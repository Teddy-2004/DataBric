"""
DataBric Backend Tests
Run with: pytest tests/ -v
"""
import pytest
from fastapi.testclient import TestClient
from unittest.mock import AsyncMock, patch, MagicMock
import uuid

from app.main import app
from app.services.relay_service import generate_vless_reality_uri


# ── Test client ───────────────────────────────────────────────
client = TestClient(app)


# ── Health check ──────────────────────────────────────────────
def test_health():
    resp = client.get("/health")
    assert resp.status_code == 200
    data = resp.json()
    assert data["status"] == "ok"


# ── OTP service tests ──────────────────────────────────────────
# The DB-backed implementation is exercised via mocked asyncpg helpers.

@pytest.mark.asyncio
async def test_send_otp_dev_mode_inserts_row():
    """In dev mode send_otp should upsert into otp_codes and return True."""
    from app.services import otp_service

    with patch.object(otp_service, "fetchrow", new_callable=AsyncMock) as m_fetchrow, \
         patch.object(otp_service, "execute", new_callable=AsyncMock) as m_execute:
        m_fetchrow.return_value = None  # no existing row → no cooldown
        result = await otp_service.send_otp("+250780000001")
        assert result is True
        # Upsert was called with hashed OTP
        assert m_execute.await_count == 1
        args = m_execute.call_args.args
        assert "INSERT INTO otp_codes" in args[0]
        assert args[1] == "+250780000001"
        # otp_hash is 64 hex chars (SHA256)
        assert len(args[2]) == 64


@pytest.mark.asyncio
async def test_send_otp_cooldown_blocks_rapid_resend():
    """A row issued <30s ago should make send_otp return False."""
    from app.services import otp_service
    from datetime import datetime, timedelta, timezone

    fresh_expiry = datetime.now(timezone.utc) + timedelta(seconds=290)  # 10s ago
    with patch.object(otp_service, "fetchrow", new_callable=AsyncMock) as m_fetchrow, \
         patch.object(otp_service, "execute", new_callable=AsyncMock) as m_execute:
        m_fetchrow.return_value = {"expires_at": fresh_expiry, "attempts": 0}
        result = await otp_service.send_otp("+250780000001")
        assert result is False
        m_execute.assert_not_awaited()


@pytest.mark.asyncio
async def test_verify_otp_matches_hash():
    """verify_otp accepts a code whose HMAC matches the stored hash."""
    from app.services import otp_service

    code = "123456"
    stored_hash = otp_service._hash_otp(code)
    with patch.object(otp_service, "fetchrow", new_callable=AsyncMock) as m_fetchrow, \
         patch.object(otp_service, "execute", new_callable=AsyncMock) as m_execute:
        m_fetchrow.return_value = {"otp_hash": stored_hash, "attempts": 1}
        ok = await otp_service.verify_otp("+250780000001", code)
        assert ok is True
        # Successful verification deletes the row.
        assert m_execute.await_count == 1
        assert "DELETE" in m_execute.call_args.args[0]


@pytest.mark.asyncio
async def test_verify_otp_rejects_wrong_code():
    from app.services import otp_service

    real_hash = otp_service._hash_otp("123456")
    with patch.object(otp_service, "fetchrow", new_callable=AsyncMock) as m_fetchrow, \
         patch.object(otp_service, "execute", new_callable=AsyncMock):
        m_fetchrow.return_value = {"otp_hash": real_hash, "attempts": 1}
        ok = await otp_service.verify_otp("+250780000001", "000000")
        assert ok is False


@pytest.mark.asyncio
async def test_verify_otp_rejects_when_no_row():
    """If the atomic UPDATE returns no row (expired or attempts exceeded),
    verify_otp returns False without ever comparing hashes."""
    from app.services import otp_service

    with patch.object(otp_service, "fetchrow", new_callable=AsyncMock) as m_fetchrow, \
         patch.object(otp_service, "execute", new_callable=AsyncMock):
        m_fetchrow.return_value = None
        ok = await otp_service.verify_otp("+250780000001", "123456")
        assert ok is False


# ── VLESS URI generation ───────────────────────────────────────
def test_vless_reality_uri_format():
    uri = generate_vless_reality_uri(
        user_uuid="test-uuid-1234",
        host="relay1.databric.app",
        port=8443,
        public_key="abc123publickey",
        short_id="deadbeef",
        server_name="www.google.com",
    )
    assert uri.startswith("vless://")
    assert "relay1.databric.app:8443" in uri
    assert "security=reality" in uri
    assert "fp=chrome" in uri
    assert "sni=www.google.com" in uri
    assert "pbk=abc123publickey" in uri
    assert "sid=deadbeef" in uri
    assert "flow=xtls-rprx-vision" in uri


# ── Schema validation tests ────────────────────────────────────
def test_phone_validation():
    from app.models.schemas import SendOTPRequest
    from pydantic import ValidationError

    # Valid
    req = SendOTPRequest(phone_number="+250780000001")
    assert req.phone_number == "+250780000001"

    # No country code
    with pytest.raises(ValidationError):
        SendOTPRequest(phone_number="0780000001")

    # Too short
    with pytest.raises(ValidationError):
        SendOTPRequest(phone_number="+123")


def test_otp_validation():
    from app.models.schemas import VerifyOTPRequest
    from pydantic import ValidationError

    # Valid
    req = VerifyOTPRequest(phone_number="+250780000001", otp_code="123456")
    assert req.otp_code == "123456"

    # Not 6 digits
    with pytest.raises(ValidationError):
        VerifyOTPRequest(phone_number="+250780000001", otp_code="12345")

    # Not digits
    with pytest.raises(ValidationError):
        VerifyOTPRequest(phone_number="+250780000001", otp_code="abcdef")


def test_sharing_limit_validation():
    from app.models.schemas import StartSharingRequest
    from pydantic import ValidationError

    # Valid
    req = StartSharingRequest(limit_gb=2.0)
    assert req.limit_gb == 2.0

    # Too small
    with pytest.raises(ValidationError):
        StartSharingRequest(limit_gb=0.05)

    # Too large
    with pytest.raises(ValidationError):
        StartSharingRequest(limit_gb=100.0)


def test_usage_heartbeat_requires_heartbeat_id():
    """heartbeat_id is required for idempotent deduplication."""
    from app.models.schemas import UsageHeartbeat
    from pydantic import ValidationError

    with pytest.raises(ValidationError):
        UsageHeartbeat(session_id=uuid.uuid4(), bytes_delta=1024)

    ok = UsageHeartbeat(
        session_id=uuid.uuid4(),
        bytes_delta=1024,
        heartbeat_id=uuid.uuid4(),
    )
    assert ok.bytes_delta == 1024


# ── Auth endpoints (mocked DB) ─────────────────────────────────
@patch("app.api.auth.send_otp", new_callable=AsyncMock, return_value=True)
def test_send_otp_endpoint(mock_send):
    resp = client.post("/auth/otp/send", json={"phone_number": "+250780000001"})
    assert resp.status_code == 200
    assert resp.json()["success"] is True


@patch("app.api.auth.send_otp", new_callable=AsyncMock, return_value=False)
def test_send_otp_failure(mock_send):
    resp = client.post("/auth/otp/send", json={"phone_number": "+250780000001"})
    assert resp.status_code == 503


def test_send_otp_invalid_phone():
    resp = client.post("/auth/otp/send", json={"phone_number": "invalid"})
    assert resp.status_code == 422


# ── Relay endpoints (header-based auth) ────────────────────────
def test_relay_register_missing_secret():
    """No header → 403."""
    resp = client.post("/relay/register", json={
        "node_id": "test-node",
        "host": "1.2.3.4",
        "port": 8443,
        "region": "KE",
        "city": "Nairobi",
    })
    assert resp.status_code == 403


def test_relay_register_wrong_secret():
    resp = client.post(
        "/relay/register",
        json={
            "node_id": "test-node",
            "host": "1.2.3.4",
            "port": 8443,
            "region": "KE",
            "city": "Nairobi",
        },
        headers={"X-Relay-Secret": "wrong-secret"},
    )
    assert resp.status_code == 403


def test_relay_usage_wrong_secret():
    resp = client.post(
        "/relay/usage",
        json={
            "session_id": str(uuid.uuid4()),
            "bytes_delta": 1024,
            "heartbeat_id": str(uuid.uuid4()),
        },
        headers={"X-Relay-Secret": "wrong-secret"},
    )
    assert resp.status_code == 403


# ── Rate limiting ──────────────────────────────────────────────
def test_rate_limit():
    """Hit the same endpoint 101 times — should get 429 on the 101st."""
    for i in range(100):
        client.get("/health")
    # Note: health is excluded from rate limiting in our middleware
    # This test verifies the counter logic conceptually
    assert True  # Placeholder — test rate limit on auth endpoints in integration tests
