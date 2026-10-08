#!/usr/bin/env bash
# DataBric static reverse-tunnel test: laptop side.
#
# Runs the relay and the buyer on this laptop. The seller runs on the phone
# (DataBric debug build > Share Data > "Start seller tunnel"), reached through
# `adb reverse`, over USB or wireless debugging.
#
#   Phone: connected over adb (USB, or `adb connect <ip>:<port>` for wireless).
#          For a mobile-data test the phone must be off Wi-Fi, which needs USB.
#   Run:   ./run_laptop.sh
#          With several phones connected: ANDROID_SERIAL=<serial> ./run_laptop.sh
#
# Pass: "Via tunnel" prints an IP at all. The relay has no internet exit of its
# own, so any answer came through the phone. On mobile data it should be the
# carrier's IP, not this laptop's.
#
# Xray is pinned to v25.3.6 because that is the core bundled in
# flutter_v2ray 1.0.10 on the phone. A newer relay and the older phone core
# disagree on the reverse control channel.

set -euo pipefail
cd "$(dirname "$0")"

XRAY_VERSION="v25.3.6"
CHECK_URL="${CHECK_URL:-https://api.ipify.org}"
SOCKS="socks5h://127.0.0.1:10808"
CACHE="$HOME/.cache/databric/xray-$XRAY_VERSION"
LOGS="${TMPDIR:-/tmp}/databric-static-test"

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64)  ASSET="Xray-macos-arm64-v8a.zip"; SHA="0d8486ab2eb089abcbc47a7c8d2004490c98dc8fd2ca760915ad746667aa7d7b" ;;
  Darwin-x86_64) ASSET="Xray-macos-64.zip";        SHA="cc773fca109d45de4ad3a62eedf5142391c61c3048eb80b6370ce97bf5d0a075" ;;
  Linux-x86_64)  ASSET="Xray-linux-64.zip";        SHA="82d4be3a5ed8bd2621df9c9913c3a2761b86a42ae8485da836f7447ff2ec3d4d" ;;
  Linux-aarch64) ASSET="Xray-linux-arm64-v8a.zip"; SHA="1595f446b3d3a2bfe4a737e3cdb4c189c8c4e271322a7a2a0f5ea735b9511e80" ;;
  *) echo "Unsupported platform: $(uname -s)-$(uname -m)"; exit 1 ;;
esac

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

XRAY="$CACHE/xray"
if [ ! -x "$XRAY" ]; then
  echo "Downloading Xray $XRAY_VERSION ($ASSET)..."
  mkdir -p "$CACHE"
  curl -fsSL -o "$CACHE/$ASSET" "https://github.com/XTLS/Xray-core/releases/download/$XRAY_VERSION/$ASSET"
  if [ "$(sha256 "$CACHE/$ASSET")" != "$SHA" ]; then
    echo "Checksum mismatch for $ASSET. Not running it."; rm -f "$CACHE/$ASSET"; exit 1
  fi
  unzip -o -q "$CACHE/$ASSET" -d "$CACHE"
  chmod +x "$XRAY"
fi
echo "Using $("$XRAY" version | head -1)"

# ── adb: find it, pick the phone, set up the reverse port ────────────────────

find_adb() {
  if command -v adb >/dev/null 2>&1; then command -v adb; return 0; fi
  for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do
    if [ -n "$sdk" ] && [ -x "$sdk/platform-tools/adb" ]; then echo "$sdk/platform-tools/adb"; return 0; fi
  done
  return 1
}

ADB="$(find_adb || true)"
REVERSE_OK=0

# Sets up `adb reverse` on the phone. Pass "quiet" to skip the warnings
# (used while retrying in the wait loop). Returns non-zero if not set.
setup_reverse() {
  local quiet="${1:-}" list phones count serial out
  if [ -z "$ADB" ]; then
    [ -n "$quiet" ] || echo "WARNING: adb not found. Add the Android SDK's platform-tools folder to your PATH."
    return 1
  fi
  if [ -n "${ANDROID_SERIAL:-}" ]; then
    serial="$ANDROID_SERIAL"
  else
    list="$("$ADB" devices 2>&1 || true)"
    # Ready devices only, emulators excluded: the emulator shares this
    # laptop's network, so it cannot stand in for the phone.
    phones="$(printf '%s\n' "$list" | awk 'NR>1 && $2=="device" && $1 !~ /^emulator-/ {print $1}')"
    count="$(printf '%s\n' "$phones" | grep -c . || true)"
    if [ "$count" -eq 0 ]; then
      if [ -z "$quiet" ]; then
        echo "WARNING: no phone ready over adb. 'adb devices' says:"
        printf '%s\n' "$list" | sed 's/^/    /'
        echo "  Connect the phone (USB, or 'adb connect <ip>:<port>'). This script keeps checking."
      fi
      return 1
    fi
    if [ "$count" -gt 1 ]; then
      if [ -z "$quiet" ]; then
        echo "WARNING: more than one phone connected:"
        printf '%s\n' "$phones" | sed 's/^/    /'
        echo "  If these are the same phone, remove one with: adb disconnect <ip>:<port>"
        echo "  Otherwise run again with: ANDROID_SERIAL=<one of them> ./run_laptop.sh"
      fi
      return 1
    fi
    serial="$phones"
  fi
  if out="$("$ADB" -s "$serial" reverse tcp:9443 tcp:9443 2>&1)"; then
    echo "adb reverse set on $serial: phone 127.0.0.1:9443 -> laptop 127.0.0.1:9443"
    REVERSE_OK=1
    return 0
  fi
  [ -n "$quiet" ] || echo "WARNING: adb reverse failed on $serial: $out"
  return 1
}

setup_reverse || true

# ── relay + buyer ────────────────────────────────────────────────────────────

mkdir -p "$LOGS"
"$XRAY" run -c relay.json > "$LOGS/relay.log" 2>&1 &
RELAY_PID=$!
"$XRAY" run -c buyer.json > "$LOGS/buyer.log" 2>&1 &
BUYER_PID=$!
trap 'kill $RELAY_PID $BUYER_PID 2>/dev/null || true' EXIT
sleep 1
if ! kill -0 $RELAY_PID 2>/dev/null || ! kill -0 $BUYER_PID 2>/dev/null; then
  echo "Relay or buyer failed to start (is port 8443, 9443 or 10808 in use?). Logs: $LOGS"; exit 1
fi
echo "Relay and buyer running. Logs: $LOGS"

DIRECT="$(curl -s -m 10 --noproxy '*' "$CHECK_URL" || true)"
echo
echo "Direct (this laptop):  ${DIRECT:-unavailable}"
echo "Now press \"Start seller tunnel\" in the app. Waiting for the phone..."

TUNNEL=""
while [ -z "$TUNNEL" ]; do
  # The phone may be connected after the script started; keep trying quietly.
  [ "$REVERSE_OK" = 1 ] || setup_reverse quiet || true
  if grep -q "seller-in -> portal" "$LOGS/relay.log" 2>/dev/null; then
    TUNNEL="$(curl -s -m 10 --noproxy '' -x "$SOCKS" "$CHECK_URL" || true)"
  fi
  [ -n "$TUNNEL" ] || sleep 2
done

echo "Via tunnel (phone):    $TUNNEL"
if [ -n "$DIRECT" ] && [ "$TUNNEL" = "$DIRECT" ]; then
  echo "RESULT: the tunnel works. The IP matches this laptop's because the phone"
  echo "        is on the same network (Wi-Fi). Take it off Wi-Fi to test mobile data."
else
  echo "RESULT: the tunnel works, and traffic leaves through the phone's own network."
fi
echo
echo "Tunnel stays up. Try your own request, e.g.:"
echo "  curl -x $SOCKS https://ifconfig.me"
echo "Stop the seller in the app and the same request should fail."
echo "Press Ctrl-C to stop."
wait
