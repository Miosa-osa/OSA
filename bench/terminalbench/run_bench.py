#!/usr/bin/env python3
"""Terminal-Bench 2.0 runner for OSA.

Harbor is the harness; this is the thin layer around it that (a) supplies the
flags OSA needs, and (b) turns Harbor's per-trial output into one results file
with the honesty flags attached, in the same shape as bench/swebench.

    # sanity: the oracle solutions must score 1.0, or the harness is broken
    ./run_bench.py --agent oracle --tasks regex-log

    # OSA on a named task
    ./run_bench.py --agent osa --tasks regex-log

    # OSA on the hard end
    ./run_bench.py --agent osa --difficulty hard --limit 8

Run `--agent oracle` first on any new machine. It should score 1.0 on every
task; if it does not, the harness is broken rather than the agent.
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

import report as report_mod  # noqa: E402

TASKS_DIR_ENV = "OSA_TBENCH_TASKS_DIR"
DEFAULT_DATASET = "terminal-bench@2.0"


def log(msg: str) -> None:
    print(f"[tbench {datetime.now().strftime('%H:%M:%S')}] {msg}", flush=True)


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


def local_tasks_dir() -> Path | None:
    """A local clone of harbor-framework/terminal-bench-2, if one is configured.

    Using the local clone avoids re-resolving the registry on every run and is
    the only way to filter on task.toml metadata (difficulty), which the Harbor
    CLI does not expose as a flag.
    """
    p = os.environ.get(TASKS_DIR_ENV)
    if p and Path(p).is_dir():
        return Path(p)
    default = HERE / "tasks" / "terminal-bench-2"
    return default if default.is_dir() else None


def read_task_meta(task_dir: Path) -> dict:
    toml_path = task_dir / "task.toml"
    if not toml_path.exists():
        return {}
    try:
        import tomllib

        return tomllib.loads(toml_path.read_text())
    except Exception:  # noqa: BLE001
        return {}


def select_tasks(args) -> tuple[list[str], int]:
    """Return (task names, dataset size).

    Difficulty filtering requires the local clone; without it the only filters
    Harbor itself offers are name globs and a count.
    """
    tasks_dir = local_tasks_dir()
    if tasks_dir is None:
        if args.difficulty:
            raise SystemExit(
                f"--difficulty needs a local task clone. Set {TASKS_DIR_ENV} or:\n"
                f"  git clone --depth 1 https://github.com/harbor-framework/terminal-bench-2 "
                f"{HERE / 'tasks' / 'terminal-bench-2'}"
            )
        return (args.tasks or []), report_mod.TERMINAL_BENCH_2_SIZE

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
    ap.add_argument("--dataset", default=None,
                    help=f"harbor dataset id (default {DEFAULT_DATASET}); "
                         "ignored when a local task clone is used")

    sel = ap.add_argument_group("task selection")
    sel.add_argument("--tasks", nargs="*", default=None, help="task directory names")
    sel.add_argument("--difficulty", default=None, choices=["easy", "medium", "hard"],
                     help="from task.toml [metadata]; needs the local clone")
    sel.add_argument("--limit", type=int, default=None)

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

    tasks_dir = local_tasks_dir()
    chosen, dataset_size = select_tasks(args)

    config = {
        "run_id": run_id,
        "agent": args.agent,
        "model": args.model,
        "dataset": str(tasks_dir) if tasks_dir else (args.dataset or DEFAULT_DATASET),
        "dataset_size": dataset_size,
        "tasks_requested": chosen,
        "difficulty_filter": args.difficulty,
        "n_concurrent": args.n_concurrent,
        "install_only": args.install_only,
        "harbor_version": harbor_version(),
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
            cmd += ["-d", args.dataset or DEFAULT_DATASET]
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
