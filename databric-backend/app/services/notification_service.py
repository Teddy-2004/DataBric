import asyncio
import httpx
import json
import logging
import time
from app.core.config import settings
from app.core.database import fetchrow, fetch
import uuid

logger = logging.getLogger(__name__)

FCM_URL = "https://fcm.googleapis.com/v1/projects/{project_id}/messages:send"

# Cached service-account credentials. Reused across requests so we don't
# re-load the JSON file and re-run the OAuth refresh on every push.
_cached_credentials = None
_credentials_lock = asyncio.Lock()


def _build_credentials():
    import google.oauth2.service_account
    return google.oauth2.service_account.Credentials.from_service_account_file(
        settings.FIREBASE_CREDENTIALS_PATH,
        scopes=["https://www.googleapis.com/auth/firebase.messaging"],
    )


def _sync_refresh(credentials):
    import google.auth.transport.requests
    credentials.refresh(google.auth.transport.requests.Request())


async def _get_access_token() -> str:
    """
    Get Firebase OAuth2 access token from service account credentials.

    Returns a cached token until ~60s before its expiry, then refreshes.
    The refresh call is sync I/O so we run it in a thread to keep the
    event loop free.
    """
    if settings.APP_ENV == "development":
        return "dev-token"

    global _cached_credentials
    async with _credentials_lock:
        try:
            if _cached_credentials is None:
                _cached_credentials = await asyncio.to_thread(_build_credentials)

            needs_refresh = (
                _cached_credentials.token is None
                or _cached_credentials.expired
                or (
                    _cached_credentials.expiry is not None
                    and (_cached_credentials.expiry.timestamp() - time.time()) < 60
                )
            )
            if needs_refresh:
                await asyncio.to_thread(_sync_refresh, _cached_credentials)
            return _cached_credentials.token or ""
        except Exception as e:
            logger.error(f"Failed to get Firebase token: {e}")
            return ""


async def send_notification(
    user_id: uuid.UUID,
    title: str,
    body: str,
    data: dict = None,
) -> bool:
    """
    Send push notification to a user's registered device(s).
    """
    # Get all FCM tokens for user
    devices = await fetch(
        "SELECT fcm_token FROM devices WHERE user_id = $1 AND fcm_token IS NOT NULL",
        user_id
    )

    if not devices:
        logger.debug(f"No devices found for user {user_id}")
        return False

    if settings.APP_ENV == "development":
        logger.info(f"[DEV] Push to {user_id}: {title} — {body}")
        return True

    token = await _get_access_token()
    if not token:
        return False

    url = FCM_URL.format(project_id=settings.FIREBASE_PROJECT_ID)
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }

    success = False
    async with httpx.AsyncClient() as client:
        for device in devices:
            payload = {
                "message": {
                    "token": device["fcm_token"],
                    "notification": {"title": title, "body": body},
                    "android": {"priority": "high"},
                    "data": {k: str(v) for k, v in (data or {}).items()},
                }
            }
            try:
                resp = await client.post(url, headers=headers, json=payload, timeout=10.0)
                if resp.status_code == 200:
                    success = True
                else:
                    logger.warning(f"FCM error {resp.status_code}: {resp.text}")
            except Exception as e:
                logger.error(f"FCM send failed: {e}")

    return success


# ── Notification helpers ───────────────────────────────────────

async def notify_connection_request(seller_id: uuid.UUID, buyer_name: str, session_id: uuid.UUID):
    await send_notification(
        seller_id,
        title="Connection request",
        body=f"{buyer_name} wants to use your data",
        data={"type": "connection_request", "session_id": str(session_id)},
    )


async def notify_session_started(buyer_id: uuid.UUID, seller_name: str):
    await send_notification(
        buyer_id,
        title="Connected!",
        body=f"You are now using {seller_name}'s data",
        data={"type": "session_started"},
    )


async def notify_usage_warning(seller_id: uuid.UUID, used_gb: float, limit_gb: float):
    await send_notification(
        seller_id,
        title="Almost at your limit",
        body=f"{used_gb:.1f} GB of {limit_gb:.1f} GB used",
        data={"type": "usage_warning"},
    )


async def notify_session_ended(user_id: uuid.UUID, used_gb: float, reason: str = "limit_reached"):
    reasons = {
        "limit_reached": "Data limit reached",
        "seller_stopped": "Seller ended sharing",
        "buyer_disconnected": "Connection closed",
    }
    await send_notification(
        user_id,
        title="Session ended",
        body=f"{reasons.get(reason, 'Session ended')} — {used_gb:.2f} GB used",
        data={"type": "session_ended", "reason": reason, "used_gb": str(used_gb)},
    )


async def notify_friend_request(user_id: uuid.UUID, from_name: str, friendship_id: uuid.UUID):
    await send_notification(
        user_id,
        title="Friend request",
        body=f"{from_name} wants to connect with you on DataBric",
        data={"type": "friend_request", "friendship_id": str(friendship_id)},
    )
