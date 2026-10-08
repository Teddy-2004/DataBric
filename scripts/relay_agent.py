#!/usr/bin/env python3
"""
DataBric relay agent.

Runs next to Xray on a relay node and keeps Xray's live sessions in step
with the backend:

  * registers the node with the backend on start, then heartbeats
  * every few seconds asks the backend which sessions are live on this node
    (GET /relay/sessions) and, without restarting Xray:
      - adds the session's seller and buyer credentials
      - adds routing rules binding them to the session's reverse-proxy slot
      - on session end, removes all of that and cuts the seller's open
        connections, so the slot is clean for the next session
  * `render-config` prints the Xray config this agent expects to manage

Why slots: the reverse proxy entry points ("portals") of Xray v25.3.6 can only
be defined in the config file, not added at runtime. The config defines
PORTAL_SLOTS of them; the backend gives each session a free one.

Why cut connections: Xray cannot detach a bridge from a portal. A seller
whose session ended could otherwise stay attached to the slot and receive the
next session's buyer traffic.

Xray must be v25.3.6, the core bundled in the phone app (flutter_v2ray 1.0.10).

Usage:
  relay_agent.py render-config [--env /etc/databric/relay.env]
  relay_agent.py run           [--env /etc/databric/relay.env]

Needs: Python 3.8+, grpcio (pip install grpcio), the xray binary, and `ss`
(iproute2) with kernel socket-destroy support, run as root.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

log = logging.getLogger("relay-agent")

BUYER_INBOUND = "buyer-in"
SELLER_INBOUND = "seller-in"
BUYER_FLOW = "xtls-rprx-vision"  # must match the buyer VLESS URI from the backend


# ── Naming shared with the backend (app/services/relay_service.py) ──────────

def slot_domain(slot: int) -> str:
    return f"slot-{slot:03d}.relay.databric.internal"


def portal_tag(slot: int) -> str:
    return f"portal-{slot:03d}"


def buyer_email(session_id: str) -> str:
    return f"b-{session_id}"


def seller_email(session_id: str) -> str:
    return f"s-{session_id}"


# ── Settings ────────────────────────────────────────────────────────────────

DEFAULTS = {
    "NODE_ID": "relay-1",
    "BACKEND_URL": "",
    "RELAY_SECRET": "",
    "PUBLIC_HOST": "",          # what phones dial; detected if empty
    "REGION": "KE",
    "CITY": "Nairobi",
    "BUYER_PORT": "8443",
    "SELLER_PORT": "9443",
    "PORTAL_SLOTS": "100",
    "REALITY_PRIVATE_KEY": "",
    "REALITY_PUBLIC_KEY": "",
    "REALITY_SHORT_ID": "",
    "REALITY_DEST": "www.google.com:443",
    "REALITY_SERVER_NAME": "www.google.com",
    "LISTEN": "0.0.0.0",
    "XRAY_BIN": "/usr/local/bin/xray",
    "XRAY_API": "127.0.0.1:10085",
    "ACCESS_LOG": "/var/log/xray/access.log",
    "ERROR_LOG": "/var/log/xray/error.log",
    "STATE_FILE": "/var/lib/databric/relay-agent-state.json",
    "SYNC_INTERVAL": "3",
    "HEARTBEAT_INTERVAL": "30",
}


def load_settings(env_file: str | None) -> dict:
    s = dict(DEFAULTS)
    if env_file and Path(env_file).exists():
        for line in Path(env_file).read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            s[k.strip()] = v.strip().strip('"').strip("'")
    for k in DEFAULTS:
        if k in os.environ:
            s[k] = os.environ[k]
    for k in ("BUYER_PORT", "SELLER_PORT", "PORTAL_SLOTS"):
        s[k] = int(s[k])
    for k in ("SYNC_INTERVAL", "HEARTBEAT_INTERVAL"):
        s[k] = float(s[k])
    return s


# ── Xray config for the relay ───────────────────────────────────────────────

def render_xray_config(s: dict) -> dict:
    reality = {
        "show": False,
        "dest": s["REALITY_DEST"],
        "xver": 0,
        "serverNames": [s["REALITY_SERVER_NAME"]],
        "privateKey": s["REALITY_PRIVATE_KEY"],
        "shortIds": [s["REALITY_SHORT_ID"]],
    }
    stream = {"network": "tcp", "security": "reality", "realitySettings": reality}

    def vless_inbound(tag: str, port: int) -> dict:
        return {
            "tag": tag,
            "listen": s["LISTEN"],
            "port": port,
            "protocol": "vless",
            # Users are added and removed at runtime by this agent.
            "settings": {"clients": [], "decryption": "none"},
            "streamSettings": stream,
        }

    return {
        "log": {
            "loglevel": "warning",
            # The agent reads the access log to find each seller's connections.
            "access": s["ACCESS_LOG"],
            "error": s["ERROR_LOG"],
        },
        "api": {
            "tag": "api",
            "listen": s["XRAY_API"],  # keep on localhost
            "services": ["HandlerService", "RoutingService", "StatsService"],
        },
        "stats": {},
        "policy": {
            "levels": {"0": {"statsUserUplink": True, "statsUserDownlink": True}},
            "system": {"statsInboundUplink": True, "statsInboundDownlink": True},
        },
        "reverse": {
            "portals": [
                {"tag": portal_tag(i), "domain": slot_domain(i)}
                for i in range(s["PORTAL_SLOTS"])
            ]
        },
        "inbounds": [
            vless_inbound(BUYER_INBOUND, s["BUYER_PORT"]),
            vless_inbound(SELLER_INBOUND, s["SELLER_PORT"]),
        ],
        # First outbound is the default: anything not matched by a session
        # rule goes nowhere. The relay never reaches the internet itself.
        "outbounds": [{"tag": "blocked", "protocol": "blackhole"}],
        # Session rules are appended at runtime. Do not add a catch-all here:
        # appended rules come after it and would never match.
        "routing": {"domainStrategy": "AsIs", "rules": []},
    }


def session_rules(session_id: str, slot: int) -> list:
    return [
        {
            # The seller's bridge may only attach to its own slot.
            "type": "field",
            "ruleTag": seller_email(session_id),
            "inboundTag": [SELLER_INBOUND],
            "user": [seller_email(session_id)],
            "domain": [f"full:{slot_domain(slot)}"],
            "outboundTag": portal_tag(slot),
        },
        {
            # The buyer's traffic goes to that slot, and so to that seller.
            "type": "field",
            "ruleTag": buyer_email(session_id),
            "inboundTag": [BUYER_INBOUND],
            "user": [buyer_email(session_id)],
            "outboundTag": portal_tag(slot),
        },
    ]


# ── Minimal protobuf encoding for Xray's HandlerService.AlterInbound ────────
# Field numbers from xray-core v25.3.6: app/proxyman/command/command.proto,
# common/protocol/user.proto, common/serial/typed_message.proto,
# proxy/vless/account.proto. Hand-encoded so the relay only needs grpcio,
# not generated stubs.

def _varint(n: int) -> bytes:
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def _len_field(num: int, data: bytes) -> bytes:
    return _varint((num << 3) | 2) + _varint(len(data)) + data


def _str_field(num: int, value: str) -> bytes:
    return _len_field(num, value.encode()) if value else b""


def _typed_message(type_name: str, value: bytes) -> bytes:
    return _str_field(1, type_name) + _len_field(2, value)


def encode_add_vless_user(inbound_tag: str, email: str, user_id: str, flow: str = "") -> bytes:
    account = _str_field(1, user_id) + _str_field(2, flow) + _str_field(3, "none")
    user = _str_field(2, email) + _len_field(
        3, _typed_message("xray.proxy.vless.Account", account)
    )
    op = _len_field(1, user)
    return _str_field(1, inbound_tag) + _len_field(
        2, _typed_message("xray.app.proxyman.command.AddUserOperation", op)
    )


def encode_remove_user(inbound_tag: str, email: str) -> bytes:
    op = _str_field(1, email)
    return _str_field(1, inbound_tag) + _len_field(
        2, _typed_message("xray.app.proxyman.command.RemoveUserOperation", op)
    )


# ── Xray API ────────────────────────────────────────────────────────────────

class XrayApi:
    def __init__(self, api_addr: str, xray_bin: str):
        import grpc  # imported here so render-config works without grpcio

        self._grpc = grpc
        self.api_addr = api_addr
        self.xray_bin = xray_bin
        channel = grpc.insecure_channel(api_addr)
        self._alter = channel.unary_unary(
            "/xray.app.proxyman.command.HandlerService/AlterInbound",
            request_serializer=lambda b: b,
            response_deserializer=lambda b: b,
        )

    def add_user(self, inbound_tag: str, email: str, user_id: str, flow: str = ""):
        self._alter(encode_add_vless_user(inbound_tag, email, user_id, flow), timeout=5)

    def remove_user(self, inbound_tag: str, email: str) -> bool:
        try:
            self._alter(encode_remove_user(inbound_tag, email), timeout=5)
            return True
        except self._grpc.RpcError as e:
            log.debug("remove_user %s %s: %s", inbound_tag, email, e)
            return False

    def add_rules(self, rules: list):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump({"routing": {"rules": rules}}, f)
            path = f.name
        try:
            # -append is essential: without it Xray REPLACES every rule.
            self._cli(["adrules", "-append", path])
        finally:
            os.unlink(path)

    def remove_rules(self, tags: list):
        # One call per tag: a missing tag must not stop the others going.
        for tag in tags:
            try:
                self._cli(["rmrules", tag])
            except RuntimeError as e:
                log.debug("remove_rules %s: %s", tag, e)

    def _cli(self, args: list):
        cmd = [self.xray_bin, "api", args[0], f"--server={self.api_addr}", *args[1:]]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        if r.returncode != 0:
            raise RuntimeError(f"{' '.join(args[:2])} failed: {(r.stderr or r.stdout).strip()}")


# ── Seller connections, read from Xray's access log ─────────────────────────

ACCESS_RE = re.compile(
    r"from (?:tcp:)?\[?([0-9a-fA-F:.]+?)\]?:(\d+) accepted \S+ \["
    + re.escape(SELLER_INBOUND)
    + r" -> [^\]]+\] email: (s-[0-9a-fA-F-]+)"
)


class SellerConnections:
    """Follows the access log and remembers which TCP peers belong to which seller."""

    def __init__(self, path: str):
        self.path = path
        self._lock = threading.Lock()
        self._by_email: dict[str, set] = {}

    def feed(self, line: str):
        m = ACCESS_RE.search(line)
        if m:
            ip, port, email = m.group(1), int(m.group(2)), m.group(3)
            with self._lock:
                self._by_email.setdefault(email, set()).add((ip, port))

    def take(self, email: str) -> set:
        with self._lock:
            return self._by_email.pop(email, set())

    def follow(self, stop: threading.Event):
        f, inode = None, None
        while not stop.is_set():
            try:
                st = os.stat(self.path)
                if f is None or st.st_ino != inode or f.tell() > st.st_size:
                    if f:
                        f.close()
                    # From the start: rebuilds the map after an agent restart.
                    f, inode = open(self.path, "r", errors="replace"), st.st_ino
                line = f.readline()
                if line:
                    self.feed(line)
                    continue
            except FileNotFoundError:
                pass
            stop.wait(0.5)


def _open_tcp_peers(local_port: int) -> set:
    """Remote (ip, port) of established TCP connections to local_port."""
    peers = set()
    for path, v6 in (("/proc/net/tcp", False), ("/proc/net/tcp6", True)):
        try:
            lines = Path(path).read_text().splitlines()[1:]
        except FileNotFoundError:
            continue
        for row in lines:
            parts = row.split()
            if len(parts) < 4 or parts[3] != "01":  # 01 = ESTABLISHED
                continue
            if int(parts[1].split(":")[1], 16) != local_port:
                continue
            rhex, rport = parts[2].split(":")
            peers.add((_hex_ip(rhex, v6), int(rport, 16)))
    return peers


def _hex_ip(h: str, v6: bool) -> str:
    import ipaddress

    raw = bytes.fromhex(h)
    if not v6:
        return str(ipaddress.IPv4Address(raw[::-1]))
    # /proc/net/tcp6 stores four little-endian 32-bit words
    words = b"".join(raw[i:i + 4][::-1] for i in range(0, 16, 4))
    addr = ipaddress.IPv6Address(words)
    return str(addr.ipv4_mapped) if addr.ipv4_mapped else str(addr)


def cut_connections(peers: set, seller_port: int) -> set:
    """Kills the given TCP connections. Returns those still open afterwards."""
    for ip, port in peers:
        target = f"[{ip}]" if ":" in ip else ip
        try:
            r = subprocess.run(
                ["ss", "-K", "dst", target, "dport", "=", f":{port}"],
                capture_output=True, text=True, timeout=10,
            )
        except (OSError, subprocess.SubprocessError) as e:
            log.error("could not run ss -K (install iproute2): %s", e)
            continue
        if r.returncode != 0:
            log.warning("ss -K failed for %s:%s: %s", ip, port, r.stderr.strip())
    time.sleep(0.2)
    return peers & _open_tcp_peers(seller_port)


# ── Backend client ──────────────────────────────────────────────────────────

class Backend:
    def __init__(self, base_url: str, secret: str):
        self.base = base_url.rstrip("/")
        self.secret = secret

    def _req(self, method: str, path: str, body: dict | None = None) -> dict:
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(
            self.base + path,
            data=data,
            method=method,
            headers={"X-Relay-Secret": self.secret, "Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read() or b"{}")

    def register(self, s: dict):
        return self._req("POST", "/relay/register", {
            "node_id": s["NODE_ID"],
            "host": s["PUBLIC_HOST"],
            "port": s["BUYER_PORT"],
            "region": s["REGION"],
            "city": s["CITY"],
            "public_key": s["REALITY_PUBLIC_KEY"],
            "short_id": s["REALITY_SHORT_ID"],
            "server_name": s["REALITY_SERVER_NAME"],
            "seller_port": s["SELLER_PORT"],
            "portal_slots": s["PORTAL_SLOTS"],
        })

    def heartbeat(self, node_id: str, active_sessions: int):
        return self._req("POST", "/relay/heartbeat", {
            "node_id": node_id,
            "active_sessions": active_sessions,
            "cpu_percent": _cpu_percent(),
            "memory_percent": _memory_percent(),
        })

    def live_sessions(self, node_id: str) -> list:
        q = urllib.parse.urlencode({"node_id": node_id})
        return self._req("GET", f"/relay/sessions?{q}").get("sessions", [])


def _cpu_percent() -> float:
    try:
        return round(os.getloadavg()[0] / (os.cpu_count() or 1) * 100, 1)
    except OSError:
        return 0.0


def _memory_percent() -> float:
    try:
        info = {}
        for line in Path("/proc/meminfo").read_text().splitlines():
            k, v = line.split(":", 1)
            info[k] = int(v.split()[0])
        return round(100 * (1 - info["MemAvailable"] / info["MemTotal"]), 1)
    except Exception:
        return 0.0


def _detect_public_ip() -> str:
    try:
        with urllib.request.urlopen("https://api.ipify.org", timeout=10) as r:
            return r.read().decode().strip()
    except Exception:
        return ""


def xray_pid() -> int | None:
    """PID of the long-running `xray run`, ignoring this agent's `xray api` calls."""
    pids = []
    for d in Path("/proc").iterdir():
        if not d.name.isdigit():
            continue
        try:
            argv = (d / "cmdline").read_bytes().split(b"\0")
        except OSError:
            continue
        if argv and os.path.basename(argv[0].decode(errors="replace")) == "xray" and b"run" in argv[1:]:
            pids.append(int(d.name))
    return min(pids) if pids else None


# ── The agent ───────────────────────────────────────────────────────────────

class Agent:
    def __init__(self, s: dict, api: XrayApi, backend: Backend, conns: SellerConnections):
        self.s, self.api, self.backend, self.conns = s, api, backend, conns
        self.state_path = Path(s["STATE_FILE"])
        self.applied: dict[str, dict] = {}
        self.xray_pid: int | None = None
        self._load_state()

    def _load_state(self):
        try:
            st = json.loads(self.state_path.read_text())
            self.applied = st.get("sessions", {})
            self.xray_pid = st.get("xray_pid")
        except (FileNotFoundError, ValueError):
            pass

    def _save_state(self):
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.state_path.with_suffix(".tmp")
        tmp.write_text(json.dumps({"xray_pid": self.xray_pid, "sessions": self.applied}))
        tmp.replace(self.state_path)

    def sync(self, live: list):
        pid = xray_pid()
        if pid is None:
            log.warning("xray is not running; nothing applied")
            return
        if pid != self.xray_pid:
            # A fresh Xray process has none of the runtime users or rules.
            if self.applied:
                log.info("xray restarted (pid %s -> %s); re-applying all sessions", self.xray_pid, pid)
            self.applied, self.xray_pid = {}, pid
            self._save_state()

        wanted = {
            str(x["session_id"]): x for x in live
            if x.get("slot") is not None and x.get("seller_uuid") and x.get("buyer_uuid")
        }
        for sid in [k for k in self.applied if k not in wanted]:
            self._remove(sid)
        for sid, x in wanted.items():
            if sid not in self.applied:
                self._add(sid, x)

    def _add(self, sid: str, x: dict):
        slot = int(x["slot"])
        # Clear any half-applied leftovers first, so this is safe to repeat.
        self.api.remove_rules([seller_email(sid), buyer_email(sid)])
        self.api.remove_user(SELLER_INBOUND, seller_email(sid))
        self.api.remove_user(BUYER_INBOUND, buyer_email(sid))
        try:
            self.api.add_user(SELLER_INBOUND, seller_email(sid), x["seller_uuid"])
            self.api.add_user(BUYER_INBOUND, buyer_email(sid), x["buyer_uuid"], BUYER_FLOW)
            self.api.add_rules(session_rules(sid, slot))
        except Exception as e:
            log.error("could not apply session %s: %s", sid, e)
            return
        self.applied[sid] = {"slot": slot}
        self._save_state()
        log.info("session %s live on slot %d", sid, slot)

    def _remove(self, sid: str):
        slot = self.applied[sid].get("slot")
        self.api.remove_rules([seller_email(sid), buyer_email(sid)])
        self.api.remove_user(SELLER_INBOUND, seller_email(sid))
        self.api.remove_user(BUYER_INBOUND, buyer_email(sid))
        peers = self.conns.take(seller_email(sid))
        still_open = cut_connections(peers, self.s["SELLER_PORT"]) if peers else set()
        if still_open:
            log.error(
                "session %s ended but %d seller connection(s) on slot %s are still open: %s. "
                "Slot %s may carry the next session's traffic to this seller.",
                sid, len(still_open), slot, sorted(still_open), slot,
            )
        del self.applied[sid]
        self._save_state()
        log.info("session %s removed from slot %s (cut %d connection(s))", sid, slot, len(peers) - len(still_open))

    def run(self, stop: threading.Event):
        while not stop.is_set():
            try:
                self.backend.register(self.s)
                log.info("registered %s as %s", self.s["NODE_ID"], self.s["PUBLIC_HOST"])
                break
            except Exception as e:
                log.warning("register failed, retrying in 10s: %s", e)
                stop.wait(10)

        next_heartbeat = 0.0
        while not stop.is_set():
            try:
                self.sync(self.backend.live_sessions(self.s["NODE_ID"]))
            except urllib.error.URLError as e:
                log.warning("could not reach backend: %s", e)
            except Exception:
                log.exception("sync failed")
            if time.monotonic() >= next_heartbeat:
                try:
                    self.backend.heartbeat(self.s["NODE_ID"], len(self.applied))
                except Exception as e:
                    log.warning("heartbeat failed: %s", e)
                next_heartbeat = time.monotonic() + self.s["HEARTBEAT_INTERVAL"]
            stop.wait(self.s["SYNC_INTERVAL"])


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("command", choices=["render-config", "run"])
    p.add_argument("--env", default="/etc/databric/relay.env")
    a = p.parse_args(argv)
    s = load_settings(a.env)

    if a.command == "render-config":
        json.dump(render_xray_config(s), sys.stdout, indent=2)
        print()
        return 0

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    missing = [k for k in ("BACKEND_URL", "RELAY_SECRET", "REALITY_PUBLIC_KEY", "REALITY_SHORT_ID") if not s[k]]
    if missing:
        log.error("missing settings: %s", ", ".join(missing))
        return 1
    if not s["PUBLIC_HOST"]:
        s["PUBLIC_HOST"] = _detect_public_ip()
        if not s["PUBLIC_HOST"]:
            log.error("PUBLIC_HOST is empty and the public IP could not be detected")
            return 1

    conns = SellerConnections(s["ACCESS_LOG"])
    stop = threading.Event()
    threading.Thread(target=conns.follow, args=(stop,), daemon=True).start()
    agent = Agent(s, XrayApi(s["XRAY_API"], s["XRAY_BIN"]), Backend(s["BACKEND_URL"], s["RELAY_SECRET"]), conns)
    try:
        agent.run(stop)
    except KeyboardInterrupt:
        stop.set()
    return 0


if __name__ == "__main__":
    sys.exit(main())
