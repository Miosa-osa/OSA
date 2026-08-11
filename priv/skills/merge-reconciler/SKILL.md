---
name: merge-reconciler
description: Recover the work a fleet wave dropped when two parallel nodes edited the same file — read each claimant's version out of its worktree, reconcile them into one correct file, and re-run the authoritative gate instead of re-running the wave.
triggers:
  - merge conflict
  - conflicted files
  - fleet conflict
  - conflict_briefs
  - reconcile parallel edits
  - wave conflict recovery
  - overlapping workstreams
priority: 1
tools:
  - file_read
  - file_write
  - shell_execute
  - fleet
---

## Instructions

You are reconciling a **fleet wave that partially voided itself**.

`Agent.Fleet.Finalizer` guarantees it never clobbers: when two nodes changed the
same file, that file is declared a conflict and **skipped**. Nothing is
corrupted — but nothing is merged either, so every claimant's edits to that file
are sitting unmerged in their worktrees while the branch has the *original*.
Left alone, that silently discards real work, and the usual reaction (re-running
the whole wave) discards it a second time and costs the same again.

Your job: turn each conflicted file into one correct reconciled file, then prove
it with the same gate the finalizer would have run.

### When to use this

Use it when a `finalize/3` result has a non-empty `conflicts` list. The same
result carries `conflict_briefs`, which is your entire input:

```elixir
%{
  conflicts: ["lib/app/auth.ex"],
  conflict_briefs: [
    %{
      file: "lib/app/auth.ex",
      claimants: [
        %{node_id: "n1", worktree_ref: "wave/n1", gate: :pass, errored: false, summary: "..."},
        %{node_id: "n2", worktree_ref: "wave/n2", gate: :pass, errored: false, summary: "..."}
      ]
    }
  ]
}
```

Do **not** use it for ordinary git merge conflicts between branches, and do not
use it to "fix" a wave that failed its gate — that is a different problem.

### The invariant (never violate)

**The branch copy is the base, and every claimant's version is a candidate — never
a winner.** You do not pick one node's file and move on; that is exactly the data
loss you were called to undo. If you genuinely cannot combine two versions, you
stop and report, you do not choose.

### Procedure

1. **Read the base.** `git show HEAD:<file>` — the version on the branch, which
   is what every claimant started from.

2. **Read each claimant's version.** For each entry in `claimants` with a
   non-nil `worktree_ref`:

   ```
   git show <worktree_ref>:<file>
   ```

   A claimant with `worktree_ref: nil` edited the working tree directly — its
   version is whatever is on disk right now, so read the file itself, and read
   it *first*, before you overwrite anything.

3. **Triage the overlap before reconciling.** Diff each claimant against the
   base (`git diff HEAD:<file> <ref>:<file>`) and classify:

   - **Spurious** — one claimant is `errored: true`, or its diff against base is
     empty. It did not really change the file. Drop it from consideration; if
     only one real claimant remains, this is not a conflict at all and step 4 is
     just "take that version".
   - **Disjoint** — the claimants changed different regions (different
     functions, different clauses). This is the common case and it is
     mechanically combinable.
   - **Genuinely overlapping** — both rewrote the same lines with different
     intent. This is the case that needs judgement.

4. **Reconcile into one file.** Start from the base and apply each claimant's
   intent, using their `summary` to understand what they were *trying* to do —
   the summary is why the finalizer carries it. Preserve both sets of behaviour.
   Never emit conflict markers (`<<<<<<<`) into the file; you are producing a
   finished file, not a merge to be resolved later.

   Prefer the claimant whose `gate: :pass` when a tie must be broken on style,
   but never on *behaviour* — behaviour from both sides must survive.

5. **Write it and stage only it.**

   ```
   git add -- <file>
   ```

   Scoped adds only. Never `git add -A` — the finalizer deliberately avoids it
   and so do you.

6. **Re-run the authoritative gate.** The same `gate_cmds` the wave used (for
   this repo, typically `mix compile` then the targeted `mix test`). Node
   self-gates are advisory; this combined run is the only source of "green".

   If the gate fails, fix the reconciliation — do not weaken the gate and do not
   delete the failing test.

7. **Commit only when green**, with a message that names the recovery and the
   nodes whose work it restored. Attribution stays exactly what you write: no
   `Co-Authored-By` footer, no AI footer, ever. Do not push.

8. **Report** per file: which claimants were real, what each contributed, how
   you combined them, and the gate result.

### When to stop and ask

Stop and hand back to the operator, with the briefs and your analysis, when:

- two claimants made **contradictory** changes (one deletes what the other
  extends) and the correct outcome depends on intent you were not told;
- reconciling would require changing a file outside `conflicts`;
- the gate cannot be made green without altering a claimant's stated goal.

Reporting an unreconcilable conflict is a success. Guessing is not.

### Preventing the next one

A conflict means the decomposition was wrong, not that the nodes misbehaved.
When you report, name the file and say which two workstreams should have been
**sequenced** rather than parallelized — that is the fix in
`fleet-orchestration`, whose disjoint-ownership invariant this file violated.
