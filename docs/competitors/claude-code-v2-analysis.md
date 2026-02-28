# Claude Code v2 — Prompt Engineering Analysis

> Purpose: Deep analysis of Claude Code v2's system prompt architecture — what makes it work, where it fails, and what OSA adopted, skipped, or surpassed.

---

## 1. Prompt Architecture Overview

Claude Code v2's system prompt is approximately 1,150 lines. It is monolithic — a single string assembled by concatenation at startup with no static/dynamic split. The architecture has four structural characteristics that define everything that follows.

**Full JSON tool schemas embedded inline.** Every tool the agent can call gets its complete JSON schema, parameter descriptions, types, and usage notes injected directly into the system prompt. This is not a list of tool names — it is the full API contract for every tool, readable by the model as part of its context.

**Environment block injected at the end.** Operating system, working directory, current date, Git state, and model identifier are appended to the system prompt at startup. This block is dynamic in the sense that it varies per session, but it is not rebuilt per iteration — it is set once at session start and remains static for the session's lifetime.

**No caching split.** All 1,150 lines are re-sent as the system message on every API call. There is no `cache_control` hint applied to the stable portion of the prompt. Anthropic's own prompt caching feature — available on the Anthropic API since 2024 — is not used by Anthropic's own coding tool.

**No tiering, no dynamic truncation.** The prompt is not token-budget-managed. There is no priority ordering that would drop low-importance sections if the context window fills. If the conversation grows large, the system prompt competes with conversation history for the available window.

Assembly order:
```
1.  Identity (2 sentences)
2.  Security guardrails
3.  Help / feedback routing
4.  Documentation lookup rules
5.  Professional objectivity
6.  Tone and style (adaptive)
7.  Proactiveness balance
8.  Task management (TodoWrite rules)
9.  Doing tasks (workflow)
10. Tool usage policy
11. Environment info
12. Model info
13. [Tool schemas appended by framework]
```

---

## 2. What Makes It Good — Score: 9/10

### 2.1 Tool Schema Injection (Best in Class)

The most technically significant aspect of Claude Code v2's prompt is its tool schema injection strategy. Every tool gets a complete JSON schema with parameter names, types, required/optional flags, and natural-language usage notes. The contrast with competitors is stark:

- **Cline**: Tool names in an XML tag list. No schemas, no descriptions.
- **Gemini CLI**: Function names with brief one-line descriptions.
- **Codex CLI**: Tool references in prose without schemas.
- **Claude Code v2**: Full JSON schema with `description`, `type`, `required`, and inline usage guidance per parameter.

Why this matters: language models produce significantly more reliable tool calls when they can see the exact parameter contracts rather than inferring them. A tool called `file_edit` with no schema could mean a hundred different things. A tool with explicit schema — `old_string: {type: string, description: "The exact text to replace — must match character-for-character"}` — removes the inference burden and reduces hallucinated parameters. This is the single strongest engineering decision in Claude Code v2's prompt.

### 2.2 TodoWrite State Machine

Claude Code v2 implements a four-state task tracking system via the `TodoWrite` tool: `pending → in_progress → completed → cancelled`. The prompt includes explicit rules for when to create todos, how to update status, and the obligation to reconcile the todo list after each meaningful step.

The mechanism solves a genuine multi-step agent failure mode: the agent that executes 12 tool calls with no external state and then either succeeds silently or fails with no trace of what was completed. TodoWrite creates an observable work queue. The user can see current status without reading the conversation. The agent cannot silently skip steps without leaving evidence.

The state machine is also a self-accountability mechanism — marking a task `completed` when it is not yet verified creates an inconsistency the model can be prompted to resolve. The explicit `cancelled` state handles the case where a planned step turns out to be unnecessary, rather than leaving dangling `pending` items.

### 2.3 Git Safety Protocol

Claude Code v2 dedicates a substantial section to Git-specific rules. The key prohibitions, stated explicitly:

- Never force push without explicit user confirmation
- Never skip pre-commit hooks (`--no-verify`)
- Never amend a commit blindly after a hook failure — create a NEW commit instead
- Stage specific files rather than `git add .` (which can include secrets)
- Check `git status` and `git diff` before committing

The "new commit after hook failure" rule is the most sophisticated. The failure mode it prevents: a pre-commit hook fails (linter error, test failure), the agent runs the fix, then re-amends the original commit. If the hook failed on the original commit's content, the staged state after the fix may be inconsistent. A clean new commit is always safer. This rule reflects operational experience with real Git workflows that most prompt authors don't have.

### 2.4 Parallel Tool Batching

Claude Code v2 includes an explicit directive to batch independent tool calls into a single response. The exact instruction: "Call multiple tools in a single response." The prompt gives examples of which operations can be parallelized safely (reading multiple files) versus which require sequential execution (operations where output of one is input to the next).

This directive is load-bearing. Without it, models default to sequential tool calling — one tool per response, wait for result, call next tool. Sequential execution on a task requiring 10 file reads produces 10 round-trip latencies where 1 round-trip (with 10 parallel reads) would suffice. Cursor makes this even more explicit with "DEFAULT TO PARALLEL" in bold near the top of its prompt. Claude Code v2's version is correct but less prominent.

### 2.5 Proactiveness Balance

Claude Code v2 includes a dedicated section with explicit rules on when to act proactively versus when to ask. The structure is:

- Explicit list of acceptable proactive behaviors (fix obvious errors, suggest relevant improvements)
- Explicit list of prohibited proactive behaviors (don't add features, don't commit without being asked)
- A tie-breaking principle: the cost of over-proactiveness (unwanted changes, scope creep) exceeds the cost of under-proactiveness

The tie-breaking principle is particularly valuable. A binary rule ("don't be too proactive") fails when the model encounters an edge case not covered by the explicit list. An asymmetric cost framing ("over-proactiveness costs more — default to asking") handles novel cases correctly without explicit enumeration.

### 2.6 Output Minimization

Claude Code v2's tone section includes "brevity is the soul of wit" as a guiding principle, operationalized as: response length should match the complexity of the request. Simple task → brief confirmation. Complex architecture → structured explanation. The prompt explicitly prohibits preamble ("Sure, I'd be happy to...") and postamble ("Let me know if there's anything else...").

This is a regression from Claude Code v1, which had the stricter "fewer than 4 lines" rule. v2's version is more adaptive but relies on the model calibrating complexity correctly. The result is better for complex tasks and slightly noisier for trivial ones.

---

## 3. What Makes It Bad

### 3.1 No Signal Classification

Claude Code v2 applies the same processing pipeline to every message. "hey" and a 500-word architecture request receive the same treatment: the same system prompt length, the same tool availability, the same format assumptions.

This is a fundamental architectural choice with compounding costs. A trivial message that could be answered in one sentence still incurs the full input token cost of a 1,150-line system prompt. An architecture-level question that would benefit from structured thinking, plan mode, and heavier tool use receives no signal that it should be handled differently from a greeting.

The failure mode is not dramatic — it is a continuous efficiency leak and quality floor problem. Users who fire off quick messages pay disproportionate API costs. Users who need deep analysis get a response calibrated to "average complexity" rather than their specific signal weight.

No competitor in the market has implemented signal-adaptive behavior at the prompt level. This is not a criticism unique to Claude Code v2 — it is a gap in the entire competitive field.

### 3.2 No Personality

The identity section of Claude Code v2 is two sentences:

> "You are a Claude agent, built on Anthropic's Claude Agent SDK."
> "You are an interactive CLI tool that helps users with software engineering tasks."

That is the complete personality definition. There are no values, no communication style, no banned phrases, no character. The professional tone section adds formality calibration — match the user's register — but that is style adaptation, not identity.

The consequence is that responses feel sterile and interchangeable. Users do not form a relationship with a tool that has no character. Long-term retention and user satisfaction correlate with perceived personality in conversational interfaces. Claude Code v2's approach prioritizes functional accuracy over character, which is a legitimate design choice — but it is a choice with costs that manifest over weeks of use rather than in initial testing.

Compare: Codex CLI establishes "remote teammate, knowledgeable and eager to help" in its first sentence. Windsurf declares "You are Cascade, built on the AI Flow paradigm" and uses the paradigm throughout. These are thin by OSA's standards but they exist. Claude Code v2's identity is purely functional.

### 3.3 No Prompt Caching

This is the most ironic structural flaw in Claude Code v2: Anthropic's own coding tool does not use Anthropic's prompt caching feature.

Prompt caching works by splitting the system message into a stable block (marked with `cache_control: {type: "ephemeral"}`) and a dynamic block. Subsequent API calls within the cache TTL (5 minutes for ephemeral) receive the stable block from cache at approximately 10% of the normal input token cost.

Claude Code v2's 1,150-line system prompt is sent in full on every API call. In a typical session with 8 conversation turns and an average of 3 ReAct iterations per turn, that is 24 system prompt sends per session. At roughly 1,000 tokens per system prompt, that is 24,000 input tokens per session devoted entirely to the system prompt — before a single user message is processed.

With a static/dynamic split, 90% of those tokens (the identity, tool schemas, git rules, proactiveness section — everything that doesn't change per request) would be cached after the first send. The remaining 24 sends would cost approximately 2,400 token-equivalent units for that portion. The reduction is 86% on the stable portion of input tokens.

OpenCode — a significantly less resourced competitor — implemented prompt caching with a two-part split: `anthropic.txt` as stable prefix, dynamic context as per-request suffix. Claude Code v2 has not.

### 3.4 No Noise Filtering

All messages go through the full pipeline regardless of content. A greeting, a one-word acknowledgment, and a multi-file refactoring request are processed identically at the infrastructure level:

1. Append to conversation history
2. Build system prompt (1,150 lines)
3. Send full context to API
4. Execute ReAct loop
5. Return response

A message like "thanks" costs the same as a complex task in terms of system prompt tokens. More significantly, there is no short-circuit: the model is always asked to reason over the full tool set for every input, even inputs where tool use is obviously unnecessary. This wastes inference capacity and produces responses that feel over-engineered for casual messages.

A two-tier noise gate — pattern matching for clearly trivial inputs at the infrastructure layer before the LLM is invoked — would eliminate this waste. No competitor implements this. Claude Code v2 does not implement this.

### 3.5 Monolithic Structure

The 1,150-line prompt was clearly assembled by concatenation over time. There is no narrative flow from one section to the next. The "professional objectivity" section (section 5 in the assembly order) sits between "help/feedback routing" and "tone and style" with no logical connection to either neighbor. Tool usage rules appear in section 10, after doing-tasks in section 9, despite the model needing the tool rules to understand the doing-tasks instructions.

The practical consequence is prompt coherence degradation. When sections do not reference each other, the model treats them as independent policies rather than a unified behavioral framework. Rules that should reinforce each other (output minimization + proactiveness balance) are separated by unrelated content, reducing the probability that the model applies them together.

By contrast, OSA's `SYSTEM.md` is written as a single authored document with deliberate section ordering: Security → Identity → Signal System → Personality → Tool Usage → Task Management → Doing Tasks → Git → Output → Proactiveness. Each section builds on the previous. Tool usage appears before doing-tasks because the doing-tasks instructions assume the model knows which tools to use.

### 3.6 No Memory System

Every Claude Code v2 session starts from zero. The only cross-session persistence is the CLAUDE.md file — a project-level configuration file that users must manually maintain. The agent has no automatic learning, no pattern recognition across sessions, no ability to remember user preferences without explicit documentation.

This means users repeat themselves. Preferences established in session one must be re-stated in session two. Mistakes corrected in session one may recur in session three. The agent has no ability to notice that a user consistently prefers a particular code style, or that a specific type of request always requires a specific pre-check.

The architectural gap is fundamental, not cosmetic. Implementing cross-session memory requires persistent storage, memory indexing, and a retrieval mechanism — none of which are present in Claude Code v2. Windsurf has a basic memory system. OpenClaw has a sophisticated hybrid RAG system. Claude Code v2 has a manually-maintained markdown file.

### 3.7 Single Provider Lock-in

Claude Code v2 is designed exclusively for Anthropic's API. The agent identity ("You are a Claude agent, built on Anthropic's Claude Agent SDK") is model-specific. Tool schemas are calibrated for Claude's function calling format. There is no multi-provider support, no Ollama integration, no path to running locally.

For users in restricted networks, users with data privacy requirements, or users who want to experiment with other frontier models, Claude Code v2 is unavailable by design. The single-provider constraint is a market positioning choice, not a technical necessity.

---

## 4. Section-by-Section Breakdown

### 4.1 System Identity Block

**What it does.** Establishes that the agent is a CLI tool for software engineering tasks, built on the Anthropic Agent SDK.

**Why it works (partially).** The two-sentence identity gives the model a functional anchor. "CLI tool for software engineering" correctly scopes tool selection — file operations, shell commands, code editing — and prevents the model from behaving as a general-purpose chat assistant. The "Agent SDK" attribution correctly positions the tool within the agent execution framework.

**Why it doesn't work (fully).** Two sentences is not an identity. It is a label. A label tells the model what it is not, more than what it is. "CLI tool" rules out "chatbot" but does not establish voice, values, or decision-making character. The model fills in the gaps from training-time defaults: corporate-sounding, overly deferential, hedging on uncertainty. Users experience this as the tool feeling generic despite being technically capable.

**What OSA does differently.** OSA's identity section is approximately 400 words covering: name and pronunciation, paradigm negation ("you are NOT a chatbot"), OS-inhabitation metaphor, signal processing loop as self-concept, and a complete capabilities list including all supported channels. The signal processing loop is embedded in the identity section so the model treats classification as perceptual rather than procedural.

### 4.2 Tool Definitions and Routing

**What it does.** Provides complete JSON schemas for all available tools, followed by routing rules that establish a preference hierarchy: dedicated tools over shell equivalents.

**Why it works.** The full schema injection is the strongest engineering decision in the prompt (see 2.1). The routing hierarchy (`file_read` over `cat`, `file_edit` over `sed`) eliminates the most common tool misuse pattern — using the shell as a universal escape hatch.

**Why it doesn't (fully) work.** The tool schemas are embedded in the system prompt at the end of the document, after the behavioral rules. This means the model encounters the behavioral rules (section 10: tool usage policy) before it encounters the tool specifications. The model is told "prefer file_read over cat" before it sees what file_read's parameters are. Correct reading order would be: here are the tools, here is how to use them. Claude Code v2 inverts this.

**What OSA does differently.** OSA injects `{{TOOL_DEFINITIONS}}` inside the Tool Usage Policy section (Section 5), immediately after the routing rules. The model reads "use file_read not cat" and then immediately sees the file_read schema. The instruction and the specification appear in the same context window region, reinforcing each other.

### 4.3 TodoWrite / Task Management

**What it does.** Establishes a four-state task tracking system (`pending → in_progress → completed → cancelled`), defines when to create todos (3+ steps, multi-file changes), and mandates status reconciliation after each meaningful step.

**Why it works.** This is Claude Code v2's second-strongest engineering decision. The state machine is a behavioral contract — the agent cannot quietly skip steps or claim completion without updating the observable record. Users who read the todo list can understand what the agent is doing without reading 20 tool call results.

**Why it doesn't (fully) work.** The reconciliation requirement — update the todo list after each tool call — is aggressive. On a task with 15 tool calls, this produces 15 TodoWrite updates, most of which are noise. Cursor's version has the same problem. OSA's version requires task updates at batch boundaries (after a group of related tool calls), not after every individual call.

**What OSA does differently.** OSA's `task_write` protocol requires completion evidence: you cannot mark a task completed without attaching output (test results, compiler output, a file path). This prevents the premature completion failure mode where the model marks something done because it "believes" the task is complete without verification.

### 4.4 Git Workflows

**What it does.** Establishes a commit protocol (status → diff → log → stage specific files → commit), a PR protocol, and safety rules (no force push, no `--no-verify`, new commit after hook failure).

**Why it works.** Git safety rules prevent catastrophic failures that are easy to trigger and hard to recover from. Force push to main, amending a commit with staged secrets, skipping hooks that exist for good reason — these are real failure modes that have caused real data loss in real projects. Explicit prohibitions are the only reliable defense when the agent has shell access.

**Why it doesn't (fully) work.** The git section is embedded inside the "doing tasks" section rather than as a standalone protocol. This reduces its prominence and makes it easier for the model to apply the "doing tasks" workflow without engaging the git-specific rules. Separating git into its own section (as OSA does) gives it appropriate weight.

**What OSA does differently.** OSA adds one rule not present in Claude Code v2: `git log --oneline -5` before committing, to match the repository's existing commit style. This prevents OSA commits from looking different from the project's history — a subtle quality signal that matters in collaborative codebases.

### 4.5 Output Formatting Rules

**What it does.** Establishes that response length should match request complexity. Prohibits preamble ("Sure, I can help with that") and postamble ("Let me know if you need anything else"). Calibrates markdown usage to context.

**Why it works.** The preamble/postamble prohibition is the single highest-leverage formatting rule available. Eliminating these phrases alone saves 10-30 tokens per response and increases the signal density of every output. The complexity-matching rule is correct in principle.

**Why it doesn't (fully) work.** "Match complexity" is vague without calibration guidance. What counts as a simple request vs a complex one? Without explicit thresholds, the model uses heuristics that are inconsistent across sessions. A 3-line question might get a 20-line response if the model classifies it as complex, or a 2-line response if it classifies it as simple. Signal Theory's weight thresholds (< 0.2 / 0.2-0.5 / 0.5-0.8 / > 0.8) give the model explicit calibration points that produce consistent output depth.

**What OSA does differently.** OSA's brevity rule is tied explicitly to signal weight: "Fewer than 4 lines unless detail is requested or signal weight demands more." The phrase "signal weight demands more" is not prose — it refers to the specific thresholds defined in Section 3 of SYSTEM.md. A model that has read both sections knows that weight > 0.8 unlocks detailed responses and weight < 0.2 constrains to brief natural replies. The calibration is numeric and consistent.

### 4.6 Proactiveness Balance

**What it does.** Defines when the agent should act without being asked (fix obvious errors, surface relevant improvements) and when it should not (don't add features, don't commit unasked). Provides a tie-breaking principle: over-proactiveness costs more than under-proactiveness.

**Why it works.** The tie-breaking principle is the section's most valuable element (see 2.5). It handles edge cases not covered by the explicit lists by encoding the correct asymmetry: when in doubt, ask rather than act. This is the correct default for an agent operating on someone else's filesystem.

**Why it doesn't (fully) work.** The affirmative proactive behaviors are underspecified. "Fix obvious errors you notice" is correct but vague — what counts as obvious? "Suggest relevant improvements when minor and clearly beneficial" provides no calibration for what is minor or clearly beneficial. These gaps are filled by the model's priors, which vary.

**What OSA does differently.** OSA specifies the acceptable proactive categories explicitly: typos, missing imports, broken links, code quality issues, security surface issues, performance surface issues, and pattern recognition ("You've been working on this a while..."). The enumeration removes the inference burden.

### 4.7 Environment Injection

**What it does.** Appends a block at the end of the system prompt containing: operating system, shell, working directory, current date, Git repository state (branch, recent commits), Anthropic model identifier.

**Why it works.** Environment context enables correct tool routing. An agent that knows it is on macOS vs Linux knows which shell commands work. An agent that knows the current Git branch knows whether it is on a feature branch or main. The model cannot infer this from training data — runtime context must be injected.

**Why it doesn't (fully) work.** The environment block is appended once at session start and not updated. Git state in particular can change during a long session — the model may have a stale view of the repository if commits are made mid-session. Per-iteration environment refresh (at the dynamic block level) would be more accurate.

**What OSA does differently.** OSA's environment block is a per-request dynamic block, not a session-level static block. `git status`, current timestamp, and model identifier are rebuilt on each `Context.build/2` call. The model always has an accurate view of system state at the time of each response.

---

## 5. Lessons for OSA

### 5.1 What We Adopted and Why

**TodoWrite → task_write protocol.** The state machine concept and the observable work queue mechanism are directly adopted. OSA adds the evidence requirement on completion and drops the per-tool-call reconciliation in favor of batch-level updates.

**Git safety protocol.** The full set of prohibitions — no force push, no `--no-verify`, no blind amend, specific file staging — is adopted verbatim. OSA adds the `git log --oneline -5` style-matching step.

**Proactiveness balance section.** The asymmetric cost framing is adopted directly. OSA adds explicit enumeration of acceptable proactive categories and the "mention and defer" tie-breaker articulation.

**Output minimization patterns.** The preamble/postamble prohibition is adopted. OSA replaces the vague "match complexity" calibration with explicit signal weight thresholds.

**Parallel batching directive.** Adopted and strengthened: OSA adds "3-5 tools per turn when possible" from Cursor, which is more explicit than Claude Code v2's general instruction.

**Tool preference hierarchy.** The "dedicated tools over shell equivalents" routing rules are adopted with an extended list covering more tool pairs.

### 5.2 What We Skipped and Why

**Per-tool JSON schemas in the system prompt.** OSA injects tool schemas dynamically at boot time via `{{TOOL_DEFINITIONS}}`. This achieves the same result — the model sees complete schemas — while allowing tools to be added or modified without editing the base system prompt. Embedded schemas in the base prompt become maintenance debt as the tool set evolves.

**Agent SDK identity framing.** "You are a Claude agent, built on Anthropic's Claude Agent SDK" is Anthropic-specific branding that OSA cannot adopt without misrepresentation. OSA's identity is provider-neutral: "You are OSA — the Optimal System Agent."

**Session-level environment injection.** Replaced by per-request dynamic environment block for accuracy reasons described in 4.7.

**Monolithic prompt assembly.** Replaced by the static/dynamic two-tier split, enabling Anthropic's prompt caching and reducing per-iteration token costs by approximately 86% on the static portion.

### 5.3 Where OSA Is Strictly Better

**Signal-adaptive behavior.** OSA classifies every message on five dimensions (Mode, Genre, Type, Format, Weight) and adjusts system behavior accordingly. Claude Code v2 applies uniform processing. The impact is most visible at the extremes: trivial messages in OSA get brief natural responses and skip tool invocation entirely; high-weight signals trigger plan mode, heavier tool use, and structured output. Claude Code v2 produces the same response style for both.

**Personality system.** OSA's SYSTEM.md Section 4 contains approximately 500 words of character definition: communication style, banned phrases with annotations, values as explicit trade-off pairs, decision-making procedures. Claude Code v2's identity is two sentences. The depth difference produces measurably different user experience over extended sessions.

**Prompt caching.** OSA's static/dynamic split enables Anthropic prompt caching on the stable portion (~800-1200 tokens). At 24 system prompt sends per typical session, this reduces static prompt input tokens by approximately 86%. Claude Code v2 does not use prompt caching despite being built by the company that provides it.

**Noise filtering.** OSA implements a two-tier pre-LLM gate: pattern matching for clearly trivial inputs at the infrastructure layer (`loop.ex`) before the LLM is invoked. Greetings, single-word acknowledgments, and other low-signal messages are handled without a full API call. Claude Code v2 sends all inputs through the full pipeline.

**Cross-session memory.** OSA persists patterns, solutions, decisions, and context across sessions. Users do not repeat themselves. Corrections teach the system. Claude Code v2 has no automatic cross-session learning.

**Multi-provider support.** OSA routes to 18 providers including Ollama for fully local execution. Claude Code v2 is Anthropic-only.

**Cohesive document structure.** OSA's SYSTEM.md reads as a single authored document. Claude Code v2's prompt reads as sections concatenated over time. Narrative coherence produces more consistent behavioral compliance from the model.

**Token-budgeted context assembly.** OSA's context builder manages a priority-ranked section list with explicit token budgets per tier. If context fills, low-priority sections are dropped rather than truncating the conversation. Claude Code v2 has no such mechanism.

### 5.4 Where Claude Code v2 Is Still Ahead

**Tool schema quality and density.** Claude Code v2's tool schemas are the most detailed in the competitive field. The usage notes per parameter are production-grade documentation. OSA's `{{TOOL_DEFINITIONS}}` injection can match this, but the quality depends on how each tool's documentation is written. Claude Code v2's schemas are consistently excellent.

**Ecosystem maturity.** Claude Code v2 benefits from Anthropic's production usage data across millions of sessions. Its behavioral rules reflect real failure modes observed at scale. OSA is earlier in its development cycle and its rules reflect a smaller operational dataset.

**Agent orchestration primitives.** Claude Code v2's `Task` tool spawns subagents with full execution context. The primitive is clean and production-tested. OSA's agent orchestration system is more capable architecturally (wave execution, 9 roles, 10 swarm presets) but the individual primitive quality is still maturing.

---

## 6. Competitive Verdict

Claude Code v2 scores 9/10 in the competitor ranking for one reason: it nailed the fundamentals that most competitors got wrong. Full tool schemas, structured task tracking, explicit Git safety, and parallel batching are each individually impactful. Together, they produce an agent that behaves consistently on real software engineering tasks where most competitors produce inconsistent results.

The weaknesses are architectural rather than tactical. No signal classification, no prompt caching, no memory, no personality, monolithic structure — these are not bugs in individual sections. They are design decisions that compound into a system that is functionally excellent and strategically limited.

The functional ceiling of Claude Code v2's architecture is roughly where it is now. Getting from 9/10 to 9.5/10 would require architectural changes (caching split, signal classification, memory system) that would require significant rework of the existing structure.

OSA's target is 9.5/10 by building on Claude Code v2's tactical wins while addressing its architectural gaps.

**Specific metrics where OSA outperforms or targets outperformance:**

| Metric | Claude Code v2 | OSA |
|--------|----------------|-----|
| Prompt caching savings | 0% | ~86% on static portion |
| Signal classification | None | 5-tuple per message |
| Cross-session memory | Manual (CLAUDE.md) | Automatic (MEMORY.md + SICA) |
| Personality depth | 2 sentences | ~500 words |
| Noise filtering | None | 2-tier pre-LLM gate |
| Provider support | 1 (Anthropic) | 18 (including Ollama local) |
| Task completion evidence | Not required | Required |
| Environment freshness | Session-level (stale) | Per-request (current) |
| Prompt coherence | Concatenated sections | Single authored document |
| Tool schema placement | End of document | Adjacent to routing rules |

**The one thing Claude Code v2 does that no prompt engineering trick can replace**: production data at scale. Their behavioral rules are calibrated against real failure modes encountered by millions of developers. OSA's rules are correct in principle. Over time, operational data will close this gap. It is not a prompt engineering problem — it is a time-in-market problem.

---

*See also: [Competitor Prompt Ranking](../tasks/docs/07-competitor-prompt-ranking.md) | [System Prompt Anatomy](../tasks/docs/02-system-prompt-anatomy.md) | [System Prompt Restructuring](../tasks/docs/06-system-prompt-restructuring.md)*
