"""Turn two Harbor job directories into one fresh-vs-corrupted delta.

Named ``delta_report`` rather than ``report`` on purpose: this module imports
``bench/terminalbench/report.py``, and with both directories on ``PYTHONPATH``
(which the corrupted arm needs) two modules called ``report`` resolve by path
order. The first version of this file was called ``report.py`` and ``run_bench``
silently bound the *Terminal-Bench* reporter instead of this one.

``bench/terminalbench/report.py`` already knows how to read a Harbor trial,
decide whether it passed, and — the part that matters here — attribute a
failure to the *model* or to *OSA/the harness*. All of that is imported rather
than restated; this module adds only what is specific to a two-arm experiment.

--------------------------------------------------------------------------
Why the paired intersection is the headline and not the two arm accuracies
--------------------------------------------------------------------------

A delta between two arms that ran different task sets measures task difficulty,
not recovery. If a trial is missing from either arm (Harbor crashed, the run was
interrupted, the replay found nothing to replay), the *pair* is dropped — not
just the trial. ``delta`` is therefore always computed over tasks that produced
a valid result on both sides, and ``paired_n`` is printed next to it so a delta
over three tasks can never be mistaken for a delta over sixty.

Two deltas are reported:

``delta``                 raw, over all paired tasks.
``delta_excluding_harness`` over paired tasks where neither arm suffered a
                          harness fault. If these two disagree, the raw delta is
                          partly measuring OSA's install/boot reliability rather
                          than its recovery ability, and the second number is
                          the honest one to quote for recovery.

A corrupted trial that replayed zero commands is not a corrupted trial. It is
counted in ``invalid_corrupted`` and excluded from everything, because including
it would make OSA look *better* at recovery than it is — the direction of error
a benchmark must never take by default.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
TBENCH = HERE.parent / "terminalbench"
REPORT = HERE.parent / "report"
for _p in (TBENCH, REPORT):
    if str(_p) not in sys.path:
        sys.path.append(str(_p))

import report as tbench_report  # noqa: E402  (bench/terminalbench/report.py)

try:
    # bench/report owns the house rules on when a proportion may be quoted.
    # Imported, never edited.
    from stats import wilson  # noqa: E402
    from honesty import MIN_N_FOR_RATE  # noqa: E402
except ImportError:  # pragma: no cover - bench/report is optional at runtime
    wilson = None
    MIN_N_FOR_RATE = 30


def mcnemar_exact(regressed: int, recovered: int) -> dict:
    """Exact McNemar test on the discordant pairs.

    The two arms are **paired** — the same task, the same model, twice — so
    treating the arm accuracies as independent proportions is the wrong test and
    would overstate the uncertainty. All the information about whether
    corruption changed anything lives in the two discordant cells:

        b = regressed  (solved fresh, failed corrupted)
        c = recovered  (failed fresh, solved corrupted)

    Under the null "corruption has no effect", each discordant pair is a fair
    coin, so p is a two-sided binomial sign test on b out of b+c. `held` and
    `failed_both` contribute nothing and are correctly ignored.
    """
    n = regressed + recovered
    if n == 0:
        return {
            "discordant_pairs": 0,
            "p_value": None,
            "interpretation": (
                "no discordant pairs: every task landed the same way in both "
                "arms, so this run carries no evidence either way"
            ),
        }
    from math import comb

    k = min(regressed, recovered)
    tail = sum(comb(n, i) for i in range(0, k + 1)) / (2**n)
    p = min(1.0, 2 * tail)
    return {
        "discordant_pairs": n,
        "regressed": regressed,
        "recovered": recovered,
        "p_value": round(p, 4),
        "significant_at_05": p < 0.05,
        "interpretation": (
            f"{regressed} regressed vs {recovered} recovered out of {n} "
            f"discordant pairs; two-sided exact p={p:.3f}"
        ),
    }

SCHEMA_VERSION = 1
TERMINAL_BENCH_2_SIZE = tbench_report.TERMINAL_BENCH_2_SIZE

# Recovery-Bench's own universe: the tasks the shared weak agent (terminus-2 /
# claude-haiku-4-5) failed and which yield at least one replayable command.
# A run over fewer is a subset of Recovery-Bench, not a Recovery-Bench score.
CORRUPTED_UNIVERSE_SIZE = 64

# Published figures, for orientation only. These are averages over a model set
# that does not include whatever OSA is driving, so they are a sanity band, not
# a target. Source: Letta, "Introducing Recovery-Bench" (2026).
PUBLISHED = {
    "fresh_mean": 0.263,
    "corrupted_mean": 0.112,
    "relative_drop": 0.57,
    "note": (
        "averaged over the paper's model set; rankings reorder between the two "
        "arms, which is the finding that makes recovery a separate axis"
    ),
}


def _interval(k: int, n: int) -> dict | None:
    """95% Wilson interval on one arm, for orientation only.

    The arms are paired, so these intervals are *not* the test — see
    :func:`mcnemar_exact`. They are here to show how wide the fog is around each
    arm's point estimate, which on a small subset is very wide indeed.
    """
    if wilson is None or n <= 0:
        return None
    try:
        iv = wilson(k, n)
    except Exception:  # noqa: BLE001
        return None
    return {
        "low": round(iv.low, 4),
        "high": round(iv.high, 4),
        "width_pp": round((iv.high - iv.low) * 100, 1),
    }


def _mean(xs):
    xs = [x for x in xs if x is not None]
    return round(sum(xs) / len(xs), 3) if xs else None


def _total(xs):
    xs = [x for x in xs if x is not None]
    return sum(xs) if xs else None


def collect_arm(job_dir: Path, arm: str) -> list[dict]:
    """Read one arm's trials, tagging each with the arm and its replay proof."""
    rows = tbench_report.collect(Path(job_dir))
    for r in rows:
        r["arm"] = arm
        meta = _trial_meta(Path(r["trial_dir"]))
        # The manifest is written during setup and survives a trial that later
        # timed out or crashed; the AgentContext metadata only exists if run()
        # completed. Prefer the durable evidence, fall back to the metadata.
        man = _replay_manifest(Path(r["trial_dir"]))
        r["replay_commands"] = man.get(
            "commands_found", meta.get("recovery_replay_commands")
        )
        r["replay_finished"] = man.get("replay_finished")
        r["replay_seconds"] = man.get("replay_seconds")
        r["message_mode"] = man.get("message_mode", meta.get("recovery_message_mode"))
        r["prior_messages"] = man.get(
            "prior_messages", meta.get("recovery_prior_messages")
        )
        # The corrupted arm has to prove it corrupted something: commands were
        # found AND the replay ran to completion. A replay that started and died
        # halfway leaves an unknown state, which is not a controlled condition.
        r["valid_for_arm"] = (
            True
            if arm == "fresh"
            else bool((r["replay_commands"] or 0) > 0 and man.get("replay_finished"))
        )
    return rows


def _replay_manifest(trial_dir: Path) -> dict:
    for p in (
        trial_dir / "agent" / "recovery-replay.json",
        trial_dir / "recovery-replay.json",
    ):
        if p.exists():
            try:
                return json.loads(p.read_text())
            except (OSError, json.JSONDecodeError):
                return {}
    return {}


def _trial_meta(trial_dir: Path) -> dict:
    try:
        r = json.loads((trial_dir / "result.json").read_text())
    except (OSError, json.JSONDecodeError):
        return {}
    return ((r.get("agent_result") or {}).get("metadata")) or {}


def _arm_aggregate(rows: list[dict]) -> dict:
    valid = [r for r in rows if r.get("valid_for_arm", True)]
    n = len(valid)
    resolved = [r for r in valid if r["resolved"]]
    harness = [r for r in valid if r["fault_owner"] == "harness"]
    model = [r for r in valid if r["fault_owner"] == "model"]
    ambiguous = [r for r in valid if r["fault_owner"] == "ambiguous"]

    taxonomy: dict[str, int] = {}
    for r in valid:
        if r["failure_reason"]:
            taxonomy[r["failure_reason"]] = taxonomy.get(r["failure_reason"], 0) + 1

    inflicted: dict[str, int] = {}
    inflicted_tasks: dict[str, list[str]] = {}
    for r in valid:
        for k, v in (r["self_inflicted"] or {}).items():
            inflicted[k] = inflicted.get(k, 0) + v
            inflicted_tasks.setdefault(k, []).append(r["task_name"])

    return {
        "tasks_attempted": n,
        "tasks_resolved": len(resolved),
        "accuracy": round(len(resolved) / n, 4) if n else None,
        "invalid_trials": len(rows) - n,
        "fault_owner_counts": {
            "resolved": len(resolved),
            "model": len(model),
            "harness": len(harness),
            "ambiguous": len(ambiguous),
        },
        "harness_fault_rate": round(len(harness) / n, 4) if n else None,
        "wall_clock_total_s": _total(r["wall_clock_s"] for r in valid),
        "wall_clock_mean_s": _mean(r["wall_clock_s"] for r in valid),
        "agent_setup_mean_s": _mean(r["agent_setup_s"] for r in valid),
        "tokens_in_total": _total(r["tokens_in"] for r in valid),
        "tokens_out_total": _total(r["tokens_out"] for r in valid),
        "cost_usd_total": (
            round(_total(r["cost_usd"] for r in valid), 4)
            if _total(r["cost_usd"] for r in valid) is not None
            else None
        ),
        "turns_mean": _mean(r["turns"] for r in valid),
        "tool_calls_mean": _mean(r["tool_calls"] for r in valid),
        "failure_taxonomy": dict(sorted(taxonomy.items(), key=lambda kv: -kv[1])),
        "self_inflicted_totals": dict(sorted(inflicted.items(), key=lambda kv: -kv[1])),
        "self_inflicted_tasks": inflicted_tasks,
    }


def _pair(arm_rows: dict[str, list[dict]]) -> list[dict]:
    """One row per task that produced a valid result in BOTH arms."""
    fresh = {
        r["task_name"]: r
        for r in arm_rows.get("fresh", [])
        if r.get("valid_for_arm", True)
    }
    corrupt = {
        r["task_name"]: r
        for r in arm_rows.get("corrupted", [])
        if r.get("valid_for_arm", True)
    }
    pairs = []
    for name in sorted(set(fresh) & set(corrupt)):
        f, c = fresh[name], corrupt[name]
        pairs.append(
            {
                "task_name": name,
                "fresh_reward": f["reward"],
                "corrupted_reward": c["reward"],
                "fresh_resolved": f["resolved"],
                "corrupted_resolved": c["resolved"],
                # The four-way transition table is the interesting object: the
                # `regressed` cell is recovery failure, the `recovered` cell is
                # recovery success, and they are not symmetric.
                "transition": (
                    "held" if f["resolved"] and c["resolved"]
                    else "regressed" if f["resolved"] and not c["resolved"]
                    else "recovered" if not f["resolved"] and c["resolved"]
                    else "failed_both"
                ),
                "fresh_owner": f["fault_owner"],
                "corrupted_owner": c["fault_owner"],
                "fresh_reason": f["failure_reason"],
                "corrupted_reason": c["failure_reason"],
                "replay_commands": c.get("replay_commands"),
                "fresh_turns": f["turns"],
                "corrupted_turns": c["turns"],
                "fresh_tokens_in": f["tokens_in"],
                "corrupted_tokens_in": c["tokens_in"],
                "fresh_self_inflicted": f["self_inflicted"],
                "corrupted_self_inflicted": c["self_inflicted"],
                "either_harness_fault": "harness" in (f["fault_owner"], c["fault_owner"]),
            }
        )
    return pairs


def build_delta(*, config: dict, arm_rows: dict[str, list[dict]]) -> dict[str, Any]:
    arms = {arm: _arm_aggregate(rows) for arm, rows in arm_rows.items()}
    pairs = _pair(arm_rows)

    n = len(pairs)
    f_ok = sum(1 for p in pairs if p["fresh_resolved"])
    c_ok = sum(1 for p in pairs if p["corrupted_resolved"])
    f_acc = round(f_ok / n, 4) if n else None
    c_acc = round(c_ok / n, 4) if n else None

    clean = [p for p in pairs if not p["either_harness_fault"]]
    cn = len(clean)
    cf = sum(1 for p in clean if p["fresh_resolved"])
    cc = sum(1 for p in clean if p["corrupted_resolved"])

    transitions: dict[str, int] = {}
    for p in pairs:
        transitions[p["transition"]] = transitions.get(p["transition"], 0) + 1

    invalid_corrupted = [
        r["task_name"]
        for r in arm_rows.get("corrupted", [])
        if not r.get("valid_for_arm", True)
    ]

    delta = {
        "paired_n": n,
        "fresh_accuracy": f_acc,
        "corrupted_accuracy": c_acc,
        "delta": round(c_acc - f_acc, 4) if (f_acc is not None and c_acc is not None) else None,
        "relative_drop": (
            round((f_acc - c_acc) / f_acc, 4) if f_acc else None
        ),
        "paired_n_excluding_harness": cn,
        "fresh_accuracy_excluding_harness": round(cf / cn, 4) if cn else None,
        "corrupted_accuracy_excluding_harness": round(cc / cn, 4) if cn else None,
        "delta_excluding_harness": round((cc - cf) / cn, 4) if cn else None,
        "transitions": transitions,
        "regressed_tasks": [p["task_name"] for p in pairs if p["transition"] == "regressed"],
        "recovered_tasks": [p["task_name"] for p in pairs if p["transition"] == "recovered"],
        "invalid_corrupted_trials": invalid_corrupted,
        # A delta over a handful of tasks is a pipeline signal. This flag is what
        # stops it being quoted as a Recovery-Bench score.
        "is_full_corrupted_universe": n == CORRUPTED_UNIVERSE_SIZE,
        "corrupted_universe_size": CORRUPTED_UNIVERSE_SIZE,
        "published_reference": PUBLISHED,
        # The paired test. This, not the delta, is what says whether the run
        # found anything at all.
        "mcnemar": mcnemar_exact(
            transitions.get("regressed", 0), transitions.get("recovered", 0)
        ),
        # bench/report refuses to headline a proportion below MIN_N_FOR_RATE.
        # The same rule applies here; a delta between two tiny proportions is
        # even noisier than either one.
        "min_n_for_rate": MIN_N_FOR_RATE,
        "n_below_rate_threshold": n < MIN_N_FOR_RATE,
        "fresh_interval": _interval(f_ok, n),
        "corrupted_interval": _interval(c_ok, n),
    }

    return {
        "schema_version": SCHEMA_VERSION,
        "benchmark": "recovery-bench",
        "config": config,
        "delta": delta,
        "arms": arms,
        "pairs": pairs,
        "tasks": {arm: rows for arm, rows in arm_rows.items()},
    }


def _fmt(v, suffix=""):
    return "n/a" if v is None else f"{v}{suffix}"


def _pc(v):
    return "n/a" if v is None else f"{v * 100:.1f}%"


def _signed_pc(v):
    return "n/a" if v is None else f"{v * 100:+.1f} pp"


def summary_md(results: dict) -> str:
    cfg = results["config"]
    d = results["delta"]
    arms = results["arms"]

    lines = [
        f"# OSA Recovery-Bench run — `{cfg.get('run_id')}`",
        "",
        f"- **Benchmark**: Recovery-Bench over Terminal-Bench 2.0 via Harbor "
        f"`{cfg.get('harbor_version', '?')}`",
        f"- **Corruption source**: `{cfg.get('initial_agent')}` — the shared "
        f"upstream traces, so the corrupted states are identical to everyone "
        f"else's",
        f"- **Model (both arms)**: `{cfg.get('model') or 'from OSA config'}`",
        f"- **Message mode**: `{cfg.get('message_mode')}` "
        f"(`none` = corrupted machine only, no polluted transcript)",
        f"- **OSA commit**: `{cfg.get('osa_commit')}`   "
        f"**release built**: {cfg.get('release_built_at')}",
        f"- **Graded by**: each task's own `tests/test.sh`, on final container state",
        "",
        "## Headline — the delta is the deliverable",
        "",
        f"| arm | solved | accuracy |",
        f"|---|---|---|",
        f"| fresh (pristine container) | {sum(1 for p in results['pairs'] if p['fresh_resolved'])}"
        f" / {d['paired_n']} | {_pc(d['fresh_accuracy'])} |",
        f"| corrupted (weak agent's failure replayed) | "
        f"{sum(1 for p in results['pairs'] if p['corrupted_resolved'])}"
        f" / {d['paired_n']} | {_pc(d['corrupted_accuracy'])} |",
        f"| **delta** | | **{_signed_pc(d['delta'])}** |",
        "",
        f"Relative drop: **{_pc(d['relative_drop'])}**. "
        f"Paired over **n = {d['paired_n']}** tasks present in both arms.",
        "",
    ]

    if not d["is_full_corrupted_universe"]:
        lines += [
            f"> **Subset run.** {d['paired_n']} of "
            f"{d['corrupted_universe_size']} tasks in Recovery-Bench's corrupted "
            "universe. This is a pipeline and regression signal, not a "
            "Recovery-Bench score, and must not be quoted as one.",
            "",
        ]
    if d.get("n_below_rate_threshold"):
        fi, ci = d.get("fresh_interval"), d.get("corrupted_interval")
        lines += [
            f"> **n = {d['paired_n']} is below `bench/report`'s "
            f"`MIN_N_FOR_RATE` = {d['min_n_for_rate']}**, the point below which "
            "that module refuses to present a proportion as a headline. The "
            "percentages above are reported because the *paired* design makes "
            "them more informative than two independent samples would be — but "
            "the individual arm rates are not separable from noise:",
            "",
            (f">   fresh 95% CI {_pc(fi['low'])}–{_pc(fi['high'])} "
             f"({fi['width_pp']} pp wide)" if fi else "> (interval unavailable)"),
            (f">   corrupted 95% CI {_pc(ci['low'])}–{_pc(ci['high'])} "
             f"({ci['width_pp']} pp wide)" if ci else ""),
            "",
            "> The transition table and the McNemar test below are what this "
            "run can actually support.",
            "",
        ]

    mc = d.get("mcnemar") or {}
    lines += [
        "### Is the delta real? (paired test)",
        "",
        "The arms are paired — same task, same model, twice — so the evidence "
        "lives entirely in the tasks that changed verdict. Exact two-sided "
        "McNemar on the discordant pairs:",
        "",
        f"- discordant pairs: **{mc.get('discordant_pairs', 0)}** "
        f"({mc.get('regressed', 0)} regressed, {mc.get('recovered', 0)} recovered)",
        f"- p-value: **{mc.get('p_value') if mc.get('p_value') is not None else 'n/a'}**",
        f"- {mc.get('interpretation', '')}",
        "",
    ]

    pub = d["published_reference"]
    lines += [
        "### Against the published figures",
        "",
        f"The paper reports **{_pc(pub['fresh_mean'])} fresh -> "
        f"{_pc(pub['corrupted_mean'])} corrupted** "
        f"({_pc(pub['relative_drop'])} relative drop), {pub['note']}. "
        "Those are averages over a different model set and a full run; they are "
        "an orientation band, not a target.",
        "",
        "## What moved, per task",
        "",
        "The transition table is the part that carries information. `regressed` "
        "is a task OSA could do from scratch but not from a broken machine — "
        "that cell *is* the recovery failure. `recovered` is the opposite and is "
        "rarer than intuition suggests.",
        "",
        "| transition | count | meaning |",
        "|---|---|---|",
    ]
    meanings = {
        "held": "solved in both arms — corruption did not matter",
        "regressed": "solved fresh, failed corrupted — **recovery failure**",
        "recovered": "failed fresh, solved corrupted — prior work helped",
        "failed_both": "failed in both arms — task is out of reach either way",
    }
    for k in ("held", "regressed", "recovered", "failed_both"):
        lines.append(f"| {k} | {d['transitions'].get(k, 0)} | {meanings[k]} |")

    if d["regressed_tasks"]:
        lines += ["", f"Regressed: {', '.join(f'`{t}`' for t in d['regressed_tasks'])}"]
    if d["recovered_tasks"]:
        lines += ["", f"Recovered: {', '.join(f'`{t}`' for t in d['recovered_tasks'])}"]

    lines += [
        "",
        "## Harness or model?",
        "",
        "OSA failing to boot is not OSA failing to recover. The delta below "
        "excludes any pair where either arm suffered a harness fault; if it "
        "disagrees with the headline, the headline is partly measuring install "
        "reliability.",
        "",
        "| metric | raw | excluding harness faults |",
        "|---|---|---|",
        f"| paired n | {d['paired_n']} | {d['paired_n_excluding_harness']} |",
        f"| fresh | {_pc(d['fresh_accuracy'])} | "
        f"{_pc(d['fresh_accuracy_excluding_harness'])} |",
        f"| corrupted | {_pc(d['corrupted_accuracy'])} | "
        f"{_pc(d['corrupted_accuracy_excluding_harness'])} |",
        f"| **delta** | **{_signed_pc(d['delta'])}** | "
        f"**{_signed_pc(d['delta_excluding_harness'])}** |",
        "",
    ]

    if d["invalid_corrupted_trials"]:
        lines += [
            f"> **{len(d['invalid_corrupted_trials'])} corrupted trial(s) "
            "discarded** for replaying zero commands — a corrupted arm that "
            "corrupted nothing is a second fresh run and would shrink the delta: "
            + ", ".join(f"`{t}`" for t in d["invalid_corrupted_trials"]),
            "",
        ]

    lines += ["## Per-arm detail", "", "| metric | fresh | corrupted |", "|---|---|---|"]
    f, c = arms.get("fresh", {}), arms.get("corrupted", {})

    def row(label, key, fmt=_fmt):
        return f"| {label} | {fmt(f.get(key))} | {fmt(c.get(key))} |"

    lines += [
        row("tasks attempted", "tasks_attempted"),
        row("tasks resolved", "tasks_resolved"),
        f"| accuracy | {_pc(f.get('accuracy'))} | {_pc(c.get('accuracy'))} |",
        f"| harness fault rate | {_pc(f.get('harness_fault_rate'))} | "
        f"{_pc(c.get('harness_fault_rate'))} |",
        row("wall-clock total", "wall_clock_total_s"),
        row("agent setup mean (install + replay)", "agent_setup_mean_s"),
        row("turns mean", "turns_mean"),
        row("tool calls mean", "tool_calls_mean"),
        row("tokens in", "tokens_in_total"),
        row("tokens out", "tokens_out_total"),
        "",
        "## OSA self-inflicted markers, by arm",
        "",
        "Scraped from OSA's own log inside each container. A marker that is "
        "**much more common in the corrupted arm** is the strongest available "
        "evidence that OSA, not the model, is what fails under recovery.",
        "",
        "| marker | fresh | corrupted |",
        "|---|---|---|",
    ]
    keys = sorted(
        set(f.get("self_inflicted_totals", {})) | set(c.get("self_inflicted_totals", {}))
    )
    if keys:
        for k in keys:
            lines.append(
                f"| {k} | {f.get('self_inflicted_totals', {}).get(k, 0)} | "
                f"{c.get('self_inflicted_totals', {}).get(k, 0)} |"
            )
    else:
        lines.append("| _none observed_ | | |")

    lines += [
        "",
        "## Failure taxonomy, by arm",
        "",
        "| reason | fresh | corrupted |",
        "|---|---|---|",
    ]
    tkeys = sorted(set(f.get("failure_taxonomy", {})) | set(c.get("failure_taxonomy", {})))
    if tkeys:
        for k in tkeys:
            lines.append(
                f"| {k} | {f.get('failure_taxonomy', {}).get(k, 0)} | "
                f"{c.get('failure_taxonomy', {}).get(k, 0)} |"
            )
    else:
        lines.append("| _no failures_ | | |")

    lines += [
        "",
        "## Per paired task",
        "",
        "| task | fresh | corrupted | transition | replayed cmds | fresh reason | corrupted reason |",
        "|---|---|---|---|---|---|---|",
    ]
    for p in results["pairs"]:
        lines.append(
            "| `{t}` | {fr} | {cr} | {tr} | {rc} | {frr} | {crr} |".format(
                t=p["task_name"],
                fr=_fmt(p["fresh_reward"]),
                cr=_fmt(p["corrupted_reward"]),
                tr=p["transition"],
                rc=_fmt(p["replay_commands"]),
                frr=p["fresh_reason"] or "-",
                crr=p["corrupted_reason"] or "-",
            )
        )

    lines += [
        "",
        "See `bench/recoverybench/README.md` for what this delta can and cannot claim.",
    ]
    return "\n".join(lines) + "\n"


def write(results: dict, out_dir: Path) -> tuple[Path, Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    rj = out_dir / "results.json"
    sm = out_dir / "summary.md"
    rj.write_text(json.dumps(results, indent=2) + "\n")
    sm.write_text(summary_md(results))
    return rj, sm
