# OSA Fleet / Workflow / Effort — Edge-Case Hardening Plan

Every failure mode of the FleetView + dynamic-workflow + effort system, the intended
behavior, and the workstream that owns it. Each workstream owns a DISJOINT set of files
so agents can build in parallel without collision. TDD each fix.

---

## W1 — fan_out / workflow robustness   (OWNS: `agent/fleet.ex` + its test)
- **Node error isolation**: one item throwing/failing must NOT kill the whole workflow —
  it drops to a `{:error, ...}` result, the slot frees, remaining items continue.
- **Per-node timeout**: `fan_out` uses `timeout: :infinity` → a hung node stalls the queue
  forever. Add a configurable per-node timeout (`:node_timeout_ms`, sane default) so a
  runaway node is reaped and its slot freed; record it as a timed-out result.
- **Empty / single / huge items**: `items: []` → `{:ok, %{total: 0, ...}}` (no-op, no
  crash). Single item works. `> :max_fleet_total` (1000) → truncate + report `dropped`.
- **Slot accounting on failure/timeout**: `fleet_summary` running/queued stays correct even
  when items fail/timeout (don't leak slots).
- **Effort flips mid-workflow**: a workflow already started at `:ultra` keeps running even
  if effort is lowered mid-flight (gate is checked once at entry, not per item).
- **Concurrency never exceeds cap** under churn (existing test — keep it green).

## W2 — budget across the fleet   (OWNS: `agent/loop/accounting.ex`, `agent/loop/checkpoint.ex`, budget bits of `agent/loop.ex`)
- **Cap-defeat via fan-out**: N child nodes each under their own cap can blow the intended
  total. Add a fleet/tree budget rollup (or a shared parent budget the children draw from)
  so `max_budget_usd` bounds the WHOLE tree, not each node independently.
- **Budget hit mid-fleet**: when the (tree) budget is exhausted, STOP spawning new nodes
  (fan_out refuses further items) and surface it — don't silently overspend.
- **Persist/restore already done** (`max_budget_usd` in checkpoint) — add a test that a
  restored cap still bounds a resumed fleet.

## W3 — crash recovery / orphans (D3)   (OWNS: `agent/run_store.ex` recovery path + a boot resumer + `application.ex` supervisor wiring)
- **Parent crash orphans children**: live fleet descendants die with the daemon and are
  never resumed. On boot, walk `RunStore` for runs left `:running` under an autonomous
  posture and re-dispatch live descendants (extend the existing `task_resume` to a subtree
  resume), budget-capped.
- **Queued (not-yet-started) workflow items on crash**: document they're lost in v1 (only
  started nodes are durable) — `log()` the drop, don't pretend they ran.
- **Stale `:running` rows**: rows for nodes whose process is gone must be reconciled at boot
  (mark failed/cancelled) so the roster + counts aren't inflated.

## W4 — effort × provider matrix   (OWNS: `providers/anthropic.ex`, `providers/openai_compat.ex`, `providers/google.ex`, `providers/ollama.ex`, `agent/loop/llm_client.ex` thinking_config + a provider-matrix test)
- **Per provider per tier**: opus (adaptive below ultra, enabled+64k at ultra — done, add
  matrix test), non-opus anthropic (enabled+budget), OpenAI (`reasoning_effort` fast→low /
  xhigh,ultra→high — done, test), Gemini (`thinking_budget`), Ollama (no thinking → must
  no-op cleanly, never crash).
- **`off` tier**: thinking disabled; `off` + `fleet_workflow` → ultra-gate refuses (can't
  run workflows at off). Verify `off` doesn't send a thinking block anywhere.
- **Invalid / unknown effort value** from persisted config → `normalize/1` keeps it,
  `get/1` falls back to `:medium`; assert no crash anywhere in the provider path.

## W5 — fleet tool arg validation   (OWNS: `tools/builtins/fleet/handler.ex`, `tools/builtins/fleet/tool.ex` + test)
- **Bad `action`** (neither spawn nor workflow) → clear validation error to the model.
- **`workflow` with missing/empty `items`** → clear error, no crash.
- **`workflow` below ultra** → the ultra-gate message ("raise effort to ultra…") reaches the
  model so it can raise effort OR fall back to `spawn`.
- **`spawn` at fleet cap** → graceful refusal message (not a crash).
- **agent_type unknown** → falls back to `general-purpose` (registry default), not an error.
- **Schema stays clean**: no `Type.Union`/`anyOf`/`oneOf`/`format` (keep the asserting test).

## W6 — scratchpad concurrency   (OWNS: `tools/builtins/scratchpad/handler.ex` + test)
- **Concurrent writes from many nodes**: N fleet nodes writing the shared scratchpad at once
  must not corrupt it (atomic append / serialized write). Verify no lost/torn entries.
- **Turn-boundary clear during a live workflow**: the scratchpad clears on new turn — ensure
  an in-flight workflow's shared entries aren't wiped mid-run (or are re-seeded).
- **Seed failure is best-effort** (already wrapped) — keep it non-fatal.

## W7 — README + capability docs   (OWNS: `README.md`, `docs/BACKLOG.md`)
- Update README with the new capabilities: FleetView roster (CC-parity), full-power fleet
  spawn, dynamic workflows (ultra-gated), the `fleet` tool, effort ladder
  fast/medium/high/xhigh/ultra + effort-in-thinking, budget-survives-restart. Add a short
  "Agent Fleet & Dynamic Workflows" section + an effort-levels table. Keep tone/format
  consistent with the existing README. Update `docs/BACKLOG.md` scoreboard.

---

## Rust-TUI edge cases — DEFERRED to wave 2 (after the arrows-verify agent frees priv/rust/tui)
- Roster overflow (many nodes → scroll/cap), long node names (truncate — mostly done),
  `fleet_summary` running>cap defensive clamp, arrows pressed during Processing / empty
  roster, main-row token/elapsed accuracy, roster flicker under rapid churn (prune_stale).
- These OWN the Rust TUI files the arrows agent is currently editing → must wait.

## Sequencing
W1–W7 own disjoint files → launch in parallel now. Rust-TUI wave-2 after arrows-verify +
this wave land. Then cut the release (v1.0.028) capturing everything.
