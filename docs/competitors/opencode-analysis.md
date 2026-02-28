# OpenCode System Prompt Analysis

> Competitor: OpenCode (sst/opencode)
> Score: 7/10
> Category: CLI Coding Agent (terminal-first)
> Threat Level: MEDIUM
> Analysis date: 2026-03-01

---

## Purpose

This document dissects the OpenCode system prompt architecture — its structural innovations, failure modes, and what OSA has adopted (and rejected) from it. OpenCode contains the single most important prompt engineering innovation seen in any open-source agent to date: the two-part Anthropic caching split.

---

## 1. Architecture Overview

OpenCode's system prompt totals approximately 500 lines, but that count is misleading. The prompt is not a single file — it is a set of provider-specific files selected and assembled at runtime:

```
opencode/
└── prompts/
    ├── anthropic.txt      ← Anthropic Claude (primary, cache-split architecture)
    ├── gemini.txt         ← Google Gemini (adapted for thinking mode)
    ├── openai.txt         ← OpenAI GPT-4 series
    ├── qwen.txt           ← Qwen 2.5 (tuned for Chinese reasoning quirks)
    ├── default.txt        ← Fallback for unknown providers
    └── shared/
        ├── tools.txt      ← Tool definitions (provider-agnostic)
        └── persona.txt    ← Identity and voice (shared baseline)
```

At session start, the runtime selects the appropriate provider file and composes the final prompt:

```
Final prompt = [provider_file] + [tools.txt] + [persona.txt] + [dynamic_suffix]
```

The `dynamic_suffix` contains session-specific state: the current plan, recent errors, and workspace context. This is the variable part that changes per turn.

The architecture's key insight: the static portion (provider_file + tools.txt + persona.txt) never changes within a session. The dynamic suffix is typically 200-400 tokens. This separation is not just organization — it is the foundation for the caching strategy.

---

## 2. What Makes It Good

### 2.1 Prompt Caching — The Key Innovation

This is the single best architectural decision in any open-source AI agent system prompt. OpenCode's `anthropic.txt` is structured to maximize Anthropic's prompt caching:

```
┌─────────────────────────────────────────────────────────────┐
│  PART 1: CACHEABLE PREFIX (~400-450 tokens)                 │
│  ─────────────────────────────────────────────────────────  │
│  - Agent identity and role                                  │
│  - Full tool definitions (read_file, write_file, shell…)    │
│  - Behavioral constraints                                   │
│  - Code style preferences                                   │
│  - Error handling instructions                              │
│  │                                                          │
│  [cache_control: {"type": "ephemeral"}]  ← cache boundary  │
│  ─────────────────────────────────────────────────────────  │
│  PART 2: DYNAMIC SUFFIX (~50-200 tokens, NOT cached)        │
│  - Current plan state                                       │
│  - Session workspace context                                │
│  - Active error context (if any)                            │
└─────────────────────────────────────────────────────────────┘
```

On every turn after the first, Anthropic's API returns the Part 1 tokens from cache. The billing reads:
- Part 1: cache read tokens (approximately 10% of full input price)
- Part 2: fresh input tokens (standard price)

For a session with 30 turns and a 450-token system prompt prefix:

```
Without caching:  30 turns × 450 tokens = 13,500 tokens billed at input rate
With caching:     1 turn  × 450 tokens  = 450 tokens at input rate (cache write)
                  29 turns × 450 tokens = 13,050 tokens at cache read rate (~10%)

Savings:  13,050 × 0.90 = 11,745 tokens of savings per session
At claude-sonnet-4-6 pricing ($3/M input): ~$0.035 saved per session
At 10,000 sessions/day: ~$350/day, ~$128,000/year
```

This is not a rounding error. At scale, prompt caching on system prompts is a material cost reduction. The savings compound as session length grows — longer sessions mean more cache hits per cache write.

**Why competitors miss this**: The split only works if the system prompt is cleanly divided into stable-then-variable sections. Most agents build the full system prompt dynamically per turn (injecting memory, context, plan state into a single blob), which makes caching impossible. OpenCode's two-file architecture (static prefix + dynamic suffix) makes the cache boundary structurally enforced, not just hoped for.

**OSA's adoption**: This pattern was adopted in OSA's Anthropic provider. The `Context.build/2` in `Agent.Loop` constructs system messages with a stable prefix (identity + tools + skills) followed by a per-turn suffix (signal context + memory injection). The cache control header is applied to the prefix boundary.

### 2.2 Provider-Specific Prompt Files

Each model family has meaningfully different behavioral quirks, and OpenCode addresses this directly:

**`anthropic.txt`** — Exploits Claude's strength with structured XML-style thinking blocks. Instructions are written to leverage extended thinking mode when available. The file explicitly references Claude's preference for explicit reasoning chains.

**`gemini.txt`** — Adjusted for Gemini's different handling of tool call schemas. Gemini is more literal with tool definitions, so the file provides more explicit format examples. The system prompt also references Gemini's thinking budget parameter differently than Anthropic's.

**`qwen.txt`** — Tuned for Qwen 2.5's training distribution. Qwen performs better with Chinese-language instruction patterns even when responding in English. The file mixes instruction register accordingly.

**`default.txt`** — Conservative baseline that works acceptably across unknown models. Avoids model-specific tricks.

The insight is correct: "one prompt fits all" is a lie. A Claude and a Qwen model have different instruction-following behaviors that emerge from different training distributions. OpenCode acknowledges this; most competitors ignore it.

### 2.3 Plan File Persistence to Disk

OpenCode persists plan state to `.opencode/plan.md` in the workspace root. This file survives:
- Session crashes
- Process restarts
- CLI exits and re-entries

On next launch, if `.opencode/plan.md` exists, it is injected into the dynamic suffix automatically. The user does not need to re-explain the task context. This is the correct implementation of plan resumability.

Comparison of plan persistence across agents:

| Agent | Plan Storage | Survives Restart? |
|-------|-------------|-------------------|
| OpenCode | `.opencode/plan.md` (disk) | Yes |
| Windsurf | `plan.md` in workspace (disk) | Yes |
| Cursor | In-session Markdown (memory) | No |
| Cline | Per-turn in context window | No |
| OSA | `tasks/todo.md` (disk) | Yes (matches) |

OSA matches OpenCode here. The implementation in OSA uses `tasks/todo.md` which is written per plan creation and read at context build time. The persistence guarantee is equivalent.

### 2.4 Doom Loop Detection

OpenCode tracks consecutive tool failures in a counter. When the counter exceeds a configurable threshold (default: 3 consecutive failures), the agent halts and surfaces an explicit error:

```
Failure counter: 0 → 1 → 2 → 3 → HALT
"I've tried this approach 3 times and keep failing.
Here's what I know:
  - [summary of attempts]
  - [what failed each time]
Please tell me how to proceed differently."
```

This is a correct safety mechanism. Without it, agents enter retry loops that burn tokens and time, eventually timing out silently or producing garbage output on the final attempt.

The counter resets on:
- A successful tool execution
- A user message that changes direction
- Explicit "try again" instruction

The threshold is configurable via `.opencode/config.toml`:
```toml
[agent]
max_consecutive_failures = 3  # default
```

**OSA equivalent**: OSA's `run_loop` has an `iteration` counter with a `max_iterations` hard cap (default 30). Context overflow triggers compaction and retry (up to 3 attempts). However, OSA does not have OpenCode's explicit consecutive-failure-specific counter with user-surfaced explanation. This is a gap worth addressing — the iteration cap fires at 30 total iterations, not 3 consecutive failures on the same action.

### 2.5 Structured Output Mode

OpenCode supports a JSON-schema-constrained response mode for specific operations. When the agent needs to produce structured data (file diffs, task lists, dependency graphs), it switches to a constrained output mode that guarantees schema compliance:

```json
{
  "mode": "structured",
  "schema": {
    "type": "object",
    "properties": {
      "files_modified": {"type": "array", "items": {"type": "string"}},
      "summary": {"type": "string"},
      "next_step": {"type": "string"}
    }
  }
}
```

This is not cosmetic. Structured output eliminates JSON parsing failures and hallucinated field names — two common failure modes when asking LLMs to produce machine-readable output in free text mode. The schema acts as a contract between the agent and its downstream consumers.

---

## 3. What Makes It Bad

### 3.1 Per-Provider File Fragmentation

The six separate provider files are a maintenance liability. Any behavioral change that should apply to all models (e.g., "always cite the file and line number when referencing code") must be applied six times. Failure to propagate a change creates behavioral divergence across providers that is silent and hard to detect.

The correct architecture is a unified behavioral layer with provider-specific overrides, not six independent files:

```
Correct:
  base_prompt.txt         ← universal behavior (single source of truth)
  overrides/
    anthropic_overrides.txt   ← delta only: cache control, thinking mode
    gemini_overrides.txt      ← delta only: tool schema format
    qwen_overrides.txt        ← delta only: instruction register

What OpenCode has:
  anthropic.txt           ← full prompt, 500 lines
  gemini.txt              ← full prompt, 480 lines (90% identical to anthropic.txt)
  openai.txt              ← full prompt, 470 lines (95% identical to anthropic.txt)
  qwen.txt                ← full prompt, 490 lines
```

The six files currently share approximately 80-90% of their content through copy-paste. When a bug is found in the tool definition section, it must be patched in six places. This is a textbook DRY violation and will cause drift over time.

**OSA's approach**: OSA does not use per-provider prompt files. Provider-specific behavior is handled in the Elixir provider modules (`providers/anthropic.ex`, `providers/openai.ex`) at the API adapter level — request formatting, cache control headers, thinking mode parameters. The system prompt itself is provider-agnostic. This is the correct separation of concerns.

### 3.2 No Personality System

OpenCode is purely functional. The persona in `persona.txt` is approximately 20 lines of "you are a coding assistant" boilerplate with no adaptive behavior. The model responds identically to:

- A senior Elixir engineer debugging a GenServer supervision tree
- A student asking what a for-loop does

This is a missed opportunity given the per-provider file system already acknowledges that different contexts need different prompts. The same logic applies to different user expertise levels, different task types, and different output channels.

OSA's Signal Theory addresses this at the architecture level: the five-tuple signal classification (Mode, Genre, Type, Format, Weight) determines the output profile before the LLM is called. The context builder in `Agent.Context` varies instruction depth, vocabulary register, and response format based on the signal.

### 3.3 No Adaptive Behavior Based on Message Content

Related to the lack of personality: OpenCode does not vary its tool usage strategy, verbosity, or reasoning depth based on what the user asked. A "quick question" and a "build this full feature" get the same context assembly, the same tool availability, the same output format.

This means OpenCode routinely over-processes simple requests (a Shannon violation — bandwidth overload) and potentially under-processes complex ones (an Ashby violation — insufficient variety in response modes).

### 3.4 No Signal Classification

OpenCode has no equivalent to OSA's noise filter. A blank message, a "thanks", and a complex specification all trigger the same code path: full context assembly, plan evaluation, LLM call, plan update.

The fix is straightforward — a fast deterministic pattern matcher on the input before any LLM work begins. OpenCode doesn't have it.

### 3.5 No Parallel Execution Model

Like Windsurf, OpenCode is strictly sequential. One agent, one action, one step at a time. For a CLI coding agent targeting power users who want to parallelize long-running tasks, this is a meaningful limitation.

The doom loop detector helps prevent wasted time, but it does not replace parallelism. An agent that can fan out independent subtasks to parallel workers completes complex tasks faster and fails more gracefully (partial completion vs. total failure).

---

## 4. Section-by-Section Breakdown

### 4.1 Caching Architecture (anthropic.txt, lines 1-450)

```
Length:     ~450 lines (the cacheable prefix)
Strength:   Cache boundary is enforced by file structure — cannot be accidentally violated
Weakness:   Cache boundary is hard-coded in the file; any growth pushes content past optimal cache size
OSA parity: Yes — cache_control applied in Anthropic provider, prefix/suffix split in Context.build/2
```

The implementation detail worth noting: Anthropic's cache control requires a minimum of 1024 tokens to cache. OpenCode's prefix is designed to stay above this threshold. If the prefix falls below 1024 tokens (e.g., after trimming), caching silently stops working. This is a fragile invariant that must be maintained as the prompt evolves.

**Concrete failure mode**: A developer trims the tool definitions section to reduce prompt size, inadvertently dropping below the 1024-token threshold. Caching stops. Token costs jump 2-3x. The failure is invisible in the API response — there is no error, just missing `cache_read_input_tokens` in the usage block.

### 4.2 Provider File Selection (runtime loader)

```
Mechanism:  Runtime detects active provider → selects matching .txt file → falls back to default.txt
Strength:   No model-specific logic in the agent loop itself
Weakness:   No override mechanism — can't apply anthropic behavior to an Anthropic-compatible endpoint
OSA parity: Partial — OSA handles provider quirks in adapter modules, not prompt files
```

The runtime selection is clean, but the override gap matters for OpenRouter users. If a user routes Claude through OpenRouter, OpenCode serves `default.txt` instead of `anthropic.txt`, missing the caching split and model-specific instructions.

### 4.3 Plan Persistence (.opencode/plan.md)

```
Length:     Dynamic (plan contents determine size)
Strength:   Disk persistence guarantees resumability across crashes
Weakness:   No plan versioning — if a plan becomes stale (user changed direction), old plan is still injected
OSA parity: Yes — tasks/todo.md, same guarantees
```

A stale plan injection can actively mislead the agent. If the user abandons a plan mid-task and starts fresh, the old `.opencode/plan.md` content persists and may be injected into the new session context, causing the agent to reference work items from the abandoned plan. OpenCode does not have a "reset plan" command.

### 4.4 Doom Loop Counter

```
Mechanism:  Counts consecutive tool failures, halts at threshold, surfaces explanation to user
Strength:   Prevents silent infinite retry loops that burn tokens
Weakness:   Counter is per-session, not persisted — a crash resets the counter to 0
OSA parity: Partial — OSA has max_iterations cap, not a consecutive-failure-specific counter
```

The non-persistent counter is a minor gap. A crash during a stuck loop resets context, so the agent will retry from scratch rather than halting with an explanation. This is acceptable behavior but means a crashed stuck loop will restart stuck.

### 4.5 Structured Output Mode

```
Mechanism:  Schema passed in request → provider enforces JSON schema compliance
Strength:   Eliminates downstream JSON parsing failures, guarantees contract
Weakness:   Only available for Anthropic and OpenAI; Ollama support is experimental
OSA parity: Partial — OSA uses typed tool results but does not enforce JSON schema on free-text responses
```

---

## 5. Lessons for OSA

### 5.1 Adopted — Already Implemented

| OpenCode Feature | OSA Implementation | Notes |
|-----------------|-------------------|-------|
| Two-part caching split | `providers/anthropic.ex` + `Context.build/2` | cache_control applied to system prefix |
| Plan file on disk | `tasks/todo.md` | survives restarts |
| Bounded iteration | `max_iterations` = 30 | configurable via app env |
| Context compaction | `Agent.Compactor.maybe_compact/1` | triggered on overflow |

### 5.2 Adopted Conceptually — Implemented Differently

| OpenCode Pattern | OSA Approach | Why Different |
|-----------------|-------------|---------------|
| Per-provider prompt files | Per-provider adapter modules | OSA separates behavioral logic (prompt) from wire-protocol logic (adapter) — cleaner separation |
| Provider detection at runtime | `config/runtime.exs` provider chain | OSA detects at boot, not per-request |

### 5.3 Not Adopted — Intentional

| OpenCode Feature | Reason Skipped |
|-----------------|----------------|
| 6 separate prompt .txt files | DRY violation; adapter-level handling is correct |
| Per-provider prompt divergence | Creates silent drift; OSA uses one prompt + adapter overrides |

### 5.4 Gap — Action Item

| Gap | OpenCode Advantage | OSA Action |
|----|-------------------|------------|
| Consecutive failure counter | Halts with explanation after 3 consecutive failures on same action | Add `consecutive_failure_count` to `Agent.Loop` state; surface explanation to user when threshold exceeded (suggest threshold: 3) |
| Stale plan detection | (OpenCode also lacks this — both have the gap) | On session start, check plan.md age; if > 24h, surface "stale plan" warning before injection |
| Structured output on arbitrary responses | Schema-enforced JSON where needed | Evaluate adding JSON-schema response mode to Anthropic/OpenAI providers for tool-result and plan-output operations |

---

## 6. Competitive Verdict

**Score: 7/10**

OpenCode earns a 7 primarily on the strength of one decision: the two-part prompt caching architecture. This is genuinely good engineering. It reduces LLM API costs by 60-80% per session at Anthropic pricing, it is structurally enforced by the file layout, and it compounds with session length. No other open-source agent has implemented this correctly.

The per-provider file system earns partial credit — the intent is correct (different models need different prompts), but the implementation (full copies vs. delta overrides) creates a maintenance liability that will grow over time.

The doom loop counter is a sensible safety mechanism that OSA should replicate in a focused form: not just a max_iterations cap but a consecutive-failure-specific counter with user-facing explanation.

**Where OpenCode falls short**:
- Per-provider file fragmentation (copy-paste over delta overrides)
- No signal classification (same weight for all inputs)
- No adaptive behavior (same mode for all users and requests)
- No parallel execution (strictly sequential)
- No personality or learning (stateless behavioral model)

**OSA wins on**: signal classification, parallel execution (10 agents), cross-session learning (SICA engine), three-tier memory, hook pipeline, 18 providers, budget management, and everything in the feature matrix that OpenCode doesn't address.

The most important takeaway from OpenCode is not what to copy — OSA has already absorbed the caching strategy. The takeaway is that the consecutive-failure counter is a practical safety mechanism that OSA's iteration cap does not fully cover, and it is worth implementing.

---

## See Also

- [Windsurf Analysis](windsurf-analysis.md) — better plan protocol, better memory, same sequential limitation
- [Aider Analysis](aider.md) — strongest SWE-bench performance, git-native workflow
- [Feature Matrix](feature-matrix.md) — full side-by-side comparison
- [Pipeline Comparison](../pipeline-comparison.md) — OSA event pipeline vs. competitors
