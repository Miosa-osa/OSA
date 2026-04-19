#!/usr/bin/env bash
set -euo pipefail

# ── OSA Installer ───────────────────────────────────────────────────
# One command to install OSA from source on a fresh machine.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Miosa-osa/OSA/main/install.sh | bash
#
# What it does:
#   1. Installs Elixir, Erlang, Rust if missing
#   2. Clones the repo to ~/.osa/src
#   3. Builds the Elixir backend + Rust TUI
#   4. Symlinks `osa` to your PATH
#   5. You type `osa` — setup wizard runs on first launch
# ────────────────────────────────────────────────────────────────────

REPO="Miosa-osa/OSA"
INSTALL_DIR="${OSA_HOME:-$HOME/.osa}"
SRC_DIR="$INSTALL_DIR/src"
BIN_LINK="/usr/local/bin/osa"
RELEASES_URL="https://github.com/${REPO}/releases/latest/download"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
YELLOW='\033[0;33m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

# sudo helper
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

echo -e "${PURPLE}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║            OSA — the Optimal System Agent        ║"
echo "  ║     One AI agent that lives in your OS.          ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Detect platform ─────────────────────────────────────────────────

case "$(uname -s)" in
  Darwin) OS="macos" ;;
  Linux)  OS="linux" ;;
  *)
    echo -e "${RED}Unsupported OS: $(uname -s)${NC}"
    echo "  OSA supports macOS and Linux."
    exit 1
    ;;
esac

case "$(uname -m)" in
  arm64|aarch64) ARCH="arm64" ;;
  x86_64|amd64)  ARCH="amd64" ;;
  *)
    echo -e "${YELLOW}Architecture $(uname -m) has no pre-built binary — falling back to source install.${NC}"
    ARCH="unsupported"
    ;;
esac

echo -e "${DIM}Platform: ${OS}/${ARCH}${NC}"

# ── Try pre-built binary first ───────────────────────────────────────
# Maps OS/ARCH to the release asset name produced by the CI workflow.
#   macos/arm64   → osa-darwin-arm64
#   linux/amd64   → osa-linux-amd64
#   linux/arm64   → osa-linux-arm64
# Windows is not reachable from this script (no bash); fall through to source.

_install_binary() {
  local asset_name
  case "${OS}/${ARCH}" in
    macos/arm64)  asset_name="osa-darwin-arm64" ;;
    linux/amd64)  asset_name="osa-linux-amd64"  ;;
    linux/arm64)  asset_name="osa-linux-arm64"  ;;
    *)            return 1 ;;
  esac

  local url="${RELEASES_URL}/${asset_name}"
  echo -e "${BLUE}[1/1]${NC} Downloading pre-built binary from GitHub Releases..."
  echo -e "${DIM}  ${url}${NC}"

  if ! curl -fsSL --head "$url" -o /dev/null 2>/dev/null; then
    echo -e "${DIM}  No release available yet — falling back to source install.${NC}"
    return 1
  fi

  local tmp_bin
  tmp_bin="$(mktemp)"
  if ! curl -fsSL "$url" -o "$tmp_bin"; then
    echo -e "${YELLOW}  Binary download failed — falling back to source install.${NC}"
    rm -f "$tmp_bin"
    return 1
  fi

  chmod +x "$tmp_bin"

  # Install to /usr/local/bin/osa
  if [ -w /usr/local/bin ] || [ -w "$(dirname /usr/local/bin)" ]; then
    mv "$tmp_bin" /usr/local/bin/osa
  elif [ -n "$SUDO" ]; then
    $SUDO mv "$tmp_bin" /usr/local/bin/osa
  else
    mkdir -p "$HOME/.local/bin"
    mv "$tmp_bin" "$HOME/.local/bin/osa"
    export PATH="$HOME/.local/bin:$PATH"
  fi

  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║            Installation Complete!                ║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  Type ${BOLD}osa${NC} to start."
  echo ""
  echo -e "  ${DIM}First run launches a setup wizard.${NC}"
  echo ""
  return 0
}

# Attempt binary install; if it succeeds, exit cleanly.
if [ "$ARCH" != "unsupported" ] && _install_binary; then
  exit 0
fi

echo -e "${DIM}Falling back to source-based install (builds from Git)...${NC}"
echo ""

# ── Package manager detection ───────────────────────────────────────

detect_pkg() {
  if   command -v brew    >/dev/null 2>&1; then echo "brew"
  elif command -v apt-get >/dev/null 2>&1; then echo "apt"
  elif command -v dnf     >/dev/null 2>&1; then echo "dnf"
  elif command -v pacman  >/dev/null 2>&1; then echo "pacman"
  elif command -v apk     >/dev/null 2>&1; then echo "apk"
  elif command -v zypper  >/dev/null 2>&1; then echo "zypper"
  elif command -v yum     >/dev/null 2>&1; then echo "yum"
  else echo "unknown"
  fi
}

PKG=$(detect_pkg)

pkg_install() {
  case "$PKG" in
    brew)   brew install "$@" ;;
    apt)    $SUDO apt-get update -qq && $SUDO apt-get install -y -qq "$@" ;;
    dnf)    $SUDO dnf install -y -q "$@" ;;
    yum)    $SUDO yum install -y -q "$@" ;;
    pacman) $SUDO pacman -Sy --noconfirm "$@" ;;
    apk)    $SUDO apk add --no-cache "$@" ;;
    zypper) $SUDO zypper install -y "$@" ;;
    *)      echo -e "${RED}No supported package manager found.${NC}"; return 1 ;;
  esac
}

# ── Step 1: Install git if missing ──────────────────────────────────

if ! command -v git >/dev/null 2>&1; then
  echo -e "${BLUE}[1/6]${NC} Installing git..."
  pkg_install git
fi

# ── Step 2: Install Erlang + Elixir ─────────────────────────────────

check_elixir_version() {
  local ver major minor
  ver=$(elixir --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  [ -z "$ver" ] && return 1
  major=$(echo "$ver" | cut -d. -f1)
  minor=$(echo "$ver" | cut -d. -f2)
  [ "${major:-0}" -gt 1 ] && return 0
  [ "${major:-0}" -eq 1 ] && [ "${minor:-0}" -ge 17 ] && return 0
  return 1
}

if ! command -v mix >/dev/null 2>&1 || ! check_elixir_version; then
  echo -e "${BLUE}[2/6]${NC} Installing Erlang + Elixir..."
  case "$OS" in
    macos)
      if ! command -v brew >/dev/null 2>&1; then
        echo -e "${DIM}  Installing Homebrew first...${NC}"
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        if [ -f "/opt/homebrew/bin/brew" ]; then
          eval "$(/opt/homebrew/bin/brew shellenv)"
        elif [ -f "/usr/local/bin/brew" ]; then
          eval "$(/usr/local/bin/brew shellenv)"
        fi
        PKG="brew"
      fi
      brew install erlang elixir
      ;;
    linux)
      case "$PKG" in
        apt)    pkg_install erlang elixir ;;
        dnf)    pkg_install erlang elixir ;;
        pacman) pkg_install erlang elixir ;;
        apk)    pkg_install erlang elixir ;;
        *)      pkg_install erlang elixir ;;
      esac
      # Verify version — install prebuilt if system package is too old
      if ! check_elixir_version; then
        local elixir_ver="1.18.3"
        local otp_major
        otp_major=$(erl -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().' -noshell 2>/dev/null || echo "27")
        local url="https://github.com/elixir-lang/elixir/releases/download/v${elixir_ver}/elixir-otp-${otp_major}.zip"
        echo -e "${DIM}  System Elixir too old — installing v${elixir_ver} from prebuilt...${NC}"
        local dest="/usr/local/lib/elixir"
        $SUDO mkdir -p "$dest"
        command -v unzip >/dev/null 2>&1 || pkg_install unzip
        curl -fsSLo /tmp/elixir.zip "$url"
        $SUDO unzip -qo /tmp/elixir.zip -d "$dest"
        rm -f /tmp/elixir.zip
        for bin in elixir mix iex elixirc; do
          $SUDO ln -sf "$dest/bin/$bin" /usr/local/bin/"$bin"
        done
      fi
      ;;
  esac
  echo -e "${GREEN}  Elixir ready${NC}"
else
  echo -e "${BLUE}[2/6]${NC} Elixir $(elixir --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) ${GREEN}found${NC}"
fi

# ── Step 3: Install Rust ────────────────────────────────────────────

if ! command -v cargo >/dev/null 2>&1; then
  echo -e "${BLUE}[3/6]${NC} Installing Rust..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --quiet
  . "${HOME}/.cargo/env" 2>/dev/null || true
  export PATH="${HOME}/.cargo/bin:$PATH"
  echo -e "${GREEN}  Rust ready${NC}"
else
  echo -e "${BLUE}[3/6]${NC} Rust $(rustc --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+') ${GREEN}found${NC}"
fi

# ── Step 4: Clone repo ──────────────────────────────────────────────

if [ -d "$SRC_DIR/.git" ]; then
  echo -e "${BLUE}[4/6]${NC} Updating existing install..."
  (cd "$SRC_DIR" && git pull --ff-only origin main 2>&1 | tail -3)
else
  echo -e "${BLUE}[4/6]${NC} Cloning OSA..."
  mkdir -p "$INSTALL_DIR"
  git clone --depth 1 "https://github.com/${REPO}.git" "$SRC_DIR"
fi

# ── Step 5: Build ───────────────────────────────────────────────────

echo -e "${BLUE}[5/6]${NC} Building Elixir backend..."
cd "$SRC_DIR"
mix local.hex --force --if-missing >/dev/null 2>&1 || true
mix local.rebar --force --if-missing >/dev/null 2>&1 || true
mix deps.get --quiet 2>&1 | tail -3
mix compile 2>&1 | tail -5
mix ecto.setup 2>/dev/null || mix ecto.create 2>/dev/null || true

echo -e "${BLUE}[5/6]${NC} Building Rust TUI..."

# Install Linux native build deps if needed
if [ "$OS" = "linux" ]; then
  case "$PKG" in
    apt)
      local needed=()
      command -v pkg-config >/dev/null 2>&1 || needed+=(pkg-config)
      command -v gcc >/dev/null 2>&1        || needed+=(build-essential)
      [ -f /usr/lib/*/libssl.so ] 2>/dev/null || needed+=(libssl-dev)
      [ -f /usr/lib/*/libxcb.so ] 2>/dev/null || needed+=(libxcb1-dev)
      [ -f /usr/lib/*/libasound.so ] 2>/dev/null || needed+=(libasound2-dev)
      if [ ${#needed[@]} -gt 0 ]; then
        echo -e "${DIM}  Installing build deps: ${needed[*]}${NC}"
        $SUDO apt-get install -y -qq "${needed[@]}" 2>/dev/null || true
      fi
      ;;
    dnf|yum)  pkg_install gcc gcc-c++ make pkg-config openssl-devel 2>/dev/null || true ;;
    pacman)   pkg_install base-devel pkg-config openssl 2>/dev/null || true ;;
  esac
fi

(cd "$SRC_DIR/priv/rust/tui" && cargo build --release 2>&1 | grep -E "Compiling|Finished|error" | tail -10)

if [ ! -f "$SRC_DIR/priv/rust/tui/target/release/osagent" ]; then
  echo -e "${RED}TUI build failed. The backend still works — run: mix osa.chat${NC}"
fi

# ── Step 5b: Computer Use deps (Linux X11) ─────────────────────────

if [ "$OS" = "linux" ] && [ -n "${DISPLAY:-}" ]; then
  echo -e "${BLUE}[5b/6]${NC} Installing Computer Use deps (X11 desktop control)..."
  case "$PKG" in
    apt)
      $SUDO apt-get install -y -qq xdotool maim python3-gi gir1.2-atspi-2.0 2>/dev/null || true
      ;;
    dnf|yum)
      pkg_install xdotool maim python3-gobject 2>/dev/null || true
      ;;
    pacman)
      pkg_install xdotool maim python-gobject at-spi2-core 2>/dev/null || true
      ;;
  esac

  # Auto-enable computer_use in .env if it exists
  OSA_ENV="$INSTALL_DIR/.env"
  if [ -f "$OSA_ENV" ] && ! grep -q "OSA_COMPUTER_USE" "$OSA_ENV"; then
    echo "" >> "$OSA_ENV"
    echo "# Computer Use (auto-detected Linux X11)" >> "$OSA_ENV"
    echo "OSA_COMPUTER_USE=true" >> "$OSA_ENV"
  fi
  echo -e "${GREEN}  Computer Use ready${NC}"
fi

# ── Step 6: Symlink `osa` to PATH ──────────────────────────────────

echo -e "${BLUE}[6/6]${NC} Adding ${BOLD}osa${NC} to your PATH..."

# Try /usr/local/bin first (most universal), fall back to ~/.local/bin
if [ -w /usr/local/bin ] || [ -w "$(dirname /usr/local/bin)" ]; then
  ln -sf "$SRC_DIR/bin/osa" /usr/local/bin/osa
  echo -e "${DIM}  Linked: /usr/local/bin/osa${NC}"
elif [ -n "$SUDO" ]; then
  $SUDO ln -sf "$SRC_DIR/bin/osa" /usr/local/bin/osa
  echo -e "${DIM}  Linked: /usr/local/bin/osa (via sudo)${NC}"
else
  # Fall back to ~/.local/bin
  mkdir -p "$HOME/.local/bin"
  ln -sf "$SRC_DIR/bin/osa" "$HOME/.local/bin/osa"

  # Ensure ~/.local/bin is on PATH
  if ! echo "$PATH" | grep -qF "$HOME/.local/bin"; then
    case "$SHELL" in
      */zsh)  RC_FILE="$HOME/.zshrc" ;;
      */bash) RC_FILE="${HOME}/.bash_profile"; [ -f "$RC_FILE" ] || RC_FILE="$HOME/.bashrc" ;;
      *)      RC_FILE="$HOME/.profile" ;;
    esac
    if [ -n "$RC_FILE" ] && ! grep -qF '.local/bin' "$RC_FILE" 2>/dev/null; then
      echo '' >> "$RC_FILE"
      echo '# OSA' >> "$RC_FILE"
      echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$RC_FILE"
      echo -e "${DIM}  Added ~/.local/bin to PATH in $(basename "$RC_FILE")${NC}"
    fi
    export PATH="$HOME/.local/bin:$PATH"
  fi
  echo -e "${DIM}  Linked: ~/.local/bin/osa${NC}"
fi

# ── Done ────────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║            Installation Complete!                ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Type ${BOLD}osa${NC} to start."
echo ""
echo -e "  ${DIM}First run launches a setup wizard — pick your LLM"
echo -e "  provider, enter your API key, name yourself and"
echo -e "  your agent. Takes about 60 seconds.${NC}"
echo ""
echo -e "  ${BOLD}Commands:${NC}"
echo -e "    ${BLUE}osa${NC}              Launch (backend + Rust TUI)"
echo -e "    ${BLUE}osa serve${NC}        Backend only (headless API)"
echo -e "    ${BLUE}osa setup${NC}        Re-run the setup wizard"
echo -e "    ${BLUE}osa update${NC}       Pull latest + rebuild"
echo -e "    ${BLUE}osa doctor${NC}       Health checks"
echo ""

# If this is a fresh install in an interactive terminal, hint to restart shell
if ! command -v osa >/dev/null 2>&1; then
  echo -e "  ${YELLOW}Restart your terminal (or run: source ~/.zshrc) then type: osa${NC}"
fi
