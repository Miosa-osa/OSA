"""The Harbor datasets we can actually run, and what each one is worth.

WHY THIS FILE EXISTS
--------------------
Until now `run_bench.py` hard-coded one dataset: a local clone of
Terminal-Bench **2.0**. That is a superseded task set. Terminal-Bench 2.1 is a
corrected iteration of the *same* 89 tasks (26 of them modified per the
upstream README; 27 differ byte-for-byte on disk, see `DIFF_TB20_TB21`), and
Terminal-Bench 3 is a different, smaller, harder set that is where the live
leaderboard moved. A failure recorded against 2.0 on one of those 27 tasks may
be an artefact of a broken task rather than a defect in OSA, and there is no way
to tell after the fact. So the version has to be a first-class, recorded input.

2.0 IS DELIBERATELY KEPT. We have historical runs against it and the only way to
say *what changed* is to be able to re-run the old set. It is marked
`status="superseded"` and the reporter stamps that onto every artefact.

RESOLUTION: HUB, NOT THE LEGACY REGISTRY
----------------------------------------
Harbor has two dataset resolution paths and only one of them is current:

  * the **legacy registry** — `registry.json` in the harbor repo, mirrored into
    a public Supabase table. `harbor download name@version`. This is what
    `--dataset terminal-bench@2.0` uses. It contains 80 datasets and its
    newest Terminal-Bench entry is **2.0**. It has not been updated with 2.1,
    3, or Harbor-Index, and `harbor dataset list` will not show them.
  * the **Harbor Hub** — `harbor download org/name[@ref]`, backed by
    hub.harborframework.com. This is where the current datasets live.

Verified on 2026-08-14 against the installed Harbor 0.21.0 (the newest release;
published 2026-08-10), so this is not a "upgrade Harbor" problem: the legacy
registry is simply stale, and the Hub path is the one to use. Every entry below
with a `hub_id` was resolved and downloaded successfully; the sizes recorded
here are counted from what actually landed on disk, not from a web page.

LOCAL COPY VS. LIVE RESOLUTION
------------------------------
Each dataset is downloaded once into `tasks/<local_dir>/` and run with
`harbor run -p tasks/<dir>`. That is not just a cache: it is the only way to
filter on `task.toml` metadata (difficulty), and it pins the task content for
the run so a mid-flight upstream edit cannot silently change the denominator.
Re-download with `datasets.py sync <key>`.
"""

from __future__ import annotations

import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
TASKS_ROOT = HERE / "tasks"


@dataclass(frozen=True)
class Dataset:
    """One runnable Harbor dataset."""

    key: str
    #: What the reporter stamps on the artefact. Never inferred.
    label: str
    #: `org/name` on the Harbor Hub, for `harbor download` / `harbor run -d`.
    #: None means the dataset is only available as a local clone.
    hub_id: str | None
    #: Directory under `tasks/`.
    local_dir: str
    #: Task count, COUNTED FROM DISK after download — not quoted from a page.
    size: int
    #: "current"  — a live leaderboard exists for this exact set.
    #: "superseded" — kept for historical comparison only.
    status: str
    #: Where the comparable public numbers live, if anywhere.
    leaderboard: str | None = None
    #: Anything a reader must know before quoting a number from this set.
    notes: tuple[str, ...] = field(default_factory=tuple)

    @property
    def path(self) -> Path:
        return TASKS_ROOT / self.local_dir

    @property
    def present(self) -> bool:
        return self.path.is_dir() and any(self.path.glob("*/task.toml"))

    def task_names(self) -> list[str]:
        return sorted(p.parent.name for p in self.path.glob("*/task.toml"))

    def on_disk_size(self) -> int:
        return len(self.task_names())


#: The 27 tasks whose non-dotfile content differs between the local 2.0 clone
#: and the 2.1 download. Upstream's README says "26 tasks were modified"; the
#: byte comparison finds 27. Either way, **any OSA result on one of these from a
#: 2.0 run is suspect** and should be re-run on 2.1 before being cited.
#: Computed by `datasets.py diff`, not typed by hand.
DIFF_TB20_TB21: tuple[str, ...] = (
    "adaptive-rejection-sampler",
    "build-pmars",
    "build-pov-ray",
    "caffe-cifar-10",
    "compile-compcert",
    "configure-git-webserver",
    "extract-moves-from-video",
    "filter-js-from-html",
    "financial-document-processor",
    "fix-git",
    "hf-model-inference",
    "install-windows-3.11",
    "make-doom-for-mips",
    "mcmc-sampling-stan",
    "mteb-leaderboard",
    "mteb-retrieve",
    "overfull-hbox",
    "polyglot-c-py",
    "polyglot-rust-c",
    "protein-assembly",
    "pytorch-model-recovery",
    "query-optimize",
    "rstan-to-pystan",
    "sam-cell-seg",
    "torch-pipeline-parallelism",
    "torch-tensor-parallelism",
    "train-fasttext",
)


DATASETS: dict[str, Dataset] = {
    "tb2.0": Dataset(
        key="tb2.0",
        label="Terminal-Bench 2.0",
        # Resolvable through the LEGACY registry as `terminal-bench@2.0`.
        #
        # The Hub DOES carry this line, contrary to the previous note here, and
        # it is the canonical id the upstream docs use:
        #   harbor run -d terminal-bench/terminal-bench-2 -a oracle
        # Downloaded and compared 2026-08-15. `terminal-bench/terminal-bench-2`
        # is semantically 2.0, not 2.1 -- against our local copies it differs on
        # 1 instruction / 2 test dirs / 3 solutions, versus 11 / 9 / 11 for our
        # 2.1 copy. So the Hub id is the 2.0 line and the leaderboard repo named
        # `terminal-bench-2-leaderboard` is its board.
        #
        # Left as None deliberately rather than pointed at the Hub, because our
        # local copy is NOT byte-identical to it and switching the id silently
        # would change what historical runs are compared against.
        #
        # ## The drift, re-measured 2026-08-15 against a fresh
        # ## `harbor download terminal-bench/terminal-bench-2`
        #
        # The two are different SNAPSHOTS OF THE SAME LINE, not two versions.
        # Our copy comes from the legacy registry's git pin `69671fb`
        # (2025-10-31); the Hub package was cut earlier, and the git repo went
        # on receiving 2.1-era fixes afterwards. So our "2.0" already carries
        # part of 2.1. Content:
        #
        #   install-windows-3.11    -- named `install-windows-3-11` upstream
        #   overfull-hbox           -- solution differs; ours == our 2.1 copy
        #   rstan-to-pystan         -- solution differs. HUB PINS the apt
        #                              versions of build-essential/gfortran/
        #                              libatlas; OURS HAS THEM UNPINNED. (An
        #                              earlier note here and
        #                              `docs/research/harbor-framework.md` §4
        #                              both had this backwards and concluded
        #                              that switching to the Hub would RECOVER
        #                              this task. It would not: the Hub copy is
        #                              the pinned one, and our unpinned copy
        #                              still fails its oracle anyway, on
        #                              `ModuleNotFoundError: pkg_resources` --
        #                              nothing to do with apt at all.)
        #
        # ## And the part that changes a score
        #
        # THREE tasks differ in resources or agent budget, and our copy is the
        # more generous one in every case:
        #
        #   crack-7z-hash        hub 900s / 2048MB   vs  ours 1800s / 4096MB
        #   filter-js-from-html  hub      / 2048MB   vs  ours      / 4096MB
        #   gpt2-codegolf        hub      / 4096MB   vs  ours      / 8192MB
        #
        # `crack-7z-hash` is the one that matters: it PASSED in the full-89 run
        # with double the agent timeout the Hub package allows. Both leaderboard
        # contracts forbid resource and timeout overrides, and running a task
        # copy that carries larger values is the same thing arriving by a
        # different route -- it just does not show up in `config.json` as an
        # override. Any figure from this copy must not be compared against a
        # published row without saying so.
        #
        # Anything intended for SUBMISSION must be run against the canonical id
        # rather than this copy.
        hub_id=None,
        local_dir="terminal-bench-2",
        size=89,
        status="superseded",
        leaderboard="tbench.ai/leaderboard/terminal-bench/2.0",
        notes=(
            "SUPERSEDED by 2.1. Kept so historical OSA runs remain "
            "re-derivable and so 2.0-vs-2.1 deltas can be attributed.",
            "27 of its 89 tasks were changed in 2.1 (see DIFF_TB20_TB21). A "
            "failure on one of those is not evidence about OSA until it has "
            "been reproduced on 2.1.",
        ),
    ),
    "tb2.1": Dataset(
        key="tb2.1",
        label="Terminal-Bench 2.1",
        hub_id="terminal-bench/terminal-bench-2-1",
        local_dir="terminal-bench-2-1",
        size=89,
        status="current",
        leaderboard="tbench.ai/leaderboard/terminal-bench/2.1",
        notes=(
            "Same 89 task names as 2.0; 26 modified upstream to fix bugs, "
            "timeouts, resources and reward-hacking robustness. Many changes "
            "taken from Z.ai's terminal-bench-2-verified.",
            # RETRACTED 2026-08-15. This note used to assert that community
            # submissions were CLOSED and maintainer-run only. That was wrong,
            # it was never sourced, and it propagated out of here into planning
            # decisions -- it is the reason a publishable number was treated as
            # unpublishable. tbench.ai's "Running Terminal-Bench" page says:
            #
            #   "Leaderboard logs are stored in [this HuggingFace repo]
            #    (huggingface.co/datasets/alexgshaw/terminal-bench-2-leaderboard).
            #    To submit your results, open a PR there following the
            #    instructions in the README."
            #
            # Submissions are OPEN, by PR to that dataset repo.
            # VERIFIED 2026-08-15 by fetching the repo tbench.ai's own 2.0 docs
            # page links to. The link exists; the destination is shut:
            # huggingface.co/datasets/alexgshaw/terminal-bench-2-leaderboard
            # reads "SUBMISSIONS CLOSED -- All PRs opened before May 14th have
            # been reviewed and merged if valid... We are working on a new
            # submission process... Check back by end of June for an update."
            # That note is itself stale as of mid-August, with no new process
            # shipped. So the live docs link to a closed door, which is why
            # reading the docs page alone gives the wrong answer.
            "Submissions CLOSED (hf.co/datasets/alexgshaw/terminal-bench-2-"
            "leaderboard README, checked 2026-08-15). Successor process "
            "announced but not shipped.",
            # NOW VERIFIED, from the same README. This was an unsourced claim
            # here and it turned out to be correct.
            "5 trials per task MINIMUM: 'Each task must be evaluated with a "
            "minimum of five trials.' A single-trial run is a different "
            "measurement and cannot be laid beside a board row.",
            # The artefact contract, for whenever the successor process lands.
            # Everything here is something Harbor already writes and this
            # harness already retains -- the gap is trials, not engineering.
            # Note there is no ATIF requirement on the 2.0 path; that is 2.1's
            # CI, and conflating them would cost an adapter rewrite for nothing.
            "Layout: submissions/terminal-bench/2.0/<agent>__<model>/"
            "{metadata.yaml, <job>/config.json, <job>/<trial>/result.json}. "
            "metadata.yaml needs agent_url, agent_display_name, "
            "agent_org_display_name, and models[] with model_name, "
            "model_provider, model_display_name, model_org_display_name.",
        ),
    ),
    "tb3": Dataset(
        key="tb3",
        label="Terminal-Bench 3 (continuous)",
        hub_id="terminal-bench/terminal-bench",
        local_dir="terminal-bench",
        size=74,
        status="current",
        leaderboard="tbench.ai/leaderboard/terminal-bench",
        notes=(
            "A DIFFERENT task set, not a patch of 2.x — 74 tasks, no name "
            "overlap with 2.0/2.1. Deeply unsaturated.",
            "It is a CONTINUOUS benchmark: `@latest` moves. The local copy "
            "pins whatever was current when it was synced; the resolved ref "
            "is recorded in the run config so two runs can be told apart.",
            "Upstream develops on Modal and says the oracle may flake on "
            "other sandboxes. Run the oracle control before believing any "
            "failure on this set.",
        ),
    ),
    "harbor-index": Dataset(
        key="harbor-index",
        label="Harbor-Index",
        hub_id="harbor-index/harbor-index",
        local_dir="harbor-index",
        size=80,
        status="current",
        leaderboard="hub.harborframework.com/datasets/harbor-index/harbor-index",
        notes=(
            "Built by the Terminal-Bench authors explicitly for cheap "
            "cross-AGENT comparison: distilled from >6,000 candidate tasks "
            "across many benchmarks, filtered for >33% frontier pass rate, "
            "LLM-audited, then human-reviewed.",
            "80 tasks as downloaded — not the 82 quoted in "
            "docs/research/what-harnesses-benchmark.md. Upstream's own README "
            "also says 80.",
            "A SUBSET OF TASKS IS GRADED BY AN LLM-JUDGE ENSEMBLE, pinned by "
            "the upstream job-config.yaml, which needs OPENAI/ANTHROPIC/GEMINI "
            "keys at VERIFY time. Without them those tasks cannot be scored, "
            "and a run that silently drops them is reporting on a different "
            "denominator. See `judge_required_tasks()`.",
        ),
    ),
    "tb-pro": Dataset(
        key="tb-pro",
        label="Terminal-Bench Pro (public half)",
        hub_id=None,  # legacy registry only: `terminal-bench-pro@1.0`
        local_dir="terminal-bench-pro",
        size=200,
        status="current",
        leaderboard=None,
        notes=(
            "Alibaba. 200 public of 400 tasks, TB2.0 format. Resolvable only "
            "through the LEGACY registry (`--legacy-dataset "
            "terminal-bench-pro@1.0`); not on the Hub.",
            "No public methodology page and submissions are by email, so "
            "there is no board to compare against. Second tier for us.",
        ),
    ),
}

#: Datasets the runner offers by default in help text, in the order a reader
#: should think about them.
ORDER = ("tb2.1", "tb3", "harbor-index", "tb2.0", "tb-pro")


def get(key: str) -> Dataset:
    if key not in DATASETS:
        raise SystemExit(
            f"unknown dataset key '{key}'. Known: {', '.join(ORDER)}"
        )
    return DATASETS[key]


#: Task-name prefixes whose VERIFIER calls an LLM judge, per Harbor-Index's own
#: `job-config.yaml`: "the LLM-judged tasks (hle-*, omnimath-*, gaia2-*,
#: widesearch-*) crash with '... must be set' without all three JUDGE_* vars".
#: The judge is a single Anthropic model (claude-opus-5) voting 3 times.
#:
#: This is NOT discoverable from the task.toml files — they contain no mention
#: of a judge — so it cannot be derived from the downloaded dataset and has to
#: be recorded here, sourced. Without ANTHROPIC_API_KEY these tasks cannot be
#: graded at all, and a run that quietly loses them is reporting a different
#: denominator than the leaderboard.
JUDGE_TASK_PREFIXES: dict[str, tuple[str, ...]] = {
    "harbor-index": ("hle-", "omnimath-", "gaia2-", "widesearch-"),
}


def judge_required_tasks(ds: Dataset) -> list[str]:
    """Tasks in `ds` whose verifier needs a model credential to grade at all."""
    prefixes = JUDGE_TASK_PREFIXES.get(ds.key, ())
    if not prefixes or not ds.present:
        return []
    return [n for n in ds.task_names() if n.startswith(prefixes)]


def gradeable_tasks(ds: Dataset, *, have_judge_key: bool) -> list[str]:
    """The tasks that can actually be scored on this machine."""
    names = ds.task_names()
    if have_judge_key:
        return names
    skip = set(judge_required_tasks(ds))
    return [n for n in names if n not in skip]


def sync(ds: Dataset, *, overwrite: bool = True) -> None:
    """(Re-)download a Hub dataset into `tasks/<local_dir>`."""
    if ds.hub_id is None:
        raise SystemExit(
            f"{ds.key} has no Hub id. It resolves through the legacy registry "
            f"only; run it with `--legacy-dataset`."
        )
    harbor = HERE / ".venv" / "bin" / "harbor"
    cmd = [str(harbor), "download", ds.hub_id, "-o", str(TASKS_ROOT)]
    if overwrite:
        cmd.append("--overwrite")
    print(" ".join(cmd))
    subprocess.run(cmd, check=True)


#: Artefacts that must never exist inside a task copy, because Harbor uploads
#: the whole task directory into the grading container.
_CONTAMINANTS = ("__pycache__", "*.pyc", "*.pyo", ".pytest_cache")


def contamination(ds: Dataset) -> list[str]:
    """Host-generated files sitting inside a task copy.

    ## Why this is a gate and not a lint

    `verifier/verifier.py:133-238` uploads the task's `tests/` directory into
    the container that decides the reward. Anything we leave in there is shipped
    into a grading environment. Stale bytecode whose source has since changed is
    the bad case: Python prefers a `.pyc` whose embedded mtime still matches, so
    a grading run can execute code that no longer exists on disk.

    ## How it got there

    The repo had no pytest configuration, so a bare `pytest` from `bench/`
    collected `tasks/*/tests/test_*.py` -- the benchmark tasks' own tests --
    compiled them, and left the bytecode behind. Measured 2026-08-15: 27
    `__pycache__` directories and 38 `.pyc` files across the task copies, all
    stamped that day, all named `cpython-312-pytest-9.1.1`. A fresh
    `harbor download terminal-bench/terminal-bench-2` contains none, confirming
    every one was ours. `bench/pytest.ini` now stops the collection; this
    function is the check that the prevention actually held.
    """
    if not ds.present:
        return []
    found: list[str] = []
    for pattern in _CONTAMINANTS:
        for p in ds.path.rglob(pattern):
            found.append(str(p.relative_to(ds.path)))
    return sorted(found)


def clean(ds: Dataset) -> list[str]:
    """Remove every contaminant from a task copy. Returns what it deleted."""
    import shutil

    removed = contamination(ds)
    for pattern in _CONTAMINANTS:
        for p in list(ds.path.rglob(pattern)):
            if p.is_dir():
                shutil.rmtree(p, ignore_errors=True)
            elif p.exists():
                p.unlink()
    return removed


def _diff(a: Dataset, b: Dataset) -> list[str]:
    """Task names whose content differs, ignoring dotfiles.

    Dotfiles are ignored on purpose: the 2.0 copy came from a `git clone` and
    carries a per-task `.gitignore` that the Hub download does not, which makes
    a naive comparison report all 89 tasks as changed and says nothing.
    """

    def files(root: Path) -> dict[str, Path]:
        return {
            str(p.relative_to(root)): p
            for p in root.rglob("*")
            if p.is_file()
            and not any(part.startswith(".") for part in p.relative_to(root).parts)
        }

    changed = []
    for name in a.task_names():
        pa, pb = a.path / name, b.path / name
        if not pb.is_dir():
            changed.append(name)
            continue
        fa, fb = files(pa), files(pb)
        if set(fa) != set(fb) or any(
            fa[k].read_bytes() != fb[k].read_bytes() for k in set(fa) & set(fb)
        ):
            changed.append(name)
    return changed


def main(argv: list[str] | None = None) -> int:
    import argparse

    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list")
    p = sub.add_parser("sync", help="download / refresh a dataset from the Hub")
    p.add_argument("key", nargs="*", default=None)
    p = sub.add_parser("diff", help="which tasks changed between two datasets")
    p.add_argument("a")
    p.add_argument("b")
    p = sub.add_parser(
        "check", help="fail if a task copy carries host-generated bytecode"
    )
    p.add_argument("key", nargs="*", default=None)
    p.add_argument("--fix", action="store_true", help="delete what it finds")

    args = ap.parse_args(argv)

    if args.cmd == "list":
        print(f"{'key':14s} {'label':32s} {'status':11s} {'declared':>8s} "
              f"{'on disk':>8s}  hub id")
        for k in ORDER:
            d = DATASETS[k]
            disk = d.on_disk_size() if d.present else 0
            flag = "" if (not d.present or disk == d.size) else "  <-- MISMATCH"
            print(f"{d.key:14s} {d.label:32s} {d.status:11s} {d.size:8d} "
                  f"{disk:8d}  {d.hub_id or '(legacy registry only)'}{flag}")
        return 0

    if args.cmd == "sync":
        keys = args.key or [k for k in ORDER if DATASETS[k].hub_id]
        for k in keys:
            sync(get(k))
        return 0

    if args.cmd == "check":
        keys = args.key or [k for k in ORDER if DATASETS[k].present]
        dirty = 0
        for k in keys:
            ds = get(k)
            found = clean(ds) if args.fix else contamination(ds)
            if found:
                dirty += 1
                verb = "removed" if args.fix else "FOUND"
                print(f"{verb} {len(found)} contaminant(s) in {ds.key}:")
                for f in found[:20]:
                    print(f"  {f}")
                if len(found) > 20:
                    print(f"  ... and {len(found) - 20} more")
            else:
                print(f"clean: {ds.key}")
        return 1 if (dirty and not args.fix) else 0

    if args.cmd == "diff":
        a, b = get(args.a), get(args.b)
        if not (a.present and b.present):
            raise SystemExit("both datasets must be present on disk")
        ch = _diff(a, b)
        print(f"{len(ch)} task(s) differ between {a.label} and {b.label}:")
        for n in ch:
            print(f"  {n}")
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
