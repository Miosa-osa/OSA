"""Turn several arms' Harbor job directories into one paired comparison.

THREE THINGS THIS REFUSES TO DO
-------------------------------
1. **Rank the arms.** At n=5-8 the confidence intervals on every arm overlap
   almost everything. `ranking_supported` is computed, and on a run this size
   it is False, and the report says so in the headline rather than in a
   footnote.

2. **Pool harness faults with model faults.** The whole reason to run a
   head-to-head yourself is that you can see WHOSE fault each failure was. An
   arm that scored 2/6 because the model was wrong and an arm that scored 2/6
   because it crashed on four tasks are not the same arm, and a single accuracy
   column cannot tell them apart.

3. **Report a cost column as if it were comparable.** aider emits no telemetry
   at all, mini-swe-agent always reports $0, codex and opencode report None
   for an unpriced model. Empty is rendered as `-` and never as 0, because a
   zero in a cost column reads as "free" and here it means "not measured".

`schema_version`, `config`, `aggregate` and the honesty flags mirror
`bench/terminalbench/report.py` so `bench/report`'s gate can read this without
being taught a second schema.
"""

from __future__ import annotations

import json
import statistics
import sys
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "report"))

import attribution  # noqa: E402
import paired  # noqa: E402

try:
    import stats as report_stats  # bench/report/stats.py -- read-only use
except ImportError:  # pragma: no cover
    report_stats = None

SCHEMA_VERSION = 1
TERMINAL_BENCH_2_SIZE = 89

#: Below this many tasks, no arrangement of results can separate two close
#: arms. Used to set `ranking_supported`, which the renderer puts in the
#: headline.
MIN_N_FOR_RANKING = 20


def _mean(xs):
    xs = [x for x in xs if x is not None]
    return round(statistics.mean(xs), 2) if xs else None


def _total(xs):
    xs = [x for x in xs if x is not None]
    return sum(xs) if xs else None


def _fmt(v, suffix=""):
    """`-` for missing. NEVER 0 -- a measured zero and an absent measurement
    are different facts and only one of them is good news."""
    if v is None:
        return "-"
    if isinstance(v, float):
        return f"{v:,.2f}{suffix}"
    if isinstance(v, int):
        return f"{v:,}{suffix}"
    return f"{v}{suffix}"


def _arm_aggregate(rows: list[dict]) -> dict:
    n = len(rows)
    resolved = [r for r in rows if r["resolved"]]
    owners = {"resolved": 0, "model": 0, "harness": 0, "ambiguous": 0, "grader": 0}
    for r in rows:
        owners[r["fault_owner"]] = owners.get(r["fault_owner"], 0) + 1

    taxonomy: dict[str, int] = {}
    for r in rows:
        if r["failure_reason"]:
            taxonomy[r["failure_reason"]] = taxonomy.get(r["failure_reason"], 0) + 1

    inflicted: dict[str, int] = {}
    inflicted_tasks: dict[str, list[str]] = {}
    for r in rows:
        for k, v in (r["self_inflicted"] or {}).items():
            inflicted[k] = inflicted.get(k, 0) + v
            inflicted_tasks.setdefault(k, []).append(r["task"])

    n_harness = owners["harness"]
    n_scoreable = n - n_harness
    tok_in = _total(r["tokens_in"] for r in rows)
    tok_out = _total(r["tokens_out"] for r in rows)

    ci = None
    if report_stats and n:
        ci = report_stats.wilson(len(resolved), n).to_json()

    # Tokens are only comparable when every task reported them. An arm that
    # reported 2 of 6 has a total that is not a total.
    tok_missing = sum(1 for r in rows if r["tokens_in"] is None)

    return {
        "tasks_attempted": n,
        "tasks_resolved": len(resolved),
        "accuracy": round(len(resolved) / n, 4) if n else None,
        "accuracy_ci95": ci,
        "accuracy_excluding_harness_faults": (
            round(len(resolved) / n_scoreable, 4) if n_scoreable else None),
        "is_full_dataset_run": n == TERMINAL_BENCH_2_SIZE,
        "fault_owner_counts": owners,
        "harness_fault_rate": round(n_harness / n, 4) if n else None,
        "failure_taxonomy": dict(sorted(taxonomy.items(), key=lambda kv: -kv[1])),
        "self_inflicted_totals": dict(sorted(inflicted.items(), key=lambda kv: -kv[1])),
        "self_inflicted_tasks": inflicted_tasks,
        "wall_clock_total_s": _total(r["wall_clock_s"] for r in rows),
        "wall_clock_mean_s": _mean(r["wall_clock_s"] for r in rows),
        "agent_setup_mean_s": _mean(r["agent_setup_s"] for r in rows),
        "agent_exec_mean_s": _mean(r["agent_exec_s"] for r in rows),
        "tokens_in_total": tok_in,
        "tokens_out_total": tok_out,
        "tokens_missing_on_n_tasks": tok_missing,
        "tokens_comparable": tok_missing == 0,
        "tokens_per_resolved": (
            round((tok_in + tok_out) / len(resolved), 1)
            if resolved and tok_in is not None and tok_out is not None else None),
        "cost_usd_total": _total(r["cost_usd"] for r in rows),
        "agent_version": next((r["agent_version"] for r in rows if r["agent_version"]), None),
    }


def build(*, config: dict, job_dirs: dict[str, str], arms: list) -> dict[str, Any]:
    by_arm: dict[str, list[dict]] = {}
    families = {a.name: a.family for a in arms}
    for name, jd in job_dirs.items():
        by_arm[name] = attribution.collect_arm(Path(jd), families.get(name, "generic"))

    aggregates = {name: _arm_aggregate(rows) for name, rows in by_arm.items()}

    # -- pairing ---------------------------------------------------------
    indexed = {name: {r["task"]: r for r in rows} for name, rows in by_arm.items()}
    all_tasks = sorted({t for idx in indexed.values() for t in idx})

    per_task = []
    for t in all_tasks:
        row = {"task": t, "arms": {}}
        for name in by_arm:
            r = indexed[name].get(t)
            row["arms"][name] = None if r is None else {
                "resolved": r["resolved"],
                "reward": r["reward"],
                "fault_owner": r["fault_owner"],
                "failure_reason": r["failure_reason"] or None,
                "wall_clock_s": r["wall_clock_s"],
                "tokens_in": r["tokens_in"],
                "tokens_out": r["tokens_out"],
            }
        winners = [n for n in by_arm if (indexed[n].get(t) or {}).get("resolved")]
        row["solved_by"] = winners
        row["solved_by_none"] = not winners
        row["solved_by_all"] = len(winners) == len(by_arm)
        # A task every arm solved, or no arm solved, carries no information
        # about which harness is better. Marked so the reader can see how much
        # of the task set was actually doing any work.
        row["discriminating"] = 0 < len(winners) < len(by_arm)
        per_task.append(row)

    names = sorted(by_arm)
    pairwise = []
    for i, a in enumerate(names):
        for b in names[i + 1:]:
            pairwise.append(paired.compare(a, indexed[a], b, indexed[b]).to_json())

    n_tasks = len(all_tasks)
    n_discriminating = sum(1 for r in per_task if r["discriminating"])

    comparison = {
        "arms": names,
        "n_tasks": n_tasks,
        "n_discriminating_tasks": n_discriminating,
        "min_discordant_for_significance": paired.min_discordant_for_significance(),
        "ranking_supported": n_tasks >= MIN_N_FOR_RANKING and any(
            p["mcnemar_exact"]["significant"] for p in pairwise),
        "ranking_note": (
            f"n={n_tasks}. An exact paired test needs at least "
            f"{paired.min_discordant_for_significance()} DISCORDANT pairs "
            f"before any result can reach p<0.05; this run produced "
            f"{n_discriminating} task(s) on which the arms disagreed at all. "
            "Ordering the arms by resolve count is describing this sample, "
            "not ranking the harnesses."),
        "pairwise": pairwise,
    }

    # -- the headline claim, stated as a limit rather than a result -------
    honesty = {
        "is_full_dataset_run": n_tasks == TERMINAL_BENCH_2_SIZE,
        "model_held_fixed": config.get("model_held_fixed"),
        "model_fixed_caveat": config.get("model_fixed_caveat"),
        "arms_blocked_not_beaten": sorted(config.get("blocked_arms", {})),
        "attempts_per_task": 1,
        "claim_label": _claim_label(config, n_tasks, comparison),
        "must_not_be_quoted_as": [
            "a Terminal-Bench 2.0 score (subset run)",
            "a ranking of agent harnesses (n too small, see ranking_note)",
            "a statement about any arm in `arms_blocked_not_beaten`",
            "a cost comparison for arms whose tokens_comparable is false",
        ],
    }

    return {
        "schema_version": SCHEMA_VERSION,
        "benchmark": "terminal-bench-2.0-headtohead",
        "config": config,
        "honesty": honesty,
        "aggregate_by_arm": aggregates,
        "comparison": comparison,
        "per_task": per_task,
        "tasks_by_arm": by_arm,
    }


def _claim_label(config: dict, n_tasks: int, comparison: dict) -> str:
    if n_tasks != TERMINAL_BENCH_2_SIZE:
        base = (f"PIPELINE / DIAGNOSTIC RUN over {n_tasks} of "
                f"{TERMINAL_BENCH_2_SIZE} Terminal-Bench 2.0 tasks")
    else:
        base = "Full Terminal-Bench 2.0 head-to-head"
    if not comparison["ranking_supported"]:
        base += " — DOES NOT SUPPORT A RANKING"
    if not config.get("model_held_fixed"):
        base += " — MODEL NOT HELD FIXED: this is a model comparison, not a harness comparison"
    return base


# ---------------------------------------------------------------------------
# rendering
# ---------------------------------------------------------------------------

def report_md(results: dict) -> str:
    cfg = results["config"]
    agg = results["aggregate_by_arm"]
    cmp_ = results["comparison"]
    hon = results["honesty"]
    names = cmp_["arms"]

    L: list[str] = []
    L += [
        f"# Head-to-head — `{cfg['run_id']}`",
        "",
        f"**{hon['claim_label']}**",
        "",
        f"- **Benchmark**: Terminal-Bench 2.0 via Harbor `{cfg.get('harbor_version','?')}`",
        f"- **Tasks**: {cmp_['n_tasks']} — `{'`, `'.join(cfg.get('tasks', []))}`",
        f"- **Selection**: {cfg.get('task_selection')}",
        f"- **Model**: `{cfg.get('shared_model')}`, one shared Ollama daemon, "
        f"identical for every arm",
        f"- **Limits**: {cfg.get('limits', {}).get('wall_clock')}; "
        f"turn cap {cfg.get('limits', {}).get('turn_cap')}",
        f"- **Attempts**: 1 per task per arm (best-of-1, no reranking)",
        f"- **Graded by**: {cfg.get('graded_by')}",
        "",
        "## Why this exists",
        "",
        "Published leaderboard numbers are not comparable to ours: scaffold "
        "alone moves SWE-bench by 11-20 points for the same model, labs "
        "disagree about the denominator, and best-of-k reported as pass@1 is "
        "permitted. Putting our number next to theirs measures nothing. This "
        "runs the competitors ourselves, on the same tasks, with the same "
        "model, under the same limits — which measures something real.",
        "",
        "## The model was held fixed — with one declared asymmetry",
        "",
        cfg.get("model_fixed_caveat", ""),
        "",
        "| arm | wire protocol |",
        "|---|---|",
    ]
    for n, w in (cfg.get("arm_wire_protocols") or {}).items():
        L.append(f"| `{n}` | {w} |")

    # -- headline --------------------------------------------------------
    L += ["", "## Per-arm result", "",
          "| arm | solved | accuracy | 95% CI | harness faults | model faults | ambiguous |",
          "|---|---|---|---|---|---|---|"]
    for n in names:
        a = agg[n]
        fo = a["fault_owner_counts"]
        ci = a.get("accuracy_ci95")
        ci_s = (f"{ci['low']*100:.0f}–{ci['high']*100:.0f}%" if ci else "-")
        L.append(
            f"| `{n}` | {a['tasks_resolved']}/{a['tasks_attempted']} "
            f"| {(a['accuracy'] or 0)*100:.1f}% | {ci_s} "
            f"| {fo['harness']} | {fo['model']} | {fo['ambiguous']} |")
    L += ["",
          "> Every interval above is wide enough to contain most of the other "
          "arms. That is not a hedge, it is the measurement: "
          f"{cmp_['ranking_note']}",
          ""]

    # -- the actual comparison: failure split ----------------------------
    L += [
        "## The failure split — the part a harness actually controls",
        "",
        "A harness cannot make the model smarter. What it controls is whether "
        "the model ever got a fair attempt. `harness` failures are the arm's "
        "own doing: it failed to install, never reached the provider, crashed, "
        "or died before the grader ran. `model` failures are the arm working "
        "correctly and the answer still being wrong. `ambiguous` is timeouts, "
        "where a real internal ceiling and a slow model are indistinguishable "
        "from outside.",
        "",
        "| arm | resolved | model fault | harness fault | ambiguous | grader fault | harness-fault rate |",
        "|---|---|---|---|---|---|---|",
    ]
    for n in names:
        fo = agg[n]["fault_owner_counts"]
        L.append(
            f"| `{n}` | {fo['resolved']} | {fo['model']} | {fo['harness']} "
            f"| {fo['ambiguous']} | {fo.get('grader', 0)} "
            f"| {(agg[n]['harness_fault_rate'] or 0)*100:.1f}% |")
    L += ["",
          "> A non-zero harness-fault rate means that arm's accuracy above is "
          "**understated** by that much — and that the fix is in the harness, "
          "not the model.",
          ""]

    L += ["### Failure taxonomy per arm", ""]
    for n in names:
        tax = agg[n]["failure_taxonomy"]
        L.append(f"**`{n}`** — " + (", ".join(f"`{k}` x{v}" for k, v in tax.items())
                                    if tax else "_no failures_"))
    L.append("")

    # -- paired table ----------------------------------------------------
    L += ["## Per task, every arm", "",
          "`Y` solved. Otherwise the fault owner: `model` / `harness` / "
          "`ambig` / `grader`.", "",
          "| task | " + " | ".join(f"`{n}`" for n in names) + " | discriminating |",
          "|---|" + "---|" * (len(names) + 1)]
    short = {"model": "model", "harness": "**harness**", "ambiguous": "ambig",
             "grader": "grader", "resolved": "Y"}
    for row in results["per_task"]:
        cells = []
        for n in names:
            c = row["arms"].get(n)
            cells.append("_not run_" if c is None else short.get(c["fault_owner"], "?"))
        cells.append("yes" if row["discriminating"] else "no")
        L.append(f"| `{row['task']}` | " + " | ".join(cells) + " |")
    L += ["",
          f"Only **{cmp_['n_discriminating_tasks']} of {cmp_['n_tasks']}** "
          "tasks separated the arms at all. Tasks every arm solved, or no arm "
          "solved, contribute nothing to a comparison — which is why the "
          "effective sample here is smaller than the task count suggests.",
          ""]

    # -- pairwise --------------------------------------------------------
    L += ["## Paired tests (exact McNemar)", "",
          "Two arms on the same tasks are one sample measured twice, so only "
          "the tasks they DISAGREED on carry information.", "",
          "| A | B | A only | B only | both | neither | p (exact) | verdict |",
          "|---|---|---|---|---|---|---|---|"]
    for p in cmp_["pairwise"]:
        t = p["mcnemar_exact"]
        L.append(
            f"| `{p['arm_a']}` | `{p['arm_b']}` | {p['a_only']} | {p['b_only']} "
            f"| {p['both_solved']} | {p['neither_solved']} | {t['p_value']} "
            f"| {'DISTINGUISHABLE' if t['significant'] else 'not distinguishable'} |")
    L += ["",
          f"> At least **{cmp_['min_discordant_for_significance']} discordant "
          "pairs** are required before any two-sided exact result can reach "
          "p<0.05. Below that, 'not distinguishable' is a statement about the "
          "experiment's size, not about the arms.",
          ""]

    # -- cost ------------------------------------------------------------
    L += ["## Cost of the result", "",
          "| arm | wall total | wall mean/task | setup mean | tok in | tok out | "
          "tok/solved | cost | tokens comparable? |",
          "|---|---|---|---|---|---|---|---|---|"]
    for n in names:
        a = agg[n]
        comparable = ("yes" if a["tokens_comparable"]
                      else f"NO ({a['tokens_missing_on_n_tasks']} task(s) missing)")
        L.append(
            f"| `{n}` | {_fmt(a['wall_clock_total_s'],' s')} "
            f"| {_fmt(a['wall_clock_mean_s'],' s')} "
            f"| {_fmt(a['agent_setup_mean_s'],' s')} "
            f"| {_fmt(a['tokens_in_total'])} | {_fmt(a['tokens_out_total'])} "
            f"| {_fmt(a['tokens_per_resolved'])} | {_fmt(a['cost_usd_total'])} "
            f"| {comparable} |")
    L += ["",
          "> `-` means **not measured**, never zero. aider's adapter reports no "
          "telemetry at all; mini-swe-agent always reports $0 because the model "
          "is not in LiteLLM's price map; codex and opencode return no cost for "
          "an unpriced model. A cost column across these arms is not a cost "
          "comparison and is not offered as one.",
          ""]

    # -- self-inflicted --------------------------------------------------
    L += ["## Self-inflicted markers", "",
          "Scraped from each arm's own logs. A **signal, not a verdict** — "
          "these never move an arm's fault attribution. One that recurs across "
          "tasks is a bug report waiting to be written.", ""]
    any_marker = False
    for n in names:
        tot = agg[n]["self_inflicted_totals"]
        if not tot:
            continue
        any_marker = True
        L += [f"**`{n}`**", "", "| marker | occurrences | tasks |", "|---|---|---|"]
        for k, v in tot.items():
            L.append(f"| {k} | {v} | {len(set(agg[n]['self_inflicted_tasks'].get(k, [])))} |")
        L.append("")
    if not any_marker:
        L += ["_None observed._", ""]

    # -- blocked ---------------------------------------------------------
    L += ["## Arms that were NOT run", "",
          "These are missing credentials and protocol mismatches. **None of "
          "this is a result about those agents.** An arm we could not point at "
          "the shared model is an arm we did not measure.", "",
          "| arm | blocker | why |", "|---|---|---|"]
    for name, b in (cfg.get("blocked_arms") or {}).items():
        L.append(f"| `{name}` | {b['blocker']} | {b['reason']} |")
    L.append("")

    # -- integrity -------------------------------------------------------
    L += ["## Run integrity", "",
          "| check | result |", "|---|---|"]
    pb, pa = cfg.get("provider_probe_before", {}), cfg.get("provider_probe_after", {})
    L += [f"| shared model reachable before | {pb.get('shared_model_present')} |",
          f"| shared model reachable after | {pa.get('shared_model_present')} |",
          f"| contamination probe (live containers) | "
          f"{(cfg.get('contamination_probe') or {}).get('status', 'not run')} |",
          f"| disk free before / after | {cfg.get('disk_free_gb_before')} GB / "
          f"{cfg.get('disk_free_gb_after')} GB |",
          f"| harbor exit code per arm | {cfg.get('arm_exit_codes')} |",
          ""]

    L += ["## What this can and cannot support", "",
          "**Can**: the harness-vs-model failure split per arm, on identical "
          "tasks with an identical model — the one thing a harness actually "
          "controls. Whether an arm can complete a long-horizon terminal task "
          "at all. Wall-clock and token cost of an attempt, for the arms whose "
          "telemetry is comparable.", "",
          "**Cannot**: rank the arms. Produce a Terminal-Bench 2.0 score. Say "
          "anything about the arms listed as not run. Compare cost across arms "
          "with missing telemetry. Distinguish a harness's ceiling from a slow "
          "model on the timeout rows.", "",
          "See `bench/headtohead/README.md` and `bench/report/METHODOLOGY.md`."]
    return "\n".join(L) + "\n"


def print_headline(results: dict) -> None:
    agg = results["aggregate_by_arm"]
    print("\n" + "=" * 66)
    print(results["honesty"]["claim_label"])
    print("=" * 66)
    for n in results["comparison"]["arms"]:
        a = agg[n]
        fo = a["fault_owner_counts"]
        print(f"  {n:16} {a['tasks_resolved']}/{a['tasks_attempted']} solved   "
              f"model-fault={fo['model']} harness-fault={fo['harness']} "
              f"ambiguous={fo['ambiguous']}")
    print(f"\n  {results['comparison']['ranking_note']}\n")


def write(results: dict, out_dir: Path) -> tuple[Path, Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    rj = out_dir / "results.json"
    rm = out_dir / "report.md"
    rj.write_text(json.dumps(results, indent=2) + "\n")
    rm.write_text(report_md(results))
    return rj, rm


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: report_h2h.py <run-dir>   (re-renders results.json)")
    run_dir = Path(sys.argv[1])
    res = json.loads((run_dir / "results.json").read_text())
    (run_dir / "report.md").write_text(report_md(res))
    print_headline(res)
    print(f"rewrote {run_dir / 'report.md'}")
