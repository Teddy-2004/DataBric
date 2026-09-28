#!/bin/bash
# ============================================================
# DataBric Relay Node Setup Script
# Run this on a fresh Ubuntu 22.04 VPS (DigitalOcean/Hetzner)
# Usage: sudo bash setup_relay.sh <node_id> <region> <city> <backend_url>
# Example: sudo bash setup_relay.sh nairobi-1 KE Nairobi https://api.databric.app
# ============================================================

set -e

NODE_ID=${1:-"relay-1"}
REGION=${2:-"KE"}
CITY=${3:-"Nairobi"}
BACKEND_URL=${4:-"https://api.databric.app"}
RELAY_SECRET=${RELAY_SECRET:-"change-this-secret"}
PORT=8443

echo "============================================"
echo "DataBric Relay Setup: $NODE_ID ($CITY, $REGION)"
echo "============================================"

# ── System update ──────────────────────────────────────────────
apt-get update -qq
apt-get install -y curl wget jq python3 python3-pip ufw

# ── Install Xray-core ──────────────────────────────────────────
echo "Installing Xray-core..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# ── Generate VLESS Reality keys ────────────────────────────────
echo "Generating Reality keypair..."
KEYS=$(xray x25519)
PRIVATE_KEY=$(echo "$KEYS" | grep "Private key" | awk '{print $NF}')
PUBLIC_KEY=$(echo "$KEYS" | grep "Public key" | awk '{print $NF}')
SHORT_ID=$(openssl rand -hex 4)

echo "Private Key: $PRIVATE_KEY"
echo "Public Key:  $PUBLIC_KEY"
echo "Short ID:    $SHORT_ID"

# Save keys securely
mkdir -p /etc/databric
cat > /etc/databric/keys.env << EOF
PRIVATE_KEY=$PRIVATE_KEY
PUBLIC_KEY=$PUBLIC_KEY
SHORT_ID=$SHORT_ID
NODE_ID=$NODE_ID
RELAY_SECRET=$RELAY_SECRET
BACKEND_URL=$BACKEND_URL
EOF
chmod 600 /etc/databric/keys.env

# ── Write Xray config ──────────────────────────────────────────
echo "Writing Xray config..."
cat > /usr/local/etc/xray/config.json << EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": $PORT,
    "protocol": "vless",
    "settings": {
      "clients": [],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "www.google.com:443",
        "xver": 0,
        "serverNames": ["www.google.com"],
        "privateKey": "$PRIVATE_KEY",
        "shortIds": ["$SHORT_ID"]
      }
    }
  }],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "blocked" }
  ],
  "api": {
    "tag": "api",
    "services": ["HandlerService", "StatsService"]
  },
  "stats": {},
  "policy": {
    "levels": { "0": { "statsUserUplink": true, "statsUserDownlink": true } },
    "system": { "statsInboundUplink": true, "statsInboundDownlink": true }
  },
  "routing": {
    "rules": [{ "inboundTag": ["api"], "outboundTag": "api", "type": "field" }]
  }
}
EOF

# ── Firewall ───────────────────────────────────────────────────
echo "Configuring firewall..."
ufw allow ssh
ufw allow $PORT/tcp
ufw allow 62789/tcp  # Xray API port (internal only — restrict to localhost)
ufw --force enable

# ── Start Xray ─────────────────────────────────────────────────
systemctl enable xray
systemctl restart xray
sleep 2
systemctl status xray --no-pager

# ── Install relay monitor ──────────────────────────────────────
echo "Installing relay monitor..."
pip3 install httpx psutil --break-system-packages -q

cat > /usr/local/bin/databric-monitor.py << 'PYEOF'
#!/usr/bin/env python3
"""
DataBric relay node monitor.
Runs every 30s: reports health to backend and processes usage stats.
"""
import asyncio
import httpx
import psutil
import json
import os
import subprocess
from pathlib import Path

# Load config
env = {}
for line in Path("/etc/databric/keys.env").read_text().splitlines():
    if "=" in line:
        k, v = line.split("=", 1)
        env[k.strip()] = v.strip()

NODE_ID = env.get("NODE_ID", "unknown")
PUBLIC_KEY = env.get("PUBLIC_KEY", "")
SHORT_ID = env.get("SHORT_ID", "")
RELAY_SECRET = env.get("RELAY_SECRET", "")
BACKEND_URL = env.get("BACKEND_URL", "")
REGION = os.environ.get("REGION", "KE")
CITY = os.environ.get("CITY", "Nairobi")
PORT = int(os.environ.get("PORT", "8443"))


def get_public_ip() -> str:
    try:
        import urllib.request
        return urllib.request.urlopen("https://api.ipify.org", timeout=5).read().decode()
    except:
        return "unknown"


def get_active_sessions() -> int:
    try:
        result = subprocess.run(
            ["xray", "api", "statssys", "--server=127.0.0.1:62789"],
            capture_output=True, text=True, timeout=5
        )
        return 0  # Parse from result in production
    except:
        return 0


async def register():
    async with httpx.AsyncClient() as client:
        resp = await client.post(
            f"{BACKEND_URL}/relay/register",
            json={
                "node_id": NODE_ID,
                "host": get_public_ip(),
                "port": PORT,
                "region": REGION,
                "city": CITY,
                "public_key": PUBLIC_KEY,
                "relay_secret": RELAY_SECRET,
            },
            timeout=10.0,
        )
        print(f"Register: {resp.status_code}")


async def heartbeat():
    async with httpx.AsyncClient() as client:
        resp = await client.post(
            f"{BACKEND_URL}/relay/heartbeat",
            json={
                "node_id": NODE_ID,
                "relay_secret": RELAY_SECRET,
                "active_sessions": get_active_sessions(),
                "cpu_percent": psutil.cpu_percent(),
                "memory_percent": psutil.virtual_memory().percent,
            },
            timeout=10.0,
        )
        print(f"Heartbeat: {resp.status_code}")


async def main():
    print(f"DataBric relay monitor starting: {NODE_ID}")
    await register()

    while True:
        try:
            await heartbeat()
        except Exception as e:
            print(f"Heartbeat error: {e}")
        await asyncio.sleep(30)


if __name__ == "__main__":
    asyncio.run(main())
PYEOF
chmod +x /usr/local/bin/databric-monitor.py

# ── Systemd service for monitor ────────────────────────────────
cat > /etc/systemd/system/databric-monitor.service << EOF
[Unit]
Description=DataBric Relay Monitor
After=network.target xray.service

[Service]
Type=simple
Environment=REGION=$REGION
Environment=CITY=$CITY
Environment=PORT=$PORT
ExecStart=/usr/bin/python3 /usr/local/bin/databric-monitor.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl enable databric-monitor
systemctl start databric-monitor

echo ""
echo "============================================"
echo "Setup complete!"
echo "Node ID:    $NODE_ID"
echo "Public Key: $PUBLIC_KEY"
echo "Short ID:   $SHORT_ID"
echo "Port:       $PORT"
echo ""
echo "Add this to your backend RELAY_NODES env var:"
echo "$REGION:$(get_public_ip || echo 'YOUR_SERVER_IP'):$PORT"
echo "============================================"
