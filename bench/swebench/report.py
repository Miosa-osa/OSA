"""Merge inference metrics with the official grading into one results file.

Two artefacts come out of here:

  results.json  -- machine readable, stable schema, one object per instance
                   plus an aggregate block.
  summary.md    -- the same numbers for humans, with the caveats attached so
                   they travel with the figure.
"""

from __future__ import annotations

import json
import statistics
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1


def _instance_detail(report_dir: Path, run_id: str, model: str, iid: str) -> dict:
    """Read the harness's per-instance report.json, if it wrote one."""
    p = (
        report_dir
        / "logs"
        / "run_evaluation"
        / run_id
        / model.replace("/", "__")
        / iid
        / "report.json"
    )
    if not p.exists():
        return {}
    try:
        return json.loads(p.read_text()).get(iid, {})
    except (json.JSONDecodeError, OSError):
        return {}


def _failure_reason(outcome: str, inference: dict, detail: dict) -> str:
    """One canonical reason string per instance.

    Ordered most-specific-first: an agent that crashed is reported as crashed
    even though its (absent) patch also counts as empty.
    """
    st = inference.get("status")
    if outcome == "resolved":
        return ""
    if st == "timeout":
        return "agent_timeout"
    if st == "runner_error":
        return "harness_error"
    if st == "agent_error":
        return "agent_error"
    if outcome == "empty_patch" or st == "empty_patch":
        return "no_patch_produced"
    if outcome == "eval_error":
        return "patch_apply_or_eval_failed"
    if outcome == "incomplete":
        return "eval_incomplete"

    status = detail.get("tests_status") or {}
    f2p = status.get("FAIL_TO_PASS", {})
    p2p = status.get("PASS_TO_PASS", {})
    if p2p.get("failure"):
        return "regression_pass_to_pass_broke"
    if f2p.get("failure"):
        return "fix_incomplete_fail_to_pass_still_failing"
    return "unresolved_unclassified"


def _mean(xs):
    xs = [x for x in xs if x is not None]
    return round(statistics.mean(xs), 3) if xs else None


def _total(xs):
    xs = [x for x in xs if x is not None]
    return sum(xs) if xs else None


def build(
    *,
    config: dict,
    inference: list[dict],
    outcomes: dict[str, str],
    harness_report: dict,
    report_dir: Path,
    run_id: str,
    model: str,
) -> dict[str, Any]:
    rows = []
    for inf in inference:
        iid = inf["instance_id"]
        outcome = outcomes.get(iid, "incomplete")
        detail = _instance_detail(report_dir, run_id, model, iid)
        status = detail.get("tests_status") or {}
        rows.append(
            {
                "instance_id": iid,
                "resolved": outcome == "resolved",
                "outcome": outcome,
                "failure_reason": _failure_reason(outcome, inf, detail),
                "wall_clock_s": round(inf.get("wall_clock_s") or 0.0, 2),
                "tokens_in": inf.get("tokens_in"),
                "tokens_out": inf.get("tokens_out"),
                "tokens_cache_read": inf.get("tokens_cache_read"),
                "tokens_cache_write": inf.get("tokens_cache_write"),
                "cost_usd": inf.get("cost_usd"),
                "tool_calls": inf.get("tool_calls"),
                "turns": inf.get("turns"),
                "patch_bytes": inf.get("patch_bytes", 0),
                "agent_status": inf.get("status"),
                "agent_error": inf.get("error"),
                "model": inf.get("model"),
                "session_id": inf.get("session_id"),
                "fail_to_pass_failing": (
                    status.get("FAIL_TO_PASS", {}).get("failure") or []
                ),
                "pass_to_pass_failing": (
                    status.get("PASS_TO_PASS", {}).get("failure") or []
                ),
            }
        )

    rows.sort(key=lambda r: r["instance_id"])
    n = len(rows)
    resolved = [r for r in rows if r["resolved"]]

    tok_in = _total(r["tokens_in"] for r in rows)
    tok_out = _total(r["tokens_out"] for r in rows)
    cost = _total(r["cost_usd"] for r in rows)

    taxonomy: dict[str, int] = {}
    for r in rows:
        if r["failure_reason"]:
            taxonomy[r["failure_reason"]] = taxonomy.get(r["failure_reason"], 0) + 1

    aggregate = {
        "instances_attempted": n,
        "instances_resolved": len(resolved),
        # pass@1 on the *attempted subset*. This is NOT a SWE-bench Verified
        # score unless instances_attempted == 500.
        "resolve_rate": round(len(resolved) / n, 4) if n else None,
        "is_full_dataset_run": n == config.get("dataset_size"),
        "wall_clock_total_s": round(sum(r["wall_clock_s"] for r in rows), 2),
        "wall_clock_mean_s": _mean(r["wall_clock_s"] for r in rows),
        "wall_clock_mean_resolved_s": _mean(r["wall_clock_s"] for r in resolved),
        "tokens_in_total": tok_in,
        "tokens_out_total": tok_out,
        "tokens_total": (tok_in + tok_out) if (tok_in is not None and tok_out is not None) else None,
        "tokens_per_resolved": (
            round((tok_in + tok_out) / len(resolved), 1)
            if resolved and tok_in is not None and tok_out is not None
            else None
        ),
        "cost_usd_total": round(cost, 4) if cost is not None else None,
        "cost_usd_per_resolved": (
            round(cost / len(resolved), 4) if resolved and cost is not None else None
        ),
        "tool_calls_total": _total(r["tool_calls"] for r in rows),
        "tool_calls_mean": _mean(r["tool_calls"] for r in rows),
        "turns_mean": _mean(r["turns"] for r in rows),
        "failure_taxonomy": dict(sorted(taxonomy.items(), key=lambda kv: -kv[1])),
    }

    return {
        "schema_version": SCHEMA_VERSION,
        "config": config,
        "aggregate": aggregate,
        "harness_report": {
            k: v for k, v in harness_report.items() if not k.endswith("_ids")
        },
        "instances": rows,
    }


def _fmt(v, suffix=""):
    return "n/a" if v is None else f"{v}{suffix}"


def summary_md(results: dict) -> str:
    cfg = results["config"]
    a = results["aggregate"]
    lines = [
        f"# OSA benchmark run — `{cfg['run_id']}`",
        "",
        f"- **Benchmark**: SWE-bench (`{cfg['dataset_name']}`, split `{cfg['split']}`)",
        f"- **Runner**: `{cfg['runner']}`   **Model**: `{cfg.get('model') or 'n/a'}`",
        f"- **Started**: {cfg.get('started_at')}",
        f"- **Graded by**: official `swebench` harness v{cfg.get('swebench_version', '?')} in Docker",
        "",
        "## Headline",
        "",
        f"**{a['instances_resolved']} / {a['instances_attempted']} resolved "
        f"({(a['resolve_rate'] or 0) * 100:.1f}%)**",
        "",
    ]
    if not a["is_full_dataset_run"]:
        lines += [
            "> This is a **subset** run. It is a pipeline and regression signal, "
            "not a SWE-bench Verified score, and must not be quoted as one. "
            "Subsets of a few dozen instances have a confidence interval wide "
            "enough to swallow most of the leaderboard.",
            "",
        ]
    lines += [
        "## Cost of the result",
        "",
        "| metric | value |",
        "|---|---|",
        f"| wall-clock total | {_fmt(a['wall_clock_total_s'], ' s')} |",
        f"| wall-clock mean / task | {_fmt(a['wall_clock_mean_s'], ' s')} |",
        f"| wall-clock mean / resolved task | {_fmt(a['wall_clock_mean_resolved_s'], ' s')} |",
        f"| tokens in | {_fmt(a['tokens_in_total'])} |",
        f"| tokens out | {_fmt(a['tokens_out_total'])} |",
        f"| tokens / resolved task | {_fmt(a['tokens_per_resolved'])} |",
        f"| cost total | {_fmt(a['cost_usd_total'], ' USD')} |",
        f"| cost / resolved task | {_fmt(a['cost_usd_per_resolved'], ' USD')} |",
        f"| tool calls total | {_fmt(a['tool_calls_total'])} |",
        f"| tool calls mean / task | {_fmt(a['tool_calls_mean'])} |",
        f"| turns mean / task | {_fmt(a['turns_mean'])} |",
        "",
        "## Failure taxonomy",
        "",
    ]
    if a["failure_taxonomy"]:
        lines += ["| reason | count |", "|---|---|"]
        lines += [f"| {k} | {v} |" for k, v in a["failure_taxonomy"].items()]
    else:
        lines.append("_No failures._")
    lines += [
        "",
        "## Per instance",
        "",
        "| instance | resolved | reason | wall s | tok in | tok out | tools | cost |",
        "|---|---|---|---|---|---|---|---|",
    ]
    for r in results["instances"]:
        lines.append(
            "| `{iid}` | {ok} | {reason} | {w} | {ti} | {to} | {tc} | {c} |".format(
                iid=r["instance_id"],
                ok="yes" if r["resolved"] else "no",
                reason=r["failure_reason"] or "-",
                w=r["wall_clock_s"],
                ti=_fmt(r["tokens_in"]),
                to=_fmt(r["tokens_out"]),
                tc=_fmt(r["tool_calls"]),
                c=_fmt(r["cost_usd"]),
            )
        )
    lines += ["", "See `bench/README.md` for what these numbers can and cannot claim."]
    return "\n".join(lines) + "\n"


def write(results: dict, out_dir: Path) -> tuple[Path, Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    rj = out_dir / "results.json"
    sm = out_dir / "summary.md"
    rj.write_text(json.dumps(results, indent=2, sort_keys=False) + "\n")
    sm.write_text(summary_md(results))
    return rj, sm
