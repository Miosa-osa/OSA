# Cursor System Prompt Architecture — Deep Analysis

> A forensic breakdown of Cursor's ~800-line system prompt: what works, what fails, and what OSA adopted.

---

## 1. Prompt Architecture Overview

Cursor's system prompt is approximately 800 lines. It is not a static document — the assembly is dynamic in one specific way: todo state is injected fresh on every turn, merging current task status into the prompt before the LLM sees the message.

**Assembly strategy: agent prompt + injected todo state**

```
[Static agent prompt — ~750 lines]
  + [todo state block — injected per turn]
  = ~800 lines submitted to the model each call
```

The static portion covers identity, tool routing rules, status update mandates, output format, and citation format. The dynamic portion is exclusively the todo list. Everything else — editor context (open files, cursor position, active selection) — is injected separately as a context block appended to the user message, not the system prompt.

**Model framing: GPT-5 lock-in**

The system prompt opens with an explicit model declaration:

```
"You are a powerful agentic AI coding assistant, powered by GPT-5."
```

This is architecturally significant and architecturally wrong. Cursor supports multiple backends (OpenAI, Claude, Gemini). The model-specific identity framing is only accurate when running GPT-5. When Cursor routes to Claude, the system prompt still declares GPT-5 identity. This is a separation-of-concerns failure baked into the prompt at line 1.

**Section order (reconstructed)**

```
1. Identity + model declaration
2. Tool instructions — parallel-first directive
3. Status update mandate (between tool batches)
4. TODO management protocol (todo_write semantics)
5. Code output policy (never output code inline — use tools)
6. Citation format rules (cite_blocks)
7. Markdown formatting rules
8. Verification loop (linter → fix → retry)
9. [Dynamic: active file, cursor position, selection injected here]
```

The ordering is deliberate. High-value behavioral directives (parallel execution, status updates) appear early — within the first 20% of the prompt. Low-value formatting rules appear late. This is correct prompt engineering: LLMs exhibit primacy effects, placing critical directives early maximizes their recall weight.

---

## 2. What Makes It Good (Score: 8/10)

### "DEFAULT TO PARALLEL" Directive

This is the single best prompt engineering decision in Cursor's system prompt.

The exact wording matters:

```
DEFAULT TO PARALLEL: Unless you have specific reason operations MUST be
sequential, DEFAULT TO PARALLEL tool calls. Maximize parallel tool calls.
Aim for 3-5 tool calls per turn where possible.
```

Three things make this directive effective:

**1. Placement.** It appears within the first 25% of the prompt, under tool instructions, before any other behavioral guidance. LLMs weight early content more heavily due to primacy effects in transformer attention. Putting this directive late in the prompt (say, at line 600 of 800) would reduce its effect. Cursor puts it at line ~80.

**2. Explicit negation.** The phrasing "unless you have specific reason operations MUST be sequential" is not optional hedging — it is a precise carve-out. The model is instructed to invert the default assumption. Most models without this instruction default to sequential tool use because that is what training data reflects (humans use tools one at a time). Cursor explicitly overrides this default.

**3. Quantified target.** "Aim for 3-5 tool calls per turn where possible" gives the model a concrete number to optimize against. Vague directives ("use parallel calls when you can") produce inconsistent behavior. Quantified targets ("3-5 per turn") give the model a measurable objective.

No other competitor prompt in the field contains a directive of this clarity or placement. Claude Code v2 has a parallel batching note, but it appears at line ~900 of 1150, far enough down to reduce its weight. Windsurf explicitly takes the opposite position ("only use tools if absolutely necessary"). Cline forbids parallelism entirely (one tool per message). Cursor is alone in making parallelism the default, explicit, and quantified.

The measurable effect: a Cursor agent operating on a task that touches 4 independent files will attempt to read all 4 in a single turn batch. A sequential agent does this in 4 turns. The throughput difference compounds over multi-step tasks.

### Todo State with Merge Semantics

Cursor's `todo_write` tool accepts a `merge=true` parameter. This is a small but important design choice.

**Without merge semantics:**

```
Turn 1: todo_write([task_a, task_b, task_c])
Turn 3: todo_write([task_a_done, task_d_new])
→ Result: todo list = [task_a_done, task_d_new]
→ task_b and task_c are silently dropped
```

**With merge semantics:**

```
Turn 1: todo_write(merge=true, [task_a, task_b, task_c])
Turn 3: todo_write(merge=true, [task_a=done, task_d=new])
→ Result: todo list = [task_a=done, task_b, task_c, task_d=new]
→ Nothing is dropped
```

The problem this solves is real: during multi-step operations, agents frequently issue partial todo updates — updating only the tasks they just touched, not the full list. Without merge semantics, this silently drops tasks that haven't been touched yet. With merge semantics, updates are additive: new tasks are added, existing tasks can be updated, but nothing disappears unless explicitly removed.

Claude Code v2's `TodoWrite` replaces the entire list on each call. This is simpler to implement but introduces the silent-drop failure mode. Cursor's approach is strictly more correct for multi-step workflows.

The implementation cost is minimal (a merge operation on the todo state store). The reliability benefit for long tasks is non-trivial.

### Status Update Mandate

Cursor's prompt contains an explicit requirement:

```
After each tool batch, emit a 1-3 sentence status update summarizing:
  - What you just did
  - What you are about to do next
Before starting the next tool batch.
```

This addresses a genuine UX failure mode: long silent execution. When an agent runs 6 sequential tool batches without emitting any output, the user sees nothing for 30-90 seconds. They do not know if the agent is making progress, stuck in a loop, or about to do something destructive.

The status update mandate creates a heartbeat rhythm:

```
[Tool batch 1] → Status: "Read 4 source files. Analyzing auth flow next."
[Tool batch 2] → Status: "Found the race condition in session.ex:47. Applying fix."
[Tool batch 3] → Status: "Applied fix. Running tests to verify."
```

The user always knows the current state. The 1-3 sentence constraint prevents the status updates from becoming verbose output that buries the actual work. This is a well-calibrated directive.

The mechanism is in-prompt (the model is instructed to do this) rather than implemented in the runtime layer. This means it can fail — a model following different instructions might skip the updates. But placing it in the prompt ensures it works across all backends without client-side instrumentation.

### cite_blocks Format

Cursor defines a structured format for referencing existing code:

```
cite_blocks:
  file: path/to/file.ts
  lines: 45-62
  content: [code excerpt]
```

This is machine-parseable. The IDE can render it as a clickable link that jumps to the referenced location. It separates the code reference (what the agent is pointing at) from the code change (what the agent is doing), which reduces confusion when the agent is explaining vs editing.

The value is IDE-specific — it works because Cursor controls the rendering layer. In a CLI context, cite_blocks renders as inert text. But within the IDE, this format enables a class of UX interactions (click-to-navigate from agent output to source) that unstructured text references cannot support.

---

## 3. What Makes It Bad

### Todo Noise on Every Turn

Cursor injects the full todo list into the system prompt on every single turn, regardless of whether the current interaction has anything to do with task tracking.

```
User: "What does the auth module do?"
System prompt (injected):
  [750 lines of agent instructions]
  [Current todo list:
    - task_a: Add pagination to /users endpoint [in_progress]
    - task_b: Fix race condition in session handler [pending]
    - task_c: Update API docs [pending]]
```

The todo list is irrelevant to a question about what the auth module does. But the model still processes all those tokens. At scale, this is a non-trivial cost. On a project with 15 active tasks, the todo block alone adds ~200-300 tokens per turn, every turn, including turns where the user asks "what time is it."

The correct implementation: inject todo state only when the classifier detects a task-relevant message (task creation, task update, planning request). This would eliminate the noise on roughly 60-70% of interactions based on typical usage patterns.

Cursor does not have a signal classification layer. There is no mechanism to distinguish task-relevant from task-irrelevant messages. So the todo list goes in everywhere, always.

### No Personality

Cursor's identity layer is two sentences:

```
"You are a powerful agentic AI coding assistant, powered by GPT-5.
You are pair programming with a USER who may have specific context."
```

This is a function declaration, not a personality. The model knows what it is (a coding assistant) and what the user is (a pair programming partner). It knows nothing about how to communicate, when to push back, when to ask for clarification, how to handle disagreement, or what its own values are.

The practical effect: Cursor's responses are competent but uniform. The agent will complete any task with the same tone, depth, and framing. There is no calibration to the user's technical level. There is no warmth or friction — just execution. Users who want a collaborator get a tool.

This is a deliberate product choice. Cursor optimizes for task completion speed, not relationship quality. But it means Cursor agents feel interchangeable. There is no sense that this particular assistant knows anything about you or has any perspective of its own.

### GPT-5 Identity Lock-in

The model declaration at line 1 of the prompt is:

```
"You are a powerful agentic AI coding assistant, powered by GPT-5."
```

Cursor supports four backends: OpenAI (GPT-4o, GPT-5), Anthropic (Claude), Google (Gemini), xAI (Grok). The same system prompt — including the GPT-5 identity declaration — is sent to all backends.

When the backend is Claude, the system prompt tells Claude that it is GPT-5. Claude then operates under a false identity, which can produce subtle inconsistencies: Claude's knowledge of its own capabilities, limitations, and training differs from GPT-5's. Telling Claude it is GPT-5 does not change what Claude knows — it only creates a contradiction between the stated identity and the actual knowledge base.

The correct architecture: model identity should be injected by the runtime layer, not hardcoded in the static system prompt. The static prompt should read:

```
"You are a powerful agentic AI coding assistant."
```

And the runtime injects:

```
"You are powered by [model_name]."
```

This is a basic separation of concerns. Configuration (which model) should not be hardcoded in content (the behavioral prompt). Cursor violates this by conflating the two.

### No Signal Classification

Cursor processes every message through the same pipeline regardless of message type, length, complexity, or intent. A one-word command ("refactor") and a 500-word architecture description both enter the same prompt assembly, trigger the same tool routing logic, and produce responses governed by the same output rules.

There is no mechanism to detect that "thanks" is noise and skip the LLM entirely. There is no mechanism to detect that a 500-word architecture description needs a different response depth than "fix the typo in line 3." Every message is treated as a task.

The cost is both tokens (processing noise messages wastes LLM calls) and response quality (the same output rules cannot simultaneously produce correct behavior for trivial and complex inputs). Cursor compensates with the status update mandate, which creates visible rhythm, but the underlying classification problem is unaddressed.

### No Cross-Session Memory

Cursor has no persistent memory across sessions. Every new session begins with the static system prompt and no knowledge of previous interactions, user preferences, established conventions, or past decisions.

The practical consequence: users must re-establish context at the start of every session. "I use tabs not spaces" must be stated again. "We decided to use the repository pattern for this service" must be restated. "I prefer minimal comments" must be repeated.

Windsurf has a memory system that persists user preferences. OSA has `/mem-save` and `/mem-search` with keyword-relevant retrieval. Cursor has neither. For one-off tasks, this is not a problem. For users running extended projects over days or weeks, the lack of memory means Cursor's agents have amnesia.

### No Noise Filtering

Every message Cursor receives hits the LLM. There is no short-circuit gate for low-signal inputs.

```
User: "ok"
→ Cursor: injects 800-line prompt + todo state + context block → sends to GPT-5 → generates response
→ Cost: ~3000 input tokens + output tokens
→ Correct response: acknowledge without full processing, or skip response entirely
```

This is not a catastrophic failure mode but it is a continuous inefficiency. On a chat-heavy session with frequent acknowledgments, status checks, and off-topic messages, the cumulative cost of processing noise is non-trivial.

---

## 4. Section-by-Section Breakdown

### System Identity + Model Framing

```
"You are a powerful agentic AI coding assistant, powered by GPT-5.
You are pair programming with a USER who may have specific context."
```

**What it does well:** establishes the pair-programming mental model. The model understands it is a collaborator, not a search engine. The "USER may have specific context" qualifier correctly establishes that the user is a peer, not someone to be talked down to.

**What fails:** the GPT-5 hardcode (covered above). The identity is purely functional — two sentences with no voice, values, or communication style.

### DEFAULT TO PARALLEL Directive

```
DEFAULT TO PARALLEL: Unless you have specific reason operations MUST be
sequential, DEFAULT TO PARALLEL tool calls. Maximize parallel tool calls.
Aim for 3-5 tool calls per turn where possible.
```

**What it does well:** everything. Early placement, explicit negation of the sequential default, quantified target. This is the cleanest behavioral directive in any competitor prompt.

**What fails:** nothing significant. The only limitation is that it relies on the model following the instruction — there is no runtime enforcement. If the model underperforms on parallel batching, there is no fallback mechanism in the runtime layer.

### Todo State Injection

```
[Injected dynamically each turn]:
Current Tasks:
  - task_a: [description] [status]
  - task_b: [description] [status]
  ...
```

**What it does well:** the model always has current task state. There is no risk of the model acting on stale task information because the state is refreshed on every turn.

**What fails:** unconditional injection. The todo block appears on turns where it provides zero value (conversational queries, factual questions, one-line commands). This is token waste with no compensating benefit on those turns.

### Tool Routing Rules

The tool routing section establishes which tools to use and when. The parallel directive lives here.

**What it does well:** the co-location of the parallel directive with the tool routing rules is correct. The model encounters the directive at exactly the moment it is deciding how to use tools.

**What fails:** no tool hierarchy. Claude Code v2 specifies a clear preference ordering (dedicated tools over Bash; Bash only when no dedicated tool exists). Cursor's tool routing rules do not establish this hierarchy, which means the model may default to Bash for operations that have purpose-built tools.

### Status Update Mandate

```
After completing each tool batch, before starting the next, emit a brief
status update: 1-3 sentences covering what you just completed and what
you are starting next.
```

**What it does well:** the 1-3 sentence constraint is well-calibrated. Long enough to be informative, short enough to not interrupt flow. The placement of the mandate immediately after the parallel directive creates a rhythm: batch tools → emit status → batch tools → emit status.

**What fails:** it is purely in-prompt. If the model decides to skip the status update, nothing in the runtime layer catches or compensates. There is no structured event (like an SSE heartbeat) that guarantees the user receives an update.

### cite_blocks Format

```
cite_blocks: {
  "file": "src/auth/session.ts",
  "startLine": 45,
  "endLine": 62,
  "content": "..."
}
```

**What it does well:** machine-parseable, IDE-navigable, separates reference from change.

**What fails:** environment-specific. In any context other than the Cursor IDE (CLI, web, API), cite_blocks render as inert JSON. There is no graceful degradation to a human-readable format when the rendering environment does not support the format.

### Output Rules

```
Never output code inline — use edit tools.
Markdown only where semantically correct.
Do not use markdown in response to conversational messages.
```

**What it does well:** the "do not use markdown in conversational responses" rule is correct and rarely implemented. LLMs default to markdown everywhere. Cursor explicitly tells the model to suppress markdown for conversational exchanges.

**What fails:** the rule against inline code output is an IDE-specific constraint. In Cursor, showing code inline would conflict with the diff-rendering UI. In other contexts, inline code output is often preferable. This rule is not portable.

---

## 5. Lessons for OSA

### What We Adopted

**Parallel-first directive.** OSA's tool process section now includes an explicit DEFAULT TO PARALLEL rule with the same early placement. Wording adapted to OSA's tool routing context but semantically identical to Cursor's. Source: `tasks/docs/07-competitor-prompt-ranking.md`, confirmed adoption.

**Status update mandate between tool batches.** OSA adopted the requirement to emit a summary after each tool batch before starting the next. Implementation differs: OSA's status updates are structured SSE events (typed `{type: "status", content: "..."}`) rather than inline text, which gives the TUI layer control over display formatting. The in-prompt mandate is present as a fallback for non-SSE channels.

### What We Skipped

**cite_blocks format.** OSA's CLI rendering layer has no IDE context. File references in OSA output use plain text paths (`path/to/file.ex:45`) which are readable in terminal output and linkable in TUI. The cite_blocks JSON format adds no value without an IDE to consume it.

**todo_write merge semantics.** OSA uses its own task tracker (`/tm-*` commands) backed by `tasks/todo.md`. The semantics differ: OSA tasks are line-item checkboxes in a markdown file rather than a structured state store. Merge semantics are not applicable to this model. The corresponding OSA protection against silent drops is that the task file is append-only during a session — new tasks are added at the bottom, existing tasks are updated in place.

**Unconditional todo injection.** OSA's context assembler (`context.ex`) injects the task state block in Tier 2, not Tier 1. Tier 2 content is conditional on budget availability AND signal relevance. A task-state block is only injected when the signal classifier detects a task-relevant message (weight > 0.7 AND genre in {spec, bug_report, directive}). Conversational and factual queries do not trigger task state injection.

### Where OSA Is Strictly Better

**Signal classification.** Cursor treats every message identically. OSA classifies every message on 5 dimensions (mode, genre, type, format, weight) before any prompt assembly occurs. A weight-0.15 acknowledgment like "ok" is caught by the deterministic noise filter and either skipped or answered without a full LLM call. This eliminates a category of waste that Cursor has no mechanism to address.

**Noise filtering.** OSA's two-tier noise filter (deterministic pattern match < 1ms, LLM-based uncertainty resolution ~200ms) short-circuits 40-60% of messages before they reach the full pipeline. Cursor has no equivalent gate.

**Personality and identity.** Cursor has 2 sentences of identity. OSA has 400+ words in IDENTITY.md covering capabilities, signal modes, and constraints, plus 500+ words in SOUL.md covering personality, communication style, values, and failure modes. The practical difference: OSA's responses adapt to the user, the topic, and the conversation depth. Cursor's responses are uniformly competent.

**Signal-adaptive output.** Cursor's output rules are static — the same rules apply to a typo fix and an architecture redesign. OSA's output behavior changes per signal mode:
- EXECUTE mode: concise, action-first, no preamble
- BUILD mode: structured, progressive disclosure, show work
- ANALYZE mode: thorough, explicit reasoning, use structure
- ASSIST mode: explanatory, match user depth

This is not cosmetic. A concise rule applied to a complex analysis request produces a low-quality response. An expansive rule applied to a simple command produces noise. Static output rules cannot be correct for both.

**Memory.** OSA has `/mem-save` (persist decision/pattern/solution/context) and `/mem-search` (keyword-relevant retrieval). Cross-session memory means an OSA deployment learns user preferences, project conventions, and past decisions. Cursor amnesia-resets on every session.

**Token budgeting.** OSA's context assembler operates within a configurable token budget with a priority-tiered fallback. If the budget fills, Tier 4 content (OS templates, machine-specific context) is truncated before Tier 1 content (security guardrail, identity, soul) is touched. Cursor injects its fixed ~800-line prompt every turn with no budget management.

**Model-agnostic identity.** OSA does not hardcode a model name in its system prompt. The runtime block injects `provider` and `model` as structured variables. The identity layer reads those variables. If the provider changes from Anthropic to Groq, the system prompt updates automatically.

### Where Cursor Is Still Ahead

**IDE integration.** This is not a prompt architecture advantage — it is a product architecture advantage. Cursor's cite_blocks, diff rendering, plan mode with editable markdown, and file navigation from agent output are only possible because Cursor controls the editor. OSA operates in CLI, HTTP, and messaging channels. The UX ceiling for OSA's TUI is lower than Cursor's IDE by design.

**Parallel execution with git worktrees.** Cursor 2.0 supports 8 parallel agents running in isolated git worktrees. This is a runtime infrastructure feature. OSA's orchestrator supports 10 parallel agents but shares the working directory without worktree isolation. Cursor's isolation model is safer for large multi-agent tasks where agents might conflict on file edits.

**Background agents.** Cursor's background agents run async tasks that complete while the user is doing other work. OSA's agent orchestration is session-scoped. True background execution (persisting across sessions, resumable from any client) is not yet implemented.

---

## 6. Competitive Verdict

Cursor's system prompt scores 8/10 because it solves the right problems in the right places. The DEFAULT TO PARALLEL directive is the best single behavioral directive in the competitor field — well-placed, explicit, quantified, and measurably effective. The status update mandate addresses a real UX failure mode. The merge semantics on `todo_write` prevent a real data-loss bug.

The failures are systematic. No signal classification means every message is processed with full cost regardless of signal weight. No noise filtering means trivial inputs burn LLM tokens. No personality means users get a capable tool with no voice. The GPT-5 identity hardcode is a separation-of-concerns error that gets worse as Cursor's backend diversity grows.

The architectural ceiling of Cursor's prompt is the absence of adaptivity. Every mechanism in the prompt is static: static identity, static output rules, static todo injection, static tool routing rules. The prompt does not change based on what the user said. Cursor's agent behaves identically whether the user is asking a factual question, planning an architecture, or debugging a crash. That uniformity is a feature for predictability and a limitation for quality.

OSA's architecture is adaptive at every layer that Cursor is static. Signal classification changes prompt assembly. Mode overlays change output behavior. Noise filtering changes whether the LLM is called at all. Memory changes what context is available. Communication profiling changes how the response is framed. These are not cosmetic differences — they represent a fundamentally different philosophy: the system should understand the message before it responds to it.

Where Cursor wins: product integration (IDE), background execution, and git worktree isolation. These are infrastructure advantages unrelated to prompt architecture.

Where OSA wins: every dimension of prompt architecture. Signal intelligence, adaptivity, personality, memory, noise filtering, token budgeting, model-agnostic design. OSA's prompt architecture is the stronger system. The IDE gap is the honest competitive weakness.

| Dimension | Cursor | OSA | Winner |
|-----------|--------|-----|--------|
| Parallel execution directive | Explicit, bolded, quantified, early | Adopted from Cursor | Tie |
| Status updates | In-prompt mandate | In-prompt + structured SSE | OSA |
| Todo management | Merge semantics, injected every turn | Signal-conditional injection, append-only | OSA |
| Signal classification | None | 5-tuple + noise filter | OSA |
| Output adaptivity | Static rules | Mode-driven overlays | OSA |
| Identity / personality | 2 sentences | 900+ words across 2 files | OSA |
| Memory | None | Cross-session with retrieval | OSA |
| Model agnosticism | GPT-5 hardcoded | Runtime-injected | OSA |
| Token efficiency | ~800 lines unconditional | 4-tier budget-aware assembly | OSA |
| IDE integration | Full editor, worktrees | CLI/TUI only | Cursor |
| Background agents | Yes | Not yet | Cursor |

**Final scores: Cursor 8/10 — OSA 9.5/10 (target)**

The gap between Cursor's prompt and OSA's prompt architecture is not incremental. It is the difference between a well-engineered static system and an adaptive system that understands what it is responding to before it responds.

---

*See also:*
- *[Competitor Rankings](07-competitor-prompt-ranking.md) — full 8-tool ranking with adoption decisions*
- *[System Prompt Anatomy](../tasks/docs/02-system-prompt-anatomy.md) — section-by-section comparison across 7 tools*
- *[Signal Theory Architecture](../architecture/signal-theory.md) — OSA's classification framework*
- *[Feature Matrix](feature-matrix.md) — full feature comparison across all competitors*
