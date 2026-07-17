# Monitoring

Audience: operators running OSA in production or staging environments.

---

## Health Check

The HTTP server exposes a health endpoint with no authentication required:

```
GET /health
```

Response:

```json
{
  "status": "ok",
  "version": "1.2.3",
  "provider": "anthropic",
  "model": "claude-opus-4-5",
  "uptime_seconds": 3841
}
```

`status` is always `"ok"` if the HTTP server is reachable. The endpoint does
not check provider connectivity or database health — it verifies only that the
BEAM application is running and the HTTP server is accepting requests.

Use this endpoint for load balancer health checks and basic process monitors
(systemd, k8s liveness probe, Docker healthcheck):

```
interval: 30s
timeout: 5s
start-period: 15s
retries: 3
```

For a readiness probe (confirms the tools registry is loaded and the
application is fully initialized), use `GET /api/v1/tools` — it returns 200
only after `Tools.Registry` has completed startup.

---

## SSE Event Stream

Every session exposes a real-time Server-Sent Events stream:

```
GET /api/v1/stream/:session_id
Authorization: Bearer <jwt>   (only when OSA_REQUIRE_AUTH=true)
Accept: text/event-stream
```

Each SSE message is a JSON-encoded `%OptimalSystemAgent.Events.Event{}` struct:

```
data: {"id":"uuid","type":"tool_call","payload":{"tool":"file_read","session_id":"cli:abc"},"timestamp":"2026-03-14T12:00:00Z"}

data: {"id":"uuid","type":"agent_response","payload":{"content":"Here is the result..."},"timestamp":"2026-03-14T12:00:01Z"}
```

The stream delivers:
- Up to 1,000 buffered historical events immediately on connection (from the
  `Events.Stream` circular buffer for that session)
- All subsequent live events as they are emitted

The stream stays open until the client disconnects or the session terminates.

```sh
curl -N -H "Accept: text/event-stream" \
  http://localhost:9089/api/v1/stream/cli:my_session_id
```

---

## Telemetry Events

OSA emits standard Telemetry events for all major operations. Attach handlers
to forward metrics to your backend (StatsD, Prometheus, Datadog, etc.):

```elixir
:telemetry.attach_many(
  "my-monitoring-handler",
  [
    [:optimal_system_agent, :llm, :request, :stop],
    [:optimal_system_agent, :tool, :execute, :stop],
    [:optimal_system_agent, :session, :start],
    [:optimal_system_agent, :session, :stop],
    [:optimal_system_agent, :budget, :exceeded]
  ],
  fn event_name, measurements, metadata, _config ->
    MyMetrics.record(event_name, measurements, metadata)
  end,
  nil
)
```

### Event reference

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[:osa, :llm, :request, :start]` | `%{system_time: integer}` | `%{provider, model, session_id}` |
| `[:osa, :llm, :request, :stop]` | `%{duration: native_time}` | `%{provider, model, session_id, input_tokens, output_tokens}` |
| `[:osa, :llm, :request, :exception]` | `%{duration: native_time}` | `%{provider, model, kind, reason}` |
| `[:osa, :tool, :execute, :start]` | `%{system_time: integer}` | `%{tool, session_id}` |
| `[:osa, :tool, :execute, :stop]` | `%{duration: native_time}` | `%{tool, session_id, success}` |
| `[:osa, :session, :start]` | `%{system_time: integer}` | `%{session_id, channel}` |
| `[:osa, :session, :stop]` | `%{duration: native_time}` | `%{session_id, channel, message_count}` |
| `[:osa, :budget, :exceeded]` | `%{system_time: integer}` | `%{session_id, budget_type, limit_usd, spent_usd}` |

Convert native time to milliseconds:

```elixir
ms = :erlang.convert_time_unit(measurements.duration, :native, :millisecond)
```

---

## Hooks Metrics

Query hook execution counts, timing, and block rates from IEx:

```elixir
OptimalSystemAgent.Agent.Hooks.metrics()
# => %{
#      {:pre_tool_use, "security_check"} => %{
#        call_count: 1_423, block_count: 3, avg_latency_us: 41
#      },
#      {:pre_tool_use, "spend_guard"} => %{
#        call_count: 1_423, block_count: 0, avg_latency_us: 12
#      }
#    }
```

High `block_count` on `spend_guard` indicates the budget limit was reached.
High `block_count` on `security_check` indicates blocked shell commands.

---

## Provider Health

Monitor circuit breaker state:

```elixir
MiosaLLM.HealthChecker.status()
# => %{
#      anthropic: %{state: :closed, failure_count: 0},
#      openai:    %{state: :open,   failure_count: 3, open_until: 1741959930},
#      ollama:    %{state: :closed, failure_count: 0}
#    }
```

| State | Meaning |
|-------|---------|
| `:closed` | Healthy — requests flow normally |
| `:open` | Failed 3 times — requests skipped for 30 seconds |
| `:half_open` | Cooldown expired — next request is a probe |
| `:rate_limited` | HTTP 429 received — skipped for 60 seconds or Retry-After duration |

---

## Budget Status

```elixir
MiosaBudget.Budget.status()
# => %{
#      daily_spent_usd: 12.43,
#      daily_limit_usd: 50.0,
#      monthly_spent_usd: 87.21,
#      monthly_limit_usd: 500.0,
#      per_call_limit_usd: 5.0,
#      resets_at: ~D[2026-03-15]
#    }
```

When a limit is exceeded:
1. `spend_guard` blocks all subsequent tool calls
2. `[:optimal_system_agent, :budget, :exceeded]` telemetry event is emitted
3. `:algedonic_alert` event fires on the event bus

---

## DLQ Status

```elixir
OptimalSystemAgent.Events.DLQ.size()
# => 0

OptimalSystemAgent.Events.DLQ.list()
# => [%{event_type: :tool_call, retries: 2, error: "...", next_retry_at: ...}]
```

A growing DLQ indicates a persistent event handler failure. Inspect entries,
fix the handler, and flush.

---

## Application Metrics (Built-in)

`OptimalSystemAgent.Telemetry.Metrics` tracks runtime statistics and writes a
JSON snapshot to `~/.osa/metrics.json` every 5 minutes.

Read current metrics:

```sh
curl http://localhost:9089/api/v1/analytics
```

Tracked metrics include: sessions per day, total messages, token usage,
top tools by call count, provider call counts, noise filter rate, and
signal weight distribution.

---

## BEAM VM Metrics

```elixir
# Process count (warn if > 5,000 for typical workloads)
:erlang.system_info(:process_count)

# Memory breakdown
:erlang.memory()
# => [total: N, processes: N, binary: N, ets: N, atom: N, ...]

# ETS memory specifically
:erlang.memory(:ets)
```

---

## Alerting Thresholds

| Condition | Threshold | Action |
|-----------|-----------|--------|
| Health endpoint down | `GET /health` non-200 | Restart; the OTP process may have crashed |
| Process count high | > 5,000 | Investigate session leak |
| Memory > 1 GB | `:erlang.memory(:total)` | Profile with `:recon_alloc` or restart |
| Budget exceeded | `budget.exceeded` telemetry | Review spend, adjust limits, or add credits |
| Provider p99 > 30s | Analytics endpoint | Switch provider via `OSA_DEFAULT_PROVIDER` |
| DLQ size > 100 | `DLQ.size()` | Investigate handler failure; flush and fix |
| SQLite file > 1 GB | `~/.osa/osa.db` size | Archive old sessions; see backup-recovery.md |

---

## Log Patterns to Alert On

| Pattern | Level | Meaning |
|---------|-------|---------|
| `[loop] Output guardrail` | warning | Possible system prompt leak in response |
| `[DLQ] Enqueued failed` | warning | Event handler crashed |
| `[loop] Budget exceeded` | warning | Tool calls are being blocked |
| `[Compactor] Emergency truncate` | warning | Context window full — hard truncation |
| `[HealthChecker] Circuit breaker OPEN` | warning | Provider marked unhealthy |
| `[Bus] Signal failure mode` | warning | Signal Theory anomaly |

---

## Related

- [Runtime Behavior](./runtime-behavior.md) — supervision, restart semantics, state persistence
- [Incident Handling](./incident-handling.md) — what to do when alerts fire
- [Performance Tuning](./performance-tuning.md) — context window, token budget, connection pools
