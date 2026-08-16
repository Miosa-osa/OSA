#!/usr/bin/env python3
"""Per-fix evidence scraper for the 1.0.99 verification run.

`report.py` answers "did the number move". This answers the different and
prior question: **did the specific mechanisms we shipped actually fire in this
run**, or did the number move for some other reason.

Every fix below has a distinct, greppable signature that did not exist in the
baseline artefact. A fix whose signature is absent is not "verified"; it is
`UNOBSERVED`, and the three ways that can happen are kept apart because they
have different remedies:

* ``FIRED``      — the mechanism ran. Count and samples are shown.
* ``NOT NEEDED`` — the mechanism is conditional and its precondition never
  occurred in these eight tasks (e.g. no provider cut-off happened, so the
  truncation recovery had nothing to recover). Says nothing about the fix.
* ``UNOBSERVED`` — the precondition plausibly occurred and the signature is
  still absent. That is a finding and is reported as one.

Reads only run artefacts: `agent/osa-events.jsonl` (every SSE frame) and
`agent/osa-serve.log` (OSA's own log inside the container).
"""

from __future__ import annotations

import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

# --------------------------------------------------------------------- signatures

#: `file_grep` fell back to the pure-Elixir walk because ripgrep is absent.
#: Logged ONCE PER SESSION by `Backend.warn_missing_once/1`, which did not exist
#: before `56a219b5`. Its presence proves the substitution is no longer silent;
#: the task containers install `python3 tar ca-certificates procps git` and NOT
#: ripgrep, so the fallback is the path under test here.
RX_GREP_FALLBACK = re.compile(r"\[file_grep\] ripgrep .* is not on this node's PATH", re.I)

#: The sentence appended to an EMPTY file_grep result naming the engine that
#: answered. Also new in `56a219b5`, and the direct antidote to the false
#: negative: the model can now tell "absent" from "not looked at".
RX_GREP_EMPTY_NOTE = re.compile(r"lower bound|pure-Elixir fallback|search backend", re.I)

#: The fallback hit its file cap. New in `9b592b07` — the old code took 500 of
#: 54,905 files and said nothing.
RX_GREP_CAPPED = re.compile(r"(cap|limit).{0,40}(file|scanned)|scanned \d+ of \d+ files", re.I)

#: A provider cut the generation short. `9b917049` + `Providers.StopReason`.
RX_TRUNCATED = re.compile(
    r"stop_reason.{0,20}(max_tokens|length)|truncated (generation|response|answer)"
    r"|output.token ceiling|:truncated",
    re.I,
)

#: The completion gate refused a claim resting on background work nobody looked
#: at. Clause 0, `66834e42`, un-starved by `21bdbc21`.
RX_UNOBSERVED_BG = re.compile(r"unobserved_background", re.I)

#: `bash_output` actually blocked on a background job — the tool that could not
#: wait, and now can. `21bdbc21`.
RX_BG_WAIT = re.compile(r"background_wait_started|wait_ms", re.I)

#: The announcement backstop nudged a turn that ended on "I'll do X next".
RX_ANNOUNCE = re.compile(r"announcement_continue", re.I)

#: `file_edit` diff hygiene — `250e2430`.
RX_EDIT_DIFF = re.compile(r"diff pointed|region the edit never touched", re.I)

#: Parallel edits to one file — `05b22c57`.
RX_PARALLEL_EDIT = re.compile(r"concurrent edit|two edits to one file|edit serial", re.I)

LOG_SIGNATURES = {
    "file_grep_fallback_warned": RX_GREP_FALLBACK,
    "file_grep_capped": RX_GREP_CAPPED,
    "truncation_detected": RX_TRUNCATED,
    "unobserved_background_gate": RX_UNOBSERVED_BG,
    "background_wait": RX_BG_WAIT,
    "announcement_continue": RX_ANNOUNCE,
    "file_edit_diff_note": RX_EDIT_DIFF,
    "parallel_edit_serialised": RX_PARALLEL_EDIT,
}

#: SSE `system_event` names introduced by the fixes.
EVENT_NAMES = {
    "background_wait_started",
    "announcement_continue",
    "verification_gate_triggered",
}

#: What a `file_grep` result looks like when it found nothing. This is the
#: false-negative surface: the baseline emitted this after reading 0.9% of the
#: tree, so each one is cross-checked below against a later shell grep.
RX_NO_MATCH = re.compile(r"no matches|0 matches|nothing found", re.I)

#: The daemonised form `shell_execute/prompt.ex` now names for a service that is
#: itself the deliverable — the half of species 3 that is a prompt change and
#: can only be observed in what the model typed.
RX_DAEMONISED = re.compile(r"\bsetsid\b|\bnohup\b|\bdisown\b|systemctl start", re.I)

#: A background command that looks like a long-lived listener. Counted so
#: "servers are still being launched into the session group" stays visible
#: rather than being inferred from a task verdict.
RX_SERVERISH = re.compile(
    r"\b(serve|server|httpd|nginx|uvicorn|gunicorn|flask run|node .*server"
    r"|python3? -m http\.server|rails s|listen|daemon)\b",
    re.I,
)


#: Provider max-output ceiling, same constant and same justification as
#: `scripts/failure_species.py`. Duplicated rather than imported because that
#: module lives outside this package and this file is uploaded nowhere.
MAX_OUTPUT_TOKENS = 32768

#: ``(fix, signal keys, precondition keys, what the precondition means)``.
#:
#: The verdict rule, applied uniformly:
#:
#: * any signal key non-zero            -> **FIRED**
#: * all signals zero, all preconds 0   -> **NOT NEEDED** (says nothing about the fix)
#: * all signals zero, a precond > 0    -> **UNOBSERVED** (a finding)
#: * no precondition is knowable        -> **NOT OBSERVABLE HERE**, stated as such
#:
#: A fix with an empty precondition tuple is one whose trigger this run cannot
#: measure. Reporting that as NOT NEEDED would be a claim the artefacts do not
#: support, so it gets its own bucket instead of being quietly folded into one
#: of the other three.
FIXES = (
    ("file_grep: fallback is no longer silent",
     ("file_grep_fallback_warned",), ("file_grep_calls",),
     "file_grep was called at all"),
    ("file_grep: an empty result names its backend",
     ("file_grep_empty_named_backend",), ("file_grep_empty",),
     "file_grep returned an empty result"),
    ("file_grep: the fallback reports its file cap",
     ("file_grep_capped",), ("file_grep_calls",),
     "file_grep was called at all"),
    ("truncation: a provider cut-off is detected, not delivered as the answer",
     ("truncation_detected",), ("generation_at_output_ceiling",),
     "a generation hit the output ceiling"),
    ("background: the completion gate refuses a claim resting on unobserved work",
     ("unobserved_background_gate", "gate_reason:unobserved_background"),
     ("background_started",),
     "a background command was started"),
    ("background: bash_output can actually wait (`wait_ms`)",
     ("background_wait", "bash_output_wait_ms_arg", "ev:background_wait_started"),
     ("background_started",),
     "a background command was started"),
    ("services: the prompt names the daemonised form for a service deliverable",
     ("daemonised_service_cmd",), ("background_serverish",),
     "a server-shaped background command was started"),
    ("loop: the announcement backstop nudges a turn that ended on 'I'll do X next'",
     ("announcement_continue", "ev:announcement_continue"), (),
     "not measurable from these artefacts"),
    ("file_edit: the diff points at the region the edit touched",
     ("file_edit_diff_note",), ("file_edit_calls",),
     "an edit tool was called"),
    ("loop: two edits to one file are serialised",
     ("parallel_edit_serialised",), (),
     "not measurable from these artefacts"),
)


def verdict(totals: Counter, signals: tuple, preconds: tuple) -> tuple[str, str]:
    fired = sum(totals.get(k, 0) for k in signals)
    if fired:
        return "FIRED", f"{fired} occurrence(s)"
    if not preconds:
        return "NOT OBSERVABLE HERE", "no precondition is recoverable from the logs"
    n = sum(totals.get(k, 0) for k in preconds)
    if n:
        return "UNOBSERVED", f"precondition occurred {n} time(s) and the signal is absent"
    return "NOT NEEDED", "the precondition never occurred in this run"


def trials(run_dir: Path):
    for agent in sorted(run_dir.glob("harbor/*/*/agent")):
        yield agent.parent.name.split("__")[0], agent


def scan(run_dir: Path) -> dict:
    per_task: dict[str, dict] = {}
    samples: dict[str, str] = {}
    events_seen: Counter = Counter()
    grep_calls: list[dict] = []

    for task, agent in trials(run_dir):
        row = defaultdict(int)

        for log in ("osa-serve.log", "osa-driver.log"):
            p = agent / log
            if not p.exists():
                continue
            for line in p.read_text(errors="replace").splitlines():
                for key, rx in LOG_SIGNATURES.items():
                    if rx.search(line):
                        row[key] += 1
                        samples.setdefault(key, f"[{task}] {line.strip()[:300]}")

        ev = agent / "osa-events.jsonl"
        if ev.exists():
            pending: dict[str, dict] = {}
            for line in ev.read_text(errors="replace").splitlines():
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                t = d.get("type")
                name = d.get("event") or d.get("_event")
                if t == "system_event" and name in EVENT_NAMES:
                    events_seen[name] += 1
                    row[f"ev:{name}"] += 1
                    samples.setdefault(f"ev:{name}", f"[{task}] {json.dumps(d)[:300]}")
                    # The gate has several clauses and they are different fixes.
                    # Counting the bare event as evidence for the background
                    # clause would call it FIRED whenever the UNRELATED
                    # `unchecked_write` clause ran -- measured on the smoke run,
                    # where exactly that produced a false FIRED.
                    if name == "verification_gate_triggered":
                        row[f"gate_reason:{d.get('reason') or '?'}"] += 1
                        row[f"gate_oracle:{d.get('oracle') or '?'}"] += 1
                # The PRECONDITION for the truncation fix. A generation that
                # reports exactly the provider ceiling was cut off rather than
                # finished (`scripts/failure_species.py:MAX_OUTPUT_TOKENS`).
                # Without this counter, "no truncation was detected" and "no
                # truncation happened" are the same output, which is precisely
                # the NOT NEEDED / UNOBSERVED distinction this file exists to
                # make.
                if t == "llm_response":
                    ot = (d.get("usage") or {}).get("output_tokens") or 0
                    if ot >= MAX_OUTPUT_TOKENS:
                        row["generation_at_output_ceiling"] += 1
                if t == "tool_call" and d.get("phase") == "start":
                    pending[d.get("tool_call_id")] = d
                    a = str(d.get("args", ""))
                    if d.get("name") in ("file_edit", "file_transform"):
                        row["file_edit_calls"] += 1
                    if d.get("name") == "bash_output" and "wait_ms" in a:
                        row["bash_output_wait_ms_arg"] += 1
                    # Species 3: the prompt now names the daemonised form for a
                    # service that IS the deliverable, instead of steering it
                    # into the session's process group where `fire_session_end`
                    # correctly reaps it. Use of `setsid`/`nohup` is the model
                    # taking that advice.
                    if RX_DAEMONISED.search(a):
                        row["daemonised_service_cmd"] += 1
                        samples.setdefault("daemonised_service_cmd", f"[{task}] {a[:280]}")
                if t == "background_command_started":
                    row["background_started"] += 1
                    if RX_SERVERISH.search(str(d.get("command", ""))):
                        row["background_serverish"] += 1
                        samples.setdefault(
                            "background_serverish",
                            f"[{task}] {str(d.get('command'))[:280]}",
                        )
                if t == "tool_result":
                    call = pending.get(d.get("tool_call_id"), {})
                    res = str(d.get("result") or "")
                    if d.get("name") == "file_grep":
                        empty = bool(RX_NO_MATCH.search(res)) or not res.strip()
                        grep_calls.append(
                            {
                                "task": task,
                                "args": str(call.get("args", ""))[:200],
                                "empty": empty,
                                "names_backend": bool(RX_GREP_EMPTY_NOTE.search(res)),
                                "result_head": res[:200],
                            }
                        )
                        row["file_grep_calls"] += 1
                        if empty:
                            row["file_grep_empty"] += 1
                            if RX_GREP_EMPTY_NOTE.search(res):
                                row["file_grep_empty_named_backend"] += 1

        per_task[task] = dict(row)

    return {
        "per_task": per_task,
        "samples": samples,
        "events": dict(events_seen),
        "grep_calls": grep_calls,
    }


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: fix_evidence.py runs/<run-id>")
        return 2
    run_dir = Path(argv[1])
    out = scan(run_dir)

    totals: Counter = Counter()
    for row in out["per_task"].values():
        totals.update(row)

    print(f"# fix evidence — {run_dir.name}\n")
    print(f"trials scanned: {len(out['per_task'])}\n")
    print("| signal | total | tasks |")
    print("|---|---:|---:|")
    for k in sorted(totals):
        n_tasks = sum(1 for r in out["per_task"].values() if r.get(k))
        print(f"| `{k}` | {totals[k]} | {n_tasks} |")

    print("\n## per-fix verdict\n")
    print("| fix | verdict | evidence | precondition |")
    print("|---|---|---|---|")
    verdicts = {}
    for label, signals, preconds, precond_desc in FIXES:
        v, why = verdict(totals, signals, preconds)
        verdicts[label] = {"verdict": v, "evidence": why,
                           "precondition": precond_desc}
        print(f"| {label} | **{v}** | {why} | {precond_desc} |")
    out["verdicts"] = verdicts

    n_unobs = sum(1 for d in verdicts.values() if d["verdict"] == "UNOBSERVED")
    if n_unobs:
        print(f"\n> **{n_unobs} fix(es) are UNOBSERVED**: the situation they "
              f"address happened in this run and the mechanism left no trace. "
              f"That is a finding, not a null result, and each one is either a "
              f"fix that did not fire or a signature this scraper has wrong.")

    print("\n## file_grep empty results (the false-negative surface)\n")
    empties = [g for g in out["grep_calls"] if g["empty"]]
    print(f"{len(empties)} empty of {len(out['grep_calls'])} file_grep calls; "
          f"{sum(1 for g in empties if g['names_backend'])} of those named the backend.")
    for g in empties[:20]:
        print(f"  - [{g['task']}] args={g['args']!r} named_backend={g['names_backend']}")

    print("\n## samples\n")
    for k, v in sorted(out["samples"].items()):
        print(f"- `{k}`: {v}")

    (run_dir / "fix-evidence.json").write_text(json.dumps(out, indent=2) + "\n")
    print(f"\nwrote {run_dir / 'fix-evidence.json'}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
