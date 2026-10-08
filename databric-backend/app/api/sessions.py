from fastapi import APIRouter, Depends, HTTPException, status
from app.models.schemas import (
    StartSharingRequest, ConnectRequest,
    ConnectResponse, APIResponse
)
from app.core.database import fetchrow, fetch, execute
from app.core.security import get_current_user
from app.services.relay_service import (
    get_best_relay_node, create_session,
    connect_buyer_to_session, terminate_session,
    get_active_session_for_seller, RelayFullError,
)
from app.services.notification_service import (
    notify_connection_request, notify_session_started,
    notify_session_ended
)
import logging

router = APIRouter(prefix="/sessions", tags=["sessions"])
logger = logging.getLogger(__name__)


def _bytes_to_gb(b: int) -> float:
    return round((b or 0) / (1024 ** 3), 3)


def _session_to_public(s: dict) -> dict:
    """
    Build a client-safe session projection.

    Important: do NOT spread `s` here — the raw row contains VLESS Reality
    credentials (`vless_uuid`, `short_id`, `public_key`) that the buyer
    should never see and the seller doesn't need after the initial start
    response (they already hold the URI). Explicit allow-list only.
    """
    limit_bytes = s.get("limit_bytes", 0) or 0
    used_bytes = s.get("used_bytes", 0) or 0
    return {
        "id": str(s["id"]) if s.get("id") else None,
        "seller_id": str(s["seller_id"]) if s.get("seller_id") else None,
        "buyer_id": str(s["buyer_id"]) if s.get("buyer_id") else None,
        "status": s.get("status"),
        "end_reason": s.get("end_reason"),
        "used_bytes": used_bytes,
        "limit_bytes": limit_bytes,
        "limit_gb": _bytes_to_gb(limit_bytes),
        "used_gb": _bytes_to_gb(used_bytes),
        "usage_percent": (used_bytes / limit_bytes) if limit_bytes > 0 else 0,
        "started_at": s.get("started_at").isoformat() if s.get("started_at") else None,
        "ended_at": s.get("ended_at").isoformat() if s.get("ended_at") else None,
    }


async def _are_friends(user_a, user_b) -> bool:
    row = await fetchrow(
        """
        SELECT 1 FROM friendships
        WHERE status = 'accepted'
        AND (
            (user_a_id = $1 AND user_b_id = $2)
            OR (user_a_id = $2 AND user_b_id = $1)
        )
        """,
        user_a, user_b,
    )
    return row is not None


@router.post("/start", response_model=dict)
async def start_sharing(
    body: StartSharingRequest,
    current_user: dict = Depends(get_current_user)
):
    """
    Seller calls this to start sharing their data.

    Returns `seller_config`: the full Xray config the app runs to connect the
    seller's phone to the relay as this session's reverse-proxy bridge. The
    relay agent picks the session up within a few seconds.
    """
    # Check no active session already running
    existing = await get_active_session_for_seller(current_user["id"])
    if existing:
        raise HTTPException(
            status_code=400,
            detail="You already have an active sharing session. Stop it first."
        )

    # If a specific receiver was named, require they're a friend already.
    if body.receiver_id and not await _are_friends(current_user["id"], body.receiver_id):
        raise HTTPException(
            status_code=400,
            detail="You can only share with friends on DataBric."
        )

    # Select best relay node
    relay = await get_best_relay_node(region=current_user.get("country"))
    if not relay:
        raise HTTPException(
            status_code=503,
            detail="No relay nodes available right now. Try again in a moment."
        )

    try:
        session = await create_session(
            seller_id=current_user["id"],
            limit_gb=body.limit_gb,
            relay_node=relay,
            receiver_id=body.receiver_id,
        )
    except RelayFullError:
        raise HTTPException(
            status_code=503,
            detail="All sharing slots are busy right now. Try again in a moment."
        )

    logger.info(
        f"Sharing started: seller={current_user['id']} "
        f"limit={body.limit_gb}GB relay={relay['host']}"
    )

    # One-time response, not repeated by /active: it contains credentials.
    return {
        "session_id": str(session["id"]),
        "seller_config": session["seller_config"],
        # Kept only for app builds older than seller_config, which read it and
        # ran a placeholder. Remove once those builds are gone.
        "vless_uri": session["vless_uri"],
        "relay_host": relay["host"],
        "relay_port": relay["port"],
        "limit_gb": body.limit_gb,
        "message": "Sharing started. Send your session_id to a friend to let them connect."
    }


@router.post("/stop", response_model=APIResponse)
async def stop_sharing(current_user: dict = Depends(get_current_user)):
    """Seller calls this to stop sharing."""
    session = await get_active_session_for_seller(current_user["id"])
    if not session:
        raise HTTPException(status_code=404, detail="No active sharing session found")

    used_gb = _bytes_to_gb(session.get("used_bytes", 0))
    await terminate_session(session["id"], end_reason="seller_stopped")

    # Notify buyer if connected
    if session.get("buyer_id"):
        await notify_session_ended(session["buyer_id"], used_gb, "seller_stopped")

    return APIResponse(message=f"Sharing stopped. {used_gb:.2f} GB was shared.")


@router.post("/connect", response_model=ConnectResponse)
async def connect_to_session(
    body: ConnectRequest,
    current_user: dict = Depends(get_current_user)
):
    """
    Buyer calls this to connect to a seller's sharing session.
    Returns the VLESS+Reality URI to load into Xray-core on buyer's device.

    Flow:
    1. Verify buyer and seller are friends
    2. Find seller's active advertising session
    3. Connect buyer to session
    4. Return VLESS URI for buyer's Xray-core client
    """
    seller_id = body.seller_id

    if not await _are_friends(current_user["id"], seller_id):
        raise HTTPException(
            status_code=403,
            detail="You can only connect to friends on DataBric."
        )

    # Get seller's active session
    session = await get_active_session_for_seller(seller_id)
    if not session:
        raise HTTPException(
            status_code=404,
            detail="This friend is not currently sharing. Ask them to start sharing first."
        )

    # If session has a specific receiver, enforce it
    if session.get("receiver_id") and str(session["receiver_id"]) != str(current_user["id"]):
        raise HTTPException(
            status_code=403,
            detail="This session is not intended for you."
        )

    if session["status"] != "advertising":
        raise HTTPException(
            status_code=409,
            detail="This friend's session is already in use."
        )

    # Connect buyer
    try:
        updated = await connect_buyer_to_session(session["id"], current_user["id"])
    except ValueError as e:
        raise HTTPException(status_code=409, detail=str(e))

    # Notify seller
    buyer_name = current_user.get("display_name") or current_user["phone_number"]
    await notify_connection_request(seller_id, buyer_name, session["id"])

    # Notify buyer
    seller = await fetchrow("SELECT * FROM users WHERE id = $1", seller_id)
    seller_name = dict(seller).get("display_name") or dict(seller)["phone_number"]
    await notify_session_started(current_user["id"], seller_name)

    # Build VLESS URI for buyer
    from app.services.relay_service import generate_vless_reality_uri
    vless_uri = generate_vless_reality_uri(
        user_uuid=session["vless_uuid"],
        host=session["host"],
        port=session["port"],
        public_key=session["public_key"],
        short_id=session["short_id"],
        server_name=session.get("server_name") or "www.google.com",
    )

    return ConnectResponse(
        session_id=session["id"],
        vless_uri=vless_uri,
        relay_host=session["host"],
        relay_port=session["port"],
    )


@router.post("/disconnect", response_model=APIResponse)
async def disconnect(current_user: dict = Depends(get_current_user)):
    """Buyer calls this to disconnect from a session."""
    row = await fetchrow(
        """
        SELECT * FROM sharing_sessions
        WHERE buyer_id = $1
        AND status IN ('connected', 'transferring')
        ORDER BY started_at DESC LIMIT 1
        """,
        current_user["id"]
    )
    if not row:
        raise HTTPException(status_code=404, detail="No active connection found")

    s = dict(row)
    used_gb = _bytes_to_gb(s.get("used_bytes", 0))

    # Status = 'ended' with end_reason distinguishes from 'terminated' (forced).
    await execute(
        """
        UPDATE sharing_sessions
        SET status = 'ended',
            end_reason = 'buyer_disconnected',
            ended_at = NOW()
        WHERE id = $1
        """,
        s["id"]
    )

    await notify_session_ended(s["seller_id"], used_gb, "buyer_disconnected")

    return APIResponse(message=f"Disconnected. {used_gb:.3f} GB used.")


@router.get("/active", response_model=dict)
async def get_active_session(current_user: dict = Depends(get_current_user)):
    """
    Return the current user's active session (as seller or buyer).
    Flutter app polls this every 5s to update the UI.
    """
    # Check as seller
    as_seller = await get_active_session_for_seller(current_user["id"])
    if as_seller:
        return {
            "role": "seller",
            "session": _session_to_public(as_seller)
        }

    # Check as buyer
    as_buyer = await fetchrow(
        """
        SELECT s.*, rn.host, rn.port
        FROM sharing_sessions s
        JOIN relay_nodes rn ON rn.id = s.relay_node_id
        WHERE s.buyer_id = $1
        AND s.status IN ('connected', 'transferring')
        ORDER BY s.started_at DESC LIMIT 1
        """,
        current_user["id"]
    )
    if as_buyer:
        return {
            "role": "buyer",
            "session": _session_to_public(dict(as_buyer))
        }

    return {"role": None, "session": None}


@router.get("/history", response_model=list[dict])
async def get_history(
    page: int = 1,
    per_page: int = 20,
    current_user: dict = Depends(get_current_user)
):
    """Return paginated session history for current user."""
    offset = (page - 1) * per_page

    rows = await fetch(
        """
        SELECT
            s.id,
            s.status,
            s.end_reason,
            s.used_bytes,
            s.limit_bytes,
            s.started_at,
            s.ended_at,
            CASE
                WHEN s.seller_id = $1 THEN 'sent'
                ELSE 'received'
            END AS direction,
            CASE
                WHEN s.seller_id = $1 THEN u_buyer.phone_number
                ELSE u_seller.phone_number
            END AS friend_phone,
            CASE
                WHEN s.seller_id = $1 THEN u_buyer.display_name
                ELSE u_seller.display_name
            END AS friend_name,
            CASE
                WHEN s.seller_id = $1 THEN u_buyer.carrier
                ELSE u_seller.carrier
            END AS friend_carrier
        FROM sharing_sessions s
        LEFT JOIN users u_buyer ON u_buyer.id = s.buyer_id
        LEFT JOIN users u_seller ON u_seller.id = s.seller_id
        WHERE (s.seller_id = $1 OR s.buyer_id = $1)
          AND s.status IN ('ended', 'terminated')
        ORDER BY s.started_at DESC
        LIMIT $2 OFFSET $3
        """,
        current_user["id"], per_page, offset
    )

    result = []
    for r in rows:
        d = dict(r)
        d["amount_gb"] = _bytes_to_gb(d.get("used_bytes", 0))
        result.append(d)

    return result
