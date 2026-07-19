# Goal Verification, Goal Tracking, and Loop Discipline

Harness-owned layers that sit on top of the ReAct loop's own guardrails
(see [loop.md](loop.md)) to judge whether the user's actual *goal* was met —
not merely whether a file compiled — and to keep long, multi-turn autonomous
runs from spinning forever. Off by default; all four are opt-in via
application config (see
[Configuration → Agent Behavior](../../getting-started/configuration.md#agent-behavior-wave-2b2c)).

---

## Investigative Plan Mode

`enter_plan_mode` / `exit_plan_mode` are builtin tools
(`OptimalSystemAgent.Tools.Builtins.EnterPlanMode`, `...ExitPlanMode`) that
gate a session into a read-only investigation posture before any writes
happen.

- `enter_plan_mode` calls `Agent.Loop.enter_plan_mode/1`, a `GenServer` call
  that mutates `plan_mode_enabled` on the live `Loop` process — the loop
  itself is the single writer of that state. If no live loop is found (e.g.
  offline/test contexts), the tool still returns a confirmation rather than
  erroring.
- While active, only read-only tools are permitted; `exit_plan_mode` ends the
  investigation and hands control back for execution.

**Durable plan file** (`Agent.PlanStore`) — the plan *text* is the source of
truth on disk, not transient process state:

```
~/.osa/sessions/<safe_id>.plan.md      # the plan itself
~/.osa/sessions/<safe_id>.progress.md  # the progress ledger (Agent.ProgressLedger)
```

This means a plan survives context resets, session restarts, and the whole
daemon bouncing. An ETS table (`:osa_pending_plans`) is kept only as a
*pending-approval index* — it records that a plan is awaiting a
`plan_approve` / `plan_reject` / `plan_edit` decision (original user input +
timestamp) for the HTTP handlers that drive the TUI's `plan_review` dialog.
`take/1` (approve) clears the pending marker but deliberately leaves the plan
file on disk as a durable record.

---

## Goal Verifier (single-turn)

**Module:** `OptimalSystemAgent.Agent.Loop.GoalVerifier`
**Config:** `goal_verifier_enabled` (default `false`)

An independent, read-only skeptic panel that judges goal-completion for the
CURRENT turn, modeled on grok-build's `session/goal_classifier.rs`. It spawns
N separate, read-only subagents — each with fresh context, no visibility into
how the work was produced — instructed to try to REFUTE goal-completion, and
aggregates their votes by **strict majority-refute**.

| Verdict | Meaning |
|---|---|
| `:complete` | A strict majority of skeptics did NOT refute goal completion. |
| `:incomplete` | A strict majority refuted, but did not judge the goal unachievable — another attempt is warranted. |
| `:off_track` | A strict majority refuted AND a strict majority of those refuters judged the goal environmentally blocked/contradictory — surfaced as a redirect, not a "try harder" nudge. |

Any not-refuted vote does **not** default to "achieved" on a tie or missing
data — uncertainty fails closed to `:incomplete`.

**Budget discipline** — two cheap circuit breakers bound cost before the
expensive subagent panel is ever spawned:

- **Run cap** (`goal_verifier_max_runs`, default `3`) — after N rounds in a
  turn, the gate steps aside and lets the agent finish.
- **Stall early-exit** (`goal_verifier_stall_threshold`, default `2`) — two
  consecutive rounds citing the identical gap fingerprint (via
  `gap_fingerprint/1`, a normalized+sorted `phash2` of the refuting skeptics'
  cited gaps) stop further re-prompting.

A cheap local precondition (`has_accumulated_work?/1` — at least one
successful write on record) is checked before the panel is ever spawned, so
read-only turns never trigger it.

`goal_verifier_skeptic_count` (default `3`, clamped to `1..5`) controls panel
size.

---

## Goal Tracker (cross-turn)

**Module:** `OptimalSystemAgent.Agent.Loop.GoalTracker`
**Config:** `goal_tracker_enabled` (default `false`, or auto-on for an
autonomous session posture)

`GoalVerifier`'s bookkeeping lives in the `state` map threaded through
in-process recursion — it resets to zero at the start of every NEW top-level
turn. `GoalTracker` is the missing cross-turn layer: a small ETS-backed
state machine, keyed by `session_id`, modeled on grok-build's
`session/goal_tracker.rs` (`GoalStatus`/`GoalPhase`,
`GOAL_CLASSIFIER_STALL_THRESHOLD`).

Status: `:active | :paused | :completed | :off_track`. Phase: `:idle |
:planning | :executing`.

| Behavior | Config Key | Default |
|---|---|---|
| Lifetime run cap across the WHOLE goal before auto-pause (`:paused`, reason `:run_cap`) | `goal_tracker_max_runs` | `12` |
| Reverify cadence — how often the expensive skeptic panel is spawned | `goal_tracker_reverify_after` | `8` turns |
| Cross-turn stall detection — same gap fingerprint across two verification rounds → auto-pause (`:paused`, reason `:no_progress`) | `goal_tracker_stall_threshold` | `2` |

Transitions: `:active -> :completed` when `GoalVerifier` returns `:complete`;
`:active -> :off_track` (queuing a re-plan nudge via `Agent.Loop.Steer`) when
`GoalVerifier` returns `:off_track`; `:active -> :paused` on stall or run-cap.

`GoalTracker` reuses `Agent.ProgressLedger` as its durable goal store —
`start/2` writes the goal into the ledger's `## Goal` section, and every
status transition is appended to the ledger's `## Log`, so transition history
survives a context reset or daemon restart the same way every other durable
goal signal in OSA does.

**Wiring** (in `react_loop.ex`):

```elixir
goal_verifier_enabled?(state) and GoalVerifier.needs_verification?(state) and
    GoalTracker.reverify_due?(state.session_id) ->
  {result, state} = GoalVerifier.verify(state)
  GoalTracker.advance(state.session_id, result)
  # :complete -> finish_turn; otherwise inject the panel's directive and loop
```

---

## Reasoning-Only Doomloop Detector

**Module:** `OptimalSystemAgent.Agent.Loop.DoomLoop.ReasoningOnly`
**Config:** `doom_loop_resample: [reasoning_only_threshold: N]` (default `3`)

OSA's other doomloop detectors (`IdenticalCall`, `Stall`, `FailureSignature`)
all key off repeated *tool calls*. A model that spins purely in thought (zero
tool calls every generation) or whose turn keeps erroring produces no
tool-call signature at all, so none of them trip — and the absolute call cap
never moves either, since it only counts tool calls.

This detector tracks a consecutive counter of "empty" turns — a generation
with zero tool calls, or one flagged via `state[:turn_errored]` — on
`state[:reasoning_only_streak]`, and halts once the streak reaches
`threshold/0`. Any turn that DOES carry a tool call resets the streak. On
halt it returns the same `{:halt, message, state}` contract the other
detectors use, so it plugs into the existing `Resample` remedy with no new
plumbing.

---

## Forced Max-Steps Wrap-Up

When the loop hits `max_iterations`, instead of a canned truncation message,
`forced_wrapup/2` runs one final **tools-disabled** model turn so the user
gets a real state summary and handoff. The call is wrapped in
`try/rescue/catch` with a static fallback message, so hitting the cap can
never itself crash the turn.

---

## Header-Aware Retry

Provider resilience (`OptimalSystemAgent.Providers.Resilience`,
`RetryClassifier`) honors a `Retry-After` header from the provider (capped at
60s) instead of blind exponential backoff when the provider supplies one, and
can drive a header-aware retry decision that rebuilds the HTTP/1.1 client or
strips images from the retried request when that is what the failure calls
for.

---

## First-Failure Self-Correction (grounded, not ungrounded)

**Module:** `OptimalSystemAgent.Agent.Loop.VerificationGate`

Research motivation: CRITIC (Gou et al.) and *"Large Language Models Cannot
Self-Correct Reasoning Yet"* (Huang et al.) both show that *ungrounded*
self-correction — a model re-judging its own output with no external signal —
tends to leave accuracy flat or degrade it. `VerificationGate` enforces
grounding at the point the agent is about to declare a turn done: it
re-prompts only after an external, grounded check (build/test/lint) has
actually run and failed against the change — not on the model's own say-so.
`GoalVerifier` (above) is the harness-owned escalation on top of this for the
narrower "did it compile" case not covering "was the right thing built".

---

## Token-Budget "Work to Target"

**Config:** `target_output_tokens` (state key or app env; default `nil` = off)

Lets a caller (or session state) set a target output-token budget for a
session. When set and positive, the loop keeps auto-continuing —
`token_target_unmet?/1` checks `state.session_output_tokens < target` — up to
`@max_target_continues` continues, instead of stopping at the first
"complete-looking" response. This is CC-parity "work to target": useful when
a caller wants the agent to keep elaborating/working until a token budget is
actually consumed, not just until the model decides it's done.

---

## See Also

- [Agent Loop](loop.md)
- [Context Compactor](compactor.md) — for post-compaction auto-continue
- [Delegation](../orchestration/delegation.md) — for cascading cancel and worktree snapshots
- [Configuration → Agent Behavior](../../getting-started/configuration.md#agent-behavior-wave-2b2c)
