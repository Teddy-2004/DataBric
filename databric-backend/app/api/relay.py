from fastapi import APIRouter, HTTPException, status, Header
from app.models.schemas import (
    UsageHeartbeat, RelayNodeRegister, NodeHealthPing, APIResponse
)
from app.services.relay_service import (
    register_relay_node, update_node_health,
    process_usage_heartbeat, mark_node_blocked
)
from app.services.notification_service import (
    notify_usage_warning, notify_session_ended
)
from app.core.database import fetchrow
from app.core.security import verify_relay_secret
import logging

router = APIRouter(prefix="/relay", tags=["relay-internal"])
logger = logging.getLogger(__name__)


def _require_relay(secret: str | None):
    if not verify_relay_secret(secret):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Invalid relay secret"
        )


@router.post("/register", response_model=APIResponse)
async def relay_register(
    body: RelayNodeRegister,
    x_relay_secret: str | None = Header(default=None, alias="X-Relay-Secret"),
):
    """
    Called by a relay node when it starts up.
    Registers the node's host, port, region, and VLESS Reality public key.
    """
    _require_relay(x_relay_secret)

    node_db_id = await register_relay_node(
        node_id=body.node_id,
        host=body.host,
        port=body.port,
        region=body.region,
        city=body.city,
        public_key=body.public_key or "",
    )

    logger.info(f"Relay node registered: {body.node_id} @ {body.host}:{body.port}")
    return APIResponse(message="Node registered", data={"db_id": str(node_db_id)})


@router.post("/heartbeat", response_model=APIResponse)
async def node_heartbeat(
    body: NodeHealthPing,
    x_relay_secret: str | None = Header(default=None, alias="X-Relay-Secret"),
):
    """
    Called by relay nodes every 30 seconds to report health.
    Backend uses this to detect dead nodes and rebalance traffic.
    """
    _require_relay(x_relay_secret)
    await update_node_health(
        node_id=body.node_id,
        active_sessions=body.active_sessions,
        cpu_percent=body.cpu_percent,
        memory_percent=body.memory_percent,
    )
    return APIResponse(message="OK")


@router.post("/usage", response_model=dict)
async def report_usage(
    body: UsageHeartbeat,
    x_relay_secret: str | None = Header(default=None, alias="X-Relay-Secret"),
):
    """
    Called by relay node every 5 seconds per active session.
    Reports bytes transferred since last call. Idempotent on heartbeat_id —
    retrying the same heartbeat will not double-count bytes.

    Returns:
    - terminate: bool — relay must close the session if True
    - warn: bool — relay should push warning notification if True
    """
    _require_relay(x_relay_secret)

    result = await process_usage_heartbeat(
        session_id=body.session_id,
        bytes_delta=body.bytes_delta,
        heartbeat_id=body.heartbeat_id,
    )

    if result.get("terminate") and result.get("reason") == "session_not_found":
        return {"terminate": True, "warn": False}

    # Send warning notification at 95% usage
    if result.get("warn"):
        session = await fetchrow(
            "SELECT seller_id, limit_bytes, used_bytes FROM sharing_sessions WHERE id = $1",
            body.session_id
        )
        if session:
            s = dict(session)
            used_gb = round(s["used_bytes"] / (1024**3), 2)
            limit_gb = round(s["limit_bytes"] / (1024**3), 2)
            await notify_usage_warning(s["seller_id"], used_gb, limit_gb)

    # Send end notifications if session terminated by limit
    if result.get("terminate") and result.get("status") == "ended":
        session = await fetchrow(
            "SELECT seller_id, buyer_id, used_bytes FROM sharing_sessions WHERE id = $1",
            body.session_id
        )
        if session:
            s = dict(session)
            used_gb = round(s["used_bytes"] / (1024**3), 3)
            if s.get("seller_id"):
                await notify_session_ended(s["seller_id"], used_gb, "limit_reached")
            if s.get("buyer_id"):
                await notify_session_ended(s["buyer_id"], used_gb, "limit_reached")

    return result


@router.post("/blocked", response_model=APIResponse)
async def report_blocked(
    node_id: str,
    carrier: str,
    x_relay_secret: str | None = Header(default=None, alias="X-Relay-Secret"),
):
    """
    Called by monitoring service when a relay IP is detected as blocked
    by a specific carrier. Triggers IP rotation.
    """
    _require_relay(x_relay_secret)
    await mark_node_blocked(node_id, carrier)
    return APIResponse(message=f"Block recorded: {node_id} by {carrier}")
