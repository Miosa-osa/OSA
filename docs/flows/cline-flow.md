# Cline — Message Processing Flow

> Score: 6/10 | Threat: MEDIUM | 40K+ GitHub Stars | TypeScript | Apache 2.0
> One tool per message. XML format. Sequential safety at the cost of all parallelism.

---

## High-Level Message Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                          CLINE PIPELINE                             │
└─────────────────────────────────────────────────────────────────────┘

  ┌──────────┐
  │   USER   │
  │  INPUT   │
  └────┬─────┘
       │
       ▼
  ┌────────────────────────────────────────────────┐
  │             TASK TYPE DETECTION                │
  └────────────────────┬───────────────────────────┘
                       │
          ┌────────────┴────────────┐
          │                         │
          ▼                         ▼
  ┌───────────────┐         ┌───────────────────┐
  │   NEW TASK    │         │  EXISTING TASK /  │
  │               │         │  CONTINUE SESSION │
  └───────┬───────┘         └─────────┬─────────┘
          │                           │
          ▼                           ▼
  ┌───────────────┐         ┌───────────────────┐
  │  PLAN FIRST   │         │  READ STATE FIRST │
  │  before any   │         │  (files, history, │
  │  tool call    │         │   prior context)  │
  └───────┬───────┘         └─────────┬─────────┘
          │                           │
          └─────────────┬─────────────┘
                        │
                        ▼
  ┌────────────────────────────────────────────────┐
  │               LLM API CALL                     │
  │   (Anthropic / OpenAI / Gemini / Ollama / …)  │
  └────────────────────┬───────────────────────────┘
                       │
                       ▼
  ┌────────────────────────────────────────────────┐
  │          XML TOOL CALL IN RESPONSE?            │
  └────────────────────┬───────────────────────────┘
                  YES  │   NO
       ┌───────────────┘   └───────────────────────┐
       │                                           │
       ▼                                           ▼
  ┌──────────────────────────┐           ┌─────────────────┐
  │   PARSE XML TOOL CALL    │           │  FINAL RESPONSE │
  │                          │           │  (≤3 lines)     │
  │  <tool_name>             │           │  to user        │
  │    <param>value</param>  │           └─────────────────┘
  │  </tool_name>            │
  └──────────┬───────────────┘
             │
             ▼
  ┌──────────────────────────────────────────────────┐
  │          IS THIS A SHELL COMMAND?                │
  └────────────────────┬─────────────────────────────┘
                  YES  │   NO
       ┌───────────────┘   └──────────────────────────┐
       │                                              │
       ▼                                              ▼
  ┌────────────────────────────┐           ┌──────────────────┐
  │  EXPLAIN BEFORE RUNNING    │           │  EXECUTE TOOL    │
  │                            │           │  directly        │
  │  "This command will…"      │           └────────┬─────────┘
  │  [approval required]       │                    │
  └────────────┬───────────────┘                    │
               │                                    │
               ▼                                    │
  ┌────────────────────────────┐                    │
  │   HUMAN APPROVES?          │                    │
  └────────────┬───────────────┘                    │
          YES  │   NO                               │
    ┌──────────┘   └────────────┐                   │
    │                           │                   │
    ▼                           ▼                   │
  ┌──────────────┐  ┌─────────────────────┐         │
  │   EXECUTE    │  │  SKIP / re-plan     │         │
  │   command    │  │  without command    │         │
  └──────┬───────┘  └─────────────────────┘         │
         │                                           │
         └───────────────────────┬───────────────────┘
                                 │
                                 ▼
                    ┌────────────────────────┐
                    │   TOOL RESULT → next   │
                    │   LLM message          │
                    └────────────┬───────────┘
                                 │
                                 └──► (loop: next tool call)
```

---

## One Tool Per Message — The Sequential Safety Model

```
┌──────────────────────────────────────────────────────────────────────┐
│         CLINE FUNDAMENTAL CONSTRAINT: ONE TOOL PER MESSAGE           │
│         Cannot be configured away. Architectural decision.           │
└──────────────────────────────────────────────────────────────────────┘

  Message 1                Message 2                Message 3
  ┌─────────────┐          ┌─────────────┐          ┌─────────────┐
  │  LLM CALL   │          │  LLM CALL   │          │  LLM CALL   │
  └──────┬──────┘          └──────┬──────┘          └──────┬──────┘
         │                        │                        │
         ▼                        ▼                        ▼
  ┌─────────────┐          ┌─────────────┐          ┌─────────────┐
  │   1 TOOL    │          │   1 TOOL    │          │   1 TOOL    │
  │  read_file  │          │  edit_file  │          │  run_tests  │
  └──────┬──────┘          └──────┬──────┘          └──────┬──────┘
         │                        │                        │
         ▼                        ▼                        ▼
  ┌─────────────┐          ┌─────────────┐          ┌─────────────┐
  │   RESULT    │──────────│   RESULT    │──────────│   RESULT    │
  └─────────────┘  (wait)  └─────────────┘  (wait)  └─────────────┘

  Total wall time = sum of ALL tool RTTs (no overlap possible)

  CONTRAST with OSA:
  ┌──────────────────────────────────────────────────────────────┐
  │  Agent 1: read_file ──────────────────────────────► done    │
  │  Agent 2: read_file ──────────────────────────────► done    │ (parallel)
  │  Agent 3: read_file ──────────────────────────────► done    │
  └──────────────────────────────────────────────────────────────┘
  Total wall time = longest single tool RTT
```

---

## XML Tool Format

```
┌──────────────────────────────────────────────────────────────────────┐
│                      CLINE XML TOOL FORMAT                           │
│           Deterministically parseable — no ambiguity                 │
└──────────────────────────────────────────────────────────────────────┘

  LLM response contains exactly ONE of these blocks:

  ┌─────────────────────────────────────────┐
  │  <read_file>                            │
  │    <path>/absolute/path/to/file</path>  │
  │  </read_file>                           │
  └─────────────────────────────────────────┘

  ┌─────────────────────────────────────────┐
  │  <write_to_file>                        │
  │    <path>/absolute/path/to/file</path>  │
  │    <content>full file content</content> │
  │  </write_to_file>                       │
  └─────────────────────────────────────────┘

  ┌─────────────────────────────────────────┐
  │  <execute_command>                      │
  │    <command>npm test</command>          │
  │  </execute_command>                     │
  └─────────────────────────────────────────┘

  Parser: deterministic XML — no regex heuristics, no JSON parsing
  Failure mode: malformed XML → retry with error context
```

---

## New Task vs Existing Task Branch

```
┌──────────────────────────────────────────────────────────────────────┐
│                     TWO WORKFLOW ENTRY POINTS                        │
└──────────────────────────────────────────────────────────────────────┘

                    ┌──────────────┐
                    │  Task arrives│
                    └──────┬───────┘
                           │
              ┌────────────┴─────────────┐
              │                          │
    ┌─────────┴──────────┐    ┌──────────┴──────────┐
    │    NEW SESSION     │    │  RESUMING SESSION    │
    │  no prior context  │    │  existing state      │
    └─────────┬──────────┘    └──────────┬───────────┘
              │                          │
              ▼                          ▼
    ┌──────────────────┐      ┌─────────────────────┐
    │   PLAN PHASE     │      │   STATE RECOVERY    │
    │                  │      │                     │
    │  • Explore repo  │      │  • Read task file   │
    │    structure     │      │  • Read open files  │
    │  • Identify      │      │  • Reconstruct      │
    │    entry points  │      │    prior progress   │
    │  • Outline steps │      │  • Find stopping    │
    │  before any edit │      │    point            │
    └─────────┬────────┘      └──────────┬──────────┘
              │                          │
              └────────────┬─────────────┘
                           │
                           ▼
                  ┌─────────────────┐
                  │  EXECUTE LOOP   │
                  │  (1 tool/msg)   │
                  └─────────────────┘
```

---

## Response Brevity Constraint

```
┌──────────────────────────────────────────────────────────────────────┐
│                    EXTREME BREVITY MANDATE                           │
└──────────────────────────────────────────────────────────────────────┘

  Response to user (non-tool turns):

  ┌─────────────────────────────────────────────────────────┐
  │  Target: < 3 lines                                      │
  │                                                         │
  │  "Reading the config file."           ← 1 line ✓       │
  │  "Tests pass. Updating the handler."  ← 1 line ✓       │
  │                                                         │
  │  "I've analyzed the codebase and I think the issue     │
  │   is in the auth middleware because the token is not   │
  │   being validated correctly before the route handler   │
  │   executes, which causes the 401..."   ← VIOLATION ✗   │
  └─────────────────────────────────────────────────────────┘

  Note: brevity is encoded in system prompt, not enforced structurally.
        LLM can and does violate it on complex reasoning turns.
```

---

## What Cline Lacks

```
┌────────────────────────────────────────────────────────────────────┐
│                         CAPABILITY GAPS                            │
├────────────────────────────────┬───────────────────────────────────┤
│  FEATURE                       │  STATUS                           │
├────────────────────────────────┼───────────────────────────────────┤
│  Parallel tool execution       │  Impossible — architectural limit │
│  Multi-agent orchestration     │  None — single agent only         │
│  Adaptive output depth         │  None — always ≤3 lines           │
│  Personality / identity        │  None — purely transactional      │
│  Memory across sessions        │  None — stateless per session     │
│  Signal classification         │  None — no message intelligence   │
│  Hook / middleware pipeline    │  None — no lifecycle events       │
│  Learning engine               │  None — no self-improvement       │
│  Budget / cost tracking        │  None — no cost controls          │
│  Multi-channel support         │  IDE (VS Code) only               │
│  Plan mode (adaptive)          │  Plan phase for new tasks only    │
└────────────────────────────────┴───────────────────────────────────┘
```

---

## OSA Comparison

```
┌──────────────────────────────────────────────────────────────────────┐
│                  CLINE vs OSA AGENT (key deltas)                     │
├────────────────────────────────┬────────────────────────────────────┤
│  CLINE                         │  OSA AGENT                         │
├────────────────────────────────┼────────────────────────────────────┤
│  1 tool per message            │  10 parallel agents, wave exec     │
│  XML format (deterministic)    │  JSON tool calls (LLM-native)      │
│  Explain shell cmds before run │  Hook pipeline gates tool use      │
│  Human approval per step       │  Configurable trust tiers          │
│  VS Code only                  │  CLI + HTTP + 12 channels          │
│  No memory                     │  Persistent SICA learning engine   │
│  No signal intelligence        │  Signal Theory — 5D classification │
│  No cost tracking              │  Tier-aware budget per agent       │
│  Broad LLM support             │  18 providers, Ollama local-first  │
└────────────────────────────────┴────────────────────────────────────┘
```

---

*See also: `/docs/competitors/cline.md` | `/docs/flows/gemini-cli-flow.md` | `/docs/flows/codex-cli-flow.md`*
