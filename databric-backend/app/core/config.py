from pydantic_settings import BaseSettings
from pydantic import field_validator
from typing import List
import os


class Settings(BaseSettings):
    # ── App ────────────────────────────────────────────────────
    APP_ENV: str = "development"
    SECRET_KEY: str = "change-me"
    ALLOWED_ORIGINS: str = "http://localhost:3000"

    # ── Supabase ───────────────────────────────────────────────
    SUPABASE_URL: str = ""
    SUPABASE_SERVICE_KEY: str = ""
    SUPABASE_JWT_SECRET: str = ""
    DATABASE_URL: str = ""

    # ── Africa's Talking ───────────────────────────────────────
    AT_API_KEY: str = ""
    AT_USERNAME: str = "sandbox"
    AT_SENDER_ID: str = "DataBric"

    # ── Twilio (WhatsApp OTP) ──────────────────────────────────
    # Real credentials live in .env / Render secrets — never commit them.
    TWILIO_ACCOUNT_SID: str = ""
    TWILIO_AUTH_TOKEN: str = ""
    TWILIO_WHATSAPP_FROM: str = "+14155238886"  # Twilio sandbox default

    # ── Firebase ───────────────────────────────────────────────
    FIREBASE_PROJECT_ID: str = ""
    FIREBASE_CREDENTIALS_PATH: str = "./firebase-credentials.json"

    # ── Relay ──────────────────────────────────────────────────
    RELAY_SECRET_KEY: str = "relay-secret"
    RELAY_NODES: str = ""

    # ── Usage ──────────────────────────────────────────────────
    USAGE_HEARTBEAT_INTERVAL: int = 5
    SESSION_WARNING_THRESHOLD: float = 0.95

    @property
    def allowed_origins_list(self) -> List[str]:
        return [o.strip() for o in self.ALLOWED_ORIGINS.split(",")]

    @property
    def is_production(self) -> bool:
        return self.APP_ENV == "production"

    @property
    def relay_nodes_list(self) -> List[dict]:
        """Parse RELAY_NODES env var into list of dicts."""
        nodes = []
        for entry in self.RELAY_NODES.split(","):
            entry = entry.strip()
            if not entry:
                continue
            parts = entry.split(":")
            if len(parts) == 3:
                nodes.append({
                    "region": parts[0],
                    "host": parts[1],
                    "port": int(parts[2])
                })
        return nodes

    class Config:
        env_file = ".env"
        env_file_encoding = "utf-8"
        case_sensitive = True


settings = Settings()


# Refuse to boot a production server with default placeholder secrets.
# Render generates SECRET_KEY and RELAY_SECRET_KEY automatically; a missing
# override here means the deploy is misconfigured.
if settings.is_production:
    _problems = []
    if settings.SECRET_KEY in ("", "change-me"):
        _problems.append("SECRET_KEY is unset or default 'change-me'")
    if settings.RELAY_SECRET_KEY in ("", "relay-secret"):
        _problems.append("RELAY_SECRET_KEY is unset or default 'relay-secret'")
    if not settings.SUPABASE_URL:
        _problems.append("SUPABASE_URL is empty")
    if not settings.DATABASE_URL:
        _problems.append("DATABASE_URL is empty")
    if "*" in settings.allowed_origins_list:
        _problems.append("ALLOWED_ORIGINS contains '*' (incompatible with allow_credentials)")
    if _problems:
        raise RuntimeError(
            "Refusing to start in production with insecure config: "
            + "; ".join(_problems)
        )
