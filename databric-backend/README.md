# DataBric Backend

FastAPI backend for the DataBric mobile data sharing platform.

## Architecture Overview

```
Flutter App (Android)
    │
    │ VLESS+Reality (disguised as HTTPS)
    ▼
Cloudflare Tunnel  ──►  Relay Node (Xray-core)
                              │
                              │ REST API
                              ▼
                        FastAPI Backend
                              │
                              ▼
                        Supabase (PostgreSQL)
```

## Project Structure

```
databric-backend/
├── app/
│   ├── main.py                  ← FastAPI app, middleware, routers
│   ├── api/
│   │   ├── auth.py              ← OTP send/verify, JWT, device registration
│   │   ├── users.py             ← Profile update, user search
│   │   ├── friends.py           ← Friend invite, accept, block, list
│   │   ├── sessions.py          ← Start/stop sharing, connect, history
│   │   └── relay.py             ← Internal: usage heartbeats, node health
│   ├── core/
│   │   ├── config.py            ← Settings from environment variables
│   │   ├── database.py          ← Supabase + asyncpg connection pool
│   │   └── security.py          ← JWT verification, auth dependency
│   ├── models/
│   │   └── schemas.py           ← All Pydantic request/response models
│   ├── services/
│   │   ├── otp_service.py       ← Africa's Talking SMS OTP
│   │   ├── notification_service.py ← Firebase FCM push notifications
│   │   └── relay_service.py     ← VLESS URI generation, session management
│   └── middleware/
│       └── logging.py           ← Request logging + rate limiting
├── xray/
│   └── config.json              ← Xray-core VLESS+Reality server config
├── scripts/
│   ├── schema.sql               ← Complete database schema (run in Supabase)
│   └── setup_relay.sh           ← One-command relay node setup on VPS
├── tests/
│   └── test_backend.py          ← 14 tests covering all core logic
├── Dockerfile
├── render.yaml                  ← One-click deploy to Render
└── requirements.txt
```

## Quick Start (Development)

### 1. Clone and install

```bash
git clone https://github.com/your-org/databric-backend
cd databric-backend
pip install -r requirements.txt
```

### 2. Set up Supabase

1. Create a project at supabase.com
2. Go to SQL Editor and run `scripts/schema.sql`
3. Copy your Project URL and service role key

### 3. Configure environment

```bash
cp .env.example .env
# Edit .env with your Supabase URL, keys, and other config
```

### 4. Run locally

```bash
uvicorn app.main:app --reload --port 8000
```

API docs available at: http://localhost:8000/docs

### 5. Run tests

```bash
pytest tests/ -v
```

---

## API Endpoints

### Auth
| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/auth/otp/send` | Send OTP to phone number |
| POST | `/auth/otp/verify` | Verify OTP, get JWT token |
| POST | `/auth/device` | Register FCM token for push notifications |
| GET | `/auth/me` | Get current user profile |

### Users
| Method | Endpoint | Description |
|--------|----------|-------------|
| PATCH | `/users/me` | Update carrier, city, country, display name |
| GET | `/users/search?phone=...` | Find user by phone number |

### Friends
| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/friends` | List all friendships |
| POST | `/friends/invite` | Invite a friend by phone number |
| POST | `/friends/action` | Accept, block, or remove a friendship |

### Sessions
| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/sessions/start` | Seller: start sharing, get VLESS URI |
| POST | `/sessions/stop` | Seller: stop sharing |
| POST | `/sessions/connect` | Buyer: connect to friend's session |
| POST | `/sessions/disconnect` | Buyer: disconnect from session |
| GET | `/sessions/active` | Get current active session (seller or buyer) |
| GET | `/sessions/history` | Paginated transfer history |

### Relay (internal — relay nodes only)
| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/relay/register` | Relay node startup registration |
| POST | `/relay/heartbeat` | 30s health ping from relay node |
| POST | `/relay/usage` | 5s usage heartbeat per session |
| POST | `/relay/blocked` | Report carrier blocking event |

---

## Deploying to Render

1. Push to GitHub
2. Go to render.com → New Web Service → connect repo
3. Render detects `render.yaml` automatically
4. Set environment variables in Render dashboard
5. Deploy

---

## Setting Up a Relay Node

On a fresh Ubuntu 22.04 VPS (DigitalOcean or Hetzner):

```bash
export RELAY_SECRET="your-relay-secret-from-env"
sudo bash scripts/setup_relay.sh nairobi-1 KE Nairobi https://your-api.onrender.com
```

The script:
- Installs Xray-core
- Generates VLESS Reality keypair
- Configures the server
- Starts the relay monitor
- Registers with the backend automatically

---

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `SUPABASE_URL` | Yes | Your Supabase project URL |
| `SUPABASE_SERVICE_KEY` | Yes | Supabase service role key |
| `SUPABASE_JWT_SECRET` | Yes | From Supabase Settings → API |
| `SECRET_KEY` | Yes | Random 64-char string for JWT signing |
| `AT_API_KEY` | Yes (prod) | Africa's Talking API key |
| `AT_USERNAME` | Yes (prod) | Africa's Talking username |
| `RELAY_SECRET_KEY` | Yes | Shared secret with relay nodes |
| `FIREBASE_PROJECT_ID` | Yes (prod) | Firebase project ID |

---

## How the Sharing Flow Works

```
1. Seller opens app → taps "Start Sharing" → sets 2GB limit
   POST /sessions/start
   ← Returns VLESS+Reality URI

2. Flutter app loads URI into Xray-core library
   Xray-core opens tunnel: phone ←→ relay node (disguised as HTTPS)

3. Seller shares their session_id with a friend (via app invite)

4. Buyer taps "Connect to [friend]"
   POST /sessions/connect { seller_id: "..." }
   ← Returns VLESS+Reality URI for buyer

5. Buyer's Xray-core connects through relay → seller's phone → internet

6. Relay node sends usage every 5s:
   POST /relay/usage { session_id, bytes_delta, relay_secret }

7. At 95% usage → seller gets push notification warning
   At 100% → session auto-terminated, both users notified
```
