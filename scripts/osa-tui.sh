#!/usr/bin/env bash
# osa — Launch OSA Agent (backend + Rust TUI)
# Usage: osa
set -e

# Resolve project root from this script's location (scripts/ lives under root).
SCRIPT="${BASH_SOURCE[0]:-$0}"
[ -L "$SCRIPT" ] && SCRIPT="$(readlink -f "$SCRIPT")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TUI_BIN="$PROJECT_DIR/priv/rust/tui/target/release/osagent"
PORT=9089
PID_FILE="/tmp/osa-backend.pid"

# ── Build TUI if needed ─────────────────────────────────────────────
# Stamp OSA_VERSION from the repo VERSION file so the version baked into the
# binary matches the release (else it falls back to Cargo.toml's 1.0.0).
if [ ! -f "$TUI_BIN" ]; then
  echo "Building Rust TUI (first time only)..."
  (cd "$PROJECT_DIR/priv/rust/tui" && OSA_VERSION="$(cat "$PROJECT_DIR/VERSION" 2>/dev/null || true)" cargo build --release 2>&1)
fi

# ── Kill any stale backend on the port ──────────────────────────────
if lsof -i :$PORT -t > /dev/null 2>&1; then
  echo "Cleaning up stale backend on port $PORT..."
  lsof -i :$PORT -t | xargs kill -9 2>/dev/null
  sleep 1
fi

# Also kill from previous PID file
if [ -f "$PID_FILE" ]; then
  OLD_PID=$(cat "$PID_FILE")
  kill "$OLD_PID" 2>/dev/null
  rm -f "$PID_FILE"
fi

# ── Start backend (silent, headless) ────────────────────────────────
cd "$PROJECT_DIR"
MIX_QUIET=1 LOGGER_LEVEL=error mix run --no-halt > /tmp/osa-backend.log 2>&1 &
BACKEND_PID=$!
echo "$BACKEND_PID" > "$PID_FILE"

# ── Wait for backend to be ready ────────────────────────────────────
printf "Starting OSA"
for i in $(seq 1 20); do
  if curl -s "http://localhost:$PORT/health" > /dev/null 2>&1; then
    echo " ✓"
    break
  fi
  printf "."
  sleep 0.5
done

# Bail if backend didn't start
if ! curl -s "http://localhost:$PORT/health" > /dev/null 2>&1; then
  echo " FAILED"
  echo "Backend did not start. Check /tmp/osa-backend.log"
  kill "$BACKEND_PID" 2>/dev/null
  rm -f "$PID_FILE"
  exit 1
fi

# ── Launch Rust TUI (takes over terminal) ───────────────────────────
"$TUI_BIN" "$@"
EXIT_CODE=$?

# ── Cleanup on exit ─────────────────────────────────────────────────
kill "$BACKEND_PID" 2>/dev/null
rm -f "$PID_FILE"
exit $EXIT_CODE
