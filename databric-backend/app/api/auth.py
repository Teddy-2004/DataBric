from fastapi import APIRouter, HTTPException, Depends, status
from app.models.schemas import (
    SendOTPRequest, VerifyOTPRequest, AuthResponse,
    UserCreate, UserPublic, DeviceRegister, APIResponse
)
from app.services.otp_service import send_otp, verify_otp
from app.core.database import fetchrow, execute
from app.core.security import get_current_user
from app.core.config import settings
from jose import jwt
from datetime import datetime, timedelta, timezone
import uuid
import logging

router = APIRouter(prefix="/auth", tags=["auth"])
logger = logging.getLogger(__name__)

TOKEN_EXPIRY_HOURS = 24 * 30  # 30 days


def _create_token(user_id: str) -> str:
    now = datetime.now(timezone.utc)
    payload = {
        "sub": user_id,
        "iat": now,
        "exp": now + timedelta(hours=TOKEN_EXPIRY_HOURS),
    }
    return jwt.encode(payload, settings.SECRET_KEY, algorithm="HS256")


@router.post("/otp/send", response_model=APIResponse)
async def send_otp_endpoint(body: SendOTPRequest):
    """
    Step 1 of auth: Send OTP to phone number.
    The service layer enforces a per-phone resend cooldown to cap SMS spend
    and slow phone-number enumeration / brute force.
    """
    success = await send_otp(body.phone_number)
    if not success:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Failed to send OTP. If you just requested one, wait a moment and try again."
        )
    return APIResponse(message=f"OTP sent to {body.phone_number}")


@router.post("/otp/verify", response_model=AuthResponse)
async def verify_otp_endpoint(body: VerifyOTPRequest):
    """
    Step 2 of auth: Verify OTP and get or create user.
    Returns JWT token.
    """
    valid = await verify_otp(body.phone_number, body.otp_code)
    if not valid:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired OTP"
        )

    # Get or create user
    user = await fetchrow(
        "SELECT * FROM users WHERE phone_number = $1",
        body.phone_number
    )

    if not user:
        user_id = uuid.uuid4()
        user = await fetchrow(
            """
            INSERT INTO users (id, phone_number, created_at)
            VALUES ($1, $2, NOW())
            RETURNING *
            """,
            user_id, body.phone_number
        )
        logger.info(f"New user registered: {body.phone_number}")

    user = dict(user)
    token = _create_token(str(user["id"]))

    return AuthResponse(
        access_token=token,
        user=UserPublic(**user)
    )


@router.post("/device", response_model=APIResponse)
async def register_device(
    body: DeviceRegister,
    current_user: dict = Depends(get_current_user)
):
    """
    Register or update FCM token for push notifications.
    Call this after login and whenever the FCM token refreshes.
    """
    await execute(
        """
        INSERT INTO devices (user_id, fcm_token, platform, app_version, last_seen)
        VALUES ($1, $2, $3, $4, NOW())
        ON CONFLICT (user_id, platform)
        DO UPDATE SET
            fcm_token = EXCLUDED.fcm_token,
            app_version = EXCLUDED.app_version,
            last_seen = NOW()
        """,
        current_user["id"],
        body.fcm_token,
        body.platform,
        body.app_version,
    )
    return APIResponse(message="Device registered")


@router.get("/me", response_model=UserPublic)
async def get_me(current_user: dict = Depends(get_current_user)):
    """Return current authenticated user."""
    return UserPublic(**current_user)
