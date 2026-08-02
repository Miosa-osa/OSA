#!/usr/bin/env bash
# Run the PTY layout harness against a freshly built `osagent`.
#
# See test/pty/README.md — in particular the documented pyte-vs-VTE reflow
# limitation, which bounds what a green run here actually proves.
#
# Usage:
#   test/pty/run.sh              # build if needed, then run
#   test/pty/run.sh --no-build   # use the existing binary
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TUI_DIR="$REPO_ROOT/priv/rust/tui"
BIN="$TUI_DIR/target/release/osagent"

if [[ "${1:-}" != "--no-build" ]]; then
  echo "==> building osagent (release)"
  (cd "$TUI_DIR" && cargo build --release --quiet)
fi

if [[ ! -x "$BIN" ]]; then
  echo "error: $BIN not found. Run without --no-build." >&2
  exit 1
fi

if ! python3 -c "import pyte" >/dev/null 2>&1; then
  cat >&2 <<'EOF'
error: the PTY harness needs `pyte` (a pure-python terminal emulator).

  python3 -m pip install --user pyte
EOF
  exit 1
fi

# Keep the harness away from the developer's real ~/.osa state.
OSA_PTY_HOME="$(mktemp -d)"
export OSA_PTY_HOME
trap 'rm -rf "$OSA_PTY_HOME"' EXIT

echo "==> PTY layout harness"
exec python3 "$REPO_ROOT/test/pty/test_resize.py" "$@"
