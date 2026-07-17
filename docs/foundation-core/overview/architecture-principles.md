# Architecture Principles

**Audience:** Engineers contributing to or extending OSA, operators deploying it.
These principles explain *why* the system is built the way it is — the reasoning
behind decisions that might otherwise look arbitrary.

---

## 1. OTP Fault Tolerance — Let It Crash

The single most important design principle in OSA is inherited from Erlang/OTP:
**do not write defensive code to prevent crashes; write supervision hierarchies
to recover from them automatically.**

This means:

- No `try/rescue` blocks around internal logic to hide errors
- No `nil` checks on values that should always be present
- No silent failure paths that swallow errors and return degraded results

Instead: if a GenServer crashes, its supervisor restarts it. If the crash repeats
beyond the restart intensity limit, it propagates up the tree. Each supervision
level is responsible for a meaningful scope of the system.

The practical consequence is that OSA uses a four-level supervision tree:

```
OptimalSystemAgent.Supervisor     (rest_for_one)
├── Supervisors.Infrastructure    (rest_for_one)  — foundational layer
├── Supervisors.Sessions          (one_for_one)   — user-facing sessions
├── Supervisors.AgentServices     (one_for_one)   — intelligence services
└── Supervisors.Extensions        (one_for_one)   — optional subsystems
```

`rest_for_one` at the top level means: if Infrastructure crashes, everything
above it (Sessions, AgentServices, Extensions) also restarts, because they depend
on Infrastructure being healthy. `one_for_one` within Sessions means: if one
channel adapter crashes, the others continue running.

**Rule:** Supervision strategy encodes dependency semantics. `rest_for_one` for
ordered dependencies. `one_for_one` for independent peers.

---

## 2. goldrush — Zero-Overhead Event Routing

The internal event bus uses [goldrush](https://github.com/robertohluna/goldrush),
a fork of extend/goldrush that compiles event-matching predicates into real Erlang
bytecode modules at startup.

```erlang
%% At startup, glc:compile/2 produces a real BEAM module:
%% :osa_event_router — compiled from the union of all registered predicates.
%% At runtime:
glc:handle(:osa_event_router, Event)
%% This is a function call into a compiled module — no hash lookups,
%% no ETS reads, no pattern dispatch. Pure BEAM instruction execution.
```

The tool dispatcher (`:osa_tool_dispatcher`) and provider router
(`:osa_provider_router`) use the same mechanism. Tool calls and provider
selections are compiled routing decisions, not runtime lookups.

**Rule:** High-frequency paths (event dispatch, tool calls, provider routing)
must use compiled goldrush modules, not dynamic dispatch over ETS or maps.

---

## 3. ETS for Reads, GenServer for Writes

OSA uses ETS (Erlang Term Storage) as a shared in-memory data layer for all
state that is read frequently and written infrequently:

| ETS Table | Contents | Access Pattern |
|---|---|---|
| `:osa_hooks` | Registered hook entries | Many readers, rare writes |
| `:osa_hooks_metrics` | Atomic execution counters | Many concurrent writers |
| `:osa_signal_cache` | Classification results (10-min TTL) | Many readers, rare writes |
| `:osa_tool_cache` | Tool schema cache | Many readers, rare writes |

The corresponding GenServer owns each ETS table and is the sole writer:

```elixir
# Registration goes through GenServer (serialized, no race conditions)
def register_hook(name, event, handler, priority) do
  GenServer.call(__MODULE__, {:register, name, event, handler, priority})
end

# Execution reads from ETS in the caller's process (no GenServer bottleneck)
def run_hooks(event, payload) do
  :ets.lookup(:osa_hooks, event)
  |> Enum.sort_by(& &1.priority)
  |> Enum.reduce_while({:ok, payload}, &execute_hook/2)
end
```

This pattern eliminates the GenServer bottleneck on read paths while keeping
writes safe and ordered.

**Rule:** GenServers serialize writes. ETS serves reads. Never put a read-heavy
operation on a GenServer call path.

---

## 4. Two-Tier Context Assembly

Every agent turn assembles a system prompt from two tiers:

```
Tier 1 — Static Base (cached)
  - SYSTEM.md + tool definitions + rules + user profile
  - Computed once at session start, stored in persistent_term
  - For Anthropic: marked cache_control: ephemeral (~90% prompt cache hit rate)
  - Never recomputed within a session

Tier 2 — Dynamic Context (per-request, token-budgeted)
  - Runtime state, memory recalls, active tasks, workflow phase
  - Budget: max_tokens - static_tokens - conversation_tokens - response_reserve
  - Each block is budget-fitted independently
```

The budget calculation:

```elixir
dynamic_budget = max(
  provider_context_window
  - @response_reserve       # 8,192 tokens — always reserved for output
  - conversation_tokens     # actual conversation history
  - static_tokens,          # cached base (measured once)
  1_000                     # minimum floor
)
```

This design has two consequences. First, the static base cost (typically 2,000 –
8,000 tokens depending on Soul configuration) is paid once per session, not per
turn. Second, the dynamic budget is always accurate — it accounts for actual
conversation length, not an estimate.

**Rule:** Context assembly must be deterministic and bounded. No dynamic section
can exceed its allocated budget. The response reserve is inviolable.

---

## 5. Defense in Depth

Security is layered across four independent enforcement points:

```
Hook pipeline   — security_check (priority 10) blocks dangerous tool calls
                  before they reach the tool registry
Budget guard    — spend_guard (priority 8) blocks tool calls when the session
                  token budget is exhausted
Sandbox         — code execution runs in Docker (read-only root, CAP_DROP ALL),
                  Wasm (fuel limits), or Sprites.dev (Firecracker microVMs)
Shell policy    — allowlist/blocklist enforcement in OptimalSystemAgent.Security
                  independent of the hook pipeline
```

No single enforcement point is the last line of defense. If a hook is
misconfigured, the sandbox still isolates execution. If a custom hook removes the
security check, the budget guard still prevents runaway spending.

**Rule:** Never rely on a single enforcement point for safety properties.
Layer controls so that no single misconfiguration creates a vulnerability.

---

## 6. Graceful Degradation for Optional Modules

The Extensions supervisor (`Supervisors.Extensions`) manages all opt-in
subsystems. These are designed to start conditionally and fail silently if their
dependencies are unavailable:

- `Sandbox.Supervisor` — skipped if Docker is not running
- `Fleet.Supervisor` — skipped if multi-instance config is absent
- `Platform.AMQP` — skipped if RabbitMQ connection string is not set
- `Sidecar.Manager` children — each Go/Python sidecar starts only if its binary
  is present in `priv/`

The pattern is consistent: check the dependency at supervisor init time, return
`:ignore` from `start_link` if it is absent, log a notice but do not crash.

```elixir
def start_link(opts) do
  if docker_available?() do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  else
    Logger.notice("[Sandbox] Docker not available — sandbox disabled")
    :ignore
  end
end
```

**Rule:** Optional features must not crash the system when their external
dependencies are absent. Return `:ignore`, not an error.

---

## 7. Temporal Decay for Memory Relevance

The Vault observation system uses exponential decay scoring to model the
decreasing relevance of information over time:

```
score(t) = base_score * e^(-lambda * elapsed_days)
```

Where `lambda` controls the decay rate. A high-confidence observation from last
week scores higher than a low-confidence observation from yesterday, but both
score lower than a recent observation at the same confidence.

This is applied during prompt injection: when the Vault selects which facts and
observations to include in the dynamic context, it ranks candidates by their
current decayed score rather than creation time. The system actively forgets
stale information.

The same decay principle applies to episodic memory retrieval: recent episodes
receive a recency bonus during keyword-based recall, so the agent naturally
surfaces recent context before older context at the same relevance score.

**Rule:** Time is information. Relevance degrades. Systems that treat a fact from
two years ago as equally relevant as a fact from this morning are discarding
temporal information. OSA does not.

---

## 8. PACT — The Orchestration Quality Gate

Multi-agent orchestration follows the PACT framework as a structured feedback
loop across four phases:

```
Planning      — analyze complexity, decompose into dependency-aware tasks,
                assign tiers, validate the plan against quality criteria
Action        — execute sub-agents in dependency-ordered waves; each wave
                is parallel, waves are sequential
Coordination  — track real-time progress via Events.Bus; synthesis waits
                for all agents in a wave before proceeding
Testing       — quality gate: evaluate outputs, retry failed agents within
                budget, escalate to elite tier if specialist output fails QA
```

PACT is not a library — it is a pattern enforced by the Orchestrator's state
machine. The orchestrator will not emit a synthesis response until all four
phases have completed or a budget limit has been reached.

**Rule:** Orchestrated outputs must pass a quality gate. A response that was
generated but not validated is not a complete orchestration result.

---

## 9. Proactive, Not Reactive by Default

`Agent.Scheduler` and `Agent.Scheduler.HeartbeatExecutor` treat OSA as an actor,
not just a responder. The scheduler fires cron-style triggers that cause the agent
to take actions — not because a user asked, but because a scheduled condition
fired. Inside the agent loop, `Agent.Loop.ProactiveCompaction` acts ahead of need
too: it compacts context *before* the window overflows rather than only reacting
to a 413.

This is architecturally significant: OSA is designed as a *viable system* (see
[Purpose](purpose.md)) with System 4 (intelligence) and System 5 (policy)
functions. It monitors its environment and acts. This shapes how the supervision
tree is structured and why the Scheduler is in AgentServices rather than
Extensions.

> **Planned, not yet built:** a single autonomous-outreach coordinator
> (historically referred to as `ProactiveMode`) that would greet users on
> session start, react to alerts with autonomous LLM calls, and maintain an
> activity log **does not exist in `lib/`**. Today "proactive" behavior is the
> scheduler/heartbeat pair above, `Agent.Loop.ProactiveCompaction`, and a
> per-session `POST /sessions/:id/proactive` toggle (`SessionManager.set_proactive/1`).
> See [../../features/proactive-mode.md](../../features/proactive-mode.md).

**Rule:** Proactive behavior is a first-class capability, not a plugin. The
scheduler and heartbeat executor are always started, not opt-in.

---

## Next

- [System Boundaries](system-boundaries.md) — The concrete scope of what OSA
  owns versus what it delegates
- [Dependency Rules](dependency-rules.md) — How layers are allowed to depend
  on each other
