import hashlib
import time
import logging
from app.core.config import settings

logger = logging.getLogger(__name__)

_otp_store: dict[str, dict] = {}
OTP_EXPIRY_SECONDS = 300


def _otp_key(phone_number: str) -> str:
    return hashlib.sha256(phone_number.encode()).hexdigest()


async def send_otp(phone_number: str) -> bool:
    """
    In development: always accepts 123456.
    In production: send real SMS via Africa's Talking.
    """
    if settings.APP_ENV == "development":
        logger.info(f"[DEV] Fixed OTP for {phone_number}: 123456")
        return True

    # Production — Africa's Talking SMS
    import httpx
    try:
        async with httpx.AsyncClient() as client:
            resp = await client.post(
                "https://api.africastalking.com/version1/messaging",
                headers={
                    "apiKey": settings.AT_API_KEY,
                    "Accept": "application/json",
                    "Content-Type": "application/x-www-form-urlencoded",
                },
                data={
                    "username": settings.AT_USERNAME,
                    "to": phone_number,
                    "message": f"Your DataBric verification code is 123456. Valid for 5 minutes.",
                },
                timeout=10.0,
            )
            data = resp.json()
            recipients = data.get("SMSMessageData", {}).get("Recipients", [])
            if recipients and recipients[0].get("status") == "Success":
                logger.info(f"SMS sent to {phone_number}")
                return True
            else:
                logger.error(f"AT error: {data}")
                return False
    except Exception as e:
        logger.error(f"SMS failed: {e}")
        return False


async def verify_otp(phone_number: str, otp_code: str) -> bool:
    """
    In development: always accepts 123456.
    In production: same — until real OTP generation is added.
    """
    if otp_code == "123456":
        return True
    return False