// Static reverse-tunnel test (debug builds only).
//
// Copy of xray/static-test/seller.json. Keep the two in sync: the relay in
// xray/static-test/relay.json expects exactly this user id, which it gives
// the reverse tag the buyer is routed to (VLESS Reverse Proxy, Xray 26+).
//
// The relay address is 127.0.0.1:9443 on the phone, which `adb reverse`
// forwards to the laptop. Nothing here is a secret or meant for production.

const String kStaticTestSessionId = 'static-test';

const String kStaticSellerTestConfig = r'''
{
  "log": {
    "loglevel": "info"
  },
  "inbounds": [
    {
      "tag": "local-socks",
      "listen": "127.0.0.1",
      "port": 10818,
      "protocol": "socks",
      "settings": {
        "udp": false
      }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "address": "127.0.0.1",
        "port": 9443,
        "id": "5e11e200-2222-4ccc-8ddd-000000000002",
        "encryption": "none",
        "reverse": {
          "tag": "r-in"
        },
        "servers": [
          {
            "address": "127.0.0.1",
            "port": 9443
          }
        ]
      }
    },
    {
      "tag": "direct",
      "protocol": "freedom",
      "streamSettings": {
        "sockopt": {
          "domainStrategy": "UseIPv4v6"
        }
      },
      "settings": {
        "finalRules": [
          {
            "action": "block",
            "ip": [
              "0.0.0.0/8",
              "10.0.0.0/8",
              "100.64.0.0/10",
              "127.0.0.0/8",
              "169.254.0.0/16",
              "172.16.0.0/12",
              "192.168.0.0/16",
              "::1/128",
              "fc00::/7",
              "fe80::/10"
            ]
          },
          {
            "action": "allow"
          }
        ]
      }
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "IPOnDemand",
    "rules": [
      {
        "type": "field",
        "inboundTag": [
          "dns-query"
        ],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "inboundTag": [
          "r-in"
        ],
        "ip": [
          "0.0.0.0/8",
          "10.0.0.0/8",
          "100.64.0.0/10",
          "127.0.0.0/8",
          "169.254.0.0/16",
          "172.16.0.0/12",
          "192.168.0.0/16",
          "::1/128",
          "fc00::/7",
          "fe80::/10"
        ],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "inboundTag": [
          "r-in"
        ],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "inboundTag": [
          "local-socks"
        ],
        "outboundTag": "block"
      }
    ]
  },
  "dns": {
    "tag": "dns-query",
    "servers": [
      "1.1.1.1",
      "8.8.8.8"
    ]
  }
}
''';
