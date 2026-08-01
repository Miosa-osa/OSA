# OSA Documentation

> **OSA v1.0.052** — Optimal System Agent
> Elixir/OTP + Rust TUI + Tauri/SvelteKit. Signal Theory-based AI agent orchestration.
> 27 LLM providers · 82 tools · 12 chat channels · Apache 2.0

---

## Quick Start

```bash
# Install and run (macOS / Linux)
curl -fsSL https://raw.githubusercontent.com/Miosa-osa/OSA/main/scripts/install.sh | sh
osa

# Windows (PowerShell)
#   irm https://raw.githubusercontent.com/Miosa-osa/OSA/main/scripts/install.ps1 | iex

# Or from source
git clone https://github.com/Miosa-osa/OSA.git
cd OSA && mix setup && mix osa.serve
```

> Homebrew is **not** a supported install path — the tap formula is many
> releases stale and its tarball omits the Rust TUI. See `Formula/osa.rb`.

See [Getting Started](getting-started/) for installation, configuration, and first run.

---

## Documentation Map

### [Learning](learning/) — New to the Tech Stack?

If you've never used Elixir, don't know what the BEAM VM is, or want to understand
why OSA is built the way it is — start here.

| Guide | What You'll Learn |
|---|---|
| [BEAM & OTP](learning/beam-and-otp.md) | What makes Elixir/OTP special — processes, supervisors, fault tolerance |
| [Supervision Trees](learning/supervision-trees.md) | How OSA's process hierarchy works and why it matters |
| [ETS & persistent_term](learning/ets-and-persistent-term.md) | In-memory storage — why it's fast and when OSA uses it |
| [goldrush Events](learning/goldrush-events.md) | Compiled event routing — how events dispatch at BEAM instruction speed |
| [Signal Theory](learning/signal-theory-explained.md) | The 5-tuple classification that makes OSA different from every other agent |
| [ReAct Pattern](learning/react-pattern.md) | How AI agents reason: think → act → observe → repeat |
| [Desktop Stack](learning/tauri-sveltekit.md) | Tauri + SvelteKit — how the desktop app is built |
| [LLM Providers](learning/llm-providers.md) | How OSA talks to 18 different AI model providers |

---

### [Foundation Core](foundation-core/) — Architecture & Principles

The architectural foundation: why OSA exists, how it's designed, and the rules
that govern module interaction.

| Section | What It Covers |
|---|---|
| [Overview](foundation-core/overview/) | Purpose, principles, boundaries, dependency rules, glossary |
| [Architecture](foundation-core/architecture/) | System design, component model, execution flow, data flow |
| [Core Components](foundation-core/core-components/) | Runtime, configuration, events, error handling, logging, observability |
| [Interfaces](foundation-core/interfaces/) | API surface, service contracts, event contracts, integration points |
| [Security](foundation-core/security/) | Security model, threat model, access control, data protection |
| [Data](foundation-core/data/) | Data model, storage architecture, migration strategy |
| [Reliability](foundation-core/reliability/) | Fault tolerance, graceful degradation, recovery procedures |
| [Governance](foundation-core/governance/) | Versioning, deprecation, ADRs |
| [Diagrams](foundation-core/diagrams/) | Supervision tree, module dependencies, workflow diagrams |

---

### [Backend](backend/) — Deep Subsystem Documentation

Every subsystem documented in depth — module names, function signatures, config
keys, code examples.

| Section | Docs | What It Covers |
|---|---|---|
| [Agent Loop](backend/agent-loop/) | 6 | Core reasoning engine — ReAct loop, context builder, strategies, compactor, scratchpad, auto-fixer |
| [LLM Providers](backend/providers/) | 16 | 18 providers — Anthropic, OpenAI, Groq, Ollama, Google, DeepSeek, and 12 more. Config, models, fallback chains |
| [Tools](backend/tools/) | 6 | 32 built-in tools — file ops, shell, git, web, memory, intelligence. Registry, middleware, custom tools |
| [Channels](backend/channels/) | 12 | 12 chat channels — CLI, HTTP, Telegram, Discord, Slack, WhatsApp, Signal, Matrix, Email, QQ, DingTalk, Feishu |
| [Memory](backend/memory/) | 7 | 5-layer memory — store, episodic, learning, knowledge graph, cortex, taxonomy |
| [Orchestration](backend/orchestration/) | 5 | Multi-agent coordination — orchestrator, agent roster, swarm mode, fleet, delegation |
| [Events](backend/events/) | 3 | goldrush event bus, OSCP protocol, telemetry metrics |
| [Infrastructure](backend/infrastructure/) | 6 | Sandbox, MCP, sidecar, scheduler, security, intelligence |
| [Platform](backend/platform/) | 4 | Multi-tenant — auth, tenants, AMQP, instances |
| [Signal Theory](backend/signal-theory.md) | 1 | 5-tuple classification — mode, genre, type, weight, format |

---

### [Desktop](desktop/) — Command Center

The Tauri 2 + SvelteKit 5 desktop application.

| Doc | What It Covers |
|---|---|
| [Overview](desktop/README.md) | What the Command Center is, key features, how to run it |
| [Architecture](desktop/architecture.md) | Tauri shell, SvelteKit frontend, Elixir sidecar, IPC commands |
| [Stores](desktop/stores.md) | Svelte state management — chat, sessions, auth, permissions |
| [API Client](desktop/api-client.md) | HTTP client, SSE streaming, event types, reconnection |
| [Components](desktop/components.md) | Chat UI, terminal, onboarding, settings |
| [Development](desktop/development.md) | Dev setup, hot reload, building, debugging |

---

### [Features](features/) — Feature Documentation

| Doc | What It Covers |
|---|---|
| [Hooks](features/hooks.md) | 13 lifecycle events, 10 active hooks, custom hook authoring |
| [Recipes](features/recipes.md) | Reusable workflow templates |
| [Skills](features/skills.md) | Dynamic skill system — built-in + SKILL.md custom skills |
| [Voice](features/voice.md) | Voice I/O — STT, TTS, audio levels |
| [Proactive Mode](features/proactive-mode.md) | Autonomous work triggered by signals and schedules |
| [Tasks](features/tasks.md) | Task tracking, queue management |
| [Computer Use](features/computer-use.md) | Screen interaction capabilities |
| [Orchestration](features/orchestration.md) | Multi-agent feature overview |
| [TUI](features/tui.md) | Composer (@-mentions, ghost-text, bash-mode), rendering (LaTeX, tables), notifications, status cues, streaming viewport |

---

### [Reference](reference/) — API & CLI Reference

| Doc | What It Covers |
|---|---|
| [HTTP API](reference/http-api.md) | All REST endpoints — auth, sessions, chat, orchestration, data, knowledge |
| [CLI Commands](reference/cli-reference.md) | All slash commands by category |
| [SDK](reference/sdk.md) | Public contracts for tools, agents, channels, hooks |
| [Knowledge Explorer](reference/knowledge-explorer.md) | Knowledge graph query interface |

---

### [Getting Started](getting-started/) — Installation & Setup

| Doc | What It Covers |
|---|---|
| [Installation](getting-started/README.md) | Prerequisites, install methods (Homebrew, source, Docker) |
| [Configuration](getting-started/configuration.md) | Config keys, env vars, feature flags |
| [Troubleshooting](getting-started/troubleshooting.md) | Common issues and solutions |

---

### [Operations](operations/) — Running OSA in Production

| Doc | What It Covers |
|---|---|
| [Deployment](operations/deployment.md) | Docker, systemd, Nginx, production checklist |
| [Self-Update](operations/self-update.md) | Rollback-safe `osa update` — stage/build/boot-probe/atomic-swap, rollback, dry-run |
| [Debugging](operations/debugging.md) | Log queries, ETS inspection, failure patterns |
| [Changelog](operations/changelog.md) | Release history |

See also the repo-root [CHANGELOG.md](../CHANGELOG.md) for this cycle's changes.

---

### [How-To Guides](foundation-core/how-to/) — Extending & Debugging OSA

| Section | What It Covers |
|---|---|
| [Getting Started](foundation-core/how-to/getting-started.md) | First steps after installation |
| [Building on Core](foundation-core/how-to/building-on-core/) | Creating modules, extending services, custom middleware |
| [Debugging](foundation-core/how-to/debugging/) | Debugging guide, common issues, provider troubleshooting |
| [Integration](foundation-core/how-to/integration/) | Provider setup, channel setup, desktop integration |
| [Testing](foundation-core/how-to/testing/) | Test strategy, test patterns |

---

### [Development](foundation-core/development/) — Contributing to OSA

| Doc | What It Covers |
|---|---|
| [Dev Setup](foundation-core/development/development-setup.md) | Environment setup, dependencies, IDE config |
| [Coding Standards](foundation-core/development/coding-standards.md) | Style guide, naming, documentation requirements |
| [Contribution Guide](foundation-core/development/contribution-guide.md) | Fork, branch, PR process |
| [Build System](foundation-core/development/build-system.md) | Mix, releases, Docker builds |
| [CI/CD](foundation-core/development/ci-cd.md) | GitHub Actions, testing pipeline |

---

### [Known Issues](known-issues/)

18 open issues organized by severity with individual tracking files, root cause
analysis, code references, and suggested fixes. See the [issue index](known-issues/README.md).

---

### [Archive](archive/)

Historical documentation preserved for reference:

- `architecture-legacy/` — Original architecture docs
- `research/` — Competitor analysis, prompt engineering
- `roadmap/` — Historical roadmap docs
- `agent-dispatch/` — Multi-agent dispatch framework research
- `flows/` — Message flow analysis across architectures

---

## Directory Map

```
docs/
├── README.md                  ← You are here
├── KNOWN_ISSUES.md            Bug catalog (18 open, 4 fixed)
│
├── learning/                  Education — BEAM, OTP, goldrush, Signal Theory (9 docs)
├── getting-started/           Install, config, troubleshooting (3 docs)
│
├── foundation-core/           Architecture & principles
│   ├── overview/              Purpose, principles, boundaries, glossary (5 docs)
│   ├── architecture/          System design, components, flows (7 docs)
│   ├── core-components/       Runtime, config, events, errors, logging (14 docs)
│   ├── interfaces/            APIs, contracts, integration points (4 docs)
│   ├── security/              Security model, threats, access control (4 docs)
│   ├── data/                  Data model, storage, migrations (3 docs)
│   ├── how-to/                Guides for extending, debugging, testing (11 docs)
│   ├── development/           Dev setup, standards, contributing (5 docs)
│   ├── operations/            Deploy, config reference, monitoring (5 docs)
│   ├── reliability/           Fault tolerance, degradation, recovery (3 docs)
│   ├── governance/            Versioning, deprecation, ADRs (5 docs)
│   ├── ownership/             Maintainers, module ownership (2 docs)
│   └── diagrams/              Visual architecture diagrams (5 docs)
│
├── backend/                   Deep subsystem docs
│   ├── agent-loop/            Core reasoning engine (7 docs)
│   ├── providers/             18 LLM providers (16 docs)
│   ├── tools/                 32 built-in tools (6 docs)
│   ├── channels/              12 chat channels (12 docs)
│   ├── memory/                5-layer memory system (8 docs)
│   ├── orchestration/         Multi-agent coordination (5 docs)
│   ├── events/                Event bus, protocol, telemetry (3 docs)
│   ├── infrastructure/        Sandbox, MCP, scheduler (6 docs)
│   ├── platform/              Multi-tenant infrastructure (4 docs)
│   └── signal-theory.md       5-tuple classification
│
├── desktop/                   Tauri Command Center (6 docs)
├── features/                  Hooks, recipes, skills, voice, TUI (9 docs)
├── reference/                 HTTP API, CLI, SDK (4 docs)
├── operations/                Deployment, self-update, debugging, changelog (4 docs)
│
└── archive/                   Historical docs (preserved)
```

**Total: ~170+ documents across 12 sections**
