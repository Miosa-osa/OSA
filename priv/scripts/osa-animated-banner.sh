#!/bin/bash
# =============================================================================
# OSA AGENT - DARK NEON (single color scheme)
# Electric cyan primary, dark purple glow, no rainbow
# =============================================================================

# MINIMAL PALETTE - cyan dominant, dark aesthetic
CYAN='\033[38;5;51m'      # Primary - Electric Cyan
DCYAN='\033[38;5;44m'     # Dark Cyan
PURPLE='\033[38;5;93m'    # Subtle purple glow
DPURPLE='\033[38;5;54m'   # Dark purple
WHITE='\033[38;5;255m'    # Bright white
GRAY='\033[38;5;240m'     # Dark gray
DIM='\033[38;5;236m'      # Very dark

BOLD='\033[1m'
R='\033[0m'

FRAMES=35
DELAY=0.04

printf '\033[?25l'
printf '\033[2J'
trap 'printf "\033[?25h\033[0m"' EXIT INT TERM

SPINS="⠋⠙⠹⠸⠼⠴⠦⠧"
DOTS="⣾⣽⣻⢿⡿⣟⣯⣷"
STARS="✦✧★☆✦✧★☆"
GLITCH="░▒▓█▓▒░█"

TAGS=(
    "Your Operating System, Supercharged"
    "AI-Powered Development at Warp Speed"
    "47 Agents. Infinite Possibilities."
    "Code Smarter. Ship Faster."
    "The Future of Development is Here"
    "Unleash Your Full Potential"
)

draw() {
    local f=$1

    local spin="${SPINS:$((f % 8)):1}"
    local dot="${DOTS:$((f % 8)):1}"
    local star="${STARS:$((f % 8)):1}"
    local glitch="${GLITCH:$((f % 8)):1}"

    # Pulsing intensity (bold on/off creates glow effect)
    local glow=""
    [ $((f % 2)) -eq 0 ] && glow="$BOLD"

    # Subtle color shift between cyan shades only
    local main sub
    if [ $((f % 4)) -lt 2 ]; then
        main="$CYAN"
        sub="$DCYAN"
    else
        main="$DCYAN"
        sub="$CYAN"
    fi

    printf '\033[H\n'

    # Dark border with glitch accent
    printf "  ${PURPLE}${glitch}${DIM}══════════════════════════════════════════════════════════════════════════${PURPLE}${glitch}${R}\n"
    echo ""

    # OSA AGENT - all cyan, pulsing glow effect
    printf "    ${main}${glow} ██████╗ ${sub}${glow}███████╗${main}${glow} █████╗ ${R}    ${sub}${glow} █████╗ ${main}${glow} ██████╗ ${sub}${glow}███████╗${main}${glow}███╗   ██╗${sub}${glow}████████╗${R}\n"
    printf "    ${main}${glow}██╔═══██╗${sub}${glow}██╔════╝${main}${glow}██╔══██╗${R}   ${sub}${glow}██╔══██╗${main}${glow}██╔════╝ ${sub}${glow}██╔════╝${main}${glow}████╗  ██║${sub}${glow}╚══██╔══╝${R}\n"
    printf "    ${main}${glow}██║   ██║${sub}${glow}███████╗${main}${glow}███████║${R}   ${sub}${glow}███████║${main}${glow}██║  ███╗${sub}${glow}█████╗  ${main}${glow}██╔██╗ ██║${sub}${glow}   ██║   ${R}\n"
    printf "    ${main}${glow}██║   ██║${sub}${glow}╚════██║${main}${glow}██╔══██║${R}   ${sub}${glow}██╔══██║${main}${glow}██║   ██║${sub}${glow}██╔══╝  ${main}${glow}██║╚██╗██║${sub}${glow}   ██║   ${R}\n"
    printf "    ${main}${glow}╚██████╔╝${sub}${glow}███████║${main}${glow}██║  ██║${R}   ${sub}${glow}██║  ██║${main}${glow}╚██████╔╝${sub}${glow}███████╗${main}${glow}██║ ╚████║${sub}${glow}   ██║   ${R}\n"
    printf "    ${main}${glow} ╚═════╝ ${sub}${glow}╚══════╝${main}${glow}╚═╝  ╚═╝${R}   ${sub}${glow}╚═╝  ╚═╝${main}${glow} ╚═════╝ ${sub}${glow}╚══════╝${main}${glow}╚═╝  ╚═══╝${sub}${glow}   ╚═╝   ${R}\n"

    echo ""

    # Subtitle - cyan with animated elements
    printf "                ${PURPLE}${dot}${R} ${CYAN}${spin}${R} ${WHITE}${glow}OPERATING SYSTEM AGENT${R} ${CYAN}${spin}${R} ${PURPLE}${dot}${R}\n"

    echo ""

    # Tagline
    local tag="${TAGS[$((f / 6 % 6))]}"
    printf "                    ${CYAN}${star}${R} ${GRAY}${tag}${R} ${CYAN}${star}${R}\n"

    echo ""

    # Bottom border
    printf "  ${PURPLE}${glitch}${DIM}══════════════════════════════════════════════════════════════════════════${PURPLE}${glitch}${R}\n"
    echo ""
}

draw_bar() {
    local pct=$1
    local f=$2
    local w=50
    local filled=$((pct * w / 100))
    local empty=$((w - filled))
    local dot="${DOTS:$((f % 8)):1}"

    local bar=""
    for ((i=0; i<filled; i++)); do
        bar+="${CYAN}▰${R}"
    done

    if [ $empty -gt 0 ]; then
        bar+="${PURPLE}${dot}${R}"
        empty=$((empty-1))
    fi

    for ((i=0; i<empty; i++)); do bar+="${DIM}▱${R}"; done

    printf "            ${DIM}[${R}${bar}${DIM}]${R} ${CYAN}${pct}%%${R}          \n"
}

draw_cap() {
    local f=$1
    local dot="${DOTS:$((f % 8)):1}"
    local star="${STARS:$((f % 8)):1}"
    local spin="${SPINS:$((f % 8)):1}"

    echo ""
    printf "  ${DIM}════════════════════════════════════════════════════════════════════════════════${R}\n\n"

    printf "      ${CYAN}${dot}${R} ${BOLD}ELITE${R}         ${CYAN}龍${R}Dragon  ${CYAN}⊛${R}Oracle  ${CYAN}✸${R}Nova  ${CYAN}⚡${R}Blitz  ${CYAN}⬡${R}Architect\n"
    printf "      ${CYAN}${dot}${R} ${BOLD}COMBAT${R}        ${CYAN}♆${R}Angel   ${CYAN}◎${R}Cache   ${CYAN}⫘${R}Parallel  ${CYAN}◬${R}Quantum\n"
    printf "      ${CYAN}${dot}${R} ${BOLD}MCP SERVERS${R}   github  memory  context7  playwright  greptile\n"
    printf "      ${CYAN}${dot}${R} ${BOLD}CORE SKILLS${R}   brainstorm  debug  tdd  review  verify  parallel\n"
    echo ""
    printf "  ${DIM}════════════════════════════════════════════════════════════════════════════════${R}\n\n"

    printf "      ${CYAN}${star}${R} ${BOLD}ANIMATED STATUS PREVIEW${R}\n\n"
    printf "      ${CYAN}◈${R}${PURPLE}${spin}${R} ~/project ${DIM}│${R} ${CYAN}龍${R}Dragon ${DIM}│${R} ${CYAN}▰▰▰▰▰${PURPLE}${dot}${DIM}▱▱${R} ${DIM}│${R} ${CYAN}◉${R}47 ${DIM}│${R} ${CYAN}${star}${R}∞ ${DIM}│${R} ${CYAN}🌕${R}\n"
    echo ""
    printf "  ${DIM}════════════════════════════════════════════════════════════════════════════════${R}\n\n"
}

# =============================================================================
# RUN
# =============================================================================

for ((f=0; f<FRAMES; f++)); do
    draw $f
    if [ $f -ge 4 ]; then
        pct=$(( (f - 4) * 100 / (FRAMES - 6) ))
        [ $pct -gt 100 ] && pct=100
        draw_bar $pct $f
    else
        echo ""
    fi
    sleep $DELAY
done

draw $((FRAMES-1))
draw_bar 100 $((FRAMES-1))
draw_cap $((FRAMES-1))

printf "      ${CYAN}◈${R} ${BOLD}OSA Agent initialized.${R} ${DIM}All systems online.${R}\n"
printf "      ${CYAN}✦${R} ${GRAY}Ready to revolutionize your workflow.${R}\n\n"

printf '\033[?25h'
