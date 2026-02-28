# Gemini CLI — Message Processing Flow

> Score: 6/10 | Threat: MEDIUM | Google DeepMind | Go + Python | Apache 2.0
> Rigid workflow engine. Large prompt. Convention verification mandate. No adaptive behavior.

---

## High-Level Message Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                        GEMINI CLI PIPELINE                          │
└─────────────────────────────────────────────────────────────────────┘

  ┌──────────┐
  │   USER   │
  │  INPUT   │
  └────┬─────┘
       │
       ▼
  ┌────────────────────────────────────────────────┐
  │            SYSTEM PROMPT ASSEMBLY              │
  │                                                │
  │  ┌──────────────────────────────────────────┐  │
  │  │  Workflow Prompt (~400 lines, static)    │  │
  │  │  ─────────────────────────────────────  │  │
  │  │  • Convention verification mandate       │  │
  │  │  • Absolute path enforcement             │  │
  │  │  • Fixed test→lint→build sequence        │  │
  │  │  • Tool usage rules                      │  │
  │  └──────────────────────────────────────────┘  │
  └────────────────────┬───────────────────────────┘
                       │
                       ▼
  ┌────────────────────────────────────────────────┐
  │               GEMINI API CALL                  │
  │         (gemini-2.5-pro / flash)               │
  └────────────────────┬───────────────────────────┘
                       │
                       ▼
               ┌───────────────┐
               │  Tool Call?   │
               └───────┬───────┘
                  YES  │   NO
          ┌────────────┘   └─────────────────┐
          │                                  │
          ▼                                  ▼
  ┌───────────────────┐              ┌───────────────┐
  │ CONVENTION CHECK  │              │  TEXT OUTPUT  │
  │   (mandatory)     │              │  to terminal  │
  └─────────┬─────────┘              └───────────────┘
            │
            ▼
  ┌──────────────────────────────────────────────────┐
  │           BEFORE EVERY IMPORT / LIBRARY USE      │
  │                                                  │
  │   ┌────────────────────────────────────────────┐ │
  │   │  Is this library already used in project?  │ │
  │   └─────────────────────┬──────────────────────┘ │
  │                    YES  │  NO                     │
  │           ┌─────────────┘  └──────────────┐      │
  │           ▼                               ▼      │
  │   ┌──────────────┐             ┌─────────────────┐│
  │   │   PROCEED    │             │  CHECK manifest  ││
  │   │  with tool   │             │  package.json /  ││
  │   │    call      │             │  go.mod / etc.   ││
  │   └──────┬───────┘             └────────┬────────┘│
  │          │                         FOUND │  NOT   │
  │          │                    ┌──────────┘  FOUND │
  │          │                    ▼                   │
  │          │           ┌──────────────┐    ┌────────┴──┐
  │          │           │   PROCEED    │    │   ERROR   │
  │          │           │  with tool   │    │  "not in  │
  │          │           │    call      │    │  project" │
  │          │           └──────┬───────┘    └───────────┘
  │          └──────────────────┘                        │
  └──────────────────────────────────────────────────────┘
                       │
                       ▼
  ┌────────────────────────────────────────────────┐
  │              TOOL EXECUTION                    │
  │  ┌──────────────────────────────────────────┐  │
  │  │  All paths MUST be absolute              │  │
  │  │  /home/user/project/src/main.go    ✓    │  │
  │  │  ./src/main.go                     ✗    │  │
  │  └──────────────────────────────────────────┘  │
  └────────────────────┬───────────────────────────┘
                       │
                       ▼
               ┌───────────────┐
               │  More tools?  │
               └───────┬───────┘
                  YES  │   NO
          ┌────────────┘   └──────────────────────────┐
          │                                           │
          └──► (loop back to convention check)        │
                                                      ▼
                                             ┌────────────────┐
                                             │ FINAL RESPONSE │
                                             │  to terminal   │
                                             └────────────────┘
```

---

## Rigid Workflow Sequence (All Task Types)

```
┌──────────────────────────────────────────────────────────────────────┐
│          FIXED SEQUENCE — SAME FOR EVERY TASK, NO EXCEPTIONS         │
└──────────────────────────────────────────────────────────────────────┘

  ANY TASK (bug fix, feature, refactor, docs — does not matter)
       │
       ▼
  ┌─────────┐     ┌─────────┐     ┌─────────┐     ┌─────────────┐
  │  STEP 1 │────▶│  STEP 2 │────▶│  STEP 3 │────▶│   RESPOND   │
  │  test   │     │  lint   │     │  build  │     │  to user    │
  └─────────┘     └─────────┘     └─────────┘     └─────────────┘

  Note: Sequence is HARDCODED in the workflow prompt.
        It does not adapt to task type or prior results.
        A documentation-only change still runs test→lint→build.
```

---

## Absolute Path Enforcement

```
┌──────────────────────────────────────────────────────────────────────┐
│                    PATH VALIDATION (all tool calls)                  │
└──────────────────────────────────────────────────────────────────────┘

  Tool call constructed
         │
         ▼
  ┌──────────────────────────────┐
  │  Does path start with "/"?   │
  └──────────────┬───────────────┘
           YES   │   NO
    ┌────────────┘   └──────────────────────┐
    │                                       │
    ▼                                       ▼
  ┌──────────────┐               ┌──────────────────────────┐
  │  EXECUTE     │               │  REJECT / re-prompt LLM  │
  │  tool call   │               │  "Use absolute path"     │
  └──────────────┘               └──────────────────────────┘
```

---

## What Gemini CLI Lacks

```
┌────────────────────────────────────────────────────────────────────┐
│                        CAPABILITY GAPS                             │
├────────────────────────────────┬───────────────────────────────────┤
│  FEATURE                       │  STATUS                           │
├────────────────────────────────┼───────────────────────────────────┤
│  Personality / identity        │  None — purely mechanical         │
│  Parallel execution            │  None — strictly sequential       │
│  Adaptive workflow             │  None — rigid 3-step for all      │
│  Signal classification         │  None — no message intelligence   │
│  Memory across sessions        │  None — stateless                 │
│  Multi-agent orchestration     │  None — single agent only         │
│  Task tracking / plan mode     │  None — no explicit planning      │
│  Multi-channel support         │  None — terminal only             │
│  Hook / middleware pipeline    │  None — no lifecycle events       │
│  Learning engine               │  None — no self-improvement       │
└────────────────────────────────┴───────────────────────────────────┘
```

---

## OSA Comparison

```
┌──────────────────────────────────────────────────────────────────────┐
│                 GEMINI CLI vs OSA AGENT (key deltas)                 │
├────────────────────────────────┬────────────────────────────────────┤
│  GEMINI CLI                    │  OSA AGENT                         │
├────────────────────────────────┼────────────────────────────────────┤
│  ~400-line static prompt       │  Modular prompt assembly           │
│  1 fixed workflow for all      │  Adaptive plan mode per task type  │
│  Sequential only               │  10 parallel agents, wave exec     │
│  Convention check per call     │  Hook pipeline (13 events)         │
│  No memory                     │  Persistent memory + SICA learning │
│  Terminal only                 │  CLI + HTTP + 12 messaging channels│
│  No cost tracking              │  Tier-aware budget per agent       │
│  No personality                │  Signal Theory encoded in identity │
└────────────────────────────────┴────────────────────────────────────┘
```

---

*See also: `/docs/competitors/feature-matrix.md` | `/docs/flows/cline-flow.md` | `/docs/flows/codex-cli-flow.md`*
