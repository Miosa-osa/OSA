"""Task-runner interface for the OSA benchmark harness.

A *runner* is anything that can be handed a prepared SWE-bench workspace and a
problem statement, and produce a unified-diff patch. The evaluation half of the
pipeline (bench/swebench/evaluate.py) does not care which runner produced the
patch, which is the point: it keeps the harness honest, because the same scoring
code grades OSA, the gold patch and the empty control.

Implement `Runner.run()` to plug a new agent in.
"""

from __future__ import annotations

import dataclasses
import json
import os
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional, Protocol


# --------------------------------------------------------------------------
# Data contracts
# --------------------------------------------------------------------------


@dataclass
class Task:
    """One SWE-bench instance, already materialised on disk."""

    instance_id: str
    repo: str  # e.g. "django/django"
    base_commit: str
    problem_statement: str
    version: str
    #: Host directory containing a git checkout of `repo` at `base_commit`.
    #: The agent is expected to edit files here.
    workspace: Path
    #: Docker container holding the *installed* environment for this instance
    #: (repo at /testbed, deps installed). May be None if the workspace was
    #: prepared without a live container.
    container: Optional[str] = None
    #: Hard wall-clock budget for the agent, in seconds.
    timeout_s: int = 1800


@dataclass
class RunResult:
    """Everything we record about one agent attempt at one task.

    Fields that a runner genuinely cannot determine must be left as None rather
    than defaulted to 0 -- "unknown" and "zero" mean very different things when
    you are reporting tokens-per-solved-task.
    """

    instance_id: str
    #: Unified diff the agent produced. "" means it changed nothing.
    patch: str = ""
    #: ok | empty_patch | timeout | runner_error | agent_error | skipped
    status: str = "ok"
    error: Optional[str] = None

    wall_clock_s: float = 0.0

    tokens_in: Optional[int] = None
    tokens_out: Optional[int] = None
    tokens_cache_read: Optional[int] = None
    tokens_cache_write: Optional[int] = None
    cost_usd: Optional[float] = None
    tool_calls: Optional[int] = None
    turns: Optional[int] = None

    model: Optional[str] = None
    session_id: Optional[str] = None
    #: Runner-specific extras, kept out of the top-level schema on purpose.
    raw: dict[str, Any] = field(default_factory=dict)

    def to_json(self) -> dict[str, Any]:
        return dataclasses.asdict(self) | {"patch_bytes": len(self.patch)}


class Runner(Protocol):
    """The interface every agent adapter implements."""

    name: str

    def prepare(self) -> None:
        """Called once before any task. Boot daemons, check auth, etc."""

    def run(self, task: Task) -> RunResult:
        """Attempt one task. Must not raise; encode failure in RunResult."""

    def close(self) -> None:
        """Called once after all tasks."""


# --------------------------------------------------------------------------
# Shared helpers
# --------------------------------------------------------------------------

#: Files an agent patch must never touch. SWE-bench's own eval script reverts
#: test files to the base commit before applying test_patch, so edits here are
#: silently discarded by the grader -- we strip them so the recorded patch
#: matches what is actually graded.
TEST_PATH_MARKERS = ("tests/", "test/", "testing/")


def _is_test_path(path: str) -> bool:
    base = os.path.basename(path)
    if base.startswith("test_") or base.endswith("_test.py") or base == "conftest.py":
        return True
    return any(m in path for m in TEST_PATH_MARKERS)


def git_diff(workspace: Path, exclude_tests: bool = True) -> str:
    """Produce the model_patch for a workspace.

    Uses `git add -A` into the index so that newly created files show up, then
    `git diff --cached`. The index mutation is local to the throwaway
    workspace clone, so it does not matter that it is destructive.
    """
    subprocess.run(
        ["git", "add", "-A"], cwd=workspace, check=True, capture_output=True
    )
    if exclude_tests:
        names = subprocess.run(
            ["git", "diff", "--cached", "--name-only"],
            cwd=workspace,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.split()
        drop = [n for n in names if _is_test_path(n)]
        if drop:
            subprocess.run(
                ["git", "restore", "--staged", "--worktree", "--", *drop],
                cwd=workspace,
                capture_output=True,
            )
    out = subprocess.run(
        ["git", "diff", "--cached", "--no-color", "--binary"],
        cwd=workspace,
        check=True,
        capture_output=True,
        text=True,
        errors="replace",
    ).stdout
    return out


# --------------------------------------------------------------------------
# Control runners -- these exist to validate the pipeline itself
# --------------------------------------------------------------------------


class GoldRunner:
    """Upper control: emits the dataset's own gold patch.

    A correctly wired pipeline scores ~100% with this runner. If it does not,
    the bug is in the harness, not in the agent. Always run this first on a new
    machine.
    """

    name = "gold"

    def __init__(self, dataset_by_id: dict[str, dict]):
        self._ds = dataset_by_id

    def prepare(self) -> None:  # pragma: no cover - trivial
        pass

    def run(self, task: Task) -> RunResult:
        t0 = time.monotonic()
        patch = self._ds[task.instance_id]["patch"]
        return RunResult(
            instance_id=task.instance_id,
            patch=patch,
            status="ok" if patch.strip() else "empty_patch",
            wall_clock_s=time.monotonic() - t0,
            model="oracle",
            tool_calls=0,
            turns=0,
        )

    def close(self) -> None:  # pragma: no cover - trivial
        pass


class EmptyRunner:
    """Lower control: never edits anything.

    A correctly wired pipeline scores exactly 0% with this runner. If it scores
    above zero, the FAIL_TO_PASS selection or the eval invocation is wrong.
    """

    name = "empty"

    def prepare(self) -> None:  # pragma: no cover - trivial
        pass

    def run(self, task: Task) -> RunResult:
        return RunResult(
            instance_id=task.instance_id,
            patch="",
            status="empty_patch",
            wall_clock_s=0.0,
            model="none",
            tool_calls=0,
            turns=0,
        )

    def close(self) -> None:  # pragma: no cover - trivial
        pass


# --------------------------------------------------------------------------
# Registry
# --------------------------------------------------------------------------


def build_runner(kind: str, *, dataset_by_id: dict[str, dict], opts: dict) -> Runner:
    if kind == "gold":
        return GoldRunner(dataset_by_id)
    if kind == "empty":
        return EmptyRunner()
    if kind == "osa":
        from osa_runner import OsaRunner  # local import: keeps controls dependency-free

        return OsaRunner(**opts)
    raise SystemExit(f"unknown runner: {kind!r} (want: gold | empty | osa)")
