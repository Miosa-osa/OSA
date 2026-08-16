#!/usr/bin/env python3
"""Harbor benchmark runner for OSA.

Harbor is the harness; this is the thin layer around it that (a) supplies the
flags OSA needs, and (b) turns Harbor's per-trial output into one results file
with the honesty flags attached, in the same shape as bench/swebench.

The dataset is a FIRST-CLASS, RECORDED INPUT (`bench/terminalbench/datasets.py`).
It used to be hard-coded to a local clone of Terminal-Bench 2.0, which is a
superseded task set: 2.1 modified 26 of the same 89 tasks, so a failure recorded
against 2.0 may be an artefact of a task that has since been fixed. The default
is now **2.1**; 2.0 is still runnable, on purpose, so old results stay
re-derivable and 2.0-vs-2.1 deltas can be attributed.

    # sanity: the oracle solutions must score 1.0, or the harness is broken
    ./run_bench.py --agent oracle --tasks regex-log

    # OSA on a named task, on the CURRENT Terminal-Bench
    ./run_bench.py --agent osa --tasks regex-log

    # OSA on the hard end of the superseded 2.0 set, for comparison
    ./run_bench.py --dataset-key tb2.0 --agent osa --difficulty hard --limit 8

    # the cheap cross-agent instrument
    ./run_bench.py --dataset-key harbor-index --agent osa --limit 8

    # the fixed cost probe (same 8 tasks every time; see probeset.py)
    ./run_bench.py --agent osa --probe

Run `--agent oracle` first on any new machine, or better, use
`./controls.py run --dataset-key <k>`, which runs oracle AND nop and writes the
gate file that `controls.py gate` reads. An OSA number from a dataset whose
oracle did not score ~100% is not a measurement of OSA.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import artifact_lock  # noqa: E402
import datasets as datasets_mod  # noqa: E402
import probeset as probeset_mod  # noqa: E402
import report as report_mod  # noqa: E402

TASKS_DIR_ENV = "OSA_TBENCH_TASKS_DIR"
#: Legacy-registry id, still accepted via --legacy-dataset. The legacy registry
#: has not been updated past Terminal-Bench 2.0; see datasets.py.
DEFAULT_LEGACY_DATASET = "terminal-bench@2.0"
DEFAULT_DATASET_KEY = "tb2.1"


def log(msg: str) -> None:
    print(f"[tbench {datetime.now().strftime('%H:%M:%S')}] {msg}", flush=True)


def artifact_provenance() -> dict:
    """Which OSA build this run actually measured.

    The tarball under `dist/` is what goes into every container, and NOTHING
    else about the run identifies it. That is how two arms of an ablation came
    to be run on different code: an artefact built four hours before `lib/`
    changed was reused, and the comparison was voided after the fact with no way
    to tell from the results file which build each arm had.

    So the artefact's mtime, size and sha256 are recorded, alongside the repo
    HEAD and whether the tree was dirty at launch. `built_after_head_commit` is
    the check that matters: false means the artefact predates the commit the
    run claims to measure, and the run is measuring older code than its own
    provenance says.
    """
    art = HERE / "dist" / "osa-release-linux-x86_64.tar.gz"
    out: dict = {"artifact": str(art), "present": art.exists()}
    if art.exists():
        st = art.stat()
        out["built_at"] = datetime.fromtimestamp(st.st_mtime, timezone.utc).isoformat()
        out["size_bytes"] = st.st_size
        try:
            import hashlib

            h = hashlib.sha256()
            with art.open("rb") as fh:
                for chunk in iter(lambda: fh.read(1 << 20), b""):
                    h.update(chunk)
            out["sha256"] = h.hexdigest()
        except OSError:
            pass

    def _git(*a) -> str | None:
        try:
            r = subprocess.run(
                ["git", *a], cwd=str(HERE), capture_output=True, text=True, timeout=30
            )
            return r.stdout.strip() or None
        except Exception:  # noqa: BLE001
            return None

    out["head_commit"] = _git("rev-parse", "HEAD")
    out["head_committed_at"] = _git("log", "-1", "--format=%cI")
    # `:/lib` and not `lib`. `_git` runs with cwd=HERE, which is
    # bench/terminalbench, and a plain `lib` pathspec is resolved relative to the
    # CURRENT DIRECTORY -- so it matched `bench/terminalbench/lib`, which does
    # not exist, and this check reported a clean tree unconditionally from the
    # day it was written. The leading `:/` is git's magic prefix for
    # "relative to the top of the working tree" and is cwd-independent.
    #
    # This is the guard that was supposed to catch benchmarking a half-applied
    # tree. It caught nothing, twice.
    dirty = _git("status", "--porcelain", "--", ":/lib")
    out["lib_dirty_at_launch"] = bool(dirty)
    out["lib_dirty_files"] = len(dirty.splitlines()) if dirty else 0
    # Parsed, not compared as strings. `built_at` is rendered from a UTC-aware
    # datetime ("...+00:00") while `head_committed_at` comes from git's %cI in
    # LOCAL time ("...+07:00"), and a lexicographic comparison of two ISO
    # timestamps at different offsets compares the printed digits rather than
    # the instants. Measured on a real build: an artefact 3 minutes NEWER than
    # HEAD compared as older, because "2026-08-14T17:51:39+00:00" sorts before
    # "2026-08-15T00:48:17+07:00" as text while naming a later moment.
    #
    # The failure mode is the dangerous direction: a sound artefact reported as
    # predating the commit it measures, on a field whose whole job is to say
    # whether the run is measuring the code it claims to.
    if out.get("built_at") and out.get("head_committed_at"):
        try:
            built = datetime.fromisoformat(out["built_at"])
            committed = datetime.fromisoformat(out["head_committed_at"])
            out["built_after_head_commit"] = built > committed
        except ValueError as exc:
            out["built_after_head_commit"] = None
            out["built_after_head_commit_error"] = str(exc)

    # The sidecar `build_release.sh` writes beside the tarball. This is the only
    # field that identifies the code that was MEASURED; everything above it
    # describes the repo at LAUNCH, and the two diverge the moment anyone
    # commits in between -- which, with several agents working in lib/, they do.
    # `built_after_head_commit` in particular goes false on a perfectly sound
    # artefact as soon as a later commit lands, so it must not be read as a
    # staleness verdict when `build_sha` is present.
    side = art.parent / "build-provenance.json"
    if side.exists():
        try:
            out["build"] = json.loads(side.read_text())
        except (OSError, json.JSONDecodeError) as exc:
            out["build"] = {"error": f"unreadable build-provenance.json: {exc}"}
    else:
        out["build"] = None
    return out


def harbor_bin() -> Path:
    venv = HERE / ".venv" / "bin" / "harbor"
    if not venv.exists():
        raise SystemExit(
            f"{venv} missing. Create it:\n"
            f"  python3 -m venv {HERE / '.venv'} && {HERE / '.venv/bin/pip'} install harbor"
        )
    return venv


def harbor_version() -> str:
    try:
        return subprocess.run(
            [str(harbor_bin()), "--version"], capture_output=True, text=True, timeout=60
        ).stdout.strip()
    except Exception:  # noqa: BLE001
        return "?"


def ablation_env() -> dict[str, str]:
    """Which OSA behaviour switches this run is flipping, read from our own env.

    The key list is owned by ``osa_agent.OSA_ABLATION_ENV_KEYS`` — that is the
    module that forwards them into the container — but ``osa_agent`` imports
    ``harbor``, which lives in ``.venv`` and not in *this* interpreter. So the
    names are lifted out of the source text rather than duplicated here: one
    definition, and adding a switch there makes it recorded here automatically.

    Recorded into ``config.json`` because an arm that cannot state its own
    switches is not an arm. Two arms of a one-variable ablation are built from
    the same artefact and are otherwise byte-identical on disk.
    """
    src = (HERE / "osa_agent.py").read_text()
    # Terminated on a bare `)` at column 0, not the first `)` in the block:
    # the entries are commented, the comments contain parentheses, and a
    # non-greedy match stops inside the first one and silently returns no keys.
    m = re.search(r"^OSA_ABLATION_ENV_KEYS = \(\n(.*?)^\)", src, re.S | re.M)
    keys = re.findall(r'"([A-Z0-9_]+)"', m.group(1)) if m else []
    return {k: os.environ[k] for k in keys if os.environ.get(k) not in (None, "")}


def local_tasks_dir(ds: "datasets_mod.Dataset | None") -> Path | None:
    """The on-disk copy of the selected dataset, if there is one.

    Using the local copy avoids re-resolving the registry on every run, is the
    only way to filter on task.toml metadata (difficulty) — which the Harbor CLI
    does not expose as a flag — and pins the task content so an upstream edit
    mid-run cannot change the denominator underneath us. That last point matters
    for `tb3`, which is a continuous benchmark whose `@latest` moves.

    `OSA_TBENCH_TASKS_DIR` still overrides everything, for a scratch task set.
    """
    p = os.environ.get(TASKS_DIR_ENV)
    if p and Path(p).is_dir():
        return Path(p)
    if ds is None:
        return None
    return ds.path if ds.present else None


def read_task_meta(task_dir: Path) -> dict:
    toml_path = task_dir / "task.toml"
    if not toml_path.exists():
        return {}
    try:
        import tomllib

        return tomllib.loads(toml_path.read_text())
    except Exception:  # noqa: BLE001
        return {}


def select_tasks(args, ds) -> tuple[list[str], int]:
    """Return (task names, dataset size).

    Difficulty filtering requires the local copy; without it the only filters
    Harbor itself offers are name globs and a count.
    """
    tasks_dir = local_tasks_dir(ds)
    if tasks_dir is None:
        if args.difficulty:
            raise SystemExit(
                f"--difficulty needs a local copy of the task set. Fetch it:\n"
                f"  ./datasets.py sync {ds.key if ds else 'tb2.1'}"
            )
        return (args.tasks or []), (ds.size if ds else 0)

    all_dirs = sorted(p.parent for p in tasks_dir.glob("*/task.toml"))
    dataset_size = len(all_dirs)
    chosen = []
    for d in all_dirs:
        meta = read_task_meta(d)
        difficulty = (meta.get("metadata") or {}).get("difficulty")
        if args.difficulty and difficulty != args.difficulty:
            continue
        if args.tasks and d.name not in args.tasks:
            continue
        chosen.append(d.name)
    if args.tasks:
        missing = sorted(set(args.tasks) - set(chosen))
        if missing and not args.difficulty:
            raise SystemExit(f"tasks not found in {tasks_dir}: {missing}")
    if args.limit:
        chosen = chosen[: args.limit]
    return chosen, dataset_size


def filter_judge_tasks(
    ds, chosen: list[str], explicit: set[str], *, have_key: bool
) -> tuple[list[str], list[str]]:
    """Drop the tasks whose VERIFIER cannot run here. Returns (kept, dropped).

    16 of Harbor-Index's 80 tasks are scored by an LLM-judge ensemble that runs
    at verify time and needs a model credential (`datasets.JUDGE_TASK_PREFIXES`,
    sourced from the upstream `job-config.yaml`). Without it the verifier
    crashes rather than scoring zero, so those tasks are **absences, not
    failures** -- scoring them 0 understates the rate and dispatching them burns
    budget on a result nothing can grade.

    `controls.py` has filtered them since it was written; this runner did not.
    That is not a rounding error: the controls would validate 64 tasks, the
    runner would dispatch 80, and the run would report over a denominator it had
    never measured, with `controls.py gate` unable to see the difference because
    it only inspects the tasks a run actually recorded.

    An EXPLICITLY named task is never dropped silently -- see the caller.
    """
    if not ds or have_key:
        return chosen, []
    required = set(datasets_mod.judge_required_tasks(ds))
    if not required:
        return chosen, []
    blocked = sorted(set(chosen) & required)
    named = sorted(set(blocked) & explicit)
    if named:
        raise SystemExit(
            f"{len(named)} task(s) you named are graded by an LLM judge at "
            f"VERIFY time and cannot be scored without "
            f"${datasets_mod.JUDGE_CREDENTIAL_ENV}: {', '.join(named)}.\n"
            "Set the credential, or drop them from --tasks. They are not "
            "dropped for you, because a run that quietly loses a task you asked "
            "for reports on a set you did not choose."
        )
    drop = set(blocked)
    return [t for t in chosen if t not in drop], blocked


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--agent", default="osa", help="osa | oracle | nop | any harbor agent")
    ap.add_argument("--run-id", default=None, help="defaults to <agent>-<timestamp>")
    ap.add_argument("--dataset-key", default=DEFAULT_DATASET_KEY,
                    choices=list(datasets_mod.ORDER),
                    help=f"which task set (default {DEFAULT_DATASET_KEY}). "
                         "See ./datasets.py list")
    ap.add_argument("--legacy-dataset", default=None,
                    help="bypass --dataset-key and resolve a LEGACY registry id "
                         f"(e.g. {DEFAULT_LEGACY_DATASET}). The legacy registry "
                         "stops at Terminal-Bench 2.0")

    sel = ap.add_argument_group("task selection")
    sel.add_argument("--tasks", nargs="*", default=None, help="task directory names")
    sel.add_argument("--difficulty", default=None, choices=["easy", "medium", "hard"],
                     help="from task.toml [metadata]; needs the local copy")
    sel.add_argument("--limit", type=int, default=None)
    sel.add_argument("--probe", action="store_true",
                     help="run the FIXED cost-probe task set for this dataset "
                          "(see probeset.py). Overrides --tasks/--difficulty")

    run = ap.add_argument_group("execution")
    run.add_argument("--model", default=None, help="passed to harbor as -m provider/model")
    run.add_argument("--n-concurrent", type=int, default=2,
                     help="trials in parallel. Each runs a whole OSA VM in a "
                          "container; do not raise this casually")
    # Harbor has FOUR timeout multipliers, and they are not interchangeable.
    # `--timeout-multiplier` is the global one; the other three override it for
    # one phase each. cline's published GLM-5.2 rows used the GLOBAL one at 2.0,
    # so matching them means this flag and not `--agent-timeout-multiplier`,
    # which leaves the verifier and setup budgets at 1.0.
    #
    # That distinction is not academic here. TB 2.1's oracle control lost
    # `torch-pipeline-parallelism` to a VerifierTimeoutError -- it spent its
    # whole 900s budget pulling ~2.5 GB of CUDA wheels without reaching a test.
    # Doubling only the agent phase would not have moved that task at all.
    run.add_argument("--timeout-multiplier", type=float, default=None,
                     help="global task-timeout multiplier. cline ran 2.0; a run "
                          "at 1.0 is not comparable to their numbers")
    run.add_argument("--agent-timeout-multiplier", type=float, default=None,
                     help="overrides --timeout-multiplier for the agent phase only")
    # TRIALS PER TASK. Harbor's `-k`.
    #
    # Both leaderboard contracts require five, verbatim -- the TB 2.0 board:
    # "Each task must be evaluated with a minimum of five trials. We recommend
    # the `-k 5` flag for convenience."; TB 2.1's `SUBMIT.md`: "Cover every
    # task, >= 5 trials each", enforced in its CI by
    # `MIN_TRIALS_PER_TASK = 5`.
    #
    # We ran n=1 for every figure we have ever quoted. That is not a rounding
    # concern: a single task has been watched flipping 4-pass/2-fail with no
    # code change at all, so at n=1 each task contributes a coin flip and the
    # run-to-run spread swamps the differences being tuned for. Default stays 1
    # so this flag never silently multiplies anyone's compute bill; anything
    # intended for publication passes 5.
    run.add_argument("-k", "--n-attempts", type=int, default=None,
                     help="trials per task (harbor -k). Both leaderboards "
                          "require >= 5; we have only ever run 1")
    # RETRIES. Harbor's `-r`, default 0.
    #
    # Inert until 2026-08-15, for a reason that had nothing to do with this
    # flag: the driver exited 0 on every failure, so Harbor never saw an
    # exception to retry and a provider outage was recorded as a clean
    # reward-0. With the driver's exit codes fixed (`driver/osa_headless.py`,
    # `_EXIT_CODES`) a retry budget finally does something, so it is reachable.
    # `exclude_exceptions` still governs WHAT is retried: infrastructure yes,
    # the agent never.
    run.add_argument("-r", "--max-retries", type=int, default=None,
                     help="retries per trial on infrastructure faults "
                          "(harbor -r). Pointless before the driver reported "
                          "failure exit codes; useful now")
    # Reasoning effort. Anthropic's Opus 4.6 system card measures the SAME model
    # under a FIXED harness moving 10.3 pp across effort tiers (55.1 low -> 65.4
    # max) -- a bigger lever than the 7.2 pp harness delta they measure on the
    # same task set. cline measured the same thing on GLM-5.2: reasoning off
    # costs it 11.2 pp (68.5% -> 57.3%). Every published figure names its tier
    # ("Fable 5 (xhigh)", "Opus 5 (max)"). An unpinned effort makes a number
    # unquotable, so both dials are explicit flags and both land in config.json.
    #
    # There are TWO dials because they are not the same dial:
    #   --effort       OSA's own ladder (Agent.Effort): max_iterations, thinking
    #                  budget, internal gating. Reaches the wire on Anthropic
    #                  (output_config.effort) and OpenAI-compat (reasoning_effort).
    #   --ollama-think Ollama's `think` field. Ollama has NO effort->thinking
    #                  wiring (see providers/ollama.ex `apply_think/3`), so on
    #                  our serving path --effort never reaches the wire and THIS
    #                  is the only knob that changes what the model does. It is
    #                  the analogue of cline's "reasoning: medium" vs "off".
    run.add_argument("--effort", default=None,
                     choices=["fast", "medium", "high", "xhigh", "ultra"],
                     help="pin OSA's effort ladder. Unset means UNPINNED, which "
                          "is recorded as such and makes the run unquotable")
    run.add_argument("--ollama-think", default=None, choices=["true", "false"],
                     help="pin Ollama's `think` field. On glm-5.2:cloud this is "
                          "the only reasoning dial that reaches the wire")
    run.add_argument("--host-provider", action="store_true", default=True,
                     help="let the container reach a model provider on the host "
                          "(local Ollama). On by default")
    run.add_argument("--no-host-provider", dest="host_provider", action="store_false")
    run.add_argument("--install-only", action="store_true",
                     help="install OSA into each container and stop: a fast "
                          "compatibility check that costs no tokens")
    run.add_argument("--report-only", metavar="JOB_DIR",
                     help="skip running; just re-report an existing harbor job dir")
    run.add_argument("--allow-unpinned-artifact", action="store_true",
                     help="read dist/ live instead of pinning an immutable copy "
                          "into the run directory. Any rebuild during the run "
                          "then silently changes what is measured -- which has "
                          "happened three times. Debugging only.")
    run.add_argument("--allow-split-build", action="store_true",
                     help="launch even when dist/ and dist-bullseye/ were built "
                          "from different commits. Tasks are routed between them "
                          "by container glibc, so the run measures two builds.")

    args = ap.parse_args()
    run_id = args.run_id or f"{args.agent}-{time.strftime('%Y%m%d-%H%M%S')}"
    out = HERE / "runs" / run_id
    out.mkdir(parents=True, exist_ok=True)

    ds = None if args.legacy_dataset else datasets_mod.get(args.dataset_key)
    if ds is not None and not ds.present:
        raise SystemExit(
            f"dataset '{ds.key}' is not on disk at {ds.path}.\n"
            f"  ./datasets.py sync {ds.key}"
        )

    # Captured BEFORE --probe overwrites it: an operator who names a task by
    # hand is making a different request from one who takes a probe set, and the
    # judge filter below treats them differently.
    explicit_tasks = set(args.tasks or [])

    if args.probe:
        probe = probeset_mod.get(args.dataset_key)
        args.tasks = list(probe.tasks)
        args.difficulty = None
        args.limit = None

    tasks_dir = local_tasks_dir(ds)
    chosen, dataset_size = select_tasks(args, ds)

    # ---------------------------------------------------------------- judge
    # DROP THE TASKS THIS MACHINE CANNOT GRADE, AND SAY THE DENOMINATOR ALOUD.
    #
    # 16 of Harbor-Index's 80 tasks are scored by an LLM-judge ensemble that
    # runs at VERIFY time and needs a model credential (see
    # `datasets.JUDGE_TASK_PREFIXES`, sourced from the upstream
    # `job-config.yaml`). Without it their verifier crashes rather than scoring
    # zero, so they are not failures -- they are absences.
    #
    # `controls.py` has known this since it was written and filtered them out of
    # its own sweep. `run_bench.py` did not. The consequence is not a rounding
    # error: the controls would validate 64 tasks, the runner would dispatch 80,
    # and every one of the extra 16 would land in the results as an unscored
    # trial against a denominator of 80 -- a rate measured over one set and
    # reported over another, with the gate unable to see the difference because
    # it only checks the tasks the run actually recorded.
    #
    # An explicitly named task is NOT silently dropped. Someone who typed
    # `--tasks hle-vowel-marking-system` has asked a question this machine
    # cannot answer, and the honest reply is to refuse. See
    # `filter_judge_tasks`, which is where the rule lives so it can be tested
    # without launching a run.
    have_key = datasets_mod.have_judge_key()
    judge_required = sorted(datasets_mod.judge_required_tasks(ds)) if ds else []
    chosen, judge_skipped = filter_judge_tasks(
        ds, chosen, explicit_tasks, have_key=have_key
    )

    # THE EFFECTIVE DENOMINATOR, STATED BEFORE ANYTHING IS SPENT.
    # `dataset_size` is what the task set HAS; `len(chosen)` is what this run
    # can actually score. Printing the second only at the end, after the money
    # is gone, is how a partial run gets quoted as a full one.
    if ds is not None:
        log(f"denominator: {len(chosen)} of {dataset_size} {ds.key} task(s) "
            f"will be dispatched and are scoreable here")
    if judge_skipped:
        log(f"  {len(judge_skipped)} task(s) EXCLUDED: their verifier calls an "
            f"LLM judge and ${datasets_mod.JUDGE_CREDENTIAL_ENV} is unset, so "
            f"they cannot be graded at all — they are absences, not failures.")
        log(f"  excluded: {', '.join(judge_skipped)}")
        log(f"  ANY RATE FROM THIS RUN IS OVER {len(chosen)}, NOT "
            f"{dataset_size}. Say so when quoting it.")

    # Refuse to ship host-generated bytecode into a grading container.
    #
    # Harbor uploads the task's `tests/` directory into the environment that
    # decides the reward, so a `.pyc` left behind by a host `pytest` run is
    # uploaded with it. `bench/pytest.ini` stops the collection that created
    # them; this is the check that the prevention held, because the failure mode
    # is silent and lands in the grader.
    if ds is not None:
        dirty = datasets_mod.contamination(ds)
        if dirty:
            raise SystemExit(
                f"{len(dirty)} host-generated file(s) inside the {ds.key} task "
                f"copy would be uploaded into the grading container, e.g. "
                f"{dirty[0]}.\n"
                f"  python3 datasets.py check {ds.key} --fix"
            )

        # Refuse to launch against a task copy whose recorded non-conformance
        # no longer matches the disk.
        #
        # `datasets.NONCONFORMING_TASKS` is what `report.py` uses to mark
        # results void, and it is a pinned measurement against the canonical Hub
        # package. If the local copy has since moved, the marking is either
        # missing a task that now buys us an advantage or voiding one that no
        # longer does -- and both are worse than not marking at all, because
        # both are stated confidently in the summary. Stale-table means stop.
        #
        # This is NOT a substitute for `controls.py gate`, which still runs
        # afterwards and still blocks on unmeasured tasks. It is the same class
        # of pre-flight as the contamination check above: something that must be
        # true before a run is worth starting.
        drift = datasets_mod.check_conformance(ds)
        if drift:
            raise SystemExit(
                f"the recorded non-conformance table for {ds.key} no longer "
                "matches the task copy on disk, so results cannot be marked "
                "void correctly:\n  "
                + "\n  ".join(drift)
                + "\nRe-measure against `harbor download` and update "
                "`datasets.NONCONFORMING_TASKS`."
            )

    config = {
        "run_id": run_id,
        "agent": args.agent,
        "model": args.model,
        # The key is what everything downstream keys off; the path/id is the
        # provenance. Both are recorded because either alone is ambiguous.
        "dataset_key": ds.key if ds else "legacy",
        "dataset_label": ds.label if ds else (args.legacy_dataset or DEFAULT_LEGACY_DATASET),
        "dataset_status": ds.status if ds else "unknown",
        "dataset_hub_id": ds.hub_id if ds else None,
        "dataset": str(tasks_dir) if tasks_dir else (args.legacy_dataset or DEFAULT_LEGACY_DATASET),
        "dataset_size": dataset_size,
        "dataset_notes": list(ds.notes) if ds else [],
        "probe_set": probeset_mod.get(args.dataset_key).name if args.probe else None,
        # WHETHER THERE IS ANYTHING TO COMPARE THIS PROBE AGAINST.
        # `probeset.PROBE_SETS["harbor-index"].baseline is None`: this set has
        # never been run, so the FIRST run establishes the baseline and can
        # support no improvement claim at all. That is a property of the
        # artefact, so it is recorded in the artefact rather than left in a
        # module docstring the reader of the results file will never open.
        "probe_has_baseline": (
            probeset_mod.get(args.dataset_key).baseline is not None
            if args.probe
            else None
        ),
        "tasks_requested": chosen,
        # THE DENOMINATOR, RECORDED. `dataset_size` is what the set has;
        # `effective_denominator` is what this run could score. They differ
        # whenever a judged task is dropped, and a results file that carries
        # only the first invites a rate to be quoted over a set that was never
        # attempted. `report.py` prints the gap under the headline.
        "effective_denominator": len(chosen),
        "have_judge_key": have_key,
        "judge_required_tasks": judge_required,
        "judge_skipped_tasks": judge_skipped,
        "judge_credential_env": datasets_mod.JUDGE_CREDENTIAL_ENV,
        "difficulty_filter": args.difficulty,
        "n_concurrent": args.n_concurrent,
        # Timeouts convert possible solves into guaranteed fails, so the
        # multiplier is part of the result and not part of the invocation.
        # cline's published GLM-5.2 rows ran at 2.0; a run at 1.0 is not
        # comparable to them and must not be presented as if it were.
        "timeout_multiplier": args.timeout_multiplier,
        "agent_timeout_multiplier": args.agent_timeout_multiplier,
        # TRIALS PER TASK, recorded because it decides what the accuracy field
        # even means. `1` is a per-trial pass rate whose per-task resolution is
        # a coin flip; `>= 5` is what the leaderboards compare. A results file
        # that does not state this cannot be read correctly later, and every
        # figure we have published so far was written without it.
        "n_attempts": args.n_attempts or 1,
        "max_retries": args.max_retries or 0,
        # `None` means UNPINNED, deliberately. See the --effort help text: a
        # number whose reasoning tier is unrecorded is not reproducible, so the
        # absence has to stay legible instead of being filled with a default.
        "effort": args.effort,
        "ollama_think": args.ollama_think,
        "install_only": args.install_only,
        "harbor_version": harbor_version(),
        # WHICH BUILD THIS MEASURED. Without it a results file cannot be
        # attributed to any particular code, which has already voided one
        # ablation. See `artifact_provenance`.
        "artifact": artifact_provenance(),
        # WHICH BYTES THIS RUN OWNS. `artifact` above describes `dist/` at
        # launch and stops being true the moment anyone rebuilds; this names
        # the immutable copy inside the run directory that every container was
        # actually installed from. Filled in by the pin step below.
        "artifact_pin": None,
        # WHICH SWITCHES THIS RUN FLIPPED. Same reason as `artifact`: a results
        # file that cannot say which behaviour flags were on cannot be one arm
        # of an ablation, and two arms of the same artefact are otherwise
        # indistinguishable on disk. `{}` means "stock defaults".
        "ablation_env": ablation_env() if args.agent == "osa" else {},
        "started_at": datetime.now(timezone.utc).isoformat(),
        "host": {"platform": platform.platform(), "python": platform.python_version()},
    }

    if args.report_only:
        job_dir = Path(args.report_only)
    else:
        agent_spec = "osa_agent:OsaAgent" if args.agent == "osa" else args.agent
        cmd = [str(harbor_bin()), "run", "-a", agent_spec, "-y",
               "-o", str(out / "harbor"), "-n", str(args.n_concurrent)]

        if tasks_dir:
            # Harbor takes one -p; run the dataset dir and filter by name.
            cmd += ["-p", str(tasks_dir)]
            for t in chosen:
                cmd += ["-i", t]
            if not chosen:
                raise SystemExit("no tasks selected")
        else:
            cmd += ["-d", args.legacy_dataset or DEFAULT_LEGACY_DATASET]
            for t in (args.tasks or []):
                cmd += ["-i", t]
            if args.limit:
                cmd += ["-l", str(args.limit)]

        if args.model:
            cmd += ["-m", args.model]
        if args.timeout_multiplier:
            cmd += ["--timeout-multiplier", str(args.timeout_multiplier)]
        if args.agent_timeout_multiplier:
            cmd += ["--agent-timeout-multiplier", str(args.agent_timeout_multiplier)]
        if args.n_attempts:
            cmd += ["-k", str(args.n_attempts)]
        if args.max_retries:
            cmd += ["-r", str(args.max_retries)]
        if args.install_only:
            cmd += ["--install-only"]
        if args.host_provider and args.agent == "osa":
            cmd += ["--extra-docker-compose", str(HERE / "compose-host-provider.yaml")]

        # ── Pin the artefact for the lifetime of this run ──────────────────
        #
        # Until this existed, a run read `dist/` at launch and trusted it for
        # hours while other sessions were free to rebuild it -- which they did,
        # three times, and once mid-run. Copying the tarball into the run
        # directory and installing from there means the run owns bytes nobody
        # can replace, and means "what did we actually measure?" is answerable
        # from the run itself rather than from a `dist/` that has since moved.
        #
        # This REFUSES rather than records-and-continues; see
        # `artifact_lock.pin_for_run` for the exact conditions. Record-and-
        # continue is what produced the unusable runs.
        if args.agent == "osa" and not args.allow_unpinned_artifact:
            try:
                pin = artifact_lock.pin_for_run(out)
                artifact_lock.verify_pin(Path(pin["root"]))
            except artifact_lock.ArtifactError as exc:
                raise SystemExit(f"artefact pin failed, refusing to launch: {exc}") from exc
            config["artifact_pin"] = pin
            for name, entry in sorted(pin["variants"].items()):
                if entry.get("present"):
                    log(f"pinned {name} artefact "
                        f"build_sha={(entry['build'].get('build_sha') or '?')[:12]} "
                        f"sha256={entry['sha256'][:12]} -> {entry['pinned']}")
                else:
                    log(f"no {name} artefact to pin ({entry['source']})")
            # Two variants built from different commits is the split-build
            # incident: `dist/` was clobbered mid-run while `dist-bullseye/`
            # was not, so 2 of 89 tasks measured a different commit than the
            # other 87 and nothing said so. Loud, and fatal unless waived --
            # a run that measures two builds is not one measurement.
            if not pin["variants_agree"]:
                msg = (f"the pinned variants were built from DIFFERENT commits: "
                       f"{pin['build_shas']}. Tasks are routed between them by "
                       f"container glibc, so this run would measure two builds.")
                if args.allow_split_build:
                    log(f"WARNING: {msg} (allowed by --allow-split-build)")
                else:
                    raise SystemExit(
                        f"{msg}\nRebuild both from the same commit:\n"
                        f"  ./build_release.sh --from-commit <sha> --force\n"
                        f"  ./build_release.sh --bullseye --from-commit <sha> --force\n"
                        f"or pass --allow-split-build to measure them anyway."
                    )
        elif args.agent == "osa":
            log("WARNING: --allow-unpinned-artifact: this run reads dist/ live "
                "for its whole lifetime and any rebuild will silently change "
                "what it measures.")

        env = os.environ.copy()
        env["PYTHONPATH"] = str(HERE) + os.pathsep + env.get("PYTHONPATH", "")
        # The adapter installs from the pinned copy when this is set, and from
        # `dist/` when it is not -- so an adapter run under a bare `harbor run`
        # behaves exactly as it did before pinning existed.
        if config["artifact_pin"]:
            env[artifact_lock.PINNED_ROOT_ENV] = config["artifact_pin"]["root"]
        # Tell the adapter WHICH task set this run selected.
        #
        # It needs the task's own `timeout_sec` to set a driver deadline that
        # fires just before Harbor's -- Harbor never tells an adapter its budget
        # (`agent_timeout_sec` goes to the oracle only). Without this the adapter
        # has to scan every dataset copy on disk, and task names are not unique
        # across them: `gpt2-codegolf` is 900s in TB 2.0 and 18000s elsewhere.
        # Passing the selected directory makes that resolution exact instead of
        # a guess it would refuse to make.
        if tasks_dir:
            env[TASKS_DIR_ENV] = str(tasks_dir)
        # The adapter runs inside the harbor subprocess, so the only channel
        # from this flag to `~/.osa/config.toml` and `~/.osa/.env` is the
        # environment. Set only when pinned -- an unset key must leave OSA's own
        # resolution order untouched rather than silently defaulting the tier.
        if args.effort:
            env["OSA_BENCH_EFFORT"] = args.effort
        if args.ollama_think:
            env["OLLAMA_THINK"] = args.ollama_think
        # The agent-phase multiplier, forwarded so the ADAPTER can scale the
        # driver's own hardcoded 1800s deadline. Harbor's multipliers never
        # reached it -- see `osa_agent.driver_run_timeout`. The agent-specific
        # override wins over the global one here for the same reason Harbor
        # applies it that way.
        eff_mult = args.agent_timeout_multiplier or args.timeout_multiplier
        if eff_mult:
            env["OSA_BENCH_TIMEOUT_MULTIPLIER"] = str(eff_mult)

        log(f"run_id={run_id}  {len(chosen) or args.limit or 'all'} task(s)")
        log(" ".join(cmd))
        (out / "config.json").write_text(json.dumps(config, indent=2) + "\n")
        rc = subprocess.run(cmd, env=env, cwd=str(HERE)).returncode
        config["harbor_exit_code"] = rc

        job_dirs = sorted((out / "harbor").glob("*/"), key=lambda p: p.stat().st_mtime)
        if not job_dirs:
            raise SystemExit(f"harbor produced no job dir under {out / 'harbor'}")
        job_dir = job_dirs[-1]

    config["finished_at"] = datetime.now(timezone.utc).isoformat()
    config["job_dir"] = str(job_dir)

    rows = report_mod.collect(job_dir)
    results = report_mod.build(config=config, rows=rows)
    rj, sm = report_mod.write(results, out)

    a = results["aggregate"]
    log(f"SOLVED {a['tasks_resolved']}/{a['tasks_attempted']} "
        f"({(a['accuracy'] or 0) * 100:.1f}%)")
    log(f"fault owners: {a['fault_owner_counts']}")
    if a["self_inflicted_totals"]:
        log(f"OSA self-inflicted markers: {a['self_inflicted_totals']}")
    log(f"results: {rj}")
    log(f"summary: {sm}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
