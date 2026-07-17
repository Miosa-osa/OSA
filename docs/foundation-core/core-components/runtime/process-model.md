# Process Model

## Audience

Elixir/OTP engineers working on OSA internals. Assumes familiarity with GenServer, Supervisor, and ETS.

## Overview

OSA is structured as a four-tier OTP supervision tree rooted at `OptimalSystemAgent.Supervisor` with `:rest_for_one` strategy. A crash in the infrastructure layer restarts everything above it; crashes within a tier's children are isolated by each tier's own strategy.

## Supervision Tree

```
OptimalSystemAgent.Supervisor  (rest_for_one)
├── OptimalSystemAgent.TaskSupervisor          Task.Supervisor  (fire-and-forget async)
├── OptimalSystemAgent.Supervisors.Infrastructure  (rest_for_one)
│   ├── OptimalSystemAgent.SessionRegistry     Registry :unique
│   ├── OptimalSystemAgent.Events.TaskSupervisor  Task.Supervisor (max 100)
│   ├── Phoenix.PubSub
│   ├── OptimalSystemAgent.Events.Bus          GenServer
│   ├── OptimalSystemAgent.Events.DLQ          GenServer
│   ├── OptimalSystemAgent.Bridge.PubSub       GenServer
│   ├── OptimalSystemAgent.Store.Repo          Ecto SQLite3
│   ├── OptimalSystemAgent.EventStream         GenServer
│   ├── OptimalSystemAgent.Telemetry.Metrics   GenServer
│   ├── MiosaLLM.HealthChecker                 GenServer
│   ├── MiosaProviders.Registry                GenServer
│   ├── OptimalSystemAgent.Tools.Registry      GenServer
│   ├── OptimalSystemAgent.Tools.Cache         GenServer
│   ├── OptimalSystemAgent.Machines            GenServer
│   ├── OptimalSystemAgent.Commands            GenServer
│   ├── OptimalSystemAgent.OS.Registry         GenServer
│   ├── OptimalSystemAgent.MCP.Registry        Registry :unique
│   └── OptimalSystemAgent.MCP.Supervisor      DynamicSupervisor
├── OptimalSystemAgent.Supervisors.Sessions    (one_for_one)
│   ├── OptimalSystemAgent.Channels.Supervisor DynamicSupervisor
│   ├── OptimalSystemAgent.EventStreamRegistry Registry :unique
│   └── OptimalSystemAgent.SessionSupervisor   DynamicSupervisor
├── OptimalSystemAgent.Supervisors.AgentServices  (one_for_one)
│   ├── OptimalSystemAgent.Agent.Memory
│   ├── OptimalSystemAgent.Agent.HeartbeatState
│   ├── OptimalSystemAgent.Agent.Tasks
│   ├── MiosaBudget.Budget
│   ├── OptimalSystemAgent.Agent.Orchestrator
│   ├── OptimalSystemAgent.Agent.Progress
│   ├── OptimalSystemAgent.Agent.Hooks
│   ├── OptimalSystemAgent.Agent.Learning
│   ├── MiosaKnowledge.Store
│   ├── OptimalSystemAgent.Agent.Memory.KnowledgeBridge
│   ├── OptimalSystemAgent.Vault.Supervisor
│   ├── OptimalSystemAgent.Agent.Scheduler
│   ├── OptimalSystemAgent.Agent.Compactor
│   ├── OptimalSystemAgent.Agent.Cortex
│   └── OptimalSystemAgent.Webhooks.Dispatcher
├── OptimalSystemAgent.Supervisors.Extensions  (one_for_one, conditionally populated)
├── OptimalSystemAgent.Channels.Starter
└── Bandit  (HTTP, port 9089, started last)
```

## Per-Session Agent Processes

Each active session runs one `OptimalSystemAgent.Agent.Loop` process, a GenServer started inside `OptimalSystemAgent.SessionSupervisor` (a `DynamicSupervisor`).

Sessions are registered in `OptimalSystemAgent.SessionRegistry` (a `Registry` with `:unique` keys) using the via-tuple pattern:

```elixir
{:via, Registry, {OptimalSystemAgent.SessionRegistry, session_id, user_id}}
```

The loop uses `:transient` restart strategy so it restarts only on crash, not on normal exit. The child spec is:

```elixir
%{
  id: {OptimalSystemAgent.Agent.Loop, session_id},
  start: {OptimalSystemAgent.Agent.Loop, :start_link, [opts]},
  restart: :transient,
  type: :worker
}
```

Looking up an existing session:

```elixir
Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id)
# => [{pid, user_id}] | []
```

## GenServer Patterns

Most singleton services follow a standard pattern:

```elixir
use GenServer
def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
```

Session-scoped processes use via-tuple registration:

```elixir
def start_link(session_id) do
  GenServer.start_link(__MODULE__, session_id, name: via(session_id))
end

defp via(session_id) do
  {:via, Registry, {OptimalSystemAgent.EventStreamRegistry, session_id}}
end
```

The `Agent.Loop` intentionally blocks its mailbox during LLM calls by using `GenServer.call` with `:infinity` timeout. Cancellation is handled out-of-band via ETS (see Concurrency Patterns).

## ETS Tables Created at Boot

OSA creates seven named ETS tables in `Application.start/2` before the supervision tree starts:

| Table | Access | Purpose |
|-------|--------|---------|
| `:osa_cancel_flags` | public set | Per-session cancellation flags; read by Loop each iteration |
| `:osa_files_read` | public set | Read-before-write tracking for pre_tool_use hook |
| `:osa_survey_answers` | public set | HTTP endpoint writes; Loop polls for ask_user_question |
| `:osa_context_cache` | public set | Ollama model context window sizes (avoids repeated HTTP calls) |
| `:osa_survey_responses` | public bag | Survey/waitlist data when platform DB is disabled |
| `:osa_session_provider_overrides` | public set | Hot-swap provider/model per session via API |
| `:osa_pending_questions` | public set | Tracks blocked ask_user_question calls for `/pending_questions` endpoint |

Additional ETS tables created by specific services:

| Table | Owner | Purpose |
|-------|-------|---------|
| `:osa_event_handlers` | `Events.Bus` | Registered handler functions by event type |
| `:osa_dlq` | `Events.DLQ` | Failed event retry queue |
| `:osa_telemetry` | `Telemetry.Metrics` | Runtime metrics snapshot |
| `:osa_rate_limits` | `HTTP.RateLimiter` | Per-IP token bucket state |

## Process Linking and Monitoring

`Events.Stream` monitors its subscribers with `Process.monitor/1`. When a monitored subscriber process exits, the stream automatically removes it from the subscriber list via `handle_info({:DOWN, ...})`.

The `Bridge.PubSub` registers handlers with `Events.Bus` after a short delay (`Process.send_after(self(), :register_bridge, 100)`) to avoid a race with the bus initialization.

## Mailbox Patterns

`Agent.Loop` uses `handle_call` for message processing with `:infinity` timeout. Since the GenServer mailbox is blocked during LLM calls, cancellation uses ETS:

```elixir
# Cancel side — any process
:ets.insert(:osa_cancel_flags, {session_id, true})

# Loop side — checked each iteration
case :ets.lookup(:osa_cancel_flags, session_id) do
  [{_, true}] -> :cancelled
  _ -> :continue
end
```

`Telemetry.Metrics` uses `handle_cast` for all write operations to avoid blocking callers on metric updates, and `handle_info` to forward events it receives from its own Bus subscriptions.

## Boot Sequence

1. ETS tables created (before any process starts)
2. `Soul.load/0` and `PromptLoader.load/0` populate `:persistent_term` (before LLM calls)
3. Supervision tree starts in `:rest_for_one` order
4. After `{:ok, pid}`: Ollama model auto-detection runs synchronously (so banner shows correct model)
5. MCP server startup runs in a `Task` (asynchronous, registers tools when complete)
