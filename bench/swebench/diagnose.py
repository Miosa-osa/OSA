"""Classify *why* an instance failed, and whose fault it was.

The pass rate is the least useful number this harness produces. What we
actually want from a benchmark run is a ranked list of things to fix, and that
requires separating two very different failures that look identical in
`results.json`:

  **model failure** -- OSA worked correctly and the model still produced a
      wrong or incomplete patch. Nothing to fix in OSA; this is the benchmark
      measuring what it claims to measure.

  **harness failure** -- OSA got in the model's way. A tool errored, a result
      came back truncated past usefulness, the context meter was broken so
      compaction never fired, the turn ended while there was obviously work
      left, the stream died. These are OSA bugs, they are the reason for
      running this at all, and they must not be averaged into "the model is not
      good enough".

The split is deliberately conservative: an instance is only called a harness
failure when there is positive evidence of OSA misbehaving. When in doubt it is
recorded as a model failure, because over-claiming OSA bugs would make this
tool useless in the opposite direction.

Every bucket name is stable and every failure lands in exactly one, so the
distribution can be diffed across runs.
"""

from __future__ import annotations

import json
from pathlib import Path

#: Failure buckets, grouped by who is responsible. The order within each list
#: is the order they are tested in -- most specific first.
HARNESS_BUCKETS = [
    "osa_refused_the_task",
    "osa_stream_died",
    "osa_agent_crashed",
    "osa_timeout",
    "osa_tool_failures",
    "osa_truncated_observations",
    "osa_context_window_unresolved",
    "osa_stalled",
    "osa_stopped_early",
]

MODEL_BUCKETS = [
    "model_no_patch",
    "model_edited_tests_only",
    "model_patch_did_not_apply",
    "model_regression_pass_to_pass_broke",
    "model_fix_incomplete_fail_to_pass_still_failing",
    "model_fix_incomplete_and_regressed",
]

INFRA_BUCKETS = [
    "bench_workspace_error",
    "bench_eval_error",
    "bench_eval_incomplete",
]

UNCLASSIFIED = "unclassified"

#: A turn that ended after this few tool calls, with no patch and no error, is
#: an agent that gave up rather than one that tried and failed.
GAVE_UP_TOOL_CALLS = 3

#: OSA's guardrails can refuse a turn *before* the LLM ever sees it, replying
#: with a fixed string. When that happens the instance is unwinnable and it has
#: nothing to do with the model's ability -- but from the outside it looks
#: exactly like an agent that did nothing, and was originally bucketed as
#: `model_no_patch`, i.e. blamed on the model.
#:
#: Observed live: three instances refused in ~1.0s with zero tool calls and
#: zero LLM turns, because the structural prompt-injection detector matches
#: `/(?:^|\n)\s*(?:system|assistant|user)\s*:/i` and scikit-learn's and
#: matplotlib's issue templates embed a `System:` line (the header of
#: `sklearn.show_versions()` environment output).
REFUSAL_MARKERS = (
    "i can't share my internal configuration or system instructions",
    "i cannot share my internal configuration",
)


#: OSA-internal faults that end a turn but were emitted as `kind: :llm_error`,
#: i.e. as if the model provider had failed. There is now an additive `owner`
#: field on `turn_error` that says `:osa`, but runs recorded before it carry no
#: owner at all -- so historical artifacts are re-scored from the fault's own
#: text, which is unambiguous.
#:
#: Measured on disk: `osa-hard40-airgap/sympy__sympy-13877` died at iteration 18
#: on `Ollama unexpected error: invalid byte 0xA9 in <<...>>` -- a non-UTF-8
#: file path in tool output -- and was filed as `model_no_patch`, fault=model.
LEGACY_OSA_FAULT_MARKERS = (
    ("encoding_fault", "invalid byte 0x"),
    ("encoding_fault", "not valid utf-8"),
    ("request_shape", "this is a bug in osa"),
    ("request_shape", "request_shape"),
    ("tool_use_mismatch", "tool_use_mismatch"),
    ("duplicate_tool_use", "duplicate_tool_use"),
)


def _legacy_osa_fault(inference: dict) -> str | None:
    """Name the OSA-internal fault a turn died on, for runs with no `owner`.

    Only the FINAL message is consulted: a marker seen mid-run may have been
    retried past, whereas the last thing the session said is what ended it.
    """
    sig = (inference.get("raw") or {}).get("osa_signals") or {}
    tail = (sig.get("final_message_tail") or "").lower()
    if not tail:
        return None
    for name, marker in LEGACY_OSA_FAULT_MARKERS:
        if marker in tail:
            return name
    return None


def _looks_refused(inference: dict) -> bool:
    sig = (inference.get("raw") or {}).get("osa_signals") or {}
    tail = (sig.get("final_message_tail") or "").strip().lower()
    if not tail:
        return False
    if not any(m in tail for m in REFUSAL_MARKERS):
        return False
    # A refusal only counts when nothing else happened. If the agent worked and
    # merely mentioned this at the end, it is not a refused turn.
    return not (inference.get("tool_calls") or 0)


def _tests_moved(detail: dict) -> tuple[list, list, list, list]:
    """(f2p_pass, f2p_fail, p2p_pass, p2p_fail) from the harness's own report."""
    status = detail.get("tests_status") or {}
    f2p = status.get("FAIL_TO_PASS", {}) or {}
    p2p = status.get("PASS_TO_PASS", {}) or {}
    return (
        f2p.get("success") or [],
        f2p.get("failure") or [],
        p2p.get("success") or [],
        p2p.get("failure") or [],
    )


def patch_apply_failed(report_dir: Path, run_id: str, model: str, iid: str) -> bool:
    """Did the official harness refuse to apply our patch?

    `error_ids` lumps together "the patch did not apply" and "the container
    fell over", which are a model problem and an infrastructure problem
    respectively. The per-instance run log is the only place that distinguishes
    them.
    """
    log = (
        report_dir
        / "logs"
        / "run_evaluation"
        / run_id
        / model.replace("/", "__")
        / iid
        / "run_instance.log"
    )
    if not log.exists():
        return False
    try:
        text = log.read_text(errors="replace")
    except OSError:
        return False
    return "APPLY_PATCH_FAIL" in text or "Patch Apply Failed" in text


def classify(
    *,
    outcome: str,
    inference: dict,
    detail: dict,
    patch_did_not_apply: bool = False,
) -> dict:
    """Return {bucket, fault, evidence} for one instance.

    `fault` is one of: none | model | harness | bench.
    """
    if outcome == "resolved":
        return {"bucket": "", "fault": "none", "evidence": []}

    st = inference.get("status")
    sig = (inference.get("raw") or {}).get("osa_signals") or {}
    ev: list[str] = []

    # ---- 0. OSA declined to attempt the task at all -----------------------
    # Checked first: a refused turn also has no patch and no tool calls, so
    # every later rule would happily misfile it as the model's failure.
    if _looks_refused(inference):
        return {
            "bucket": "osa_refused_the_task",
            "fault": "harness",
            "evidence": [
                "OSA's guardrails refused the turn before the model saw it — "
                "zero tool calls, zero LLM turns, canned refusal text",
                "the issue body contains a line matching OSA's structural "
                "prompt-injection detector "
                r"(/(?:^|\n)\s*(?:system|assistant|user)\s*:/i); "
                "scikit-learn and matplotlib issue templates paste a `System:` "
                "environment block, which is not an injection attempt",
                "this instance was unwinnable and says nothing about the model",
            ],
        }

    # A turn that ended on an OSA-internal fault. `st` covers runs recorded by
    # the owner-aware runner; `_legacy_osa_fault` re-scores everything older.
    legacy = _legacy_osa_fault(inference)
    if st == "osa_internal_error" or legacy:
        return {
            "bucket": f"osa_internal_turn_error:{legacy or 'owner_osa'}",
            "fault": "harness",
            "evidence": [
                inference.get("error")
                or ((inference.get("raw") or {}).get("osa_signals") or {}).get(
                    "final_message_tail", ""
                )[:300],
                "the turn ended on an OSA-internal fault emitted as an LLM "
                "error; the missing/partial patch is not the model's doing",
            ],
        }
    if st == "provider_error":
        return {
            "bucket": "provider_turn_error",
            "fault": "provider",
            "evidence": [inference.get("error") or "the provider failed the turn"],
        }
    if st == "turn_error_unattributed":
        return {
            "bucket": "turn_error_unattributed",
            "fault": "unattributed",
            "evidence": [
                inference.get("error") or "turn ended on an error",
                "the error carried no `owner` field and matched no known "
                "OSA-internal fault, so it is attributed to nobody rather than "
                "to the model",
            ],
        }

    # ---- 1. OSA visibly broke, in ways that make the patch irrelevant -----
    if st == "runner_error":
        err = inference.get("error") or ""
        if "SSE stream closed" in err:
            return {
                "bucket": "osa_stream_died",
                "fault": "harness",
                "evidence": [f"the event stream ended before `done`: {err}"],
            }
        # A workspace/docker/git failure is ours, not OSA's and not the model's.
        if "git diff failed" in err or "docker" in err.lower():
            return {"bucket": "bench_workspace_error", "fault": "bench",
                    "evidence": [err]}
        return {"bucket": "osa_stream_died", "fault": "harness", "evidence": [err]}

    if st == "agent_error":
        return {
            "bucket": "osa_agent_crashed",
            "fault": "harness",
            "evidence": [inference.get("error") or "agent exited non-zero"],
        }

    # ---- 2. Nothing was submitted -----------------------------------------
    if st == "tests_only_patch":
        dropped = (inference.get("raw") or {}).get("dropped_test_paths") or []
        return {
            "bucket": "model_edited_tests_only",
            "fault": "model",
            "evidence": [
                "the only files edited were tests, which the grader reverts: "
                + ", ".join(dropped[:5])
            ],
        }

    if outcome == "empty_patch" or st == "empty_patch":
        # An empty patch after a handful of tool calls with tool errors is OSA
        # blocking the agent; an empty patch after real work is the model
        # declining to commit to a fix.
        tc = inference.get("tool_calls") or 0
        if sig.get("tool_failures"):
            ev.append(
                f"{sig['tool_failures']} tool call(s) failed: "
                f"{sig.get('tool_failure_names')}"
            )
        if tc <= GAVE_UP_TOOL_CALLS and sig.get("tool_failures"):
            return {"bucket": "osa_tool_failures", "fault": "harness",
                    "evidence": ev + [f"only {tc} tool calls before giving up"]}
        return {"bucket": "model_no_patch", "fault": "model",
                "evidence": ev + [f"{tc} tool calls, no source file changed"]}

    # ---- 3. Graded, and lost ----------------------------------------------
    if outcome == "eval_error":
        if patch_did_not_apply:
            return {
                "bucket": "model_patch_did_not_apply",
                "fault": "model",
                "evidence": ["the grader could not apply the diff to a clean tree"],
            }
        return {"bucket": "bench_eval_error", "fault": "bench",
                "evidence": ["the official harness errored on this instance"]}

    if outcome == "incomplete":
        return {"bucket": "bench_eval_incomplete", "fault": "bench",
                "evidence": ["the official harness never finished this instance"]}

    f2p_ok, f2p_bad, _p2p_ok, p2p_bad = _tests_moved(detail)

    # OSA-side evidence that a *test* failure was really an OSA failure: the
    # agent could not observe its own work well enough to get it right.
    if sig.get("truncated_results"):
        ev.append(
            f"{sig['truncated_results']} tool result(s) were truncated or spilled "
            f"to a sidecar file before the model saw them"
        )
    if sig.get("context_window_reported") == 0:
        ev.append(
            "OSA reported max_tokens=0 for this session, so its own context "
            "meter read 0% all run and compaction thresholds could never fire"
        )
    if sig.get("tool_failures"):
        ev.append(
            f"{sig['tool_failures']} tool call(s) failed: {sig.get('tool_failure_names')}"
        )

    if p2p_bad and f2p_bad:
        bucket, fault = "model_fix_incomplete_and_regressed", "model"
        ev.append(
            f"{len(f2p_bad)} target test(s) still failing AND {len(p2p_bad)} "
            f"previously-passing test(s) broken"
        )
    elif p2p_bad:
        bucket, fault = "model_regression_pass_to_pass_broke", "model"
        ev.append(
            f"all {len(f2p_ok)} target test(s) flipped, but the patch broke "
            f"{len(p2p_bad)} unrelated test(s): {p2p_bad[:5]}"
        )
    elif f2p_bad:
        bucket, fault = "model_fix_incomplete_fail_to_pass_still_failing", "model"
        ev.append(f"{len(f2p_bad)} target test(s) still failing: {f2p_bad[:5]}")
    elif not detail:
        # Graded "unresolved" but the harness wrote no per-instance detail.
        return {"bucket": UNCLASSIFIED, "fault": "bench",
                "evidence": ["no per-instance report was written by the grader"]}
    else:
        return {"bucket": UNCLASSIFIED, "fault": "model", "evidence": ev}

    # A model-shaped failure with strong OSA-side evidence gets reported as
    # BOTH: the bucket stays model (the patch really was wrong) but the
    # evidence carries the OSA problem so it is not lost. A truncated
    # observation is promoted, because a model that could not see the file it
    # was editing did not get a fair attempt.
    if sig.get("truncated_results", 0) >= 2:
        return {"bucket": "osa_truncated_observations", "fault": "harness",
                "evidence": ev}

    return {"bucket": bucket, "fault": fault, "evidence": ev}


def summarize(rows: list[dict]) -> dict:
    """Aggregate the per-instance classifications into the report block."""
    buckets: dict[str, int] = {}
    faults: dict[str, int] = {
        "none": 0, "model": 0, "harness": 0, "bench": 0,
        # Neither OSA's code nor the model's competence. Kept separate so
        # neither side absorbs them by default.
        "provider": 0, "unattributed": 0,
    }
    for r in rows:
        b = r.get("failure_bucket") or ""
        if b:
            buckets[b] = buckets.get(b, 0) + 1
        faults[r.get("failure_fault", "none")] = (
            faults.get(r.get("failure_fault", "none"), 0) + 1
        )

    failed = sum(v for k, v in faults.items() if k != "none")
    return {
        "buckets": dict(sorted(buckets.items(), key=lambda kv: -kv[1])),
        "by_fault": faults,
        "failures_total": failed,
        # The headline diagnostic number: of everything that went wrong, how
        # much was OSA rather than the model.
        "harness_fault_share": (
            round(faults.get("harness", 0) / failed, 3) if failed else None
        ),
    }


def repeated_harness_failures(rows: list[dict], threshold: int = 2) -> list[dict]:
    """Harness-fault buckets seen `threshold`+ times -- i.e. probable OSA bugs.

    A one-off can be bad luck. The same OSA-side failure twice in one run is a
    bug report, and the caller is expected to surface these rather than leave
    them inside a distribution table.
    """
    counts: dict[str, list[str]] = {}
    for r in rows:
        if r.get("failure_fault") == "harness":
            counts.setdefault(r["failure_bucket"], []).append(r["instance_id"])
    return [
        {"bucket": b, "count": len(ids), "instances": sorted(ids)}
        for b, ids in sorted(counts.items(), key=lambda kv: -len(kv[1]))
        if len(ids) >= threshold
    ]


def write_failure_dossiers(results: dict, out_dir: Path) -> int:
    """One markdown file per failure, with everything needed to diagnose it.

    Failures are the deliverable. A bucket name in a table is not enough to act
    on; the patch, the tests that moved, the OSA signals and a pointer to the
    session transcript are.
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    n = 0
    for r in results["instances"]:
        if r["resolved"]:
            continue
        n += 1
        lines = [
            f"# {r['instance_id']}",
            "",
            f"- **bucket**: `{r.get('failure_bucket')}`  (fault: **{r.get('failure_fault')}**)",
            f"- **outcome**: `{r['outcome']}`   **agent status**: `{r.get('agent_status')}`",
            f"- **wall clock**: {r['wall_clock_s']}s   **tool calls**: {r.get('tool_calls')}"
            f"   **turns**: {r.get('turns')}",
            f"- **patch size**: {r.get('patch_bytes')} bytes",
            "",
            "## Why this is the verdict",
            "",
        ]
        lines += [f"- {e}" for e in (r.get("failure_evidence") or ["(no evidence recorded)"])]

        if r.get("fail_to_pass_failing"):
            lines += ["", "## FAIL_TO_PASS still failing", ""]
            lines += [f"- `{t}`" for t in r["fail_to_pass_failing"][:25]]
        if r.get("pass_to_pass_failing"):
            lines += ["", "## PASS_TO_PASS broken by the patch", ""]
            lines += [f"- `{t}`" for t in r["pass_to_pass_failing"][:25]]

        sig = r.get("osa_signals") or {}
        if sig:
            lines += ["", "## OSA signals", "", "```json",
                      json.dumps(sig, indent=2)[:6000], "```"]

        if r.get("transcript_dir"):
            lines += ["", "## Session transcript", "",
                      f"`{r['transcript_dir']}`",
                      "",
                      "(`*.json` = replayed transcript, `*.updates.jsonl` = the "
                      "append-only event log compaction never prunes.)"]
        if r.get("event_log"):
            lines += ["", f"SSE frames: `{r['event_log']}`"]

        if r.get("model_patch"):
            lines += ["", "## Submitted patch", "", "```diff",
                      r["model_patch"][:20000], "```"]

        (out_dir / f"{r['instance_id']}.md").write_text("\n".join(lines) + "\n")
    return n
