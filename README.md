# OptimalSystemAgent

> Your AI agent that actually understands what matters. It reads every message, decides if it's noise or signal, and only spends energy on what counts. Runs on your machine. Your data stays yours.

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Elixir](https://img.shields.io/badge/Elixir-1.19+-purple.svg)](https://elixir-lang.org)
[![OTP](https://img.shields.io/badge/OTP-28+-green.svg)](https://www.erlang.org)

---

## The Problem

We built OpenClaw — an open-source AI agent framework. 430,000 lines of TypeScript. It worked. But we kept hitting the same wall: **every message got the same treatment**. A "hey" went through the same pipeline as "we need to restructure our entire Q3 revenue model."

That's like giving every phone call to your business the same priority. The spam call gets the same attention as your biggest client. No business runs that way. Why should your AI?

## The Solution

OSA classifies every incoming message *before* processing it. Five dimensions, scored instantly:

- **What needs to happen** — Build something? Analyze data? Just assist?
- **What's the intent** — Is someone asking, deciding, committing, or just chatting?
- **What domain** — A question? A bug report? A scheduling request?
- **What format** — A quick message? A document? A system alert?
- **How important is it** — Noise (0.0) to critical signal (1.0)

Noise gets filtered out *before* it ever hits your AI model. Real signals get routed to the right handler immediately. The result: **40-60% fewer AI calls, faster responses, lower cost.**

This isn't a feature bolted onto an agent. It's the architecture.

**Research:** [Signal Theory: The Architecture of Optimal Intent Encoding in Communication Systems](https://zenodo.org/records/18774174) (Luna, 2026)

## One-Line Install (macOS)

```bash
curl -fsSL https://raw.githubusercontent.com/Miosa-osa/OSA/main/install.sh | bash
```

Sets up everything automatically — Elixir, dependencies, configuration wizard. Takes about 2 minutes.

## What Makes OSA Different

### 1. It Filters Noise Before Spending Money

Every AI call costs money (or compute time). Most agents waste 40-60% of their capacity on messages that don't need AI at all — greetings, "ok", "thanks", emoji reactions.

OSA has two layers of filtering:
- **Instant filter (< 1ms):** Pattern matching catches obvious noise — no AI needed
- **Smart filter (~200ms):** For borderline messages, a fast model decides: signal or noise?

Only real signals reach your main AI model.

### 2. It Learns How People Communicate

OSA has five built-in intelligence modules that no other agent framework offers:

| Module | What It Does |
|--------|-------------|
| **Communication Profiler** | Learns each contact's communication style over time |
| **Communication Coach** | Scores your outbound message quality before you send |
| **Conversation Tracker** | Tracks depth — from casual chat to deep strategic discussion |
| **Proactive Monitor** | Watches for silence, drift, and engagement drops |
| **Contact Detector** | Identifies who's talking in under 1 millisecond |

### 3. It Routes Events at Hardware Speed

Internal event routing uses [goldrush](https://github.com/extend/goldrush) — a library that compiles event-matching rules into actual machine code at runtime. When OSA routes a message internally, it's not doing lookups or matching patterns. The routing is pre-compiled into the runtime itself.

This is the same technology used in telecom systems that handle millions of events per second.

### 4. It's Modular — Turn Capabilities On and Off

Skills are grouped into **machines** you toggle with a config file:

| Machine | What You Get |
|---------|-------------|
| **Core** (always on) | File operations, shell commands, web search |
| **Communication** | Send via Telegram, Discord, Slack |
| **Productivity** | Calendar management, task tracking |
| **Research** | Deep web search, summarization, translation |

Need a new capability? Write a skill file, drop it in a folder. It's available immediately — no restart needed.

### 5. It Doesn't Crash — It Recovers

Built on the BEAM virtual machine (Erlang/OTP) — the same platform that powers WhatsApp and telecom switches. If any part of OSA crashes, it automatically restarts without affecting the rest of the system. Handle 30+ conversations simultaneously on a single instance.

### 6. It Runs Locally — Your Data Stays Yours

Default setup uses Ollama for local AI. No data leaves your machine. No API keys needed. Zero cloud dependency.

Want more power? Point it at Anthropic (Claude) or OpenAI (GPT) with one config change.

## Quick Start

### Install

```bash
# One-line install (recommended)
curl -fsSL https://raw.githubusercontent.com/Miosa-osa/OSA/main/install.sh | bash

# Or manual setup
git clone https://github.com/Miosa-osa/OSA.git
cd OSA
mix deps.get
mix osa.setup    # Interactive setup wizard
mix ecto.create && mix ecto.migrate
mix compile
```

### Run

```bash
mix chat          # Start talking to your agent
```

### Configure

```bash
# Local AI (default — free)
export OSA_DEFAULT_PROVIDER=ollama

# Or Anthropic Claude
export OSA_DEFAULT_PROVIDER=anthropic
export ANTHROPIC_API_KEY=sk-...

# Or OpenAI
export OSA_DEFAULT_PROVIDER=openai
export OPENAI_API_KEY=sk-...
```

Or edit `~/.osa/config.json` directly.

### Auto-Start on Login (macOS)

```bash
launchctl load ~/Library/LaunchAgents/com.osa.agent.plist    # Enable
launchctl unload ~/Library/LaunchAgents/com.osa.agent.plist  # Disable
```

## How It Works (Technical)

### Signal Classification

Every message is classified into a 5-tuple before processing:

```
S = (Mode, Genre, Type, Format, Weight)

Mode:   What to do       — BUILD, ASSIST, ANALYZE, EXECUTE, MAINTAIN
Genre:  Purpose          — DIRECT, INFORM, COMMIT, DECIDE, EXPRESS
Type:   Domain category  — question, request, issue, scheduling, etc.
Format: Container        — message, document, command, notification
Weight: Information value — 0.0 (noise) to 1.0 (critical signal)
```

### Architecture

```
┌─────────────────────────────────────────────────┐
│                    Channels                      │
│  CLI │ Telegram │ Discord │ Slack │ SDK          │
└──────────────┬──────────────────────────────────┘
               │
┌──────────────▼──────────────────────────────────┐
│              Signal Classifier                   │
│  S = (Mode, Genre, Type, Format, Weight)         │
│  Two-tier noise filter                           │
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
└──────────────┬──────────────────────────────────┘
               │
    ┌──────────┼──────────┐
    ▼          ▼          ▼
┌────────┐ ┌────────┐ ┌────────┐
│Machines│ │Provider│ │ Memory │
│(skills)│ │Registry│ │(JSONL) │
└────────┘ └────────┘ └────────┘

Intelligence Layer (always running):
  CommProfiler │ CommCoach │ ConversationTracker
  ContactDetector │ ProactiveMonitor
```

### Adding Custom Skills

Skills are Elixir modules with four functions — name, description, parameters, execute:

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

# Register at runtime — available immediately, no restart:
OptimalSystemAgent.Skills.Registry.register(MyApp.Skills.Calculator)
```

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

## OSA vs. Other Frameworks

| | OSA | OpenClaw | AutoGen | CrewAI |
|--|-----|----------|---------|--------|
| **Classifies before processing** | Yes (5-tuple) | No | No | No |
| **Filters noise** | Two-tier | None | None | None |
| **Communication intelligence** | 5 modules | None | None | None |
| **Event routing** | Compiled bytecode ([goldrush](https://github.com/extend/goldrush)) | None | None | None |
| **Conversation depth tracking** | 4-level adaptive | No | No | No |
| **Fault tolerance** | Auto-recovery (OTP) | None | None | None |
| **Hot reload skills** | Yes | No | No | No |
| **Runs locally** | Yes (Ollama) | Yes | Requires API | Requires API |
| **Runtime** | BEAM (concurrent) | Node.js (single-thread) | Python | Python |
| **Codebase** | ~8K lines | ~430K lines | ~50K lines | ~30K lines |

## Theoretical Foundation

OSA is grounded in four principles from communication and systems theory:

1. **Shannon (Channel Capacity):** Every channel has a maximum information rate. Processing noise wastes capacity meant for real signals.
2. **Ashby (Requisite Variety):** The system must match the variety of its inputs — enough capability to handle anything, but no unnecessary complexity.
3. **Beer (Viable System Model):** Five operational modes (Build, Assist, Analyze, Execute, Maintain) mirror the five subsystems every viable organization needs.
4. **Wiener (Feedback Loops):** Every action produces feedback. Every feedback loop has a response. The agent learns and adapts.

## MIOSA Ecosystem

OSA is the intelligence layer of the MIOSA platform. It powers the AI behind every OS template — running locally on your machine or via the MIOSA Cloud API.

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

### How It Fits Together

- **OS Templates** (BusinessOS, ContentOS, etc.) are the interface — they give you the screens, workflows, and tools for your domain
- **OSA** is the brain — it classifies signals, monitors conversations, executes tools, and takes initiative when it detects something important
- **MIOSA SDK** connects the templates to OSA, whether you're running locally or using the cloud
- **Local mode:** Everything runs on your machine. Your data never leaves. Zero cloud dependency.
- **Cloud mode:** Managed OSA with enterprise features, cross-OS reasoning, and fully autonomous operation.

### Use Cases

| Setup | What You Get |
|-------|-------------|
| **OSA standalone** | A local AI agent in your terminal. Chat, automate tasks, manage files. |
| **OSA + BusinessOS** | A proactive business assistant that monitors conversations, manages contacts, and schedules follow-ups automatically. |
| **OSA + ContentOS** | A content operations agent that drafts, schedules, analyzes engagement, and manages publishing. |
| **OSA + Custom Template** | Build your own OS template. OSA handles the intelligence, you design the experience. |
| **MIOSA Cloud** | Managed OSA instances with enterprise governance, multi-tenant support, and 99.9% uptime. |

### MIOSA Premium

The open-source OSA is the full local agent. MIOSA Premium adds:

- **SORX Skills Engine:** Enterprise-grade skill execution with reliability tiers and temperature control
- **Cross-OS Reasoning:** Query across multiple OS instances simultaneously
- **Enterprise Governance:** Custom autonomy policies, audit logging, compliance
- **Cloud API:** Managed OSA instances with 99.9% uptime SLA
- **24/7 Proactive Monitoring:** Fully autonomous operation

[miosa.ai](https://miosa.ai)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Apache 2.0 — See [LICENSE](LICENSE).

---

Built by [MIOSA](https://miosa.ai). Grounded in [Signal Theory](https://zenodo.org/records/18774174).
