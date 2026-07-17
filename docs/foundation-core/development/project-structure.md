# Project Structure

Audience: developers who are new to the OSA codebase and need a map before
diving into the source.

---

## Root Layout

```
OSA/
├── mix.exs                 Application definition, deps, aliases, releases
├── mix.lock                Locked dependency versions
├── VERSION                 Current version string (read by mix.exs)
├── config/                 Mix configuration
├── lib/                    All Elixir source code
├── test/                   ExUnit tests
├── priv/                   Non-Elixir assets bundled with releases
├── desktop/                Tauri desktop application (Svelte + Rust)
├── bin/                    Shell scripts for running and managing OSA
├── docs/                   Project documentation
├── rel/                    Release templates
├── native/                 Rustler NIF stubs (currently unused)
├── sandbox/                Isolated experimental code
├── scripts/                Utility scripts (not part of the application)
└── support/                CI and build support files
```

---

## config/

```
config/
├── config.exs              Compile-time defaults (provider names, limits)
├── dev.exs                 Development overrides (debug logging, test secrets)
├── prod.exs                Production overrides (strict logging, no debug routes)
├── test.exs                Test overrides (disable LLM, port 0, test secret)
└── runtime.exs             Runtime config: reads env vars, detects provider
```

`runtime.exs` is the primary configuration file. It runs at application
startup after the release is assembled. Everything that changes between
environments (API keys, ports, budget limits) is configured here via
environment variables.

---

## lib/

```
lib/
├── optimal_system_agent/   Main application namespace
├── miosa/                  Compatibility shims (Miosa.* → OptimalSystemAgent.*)
├── mix/                    Custom Mix tasks
└── osa_sdk.ex              Public SDK entry point
```

### lib/optimal_system_agent/

This is the primary namespace. Every module is `OptimalSystemAgent.*`.

```
optimal_system_agent/
├── application.ex          OTP Application — supervision tree root
├── cli.ex                  CLI entry point (subcommands: chat, setup, serve, doctor)
├── commands.ex             Slash command registry (built-in + custom)
├── commands/               Individual command handler modules
├── machines.ex             Machine/agent registry
├── signal.ex               Signal Theory facade
├── soul.ex                 Personality/identity file loader
├── prompt_loader.ex        Prompt template loader (priv/prompts/)
├── nif.ex                  NIF bridge (pure Elixir fallbacks when Rust unavailable)
├── utils.ex                Shared utility functions
│
├── agent/                  Agent loop and intelligence
│   ├── loop.ex             Bounded ReAct loop (core reasoning engine)
│   ├── loop/               Loop sub-modules
│   │   ├── tool_executor.ex  Tool dispatch, permission tiers, hook invocation
│   │   ├── llm_client.ex     LLM call wrapper (retry, fallback, streaming)
│   │   ├── guardrails.ex     Prompt injection detection and response scrubbing
│   │   ├── genre_router.ex   Signal genre → response strategy routing
│   │   └── checkpoint.ex     Conversation checkpoint save/restore
│   ├── memory.ex           Conversation memory (delegates to MiosaMemory)
│   ├── memory/             Memory sub-modules
│   │   ├── injector.ex       Context injection into prompts
│   │   ├── knowledge_bridge.ex  Bridge to MiosaKnowledge store
│   │   └── sqlite_bridge.ex    SQLite persistence layer
│   ├── context.ex          Context builder (identity + memory + runtime)
│   ├── compactor.ex        Context window compaction (sliding window, importance-weighted)
│   ├── hooks.ex            Middleware pipeline (ETS-backed, priority-ordered)
│   ├── cortex.ex           Background topic synthesis and bulletin board
│   ├── scheduler.ex        Cron-like proactive task scheduling
│   ├── orchestrator.ex     Multi-agent workflow coordinator
│   ├── learning.ex         Pattern capture and meta-learning
│   ├── tier.ex             LLM tier detection (fast / standard / elite)
│   └── strategies/         Strategy modules (debate, explore, etc.)
│
├── channels/               Channel adapters
│   ├── behaviour.ex        Behaviour contract for all adapters
│   ├── noise_filter.ex     Two-tier signal filter (deterministic + weight-based)
│   ├── http.ex             HTTP/SSE API (Plug + Bandit, port 9089)
│   ├── cli.ex              Interactive terminal chat
│   ├── telegram.ex         Telegram Bot API adapter
│   ├── discord.ex          Discord adapter
│   ├── slack.ex            Slack adapter
│   ├── whatsapp.ex         WhatsApp adapter
│   ├── matrix.ex           Matrix adapter
│   ├── email.ex            Email adapter
│   ├── dingtalk.ex         DingTalk adapter
│   ├── feishu.ex           Feishu adapter
│   ├── qq.ex               QQ adapter
│   ├── starter.ex          Deferred channel boot (starts configured adapters)
│   ├── session.ex          Session lifecycle helpers
│   └── manager.ex          Channel manager
│
├── events/                 Event system
│   ├── bus.ex              goldrush-compiled event router (zero-overhead dispatch)
│   ├── event.ex            Event struct definition
│   ├── classifier.ex       Auto-classification of events with Signal Theory
│   ├── dlq.ex              Dead Letter Queue (retry with exponential backoff)
│   ├── failure_modes.ex    Signal Theory failure mode detection
│   └── stream.ex           Per-session circular event buffer
│
├── providers/              LLM providers
│   ├── behaviour.ex        Behaviour contract for providers
│   ├── registry.ex         goldrush-compiled provider router
│   ├── health_checker.ex   Circuit breaker and rate-limit tracker
│   ├── anthropic.ex        Anthropic provider
│   ├── openai_compat.ex    OpenAI-compatible base provider
│   ├── openai_compat_provider.ex  OpenAI-compatible variants (Groq, Together, etc.)
│   ├── google.ex           Google Gemini provider
│   ├── cohere.ex           Cohere provider
│   ├── ollama.ex           Ollama (local models) provider
│   ├── replicate.ex        Replicate provider
│   └── tool_call_parsers.ex  Provider-specific tool call format normalizers
│
├── tools/                  Tool system
│   ├── registry.ex         Tool and skill registry (goldrush-compiled dispatcher)
│   ├── cache.ex            Tool output cache
│   ├── cached_executor.ex  Caching wrapper for tool execution
│   ├── synthesizer.ex      Tool result synthesis
│   └── builtins/           Built-in tool implementations (file, git, web, etc.)
│
├── vault/                  Structured long-term memory
│   ├── vault.ex            Public API facade
│   ├── store.ex            File-backed memory store
│   ├── category.ex         Memory categories (:fact, :preference, :project, …)
│   ├── fact_extractor.ex   LLM-based fact extraction from content
│   ├── fact_store.ex       Extracted fact storage
│   ├── context_profile.ex  Context profiling for prompt injection
│   ├── inject.ex           Keyword-matched prompt injection
│   ├── observer.ex         Observation buffering
│   ├── handoff.ex          Session handoff (context for new sessions)
│   ├── session_lifecycle.ex  Wake/sleep/checkpoint management
│   └── supervisor.ex       Vault subsystem supervisor
│
├── signal/                 Signal Theory subsystem
│   └── classifier.ex       OSA-wired classifier (delegates to MiosaSignal)
│
├── supervisors/            Subsystem supervisors
│   ├── infrastructure.ex   Core layer (bus, storage, tools, MCP)
│   ├── sessions.ex         Channel adapters + session DynamicSupervisor
│   ├── agent_services.ex   Memory, hooks, learning, scheduler, etc.
│   └── extensions.ex       Opt-in subsystems (treasury, fleet, swarm, etc.)
│
├── intelligence/           Conversation intelligence
│   ├── conversation_tracker.ex  Long-term conversation analysis
│   ├── comm_coach.ex            Communication coaching
│   └── contact_detector.ex      Contact/person detection
│
├── mcp/                    Model Context Protocol integration
│   └── client.ex           MCP server manager and tool registration
│
├── telemetry/              Telemetry and metrics
│   └── metrics.ex          Telemetry event subscriptions and counters
│
├── store/                  SQLite Ecto repository
│   └── repo.ex             Ecto.Repo for agent store
│
└── platform/               Multi-tenant PostgreSQL layer (opt-in)
    └── repo.ex             Ecto.Repo for platform database
```

### lib/miosa/

Thin shims that satisfy call sites expecting the `Miosa.*` or `MiosaX.*`
namespace. The actual implementations live in `lib/optimal_system_agent/` —
these modules just delegate:

```
miosa/
├── shims.ex          Core shim (MiosaMemory, MiosaProviders, etc.)
└── memory_store.ex   MiosaMemory.Store shim
```

### lib/mix/

Custom Mix tasks:

```
mix/tasks/
└── osa.chat.ex       `mix chat` — starts CLI chat mode
```

---

## priv/

Non-Elixir assets packaged with the release:

```
priv/
├── go/tokenizer/       Go binary for accurate BPE token counting
│   └── osa-tokenizer   Pre-compiled binary (built separately for CI)
├── prompts/            YAML/Markdown prompt templates
│   ├── soul.yml        Default agent personality
│   └── *.md            System prompt fragments
├── repo/migrations/    Ecto SQLite migrations
├── scripts/            Shell scripts (install, update)
├── rust/               Rust source for the TUI (if enabled)
├── skills/             Default skill definitions
├── swarms/             Swarm configuration files
└── rules/              Built-in constraint rules
```

---

## test/

```
test/
├── test_helper.exs             ExUnit setup (excludes :integration by default)
├── optimal_system_agent/       Unit tests (mirrors lib/ structure)
├── integration/                Integration tests (tagged @moduletag :integration)
├── e2e/                        End-to-end tests
└── support/                    Shared test utilities and factories
```

---

## desktop/

Tauri application:

```
desktop/
├── package.json        Node.js project (Svelte + Vite)
├── src/                Svelte frontend source
├── src-tauri/          Rust Tauri application shell
├── static/             Static assets
├── vite.config.ts      Vite bundler config
└── svelte.config.js    SvelteKit config
```

---

## bin/

```
bin/
├── osa             Shell wrapper — dispatches subcommands (chat, setup, serve, doctor, version)
├── install         Installation script
└── version-bump    Release version management script
```

---

## Related

- [Local Development](./local-development.md) — run and develop OSA locally
- [Coding Standards](./coding-standards.md) — naming and style conventions
- [Understanding the Core](../how-to/understanding-the-core.md) — mental model of the runtime
