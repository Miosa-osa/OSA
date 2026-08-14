#!/usr/bin/env python3
"""Replay engagement detectors against benchmark run artifacts, READ ONLY.

## What this answers

`VerificationGate` clause 0 refuses a completion claim made while a background
command the session started is still running. This script asks the only
question that makes that clause worth shipping:

    would it have fired on the failures, and would it have STAYED QUIET on the
    solves?

A detector that also fires on solves is worse than nothing: it converts fast
correct work into re-prompts, and on a deadline-bound task a re-prompt can
convert a solve into a timeout.

## Why the obvious detectors are in here too

The cluster this came from was first characterised by wall clock: six failures
under 5 s/turn against 7.7 s/turn for solves, measured mid-run on 41 graded
trials. **That separation does not survive the sample growing.** The
`sec_per_turn` and `reasoning_*` rows below are kept so the comparison is
reproducible rather than remembered, and so the next person reaches for the
replay before the anecdote.

Both proxies are also confounded three ways — provider latency, model, task
difficulty — while `unobserved_background` reads a fact off the event log that
the loop can read directly off `Shell.BackgroundManager`. The offline
computation and the in-loop computation are the same question asked of the same
state, which is the property that makes this replay an acceptance test rather
than an analogy.

## Usage

    scripts/engagement_replay.py bench/terminalbench/runs/<run>/harbor/<stamp>
    scripts/engagement_replay.py <run_dir> --detector unobserved_background -v

Reads `result.json` + `agent/osa-events.jsonl` + `agent/osa-driver.log` under
each trial directory. Writes nothing.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

#: Tasks whose own reference solution scores < 1.0 on the machine that produced
#: the artifacts. An OSA failure on one of these is not evidence about OSA.
#: Regenerate with `bench/terminalbench/controls.py` rather than trusting this
#: list on another host — it is a statement about local images and credentials.
TB20_UNSOUND = {
    "build-cython-ext", "build-pmars", "make-doom-for-mips",
    "mcmc-sampling-stan", "protein-assembly", "rstan-to-pystan",
}
#: Oracle wrote no reward at all: the task is probably fine and the machine is not.
TB20_INFRA = {"caffe-cifar-10"}

#: The retracted proxy, kept only so its failure is reproducible. See module doc.
SHALLOW_SEC_PER_TURN = 5.0
SHALLOW_REASONING_CHARS_PER_TURN = 200


def parse_events(path: Path) -> dict:
    """Fold one episode's event log into the facts every detector needs.

    Turns are segmented on `llm_response`, whose `usage` is per-round-trip and
    is emitted twice per turn (bus + PubSub bridge); consecutive duplicates are
    dropped. Reasoning is accumulated from `thinking_delta`, which is what both
    the Anthropic-native and the openai-compatible streaming paths emit.
    """
    turns: list[dict] = []
    think = text = 0
    last_usage = None
    live: set[str] = set()
    # Snapshot taken AT the completion claim, not at end of episode. A trial
    # killed by the deadline mid-command has background work in flight and
    # never made a claim; that is not the defect and must not count as a fire.
    claim_live: set[str] | None = None
    claim_text = ""

    with path.open(errors="replace") as fh:
        for line in fh:
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                continue
            t = e.get("type")
            if t == "thinking_delta":
                think += len(e.get("text") or "")
            elif t == "streaming_token":
                text += len(e.get("text") or "")
            elif t == "llm_response":
                u = e.get("usage") or {}
                key = (u.get("input_tokens"), u.get("output_tokens"))
                if key == last_usage:
                    continue
                last_usage = key
                turns.append({"out": u.get("output_tokens") or 0, "think": think, "text": text})
                think = text = 0
            elif t == "background_command_started":
                live.add(e.get("background_id"))
            elif t == "background_command_completed":
                live.discard(e.get("background_id"))
            elif t == "agent_response":
                claim_live = set(live)
                claim_text = e.get("response") or ""

    return {"turns": turns, "claim_live": claim_live, "claim_text": claim_text}


def collect(run_dir: Path) -> list[dict]:
    rows = []
    for rj in sorted(run_dir.glob("*/result.json")):
        try:
            d = json.loads(rj.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        md = (d.get("agent_result") or {}).get("metadata") or {}
        wall = None
        log = rj.parent / "agent" / "osa-driver.log"
        if log.exists():
            m = re.search(r"run=([\d.]+)s", log.read_text(errors="replace"))
            if m:
                wall = float(m.group(1))
        ev = rj.parent / "agent" / "osa-events.jsonl"
        row = {
            "task": d["task_name"].split("/")[-1],
            "reward": ((d.get("verifier_result") or {}).get("rewards") or {}).get("reward"),
            "status": md.get("osa_status"),
            "turns_reported": md.get("osa_turns") or 0,
            "wall_s": wall,
        }
        row.update(parse_events(ev) if ev.exists() else
                   {"turns": [], "claim_live": None, "claim_text": ""})
        rows.append(row)
    return rows


def bucket(r: dict) -> str:
    if r["reward"] is None:
        return "ungraded"
    if r["reward"] == 1.0:
        return "solved"
    if r["task"] in TB20_UNSOUND:
        return "unsound_task"
    if r["task"] in TB20_INFRA:
        return "infra"
    if r["status"] == "timeout":
        return "timeout"
    if r["status"] not in ("ok", None):
        return "harness_fault"
    return "model_failure"


# --- detectors ------------------------------------------------------------
# Each returns (fired, note). Keep them pure and one-line-explainable: the
# point of the table is that they are comparable.

def d_unobserved_background(r: dict) -> tuple[bool, str]:
    """SHIPPED. A completion claim made while a background command still runs."""
    live = r["claim_live"]
    if not live:
        return False, ""
    return True, ",".join(sorted(live))


def d_sec_per_turn(r: dict) -> tuple[bool, str]:
    """RETRACTED PROXY. Wall clock per turn below a fixed floor."""
    if not r["wall_s"] or not r["turns_reported"]:
        return False, ""
    spt = r["wall_s"] / r["turns_reported"]
    return spt < SHALLOW_SEC_PER_TURN, f"{spt:.1f}s/turn"


def d_reasoning_per_turn(r: dict) -> tuple[bool, str]:
    """REJECTED PROXY. Mean reasoning characters per turn below a floor."""
    T = r["turns"]
    if not T:
        return False, ""
    per = sum(t["think"] for t in T) / len(T)
    return per < SHALLOW_REASONING_CHARS_PER_TURN, f"{per:.0f} chars/turn"


def d_no_reasoning_final_turn(r: dict) -> tuple[bool, str]:
    """REJECTED PROXY. The turn that ended the episode emitted no reasoning."""
    T = r["turns"]
    if not T:
        return False, ""
    return T[-1]["think"] == 0, f"final think={T[-1]['think']}"


DETECTORS = {
    "unobserved_background": d_unobserved_background,
    "sec_per_turn": d_sec_per_turn,
    "reasoning_per_turn": d_reasoning_per_turn,
    "no_reasoning_final_turn": d_no_reasoning_final_turn,
}

#: Buckets a detector is allowed to fire on without it counting against it.
#: `solved` is the one that matters: a fire there is a false positive by
#: definition, because the episode was correct.
NEGATIVE_BUCKETS = ("solved",)
POSITIVE_BUCKETS = ("model_failure",)


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run_dir", help="a harbor timestamp dir containing <task>/result.json")
    ap.add_argument("--detector", action="append", choices=sorted(DETECTORS),
                    help="restrict to these (default: all, for comparison)")
    ap.add_argument("-v", "--verbose", action="store_true", help="list every fire")
    args = ap.parse_args()

    run = Path(args.run_dir)
    if not run.exists():
        print(f"no such run: {run}", file=sys.stderr)
        return 1
    rows = [r for r in collect(run) if bucket(r) != "ungraded"]
    if not rows:
        print("nothing graded yet", file=sys.stderr)
        return 1
    for r in rows:
        r["bucket"] = bucket(r)

    buckets: dict[str, list] = {}
    for r in rows:
        buckets.setdefault(r["bucket"], []).append(r)
    order = [b for b in ("model_failure", "solved", "timeout", "unsound_task",
                         "infra", "harness_fault") if b in buckets]

    print(f"run: {run}")
    print("graded " + "  ".join(f"{b}={len(buckets[b])}" for b in order))
    print()

    names = args.detector or list(DETECTORS)
    width = max(len(n) for n in names)
    print(f"{'detector':<{width}}  " + "  ".join(f"{b:>14}" for b in order))
    fires: dict[str, dict[str, list]] = {}
    for name in names:
        fn = DETECTORS[name]
        per: dict[str, list] = {}
        for r in rows:
            fired, note = fn(r)
            if fired:
                per.setdefault(r["bucket"], []).append((r["task"], note))
        fires[name] = per
        cells = "  ".join(f"{len(per.get(b, [])):>6}/{len(buckets[b]):<7}" for b in order)
        print(f"{name:<{width}}  {cells}")

    print()
    for name in names:
        per = fires[name]
        tp = sum(len(per.get(b, [])) for b in POSITIVE_BUCKETS)
        fp = sum(len(per.get(b, [])) for b in NEGATIVE_BUCKETS)
        npos = sum(len(buckets.get(b, [])) for b in POSITIVE_BUCKETS)
        nneg = sum(len(buckets.get(b, [])) for b in NEGATIVE_BUCKETS)
        prec = tp / (tp + fp) if (tp + fp) else 0.0
        verdict = "USABLE" if fp == 0 and tp else ("USELESS" if not tp else "FALSE POSITIVES")
        print(f"{name:<{width}}  recall {tp}/{npos}   false-fire {fp}/{nneg}   "
              f"precision {prec:.0%}   {verdict}")

    if args.verbose:
        for name in names:
            print(f"\n--- {name} ---")
            for b in order:
                for task, note in sorted(fires[name].get(b, [])):
                    print(f"  {b:<14} {task:<34} {note}")

    # Exit non-zero when the shipped detector has acquired a false positive, so
    # this can be run as a regression check rather than read as a report.
    return 1 if fires.get("unobserved_background", {}).get("solved") else 0


if __name__ == "__main__":
    sys.exit(main())
