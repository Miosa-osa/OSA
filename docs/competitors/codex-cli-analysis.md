# System Prompt Architecture Analysis: Codex CLI

> Score: **5/10** | Architecture depth: shallow | Prompt size: ~300 lines | Differentiator: git context injection

## Purpose

Dissect the Codex CLI system prompt architecture to extract transferable patterns and identify failure modes. This is a prompt engineering analysis, not a product comparison.

---

## Architecture Overview

Codex CLI has the thinnest system prompt of the three competitors analyzed here. At approximately 300 lines, it relies heavily on runtime context injection (git state, directory listing) rather than behavioral rules. The result is a prompt that is easy to understand and easy to outgrow: it works well for simple terminal coding tasks but provides no infrastructure for complex agent behavior.

Prompt decomposition:

| Layer | Lines (approx.) | Content |
|-------|----------------|---------|
| Personality framing | ~20 | "Remote teammate" identity |
| Git context injection | ~40 | Auto-injected git status/diff/log |
| Sandbox trust model | ~50 | Three-tier approval system |
| Tool definitions | ~80 | File, shell, search tools |
| General guidelines | ~110 | Style, format, interaction rules |

---

## What Makes It Good

### "Remote Teammate" Personality

Codex CLI opens with a framing that distinguishes it from every other competitor:

> "You are a remote software engineer joining this project. You don't know everything about the codebase, but you're collaborative, curious, and capable. Ask when you're unsure. Explain your reasoning. Treat the user as a peer."

This is the only competitor prompt that establishes a social contract between the model and the user. The framing produces measurable behavior differences:

- The model asks clarifying questions instead of assuming
- Explanations are peer-to-peer rather than top-down
- Uncertainty is surfaced rather than suppressed

The weakness is that the framing is one paragraph. It establishes a direction but not a framework. There are no rules governing how the "remote teammate" behaves under specific conditions: what does the teammate do when asked to execute a destructive command? How does the teammate adapt depth when the user is clearly an expert versus a novice? The personality is a sketch, not a spec.

### Git-State-as-Context Injection

Every Codex CLI session auto-injects the current git state into the system prompt:

```
=== REPOSITORY STATE ===
Branch: feature/auth-refactor
Status:
  M  lib/auth/session.ex
  M  lib/auth/token.ex
  ?? lib/auth/mfa.ex

Recent commits:
  a3f9c12 fix: session token expiry logic
  b7e1240 feat: add MFA scaffolding
  c91de05 refactor: extract token validation

Diff (staged):
  [full diff of staged changes]
```

**Why this matters**: it eliminates an entire class of context-establishment questions. The model knows immediately:
- What changed since the last commit (staged diff)
- What is untracked or modified but unstaged (working tree state)
- What the recent trajectory of the codebase is (log)

Without this injection, the user must manually describe what they were working on. With it, the model can immediately connect a bug report or question to the specific files in active development.

This is a context compression technique: a single injection replaces 5-10 conversational turns of "what are you working on? what changed? what's the branch?".

The technique also keeps the model grounded in actual state rather than hallucinated assumptions about what might have changed.

### Sandbox Trust Model

Codex CLI defines three permission tiers for command execution:

| Tier | Name | Behavior |
|------|------|----------|
| 1 | Read-only | File reads, grep, directory listing — auto-execute |
| 2 | Workspace-scoped | File writes within project root — auto-execute |
| 3 | Full access | Network calls, system commands, external processes — require confirmation |

```
# Tier 1: auto-execute
read_file, search_files, list_directory, grep

# Tier 2: auto-execute within project root
write_file, edit_file, create_file, delete_file (within $PROJECT_ROOT only)

# Tier 3: requires user confirmation
execute_command (if: network access, sudo, rm -rf, external processes)
```

**What this gets right**: the model can read and edit files without interrupting the user, but must pause before doing anything with external side effects. The boundary is semantically correct — writes within the project are reversible (git), writes outside or commands with external effects are not.

**What it gets wrong**: the three tiers are hardcoded. There is no mechanism for the user to promote a frequently-used Tier 3 command to Tier 2 for a session, or to demote all file writes to Tier 3 for sensitive projects. The tiers are a good starting point but not adaptive to context.

---

## What Makes It Bad

### Minimal Prompt Means Shallow Behavior

300 lines is not enough to cover the range of situations a coding agent encounters. The prompt handles:
- Simple file edits
- Shell command execution
- Basic Q&A about code

It does not handle:
- Multi-service architecture changes (no orchestration)
- Long-running tasks with checkpointing (no task management)
- Adaptive output depth (no signal classification)
- Session-to-session continuity (no memory)
- Self-correction on errors (no learning loop)

When Codex CLI encounters a situation outside its explicit rules, the model defaults to generic LLM behavior — which is inconsistent, ungrounded, and not tuned for the specific context. A thin prompt produces brittle agent behavior at the edges.

### "Remote Teammate" Is One Sentence Deep

The personality framing is the right idea executed at insufficient depth. Compare:

**Codex CLI** (actual):
> "You are a remote software engineer. You're collaborative, curious, and capable."

**What is missing**:
- How does the teammate adapt when the task is simple vs. complex?
- What does the teammate do when it disagrees with the user's approach?
- How does the teammate communicate uncertainty without stalling?
- What is the teammate's output style for different task types?

One sentence of personality produces surface-level warmth without changing the model's actual decision-making in complex situations. The framing is cosmetic rather than behavioral.

### No Plan Mode

Codex CLI has no concept of a planning phase. The model reads the request, optionally reads some files, and immediately starts executing. For tasks with multiple steps or irreversible consequences, this is a reliability failure: the model begins acting before it has formed a complete model of what needs to happen.

Compare to OSA's plan mode: for any task rated 3+ in complexity, the model writes a plan to `tasks/todo.md`, checkpoints the plan with the user, then executes. Codex CLI skips the checkpoint entirely.

The missing plan mode is most visible in long tasks where the model makes an incorrect assumption in step 2 that invalidates steps 3 through 7 — all of which have already been executed before the error surfaces.

### No Parallel Execution

Like Gemini CLI, Codex CLI executes sequentially. Git context injection reduces the cost of context establishment, but the execution model does not leverage the context for parallel dispatch. A refactor touching 10 files requires 10 sequential edit operations.

### OpenAI Lock-In at the Prompt Level

The prompt assumes GPT-5.2-Codex behaviors, response patterns, and tool-calling conventions. The architecture is not portable to other providers. OSA's provider-agnostic design means the same prompt infrastructure works across 18 providers and adapts tool-calling format to provider-specific requirements.

### No Memory, No Learning, No Hooks

Zero infrastructure for:
- Session-to-session memory
- Pattern learning from corrections
- Pre/post tool middleware
- Budget tracking
- Error recovery with backoff

These are not features bolted onto a prompt — they require architectural decisions about how the agent stores state and processes events. Codex CLI made no such decisions. The 300-line prompt is the entire agent architecture.

---

## Section Breakdown

### Personality Framing

```
You are an expert software engineer working remotely on this project.

Approach:
- Be collaborative, not prescriptive
- Ask clarifying questions when intent is ambiguous
- Explain your reasoning before making changes
- Treat the user as a peer, not a student
- Surface uncertainty rather than guessing
```

**What works**: the "surface uncertainty rather than guessing" directive is high-value. LLMs default to confident-sounding output even when they are guessing. An explicit rule to surface uncertainty reduces silent errors.

**What does not work**: "treat the user as a peer" is undefined. How does a peer behave when the user asks for something architecturally questionable? Does the peer comply, push back, offer alternatives? The framing raises the expectation without providing the behavior rules.

### Git Context Injection

```
=== CURRENT REPOSITORY STATE ===
Working directory: {{cwd}}
Branch: {{git_branch}}
Modified files: {{git_status}}
Recent commits: {{git_log_5}}
Staged diff: {{git_diff_staged}}
```

The injection uses template variables filled at session start. Each variable is a git command output:
- `git_branch` = `git rev-parse --abbrev-ref HEAD`
- `git_status` = `git status --short`
- `git_log_5` = `git log --oneline -5`
- `git_diff_staged` = `git diff --cached`

**Practical note**: the staged diff can be large. For projects with large changesets, this injection can consume significant context window budget on state that may not be relevant to the current task. There is no filtering: the full diff injects regardless of whether it is related to the user's question.

OSA's approach: inject git state on demand via tool call when the model determines it is relevant, rather than pre-loading it unconditionally.

### Sandbox Tiers

```
PERMISSION_TIERS:
  READ_ONLY = [read_file, search_files, list_dir, grep, git_log, git_diff]
  WORKSPACE = [write_file, edit_file, create_file, delete_file] # within $CWD only
  FULL_ACCESS = [execute_command, network_request, system_call]  # requires confirmation

DEFAULT_TIER = WORKSPACE
CONFIRMATION_REQUIRED = FULL_ACCESS
```

The `DEFAULT_TIER = WORKSPACE` setting is a sensible default: most coding tasks need file writes, and requiring confirmation on every edit would make the tool unusable. The constraint to `$CWD` prevents writes from escaping the project directory.

---

## Lessons for OSA

| Rule | Adopted | Notes |
|------|---------|-------|
| Git context injection | Yes, with modification | OSA injects git state on-demand rather than unconditionally, avoiding context bloat on large diffs. |
| Sandbox trust tiers | Yes, extended | OSA's hook pipeline implements tier-equivalent logic with configurable promotion/demotion per session. |
| "Remote teammate" personality | No | OSA's identity is governed by Signal Theory, which is more specific and behavioral than a personality sketch. |
| Minimal prompt | No | OSA's system prompt is deliberately comprehensive. Thin prompts fail at the edges. |
| Plan mode | Already present | OSA's plan mode is more developed — checkpoints, `tasks/todo.md`, user confirmation before execution. |
| OpenAI-only | Never | OSA's provider-agnostic architecture is a foundational design decision. |

### What OSA Does Differently

OSA's git context injection is conditional: the orchestrator calls `git status` and injects state when the task involves file changes or the user references specific files. It does not inject the full staged diff unconditionally — for large changesets, this would consume 30-50K tokens of context on state that may be entirely irrelevant to the task.

OSA's personality is governed by Signal Theory, which specifies not just tone but output structure, depth calibration, and mode selection per task type. Codex CLI's "remote teammate" framing is a single behavioral nudge; Signal Theory is a complete communication framework.

---

## Verdict

Codex CLI is the thinnest prompt in this analysis. It does two things well: git context injection (a genuinely useful technique that eliminates context-establishment overhead) and the three-tier sandbox model (semantically correct permission boundaries). Everything else — personality, plan mode, parallel execution, memory, learning, hooks — is absent.

The "remote teammate" framing is a missed opportunity. It establishes the right tone but does not specify the right behaviors. One paragraph of personality sketch is not an agent architecture.

Score: **5/10**

The git injection pattern is the only technique here that OSA adopted with modification. The rest of the prompt is too thin to provide meaningful lessons — its absence of architecture is itself the lesson: a 300-line prompt is insufficient for agents expected to handle complex, multi-step, multi-file engineering tasks.

**Key takeaway**: git context injection is a high-value, low-cost technique for grounding the model in actual repository state. Adopt it with conditional injection to avoid context budget waste on large diffs.

---

## See Also

- [Gemini CLI System Prompt Analysis](./gemini-cli-analysis.md)
- [Cline System Prompt Analysis](./cline-analysis.md)
- [OSA Signal Theory Architecture](../architecture/signal-theory.md)
- [OSA Hook Pipeline Guide](../guides/hooks.md)
