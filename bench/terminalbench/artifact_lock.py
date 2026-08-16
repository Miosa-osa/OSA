"""Advisory build lock and per-run artefact pinning for the release tarballs.

## The class of bug this exists to stop

`dist/osa-release-linux-x86_64.tar.gz` is unlocked shared mutable state. It is
what goes into every task container, several sessions build it, and a run reads
it at launch and then trusts it for hours. Nothing arbitrated any of that.

Three incidents, all real, all discovered after the fact:

1. An arm verified its artefact at 01:43:15Z; a sibling session ran
   `build_release.sh --force` at 01:52:41Z; the run launched 86 seconds later
   **on the sibling's build**. `config.json` recorded the truth, so the run was
   internally consistent -- but the operator's belief about what had been
   measured was wrong, and it took a careful reader to notice.
2. An arm's artefact turned out to be four hours stale while `lib/` had moved
   underneath it.
3. `dist/` was found built from a commit that no longer existed after a history
   rewrite.

And a fourth, measured on `osa-tb20-full89-9b57ee7d`: the run used **two
different builds**. `dist/` was clobbered mid-run but `dist-bullseye/` was not,
so the 2 qemu tasks that select the bullseye variant by glibc ran
`9b57ee7d` while the other 87 ran `04061c68`.

Recording provenance -- which `run_bench.artifact_provenance` already did --
answers "what happened?" afterwards. It cannot answer "is this still the thing
I verified?" at the moment it matters. These two mechanisms do:

## Two mechanisms, deliberately

**A build must not silently replace an artefact another process is using.**
`build_release.sh` takes `flock` on `<outdir>/.build.lock` for the whole build
and stamps the holder's pid and commit into it. A second builder fails loudly
naming the holder. It does NOT wait: a build that queues behind another one
finishes by overwriting it anyway, which is the same incident with extra
latency.

**A run must be able to pin an artefact for its lifetime.** `pin_for_run`
copies each tarball into the run directory under the same lock and installs
from *that*. This is strictly stronger than the lock, for two reasons that both
mattered above: it survives a lock being ignored (a copy cannot be clobbered by
a later build at all), and it makes the artefact recoverable from the run
afterwards -- which would have answered "what did we actually measure?"
instantly, twice.

Both variants are covered. `osa_agent._artifact_for` picks between `dist/` and
`dist-bullseye/` per container by glibc, so a guarantee that only covered
`dist/` would have left exactly the split-build hole that incident 4 was.

## The on-disk contract

    <outdir>/.build.lock          flock'd for the duration of a build; the
                                  holder's pid/sha/start time as JSON inside
    <run>/artifacts/<variant>/    the pinned copy: tarball, build-provenance
                                  .json, and pin.json (sha256 + source + time)

`flock(1)` and `fcntl.flock` are the same `flock(2)`, so the shell builder and
this module interoperate without a second convention.
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import shutil
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent

#: Basename of the advisory lock inside each output directory. Must match
#: `build_release.sh`.
LOCK_NAME = ".build.lock"

#: Tarball basename, identical in every variant directory.
TARBALL_NAME = "osa-release-linux-x86_64.tar.gz"

#: Sidecar `build_release.sh` writes naming the source commit.
PROVENANCE_NAME = "build-provenance.json"

#: Env var naming the pinned artefact root, read by `osa_agent`. Unset means
#: "read `dist/` live", which is exactly the pre-pinning behaviour -- so an
#: adapter running under an older runner, or a bare `harbor run`, is unchanged.
PINNED_ROOT_ENV = "OSA_BENCH_ARTIFACT_ROOT"

#: variant name -> source directory. The names are what appear under
#: `<run>/artifacts/` and in `config.json`.
VARIANTS = {
    "default": HERE / "dist",
    "bullseye": HERE / "dist-bullseye",
}


class ArtifactError(RuntimeError):
    """A pin could not be established. Always fatal at launch, never a warning.

    The whole point is to refuse rather than to record-and-continue, because
    record-and-continue is what produced three unusable runs.
    """


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


@contextmanager
def build_lock(outdir: Path, *, purpose: str):
    """Hold `<outdir>/.build.lock` exclusively, or raise naming the holder.

    Non-blocking on purpose. A builder that waits still overwrites the artefact
    when its turn comes, and a run that waits is a run whose artefact is being
    replaced while it waits -- neither is the behaviour anyone wants, and both
    hide the collision instead of surfacing it.
    """
    outdir.mkdir(parents=True, exist_ok=True)
    lock_path = outdir / LOCK_NAME
    fd = os.open(str(lock_path), os.O_RDWR | os.O_CREAT, 0o644)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            raise ArtifactError(
                f"{outdir} is locked by another process -- {describe_holder(outdir)}. "
                f"Refusing to {purpose}: proceeding would race a build that is "
                f"replacing this artefact right now."
            ) from None
        os.ftruncate(fd, 0)
        os.write(fd, (json.dumps({
            "pid": os.getpid(),
            "purpose": purpose,
            "held_since": datetime.now(timezone.utc).isoformat(),
        }) + "\n").encode())
        os.fsync(fd)
        yield lock_path
    finally:
        os.close(fd)


def describe_holder(outdir: Path) -> str:
    """Human-readable "who holds this", for the refusal message.

    Best-effort: the lock's payload is written after the flock is taken, so a
    holder caught in that window has an empty file. Say so rather than
    implying nobody holds it.
    """
    lock_path = outdir / LOCK_NAME
    try:
        raw = lock_path.read_text().strip()
    except OSError:
        return "holder unknown (lock file unreadable)"
    if not raw:
        return "holder unknown (lock taken, identity not yet written)"
    try:
        info = json.loads(raw)
    except json.JSONDecodeError:
        return f"holder unknown (unparseable lock payload: {raw[:120]!r})"
    bits = [f"pid={info.get('pid')}"]
    for key in ("purpose", "build_sha", "dockerfile", "held_since"):
        if info.get(key):
            bits.append(f"{key}={info[key]}")
    return " ".join(bits)


def is_locked(outdir: Path) -> bool:
    """True when some process currently holds the build lock on `outdir`."""
    lock_path = outdir / LOCK_NAME
    if not lock_path.exists():
        return False
    fd = os.open(str(lock_path), os.O_RDWR)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(fd, fcntl.LOCK_UN)
        return False
    except OSError:
        return True
    finally:
        os.close(fd)


def pin_for_run(run_dir: Path, *, variants: dict[str, Path] | None = None) -> dict:
    """Copy every present artefact into `run_dir/artifacts/` and verify it.

    Returns a manifest for `config.json`. Raises `ArtifactError` rather than
    returning a degraded result, on any of:

      * the default artefact is absent -- there is nothing to measure;
      * a build holds the lock -- the artefact is being replaced right now;
      * the tarball changed between the pre-copy and post-copy hash -- a build
        landed mid-copy and the pinned bytes are of no known build;
      * `build-provenance.json` is missing or unreadable -- the copy would be
        an artefact nobody can attribute to a commit, which is incident 3.

    The bullseye variant is optional (it may simply not have been built) but is
    pinned and verified on exactly the same terms when present. A run that
    pins one and reads the other live is incident 4.
    """
    variants = VARIANTS if variants is None else variants
    root = run_dir / "artifacts"
    manifest: dict = {"root": str(root), "variants": {}}

    default_src = variants.get("default")
    if default_src is None or not (default_src / TARBALL_NAME).exists():
        raise ArtifactError(
            f"no release tarball at {default_src / TARBALL_NAME if default_src else '?'}. "
            f"Build one first: ./build_release.sh --from-commit HEAD"
        )

    for name, src_dir in variants.items():
        src = src_dir / TARBALL_NAME
        if not src.exists():
            manifest["variants"][name] = {"present": False, "source": str(src)}
            continue

        prov_src = src_dir / PROVENANCE_NAME
        if not prov_src.exists():
            raise ArtifactError(
                f"{src} has no {PROVENANCE_NAME} beside it, so the build it came "
                f"from cannot be named. Rebuild with ./build_release.sh so the "
                f"sidecar is written."
            )
        try:
            provenance = json.loads(prov_src.read_text())
        except (OSError, json.JSONDecodeError) as exc:
            raise ArtifactError(f"unreadable {prov_src}: {exc}") from exc
        if not provenance.get("build_sha"):
            raise ArtifactError(
                f"{prov_src} carries no build_sha, so this artefact cannot be "
                f"attributed to any commit."
            )

        dest_dir = root / name
        dest_dir.mkdir(parents=True, exist_ok=True)

        # Copy under the build lock, so a builder cannot start midway through.
        # The before/after hashes are belt-and-braces for a builder that
        # ignored the lock entirely -- which is the case pinning exists to
        # survive, so it is checked rather than assumed away.
        with build_lock(src_dir, purpose=f"pin {name} artefact for {run_dir.name}"):
            before = sha256(src)
            shutil.copy2(src, dest_dir / TARBALL_NAME)
            shutil.copy2(prov_src, dest_dir / PROVENANCE_NAME)
            after = sha256(src)
            pinned = sha256(dest_dir / TARBALL_NAME)

        if before != after:
            raise ArtifactError(
                f"{src} changed while it was being pinned ({before[:12]} -> "
                f"{after[:12]}): a build landed mid-copy. The pinned bytes "
                f"belong to no known build; re-run once the build has finished."
            )
        if pinned != before:
            raise ArtifactError(
                f"the pinned copy of {name} does not match its source "
                f"({pinned[:12]} != {before[:12]}) -- the copy is corrupt."
            )

        entry = {
            "present": True,
            "source": str(src),
            "pinned": str(dest_dir / TARBALL_NAME),
            "sha256": pinned,
            "size_bytes": src.stat().st_size,
            "build": provenance,
            "pinned_at": datetime.now(timezone.utc).isoformat(),
        }
        (dest_dir / "pin.json").write_text(json.dumps(entry, indent=2) + "\n")
        manifest["variants"][name] = entry

    # THE SPLIT-BUILD CHECK. Incident 4 in the module docstring: `dist/` was
    # clobbered mid-run and `dist-bullseye/` was not, so 2 of 89 tasks measured
    # a different commit than the other 87 and the results file said nothing.
    # Pinning alone does not catch this -- it would faithfully pin two
    # different builds -- so the disagreement is named here.
    shas = {
        name: e["build"].get("build_sha")
        for name, e in manifest["variants"].items()
        if e.get("present")
    }
    manifest["build_shas"] = shas
    manifest["variants_agree"] = len(set(shas.values())) <= 1
    return manifest


def verify_pin(root: Path) -> dict:
    """Re-hash a pinned artefact set against its own `pin.json`.

    Cheap enough to run at launch after pinning, and the only check that would
    have caught a pinned copy being edited afterwards. Returns
    `{variant: ok_bool}`; raises `ArtifactError` on the first mismatch.
    """
    out = {}
    for pin_file in sorted(root.glob("*/pin.json")):
        entry = json.loads(pin_file.read_text())
        tar = pin_file.parent / TARBALL_NAME
        if not tar.exists():
            raise ArtifactError(f"pinned artefact {tar} has gone missing")
        actual = sha256(tar)
        if actual != entry["sha256"]:
            raise ArtifactError(
                f"pinned artefact {tar} no longer matches its pin.json "
                f"({actual[:12]} != {entry['sha256'][:12]})"
            )
        out[pin_file.parent.name] = True
    return out
