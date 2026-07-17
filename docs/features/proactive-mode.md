# Proactive Mode

> **⚠️ STATUS: PLANNED / NOT YET IMPLEMENTED.** As of v1.0.3 the
> `OptimalSystemAgent.Agent.ProactiveMode` GenServer described in this document
> **does not exist** in `lib/`. There is no ProactiveMode module, no
> `proactive_mode` config key, no `~/.osa/data/proactive_log.jsonl` activity log,
> and no autonomous cron/heartbeat/trigger scheduler. The only "proactive" code
> that ships today is unrelated: `Agent.Loop.ProactiveCompaction` (automatic
> context-window compaction) and a per-session `POST /sessions/:id/proactive`
> HTTP toggle (`SessionManager.set_proactive/1`) that flags a single session — it
> does **not** dispatch autonomous work. Everything below describes the *intended*
> design of an autonomous-work orchestrator, not shipping behavior.

Proactive mode is intended to be the primary orchestrator of autonomous work in OSA. When enabled, OSA would operate independently — greeting users on session start, reacting to system alerts with autonomous LLM calls, executing scheduled cron jobs, and maintaining an activity log accessible at any time.

Disabled by default. Planned toggle: `/proactive on|off` or via the HTTP API.

---

## What It Does

| Capability | Description |
|------------|-------------|
| Context-aware greeting | Greets the user by time of day, summarizes activity since last session |
| Autonomous work | Dispatches agent loops in response to critical alerts |
| Cron scheduling | Creates and manages time-based recurring jobs |
| Heartbeat tasks | Registers persistent background tasks |
| Event triggers | Fires autonomous work in response to bus events |
| Activity log | Persisted to `~/.osa/data/proactive_log.jsonl` |

---

## Rate Limiting and Budget Enforcement

All autonomous LLM calls route through ProactiveMode before reaching the agent loop. Two gates run before every outbound message:

**Rate limit:**
- Maximum 5 messages per hour
- Minimum 30 seconds between consecutive messages

**Budget check:**
- Calls `MiosaBudget.Budget.check_budget()` before every autonomous dispatch
- If the budget is exceeded, the work is skipped and logged as `autonomous_skipped`

Both limits apply to proactive-initiated work only, not to user-initiated conversations.

---

## Permission Tiers

Autonomous work runs under the `:workspace` permission tier by default. This grants file read/write access within the working directory but restricts network operations and shell commands to a safe subset.

The tier is stored in the GenServer state as `autonomous_permission_tier` and can be changed at the application config level.

---

## Enabling and Disabling

```elixir
# CLI
/proactive on
/proactive off

# Elixir API
OptimalSystemAgent.Agent.ProactiveMode.enable()
OptimalSystemAgent.Agent.ProactiveMode.disable()
OptimalSystemAgent.Agent.ProactiveMode.toggle()
```

The enabled state persists across restarts. It is stored in `~/.osa/config.json`:

```json
{
  "proactive_mode": true
}
```

---

## Alert Handling

ProactiveMode subscribes to `Events.Bus` on the `:system_event` topic. Alerts arrive via `handle_alert/1`:

```elixir
ProactiveMode.handle_alert(%{
  severity: :critical,
  message: "Memory usage at 95%"
})
```

| Severity | Action |
|----------|--------|
| `:critical` | Queues notification AND dispatches autonomous agent work (budget permitting) |
| Other | Queues notification only |

When an autonomous dispatch completes, the result is logged and the user receives a notification:

```
[work_complete] Autonomous fix for: Memory usage at 95%
```

If the agent errors, the failure is also logged and surfaced:

```
[work_failed] Autonomous fix failed: timeout
```

---

## Scheduling Work

```elixir
# Cron job (runs every 6 hours)
{:ok, job} = ProactiveMode.schedule_work(%{
  name:     "daily-digest",
  schedule: "0 */6 * * *",
  task:     "Generate a daily summary of recent activity and save to DAILY.md"
})

# Heartbeat task (persistent background task)
:ok = ProactiveMode.add_heartbeat_task(
  "Monitor disk usage and alert if above 80%"
)

# Event trigger
{:ok, trigger} = ProactiveMode.add_trigger(%{
  "name"  => "low-memory-responder",
  "event" => "system:memory_warning",
  "task"  => "Free memory by clearing caches"
})
```

When a scheduled job completes, ProactiveMode receives the `cron_job_completed` bus event and queues a notification for delivery to the active session.

---

## Notification Delivery

Notifications queue in process state and are delivered to the active CLI or HTTP session. Delivery runs every 5 seconds via an internal timer.

A message is delivered only when:
1. An active session is registered (`set_active_session/1` was called)
2. The rate limits are not exceeded
3. The pending queue is non-empty

Messages are emitted as `proactive_message` events on the bus:

```elixir
%{
  event:        :proactive_message,
  session_id:   "cli_abc123",
  message:      "Cron job completed: daily-digest",
  message_type: :work_complete
}
```

Message types: `:info`, `:alert`, `:work_complete`, `:work_failed`.

---

## Greeting

On session start, ProactiveMode generates a time-aware greeting that includes:

1. **Time of day** — "Good morning", "Good afternoon", or "Good evening"
2. **Activity since last session** — counts of each activity type from the log
3. **Scheduler status** — counts of active cron jobs, pending heartbeat tasks, and active triggers

Example:
```
Good morning. While you were away: 2 autonomous_complete, 1 cron_job. Active: 3 cron jobs, 1 trigger. Type /activity to review.
```

Greeting only fires when:
- Proactive mode is enabled
- `greeting_enabled` is true (default)
- The onboarding first-run flow is complete

---

## Activity Log

All activity is logged to `~/.osa/data/proactive_log.jsonl` — one JSON object per line. The last 100 entries are kept in memory.

```json
{"ts": "2026-03-08T10:05:00Z", "type": "autonomous_complete", "message": "Autonomous fix for: Memory usage..."}
{"ts": "2026-03-08T10:00:00Z", "type": "scheduled",           "message": "Created scheduled job: daily-digest"}
{"ts": "2026-03-08T09:55:00Z", "type": "alert:critical",      "message": "Memory usage at 95%"}
```

**Activity types:** `scheduled`, `heartbeat`, `trigger`, `alert:<severity>`, `autonomous_started`, `autonomous_complete`, `autonomous_failed`, `autonomous_skipped`, `info`, `work_complete`, `work_failed`.

```elixir
# Query the log
all_entries     = ProactiveMode.activity_log()
since_yesterday = ProactiveMode.activity_since(DateTime.add(DateTime.utc_now(), -86400, :second))

# Clear
ProactiveMode.clear_activity_log()
```

---

## Status

```elixir
ProactiveMode.status()
# Returns:
%{
  enabled:               true,
  greeting_enabled:      true,
  autonomous_work:       true,
  active_session:        "cli_abc123",
  messages_this_hour:    2,
  max_messages_per_hour: 5,
  activity_log_count:    47,
  pending_notifications: 0,
  permission_tier:       :workspace,
  scheduler:             %{cron_active: 3, heartbeat_pending: 1, trigger_active: 2}
}
```

---

## Configuration Reference

| Key | Default | Description |
|-----|---------|-------------|
| `max_messages_per_hour` | `5` | Proactive message rate cap |
| `min_message_interval_ms` | `30_000` | Minimum gap between messages |
| `autonomous_permission_tier` | `:workspace` | Permission level for autonomous agents |
| `greeting_enabled` | `true` | Show time-aware greeting on session start |
| `autonomous_work` | `true` | Dispatch autonomous agent loops for critical alerts |

---

## Events Consumed

ProactiveMode listens for these bus events to update its state and trigger notifications:

| Event | Action |
|-------|--------|
| `cron_job_completed` | Queue work_complete notification |
| `cron_job_failed` | Queue work_failed notification |
| `heartbeat_task_completed` | Queue work_complete notification |
| `trigger_fired` | Queue info notification |

---

## See Also

- [Tasks](tasks.md) — per-session task tracking and workflow decomposition
- [Hooks](hooks.md) — the `spend_guard` hook that enforces budget at the tool level
