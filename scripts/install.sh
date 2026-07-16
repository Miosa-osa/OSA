#!/bin/sh
# scripts/install.sh — OSA one-command installer (zero toolchains).
#
# Downloads prebuilt release artifacts from GitHub Releases and wires up the
# `osa` command. The user needs NO Elixir, Erlang, or Rust: the release tarball
# bundles its own ERTS (built on CI via `MIX_ENV=prod mix release osagent`) and
# the Rust TUI ships as a prebuilt binary.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Miosa-osa/OSA/main/scripts/install.sh | sh
#   wget -qO-  https://raw.githubusercontent.com/Miosa-osa/OSA/main/scripts/install.sh | sh
#
# Environment overrides:
#   OSA_VERSION   Pin to a release tag (e.g. "v0.4.0"). Default: latest.
#   OSA_HOME      Install root. Default: $HOME/.osa
#
# Exit codes:
#   0 success   1 unsupported platform   2 network error   3 extraction error
#
# POSIX sh. No bashisms. Requires: curl or wget, tar, and sha256sum/shasum.

set -eu

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
GITHUB_REPO="Miosa-osa/OSA"
OSA_HOME="${OSA_HOME:-${HOME}/.osa}"
RELEASE_DIR="${OSA_HOME}/release"
BIN_DIR="${OSA_HOME}/bin"
TUI_BIN="${BIN_DIR}/osagent-tui"
LAUNCHER="${BIN_DIR}/osa"
INSTALL_ONE_LINER="curl -fsSL https://raw.githubusercontent.com/${GITHUB_REPO}/main/scripts/install.sh | sh"

# ---------------------------------------------------------------------------
# Pretty output
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  BOLD='\033[1m'; DIM='\033[2m'; GREEN='\033[0;32m'
  YELLOW='\033[0;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; RESET='\033[0m'
else
  BOLD=''; DIM=''; GREEN=''; YELLOW=''; RED=''; CYAN=''; RESET=''
fi

info() { printf "  ${CYAN}→${RESET} %s\n" "$*"; }
ok()   { printf "  ${GREEN}✓${RESET} %s\n" "$*"; }
warn() { printf "  ${YELLOW}!${RESET} %s\n" "$*" >&2; }
fail() { printf "  ${RED}✗${RESET} %s\n" "$1" >&2; exit "${2:-1}"; }

_download() {
  # _download <url> <dest> — curl first, wget fallback. Returns 2 on failure.
  _url="$1"; _dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --retry-delay 2 -o "$_dest" "$_url" || return 2
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$_dest" "$_url" || return 2
  else
    fail "Neither curl nor wget is available — install one (via your system package manager) and re-run the installer."
  fi
}

# ---------------------------------------------------------------------------
# Banner — cyan/blue ASCII logo. Colors auto-disable when stdout is not a TTY
# (BOLD/CYAN/DIM/RESET are empty in that case), so this degrades to plain text.
# The art is printed with %s so backslashes are never treated as escapes.
# ---------------------------------------------------------------------------
printf '\n'
printf '%b' "${CYAN}${BOLD}"
printf '%s\n' \
'    ___  ____    _    ' \
'   / _ \/ ___|  / \   ' \
'  | | | \___ \ / _ \  ' \
'  | |_| |___) / ___ \ ' \
'   \___/|____/_/   \_\'
printf '%b' "${RESET}"
printf '%b\n' "${BOLD}  the Optimal System Agent${RESET}"
printf '%b\n\n' "${DIM}  One-command installer · no Elixir / Erlang / Rust required${RESET}"

# ---------------------------------------------------------------------------
# Detect OS + architecture
# ---------------------------------------------------------------------------
OS=""
ARCH=""
case "$(uname -s)" in
  Darwin) OS="macos" ;;
  Linux)  OS="linux" ;;
  *) fail "Unsupported OS: $(uname -s). OSA supports macOS and Linux." 1 ;;
esac

case "$(uname -m)" in
  arm64|aarch64) ARCH="arm64" ;;
  x86_64|amd64)  ARCH="x64" ;;
  *) fail "Unsupported architecture: $(uname -m)." 1 ;;
esac

PLATFORM="${OS}-${ARCH}"
info "Detected platform: ${PLATFORM}"

# Only combinations CI publishes assets for.
case "$PLATFORM" in
  linux-x64|macos-arm64) : ;;
  *)
    warn "No prebuilt binaries are published for ${PLATFORM} yet."
    warn "Build from source instead:"
    warn "  curl -fsSL https://raw.githubusercontent.com/${GITHUB_REPO}/main/install.sh | bash"
    exit 1
    ;;
esac

TARBALL="osa-${PLATFORM}.tar.gz"
TUI_ASSET="osagent-tui-${PLATFORM}"

# ---------------------------------------------------------------------------
# Resolve version (latest or pinned)
# ---------------------------------------------------------------------------
if [ -n "${OSA_VERSION:-}" ]; then
  VERSION="${OSA_VERSION}"
  info "Using pinned version: ${VERSION}"
else
  info "Resolving latest release..."
  META="$(mktemp "${TMPDIR:-/tmp}/osa-meta.XXXXXX")"
  if ! _download "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" "$META"; then
    rm -f "$META"
    fail "Network error: could not reach the GitHub API." 2
  fi
  VERSION="$(grep '"tag_name"' "$META" | head -1 \
    | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')"
  rm -f "$META"
  [ -n "$VERSION" ] || fail "Could not determine latest release. Pin with OSA_VERSION=v0.4.0." 2
  ok "Latest release: ${VERSION}"
fi

BASE_URL="https://github.com/${GITHUB_REPO}/releases/download/${VERSION}"

# ---------------------------------------------------------------------------
# Download artifacts to a scratch dir
# ---------------------------------------------------------------------------
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/osa-install.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

info "Downloading ${TARBALL}..."
if ! _download "${BASE_URL}/${TARBALL}" "${TMP_DIR}/${TARBALL}"; then
  warn "URL: ${BASE_URL}/${TARBALL}"
  warn "See releases: https://github.com/${GITHUB_REPO}/releases"
  fail "Download failed." 2
fi
ok "Downloaded ${TARBALL}"

info "Downloading ${TUI_ASSET}..."
if ! _download "${BASE_URL}/${TUI_ASSET}" "${TMP_DIR}/${TUI_ASSET}"; then
  fail "Download failed for ${TUI_ASSET}." 2
fi
ok "Downloaded ${TUI_ASSET}"

# ---------------------------------------------------------------------------
# Verify checksum (best effort — warn if sidecar absent)
# ---------------------------------------------------------------------------
info "Verifying checksum..."
if _download "${BASE_URL}/${TARBALL}.sha256" "${TMP_DIR}/${TARBALL}.sha256" 2>/dev/null; then
  EXPECTED="$(awk '{print $1}' "${TMP_DIR}/${TARBALL}.sha256")"
  if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL="$(sha256sum "${TMP_DIR}/${TARBALL}" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    ACTUAL="$(shasum -a 256 "${TMP_DIR}/${TARBALL}" | awk '{print $1}')"
  else
    ACTUAL=""
    warn "No sha256sum/shasum found — skipping verification."
  fi
  if [ -n "$ACTUAL" ]; then
    if [ "$ACTUAL" != "$EXPECTED" ]; then
      fail "Checksum mismatch — download may be corrupted. Aborting." 3
    fi
    ok "Checksum verified"
  fi
else
  warn "No .sha256 sidecar for this release — skipping verification."
fi

# ---------------------------------------------------------------------------
# Extract OTP release into ~/.osa/release (fresh)
# ---------------------------------------------------------------------------
info "Installing OTP release to ${RELEASE_DIR}..."
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"
if ! tar -xzf "${TMP_DIR}/${TARBALL}" -C "$RELEASE_DIR" 2>/dev/null; then
  fail "Extraction failed." 3
fi

RELEASE_BIN="${RELEASE_DIR}/bin/osagent"
[ -x "$RELEASE_BIN" ] || chmod +x "$RELEASE_BIN" 2>/dev/null || true
[ -f "$RELEASE_BIN" ] || fail "Release wrapper not found at ${RELEASE_BIN}." 3
ok "Release installed"

# ---------------------------------------------------------------------------
# Install the Rust TUI binary
# ---------------------------------------------------------------------------
mkdir -p "$BIN_DIR"
cp "${TMP_DIR}/${TUI_ASSET}" "$TUI_BIN"
chmod +x "$TUI_BIN"
ok "TUI installed to ${TUI_BIN}"

# Record install layout so tooling can locate the release.
printf "%s\n" "$RELEASE_DIR" > "${OSA_HOME}/release_root"

# ---------------------------------------------------------------------------
# Write the `osa` launcher
#
# Mirrors bin/osa + ~/.claude/scripts/osa: sources ~/.osa/.env, boots the
# ERTS-bundled backend (headless `serve`), waits for /health, launches the
# Rust TUI, and tears the backend down on exit.
# ---------------------------------------------------------------------------
info "Writing launcher to ${LAUNCHER}..."
cat > "$LAUNCHER" <<'LAUNCHER_EOF'
#!/usr/bin/env bash
# osa — launcher for the prebuilt OSA install (~/.osa).
#
#   osa                 Start backend + TUI (default)
#   osa setup           Configure provider / API keys
#   osa serve           Backend only (headless HTTP API)
#   osa doctor          Health checks
#   osa version         Print version
#   osa opencomputers   Manage the MIOSA host connection
#   osa update          How to update
set -eu

OSA_HOME="${OSA_HOME:-$HOME/.osa}"
export OSA_HOME
RELEASE_BIN="$OSA_HOME/release/bin/osagent"
TUI_BIN="$OSA_HOME/bin/osagent-tui"
LOG_DIR="$OSA_HOME/logs"
mkdir -p "$LOG_DIR"

# Load user config (provider/model/keys) before booting the backend, so
# config/runtime.exs sees it (mirrors ~/.claude/scripts/osa).
if [ -f "$OSA_HOME/.env" ]; then
  # Harden sourcing: a single malformed line (unterminated quote, bare word, or
  # $UNSET under `set -u`) would otherwise abort the whole launcher under
  # `set -eu` with a cryptic parse error. Relax the strict flags just for the
  # sourcing, warn instead of dying, then restore them.
  set +e
  set +u
  set -a
  . "$OSA_HOME/.env" 2>/dev/null \
    || echo "warning: some lines in $OSA_HOME/.env could not be parsed — ignoring them" >&2
  set +a
  set -eu
fi

if [ ! -x "$RELEASE_BIN" ]; then
  echo "OSA is not installed correctly ($RELEASE_BIN missing)." >&2
  echo "Reinstall: curl -fsSL https://raw.githubusercontent.com/Miosa-osa/OSA/main/scripts/install.sh | sh" >&2
  exit 1
fi

_http_ok() {
  if command -v curl >/dev/null 2>&1; then
    curl -sf "$1" >/dev/null 2>&1
  elif command -v wget >/dev/null 2>&1; then
    wget -qO /dev/null "$1" 2>/dev/null
  else
    return 1
  fi
}

PORT="${OSA_PORT:-9089}"

case "${1:-}" in
  version|--version|-v) exec "$RELEASE_BIN" version ;;
  setup)                exec "$RELEASE_BIN" setup ;;
  serve)                exec "$RELEASE_BIN" serve ;;
  doctor)               exec "$RELEASE_BIN" doctor ;;
  opencomputers)        shift; exec "$RELEASE_BIN" opencomputers "$@" ;;
  update)
    echo "To update OSA, re-run the installer:"
    echo "  curl -fsSL https://raw.githubusercontent.com/Miosa-osa/OSA/main/scripts/install.sh | sh"
    exit 0
    ;;
  help|--help|-h)
    echo ""
    echo "  OSA Agent — Your OS, Supercharged"
    echo ""
    echo "  Usage:"
    echo "    osa                Start backend + TUI (default)"
    echo "    osa setup          Configure provider / API keys"
    echo "    osa serve          Backend only (headless HTTP API)"
    echo "    osa doctor         Run health checks"
    echo "    osa version        Print version"
    echo "    osa opencomputers  Manage the MIOSA host connection"
    echo "    osa update         Update instructions"
    echo ""
    exit 0
    ;;
esac

# Default: start the backend (if not already up), then launch the TUI.
BACKEND_PID=""
cleanup() {
  if [ -n "$BACKEND_PID" ] && kill -0 "$BACKEND_PID" 2>/dev/null; then
    kill "$BACKEND_PID" 2>/dev/null || true
    wait "$BACKEND_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

if _http_ok "http://localhost:$PORT/health"; then
  : # backend already running
else
  "$RELEASE_BIN" serve >"$LOG_DIR/backend.log" 2>&1 &
  BACKEND_PID=$!
  i=0
  while [ "$i" -lt 40 ]; do
    if _http_ok "http://localhost:$PORT/health"; then
      break
    fi
    # If serve has already exited, waiting the full window is pointless. The
    # usual cause is the port being held by another process (bind failure).
    if [ -n "$BACKEND_PID" ] && ! kill -0 "$BACKEND_PID" 2>/dev/null; then
      break
    fi
    sleep 0.5
    i=$((i + 1))
  done
  if ! _http_ok "http://localhost:$PORT/health"; then
    if [ -n "$BACKEND_PID" ] && ! kill -0 "$BACKEND_PID" 2>/dev/null; then
      echo "OSA backend exited during startup — port $PORT is likely already in use." >&2
      echo "  - Another OSA instance or process may be bound to :$PORT." >&2
      echo "  - Start on a different port:  OSA_PORT=<number> osa" >&2
    else
      echo "OSA backend did not become healthy on port $PORT within ~20s." >&2
    fi
    echo "  - Inspect the log:  $LOG_DIR/backend.log" >&2
    echo "  - Run diagnostics:  osa doctor" >&2
  fi
fi

EXIT_CODE=0
"$TUI_BIN" "$@" || EXIT_CODE=$?
cleanup
trap - EXIT INT TERM
exit "$EXIT_CODE"
LAUNCHER_EOF
chmod +x "$LAUNCHER"
ok "Launcher installed"

# ---------------------------------------------------------------------------
# Wire PATH
# ---------------------------------------------------------------------------
on_path=false
_IFS="$IFS"; IFS=:
for dir in $PATH; do
  if [ "$dir" = "$BIN_DIR" ]; then on_path=true; break; fi
done
IFS="$_IFS"

if [ "$on_path" = "false" ]; then
  SHELL_NAME="$(basename "${SHELL:-/bin/sh}" 2>/dev/null || echo sh)"
  EXPORT_LINE="export PATH=\"${BIN_DIR}:\$PATH\""
  case "$SHELL_NAME" in
    zsh)  RC_FILE="${ZDOTDIR:-$HOME}/.zshrc" ;;
    bash) if [ -f "$HOME/.bash_profile" ]; then RC_FILE="$HOME/.bash_profile"; else RC_FILE="$HOME/.bashrc"; fi ;;
    fish) RC_FILE="$HOME/.config/fish/config.fish"; EXPORT_LINE="fish_add_path ${BIN_DIR}" ;;
    *)    RC_FILE="$HOME/.profile" ;;
  esac
  mkdir -p "$(dirname "$RC_FILE")"
  if [ ! -f "$RC_FILE" ] || ! grep -qF "$BIN_DIR" "$RC_FILE" 2>/dev/null; then
    printf "\n# OSA Agent\n%s\n" "$EXPORT_LINE" >> "$RC_FILE"
    ok "Added ${BIN_DIR} to PATH in ${RC_FILE}"
    RELOAD_HINT="$RC_FILE"
  fi
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
printf "\n${GREEN}${BOLD}  OSA ${VERSION} installed.${RESET}\n\n"
if [ -n "${RELOAD_HINT:-}" ]; then
  printf "  Reload your shell, then run ${BOLD}osa${RESET}:\n"
  printf "    ${DIM}. %s${RESET}\n\n" "$RELOAD_HINT"
else
  printf "  Run ${BOLD}osa${RESET} to start.\n\n"
fi
printf "  ${DIM}Update later: ${INSTALL_ONE_LINER}${RESET}\n\n"
