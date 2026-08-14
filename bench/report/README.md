# bench/report

Validation and reporting for benchmark runs. Reads the artefacts produced by
`bench/swebench` and turns them into something that can survive being argued
with.

It never writes into `bench/swebench`. Standard library only — no dependencies,
no venv.

**Scope: SWE-bench-shaped runs only.** `loader.py` requires the `instances`
schema that `bench/swebench/report.py` owns, and it refuses anything else rather
than guessing. Harbor runs (`bench/terminalbench`, `bench/headtohead`) are
task-shaped, not instance-shaped, and have their own control gate with the same
contract: **`bench/terminalbench/controls.py gate <run>`**. It plays the part
gold-apply and empty-patch play here — `oracle` must solve every task in the run
and `nop` must solve none — and it exits 1 when they do not, so a Harbor number
is no more quotable without controls than a SWE-bench one is.

## Why this exists separately

`bench/swebench` answers "did the agent solve the task". This answers "is the
resulting number worth anything, and what does it tell us to fix". Those are
different jobs, and the second one has to be able to say **no**.

Two commitments shape everything here:

1. **Refuse to mislead.** The reporter is a gate, not a formatter. If a run
   cannot support a claim, it withholds the claim rather than printing it with
   a caveat underneath. A 2/2 run does not get to print "100%".
2. **Failures are the deliverable.** The pass rate is a scalar and tells you
   nothing about what to fix. The distribution of failure causes, attributed to
   a layer, with a path to each transcript, is the actual output.

## Use

```bash
# the full report
python bench/report/cli.py summarise bench/swebench/runs/osa-smoke2

# machine readable
python bench/report/cli.py summarise <run> --json --out report.json

# failures only, with transcript paths
python bench/report/cli.py failures <run>

# everything a third party needs to re-run us
python bench/report/cli.py manifest <run> --out manifest.json

# CI gate: exit 1 if the run may not be quoted as a rate
python bench/report/cli.py gate <run>

# two runs, with a difference interval that can say "indistinguishable"
python bench/report/cli.py compare <run-a> <run-b>

# tests
python bench/report/test_report.py
```

`--confidence` (default 0.95) and `--method` (`wilson` | `clopper-pearson`)
apply to all commands. The seed is read from the run's own
`config.sampling.seed`; `--seed N` remains for declaring a draw made out of
band (an `--instances` file copied from an earlier seeded sample, say). With no
seed from either source, selection bias is reported as unquantified.

Gold and empty control runs over the *same instance set* are discovered
automatically from sibling directories under `runs/`.

## Layout

| file | role |
|---|---|
| `stats.py` | Wilson / Clopper–Pearson intervals, Newcombe two-proportion difference. Wald is implemented only as a counter-example and cannot be selected. |
| `loader.py` | Reads `results.json` (schema v1, owned by `bench/swebench/report.py`). Validates the version and refuses anything else. |
| `honesty.py` | The rules that decide what a run may claim, plus `KNOWN_HARNESS_DEFECTS`. |
| `failures.py` | Failure bucketing, layer attribution, evidence paths, diagnostic leads. |
| `manifest.py` | Reproducibility manifest, including SHA-256 of every bench source file. |
| `render.py` | Markdown output. Validity gate first, failures before cost. |
| `cli.py` | Entry point. |
| `METHODOLOGY.md` | What the numbers mean and what they cannot claim, with citations. Read this before quoting anything. |
| `NEXT_BENCHMARKS.md` | What to build next and why, ranked by diagnostic value per unit of setup cost. |

## The defect registry

`honesty.KNOWN_HARNESS_DEFECTS` encodes validity defects found by auditing the
pipeline. Every report generated while a defect is open carries it on its face,
labelled with whether it *inflates*, *deflates* or *distorts*.

`web_lookup_of_solution_not_prevented` is **conditional**: it fires unless
`honesty.airgap_status()` returns `verified`, which requires three things in
the run's own artefacts — a probe attestation in `config.airgap`, zero
network-tool calls, and an explicit (possibly empty) `residual_shell_egress`
scan. A missing key never reads as a pass. Two further states are their own
BLOCKs: `airgap_requested_but_not_verified` (a control that was believed rather
than measured, which is worse than no control) and `airgap_verified_but_breached`.

A subset run still is not quotable as a rate, because
`subset_not_a_dataset_score` blocks independently of any of this. See
`METHODOLOGY.md` §4 for the full audit.

Removing an entry from that list is a claim that the defect is fixed, and
should be made in the same commit that fixes it.

## Schema coupling

`loader.SUPPORTED_SCHEMA` pins the `results.json` schema version. If
`bench/swebench` bumps `SCHEMA_VERSION`, this reporter fails loudly rather than
misreading fields. Widen it only after re-reading their `report.py`.
