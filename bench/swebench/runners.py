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
import re
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
    #: Files the grader will revert to base_commit before grading, i.e. the
    #: file list of the hidden test_patch. Used ONLY after the agent finishes,
    #: to make the recorded patch equal the graded one. Never shown to it.
    graded_away_paths: list[str] = field(default_factory=list)


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
    #: ok | empty_patch | tests_only_patch | timeout | runner_error
    #: | agent_error | skipped
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

#: `diff --git a/<path> b/<path>` -- how we recover a patch's file list.
_DIFF_PATH_RE = re.compile(r"^diff --git a/.* b/(.*)$", re.MULTILINE)


def test_patch_files(test_patch: str) -> list[str]:
    """The exact files the grader will revert, read from the instance's test_patch.

    This is the ONLY correct definition of "a file the agent cannot usefully
    edit". The grader does not guess from filenames: it runs
    `git checkout <base_commit> -- <files in test_patch>` and then applies
    test_patch. Any other file the agent touched is kept and graded.

    The previous implementation guessed from the path instead, and matched
    `"test/"` as a *substring*. That is contained in `src/_pytest/`, so every
    edit to pytest's own source was silently deleted from the submission --
    and, because the result was then an empty diff, reported as the agent
    having produced no patch. Checked against all 500 SWE-bench Verified gold
    patches, that predicate destroyed 19 of them outright: an unreachable
    ceiling of 96.2%, charged to the agent. It also matched the legitimate
    source file `django/test/client.py`.

    Deriving the list from test_patch is exact, cannot drift from the grader,
    and leaks nothing to the agent -- it is applied after the agent has
    finished, purely to make the recorded patch equal the graded one.
    """
    return sorted(set(_DIFF_PATH_RE.findall(test_patch or "")))


def git_diff(workspace: Path, strip_paths: list[str] | None = None) -> tuple[str, list[str]]:
    """Produce the model_patch for a workspace.

    Uses `git add -A` into the index so that newly created files show up, then
    `git diff --cached`. The index mutation is local to the throwaway
    workspace clone, so it does not matter that it is destructive.

    `strip_paths` should be `test_patch_files(instance["test_patch"])`: the
    files the grader reverts, and therefore the only ones worth removing.
    Passing None strips nothing, which is the safe default -- an over-eager
    strip silently deletes the agent's real work.

    Returns `(patch, dropped_paths)`. The second element matters for diagnosis:
    an agent whose only edits were to graded-away test files produces an empty
    patch, and that is a different mistake from an agent that produced nothing.
    """
    drop: list[str] = []
    subprocess.run(
        ["git", "add", "-A"], cwd=workspace, check=True, capture_output=True
    )
    if strip_paths:
        wanted = set(strip_paths)
        names = subprocess.run(
            ["git", "diff", "--cached", "--name-only"],
            cwd=workspace,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.split()
        drop[:] = [n for n in names if n in wanted]
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
    return out, drop


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


class GoldApplyRunner:
    """Upper control that goes through the REAL path, not around it.

    `GoldRunner` hands the dataset's patch straight to the grader. That proves
    the dataset, the grading invocation and the report are wired up -- but it
    never touches the workspace, never runs `git diff`, and therefore cannot
    detect a bug in patch *extraction*. One lived there undetected: the
    strip predicate substring-matched `"test/"`, which is inside
    `src/_pytest/`, and silently deleted 19 of the 500 gold patches in full
    while `GoldRunner` reported a clean 100%.

    This runner applies the gold patch to the prepared workspace with `git
    apply` and then extracts it back out exactly the way an agent's work is
    extracted. It must also score 100%; when it does not, extraction is broken
    even though `gold` looks fine. Run both.
    """

    name = "gold-apply"

    def __init__(self, dataset_by_id: dict[str, dict]):
        self._ds = dataset_by_id

    def prepare(self) -> None:  # pragma: no cover - trivial
        pass

    def run(self, task: Task) -> RunResult:
        t0 = time.monotonic()
        gold = self._ds[task.instance_id]["patch"]
        proc = subprocess.run(
            ["git", "apply", "-"],
            cwd=task.workspace,
            input=gold,
            text=True,
            capture_output=True,
        )
        if proc.returncode != 0:
            return RunResult(
                instance_id=task.instance_id, patch="", status="runner_error",
                error=f"git apply of the gold patch failed: {proc.stderr[:400]}",
                wall_clock_s=time.monotonic() - t0, model="oracle",
            )
        patch, dropped = git_diff(task.workspace, strip_paths=task.graded_away_paths)
        return RunResult(
            instance_id=task.instance_id,
            patch=patch,
            status="ok" if patch.strip() else "empty_patch",
            wall_clock_s=time.monotonic() - t0,
            model="oracle",
            tool_calls=0,
            turns=0,
            raw={"dropped_test_paths": dropped},
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
    if kind == "gold-apply":
        return GoldApplyRunner(dataset_by_id)
    if kind == "empty":
        return EmptyRunner()
    if kind == "osa":
        from osa_runner import OsaRunner  # local import: keeps controls dependency-free

        return OsaRunner(**opts)
    raise SystemExit(
        f"unknown runner: {kind!r} (want: gold | gold-apply | empty | osa)"
    )
