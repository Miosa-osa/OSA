# OSA — the Optimal System Agent

> Signal Theory-optimized proactive AI agent. Local-first. Open source. BEAM-powered.

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/Version-0.4.0-orange.svg)](#)
[![Elixir](https://img.shields.io/badge/Elixir-1.17+-purple.svg)](https://elixir-lang.org)
[![OTP](https://img.shields.io/badge/OTP-27+-green.svg)](https://www.erlang.org)
[![Tools](https://img.shields.io/badge/Tools-50-blue.svg)](#50-built-in-tools)
[![Agents](https://img.shields.io/badge/Agents-14_roles-green.svg)](#autonomous-task-orchestration)

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/Miosa-osa/OSA/main/install.sh | bash
osa
```

That's it. The installer auto-detects Elixir/Erlang/Rust and installs anything missing, clones the repo, builds the backend + Rust TUI, and symlinks `osa` to your PATH. First run drops you into an interactive setup wizard (pick a provider, paste a key or pick the local Ollama default, done). Type `osa` from anywhere on disk after that.

```
✓ Backend boots in ~2s
✓ TUI launches with full chat UI
✓ 50 built-in tools loaded (30 always-on, 17 lazy via tool_search, 3 scheduling primitives)
✓ Multi-provider (Anthropic, OpenAI, Ollama, Groq, Google, plus 13 more)
✓ Cross-session memory + learning
✓ Zero data leaves your machine unless you point it at a hosted provider
```

Already cloned? From the repo root:

```bash
bin/install   # detects local checkout, no re-clone
osa           # launch
```

Common entry points:

| Command | What it does |
|---|---|
| `osa` | Backend + TUI (default) |
| `osa setup` | Re-run the setup wizard (switch provider, change key) |
| `osa update` | Pull latest, rebuild |
| `osa serve` | Backend only, no TUI (HTTP API on :9089) |
| `osa doctor` | Health checks |
| `osa --dev` | Dev profile, port 19001 |

Override the port with `OSA_HTTP_PORT=<n>` in `~/.osa/.env` (default 9089).

---

## Overview

OSA is the intelligence layer of [MIOSA](https://miosa.ai) — a local-first, open-source AI agent built on Elixir/OTP. It runs on your machine, owns your data, and connects to any LLM provider you choose.

Every agent framework processes every message the same way. OSA does not. Before any message reaches the reasoning engine, a **Signal Classifier** decodes its intent, domain, and complexity. Simple tasks go to fast, cheap models. Complex multi-step tasks get decomposed into parallel sub-agents with the right models for each step. The agent learns from every session.

The theoretical foundation is [Signal Theory](https://zenodo.org/records/18774174) — a framework for maximizing signal-to-noise ratio in AI communication, grounded in Shannon, Ashby, Beer, and Wiener.

---

## Architecture

### Execution Flow

```
User Input
  │
  ├─ Message Queue (300ms debounce batching)
  │
  ├─ UserPromptSubmit Hook (can modify/block)
  │
  ├─ Budget + Turn Limit Check
  │
  ├─ Prompt Injection Guard (3-tier detection)
  │
  ├─ Context Compaction Pipeline
  │   ├─ Micro-compact (no LLM — truncate old tool results)
  │   ├─ Strip tool args → Merge consecutive → Summarize warm zone
  │   ├─ Structured 8-section compression (iterative, preserves details)
  │   ├─ Context collapse (413 recovery — withhold large results)
  │   └─ Post-compact restore (re-inject files, tasks, workspace)
  │
  ├─ Pre-Directives (explore, delegation, task creation nudges)
  │
  ├─ Genre Routing (low-signal → short-circuit, skip full loop)
  │
  ├─ Context Build (cached static base + dynamic per-request)
  │   ├─ Async memory prefetch (fires parallel while context builds)
  │   ├─ Effort-aware thinking config (low/medium/high/max)
  │   ├─ Agent message injection (inter-agent communication)
  │   └─ Iteration budget tracking
  │
  ├─ LLM Streaming Call
  │   ├─ Streaming tool execution (tools fire MID-STREAM)
  │   ├─ Fallback model chain (auto-switch on rate limit/failure)
  │   └─ Max output token recovery (bump + retry on truncation)
  │
  ├─ Tool Execution
  │   ├─ Concurrency-aware dispatch (parallel safe, sequential unsafe)
  │   ├─ Permission check (tiers + pattern rules + interactive prompt)
  │   ├─ Pre-hooks (security, spend guard, MCP cache)
  │   ├─ Tool result persistence (large → disk with reference)
  │   ├─ Diff generation (unified diff for file operations)
  │   ├─ Post-hooks (cost, telemetry, learning, episodic)
  │   └─ Doom loop detection (halt on repeated failures)
  │
  ├─ Behavioral Nudges (read-before-write, code-in-text, verification)
  │
  ├─ Stop Hooks (can override response or force continuation)
  │
  └─ Post-Response
      ├─ Output guardrail (scrub system prompt leaks)
      ├─ Post-response hooks (transcript, auto-memory, session save)
      ├─ Telemetry recording
      └─ SSE broadcast to all connected clients
```

### System Layers

```
┌─────────────────────────────────────────────────────────────────────┐
│  Channels: Rust TUI │ Desktop (Tauri) │ HTTP/SSE │ Telegram │ ...  │
├─────────────────────────────────────────────────────────────────────┤
│  Signal Classifier: S = (Mode, Genre, Type, Format, Weight)        │
├─────────────────────────────────────────────────────────────────────┤
│  Events.Bus (Goldrush compiled BEAM bytecode dispatch)              │
├──────────┬──────────┬───────────┬──────────┬────────────────────────┤
│  Agent   │ Orchest- │  Swarm    │ Scheduler│  Healing Orchestrator  │
│  Loop    │ rator    │  (4 modes)│ (cron)   │  (self-repair)         │
│  (ReAct) │ (14 roles│           │          │                        │
│          │  bg/fork/│  Teams +  │          │  Speculative Executor  │
│          │  worktree│  NervSys  │          │                        │
├──────────┴──────────┴───────────┴──────────┴────────────────────────┤
│  Context │ Compactor │ Memory  │ Settings │ Hooks   │ Permissions   │
│  Builder │ (6-step)  │ (SQLite │ Cascade  │ (25     │ (pattern      │
│          │           │  +ETS   │ (4-layer)│  events,│  rules,       │
│          │           │  +FTS5) │          │  4 types│  interactive) │
├──────────┴───────────┴─────────┴──────────┴─────────┴───────────────┤
│  7 Providers  │  47 Tools  │  Telemetry  │  Credential Pool  │ Soul│
│  + Fallback   │  (deferred)│  (per-tool) │  (key rotation)   │     │
└───────────────┴────────────┴─────────────┴───────────────────┴─────┘
```

**Runtime:** Elixir 1.17+ / Erlang OTP 27+  |  **HTTP:** Bandit  |  **DB:** SQLite + ETS + persistent_term  |  **Events:** Goldrush  |  **HTTP Client:** Req

---

## Features

### Signal Classification

Every input is classified into a 5-tuple before it reaches the reasoning engine:

```
S = (Mode, Genre, Type, Format, Weight)

Mode    — What to do:       BUILD, EXECUTE, ANALYZE, MAINTAIN, ASSIST
Genre   — Speech act:       DIRECT, INFORM, COMMIT, DECIDE, EXPRESS
Type    — Domain category:  question, request, issue, scheduling, summary
Format  — Container:        message, command, document, notification
Weight  — Complexity:       0.0 (trivial) → 1.0 (critical, multi-step)
```

The classifier is LLM-primary with a deterministic regex fallback. Results are cached in ETS (SHA256 key, 10-minute TTL). This is what makes tier routing possible.

### Multi-Provider LLM Routing

7 providers, 3 tiers, weight-based dispatch:

| Weight Range | Tier | Use Case |
|---|---|---|
| 0.00–0.35 | Utility | Fast, cheap — greetings, lookups, summaries |
| 0.35–0.65 | Specialist | Balanced — code tasks, analysis, writing |
| 0.65–1.00 | Elite | Full reasoning — architecture, orchestration, novel problems |

| Provider | Notes |
|---|---|
| **Ollama Local** | Runs on your machine — fully private, no API cost |
| **Ollama Cloud** | Fast cloud inference, no GPU required |
| **Anthropic** | Claude Opus, Sonnet, Haiku |
| **OpenAI** | GPT-4o, GPT-4o-mini, o-series |
| **OpenRouter** | 200+ models behind a single API key |
| **MIOSA** | Fully managed Optimal agent endpoint |
| **Custom** | Any OpenAI-compatible endpoint |

### Autonomous Task Orchestration

14 specialized agent roles. Explore → Plan → Execute protocol:

```
User: "Build a REST API with auth, tests, and docs"

OSA:
  ├── Explorer agent   — scans codebase (read-only, fast)
  ├── Planner agent    — designs architecture + implementation plan
  ├── Backend agent    — writes API + auth middleware
  ├── Tester agent     — writes test suite
  └── Doc-writer agent — writes documentation
```

Sub-agents share a task list and communicate via ETS-backed mailboxes.

### Multi-Agent Swarm Patterns

```elixir
:parallel     # All agents work simultaneously, results merged
:pipeline     # Each agent's output feeds the next
:debate       # Agents argue positions, consensus emerges
:review_loop  # Build → review → fix → re-review (iteration budget enforced)
```

Swarms use ETS-backed team coordination: shared task lists, per-agent mailboxes, scratchpads, and configurable iteration limits.

### 47 Built-in Tools

| Category | Tools |
|---|---|
| **File** | `file_read`, `file_write`, `file_edit`, `file_glob`, `file_grep`, `dir_list`, `multi_file_edit` |
| **System** | `shell_execute`, `git`, `download`, `repl` (Python/Elixir/Node) |
| **Web** | `web_search`, `web_fetch` |
| **Memory** | `memory_save`, `memory_recall`, `session_search` (FTS5 full-text) |
| **Agent** | `delegate` (background/fork/worktree), `send_message`, `message_agent`, `list_agents`, `team_tasks`, `task_stop`, `task_output` |
| **Skills** | `create_skill`, `list_skills` |
| **Code** | `code_symbols`, `computer_use` (macOS/Linux/Docker/SSH) |
| **Config** | `config`, `cron` (create/list/delete/trigger), `tool_search` |
| **Advanced** | `mixture_of_agents` (multi-LLM ensemble), `verify_loop`, `spawn_conversation`, `peer_review`, `cross_team_query` |
| **Other** | `task_write`, `ask_user`, `create_agent` |

Tools support deferred loading — rarely-used tools excluded from prompt, discoverable via `tool_search`. Large results auto-persisted to disk.

### Identity and Memory

**Soul system:** `IDENTITY.md`, `USER.md`, and `SOUL.md` are loaded at boot and interpolated into every LLM call. The setup wizard collects your name and agent name on first run. The agent knows who it is and who you are from conversation one.

**Memory layers:**

| Layer | Backend | Notes |
|---|---|---|
| Long-term | SQLite + ETS | Relevance scoring: keyword match + signal weight + recency |
| Episodic | ETS | Per-session event tracking, capped at 1000 events |
| Skills | File system | Patterns with occurrence >= 5 auto-generate skill files (SICA) |

**SICA Learning cycle:** See → Introspect → Capture → Adapt. The agent observes what works across sessions and converts recurring patterns into reusable skills automatically.

### Token-Budgeted Context Assembly

```
CRITICAL  (unlimited)  — System identity, active tool schemas
HIGH      (40%)        — Recent conversation turns, current task state
MEDIUM    (30%)        — Relevant memories (keyword-searched from SQLite/ETS)
LOW       (remaining)  — Workflow context, environmental metadata
```

**Three-zone compression:**
- **HOT** — last 10 messages, full fidelity
- **WARM** — older turns, progressively summarized
- **COLD** — oldest content reduced to key facts only

### Computer Use

Control your desktop directly from the agent. Platform adapters for:

| Platform | Method |
|---|---|
| **macOS** | Accessibility API — click, type, screenshot, scroll |
| **Linux X11** | xdotool + xclip — full desktop control |
| **Docker** | Container-isolated desktop interaction |
| **Remote SSH** | Control machines over SSH tunnels |

The agent can take screenshots, click elements, type text, press keys, scroll, and interact with any GUI application.

### Channels

| Channel | Notes |
|---|---|
| **Elixir CLI** | Primary REPL — 25 commands, streaming, task display, diff view, Ctrl+R search, multi-line input |
| **Rust TUI** | Full terminal UI — onboarding wizard, model picker, sessions, command palette |
| **Desktop GUI** | Tauri 2 + SvelteKit 5 — chat, agents, tasks, memory, signals, settings, usage tracking |
| **HTTP/SSE API** | Port 9089, JWT auth, 20+ route modules, real-time SSE streaming |
| **Telegram** | Long-polling, typing indicators, markdown conversion |
| **Discord** | Webhook mode, token validation |
| **Slack** | Webhook + HMAC-SHA256 request verification |

### Hooks System

25 lifecycle events. 4 hook types:

| Type | Description |
|---|---|
| **Function** | Elixir functions — built-in (security, budget, telemetry, learning) |
| **HTTP Webhook** | POST JSON to external URLs on any event |
| **Shell Command** | Run bash commands with payload interpolation |
| **Agent** | Spawn a subagent in response to an event |

Events: `pre_tool_use`, `post_tool_use`, `post_tool_use_failure`, `user_prompt_submit`, `pre_compact`, `post_compact`, `session_start`, `session_end`, `pre_response`, `post_response`, `subagent_start`, `subagent_stop`, `file_changed`, `permission_request`, `stop`, and more.

Configure via `~/.osa/settings.json`:
```json
{
  "hooks": {
    "post_tool_use": [
      {"type": "http", "url": "https://example.com/webhook"},
      {"type": "shell", "command": "echo '{{tool_name}} done' >> /tmp/osa.log"}
    ]
  }
}
```

### Effort Levels

Control thinking depth and iteration budget:

| Level | Thinking | Iterations | Use Case |
|---|---|---|---|
| `/effort low` | 1K tokens | 10 | Quick answers, fast mode |
| `/effort medium` | 5K tokens | 30 | Balanced (default) |
| `/effort high` | 10K tokens | 50 | Deep reasoning |
| `/effort max` | 32K tokens | 100 | Maximum analysis |

### Scheduler

Cron jobs (`CRONS.json`) and event-driven triggers (`TRIGGERS.json`) configured in `~/.osa/`. `HEARTBEAT.md` defines a recurring proactive checklist the agent runs on a schedule.

---

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/Miosa-osa/OSA/main/install.sh | bash
```

The installer auto-detects your OS and architecture. On **macOS arm64**, **Linux amd64**, and **Linux arm64** it downloads the pre-built single binary from GitHub Releases — no Elixir, Erlang, or Rust required. On other platforms it falls back to a source build (installs Elixir/Erlang/Rust automatically).

**Homebrew:** `brew tap miosa-osa/tap && brew install osagent`

**Windows:** Download `osa-windows-amd64.exe` from [GitHub Releases](https://github.com/Miosa-osa/OSA/releases/latest) and add it to your PATH.

**Docker:** `docker compose up -d`

---

## Usage

```bash
osa
```

First run detects your setup and offers:

1. **Quick Start** — auto-detect providers and go
2. **Manual Setup** — choose provider, enter API key or OAuth sign-in, pick model
3. **Skip** — configure later with `/setup` or `~/.osa/.env`

Supported providers: Ollama (local/free), Anthropic (OAuth or API key), OpenAI, Groq, OpenRouter, Together, DeepSeek.

### Subcommands

```
osa              Start (backend + TUI)
osa setup        Re-run setup wizard
osa serve        Headless backend (HTTP API on :9089)
osa update       Pull latest + recompile
osa doctor       Health checks
osa version      Print version
```

### CLI Commands (25)

Type `/help` inside the REPL:

```
/help /clear /compact /model /status /cost /context /memory /tools /skills
/agents /sessions /tasks /plan /doctor /export /version /coordinator /effort
/fast /permissions /hooks /metrics /setup /login /logout /channels /exit
```

### Headless Mode

```bash
mix osa.run "Fix the auth bug"                          # text output
mix osa.run --format json "Explain this code"           # structured JSON
echo "Build an API" | mix osa.run --format stream-json  # streaming NDJSON
```

### Session Resume

```bash
mix osa.chat --resume cli_abc123    # Resume specific session
mix osa.chat --continue             # Resume most recent
```

---

## Configuration

All runtime config lives in `~/.osa/.env`, generated by the setup wizard:

```bash
OSA_DEFAULT_PROVIDER=ollama
OLLAMA_URL=http://localhost:11434
OLLAMA_MODEL=nemotron-3-super
OSA_USER_NAME=Roberto
OSA_AGENT_NAME=OSA
```

**Workspace:** `~/.osa/`

```
~/.osa/
├── .env              # Provider config (generated by wizard)
├── settings.json     # User settings (effort, permissions, hooks)
├── permissions.json  # Tool permission rules (allow/deny with glob patterns)
├── oauth.json        # OAuth credentials (auto-refreshed)
├── IDENTITY.md       # Agent personality
├── USER.md           # User profile
├── SOUL.md           # Agent values
├── agents/           # Custom agent roles (AGENT.md files)
├── skills/           # Custom skills (SKILL.md files, hot-reload)
├── sessions/         # Saved session state (for resume)
├── exports/          # Exported conversations
├── workspace/        # Agent file workspace
├── tool-results/     # Large tool output persistence
├── worktrees/        # Git worktree isolation
├── agent-memory/     # Per-agent persistent memory
└── prompts/          # System prompt overrides
```

**Settings cascade:** user (`~/.osa/settings.json`) < project (`.osa/settings.json`) < local (`.osa/settings.local.json`) < session

### Agent Definitions

Subagents are Markdown files with YAML frontmatter and a prompt body. OSA loads
agent definitions in this precedence order, with later sources overriding
earlier ones:

`priv/agents` < project `.claude/agents` < project `.osa/agents` < `~/.osa/agents`

Both flat files like `.osa/agents/verifier.md` and directory agents like
`~/.osa/agents/verifier/AGENT.md` are supported. Claude-style frontmatter
aliases are accepted, including `tools`, `disallowedTools`, `maxTurns`,
`permissionMode`, `model`, `background`, `isolation`, and `skills`.

---

## Project Structure

```
lib/optimal_system_agent/       # 200+ Elixir modules
  agent/                        # ReAct loop, context, memory, effort, worktree, compactor, hooks
  agent/loop/                   # Core loop: react_loop, tool_executor, streaming_tool_executor,
                                # context_collapse, tool_result_storage, llm_client, guardrails
  channels/cli/                 # CLI: commands (25), permissions, spinner, renderer, line_editor,
                                # message_queue, diff_renderer, agent_tree, task_display
  channels/http/                # HTTP API: 20+ route modules, SSE streaming, auth, rate limiter
  events/                       # Bus (Goldrush compiled BEAM bytecode), PubSub, DLQ
  providers/                    # 7 providers + fallback chain + credential pool
  tools/builtins/               # 47 built-in tools, schema validation, deferred loading
  memory/                       # Store (SQLite + ETS), auto_extract, SICA learning, FTS5 search
  telemetry/                    # Per-tool and per-provider execution metrics
  swarm/                        # Parallel, pipeline, debate, review_loop coordinators
  budget/                       # Token cost tracking, treasury
  signal/                       # Signal classifier, noise filter
  store/                        # Ecto repo, schemas, migrations (SQLite + PostgreSQL)
  supervisors/                  # OTP supervision trees

priv/
  rust/tui/                     # Rust TUI (ratatui + crossterm)
  prompts/                      # System prompt templates
  agents/                       # Agent role definitions
  skills/                       # Built-in skills (hot-loadable)
  swarms/                       # Swarm pattern presets

desktop/                        # Command Center — Tauri 2 + SvelteKit 5
```

---

## Custom Skills

Drop a markdown file anywhere under `~/.osa/skills/`:

```markdown
---
name: data-analyzer
description: Analyze datasets and produce insights
tools:
  - file_read
  - shell_execute
---

## Instructions

When asked to analyze data:
1. Read the file to understand its structure
2. Use shell commands to run analysis
3. Produce a summary with key findings
```

Skills are available immediately — no restart, no recompile. The Skills Registry hot-reloads on file change.

Recurring behavior patterns (occurrence >= 5) are auto-promoted to skills by the SICA engine.

---

## Testing

```bash
mix test                    # Full suite (1730 tests)
mix test test/tools/        # Tool tests only
mix test test/providers/    # Provider tests only
mix test test/signal/       # Signal classification tests
mix test test/swarm/        # Swarm pattern tests
```

---

## What Is In Progress

| Area | Status | Notes |
|---|---|---|
| Events/Signal tests | Aligning | Core rewritten, tests being updated |
| Agent strategy tests | Evaluating | Mixed test failures under review |
| Swarm HTTP routing | Partial | Works via `delegate` tool; HTTP endpoint pending |
| Permission system | Wiring | TUI UI done, backend endpoint pending |
| Sandbox isolation | Planned | Docker/Wasm backends |
| Additional channels | Planned | WhatsApp, Signal, Matrix, Email |
| Vault (structured memory) | Planned | 8-category typed memory with fact extraction |

---

## Theoretical Foundation

OSA is grounded in four principles from information and systems theory:

1. **Shannon (Channel Capacity)** — Every channel has finite capacity. Match compute to complexity. Don't run your best model on trivial tasks.
2. **Ashby (Requisite Variety)** — The system must match the variety of inputs it receives. OSA must handle every signal type, not just the common ones.
3. **Beer (Viable System Model)** — Five operational modes mirror the five subsystems every viable organization needs. Structure enables autonomy.
4. **Wiener (Feedback Loops)** — Every action produces feedback. The agent learns what works and adapts across sessions.

**Research paper:** [Signal Theory: The Architecture of Optimal Intent Encoding](https://zenodo.org/records/18774174) — Luna, MIOSA Research, 2026.

---

## Ecosystem

OSA is the intelligence layer of the MIOSA platform:

| Configuration | What You Get |
|---|---|
| **OSA standalone** | Full AI agent in your terminal, on your hardware |
| **OSA + BusinessOS** | Proactive business assistant with CRM, scheduling, revenue alerts |
| **OSA + Custom Template** | Build your own OS template; OSA provides the intelligence layer |
| **MIOSA Cloud** | Managed instances with enterprise governance |

[miosa.ai](https://miosa.ai) — [GitHub](https://github.com/Miosa-osa/OSA)

---

## Contributing

Skills over code changes. Write a `SKILL.md`, share it with the community. See [CONTRIBUTING.md](CONTRIBUTING.md) for the full process.

## License

Apache 2.0 — See [LICENSE](LICENSE).

---

Built by [Roberto H. Luna](https://github.com/robertohluna) and the [MIOSA](https://miosa.ai) team.
Grounded in [Signal Theory](https://zenodo.org/records/18774174). Powered by the BEAM.

---

## Codebase Visualization

This repository is indexed with [CodeGraphContext](https://github.com/CodeGraphContext/CodeGraphContext) — an interactive code graph that maps functions, modules, call chains, and relationships across the entire codebase.

### Quick Start

```bash
# Install CGC
uv tool install codegraphcontext

# Index this repository
cgc index .

# Launch the interactive visualizer (opens in browser)
cgc visualize
```

This opens an interactive graph at `http://localhost:8000/playground` where you can:

- **Search** for any function, module, or class
- **Trace call chains** — who calls what, and how deep
- **Detect dead code** — unused functions and modules
- **Analyze complexity** — cyclomatic complexity per function
- **Inspect relationships** — imports, inheritance, method calls

### CLI Usage

```bash
# Find callers of a function
cgc analyze callers function_name

# Find dead code
cgc analyze dead-code

# Complexity analysis
cgc analyze complexity

# Raw Cypher query
cgc query "MATCH (f:Function) RETURN f.name LIMIT 20"
```

### Requirements

- Python 3.10+
- [uv](https://docs.astral.sh/uv/) (recommended) or pip
