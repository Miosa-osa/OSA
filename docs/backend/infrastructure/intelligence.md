# Infrastructure: Intelligence (Proactive Mode)

> **⚠ PLANNED / NOT IMPLEMENTED.** The `OptimalSystemAgent.Agent.ProactiveMode`
> GenServer described throughout this document **does not exist** in `lib/`.
> There is no `ProactiveMode` module, no `proactive_mode` config key, no
> `~/.osa/data/proactive_log.jsonl` activity log, and no autonomous
> cron/heartbeat/trigger scheduler wired to a proactive coordinator. This page
> describes an intended design, not shipped behavior.
>
> **What actually ships today (all unrelated to a single coordinator):**
> - `Agent.Loop.ProactiveCompaction` — proactive context-window compaction inside
>   the agent loop (config: `proactive_compaction_enabled`,
>   `proactive_compaction_threshold`, `proactive_compaction_keep_turns`). Not a
>   supervised process.
> - `POST /sessions/:id/proactive` → `SessionManager.set_proactive/1` — a
>   per-session toggle that flags one session.
> - `Agent.Scheduler` + `Agent.Scheduler.HeartbeatExecutor` — real AgentServices
>   children that run scheduled/heartbeat work (but do not route through any
>   `ProactiveMode`).
> - A passive CLI handler (`Events.register_proactive_handler/1`) that renders
>   `:proactive_message` bus events if any are emitted — no supervised producer
>   emits them today.
>
> See [../../features/proactive-mode.md](../../features/proactive-mode.md) for the
> canonical planned-feature spec.

`Agent.ProactiveMode` **would be** the central coordinator for OSA's autonomous behaviour. It **would** gate all background-initiated LLM calls through rate limiting, budget enforcement, and permission tier checks, and deliver notifications to the active user session.

---

## Overview

ProactiveMode bridges three event sources — the Scheduler, the Event Bus, and direct API calls — to the user:

```
Scheduler (cron jobs, heartbeat, triggers)
    |
    v              rate limit (5/hr, 30s gap)
ProactiveMode  <-- budget check (MiosaBudget)
    |              permission tier (:workspace)
    v
Events.Bus (proactive_message event)
    |
    v
Active CLI/HTTP session (delivery)
```

Disabled by default. Enable with `/proactive on` or `ProactiveMode.enable/0`.

---

## Configuration

```elixir
config :optimal_system_agent,
  proactive_mode: false    # initial enabled state (overridden by ~/.osa/config.json)
```

Enabled state is persisted to `~/.osa/config.json` under the key `"proactive_mode"`. On restart, the GenServer reads this file to restore the previous state.

Activity is logged to `~/.osa/data/proactive_log.jsonl` in newline-delimited JSON. Up to 100 entries are kept in memory; the log file grows unbounded until cleared.

---

## Rate Limiting

All outbound proactive messages (notifications, autonomous results) are governed by two limits:

| Limit | Value |
|-------|-------|
| Max messages per hour | 5 |
| Min interval between messages | 30 seconds |

A delivery check runs every 5 seconds (`Process.send_after(self(), :delivery_check, 5_000)`). If a pending notification exists and both rate limits allow, it is emitted to the Bus. The hourly counter resets every 60 minutes.

Pending notifications queue up in state; they are not dropped when rate-limited, only delayed.

---

## Public API

```elixir
# Lifecycle
ProactiveMode.enable()             # persist + emit system_event
ProactiveMode.disable()
ProactiveMode.toggle()
ProactiveMode.enabled?()           # safe — returns false on process not running

# Session binding
ProactiveMode.set_active_session("sess-abc")   # target for message delivery
ProactiveMode.clear_active_session()           # user disconnected

# Notifications
ProactiveMode.notify("Backup complete", :work_complete)

# Alert from ProactiveMonitor
ProactiveMode.handle_alert(%{severity: :critical, message: "Disk at 95%"})

# Scheduler integration
ProactiveMode.schedule_work(%{
  name: "daily-review",
  schedule: "0 9 * * *",
  task: "Summarize open tasks"
})
ProactiveMode.add_heartbeat_task("Review logs")
ProactiveMode.add_trigger(%{"id" => "on-error", "event" => "tool_result", "action" => %{...}})

# Activity log
ProactiveMode.activity_log()                    # all entries
ProactiveMode.activity_since(~U[2026-03-08 00:00:00Z])
ProactiveMode.clear_activity_log()

# Status
ProactiveMode.status()
# => %{
#      enabled: true,
#      messages_this_hour: 2,
#      max_messages_per_hour: 5,
#      active_session: "sess-abc",
#      pending_notifications: 0,
#      activity_log_count: 47,
#      permission_tier: :workspace,
#      scheduler: %{cron_active: 3, ...}
#    }

# Session greeting
ProactiveMode.greeting("sess-abc")
# => {:ok, "Good morning. While you were away: 2 autonomous_complete. Active: 3 cron jobs."}
# => :skip  (disabled or first-run)
```

---

## Alert Handling

`handle_alert/1` would be called by `ProactiveMonitor` when a monitoring condition triggers (note: `ProactiveMonitor` is itself part of the unbuilt Signal Theory intelligence subsystem — it does not exist in `lib/`):

```elixir
ProactiveMode.handle_alert(%{
  severity: :critical | :warning | :info,
  message: "Disk at 95%"
})
```

**When proactive mode is enabled and `autonomous_work` is true:**

- Logs the alert to the activity log.
- For `:critical` severity: calls `maybe_dispatch_autonomous/2` (see below).
- For all severities: queues a `[severity] message` notification.

**When disabled:** alert is silently dropped.

---

## Autonomous Work Dispatch

For critical alerts, ProactiveMode can dispatch an autonomous agent run:

```
maybe_dispatch_autonomous(alert, state)
  |-> MiosaBudget.Budget.check_budget()
  |     -> budget exceeded: log "skipped", return
  |-> Task.Supervisor.start_child(Events.TaskSupervisor, fn ->
  |     Agent.Loop.process_message(
  |       "proactive_#{timestamp}",
  |       "PROACTIVE ALERT (critical): #{message}\n\nInvestigate and take corrective action.",
  |       permission_tier: :workspace
  |     )
  |   end)
  |-> log "autonomous_started"

Result arrives as {:autonomous_result, alert_message, result}:
  -> {:ok, _}     : log "autonomous_complete", queue :work_complete notification
  -> {:error, _}  : log "autonomous_failed", queue :work_failed notification
```

The budget check is wrapped in a rescue/catch to default to `true` if `MiosaBudget` is unavailable. Autonomous sessions use the `:workspace` permission tier.

---

## Scheduler Event Subscriptions

At startup, ProactiveMode registers a Bus handler for `:system_event` to translate Scheduler completions into user notifications:

| Bus event | Notification |
|-----------|-------------|
| `cron_job_completed` | `"Cron job completed: {name}"` |
| `cron_job_failed` | `"Cron job failed: {name} — {reason}"` |
| `heartbeat_task_completed` | `"Heartbeat task done: {task[:60]}"` |
| `trigger_fired` | `"Trigger fired: {name}"` |

---

## Session Greeting

`greeting/1` is called by the CLI channel on session start. Returns `:skip` when:
- ProactiveMode is disabled.
- `greeting_enabled` is false.
- The `Onboarding.first_run?/0` check returns true.

When active, the greeting combines three parts:

1. **Time greeting** — "Good morning/afternoon/evening" based on UTC hour.
2. **"While you were away" summary** — activity log entries since the most recently modified session file in `~/.osa/sessions/`. Groups entries by type with counts.
3. **Scheduler hint** — active cron count, pending heartbeat count, active trigger count from `Scheduler.status/0`.

Example output:

```
Good morning. While you were away: 2 autonomous_complete, 1 heartbeat. Active: 3 cron jobs, 2 triggers.
```

---

## Activity Log Format

Each entry in `~/.osa/data/proactive_log.jsonl`:

```json
{"ts": "2026-03-08T10:30:00Z", "type": "autonomous_complete", "message": "Autonomous fix for: Disk at 95%"}
{"ts": "2026-03-08T10:00:00Z", "type": "cron_job_completed",  "message": "Cron job completed: daily-summary"}
{"ts": "2026-03-08T09:30:00Z", "type": "alert:critical",      "message": "Disk at 95%"}
```

Common `type` values: `scheduled`, `heartbeat`, `trigger`, `alert:{severity}`, `autonomous_started`, `autonomous_complete`, `autonomous_failed`, `autonomous_skipped`, `info`, `work_complete`, `work_failed`.

---

## Bus Events Emitted

| Event type | Payload |
|---|---|
| `:system_event` | `%{event: :proactive_mode_changed, enabled: true/false}` |
| `:system_event` | `%{event: :proactive_message, session_id: id, message: text, message_type: type}` |

---

## See Also

- [scheduler.md](scheduler.md) — Cron engine; `ProactiveMode` delegates schedule_work and add_heartbeat_task here
- [../events/bus.md](../events/bus.md) — Bus events consumed and emitted by ProactiveMode
- [sandbox.md](sandbox.md) — Execution environment for autonomous agent work
