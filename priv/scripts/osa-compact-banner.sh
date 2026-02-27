#!/bin/bash
# =============================================================================
# OSA AGENT - Compact Banner
# Dark neon cyan aesthetic - matches animated banner & status line
# =============================================================================

CYAN='\033[38;5;51m'
DCYAN='\033[38;5;44m'
PURPLE='\033[38;5;93m'
DPURPLE='\033[38;5;54m'
WHITE='\033[38;5;255m'
GRAY='\033[38;5;240m'
DGRAY='\033[38;5;236m'
BOLD='\033[1m'
R='\033[0m'

# Get current directory
CWD="${PWD/#$HOME/~}"
[ ${#CWD} -gt 40 ] && CWD="…${CWD: -37}"

# Animated characters
STARS="✦✧★☆✦✧★☆"
DOTS="⣾⣽⣻⢿⡿⣟⣯⣷"
SPINS="◜◝◞◟◜◝◞◟"
BRAILLE="⠋⠙⠹⠸⠼⠴⠦⠧"
GLITCH="░▒▓█▓▒░█"

FRAME=$(($(date +%s) % 8))
PULSE=$(($(date +%s) % 2))

STAR="${STARS:$FRAME:1}"
DOT="${DOTS:$FRAME:1}"
SPIN="${SPINS:$((FRAME % 4)):1}"
SPINNER="${BRAILLE:$FRAME:1}"
GLYPH="${GLITCH:$FRAME:1}"

# Pulsing effect
if [ $PULSE -eq 0 ]; then
    MAIN="$CYAN"
    SUB="$DCYAN"
else
    MAIN="$DCYAN"
    SUB="$CYAN"
fi

echo ""
printf " ${PURPLE}${GLYPH}${DGRAY}═══════════════════════════════════════════════════════${PURPLE}${GLYPH}${R}\n"
printf " ${MAIN}${BOLD}◈${R}${PURPLE}${SPINNER}${R} ${CYAN}${BOLD}OSA${R} ${WHITE}Agent${R}  ${DGRAY}│${R}  ${GRAY}Operating System Agent${R}\n"
printf " ${SUB}${STAR}${R}  ${DGRAY}${CWD}${R}\n"
printf " ${PURPLE}${DOT}${R}  ${DGRAY}Your OS, Supercharged${R}  ${CYAN}${SPIN}${R}\n"
printf " ${PURPLE}${GLYPH}${DGRAY}═══════════════════════════════════════════════════════${PURPLE}${GLYPH}${R}\n"
echo ""
