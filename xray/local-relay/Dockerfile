# DataBric relay for local testing: the same Xray build and relay agent the
# real servers run (scripts/setup_relay.sh), in one container.
# Build context: databric-backend/scripts (for relay_agent.py). Use run.sh.
FROM python:3.12-slim

ARG XRAY_VERSION=v25.3.6
ARG TARGETARCH
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends curl unzip ca-certificates iproute2 >/dev/null \
 && rm -rf /var/lib/apt/lists/*

# Pinned to the core bundled in the phone app (flutter_v2ray 1.0.10). Newer
# relays break the reverse-proxy control channel.
RUN set -eu; \
    case "$TARGETARCH" in \
      amd64) ASSET=Xray-linux-64.zip;        SHA=82d4be3a5ed8bd2621df9c9913c3a2761b86a42ae8485da836f7447ff2ec3d4d ;; \
      arm64) ASSET=Xray-linux-arm64-v8a.zip; SHA=1595f446b3d3a2bfe4a737e3cdb4c189c8c4e271322a7a2a0f5ea735b9511e80 ;; \
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
  out=$(xray x25519)
  {
    echo "REALITY_PRIVATE_KEY=$(echo "$out" | grep 'Private key' | awk '{print $NF}')"
    echo "REALITY_PUBLIC_KEY=$(echo "$out" | grep 'Public key' | awk '{print $NF}')"
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
