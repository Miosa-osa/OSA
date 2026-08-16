#!/usr/bin/env python3
"""Measure how much a Harbor run's episodes ITERATED, and test whether that
separates the species-2 failures from the solves.

## The question this exists for

`docs/research/failure-taxonomy.md` §2 names nine tasks on which OSA wrote a
genuine red->green test that measured the wrong property. Thirty candidate
DETECTORS have been rejected against those nine. The hypothesis this script
tests is different in kind: not "can we recognise the shape afterwards" but
"does the failing episode simply iterate less than the solving one" — the
behavioural story imported from mini-swe-agent, which solves by writing several
named test files and looping write -> test -> fix -> test.

If that story held here, the nine would show fewer cycles than matched solves
and a gate demanding a second cycle would be safe. It does not hold. See
`docs/design/iteration-discipline.md`; this script is where those numbers come
from.

## What is counted, and from which field

Every quantity is derived from `agent/osa-events.jsonl`:

  * **command text** — `command_output_delta.command`, the FULL unclipped
    command, taken once per `tool_call_id`. `tool_call.args` is a 60-character
    display hint and has produced three retracted findings; it is never read
    here for content.
  * **edits** — `tool_result` where `name` is a write tool, which carries the
    resolved `path`.
  * **authorship** — a path is "ours" once a write tool produced it OR once a
    shell command redirected into it (`>`, `>>`, `tee`). Many tests in this
    corpus are written by heredoc, and a run that only counts write tools
    reads those as external.

A **cycle** is one completed `test-run -> edit -> test-run`. Two cycles means
the fix was re-tested after a subsequent change, which is exactly what a
"require a second cycle" gate would demand.

## Acceptance rule, inherited verbatim

    A detector must fire on at least one failure and on ZERO solved trials.

Same rule as `scripts/failure_species.py`. Every gate simulated below is
printed with its solve count so a rejection is visible rather than argued.

Usage:
    python3 scripts/iteration_depth.py bench/terminalbench/runs/<run-id>
"""

from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import sys
from pathlib import Path

#: The nine tasks `docs/research/failure-taxonomy.md` §2 names. Verbatim from
#: the taxonomy and from `bench/terminalbench/species2_probe.py`, not
#: re-derived, so the three lists cannot drift apart silently.
SPECIES_2_TASKS = frozenset(
    {
        "adaptive-rejection-sampler",
        "build-pov-ray",
        "dna-assembly",
        "filter-js-from-html",
        "mailman",
        "model-extraction-relu-logits",
        "sam-cell-seg",
        "sanitize-git-repo",
        "torch-tensor-parallelism",
    }
)

WRITE_TOOLS = frozenset({"file_write", "file_edit", "multi_file_edit", "file_transform"})
READ_TOOLS = frozenset({"file_read", "file_grep", "dir_list", "file_glob"})

#: A command that runs a test. Two arms: named runners (pytest, cargo test,
#: googletest via ctest, ...) and the direct invocation of a file whose name
#: says it is a test or a checker. `eval.py`/`check.py` are included because
#: several tasks in this dataset ship exactly those as the environment's own
#: oracle, and running one is the behaviour §2.5 says should outrank inventing
#: a test.
TEST_RE = re.compile(
    r"\b(pytest|unittest|nose2?|bats|tox|ctest|cargo\s+test|go\s+test|"
    r"npm\s+(run\s+)?test|make\s+(check|test)|dune\s+(test|runtest)|"
    r"mix\s+test|rspec|phpunit)\b|"
    r"[\w./-]*\b(test|tests|check|verify|eval|run_tests|conftest)[\w-]*\.(py|sh|c|cpp|js|ts|rb|pl)\b|"
    r"\./(test|tests|check|verify|run_tests)[\w.-]*",
    re.IGNORECASE,
)

#: Shell-side authorship. A heredoc's target appears as the redirect operand,
#: so this catches `cat > /app/tests/test_x.py << 'EOF'` as well as `tee`.
REDIR_RE = re.compile(r"(?:>>?|\|\s*tee(?:\s+-a)?)\s+(['\"]?)([\w./~$-]+)\1")

_NOT_A_FILE = frozenset({"/dev/null", "/dev/stderr", "/dev/stdout", "&1", "&2"})


def _events(trial_dir: Path):
    """Ordered tool events plus the full command text per tool_call_id."""
    path = trial_dir / "agent" / "osa-events.jsonl"
    commands: dict[str, str] = {}
    order = []
    with path.open(errors="replace") as fh:
        for line in fh:
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                continue
            t = e.get("type")
            if t == "command_output_delta":
                cid, cmd = e.get("tool_call_id"), e.get("command")
                if cid and cmd and cid not in commands:
                    commands[cid] = cmd
            elif t in ("tool_call", "tool_result", "done"):
                order.append((t, e))
    return order, commands


def profile(trial_dir: Path) -> dict:
    """Iteration profile of one trial.

    `seq` is a compact transcript alphabet, kept because a disagreement about
    a count is settled by reading it rather than by re-deriving it:
        E edit   t self-authored test run   T test run naming no artefact of ours
        . other command   R external read   W web fetch   | done
    """
    order, commands = _events(trial_dir)
    seen: set[str] = set()
    ours: set[str] = set()
    seq: list[str] = []
    counts = {k: 0 for k in ("edits", "test_runs", "self_test_runs", "ext_test_runs",
                             "ext_reads", "web", "cmd_missing")}

    def claim(path: str) -> None:
        if path and path not in _NOT_A_FILE:
            ours.add(path)
            ours.add(os.path.basename(path))

    for t, e in order:
        if t == "tool_call":
            cid = e.get("tool_call_id")
            # tool_call is emitted twice per call on some routes; the second
            # copy is not a second call.
            if cid in seen:
                continue
            seen.add(cid)
            if e.get("name") != "shell_execute":
                continue
            cmd = commands.get(cid)
            if not cmd:
                counts["cmd_missing"] += 1
                seq.append("?")
                continue
            if TEST_RE.search(cmd):
                counts["test_runs"] += 1
                if any(len(o) > 3 and o in cmd for o in ours):
                    counts["self_test_runs"] += 1
                    seq.append("t")
                else:
                    counts["ext_test_runs"] += 1
                    seq.append("T")
            else:
                seq.append(".")
            for m in REDIR_RE.finditer(cmd):
                claim(m.group(2))
        elif t == "tool_result":
            name, path = e.get("name"), e.get("path")
            if name in WRITE_TOOLS:
                counts["edits"] += 1
                seq.append("E")
                claim(path or "")
            elif name in READ_TOOLS:
                counts["ext_reads"] += 1
                seq.append("R")
            elif name == "web_fetch":
                counts["web"] += 1
                seq.append("W")
        elif t == "done":
            seq.append("|")

    s = "".join(seq)
    cycles, state = 0, 0
    for c in s:
        if c in "tT":
            if state == 2:
                cycles += 1
            state = 1
        elif c == "E" and state == 1:
            state = 2
    return dict(seq=s, cycles=cycles, **counts)


#: The interventions proposed for species 2, each expressed as the gate that
#: would have to fire to demand it. A gate that fires on a solved trial would
#: spend that trial's turns telling a correct episode to keep going.
GATES = {
    "require a 2nd cycle          (cycles < 2)": lambda v: v["cycles"] < 2,
    "require any cycle            (cycles < 1)": lambda v: v["cycles"] < 1,
    "require an unauthored oracle (ext_test_runs == 0)": lambda v: v["ext_test_runs"] == 0,
    "self-tested but never externally (self>0, ext==0)":
        lambda v: v["self_test_runs"] > 0 and v["ext_test_runs"] == 0,
    "self-tested repeatedly, never externally (self>=3, ext==0)":
        lambda v: v["self_test_runs"] >= 3 and v["ext_test_runs"] == 0,
    "fire on OVER-iteration       (cycles >= 2)": lambda v: v["cycles"] >= 2,
    "over-iterated on its own oracle (cycles>=2, ext==0)":
        lambda v: v["cycles"] >= 2 and v["ext_test_runs"] == 0,
    "consulted nothing external   (ext_reads == 0)": lambda v: v["ext_reads"] == 0,
    "fix never re-tested (edits after last test run)":
        lambda v: v["edits_after_last_test"] > 0,
}

FIELDS = ("cycles", "test_runs", "self_test_runs", "ext_test_runs", "edits",
          "ext_reads", "turns")


def collect(run: Path, repo_root: Path) -> dict[str, dict]:
    results = json.loads((run / "results.json").read_text())
    out: dict[str, dict] = {}
    for t in results["tasks"]:
        name = t["task_name"].split("/")[-1]
        rel = t.get("trial_dir")
        if not rel:
            continue
        trial = repo_root / "bench" / "terminalbench" / rel
        if not (trial / "agent" / "osa-events.jsonl").exists():
            continue
        v = profile(trial)
        s = v["seq"]
        last = max(s.rfind("t"), s.rfind("T"))
        v["edits_after_last_test"] = s[last:].count("E") if last >= 0 else -1
        v["turns"] = t.get("turns") or 0
        v["reward"] = t.get("reward")
        v["cls"] = (
            "SP2" if name in SPECIES_2_TASKS
            else "SOLVE" if t.get("reward") == 1.0
            else "OTHER"
        )
        out[name] = v
    return out


def report(rows: dict[str, dict], turn_matched: bool) -> int:
    groups = {c: [v for v in rows.values() if v["cls"] == c] for c in ("SOLVE", "SP2", "OTHER")}
    if not groups["SP2"]:
        print("no species-2 trials in this run; nothing to compare", file=sys.stderr)
        return 1

    if turn_matched:
        lo = min(v["turns"] for v in groups["SP2"])
        hi = max(v["turns"] for v in groups["SP2"])
        groups["SOLVE"] = [v for v in groups["SOLVE"] if lo <= v["turns"] <= hi]
        print(f"# solves restricted to the species-2 turn band [{lo}, {hi}]\n")

    print(f"{'group':8} {'n':>3} " + " ".join(f"{f:>15}" for f in FIELDS))
    for c in ("SP2", "SOLVE", "OTHER"):
        g = groups[c]
        if not g:
            continue
        med = " ".join(f"{statistics.median([r[f] for r in g]):15.1f}" for f in FIELDS)
        print(f"{c:8} {len(g):3} {med}   (median)")

    print(f"\n{'gate':60} {'SP2':>5} {'OTHER':>6} {'SOLVE':>6}  verdict")
    rejected = 0
    for label, fn in GATES.items():
        a = sum(1 for v in groups["SP2"] if fn(v))
        b = sum(1 for v in groups["OTHER"] if fn(v))
        c = sum(1 for v in groups["SOLVE"] if fn(v))
        ok = c == 0 and a > 0
        rejected += 0 if ok else 1
        print(f"{label:60} {a:5} {b:6} {c:6}  {'PASS' if ok else 'REJECTED'}")
    print(f"\n{rejected}/{len(GATES)} gates rejected under the acceptance rule.")
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("run_dir", type=Path,
                    help="a Harbor run directory containing results.json")
    ap.add_argument("--turn-matched", action="store_true",
                    help="restrict solves to the species-2 turn band, so a "
                         "difference cannot be a difference in task length")
    ap.add_argument("--json", type=Path, help="also write the per-trial profiles here")
    args = ap.parse_args(argv)

    run = args.run_dir
    if not (run / "results.json").exists():
        print(f"no results.json under {run}", file=sys.stderr)
        return 2
    repo_root = Path(__file__).resolve().parent.parent
    rows = collect(run, repo_root)
    if not rows:
        print(f"no readable trials under {run}", file=sys.stderr)
        return 2
    if args.json:
        args.json.write_text(json.dumps(rows, indent=1))
    return report(rows, args.turn_matched)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
