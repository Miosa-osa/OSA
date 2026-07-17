# Understanding the Core

Audience: developers who want to build on OSA or debug its internals. This
document gives you the mental model you need before reading any source code.

---

## OSA is a Supervised Process Tree

OSA is an OTP application. Every piece of state lives inside a supervised
process. If a process crashes, the supervisor restarts it according to a
defined strategy. Nothing is global mutable state. Nothing is a singleton
that can silently corrupt.

The top-level supervisor uses `:rest_for_one`. This means a crash in any
child takes down every child that was started after it. The ordering is:

```
OptimalSystemAgent.Supervisor  (rest_for_one)
├── Platform.Repo              (optional, PostgreSQL)
├── Task.Supervisor            (fire-and-forget async work)
├── Supervisors.Infrastructure (rest_for_one — core layer)
├── Supervisors.Sessions       (one_for_one — channels + session mgmt)
├── Supervisors.AgentServices  (one_for_one — memory, hooks, scheduler…)
├── Supervisors.Extensions     (one_for_one — opt-in subsystems)
├── Channels.Starter           (deferred channel boot)
└── Bandit HTTP server         (port 9089)
```

Infrastructure failing tears down everything above it because everything
depends on the event bus, registries, and storage. A session crashing (e.g.,
an Agent.Loop error) is isolated to that session's DynamicSupervisor child —
it does not affect other sessions or the infrastructure layer.

---

## Every Session is One GenServer

When a user connects — via CLI, HTTP, Telegram, Discord, or any other channel
— the channel adapter calls `Agent.Loop.start_link/1`. This spawns a GenServer
under `OptimalSystemAgent.SessionSupervisor` (a DynamicSupervisor) and
registers it by session ID in `OptimalSystemAgent.SessionRegistry`.

The Loop GenServer holds all per-session state:

- `session_id` and `user_id`
- Active `provider` and `model`
- `working_dir` for file tool operations
- Accumulated `messages` (the conversation window)
- `permission_tier` (`:read_only`, `:workspace`, or `:full`)
- Metrics: token usage, iteration count, tool call count

Each session is fully independent. Two concurrent sessions do not share
message state. Budget and memory are shared across sessions only when
explicitly written to the shared store.

---

## How a Message Flows Through the System

This is the critical path for every user message:

```
Channel (CLI / HTTP / Telegram / …)
  │
  ▼
Agent.Loop.process_message/2
  │
  ├─ 0. Guardrails: prompt injection check (hard block — no memory write)
  │
  ├─ 1. NoiseFilter: two-tier signal weight check
  │       Tier 1: deterministic regex (<1 ms)
  │       Tier 2: signal weight threshold (0.0–1.0)
  │       Result: :pass | :filtered | :clarify
  │
  ├─ 2. (pass) Persist user message to Agent.Memory (SQLite)
  │
  ├─ 3. Build context
  │       identity (Soul/personality)
  │       + memory (recent messages, recalled facts)
  │       + runtime state (tools, skills, hooks)
  │
  ├─ 4. GenreRouter: classify signal genre
  │       Some genres return a canned response (no LLM needed)
  │
  ├─ 5. LLM call (via MiosaProviders.Registry → provider module)
  │
  ├─ 6. Tool calls? (ReAct loop, up to max_iterations = 30)
  │       │
  │       ├─ Hooks.run(:pre_tool_use, payload)
  │       │     security_check (p10) — block dangerous shell commands
  │       │     spend_guard (p8)     — block if budget exceeded
  │       │     mcp_cache (p15)      — inject cached MCP schemas
  │       │
  │       ├─ ToolExecutor.execute_tool_call/2
  │       │     permission tier enforcement
  │       │     parallel dispatch via Task.async_stream
  │       │
  │       └─ Hooks.run_async(:post_tool_use, payload)
  │             cost_tracker (p25)   — record actual API spend
  │             telemetry (p90)      — emit tool timing telemetry
  │
  ├─ 7. Output guardrail: scrub system prompt echoes (Bug 17 mitigation)
  │
  ├─ 8. Persist assistant message to Agent.Memory
  │
  └─ 9. Send response back to channel
         Emit agent_response event on Events.Bus
```

Steps 5–6 repeat until the LLM returns a message with no tool calls, or
`max_iterations` is reached.

---

## Everything is an Event

`OptimalSystemAgent.Events.Bus` is the central nervous system. It uses
goldrush — compiled Erlang bytecode — for zero-overhead event routing. There
are no hash lookups at dispatch time; the routing logic is compiled to real
BEAM instruction sequences.

The full set of event types:

| Event type | Emitted by | Consumed by |
|------------|------------|-------------|
| `user_message` | Channels | Agent.Loop |
| `llm_request` | Agent.Loop | Providers.Registry |
| `llm_response` | Providers | Agent.Loop |
| `tool_call` | Agent.Loop | Tools.Registry |
| `tool_result` | Tools | Agent.Loop |
| `agent_response` | Agent.Loop | Channels, Bridge.PubSub |
| `system_event` | Scheduler, internals | Agent.Loop, Memory |
| `channel_connected` | Channel adapters | EventStream |
| `channel_disconnected` | Channel adapters | EventStream |
| `algedonic_alert` | DLQ, spend_guard | Operator alerting |
| `ask_user_question` | Agent.Loop | HTTP endpoint |
| `survey_answered` | HTTP endpoint | Agent.Loop |

Emit an event:

```elixir
Events.Bus.emit(:tool_call, %{tool: "file_read", session_id: sid})
```

Subscribe to an event type:

```elixir
Events.Bus.subscribe(:agent_response, fn event ->
  IO.inspect(event.payload)
end)
```

---

## Hooks Intercept at Lifecycle Points

`OptimalSystemAgent.Agent.Hooks` is a middleware pipeline that intercepts
agent actions at defined lifecycle points. Each hook is a function that
receives a payload map and returns `{:ok, payload}`, `{:block, reason}`,
or `:skip`.

Lifecycle points (hook events):

| Hook event | When it fires |
|------------|--------------|
| `:pre_tool_use` | Before every tool call — can block |
| `:post_tool_use` | After every tool call (async) |
| `:pre_compact` | Before context compaction |
| `:session_start` | When a new session is created |
| `:session_end` | When a session terminates |
| `:pre_response` | Before the final response is sent |
| `:post_response` | After the response is delivered |

Built-in hooks (registered at boot):

| Hook name | Event | Priority | Purpose |
|-----------|-------|----------|---------|
| `security_check` | `:pre_tool_use` | 10 | Block dangerous shell commands |
| `spend_guard` | `:pre_tool_use` | 8 | Block when budget is exceeded |
| `mcp_cache` | `:pre_tool_use` | 15 | Inject cached MCP tool schemas |
| `cost_tracker` | `:post_tool_use` | 25 | Record actual API spend |
| `mcp_cache_post` | `:post_tool_use` | 15 | Populate MCP schema cache |
| `telemetry` | `:post_tool_use` | 90 | Emit timing telemetry |

Hook registration is serialized through the GenServer (one write at a time).
Hook execution reads directly from ETS in the caller's process — no GenServer
bottleneck on the hot path.

---

## Phoenix.PubSub Fan-out

In addition to goldrush routing (point-to-point handlers registered on the
Bus), OSA uses `Phoenix.PubSub` for fan-out to multiple subscribers on
named topics. This is the mechanism that feeds the SSE event stream and
external WebSocket clients.

```elixir
# Subscribe to a session's events
Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "session:#{session_id}")

# Broadcast to all subscribers
Phoenix.PubSub.broadcast(OptimalSystemAgent.PubSub, "session:#{session_id}", {:event, event})
```

---

## Key ETS Tables

ETS tables are created at application start and survive individual process
restarts (they are owned by supervisors, not by the processes that read them).

| Table name | Type | Purpose |
|------------|------|---------|
| `:osa_cancel_flags` | set, public | Per-session loop cancellation flags |
| `:osa_files_read` | set, public | Read-before-write tracking per session |
| `:osa_survey_answers` | set, public | Answers to `ask_user_question` polls |
| `:osa_context_cache` | set, public | Ollama model context window sizes |
| `:osa_hooks` | bag, read_concurrency | Registered hooks by event type |
| `:osa_hooks_metrics` | set, write_concurrency | Hook call counts and timing |
| `:osa_commands` | — | Registered slash commands |
| `:osa_dlq` | — | Dead letter queue entries |
| `:osa_session_provider_overrides` | set, public | Per-session provider/model hot-swap |

---

## Summary

- OSA is a supervised process tree. Processes crash safely; supervisors restart them.
- Every session is one `Agent.Loop` GenServer, isolated from all other sessions.
- A message flows: Channel → Guardrails → NoiseFilter → Memory → Context → LLM → Tools → Response.
- Everything observable emits an event. Events route through goldrush at BEAM speed.
- Hooks intercept at lifecycle points. They can read, modify, or block payloads.
- Phoenix.PubSub handles fan-out to SSE streams and external subscribers.
- ETS tables provide lock-free reads for hot-path data.
