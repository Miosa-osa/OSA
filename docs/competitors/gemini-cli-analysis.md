# System Prompt Architecture Analysis: Gemini CLI

> Score: **6/10** | Architecture depth: shallow-to-medium | Prompt size: ~400 lines

## Purpose

Dissect the Gemini CLI system prompt architecture to extract transferable patterns and identify failure modes. This is a prompt engineering analysis, not a product comparison.

---

## Architecture Overview

Gemini CLI's system prompt is approximately 400 lines organized around a workflow mandate. The structure is procedural rather than declarative: it tells the model what to do step-by-step rather than defining an identity or communication philosophy. There is no personality layer, no adaptive depth, and no meta-framework governing how responses are shaped.

The prompt can be decomposed into four layers:

| Layer | Lines (approx.) | Content |
|-------|----------------|---------|
| Role definition | ~20 | "You are a coding assistant" framing |
| Convention verification | ~30 | The single strongest rule in the prompt |
| Workflow mandate | ~200 | Task execution sequence with verification loop |
| Path and tool rules | ~150 | Absolute paths, file handling, tool invocation |

---

## What Makes It Good

### Convention Verification Mandate

The single most practically valuable rule found in any competitor prompt:

> "Before using any library, verify it is already in use in the codebase."

This one sentence solves a real, persistent LLM coding failure: hallucinated imports. When a model invents a dependency that does not exist in the project, it breaks builds silently. Gemini CLI's mandate — verify first, import second — forces grounding in the actual codebase before generating code that references external packages.

This rule does not require an elaborate framework. It is a one-line constraint that eliminates an entire class of bugs. High information density, minimal token cost.

### Rigid Verify Loop

Every task follows the same verification sequence:

```
test → lint → build
```

Always in that order. No skipping. No optional steps. The rigidity is intentional — it prevents the common LLM failure of claiming a task is done without confirming the artifact compiles or tests pass.

The loop is also predictable. Users and the model itself can rely on the invariant: nothing is complete until the verify loop passes.

### Absolute Path Enforcement

File references always use absolute paths. This eliminates an entire category of file operation failures where relative paths break depending on the working directory at invocation time. Simple rule, consistent elimination of ambiguity.

---

## What Makes It Bad

### No Personality

The prompt produces a mechanical assistant. There is no communication philosophy, no tone guidance, no sense of how to adapt output depth to task complexity. The model behaves identically whether it is fixing a typo or redesigning an API layer.

This is a Shannon violation: the output density does not adapt to the receiver's needs. A one-line fix produces the same verbose verification log as a multi-file refactor.

### Rigid Workflow for All Task Types

The test → lint → build mandate makes sense for code changes. It does not make sense for:
- Answering a question about what a function does
- Explaining an architecture decision
- Writing documentation

Applying the same workflow to every task type introduces noise. The model burns tokens on verification steps that are irrelevant to the task, and the user waits for a loop that adds nothing.

### No Parallel Execution

All operations are sequential. A task that touches five files executes five sequential edits with five verification loops. No batching, no parallel tool calls, no coordination across files. At scale, this is a throughput ceiling.

### No Signal Classification

Gemini CLI has no concept of what type of output it is producing. It cannot distinguish between:
- A direct answer (needs: speed, brevity)
- A specification (needs: structure, completeness)
- A runbook (needs: ordered steps, decision trees)

Every response is prose + code with the same formatting regardless of what the situation calls for. This is an Ashby violation: insufficient variety in output repertoire to match the diversity of situations.

### No Memory

State resets between sessions. The model cannot learn that a project uses a specific testing framework, that a particular file is always the entry point, or that a user prefers concise explanations. Each conversation starts from zero.

---

## Section Breakdown

### Convention Verification Rule

```
Before using any library or framework, check if it is already present in:
- package.json / go.mod / requirements.txt / Cargo.toml
- Existing import statements in the target file
If not found, do not add it without user confirmation.
```

**Why it works**: grounds the model in the existing dependency graph before it generates code. Prevents phantom imports. Prevents version conflicts. One rule, multiple failure modes eliminated.

**OSA analog**: adopted verbatim as a convention check step in the agent loop.

### Workflow Mandate

```
For every code change:
1. Read the relevant file(s)
2. Understand current state
3. Make the minimal change
4. Run: test → lint → build
5. Report result
```

**Why it works**: prevents partial completion. The model cannot claim done without evidence. Verification is not optional.

**Failure mode**: applied uniformly regardless of task type. A documentation edit should not trigger a build cycle.

### Path Rules

```
Always use absolute file paths.
Never use ~ or relative paths in tool calls.
Resolve paths before invoking any file tool.
```

**Why it works**: eliminates working-directory ambiguity. File tools receive unambiguous inputs.

**OSA analog**: enforced in all tool invocations by default.

---

## Lessons for OSA

| Rule | Adopted | Notes |
|------|---------|-------|
| Convention verification | Yes | Added to agent loop pre-code-generation |
| Absolute paths | Yes | Already enforced in OSA tool layer |
| Rigid verify loop | Partial | OSA uses adaptive verification — full loop for code changes, skip for non-code tasks |
| Sequential only | No | OSA uses parallel execution for multi-file tasks |

### What OSA Does Differently

OSA's verify loop is task-type-aware. Code changes get test → lint → build. Prose tasks get a different verification path (accuracy check, format check). This prevents the Gemini CLI failure mode of applying the same ritual to every task regardless of relevance.

OSA's Signal Theory layer replaces the missing personality. Before generating output, the model resolves Mode, Genre, Type, Format, and Structure. Gemini CLI has none of this — it produces whatever shape the LLM defaults to.

---

## Verdict

Gemini CLI's prompt is competent but brittle. The convention verification rule is its single standout contribution — a one-line fix for a real and recurring LLM failure mode. Everything else is mechanical workflow management that does not adapt to task type, output type, or user context.

Score: **6/10**

High marks for the convention check. Low marks for the lack of adaptive behavior, personality, parallel execution, and signal intelligence. Suitable for simple single-file coding tasks. Breaks down under architectural complexity.

**Key takeaway**: one precise rule (convention verification) is worth more than 200 lines of rigid workflow mandate. Rules should eliminate specific failure modes, not describe generic procedures.

---

## See Also

- [Cline System Prompt Analysis](./cline-analysis.md)
- [Codex CLI System Prompt Analysis](./codex-cli-analysis.md)
- [OSA Signal Theory Architecture](../architecture/signal-theory.md)
- [Competitor Feature Matrix](./feature-matrix.md)
