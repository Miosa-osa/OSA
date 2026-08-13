"""The reproducibility manifest: everything a third party needs to re-run us.

A benchmark result is a claim about a procedure. If the procedure is not
pinned, the claim is not checkable. This module records the pins.

Two things here are load-bearing and often left out elsewhere:

  * The harness scripts are hashed. bench/swebench is under active
    development; a results.json from last week was produced by different code
    than the one in the tree today. The hashes make that detectable instead of
    invisible.

  * The defects listed in honesty.KNOWN_HARNESS_DEFECTS are stamped into the
    manifest. A reproducer needs to know that the run they are reproducing had
    the FAIL_TO_PASS names visible to the agent, because reproducing the
    number without reproducing the leak will not work.
"""

from __future__ import annotations

import hashlib
import json
import os
import platform
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING

import honesty

if TYPE_CHECKING:
    from loader import Run

HERE = Path(__file__).resolve().parent
BENCH_DIR = HERE.parent
REPO_ROOT = BENCH_DIR.parent

#: Files whose content changes the meaning of a result.
PINNED_SOURCES = [
    "swebench/run_bench.py",
    "swebench/runners.py",
    "swebench/osa_runner.py",
    "swebench/workspace.py",
    "swebench/evaluate.py",
    "swebench/report.py",
]

#: Environment variables that change behaviour and must be recorded. Values are
#: recorded only when they cannot carry a credential.
SAFE_ENV = ["OSA_HOME", "OSA_HTTP_PORT", "OSA_BENCH_URL", "SWEBENCH_DOCKER_FORK"]
SECRET_ENV = ["OSA_BENCH_TOKEN", "HF_TOKEN", "ANTHROPIC_API_KEY", "OPENAI_API_KEY"]


def _run(cmd: list[str], cwd: Path | None = None) -> str | None:
    try:
        r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=20)
        return r.stdout.strip() or None if r.returncode == 0 else None
    except (OSError, subprocess.SubprocessError):
        return None


def _sha256(p: Path) -> str | None:
    try:
        return hashlib.sha256(p.read_bytes()).hexdigest()
    except OSError:
        return None


def git_state(root: Path) -> dict:
    dirty = _run(["git", "status", "--porcelain"], cwd=root)
    return {
        "commit": _run(["git", "rev-parse", "HEAD"], cwd=root),
        "branch": _run(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=root),
        "describe": _run(["git", "describe", "--tags", "--always", "--dirty"], cwd=root),
        "working_tree_clean": (dirty == "" or dirty is None),
        "dirty_files": [l[3:] for l in (dirty or "").splitlines()][:50],
    }


def source_pins() -> dict:
    out = {}
    for rel in PINNED_SOURCES:
        p = BENCH_DIR / rel
        out[rel] = {"sha256": _sha256(p), "present": p.exists()}
    return out


def docker_images(instance_ids: list[str], namespace: str = "swebench") -> dict:
    """Resolve the local image digest for each instance image, if present.

    The image is the environment. Two runs against different image builds are
    not the same experiment, and the tag is always ':latest', so the tag alone
    pins nothing.
    """
    out: dict[str, dict] = {}
    for iid in instance_ids[:200]:
        key = f"sweb.eval.x86_64.{iid.lower()}:latest"
        if namespace and namespace != "none":
            key = f"{namespace}/{key}".replace("__", "_1776_")
        digest = _run(
            ["docker", "image", "inspect", "--format", "{{index .RepoDigests 0}}", key]
        )
        image_id = _run(["docker", "image", "inspect", "--format", "{{.Id}}", key])
        out[iid] = {"image": key, "repo_digest": digest, "image_id": image_id}
    return out


@dataclass
class Manifest:
    run_id: str
    data: dict = field(default_factory=dict)

    def to_json(self) -> dict:
        return self.data

    def write(self, path: Path) -> Path:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(self.data, indent=2, sort_keys=False) + "\n")
        return path


def _reproduce_command(run: "Run") -> list[str]:
    c = run.config
    cmd = [
        "python bench/swebench/run_bench.py",
        f"--runner {c.get('runner')}",
        f"--run-id {c.get('run_id')}-repro",
        f"--dataset {c.get('dataset_name')}",
        f"--split {c.get('split')}",
        f"--agent-timeout {c.get('agent_timeout_s')}",
        f"--max-turns {c.get('max_turns')}",
        f"--namespace {c.get('namespace')}",
    ]
    if c.get("runner") == "osa":
        cmd.append(f"--osa-mode {c.get('transport')}")
        if run.model and not run.model.startswith("MIXED:"):
            cmd.append(f"--model {run.model}")
    if not c.get("test_bridge", True):
        cmd.append("--no-test-bridge")
    ids = c.get("instance_ids") or []
    if ids and c.get("dataset_size") != len(ids):
        cmd.append("--instance-ids " + " ".join(ids))
    return cmd


def build(run: "Run", *, with_docker: bool = True) -> Manifest:
    c = run.config
    verdict = honesty.evaluate(run)
    defects = [
        {
            "code": d.code,
            "direction": d.direction,
            "severity": d.severity,
            "message": d.message,
        }
        for d in honesty.KNOWN_HARNESS_DEFECTS
        if d.applies_when is None or d.applies_when(run)
    ]

    data = {
        "manifest_version": 1,
        "generated_by": "bench/report",
        "run_id": run.run_id,
        "results_path": str(run.path),
        # -- what was measured ------------------------------------------
        "measurement": {
            "benchmark": c.get("dataset_name"),
            "split": c.get("split"),
            "dataset_size": c.get("dataset_size"),
            "instances_attempted": run.n,
            "instances_resolved": run.k,
            "is_full_dataset_run": run.is_full_dataset,
            "instance_ids": run.instance_ids,
            "instance_id_sha256": hashlib.sha256(
                "\n".join(sorted(run.instance_ids)).encode()
            ).hexdigest(),
            "claim_label": honesty.claim_label(run, verdict),
        },
        # -- the system under test --------------------------------------
        "system_under_test": {
            "runner": c.get("runner"),
            "transport": c.get("transport"),
            "model": run.model,
            "provider": next(
                (
                    i.raw.get("provider")
                    for i in run.instances
                    if isinstance(i.raw, dict) and i.raw.get("provider")
                ),
                None,
            ),
            "osa_git": git_state(REPO_ROOT),
            "permission_mode": "overdrive (approvals disabled)",
            "network_access_during_inference": "unrestricted (agent runs on host)",
            "web_tools_available": ["web_search", "web_fetch", "download"],
        },
        # -- the limits that define the result --------------------------
        "budgets": {
            "agent_timeout_s": c.get("agent_timeout_s"),
            "max_turns": c.get("max_turns"),
            "max_budget_usd": c.get("max_budget_usd"),
            "test_bridge_enabled": c.get("test_bridge"),
            "attempts_per_instance": 1,
            "selection_method": "best-of-1 (no reranking, no test-time compute)",
        },
        # -- how it was graded ------------------------------------------
        "grading": {
            "graded_by": "swebench.harness.run_evaluation (official package)",
            "swebench_version": c.get("swebench_version"),
            "namespace": c.get("namespace"),
            "reimplemented_locally": False,
            "note": (
                "bench/swebench/evaluate.py shells out to the official harness; "
                "it does not reimplement pass/fail. Grading resets test files "
                "to base_commit and applies the dataset test_patch, so agent "
                "edits to tests cannot affect the outcome."
            ),
        },
        # -- environment -------------------------------------------------
        "environment": {
            "platform": platform.platform(),
            "python": platform.python_version(),
            "reporter_python": sys.version.split()[0],
            "cpu_count": os.cpu_count(),
            "host_recorded_at_run_time": c.get("host"),
            "env": {k: os.environ.get(k) for k in SAFE_ENV if os.environ.get(k)},
            "secrets_present": {k: (k in os.environ) for k in SECRET_ENV},
        },
        # -- exact code ---------------------------------------------------
        "code_pins": {
            "bench_sources_sha256": source_pins(),
            "note": (
                "If any of these hashes differ from the tree you are "
                "reproducing on, you are running different code and should "
                "expect a different number."
            ),
        },
        "timing": {
            "started_at": c.get("started_at"),
            "finished_at": c.get("finished_at"),
            "wall_clock_total_s": run.aggregate.get("wall_clock_total_s"),
        },
        # -- caveats that must travel with the number ---------------------
        "known_defects_at_run_time": defects,
        "validity": verdict.to_json(),
        "reproduce": {
            "prerequisites": [
                "docker, with ~5 GB of disk per instance image",
                "bench/swebench/setup.sh to build the .venv and install swebench",
                "an OSA backend on a non-default port, e.g. "
                "OSA_HTTP_PORT=19801 mix osa.serve",
            ],
            "command": _reproduce_command(run),
            "expected": (
                "The same instance set, the same grader, and the same code "
                "pins. The resolved COUNT will still vary run to run: agent "
                "runs are stochastic and this manifest describes one sample."
            ),
        },
    }

    if with_docker:
        data["environment"]["instance_images"] = docker_images(
            run.instance_ids, c.get("namespace") or "swebench"
        )

    return Manifest(run_id=run.run_id, data=data)
