"""Turn a Harbor job directory into a results file with the caveats attached.

Two artefacts, deliberately the same shape as ``bench/swebench/report.py``:

  results.json  -- machine readable, stable schema, one object per task plus an
                   aggregate block.
  summary.md    -- the same numbers for humans, with the honesty flags inline so
                   they travel with the figure.

The one thing this adds over the SWE-bench reporter is the **fault attribution**
split. Terminal-Bench is being run here as a diagnostic instrument, so a failure
that is OSA's own doing (install broke, boot failed, the stream ended without a
terminal frame, a turn was cut short) must never be pooled with a failure where
the model simply got the task wrong. Those are different bugs with different
owners, and pooling them is how a harness ends up measuring nothing.
"""

from __future__ import annotations

import json
import statistics
import sys
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1

# Terminal-Bench 2.0 is 89 tasks. A run over fewer is a pipeline signal, not a
# score, and `is_full_dataset_run` is what stops it being quoted as one.
TERMINAL_BENCH_2_SIZE = 89

# Failure reasons whose owner is OSA/the harness rather than the model. Anything
# in this set means the episode never got a fair chance, so it is excluded from
# the "model" denominator as well as being reported on its own.
HARNESS_FAULTS = {
    "agent_install_failed",
    "agent_boot_failed",
    "orchestrate_rejected",
    "stream_closed_without_done",
    "harness_exception",
    "no_telemetry_written",
}


def _mean(xs):
    xs = [x for x in xs if x is not None]
    return round(statistics.mean(xs), 3) if xs else None


def _total(xs):
    xs = [x for x in xs if x is not None]
    return sum(xs) if xs else None


def _seconds(a: str | None, b: str | None) -> float | None:
    if not a or not b:
        return None
    from datetime import datetime

    try:
        return round(
            (datetime.fromisoformat(b) - datetime.fromisoformat(a)).total_seconds(), 2
        )
    except ValueError:
        return None


def _failure_reason(reward: float | None, exc: dict | None, meta: dict) -> str:
    """One canonical reason per task, most-specific-first.

    Ordering matters: a trial that blew up in Harbor is reported as a harness
    exception even though its (absent) reward also reads as a plain failure.
    """
    if reward is not None and reward >= 1.0:
        return ""

    status = meta.get("osa_status")
    if exc:
        name = exc.get("exception_type") or exc.get("type") or "Exception"
        # A non-zero exit from the driver with a boot failure underneath is an
        # install problem, not a generic harness blowup.
        if status in ("install_or_boot_failed",):
            return "agent_boot_failed"
        return f"harness_exception:{name}"
    if status is None:
        return "no_telemetry_written"
    if status == "install_or_boot_failed":
        return "agent_boot_failed"
    if status == "orchestrate_rejected":
        return "orchestrate_rejected"
    if status == "stream_closed_without_done":
        return "stream_closed_without_done"
    if status == "timeout":
        return "agent_timeout"
    if status == "ok":
        if not meta.get("osa_tool_calls"):
            # Ran to completion having never touched the machine. Terminal-Bench
            # grades container state, so this is an answer-shaped non-attempt.
            return "completed_without_acting"
        return "completed_but_wrong"
    return f"unclassified:{status}"


def _fault_owner(reason: str) -> str:
    if not reason:
        return "resolved"
    base = reason.split(":", 1)[0]
    if base in HARNESS_FAULTS or reason.startswith("harness_exception"):
        return "harness"
    if reason == "agent_timeout":
        # Ambiguous by construction: a real ceiling and a slow model look the
        # same from outside. Kept in its own bucket rather than guessed at.
        return "ambiguous"
    return "model"


def _rescan_serve_log(trial_dir: Path) -> tuple[dict, dict] | None:
    """Re-derive the self-inflicted markers from OSA's log on disk.

    The driver classifies inside the container, but the pattern table is the
    part of this harness most likely to be wrong on the first try -- the first
    version counted a boot banner as a context-window overflow on every task,
    and a second counted a safety refusal as a VM crash. Re-scanning here means
    an improved table can be applied to runs that already happened, instead of
    the run being permanently stamped with a bad taxonomy.
    """
    log_path = trial_dir / "agent" / "osa-serve.log"
    if not log_path.exists():
        return None
    try:
        sys.path.insert(0, str(Path(__file__).resolve().parent / "driver"))
        import osa_headless  # noqa: PLC0415
    except Exception:  # noqa: BLE001
        return None
    counts: dict[str, int] = {}
    samples: dict[str, str] = {}
    try:
        text = log_path.read_text("utf-8", "replace")
    except OSError:
        return None
    for line in text.splitlines():
        if osa_headless.BENIGN.search(line):
            continue
        for key, rx in osa_headless.SELF_INFLICTED:
            if rx.search(line):
                counts[key] = counts.get(key, 0) + 1
                samples.setdefault(key, line.strip()[:400])
    return counts, samples


def collect(job_dir: Path) -> list[dict]:
    """Read every trial under a Harbor job directory."""
    rows = []
    for result_path in sorted(job_dir.glob("*/result.json")):
        try:
            r = json.loads(result_path.read_text())
        except (json.JSONDecodeError, OSError):
            continue
        trial_dir = result_path.parent
        rewards = (r.get("verifier_result") or {}).get("rewards") or {}
        reward = rewards.get("reward")
        agent_result = r.get("agent_result") or {}
        meta = agent_result.get("metadata") or {}
        exc = r.get("exception_info")

        reason = _failure_reason(reward, exc, meta)
        telemetry_path = trial_dir / "agent" / "osa-telemetry.json"

        rescan = _rescan_serve_log(trial_dir)
        inflicted = rescan[0] if rescan else (meta.get("osa_self_inflicted") or {})
        inflicted_samples = (
            rescan[1] if rescan else (meta.get("osa_self_inflicted_samples") or {})
        )

        rows.append(
            {
                "task_name": r.get("task_name"),
                "trial_name": r.get("trial_name"),
                "reward": reward,
                "resolved": bool(reward is not None and reward >= 1.0),
                "failure_reason": reason,
                "fault_owner": _fault_owner(reason),
                "wall_clock_s": _seconds(r.get("started_at"), r.get("finished_at")),
                "agent_setup_s": _seconds(
                    (r.get("agent_setup") or {}).get("started_at"),
                    (r.get("agent_setup") or {}).get("finished_at"),
                ),
                "agent_exec_s": _seconds(
                    (r.get("agent_execution") or {}).get("started_at"),
                    (r.get("agent_execution") or {}).get("finished_at"),
                ),
                "tokens_in": agent_result.get("n_input_tokens"),
                "tokens_out": agent_result.get("n_output_tokens"),
                "tokens_cache": agent_result.get("n_cache_tokens"),
                "cost_usd": agent_result.get("cost_usd"),
                "turns": meta.get("osa_turns"),
                "tool_calls": meta.get("osa_tool_calls"),
                "osa_status": meta.get("osa_status"),
                "osa_error": meta.get("osa_error"),
                "osa_boot_s": meta.get("osa_boot_s"),
                "osa_saw_done": meta.get("osa_saw_done"),
                "osa_last_event_type": meta.get("osa_last_event_type"),
                "self_inflicted": inflicted,
                "self_inflicted_samples": inflicted_samples,
                "exception": (exc or {}).get("exception_type") if exc else None,
                "exception_message": (exc or {}).get("exception_message") if exc else None,
                "telemetry_path": str(telemetry_path) if telemetry_path.exists() else None,
                "trial_dir": str(trial_dir),
            }
        )
    rows.sort(key=lambda r: r["task_name"] or "")
    return rows


def build(*, config: dict, rows: list[dict]) -> dict[str, Any]:
    n = len(rows)
    resolved = [r for r in rows if r["resolved"]]
    harness_faults = [r for r in rows if r["fault_owner"] == "harness"]
    model_faults = [r for r in rows if r["fault_owner"] == "model"]
    ambiguous = [r for r in rows if r["fault_owner"] == "ambiguous"]

    taxonomy: dict[str, int] = {}
    for r in rows:
        if r["failure_reason"]:
            taxonomy[r["failure_reason"]] = taxonomy.get(r["failure_reason"], 0) + 1

    # Every self-inflicted marker seen anywhere in the run, summed. A marker
    # that shows up on many tasks is a bug report waiting to be written.
    inflicted: dict[str, int] = {}
    inflicted_tasks: dict[str, list[str]] = {}
    for r in rows:
        for k, v in (r["self_inflicted"] or {}).items():
            inflicted[k] = inflicted.get(k, 0) + v
            inflicted_tasks.setdefault(k, []).append(r["task_name"])

    tok_in = _total(r["tokens_in"] for r in rows)
    tok_out = _total(r["tokens_out"] for r in rows)
    cost = _total(r["cost_usd"] for r in rows)
    n_scoreable = n - len(harness_faults)

    aggregate = {
        "tasks_attempted": n,
        "tasks_resolved": len(resolved),
        # Accuracy over everything attempted -- the number Terminal-Bench would
        # report. NOT a Terminal-Bench 2.0 score unless is_full_dataset_run.
        "accuracy": round(len(resolved) / n, 4) if n else None,
        # Accuracy with harness faults removed from the denominator. Higher by
        # construction; only meaningful next to harness_fault_rate.
        "accuracy_excluding_harness_faults": (
            round(len(resolved) / n_scoreable, 4) if n_scoreable else None
        ),
        "is_full_dataset_run": n == TERMINAL_BENCH_2_SIZE
        and config.get("dataset_size") == TERMINAL_BENCH_2_SIZE,
        "dataset_size": config.get("dataset_size"),
        "fault_owner_counts": {
            "resolved": len(resolved),
            "model": len(model_faults),
            "harness": len(harness_faults),
            "ambiguous": len(ambiguous),
        },
        "harness_fault_rate": round(len(harness_faults) / n, 4) if n else None,
        "wall_clock_total_s": _total(r["wall_clock_s"] for r in rows),
        "wall_clock_mean_s": _mean(r["wall_clock_s"] for r in rows),
        "agent_setup_mean_s": _mean(r["agent_setup_s"] for r in rows),
        "agent_exec_mean_s": _mean(r["agent_exec_s"] for r in rows),
        "osa_boot_mean_s": _mean(r["osa_boot_s"] for r in rows),
        "tokens_in_total": tok_in,
        "tokens_out_total": tok_out,
        "tokens_per_resolved": (
            round((tok_in + tok_out) / len(resolved), 1)
            if resolved and tok_in is not None and tok_out is not None
            else None
        ),
        "cost_usd_total": round(cost, 4) if cost is not None else None,
        "turns_mean": _mean(r["turns"] for r in rows),
        "tool_calls_mean": _mean(r["tool_calls"] for r in rows),
        "failure_taxonomy": dict(sorted(taxonomy.items(), key=lambda kv: -kv[1])),
        "self_inflicted_totals": dict(sorted(inflicted.items(), key=lambda kv: -kv[1])),
        "self_inflicted_tasks": inflicted_tasks,
    }

    return {
        "schema_version": SCHEMA_VERSION,
        "benchmark": "terminal-bench-2.0",
        "config": config,
        "aggregate": aggregate,
        "tasks": rows,
    }


def _fmt(v, suffix=""):
    return "n/a" if v is None else f"{v}{suffix}"


def summary_md(results: dict) -> str:
    cfg = results["config"]
    a = results["aggregate"]
    lines = [
        f"# OSA Terminal-Bench run — `{cfg['run_id']}`",
        "",
        f"- **Benchmark**: Terminal-Bench 2.0 via Harbor `{cfg.get('harbor_version', '?')}`",
        f"- **Dataset**: `{cfg.get('dataset')}`  ({_fmt(a['dataset_size'])} tasks available)",
        f"- **Agent**: `{cfg.get('agent')}`   **Model**: `{cfg.get('model') or 'from OSA config'}`",
        f"- **Started**: {cfg.get('started_at')}",
        f"- **Graded by**: the task's own `tests/test.sh` inside the task container "
        f"(final container state, not a patch)",
        "",
        "## Headline",
        "",
        f"**{a['tasks_resolved']} / {a['tasks_attempted']} solved "
        f"({(a['accuracy'] or 0) * 100:.1f}%)**",
        "",
    ]
    if not a["is_full_dataset_run"]:
        lines += [
            "> This is a **subset** run over "
            f"{a['tasks_attempted']} of {TERMINAL_BENCH_2_SIZE} tasks. It is a "
            "pipeline and regression signal, not a Terminal-Bench 2.0 score, and "
            "must not be quoted as one.",
            "",
        ]
    fo = a["fault_owner_counts"]
    lines += [
        "## Who failed",
        "",
        "The point of running this is to separate OSA's own defects from the "
        "model getting the task wrong. Only the `model` row is about capability.",
        "",
        "| owner | count | meaning |",
        "|---|---|---|",
        f"| resolved | {fo['resolved']} | task passed its verifier |",
        f"| model | {fo['model']} | OSA worked; the answer was wrong or absent |",
        f"| harness | {fo['harness']} | OSA/adapter broke — these never had a fair chance |",
        f"| ambiguous | {fo['ambiguous']} | timeouts: a real ceiling and a slow model look identical |",
        "",
        f"**Harness fault rate: {(a['harness_fault_rate'] or 0) * 100:.1f}%.** "
        "Any value above zero means the score below is understated by that much.",
        "",
        f"Accuracy excluding harness faults: "
        f"{(a['accuracy_excluding_harness_faults'] or 0) * 100:.1f}%",
        "",
        "## OSA self-inflicted markers",
        "",
        "Counted from OSA's own log inside each container. A marker is a "
        "**signal, not a verdict** — but one appearing across many tasks is a "
        "bug report.",
        "",
    ]
    if a["self_inflicted_totals"]:
        lines += ["| marker | occurrences | tasks |", "|---|---|---|"]
        for k, v in a["self_inflicted_totals"].items():
            tasks = a["self_inflicted_tasks"].get(k, [])
            lines.append(f"| {k} | {v} | {len(set(tasks))} |")
    else:
        lines.append("_None observed._")

    lines += [
        "",
        "## Cost of the result",
        "",
        "| metric | value |",
        "|---|---|",
        f"| wall-clock total | {_fmt(a['wall_clock_total_s'], ' s')} |",
        f"| wall-clock mean / task | {_fmt(a['wall_clock_mean_s'], ' s')} |",
        f"| agent setup mean (install OSA) | {_fmt(a['agent_setup_mean_s'], ' s')} |",
        f"| agent exec mean | {_fmt(a['agent_exec_mean_s'], ' s')} |",
        f"| OSA boot mean (in container) | {_fmt(a['osa_boot_mean_s'], ' s')} |",
        f"| tokens in | {_fmt(a['tokens_in_total'])} |",
        f"| tokens out | {_fmt(a['tokens_out_total'])} |",
        f"| tokens / solved task | {_fmt(a['tokens_per_resolved'])} |",
        f"| cost total | {_fmt(a['cost_usd_total'], ' USD')} |",
        f"| turns mean / task | {_fmt(a['turns_mean'])} |",
        f"| tool calls mean / task | {_fmt(a['tool_calls_mean'])} |",
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
        "## Per task",
        "",
        "| task | reward | owner | reason | wall s | turns | tools | tok in | tok out |",
        "|---|---|---|---|---|---|---|---|---|",
    ]
    for r in results["tasks"]:
        lines.append(
            "| `{t}` | {rw} | {ow} | {rs} | {w} | {tu} | {tc} | {ti} | {to} |".format(
                t=r["task_name"],
                rw=_fmt(r["reward"]),
                ow=r["fault_owner"],
                rs=r["failure_reason"] or "-",
                w=_fmt(r["wall_clock_s"]),
                tu=_fmt(r["turns"]),
                tc=_fmt(r["tool_calls"]),
                ti=_fmt(r["tokens_in"]),
                to=_fmt(r["tokens_out"]),
            )
        )
    lines += ["", "See `bench/terminalbench/README.md` for what these numbers can and cannot claim."]
    return "\n".join(lines) + "\n"


def write(results: dict, out_dir: Path) -> tuple[Path, Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    rj = out_dir / "results.json"
    sm = out_dir / "summary.md"
    rj.write_text(json.dumps(results, indent=2) + "\n")
    sm.write_text(summary_md(results))
    return rj, sm
