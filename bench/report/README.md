# bench/report

Validation and reporting for benchmark runs. Reads the artefacts produced by
`bench/swebench` and turns them into something that can survive being argued
with.

It never writes into `bench/swebench`. Standard library only — no dependencies,
no venv.

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
apply to all commands. Pass `--seed N` to declare that the instance set was
drawn as a seeded random sample; without it, selection bias is reported as
unquantified.

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

**Two BLOCK-level defects are currently open, so no run is quotable as a rate
at all.** That is intended: both are violations of the official SWE-bench
submission checklist, and a number produced under them is not measuring what it
claims to. See `METHODOLOGY.md` §4 for the full audit.

Removing an entry from that list is a claim that the defect is fixed, and
should be made in the same commit that fixes it.

## Schema coupling

`loader.SUPPORTED_SCHEMA` pins the `results.json` schema version. If
`bench/swebench` bumps `SCHEMA_VERSION`, this reporter fails loudly rather than
misreading fields. Widen it only after re-reading their `report.py`.
