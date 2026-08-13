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

import os
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

ARCH = "x86_64"

TEST_BRIDGE = """#!/usr/bin/env bash
# Run the project's own test suite against your current edits.
#
#   ./run_tests.sh                       # run the tests named in the task
#   ./run_tests.sh path/to/test_x.py     # run something specific
#
# Your edits in this directory are live inside the environment; there is no
# build or sync step.
set -uo pipefail
CONTAINER="__CONTAINER__"
if [ "$#" -eq 0 ]; then set -- __DEFAULT_TESTS__; fi
exec docker exec "$CONTAINER" bash -lc \
  "source /opt/miniconda3/bin/activate && conda activate testbed && cd /testbed && __TEST_CMD__ $*"
"""


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
    default_tests: str = "",
    test_cmd: str = "python -m pytest -rA",
) -> PreparedWorkspace:
    """Extract /testbed for one instance and (optionally) bind it back."""
    iid = instance["instance_id"]
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
            .replace("__DEFAULT_TESTS__", default_tests or "")
            .replace("__TEST_CMD__", test_cmd)
        )
        bridge.chmod(0o755)
        # run_tests.sh is harness scaffolding, never part of the patch.
        exclude = dest / ".git" / "info" / "exclude"
        exclude.parent.mkdir(parents=True, exist_ok=True)
        with exclude.open("a") as fh:
            fh.write("\nrun_tests.sh\nAGENT_TASK.md\n")

    return PreparedWorkspace(instance_id=iid, path=dest, container=container)
