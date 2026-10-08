#!/bin/bash
# ============================================================
# DataBric Relay Node Setup
#
# Run on a fresh Ubuntu 22.04/24.04 VPS, from a checkout of the repo
# (needs scripts/relay_agent.py next to this file):
#
#   sudo RELAY_SECRET=<backend RELAY_SECRET_KEY> \
#        bash scripts/setup_relay.sh <node_id> <region> <city> <backend_url>
#
#   e.g. ... setup_relay.sh nairobi-1 KE Nairobi https://databric.onrender.com
#
# Optional env: PUBLIC_HOST (DNS name or IP phones dial; default: detected
# public IP), PORTAL_SLOTS (default 100), BUYER_PORT (8443), SELLER_PORT (9443).
#
# Safe to re-run: keeps the existing Reality keys in /etc/databric/relay.env.
#
# Xray is pinned to v25.3.6, the core bundled in the phone app
# (flutter_v2ray 1.0.10). Newer relays break the reverse-proxy control channel.
# ============================================================

set -euo pipefail

NODE_ID=${1:?usage: setup_relay.sh <node_id> <region> <city> <backend_url>}
REGION=${2:?region (e.g. KE)}
CITY=${3:?city}
BACKEND_URL=${4:?backend url}
RELAY_SECRET=${RELAY_SECRET:-}
BUYER_PORT=${BUYER_PORT:-8443}
SELLER_PORT=${SELLER_PORT:-9443}
PORTAL_SLOTS=${PORTAL_SLOTS:-100}

XRAY_VERSION="v25.3.6"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE=/etc/databric/relay.env
AGENT_DIR=/opt/databric-relay-agent

if [ "$(id -u)" != 0 ]; then echo "Run as root (sudo)."; exit 1; fi
if [ -z "$RELAY_SECRET" ] || [ "$RELAY_SECRET" = "change-this-secret" ]; then
  echo "Set RELAY_SECRET to the backend's RELAY_SECRET_KEY (Render > Environment)."; exit 1
fi
if [ ! -f "$SCRIPT_DIR/relay_agent.py" ]; then
  echo "relay_agent.py not found next to this script. Run it from a checkout of the repo."; exit 1
fi

echo "============================================"
echo "DataBric relay setup: $NODE_ID ($CITY, $REGION)"
echo "============================================"

# ── Packages ───────────────────────────────────────────────────
# iproute2 provides `ss`, which the agent uses to cut ended sellers' connections.
apt-get update -qq
apt-get install -y -qq curl unzip openssl python3 python3-venv iproute2 ufw >/dev/null

# ── Xray, pinned ───────────────────────────────────────────────
case "$(uname -m)" in
  x86_64)  ASSET="Xray-linux-64.zip";        SHA="82d4be3a5ed8bd2621df9c9913c3a2761b86a42ae8485da836f7447ff2ec3d4d" ;;
  aarch64) ASSET="Xray-linux-arm64-v8a.zip"; SHA="1595f446b3d3a2bfe4a737e3cdb4c189c8c4e271322a7a2a0f5ea735b9511e80" ;;
  *) echo "Unsupported CPU: $(uname -m)"; exit 1 ;;
esac
if ! /usr/local/bin/xray version 2>/dev/null | grep -q "^Xray ${XRAY_VERSION#v} "; then
  echo "Installing Xray $XRAY_VERSION..."
  TMP=$(mktemp -d)
  curl -fsSL -o "$TMP/$ASSET" "https://github.com/XTLS/Xray-core/releases/download/$XRAY_VERSION/$ASSET"
  echo "$SHA  $TMP/$ASSET" | sha256sum -c --quiet
  unzip -o -q "$TMP/$ASSET" xray -d "$TMP"
  install -m 755 "$TMP/xray" /usr/local/bin/xray
  rm -rf "$TMP"
fi
/usr/local/bin/xray version | head -1

# ── Keys and settings (kept across re-runs) ────────────────────
mkdir -p /etc/databric
chmod 700 /etc/databric
if [ -f "$ENV_FILE" ] && grep -q '^REALITY_PRIVATE_KEY=.' "$ENV_FILE"; then
  echo "Keeping existing Reality keys from $ENV_FILE"
  PRIVATE_KEY=$(grep '^REALITY_PRIVATE_KEY=' "$ENV_FILE" | cut -d= -f2-)
  PUBLIC_KEY=$(grep '^REALITY_PUBLIC_KEY=' "$ENV_FILE" | cut -d= -f2-)
  SHORT_ID=$(grep '^REALITY_SHORT_ID=' "$ENV_FILE" | cut -d= -f2-)
else
  echo "Generating Reality keypair..."
  KEYS=$(/usr/local/bin/xray x25519)
  PRIVATE_KEY=$(echo "$KEYS" | grep "Private key" | awk '{print $NF}')
  PUBLIC_KEY=$(echo "$KEYS" | grep "Public key" | awk '{print $NF}')
  SHORT_ID=$(openssl rand -hex 4)
fi
if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ] || [ -z "$SHORT_ID" ]; then
  echo "Could not read Reality keys."; exit 1
fi

PUBLIC_HOST=${PUBLIC_HOST:-$(curl -fsS -m 10 https://api.ipify.org || true)}
if [ -z "$PUBLIC_HOST" ]; then echo "Could not detect the public IP; set PUBLIC_HOST."; exit 1; fi

umask 077
cat > "$ENV_FILE" <<EOF
NODE_ID=$NODE_ID
REGION=$REGION
CITY=$CITY
BACKEND_URL=$BACKEND_URL
RELAY_SECRET=$RELAY_SECRET
PUBLIC_HOST=$PUBLIC_HOST
BUYER_PORT=$BUYER_PORT
SELLER_PORT=$SELLER_PORT
PORTAL_SLOTS=$PORTAL_SLOTS
REALITY_PRIVATE_KEY=$PRIVATE_KEY
REALITY_PUBLIC_KEY=$PUBLIC_KEY
REALITY_SHORT_ID=$SHORT_ID
REALITY_DEST=www.google.com:443
REALITY_SERVER_NAME=www.google.com
XRAY_BIN=/usr/local/bin/xray
XRAY_API=127.0.0.1:10085
ACCESS_LOG=/var/log/xray/access.log
ERROR_LOG=/var/log/xray/error.log
STATE_FILE=/var/lib/databric/relay-agent-state.json
EOF
umask 022

# ── Relay agent ────────────────────────────────────────────────
mkdir -p "$AGENT_DIR" /var/lib/databric
install -m 755 "$SCRIPT_DIR/relay_agent.py" "$AGENT_DIR/relay_agent.py"
[ -x "$AGENT_DIR/venv/bin/python" ] || python3 -m venv "$AGENT_DIR/venv"
"$AGENT_DIR/venv/bin/pip" install -q --upgrade "grpcio>=1.60,<2"

# ── Xray config, rendered by the agent so both agree on slots ──
mkdir -p /usr/local/etc/xray /var/log/xray
"$AGENT_DIR/venv/bin/python" "$AGENT_DIR/relay_agent.py" render-config --env "$ENV_FILE" > /usr/local/etc/xray/config.json
chmod 640 /usr/local/etc/xray/config.json
chown root:nogroup /usr/local/etc/xray/config.json
chown nobody:nogroup /var/log/xray
/usr/local/bin/xray run -test -c /usr/local/etc/xray/config.json >/dev/null

cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray (DataBric relay)
After=network-online.target
Wants=network-online.target

[Service]
User=nobody
Group=nogroup
ExecStart=/usr/local/bin/xray run -c /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

# Root: it cuts other processes' TCP connections with `ss -K`.
cat > /etc/systemd/system/databric-relay-agent.service <<EOF
[Unit]
Description=DataBric relay agent
After=network-online.target xray.service
Wants=network-online.target

[Service]
ExecStart=$AGENT_DIR/venv/bin/python $AGENT_DIR/relay_agent.py run --env $ENV_FILE
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# The old monitor is replaced by the agent.
systemctl disable --now databric-monitor 2>/dev/null || true
rm -f /etc/systemd/system/databric-monitor.service /usr/local/bin/databric-monitor.py

# ── Firewall: only the two phone-facing ports (API stays on localhost) ──
ufw allow ssh >/dev/null
ufw allow "$BUYER_PORT/tcp" >/dev/null
ufw allow "$SELLER_PORT/tcp" >/dev/null
ufw delete allow 62789/tcp >/dev/null 2>&1 || true
ufw --force enable >/dev/null

systemctl daemon-reload
systemctl enable xray databric-relay-agent >/dev/null
systemctl restart xray
sleep 1
systemctl restart databric-relay-agent
sleep 3
systemctl --no-pager --lines=0 status xray databric-relay-agent || true

echo ""
echo "============================================"
echo "Relay ready: $NODE_ID"
echo "Phones dial:  $PUBLIC_HOST  (buyers :$BUYER_PORT, sellers :$SELLER_PORT)"
echo "Slots:        $PORTAL_SLOTS"
echo "Public key:   $PUBLIC_KEY"
echo "Short ID:     $SHORT_ID"
echo ""
echo "Agent log:    journalctl -u databric-relay-agent -f"
echo "Look for 'registered $NODE_ID' there; then the backend can use this relay."
echo "============================================"
