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
def _request(xff=None, peer="203.0.113.10"):
    from starlette.requests import Request
    headers = [] if xff is None else [(b"x-forwarded-for", xff.encode())]
    return Request({"type": "http", "headers": headers, "client": (peer, 1234)})


def test_client_ip_ignores_forged_forwarded_for():
    """Behind one proxy, only the entry that proxy appended is believed."""
    from app.middleware.logging import client_ip
    # Client forged "1.2.3.4"; the proxy appended the real address.
    assert client_ip(_request("1.2.3.4, 198.51.100.7"), 1) == "198.51.100.7"
    # No forgery: the proxy's entry is the only one.
    assert client_ip(_request("198.51.100.7"), 1) == "198.51.100.7"
    # Two proxies: the outer one's entry, two from the right.
    assert client_ip(_request("1.2.3.4, 198.51.100.7, 10.0.0.2"), 2) == "198.51.100.7"


def test_client_ip_falls_back_to_the_connection():
    from app.middleware.logging import client_ip
    # No proxy configured: the header is ignored entirely.
    assert client_ip(_request("1.2.3.4"), 0) == "203.0.113.10"
    # No header, or garbage in the trusted position.
    assert client_ip(_request(None), 1) == "203.0.113.10"
    assert client_ip(_request("1.2.3.4, not-an-ip"), 1) == "203.0.113.10"


def test_rate_limit_cannot_be_dodged_with_forged_headers():
    """A client rotating forged X-Forwarded-For values still hits the limit."""
    from fastapi import FastAPI
    from app.middleware.logging import RateLimitMiddleware

    mini = FastAPI()
    mini.add_middleware(RateLimitMiddleware, max_requests=5, window_seconds=60)

    @mini.get("/ping")
    def ping():
        return {"ok": True}

    c = TestClient(mini)
    # Render's three proxies: the first appends the real client address,
    # the other two their own internal ones.
    render = "172.70.1.1, 10.24.242.28"
    real = "198.51.100.7"
    codes = [
        c.get("/ping", headers={"X-Forwarded-For": f"10.0.0.{i}, {real}, {render}"}).status_code
        for i in range(7)
    ]
    assert codes == [200] * 5 + [429] * 2

    # A different real client has its own budget.
    other = {"X-Forwarded-For": f"198.51.100.8, {render}"}
    assert c.get("/ping", headers=other).status_code == 200


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
        seller_uuid="5e11e200-2222-4ccc-8ddd-000000000002",
        public_key="pbk123", short_id="a1b2c3d4", server_name="www.google.com",
    )
    args.update(overrides)
    return json.loads(generate_seller_bridge_config(**args))


def test_seller_config_meets_flutter_v2ray_client_requirements():
    """flutter_v2ray_client 3.5.0 refuses configs that break these."""
    c = _seller_config()
    assert isinstance(c["inbounds"], list) and c["inbounds"]
    first = c["outbounds"][0]
    assert first["tag"] == "proxy" and first["protocol"] == "vless"
    # The plugin reads settings.vnext[0] or settings.servers[0]; "vnext" would
    # switch Xray to the old outbound format, where reverse doesn't work.
    assert "vnext" not in first["settings"]
    assert first["settings"]["servers"][0] == {"address": "relay1.databric.app", "port": 9443}
    reality = first["streamSettings"]["realitySettings"]
    assert first["streamSettings"]["security"] == "reality"
    assert reality == {"serverName": "www.google.com", "fingerprint": "chrome",
                       "publicKey": "pbk123", "shortId": "a1b2c3d4"}


def test_seller_config_is_a_vless_reverse_tunnel_that_blocks_private_ranges():
    c = _seller_config()
    vless = c["outbounds"][0]["settings"]
    assert vless["address"] == "relay1.databric.app" and vless["port"] == 9443
    assert vless["id"] == "5e11e200-2222-4ccc-8ddd-000000000002"
    assert vless["reverse"] == {"tag": "r-in"}
    assert "reverse" not in c  # Xray 26 rejects the old reverse section
    rules = c["routing"]["rules"]
    private = rules[0]
    assert private["inboundTag"] == ["r-in"] and private["outboundTag"] == "block"
    assert "192.168.0.0/16" in private["ip"]
    assert rules[1] == {"type": "field", "inboundTag": ["r-in"], "outboundTag": "direct"}
    assert c["routing"]["domainStrategy"] == "IPOnDemand"


def test_relay_agent_adds_sellers_with_their_reverse_tag():
    """The seller's account carries the session's reverse tag, and only the
    session's buyer is routed to it."""
    agent = _load_relay_agent()
    sid = "3f1c0000-0000-4000-8000-000000000001"
    req = agent.encode_add_vless_user("seller-in", f"s-{sid}", "u-1", reverse=agent.reverse_tag(sid))
    assert f"r-{sid}".encode() in req
    plain = agent.encode_add_vless_user("buyer-in", f"b-{sid}", "u-2", flow="xtls-rprx-vision")
    assert f"r-{sid}".encode() not in plain
    (rule,) = agent.session_rules(sid)
    assert rule["user"] == [f"b-{sid}"] and rule["outboundTag"] == f"r-{sid}"
    cfg = agent.render_xray_config(agent.load_settings(None))
    assert "reverse" not in cfg


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


# ── Relay agent: usage metering and reporting ──────────────────
import urllib.error


class _FakeXray:
    def __init__(self):
        self.traffic = {}
        self.removed = []

    def buyer_traffic(self):
        return dict(self.traffic)

    def remove_rules(self, tags):
        self.removed += list(tags)

    def remove_user(self, tag, email):
        self.removed.append(email)
        return True


class _FakeBackend:
    def __init__(self):
        self.calls = []        # (session_id, bytes_delta, heartbeat_id) attempts
        self.behaviour = "ok"  # "ok" | "down" | "refuse" | "terminate"

    def report_usage(self, session_id, bytes_delta, heartbeat_id):
        self.calls.append((session_id, bytes_delta, heartbeat_id))
        if self.behaviour == "down":
            raise urllib.error.URLError("connection refused")
        if self.behaviour == "refuse":
            raise urllib.error.HTTPError("u", 500, "err", {}, None)
        return {"terminate": self.behaviour == "terminate"}

    def live_sessions(self, node_id):
        return []


def _agent(tmp_path, xray=None, backend=None):
    ra = _load_relay_agent()
    s = ra.load_settings(None)
    s["STATE_FILE"] = str(tmp_path / "state.json")
    agent = ra.Agent(s, xray or _FakeXray(), backend or _FakeBackend())
    return ra, agent


def test_parse_user_traffic_sums_up_and_down():
    ra = _load_relay_agent()
    out = json.dumps({"stat": [
        {"name": "user>>>b-1>>>traffic>>>uplink", "value": "100"},
        {"name": "user>>>b-1>>>traffic>>>downlink", "value": 900},
        {"name": "user>>>b-2>>>traffic>>>downlink"},  # zero values omit "value"
        {"name": "inbound>>>buyer-in>>>traffic>>>uplink", "value": 5},
    ]})
    assert ra.parse_user_traffic(out) == {"b-1": 1000, "b-2": 0}
    assert ra.parse_user_traffic("") == {}


def test_usage_retries_keep_heartbeat_id_and_never_double_count(tmp_path):
    xray, backend = _FakeXray(), _FakeBackend()
    ra, agent = _agent(tmp_path, xray, backend)
    agent.applied = {"s1": {"slot": 1}}
    xray.traffic = {"b-s1": 1000}
    agent.meter()
    backend.behaviour = "down"
    agent.flush_usage()
    agent.flush_usage()
    assert len(agent.outbox) == 1
    first_id = agent.outbox[0]["heartbeat_id"]
    assert {c[2] for c in backend.calls} == {first_id}  # retried with the same id

    xray.traffic = {"b-s1": 1500}
    agent.meter()
    backend.behaviour = "ok"
    agent.flush_usage()
    assert agent.outbox == []
    delivered = [c for c in backend.calls[-2:]]
    assert [c[1] for c in delivered] == [1000, 500]
    assert delivered[0][2] == first_id


def test_queued_usage_survives_agent_restart(tmp_path):
    xray, backend = _FakeXray(), _FakeBackend()
    ra, agent = _agent(tmp_path, xray, backend)
    agent.applied = {"s1": {"slot": 1}}
    xray.traffic = {"b-s1": 4096}
    agent.meter()
    queued = list(agent.outbox)
    _, restarted = _agent(tmp_path, xray, backend)
    assert restarted.outbox == queued
    assert restarted.applied["s1"]["counted"] == 4096


def test_counter_reset_counts_only_new_traffic(tmp_path):
    xray = _FakeXray()
    ra, agent = _agent(tmp_path, xray)
    agent.applied = {"s1": {"slot": 1, "counted": 5000}}
    xray.traffic = {"b-s1": 300}  # Xray restarted, counters began again
    agent.meter()
    assert [i["bytes_delta"] for i in agent.outbox] == [300]


def test_refused_report_is_dropped_after_max_attempts(tmp_path):
    xray, backend = _FakeXray(), _FakeBackend()
    ra, agent = _agent(tmp_path, xray, backend)
    agent.applied = {"s1": {"slot": 1}}
    xray.traffic = {"b-s1": 10}
    agent.meter()
    backend.behaviour = "refuse"
    for _ in range(agent.MAX_REPORT_ATTEMPTS):
        agent.flush_usage()
    assert agent.outbox == []  # dropped, so it cannot block later reports


def test_backend_ending_a_session_removes_it_at_once(tmp_path):
    xray, backend = _FakeXray(), _FakeBackend()
    ra, agent = _agent(tmp_path, xray, backend)
    agent.applied = {"s1": {"slot": 1}}
    xray.traffic = {"b-s1": 10}
    backend.behaviour = "terminate"
    agent.cycle()
    assert "s1" not in agent.applied
    assert "b-s1" in xray.removed and "s-s1" in xray.removed


# ── Restoring the seller's tunnel ──────────────────────────────
def _seller_session_row(**overrides):
    row = {
        "id": uuid.uuid4(), "status": "connected", "relay_slot": 5,
        "seller_uuid": "5e11e200-2222-4ccc-8ddd-000000000009", "short_id": "a1b2c3d4",
        "host": "relay1.databric.app", "port": 8443, "seller_port": 9443,
        "public_key": "pbk123", "server_name": "www.google.com",
    }
    row.update(overrides)
    return row


def test_seller_config_endpoint_rebuilds_the_same_config():
    from app.services.xray_configs import generate_seller_bridge_config
    _as_seller()
    row = _seller_session_row()
    try:
        with patch("app.api.sessions.get_active_session_for_seller", new_callable=AsyncMock, return_value=row):
            resp = client.get("/sessions/seller-config", headers=_OWN_RATE_BUCKET)
    finally:
        app.dependency_overrides.clear()
    assert resp.status_code == 200
    body = resp.json()
    assert body["session_id"] == str(row["id"])
    expected = generate_seller_bridge_config(
        relay_host="relay1.databric.app", seller_port=9443, seller_uuid=row["seller_uuid"],
        public_key="pbk123", short_id="a1b2c3d4", server_name="www.google.com")
    assert body["seller_config"] == expected


def test_seller_config_endpoint_404_without_a_restorable_session():
    _as_seller()
    try:
        with patch("app.api.sessions.get_active_session_for_seller", new_callable=AsyncMock, return_value=None):
            assert client.get("/sessions/seller-config", headers=_OWN_RATE_BUCKET).status_code == 404
        # A session created before relay slots existed has nothing to restore.
        old = _seller_session_row(relay_slot=None, seller_uuid=None)
        with patch("app.api.sessions.get_active_session_for_seller", new_callable=AsyncMock, return_value=old):
            assert client.get("/sessions/seller-config", headers=_OWN_RATE_BUCKET).status_code == 404
    finally:
        app.dependency_overrides.clear()
