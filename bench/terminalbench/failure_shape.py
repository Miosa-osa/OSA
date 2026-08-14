#!/usr/bin/env python3
"""Classify a run's failures, and describe the shape of the ones that are ours.

## Why this exists separately from `report.py`

`report.py` answers "who failed" at the level Harbor can see: resolved, model,
harness, ambiguous. That split is necessary and it is not sufficient, because
the `model` bucket silently contains three different things:

  * tasks whose own reference solution fails on this machine (the oracle
    control knows these; the reporter does not),
  * tasks killed by a deadline, which are recoverable by re-running rather than
    by changing anything,
  * tasks where OSA genuinely did its job and the answer was wrong.

Only the third is evidence about the harness. Quoting a rate over the union of
all four buckets mixes a machine defect, a timeout policy and a capability
limit into one number, and then invites comparison against a published figure
that carried none of them.

## The proxy trap, which cost a wrong conclusion once already

The obvious way to ask "is OSA stopping early?" is to compare turn counts of
failed against solved episodes. **That measure is invalid whenever reasoning is
enabled, and it inverts the answer.**

Measured on the first reasoning-on full-89 arm:

  by turns       solved med 22, failed med 24   -> "failures run LONGER, no early stop"
  by wall clock  solved med 146s, failed med 290s, but failed q1 53s vs solved q1 95s

The turn comparison hid a bimodal failure distribution. Six of fourteen
failures finished in under 80 seconds at 3-4 s/turn -- against 8 s/turn for
solves -- having burned 11-18 turns and ended with `status=ok` and no
self-inflicted markers. That is the shallow self-certification signature, and
the turn-count view reported its opposite with confidence.

The same trap runs the other way: `regex-chess` spent 1169s over 6 turns
(195 s/turn), the deepest-thinking episode in the set, and a turn-count reading
labels it an early stop.

**So: seconds per turn is the discriminator, not turns.** With reasoning on, a
turn is not a unit of effort, and any statistic built on turn counts is
measuring how the model chose to chunk its output rather than how hard it
worked.
"""

from __future__ import annotations

import argparse
import json
import re
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

#: Tasks whose own reference solution scores < 1.0 on THIS machine, from
#: `controls.py run --dataset-key tb2.0`. An OSA failure on one of these is not
#: evidence about OSA. Regenerate rather than trusting this list on another host
#: -- it is a statement about local images, indexes and credentials.
TB20_UNSOUND = {
    "build-cython-ext", "build-pmars", "make-doom-for-mips",
    "mcmc-sampling-stan", "protein-assembly", "rstan-to-pystan",
}
#: Oracle wrote no reward at all: the task is probably fine and the machine is not.
TB20_INFRA = {"caffe-cifar-10"}

#: Below this, an episode that ended cleanly did not do enough thinking to have
#: been reasoning on its turns. Derived from the measured contrast (solves run a
#: median 8 s/turn; the shallow cluster runs 3-4) and deliberately conservative.
SHALLOW_SEC_PER_TURN = 5.0


def collect(run_dir: Path, unsound: set[str], infra: set[str]) -> list[dict]:
    rows = []
    for f in run_dir.glob("harbor/*/*/result.json"):
        try:
            d = json.loads(f.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        name = d["task_name"].split("/")[-1]
        reward = ((d.get("verifier_result") or {}).get("rewards") or {}).get("reward")
        ar = d.get("agent_result") or {}
        md = ar.get("metadata") or {}
        # Wall clock comes from the driver's own final line, which is the only
        # place the agent phase's duration is recorded; Harbor's result.json
        # leaves `ended_at` null on trials it killed.
        wall = None
        log = f.parent / "agent" / "osa-driver.log"
        if log.exists():
            m = re.search(r"run=([\d.]+)s", log.read_text(errors="replace"))
            if m:
                wall = float(m.group(1))
        rows.append({
            "task": name,
            "reward": reward,
            "solved": reward == 1.0,
            "status": md.get("osa_status"),
            "error": md.get("osa_error"),
            "turns": md.get("osa_turns") or 0,
            "tools": md.get("osa_tool_calls") or 0,
            "wall_s": wall,
            "tokens_in": ar.get("n_input_tokens"),
            "self_inflicted": md.get("osa_self_inflicted") or {},
        })
    return rows


def bucket(r: dict, unsound: set[str], infra: set[str]) -> str:
    if r["reward"] is None:
        return "ungraded"
    if r["solved"]:
        return "solved"
    if r["task"] in unsound:
        return "unsound_task"
    if r["task"] in infra:
        return "infra"
    if r["status"] == "timeout":
        return "timeout"
    if r["status"] not in ("ok", None):
        return "harness_fault"
    return "model_failure"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run_dir")
    ap.add_argument("--dataset-key", default="tb2.0")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    run = Path(args.run_dir)
    if not run.exists():
        print(f"no such run: {run}", file=sys.stderr)
        return 1
    unsound = TB20_UNSOUND if args.dataset_key == "tb2.0" else set()
    infra = TB20_INFRA if args.dataset_key == "tb2.0" else set()

    rows = collect(run, unsound, infra)
    for r in rows:
        r["bucket"] = bucket(r, unsound, infra)
    graded = [r for r in rows if r["bucket"] != "ungraded"]
    if not graded:
        print("nothing graded yet")
        return 0
    solved = [r for r in graded if r["bucket"] == "solved"]
    by: dict[str, list] = {}
    for r in graded:
        by.setdefault(r["bucket"], []).append(r)

    n = len(graded)
    n_sound = n - len(by.get("unsound_task", [])) - len(by.get("infra", []))
    n_sound_untimed = n_sound - len(by.get("timeout", []))

    print(f"graded {n}   solved {len(solved)}")
    print(f"  raw rate            {len(solved)}/{n} = {len(solved) / n * 100:.1f}%")
    print(f"  sound-task rate     {len(solved)}/{n_sound} = {len(solved) / n_sound * 100:.1f}%")
    print(f"  sound + untimed     {len(solved)}/{n_sound_untimed} = "
          f"{len(solved) / n_sound_untimed * 100:.1f}%")
    print()
    for k in ("unsound_task", "infra", "timeout", "harness_fault", "model_failure"):
        v = by.get(k, [])
        if v:
            print(f"  {k:<14} {len(v):>2}  {sorted(r['task'] for r in v)}")

    # --- the shape of the failures that are actually ours ---------------
    mf = [r for r in by.get("model_failure", []) if r["wall_s"] and r["turns"]]
    sv = [r for r in solved if r["wall_s"] and r["turns"]]
    if not mf:
        return 0
    print("\n--- shape of model failures (seconds per turn, NOT turns) ---")

    def spt(x):
        return statistics.median([r["wall_s"] / r["turns"] for r in x])

    if sv:
        print(f"  solved   median {spt(sv):5.1f} s/turn   "
              f"median wall {statistics.median([r['wall_s'] for r in sv]):6.0f}s")
    print(f"  failed   median {spt(mf):5.1f} s/turn   "
          f"median wall {statistics.median([r['wall_s'] for r in mf]):6.0f}s")

    shallow = [r for r in mf if r["wall_s"] / r["turns"] < SHALLOW_SEC_PER_TURN]
    if shallow:
        print(f"\n  SHALLOW STOPS: {len(shallow)}/{len(mf)} failures under "
              f"{SHALLOW_SEC_PER_TURN} s/turn.")
        print("  These ended cleanly, burned turns fast, and were wrong -- the "
              "signature\n  the verification-adequacy gate exists to catch. "
              "Every one is a gate miss.")
        for r in sorted(shallow, key=lambda x: x["wall_s"]):
            print(f"    {r['task']:<32} {r['wall_s']:6.0f}s  turns={r['turns']:<3} "
                  f"{r['wall_s'] / r['turns']:4.1f}s/turn  si={r['self_inflicted'] or '{}'}")
    deep = [r for r in mf if r["wall_s"] / r["turns"] >= SHALLOW_SEC_PER_TURN]
    if deep and args.verbose:
        print(f"\n  worked-hard-still-wrong: {len(deep)}")
        for r in sorted(deep, key=lambda x: -x["wall_s"]):
            print(f"    {r['task']:<32} {r['wall_s']:6.0f}s  turns={r['turns']:<3} "
                  f"{r['wall_s'] / r['turns']:5.1f}s/turn")
    return 0


if __name__ == "__main__":
    sys.exit(main())
