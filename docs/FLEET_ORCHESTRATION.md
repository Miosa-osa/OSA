# OSA Fleet Orchestration — replicate the disjoint-workstream flow

Goal: OSA should natively run the multi-agent orchestration pattern demonstrated when
building the FleetView edge-case wave — decompose a large task into DISJOINT file-owned
workstreams, fan out isolated agents, collect structured reports, run ONE authoritative
gate, and commit when green. Not naive fan-out — collision-free, verifiable, self-committing.

This is a `Fleet.fan_out` upgrade + an orchestration skill, gated behind `:ultra`.

---

## The flow, step → OSA capability → gap

| # | Step (what the orchestrator did) | OSA has | GAP to build |
|---|---|---|---|
| 1 | **Recon first** — scope before launching | agent can read/grep freely | prompt/skill: "scout the work-list before the fan-out" |
| 2 | **Decompose into disjoint FILE-OWNED workstreams** | — | the orchestration SKILL: teach the coordinator to partition a task by non-overlapping file sets (+ sequence shared-file "chokepoints") |
| 3 | **Strict per-agent scope** ("own only X; ignore unowned errors") | delegate passes a task string | pass an explicit `owns: [files]` + inject the "ignore sibling compile noise" convention into each node's prompt |
| 4 | **Launch the wave, collision-free** | `fan_out` queue-drain (16), `spawn_fleet_node` | **worktree-per-node isolation** (robust collision-freedom) — reuse `workspace/fast_worktree` + RunStore `worktree_snapshot_ref`; opt-in `:isolation` on fan_out |
| 5 | **Structured reports back** | `fan_out` returns results list | each node returns a structured `%{files_changed, gate, stubbed, summary}` (schema-shaped return), not free text |
| 6 | **Authoritative combined gate + commit when green** | orchestrator has a synthesis finalizer (`run_parallel` wave+synthesis) | a **finalizer step**: merge disjoint worktree diffs → run a configured gate cmd (mix/cargo) → commit (attribution-clean) if green, else report failures. New `Fleet.Finalizer`. |
| 7 | **Sequence shared-file work; commit protectively** | subtree tracking | the skill emits a sequencing plan (parallel set + sequenced chokepoints) + checkpoint commits between phases |

---

## Build plan (all gated behind `:ultra` — this IS a dynamic workflow)

### O1 — worktree-per-node isolation  (OWNS: `agent/fleet.ex` spawn path + `workspace/fast_worktree` glue)
- Add opt `:isolation` to `spawn_fleet_node`/`fan_out`. When set, each node runs in its own
  fast-worktree (OSA already has `workspace/fast_worktree/{populate,metadata}.ex` + RunStore
  `worktree_snapshot_ref`). Node edits land in its worktree, never the main tree.
- BLOCKED until W1 (edge-case wave) frees `fleet.ex`.

### O2 — structured node reports  (OWNS: `agent/fleet.ex` return shape + a report struct)
- Nodes return `%{node_id, files_changed, gate: :pass|:fail|:skipped, stubbed, summary}`.
  fan_out aggregates them for the finalizer. (Mirrors how the orchestrator subagents already
  return summaries; add the structured fields.)

### O3 — the finalizer  (OWNS: new `agent/fleet/finalizer.ex`)
- After all nodes complete: (a) merge each worktree's disjoint diff into a target branch
  (disjoint files → clean apply; on overlap → flag conflict, don't clobber); (b) run a
  configured gate command list (e.g. `mix compile`, `mix test <targets>`, `cargo build`);
  (c) if green, commit attribution-clean (NO Claude footer — repo has no committer script,
  use git directly); else return the failing gate output for the orchestrator to fix.
- Never auto-push (outward step stays operator-gated).

### O4 — the orchestration skill/prompt  (OWNS: new skill file + coordinator prompt addendum)
- Teach the coordinator to: recon → partition into disjoint file-owned workstreams →
  identify shared-file chokepoints to SEQUENCE → emit per-node `owns:` scope + the
  "ignore unowned-file errors; only fix your files" convention → run the finalizer →
  checkpoint-commit between phases. This is the *intelligence* that made the flow work; it
  rides on `coordinator_mode` + the `fleet` tool.

### Guardrails (carry over from the real flow)
- Disjoint ownership is the invariant; overlap → sequence, never parallel-edit.
- Orchestrator's combined gate is the ONLY source of "green" — node self-gates are advisory.
- Commit-when-green + protective checkpoints; never push without explicit consent.
- All caps still apply (16 concurrent, 1000 total, depth cap, `:ultra` gate).

Build order: O1–O4 after the current edge-case wave lands (O1/O2 touch `fleet.ex` which W1
owns now). O3/O4 are new files (buildable sooner) but wire into fan_out, so land them
together with O1/O2 for a coherent, tested orchestration capability. Ship behind `:ultra`.
