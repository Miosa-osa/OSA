#!/usr/bin/env bash
# scripts/rebuild-tui.sh — rebuild the Rust TUI and relaunch OSA so changes take
# effect immediately (dev loop).
#
# Why this exists
# ---------------
# The `osa` launcher execs the cargo release binary directly:
#     $ROOT/priv/rust/tui/target/release/osagent
# (resolved through the ~/.osa/src symlink — it is the SAME file cargo writes).
# So a fresh `cargo build --release` is picked up on the next `osa`; there is NO
# copy/install step for a source checkout.
#
# BUT the version string is baked at COMPILE time:
#     osa_version() = option_env!("OSA_VERSION").unwrap_or(env!("CARGO_PKG_VERSION"))
# With no OSA_VERSION set, the binary falls back to priv/rust/tui/Cargo.toml's
# version (currently 1.0.0 -> shown as v1.0.000) instead of the repo VERSION
# file. This script stamps OSA_VERSION from ./VERSION so the rebuilt TUI shows
# the real version, then restarts the warm backend daemon so a fully fresh stack
# comes up.
#
# Usage:
#   scripts/rebuild-tui.sh            # rebuild + relaunch the TUI
#   scripts/rebuild-tui.sh overdrive  # any args are forwarded to `osa`
#   OSA_TUI_NO_LAUNCH=1 scripts/rebuild-tui.sh   # rebuild only, don't relaunch

set -euo pipefail

# ── Resolve repo root (this script lives in <root>/scripts) ──────────
SCRIPT="${BASH_SOURCE[0]}"
[ -L "$SCRIPT" ] && SCRIPT="$(readlink -f "$SCRIPT")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TUI_DIR="$ROOT/priv/rust/tui"
TUI_BIN="$TUI_DIR/target/release/osagent"

if [ ! -f "$TUI_DIR/Cargo.toml" ]; then
  echo "Error: TUI source not found at $TUI_DIR" >&2
  exit 1
fi

if ! command -v cargo >/dev/null 2>&1; then
  echo "Error: cargo not on PATH. Install Rust (https://rustup.rs) or run: . \"\$HOME/.cargo/env\"" >&2
  exit 1
fi

# ── Stamp the version from the repo VERSION file (compile-time env) ──
OSA_VERSION="${OSA_VERSION:-$(cat "$ROOT/VERSION" 2>/dev/null || true)}"
export OSA_VERSION

echo "→ Rebuilding TUI (OSA_VERSION=${OSA_VERSION:-<unset, falling back to Cargo.toml>})"
( cd "$TUI_DIR" && cargo build --release )

if [ ! -x "$TUI_BIN" ]; then
  echo "Error: build did not produce $TUI_BIN" >&2
  exit 1
fi
echo "✓ Built $TUI_BIN"

if [ "${OSA_TUI_NO_LAUNCH:-0}" = "1" ]; then
  echo "OSA_TUI_NO_LAUNCH=1 — skipping relaunch. Run 'osa' to launch the fresh binary."
  exit 0
fi

# ── Cycle the warm backend daemon so the fresh stack comes up ───────
# `osa` attaches to an already-healthy daemon and never restarts it; stopping it
# first guarantees a fresh backend to pair with the freshly built TUI.
if command -v osa >/dev/null 2>&1; then
  osa stop >/dev/null 2>&1 || true
  echo "→ Launching fresh OSA…"
  exec osa "$@"
else
  # Fall back to the in-repo launcher (source layout).
  "$ROOT/bin/osa" stop >/dev/null 2>&1 || true
  echo "→ Launching fresh OSA (via bin/osa)…"
  exec "$ROOT/bin/osa" "$@"
fi
