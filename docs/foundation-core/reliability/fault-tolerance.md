# Fault Tolerance

OSA relies on OTP supervision for fault isolation and automatic recovery. The design principle
is crash containment: a failed process should restart itself without destabilizing anything that
was not already affected.

---

## Top-Level Supervision Strategy: `:rest_for_one`

The root supervisor (`OptimalSystemAgent.Supervisor`) uses `:rest_for_one`.

```
OptimalSystemAgent.Supervisor  [strategy: :rest_for_one]
│
├── [opt] Platform.Repo              PostgreSQL — multi-tenant (conditional on DATABASE_URL)
├── Task.Supervisor                  name: OptimalSystemAgent.TaskSupervisor
├── Supervisors.Infrastructure       [strategy: :rest_for_one]
├── Supervisors.Sessions             [strategy: :one_for_one]
├── Supervisors.AgentServices        [strategy: :one_for_one]
├── Supervisors.Extensions           [strategy: :one_for_one]
├── Channels.Starter                 Deferred channel boot (handle_continue)
└── Bandit HTTP                      Port 9089 — started last
```

Under `:rest_for_one`, if child N crashes, OTP restarts N and also restarts every child
that was started after N. The ordering is intentional:

- `Infrastructure` crashing means the event bus, provider registry, and storage are
  gone — sessions, agent services, and extensions cannot function without them, so they
  restart too.
- `Sessions` crashing while `Infrastructure` is healthy means only active sessions and
  channel adapters restart; the event bus, memory, and provider registry are untouched.
- `AgentServices` crashing while `Infrastructure` and `Sessions` are healthy means only
  the memory GenServers, orchestrator, hooks, and scheduler restart; live sessions are
  disrupted but infrastructure survives.
- `Extensions` crashing affects only opt-in subsystems (fleet, sandbox, sidecars) and
  has no effect on anything above it.

---

## Subsystem Strategies

### `Supervisors.Infrastructure` — `:rest_for_one`

Children have strict initialization ordering. Later children depend on earlier ones:

```
Infrastructure supervisor children (in start order):
  1. SessionRegistry          — ETS-backed unique registry for session lookup
  2. Events.TaskSupervisor    — max_children: 100; must exist before Events.Bus
  3. Phoenix.PubSub           — name: OptimalSystemAgent.PubSub
  4. Events.Bus               — goldrush :osa_event_router; depends on TaskSupervisor
  5. Events.DLQ               — dead-letter queue; depends on Events.Bus
  6. Bridge.PubSub            — goldrush → Phoenix.PubSub fan-out; depends on both
  7. Store.Repo               — Ecto/SQLite3 persistent store
  8. EventStream              — SSE registry; depends on PubSub
  9. Telemetry.Metrics        — subscribes to Events.Bus; depends on Bus + TaskSupervisor
  10. MiosaLLM.HealthChecker  — circuit breaker GenServer; must start before Registry
  11. MiosaProviders.Registry — LLM routing; depends on HealthChecker
  12. Tools.Registry           — goldrush :osa_tool_dispatcher
  13. Tools.Cache              — ETS-backed tool result cache
  14. Machines                 — composable skill set manager
  15. Commands                 — slash command registry
  16. OS.Registry              — OS template discovery
  17. MCP.Registry             — unique Registry for MCP server lookup
  18. MCP.Supervisor           — DynamicSupervisor for per-server GenServers
```

The `:rest_for_one` strategy here is critical: if `Events.Bus` crashes (child 4), OTP
restarts children 4-18 in order, re-establishing the complete event routing graph.

### `Supervisors.Sessions` — `:one_for_one`

Children are independent: a crashed channel adapter (e.g., Telegram) must not tear down
the `SessionSupervisor` holding all active agent loops.

```
Sessions supervisor children:
  1. Channels.Supervisor    — DynamicSupervisor, strategy: :one_for_one
  2. EventStreamRegistry    — unique Registry for per-session SSE streams
  3. SessionSupervisor      — DynamicSupervisor, strategy: :one_for_one
```

`Agent.Loop` processes live under `SessionSupervisor`. Each session is a child of the
DynamicSupervisor, supervised with `:temporary` restart semantics — a crashed session
is not automatically restarted because there is no way to recover conversation state
deterministically from a crash mid-turn.

### `Supervisors.AgentServices` — `:one_for_one`

Services are independent GenServers. A crashed `Scheduler` should not restart `Memory`:

```
AgentServices supervisor children (all :one_for_one):
  Agent.Memory               HeartbeatState           Tasks
  MiosaBudget.Budget         Agent.Orchestrator       Agent.Progress
  Agent.Hooks                Agent.Learning           MiosaKnowledge.Store
  Agent.Memory.KnowledgeBridge                        Vault.Supervisor
  Agent.Scheduler            Agent.Compactor          Agent.Cortex
  Webhooks.Dispatcher
```

`Vault.Supervisor` is itself a `:one_for_one` supervisor with two children:
`Vault.FactStore` and `Vault.Observer`.

### `Supervisors.Extensions` — `:one_for_one`

All extensions are independent. Crash isolation prevents a broken sidecar from
affecting the intelligence subsystem or swarm coordinator:

```
Extensions supervisor children (conditional):
  Intelligence.Supervisor    — always started; CommProfiler, CommCoach,
                               ConversationTracker, ProactiveMonitor
  Agent.Orchestrator.Mailbox — ETS-backed swarm mailbox (always started)
  Agent.Orchestrator.SwarmMode — swarm coordinator GenServer (always started)
  SwarmMode.AgentPool        — DynamicSupervisor, max_children: 50

  [conditional on config flags]:
  MiosaBudget.Treasury       — OSA_TREASURY_ENABLED=true
  Fleet.Supervisor           — OSA_FLEET_ENABLED=true
  Sidecar.Manager            — always started when sidecars enabled
  Go.Tokenizer               — go_tokenizer_enabled: true
  Python.Supervisor          — python_sidecar_enabled: true
  Go.Git                     — go_git_enabled: true
  Go.Sysmon                  — go_sysmon_enabled: true
  WhatsAppWeb                — whatsapp_web_enabled: true
  Sandbox.Supervisor         — sandbox_enabled: true
  Integrations.Wallet.Mock   — wallet_enabled: true
  Integrations.Wallet        — wallet_enabled: true
  System.Updater             — update_enabled: true
  Platform.AMQP              — AMQP_URL present
```

`Fleet.Supervisor` is itself a `:one_for_one` supervisor with:
`Fleet.AgentRegistry`, `Fleet.SentinelPool` (DynamicSupervisor), `Fleet.Registry`.

---

## Max Restarts Configuration

The default OTP `max_restarts` (3 restarts in 5 seconds) applies to all supervisors
unless overridden. These are the OTP defaults; they have not been overridden in the
current codebase.

If a child exceeds the restart frequency, the supervisor itself terminates and propagates
the failure upward in the tree. With `:rest_for_one` at the root, this means the root
supervisor handles the cascade.

---

## How Failures Cascade (and Do Not)

The failure containment rules follow from the supervision strategies:

| Failure | Scope of Impact |
|---|---|
| An `Agent.Loop` GenServer crashes mid-turn | That session only. The DynamicSupervisor does not restart it (`:temporary`). User sees a disconnection. |
| `Agent.Scheduler` crashes | Scheduler restarts (`:one_for_one`). Memory, Hooks, and all other AgentServices are unaffected. |
| `Events.Bus` crashes | `Events.Bus` through `MCP.Supervisor` restart in order (`:rest_for_one` in Infrastructure). Active sessions lose event routing until they recover (~1–2 seconds). |
| `Supervisors.Infrastructure` crashes | Root `:rest_for_one` restarts Infrastructure, Sessions, AgentServices, Extensions, Starter, and HTTP in order. The system fully recovers but all sessions are terminated. |
| `Intelligence.CommProfiler` crashes | CommProfiler restarts (`:one_for_one` in Extensions). All other subsystems are unaffected. |
| Go tokenizer sidecar crashes | `Go.Tokenizer` restarts (`:one_for_one` in Extensions). Token counting falls back to Elixir estimation during downtime. |

---

## ETS Tables

Seven ETS tables are created before the supervision tree starts, in `Application.start/2`:

| Table | Type | Purpose |
|---|---|---|
| `:osa_cancel_flags` | `:public, :set` | Per-session loop cancellation flags |
| `:osa_files_read` | `:public, :set` | Read-before-write tracking per session |
| `:osa_survey_answers` | `:public, :set` | ask_user HTTP poll answers |
| `:osa_context_cache` | `:public, :set` | Ollama model context window size cache |
| `:osa_survey_responses` | `:public, :bag` | Survey responses (when platform DB off) |
| `:osa_session_provider_overrides` | `:public, :set` | Hot-swap provider/model per session |
| `:osa_pending_questions` | `:public, :set` | Pending ask_user question tracking |

These tables survive individual process crashes because they are not owned by any single
process — they were created by the application process before supervision started.

Two additional ETS tables are created by subsystems on startup:
- `:osa_event_handlers` — created by `Events.Bus.init/1`, holds registered event handlers
- `:osa_tool_handlers` — created by `Tools.Registry` via goldrush compile

---

## `persistent_term` Usage

Ollama tier assignments and manual tier overrides are stored in `persistent_term`:

- `:osa_ollama_tiers` — model-to-tier mapping (elite/specialist/utility)
- `:osa_tier_overrides` — manual overrides applied on top of auto-detection

These survive GenServer crashes. They are written at boot by `Agent.Tier.detect_ollama_tiers/0`
and whenever `Agent.Tier.set_tier_override/2` is called.

Soul and prompt content is loaded into `persistent_term` before the supervision tree starts
via `OptimalSystemAgent.Soul.load/0` and `OptimalSystemAgent.PromptLoader.load/0`.
