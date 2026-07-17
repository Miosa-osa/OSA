# Channels: HTTP

The HTTP channel is a Plug.Router application served by Bandit on port 9089. It is the primary API surface consumed by MIOSA SDK clients, the web UI, and external integrations.

---

## Server Configuration

```elixir
config :optimal_system_agent,
  http_port: 9089,                  # default
  require_auth: false,              # set true in production
  jwt_secret: System.get_env("JWT_SECRET"),
  shared_secret: System.get_env("OSA_SHARED_SECRET"),
  cors_origin: "*"
```

The server is started as a supervised Bandit child. Port is read from config at start time.

---

## Module: `Channels.HTTP`

The top-level `Channels.HTTP` module handles pre-auth routes and delegates all `/api/v1/*` traffic to `Channels.HTTP.API`.

**Plug pipeline (outermost):**

1. `security_headers` — sets `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`, `X-XSS-Protection`, `Content-Security-Policy`, `Strict-Transport-Security`.
2. `cors_headers` — sets `Access-Control-Allow-Origin: *` and related CORS headers.
3. `Plug.Logger` (`:debug` level).

**Routes handled directly:**

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| `OPTIONS *` | Any | None | CORS preflight, returns 204 |
| `GET` | `/health` | None | Returns JSON with status, version, uptime, provider, model, context window |
| `GET` | `/onboarding/status` | None | First-run detection, system info, provider/template lists |
| `POST` | `/onboarding/setup` | None | Write config, reload soul, detect Ollama tiers, connect OS template |
| `forward /api/v1` | — | JWT | Delegates to `Channels.HTTP.API` |

---

## Module: `Channels.HTTP.API`

The authenticated API router. All endpoints under `/api/v1`.

**Plug pipeline (inner):**

1. `cors` — CORS headers + OPTIONS preflight halt.
2. `RateLimiter` — ETS token bucket per IP.
3. `validate_content_type` — requires `application/json` on POST/PUT/PATCH.
4. `authenticate` — JWT Bearer verification (see below).
5. `Integrity` — HMAC-SHA256 request body check (optional, see below).
6. `Plug.Parsers` (JSON, 1 MB limit).

Auth routes (`/api/v1/auth/*`), channel webhook routes (`/api/v1/channels/*`), and platform auth routes (`/api/v1/platform/auth/*`) bypass JWT authentication — each uses its own platform-specific verification.

When `require_auth: false` (development default), missing or invalid tokens are accepted and the user is assigned `"anonymous"`.

### Sub-router forwarding map

| Prefix | Module | Key endpoints |
|--------|--------|---------------|
| `/auth` | `AuthRoutes` | `POST /login`, `POST /logout`, `POST /refresh` |
| `/channels` | `ChannelRoutes` | `GET /`, `POST /*/webhook` (10 platforms) |
| `/sessions` | `SessionRoutes` | `GET /`, `POST /`, `GET /:id`, `DELETE /:id`, `GET /:id/messages`, `POST /:id/cancel` |
| `/fleet` | `FleetRoutes` | `POST /register`, `POST /heartbeat`, `POST /dispatch`, `GET /agents`, `GET /:id` |
| `/orchestrate` | `OrchestrationRoutes` | `POST /`, `POST /complex`, `GET /tasks`, `GET /:id/progress` |
| `/swarm` | `OrchestrationRoutes` | `POST /launch`, `GET /`, `GET /:id`, `DELETE /:id` |
| `/stream` | `AgentRoutes` | `GET /:session_id` (SSE) |
| `/tools` | `ToolRoutes` | `GET /`, `POST /:name/execute` |
| `/skills` | `ToolRoutes` | `GET /`, `POST /create` |
| `/commands` | `ToolRoutes` | `GET /`, `POST /execute` |
| `/memory` | `DataRoutes` | `POST /`, `GET /recall`, `GET /search` |
| `/models` | `DataRoutes` | `GET /`, `POST /switch` |
| `/analytics` | `DataRoutes` | `GET /` |
| `/scheduler` | `DataRoutes` | `GET /jobs`, `POST /reload` |
| `/webhooks` | `DataRoutes` | `POST /:trigger_id` |
| `/machines` | `DataRoutes` | `GET /` |
| `/events` | `ProtocolRoutes` | `POST /`, `GET /stream` |
| `/oscp` | `ProtocolRoutes` | `POST /` |
| `/tasks` | `ProtocolRoutes` | `GET /history` |
| `/command-center` | `CommandCenterRoutes` | `GET /`, `GET /agents`, `GET /tiers`, `GET /patterns`, `GET /metrics`, `GET /events`, `POST /sandboxes` |
| `/classify` | Inline | `POST /` — signal classification |
| `/knowledge` | `KnowledgeRoutes` | `GET /triples`, `GET /count`, `GET /context/:id`, `POST /assert`, `POST /retract`, `POST /sparql`, `POST /reason` |
| `/platform/auth` | `PlatformAuthRoutes` | Platform-level register/login/refresh |
| `/platform` | `PlatformRoutes` | Tenant/OS instance CRUD |

### Inline endpoint: `POST /api/v1/classify`

Classifies a message using `Signal.Classifier`. Returns signal dimensions:

```json
{
  "signal": {
    "mode": "linguistic",
    "genre": "directive",
    "type": "direct",
    "format": "text",
    "weight": 0.87
  }
}
```

---

## Authentication (`Channels.HTTP.Auth`)

HS256 JWT authentication. The shared secret is resolved from (in order):

1. `Application.get_env(:optimal_system_agent, :jwt_secret)`
2. `Application.get_env(:optimal_system_agent, :shared_secret)`
3. `JWT_SECRET` environment variable
4. `OSA_SHARED_SECRET` environment variable
5. Auto-generated ephemeral secret (logged as a warning — not suitable for production)

**Token claims:**

| Claim | Required | Description |
|-------|----------|-------------|
| `user_id` | Yes | User or client identifier |
| `exp` | Yes | Expiration (Unix seconds) |
| `iat` | No | Issued-at |
| `workspace_id` | No | Optional workspace scope |

**Token lifetimes:**
- Access token: 900 seconds (15 min).
- Refresh token: 604 800 seconds (7 days), carries `"type": "refresh"` claim.

**Key functions:**

| Function | Description |
|----------|-------------|
| `verify_token/1` | Verify Bearer token. Returns `{:ok, claims}` or `{:error, reason}` |
| `generate_token/1` | Issue a new access token for given claims |
| `generate_refresh_token/1` | Issue a long-lived refresh token |
| `refresh/1` | Validate refresh token, return new access + refresh pair |

Signature comparison uses `Plug.Crypto.secure_compare/2` to prevent timing attacks.

---

## Rate Limiter (`Channels.HTTP.RateLimiter`)

ETS-backed token bucket, no external dependencies.

**Limits:**

| Path | Limit |
|------|-------|
| `/api/v1/auth/*` | 10 req/min |
| `/api/v1/platform/auth/*` | 10 req/min |
| All other paths | 60 req/min |

ETS table `:osa_rate_limits` stores `{ip_string, token_count, last_refill_unix_seconds}`. Refill is proportional to elapsed time within the window. A background cleanup process runs every 5 minutes and removes entries older than 10 minutes.

Response headers: `X-RateLimit-Limit`, `X-RateLimit-Remaining`. On 429: `Retry-After`.

---

## Integrity Check (`Channels.HTTP.Integrity`)

HMAC-SHA256 request body verification. Enabled when `require_auth: true` (globally) or `require_fleet_integrity: true` (fleet paths only).

Bypassed for `/api/v1/auth/*` and `/health` — clients cannot sign before authenticating.

**Required headers:**

| Header | Format | Description |
|--------|--------|-------------|
| `X-OSA-Signature` | hex string | HMAC-SHA256 of payload |
| `X-OSA-Timestamp` | Unix seconds | Request timestamp |
| `X-OSA-Nonce` | any string | One-time nonce |

**Payload signed:** `timestamp + "\n" + nonce + "\n" + body`

**Timestamp window:** 300 seconds (5 min).

**Nonce deduplication:** ETS table `:osa_integrity_nonces`, reaped every 60 seconds via `:timer.apply_interval`.

Returns `401` with `integrity_check_failed` error on any violation.

---

## See Also

- [overview.md](overview.md) — Channel behaviour contract
- [messaging.md](messaging.md) — Channel webhook routes (10 platforms)
- [../events/bus.md](../events/bus.md) — Event types emitted by API routes
