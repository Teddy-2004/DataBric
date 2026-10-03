from fastapi import APIRouter, Depends, HTTPException, status
from app.models.schemas import (
    FriendInviteRequest, FriendActionRequest,
    FriendshipPublic, UserPublic, APIResponse
)
from app.core.database import fetchrow, fetch, execute
from app.core.security import get_current_user
from app.services.notification_service import notify_friend_request
import uuid

router = APIRouter(prefix="/friends", tags=["friends"])


@router.get("", response_model=list[dict])
async def list_friends(current_user: dict = Depends(get_current_user)):
    """
    Return all friendships for the current user.
    Includes accepted, pending sent, and pending received.
    """
    rows = await fetch(
        """
        SELECT
            f.id AS friendship_id,
            f.status,
            f.initiated_by,
            f.created_at,
            CASE
                WHEN f.user_a_id = $1 THEN f.user_b_id
                ELSE f.user_a_id
            END AS friend_id,
            u.phone_number,
            u.display_name,
            u.carrier,
            u.city,
            u.country
        FROM friendships f
        JOIN users u ON u.id = CASE
            WHEN f.user_a_id = $1 THEN f.user_b_id
            ELSE f.user_a_id
        END
        WHERE (f.user_a_id = $1 OR f.user_b_id = $1)
          AND f.status != 'blocked'
        ORDER BY f.created_at DESC
        """,
        current_user["id"]
    )
    return [dict(r) for r in rows]


@router.post("/invite", response_model=APIResponse)
async def invite_friend(
    body: FriendInviteRequest,
    current_user: dict = Depends(get_current_user)
):
    """
    Invite a user by phone number.
    If they are on DataBric, creates a pending friendship.
    """
    target = await fetchrow(
        "SELECT * FROM users WHERE phone_number = $1",
        body.phone_number
    )

    if not target:
        # Phone not registered — could send SMS invite in future
        return APIResponse(
            message="Phone number not registered on DataBric yet. We'll let you know when they join."
        )

    target = dict(target)

    # Robust self-check by id, not by string-comparing potentially differently
    # normalized phone numbers.
    if target["id"] == current_user["id"]:
        raise HTTPException(status_code=400, detail="Cannot invite yourself")

    # Check if friendship already exists
    existing = await fetchrow(
        """
        SELECT id, status FROM friendships
        WHERE (user_a_id = $1 AND user_b_id = $2)
           OR (user_a_id = $2 AND user_b_id = $1)
        """,
        current_user["id"], target["id"]
    )

    if existing:
        ex = dict(existing)
        if ex["status"] == "accepted":
            raise HTTPException(status_code=400, detail="Already friends")
        if ex["status"] == "pending":
            raise HTTPException(status_code=400, detail="Invitation already sent")
        if ex["status"] == "blocked":
            raise HTTPException(status_code=400, detail="Cannot invite this user")

    friendship_id = uuid.uuid4()
    await execute(
        """
        INSERT INTO friendships (id, user_a_id, user_b_id, status, initiated_by, created_at)
        VALUES ($1, $2, $3, 'pending', $4, NOW())
        """,
        friendship_id,
        current_user["id"],
        target["id"],
        current_user["id"],
    )

    # Push notification to target
    sender_name = current_user.get("display_name") or current_user["phone_number"]
    await notify_friend_request(target["id"], sender_name, friendship_id)

    return APIResponse(message=f"Friend request sent to {body.phone_number}")


@router.post("/action", response_model=APIResponse)
async def friend_action(
    body: FriendActionRequest,
    current_user: dict = Depends(get_current_user)
):
    """
    Accept, block, or remove a friendship.
    """
    friendship = await fetchrow(
        """
        SELECT * FROM friendships
        WHERE id = $1
        AND (user_a_id = $2 OR user_b_id = $2)
        """,
        body.friendship_id, current_user["id"]
    )

    if not friendship:
        raise HTTPException(status_code=404, detail="Friendship not found")

    f = dict(friendship)

    if body.action == "accept":
        if f["status"] != "pending":
            raise HTTPException(status_code=400, detail="No pending request to accept")
        if f["initiated_by"] == current_user["id"]:
            raise HTTPException(status_code=400, detail="Cannot accept your own request")
        await execute(
            "UPDATE friendships SET status = 'accepted' WHERE id = $1",
            body.friendship_id
        )
        return APIResponse(message="Friend request accepted")

    elif body.action == "block":
        await execute(
            "UPDATE friendships SET status = 'blocked' WHERE id = $1",
            body.friendship_id
        )
        return APIResponse(message="User blocked")

    elif body.action == "remove":
        await execute(
            "DELETE FROM friendships WHERE id = $1",
            body.friendship_id
        )
        return APIResponse(message="Friend removed")

    raise HTTPException(status_code=400, detail="Invalid action")
