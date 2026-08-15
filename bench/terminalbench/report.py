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

# The interval implementation lives in `bench/report/stats.py`, which has tests.
# Duplicating the arithmetic here to avoid the import would duplicate the one
# part of this file that is genuinely easy to get subtly wrong, so the import is
# made to work rather than avoided.
#
# It has to be loaded BY PATH. `bench/report/` is a package and THIS module is
# also named `report`; whichever of the two `sys.path` reaches first shadows the
# other, and from inside `bench/terminalbench/` that is always this file. A
# plain `from report.stats import wilson` therefore fails with "'report' is not
# a package" -- which it did, silently falling back to no interval at all.
def _load_wilson():
    import importlib.util

    src = Path(__file__).resolve().parents[1] / "report" / "stats.py"
    if not src.exists():
        return None
    try:
        spec = importlib.util.spec_from_file_location("_bench_report_stats", src)
        if spec is None or spec.loader is None:
            return None
        mod = importlib.util.module_from_spec(spec)
        # Registered BEFORE exec_module: `stats.py` declares a frozen
        # `@dataclass`, and dataclasses resolves a field's type by looking its
        # defining module up in `sys.modules`. On an unregistered module that
        # lookup returns None and construction dies inside `_is_type` with an
        # AttributeError that names neither this file nor the real cause.
        sys.modules[spec.name] = mod
        spec.loader.exec_module(mod)
        return mod.wilson
    except Exception:  # noqa: BLE001
        return None


_wilson = _load_wilson()

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


#: Provider-message phrasings that mean "this account/session has no budget
#: left", as opposed to "you are going too fast, back off".
#:
#: The two arrive as the same HTTP 429 and OSA's `ErrorCatalog` collapses both
#: to `:rate_limit` (`providers/error_catalog.ex:197`), so the distinction can
#: only be recovered from the message. Sourced from the text actually observed:
#: `runs/rerun-timeouts-f6981b61` carries `"you (focused_varahamihira_355) have
#: reached your session usage limit, add extra usage: ..."` on 4 trials. The
#: rest of the table is Harbor's own vocabulary for the same condition
#: (`agents/installed/base.py:444-447`, the four `ApiUsageLimitError` patterns),
#: kept aligned so our label and Harbor's exception type cannot disagree.
_QUOTA_PHRASES = (
    "usage limit",
    "quota exceeded",
    "insufficient_quota",
    "insufficient quota",
    "exceeded your current quota",
    "unpaid invoice",
    "billing hard limit",
    "credit balance is too low",
)


def _is_quota_exhaustion(turn_error) -> bool:
    """True when a turn-ending provider error was budget exhaustion."""
    if not isinstance(turn_error, dict):
        return False
    if (turn_error.get("category") or "").lstrip(":") != "rate_limit":
        return False
    reason = str(turn_error.get("reason") or "").lower()
    return any(p in reason for p in _QUOTA_PHRASES)


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
        # "The provider refused this request" and "our account has no budget
        # left" are the same status and utterly different findings, and only one
        # of them says anything at all about the harness or the model.
        #
        # Measured on `runs/rerun-timeouts-f6981b61`: 4 of the 6 retry trials
        # died on `Ollama returned 429: ... you have reached your session usage
        # limit`, every one recorded as `provider_error` with reward 0.0 and
        # `exception_info: null`. Those four are not measurements. Reporting
        # them beside a genuine upstream 500 -- or, worse, inside an accuracy
        # denominator -- is how a night of exhausted quota turns into a score.
        #
        # The category comes from OSA's own `ErrorCatalog`
        # (`providers/error_catalog.ex:197` maps HTTP 429 -> `:rate_limit`), and
        # the quota-vs-transient distinction from the provider's own message
        # text. That text is a structured field on the error, not task output,
        # so matching it is not the free-text guessing the driver's
        # `_classifier_line` refuses to do.
        if _is_quota_exhaustion(meta.get("osa_turn_error")):
            return "provider_quota_exhausted"
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
    if reason == "provider_quota_exhausted":
        # Never the model's, never OSA's: our account ran out of budget
        # mid-episode. It is not `harness` either -- `harness_fault_rate` is
        # read as an OSA-quality signal and an exhausted wallet says nothing
        # about OSA's code. It is reported separately and excluded from the
        # quotable denominator entirely; see `void_tasks` in `build`.
        return "ambiguous"
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

    # `n_input_tokens` is deliberately NOT a source here any more.
    #
    # Since D7 (`osa_agent.py::populate_context_post_run`) that field carries
    # the WHOLE prompt -- uncached + cache read + cache creation -- because that
    # is what Harbor's schema means by it (`models/agent/context.py:9-11`).
    # `tokens_in` here is the UNCACHED remainder, and `prompt_tok` below adds
    # the two cache counters back on. Leaving `n_input_tokens` in this `max`
    # would therefore have fed a cache-inclusive total into a slot the caller
    # adds cache to, double-counting every cached token exactly once.
    #
    # The adapter now writes the uncached figure to
    # `metadata.osa_uncached_input_tokens`. Its ABSENCE identifies a pre-D7
    # artefact, whose `n_input_tokens` was uncached and is therefore safe to use
    # -- which is how archived runs stay re-derivable rather than being
    # retroactively mis-scored by a corrected reader.
    pre_d7 = "osa_uncached_input_tokens" not in meta
    return {
        "tokens_in": _max_num(
            meta.get("osa_uncached_input_tokens"),
            agent_result.get("n_input_tokens") if pre_d7 else None,
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


def _trials_by_task(rows: list[dict]) -> dict[str, list[dict]]:
    """Group trial rows by task name.

    With `-k 1` every group has one member and this is the identity. With
    `-k 5` Harbor writes five sibling trial directories per task, distinguished
    only by the random suffix in `trial_name`, so the task name is the only
    stable key.
    """
    groups: dict[str, list[dict]] = {}
    for r in rows:
        groups.setdefault(r["task_name"] or "?", []).append(r)
    return groups


def multi_trial(rows: list[dict], declared_k: int) -> dict[str, Any] | None:
    """Per-task resolution across repeated trials, or None when k == 1.

    ## Why both numbers are reported

    `accuracy` over trial rows is a **per-trial** pass rate. At k=1 it is also
    the per-task rate, which is why the distinction has never mattered here and
    why nothing in this file drew it. At k>1 they are different quantities and
    quoting one for the other is a real error in both directions:

      * **pass@1** (mean per-task pass fraction) is the honest expected result
        of running the benchmark once, and is what a leaderboard row means.
      * **pass@k** (task solved in *at least one* trial) is strictly higher and
        rises with k, so it is only comparable against the same k.

    A single task in our own runs has been observed flipping 4-pass/2-fail with
    no code change, so at k=1 the gap between these two is entirely noise we
    have never measured. `flaky_tasks` names the tasks that did not agree with
    themselves -- that list is the direct evidence for how much of any quoted
    delta is real.
    """
    groups = _trials_by_task(rows)
    observed = [len(v) for v in groups.values()]
    if not observed or max(observed) <= 1:
        return None

    per_task = []
    for task, trials in sorted(groups.items()):
        # A trial that never got a verdict is not a failed attempt. It is
        # excluded from the task's own denominator and counted separately,
        # rather than being folded in as a 0 -- that is the same substitution
        # the exit-code work exists to stop.
        graded = [t for t in trials if t["reward"] is not None]
        n_pass = sum(1 for t in graded if t["resolved"])
        per_task.append(
            {
                "task_name": task,
                "n_trials": len(trials),
                "n_graded": len(graded),
                "n_errored": len(trials) - len(graded),
                "n_pass": n_pass,
                "pass_fraction": (
                    round(n_pass / len(graded), 4) if graded else None
                ),
                "solved_at_least_once": n_pass > 0,
                # Disagreed with itself: the direct measure of how much of any
                # quoted rate is a coin flip.
                "flaky": 0 < n_pass < len(graded),
            }
        )

    scored = [t for t in per_task if t["pass_fraction"] is not None]
    return {
        "n_tasks": len(per_task),
        "n_attempts_declared": declared_k,
        "trials_per_task_observed": sorted(set(observed)),
        # The expected result of running the benchmark ONCE. This is the figure
        # that is comparable to a published leaderboard row.
        "pass_at_1": (
            round(sum(t["pass_fraction"] for t in scored) / len(scored), 4)
            if scored
            else None
        ),
        # Solved in at least one trial out of k. Higher by construction and only
        # comparable against the same k -- never quote it as "the" score.
        "pass_at_k": (
            round(
                sum(1 for t in per_task if t["solved_at_least_once"]) / len(per_task), 4
            )
            if per_task
            else None
        ),
        "k": max(observed),
        "flaky_tasks": sorted(t["task_name"] for t in per_task if t["flaky"]),
        "n_flaky": sum(1 for t in per_task if t["flaky"]),
        "per_task": per_task,
    }


def _mark_void(config: dict, rows: list[dict]) -> None:
    """Stamp `void` / `void_reason` on every row that is not a measurement.

    Two causes, both of which produce a reward that exists but means nothing:

    1. **A non-conforming task copy.** Our local `tasks/` carries four TB 2.0
       tasks with larger budgets or memory than the canonical Hub package
       (`datasets.NONCONFORMING_TASKS`). Both leaderboard contracts forbid
       timeout and resource overrides, and this one is invisible in
       `config.json` because it is baked into the task file. `crack-7z-hash`
       is the case that costs us a point: it **passed** in
       `runs/osa-tb20-full89-f6981b61`.

    2. **Provider quota exhaustion.** The episode stopped because our account
       ran out, not because the agent did anything. See
       `_is_quota_exhaustion`.

    Marking is deliberately NOT subtraction. The row keeps its reward and stays
    in `accuracy`, which remains the raw over-everything-attempted figure a
    reader would compute themselves; the void set is published beside it with
    `accuracy_excluding_void`. Silently shrinking a denominator is the failure
    mode this whole reporter exists to prevent, and it would be no better done
    in our own favour than against us.
    """
    key = config.get("dataset_key")
    nonconforming: dict[str, Any] = {}
    if key:
        try:
            sys.path.insert(0, str(Path(__file__).resolve().parent))
            import datasets as _datasets

            ds = _datasets.DATASETS.get(key)
            if ds is not None:
                nonconforming = _datasets.nonconforming_tasks(ds)
                _void_note = _datasets.void_reason
        except Exception:  # noqa: BLE001
            nonconforming = {}
    for r in rows:
        short = r["task_name"].split("/")[-1]
        reasons: list[str] = []
        if short in nonconforming:
            reasons.append(_void_note(_datasets.DATASETS[key], short) or "")
        if r.get("failure_reason") == "provider_quota_exhausted":
            reasons.append(
                "provider quota exhausted mid-episode: the account ran out of "
                "budget, so this trial measured neither the model nor the "
                "harness. Not a scoreable result."
            )
        r["void"] = bool(reasons)
        r["void_reason"] = " | ".join(x for x in reasons if x) or None


def build(*, config: dict, rows: list[dict]) -> dict[str, Any]:
    _mark_void(config, rows)
    n = len(rows)
    void_rows = [r for r in rows if r.get("void")]
    live_rows = [r for r in rows if not r.get("void")]
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
    multi = multi_trial(rows, config.get("n_attempts") or 1)
    # DISTINCT TASKS, not trial rows. At k=1 these are the same number, which is
    # why every field below could get away with using `n`. At k>1 `n` is
    # `tasks x k`, and comparing it against `dataset_size` would make a 5-trial
    # 89-task run look like 445 tasks and declare itself not a full run.
    n_tasks = multi["n_tasks"] if multi else n

    aggregate = {
        "tasks_attempted": n_tasks,
        # Trial rows behind `tasks_attempted`. Equal to it at k=1.
        "trials_attempted": n,
        "tasks_resolved": len(resolved),
        # Accuracy over everything attempted -- the number Terminal-Bench would
        # report. NOT a Terminal-Bench 2.0 score unless is_full_dataset_run.
        #
        # At k>1 this is the PER-TRIAL pass rate. The per-task figures live in
        # `multi_trial` and `pass_at_1` there is the one comparable to a
        # published row; see that function's docstring for why the two differ.
        "accuracy": round(len(resolved) / n, 4) if n else None,
        # --- excluded-with-cause ----------------------------------------
        # Trials that are not measurements at all: a non-conforming task copy,
        # or an episode our provider quota killed. Published as an explicit
        # per-task list rather than folded away, because "we dropped 1 of 89"
        # is a claim a reader must be able to audit. See `_mark_void`.
        "void_tasks": [
            {"task_name": r["task_name"], "reward": r["reward"],
             "resolved": r["resolved"], "reason": r["void_reason"]}
            for r in void_rows
        ],
        "n_void": len(void_rows),
        # The rate over what was actually measured. Quote THIS, with the void
        # list beside it, or quote `accuracy` and say what is in it -- never
        # `accuracy` alone once `n_void > 0`.
        "accuracy_excluding_void": (
            round(sum(1 for r in live_rows if r["resolved"]) / len(live_rows), 4)
            if live_rows
            else None
        ),
        # Quota deaths on their own. `provider_quota_exhausted` is reported
        # apart from `provider_error` because an exhausted wallet and an
        # upstream 500 are not the same finding, and neither is the model's.
        "quota_exhausted_tasks": sorted(
            r["task_name"]
            for r in rows
            if r.get("failure_reason") == "provider_quota_exhausted"
        ),
        # None at k=1. Populated the moment any task has more than one trial,
        # and carries pass@1, pass@k and the list of tasks that disagreed with
        # themselves.
        "multi_trial": multi,
        # Both leaderboards require >= 5 trials per task, verbatim. Recorded
        # here so a results file states its own admissibility rather than
        # leaving a reader to assume.
        "n_attempts": config.get("n_attempts") or 1,
        "meets_leaderboard_trial_minimum": (config.get("n_attempts") or 1) >= 5,
        # A solve rate without an interval invites the reader to compare it to
        # a published figure digit-for-digit, which at these denominators is
        # never warranted: at n=89 a 60% result carries roughly +/-10 pp at 95%
        # confidence, so a 5-point gap to another single-run figure is not a
        # gap. Wilson rather than normal-approximation because it stays sane at
        # k=0 and k=n, which the probe sets reach.
        "accuracy_ci95": (
            {
                "low": round(_wilson(len(resolved), n).low, 4),
                "high": round(_wilson(len(resolved), n).high, 4),
                "method": "wilson",
                "confidence": 0.95,
            }
            if _wilson is not None and n
            else None
        ),
        # Accuracy with harness faults removed from the denominator. Higher by
        # construction; only meaningful next to harness_fault_rate.
        "accuracy_excluding_harness_faults": (
            round(len(resolved) / n_scoreable, 4) if n_scoreable else None
        ),
        # Full means "every task the selected dataset has", whatever that
        # dataset is. Compared against the size the runner recorded, which it
        # counted from disk.
        "is_full_dataset_run": bool(declared_size) and n_tasks == declared_size,
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
        # Effort and the timeout multiplier are conditions of the measurement,
        # not of the invocation. Anthropic measures 10.3 pp of movement on
        # effort alone and cline measures 11.2 pp on this exact model; a
        # timeout multiplier converts possible solves into guaranteed fails.
        # `UNPINNED` is printed in full rather than left blank because a blank
        # reads as "default" and it is not -- it is "unknown".
        f"- **Effort**: `{cfg.get('effort') or 'UNPINNED'}`   "
        f"**ollama think**: `{cfg.get('ollama_think') or 'UNPINNED'}`   "
        # The GLOBAL multiplier is the one cline published at 2.0; the agent-only
        # override is printed beside it only when it differs, because a reader
        # who sees one number will assume it governed every phase.
        f"**timeout multiplier**: `{cfg.get('timeout_multiplier') or 1.0}`"
        + (
            f" (agent phase overridden to `{cfg['agent_timeout_multiplier']}`)"
            if cfg.get("agent_timeout_multiplier")
            else ""
        ),
        f"- **Started**: {cfg.get('started_at')}",
        f"- **Graded by**: the task's own `tests/test.sh` inside the task container "
        f"(final container state, not a patch)",
        "",
        "## Headline",
        "",
        f"**{a['tasks_resolved']} / {a['trials_attempted']} solved "
        f"({(a['accuracy'] or 0) * 100:.1f}%)**",
        "",
    ]
    if a.get("n_void"):
        # Printed HERE, directly under the headline, and not in a footnote.
        # A reader who stops after the headline must not stop before this.
        n_live = a["trials_attempted"] - a["n_void"]
        n_live_resolved = round((a["accuracy_excluding_void"] or 0) * n_live)
        lines += [
            f"> **{a['n_void']} of these {a['trials_attempted']} trials are NOT "
            "measurements** and the headline above therefore is not a quotable "
            "rate. Excluding them: "
            f"**{n_live_resolved} / {n_live} = "
            f"{(a['accuracy_excluding_void'] or 0) * 100:.1f}%**.",
            ">",
        ]
        for v in a["void_tasks"]:
            verdict = "PASSED" if v["resolved"] else "failed"
            lines += [f"> - `{v['task_name']}` ({verdict}) — {v['reason']}"]
        lines += [""]
    if a.get("quota_exhausted_tasks"):
        lines += [
            f"> **Provider quota died during this run.** "
            f"{len(a['quota_exhausted_tasks'])} trial(s) stopped because the "
            "account ran out of budget, not because the agent failed: "
            + ", ".join(f"`{t}`" for t in a["quota_exhausted_tasks"])
            + ". These are infrastructure deaths and are excluded above. "
            "Do not read them as model failures.",
            "",
        ]
    mt = a.get("multi_trial")
    if mt:
        # At k>1 the headline above is a per-TRIAL rate. Say so immediately and
        # give the per-task figures, because pass@1 and pass@k are different
        # quantities and only pass@1 is comparable to a leaderboard row.
        lines += [
            f"Run at **k={mt['k']}** trials/task over {mt['n_tasks']} tasks, so "
            "the line above is a per-**trial** rate. The per-**task** figures:",
            "",
            f"- **pass@1 = {(mt['pass_at_1'] or 0) * 100:.1f}%** — the expected "
            "result of running the benchmark once. This is the figure "
            "comparable to a published leaderboard row.",
            f"- **pass@{mt['k']} = {(mt['pass_at_k'] or 0) * 100:.1f}%** — solved "
            f"in at least one of {mt['k']} trials. Higher by construction and "
            f"only comparable against another k={mt['k']} figure. Never quote "
            "it as \"the\" score.",
            "",
        ]
        if mt["n_flaky"]:
            lines += [
                f"**{mt['n_flaky']} task(s) disagreed with themselves** across "
                f"trials: {', '.join(mt['flaky_tasks'])}. That disagreement is "
                "the measured noise floor of this run; a delta smaller than it "
                "is not a result.",
                "",
            ]
    elif not a.get("meets_leaderboard_trial_minimum"):
        lines += [
            "> Run at **k=1**. Both Terminal-Bench leaderboards require a "
            "minimum of **five trials per task** (\"Each task must be evaluated "
            "with a minimum of five trials\"), so this figure is **not "
            "admissible** and is not comparable to a published row: the "
            "per-task result is a single sample, and tasks in this suite have "
            "been observed flipping between pass and fail with no code change.",
            "",
        ]
    ci = a.get("accuracy_ci95")
    if ci:
        lines += [
            f"95% CI (Wilson): **{ci['low'] * 100:.1f}% – {ci['high'] * 100:.1f}%**. "
            "Any published figure inside this band is not distinguishable from "
            "this one on this evidence.",
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
