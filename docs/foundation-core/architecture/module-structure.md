# Module Structure

OSA contains 853 Elixir source files totaling approximately 82K lines of Elixir code across
`lib/`. The main application logic lives under `lib/optimal_system_agent/`. Supporting libraries
live under `lib/miosa/` (memory shims) and `lib/osa_sdk.ex` (public SDK entry point).

---

## Directory Map

```
lib/
├── optimal_system_agent/        # Main application (853 .ex files, ~82K lines)
│   ├── agent/                   # Core reasoning loop (73 files, ~22K lines)
│   ├── channels/                # I/O adapters (51 files, ~12K lines)
│   ├── tools/                   # Built-in tool modules (56 files, ~13K lines)
│   ├── providers/               # LLM provider integrations (11 files, ~4K lines)
│   ├── commands/                # Slash command implementations (12 files, ~3K lines)
│   ├── swarm/                   # Multi-agent patterns (8 files, ~3K lines)
│   ├── events/                  # Event bus, DLQ, stream (6 files)
│   ├── supervisors/             # Subsystem supervisors (4 files)
│   ├── mcp/                     # MCP client/server (3 files)
│   ├── vault/                   # Persistent context store (2 files)
│   ├── bridge/                  # PubSub bridge (1 file)
│   ├── store/                   # Ecto repo (1 file)
│   ├── security/                # Shell policy, guardrails (2 files)
│   ├── signal/                  # Signal Theory shim (1 file)
│   ├── telemetry/               # Metrics collection (1 file)
│   ├── intelligence/            # Signal Theory intelligence (6 files)
│   ├── fleet/                   # Fleet management (3 files)
│   ├── sidecar/                 # External process management (3 files)
│   ├── go/                      # Go sidecar wrappers (3 files)
│   ├── python/                  # Python sidecar (2 files)
│   ├── sdk/                     # Public SDK modules (5 files)
│   ├── platform/                # Platform integrations (3 files)
│   ├── sandbox/                 # Code execution sandbox (3 files)
│   ├── webhooks/                # Outbound webhook delivery (2 files)
│   ├── system/                  # OTA updater (1 file)
│   ├── integrations/            # Wallet, external services (3 files)
│   ├── recipes/                 # Reusable agent recipes (4 files)
│   ├── mcts/                    # Monte Carlo Tree Search index (3 files)
│   ├── os/                      # OS template registry (1 file)
│   ├── tenant/                  # Multi-tenant configuration (1 file)
│   └── utils.ex                 # Shared utilities
├── miosa/                       # Memory shims for miosa_* packages
│   ├── memory_store.ex
│   └── shims.ex
└── osa_sdk.ex                   # Public SDK entry point
```

---

## agent/ — Core Reasoning Loop (73 files, ~22K lines)

The heart of OSA. Every agent session runs as an `Agent.Loop` GenServer. The loop coordinates
context building, LLM calls, tool execution, and memory persistence.

### Top-level agent modules

| File | Module | Purpose |
|---|---|---|
| `loop.ex` | `Agent.Loop` | Bounded ReAct agent loop GenServer. Entry point for all session messages. |
| `context.ex` | `Agent.Context` | Two-tier token-budgeted system prompt assembly (static base + 11 dynamic blocks). |
| `hooks.ex` | `Agent.Hooks` | Priority-ordered middleware pipeline. ETS-backed for concurrent reads. |
| `memory.ex` | `Agent.Memory` | Long-term memory store with relevance filtering. |
| `tasks.ex` | `Agent.Tasks` | Per-session task queue with workflow context injection. |
| `learning.ex` | `Agent.Learning` | Pattern and solution accumulation from interactions. |
| `orchestrator.ex` | `Agent.Orchestrator` | Multi-agent coordination and result aggregation. |
| `scheduler.ex` | `Agent.Scheduler` | Cron and interval-based task scheduling. |
| `compactor.ex` | `Agent.Compactor` | Context window compaction via summarization. |
| `cortex.ex` | `Agent.Cortex` | Multi-provider synthesis (fan-out + aggregate). |
| `strategy.ex` | `Agent.Strategy` | Reasoning strategy selection (ReAct, plan-then-execute, etc.). |
| `tier.ex` | `Agent.Tier` | Provider tier assignment (opus/sonnet/haiku equivalents per provider). |
| `soul.ex` | `Soul` | Loads and caches `SYSTEM.md` into `persistent_term` at boot. |
| `prompt_loader.ex` | `PromptLoader` | Loads prompt templates from `priv/prompts/` into `persistent_term`. |
| `loop/proactive_compaction.ex` | `Agent.Loop.ProactiveCompaction` | Proactive context-window compaction — summarizes history before the window overflows. |
| `heartbeat_state.ex` | `Agent.HeartbeatState` | Session liveness tracking. |
| `progress.ex` | `Agent.Progress` | Progress reporting for long-running operations. |
| `introspection.ex` | `Agent.Introspection` | Self-reflection and meta-reasoning capabilities. |
| `scratchpad.ex` | `Agent.Scratchpad` | Per-session reasoning scratchpad for extended thinking. |
| `health_tracker.ex` | `Agent.HealthTracker` | Agent health metrics and alerting. |
| `replay.ex` | `Agent.Replay` | Session replay from event history. |
| `appraiser.ex` | `Agent.Appraiser` | Response quality scoring. |
| `auto_fixer.ex` | `Agent.AutoFixer` | Automatic error recovery and retry logic. |
| `explorer.ex` | `Agent.Explorer` | Codebase exploration and context gathering. |
| `debate.ex` | `Agent.Debate` | Multi-perspective reasoning via internal debate. |
| `directive.ex` | `Agent.Directive` | Parses and applies user directives to agent behavior. |
| `roster.ex` | `Agent.Roster` | Multi-agent roster management. |
| `skill_bootstrap.ex` | `Agent.SkillBootstrap` | Bootstraps skill definitions at session start. |
| `skill_evolution.ex` | `Agent.SkillEvolution` | Evolves and refines skills based on usage. |
| `workspace.ex` | `Workspace` | Working directory and project context management. |
| `agent_behaviour.ex` | `AgentBehaviour` | Elixir behaviour for custom agent implementations. |
| `cortex_provider.ex` | `Agent.CortexProvider` | Provider adapter for Cortex fan-out. |
| `treasury.ex` | `Agent.Treasury` | Agent-level budget interface to MiosaBudget. |

### agent/loop/ — Loop internals

| File | Module | Purpose |
|---|---|---|
| `loop/guardrails.ex` | `Agent.Loop.Guardrails` | Prompt injection detection (hard block before any processing). |
| `loop/noise_filter.ex` | `Channels.NoiseFilter` | Two-tier message noise filter (regex tier + signal weight tier). |
| `loop/genre_router.ex` | `Agent.Loop.GenreRouter` | Routes by signal genre; some genres return canned responses without tool use. |
| `loop/llm_client.ex` | `Agent.Loop.LLMClient` | Manages LLM API calls with retry, streaming, and provider selection. |
| `loop/tool_executor.ex` | `Agent.Loop.ToolExecutor` | Executes tool calls from LLM responses, runs hook pipeline, captures results. |
| `loop/checkpoint.ex` | `Agent.Loop.Checkpoint` | Saves and restores loop state checkpoints. |

### agent/memory/ — Memory subsystem

| File | Module | Purpose |
|---|---|---|
| `memory/episodic.ex` | `Agent.Memory.Episodic` | Per-session recent event buffer (used in context building). |
| `memory/taxonomy.ex` | `Agent.Memory.Taxonomy` | Classifies memory entries into categories (pattern, solution, fact). |
| `memory/injector.ex` | `Agent.Memory.Injector` | Selects relevant taxonomy entries and formats them for prompt injection. |
| `memory/knowledge_bridge.ex` | `Agent.Memory.KnowledgeBridge` | Bridges memory → MiosaKnowledge structured store. |

### agent/learning/ — Learning engine

| File | Module | Purpose |
|---|---|---|
| `learning/pattern_store.ex` | `Agent.Learning.PatternStore` | Persistent pattern storage with ETS fast-path. |
| `learning/solution_store.ex` | `Agent.Learning.SolutionStore` | Persistent solution (error→fix) storage. |
| `learning/classifier.ex` | `Agent.Learning.Classifier` | Classifies interactions for pattern extraction. |

### agent/orchestrator/ — Multi-agent coordination

| File | Module | Purpose |
|---|---|---|
| `orchestrator/mailbox.ex` | `Agent.Orchestrator.Mailbox` | ETS mailbox for swarm message passing. |
| `orchestrator/swarm_mode.ex` | `Agent.Orchestrator.SwarmMode` | Swarm coordinator state machine. |

### agent/strategies/ — Reasoning strategies

| File | Module | Purpose |
|---|---|---|
| `strategies/react.ex` | `Agent.Strategies.ReAct` | Default ReAct (Reason+Act) loop strategy. |
| `strategies/plan_execute.ex` | `Agent.Strategies.PlanExecute` | Plan-then-execute two-phase strategy. |
| `strategies/reflection.ex` | `Agent.Strategies.Reflection` | Reflection and self-correction strategy. |

### agent/scheduler/ — Scheduling

| File | Module | Purpose |
|---|---|---|
| `scheduler/cron.ex` | `Agent.Scheduler.Cron` | Cron expression parser and evaluator. |
| `scheduler/store.ex` | `Agent.Scheduler.Store` | Persistent schedule storage (SQLite). |

### agent/tasks/ — Task management

| File | Module | Purpose |
|---|---|---|
| `tasks/store.ex` | `Agent.Tasks.Store` | SQLite-backed task persistence. |
| `tasks/workflow.ex` | `Agent.Tasks.Workflow` | Multi-step workflow definitions. |

---

## channels/ — I/O Adapters (51 files, ~12K lines)

All inbound and outbound message routing. Every adapter implements `Channels.Behaviour`.

### Top-level channel modules

| File | Module | Purpose |
|---|---|---|
| `behaviour.ex` | `Channels.Behaviour` | Behaviour contract: `channel_name/0`, `start_link/1`, `send_message/3`, `connected?/0`. |
| `noise_filter.ex` | `Channels.NoiseFilter` | Two-tier noise filter (regex + signal weight). Blocks ~40-60% of low-value messages. |
| `manager.ex` | `Channels.Manager` | Manages channel adapter lifecycle. |
| `session.ex` | `Channels.Session` | Per-session channel state. |
| `starter.ex` | `Channels.Starter` | Deferred channel startup via `handle_continue`. |

### Adapter modules

| File | Module | Protocol |
|---|---|---|
| `cli.ex` + `cli/` | `Channels.CLI` | stdio with TUI rendering |
| `http.ex` + `http/` | `Channels.HTTP` | REST API + SSE (Bandit/Plug) |
| `telegram.ex` | `Channels.Telegram` | Telegram Bot API |
| `discord.ex` | `Channels.Discord` | Discord Gateway |
| `slack.ex` | `Channels.Slack` | Slack Events API |
| `signal.ex` | `Channels.Signal` | Signal Messenger |
| `whatsapp.ex` | `Channels.WhatsApp` | WhatsApp Business API |
| `email.ex` | `Channels.Email` | SMTP/IMAP |
| `matrix.ex` | `Channels.Matrix` | Matrix Client-Server API |
| `dingtalk.ex` | `Channels.DingTalk` | DingTalk Webhook |
| `feishu.ex` | `Channels.Feishu` | Feishu/Lark Bot |
| `qq.ex` | `Channels.QQ` | QQ Bot API |

### http/ — HTTP channel internals

The HTTP channel is the primary API surface for the SDK and Command Center. It implements:
- REST endpoints for session creation, message submission, and status queries
- SSE endpoints for streaming agent responses
- WebSocket support for real-time bidirectional communication
- The `ask_user_question` survey endpoint (writes to `:osa_survey_answers` ETS)

---

## tools/ — Built-in Tools (56 files, ~13K lines)

All tool modules implement `Tools.Behaviour`: `name/0`, `description/0`, `parameters/0`,
`execute/1`, and an optional `available?/0` guard.

### tools/builtins/ — Built-in tool implementations (40 tools)

**File operations:**

| Tool | Module | Purpose |
|---|---|---|
| `file_read` | `Tools.Builtins.FileRead` | Read file contents with line range support |
| `file_write` | `Tools.Builtins.FileWrite` | Write or overwrite files |
| `file_edit` | `Tools.Builtins.FileEdit` | Surgical string replacement in files |
| `multi_file_edit` | `Tools.Builtins.MultiFileEdit` | Edit multiple files in one call |
| `file_glob` | `Tools.Builtins.FileGlob` | Glob pattern file discovery |
| `file_grep` | `Tools.Builtins.FileGrep` | Regex content search |
| `dir_list` | `Tools.Builtins.DirList` | Directory listing |
| `diff` | `Tools.Builtins.Diff` | File diff generation |
| `notebook_edit` | `Tools.Builtins.NotebookEdit` | Jupyter notebook cell editing |

**Code intelligence:**

| Tool | Module | Purpose |
|---|---|---|
| `code_symbols` | `Tools.Builtins.CodeSymbols` | Extract symbols from source files |
| `codebase_explore` | `Tools.Builtins.CodebaseExplore` | Intelligent codebase traversal |
| `mcts_index` | `Tools.Builtins.MCTSIndex` | MCTS-based relevant file finder |
| `semantic_search` | `Tools.Builtins.SemanticSearch` | Embedding-based semantic file search |
| `git` | `Tools.Builtins.Git` | Git operations (status, diff, log, commit) |
| `github` | `Tools.Builtins.Github` | GitHub API integration |

**Execution:**

| Tool | Module | Purpose |
|---|---|---|
| `shell_execute` | `Tools.Builtins.ShellExecute` | Shell command execution (security-checked) |
| `code_sandbox` | `Tools.Builtins.CodeSandbox` | Sandboxed code execution |
| `compute_vm` | `Tools.Builtins.ComputeVm` | VM-isolated compute environment |
| `computer_use` | `Tools.Builtins.ComputerUse` | Desktop automation (screenshot, click, type) |
| `browser` | `Tools.Builtins.Browser` | Headless browser control |

**Memory and knowledge:**

| Tool | Module | Purpose |
|---|---|---|
| `memory_save` | `Tools.Builtins.MemorySave` | Persist facts to long-term memory |
| `memory_recall` | `Tools.Builtins.MemoryRecall` | Query long-term memory |
| `knowledge` | `Tools.Builtins.Knowledge` | Structured knowledge store access |
| `session_search` | `Tools.Builtins.SessionSearch` | Search current session history |

**Vault:**

| Tool | Module | Purpose |
|---|---|---|
| `vault_remember` | `Tools.Builtins.VaultRemember` | Store named context in vault |
| `vault_context` | `Tools.Builtins.VaultContext` | Retrieve vault context bundle |
| `vault_wake` | `Tools.Builtins.VaultWake` | Restore vault from persistent store |
| `vault_sleep` | `Tools.Builtins.VaultSleep` (via `vault_checkpoint`) | Persist vault to storage |
| `vault_checkpoint` | `Tools.Builtins.VaultCheckpoint` | Snapshot current vault state |
| `vault_inject` | `Tools.Builtins.VaultInject` | Inject vault content into context |

**Web:**

| Tool | Module | Purpose |
|---|---|---|
| `web_search` | `Tools.Builtins.WebSearch` | Web search via configured provider |
| `web_fetch` | `Tools.Builtins.WebFetch` | HTTP fetch with content extraction |

**Task management:**

| Tool | Module | Purpose |
|---|---|---|
| `task_write` | `Tools.Builtins.TaskWrite` | Create/update session tasks |
| `ask_user` | `Tools.Builtins.AskUser` | Pause and ask user a question (blocks until answered) |

**Multi-agent:**

| Tool | Module | Purpose |
|---|---|---|
| `orchestrate` | `Tools.Builtins.Orchestrate` | Spawn parallel sub-agents with instructions |
| `delegate` | `Tools.Builtins.Delegate` | Delegate a task to a specialized agent |

**Skills:**

| Tool | Module | Purpose |
|---|---|---|
| `create_skill` | `Tools.Builtins.CreateSkill` | Create a new SKILL.md file |
| `use_skill` | `Tools.Builtins.UseSkill` | Explicitly invoke a named skill |
| `skill_manager` | `Tools.Builtins.SkillManager` | List, enable, disable, delete skills |

**Finance/wallet:**

| Tool | Module | Purpose |
|---|---|---|
| `wallet_ops` | `Tools.Builtins.WalletOps` | Cryptocurrency wallet operations |
| `budget_status` | `Tools.Builtins.BudgetStatus` | Report current API spend status |

---

## providers/ — LLM Integrations (11 files, ~4K lines)

Thin adapter layer over LLM APIs. Each provider implements the `MiosaProviders.Behaviour`
contract. `MiosaProviders.Registry` routes calls to the active provider.

| File | Module | Provider |
|---|---|---|
| `anthropic.ex` | `MiosaProviders.Anthropic` | Claude (claude-sonnet-4-6, claude-opus-4, etc.) with prompt caching |
| `ollama.ex` | `MiosaProviders.Ollama` | Ollama local models with auto-detection |
| `openai.ex` | `MiosaProviders.OpenAI` | OpenAI GPT-4o, GPT-4o-mini |
| `gemini.ex` | `MiosaProviders.Gemini` | Google Gemini |
| `groq.ex` | `MiosaProviders.Groq` | Groq inference |
| `mistral.ex` | `MiosaProviders.Mistral` | Mistral AI |
| `together.ex` | `MiosaProviders.Together` | Together AI |
| `cohere.ex` | `MiosaProviders.Cohere` | Cohere Command |
| `deepseek.ex` | `MiosaProviders.DeepSeek` | DeepSeek |
| `local.ex` | `MiosaProviders.Local` | Local HTTP inference server (OpenAI-compatible) |
| `registry.ex` | `MiosaProviders.Registry` | Provider router and context window registry |

---

## commands/ — Slash Commands (12 files, ~3K lines)

Each command module handles a specific slash command. The `Commands` GenServer discovers and
registers these at boot, alongside user-defined markdown commands from `~/.osa/commands/`.

| File | Command | Purpose |
|---|---|---|
| `help.ex` | `/help` | List available commands and shortcuts |
| `budget.ex` | `/budget` | Display API spend and budget status |
| `status.ex` | `/status` | System health and session status |
| `memory.ex` | `/memory` | Inspect or clear long-term memory |
| `tasks.ex` | `/tasks` | List and manage session tasks |
| `skills.ex` | `/skills` | List, enable, or disable skills |
| `plan.ex` | `/plan` | Toggle plan mode |
| `compact.ex` | `/compact` | Trigger context compaction |
| `clear.ex` | `/clear` | Clear conversation history |
| `hooks.ex` | `/hooks` | Inspect registered hooks and metrics |
| `providers.ex` | `/providers` | List and switch LLM providers |
| `swarm.ex` | `/swarm` | Manage swarm sessions |

---

## swarm/ — Multi-Agent Patterns (8 files, ~3K lines)

| File | Module | Purpose |
|---|---|---|
| `supervisor.ex` | `Swarm.Supervisor` | Umbrella for swarm processes |
| `orchestrator.ex` | `Swarm.Orchestrator` | Task decomposition and agent assignment |
| `worker.ex` | `Swarm.Worker` | Sub-agent worker process |
| `mailbox.ex` | `Swarm.Mailbox` | Swarm-level message routing |
| `planner.ex` | `Swarm.Planner` | Task decomposition planning |
| `patterns.ex` | `Swarm.Patterns` | Pre-defined swarm patterns (map/reduce, pipeline, etc.) |
| `pact.ex` | `Swarm.Pact` | Inter-agent agreements and shared state |
| `intelligence.ex` | `Swarm.Intelligence` | Emergent swarm coordination |

---

## events/ — Event Bus (6 files)

| File | Module | Purpose |
|---|---|---|
| `bus.ex` | `Events.Bus` | goldrush-compiled event router. Zero-overhead dispatch via compiled BEAM bytecode. |
| `dlq.ex` | `Events.DLQ` | Dead-letter queue with exponential backoff retry. |
| `stream.ex` | `Events.Stream` | Per-session circular buffer (max 1000 events) for SSE. |
| `event.ex` | `Events.Event` | Event struct: `id`, `type`, `source`, `payload`, signal fields, tracing fields. |
| `classifier.ex` | `Events.Classifier` | Auto-classifies Signal Theory dimensions on events. |
| `failure_modes.ex` | `Events.FailureModes` | Detects Signal Theory failure patterns (sampled 1-in-10). |

---

## supervisors/ — Subsystem Supervisors (4 files)

| File | Module | Strategy |
|---|---|---|
| `infrastructure.ex` | `Supervisors.Infrastructure` | `:rest_for_one` |
| `sessions.ex` | `Supervisors.Sessions` | `:one_for_one` |
| `agent_services.ex` | `Supervisors.AgentServices` | `:one_for_one` |
| `extensions.ex` | `Supervisors.Extensions` | `:one_for_one` |

---

## Smaller Subsystems

| Directory | Files | Purpose |
|---|---|---|
| `mcp/` | 3 | MCP client, server GenServer, JSON-RPC protocol |
| `vault/` | 2 | Vault store and persistence logic |
| `bridge/` | 1 | `Bridge.PubSub` — Events.Bus → Phoenix.PubSub bridge |
| `store/` | 1 | Ecto repo (SQLite3) |
| `security/` | 2 | `ShellPolicy` (dangerous command blocklist), `Guardrails` (prompt injection) |
| `signal/` | 1 | `Signal` — delegation shim to `MiosaSignal` package |
| `telemetry/` | 1 | `Telemetry.Metrics` — tool timing aggregation |
| `intelligence/` | 6 | Signal Theory intelligence: ConversationTracker, ContactDetector, ProactiveMonitor |
| `fleet/` | 3 | Fleet supervisor, registry, sentinel model |
| `sidecar/` | 3 | Sidecar.Manager, circuit breaker, process monitor |
| `go/` | 3 | Go.Tokenizer, Go.Git, Go.Sysmon (Port-based wrappers) |
| `python/` | 2 | Python.Supervisor, Python.Worker |
| `sdk/` | 5 | Public SDK: session management, tool invocation, event subscription |
| `platform/` | 3 | Platform.Repo (PostgreSQL), Platform.AMQP, onboarding |
| `sandbox/` | 3 | Sandbox supervisor, executor, resource limiter |
| `webhooks/` | 2 | Webhooks.Dispatcher, endpoint registry |
| `system/` | 1 | System.Updater — OTA updates |
| `integrations/` | 3 | Wallet, Wallet.Mock, external service wrappers |
| `recipes/` | 4 | Reusable agent task templates |
| `mcts/` | 3 | MCTS index builder, searcher, pruner |
| `os/` | 1 | OS.Registry — OS template connection tracking |
| `tenant/` | 1 | Multi-tenant config isolation |
| `onboarding/` | 2 | First-run setup and persona initialization |
| `cli/` | 3 | CLI rendering, input handling, TUI layout |
| `command_center/` | 4 | Web-based Command Center (Phoenix LiveView or REST) |
| `agents/` | 2 | Additional named agent profiles |
| `protocol/` | 2 | Protocol definitions for cross-agent communication |

---

## Naming Conventions

- Module names use the `OptimalSystemAgent.*` namespace for all application code.
- External library modules use their own namespace (`MiosaLLM`, `MiosaProviders`, `MiosaBudget`,
  `MiosaKnowledge`, `MiosaSignal`).
- All GenServer modules follow the pattern: `use GenServer`, named `__MODULE__` in `start_link/1`.
- All Supervisor modules follow: `use Supervisor`, named `__MODULE__` in `start_link/1`.
- Tool modules live under `Tools.Builtins.*` and register via `Tools.Registry.load_builtin_tools/0`.
- Channel adapters live under `Channels.*` and register with `Channels.Supervisor`.

---

## Dependencies (Key External Packages)

| Package | Purpose |
|---|---|
| `bandit` | HTTP server (Plug-compatible, replaces Cowboy) |
| `phoenix_pubsub` | In-process pub/sub |
| `ecto_sqlite3` | SQLite3 database adapter |
| `goldrush` | Compiled BEAM event routing |
| `yaml_elixir` | YAML frontmatter parsing for SKILL.md files |
| `ex_json_schema` | JSON Schema validation for tool arguments |
| `jason` | JSON encode/decode |
| `req` | HTTP client for provider and tool calls |
| `miosa_llm` | LLM provider abstraction and health checking |
| `miosa_providers` | Multi-provider LLM routing |
| `miosa_budget` | API spend tracking and budget enforcement |
| `miosa_knowledge` | Structured knowledge store (Mnesia/ETS) |
| `miosa_signal` | Signal Theory types and measurement |
