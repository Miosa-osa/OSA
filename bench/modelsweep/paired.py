#!/usr/bin/env python3
"""Paired analysis for the model sweep.

## Why this is not `bench/report/cli.py compare`

That comparator treats two runs as INDEPENDENT samples. These arms are not
independent: every arm runs the SAME 12 instances, so each instance contributes
a matched pair. Throwing the pairing away is not merely conservative -- it
answers a different question, and on n=12 the difference dominates. Two arms
that agree on 10 instances and differ on 2 carry all their evidence in those 2
discordant pairs; an unpaired test dilutes that across 12 and reports nothing.

So: **exact McNemar on the discordant pairs only.** With b+c discordant pairs
the two-sided exact p is the binomial tail at 1/2, which for the counts this
sweep can produce is computed in closed form rather than approximated -- the
chi-square form of McNemar is invalid at these counts and the continuity
correction does not save it.

## What n=12 can and cannot say

A per-arm rate on 12 instances has a Wilson 95% interval roughly +/-25 points
wide. 9/12 = 75% has an interval of about [47%, 91%]. **This sweep cannot rank
close models.** It can only detect a difference that is very large, or --
more usefully -- separate a model-shaped failure from a harness-shaped one by
looking at WHICH instances fail and HOW.

Every number this module prints carries its interval for that reason.
"""

from __future__ import annotations

import argparse
import json
import math
from itertools import combinations
from pathlib import Path


def wilson(k: int, n: int, z: float = 1.959963984540054) -> tuple[float, float]:
    """Wilson score interval. Not normal-approximation: at n=12 that would
    produce bounds below 0 or above 1 and imply precision that is not there."""
    if n == 0:
        return (0.0, 0.0)
    p = k / n
    d = 1 + z * z / n
    centre = (p + z * z / (2 * n)) / d
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return (max(0.0, centre - half), min(1.0, centre + half))


def _binom_pmf(k: int, n: int) -> float:
    return math.comb(n, k) * 0.5**n


def mcnemar_exact(b: int, c: int) -> float:
    """Two-sided exact McNemar p-value.

    b = solved by A only, c = solved by B only. Under H0 each discordant pair
    is a fair coin, so the statistic is Binomial(b+c, 1/2) and the two-sided p
    is the sum of all outcomes no more likely than the observed one. Returns
    1.0 when there are no discordant pairs -- with nothing discordant there is
    no evidence of a difference, which is not the same as evidence of equality.
    """
    n = b + c
    if n == 0:
        return 1.0
    obs = _binom_pmf(b, n)
    # Floating tolerance matters: pmf(k) and pmf(n-k) are equal in exact
    # arithmetic but can differ in the last bit, which would drop one tail.
    tol = 1e-12
    return min(1.0, sum(_binom_pmf(k, n) for k in range(n + 1)
                        if _binom_pmf(k, n) <= obs + tol))


def load_arm(run_dir: Path) -> dict:
    """Map instance_id -> resolved(bool), plus the arm's metadata.

    `fault` is carried through so an instance the bench itself broke (provider
    outage -> fault=bench) can be EXCLUDED rather than scored as a model miss.
    Silently counting those as failures is the exact misattribution
    `runners.provider_failure` exists to prevent.
    """
    res = json.loads((run_dir / "results.json").read_text())
    cfg = res.get("config", {})
    out = {}
    for i in res.get("instances", []):
        out[i["instance_id"]] = {
            "resolved": bool(i.get("resolved")),
            "status": i.get("status"),
            "fault": (i.get("diagnosis") or {}).get("fault") if isinstance(i.get("diagnosis"), dict) else i.get("fault"),
            "tool_calls": i.get("tool_calls"),
            "turns": i.get("turns"),
            "cost_usd": i.get("cost_usd"),
            "error": i.get("error"),
        }
    agg = res.get("aggregate", {})
    return {
        "run_id": cfg.get("run_id") or run_dir.name,
        "model": cfg.get("model"),
        "instances": out,
        "cost_usd_total": agg.get("cost_usd_total"),
        "wall_clock_total_s": agg.get("wall_clock_total_s"),
        "is_full_dataset_run": agg.get("is_full_dataset_run", False),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("runs", nargs="+", help="run directories, one per arm")
    ap.add_argument("--label", action="append", default=None,
                    help="override arm labels, in the same order")
    ap.add_argument("--json-out", default=None)
    args = ap.parse_args()

    arms = [load_arm(Path(r)) for r in args.runs]
    labels = args.label or [a["model"] or a["run_id"] for a in arms]
    if len(labels) != len(arms):
        raise SystemExit("--label count must match run count")

    # Only instances every arm attempted -- an arm missing an instance would
    # otherwise get a free pass on it.
    common = set(arms[0]["instances"])
    for a in arms[1:]:
        common &= set(a["instances"])
    common = sorted(common)

    print(f"paired on {len(common)} instance(s) common to all {len(arms)} arm(s)\n")

    # -- per-instance table -------------------------------------------------
    w = max(len(i) for i in common) if common else 10
    w = min(w, 62)
    head = f"{'instance':<{w}}  " + "  ".join(f"{l[:22]:<22}" for l in labels)
    print(head)
    print("-" * len(head))
    for iid in common:
        cells = []
        for a in arms:
            r = a["instances"][iid]
            mark = "PASS" if r["resolved"] else "fail"
            if r.get("fault") == "bench":
                mark = "EXCL(bench)"
            cells.append(f"{mark:<22}")
        print(f"{iid[:w]:<{w}}  " + "  ".join(cells))
    print()

    # -- per-arm rates ------------------------------------------------------
    print(f"{'arm':<26} {'resolved':<10} {'rate':<8} {'wilson95':<18} {'cost_usd':<10} {'excluded'}")
    summary = []
    for a, l in zip(arms, labels):
        rows = [a["instances"][i] for i in common]
        excl = [i for i, r in zip(common, rows) if r.get("fault") == "bench"]
        scored = [r for r in rows if r.get("fault") != "bench"]
        k = sum(1 for r in scored if r["resolved"])
        n = len(scored)
        lo, hi = wilson(k, n)
        print(f"{l[:25]:<26} {f'{k}/{n}':<10} {k/n if n else 0:<8.3f} "
              f"[{lo:.3f}, {hi:.3f}]{'':<3} {str(round(a['cost_usd_total'] or 0, 2)):<10} {len(excl)}")
        summary.append({"arm": l, "resolved": k, "n": n,
                        "rate": k / n if n else None, "wilson95": [lo, hi],
                        "cost_usd_total": a["cost_usd_total"],
                        "excluded_bench_fault": excl})
    print()

    # -- pairwise exact McNemar --------------------------------------------
    pairs = []
    print("pairwise exact McNemar (discordant pairs only):")
    for (ia, a), (ib, b) in combinations(list(enumerate(arms)), 2):
        la, lb = labels[ia], labels[ib]
        usable = [i for i in common
                  if a["instances"][i].get("fault") != "bench"
                  and b["instances"][i].get("fault") != "bench"]
        only_a = [i for i in usable
                  if a["instances"][i]["resolved"] and not b["instances"][i]["resolved"]]
        only_b = [i for i in usable
                  if b["instances"][i]["resolved"] and not a["instances"][i]["resolved"]]
        p = mcnemar_exact(len(only_a), len(only_b))
        print(f"  {la[:20]:<20} vs {lb[:20]:<20} "
              f"b={len(only_a)} c={len(only_b)} n_disc={len(only_a)+len(only_b)} p={p:.4f}"
              + ("" if p < 0.05 else "   (not significant)"))
        pairs.append({"a": la, "b": lb, "only_a": only_a, "only_b": only_b,
                      "b_count": len(only_a), "c_count": len(only_b),
                      "p_exact_two_sided": p, "n_paired": len(usable)})
    print()
    print("n=12 cannot rank close models; intervals above are ~25 points wide.")
    print("A non-significant p is NOT evidence the models are equal.")

    if args.json_out:
        Path(args.json_out).write_text(json.dumps(
            {"instances": common, "arms": summary, "pairwise": pairs,
             "is_full_dataset_run": False,
             "note": "paired design; exact McNemar on discordant pairs; "
                     "Wilson intervals; bench-fault instances excluded"},
            indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
