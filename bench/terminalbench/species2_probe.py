#!/usr/bin/env python3
"""Settle (or fail to settle) the species-2 anchoring hypothesis, from data.

## The open question this exists for

`docs/research/failure-taxonomy.md` §2 names nine tasks on which the model wrote
a genuine red->green test that measured **the wrong property**. Eleven candidate
detectors were built and every one was rejected under the acceptance rule
`scripts/failure_species.py` states: *a detector must fire on at least one
failure and on ZERO solved trials*. They were rejected because the solves did
the same thing — a self-written test that passes is the signature of a correct
episode and an incorrect one in equal measure.

§2.5 narrowed the surviving hypothesis to **oracle provenance**: a requirement
with a named external checker gets checked; a requirement stated only in prose
gets reasoned about and never asserted. It could not be tested, because OSA's
event log stores a `file_write`'s path and not its content.

1.0.99 ships the missing fact. `VerificationEvidence.oracle_provenance/1`
(`:external | :self_authored | :none`) now rides on every
`verification_gate_triggered` event. This reads it back and cross-tabs it
against the verdict.

## What a result here means, and what it does not

This applies the same acceptance rule, and it is expected to be able to REJECT
the hypothesis, not to confirm it. If `self_authored` appears on solved trials
at a similar rate, provenance joins the eleven rejected proxies and that is the
finding — the same finding, more cheaply, for the next person who has the idea.

It is also not a per-requirement measurement. Provenance is recorded per
session; §2.5's claim is about *coverage of individual requirements within* a
session, and a session that ran one external checker and invented three tests
reads as `external` here. So a null result rejects the strong session-level
form and leaves the per-requirement form untested.

Usage:
    ./species2_probe.py runs/<run-id>
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter, defaultdict
from pathlib import Path

#: The nine tasks §2 names. Listed so the cross-tab can be read for them
#: specifically as well as over the whole run -- they are the cases the
#: hypothesis is about, and pooling them into "all failures" dilutes exactly the
#: signal being looked for.
#: Verbatim from `docs/research/failure-taxonomy.md` §2, not re-derived.
SPECIES_2_TASKS = (
    "adaptive-rejection-sampler",
    "build-pov-ray",
    "dna-assembly",
    "filter-js-from-html",
    "mailman",
    "model-extraction-relu-logits",
    "sam-cell-seg",
    "sanitize-git-repo",
    "torch-tensor-parallelism",
)


def gate_events(trial_dir: Path):
    p = trial_dir / "agent" / "osa-events.jsonl"
    if not p.exists():
        return
    for line in p.read_text(errors="replace").splitlines():
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue
        if d.get("type") == "system_event" and (
            d.get("event") or d.get("_event")
        ) == "verification_gate_triggered":
            yield d


def session_provenance(trial_dir: Path) -> tuple[str | None, Counter, Counter]:
    """The session's provenance, plus the raw distributions behind it.

    A session can fire the gate several times and the provenance can change as
    the session goes on. The single label is the **strongest** observed --
    `external` beats `self_authored` beats `none` -- because the hypothesis is
    "did an external oracle appear at all", and taking the last value instead
    would let one late invented test erase a real checker.
    """
    provs, reasons = Counter(), Counter()
    for e in gate_events(trial_dir):
        provs[e.get("oracle") or "missing"] += 1
        reasons[e.get("reason") or "?"] += 1
    if not provs:
        return None, provs, reasons
    for rank in ("external", "self_authored", "none", "missing"):
        if provs.get(rank):
            return rank, provs, reasons
    return None, provs, reasons


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("run_dir")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args(argv[1:])

    run = Path(args.run_dir)
    doc = json.loads((run / "results.json").read_text())

    table: dict[tuple[str, bool], list[str]] = defaultdict(list)
    rows = []
    no_gate = []
    for t in doc["tasks"]:
        d = t.get("trial_dir")
        if not d:
            continue
        name = t["task_name"].split("/")[-1]
        solved = bool(t.get("resolved"))
        prov, provs, reasons = session_provenance(Path(d))
        if prov is None:
            no_gate.append(name)
            continue
        table[(prov, solved)].append(name)
        rows.append((name, solved, prov, dict(provs), dict(reasons)))

    print(f"# species-2 probe — `{run.name}`\n")
    print(f"trials with at least one `verification_gate_triggered`: {len(rows)}")
    print(f"trials with none (gate never fired): {len(no_gate)}")

    print("\n## provenance x verdict\n")
    print("| oracle provenance | solved | failed | fires on a solve? |")
    print("|---|---:|---:|---|")
    for prov in ("external", "self_authored", "none", "missing"):
        s = len(table.get((prov, True), []))
        f = len(table.get((prov, False), []))
        if not (s or f):
            continue
        verdict = "**YES — rejected as a detector**" if s else "no"
        print(f"| `{prov}` | {s} | {f} | {verdict} |")

    sp2_present = [r for r in rows if r[0] in SPECIES_2_TASKS]
    print(f"\n## the nine §2 tasks ({len(sp2_present)} of 9 produced a gate event)\n")
    if sp2_present:
        print("| task | verdict | provenance | gate reasons |")
        print("|---|---|---|---|")
        for name, solved, prov, _p, reasons in sorted(sp2_present):
            print(f"| `{name}` | {'solved' if solved else 'failed'} "
                  f"| `{prov}` | {reasons} |")

    self_on_solve = len(table.get(("self_authored", True), []))
    print("\n## verdict\n")
    if self_on_solve:
        print(f"`self_authored` fired on **{self_on_solve} solved** trial(s). Under "
              f"`scripts/failure_species.py`'s acceptance rule that rejects it as a "
              f"detector — the same structural reason the other eleven candidates "
              f"were rejected. Session-level oracle provenance does NOT separate "
              f"species 2 from a correct episode.")
        print("\nThis rejects the SESSION-level form of the anchoring hypothesis "
              "only. §2.5's claim is per-requirement, and provenance is recorded "
              "per session, so that form remains untested and would need the "
              "assertion text the event log still does not carry.")
    elif table.get(("self_authored", False)):
        print("`self_authored` fired on failures and on **zero** solves. That "
              "passes the acceptance rule and is the first candidate to do so. "
              "Treat it as a lead at this n, not a detector: check it against a "
              "second run before shipping anything that acts on it.")
    else:
        print("Not enough gate events to say anything either way.")

    if args.verbose:
        print("\n## per trial\n")
        for name, solved, prov, provs, reasons in sorted(rows):
            print(f"{name:<36} {'solved' if solved else 'failed':<7} "
                  f"{prov:<14} {provs} {reasons}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
