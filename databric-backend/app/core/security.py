from fastapi import HTTPException, Security, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from jose import JWTError, jwt
from app.core.config import settings
from app.core.database import fetchrow
import hmac
import logging
import uuid

logger = logging.getLogger(__name__)
security = HTTPBearer()


class AuthError(HTTPException):
    def __init__(self, detail: str):
        super().__init__(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=detail,
            headers={"WWW-Authenticate": "Bearer"},
        )


async def verify_token(
    credentials: HTTPAuthorizationCredentials = Security(security)
) -> dict:
    """
    Verify Supabase JWT token and return the user payload.
    Called as a FastAPI dependency on every protected route.
    """
    token = credentials.credentials
    try:
        payload = jwt.decode(
            token,
            settings.SECRET_KEY,
            algorithms=["HS256"],
            options={"verify_aud": False},
        )
        user_id: str = payload.get("sub")
        if not user_id:
            raise AuthError("Invalid token: no subject")
        return {"user_id": user_id, "payload": payload}
    except JWTError as e:
        logger.warning(f"JWT verification failed: {e}")
        raise AuthError("Invalid or expired token")


async def get_current_user(token_data: dict = Security(verify_token)) -> dict:
    """
    Resolve authenticated user from DB.
    Returns full user record.
    """
    user_id = token_data["user_id"]
    user = await fetchrow(
        "SELECT * FROM users WHERE id = $1",
        uuid.UUID(user_id)
    )
    if not user:
        raise AuthError("User not found")
    return dict(user)


def verify_relay_secret(secret: str | None) -> bool:
    """
    Relay nodes authenticate with a shared secret carried in X-Relay-Secret.
    Constant-time comparison to defeat timing attacks.
    """
    if not secret:
        return False
    return hmac.compare_digest(secret.encode(), settings.RELAY_SECRET_KEY.encode())
