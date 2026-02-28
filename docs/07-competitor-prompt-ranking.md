# Doc 7: Competitor System Prompt Ranking

> Ranks all competitor system prompts from best to worst architecture, with adoption decisions for OSA v2.

---

## Summary Table

| Rank | Tool | Score | Key Strength | Adopting? |
|---|---|---|---|---|
| 1 | Claude Code v2 | 9/10 | Comprehensive tool schema + task management | Yes — task rules, git safety, batching |
| 2 | Cursor | 8/10 | Parallel-first directive, status update mandate | Yes — parallel batching, status updates |
| 3 | Windsurf | 7/10 | Plan update protocol, memory system | No — OSA already has both |
| 4 | OpenCode | 7/10 | Prompt caching (2-part split), provider files | Yes — caching architecture |
| 5 | Gemini CLI | 6/10 | Convention verification mandate | Yes — one directive |
| 6 | Cline | 6/10 | XML tool format, sequential safety | No — conflicts with parallel model |
| 7 | Codex CLI | 5/10 | "Remote teammate" personality | No — OSA personality already deeper |
| 8 | Claude Code v1 | 4/10 | Extreme output minimization | No — v2 supersedes everything |

**OSA v2 Target Score: 9.5/10**

---

## Detailed Rankings

### 1. Claude Code v2 — Score: 9/10

**Prompt Size**: ~1150 lines. Monolithic + detailed tool schemas.

**Strengths**

- Most comprehensive tool schema injection of any competitor — full JSON schemas, parameter descriptions, and usage notes per tool
- `TodoWrite` task management with structured state (pending / in_progress / completed / cancelled)
- Git safety protocol: never force push, never skip hooks, prefer new commits over amend
- Proactiveness balance section — explicit rules on when to act vs when to ask
- Adaptive output formatting — response length scales to request complexity
- Parallel batching directive — explicit instruction to fan-out independent tool calls

**Weaknesses**

- No signal-adaptive behavior — same response style regardless of message weight or genre
- Static personality — "helpful CLI tool" with no genuine voice

**Adoption decisions**

| Item | Decision | Rationale |
|---|---|---|
| Task management rules (TodoWrite behavior) | **Adopt** | Best-in-class state machine for task tracking |
| Git safety protocol | **Adopt** | Never force push, never skip hooks, NEW commits over amend |
| Output minimization patterns | **Adopt** | Response length proportional to request complexity |
| Proactiveness balance section | **Adopt** | Explicit act-vs-ask rules reduce user friction |
| Tool preference hierarchy | **Adopt** | Dedicated tools over Bash; Bash only when no dedicated tool exists |
| Parallel batching directive | **Adopt** | Fan-out independent tool calls in single turn |
| Per-tool JSON schemas in prompt | **Skip** | OSA injects tool schemas dynamically at assembly time |
| Agent SDK identity framing | **Skip** | OSA has its own identity system (IDENTITY.md + SOUL.md) |

---

### 2. Cursor — Score: 8/10

**Prompt Size**: ~800 lines. Agent prompt + todo state injected per turn.

**Strengths**

- "DEFAULT TO PARALLEL" is explicit, bolded, and near the top of the prompt — highest visibility of any competitor
- `todo_write` merge semantics: update existing tasks rather than replacing list
- Status update mandate between tool batches — required to emit a summary after each batch before starting the next
- `cite_blocks` format for code references — structured citation with file path + line range

**Weaknesses**

- Over-reliance on todo state — todo list injected on every turn regardless of relevance, adds noise
- No personality layer — purely transactional framing
- GPT-5 identity lock-in in prompt (model-specific assumptions baked in)

**Adoption decisions**

| Item | Decision | Rationale |
|---|---|---|
| Parallel-first directive | **Adopt** | Explicit "DEFAULT TO PARALLEL" wording is effective; adapt for OSA |
| Status update mandate between batches | **Adopt** | Reduces user uncertainty during long multi-batch operations |
| cite_blocks format | **Skip** | Not relevant to OSA's CLI rendering layer |
| todo_write merge semantics | **Skip** | OSA uses its own task tracker (`/tm-*` commands) with different semantics |

---

### 3. Windsurf — Score: 7/10

**Prompt Size**: ~600 lines. Flow prompt + plan state + memory injected.

**Strengths**

- Plan update protocol — agent explicitly updates its plan file after each significant step
- Memory system — persists user preferences and project context across sessions
- Step-by-step narrative output — writes what it's about to do, does it, then writes what changed
- "What changed" summaries at end of each action block

**Weaknesses**

- Tool minimalism ("only use tools if absolutely necessary") is too conservative — creates hesitation before legitimate tool use
- No signal classification — same behavior for a one-word query and a 500-word architecture request
- No parallel execution model

**Adoption decisions**

| Item | Decision | Rationale |
|---|---|---|
| Plan update protocol | **Skip** | OSA already has plan mode + `tasks/todo.md` |
| Memory system | **Skip** | OSA already has `/mem-save` and `/mem-search` |
| Tool minimalism directive | **Skip** | Directly conflicts with OSA's proactive tool use philosophy |

Windsurf is informational reference only. No direct adoptions.

---

### 4. OpenCode — Score: 7/10

**Prompt Size**: ~500 lines base + env block. Split into provider-specific `.txt` files.

**Strengths**

- Provider-specific prompt files (`anthropic.txt`, `gemini.txt`, `qwen.txt`) — each tuned to model capabilities and instruction-following patterns
- Prompt caching architecture: system prompt split into exactly 2 parts for Anthropic — static cacheable prefix + dynamic per-request suffix
- Plan file persistence — writes `.opencode/plan.md` to disk, not just in-context
- Doom loop detection — counts consecutive tool failures, halts and reports after threshold
- Structured output mode — JSON-schema-constrained responses for machine consumption

**Weaknesses**

- Per-provider fragmentation — 6 separate files to maintain; no unified signal-adaptive layer
- No personality system — purely functional framing across all provider files
- No adaptive behavior based on message content

**Adoption decisions**

| Item | Decision | Rationale |
|---|---|---|
| Prompt caching (2-part split) | **Adopt** | 60-80% input token savings on multi-iteration requests; details in GAP-01 |
| Plan persistence concept | **Adopt (future)** | Write plan to disk for resumability across sessions |
| Per-provider prompt files | **Skip** | OSA uses single SYSTEM.md with signal-adaptive overlays; cleaner to maintain |
| Structured output tool | **Skip (future)** | Useful for machine consumers; not a current priority |

---

### 5. Gemini CLI — Score: 6/10

**Prompt Size**: ~400 lines. Workflow prompt + convention verification.

**Strengths**

- Convention verification mandate: "Before using any library, verify it is already in use in the codebase or confirm it is available" — prevents hallucinated imports
- Same verify loop as Cline: test → lint → build, always in that order
- Absolute paths enforced — no relative path usage in tool calls

**Weaknesses**

- No personality — purely mechanical instructions
- Minimal identity — does not establish voice or agency
- Rigid workflow — same sequence for all task types regardless of complexity

**Adoption decisions**

| Item | Decision | Rationale |
|---|---|---|
| Convention verification directive | **Adopt** | One sentence, high signal-to-noise, prevents a real class of errors |
| Rigid workflow mandate | **Skip** | OSA adapts workflow to signal mode and task complexity |

---

### 6. Cline — Score: 6/10

**Prompt Size**: ~400 lines. Workflow prompt with XML tool format.

**Strengths**

- XML tool format (`<tool_name><param>value</param></tool_name>`) — deterministically parseable without JSON edge cases
- Sequential safety model — one tool per message prevents cascading failures from bad tool output
- `explain_command_before_running` — requires explanation before any shell command
- Two workflow patterns: new task (plan first) vs existing task (read state first)

**Weaknesses**

- One tool per message is a fundamental throughput constraint — cannot parallelize any work
- Extreme brevity requirement (`<3 lines` for most responses) — conflicts with adaptive output depth
- No adaptive behavior — same verbosity for a typo fix and an architecture refactor

**Adoption decisions**

| Item | Decision | Rationale |
|---|---|---|
| `explain_command_before_running` | **Skip** | OSA's security hook covers this; duplicate layer |
| One-tool-per-message constraint | **Skip** | Directly conflicts with parallel batching model |
| XML tool format | **Skip** | OSA uses standard Anthropic tool calling protocol |

No direct adoptions from Cline.

---

### 7. Codex CLI — Score: 5/10

**Prompt Size**: ~300 lines. Minimal prompt + git context injected.

**Strengths**

- "Remote teammate" personality framing — warm, helpful, collaborative tone
- Git-state-as-context approach — injects `git status` and recent diff into system context automatically
- Sandbox trust model — classifies operations by risk tier, requests confirmation at tier boundary

**Weaknesses**

- Minimal prompt (~300 lines) — insufficient coverage of tool routing, plan mode, task tracking, signal handling
- No parallel execution model
- No persona depth — "remote teammate" is a single sentence, not a developed voice

**Adoption decisions**

| Item | Decision | Rationale |
|---|---|---|
| "Remote teammate" personality | **Skip** | OSA personality system (IDENTITY.md + SOUL.md) already more developed |
| Git-state-as-context | **Skip** | OSA's context builder already pulls git state via hooks |
| Sandbox trust model | **Skip** | OSA's security hook implements risk-tiered confirmation |

No direct adoptions from Codex CLI.

---

### 8. Claude Code v1 — Score: 4/10

**Prompt Size**: ~192 lines. Monolithic static prompt.

**Strengths**

- Extreme output minimization — "fewer than 4 lines" rule enforces discipline on response length
- Clear anti-pattern rules — explicit list of prohibited behaviors (no unsolicited explanations, no filler)

**Weaknesses**

- No personality — one-sentence identity
- No modes — same behavior regardless of task type
- No task tracking — no plan system, no todo state
- Minimal tool guidance — tools listed by name only, no usage rules
- v2 supersedes this entirely

**Adoption decisions**

| Item | Decision | Rationale |
|---|---|---|
| All content | **Skip** | Claude Code v2 supersedes every section of v1 |

No direct adoptions from Claude Code v1.

---

## OSA v2 — Target Score: 9.5/10

OSA's new system prompt architecture outperforms all competitors on seven axes.

### What makes OSA better

**1. Signal-adaptive behavior**

No other tool changes its response depth, verbosity, or tool selection based on per-message signal classification. OSA detects mode (linguistic / visual / code), genre (spec / brief / report / ADR / etc.), and weight (S/M/L/XL) and adjusts behavior accordingly. A one-word query gets a one-line answer. An architecture request gets a full spec.

**2. Cohesive document structure**

Claude Code v2's prompt is 1150 lines of blocks that were clearly assembled by concatenation over time. OSA's system prompt reads top-to-bottom as a single authored document: identity → principles → signal behavior → workflow → tool rules → safety.

**3. Two-tier caching**

Adopted from OpenCode. Static content (identity, soul, tool process, security, environment) is the cacheable prefix. Dynamic content (signal overlay, plan mode, tasks, rules, memory) is the per-call suffix. Estimated 60–80% input token savings on multi-iteration requests.

**4. Developed personality system**

OSA has 500+ words of genuine personality across IDENTITY.md and SOUL.md — voice, values, communication style, and failure modes. No competitor exceeds 50 words of personality framing. "I'm a helpful coding assistant" is not a personality.

**5. Token-budgeted assembly**

OSA's context builder (`context.ex`) assembles the system prompt to fit within a configurable token budget. Sections are priority-ranked: security first, identity second, tools third, rules last. Budget overrun drops the lowest-priority sections, never the highest.

**6. Competitor best practices integrated**

| Practice | Source | OSA Implementation |
|---|---|---|
| Parallel batching directive | Cursor | `DEFAULT TO PARALLEL` in tool process section |
| Git safety protocol | Claude Code v2 | In workflow rules: no force push, no amend, new commits |
| Convention verification | Gemini CLI | "Verify library availability before use" in code rules |
| Prompt caching (2-part) | OpenCode | Static prefix cached, dynamic suffix per-call |
| Status update between batches | Cursor | Required summary emission after each tool batch |
| Task management state machine | Claude Code v2 | TodoWrite-equivalent in task management rules |

**7. Backward compatibility**

Old IDENTITY.md and SOUL.md format still works without modification. The new assembly layer reads both files as inputs and composes them into the new structure. Existing OSA deployments do not need to rewrite their identity configuration.

---

## Adoption Checklist

Items confirmed for OSA v2 system prompt, sorted by source.

**From Claude Code v2**
- [ ] Task management rules (pending / in_progress / completed / cancelled state machine)
- [ ] Git safety protocol (no force push, no skip hooks, new commits over amend)
- [ ] Output length proportional to request complexity
- [ ] Proactiveness balance — explicit act-vs-ask rules
- [ ] Tool preference hierarchy — dedicated tools over Bash
- [ ] Parallel batching directive — fan-out independent calls

**From Cursor**
- [ ] "DEFAULT TO PARALLEL" explicit directive near top of prompt
- [ ] Status update mandate between tool batches

**From OpenCode**
- [ ] Two-part prompt caching split (static cacheable + dynamic per-request)
- [ ] Plan persistence to disk (deferred to future milestone)

**From Gemini CLI**
- [ ] Convention verification directive ("verify library is available before use")

**Total adoptions: 11 items across 4 competitors**

---

*See also: [Doc 2: System Prompt Anatomy](02-system-prompt-anatomy.md) | [Doc 5: Gap Analysis & Roadmap](05-gap-analysis-roadmap.md)*
