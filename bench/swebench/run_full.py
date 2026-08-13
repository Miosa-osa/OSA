#!/usr/bin/env python3
"""Run SWE-bench Verified at full scale, in waves, on a disk that cannot hold it.

THE BINDING CONSTRAINT IS DISK, AND IT WAS MEASURED, NOT ASSUMED
----------------------------------------------------------------
Published guidance says instance images are "3-5 GB each". That is the *image*
size and it is the wrong number to plan with, because the base and env layers
are shared. What matters is the marginal cost of adding one more instance to a
host that already has its neighbours. Measured on this host by pulling five
images from five different repo families and taking the `statvfs` delta around
each pull:

    django__django-10097            2.24 GB   23.1 s
    sympy__sympy-11618              0.12 GB    3.5 s
    matplotlib__matplotlib-13989    3.62 GB   36.9 s
    sphinx-doc__sphinx-10323        0.43 GB   18.1 s
    pydata__xarray-2905             5.39 GB   63.6 s
    ------------------------------------------------
    mean 2.36 GB, 11.81 GB / 145 s = 81 MB/s

500 x 2.36 GB is ~1.18 TB against 449 GB free. Docker's own per-image UNIQUE
SIZE across the 44 images already present agrees (django ~1.3 GB unique on a
2.9 GB shared env layer; matplotlib ~9 GB unique). So the full set does not fit
simultaneously, and no cache-level setting changes that: `--cache-level env`
only governs what the *grader* keeps afterwards, while `workspace.prepare()`
pulls the instance image during inference regardless.

WHAT ACTUALLY WORKS
-------------------
Waves. Each wave is a small set of instances that is carried through ALL THREE
ARMS -- gold-apply, empty, osa -- before its images are deleted. Peak disk is
therefore `wave_size * 2.4 GB` plus the accumulating (small, shared, reused)
env layers, and total download volume is ~1.2 TB *once* rather than once per
arm. Running the arms in the other order -- all of gold, then all of empty,
then all of osa -- would pull the same 1.2 TB three times.

WHY A SEEDED SHUFFLE AND NOT DATASET ORDER
------------------------------------------
Waves are cut from a seeded shuffle of all 500 instance ids. That makes **every
prefix of waves a uniform random sample of the dataset**, so an interrupted run
still yields a defensible number instead of "the first N rows", which is not a
sample and which `run_bench.py --limit` correctly labels as such. If all waves
finish, the union is the whole dataset and `is_full_dataset_run` becomes true
for the first time.

The three arms of a wave use the SAME instances, which is the point: a control
that ran on a different set proves nothing about this one.

CHECKPOINTING
-------------
`state.json` records every (wave, arm) that finished. Re-running skips them.
Nothing is deleted on resume -- in particular not `transcripts/`, which is the
diagnostic deliverable.

USAGE
  run_full.py --wave-size 50 --osa-url http://127.0.0.1:19963 [--waves 0 1 2]
  run_full.py --merge-only
"""
from __future__ import annotations

import argparse
import json
import random
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
PY = HERE / ".venv" / "bin" / "python"

#: The order matters. gold-apply first: if the wave is not winnable the OSA
#: number from it means nothing, and finding that out before spending the
#: agent's tokens is free.
ARMS = ["gold-apply", "empty", "osa"]
ARM_TAG = {"gold-apply": "gold", "empty": "empty", "osa": "osa"}

SHUFFLE_SEED = 20260814


def log(*a):
    print(f"[{time.strftime('%H:%M:%S')}] [run_full]", *a, flush=True)


def free_gb(p: Path = HERE) -> float:
    return shutil.disk_usage(p).free / 1e9


def wave_plan(all_ids: list[str], wave_size: int) -> list[list[str]]:
    ids = list(all_ids)
    random.Random(SHUFFLE_SEED).shuffle(ids)
    return [ids[i:i + wave_size] for i in range(0, len(ids), wave_size)]


class State:
    def __init__(self, path: Path):
        self.path = path
        self.d = json.loads(path.read_text()) if path.exists() else {"done": {}}

    def is_done(self, wave: int, arm: str) -> bool:
        return self.d["done"].get(f"{wave}:{arm}", {}).get("ok") is True

    def mark(self, wave: int, arm: str, ok: bool, **kw):
        self.d["done"][f"{wave}:{arm}"] = {
            "ok": ok, "at": datetime.now(timezone.utc).isoformat(), **kw
        }
        self.save()

    def save(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps(self.d, indent=2) + "\n")


def run_arm(*, arm: str, wave: int, ids_file: Path, run_id: str, args) -> bool:
    cmd = [
        str(PY), str(HERE / "run_bench.py"),
        "--runner", arm,
        "--instances", str(ids_file),
        "--run-id", run_id,
        "--eval-workers", str(args.eval_workers),
        "--eval-timeout", str(args.eval_timeout),
        "--min-free-gb", str(args.min_free_gb),
        # Keep the instance image for the next arm of the SAME wave. Handing
        # the grader `env` here would delete it and force a re-pull per arm,
        # tripling the 1.2 TB download. The wave prunes its own images at the
        # end instead.
        "--cache-level", "instance",
    ]
    if arm == "osa":
        cmd += [
            "--osa-url", args.osa_url,
            "--infer-workers", str(args.infer_workers),
            "--agent-timeout", str(args.agent_timeout),
            "--max-turns", str(args.max_turns),
        ]
        if args.airgap:
            cmd += ["--airgap"]
    else:
        # Controls do not call a model; their only cost is Docker, so they can
        # use more workers than the agent arm without distorting anything.
        cmd += ["--infer-workers", str(args.ctrl_infer_workers)]

    log(f"wave {wave} arm {arm}: {' '.join(cmd[2:])}")
    t = time.time()
    rc = subprocess.run(cmd, cwd=HERE).returncode
    log(f"wave {wave} arm {arm}: exit {rc} after {time.time() - t:.0f}s, "
        f"{free_gb():.0f} GB free")
    return rc == 0


def prune_wave(ids: list[str]) -> float:
    """Delete this wave's instance images; keep base and env layers.

    Env layers are what make the next wave cheap -- they are shared by every
    instance of the same repo+version and re-pulling them would dominate.
    """
    import workspace as ws
    before = free_gb()
    for iid in ids:
        img = ws.instance_image(iid)
        if ws.image_present(img):
            subprocess.run(["docker", "rmi", "-f", img], capture_output=True)
    # NOT `docker container prune -f`: that removes every stopped container on
    # the host, including ones belonging to whoever else uses this machine.
    # Only this harness's own leftovers are ours to delete.
    stale = subprocess.run(
        ["docker", "ps", "-aq", "--filter", "status=exited",
         "--filter", "name=^bench-", "--filter", "name=^sweb.eval"],
        capture_output=True, text=True,
    ).stdout.split()
    if stale:
        subprocess.run(["docker", "rm", "-f", *stale], capture_output=True)
    freed = free_gb() - before
    log(f"pruned wave images: freed {freed:.1f} GB, {free_gb():.0f} GB free")
    return freed


def merge_all(waves: list[list[str]], state: State, args) -> None:
    """Rebuild the three merged arm reports from whatever has finished.

    Called after EVERY wave, so an interruption at any point leaves a complete,
    gated, self-describing report on disk for the instances that did run.
    """
    import merge_waves
    for arm in ARMS:
        done = [
            w for w in range(len(waves))
            if state.is_done(w, arm)
            and (HERE / "runs" / f"{args.prefix}-w{w:02d}-{ARM_TAG[arm]}" / "inference.jsonl").exists()
        ]
        if not done:
            continue
        dirs = [HERE / "runs" / f"{args.prefix}-w{w:02d}-{ARM_TAG[arm]}" for w in done]
        out = HERE / "runs" / f"{args.prefix}-{ARM_TAG[arm]}"
        try:
            doc = merge_waves.merge(
                dirs, out, f"{args.prefix}-{ARM_TAG[arm]}", dataset_size=500,
                sampling={
                    "method": "seeded-shuffle-prefix (uniform, unweighted)",
                    "seed": SHUFFLE_SEED,
                    "population": 500,
                    "n_requested": len(waves) * args.wave_size,
                    "wave_size": args.wave_size,
                    "waves_completed": sorted(done),
                    "hard_weighted": False,
                    "note": (
                        "All 500 ids shuffled once with this seed and cut into "
                        "waves. Every prefix of waves is therefore a uniform "
                        "random sample of the dataset -- unlike --limit, which "
                        "takes dataset order. When every wave is present the "
                        "union IS the dataset and is_full_dataset_run is true."
                    ),
                },
            )
        except Exception as e:  # noqa: BLE001 - a merge failure must not kill the run
            log(f"merge {arm} FAILED: {type(e).__name__}: {e}")
            continue
        a = doc["aggregate"]
        log(f"MERGED {arm}: {a['instances_resolved']}/{a['instances_attempted']} "
            f"({(a['resolve_rate'] or 0) * 100:.1f}%)  -> {out}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--prefix", default="full500")
    ap.add_argument("--wave-size", type=int, default=50)
    ap.add_argument("--waves", type=int, nargs="*", default=None,
                    help="wave indices to run; default all")
    ap.add_argument("--arms", nargs="*", default=ARMS)
    ap.add_argument("--osa-url", default="http://127.0.0.1:19963")
    ap.add_argument("--airgap", action="store_true", default=True)
    ap.add_argument("--no-airgap", dest="airgap", action="store_false")
    ap.add_argument("--infer-workers", type=int, default=3)
    ap.add_argument("--ctrl-infer-workers", type=int, default=6)
    ap.add_argument("--eval-workers", type=int, default=6)
    ap.add_argument("--agent-timeout", type=int, default=1800)
    ap.add_argument("--eval-timeout", type=int, default=1800)
    ap.add_argument("--max-turns", type=int, default=60)
    ap.add_argument("--min-free-gb", type=float, default=60.0)
    ap.add_argument("--reserve-gb", type=float, default=90.0,
                    help="prune before a wave if free disk is under this")
    ap.add_argument("--merge-only", action="store_true")
    args = ap.parse_args()

    all_ids = [l.strip() for l in (HERE / "instances" / "all500.txt").read_text().splitlines() if l.strip()]
    if len(all_ids) != 500:
        raise SystemExit(f"expected 500 instance ids, found {len(all_ids)}")
    waves = wave_plan(all_ids, args.wave_size)
    state = State(HERE / "runs" / f"{args.prefix}-state.json")
    state.d["plan"] = {
        "shuffle_seed": SHUFFLE_SEED,
        "wave_size": args.wave_size,
        "n_waves": len(waves),
        "selection": (
            "seeded shuffle of all 500; every prefix of waves is a uniform "
            "random sample of SWE-bench Verified, and the union of all waves "
            "is the dataset"
        ),
    }
    state.save()

    if args.merge_only:
        merge_all(waves, state, args)
        return 0

    todo = args.waves if args.waves is not None else list(range(len(waves)))
    log(f"{len(waves)} wave(s) of {args.wave_size}; running {todo}; "
        f"{free_gb():.0f} GB free")

    for w in todo:
        ids = waves[w]
        ids_file = HERE / "instances" / f"{args.prefix}-w{w:02d}.txt"
        ids_file.write_text("\n".join(ids) + "\n")

        if free_gb() < args.reserve_gb:
            log(f"only {free_gb():.0f} GB free; pruning previous waves")
            for pw in range(w):
                prune_wave(waves[pw])

        for arm in args.arms:
            if state.is_done(w, arm):
                log(f"wave {w} arm {arm}: already done, skipping")
                continue
            run_id = f"{args.prefix}-w{w:02d}-{ARM_TAG[arm]}"
            ok = run_arm(arm=arm, wave=w, ids_file=ids_file, run_id=run_id, args=args)
            state.mark(w, arm, ok, run_id=run_id, free_gb=round(free_gb(), 1))
            if not ok and arm != "osa":
                # A control that did not complete invalidates the wave's OSA
                # number. Record it and move on rather than silently producing
                # an ungrounded score.
                log(f"wave {w}: control {arm} did not complete — the OSA arm "
                    f"for this wave is NOT evidence until it does")

        prune_wave(ids)
        merge_all(waves, state, args)

    log("all requested waves attempted")
    merge_all(waves, state, args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
