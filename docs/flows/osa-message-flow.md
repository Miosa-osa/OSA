# OSA — Message Processing Flow

Canonical reference for how a user message travels through the Optimal System Agent pipeline, from
channel ingress to SSE display. Every decision point, every injection point, every variable is shown.

Source files referenced throughout: `agent/loop.ex`, `signal/classifier.ex`,
`signal/noise_filter.ex`, `agent/context.ex`, `agent/hooks.ex`, `agent/tier.ex`,
`bridge/pubsub.ex`, `channels/http/api.ex`, `client/sse.go`.

---

## 1. High-Level Architecture

```
User Input
    │
    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  CHANNEL LAYER                                                              │
│  ┌────────┐  ┌──────┐  ┌──────────┐  ┌────────┐  ┌────────┐  ┌─────────┐  │
│  │  CLI   │  │ HTTP │  │ Telegram │  │Discord │  │  Slack │  │ Webhook │  │
│  └───┬────┘  └──┬───┘  └────┬─────┘  └───┬────┘  └───┬────┘  └────┬────┘  │
│      └──────────┴───────────┴────────────┴────────────┴────────────┘       │
└──────────────────────────────────┬──────────────────────────────────────────┘
                                   │ {message, channel, session_id, user_id}
                                   ▼
                        ┌──────────────────┐
                        │     Router        │   POST /api/v1/orchestrate
                        │ (Phoenix/Plug)    │   GenServer.call(via(session_id),
                        └────────┬─────────┘   {:process, message, opts})
                                 │
                                 ▼
                        ┌──────────────────┐
                        │ Signal Classifier │   S = (Mode, Genre, Type, Format, Weight)
                        │  + Noise Filter  │   classify_fast/2 + NoiseFilter.filter/1
                        └────────┬─────────┘
                                 │
                    ┌────────────┴─────────────┐
                    │                          │
                 {:noise, _}           {:signal, weight}
                    │                          │
                    ▼                          ▼
             Short-circuit            ┌──────────────────┐
             (no LLM call)            │  Context Builder  │   Two-tier assembly
                                      │  (Soul + dynamic) │   Token-budgeted
                                      └────────┬─────────┘
                                               │
                                               ▼
                                      ┌──────────────────┐
                                      │ Provider Router   │   Config / /model override
                                      │ (Tier-aware)      │   Tier: elite/specialist/utility
                                      └────────┬─────────┘
                                               │
                                               ▼
                                      ┌──────────────────┐
                                      │   LLM Provider   │   Anthropic / OpenAI / Ollama
                                      │ (chat_stream/3)  │   / Groq / DeepSeek / etc.
                                      └────────┬─────────┘
                                               │ Token stream
                                               ▼
                                      ┌──────────────────┐
                                      │   ReAct Loop      │   Max 30 iterations
                                      │ (agent/loop.ex)   │   Pre/Post hooks
                                      └────────┬─────────┘
                                               │
                                               ▼
                                      ┌──────────────────┐
                                      │  Events.Bus       │   goldrush event bus
                                      │ (Bridge.PubSub)   │   → Phoenix.PubSub
                                      └────────┬─────────┘
                                               │
                                               ▼
                                      ┌──────────────────┐
                                      │  SSE Controller   │   GET /api/v1/stream/:session_id
                                      │ (HTTP channel)    │   Chunked text/event-stream
                                      └────────┬─────────┘
                                               │
                                               ▼
                                      ┌──────────────────┐
                                      │  Go TUI / Client  │   SSEClient.ListenCmd
                                      │  (Bubbletea)      │   parseSSEEvent dispatcher
                                      └──────────────────┘
```

---

## 2. Detailed Signal Classification Flow

Every incoming message is classified into Signal Theory 5-tuple `S = (M, G, T, F, W)` before the
agent loop runs. Classification has two phases: a synchronous fast path that never blocks, and an
asynchronous LLM enrichment that runs in the background.

```
User Message
    │
    ▼
┌─────────────────────────────────────────────────────┐
│  PHASE 1 — NOISE FILTER  (NoiseFilter.filter/1)     │
│                                                     │
│  Tier 1: Deterministic (< 1ms)                      │
│    length == 0                  → {:noise, :empty}  │
│    length < 3                   → {:noise, :too_short}│
│    matches @noise_patterns      → {:noise, :pattern_match}│
│      (greetings, ack, lol, hi…)                     │
│    weight < 0.3                 → {:noise, :low_weight}│
│    weight 0.3–0.59              → {:uncertain, w}   │
│    weight >= 0.6                → {:signal, w}      │
│                                                     │
│  Tier 2: LLM-based (ETS-cached, 5-min TTL)          │
│    only when :uncertain                             │
│    → classify_noise_llm/1                           │
│       T=0.0, max_tokens=10                          │
│       returns "signal" | "noise"                    │
└───────────┬─────────────────────┬───────────────────┘
            │                     │
       {:noise, reason}    {:signal, weight}
            │                     │
            ▼                     │
  ┌─────────────────────┐         │
  │  Short-Circuit Path  │         │
  │                     │         │
  │  - No LLM call       │         │
  │  - Memory.append     │         │
  │    (user msg)        │         │
  │  - Noise ack to user │         │
  │  - Bus.emit(         │         │
  │    :signal_low_weight│         │
  │    )                 │         │
  │                     │         │
  │  Acks by reason:     │         │
  │    :empty      → ""  │         │
  │    :too_short  → 👍  │         │
  │    :pattern_match→ 👍│         │
  │    :low_weight → "Got│         │
  │                  it."│         │
  │    :llm_classified   │         │
  │              → "Noted│         │
  │                  ."  │         │
  └─────────────────────┘         │
                                  ▼
                    ┌─────────────────────────────────┐
                    │  PHASE 2 — FAST CLASSIFY         │
                    │  Classifier.classify_fast/2      │
                    │  (always synchronous, < 1ms)     │
                    │                                  │
                    │  Returns %Signal{confidence: :low}│
                    │                                  │
                    │  Mode (classify_mode/1):         │
                    │    :build    — build/create/make │
                    │    :execute  — run/trigger/send  │
                    │    :analyze  — report/metrics    │
                    │    :maintain — fix/update/migrate│
                    │    :assist   — help/explain/how  │
                    │                                  │
                    │  Genre (classify_genre/1):       │
                    │    :direct  — commands, !        │
                    │    :commit  — "i will", "i'll"   │
                    │    :decide  — approve/reject     │
                    │    :express — thanks/hate/love   │
                    │    :inform  — (default)          │
                    │                                  │
                    │  Type (classify_type/1):         │
                    │    question  — contains "?"      │
                    │    issue     — error/bug/crash   │
                    │    scheduling— remind/tomorrow   │
                    │    summary   — summarize/recap   │
                    │    general   — (default)         │
                    │                                  │
                    │  Format (classify_format/2):     │
                    │    :cli      → :command          │
                    │    :telegram → :message          │
                    │    :webhook  → :notification     │
                    │    :filesystem→:document         │
                    │                                  │
                    │  Weight (calculate_weight/1):    │
                    │    base 0.5                      │
                    │    + length_bonus  (max 0.2)     │
                    │    + question_bonus (+0.15)      │
                    │    + urgency_bonus  (+0.2)       │
                    │    - noise_penalty  (-0.3)       │
                    │    clamped [0.0, 1.0]            │
                    └──────────────┬──────────────────┘
                                   │
                                   │  (spawns async Task, fire-and-forget)
                                   ├────────────────────────────────────────────┐
                                   │                                            │
                                   ▼                                            ▼
                    ┌──────────────────────────┐      ┌────────────────────────────────┐
                    │  Synchronous signal used  │      │  PHASE 3 — ASYNC LLM ENRICH   │
                    │  immediately for routing  │      │  Classifier.classify_async/3   │
                    │  (plan mode check,        │      │                               │
                    │   context overlay, etc.)  │      │  ETS cache (SHA256 key, 10m)  │
                    │                           │      │  T=0.0, max_tokens=80         │
                    └──────────────────────────┘      │  Returns JSON:                │
                                                       │  {mode, genre, type, weight}  │
                                                       │                               │
                                                       │  On success:                  │
                                                       │  Bus.emit(:signal_classified, │
                                                       │    {signal, session_id,       │
                                                       │     source: :llm})            │
                                                       │                               │
                                                       │  confidence: :high (vs :low   │
                                                       │  from fast path)              │
                                                       └────────────────────────────────┘

Signal 5-tuple result: S = (Mode, Genre, Type, Format, Weight)
  Example: S = (:build, :direct, "request", :command, 0.87)
```

---

## 3. Context Assembly Flow (Two-Tier)

The system prompt is assembled in two tiers on every request. Tier 1 is a static base cached in
`:persistent_term`. Tier 2 is assembled fresh per request using a token-budget priority scheme.

```
┌───────────────────────────────────────────────────────────────────────────┐
│  TIER 1 — STATIC BASE                                                     │
│  Soul.static_base/0  (cached in :persistent_term at boot)                 │
│  ~0 cost per request after first call                                     │
│                                                                           │
│  Template: priv/prompts/SYSTEM.md                                         │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │  §1  Security Rules                                                 │  │
│  │  §2  Identity  (OSA — Optimal System Agent)                         │  │
│  │  §3  Signal System  (S = (M,G,T,F,W) explained)                     │  │
│  │  §4  Personality                                                    │  │
│  │  §5  Tool Usage Policy                                              │  │
│  │       └── {{TOOL_DEFINITIONS}}  ← interpolated at boot              │  │
│  │           Tools.list_tools_direct() serialized to JSON schema       │  │
│  │  §6  Task Management                                                │  │
│  │  §7  Doing Tasks  (REPRODUCE→ISOLATE→HYPOTHESIZE→TEST→FIX→VERIFY)  │  │
│  │  §8  Git Workflows                                                  │  │
│  │  §9  Output Formatting                                              │  │
│  │  §10 Proactiveness                                                  │  │
│  │  {{RULES}}  ← interpolated at boot (rules/*.md concatenated)        │  │
│  │  {{USER_PROFILE}}  ← interpolated at boot                           │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                                                           │
│  For Anthropic provider: wrapped in cache_control: {type: "ephemeral"}   │
│  → ~90% input token savings after first request in a billing period      │
└───────────────────────────────────────────────────────────────────────────┘
                                   │
                                   │  static_tokens  (counted once at boot)
                                   │
                                   ▼
┌───────────────────────────────────────────────────────────────────────────┐
│  TIER 2 — DYNAMIC CONTEXT  (assembled per-request)                        │
│  Context.build(state, signal)                                             │
│                                                                           │
│  Budget formula:                                                          │
│    dynamic_budget = max_tokens                                            │
│                   - response_reserve (4 096)                              │
│                   - conversation_tokens                                   │
│                   - static_tokens                                         │
│    (floor: 1 000 tokens)                                                  │
│                                                                           │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │  P1 — ALWAYS INCLUDED (no budget cap)                               │  │
│  │                                                                     │  │
│  │  signal_overlay   — Active Signal: MODE × GENRE (weight: W)        │  │
│  │                     Mode guidance (e.g. EXECUTE: be concise)        │  │
│  │                     Genre guidance (e.g. DIRECT: respond w/ action) │  │
│  │                     Weight guidance (brief | thorough)              │  │
│  │                                                                     │  │
│  │  runtime          — Timestamp, channel, session_id                  │  │
│  │                                                                     │  │
│  │  environment      — cwd, date, OS, Elixir/OTP version,              │  │
│  │                     provider/model, git branch, modified files,     │  │
│  │                     recent commits  (cached per message)            │  │
│  │                                                                     │  │
│  │  plan_mode        — Injected only when state.plan_mode == true      │  │
│  │                     Forces structured plan output, no tool calls    │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                                                           │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │  P2 — BUDGET-FITTED  (up to 40% of dynamic_budget)                  │  │
│  │                                                                     │  │
│  │  memory           — Memory.recall() filtered by relevance to        │  │
│  │                     latest user message (section overlap scoring)   │  │
│  │                     Falls back to full recall if no match           │  │
│  │                                                                     │  │
│  │  task_state       — TaskTracker.get_tasks(session_id)               │  │
│  │                     Active task list with status icons              │  │
│  │                     (✔ completed, ◼ in_progress, ✘ failed, ◻ todo) │  │
│  │                                                                     │  │
│  │  workflow         — Workflow.context_block(session_id)              │  │
│  │                     Active workflow state if any                    │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                                                           │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │  P3 — BUDGET-FITTED  (up to 30% of dynamic_budget)                  │  │
│  │                                                                     │  │
│  │  intelligence     — CommProfiler.get_profile(user_id)               │  │
│  │                     formality, avg_length, common_topics            │  │
│  │                     "Adapt tone to match this user's style"         │  │
│  │                                                                     │  │
│  │  cortex_bulletin  — Cortex.bulletin()                               │  │
│  │                     LLM-synthesized knowledge bulletin:             │  │
│  │                     Current Focus, Pending Items, Key Decisions,    │  │
│  │                     Patterns, Context  (refreshed every 5 min)      │  │
│  │                     First synthesis: 30s after boot                 │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                                                           │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │  P4 — REMAINING BUDGET                                              │  │
│  │                                                                     │  │
│  │  os_templates     — OS.Registry.prompt_addendums()                  │  │
│  │                     OS-level prompt extensions                      │  │
│  │                                                                     │  │
│  │  machines         — Machines.prompt_addendums()                     │  │
│  │                     Connected machine context                       │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                                                           │
│  Token estimator priority:                                                │
│    1. Go tokenizer NIF (accurate BPE count)                               │
│    2. Heuristic fallback (word + punctuation estimate)                    │
│                                                                           │
│  Blocks that exceed remaining budget are truncated with "[...truncated]"  │
└───────────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
                     %{messages: [system_msg | conversation]}
```

**Provider-specific system message encoding:**

```
Anthropic:                          All other providers:
┌──────────────────────────┐        ┌──────────────────────────────┐
│ role: "system"           │        │ role: "system"               │
│ content: [               │        │ content: static_base         │
│   {type: "text",         │        │          <> "\n\n"           │
│    text: static_base,    │        │          <> dynamic_context  │
│    cache_control:        │        └──────────────────────────────┘
│     {type:"ephemeral"}}, │
│   {type: "text",         │
│    text: dynamic_context}│
│ ]                        │
└──────────────────────────┘
```

---

## 4. ReAct Loop Flow

The ReAct (Reasoning + Acting) loop in `agent/loop.ex` is the core execution engine. It runs up to
30 iterations, executing tool calls and re-prompting until the LLM returns a final response with no
tool calls.

```
Context.build(state, signal) → %{messages: [...]}
    │
    ▼
Bus.emit(:llm_request, {session_id, iteration})
    │
    ▼
┌──────────────────────────────────────────────────┐
│  Providers.chat_stream(messages, callback, opts) │
│                                                  │
│  Streaming callback:                             │
│    {:text_delta, text}   → Bus.emit(:system_event,│
│                             :streaming_token)    │
│    {:thinking_delta, t}  → Bus.emit(:system_event,│
│                             :thinking_delta)     │
│    {:done, result}       → stash in Process dict │
│                                                  │
│  opts:                                           │
│    tools: state.tools                            │
│    temperature: 0.7  (or tier-specific)          │
│    thinking: {type: "adaptive"}  (Opus only)     │
│           or {type: "enabled",                   │
│              budget_tokens: 5000}                │
└────────────────┬─────────────────────────────────┘
                 │
Bus.emit(:llm_response, {session_id, duration_ms, usage})
                 │
                 ▼
        ┌────────────────────┐
        │   Parse Response   │
        └────────┬───────────┘
                 │
         Has tool_calls?
     ┌───────────┴───────────┐
    Yes                      No
     │                       │
     ▼                       ▼
┌──────────────┐    ┌──────────────────────┐
│ Append asst  │    │ Return final response │
│ msg to state │    │ → Memory.append(asst) │
│ (with        │    │ → Bus.emit(           │
│  tool_calls  │    │    :agent_response)   │
│  + thinking  │    │ → {:reply, {:ok, resp}│
│  blocks)     │    │    state}             │
└──────┬───────┘    └──────────────────────┘
       │
       │ For each tool_call in tool_calls:
       │
       ▼
┌──────────────────────────────────────────────────┐
│  PRE_TOOL_USE HOOKS  (synchronous, can block)    │
│  Hook chain — priority ordered:                  │
│                                                  │
│  p=8  spend_guard        — blocks if budget      │
│                             limit exceeded       │
│  p=10 security_check     — blocks dangerous      │
│                             shell commands       │
│                             (ShellPolicy.validate)│
│  p=12 context_optimizer  — warns after 20 tools  │
│  p=15 mcp_cache          — inject cached schema  │
│  p=20 budget_tracker     — annotate payload      │
│                                                  │
│  {:blocked, reason} → tool_result = "Blocked: ." │
│  {:ok, payload}     → continue to execution     │
└──────────────────────┬───────────────────────────┘
                       │
                       ▼
           Bus.emit(:tool_call, {name, :start, args})
                       │
                       ▼
              Tools.execute(name, args)
                       │
              ┌────────┴────────┐
              │                 │
           {:ok, _}       {:error, reason}
              │                 │
        (image or text)  "Error: #{reason}"
              │
              ▼
┌──────────────────────────────────────────────────┐
│  POST_TOOL_USE HOOKS  (async, fire-and-forget)   │
│  Hook chain — priority ordered:                  │
│                                                  │
│  p=15 mcp_cache_post     — cache schema result   │
│  p=25 cost_tracker       — record API spend      │
│  p=30 error_recovery     — emit recovery hints   │
│  p=50 learning_capture   — emit tool_learning    │
│  p=60 episodic_memory    — write to JSONL        │
│                             (~/.osa/learning/)   │
│  p=80 metrics_dashboard  — write daily.json      │
│  p=85 auto_format        — suggest formatter     │
│                             (.ex→mix format,     │
│                              .go→gofmt, etc.)    │
│  p=90 telemetry          — emit tool_telemetry   │
│  p=95 hierarchical_      — emit compaction warn  │
│        compaction           at 50/80/90/95% util │
└──────────────────────────────────────────────────┘
                       │
                       ▼
       Bus.emit(:tool_call,   {name, :end, duration_ms})
       Bus.emit(:tool_result, {name, result, success})
                       │
                       ▼
        Append tool result message to state.messages
           %{role: "tool", tool_call_id: id,
             content: result_str | image_block}
                       │
                       ▼
                  iteration += 1
                       │
              iteration >= 30?
          ┌────────────┴────────────┐
         Yes                       No
          │                        │
          ▼                        │
  "I've reached my              re-prompt
   reasoning limit."          (recurse to
                                top of loop)

Context overflow recovery:
  If LLM returns context_length error AND iteration < 3:
    → Compactor.maybe_compact(state.messages)
    → retry run_loop with compacted history
  After 3 attempts: return overflow message to user
```

---

## 5. SSE Event Streaming

OSA streams all internal events through a three-tier event bus to the connected TUI or HTTP client
in real time.

```
Agent loop internal event
    │
    ▼
┌────────────────────────────────────────────────────────────────┐
│  Events.Bus  (goldrush-backed internal event bus)              │
│  Bus.emit(event_type, payload)                                 │
│                                                                │
│  Event types emitted by the agent:                             │
│    :llm_request       — LLM call starting (session, iteration) │
│    :llm_response      — LLM call done (duration_ms, usage)     │
│    :tool_call         — tool start/end (name, phase, args, ms) │
│    :tool_result       — tool output (name, result, success)    │
│    :agent_response    — final response (response, signal)      │
│    :signal_classified — async enriched signal (signal, source) │
│    :system_event      — all other events (see subtypes below)  │
│                                                                │
│  :system_event subtypes:                                       │
│    streaming_token          — per-token text delta             │
│    thinking_delta           — per-token thinking delta         │
│    signal_low_weight        — noise gate triggered             │
│    context_pressure         — context utilization update       │
│    hook_blocked             — pre_tool_use block               │
│    tool_learning            — learning capture event           │
│    error_detected           — error recovery triggered         │
│    tool_telemetry           — timing metrics                   │
│    compaction_warning/      — context window pressure          │
│     needed/critical                                            │
│    pattern_detected         — repeated tool usage (count >= 5) │
│    task_created/updated     — task state changes               │
│    swarm_started/completed/ — swarm lifecycle events           │
│     failed/cancelled/timeout                                   │
│    orchestrator_task_started/agent_started/                    │
│     agent_progress/agent_completed/wave_started/              │
│     task_completed                                             │
│    budget_warning/exceeded  — spend limit alerts               │
│    swarm_intelligence_started/round/converged/completed        │
└────────────────────────────────┬───────────────────────────────┘
                                 │
                                 ▼
┌────────────────────────────────────────────────────────────────┐
│  Bridge.PubSub  (goldrush → Phoenix.PubSub)                    │
│                                                                │
│  Three-tier fan-out:                                           │
│    Tier 1  "osa:events"             — all events (firehose)    │
│    Tier 2  "osa:session:{id}"       — scoped by session_id     │
│    Tier 3  "osa:type:{event_type}"  — scoped by event type     │
└────────────────────────────────┬───────────────────────────────┘
                                 │
                                 ▼
┌────────────────────────────────────────────────────────────────┐
│  HTTP SSE Controller  (GET /api/v1/stream/:session_id)         │
│                                                                │
│  Subscribes to:  "osa:session:{session_id}"                    │
│                                                                │
│  Each {:osa_event, event} received → serialized as:           │
│                                                                │
│  event: <event_type>                                           │
│  data: <JSON payload>                                          │
│  (blank line)                                                  │
│                                                                │
│  Keepalive: ": keep-alive\n\n" every 15s                       │
│                                                                │
│  Auth: JWT required (or anonymous in dev mode)                 │
└────────────────────────────────┬───────────────────────────────┘
                                 │  HTTP chunked response
                                 │  Content-Type: text/event-stream
                                 │  Cache-Control: no-cache
                                 ▼
┌────────────────────────────────────────────────────────────────┐
│  SSEClient (client/sse.go)   — Go TUI                          │
│                                                                │
│  SSEClient.ListenCmd(p *tea.Program) tea.Cmd                   │
│    GET /api/v1/stream/{session_id}                             │
│    Authorization: Bearer {token}                               │
│    Reconnect: exponential backoff (1s→32s, max 10 attempts)    │
│    Buffer: 1 MB per line                                       │
│                                                                │
│  parseSSEEvent(eventType, data) → tea.Msg                      │
│                                                                │
│  Event type → Go struct mapping:                               │
│    "agent_response"    → AgentResponseEvent                    │
│    "tool_call"         → ToolCallStartEvent | ToolCallEndEvent │
│                          (phase field: "start" | "end")        │
│    "llm_request"       → LLMRequestEvent                       │
│    "llm_response"      → LLMResponseEvent                      │
│    "streaming_token"   → StreamingTokenEvent                   │
│    "tool_result"       → ToolResultEvent                       │
│    "signal_classified" → SignalClassifiedEvent                 │
│    "system_event"      → parseSystemEvent() dispatcher         │
│      ├── streaming_token, thinking_delta                       │
│      ├── context_pressure                                      │
│      ├── orchestrator_*  (task/agent/wave lifecycle)           │
│      ├── swarm_*, swarm_intelligence_*                         │
│      ├── hook_blocked, budget_warning, budget_exceeded         │
│      ├── task_created, task_updated                            │
│      └── (unknown → SSEParseWarning toast)                     │
│                                                                │
│  p.Send(msg) → Bubbletea message dispatch → app.Update(msg)   │
└────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
                    TUI renders in real time:
                      - Streaming token accumulation
                      - Tool call progress indicators
                      - Signal badge (Mode × Genre)
                      - Context pressure bar
                      - Swarm/orchestrator wave progress
```

---

## 6. Plan Mode Decision

Plan Mode intercepts high-weight action signals before tool execution. The agent generates a
structured plan and waits for user approval. Only modes that involve destructive or creative action
are eligible.

```
Signal classified: S = (Mode, Genre, Type, Format, Weight)
    │
    ▼
should_plan?(signal, state)?
    │
    ├── state.plan_mode_enabled == false?
    │       └── No → direct execution
    │
    ├── state.plan_mode == true (already in plan mode)?
    │       └── Yes → skip (prevent re-entry)
    │
    ├── signal.mode NOT IN [:build, :execute, :maintain]?
    │       └── Yes → direct execution
    │               (:analyze excluded — read-only, no plan needed)
    │
    ├── signal.weight < 0.75?
    │       └── Yes → direct execution (low-confidence signals bypass)
    │
    ├── signal.type NOT IN ["request", "general"]?
    │       └── Yes → direct execution
    │
    └── All conditions met? → ENTER PLAN MODE
            │
            ▼
    ┌────────────────────────────────────────┐
    │  Plan Mode Execution                   │
    │                                        │
    │  state.plan_mode = true                │
    │  Context.build(state, signal)          │
    │    → P1 block: plan_mode overlay       │
    │       injected (no tools, structured   │
    │       output format)                   │
    │                                        │
    │  llm_chat(state, messages, tools: [])  │
    │    temperature: 0.3 (deterministic)    │
    │    NO tool definitions sent            │
    │                                        │
    │  LLM output format:                    │
    │    ### Goal                            │
    │    One sentence.                       │
    │    ### Steps                           │
    │    1. Concrete action                  │
    │    2. Concrete action                  │
    │    ### Files                           │
    │    List of files to create/modify      │
    │    ### Risks                           │
    │    Edge cases, breaking changes        │
    │    ### Estimate                        │
    │    trivial / small / medium / large    │
    └──────────────┬─────────────────────────┘
                   │
                   ▼
    {:reply, {:plan, plan_text, signal}, state}
                   │
                   ▼
         Channel displays plan to user
                   │
                   ▼
         User decision:
    ┌──────────┴──────────┐
   Approve              Reject / Modify
    │                       │
    ▼                       ▼
process_message(           User sends revised
  session_id, msg,         request or
  skip_plan: true)         alternative
    │
    ▼
Bypass should_plan?
→ direct execution path
  (state.plan_mode = false,
   normal run_loop with tools)

Override: User types "/plan" explicitly
    │
    ▼
Force plan mode regardless of signal weight
(CLI command handler sets plan_mode_enabled: true
 for that session)
```

---

## 7. Provider Routing

The provider and model for each request are resolved through a multi-stage priority chain. Every
one of the 18 supported providers accepts a `:model` option override.

```
Request arrives at Agent.Loop
    │
    ▼
┌────────────────────────────────────────────────────────────────┐
│  PROVIDER RESOLUTION  (priority order, first match wins)       │
│                                                                │
│  1. Per-call override  (SDK passthrough)                       │
│     opts[:provider] / opts[:model] from process_message/3     │
│     → apply_overrides(state, opts)                             │
│     Example: SDK call with provider: :anthropic, model: "..."  │
│                                                                │
│  2. Per-session override  (set by /model command)              │
│     state.provider / state.model fields on Loop GenServer      │
│     Persists for the lifetime of the session GenServer         │
│                                                                │
│  3. Tier-based routing  (agent dispatch / swarm workers)       │
│     Agent.Tier.model_for(tier, provider)                       │
│       :elite      → opus-class                                 │
│         anthropic: claude-opus-4-6                             │
│         openai:    gpt-4o                                      │
│         google:    gemini-2.5-pro                              │
│         groq:      llama-3.3-70b-versatile                     │
│       :specialist → sonnet-class                               │
│         anthropic: claude-sonnet-4-6                           │
│         openai:    gpt-4o-mini                                 │
│         google:    gemini-2.0-flash                            │
│       :utility    → haiku-class                                │
│         anthropic: claude-haiku-4-5-20251001                   │
│         openai:    gpt-3.5-turbo                               │
│         google:    gemini-2.0-flash-lite                       │
│                                                                │
│  4. Config default  (config/runtime.exs)                       │
│     Application.get_env(:optimal_system_agent, :default_       │
│       provider, :ollama)                                       │
│     Provider auto-detection at boot:                           │
│       OSA_DEFAULT_PROVIDER env                                 │
│       → ANTHROPIC_API_KEY present?                             │
│       → OPENAI_API_KEY present?                                │
│       → GROQ_API_KEY present?                                  │
│       → OPENROUTER_API_KEY present?                            │
│       → ollama fallback (http://localhost:11434)               │
└───────────────────────────┬────────────────────────────────────┘
                            │
                            ▼
┌────────────────────────────────────────────────────────────────┐
│  OLLAMA TIER DETECTION  (local models only)                    │
│  Agent.Tier.detect_ollama_tiers/0  — called at boot            │
│                                                                │
│  GET /api/tags → [{name, size_bytes}]                          │
│  Sort by size descending                                       │
│                                                                │
│  1 model:   elite=model, specialist=model, utility=model       │
│  2 models:  elite=large, specialist=small, utility=small       │
│  3+ models: elite=largest, specialist=middle, utility=smallest │
│                                                                │
│  Overrides:  set_tier_override(tier, model)                    │
│              stored in :persistent_term {:osa_tier_overrides}  │
│              merged on top of size-based assignment            │
└───────────────────────────┬────────────────────────────────────┘
                            │
                            ▼
┌────────────────────────────────────────────────────────────────┐
│  TOOL GATING  (Ollama small models)                            │
│                                                                │
│  Tools are stripped for models that cannot handle them:        │
│    Model size < 7 GB  → tools: []  (no tool definitions)       │
│    Model not in known tool-capable prefix list → tools: []     │
│    Known capable prefixes: llama3, mistral, qwen2.5, etc.      │
│                                                                │
│  Prevents hallucinated tool calls from small local models.     │
│  Full tools list sent only to verified capable models.         │
└───────────────────────────┬────────────────────────────────────┘
                            │
                            ▼
┌────────────────────────────────────────────────────────────────┐
│  TOKEN BUDGETS PER TIER                                        │
│                                                                │
│  Tier         total    system  agent   tools   conv   exec    │
│  ─────────────────────────────────────────────────────────    │
│  :elite       250 000  20 000  30 000  20 000  60 000  75 000 │
│  :specialist  200 000  15 000  25 000  15 000  50 000  60 000 │
│  :utility     100 000   8 000  12 000   8 000  25 000  30 000 │
│                                                                │
│  Max iterations per tier:                                      │
│    :elite       25                                             │
│    :specialist  15                                             │
│    :utility      8                                             │
│                                                                │
│  Temperature per tier:                                         │
│    :elite       0.5  (more creative)                           │
│    :specialist  0.4                                            │
│    :utility     0.2  (more deterministic)                      │
│                                                                │
│  Max response tokens per tier:                                 │
│    :elite       8 000                                          │
│    :specialist  4 000                                          │
│    :utility     2 000                                          │
│                                                                │
│  Complexity → tier mapping:                                    │
│    1–3  → :utility                                             │
│    4–6  → :specialist                                          │
│    7–10 → :elite                                               │
└────────────────────────────────────────────────────────────────┘

Providers.chat(messages, opts)  /  Providers.chat_stream(messages, cb, opts)
    Both accept:  provider: atom,  model: string  as opts
    All 18 providers route via Providers.Registry dispatcher:
      anthropic, openai, google, deepseek, mistral, cohere, groq,
      fireworks, together, replicate, openrouter, perplexity,
      qwen, zhipu, moonshot, baichuan, volcengine, ollama
```

---

## 8. End-to-End Timing Reference

```
Message received by channel
    │
    │  < 1ms   Noise filter tier 1 (deterministic)
    │  < 1ms   Signal classify_fast (deterministic)
    │
    ▼
Noise?  → short-circuit (< 2ms total, no LLM)
    │
    │  ~0ms    Context.build — static base from :persistent_term cache
    │  ~5ms    Context.build — dynamic context assembly + token counting
    │
    │  ~200ms–2s  LLM call (first token, streaming begins)
    │              → streaming_token events emitted per delta
    │
    │  ~50–500ms per tool  (tool execution)
    │   └── pre hooks (sync, < 5ms for security/budget)
    │   └── tool execute
    │   └── post hooks (async, fire-and-forget)
    │
    │  (repeat per iteration, max 30)
    │
    ▼
agent_response event emitted
    │
    │  < 1ms   Phoenix.PubSub broadcast to session topic
    │  < 1ms   SSE controller serializes + sends chunk
    │  < 1ms   Go TUI receives, parses, renders
    │
    ▼
User sees final response

Background (async, non-blocking):
    ~200ms  classify_async LLM enrichment (ETS-cached after first call)
    ~5min   Cortex bulletin refresh cycle (LLM synthesis of memory)
```

---

## 9. Swarm / Multi-Agent Dispatch

When the LLM calls the `orchestrate` tool, work fans out to multiple agents.

```
ReAct Loop (agent/loop.ex)
    │
    │  LLM returns tool_call: orchestrate({pattern: "debug-swarm", task: "..."})
    │
    ▼
┌──────────────────────────────────────────────────────────────────────┐
│  SWARM ORCHESTRATOR (swarm/orchestrator.ex)                          │
│                                                                      │
│  1. Resolve pattern → preset config (from priv/swarms/patterns.json) │
│     ┌──────────────────────────────────────────────────────┐        │
│     │ Presets: code-analysis, full-stack, debug-swarm,     │        │
│     │ performance-audit, security-audit, documentation,    │        │
│     │ adaptive-debug, adaptive-feature, concurrent-        │        │
│     │ migration, ai-pipeline, review-cycle                 │        │
│     └──────────────────────────────────────────────────────┘        │
│                                                                      │
│  2. Assign agents from roster (agent/roster.ex)                      │
│     Role → Agent: lead→master-orchestrator, backend→backend-go, etc. │
│     Each agent gets tier-based model: elite→opus, specialist→sonnet  │
│                                                                      │
│  3. Select execution pattern                                         │
│     ┌──────────┬──────────┬──────────┬──────────────┐               │
│     │ parallel │ pipeline │ debate   │ review_loop  │               │
│     │ all at   │ A→B→C    │ all+crit │ code+review  │               │
│     │ once     │ chain    │ evaluate │ iterate      │               │
│     └──────────┴──────────┴──────────┴──────────────┘               │
│                                                                      │
│  4. Execute (max 10 agents, max 10 concurrent swarms, 5min timeout)  │
│                                                                      │
│     PARALLEL:                                                        │
│       ┌─────────┐  ┌─────────┐  ┌─────────┐                        │
│       │ Agent A │  │ Agent B │  │ Agent C │   (all independent)     │
│       └────┬────┘  └────┬────┘  └────┬────┘                        │
│            └─────────┬──┘────────────┘                              │
│                      ▼                                              │
│               Merge results                                          │
│                                                                      │
│     PIPELINE:                                                        │
│       Agent A ──output──▶ Agent B ──output──▶ Agent C               │
│                                                                      │
│     DEBATE:                                                          │
│       Agent A ──┐                                                    │
│       Agent B ──┤──all proposals──▶ Critic Agent ──▶ verdict        │
│       Agent C ──┘                                                    │
│                                                                      │
│  5. Return merged/final result to ReAct loop as tool_result          │
│                                                                      │
│  Events emitted: swarm_started, swarm_completed/failed/cancelled    │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 10. Plan Mode Approval Gate

```
Signal classified with should_plan? = true
    │
    │  Conditions (ALL must be true):
    │    1. Mode = BUILD or EXECUTE or MAINTAIN
    │    2. Weight >= 0.75
    │    3. session has no skip_plan: true flag
    │    4. Not already in plan execution
    │    5. User didn't say "just do it" or similar override
    │
    ▼
┌──────────────────────────────────────────────────────────┐
│  PLAN GENERATION (no tools, text only)                    │
│                                                           │
│  LLM produces structured plan:                            │
│    Goal:     One sentence                                 │
│    Steps:    Numbered, specific, unambiguous               │
│    Files:    List of creates/modifies                     │
│    Risks:    Edge cases, breaking changes                 │
│    Estimate: trivial / small / medium / large             │
│                                                           │
│  Returns: {:plan, plan_text, signal}                      │
└──────────────────────┬────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────────┐
│  CHANNEL RESPONSIBILITY (approval gate)                   │
│                                                           │
│  CLI:  Display plan → prompt [Y/n/edit]                   │
│  HTTP: Return plan as SSE event → client handles UI       │
│  TUI:  Render plan → keyboard approve/reject              │
│                                                           │
│  User response:                                           │
│    ├── Approve → Loop re-enters with plan as context,     │
│    │             executes plan steps with tools            │
│    ├── Reject  → Plan discarded, user gives new input     │
│    └── Edit    → Modified plan re-submitted for approval  │
└──────────────────────────────────────────────────────────┘
```

---

## 11. Dynamic Context Block Details

The flow doc Section 3 showed the priority tiers. Here's what each block actually contains:

```
┌──────────────────────────────────────────────────────────────────┐
│  PRIORITY 1 — Always included                                     │
│                                                                   │
│  signal_overlay:                                                  │
│    Mode behavior text from mode_behaviors.md                      │
│    Genre behavior text from genre_behaviors.md                    │
│    Weight: {value}, classified signal tuple                       │
│                                                                   │
│  runtime:                                                         │
│    Channel: {http|cli|telegram|discord|...}                       │
│    Session: {session_id}                                          │
│    User: {user_id}                                                │
│    Timestamp: {ISO 8601}                                          │
│                                                                   │
│  environment:                                                     │
│    Working directory, OS, shell                                   │
│    Git branch + status (if git repo)                              │
│    Language runtimes detected                                     │
│                                                                   │
│  plan_mode:                                                       │
│    (only when plan mode active)                                   │
│    "You are in PLAN MODE. Do NOT execute tools..."                │
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│  PRIORITY 2 — Budget-fitted (40% of dynamic budget)               │
│                                                                   │
│  memory:                                                          │
│    Memory.recall_relevant(message, limit: budget)                 │
│    → keyword extraction → ETS episodic index → score by          │
│      relevance * recency → top-N within token budget             │
│                                                                   │
│  tasks:                                                           │
│    TaskTracker.get_tasks(session_id)                              │
│    → pending/in_progress tasks with descriptions                 │
│    → ordered by urgency, truncated to budget                     │
│                                                                   │
│  workflow:                                                        │
│    Workflow.get_active(session_id)                                │
│    → active workflow name, current step, state machine            │
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│  PRIORITY 3 — Budget-fitted (30% of remaining)                    │
│                                                                   │
│  intelligence:                                                    │
│    CommProfiler.get_profile(user_id)                              │
│    → user's communication style, preferences, patterns           │
│    → ContactDetector results (relationships mentioned)            │
│    → ConversationTracker multi-turn context                      │
│                                                                   │
│  cortex:                                                          │
│    Cortex.bulletin()                                              │
│    → LLM-synthesized knowledge summary, refreshed every ~5min    │
│    → cross-session patterns, decision history, active concerns   │
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│  PRIORITY 4 — Remaining budget                                    │
│                                                                   │
│  os_templates:                                                    │
│    Connected OS addendums (BusinessOS, ContentOS, DevOS, etc.)    │
│    → injected only when OS template is active                    │
│                                                                   │
│  machines:                                                        │
│    Connected machine addendums                                    │
│    → remote system capabilities, endpoints, credentials refs     │
└──────────────────────────────────────────────────────────────────┘
```

---

## 12. Noise Acknowledgment Strategy

When the noise filter short-circuits (no LLM call), OSA still responds:

```
Noise filter returns {:noise, reason}
    │
    ▼
┌──────────────────────────────────────────────────────┐
│  noise_acknowledgment/1 (loop.ex)                     │
│                                                       │
│  reason              │ response                       │
│  ────────────────────┼────────────────────────────── │
│  :empty              │ random emoji (👋 🤔 ...)       │
│  :too_short          │ random emoji                   │
│  :pattern_match      │ random emoji (greeting match)  │
│  :low_weight         │ "Got it." / "Noted." / brief   │
│                                                       │
│  Rationale:                                           │
│  - Empty/short → playful, signal "I'm here"           │
│  - Pattern match → acknowledge without wasting tokens  │
│  - Low weight → slightly more substantive, user tried  │
│    to say something but it wasn't complex enough for   │
│    full pipeline                                       │
│                                                       │
│  NO LLM CALL — zero tokens consumed for noise         │
└──────────────────────────────────────────────────────┘
```

---

## 13. Session Lifecycle

```
Client connects
    │
    ▼
┌──────────────────────────────────────────────────────┐
│  Session Creation                                     │
│                                                       │
│  POST /api/v1/sessions                                │
│    → SessionManager.create(user_id, channel, opts)    │
│    → Starts GenServer via Registry (via tuple)        │
│    → GenServer.init/1:                                │
│        1. Load or create session state                │
│        2. Fire :session_start hooks                   │
│           └── context_injection hook                  │
│           └── memory loading                          │
│        3. Return {:ok, state}                         │
│                                                       │
│  State: %{session_id, user_id, channel, messages,     │
│          signal: nil, plan_mode: false, ...}          │
└──────────────────────┬────────────────────────────────┘
                       │
                       ▼
            Session active (GenServer alive)
                       │
            ├── Process messages via {:process, msg, opts}
            ├── Crash recovery: Supervisor restarts
            │   └── State loaded from persistence
            ├── Timeout: GenServer terminates after idle
            │   └── :session_end hooks fire
            │   └── Learning consolidation
            │   └── Pattern save
            └── Explicit close: client disconnects
                └── Same cleanup as timeout
```

---

## See Also

- `lib/optimal_system_agent/agent/loop.ex` — ReAct loop implementation
- `lib/optimal_system_agent/signal/classifier.ex` — Signal 5-tuple classification
- `lib/optimal_system_agent/signal/noise_filter.ex` — Two-tier noise gate
- `lib/optimal_system_agent/agent/context.ex` — Two-tier context assembly
- `lib/optimal_system_agent/agent/hooks.ex` — Pre/post hook pipeline
- `lib/optimal_system_agent/agent/tier.ex` — Model tier routing
- `lib/optimal_system_agent/agent/cortex.ex` — Knowledge synthesis engine
- `lib/optimal_system_agent/bridge/pubsub.ex` — Event bus to PubSub bridge
- `lib/optimal_system_agent/channels/http/api.ex` — HTTP API + SSE endpoint
- `priv/go/tui/client/sse.go` — Go SSE client + event dispatcher
- `docs/architecture/signal-theory.md` — Signal Theory conceptual reference
