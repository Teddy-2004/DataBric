from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel
from typing import Optional
from app.models.schemas import UserPublic, UserUpdate, APIResponse
from app.core.database import fetchrow, execute
from app.core.security import get_current_user
import uuid

router = APIRouter(prefix="/users", tags=["users"])


# Explicit allow-list. The PATCH builder validates incoming field names
# against this set before composing SQL — defense in depth even though
# UserUpdate is already a fixed schema.
_PATCHABLE_FIELDS = frozenset({"carrier", "city", "country", "display_name"})


class UserSearchResult(BaseModel):
    """
    Narrow projection for /users/search.
    Intentionally omits carrier/city/country to avoid phone→profile enumeration:
    any authenticated user can call this endpoint, so we expose only the
    minimum needed to invite someone (id + phone confirmation + display name).
    """
    id: uuid.UUID
    phone_number: str
    display_name: Optional[str] = None


@router.patch("/me", response_model=UserPublic)
async def update_profile(
    body: UserUpdate,
    current_user: dict = Depends(get_current_user)
):
    """Update user profile — carrier, city, country, display name."""
    fields = body.model_dump(exclude_none=True)
    if not fields:
        return UserPublic(**current_user)

    unknown = set(fields) - _PATCHABLE_FIELDS
    if unknown:
        raise HTTPException(
            status_code=422,
            detail=f"Unknown fields: {sorted(unknown)}",
        )

    set_clauses = ", ".join(f"{k} = ${i+2}" for i, k in enumerate(fields))
    values = list(fields.values())

    user = await fetchrow(
        f"UPDATE users SET {set_clauses} WHERE id = $1 RETURNING *",
        current_user["id"], *values
    )
    return UserPublic(**dict(user))


@router.get("/search", response_model=list[UserSearchResult])
async def search_user_by_phone(
    phone: str,
    current_user: dict = Depends(get_current_user)
):
    """
    Look up a user by phone number.
    Used when inviting a friend who is already on DataBric.

    Returns only id/phone/display_name. Carrier/city/country are intentionally
    withheld to prevent profile enumeration by phone-number scanning.
    """
    if len(phone) < 7:
        raise HTTPException(status_code=400, detail="Phone number too short")

    row = await fetchrow(
        "SELECT id, phone_number, display_name FROM users WHERE phone_number = $1 AND id != $2",
        phone, current_user["id"]
    )
    if not row:
        return []
    return [UserSearchResult(**dict(row))]
