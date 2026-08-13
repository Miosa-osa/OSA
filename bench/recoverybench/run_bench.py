#!/usr/bin/env python3
"""Recovery-Bench runner for OSA — the fresh/corrupted delta.

Recovery-Bench measures one thing that no other agent benchmark measures: how
much of an agent's competence survives being started on a machine that a
previous agent already broke. The published result is that it survives badly
(26.3% fresh -> 11.2% corrupted, averaged over models) and — the part that
matters — that the *rankings reorder*. Recovery is therefore a separate axis
from raw capability, which makes it the sharpest instrument available for
measuring a harness rather than a model.

    # one-time: shared initial traces (the fixed corruption source)
    ./fetch_lfs.py

    # what would run, and why
    ./run_bench.py --list

    # the real thing: both arms, same tasks, same model
    ./run_bench.py --limit 6

    # one arm only (e.g. to resume after a crash)
    ./run_bench.py --tasks raman-fitting --arms corrupted

--------------------------------------------------------------------------
The experimental design, and the ways it can go wrong
--------------------------------------------------------------------------

Fresh arm      OSA on task T in a pristine container.
Corrupted arm  OSA on task T in a container where a weaker model's failed
               command sequence has been replayed first.

Held fixed across the arms: the task, the image, the verifier, the timeouts,
the OSA release binary, and **the model**. The only independent variable is the
starting state. ``delta = corrupted_accuracy - fresh_accuracy`` is the number
this harness exists to produce; neither arm's absolute score is the deliverable.

Three ways this measurement can silently lie, all of which are checked:

1. **The two arms run different task sets.** Then the delta is a task-difficulty
   artefact. Guarded: both arms are handed one identical task list, and the
   reporter recomputes the delta over the *intersection* of tasks that actually
   produced a result in both arms.
2. **The corruption did not happen.** A replay that found no commands makes the
   corrupted arm a second fresh run, which shrinks the delta toward zero and
   flatters OSA. Guarded: ``recovery_replay_commands`` is required to be > 0 or
   the trial is dropped from the corrupted arm and counted as invalid.
3. **Harness faults are pooled with model failures.** OSA failing to boot is not
   OSA failing to recover. Guarded: fault attribution is inherited from
   ``bench/terminalbench/report.py`` and a harness-adjusted delta is reported
   next to the raw one.

Only tasks the weak agent *failed* have a corrupted state to restore, so the
task universe is those 64 of 89, not all 89. That is Recovery-Bench's own
definition, not a shortcut taken here.
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
TBENCH = HERE.parent / "terminalbench"
UPSTREAM = HERE / "upstream"

for _p in (HERE, TBENCH, UPSTREAM):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

import delta_report as report_mod  # noqa: E402

# ERTS in the OSA release is built on debian-bookworm (glibc 2.36) and cannot
# start on bullseye (glibc 2.31). These two tasks are out of reach for the
# artefact, not for OSA; see bench/terminalbench/README.md. Excluded explicitly
# rather than allowed to fail and pollute the harness-fault rate.
GLIBC_UNSUPPORTED = {"qemu-startup", "qemu-alpine-ssh"}

ARMS = ("fresh", "corrupted")


def log(msg: str) -> None:
    print(f"[recovery {datetime.now().strftime('%H:%M:%S')}] {msg}", flush=True)


def harbor_bin() -> Path:
    venv = TBENCH / ".venv" / "bin" / "harbor"
    if not venv.exists():
        raise SystemExit(
            f"{venv} missing. bench/recoverybench reuses bench/terminalbench's venv:\n"
            f"  python3 -m venv {TBENCH / '.venv'} && {TBENCH / '.venv/bin/pip'} install harbor"
        )
    return venv


def harbor_version() -> str:
    try:
        return subprocess.run(
            [str(harbor_bin()), "--version"], capture_output=True, text=True, timeout=60
        ).stdout.strip()
    except Exception:  # noqa: BLE001
        return "?"


def traces_dir(explicit: str | None) -> Path:
    if explicit:
        p = Path(explicit)
        if not p.is_dir():
            raise SystemExit(f"--traces {p} is not a directory")
        return p
    found = sorted((UPSTREAM / "runs").glob("initial-*"))
    if not found:
        raise SystemExit(
            "No initial traces found under upstream/runs/.\n"
            "Clone upstream and fetch the shared traces:\n"
            "  GIT_LFS_SKIP_SMUDGE=1 git clone --depth 1 "
            "https://github.com/letta-ai/recovery-bench.git upstream\n"
            "  ./fetch_lfs.py"
        )
    return found[0]


def tasks_dir() -> Path:
    p = os.environ.get("OSA_TBENCH_TASKS_DIR")
    if p and Path(p).is_dir():
        return Path(p)
    default = TBENCH / "tasks" / "terminal-bench-2"
    if not default.is_dir():
        raise SystemExit(
            f"Terminal-Bench task clone missing at {default}. Recovery-Bench "
            "runs the same task definitions:\n"
            "  git clone --depth 1 "
            f"https://github.com/harbor-framework/terminal-bench-2 {default}"
        )
    return default


def task_difficulty(name: str) -> str | None:
    toml_path = tasks_dir() / name / "task.toml"
    if not toml_path.exists():
        return None
    try:
        import tomllib

        return (tomllib.loads(toml_path.read_text()).get("metadata") or {}).get("difficulty")
    except Exception:  # noqa: BLE001
        return None


def corrupted_universe(traces: Path) -> list[dict]:
    """The tasks that have a corrupted state to restore, with replay sizes.

    A task qualifies only if the weak agent failed it (reward == 0) *and* its
    trajectory yields at least one replayable command. A failed run that
    produced no commands leaves the machine pristine, so there is nothing to
    recover from and including it would dilute the delta.
    """
    from recovery_bench.replay import extract_commands, extract_messages
    from recovery_bench.utils import get_unsolved_tasks

    unsolved = set(get_unsolved_tasks(str(traces)))
    rows = []
    for d in sorted(traces.iterdir()):
        if not d.is_dir():
            continue
        name = d.name[9:] if len(d.name) > 9 and d.name[8] == "-" else d.name
        name = name.rsplit("__", 1)[0]
        if name not in unsolved:
            continue
        cmds = extract_commands(d)
        if not cmds:
            continue
        rows.append(
            {
                "task_name": name,
                "replay_commands": len(cmds),
                "prior_messages": len(extract_messages(d)),
                "difficulty": task_difficulty(name),
                "glibc_unsupported": name in GLIBC_UNSUPPORTED,
            }
        )
    return rows


def select(args, universe: list[dict]) -> list[dict]:
    rows = [r for r in universe if not r["glibc_unsupported"]]
    if args.difficulty:
        rows = [r for r in rows if r["difficulty"] == args.difficulty]
    if args.tasks:
        by_name = {r["task_name"]: r for r in rows}
        missing = [t for t in args.tasks if t not in by_name]
        if missing:
            raise SystemExit(
                f"not in the corrupted universe (weak agent solved them, they "
                f"have no replayable commands, or they are glibc-unsupported): {missing}"
            )
        return [by_name[t] for t in args.tasks]
    rows.sort(key=lambda r: (r["replay_commands"], r["task_name"]))
    if args.max_replay:
        rows = [r for r in rows if r["replay_commands"] <= args.max_replay]
    if not args.limit or args.limit >= len(rows):
        return rows

    # Stratified across the replay-length distribution, NOT the cheapest N.
    #
    # This matters more than it looks. The number of replayed commands is a
    # proxy for how badly the machine was left, and it is strongly correlated
    # with wall-clock cost. Taking the cheapest N tasks therefore selects the
    # *least corrupted* tasks in the universe — `largest-eigenval`, the
    # 2-command minimum, replays nothing but two verification prints and leaves
    # an essentially pristine container. A subset built that way would drive the
    # measured delta toward zero and flatter OSA, which is exactly the direction
    # of error this harness must not take by default.
    #
    # Evenly spaced indices over the sorted list keep the low, middle and high
    # ends of the corruption distribution represented. Deterministic, so a run
    # is reproducible from its config.
    n, k = len(rows), args.limit
    idx = sorted({round(i * (n - 1) / (k - 1)) if k > 1 else 0 for i in range(k)})
    return [rows[i] for i in idx]


def run_arm(
    arm: str,
    task_names: list[str],
    out: Path,
    args,
    traces: Path,
) -> Path | None:
    """Run one arm through Harbor and return its job directory."""
    arm_out = out / arm
    arm_out.mkdir(parents=True, exist_ok=True)

    if arm == "fresh":
        # The unmodified Terminal-Bench adapter. Using the same class the fresh
        # benchmark uses is what makes the fresh arm a true control.
        agent_spec = "osa_agent:OsaAgent"
    elif args.message_mode == "full":
        agent_spec = "recovery_osa_agent:RecoveryOsaFullContext"
    else:
        agent_spec = "recovery_osa_agent:RecoveryOsa"

    cmd = [
        str(harbor_bin()), "run",
        "-a", agent_spec,
        "-y",
        "-o", str(arm_out / "harbor"),
        "-n", str(args.n_concurrent),
        "-p", str(tasks_dir()),
    ]
    for t in task_names:
        cmd += ["-i", t]
    if args.model:
        cmd += ["-m", args.model]
    if args.agent_timeout_multiplier:
        cmd += ["--agent-timeout-multiplier", str(args.agent_timeout_multiplier)]
    if args.install_only:
        cmd += ["--install-only"]
    if args.host_provider:
        cmd += ["--extra-docker-compose", str(TBENCH / "compose-host-provider.yaml")]
    if arm == "corrupted":
        # Replay happens inside agent setup and can take minutes on a long
        # trajectory; the default setup timeout is sized for an install.
        cmd += ["--agent-setup-timeout-multiplier", str(args.setup_timeout_multiplier)]
        cmd += ["--agent-kwarg", f"message_mode={args.message_mode}"]

    env = os.environ.copy()
    env["PYTHONPATH"] = os.pathsep.join(
        [str(HERE), str(TBENCH), str(UPSTREAM), env.get("PYTHONPATH", "")]
    )
    # How RecoveryMixin finds the failed trajectory for each task.
    env["TRAJECTORY_FOLDER"] = str(traces)

    log(f"--- ARM: {arm} ---  {len(task_names)} task(s)  agent={agent_spec}")
    log(" ".join(cmd))
    rc = subprocess.run(cmd, env=env, cwd=str(HERE)).returncode
    log(f"arm {arm} harbor exit={rc}")

    job_dirs = sorted((arm_out / "harbor").glob("*/"), key=lambda p: p.stat().st_mtime)
    if not job_dirs:
        log(f"arm {arm}: harbor produced no job dir")
        return None
    return job_dirs[-1]


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--run-id", default=None)
    ap.add_argument("--traces", default=None, help="initial-traces dir (default: upstream/runs/initial-*)")
    ap.add_argument("--list", action="store_true", help="print the selected tasks and exit")

    sel = ap.add_argument_group("task selection")
    sel.add_argument("--tasks", nargs="*", default=None)
    sel.add_argument("--difficulty", default=None, choices=["easy", "medium", "hard"])
    sel.add_argument("--limit", type=int, default=None)
    sel.add_argument("--max-replay", type=int, default=None,
                     help="skip tasks whose trajectory has more than N commands")

    run = ap.add_argument_group("execution")
    run.add_argument("--arms", nargs="*", default=list(ARMS), choices=list(ARMS))
    run.add_argument("--model", default=None)
    run.add_argument("--message-mode", default="none", choices=["none", "summary", "full"],
                     help="what the recovery agent is told about the failed attempt. "
                          "'none' = corrupted machine only, which isolates state "
                          "recovery from context pollution")
    run.add_argument("--n-concurrent", type=int, default=2)
    run.add_argument("--agent-timeout-multiplier", type=float, default=None)
    run.add_argument("--setup-timeout-multiplier", type=float, default=3.0)
    run.add_argument("--host-provider", action="store_true", default=True)
    run.add_argument("--no-host-provider", dest="host_provider", action="store_false")
    run.add_argument("--install-only", action="store_true")
    run.add_argument("--report-only", metavar="RUN_DIR",
                     help="skip running; rebuild the delta report from an existing run dir")

    args = ap.parse_args()

    traces = traces_dir(args.traces)
    universe = corrupted_universe(traces)
    chosen = select(args, universe)
    task_names = [r["task_name"] for r in chosen]

    if args.list:
        print(f"traces: {traces}")
        print(f"corrupted universe: {len(universe)} tasks "
              f"({sum(1 for r in universe if r['glibc_unsupported'])} glibc-unsupported)")
        print(f"selected: {len(chosen)}")
        print(f"{'task':40} {'diff':7} {'cmds':>5} {'msgs':>5}")
        for r in chosen:
            print(f"{r['task_name']:40} {str(r['difficulty']):7} "
                  f"{r['replay_commands']:5} {r['prior_messages']:5}")
        return 0

    if not task_names:
        raise SystemExit("no tasks selected")

    run_id = args.run_id or f"recovery-{time.strftime('%Y%m%d-%H%M%S')}"
    out = HERE / "runs" / run_id
    out.mkdir(parents=True, exist_ok=True)

    config = {
        "run_id": run_id,
        "benchmark": "recovery-bench",
        "dataset": "terminal-bench@2.0",
        "dataset_size": report_mod.TERMINAL_BENCH_2_SIZE,
        "traces_dir": str(traces),
        "initial_agent": "terminus-2 / claude-haiku-4-5 (upstream shared traces)",
        "corrupted_universe_size": len(universe),
        "tasks_requested": task_names,
        "task_meta": {r["task_name"]: r for r in chosen},
        "arms": args.arms,
        "model": args.model,
        "message_mode": args.message_mode,
        "n_concurrent": args.n_concurrent,
        "install_only": args.install_only,
        "harbor_version": harbor_version(),
        "osa_commit": subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True,
            cwd=str(HERE),
        ).stdout.strip(),
        "release_built_at": (
            datetime.fromtimestamp(
                (TBENCH / "dist" / "osa-release-linux-x86_64.tar.gz").stat().st_mtime,
                timezone.utc,
            ).isoformat()
            if (TBENCH / "dist" / "osa-release-linux-x86_64.tar.gz").exists()
            else None
        ),
        "started_at": datetime.now(timezone.utc).isoformat(),
        "host": {"platform": platform.platform(), "python": platform.python_version()},
    }

    if args.report_only:
        out = Path(args.report_only)
        try:
            config = json.loads((out / "config.json").read_text())
        except OSError:
            pass
        job_dirs = {}
        for arm in ARMS:
            found = sorted((out / arm / "harbor").glob("*/"), key=lambda p: p.stat().st_mtime)
            if found:
                job_dirs[arm] = found[-1]
    else:
        (out / "config.json").write_text(json.dumps(config, indent=2) + "\n")
        job_dirs = {}
        for arm in args.arms:
            jd = run_arm(arm, task_names, out, args, traces)
            if jd:
                job_dirs[arm] = jd

    config["finished_at"] = datetime.now(timezone.utc).isoformat()
    config["job_dirs"] = {k: str(v) for k, v in job_dirs.items()}
    (out / "config.json").write_text(json.dumps(config, indent=2) + "\n")

    arm_rows = {arm: report_mod.collect_arm(jd, arm) for arm, jd in job_dirs.items()}
    results = report_mod.build_delta(config=config, arm_rows=arm_rows)
    rj, sm = report_mod.write(results, out)

    d = results["delta"]
    for arm in ARMS:
        a = results["arms"].get(arm)
        if a:
            log(f"{arm:10} {a['tasks_resolved']}/{a['tasks_attempted']} "
                f"({(a['accuracy'] or 0) * 100:.1f}%)")
    log(f"PAIRED n={d['paired_n']}  fresh={_pc(d['fresh_accuracy'])} "
        f"corrupted={_pc(d['corrupted_accuracy'])}  DELTA={_pc(d['delta'])}")
    log(f"results: {rj}")
    log(f"summary: {sm}")
    return 0


def _pc(v):
    return "n/a" if v is None else f"{v * 100:.1f}%"


if __name__ == "__main__":
    sys.exit(main())
