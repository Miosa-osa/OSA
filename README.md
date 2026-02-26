# OptimalSystemAgent

> A lightweight, Signal Theory-grounded AI agent that classifies every message before processing it. Unlike other agent frameworks that treat every input equally, OSA decides what matters first — filtering noise, routing signals, and only spending compute on what counts. An alternative to [NanoClaw](https://github.com/qwibitai/nanoclaw), [Nanobot](https://github.com/HKUDS/nanobot), and [OpenClaw](https://github.com/openclaw/openclaw). Runs on your machine. Your data stays yours.

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Elixir](https://img.shields.io/badge/Elixir-1.19+-purple.svg)](https://elixir-lang.org)
[![OTP](https://img.shields.io/badge/OTP-28+-green.svg)](https://www.erlang.org)

---

## The Problem

When we started building an AI agent for the MIOSA platform, we looked at what was already out there. OpenClaw had 430,000 lines of TypeScript. NanoClaw stripped that down to ~200 lines. Nanobot got it to 4,000 lines of Python. AutoGen, CrewAI — more options, different languages, same core idea.

They all solved real problems. NanoClaw nailed simplicity and security. Nanobot nailed lightweight multi-channel support. But after running them, we kept hitting the same wall: **every message gets the same treatment.** A "hey" goes through the same pipeline as "we need to restructure our entire Q3 revenue model."

None of them solved the **intelligence problem.** They send every single message — greetings, "ok", emoji reactions, "thanks" — straight to the AI model. Every message costs the same compute. Every message waits in the same queue. There's no triage. No priority. No signal-versus-noise separation.

That's like running a business where every phone call gets the same priority. The spam call gets the same attention as your biggest client. No business runs that way. Why should your AI?

So we built OSA from scratch — different language, different runtime, different architecture. Not a fork, not a wrapper. A fundamentally different approach grounded in [Signal Theory](https://zenodo.org/records/18774174).

## What OSA Does Differently

OSA classifies every incoming message *before* processing it. Five dimensions, scored in under 1 millisecond:

- **What needs to happen** — Build something? Analyze data? Just assist?
- **What's the intent** — Is someone asking, deciding, committing, or just chatting?
- **What domain** — A question? A bug report? A scheduling request?
- **What format** — A quick message? A document? A system alert?
- **How important is it** — Noise (0.0) to critical signal (1.0)

Noise gets filtered *before* it ever hits your AI model. Real signals get routed to the right handler immediately. The result: **40-60% fewer AI calls, faster responses, lower cost.**

This isn't a feature bolted onto an agent. It's the architecture.

**Research:** [Signal Theory: The Architecture of Optimal Intent Encoding in Communication Systems](https://zenodo.org/records/18774174) (Luna, 2026)

## One-Line Install (macOS)

```bash
curl -fsSL https://raw.githubusercontent.com/Miosa-osa/OSA/main/install.sh | bash
```

Sets up everything automatically — Elixir, dependencies, configuration wizard. Takes about 2 minutes.

## Why OSA Over NanoClaw / Nanobot / OpenClaw

### 1. It Filters Noise Before Spending Money

Every AI call costs money (or compute time). NanoClaw, Nanobot, and OpenClaw send everything to the model. Every "ok", every "thanks", every emoji reaction — full pipeline, full cost.

OSA has two layers of filtering:
- **Instant filter (< 1ms):** Pattern matching catches obvious noise — no AI needed
- **Smart filter (~200ms):** For borderline messages, a fast model decides: signal or noise?

Only real signals reach your main AI model. You save 40-60% on AI costs immediately.

### 2. It Has Communication Intelligence (Nobody Else Does)

NanoClaw has container isolation. Nanobot has channel breadth. OSA has **communication intelligence** — five modules that understand how people communicate:

| Module | What It Does |
|--------|-------------|
| **Communication Profiler** | Learns each contact's communication style over time |
| **Communication Coach** | Scores your outbound message quality before you send |
| **Conversation Tracker** | Tracks depth — from casual chat to deep strategic discussion |
| **Proactive Monitor** | Watches for silence, drift, and engagement drops |
| **Contact Detector** | Identifies who's talking in under 1 millisecond |

No other agent framework — lightweight or otherwise — has anything like this.

### 3. It Actually Recovers From Crashes

NanoClaw runs as a single Node.js process. If it crashes, everything stops. You restart manually. Nanobot is a Python process — same problem.

OSA runs on the BEAM virtual machine (Erlang/OTP) — the same platform that powers WhatsApp and telecom switches with 99.9999% uptime. If any part of OSA crashes, it automatically restarts that component without affecting the rest of the system. Handle 30+ conversations simultaneously on a single instance.

### 4. It Routes Events at Hardware Speed

Internal event routing uses [goldrush](https://github.com/robertohluna/goldrush) — a library that compiles event-matching rules into actual machine code at runtime. When OSA routes a message internally, it's not doing hash lookups or pattern matching. The routing is pre-compiled into the runtime itself.

NanoClaw routes through a Node.js polling loop. Nanobot routes through a Python message bus. OSA routes through compiled Erlang bytecode. The difference matters at scale.

### 5. It's Modular — Turn Capabilities On and Off

Skills are grouped into **machines** you toggle with a config file:

| Machine | What You Get |
|---------|-------------|
| **Core** (always on) | File operations, shell commands, web search |
| **Communication** | Send via Telegram, Discord, Slack |
| **Productivity** | Calendar management, task tracking |
| **Research** | Deep web search, summarization, translation |

Need a new capability? Write a skill file, drop it in a folder. It's available immediately — no restart needed, no rebuild, no recompilation. Hot code reload.

### 6. It Runs Locally — Your Data Stays Yours

Default setup uses Ollama for local AI. No data leaves your machine. No API keys needed. Zero cloud dependency.

Want more power? Point it at Anthropic or OpenAI with one config change.

## OSA vs. Other Frameworks

| | **OSA** | **NanoClaw** | **Nanobot** | **OpenClaw** | **AutoGen** | **CrewAI** |
|--|---------|-------------|------------|-------------|------------|-----------|
| **Classifies before processing** | Yes (5-tuple) | No | No | No | No | No |
| **Filters noise** | Two-tier (1ms + 200ms) | No | No | No | No | No |
| **Communication intelligence** | 5 modules | No | No | No | No | No |
| **Conversation depth tracking** | 4-level adaptive | No | No | No | No | No |
| **Event routing** | Compiled bytecode ([goldrush](https://github.com/robertohluna/goldrush)) | Polling loop | Python bus | None | None | None |
| **Fault tolerance** | Auto-recovery (OTP) | Single process | Single process | None | None | None |
| **Concurrent conversations** | 30+ (BEAM processes) | Queue-based | Sequential | Queue-based | Sequential | Sequential |
| **Hot reload skills** | Yes (no restart) | No (code change) | No (restart) | No | No | No |
| **Container isolation** | BEAM process isolation | Docker/Apple Container | No | No | No | No |
| **Runs locally** | Yes (Ollama) | Yes (agent SDK) | Yes (vLLM) | Yes | Requires API | Requires API |
| **SDK / HTTP API** | Yes (REST + SSE) | IPC only | CLI + gateway | REST | Python | Python |
| **MCP support** | Yes | Via agent SDK | Yes | Yes | No | No |
| **Language** | Elixir/OTP | TypeScript | Python | TypeScript | Python | Python |
| **Codebase** | ~8K lines | ~200 lines core | ~4K lines | ~430K lines | ~50K lines | ~30K lines |

### What They Do Better (Being Honest)

- **NanoClaw** has true OS-level container isolation via Docker — agents can't escape their sandbox. OSA uses BEAM process isolation which is lighter but less strict.
- **NanoClaw** has agent swarms — teams of agents that collaborate. OSA doesn't have multi-agent collaboration yet.
- **Nanobot** supports 10+ chat channels out of the box (Telegram, Discord, WhatsApp, Slack, Signal, Matrix, QQ, DingTalk, Feishu, Email). OSA currently has CLI and HTTP/SDK — more channels are planned.
- **Nanobot** supports 17 LLM providers including Chinese providers (Qwen, Moonshot, Zhipu, VolcEngine). OSA supports Ollama, Anthropic, and OpenAI.
- **Both** have simpler setup — NanoClaw uses an agent SDK to guide installation, Nanobot is a pip install.

### What OSA Does That Neither Can

- **Signal classification** — The 5-tuple S=(Mode, Genre, Type, Format, Weight) is architecturally unique. No other framework classifies the nature of a message before deciding how to handle it.
- **Noise filtering** — 40-60% of messages in a typical conversation are noise. OSA filters them before they hit the AI model. Everyone else processes everything.
- **Communication intelligence** — Five dedicated modules that learn how people communicate, track conversation depth, detect contacts, and monitor engagement. This doesn't exist anywhere else.
- **Hardware-speed routing** — goldrush compiles event filters into actual Erlang bytecode modules. This is telecom-grade event processing running inside your agent.
- **True fault tolerance** — OTP supervision trees restart crashed components automatically. Your agent doesn't go down because one skill had a bug.

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

The HTTP API starts automatically on port 8089 — connect any SDK client or send requests directly.

### Configure

```bash
# Local AI (default — free)
export OSA_DEFAULT_PROVIDER=ollama

# Or Anthropic
export OSA_DEFAULT_PROVIDER=anthropic
export ANTHROPIC_API_KEY=sk-...

# Or OpenAI
export OSA_DEFAULT_PROVIDER=openai
export OPENAI_API_KEY=sk-...
```

Or edit `~/.osa/config.json` directly.

### HTTP API

OSA exposes a REST API on port 8089 for SDK clients and integrations:

```bash
# Health check
curl http://localhost:8089/health

# Classify a message (Signal Theory 5-tuple)
curl -X POST http://localhost:8089/api/v1/classify \
  -H "Content-Type: application/json" \
  -d '{"message": "What is our Q3 revenue trend?"}'

# Run the full agent loop
curl -X POST http://localhost:8089/api/v1/orchestrate \
  -H "Content-Type: application/json" \
  -d '{"input": "Analyze our sales pipeline", "session_id": "my-session"}'

# List available skills
curl http://localhost:8089/api/v1/skills

# Stream events (SSE)
curl http://localhost:8089/api/v1/stream/my-session
```

JWT authentication is supported for production use — set `OSA_SHARED_SECRET` and `OSA_REQUIRE_AUTH=true`.

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
│  CLI │ HTTP API │ Telegram │ Discord │ SDK       │
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

## Ready-Made Skills

Drop these into `~/.osa/skills/` and they work immediately — no restart, no rebuild:

| Skill | What It Does |
|-------|-------------|
| [Email Assistant](examples/skills/email-assistant/) | Triage inbox, flag urgent, draft replies, track follow-ups |
| [Daily Briefing](examples/skills/daily-briefing/) | Weather, calendar, news, task priorities — every morning automatically |
| [Sales Pipeline](examples/skills/sales-pipeline/) | Track deals, catch stalled opportunities, forecast revenue |
| [Content Writer](examples/skills/content-writer/) | Blog posts, social media, email campaigns — research-first drafting |
| [Meeting Prep](examples/skills/meeting-prep/) | Research attendees, prep talking points, summarize past interactions |

Copy the skill folder into `~/.osa/skills/` and it's live:

```bash
cp -r examples/skills/email-assistant ~/.osa/skills/
# Done. Ask your agent: "triage my inbox"
```

See the [Skills Guide](docs/skills-guide.md) to write your own.

## Real-World Use Cases

| Use Case | Machines | What Happens |
|----------|----------|-------------|
| **Personal AI Assistant** | Core | Daily briefings, email triage, task management, file organization |
| **Business Operations** | Core + Communication | Sales pipeline monitoring, client follow-ups, meeting prep, revenue alerts |
| **Content Operations** | Core + Research | Blog drafting, social scheduling, engagement analysis, trend research |
| **Customer Support** | Core + Communication | Ticket triage via signal classification, auto-categorization, response drafting |
| **Development Workflow** | Core | Code review, bug triage, sprint planning, documentation |
| **Research Assistant** | Core + Research | Deep web search, source summarization, knowledge management |

Full details with example prompts: [Use Cases Guide](docs/use-cases.md)

## Documentation

| Doc | What It Covers |
|-----|---------------|
| [Getting Started](docs/getting-started.md) | Install, first conversation, add skills, configure providers |
| [Skills Guide](docs/skills-guide.md) | SKILL.md format, Elixir modules, hot reload, best practices |
| [HTTP API Reference](docs/http-api.md) | Every endpoint, auth, SSE streaming, error codes |
| [Architecture](docs/architecture.md) | Signal Theory deep dive, event bus, agent loop, supervision tree |
| [Use Cases](docs/use-cases.md) | 6 real-world use cases with example prompts |
| [SDK Architecture](docs/SDK-ARCHITECTURE.md) | SDK design, ADRs, API contract, migration path |

## Contributing

We prefer **skills over code changes.** Write a SKILL.md, share it with the community. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Apache 2.0 — See [LICENSE](LICENSE).

---

Built by [MIOSA](https://miosa.ai). Grounded in [Signal Theory](https://zenodo.org/records/18774174).
