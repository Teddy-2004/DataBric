# DataBric relay for local testing: the same Xray build and relay agent the
# real servers run (scripts/setup_relay.sh), in one container.
# Build context: databric-backend/scripts (for relay_agent.py). Use run.sh.
FROM python:3.12-slim

ARG XRAY_VERSION=v26.9.9
ARG TARGETARCH
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends curl unzip ca-certificates >/dev/null \
 && rm -rf /var/lib/apt/lists/*

# Pinned to the core bundled in the phone app (flutter_v2ray_client 3.5.0).
# Sellers use VLESS Reverse Proxy, which needs Xray 26+.
RUN set -eu; \
    case "$TARGETARCH" in \
      amd64) ASSET=Xray-linux-64.zip;        SHA=1eb9175d0f0a8f8149c9230a7fc5ae66ce332ed20a53155ce61fe62e3f58b7df ;; \
      arm64) ASSET=Xray-linux-arm64-v8a.zip; SHA=3e38d72dfc5eb65c91df0e5583e9b6676c32232041da47de6ae73946b526d66c ;; \
      *) echo "unsupported arch $TARGETARCH"; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/download/$XRAY_VERSION/$ASSET"; \
    echo "$SHA  /tmp/xray.zip" | sha256sum -c --quiet; \
    unzip -q /tmp/xray.zip xray -d /usr/local/bin; \
    rm /tmp/xray.zip; \
    xray version | head -1

RUN pip install -q --no-cache-dir "grpcio>=1.60,<2"

COPY relay_agent.py /opt/relay/relay_agent.py

COPY <<'EOF' /opt/relay/entrypoint.sh
#!/bin/bash
# Keeps the Reality keys in /state across restarts, renders the Xray config
# with the agent (so both agree on slots), then runs Xray and the agent.
set -euo pipefail
mkdir -p /state /var/log/xray
KEYS=/state/keys.env
if [ ! -s "$KEYS" ]; then
  # Xray 25 prints "Private key:/Public key:", Xray 26 "PrivateKey:/Password (PublicKey):".
  out=$(xray x25519)
  priv=$(echo "$out" | grep -iE '^private ?key:' | awk '{print $NF}')
  pub=$(echo "$out" | grep -iE 'public ?key' | awk '{print $NF}')
  if [ -z "$priv" ] || [ -z "$pub" ]; then
    echo "Could not read the keys from 'xray x25519':"; echo "$out"; exit 1
  fi
  {
    echo "REALITY_PRIVATE_KEY=$priv"
    echo "REALITY_PUBLIC_KEY=$pub"
    echo "REALITY_SHORT_ID=$(python3 -c 'import secrets; print(secrets.token_hex(4))')"
  } > "$KEYS"
  echo "Generated new Reality keys."
fi
set -a; . "$KEYS"; set +a
export STATE_FILE=/state/agent-state.json

python3 /opt/relay/relay_agent.py render-config --env /nonexistent > /etc/xray.json
xray run -test -c /etc/xray.json >/dev/null
xray run -c /etc/xray.json &
sleep 1
python3 /opt/relay/relay_agent.py run --env /nonexistent &
# Stop the container when either process exits, so the problem is visible.
wait -n
echo "Xray or the relay agent exited; stopping."
exit 1
EOF
RUN chmod 755 /opt/relay/entrypoint.sh

EXPOSE 8443 9443
ENTRYPOINT ["/opt/relay/entrypoint.sh"]
