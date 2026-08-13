#!/usr/bin/env python3
"""Did OSA fail to *notice* the broken state, or notice it and fail to *act*?

The delta says recovery is worse than fresh. It does not say why, and the two
candidate causes call for completely different fixes:

  A. **Blindness** — OSA never observed that the machine was broken. It did not
     run the verification, or it ran it and the failure never made it back into
     the model's context (truncated tool output, evicted block, dropped turn).
     That is a *harness* problem.

  B. **Resignation** — OSA observed the failure and stopped anyway: it ran the
     test, saw it fail, and produced an answer instead of another edit. That is
     a *policy/model* problem, and no amount of context plumbing fixes it.

This separation is the same question the airgapped SWE-bench run raised, where
16 of 17 failed instances *did* run tests, so verification was demonstrably
happening and was not the differentiator. If the same shape shows up here, the
two benchmarks are pointing at one behaviour.

Method, and its limits
----------------------
For each trial this replays ``osa-events.jsonl`` in order and marks:

* **observed failure** — a ``tool_result`` carrying a recognisable failure
  signature (traceback, assertion, non-zero exit, test-runner failure line).
* **mutating action** — a tool call that changes the machine: ``file_write``,
  ``file_edit``, or a ``shell_execute`` whose command matches a write-shaped
  pattern.

Classification is on the *last* observed failure, because what matters is what
OSA did once it last knew the state was bad:

  ``never_observed_failure``  no failure signature ever came back (candidate A)
  ``resigned_after_failure``  saw a failure, then made **zero** mutating calls
                              before ending the run (candidate B)
  ``iterated_after_failure``  saw a failure and kept editing — a genuine
                              capability limit, not a recovery-policy defect

A caveat that matters for comparing this to SWE-bench
-----------------------------------------------------
``verify_calls`` counts recognisable test-runner invocations, and on
Terminal-Bench it comes out at or near **zero for every task, including the ones
that pass**. That is not OSA declining to verify. Terminal-Bench deliberately
does *not* expose ``tests/test.sh`` to the agent — grading happens after the
episode, on container state — so there is no target test for the agent to run.
Agents verify ad hoc instead (a ``python -c`` round-trip, re-reading a file).

So the SWE-bench observation "16 of 17 failed instances did run tests" has **no
direct analogue here**, and ``verify_calls`` must not be read as evidence either
way. The transferable signal is the pair
(``failures_observed``, ``mutations_after_last_failure``): whether the machine
told OSA something was wrong, and whether OSA did anything about it.

**This is heuristic and it is not a verdict.** Command classification is
regex-based; a shell one-liner can both test and mutate. The counts are a lead
worth chasing in the transcripts, in the same spirit as the self-inflicted
markers in ``bench/terminalbench``. `resigned_after_failure` on a task that
*passed* is not a defect at all — it usually means the last failure was an
intermediate step that was later fixed, which is why the reporter prints the
reward alongside.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

# --- what counts as "the machine told OSA it was broken" -------------------
FAILURE_SIGNS = re.compile(
    r"Traceback \(most recent call last\)"
    r"|^\s*AssertionError"
    r"|\bFAILED\b"
    r"|\d+ failed"
    r"|\bERROR\b.*\btest"
    r"|No such file or directory"
    r"|ModuleNotFoundError"
    r"|command not found"
    r"|Exit [1-9]\d*:"
    r"|non-zero exit",
    re.MULTILINE,
)

# --- what counts as "OSA changed the machine" ------------------------------
MUTATING_TOOLS = {"file_write", "file_edit", "str_replace", "apply_patch"}

MUTATING_SHELL = re.compile(
    r"(^|\s|\|)(rm|mv|cp|mkdir|touch|chmod|chown|ln|patch|tee)\s"
    r"|>\s*\S"                      # any redirect that writes
    r"|\bsed\b[^|]*-i"              # in-place sed
    r"|\bcat\b\s*<<"                # heredoc write
    r"|\b(pip|pip3|apt|apt-get|npm|cargo|go)\s+(install|add|get)\b"
    r"|\bpython[0-9.]*\s+-c\s+.{0,200}(open\(|write|Path\()",
)

# --- what counts as "OSA checked whether it worked" ------------------------
VERIFY_SHELL = re.compile(
    r"\bpytest\b|\bunittest\b|\bnose\b"
    r"|\b(make|npm|yarn|pnpm)\s+test\b"
    r"|\bgo\s+test\b|\bcargo\s+test\b"
    r"|\.?/?run_tests?|\btest\.sh\b"
    r"|\bpython[0-9.]*\s+-m\s+pytest\b",
)


def _events(path: Path):
    with path.open() as fh:
        for line in fh:
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def _shell_command(ev: dict) -> str:
    a = ev.get("args")
    if isinstance(a, str):
        return a
    if isinstance(a, dict):
        for k in ("command", "cmd", "script", "input"):
            if k in a:
                return str(a[k])
        return json.dumps(a)
    return ""


def analyse_trial(agent_dir: Path) -> dict | None:
    ev_path = agent_dir / "osa-events.jsonl"
    if not ev_path.exists():
        return None

    step = 0
    last_failure_step = None
    mutations_after_failure = 0
    total_mutations = 0
    verify_calls = 0
    failures_seen = 0
    last_failure_excerpt = ""

    for ev in _events(ev_path):
        t = ev.get("type")

        if t == "tool_call" and ev.get("phase") == "start":
            step += 1
            name = ev.get("name") or ""
            cmd = _shell_command(ev)
            mutating = name in MUTATING_TOOLS or (
                name == "shell_execute" and bool(MUTATING_SHELL.search(cmd))
            )
            if name == "shell_execute" and VERIFY_SHELL.search(cmd):
                verify_calls += 1
            if mutating:
                total_mutations += 1
                if last_failure_step is not None:
                    mutations_after_failure += 1

        elif t == "tool_result":
            result = str(ev.get("result", ""))
            failed = ev.get("success") is False or bool(FAILURE_SIGNS.search(result))
            if failed:
                failures_seen += 1
                last_failure_step = step
                mutations_after_failure = 0  # reset: count only after the LAST one
                last_failure_excerpt = result.strip().replace("\n", " ")[:160]

    if last_failure_step is None:
        verdict = "never_observed_failure"
    elif mutations_after_failure == 0:
        verdict = "resigned_after_failure"
    else:
        verdict = "iterated_after_failure"

    return {
        "verdict": verdict,
        "failures_observed": failures_seen,
        "verify_calls": verify_calls,
        "total_mutations": total_mutations,
        "mutations_after_last_failure": mutations_after_failure,
        "last_failure_excerpt": last_failure_excerpt,
    }


def analyse_run(run_dir: Path) -> dict:
    out: dict[str, dict] = {}
    for arm in ("fresh", "corrupted"):
        rows = {}
        for result_path in (run_dir / arm).glob("harbor/*/*__*/result.json"):
            trial = result_path.parent
            try:
                r = json.loads(result_path.read_text())
            except (OSError, json.JSONDecodeError):
                continue
            name = r.get("task_name")
            if not name:
                continue
            name = name.split("/")[-1]
            a = analyse_trial(trial / "agent")
            if a is None:
                continue
            a["reward"] = (r.get("verifier_result") or {}).get("rewards", {}).get("reward")
            meta = (r.get("agent_result") or {}).get("metadata") or {}
            a["osa_status"] = meta.get("osa_status")
            rows[name] = a
        out[arm] = rows
    return out


def main() -> int:
    run_dir = Path(sys.argv[1] if len(sys.argv) > 1 else "runs/delta-01")
    data = analyse_run(run_dir)

    print(f"# Recovery forensics — {run_dir}\n")
    print("Heuristic. `resigned_after_failure` on a PASSED task is normally benign")
    print("(the last failure was an intermediate step). The cell that matters is")
    print("`resigned_after_failure` on a FAILED task in the corrupted arm.\n")

    for arm in ("fresh", "corrupted"):
        rows = data.get(arm) or {}
        if not rows:
            continue
        print(f"## {arm}  (n={len(rows)})")
        print(f"{'task':34}{'rw':>5} {'verdict':26}{'fails':>6}{'verif':>6}"
              f"{'muts':>6}{'after':>6}")
        for name, a in sorted(rows.items()):
            print(f"{name[:33]:34}{str(a['reward']):>5} {a['verdict']:26}"
                  f"{a['failures_observed']:>6}{a['verify_calls']:>6}"
                  f"{a['total_mutations']:>6}{a['mutations_after_last_failure']:>6}")
        tally: dict[str, int] = {}
        for a in rows.values():
            tally[a["verdict"]] = tally.get(a["verdict"], 0) + 1
        print(f"  -> {tally}\n")

    # The comparison the whole file exists for.
    f, c = data.get("fresh") or {}, data.get("corrupted") or {}
    both = sorted(set(f) & set(c))
    if both:
        print("## Paired: what changed between the arms")
        print(f"{'task':34}{'fresh':>7}{'corr':>7}  {'fresh verdict':26}corrupted verdict")
        for t in both:
            print(f"{t[:33]:34}{str(f[t]['reward']):>7}{str(c[t]['reward']):>7}  "
                  f"{f[t]['verdict']:26}{c[t]['verdict']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
