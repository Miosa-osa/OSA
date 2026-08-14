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
import re
import statistics
import sys
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1

# Terminal-Bench 2.0 and 2.1 are both 89 tasks. Kept as a constant only for
# callers that predate `datasets.py`; the size that actually governs
# `is_full_dataset_run` now comes from the run config, because the runner can
# point at datasets of 74, 80, 89 or 200 tasks and a fixed 89 would have
# declared an 80-task Harbor-Index run "not full" and a 74-task
# Terminal-Bench-3 run "not full" forever.
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
    # A turn that ended on an OSA-internal fault (encoding, :request_shape,
    # :tool_use_mismatch, :duplicate_tool_use). These were emitted as
    # `kind: :llm_error`, became `provider_error` in the driver, and -- because
    # `provider_error` is not in this set -- were counted against the MODEL.
    # Every harness-vs-model split published before the `owner` field existed
    # was computed with OSA's own faults credited to the model.
    "osa_internal_error",
    # A task the model failed while OSA was refusing tool calls on paths inside
    # the session's OWN workspace. `Permissions.denial_fault_owner/3` stamps
    # `fault_owner: :osa` on exactly those (and deliberately on nothing else --
    # a refused `/etc/shadow` is the boundary working), and the stamp rides out
    # on both the `tool_call` phase-`end` and the `tool_result` frames.
    #
    # It was stamped and then not read. The whole reason the stamp exists is
    # that a denial is a tool RESULT, not a turn error, so it never reached
    # `_failure_reason` -- the run in which 142 denials drove one task to shuttle
    # files with `cp` and another to instruct a headless benchmark to type
    # `/add-dir /app` reported a harness fault rate of 0.0%. Reading the stamp
    # here is what closes that loop.
    "osa_workspace_denied",
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


def _failure_reason(
    reward: float | None, exc: dict | None, meta: dict, events: dict | None = None
) -> str:
    """One canonical reason per task, most-specific-first.

    Ordering matters: a trial that blew up in Harbor is reported as a harness
    exception even though its (absent) reward also reads as a plain failure.

    `events` carries the per-episode counters from `_scan_events`. It only ever
    RE-LABELS a task that already failed: a passing task is `resolved` no matter
    how much OSA got in its own way, because the verifier is the authority on
    whether the work got done. The obstruction on a passing task is still
    reported -- as `osa_tool_faults` in its row and in the aggregate -- rather
    than being allowed to move a green result into the harness bucket.
    """
    if reward is not None and reward >= 1.0:
        return ""

    status = meta.get("osa_status")
    # `runner_error` is the driver's INITIAL sentinel, and for a window of runs
    # its clean-exit branch could not overwrite it: the guard listed only
    # (None, "", "running"), none of which the driver ever sets. Every clean
    # exit therefore kept the sentinel and landed here as
    # `unclassified:runner_error`. A driver that genuinely died never recorded a
    # `done` frame, so the two are distinguishable on disk — re-derive, the same
    # way `provider_error` is re-derived from its owner below, rather than
    # leaving an archived run mis-bucketed forever.
    if status == "runner_error" and meta.get("osa_saw_done") and not exc:
        status = "ok"
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
    if status in ("osa_internal_error", "turn_error_unattributed"):
        return status
    # Runs recorded before the driver read `turn_error["owner"]` stamped every
    # turn-ending error as `provider_error`, whoever owned it. Re-derive from
    # the owner the telemetry carries, so an old run can be re-scored from disk
    # rather than being stamped forever with the wrong attribution.
    if status == "provider_error":
        owner = meta.get("osa_turn_error_owner")
        if owner == "osa":
            return "osa_internal_error"
        if owner != "provider":
            return "turn_error_unattributed"
        return "provider_error"
    if status == "ok":
        # A run that OSA obstructed is not a measurement of the model. This is
        # checked BEFORE `completed_but_wrong`, because `completed_but_wrong` is
        # a verdict on the model's competence and it is not one we are entitled
        # to reach on an episode where our own path policy refused calls inside
        # the workspace.
        if (events or {}).get("osa_tool_faults"):
            return "osa_workspace_denied"
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
    if reason in ("agent_timeout", "provider_error", "turn_error_unattributed"):
        # Ambiguous by construction, for three different reasons:
        #   agent_timeout            a real ceiling and a slow model look the
        #                            same from outside;
        #   provider_error           upstream refused/failed -- not OSA's code,
        #                            but not the model's competence either;
        #   turn_error_unattributed  the turn died on an error carrying no
        #                            `owner`. Unknown is not "the model's
        #                            fault"; it is unknown, and it says so.
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


#: Result text of a tool call that OSA refused on path grounds. Kept broader
#: than `Permissions`' own marker list on purpose: this counter is the *total*
#: denial pressure on the episode, including the legitimate refusals, and it is
#: reported next to -- never merged into -- the `fault_owner` split, which is
#: the narrow OSA-at-fault subset.
_DENIAL_RX = re.compile(
    r"Permission denied|Access denied|outside allowed|not an allowed path"
    r"|is not permitted|blocked by permission",
    re.I,
)

#: The workaround signature. A headless benchmark episode cannot type a slash
#: command, so an agent emitting `/add-dir` has concluded its own workspace is
#: unreachable and is asking a human that is not there to fix it. Every
#: occurrence is a self-report that the container fix did not land.
_ADD_DIR_RX = re.compile(r"/add-dir\b")

#: Tools whose call is a WRITE to the filesystem. Counted because the `cp`
#: shuttle the denial bug forced (write to an allowed dir, then shell-copy it
#: into place) inflates this number, so it falls when the bug is really gone.
_WRITE_TOOLS = {
    "file_write", "file_edit", "multi_file_edit", "file_transform",
    "notebook_edit", "task_write",
}


def _scan_events(trial_dir: Path) -> dict:
    """Per-episode counters that only the raw SSE log can answer.

    Four things the trial-level `result.json` cannot tell you and the aggregate
    was published without:

      * `osa_tool_faults`   -- tool calls OSA itself refused on a path inside
        the session workspace, read from the `fault_owner` stamp on the
        `tool_call` (phase `end`) and `tool_result` frames. De-duplicated by
        `tool_call_id`, because the two frames describe ONE call and counting
        both would double every fault.
      * `denials`           -- every path refusal the model saw, at fault or not.
      * `add_dir_mentions`  -- the give-up signature.
      * `write_ops` / `peak_context_tokens` -- the shape of the workaround.
    """
    path = trial_dir / "agent" / "osa-events.jsonl"
    out = {
        "osa_tool_faults": None,
        "osa_tool_fault_tools": {},
        "denials": None,
        "denial_samples": [],
        "add_dir_mentions": None,
        "write_ops": None,
        "peak_context_tokens": None,
        "context_window": None,
    }
    if not path.exists():
        return out

    fault_ids: set[str] = set()
    fault_tools: dict[str, int] = {}
    denials = 0
    denial_samples: list[str] = []
    add_dir = 0
    writes = 0
    peak = 0
    window = None
    try:
        with path.open("r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if _ADD_DIR_RX.search(line):
                    add_dir += 1
                try:
                    ev = json.loads(line)
                except json.JSONDecodeError:
                    continue
                etype = ev.get("type") or ev.get("_event")

                # The stamp rides on both frames of the same call. Key on the
                # id so one refusal counts once.
                if etype in ("tool_call", "tool_result"):
                    owner = ev.get("fault_owner")
                    if isinstance(owner, str) and owner.lstrip(":") == "osa":
                        cid = ev.get("tool_call_id") or f"{etype}:{len(fault_ids)}"
                        if cid not in fault_ids:
                            fault_ids.add(cid)
                            name = ev.get("name") or "?"
                            fault_tools[name] = fault_tools.get(name, 0) + 1

                if etype == "tool_result":
                    text = str(ev.get("result") or "")
                    if _DENIAL_RX.search(text):
                        denials += 1
                        if len(denial_samples) < 5:
                            denial_samples.append(
                                f"{ev.get('name')}: {text.strip()[:220]}"
                            )
                elif etype == "tool_call":
                    if ev.get("phase") in ("start", None) and ev.get("name") in _WRITE_TOOLS:
                        writes += 1
                elif etype == "context_pressure":
                    est = ev.get("estimated_tokens")
                    if isinstance(est, (int, float)):
                        peak = max(peak, int(est))
                    mx = ev.get("max_tokens")
                    if isinstance(mx, (int, float)):
                        window = int(mx)
    except OSError:
        return out

    out.update(
        osa_tool_faults=len(fault_ids),
        osa_tool_fault_tools=dict(sorted(fault_tools.items(), key=lambda kv: -kv[1])),
        denials=denials,
        denial_samples=denial_samples,
        add_dir_mentions=add_dir,
        write_ops=writes,
        peak_context_tokens=peak or None,
        context_window=window,
    )
    return out


def _max_num(*vals):
    """Largest readable number among cumulative readings of one counter."""
    nums = [v for v in vals if isinstance(v, (int, float)) and not isinstance(v, bool)]
    return max(nums) if nums else None


def _last_frame_spend(trial_dir: Path) -> dict:
    """Spend re-derived from the raw `cost_update` frames.

    Returns the LAST frame (whose `tree_cost_usd` / `session_cost_usd` are
    session-to-date cumulative) with three extra keys holding the SUM of the
    per-turn `usage` blocks: `_sum_input_tokens`, `_sum_output_tokens`,
    `_sum_cache_read` / `_sum_cache_creation`.

    Two different shapes in one frame, and mixing them up would be a 100x error
    either way: `tree_cost_usd` is cumulative, `usage` is that round-trip alone.
    Summing `usage` across frames is exactly how the driver builds the
    `osa_usage_sum` it writes into telemetry -- verified on 15 trials across two
    runs, where the sum reproduces the telemetry figure to the token.

    ## Why sum here when the driver already did

    Because the driver only writes telemetry if it survives to write it. A trial
    Harbor kills on `AgentTimeoutError` leaves `agent_result` entirely null, and
    the task then contributed ZERO tokens to a total whose denominator still
    counted it. Measured: `path-tracing` timed out at 1800s having actually
    burned 17.46M input tokens and $10.70 -- the single most expensive task in
    the probe set -- and its absence pulled the published `input_tokens/task`
    down by ~20% while the task still scored a pass. An unmeasured expensive
    task that silently reads as free is the exact failure mode this reporter
    exists to prevent, so the raw log is summed here as a fallback of record.

    The values join `_reconcile_spend`'s `max` reconciliation rather than
    overriding anything: on a trial that did write telemetry the two agree
    exactly, so this is a no-op there and a recovery only where it is needed.
    """
    path = trial_dir / "agent" / "osa-events.jsonl"
    if not path.exists():
        return {}
    last: dict = {}
    sums = {"input_tokens": 0, "output_tokens": 0,
            "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0}
    seen = False
    try:
        with path.open("r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if '"cost_update"' not in line:
                    continue
                try:
                    ev = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if (ev.get("type") or ev.get("_event")) != "cost_update":
                    continue
                last = ev
                usage = ev.get("usage") or {}
                if isinstance(usage, dict):
                    for key in sums:
                        v = usage.get(key)
                        if isinstance(v, (int, float)) and not isinstance(v, bool):
                            sums[key] += v
                            seen = True
    except OSError:
        return {}
    if seen:
        last = dict(last)
        last["_sum_input_tokens"] = sums["input_tokens"]
        last["_sum_output_tokens"] = sums["output_tokens"]
        last["_sum_cache_read"] = sums["cache_read_input_tokens"]
        last["_sum_cache_creation"] = sums["cache_creation_input_tokens"]
    return last


def _reconcile_spend(trial_dir: Path, agent_result: dict, meta: dict) -> dict:
    """Re-derive tokens and cost from every record the trial retained.

    Motivation is the same as `_rescan_serve_log`: an archived run should be
    re-scorable with a corrected reader rather than being stamped forever with
    whatever the reader believed on the day.

    What was wrong: the agent adapter preferred OSA's spend sidecar over the
    summed SSE frames whenever the sidecar had the key. The sidecar is written
    by the agent process and, on a turn whose final LLM round-trip makes no tool
    call, could be one round-trip stale — so the published input-token and $
    figures came out LOW (measured: 30k-110k input tokens per task, ~1.1% of the
    probe total). Every one of these counters is a monotonic session total, so
    the largest readable value is the freshest and `max` is the reconciliation
    that carries no bias in either direction.
    """
    spend = meta.get("osa_spend_sidecar") or {}
    summed = meta.get("osa_usage_sum") or {}
    frame = _last_frame_spend(trial_dir)

    cache_r = _max_num(
        spend.get("cache_read_tokens"),
        summed.get("cache_read_input_tokens"),
        frame.get("_sum_cache_read"),
    )
    cache_w = _max_num(
        spend.get("cache_creation_tokens"),
        summed.get("cache_creation_input_tokens"),
        frame.get("_sum_cache_creation"),
    )
    cache_total = (cache_r or 0) + (cache_w or 0)

    return {
        "tokens_in": _max_num(
            agent_result.get("n_input_tokens"),
            spend.get("input_tokens"),
            summed.get("input_tokens"),
            # Last resort, and the ONLY source on a trial Harbor killed before
            # telemetry was written. Identical to the two above whenever they
            # exist; the difference is that it exists when they do not.
            frame.get("_sum_input_tokens"),
        ),
        "tokens_out": _max_num(
            agent_result.get("n_output_tokens"),
            spend.get("output_tokens"),
            summed.get("output_tokens"),
            frame.get("_sum_output_tokens"),
        ),
        # Keep `None` rather than 0 when no source reported a cache counter at
        # all — "not measured" and "measured as zero" are different claims.
        "tokens_cache": cache_total
        if (cache_r is not None or cache_w is not None) and cache_total
        else agent_result.get("n_cache_tokens"),
        # READ and WRITE kept apart, because they are different events and only
        # one of them is a hit. A read is a prefix that was already resident; a
        # write is a miss that got stored, billed at 1.25x input rather than
        # 0.1x. Collapsing them into one "cache tokens" figure — which is all
        # this reader used to keep — makes the hit rate unrecoverable and hides
        # a run that re-wrote its prefix every turn behind a run that reused it.
        "tokens_cache_read": cache_r,
        "tokens_cache_write": cache_w,
        "cost_usd": _max_num(
            agent_result.get("cost_usd"),
            spend.get("tree_cost_usd"),
            spend.get("cost_usd"),
            frame.get("tree_cost_usd"),
            frame.get("session_cost_usd"),
        ),
    }


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

        events = _scan_events(trial_dir)
        reason = _failure_reason(reward, exc, meta, events)
        telemetry_path = trial_dir / "agent" / "osa-telemetry.json"

        spend_fix = _reconcile_spend(trial_dir, agent_result, meta)
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
                **spend_fix,
                "turns": meta.get("osa_turns"),
                "tool_calls": meta.get("osa_tool_calls"),
                "osa_status": meta.get("osa_status"),
                "osa_error": meta.get("osa_error"),
                "osa_boot_s": meta.get("osa_boot_s"),
                "osa_saw_done": meta.get("osa_saw_done"),
                "osa_last_event_type": meta.get("osa_last_event_type"),
                "self_inflicted": inflicted,
                "self_inflicted_samples": inflicted_samples,
                **events,
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
    tok_cache = _total(r["tokens_cache"] for r in rows)
    tok_cache_r = _total(r.get("tokens_cache_read") for r in rows)
    tok_cache_w = _total(r.get("tokens_cache_write") for r in rows)
    #: Everything sent in, at any billing rate. The denominator for both the
    #: hit rate and input-tokens/task; see those keys for why.
    prompt_tok = (tok_in or 0) + (tok_cache_r or 0) + (tok_cache_w or 0) or None
    cost = _total(r["cost_usd"] for r in rows)
    n_scoreable = n - len(harness_faults)
    declared_size = config.get("dataset_size") or 0

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
        # Full means "every task the selected dataset has", whatever that
        # dataset is. Compared against the size the runner recorded, which it
        # counted from disk.
        "is_full_dataset_run": bool(declared_size) and n == declared_size,
        "dataset_size": config.get("dataset_size"),
        "dataset_key": config.get("dataset_key"),
        "dataset_label": config.get("dataset_label"),
        "dataset_status": config.get("dataset_status"),
        "fault_owner_counts": {
            "resolved": len(resolved),
            "model": len(model_faults),
            "harness": len(harness_faults),
            "ambiguous": len(ambiguous),
        },
        "harness_fault_rate": round(len(harness_faults) / n, 4) if n else None,
        # --- workspace-denial instrumentation ---------------------------
        # `Agent.Safety.PathPolicy` never consulted the session's working
        # directory, so in a container with HOME=/root and a workspace of /app
        # every file_write/file_read/dir_list on the workspace was denied. The
        # agent routed around it with `cp` shuttles; one episode gave up and
        # told a headless benchmark to run `/add-dir /app`. These four counters
        # are the direct measure of whether that is gone, and they are reported
        # whether or not the task passed -- a task can be obstructed and still
        # scrape a pass, and that pass is not evidence the bug is fixed.
        "osa_tool_faults_total": _total(r.get("osa_tool_faults") for r in rows),
        "osa_tool_fault_tasks": sorted(
            r["task_name"] for r in rows if r.get("osa_tool_faults")
        ),
        "denials_total": _total(r.get("denials") for r in rows),
        "denial_tasks": sorted(r["task_name"] for r in rows if r.get("denials")),
        "add_dir_mentions_total": _total(r.get("add_dir_mentions") for r in rows),
        "add_dir_tasks": sorted(
            r["task_name"] for r in rows if r.get("add_dir_mentions")
        ),
        "write_ops_total": _total(r.get("write_ops") for r in rows),
        "write_ops_mean": _mean(r.get("write_ops") for r in rows),
        "peak_context_tokens_max": (
            max(
                (r["peak_context_tokens"] for r in rows if r.get("peak_context_tokens")),
                default=None,
            )
        ),
        "peak_context_tokens_mean": _mean(r.get("peak_context_tokens") for r in rows),
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
        # --- the cost-probe columns -------------------------------------
        # These four are the ones the competitive field publishes and the ones
        # `probeset.py` diffs across optimisation attempts. They are per-TASK,
        # not per-solved-task, on purpose: the denominator must not move when
        # the pass rate moves, or a change that solves fewer tasks looks like a
        # cost win.
        # Uncached input + cache reads + cache writes: every token sent in.
        # A cache read is input the model SAW and was billed for (at 0.1x), so
        # excluding it flatters a cached harness on token count — here by 25x,
        # which would have put us at 34k input tokens/task against a field that
        # publishes 0.7-1.3M. `bench/report/loader.py` has always summed the
        # three; this is the same definition, so the two layers agree.
        "input_tokens_per_task": (
            round(prompt_tok / n, 1) if prompt_tok and n else None
        ),
        "output_tokens_per_task": round(tok_out / n, 1) if tok_out and n else None,
        # Same numerator as input_tokens_per_task, or the ratio would be quoted
        # against a different denominator than the field's 56-85:1.
        "in_out_ratio": (
            round(prompt_tok / tok_out, 1) if prompt_tok and tok_out else None
        ),
        # Uncached input alone, kept separate: it is the figure that actually
        # shrinks when caching works, and collapsing it into the total above
        # would hide that.
        "uncached_input_tokens_total": tok_in,
        # Cache accounting. Every adapter in the field parses cache_read
        # separately and reports a hit rate; a value of 0.0 with a non-null
        # denominator is a real finding, not missing data. `None` means the
        # adapter reported nothing at all, which is a different thing and must
        # not be rendered as zero.
        #
        # The DENOMINATOR is the whole prompt, not the uncached remainder.
        # `Loop.Accounting` subtracts the cached overlap back out of
        # `input_tokens` for every `{:compat, _}` route (an OpenAI-shaped
        # gateway reports `prompt_tokens` inclusive of its cached slice), so
        # `tokens_in` here is the UNCACHED input alone. Dividing cache tokens by
        # it was only ever ~0 or ~None while nothing cached; the first run that
        # actually hit cache — 477 uncached input against 32,577 cache reads on
        # a single turn — would have published a "hit rate" of 6,800%.
        #
        # Numerator is READS only. A write is a miss that got stored: billed at
        # 1.25x input, not 0.1x. Counting writes as hits would score a run that
        # re-writes its prefix every turn — the exact pathology this column
        # exists to catch — as a perfect cache.
        "cache_tokens_total": tok_cache,
        "cache_read_tokens_total": tok_cache_r,
        "cache_creation_tokens_total": tok_cache_w,
        "cache_hit_rate": (
            round(tok_cache_r / prompt_tok, 4)
            if tok_cache_r is not None and prompt_tok
            else None
        ),
        "cost_usd_per_task": round(cost / n, 4) if cost is not None and n else None,
        "turns_mean": _mean(r["turns"] for r in rows),
        "tool_calls_mean": _mean(r["tool_calls"] for r in rows),
        "failure_taxonomy": dict(sorted(taxonomy.items(), key=lambda kv: -kv[1])),
        "self_inflicted_totals": dict(sorted(inflicted.items(), key=lambda kv: -kv[1])),
        "self_inflicted_tasks": inflicted_tasks,
    }

    return {
        "schema_version": SCHEMA_VERSION,
        # Stamped from the run config. It used to be the literal string
        # "terminal-bench-2.0" on every artefact, including runs that were not
        # Terminal-Bench 2.0.
        "benchmark": config.get("dataset_label") or "unknown",
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
        f"# OSA Harbor run — `{cfg['run_id']}`",
        "",
        f"- **Benchmark**: {results.get('benchmark')} via Harbor "
        f"`{cfg.get('harbor_version', '?')}`",
        f"- **Dataset**: `{cfg.get('dataset')}`  ({_fmt(a['dataset_size'])} tasks available)",
        f"- **Dataset key**: `{cfg.get('dataset_key')}`   "
        f"**status**: `{cfg.get('dataset_status')}`",]
    if cfg.get("dataset_status") == "superseded":
        lines += [
            "",
            "> ⚠ **This task set is SUPERSEDED.** It is kept so historical runs "
            "stay re-derivable. A number from it is not comparable to a current "
            "leaderboard and must be labelled with the version.",
        ]
    if cfg.get("probe_set"):
        lines += [
            "",
            f"> Fixed cost probe `{cfg['probe_set']}` — the same tasks every "
            "time, so token and cost figures across runs are paired. This is "
            "**not** a pass-rate measurement; see the cost table below.",
        ]
    lines += [
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
            f"{a['tasks_attempted']} of {_fmt(a['dataset_size'])} tasks. It is a "
            f"pipeline and regression signal, not a {results.get('benchmark')} "
            "score, and must not be quoted as one.",
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
        "## Workspace denials",
        "",
        "OSA's path policy did not consult the session's working directory, so "
        "in a container with `HOME=/root` and a workspace of `/app` every "
        "`file_write`/`file_read`/`dir_list` on the workspace was refused. "
        "These are the counters that say whether that is actually gone. "
        "`OSA-at-fault` is the narrow subset stamped `fault_owner: :osa` -- a "
        "refusal of a path genuinely outside the workspace is the boundary "
        "working and is counted under `all denials` only.",
        "",
        "| counter | value | tasks |",
        "|---|---|---|",
        f"| **OSA-at-fault tool denials** | {_fmt(a.get('osa_tool_faults_total'))} "
        f"| {len(a.get('osa_tool_fault_tasks') or [])} |",
        f"| all path denials seen by the model | {_fmt(a.get('denials_total'))} "
        f"| {len(a.get('denial_tasks') or [])} |",
        f"| `/add-dir` mentions (the give-up signature) | "
        f"{_fmt(a.get('add_dir_mentions_total'))} "
        f"| {len(a.get('add_dir_tasks') or [])} |",
        f"| write ops (total / mean per task) | "
        f"{_fmt(a.get('write_ops_total'))} / {_fmt(a.get('write_ops_mean'))} | — |",
        f"| peak context tokens (max / mean) | "
        f"{_fmt(a.get('peak_context_tokens_max'))} / "
        f"{_fmt(a.get('peak_context_tokens_mean'))} | — |",
        "",]
    if a.get("osa_tool_faults_total"):
        lines += [
            "> ⚠ **OSA denied tool calls on paths inside its own workspace on "
            f"{len(a.get('osa_tool_fault_tasks') or [])} task(s).** Any failure "
            "among them is a harness fault, not a model failure, and the token "
            "figures on those tasks include the cost of working around OSA.",
            "",
        ]
    lines += [
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
        f"| tokens in (uncached only) | {_fmt(a['tokens_in_total'])} |",
        f"| tokens out | {_fmt(a['tokens_out_total'])} |",
        f"| tokens / solved task | {_fmt(a['tokens_per_resolved'])} |",
        f"| cost total | {_fmt(a['cost_usd_total'], ' USD')} |",
        f"| **input tokens / task** (incl. cache reads) | "
        f"{_fmt(a['input_tokens_per_task'])} |",
        f"| **in:out ratio** | {_fmt(a['in_out_ratio'], ':1')} |",
        f"| **cache hit rate** | "
        + ("n/a (adapter reported no cache counter)"
           if a["cache_hit_rate"] is None
           else f"{a['cache_hit_rate'] * 100:.1f}% "
                f"(reads {_fmt(a.get('cache_read_tokens_total'))} of "
                f"{_fmt((a['tokens_in_total'] or 0) + (a.get('cache_read_tokens_total') or 0) + (a.get('cache_creation_tokens_total') or 0))} prompt tokens)")
        + " |",
        f"| cache writes (billed 1.25x) | {_fmt(a.get('cache_creation_tokens_total'))} |",
        f"| **$ / task** | {_fmt(a['cost_usd_per_task'], ' USD')} |",
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
        "| task | reward | owner | reason | wall s | turns | tools | tok in | tok out "
        "| writes | peak ctx | denials | OSA-fault |",
        "|---|---|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    for r in results["tasks"]:
        lines.append(
            "| `{t}` | {rw} | {ow} | {rs} | {w} | {tu} | {tc} | {ti} | {to} "
            "| {wr} | {pk} | {dn} | {of} |".format(
                t=r["task_name"],
                rw=_fmt(r["reward"]),
                ow=r["fault_owner"],
                rs=r["failure_reason"] or "-",
                w=_fmt(r["wall_clock_s"]),
                tu=_fmt(r["turns"]),
                tc=_fmt(r["tool_calls"]),
                ti=_fmt(r["tokens_in"]),
                to=_fmt(r["tokens_out"]),
                wr=_fmt(r.get("write_ops")),
                pk=_fmt(r.get("peak_context_tokens")),
                dn=_fmt(r.get("denials")),
                of=_fmt(r.get("osa_tool_faults")),
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
