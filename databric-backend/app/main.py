from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.exceptions import RequestValidationError
from fastapi.encoders import jsonable_encoder
from contextlib import asynccontextmanager
import logging
import sys

from app.core.config import settings
from app.core.database import get_pool, close_pool
from app.middleware.logging import LoggingMiddleware, RateLimitMiddleware
from app.api import auth, users, friends, sessions, relay

# ── Logging ────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.DEBUG if not settings.is_production else logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
logger = logging.getLogger(__name__)


# ── Lifespan ───────────────────────────────────────────────────
@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info(f"DataBric API starting — env={settings.APP_ENV}")
    # Warm up DB pool
    try:
        await get_pool()
        logger.info("Database pool ready")
    except Exception as e:
        logger.warning(f"DB pool not available on startup: {e}")
    yield
    await close_pool()
    logger.info("DataBric API shutdown complete")


# ── App ────────────────────────────────────────────────────────
app = FastAPI(
    title="DataBric API",
    description="Backend for the DataBric mobile data sharing platform",
    version="1.0.0",
    docs_url="/docs" if not settings.is_production else None,
    redoc_url="/redoc" if not settings.is_production else None,
    lifespan=lifespan,
)

# ── Middleware ─────────────────────────────────────────────────
# The mobile client doesn't use Origin headers; CORS exists mainly for the
# OpenAPI docs UI in dev. Be explicit about methods/headers so a future docs
# host doesn't accidentally widen the surface.
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.allowed_origins_list,
    allow_credentials=True,
    allow_methods=["GET", "POST", "PATCH", "DELETE", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type", "X-Request-ID", "X-Relay-Secret"],
)
app.add_middleware(LoggingMiddleware)
app.add_middleware(RateLimitMiddleware, max_requests=100, window_seconds=60)

# ── Routers ────────────────────────────────────────────────────
app.include_router(auth.router)
app.include_router(users.router)
app.include_router(friends.router)
app.include_router(sessions.router)
app.include_router(relay.router)


# ── Global error handlers ──────────────────────────────────────
@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception):
    logger.error(f"Unhandled exception on {request.url.path}: {exc}", exc_info=True)
    return JSONResponse(
        status_code=500,
        content={"detail": "An unexpected error occurred. Please try again."}
    )

@app.exception_handler(RequestValidationError)
async def validation_exception_handler(request: Request, exc: RequestValidationError):
    # Pydantic v2 sometimes embeds non-JSON-serializable objects (e.g. the
    # raw ValueError instance) inside the ctx of each error. Run it through
    # jsonable_encoder so the response can always be serialized.
    details = jsonable_encoder(exc.errors())
    logger.error(f"Validation error on {request.url.path}: {details}")
    return JSONResponse(status_code=422, content={"detail": details})
# ── Health check ───────────────────────────────────────────────
@app.get("/health", tags=["system"])
async def health_check():
    return {
        "status": "ok",
        "env": settings.APP_ENV,
        "version": "1.0.0",
    }


@app.get("/", tags=["system"])
async def root():
    return {"message": "DataBric API", "docs": "/docs"}
