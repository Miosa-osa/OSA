#!/usr/bin/env python3
"""Price every arm at ONE rate table, stated, and never from a stored `cost_usd`.

`probeset.arms` already does this, but its `GLM_RATES` constant is
`(0.60, 2.20)` — GLM-**4.7**'s rate, which is the 2.4x under-billing
`zai_models.ex` was written to end. Re-using it would carry that error into the
comparison it exists to make honest. This module keeps the rate tables explicit
and prints the arm under each of them, because the two arms were served by
different paths and there is no single "correct" price that is fair to both:

* `openrouter_live` — what THIS run was actually billed. Retrieved from
  `GET /api/v1/models` at launch, not from a doc.
* `zai_first_party` — Z.ai's own published rate for GLM-5.2, which is what the
  Ollama `glm-5.2:cloud` baseline would have cost had it been priced correctly.

The like-for-like token comparison uses ONE table across both arms and is the
figure to read for "did the harness get cheaper". The per-arm actual is the
figure to read for "what did it cost". They are different questions and are
never merged.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import probeset as ps  # noqa: E402

#: $/M input, $/M output, $/M cached-read.
RATES = {
    # Live OpenRouter aggregate route for `z-ai/glm-5.2`, GET /api/v1/models,
    # 2026-08-16. NOTE this is 2.58x BELOW the $1.19/$3.74 the bench README
    # records from 2026-08-14 — the route price moved, and it is also 3x below
    # Z.ai's own first-party endpoint, so OpenRouter is not defaulting to the
    # vendor endpoint. Recorded rather than corrected.
    "openrouter_live": (0.462, 1.452, 0.0858),
    # Z.ai's published GLM-5.2 rate (docs.z.ai pricing, cross-checked against
    # OpenRouter's `/models/z-ai/glm-5.2/endpoints` first-party row). This is
    # the rate `glm-5.2:cloud` should always have been billed at.
    "zai_first_party": (1.40, 4.40, 0.26),
    # What the baseline actually recorded. Kept ONLY so the size of the error
    # is visible; never use it for a comparison.
    "legacy_wrong": (0.60, 2.20, None),
}


def price(tok_in: float, tok_out: float, cache_read: float, table: str) -> float:
    r_in, r_out, r_cache = RATES[table]
    uncached = max(tok_in - cache_read, 0)
    c = uncached * r_in / 1e6 + tok_out * r_out / 1e6
    c += cache_read * (r_cache if r_cache is not None else r_in) / 1e6
    return c


def arm_from_results(path: Path, tasks: tuple[str, ...]) -> dict:
    doc = json.loads(path.read_text())
    rows = {
        t["task_name"].split("/")[-1]: t
        for t in doc["tasks"]
        if t["task_name"].split("/")[-1] in tasks
    }
    tin = tout = cread = cwrite = 0
    have_cache = False
    resolved = []
    for name, t in rows.items():
        r, w = t.get("tokens_cache_read"), t.get("tokens_cache_write")
        if r is not None or w is not None:
            have_cache = True
        cread += r or 0
        cwrite += w or 0
        tin += (t.get("tokens_in") or 0) + (r or 0) + (w or 0)
        tout += t.get("tokens_out") or 0
        if t["resolved"]:
            resolved.append(name)
    n = len(rows) or 1
    return {
        "n": len(rows),
        "resolved": len(resolved),
        "resolved_tasks": sorted(resolved),
        "tokens_in_total": tin,
        "tokens_out_total": tout,
        "cache_read_total": cread,
        "cache_write_total": cwrite,
        "have_cache_counter": have_cache,
        "input_tokens_per_task": tin / n,
        "output_tokens_per_task": tout / n,
        "in_out_ratio": tin / tout if tout else None,
        "cache_hit_rate": (cread / tin if have_cache and tin else None),
        "per_task": {
            k: {
                "in": (v.get("tokens_in") or 0)
                + (v.get("tokens_cache_read") or 0)
                + (v.get("tokens_cache_write") or 0),
                "out": v.get("tokens_out") or 0,
                "cache_read": v.get("tokens_cache_read"),
                "resolved": v["resolved"],
                "wall_s": v.get("wall_clock_s"),
            }
            for k, v in rows.items()
        },
    }


def baseline_arm(tasks: tuple[str, ...]) -> dict:
    b = ps._TB_BASELINE
    per = b["per_task_input_tokens"]
    tin = sum(per[t] for t in tasks)
    tout = b["output_tokens_total"]
    n = len(tasks)
    return {
        "n": n,
        "resolved": b["resolved"],
        "resolved_tasks": b["resolved_tasks"],
        "tokens_in_total": tin,
        "tokens_out_total": tout,
        "cache_read_total": 0,
        "cache_write_total": 0,
        "have_cache_counter": False,
        "input_tokens_per_task": tin / n,
        "output_tokens_per_task": tout / n,
        "in_out_ratio": tin / tout if tout else None,
        "cache_hit_rate": None,
        "per_task": {t: {"in": per[t], "out": None,
                         "resolved": t in b["resolved_tasks"]} for t in tasks},
    }


def wilson(k: int, n: int, z: float = 1.96) -> tuple[float, float]:
    if n == 0:
        return (0.0, 0.0)
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * ((p * (1 - p) / n + z * z / (4 * n * n)) ** 0.5) / d
    return (max(0.0, c - h), min(1.0, c + h))


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: reprice.py runs/<new-run>")
        return 2
    p = Path(argv[1])
    p = p if p.is_file() else p / "results.json"
    probe = ps.get("tb2.1")

    after = arm_from_results(p, probe.tasks)
    after["_label"] = argv[1].rstrip("/").split("/")[-1]
    # The `before` arm defaults to the RECORDED baseline in `probeset.py`, which
    # is the contractual one. It is also the WORST-controlled one: it ran on
    # Ollama with reasoning off (`maybe_add_think/3`'s default), so a comparison
    # against it mixes the 16 fixes with an 11.2 pp reasoning switch and a
    # change of serving path. Pass a run directory as argv[2] to use a
    # better-matched predecessor instead — `osa-tb20-full89-f6981b61` ran the
    # same eight tasks at `effort=medium, think=true`, differing from this arm
    # only in the OSA build and the serving path.
    if len(argv) > 2:
        q = Path(argv[2])
        before = arm_from_results(q if q.is_file() else q / "results.json", probe.tasks)
        before["_label"] = Path(argv[2]).name
    else:
        before = baseline_arm(probe.tasks)
        before["_label"] = "recorded baseline"

    print(f"# tb-cost-probe-v1 — {before['_label']} vs {after['_label']}\n")
    print("Both arms priced from TOKEN COUNTS at the same table. Stored "
          "`cost_usd` is ignored on both sides.\n")

    for table in ("openrouter_live", "zai_first_party"):
        r = RATES[table]
        print(f"\n## priced at `{table}` (${r[0]}/M in, ${r[1]}/M out, "
              f"${r[2]}/M cache-read)\n")
        print(f"| metric | {before['_label']} ({before['resolved']}/{before['n']}) | {after['_label']} | change |")
        print("|---|---:|---:|---:|")
        rows = [
            ("input tok/task", "input_tokens_per_task", "{:,.0f}"),
            ("output tok/task", "output_tokens_per_task", "{:,.0f}"),
            ("in:out", "in_out_ratio", "{:.1f}:1"),
        ]
        for label, key, spec in rows:
            x, y = before[key], after[key]
            d = f"{(y - x) / x * 100:+.1f}%" if x else "n/a"
            print(f"| {label} | {spec.format(x)} | {spec.format(y)} | {d} |")
        for label, key in (("cache hit", "cache_hit_rate"),):
            x, y = before[key], after[key]
            f = lambda v: "None (not reported)" if v is None else f"{v:.2%}"  # noqa: E731
            print(f"| {label} | {f(x)} | {f(y)} | — |")
        cb = price(before["tokens_in_total"], before["tokens_out_total"], 0, table) / before["n"]
        ca = price(after["tokens_in_total"], after["tokens_out_total"],
                   after["cache_read_total"], table) / after["n"]
        print(f"| $/task | ${cb:.4f} | ${ca:.4f} | {(ca - cb) / cb * 100:+.1f}% |")
        print(f"| solved | {before['resolved']}/{before['n']} | "
              f"{after['resolved']}/{after['n']} | — |")

    lo, hi = wilson(after["resolved"], after["n"])
    blo, bhi = wilson(before["resolved"], before["n"])
    print(f"\n## solve rate\n")
    print(f"{before['_label']} {before['resolved']}/{before['n']} "
          f"= {before['resolved']/before['n']:.1%} (95% Wilson {blo:.1%}–{bhi:.1%})")
    print(f"{after['_label']}   {after['resolved']}/{after['n']} "
          f"= {after['resolved']/after['n']:.1%} (95% Wilson {lo:.1%}–{hi:.1%})")
    gained = sorted(set(after["resolved_tasks"]) - set(before["resolved_tasks"]))
    lost = sorted(set(before["resolved_tasks"]) - set(after["resolved_tasks"]))
    print(f"gained: {gained or 'none'}")
    print(f"lost:   {lost or 'none'}")
    if lost:
        print("\n> **SOLVE RATE REGRESSION on the tasks above.** Those tasks are "
              "no longer paired cost observations and a token reduction on them "
              "is not a win.")

    print("\n## per task\n")
    print(f"| task | {before['_label']} in | {after['_label']} in | change | verdict |")
    print("|---|---:|---:|---:|---|")
    for t in probe.tasks:
        b = before["per_task"][t]
        a = after["per_task"].get(t)
        if a is None:
            print(f"| `{t}` | {b['in']:,} | — | — | NOT RUN |")
            continue
        d = f"{(a['in'] - b['in']) / b['in'] * 100:+.1f}%" if b["in"] else "n/a"
        v = f"{'pass' if b['resolved'] else 'fail'} -> {'pass' if a['resolved'] else 'fail'}"
        flag = "" if b["resolved"] == a["resolved"] else "  **unpaired**"
        print(f"| `{t}` | {b['in']:,} | {a['in']:,} | {d} | {v}{flag} |")

    json.dump({"before": before, "after": after},
              open(Path(argv[1]).parent / "reprice.json"
                   if Path(argv[1]).is_file() else Path(argv[1]) / "reprice.json", "w"),
              indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
