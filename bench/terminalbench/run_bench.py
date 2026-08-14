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
    dirty = _git("status", "--porcelain", "--", "lib")
    out["lib_dirty_at_launch"] = bool(dirty)
    out["lib_dirty_files"] = len(dirty.splitlines()) if dirty else 0
    if out.get("built_at") and out.get("head_committed_at"):
        out["built_after_head_commit"] = out["built_at"] > out["head_committed_at"]
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
    run.add_argument("--agent-timeout-multiplier", type=float, default=None)
    run.add_argument("--host-provider", action="store_true", default=True,
                     help="let the container reach a model provider on the host "
                          "(local Ollama). On by default")
    run.add_argument("--no-host-provider", dest="host_provider", action="store_false")
    run.add_argument("--install-only", action="store_true",
                     help="install OSA into each container and stop: a fast "
                          "compatibility check that costs no tokens")
    run.add_argument("--report-only", metavar="JOB_DIR",
                     help="skip running; just re-report an existing harbor job dir")

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

    if args.probe:
        probe = probeset_mod.get(args.dataset_key)
        args.tasks = list(probe.tasks)
        args.difficulty = None
        args.limit = None

    tasks_dir = local_tasks_dir(ds)
    chosen, dataset_size = select_tasks(args, ds)

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
        "tasks_requested": chosen,
        "difficulty_filter": args.difficulty,
        "n_concurrent": args.n_concurrent,
        "install_only": args.install_only,
        "harbor_version": harbor_version(),
        # WHICH BUILD THIS MEASURED. Without it a results file cannot be
        # attributed to any particular code, which has already voided one
        # ablation. See `artifact_provenance`.
        "artifact": artifact_provenance(),
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
        if args.agent_timeout_multiplier:
            cmd += ["--agent-timeout-multiplier", str(args.agent_timeout_multiplier)]
        if args.install_only:
            cmd += ["--install-only"]
        if args.host_provider and args.agent == "osa":
            cmd += ["--extra-docker-compose", str(HERE / "compose-host-provider.yaml")]

        env = os.environ.copy()
        env["PYTHONPATH"] = str(HERE) + os.pathsep + env.get("PYTHONPATH", "")

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
