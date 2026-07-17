# Understanding Supervision Trees

A supervision tree is the organizational backbone of an OTP application. It is a
hierarchy of processes where every process has a parent responsible for it. When
something goes wrong, the tree determines what gets restarted and in what order.

If you have not read [beam-and-otp.md](./beam-and-otp.md) yet, read that first.
This guide assumes you understand BEAM processes and supervisors.

---

## What a Supervision Tree Is

Imagine a company org chart. At the top is the CEO. Reporting to the CEO are
department heads. Reporting to each department head are individual workers. If a
worker quits (crashes), their department head hires a replacement. If an entire
department collapses, the CEO decides whether to reconstruct that department or
shut down the company.

A supervision tree works the same way:

```
Application Supervisor (top-level)
├── Infrastructure Supervisor
│   ├── Registry process
│   ├── Event Bus process
│   └── Provider Router process
├── Sessions Supervisor
│   ├── Channel Supervisor (dynamic)
│   └── Session Supervisor (dynamic)
└── AgentServices Supervisor
    ├── Memory process
    ├── Scheduler process
    └── Learning process
```

Each supervisor watches its children. When a child crashes, the supervisor
decides what to restart based on its configured strategy.

---

## OSA's Supervision Tree

OSA's application supervisor starts these children in order using the
`:rest_for_one` strategy:

```
OptimalSystemAgent.Supervisor  (rest_for_one)
│
├── [Platform.Repo]             — optional PostgreSQL repo (if DATABASE_URL set)
├── Task.Supervisor             — general-purpose async task runner
│
├── Supervisors.Infrastructure  — registries, event bus, providers, tools
├── Supervisors.Sessions        — channel adapters, session process pool
├── Supervisors.AgentServices   — memory, orchestration, hooks, learning
├── Supervisors.Extensions      — optional subsystems (fleet, swarm, sidecars)
│
├── Channels.Starter            — deferred channel startup
└── Bandit (HTTP)               — HTTP API on port 9089, started last
```

The HTTP server is started last deliberately. All agent processes must be ready
before OSA accepts external requests.

---

## The Root Strategy: `:rest_for_one`

The top-level supervisor uses `:rest_for_one`. This matters because of the
startup dependency between the four subsystems.

If `Infrastructure` crashes — which provides the event bus, provider router, and
tool registry that everything else depends on — then `Sessions`, `AgentServices`,
and `Extensions` cannot function correctly. They hold references to Infrastructure
processes that no longer exist. `:rest_for_one` restarts Infrastructure and
everything that was started after it, giving the whole system a clean slate.

If `Sessions` crashes but `Infrastructure` is healthy, only `Sessions` and
`AgentServices` and `Extensions` restart. Infrastructure stays up. The recovery
is scoped to the minimum necessary.

---

## The Four Subsystems

### Infrastructure (`rest_for_one`)

```
Supervisors.Infrastructure  (rest_for_one)
├── SessionRegistry           — Registry for looking up sessions by ID
├── Events.TaskSupervisor     — Task pool for async event dispatch
├── Phoenix.PubSub            — Pub/sub for bridge and event streams
├── Events.Bus                — goldrush-compiled :osa_event_router
├── Events.DLQ                — Dead-letter queue for failed event handlers
├── Bridge.PubSub             — External bridge pub/sub
├── Store.Repo                — SQLite persistent storage
├── EventStream               — SSE stream for Command Center UI
├── Telemetry.Metrics         — Subscribes to event bus for metrics
├── MiosaLLM.HealthChecker    — Provider circuit breaker
├── MiosaProviders.Registry   — goldrush-compiled :osa_provider_router
├── Tools.Registry            — goldrush-compiled :osa_tool_dispatcher
├── Tools.Cache               — Tool result cache
├── Machines                  — OS/machine templates
├── Commands                  — Slash command registry
├── OS.Registry               — OS template discovery
├── MCP.Registry              — MCP server name registry
└── MCP.Supervisor            — DynamicSupervisor for MCP server processes
```

`Infrastructure` uses `:rest_for_one` internally because several children have
strict ordering requirements. The event bus must start before the dead-letter
queue (which subscribes to the bus). The provider health checker must start
before the provider registry (which needs the health checker during init).

### Sessions (`one_for_one`)

```
Supervisors.Sessions  (one_for_one)
├── Channels.Supervisor      — DynamicSupervisor for channel adapters
│   ├── [CLI adapter]        — started on demand
│   ├── [Telegram adapter]   — started if configured
│   └── [Discord adapter]    — started if configured
├── EventStreamRegistry      — Registry for per-session SSE streams
└── SessionSupervisor        — DynamicSupervisor for agent Loop processes
    ├── [Loop for session A] — started when user connects
    ├── [Loop for session B]
    └── ...
```

`Sessions` uses `:one_for_one` because a crashed Telegram adapter should not
restart the CLI adapter or kill all active sessions. Each child is independent.

The `SessionSupervisor` is a `DynamicSupervisor`, which is a special supervisor
that manages a variable number of children. Sessions come and go — a user starts
a conversation, an agent loop process starts; the user closes the app, the
process ends. Static supervisors require a fixed list of children at startup.
DynamicSupervisor handles a pool that grows and shrinks at runtime.

### AgentServices (`one_for_one`)

```
Supervisors.AgentServices  (one_for_one)
├── Agent.Memory             — Long-term memory store
├── Agent.HeartbeatState     — Session heartbeat tracking
├── Agent.Tasks              — Task queue management
├── MiosaBudget.Budget       — Token/cost budget tracking
├── Agent.Orchestrator       — Multi-agent coordination
├── Agent.Progress           — Progress reporting
├── Agent.Hooks              — Pre/post tool execution hooks
├── Agent.Learning           — Pattern learning from interactions
├── MiosaKnowledge.Store     — Semantic knowledge store (Mnesia backend)
├── Agent.Memory.KnowledgeBridge — Bridges memory to knowledge store
├── Vault.Supervisor         — Encrypted credential storage
├── Agent.Scheduler          — Cron-style task scheduling
├── Agent.Compactor          — Context window compaction
├── Agent.Cortex             — Cortex synthesis (cross-session insights)
└── Webhooks.Dispatcher      — Outbound webhook delivery
```

These are independent services. A Scheduler crash should not restart the Memory
process, which might be mid-write. `:one_for_one` gives each service its own
crash boundary.

### Extensions (`one_for_one`)

```
Supervisors.Extensions  (one_for_one)
├── [MiosaBudget.Treasury]   — opt-in: OSA_TREASURY_ENABLED=true
├── Intelligence.Supervisor  — Signal Theory intelligence layer (always on)
├── Agent.Orchestrator.Mailbox       — Swarm coordination ETS mailbox
├── Agent.Orchestrator.SwarmMode     — Swarm GenServer
├── Agent.Orchestrator.SwarmMode.AgentPool  — DynamicSupervisor, max 50 agents
├── [Fleet.Supervisor]       — opt-in: OSA_FLEET_ENABLED=true
├── Sidecar.Manager          — Sidecar circuit breaker + registry
├── [Go.Tokenizer]           — opt-in: go sidecar for token counting
├── [Python.Supervisor]      — opt-in: Python sidecar
├── [Go.Git]                 — opt-in: Git operations sidecar
├── [Go.Sysmon]              — opt-in: System monitoring sidecar
├── [WhatsAppWeb]            — opt-in: WhatsApp Web sidecar
├── [Sandbox.Supervisor]     — opt-in: OSA_SANDBOX_ENABLED=true
├── [Integrations.Wallet]    — opt-in: OSA_WALLET_ENABLED=true
├── [System.Updater]         — opt-in: OSA_UPDATE_ENABLED=true
└── [Platform.AMQP]          — opt-in: if AMQP_URL is set
```

Extensions are independent opt-in subsystems. `:one_for_one` is correct here
because a fleet management crash should not restart the Python sidecar manager.

---

## Why Dynamic Supervisors for Sessions

Static supervisors require you to declare all children upfront in `init`. This
works when you know exactly what processes you will run at startup.

Sessions are different. You do not know how many users will connect, or when.
`DynamicSupervisor` allows OSA to:

1. Start a new agent loop process when a user connects: `DynamicSupervisor.start_child/2`
2. Let the process exit naturally when the session ends
3. Have the supervisor restart it if it crashes unexpectedly
4. Scale from 1 to thousands of concurrent sessions without configuration changes

---

## What Happens When Something Crashes

Walk through a concrete failure scenario:

1. A user's agent loop crashes mid-reasoning (e.g., a tool returns unexpected data).
2. The `SessionSupervisor` (a DynamicSupervisor under `Sessions`) detects the crash.
3. It restarts the loop process for that session. The session starts fresh.
4. The other 47 active sessions are completely unaffected.
5. The Infrastructure, AgentServices, and Extensions subsystems never notice.

Now a more serious failure:

1. The `Events.Bus` (goldrush event router) crashes.
2. The `Infrastructure` supervisor restarts Bus.
3. But Sessions, AgentServices, and Extensions were started after Infrastructure.
4. Because the root supervisor uses `:rest_for_one`, those subsystems restart too.
5. Active sessions are terminated and restart fresh.
6. The system is fully operational within seconds.

---

## Observing the Supervision Tree

You can inspect the live supervision tree in an IEx console connected to a
running OSA node:

```elixir
# Show all children of the top-level supervisor
Supervisor.which_children(OptimalSystemAgent.Supervisor)

# Show children of the Infrastructure supervisor
Supervisor.which_children(OptimalSystemAgent.Supervisors.Infrastructure)

# Show all active session processes
DynamicSupervisor.which_children(OptimalSystemAgent.SessionSupervisor)
```

---

## Next Steps

With supervision trees understood, read
[ets-and-persistent-term.md](./ets-and-persistent-term.md) to learn how OSA
stores and retrieves data at microsecond speed without touching a database.
