import uuid
import json
import secrets
import logging
import httpx
from datetime import datetime
from app.core.database import fetch, fetchrow, execute, fetchval, get_pool
from app.core.config import settings

logger = logging.getLogger(__name__)


# ── VLESS Reality URI generation ───────────────────────────────

def generate_vless_reality_uri(
    user_uuid: str,
    host: str,
    port: int,
    public_key: str,
    short_id: str,
    server_name: str = "www.google.com",  # SNI — borrowed from real site
) -> str:
    """
    Generate a VLESS+Reality connection URI for the Flutter app.
    The app passes this URI to the Xray-core library to establish the tunnel.

    Format:
    vless://{uuid}@{host}:{port}?
        encryption=none
        &security=reality
        &sni={server_name}
        &fp=chrome           # fingerprint: mimic Chrome TLS
        &pbk={public_key}    # Reality public key
        &sid={short_id}      # Reality short ID
        &type=tcp
        &flow=xtls-rprx-vision  # XTLS Vision flow control
    """
    params = (
        f"encryption=none"
        f"&security=reality"
        f"&sni={server_name}"
        f"&fp=chrome"
        f"&pbk={public_key}"
        f"&sid={short_id}"
        f"&type=tcp"
        f"&flow=xtls-rprx-vision"
        f"&remark=DataBric"
    )
    return f"vless://{user_uuid}@{host}:{port}?{params}"


# ── Relay node selection ───────────────────────────────────────

async def get_best_relay_node(region: str = None) -> dict | None:
    """
    Select the best available relay node.
    Prefers same region as seller if specified.
    Falls back to any active node.
    """
    if region:
        node = await fetchrow(
            """
            SELECT * FROM relay_nodes
            WHERE status = 'active'
            AND region = $1
            ORDER BY active_sessions ASC, last_health_check DESC
            LIMIT 1
            """,
            region
        )
        if node:
            return dict(node)

    # Fallback: any active node with lowest load
    node = await fetchrow(
        """
        SELECT * FROM relay_nodes
        WHERE status = 'active'
        ORDER BY active_sessions ASC, last_health_check DESC
        LIMIT 1
        """
    )
    return dict(node) if node else None


async def register_relay_node(
    node_id: str,
    host: str,
    port: int,
    region: str,
    city: str,
    public_key: str,
) -> uuid.UUID:
    """
    Register or update a relay node in the database.
    Called by relay nodes on startup.
    """
    result = await fetchrow(
        """
        INSERT INTO relay_nodes (node_id, host, port, region, city, public_key, status, active_sessions, last_health_check)
        VALUES ($1, $2, $3, $4, $5, $6, 'active', 0, NOW())
        ON CONFLICT (node_id)
        DO UPDATE SET
            host = EXCLUDED.host,
            port = EXCLUDED.port,
            status = 'active',
            last_health_check = NOW()
        RETURNING id
        """,
        node_id, host, port, region, city, public_key
    )
    return result["id"]


async def update_node_health(
    node_id: str,
    active_sessions: int,
    cpu_percent: float,
    memory_percent: float,
):
    """Called by relay nodes every 30 seconds."""
    await execute(
        """
        UPDATE relay_nodes
        SET active_sessions = $2,
            cpu_percent = $3,
            memory_percent = $4,
            last_health_check = NOW()
        WHERE node_id = $1
        """,
        node_id, active_sessions, cpu_percent, memory_percent
    )


async def mark_node_blocked(node_id: str, carrier: str):
    """
    Mark a relay node as blocked by a specific carrier.
    The IP rotation system picks this up and assigns a new IP.
    """
    await execute(
        """
        INSERT INTO carrier_blocks (relay_node_id, carrier, detected_at)
        SELECT id, $2, NOW()
        FROM relay_nodes WHERE node_id = $1
        """,
        node_id, carrier
    )
    logger.warning(f"Relay node {node_id} blocked by carrier: {carrier}")


# ── Session management ─────────────────────────────────────────

async def create_session(
    seller_id: uuid.UUID,
    limit_gb: float,
    relay_node: dict,
    receiver_id: uuid.UUID | None = None,
) -> dict:
    """
    Create a new sharing session in ADVERTISING state.
    Returns session record with VLESS URI.
    """
    limit_bytes = int(limit_gb * 1024 * 1024 * 1024)

    # Generate unique VLESS user UUID for this session
    vless_uuid = str(uuid.uuid4())
    short_id = secrets.token_hex(4)  # 8-char hex

    session = await fetchrow(
        """
        INSERT INTO sharing_sessions
            (seller_id, buyer_id, relay_node_id, limit_bytes, used_bytes, 
            status, vless_uuid, short_id, receiver_id, started_at)
        VALUES ($1, $2, $3, $4, 0, 'advertising', $5, $6, $7, NOW())
        RETURNING *
        """,
        seller_id,
        None,
        relay_node["id"],
        limit_bytes,
        vless_uuid,
        short_id,
        receiver_id,  # new
    )

    vless_uri = generate_vless_reality_uri(
        user_uuid=vless_uuid,
        host=relay_node["host"],
        port=relay_node["port"],
        public_key=relay_node["public_key"],
        short_id=short_id,
    )

    return {**dict(session), "vless_uri": vless_uri}


async def connect_buyer_to_session(
    session_id: uuid.UUID,
    buyer_id: uuid.UUID,
) -> dict:
    """
    Connect a buyer to an advertising session.
    Transitions session from ADVERTISING → CONNECTED.
    """
    session = await fetchrow(
        """
        UPDATE sharing_sessions
        SET buyer_id = $2, status = 'connected'
        WHERE id = $1 AND status = 'advertising' AND buyer_id IS NULL
        RETURNING *
        """,
        session_id, buyer_id
    )
    if not session:
        raise ValueError("Session not available or already taken")
    return dict(session)


async def process_usage_heartbeat(
    session_id: uuid.UUID,
    bytes_delta: int,
    heartbeat_id: uuid.UUID,
) -> dict:
    """
    Process usage update from relay node.

    Idempotent on `heartbeat_id`: if the relay retries a delivery the
    second call returns the current session state without re-counting
    bytes. The dedupe row is inserted FIRST and only on a fresh insert
    do we apply the byte delta — both inside one connection.
    """
    pool = await get_pool()
    async with pool.acquire() as conn:
        async with conn.transaction():
            # First-write-wins on heartbeat_id. If the row already exists
            # (retry), this returns no row and we skip the byte update.
            inserted = await conn.fetchrow(
                """
                INSERT INTO usage_events (session_id, bytes_delta, heartbeat_id, recorded_at)
                VALUES ($1, $2, $3, NOW())
                ON CONFLICT (heartbeat_id) DO NOTHING
                RETURNING id
                """,
                session_id, bytes_delta, heartbeat_id,
            )

            if inserted is None:
                # Replay — just report current state, no double counting.
                row = await conn.fetchrow(
                    "SELECT used_bytes, limit_bytes, status FROM sharing_sessions WHERE id = $1",
                    session_id,
                )
                if not row:
                    return {"terminate": True, "reason": "session_not_found"}
                s = dict(row)
                usage_percent = s["used_bytes"] / s["limit_bytes"] if s["limit_bytes"] > 0 else 0
                return {
                    "session_id": str(session_id),
                    "used_bytes": s["used_bytes"],
                    "limit_bytes": s["limit_bytes"],
                    "usage_percent": usage_percent,
                    "status": s["status"],
                    "terminate": s["status"] in ("ended", "terminated"),
                    "warn": usage_percent >= settings.SESSION_WARNING_THRESHOLD,
                    "deduped": True,
                }

            session = await conn.fetchrow(
                """
                UPDATE sharing_sessions
                SET used_bytes = used_bytes + $2,
                    status = CASE
                        WHEN used_bytes + $2 >= limit_bytes THEN 'ended'
                        WHEN status = 'connected' THEN 'transferring'
                        ELSE status
                    END,
                    end_reason = CASE
                        WHEN used_bytes + $2 >= limit_bytes THEN 'limit_reached'
                        ELSE end_reason
                    END,
                    ended_at = CASE
                        WHEN used_bytes + $2 >= limit_bytes THEN NOW()
                        ELSE ended_at
                    END
                WHERE id = $1 AND status IN ('connected', 'transferring')
                RETURNING *
                """,
                session_id, bytes_delta,
            )

    if not session:
        return {"terminate": True, "reason": "session_not_found"}

    s = dict(session)
    usage_percent = s["used_bytes"] / s["limit_bytes"] if s["limit_bytes"] > 0 else 0

    return {
        "session_id": str(session_id),
        "used_bytes": s["used_bytes"],
        "limit_bytes": s["limit_bytes"],
        "usage_percent": usage_percent,
        "status": s["status"],
        "terminate": s["status"] in ("ended", "terminated"),
        "warn": usage_percent >= settings.SESSION_WARNING_THRESHOLD,
    }


async def terminate_session(
    session_id: uuid.UUID,
    end_reason: str = "seller_stopped",
):
    """
    Forcefully end a session.

    Writes status='ended' for the normal user-initiated stops
    (seller_stopped / buyer_disconnected) so history rendering and
    notifications can treat them uniformly. Reserves 'terminated' for
    abuse/admin kills via end_reason='admin_terminated'.
    """
    target_status = "terminated" if end_reason == "admin_terminated" else "ended"
    await execute(
        """
        UPDATE sharing_sessions
        SET status = $2,
            end_reason = $3,
            ended_at = NOW()
        WHERE id = $1 AND status NOT IN ('ended', 'terminated')
        """,
        session_id, target_status, end_reason,
    )
    logger.info(f"Session {session_id} ended: {end_reason}")


async def get_active_session_for_seller(seller_id: uuid.UUID) -> dict | None:
    row = await fetchrow(
        """
        SELECT s.*, rn.host, rn.port, rn.public_key
        FROM sharing_sessions s
        JOIN relay_nodes rn ON rn.id = s.relay_node_id
        WHERE s.seller_id = $1
        AND s.status IN ('advertising', 'connected', 'transferring')
        ORDER BY s.started_at DESC
        LIMIT 1
        """,
        seller_id
    )
    return dict(row) if row else None
