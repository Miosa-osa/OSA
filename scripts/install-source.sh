#!/usr/bin/env bash
# scripts/install.sh — One-line installer for OSA Agent.
#
# Usage:
#   macOS/Linux: curl -fsSL https://raw.githubusercontent.com/Miosa-osa/OptimalSystemAgent/main/scripts/install.sh | bash
#   Windows:     irm https://raw.githubusercontent.com/Miosa-osa/OptimalSystemAgent/main/scripts/install.ps1 | iex
#
# Supported:
#   macOS (ARM + Intel), Ubuntu, Debian, Fedora, RHEL/Rocky/Alma,
#   Arch, Alpine, openSUSE, Amazon Linux, WSL2, Windows (via install.ps1)
#
# What it does:
#   1. Auto-installs ALL prerequisites — no questions asked
#   2. Clones repo to ~/.osa/agent/ (or updates existing)
#   3. Installs native build dependencies for Rust TUI
#   4. Builds the Rust TUI
#   5. Fetches Elixir dependencies & compiles
#   6. Installs `osa` and `osagent` to ~/.local/bin
#   7. Sets up PATH if needed

set -euo pipefail

# ── Safe defaults ────────────────────────────────────────────────
HOME="${HOME:-/root}"
export LC_ALL="${LC_ALL:-C.UTF-8}"
export LANG="${LANG:-C.UTF-8}"

# sudo helper: skip when already root
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

# ── Colors ─────────────────────────────────────────────────────────
if [ -t 1 ]; then
  BOLD='\033[1m'
  DIM='\033[2m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  RED='\033[0;31m'
  CYAN='\033[0;36m'
  RESET='\033[0m'
else
  BOLD='' DIM='' GREEN='' YELLOW='' RED='' CYAN='' RESET=''
fi

info()  { echo -e "${CYAN}→${RESET} $*"; }
ok()    { echo -e "${GREEN}✓${RESET} $*"; }
warn()  { echo -e "${YELLOW}⚠${RESET} $*"; }
fail()  { echo -e "${RED}✗${RESET} $*"; exit 1; }

# ── Config ─────────────────────────────────────────────────────────
OSA_DIR="${HOME}/.osa"
INSTALL_DIR="${HOME}/.local/bin"
REPO_URL="${OSA_REPO_URL:-https://github.com/Miosa-osa/OSA.git}"
BRANCH="${OSA_BRANCH:-main}"
AGENT_DIR="${OSA_DIR}/agent"

# Minimum required versions
MIN_ELIXIR_MAJOR=1
MIN_ELIXIR_MINOR=17
MIN_OTP_MAJOR=26

# ── Banner ─────────────────────────────────────────────────────────
# Cyan/blue ASCII logo. Colors are empty when stdout is not a TTY, so this
# degrades to plain text. The art is emitted via a quoted heredoc so the
# backslashes are never interpreted.
echo ""
printf '%b' "${CYAN}${BOLD}"
cat <<'OSA_LOGO'
    ___  ____    _
   / _ \/ ___|  / \
  | | | \___ \ / _ \
  | |_| |___) / ___ \
   \___/|____/_/   \_\
OSA_LOGO
printf '%b' "${RESET}"
echo -e "${BOLD}  OSA Agent — Installer${RESET}"
echo -e "${DIM}  Your OS, Supercharged · builds from source${RESET}"
echo ""

# ── Detect OS + package manager ──────────────────────────────────
detect_os() {
  case "$(uname -s)" in
    Darwin) OS="macos"; PKG="brew" ;;
    Linux)  OS="linux"
      if   command -v apt-get >/dev/null 2>&1; then PKG="apt"
      elif command -v dnf     >/dev/null 2>&1; then PKG="dnf"
      elif command -v pacman  >/dev/null 2>&1; then PKG="pacman"
      elif command -v apk     >/dev/null 2>&1; then PKG="apk"
      elif command -v zypper  >/dev/null 2>&1; then PKG="zypper"
      elif command -v yum     >/dev/null 2>&1; then PKG="yum"
      else PKG="unknown"
      fi
      ;;
    MINGW*|MSYS*|CYGWIN*) OS="windows"; PKG="unknown" ;;
    *) fail "Unsupported OS: $(uname -s)" ;;
  esac
}
detect_os

if [ "$OS" = "windows" ]; then
  warn "Windows detected via Git Bash/MSYS2."
  info "For best results, use the PowerShell installer instead:"
  echo ""
  echo "    irm https://raw.githubusercontent.com/Miosa-osa/OptimalSystemAgent/main/scripts/install.ps1 | iex"
  echo ""
  info "Or use WSL2 (Ubuntu) for a full Linux experience."
  echo ""
  # Try to run the PowerShell installer directly if powershell is available
  if command -v powershell.exe >/dev/null 2>&1; then
    info "Launching PowerShell installer..."
    powershell.exe -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/Miosa-osa/OptimalSystemAgent/main/scripts/install.ps1 | iex"
    exit $?
  fi
  fail "Cannot auto-install on Windows from bash. Use the PowerShell command above."
fi

echo -e "${DIM}  OS: $OS | Package manager: $PKG${RESET}"
echo ""

# ── Helpers ──────────────────────────────────────────────────────
check_cmd() { command -v "$1" >/dev/null 2>&1; }

# Check if Elixir version >= 1.17
check_elixir_version() {
  local ver major minor
  ver=$(elixir --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  [ -z "$ver" ] && return 1
  major=$(echo "$ver" | cut -d. -f1)
  minor=$(echo "$ver" | cut -d. -f2)
  if [ "${major:-0}" -lt "$MIN_ELIXIR_MAJOR" ] || \
     { [ "${major:-0}" -eq "$MIN_ELIXIR_MAJOR" ] && [ "${minor:-0}" -lt "$MIN_ELIXIR_MINOR" ]; }; then
    return 1
  fi
  return 0
}

# Package install abstraction
pkg_install() {
  case "$PKG" in
    apt)    $SUDO apt-get install -y -qq "$@" ;;
    dnf)    $SUDO dnf install -y -q "$@" ;;
    yum)    $SUDO yum install -y -q "$@" ;;
    pacman) $SUDO pacman -Sy --noconfirm "$@" ;;
    apk)    $SUDO apk add --no-cache "$@" ;;
    zypper) $SUDO zypper install -y "$@" ;;
    *)      return 1 ;;
  esac
}

pkg_update() {
  case "$PKG" in
    apt)    $SUDO apt-get update -qq ;;
    dnf|yum) $SUDO dnf check-update -q 2>/dev/null || true ;;
    pacman) $SUDO pacman -Sy ;;
    apk)    $SUDO apk update ;;
    zypper) $SUDO zypper refresh -q ;;
  esac
}

# ── Setup locale (Linux) ─────────────────────────────────────────
if [ "$OS" = "linux" ]; then
  if ! locale 2>/dev/null | grep -qi "utf-8" 2>/dev/null; then
    info "Setting up UTF-8 locale..."
    case "$PKG" in
      apt)
        pkg_install locales 2>/dev/null || true
        $SUDO locale-gen en_US.UTF-8 2>/dev/null || true
        ;;
      dnf|yum)
        pkg_install glibc-langpack-en 2>/dev/null || true
        ;;
      apk)
        # Alpine: musl doesn't have locale-gen, set env vars
        ;;
    esac
    export LANG=en_US.UTF-8
    export LC_ALL=en_US.UTF-8
  fi
fi

# ── Install git if missing ─────────────────────────────────────────
if ! check_cmd git; then
  if [ "$OS" = "macos" ]; then
    info "Installing Xcode Command Line Tools (includes git)..."
    xcode-select --install 2>/dev/null || true
    local attempts=0
    until check_cmd git || [ $attempts -ge 120 ]; do
      sleep 2
      attempts=$((attempts + 1))
    done
    check_cmd git || fail "git installation timed out. Install Xcode CLT manually: xcode-select --install"
  elif [ "$OS" = "linux" ]; then
    info "Installing git..."
    pkg_update
    pkg_install git
  fi
  check_cmd git || fail "git installation failed."
  ok "git installed"
fi

# ── Install curl if missing ────────────────────────────────────────
if ! check_cmd curl; then
  info "Installing curl..."
  pkg_install curl 2>/dev/null || true
  check_cmd curl || fail "curl is required. Install it manually."
  ok "curl installed"
fi

# ── Install Rust if missing ───────────────────────────────────────
if ! check_cmd cargo; then
  info "Installing Rust (needed for the TUI)..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --quiet
  . "${HOME}/.cargo/env" 2>/dev/null || true
  export PATH="${HOME}/.cargo/bin:$PATH"
  check_cmd cargo || fail "Rust installation failed. Install manually: https://rustup.rs"
  ok "Rust installed"
else
  ok "Rust found: $(rustc --version 2>/dev/null || echo 'unknown')"
fi

# ── Install Erlang + Elixir ──────────────────────────────────────
install_elixir_from_prebuilt() {
  # Download prebuilt Elixir from GitHub releases (works on any OS with OTP installed)
  local elixir_ver="1.18.3"
  local otp_major
  otp_major=$(erl -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().' -noshell 2>/dev/null || echo "27")
  local url="https://github.com/elixir-lang/elixir/releases/download/v${elixir_ver}/elixir-otp-${otp_major}.zip"

  info "Installing Elixir ${elixir_ver} from prebuilt release..."
  local dest="/usr/local/lib/elixir"
  $SUDO mkdir -p "$dest"
  if curl -fsSLo /tmp/elixir.zip "$url" 2>/dev/null; then
    $SUDO unzip -qo /tmp/elixir.zip -d "$dest"
    rm -f /tmp/elixir.zip
    # Symlink binaries
    for bin in elixir mix iex elixirc; do
      $SUDO ln -sf "$dest/bin/$bin" /usr/local/bin/"$bin"
    done
    ok "Elixir ${elixir_ver} installed from prebuilt"
  else
    fail "Could not download Elixir prebuilt. Install Elixir 1.17+ manually: https://elixir-lang.org/install.html"
  fi
}

install_erlang_and_elixir() {
  info "Installing Erlang + Elixir..."

  if [ "$OS" = "macos" ]; then
    if ! check_cmd brew; then
      info "Installing Homebrew first..."
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      if [ -f "/opt/homebrew/bin/brew" ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
      elif [ -f "/usr/local/bin/brew" ]; then
        eval "$(/usr/local/bin/brew shellenv)"
      fi
    fi
    brew install erlang elixir
    ok "Erlang + Elixir installed via Homebrew"
    return 0
  fi

  # Linux: install Erlang first, then ensure Elixir version is correct
  case "$PKG" in
    apt)
      pkg_update
      pkg_install software-properties-common apt-transport-https 2>/dev/null || true
      # Try system packages first
      pkg_install erlang elixir 2>/dev/null || {
        # Fallback: Erlang Solutions
        info "System packages too old or missing, trying Erlang Solutions..."
        curl -fsSLo /tmp/erlang-solutions.deb \
          https://packages.erlang-solutions.com/erlang-solutions_2.0_all.deb 2>/dev/null || true
        if [ -f /tmp/erlang-solutions.deb ]; then
          $SUDO dpkg -i /tmp/erlang-solutions.deb 2>/dev/null || true
          rm -f /tmp/erlang-solutions.deb
          pkg_update
          pkg_install esl-erlang elixir 2>/dev/null || pkg_install esl-erlang 2>/dev/null
        fi
      }
      ;;
    dnf|yum)
      # Enable EPEL if on RHEL/CentOS/Rocky/Alma
      if [ -f /etc/redhat-release ]; then
        pkg_install epel-release 2>/dev/null || true
      fi
      pkg_install erlang elixir 2>/dev/null || {
        # Fallback: Erlang Solutions RPM
        info "System packages too old or missing, trying Erlang Solutions..."
        curl -fsSLo /tmp/erlang-solutions.rpm \
          https://packages.erlang-solutions.com/erlang-solutions-2.0-1.noarch.rpm 2>/dev/null || true
        if [ -f /tmp/erlang-solutions.rpm ]; then
          $SUDO rpm -Uvh /tmp/erlang-solutions.rpm 2>/dev/null || true
          rm -f /tmp/erlang-solutions.rpm
          pkg_install esl-erlang elixir 2>/dev/null || pkg_install esl-erlang 2>/dev/null
        fi
      }
      ;;
    pacman)
      pkg_install erlang elixir
      ;;
    apk)
      pkg_install erlang elixir 2>/dev/null || pkg_install erlang 2>/dev/null
      ;;
    zypper)
      pkg_install erlang elixir 2>/dev/null || pkg_install erlang 2>/dev/null
      ;;
    *)
      fail "No supported package manager found. Install Erlang 26+ and Elixir 1.17+ manually."
      ;;
  esac

  # Check if Erlang is installed (minimum requirement)
  if ! check_cmd erl; then
    fail "Erlang installation failed. Install OTP 26+ manually: https://www.erlang.org/downloads"
  fi

  # Check Elixir version — if missing or too old, install from prebuilt
  if ! check_cmd elixir || ! check_elixir_version; then
    local installed_ver=""
    if check_cmd elixir; then
      installed_ver=$(elixir --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
      warn "Elixir ${installed_ver} is too old (need 1.17+). Installing prebuilt..."
    fi
    # Ensure unzip is available for the prebuilt install
    check_cmd unzip || pkg_install unzip 2>/dev/null || true
    install_elixir_from_prebuilt
  fi
}

if ! check_cmd elixir || ! check_cmd mix; then
  install_erlang_and_elixir
elif ! check_elixir_version; then
  installed_ver=$(elixir --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  warn "Elixir ${installed_ver} found but need 1.17+. Upgrading..."
  check_cmd unzip || pkg_install unzip 2>/dev/null || true
  install_elixir_from_prebuilt
else
  ok "Elixir found: $(elixir --version 2>/dev/null | tail -1 || echo 'unknown')"
fi

# Final verification
check_cmd elixir || fail "Elixir installation failed. Install Elixir 1.17+ manually."
check_cmd erl    || fail "Erlang installation failed. Install OTP 26+ manually."
check_elixir_version || fail "Elixir version too old. Need 1.17+, have: $(elixir --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"

# ── Local checkout detection (must run BEFORE clone) ─────────────
# When this script is launched from inside a cloned repo (e.g. via
# `bin/install`), use the existing checkout instead of cloning anew.
SCRIPT_SELF="${BASH_SOURCE[0]:-$0}"
LOCAL_CHECKOUT=""
if [ -f "$(dirname "$SCRIPT_SELF")/../mix.exs" ] 2>/dev/null; then
  LOCAL_CHECKOUT="$(cd "$(dirname "$SCRIPT_SELF")/.." && pwd)"
fi

# ── Clone or update repo ──────────────────────────────────────────
mkdir -p "$OSA_DIR"

if [ -n "$LOCAL_CHECKOUT" ]; then
  AGENT_DIR="$LOCAL_CHECKOUT"
  info "Running from local checkout: $AGENT_DIR"
elif [ -d "$AGENT_DIR/.git" ]; then
  info "Updating existing installation..."
  (cd "$AGENT_DIR" && git pull --ff-only origin "$BRANCH" 2>&1) || true
  ok "Updated"
elif [ -d "$AGENT_DIR" ]; then
  info "Using existing directory: $AGENT_DIR"
else
  info "Cloning OSA Agent..."
  git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$AGENT_DIR" 2>&1 | tail -2
  ok "Cloned to $AGENT_DIR"
fi

echo "$AGENT_DIR" > "$OSA_DIR/project_root"

# ── Install native build dependencies ────────────────────────────
# Required by Rust TUI crates:
#   arboard  → libxcb (X11 clipboard)
#   cpal     → libasound (ALSA audio)
#   syntect  → libonig (Oniguruma regex)
#   reqwest  → libssl (TLS)
#   general  → pkg-config, gcc/cc

info "Installing build dependencies..."
case "$PKG" in
  apt)
    pkg_install \
      build-essential pkg-config \
      libssl-dev \
      libxcb1-dev libxcb-render0-dev libxcb-shape0-dev libxcb-xfixes0-dev \
      libasound2-dev \
      libonig-dev \
      2>/dev/null || warn "Some build deps could not be installed (non-fatal)"
    ;;
  dnf|yum)
    pkg_install \
      gcc gcc-c++ make pkg-config \
      openssl-devel \
      libxcb-devel \
      alsa-lib-devel \
      oniguruma-devel \
      2>/dev/null || warn "Some build deps could not be installed (non-fatal)"
    ;;
  pacman)
    pkg_install \
      base-devel pkg-config \
      openssl \
      libxcb \
      alsa-lib \
      oniguruma \
      2>/dev/null || warn "Some build deps could not be installed (non-fatal)"
    ;;
  apk)
    pkg_install \
      build-base pkgconfig \
      openssl-dev \
      libxcb-dev \
      alsa-lib-dev \
      oniguruma-dev \
      2>/dev/null || warn "Some build deps could not be installed (non-fatal)"
    ;;
  zypper)
    pkg_install \
      -t pattern devel_basis 2>/dev/null || pkg_install gcc gcc-c++ make 2>/dev/null || true
    pkg_install \
      pkg-config \
      libopenssl-devel \
      libxcb-devel \
      alsa-devel \
      oniguruma-devel \
      2>/dev/null || warn "Some build deps could not be installed (non-fatal)"
    ;;
esac
ok "Build dependencies ready"

# ── Build Rust TUI ────────────────────────────────────────────────
TUI_DIR="$AGENT_DIR/priv/rust/tui"
if [ ! -d "$TUI_DIR" ]; then
  fail "TUI source not found at $TUI_DIR"
fi

info "Building TUI (this takes ~60s on first run)..."
BUILD_LOG="/tmp/osa-tui-build.log"
if (cd "$TUI_DIR" && cargo build --release 2>&1 | tee "$BUILD_LOG" | grep -E "Compiling|Finished|error" | tail -10); then
  : # success path
fi
if [ ! -f "$TUI_DIR/target/release/osagent" ]; then
  echo ""
  warn "TUI build failed. Last 20 lines of build output:"
  tail -20 "$BUILD_LOG" 2>/dev/null | sed 's/^/    /'
  echo ""
  fail "TUI build failed. Check errors above."
fi
ok "TUI built"
rm -f "$BUILD_LOG"

# ── Fetch Elixir deps ─────────────────────────────────────────────
info "Fetching Elixir dependencies..."
(cd "$AGENT_DIR" && mix local.hex --force --if-missing >/dev/null 2>&1 || true)
(cd "$AGENT_DIR" && mix local.rebar --force --if-missing >/dev/null 2>&1 || true)
(cd "$AGENT_DIR" && mix deps.get 2>&1 | tail -5)
(cd "$AGENT_DIR" && mix compile 2>&1 | tail -5)
ok "Dependencies ready"

# ── Install binaries ──────────────────────────────────────────────
mkdir -p "$INSTALL_DIR"
chmod +x "$AGENT_DIR/bin/osa"

ln -sf "$AGENT_DIR/bin/osa" "$INSTALL_DIR/osa"
ln -sf "$AGENT_DIR/bin/osa" "$INSTALL_DIR/osagent"
ok "Linked osa     → $INSTALL_DIR/osa"
ok "Linked osagent → $INSTALL_DIR/osagent"

# ── Ensure PATH ───────────────────────────────────────────────────
path_updated=false
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
  SHELL_NAME="$(basename "${SHELL:-/bin/bash}")"
  case "$SHELL_NAME" in
    zsh)  SHELL_RC="$HOME/.zshrc" ;;
    bash) SHELL_RC="$HOME/.bashrc" ;;
    fish) SHELL_RC="$HOME/.config/fish/config.fish" ;;
    *)    SHELL_RC="$HOME/.profile" ;;
  esac

  EXPORT_LINE='export PATH="$HOME/.local/bin:$PATH"'
  if [ "$SHELL_NAME" = "fish" ]; then
    EXPORT_LINE='set -gx PATH $HOME/.local/bin $PATH'
  fi

  if [ -f "$SHELL_RC" ] && grep -qF '.local/bin' "$SHELL_RC" 2>/dev/null; then
    : # Already present
  else
    echo "" >> "$SHELL_RC"
    echo "# OSA Agent" >> "$SHELL_RC"
    echo "$EXPORT_LINE" >> "$SHELL_RC"
    path_updated=true
    ok "Added ~/.local/bin to PATH in $SHELL_RC"
  fi

  # Also write to .profile for non-interactive sessions (root VPS)
  if [ "$SHELL_NAME" = "bash" ] && [ -f "$HOME/.profile" ]; then
    if ! grep -qF '.local/bin' "$HOME/.profile" 2>/dev/null; then
      echo "" >> "$HOME/.profile"
      echo "# OSA Agent" >> "$HOME/.profile"
      echo "$EXPORT_LINE" >> "$HOME/.profile"
    fi
  fi
fi

# ── Create default config if needed ───────────────────────────────
mkdir -p "$OSA_DIR/logs"

if [ ! -f "$OSA_DIR/.env" ]; then
  cat > "$OSA_DIR/.env" <<'ENVEOF'
# OSA Agent Configuration
# Uncomment and set your API key for cloud providers:
# ANTHROPIC_API_KEY=sk-ant-...
# OPENAI_API_KEY=sk-...
# GROQ_API_KEY=gsk_...

# Default: Ollama (local, no API key needed)
# OSA_DEFAULT_PROVIDER=ollama
# OSA_PORT=8089
ENVEOF
  ok "Created config template → $OSA_DIR/.env"
fi

# ── Success ────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}  ◈ OSA Agent installed successfully!${RESET}"
echo ""
echo -e "  ${DIM}Locations:${RESET}"
echo -e "    Agent:    $AGENT_DIR"
echo -e "    Commands: $INSTALL_DIR/osa, $INSTALL_DIR/osagent"
echo -e "    Config:   $OSA_DIR/.env"
echo -e "    Logs:     $OSA_DIR/logs/"
echo ""

if [ "$path_updated" = true ]; then
  echo -e "  ${YELLOW}Reload your shell first:${RESET}"
  echo -e "    ${BOLD}source $SHELL_RC${RESET}"
  echo ""
fi

echo -e "  ${DIM}Quick start:${RESET}"
echo -e "    ${BOLD}osa${RESET}             Start backend + TUI (same as osagent)"
echo -e "    ${BOLD}osa update${RESET}      Pull latest + recompile"
echo -e "    ${BOLD}osa setup${RESET}       Interactive setup wizard"
echo -e "    ${DIM}Default: Ollama (local, no key needed)${RESET}"
echo ""
