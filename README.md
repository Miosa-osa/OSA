# OSA — the Optimal System Agent

> Signal Theory-optimized proactive AI agent. Local-first. Open source. BEAM-powered.

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/Version-0.3.0-orange.svg)](#)
[![Elixir](https://img.shields.io/badge/Elixir-1.17+-purple.svg)](https://elixir-lang.org)
[![OTP](https://img.shields.io/badge/OTP-27+-green.svg)](https://www.erlang.org)
[![Tests](https://img.shields.io/badge/Tests-1730-brightgreen.svg)](#testing)

---

## Overview

OSA is the intelligence layer of [MIOSA](https://miosa.ai) — a local-first, open-source AI agent built on Elixir/OTP. It runs on your machine, owns your data, and connects to any LLM provider you choose.

Every agent framework processes every message the same way. OSA does not. Before any message reaches the reasoning engine, a **Signal Classifier** decodes its intent, domain, and complexity. Simple tasks go to fast, cheap models. Complex multi-step tasks get decomposed into parallel sub-agents with the right models for each step. The agent learns from every session.

The theoretical foundation is [Signal Theory](https://zenodo.org/records/18774174) — a framework for maximizing signal-to-noise ratio in AI communication, grounded in Shannon, Ashby, Beer, and Wiener.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                          Channels                             │
│   Rust TUI │ Desktop GUI │ HTTP/REST │ Telegram │ Discord │ Slack │
└───────────────────────────┬──────────────────────────────────┘
                            │
┌───────────────────────────▼──────────────────────────────────┐
│              Signal Classifier  (LLM-primary)                 │
│         S = (Mode, Genre, Type, Format, Weight)               │
│         ETS cache (SHA256, 10-min TTL) │ Deterministic fallback│
└───────────────────────────┬──────────────────────────────────┘
                            │
┌───────────────────────────▼──────────────────────────────────┐
│              Two-Tier Noise Filter                            │
│       Tier 1: <1ms regex │ Tier 2: weight thresholds         │
└───────────────────────────┬──────────────────────────────────┘
                            │
┌───────────────────────────▼──────────────────────────────────┐
│         Events.Bus  (Goldrush compiled BEAM bytecode)         │
│         PubSub fan-out │ DLQ │ Circuit breakers              │
└──┬─────────────┬──────────────┬──────────────┬───────────────┘
   │             │              │              │
┌──▼────┐  ┌────▼──────┐  ┌───▼────┐  ┌──────▼──────┐
│ Agent │  │Orchestrat-│  │ Swarm  │  │  Scheduler  │
│ Loop  │  │   or      │  │        │  │  Cron +     │
│       │  │           │  │4 modes │  │  Heartbeat  │
│ ReAct │  │ Sub-agents│  │        │  │             │
│ cycle │  │ (parallel)│  │ Teams  │  │             │
└──┬────┘  └────┬──────┘  └───┬────┘  └─────────────┘
   │            │             │
┌──▼────────────▼─────────────▼────────────────────────────────┐
│                   Shared Infrastructure                        │
│  Context Builder (token-budgeted, 4-tier priority)            │
│  Compactor (3-zone: HOT / WARM / COLD)                        │
│  Memory (SQLite + ETS + episodic)                             │
│  Skills Registry (hot-reload, no restart)                     │
│  Budget Tracker (per-provider token costs)                    │
│  Soul System (IDENTITY.md + USER.md + SOUL.md interpolation)  │
└────────────┬───────────────┬──────────────┬───────────────────┘
             │               │              │
      ┌──────▼──────┐ ┌──────▼──────┐ ┌────▼────────┐
      │ 7 LLM       │ │ 25 Built-in │ │ OS Templates│
      │ Providers   │ │ Tools       │ │ (priv/)     │
      └─────────────┘ └─────────────┘ └─────────────┘
```

**Runtime:** Elixir 1.17+ / Erlang OTP 27+
**HTTP server:** Bandit 1.6
**Databases:** SQLite (local memory) + PostgreSQL (platform)
**Event routing:** Goldrush (compiled BEAM bytecode rules)
**HTTP client:** Req 0.5

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

Complex tasks are decomposed into parallel sub-agents, each with its own ReAct loop:

```
User: "Build a REST API with auth, tests, and docs"

Orchestrator:
  ├── Research agent  — analyzes existing codebase
  ├── Builder agent   — writes implementation
  ├── Tester agent    — writes test suite
  └── Writer agent    — writes documentation
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

### 25 Built-in Tools

| Category | Tools |
|---|---|
| **File** | `file_read`, `file_write`, `file_edit`, `file_glob`, `file_grep`, `dir_list`, `multi_file_edit` |
| **System** | `shell_execute`, `git`, `download` |
| **Web** | `web_search`, `web_fetch` |
| **Memory** | `memory_save`, `memory_recall`, `session_search` |
| **Agent** | `delegate`, `message_agent`, `list_agents`, `team_tasks` |
| **Skills** | `create_skill`, `list_skills` |
| **Code** | `code_symbols`, `computer_use` |
| **Other** | `task_write`, `ask_user` |

All tools are schema-validated at registration time via the Tools Registry.

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

### Channels

| Channel | Notes |
|---|---|
| **Rust TUI** | Primary interface. Full terminal UI — onboarding wizard, model picker, sessions, command palette. Built with ratatui + crossterm. |
| **Desktop GUI** | Tauri 2 + SvelteKit 5 native app (`desktop/`). Command Center. |
| **HTTP/REST** | Port 8089, SSE streaming, JWT auth. |
| **Telegram** | Long-polling, typing indicators, markdown conversion. |
| **Discord** | Webhook mode, token validation. |
| **Slack** | Webhook + HMAC-SHA256 request verification. |

### Scheduler

Cron jobs (`CRONS.json`) and event-driven triggers (`TRIGGERS.json`) configured in `~/.osa/`. `HEARTBEAT.md` defines a recurring proactive checklist the agent runs on a schedule.

---

## Installation

One command. Handles Elixir, Erlang, and Rust if they are not already installed.

```bash
curl -fsSL https://raw.githubusercontent.com/Miosa-osa/OSA/main/install.sh | bash
```

The installer clones the repo, compiles the Elixir backend, builds the Rust TUI, and symlinks `osa` to your PATH.

### Docker

```bash
docker compose up -d
```

---

## Usage

```bash
osa              # Start backend + Rust TUI (primary)
osa serve        # Headless backend only — HTTP API on :8089
osa setup        # Re-run the setup wizard
osa update       # Pull latest, recompile, rebuild TUI
osa doctor       # Run health checks
osa version      # Print version
```

**First run:** The TUI launches a 7-step setup wizard. Pick your LLM provider, enter API keys, set your name and agent name. Config saves to `~/.osa/.env` and never asks again.

When you quit the TUI, the backend shuts down automatically.

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

**Workspace directory:** `~/.osa/`

```
~/.osa/
├── .env             # Provider config (generated by wizard)
├── IDENTITY.md      # Agent personality and role
├── USER.md          # User profile (name, preferences, context)
├── SOUL.md          # Agent values and operating principles
├── HEARTBEAT.md     # Proactive scheduled checklist
├── BOOTSTRAP.md     # First-conversation script (auto-deleted after use)
├── skills/          # Custom skill definitions
├── CRONS.json       # Scheduled cron jobs
└── TRIGGERS.json    # Event-driven trigger definitions
```

---

## Project Structure

```
lib/optimal_system_agent/       # 90+ Elixir modules
  agent/                        # ReAct loop, context builder, memory, strategies, guardrails
  channels/                     # CLI, HTTP API, Telegram, Discord, Slack handlers
  events/                       # Bus (Goldrush), PubSub bridge, DLQ, circuit breakers
  providers/                    # Ollama, Anthropic, OpenAI-compat adapters, router
  tools/                        # 25 built-in tools, registry, schema validation
  memory/                       # Store (SQLite + ETS), SICA pattern engine, skill generator
  swarm/                        # Parallel, pipeline, debate, review_loop coordinators
  budget/                       # Per-provider token cost tracking
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
