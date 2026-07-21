# OSA FleetView — Design (CC-parity agent roster)

Goal: replicate Claude Code's under-the-composer agent panel exactly — the live,
arrow-key-selectable roster of running agents where `main` is the root and every
sub-agent is a full-power OSA loop booted with its own task-derived system prompt,
switchable/attachable/killable from the keyboard.

This doc has three parts: (1) the CC reference behavior we must match (frozen spec),
(2) the TUI design, (3) the backend design. Parts 2–3 land against real code anchors
from the recon pass.

---

## Part 1 — CC reference behavior (the spec to match, frozen)

Observed firsthand from the running Claude Code TUI. This is the target.

### 1.1 Location & anatomy
The panel renders **below the composer input**, above the bottom status chrome
(mode line + hints). It is always present once ≥1 agent exists; `main` is always
row 0 so the list is never empty.

Row shape, left→right:
```
<glyph>  <agent-type>   <live-activity>            <elapsed> · <arrow><tokens>
● main
◯ general-purpose  Reading CC pillLabel.ts strings   10m 25s · ↓ 107.3k tokens
◯ general-purpose  Locating status_bar layout…        1m 25s · ↓ 103.1k tokens
```

- **glyph** — `●` filled = the currently-selected / attached node (and `main`);
  `◯` hollow = other nodes. (In CC the selection cursor is the filled dot.)
- **agent-type** — the custom-agent name the node was spawned as (`main`,
  `general-purpose`, `code-reviewer`, …). This is the identity that also selected
  its **system prompt + tool allowlist** at spawn.
- **live-activity** — a one-line, continuously-updated summary of what the node is
  doing right now ("Reading X", "Locating Y"), truncated with `…` to fit width.
- **elapsed** — wall-clock since the node started, compact
  (`10m 25s`, `1m 25s`, `1h 05m 22s`). Reuses fmt_elapsed_compact.
- **tokens** — cumulative output tokens for that node, `↓ 107.3k` style, k/M scaled.

### 1.2 Interaction model (keyboard)
- The composer status hint reads `← for agents` when idle. Pressing **←** enters
  **agents-select mode** (focus moves from composer to the roster).
- In agents-select mode: **↑ / ↓** move the selection cursor between rows;
  the selected row shows its hints: `Enter to view · x to stop`.
- **Enter** = *view/attach*: the main transcript viewport switches to that node's
  live stream (you watch it think/act in real time). Selecting `main` returns you
  to your own conversation.
- **x** = *stop*: cancels that node (and, for a full-OSA node, its subtree).
- **→ / Esc** returns focus to the composer without changing attachment.
- Queued-input affordance coexists: `Press up to edit queued` when a message is
  queued — do not clobber that binding; agents-select is entered via ← specifically.

### 1.3 Semantics that matter
- **`main` is the root, never killable, always row 0, rendered in GREEN.** Its `●`
  glyph + label are green — the visual cue that it's the home node you always return to.
  Attaching elsewhere does not pause `main`; it keeps running. Selecting `main` + Enter
  = detach → return to your own conversation/transcript.
- **Each sub-agent is a fresh, isolated context** — its own conversation, its own
  token budget, its own system prompt chosen by agent-type. That tailored system
  prompt *is the point of "custom agents"*: a `code-reviewer` node is booted with the
  reviewer prompt + read-only tools, not a generic clone.
- **The list is live**: rows appear on spawn, update activity/elapsed/tokens every
  tick, and drop (or move to a terminal ✔/✗ state briefly) on completion.
- **Attachment is a view, not a handoff**: watching a node does not steal its input
  or block it; it streams a read view of that node's transcript.

### 1.4 What OSA already has that maps onto this
(from memory + plan doc — confirm against recon)
- `/bg` `/fg` `/agents`, a coordinator mode, delegate workers, an agents panel that
  shows worker/scratchpad activity. → the data source + commands exist.
- RunStore tracks the `parent_session_id` chain = the tree backbone; rehydrates at
  boot; subtree-cancel already walks it. → the tree model exists.
- status_bar.rs already draws goal + dual elapsed timers via fmt_elapsed_compact,
  and there is an existing selectable-list pattern (35 dialogs, reverse-search). →
  the render + nav primitives exist.

Gap = wiring these into the exact CC layout + interaction above, and making a
background node a **full-power Loop** (not the restricted delegate) so the roster is a
true recursive fleet.

---

## Part 2 — TUI design

### 2.0 What already exists (do NOT rebuild)
OSA already ships most of this. Files under `priv/rust/tui/src/`:
- **Roster data model:** `components/agents/` — `struct Agents` (`mod.rs:24`, held as
  `App::agents`) with `entries: Vec<AgentEntry>`; `AgentEntry` (`entry.rs:12`:
  name/role/model/subject/status/current_action/recent_actions/tool_uses/tokens_used/
  batch_id/started_at/…); `AgentStatus{Spawning,Running,Completed,Failed}` (`entry.rs:4`).
  Mutation API already wired: `agent_started/progress/completed/failed`,
  `on_agents_spawning`, `tick`/`prune_stale`.
- **Inline bottom panel:** `render.rs:16 draw_tree()` — renders header + batch groups
  with `├─`/`└─`/`│` connectors (`:123-321`), `@name: subject · N tool uses · N tokens`
  (`:178-231`), `⎿ <summary>` result line (`:295`), scratchpad section. This is the CC
  under-composer surface — it just needs the CC row layout + a `main` root row.
- **Full-screen dashboard w/ selection (THE nav pattern):** `render.rs:422
  draw_dashboard(selected,…)` groups Working/Ready/Completed/Failed, draws `▸` marker,
  token bar + elapsed/tool/token meta, footer `↑/↓ select  enter view  c/x stop`.
  Keys: `update.rs:513 handle_agents_dashboard_key` (↑/k, ↓/j bounded by
  `dashboard_item_count`, Enter/v→`view_selected_dashboard_item`, c/x→stop, Esc/q close).
  Cursor index `App::agents_dashboard_selected` (`mod.rs:347`). State machine
  `AppState::AgentsDashboard` (`state.rs:17`), routed in `update.rs:240`.
- **Attach-to-stream path (reuse as-is):** `handle_dialogs.rs:1098
  view_selected_dashboard_item` → `client.agent_transcript(id)` → opens transcript
  viewer (`BackendEvent::AgentTranscript`, handled `handle_backend.rs:1352`). Stop path
  `stop_selected_dashboard_item` (`:1085`) → `client.cancel_agent(id)`.
- **status_bar goal+elapsed:** `status_bar.rs:139 fmt_elapsed_compact`; goal chip
  composed in `app/mod.rs:928 compose_goal_label` → "Working on: <goal> · 3m40s",
  synced every frame by `mod.rs:868 sync_goal_indicator`. Subagent footer cue
  `set_subagents(count,cost)` (`status_bar.rs:401`, rendered `:1084`
  `◇ N subagents · $cost · ↓ manage`).
- **Commands:** `/agents`→`open_agents_dashboard` (`commands.rs:308`), `/bg` (`:275`),
  `/fg`→`foreground_task` (`:303`). `↓` opens dashboard (`update.rs:931`).
- **Reusable tree primitive:** `mod.rs:503 grouped_entries()` + connectors in
  `render.rs:147-321` → `● main` → children hierarchy renders for free.

### 2.1 The CC-parity gap (what to actually build)
1. **`main` as row 0.** The roster currently shows only workers, not the root. Add a
   synthetic `main` node (glyph `●`, name `main`, activity = current top-level action,
   elapsed = turn elapsed, tokens = session tokens) as index 0 of the roster, in both
   `draw_tree` (inline) and `draw_dashboard` (full). It is never cancellable
   (`is_cancellable(0)=false`) and Enter on it = detach → return to main transcript.
2. **CC row layout.** Reformat the inline `draw_tree` row to the frozen spec (Part 1.1):
   `<glyph> <agent-type>  <live-activity…truncated>  <elapsed> · ↓<tokens>`. Glyph =
   `●` for selected/attached + `main`, `◯` otherwise. Reuse `fmt_elapsed_compact` and a
   k/M token formatter.
3. **Inline `← for agents` select mode.** Today selection lives only in the full-screen
   `/agents` dashboard. Add an inline focus mode so ← from the composer moves a cursor
   over the under-composer roster (↑/↓ select, Enter view, x stop, →/Esc back to
   composer) WITHOUT opening the full-screen state — matching CC. Implementation: a new
   lightweight `AppState::FleetSelect` (or a `roster_focus: bool` + cursor on `App`) that
   reuses `handle_agents_dashboard_key`'s logic against the inline roster index. Update
   the composer hint to show `← for agents` when idle and
   `Enter to view · x to stop` when a row is selected.
4. **Fleet event ingestion.** Handle the new backend `fleet_node_*` events (Part 3.0) by
   driving the same `Agents` mutation API, so full-power background nodes appear in the
   roster identically to orchestrator workers. Map `main` from existing
   session/goal/token state (no new backend event needed for the root row).

### 2.2 Non-goals for v1
- No new full-screen chrome — reuse `draw_dashboard`. The visible win is the inline
  under-composer roster + `←` select mode + the `main` root row.
- Keep the existing `/agents` dashboard as the "expanded" view; inline is the quick view.

## Part 3 — Backend design

### 3.0 Wire protocol (CONFIRMED)
Transport = **HTTP SSE**. TUI holds a long-lived `GET /api/v1/stream/{session_id}`
(`Accept: text/event-stream`); backend pushes `event: <type>\ndata: <json>\n\n`
frames off `Phoenix.PubSub` topic `"osa:session:{session_id}"`.

- Elixir encoder: `channels/http/api/agent_routes.ex:104-140` (`sse_loop/2`), wire
  write at `:120`. A `%{type: :system_event, event: sub}` becomes an SSE frame named
  `sub` (`:109-114`). Emitters use `orchestrator.ex` `emit_event/2` (`:1408-1427`)
  or `events/bus.ex:59` `Bus.emit(:system_event, ...)`.
- Rust decoder: `client/sse.rs` — frame parse `:221-224`, dispatch `parse_sse_event`
  `:278` (flat) → `parse_system_event` `:719` (system_event-wrapped). Pass-through
  frame-name list `:451-487`. Decoded into `enum BackendEvent`
  (`event/backend.rs:15`) and handled in `app/handle_backend.rs:32`.
- **Existing roster event** (reuse the shape): `orchestrator_agent_progress`, built
  in `orchestrator.ex` `forwarder_loop/4` (`:1259-1300`):
  `{event, agent_name, current_action, tool_uses, tokens_used, recent_actions,
  description}` → decoded `sse.rs:804-828` → `BackendEvent::OrchestratorAgentProgress`
  → `handle_backend.rs:1279` drives `self.agents`. Siblings:
  `orchestrator_agent_started` (`orch:263`/`sse:782`/`hb:1273`), `_completed`
  (`sse:842`), `scratchpad_activity` (`sse:1185`), `task_created`/`_updated`
  (`sse:974`/`991`).

**Adding the new `fleet_status` / `fleet_node_*` events = 4 edits, no route change:**
1. Elixir: `emit_event(parent_id, %{event: "fleet_node_update", ...})` from the
   orchestrator/RunStore wherever the tree changes.
2. Rust: add frame name to pass-through list `sse.rs:451-487`.
3. Rust: add decode arm in `parse_system_event` `sse.rs:726`.
4. Rust: add `BackendEvent` variant (`backend.rs:15`) + handler arm
   (`handle_backend.rs:32`).
   Unknown frames fall through to `ParseWarning` (fwd/bwd compatible; `#[serde(default)]`
   on all fields), so shipping the Elixir + Rust halves independently is safe.

### 3.1 Fleet model, spawn path, budget, caps (CONFIRMED anchors)

**Tree backbone** — `agent/run_store.ex` (`RunStore`). ETS `@table` + `~/.osa/agent-runs/
<id>.md` transcript + `.messages.etf` sidecar. `run` type carries `parent_session_id`
(the tree edge), `role, task, status, started_at, tool_count, tokens_used,
recent_actions`. `start_run/1` (needs `:agent_id` + `:parent_session_id`), `progress/3`,
`complete/2`, `list/1` (newest-first), `get/1`. Boot rehydrate: `init_store/0`→
`rehydrate/0` (call from supervisor boot). Tree read for FleetView = `RunStore.list/1`.

**Full-power spawn (USE THIS)** — `runtime/session_manager.ex`
`SessionManager.ensure_loop(session_id, opts)` → `start_loop/2` →
`DynamicSupervisor.start_child(SessionSupervisor, {Loop, loop_opts})`. `loop_opts` threads
`[user_id, channel, working_dir, parent_session_id]` and sets **no** `permission_tier`
and **no** `channel: :internal`, so `Loop.init` (`loop.ex:688`) defaults
`permission_tier: :full`, non-coordinator, `delegation_depth: 0` — full tools/MCP/memory/
permissions. Drive via `Loop.process_message/3` / `process_message_async/3`. Caller MUST
also `RunStore.start_run/1` (SessionManager does not) so the node gets a tree row.

**Custom-agent system prompt** — spawn with the chosen agent-type's system prompt + tool
allowlist. The agent-type identity (`main`, `general-purpose`, `code-reviewer`, …) maps to
a system-prompt + tool set applied at `Loop.init` via opts (system prompt override + tool
filter). v1: pass `role`/agent-type through `ensure_loop` opts and resolve the prompt in
`Loop.init` from an agent-type registry (reuse whatever the delegate path uses for role
prompts; if none, a small `fleet_agent_types` table: name→{system_prompt, tools}).

**AVOID (restricted path)** — `orchestrator.ex run_subagent/1` hard-codes
`user_id:"subagent"`, `channel: :internal`, `permission_tier: :subagent`,
`delegation_depth: parent+1`. That's the lightweight worker, not a fleet node.

**Subtree cancel (reuse as-is)** — `SessionManager.cancel/1` → `Loop.cancel/1`:
`descendant_session_ids/1` BFS over `parent_session_id`, sets `:osa_cancel_flags`, cancels
bg shell jobs, `force_terminate_subagent/1` on each descendant GenServer. Root spared
unless it has a parent. `x`/stop on a fleet node → `SessionManager.cancel(node_id)`.

**`/fg` (NET-NEW)** — no foreground switch exists. Add: CLI `channels/cli/commands.ex`
`@commands` entry + handler, and/or an HTTP route; the live process is addressable via
`SessionRegistry`. For the TUI, "attach" is already a *read view* (transcript viewer via
`client.agent_transcript`), so `/fg` in the TUI = select node + Enter (view). A true
input-handoff `/fg` (send your next message to that node) is a later increment.

**Budget persistence (D2)** — `agent/loop/checkpoint.ex checkpoint_state/1` already
persists SPEND (`session_cost_usd` + token totals, atomic tmp+rename) but NOT the cap.
`max_budget_usd` is re-read fresh each `Loop.init` from opts→app env (default `nil`). Fix
= restore half: on `Loop.init`, if a checkpoint has accumulated `session_cost_usd`, seed it
into state (already restored via `restore_checkpoint/1`) AND ensure `max_budget_usd`
survives — persist the cap in the checkpoint data map and restore it, so a $50 cap can't be
reset to $0 by a crash/restart.

**Caps** — delegation depth ceiling exists (`loop/tool_filter.ex
@default_max_delegation_depth 3`, strips spawning tools past depth). **No global
total-agent cap** — net-new if the fleet needs a fleet-wide ceiling
(count `RunStore.list` where `status==:running`, deny spawn past `:max_fleet_agents`).

### 3.2 New wire events (the contract both sides build to)
Follow the `orchestrator_agent_progress` pattern. Emit via
`Bus.emit(:system_event, %{event: <name>, session_id: <root/parent>, ...})`, add `<name>`
to `TuiForwarder.@forward_events` allowlist, add decode arm in `sse.rs` +
`BackendEvent` variant + `handle_backend.rs` arm.

```
fleet_node_started    { session_id(parent), node_id, agent_type, task, flavor("full"|"worker"), depth }
fleet_node_progress   { session_id, node_id, current_action, tool_uses, tokens_used, recent_actions }
fleet_node_completed  { session_id, node_id, summary, status("completed"|"failed"|"cancelled") }
```
The `main` root row needs NO backend event — the TUI synthesizes it from existing session
goal/token/elapsed state. These three just make full-power background nodes appear in the
roster via the existing `Agents` mutation API (`agent_started/progress/completed`).

---

## Build plan (ordered, each gated + committed attribution-clean)

**B1 — TUI CC-parity roster (visible win, mostly reuse).** Rust, `priv/rust/tui/`.
- Add synthetic `main` node as row 0 in the inline roster + dashboard (glyph `●`, name
  `main`, activity=top-level action, elapsed=turn elapsed, tokens=session tokens; not
  cancellable; Enter = detach to main transcript).
- Reformat inline `draw_tree` row to the frozen CC layout: `<glyph> <agent-type>
  <activity…>  <elapsed> · ↓<tokens>` (reuse `fmt_elapsed_compact` + k/M formatter).
- Add inline `← for agents` select mode: `AppState::FleetSelect` (or `roster_focus` flag)
  reusing `handle_agents_dashboard_key` logic against the inline roster; composer hint
  `← for agents` / `Enter to view · x to stop`.
- Gate: `cargo build` + `cargo test` in `priv/rust/tui`.

**B2 — Elixir full-power spawn + fleet events + `/fg`.** Elixir, `lib/`.
- `spawn_fleet_node/2` helper: `SessionManager.ensure_loop` (full-power opts) +
  `RunStore.start_run/1` + resolve agent-type system prompt/tools.
- Emit `fleet_node_started/progress/completed`; add names to `TuiForwarder.@forward_events`.
- `/fg` command (CLI + select-node view already covers TUI attach).
- Global fleet cap (`:max_fleet_agents`) + reuse `SessionManager.cancel/1` for stop.
- Gate: `mix compile` + targeted `mix test`.

**B3 — Rust fleet-event ingestion.** Decode `fleet_node_*` in `sse.rs` + `BackendEvent`
(`backend.rs`) + `handle_backend.rs` → drive `Agents`. Gate: `cargo build`+`cargo test`.

**B4 — Budget persistence (D2 restore).** `checkpoint.ex` persist+restore `max_budget_usd`;
`loop.ex init` honor it across restart. Gate: `mix test` on the checkpoint/loop budget path.

B1+B2 are disjoint file sets (Rust vs Elixir) → build in parallel. B3 depends on B2's event
names (contract above, so it can proceed against the frozen names). B4 is independent.

---

## Part 4 — Dynamic-workflow orchestration layer (researched from CC docs)

CC has THREE distinct multi-agent systems (not one). Mapping to OSA:
- **Subagents** (in-session Task delegation) → OSA's existing `delegate`/`run_subagent`.
- **Agent Teams** (independent peer sessions + shared task list + roster panel) → OSA's
  FleetView (Parts 1–3): `spawn_fleet_node` full-power peers + the roster.
- **Dynamic Workflows** (a script fans out agents at scale, run OUTSIDE the conversation,
  results in script vars not context) → NET-NEW for OSA. This is what the user means by
  "the dynamic workflows thing."

### 4.0 CRITICAL distinction + the effort gate (user requirement)
These are TWO DIFFERENT DEPTHS and must NOT be conflated:
- **Agent spawning (FleetView)** = fire off N independent peer agents (5, 6, 10) that each
  do their own work side by side. Available at ANY effort level. Parts 1–3.
- **Dynamic workflows** = DEEPER — a small set (often 2/3/4) of agents ORCHESTRATED to work
  TOGETHER via deterministic control flow (fan-out → hand-off → verify → synthesize), not
  merely spawned in parallel. This is gated.

**THE GATE: dynamic workflows only activate at the MAX effort tier, named `ultra`.** This
mirrors CC exactly — `/effort ultracode` is what unlocks automatic workflow orchestration;
subagents/peer-spawning work without it. So OSA:
- adds/uses a max effort tier called **`ultra`** (OSA's `ultracode` equivalent);
- gates the dynamic-workflow orchestration engine behind `effort == ultra` — below ultra,
  the orchestration fan-out is disabled (or falls back to plain peer-spawning);
- keeps FleetView peer-spawning + the roster available at every effort level.
The gate is a runtime check at the workflow-entry (`Fleet.fan_out` / the orchestration
driver): if effort < ultra, refuse to start an orchestrated workflow (clear message: "raise
effort to ultra to run dynamic workflows"), while `spawn_fleet_node` stays unguarded.
Wiring location = TBD from effort-mode recon (does OSA have an effort/reasoning tier already?
add `ultra` as its max; else design a minimal effort mode with `ultra` on top).

**HARD CONSTRAINT — preserve the thinking display.** OSA already shows reasoning with a
"Thought for Ns" timer + a live thinking indicator (`components/activity.rs`). Adding effort
tiers MUST NOT regress this. The effort tier should DRIVE the reasoning budget (higher effort
= more thinking) and the existing indicator must keep working at every tier — ideally more
visible thinking at `ultra`. Effort→thinking wiring anchors come from the effort-mode recon
(the thinking-display end-to-end map). Any effort change ships with the thinking indicator
verified intact.

### 4.1 The real caps (CC docs — corrected)
- **16 concurrent agents / machine** (hard; lower on CPU-constrained boxes).
- **1,000 total agents / run** (runaway kill switch).
- **≥25 scheduled = "Large workflow" warning** (a warning, NOT a cap).
- Excess spawns past 16 **queue FIFO and drain** as slots free — they do NOT fail.
- No single session-wide "N/32" gauge exists; counts show per-phase in `/workflows` and as
  `← N agents` in the agent footer. The user's "25/32" = a conflation of 16-cap + 25-warning.

### 4.2 OSA mapping / build (B5, after B1–B4)
- **Concurrency = 16, queue-drain.** Reuse the `:max_fleet_agents` gate (set 16) but change
  semantics from *refuse-past-cap* to *bounded pool + FIFO queue*: a fan-out of N nodes runs
  16 at a time, enqueues the rest, drains as `fleet_node_completed` frees a slot. Elixir-native:
  a `Task.Supervisor` + a bounded queue GenServer (or `:max_concurrency` on
  `Task.async_stream`). Add `:max_fleet_total` (1000) run-lifetime kill switch.
- **Live counter in the roster header.** Render `running/cap` (e.g. `14/16 agents`) in the
  FleetView header (inline `draw_tree` header at `render.rs:48` + dashboard). Emit a
  `fleet_summary {running, queued, cap, total_spawned}` Bus event (add to TuiForwarder
  allowlist + a Rust decode arm) so the header is live. "Large fleet" (dim warning) at ≥25.
- **Fan-out driver (optional v2).** A workflow-style fan-out entry: given a list, spawn one
  fleet node per item through the bounded pool. Keep OSA's version as an Elixir orchestration
  fn first (`Fleet.fan_out(items, agent_type, opts)`), not a JS scripting runtime — the JS
  script layer is a much larger, separate effort and not needed for the counter/queue UX the
  user is asking for.

Build order: finish B1–B4, then B5 (queue-drain + counter). B5's counter renders in the
same roster header B1 builds, so B5 lands after B1 to avoid churn on `render.rs`.
