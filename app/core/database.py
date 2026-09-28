from supabase import create_client, Client
from app.core.config import settings
import asyncpg
import logging

logger = logging.getLogger(__name__)

# ── Supabase client (for auth + realtime) ──────────────────────
_supabase_client: Client | None = None


def get_supabase() -> Client:
    global _supabase_client
    if _supabase_client is None:
        _supabase_client = create_client(
            settings.SUPABASE_URL,
            settings.SUPABASE_SERVICE_KEY
        )
    return _supabase_client


# ── asyncpg pool (for direct high-performance DB queries) ──────
_pool: asyncpg.Pool | None = None


async def get_pool() -> asyncpg.Pool:
    global _pool
    if _pool is None:
        # Extract connection string from Supabase URL
        # Format: postgresql://postgres:[password]@[host]:5432/postgres
        _pool = await asyncpg.create_pool(
            dsn=settings.DATABASE_URL,
            min_size=2,
            max_size=10,
            command_timeout=30,
            statement_cache_size=0,
        )
        logger.info("Database pool created")
    return _pool


async def close_pool():
    global _pool
    if _pool:
        await _pool.close()
        _pool = None
        logger.info("Database pool closed")


async def execute(query: str, *args):
    pool = await get_pool()
    async with pool.acquire() as conn:
        return await conn.execute(query, *args)


async def fetch(query: str, *args) -> list:
    pool = await get_pool()
    async with pool.acquire() as conn:
        return await conn.fetch(query, *args)


async def fetchrow(query: str, *args):
    pool = await get_pool()
    async with pool.acquire() as conn:
        return await conn.fetchrow(query, *args)


async def fetchval(query: str, *args):
    pool = await get_pool()
    async with pool.acquire() as conn:
        return await conn.fetchval(query, *args)
