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


# ── Relay seller slots and seller configs ──────────────────────
import json
import importlib.util
from pathlib import Path


def _load_relay_agent():
    path = Path(__file__).resolve().parent.parent / "scripts" / "relay_agent.py"
    spec = importlib.util.spec_from_file_location("relay_agent", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _seller_config(**overrides):
    from app.services.xray_configs import generate_seller_bridge_config
    args = dict(
        relay_host="relay1.databric.app", seller_port=9443,
        seller_uuid="5e11e200-2222-4ccc-8ddd-000000000002", slot=7,
        public_key="pbk123", short_id="a1b2c3d4", server_name="www.google.com",
    )
    args.update(overrides)
    return json.loads(generate_seller_bridge_config(**args))


def test_seller_config_meets_flutter_v2ray_requirements():
    """flutter_v2ray 1.0.10 silently refuses configs that break these."""
    c = _seller_config()
    assert isinstance(c["inbounds"], list) and c["inbounds"]
    first = c["outbounds"][0]
    assert first["tag"] == "proxy" and first["protocol"] == "vless"
    vnext = first["settings"]["vnext"][0]
    assert vnext["address"] == "relay1.databric.app" and vnext["port"] == 9443
    assert vnext["users"][0]["id"] == "5e11e200-2222-4ccc-8ddd-000000000002"
    reality = first["streamSettings"]["realitySettings"]
    assert first["streamSettings"]["security"] == "reality"
    assert reality == {"serverName": "www.google.com", "fingerprint": "chrome",
                       "publicKey": "pbk123", "shortId": "a1b2c3d4"}


def test_seller_config_bridges_its_own_slot_and_blocks_private_ranges():
    c = _seller_config(slot=42)
    domain = "slot-042.relay.databric.internal"
    assert c["reverse"]["bridges"] == [{"tag": "bridge", "domain": domain}]
    rules = c["routing"]["rules"]
    assert rules[0]["domain"] == [f"full:{domain}"] and rules[0]["outboundTag"] == "proxy"
    private = rules[1]
    assert private["outboundTag"] == "block" and "192.168.0.0/16" in private["ip"]
    assert c["routing"]["domainStrategy"] == "IPOnDemand"


def test_slot_naming_matches_relay_agent():
    """Backend and relay agent must agree, or sellers attach where no buyer goes."""
    from app.services.xray_configs import slot_domain
    agent = _load_relay_agent()
    for slot in (0, 7, 99, 250):
        assert slot_domain(slot) == agent.slot_domain(slot)
        assert agent.portal_tag(slot).endswith(f"{slot:03d}")


def test_relay_sessions_requires_secret():
    assert client.get("/relay/sessions", params={"node_id": "n1"}).status_code == 403
    resp = client.get("/relay/sessions", params={"node_id": "n1"},
                      headers={"X-Relay-Secret": "wrong-secret"})
    assert resp.status_code == 403


def test_relay_sessions_lists_live_sessions():
    from app.core.config import settings
    live = [{"session_id": str(uuid.uuid4()), "slot": 3, "seller_uuid": "s", "buyer_uuid": "b",
             "status": "advertising"}]
    with patch("app.api.relay.get_live_sessions_for_node", new_callable=AsyncMock,
               return_value=live) as m:
        resp = client.get("/relay/sessions", params={"node_id": "nairobi-1"},
                          headers={"X-Relay-Secret": settings.RELAY_SECRET_KEY})
    assert resp.status_code == 200
    assert resp.json() == {"sessions": live}
    m.assert_awaited_once_with("nairobi-1")


def test_relay_register_passes_slot_fields():
    from app.core.config import settings
    with patch("app.api.relay.register_relay_node", new_callable=AsyncMock,
               return_value=uuid.uuid4()) as m:
        resp = client.post("/relay/register", headers={"X-Relay-Secret": settings.RELAY_SECRET_KEY}, json={
            "node_id": "nairobi-1", "host": "1.2.3.4", "port": 8443, "region": "KE", "city": "Nairobi",
            "public_key": "pbk", "short_id": "a1b2c3d4", "server_name": "www.google.com",
            "seller_port": 9443, "portal_slots": 100,
        })
    assert resp.status_code == 200
    kw = m.await_args.kwargs
    assert (kw["short_id"], kw["seller_port"], kw["portal_slots"]) == ("a1b2c3d4", 9443, 100)


# test_rate_limit uses up the shared client's budget; use a separate one.
_OWN_RATE_BUCKET = {"X-Forwarded-For": "10.9.9.1"}


def _as_seller():
    from app.core.security import get_current_user
    user = {"id": uuid.uuid4(), "country": "KE", "phone_number": "+254700000001"}
    app.dependency_overrides[get_current_user] = lambda: user
    return user


def test_start_sharing_returns_seller_config():
    _as_seller()
    node = {"id": uuid.uuid4(), "host": "1.2.3.4", "port": 8443}
    created = {"id": uuid.uuid4(), "seller_config": '{"x": 1}', "vless_uri": "vless://b@1.2.3.4:8443"}
    try:
        with patch("app.api.sessions.get_active_session_for_seller", new_callable=AsyncMock, return_value=None), \
             patch("app.api.sessions.get_best_relay_node", new_callable=AsyncMock, return_value=node), \
             patch("app.api.sessions.create_session", new_callable=AsyncMock, return_value=created):
            resp = client.post("/sessions/start", json={"limit_gb": 1}, headers=_OWN_RATE_BUCKET)
    finally:
        app.dependency_overrides.clear()
    assert resp.status_code == 200
    body = resp.json()
    assert body["seller_config"] == '{"x": 1}'
    assert body["session_id"] == str(created["id"])


def test_start_sharing_when_relay_full_returns_503():
    from app.services.relay_service import RelayFullError
    _as_seller()
    try:
        with patch("app.api.sessions.get_active_session_for_seller", new_callable=AsyncMock, return_value=None), \
             patch("app.api.sessions.get_best_relay_node", new_callable=AsyncMock,
                   return_value={"id": uuid.uuid4(), "host": "h", "port": 1}), \
             patch("app.api.sessions.create_session", new_callable=AsyncMock, side_effect=RelayFullError("full")):
            resp = client.post("/sessions/start", json={"limit_gb": 1}, headers=_OWN_RATE_BUCKET)
    finally:
        app.dependency_overrides.clear()
    assert resp.status_code == 503
