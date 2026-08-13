"""Agent-agnostic failure attribution for a Harbor trial.

WHY THIS FILE EXISTS SEPARATELY FROM bench/terminalbench/report.py
------------------------------------------------------------------
`bench/terminalbench/report.py` attributes faults by reading OSA's own
telemetry: `metadata.osa_status`, `osa_saw_done`, `osa_tool_calls`. That is the
right instrument when OSA is the only thing being measured, and the wrong one
the moment a competitor is in the run -- a Codex trial has no `osa_status`, so
that reporter would classify every single Codex trial as
`no_telemetry_written`, i.e. a harness fault, i.e. a 100% harness-fault rate
for every arm that is not OSA.

An attribution rule that flatters OSA by construction is worse than no
attribution at all, so this module derives the split from fields **every**
Harbor agent produces:

  * `exception_info`           -- Harbor caught something
  * `agent_execution` timings  -- did the agent phase even start
  * `agent_setup` timings      -- did install succeed
  * `agent_result.*_tokens`    -- did the agent ever reach the model
  * `verifier_result.rewards`  -- did the grader run

Per-agent telemetry is used only to *refine* a classification that the generic
rules already made, never to make one that the generic rules could not. That
asymmetry is the whole point: OSA's richer instrumentation must not be able to
move OSA's own number.

THE FOUR OWNERS
---------------
resolved   the verifier scored 1.0
harness    the agent (or its adapter) broke: install failed, it never booted,
           it never reached the model, it crashed, or the grader never ran.
           The episode never had a fair chance. Excluded from the model
           denominator, reported on its own.
ambiguous  a timeout. From outside, "this harness burns its budget on
           overhead" and "this model is slow" are the same observation. Never
           silently assigned to either owner.
model      the agent ran, reached the model, finished, and the answer was
           wrong. This is the only bucket that is about capability.

`zero_action` is a sub-case of `model` that is worth separating: the agent
finished cleanly having never run a command. Terminal-Bench grades container
state, so an answer-shaped non-attempt scores 0 no matter how good the prose
was. It is a *harness-shaped* failure with a *model-shaped* cause, and pooling
it either way loses the finding.
"""

from __future__ import annotations

import json
import re
from datetime import datetime
from pathlib import Path

SCHEMA_VERSION = 1

#: Harbor exception types that mean the agent/adapter broke rather than the
#: model being wrong. Matched on the type NAME, since Harbor reports the class
#: name as a string.
HARNESS_EXCEPTIONS = {
    "AgentSetupTimeoutError",       # install did not finish
    "EnvironmentStartTimeoutError",  # container never came up
    "NonZeroAgentExitCodeError",    # the CLI itself exited non-zero
    "AgentInstallError",
    "ImportError",
    "ModuleNotFoundError",
}

#: Timeouts. Ambiguous by construction; see the module docstring.
AMBIGUOUS_EXCEPTIONS = {
    "AgentTimeoutError",
    "TimeoutError",
}

#: The verifier itself failing is a harness fault, but it is OUR harness (the
#: task's), not the agent's. Kept in its own bucket so it can never be read as
#: "the agent broke".
GRADER_EXCEPTIONS = {
    "VerifierTimeoutError",
}

#: The SHARED provider refusing to serve. This is neither the harness's fault
#: nor the model's -- it is the experiment's own infrastructure failing, and it
#: hits every arm equally. It gets its own owner because both alternatives are
#: lies: calling it `harness` blames each agent for our exhausted quota (and
#: would make every arm look broken), and calling it `model` scores a
#: capability failure for a call that never happened.
#:
#: Found the hard way: mid-build, the Ollama cloud account returned
#: `HTTP 429 ... reached your session usage limit` for every cloud model. The
#: 0-token rule below would have filed that as `agent_never_reached_model`
#: against every single arm.
#: Every alternative must be specific enough that it cannot fire on ordinary
#: log noise. A bare `\b429\b` was the first draft and is WRONG: "wrote 429
#: bytes" would void an otherwise valid run, and a detector that voids good
#: runs gets switched off, which is worse than not having one. So 429 and 503
#: only count when they appear next to a status/error word.
PROVIDER_OUTAGE = re.compile(
    r"(reached your session usage limit"
    r"|(status(_?code)?|http|returned|code)\W{0,4}(429|503)\b"
    r"|\b(429|503)\W{0,4}(too many requests|service unavailable)"
    r"|rate.?limit(ed)?\s+(exceeded|reached)"
    r"|quota (exceeded|exhausted)"
    r"|insufficient_quota"
    r"|\bwas retired at\b"
    r"|model .{0,60}\bdoes not exist\b)",
    re.I,
)

#: How many lines of an arm's logs to scan for an outage signature. The
#: signature always appears near the provider call, so a bounded scan is enough
#: and keeps a 100 MB serve log out of memory.
_OUTAGE_SCAN_BYTES = 8 * 1024 * 1024

#: Harbor's own error classifier already recognises provider-side refusals and
#: raises a typed exception for them. Trusting that is strictly better than
#: re-deriving it from logs: it works even when an arm writes no log at all.
#: Observed live -- mini-swe-agent's 429 surfaced as `ApiRateLimitError`.
#: (Names from harbor/agents/installed/base.py ERROR_PATTERNS.)
PROVIDER_EXCEPTIONS = {
    "ApiRateLimitError",
    "ApiUsageLimitError",
    "ApiOverloadedError",
    "ApiInternalServerError",
    "ApiProviderResourceNotFoundError",
    "ModelNotFoundError",
}

#: The provider dropped the connection or the model refused. Real events, but
#: NOT clean outages -- an arm that cannot survive a mid-stream disconnect is
#: showing something about itself. Left with the harness so a fragile arm is
#: not excused, and listed here so the choice is visible rather than implicit.
_NOT_PROVIDER_OUTAGE = {
    "ApiConnectionClosedError",
    "ApiResponseStalledError",
    "ContextWindowExceededError",
    "OutputTokenExceededError",
}

HARNESS_REASONS = {
    "agent_install_failed",
    "agent_never_started",
    "agent_never_reached_model",
    "agent_exited_nonzero",
    "no_verifier_reward",
    "harness_exception",
}

GRADER_REASONS = {"verifier_timeout", "verifier_error"}


# --------------------------------------------------------------------------
# self-inflicted markers, per arm
# --------------------------------------------------------------------------
# Scraped from whatever log the agent leaves in the trial's agent/ directory.
# A marker is a SIGNAL, NOT A VERDICT. It never changes fault_owner; it exists
# so that a defect which recurs across tasks becomes a bug report instead of a
# footnote. The OSA table is deliberately the same one bench/terminalbench uses
# so the two harnesses cannot disagree about OSA.
#
# Each entry: (marker_name, compiled regex). Keys are namespaced by arm so a
# cross-arm total is never accidentally summed over different meanings.
_MARKERS: dict[str, list[tuple[str, re.Pattern]]] = {
    "osa": [
        ("essential_context_dropped",
         re.compile(r"ESSENTIAL context block (dropped|truncated)")),
        ("stall_detector", re.compile(r"\[doom\] Stall detected")),
        ("circuit_breaker_block", re.compile(r"CIRCUIT-BREAKER blocked")),
        ("compaction_ran", re.compile(r"\[Context\].*compact", re.I)),
        ("tool_result_truncated", re.compile(r"tool result truncated", re.I)),
    ],
    "codex": [
        ("context_compaction", re.compile(r"auto-compact|compacting context", re.I)),
        ("stream_error", re.compile(r"stream (error|disconnected)", re.I)),
        ("retrying", re.compile(r"\bretrying\b", re.I)),
    ],
    "opencode": [
        ("summarize_session", re.compile(r"summariz\w+ session", re.I)),
        ("provider_error", re.compile(r"ProviderError|AI_APICallError")),
    ],
    "goose": [
        ("context_truncated", re.compile(r"context (limit|truncat)", re.I)),
        ("tool_error", re.compile(r"tool.*(failed|error)", re.I)),
    ],
    "aider": [
        ("context_exhausted", re.compile(r"context window|exceeds", re.I)),
        ("edit_apply_failed", re.compile(r"SearchReplaceNoExactMatch|failed to apply", re.I)),
    ],
}

#: Lines that match a marker but are not the thing the marker means -- a banner
#: that mentions compaction, a help string that lists the word "error".
_BENIGN = re.compile(
    r"(usage:|--help|^\s*#|Available (commands|flags)|"
    r"error_catalog|no such option)",
    re.I,
)

#: Log files to scan, in order, per arm. First existing one wins; all are
#: scanned when several exist.
_LOG_GLOBS = ["*.log", "*.txt", "*.jsonl"]

#: Never read a log bigger than this into memory. OSA's serve log on a
#: long-horizon task has been observed above 100 MB.
_MAX_LOG_BYTES = 64 * 1024 * 1024


def _seconds(a: str | None, b: str | None) -> float | None:
    if not a or not b:
        return None
    try:
        return round((datetime.fromisoformat(b) - datetime.fromisoformat(a)).total_seconds(), 2)
    except (ValueError, TypeError):
        return None


def scrape_markers(trial_dir: Path, arm_family: str) -> tuple[dict, dict]:
    """Count this arm's known self-inflicted markers in its own logs."""
    table = _MARKERS.get(arm_family)
    if not table:
        return {}, {}
    agent_dir = trial_dir / "agent"
    if not agent_dir.is_dir():
        return {}, {}

    counts: dict[str, int] = {}
    samples: dict[str, str] = {}
    seen: set[Path] = set()
    for glob in _LOG_GLOBS:
        for path in sorted(agent_dir.rglob(glob)):
            if path in seen or not path.is_file():
                continue
            seen.add(path)
            try:
                if path.stat().st_size > _MAX_LOG_BYTES:
                    continue
                text = path.read_text("utf-8", "replace")
            except OSError:
                continue
            for line in text.splitlines():
                if _BENIGN.search(line):
                    continue
                for key, rx in table:
                    if rx.search(line):
                        counts[key] = counts.get(key, 0) + 1
                        samples.setdefault(key, line.strip()[:300])
    return counts, samples


def detect_provider_outage(trial_dir: Path) -> str | None:
    """Return the offending log line if the SHARED provider refused to serve.

    Scanned from whatever logs the arm left behind, because no arm reports
    "the provider 429'd me" in a structured field -- OSA, for one, reported
    `status: ok` on a turn where every provider call failed.
    """
    agent_dir = trial_dir / "agent"
    if not agent_dir.is_dir():
        return None
    for glob in _LOG_GLOBS:
        for path in sorted(agent_dir.rglob(glob)):
            if not path.is_file():
                continue
            try:
                if path.stat().st_size > _OUTAGE_SCAN_BYTES:
                    continue
                text = path.read_text("utf-8", "replace")
            except OSError:
                continue
            m = PROVIDER_OUTAGE.search(text)
            if m:
                for line in text.splitlines():
                    if PROVIDER_OUTAGE.search(line):
                        return line.strip()[:300]
    return None


def classify(result: dict, trial_dir: Path) -> tuple[str, str, str]:
    """Return (failure_reason, fault_owner, evidence).

    Ordering is most-specific-first and deliberately conservative: anything
    that could be the agent's own breakage is called harness, because the cost
    of mislabelling a broken arm as "the model got it wrong" is a comparison
    that reads as a capability result and is not one.
    """
    rewards = (result.get("verifier_result") or {}).get("rewards") or {}
    reward = rewards.get("reward")
    if reward is not None and reward >= 1.0:
        return "", "resolved", "verifier reward 1.0"

    exc = result.get("exception_info") or {}
    exc_type = exc.get("exception_type") or exc.get("type") or ""
    exc_msg = (exc.get("exception_message") or "")[:300]

    setup = result.get("agent_setup") or {}
    execution = result.get("agent_execution") or {}
    agent_result = result.get("agent_result") or {}

    setup_s = _seconds(setup.get("started_at"), setup.get("finished_at"))
    exec_s = _seconds(execution.get("started_at"), execution.get("finished_at"))

    # -- 0. the shared provider refused to serve ------------------------
    # Checked FIRST, ahead of every other rule. A quota-exhausted provider
    # produces zero tokens, a crashed CLI, or a timeout depending on the arm,
    # so every downstream rule would misfile it -- and misfile it as the ARM's
    # fault, which is the one direction that must never be guessed.
    if exc_type in PROVIDER_EXCEPTIONS:
        return ("provider_outage", "provider",
                f"harbor classified this as {exc_type}: {exc_msg}")
    outage = detect_provider_outage(trial_dir)
    if outage:
        return "provider_outage", "provider", outage

    # -- 1. install never completed ------------------------------------
    if setup.get("started_at") and not setup.get("finished_at"):
        return "agent_install_failed", "harness", f"agent_setup never finished ({exc_type or 'no exception'})"
    if exc_type == "AgentSetupTimeoutError":
        return "agent_install_failed", "harness", f"{exc_type}: {exc_msg}"

    # -- 2. the agent phase never ran ----------------------------------
    if not execution.get("started_at"):
        return "agent_never_started", "harness", f"no agent_execution block ({exc_type or 'no exception'})"

    # -- 3. grader problems are ours, not the agent's ------------------
    if exc_type in GRADER_EXCEPTIONS:
        return "verifier_timeout", "grader", f"{exc_type}: {exc_msg}"

    # -- 4. timeouts stay ambiguous ------------------------------------
    if exc_type in AMBIGUOUS_EXCEPTIONS:
        return "agent_timeout", "ambiguous", f"{exc_type} after {exec_s}s"

    # -- 5. the agent crashed ------------------------------------------
    if exc_type in HARNESS_EXCEPTIONS:
        return "agent_exited_nonzero", "harness", f"{exc_type}: {exc_msg}"
    if exc_type:
        return "harness_exception", "harness", f"{exc_type}: {exc_msg}"

    # -- 6. it "ran" but never reached the model -----------------------
    # Zero tokens both ways, on an arm that reports tokens at all, means the
    # provider call never succeeded: wrong base URL, rejected key, unknown
    # model. That is configuration, i.e. this harness's fault, and calling it
    # a model failure would silently credit OSA for a competitor we misconfigured.
    tin = agent_result.get("n_input_tokens")
    tout = agent_result.get("n_output_tokens")
    if tin is not None and tout is not None and tin == 0 and tout == 0:
        return ("agent_never_reached_model", "harness",
                f"0 input and 0 output tokens after {exec_s}s of agent execution")

    # -- 7. the grader never produced a number -------------------------
    if reward is None:
        return "no_verifier_reward", "harness", "verifier_result.rewards.reward absent"

    # -- 8. genuine wrong answers --------------------------------------
    # Refinement only, and only downward in specificity -- the owner stays
    # `model` either way, so per-agent telemetry cannot move an arm's score.
    meta = agent_result.get("metadata") or {}
    tool_calls = meta.get("osa_tool_calls")
    if tool_calls == 0:
        return "completed_without_acting", "model", "agent finished having made 0 tool calls"
    return "completed_but_wrong", "model", f"verifier reward {reward} after {exec_s}s"


def collect_arm(job_dir: Path, arm_family: str) -> list[dict]:
    """Read every trial under one arm's Harbor job directory."""
    rows: list[dict] = []
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

        reason, owner, evidence = classify(r, trial_dir)
        markers, marker_samples = scrape_markers(trial_dir, arm_family)

        task = r.get("task_name") or ""
        rows.append({
            # Harbor prefixes the dataset: "terminal-bench/regex-log". The bare
            # name is the join key across arms.
            "task": task.rsplit("/", 1)[-1],
            "task_name": task,
            "trial_name": r.get("trial_name"),
            "task_checksum": r.get("task_checksum"),
            "reward": reward,
            "resolved": bool(reward is not None and reward >= 1.0),
            "failure_reason": reason,
            "fault_owner": owner,
            "fault_evidence": evidence,
            "wall_clock_s": _seconds(r.get("started_at"), r.get("finished_at")),
            "agent_setup_s": _seconds((r.get("agent_setup") or {}).get("started_at"),
                                      (r.get("agent_setup") or {}).get("finished_at")),
            "agent_exec_s": _seconds((r.get("agent_execution") or {}).get("started_at"),
                                     (r.get("agent_execution") or {}).get("finished_at")),
            "tokens_in": agent_result.get("n_input_tokens"),
            "tokens_out": agent_result.get("n_output_tokens"),
            "tokens_cache": agent_result.get("n_cache_tokens"),
            "cost_usd": agent_result.get("cost_usd"),
            "agent_version": (r.get("agent_info") or {}).get("version"),
            "exception": (r.get("exception_info") or {}).get("exception_type"),
            "self_inflicted": markers,
            "self_inflicted_samples": marker_samples,
            # OSA-only extras, recorded but never used for attribution.
            "agent_metadata": {k: v for k, v in meta.items()
                               if k in ("osa_turns", "osa_tool_calls", "osa_status",
                                        "osa_boot_s", "osa_saw_done")},
            "trial_dir": str(trial_dir),
        })
    rows.sort(key=lambda r: r["task"])
    return rows
