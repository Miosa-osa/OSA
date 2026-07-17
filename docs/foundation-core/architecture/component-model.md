# Component Model

Each component in OSA runs as a named OTP process. This document catalogues every component by
subsystem, describing its OTP process type, primary responsibility, and the public interfaces other
components use to interact with it.

Process types used:

- **GenServer** — stateful server process, single-threaded message handling
- **Supervisor** — monitors children, restarts on crash
- **DynamicSupervisor** — starts/stops children at runtime
- **Registry** — ETS-backed process name registry
- **Task.Supervisor** — pool for fire-and-forget async tasks

---

## Infrastructure Subsystem

These components form the foundational layer. Everything else depends on them.

### SessionRegistry

| | |
|---|---|
| Type | Registry (`:unique`) |
| Module | `OptimalSystemAgent.SessionRegistry` |
| Responsibility | Maps session IDs to `Agent.Loop` PIDs. Used by all code that needs to find or message a session process. |
| Key interfaces | `Registry.lookup/2`, `Registry.register/3` (called by `Agent.Loop` on start) |

### Events.TaskSupervisor

| | |
|---|---|
| Type | Task.Supervisor |
| Module | `OptimalSystemAgent.Events.TaskSupervisor` |
| Responsibility | Supervises short-lived tasks spawned by the event bus for handler dispatch. Caps at 100 concurrent children. Must start before `Events.Bus`. |
| Key interfaces | `Task.Supervisor.start_child/2` (called by `Events.Bus`) |

### Phoenix.PubSub

| | |
|---|---|
| Type | Supervisor (internal, Phoenix library) |
| Module | `Phoenix.PubSub` (name: `OptimalSystemAgent.PubSub`) |
| Responsibility | In-process pub/sub for channel-level message broadcast. Used by `Channels.HTTP` for SSE fan-out. |
| Key interfaces | `Phoenix.PubSub.broadcast/3`, `Phoenix.PubSub.subscribe/2` |

### Events.Bus

| | |
|---|---|
| Type | GenServer |
| Module | `OptimalSystemAgent.Events.Bus` |
| Responsibility | Central event router. Compiles a goldrush BEAM module (`:osa_event_router`) at init for zero-overhead dispatch. Routes 14 typed events: `user_message`, `llm_request`, `llm_response`, `tool_call`, `tool_result`, `agent_response`, `system_event`, `channel_connected`, `channel_disconnected`, `channel_error`, `ask_user_question`, `survey_answered`, `algedonic_alert`. Failed handler executions are forwarded to `Events.DLQ`. |
| Key interfaces | `Bus.emit/3`, `Bus.emit_algedonic/3`, `Bus.register_handler/2`, `Bus.unregister_handler/2` |

### Events.DLQ

| | |
|---|---|
| Type | GenServer |
| Module | `OptimalSystemAgent.Events.DLQ` |
| Responsibility | Dead-letter queue for failed event handler dispatches. ETS-backed. Retries with exponential backoff (base 1s, max 30s) up to 3 times. On exhaustion emits an algedonic alert and drops the event. Periodic retry tick every 60 seconds. |
| Key interfaces | `DLQ.enqueue/4`, `DLQ.depth/0`, `DLQ.drain/0` |

### Bridge.PubSub

| | |
|---|---|
| Type | GenServer |
| Module | `OptimalSystemAgent.Bridge.PubSub` |
| Responsibility | Bridges events from `Events.Bus` into `Phoenix.PubSub` topics. Enables HTTP SSE clients and the Command Center to subscribe to live agent events without coupling to the bus internals. |
| Key interfaces | `Bridge.PubSub.broadcast/2` |

### Store.Repo

| | |
|---|---|
| Type | GenServer (Ecto adapter) |
| Module | `OptimalSystemAgent.Store.Repo` |
| Responsibility | Ecto repository backed by SQLite3 (Exqlite adapter). Persists messages, memories, tasks, and agent state across restarts. |
| Key interfaces | `Repo.get/2`, `Repo.insert/1`, `Repo.query/2`, standard Ecto `Repo` API |

### EventStream

| | |
|---|---|
| Type | GenServer |
| Module | `OptimalSystemAgent.EventStream` |
| Responsibility | Per-session circular event buffer (max 1000 events) for Server-Sent Events delivery to the Command Center. Appended to by `Events.Bus` for all events carrying a `session_id`. |
| Key interfaces | `EventStream.append/2`, `EventStream.recent/2` |

### Telemetry.Metrics

| | |
|---|---|
| Type | GenServer |
| Module | `OptimalSystemAgent.Telemetry.Metrics` |
| Responsibility | Subscribes to `Events.Bus` for `tool_telemetry` system events. Accumulates tool timing metrics and exposes aggregated stats. |
| Key interfaces | `Telemetry.Metrics.get/0` |

### MiosaLLM.HealthChecker

| | |
|---|---|
| Type | GenServer |
| Module | `MiosaLLM.HealthChecker` |
| Responsibility | Monitors LLM provider health with circuit-breaker logic. Tracks failure rates per provider. `MiosaProviders.Registry` queries this before routing an LLM call. |
| Key interfaces | `HealthChecker.healthy?/1`, `HealthChecker.record_failure/2`, `HealthChecker.record_success/1` |

### MiosaProviders.Registry

| | |
|---|---|
| Type | GenServer |
| Module | `MiosaProviders.Registry` |
| Responsibility | Routes LLM calls to the configured provider (Anthropic, Ollama, OpenAI, etc.). Compiles a goldrush module (`:osa_provider_router`) for dispatch. Exposes `context_window/1` for token budget calculations. |
| Key interfaces | `Registry.call/3`, `Registry.context_window/1`, `Registry.list_providers/0` |

### Tools.Registry

| | |
|---|---|
| Type | GenServer |
| Module | `OptimalSystemAgent.Tools.Registry` |
| Responsibility | Manages 40+ built-in tool modules, SKILL.md skill files (from `priv/skills/` and `~/.osa/skills/`), and MCP-discovered tools. Compiles goldrush dispatcher (`:osa_tool_dispatcher`). Stores tool maps in `:persistent_term` for lock-free concurrent reads. Supports hot registration of new tools without restart. |
| Key interfaces | `Registry.execute/2`, `Registry.execute_direct/2`, `Registry.list_tools/0`, `Registry.list_tools_direct/0`, `Registry.register/1`, `Registry.register_mcp_tools/0`, `Registry.active_skills_context/1`, `Registry.filter_applicable_tools/1` |

### Tools.Cache

| | |
|---|---|
| Type | GenServer |
| Module | `OptimalSystemAgent.Tools.Cache` |
| Responsibility | Memoizes tool results with configurable TTL. Keyed by `{tool_name, arguments_hash}`. Used by tools that call external APIs to avoid redundant requests within a session. |
| Key interfaces | `Tools.Cache.get/2`, `Tools.Cache.put/3` |

### Machines

| | |
|---|---|
| Type | GenServer |
| Module | `OptimalSystemAgent.Machines` |
| Responsibility | Discovers and manages OS template definitions. Templates define environment shapes (e.g., a pre-configured dev container) the agent can instantiate or connect to. |
| Key interfaces | `Machines.list/0`, `Machines.get/1` |

### Commands

| | |
|---|---|
| Type | GenServer |
| Module | `OptimalSystemAgent.Commands` |
| Responsibility | Slash command registry for built-in commands (`/help`, `/budget`, `/status`, etc.), user-defined markdown commands from `~/.osa/commands/`, and agent-created commands. |
| Key interfaces | `Commands.execute/2`, `Commands.list/0`, `Commands.register/2` |

### OS.Registry

| | |
|---|---|
| Type | GenServer |
| Module | `OptimalSystemAgent.OS.Registry` |
| Responsibility | Tracks OS template connections. Maps template names to active connection state. |
| Key interfaces | `OS.Registry.register/2`, `OS.Registry.lookup/1` |

### MCP.Registry

| | |
|---|---|
| Type | Registry (`:unique`) |
| Module | `OptimalSystemAgent.MCP.Registry` |
| Responsibility | Maps MCP server names to their `MCP.Server` GenServer PIDs. Used by `MCP.Client` for server lookup before JSON-RPC calls. |
| Key interfaces | `Registry.lookup/2` (standard `Registry` API) |

### MCP.Supervisor

| | |
|---|---|
| Type | DynamicSupervisor |
| Module | `OptimalSystemAgent.MCP.Supervisor` |
| Responsibility | Owns one `MCP.Server` GenServer per configured MCP server entry in `~/.osa/mcp.json`. Servers are started asynchronously after boot via `MCP.Client.start_servers/0`. |
| Key interfaces | `DynamicSupervisor.start_child/2` (called by `MCP.Client`) |

---

## Sessions Subsystem

### Channels.Supervisor

| | |
|---|---|
| Type | DynamicSupervisor |
| Module | `OptimalSystemAgent.Channels.Supervisor` |
| Responsibility | Owns one GenServer per active channel adapter. Adapters are started by `Channels.Starter` during `handle_continue` after the supervisor tree is up. Supports up to 12 concurrent adapter types. |
| Key interfaces | `DynamicSupervisor.start_child/2` |

### Channel Adapters (12 adapters)

Each adapter implements `OptimalSystemAgent.Channels.Behaviour`:

| Adapter | Module | Protocol |
|---|---|---|
| CLI | `Channels.CLI` | stdio/TTY |
| HTTP | `Channels.HTTP` | REST + SSE (Bandit/Plug) |
| Telegram | `Channels.Telegram` | Telegram Bot API |
| Discord | `Channels.Discord` | Discord Gateway |
| Slack | `Channels.Slack` | Slack Events API |
| Signal | `Channels.Signal` | Signal Messenger |
| WhatsApp | `Channels.WhatsApp` | WhatsApp Business API |
| Email | `Channels.Email` | SMTP/IMAP |
| Matrix | `Channels.Matrix` | Matrix Client-Server API |
| DingTalk | `Channels.DingTalk` | DingTalk Webhook |
| Feishu | `Channels.Feishu` | Feishu/Lark Bot |
| QQ | `Channels.QQ` | QQ Bot API |

Required callbacks for all adapters:

```elixir
@callback channel_name() :: atom()
@callback start_link(opts :: keyword()) :: GenServer.on_start()
@callback send_message(chat_id :: String.t(), message :: String.t(), opts :: keyword()) ::
            :ok | {:error, term()}
@callback connected?() :: boolean()
```

### EventStreamRegistry

| | |
|---|---|
| Type | Registry (`:unique`) |
| Module | `OptimalSystemAgent.EventStreamRegistry` |
| Responsibility | Maps session IDs to per-session event stream GenServer PIDs. Used by SSE handlers to subscribe a client to the correct session's event buffer. |
| Key interfaces | `Registry.lookup/2`, `Registry.register/3` |

### SessionSupervisor

| | |
|---|---|
| Type | DynamicSupervisor |
| Module | `OptimalSystemAgent.SessionSupervisor` |
| Responsibility | Owns one `Agent.Loop` GenServer per active agent session. Sessions are created on first message and terminated explicitly or via timeout. |
| Key interfaces | `DynamicSupervisor.start_child/2`, `DynamicSupervisor.terminate_child/2` |

---

## AgentServices Subsystem

### Agent.Memory

| | |
|---|---|
| Type | GenServer |
| Module | `OptimalSystemAgent.Agent.Memory` |
| Responsibility | Long-term memory store. Persists facts, decisions, and context across sessions. Provides `recall/0` for full memory dump and relevance-filtered recall via keyword overlap. The `KnowledgeBridge` syncs important memories into `MiosaKnowledge.Store`. |
| Key interfaces | `Memory.remember/2`, `Memory.recall/0`, `Memory.forget/1` |

### Agent.HeartbeatState

| | |
|---|---|
| Type | GenServer |
| Module | `OptimalSystemAgent.Agent.HeartbeatState` |
| Responsibility | Tracks per-session liveness. Channel adapters ping this periodically; idle sessions are marked for reaping by the Scheduler. |
| Key interfaces | `HeartbeatState.ping/1`, `HeartbeatState.last_seen/1` |

### Agent.Tasks

| | |
|---|---|
| Type | GenServer |
| Module | `OptimalSystemAgent.Agent.Tasks` |
| Responsibility | Task queue per session. Tracks tasks with statuses `:pending`, `:in_progress`, `:completed`, `:failed`. The `Context` builder reads tasks via `Tasks.get_tasks/1` and injects them into the system prompt. Exposes workflow context blocks for multi-step plans. |
| Key interfaces | `Tasks.add/2`, `Tasks.get_tasks/1`, `Tasks.update_status/3`, `Tasks.workflow_context_block/1` |

### MiosaBudget.Budget

| | |
|---|---|
| Type | GenServer |
| Module | `MiosaBudget.Budget` |
| Responsibility | Tracks API spend (tokens in/out, cost in USD) per session and globally. The `spend_guard` hook (priority 8) calls `Budget.check_budget/0` before every tool execution. `cost_tracker` hook (priority 25) records actual spend after tool use. |
| Key interfaces | `Budget.check_budget/0`, `Budget.record_cost/5`, `Budget.status/0` |

### Agent.Orchestrator

| | |
|---|---|
| Type | GenServer |
| Module | `OptimalSystemAgent.Agent.Orchestrator` |
| Responsibility | Coordinates multi-agent parallel task execution. Spawns sub-agent sessions via the `orchestrate` tool. Tracks sub-agent results, aggregates outputs, and returns synthesized responses to the calling session. |
| Key interfaces | `Orchestrator.spawn_agents/2`, `Orchestrator.await_results/1` |

### Agent.Progress

| | |
|---|---|
| Type | GenServer |
| Module | `OptimalSystemAgent.Agent.Progress` |
| Responsibility | Reports progress for long-running operations to channels and the Command Center. Integrates with `Bridge.PubSub` for live progress streaming. |
| Key interfaces | `Progress.update/3`, `Progress.complete/2` |

### Agent.Hooks

| | |
|---|---|
| Type | GenServer |
| Module | `OptimalSystemAgent.Agent.Hooks` |
| Responsibility | Priority-ordered middleware pipeline for agent lifecycle events. Registration goes through the GenServer (serialized writes). Hook definitions stored in ETS (`:osa_hooks`, bag, read_concurrency). Hook execution reads from ETS in the caller's process — no GenServer bottleneck. Metrics stored in ETS (`:osa_hooks_metrics`, write_concurrency). |
| Key interfaces | `Hooks.register/4`, `Hooks.run/2`, `Hooks.run_async/2`, `Hooks.list_hooks/0`, `Hooks.metrics/0` |

Built-in hooks:

| Hook | Event | Priority | Action |
|---|---|---|---|
| `spend_guard` | `pre_tool_use` | 8 | Block when budget exceeded |
| `security_check` | `pre_tool_use` | 10 | Block dangerous shell commands |
| `read_before_write` | `pre_tool_use` | 12 | Nudge when editing unread files |
| `mcp_cache` | `pre_tool_use` | 15 | Inject cached MCP schema |
| `track_files_read` | `post_tool_use` | 5 | Record file paths after reads |
| `mcp_cache_post` | `post_tool_use` | 15 | Populate MCP schema cache |
| `cost_tracker` | `post_tool_use` | 25 | Record actual API spend |
| `vault_auto_checkpoint` | `post_tool_use` | 80 | Save vault every 10 tool calls |
| `telemetry` | `post_tool_use` | 90 | Emit tool timing telemetry |
| `session_cleanup` | `session_end` | 90 | Remove ETS entries for session |

### Agent.Learning

| | |
|---|---|
| Type | GenServer |
| Module | `OptimalSystemAgent.Agent.Learning` |
| Responsibility | Accumulates patterns and solutions from agent interactions. `Context.build` injects relevant patterns into the system prompt via `Taxonomy` and `Injector`. Patterns persist across sessions in the knowledge backend. |
| Key interfaces | `Learning.patterns/0`, `Learning.solutions/0`, `Learning.record_pattern/2`, `Learning.record_solution/2` |

### MiosaKnowledge.Store

| | |
|---|---|
| Type | GenServer |
| Module | `MiosaKnowledge.Store` |
| Responsibility | Structured knowledge store with Mnesia backend (ETS in test). Stores typed knowledge entries (facts, patterns, procedures). Used by the `knowledge` and `semantic_search` tools. |
| Key interfaces | `Store.put/2`, `Store.get/2`, `Store.search/2` |

### Agent.Memory.KnowledgeBridge

| | |
|---|---|
| Type | GenServer |
| Module | `OptimalSystemAgent.Agent.Memory.KnowledgeBridge` |
| Responsibility | Bridges long-term memory entries into the structured knowledge store. Classifies memory content via `Memory.Taxonomy` and upserts into `MiosaKnowledge.Store`. |
| Key interfaces | Called internally on memory writes |

### Vault.Supervisor

| | |
|---|---|
| Type | Supervisor |
| Module | `OptimalSystemAgent.Vault.Supervisor` |
| Responsibility | Owns the Vault GenServer and its persistence workers. The Vault is a persistent, encrypted context store where the agent can `remember`, `wake`, `sleep`, `checkpoint`, and `inject` named context bundles. |
| Key interfaces | `Vault.remember/2`, `Vault.context/1`, `Vault.checkpoint/1`, `Vault.wake/1`, `Vault.sleep/1` |

### Agent.Scheduler

| | |
|---|---|
| Type | GenServer |
| Module | `OptimalSystemAgent.Agent.Scheduler` |
| Responsibility | Runs scheduled tasks (cron-style or interval-based). Supports one-shot and recurring schedules. Dispatches due tasks to the appropriate session or creates a new session. |
| Key interfaces | `Scheduler.schedule/3`, `Scheduler.cancel/1`, `Scheduler.list/0` |

### Agent.Compactor

| | |
|---|---|
| Type | GenServer |
| Module | `OptimalSystemAgent.Agent.Compactor` |
| Responsibility | Context window compaction. When a session's conversation history exceeds the token budget, the Compactor summarizes older exchanges and replaces them with a compressed summary. The `pre_compact` hook fires before compaction. |
| Key interfaces | `Compactor.compact/2`, `Compactor.needs_compact?/2` |

### Agent.Cortex

| | |
|---|---|
| Type | GenServer |
| Module | `OptimalSystemAgent.Agent.Cortex` |
| Responsibility | Multi-provider synthesis. Fans a prompt out to multiple LLM providers in parallel and synthesizes the responses into a single answer. Used for high-stakes queries where cross-provider validation is desired. |
| Key interfaces | `Cortex.synthesize/2` |

### Proactive behavior (what ships today)

> There is **no** `Agent.ProactiveMode` GenServer in the codebase. A single
> autonomous-outreach coordinator was never built. The proactive capabilities
> that actually ship are two unrelated, narrower mechanisms:

| | |
|---|---|
| Context compaction | `OptimalSystemAgent.Agent.Loop.ProactiveCompaction` — runs inside the agent loop (not a supervised process). It watches context utilization each iteration and rewrites message history *before* the window overflows, once the token count crosses a configurable fraction of the model window (default `0.75`). Config: `proactive_compaction_enabled`, `proactive_compaction_threshold`, `proactive_compaction_keep_turns`. |
| Per-session toggle | `POST /sessions/:id/proactive` → `SessionManager.set_proactive/1` flags a single session. Scope is one session; there is no global daemon, cron/heartbeat trigger engine, or activity log behind it. |

Scheduled/heartbeat work is handled separately by `Agent.Scheduler` and
`Agent.Scheduler.HeartbeatExecutor` (both real AgentServices children).

### Webhooks.Dispatcher

| | |
|---|---|
| Type | GenServer |
| Module | `OptimalSystemAgent.Webhooks.Dispatcher` |
| Responsibility | Delivers outbound webhook payloads to configured URLs. Supports retry logic and signature verification. Used by the `agent_response` event to notify external systems. |
| Key interfaces | `Webhooks.Dispatcher.dispatch/2`, `Webhooks.Dispatcher.register_endpoint/2` |

---

## Extensions Subsystem

### MiosaBudget.Treasury

| | |
|---|---|
| Type | GenServer |
| Module | `MiosaBudget.Treasury` |
| Responsibility | Organization-level budget management. Aggregates spend across sessions and enforces team/org-level limits. Opt-in via `OSA_TREASURY_ENABLED=true`. |
| Condition | `OSA_TREASURY_ENABLED=true` |

### Intelligence.Supervisor

| | |
|---|---|
| Type | Supervisor |
| Module | `OptimalSystemAgent.Intelligence.Supervisor` |
| Responsibility | Umbrella for Signal Theory intelligence processes. Children start dormant and activate when wired to session data. `ConversationTracker` tracks conversation depth per session; `Context.runtime_block` uses it. |
| Children | `ConversationTracker`, `ContactDetector`, `ProactiveMonitor` |

### Orchestrator.Mailbox

| | |
|---|---|
| Type | GenServer |
| Module | `OptimalSystemAgent.Agent.Orchestrator.Mailbox` |
| Responsibility | ETS-backed message mailbox for swarm coordination. Sub-agents write results here; the orchestrating session reads and aggregates. Must start before `SwarmMode`. |
| Key interfaces | `Mailbox.put/3`, `Mailbox.take/2`, `Mailbox.list/1` |

### Orchestrator.SwarmMode

| | |
|---|---|
| Type | GenServer |
| Module | `OptimalSystemAgent.Agent.Orchestrator.SwarmMode` |
| Responsibility | Manages active swarm sessions. Tracks which sessions are operating as swarm coordinators and which are workers. Routes swarm-level messages. |
| Key interfaces | `SwarmMode.enter/2`, `SwarmMode.exit/1`, `SwarmMode.status/0` |

### SwarmMode.AgentPool

| | |
|---|---|
| Type | DynamicSupervisor |
| Module | `OptimalSystemAgent.Agent.Orchestrator.SwarmMode.AgentPool` |
| Responsibility | Pool of sub-agent sessions spawned for swarm tasks. Max 50 concurrent sub-agents. |
| Key interfaces | `DynamicSupervisor.start_child/2` |

### Fleet.Supervisor

| | |
|---|---|
| Type | Supervisor |
| Module | `OptimalSystemAgent.Fleet.Supervisor` |
| Responsibility | Manages a fleet of OSA instances (sentinel model). Tracks registered remote agents and routes cross-instance tasks. Opt-in via `OSA_FLEET_ENABLED=true`. |
| Condition | `OSA_FLEET_ENABLED=true` |

### Sidecar.Manager

| | |
|---|---|
| Type | GenServer |
| Module | `OptimalSystemAgent.Sidecar.Manager` |
| Responsibility | Creates ETS tables for sidecar circuit breakers and manages the lifecycle of external sidecar processes (Go, Python). Always starts so the ETS tables are available before optional sidecars are added. |
| Key interfaces | `Sidecar.Manager.status/0`, `Sidecar.Manager.restart/1` |

### Go.Tokenizer

| | |
|---|---|
| Type | GenServer (Port-based) |
| Module | `OptimalSystemAgent.Go.Tokenizer` |
| Responsibility | Wraps the Go BPE tokenizer binary via Erlang Port. `Agent.Context.estimate_tokens/1` calls this for accurate token counting. Falls back to heuristic estimation when unavailable. |
| Condition | `go_tokenizer_enabled` in application config |
| Key interfaces | `Go.Tokenizer.count_tokens/1` |

### Python.Supervisor

| | |
|---|---|
| Type | Supervisor |
| Module | `OptimalSystemAgent.Python.Supervisor` |
| Responsibility | Manages Python sidecar processes for ML inference tasks (embeddings, classification) that are not available in Elixir. Communicates via Port or HTTP. |
| Condition | `python_sidecar_enabled` in application config |

### Go.Git

| | |
|---|---|
| Type | GenServer (Port-based) |
| Module | `OptimalSystemAgent.Go.Git` |
| Responsibility | Wraps a Go-based git operations binary. Provides higher-performance git operations than shelling out to the `git` CLI. |
| Condition | `go_git_enabled` in application config |

### Go.Sysmon

| | |
|---|---|
| Type | GenServer (Port-based) |
| Module | `OptimalSystemAgent.Go.Sysmon` |
| Responsibility | System monitor sidecar. Collects CPU, memory, and disk metrics from Go-side and exposes them to the agent for environment awareness. |
| Condition | `go_sysmon_enabled` in application config |

### WhatsAppWeb

| | |
|---|---|
| Type | GenServer |
| Module | `OptimalSystemAgent.WhatsAppWeb` |
| Responsibility | WhatsApp Web protocol handler (browser automation). Operates independently from the WhatsApp Business API channel adapter. |
| Condition | `whatsapp_web_enabled` in application config |

### Sandbox.Supervisor

| | |
|---|---|
| Type | Supervisor |
| Module | `OptimalSystemAgent.Sandbox.Supervisor` |
| Responsibility | Manages isolated code execution environments. Used by the `code_sandbox` and `compute_vm` tools to run untrusted code with resource limits. |
| Condition | `sandbox_enabled` in application config |

### Integrations.Wallet

| | |
|---|---|
| Type | GenServer |
| Module | `OptimalSystemAgent.Integrations.Wallet` |
| Responsibility | Cryptocurrency wallet integration for the `wallet_ops` tool. Manages key storage and transaction signing. Starts alongside a `Mock` provider for testing. |
| Condition | `wallet_enabled` in application config |

### System.Updater

| | |
|---|---|
| Type | GenServer |
| Module | `OptimalSystemAgent.System.Updater` |
| Responsibility | OTA self-update manager. Polls for new OSA releases, downloads update bundles, and triggers hot code reload or restart sequences. |
| Condition | `update_enabled` in application config |

### Platform.AMQP

| | |
|---|---|
| Type | GenServer |
| Module | `OptimalSystemAgent.Platform.AMQP` |
| Responsibility | AMQP publisher for integration with RabbitMQ or compatible brokers. Publishes `agent_response` and `system_event` events to configured exchanges. |
| Condition | `AMQP_URL` environment variable set |
