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

import airgap
import diagnose

#: Tools that can reach the public internet, where the real fix for a 2019-2023
#: GitHub issue is published. The container the tests run in is `--network
#: none`, but OSA itself runs on the HOST, so the sandbox does not constrain it.
#: SWE-bench's own checklist requires that the agent cannot look the answer up;
#: Epoch runs airgapped for exactly this reason.
#:
#: Enforcement is now possible and is done by `airgap.py`: a permissions deny
#: list in the BACKEND's OSA_SETTINGS (flag) layer, which outranks overdrive.
#: Measurement stays regardless, because a control that is only ever asserted
#: is how the last one shipped broken.
NETWORK_TOOLS = airgap.NETWORK_TOOLS

_ENFORCEMENT_NONE = (
    "NONE. Measured, not prevented. This run's backend was not started with "
    "the OSA_SETTINGS deny list (bench/swebench/airgap.py), so web_search / "
    "web_fetch / download / browser were callable and permission_mode "
    "overdrive disabled the approval path. Note that a workspace-local "
    ".osa/settings.local.json deny hook was tried EARLIER and verified "
    "ineffective -- Settings.layer(:local) resolves through a process-global "
    "Workspace.Cwd, so a per-request working_dir cannot scope it. The flag "
    "layer is what works; see airgap.py."
)

_ENFORCEMENT_PROBED = (
    "DENY LIST in the backend's OSA_SETTINGS (flag) layer, verified by a live "
    "differential probe before this run started: the denied tool was called "
    "and refused in 0ms while a non-denied control tool succeeded in the same "
    "session under permission_mode overdrive. Permissions.rules/0 reads the "
    "flag layer and ToolExecutor consults deny rules BEFORE any permission-"
    "mode short-circuit, so overdrive does not bypass it. The attestation is "
    "in config.airgap and airgap-probe.json. RESIDUAL: shell_execute remains "
    "available; deny rules cover it by command prefix only, so egress built "
    "inside a Python one-liner is detected after the fact (see "
    "residual_shell_egress) rather than prevented."
)


def network_tool_use(rows: list[dict], attestation: dict | None = None) -> dict:
    """Who reached for the network, and who actually got there.

    These are two different questions and the first version of this function
    answered only one of them, which produced a false alarm the first time the
    airgap worked: the agent ATTEMPTED seven lookups across five instances, was
    refused every time, and the run was reported as a breach.

    So attempts and successes are counted separately now.
    `osa_signals.tool_names` counts `tool_call phase=start` frames (attempts);
    `tool_failure_names` counts `phase=end, success=false` (refusals, and
    genuine tool errors -- indistinguishable from the stream, which is why the
    probe attestation is what establishes that a refusal is a refusal).
    A DENIED attempt cannot have leaked anything, so only a SUCCEEDED call
    invalidates a score. The attempts stay in the record because they are
    evidence in their own right: they show how often this agent's strategy is
    "look it up".
    """
    attempted: dict[str, int] = {}
    failed: dict[str, int] = {}
    succeeded: dict[str, int] = {}
    instances = []
    instances_succeeded = []
    residual: dict[str, list] = {}
    #: FINDINGS.md #6 -- build tools that fetch as a side effect (`go:
    #: downloading`, `pip install`). Reported separately from `residual`
    #: because an ambiguous `go build` must not void a run's score; see
    #: airgap._TOOLCHAIN_CMD_HINTS.
    toolchain_fetch: dict[str, list] = {}
    scanned = 0
    for r in rows:
        sig = r.get("osa_signals") or {}
        names = sig.get("tool_names") or {}
        fails = sig.get("tool_failure_names") or {}
        hit = {k: v for k, v in names.items() if k in NETWORK_TOOLS}
        if hit:
            instances.append(r["instance_id"])
            got_through = False
            for k, v in hit.items():
                attempted[k] = attempted.get(k, 0) + v
                f = min(int(fails.get(k, 0)), v)
                failed[k] = failed.get(k, 0) + f
                if v - f > 0:
                    succeeded[k] = succeeded.get(k, 0) + (v - f)
                    got_through = True
            if got_through:
                instances_succeeded.append(r["instance_id"])
        # The surface the deny rules cannot cover, scanned from the recorded
        # SSE stream. Absence of this key means nobody looked, which the
        # reporter treats as unproven rather than clean.
        log_path = r.get("event_log")
        if log_path:
            scanned += 1
            explicit, toolchain = airgap.split_egress_hits(
                airgap.residual_egress_evidence(Path(log_path))
            )
            if explicit:
                residual[r["instance_id"]] = explicit
            if toolchain:
                toolchain_fetch[r["instance_id"]] = toolchain

    enforced = bool(attestation and attestation.get("enforced"))
    return {
        "tools_watched": list(NETWORK_TOOLS),
        "available_to_agent": not enforced,
        "enforcement": _ENFORCEMENT_PROBED if enforced else _ENFORCEMENT_NONE,
        "enforcement_probed": enforced,
        "probe_attestation": attestation or None,
        # `calls_by_tool` is retained under its old name and old meaning
        # (ATTEMPTS) so an existing results.json keeps reading the same.
        "calls_by_tool": attempted,
        "attempted_by_tool": attempted,
        "refused_by_tool": failed,
        "succeeded_by_tool": succeeded,
        "instances_that_used_one": sorted(instances),
        "instances_that_got_through": sorted(instances_succeeded),
        "residual_shell_egress": {
            "scanned": scanned,
            "of_instances": len(rows),
            "instances": residual,
            "note": (
                "Markers (urllib/requests.get/urlopen/github.com URLs) inside "
                "shell_execute or repl commands. A hit is a pointer at a "
                "transcript for a human to read, not proof of a lookup. An "
                "empty map means the recorded streams contain no evidence, "
                "which is weaker than 'no egress happened'."
            ),
        },
        # FINDINGS.md #6: the egress scan used to grep for urllib/requests and
        # therefore missed `go: downloading` and `pip install`, which are real
        # outbound network from shell_execute. Both the commands and the tools'
        # own download lines are scanned now. Kept OUT of
        # `residual_shell_egress` on purpose: a hit there sets the gate's
        # `breached` verdict, and `go build` on a warm module cache does not
        # touch the network. This block is for a human to read.
        "toolchain_fetch": {
            "scanned": scanned,
            "instances": toolchain_fetch,
            "note": (
                "Build/package tools that CAN fetch (evidence=command) or that "
                "printed a download line (evidence=output). Output evidence is "
                "the strong kind. This does not set `clean` to false -- it is a "
                "pointer at a transcript, and the airgap is a filter on this "
                "surface rather than a boundary (FINDINGS.md #7)."
            ),
        },
        # "clean" means nothing GOT THROUGH. Refused attempts are recorded
        # above and do not make a run dirty -- they cannot carry information.
        "clean": not succeeded and not residual,
    }

#: 2 adds: per-instance failure_bucket/failure_fault/failure_evidence and the
#: osa_signals block; multi-attempt (pass@k) aggregates; the sampling
#: provenance block. `failure_reason` is retained unchanged for compatibility.
SCHEMA_VERSION = 2


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
        raw = inf.get("raw") or {}
        verdict = diagnose.classify(
            outcome=outcome,
            inference=inf,
            detail=detail,
            patch_did_not_apply=(
                outcome == "eval_error"
                and diagnose.patch_apply_failed(report_dir, run_id, model, iid)
            ),
        )
        rows.append(
            {
                "instance_id": iid,
                "resolved": outcome == "resolved",
                "outcome": outcome,
                "failure_reason": _failure_reason(outcome, inf, detail),
                # The bucket every failure lands in, and whose fault it was.
                # See diagnose.py: `harness` means OSA got in the model's way
                # and is a bug report, not a score.
                "failure_bucket": verdict["bucket"],
                "failure_fault": verdict["fault"],
                "failure_evidence": verdict["evidence"],
                "osa_signals": raw.get("osa_signals") or {},
                # Carried for failures only -- it is the primary diagnostic
                # artefact, and carrying it for passes would double the file
                # size to say "this one worked".
                "model_patch": "" if outcome == "resolved" else inf.get("patch", ""),
                "transcript_dir": raw.get("transcript_dir"),
                "event_log": raw.get("event_log"),
                "dropped_test_paths": raw.get("dropped_test_paths") or [],
                "wall_clock_s": round(inf.get("wall_clock_s") or 0.0, 2),
                "tokens_in": inf.get("tokens_in"),
                "tokens_out": inf.get("tokens_out"),
                "tokens_cache_read": inf.get("tokens_cache_read"),
                "tokens_cache_write": inf.get("tokens_cache_write"),
                "cost_usd": inf.get("cost_usd"),
                # None on pre-tree-cost runs (parent-only figure, completeness
                # unknowable); False means the figure is a LOWER BOUND.
                "cost_complete": inf.get("cost_complete"),
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
    # A total is only "complete" if every row that contributed to it was. One
    # incomplete tree makes the whole total a lower bound; a single pre-field
    # row makes the whole total parent-only.
    flags = [r.get("cost_complete") for r in rows if r.get("cost_usd") is not None]
    if any(f is None for f in flags) or not flags:
        cost_complete = None
    else:
        cost_complete = all(flags)

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
        # $/task, not $/resolved-task: the published headline the competitive
        # field quotes (goose's cross-harness table, docs/research/
        # what-harnesses-benchmark.md §5) is per ATTEMPTED task.
        "cost_usd_per_task": round(cost / n, 4) if n and cost is not None else None,
        # True | False (lower bound: a subagent's spend was unreadable) | None
        # (recorded before tree costs existed -- parent-only, subagent spend
        # missing entirely). Never render None as True.
        "cost_complete": cost_complete,
        "cost_usd_per_resolved": (
            round(cost / len(resolved), 4) if resolved and cost is not None else None
        ),
        "tool_calls_total": _total(r["tool_calls"] for r in rows),
        "tool_calls_mean": _mean(r["tool_calls"] for r in rows),
        "turns_mean": _mean(r["turns"] for r in rows),
        "failure_taxonomy": dict(sorted(taxonomy.items(), key=lambda kv: -kv[1])),
        # The actionable half of the report: every failure in a named bucket,
        # split by whether OSA or the model was responsible.
        "diagnosis": diagnose.summarize(rows),
        "probable_osa_bugs": diagnose.repeated_harness_failures(rows),
        # Whether the agent could have looked the answer up, and whether it did.
        "network_tool_use": network_tool_use(rows, config.get("airgap")),
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


def merge_attempts(attempt_docs: list[dict], config: dict) -> dict:
    """Fold k independent attempts at the same instances into one document.

    Single-sample SWE-bench scores are noisy enough that the industry reports
    both pass@1 and pass@k, and the gap between them says something real: a
    large gap means the agent *can* solve the task but is unreliable, which is
    a different problem from not being able to solve it at all.

    Definitions used here, stated because they are not universal:

      pass@1  -- mean resolve rate across the k attempts (not "attempt 1"),
                 which is the unbiased estimator of a single sample's success.
      pass@k  -- fraction of instances resolved by *at least one* attempt.
      pass^k  -- fraction resolved by *every* attempt. The reliability figure;
                 almost nobody reports it, and it is the one that matters if
                 you intend to trust the agent unattended.
    """
    if len(attempt_docs) == 1:
        doc = attempt_docs[0]
        doc["aggregate"]["attempts"] = 1
        doc["aggregate"]["pass_at_1"] = doc["aggregate"]["resolve_rate"]
        doc["aggregate"]["pass_at_k"] = doc["aggregate"]["resolve_rate"]
        doc["aggregate"]["pass_hat_k"] = doc["aggregate"]["resolve_rate"]
        return doc

    k = len(attempt_docs)
    base = attempt_docs[0]
    by_id: dict[str, list[dict]] = {}
    for doc in attempt_docs:
        for r in doc["instances"]:
            by_id.setdefault(r["instance_id"], []).append(r)

    merged_rows = []
    for iid, attempts in sorted(by_id.items()):
        oks = [a["resolved"] for a in attempts]
        # Report the FIRST failing attempt as the representative row: a passing
        # attempt has nothing to diagnose, and the point of this file is the
        # failures.
        rep = next((a for a in attempts if not a["resolved"]), attempts[0])
        merged_rows.append(
            rep
            | {
                "attempts_n": len(attempts),
                "attempts_resolved": sum(oks),
                "resolved_any": any(oks),
                "resolved_all": all(oks),
                # `resolved` keeps its per-attempt meaning for the
                # representative row; use resolved_any/_all for pass@k.
                "per_attempt": [
                    {
                        "attempt": i + 1,
                        "resolved": a["resolved"],
                        "bucket": a.get("failure_bucket"),
                        "fault": a.get("failure_fault"),
                        "wall_clock_s": a.get("wall_clock_s"),
                    }
                    for i, a in enumerate(attempts)
                ],
            }
        )

    n = len(merged_rows)
    per_attempt_rates = [d["aggregate"]["resolve_rate"] or 0.0 for d in attempt_docs]
    agg = dict(base["aggregate"])
    agg.update(
        {
            "attempts": k,
            "instances_attempted": n,
            # DELIBERATELY None for k>1. Reporting `resolved_any` here would be
            # pass@k wearing pass@1's name, which is the single most common way
            # a multi-sample SWE-bench number gets overstated. There is no
            # honest scalar "resolved count" across k attempts, so the field is
            # withheld and the reader is forced onto a labelled metric.
            "instances_resolved": None,
            "instances_resolved_any": sum(1 for r in merged_rows if r["resolved_any"]),
            "instances_resolved_all": sum(1 for r in merged_rows if r["resolved_all"]),
            "instances_resolved_per_attempt": [
                d["aggregate"]["instances_resolved"] for d in attempt_docs
            ],
            # The primary metric. pass@k is reported alongside, never instead.
            "pass_at_1": round(sum(per_attempt_rates) / k, 4),
            "pass_at_k": round(
                sum(1 for r in merged_rows if r["resolved_any"]) / n, 4
            )
            if n
            else None,
            "pass_hat_k": round(
                sum(1 for r in merged_rows if r["resolved_all"]) / n, 4
            )
            if n
            else None,
            "resolve_rate_per_attempt": [round(x, 4) for x in per_attempt_rates],
            # `resolve_rate` stays pass@1 so a k=1 and a k>1 run can be
            # compared without reading the schema.
            "resolve_rate": round(sum(per_attempt_rates) / k, 4),
            # Cost/time are the SUM over all attempts -- k attempts really did
            # cost k times as much, and pretending otherwise would make pass@k
            # look free.
            "wall_clock_total_s": round(
                sum(d["aggregate"]["wall_clock_total_s"] for d in attempt_docs), 2
            ),
            "tokens_in_total": _total(
                d["aggregate"]["tokens_in_total"] for d in attempt_docs
            ),
            "tokens_out_total": _total(
                d["aggregate"]["tokens_out_total"] for d in attempt_docs
            ),
            "diagnosis": diagnose.summarize(merged_rows),
            "probable_osa_bugs": diagnose.repeated_harness_failures(merged_rows),
            "network_tool_use": network_tool_use(merged_rows, config.get("airgap")),
        }
    )
    ti, to = agg["tokens_in_total"], agg["tokens_out_total"]
    agg["tokens_total"] = (ti + to) if (ti is not None and to is not None) else None
    # Efficiency is quoted per *resolved-at-all* task, and says so, because the
    # denominator has to be a real count of tasks that produced a fix.
    nres = agg["instances_resolved_any"]
    agg["tokens_per_resolved"] = (
        round(agg["tokens_total"] / nres, 1) if nres and agg["tokens_total"] else None
    )

    return {
        "schema_version": SCHEMA_VERSION,
        "config": config,
        "aggregate": agg,
        "harness_report": base.get("harness_report", {}),
        "instances": merged_rows,
        "per_attempt_aggregates": [
            {"attempt": i + 1, **d["aggregate"]} for i, d in enumerate(attempt_docs)
        ],
    }



def _cost_caveat(a: dict) -> str:
    """Suffix that stops an incomplete cost total reading as an exact one."""
    c = a.get("cost_complete")
    if c is True:
        return ""
    if c is False:
        return " **(lower bound — a subagent's spend could not be read)**"
    return " **(parent session only — subagent spend NOT included)**"


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
    ]
    if a.get("attempts", 1) > 1:
        lines += [
            f"**pass@1 = {(a['pass_at_1'] or 0) * 100:.1f}%** "
            f"(mean of {a['attempts']} independent attempts at "
            f"{a['instances_attempted']} instances; per attempt: "
            f"{', '.join(f'{x * 100:.1f}%' for x in a['resolve_rate_per_attempt'])})",
            "",
            "pass@1 is the primary metric and the only one comparable to a "
            "published SWE-bench number. The two below are reported because "
            "single samples are noisy, and must never be quoted as the score.",
            "",
            f"- pass@{a['attempts']} (resolved by **at least one** attempt): "
            f"{(a['pass_at_k'] or 0) * 100:.1f}% "
            f"({a['instances_resolved_any']}/{a['instances_attempted']})",
            f"- pass^{a['attempts']} (resolved by **every** attempt — the "
            f"reliability figure): {(a['pass_hat_k'] or 0) * 100:.1f}% "
            f"({a['instances_resolved_all']}/{a['instances_attempted']})",
            "",
        ]
    else:
        lines += [
            f"**{a['instances_resolved']} / {a['instances_attempted']} resolved "
            f"({(a['resolve_rate'] or 0) * 100:.1f}%)**  — pass@1, single attempt.",
            "",
        ]
    if not a["is_full_dataset_run"]:
        samp = cfg.get("sampling") or {}
        lines += [
            "> This is a **subset** run. It is a pipeline and regression signal, "
            "not a SWE-bench Verified score, and must not be quoted as one. "
            "Subsets of a few dozen instances have a confidence interval wide "
            "enough to swallow most of the leaderboard.",
            "",
        ]
        if samp:
            lines += [
                f"> **Sampling**: `{samp.get('method')}`, seed `{samp.get('seed')}`, "
                f"{samp.get('n_selected')} of {samp.get('population')} instances"
                + (
                    f", deliberately weighted toward the hard end "
                    f"(difficulty/patch-size/PASS_TO_PASS-count). "
                    f"**This subset is harder than the full dataset, so the rate "
                    f"here should read LOWER than a full-dataset score, not higher.**"
                    if samp.get("hard_weighted")
                    else ""
                ),
                "",
            ]
    if cfg.get("f2p_hint"):
        lines += [
            "> **The agent was given the FAIL_TO_PASS test ids** via "
            "`run_tests.sh`. That is an advantage leaderboard agents do not "
            "have, it violates the official checklist, and it inflates this "
            "number. Re-run without `--f2p-hint` before quoting anything.",
            "",
        ]

    net = a.get("network_tool_use") or {}
    if net:
        resid = net.get("residual_shell_egress") or {}
        if net.get("enforcement_probed") and net.get("clean"):
            lines += [
                "> **Web lookup was PREVENTED, and the prevention was probed.** "
                f"`{'`, `'.join(net['tools_watched'])}` are denied by a "
                "permissions rule in the backend's `OSA_SETTINGS` layer, which "
                "`ToolExecutor` consults before any permission-mode "
                "short-circuit — so `overdrive` does not bypass it. Before this "
                "run started, a live differential probe called a denied tool "
                "(refused, 0 ms) and a non-denied control tool (succeeded) in "
                "one session; the attestation is in `airgap-probe.json`. Zero "
                "network-tool calls were recorded across the run, and "
                f"{resid.get('scanned', 0)} of {resid.get('of_instances', 0)} "
                "event streams were scanned for shell-based egress with no "
                "hits. **Residual surface**: `shell_execute` stays available "
                "and is denied only by command prefix, so an egress path built "
                "inside a Python one-liner is detected after the fact rather "
                "than prevented.",
                "",
            ]
        elif net.get("enforcement_probed") and not net.get("clean"):
            lines += [
                "> **The airgap was verified and network access happened "
                "anyway — do not use this run.** "
                f"Calls: `{net['calls_by_tool']}`; shell egress markers: "
                f"`{list((resid.get('instances') or {}).keys())[:10]}`. Either "
                "enforcement regressed mid-run or this harness is "
                "mis-recording. Establish which before quoting anything.",
                "",
            ]
        elif net.get("clean"):
            lines += [
                "> **Web access**: the agent *could* reach the internet "
                f"(`{'`, `'.join(net['tools_watched'])}` were all available — "
                "this run was NOT started with the `--airgap` deny list). It "
                "**did not call any of them** on any instance, so no answer "
                "was looked up in this run. That is an observation, not a "
                "guarantee: `shell_execute` can also reach the network. Re-run "
                "with `--airgap` to make it a guarantee.",
                "",
            ]
        else:
            lines += [
                "> **WEB ACCESS WAS USED — this run is not a valid measurement.** "
                f"Network tools were called: `{net['calls_by_tool']}` on "
                f"instances {', '.join('`' + i + '`' for i in net['instances_that_used_one'][:10])}. "
                "The fix for these issues is published online, so any instance "
                "here may have been looked up rather than solved.",
                "",
            ]

    diag = a.get("diagnosis") or {}
    if diag.get("failures_total"):
        by = diag.get("by_fault", {})
        share = diag.get("harness_fault_share")
        lines += [
            "## Whose fault were the failures",
            "",
            "The point of this run is the failures, and they are only "
            "actionable once OSA's own faults are separated from the model's.",
            "",
            "| fault | count | meaning |",
            "|---|---|---|",
            f"| **harness (OSA)** | {by.get('harness', 0)} | OSA got in the "
            "model's way — these are bugs to fix |",
            f"| model | {by.get('model', 0)} | OSA worked; the patch was wrong |",
            f"| bench | {by.get('bench', 0)} | this harness or Docker misbehaved |",
            f"| provider | {by.get('provider', 0)} | the model provider failed "
            "the turn — neither OSA's code nor the model's answer |",
            f"| unattributed | {by.get('unattributed', 0)} | the turn died on an "
            "error carrying no `owner` — deliberately not charged to anyone |",
            "",
            f"**{(share or 0) * 100:.0f}% of failures were OSA's fault**, not the model's."
            if share is not None
            else "",
            "",
        ]
        bugs = a.get("probable_osa_bugs") or []
        if bugs:
            lines += [
                "### Probable OSA bugs (same harness failure seen more than once)",
                "",
            ]
            for b in bugs:
                lines.append(
                    f"- **`{b['bucket']}`** × {b['count']} — "
                    + ", ".join(f"`{i}`" for i in b["instances"][:8])
                )
            lines.append("")

        lines += ["### Every failure, bucketed", "", "| bucket | fault | count |", "|---|---|---|"]
        fault_of = {}
        for r in results["instances"]:
            if r.get("failure_bucket"):
                fault_of[r["failure_bucket"]] = r.get("failure_fault")
        for k, v in diag.get("buckets", {}).items():
            lines.append(f"| `{k}` | {fault_of.get(k, '?')} | {v} |")
        lines.append("")
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
        f"| cost total | {_fmt(a['cost_usd_total'], ' USD')}{_cost_caveat(a)} |",
        f"| **cost / task** | {_fmt(a.get('cost_usd_per_task'), ' USD')}"
        f"{_cost_caveat(a)} |",
        f"| cost / resolved task | {_fmt(a['cost_usd_per_resolved'], ' USD')}"
        f"{_cost_caveat(a)} |",
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
                ok="yes" if r.get("resolved_any", r["resolved"]) else "no",
                reason=r.get("failure_bucket") or r["failure_reason"] or "-",
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
