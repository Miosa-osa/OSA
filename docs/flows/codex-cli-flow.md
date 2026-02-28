# Codex CLI — Message Processing Flow

> Score: 5/10 | Threat: MEDIUM | OpenAI | Rust | Apache 2.0
> Minimal prompt. Git-injected context. Three-tier sandbox trust model. OpenAI-only.

---

## High-Level Message Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                        CODEX CLI PIPELINE                           │
└─────────────────────────────────────────────────────────────────────┘

  ┌──────────┐
  │   USER   │
  │  INPUT   │
  └────┬─────┘
       │
       ▼
  ┌────────────────────────────────────────────────────────┐
  │             CONTEXT ASSEMBLY (every call)              │
  │                                                        │
  │  ┌───────────────────────────────────────────────────┐ │
  │  │  System prompt (~300 lines)                       │ │
  │  │  ─────────────────────────────────────────────── │ │
  │  │  "You are a remote teammate helping the user…"   │ │
  │  │  [tool definitions]                               │ │
  │  │  [approval mode rules]                            │ │
  │  └───────────────────────────────────────────────────┘ │
  │                         +                              │
  │  ┌───────────────────────────────────────────────────┐ │
  │  │  AUTO-INJECTED GIT CONTEXT                        │ │
  │  │  ─────────────────────────────────────────────── │ │
  │  │  $ git status (current working tree)              │ │
  │  │  $ git diff HEAD~1 (recent changes)               │ │
  │  └───────────────────────────────────────────────────┘ │
  └────────────────────────┬───────────────────────────────┘
                           │
                           ▼
  ┌────────────────────────────────────────────────────────┐
  │                  OPENAI API CALL                       │
  │          (GPT-4o / o3 / codex model)                  │
  │          OpenAI ONLY — no provider choice              │
  └────────────────────────┬───────────────────────────────┘
                           │
                           ▼
                  ┌────────────────┐
                  │  Tool call?    │
                  └───────┬────────┘
                     YES  │   NO
          ┌──────────────┘   └──────────────────────────┐
          │                                             │
          ▼                                             ▼
  ┌───────────────────────┐                  ┌─────────────────┐
  │  SANDBOX TRUST CHECK  │                  │  TEXT RESPONSE  │
  │  (classify operation) │                  │  to terminal    │
  └──────────┬────────────┘                  └─────────────────┘
             │
             ▼
  ┌──────────────────────────────────────────────────────────┐
  │                 THREE-TIER TRUST MODEL                   │
  └──────────────────────────────────────────────────────────┘
             │
  ┌──────────┴──────────────────────────────────────────────┐
  │                                                         │
  ▼                    ▼                                    ▼
┌──────────────┐  ┌────────────────────┐  ┌────────────────────────┐
│   TIER 1     │  │     TIER 2         │  │       TIER 3           │
│              │  │                    │  │                        │
│  SAFE OPS    │  │  MODERATE OPS      │  │  DESTRUCTIVE OPS       │
│              │  │                    │  │                        │
│  • read file │  │  • write file      │  │  • delete file/dir     │
│  • list dir  │  │  • create file     │  │  • git reset --hard    │
│  • git log   │  │  • run tests       │  │  • rm -rf              │
│  • git diff  │  │  • install pkg     │  │  • drop database       │
│              │  │  • network call    │  │  • overwrite config    │
│  AUTO-EXEC   │  │                    │  │                        │
│  no prompt   │  │  INFORM user,      │  │  REQUIRE explicit      │
│              │  │  then proceed      │  │  YES confirmation      │
└──────┬───────┘  └────────┬───────────┘  └───────────┬────────────┘
       │                   │                           │
       │          ┌────────┴──────────────┐   ┌───────┴──────────┐
       │          │  "Running npm test…"  │   │  "This will      │
       │          │  [executes]           │   │  delete X. OK?"  │
       │          └────────┬──────────────┘   │  YES / NO        │
       │                   │                  └───────┬──────────┘
       │                   │                      YES │   NO
       │                   │               ┌──────────┘   └──────┐
       │                   │               │                     │
       └─────────┬─────────┘               ▼                     ▼
                 │                  ┌───────────┐      ┌─────────────────┐
                 ▼                  │  EXECUTE  │      │  ABORT / skip   │
        ┌────────────────┐          └───────────┘      └─────────────────┘
        │   TOOL RESULT  │
        └───────┬────────┘
                │
                ▼
        ┌────────────────┐
        │  More tools?   │──YES──► (loop back to trust check)
        └───────┬────────┘
           NO   │
                ▼
        ┌────────────────┐
        │ FINAL RESPONSE │
        └────────────────┘
```

---

## Git-State-as-Context Injection

```
┌──────────────────────────────────────────────────────────────────────┐
│              AUTO-INJECTED CONTEXT (every API call)                  │
└──────────────────────────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────────┐
  │  BEFORE building system prompt:                         │
  │                                                         │
  │  1. Run: git status --short                             │
  │     → captures modified/untracked/staged files         │
  │                                                         │
  │  2. Run: git diff HEAD~1 --stat                         │
  │     → captures what changed in last commit             │
  │                                                         │
  │  3. Inject both into system prompt header               │
  │                                                         │
  │  Effect: LLM always knows repo state without asking     │
  │                                                         │
  │  Limitation: only git-tracked projects benefit          │
  │              non-git dirs get no state context          │
  └─────────────────────────────────────────────────────────┘
```

---

## "Remote Teammate" Personality

```
┌──────────────────────────────────────────────────────────────────────┐
│                    PERSONALITY FRAMING                               │
└──────────────────────────────────────────────────────────────────────┘

  System prompt opening (paraphrased):

  ┌─────────────────────────────────────────────────────────┐
  │  "You are a helpful, collaborative coding partner —     │
  │   like a remote teammate who knows the codebase."      │
  └─────────────────────────────────────────────────────────┘

  Implementation depth:
  ┌─────────────────────────────────────────────────────────┐
  │  1 sentence of framing                                  │
  │  No behavioral rules derived from it                   │
  │  No adaptive tone based on context                     │
  │  No Signal Theory or message classification            │
  │                                                         │
  │  Result: marketing copy, not functional personality    │
  └─────────────────────────────────────────────────────────┘
```

---

## Approval Mode Configuration

```
┌──────────────────────────────────────────────────────────────────────┐
│                THREE GLOBAL APPROVAL MODES (config.toml)             │
└──────────────────────────────────────────────────────────────────────┘

  ┌──────────────────────────────────────────────────────────┐
  │  --approval-mode=read-only                               │
  │                                                          │
  │  Only read operations auto-approved.                     │
  │  ALL writes require human confirmation.                  │
  │  Safest mode. Slowest. Good for exploration.             │
  └──────────────────────────────────────────────────────────┘

  ┌──────────────────────────────────────────────────────────┐
  │  --approval-mode=auto (default)                          │
  │                                                          │
  │  Tier 1 + Tier 2 ops auto-approved.                      │
  │  Tier 3 (destructive) requires confirmation.             │
  │  Workspace-scoped safety: won't touch outside CWD.       │
  └──────────────────────────────────────────────────────────┘

  ┌──────────────────────────────────────────────────────────┐
  │  --approval-mode=full                                    │
  │                                                          │
  │  ALL operations auto-approved including destructive.     │
  │  Maximum autonomy. Use in sandboxed environments only.   │
  └──────────────────────────────────────────────────────────┘
```

---

## What Codex CLI Lacks

```
┌────────────────────────────────────────────────────────────────────┐
│                         CAPABILITY GAPS                            │
├────────────────────────────────┬───────────────────────────────────┤
│  FEATURE                       │  STATUS                           │
├────────────────────────────────┼───────────────────────────────────┤
│  Multi-provider LLM support    │  OpenAI models ONLY (hard lock)   │
│  Parallel execution            │  None — sequential only           │
│  Plan mode                     │  None — no explicit planning      │
│  Task tracking                 │  Basic to-do list (UI only)       │
│  Signal handling               │  None — no message intelligence   │
│  Memory across sessions        │  None — stateless                 │
│  Multi-agent orchestration     │  Experimental — not production    │
│  Hook / middleware pipeline    │  None — no lifecycle events       │
│  Learning engine               │  None — no self-improvement       │
│  Budget / cost tracking        │  None — no cost controls          │
│  Multi-channel support         │  Terminal only                    │
│  Deep personality system       │  1-sentence framing only          │
│  Prompt coverage               │  ~300 lines — shallow vs peers    │
└────────────────────────────────┴───────────────────────────────────┘
```

---

## OSA Comparison

```
┌──────────────────────────────────────────────────────────────────────┐
│                 CODEX CLI vs OSA AGENT (key deltas)                  │
├────────────────────────────────┬────────────────────────────────────┤
│  CODEX CLI                     │  OSA AGENT                         │
├────────────────────────────────┼────────────────────────────────────┤
│  OpenAI-only (vendor lock-in)  │  18 providers, Ollama local-first  │
│  ~300-line shallow prompt      │  Modular, deep prompt assembly     │
│  Git context injection         │  Git context + session memory      │
│  3-tier sandbox trust          │  Hook pipeline (security_check)    │
│  "Remote teammate" (1 sentence)│  Signal Theory — full identity     │
│  Experimental multi-agent      │  Production 10-agent, wave exec    │
│  No learning                   │  SICA learning engine              │
│  No plan mode                  │  Plan mode for ALL non-trivial tasks│
│  Terminal only                 │  CLI + HTTP + 12 messaging channels│
│  No cost tracking              │  Tier-aware budget per agent       │
└────────────────────────────────┴────────────────────────────────────┘
```

---

*See also: `/docs/competitors/codex-cli.md` | `/docs/flows/gemini-cli-flow.md` | `/docs/flows/cline-flow.md`*
