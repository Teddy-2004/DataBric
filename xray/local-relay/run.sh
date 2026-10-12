#!/bin/bash
# Runs a DataBric relay on this Mac in Docker, registered with the live
# backend, so Android emulators on this Mac can test the real Share flow.
#
#   xray/local-relay/run.sh          start (asks for the relay secret once)
#   xray/local-relay/run.sh logs     follow the relay's log
#   xray/local-relay/run.sh stop     stop it
#
# Emulators reach the Mac at 10.0.2.2, so that is the address the relay
# registers. Real phones can't use it. When stopped, the backend stops
# choosing this relay after about two minutes.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
NAME=databric-local-relay
IMAGE=databric-local-relay
ENV_FILE="$HERE/.env"   # holds the secret; ignored by git
BACKEND_URL=${BACKEND_URL:-https://databric.onrender.com}

case "${1:-start}" in
  logs) exec docker logs -f "$NAME" ;;
  stop) docker rm -f "$NAME" >/dev/null 2>&1 && echo "Relay stopped." || echo "Relay was not running."; exit 0 ;;
  start) ;;
  *) echo "usage: $0 [start|logs|stop]"; exit 1 ;;
esac

if ! docker info >/dev/null 2>&1; then
  echo "Docker isn't running. Open Docker Desktop, wait until it says it's running, then try again."
  exit 1
fi

# Anything else on these ports takes the emulators' connections instead of
# the container (e.g. the static tunnel test's relay on 127.0.0.1).
OTHERS=$(lsof -nP -iTCP:8443 -iTCP:9443 -sTCP:LISTEN 2>/dev/null | awk 'NR>1 && $1 !~ /^com\.docke/ {print $1" (PID "$2")"}' | sort -u)
if [ -n "$OTHERS" ]; then
  echo "Another program is listening on port 8443 or 9443, so the emulators would reach it instead of this relay:"
  echo "$OTHERS" | sed 's/^/  /'
  echo "Stop it first (for example: kill <PID>), then run this again."
  exit 1
fi

if [ ! -s "$ENV_FILE" ]; then
  echo "Paste the backend's RELAY_SECRET_KEY (Render > your service > Environment)."
  echo "It won't be shown as you type, and is saved only to xray/local-relay/.env."
  read -rs -p "RELAY_SECRET_KEY: " SECRET; echo
  [ -n "$SECRET" ] || { echo "Nothing entered."; exit 1; }
  umask 077
  printf 'RELAY_SECRET=%s\n' "$SECRET" > "$ENV_FILE"
fi

echo "Building the relay image (the first build downloads Xray; later ones are quick)..."
docker build -q -t "$IMAGE" -f "$HERE/Dockerfile" "$REPO/databric-backend/scripts" >/dev/null

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" \
  --env-file "$ENV_FILE" \
  -e NODE_ID=mac-local \
  -e BACKEND_URL="$BACKEND_URL" \
  -e PUBLIC_HOST=10.0.2.2 \
  -e REGION=IT -e CITY="Local test" \
  -e PORTAL_SLOTS=10 \
  -e HEARTBEAT_INTERVAL=30 \
  -p 8443:8443 -p 9443:9443 \
  -v databric-local-relay:/state \
  "$IMAGE" >/dev/null

echo "Started. Waiting for it to register with the backend (Render may need ~1 min to wake up)..."
for _ in $(seq 1 90); do
  if docker logs "$NAME" 2>&1 | grep -q "registered mac-local"; then
    echo ""
    echo "Relay is up and registered as mac-local."
    echo "Emulators reach it at 10.0.2.2 (buyers :8443, sellers :9443)."
    echo "Follow its log:  xray/local-relay/run.sh logs"
    echo "Stop it:         xray/local-relay/run.sh stop"
    exit 0
  fi
  if ! docker ps -q -f name="^$NAME$" | grep -q .; then
    echo "The relay stopped. Its log:"; docker logs --tail 30 "$NAME"; exit 1
  fi
  sleep 2
done
echo "Not registered after 3 minutes. Recent log:"
docker logs --tail 30 "$NAME"
exit 1
