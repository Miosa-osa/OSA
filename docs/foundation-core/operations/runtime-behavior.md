# Runtime Behavior

Audience: operators and developers who need to understand what OSA does at
runtime, how it recovers from failures, and what state survives restarts.

---

## OTP Supervision Guarantees

OSA uses four subsystem supervisors under a top-level `:rest_for_one`
supervisor. Each subsystem has its own failure semantics.

### Top-level: rest_for_one

```
OptimalSystemAgent.Supervisor  (rest_for_one)
├── Platform.Repo              (optional)
├── Task.Supervisor
├── Supervisors.Infrastructure
├── Supervisors.Sessions
├── Supervisors.AgentServices
├── Supervisors.Extensions
├── Channels.Starter
└── Bandit HTTP server
```

`:rest_for_one` means: if child N crashes, children N+1 through the end of
the list are stopped and restarted in order. A crash in `Infrastructure`
stops and restarts every child that started after it, because all other
subsystems depend on the event bus, registries, and storage that
`Infrastructure` manages.

A crash in `Extensions` (the last subsystem) restarts only Extensions
and the components below it (Channels.Starter, Bandit). Core functionality
is unaffected.

### Infrastructure: rest_for_one

```
Supervisors.Infrastructure  (rest_for_one)
├── SessionRegistry
├── Events.TaskSupervisor
├── Phoenix.PubSub
├── Events.Bus
├── Events.DLQ
├── Bridge.PubSub
├── Store.Repo
├── EventStream
├── Telemetry.Metrics
├── MiosaLLM.HealthChecker
├── MiosaProviders.Registry
├── Tools.Registry
├── Tools.Cache
├── Machines
├── Commands
├── OS.Registry
└── MCP.Client
```

`:rest_for_one` here ensures that if `Events.Bus` crashes, the DLQ (which
depends on Bus) is also restarted in correct order.

### Sessions: one_for_one

```
Supervisors.Sessions  (one_for_one)
├── Channels.Supervisor (DynamicSupervisor)
├── EventStreamRegistry
└── SessionSupervisor (DynamicSupervisor)
```

`:one_for_one`: a crashed channel adapter (e.g., the Telegram adapter) does
not affect the session supervisor or other channel adapters.

### AgentServices: one_for_one

```
Supervisors.AgentServices  (one_for_one)
├── Agent.Memory
├── Agent.HeartbeatState
├── Agent.Tasks
├── MiosaBudget.Budget
├── Agent.Orchestrator
├── Agent.Progress
├── Agent.Hooks
├── Agent.Learning
├── MiosaKnowledge.Store
├── Agent.Memory.KnowledgeBridge
├── Vault.Supervisor
├── Agent.Scheduler
├── Agent.Compactor
├── Agent.Cortex
└── Webhooks.Dispatcher
```

`:one_for_one`: each service is independent. A crash in `Agent.Scheduler`
does not restart `Agent.Memory` or `Agent.Hooks`.

### Session processes: DynamicSupervisor

Each active agent session is a child of `SessionSupervisor` (a
DynamicSupervisor with `:one_for_one` strategy). A crashed `Agent.Loop`
is restarted in isolation — other sessions are unaffected.

Session restart behavior:
- The loop restarts with its initial state (empty message history)
- ETS cancel flags for that session are cleared at restart
- Memory (SQLite) is not rolled back — persisted messages remain

---

## What Survives Process Restarts

### ETS tables (survive)

ETS tables listed in `application.ex` are created at application startup and
are owned by the application process, not by individual GenServers. They
survive any GenServer restart:

| Table | What it holds |
|-------|--------------|
| `:osa_cancel_flags` | Per-session cancellation flags |
| `:osa_files_read` | Read-before-write tracking |
| `:osa_survey_answers` | Pending ask_user answers |
| `:osa_context_cache` | Ollama model context sizes |
| `:osa_session_provider_overrides` | Hot-swapped provider/model per session |
| `:osa_pending_questions` | Questions blocking the agent loop |

ETS tables created inside a GenServer's `init/1` are owned by that GenServer
and are dropped when it crashes.

### SQLite (survives)

All conversation messages written via `Agent.Memory` are persisted to
SQLite before the LLM call is made. They survive any process restart and
application restart.

Budget spend records are persisted to SQLite. The daily and monthly counters
are accurate after restart.

### persistent_term (survives within a node run)

The tools registry and built-in tools list are stored in `persistent_term`
for lock-free reads. These are repopulated at application start and at each
tool registration. They do not survive application restarts — `Tools.Registry`
reregisters tools from the supervisor's `init/1`.

### In-memory state (lost on restart)

- Active session message buffers (the `messages` list in `Agent.Loop`)
- Hook registrations added programmatically at runtime (re-register in a
  supervised process)
- DLQ entries (ephemeral by design — the learning engine captures durable
  patterns)
- Cortex bulletin entries

---

## Memory Usage

OSA is designed for long-running operation on developer hardware. Memory
management strategies:

### ETS

ETS tables use BEAM-managed memory outside of the GC heap. Large tables
(e.g., `:osa_hooks`) grow slowly and are bounded by the number of registered
hooks. Tables are not cleared between sessions — entries accumulate until
the application restarts or an explicit delete is called.

### Context compaction

The `Agent.Compactor` prevents unbounded message list growth. It applies
progressive compression when the conversation approaches the configured
context window limit:

- 80% utilization → warning logged
- 85% → aggressive compression (merge, summarize warm zone)
- 90% → cold zone collapsed to key-facts summary (LLM call)
- 95% → emergency truncation (no LLM, hard drop)

Compaction is transparent to the user. It runs within the agent loop before
each LLM call.

### Go tokenizer

Accurate BPE token counting uses the pre-compiled Go binary in
`priv/go/tokenizer/`. If the binary is absent or incompatible, the system
falls back to a word-count heuristic (`words * 1.3 + punctuation * 0.5`).
The heuristic overestimates slightly — compaction triggers conservatively.

---

## Budget Tracking

The `MiosaBudget.Budget` GenServer tracks cumulative spend across all
sessions. Counters are persisted to SQLite after each tool call.

- Daily budget resets at midnight UTC.
- Monthly budget resets on the first of each month UTC.
- When daily or per-call limits are exceeded, `spend_guard` blocks all
  subsequent tool calls for all sessions (global, not per-session).
- An `:algedonic_alert` event is emitted when a limit is reached.

---

## Provider Fallback

When the primary provider fails (HTTP 5xx, timeout, circuit breaker open),
OSA automatically tries the next provider in the fallback chain:

1. The chain is auto-detected from configured API keys at startup.
2. Ollama is included only if it is reachable at boot (TCP check).
3. The active provider is removed from its own fallback chain (no self-loop).
4. Override: `OSA_FALLBACK_CHAIN=anthropic,openai,ollama`

Each provider failure is recorded by `MiosaLLM.HealthChecker`. After 3
consecutive failures, the circuit breaker opens for 30 seconds. Requests
skip the provider during the open window.

---

## Related

- [Monitoring](./monitoring.md) — health checks, telemetry, SSE stream
- [Performance Tuning](./performance-tuning.md) — context window, token budget, connection pools
- [Incident Handling](./incident-handling.md) — provider failure, DLQ overflow, budget alerts
