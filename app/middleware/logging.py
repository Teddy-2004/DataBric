from fastapi import Request
from starlette.middleware.base import BaseHTTPMiddleware
import time
import logging
import uuid

logger = logging.getLogger(__name__)


class LoggingMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        request_id = str(uuid.uuid4())[:8]
        start = time.time()

        # Skip logging for health checks to reduce noise
        if request.url.path == "/health":
            return await call_next(request)

        logger.info(
            f"[{request_id}] {request.method} {request.url.path}"
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

    def _get_client_ip(self, request: Request) -> str:
        forwarded = request.headers.get("X-Forwarded-For")
        if forwarded:
            return forwarded.split(",")[0].strip()
        return request.client.host if request.client else "unknown"

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

        ip = self._get_client_ip(request)
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
