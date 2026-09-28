-- ============================================================
-- DataBric Database Schema
-- Run this in the Supabase SQL editor to set up the database.
-- ============================================================

-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ── Users ────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS users (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    phone_number    TEXT UNIQUE NOT NULL,
    display_name    TEXT,
    carrier         TEXT,
    city            TEXT,
    country         TEXT,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_users_phone ON users(phone_number);

-- ── Devices (for push notifications) ─────────────────────────
CREATE TABLE IF NOT EXISTS devices (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    fcm_token   TEXT,
    platform    TEXT NOT NULL DEFAULT 'android',
    app_version TEXT,
    last_seen   TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (user_id, platform)
);

CREATE INDEX idx_devices_user ON devices(user_id);

-- ── Friendships ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS friendships (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_a_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    user_b_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    status          TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'accepted', 'blocked')),
    initiated_by    UUID NOT NULL REFERENCES users(id),
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (user_a_id, user_b_id),
    CHECK (user_a_id != user_b_id)
);

CREATE INDEX idx_friendships_a ON friendships(user_a_id);
CREATE INDEX idx_friendships_b ON friendships(user_b_id);

-- ── Relay nodes ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS relay_nodes (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    node_id             TEXT UNIQUE NOT NULL,   -- human-readable e.g. "nairobi-1"
    host                TEXT NOT NULL,
    port                INTEGER NOT NULL DEFAULT 8443,
    region              TEXT NOT NULL,           -- country code e.g. "KE"
    city                TEXT NOT NULL,
    public_key          TEXT NOT NULL DEFAULT '', -- VLESS Reality public key
    status              TEXT NOT NULL DEFAULT 'active'
                        CHECK (status IN ('active', 'blocked', 'retired')),
    active_sessions     INTEGER DEFAULT 0,
    cpu_percent         FLOAT DEFAULT 0,
    memory_percent      FLOAT DEFAULT 0,
    last_health_check   TIMESTAMPTZ DEFAULT NOW(),
    created_at          TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_relay_nodes_status ON relay_nodes(status);
CREATE INDEX idx_relay_nodes_region ON relay_nodes(region);

-- ── Sharing sessions ──────────────────────────────────────────
CREATE TABLE IF NOT EXISTS sharing_sessions (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    seller_id       UUID NOT NULL REFERENCES users(id),
    buyer_id        UUID REFERENCES users(id),
    relay_node_id   UUID REFERENCES relay_nodes(id),

    -- VLESS Reality session credentials
    vless_uuid      TEXT NOT NULL,
    short_id        TEXT NOT NULL,

    -- Data limits
    limit_bytes     BIGINT NOT NULL,
    used_bytes      BIGINT NOT NULL DEFAULT 0,

    -- State machine
    status          TEXT NOT NULL DEFAULT 'advertising'
                    CHECK (status IN (
                        'advertising',
                        'connected',
                        'transferring',
                        'ended',
                        'terminated'
                    )),
    end_reason      TEXT CHECK (end_reason IN (
                        'seller_stopped',
                        'buyer_disconnected',
                        'limit_reached',
                        'admin_terminated'
                    )),

    started_at      TIMESTAMPTZ DEFAULT NOW(),
    ended_at        TIMESTAMPTZ,

    CHECK (used_bytes >= 0),
    CHECK (used_bytes <= limit_bytes + 1048576) -- allow 1MB overflow for timing
);

CREATE INDEX idx_sessions_seller ON sharing_sessions(seller_id);
CREATE INDEX idx_sessions_buyer ON sharing_sessions(buyer_id);
CREATE INDEX idx_sessions_status ON sharing_sessions(status);
CREATE INDEX idx_sessions_active ON sharing_sessions(seller_id, status)
    WHERE status IN ('advertising', 'connected', 'transferring');

-- ── Usage events (granular log) ───────────────────────────────
CREATE TABLE IF NOT EXISTS usage_events (
    id           BIGSERIAL PRIMARY KEY,
    session_id   UUID NOT NULL REFERENCES sharing_sessions(id) ON DELETE CASCADE,
    bytes_delta  BIGINT NOT NULL CHECK (bytes_delta >= 0),
    heartbeat_id UUID UNIQUE,  -- supplied by relay for idempotency
    recorded_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_usage_events_session ON usage_events(session_id);

-- ── Carrier blocking log ──────────────────────────────────────
CREATE TABLE IF NOT EXISTS carrier_blocks (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    relay_node_id   UUID NOT NULL REFERENCES relay_nodes(id),
    carrier         TEXT NOT NULL,
    detected_at     TIMESTAMPTZ DEFAULT NOW(),
    resolved_at     TIMESTAMPTZ
);

CREATE INDEX idx_carrier_blocks_node ON carrier_blocks(relay_node_id);

-- ── OTP store (optional — use if not using in-memory) ─────────
CREATE TABLE IF NOT EXISTS otp_codes (
    phone_number    TEXT PRIMARY KEY,
    otp_hash        TEXT NOT NULL,
    expires_at      TIMESTAMPTZ NOT NULL,
    attempts        INTEGER DEFAULT 0
);

-- ── Triggers: updated_at ──────────────────────────────────────
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ── Row Level Security ────────────────────────────────────────
-- Enable RLS on all tables
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE friendships ENABLE ROW LEVEL SECURITY;
ALTER TABLE sharing_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE usage_events ENABLE ROW LEVEL SECURITY;

-- Service role bypasses RLS (our backend uses service role key)
-- These policies apply only when accessed via anon/user JWT directly

CREATE POLICY "users: service role full access"
    ON users FOR ALL TO service_role USING (true);

CREATE POLICY "devices: service role full access"
    ON devices FOR ALL TO service_role USING (true);

CREATE POLICY "friendships: service role full access"
    ON friendships FOR ALL TO service_role USING (true);

CREATE POLICY "sessions: service role full access"
    ON sharing_sessions FOR ALL TO service_role USING (true);

CREATE POLICY "usage_events: service role full access"
    ON usage_events FOR ALL TO service_role USING (true);

-- ── Seed: development relay node ──────────────────────────────
-- Replace with real values when you deploy your first relay
INSERT INTO relay_nodes (node_id, host, port, region, city, public_key, status)
VALUES (
    'nairobi-dev-1',
    'relay1.databric.app',
    8443,
    'KE',
    'Nairobi',
    'REPLACE_WITH_REAL_VLESS_REALITY_PUBLIC_KEY',
    'active'
) ON CONFLICT (node_id) DO NOTHING;

-- ── Migration helpers (idempotent) ────────────────────────────
-- Safe to re-run if upgrading an existing deployment created before these columns existed.
ALTER TABLE sharing_sessions
    ADD COLUMN IF NOT EXISTS end_reason TEXT
    CHECK (end_reason IS NULL OR end_reason IN (
        'seller_stopped', 'buyer_disconnected', 'limit_reached', 'admin_terminated'
    ));

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name='usage_events' AND column_name='bytes_delta' AND data_type='integer'
    ) THEN
        ALTER TABLE usage_events ALTER COLUMN bytes_delta TYPE BIGINT;
    END IF;
END$$;

ALTER TABLE usage_events ADD COLUMN IF NOT EXISTS heartbeat_id UUID;
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE tablename = 'usage_events' AND indexname = 'usage_events_heartbeat_id_key'
    ) THEN
        ALTER TABLE usage_events ADD CONSTRAINT usage_events_heartbeat_id_key UNIQUE (heartbeat_id);
    END IF;
END$$;
