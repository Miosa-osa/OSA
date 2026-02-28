# Windsurf System Prompt Analysis

> Competitor: Windsurf (Codeium)
> Score: 7/10
> Category: IDE Agent (VS Code fork)
> Threat Level: MEDIUM-HIGH
> Analysis date: 2026-03-01

---

## Purpose

This document dissects the Windsurf system prompt architecture — what it does well, where it fails, and what (if anything) OSA should adopt. The goal is to be precise, not diplomatic.

---

## 1. Architecture Overview

Windsurf's system prompt is approximately 600 lines and follows a Flow-based composition model. Rather than a flat monolith, it assembles at runtime from three injected layers:

```
┌─────────────────────────────────────────────┐
│  WINDSURF SYSTEM PROMPT (runtime assembly)  │
├─────────────────────────────────────────────┤
│  Layer 1: Flow Prompt (static baseline)     │
│    - Identity, tool definitions, voice       │
│    - Tool use constraints                    │
│    - Cascade (their word for agent loop)     │
├─────────────────────────────────────────────┤
│  Layer 2: Plan State (injected per turn)     │
│    - Current plan.md contents               │
│    - Step completion status                  │
│    - Last N actions taken                    │
├─────────────────────────────────────────────┤
│  Layer 3: Memory Injection (per user)        │
│    - Persisted user preferences              │
│    - Previously observed patterns            │
│    - Workspace context (repo, lang, stack)   │
└─────────────────────────────────────────────┘
```

Each conversation turn re-injects layers 2 and 3, updating the plan state and memory with anything learned in the previous turn. Layer 1 stays static across the session.

The agent operates in what Windsurf calls "Cascade" — their branded name for a bounded ReAct loop with a hard iteration cap. The cap is not published but empirically appears to be 20-25 turns before it halts and asks the user to continue.

---

## 2. What Makes It Good

### 2.1 Plan Update Protocol

Windsurf's most distinctive structural feature is its **plan update obligation**. After every significant action, the prompt explicitly instructs the model to:

1. Identify which plan step was just completed
2. Mark it done in the plan file
3. Write a one-sentence "what changed" summary
4. State the next step before proceeding

The plan file is not just a pre-execution artifact — it is a live document that the agent reads and writes throughout execution. This produces two benefits:

- **Resumability**: If the session dies mid-task, the plan file records exactly where execution stopped. The next session picks up from the last incomplete step without re-reading the entire conversation history.
- **Auditability**: The user can open plan.md at any point and see exactly what happened. This is better UX than reading raw tool call logs.

The protocol forces the model into a tight edit-verify-update cycle that reduces drift on long tasks.

Example prompt fragment (paraphrased):
```
After completing each step:
1. Update plan.md - mark the step [DONE]
2. Write one sentence: what changed as a result
3. State the next step you will take
Do not proceed to the next step until plan.md reflects the current state.
```

### 2.2 Memory System — Best Cross-Session Memory of Any Competitor

Windsurf's memory implementation is the most developed in the IDE agent space. It operates at three levels:

**Level 1 — Workspace Memory** (per repo):
- Programming language and framework detected at session start
- Coding patterns observed in the codebase (naming conventions, file structure)
- Lint/format rules inferred from config files
- Test framework and run commands

**Level 2 — User Preference Memory** (per user account, cross-workspace):
- Communication style preferences ("be concise", "always explain changes")
- Tool preferences (preferred shell, preferred editor commands)
- Domain expertise level (adjusts explanation depth)
- Historical corrections (what the user told it not to do)

**Level 3 — Session Memory** (current session):
- Recent file edits
- Errors encountered and how they were resolved
- Decisions made mid-task

This three-level structure is architecturally correct. Level 1 answers "what kind of codebase is this?", Level 2 answers "what does this user want from an AI?", Level 3 answers "what just happened?". Each question has a different lifetime and update frequency, and Windsurf separates them correctly.

**Comparative note**: OpenHands and Cline have no cross-session memory at all. Cursor has no memory between sessions. Aider uses git history as implicit memory but has no explicit preference store. Windsurf wins this category across all IDE agents.

### 2.3 Step-by-Step Narrative Output

Windsurf instructs the model to narrate in a specific structure:

```
[What I'll do]  →  [Do it]  →  [What changed]
```

Before each action: one sentence stating intent.
After each action: one sentence summarizing the result.
This is not prose padding — it is structured execution logging that surfaces in the IDE sidebar as a readable activity feed.

The pattern solves a real UX problem: users watching an agent work need just enough context to trust it without being buried in raw output. The "what I'll do / what changed" framing gives exactly that — it is compression with maximum information density.

### 2.4 Tool Minimalism (Intentional Conservatism)

Windsurf's prompt contains an explicit instruction: "only use tools if absolutely necessary." This reads as a weakness (discussed below), but the intent is defensible. The design philosophy appears to be:

- Prefer reading existing code to writing new code
- Prefer small targeted edits to large rewrites
- Ask before taking destructive actions

For an IDE tool used by developers who are watching the agent work in real-time, this caution makes sense. The user can always push for more.

---

## 3. What Makes It Bad

### 3.1 Tool Minimalism — Too Conservative

The "only use tools if absolutely necessary" instruction becomes a liability on multi-step tasks. It creates excessive hesitation on operations that are clearly required. The model interprets "necessary" conservatively and asks for confirmation at inflection points where a confident agent would just proceed.

The failure mode is observable: on tasks like "set up a test suite" or "refactor this module to use the repository pattern," Windsurf pauses mid-execution to confirm steps that any competent developer would consider implied by the original request.

OSA's approach is better: tools are gated by security check (blocking dangerous operations) not by a vague necessity threshold. A security hook that blocks `rm -rf /` is correct. An instruction to "avoid tools when possible" is just friction.

### 3.2 No Signal Classification

Windsurf applies the same processing weight to every input regardless of its nature. A one-word acknowledgment ("ok") and a 500-word architectural specification receive identical treatment: both trigger context assembly, plan evaluation, and a full LLM call.

This is a Shannon violation. The channel has finite capacity. Spending it on "ok" is waste.

OSA's two-tier noise filter (deterministic pattern match + LLM classification) gates sub-threshold signals before the LLM is ever called. For a "ok" or "thanks" response, OSA emits a thumbs-up acknowledgment without touching the LLM. Windsurf doesn't have this.

At scale, the difference matters: across a 50-turn session with 10 low-signal turns, Windsurf burns 10 unnecessary LLM calls. OSA burns 0.

### 3.3 No Parallel Execution

Windsurf is strictly sequential. Every step waits for the previous step to complete before starting. For tasks with independent subtasks (e.g., "write tests for module A and B simultaneously," "generate documentation for these 5 files"), this is a direct performance penalty.

Cursor executes up to 8 parallel agents using git worktrees. OSA executes up to 10 parallel agents across 9 roles with wave-based scheduling. Windsurf executes 1 agent doing 1 thing.

The absence of parallelism is not a prompt-level limitation — it is an architectural one. Windsurf's underlying Cascade agent loop is inherently single-threaded, and their system prompt reflects that reality.

### 3.4 No Personality or Adaptive Behavior

Windsurf's prompt reads like a technical specification document. There is no identity, no voice, no adaptive behavior based on user context. The model behaves the same way for a senior engineer debugging a race condition as it does for a beginner asking how to create a file.

This is a missed opportunity. The memory system already captures user expertise level — but the execution layer does not appear to vary its output depth, tone, or approach based on that knowledge.

OSA's Signal Theory addresses this directly: the signal classification tuple (M, G, T, F, W) routes each request to the appropriate response mode, format, and depth. A build request from a senior user gets a different output density than a question from a new user.

---

## 4. Section-by-Section Breakdown

### 4.1 Identity and Role Definition

```
Length:     ~40 lines
Purpose:    Establish Windsurf as an IDE agent (not a general chatbot)
Strength:   Clear tool boundary — "you operate inside a VS Code workspace"
Weakness:   No personality differentiation, no tier system, no adaptive role
```

Windsurf positions itself narrowly: it is a coding assistant inside an IDE. This is a correct and honest framing that prevents scope creep. The limitation is that it has no mechanism to expand that role when needed (e.g., act as an architect vs. act as a code monkey depending on the signal).

### 4.2 Plan Update Protocol

```
Length:     ~60 lines
Purpose:    Enforce structured execution with live plan tracking
Strength:   Resumability, auditability, step-gating reduces drift
Weakness:   No parallel plan branches, no task dependency graph
```

The plan protocol is the strongest section. The one gap: it handles sequential plans only. There is no mechanism for "steps 3, 4, 5 can run in parallel — do them simultaneously." For complex tasks with parallelizable workstreams, this is a ceiling.

### 4.3 Memory Injection

```
Length:     ~80 lines (excluding injected content)
Purpose:    Personalize execution based on user history and workspace context
Strength:   Three-level separation (workspace/user/session) is architecturally correct
Weakness:   No semantic search over memory, no pattern consolidation, no self-learning
```

Memory is injected as a flat list of key-value preferences. There is no retrieval mechanism — the entire memory store is injected every turn. This works at small scale but breaks down as memory grows. There is no equivalent to OSA's SICA engine for pattern consolidation or the three-tier (working/episodic/semantic) TTL system.

### 4.4 Tool Gate

```
Length:     ~50 lines
Purpose:    Constrain tool use to necessary operations only
Strength:   Prevents runaway tool use on simple tasks
Weakness:   Too conservative, creates hesitation on justified actions
```

The tool gate instruction is blunt. A better implementation would gate on risk level, not necessity. OSA's pre_tool_use hook pipeline achieves this more precisely: security_check blocks dangerous patterns, budget_tracker blocks over-spend, and everything else proceeds without friction.

### 4.5 Narrative Output Format

```
Length:     ~30 lines
Purpose:    Produce readable execution trace for the IDE sidebar
Strength:   "What I'll do / what changed" is high information density
Weakness:   No adaptation based on output channel or signal type
```

This format is correct for IDE use. It would be wrong for a Telegram message (too verbose) or a Discord response (wrong register). OSA's signal-aware context builder varies the output format based on channel and signal type — the same LLM, different genre.

---

## 5. Lessons for OSA

### 5.1 Already Have — No Action Needed

| Windsurf Feature | OSA Equivalent |
|-----------------|----------------|
| Plan file persistence | `tasks/todo.md` + plan mode in `Agent.Loop` |
| Memory injection | `MEMORY.md` + three-tier (ETS/JSONL/Semantic) |
| Narrative output | Signal-aware `Context.build/2` |
| Tool safety gate | `pre_tool_use` hook → `security_check` |
| Bounded iteration | `max_iterations` cap (default 30) |
| Context compaction | `Agent.Compactor.maybe_compact/1` |

OSA's architecture already implements or exceeds every Windsurf feature. There is nothing to adopt.

### 5.2 Windsurf Does Better — Action Items

| Gap | Windsurf Advantage | OSA Action |
|-----|-------------------|------------|
| Plan resumability | plan.md survives session restarts | Ensure `tasks/todo.md` is always readable by a new session (currently it is — confirm this in integration tests) |
| "What changed" summaries | Mandatory per-step summaries | Consider adding this as an optional post-action hook for long-running swarm tasks |

---

## 6. Competitive Verdict

**Score: 7/10**

Windsurf earns its score primarily through the plan update protocol and the memory system — both are genuinely well-designed. The three-level memory separation is the best in the IDE agent category and approaches what OSA has in `Agent.Learning`.

The score ceiling is set by what Windsurf lacks: no signal classification, no parallel execution, no adaptive behavior, and a tool gate that creates unnecessary hesitation. These are not minor gaps — they are architectural decisions that limit what Windsurf can do.

**OSA wins on every axis except**:
- IDE integration (OSA has no native IDE plugin)
- Plan resumability across session crashes (OSA has it but it should be tested explicitly)

Windsurf is a competent, well-engineered single-agent system for developers who live in VS Code. OSA is a multi-agent platform with deeper intelligence. They are not direct competitors at the architecture level — but for the subset of OSA users who want a coding agent, Windsurf is the most credible IDE alternative.

---

## See Also

- [Cursor Analysis](cursor.md) — better parallelism (8 agents), better UX, same IDE limitation
- [Cline Analysis](cline.md) — similar tool set, Computer Use advantage
- [Feature Matrix](feature-matrix.md) — full side-by-side
- [OSA vs OpenClaw Hitlist](osa-vs-openclaw-hitlist.md)
