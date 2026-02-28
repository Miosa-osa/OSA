# OpenCode — Message Processing Flow

**Score**: 7/10
**Date**: 2026-03-01
**Purpose**: ASCII flow diagram of OpenCode's message processing pipeline, prompt caching architecture, doom loop detection, and structural gaps versus OSA.

---

## 1. High-Level Pipeline

```
┌─────────────────────────────────────────────────────────────────────┐
│                        USER INPUT                                   │
│                   (CLI / TUI / API call)                            │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│                   PROVIDER DETECTION                                │
│                                                                     │
│   Reads config → selects active provider                            │
│   anthropic | openai | gemini | groq | qwen | deepseek             │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│                 PROMPT FILE SELECTION                               │
│                                                                     │
│   .opencode/prompts/                                                │
│   ├── anthropic.txt   ◄── selected when provider = anthropic       │
│   ├── openai.txt      ◄── selected when provider = openai          │
│   ├── gemini.txt      ◄── selected when provider = gemini          │
│   ├── groq.txt        ◄── selected when provider = groq            │
│   ├── qwen.txt        ◄── selected when provider = qwen            │
│   └── deepseek.txt    ◄── selected when provider = deepseek        │
│                                                                     │
│   NOTE: 6 separate files = 6 places to maintain every rule change  │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│                  PROMPT ASSEMBLY (2-PART SPLIT)                     │
│                                                                     │
│   Part 1 — Static Cacheable Prefix                                  │
│   ┌─────────────────────────────────────────────────────────────┐  │
│   │  • Identity / persona block                                  │  │
│   │  • Behavioral rules                                          │  │
│   │  • Tool schemas (all tool definitions)                       │  │
│   │  • cache_control: ephemeral   ◄── Anthropic cache marker     │  │
│   └─────────────────────────────────────────────────────────────┘  │
│                                                                     │
│   Part 2 — Dynamic Per-Request Suffix                               │
│   ┌─────────────────────────────────────────────────────────────┐  │
│   │  • Current working directory                                  │  │
│   │  • Project context / recent state                            │  │
│   │  • Conversation history                                       │  │
│   │  • User message                                               │  │
│   └─────────────────────────────────────────────────────────────┘  │
│                                                                     │
│   No cache_control on Part 2 — changes every request               │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    PLAN FILE CHECK                                  │
│                                                                     │
│   Does .opencode/plan.md exist on disk?                             │
│                                                                     │
│        YES ──► Load plan into Part 2 suffix                         │
│         NO ──► Skip (no plan context injected)                      │
│                                                                     │
│   Plan is written to DISK, not held in-context only.               │
│   Survives process restarts and session breaks.                     │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     LLM API CALL                                    │
│                                                                     │
│   Standard mode:      Text response + optional tool_calls           │
│   Structured mode:    JSON-schema-constrained response              │
│                       (machine consumption, no free text)           │
│                                                                     │
│   Streaming: token-by-token via provider SSE                        │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                      ┌────────┴────────┐
                      │                 │
                      ▼                 ▼
               tool_calls?         text only?
               (yes)               (yes)
                      │                 │
                      │                 ▼
                      │        ┌────────────────┐
                      │        │  RENDER OUTPUT │
                      │        │  to terminal   │
                      │        └────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────────────┐
│                   TOOL EXECUTION LOOP                               │
│                                                                     │
│   ┌──────────────────────────────────────────────────────────┐     │
│   │  For each tool_call in response:                          │     │
│   │                                                           │     │
│   │    dispatch tool ──► execute ──► capture result           │     │
│   │                              │                            │     │
│   │                    success? ─┤                            │     │
│   │                              │                            │     │
│   │                      YES ──► append tool_result           │     │
│   │                              │   to conversation          │     │
│   │                       NO ──► increment failure counter    │     │
│   │                              │                            │     │
│   └──────────────────────────────┼────────────────────────── ┘     │
│                                  │                                  │
│                         DOOM LOOP CHECK                             │
│                         (see Section 3)                             │
└──────────────────────────────────┬──────────────────────────────────┘
                                   │
                         all tools done?
                                   │
                                   ▼
                      ┌────────────────────┐
                      │  Next LLM turn     │  ◄── loop back with
                      │  (with tool        │       tool results
                      │   results)         │       appended
                      └────────────────────┘
                                   │
                         no more tool_calls
                                   │
                                   ▼
                      ┌────────────────────┐
                      │   FINAL RESPONSE   │
                      │   Render to user   │
                      └────────────────────┘
```

---

## 2. Prompt Caching Architecture (Anthropic — Key Innovation)

```
REQUEST 1 (cold — cache miss)
═══════════════════════════════════════════════════════════════════════

  ┌──────────────────────────────────────────────────┐
  │  PART 1: Static Prefix              ~30K tokens   │
  │  ┌────────────────────────────────────────────┐  │
  │  │  Identity block                             │  │
  │  │  Behavioral rules                           │  │
  │  │  All tool schemas                           │  │
  │  │  ─────────────────────────────────────────  │  │
  │  │  cache_control: { type: "ephemeral" }  ◄──  │──┼── Anthropic
  │  └────────────────────────────────────────────┘  │    writes
  │                                                  │    to cache
  │  PART 2: Dynamic Suffix             ~5K tokens    │
  │  ┌────────────────────────────────────────────┐  │
  │  │  cwd + project context + user message       │  │
  │  └────────────────────────────────────────────┘  │
  └──────────────────────────────────────────────────┘

  Total billed: ~35K tokens (full Part 1 + Part 2)


REQUEST 2+ (warm — cache hit)
═══════════════════════════════════════════════════════════════════════

  ┌──────────────────────────────────────────────────┐
  │  PART 1: Static Prefix              CACHE HIT     │
  │  ┌────────────────────────────────────────────┐  │
  │  │  [served from Anthropic cache]              │  │  ◄── ~0.1x cost
  │  │  cache_control: { type: "ephemeral" }       │  │      vs full send
  │  └────────────────────────────────────────────┘  │
  │                                                  │
  │  PART 2: Dynamic Suffix             ~5K tokens    │
  │  ┌────────────────────────────────────────────┐  │
  │  │  cwd + project context + user message       │  │  ◄── billed normally
  │  └────────────────────────────────────────────┘  │
  └──────────────────────────────────────────────────┘

  Total billed: ~5K tokens (Part 2 only)
  Savings: 60–80% token cost reduction after first call


TOKEN COST COMPARISON
═══════════════════════════════════════════════════════════════════════

  Request   No Cache        With Cache      Delta
  ────────  ──────────────  ──────────────  ──────────────────────────
  1         35K (full)      35K (full)      —  (cache write overhead)
  2         35K (full)      5K (hit)        -85%
  3         35K (full)      5K (hit)        -85%
  10        350K total      80K total       -77%
  100       3.5M total      530K total      -85%

  Rule: static prefix must NOT change between requests.
  Any edit to identity/rules/tool schemas invalidates the cache.


WHAT MAKES PART 1 CACHEABLE
═══════════════════════════════════════════════════════════════════════

  STABLE (safe in Part 1)         UNSTABLE (must stay in Part 2)
  ──────────────────────────────  ──────────────────────────────
  Identity / persona              Current date/time
  Behavioral rules                Working directory
  Tool definitions                Conversation history
  Project-level instructions      Git status / recent commits
  Permission policies             User message content
                                  Plan file contents (if dynamic)
```

---

## 3. Doom Loop Detection

```
TOOL EXECUTION TIMELINE
═══════════════════════════════════════════════════════════════════════

  Turn 1:  tool_call(bash, "ls /nonexistent")
             └─► FAIL  ──► failure_counter = 1

  Turn 2:  tool_call(bash, "ls /nonexistent")   ◄── same call again
             └─► FAIL  ──► failure_counter = 2

  Turn 3:  tool_call(bash, "ls /nonexistent")   ◄── LLM stuck in loop
             └─► FAIL  ──► failure_counter = 3


DOOM LOOP CHECK (runs after each tool result)
═══════════════════════════════════════════════════════════════════════

  ┌─────────────────────────────────────────────────────────────┐
  │                                                             │
  │   current_tool_call == last_tool_call?                      │
  │                                                             │
  │        YES ──► increment consecutive_failure_count          │
  │         NO ──► reset consecutive_failure_count = 0          │
  │                                                             │
  │   consecutive_failure_count >= THRESHOLD?  (default: 3)     │
  │                                                             │
  │        YES ──► HALT                                         │
  │                │                                            │
  │                ▼                                            │
  │        ┌───────────────────────────────────────────────┐   │
  │        │  DOOM LOOP REPORT                             │   │
  │        │                                               │   │
  │        │  "Detected repeated tool failure:             │   │
  │        │   [tool_name] failed [N] times consecutively. │   │
  │        │   Last error: [error_message]                 │   │
  │        │   Stopping to prevent infinite loop."         │   │
  │        │                                               │   │
  │        │  Return report to user. Do NOT retry.         │   │
  │        └───────────────────────────────────────────────┘   │
  │                                                             │
  │         NO ──► continue tool execution loop                 │
  │                                                             │
  └─────────────────────────────────────────────────────────────┘


FAILURE COUNTER STATE MACHINE
═══════════════════════════════════════════════════════════════════════

  [0] ──► tool success      ──► [0]   (reset)
  [0] ──► tool fail (new)   ──► [1]
  [1] ──► tool fail (same)  ──► [2]
  [1] ──► tool fail (diff)  ──► [1]   (different failure, not a loop)
  [2] ──► tool fail (same)  ──► [3]   ──► HALT (threshold reached)
  [2] ──► tool success      ──► [0]   (reset)

  Key: "same" = identical tool name + identical arguments
```

---

## 4. Provider-Specific Prompt Selection Logic

```
CONFIG RESOLUTION
═══════════════════════════════════════════════════════════════════════

  config.toml / env vars
       │
       ▼
  provider = ?
       │
       ├── "anthropic"  ──► load .opencode/prompts/anthropic.txt
       │                    + apply 2-part cache_control split
       │
       ├── "openai"     ──► load .opencode/prompts/openai.txt
       │                    (no cache_control — OpenAI prefix caching
       │                     is automatic, not explicit)
       │
       ├── "gemini"     ──► load .opencode/prompts/gemini.txt
       │                    (Google context caching = separate API)
       │
       ├── "groq"       ──► load .opencode/prompts/groq.txt
       │
       ├── "qwen"       ──► load .opencode/prompts/qwen.txt
       │
       └── "deepseek"   ──► load .opencode/prompts/deepseek.txt


MAINTENANCE BURDEN
═══════════════════════════════════════════════════════════════════════

  Change a behavioral rule?
       │
       ▼
  Update anthropic.txt  ──► Update openai.txt  ──► Update gemini.txt
       │
       ▼
  Update groq.txt  ──► Update qwen.txt  ──► Update deepseek.txt
       │
       ▼
  Verify all 6 files are consistent  ◄── manual, no enforcement

  Risk: files drift out of sync. No single source of truth.
  OSA contrast: 1 unified prompt with provider-specific overrides.
```

---

## 5. Plan File Persistence

```
PLAN LIFECYCLE
═══════════════════════════════════════════════════════════════════════

  LLM decides to create a plan
       │
       ▼
  ┌─────────────────────────────────────────────┐
  │  WRITE to disk                              │
  │  path: .opencode/plan.md                   │
  │  content: structured task list / steps      │
  └─────────────────────────────────────────────┘
       │
       ▼
  Plan persists across:
  ├── session restarts       ◄── process can die, plan survives
  ├── provider switches      ◄── file is provider-agnostic
  └── long-running tasks     ◄── next session picks up where left off

  On next request:
       │
       ▼
  ┌─────────────────────────────────────────────┐
  │  CHECK: does .opencode/plan.md exist?        │
  │                                             │
  │  YES ──► read file ──► inject into Part 2   │
  │           suffix as plan context             │
  │                                             │
  │   NO ──► no plan context injected            │
  └─────────────────────────────────────────────┘

  Plan update (LLM rewrites steps as tasks complete):
       │
       ▼
  overwrite .opencode/plan.md with updated content
  (atomic write — no partial state)


IN-CONTEXT vs ON-DISK COMPARISON
═══════════════════════════════════════════════════════════════════════

  Approach          Survives Restart?   Tokens Used?   Drift Risk?
  ────────────────  ──────────────────  ─────────────  ───────────
  In-context only   NO                  Yes (always)   High
  On-disk (OpenCode) YES                Only if read   Low
  OSA task_write    YES (TaskTracker)   Injected T2    Low
```

---

## 6. Structured Output Mode

```
ACTIVATION
═══════════════════════════════════════════════════════════════════════

  Standard mode  ──► free text + optional tool_calls
  Structured mode ──► JSON only, constrained by schema


STRUCTURED OUTPUT FLOW
═══════════════════════════════════════════════════════════════════════

  ┌──────────────────────────────────────────────────────────┐
  │  Caller provides JSON schema                             │
  │  {                                                       │
  │    "type": "object",                                     │
  │    "properties": {                                       │
  │      "action": { "type": "string", "enum": [...] },      │
  │      "file":   { "type": "string" },                     │
  │      "reason": { "type": "string" }                      │
  │    },                                                    │
  │    "required": ["action", "file"]                        │
  │  }                                                       │
  └──────────────────────┬───────────────────────────────────┘
                         │
                         ▼
  ┌──────────────────────────────────────────────────────────┐
  │  LLM API call with response_format constraint            │
  │  (Anthropic: tool schema trick)                          │
  │  (OpenAI: response_format: { type: "json_schema" })      │
  └──────────────────────┬───────────────────────────────────┘
                         │
                         ▼
  ┌──────────────────────────────────────────────────────────┐
  │  Response is guaranteed-valid JSON matching schema       │
  │  No free text. No markdown. No explanation.              │
  │                                                          │
  │  {                                                       │
  │    "action": "edit",                                     │
  │    "file": "src/main.go",                                │
  │    "reason": "fix null pointer on line 42"               │
  │  }                                                       │
  └──────────────────────┬───────────────────────────────────┘
                         │
                         ▼
  Caller parses JSON directly — no natural language parsing needed

  USE CASES: CI pipelines, agent orchestrators, batch processors,
             any machine-to-machine consumption of LLM output.
```

---

## 7. What OpenCode Does NOT Have

```
ABSENT CAPABILITIES
═══════════════════════════════════════════════════════════════════════

  Signal Classification
  ─────────────────────
  No pre-LLM classification of message mode, genre, or intent.
  Every input goes to LLM regardless of whether it's a greeting,
  a one-word ack, or a complex architectural request.
  Cost: pays full LLM tokens for noise.

  Unified Prompt / Single Source of Truth
  ────────────────────────────────────────
  6 separate provider prompt files with no enforcement of
  consistency across them. Rules must be replicated manually.
  Cost: maintenance burden scales linearly with provider count.

  Personality / Adaptive Behavior
  ────────────────────────────────
  No SOUL layer. No mode-adaptive response style.
  Identity is a static text block, not a behavioral system.
  Cost: responses have no stylistic coherence across providers.

  Multi-Agent / Swarm Orchestration
  ──────────────────────────────────
  No wave execution, no parallel agent dispatch, no role-based
  agent selection. Single-agent execution only.
  Cost: complex tasks run sequentially with no parallelism.

  Hook Pipeline / Middleware
  ──────────────────────────
  No pre/post tool hooks, no session lifecycle events.
  No plugin injection points without modifying source.
  Cost: no extensibility without forking.

  Noise Filtering
  ───────────────
  No deterministic or LLM-based noise filter.
  Every user message pays full LLM invocation cost.

  Provider Failover
  ─────────────────
  No automatic fallback to alternate provider or auth profile
  on failure. Single-provider execution per session.

  Learning / Self-Improvement
  ─────────────────────────────
  No SICA loop (Observe → Reflect → Propose → Test → Integrate).
  No pattern consolidation. No cross-session skill generation.
  Behavior is static — what ships is what runs.
```

---

## 8. OpenCode vs OSA: Architecture Comparison

```
OPENCODE PIPELINE                    OSA PIPELINE
═════════════════════                ════════════
User input (CLI/TUI)                 User → LineEditor.readline
  │                                    │
  ▼                                    ▼
Provider detection                   sanitize_input()  [NFC + ctrl strip]
  │                                    │
  ▼                                    ▼
Load provider .txt file              Classifier.classify() → S=(M,G,T,F,W)
  │                                    │
  ▼                                    ▼
2-part prompt assembly               NoiseFilter (2-tier: deterministic + LLM)
  ├── Part 1: static + cache_control   │
  └── Part 2: dynamic suffix           ▼
  │                                  Context.build() (4-tier token budget)
  ▼                                    ├── T1: Identity + SOUL
Load plan.md if exists               │   ├── T2: Signal overlay + task state
  │                                  │   ├── T3: User context + environment
  ▼                                  │   └── T4: Conversation history
LLM API call                         │
  │                                    ▼
  ▼                                  Providers.Registry.chat()
Tool execution loop                    │
  ├── doom loop detection              ▼
  └── failure counter                Tool loop (max 30 iterations)
  │                                    ├── Hooks.run(:pre_tool_use)
  ▼                                    ├── Skills.execute()
Render response                      │   ├── doom loop equivalent:
  │                                  │   │   consecutive_fail check
  ▼                                  │   └── bail after threshold
DONE                                 │   └── Hooks.run_async(:post_tool_use)
                                       │
                                       ▼
                                     Markdown.render() + ANSI
                                       │
                                       ▼
                                     Status line (signal mode/genre/weight)


OPENCODE STRENGTHS                   OSA STRENGTHS
──────────────────────────────────   ──────────────────────────────────
Explicit cache_control on Anthropic  Signal Theory classification (unique)
Plan.md disk persistence             Unified prompt (1 source of truth)
Structured output mode               18 providers + tool gating by size
6-provider prompt coverage           Hook pipeline (extensible middleware)
Clean 2-part caching split           Wave execution + swarm orchestration
                                     Learning engine (SICA loop)
                                     Status line with signal info
                                     Extended thinking (per-tier budgets)

OPENCODE GAPS vs OSA                 OSA GAPS vs OPENCODE
──────────────────────────────────   ──────────────────────────────────
No signal classification             No explicit cache_control (OPEN)
No unified prompt file               No structured output mode
No hook pipeline                     No /compact or /context commands
No multi-agent execution             No diff display for file edits
No noise filtering                   No image/vision support
No adaptive personality
No learning / self-improvement
```

---

*Generated by Technical Writer agent.*
*Source: OpenCode architecture analysis, OSA pipeline-comparison.md, competitor docs.*
