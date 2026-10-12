from fastapi import Request
from starlette.middleware.base import BaseHTTPMiddleware
import ipaddress
import time
import logging
import uuid

from app.core.config import settings

logger = logging.getLogger(__name__)


def client_ip(request: Request, trusted_hops: int | None = None) -> str:
    """
    The caller's IP, as far as it can be trusted.

    Each proxy in front of the app appends the address it received the
    request from to X-Forwarded-For. A client can put anything it likes in
    the header before it reaches the first proxy, so only the entries our
    own proxies appended (the rightmost `trusted_hops`) are believed.
    """
    hops = settings.TRUSTED_PROXY_HOPS if trusted_hops is None else trusted_hops
    peer = request.client.host if request.client else "unknown"
    if hops <= 0:
        return peer

    raw = ",".join(request.headers.getlist("x-forwarded-for"))
    chain = [h.strip() for h in raw.split(",") if h.strip()]
    if not chain:
        return peer
    # Fewer entries than proxies means the header was rewritten rather than
    # appended to; the leftmost entry is then the proxy's own value.
    candidate = chain[max(len(chain) - hops, 0)]
    try:
        return str(ipaddress.ip_address(candidate))
    except ValueError:
        return peer


class LoggingMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        request_id = str(uuid.uuid4())[:8]
        start = time.time()

        # Skip logging for health checks to reduce noise
        if request.url.path == "/health":
            return await call_next(request)

        # xff= is the number of X-Forwarded-For entries: it shows how many
        # proxies the request passed through (see TRUSTED_PROXY_HOPS).
        xff = sum(
            1 for v in request.headers.getlist("x-forwarded-for")
            for h in v.split(",") if h.strip()
        )
        logger.info(
            f"[{request_id}] {request.method} {request.url.path} "
            f"ip={client_ip(request)} xff={xff}"
        )

        response = await call_next(request)
        duration = round((time.time() - start) * 1000, 1)

        logger.info(
            f"[{request_id}] {response.status_code} {duration}ms"
        )

        response.headers["X-Request-ID"] = request_id
        return response


class RateLimitMiddleware(BaseHTTPMiddleware):
    """
    Best-effort, per-worker in-memory rate limiter.

    Note: this is per-process. With uvicorn --workers N, each worker has its
    own counter, so the effective ceiling is roughly N×max_requests per IP.
    For strict limits use a Redis-backed limiter.
    """
    # How often to sweep the whole dict for stale entries (in seconds).
    _PRUNE_INTERVAL = 300

    def __init__(self, app, max_requests: int = 60, window_seconds: int = 60):
        super().__init__(app)
        self.max_requests = max_requests
        self.window = window_seconds
        self._store: dict[str, list] = {}
        self._last_prune = time.time()

    def _maybe_prune(self, now: float) -> None:
        if now - self._last_prune < self._PRUNE_INTERVAL:
            return
        cutoff = now - self.window
        stale = [ip for ip, ts in self._store.items() if not ts or ts[-1] < cutoff]
        for ip in stale:
            self._store.pop(ip, None)
        self._last_prune = now

    async def dispatch(self, request: Request, call_next):
        # Skip rate limiting for relay internal endpoints
        if request.url.path.startswith("/relay/"):
            return await call_next(request)

        ip = client_ip(request)
        now = time.time()
        self._maybe_prune(now)

        if ip not in self._store:
            self._store[ip] = []

        # Remove old entries outside the window
        self._store[ip] = [t for t in self._store[ip] if now - t < self.window]

        if len(self._store[ip]) >= self.max_requests:
            from fastapi.responses import JSONResponse
            return JSONResponse(
                status_code=429,
                content={"detail": "Too many requests. Please slow down."}
            )

        self._store[ip].append(now)
        return await call_next(request)
