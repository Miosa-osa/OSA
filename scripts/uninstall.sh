#!/usr/bin/env bash
# scripts/uninstall.sh — Remove OSA Agent installation.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Miosa-osa/OSA/main/scripts/uninstall.sh | bash

set -euo pipefail

INSTALL_DIR="${HOME}/.local/bin"
OSA_DIR="${HOME}/.osa"

echo ""
echo "  ◈ OSA Agent — Uninstall"
echo ""

removed=0

for f in "$INSTALL_DIR/osagent" "$INSTALL_DIR/osa"; do
  if [ -f "$f" ] || [ -L "$f" ]; then
    rm -f "$f"
    echo "  Removed $f"
    removed=$((removed + 1))
  fi
done

# Also check legacy ~/bin location
for f in "$HOME/bin/osagent" "$HOME/bin/osa"; do
  if [ -f "$f" ] || [ -L "$f" ]; then
    rm -f "$f"
    echo "  Removed $f"
    removed=$((removed + 1))
  fi
done

if [ "$removed" -eq 0 ]; then
  echo "  Nothing to remove."
else
  echo ""
  echo "  ✓ Binaries removed."
fi

echo ""
read -rp "  Remove ~/.osa/ config and logs? [y/N] " yn
if [[ "$yn" =~ ^[Yy]$ ]]; then
  rm -rf "$OSA_DIR"
  echo "  Removed $OSA_DIR"
fi

read -rp "  Remove cloned repo at ~/.osa/agent/? [y/N] " yn
if [[ "$yn" =~ ^[Yy]$ ]]; then
  rm -rf "${OSA_DIR}/agent"
  echo "  Removed ${OSA_DIR}/agent"
fi

echo ""
echo "  ✓ Done."
echo ""
