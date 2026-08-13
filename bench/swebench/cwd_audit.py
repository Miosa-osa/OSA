#!/usr/bin/env python3
"""Audit whether `shell_execute` actually ran in the session's `working_dir`.

FINDINGS.md #1, at scale.

The report there is from SWE-bench Pro: on 4 of 12 instances `pwd` returned the
backend's boot directory rather than the workspace, and the `git log` calls
therefore read OSA's own history instead of the task repo's. The mechanism was
never established, and the isolating probe died on an unrelated ETS error. So
this looks for the same fingerprint in the one place where it can be observed
without a new probe: the recorded SSE streams of a 500-instance run.

WHY THIS IS A FAIR TEST AND NOT A FISHING TRIP
----------------------------------------------
Every instance's workspace path is known, and it is unique per instance. If
`shell_execute` honours `working_dir`, then:

  * `pwd` prints that path (or `/testbed`, which the bind mount makes the same
    files inside the test container);
  * a relative `ls`/`cat` of a file that exists in the workspace succeeds;
  * `git log` shows the *task repo's* commits, not OSA's.

Each of those has a negation that is checkable from the stream alone, and each
negation is recorded separately, because "the agent chose to cd somewhere" and
"the tool ignored working_dir" produce different evidence:

  cwd_outside_workspace   a pwd result outside the workspace AND no preceding
                          `cd` in the same command. This is the finding.
  cwd_after_explicit_cd   same, but the command contains its own `cd`. Not a
                          defect -- the agent asked for it.
  foreign_git_history     `git log`/`git status` output naming OSA's own repo.
  relative_path_enoent    a relative path failed with ENOENT while the same
                          path exists in the workspace on disk. The strongest
                          indirect evidence, because it cannot be explained by
                          the agent's choices.

A clean result here does NOT close FINDINGS #1 for SWE-bench Pro -- different
harness, different container arrangement. It does establish whether Verified at
n=500 reproduces it.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent

_SHELLY = ("shell_execute", "repl", "pty", "bash_output")
#: An absolute path on a line by itself -- what `pwd` prints.
_ABS_LINE = re.compile(r"^(/[^\s\0]*)\s*$", re.MULTILINE)
_HAS_PWD = re.compile(r"(^|[;&|]|\s)pwd(\s|$|[;&|])")
_HAS_CD = re.compile(r"(^|[;&|]|\s)cd\s")
_ENOENT = re.compile(
    r"(?:cannot access|No such file or directory|can't open file|not found):?\s*'?\"?([^\s'\"]+)"
)
#: Strings that only appear in OSA's own tree, never in a SWE-bench task repo.
_OSA_MARKERS = ("optimal_system_agent", "osa/OSA", "mix.exs", "priv/rust/tui")


def _cmd_of(ev: dict) -> str:
    args = ev.get("args") or ev.get("arguments") or ev.get("input") or {}
    if isinstance(args, dict):
        return str(args.get("command") or args.get("code") or "")
    return str(args)


def audit_log(event_log: Path, workspace: Path) -> dict:
    """Audit one instance's stream. `workspace` is its prepared host directory.

    The directory need not still EXIST -- runs delete their workspaces unless
    `--keep-workspaces` was passed, and an early version of this audit treated a
    missing directory as "no workspace path known", which made every `pwd` look
    like a violation and produced a false positive on `pylint-dev__pylint-4661`
    whose `pwd` was in fact correct. The path is a string comparison; only the
    ENOENT cross-check needs the files to be there.
    """
    findings: dict[str, list] = {
        "cwd_outside_workspace": [],
        "cwd_after_explicit_cd": [],
        "foreign_git_history": [],
        "relative_path_enoent": [],
    }
    counts = Counter()
    cmd_by_call: dict[str, str] = {}
    # One shell call surfaces its output TWICE -- once as `tool_result` and once
    # as `command_output_delta`. Counting both double-reports every finding, so
    # each (call_id, bucket) is recorded once.
    charged: set[tuple[str, str]] = set()

    def charge(bucket: str, call: str | None) -> bool:
        key = (call or "", bucket)
        if key in charged:
            return False
        charged.add(key)
        return True

    ws = str(workspace)
    ws_files = workspace.is_dir()

    def in_workspace(p: str) -> bool:
        # `/testbed` is the container's view of the very same inodes via the
        # bind mount, so it is the workspace by another name and must not be
        # reported as a violation.
        return p.startswith("/testbed") or p.startswith(ws)

    try:
        lines = event_log.read_text(errors="replace").splitlines()
    except OSError:
        return {"error": f"unreadable: {event_log}"}

    for line in lines:
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(ev, dict):
            continue
        etype = ev.get("type") or ev.get("_event")
        name = ev.get("name") or ev.get("tool")
        call_id = ev.get("tool_call_id")

        if etype == "tool_call" and name in _SHELLY and ev.get("phase") == "start":
            cmd = _cmd_of(ev)
            if call_id:
                cmd_by_call[call_id] = cmd
            counts["shell_commands"] += 1
            if ws in cmd:
                counts["commands_using_absolute_workspace_path"] += 1
            if _HAS_CD.search(cmd):
                counts["commands_with_explicit_cd"] += 1
            continue

        if etype not in ("tool_result", "command_output_delta"):
            continue
        out = str(ev.get("result") or ev.get("chunk") or ev.get("tail") or "")
        if not out:
            continue
        cmd = cmd_by_call.get(call_id, str(ev.get("command") or ""))

        if _HAS_PWD.search(cmd):
            for m in _ABS_LINE.finditer(out[:2000]):
                p = m.group(1)
                bucket = (
                    "pwd_in_workspace" if in_workspace(p)
                    else "cwd_after_explicit_cd" if _HAS_CD.search(cmd)
                    else "cwd_outside_workspace"
                )
                if charge(bucket, call_id):
                    counts[bucket] += 1
                    if bucket != "pwd_in_workspace":
                        findings[bucket].append({"command": cmd[:200], "pwd": p})
                break

        if ("git " in cmd and any(mk in out for mk in _OSA_MARKERS)
                and charge("foreign_git_history", call_id)):
            counts["foreign_git_history"] += 1
            findings["foreign_git_history"].append(
                {"command": cmd[:200], "excerpt": out[:300]}
            )

        # A relative path that failed with ENOENT while it exists on disk in the
        # workspace can only mean the command did not run where it was told to.
        if ws_files:
            for m in _ENOENT.finditer(out[:4000]):
                p = m.group(1).strip("'\"")
                if p.startswith("/") or not p:
                    continue
                try:
                    exists = (workspace / p).exists()
                except OSError:
                    exists = False
                if exists and charge("relative_path_enoent", call_id):
                    counts["relative_path_enoent"] += 1
                    findings["relative_path_enoent"].append(
                        {"command": cmd[:200], "path": p}
                    )
                    break

    return {"counts": dict(counts), "findings": {k: v for k, v in findings.items() if v}}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run", help="a run directory with logs/ (merged or per-wave)")
    ap.add_argument("--wave-runs", nargs="*", default=None,
                    help="per-wave run dirs to scan instead (a merged dir has no logs/)")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()

    roots = [Path(r) for r in (a.wave_runs or [a.run])]
    per_instance = {}
    for root in roots:
        if not root.is_absolute():
            root = HERE / root
        for log in sorted((root / "logs").glob("*.jsonl")):
            iid = log.name.split(".")[0]
            per_instance[iid] = audit_log(log, root / "workspaces" / iid)

    total = Counter()
    flagged = {}
    for iid, r in per_instance.items():
        for k, v in (r.get("counts") or {}).items():
            total[k] += v
        if r.get("findings"):
            flagged[iid] = r

    out = {
        "instances_scanned": len(per_instance),
        "instances_flagged": len(flagged),
        "totals": dict(total),
        "flagged": flagged,
    }
    if a.json:
        print(json.dumps(out, indent=2))
        return 0

    print(f"scanned {out['instances_scanned']} instance stream(s); "
          f"{out['instances_flagged']} flagged")
    for k, v in sorted(total.items()):
        print(f"  {k}: {v}")
    if not flagged:
        print("\nNo evidence that shell_execute ignored the session working_dir.")
        print("That is weaker than 'it never happens': it means this run's "
              "recorded streams contain no instance of the fingerprint.")
    for iid, r in list(flagged.items())[:20]:
        print(f"\n-- {iid}")
        for bucket, hits in r["findings"].items():
            print(f"   {bucket} x{len(hits)}")
            for h in hits[:2]:
                print(f"     {h}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
