"""
Xray configs handed to the sellers' phones.

Sellers use Xray's VLESS Reverse Proxy (Xray 26+; the older "reverse"
bridges/portals were removed). The phone dials out to the relay's seller
port as a VLESS user that the relay agent (scripts/relay_agent.py) created
with a reverse tag for this session; the relay routes that session's buyer to
the tag, so buyer traffic comes down the phone's connection and leaves
through the phone's own network.

The phone app runs these configs with flutter_v2ray_client 3.5.0
(Xray v26.9.9), which requires:
  - an "inbounds" array
  - outbounds[0].settings.vnext[0] or .servers[0] with address and port (it
    reads them for its notification). VLESS Reverse only works in the flat
    outbound format, and a "vnext" key would switch Xray to the old format,
    so the outbound carries a "servers" entry that Xray ignores.
  - the tunnel outbound tagged "proxy", for its traffic counters
"""

import json

SELLER_LOCAL_SOCKS_PORT = 10818  # unused locally; the plugin refuses configs without an inbound
REVERSE_INBOUND_TAG = "r-in"  # where buyer traffic enters the seller's routing
DNS_TAG = "dns-query"  # Xray's own DNS lookups, routed straight out

# Buyers' connections arrive as names (Chrome, sniffing), which the seller's
# Xray must resolve. Without servers here it uses Go's system resolver, which
# on Android has no /etc/resolv.conf and fails every lookup.
DNS_SERVERS = ["1.1.1.1", "8.8.8.8"]

# Destinations a buyer must never reach through a seller's phone: the phone
# itself, the seller's home or office LAN, carrier-internal ranges. Xray 26's
# freedom outbound blocks most of these by default too; this rule keeps the
# guarantee explicit.
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


def generate_seller_bridge_config(
    *,
    relay_host: str,
    seller_port: int,
    seller_uuid: str,
    public_key: str,
    short_id: str,
    server_name: str,
    fingerprint: str = "chrome",
) -> str:
    """Full Xray config for the seller's phone (VLESS reverse tunnel)."""
    config = {
        "log": {"loglevel": "warning"},
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
                    "address": relay_host,
                    "port": seller_port,
                    "id": seller_uuid,
                    "encryption": "none",
                    "reverse": {"tag": REVERSE_INBOUND_TAG},
                    # Read by the plugin only; Xray ignores it.
                    "servers": [{"address": relay_host, "port": seller_port}],
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
            {
                "tag": "direct",
                "protocol": "freedom",
                # Resolve names with the DNS servers above (IPv4 first).
                "streamSettings": {"sockopt": {"domainStrategy": "UseIPv4v6"}},
            },
            {"tag": "block", "protocol": "blackhole"},
        ],
        "dns": {"tag": DNS_TAG, "servers": DNS_SERVERS},
        "routing": {
            # Resolve domains before the private-range rule, so a hostname
            # pointing at 192.168.x.x is blocked too.
            "domainStrategy": "IPOnDemand",
            "rules": [
                # DNS queries go straight out, not back into the tunnel (the
                # first outbound, and so the default).
                {"type": "field", "inboundTag": [DNS_TAG], "outboundTag": "direct"},
                {
                    "type": "field",
                    "inboundTag": [REVERSE_INBOUND_TAG],
                    "ip": PRIVATE_RANGES,
                    "outboundTag": "block",
                },
                {"type": "field", "inboundTag": [REVERSE_INBOUND_TAG], "outboundTag": "direct"},
                {"type": "field", "inboundTag": ["local-socks"], "outboundTag": "block"},
            ],
        },
    }
    return json.dumps(config, indent=2)
