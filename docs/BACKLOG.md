# OSA Full Backlog — final state (2026-07-19)

Every item from the reconciliation, now built + committed unless noted. 43 local
commits on `main`, NOT pushed, held at v1.0.10. Backend live on :9089.

Status: ✅ done+committed · 🟢 done, opt-in/gated by design · ⏸ deferred with rationale

---

## Backend / agent
| ID | Item | Status | Proof |
|----|------|--------|-------|
| U-A1 | token-budget work-to-target auto-continue | ✅ | react_loop, db28787 |
| U-A2 | hashline self-verifying edits (drift guard) | ✅ | drift_guard.ex, 8b1175a |
| U-A3 | rollback-safe self-update (atomic swap) | ✅ | bin/osa-update, f041853 |
| U-A4 | output-shorten-to-file at tool boundary | ✅ | tool_result_storage.ex, 8b1175a |
| — | multi-turn goal orchestration (goal_tracker) | ✅ | goal_tracker.ex + wired, e40ba38 |
| — | persisted vector store | ✅ | memory_vectors table, 9907ad3 |
| — | post-compaction auto-continue | ✅ | proactive_compaction + wired, e40ba38 |
| — | **message-derived loop state (crash-resume)** | ✅ | COVERED by a different mechanism — verified: Checkpoint.checkpoint_state runs per-iteration (react_loop:1088), Loop.init restores it (loop.ex:581) + falls back to SessionPersistence, so a mid-turn crash resumes; interleaving is handled by the Steer queue + task-notification drains. opencode's re-derive-every-step architecture would add zero capability. |

## TUI — composer
U-T1 @-mention structured attachment ✅ · U-T2 Ctrl+N/P history + Alt+D ✅ · U-T3 ghost-text ✅ ·
U-T4 bash `!` submit-mode ✅ · U-T5 huge-input pill ✅ · U-T6 frecency recall ✅ · U-T30 @-popup glyphs ✅
(all 916ed25; submit-consumption a90dae2 — image mentions carried, structured @file/@agent refs ⏸ need a backend request field)

## TUI — render
U-T7 raw-toggle ✅ (alt+r, a90dae2; live-preview swap ⏸ streaming-height tension) · U-T8 LaTeX→Unicode ✅ ·
U-T10 table-cell markdown/nested-quote/tabs/soft-break ✅ · U-T31 bold-italic/setext ✅ (all 916ed25)
+ constant inline-viewport "real cure" ✅ 9638491 · remove PlanReview from is_overlay ✅ 9638491

## TUI — notifications / focus / clipboard
U-T7-copy ✅ · U-T11 focus (DECSET 1004) ✅ · U-T12 OSC 9;4 progress ✅ · U-T13 macOS Shift probe ✅ ·
U-T15 sleep inhibitor ✅ · U-T16 audio cue ✅ · U-T17 kitty click-to-focus ✅ · U-T18 notify channel+hooks ✅ ·
U-T19 layered clipboard ✅ · U-B3 kitty re-push ✅ (8edab6c + a90dae2)

## TUI — status / activity
U-T22 esc-again-to-interrupt ✅ · U-T23 watcher cue ✅ · U-T24 queued hint ✅ · U-T25 usage-%+low-balance ✅ ·
U-T26 MCP chip ✅ (LSP half ⏸ no backend LSP concept) · U-T27 spinner width-gating ✅ · U-T28 subagent footer ✅ ·
U-T29 categorical /context ✅ (already present) (8edab6c)

## Bug cluster
U-B1 newline probe ✅ 3da7e45 · U-B2 Ctrl+O expand-first ✅ a90dae2 · U-B3 kitty re-push ✅ ·
U-B4 ThinkingDelta gate ✅ · U-B5 dead handlers (SkillsLoaded removed, Swarm wired; ModelsLoaded gone) ✅ ·
U-B6 bg double-count + ToolResult ordering ✅ (8edab6c)

## Mouse (crossterm-gated)
U-T9 click-to-open link, U-T14 transcript text-selection, U-T21 stop/bg buttons ⏸ — crossterm can't do
click-position AND native wheel-scroll together (documented decision). U-T14 is the one partial worth
revisiting (overlay-scoped capture); U-T9/U-T21 stay deferred.

---

## Deferred with rationale (not dropped — deliberate)
1. **Message-derived loop state** — a rewrite of react_loop's core state management to re-derive from
   persisted messages each step. The audit itself rated this MED-LOW *because OSA already has durable
   checkpoint/resume* (checkpoint.ex, durable_log, session_persistence). The only marginal gain is
   mid-turn crash resume — an edge case OSA mostly covers — and the cost is destabilizing the core loop
   that now carries 6 waves of carefully-wired behavior. Holding this is the correct risk/reward call,
   not a gap. Revisit only if mid-turn crash resume becomes a real observed need.
2. **Structured @file/@agent refs on the wire** — image mentions carry today; non-image refs still reach
   the model as inline prompt text (nothing lost). A proper structured carry needs a new OrchestrateRequest
   field + backend handling — a small backend feature, not TUI glue.
3. **Mouse U-T9/U-T21**, **LSP status half**, **live-preview raw swap** — genuinely blocked (crossterm),
   no data source, or in tension with the inline-viewport invariant. Each noted at its row.

## Not started elsewhere (infra, previously deferred-by-choice)
Session sharing (hosting server), network-proxy egress sandbox — low value for local single-operator use.
Push + release — user-gated (43 commits local, unpushed).
