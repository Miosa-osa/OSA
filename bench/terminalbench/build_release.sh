#!/usr/bin/env bash
# Build the portable OSA OTP release tarball that gets injected into every
# Terminal-Bench task container.
#
#   ./build_release.sh            build if dist/ is missing
#   ./build_release.sh --force    always rebuild
#
# Output: dist/osa-release-linux-x86_64.tar.gz  (~40-80 MB, ERTS bundled)
#
# The build happens inside a debian-bookworm container on purpose. See the
# header of Dockerfile.release for why building on the host would produce an
# artefact that cannot start in the task images.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
OUT="$HERE/dist/osa-release-linux-x86_64.tar.gz"
CTX="$HERE/.buildctx"
IMAGE="osa-bench-release-builder"

if [[ -f "$OUT" && "${1:-}" != "--force" ]]; then
  echo "release already built: $OUT ($(du -h "$OUT" | cut -f1))"
  exit 0
fi

# `mix release` copies priv/ wholesale, and priv/rust/tui/target is ~30 GB on
# any machine that has built the TUI. mix.exs prunes it *after* :assemble, which
# is far too late. Keep it out of the build context entirely.
echo "==> staging build context (excluding _build, deps, .git, rust target)"
rm -rf "$CTX"
mkdir -p "$CTX"
rsync -a \
  --exclude '.git/' \
  --exclude '_build/' \
  --exclude 'deps/' \
  --exclude 'priv/rust/tui/target/' \
  --exclude 'bench/' \
  --exclude 'burrito_out/' \
  --exclude '*.tar.gz' \
  "$REPO/" "$CTX/"

echo "==> building release image (this takes a few minutes)"
docker build -f "$HERE/Dockerfile.release" -t "$IMAGE" "$CTX"

echo "==> extracting tarball"
mkdir -p "$HERE/dist"
cid=$(docker create "$IMAGE" /bin/true)
docker cp "$cid:/osa-release-linux-x86_64.tar.gz" "$OUT"
docker rm -f "$cid" >/dev/null
rm -rf "$CTX"

echo "==> $OUT ($(du -h "$OUT" | cut -f1))"
