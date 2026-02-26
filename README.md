# OptimalSystemAgent

> The proactive AI agent that actually understands communication. Signal Theory optimized. Elixir/OTP. Run locally.

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Elixir](https://img.shields.io/badge/Elixir-1.19+-purple.svg)](https://elixir-lang.org)
[![OTP](https://img.shields.io/badge/OTP-28+-green.svg)](https://www.erlang.org)

---

## Why Another Agent Framework?

Every existing agent framework (OpenClaw, AutoGen, CrewAI, LangGraph) makes the same mistake: they treat all communication equally. A "hello" gets the same processing pipeline as "we need to restructure the Q3 revenue model."

**OptimalSystemAgent (OSA) doesn't.** Every message is classified as a **Signal** before anything else happens.

## One-Line Install (macOS)

```bash
curl -fsSL https://raw.githubusercontent.com/Miosa-osa/OSA/main/install.sh | bash
```

This installs Homebrew (if missing), mise, Erlang/OTP 28, Elixir 1.19, clones the repo, and runs the interactive setup wizard.

## What Makes OSA Different

### Signal Classification

Every incoming message is classified into a 5-tuple:

```
S = (Mode, Genre, Type, Format, Weight)

Mode:   What to do       — BUILD, ASSIST, ANALYZE, EXECUTE, MAINTAIN
Genre:  Purpose          — DIRECT, INFORM, COMMIT, DECIDE, EXPRESS
Type:   Domain category  — question, request, issue, scheduling, etc.
Format: Container        — message, document, command, notification
Weight: Information value — 0.0 (noise) to 1.0 (critical signal)
```

Noise gets filtered BEFORE hitting your LLM. Signals get routed to the right handler. This isn't a feature — it's the architecture.

**Reference:** [Signal Theory: The Architecture of Optimal Intent Encoding in Communication Systems](https://zenodo.org/records/18774174) (Luna, 2026)

### Goldrush Compiled Event Routing

Every component communicates through [goldrush](https://github.com/extend/goldrush) — compiled Erlang bytecode event modules via `glc:compile/3`. Event routing happens at BEAM instruction speed — no hash lookups, no pattern matching at runtime.

Four compiled modules:

| Module | Owner | Purpose |
|--------|-------|---------|
| `:osa_event_router` | Events.Bus | Central event bus — matches by `:type` field |
| `:osa_provider_router` | Providers.Registry | Routes LLM requests to Claude vs GPT vs Ollama |
| `:osa_tool_dispatcher` | Skills.Registry | Tool dispatch — per skill handler |
| `:osa_agent_loop` | Agent.Loop | User message matching for agent processing |

### Two-Tier Noise Filtering (Shannon Channel Capacity)

Shannon proved that every channel has a maximum information rate. Processing noise reduces your agent's capacity for real signals.

- **Tier 1 (< 1ms):** Deterministic pattern matching — greetings, acknowledgments, emoji
- **Tier 2 (~200ms):** LLM classification — only for uncertain signals

Result: 40-60% fewer LLM calls. Faster responses. Lower cost.

### Communication Intelligence (Signal Theory Unique)

- **CommProfiler:** Learns how each contact communicates over time
- **CommCoach:** Scores your outbound message quality
- **ConversationTracker:** Tracks depth (casual -> working -> deep -> strategic)
- **ProactiveMonitor:** Scans for silence, drift, engagement drops
- **ContactDetector:** Identifies contacts in < 1ms (no LLM needed)

### Composable Machines

Skills are organized into **machines** — composable skill sets activated via `~/.osa/config.json`:

| Machine | Activation | Skills |
|---------|------------|--------|
| Core | Always active | shell_execute, file_read, file_write, web_search |
| Communication | Config toggle | telegram_send, discord_send, slack_send |
| Productivity | Config toggle | calendar_read, calendar_create, task_manager |
| Research | Config toggle | web_search_deep, summarize, translate |

### Markdown Skills + Hot Reload

Skills are SKILL.md files or Elixir modules implementing `Skills.Behaviour`:

```elixir
defmodule MyApp.Skills.Calculator do
  @behaviour OptimalSystemAgent.Skills.Behaviour

  @impl true
  def name, do: "calculator"

  @impl true
  def description, do: "Evaluate a math expression"

  @impl true
  def parameters do
    %{"type" => "object",
      "properties" => %{
        "expression" => %{"type" => "string"}
      }, "required" => ["expression"]}
  end

  @impl true
  def execute(%{"expression" => expr}) do
    {result, _} = Code.eval_string(expr)
    {:ok, "#{result}"}
  end
end

# Register at runtime — goldrush recompiles the dispatcher automatically:
OptimalSystemAgent.Skills.Registry.register(MyApp.Skills.Calculator)
```

New skills become available **immediately** without restarting the BEAM VM.

### MCP Integration

Full Model Context Protocol support. Drop in any MCP server:

```json
// ~/.osa/mcp.json
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/home/user"]
    }
  }
}
```

### Elixir/OTP (Fault-Tolerant by Design)

- Supervised process tree — crashed processes restart automatically
- Hot code upgrades — update skills without downtime
- 30+ concurrent conversations on a single instance
- Built for the BEAM — the VM designed for telecom reliability

## Quick Start

### Prerequisites

- macOS (Linux support coming)
- Ollama (for local LLM) or an API key for Anthropic/OpenAI

### Install

```bash
# One-line install (recommended)
curl -fsSL https://raw.githubusercontent.com/Miosa-osa/OSA/main/install.sh | bash

# Or manual setup
git clone https://github.com/Miosa-osa/OSA.git
cd OSA
mix deps.get
mix osa.setup    # Interactive setup wizard
mix compile
```

### Run

```bash
mix chat          # Interactive terminal REPL
mix osa.chat      # Same thing, Mix task
iex -S mix        # Programmatic usage
```

### Auto-Start on Login (macOS)

```bash
launchctl load ~/Library/LaunchAgents/com.osa.agent.plist    # Enable
launchctl unload ~/Library/LaunchAgents/com.osa.agent.plist  # Disable
```

### Configure

```bash
# Use local Ollama (default — no API key needed)
export OSA_DEFAULT_PROVIDER=ollama

# Or use Anthropic Claude
export OSA_DEFAULT_PROVIDER=anthropic
export ANTHROPIC_API_KEY=sk-...

# Or use OpenAI
export OSA_DEFAULT_PROVIDER=openai
export OPENAI_API_KEY=sk-...
```

Or edit `~/.osa/config.json` directly.

## Architecture

```
┌─────────────────────────────────────────────────┐
│                    Channels                      │
│  CLI │ Telegram │ Discord │ Slack │ SDK          │
└──────────────┬──────────────────────────────────┘
               │
┌──────────────▼──────────────────────────────────┐
│              Signal Classifier                   │
│  S = (Mode, Genre, Type, Format, Weight)         │
│  Two-tier noise filter (Shannon)                 │
└──────────────┬──────────────────────────────────┘
               │ signals only (noise filtered)
┌──────────────▼──────────────────────────────────┐
│     Events.Bus (:osa_event_router)               │
│     goldrush-compiled Erlang bytecode            │
└──────────────┬──────────────────────────────────┘
               │
┌──────────────▼──────────────────────────────────┐
│              Agent Loop (ReAct)                   │
│  Context → LLM → Tools → LLM → Response          │
│  Max 20 iterations │ Bounded reasoning            │
│  :osa_agent_loop compiled module                  │
└──────────────┬──────────────────────────────────┘
               │
    ┌──────────┼──────────┐
    ▼          ▼          ▼
┌────────┐ ┌────────┐ ┌────────┐
│Machines│ │Provider│ │ Memory │
│(skills)│ │Registry│ │(JSONL) │
│:osa_   │ │:osa_   │ │        │
│tool_   │ │provider│ │        │
│dispatch│ │_router │ │        │
└────────┘ └────────┘ └────────┘

Bridge.PubSub (3-tier fan-out):
  osa:events │ osa:session:{id} │ osa:type:{type}

Intelligence Layer (always running):
  CommProfiler │ CommCoach │ ConversationTracker
  ContactDetector │ ProactiveMonitor
```

### Supervisor Tree

```
OptimalSystemAgent.Application (one_for_one)
├── SessionRegistry           ← process registry for agent sessions
├── Phoenix.PubSub            ← standalone publish/subscribe
├── Events.Bus                ← goldrush-compiled :osa_event_router
├── Bridge.PubSub             ← goldrush → PubSub bridge (3 tiers)
├── Store.Repo                ← SQLite3 persistent storage
├── Providers.Registry        ← goldrush-compiled :osa_provider_router
├── Skills.Registry           ← goldrush-compiled :osa_tool_dispatcher
├── Machines                  ← composable skill set activation
├── MCP.Supervisor            ← DynamicSupervisor for MCP servers
├── Channels.Supervisor       ← DynamicSupervisor (CLI / Telegram / SDK)
├── Agent.Memory              ← persistent JSONL session storage
├── Agent.Scheduler           ← heartbeat + cron scheduler
├── Agent.Compactor           ← context compression (80/85/95%)
├── Agent.Cortex              ← periodic memory synthesis
└── Intelligence.Supervisor   ← Signal Theory intelligence modules
```

## OSA vs. Other Frameworks

| Feature | OSA | OpenClaw | NanoClaw | AutoGen | CrewAI |
|---------|-----|----------|----------|---------|--------|
| Signal classification | 5-tuple S=(M,G,T,F,W) | No | No | No | No |
| Noise filtering | Two-tier (Shannon) | None | None | None | None |
| Communication intelligence | 5 modules | None | None | None | None |
| Event routing | [goldrush](https://github.com/extend/goldrush) compiled Erlang bytecode | None | Hash lookup | None | None |
| Conversation depth tracking | 4-level adaptive | No | No | No | No |
| Persistent memory | JSONL + MEMORY.md | Flat markdown | SQLite | Vector DB | Vector DB |
| Context compaction | 3-tier threshold | Manual | None | None | None |
| Fault tolerance | OTP supervision | None | None | None | None |
| Hot code reload | goldrush recompile | No | No | No | No |
| Composable machines | Config toggle | No | No | No | No |
| MCP support | Yes | Partial | Yes | No | No |
| Run locally | Yes (Ollama) | Yes | Yes | Requires API | Requires API |
| Runtime | BEAM (preemptive, concurrent) | Node.js (single-threaded) | Node.js | Python | Python |
| Codebase | ~8K lines Elixir | ~430K lines TS | ~15K lines TS | ~50K lines | ~30K lines |

## Theoretical Foundation

OSA is built on four governing principles from Signal Theory:

1. **Shannon (Channel Capacity):** Every channel has a maximum information rate. Don't waste it on noise.
2. **Ashby (Requisite Variety):** The agent must have enough variety to handle the variety of inputs — but not more.
3. **Beer (Viable System Model):** The agent is a recursive viable system with 5 subsystems (S1-S5) mapped to 5 modes.
4. **Wiener (Feedback Loops):** Every action produces feedback. Every feedback loop has a response mechanism.

Google DeepMind independently arrived at the same 5-level autonomy framework (Feb 2026) — 54 years after Beer formalized it.

## MIOSA Ecosystem

OSA is the intelligence layer of the MIOSA platform. It runs locally as your proactive agent and integrates with the broader operating system ecosystem.

```
┌─────────────────────────────────────────────────────────┐
│                    MIOSA Platform                         │
│                                                           │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐      │
│  │  BusinessOS  │  │  ContentOS  │  │  Your OS    │      │
│  │  (template)  │  │  (template) │  │  (template) │      │
│  └──────┬───────┘  └──────┬──────┘  └──────┬──────┘      │
│         │                 │                 │              │
│  ┌──────▼─────────────────▼─────────────────▼──────┐      │
│  │              OS Templates + SDK                  │      │
│  │         Desktop / Mobile / Web UI                │      │
│  └──────────────────────┬──────────────────────────┘      │
│                         │                                  │
│  ┌──────────────────────▼──────────────────────────┐      │
│  │         OptimalSystemAgent (OSA)                 │      │
│  │    Signal Theory intelligence — runs local       │      │
│  │    or connects via MIOSA Cloud API               │      │
│  └─────────────────────────────────────────────────┘      │
└───────────────────────────────────────────────────────────┘
```

### How It Works

- **OS Templates** (BusinessOS, ContentOS, etc.) provide the UI and workflows for specific domains
- **OSA** provides the intelligence — signal classification, proactive monitoring, communication intelligence, tool execution
- **MIOSA SDK** connects the templates to OSA, whether running locally or via the cloud API
- **Local mode:** OSA runs on your machine with Ollama. Your data stays local. Zero cloud dependency.
- **Cloud mode:** Connect to the MIOSA Cloud API for managed OSA with enterprise features, cross-OS reasoning, and L5 autonomous operation.

### Use Cases

| Setup | Description |
|-------|-------------|
| **OSA standalone** | Run locally as a CLI agent. Chat, automate tasks, manage files. No UI needed. |
| **OSA + BusinessOS** | Proactive business assistant. Monitors conversations, manages contacts, schedules follow-ups. |
| **OSA + ContentOS** | Content operations agent. Drafts, schedules, analyzes engagement, manages publishing workflows. |
| **OSA + Custom Template** | Build your own OS template. OSA handles the intelligence, you design the experience. |
| **MIOSA Cloud API** | Managed OSA instances. Multi-tenant, enterprise governance, cross-OS reasoning. |

### MIOSA Premium

The open-source OSA is the full local agent. MIOSA Premium adds:

- **SORX Skills Engine:** Tier-gated skill execution with temperature control
- **Cross-OS Reasoning:** Query across multiple OS instances simultaneously
- **Enterprise Governance:** Custom autonomy policies, audit logging, compliance
- **CARRIER Bridge:** Go <-> Elixir high-performance protocol
- **Cloud API:** Managed OSA instances with 99.9% uptime SLA
- **24/7 Proactive Monitoring:** L5 fully autonomous operation

[miosa.ai](https://miosa.ai)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Apache 2.0 — See [LICENSE](LICENSE).

---

Built by [MIOSA](https://miosa.ai). Grounded in [Signal Theory](https://zenodo.org/records/18774174).
