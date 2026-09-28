from pydantic import BaseModel, field_validator, model_validator
from typing import Optional, List
from datetime import datetime
from enum import Enum
import uuid


# ── Enums ──────────────────────────────────────────────────────

class FriendshipStatus(str, Enum):
    PENDING = "pending"
    ACCEPTED = "accepted"
    BLOCKED = "blocked"


class SessionStatus(str, Enum):
    ADVERTISING = "advertising"
    CONNECTED = "connected"
    TRANSFERRING = "transferring"
    ENDED = "ended"
    TERMINATED = "terminated"


class SessionDirection(str, Enum):
    SENT = "sent"
    RECEIVED = "received"


class NodeStatus(str, Enum):
    ACTIVE = "active"
    BLOCKED = "blocked"
    RETIRED = "retired"


# ── Auth schemas ───────────────────────────────────────────────

class SendOTPRequest(BaseModel):
    phone_number: str

    @field_validator("phone_number")
    @classmethod
    def validate_phone(cls, v):
        v = v.strip().replace(" ", "")
        if not v.startswith("+"):
            raise ValueError("Phone number must include country code (e.g. +250...)")
        if len(v) < 10 or len(v) > 16:
            raise ValueError("Invalid phone number length")
        return v


class VerifyOTPRequest(BaseModel):
    phone_number: str
    otp_code: str

    @field_validator("otp_code")
    @classmethod
    def validate_otp(cls, v):
        v = v.strip()
        if not v.isdigit() or len(v) != 6:
            raise ValueError("OTP must be a 6-digit number")
        return v


class AuthResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    user: "UserPublic"


# ── User schemas ───────────────────────────────────────────────

class UserCreate(BaseModel):
    phone_number: str
    carrier: Optional[str] = None
    city: Optional[str] = None
    country: Optional[str] = None


class UserUpdate(BaseModel):
    carrier: Optional[str] = None
    city: Optional[str] = None
    country: Optional[str] = None
    display_name: Optional[str] = None


class UserPublic(BaseModel):
    id: uuid.UUID
    phone_number: str
    display_name: Optional[str] = None
    carrier: Optional[str] = None
    city: Optional[str] = None
    country: Optional[str] = None
    created_at: datetime

    class Config:
        from_attributes = True


class DeviceRegister(BaseModel):
    fcm_token: str
    platform: str = "android"
    app_version: str = "1.0.0"

    @field_validator("platform")
    @classmethod
    def validate_platform(cls, v):
        if v not in ("android", "ios"):
            raise ValueError("platform must be android or ios")
        return v


# ── Friendship schemas ─────────────────────────────────────────

class FriendInviteRequest(BaseModel):
    phone_number: str


class FriendActionRequest(BaseModel):
    friendship_id: uuid.UUID
    action: str  # accept | block | remove

    @field_validator("action")
    @classmethod
    def validate_action(cls, v):
        if v not in ("accept", "block", "remove"):
            raise ValueError("action must be accept, block, or remove")
        return v


class FriendshipPublic(BaseModel):
    id: uuid.UUID
    friend: UserPublic
    status: FriendshipStatus
    initiated_by: uuid.UUID
    created_at: datetime

    class Config:
        from_attributes = True


# ── Session schemas ────────────────────────────────────────────

class StartSharingRequest(BaseModel):
    limit_gb: float
    receiver_id: Optional[uuid.UUID] = None

    @field_validator("limit_gb", mode="before")
    @classmethod
    def validate_limit(cls, v):
        v = float(v)  # accept int or float
        if v < 0.1:
            raise ValueError("Minimum sharing limit is 100 MB")
        if v > 50:
            raise ValueError("Maximum sharing limit is 50 GB")
        return round(v, 2)


class ConnectRequest(BaseModel):
    seller_id: uuid.UUID


class SessionPublic(BaseModel):
    id: uuid.UUID
    seller_id: uuid.UUID
    buyer_id: Optional[uuid.UUID]
    relay_node_id: Optional[uuid.UUID]
    limit_bytes: int
    used_bytes: int
    status: SessionStatus
    started_at: datetime
    ended_at: Optional[datetime]

    # Computed
    limit_gb: float
    used_gb: float
    usage_percent: float

    class Config:
        from_attributes = True


class SessionWithFriend(BaseModel):
    id: uuid.UUID
    direction: SessionDirection
    friend_name: Optional[str]
    friend_carrier: Optional[str]
    amount_gb: float
    status: SessionStatus
    created_at: datetime

    class Config:
        from_attributes = True


class ConnectResponse(BaseModel):
    session_id: uuid.UUID
    vless_uri: str          # VLESS+Reality connection string for the app
    relay_host: str
    relay_port: int


# ── Usage tracking schemas (relay → backend) ───────────────────
# NOTE: relay authentication is via the X-Relay-Secret header, not in-body.

class UsageHeartbeat(BaseModel):
    session_id: uuid.UUID
    bytes_delta: int        # bytes transferred since last heartbeat
    heartbeat_id: uuid.UUID  # supplied by relay; backend dedupes on this

    @field_validator("bytes_delta")
    @classmethod
    def validate_bytes(cls, v):
        if v < 0:
            raise ValueError("bytes_delta cannot be negative")
        return v


class RelayNodeRegister(BaseModel):
    node_id: str
    host: str
    port: int
    region: str
    city: str
    public_key: Optional[str] = ""


class NodeHealthPing(BaseModel):
    node_id: str
    active_sessions: int
    cpu_percent: float
    memory_percent: float


# ── Response wrappers ──────────────────────────────────────────

class APIResponse(BaseModel):
    success: bool = True
    message: str = "OK"
    data: Optional[dict] = None


class PaginatedResponse(BaseModel):
    items: list
    total: int
    page: int
    per_page: int
