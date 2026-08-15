#!/usr/bin/env python3
"""Did our own test-file policy put a pass at risk on any graded task?

## What happened

`docs/research/failure-taxonomy.md` species 6: OSA's verification gate told the
model to write a **persisted** test file, the model complied, and on
`polyglot-c-py` and `polyglot-rust-c` the test landed beside the deliverable in
a directory whose verifier asserts its exact contents:

    polyglot_files = os.listdir("/app/polyglot")
    assert polyglot_files == ["main.rs"], f"Expected only main.rs, found: {polyglot_files}"

Replayed over the full-89 TB 2.0 run, **12 trials wrote a test artefact into a
directory the instruction names as a deliverable, and 10 of them were solves**.
The ten survived because their verifiers do not inspect directory contents.
That is luck, not correctness, and the open question this file answers is:
**would any of the ten have failed a stricter grader?**

The gate now relocates tests to `/tmp/osa-tests/`, so this is a question about
the recorded results, not about future runs. It still has to be answered,
because a conditional pass that is not marked is a pass that gets quoted.

## How the question is made answerable

"Stricter grader" is not a feeling. The only stricter grader that has ever
existed on this benchmark is the polyglot one, and its rule is exact:

    the directory holding the single named deliverable must contain
    ONLY that deliverable.

A grader can only fail on an artefact it can SEE, so for each trial this scans:

  * every path the agent wrote (`written_paths`),
  * which of those are test artefacts outside `/tmp` (`is_test_artefact`),
  * which directories the task's OWN verifier enumerates, resolved to absolute
    paths (`enumerated_dirs`) — read from the task copy on disk, not assumed,
  * whether any artefact sits inside one of them.

A trial is `CONDITIONAL` only when an artefact is reachable that way, or
`CONDITIONAL-UNRESOLVED` when the verifier enumerates a path this reader cannot
resolve (fail closed). Everything else is `polluted-ungraded`. That distinction
is the whole point: marking every polluted trial conditional would be as wrong
as marking none.

Note this uses a WIDER pollution criterion than the taxonomy's twelve — any test
artefact anywhere outside `/tmp`, not only ones beside a named deliverable — so
its raw pollution count is larger by construction and is not a correction to
that figure.

## Known limitations, because they bound the answer

  * **`args` is clipped.** OSA's `tool_call.args` is a display hint. Measured
    over this run: faithful on 181 of 3,796 tool calls (4.8%, all `file_edit`);
    `shell_execute` is truncated at exactly 60 characters on 1,682 of 1,954
    calls (86%). So a file created by a shell redirect past column 60 is
    invisible here. `unparseable` counts those instead of pretending they are
    absent — this scanner reports what it could not see. Same root cause as D8.
  * **Container start contents are read from the Dockerfile, not observed.** A
    `RUN` that generates files (`chess-best-move` runs `make.py`) is counted as
    "produces unknown extra files", which is the safe direction: it can only
    move a task OUT of the exclusive-directory class, never into it.

USE
---
    ./pollution_recheck.py scan runs/osa-tb20-full89-f6981b61/harbor/<job>
    ./pollution_recheck.py scan <job> --json
    ./pollution_recheck.py stamp runs/osa-tb20-full89-f6981b61
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import datasets as datasets_mod  # noqa: E402

#: A written path is a test artefact if its basename looks like one. Deliberately
#: generous on the prefix side and anchored on the extension side: `test.txt` as
#: a DELIVERABLE would be a false positive, and no task in the set has one.
_TEST_NAME = re.compile(
    r"^(test_|tests_|check_|verify_|run_test|test)", re.IGNORECASE
)

#: Directories that are scratch by construction. An artefact here is the
#: behaviour the fixed gate prescribes, not a finding.
_SCRATCH_PREFIXES = ("/tmp/", "/var/tmp/", "/dev/")

#: Tool calls whose first argument is the path they write.
_PATH_ARG_TOOLS = ("file_write", "file_transform")

#: Enumeration primitives. A verifier containing any of these can see the
#: contents of a directory and can therefore fail on an artefact it did not
#: expect. Grepped from the task copy rather than listed here, because the list
#: has to stay true of the dataset actually on disk.
_ENUMERATORS = re.compile(
    r"os\.listdir|\.iterdir\(|os\.scandir|glob\.glob|\.glob\(|os\.walk|\.rglob\("
)


def _events(trial_dir: Path):
    p = trial_dir / "agent" / "osa-events.jsonl"
    if not p.exists():
        return
    with p.open() as fh:
        for line in fh:
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def written_paths(trial_dir: Path) -> tuple[list[str], int]:
    """(absolute paths the agent wrote, count of calls we could not read).

    The second element is not decoration. `args` is truncated at 60 characters
    on most `shell_execute` calls, so a `... > /app/out.txt` past that column is
    simply not in the record. Returning the count makes the blind spot part of
    the finding instead of a silent zero.
    """
    paths: list[str] = []
    unreadable = 0
    for r in _events(trial_dir):
        if r.get("type") != "tool_call" or r.get("phase") != "start":
            continue
        name = r.get("name") or ""
        args = r.get("args")
        if not isinstance(args, str) or not args:
            continue
        truncated = (
            r.get("args_bytes") is not None and r["args_bytes"] != len(args)
        )
        if name in _PATH_ARG_TOOLS:
            # The whole argument IS the path for these, and it is only
            # truncated if the path itself exceeds the clip.
            if args.startswith("/"):
                paths.append(args)
            continue
        if name == "file_edit":
            # Faithful JSON on this tool; the path is a field.
            try:
                obj = json.loads(args)
            except json.JSONDecodeError:
                unreadable += 1
                continue
            p = obj.get("path") or obj.get("file_path")
            if isinstance(p, str) and p.startswith("/"):
                paths.append(p)
            continue
        if name in ("shell_execute", "bash_execute"):
            for m in re.finditer(r"(?:>>?|\btee\s+)\s*([^\s;|&]+)", args):
                cand = m.group(1)
                if cand.startswith("/"):
                    paths.append(cand)
            if truncated:
                unreadable += 1
    return paths, unreadable


def is_test_artefact(path: str) -> bool:
    return bool(_TEST_NAME.match(Path(path).name))


#: `os.listdir(X)` / `os.walk(X)` / `X.glob(...)` -- capture the receiver or
#: argument token so it can be resolved to a path.
_ENUM_SITE = re.compile(
    r"(?:os\.listdir|os\.walk|os\.scandir|glob\.glob)\(\s*([A-Za-z_][\w.]*|[\"'][^\"']*[\"'])"
    r"|([A-Za-z_][\w.]*)\s*\.\s*(?:glob|rglob|iterdir)\("
)
#: A module-level constant bound to a string or f-string literal. Only the part
#: before the first `{` is usable, which is enough: `/app/c4_test_{uuid}/`
#: resolves to the prefix `/app/c4_test_`, and that is all a containment test
#: needs.
_CONST = re.compile(r"^([A-Z_][A-Z0-9_]*)\s*=\s*f?[\"']([^\"'{]*)", re.M)


def enumerated_dirs(task_dir: Path) -> tuple[set[str], int]:
    """(absolute directories this task's verifier enumerates, unresolved sites).

    WHY THIS IS NOT JUST "does the verifier call listdir".

    The coarse question over-flags badly. `reshard-c4-data` calls both
    `os.walk` and `os.listdir`, and a coarse scan therefore marks its solve
    CONDITIONAL -- but both calls target `TEST_OUTPUT_DIR`, which the module
    defines as `f"/app/c4_test_{uuid.uuid4()}/"`, a directory **the verifier
    creates during its own run**. The agent's artefact at `/app/tests/` is not
    reachable from it, and calling that pass conditional would be as wrong as
    calling the polyglot ones fine.

    Unresolved sites are counted, not ignored, and the caller treats them as
    conditional. `filter-js-from-html` enumerates
    `testcases_path = download_attack_vectors()`, a local bound to a call: this
    reader cannot say where it points, so it must not say it is safe.
    """
    dirs: set[str] = set()
    unresolved = 0
    tests = task_dir / "tests"
    if not tests.is_dir():
        return dirs, unresolved
    for f in tests.rglob("*.py"):
        try:
            src = f.read_text(errors="replace")
        except OSError:
            continue
        consts = {m.group(1): m.group(2) for m in _CONST.finditer(src)}
        for m in _ENUM_SITE.finditer(src):
            token = m.group(1) or m.group(2) or ""
            if token[:1] in ("'", '"'):
                val = token[1:-1]
            else:
                val = consts.get(token.split(".")[0], "")
            if val.startswith("/"):
                dirs.add(val.rstrip("/") or "/")
            else:
                unresolved += 1
    return dirs, unresolved


def enumerating_tasks(ds) -> set[str]:
    """Tasks in `ds` whose own verifier can see a directory listing at all.

    The coarse set, kept for the summary line. TB 2.0 has ten and TB 2.1 has
    nine, and that difference is the finding -- see `polyglot_rule_retracted`.
    """
    out: set[str] = set()
    if not ds.present:
        return out
    for tests in ds.path.glob("*/tests"):
        for f in tests.rglob("*.py"):
            try:
                if _ENUMERATORS.search(f.read_text(errors="replace")):
                    out.add(tests.parent.name)
                    break
            except OSError:
                continue
    return out


def polyglot_rule_retracted() -> dict:
    """Did upstream keep the exclusive-listing assertion in Terminal-Bench 2.1?

    It did not, and this reads the answer off the task copies rather than
    asserting it. TB 2.1's `polyglot-rust-c` verifier now says, verbatim:

        # Check that main.rs exists (dont require it to be the only file
        # -- compilation may leave binaries)

    and `polyglot-c-py`'s says the task description allows compiling to
    `/app/polyglot/cmain`, "so we allow additional files like compiled binaries
    to exist". That is upstream classifying its own assertion as a task bug: the
    instruction's own example command writes a binary into the directory the
    assertion required to hold one file.

    Which means the stricter grader this whole question is measured against
    **does not exist any more**, and species 6 is a TB 2.0 artefact.
    """
    out = {}
    for key in ("tb2.0", "tb2.1"):
        ds = datasets_mod.DATASETS[key]
        for task in ("polyglot-c-py", "polyglot-rust-c"):
            f = ds.path / task / "tests" / "test_outputs.py"
            if not f.exists():
                out[f"{key}/{task}"] = None
                continue
            src = f.read_text(errors="replace")
            out[f"{key}/{task}"] = bool(
                re.search(r"polyglot_files\s*==\s*\[", src)
            )
    return out


def scan(job_dir: Path, dataset_key: str) -> dict:
    ds = datasets_mod.get(dataset_key)
    enumerating = enumerating_tasks(ds)
    rows = []
    for trial in sorted(job_dir.glob("*__*")):
        rp = trial / "result.json"
        if not rp.is_file():
            continue
        try:
            res = json.loads(rp.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        task = (res.get("task_name") or trial.name.split("__")[0]).split("/")[-1]
        reward = (res.get("verifier_result") or {}).get("rewards", {}).get("reward")
        paths, unreadable = written_paths(trial)
        artefacts = [
            p
            for p in dict.fromkeys(paths)
            if is_test_artefact(p) and not p.startswith(_SCRATCH_PREFIXES)
        ]
        enumerated = task in enumerating
        seen_dirs, unresolved = enumerated_dirs(ds.path / task)
        # An artefact is REACHABLE by the grader when it sits inside a directory
        # the verifier actually enumerates. Prefix containment, because a
        # resolved value may be an f-string prefix (`/app/c4_test_`).
        reached = sorted(
            p
            for p in artefacts
            if any(str(Path(p).parent).startswith(d) for d in seen_dirs)
        )
        if not artefacts:
            verdict = "clean"
        elif reached:
            verdict = "CONDITIONAL"
        elif enumerated and unresolved:
            # Fail closed. The verifier enumerates something this reader cannot
            # resolve, so "not reachable" is not a statement it has earned.
            verdict = "CONDITIONAL-UNRESOLVED"
        else:
            verdict = "polluted-ungraded"
        rows.append(
            {
                "task": task,
                "trial": trial.name,
                "reward": reward,
                "resolved": bool(reward is not None and reward >= 1.0),
                "test_artefacts_in_workspace": artefacts,
                "verifier_enumerates_a_directory": enumerated,
                "verifier_enumerated_dirs": sorted(seen_dirs),
                "verifier_unresolved_enumerations": unresolved,
                "artefacts_the_grader_could_see": reached,
                "unreadable_tool_calls": unreadable,
                "verdict": verdict,
            }
        )
    polluted = [r for r in rows if r["verdict"] != "clean"]
    return {
        "job_dir": str(job_dir),
        "dataset_key": dataset_key,
        "n_trials": len(rows),
        "n_polluted": len(polluted),
        "n_polluted_solves": sum(1 for r in polluted if r["resolved"]),
        "n_conditional": sum(1 for r in rows if r["verdict"].startswith("CONDITIONAL")),
        "n_conditional_solves": sum(
            1 for r in rows if r["verdict"].startswith("CONDITIONAL") and r["resolved"]
        ),
        "enumerating_tasks": sorted(enumerating),
        "polyglot_exclusive_listing_still_asserted": polyglot_rule_retracted(),
        "rows": rows,
    }


def cmd_scan(args) -> int:
    out = scan(Path(args.job_dir), args.dataset_key)
    if args.json:
        print(json.dumps(out, indent=2))
        return 0
    print(f"{out['n_trials']} trial(s), dataset {out['dataset_key']}")
    print(f"{out['n_polluted']} wrote a test artefact into the workspace "
          f"({out['n_polluted_solves']} of them solves)")
    print(f"{out['n_conditional']} of those are CONDITIONAL — the artefact sits "
          f"where the task's own verifier can see it "
          f"({out['n_conditional_solves']} of them SOLVES)")
    print()
    print(f"{'task':38s} {'reward':>7s} {'enum':>5s}  verdict / artefacts")
    for r in out["rows"]:
        if r["verdict"] == "clean":
            continue
        print(f"{r['task']:38s} {str(r['reward']):>7s} "
              f"{'yes' if r['verifier_enumerates_a_directory'] else 'no':>5s}  "
              f"{r['verdict']}: {', '.join(r['test_artefacts_in_workspace'])}")
    print()
    print("Terminal-Bench 2.1 still asserts the exclusive listing?")
    for k, v in out["polyglot_exclusive_listing_still_asserted"].items():
        print(f"  {k:34s} {v}")
    return 0


def cmd_stamp(args) -> int:
    """Write the verdict into a run's `results.json` rows.

    A conditional pass that lives only in an analysis nobody re-runs is a
    conditional pass that gets quoted. `report.py` already marks non-conforming
    task copies `void` for the same reason; this is the same discipline applied
    to a risk the grader happened not to check.
    """
    run_dir = Path(args.run)
    rj = run_dir / "results.json"
    doc = json.loads(rj.read_text())
    key = (doc.get("config") or {}).get("dataset_key") or args.dataset_key
    job = Path((doc.get("config") or {}).get("job_dir") or "")
    if not job.is_dir():
        raise SystemExit(f"job_dir from {rj} is not a directory: {job}")
    out = scan(job, key)
    by_task = {r["task"]: r for r in out["rows"]}
    n = 0
    for row in doc.get("tasks") or []:
        f = by_task.get((row.get("task_name") or "").split("/")[-1])
        if not f or f["verdict"] == "clean":
            continue
        row["deliverable_pollution"] = {
            "artefacts": f["test_artefacts_in_workspace"],
            "verifier_enumerates_a_directory": f["verifier_enumerates_a_directory"],
            "verdict": f["verdict"],
            "note": (
                "OSA's verification gate asked for a PERSISTED test file and it "
                "landed in the graded workspace. This grader does not inspect "
                "directory contents, so the result stands; the marker records "
                "that it was not tested against one."
                if f["verdict"] == "polluted-ungraded"
                else "CONDITIONAL: the artefact sits where this task's verifier "
                "can see it (or the verifier enumerates a path this reader "
                "could not resolve). Re-check before quoting."
            ),
        }
        n += 1
    rj.write_text(json.dumps(doc, indent=2) + "\n")
    print(f"stamped {n} row(s) in {rj}")
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("scan")
    p.add_argument("job_dir")
    p.add_argument("--dataset-key", default="tb2.0", choices=list(datasets_mod.ORDER))
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_scan)
    p = sub.add_parser("stamp")
    p.add_argument("run")
    p.add_argument("--dataset-key", default="tb2.0", choices=list(datasets_mod.ORDER))
    p.set_defaults(fn=cmd_stamp)
    args = ap.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
