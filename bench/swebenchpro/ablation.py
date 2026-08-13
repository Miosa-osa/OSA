#!/usr/bin/env python3
"""Paired comparison of two context modes over the SAME instances.

    ./.venv/bin/python ablation.py runs/osa-s12-full runs/osa-s12-nospec

## Why this is not `bench/report/cli.py compare`

That command uses `stats.two_proportion` (Newcombe), which assumes the two
samples are **independent**. These are not: every instance appears in both
arms, with the same seed, the same model and the same limits. Treating paired
data as independent throws away the pairing -- the very thing that makes a
12-instance ablation worth running at all -- and produces an interval that is
too wide in the usual case and, when the arms are strongly correlated, wrong in
a way that is not conservative.

The correct conditioning is on the **discordant pairs** only: instances that
one arm solved and the other did not. Concordant pairs (both solved, or neither
solved) carry no information about the difference, however many there are. So:

  b = solved with full spec, NOT solved without
  c = solved without spec, NOT solved with

McNemar's exact test asks whether b out of (b+c) discordant pairs is further
from half than chance would explain, which is a plain two-sided binomial test
at p=0.5. The interval on the difference is the exact (Clopper-Pearson)
interval for that same binomial proportion, rescaled by (b+c)/n.

At n=12 this will almost certainly not be significant, and saying so is the
point: the paired table below is the finding, and the scalar delta is the part
that has to carry its uncertainty in public.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "report"))

import stats  # type: ignore  # bench/report/stats.py, read-only


def load(run: Path) -> tuple[dict, dict]:
    d = json.loads((run / "results.json").read_text())
    by_id = {i["instance_id"]: i for i in d["instances"]}
    return d, by_id


def binom_two_sided_p(b: int, n: int) -> float:
    """Exact two-sided binomial p at p=0.5 -- McNemar's exact test.

    With p=0.5 the distribution is symmetric, so the two-sided p is simply
    twice the smaller tail, capped at 1.
    """
    if n == 0:
        return 1.0
    tail = min(stats._binom_cdf_le(b, n, 0.5), stats._binom_sf_ge(b, n, 0.5))
    return min(1.0, 2.0 * tail)


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    a_dir, b_dir = Path(sys.argv[1]), Path(sys.argv[2])
    A, a = load(a_dir)
    B, b = load(b_dir)

    ids = [i["instance_id"] for i in A["instances"]]
    missing = [i for i in ids if i not in b]
    if missing or len(b) != len(ids):
        print(f"NOT PAIRED: instance sets differ ({len(ids)} vs {len(b)}); "
              f"missing {missing[:3]}")
        return 1

    # Pairing is only meaningful if everything except the treatment matched.
    print("=== pairing check ===")
    for key in ("model", "attempts", "max_turns", "agent_timeout_s",
                "test_file_hint", "test_bridge", "harness_commit"):
        va, vb = A["config"].get(key), B["config"].get(key)
        flag = "OK " if va == vb else "DIFF"
        print(f"  {flag} {key:18s} {va} | {vb}")
    print(f"  --- treatment      context_mode "
          f"{A['config'].get('context_mode')} -> {B['config'].get('context_mode')}")
    print(f"  seed {A['config'].get('sampling', {}).get('seed')} | "
          f"{B['config'].get('sampling', {}).get('seed')}")

    print()
    print("=== paired per-instance outcomes ===")
    print(f"{'full':>5s} {'nospec':>7s} {'flip':>5s}  instance")
    n11 = n00 = bb = cc = 0
    flips = []
    for iid in ids:
        ra, rb = a[iid]["resolved"], b[iid]["resolved"]
        if ra and rb:
            n11 += 1
            f = ""
        elif not ra and not rb:
            n00 += 1
            f = ""
        elif ra and not rb:
            bb += 1
            f = "LOST"
            flips.append((iid, "LOST", a[iid], b[iid]))
        else:
            cc += 1
            f = "GAIN"
            flips.append((iid, "GAIN", a[iid], b[iid]))
        print(f"{'YES' if ra else 'no':>5s} {'YES' if rb else 'no':>7s} "
              f"{f:>5s}  {iid[:56]}")

    n = len(ids)
    ka, kb = sum(a[i]["resolved"] for i in ids), sum(b[i]["resolved"] for i in ids)
    print()
    print("=== contingency (paired) ===")
    print(f"  both solved                : {n11}")
    print(f"  neither solved             : {n00}")
    print(f"  b = full only (spec helped): {bb}")
    print(f"  c = nospec only (spec hurt): {cc}")
    print(f"  discordant pairs           : {bb + cc}")

    print()
    print("=== totals ===")
    ia = stats.wilson(ka, n)
    ib = stats.wilson(kb, n)
    print(f"  full   : {ka}/{n}  ({ia.low * 100:.1f}%-{ia.high * 100:.1f}% Wilson)")
    print(f"  no-spec: {kb}/{n}  ({ib.low * 100:.1f}%-{ib.high * 100:.1f}% Wilson)")

    d = (ka - kb) / n
    disc = bb + cc
    print()
    print("=== paired difference (McNemar, exact) ===")
    print(f"  observed delta        : {d * 100:+.1f} pp  ({ka - kb} instances)")
    if disc == 0:
        print("  discordant pairs      : 0 -- the two arms solved exactly the same "
              "instances, so the difference is 0 with no evidence of any effect "
              "in either direction.")
        print("  exact McNemar p       : 1.0")
    else:
        p = binom_two_sided_p(bb, disc)
        ci = stats.clopper_pearson(bb, disc, 0.95)
        lo = (2 * ci.low - 1) * disc / n
        hi = (2 * ci.high - 1) * disc / n
        print(f"  exact McNemar p       : {p:.4f}")
        print(f"  95% CI on the delta   : {lo * 100:+.1f} pp to {hi * 100:+.1f} pp")
        print(f"    (exact interval on b/(b+c) = {bb}/{disc}, rescaled by (b+c)/n)")
        if lo <= 0 <= hi:
            print("  => the interval contains 0: this run does NOT establish that "
                  "withholding the spec changes the outcome.")

    print()
    print("=== effort, both arms ===")
    for tag, doc in (("full", A), ("nospec", B)):
        ag = doc["aggregate"]
        print(f"  {tag:7s} tokens_in={ag['tokens_in_total']:>10} "
              f"cost=${ag['cost_usd_total']:<8} "
              f"turns={ag['turns_mean']:<7} tools={ag['tool_calls_mean']:<7} "
              f"wall/inst={ag['wall_clock_mean_s'] / 60:.1f}min")

    print()
    print("=== fault attribution (a harness fault outranks the ablation) ===")
    for tag, doc in (("full", A), ("nospec", B)):
        dg = doc["aggregate"].get("diagnosis") or {}
        print(f"  {tag:7s} {dg.get('by_fault')}")
        print(f"          buckets: {dg.get('buckets')}")
    for tag, doc in (("full", A), ("nospec", B)):
        bugs = doc["aggregate"].get("probable_osa_bugs") or []
        if bugs:
            print(f"  !! {tag}: probable OSA bugs: "
                  f"{[(x['bucket'], x['count']) for x in bugs]}")

    print()
    print("=== flipped instances, in detail ===")
    for iid, kind, ra, rb in flips:
        print(f"  [{kind}] {iid[:60]}")
        print(f"      full  : {ra['outcome']:12s} {ra.get('failure_bucket') or '-'}"
              f"  patch={ra['patch_bytes']}B turns={ra.get('turns')}")
        print(f"      nospec: {rb['outcome']:12s} {rb.get('failure_bucket') or '-'}"
              f"  patch={rb['patch_bytes']}B turns={rb.get('turns')}")
    if not flips:
        print("  none")
    return 0


if __name__ == "__main__":
    sys.exit(main())
