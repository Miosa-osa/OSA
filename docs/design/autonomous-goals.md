# Autonomous goals

Status: design sketch. **Nothing here is implemented by the change that
accompanies it** — the shippable half of that work was making compaction a
continuation (`docs/design/context-compaction.md` is the subsystem; the
continuation behaviour lives in `Agent.Loop.ReactLoop` and
`Agent.Loop.ProactiveCompaction`). This document describes the *next* thing:
OSA setting its own goal and its own completion criteria, and working until it
meets them.

**The problem in one sentence:** OSA can already be told what to do and can
already judge whether it did it, but nothing connects those two facts, so every
long-horizon run is still paced by a human typing the next message.

All file:line citations are OSA's, relative to the repository root.

---

## Part 1 — What already exists

More of this is built than one would guess. The pieces are individually mature;
what is missing is almost entirely wiring and one decision-making stage.

### 1.1 The plan — `Agent.Tasks` / `Agent.Tasks.Tracker`

`lib/optimal_system_agent/agent/tasks/tracker.ex`

A per-session checklist with real state transitions
(`:pending → :in_progress → :completed | :failed`), Bus + SSE events on every
transition, and atomic JSON persistence at
`~/.osa/sessions/<id>/tasks.json`. Items can be added by the model (the
task/todo tools), extracted from a response (`extract_from_response/1`), or
added programmatically.

This is the closest thing OSA has to "what am I doing", and it is durable across
BEAM invocations. It is also now the thing that survives a compaction fold and
gets restated to the model in the post-compaction continuation
(`ProactiveCompaction.continuation_message/1`).

What it is *not*: a goal. It has no notion of done-ness for the run as a whole,
no acceptance criteria, and no author — an item added by the model and an item
added by the user are indistinguishable.

### 1.2 The founding instruction — `Agent.TaskBrief`

`lib/optimal_system_agent/agent/task_brief.ex`

`{goal, constraints, acceptance_criteria, created_at}`, captured **once** per
session, stored on disk, and injected into the `role: "system"` block by
`Agent.Context.build/1` on every turn
(`lib/optimal_system_agent/agent/context.ex:1506`). Deliberately immutable: it
is the run's founding instruction, not a status field.

This already answers the hardest durability question in the whole design — the
original goal cannot be compacted away, because it is re-derived from disk into
a system block on every turn. **`acceptance_criteria` is already a field.** It
is presently only ever filled in by a human.

### 1.3 The mutable goal + log — `Agent.ProgressLedger`

A durable markdown ledger with a `## Goal` section and a `## Log` of
timestamped entries. Written by `progress_note`
(`lib/optimal_system_agent/tools/builtins/progress_note/handler.ex:75`) and by
the memory coordinator. This is where a *changing* goal lives, as opposed to the
brief's frozen one.

### 1.4 The cross-turn goal machine — `Agent.Loop.GoalTracker`

`lib/optimal_system_agent/agent/loop/goal_tracker.ex`

An ETS-cached, disk-backed state machine keyed by session:
`status ∈ {:active, :paused, :completed, :off_track}`,
`phase ∈ {:idle, :planning, :executing}`, a cross-turn stall detector (two
consecutive verification rounds citing the same gap fingerprint → auto-pause
`:no_progress`), a lifetime run cap (→ auto-pause `:run_cap`), and a
reverify-after cadence so the expensive panel is not spawned every turn. It
queues a re-plan nudge through `Agent.Loop.Steer` when a goal goes off-track.

This is a well-built circuit breaker for exactly the failure mode an autonomous
loop has.

### 1.5 The completion check — `Agent.Loop.GoalVerifier` and `VerificationGate`

Two different claims, deliberately:

- `VerificationGate` proves the narrow, cheap, *grounded* claim: a file was
  written and a build/test/lint subsequently passed against it.
- `GoalVerifier` spawns N read-only skeptic subagents with fresh context, each
  instructed to try to **refute** goal-completion, and aggregates by strict
  majority-refute. A not-refuted vote does not default to "complete".

Together these are a genuinely strong answer to "is it done?" — stronger than
asking the model that did the work.

### 1.6 Re-entry mechanisms that already drive a turn without a user

- `Agent.BackgroundNotifier` — a finished background sub-agent injects a
  synthetic turn into the parent session.
- `Agent.Loop.Steer` — mid-turn directives folded in at a step boundary.
- `Agent.Scheduler` / `Agent.Attendance`.
- The post-compaction continuation added alongside this document.

So "something other than a user message causes the loop to take another step"
is a shape OSA already has, four times over.

---

## Part 2 — What is missing

### 2.1 Nothing ever starts a goal

`GoalTracker.start/2` has **no callers in `lib/`**. Grepped:

```
$ grep -rn "GoalTracker.start(" lib
lib/optimal_system_agent/agent/loop/goal_verifier.ex:194:    * an anchored goal loop — `GoalTracker.start/2` set a real goal that is
```

— a doc comment. `GoalTracker.ensure/1` and `GoalTracker.continue?/1` likewise
have no callers. The only live entry point is `GoalTracker.advance/2`, called
from `GoalVerifier` (`goal_verifier.ex:372`), which advances a state machine for
a goal that was never started.

There is also no `/goal` command in the CLI command table
(`lib/optimal_system_agent/channels/cli/commands.ex`). The whole cross-turn goal
layer is reachable only by accident.

The *brief* half is live, and only that half: `ProgressLedger.set_goal/2` calls
`TaskBrief.capture/2` (`progress_ledger.ex:449`), and the `progress_note` tool
reaches `set_goal/2`. So a model that calls `progress_note` with a goal does get
a durable brief injected into every subsequent system prompt — but no tracker,
no stall detector, no run cap, and no phase.

**This is the single highest-value gap and it is small.** A `/goal` command that
calls `GoalTracker.start/2` + `TaskBrief.capture/3` lights up the tracker, the
brief injection, the stall detector, the run cap, and the verifier's
"anchored goal loop" activation heuristic, all of which are already written.

### 2.2 Completion criteria are never authored, only consumed

`TaskBrief`'s `acceptance_criteria` is a string a human writes. Nothing asks the
model to propose criteria, and nothing checks the proposed criteria are
*checkable* — "the code is clean" is not a completion criterion; "`mix test`
passes and `lib/foo.ex` exports `bar/1`" is.

Missing stage, in order:

1. **Elicit** — from the user's instruction, propose 3-7 acceptance criteria.
2. **Ground** — reject criteria with no mechanical check behind them. Reuse
   `VerificationGate`'s notion of grounded evidence: each criterion must name a
   command to run or a file/symbol to assert on.
3. **Confirm** — show them and get one cheap human yes before a long unattended
   run. This is the honest place for the human to be in the loop, and it is
   before the expensive part rather than after.
4. **Freeze** — `TaskBrief.capture/3`, which is already immutable and already
   injected every turn.

### 2.3 No autonomous re-entry on the goal

The re-entry mechanisms in §1.6 are all *reactive* — something finished, so take
another step. None of them is "the goal is not met, so take another step".

The missing loop is:

```
turn ends with no tool calls
  → GoalTracker.continue?(session_id)?
      → yes: inject a goal-anchored continuation and run(state)
      → no (:completed | :paused | :off_track): end, and say which
```

Note the shape is identical to the post-compaction continuation just shipped,
including its budget. That is not a coincidence and the two should share the
continuation-budget mechanism rather than growing a second one.

### 2.4 No unattended budget beyond iterations

`max_iterations` and `max_budget_usd` bound a *turn*. A goal loop spanning many
turns needs its own wall-clock, dollar, and turn budgets, and needs to report
what it spent when it stops. `GoalTracker`'s run cap is a proxy for this but
counts verification rounds, not work.

---

## Part 3 — Risks

**A wrong goal, pursued efficiently, is worse than no goal.** Self-authored
criteria are the model's own reading of an instruction; if the reading is wrong,
every subsequent verification confirms the wrong thing, and the skeptic panel
does not help because it is refuting the *stated* criteria. Mitigation: §2.2's
confirm step, and never letting the model rewrite the frozen brief (which
`TaskBrief`'s immutability already enforces).

**Grading its own homework.** `GoalVerifier`'s fresh-context read-only skeptics
are a real mitigation and should stay the only completion authority; a "the
model said it was done" path must not be added as a fast path.

**Unattended blast radius.** An autonomous loop that can run for hours needs the
permission story to be *stricter* than an attended one, not looser. Anything
that would prompt should stop the loop and wait, not auto-approve — the exact
opposite of what "overdrive" does for an attended session.

**Stall that looks like progress.** `GoalTracker`'s gap-fingerprint stall
detector catches repeated identical gaps. It does not catch a loop that produces
a *different* superficial gap each round while making no real progress. A
secondary signal (no file changed, no test status change over N rounds) is
needed before this runs unattended.

**Cost.** N skeptic subagents per verification round, times a reverify cadence,
times a long run. The cadence and run cap exist; the dollar budget does not.

---

## Part 4 — Prior art worth studying first

A prior study of `xai-org/grok-build` found a **10-module `/goal` subsystem**
there — goal tracking, a goal classifier, stall thresholds, reverify cadence and
their configuration resolution. OSA's `GoalTracker` and `GoalVerifier` are
already ports of two of those modules (`session/goal_tracker.rs`,
`session/goal_classifier.rs`) and cite them in their moduledocs. The remaining
eight are the natural next read, specifically for the parts OSA is missing:
where a goal is *authored*, how criteria are made checkable, and what drives
re-entry.

Read those before designing §2.2 and §2.3 from scratch.

---

## Part 5 — Ordered path

1. `/goal <text>` → `GoalTracker.start/2` + `TaskBrief.capture/3`. Lights up
   five existing subsystems; roughly a day.
2. Criteria elicitation + grounding + confirm (§2.2), writing into the brief's
   existing `acceptance_criteria` field.
3. Goal-anchored re-entry (§2.3), sharing the post-compaction continuation
   budget.
4. Cross-turn budgets and a spend report at stop (§2.4).
5. Secondary stall signal (Part 3) — required before step 3 is allowed to run
   unattended.
