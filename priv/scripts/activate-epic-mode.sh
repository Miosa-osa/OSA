#!/bin/bash
# =============================================================================
# ACTIVATE EPIC MODE - Full Claude Code Ecosystem Enhancement
# =============================================================================
# Run: source ~/.claude/scripts/activate-epic-mode.sh
# =============================================================================

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "                    🚀 EPIC MODE ACTIVATION 🚀"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Backup current starship config
if [ -f "$HOME/.config/starship.toml" ]; then
    cp "$HOME/.config/starship.toml" "$HOME/.config/starship.toml.backup"
    echo "✓ Backed up existing starship.toml"
fi

# Link epic starship config
cp "$HOME/.config/starship-epic.toml" "$HOME/.config/starship.toml"
echo "✓ Activated epic Starship configuration"

# Ensure Starship is initialized (add to .zshrc if not present)
if ! grep -q 'eval "$(starship init zsh)"' "$HOME/.zshrc"; then
    echo '' >> "$HOME/.zshrc"
    echo '# Epic Starship Prompt' >> "$HOME/.zshrc"
    echo 'eval "$(starship init zsh)"' >> "$HOME/.zshrc"
    echo "✓ Added Starship init to .zshrc"
fi

# Set Claude Code environment variables
export CLAUDE_CODE_EPIC_MODE=true
export STARSHIP_CONFIG="$HOME/.config/starship.toml"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Epic Mode Features Activated:"
echo ""
echo "  ╭─ Claude Code ─────────────────────────────────────────────╮"
echo "  │  • Epic status line with progress bars & Nerd Font icons  │"
echo "  │  • Agent indicators (󰩃 Dragon 󰜫 Oracle  Nova 󱐋 Blitz)   │"
echo "  │  • Cost tracking & context window visualization           │"
echo "  │  • Learning metrics (patterns/solutions stored)           │"
echo "  │  • Task status & pending count                            │"
echo "  │  • Session duration & performance metrics                 │"
echo "  ╰───────────────────────────────────────────────────────────╯"
echo ""
echo "  ╭─ Terminal (Starship) ─────────────────────────────────────╮"
echo "  │  • Dracula-inspired color scheme                          │"
echo "  │  • Git status with ahead/behind indicators                │"
echo "  │  • Language/runtime version display                       │"
echo "  │  • Docker context awareness                               │"
echo "  │  • Command duration tracking                              │"
echo "  │  • Time display                                           │"
echo "  ╰───────────────────────────────────────────────────────────╯"
echo ""
echo "  To apply Starship changes, run: source ~/.zshrc"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
