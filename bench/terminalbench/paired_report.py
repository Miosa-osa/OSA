#!/usr/bin/env python3
"""Lay two full-dataset runs side by side, at one rate table, with intervals.

`reprice.py` does this for the eight-task cost probe and iterates
`probeset.tasks`, so it cannot read a full run. `probeset.arms` re-prices but
carries GLM-4.7's rate. This is the full-dataset version, and it exists to make
four specific claims safe to publish:

1. **Three denominators, never one.** `raw` is what a reader would compute from
   the results file. `sound` removes the tasks the oracle cannot solve on this
   machine (`controls.py`'s `graded_wrong` list) plus the non-conforming task
   copies -- both are exclusions *with a stated cause*, decided before the run,
   not after seeing which way they went. `sound_untimed` additionally removes
   trials that ended on a timeout, because a verdict on a task sitting on its
   ceiling is a coin flip and both arms have been watched flipping.

2. **Wilson intervals on all of them.** At n=89 a single run's 95% interval is
   about +/-10 points. Most deltas anyone wants to quote are inside it.

3. **One rate table across both arms.** The stored `cost_usd` of the two arms
   was computed at rates 2.4x apart (`zai_models.ex`), so a stored-dollar delta
   is a pricing-bug artefact. Everything here is re-derived from tokens.

4. **Flips are named in both directions**, and the regressions are printed
   first, because a task that got worse is the finding.

Usage:
    ./paired_report.py runs/<before> runs/<after> [--rate openrouter_live]
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import datasets as datasets_mod  # noqa: E402
from reprice import RATES  # noqa: E402


def wilson(k: int, n: int) -> tuple[float, float]:
    """95% Wilson score interval. Returns (0, 0) for an empty denominator."""
    if not n:
        return (0.0, 0.0)
    z = 1.959963984540054
    p = k / n
    d = 1 + z * z / n
    c = p + z * z / (2 * n)
    m = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))
    return ((c - m) / d, (c + m) / d)


#: Failure reasons that mean "the clock ran out", not "the answer was wrong".
#: Both arms are read with the same list, so a timeout-shaped exclusion cannot
#: favour one of them.
TIMEOUT_REASONS = ("agent_timeout", "harness_exception:AgentTimeoutError")


def load(run_dir: Path) -> dict:
    d = json.loads((run_dir / "results.json").read_text())
    tasks = {}
    for t in d["tasks"]:
        name = t["task_name"].split("/")[-1]
        tasks[name] = t
    d["_by_name"] = tasks
    d["_label"] = run_dir.name
    return d


def oracle_broken(dataset_key: str) -> set[str]:
    """Tasks whose OWN reference solution does not pass on this machine.

    Read from the control observations rather than hardcoded, so this cannot
    drift away from what `controls.py gate` enforces.
    """
    path = HERE / "runs" / "_controls" / dataset_key / "controls.json"
    if not path.exists():
        return set()
    obs = json.loads(path.read_text()).get("observations", {})
    out = set()
    for name, e in obs.items():
        o = e.get("oracle")
        if not o:
            continue
        r = o.get("reward")
        if r is None or r < 1.0:
            out.add(name)
    return out


def cost(t: dict, rate: tuple[float, float, float]) -> float:
    """Dollars for one trial, re-derived from its tokens at `rate`.

    `results.json`'s per-task `tokens_in` is the **uncached remainder**, not the
    cache-inclusive figure (`report.py:544`, and the summary renders it as
    "tokens in (uncached only)"). Only the AGGREGATE `input_tokens_per_task`
    adds the cache columns back. Getting this backwards double-counts every
    cache read at the full input rate, which on a 96%-cached arm is an order of
    magnitude, so it is spelled out here rather than left to the reader.
    """
    r_in, r_out, r_cache = rate
    cread = t.get("tokens_cache_read") or 0
    cwrite = t.get("tokens_cache_write") or 0
    uncached = t.get("tokens_in") or 0
    c = uncached / 1e6 * r_in + (t.get("tokens_out") or 0) / 1e6 * r_out
    if r_cache is not None:
        c += cread / 1e6 * r_cache
    # Cache writes bill at 1.25x input on every provider that charges for them.
    c += cwrite / 1e6 * r_in * 1.25
    return c


def slices(run: dict, excluded: set[str]) -> dict:
    """The three denominators, as {name: (resolved, attempted, [tasks])}."""
    names = sorted(run["_by_name"])
    raw = names
    sound = [n for n in raw if n not in excluded]
    untimed = [
        n for n in sound
        if (run["_by_name"][n].get("failure_reason") or "") not in TIMEOUT_REASONS
    ]
    out = {}
    for label, sel in (("raw", raw), ("sound", sound), ("sound_untimed", untimed)):
        k = sum(1 for n in sel if run["_by_name"][n].get("resolved"))
        out[label] = (k, len(sel), sel)
    return out


def columns(run: dict, names: list[str], rate) -> dict:
    """The four columns the field publishes, over a named task subset."""
    ts = [run["_by_name"][n] for n in names]
    uncached = sum(t.get("tokens_in") or 0 for t in ts)
    tout = sum(t.get("tokens_out") or 0 for t in ts)
    cread = sum(t.get("tokens_cache_read") or 0 for t in ts)
    cwrite = sum(t.get("tokens_cache_write") or 0 for t in ts)
    have_cache = any(t.get("tokens_cache_read") is not None for t in ts)
    # THE cache-inclusive numerator, which is what Harbor's schema means by
    # input tokens and what every reference adapter reports. Quoting the
    # uncached figure here would flatter a cached arm by up to 25x.
    tin = uncached + cread + cwrite
    n = len(ts) or 1
    return {
        "n": len(ts),
        "input_tokens_per_task": tin / n,
        "in_out_ratio": (tin / tout) if tout else None,
        "cache_hit_rate": (cread / tin) if (have_cache and tin) else None,
        "cost_usd_per_task": sum(cost(t, rate) for t in ts) / n,
        "cost_usd_total": sum(cost(t, rate) for t in ts),
        "uncached_input_total": uncached,
        "tokens_in_total": tin,
        "tokens_out_total": tout,
        "cache_read_total": cread,
    }


def fmt_rate(k: int, n: int) -> str:
    lo, hi = wilson(k, n)
    return f"{k}/{n} = {k / n * 100:.2f}%  (95% Wilson {lo * 100:.1f}–{hi * 100:.1f}%)"


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("before")
    ap.add_argument("after")
    ap.add_argument("--rate", default="openrouter_live", choices=sorted(RATES))
    ap.add_argument("--compare-to", type=float, default=68.5,
                    help="an external published rate, in percent (cline: 68.5)")
    args = ap.parse_args(argv[1:])

    b, a = load(Path(args.before)), load(Path(args.after))
    rate = RATES[args.rate]
    key = a["config"]["dataset_key"]

    broken = oracle_broken(key)
    # NONCONFORMING_TASKS is keyed by dataset first, then by task.
    nonconforming = set(
        (getattr(datasets_mod, "NONCONFORMING_TASKS", {}) or {}).get(key, {})
    )
    excluded = broken | nonconforming

    print(f"# paired report — `{b['_label']}`  ->  `{a['_label']}`\n")
    print(f"- dataset `{key}`, rate table `{args.rate}` "
          f"= ${rate[0]}/M in, ${rate[1]}/M out, ${rate[2]}/M cache-read")
    print(f"- excluded with cause: {len(excluded)} task(s)")
    print(f"  - oracle cannot solve them here ({len(broken)}): "
          f"{', '.join(sorted(broken)) or 'none'}")
    print(f"  - non-conforming task copy ({len(nonconforming)}): "
          f"{', '.join(sorted(nonconforming)) or 'none'}")

    print("\n## headline\n")
    print("| slice | before | after |")
    print("|---|---|---|")
    sb, sa = slices(b, excluded), slices(a, excluded)
    for label in ("raw", "sound", "sound_untimed"):
        kb, nb, _ = sb[label]
        ka, na, _ = sa[label]
        print(f"| `{label}` | {fmt_rate(kb, nb)} | {fmt_rate(ka, na)} |")

    ka, na, _ = sa["sound"]
    lo, hi = wilson(ka, na)
    ext = args.compare_to / 100
    verdict = ("INSIDE this run's interval — not distinguishable on this evidence"
               if lo <= ext <= hi else
               "OUTSIDE this run's interval")
    print(f"\nExternal comparison: cline {args.compare_to}% is **{verdict}** "
          f"(sound slice, {lo * 100:.1f}–{hi * 100:.1f}%).")

    print("\n## the four published columns, both arms at one rate table\n")
    print("| column | before | after |")
    print("|---|---:|---:|")
    cb = columns(b, sb["raw"][2], rate)
    ca = columns(a, sa["raw"][2], rate)
    rows = [
        ("input tok/task (cache-incl.)", "input_tokens_per_task", "{:,.0f}"),
        ("in:out ratio", "in_out_ratio", "{:.1f}:1"),
        ("cache hit rate", "cache_hit_rate", "{:.1%}"),
        ("$/task (token-derived)", "cost_usd_per_task", "${:.4f}"),
        ("$ total (token-derived)", "cost_usd_total", "${:.2f}"),
    ]
    for label, k, f in rows:
        vb, va = cb[k], ca[k]
        print(f"| {label} | {f.format(vb) if vb is not None else '—'} "
              f"| {f.format(va) if va is not None else '—'} |")

    print("\n> Token-derived dollars are a LOWER BOUND on this route: "
          "`z-ai/glm-5.2` is served by many endpoints across a wide price band, "
          "chosen per request, and nothing we log records which one served a "
          "call. Read the billed figure from `spend_watch.py report` beside "
          "this, never instead of it.")

    print("\n## flips\n")
    common = sorted(set(b["_by_name"]) & set(a["_by_name"]))
    lost = [n for n in common
            if b["_by_name"][n].get("resolved") and not a["_by_name"][n].get("resolved")]
    gained = [n for n in common
              if not b["_by_name"][n].get("resolved") and a["_by_name"][n].get("resolved")]

    print(f"### REGRESSED — pass -> fail ({len(lost)})\n")
    if lost:
        print("| task | after: reason | after: owner | excluded? |")
        print("|---|---|---|---|")
        for n in lost:
            t = a["_by_name"][n]
            print(f"| `{n}` | {t.get('failure_reason') or '—'} "
                  f"| {t.get('fault_owner') or '—'} "
                  f"| {'yes' if n in excluded else 'no'} |")
    else:
        print("_none_")

    print(f"\n### improved — fail -> pass ({len(gained)})\n")
    if gained:
        print("| task | before: reason | before: owner |")
        print("|---|---|---|")
        for n in gained:
            t = b["_by_name"][n]
            print(f"| `{n}` | {t.get('failure_reason') or '—'} "
                  f"| {t.get('fault_owner') or '—'} |")
    else:
        print("_none_")

    print(f"\nNet {len(gained) - len(lost):+d} tasks. At n=1 per task each of "
          f"these is a single sample; a task has been watched flipping "
          f"4-pass/2-fail with no code change at all.")

    print("\n## harness faults\n")
    print("| arm | fault owners | harness fault rate |")
    print("|---|---|---|")
    for run in (b, a):
        ag = run["aggregate"]
        print(f"| `{run['_label']}` | {ag['fault_owner_counts']} "
              f"| {ag['harness_fault_rate'] * 100:.2f}% |")

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
