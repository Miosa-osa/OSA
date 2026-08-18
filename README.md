<div align="center">

<img src="assets/OSAIconLogo.png" alt="OSA" width="128" />

# OSA: the Optimal System Agent

**OSA finds the signal in your work.** Built on Signal Theory, it classifies
what you ask, filters the noise, and routes the work to the right model,
proactively, and on your machine.

Across your code, your ops, and the everyday busywork, OSA separates what matters
from the noise and does the work that counts. One command to install. Runs
locally. Works with any model.

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/Version-v1.0.118-blue.svg)](#)
[![Elixir](https://img.shields.io/badge/Elixir-1.17+-purple.svg)](https://elixir-lang.org)
[![OTP](https://img.shields.io/badge/OTP-27+-green.svg)](https://www.erlang.org)
[![Tools](https://img.shields.io/badge/Tools-82-blue.svg)](#built-in-tools)
[![Agents](https://img.shields.io/badge/Agents-18_roles-green.svg)](#autonomous-task-orchestration)

</div>

---

## Install in one command

**macOS / Linux**, paste this into a terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/Miosa-osa/OSA/main/scripts/install.sh | sh
osa
```

**Windows**, paste this into PowerShell:

```powershell
irm https://raw.githubusercontent.com/Miosa-osa/OSA/main/scripts/install.ps1 | iex
osa
```

That's it. **No Elixir, Erlang, or Rust required.** The installer detects your
OS and CPU, downloads the prebuilt release from GitHub (a self-contained
Elixir/OTP release that bundles its own runtime, plus the prebuilt Rust TUI),
verifies its checksum, unpacks everything under `~/.osa` (or `%USERPROFILE%\.osa`),
and puts the `osa` command on your PATH. The first run drops you into a short
setup wizard: pick a provider, paste a key or take the local Ollama default,
done. After that, type `osa` from anywhere on disk.

Prebuilt targets: **linux-x64**, **macOS arm64**, **windows-x64**. Pin a
specific release with `OSA_VERSION=v1.0.118` (`$env:OSA_VERSION = "v1.0.118"` on
Windows). On any other platform (macOS Intel, Linux arm64) the installer stops
and points you at the from-source script below.

```
✓ Warm background backend       ✓ Cross-session memory + learning
✓ Full chat TUI                 ✓ 82 built-in tools, deferred-loaded
✓ 27 providers + fallback       ✓ Nothing leaves your machine unless you say so
✓ Proactive skill discovery     ✓ Durable goals, queues, and recovery
```

<details>
<summary><b>Other ways to install</b></summary>

**Already cloned the repo?** From the repo root:

```bash
bin/install   # detects the local checkout, no re-clone
osa           # launch
```

**From source (any platform, installs toolchains as needed):**

```bash
curl -fsSL https://raw.githubusercontent.com/Miosa-osa/OSA/main/scripts/install-source.sh | bash  # macOS / Linux
irm https://raw.githubusercontent.com/Miosa-osa/OSA/main/scripts/install-source.ps1 | iex  # Windows
```

**Docker:** `docker compose up -d`

</details>

---

## New to OSA? Start here

New here? The [Getting Started guide](docs/GETTING_STARTED.md) takes you from install
to your first real task in a few minutes, with no prior setup knowledge needed.

**Recommended setup (the easy path):** on first run, the wizard asks which provider
to use. Pick **Ollama Cloud (recommended)** and the model **`glm-5.2:cloud`**. It
needs no GPU and no large downloads (Ollama offloads the heavy work to its cloud),
and it gives you a 1,000,000 token context window. Install Ollama from
[ollama.com](https://ollama.com), sign in (via the Ollama desktop app or
`ollama signin`, which lets your local Ollama proxy cloud models so OSA needs no
extra key) or paste a key from [ollama.com/account/keys](https://ollama.com/account/keys),
then choose that provider and model in the wizard. Prefer a different provider
(OpenRouter, Anthropic, fully local Ollama, and more)? The
[Getting Started guide](docs/GETTING_STARTED.md) covers every option.

---

## How it works

OSA is two programs that cooperate on your machine:

- **The engine**: an Elixir/OTP application. This is the brain: the agent
  loop, the tools, the LLM providers, memory, permissions, and persistence.
  Because it runs on the BEAM, thousands of lightweight processes (turns,
  sub-agents, hooks, streams) run concurrently and supervise each other, so one
  failure never takes the whole agent down.
- **The interface**: a Rust TUI built on ratatui. This is what you see and type
  into: the composer, the streaming message view, dialogs, the agent tree.

The two halves talk over a small **HTTP + SSE API bound to `127.0.0.1`** (port
9089 by default). The TUI never reaches the internet directly, it only speaks
to your local engine, and the engine is the only thing that talks to model
providers. Nothing leaves your machine unless a tool you approved makes it
happen.

The single `osa` command ties them together. The first launch starts the engine
as a **warm background daemon** and attaches the TUI to it. That daemon
**outlives the TUI**, so every `osa` after the first attaches instantly, no
cold start. It idles down when unused, and the launcher notices on its own when
a running daemon is older than what is installed on disk and restarts it for
you.

**The life of a turn:**

```
you type a message
   │  HTTP POST → 127.0.0.1:9089
   ▼
engine classifies the signal, ranks relevant skills, builds context, picks a model tier
   │
   ▼
ReAct loop:  think → call a tool → observe → repeat
   │         every tool clears a permission check first
   │         (ask · auto-edit · plan · overdrive)
   ▼
tokens, tool results, and diffs stream back over SSE (live) into the TUI
```

Everything the agent produces (reasoning, tool calls, file diffs, sub-agent
activity) is streamed as it happens, so the TUI always mirrors the engine's
real state. Skill use, goal state, tool stalls, context occupancy, normalized
reasoning state, and reconnect health remain visible without widening the
terminal. For the full pipeline (compaction, fallback chains, hooks,
guardrails) see [Architecture](#architecture) below.

---

## What OSA does

`osa` is the one command you run. The first launch warms the backend as a
background daemon and drops you straight into the TUI; that daemon **survives
TUI exit**, so every `osa` after that attaches instantly with no cold start.

### Overdrive and permission modes

By default OSA asks before it touches anything consequential. You choose how
much rope it gets:

| Mode | Behavior |
|---|---|
| **ask** (default) | Approve each edit and command as it comes |
| **auto-edit** | File edits run automatically; commands still prompt |
| **plan** | OSA proposes a plan and waits, no writes until you approve |
| **overdrive (full auto)** | No prompts, OSA runs end to end |
| **auto** | Safety-guardian mode: OSA classifies each call and only stops for the risky ones. Set with `/auto`, not in the Shift+Tab cycle |

**Shift+Tab** cycles ask → auto-edit → plan → overdrive, even mid-turn. Seed the
mode at launch with `--permission-mode <mode>`, or go straight to full auto with
`osa overdrive` (`--overdrive`, `--yolo`). Overdrive shows a red warning and a
one-time confirmation the first time; only use it in a directory you trust.

### Workspace trust

A directory you have never used OSA in is **untrusted**, and an untrusted
project's config is withheld rather than obeyed: `.osa/settings.json` (and the
project hooks, permission rules, and MCP settings it carries) is ignored until
you accept trust for that directory, so cloning a hostile repo cannot hand
itself permissions by shipping a settings file. OSA logs which file it withheld
instead of silently dropping it. Run **`/trust`** to see the directory's status
and the specific risks its config would introduce, and `/trust accept` to accept.
Trust is remembered per directory in `~/.osa/trusted_workspaces.json` and is
inherited by subdirectories; your home directory and `/` are only ever trusted
for the current session, never persisted.

### Warm single-command startup

The backend runs as a warm daemon that outlives the TUI, so a second `osa`
attaches with no cold start, and it idles down when unused. You are never asked
to restart it by hand: on every launch the launcher compares the running
daemon's version against what is installed and stops a stale one first, so a
freshly updated OSA is what actually serves your next turn. (If that daemon is
busy — another TUI is attached — OSA asks before restarting rather than yanking
it out from under you.)

| Command | What it does |
|---|---|
| `osa` | Attach the TUI (warms the backend daemon if needed) |
| `osa overdrive` | Launch in overdrive (full auto), skips approval prompts |
| `osa continue` | Resume the newest session in this directory |
| `osa resume [id]` | Resume a specific session (or pick one) |
| `osa setup` | Re-run the setup wizard (switch provider, change key) |
| `osa update` | Update in place, show what's new, then relaunch |
| `osa doctor` | Health checks |
| `osa serve` | Backend only, no TUI (HTTP API on :9089) |
| `osa version` | Print version (backend, TUI, and the installed release stamp) |
| `osa stop` | Stop the background backend daemon (rarely needed) |
| `osa help` | Full command + flag reference |

**Launch flags** (`osa --help` prints the authoritative list; an unrecognised
flag is now a hard error with usage, never silently ignored):

| Flag | What it does |
|---|---|
| `--model <name>`, `-m` | Run **this session** on `<name>`, overriding the saved default |
| `--provider <name>` | Provider for `--model` (inferred from the model when omitted) |
| `--permission-mode <mode>` | Seed the mode: `ask` · `auto-edit` · `plan` · `auto` · `overdrive` |
| `-c`, `--continue` | Resume this folder's newest session |
| `--resume [id]` | Resume a session; bare `--resume` opens the picker |
| `--overdrive`, `--yolo` | Full auto |
| `--profile <name>` | Use the `~/.osa/profiles/<name>` profile |
| `--setup` · `--dev` · `--no-color` · `-V` · `-h` | Wizard · dev mode · plain output · version · help |

### Resuming where you left off

On exit OSA prints the exact command to pick this conversation back up,
including the mode you were in:

```
Resume this session with:
  osa resume cli_a1b2c3d4
```

The id accepts a **prefix**, git-short-SHA style, so `osa resume cli_a1b` works
and an ambiguous prefix lists the candidates rather than guessing. `osa continue`
skips the id entirely and takes the newest session in the current directory, and
bare `osa resume` opens a picker.

### Updating

`osa update` downloads the latest prebuilt release + TUI, verifies its checksum,
swaps them in atomically under `~/.osa`, prints the version delta and release
notes, restarts the backend if the running one is now stale, and relaunches.
**You never need to run `osa stop` as part of updating** — an update that left an
old daemon serving from memory is treated as a failed update, not a success.
The swap is **rollback-safe**: a fresh version is staged and built, boot-probed
against `/health`, and only then atomically repointed. `osa update --staged
--rollback` reverts to the previous version if a new one misbehaves, and
`--dry-run` prints the plan without touching anything. `osa doctor` runs real
health checks: provider reachability, port binding, config sanity, workspace
layout.

### Slash commands

Type `/` in the TUI for the full palette — around 70 commands, completed as you
type. The ones worth knowing:

```
session    /new      /clear    /resume   /continue /session  /fork     /rename
           /tag      /sessions /recap    /rewind   /undo     /retry    /export /save
model      /model    /models   /reasoning /effort  /fast     /coordinator
context    /context  /usage    /compact  /cost     /files    /memory
work       /plan     /goal     /loop     /steer    /bg       /fg       /agents
           /tasks
project    /map      /init     /trust    /add-dir  /skills   /tools
config     /setup    /config   /permissions /hooks /mcp      /sandbox  /channels
           /theme    /keybindings /verbose /a11y   /persona  /customize
system     /doctor   /status   /metrics  /version  /update   /release-notes
           /login    /logout   /help     /exit
```

Some commands are served by the engine and some by the TUI; the palette merges
both, so everything above is reachable from the same prompt.

### Reading model performance

The permanent footer stays deliberately small so it remains stable while the terminal resizes.
It shows the active model, current context occupancy, normalized reasoning state, and a reasoning-effort chip only when the effort differs from the default `medium` tier.
Running `/fast`, for example, makes `effort:fast` appear immediately.
Active skills use a separate `Using:` row, with a `+N` count when more selections are active than fit comfortably.
That row is cleared and rebuilt from the attached session after reconnecting, so it never leaks labels from another conversation.

The activity row reports what matters during a turn: elapsed time, current output flow, thinking state, retries, stalls, and the interrupt control.
It does not repeat the latest request's input-token count because that number is the full prompt sent to the model, not cumulative session usage, and duplicating it beside the context meter is misleading.

Use the on-demand views for diagnosis instead of packing every metric into permanent chrome:

| Command | Use it for |
|---|---|
| `/context` | Current context occupancy and token breakdown |
| `/cost` | Session token accounting and estimated spend |
| `/usage` | Provider account quota and reported usage |
| `/save` | A readable Markdown snapshot under `~/.osa/exports` |
| `/loop 5m <prompt>` | Repeat a prompt through the durable session queue until `/loop stop` |
| `/status` | Active provider, model, session, tools, and permission state |
| `/reasoning` or `/effort` | Changing the speed-versus-depth tradeoff |

For quick conversational work, use `fast`.
Keep `medium` for normal coding and tool use, move to `high` or `xhigh` for difficult multi-step reasoning, and reserve `ultra` for work that benefits from maximum reasoning or dynamic workflow fan-out.
Model latency, cost, and answer quality are separate signals, so compare them on the same task rather than treating token count alone as performance.

### `/map` — see the whole repo, not just the checkout

`/map` renders the structure of the workspace you are in: its components, the
language and role of each, and — the part `git ls-files` hides — **git
submodules and nested repositories**, which normally collapse to a single
gitlink entry and become invisible to the agent. It resolves the *outermost*
enclosing workspace rather than just your current directory, understands Elixir
umbrella / Cargo / pnpm / npm / yarn / Go workspace members, and caches per root
with invalidation when the manifests change. `/map [path] [--depth N] [--refresh]`.
The agent has the same view through its `workspace_map` tool.

### Keyboard

| Key | Action |
|---|---|
| **Enter** | Send message |
| **Shift+Tab** | Cycle permission mode (ask → auto-edit → plan → overdrive) |
| **Esc** | Clear the composer |
| **Esc Esc** | Rewind, jump back to edit a previous message |
| **Ctrl+C** | Cancel the running turn (quit when the composer is empty) |
| **Ctrl+D** | Exit |
| **Ctrl+N** | New session |
| **Ctrl+R** | Reverse-search your history |
| **Ctrl+K** | Command palette (kill-to-end-of-line with text) |
| **Ctrl+O** | Expand the last tool result inline |
| **Ctrl+T** | Toggle the todo/task list |
| **Ctrl+B** | Send the running turn to the background |
| **Ctrl+G** / **Alt+V** | Voice input |
| **Ctrl+Z** | Suspend |
| **Ctrl+L** | Redraw the screen |
| **Ctrl+Shift+L** | Toggle the sidebar |
| **Ctrl+X Ctrl+K** | Stop all running agents |
| **Alt+P** | Model picker |
| **Alt+T** | Toggle the thinking view |
| **Alt+R** | Toggle raw markdown |
| **Ctrl+V** | Paste, images become `[Image #N]`, file paths attach |
| **←** | Move focus into the fleet roster |
| **`/`** | Slash-command completions |
| **`!`** | Shell mode, run the line as a shell command |
| **`@`** | Mention a file or directory (fuzzy picker) |
| **F1** | Help |

Every one of these is rebindable: drop a `~/.osa/keybindings.json` listing
`{context, bindings}` blocks (contexts are `global`, `idle`, `processing`;
chords may be multi-step, e.g. `"ctrl+x ctrl+k"`). `Ctrl+C`, `Ctrl+D` and
`Ctrl+M` are reserved. `/keybindings` prints the live map and the config path.

### `!` shell and `@` file mentions

Prefix a line with **`!`** to run it as a shell command without leaving the
chat, `!git status`, `!ls`, `!cargo test`. Type **`@`** to fuzzy-pick a file or
directory; the path is inserted inline and its contents are pulled into context
so you can say "explain `@lib/agent/loop.ex`" and OSA already has it.

### MCP (Model Context Protocol)

OSA is both an MCP **client** and an MCP **server**. Point it at any MCP server
and its tools show up alongside the built-ins, discoverable and callable in the
same loop. Expose OSA's own tools to other MCP-aware apps by running it as a
server. Full JSON-RPC protocol, multiple transports, tool discovery, and result
caching are built in.

Servers you give OSA live in three scopes, and always load:

| Scope | File |
|---|---|
| user | `~/.osa/mcp.json` |
| project | `./.mcp.json` (shared, and requires approval before it starts) |
| local | `./.osa/mcp.local.json` (yours, untracked) |

**Other tools' MCP configs are opt-in, not inherited.** OSA can read the servers
you configured in Claude Code, Claude Desktop, Codex, and Cursor — but importing
one means spawning a subprocess you never authorised for OSA and adding tools you
never chose, so it is **off by default**. `/mcp list` tells you what is out there
without running any of it ("*N servers available in other tools' configs — NOT
imported*") and labels every loaded server with where it came from, so an
inherited server never masquerades as one of yours. Opt in by setting
`"mcp_import_foreign": true` in `~/.osa/settings.json`. Native servers always win
a name collision against a discovered one.

`/mcp` manages the rest: `add`, `remove`, `get`, and `exclude <name>` /
`unexclude <name>` — a deny list that keeps a server from loading **from any
source**, native or inherited.

### Sandboxes

Code execution routes through a pluggable sandbox layer. Backends:

| Backend | Notes |
|---|---|
| **MIOSA** | Recommended managed sandbox, auto-selected when configured |
| **E2B** | Cloud microVM isolation (`E2B_API_KEY`) |
| **Vercel** | Ephemeral cloud execution (`VERCEL_TOKEN`) |
| **Docker** | Local container isolation |
| **Host** | Direct execution, the fallback when no sandbox is configured |

In *required* mode, host execution is blocked unless a real sandbox is
available, so untrusted code never touches your machine. A dangerous-command
guard screens every shell invocation regardless of backend.

### Background agents and steer

`delegate` spawns sub-agents that run in the background, in a fork, or in an
isolated git worktree, in parallel, each with the right model for its step.
They share a task list and talk over ETS-backed mailboxes. Watch them live in
the agent tree, and **steer** a running agent mid-turn: send a new directive
into an in-flight turn and it adapts without being cancelled and restarted.
Stop or interrupt any agent from the same view. Cancelling an agent cascades
transitively to every sub-agent it spawned; a sibling can hand its context to
another via peer-resume, and worktree work is snapshotted to a durable git ref
before teardown so it stays inspectable even when discarded.
Parent agents and sub-agents independently rank the compact skill catalog for
their own task, then load only the selected `SKILL.md` body through `skill_view`.
Each selection is checkpointed against that session, so one agent's workflow
does not bleed into another agent's context.

### Plan mode, goal tracking, and rewind

`/plan` (or **Esc Esc**) puts OSA into investigative plan mode: read-only until
you approve, with the plan itself written to a durable file so it survives a
context reset or restart. For long autonomous runs, an independent read-only
goal verifier periodically checks whether your actual *goal* was met (not
just whether a file compiled) and a cross-turn goal tracker auto-pauses on a
stall instead of spinning forever. While a durable goal is active, the TUI gives
it a dedicated footer row with its elapsed time and `/goal pause`, `/goal resume`,
or `/goal stop` control, so the goal remains readable without widening the
terminal. **Esc Esc** also drives the unified
`/rewind`: jump back to any previous turn (code + conversation, or either
alone), see a diff of what's about to change, and undo the rewind itself if
you change your mind.

---

## Quickstart

```bash
osa
```

First run detects your setup and offers:

1. **Quick Start**: auto-detect providers and go
2. **Manual Setup**: choose a provider, enter an API key, pick a model
3. **Skip**: configure later with `/setup` or by editing `~/.osa/.env`

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
osa resume cli_abc123     # a specific session (a unique prefix is enough)
osa resume                # pick from a list
```

**Pick a model for one run:**

```bash
osa --model claude-opus-5 --provider anthropic
osa -m glm-5.2:cloud continue
```

---

## Configuration

All runtime config lives in `~/.osa/.env`, generated by the setup wizard:

```bash
OSA_DEFAULT_PROVIDER=ollama_cloud
OLLAMA_URL=https://ollama.com
OLLAMA_MODEL=glm-5.2:cloud
OSA_USER_NAME=Ada
OSA_AGENT_NAME=OSA
```

Anything already exported in your shell wins over this file, so
`OLLAMA_MODEL=x osa` is a one-off override rather than a silent no-op.

**Workspace:** everything OSA keeps lives under `~/.osa/`:

```
~/.osa/
├── .env              # Provider config (generated by the wizard)
├── settings.json     # User settings (effort, permissions, hooks, MCP switches)
├── permissions.json  # Tool permission rules (allow/deny with glob patterns)
├── keybindings.json  # Optional TUI key remapping
├── mcp.json          # Your MCP servers (user scope)
├── trusted_workspaces.json  # Directories you have granted trust
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

**Settings cascade:** user (`~/.osa/settings.json`) < project (`.osa/settings.json`) < local (`.osa/settings.local.json`) < session. The two project layers only apply once you have granted the directory trust — see [Workspace trust](#workspace-trust).

**Port.** The default is 9089. To move it, set **both** `OSA_PORT` (which the
`osa` launcher uses to find and health-check the backend) and `OSA_HTTP_PORT`
(which the backend binds to) to the same value.

---

## Overview

OSA is the intelligence layer of [MIOSA](https://miosa.ai), a local-first,
open-source AI agent built on Elixir/OTP. It runs on your machine, owns your
data, and connects to any LLM provider you choose.

Every agent framework processes every message the same way. OSA does not. Before
any message reaches the reasoning engine, a **Signal Classifier** decodes its
intent, domain, and complexity. Simple tasks go to fast, cheap models. Complex
multi-step tasks get decomposed into parallel sub-agents with the right model
for each step. The agent learns from every session.

The theoretical foundation is [Signal Theory](https://zenodo.org/records/18774174),
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
  │   ├─ Micro-compact (no LLM, truncate old tool results)
  │   ├─ Strip tool args → Merge consecutive → Summarize warm zone
  │   ├─ Structured 8-section compression (iterative, preserves details)
  │   ├─ Context collapse (413 recovery, withhold large results)
  │   └─ Post-compact restore (re-inject files, tasks, workspace)
  │
  ├─ Pre-Directives (explore, delegation, task creation nudges)
  │
  ├─ Genre Routing (low-signal → short-circuit, skip full loop)
  │
  ├─ Context Build (cached static base + dynamic per-request)
  │   ├─ Async memory prefetch (fires parallel while context builds)
  │   ├─ Effort-aware thinking config (fast/medium/high/xhigh/ultra)
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
│  (ReAct) │ (18 roles│           │          │                        │
│          │  bg/fork/│  Teams +  │          │  Speculative Executor  │
│          │  worktree│  NervSys  │          │                        │
├──────────┴──────────┴───────────┴──────────┴────────────────────────┤
│  Context │ Compactor │ Memory  │ Settings │ Hooks   │ Permissions   │
│  Builder │ (6-step)  │ (SQLite │ Cascade  │ (25     │ (pattern      │
│          │           │  +ETS   │ (4-layer,│  events,│  rules,       │
│          │           │  +FTS5) │  trust-  │  4 types│  interactive) │
│          │           │         │  gated)  │         │               │
├──────────┴───────────┴─────────┴──────────┴─────────┴───────────────┤
│  27 Providers │  82 Tools  │  Telemetry  │  Credential Pool  │ Soul│
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

Mode      What to do:       BUILD, EXECUTE, ANALYZE, MAINTAIN, ASSIST
Genre     Speech act:       DIRECT, INFORM, COMMIT, DECIDE, EXPRESS
Type      Domain category:  question, request, issue, scheduling, summary
Format    Container:        message, command, document, notification
Weight    Complexity:       0.0 (trivial) → 1.0 (critical, multi-step)
```

The classifier is LLM-primary with a deterministic regex fallback. Results are
cached in ETS (SHA256 key, 10-minute TTL). This is what makes tier routing
possible.

### Multi-Provider LLM Routing

27 providers offered in the setup wizard, 3 tiers, weight-based dispatch:

| Weight Range | Tier | Use Case |
|---|---|---|
| 0.00–0.35 | Utility | Fast, cheap: greetings, lookups, summaries |
| 0.35–0.65 | Specialist | Balanced: code tasks, analysis, writing |
| 0.65–1.00 | Elite | Full reasoning: architecture, orchestration, novel problems |

| Provider | Notes |
|---|---|
| **Ollama Cloud** | Fast cloud inference, no GPU required — the recommended start |
| **Ollama Local** | Runs on your machine, fully private, no API cost |
| **Anthropic** | Claude Opus 5, Sonnet 5, Opus 4.x, Sonnet 4.6, Haiku 4.5 |
| **OpenAI** | GPT-5.6 (`-terra`, `-sol`, `-luna`) |
| **Google** | Gemini 3.6 Flash, 3.5 Flash / Flash-Lite, 3.1 Pro |
| **xAI** | Grok 4.5, 4.3, Grok Build |
| **DeepSeek** | DeepSeek V4 Pro / V4 Flash, Reasoner |
| **Mistral** | Mistral Large / Medium / Small, Codestral |
| **OpenRouter** | 200+ models behind a single API key |
| **MIOSA** | Managed Optimal endpoint (limited access) |
| **Custom / local** | Any OpenAI-compatible endpoint, plus LM Studio and llama.cpp |

Also routed and offered in the wizard: Groq, Cohere, Cerebras, Fireworks,
Together, Perplexity, Replicate, SambaNova, Hyperbolic, Qwen, Moonshot (Kimi),
Zhipu (GLM), Volcengine (Doubao), Baichuan.

**Keys are checked against the real API, at setup.** When you paste a key the
wizard makes an actual minimal call to *that provider's own* endpoint — Anthropic
`/v1/messages`, Google `generateContent`, OpenRouter `/api/v1/key`, DeepSeek's
balance endpoint, an OpenAI-compatible `/chat/completions` at the provider's own
base URL for the rest — and reports one of three answers: verified, key rejected
(401/402/403, and it lets you re-enter), or unverified because the network call
itself failed. It never silently accepts a dead key, and never falls back to
probing a different vendor's endpoint.

**Recommended default:** Ollama Cloud with `glm-5.2:cloud` (no GPU, 1,000,000 token
context) is the easy starting point the setup wizard marks recommended. Other
no-GPU cloud models include `glm-5.1:cloud`, `kimi-k3:cloud`,
`kimi-k2.7-code:cloud`, `minimax-m3:cloud`, `qwen3.5:cloud`,
`deepseek-v4-pro:cloud`, and `gpt-oss:120b-cloud`. See the
[Getting Started guide](docs/GETTING_STARTED.md) for the full provider and model
list.

Switch model mid-conversation with **`/model`** (or `/models` for the picker, or
**Alt+P**). The switch is **session-scoped** — it changes the conversation you are
in, not your global default — so you can start a turn on a cheap model and move
to a stronger one without touching your config. `--model` / `--provider` do the
same thing at launch. Retired model ids are tracked and rejected up front rather
than 404-ing mid-turn.

When a call rate-limits or fails, OSA walks a configurable fallback chain and
reconnects mid-stream, so the turn keeps going.
OpenRouter model identifiers inherit context, reasoning, vision, and tool-call
capabilities from the matching vendor-scoped native catalog entry.
When tools are required, fallback routing skips models authoritatively known not
to support tool calls instead of sending a turn that cannot complete.

### Autonomous Task Orchestration

18 specialized agent roles ship built in (architect, backend, frontend, devops,
explorer, planner, debugger, tester, code-reviewer, security-auditor,
performance, refactorer, researcher, doc-writer, general-purpose and friends),
and you can add your own as `AGENT.md` files under `~/.osa/agents/`.
Explore → Plan → Execute protocol:

```
User: "Build a REST API with auth, tests, and docs"

OSA:
  ├── Explorer agent     scans codebase (read-only, fast)
  ├── Planner agent      designs architecture + implementation plan
  ├── Backend agent      writes API + auth middleware
  ├── Tester agent       writes test suite
  └── Doc-writer agent   writes documentation
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

### Post-edit format + diagnostics (OSA doesn't edit blind)

After every edit or write, OSA runs the touched file through a fast, single-file
**format + diagnostics** pass and injects any syntax/parse error straight back into
the tool result **the same turn** — so the model sees the mistake it just made
instead of discovering it many tool-calls later.

- **Auto-format on write.** Elixir formats in-process via `Code.format_string!/2`
  (respecting your `.formatter.exs`, no `mix` startup cost); Go, Rust, JS/TS and
  Python use their own single-file formatter (`gofmt -w`, `rustfmt`,
  `prettier --write`, `ruff format`).
- **Fast diagnostics.** Elixir syntax via `Code.string_to_quoted/2` (instant,
  in-process); Go via `gofmt -e`, Rust via `rustfmt`, JS via `node --check`, Python
  via `ruff check` / `py_compile`; TS/TSX parse errors surface through `prettier`.

It's dependency-light — each tool is time-boxed and quietly skipped when its binary
isn't installed, and a file that fails to parse is left untouched with its error
reported. Turn it off with `config :optimal_system_agent, post_edit_verify: [enabled: false]`.

### Agent Fleet & Dynamic Workflows

OSA can fan out into a **fleet** of independent, full-power agents and watch them
live from a Claude-Code-style roster under the composer.

**The fleet roster.** Beneath the composer sits a live roster of every running agent.
`main` is always row 0, rendered in green, the home node you always return to and never killable.
Each spawned node shows its agent type, active skills, current tool or activity, wall-clock elapsed, cumulative tokens, retries, failures, and parent-delivery state.
Open a selected node's summary to see why its model and skills were chosen.
Press **←** to move focus from the composer into the roster, **↑/↓** to select a node, and **Enter** to attach to its live transcript.
Use **p** to pause, **u** to resume, **r** to retry, **t** to cancel its current tool, **a** to reassign its task, and **x** to stop it.
Attaching is a read view and never pauses the node or steals its input.
Selecting `main` and pressing Enter returns you to your own conversation.

**Full-power spawn.** Every fleet node is a complete OSA agent loop, not a
restricted worker, its own conversation, its own token budget, and full tools,
MCP, memory, and permissions. Each is booted with the system prompt and tool
allowlist of its **custom agent-type** (`general-purpose`, `code-reviewer`, …),
so a `code-reviewer` node comes up with the reviewer prompt and read-only tools,
not a generic clone.

**Automatic, not manual.** Spawning is the agent's own decision when a task benefits from parallel peers.
Delegation routes each task to a tool-capable model and records the selection rationale.
Nodes coordinate through a shared scratchpad, and each node's budget and execution-control record are checkpointed.
After a full backend restart, orphaned autonomous nodes are recovered from their durable transcripts under the same agent IDs unless `fleet_resume_on_boot` is disabled.
Completion delivery uses durable receipts so the parent can acknowledge a result without losing it or injecting it twice after a crash.

**Dynamic workflows (ultra only).** At the top effort tier, `ultra`, OSA unlocks
dynamic workflows: fan-out orchestration that spreads a list of work across the
fleet through a bounded pool of **16 concurrent** agents. Spawns past the cap
queue FIFO and drain as slots free (they never fail), and the roster header
carries a live `N/16` counter. Below `ultra`, plain peer-spawning still works,
only the orchestrated fan-out is gated, raise effort to `ultra` to run dynamic
workflows.

### Built-in Tools

82 tools, all schema-validated, most deferred-loaded (excluded from the prompt
until needed, discoverable via `tool_search`):

| Category | Tools |
|---|---|
| **File** | `file_read`, `file_write`, `file_edit`, `multi_file_edit`, `file_glob`, `file_grep`, `dir_list`, `notebook_edit`, `diff` |
| **System** | `shell_execute`, `git`, `github`, `download`, `repl` (Python/Elixir/Node), `code_sandbox`, `bash_output`, `pty_start`, `pty_send`, `pty_read`, `pty_wait`, `pty_stop` |
| **Web** | `web_search`, `web_fetch`, `browser` |
| **Code** | `code_symbols`, `codebase_explore`, `semantic_search`, `workspace_map`, `computer_use` (macOS/Linux/Docker/SSH) |
| **Memory** | `memory_save`, `memory_recall`, `session_search`, `knowledge`, `scratchpad` |
| **Agents** | `delegate`, `fleet`, `orchestrate`, `create_agent`, `list_agents`, `send_message`, `message_agent`, `team_create`, `team_delete`, `team_tasks`, `task_write`, `task_output`, `task_stop`, `task_wait`, `task_resume`, `spawn_conversation` |
| **Multi-agent** | `mixture_of_agents`, `peer_review`, `peer_negotiate_task`, `peer_claim_region`, `cross_team_query` |
| **Plan / worktree** | `enter_plan_mode`, `exit_plan_mode`, `enter_worktree`, `exit_worktree`, `rollback`, `verify_loop`, `start_speculative` |
| **Skills** | `skill_view`, `create_skill`, `save_skill`, `use_skill`, `find_skill`, `list_skills`, `skill_manager`, `use_tool` |
| **Reporting** | `brief`, `progress_note`, `monitor`, `push_notification`, `send_user_file`, `subscribe_pr`, `remote_trigger` |
| **Config / meta** | `config`, `cron`, `sleep`, `tool_search`, `budget_status`, `ask_user` |

Large tool results are auto-persisted to disk and referenced by handle, so a
big grep never blows the context window. `file_edit` carries a second,
content-hash drift guard on top of the mtime/size check, so a same-second
collision between two edits can never silently corrupt a file.

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
| Skills | File system + session checkpoint | Patterns with occurrence ≥ 5 auto-generate skill files (SICA); active selections retain their name, body hash, and selection time |

**SICA learning cycle:** See → Introspect → Capture → Adapt. OSA observes what
works across sessions and converts recurring patterns into reusable skills
automatically.

### Token-Budgeted Context Assembly

```
CRITICAL  (unlimited)    System identity, active tool schemas
HIGH      (40%)          Recent conversation turns, current task state
MEDIUM    (30%)          Relevant memories (hybrid RAG recall, see below)
LOW       (remaining)    Workflow context, environmental metadata
```

**Three-zone compression:**
- **HOT**: last 10 messages, full fidelity
- **WARM**: older turns, progressively summarized
- **COLD**: oldest content reduced to key facts only

Compaction preserves the most recent user message verbatim (never summarized),
sizes the preserved tail to a token budget instead of a fixed message count,
and prunes stale tool-result output outright once it ages out of that budget.
On context overflow, media blocks are stripped and the request replayed before
falling back further. Recall itself is **hybrid**: vector KNN over a persisted
embedding store, fused with MMR re-ranking (so results aren't three near-dupes
of the same fact) and lightweight query expansion, degrading gracefully to
keyword-only search when no embedding provider is configured.

### Computer Use

Control your desktop directly from the agent. Platform adapters:

| Platform | Method |
|---|---|
| **macOS** | Accessibility API: click, type, screenshot, scroll |
| **Linux X11** | xdotool + xclip, full desktop control |
| **Docker** | Container-isolated desktop interaction |
| **Remote SSH** | Control machines over SSH tunnels |

OSA can take screenshots, click elements, type text, press keys, scroll, and
interact with any GUI application.

### Channels

| Channel | Notes |
|---|---|
| **Rust TUI** | Primary terminal UI: onboarding wizard, model picker, sessions, command palette, agent tree, skill and goal rows, normalized reasoning/effort state, tool-stall and recovery notices, `!` shell, `@` mentions with frecency ranking + ghost-text, LaTeX/table rendering, desktop notifications, and a fixed-height streaming viewport |
| **Elixir CLI** | REPL: streaming, task display, diff view, Ctrl+R search, multi-line input |
| **HTTP/SSE API** | Port 9089, JWT auth, 20+ route modules, real-time SSE streaming |
| **Telegram** | Long-polling, typing indicators, markdown conversion |
| **Discord** | Webhook mode, token validation |
| **Slack** | Webhook + HMAC-SHA256 request verification |
| **Also shipped** | WhatsApp, Matrix, Signal, email, LINE, Feishu, WeCom, DingTalk |

### Hooks System

25 lifecycle events, 4 hook types:

| Type | Description |
|---|---|
| **Function** | Elixir functions, built-in (security, budget, telemetry, learning) |
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

Effort controls **how much OSA thinks**, the reasoning budget it spends before
acting. Set it with `/effort`. The current tier drives the live thinking
indicator, so you see it working harder as effort climbs (e.g. *"thinking harder
with ultra effort"*).

| Level | What it does |
|---|---|
| `fast` | Minimal thinking, quick answers and low-latency replies |
| `medium` | Balanced reasoning for everyday tasks (default) |
| `high` | Deeper reasoning for harder, multi-step work |
| `xhigh` | Extended reasoning for complex analysis |
| `ultra` | Maximum thinking, and unlocks dynamic workflows (fan-out fleet orchestration) |

Higher effort means more visible thinking in the indicator; `ultra` additionally
enables the fan-out dynamic-workflow orchestration described in
[Agent Fleet & Dynamic Workflows](#agent-fleet--dynamic-workflows).
The footer keeps effort and provider-normalized reasoning as separate signals,
and refreshes both after `/reasoning`, `/effort`, `/fast`, or a model switch.

### Scheduler

Cron jobs (`CRONS.json`) and event-driven triggers (`TRIGGERS.json`) live in
`~/.osa/`. `HEARTBEAT.md` defines a recurring proactive checklist OSA runs on a
schedule, the "proactive" in proactive agent.

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

Skills are available immediately, no restart, no recompile. The Skills Registry
hot-reloads on file change. Recurring behavior patterns (occurrence ≥ 5) are
auto-promoted to skills by the SICA engine.

OSA keeps the catalog compact and loads a full `SKILL.md` only after the agent selects it with `skill_view`.
Before complex work, a metadata-only advisor ranks likely skills for the current request without loading the library's instruction bodies into context.
Its short-lived cache is invalidated by metadata changes, and telemetry reports ranking time, cache hits, candidate counts, selected body size, and the bytes added back to context.
Selected skill names, content hashes, and selection times are checkpointed with the session and re-injected on every generation, so compaction or a backend restart cannot make a long-running agent forget the workflow it chose or silently adopt changed instructions.
When a selected skill body is no longer present in conversation context, OSA requires the agent to reload it with `skill_view` before taking another task action.
The TUI shows active selections as `Using: diagnose` and restores that row when its session stream reconnects.
Deleting the session removes that checkpoint.

Long-running tools emit lightweight heartbeat frames so the TUI can distinguish useful work from a disconnected backend and surface a stalled-call recovery hint without killing legitimate builds.
`GET /api/v1/sessions/:id/health` reports whether a session is live, healthy, degraded, recoverable, or missing, including transcript, durable-event, and selected-skill diagnostics plus the appropriate recovery action, and the TUI checks it after reconnecting.
Provider reasoning state is normalized into a stable on/off signal for the TUI, while the configured effort tier remains visible separately.
OpenRouter model identifiers reuse the matching vendor's native catalog context, tool-call, vision, and reasoning capability metadata, so routing decisions do not degrade merely because a model is addressed through the gateway.
Fallback routing skips a provider when its selected model is authoritatively known to lack tools required by the active turn.

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
├── lib/optimal_system_agent/        # THE ENGINE, 200+ Elixir modules
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
│   ├── tools/builtins/              #   the 82 built-in tools: file, shell, search, web, delegate…
│   ├── workspace/                   #   workspace topology (/map) + per-directory trust
│   ├── signal/                      #   signal classifier, routes each message by intent + complexity
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
│   ├── rust/tui/src/                # THE INTERFACE, terminal UI (Rust + ratatui)
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
├── desktop/                         # legacy/experimental GUI (WIP, not part of the shipped agent)
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

## Benchmarks

OSA is benchmarked against the standard agentic-coding evaluations, and against
competing harnesses run **on this machine with the model held fixed**.

We do not quote a leaderboard-comparable score, and the reason matters more than
the number would. Published SWE-bench figures are not comparable to each other:
scaffold alone moves the same model by **11–20 points**, labs report against
denominators of 477, 484 and 500, and the official checklist forbids pass@k as a
headline while permitting best-of-k reported as pass@1. UTBoost (ACL 2025) found
**345 patches mis-graded as passing**, changing 24.4% of Verified leaderboard
entries — and the leaderboard was never re-issued.

So the only comparison we consider meaningful is one we run ourselves, with one
model, one task set, and one set of limits.

### Cost per task

The field publishes token and cost figures; ours were far outside them. Divided
out from goose's model-pinned Harbor table:

| harness | input/task | in:out | effective $/M input |
|---|---|---|---|
| Claude Code | 1.15M | 85:1 | $0.24 |
| opencode | 1.25M | 70:1 | $0.42 |
| goose | 0.71–0.88M | 56–67:1 | $3.00 |
| **OSA (before)** | **3–8M** | **~140:1** | **$3.00** |

$3.00/M is the full **uncached** rate; $0.24 implies ~96–100% cache hits. OSA had
both multipliers stacked — several times the field's token volume *and* zero
caching — for 12–35x Claude Code's cost per task.

Measured on `tb-cost-probe-v1`, 8 Terminal-Bench tasks, same provider
(`ollama/glm-5.2:cloud`), same limits, changing only the code:

| | before | after | change |
|---|---|---|---|
| input tokens / task | 4,654,997 | **2,821,177** | **−39.4%** |
| $ / task | $2.8628 | **$1.7310** | **−39.5%** |
| in:out ratio | 146.7:1 | 162.3:1 | +10.6% |
| tasks solved | 5/8 | 5/8 | unchanged |

That puts us at **2.2–3.9x** the field's input volume, down from 3.6–6.5x. It is
progress, not parity.

Four things this table is not, stated because each one could be read as a bigger
claim than we can support:

- **Both arms are priced at the same correct rates.** Our accounting was
  separately found to misprice models by up to 3x; presenting a raw dollar delta
  across that fix would have manufactured an improvement. The delta above tracks
  the token delta exactly, as it must.
- **The prompt-caching win is not in these numbers.** Caching went 0% → 94.1%
  measured live, but the benchmark path runs on Ollama, which has no cache to hit
  and no counter to read. The −39.4% comes from compaction, accounting and loop
  fixes alone; caching is additive on top for Anthropic-routed traffic, and is
  not yet demonstrated end-to-end on a benchmark.
- **The in:out ratio got worse**, because output fell faster than input. The
  ratio is a diagnostic, not a goal.
- **Solve rate is unchanged, not improved**, and its composition moved: one task
  regressed and one improved. The regression was re-run 3 times on the identical
  pre-fix build and flipped without any code change — 4 pass / 2 fail across 6
  observations. It is variance, and single runs on this set are not evidence of
  small differences in either direction.

### Corrections as of 1.0.100

Four claims above are wrong or superseded. They are corrected here rather than
edited away, because the corrections are the more useful record.

- **The dollar figures understate spend.** Both arms were priced with
  `glm-5.2:cloud` carrying the previous generation's rate — `{0.60, 2.20}`
  against Z.ai's `{1.40, 4.40}`. Every dollar number in the table above is
  **2.4x low**. The *percentage* delta survives, because both arms carry the
  same error; the absolute figures do not. Three further mispricings were found
  since: Sonnet 1.50x over, Opus 3.00x over, and every Mistral model reached
  through a gateway billing **$0.00**. All four reported `confidence: :exact`.
- **The 162:1 in:out ratio is not comparable to the field's.** It measures our
  reasoning-suppressed output against competitors' reasoning-inclusive output.
  Measured on the same basis, OSA is **69:1 against codex's 75:1** — inside the
  band, not far outside it.
- **Caching is now demonstrated end-to-end**, which the note above said it was
  not. It had been emitted only when the provider was native Anthropic, while
  benchmarks reach Claude through a compat gateway — so on the path that
  actually runs, the feature was dead code. **0% → 92.8%** on a live arm.
- **The prefix is 17.7k tokens, not the 29.8k previously measured**, of which
  7.3k is tool schemas rather than 18.6k. Earlier releases already took that;
  the larger figure was stale when quoted.

One arm was run for 1.0.100, on `anthropic/claude-sonnet-5` with an **8x timeout
multiplier**. It is **not quotable as a result**: 8 of 89 tasks, k=1, and a
multiplier far outside Terminal-Bench's own budget — one task consumed 3h11m
against a declared 30 minutes. It was run to answer one question, and it did.

Of three tasks previously lost to identical 1743s cutoffs, **two were genuinely
clock-bound** (solving at 42m and 3h11m) and **one was never a timeout at all** —
it finished early and wrong, in half the turns. That third diagnosis had been
ours and it was incorrect. Useful calibration: one task needed 1.45x its declared
budget and the other 6.4x, so a 2x multiplier recovers one of them and nothing
else.

The same arm surfaced a cache hit rate falling **95.4% → 63.2%**. That was traced
to a live defect, not to the model or the timeout: the world-state ledger's ETS
table was owned by whichever process created it, and being reached from transient
processes meant the first one to exit destroyed every session's ledger. Fixed in
this release. **Both benchmark arms predate the fix.**

### TUI resize status

The resize break documented in 1.0.102 is fixed.
OSA now owns the visible transcript, reflows retained content at the new width, keeps live surfaces at stable measured heights, and redraws from state instead of relying on terminal scrollback behavior.
Tables, code fences, the composer, thinking output, activity, goals, and status rows therefore resize as one layout rather than leaving stacked or duplicated frames behind.

The status footer uses progressive disclosure at narrow widths.
The context label survives first, its decorative meter shortens when necessary, and optional effort, MCP, and version chips render only when each complete chip fits.
Active goals use their own row so their description and controls do not compete with model and context information.
Active skills also use their own row, collapse excess selections into `+N`, and replay from the current session after SSE reconnect.
Tool heartbeats and session-health recovery notices appear in transient activity or notification surfaces rather than expanding the permanent footer.

`test/pty/test_resize.py` exercises the release binary through a real pseudo-terminal, while `test/pty/vte_content_reflow.py` covers the libvte behavior used by GNOME Terminal and Tilix.

### Prefix cost as of 1.0.101

The static prefix is what every turn pays before any work happens, so it is the
one efficiency number worth quoting on its own. Measured locally, not modelled:

| segment | tokens |
|---|---:|
| tool schemas | 7,259 |
| static base | 6,340 |
| world state | 2,865 |
| volatile tail (uncached by design) | 1,215 |
| **total** | **≈17.7k** |

MCP is separate and used to dominate it. Measured by speaking MCP stdio to 13
configured servers, of which 7 answered with **387 real tools**:

| | prefix tokens |
|---|---:|
| declared as native tool schemas | 72,111 |
| virtualized, every tool name listed | 2,020 |
| virtualized, per-server ceiling (1.0.101) | **417** |

The cost is now **O(servers), not O(tools)** — a server exposing 300 tools costs
one line. Permission gating is unchanged: every MCP call still goes through an
OSA tool with a real schema and a real permission check.

**No benchmark arm was run for 1.0.101.** The last one is described above and is
diagnostic, not comparable.

### Head-to-head, model held fixed

Terminal-Bench 2.0 tasks, all arms on `glm-5.2:cloud` through one local daemon,
wire-verified per arm that no arm silently substituted a model.

**These are Terminal-Bench 2.0 numbers, and 2.0 is superseded.** The live
leaderboards are 2.1 and 3; 2.1 corrects 26 tasks upstream (a byte-diff of the
two trees finds 27). Nothing below has been re-run on the current sets yet.

**The harness-fault column below reads 0 for every arm because it was computed
before we could measure it.** See the correction under *What the benchmarks were
actually for*.

| harness | solved | harness faults |
|---|---|---|
| codex | 6/6 | 0 |
| mini-swe-agent | 6/6 | 0 |
| **OSA** | **4/6** | **0** |
| opencode | 3/6 | 0 |
| goose | 3/6 | 0 |

**This is not a ranking.** n=6 yields 4 discordant tasks against the ≥6 needed
for p<0.05, and every pairwise exact-McNemar test returned "not
distinguishable". It is published because it is what we measured, not because it
settles anything.

The result we consider most instructive is not ours: **mini-swe-agent — a
deliberately minimal loop around one bash tool, with a 243-byte tool schema —
matched codex and beat OSA.** On the longest task, codex solved it on 3.66M
input tokens while OSA burned 32.5M and timed out.

### SWE-bench Verified and SWE-bench Pro

| benchmark | arm | resolved | 95% CI |
|---|---|---|---|
| Verified (hard subset, airgapped) | OSA | 23/40 | 42.2–71.5% |
| Pro (hard subset) | OSA | 9/12 | 46.8–91.1% |
| Pro (same 12, OpenRouter path) | OSA | 6/12 | 25.4–74.6% |

Controls on the same sets: gold-apply 40/40 and 12/12, empty 0/40 and 0/12, so
the pipelines are sound. **None of these is a dataset score** — every run carries
`is_full_dataset_run: false`, and `bench/report/cli.py gate` refuses to print any
of them as a rate. That refusal is the design working, not a limitation.

At n=100 on Verified, gold-apply scores **98/100** — two instances are broken in
the dataset itself, so the achievable ceiling on that prefix is 98%, not 100%.

### What the benchmarks were actually for

Finding our own bugs. When we started, **a quarter of failures were OSA's
fault** rather than the model's.

**Correction.** An earlier version of this section claimed two benchmarks
reported *zero* harness faults. That claim was produced by a broken instrument
and was false. Four classes of OSA's own errors — encoding faults that killed a
turn, malformed requests, and two kinds of corruption in our own history — were
being emitted as `llm_error` and therefore scored as **model** failures. Every
harness-vs-model split we published was biased in our favour.

Re-scored under corrected attribution, `osa-hard40-airgap` goes from 17 model /
0 harness to **16 model / 1 harness** — a harness-fault share of **5.9% of
failures, not 0%**. Terminal-Bench does not move: 17 telemetry files on disk,
none carrying an affected fault. The gap was smaller than we feared, but it was
not zero, and the instrument that reported zero could not have reported anything
else.

Fixed along the way:

- A nil model silently disabled compaction on 37 of 40 sessions and budgeted a
  1M-token window as 32k
- The prompt-injection guard refused any pasted log containing `System:` — 15 of
  500 instances
- A missing `git` took down the whole application at boot
- OSA could not boot as root, breaking every containerised deployment
- Tools ran in the backend's directory rather than the session's
- Anthropic and Gemini rejected OSA's message shape with a 400, so the
  self-correction loop never ran once on those families

### Honest limits

- **Every number is a single run.** 9 of 40 instances flipped between two runs of
  the same set, so differences smaller than that are noise.
- **No full-dataset run.** 40 of 500 and 12 of 731.
- **Shell egress is a filter, not a boundary.** Web tools are denied and
  probe-verified, but this host refuses unprivileged network namespaces, so
  toolchain fetches (`go: downloading`) are detected post-hoc rather than
  prevented.
- **Every published SWE-bench Pro image ships the answer** in `/app/.git`;
  `git show <fix_commit>` returns the gold patch with the network off. We strip
  it and refuse a workspace where it is still reachable. Any Pro result produced
  without that — including published ones — is an upper bound of unknown
  tightness.

### Reproducing

```bash
bench/run-all.sh smoke        # controls only — prove the pipeline first
bench/run-all.sh swebench     # then a real arm
bench/report/cli.py gate --run <dir>
```

Controls run first and the OSA arm is refused if they fail. Methodology, with
citations, is in [`bench/report/METHODOLOGY.md`](bench/report/METHODOLOGY.md);
open findings are tracked in [`bench/FINDINGS.md`](bench/FINDINGS.md).


---

## Theoretical Foundation

OSA is grounded in four principles from information and systems theory:

1. **Shannon (Channel Capacity)**: Every channel has finite capacity. Match compute to complexity. Don't run your best model on trivial tasks.
2. **Ashby (Requisite Variety)**: The system must match the variety of inputs it receives. OSA handles every signal type, not just the common ones.
3. **Beer (Viable System Model)**: Five operational modes mirror the five subsystems every viable organization needs. Structure enables autonomy.
4. **Wiener (Feedback Loops)**: Every action produces feedback. OSA learns what works and adapts across sessions.

**Research paper:** [Signal Theory: The Architecture of Optimal Intent Encoding](https://zenodo.org/records/18774174), Luna, MIOSA Research, 2026.

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

OSA ships with its **own native memory**, built in, on by default, and fully
standalone. It works with no external services: long-term recall, episodic
tracking, the vault, and skill learning all run locally out of the box. Nothing
extra is required to get persistent, cross-session memory.

**Optimal Engine** is a knowledge-base / "second brain" product in the ecosystem,
a richer external memory and knowledge/data-store layer you can plug in. It's
**available today** and ships its **own CLI**: set it up, then tell OSA about it,
and OSA can leverage Optimal Engine as an external memory/knowledge layer
alongside its native memory. Native memory works standalone; Optimal Engine is
the optional, recommended layer when you want a deeper, shared knowledge base.

[miosa.ai](https://miosa.ai) · [GitHub](https://github.com/Miosa-osa/OSA)

---

## Contributing

Skills over code changes. Write a `SKILL.md`, share it with the community. See
[CONTRIBUTING.md](CONTRIBUTING.md) for the full process.

## License

Apache 2.0. See [LICENSE](LICENSE).

---

<div align="center">

Built by [Roberto H. Luna](https://github.com/robertohluna) and the [MIOSA](https://miosa.ai) team.
Grounded in [Signal Theory](https://zenodo.org/records/18774174). Powered by the BEAM.

</div>
