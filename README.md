# OptimalSystemAgent

> The AI agent that thinks before it acts. Signal Theory-grounded intelligence that classifies, filters, orchestrates, and learns — across 17 LLM providers, 12 chat channels, and unlimited custom skills. An alternative to [NanoClaw](https://github.com/qwibitai/nanoclaw), [Nanobot](https://github.com/HKUDS/nanobot), and [OpenClaw](https://github.com/openclaw/openclaw). Runs on your machine. Your data stays yours.

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Elixir](https://img.shields.io/badge/Elixir-1.19+-purple.svg)](https://elixir-lang.org)
[![OTP](https://img.shields.io/badge/OTP-28+-green.svg)](https://www.erlang.org)
[![Tests](https://img.shields.io/badge/Tests-440%20passing-brightgreen.svg)](#)

---

## The Problem

Every agent framework today treats every message the same. A "hey" goes through the same pipeline as "our production database is down." Every greeting, every "ok", every emoji reaction — full pipeline, full cost, full latency.

None of them solve the **intelligence problem.** They're message processors, not intelligent systems.

OSA is different. It's grounded in [Signal Theory](https://zenodo.org/records/18774174) — every message is classified, weighted, and routed before a single token of AI compute is spent. Noise gets filtered. Signals get prioritized. Complex tasks get decomposed across multiple agents. The system learns and adapts.

**18,700+ lines of Elixir/OTP. 440 tests. Zero cloud dependency.**

## What Makes OSA Different

### 1. LLM-Primary Signal Classification

Every message is classified into a 5-tuple before processing — and the classifier is an LLM, not regex:

```
S = (Mode, Genre, Type, Format, Weight)

Mode:   What action    — BUILD, EXECUTE, ANALYZE, MAINTAIN, ASSIST
Genre:  Purpose        — DIRECT, INFORM, COMMIT, DECIDE, EXPRESS
Type:   Domain         — question, request, issue, scheduling, summary, report
Format: Container      — message, command, document, notification
Weight: Information    — 0.0 (noise) → 1.0 (critical signal)
```

The LLM understands intent. "Help me build a rocket" → BUILD mode (not ASSIST, which is what keyword matching would give you). "Can you run the tests?" → EXECUTE. The deterministic fallback only activates when the LLM is unavailable.

Results are cached in ETS (SHA256 key, 10-minute TTL) — repeated messages never hit the LLM twice.

### 2. Two-Tier Noise Filtering

```
Tier 1 (< 1ms):  Deterministic — regex patterns, length thresholds, duplicate detection
Tier 2 (~200ms): LLM-based — only for uncertain signals (weight 0.3-0.6)
```

40-60% of messages in a typical conversation are noise. OSA filters them before they reach your main AI model. Everyone else processes everything.

### 3. Autonomous Task Orchestration

Complex tasks get decomposed into parallel sub-agents automatically:

```
User: "Build me a REST API with auth, tests, and docs"

OSA Orchestrator:
  ├── Research agent — 12 tool uses — 45.2k tokens — analyzing codebase
  ├── Builder agent  — 28 tool uses — 89.1k tokens — writing implementation
  ├── Tester agent   — 8 tool uses  — 23.4k tokens — writing tests
  └── Writer agent   — 5 tool uses  — 12.8k tokens — writing documentation

Synthesis: 4 agents completed — files created, tests passing, docs written.
```

The orchestrator:
- Analyzes complexity via LLM (simple → single agent, complex → multi-agent)
- Decomposes into dependency-aware waves (topological sort)
- Spawns sub-agents with role-specific prompts (researcher, builder, tester, reviewer, writer)
- Tracks real-time progress (tool uses, tokens, current action) via event bus
- Synthesizes all results into a unified response

### 4. Intelligent Skill Discovery & Creation

Before creating a new skill, OSA searches existing ones:

```
User: "Create a skill for analyzing CSV data"

OSA: Found existing skills that may match:
  - file_read (relevance: 0.72) — Read file contents from the filesystem
  - shell_execute (relevance: 0.45) — Execute shell commands

  Use one of these, or should I create a new skill?

User: "Create a new one"
→ OSA writes ~/.osa/skills/csv-analyzer/SKILL.md and hot-registers it immediately.
```

Skills can be:
- **Built-in modules** — Elixir code implementing `Skills.Behaviour`
- **SKILL.md files** — Markdown-defined, drop in `~/.osa/skills/`, available instantly
- **MCP server tools** — Auto-discovered from `~/.osa/mcp.json`
- **Dynamically created** — The agent creates its own skills at runtime

### 5. Token-Budgeted Context Assembly

Context isn't dumped — it's assembled with a token budget:

```
CRITICAL (unlimited): System identity, active tools
HIGH     (40%):       Recent conversation turns, current task state
MEDIUM   (30%):       Relevant memories (keyword-searched, not full dump)
LOW      (remaining): Workflow context, environmental info
```

Smart token estimation: `words × 1.3 + punctuation × 0.5`. Relevance-scored memory retrieval: keyword overlap 50% + recency decay 30% + importance 20%.

### 6. Progressive Context Compression

Three-zone sliding window with importance-weighted retention:

```
HOT  (last 10 msgs):  Never touched — full fidelity
WARM (msgs 11-30):    Progressive compression — merge same-role, summarize groups
COLD (msgs 31+):      Key facts only — importance-weighted retention
```

5-step compression pipeline: strip tool args → merge same-role → summarize groups of 5 → compress cold → emergency truncate. Tool calls get +0.5 importance, acknowledgments get -0.5.

### 7. Three-Store Memory Architecture

```
Session Memory:  JSONL per session — full conversation history
Long-Term:       MEMORY.md — persistent knowledge base
Episodic Index:  ETS inverted index — keyword → session mapping
```

`recall_relevant/2` extracts keywords (150+ stop words filtered), searches the inverted index, scores by relevance, and returns the most relevant memories for injection into context.

### 8. Communication Intelligence

Five modules that understand how people communicate:

| Module | What It Does |
|--------|-------------|
| **Communication Profiler** | Learns each contact's style — response time, formality, topic preferences |
| **Communication Coach** | Scores outbound message quality before sending — clarity, tone, completeness |
| **Conversation Tracker** | Tracks depth from casual chat to deep strategic discussion (4 levels) |
| **Proactive Monitor** | Watches for silence, drift, and engagement drops — triggers alerts |
| **Contact Detector** | Identifies who's talking in under 1 millisecond |

No other agent framework has anything like this.

### 9. Multi-Agent Swarm Collaboration

```elixir
# Four collaboration patterns
:parallel     # All agents work simultaneously
:pipeline     # Agent output feeds into next agent
:debate       # Agents argue, consensus emerges
:review_loop  # Build → review → fix → re-review
```

Eight specialized agent roles with dedicated prompts. Mailbox-based inter-agent messaging. Dependency-aware wave execution.

### 10. Docker Container Isolation

```bash
mix osa.sandbox.setup   # Build the sandbox image
```

- Read-only root filesystem
- `CAP_DROP ALL` — zero Linux capabilities
- Network isolation
- Warm container pool for instant execution
- Ubuntu 24.04 base with common dev tools

## 17 LLM Providers

| Provider | Type | Notable |
|----------|------|---------|
| **Ollama** | Local | Free, private, no API key |
| **Anthropic** | Cloud | Native Messages API |
| **OpenAI** | Cloud | GPT-4o, o1, o3 |
| **Groq** | Cloud | Ultra-fast inference |
| **Together** | Cloud | Open-source model hosting |
| **Fireworks** | Cloud | Fast inference |
| **DeepSeek** | Cloud | Cost-effective |
| **Perplexity** | Cloud | Search-augmented |
| **Mistral** | Cloud | European provider |
| **Replicate** | Cloud | Model marketplace |
| **Google** | Cloud | Gemini models |
| **Cohere** | Cloud | Enterprise NLP |
| **Qwen** | Cloud | Alibaba Cloud |
| **Moonshot** | Cloud | Kimi models |
| **Zhipu** | Cloud | GLM models |
| **VolcEngine** | Cloud | ByteDance |
| **Baichuan** | Cloud | Chinese LLM |

Shared `OpenAICompat` base for 13 providers. Native implementations for Anthropic and Ollama. Fallback chain: if primary fails, next provider picks up automatically.

```bash
export OSA_DEFAULT_PROVIDER=groq
export GROQ_API_KEY=gsk_...
# Done. OSA now uses Groq for all inference.
```

## 12 Chat Channels

| Channel | Features |
|---------|----------|
| **CLI** | Built-in terminal interface |
| **HTTP/REST** | SDK API surface on port 8089 |
| **Telegram** | Webhook + polling, group support |
| **Discord** | Bot gateway, slash commands |
| **Slack** | Events API, slash commands, blocks |
| **WhatsApp** | Business API, webhook verification |
| **Signal** | Signal CLI bridge, group support |
| **Matrix** | Federation-ready, E2EE support |
| **Email** | IMAP polling + SMTP sending |
| **QQ** | OneBot protocol |
| **DingTalk** | Robot webhook, outgoing messages |
| **Feishu/Lark** | Event subscriptions, card messages |

Each channel adapter handles webhook signature verification, rate limiting, and message format translation. The manager starts configured channels automatically at boot.

## OSA vs. Everyone Else

| | **OSA** | **NanoClaw** | **Nanobot** | **OpenClaw** | **AutoGen** | **CrewAI** |
|--|---------|-------------|------------|-------------|------------|-----------|
| **Signal classification** | LLM-primary 5-tuple | No | No | No | No | No |
| **Noise filtering** | Two-tier (1ms + 200ms) | No | No | No | No | No |
| **Task orchestration** | Multi-agent, dependency-aware | No | No | No | Basic | Basic |
| **Communication intelligence** | 5 modules | No | No | No | No | No |
| **Skill discovery** | Search + suggest + create | No | Plugin system | No | No | No |
| **Context compression** | 3-zone sliding window | No | No | No | No | No |
| **Token-budgeted context** | 4-tier priority | No | No | No | No | No |
| **Memory architecture** | 3-store + inverted index | No | Basic | No | No | No |
| **LLM providers** | 17 | 3-4 | 17 | 3-4 | 3-4 | 3-4 |
| **Chat channels** | 12 | IPC only | 10+ | REST | Python | Python |
| **Container isolation** | Docker sandbox | Docker/Apple | No | No | No | No |
| **Agent swarms** | 4 patterns, 8 roles | Basic | No | No | Multi-agent | Multi-agent |
| **Event routing** | Compiled bytecode (goldrush) | Polling | Python bus | None | None | None |
| **Fault tolerance** | OTP auto-recovery | Single process | Single process | None | None | None |
| **Concurrent conversations** | 30+ (BEAM processes) | Queue-based | Sequential | Queue-based | Sequential | Sequential |
| **Hot reload skills** | Yes (no restart) | No | No | No | No | No |
| **MCP support** | Yes | Via SDK | Yes | Yes | No | No |
| **Dynamic skill creation** | Runtime SKILL.md + register | No | No | No | No | No |
| **Workflow tracking** | Multi-step + LLM decomposition | No | No | No | No | No |
| **Language** | Elixir/OTP | TypeScript | Python | TypeScript | Python | Python |
| **Codebase** | ~18.7K lines | ~200 lines core | ~4K lines | ~430K lines | ~50K lines | ~30K lines |
| **Tests** | 440 | Minimal | Minimal | Basic | Basic | Basic |

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
# Local AI (default — free, private)
export OSA_DEFAULT_PROVIDER=ollama

# Or any of the 17 supported providers:
export OSA_DEFAULT_PROVIDER=anthropic    # or openai, groq, deepseek, together, etc.
export ANTHROPIC_API_KEY=sk-...
```

Or edit `~/.osa/config.json` directly.

### Chat Channels

```bash
# Enable Telegram
export TELEGRAM_BOT_TOKEN=...

# Enable Discord
export DISCORD_BOT_TOKEN=...

# Enable Slack
export SLACK_BOT_TOKEN=...
export SLACK_SIGNING_SECRET=...

# Channels auto-start when their config is present
```

## HTTP API

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

# Execute a complex task (multi-agent orchestration)
curl -X POST http://localhost:8089/api/v1/orchestrator/complex \
  -H "Content-Type: application/json" \
  -d '{"message": "Build a REST API with auth and tests", "session_id": "s1"}'

# Get orchestration progress
curl http://localhost:8089/api/v1/orchestrator/progress/task_abc123

# Launch an agent swarm
curl -X POST http://localhost:8089/api/v1/swarm/launch \
  -H "Content-Type: application/json" \
  -d '{"task": "Review this codebase for security issues", "pattern": "review_loop"}'

# List available skills
curl http://localhost:8089/api/v1/skills

# Create a dynamic skill
curl -X POST http://localhost:8089/api/v1/skills/create \
  -H "Content-Type: application/json" \
  -d '{"name": "csv-analyzer", "description": "Analyze CSV files", "instructions": "..."}'

# Stream events (SSE)
curl http://localhost:8089/api/v1/stream/my-session

# Channel webhooks
curl -X POST http://localhost:8089/webhook/telegram
curl -X POST http://localhost:8089/webhook/discord
curl -X POST http://localhost:8089/webhook/slack
```

JWT authentication is supported for production — set `OSA_SHARED_SECRET` and `OSA_REQUIRE_AUTH=true`.

## Architecture

```
┌───────────────────────────────────────────────────────────┐
│                      12 Channels                           │
│  CLI │ HTTP │ Telegram │ Discord │ Slack │ WhatsApp │ ...  │
└───────────────────────┬───────────────────────────────────┘
                        │
┌───────────────────────▼───────────────────────────────────┐
│            Signal Classifier (LLM-primary)                 │
│    S = (Mode, Genre, Type, Format, Weight)                 │
│    ETS cache (SHA256, 10-min TTL)                          │
│    Deterministic fallback when LLM unavailable             │
└───────────────────────┬───────────────────────────────────┘
                        │
┌───────────────────────▼───────────────────────────────────┐
│         Two-Tier Noise Filter                              │
│    Tier 1: < 1ms deterministic │ Tier 2: ~200ms LLM       │
│    40-60% of messages filtered before AI compute           │
└───────────────────────┬───────────────────────────────────┘
                        │ signals only
┌───────────────────────▼───────────────────────────────────┐
│         Events.Bus (:osa_event_router)                     │
│         goldrush-compiled Erlang bytecode                  │
└───────┬─────────┬─────────┬─────────┬────────────────────┘
        │         │         │         │
   ┌────▼───┐ ┌───▼────┐ ┌──▼──┐ ┌───▼──────────┐
   │  Agent │ │Orchest-│ │Swarm│ │ Intelligence │
   │  Loop  │ │ rator  │ │     │ │   (5 mods)   │
   └───┬────┘ └───┬────┘ └──┬──┘ └──────────────┘
       │          │         │
  ┌────▼──────────▼─────────▼──────────────────────┐
  │             Shared Infrastructure               │
  │  Context Builder (token-budgeted)               │
  │  Compactor (3-zone sliding window)              │
  │  Memory (3-store + inverted index)              │
  │  Cortex (knowledge synthesis)                   │
  │  Workflow (multi-step tracking)                 │
  │  Scheduler (cron + heartbeat)                   │
  └────────────────────────────────────────────────┘
       │          │         │          │
  ┌────▼───┐ ┌───▼────┐ ┌──▼────┐ ┌───▼──────┐
  │17 LLM  │ │Skills  │ │Memory │ │  OS      │
  │Providers│ │Registry│ │(JSONL)│ │Templates │
  └────────┘ └────────┘ └───────┘ └──────────┘
```

### OTP Supervision Tree

Every component is supervised. If any part crashes, OTP restarts just that component — no downtime, no data loss, no manual intervention. This is the same technology that powers telecom switches with 99.9999% uptime.

```
OptimalSystemAgent.Supervisor (one_for_one)
├── SessionRegistry
├── Phoenix.PubSub
├── Events.Bus (goldrush :osa_event_router)
├── Bridge.PubSub (event fan-out, 3 tiers)
├── Store.Repo (SQLite3)
├── Providers.Registry (17 providers, :osa_provider_router)
├── Skills.Registry (7 builtins + SKILL.md + MCP, :osa_tool_dispatcher)
├── Machines (composable skill sets)
├── OS.Registry (template discovery + connection)
├── MCP.Supervisor (DynamicSupervisor)
├── Channels.Supervisor (DynamicSupervisor, 12 adapters)
├── Agent.Memory (3-store architecture)
├── Agent.Workflow (multi-step tracking)
├── Agent.Orchestrator (multi-agent spawning)
├── Agent.Progress (real-time tracking)
├── Agent.Scheduler (cron + heartbeat)
├── Agent.Compactor (3-zone compression)
├── Agent.Cortex (knowledge synthesis)
├── Intelligence.Supervisor (5 communication modules)
├── Swarm.Supervisor (multi-agent patterns)
├── Bandit HTTP (port 8089)
└── Sandbox.Supervisor (Docker, when enabled)
```

## Workflow Examples

OSA ships with workflow templates for common complex tasks:

```bash
# Example workflows in examples/workflows/
build-rest-api.json         # 5-step API scaffolding
build-fullstack-app.json    # 8-step full-stack build
debug-production-issue.json # 7-step systematic debugging
content-campaign.json       # 6-step content creation
code-review.json            # 4-step code review
```

The workflow engine tracks progress, accumulates context between steps, supports checkpointing/resume, and auto-detects when a task should become a workflow.

## Adding Custom Skills

### Option 1: SKILL.md (No Code)

Drop a markdown file in `~/.osa/skills/your-skill/SKILL.md`:

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
2. Use shell commands to run analysis (pandas, awk, etc.)
3. Produce a summary with key findings
```

Available immediately — no restart, no rebuild.

### Option 2: Elixir Module (Full Power)

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

# Register at runtime — available immediately:
OptimalSystemAgent.Skills.Registry.register(MyApp.Skills.Calculator)
```

### Option 3: Let OSA Create Skills Dynamically

OSA can create its own skills at runtime when it encounters a task that needs a capability that doesn't exist yet. It writes a SKILL.md file and hot-registers it — the skill is available for all future sessions.

## MCP Integration

Full Model Context Protocol support:

```json
// ~/.osa/mcp.json
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/home/user"]
    },
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"]
    }
  }
}
```

MCP tools are auto-discovered and available alongside built-in skills.

## OS Template Integration

OSA auto-discovers and integrates with OS templates:

```bash
> connect to ~/Desktop/MIOSA/BusinessOS

# OSA scans the directory, detects the stack (Go + Svelte + PostgreSQL),
# finds modules (CRM, Projects, Invoicing), and saves the connection.
```

Ship a `.osa-manifest.json` for full integration:

```json
{
  "osa_manifest": 1,
  "name": "BusinessOS",
  "stack": { "backend": "go", "frontend": "svelte", "database": "postgresql" },
  "modules": [
    { "id": "crm", "name": "CRM", "paths": ["backend/internal/modules/crm/"] }
  ],
  "skills": [
    { "name": "create_contact", "endpoint": "POST /api/v1/contacts" }
  ]
}
```

## Theoretical Foundation

OSA is grounded in four principles from communication and systems theory:

1. **Shannon (Channel Capacity):** Every channel has finite capacity. Processing noise wastes capacity meant for real signals.
2. **Ashby (Requisite Variety):** The system must match the variety of its inputs — 17 providers, 12 channels, unlimited skills.
3. **Beer (Viable System Model):** Five operational modes (Build, Assist, Analyze, Execute, Maintain) mirror the five subsystems every viable organization needs.
4. **Wiener (Feedback Loops):** Every action produces feedback. The agent learns and adapts — memory, cortex, profiling.

**Research:** [Signal Theory: The Architecture of Optimal Intent Encoding in Communication Systems](https://zenodo.org/records/18774174) (Luna, 2026)

## MIOSA Ecosystem

OSA is the intelligence layer of the MIOSA platform:

| Setup | What You Get |
|-------|-------------|
| **OSA standalone** | Full AI agent in your terminal — chat, automate, orchestrate |
| **OSA + BusinessOS** | Proactive business assistant with CRM, scheduling, revenue alerts |
| **OSA + ContentOS** | Content operations agent — drafting, scheduling, engagement analysis |
| **OSA + Custom Template** | Build your own OS template. OSA handles the intelligence. |
| **MIOSA Cloud** | Managed instances with enterprise governance and 99.9% uptime |

### MIOSA Premium

The open-source OSA is the full agent. MIOSA Premium adds:

- **SORX Skills Engine:** Enterprise-grade skill execution with reliability tiers
- **Cross-OS Reasoning:** Query across multiple OS instances simultaneously
- **Enterprise Governance:** Custom autonomy policies, audit logging, compliance
- **Cloud API:** Managed OSA instances with 99.9% uptime SLA

[miosa.ai](https://miosa.ai)

## Documentation

| Doc | What It Covers |
|-----|---------------|
| [Getting Started](docs/getting-started.md) | Install, first conversation, configure providers |
| [Skills Guide](docs/skills-guide.md) | SKILL.md format, Elixir modules, hot reload |
| [HTTP API Reference](docs/http-api.md) | Every endpoint, auth, SSE, error codes |
| [Architecture](docs/architecture.md) | Signal Theory, event bus, supervision tree |
| [SDK Architecture](docs/SDK-ARCHITECTURE.md) | SDK design, API contract, migration path |

## Contributing

We prefer **skills over code changes.** Write a SKILL.md, share it with the community. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Apache 2.0 — See [LICENSE](LICENSE).

---

Built by [MIOSA](https://miosa.ai). Grounded in [Signal Theory](https://zenodo.org/records/18774174). Powered by the BEAM.
