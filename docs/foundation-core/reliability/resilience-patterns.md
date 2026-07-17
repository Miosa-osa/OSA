# Resilience Patterns

## Overview

OSA's resilience model is built entirely on OTP supervision trees. Every
process that can fail is supervised. Restart policies are chosen based on the
dependency relationships between processes, not by convention. The result is a
system that recovers from individual component failures automatically, without
operator intervention and without cascading those failures to unrelated subsystems.

---

## OTP Supervision Tree

The supervision tree has two tiers: the root supervisor and four subsystem
supervisors. The root uses `:rest_for_one`; each subsystem uses the strategy
appropriate to its child relationships.

```
OptimalSystemAgent.Supervisor  [rest_for_one]
├── Platform.Repo              (opt-in: DATABASE_URL)
├── Task.Supervisor            (fire-and-forget async work)
├── Supervisors.Infrastructure [rest_for_one]
├── Supervisors.Sessions       [one_for_one]
├── Supervisors.AgentServices  [one_for_one]
├── Supervisors.Extensions     [one_for_one]
├── Channels.Starter
└── Bandit (HTTP, port 9089)
```

---

## Strategy Choices

### Root Supervisor: `rest_for_one`

The root supervisor uses `:rest_for_one`. If `Supervisors.Infrastructure`
crashes, OTP will restart it and every child started after it — Sessions,
AgentServices, Extensions, Channels.Starter, and Bandit. This is correct
behavior: the higher-level subsystems depend on Infrastructure's registries,
event bus, and PubSub being alive. Allowing Sessions to continue running
against a dead event bus would produce silent, hard-to-debug failures.

An Infrastructure crash is intentionally treated as a full subsystem reset.

### Infrastructure Supervisor: `rest_for_one`

Infrastructure itself uses `:rest_for_one` internally because its children have
strict startup ordering:

- `Events.TaskSupervisor` must start before `Events.Bus` (Bus spawns supervised tasks)
- `Events.Bus` must start before `Events.DLQ` and `Bridge.PubSub`
- `Bridge.PubSub` must start before `Telemetry.Metrics`
- `MiosaLLM.HealthChecker` must start before `MiosaProviders.Registry`

If any early child crashes, all children started after it must restart too.
`:rest_for_one` enforces this automatically.

Infrastructure children in startup order:

| Process | Type | Role |
|---|---|---|
| `SessionRegistry` | Registry | Maps session IDs to Loop PIDs |
| `Events.TaskSupervisor` | Task.Supervisor | Supervised async dispatch |
| `Phoenix.PubSub` | GenServer | Internal fan-out |
| `Events.Bus` | GenServer | goldrush-compiled event router |
| `Events.DLQ` | GenServer | Dead letter queue with retry |
| `Bridge.PubSub` | GenServer | SSE bridge to desktop/web clients |
| `Store.Repo` | Ecto.Repo | SQLite WAL-mode persistent store |
| `EventStream` | GenServer | SSE stream for Command Center |
| `Telemetry.Metrics` | GenServer | Metrics subscriber |
| `MiosaLLM.HealthChecker` | GenServer | Provider circuit breaker |
| `MiosaProviders.Registry` | GenServer | goldrush provider router |
| `Tools.Registry` | GenServer | goldrush tool dispatcher |
| `Tools.Cache` | GenServer | Tool result cache |
| `Machines` | GenServer | Machine template registry |
| `Commands` | GenServer | Slash command registry |
| `OS.Registry` | GenServer | OS template registry |
| `MCP.Registry` | Registry | MCP server name lookup |
| `MCP.Supervisor` | DynamicSupervisor | Per-MCP-server GenServers |

### Sessions Supervisor: `one_for_one`

A crashed CLI adapter should not restart the EventStreamRegistry or the
SessionSupervisor. Each channel adapter is independent. Sessions uses
`:one_for_one`.

| Process | Type | Role |
|---|---|---|
| `Channels.Supervisor` | DynamicSupervisor | Channel adapters (CLI, Telegram, etc.) |
| `EventStreamRegistry` | Registry | Per-session SSE streams |
| `SessionSupervisor` | DynamicSupervisor | Agent Loop processes |

`SessionSupervisor` is itself a `DynamicSupervisor` (strategy `:one_for_one`,
`max_children` configurable). Each agent session runs as one child under this
supervisor. A session crash restarts only that session's Loop process.

### AgentServices Supervisor: `one_for_one`

Agent services are independent GenServers. A Scheduler crash has no bearing on
Memory, Budget, or Hooks. Each service restarts in isolation.

| Process | Type | Role |
|---|---|---|
| `Agent.Memory` | GenServer | Working memory store |
| `Agent.HeartbeatState` | GenServer | Health heartbeat tracker |
| `Agent.Tasks` | GenServer | Task queue |
| `MiosaBudget.Budget` | GenServer | Token/cost budget with daily+monthly limits |
| `Agent.Orchestrator` | GenServer | Multi-agent coordination |
| `Agent.Progress` | GenServer | Long-task progress reporting |
| `Agent.Hooks` | GenServer | Hook pipeline (pre/post tool, pre/post LLM) |
| `Agent.Learning` | GenServer | Pattern capture and consolidation |
| `MiosaKnowledge.Store` | GenServer | Knowledge graph (Mnesia in prod, ETS in test) |
| `Agent.Memory.KnowledgeBridge` | GenServer | Memory-to-knowledge sync |
| `Vault.Supervisor` | Supervisor | Secret store |
| `Agent.Scheduler` | GenServer | Cron-style task scheduling |
| `Agent.Compactor` | GenServer | Context window compaction |
| `Agent.Cortex` | GenServer | Cross-session synthesis |
| `Agent.ProactiveMode` | GenServer | Autonomous outreach |
| `Webhooks.Dispatcher` | GenServer | Outbound webhook delivery |

### Extensions Supervisor: `one_for_one`

Extensions are opt-in and self-contained. A fleet management crash must not
restart the Python sidecar or the AMQP publisher. `:one_for_one` ensures
complete isolation between extension children.

---

## DynamicSupervisor: Session Management

Agent sessions are managed by `OptimalSystemAgent.SessionSupervisor`, a
`DynamicSupervisor` with strategy `:one_for_one`.

Key properties:

- `max_children` is configurable (default: unlimited)
- Each child is an `Agent.Loop` GenServer registered in `SessionRegistry`
- When a session terminates normally or crashes, OTP removes the child spec
- New sessions are started with `DynamicSupervisor.start_child/2`
- Sessions link to their channel process; if the channel exits, the session
  exits cleanly without waiting for an OTP restart

---

## Process Monitoring and Auto-Cleanup

Agent sessions link their `Agent.Loop` process to the originating channel
process (e.g., the CLI GenServer or the HTTP request handler). When the
linked channel process exits:

- The Loop receives an exit signal and terminates cleanly
- `SessionSupervisor` removes the child from its dynamic table
- `SessionRegistry` de-registers the session ID automatically
- Any ETS rows for the session (`osa_cancel_flags`, `osa_pending_questions`)
  are cleaned up by the Loop's `terminate/2` callback

This eliminates orphaned Loop processes after channel disconnections.

---

## goldrush-Compiled Dispatch

Event routing and tool dispatch use goldrush, which compiles event predicates
to native BEAM bytecode modules at startup via `glc:compile/2`. Two compiled
modules are central to resilience:

- `:osa_event_router` — routes typed events to registered handlers
- `:osa_tool_dispatcher` — dispatches tool calls to registered tool modules

Because goldrush compiles dispatch to bytecode, individual handler crashes do
not affect the compiled router module itself. If a handler function raises, the
router catches the error, passes the event to `Events.DLQ` for retry, and
continues processing subsequent events. The router module remains intact.

---

## Resilience Summary

| Concern | Mechanism |
|---|---|
| Infrastructure crash | `:rest_for_one` restarts all dependents |
| Individual service crash | `:one_for_one` isolates restart to crashed process |
| Session crash | `DynamicSupervisor` restarts Loop; conversation state recoverable |
| Channel crash | Isolated under `Channels.Supervisor`; other channels unaffected |
| Event handler crash | DLQ captures event; exponential backoff retry |
| Orphaned sessions | Process linking ensures cleanup on channel exit |
| Event dispatch | goldrush compiled module survives handler crashes |
| Provider failure | `HealthChecker` circuit breaker, automatic fallback chain |
