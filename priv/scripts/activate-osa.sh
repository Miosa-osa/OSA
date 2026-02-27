#!/bin/bash
# =============================================================================
# OSA AGENT ACTIVATION - Psychedelic Edition
# =============================================================================
# OSA (Orchestrated System Architecture) Agent
# Run: source ~/.osa/scripts/activate-osa.sh
# =============================================================================

# Psychedelic Synthwave Palette
MAGENTA='\033[38;5;199m'
CYAN='\033[38;5;51m'
PURPLE='\033[38;5;135m'
PINK='\033[38;5;213m'
NEON_GREEN='\033[38;5;46m'
DIM='\033[38;5;240m'
BOLD='\033[1m'
R='\033[0m'

clear

echo ""
echo -e "${CYAN}${BOLD}"
cat << 'LOGO'
    ╔══════════════════════════════════════════════════════════════════╗
    ║                                                                  ║
LOGO
echo -e "${R}"

# Animated ASCII with color cycling
echo -e "    ${CYAN}${BOLD}║${R}  ${MAGENTA}██████╗ ${CYAN}███████╗${PURPLE} █████╗ ${R}   ${PINK} █████╗ ${MAGENTA} ██████╗ ${CYAN}███████╗${PURPLE}███╗   ██╗${PINK}████████╗${R}  ${CYAN}${BOLD}║${R}"
echo -e "    ${CYAN}${BOLD}║${R} ${MAGENTA}██╔═══██╗${CYAN}██╔════╝${PURPLE}██╔══██╗${R}  ${PINK}██╔══██╗${MAGENTA}██╔════╝ ${CYAN}██╔════╝${PURPLE}████╗  ██║${PINK}╚══██╔══╝${R}  ${CYAN}${BOLD}║${R}"
echo -e "    ${CYAN}${BOLD}║${R} ${MAGENTA}██║   ██║${CYAN}███████╗${PURPLE}███████║${R}  ${PINK}███████║${MAGENTA}██║  ███╗${CYAN}█████╗  ${PURPLE}██╔██╗ ██║${PINK}   ██║   ${R}  ${CYAN}${BOLD}║${R}"
echo -e "    ${CYAN}${BOLD}║${R} ${MAGENTA}██║   ██║${CYAN}╚════██║${PURPLE}██╔══██║${R}  ${PINK}██╔══██║${MAGENTA}██║   ██║${CYAN}██╔══╝  ${PURPLE}██║╚██╗██║${PINK}   ██║   ${R}  ${CYAN}${BOLD}║${R}"
echo -e "    ${CYAN}${BOLD}║${R} ${MAGENTA}╚██████╔╝${CYAN}███████║${PURPLE}██║  ██║${R}  ${PINK}██║  ██║${MAGENTA}╚██████╔╝${CYAN}███████╗${PURPLE}██║ ╚████║${PINK}   ██║   ${R}  ${CYAN}${BOLD}║${R}"
echo -e "    ${CYAN}${BOLD}║${R}  ${MAGENTA}╚═════╝ ${CYAN}╚══════╝${PURPLE}╚═╝  ╚═╝${R}  ${PINK}╚═╝  ╚═╝${MAGENTA} ╚═════╝ ${CYAN}╚══════╝${PURPLE}╚═╝  ╚═══╝${PINK}   ╚═╝   ${R}  ${CYAN}${BOLD}║${R}"

echo -e "${CYAN}${BOLD}"
cat << 'LOGO'
    ║                                                                  ║
    ║              Orchestrated System Architecture Agent              ║
    ╚══════════════════════════════════════════════════════════════════╝
LOGO
echo -e "${R}"

echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${R}"
echo ""

# Backup and activate Starship
if [ -f "$HOME/.config/starship.toml" ]; then
    cp "$HOME/.config/starship.toml" "$HOME/.config/starship.toml.backup" 2>/dev/null
fi
cp "$HOME/.config/starship-osa.toml" "$HOME/.config/starship.toml"
echo -e "  ${NEON_GREEN}✓${R} OSA Starship theme activated"

# Ensure Starship init
if ! grep -q 'eval "$(starship init zsh)"' "$HOME/.zshrc"; then
    echo '' >> "$HOME/.zshrc"
    echo '# OSA Agent - Starship Prompt' >> "$HOME/.zshrc"
    echo 'eval "$(starship init zsh)"' >> "$HOME/.zshrc"
    echo -e "  ${NEON_GREEN}✓${R} Starship init added to .zshrc"
fi

# Set environment
export OSA_AGENT_ACTIVE=true
export STARSHIP_CONFIG="$HOME/.config/starship.toml"

echo ""
echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${R}"
echo ""
echo -e "  ${CYAN}${BOLD}OSA AGENT CAPABILITIES${R}"
echo ""
echo -e "  ${MAGENTA}◈${R} ${BOLD}Elite Agents${R}"
echo -e "     ${MAGENTA}龍${R} Dragon  ${CYAN}⊛${R} Oracle  ${PURPLE}✸${R} Nova  ${PINK}⚡${R} Blitz"
echo ""
echo -e "  ${PINK}◈${R} ${BOLD}Combat Agents${R}"
echo -e "     ${PINK}♆${R} Angel  ${CYAN}◎${R} Cache  ${MAGENTA}⫘${R} Parallel  ${PURPLE}◬${R} Quantum"
echo ""
echo -e "  ${CYAN}◈${R} ${BOLD}Status Line Features${R}"
echo -e "     ${CYAN}▰${PURPLE}▰${MAGENTA}▰${DIM}▱▱▱${R} Psychedelic progress bar"
echo -e "     \$cost   Budget tracking"
echo -e "     ✦n/n    Learning metrics"
echo -e "     ⚡n      Performance (tokens/sec)"
echo ""
echo -e "  ${NEON_GREEN}◈${R} ${BOLD}System Optimizations${R}"
echo -e "     Semantic Router  • 47% latency reduction"
echo -e "     SimpleMem        • 30x context compression"
echo -e "     Swarm Coordinator • Parallel agent orchestration"
echo ""
echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${R}"
echo ""
echo -e "  ${DIM}Apply terminal changes:${R} source ~/.zshrc"
echo -e "  ${DIM}Run animated banner:${R} ~/.osa/scripts/osa-animated-banner.sh"
echo ""
