#!/usr/bin/env python3
"""Detect named *episode-shape* failure species in a Harbor run's event logs.

## What this is for

`bench/terminalbench/failure_shape.py` answers "whose fault was the failure"
at the level of Harbor's own buckets. This answers a narrower and more
actionable question: **did the episode end in a shape that is a defect of the
harness rather than a wrong answer from the model?**

Every detector here was derived by reading the 34 model-failure transcripts of
`osa-tb20-full89-f6981b61` and was then replayed against all 89 trials of that
run. The acceptance test for a detector is stated once and applies to all of
them:

    A detector must fire on at least one failure and on ZERO solved trials.

A detector that also fires on solves is worse than useless -- it would punish
correct work -- so any such candidate is recorded in
`docs/research/failure-taxonomy.md` under "rejected" and is not shipped here.

## Reading the output

Each row is `species  outcome  task  evidence`. Species names match the
headings in `docs/research/failure-taxonomy.md`. Nothing here is a verdict on
the model; a detector says "this episode ended in a shape we can recognise",
and the taxonomy document says what to do about it.

Usage:
    python3 scripts/failure_species.py bench/terminalbench/runs/<run-id>
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

#: Provider max-output ceiling. A generation that reports exactly this many
#: output tokens was cut off by the ceiling, not by the model choosing to stop.
#: Read off the measured distribution: 32768 appears as an exact value and
#: nothing sits between it and the next-largest observed generation.
MAX_OUTPUT_TOKENS = 32768

#: Verbatim prefixes of OSA's own loop-guard messages. When one of these is the
#: LAST thing the session emitted, OSA's guardrail -- not the model and not the
#: task -- ended the episode, and its advice text was delivered to the grader as
#: if it were the answer.
GUARD_PREFIXES = (
    "Stopped: ",              # doom_loop reasoning-only spin halt
    "I hit the same error ",  # failure-signature circuit breaker
)

#: An episode whose LAST words announce the next action rather than report a
#: result did not finish; it stopped mid-sentence in the plan. This is the one
#: language-based detector here and therefore the most brittle -- it is shipped
#: because it passes the acceptance test on the reference run and because it is
#: the only signal that catches an episode which stopped for no other visible
#: reason. Note that length ALONE is not a discriminator: a bare
#: `len(final) < N` rule fires on solved trials at every threshold tested from
#: 200 to 600 characters. The wording carries the signal, not the brevity.
#:
#: THERE IS NO VERB LIST, on purpose. There used to be one and it leaked twice,
#: both times found by a human looking at a real session and never by replay:
#: `large-scale-text-editing` on `runs/osa-tb20-full89-9b57ee7d` ("I'll examine
#: both files ...", one turn, ZERO tool calls, 2.16 s) and a user's v1.0.099
#: session ("I'll map what you already built ...", Plan 0/5, nothing checked).
#: An allow-list can only enumerate the wordings someone already thought of;
#: the `let me ` branch never had one and never leaked. So the `i'll` branch is
#: now symmetric with it and the risk lives in `COURTESY_RE` below.
#:
#: Replayed across every run on disk with a `results.json` -- 180 trials, 94
#: solves, 52 model failures -- plus both live misses:
#:
#:                        pooled failures  pooled solves  reference run
#:     verb allow-list           9              0           9 of 34
#:     shape + stop-list        11              0          10 of 34
#:
#: Strictly dominant. The reason it costs no solve is measurable and worth
#: keeping: across all 94 solves, NO answer shorter than the 500-char ceiling
#: contains "I'll" or "I will" at all -- every solve-side "I'll" sits in a
#: 735-1910 character answer.
ANNOUNCEMENT_RE = re.compile(r"(let me |i'll |i will |now let)", re.IGNORECASE)

ANNOUNCEMENT_MAX_CHARS = 500

#: The stop-list, and the half that carries the risk of the verb-free pattern.
#:
#: Every entry is a SIGN-OFF idiom: a first-person future phrase meaning "the
#: work is finished and I am offering more", not "I am about to act". Scrubbed
#: before matching, while length is still measured on the original.
#:
#: Deliberately specific rather than general. A bare "...for you" rule would
#: have been tempting and wrong: `cancel-async-tasks` fails with "...then I'll
#: create the function for you", an announcement of unstarted work that such a
#: rule would have swallowed. Mirrors `Guardrails.@courtesy_pattern`.
COURTESY_RE = re.compile(
    r"\blet me know\b"
    r"|\bi'?ll let you know\b"
    r"|\bi'?ll be (happy|glad) to\b"
    r"|\bi'?ll (look|check|dig|follow) (into|up on) (it|this|that)\b"
    r"|\bi'?ll (check|verify|confirm) that for you\b",
    re.IGNORECASE,
)

#: The *unstarted* variant of the same species, and the one the shipped backstop
#: could not see. `path-tracing` in
#: `bench/terminalbench/runs/VOID-contended-probe-minimal-04061c68`: ONE
#: generation, 263 output tokens, ZERO tool calls, $0.00174, and the entire
#: episode was "I'll start by examining the image to understand what I need to
#: reproduce." That binary already contained the backstop (21bdbc21 is an
#: ancestor of 04061c68) -- it was blocked by the loop's `not talked_only?`
#: conjunct, which a session that never called a tool trivially fails.
#:
#: The zero-tool-call conjunct is what makes this detector structurally unable
#: to fire on a solve: a solved trial produced a deliverable, and that takes at
#: least one tool. The ceiling is tighter than the 500 above because at zero
#: tools the announcement IS the whole episode. Mirrors
#: `Guardrails.unstarted_task_announcement?/2`.
UNSTARTED_MAX_CHARS = 200

#: `Guardrails.deliverable_task?/1`, verbatim: a mutating verb plus either a
#: code noun or a concretely named artefact. This is what separates
#: `path-tracing` ("Write a c program image.c ...") from a question that is
#: answerable in prose. Note "check" is deliberately not a mutating verb.
CODING_ACTION_RE = re.compile(
    r"\b(fix|change|update|refactor|add|implement|create|modify|edit|write|build"
    r"|rewrite|delete|remove|rename)\b",
    re.IGNORECASE,
)
CODING_CONTEXT_RE = re.compile(
    r"\b(function|method|module|file|code|script|class|endpoint|handler|component"
    r"|route|controller|service|model|schema|migration|test|spec|bug|error|feature)\b",
    re.IGNORECASE,
)
ARTEFACT_RE = re.compile(
    r"(/[\w.\-]+){2,}|\b[\w\-]+\.(c|h|cc|cpp|hpp|py|ex|exs|erl|rs|go|js|mjs|ts|tsx"
    r"|jsx|java|rb|sh|bash|zsh|sql|json|ya?ml|toml|ini|cfg|md|txt|csv|tsv|ppm|png"
    r"|jpe?g|cs|swift|kt|scala|lua|pl|php|r|zig|nim|ml|hs|dart|proto|lock|conf)\b",
    re.IGNORECASE,
)

#: Where task instructions live, relative to the repo root.
TASKS_ROOT = Path(__file__).resolve().parent.parent / "bench" / "terminalbench" / "tasks"


def announcement(text: str) -> bool:
    """Announcement wording, courtesy sign-offs scrubbed first."""
    return bool(ANNOUNCEMENT_RE.search(COURTESY_RE.sub("", text)))


def coding_task(task_name: str) -> bool:
    """True when the task's own instruction asks for a deliverable to be built.

    Conservative: an instruction we cannot find reads as NOT a coding task, so
    a missing tasks/ checkout can only suppress a detector, never invent one.
    """
    for p in sorted(TASKS_ROOT.glob(f"*/{task_name}/instruction.md")):
        text = p.read_text(errors="replace")
        return bool(
            CODING_ACTION_RE.search(text)
            and (CODING_CONTEXT_RE.search(text) or ARTEFACT_RE.search(text))
        )
    return False


def resolve_trial_dir(run_dir: Path, trial_dir: str) -> Path:
    """`trial_dir` from results.json, made cwd-independent.

    Harbor records `trial_dir` as `runs/<run-id>/harbor/...`, i.e. relative to
    `bench/terminalbench` and NOT to wherever this script was invoked from. The
    docstring above tells you to run it from the repo root, where every one of
    those paths resolves to something that does not exist -- `load_events`
    then returns `[]` for all 89 trials, every detector sees an empty episode,
    and the script prints "0 trials matched a species" and exits 0. A broken
    corpus is indistinguishable from a clean run, and the acceptance test that
    is supposed to be the whole point of this file passes vacuously.

    That is the same class as the `:/lib` pathspec bug in
    `run_bench.py:artifact_provenance` -- a guard that reported success
    unconditionally from the day it was written.

    The anchor is derived from `run_dir` itself, which the caller had to name
    correctly for `results.json` to be found at all: `<anchor>/runs/<run-id>`.
    """
    p = Path(trial_dir)
    if p.is_absolute() or p.exists():
        return p
    anchor = run_dir.resolve().parent.parent
    return anchor / p


def load_events(trial_dir: Path) -> list[dict]:
    p = trial_dir / "agent" / "osa-events.jsonl"
    if not p.exists():
        return []
    out = []
    for line in p.read_text(errors="replace").splitlines():
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return out


def episode(events: list[dict]) -> dict:
    """Reduce an event log to the few facts the detectors need.

    ## Why the background ledger is reconciled against `running_count`

    A ledger built only from `background_command_started` minus
    `background_command_completed` goes STALE, because the completion
    broadcast is not guaranteed to reach the wire. `BackgroundTask` documents
    the race itself: completion notification is exactly-once and "the
    cross-process race -- a `bash_output` poll vs this broadcast -- is
    arbitrated separately by the shared `Agent.TaskNotifications.mark_notified`
    check-and-set". When the poll wins, the job is reported to the model and
    the event is never emitted. The job ended; the ledger does not know.

    That produced a detector hit on a SOLVED trial -- `rstan-to-pystan` in
    `runs/osa-tb20-full89-9b57ee7d`, the first violation of the acceptance
    rule at the top of this file. MEASURED, from that trial's own log:
    `bg_keh-scTV` (`/app/venv/bin/pip install "pystan==3.10.0" pandas numpy`)
    has a start and no completion, yet the NEXT background job starts with
    `running_count: 1` -- not 2 -- and completes with `running_count: 0`. The
    eight foreground commands in between successfully import the packages that
    install produced. The install finished; only its event is missing.

    `running_count` is the runtime's own live count at the moment the event was
    emitted (`BackgroundManager.running_count/0`, inclusive of the job on a
    start and exclusive on a completion), so it is authoritative in a way the
    reconstructed ledger is not. Whenever the ledger holds more entries than
    the runtime says are live, the surplus have ended without being observed
    and the oldest are evicted -- a job that has outlived a later job's start
    is the stale one.

    The RULE is unchanged and was never wrong: claiming completion while a job
    this session started is genuinely still running is still the species. Only
    the replay's notion of "still running" is corrected.

    Note this affects the replay detector ONLY. Clause 0 of the verification
    gate (`VerificationGate.unobserved_background/1`) queries
    `BackgroundManager.list()` for live `:running` snapshots rather than
    replaying events, so it never had the stale-ledger defect and never
    blocked this completion. MEASURED: across both 89-task runs, all 77
    `verification_gate_triggered` events carry `inadequate_test`,
    `unchecked_write` or `failing_check` -- `unobserved_background` fired zero
    times, and the only gate firing on `rstan-to-pystan` was
    `inadequate_test`.
    """
    running: dict[str, str] = {}
    generations: list[int] = []
    final_response = None
    saw_done = False
    tool_calls = 0

    def reconcile(event: dict) -> None:
        """Drop ledger entries the runtime says are no longer live."""
        live = event.get("running_count")
        if not isinstance(live, int) or live < 0:
            return
        # dicts preserve insertion order, so this evicts oldest-first.
        while len(running) > live:
            running.pop(next(iter(running)))

    for e in events:
        t = e.get("type")
        if t == "tool_call":
            tool_calls += 1
        if t == "background_command_started":
            running[e["background_id"]] = str(e.get("command", ""))
            reconcile(e)
        elif t == "background_command_completed":
            running.pop(e.get("background_id"), None)
            reconcile(e)
        elif t == "llm_response":
            generations.append((e.get("usage") or {}).get("output_tokens") or 0)
        elif t == "agent_response":
            final_response = e.get("response") or ""
        elif t == "done":
            saw_done = True
    # `llm_response` is emitted twice per generation (stream end + accounting).
    return {
        "running": running,
        "generations": generations[::2],
        "final_response": final_response,
        "saw_done": saw_done,
        "tool_calls": tool_calls,
    }


def detect(ep: dict, task_name: str = "") -> list[tuple[str, str]]:
    """Return [(species, evidence)] for one episode."""
    hits = []
    gens = ep["generations"]

    # --- terminal output-token truncation --------------------------------
    # The last generation hit the provider's output ceiling, so the model was
    # cut off mid-thought. OSA delivered the truncated text as the answer
    # instead of continuing. Fires on 3 trials of the reference run
    # (regex-chess, schemelike-metacircular-eval, circuit-fibsqrt), 0 solves.
    if gens and gens[-1] >= MAX_OUTPUT_TOKENS:
        hits.append(("terminal_truncation",
                     f"final generation = {gens[-1]} output tokens (ceiling)"))

    # --- abandoned background job ----------------------------------------
    # The session declared itself finished while a background command it had
    # started was still running. Either the answer depended on that command, or
    # the command WAS the deliverable (a server) and died with the session.
    # Fires on 12 trials of the reference run, 0 solves.
    if ep["saw_done"] and ep["running"]:
        cmds = "; ".join(sorted(c[:60] for c in ep["running"].values()))
        hits.append(("abandoned_background",
                     f"{len(ep['running'])} still running at done: {cmds}"))

    # --- guard text delivered as the answer -------------------------------
    # OSA's own loop guard produced the final message. The episode did not end
    # because the work was done; it ended because a guard fired.
    # Fires on 2 trials of the reference run, 0 solves.
    fr = ep["final_response"] or ""
    if fr.startswith(GUARD_PREFIXES):
        hits.append(("guard_halt_as_answer", fr.split("\n")[0][:110]))

    # --- the last words announce the next action ---------------------------
    # Fires on 9 trials of the reference run, 0 solves.
    if fr and len(fr) < ANNOUNCEMENT_MAX_CHARS and announcement(fr):
        hits.append(("announced_next_action", fr.replace("\n", " ")[:110]))

    # --- the task was announced and never started -------------------------
    # Zero tool calls in the whole episode, on a task that asks for a code
    # change. Fires on 0 trials of the reference run and on `path-tracing` in
    # `runs/VOID-contended-probe-minimal-04061c68`; it cannot fire on a solve.
    if (
        fr
        and ep["tool_calls"] == 0
        and len(fr) < UNSTARTED_MAX_CHARS
        and announcement(fr)
        and coding_task(task_name)
    ):
        hits.append(("announced_unstarted_task",
                     f"0 tool calls: {fr.replace(chr(10), ' ')[:90]}"))

    return hits


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run_dir")
    ap.add_argument("--all", action="store_true",
                    help="also list trials with no species hit")
    args = ap.parse_args()

    run = Path(args.run_dir)
    results = run / "results.json"
    if not results.exists():
        print(f"no results.json under {run}", file=sys.stderr)
        return 1

    tasks = json.loads(results.read_text())["tasks"]
    fired_on_solve = 0
    n_with_events = 0
    rows = []
    for t in tasks:
        d = t.get("trial_dir")
        if not d:
            continue
        events = load_events(resolve_trial_dir(run, d))
        n_with_events += bool(events)
        ep = episode(events)
        name = t["task_name"].split("/")[-1]
        outcome = "solved" if t.get("resolved") else (t.get("fault_owner") or "?")
        hits = detect(ep, name)
        if not hits and not args.all:
            continue
        for species, evidence in hits or [("-", "")]:
            if species != "-" and outcome == "solved":
                fired_on_solve += 1
            rows.append((species, outcome, name, evidence))

    for species, outcome, name, evidence in sorted(rows):
        print(f"{species:<22} {outcome:<9} {name:<34} {evidence}")

    n_hit = len({r[2] for r in rows if r[0] != "-"})
    print(f"\n{n_hit} trials matched a species; "
          f"{fired_on_solve} detector hits landed on a SOLVED trial "
          f"({n_with_events}/{len(tasks)} trials had an event log).")

    # Zero readable event logs is a broken corpus, not a clean run. Said out
    # loud and failed on, because the silent version of this reads exactly like
    # a pass -- see `resolve_trial_dir`.
    if tasks and not n_with_events:
        print(f"no trial under {run} has an agent/osa-events.jsonl -- every "
              f"detector saw an empty episode, so this run proves nothing.",
              file=sys.stderr)
        return 3
    if fired_on_solve:
        print("A detector firing on a solve violates the acceptance test above.",
              file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
