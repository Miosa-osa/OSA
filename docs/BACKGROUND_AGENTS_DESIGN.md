# Background Agents: CC-Parity Design

Goal: spawn full-power OSA agents that run in the background, see how many are
running plus each one's task and elapsed time, and switch/attach to any of them.
Grounded in the Claude Code source clone (`<research-root>/ClaudeCode-Source-March31`)
and the OSA tree (repo root). No em dashes used deliberately.

---

## 1. Claude Code's model (spawn -> track -> display -> switch)

CC keeps ONE unified task registry and treats every long-running thing (shells,
local agents, remote agents, dream, workflows) as a `Task` with a common base.

**Track.** `TaskStateBase` is the per-task record: `id, type, status,
description, startTime, endTime?, totalPausedMs?, outputFile, notified`
(`src/Task.ts:45-57`), created by `createTaskStateBase` with `status:'pending'`,
`startTime: Date.now()`, `outputFile: getTaskOutputPath(id)` (`src/Task.ts:108-123`).
All tasks live in `AppState.tasks` keyed by id (`src/state/AppStateStore.ts`),
with a `foregroundedTaskId` pointer for the currently attached one.

**Spawn.** Two entry points:
- Tool-level: a running bash/agent is launched with a background flag and streams
  to `outputFile` (task types in `src/tasks/` include `LocalAgentTask`,
  `LocalShellTask`, `RemoteAgentTask`).
- Key-level: `ctrl+b` is bound to the `task:background` action
  (`src/keybindings/defaultBindings.ts:186`), which backgrounds the CURRENT live
  turn rather than killing it.

**Display.** A compact footer pill summarizes the set. `getPillLabel(tasks)`
(`src/tasks/pillLabel.ts:10-67`) collapses same-type tasks to labels like
`"1 local agent"` / `"${n} local agents"` (`:37-38`) and falls back to
`"${n} background ${n===1?'task':'tasks'}"` (`:66`). When a single task can be
viewed, `pillNeedsCta` (`:74`) adds the dimmed CTA `" · ↓ to view"`. Elapsed time
is live: `useElapsedTime(startTime)` uses `useSyncExternalStore` + `setInterval`
(`src/hooks/useElapsedTime.ts:18-31`) and renders through `formatDuration`, which
yields `"0s"`, `"2m 15s"`, `"1h 3m 4s"` (`src/utils/format.ts:34-92`), subtracting
`totalPausedMs`. The full list lives in a dialog (`src/components/tasks/*`,
`AsyncAgentDetailDialog.tsx`).

**Switch.** `useSessionBackgrounding` (`src/hooks/useSessionBackgrounding.ts`) is
the attach engine. It watches `foregroundedTaskId` (`:34-36`); when set to a
`local_agent`, it syncs that task's `messages` into the main view (`:93`) and,
if the task is still `running`, binds the task's `abortController` so Escape
controls it (`:99-124`). On completion it restores the task to background
(`:129-134`); pressing `ctrl+b` again re-backgrounds the foregrounded task
(`:42-53`). Net effect: attaching a background agent hijacks the main REPL to
stream that agent live, and detaching returns it to the pill.

**Ideas worth stealing:** (a) one registry for every long-running thing;
(b) the live footer pill "N running" + `↓ to view` CTA with per-task elapsed from
a single `startTime`; (c) attach = stream the task's messages into the main view
and re-background on Escape/completion; (d) `ctrl+b` backgrounds the LIVE turn,
so backgrounding and spawning are the same muscle.

---

## 2. OSA today, mapped against CC

OSA already has TWO parallel surfaces, and each is strong on its own axis.

**Surface A: Ctrl+B'd turns (`bg_tasks`).** `Ctrl+B` -> `Action::Background` ->
`background_or_detach` -> `background_task` (`priv/rust/tui/src/app/keys.rs:164-168`,
`app/keymap_dispatch.rs:183-185`, `app/handle_actions.rs:708-767`). `/bg` lists
them (`app/commands.rs:275-303`); `/fg` calls `foreground_task`
(`app/commands.rs:303-307`, `app/handle_actions.rs:794-841`). `/fg` is genuinely
smooth: it removes the handle, restores `processing_start` from the task's
`started_at`, restarts the activity spinner and re-enters `Processing`
(`handle_actions.rs:825-838`). The footer shows `N bg` and `N shells`
(`components/status_bar.rs:1033-1075`). This is real attach, but ONLY for
turns you backgrounded, not for spawned sub-agents.

**Surface B: orchestrator sub-agents (`AgentEntry`).** `/agents` opens the
dashboard (`app/commands.rs:308-311` -> `app/handle_dialogs.rs:1031-1044`). The
`AgentEntry` struct already carries `name, role, subject (task), status,
tool_uses, tokens_used, started_at: Instant, finished_at, last_activity`
(`components/agents/entry.rs:12-35`) and computes live elapsed via
`elapsed_secs` (`:47-50`). `draw_dashboard` renders `"Running N agents…"`
(`components/agents/render.rs:49-59`), per-agent `spinner + subject + " · N tool
uses · N tokens"` (`render.rs:157-184`), grouped by batch/wave with an est. cost
line (`render.rs:90-138`). The footer also has a subagent cue
(`status_bar.rs:401-404`, `set_subagents(count, cost)`). So count + task + elapsed
+ tokens ALREADY exist for sub-agents and look good.

**The honest gap.** The two surfaces are disjoint. `/fg` (`handle_actions.rs:794`)
only scans `bg_tasks`; it cannot foreground an `AgentEntry`. The dashboard's only
per-agent actions are "view transcript" (read-only) and "stop"
(`app/handle_dialogs.rs:1083-1125`). So you can WATCH a sub-agent but not ATTACH
to it. And sub-agents are the RESTRICTED delegate flavor (see the diff table),
not full OSA agents, and cannot themselves spawn.

**Already meets the bar (do not rebuild):** live elapsed timer per agent
(`entry.rs:47-50`), count + task + tokens dashboard (`render.rs`), footer count
cue (`status_bar.rs`), Ctrl+B backgrounding of the live turn + smooth `/fg`
attach mechanic (`handle_actions.rs:744-841`), the RunStore metadata registry,
the parent chain, subtree cancel, and shared scratchpad.

---

## 3. The diff table: sub-agent vs main chat agent

The main chat Loop starts via `SessionManager.start_loop` ->
`DynamicSupervisor.start_child(SessionSupervisor, {Loop, ...})`
(`lib/optimal_system_agent/runtime/session_manager.ex:275-289`); `Loop.init`
sets the "full power" defaults (`lib/.../agent/loop.ex:687-766`). A delegate
sub-agent is built in `Delegate.Handler.build_config`
(`.../tools/builtins/delegate/handler.ex:141-216`) and spawned by
`Orchestrator.run_subagent` -> `{Loop, subagent_opts}`
(`.../orchestrator.ex:197-383`).

| Axis | Main chat agent | Delegated sub-agent | Where |
| --- | --- | --- | --- |
| permission_tier | `:full` (all tools pass tier gate) | `:subagent` default | loop.ex:748 vs handler.ex:186-190 / orchestrator.ex:352 |
| tool set | full `all_tools`, no allowlist | narrowed by agent_def `tools_allowed`/`tools_blocked` | loop.ex:727,761-762 vs handler.ex:192-193 / orchestrator.ex:364-365 |
| can delegate/recurse | yes | NO: `:subagent` tier blocks `delegate` | tool_executor.ex:43,55-57 |
| delegation_depth | `0` (may spawn to max) | parent depth `+1` | loop.ex:758 vs handler.ex:210 / orchestrator.ex:374 |
| max depth cap | 3 | 3 (but tier already blocks) | tool_filter.ex:27,62 / handler.ex:51 |
| system prompt / persona | full OSA persona | `agent_def[:system_prompt]` override or empty | loop.ex:763 vs handler.ex:191 / orchestrator.ex:302-303,366 |
| model + provider | session model/provider | `Tier.model_for(tier, provider)` unless overridden | orchestrator.ex:204-208 |
| channel | `:cli`/`:tui` (user-facing) | `:internal` (non-interactive) | session_manager.ex:282 vs orchestrator.ex:351 |
| user_id | real user | `"subagent"` | orchestrator.ex:350 |
| coordinator mode | sticky per-session store | not applied | loop.ex:722-725 |
| permission_mode | session default / overdrive | inherited from parent | loop.ex:754-757 vs orchestrator.ex:360 |
| memory / RAG | full (agent memory + tools) | agent_memory appended, same tools unless blocked | orchestrator.ex:302-303 |
| MCP tools | in `all_tools` for both | same, unless `tools_blocked` strips | loop.ex:727 (shared Registry path) |
| scratchpad | own root | SHARED root injected into task | handler.ex:170,569-596 |
| working dir | session cwd | config cwd or worktree isolation | loop.ex:764-766 vs orchestrator.ex:308-345 |
| autonomous posture | interactive (can ask_user) | `ask_user` blocked, runs unattended | tool_executor.ex:43 |

So a delegate sub-agent is deliberately a lightweight, sandboxed worker: no
recursion, restricted tools, `:internal` channel, tier model. That is the OPPOSITE
of what the operator wants for a full-power background agent.

---

## 4. Full-power spawn design

Add a SECOND spawn flavor that boots a first-class OSA `Loop` on its own session,
reusing the MAIN start path, and register it in RunStore so it shows up in the
existing dashboard.

New function `Orchestrator.run_background_session/2` (sibling of
`run_background/2` at `orchestrator.ex:540`):

1. Mint a session id (reuse `agent:<parent>:<n>` scheme, `orchestrator.ex:553-556`).
2. `RunStore.start_run(%{agent_id, parent_session_id, role, task})`
   (`run_store.ex:45-87`) so it appears in `/agents` immediately with task +
   `started_at` (elapsed is then free).
3. Start the Loop via the MAIN path, not `subagent_opts`. Build opts with
   full-power defaults, explicitly:
   - `permission_tier: :full` (or inherit the parent's), NOT `:subagent`
   - `delegation_depth: 0` so it MAY spawn (subject to caps in section 5)
   - no `allowed_tools`/`blocked_tools` narrowing (full `all_tools`, full MCP)
   - `model`/`provider` inherited from the PARENT session, not `Tier.model_for`
   - `system_prompt_override: nil` (full OSA persona)
   - `channel: :background` (a new user-facing-but-detached channel, so it can
     stream to the TUI when attached, unlike `:internal`)
   - `permission_mode` inherited (overdrive parent -> overdrive child)
   - working_dir = parent cwd, optional worktree isolation reused as-is
4. Feed the task as the first user message and let the Loop run unattended under
   `Task.Supervisor` exactly like `run_background` does (`orchestrator.ex:565-591`),
   reaping RunStore on crash (`orchestrator.ex:597-614`).
5. Wire `BackgroundNotifier.ensure_started(parent_id)` (`orchestrator.ex:547`) so
   completion re-enters the parent, identical to the existing path.

Delegate handler gets a `flavor` arg (`"worker"` default vs `"full"`): in
`build_config`/`dispatch_background` (`handler.ex:124-128,432-450`), `flavor:
"full"` routes to `run_background_session` and skips the tier floor + tool
narrowing. Everything downstream (RunStore, dashboard, notifier, resume) is
unchanged, so the full-power agent inherits the whole existing surface for free.

Difference from the delegate path in one line: same RunStore/dashboard/notifier
plumbing, but the Loop is booted with main-chat defaults (`:full` tier, depth 0,
full tools + MCP, inherited model/persona, user-facing channel) instead of the
sandboxed `subagent_opts`.

---

## 5. Recursive hierarchy design

**Where depth lives today.** `delegation_depth` defaults `0` in `Loop.init`
(`loop.ex:758`), is incremented `+1` per child in `run_subagent`
(`orchestrator.ex:374`), read by `ToolFilter` to strip the spawning tools at the
ceiling, and hard-enforced in `Handler.check_permissions`
(`handler.ex:51`, `ToolFilter.max_delegation_depth() == 3`, `tool_filter.ex:27,62`).
The `:subagent` tier ALSO blocks `delegate` outright (`tool_executor.ex:43,55-57`),
which is why sub-agents cannot currently recurse regardless of depth.

**Allowing depth > 0 for full-OSA agents.** A `flavor: "full"` background agent
runs at `:full` tier, so the tier block no longer applies and `delegation_depth`
becomes the real governor. Keep the existing depth cap but make it configurable
and ADD a total-agent cap for spawn-bomb protection:

- Reuse `:max_delegation_depth` (default 3) as the per-branch depth cap
  (`tool_filter.ex:27`); expose it in settings.
- Add `Orchestrator.SpawnGuard`: a global counter of live RunStore rows with
  `status: :running` (derivable from `RunStore.list/1`, `run_store.ex:178`).
  `run_background_session` refuses to spawn when the count exceeds a configurable
  `:max_concurrent_agents` (e.g. 16). This is the missing global cap: `run_parallel`
  spawns a whole wave at once with no ceiling today (`orchestrator.ex:71-110`).
- Per-spawn flavor choice: the `flavor` arg ("full" vs "worker") is stored on the
  RunStore row (add a `flavor` field, `run_store.ex:27-43`) so the tree can show
  which nodes are full-OSA vs lightweight, and so worker nodes keep the cheaper
  sandboxed defaults.

**Tree tracking.** The tree already exists implicitly: `RunStore` rows carry
`parent_session_id` (`run_store.ex:29`), and `Loop.descendant_session_ids` already
BFS-walks that chain for subtree cancel (`loop.ex:499-525`). Add
`RunStore.tree/1` that folds `list/1` into a parent -> children map rooted at a
session, terminating on a seen-set (mirror the existing BFS guard).

**Tree dashboard.** Extend `draw_dashboard` (`components/agents/render.rs`) to
render `RunStore.tree` as an indented hierarchy instead of flat batch groups:
each node = connector + flavor glyph + `@name`/role + subject (task) + status +
`elapsed_secs` (already on `AgentEntry`, `entry.rs:47`) + tokens/tool_uses, with a
per-subtree totals line (sum tokens, sum est cost, max elapsed).

**Subtree switch / cancel / pause.** Cancel reuses `Loop.cancel/1` verbatim
(`loop.ex:505-525`) which already cancels the whole subtree plus background shell
jobs. Switch/attach reuses the section-6 attach mechanic on any selected node.
Pause = a new cooperative `:paused` flag alongside the existing cancel flag ETS
table (`loop.ex:@cancel_table`), checked at the Loop's iteration boundary;
`totalPausedMs` accounting mirrors CC's `TaskStateBase.totalPausedMs`
(`src/Task.ts:53`) so elapsed stays honest.

**Budget rollup + subtree join.** Sum `tokens_used`/`duration_ms` over
`RunStore.tree` for the rollup. Subtree join reuses `task_wait`
(`.../tools/builtins/task_wait/handler.ex`) extended to accept a root id and wait
on all `:running` descendants.

---

## 6. Phased build plan

### Phase 1: one full-power background agent, visible, attachable

Smallest thing that delivers "spawn a full agent, see task + elapsed, switch to it".

Backend:
- `lib/optimal_system_agent/orchestrator.ex`: add `run_background_session/2`
  (section 4). Reuse RunStore + BackgroundNotifier; boot Loop with main-chat
  full-power opts and a new `channel: :background`.
- `lib/optimal_system_agent/agent/loop.ex`: accept `channel: :background`
  (user-facing streaming, unattended) in `init` (near `:748-766`).
- `lib/optimal_system_agent/tools/builtins/delegate/handler.ex`: add `flavor`
  arg; route `flavor:"full"` to `run_background_session` (near `:124-128`).
- Optional `/spawn` command surface + a new `spawn_agent` builtin so the user can
  launch one on demand, not only via the model.

TUI:
- `priv/rust/tui/src/app/handle_actions.rs`: make `foreground_task` (`:794`) also
  scan `AgentEntry` running nodes, not just `bg_tasks`. Attaching a sub-agent =
  subscribe to its `osa:session:<id>` stream and route it into the activity view,
  reusing the `/fg` restore-from-`started_at` logic (`:825-838`).
- `priv/rust/tui/src/app/commands.rs`: extend `/fg <id>` to accept an agent id;
  add `/spawn <task>`.
- `priv/rust/tui/src/components/status_bar.rs`: the running-agent footer count
  already exists (`set_subagents`, `:401`); ensure `run_background_session` agents
  increment it.

Reuse unchanged: RunStore, `AgentEntry` elapsed timer, `/agents` dashboard,
`draw_dashboard`, BackgroundNotifier, subtree cancel.

### Phase 2: depth-capped recursion + flavor choice

- `orchestrator.ex`: `SpawnGuard` global concurrency cap on `run_background_session`
  and `run_parallel` (`:71`); read `RunStore.list` running count.
- `run_store.ex`: add `flavor` field (`:27-43`, `:45-87`).
- `handler.ex` + `tool_filter.ex`: expose `:max_delegation_depth` and
  `:max_concurrent_agents` in settings; keep depth enforcement (`handler.ex:51`).
- config: settings keys + docs.

### Phase 3: tree dashboard + subtree ops + budget rollup

- `run_store.ex`: add `tree/1` (parent -> children fold with seen-set).
- `components/agents/render.rs`: hierarchical indented render with flavor glyph +
  per-subtree totals.
- `app/handle_dialogs.rs`: dashboard actions for subtree cancel (reuse
  `Loop.cancel`), subtree switch, pause/resume.
- `loop.ex`: cooperative `:paused` flag + `totalPausedMs` accounting.
- `tools/builtins/task_wait/handler.ex`: root-id subtree join; budget rollup query.

---

## 7. What already exists (reuse, do not rebuild)

- Per-agent registry with task, status, `started_at`, tokens, tool count,
  parent chain: `RunStore` (`run_store.ex:27-87`).
- Live per-agent elapsed timer: `AgentEntry.elapsed_secs` (`entry.rs:47-50`).
- Count + task + tokens dashboard: `draw_dashboard` (`render.rs:49-184`),
  opened by `/agents` (`commands.rs:308-311`, `handle_dialogs.rs:1031-1044`).
- Footer running-count cue: `status_bar.rs:401-404,558-559,1033-1075`.
- Ctrl+B backgrounds the live turn; smooth `/fg` attach: `keys.rs:164-168`,
  `handle_actions.rs:708-841`.
- Fire-and-forget spawn + completion re-entry: `run_background` +
  `BackgroundNotifier` (`orchestrator.ex:540-619`, `background_notifier.ex:65-113`).
- Parent chain + whole-subtree cancel including background shells:
  `loop.ex:499-525`.
- Resume / message a finished agent with full transcript replay:
  `resume_subagent` (`orchestrator.ex:705-772`), `task_resume`, `message_agent`.
- Shared scratchpad dependency injection: `handler.ex:170,569-596`.

The only genuinely new machinery is: (a) the full-power spawn variant
(`run_background_session`), (b) unifying `/fg` attach to cover sub-agents,
(c) the spawn-bomb concurrency guard, and (d) the hierarchical tree render.
Everything else is wiring existing parts together.
