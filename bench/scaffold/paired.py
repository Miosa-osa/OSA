#!/usr/bin/env python3
"""Paired read-out of the scaffold ablation: N arms against one baseline.

    ./paired.py <baseline_run> <arm_run> [<arm_run> ...]

## Relationship to the two neighbouring tools

`bench/report/cli.py compare` uses `stats.two_proportion` (Newcombe), which
assumes the two samples are **independent**. These arms are not: every instance
appears in every arm, same seed, same model, same limits. That path is wrong
here and is not used.

`bench/swebenchpro/ablation.py` does the correct paired thing for exactly two
runs, and its labels are hard-wired to the context-mode ablation it was written
for. This is the same statistics generalised to a matrix, with a joint
per-instance grid so a reader can see which instances are load-bearing across
*all* arms rather than one pair at a time. The exact-binomial machinery is
imported from `bench/report/stats.py`; nothing is reimplemented.

## What n=12 can and cannot do

It cannot rank arms that are close. With 12 paired instances, an arm must lose
or gain about 5 instances before an exact McNemar test clears p<0.05 — so every
delta printed here is reported with its exact interval and, in the usual case,
the honest verdict is "this run does not establish a difference".

What it CAN do, and what this experiment is actually for: identify a component
whose removal changes **nothing** — same instances solved, zero discordant
pairs. That is a real result at n=12, because it is a statement about the
observed instances rather than an estimate about a population. Report it as
"no measured effect on these 12", never as "proven equivalent".

## The repeat arm is the yardstick

An arm labelled `repeat` (identical settings to the baseline) measures
run-to-run noise on this instance set. Any other arm's discordant-pair count
must be read against it. `bench/FINDINGS.md` #8 records 9 of 40 instances
flipping between two identical runs, so the noise floor here is not small and
an arm that flips 2 instances has probably not done anything.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "report"))

import stats  # type: ignore  # bench/report/stats.py, read-only

PAIRING_KEYS = ("model", "attempts", "max_turns", "agent_timeout_s",
                "context_mode", "test_file_hint", "test_bridge",
                "harness_commit", "dataset_name", "split")


def load(run: Path) -> tuple[dict, dict]:
    d = json.loads((run / "results.json").read_text())
    return d, {i["instance_id"]: i for i in d["instances"]}


def mcnemar_exact(b: int, c: int) -> float:
    """Two-sided exact McNemar: a binomial test at p=0.5 on the discordants."""
    n = b + c
    if n == 0:
        return 1.0
    tail = min(stats._binom_cdf_le(b, n, 0.5), stats._binom_sf_ge(b, n, 0.5))
    return min(1.0, 2.0 * tail)


def check_pairing(base: dict, arm: dict, name: str) -> list[str]:
    """Everything except the treatment must match, or the pairing is a fiction."""
    bad = []
    for k in PAIRING_KEYS:
        va, vb = base["config"].get(k), arm["config"].get(k)
        if va != vb:
            bad.append(f"{k}: {va!r} != {vb!r}")
    sa = base["config"].get("sampling", {}).get("seed")
    sb = arm["config"].get("sampling", {}).get("seed")
    if sa != sb:
        bad.append(f"sampling.seed: {sa!r} != {sb!r}")
    return bad


def fault_ok(doc: dict, name: str) -> bool:
    """A provider outage or harness bug outranks any ablation reading."""
    dg = (doc["aggregate"].get("diagnosis") or {}).get("by_fault") or {}
    bad = int(dg.get("bench", 0)) + int(dg.get("harness", 0))
    if bad:
        print(f"  !! {name}: {bad} instance(s) with fault=bench/harness "
              f"({dg}). Per bench/FINDINGS.md #2 a provider 429 is recorded as "
              f"fault=bench by runners.provider_failure(); this arm is NOT a "
              f"clean measurement and must not be compared.")
        return False
    return True


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    base_dir = Path(sys.argv[1])
    arm_dirs = [Path(p) for p in sys.argv[2:]]

    B, b = load(base_dir)
    ids = [i["instance_id"] for i in B["instances"]]
    arms = []

    print("=== integrity: pairing and fault attribution ===")
    clean = fault_ok(B, base_dir.name)
    for d in arm_dirs:
        A, a = load(d)
        missing = [i for i in ids if i not in a]
        if missing or len(a) != len(ids):
            print(f"  !! {d.name}: NOT PAIRED, instance sets differ "
                  f"({len(ids)} vs {len(a)}); missing {missing[:3]}")
            continue
        bad = check_pairing(B, A, d.name)
        if bad:
            print(f"  !! {d.name}: config differs beyond the treatment: {bad}")
        ok = fault_ok(A, d.name)
        clean = clean and ok and not bad
        arms.append((d.name, A, a))
    if clean:
        print("  OK: every arm is paired on the same 12 instances, same seed, "
              "same limits, zero bench/harness faults.")
    if not arms:
        return 1

    # ---- joint per-instance grid -----------------------------------------
    print(f"\n=== per-instance outcomes (the primary result) ===")
    hdr = f"{'base':>5}" + "".join(f" {n[:12]:>13}" for n, _, _ in arms)
    print(hdr + "  instance")
    for iid in ids:
        rb = b[iid]["resolved"]
        row = f"{'YES' if rb else 'no':>5}"
        for _, _, a in arms:
            ra = a[iid]["resolved"]
            mark = "" if ra == rb else (" GAIN" if ra else " LOST")
            row += f" {('YES' if ra else 'no') + mark:>13}"
        print(row + f"  {iid[:52]}")

    # ---- paired stats per arm --------------------------------------------
    n = len(ids)
    kb = sum(b[i]["resolved"] for i in ids)
    ib = stats.wilson(kb, n)
    print(f"\n=== paired difference vs baseline ({base_dir.name}: {kb}/{n}, "
          f"{ib.low * 100:.1f}-{ib.high * 100:.1f}% Wilson) ===")
    print(f"{'arm':<18} {'k/n':>6} {'delta':>8} {'b':>3} {'c':>3} {'disc':>5} "
          f"{'McNemar p':>10}  95% CI on delta")
    for name, A, a in arms:
        ka = sum(a[i]["resolved"] for i in ids)
        bb = sum(1 for i in ids if b[i]["resolved"] and not a[i]["resolved"])
        cc = sum(1 for i in ids if a[i]["resolved"] and not b[i]["resolved"])
        disc = bb + cc
        p = mcnemar_exact(bb, cc)
        if disc:
            ci = stats.clopper_pearson(bb, disc, 0.95)
            lo = (2 * ci.low - 1) * disc / n * 100
            hi = (2 * ci.high - 1) * disc / n * 100
            # b counts baseline-only wins, so a positive b means the arm LOST.
            ci_s = f"{-hi:+.1f} pp to {-lo:+.1f} pp"
        else:
            ci_s = "0 discordant pairs -> no evidence of any effect"
        print(f"{name:<18} {ka:>3}/{n:<2} {100 * (ka - kb) / n:>+7.1f}% "
              f"{bb:>3} {cc:>3} {disc:>5} {p:>10.4f}  {ci_s}")

    # ---- effort ----------------------------------------------------------
    print(f"\n=== effort per arm ===")
    print(f"{'arm':<18} {'tok_in':>13} {'cost':>9} {'wall/inst':>10} "
          f"{'turns':>7} {'tools':>7}")
    for name, doc in [(base_dir.name, B)] + [(n_, d) for n_, d, _ in arms]:
        g = doc["aggregate"]
        print(f"{name:<18} {g['tokens_in_total']:>13,} "
              f"${g['cost_usd_total']:>8,.2f} "
              f"{g['wall_clock_mean_s'] / 60:>9.1f}m "
              f"{g['turns_mean']:>7.1f} {g['tool_calls_mean']:>7.1f}")

    print(f"\n=== honesty flags carried from every arm ===")
    for name, doc in [(base_dir.name, B)] + [(n_, d) for n_, d, _ in arms]:
        g = doc["aggregate"]
        print(f"  {name:<18} is_full_dataset_run={g.get('is_full_dataset_run')} "
              f"attempts={doc['config'].get('attempts')} "
              f"pass_at_1={g.get('pass_at_1')}")
    print(f"\n  n={n} of {B['config'].get('dataset_size')}. Not a SWE-bench Pro "
          f"score. Hard-weighted sample (mean hardness "
          f"{B['config'].get('sampling', {}).get('mean_hardness_sample')} vs "
          f"{B['config'].get('sampling', {}).get('mean_hardness_population')} "
          f"for the population). Single trial per arm, no variance estimate "
          f"except via a `repeat` arm.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
