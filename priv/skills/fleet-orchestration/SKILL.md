---
name: fleet-orchestration
description: Decompose a large task into DISJOINT file-owned workstreams, fan out isolated full-power peers, collect structured reports, run ONE authoritative gate, and commit when green — the collision-free, self-verifying multi-agent flow. Ultra-gated.
triggers:
  - fleet orchestration
  - disjoint workstreams
  - fan out
  - parallel refactor
  - multi-agent wave
  - orchestrate a wave
priority: 1
tools:
  - fleet
  - delegate
  - list_agents
  - file_read
  - shell_execute
---

## Instructions

You are the coordinator of a fleet of full-power peer agents. This skill is the
DECOMPOSITION INTELLIGENCE that makes a parallel wave collision-free and
verifiable: you partition a large task into NON-OVERLAPPING file-owned
workstreams, fan them out in isolation, collect structured reports, and run ONE
authoritative gate before committing. This is not naive fan-out — it is a
disjoint, self-verifying, self-committing flow.

Use this when a task is large enough to split across peers AND the files
involved can be partitioned into disjoint sets. It is **ultra-gated**: the
`fleet` workflow action only runs at the `:ultra` effort tier. If you are below
ultra, raise effort first or do the work solo.

### The invariant (never violate)

**Disjoint ownership.** Every spawned node owns a set of files that NO other
concurrent node touches. Two nodes editing the same file in parallel is a
collision, and collisions corrupt the wave. When files must be shared, you do
NOT parallelize them — you SEQUENCE them (see step 2 and step 7).

### The flow

#### 1. Recon first — scout before you fan out

Never partition a task you have not scoped. Before launching anything:

- Read and grep the work-list — discover the ACTUAL files, modules, and
  functions involved, not the ones you assume.
- Delegate a READ-ONLY `explorer` for breadth when the surface is unfamiliar:
  `delegate(task: "Scan <paths> — report every file touched by <change>, plus shared/contract files", role: "explorer")`.
- Produce a concrete file inventory. The partition in step 2 is only as good as
  this recon.

#### 2. Decompose into DISJOINT file-owned workstreams

From the file inventory, partition the task so each workstream owns a
**non-overlapping** set of files:

- Group files by natural seam (module, layer, feature, test target).
- Identify **shared-file chokepoints** — files that more than one workstream
  would need to edit (shared types, registries, a common router, an index).
- Chokepoints are NOT parallelized. Emit a sequencing plan:
  - a **parallel set** — workstreams with fully disjoint files, run at once;
  - **sequenced chokepoints** — the shared-file edits, run one at a time
    (before, between, or after the parallel set), each its own phase.
- If you cannot make the sets disjoint, the task is not fan-out-shaped —
  sequence it or do it solo instead.

State the plan briefly before launching: "3 disjoint workstreams (A: fleet.ex,
B: finalizer.ex, C: skill+docs) + 1 sequenced chokepoint (registry.ex, after)."

#### 3. Per-node scope — tell each node exactly what it OWNS

Every spawned node is told its exact ownership and the ignore-noise convention.
Put this verbatim into each node's task string:

> YOU OWN ONLY these files: `<explicit list>`. Edit ONLY your files. If
> compile/test shows an error in a file you do NOT own, that is a sibling's
> in-progress edit — IGNORE it, do not fix it, only fix your own files. Return a
> structured report (see below). Do NOT commit. Do NOT push.

Give each node the full context it needs (recon findings, conventions,
acceptance criteria) — nodes do not share your context window.

#### 4. Isolation — run the wave collision-free

Fan out with worktree-per-node isolation so nodes physically cannot collide:

```
fleet(action: "workflow", task: "<umbrella description>", items: [<one task string per node>], isolation: "worktree")
```

Each node's edits land in its own fast-worktree, never the main tree. The
bounded-concurrency queue-drain runs up to 16 at once. Disjoint ownership plus
worktree isolation is belt-and-suspenders collision-freedom.

#### 5. Structured reports back

Each node returns a structured report, not free text:

```
%{node_id, files_changed: [...], gate: :pass | :fail | :skipped, stubbed: [...], summary: "..."}
```

- `files_changed` — exactly what the node edited (verify it is within its owned
  set; anything outside is a scope breach to flag).
- `gate` — the node's OWN gate result. This is **advisory only**.
- `stubbed` — anything left as a placeholder for a later phase.
- `summary` — what changed and why.

#### 6. Finalize — merge, authoritative gate, commit when green

Call the finalizer step. It:

1. **Merges** each worktree's disjoint diff into the target branch. Disjoint
   files apply cleanly; on any overlap it FLAGS a conflict and does NOT clobber.
2. **Runs the authoritative combined gate** — the configured gate command list
   (e.g. `mix compile`, `mix test <targets>`, `cargo build`). **This is the ONLY
   source of "green."** Node self-gates (step 5) never count as green.
3. **Commits when green** — attribution-clean (NO AI/Claude footer), a clear
   message. If the gate fails, it returns the failing output for you to dispatch
   a fix (re-scope the failing files to a node) — it does NOT commit red.
4. **Never pushes.** Pushing is an outward step that requires explicit operator
   consent, every time.

#### 7. Protective checkpoints — commit each green phase, sequence chokepoints

- After each coherent phase goes green, COMMIT it before starting the next. A
  committed green phase is a rollback point; a wave that dies mid-flight then
  costs you one phase, not everything.
- Run the sequenced chokepoints (step 2) as their own phases between parallel
  sets — never fold a shared-file edit into the parallel wave.
- Between phases, re-run recon if the tree changed in ways that shift ownership.

### Guardrails (carry these on every wave)

- **Ultra-gated.** The `fleet` workflow action only runs at `:ultra`. Below it,
  raise effort or go solo.
- **Disjoint ownership is the invariant.** Overlap → sequence, never
  parallel-edit.
- **The coordinator's combined gate is the ONLY source of green.** Node
  self-gates are advisory.
- **Caps always apply:** 16 concurrent, 1000 total nodes, the depth cap. Do not
  attempt to exceed them.
- **Commit-when-green + protective checkpoints.** Never commit red.
- **Attribution-clean commits.** No AI/Claude co-author or footer, ever.
- **Never push without explicit operator consent.** The finalizer never
  auto-pushes; neither do you.

## Examples

**Coordinator:** "Add edge-case handling across the FleetView module — it spans
`fleet.ex`, `finalizer.ex`, the finalizer test, and a shared registry."

**Expected behavior:** Recon the four files and grep for who imports the
registry. Partition: workstream A owns `fleet.ex`, B owns `finalizer.ex` + its
test (disjoint). The registry is a chokepoint (both would touch it) → sequence
it as a final phase. Fan out A and B with `isolation: "worktree"`, each told its
owned files and the ignore-unowned-errors convention. Collect structured
reports, run the finalizer (merge → `mix compile` + targeted `mix test` → commit
green, attribution-clean). Then run the registry chokepoint as its own phase and
commit again. Never push.

---

**Coordinator:** "Refactor these 12 handler files to the new error pattern."

**Expected behavior:** 12 handlers with no shared file → 12 disjoint
workstreams (or batched into a few nodes of N files each), fan out at up to 16
concurrent with worktree isolation. Each node owns its handful of files. One
authoritative gate over all diffs, one green commit.

---

**Coordinator:** "Split this change: three modules plus a shared types file they
all edit."

**Expected behavior:** The three modules are disjoint → parallel set. The shared
types file is a chokepoint edited by all three → it CANNOT be parallelized.
Sequence it FIRST as its own phase (commit green), then fan out the three
modules against the now-stable types. Two phases, two protective commits.

---

**Coordinator (below ultra):** "Fan out this refactor across the fleet."

**Expected behavior:** The `fleet` workflow action is ultra-gated and will
return a "raise effort to ultra" message. Either raise effort to `:ultra` and
proceed with the flow above, or handle the change solo if it is small enough.
