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

set -e

MODE="${1:-release}"
ARCH="${ARCH:-$(uname -m)}"
OUT_DIR=".build/${MODE}"
BINARY="${OUT_DIR}/ScreenShare"

mkdir -p "$OUT_DIR"

OPT_FLAGS=""
if [ "$MODE" = "release" ]; then
    OPT_FLAGS="-O -whole-module-optimization"
fi

echo "[build.sh] Building ScreenShare mode=${MODE} arch=${ARCH} → ${BINARY}"

swiftc \
    $OPT_FLAGS \
    -target "${ARCH}-apple-macosx13.0" \
    -framework ScreenCaptureKit \
    -framework CoreMedia \
    -framework CoreVideo \
    -framework Network \
    Sources/ScreenShare/FrameEncoder.swift \
    Sources/ScreenShare/VncServer.swift \
    Sources/ScreenShare/Capture.swift \
    Sources/ScreenShare/main.swift \
    -o "${BINARY}"

echo "[build.sh] Done: $(ls -lh "${BINARY}" | awk '{print $5, $NF}')"

# Copy to priv/helpers/ with the OSA release binary name (release mode only).
# CI uses this path; local dev can also benefit from the auto-copy.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PRIV_HELPERS="${SCRIPT_DIR}/../../../priv/helpers"
if [ -d "${PRIV_HELPERS}" ] && [ "${MODE}" = "release" ]; then
    cp "${BINARY}" "${PRIV_HELPERS}/osa-screen-capture-darwin"
    chmod +x "${PRIV_HELPERS}/osa-screen-capture-darwin"
    echo "[build.sh] Deployed to ${PRIV_HELPERS}/osa-screen-capture-darwin"
fi
