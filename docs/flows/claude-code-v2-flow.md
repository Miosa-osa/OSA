# Claude Code v2 — Message Processing Flow

> Competitor analysis document. Claude Code v2 is Anthropic's official CLI for Claude.
> Rated 9/10 — highest-rated competitor. Generated 2026-03-01.

---

## 1. High-Level Architecture

```
USER INPUT (CLI / REPL)
         │
         ▼
┌────────────────────────────────────────────────────┐
│               SYSTEM PROMPT (monolithic)            │
│  ~1150 lines, static per session                    │
│                                                     │
│  ┌───────────────┐  ┌───────────────┐               │
│  │ Tool Schemas  │  │ TodoWrite     │               │
│  │ (full JSON    │  │ task mgmt     │               │
│  │  in prompt)   │  │ state machine │               │
│  └───────────────┘  └───────────────┘               │
│  ┌───────────────┐  ┌───────────────┐               │
│  │ Git Safety    │  │ Proactiveness │               │
│  │ Protocol      │  │ Rules         │               │
│  └───────────────┘  └───────────────┘               │
└──────────────────────────┬─────────────────────────┘
                           │  (no caching split)
                           ▼
           ┌───────────────────────────┐
           │       Claude API          │
           │  Anthropic only           │
           │  claude-sonnet / opus     │
           │  streaming responses      │
           └──────────────┬────────────┘
                          │
                          ▼
           ┌───────────────────────────┐
           │      ReAct Loop           │
           │                           │
           │  Think → Act → Observe    │
           │  (repeat until done)      │
           │  max iterations: ~30      │
           └──────────────┬────────────┘
                          │
           ┌──────────────┴────────────┐
           │      Tool Execution       │
           │  parallel batch dispatch  │
           │  up to 5+ tools per turn  │
           └──────────────┬────────────┘
                          │
                          ▼
                 Response to User
                 (streamed to CLI)
```

---

## 2. Message Entry and Tool Selection

```
USER TYPES MESSAGE
       │
       ├─── Slash command? (/help, /clear, /review, etc.)
       │         │
       │         └─ Handled locally or routed as special prompt
       │
       └─── Normal message
                 │
                 ▼
         ┌───────────────┐
         │  No filtering  │   ← every message hits the LLM
         │  No noise gate │     no signal weight check
         │  No plan mode  │     no pre-classification
         └───────┬────────┘
                 │
                 ▼
         Full system prompt + conversation history
         sent to Claude API on EVERY turn
```

---

## 3. Tool System — Routing Hierarchy

Claude Code v2 enforces a strict preference: dedicated tools over shell commands.

```
TOOL PREFERENCE HIERARCHY
═════════════════════════

  FILE READS
  ──────────
  Read tool       >   Bash: cat
  (structured,        (plain text,
   line-ranged)        no metadata)

  FILE EDITS
  ──────────
  Edit tool       >   Bash: sed / awk
  (diff-aware,        (brittle,
   validated)          no validation)

  FILE CREATION
  ─────────────
  Write tool      >   Bash: tee / echo >
  (atomic,            (no safety check)
   complete)

  FILE SEARCH
  ───────────
  Glob tool       >   Bash: find
  (pattern match,     (OS-dependent,
   sorted by mtime)    slow)

  CONTENT SEARCH
  ──────────────
  Grep tool       >   Bash: grep / rg
  (regex,             (invoked via shell,
   structured out)     subprocess overhead)

  SUBAGENT WORK
  ─────────────
  Task tool           launches a sub-Claude
  (complex work,      with its own context
   long research)     and tool access

  GENERAL EXECUTION
  ─────────────────
  Bash tool           last resort
  (when no            arbitrary shell
   dedicated tool      execution
   covers the need)
```

### Parallel Tool Batching

```
LLM RESPONSE (single turn)
         │
         ├── tool_call: Read("src/main.go")          ─┐
         ├── tool_call: Read("src/config.go")          │  executed
         ├── tool_call: Glob("**/*.go")                │  in parallel
         └── tool_call: Grep("pattern", "src/")       ─┘
                                │
                                ▼
                    all results collected
                                │
                                ▼
                    single LLM call with all 4 results
```

Tool schemas are injected as full JSON definitions directly into the system prompt.
No lazy loading. All tool definitions available on every call.

---

## 4. ReAct Loop — Detailed Flow

```
                    USER MESSAGE
                         │
                         ▼
              ┌──────────────────────┐
              │   Build API request   │
              │   - system prompt     │
              │   - conversation hist │
              │   - tool definitions  │
              └──────────┬───────────┘
                         │
                         ▼
              ┌──────────────────────┐
              │   Claude API call     │◄──────────────────┐
              │   (streaming)         │                   │
              └──────────┬───────────┘                   │
                         │                               │
              ┌──────────┴───────────┐                   │
              │                      │                   │
              ▼                      ▼                   │
       tool_calls=[]          tool_calls=[...]           │
              │                      │                   │
              ▼                      ▼                   │
      ┌──────────────┐    ┌─────────────────────┐        │
      │ FINAL ANSWER │    │  Execute all tools   │        │
      │ stream text  │    │  (parallel batch)    │        │
      │ to user      │    └──────────┬───────────┘        │
      └──────────────┘               │                   │
                          ┌──────────┴────────────┐      │
                          │  Append tool results  │      │
                          │  to conversation      │      │
                          └──────────┬────────────┘      │
                                     │                   │
                                     └───────────────────┘
                                        (loop, max ~30)
```

---

## 5. TodoWrite Task Management — State Machine

```
TodoWrite: the only built-in task management mechanism.
All state lives in the conversation context (no external store).

TASK LIFECYCLE
══════════════

  ┌─────────┐
  │ pending │ ──────────────────────────────────────────► cancelled
  └────┬────┘     (user cancels, prerequisite fails)
       │
       │ agent starts working on this task
       ▼
  ┌─────────────┐
  │ in_progress │ ─────────────────────────────────────► cancelled
  └──────┬──────┘
         │
         │ work complete, verified
         ▼
  ┌───────────┐
  │ completed │
  └───────────┘

RULES
─────
  ✓  Create tasks for operations with 3+ discrete steps
  ✓  Mark in_progress BEFORE beginning the step
  ✓  Mark completed WITH evidence (show the result)
  ✓  Keep todo list populated during multi-step work
  ✗  Do not clear todo list while work is in progress
  ✗  Do not mark completed without verifiable output

EXAMPLE SEQUENCE
────────────────
  Turn 1: TodoWrite([{id:1, content:"Read files", status:"pending"},
                     {id:2, content:"Implement fix", status:"pending"},
                     {id:3, content:"Verify tests", status:"pending"}])

  Turn 2: TodoWrite([{id:1, status:"in_progress"}])
          → Read("src/main.go")
          → Read("src/types.go")

  Turn 3: TodoWrite([{id:1, status:"completed"},
                     {id:2, status:"in_progress"}])
          → Edit("src/main.go", ...)

  Turn 4: TodoWrite([{id:2, status:"completed"},
                     {id:3, status:"in_progress"}])
          → Bash("go test ./...")

  Turn 5: TodoWrite([{id:3, status:"completed"}])
          → Final answer to user
```

---

## 6. Git Safety Protocol

```
COMMIT FLOW (when explicitly asked to commit)
═════════════════════════════════════════════

  Step 1: Situational awareness (parallel)
  ─────────────────────────────────────────
  ┌──────────────────────┬──────────────────────┐
  │  Bash: git status    │  Bash: git diff HEAD  │
  │  (what changed)      │  (exact diffs)        │
  └──────────────────────┴──────────────────────┘
                    ↓ both results
  Step 2: Style alignment
  ────────────────────────
  Bash: git log --oneline -10
  (match tense, scope format, verbosity of existing commits)

  Step 3: Draft commit message
  ─────────────────────────────
  WHY > WHAT   (explain motivation, not just "Updated X")
  Example:
    fix: prevent session crash when SSE reconnects mid-stream
    (not: "fix: update sse.go")

  Step 4: Stage specific files
  ─────────────────────────────
  git add <file1> <file2>     ← explicit paths only
  NEVER: git add .            ← never stage everything

  Step 5: Commit
  ───────────────
  git commit -m "..."

  Step 6: Hook failure handling
  ──────────────────────────────
  hook failed?
      │
      ├─ FIX the underlying issue
      │
      └─ NEW commit  (never: git commit --amend)

ABSOLUTE PROHIBITIONS
═════════════════════
  ✗  git push --force (to any shared branch)
  ✗  git push --force-with-lease (to main/master)
  ✗  git commit --no-verify  (hook bypass)
  ✗  git commit --amend      (on published commits)
  ✗  git add .               (indiscriminate staging)
  ✗  commit without being asked
  ✗  push without being asked

SAFE DEFAULTS
═════════════
  ✓  New commit > amend
  ✓  Investigate files before overwriting
  ✓  Stage only relevant files
  ✓  Explain WHY in commit messages
```

---

## 7. Output Formatting Rules

```
REQUEST COMPLEXITY → RESPONSE LENGTH
══════════════════════════════════════

  Simple queries    ──►  < 4 lines
  ("what does X do")

  Medium requests   ──►  1–3 paragraphs or short code block
  ("explain how X works")

  Complex tasks     ──►  Full structured response
  ("implement feature X")    with sections, examples,
                             file:line references

FORMAT DECISIONS
════════════════

  Code references:  file.go:42  (not just "in main.go")

  Markdown:         Used when it genuinely helps readability.
                    NOT used by default for all responses.
                    Never markdown in one-liners.

  Code blocks:      Always fenced, always with language tag.
                    Never truncated mid-block.

  Lists:            Only when content is genuinely list-shaped.
                    Not as a substitute for prose.

BREVITY PRINCIPLES
══════════════════
  - Answer the question asked, not the question you wish was asked
  - No preamble ("Great question! Let me explain...")
  - No trailing summaries ("In summary, we...")
  - No unnecessary hedging ("You might want to consider...")
  - If the answer is a file path, return the file path
```

---

## 8. Proactiveness Balance

```
┌──────────────────────────────────────────────────────────┐
│               PROACTIVE — do without asking               │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  ✓  Fix obvious typo or bug noticed during work          │
│  ✓  Surface a security or quality issue                  │
│  ✓  Suggest a minor improvement inline                   │
│  ✓  Point out a related file that likely needs updating  │
│  ✓  Note a potential edge case in the current change     │
│                                                          │
└──────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────┐
│               NOT PROACTIVE — always ask first            │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  ✗  Adding features beyond the stated request            │
│  ✗  Refactoring working code not mentioned               │
│  ✗  Creating documentation files (README, CHANGELOG)     │
│  ✗  Committing changes                                   │
│  ✗  Pushing to remote                                    │
│  ✗  Running tests not related to the change              │
│  ✗  Upgrading dependencies                               │
│                                                          │
└──────────────────────────────────────────────────────────┘

PRINCIPLE: Complete the task precisely.
           Mention related issues as observations.
           Never silently expand scope.
```

---

## 9. System Prompt Structure (Monolithic)

```
┌─────────────────────────────────────────────────────┐
│           SYSTEM PROMPT (~1150 lines)                │
│           Static per session, no caching split       │
├─────────────────────────────────────────────────────┤
│                                                     │
│  IDENTITY + BEHAVIORAL RULES                        │
│  ├── Role definition                                │
│  ├── Output formatting rules                        │
│  ├── Proactiveness constraints                      │
│  └── Brevity / tone guidelines                      │
│                                                     │
│  TOOL DEFINITIONS (full JSON schemas)               │
│  ├── Read        schema + description               │
│  ├── Write       schema + description               │
│  ├── Edit        schema + description               │
│  ├── Bash        schema + description               │
│  ├── Glob        schema + description               │
│  ├── Grep        schema + description               │
│  ├── Task        schema + description               │
│  └── TodoWrite   schema + description               │
│                                                     │
│  TASK MANAGEMENT PROTOCOL                           │
│  └── TodoWrite state machine rules                  │
│                                                     │
│  GIT SAFETY PROTOCOL                                │
│  └── Commit flow + prohibitions                     │
│                                                     │
│  ENVIRONMENT CONTEXT                                │
│  ├── cwd, hostname, platform                        │
│  └── Instruction files found (CLAUDE.md, etc.)      │
│                                                     │
│  INSTRUCTION FILES (if found)                       │
│  └── CLAUDE.md / AGENTS.md walked up from cwd       │
│                                                     │
└─────────────────────────────────────────────────────┘

NOTE: No tier-based priority. No dynamic truncation.
      No signal-aware content injection.
      All 1150 lines sent every API call.
```

---

## 10. Subagent Dispatch (Task Tool)

```
MAIN AGENT
    │
    │  complex research or parallel work detected
    │
    ▼
Task("Do X and return the result")
    │
    ├── Spawns a sub-Claude instance
    │   └── own context window
    │   └── own tool access (Read, Write, Bash, etc.)
    │   └── runs to completion
    │
    └── Returns structured result to main agent
             │
             ▼
        main agent continues
        with result in context

USE CASES
─────────
  - Long research tasks that would bloat main context
  - Parallel analysis of multiple codebases
  - Isolated work that should not pollute conversation
  - Breaking a monolithic task into focused sub-tasks
```

---

## 11. What Claude Code v2 Does NOT Have

```
FEATURE                          CLAUDE CODE v2     OSA
───────────────────────────────────────────────────────────
Signal classification (5-tuple)      NONE          Yes — <1ms deterministic
Noise filter / weight gating         NONE          Yes — pattern + weight
Plan mode with Y/N/E review          NONE          Yes — skip_plan flag
System prompt tiering                NONE          Yes — 4 tiers, dynamic budget
Prompt caching architecture          NONE          Opportunity identified
Multi-provider support               NONE          18 providers
Memory across sessions               NONE          Persistent memory + cortex
Learning engine (SICA)               NONE          Self-improving patterns
Response personality system          NONE          Signal-aware Soul overlay
Context pressure monitoring          NONE          % display, auto-compaction
Wave-based multi-agent orchestration NONE          9 roles, 5 waves, 10 presets
Per-agent token budget caps          NONE          Treasury governance
Tool gating by model capability      NONE          Ollama: size + prefix check
Doom loop detection (n identical)    3 identical   No equivalent (max 30)
Instruction file discovery           CLAUDE.md     priv/rules/**/*.md
Plan file persistence                .claude/plans  in-memory only
Noise filtering before LLM           NONE          Yes — saves tokens
Async signal enrichment              NONE          Yes — background LLM
```

---

## 12. Comparison Summary

```
┌────────────────────────────────────────────────────────────┐
│                   PIPELINE COMPARISON                       │
├───────────────────────┬────────────────────────────────────┤
│   CLAUDE CODE v2      │              OSA                   │
├───────────────────────┼────────────────────────────────────┤
│ Monolithic prompt     │ 4-tier dynamic prompt assembly     │
│ (1150 lines, static)  │ (signal-aware, budget-capped)      │
├───────────────────────┼────────────────────────────────────┤
│ No pre-classification │ Fast classifier + async enrichment  │
├───────────────────────┼────────────────────────────────────┤
│ No noise gate         │ Two-tier: pattern + weight filter   │
├───────────────────────┼────────────────────────────────────┤
│ No plan mode          │ Full plan → approve → execute flow  │
├───────────────────────┼────────────────────────────────────┤
│ Direct execution      │ Plan mode for high-weight signals   │
├───────────────────────┼────────────────────────────────────┤
│ Anthropic only        │ 18 providers + Ollama               │
├───────────────────────┼────────────────────────────────────┤
│ No memory             │ Persistent + cortex + cross-session │
├───────────────────────┼────────────────────────────────────┤
│ No learning           │ SICA engine + VIGIL error taxonomy  │
├───────────────────────┼────────────────────────────────────┤
│ REST + stream output  │ REST + SSE dual-path with dedup     │
├───────────────────────┼────────────────────────────────────┤
│ Single agent (+ Task) │ 22+ roster, waves, 10 swarm presets │
├───────────────────────┼────────────────────────────────────┤
│ TodoWrite (in-context)│ Task state in structured blocks     │
├───────────────────────┼────────────────────────────────────┤
│ Strong git protocol   │ Git protocol present (not primary)  │
├───────────────────────┼────────────────────────────────────┤
│ Clear tool hierarchy  │ Same tool preference hierarchy      │
└───────────────────────┴────────────────────────────────────┘

CLAUDE CODE v2 STRENGTHS TO LEARN FROM
────────────────────────────────────────
  1. TodoWrite discipline — explicit state machine prevents lost tasks
  2. Tool preference hierarchy — codified clearly in system prompt
  3. Git safety protocol — granular, prevents common mistakes
  4. Brevity rules — <4 lines for simple queries is a real constraint
  5. Proactiveness balance — "mention, don't act" is exactly right
  6. Parallel tool batching — independent calls in one LLM turn
  7. Task tool subagents — clean context isolation for complex work

GAPS OSA MUST MAINTAIN LEAD ON
────────────────────────────────
  1. Signal Theory pipeline (classification → routing → response)
  2. Noise filtering (token cost savings)
  3. Multi-provider flexibility (18 vs 1)
  4. Cross-session memory and learning
  5. Wave orchestration (no equivalent in Claude Code v2)
  6. Plan mode UX (Y/N/E review before execution)
  7. Context pressure visibility (% gauge in TUI)
```

---

*Source: Claude Code v2 system prompt analysis. See also: `docs/competitors/feature-matrix.md`, `tasks/pipeline-architecture.md`.*
