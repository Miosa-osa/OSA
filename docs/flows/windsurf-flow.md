# Windsurf — Message Processing Flow

Windsurf processes each user message through a fixed sequential pipeline: context
assembly (flow prompt + plan + memory), a single LLM call, conservative tool
execution (one tool at a time, only if necessary), and a "what changed" summary
before proceeding to the next step.

Score in OSA competitor ranking: **7/10**
Adoption: **None** — OSA already has plan mode and memory; tool minimalism conflicts
with OSA's proactive tool-use philosophy.

---

## 1. High-Level Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                         USER INPUT                                  │
│                     (text, code, question)                          │
└─────────────────────────────┬───────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    CONTEXT ASSEMBLY (~600 lines)                     │
│                                                                     │
│   ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐ │
│   │   Flow Prompt    │  │   Plan State     │  │  Memory Block    │ │
│   │  (static rules)  │  │  (plan.md file)  │  │ (user prefs +    │ │
│   │                  │  │                  │  │  project context)│ │
│   │  • tool rules    │  │  • current step  │  │                  │ │
│   │  • narrative fmt │  │  • pending steps │  │  persisted from  │ │
│   │  • safety gates  │  │  • completed     │  │  prior sessions  │ │
│   └──────────────────┘  └──────────────────┘  └──────────────────┘ │
│             │                    │                     │            │
│             └────────────────────┴─────────────────────┘            │
│                                  │                                  │
│                          assembled prompt                           │
└──────────────────────────────────┬──────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│                          LLM API CALL                               │
│                   (single call, non-streaming)                      │
└──────────────────────────────────┬──────────────────────────────────┘
                                   │
                    ┌──────────────┴──────────────┐
                    │                             │
                    ▼                             ▼
         ┌─────────────────┐           ┌─────────────────────┐
         │  TEXT RESPONSE  │           │   TOOL REQUEST      │
         │  (direct reply) │           │   (if necessary)    │
         └────────┬────────┘           └──────────┬──────────┘
                  │                               │
                  │                               ▼
                  │                  ┌────────────────────────┐
                  │                  │   TOOL GATE (CHECK)    │
                  │                  │                        │
                  │                  │  "Is this tool use     │
                  │                  │   absolutely           │
                  │                  │   necessary?"          │
                  │                  │                        │
                  │                  │   YES ──► execute      │
                  │                  │   NO  ──► skip, prose  │
                  │                  └────────────┬───────────┘
                  │                               │ YES path
                  │                               ▼
                  │                  ┌────────────────────────┐
                  │                  │   TOOL EXECUTION       │
                  │                  │   (sequential only,    │
                  │                  │    one at a time)      │
                  │                  └────────────┬───────────┘
                  │                               │
                  └───────────────────┬───────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     "WHAT CHANGED" SUMMARY                          │
│                                                                     │
│             Agent writes a brief summary of what changed            │
│             before moving to the next step.                         │
└──────────────────────────────────┬──────────────────────────────────┘
                                   │
                    ┌──────────────┴──────────────┐
                    │                             │
                    ▼                             ▼
         ┌──────────────────┐          ┌──────────────────────┐
         │   MORE STEPS?    │          │       DONE           │
         │   (plan active)  │          │  (no pending steps)  │
         └────────┬─────────┘          └──────────────────────┘
                  │ YES
                  ▼
         ┌──────────────────┐
         │  UPDATE PLAN     │  ◄── plan.md written to disk
         │  (write to disk) │
         └────────┬─────────┘
                  │
                  └──────────────► back to LLM API CALL
                                   (next step in plan)
```

---

## 2. Plan Update Protocol

Each significant step follows a strict write-execute-update cycle. The plan file
on disk is the single source of truth for what has been done and what remains.

```
┌─────────────────────────────────────────────────────────────────────┐
│                        PLAN LIFECYCLE                               │
└─────────────────────────────────────────────────────────────────────┘

  Session start
       │
       ▼
  ┌─────────────┐
  │  Load plan  │  ◄── reads plan.md (or creates it if absent)
  │  from disk  │
  └──────┬──────┘
         │
         ▼
  ┌─────────────────────────────────────────────────────────────────┐
  │                    STEP EXECUTION CYCLE                         │
  │                                                                 │
  │   ┌─────────────────────────────────────────────────────────┐  │
  │   │  PHASE A: ANNOUNCE                                       │  │
  │   │  Agent writes: "I am about to [action]"                  │  │
  │   └─────────────────────────┬───────────────────────────────┘  │
  │                             │                                   │
  │                             ▼                                   │
  │   ┌─────────────────────────────────────────────────────────┐  │
  │   │  PHASE B: EXECUTE                                        │  │
  │   │  Agent performs the action (edit file, run command, etc) │  │
  │   └─────────────────────────┬───────────────────────────────┘  │
  │                             │                                   │
  │                             ▼                                   │
  │   ┌─────────────────────────────────────────────────────────┐  │
  │   │  PHASE C: SUMMARIZE                                      │  │
  │   │  Agent writes: "What changed: [summary]"                 │  │
  │   └─────────────────────────┬───────────────────────────────┘  │
  │                             │                                   │
  │                             ▼                                   │
  │   ┌─────────────────────────────────────────────────────────┐  │
  │   │  PHASE D: UPDATE PLAN FILE                               │  │
  │   │  Mark current step complete, reveal next step            │  │
  │   │  Write updated plan.md to disk                           │  │
  │   └─────────────────────────────────────────────────────────┘  │
  │                             │                                   │
  │                     pending steps?                              │
  │                    YES ◄────┴────► NO → done                   │
  └─────────────────────────────────────────────────────────────────┘

  Example plan.md at mid-execution:
  ┌─────────────────────────────────────────┐
  │  ## Plan                                │
  │  - [x] Read existing auth module        │
  │  - [x] Identify expiry logic            │
  │  - [ ] Patch token refresh handler  ◄── current
  │  - [ ] Add unit test                    │
  │  - [ ] Update changelog                 │
  └─────────────────────────────────────────┘
```

---

## 3. Memory System

Memory persists user preferences and project context across sessions. It is
injected as a block into the assembled prompt on every turn.

```
┌─────────────────────────────────────────────────────────────────────┐
│                         MEMORY SYSTEM                               │
└─────────────────────────────────────────────────────────────────────┘

  WRITE PATH (end of session / after significant observation)
  ───────────────────────────────────────────────────────────
  Agent notices preference or project fact
         │
         ▼
  ┌─────────────────────┐
  │  Classify entry     │
  │                     │
  │  user.preference    │  e.g. "prefers 2-space indent"
  │  project.context    │  e.g. "uses pnpm, not npm"
  │  project.constraint │  e.g. "do not edit legacy/ dir"
  └──────────┬──────────┘
             │
             ▼
  ┌─────────────────────┐
  │  Append to          │
  │  memory store       │  (flat file or key-value store)
  └─────────────────────┘

  READ PATH (every turn, before LLM call)
  ────────────────────────────────────────
  ┌─────────────────────┐
  │  Load memory store  │
  └──────────┬──────────┘
             │
             ▼
  ┌─────────────────────┐
  ┌─────────────────────────────────────────────────────────────────┐
  │  Memory Block (injected into assembled prompt)                  │
  │                                                                 │
  │  [user preferences]                                             │
  │    • 2-space indentation                                        │
  │    • TypeScript strict mode                                     │
  │    • No default exports                                         │
  │                                                                 │
  │  [project context]                                              │
  │    • package manager: pnpm                                      │
  │    • test runner: vitest                                        │
  │    • do not modify: legacy/ directory                           │
  └─────────────────────────────────────────────────────────────────┘
             │
             ▼
     assembled prompt  ──► LLM API CALL
```

---

## 4. Tool Gate — Conservative Tool Policy

Windsurf's system prompt instructs the agent to use tools only when absolutely
necessary. This creates a decision gate before every tool invocation.

```
┌─────────────────────────────────────────────────────────────────────┐
│                       TOOL GATE DECISION                            │
└─────────────────────────────────────────────────────────────────────┘

  LLM wants to use a tool
         │
         ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │  GATE CHECK                                                      │
  │                                                                  │
  │  Q1: Can I answer this from context alone?                       │
  │      YES ──────────────────────────────────► skip tool, use prose│
  │      NO  ──► Q2                                                  │
  │                                                                  │
  │  Q2: Is tool use the only way to get this information?           │
  │      NO  ──────────────────────────────────► skip tool, estimate │
  │      YES ──► Q3                                                  │
  │                                                                  │
  │  Q3: Is the cost of being wrong without the tool significant?    │
  │      NO  ──────────────────────────────────► skip tool, proceed  │
  │      YES ──► EXECUTE TOOL                                        │
  └──────────────────────────────────────────────────────────────────┘
         │ (only if all three gates pass)
         ▼
  ┌──────────────────────┐
  │  EXECUTE TOOL        │
  │  (sequential)        │
  │                      │
  │  one tool call       │
  │  wait for result     │
  │  incorporate result  │
  │  decide if another   │
  │  tool is needed      │
  └──────────────────────┘
         │
         │  need another tool?
         │  YES ──► repeat gate check from top
         │  NO  ──► continue to "what changed" summary
         ▼

  NOTE: No parallel execution. Tool calls are always one at a time.
        This is the primary throughput constraint vs. OSA / Cursor / Claude Code.
```

---

## 5. What Windsurf Does NOT Have

```
┌─────────────────────────────────────────────────────────────────────┐
│              ABSENT FROM WINDSURF ARCHITECTURE                      │
└─────────────────────────────────────────────────────────────────────┘

  ✗  PARALLEL EXECUTION
     ─────────────────────────────────────────────────────────────────
     Tools execute sequentially. One completes before the next begins.
     No fan-out. No batch dispatch. No independent-task parallelism.

     OSA:     multiple tools dispatched in a single turn
     Cursor:  "DEFAULT TO PARALLEL" — explicit directive
     Windsurf: one tool → wait → one tool → wait → ...

  ✗  SIGNAL CLASSIFICATION
     ─────────────────────────────────────────────────────────────────
     Same pipeline for a one-word query and a 500-word architecture
     request. No mode detection, no genre detection, no weight scoring.
     No adaptive depth or effort calibration.

     OSA:      Classifier.classify() → S=(M,G,T,F,W) → adaptive prompt
     Windsurf: fixed flow prompt regardless of message content

  ✗  WEIGHT CALIBRATION
     ─────────────────────────────────────────────────────────────────
     No mechanism to allocate more or less LLM effort based on query
     complexity. A "fix typo" request and an "redesign this module"
     request receive the same processing depth.

  ✗  PERSONALITY SYSTEM
     ─────────────────────────────────────────────────────────────────
     No voice, values, or communication style definitions. Purely
     mechanical instruction following. "Helpful IDE assistant" is a
     role description, not a personality.

  ✗  NOISE FILTERING
     ─────────────────────────────────────────────────────────────────
     No pre-LLM noise filter. Greetings, acknowledgements, and
     short filler messages all go through the full pipeline and
     consume the same token budget as substantive requests.

  ✗  PROVIDER FLEXIBILITY
     ─────────────────────────────────────────────────────────────────
     IDE-coupled; not a standalone provider-agnostic system.
     No 18-provider routing, no tier-based model selection, no
     Ollama local fallback.

  ✗  HOOK PIPELINE
     ─────────────────────────────────────────────────────────────────
     No pre/post-tool hook system. No middleware for security checks,
     learning capture, budget tracking, or error recovery.

  ✗  SWARM / MULTI-AGENT ORCHESTRATION
     ─────────────────────────────────────────────────────────────────
     Single agent only. No wave execution, no role assignment, no
     parallel agent dispatch, no agent-to-agent communication.
```

---

## 6. Competitive Summary

```
┌───────────────────────────────────────────────────────────────────────┐
│  WINDSURF vs. OSA — CAPABILITY COMPARISON                             │
├─────────────────────────────┬───────────────┬─────────────────────────┤
│  Capability                 │  Windsurf     │  OSA                    │
├─────────────────────────────┼───────────────┼─────────────────────────┤
│  Plan tracking              │  plan.md      │  tasks/todo.md          │
│  Memory across sessions     │  flat store   │  /mem-save + MEMORY.md  │
│  Narrative output style     │  yes          │  configurable           │
│  Tool use                   │  conservative │  proactive + gated      │
│  Parallel execution         │  NO           │  yes (fan-out)          │
│  Signal classification      │  NO           │  yes (S=M,G,T,F,W)      │
│  Adaptive response depth    │  NO           │  yes (weight-based)     │
│  Personality                │  NO           │  IDENTITY.md + SOUL.md  │
│  Noise filtering            │  NO           │  yes (2-tier)           │
│  Multi-agent / swarm        │  NO           │  yes (10 swarm presets) │
│  Provider flexibility       │  NO           │  yes (18 providers)     │
│  Hook middleware             │  NO           │  yes (7 hook events)    │
│  Competitor score           │  7/10         │  9.5/10 (target)        │
└─────────────────────────────┴───────────────┴─────────────────────────┘

  OSA adoptions from Windsurf: NONE
  Reason: Plan mode and memory already implemented with deeper capability.
          Tool minimalism directly conflicts with OSA's proactive philosophy.
          Windsurf serves as a reference for what NOT to constrain.
```

---

*See also: [Competitor Rankings](../07-competitor-prompt-ranking.md) |
[Pipeline Comparison](../pipeline-comparison.md) |
[OSA Architecture](../architecture/README.md)*
