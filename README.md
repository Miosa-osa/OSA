<div align="center">

<img src="desktop/static/OSAIconLogo.png" alt="OSA" width="128" />

# OSA — the Optimal System Agent

**A fast, reliable, long-running AI coding agent that lives in your terminal.**
One command to install and run. No toolchains. Your machine, your data, any model.

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/Version-1.0.0-blue.svg)](#)
[![Elixir](https://img.shields.io/badge/Elixir-1.17+-purple.svg)](https://elixir-lang.org)
[![OTP](https://img.shields.io/badge/OTP-27+-green.svg)](https://www.erlang.org)
[![Tools](https://img.shields.io/badge/Tools-60-blue.svg)](#built-in-tools)
[![Agents](https://img.shields.io/badge/Agents-14_roles-green.svg)](#autonomous-task-orchestration)

</div>

---

## Install in one command

**macOS / Linux** — paste this into a terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/Miosa-osa/OSA/main/scripts/install.sh | sh
osa
```

**Windows** — paste this into PowerShell:

```powershell
irm https://raw.githubusercontent.com/Miosa-osa/OSA/main/scripts/install.ps1 | iex
osa
```

That's it. **No Elixir, Erlang, or Rust required.** The installer detects your
OS and CPU, downloads the prebuilt release from GitHub (a self-contained
Elixir/OTP release that bundles its own runtime, plus the prebuilt Rust TUI),
verifies its checksum, unpacks everything under `~/.osa` (or `%USERPROFILE%\.osa`),
and puts the `osa` command on your PATH. The first run drops you into a short
setup wizard — pick a provider, paste a key or take the local Ollama default,
done. After that, type `osa` from anywhere on disk.

Prebuilt targets: **linux-x64**, **macOS arm64**, **windows-x64**. Pin a
specific release with `OSA_VERSION=v1.0.0` (`$env:OSA_VERSION = "v1.0.0"` on
Windows).

```
✓ Backend boots in ~2s          ✓ Cross-session memory + learning
✓ Full chat TUI                 ✓ 60 built-in tools, deferred-loaded
✓ 7 providers + fallback        ✓ Nothing leaves your machine unless you say so
```

<details>
<summary><b>Other ways to install</b></summary>

**Homebrew:**

```bash
brew tap miosa-osa/tap
brew install osa
osa doctor
```

The Homebrew package also installs `osagent` and `miosa` command aliases.

**Already cloned the repo?** From the repo root:

```bash
bin/install   # detects the local checkout, no re-clone
osa           # launch
```

**From source (any platform, installs toolchains as needed):**

```bash
curl -fsSL https://raw.githubusercontent.com/Miosa-osa/OSA/main/install.sh | bash          # macOS / Linux
irm https://raw.githubusercontent.com/Miosa-osa/OSA/main/scripts/install-source.ps1 | iex  # Windows
```

**Docker:** `docker compose up -d`

</details>

---

## How it works

OSA is two programs that cooperate on your machine:

- **The engine** — an Elixir/OTP application. This is the brain: the agent
  loop, the tools, the LLM providers, memory, permissions, and persistence.
  Because it runs on the BEAM, thousands of lightweight processes — turns,
  sub-agents, hooks, streams — run concurrently and supervise each other, so one
  failure never takes the whole agent down.
- **The interface** — a Rust TUI built on ratatui. This is what you see and type
  into: the composer, the streaming message view, dialogs, the agent tree.

The two halves talk over a small **HTTP + SSE API bound to `127.0.0.1`** (port
9089 by default). The TUI never reaches the internet directly — it only speaks
to your local engine, and the engine is the only thing that talks to model
providers. Nothing leaves your machine unless a tool you approved makes it
happen.

The single `osa` command ties them together. The first launch starts the engine
as a **warm background daemon** and attaches the TUI to it. That daemon
**outlives the TUI**, so every `osa` after the first attaches instantly — no
cold start. `osa stop` shuts it down.

**The life of a turn:**

```
you type a message
   │  HTTP POST → 127.0.0.1:9089
   ▼
engine classifies the signal, builds context, picks a model tier
   │
   ▼
ReAct loop:  think → call a tool → observe → repeat
   │         every tool clears a permission check first
   │         (ask · auto-edit · plan · overdrive)
   ▼
tokens, tool results, and diffs stream back over SSE — live — into the TUI
```

Everything the agent produces — reasoning, tool calls, file diffs, sub-agent
activity — is streamed as it happens, so the TUI always mirrors the engine's
real state. For the full pipeline (compaction, fallback chains, hooks,
guardrails) see [Architecture](#architecture) below.

---

## What OSA does

`osa` is the one command you run. The first launch warms the backend as a
background daemon and drops you straight into the TUI; that daemon **survives
TUI exit**, so every `osa` after that attaches instantly with no cold start.
Stop it any time with `osa stop`.

### Overdrive and permission modes

By default OSA asks before it touches anything consequential. You choose how
much rope it gets:

| Mode | Behavior |
|---|---|
| **ask** (default) | Approve each edit and command as it comes |
| **auto-edit** | File edits run automatically; commands still prompt |
| **plan** | OSA proposes a plan and waits — no writes until you approve |
| **overdrive (full auto)** | No prompts — OSA runs end to end |

Cycle modes live with **Shift+Tab**, even mid-turn. Launch straight into full
auto with `osa overdrive` (or `--overdrive`). Overdrive shows a red warning and
a one-time confirmation the first time — only use it in a directory you trust.

### Warm single-command startup

The backend runs as a warm daemon that outlives the TUI, so a second `osa`
attaches with no cold start. It idles down when unused, and `osa stop` shuts it
down on demand.

| Command | What it does |
|---|---|
| `osa` | Attach the TUI (warms the backend daemon if needed) |
| `osa overdrive` | Launch in overdrive (full auto) — skips approval prompts |
| `osa continue` | Resume the newest session in this directory |
| `osa resume [id]` | Resume a specific session (or pick one) |
| `osa stop` | Stop the background backend daemon |
| `osa setup` | Re-run the setup wizard (switch provider, change key) |
| `osa update` | Update in place, show what's new, then relaunch |
| `osa doctor` | Health checks |
| `osa serve` | Backend only, no TUI (HTTP API on :9089) |
| `osa version` | Print version |
| `osa help` | Full command + flag reference |

`osa update` downloads the latest prebuilt release + TUI, verifies its checksum,
swaps them in atomically under `~/.osa`, prints the version delta and release
notes, and relaunches. `osa doctor` runs real health checks — provider
reachability, port binding, config sanity, workspace layout. `osa help` prints
the complete command and flag reference.

### Slash commands

Type `/` in the TUI for the full palette. The command set:

```
/help      /clear     /compact   /model     /status    /cost      /context
/memory    /tools     /skills    /agents    /sessions  /tasks     /plan
/doctor    /export    /version   /coordinator          /effort    /fast
/permissions          /hooks     /metrics   /setup     /login     /logout
/channels  /exit
```

### Keyboard

| Key | Action |
|---|---|
| **Enter** | Send message |
| **Shift+Tab** | Cycle permission mode (ask → auto-edit → overdrive …) |
| **Esc** | Clear the composer |
| **Esc Esc** | Rewind — jump back to edit a previous message |
| **Ctrl+C** | Cancel the running turn (quit when the composer is empty) |
| **Ctrl+D** | Exit |
| **Ctrl+N** | New session |
| **Ctrl+R** | Expand the last tool result inline (reverse-search with text) |
| **Ctrl+K** | Command palette (kill-to-end-of-line with text) |
| **Ctrl+O** | Toggle the agent tree / expand the last tool |
| **Ctrl+L** | Toggle the sidebar |
| **Ctrl+V** | Paste — images become `[Image #N]`, file paths attach |
| **`/`** | Slash-command completions |
| **`!`** | Shell mode — run the line as a shell command |
| **`@`** | Mention a file or directory (fuzzy picker) |
| **`?`** / **F1** | Help |

### `!` shell and `@` file mentions

Prefix a line with **`!`** to run it as a shell command without leaving the
chat — `!git status`, `!ls`, `!cargo test`. Type **`@`** to fuzzy-pick a file or
directory; the path is inserted inline and its contents are pulled into context
so you can say "explain `@lib/agent/loop.ex`" and OSA already has it.

### MCP (Model Context Protocol)

OSA is both an MCP **client** and an MCP **server**. Point it at any MCP server
and its tools show up alongside the built-ins, discoverable and callable in the
same loop. Expose OSA's own tools to other MCP-aware apps by running it as a
server. Full JSON-RPC protocol, multiple transports, tool discovery, and result
caching are built in.

### Sandboxes

Code execution routes through a pluggable sandbox layer. Backends:

| Backend | Notes |
|---|---|
| **MIOSA** | Recommended managed sandbox — auto-selected when configured |
| **E2B** | Cloud microVM isolation (`E2B_API_KEY`) |
| **Vercel** | Ephemeral cloud execution (`VERCEL_TOKEN`) |
| **Docker** | Local container isolation |
| **Host** | Direct execution — the fallback when no sandbox is configured |

In *required* mode, host execution is blocked unless a real sandbox is
available, so untrusted code never touches your machine. A dangerous-command
guard screens every shell invocation regardless of backend.

### Background agents and steer

`delegate` spawns sub-agents that run in the background, in a fork, or in an
isolated git worktree — in parallel, each with the right model for its step.
They share a task list and talk over ETS-backed mailboxes. Watch them live in
the agent tree, and **steer** a running agent mid-turn: send a new directive
into an in-flight turn and it adapts without being cancelled and restarted.
Stop or interrupt any agent from the same view.

---

## Quickstart

```bash
osa
```

First run detects your setup and offers:

1. **Quick Start** — auto-detect providers and go
2. **Manual Setup** — choose a provider, enter an API key or OAuth sign-in, pick a model
3. **Skip** — configure later with `/setup` or by editing `~/.osa/.env`

Then just talk to it:

```
› build a REST API with auth, write tests, and document it
› !git checkout -b feature/api
› explain @lib/agent/loop.ex
› /plan refactor the memory layer
```

**Headless / scripting:**

```bash
mix osa.run "Fix the auth bug"                          # text output
mix osa.run --format json "Explain this code"           # structured JSON
echo "Build an API" | mix osa.run --format stream-json  # streaming NDJSON
```

**Resume a session:**

```bash
osa continue              # newest session in this directory
osa resume cli_abc123     # a specific session
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
OSA_HTTP_PORT=9089
```

**Workspace** — everything OSA keeps lives under `~/.osa/`:

```
~/.osa/
├── .env              # Provider config (generated by the wizard)
├── settings.json     # User settings (effort, permissions, hooks)
├── permissions.json  # Tool permission rules (allow/deny with glob patterns)
├── oauth.json        # OAuth credentials (auto-refreshed)
├── version           # Installed release, used by `osa update`
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

**Settings cascade:** user (`~/.osa/settings.json`) < project (`.osa/settings.json`) < local (`.osa/settings.local.json`) < session.

Override the HTTP port with `OSA_HTTP_PORT=<n>` in `~/.osa/.env` (default 9089).

---

## Overview

OSA is the intelligence layer of [MIOSA](https://miosa.ai) — a local-first,
open-source AI agent built on Elixir/OTP. It runs on your machine, owns your
data, and connects to any LLM provider you choose.

Every agent framework processes every message the same way. OSA does not. Before
any message reaches the reasoning engine, a **Signal Classifier** decodes its
intent, domain, and complexity. Simple tasks go to fast, cheap models. Complex
multi-step tasks get decomposed into parallel sub-agents with the right model
for each step. The agent learns from every session.

The theoretical foundation is [Signal Theory](https://zenodo.org/records/18774174) —
a framework for maximizing signal-to-noise ratio in AI communication, grounded
in Shannon, Ashby, Beer, and Wiener.

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
│  7 Providers  │  60 Tools  │  Telemetry  │  Credential Pool  │ Soul│
│  + Fallback   │  (deferred)│  (per-tool) │  (key rotation)   │     │
└───────────────┴────────────┴─────────────┴───────────────────┴─────┘
```

**Runtime:** Elixir 1.17+ / Erlang OTP 27+  |  **HTTP:** Bandit  |  **DB:** SQLite + ETS + persistent_term  |  **Events:** Goldrush  |  **HTTP Client:** Req

---

## Features in depth

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

The classifier is LLM-primary with a deterministic regex fallback. Results are
cached in ETS (SHA256 key, 10-minute TTL). This is what makes tier routing
possible.

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

When a call rate-limits or fails, OSA walks a configurable fallback chain and
reconnects mid-stream — the turn keeps going.

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

Sub-agents share a task list and communicate via ETS-backed mailboxes. Run them
in the background, in a fork, or in an isolated git worktree, and steer any of
them mid-turn.

### Multi-Agent Swarm Patterns

```elixir
:parallel     # All agents work simultaneously, results merged
:pipeline     # Each agent's output feeds the next
:debate       # Agents argue positions, consensus emerges
:review_loop  # Build → review → fix → re-review (iteration budget enforced)
```

Swarms use ETS-backed team coordination: shared task lists, per-agent mailboxes,
scratchpads, and configurable iteration limits.

### Built-in Tools

60 tools, all schema-validated, most deferred-loaded (excluded from the prompt
until needed, discoverable via `tool_search`):

| Category | Tools |
|---|---|
| **File** | `file_read`, `file_write`, `file_edit`, `multi_file_edit`, `file_glob`, `file_grep`, `dir_list`, `notebook_edit` |
| **System** | `shell_execute`, `git`, `github`, `download`, `repl` (Python/Elixir/Node), `code_sandbox`, `bash_output` |
| **Web** | `web_search`, `web_fetch`, `browser` |
| **Code** | `code_symbols`, `codebase_explore`, `semantic_search`, `computer_use` (macOS/Linux/Docker/SSH) |
| **Memory** | `memory_save`, `memory_recall`, `session_search`, `knowledge` |
| **Vault** | `vault_remember`, `vault_context`, `vault_inject`, `vault_checkpoint`, `vault_sleep`, `vault_wake` |
| **Agents** | `delegate`, `orchestrate`, `create_agent`, `list_agents`, `send_message`, `message_agent`, `team_tasks`, `task_write`, `task_output`, `task_stop` |
| **Multi-agent** | `mixture_of_agents`, `peer_review`, `peer_negotiate_task`, `peer_claim_region`, `cross_team_query` |
| **Skills** | `create_skill`, `save_skill`, `use_skill`, `find_skill`, `list_skills`, `skill_manager` |
| **Config / meta** | `config`, `cron`, `tool_search`, `budget_status`, `wallet_ops`, `ask_user` |

Large tool results are auto-persisted to disk and referenced by handle, so a
big grep never blows the context window.

### Identity and Memory

**Soul system:** `IDENTITY.md`, `USER.md`, and `SOUL.md` are loaded at boot and
interpolated into every LLM call. The setup wizard collects your name and the
agent's name on first run. OSA knows who it is and who you are from conversation
one.

**Memory layers:**

| Layer | Backend | Notes |
|---|---|---|
| Long-term | SQLite + ETS | Relevance scoring: keyword match + signal weight + recency |
| Episodic | ETS | Per-session event tracking, capped at 1000 events |
| Vault | SQLite | Structured, typed memory with fact extraction and injection |
| Skills | File system | Patterns with occurrence ≥ 5 auto-generate skill files (SICA) |

**SICA learning cycle:** See → Introspect → Capture → Adapt. OSA observes what
works across sessions and converts recurring patterns into reusable skills
automatically.

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

Control your desktop directly from the agent. Platform adapters:

| Platform | Method |
|---|---|
| **macOS** | Accessibility API — click, type, screenshot, scroll |
| **Linux X11** | xdotool + xclip — full desktop control |
| **Docker** | Container-isolated desktop interaction |
| **Remote SSH** | Control machines over SSH tunnels |

OSA can take screenshots, click elements, type text, press keys, scroll, and
interact with any GUI application.

### Channels

| Channel | Notes |
|---|---|
| **Rust TUI** | Primary terminal UI — onboarding wizard, model picker, sessions, command palette, agent tree, `!` shell, `@` mentions |
| **Elixir CLI** | REPL — streaming, task display, diff view, Ctrl+R search, multi-line input |
| **Desktop GUI** | Tauri 2 + SvelteKit 5 — chat, agents, tasks, memory, signals, settings, usage tracking |
| **HTTP/SSE API** | Port 9089, JWT auth, 20+ route modules, real-time SSE streaming |
| **Telegram** | Long-polling, typing indicators, markdown conversion |
| **Discord** | Webhook mode, token validation |
| **Slack** | Webhook + HMAC-SHA256 request verification |

### Hooks System

25 lifecycle events, 4 hook types:

| Type | Description |
|---|---|
| **Function** | Elixir functions — built-in (security, budget, telemetry, learning) |
| **HTTP Webhook** | POST JSON to external URLs on any event |
| **Shell Command** | Run commands with payload interpolation |
| **Agent** | Spawn a subagent in response to an event |

Events: `pre_tool_use`, `post_tool_use`, `post_tool_use_failure`,
`user_prompt_submit`, `pre_compact`, `post_compact`, `session_start`,
`session_end`, `pre_response`, `post_response`, `subagent_start`,
`subagent_stop`, `file_changed`, `permission_request`, `stop`, and more.

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

Control thinking depth and iteration budget with `/effort`:

| Level | Thinking | Iterations | Use Case |
|---|---|---|---|
| `low` | 1K tokens | 10 | Quick answers, fast mode |
| `medium` | 5K tokens | 30 | Balanced (default) |
| `high` | 10K tokens | 50 | Deep reasoning |
| `max` | 32K tokens | 100 | Maximum analysis |

### Scheduler

Cron jobs (`CRONS.json`) and event-driven triggers (`TRIGGERS.json`) live in
`~/.osa/`. `HEARTBEAT.md` defines a recurring proactive checklist OSA runs on a
schedule — the "proactive" in proactive agent.

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

Skills are available immediately — no restart, no recompile. The Skills Registry
hot-reloads on file change. Recurring behavior patterns (occurrence ≥ 5) are
auto-promoted to skills by the SICA engine.

---

## Project layout

A map of the repository for anyone wanting to read or contribute. The two halves
from [How it works](#how-it-works) are `lib/` (the Elixir engine) and
`priv/rust/tui/` (the Rust interface).

```
OSA/
├── bin/                              # osa launcher, local installer, version-bump
├── config/                          # Elixir build + runtime config (dev / prod / test / runtime.exs)
├── scripts/                         # install / update / TUI-launch scripts (sh + ps1)
│
├── lib/optimal_system_agent/        # THE ENGINE — 200+ Elixir modules
│   ├── agent/                       #   the brain: turn orchestration + agent state
│   │   ├── loop/                    #     the ReAct turn loop, tool executor, steer/cancel,
│   │   │                            #     guardrails, genre routing, doom-loop detection
│   │   ├── safety/                  #     dangerous-command guard, prompt-injection detection, verdicts
│   │   ├── hooks/                   #     lifecycle hook dispatch (25 events)
│   │   ├── orchestrator/            #     multi-agent orchestration
│   │   ├── scheduler/               #     cron jobs + proactive triggers
│   │   ├── tasks/                   #     shared task lists across agents
│   │   ├── memory/                  #     per-agent working memory
│   │   └── compactor.ex, effort.ex, worktree.ex, plan_mode.ex …
│   ├── channels/                    #   how you reach OSA
│   │   ├── http/                    #     the local HTTP/SSE API the TUI talks to (auth, rate limiter)
│   │   ├── cli/                     #     in-terminal rendering: commands, diffs, agent tree, line editor
│   │   └── telegram.ex, slack.ex, discord.ex, whatsapp.ex, matrix.ex …  # optional messaging channels
│   ├── providers/                   #   LLM providers (Ollama, Anthropic, OpenAI…) + fallback chain,
│   │                                #   credential pool, health checks, resilience
│   ├── tools/builtins/              #   the 60 built-in tools: file, shell, search, web, delegate…
│   ├── signal/                      #   signal classifier — routes each message by intent + complexity
│   ├── memory/                      #   long-term memory, learning, skill generation (SICA / VIGIL)
│   ├── store/                       #   Ecto schemas + repo (SQLite): sessions, messages, patterns, skills
│   ├── mcp/                         #   Model Context Protocol client + server (protocol, transports)
│   ├── sandbox/                     #   pluggable code-execution backends (host / docker / e2b / vercel / miosa)
│   ├── open_computers/              #   computer-use: desktop-control adapters + session runtime
│   ├── swarm/                       #   multi-agent patterns (parallel / pipeline / debate / review-loop)
│   ├── events/                      #   event bus (Goldrush), pub/sub, dead-letter queue
│   ├── runtime/                     #   session manager
│   ├── supervisors/                 #   OTP supervision trees
│   ├── telemetry/                   #   per-tool and per-provider metrics
│   └── soul/ · budget/ · skills/    #   agent identity, cost tracking, skill registry
│
├── priv/
│   ├── rust/tui/src/                # THE INTERFACE — terminal UI (Rust + ratatui)
│   │   ├── app/                     #   event loop, key handling, actions, layout
│   │   ├── client/                  #   HTTP + SSE client that talks to the engine
│   │   ├── components/              #   composer, message list, sidebar, agent tree
│   │   ├── dialogs/                 #   onboarding wizard, model picker, permission prompts
│   │   ├── config/                  #   TUI config + keybindings
│   │   ├── render/ · view/          #   frame rendering
│   │   └── style/                   #   OSA theme + palette
│   ├── prompts/                     # system prompt templates
│   ├── agents/                      # built-in agent role definitions
│   └── skills/                      # built-in skills (hot-loadable)
│
├── desktop/                         # optional Command Center — Tauri 2 + SvelteKit GUI
├── test/                            # ExUnit test suite
├── docs/                            # additional documentation
└── .github/workflows/               # release automation
```

---

## Testing

```bash
mix test                    # Full suite
mix test test/tools/        # Tool tests only
mix test test/providers/    # Provider tests only
mix test test/signal/       # Signal classification tests
mix test test/swarm/        # Swarm pattern tests
```

---

## Theoretical Foundation

OSA is grounded in four principles from information and systems theory:

1. **Shannon (Channel Capacity)** — Every channel has finite capacity. Match compute to complexity. Don't run your best model on trivial tasks.
2. **Ashby (Requisite Variety)** — The system must match the variety of inputs it receives. OSA handles every signal type, not just the common ones.
3. **Beer (Viable System Model)** — Five operational modes mirror the five subsystems every viable organization needs. Structure enables autonomy.
4. **Wiener (Feedback Loops)** — Every action produces feedback. OSA learns what works and adapts across sessions.

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

### Memory: native, plus Optimal Engine

OSA ships with its **own native memory** — built in, on by default, and fully
standalone. It works with no external services: long-term recall, episodic
tracking, the vault, and skill learning all run locally out of the box. Nothing
extra is required to get persistent, cross-session memory.

**Optimal Engine** is a knowledge-base / "second brain" product in the ecosystem
— a richer external memory and knowledge/data-store layer you can plug in. It's
**available today** and ships its **own CLI**: set it up, then tell OSA about it,
and OSA can leverage Optimal Engine as an external memory/knowledge layer
alongside its native memory. Native memory works standalone; Optimal Engine is
the optional, recommended layer when you want a deeper, shared knowledge base.

[miosa.ai](https://miosa.ai) — [GitHub](https://github.com/Miosa-osa/OSA)

---

## Contributing

Skills over code changes. Write a `SKILL.md`, share it with the community. See
[CONTRIBUTING.md](CONTRIBUTING.md) for the full process.

## License

Apache 2.0 — See [LICENSE](LICENSE).

---

<div align="center">

Built by [Roberto H. Luna](https://github.com/robertohluna) and the [MIOSA](https://miosa.ai) team.
Grounded in [Signal Theory](https://zenodo.org/records/18774174). Powered by the BEAM.

</div>
