# Infrastructure: Scheduler

`Agent.Scheduler` is the OSA cron engine. It provides three automation mechanisms: HEARTBEAT.md (periodic task lists), CRONS.json (structured scheduled jobs), and TRIGGERS.json (event-driven automation). All three share a circuit breaker that auto-disables failing jobs after 3 consecutive errors.

---

## HEARTBEAT.md

A markdown checklist file at `~/.osa/HEARTBEAT.md`. The scheduler reads and processes it every 30 minutes (configurable).

### Format

```markdown
## Periodic Tasks
- [ ] Check weather forecast and send a summary
- [ ] Scan inbox for urgent emails
- [x] Backup local notes (completed 2026-03-08T10:30:00Z)
```

Unchecked items (`- [ ]`) are collected, executed sequentially through `Agent.Loop.process_message/2`, and marked completed with a timestamp. Checked items are not re-processed.

### Configuration

```elixir
config :optimal_system_agent,
  heartbeat_interval: 1_800_000   # 30 minutes (default)
```

### API

```elixir
Scheduler.heartbeat()                        # trigger manually
Scheduler.add_heartbeat_task("Review logs")  # append a task to HEARTBEAT.md
Scheduler.next_heartbeat_at()                # return next DateTime
```

---

## CRONS.json

Structured scheduled jobs at `~/.osa/CRONS.json`. Checked every 60 seconds (1-minute resolution).

### File format

The top-level object has a `"jobs"` array (a bare array is rejected as
"unexpected format"):

```json
{
  "jobs": [
    {
      "id": "daily-summary",
      "name": "Daily Summary",
      "schedule": "0 9 * * *",
      "type": "agent",
      "job": "Summarize today's key events and send to Telegram",
      "enabled": true
    },
    {
      "id": "backup",
      "name": "Hourly Backup",
      "schedule": "0 * * * *",
      "type": "command",
      "command": "rsync -av ~/Documents /mnt/backup/",
      "enabled": true
    },
    {
      "id": "health-check",
      "name": "API Health Check",
      "schedule": "*/5 * * * *",
      "type": "webhook",
      "url": "https://api.example.com/health",
      "method": "GET",
      "headers": {},
      "on_failure": "agent",
      "failure_job": "Alert: API health check failed"
    }
  ]
}
```

### Job types

| Type | Required field | Execution |
|------|----------------|-----------|
| `"agent"` | `job` | `Agent.Loop.process_message(scheduler_session, job)` |
| `"command"` | `command` | Shell execution (same security checks as `shell_execute` tool) |
| `"webhook"` | `url` | Outbound HTTP request (`method`, `headers`). When `on_failure` is `"agent"` and a `failure_job` is set, that task runs via the agent loop on non-2xx |

### Cron expression syntax

5-field standard cron: `minute hour day-of-month month day-of-week`.

Supported field formats:
- `*` — any value
- `*/n` — every nth value
- `n` — exact value
- `n,m,...` — comma-separated list
- `n-m` — inclusive range

Parsing and matching is delegated to `Scheduler.CronEngine`.

---

## TRIGGERS.json

Event-driven automation at `~/.osa/TRIGGERS.json`. Triggers fire when matching events arrive on the Bus.

### File format

The top-level object has a `"triggers"` array. Each trigger is flat — the
task lives in a top-level `job` (for `type: "agent"`) or `command` (for
`type: "command"`) field, not a nested `action` object:

```json
{
  "triggers": [
    {
      "id": "on-tool-error",
      "name": "Alert on Tool Error",
      "event": "tool_result",
      "type": "agent",
      "job": "A tool error occurred at {{timestamp}}: {{payload}}",
      "enabled": true
    }
  ]
}
```

### Template interpolation

The `job` / `command` string supports three placeholders:
- `{{payload}}` — JSON-encoded event payload map.
- `{{payload.key}}` — a specific top-level key from the payload map.
- `{{timestamp}}` — ISO 8601 UTC timestamp.

### Bus registration

Triggers with an `"event"` field register a Bus handler at load time:

```elixir
# Each trigger with event: "tool_result" registers:
Bus.register_handler(:tool_result, fn payload ->
  Scheduler.fire_trigger("on-tool-error", payload)
end)
```

Only atoms already in the BEAM atom table are accepted (`String.to_existing_atom/1`). Unknown event names are skipped with a warning — prevents atom table exhaustion from user-supplied values.

Previous Bus handler references are unregistered when triggers are reloaded.

### Webhook triggers

Webhooks arriving at `POST /api/v1/webhooks/:trigger_id` call `Scheduler.fire_trigger/2` directly, passing the parsed request body as the payload.

---

## Circuit Breaker

Any job or trigger that fails 3 consecutive times has its circuit opened. Opened circuits are skipped until manually re-enabled.

```elixir
# Re-enable a job with an open circuit
Scheduler.toggle_job("daily-summary", true)  # resets failure count
```

Failure counts appear in `list_jobs/0` and `list_triggers/0` output:

```elixir
[
  %{
    "id" => "daily-summary",
    "enabled" => true,
    "failure_count" => 2,
    "circuit_open" => false,
    ...
  }
]
```

---

## Persistence (`Scheduler.Persistence`)

`CRONS.json` and `TRIGGERS.json` are read from disk at startup and on `reload_crons/0`. Writes use atomic replace: write to a temp file, then `File.rename/2` to the final path. This prevents partial writes on crash.

Validation is run before any write:
- Jobs require a non-empty `"name"`, a `"schedule"` (valid cron expression), a `"type"` of `agent`/`command`/`webhook`, and the type-specific field (`"job"`, `"command"`, or `"url"`). `"id"` and `"enabled"` are optional.
- Triggers require a non-empty `"name"`, an `"event"`, a `"type"` of `agent`/`command`, and the type-specific field (`"job"` or `"command"`).

---

## Runtime Management API

```elixir
# Jobs
Scheduler.list_jobs()
Scheduler.add_job(%{"name" => "New Job", "schedule" => "0 * * * *", "type" => "agent", "task" => "..."})
Scheduler.remove_job("job-id")
Scheduler.toggle_job("job-id", false)      # disable
Scheduler.run_job("job-id")                # run immediately
Scheduler.reload_crons()                   # reload CRONS.json + TRIGGERS.json

# Triggers
Scheduler.list_triggers()
Scheduler.add_trigger(%{...})
Scheduler.remove_trigger("trigger-id")
Scheduler.toggle_trigger("trigger-id", true)
Scheduler.fire_trigger("trigger-id", %{})  # fire manually

# Status
Scheduler.status()
# => %{cron_active: 3, cron_total: 5, trigger_active: 2, ...}
```

---

## HTTP Routes

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/v1/scheduler/jobs` | List all cron jobs |
| `POST` | `/api/v1/scheduler/reload` | Reload CRONS.json and TRIGGERS.json |
| `POST` | `/api/v1/webhooks/:trigger_id` | Trigger a named trigger via webhook |

---

## See Also

- [../events/bus.md](../events/bus.md) — Event types used by triggers
