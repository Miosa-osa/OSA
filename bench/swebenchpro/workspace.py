"""Materialise a SWE-bench Pro instance as a host workspace the agent can edit.

Same inversion as `bench/swebench/workspace.py`, and for the same reason: the
instance environment only exists inside its pinned image (Go toolchain, node
modules, a built virtualenv), and OSA is an Elixir application running on the
host that we are not going to install into 731 different images. So:

  1. copy `/app` out of the instance image onto the host,
  2. start a container from that same image with the *host* directory
     bind-mounted back over `/app`.

The agent edits plain files on the host; the container still has the fully
installed toolchain pointing at those same inodes.

Two differences from the Verified runner worth knowing:

* **The repo lives at `/app`, not `/testbed`.** Pro's images are built by a
  different pipeline.

* **The images set `ENTRYPOINT ["/bin/bash"]`.** Every `docker run` and
  `docker create` here therefore passes `--entrypoint`, or the command lands as
  an argument to bash and does something else entirely. Upstream documents this
  as "Bash runs by default in our images. When running these images, you should
  not manually invoke bash" (scaleapi/SWE-bench_Pro-os#6), and the official
  local-Docker path in `swe_bench_pro_eval.eval_with_docker` overrides it the
  same way.

Scoring never uses this container. Grading is done afterwards by the official
harness in its own fresh container, from the extracted patch only.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

import dataset as ds

#: Where the repository is checked out inside a Pro instance image.
REPO_DIR = "/app"

TEST_BRIDGE = """#!/usr/bin/env bash
# Run this instance's own test files against your current edits.
#
#   ./run_tests.sh <test file> [<test file> ...]
#
# The arguments are test FILE paths, in the form this repository's runner
# expects (this is a {language} project). This is the same runner the graders
# use, so a file that passes here passes there.
#
# Your edits in this directory are live inside the environment; there is no
# build or sync step.
set -uo pipefail
CONTAINER="__CONTAINER__"
if [ "$#" -eq 0 ]; then
__NO_ARGS_ACTION__
fi
exec docker exec "$CONTAINER" /run_script.sh "$@"
"""

#: Shown when the agent runs `./run_tests.sh` with no arguments and we are not
#: handing it `selected_test_files_to_run`. Running a whole repo suite costs
#: many minutes (ansible's runs sanity + units + integration) and would burn the
#: agent's budget for nothing.
NO_DEFAULT_TESTS_MSG = (
    "  echo 'Name the test file(s) to run, e.g. ./run_tests.sh path/to/test_x.py' >&2\n"
    "  exit 2"
)


def image_present(image: str) -> bool:
    return (
        subprocess.run(["docker", "image", "inspect", image], capture_output=True).returncode
        == 0
    )


def pull_image(image: str) -> None:
    subprocess.run(["docker", "pull", image], check=True)


@dataclass
class PreparedWorkspace:
    instance_id: str
    path: Path
    container: str | None
    image: str
    #: Untracked-but-not-ignored files that were already in the image. Recorded
    #: because they are excluded from the patch, and a long list here means the
    #: image ships build output that git does not know about.
    preexisting_untracked: list[str]
    #: Attestation from `strip_future_history`, including the measured
    #: `fix_commit_reachable_after` (which must be False).
    history: dict = field(default_factory=dict)

    def teardown(self, keep_files: bool = True) -> None:
        if self.container:
            # Hand the bind-mounted files back to the invoking user; the
            # container writes as root.
            subprocess.run(
                ["docker", "exec", self.container, "chown", "-R",
                 f"{os.getuid()}:{os.getgid()}", REPO_DIR],
                capture_output=True,
            )
            subprocess.run(["docker", "rm", "-f", self.container], capture_output=True)
            self.container = None
        if not keep_files:
            shutil.rmtree(self.path, ignore_errors=True)


def _git(dest: Path, *args: str, check: bool = False) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", *args], cwd=dest, check=check, capture_output=True, text=True,
        errors="replace",
    )


#: A ref we create at base_commit so that `git gc` has a root to keep. Without
#: it, pruning after deleting every other ref would be free to collect the
#: history we are supposed to keep.
BASE_REF = "bench-base"


def strip_future_history(dest: Path, base_commit: str) -> dict:
    """Remove the solution from the workspace's own git history.

    **This is the single largest information leak in SWE-bench Pro, and it is
    not closed by any network control.**

    Every published instance image ships `/app/.git` complete: the origin
    remote, all 200-odd branch and tag refs, and — because the images were
    built by cloning the repo and checking out the *parent* of the fix — the
    fix commit itself. Measured on
    `instance_flipt-io__flipt-518ec324b66a07fdd95464a5e9ca5fe7681ad8f9`:

        $ git cat-file -t 518ec324b66a07fdd95464a5e9ca5fe7681ad8f9
        commit
        $ git show 518ec324b66a07fdd95464a5e9ca5fe7681ad8f9
        fix(config/cors): use strings.Fields for string to string slice fields

    which is the gold patch, verbatim, from a local command with the network
    off. Upstream knows: issue #93 reports a scanner achieving a 100% success
    rate against the public images, and PR #94 proposes exactly the cleanup
    below across all 731 Dockerfiles. It has been open since 2026-05-05 and is
    unmerged, and the images have not been rebuilt since 2025-10-01, so the
    leak is live in everything on Docker Hub today.

    Deriving the fix commit does not even require search: for most instances it
    is the trailing SHA of the instance_id. We never show the agent the
    instance_id or `before_repo_set_cmd`, but `git log --all` inside the
    workspace was enough on its own.

    What is removed: the origin remote, every ref other than base, the reflog,
    and then every object those made reachable. What is kept: the full ancestry
    of `base_commit`. That distinction is the point -- a real engineer fixing
    this bug would have the project's past, and taking it away would measure
    something other than software engineering. They would not have its future.

    Returns an attestation dict, recorded per instance, because "we stripped
    it" is a claim and `fix_commit_reachable_after` is the measurement.
    """
    before = _git(dest, "rev-list", "--all", "--count").stdout.strip()

    # Keep base_commit rooted before deleting everything else.
    _git(dest, "checkout", "-f", "-B", BASE_REF, base_commit)

    _git(dest, "remote", "remove", "origin")
    # Any other remotes (forks, upstream) go too.
    for remote in _git(dest, "remote").stdout.split():
        _git(dest, "remote", "remove", remote)

    refs = _git(
        dest, "for-each-ref", "--format=%(refname)",
        "refs/heads", "refs/remotes", "refs/tags",
    ).stdout.split()
    doomed = [r for r in refs if r != f"refs/heads/{BASE_REF}"]
    if doomed:
        subprocess.run(
            ["git", "update-ref", "--stdin"], cwd=dest,
            input="".join(f"delete {r}\n" for r in doomed),
            text=True, capture_output=True,
        )

    for stale in ("FETCH_HEAD", "ORIG_HEAD", "MERGE_HEAD"):
        (dest / ".git" / stale).unlink(missing_ok=True)

    _git(dest, "reflog", "expire", "--expire=now", "--all")
    # --prune=now is what actually deletes the objects; without it the fix
    # commit stays readable by SHA even with no ref pointing at it.
    _git(dest, "gc", "--prune=now", "--quiet")

    after = _git(dest, "rev-list", "--all", "--count").stdout.strip()
    return {
        "commits_reachable_before": _int(before),
        "commits_reachable_after": _int(after),
        "remotes_after": _git(dest, "remote").stdout.split(),
        "refs_after": _git(dest, "for-each-ref", "--format=%(refname)").stdout.split(),
    }


def fix_commit_reachable(dest: Path, sha: str) -> bool:
    """Whether `sha` can still be read out of this workspace. Must be False."""
    if not sha:
        return False
    p = _git(dest, "cat-file", "-t", sha)
    return p.returncode == 0 and p.stdout.strip() == "commit"


def _int(s: str) -> int | None:
    try:
        return int(s)
    except (TypeError, ValueError):
        return None


def _untracked_not_ignored(dest: Path) -> list[str]:
    """Files git would add that the image shipped, not the agent.

    `git add -A` skips gitignored paths, so `node_modules/` and friends are
    already safe. What is not safe is an untracked file the repo does *not*
    ignore -- a generated proto stub, say. Left alone it would land in the
    agent's diff on the very first `git add -A`, and be graded as the agent's
    work. We snapshot them at prep time and exclude them by name.
    """
    out = _git(dest, "status", "--porcelain", "--untracked-files=all").stdout
    return sorted(
        line[3:].strip().strip('"')
        for line in out.splitlines()
        if line.startswith("?? ")
    )


def _fix_commit(inst: dict) -> str:
    """The commit that fixed this issue, i.e. the answer.

    Named in `before_repo_set_cmd`'s `git checkout <sha> -- <test files>` line,
    which is how the grader restores the hidden tests. We read it ONLY to
    assert afterwards that it is no longer reachable from the workspace we hand
    the agent; it is never shown to the agent, and neither is the field.
    """
    last = (inst.get("before_repo_set_cmd") or "").strip().split("\n")[-1]
    m = re.search(r"git\s+checkout\s+([0-9a-f]{6,40})\s+--", last)
    return m.group(1) if m else ""


def prepare(
    inst: dict,
    root: Path,
    harness_dir: Path,
    *,
    with_container: bool = True,
    test_file_hint: bool = False,
    dockerhub_user: str = ds.DOCKERHUB_USER,
) -> PreparedWorkspace:
    """Extract /app for one instance and (optionally) bind it back."""
    iid = inst["instance_id"]
    image = ds.image_for(inst, user=dockerhub_user)
    if not image_present(image):
        pull_image(image)

    dest = root / iid
    shutil.rmtree(dest, ignore_errors=True)
    dest.parent.mkdir(parents=True, exist_ok=True)

    safe = iid.lower().replace("__", "-").replace("_", "-")[:100]
    tmp_name = f"swebp-extract-{safe}"
    subprocess.run(["docker", "rm", "-f", tmp_name], capture_output=True)
    # `docker create` inherits ENTRYPOINT ["/bin/bash"]; with no command the
    # container is never started anyway, but the override keeps it inert.
    subprocess.run(
        ["docker", "create", "--name", tmp_name, "--entrypoint", "/bin/true", image],
        check=True, capture_output=True,
    )
    try:
        subprocess.run(
            ["docker", "cp", f"{tmp_name}:{REPO_DIR}", str(dest)],
            check=True, capture_output=True,
        )
    finally:
        subprocess.run(["docker", "rm", "-f", tmp_name], capture_output=True)

    # Start from exactly base_commit with a clean *tracked* tree, so that the
    # `git diff` later is precisely "what the agent changed".
    #
    # Deliberately no `git clean`: these images carry compiled output and
    # installed dependencies that the environment needs, and some of it is
    # untracked rather than ignored. Removing it would break the very test
    # bridge we are handing the agent. Excluding it by name is the correct
    # tool, and `preexisting_untracked` records exactly what was excluded.
    base = inst["base_commit"]
    _git(dest, "checkout", "-f", base, check=True)
    _git(dest, "reset", "--hard", base, check=True)
    _git(dest, "config", "user.email", "bench@osa.local")
    _git(dest, "config", "user.name", "osa-bench")

    # Delete the answer out of the repository's own history. See
    # `strip_future_history` -- this is not optional and there is no flag to
    # turn it off, because a run without it is not measuring problem-solving.
    history = strip_future_history(dest, base)
    fix_sha = _fix_commit(inst)
    history["fix_commit"] = fix_sha
    history["fix_commit_reachable_after"] = fix_commit_reachable(dest, fix_sha)
    if history["fix_commit_reachable_after"]:
        raise RuntimeError(
            f"{iid}: the fix commit {fix_sha} is STILL readable from the "
            f"prepared workspace after history stripping. Refusing to hand the "
            f"agent a workspace containing the answer."
        )

    preexisting = _untracked_not_ignored(dest)

    exclude = dest / ".git" / "info" / "exclude"
    exclude.parent.mkdir(parents=True, exist_ok=True)
    with exclude.open("a") as fh:
        # Harness scaffolding must never become part of the submitted diff.
        fh.write("\nrun_tests.sh\nAGENT_TASK.md\n.osa/\n")
        for p in preexisting:
            fh.write(f"/{p}\n")

    container = None
    if with_container:
        container = f"swebp-run-{safe}"
        subprocess.run(["docker", "rm", "-f", container], capture_output=True)
        subprocess.run(
            [
                "docker", "run", "-d", "--name", container,
                "-v", f"{dest.resolve()}:{REPO_DIR}",
                # The agent must not be able to fetch the upstream fix through
                # its own test container either.
                "--network", "none",
                "--entrypoint", "/bin/bash",
                image, "-c", "sleep infinity",
            ],
            check=True, capture_output=True,
        )
        # The instance's OWN runner, straight from the official harness's
        # run_scripts/. Using it rather than a guessed `pytest` invocation
        # matters: these repos run `go test ./...`, `ansible-test units`,
        # `yarn jest`, `python -m pytest` -- and an agent that cannot run the
        # suite is measurably worse at this benchmark. It is also byte-identical
        # to what the grader will run, so the bridge and the grade cannot drift.
        run_script = harness_dir / "run_scripts" / iid / "run_script.sh"
        subprocess.run(
            ["docker", "cp", str(run_script), f"{container}:/run_script.sh"],
            check=True, capture_output=True,
        )
        subprocess.run(
            ["docker", "exec", container, "chmod", "0755", "/run_script.sh"],
            check=True, capture_output=True,
        )

        no_args = NO_DEFAULT_TESTS_MSG
        if test_file_hint:
            files = ds.selected_test_files(inst)
            if files:
                no_args = "  set -- " + " ".join(files)
        bridge = dest / "run_tests.sh"
        bridge.write_text(
            TEST_BRIDGE.format(language=inst.get("repo_language", ""))
            .replace("__CONTAINER__", container)
            .replace("__NO_ARGS_ACTION__", no_args)
        )
        bridge.chmod(0o755)

    return PreparedWorkspace(
        instance_id=iid, path=dest, container=container, image=image,
        preexisting_untracked=preexisting, history=history,
    )


def prune_images(rows: list[dict], dockerhub_user: str = ds.DOCKERHUB_USER) -> int:
    """Drop this run's instance images. They are ~2-3 GB each (measured)."""
    removed = 0
    for inst in rows:
        image = ds.image_for(inst, user=dockerhub_user)
        # `docker rmi` on a missing image does not reliably exit non-zero, so
        # its status cannot be used as the count.
        if not image_present(image):
            continue
        subprocess.run(["docker", "rmi", "-f", image], capture_output=True)
        if not image_present(image):
            removed += 1
    return removed


def free_gb(path: Path) -> float:
    st = os.statvfs(path)
    return st.f_bavail * st.f_frsize / 1e9
