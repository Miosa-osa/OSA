# OSA Agentic Fleet + Long-Running Durability: Unified Plan

Goal: turn OSA into a recursive fleet of full-power agents that can grind on a task
for hours or days, survive restarts, resume cleanly, and not drift or falsely
declare done, with a live tree view the operator can switch through.

This plan synthesizes three audits (crash-recovery, anti-drift-at-scale, core-runtime
resilience) and the background-agents/fleet design study.

---

## What is already solid (do NOT rebuild)

- Durable substance recovers: conversation, goal (progress_ledger.md, re-injected each
  turn), plan (plan.md), code state (fs_checkpoint shadow git), and completed tool steps
  (durable_log.jsonl replay). Primary stores use atomic temp+rename and corruption-tolerant
  JSONL (torn-tail heal + .corrupt quarantine).
- Crash checkpoint per ReAct iteration; durable step log on every tool completion.
- RunStore tracks the parent_session_id chain (the tree backbone) and rehydrates at boot;
  subtree-cancel already walks it. task_resume re-dispatches a saved subagent from ETF.
- Evidence-based done-checking exists: GoalVerifier (N read-only skeptics, majority-refute,
  fail-closed) + VerificationGate (grounded pass referencing the changed file).
- Shared scratchpad, coordinator mode, delegate workers, agents panel, /bg /fg /agents.

## The gaps (ranked), from the audits

### Durability (crash-recovery audit)
- D1 CRITICAL: resume is LAZY. A crashed 6h autonomous task does NOT auto-continue at boot;
  it only rehydrates when a session is next touched. Nothing drives it forward.
- D2 CRITICAL: cost/budget is never persisted. session_cost_usd is absent from the
  checkpoint (checkpoint.ex checkpoint_state/1), so max_budget_usd resets to $0 on any crash.
- D3 MAJOR: live subagents die with the daemon; a recursive fleet loses all descendants on
  crash and needs explicit task_resume per node.
- D4 MINOR: progress_ledger.ex and plan_store.ex use plain non-atomic writes (torn on crash).
- D5 MINOR: iteration/turn_count reset to 0 after a clean turn boundary (checkpoint cleared).

### Anti-drift over long runs (anti-drift audit)
- A1 CRITICAL: done/drift verification is turn-granular. A single hours-long autonomous run
  is ONE turn, so GoalVerifier runs at most ~3 panels total, and GoalTracker (advances per
  user MESSAGE) barely ticks. Long single-turn runs are the weakest case.
- A2 MAJOR: no slow-drift detector. Nothing measures semantic distance from the goal over
  time; detectors are exact-repeat / non-progress only.
- A3 MAJOR: stall detection is off in overdrive/autonomous (escalate-only, never kills), and
  any read/grep/search in the last-12 window foreclosures "stalled?".
- A4 MINOR: no oscillation (A-B-A-B) detection.

### Core runtime (resilience sweep) - findings folded in when that report lands.

### Fleet (design study) - full diff table + depth-cap design folded in when it lands.

---

## The fleet vision

A recursive tree of agents. Any node can spawn either:
- a FULL OSA agent (full tools + MCP + memory + permissions, its own Loop + session), for
  open-ended autonomous work that may itself fan out; or
- a LIGHTWEIGHT worker (existing restricted delegate config), for a narrow scoped task.

The operator (and any agent) can: spawn on demand, see how many are running across the tree
with each node's flavor + task + elapsed, switch/attach to any node (/fg), and cancel/pause a
whole subtree. Depth-capped and total-agent-capped to prevent runaway forking.

---

## Phased build

### Phase 0 (safe, isolated, START NOW - no collision with the runtime sweep)
- D4: atomic writes for progress_ledger.ex + plan_store.ex (temp+rename), so a crash mid-write
  never leaves a torn goal/plan.
- D2 (checkpoint half): persist session_cost_usd (and the other spend counters) in
  checkpoint_state/1 so the value survives a crash.

### Phase 1 (after the runtime sweep frees loop.ex)
- D2 (restore half): restore session_cost_usd in loop.ex init so max_budget_usd is honored
  across a crash.
- A1: make done/drift verification iteration-granular in autonomous single-turn runs (tick the
  goal machinery per ReAct iteration, not only per user message; run a bounded verifier cadence
  during a long turn), so a day-long run is actually checked, not checked ~3 times.
- Full-power background agent spawn: a background agent = a first-class OSA Loop on its own
  session (reuse the main start path, full tools/MCP/memory/permissions), visible in the tree,
  switchable via /fg. NOT the restricted delegate path.

### Phase 2
- D1: boot-time auto-continue for crashed AUTONOMOUS runs (opt-in, budget-capped): at
  application start, scan RunStore/sessions for runs that were mid-flight in an autonomous
  posture and were not cleanly finished, and re-drive them (respecting the now-persisted
  budget + a resume cap), instead of leaving them dead.
- Recursion: allow a full-OSA background agent to itself spawn (delegation_depth > 0), with a
  configurable max-depth and total-agent cap (spawn-bomb protection), and the flavor choice
  per spawn.
- D3: recursive subagent recovery - on resume, walk the parent chain and re-dispatch live
  descendants (extend task_resume to a subtree resume).

### Phase 3
- A2/A4: a slow-drift + oscillation signal (progress-over-window; alternating-pattern) feeding
  the doom-loop, tuned for 1000+ iteration runs.
- The tree dashboard: hierarchy view (parent -> children -> grandchildren) with flavor + task +
  status + elapsed per node and totals; subtree switch/cancel/pause; budget rollup across the
  tree.

Each phase ships behind the existing feature discipline (test-first, full gate) and its own
release. Phase 0 is startable immediately; the rest sequence behind the runtime sweep + the
fleet design.
