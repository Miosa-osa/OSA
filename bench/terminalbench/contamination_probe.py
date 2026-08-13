#!/usr/bin/env python3
"""Check that a task container does not ship the answer.

WHY THIS EXISTS
---------------
Every published SWE-bench Pro image contains `/app/.git` with the fix commit
still reachable: `git show <fix_commit>` returns the gold patch verbatim, with
the network off, and the fix SHA is the tail of the instance_id. An agent does
not have to be clever or dishonest to find that — it has to run `git log`.

The uncomfortable part is that **no network control touches it**. A harness can
be airgapped, probe-verified, and still measure nothing, because the leak is
inside the image rather than outside it. Our own airgap probe would have passed
and produced a confidently wrong number.

So contamination is checked the same way egress is: by probing a live container,
not by assuming. This probe is the Terminal-Bench / Recovery-Bench counterpart
of the `/app/.git` scrub in `bench/swebenchpro/workspace.py`.

RESULT AT THE TIME OF WRITING
-----------------------------
Probed against a live `terminal-bench-2` task container
(`schemelike-metacircular-eval`): no `solution/`, no `solve.sh` anywhere in the
top four directory levels, no `/app/.git`. Terminal-Bench task images do not
ship their solutions, and Recovery-Bench inherits that because it runs on the
same Harbor task set.

That is a NEGATIVE result and it is worth keeping. "We checked and it was clean"
and "we never checked" produce identical numbers right up until they don't.

USAGE
-----
    python3 contamination_probe.py <container-name>
    python3 contamination_probe.py --all      # every running __env-main-1

Exit codes: 0 clean, 1 contaminated, 2 could not probe.
"""

from __future__ import annotations

import subprocess
import sys

# Paths that would hand an agent the answer outright.
SOLUTION_PATHS = ("/solution", "/app/solution", "/tests", "/app/tests")

# A reachable git history is the SWE-bench Pro failure mode: the fix commit sits
# in the repo the agent is asked to edit.
GIT_PATHS = ("/app/.git", "/testbed/.git", "/workspace/.git")

PROBE = r"""
found=0
for p in {solution_paths}; do
  [ -e "$p" ] && { echo "LEAK path $p"; found=1; }
done
hits=$(find / -maxdepth 4 -name 'solve.sh' -o -maxdepth 4 -name 'solution.patch' 2>/dev/null | head -5)
[ -n "$hits" ] && { echo "LEAK solve-script"; echo "$hits"; found=1; }
for g in {git_paths}; do
  if [ -d "$g" ]; then
    # A git dir is only a leak if it can still reach commits the agent should
    # not see. An empty repo with one ref is how a scrubbed workspace looks.
    n=$(git --git-dir="$g" rev-list --all --count 2>/dev/null || echo 0)
    r=$(git --git-dir="$g" remote 2>/dev/null | wc -l)
    echo "GIT $g commits=$n remotes=$r"
    [ "$n" -gt 1 ] && found=1
    [ "$r" -gt 0 ] && found=1
  fi
done
exit $found
"""


def probe(container: str) -> int:
    # str.replace, not str.format: the probe is shell, and shell braces
    # ("{ echo ...; }") are not format placeholders.
    script = PROBE.replace("{solution_paths}", " ".join(SOLUTION_PATHS)).replace(
        "{git_paths}", " ".join(GIT_PATHS)
    )
    try:
        proc = subprocess.run(
            ["docker", "exec", container, "bash", "-c", script],
            capture_output=True,
            text=True,
            timeout=120,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError) as exc:
        print(f"{container}: COULD NOT PROBE ({exc})")
        return 2

    output = (proc.stdout + proc.stderr).strip()
    if proc.returncode == 0:
        print(f"{container}: CLEAN")
        if output:
            print(f"  {output}")
        return 0

    print(f"{container}: CONTAMINATED")
    for line in output.splitlines():
        print(f"  {line}")
    return 1


def running_task_containers() -> list[str]:
    proc = subprocess.run(
        ["docker", "ps", "--format", "{{.Names}}"],
        capture_output=True,
        text=True,
        check=False,
    )
    return [n for n in proc.stdout.split() if n.endswith("__env-main-1")]


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__)
        return 2

    targets = running_task_containers() if argv[1] == "--all" else [argv[1]]
    if not targets:
        print("no running task containers to probe")
        return 2

    return max(probe(c) for c in targets)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
