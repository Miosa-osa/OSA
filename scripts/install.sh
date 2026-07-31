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

_sha256_of() {
  # _sha256_of <file> — print the sha256 hex of <file>, or empty if no tool.
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    printf ''
  fi
}

_verify_asset() {
  # _verify_asset <file> <sha256_url> <label> — verify <file> against the sha256
  # sidecar at <sha256_url>. Fails hard on mismatch; warns (non-fatal) when the
  # sidecar is absent or no hashing tool exists — same policy as the tarball.
  _vf="$1"; _vurl="$2"; _vlabel="$3"; _vsum="${_vf}.sha256"
  if _download "$_vurl" "$_vsum" 2>/dev/null; then
    _vexpected="$(awk '{print $1}' "$_vsum")"
    _vactual="$(_sha256_of "$_vf")"
    if [ -z "$_vactual" ]; then
      warn "No sha256sum/shasum found — skipping ${_vlabel} verification."
    elif [ "$_vactual" != "$_vexpected" ]; then
      fail "Checksum mismatch for ${_vlabel} — download may be corrupted. Aborting." 3
    else
      ok "Checksum verified (${_vlabel})"
    fi
  else
    warn "No .sha256 sidecar for ${_vlabel} — skipping verification."
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
    warn "  curl -fsSL https://raw.githubusercontent.com/${GITHUB_REPO}/main/scripts/install-source.sh | bash"
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
# Sanity: the TUI is executed directly, so it must be a non-empty file (a 404 or
# truncated download would otherwise be copied in and fail later at exec time).
[ -s "${TMP_DIR}/${TUI_ASSET}" ] || fail "Downloaded ${TUI_ASSET} is empty — aborting." 2
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

# Verify the standalone TUI binary too (it is fetched separately from the
# tarball, so it needs its own checksum — supply-chain hardening, M2).
_verify_asset "${TMP_DIR}/${TUI_ASSET}" "${BASE_URL}/${TUI_ASSET}.sha256" "${TUI_ASSET}"

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
cp "${TMP_DIR}/${TUI_ASSET}" "$TUI_BIN" || fail "Could not write ${TUI_BIN}." 3
chmod +x "$TUI_BIN" || fail "Could not make ${TUI_BIN} executable." 3
[ -s "$TUI_BIN" ] && [ -x "$TUI_BIN" ] \
  || fail "${TUI_BIN} is empty or not executable after install." 3
# The TUI is exec'd directly by the launcher, so prove it actually runs here
# rather than discovering it at first launch.
TUI_REPORTED="$("$TUI_BIN" --version 2>/dev/null | head -1 | awk '{print $NF}')"
[ -n "$TUI_REPORTED" ] || fail "${TUI_BIN} did not run (--version produced no output)." 3
ok "TUI installed to ${TUI_BIN} (reports ${TUI_REPORTED})"

# macOS: best-effort clear of the com.apple.quarantine attribute. A curl/wget
# download does NOT set quarantine (only Finder/browser downloads do), so this
# is belt-and-suspenders — harmless and instant when the attribute is absent,
# but it spares anyone who fetched the assets via a GUI from a Gatekeeper prompt.
if [ "$OS" = "macos" ] && command -v xattr >/dev/null 2>&1; then
  xattr -dr com.apple.quarantine "$RELEASE_DIR" "$TUI_BIN" 2>/dev/null || true
fi

# Record install layout so tooling can locate the release, and stamp the
# installed version so `osa update` can compare against the latest release
# without booting the (slow) ERTS release just to read its vsn.
printf "%s\n" "$RELEASE_DIR" > "${OSA_HOME}/release_root"
printf "%s\n" "$VERSION" > "${OSA_HOME}/version"

# ---------------------------------------------------------------------------
# Write the `osa` launcher
#
# `osa` is the ONE command: it warms a background ERTS backend daemon (which
# SURVIVES TUI exit, so the next `osa` is instant), waits for /health, and
# launches the Rust TUI. It also owns overdrive (full auto), a real in-place
# `osa update`, `osa stop`, and a first-class `osa help`.
# ---------------------------------------------------------------------------
info "Writing launcher to ${LAUNCHER}..."
cat > "$LAUNCHER" <<'LAUNCHER_EOF'
#!/usr/bin/env bash
# osa — the one command to run OSA (prebuilt install under ~/.osa).
#
# Commands:
#   osa                    Attach the TUI (warms the backend daemon if needed)
#   osa overdrive          Launch in overdrive (full auto) — no approval prompts
#   osa continue           Resume the newest session in this directory
#   osa resume [id]        Resume a specific session (or pick one)
#   osa stop               Stop the background backend daemon
#   osa setup              Configure provider / API keys
#   osa update             Update in place, show what's new, then launch
#   osa doctor             Run backend health checks
#   osa serve              Run the backend in the foreground (headless API)
#   osa version            Print version
#   osa opencomputers ...  Manage the MIOSA host connection
#   osa help               Show this help
set -eu

GITHUB_REPO="Miosa-osa/OSA"
OSA_HOME="${OSA_HOME:-$HOME/.osa}"
export OSA_HOME
RELEASE_BIN="$OSA_HOME/release/bin/osagent"
TUI_BIN="$OSA_HOME/bin/osagent-tui"
LOG_DIR="$OSA_HOME/logs"
RUN_DIR="$OSA_HOME/run"
PID_FILE="$RUN_DIR/backend.pid"
PORT_FILE="$RUN_DIR/backend.port"
LOG_FILE="$LOG_DIR/backend.log"
mkdir -p "$LOG_DIR" "$RUN_DIR"

# ── Colors (OSA blue identity) ───────────────────────────────────
if [ -t 1 ]; then
  BOLD='\033[1m'; DIM='\033[2m'; GREEN='\033[0;32m'
  YELLOW='\033[0;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; RESET='\033[0m'
else
  BOLD=''; DIM=''; GREEN=''; YELLOW=''; RED=''; CYAN=''; RESET=''
fi

# Load user config (provider/model/keys) before booting the backend, so
# config/runtime.exs sees it. A single malformed .env line is warned, not fatal.
if [ -f "$OSA_HOME/.env" ]; then
  set +e; set +u; set -a
  . "$OSA_HOME/.env" 2>/dev/null \
    || echo "warning: some lines in $OSA_HOME/.env could not be parsed — ignoring them" >&2
  set +a; set -eu
fi

if [ ! -x "$RELEASE_BIN" ]; then
  echo "OSA is not installed correctly ($RELEASE_BIN missing)." >&2
  echo "Reinstall: curl -fsSL https://raw.githubusercontent.com/${GITHUB_REPO}/main/scripts/install.sh | sh" >&2
  exit 1
fi

PORT="${OSA_PORT:-9089}"
HEALTH_URL="http://localhost:${PORT}/health"

_http_ok() {
  if command -v curl >/dev/null 2>&1; then
    curl -sf "$1" >/dev/null 2>&1
  elif command -v wget >/dev/null 2>&1; then
    wget -qO /dev/null "$1" 2>/dev/null
  else
    return 1
  fi
}

_download() {
  # _download <url> <dest> — curl first, wget fallback. Returns 2 on failure.
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --retry-delay 2 -o "$2" "$1" || return 2
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$2" "$1" || return 2
  else
    echo "Neither curl nor wget is available." >&2; return 2
  fi
}

backend_healthy() { _http_ok "$HEALTH_URL"; }

daemon_pid() {
  # Echo the live daemon PID, or nothing (pidfile first, then port listener).
  pid=""
  if [ -f "$PID_FILE" ]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      echo "$pid"; return 0
    fi
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -ti ":${PORT}" -sTCP:LISTEN 2>/dev/null | head -1
  fi
}

clear_stale_pid() {
  if [ -f "$PID_FILE" ]; then
    p="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -z "$p" ] || ! kill -0 "$p" 2>/dev/null; then
      rm -f "$PID_FILE" "$PORT_FILE" 2>/dev/null || true
    fi
  fi
}

stop_daemon() {
  pid="$(daemon_pid)"
  if [ -z "$pid" ]; then
    printf "  ${DIM}No OSA backend is running on :%s.${RESET}\n" "$PORT"
    rm -f "$PID_FILE" "$PORT_FILE" 2>/dev/null || true
    return 0
  fi
  printf "  ${CYAN}→${RESET} Stopping OSA backend (pid %s)…\n" "$pid"
  # Prefer a process-group kill (the daemon is a setsid group leader, so this
  # also reaps the BEAM/erl child the release wrapper spawns); fall back to pid.
  kill -TERM -- "-${pid}" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  n=0
  while [ "$n" -lt 20 ]; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.25; n=$((n + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL -- "-${pid}" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  fi
  rm -f "$PID_FILE" "$PORT_FILE" 2>/dev/null || true
  printf "  ${GREEN}✓${RESET} Backend stopped.\n"
}

# Spinner while waiting for /health. 0 healthy, 1 timeout, 2 died.
# Re-reads the pidfile each tick so daemon death is caught even before the
# child has finished writing its PID. ASCII frames stay clean through `cut`.
wait_health() {
  max="${1:-40}"
  frames='|/-\'; i=0; n=0; ticks=$((max * 2))
  while [ "$n" -lt "$ticks" ]; do
    if backend_healthy; then
      [ -t 2 ] && printf '\r\033[K' >&2
      return 0
    fi
    wpid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "$wpid" ] && ! kill -0 "$wpid" 2>/dev/null; then
      [ -t 2 ] && printf '\r\033[K' >&2
      return 2
    fi
    if [ -t 2 ]; then
      f=$(printf '%s' "$frames" | cut -c $((i % 4 + 1)))
      printf '\r  %b%s%b warming OSA backend…' "$CYAN" "$f" "$RESET" >&2
      i=$((i + 1))
    fi
    sleep 0.5; n=$((n + 1))
  done
  [ -t 2 ] && printf '\r\033[K' >&2
  return 1
}

# Start the backend as a detached warm daemon (survives TUI exit + terminal
# close), recording the real PID so `osa stop` can reach it.
start_daemon() {
  : > "$LOG_FILE"
  printf "  ${CYAN}→${RESET} Starting OSA backend on :%s ${DIM}(background daemon)${RESET}\n" "$PORT"
  if command -v setsid >/dev/null 2>&1; then
    setsid sh -c 'echo $$ > "'"$PID_FILE"'"; exec "'"$RELEASE_BIN"'" serve' \
      >"$LOG_FILE" 2>&1 < /dev/null &
  else
    nohup "$RELEASE_BIN" serve >"$LOG_FILE" 2>&1 < /dev/null &
    echo $! > "$PID_FILE"
    disown 2>/dev/null || true
  fi
  echo "$PORT" > "$PORT_FILE"
}

warn_overdrive() {
  printf "  ${RED}${BOLD}⚠ OVERDRIVE (full auto)${RESET}${RED} — OSA will act without asking for approval.${RESET}\n" >&2
  printf "  ${DIM}  Only use this in a directory you trust. Confirm inside the TUI to proceed.${RESET}\n" >&2
}

print_help() {
  printf '\n'
  printf "${CYAN}${BOLD}    ___  ____    _   ${RESET}\n"
  printf "${CYAN}${BOLD}   / _ \\/ ___|  / \\  ${RESET}   ${BOLD}OSA${RESET} — the Optimal System Agent\n"
  printf "${CYAN}${BOLD}  | | | \\___ \\ / _ \\ ${RESET}   ${DIM}Your OS, supercharged.${RESET}\n"
  printf "${CYAN}${BOLD}  | |_| |___) / ___ \\${RESET}\n"
  printf "${CYAN}${BOLD}   \\___/|____/_/   \\_\\${RESET}\n"
  printf '\n'
  printf "  ${BOLD}Usage:${RESET} ${CYAN}osa${RESET} ${DIM}[command] [flags]${RESET}\n\n"
  printf "  ${BOLD}Commands${RESET}\n"
  printf "    ${CYAN}osa${RESET}                  Attach the TUI ${DIM}(warms the backend daemon if needed)${RESET}\n"
  printf "    ${CYAN}osa overdrive${RESET}        Launch in ${RED}overdrive (full auto)${RESET} ${DIM}— skips approval prompts${RESET}\n"
  printf "    ${CYAN}osa continue${RESET}         Resume the newest session in this folder\n"
  printf "    ${CYAN}osa resume${RESET} ${DIM}[id]${RESET}      Resume a specific session ${DIM}(or pick one)${RESET}\n"
  printf "    ${CYAN}osa stop${RESET}             Stop the background backend daemon\n"
  printf "    ${CYAN}osa setup${RESET}            Configure provider / API keys\n"
  printf "    ${CYAN}osa update${RESET}           Update in place, show what's new, then launch\n"
  printf "    ${CYAN}osa doctor${RESET}           Run backend health checks\n"
  printf "    ${CYAN}osa serve${RESET}            Run the backend in the foreground ${DIM}(headless API)${RESET}\n"
  printf "    ${CYAN}osa version${RESET}          Print version\n"
  printf "    ${CYAN}osa opencomputers${RESET}    Manage the MIOSA host connection\n"
  printf "    ${CYAN}osa help${RESET}             Show this help\n"
  printf '\n'
  printf "  ${BOLD}Flags${RESET} ${DIM}(forwarded to the TUI)${RESET}\n"
  printf "    ${CYAN}--overdrive${RESET}                     Full-auto mode ${DIM}(same as ${RESET}${CYAN}osa overdrive${RESET}${DIM})${RESET}\n"
  printf "    ${CYAN}--continue${RESET}                      Resume newest session here\n"
  printf "    ${CYAN}--resume${RESET} ${DIM}[id]${RESET}                 Resume a session\n"
  printf "    ${CYAN}--permission-mode${RESET} ${DIM}<mode>${RESET}      ask · auto-edit · plan · overdrive\n"
  printf '\n'
  printf "  ${DIM}The backend keeps running in the background so the next ${RESET}${CYAN}osa${RESET}${DIM} is instant.\n"
  printf "  ${DIM}Stop it any time with ${RESET}${CYAN}osa stop${RESET}${DIM}; it also idles down when unused.${RESET}\n"
  printf '\n'
}

# ── Version helpers ──────────────────────────────────────────────
# Normalize a version for comparison: drop a leading "v", drop any
# pre-release/build suffix, and strip the display zero-padding from the patch
# component so the release tag (v1.0.045), the backend (1.0.45) and the TUI's
# padded `--version` output (1.0.045) all compare equal.
_norm_version() {
  printf '%s' "${1#v}" | awk -F'[-+]' '{print $1}' \
    | awk -F. '{ if (NF == 3 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/)
                   printf "%d.%d.%d", $1, $2, $3
                 else printf "%s", $0 }'
}

# The version actually baked into the INSTALLED TUI binary. This is the
# diagnostic that separates "backend updated but the TUI didn't" from a mere
# display bug — the stamp in ~/.osa/version only records what we *intended* to
# install. Empty output means the binary is missing/unrunnable.
_installed_tui_version() {
  [ -x "$TUI_BIN" ] || return 1
  "$TUI_BIN" --version 2>/dev/null | head -1 | awk '{print $NF}'
}

# True when the installed TUI binary really reports version $1.
_tui_is_version() {
  _want="$(_norm_version "$1")"
  _got="$(_norm_version "$(_installed_tui_version || true)")"
  [ -n "$_got" ] && [ "$_want" = "$_got" ]
}

# ── Real in-place update: download prebuilt release + TUI, verify sha256,
# atomically swap under ~/.osa, print the delta + what's new, then launch. ──
#
# NOTE: this function is invoked as `do_update || exit $?`, which SUPPRESSES
# `set -e` for its entire body. Every mutating command below must therefore
# check its own exit status explicitly — an unchecked failure here is exactly
# how a half-applied update (new backend, old TUI) used to be reported as
# success.
do_update() {
  os=""; arch=""
  case "$(uname -s)" in
    Darwin) os="macos" ;;
    Linux)  os="linux" ;;
    *) printf "  ${RED}✗${RESET} Unsupported OS for auto-update: %s\n" "$(uname -s)" >&2; return 1 ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) arch="arm64" ;;
    x86_64|amd64)  arch="x64" ;;
    *) printf "  ${RED}✗${RESET} Unsupported arch for auto-update: %s\n" "$(uname -m)" >&2; return 1 ;;
  esac
  platform="${os}-${arch}"
  tarball="osa-${platform}.tar.gz"
  tui_asset="osagent-tui-${platform}"

  cur="$(cat "$OSA_HOME/version" 2>/dev/null || echo unknown)"
  printf "  ${CYAN}→${RESET} Current version: %s\n" "$cur"
  printf "  ${CYAN}→${RESET} Checking for updates…\n"

  meta="$(mktemp "${TMPDIR:-/tmp}/osa-meta.XXXXXX")"
  if ! _download "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" "$meta"; then
    rm -f "$meta"
    printf "  ${RED}✗${RESET} Could not reach the GitHub API. Try again later.\n" >&2
    return 2
  fi

  # Extract tag + release notes. python3 handles the multiline JSON body
  # robustly; fall back to grep/sed for the tag alone.
  if command -v python3 >/dev/null 2>&1; then
    latest="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("tag_name","") or "")' "$meta" 2>/dev/null)"
    notes="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("body","") or "")' "$meta" 2>/dev/null)"
  else
    latest="$(grep '"tag_name"' "$meta" | head -1 | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')"
    notes=""
  fi
  rm -f "$meta"

  if [ -z "$latest" ]; then
    printf "  ${RED}✗${RESET} Could not determine the latest release.\n" >&2
    return 2
  fi
  if [ "$latest" = "$cur" ]; then
    # The version stamp only records what we INTENDED to install. If a previous
    # update half-applied (backend swapped, TUI binary not), the stamp says we
    # are current while the TUI still runs old code — and every later
    # `osa update` would no-op forever. Verify against the real binary and
    # self-heal by re-installing instead of lying.
    if _tui_is_version "$latest"; then
      printf "  ${GREEN}✓${RESET} Already up to date ${DIM}(%s)${RESET}\n" "$cur"
      return 0
    fi
    tui_now="$(_installed_tui_version || true)"
    printf "  ${YELLOW}!${RESET} Version stamp says %s but the TUI binary reports %s — repairing.\n" \
      "$cur" "${tui_now:-<unreadable>}" >&2
  else
    printf "  ${CYAN}→${RESET} New version available: ${BOLD}%s${RESET}\n" "$latest"
  fi

  base="https://github.com/${GITHUB_REPO}/releases/download/${latest}"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/osa-update.XXXXXX")"

  printf "  ${CYAN}→${RESET} Downloading %s…\n" "$tarball"
  if ! _download "${base}/${tarball}" "${tmp}/${tarball}"; then
    rm -rf "$tmp"; printf "  ${RED}✗${RESET} Download failed for %s.\n" "$tarball" >&2; return 2
  fi
  printf "  ${CYAN}→${RESET} Downloading %s…\n" "$tui_asset"
  if ! _download "${base}/${tui_asset}" "${tmp}/${tui_asset}"; then
    rm -rf "$tmp"; printf "  ${RED}✗${RESET} Download failed for %s.\n" "$tui_asset" >&2; return 2
  fi
  [ -s "${tmp}/${tui_asset}" ] || { rm -rf "$tmp"; printf "  ${RED}✗${RESET} Downloaded %s is empty — aborting update.\n" "$tui_asset" >&2; return 2; }

  # Verify the tarball checksum (mandatory when the sidecar exists).
  printf "  ${CYAN}→${RESET} Verifying checksum…\n"
  if _download "${base}/${tarball}.sha256" "${tmp}/${tarball}.sha256" 2>/dev/null; then
    expected="$(awk '{print $1}' "${tmp}/${tarball}.sha256")"
    actual=""
    if command -v sha256sum >/dev/null 2>&1; then
      actual="$(sha256sum "${tmp}/${tarball}" | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
      actual="$(shasum -a 256 "${tmp}/${tarball}" | awk '{print $1}')"
    fi
    if [ -n "$actual" ] && [ "$actual" != "$expected" ]; then
      rm -rf "$tmp"
      printf "  ${RED}✗${RESET} Checksum mismatch — aborting update.\n" >&2
      return 3
    fi
    [ -n "$actual" ] && printf "  ${GREEN}✓${RESET} Checksum verified\n"
  else
    printf "  ${YELLOW}!${RESET} No .sha256 sidecar — skipping verification.\n" >&2
  fi

  # Verify the TUI binary checksum too (fetched separately — supply-chain, M2).
  if _download "${base}/${tui_asset}.sha256" "${tmp}/${tui_asset}.sha256" 2>/dev/null; then
    texpected="$(awk '{print $1}' "${tmp}/${tui_asset}.sha256")"
    tactual=""
    if command -v sha256sum >/dev/null 2>&1; then
      tactual="$(sha256sum "${tmp}/${tui_asset}" | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
      tactual="$(shasum -a 256 "${tmp}/${tui_asset}" | awk '{print $1}')"
    fi
    if [ -n "$tactual" ] && [ "$tactual" != "$texpected" ]; then
      rm -rf "$tmp"
      printf "  ${RED}✗${RESET} Checksum mismatch for %s — aborting update.\n" "$tui_asset" >&2
      return 3
    fi
    [ -n "$tactual" ] && printf "  ${GREEN}✓${RESET} Checksum verified (%s)\n" "$tui_asset"
  else
    printf "  ${YELLOW}!${RESET} No .sha256 sidecar for %s — skipping verification.\n" "$tui_asset" >&2
  fi

  # Extract the new release beside the current one (same filesystem → atomic
  # rename), then swap. Stop the old daemon first so it releases the old files.
  printf "  ${CYAN}→${RESET} Installing update…\n"
  stop_daemon >/dev/null 2>&1 || true

  new_rel="$OSA_HOME/release.new"
  rm -rf "$new_rel"; mkdir -p "$new_rel"
  if ! tar -xzf "${tmp}/${tarball}" -C "$new_rel" 2>/dev/null; then
    rm -rf "$tmp" "$new_rel"
    printf "  ${RED}✗${RESET} Extraction failed — your existing install is untouched.\n" >&2
    return 3
  fi
  [ -f "$new_rel/bin/osagent" ] || { rm -rf "$tmp" "$new_rel"; printf "  ${RED}✗${RESET} Bad release archive — aborting.\n" >&2; return 3; }
  chmod +x "$new_rel/bin/osagent" 2>/dev/null || true

  # Stage the new TUI binary BEFORE touching the live release dir, so a failure
  # to write it aborts while the install is still fully consistent.
  mkdir -p "$(dirname "$TUI_BIN")" || {
    rm -rf "$tmp" "$new_rel"
    printf "  ${RED}✗${RESET} Could not create %s — aborting update.\n" "$(dirname "$TUI_BIN")" >&2
    return 3
  }
  if ! cp "${tmp}/${tui_asset}" "${TUI_BIN}.new" || ! chmod +x "${TUI_BIN}.new"; then
    rm -f "${TUI_BIN}.new"; rm -rf "$tmp" "$new_rel"
    printf "  ${RED}✗${RESET} Could not stage the new TUI binary at %s.new — aborting update.\n" "$TUI_BIN" >&2
    printf "  ${DIM}  Your existing install is untouched. Check disk space and permissions.${RESET}\n" >&2
    return 3
  fi

  # Atomic swap of the release dir.
  rm -rf "$OSA_HOME/release.old"
  mv "$OSA_HOME/release" "$OSA_HOME/release.old" 2>/dev/null || true
  if ! mv "$new_rel" "$OSA_HOME/release"; then
    # Put the old release back so the install is not left headless.
    mv "$OSA_HOME/release.old" "$OSA_HOME/release" 2>/dev/null || true
    rm -f "${TUI_BIN}.new"; rm -rf "$tmp" "$new_rel"
    printf "  ${RED}✗${RESET} Could not install the new backend release — aborting update.\n" >&2
    return 3
  fi
  rm -rf "$OSA_HOME/release.old"

  # Atomic swap of the TUI binary. This is the step that previously ran
  # unchecked: when it failed the launcher kept exec'ing the OLD TUI while the
  # version stamp was rewritten to the new tag, so `osa update` printed success
  # and the TUI kept showing the old version forever.
  if ! mv "${TUI_BIN}.new" "$TUI_BIN"; then
    rm -f "${TUI_BIN}.new"; rm -rf "$tmp"
    printf "  ${RED}✗${RESET} Could not replace the TUI binary at %s.\n" "$TUI_BIN" >&2
    printf "  ${DIM}  The backend was updated but the TUI was NOT — the install is INCONSISTENT.${RESET}\n" >&2
    printf "  ${DIM}  Repair with:${RESET} ${CYAN}%s${RESET}\n" \
      "curl -fsSL https://raw.githubusercontent.com/${GITHUB_REPO}/main/scripts/install.sh | sh" >&2
    return 3
  fi

  # macOS: best-effort quarantine strip on the freshly swapped-in binaries.
  case "$(uname -s)" in
    Darwin) command -v xattr >/dev/null 2>&1 && xattr -dr com.apple.quarantine "$OSA_HOME/release" "$TUI_BIN" 2>/dev/null || true ;;
  esac

  # Post-swap verification. Only stamp the new version once BOTH halves are
  # actually on disk, executable, non-empty, and the TUI really reports the
  # version we just installed. Failing loudly here is the whole point: a stamp
  # written over a half-applied update makes every later `osa update` a no-op.
  if [ ! -s "$OSA_HOME/release/bin/osagent" ] || [ ! -x "$OSA_HOME/release/bin/osagent" ]; then
    rm -rf "$tmp"
    printf "  ${RED}✗${RESET} Backend binary missing or not executable after update (%s).\n" \
      "$OSA_HOME/release/bin/osagent" >&2
    return 3
  fi
  if [ ! -s "$TUI_BIN" ] || [ ! -x "$TUI_BIN" ]; then
    rm -rf "$tmp"
    printf "  ${RED}✗${RESET} TUI binary missing, empty, or not executable after update (%s).\n" "$TUI_BIN" >&2
    printf "  ${DIM}  Repair with:${RESET} ${CYAN}%s${RESET}\n" \
      "curl -fsSL https://raw.githubusercontent.com/${GITHUB_REPO}/main/scripts/install.sh | sh" >&2
    return 3
  fi
  if ! _tui_is_version "$latest"; then
    tui_now="$(_installed_tui_version || true)"
    rm -rf "$tmp"
    printf "  ${RED}✗${RESET} TUI still reports %s after updating to %s — the update did not take.\n" \
      "${tui_now:-<unreadable>}" "$latest" >&2
    printf "  ${DIM}  Not stamping the new version, so ${RESET}${CYAN}osa update${RESET}${DIM} will retry.${RESET}\n" >&2
    printf "  ${DIM}  Repair with:${RESET} ${CYAN}%s${RESET}\n" \
      "curl -fsSL https://raw.githubusercontent.com/${GITHUB_REPO}/main/scripts/install.sh | sh" >&2
    return 3
  fi
  printf "  ${GREEN}✓${RESET} TUI binary verified ${DIM}(reports %s)${RESET}\n" "$(_installed_tui_version)"

  printf "%s\n" "$OSA_HOME/release" > "$OSA_HOME/release_root"
  printf "%s\n" "$latest" > "$OSA_HOME/version"
  rm -rf "$tmp"

  printf '\n'
  printf "  ${GREEN}${BOLD}✓ Updated ${RESET}${DIM}%s${RESET} → ${BOLD}%s${RESET}\n" "$cur" "$latest"
  printf '\n'
  printf "  ${BOLD}What's new${RESET}\n"
  if [ -n "$notes" ]; then
    printf '%s\n' "$notes" | sed 's/^/    /' | head -30
  else
    printf "    See ${CYAN}https://github.com/%s/releases/tag/%s${RESET}\n" "$GITHUB_REPO" "$latest"
  fi
  printf '\n'
  if [ -t 0 ]; then
    printf "  ${DIM}Press Enter to launch OSA…${RESET} "
    read -r _ || true
  fi
  return 0
}

# ── Subcommand pre-translation (verbs → TUI flags, then fall through) ──
OVERDRIVE=0
case "${1:-}" in
  overdrive)
    OVERDRIVE=1; shift; set -- "$@" "--overdrive"
    ;;
  continue)
    shift; set -- "$@" "--continue"
    ;;
  resume)
    shift
    if [ -n "${1:-}" ] && [ "${1#-}" = "${1:-}" ]; then
      rid="$1"; shift; set -- "$@" "--resume" "$rid"
    else
      set -- "$@" "--resume"
    fi
    ;;
esac

for a in "$@"; do
  case "$a" in
    --overdrive|--dangerously-skip-permissions|--yolo) OVERDRIVE=1 ;;
  esac
done

# ── Subcommand dispatch ───────────────────────────────────────────
case "${1:-}" in
  version|--version|-v)
    # Report BOTH halves. `osa update` swaps a backend release and a separate
    # TUI binary; printing only the backend hides a half-applied update, which
    # is precisely how "I updated but the TUI shows the old version" happens.
    "$RELEASE_BIN" version || true
    if [ -x "$TUI_BIN" ]; then
      tui_v="$(_installed_tui_version || true)"
      printf "osagent-tui %s\n" "${tui_v:-<unreadable>}"
    else
      printf "osagent-tui <not installed at %s>\n" "$TUI_BIN" >&2
    fi
    stamp="$(cat "$OSA_HOME/version" 2>/dev/null || echo unknown)"
    printf "installed release stamp %s\n" "$stamp"
    if [ "$stamp" != "unknown" ] && ! _tui_is_version "$stamp"; then
      printf "  ${YELLOW}!${RESET} TUI does not match the installed release stamp — run ${CYAN}osa update${RESET} to repair.\n" >&2
    fi
    exit 0
    ;;
  setup)                exec "$RELEASE_BIN" setup ;;
  serve)                exec "$RELEASE_BIN" serve ;;
  doctor)               exec "$RELEASE_BIN" doctor ;;
  opencomputers)        shift; exec "$RELEASE_BIN" opencomputers "$@" ;;
  stop)                 stop_daemon; exit 0 ;;
  update)
    shift || true
    do_update || exit $?
    # fall through to launch on success
    ;;
  help|--help|-h)       print_help; exit 0 ;;
esac

# ── Default: warm the daemon (attach instantly if healthy), then TUI ──
if backend_healthy; then
  printf "  ${DIM}Backend already running on :%s — attaching.${RESET}\n" "$PORT"
else
  clear_stale_pid
  start_daemon
  rc=0
  wait_health 40 || rc=$?
  if [ "${rc:-0}" -eq 2 ]; then
    if command -v lsof >/dev/null 2>&1 && lsof -i ":${PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
      printf "  ${RED}✗${RESET} Backend exited during startup — port %s is already in use.\n" "$PORT" >&2
      printf "  ${DIM}  Start on another port:${RESET} ${CYAN}OSA_PORT=<n> osa${RESET}${DIM}, or ${RESET}${CYAN}osa stop${RESET}${DIM} first.${RESET}\n" >&2
    else
      printf "  ${RED}✗${RESET} Backend exited during startup.\n" >&2
    fi
    printf "  ${DIM}  Inspect the log: %s${RESET}\n" "$LOG_FILE" >&2
    rm -f "$PID_FILE" "$PORT_FILE" 2>/dev/null || true
    exit 1
  elif [ "${rc:-0}" -eq 1 ]; then
    printf "  ${RED}✗${RESET} Backend did not become healthy on :%s in time.\n" "$PORT" >&2
    printf "  ${DIM}  Inspect the log: %s   ·   Run: ${RESET}${CYAN}osa doctor${RESET}\n" "$LOG_FILE" >&2
    exit 1
  fi
  printf "  ${DIM}Backend ready. It stays warm in the background — ${RESET}${CYAN}osa stop${RESET}${DIM} to shut it down.${RESET}\n"
fi

# Show the overdrive warning right before handing off to the TUI.
[ "$OVERDRIVE" -eq 1 ] && warn_overdrive

# Launch the TUI. The backend daemon deliberately OUTLIVES this process, so the
# next `osa` attaches instantly. No cleanup trap — that is the whole point.
export OSA_URL="http://localhost:${PORT}"
exec "$TUI_BIN" "$@"
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
printf "  ${DIM}Update later: run ${RESET}${BOLD}osa update${RESET}${DIM} (in-place). Or reinstall: ${INSTALL_ONE_LINER}${RESET}\n\n"
