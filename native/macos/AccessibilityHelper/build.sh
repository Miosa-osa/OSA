#!/bin/sh
set -eu

MODE="${1:-release}"
ARCH="${ARCH:-$(uname -m)}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
OUT_DIR="${SCRIPT_DIR}/.build/${MODE}"
BINARY="${OUT_DIR}/osa-accessibility-darwin"
PRIV_HELPERS="${SCRIPT_DIR}/../../../priv/helpers"

mkdir -p "$OUT_DIR"
OPT_FLAGS=""
if [ "$MODE" = "release" ]; then
  OPT_FLAGS="-O -whole-module-optimization"
fi

# shellcheck disable=SC2086
swiftc $OPT_FLAGS \
  -target "${ARCH}-apple-macosx13.0" \
  -framework ApplicationServices \
  -framework AppKit \
  -framework CoreGraphics \
  "${SCRIPT_DIR}/main.swift" \
  -o "$BINARY"

if [ "$MODE" = "release" ]; then
  cp "$BINARY" "${PRIV_HELPERS}/osa-accessibility-darwin"
  chmod +x "${PRIV_HELPERS}/osa-accessibility-darwin"
fi

echo "Built ${BINARY}"
