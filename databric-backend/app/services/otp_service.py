import hmac
import hashlib
import secrets
import string
import logging
import httpx
import json
from app.core.config import settings
from app.core.database import fetchrow, execute

logger = logging.getLogger(__name__)

OTP_EXPIRY_SECONDS = 300  # 5 minutes
OTP_LENGTH = 6
MAX_ATTEMPTS = 5
RESEND_COOLDOWN_SECONDS = 30


def _generate_otp() -> str:
    # secrets.choice is cryptographically secure; random.choices is not.
    return "".join(secrets.choice(string.digits) for _ in range(OTP_LENGTH))


def _hash_otp(otp: str) -> str:
    """
    HMAC-SHA256 of the OTP keyed by SECRET_KEY. A leaked DB row reveals
    the hash, not the live code. Constant-time compare on verify.
    """
    return hmac.new(
        settings.SECRET_KEY.encode(),
        otp.encode(),
        hashlib.sha256,
    ).hexdigest()


# ── Send ──────────────────────────────────────────────────────


async def send_otp(phone_number: str) -> bool:
    """
    Generate a new OTP, persist its hash, and deliver it.

    Delivery order: Twilio WhatsApp first, fall back to Africa's Talking
    SMS if Twilio fails. Returns True iff at least one channel succeeded.

    DB-backed storage (otp_codes table) so OTPs sent on worker A can be
    verified on worker B — the deployed config runs `--workers 2`.
    """
    # Per-phone resend cooldown. Cheap protection against SMS-spend abuse
    # and brute-force enumeration. The check uses expires_at since we
    # always set it to NOW() + OTP_EXPIRY_SECONDS on issue.
    existing = await fetchrow(
        "SELECT expires_at FROM otp_codes WHERE phone_number = $1",
        phone_number,
    )
    if existing is not None:
        # `seconds_until_expiry` is positive while the code is live.
        # Issued time = OTP_EXPIRY_SECONDS - seconds_until_expiry.
        seconds_until_expiry = (existing["expires_at"].timestamp() - _now_ts())
        seconds_since_issue = OTP_EXPIRY_SECONDS - max(0.0, seconds_until_expiry)
        if seconds_since_issue < RESEND_COOLDOWN_SECONDS:
            logger.info(f"OTP resend throttled for {phone_number}")
            return False

    otp = _generate_otp()
    otp_hash = _hash_otp(otp)

    # Upsert: a new send invalidates any previous code and resets attempts.
    await execute(
        """
        INSERT INTO otp_codes (phone_number, otp_hash, expires_at, attempts)
        VALUES ($1, $2, NOW() + ($3 || ' seconds')::interval, 0)
        ON CONFLICT (phone_number)
        DO UPDATE SET
            otp_hash = EXCLUDED.otp_hash,
            expires_at = EXCLUDED.expires_at,
            attempts = 0
        """,
        phone_number,
        otp_hash,
        str(OTP_EXPIRY_SECONDS),
    )

    if settings.APP_ENV == "development":
        logger.info(f"[DEV] OTP for {phone_number}: {otp}")
        return True

    # Production: try WhatsApp first, fall through to SMS.
    if await _send_whatsapp(phone_number, otp):
        return True
    return await _send_sms_fallback(phone_number, otp)


async def _send_whatsapp(phone_number: str, otp: str) -> bool:
    """
    Send OTP via Twilio WhatsApp.

    Tries the configured TWILIO_WHATSAPP_FROM sender first (plain Body).
    If the account enforces ContentSid (error 21654 — trial/WhatsApp Business
    senders), falls back to the Twilio sandbox number which accepts free-form
    Body for opted-in users.
    """
    if not (settings.TWILIO_ACCOUNT_SID and settings.TWILIO_AUTH_TOKEN):
        logger.warning("Twilio credentials not configured — skipping WhatsApp")
        return False

    body = (
        f"Your DataBric verification code is: *{otp}*\n\n"
        "Valid for 5 minutes. Do not share this code with anyone."
    )

    senders = [settings.TWILIO_WHATSAPP_FROM]
    # Always include the sandbox as a fallback so trial accounts work
    # (sandbox requires the recipient to have joined via 'join <keyword>')
    sandbox = "+14155238886"
    if settings.TWILIO_WHATSAPP_FROM != sandbox:
        senders.append(sandbox)

    for sender in senders:
        try:
            async with httpx.AsyncClient() as client:
                resp = await client.post(
                    f"https://api.twilio.com/2010-04-01/Accounts/"
                    f"{settings.TWILIO_ACCOUNT_SID}/Messages.json",
                    auth=(settings.TWILIO_ACCOUNT_SID, settings.TWILIO_AUTH_TOKEN),
                    data={
                        "From": f"whatsapp:{sender}",
                        "To": f"whatsapp:{phone_number}",
                        "Body": body,
                    },
                    timeout=10.0,
                )
            if resp.status_code == 201:
                logger.info(f"WhatsApp OTP sent via {sender} to {phone_number}")
                return True
            resp_json = resp.json()
            twilio_code = resp_json.get("code")
            logger.warning(
                f"Twilio WhatsApp error {resp.status_code} "
                f"(code {twilio_code}) via {sender}: {resp_json.get('message')}"
            )
        except Exception as e:
            logger.error(f"WhatsApp send exception via {sender} for {phone_number}: {e}")

    return False


async def _send_sms_fallback(phone_number: str, otp: str) -> bool:
    """Fallback to Africa's Talking SMS if WhatsApp fails or isn't configured."""
    if not settings.AT_API_KEY:
        logger.warning("No Africa's Talking API key — SMS fallback unavailable")
        return False

    message = (
        f"Your DataBric verification code is: {otp}. "
        "Valid for 5 minutes. Do not share this code."
    )

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
                    "message": message,
                    "from": settings.AT_SENDER_ID,
                },
                timeout=10.0,
            )
            data = resp.json()
            recipients = data.get("SMSMessageData", {}).get("Recipients", [])
            if recipients and recipients[0].get("status") == "Success":
                logger.info(f"SMS fallback sent to {phone_number}")
                return True
            logger.error(f"SMS fallback failed: {data}")
            return False
    except Exception as e:
        logger.error(f"SMS fallback error for {phone_number}: {e}")
        return False


# ── Verify ────────────────────────────────────────────────────


async def verify_otp(phone_number: str, otp_code: str) -> bool:
    """
    Verify an OTP atomically.

    The single UPDATE both increments the attempts counter and reads the
    stored hash — race-free across workers. On hash match the row is
    deleted (single-use). On exhausted attempts the row is deleted to
    force a fresh resend.
    """
    candidate_hash = _hash_otp(otp_code)

    row = await fetchrow(
        """
        UPDATE otp_codes
        SET attempts = attempts + 1
        WHERE phone_number = $1
          AND expires_at > NOW()
          AND attempts < $2
        RETURNING otp_hash, attempts
        """,
        phone_number,
        MAX_ATTEMPTS,
    )
    if not row:
        return False

    if not hmac.compare_digest(row["otp_hash"], candidate_hash):
        if row["attempts"] >= MAX_ATTEMPTS:
            await execute(
                "DELETE FROM otp_codes WHERE phone_number = $1", phone_number
            )
            logger.warning(f"OTP attempts exhausted for {phone_number}")
        return False

    await execute("DELETE FROM otp_codes WHERE phone_number = $1", phone_number)
    return True


def _now_ts() -> float:
    import time
    return time.time()
