#!/bin/sh
# scripts/uninstall-binary.sh — Remove the OSA binary install.
#
# Removes the binary installed by install-binary.sh.
# Does NOT touch source-build installs (scripts/install.sh).
#
# Usage:
#   curl -fsSL https://osa.miosa.ai/uninstall.sh | sh
#   wget -qO- https://osa.miosa.ai/uninstall.sh | sh

set -eu

INSTALL_DIR="${OSA_INSTALL_DIR:-${HOME}/.osa/bin}"
BINARY="${INSTALL_DIR}/osa"

printf "\n  OSA — Uninstall (binary)\n\n"

# Remove binary
if [ -f "$BINARY" ] || [ -L "$BINARY" ]; then
  rm -f "$BINARY"
  printf "  Removed: %s\n" "$BINARY"
else
  printf "  Binary not found at %s — nothing to remove.\n" "$BINARY"
fi

# Remove install dir if empty
if [ -d "$INSTALL_DIR" ] && [ -z "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
  rmdir "$INSTALL_DIR" 2>/dev/null || true
  printf "  Removed empty directory: %s\n" "$INSTALL_DIR"
fi

# Remove parent ~/.osa if empty
OSA_DIR="${HOME}/.osa"
if [ -d "$OSA_DIR" ] && [ -z "$(ls -A "$OSA_DIR" 2>/dev/null)" ]; then
  rmdir "$OSA_DIR" 2>/dev/null || true
  printf "  Removed empty directory: %s\n" "$OSA_DIR"
fi

# Remove PATH line from shell profiles
PATH_LINE_PATTERN=".osa/bin"
for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile"; do
  if [ -f "$rc" ] && grep -q "$PATH_LINE_PATTERN" "$rc" 2>/dev/null; then
    # Use a tmp file to avoid in-place sed portability issues
    TMP=$(mktemp /tmp/osa-uninstall.XXXXXX)
    grep -v "$PATH_LINE_PATTERN" "$rc" > "$TMP" || true
    # Also remove the "# OSA Agent" comment line immediately above
    awk '
      /# OSA Agent/ { skip=1; next }
      skip && /^[[:space:]]*$/ { skip=0; next }
      { skip=0; print }
    ' "$TMP" > "${TMP}.clean" || true
    mv "${TMP}.clean" "$rc"
    rm -f "$TMP"
    printf "  Removed PATH entry from %s\n" "$rc"
  fi
done

# Fish shell
FISH_CONFIG="$HOME/.config/fish/config.fish"
if [ -f "$FISH_CONFIG" ] && grep -q ".osa/bin" "$FISH_CONFIG" 2>/dev/null; then
  TMP=$(mktemp /tmp/osa-uninstall.XXXXXX)
  grep -v ".osa/bin" "$FISH_CONFIG" > "$TMP" || true
  mv "$TMP" "$FISH_CONFIG"
  printf "  Removed PATH entry from %s\n" "$FISH_CONFIG"
fi

printf "\n  Done. OSA has been removed.\n\n"
