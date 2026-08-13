"""Materialise a SWE-bench instance as a host workspace the agent can edit.

Why this shape:

SWE-bench instance images ship the repo already installed (editable) at
/testbed inside a conda env. OSA is an Elixir application that runs on the
host, not something we can reasonably install into 500 different task images.
So we invert it:

  1. copy /testbed out of the instance image onto the host,
  2. start a container from that same image with the *host* directory
     bind-mounted back over /testbed.

The agent edits plain files on the host; the container still has the fully
installed environment pointing at those same inodes. That gives the agent a
real "run the project's tests" capability (bench/swebench/run_tests.sh, dropped
into the workspace) without putting OSA inside the image.

Scoring never uses this container. Grading is done afterwards by the official
swebench harness in its own fresh container, from the extracted patch only.
"""

from __future__ import annotations

import json
import os
import re
import shlex
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

ARCH = "x86_64"

TEST_BRIDGE = """#!/usr/bin/env bash
# Run the project's own test suite against your current edits.
#
#   ./run_tests.sh <test id> [<test id> ...]
#
# This repository's own test runner is:
#     __TEST_CMD__
# Pass test ids in whatever form THAT runner expects -- it is not always pytest.
#
# Your edits in this directory are live inside the environment; there is no
# build or sync step.
set -uo pipefail
CONTAINER="__CONTAINER__"
if [ "$#" -eq 0 ]; then
  __NO_ARGS_ACTION__
fi
exec docker exec "$CONTAINER" bash -lc \
  "source /opt/miniconda3/bin/activate && conda activate testbed && cd /testbed && __TEST_CMD__ $*"
"""


#: Fallback when the official spec map has no row for this repo/version.
FALLBACK_TEST_CMD = "python -m pytest -rA"


def test_command_for(instance: dict) -> str:
    """The repo's *real* test command, taken from the official swebench specs.

    Hardcoding `python -m pytest` here was wrong for a large part of SWE-bench
    Verified: `django/django` (231 of the 500 instances) uses
    `./tests/runtests.py --settings=test_sqlite` with dotted module paths,
    `sympy` uses `bin/test`, `sphinx` uses `tox`. Grading is unaffected -- the
    grader builds its own command from this same table -- but the agent's own
    ability to check its work is not, and an agent that cannot run the suite is
    measurably worse at this benchmark.

    Reading `MAP_REPO_VERSION_TO_SPECS` rather than maintaining a parallel table
    means the bridge and the grader cannot drift apart.
    """
    try:
        from swebench.harness.constants import MAP_REPO_VERSION_TO_SPECS
    except ImportError:  # pragma: no cover - swebench is a hard dependency
        return FALLBACK_TEST_CMD
    specs = MAP_REPO_VERSION_TO_SPECS.get(instance.get("repo", ""), {})
    row = specs.get(str(instance.get("version", "")))
    if not row:
        # Unknown version: any row for this repo beats pytest, since the test
        # runner rarely changes across a single repo's versions.
        row = next(iter(specs.values()), None)
    if not row:
        return FALLBACK_TEST_CMD
    return row.get("test_cmd") or FALLBACK_TEST_CMD


#: Shown when the agent runs `./run_tests.sh` with no arguments and we are not
#: handing it the FAIL_TO_PASS ids. Running a whole repo suite (django, sympy)
#: costs many minutes and would burn the agent's budget for nothing.
NO_DEFAULT_TESTS_MSG = (
    "  echo 'Name the test(s) to run, e.g. ./run_tests.sh <test id>. "
    "See the header of this file for the form this repository expects.' >&2\n"
    "  exit 2"
)


def default_test_args(instance: dict) -> str:
    """FAIL_TO_PASS ids rewritten into the form this repo's runner accepts.

    Only used when the caller explicitly asks for the hint (see
    `run_bench.py --f2p-hint`). It is off by default because handing the agent
    the exact names of the hidden tests is a real advantage that leaderboard
    agents do not get, and a benchmark that quietly flatters is worthless.
    """
    try:
        ids = json.loads(instance["FAIL_TO_PASS"])
    except (json.JSONDecodeError, KeyError, TypeError):
        return ""
    if not isinstance(ids, list):
        return ""

    out = []
    for raw in ids[:10]:
        i = str(raw)
        if instance.get("repo") == "django/django":
            # Django ids arrive as either "test_x (a.b.CTests)" or
            # "a.b.CTests.test_x"; runtests.py wants the dotted form.
            m = re.match(r"^(\S+)\s+\(([^)]+)\)\s*$", i)
            if m:
                i = f"{m.group(2)}.{m.group(1)}"
            i = i[len("tests.") :] if i.startswith("tests.") else i
        out.append(shlex.quote(i))
    if not out:
        return NO_DEFAULT_TESTS_MSG
    return "  set -- " + " ".join(out)


#: Tools that can fetch the published upstream fix for a SWE-bench instance.
#: The prompt names the repo and the exact base commit, so a single web search
#: can return the answer. The official submission checklist requires that this
#: be impossible, and Epoch runs airgapped for the same reason.
NETWORK_TOOLS = ("web_search", "web_fetch", "download", "browser", "github")

#: A PreToolUse hook that exits 2 -- the protocol's "deny, stderr is the
#: reason" -- written into the workspace's `.osa/settings.local.json`.
#:
#: VERIFIED NOT TO WORK, and therefore OFF by default. The theory was sound:
#: `local` is the one settings layer read from the agent's cwd that is not
#: gated on workspace trust. The measurement says otherwise. Probing a live
#: backend with this file installed and `working_dir` pointed at the workspace,
#: `web_search` executed normally and returned results.
#:
#: Root cause, in OSA rather than here: `Settings.layer(:local)` resolves its
#: path through `Workspace.Cwd.get()`, which is process-global. The per-request
#: `working_dir` on `/api/v1/orchestrate` does not move it, so a per-session
#: policy file cannot be honoured no matter where it is placed.
#:
#: Kept in the tree because it is the right shape once OSA can scope settings
#: per session, and because a documented negative result stops the next person
#: re-deriving it. Do not turn it on believing it airgaps anything.
AIRGAP_HOOK = """#!/usr/bin/env bash
# Deny every tool that can reach the public internet, for the duration of one
# benchmark instance. The fix for this issue is a published commit; an agent
# that can retrieve it is not being measured on problem-solving.
echo "Network access is disabled for this benchmark task. Solve the issue from \
the repository contents alone." >&2
exit 2
"""


def write_airgap(dest: Path) -> dict:
    """Install the network-tool deny hook into a prepared workspace.

    Returns the settings fragment actually written, so the run record can state
    what was enforced rather than asserting it.
    """
    osa_dir = dest / ".osa"
    osa_dir.mkdir(parents=True, exist_ok=True)
    hook = osa_dir / "deny-network.sh"
    hook.write_text(AIRGAP_HOOK)
    hook.chmod(0o755)

    settings = {
        "hooks": {
            "PreToolUse": [
                {
                    "matcher": "|".join(NETWORK_TOOLS),
                    "hooks": [
                        {"type": "command", "command": str(hook.resolve()),
                         "timeout": 10}
                    ],
                }
            ]
        }
    }
    (osa_dir / "settings.local.json").write_text(json.dumps(settings, indent=2))
    return settings


def instance_image(instance_id: str, namespace: str = "swebench", tag: str = "latest") -> str:
    """Mirror of swebench.harness.test_spec.TestSpec.instance_image_key."""
    key = f"sweb.eval.{ARCH}.{instance_id.lower()}:{tag}"
    if namespace:
        key = f"{namespace}/{key}".replace("__", "_1776_")
    return key


def image_present(image: str) -> bool:
    return (
        subprocess.run(
            ["docker", "image", "inspect", image], capture_output=True
        ).returncode
        == 0
    )


def pull_image(image: str) -> None:
    subprocess.run(["docker", "pull", image], check=True)


@dataclass
class PreparedWorkspace:
    instance_id: str
    path: Path
    container: str | None
    #: The airgap settings actually written into this workspace, or None.
    airgap: dict | None = None

    def teardown(self, keep_files: bool = True) -> None:
        if self.container:
            # Hand the bind-mounted files back to the invoking user; the
            # container writes as root.
            subprocess.run(
                [
                    "docker", "exec", self.container, "chown", "-R",
                    f"{os.getuid()}:{os.getgid()}", "/testbed",
                ],
                capture_output=True,
            )
            subprocess.run(["docker", "rm", "-f", self.container], capture_output=True)
            self.container = None
        if not keep_files:
            shutil.rmtree(self.path, ignore_errors=True)


def prepare(
    instance: dict,
    root: Path,
    *,
    namespace: str = "swebench",
    with_container: bool = True,
    f2p_hint: bool = False,
    airgap: bool = False,
    test_cmd: str | None = None,
) -> PreparedWorkspace:
    """Extract /testbed for one instance and (optionally) bind it back.

    `test_cmd` defaults to this repo's real runner (see `test_command_for`);
    pass a string only to override it.
    """
    iid = instance["instance_id"]
    test_cmd = test_cmd or test_command_for(instance)
    default_tests = default_test_args(instance) if f2p_hint else NO_DEFAULT_TESTS_MSG
    image = instance_image(iid, namespace=namespace)
    if not image_present(image):
        pull_image(image)

    dest = root / iid
    shutil.rmtree(dest, ignore_errors=True)
    dest.parent.mkdir(parents=True, exist_ok=True)

    tmp_name = f"bench-extract-{iid.lower().replace('__', '-')}"
    subprocess.run(["docker", "rm", "-f", tmp_name], capture_output=True)
    subprocess.run(
        ["docker", "create", "--name", tmp_name, image], check=True, capture_output=True
    )
    try:
        subprocess.run(
            ["docker", "cp", f"{tmp_name}:/testbed", str(dest)],
            check=True,
            capture_output=True,
        )
    finally:
        subprocess.run(["docker", "rm", "-f", tmp_name], capture_output=True)

    # Guarantee we start from exactly base_commit with a clean tree, so that
    # `git diff` later is precisely "what the agent changed".
    subprocess.run(
        ["git", "checkout", "-f", instance["base_commit"]],
        cwd=dest, check=True, capture_output=True,
    )
    subprocess.run(
        ["git", "reset", "--hard", instance["base_commit"]],
        cwd=dest, check=True, capture_output=True,
    )
    # -e keeps ignored build artifacts (.so, egg-info) that the installed env
    # depends on; we only want stray untracked files gone.
    subprocess.run(["git", "clean", "-fd"], cwd=dest, capture_output=True)
    subprocess.run(
        ["git", "config", "user.email", "bench@osa.local"], cwd=dest, capture_output=True
    )
    subprocess.run(
        ["git", "config", "user.name", "osa-bench"], cwd=dest, capture_output=True
    )

    airgap_settings = write_airgap(dest) if airgap else None

    container = None
    if with_container:
        container = f"bench-run-{iid.lower().replace('__', '-')}"
        subprocess.run(["docker", "rm", "-f", container], capture_output=True)
        subprocess.run(
            [
                "docker", "run", "-d", "--name", container,
                "-v", f"{dest.resolve()}:/testbed",
                "--network", "none",
                image, "tail", "-f", "/dev/null",
            ],
            check=True,
            capture_output=True,
        )
        bridge = dest / "run_tests.sh"
        bridge.write_text(
            TEST_BRIDGE.replace("__CONTAINER__", container)
            .replace("__NO_ARGS_ACTION__", default_tests)
            .replace("__TEST_CMD__", test_cmd)
        )
        bridge.chmod(0o755)
        # run_tests.sh is harness scaffolding, never part of the patch.
        exclude = dest / ".git" / "info" / "exclude"
        exclude.parent.mkdir(parents=True, exist_ok=True)
        with exclude.open("a") as fh:
            fh.write("\nrun_tests.sh\nAGENT_TASK.md\n.osa/\n")

    # Harness scaffolding must never become part of the submitted diff, whether
    # or not a test container was created.
    exclude = dest / ".git" / "info" / "exclude"
    exclude.parent.mkdir(parents=True, exist_ok=True)
    with exclude.open("a") as fh:
        fh.write("\n.osa/\n")

    return PreparedWorkspace(
        instance_id=iid, path=dest, container=container,
        airgap=airgap_settings,
    )
