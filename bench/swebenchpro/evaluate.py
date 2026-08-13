"""Thin wrapper around the *official* SWE-bench Pro evaluation harness.

We deliberately do not reimplement grading. Correctness is decided by
`harness/swe_bench_pro_eval.py` -- an unmodified clone of
github.com/scaleapi/SWE-bench_Pro-os, pinned by commit -- which is the same
code behind the public leaderboard. For each instance it starts a container
from the instance's prebuilt image, writes our patch plus the instance's own
`run_script.sh` and `parser.py` into `/workspace`, and runs:

    cd /app
    git reset --hard <base_commit>
    git checkout <base_commit>
    git apply -v /workspace/patch.diff
    git checkout <fix_commit> -- <test files>     # the graded-away paths
    bash /workspace/run_script.sh <selected_test_files_to_run> >stdout 2>stderr
    python /workspace/parser.py stdout stderr output.json

and then scores `resolved = (fail_to_pass | pass_to_pass) ⊆ {t : t.status == PASSED}`.

If you change anything in this file, you are changing how the run is *invoked*,
never how it is *scored*. The one derived number below (`_tests_status`) is a
per-test breakdown for the failure taxonomy; the pass/fail verdict itself is
read back out of the harness's own `eval_results.json` and never recomputed.

## Why there is an adapter at the bottom

`bench/swebench/report.py` and `bench/swebench/diagnose.py` already implement
the results schema, the failure buckets and the harness-vs-model fault split,
and `bench/report/` validates that schema. Rather than fork them, this module
writes the Pro harness's per-instance outcome into the *directory layout those
modules already read* (`logs/run_evaluation/<run_id>/<model>/<iid>/report.json`,
plus a `run_instance.log` carrying the patch-apply marker they grep for). The
reporting stack then works on Pro runs unmodified, which is the only way the
two benchmarks stay comparable in shape.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import dataset as ds

#: Markers `git apply -v` writes to stderr when it refuses the patch. The
#: entryscript has no `set -e`, so a failed apply does NOT stop the run: the
#: tests then execute against an unpatched tree and the instance scores as an
#: ordinary miss. Distinguishing the two is the difference between "the model
#: wrote a wrong fix" and "the model wrote a malformed diff", so it is detected
#: explicitly rather than inferred from the score.
_APPLY_FAIL_MARKERS = (
    "error: patch failed:",
    "error: patch does not apply",
    "does not exist in index",
    "error: cannot apply binary patch",
    "fatal: unrecognized input",
    "fatal: corrupt patch",
)


def write_patches(path: Path, results, prefix: str) -> int:
    """Emit the JSON list the official harness expects.

    Instances with no patch are still emitted (as an empty patch) so that
    "submitted" and "attempted" line up with the instance list, and so that the
    empty control produces real per-instance artefacts rather than absences.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    docs = [
        {"instance_id": r.instance_id, "patch": r.patch, "prefix": prefix}
        for r in results
    ]
    path.write_text(json.dumps(docs, indent=1))
    return len(docs)


def harness_commit(harness_dir: Path) -> str:
    p = subprocess.run(
        ["git", "-C", str(harness_dir), "rev-parse", "HEAD"],
        capture_output=True, text=True,
    )
    return p.stdout.strip() or "unknown"


def run_evaluation(
    *,
    python: Path,
    harness_dir: Path,
    raw_sample_path: Path,
    patches_path: Path,
    output_dir: Path,
    num_workers: int = 4,
    dockerhub_user: str = ds.DOCKERHUB_USER,
    block_network: bool = True,
    redo: bool = False,
) -> Path:
    """Invoke the official harness; return its `eval_results.json`.

    `cwd` must be the harness checkout: `swe_bench_pro_eval.py` reads
    `dockerfiles/base_dockerfile/<iid>/Dockerfile` and
    `dockerfiles/instance_dockerfile/<iid>/Dockerfile` by relative path, and a
    missing Dockerfile raises inside a worker thread where it is reported as
    "returned None" -- i.e. as an instance the model failed. Running from the
    wrong directory would therefore score 0% and look like a bad agent.
    """
    output_dir.mkdir(parents=True, exist_ok=True)
    cmd = [
        str(python), "swe_bench_pro_eval.py",
        f"--raw_sample_path={raw_sample_path.resolve()}",
        f"--patch_path={patches_path.resolve()}",
        f"--output_dir={output_dir.resolve()}",
        "--scripts_dir=run_scripts",
        f"--num_workers={num_workers}",
        f"--dockerhub_username={dockerhub_user}",
        "--use_local_docker",
    ]
    if block_network:
        # Grading must not reach the network either: several of these suites
        # would otherwise fetch modules at test time, which makes the grade
        # depend on the internet rather than on the patch.
        cmd.append("--block_network")
    if redo:
        cmd.append("--redo")
    print("+ " + " ".join(cmd), file=sys.stderr)
    subprocess.run(cmd, check=True, cwd=harness_dir)

    results = output_dir / "eval_results.json"
    if not results.exists():
        raise SystemExit(f"evaluation produced no eval_results.json under {output_dir}")
    return results


# ---------------------------------------------------------------------------
# Reading the harness back out
# ---------------------------------------------------------------------------


def _read_json(p: Path):
    try:
        return json.loads(p.read_text())
    except (OSError, json.JSONDecodeError):
        return None


def _read_text(p: Path) -> str:
    try:
        return p.read_text(errors="replace")
    except OSError:
        return ""


def _tests_status(inst: dict, output: dict | None) -> dict:
    """Per-test breakdown, in the shape `bench/swebench/report.py` already reads.

    Derived, not authoritative: the resolved/unresolved verdict comes from the
    harness's own `eval_results.json`. This exists so the failure taxonomy can
    say *which* half broke -- a patch that leaves fail_to_pass red is an
    incomplete fix, a patch that turns pass_to_pass red is a regression, and
    those are different bug reports.

    Note the official predicate is `⊆ PASSED`, so a SKIPPED or absent test
    counts as not-passed. We mirror that exactly: `failure` is everything not
    observed PASSED, and `_absent` records the sharper case where the test did
    not appear in the parser's output at all (usually a collection error or a
    suite that never ran).
    """
    tests = (output or {}).get("tests") or []
    passed = {t.get("name") for t in tests if t.get("status") == "PASSED"}
    seen = {t.get("name") for t in tests}
    out = {}
    for key, names in (
        ("FAIL_TO_PASS", ds.fail_to_pass(inst)),
        ("PASS_TO_PASS", ds.pass_to_pass(inst)),
    ):
        out[key] = {
            "success": [n for n in names if n in passed],
            "failure": [n for n in names if n not in passed],
            "_absent": [n for n in names if n not in seen],
        }
    return out


def collect(
    *,
    eval_output_dir: Path,
    prefix: str,
    instances: list[dict],
    submitted_patch_bytes: dict[str, int],
) -> tuple[dict[str, str], dict[str, dict]]:
    """Flatten the harness's artefacts into (outcomes, per-instance details).

    Outcome vocabulary, matching `bench/swebench/evaluate.per_instance_outcomes`:

      resolved     -- the harness's own verdict was True
      unresolved   -- ran to completion, verdict False
      empty_patch  -- we submitted nothing (never scored as an agent's wrong fix)
      eval_error   -- the harness produced no parsed output for this instance
      incomplete   -- the harness never returned a verdict at all

    The `eval_error` split matters and is easy to get wrong. Upstream's
    `main()` writes `eval_results[iid] = False` both when the patch was wrong
    and when the container died before writing `output.json`. Folding the
    second case into the score would charge infrastructure failures to the
    agent, so we re-separate them here on the presence of `output.json` -- and
    `bench/report/loader.py` then excludes them from the rate rather than
    counting them as misses.
    """
    verdicts = _read_json(eval_output_dir / "eval_results.json") or {}
    outcomes: dict[str, str] = {}
    details: dict[str, dict] = {}

    for inst in instances:
        iid = inst["instance_id"]
        d = eval_output_dir / iid
        output = _read_json(d / f"{prefix}_output.json")
        stderr = _read_text(d / f"{prefix}_stderr.log")
        stdout = _read_text(d / f"{prefix}_stdout.log")
        applied = not any(m in stderr for m in _APPLY_FAIL_MARKERS)
        empty = submitted_patch_bytes.get(iid, 0) == 0

        if iid not in verdicts:
            outcome = "incomplete"
        elif empty:
            outcome = "empty_patch"
        elif verdicts[iid] is True:
            outcome = "resolved"
        elif output is None:
            outcome = "eval_error"
        else:
            outcome = "unresolved"
        outcomes[iid] = outcome

        details[iid] = {
            "resolved": bool(verdicts.get(iid)),
            "patch_exists": not empty,
            "patch_successfully_applied": applied,
            "tests_status": _tests_status(inst, output),
            "tests_parsed": len((output or {}).get("tests") or []),
            "harness_output_present": output is not None,
            "stdout_bytes": len(stdout),
            "stderr_bytes": len(stderr),
        }
    return outcomes, details


def write_swebench_layout(
    *,
    report_dir: Path,
    run_id: str,
    model: str,
    details: dict[str, dict],
) -> None:
    """Re-emit Pro's results where `bench/swebench/report.py` expects to find them.

    `report._instance_detail` reads
    `<report_dir>/logs/run_evaluation/<run_id>/<model>/<iid>/report.json`, and
    `diagnose.patch_apply_failed` greps `run_instance.log` in the same
    directory for `APPLY_PATCH_FAIL`. Writing both lets the entire reporting
    and failure-attribution stack run on Pro unchanged -- no fork, no second
    copy of the schema to drift.
    """
    base = report_dir / "logs" / "run_evaluation" / run_id / model.replace("/", "__")
    for iid, detail in details.items():
        d = base / iid
        d.mkdir(parents=True, exist_ok=True)
        (d / "report.json").write_text(json.dumps({iid: detail}, indent=1))
        if not detail.get("patch_successfully_applied", True):
            (d / "run_instance.log").write_text(
                "APPLY_PATCH_FAIL: `git apply -v` rejected the submitted patch "
                "inside the official SWE-bench Pro entryscript; the graded tests "
                "then ran against an unpatched tree.\n"
            )


def summary(outcomes: dict[str, str]) -> dict:
    counts: dict[str, int] = {}
    for v in outcomes.values():
        counts[v] = counts.get(v, 0) + 1
    return dict(sorted(counts.items(), key=lambda kv: -kv[1]))
