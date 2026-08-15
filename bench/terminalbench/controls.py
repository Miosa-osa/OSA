#!/usr/bin/env python3
"""oracle / nop controls for Harbor datasets, and the gate that enforces them.

WHY
---
`bench/swebench` already refuses to print a rate for a run whose controls did
not pass: gold-apply must score 100% and empty-patch 0%. Harbor needs the same
discipline and needs it more. An independent analysis of 5,700+ Harbor runs
reports 53% of runs erroring out and roughly one correct result in five
misclassified — and 42% of 1,526 agent+model combinations failing the trivial
`hello-world` task. Whether that is Harbor or the analyst's operation of it is
unclear, and that is exactly the point: **we cannot tell our own infrastructure
noise from a harness delta unless we measure the noise.**

The two controls are:

  oracle  runs the task's own reference solution. It should solve EVERYTHING.
          Anything it misses is a task that is broken *on this machine* — bad
          image, missing credential, timeout too tight for this hardware — and
          an OSA failure on that task is not evidence about OSA.
  nop     does nothing at all. It should solve NOTHING. Anything it "solves" is
          a task whose verifier passes on the untouched starting state, i.e. a
          free point for every agent, which inflates every score equally and
          silently.

Neither control calls a model, so both are free. There is no budget argument
for skipping them.

USE
---
    ./controls.py run  --dataset-key tb2.1                 # both controls, all tasks
    ./controls.py run  --dataset-key harbor-index --limit 8
    ./controls.py status                                    # what has been measured
    ./controls.py gate runs/osa-something                   # exit 1 if unsound

WHAT THE GATE CHECKS
--------------------
Per-task, not per-dataset. A dataset-level "oracle scored 96%" says nothing
about whether the four tasks *your run happened to use* were among the sound
ones. So the gate resolves the run's own task list and demands, for each task in
it, an oracle pass and a nop non-pass. A task with no control observation at all
is a BLOCK, not a pass: unmeasured is not the same as fine.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import datasets as datasets_mod  # noqa: E402

CONTROLS_DIR = HERE / "runs" / "_controls"

#: An oracle that misses a task means the task is broken here. We do not accept
#: "close enough" at the dataset level, but we do record it rather than crashing
#: so the per-task detail survives.
ORACLE_TARGET = 1.0
NOP_TARGET = 0.0


def log(msg: str) -> None:
    print(f"[controls {datetime.now().strftime('%H:%M:%S')}] {msg}", flush=True)


def harbor_bin() -> Path:
    p = HERE / ".venv" / "bin" / "harbor"
    if not p.exists():
        raise SystemExit(f"{p} missing")
    return p


def _harbor_version() -> str:
    try:
        return subprocess.run(
            [str(harbor_bin()), "--version"], capture_output=True, text=True, timeout=60
        ).stdout.strip()
    except Exception:  # noqa: BLE001
        return "?"


def _read_job(job_dir: Path) -> dict[str, dict]:
    """task name (without dataset prefix) -> {reward, evidence}, from a job dir.

    The evidence path is kept because a failed control is a bug report, not a
    number: the useful output of "oracle scored 0 on build-cython-ext" is the
    verifier's own stdout, and it is 20 directories deep.
    """
    out: dict[str, dict] = {}
    for rp in sorted(job_dir.glob("*/result.json")):
        try:
            r = json.loads(rp.read_text())
        except (json.JSONDecodeError, OSError):
            continue
        name = r.get("task_name")
        if not name:
            continue
        rewards = (r.get("verifier_result") or {}).get("rewards") or {}
        out[name.split("/")[-1]] = {
            "reward": rewards.get("reward"),
            "trial_dir": str(rp.parent),
            "exception": (r.get("exception_info") or {}).get("exception_type"),
        }
    return out


def _run_agent(ds, agent: str, tasks: list[str], out_dir: Path, n: int) -> Path:
    cmd = [
        str(harbor_bin()), "run", "-a", agent, "-y",
        "-p", str(ds.path), "-o", str(out_dir), "-n", str(n),
    ]
    for t in tasks:
        cmd += ["-i", t]
    log(" ".join(cmd[:9]) + f" ... ({len(tasks)} tasks)")
    subprocess.run(cmd, cwd=str(HERE))
    jobs = sorted(out_dir.glob("*/"), key=lambda p: p.stat().st_mtime)
    if not jobs:
        raise SystemExit(f"harbor produced no job dir under {out_dir}")
    return jobs[-1]


def controls_path(dataset_key: str) -> Path:
    return CONTROLS_DIR / dataset_key / "controls.json"


def load_controls(dataset_key: str) -> dict | None:
    p = controls_path(dataset_key)
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text())
    except (json.JSONDecodeError, OSError):
        return None


def merge_controls(dataset_key: str, agent: str, rewards: dict, meta: dict) -> dict:
    """Fold a new control observation into the dataset's control file.

    Merged rather than replaced so a dataset can be validated in affordable
    slices: eight tasks today, eight more tomorrow, and the gate sees the union.
    Each task records WHEN it was observed, so a stale observation can be found.
    """
    doc = load_controls(dataset_key) or {
        "dataset_key": dataset_key,
        "observations": {},
        "history": [],
    }
    obs = doc["observations"]
    stamp = datetime.now(timezone.utc).isoformat()
    for task, row in rewards.items():
        entry = obs.setdefault(task, {})
        entry[agent] = {**row, "observed_at": stamp}
    doc["history"].append({"agent": agent, "n_tasks": len(rewards), "at": stamp, **meta})
    p = controls_path(dataset_key)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(doc, indent=2) + "\n")
    return doc


def _miss_kind(entry: dict) -> str:
    """Why an oracle miss happened — and these are NOT the same problem.

    `graded_wrong`  the verifier ran and returned < 1.0. The task itself does
                    not pass with its own reference solution: broken task, or
                    broken here.
    `infrastructure` the trial never produced a reward at all — a Harbor-level
                    exception. `torch-pipeline-parallelism` is the specimen:
                    its verifier spent its entire 900s budget pulling ~2.5 GB of
                    CUDA wheels (torch 825 MB, cudnn 544 MB, cublas 375 MB) and
                    hit VerifierTimeoutError before running a single test. The
                    task is fine; this box's bandwidth is not.

    Pooling them would be the exact mistake the whole harness is built to avoid.
    A `graded_wrong` task should be excluded from any denominator; an
    `infrastructure` miss should be RETRIED, and if it keeps happening it is a
    fact about the machine that belongs in the manifest, not a fact about tasks.

    KNOWN LIMITATION, and it is not a small one. This split is made on "was a
    reward written", which is a proxy for the thing we care about, not the thing
    itself. A task whose reference solution fetches from a live third-party
    package index will fail *outside* the container's control and still produce
    a written reward of 0, so it lands in `graded_wrong` while really being an
    environment failure. `mcmc-sampling-stan` is the specimen: its `solve.sh`
    installs rstan from CRAN at solve time, CRAN did not serve `StanHeaders` and
    `RcppParallel`, the R script was never written, and four of six tests failed
    on the missing artefact. Nothing about that task is broken.

    The operational conclusion is the same either way — exclude it, do not read
    an OSA failure on it as evidence — so the split is still worth making. But
    do not read `graded_wrong` as "upstream shipped a broken task" without
    opening the oracle log first. Distinguishing the two properly would mean
    classifying the oracle's own stderr, which is a heuristic we have not earned
    yet.
    """
    if entry.get("exception"):
        return "infrastructure"
    return "graded_wrong" if entry.get("reward") is not None else "infrastructure"


def summarise(doc: dict) -> dict:
    obs = doc.get("observations") or {}
    oracle = {t: v["oracle"]["reward"] for t, v in obs.items() if "oracle" in v}
    nop = {t: v["nop"]["reward"] for t, v in obs.items() if "nop" in v}
    o_pass = [t for t, r in oracle.items() if r is not None and r >= 1.0]
    n_pass = [t for t, r in nop.items() if r is not None and r >= 1.0]
    misses = sorted(set(oracle) - set(o_pass))
    by_kind: dict[str, list[str]] = {}
    for t in misses:
        by_kind.setdefault(_miss_kind(obs[t]["oracle"]), []).append(t)
    return {
        "oracle_observed": len(oracle),
        "oracle_solved": len(o_pass),
        "oracle_rate": round(len(o_pass) / len(oracle), 4) if oracle else None,
        "oracle_failed_tasks": misses,
        "oracle_failed_by_kind": by_kind,
        "nop_observed": len(nop),
        "nop_solved": len(n_pass),
        "nop_rate": round(len(n_pass) / len(nop), 4) if nop else None,
        "nop_solved_tasks": sorted(n_pass),
    }


# ---------------------------------------------------------------------------


def cmd_run(args) -> int:
    ds = datasets_mod.get(args.dataset_key)
    if not ds.present:
        raise SystemExit(f"{ds.key} is not on disk. ./datasets.py sync {ds.key}")

    # One definition, shared with run_bench.py. See datasets.have_judge_key.
    have_judge_key = datasets_mod.have_judge_key()
    tasks = args.tasks or datasets_mod.gradeable_tasks(
        ds, have_judge_key=have_judge_key
    )
    skipped = sorted(set(ds.task_names()) - set(tasks))
    if args.limit:
        tasks = tasks[: args.limit]

    if skipped and not args.tasks:
        log(
            f"skipping {len(skipped)} LLM-judge-graded task(s): no "
            f"ANTHROPIC_API_KEY, so their verifier cannot run at all. "
            f"THIS CHANGES THE DENOMINATOR — recorded in controls.json."
        )

    run_id = args.run_id or f"{ds.key}-{time.strftime('%Y%m%d-%H%M%S')}"
    out = CONTROLS_DIR / ds.key / run_id
    out.mkdir(parents=True, exist_ok=True)

    meta = {
        "run_id": run_id,
        "dataset_key": ds.key,
        "dataset_label": ds.label,
        "dataset_path": str(ds.path),
        "dataset_size": ds.on_disk_size(),
        "harbor_version": _harbor_version(),
        "have_judge_key": have_judge_key,
        "judge_skipped_tasks": skipped if not args.tasks else [],
        "host": {"platform": platform.platform()},
    }

    for agent in args.agents:
        job = _run_agent(ds, agent, tasks, out / agent, args.n_concurrent)
        rewards = _read_job(job)
        log(f"{agent}: {len(rewards)}/{len(tasks)} trials produced a result")
        doc = merge_controls(ds.key, agent, rewards, {**meta, "job_dir": str(job)})

    s = summarise(doc)
    log(f"oracle {s['oracle_solved']}/{s['oracle_observed']}  "
        f"nop {s['nop_solved']}/{s['nop_observed']}")
    print(json.dumps(s, indent=2))
    print(f"\ncontrols file: {controls_path(ds.key)}")
    return 0


def cmd_import(args) -> int:
    """Fold an existing Harbor job directory into a dataset's control file.

    `run` only writes controls.json when a whole agent phase finishes, and an
    oracle sweep over 89 tasks takes hours on one box — several tasks
    (`mteb-retrieve`, `torch-pipeline-parallelism`, `caffe-cifar-10`) pull
    multi-GB images and their reference solutions run for over an hour. If that
    is interrupted, every completed trial is on disk and none of it counts.

    This makes those trials count. It is also how a sweep run in slices gets
    folded together, and it is idempotent: re-importing the same job dir
    overwrites the same observations with the same values.
    """
    ds = datasets_mod.get(args.dataset_key)
    job = Path(args.job_dir)
    if not job.is_dir():
        raise SystemExit(f"{job} is not a directory")
    rewards = _read_job(job)
    if not rewards:
        raise SystemExit(f"no completed trials under {job}")
    doc = merge_controls(
        ds.key, args.agent, rewards,
        {"imported_from": str(job), "partial": True,
         "harbor_version": _harbor_version()},
    )
    log(f"imported {len(rewards)} {args.agent} observation(s) for {ds.key}")
    print(json.dumps(summarise(doc), indent=2))
    print(f"\ncontrols file: {controls_path(ds.key)}")
    return 0


def cmd_status(args) -> int:
    keys = [args.dataset_key] if args.dataset_key else list(datasets_mod.ORDER)
    print(f"{'dataset':14s} {'oracle':>14s} {'nop':>12s}   verdict")
    for k in keys:
        doc = load_controls(k)
        if not doc:
            print(f"{k:14s} {'—':>14s} {'—':>12s}   NOT MEASURED")
            continue
        s = summarise(doc)
        o = f"{s['oracle_solved']}/{s['oracle_observed']}"
        n = f"{s['nop_solved']}/{s['nop_observed']}"
        if not s["oracle_observed"]:
            v = "no oracle observation"
        elif s["oracle_rate"] < ORACLE_TARGET:
            v = f"SUSPECT — oracle {s['oracle_rate']*100:.1f}%"
        elif s["nop_observed"] and s["nop_rate"] > NOP_TARGET:
            v = f"SUSPECT — nop solves {s['nop_solved']}"
        elif not s["nop_observed"]:
            v = "oracle clean, nop not run"
        else:
            v = "clean"
        print(f"{k:14s} {o:>14s} {n:>12s}   {v}")
        for kind, tasks in sorted((s.get("oracle_failed_by_kind") or {}).items()):
            label = ("oracle graded < 1.0 (task is broken here)"
                     if kind == "graded_wrong"
                     else "oracle lost to infrastructure (RETRY these)")
            print(f"{'':14s}   {label}: {', '.join(tasks)}")
        if s["nop_solved_tasks"]:
            print(f"{'':14s}   nop solved:    {', '.join(s['nop_solved_tasks'])}")
    return 0


def cmd_gate(args) -> int:
    run_path = Path(args.run)
    if run_path.is_dir():
        run_path = run_path / "results.json"
    doc = json.loads(run_path.read_text())
    cfg = doc.get("config") or {}
    key = cfg.get("dataset_key")
    if not key or key == "legacy":
        print("BLOCK  no dataset_key on this run — it predates datasets.py, so "
              "the task set it used cannot be tied to a control observation.")
        return 1

    run_tasks = sorted({t["task_name"].split("/")[-1] for t in doc.get("tasks") or []})
    controls = load_controls(key)
    if not controls:
        print(f"BLOCK  no controls have ever been run for dataset '{key}'.")
        print(f"       ./controls.py run --dataset-key {key}")
        return 1

    obs = controls["observations"]
    unmeasured, oracle_failed, oracle_lost, nop_solved = [], [], [], []
    for t in run_tasks:
        e = obs.get(t) or {}
        if "oracle" not in e:
            unmeasured.append(t)
            continue
        r = e["oracle"].get("reward")
        if r is None or r < 1.0:
            # A task the oracle was never able to attempt cleanly is not the
            # same as a task the oracle attempted and failed. Both block, but
            # they tell you to do different things.
            if _miss_kind(e["oracle"]) == "infrastructure":
                oracle_lost.append(t)
            else:
                oracle_failed.append(t)
        if "nop" in e:
            nr = e["nop"].get("reward")
            if nr is not None and nr >= 1.0:
                nop_solved.append(t)

    blocks = 0
    print(f"dataset '{key}', {len(run_tasks)} task(s) in this run")
    if unmeasured:
        blocks += 1
        print(f"BLOCK  {len(unmeasured)} task(s) have NO oracle observation: "
              f"{', '.join(unmeasured)}")
        print("       Unmeasured is not the same as sound.")
    if oracle_failed:
        blocks += 1
        print(f"BLOCK  oracle FAILED on {len(oracle_failed)} task(s): "
              f"{', '.join(oracle_failed)}")
        print("       These tasks are broken on this machine. An OSA failure on "
              "them is not evidence about OSA.")
        for t in oracle_failed:
            ev = (obs[t]["oracle"]).get("trial_dir")
            if ev:
                print(f"         {t}: {ev}/verifier/test-stdout.txt")
    if oracle_lost:
        blocks += 1
        print(f"BLOCK  the oracle never got a verdict on {len(oracle_lost)} "
              f"task(s): {', '.join(oracle_lost)}")
        for t in oracle_lost:
            print(f"         {t}: {(obs[t]['oracle']).get('exception') or 'no reward written'}")
        print("       This is THIS MACHINE failing, not the task. Re-run the "
              "control for these before reading anything into an OSA result on "
              "them — and if it keeps happening, it belongs in the manifest as "
              "a property of the host.")
    if nop_solved:
        blocks += 1
        print(f"BLOCK  nop SOLVED {len(nop_solved)} task(s): {', '.join(nop_solved)}")
        print("       Their verifier passes on the untouched starting state, so "
              "they are free points for every agent.")
    nop_seen = sum(1 for t in run_tasks if "nop" in (obs.get(t) or {}))
    if nop_seen < len(run_tasks):
        print(f"WARN   only {nop_seen}/{len(run_tasks)} task(s) have a nop "
              "observation. Free-point contamination is unmeasured on the rest.")

    sys.stdout.flush()  # or the stderr verdict overtakes the findings above it
    if blocks:
        print(f"\nNOT QUOTABLE: {blocks} blocking control finding(s).", file=sys.stderr)
        return 1
    if nop_seen == len(run_tasks):
        verdict = ("Controls pass: oracle solved every task in this run, and nop "
                   "solved none.")
    else:
        # Not the same statement, and it must not be printed as if it were.
        verdict = ("Controls pass on the oracle side: it solved every task in "
                   f"this run. The nop side is only measured on {nop_seen}/"
                   f"{len(run_tasks)}, so free-point contamination is not ruled "
                   "out — say so if you quote this.")
    print("\n" + verdict, file=sys.stderr)
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("run", help="run the controls on a dataset")
    p.add_argument("--dataset-key", required=True, choices=list(datasets_mod.ORDER))
    p.add_argument("--agents", nargs="+", default=["oracle", "nop"])
    p.add_argument("--tasks", nargs="*", default=None)
    p.add_argument("--limit", type=int, default=None)
    p.add_argument("--n-concurrent", type=int, default=4)
    p.add_argument("--run-id", default=None)
    p.set_defaults(fn=cmd_run)

    p = sub.add_parser("import", help="fold an existing (or partial) Harbor "
                                      "job dir into the control file")
    p.add_argument("--dataset-key", required=True, choices=list(datasets_mod.ORDER))
    p.add_argument("--agent", required=True, choices=["oracle", "nop"])
    p.add_argument("job_dir")
    p.set_defaults(fn=cmd_import)

    p = sub.add_parser("status", help="what has been measured")
    p.add_argument("--dataset-key", default=None)
    p.set_defaults(fn=cmd_status)

    p = sub.add_parser("gate", help="exit 1 if a run's tasks are not control-clean")
    p.add_argument("run")
    p.set_defaults(fn=cmd_gate)

    args = ap.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
