# Health Checks

## Audience

Operators setting up load balancers, monitoring systems, and liveness probes for OSA.

## The /health Endpoint

OSA exposes a single health check endpoint at `GET /health`. It requires no authentication and bypasses the JWT auth plug and HMAC integrity plug.

**URL:** `GET http://localhost:9089/health`

**Response:** HTTP 200 with JSON body. This endpoint always returns 200 as long as the HTTP server is running — it is a liveness check, not a full readiness check.

### Response Schema

```json
{
  "status": "ok",
  "version": "1.0.002",
  "uptime_seconds": 3600,
  "provider": "anthropic",
  "model": "claude-sonnet-4-6",
  "context_window": 200000
}
```

| Field | Type | Description |
|-------|------|-------------|
| `status` | string | Always `"ok"` |
| `version` | string | Application version from `mix.exs` |
| `uptime_seconds` | integer | Seconds since `Application.start/2` was called |
| `provider` | string | Current default provider atom as string |
| `model` | string | Current active model name |
| `context_window` | integer | Model's context window size in tokens (from provider registry) |

### Implementation Details

Uptime is computed from a start timestamp stored in the application environment at boot:

```elixir
# In Application.start/2:
Application.put_env(:optimal_system_agent, :start_time, System.system_time(:second))

# In health check handler:
uptime = System.system_time(:second) - Application.get_env(:optimal_system_agent, :start_time, System.system_time(:second))
```

The model name is resolved dynamically: if `default_model` is configured, it is used directly. Otherwise the provider's default model is looked up via `MiosaProviders.Registry.provider_info/1`.

Context window size is queried from `MiosaProviders.Registry.context_window/1` at request time, which reads from the provider's configuration or the `:osa_context_cache` ETS table (for Ollama).

### Bypassing Auth

The `/health` path is explicitly whitelisted in two places:

1. `Channels.HTTP.Integrity` plug: `def call(%{path_info: ["health"]} = conn, _opts), do: conn`
2. The route is defined in `Channels.HTTP` (the outer router), before the `forward "/api/v1"` which applies auth.

This means `/health` is reachable regardless of `OSA_REQUIRE_AUTH` setting.

---

## Command Center Agent Health

For multi-agent deployments, the Command Center API exposes per-agent health:

**URL:** `GET /api/v1/command-center/agents/health`

Returns a summary of all registered agent health states.

**URL:** `GET /api/v1/command-center/agents/:name/health`

Returns health data for a specific named agent. Returns 404 if no health data is available for that agent.

These endpoints require JWT authentication when `OSA_REQUIRE_AUTH=true`.

---

## Uptime Tracking

Uptime tracking is implemented entirely in the `/health` handler with no dedicated GenServer. The start time is written once to the application environment and read at each health check request.

This means:
- Uptime resets on application restart (expected behavior)
- Uptime does not reset when individual GenServers crash and restart (uptime reflects application-level continuity, not process-level)
- The value is a wall-clock delta, not a monotonic counter — system clock adjustments can affect the value

---

## Liveness vs Readiness

OSA's `/health` endpoint is a **liveness check** only. It confirms the HTTP server is accepting connections and the application is running. It does not verify:

- LLM provider reachability
- SQLite database connectivity
- Session processing capability
- MCP server availability

For a readiness check before routing traffic, add a check of the provider registry or attempt a minimal LLM call. This is not built into OSA's health endpoint by design — readiness semantics vary by deployment and the health check is kept intentionally simple.

### Workaround for Deeper Checks

Call the analytics endpoint to verify end-to-end application state:

```bash
# Requires auth if OSA_REQUIRE_AUTH=true
curl -H "Authorization: Bearer $TOKEN" http://localhost:9089/api/v1/analytics
```

Or check the Providers.HealthChecker state from inside the application:

```elixir
OptimalSystemAgent.Providers.HealthChecker.state()
# => %{anthropic: %{circuit: :closed, ...}, openai: %{circuit: :half_open, ...}}
```

---

## Example Monitoring Configurations

### curl health check

```bash
curl -f http://localhost:9089/health && echo "OK" || echo "UNHEALTHY"
```

### Docker HEALTHCHECK

```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -f http://localhost:9089/health || exit 1
```

### Kubernetes liveness probe

```yaml
livenessProbe:
  httpGet:
    path: /health
    port: 9089
  initialDelaySeconds: 10
  periodSeconds: 30
  timeoutSeconds: 5
  failureThreshold: 3
```

### Docker Compose health check

```yaml
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost:9089/health"]
  interval: 30s
  timeout: 5s
  retries: 3
  start_period: 10s
```

---

## Port Configuration

The HTTP server runs on port 9089 by default. Override with:

```bash
OSA_HTTP_PORT=9000
```

Or in `config/config.exs`:

```elixir
config :optimal_system_agent, http_port: 9000
```

In test environment, `http_port: 0` causes Bandit to pick an OS-assigned port, allowing parallel test runs without conflicts.
