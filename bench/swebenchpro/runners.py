"""Task runners for SWE-bench Pro.

The `Task` / `RunResult` / `Runner` contracts and the patch-extraction helper
are imported from `bench/swebench/runners.py` rather than restated. That is
deliberate: the two benchmarks must agree on what "the patch the agent
produced" means, and a second copy of `git_diff` would eventually disagree with
the first one. This module adds only what Pro needs on top:

  * a prompt that carries Pro's two extra context fields, and a switch to
    withhold them (`ContextMode`), because that ablation is the reason this
    benchmark is interesting;
  * gold / gold-apply / empty controls bound to Pro's column names;
  * an OSA runner that is `bench/swebench/osa_runner.OsaRunner` with the prompt
    replaced -- all of the transport, telemetry, spend accounting and signal
    mining is shared, unchanged.
"""

from __future__ import annotations

import subprocess
import time

import dataset as ds
import shared

# Imported, never redefined. See module docstring, and `shared` for why this
# cannot be a plain `from runners import ...` -- that name resolves to this
# very module.
Task = shared.sb_runners.Task
RunResult = shared.sb_runners.RunResult
Runner = shared.sb_runners.Runner
git_diff = shared.sb_runners.git_diff

__all__ = [
    "Task", "RunResult", "Runner", "git_diff",
    "build_runner", "PROMPT", "CONTEXT_MODES",
]


# ---------------------------------------------------------------------------
# Prompt
# ---------------------------------------------------------------------------

# Kept as plain as the Verified prompt. SWE-bench measures the harness+model;
# a heavily tuned prompt measures the prompt instead, and anything clever here
# should be moved into OSA itself where it benefits real users too.
PROMPT = """\
You are working in a checkout of the `{repo}` repository at commit {base_commit}.
The working directory is already set to the repository root. This is a \
{language} project.

Resolve the following issue reported against this repository:

<issue>
{problem_statement}
</issue>
{spec}
Requirements:
- Edit the source files in this repository so the issue is fixed.
- Do NOT modify or add any test files. The graders use their own tests, and any
  changes you make to test files will be discarded.
- Do not create new git commits, branches, or stashes. Leave your work as
  uncommitted changes in the working tree.
- Fix the root cause. This issue is likely to require changes across several
  files; do not stop at the first symptom.
{test_hint}
When you are done, briefly state which files you changed and why.
"""

# Pro's `requirements` and `interface` columns. Every one of the 731 public
# instances has both. `requirements` is a prose specification of the intended
# behaviour; `interface` names the new functions/methods the fix is expected to
# introduce, with signatures and file paths.
#
# Including them is the dataset's intended framing -- upstream's own scaffold
# puts them in the prompt, and the published leaderboard numbers are with them.
# Withholding them is the single most informative ablation this benchmark
# offers, which is why it is a first-class run mode rather than a code edit.
SPEC_BLOCK = """
The fix is expected to satisfy the following specification:

<requirements>
{requirements}
</requirements>

and to provide the following interface:

<interface>
{interface}
</interface>
"""

TEST_HINT = """\
- You can run this instance's own test files against your edits with
  `./run_tests.sh <test file paths>` from the repository root. It is the same
  runner the graders use. Use it to check your work.

"""

#: full    -- problem_statement + requirements + interface  (the leaderboard setting)
#: no-spec -- problem_statement only
#:
#: Never mix the two inside one run: the resulting rate is a weighted average of
#: two different measurements and means nothing. run_bench.py records the mode
#: in config.json and the reporter prints it next to the score.
CONTEXT_MODES = ("full", "no-spec")


def build_prompt(inst: dict, *, context_mode: str, test_hint: bool) -> str:
    if context_mode not in CONTEXT_MODES:
        raise ValueError(f"context_mode must be one of {CONTEXT_MODES}, got {context_mode!r}")
    spec = ""
    if context_mode == "full":
        req = (inst.get("requirements") or "").strip()
        iface = (inst.get("interface") or "").strip()
        if req or iface:
            spec = SPEC_BLOCK.format(requirements=req or "(none given)",
                                     interface=iface or "(none given)")
    return PROMPT.format(
        repo=inst["repo"],
        base_commit=inst["base_commit"],
        language=inst.get("repo_language", "software"),
        problem_statement=(inst.get("problem_statement") or "").strip(),
        spec=spec,
        test_hint=TEST_HINT if test_hint else "",
    )


# ---------------------------------------------------------------------------
# Controls
# ---------------------------------------------------------------------------


class GoldRunner:
    """Upper control: emits the dataset's own gold patch, bypassing everything.

    Proves the dataset, the grading invocation and the report are wired up. It
    does NOT prove patch extraction, because it never touches the workspace --
    use `gold-apply` for that, and run both.
    """

    name = "gold"

    def __init__(self, dataset_by_id: dict[str, dict]):
        self._ds = dataset_by_id

    def prepare(self) -> None:
        pass

    def run(self, task: Task) -> RunResult:
        t0 = time.monotonic()
        patch = self._ds[task.instance_id]["patch"]
        return RunResult(
            instance_id=task.instance_id, patch=patch,
            status="ok" if patch.strip() else "empty_patch",
            wall_clock_s=time.monotonic() - t0, model="oracle",
            tool_calls=0, turns=0,
        )

    def close(self) -> None:
        pass


class GoldApplyRunner:
    """Upper control that goes through the REAL path, not around it.

    Applies the gold patch into the prepared workspace with `git apply`, then
    extracts it back out exactly the way an agent's work is extracted. It must
    also score ~100%; when it does not, extraction is broken even though `gold`
    looks fine. On SWE-bench Verified precisely this divergence caught a strip
    predicate that was deleting 19 of 500 gold patches while `gold` reported a
    clean 100% -- see `bench/swebench/runners.test_patch_files`.

    Pro raises the stakes: the gold patches are a median of 4 files and 7.8k
    characters, so there is far more surface for extraction to lose something.
    """

    name = "gold-apply"

    def __init__(self, dataset_by_id: dict[str, dict]):
        self._ds = dataset_by_id

    def prepare(self) -> None:
        pass

    def run(self, task: Task) -> RunResult:
        t0 = time.monotonic()
        gold = self._ds[task.instance_id]["patch"]
        proc = subprocess.run(
            ["git", "apply", "-"], cwd=task.workspace, input=gold,
            text=True, capture_output=True,
        )
        if proc.returncode != 0:
            return RunResult(
                instance_id=task.instance_id, patch="", status="runner_error",
                error=f"git apply of the gold patch failed: {proc.stderr[:400]}",
                wall_clock_s=time.monotonic() - t0, model="oracle",
            )
        patch, dropped = git_diff(task.workspace, strip_paths=task.graded_away_paths)
        return RunResult(
            instance_id=task.instance_id, patch=patch,
            status="ok" if patch.strip() else "empty_patch",
            wall_clock_s=time.monotonic() - t0, model="oracle",
            tool_calls=0, turns=0, raw={"dropped_test_paths": dropped},
        )

    def close(self) -> None:
        pass


class EmptyRunner:
    """Lower control: never edits anything. Must score exactly 0%.

    Above zero means the fail_to_pass selection or the eval invocation is wrong
    -- typically that the graded tests already pass at base_commit, which would
    make the instance unscoreable rather than easy.
    """

    name = "empty"

    def prepare(self) -> None:
        pass

    def run(self, task: Task) -> RunResult:
        return RunResult(
            instance_id=task.instance_id, patch="", status="empty_patch",
            wall_clock_s=0.0, model="none", tool_calls=0, turns=0,
        )

    def close(self) -> None:
        pass


# ---------------------------------------------------------------------------
# OSA
# ---------------------------------------------------------------------------


def _osa_runner_class():
    """Import lazily: the controls must stay dependency-free (no `requests`)."""
    OsaRunner = shared.osa_runner_class()

    class ProOsaRunner(OsaRunner):
        """`bench/swebench`'s OSA runner with Pro's prompt.

        Everything that makes that runner worth reusing -- the HTTP/SSE
        transport, the spend sidecar cross-check, the transcript capture, the
        stall/truncation/compaction signal mining that produces the
        harness-vs-model split -- is inherited untouched. Only `_prompt`
        changes, because only the prompt is benchmark-specific.
        """

        def __init__(self, *, dataset_by_id: dict[str, dict], context_mode: str, **kw):
            super().__init__(**kw)
            self._ds = dataset_by_id
            self._context_mode = context_mode

        def _prompt(self, task: Task) -> str:
            return build_prompt(
                self._ds[task.instance_id],
                context_mode=self._context_mode,
                test_hint=bool(self.with_test_bridge and task.container),
            )

    return ProOsaRunner


def build_runner(kind: str, *, dataset_by_id: dict[str, dict], opts: dict) -> Runner:
    if kind == "gold":
        return GoldRunner(dataset_by_id)
    if kind == "gold-apply":
        return GoldApplyRunner(dataset_by_id)
    if kind == "empty":
        return EmptyRunner()
    if kind == "osa":
        cls = _osa_runner_class()
        opts = dict(opts)
        return cls(
            dataset_by_id=dataset_by_id,
            context_mode=opts.pop("context_mode", "full"),
            **opts,
        )
    raise SystemExit(
        f"unknown runner: {kind!r} (want: gold | gold-apply | empty | osa)"
    )


def graded_away_paths(inst: dict) -> list[str]:
    """Re-exported so run_bench reads it from one place. See dataset.py."""
    return ds.graded_away_paths(inst)
