#!/usr/bin/env bash
# Build the portable OSA OTP release tarball that gets injected into every
# Terminal-Bench task container.
#
#   ./build_release.sh              build if dist/ is missing
#   ./build_release.sh --force      always rebuild
#   ./build_release.sh --bullseye   build the bullseye variant into dist-bullseye/
#   ./build_release.sh --from-commit <ref> [--force]
#                                   build from a COMMITTED tree, not the working one
#
# ## --from-commit, and why it is the mode to use for anything quotable
#
# The default path stages the build context with rsync from the live working
# tree, which means an artefact built while anyone has uncommitted edits
# contains those edits and nothing on disk records it. `artifact_provenance()`
# in run_bench.py stamps the repo HEAD and a dirty flag for exactly this reason,
# but a dirty flag tells you the number is void -- it does not prevent it.
#
# This has already cost real work twice in this effort: an ablation whose two
# arms turned out to be different code, and a full 89-task run built off a tree
# that was mid-edit. Both were discovered after the run.
#
# `--from-commit` exports a named commit with `git archive` into a clean
# directory and builds from that. Uncommitted work cannot reach the artefact by
# construction rather than by discipline, and the resulting tarball is
# reproducible from the SHA alone.
#
# Output: dist/osa-release-linux-x86_64.tar.gz  (~40-80 MB, ERTS bundled)
#         dist-bullseye/... for --bullseye (kept separate on purpose: it never
#         overwrites the known-good bookworm artefact)
#
# The bullseye variant is built on glibc 2.31 / OpenSSL 1.1 and, with the
# vendored-library wiring in osa_agent.py, has been measured to boot on
# debian:bullseye-slim, python:3.13-slim-bookworm and ubuntu:24.04 -- i.e. it
# covers the 2 tasks the bookworm artefact cannot reach as well as the other 87.
#
# The build happens inside a debian-bookworm container on purpose. See the
# header of Dockerfile.release for why building on the host would produce an
# artefact that cannot start in the task images.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
DOCKERFILE="$HERE/Dockerfile.release"
OUTDIR="$HERE/dist"
CTX="$HERE/.buildctx"
IMAGE="osa-bench-release-builder"

FROM_COMMIT=""

if [[ "${1:-}" == "--bullseye" ]]; then
  DOCKERFILE="$HERE/Dockerfile.release.bullseye"
  OUTDIR="$HERE/dist-bullseye"
  CTX="$HERE/.buildctx-bullseye"
  IMAGE="osa-bench-release-builder-bullseye"
  shift
fi
if [[ "${1:-}" == "--from-commit" ]]; then
  FROM_COMMIT="${2:?--from-commit needs a ref}"
  shift 2
fi
OUT="$OUTDIR/osa-release-linux-x86_64.tar.gz"

if [[ -f "$OUT" && "${1:-}" != "--force" ]]; then
  echo "release already built: $OUT ($(du -h "$OUT" | cut -f1))"
  exit 0
fi

# ── The build lock ────────────────────────────────────────────────────────
#
# `dist/` is shared mutable state that several sessions write and every run
# reads, and until this existed nothing arbitrated it. Measured: an arm verified
# its artefact at 01:43:15Z, a sibling ran `--force` at 01:52:41Z, and the run
# launched 86 seconds later on the sibling's build. Twice more, an arm found its
# artefact stale, or built from a commit a history rewrite had deleted.
#
# The lock is taken NON-BLOCKING and the second builder fails. It deliberately
# does not queue: a build that waits its turn still overwrites the artefact when
# it gets there, so waiting converts a loud collision into the same silent one
# with extra latency.
#
# This is advisory and it is only half the guarantee -- `artifact_lock.pin_for_run`
# copies the tarball into the run directory so a run owns immutable bytes even
# if some future caller ignores this lock. See that module's docstring.
mkdir -p "$OUTDIR"
LOCK="$OUTDIR/.build.lock"
exec 9>>"$LOCK"
if ! flock -n 9; then
  echo "!!  refusing to build: $OUTDIR is locked by another build." >&2
  echo "!!  holder: $(cat "$LOCK" 2>/dev/null | tr -d '\n' | head -c 400)" >&2
  echo "!!  Wait for it to finish, or kill it -- do NOT delete the lock while" >&2
  echo "!!  that pid is alive; the two builds would interleave in $OUTDIR." >&2
  exit 9
fi

# Stamped AFTER the flock so the payload always describes the real holder.
# `artifact_lock.describe_holder` parses this, and reports "identity not yet
# written" for the window between the two.
LOCK_SHA="$(if [[ -n "$FROM_COMMIT" ]]; then git -C "$REPO" rev-parse "$FROM_COMMIT"; else git -C "$REPO" rev-parse HEAD; fi)"
: >"$LOCK"
printf '{"pid":%d,"purpose":"build_release.sh","build_sha":"%s","dockerfile":"%s","held_since":"%s"}\n' \
  "$$" "$LOCK_SHA" "$(basename "$DOCKERFILE")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >&9

# The lock is released when fd 9 closes, which the kernel does on exit however
# we leave -- including `set -e`, a signal, or a docker build failure. No trap
# needed, and no stale lock survives a crash.

# `mix release` copies priv/ wholesale, and priv/rust/tui/target is ~30 GB on
# any machine that has built the TUI. mix.exs prunes it *after* :assemble, which
# is far too late. Keep it out of the build context entirely.
rm -rf "$CTX"
mkdir -p "$CTX"

if [[ -n "$FROM_COMMIT" ]]; then
  SHA="$(git -C "$REPO" rev-parse "$FROM_COMMIT")"
  echo "==> staging build context from COMMIT $SHA (git archive)"
  # `git archive` writes only tracked content at that commit. Untracked files
  # are absent too, which is the point and is also a hazard: a new module that
  # has not been `git add`-ed will not be in the artefact, and the build will
  # fail loudly at compile time rather than silently shipping without it.
  git -C "$REPO" archive --format=tar "$SHA" | tar -x -C "$CTX"
  # Recorded inside the context so the SHA survives into the image and can be
  # recovered from the artefact itself, not only from the run config.
  echo "$SHA" > "$CTX/.osa-build-sha"
  rm -rf "$CTX/bench"
else
  echo "==> staging build context from the WORKING TREE (excluding _build, deps, .git, rust target)"
  if ! git -C "$REPO" diff --quiet -- lib || \
     [[ -n "$(git -C "$REPO" ls-files --others --exclude-standard -- lib)" ]]; then
    echo "!!  lib/ has uncommitted changes. This artefact will contain them and" >&2
    echo "!!  nothing downstream can reproduce it. Use --from-commit <sha> for" >&2
    echo "!!  anything whose number will be quoted." >&2
  fi
  rsync -a \
    --exclude '.git/' \
    --exclude '_build/' \
    --exclude 'deps/' \
    --exclude 'priv/rust/tui/target/' \
    --exclude 'bench/' \
    --exclude 'burrito_out/' \
    --exclude '*.tar.gz' \
    "$REPO/" "$CTX/"
fi

echo "==> building release image (this takes a few minutes)"
docker build -f "$DOCKERFILE" -t "$IMAGE" "$CTX"

echo "==> extracting tarball"
mkdir -p "$OUTDIR"
cid=$(docker create "$IMAGE" /bin/true)
docker cp "$cid:/osa-release-linux-x86_64.tar.gz" "$OUT"
docker rm -f "$cid" >/dev/null

# A sidecar naming the exact source this tarball was built from.
#
# `artifact_provenance()` otherwise has only the artefact's mtime and the repo
# HEAD at RUN time, and those answer different questions. HEAD moves whenever
# anyone commits between the build and the run -- which, with several agents
# working in lib/, it does -- so "artefact is newer than HEAD" can be false on a
# perfectly sound artefact and true on a stale one. The build's own SHA does not
# move, and it is the only thing that identifies the code that was measured.
{
  echo "{"
  echo "  \"build_sha\": \"$(if [[ -n "$FROM_COMMIT" ]]; then echo "$SHA"; else git -C "$REPO" rev-parse HEAD; fi)\","
  echo "  \"from_commit\": $(if [[ -n "$FROM_COMMIT" ]]; then echo true; else echo false; fi),"
  echo "  \"lib_dirty_at_build\": $(if [[ -z "$FROM_COMMIT" ]] && { ! git -C "$REPO" diff --quiet -- lib || [[ -n "$(git -C "$REPO" ls-files --others --exclude-standard -- lib)" ]]; }; then echo true; else echo false; fi),"
  echo "  \"built_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
  echo "  \"dockerfile\": \"$(basename "$DOCKERFILE")\""
  echo "}"
} > "$OUTDIR/build-provenance.json"

rm -rf "$CTX"

echo "==> $OUT ($(du -h "$OUT" | cut -f1))"
