# Dependency Rules

**Audience:** Engineers adding modules, refactoring existing code, or trying to
understand why a given module lives where it does in the supervision tree.

Dependency rules are not stylistic preferences. They are invariants that preserve
the fault-isolation and restart-ordering guarantees that OTP supervision provides.
Violating them produces circular dependencies, incorrect restart behavior, and
runtime initialization failures.

---

## Layer Model

OSA has four layers. Dependencies flow strictly downward. No layer may depend on
a layer above it.

```
┌─────────────────────────────────────────────────────────────────────┐
│  Layer 4: Extensions                                                │
│  Sandbox, Fleet, Sidecars, AMQP, Wallet, Updater                   │
│  Depends on: Agent Layer, Infrastructure Layer                      │
│  Has NO dependents within OSA                                       │
└────────────────────────────────┬────────────────────────────────────┘
                                 │ depends on
┌────────────────────────────────▼────────────────────────────────────┐
│  Layer 3: Channels                                                  │
│  CLI, HTTP, Telegram, Discord, Slack, WhatsApp, Signal, Matrix,    │
│  Email, QQ, DingTalk, Feishu/Lark                                  │
│  Depends on: Agent Layer, Infrastructure Layer                      │
│  Extensions MUST NOT depend on Channels                             │
└────────────────────────────────┬────────────────────────────────────┘
                                 │ depends on
┌────────────────────────────────▼────────────────────────────────────┐
│  Layer 2: Agent Layer                                               │
│  Loop, Context, Strategies, Orchestrator, Memory, Vault, Hooks,    │
│  Compactor, Cortex, Scheduler, Learning, Proactive Mode            │
│  Depends on: Infrastructure Layer only                              │
│  Channels MAY depend on Agent Layer                                 │
└────────────────────────────────┬────────────────────────────────────┘
                                 │ depends on
┌────────────────────────────────▼────────────────────────────────────┐
│  Layer 1: Infrastructure Layer                                      │
│  SessionRegistry, Events.Bus, Events.DLQ, PubSub, Bridge.PubSub,  │
│  Store.Repo, Telemetry, HealthChecker, Providers.Registry,         │
│  Tools.Registry, Machines, Commands, OS.Registry, MCP.Supervisor   │
│  Depends on: NOTHING within OSA                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### The Hard Rules

**Infrastructure has no dependencies on Agent logic.** The event bus, provider
registry, tool registry, and storage layer must function without any Agent module
being loaded. This is what makes the `rest_for_one` supervision strategy at the
top level correct: Infrastructure can start and run independently.

**Agent Layer depends on Infrastructure only.** Agent modules may call into the
provider registry, tools registry, event bus, PubSub, and store. They must not
import or call Channels or Extensions modules.

**Channels depend on Agent Layer and Infrastructure.** A channel adapter calls
into the agent loop to process user input and reads session state. It must not
call into Extensions (e.g., directly invoking the sandbox subsystem from a
channel handler — that is the agent loop's job).

**Extensions depend on nothing.** Extension modules (Sandbox, Fleet, Sidecars)
depend on Infrastructure and Agent Layer services via registered names and the
event bus. They do not import specific Agent modules by name where avoidable —
they receive data through the event bus or via explicit API calls to well-defined
agent services.

---

## Supervision Strategy Rationale

The supervision strategy at each level is determined by the dependency structure
of its children, not by convenience.

### Top-Level Supervisor — `rest_for_one`

```elixir
# OptimalSystemAgent.Supervisor
Supervisor.init(children, strategy: :rest_for_one)
```

Children are ordered: Platform.Repo, then Infrastructure, then Sessions, then
AgentServices, then Extensions. `rest_for_one` means: if a child crashes, all
children *after it in the list* are also terminated and restarted. This enforces
the dependency ordering — if Infrastructure crashes, Sessions, AgentServices, and
Extensions cannot run in a healthy state, so they are all restarted together.

### Infrastructure Supervisor — `rest_for_one`

```elixir
# OptimalSystemAgent.Supervisors.Infrastructure
Supervisor.init(children, strategy: :rest_for_one)
```

Infrastructure children have strict ordering. The comments in the supervisor
module are explicit about why:

```
TaskSupervisor must start before Events.Bus
  (Bus spawns supervised async tasks via TaskSupervisor)

Events.Bus must start before Events.DLQ and Bridge.PubSub
  (DLQ subscribes to Bus; Bridge.PubSub fans out Bus events)

Bridge.PubSub must start before Telemetry.Metrics
  (Metrics subscribes to the bridge topic)

HealthChecker must start before Providers.Registry
  (Registry queries HealthChecker state during provider selection)
```

If any early child in this sequence crashes, later children cannot be in a valid
state. `rest_for_one` enforces this.

### Sessions Supervisor — `one_for_one`

```elixir
# OptimalSystemAgent.Supervisors.Sessions
Supervisor.init(children, strategy: :one_for_one)
```

Channel adapters are independent. A crash in the Telegram adapter must not
restart the Discord adapter or the SSE event stream registry. Sessions that are
in-flight continue normally while the crashed adapter restarts.

### AgentServices Supervisor — `one_for_one`

```elixir
# OptimalSystemAgent.Supervisors.AgentServices
Supervisor.init(children, strategy: :one_for_one)
```

Agent services are independent GenServers. A crash in the Scheduler must not
restart the Memory system or the Vault. These are peer services, not a dependency
chain.

### Extensions Supervisor — `one_for_one`

```elixir
# OptimalSystemAgent.Supervisors.Extensions
Supervisor.init(children, strategy: :one_for_one)
```

Extensions are isolated by definition. A crash in the Sandbox supervisor must not
affect the Fleet supervisor or the Sidecar manager.

---

## External Package Roles and Boundaries

These are the direct external dependencies declared in `mix.exs`. Each has a
defined role and is not used outside that role.

### goldrush

```
Role:    Compiled event routing — zero-overhead BEAM bytecode dispatch
Used in: Events.Bus, Tools.Registry, Providers.Registry
Rule:    ONLY used for high-frequency dispatch paths. Do not use goldrush
         for one-time lookups or low-frequency operations — use ETS or maps.
```

### req

```
Role:    HTTP client for all outbound LLM provider API calls and webhook delivery
Used in: All provider adapters in lib/optimal_system_agent/providers/ and
         lib/miosa/providers/
Rule:    Not used for inter-process communication within OSA. Do not use
         req to call localhost:9089 from within the Elixir process — use
         direct GenServer calls instead.
```

### bandit + plug

```
Role:    HTTP server for the REST API (port 9089) and webhook reception
Used in: OptimalSystemAgent.Channels.HTTP and associated router/plugs
Rule:    Not used as an application web framework. No Phoenix, no LiveView,
         no Ecto changesets in HTTP request handlers — raw Plug only.
```

### ecto_sqlite3

```
Role:    Durable local storage for conversations, memory, telemetry
Used in: OptimalSystemAgent.Store.Repo and associated schema modules
Rule:    SQLite is for persistence, not for in-process coordination. Hot
         state (active sessions, hook registrations, signal cache) lives
         in ETS, not SQLite.
```

### postgrex

```
Role:    Multi-tenant platform storage (conditional — prod + platform mode only)
Used in: OptimalSystemAgent.Platform modules (Platform.Repo)
Rule:    Only imported/used in platform/ namespace modules. Agent layer and
         Infrastructure layer modules must not reference Platform.Repo.
```

### phoenix_pubsub

```
Role:    Fanout pub/sub for internal event distribution across subscribers
Used in: Bridge.PubSub (event bus → pub/sub bridge), EventStream (SSE fanout)
Rule:    Phoenix.PubSub is for one-to-many broadcast, not request/response.
         For request/response patterns between processes, use GenServer calls.
         For one-way fire-and-forget, use Events.Bus.emit/3 instead of
         Phoenix.PubSub.broadcast directly — go through the bridge.
```

### jason

```
Role:    JSON encoding and decoding (LLM API payloads, MCP protocol, config)
Used in: All modules that parse or produce JSON
Rule:    Use Jason.decode!/1 only when the input is guaranteed valid
         (e.g. from a trusted LLM response that has already been validated).
         Use Jason.decode/1 (returning {:ok, _} | {:error, _}) for all
         untrusted input from channels, webhooks, and external APIs.
```

### yaml_elixir

```
Role:    YAML parsing for skill definitions (SKILL.md frontmatter) and config
Used in: Skills loading system, configuration parsers
Rule:    YAML is read-only at runtime. OSA does not write YAML. Do not use
         yaml_elixir for serialization.
```

### ex_json_schema

```
Role:    JSON Schema validation for tool call arguments
Used in: Tools.Registry (validates LLM-generated tool arguments before dispatch)
Rule:    Always validate tool call arguments against the tool's schema before
         executing. Never trust the LLM to produce well-formed arguments.
```

### telemetry + telemetry_metrics

```
Role:    Event-driven instrumentation
Used in: OptimalSystemAgent.Telemetry.Metrics, hook telemetry entries
Rule:    Telemetry events are fire-and-forget. Never block on telemetry.
         Never make routing decisions based on telemetry data — it is
         observability output, not control input.
```

---

## Module Naming Conventions and Layer Enforcement

Module namespace placement encodes layer membership:

| Namespace | Layer |
|---|---|
| `OptimalSystemAgent.Events.*` | Infrastructure |
| `OptimalSystemAgent.Store.*` | Infrastructure |
| `OptimalSystemAgent.Telemetry.*` | Infrastructure |
| `MiosaProviders.*` | Infrastructure |
| `MiosaLLM.*` | Infrastructure |
| `OptimalSystemAgent.Tools.*` | Infrastructure |
| `OptimalSystemAgent.Agent.*` | Agent Layer |
| `OptimalSystemAgent.Vault.*` | Agent Layer |
| `MiosaBudget.*` | Agent Layer |
| `MiosaKnowledge.*` | Agent Layer |
| `OptimalSystemAgent.Channels.*` | Channels |
| `OptimalSystemAgent.Swarm.*` | Channels (orchestration output) |
| `OptimalSystemAgent.Sandbox.*` | Extensions |
| `OptimalSystemAgent.Fleet.*` | Extensions |
| `OptimalSystemAgent.Sidecar.*` | Extensions |
| `OptimalSystemAgent.Platform.*` | Cross-cutting (platform mode only) |

**Enforcement:** There is no compile-time dependency checker today (tracked in
the ADRs as future work). Enforcement is currently by code review. When adding a
new module, verify its namespace matches its actual layer and that its `alias`
and `use` statements only reference modules from the same or lower layers.

---

## Adding a New Dependency

Before adding a new external package to `mix.exs`:

1. Verify the package is actively maintained and has a stable version.
2. Confirm it does not duplicate a capability already present (e.g. do not add
   a second HTTP client alongside `req`).
3. Determine which layer it belongs to and confirm it has no transitive
   dependencies that violate layer boundaries.
4. If the package is only needed in production (e.g. `bcrypt_elixir`), mark it
   `only: :prod, optional: true`.
5. If the package is only needed conditionally (e.g. `amqp` for RabbitMQ), mark
   it `optional: true` and ensure the supervisor that uses it handles `:ignore`
   when the package is not loaded.
6. Document its role and boundary constraints in this file.

---

## Next

- [Glossary](glossary.md) — Definitions for all terms used in this document
- [Architecture Principles](architecture-principles.md) — The reasoning behind
  the supervision strategies described here
