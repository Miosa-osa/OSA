#!/bin/sh
# scripts/install-binary.sh — OSA binary installer (macOS + Linux)
#
# Installs the pre-built Burrito binary from GitHub Releases.
# No build toolchain required — downloads a single self-contained executable.
#
# Usage:
#   curl -fsSL https://osa.miosa.ai/install.sh | sh
#   wget -qO- https://osa.miosa.ai/install.sh | sh
#
# Environment overrides:
#   OSA_VERSION      Pin to a specific release tag (e.g. "v0.3.1"). Default: latest.
#   OSA_INSTALL_DIR  Override install directory. Default: $HOME/.osa/bin
#
# Exit codes:
#   0  success
#   1  unsupported platform / architecture
#   2  network error
#   3  extraction error
#
# POSIX-compatible. No bashisms. Works with sh, bash, dash, zsh.
# Requires: curl or wget, tar (for .tar.gz) or unzip (for .zip).

set -eu

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
GITHUB_REPO="Miosa-osa/OSA"
INSTALL_DIR="${OSA_INSTALL_DIR:-${HOME}/.osa/bin}"
BINARY_NAME="osa"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
_tty() { [ -t 1 ]; }

if _tty; then
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

info()  { printf "${CYAN}  ->${RESET} %s\n" "$*"; }
ok()    { printf "${GREEN}  ok${RESET} %s\n" "$*"; }
warn()  { printf "${YELLOW}  !! WARNING:${RESET} %s\n" "$*" >&2; }
fail()  { printf "${RED}  !! ERROR:${RESET} %s\n" "$*" >&2; exit 1; }

_download() {
  # Try curl first, fall back to wget.
  url="$1"
  dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --retry-delay 2 -o "$dest" "$url" || return 2
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$dest" "$url" || return 2
  else
    fail "Neither curl nor wget found. Install one and retry."
  fi
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
printf "\n${BOLD}  OSA — Optimal System Agent${RESET}\n"
printf "${DIM}  One-line binary installer${RESET}\n\n"

# ---------------------------------------------------------------------------
# Detect OS and architecture
# ---------------------------------------------------------------------------
OS=""
ARCH=""

case "$(uname -s)" in
  Darwin) OS="macos" ;;
  Linux)  OS="linux" ;;
  *)
    printf "${RED}  Unsupported OS: $(uname -s)${RESET}\n" >&2
    printf "  OSA supports macOS and Linux.\n" >&2
    printf "  For Windows: iwr https://osa.miosa.ai/install.ps1 | iex\n" >&2
    exit 1
    ;;
esac

case "$(uname -m)" in
  arm64|aarch64) ARCH="arm64" ;;
  x86_64|amd64)  ARCH="x86_64" ;;
  *)
    printf "${RED}  Unsupported architecture: $(uname -m)${RESET}\n" >&2
    exit 1
    ;;
esac

info "Detected: ${OS}/${ARCH}"

# ---------------------------------------------------------------------------
# Map to GitHub Release asset name
# ---------------------------------------------------------------------------
# Burrito convention: osa-<os>-<arch>.tar.gz
ASSET_TARBALL="osa-${OS}-${ARCH}.tar.gz"
ASSET_SHA256="${ASSET_TARBALL}.sha256"

# ---------------------------------------------------------------------------
# Resolve version (latest or pinned)
# ---------------------------------------------------------------------------
API_URL="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"

if [ -n "${OSA_VERSION:-}" ]; then
  VERSION="${OSA_VERSION}"
  info "Using pinned version: ${VERSION}"
else
  info "Fetching latest release..."
  TMP_META=$(mktemp /tmp/osa-meta.XXXXXX)
  if ! _download "$API_URL" "$TMP_META"; then
    rm -f "$TMP_META"
    printf "${RED}  Network error: could not reach GitHub API.${RESET}\n" >&2
    printf "  Check your internet connection and try again.\n" >&2
    exit 2
  fi
  # Extract tag_name without jq — works with POSIX grep/sed
  VERSION=$(grep '"tag_name"' "$TMP_META" | head -1 \
    | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
  rm -f "$TMP_META"
  if [ -z "$VERSION" ]; then
    fail "Could not determine latest release version. Try: OSA_VERSION=v0.1.0 ... to pin."
  fi
  ok "Latest release: ${VERSION}"
fi

DOWNLOAD_BASE="https://github.com/${GITHUB_REPO}/releases/download/${VERSION}"
TARBALL_URL="${DOWNLOAD_BASE}/${ASSET_TARBALL}"
SHA256_URL="${DOWNLOAD_BASE}/${ASSET_SHA256}"

# ---------------------------------------------------------------------------
# Download to temp directory
# ---------------------------------------------------------------------------
TMP_DIR=$(mktemp -d /tmp/osa-install.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

TMP_TARBALL="${TMP_DIR}/${ASSET_TARBALL}"
TMP_SHA256="${TMP_DIR}/${ASSET_SHA256}"

info "Downloading ${ASSET_TARBALL}..."
if ! _download "$TARBALL_URL" "$TMP_TARBALL"; then
  printf "${RED}  Download failed.${RESET}\n" >&2
  printf "  URL attempted: %s\n" "$TARBALL_URL" >&2
  printf "  Verify the release exists: https://github.com/%s/releases\n" "$GITHUB_REPO" >&2
  exit 2
fi
ok "Downloaded ${ASSET_TARBALL}"

# ---------------------------------------------------------------------------
# Verify checksum (optional — skip with warning if .sha256 not found)
# ---------------------------------------------------------------------------
info "Verifying checksum..."
if _download "$SHA256_URL" "$TMP_SHA256" 2>/dev/null; then
  EXPECTED=$(cat "$TMP_SHA256" | awk '{print $1}')
  if [ -z "$EXPECTED" ]; then
    warn "Checksum file was empty — skipping verification."
  else
    if command -v sha256sum >/dev/null 2>&1; then
      ACTUAL=$(sha256sum "$TMP_TARBALL" | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
      ACTUAL=$(shasum -a 256 "$TMP_TARBALL" | awk '{print $1}')
    else
      warn "No sha256sum or shasum found — skipping checksum verification."
      ACTUAL="$EXPECTED"
    fi

    if [ "$ACTUAL" != "$EXPECTED" ]; then
      printf "${RED}  Checksum mismatch!${RESET}\n" >&2
      printf "  Expected: %s\n" "$EXPECTED" >&2
      printf "  Got:      %s\n" "$ACTUAL" >&2
      printf "  The download may be corrupted. Aborting.\n" >&2
      exit 3
    fi
    ok "Checksum verified"
  fi
else
  warn "No .sha256 file found for this release — skipping checksum verification."
fi

# ---------------------------------------------------------------------------
# Extract binary
# ---------------------------------------------------------------------------
info "Extracting..."
TMP_EXTRACT="${TMP_DIR}/extract"
mkdir -p "$TMP_EXTRACT"

if ! tar -xzf "$TMP_TARBALL" -C "$TMP_EXTRACT" 2>/dev/null; then
  printf "${RED}  Extraction failed.${RESET}\n" >&2
  exit 3
fi

# Find the binary — it may be at the top level or in a subdirectory
EXTRACTED_BIN=$(find "$TMP_EXTRACT" -type f -name "osa" | head -1)
if [ -z "$EXTRACTED_BIN" ]; then
  # Fallback: look for any single executable
  EXTRACTED_BIN=$(find "$TMP_EXTRACT" -type f -perm -u+x | head -1)
fi
if [ -z "$EXTRACTED_BIN" ]; then
  printf "${RED}  Could not find 'osa' binary in the archive.${RESET}\n" >&2
  exit 3
fi
ok "Extracted"

# ---------------------------------------------------------------------------
# Install binary
# ---------------------------------------------------------------------------
mkdir -p "$INSTALL_DIR"
DEST="${INSTALL_DIR}/${BINARY_NAME}"

cp "$EXTRACTED_BIN" "$DEST"
chmod +x "$DEST"
ok "Installed to ${DEST}"

# ---------------------------------------------------------------------------
# PATH setup
# ---------------------------------------------------------------------------
SHELL_NAME=$(basename "${SHELL:-/bin/sh}" 2>/dev/null || echo "sh")

already_on_path=false
_IFS="$IFS"; IFS=:
for dir in $PATH; do
  if [ "$dir" = "$INSTALL_DIR" ]; then
    already_on_path=true
    break
  fi
done
IFS="$_IFS"

if ! $already_on_path; then
  EXPORT_LINE="export PATH=\"\$HOME/.osa/bin:\$PATH\""

  case "$SHELL_NAME" in
    zsh)  RC_FILE="${ZDOTDIR:-$HOME}/.zshrc" ;;
    bash)
      if [ -f "$HOME/.bash_profile" ]; then
        RC_FILE="$HOME/.bash_profile"
      else
        RC_FILE="$HOME/.bashrc"
      fi
      ;;
    fish)
      RC_FILE="$HOME/.config/fish/config.fish"
      EXPORT_LINE="fish_add_path \$HOME/.osa/bin"
      ;;
    *)    RC_FILE="$HOME/.profile" ;;
  esac

  printf "\n" >> "$RC_FILE"
  printf "# OSA Agent\n" >> "$RC_FILE"
  printf "%s\n" "$EXPORT_LINE" >> "$RC_FILE"
  ok "Added ${INSTALL_DIR} to PATH in ${RC_FILE}"

  printf "\n${YELLOW}  Reload your shell before running osa:${RESET}\n"
  case "$SHELL_NAME" in
    zsh)  printf "    source %s\n" "$RC_FILE" ;;
    bash) printf "    source %s\n" "$RC_FILE" ;;
    fish) printf "    source %s\n" "$RC_FILE" ;;
    *)    printf "    . %s\n"      "$RC_FILE" ;;
  esac
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
printf "\n${GREEN}${BOLD}  OSA ${VERSION} installed successfully!${RESET}\n\n"
printf "  Next step:\n"
printf "\n"
printf "    ${BOLD}osa opencomputers connect --key <your-key>${RESET}\n"
printf "\n"
printf "  ${DIM}Get your key at: https://miosa.ai/opencomputers${RESET}\n\n"
