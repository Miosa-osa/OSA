#!/bin/sh
# build.sh — Build ScreenShare without SPM (swiftc direct invocation).
#
# Swift Package Manager's Package.swift compilation requires full Xcode
# when using CLT-only installs on macOS 14+. This script compiles directly
# with swiftc, which works with both Xcode and CLT.
#
# Usage:
#   ./build.sh                   # release build → .build/release/ScreenShare
#   ./build.sh debug             # debug build   → .build/debug/ScreenShare
#   ARCH=x86_64 ./build.sh       # cross-compile Intel (on Apple Silicon)
#   ARCH=arm64  ./build.sh       # native arm64 (default on Apple Silicon)
#
# Output binary name in priv/helpers/:
#   osa-screen-capture-darwin    (the name the Elixir MacOS adapter looks for)
#
# CI: This script is called by release.yml instead of `swift build -c release`.
#
# EVERY path below is derived from SCRIPT_DIR, never from the caller's cwd.
# release.yml runs `native/macos/ScreenShare/build.sh` from the REPO ROOT, and
# until v1.0.178 the swiftc inputs were cwd-relative ("Sources/ScreenShare/…").
# That made the step fail with "error opening input file" on every tagged
# release, which skipped the remaining macOS steps (stamp, mix release, tarball,
# TUI, upload) and published a release with no macOS assets at all (#238).
# The sibling AccessibilityHelper/build.sh was always written this way; this one
# now matches it. Keep it that way — a cwd-relative path here is a release-time
# outage, not a local inconvenience.

set -e

MODE="${1:-release}"
ARCH="${ARCH:-$(uname -m)}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
SRC_DIR="${SCRIPT_DIR}/Sources/ScreenShare"
OUT_DIR="${SCRIPT_DIR}/.build/${MODE}"
BINARY="${OUT_DIR}/ScreenShare"
PRIV_HELPERS="${SCRIPT_DIR}/../../../priv/helpers"

mkdir -p "$OUT_DIR"

OPT_FLAGS=""
if [ "$MODE" = "release" ]; then
    OPT_FLAGS="-O -whole-module-optimization"
fi

echo "[build.sh] Building ScreenShare mode=${MODE} arch=${ARCH} → ${BINARY}"

# shellcheck disable=SC2086
swiftc \
    $OPT_FLAGS \
    -target "${ARCH}-apple-macosx13.0" \
    -framework ScreenCaptureKit \
    -framework CoreMedia \
    -framework CoreVideo \
    -framework Network \
    "${SRC_DIR}/FrameEncoder.swift" \
    "${SRC_DIR}/VncServer.swift" \
    "${SRC_DIR}/Capture.swift" \
    "${SRC_DIR}/main.swift" \
    -o "${BINARY}"

echo "[build.sh] Done: $(ls -lh "${BINARY}" | awk '{print $5, $NF}')"

# Copy to priv/helpers/ with the OSA release binary name (release mode only).
# CI uses this path; local dev can also benefit from the auto-copy.
if [ -d "${PRIV_HELPERS}" ] && [ "${MODE}" = "release" ]; then
    cp "${BINARY}" "${PRIV_HELPERS}/osa-screen-capture-darwin"
    chmod +x "${PRIV_HELPERS}/osa-screen-capture-darwin"
    echo "[build.sh] Deployed to ${PRIV_HELPERS}/osa-screen-capture-darwin"
fi
