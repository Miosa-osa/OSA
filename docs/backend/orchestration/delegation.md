# Delegation

Delegation is lightweight sub-agent spawning without full orchestration overhead. A single focused agent runs an autonomous ReAct loop to research or accomplish a scoped task and returns its findings.

---

## When to Use Delegation vs Orchestration

| Concern | Delegation | Orchestration |
|---------|-----------|--------------|
| Overhead | Low (no LLM complexity analysis call) | High (complexity analysis + decomposition) |
| Parallelism | Single agent | Multiple agents in waves |
| Use case | Research, exploration, scoped subtasks | Complex multi-domain tasks |
| Tool access | Read-only by default | All tools |
| Recursive | Never (blocked) | Via `orchestrate` tool |
| Initiated from | Any agent via the `delegate` tool | User request or `orchestrate` tool |

---

## The `delegate` Tool

`OptimalSystemAgent.Tools.Builtins.Delegate` is a registered builtin tool callable by any agent. It spawns a focused sub-agent that autonomously chains tool calls.

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `task` | string | yes | What the sub-agent should investigate or accomplish |
| `tools` | array of strings | no | Restrict to specific tools (default: read-only set) |
| `tier` | string | no | `utility` (default), `specialist`, or `elite` |

### Default tool set (read-only)

```
file_read, file_grep, file_glob, dir_list,
web_search, web_fetch, memory_recall, session_search
```

The following tools are always blocked to prevent recursion:
```
delegate, orchestrate, create_skill
```

### Example call from an agent

```json
{
  "name": "delegate",
  "arguments": {
    "task": "Find all files that import the Auth module and list what they use from it",
    "tools": ["file_grep", "file_read"],
    "tier": "utility"
  }
}
```

---

## Sub-agent Execution Loop

The delegate tool runs an internal ReAct loop identical to the orchestrator's agent loop, but self-contained within the tool's `execute/1` call:

```
messages = [system_prompt, {user: task}]
loop:
  LLM call → content + tool_calls
  if no tool_calls → return content
  for each tool_call:
    Tools.execute_direct(name, args)  # lock-free, no GenServer
    append tool result to messages
  repeat up to @max_iterations (20)
```

Progress is emitted to the event bus at each iteration:

| Event | When |
|-------|------|
| `:delegate_started` | Sub-agent created |
| `:delegate_progress` | Each tool call executed |
| `:delegate_completed` | Final result ready |

The TUI displays live delegate status:
```
Delegate(explore codebase) — 12 tool uses · 45k tokens
```

---

## Tier and Model Resolution

The `tier` parameter maps to model classes:

| Tier | Model config key |
|------|----------------|
| `elite` | `:elite_model` or `:anthropic_model` |
| `specialist` | `:specialist_model` |
| `utility` | `:utility_model` |

If no model is configured for the tier, the provider's default model is used.

---

## Tool Execution — Lock-free Path

Delegate always uses `Tools.execute_direct/2` (reads from `:persistent_term`, no GenServer call) rather than `Tools.execute/2`. This is essential because the delegate tool is itself called inside a GenServer (the Loop), and a nested GenServer call to the Tools Registry would deadlock.

The same pattern applies to tool list loading: `Tools.list_tools_direct/0` reads from `:persistent_term` without going through the Registry process.

---

## Result Synthesis

The delegate returns the final LLM response as a plain string. No LLM synthesis step is applied — the last assistant message is the result. If the iteration limit is reached before the agent produces a final answer, a truncation notice is returned.

### Iteration limit behavior

At `@max_iterations` (20):
```
"Delegate reached iteration limit (20). Partial results may be available."
```

Tool results are truncated at 10KB per call to prevent context window overflow from large file reads.

---

## Orchestrate Tool

`OptimalSystemAgent.Tools.Builtins.Orchestrate` is the higher-level sibling to `delegate`. It invokes the full Orchestrator with complexity analysis and multi-agent decomposition. It is blocked for sub-agents to prevent infinite recursion.

The `orchestrate` tool is only callable from user-facing contexts (the main agent loop or explicit API calls), not from within orchestrated sub-agents.

---

## Sub-agent Spawning in the Orchestrator

The Orchestrator's `AgentRunner.spawn_agent/5` spawns sub-agents differently from the `delegate` tool:

| Aspect | `delegate` tool | `AgentRunner.spawn_agent` |
|--------|----------------|--------------------------|
| Process type | Sync (blocks caller) in `Task.async` on the call site | `Task.async` owned by Orchestrator GenServer |
| Monitoring | Not separately monitored | GenServer receives `handle_info` on completion |
| Progress reporting | Via event bus | Via `GenServer.cast` to Orchestrator |
| Prompt | Fixed system prompt | Three-tier agent selection |
| Tier override | Per-call parameter | Resolved from Roster scoring |

---

## Transitive Cascading Cancel

`Loop.cancel/1` no longer stops at the session it's called on. It BFS-walks
the parent/child session tree (`descendant_session_ids/1`, guarded against
cycles) and propagates the cancel flag to every descendant sub-agent in the
subtree, then batch-kills their background shell commands in a single pass
via `Shell.BackgroundManager.cancel_for_sessions/1` (same shape as
`kill_for_session/1` but across the whole cancelled-session subtree at once).
Cancelling a top-level orchestrated turn now reliably tears down everything
it spawned, instead of leaving orphaned sub-agents or background shells
running.

---

## `task_wait` Join-Barrier Depth Ceiling

**Module:** `OptimalSystemAgent.Tools.Builtins.TaskWait.Depth`
**Config:** `max_blocking_wait_depth` (default `3`)

A blocking `task_wait` call — an agent waiting on other agents' completion —
can no longer nest arbitrarily deep. Mirrors grok-build's
`parent_blocking_wait_depth` Arc ceiling: a chain of mutually-waiting agents
is capped, making that class of deadlock/starvation structurally impossible.

Every `task_wait` call registers its own agent id as "actively blocked" for
the duration of the wait (`enter/1` .. `exit_wait/1`) in a self-contained ETS
registry. `current_depth/1` walks the caller's ancestor chain
(`RunStore.get(id).parent_session_id`, repeated) and counts how many
ancestors are ALSO currently registered as blocked. Adding 1 for the call
about to happen is compared against `max_depth/0` **before** the wait starts
— a request that would exceed the ceiling is denied outright rather than
blocking and later failing.

---

## Peer-Resume (Sibling Handoff)

A sub-agent run can be seeded from a sibling/peer's accumulated context
(`resumed_from`) instead of always starting fresh or forking from the
parent. `Orchestrator` sets `config[:resumed_from]` when seeding a run this
way; it's carried through into `RunStore`'s run record and surfaced in the
structured result (`resumed_from`) so a parent orchestrator's summary/UI can
show lineage — purely informational, never used to gate behavior.

---

## Worktree Durable Snapshot

**Module:** `OptimalSystemAgent.Workspace.FastWorktree.snapshot_ref/2`
**Config:** `subagent_worktree_snapshot` (default `false`),
`subagent_worktree_snapshot_ref_prefix` (default
`"refs/osa/subagent-snapshots"`)

The middle ground between merging a sub-agent's worktree into the parent
branch and discarding it entirely: `snapshot_ref/2` captures the worktree's
CURRENT state into a durable git ref before `teardown/2` runs, so the work
stays inspectable/resumable (`git show <ref>`, `git worktree add -b tmp
<ref>`) even after the worktree directory itself is removed.

Any uncommitted changes (tracked + untracked-non-ignored) are committed to
the worktree's own branch first, so the ref captures the full working-tree
state — not just the last real commit. That commit is local to the
worktree's branch; it is never merged/rebased onto the caller's branch. The
worktree's branch objects live in the shared object database, so the ref
remains resolvable from the main repo after the worktree and its branch ref
are removed.

When `subagent_worktree_snapshot` is enabled, the orchestrator calls
`snapshot_ref/2` before teardown for a completed sub-agent run
(`orchestrator.ex` `subagent_worktree_snapshot?/0` gate). A snapshot failure
never fails the teardown itself — `snapshot_ref/2` rescues and returns
`{:error, reason}`.

---

## See Also

- [Orchestrator](./orchestrator.md)
- [Agents and Roster](./agents.md)
- [Tools Overview](../tools/overview.md)
- [Goal Orchestration](../agent-loop/goal-orchestration.md)
- [Configuration → Agent Behavior → Delegation / orchestration](../../getting-started/configuration.md#agent-behavior-wave-2b2c)
