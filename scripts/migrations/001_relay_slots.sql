-- ============================================================
-- 001: relay seller slots and per-session seller credentials
--
-- Run once in the Supabase SQL editor, before deploying the backend that
-- uses it. Safe to run again.
-- ============================================================

-- Relay nodes: what the relay agent reports when it registers.
ALTER TABLE relay_nodes ADD COLUMN IF NOT EXISTS short_id     TEXT    NOT NULL DEFAULT '';
ALTER TABLE relay_nodes ADD COLUMN IF NOT EXISTS server_name  TEXT    NOT NULL DEFAULT 'www.google.com';
ALTER TABLE relay_nodes ADD COLUMN IF NOT EXISTS seller_port  INTEGER NOT NULL DEFAULT 9443;
ALTER TABLE relay_nodes ADD COLUMN IF NOT EXISTS portal_slots INTEGER NOT NULL DEFAULT 0;

-- Sessions: the seller's own credentials and the relay slot it holds.
-- vless_uuid stays the buyer's credential.
ALTER TABLE sharing_sessions ADD COLUMN IF NOT EXISTS seller_uuid TEXT;
ALTER TABLE sharing_sessions ADD COLUMN IF NOT EXISTS relay_slot  INTEGER;

-- Already used by the backend; added here in case the table predates it.
ALTER TABLE sharing_sessions ADD COLUMN IF NOT EXISTS receiver_id UUID REFERENCES users(id);

-- A slot belongs to at most one live session per relay.
CREATE UNIQUE INDEX IF NOT EXISTS uq_sessions_live_slot
    ON sharing_sessions (relay_node_id, relay_slot)
    WHERE status IN ('advertising', 'connected', 'transferring')
      AND relay_slot IS NOT NULL;

-- Slot picking looks at each slot's last use.
CREATE INDEX IF NOT EXISTS idx_sessions_node_slot
    ON sharing_sessions (relay_node_id, relay_slot);
