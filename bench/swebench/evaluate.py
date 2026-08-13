"""Thin wrapper around the *official* SWE-bench evaluation harness.

We deliberately do not reimplement grading. Correctness is decided by
`swebench.harness.run_evaluation`, the same code the public leaderboard uses:
it starts a fresh container per instance, applies our patch, resets test files
to the base commit, applies the hidden test_patch, runs FAIL_TO_PASS and
PASS_TO_PASS, and requires every F2P to flip and every P2P to hold.

If you change anything in this file, you are changing how the run is *invoked*,
never how it is *scored*.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path


def write_predictions(path: Path, results, model_name: str) -> int:
    """Emit the JSONL format the official harness expects.

    Instances with no patch are still emitted (as an empty model_patch) so that
    "submitted" and "attempted" line up with the instance list.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    n = 0
    with path.open("w") as fh:
        for r in results:
            fh.write(
                json.dumps(
                    {
                        "instance_id": r.instance_id,
                        "model_name_or_path": model_name,
                        "model_patch": r.patch,
                    }
                )
                + "\n"
            )
            n += 1
    return n


def run_evaluation(
    *,
    python: Path,
    dataset_name: str,
    split: str,
    predictions_path: Path,
    run_id: str,
    instance_ids: list[str],
    report_dir: Path,
    max_workers: int = 4,
    timeout: int = 1800,
    namespace: str = "swebench",
    cache_level: str = "env",
) -> Path:
    """Invoke the harness; return the path to its report.json."""
    report_dir.mkdir(parents=True, exist_ok=True)
    cmd = [
        str(python), "-m", "swebench.harness.run_evaluation",
        "--dataset_name", dataset_name,
        "--split", split,
        "--predictions_path", str(predictions_path.resolve()),
        "--run_id", run_id,
        "--max_workers", str(max_workers),
        "--timeout", str(timeout),
        "--namespace", namespace,
        "--cache_level", cache_level,
        "--report_dir", str(report_dir.resolve()),
        "--instance_ids", *instance_ids,
    ]
    print("+ " + " ".join(cmd), file=sys.stderr)
    subprocess.run(cmd, check=True, cwd=report_dir)

    reports = sorted(report_dir.glob("*.json"))
    if not reports:
        raise SystemExit(f"evaluation produced no report under {report_dir}")
    # The harness names it "<model_name>.<run_id>.json".
    for r in reports:
        if run_id in r.name:
            return r
    return reports[0]


def load_report(path: Path) -> dict:
    return json.loads(path.read_text())


def per_instance_outcomes(report: dict) -> dict[str, str]:
    """Flatten the harness's aggregate report into instance_id -> outcome.

    Outcome vocabulary (this is our taxonomy, layered on the harness's lists):
      resolved            -- all F2P flipped, all P2P held
      unresolved          -- ran to completion, but did not satisfy the criteria
      empty_patch         -- we submitted nothing
      eval_error          -- the harness could not evaluate the instance
      incomplete          -- the harness never finished this instance
    """
    out: dict[str, str] = {}
    for iid in report.get("resolved_ids", []):
        out[iid] = "resolved"
    for iid in report.get("unresolved_ids", []):
        out.setdefault(iid, "unresolved")
    for iid in report.get("empty_patch_ids", []):
        out[iid] = "empty_patch"
    for iid in report.get("error_ids", []):
        out[iid] = "eval_error"
    for iid in report.get("incomplete_ids", []):
        out.setdefault(iid, "incomplete")
    for iid in report.get("unstopped_containers", []) or []:
        out.setdefault(iid, "incomplete")
    return out
