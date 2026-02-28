# Cursor — Message Processing Flow

> Cursor is a VS Code fork rebuilt around AI as a first-class citizen. Score: 8/10.
> This document maps every stage of its message processing pipeline using ASCII diagrams.

---

## 1. High-Level Pipeline

```
┌─────────────────────────────────────────────────────────────────────┐
│                         CURSOR PIPELINE                             │
└─────────────────────────────────────────────────────────────────────┘

  ┌──────────────────┐
  │   User (Editor)  │  types prompt in Composer or Chat pane
  └────────┬─────────┘
           │ raw text
           ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │                     PROMPT ASSEMBLY                              │
  │                                                                  │
  │  ┌─────────────────┐   ┌──────────────────┐   ┌──────────────┐ │
  │  │  System prompt  │   │  Todo list (ALL  │   │  Editor      │ │
  │  │  (static rules) │ + │  tasks injected  │ + │  context     │ │
  │  │                 │   │  EVERY turn)     │   │  (open files)│ │
  │  └─────────────────┘   └──────────────────┘   └──────────────┘ │
  └────────────────────────────────┬─────────────────────────────────┘
                                   │ assembled messages[]
                                   ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │                     LLM API (GPT-5 / Claude)                     │
  │                     model locked per tier                        │
  └────────────────────────────────┬─────────────────────────────────┘
                                   │ response with tool_calls[]
                                   ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │                  *** DEFAULT TO PARALLEL ***                     │
  │                                                                  │
  │   Independent tool calls are BATCHED and executed together.      │
  │   Sequential execution only when one call depends on another.    │
  └────────────────────────────────┬─────────────────────────────────┘
                                   │
           ┌────────────────────────┼────────────────────────┐
           │                        │                        │
           ▼                        ▼                        ▼
  ┌────────────────┐      ┌─────────────────┐      ┌────────────────┐
  │   Tool Call A  │      │   Tool Call B   │      │   Tool Call C  │
  │  (concurrent)  │      │  (concurrent)   │      │  (concurrent)  │
  └────────┬───────┘      └────────┬────────┘      └────────┬───────┘
           └────────────────────────┼────────────────────────┘
                                    │ all results collected
                                    ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │             STATUS UPDATE  (REQUIRED after each batch)           │
  │             "I read X, found Y, will now do Z."                  │
  └────────────────────────────────┬─────────────────────────────────┘
                                   │
                    ┌──────────────┘
                    │  more work needed?
                    ├── YES → back to LLM API (next batch)
                    └── NO  → Final Response to user
```

---

## 2. The "DEFAULT TO PARALLEL" Directive

```
┌─────────────────────────────────────────────────────────────────────┐
│  SYSTEM PROMPT (excerpt — bolded directive near the top)            │
│                                                                     │
│  ┌───────────────────────────────────────────────────────────────┐ │
│  │                                                               │ │
│  │   **DEFAULT TO PARALLEL TOOL USE**                           │ │
│  │                                                               │ │
│  │   When multiple tool calls are independent of each other,    │ │
│  │   call them in the SAME response turn, not sequentially.     │ │
│  │   Do NOT wait for one result before issuing the next call    │ │
│  │   unless there is a data dependency between them.            │ │
│  │                                                               │ │
│  └───────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘

  DEPENDENCY CHECK (LLM decides at inference time)

  read_file("a.ts")          ──┐
  read_file("b.ts")          ──┤  PARALLEL — no dependency
  read_file("c.ts")          ──┘

  read_file("schema.ts")     ──► result needed first
                                     │
                                     ▼
  write_file("generated.ts") ──  SEQUENTIAL — depends on above

  Batching rule:
  ┌──────────────────────────────────────────────────────┐
  │  Batch 1: [read A, read B, read C]  ← parallel      │
  │  Batch 2: [write generated.ts]      ← sequential     │
  │           (waits for Batch 1 results)                │
  └──────────────────────────────────────────────────────┘
```

---

## 3. Todo State Machine (MERGE Semantics)

```
┌─────────────────────────────────────────────────────────────────────┐
│                       TODO STATE MACHINE                            │
└─────────────────────────────────────────────────────────────────────┘

  States:   [ ] pending   [~] in_progress   [x] done   [!] failed

  ┌───────────────────────────────────────────────────────────────┐
  │  todo_write call                                              │
  │                                                               │
  │  {                                                            │
  │    "todos": [                                                 │
  │      { "id": "t1", "content": "Read schema", "status": "~" },│
  │      { "id": "t2", "content": "Write types", "status": "[ ]" }│
  │    ]                                                          │
  │  }                                                            │
  └────────────────────────────┬──────────────────────────────────┘
                               │
                               ▼
  ┌───────────────────────────────────────────────────────────────┐
  │  MERGE SEMANTICS (NOT replace)                                │
  │                                                               │
  │  Existing task found by ID?                                   │
  │         │                                                     │
  │    YES──► UPDATE status/content in place                      │
  │    NO ──► APPEND as new task                                  │
  │                                                               │
  │  Tasks already marked [x] or [!] are PRESERVED as-is         │
  │  unless explicitly updated by a new todo_write call.         │
  └────────────────────────────┬──────────────────────────────────┘
                               │
                               ▼
  ┌───────────────────────────────────────────────────────────────┐
  │  INJECTION POINT: EVERY turn, todo list prepended to prompt   │
  │                                                               │
  │  Turn N:   [system] + [todo list] + [user msg] + [history]   │
  │  Turn N+1: [system] + [todo list] + [assistant] + [user] ... │
  │  Turn N+2: [system] + [todo list] + ...                      │
  │                                                               │
  │  Effect: LLM always sees current task state.                 │
  │  Trade-off: Adds ~200-500 tokens of noise per turn.          │
  └───────────────────────────────────────────────────────────────┘

  Lifecycle:

  [ ] ─────────────────────────► [~]
  pending          start          in_progress
                                    │
                         ┌──────────┴──────────┐
                         ▼                     ▼
                        [x]                   [!]
                        done                  failed
```

---

## 4. Status Update Mandate + Tool Batch Interleaving

```
┌─────────────────────────────────────────────────────────────────────┐
│             INTERLEAVED EXECUTION PATTERN                           │
│                                                                     │
│  Rule: After EVERY tool batch, the LLM MUST emit a status update   │
│  before issuing the next batch. This is enforced in the prompt.    │
└─────────────────────────────────────────────────────────────────────┘

  LLM Turn 1
  ┌─────────────────────────────────────────────────────────────────┐
  │  Reasoning: "I need to read these 3 files first."               │
  │  tool_call: read_file("src/auth.ts")    ─┐                      │
  │  tool_call: read_file("src/types.ts")   ─┤ PARALLEL BATCH 1     │
  │  tool_call: read_file("src/api.ts")     ─┘                      │
  └────────────────────────────────┬────────────────────────────────┘
                                   │ executor runs all 3 concurrently
                                   ▼
  ┌─────────────────────────────────────────────────────────────────┐
  │  tool_result: auth.ts (1240 tokens)     ─┐                      │
  │  tool_result: types.ts (890 tokens)     ─┤ results injected     │
  │  tool_result: api.ts (2100 tokens)      ─┘                      │
  └────────────────────────────────┬────────────────────────────────┘
                                   │
  LLM Turn 2 (STATUS UPDATE REQUIRED)
  ┌─────────────────────────────────────────────────────────────────┐
  │  "I've read the auth module, types, and API layer.              │
  │   auth.ts uses JWT with RS256. types.ts defines UserPayload.    │
  │   api.ts exposes /login and /refresh. I will now write the      │
  │   updated handler and the new test file."                       │
  │                                                                 │
  │  tool_call: write_file("src/auth-v2.ts") ─┐                     │
  │  tool_call: write_file("src/auth.test.ts")─┘ PARALLEL BATCH 2  │
  └────────────────────────────────┬────────────────────────────────┘
                                   │
                                   ▼
  ┌─────────────────────────────────────────────────────────────────┐
  │  tool_result: wrote auth-v2.ts  ─┐                              │
  │  tool_result: wrote auth.test.ts ─┘ results injected            │
  └────────────────────────────────┬────────────────────────────────┘
                                   │
  LLM Turn 3 (STATUS UPDATE REQUIRED)
  ┌─────────────────────────────────────────────────────────────────┐
  │  "I've written the updated auth handler and test file.          │
  │   Both files are complete. No further tool calls needed."       │
  │                                                                 │
  │  [no tool_calls in response = loop terminates]                  │
  └────────────────────────────────┬────────────────────────────────┘
                                   │
                                   ▼
                       ┌───────────────────────┐
                       │   Final Response      │
                       │   (rendered in chat)  │
                       └───────────────────────┘

  Compact timing diagram:

  ──[ Batch 1 ]──── status ────[ Batch 2 ]──── status ────[ Final ]──
       │               │             │               │          │
    parallel        explain       parallel        explain    user sees
    tool run       progress       tool run       progress   output
```

---

## 5. cite_blocks Format

```
┌─────────────────────────────────────────────────────────────────────┐
│                      cite_blocks FORMAT                             │
│                                                                     │
│  Purpose: Structured code references embedded in LLM responses.    │
│  Links prose to exact file locations. Rendered as clickable refs   │
│  in the Cursor UI.                                                  │
└─────────────────────────────────────────────────────────────────────┘

  Wire format (JSON inside response):

  ┌──────────────────────────────────────────────────────────────┐
  │  {                                                           │
  │    "type": "cite_block",                                     │
  │    "file": "src/auth/jwt.ts",                                │
  │    "start_line": 42,                                         │
  │    "end_line": 67,                                           │
  │    "content": "export function verifyToken(token: string)"   │
  │  }                                                           │
  └──────────────────────────────────────────────────────────────┘

  Rendered in chat:
  ┌──────────────────────────────────────────────────────────────┐
  │  src/auth/jwt.ts  lines 42–67                          [↗]   │
  │  ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄ │
  │  export function verifyToken(token: string) {                │
  │    const decoded = jwt.verify(token, PUBLIC_KEY, {           │
  │      algorithms: ['RS256']                                   │
  │    });                                                       │
  │    return decoded as UserPayload;                            │
  │  }                                                           │
  └──────────────────────────────────────────────────────────────┘

  Used when:
  ├── LLM references a specific function or class
  ├── LLM explains why it modified a file
  └── LLM points to an error location in existing code
```

---

## 6. Full Turn Sequence (Detailed)

```
┌─────────────────────────────────────────────────────────────────────┐
│                  DETAILED TURN SEQUENCE                             │
└─────────────────────────────────────────────────────────────────────┘

  USER INPUT
  ──────────
  │  "Refactor the auth module to use RS256 and add tests"
  │
  ▼
  PROMPT ASSEMBLY
  ───────────────
  │
  ├─► [1] System prompt
  │        - Identity: "You are a coding assistant in Cursor."
  │        - **DEFAULT TO PARALLEL TOOL USE**
  │        - Emit status update after every tool batch
  │        - Use todo_write to track tasks (MERGE semantics)
  │        - Cite code with cite_blocks
  │        - Model: GPT-5 (identity locked)
  │
  ├─► [2] Todo state (injected every turn)
  │        [ ] Analyze current JWT implementation
  │        [ ] Write RS256 migration
  │        [ ] Write tests
  │
  ├─► [3] Editor context
  │        - Active file: src/auth/jwt.ts
  │        - Open tabs: src/types.ts, src/api.ts
  │        - Codebase index (embeddings)
  │
  └─► [4] Conversation history
           - Prior turns appended as messages[]
  │
  ▼
  LLM CALL (GPT-5)
  ────────────────
  │  Receives assembled prompt.
  │  Plans: "I need to read 3 files. All independent → PARALLEL."
  │
  ▼
  TURN 1 RESPONSE (tool_calls emitted)
  ─────────────────────────────────────
  │  todo_write([
  │    {id:"t1", content:"Analyze JWT impl", status:"~"},
  │    {id:"t2", content:"Write RS256 migration", status:"[ ]"},
  │    {id:"t3", content:"Write tests", status:"[ ]"}
  │  ])
  │
  │  read_file("src/auth/jwt.ts")    ──┐
  │  read_file("src/types.ts")       ──┤  PARALLEL BATCH 1
  │  read_file("src/api.ts")         ──┘
  │
  ▼
  TOOL EXECUTOR
  ─────────────
  │  Runs Batch 1 concurrently.
  │  Collects all 3 results.
  │  Injects results as tool_result messages.
  │
  ▼
  LLM CALL (Turn 2 — STATUS UPDATE)
  ──────────────────────────────────
  │  "I've read the auth module, types, and API.
  │   Currently uses HS256 with a shared secret.
  │   types.ts has JwtPayload interface.
  │   I will now write the RS256 migration and test file."
  │
  │  todo_write([{id:"t1", status:"x"}, {id:"t2", status:"~"}])
  │
  │  write_file("src/auth/jwt.ts", <new RS256 impl>)  ──┐
  │  write_file("src/auth/jwt.test.ts", <tests>)      ──┘  PARALLEL BATCH 2
  │
  ▼
  TOOL EXECUTOR
  ─────────────
  │  Runs Batch 2 concurrently.
  │  Collects results.
  │
  ▼
  LLM CALL (Turn 3 — STATUS UPDATE)
  ──────────────────────────────────
  │  "Migration complete. jwt.ts now uses RS256 with key pair.
  │   Tests written for verifyToken and signToken.
  │   No further tool calls required."
  │
  │  todo_write([{id:"t2", status:"x"}, {id:"t3", status:"x"}])
  │
  │  [no tool_calls → loop terminates]
  │
  ▼
  FINAL RESPONSE
  ──────────────
     Rendered in chat pane with cite_blocks linking to changed files.
     Todo list shows all tasks [x].
```

---

## 7. What Cursor Does NOT Have

```
┌─────────────────────────────────────────────────────────────────────┐
│                   MISSING CAPABILITIES                              │
│                   (compared to OSA / Claude Code)                  │
└─────────────────────────────────────────────────────────────────────┘

  SIGNAL PROCESSING
  ─────────────────
  ✗ No signal classification (M, G, T, F, W)
  ✗ No noise filtering before LLM call
  ✗ No weight calibration (all messages get identical processing)
  ✗ No adaptive system prompt based on input type

  MODEL FLEXIBILITY
  ─────────────────
  ✗ GPT-5 identity lock-in (model family assumption baked into prompt)
  ✗ ~4 provider options (OpenAI, Anthropic, Gemini, xAI)
  ✗ No local model support (Ollama, Llama)
  ✗ No tool gating by model capability

  MEMORY
  ──────
  ✗ No cross-session memory
  ✗ No long-term pattern learning
  ✗ No episodic recall
  ✗ Todo list resets between sessions (no persistence layer)

  PERSONALITY / IDENTITY
  ───────────────────────
  ✗ No defined personality (pure task executor)
  ✗ No Soul layer (no communication style rules)
  ✗ No IDENTITY.md equivalent

  INFRASTRUCTURE
  ──────────────
  ✗ Electron runtime (not OTP fault tolerance)
  ✗ Single-process (no GenServer supervision trees)
  ✗ No hook pipeline (PreToolUse, PostToolUse, etc.)
  ✗ No multi-channel delivery (IDE only)
  ✗ No scheduler / heartbeat / cron

  COST / BUDGET
  ─────────────
  ✗ No per-agent token budget
  ✗ No tier system (elite / specialist / utility)
  ✗ Flat subscription pricing (no per-task cost visibility)

  ┌─────────────────────────────────────────────────────────────────┐
  │  What Cursor IS good at:                                        │
  │  ├── Best-in-class IDE integration (VS Code fork)              │
  │  ├── Parallel tool execution as default                        │
  │  ├── Polished UX (plan mode, background agents, browser)       │
  │  └── cite_blocks for navigable code references                 │
  └─────────────────────────────────────────────────────────────────┘
```

---

## 8. Architecture Snapshot

```
┌─────────────────────────────────────────────────────────────────────┐
│                  CURSOR ARCHITECTURE (simplified)                   │
└─────────────────────────────────────────────────────────────────────┘

  ┌────────────────────────────────────────────────────────────┐
  │                  Electron Shell (VS Code fork)             │
  │                                                            │
  │  ┌─────────────┐   ┌──────────────┐   ┌────────────────┐  │
  │  │  Editor     │   │  Composer    │   │   Chat Pane    │  │
  │  │  (Monaco)   │   │  (agent UI)  │   │   (Q&A mode)   │  │
  │  └──────┬──────┘   └──────┬───────┘   └────────┬───────┘  │
  │         └─────────────────┴────────────────────┘          │
  │                            │                               │
  │                     ┌──────▼──────┐                        │
  │                     │  Prompt     │                        │
  │                     │  Assembler  │                        │
  │                     └──────┬──────┘                        │
  │                            │                               │
  │              ┌─────────────┼─────────────┐                 │
  │              ▼             ▼             ▼                 │
  │         ┌─────────┐  ┌─────────┐  ┌──────────┐           │
  │         │ System  │  │  Todo   │  │ Codebase │           │
  │         │ Prompt  │  │  State  │  │  Index   │           │
  │         └─────────┘  └─────────┘  └──────────┘           │
  │                            │                               │
  │                     ┌──────▼──────┐                        │
  │                     │  LLM API    │  GPT-5 / Claude        │
  │                     └──────┬──────┘                        │
  │                            │                               │
  │                     ┌──────▼──────┐                        │
  │                     │   Parallel  │                        │
  │                     │   Tool      │                        │
  │                     │   Executor  │                        │
  │                     └──────┬──────┘                        │
  │                            │                               │
  │         ┌──────────────────┼──────────────────┐           │
  │         ▼                  ▼                  ▼           │
  │    ┌─────────┐       ┌──────────┐       ┌─────────┐       │
  │    │ read_   │       │ write_   │       │  run_   │       │
  │    │ file    │       │  file    │       │ terminal│       │
  │    └─────────┘       └──────────┘       └─────────┘       │
  │                                                            │
  └────────────────────────────────────────────────────────────┘
```

---

*Score: 8/10 — Best IDE UX in the category. Missing: Signal Theory, memory, multi-provider, local models, OTP fault tolerance.*
*See also: `/docs/competitors/cursor.md`, `/docs/pipeline-comparison.md`*
