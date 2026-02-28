# Doc 6: System Prompt Architecture Restructuring

> Analysis of the migration from a fragmented 4-tier block assembly to a single cohesive SYSTEM.md with a two-tier static/dynamic split.

---

## 1. What Changed and Why

The OSA system prompt assembly had a structural problem: the LLM received 15 disconnected blocks joined by `---` separators. Each block was written independently, using different voice, style, and level of abstraction. The result was incoherent — the model had to synthesize identity from `IDENTITY.md`, personality from `SOUL.md`, behavioral rules from `tool_process_block()`, and signal guidance from an overlay appended at assembly time. None of these blocks were written to read together.

The second problem was token cost. Every ReAct iteration — every tool call round-trip — called `Context.build/2`, which recomposed the entire system prompt from scratch. Identity, soul, security guardrail, tool process rules: all re-tokenized every iteration. With an average of 5 iterations per request, the static portion of the prompt was paid for 5 times per conversation turn.

The third problem was maintainability. Behavioral directives were scattered across three sources (`soul.ex` inline defaults, `priv/prompts/IDENTITY.md`, `priv/prompts/SOUL.md`) with no clear ownership. Changes to tone required editing `soul.ex`. Changes to tool routing required editing `context.ex`. Changes to security required editing a hardcoded string in `Soul.security_guardrail/0`.

The restructuring addresses all three by consolidating behavioral content into `priv/prompts/SYSTEM.md` and splitting the assembly into static (cached) and dynamic (per-request) tiers.

---

## 2. Before: The 4-Tier Block Assembly

### Assembly Code Path

```
Context.build(state, signal)
  └── assemble_system_prompt(state, signal, system_budget)
        └── gather_blocks(state, signal)
              └── [15 blocks] → fit_blocks() per tier → Enum.join("\n\n---\n\n")
```

### Block Inventory

```
TIER 1 — CRITICAL (always full, no cap)
  1. soul          Soul.system_prompt(signal)
                     = security_guardrail() + IDENTITY.md + SOUL.md + signal_overlay()
                     Composed at call time. 4 parts joined by "\n\n---\n\n".

  2. tool_process  tool_process_block()
                     Hardcoded string in context.ex (~60 lines).
                     Contains: How to Use Tools, Tool Routing Rules, When/When-Not,
                     Important Rules, Brevity, Code Safety.

  3. runtime       runtime_block(state)
                     Timestamp, channel, session_id.

  4. plan_mode     plan_mode_block(state)
                     Injected when state.plan_mode == true.
                     Contains structured plan format template.

  5. environment   environment_block(state)
                     cwd, date, OS, Elixir/OTP versions, provider/model, git state.

TIER 2 — HIGH (up to 40% of system prompt budget)
  6. tools         tools_block()
                     Available tool list with parameter signatures.

  7. rules         rules_block()
                     All *.md files from priv/rules/ concatenated.

  8. memory        memory_block_relevant(state)
                     Keyword-filtered long-term memory from Memory.recall().

  9. workflow      workflow_block(state)
                     Active workflow context from Workflow.context_block(session_id).

 10. task_state    task_state_block(state)
                     Active tasks + status from TaskTracker.get_tasks(session_id).

TIER 3 — MEDIUM (up to 30% of system prompt budget)
 11. user_profile  Soul.user_block()
                     USER.md loaded from ~/.osa/USER.md.

 12. communication intelligence_block(state)
                     CommProfiler.get_profile(user_id) → formality, avg_length, topics.

 13. cortex        cortex_block()
                     Cortex.bulletin() → memory synthesis snapshot.

TIER 4 — LOW (remaining budget)
 14. os_templates  os_templates_block()
                     OS.Registry.prompt_addendums() — OS-specific behavioral guidance.

 15. machines      machines_block()
                     Machines.prompt_addendums() — machine-specific addendums.
```

### Token Budget Mechanics

```
max_tokens          = Application.get_env(:optimal_system_agent, :max_context_tokens, 128_000)
response_reserve    = 4_096
conversation_tokens = estimate_tokens_messages(state.messages)
system_budget       = max(max_tokens - response_reserve - conversation_tokens, 2_000)

tier1_tokens  = full cost, no cap
tier2_budget  = system_budget * 0.40
tier3_budget  = system_budget * 0.30
tier4_budget  = remaining after tiers 1–3
```

Blocks exceeding their tier allocation are truncated with `[...truncated...]`. Token estimation uses the Go tokenizer with a heuristic fallback (`words / 1.3`).

### Problems with This Architecture

**Incoherence at the seam.** `Soul.system_prompt/1` produces:
```
[security guardrail] --- [IDENTITY.md] --- [SOUL.md] --- [signal_overlay]
```
Then `context.ex` appends:
```
--- [tool_process_block] --- [runtime_block] --- [plan_mode_block] --- ...
```
The LLM receives identity written in one voice, personality in another, tool rules in a third. There is no narrative coherence across the assembled prompt.

**Full rebuild per iteration.** `Soul.system_prompt/1` is called inside `gather_blocks/2`, which is called by `assemble_system_prompt/3`, which is called by `Context.build/2` on every ReAct iteration. The Tier 1 `soul` block — the security guardrail, identity, and soul content — is the largest block and changes only when the signal overlay changes. Yet it is fully re-tokenized every loop iteration.

**Behavioral directives split across files.** The security guardrail lives as an inline string in `soul.ex:149`. Tool routing rules live in `context.ex:699`. Communication style lives in `priv/prompts/SOUL.md`. Output brevity rules appear twice: once in `tool_process_block()` ("fewer than 4 lines") and once in SOUL.md's Communication Calibration table. The authoritative source for each directive is unclear.

**No prompt caching.** Anthropic's prompt caching requires the system message to be split into a stable cacheable block and a dynamic per-request block. The current single-string system message format cannot use this feature at all.

**Signal overlay inflates Tier 1 on every call.** The signal overlay is dynamic — it changes with each message. But it is assembled inside `Soul.system_prompt/1`, which is a Tier 1 block (always included, no budget cap). This means any growth in the signal overlay grows the un-cacheable mandatory portion of the prompt.

---

## 3. After: The Two-Tier Static/Dynamic Split

### Architecture Overview

```
SYSTEM.md (priv/prompts/SYSTEM.md)
  ↓ loaded at boot by PromptLoader
  ↓ template vars interpolated once
  ↓ stored in :persistent_term as Soul.static_base()
  = Tier 1 Static Base (cached, ~90% of prompt content)

Context.build(state, signal)
  ↓ reads static_base from :persistent_term (no rebuild)
  ↓ assembles dynamic blocks (per-request)
  = Tier 2 Dynamic Context (token-budgeted, per-call)
```

### SYSTEM.md Structure

`priv/prompts/SYSTEM.md` is a single, coherent document the LLM reads top-to-bottom. It contains 10 sections in a deliberate reading order:

```
## 1. SECURITY
   Absolute rules. First because they must take precedence over everything else.
   Security guardrail extracted from soul.ex inline string into the document.

## 2. IDENTITY
   Who OSA is. One cohesive narrative: name, nature, capabilities, signal loop.
   Replaces the old IDENTITY.md content.

## 3. SIGNAL SYSTEM
   Mode table (EXECUTE/BUILD/ANALYZE/MAINTAIN/ASSIST).
   Genre table (DIRECT/INFORM/COMMIT/DECIDE/EXPRESS).
   Weight calibration table.
   Replaces the signal overlay tables (static portion).

## 4. PERSONALITY
   Communication style, banned phrases, values, decision-making approach.
   Replaces SOUL.md content.

## 5. TOOL USAGE POLICY
   Process, routing rules, parallel batching directive, convention verification,
   when-not-to-use, code safety rules.
   Replaces tool_process_block() in context.ex.
   Includes: {{TOOL_DEFINITIONS}} template variable (boot-time interpolation).
   Includes: {{RULES}} template variable (boot-time interpolation).

## 6. TASK MANAGEMENT
   task_write protocol: when to use, how to use, when not to use.
   Replaces task state block instructions scattered in context.ex.

## 7. DOING TASKS
   Workflow steps, plan mode format, status update directive.
   Consolidates plan_mode_block() content into the static base.

## 8. GIT WORKFLOWS
   Commit protocol, PR protocol, git safety rules.
   New section — pulled from Claude Code 2.0 analysis (Doc 2).

## 9. OUTPUT FORMATTING
   Brevity, preamble rules, code references, markdown usage, depth matching.
   Replaces brevity rules from tool_process_block() and SOUL.md.

## 10. PROACTIVENESS
   When to be proactive, when not to be, the balance principle.
   New section — pulled from Claude Code 2.0 analysis.

## User Profile
   {{USER_PROFILE}} template variable (boot-time interpolation).
```

### Template Variable System

SYSTEM.md contains three `{{VARIABLE}}` placeholders interpolated at boot time, before the document is cached:

| Variable | Source | When Interpolated |
|---|---|---|
| `{{TOOL_DEFINITIONS}}` | `Tools.Registry.list_docs_direct()` | Boot / tool reload |
| `{{RULES}}` | `priv/rules/**/*.md` concatenated | Boot / rules reload |
| `{{USER_PROFILE}}` | `~/.osa/USER.md` | Boot / Soul.load() |

These are "boot-time dynamic" — they change infrequently (when tools are registered or rules are modified) but not per-request. By interpolating at boot and caching the result, the token cost for these blocks is paid once per application boot rather than once per iteration.

### Dynamic Context Blocks (Per-Request)

The following blocks remain dynamic and are assembled by `Context.build/2` on each call. They are appended after the static base as a second system message block (or as a continuation string, depending on provider):

```
Per-request dynamic blocks (still token-budgeted):
  signal_overlay     Mode × Genre × Weight — changes per message
  environment        cwd, date, OS, provider, model, git state — changes over time
  runtime            timestamp, channel, session_id — changes per request
  plan_mode          injected only when state.plan_mode == true
  memory             keyword-filtered MEMORY.md sections
  task_state         active tasks from TaskTracker
  workflow           active workflow context from Workflow
  comm_profile       CommProfiler output (formality, topics, style)
  cortex             Cortex.bulletin() snapshot
  os_templates       OS.Registry.prompt_addendums()
  machines           Machines.prompt_addendums()
```

Note: `user_profile` moves from dynamic (Tier 3 in old system, rebuilt per call via `Soul.user_block()`) to static (interpolated into SYSTEM.md at boot). This is safe because USER.md changes rarely and a boot-time reload is acceptable.

### Token Budget Under the New System

```
static_base_tokens   = estimate_tokens(Soul.static_base())   [computed once at boot]
dynamic_budget       = max_tokens - static_base_tokens - conversation_tokens - response_reserve

Dynamic blocks are assembled within dynamic_budget using the same
priority-fitting logic as the old Tier 2–4.
```

The critical change: the static base is NOT re-estimated on every call. It is computed once at boot, stored alongside the cached string, and subtracted from the budget calculation without touching the string again.

---

## 4. What We Pulled From Each Competitor

The SYSTEM.md content was not written from scratch. Each section incorporates patterns extracted from the competitor analysis in Doc 2 and the gap analysis in Doc 5.

### Claude Code 2.0
Source: Doc 2, Section 2B–2D

- **Task management rules** (Section 6): `task_write` protocol mirrors Claude Code 2.0's `TodoWrite` protocol — when to create, how to mark progress, when to skip.
- **Git safety protocol** (Section 8): The commit workflow (status → diff → log → stage specific files → commit) and the `--no-verify` prohibition are taken directly from Claude Code 2.0's git section.
- **Output minimization** (Section 9): "fewer than 4 lines", "no preamble/postamble", "briefly confirm completion" — adapted from Claude Code 2.0's output format rules.
- **Proactiveness balance** (Section 10): The asymmetry principle ("cost of over-proactiveness exceeds cost of under-proactiveness") is adapted from Claude Code 2.0's proactiveness heuristics.
- **Parallel batching directive** (Section 5): "Call multiple tools in a single response" — explicit instruction added per GAP-07.
- **Tool preference hierarchy** (Section 5): "Use dedicated tools instead of bash equivalents" — routing rules mirroring Claude Code 2.0's tool preference ordering.

### Cursor
Source: Doc 2, Section 2B; Doc 5 GAP-07, GAP-08

- **"DEFAULT TO PARALLEL"** (Section 5): Cursor's most distinctive prompt instruction. Added to the Tool Usage Policy: "Default to parallel. Call 3-5 tools per turn when possible."
- **Status updates between tool batches** (Section 7): "After completing each batch of tool calls, provide a brief 1-sentence status update before the next batch." Addresses the silent-iteration problem.

### Gemini CLI
Source: Doc 2, Section 2B; Doc 5 GAP-10

- **Convention verification** (Section 5): "Before using any library or framework, verify it's available. Check package.json, go.mod, mix.exs, requirements.txt, or Cargo.toml." Added per GAP-10.

### OpenCode
Source: Doc 5 GAP-01, GAP-06

- **Prompt caching two-part split**: The static base / dynamic context architecture is the direct implementation of GAP-01. OpenCode collapses its system prompt into exactly 2 parts for Anthropic caching; SYSTEM.md is OSA's equivalent of their stable first part.
- **Plan file persistence concept**: The plan mode section in SYSTEM.md prepares for GAP-06 (plan persistence to `~/.osa/plans/`). The format template is already in the static base, so persisted plan files will match the format the LLM was trained to produce.

### OSA Original (Preserved)
- **Signal classification** (Sections 2–3): The `S = (M, G, T, F, W)` 5-tuple, mode/genre tables, and weight calibration are core OSA intellectual property. Preserved intact and promoted to prominent position in the document.
- **Mode/genre overlays**: The static mode and genre tables move to Section 3. The dynamic per-message overlay (which mode/genre is currently active) remains in the dynamic context block, keeping the per-call behavioral injection while avoiding re-stating the full tables every iteration.
- **Personality system** (Section 4): The full Soul content — inner life, communication calibration, banned phrases, values — is preserved. It moves from a separately loaded `SOUL.md` file into the unified SYSTEM.md document.
- **Noise filtering**: Not in the system prompt (the noise filter operates pre-LLM in loop.ex and is not prompt-driven). Preserved as-is.

---

## 5. Migration Path

### File Changes

| Old | New | Status |
|---|---|---|
| `priv/prompts/IDENTITY.md` | Content merged into SYSTEM.md §2 | Kept for backward compat |
| `priv/prompts/SOUL.md` | Content merged into SYSTEM.md §4 | Kept for backward compat |
| `Soul.security_guardrail/0` (inline) | Content merged into SYSTEM.md §1 | Function replaced by SYSTEM.md load |
| `context.ex:tool_process_block/0` | Content merged into SYSTEM.md §5 | Function removed from gather_blocks |
| `priv/prompts/SYSTEM.md` | New unified document | Created |

### Code Changes

**`Soul` module (`soul.ex`)**

The `system_prompt/1` function is replaced by two functions:

```elixir
# New: loads SYSTEM.md, interpolates boot-time vars, caches result
def load_static_base() :: :ok

# New: returns the cached, interpolated SYSTEM.md string
def static_base() :: String.t()

# Retained: builds per-request signal overlay only (not full system prompt)
def signal_overlay(signal) :: String.t()

# Removed: system_prompt/1 (the old 4-part composer)
# Removed: security_guardrail/0 (content now in SYSTEM.md)
# Retained: user_block/0 (still used for backward compat detection)
# Retained: for_agent/1, load/0, reload/0
```

**`Context` module (`context.ex`)**

The `gather_blocks/2` function changes:

```elixir
# Old Tier 1:
{Soul.system_prompt(signal), 1, "soul"},          # removed
{tool_process_block(), 1, "tool_process"},         # removed

# New Tier 1 (static base provided separately, not in gather_blocks):
# Soul.static_base() is passed as the base string before dynamic blocks

# New Tier 1 (dynamic only):
{Soul.signal_overlay(signal), 1, "signal_overlay"},  # signal only, not full soul
{runtime_block(state), 1, "runtime"},
{plan_mode_block(state), 1, "plan_mode"},
{environment_block(state), 1, "environment"},

# Tier 2–4 unchanged
```

The `build/2` function signature does not change. Internal assembly changes to:
1. Fetch `Soul.static_base()` from `:persistent_term` (no computation).
2. Compute dynamic blocks via `gather_blocks/2`.
3. Combine as: `static_base <> "\n\n---\n\n" <> dynamic_blocks_joined`.
4. Return as before: `%{messages: [system_msg | conversation]}`.

**`PromptLoader` module (`prompt_loader.ex`)**

Add `:SYSTEM` to `@known_keys`. The load order for SYSTEM.md:
1. `~/.osa/prompts/SYSTEM.md` (user override)
2. `priv/prompts/SYSTEM.md` (bundled default)

### Backward Compatibility

Users who have `~/.osa/IDENTITY.md` and/or `~/.osa/SOUL.md` (old format) are handled at boot:

```
if File.exists?("~/.osa/prompts/SYSTEM.md")
  → use it directly (user has migrated)
else if File.exists?("~/.osa/IDENTITY.md") OR File.exists?("~/.osa/SOUL.md")
  → compose those into the static base at boot (old format, graceful upgrade)
  → log: "[Soul] Using legacy IDENTITY.md + SOUL.md format. Consider migrating to ~/.osa/prompts/SYSTEM.md"
else
  → use bundled priv/prompts/SYSTEM.md (default path)
```

Old files are never deleted. They are read if present and the result replaces the corresponding sections in the assembled base, giving users a path to migrate at their own pace.

---

## 6. Provider Cache Integration

### Anthropic

Anthropic's prompt caching works by splitting the system message into content blocks. The first block with `cache_control: {type: "ephemeral"}` is cached on first call and served from cache on subsequent calls within the cache TTL (5 minutes for ephemeral).

The two-tier split maps directly to this mechanism:

```elixir
# In anthropic.ex provider, when building the system parameter:
[
  %{
    type: "text",
    text: Soul.static_base(),         # static: SYSTEM.md + boot-time interpolations
    cache_control: %{type: "ephemeral"}
  },
  %{
    type: "text",
    text: dynamic_context_string      # per-request: signal overlay + env + memory + tasks
    # no cache_control — this block changes every call
  }
]
```

The static base is typically 800–1200 tokens (SYSTEM.md as written). With an average conversation of 8 turns and 3 iterations per turn, that is 24 system prompt calls per conversation. Caching the static base eliminates ~90% of those input tokens on calls 2–24.

Estimated savings at typical Anthropic input pricing:
- Without caching: 24 × 1000 tokens = 24,000 input tokens per conversation for static base alone
- With caching: 1 × 1000 (cache write) + 23 × 100 (cache read at 10% cost) = 3,300 token-equivalent units
- Reduction: ~86% on the static portion of input tokens

### Other Providers

Providers without native prompt caching (OpenAI, Ollama, Groq, etc.) receive the static base and dynamic context as a single concatenated system message, identical to the current behavior. No change required for these providers.

The `Soul.static_base()` `:persistent_term` cache still benefits non-caching providers by eliminating the string concatenation and token estimation overhead on every loop iteration.

---

## 7. Correctness of the Migration

### What Is Preserved

- All behavioral content from IDENTITY.md, SOUL.md, and `tool_process_block()` is present in SYSTEM.md.
- The security guardrail is Section 1 — still the first thing the LLM reads.
- Signal modes, genres, and weight calibration tables are unchanged.
- The personality content (banned phrases, values, communication calibration) is preserved verbatim.
- The tool routing rules (file_read over cat, file_edit over sed, etc.) are in Section 5.
- The plan mode format template is in Section 7.
- The token budget and dynamic block priority system (`fit_blocks/2`) is unchanged.

### What Changes Behaviorally

- **Tool routing rules appear once**, not twice (old system had them in both `Soul.system_prompt` → IDENTITY.md and `tool_process_block()`).
- **Output brevity is in one place** (Section 9), not split between SOUL.md and `tool_process_block()`.
- **Parallel batching is now explicit**: "Default to parallel. Call 3-5 tools per turn when possible." Old system had no such directive.
- **Convention verification is now explicit**: "Before using any library, check package.json / go.mod / mix.exs." Old system had no such directive.
- **Git workflow is now explicit**: Commit protocol, PR protocol, git safety rules. Old system had no git-specific section.
- **Status updates are now explicit**: "Provide a 1-sentence status update after each batch of tool calls." Old system had no such directive.

### What Is Removed

- `soul.ex:security_guardrail/0` — content lives in SYSTEM.md §1
- `context.ex:tool_process_block/0` — content lives in SYSTEM.md §5
- `Soul.system_prompt/1` as the Tier 1 block composer — replaced by `Soul.static_base()` fetch

---

## 8. Document Relationships

| Doc | Relationship |
|---|---|
| Doc 2: System Prompt Anatomy | Source of the gap analysis that drove this redesign. Sections 4 and 5 of Doc 2 catalog exactly what OSA was missing and what others do differently. |
| Doc 3: Signal Classification | Signal overlay mechanism unchanged. Per-request dynamic block continues to inject `Mode × Genre × Weight` guidance. |
| Doc 5: Gap Analysis | GAP-01 (prompt caching), GAP-07 (parallel batching), GAP-08 (status updates), GAP-10 (convention verification) are all resolved by this restructuring. |
| Doc 1: Message Flow | `Context.build/2` call site at STEP 5 of the ReAct loop is unchanged. Internal behavior changes but the interface and position in the flow are identical. |

---

## 9. Implementation Checklist

```
[ ] Add :SYSTEM to PromptLoader @known_keys
[ ] Implement Soul.load_static_base/0 — loads SYSTEM.md, interpolates {{TOOL_DEFINITIONS}},
    {{RULES}}, {{USER_PROFILE}}, caches in :persistent_term
[ ] Implement Soul.static_base/0 — fetches from :persistent_term
[ ] Update Soul.load/0 to call load_static_base/0
[ ] Update context.ex gather_blocks/2 — remove soul block, remove tool_process block,
    add signal_overlay as Tier 1 dynamic block
[ ] Update context.ex assemble_system_prompt/3 — prepend static_base before dynamic blocks
[ ] Update anthropic.ex provider — split system into 2 content blocks with cache_control
[ ] Add backward compat detection in Soul — check for legacy IDENTITY.md + SOUL.md
[ ] Update PromptLoader to support reload of SYSTEM.md on /reload command
[ ] Update token_budget/2 to account for static_base_tokens separately
[ ] Add Soul.static_base_tokens/0 — computed at load time, stored in :persistent_term
[ ] Verify: all 15 old gather_blocks entries have corresponding content in SYSTEM.md or
    remain as dynamic blocks
```
