#!/usr/bin/env bash
set -euo pipefail

# ── OSA Installer ───────────────────────────────────────────────────
# Downloads the pre-built osagent binary. No Erlang/Elixir needed.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Miosa-osa/OSA/main/install.sh | sh
# ────────────────────────────────────────────────────────────────────

REPO="Miosa-osa/OSA"
INSTALL_DIR="${OSA_HOME:-$HOME/.osa}"
BIN_DIR="$INSTALL_DIR/bin"
APP_DIR="$INSTALL_DIR/app"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
DIM='\033[2m'
NC='\033[0m'

echo -e "${PURPLE}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║          osagent — binary installer              ║"
echo "  ║  Signal Theory optimized proactive AI agent      ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Detect platform ─────────────────────────────────────────────────

detect_platform() {
  local os arch

  case "$(uname -s)" in
    Darwin) os="darwin" ;;
    Linux)  os="linux" ;;
    *)
      echo -e "${RED}Unsupported OS: $(uname -s)${NC}"
      echo "  osagent supports macOS and Linux."
      exit 1
      ;;
  esac

  case "$(uname -m)" in
    arm64|aarch64) arch="arm64" ;;
    x86_64|amd64)  arch="amd64" ;;
    *)
      echo -e "${RED}Unsupported architecture: $(uname -m)${NC}"
      exit 1
      ;;
  esac

  echo "${os}-${arch}"
}

# ── Fetch latest release ───────────────────────────────────────────

fetch_latest_version() {
  local url="https://api.github.com/repos/${REPO}/releases/latest"

  if command -v curl &>/dev/null; then
    curl -fsSL "$url" | grep '"tag_name"' | sed -E 's/.*"v([^"]+)".*/\1/'
  elif command -v wget &>/dev/null; then
    wget -qO- "$url" | grep '"tag_name"' | sed -E 's/.*"v([^"]+)".*/\1/'
  else
    echo -e "${RED}curl or wget required${NC}" >&2
    exit 1
  fi
}

# ── Download and install ───────────────────────────────────────────

PLATFORM=$(detect_platform)
echo -e "${BLUE}Platform: ${PLATFORM}${NC}"

echo -e "${BLUE}Fetching latest release...${NC}"
VERSION=$(fetch_latest_version)

if [ -z "$VERSION" ]; then
  echo -e "${RED}Could not determine latest version.${NC}"
  echo "  Check https://github.com/${REPO}/releases"
  exit 1
fi

echo -e "${GREEN}Version: v${VERSION}${NC}"

TARBALL="osagent-${VERSION}-${PLATFORM}.tar.gz"
URL="https://github.com/${REPO}/releases/download/v${VERSION}/${TARBALL}"

echo -e "${BLUE}Downloading ${TARBALL}...${NC}"

mkdir -p "$APP_DIR" "$BIN_DIR"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

if command -v curl &>/dev/null; then
  curl -fsSL -o "$TMPDIR/$TARBALL" "$URL"
else
  wget -q -O "$TMPDIR/$TARBALL" "$URL"
fi

echo -e "${BLUE}Installing to ${APP_DIR}...${NC}"

# Clean previous install
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR"

tar -xzf "$TMPDIR/$TARBALL" -C "$APP_DIR"

# Symlink the osagent wrapper into bin/
ln -sf "$APP_DIR/bin/osagent" "$BIN_DIR/osagent"

echo -e "${GREEN}Installed osagent v${VERSION}${NC}"

# ── Update PATH ────────────────────────────────────────────────────

add_to_path() {
  local rc_file="$1"
  local line="export PATH=\"$BIN_DIR:\$PATH\""

  if [ -f "$rc_file" ] && grep -qF "$BIN_DIR" "$rc_file"; then
    return 0
  fi

  echo "" >> "$rc_file"
  echo "# osagent" >> "$rc_file"
  echo "$line" >> "$rc_file"
  echo -e "${DIM}  Added $BIN_DIR to PATH in $(basename "$rc_file")${NC}"
}

if ! echo "$PATH" | grep -qF "$BIN_DIR"; then
  case "$SHELL" in
    */zsh)  add_to_path "$HOME/.zshrc" ;;
    */bash)
      if [ -f "$HOME/.bash_profile" ]; then
        add_to_path "$HOME/.bash_profile"
      else
        add_to_path "$HOME/.bashrc"
      fi
      ;;
    *)      add_to_path "$HOME/.profile" ;;
  esac

  export PATH="$BIN_DIR:$PATH"
fi

# ── Run setup ──────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║          Installation Complete!                  ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Run:  ${BLUE}osagent${NC}           Start chatting"
echo -e "        ${BLUE}osagent setup${NC}     Configure provider + API keys"
echo -e "        ${BLUE}osagent version${NC}   Show version"
echo ""

if [ -t 0 ]; then
  echo -e "${PURPLE}Running setup wizard...${NC}"
  "$BIN_DIR/osagent" setup
fi
