# Architecture

Technical architecture of OptimalSystemAgent (OSA). This document covers the internal systems, how they connect, and why the design decisions were made.

---

## System Overview

```
┌─────────────────────────────────────────────────────┐
│                    Channels                          │
│  CLI  |  HTTP API (REST + SSE)  |  Future: Telegram, │
│  Discord, Slack, WhatsApp                            │
└──────────────────┬──────────────────────────────────┘
                   │
┌──────────────────▼──────────────────────────────────┐
│              Signal Classifier                       │
│  S = (Mode, Genre, Type, Format, Weight)             │
│  Deterministic pattern matching (< 1ms)              │
│  Two-tier noise filter                               │
└──────────────────┬──────────────────────────────────┘
                   │ (signals only — noise filtered)
┌──────────────────▼──────────────────────────────────┐
│            Events.Bus (goldrush)                     │
│  :osa_event_router — compiled Erlang bytecode        │
│  Zero-overhead dispatch via glc:compile/2            │
└──────────────────┬──────────────────────────────────┘
                   │
┌──────────────────▼──────────────────────────────────┐
│              Agent Loop (ReAct)                       │
│  Context → LLM → Tool Calls → LLM → Response        │
│  Max 20 iterations  |  Bounded reasoning             │
└──────┬───────┬──────────┬──────────┬────────────────┘
       │       │          │          │
       ▼       ▼          ▼          ▼
  ┌────────┐ ┌─────────┐ ┌────────┐ ┌────────────────┐
  │Skills  │ │Provider │ │Memory  │ │Intelligence    │
  │Registry│ │Registry │ │(JSONL) │ │(5 modules)     │
  └────────┘ └─────────┘ └────────┘ └────────────────┘
       │
  ┌────▼───────────────┐
  │Bridge.PubSub       │
  │3-tier event fan-out│
  └────────────────────┘
```

## Signal Theory 5-Tuple

Every incoming message is classified into a 5-tuple before any processing occurs. This is the architectural foundation that separates OSA from every other agent framework.

### The 5-Tuple: S = (Mode, Genre, Type, Format, Weight)

```elixir
%OptimalSystemAgent.Signal.Classifier{
  mode: :analyze,        # What operational mode
  genre: :inform,        # Communicative purpose
  type: "question",      # Domain category
  format: :command,      # Container format
  weight: 0.85,          # Information value [0.0, 1.0]
  raw: "What is our Q3 revenue trend?",
  channel: :cli,
  timestamp: ~U[2026-02-24 10:30:00Z]
}
```

### Mode (Beer's Viable System Model)

Derived from Stafford Beer's Viable System Model (VSM). Every viable organization needs five operational subsystems. OSA maps these to five modes:

| Mode | VSM System | Description | Trigger Keywords |
|------|-----------|-------------|------------------|
| `BUILD` | S1 — Implementation | Create something new | build, create, generate, make, scaffold, design, new |
| `EXECUTE` | S2 — Coordination | Run an action | run, execute, trigger, sync, send, import, export |
| `ANALYZE` | S3 — Control | Examine data | analyze, report, dashboard, metrics, trend, compare, kpi |
| `MAINTAIN` | S4 — Intelligence | Keep things running | update, upgrade, migrate, fix, health, backup, restore |
| `ASSIST` | S5 — Policy | Help and guide (default) | Everything else |

### Genre (Speech Act Theory)

Based on Searle's classification of speech acts. What is the communicative purpose of the message?

| Genre | Speech Act | Description | Trigger Keywords |
|-------|-----------|-------------|------------------|
| `DIRECT` | Directive | Cause an action | please, do, run, make, create, send |
| `INFORM` | Assertive | Convey information (default) | Statements, descriptions |
| `COMMIT` | Commissive | Bind the sender | I will, I'll, let me, I promise |
| `DECIDE` | Declarative | Change state | approve, reject, cancel, confirm, decide, set |
| `EXPRESS` | Expressive | Convey internal state | thanks, love, hate, great, terrible |

### Type

Domain-specific classification:

| Type | Description | Trigger |
|------|-------------|---------|
| `question` | Information request | Contains "?", or how/what/why/when/where |
| `issue` | Problem report | error, bug, broken, fail, crash |
| `scheduling` | Time-related | remind, schedule, later, tomorrow |
| `summary` | Condensation request | summarize, summary, brief, recap |
| `general` | Everything else | Default |

### Format

Container type, determined by channel:

| Format | Channels |
|--------|----------|
| `command` | CLI |
| `message` | Telegram, Discord, Slack, WhatsApp |
| `notification` | Webhooks |
| `document` | Filesystem |

### Weight (Shannon Information Content)

A float from 0.0 (pure noise) to 1.0 (maximum information). Calculated from:

- **Base:** 0.5
- **Length bonus:** Up to +0.2 (longer messages carry more potential information, diminishing returns)
- **Question bonus:** +0.15 (questions are inherently high-information requests)
- **Urgency bonus:** +0.2 (urgent, asap, critical, emergency, now, immediately)
- **Noise penalty:** -0.3 (hi, hello, hey, thanks, ok, sure, lol, haha)

Messages below the `noise_filter_threshold` (default: 0.6) are filtered and never reach the LLM.

### Two-Tier Noise Filter

1. **Tier 1 — Deterministic (< 1ms):** Pattern matching against known noise patterns. Zero compute cost.
2. **Tier 2 — Smart (~200ms):** For borderline cases, a fast model (Ollama with a small model) makes the signal/noise decision.

This means a "hey" costs nothing. A "thanks" costs nothing. Only real signals consume AI compute.

### Theoretical Foundations

The 5-tuple classification is grounded in four theories:

1. **Shannon (Channel Capacity):** Every channel has a maximum information rate. Processing noise wastes capacity.
2. **Ashby (Requisite Variety):** The system must match the variety of inputs — enough capability for anything, no unnecessary complexity.
3. **Beer (Viable System Model):** Five operational modes mirror the five subsystems every viable organization needs.
4. **Wiener (Feedback Loops):** Every action produces feedback. The agent learns and adapts.

Reference: Luna, R. (2026). *Signal Theory: The Architecture of Optimal Intent Encoding in Communication Systems.* https://zenodo.org/records/18774174

## Event Bus (goldrush)

The internal event bus uses [goldrush](https://github.com/robertohluna/goldrush), a library that compiles event-matching rules into actual Erlang bytecode modules at runtime.

### How It Works

1. **Event types are defined:** `user_message`, `llm_request`, `llm_response`, `tool_call`, `tool_result`, `agent_response`, `system_event`
2. **Filters are compiled:** `glc:compile(:osa_event_router, query)` produces a real `.beam` module
3. **Events are dispatched:** `glc:handle(:osa_event_router, event)` routes at BEAM instruction speed
4. **Handlers are registered:** Each event type can have multiple handlers stored in ETS

### Event Flow

```
Channel (CLI/HTTP)
    │
    ▼
Events.Bus.emit(:user_message, %{...})
    │
    ▼
:osa_event_router (compiled Erlang bytecode)
    │
    ├── Handler 1: Agent.Loop processes the message
    ├── Handler 2: Bridge.PubSub broadcasts to subscribers
    └── Handler 3: Intelligence modules observe
```

### Why goldrush

Regular event routing uses hash maps or pattern matching at runtime. goldrush compiles the matching rules into actual Erlang bytecode via `glc:compile/2`. The routing becomes a function call — no lookups, no comparisons at runtime.

This is the same approach used in telecom systems where millions of events per second flow through the routing layer. For an AI agent, it is overkill — but it means internal event routing is never the bottleneck, no matter how many skills, handlers, or concurrent sessions you run.

### Event Types

| Event | Source | Consumers | Description |
|-------|--------|-----------|-------------|
| `user_message` | Channels | Agent.Loop | Incoming message from any channel |
| `llm_request` | Agent.Loop | Providers.Registry | Request to the LLM |
| `llm_response` | Providers | Agent.Loop | Response from the LLM |
| `tool_call` | Agent.Loop | Skills.Registry | Tool invocation |
| `tool_result` | Skills | Agent.Loop | Tool execution result |
| `agent_response` | Agent.Loop | Channels, Bridge.PubSub | Final response to user |
| `system_event` | Scheduler, internals | Agent.Loop, Memory | System-level events (heartbeat, signal filtered, etc.) |

## Agent Loop (ReAct)

The core reasoning engine. Implements a bounded ReAct (Reasoning + Acting) loop.

### Flow

```
1. Receive message from channel/bus
2. Classify signal → S = (M, G, T, F, W)
3. Check noise filter → if W < threshold, filter and return
4. Build context (identity + memory + skills + runtime)
5. Call LLM with available tools
6. If tool_calls present:
   a. Execute each tool
   b. Append results to message history
   c. Go to step 5 (re-prompt)
7. If no tool_calls: return final response
8. Write to memory, notify channel
```

### Bounded Reasoning

The loop has a hard limit of 20 iterations (configurable via `max_iterations`). If the agent reaches this limit, it returns what it has so far. This prevents infinite loops and runaway costs.

### Context Building

The `Agent.Context` module assembles the system prompt from layered sources:

1. **Identity block** — Who the agent is (hardcoded)
2. **Bootstrap files** — `IDENTITY.md`, `SOUL.md`, `USER.md` from `~/.osa/`
3. **Long-term memory** — `MEMORY.md` contents
4. **Machine addendums** — Prompt fragments for active machines
5. **Skills documentation** — List of available tools
6. **Runtime context** — Timestamp, channel, session info

### Session Management

Each conversation runs as a separate BEAM process (GenServer):

```elixir
# Sessions are registered in an Elixir Registry
{:via, Registry, {OptimalSystemAgent.SessionRegistry, session_id}}
```

This means:
- 30+ concurrent sessions on a single instance
- Each session has its own state, message history, and iteration counter
- If one session crashes, the others are unaffected
- Sessions are started on-demand and supervised by a DynamicSupervisor

## Provider Registry

Abstraction layer over LLM providers. Currently supports:

| Provider | Local | API Key Required | Default Model |
|----------|-------|-----------------|---------------|
| Ollama | Yes | No | llama3.2:latest |
| Anthropic | No | Yes | claude-opus-4-6 |
| OpenAI | No | Yes | gpt-4o |

### Provider Dispatch

```elixir
Providers.Registry.chat(messages, tools: tools, temperature: 0.7)
```

The registry:
1. Reads the configured provider from application config
2. Formats messages for the provider's API format
3. Formats tools for the provider's function calling format
4. Makes the HTTP request via `Req`
5. Parses the response into a normalized format: `%{content: String.t(), tool_calls: [...]}`

### Fallback Chain (Planned)

4-tier model routing:
1. Process-type default (thinking = best model, tool execution = fast model)
2. Task-type override (coding tasks upgrade tier)
3. Fallback chain when rate-limited
4. Local fallback (Ollama is always available)

## Machine System

Machines are composable skill groups toggled via `~/.osa/config.json`.

### Architecture

```elixir
# machines.ex is a GenServer that:
# 1. Reads ~/.osa/config.json on startup
# 2. Determines which machines are active
# 3. Provides prompt addendums for active machines
# 4. Skills.Registry checks machine state when registering machine-specific skills
```

### Available Machines

| Machine | Always Active | Skills | Prompt Addendum |
|---------|--------------|--------|-----------------|
| Core | Yes | file_read, file_write, shell_execute, web_search, memory_save | File system, shell, web tools |
| Communication | No | telegram_send, discord_send, slack_send | Messaging capabilities |
| Productivity | No | calendar_read, calendar_create, task_manager | Calendar and task tools |
| Research | No | web_search_deep, summarize, translate | Deep search and analysis |

When a machine is activated, its prompt addendum is injected into the system prompt, giving the LLM awareness of those capabilities.

## Memory System

Two layers: JSONL session storage and MEMORY.md consolidated knowledge.

### JSONL Session Storage

Every conversation is stored as a JSONL (JSON Lines) file:

```
~/.osa/sessions/
  session_abc123.jsonl
  session_def456.jsonl
  heartbeat_1708784400.jsonl
```

Each line is a JSON object:

```json
{"role":"user","content":"What's the weather?","timestamp":"2026-02-24T10:30:00Z"}
{"role":"assistant","content":"Let me check...","timestamp":"2026-02-24T10:30:01Z"}
```

### MEMORY.md

Long-term memory for facts, preferences, and insights that persist across sessions:

```markdown
## [preference] 2026-02-24T10:30:00Z
User prefers concise responses. Location: San Francisco. Industry: SaaS.

## [contact] 2026-02-24T11:00:00Z
Sarah Chen — VP Engineering at Acme Corp. Prefers data-driven discussions.
```

Skills write to MEMORY.md via `memory_save`. The agent reads it at the start of every session via the Context builder.

### Cortex (Memory Synthesis)

The Cortex module periodically synthesizes a "memory bulletin" from:
- Recent conversations across all channels
- Updated memory entries
- Pattern detection across contacts

The bulletin is injected into the system prompt so the agent has ambient awareness of what is happening across all channels. (Currently a skeleton — full implementation planned.)

## Intelligence Modules

Five modules that understand how people communicate. These run as supervised GenServers alongside the agent loop.

### 1. Communication Profiler (`CommProfiler`)

Learns communication patterns per contact over time:
- Preferred response times
- Formality level
- Topic preferences
- Message length patterns
- Communication style (direct, analytical, expressive, etc.)

Builds an incremental profile that the agent can reference when crafting responses.

### 2. Communication Coach (`CommCoach`)

Scores outbound message quality before sending:
- Clarity
- Tone appropriateness
- Completeness
- Actionability

Provides suggestions to improve the message before it goes out.

### 3. Conversation Tracker (`ConversationTracker`)

Tracks conversation depth across four levels:
1. **Surface** — Greetings, small talk, basic exchanges
2. **Operational** — Task-oriented, transactional
3. **Strategic** — Planning, decision-making, analysis
4. **Deep** — Complex problem-solving, creative collaboration

The agent adjusts its responses based on the current depth level.

### 4. Proactive Monitor (`ProactiveMonitor`)

Watches for patterns that need attention:
- **Silence detection** — A previously active contact has gone quiet
- **Engagement drop** — Response times or engagement quality declining
- **Follow-up needed** — A commitment was made but not fulfilled
- **Drift detection** — Conversation moving away from the stated goal

Generates alerts via the event bus.

### 5. Contact Detector (`ContactDetector`)

Identifies who is communicating in under 1 millisecond:
- Pattern matching against known contacts
- Name extraction from message content
- Channel-specific identification (usernames, phone numbers)

## Bridge.PubSub (3-Tier Fan-Out)

Bridges internal goldrush events to Phoenix.PubSub for external consumption.

### Three Subscription Tiers

| Tier | Topic Pattern | Use Case |
|------|--------------|----------|
| **Firehose** | `osa:events` | All events — debugging, monitoring, dashboards |
| **Session** | `osa:session:{id}` | Events scoped to a specific chat session — SSE streaming |
| **Type** | `osa:type:{type}` | Events filtered by type — selective subscription |

### How It Works

```
goldrush event → Bridge.PubSub handler → Phoenix.PubSub broadcast
                                              │
                           ┌──────────────────┼──────────────────┐
                           ▼                  ▼                  ▼
                    Firehose topic      Session topic       Type topic
                    (all events)     (per-session events)  (per-type events)
                           │                  │                  │
                           ▼                  ▼                  ▼
                     Monitoring          SSE streaming      Selective
                     dashboards          to SDK clients      handlers
```

### Subscribing

```elixir
# Subscribe to everything
Bridge.PubSub.subscribe_firehose()

# Subscribe to a specific session (e.g., for SSE streaming)
Bridge.PubSub.subscribe_session("my-session-id")

# Subscribe to a specific event type
Bridge.PubSub.subscribe_type(:agent_response)
```

### Why PubSub Over Direct goldrush

goldrush is optimized for internal dispatch — compiled bytecode, zero overhead. But external consumers (HTTP SSE connections, monitoring tools, SDK clients) need a more standard pub/sub interface. Phoenix.PubSub provides:
- Process-based subscriptions (no coupling to goldrush internals)
- Distributed PubSub if you ever need to run multiple nodes
- Standard Elixir messaging patterns

The Bridge gives you both: goldrush speed for internal routing, Phoenix.PubSub for external consumption.

## Scheduler (HEARTBEAT.md)

The `Agent.Scheduler` is a GenServer that checks `~/.osa/HEARTBEAT.md` every 30 minutes and executes pending tasks.

### How It Works

1. Parse HEARTBEAT.md for unchecked items (`- [ ]`)
2. For each item, spin up a temporary Agent.Loop session
3. Execute the task through the full agent pipeline (classification, tools, LLM)
4. Mark completed items (`- [x]`) with a timestamp
5. Circuit breaker: auto-disable after 3 consecutive failures

### Task Format

```markdown
- [ ] This task will be executed
- [x] This task was already completed (completed 2026-02-24T10:30:00Z)
```

Tasks inside HTML comments are ignored:

```markdown
<!-- These are examples, not real tasks:
- [ ] This will NOT be executed
-->
```

## OTP Supervision Tree

```
OptimalSystemAgent.Application
├── OptimalSystemAgent.Store.Repo              # Ecto + SQLite
├── {Phoenix.PubSub, name: OptimalSystemAgent.PubSub}
├── {Registry, name: OptimalSystemAgent.SessionRegistry}
├── OptimalSystemAgent.Events.Bus              # goldrush event router
├── OptimalSystemAgent.Bridge.PubSub           # 3-tier fan-out
├── OptimalSystemAgent.Providers.Registry      # LLM providers
├── OptimalSystemAgent.Skills.Registry         # Tool registry
├── OptimalSystemAgent.Machines                # Machine activation
├── OptimalSystemAgent.Agent.Memory            # JSONL + MEMORY.md
├── OptimalSystemAgent.Agent.Cortex            # Memory synthesis
├── OptimalSystemAgent.Agent.Compactor         # Context compaction
├── OptimalSystemAgent.Agent.Scheduler         # HEARTBEAT.md
├── OptimalSystemAgent.Intelligence.Supervisor
│   ├── CommProfiler
│   ├── CommCoach
│   ├── ConversationTracker
│   ├── ProactiveMonitor
│   └── ContactDetector
├── {DynamicSupervisor, name: OptimalSystemAgent.Channels.Supervisor}
└── OptimalSystemAgent.Channels.HTTP           # Bandit HTTP server
```

If any child process crashes, the supervisor restarts it automatically. If the Channels.Supervisor crashes, all active sessions are restarted. The BEAM VM handles this — 99.9999% uptime is the standard, not the aspiration.

## Data Flow Example

A complete request lifecycle:

```
1. User sends "Analyze our Q3 sales pipeline" via HTTP API
2. HTTP.API receives the request
3. Signal.Classifier produces: S = (ANALYZE, INFORM, question, command, 0.85)
4. Weight 0.85 > threshold 0.6 → signal passes
5. Agent.Loop starts a new session GenServer
6. Agent.Context builds system prompt (identity + memory + machines + skills)
7. Providers.Registry.chat() sends to configured LLM
8. LLM responds with tool_call: web_search("Q3 sales data")
9. Skills.Registry.execute("web_search", %{"query" => "Q3 sales data"})
10. Tool result appended to message history
11. LLM re-prompted with tool results
12. LLM responds with final analysis (no more tool calls)
13. Response stored in JSONL session file
14. Events.Bus emits :agent_response
15. Bridge.PubSub broadcasts to session topic
16. SSE stream delivers event to any connected clients
17. HTTP.API returns JSON response to caller
```

Total: 17 steps, but the signal classification in step 3 took < 1ms, and the noise filter prevented this from even being a question. A "hey" would have stopped at step 4.
