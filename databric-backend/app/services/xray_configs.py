"""
Xray configs handed to the phones, and the slot naming shared with the relay.

The relay agent (scripts/relay_agent.py) defines one reverse-proxy portal per
slot and routes each session's seller and buyer to it. slot_domain() must stay
identical to the agent's, or sellers will attach to a slot no buyer reaches.

The phone app runs these configs with flutter_v2ray 1.0.10 (Xray v25.3.6),
which requires:
  - an "inbounds" array
  - outbounds[0] is the VLESS outbound with settings.vnext[0]
  - that outbound tagged "proxy", for its traffic counters
"""

import json

SELLER_LOCAL_SOCKS_PORT = 10818  # unused locally; the plugin refuses configs without an inbound

# Destinations a buyer must never reach through a seller's phone: the phone
# itself, the seller's home or office LAN, carrier-internal ranges.
PRIVATE_RANGES = [
    "0.0.0.0/8",
    "10.0.0.0/8",
    "100.64.0.0/10",
    "127.0.0.0/8",
    "169.254.0.0/16",
    "172.16.0.0/12",
    "192.168.0.0/16",
    "::1/128",
    "fc00::/7",
    "fe80::/10",
]


def slot_domain(slot: int) -> str:
    return f"slot-{slot:03d}.relay.databric.internal"


def generate_seller_bridge_config(
    *,
    relay_host: str,
    seller_port: int,
    seller_uuid: str,
    slot: int,
    public_key: str,
    short_id: str,
    server_name: str,
    fingerprint: str = "chrome",
) -> str:
    """
    Full Xray config for the seller's phone (reverse-proxy bridge).

    The phone dials OUT to the relay's seller port and offers itself as the
    bridge for its slot; buyer traffic for that slot comes back down that
    connection and leaves through the phone's own network. Mirrors
    xray/static-test/seller.json, with Reality added for real networks.
    """
    domain = slot_domain(slot)
    config = {
        "log": {"loglevel": "warning"},
        "reverse": {"bridges": [{"tag": "bridge", "domain": domain}]},
        "inbounds": [
            {
                "tag": "local-socks",
                "listen": "127.0.0.1",
                "port": SELLER_LOCAL_SOCKS_PORT,
                "protocol": "socks",
                "settings": {"udp": False},
            }
        ],
        "outbounds": [
            {
                "tag": "proxy",
                "protocol": "vless",
                "settings": {
                    "vnext": [
                        {
                            "address": relay_host,
                            "port": seller_port,
                            "users": [{"id": seller_uuid, "encryption": "none"}],
                        }
                    ]
                },
                "streamSettings": {
                    "network": "tcp",
                    "security": "reality",
                    "realitySettings": {
                        "serverName": server_name,
                        "fingerprint": fingerprint,
                        "publicKey": public_key,
                        "shortId": short_id,
                    },
                },
            },
            {"tag": "direct", "protocol": "freedom"},
            {"tag": "block", "protocol": "blackhole"},
        ],
        "routing": {
            # Resolve domains before the private-range rule, so a hostname
            # pointing at 192.168.x.x is blocked too.
            "domainStrategy": "IPOnDemand",
            "rules": [
                {
                    "type": "field",
                    "inboundTag": ["bridge"],
                    "domain": [f"full:{domain}"],
                    "outboundTag": "proxy",
                },
                {
                    "type": "field",
                    "inboundTag": ["bridge"],
                    "ip": PRIVATE_RANGES,
                    "outboundTag": "block",
                },
                {"type": "field", "inboundTag": ["bridge"], "outboundTag": "direct"},
                {"type": "field", "inboundTag": ["local-socks"], "outboundTag": "block"},
            ],
        },
    }
    return json.dumps(config, indent=2)
