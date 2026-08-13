#!/usr/bin/env python3
"""Run OSA and its competitors over the SAME Terminal-Bench tasks, same model.

WHY
---
Published leaderboard numbers are not comparable to ours and never will be.
`bench/report/METHODOLOGY.md` establishes why: scaffold alone moves SWE-bench by
11-20 points for a fixed model, labs disagree about the denominator (477 vs 484
vs 500), and the submission checklist forbids pass@k while permitting
best-of-k reported as pass@1. Putting our number next to theirs measures
nothing.

The only honest comparison is one we run ourselves, end to end, with the model
held fixed. That is what this does: one task list, one model, one set of
limits, several harnesses.

WHAT "SAME LIMITS" MEANS HERE
-----------------------------
Only ONE limit is available to every arm: wall clock, from the task's own
`agent.timeout_sec` scaled by `--agent-timeout-multiplier`. Turn caps exist on
some arms (goose `--max-turns`, mini-swe-agent `step_limit`) and not on others
(codex, opencode, OSA have no turn flag at all). Applying a turn cap to the
arms that support it, and not to the arms that do not, would be a difference in
the experiment rather than in the systems, so no turn caps are set and every
arm is bounded identically by the clock. This is recorded in the results as
`limits.turn_cap: null` so nobody has to infer it.

USAGE
-----
    # what can actually run, and why not for the rest
    ./run_h2h.py --list-arms

    # prove the pipeline: one cheap task, every runnable arm
    ./run_h2h.py --run-id smoke --arms osa codex opencode mini-swe-agent \
                 --tasks regex-log

    # the real thing
    ./run_h2h.py --run-id h2h-1 --arms osa codex opencode goose mini-swe-agent \
                 --task-set default6

Arms run SEQUENTIALLY. They share one Ollama daemon and one Docker host;
running them concurrently would let one arm's queueing become another arm's
latency, and wall-clock is one of the things being measured.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import random
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
TBENCH = HERE.parent / "terminalbench"
sys.path.insert(0, str(HERE))

import arms as arms_mod  # noqa: E402
import report_h2h  # noqa: E402

#: Terminal-Bench 2.0. A run over fewer is a pipeline signal, never a score.
DATASET_SIZE = 89

#: Curated task sets. Every one of these images was already resident on this
#: host at authoring time, so a run costs no image pulls -- which matters
#: because the arms must all see the same environment and a mid-run pull
#: failure would silently give one arm a different task set.
#:
#: Selection is DECLARED, not random-with-a-seed-we-mention-afterwards: these
#: were chosen to be (a) locally cached, (b) 900-1800s timeouts so an arm that
#: stalls does not eat the whole night, (c) a spread of difficulty and
#: category, and (d) not the two bullseye tasks (qemu-startup,
#: qemu-alpine-ssh) where OSA's release artefact cannot start at all.
#: A convenience-selected set is a convenience-selected set; calling it a
#: random sample because a seed was passed to a shuffle would be worse.
TASK_SETS = {
    "smoke1": ["regex-log"],
    "default6": [
        "regex-log",                    # medium, 900s,  data-processing
        "sparql-university",            # hard,   900s,  knowledge-graph
        "cancel-async-tasks",           # hard,   900s,  async/concurrency
        "configure-git-webserver",      # hard,   900s,  sysadmin/web
        "largest-eigenval",             # medium, 900s,  numerical
        "schemelike-metacircular-eval",  # medium, 2400s, software-engineering
    ],
    "default8": [
        "regex-log", "sparql-university", "cancel-async-tasks",
        "configure-git-webserver", "largest-eigenval",
        "schemelike-metacircular-eval", "password-recovery", "dna-assembly",
    ],
}


def log(msg: str) -> None:
    print(f"[h2h {datetime.now().strftime('%H:%M:%S')}] {msg}", flush=True)


def harbor_bin() -> Path:
    p = TBENCH / ".venv" / "bin" / "harbor"
    if not p.exists():
        raise SystemExit(f"{p} missing; see bench/terminalbench/README.md")
    return p


def harbor_version() -> str:
    try:
        return subprocess.run([str(harbor_bin()), "--version"],
                              capture_output=True, text=True, timeout=60).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return "?"


def provider_probe() -> dict:
    """Verify the shared model is actually reachable BEFORE spending a run.

    A head-to-head whose provider died halfway through is not a head-to-head,
    and the failure mode is silent: arms that ran first look fine, arms that
    ran later look broken. Probed before and after, and both readings are
    recorded.
    """
    import urllib.error
    import urllib.request

    out: dict = {"checked_at": datetime.now(timezone.utc).isoformat(),
                 "container_base_url": arms_mod.OPENAI_COMPAT_BASE_URL,
                 "probed_from_host_via": arms_mod.HOST_PROBE_URL}
    try:
        with urllib.request.urlopen(
            arms_mod.HOST_PROBE_URL + "/v1/models", timeout=15
        ) as r:
            ids = {m["id"] for m in json.load(r)["data"]}
        out["reachable"] = True
        out["shared_model_present"] = arms_mod.SHARED_MODEL in ids
    except (urllib.error.URLError, OSError, KeyError, ValueError) as e:
        out["reachable"] = False
        out["shared_model_present"] = False
        out["error"] = str(e)[:200]
    return out


def osa_release_provenance() -> dict:
    """How stale is the OSA release artefact the `osa` arm actually runs?

    The `osa` arm does not run the working tree; it runs a snapshot OTP release
    in bench/terminalbench/dist/. If that snapshot predates commits to lib/,
    the benchmark measures older code than the one in the tree, silently. This
    records the exact delta instead of asserting freshness.
    """
    tarball = TBENCH / "dist" / "osa-release-linux-x86_64.tar.gz"
    out: dict = {"artefact": str(tarball), "present": tarball.exists()}
    if not tarball.exists():
        return out
    built_at = tarball.stat().st_mtime
    out["built_at"] = datetime.fromtimestamp(built_at, timezone.utc).isoformat()
    root = TBENCH.parent.parent
    try:
        since = datetime.fromtimestamp(built_at).strftime("%Y-%m-%d %H:%M:%S")
        r = subprocess.run(
            ["git", "log", f"--since={since}", "--format=%h %s", "--name-only",
             "--", "lib/"],
            cwd=root, capture_output=True, text=True, timeout=30)
        commits = [l for l in r.stdout.splitlines() if l.strip()]
        out["lib_commits_since_build"] = commits
        out["is_stale"] = bool(commits)
        out["staleness_note"] = (
            "The osa arm runs code that PREDATES the commits listed above. "
            "Any finding about OSA here is a finding about that snapshot."
            if commits else
            "No lib/ commits since the artefact was built; snapshot matches the tree.")
        out["head"] = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=root,
            capture_output=True, text=True, timeout=20).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        out["lib_commits_since_build"] = None
    return out


def disk_free_gb(path: Path) -> float:
    st = os.statvfs(path)
    return round(st.f_bavail * st.f_frsize / 1e9, 1)


def contamination_probe() -> dict:
    """Run bench/terminalbench/contamination_probe.py against live containers.

    Terminal-Bench grades container state, so a task image that ships its own
    solution would let every arm score without solving anything -- and it
    would do so identically for every arm, which is exactly the kind of shared
    bias a head-to-head cannot detect from the numbers.
    """
    probe = TBENCH / "contamination_probe.py"
    try:
        r = subprocess.run([sys.executable, str(probe), "--all"],
                           capture_output=True, text=True, timeout=300)
    except (OSError, subprocess.SubprocessError) as e:
        return {"status": "could_not_run", "error": str(e)[:200]}
    status = {0: "clean", 1: "CONTAMINATED", 2: "no_containers_to_probe"}.get(
        r.returncode, f"rc={r.returncode}")
    return {"status": status, "returncode": r.returncode,
            "output": (r.stdout + r.stderr)[-4000:]}


def run_arm(arm, tasks: list[str], out_dir: Path, args) -> tuple[Path | None, int]:
    """Run one arm over the task list. Returns (harbor job dir, exit code)."""
    arm_out = out_dir / "arms" / arm.name
    arm_out.mkdir(parents=True, exist_ok=True)

    cmd = [str(harbor_bin()), "run", "-y",
           "-o", str(arm_out / "harbor"),
           "-n", str(args.n_concurrent),
           "-p", str(TBENCH / "tasks" / "terminal-bench-2")]
    for t in tasks:
        cmd += ["-i", t]
    cmd += arm.harbor_args()
    cmd += ["--agent-timeout-multiplier", str(args.agent_timeout_multiplier)]
    # The overlay goes to EVERY arm. Applying it to one arm and not another is
    # a difference in the environment under test, not in the agent.
    cmd += ["--extra-docker-compose", str(TBENCH / "compose-host-provider.yaml")]
    # Harmless under `network_mode: public` (ignored with a warning), load
    # bearing under an allowlist. Same for every arm either way.
    cmd += ["--allow-agent-host", "host.docker.internal",
            "--allow-environment-host", "host.docker.internal"]

    env = os.environ.copy()
    env["PYTHONPATH"] = str(TBENCH) + os.pathsep + env.get("PYTHONPATH", "")
    env.update(arm.env)

    log(f"--- arm '{arm.name}' : {len(tasks)} task(s) ---")
    log(" ".join(cmd))
    (arm_out / "command.txt").write_text(" ".join(cmd) + "\n")
    # Credential VALUES are never written out; only which names were set.
    (arm_out / "env_names.json").write_text(
        json.dumps(sorted(arm.env), indent=2) + "\n")

    t0 = time.time()
    rc = subprocess.run(cmd, env=env, cwd=str(TBENCH)).returncode
    elapsed = round(time.time() - t0, 1)
    log(f"arm '{arm.name}' finished rc={rc} in {elapsed}s")

    jobs = sorted((arm_out / "harbor").glob("*/"), key=lambda p: p.stat().st_mtime)
    return (jobs[-1] if jobs else None), rc


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--list-arms", action="store_true",
                    help="print the runnable/blocked tables and exit")
    ap.add_argument("--run-id", default=None)
    ap.add_argument("--arms", nargs="+", default=["osa", "codex", "opencode",
                                                  "mini-swe-agent"])
    ap.add_argument("--tasks", nargs="*", default=None)
    ap.add_argument("--task-set", default="default6", choices=sorted(TASK_SETS))
    ap.add_argument("--seed", type=int, default=20260814,
                    help="recorded for provenance; task sets here are DECLARED "
                         "rather than sampled, so this only affects --shuffle")
    ap.add_argument("--shuffle", action="store_true",
                    help="shuffle the task order with --seed. Order is shared "
                         "by every arm; it is never re-drawn per arm")
    ap.add_argument("--n-concurrent", type=int, default=2)
    ap.add_argument("--agent-timeout-multiplier", type=float, default=1.0)
    ap.add_argument("--report-only", action="store_true",
                    help="re-report an existing run directory without running")
    args = ap.parse_args()

    if args.list_arms:
        print("RUNNABLE (model held fixed at "
              f"{arms_mod.SHARED_MODEL} on one shared Ollama daemon)\n")
        for a in arms_mod.RUNNABLE.values():
            print(f"  {a.name:16} -a {a.agent_spec:22} -m {a.model:32} wire={a.wire}")
            for c in a.caveats:
                print(f"      ! {c}")
        print("\nBLOCKED (NOT RUN — this is a missing credential, never a result)\n")
        for b in arms_mod.BLOCKED.values():
            print(f"  {b.name:16} [{b.blocker}]")
            print(f"      why: {b.reason}")
            print(f"      fix: {b.what_would_unblock}")
        return 0

    run_id = args.run_id or f"h2h-{time.strftime('%Y%m%d-%H%M%S')}"
    out = HERE / "runs" / run_id
    out.mkdir(parents=True, exist_ok=True)

    tasks = list(args.tasks) if args.tasks else list(TASK_SETS[args.task_set])
    if args.shuffle:
        random.Random(args.seed).shuffle(tasks)

    selected = [arms_mod.get(n) for n in args.arms]

    pre = provider_probe()
    if not args.report_only and not pre.get("shared_model_present"):
        raise SystemExit(
            f"shared model {arms_mod.SHARED_MODEL} not reachable at "
            f"{arms_mod.HOST_PROBE_URL}: {pre}\n"
            "Refusing to run: an arm that cannot reach the model produces a "
            "harness fault that looks like a capability result.")

    free_gb = disk_free_gb(HERE)
    log(f"disk free: {free_gb} GB")
    if free_gb < 40:
        raise SystemExit(f"only {free_gb} GB free; task images need headroom. "
                         "Run `docker builder prune -f` and retry.")

    config = {
        "run_id": run_id,
        "benchmark": "terminal-bench-2.0",
        "comparison": "head-to-head, same tasks / same model / same limits",
        "dataset": str(TBENCH / "tasks" / "terminal-bench-2"),
        "dataset_size": DATASET_SIZE,
        "tasks": tasks,
        "task_set": None if args.tasks else args.task_set,
        "task_selection": (
            "explicit --tasks" if args.tasks else
            f"declared curated set '{args.task_set}' — locally cached images, "
            "900-2400s timeouts, mixed difficulty. NOT a random sample of "
            "Terminal-Bench 2.0 and must not be described as one."),
        "seed": args.seed,
        "shuffled": args.shuffle,
        "arms": [a.name for a in selected],
        "shared_model": arms_mod.SHARED_MODEL,
        "model_held_fixed": True,
        "model_fixed_caveat": (
            "All arms hit ONE Ollama daemon serving ONE model, but not over "
            "one wire protocol: OSA uses /api/chat (Ollama-native), codex uses "
            "/v1/responses, everything else uses /v1/chat/completions. Same "
            "weights, same daemon, three serialisations. This is a declared "
            "asymmetry, not a hidden one."),
        "arm_wire_protocols": {a.name: a.wire for a in selected},
        "arm_caveats": {a.name: list(a.caveats) for a in selected},
        "limits": {
            "wall_clock": "task.toml agent.timeout_sec x "
                          f"{args.agent_timeout_multiplier}",
            "agent_timeout_multiplier": args.agent_timeout_multiplier,
            "turn_cap": None,
            "turn_cap_note": (
                "Deliberately unset. Only goose and mini-swe-agent expose a "
                "turn/step cap; codex, opencode and OSA have no such flag. "
                "Capping only the arms that can be capped would be a "
                "difference in the experiment, not in the systems."),
            "attempts_per_task": 1,
            "selection_method": "best-of-1, no reranking, no test-time compute",
        },
        "n_concurrent": args.n_concurrent,
        "harbor_version": harbor_version(),
        "provider_probe_before": pre,
        "osa_release_provenance": osa_release_provenance(),
        "disk_free_gb_before": free_gb,
        "blocked_arms": {b.name: {"blocker": b.blocker, "reason": b.reason,
                                  "what_would_unblock": b.what_would_unblock}
                         for b in arms_mod.BLOCKED.values()},
        "started_at": datetime.now(timezone.utc).isoformat(),
        "host": {"platform": platform.platform(), "python": platform.python_version()},
        "graded_by": "each task's own tests/test.sh inside the task container "
                     "(final container state, not a patch, not model output)",
    }
    (out / "config.json").write_text(json.dumps(config, indent=2) + "\n")

    job_dirs: dict[str, str] = {}
    if args.report_only:
        for a in selected:
            jobs = sorted((out / "arms" / a.name / "harbor").glob("*/"),
                          key=lambda p: p.stat().st_mtime)
            if jobs:
                job_dirs[a.name] = str(jobs[-1])
    else:
        contamination_done = False
        for a in selected:
            job_dir, rc = run_arm(a, tasks, out, args)
            config.setdefault("arm_exit_codes", {})[a.name] = rc
            if job_dir:
                job_dirs[a.name] = str(job_dir)
            # Probe live containers once, during the first arm's run window,
            # while a task container actually exists to probe.
            if not contamination_done:
                config["contamination_probe"] = contamination_probe()
                contamination_done = True

    config["provider_probe_after"] = provider_probe()
    config["disk_free_gb_after"] = disk_free_gb(HERE)
    config["finished_at"] = datetime.now(timezone.utc).isoformat()
    config["arm_job_dirs"] = job_dirs
    (out / "config.json").write_text(json.dumps(config, indent=2) + "\n")

    results = report_h2h.build(config=config, job_dirs=job_dirs, arms=selected)
    rj, rm = report_h2h.write(results, out)
    report_h2h.print_headline(results)
    log(f"results: {rj}")
    log(f"report:  {rm}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
