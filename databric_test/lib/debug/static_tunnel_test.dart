// Static reverse-tunnel test (debug builds only).
//
// Copy of xray/static-test/seller.json. Keep the two in sync: the relay in
// xray/static-test/relay.json expects exactly this user id and bridge domain.
//
// The relay address is 127.0.0.1:9443 on the phone, which `adb reverse`
// forwards to the laptop. Nothing here is a secret or meant for production.

const String kStaticTestSessionId = 'static-test';

const String kStaticSellerTestConfig = r'''
{
  "log": { "loglevel": "info" },
  "reverse": {
    "bridges": [
      { "tag": "bridge", "domain": "seller.databric.test" }
    ]
  },
  "inbounds": [
    {
      "tag": "local-socks",
      "listen": "127.0.0.1",
      "port": 10818,
      "protocol": "socks",
      "settings": { "udp": false }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "127.0.0.1",
            "port": 9443,
            "users": [
              { "id": "5e11e200-2222-4ccc-8ddd-000000000002", "encryption": "none" }
            ]
          }
        ]
      }
    },
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPOnDemand",
    "rules": [
      {
        "type": "field",
        "inboundTag": ["bridge"],
        "domain": ["full:seller.databric.test"],
        "outboundTag": "proxy"
      },
      {
        "type": "field",
        "inboundTag": ["bridge"],
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
        "inboundTag": ["bridge"],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "inboundTag": ["local-socks"],
        "outboundTag": "block"
      }
    ]
  }
}
''';
