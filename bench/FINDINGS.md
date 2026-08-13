# Benchmark findings

The working queue for the loop: **run → find → fix → run again**.

A finding lands here when a benchmark exposes something, and leaves when it is
fixed *and* a later run confirms the fix. Nothing is deleted for being
inconvenient — a finding that turned out to be wrong gets struck through with
the reason, because "we checked and it was fine" and "we never checked" produce
identical numbers right up until they don't.

## How to use this

```bash
bench/run-all.sh smoke        # prove the pipeline before trusting anything
bench/run-all.sh swebench     # then a real arm
bench/report/cli.py gate --run <dir>
```

The gate decides whether a number is quotable. It currently refuses every run we
have, on sample size. That is correct. Do not route around it.

---

## Open — OSA defects

### 1. `shell_execute` does not always honour the session's `working_dir`
**Found:** SWE-bench Pro, 4 of 12 instances. `pwd` returned the backend's boot
directory rather than the workspace. None of 253 shell commands used absolute
workspace paths, and the `git log` calls therefore read OSA's own history rather
than the task repo's.
**Status:** mechanism NOT established. A hypothesis around `Workspace.Cwd.get/0`
and the Loop process dictionary fits, but the isolating probe hit an unrelated
`:ets.lookup(:osa_permission_responses, ...)` failure on a missing table.
**Impact:** can only depress a score. Reproducing it is the next step; it is not
yet a claim.

### 2. `context_pressure` has no traced delivery path
**Found:** the stranded-events audit
(`test/optimal_system_agent/events/stranded_events_test.exs`).
It is emitted only via `Bus.emit`, is not in the forwarder allowlist, and has no
direct broadcast anywhere in `lib/` — yet the TUI meter works and its numbers
match the backend's own arithmetic exactly (370.5k/1M reads as 37.8%). Those
facts cannot both be true through the path traced.
**Impact:** either the meter has a path the audit does not know about, or it runs
on locally-derived numbers that happen to look right. The second would be a real
bug wearing a correct-looking face.

### 3. The stall detector fires on healthy work
**Found:** Terminal-Bench, 224 times across 6 tasks — including 4 that PASSED,
81 on `path-tracing` alone.
**Status:** currently escalate-only, so harmless today. Re-arming it to halt
would kill good runs.

### 4. `mix osa.run --format stream-json` may not stream
**Found:** the first benchmark agent observed one JSON line for a whole
multi-tool session.
**Status:** UNCONFIRMED. The Bus handler is registered correctly, the emit fires
with the right shape, and dispatch reads handlers from ETS at call time — the
mechanism looks sound, and the symptom may be a model returning one chunk. Not
changed, because changing working code to chase an unreproduced report is how
you introduce a real bug.

### 5. `osa:tui:output` is subscribed and never published
`agent_routes.ex:26` subscribes to a topic nothing in the tree writes to. Dead
wiring; harmless so far.

---

## Open — harness limits (ours)

### 6. The airgap does not stop toolchain egress
`web_search` / `web_fetch` are denied and verified by a live differential probe,
but three SWE-bench Pro instances show `go: downloading github.com/...`. Real
outbound network from `shell_execute`, invisible to `residual_shell_egress`
because it greps for `urllib`/`requests` and `go build` contains neither.
It cannot retrieve the fix, but "no egress occurred" would be false.

### 7. Shell egress is a filter, not a boundary
This host refuses unprivileged network namespaces — `unshare --net` fails on
`kernel.apparmor_restrict_unprivileged_userns=1`, `bwrap --unshare-net` is not
setuid. Tried, not assumed. Residual egress is detected post-hoc rather than
prevented.

### 8. Every number is a single run
9 of 40 instances flipped between two runs of the same set. Until there are
repeats, a two- or three-point difference means nothing — including any
improvement we might want to claim from a fix.

### 9. No full-dataset run
40 of 500 for Verified, 12 of 731 for Pro. This is the only remaining BLOCK on
both, and closing it needs ~2 TB.

---

## Open — upstream, not ours

### 10. Every published SWE-bench Pro image ships the answer
`/app/.git` contains the fix commit; `git show <fix_commit>` returns the gold
patch verbatim with the network off, and the fix SHA is the tail of the
instance_id. No network control touches it. Upstream issue #93 / PR #94 propose
this exact fix; unmerged, images frozen since 2025-10-01.

**Any Pro result produced without stripping it — including published leaderboard
numbers — is an upper bound of unknown tightness.** We strip it, and `prepare()`
refuses a workspace where the fix is still reachable.

### 11. The official grader is non-deterministic on network-dependent tests
`psf__requests-1921` failed and then passed on an identical gold re-run.

### 12. Upstream's own audit finds 109 of 728 Pro tasks under-specified
They grade behaviour not pinned by anything the solver is given. That ceilings
every Pro score, ours included.

---

## Closed — fixed and confirmed by a later run

- **A quarter of failures were OSA's own fault.** The airgapped Verified run and
  the Pro run now both report **zero harness faults**. Previously: prompt-injection
  refusals on ordinary bug reports, workspace permission errors, and patches
  destroyed by a bad strip predicate.
- **`model: nil`** silently disabled compaction on 37 of 40 sessions and shrank a
  1M window to 32k. Cost also read $0.00 against 59.9M tokens; it now reads real
  ($46.66 on the airgapped run).
- **The injection guard refused pasted logs** — 15 of 500 instances, and far
  wider outside benchmarks.
- **19 of 500 instances were unwinnable** by a strip predicate matching `"test/"`
  as a substring of `src/_pytest/`. Ceiling was 96.2%; now 100.0%.
- **F2P test names leaked** into `run_tests.sh` in the agent's own working
  directory.
- **Web lookup was unprevented** — 6 instances used `web_fetch` and resolved 6/6.

---

## The live hypothesis

Both benchmarks now fail almost entirely on **incomplete fixes**: a patch is
written, tests are run, the target test still fails, and the agent submits
anyway rather than iterating.

Verification is not the missing piece — 16 of 17 failed instances ran tests, as
did 22 of 23 resolved ones. The question is what happens *after* verification
fails.

`VerificationGate` exists for exactly this and re-prompts up to
`@max_reprompts = 2`. Whether it fires was **unmeasurable** until now: its event
was emitted and forwarded nowhere. That is fixed, so the next run can answer it.

Recovery-Bench is the sharpest instrument for the same question — its `regressed`
cell *is* recovery failure, with the model held fixed.
