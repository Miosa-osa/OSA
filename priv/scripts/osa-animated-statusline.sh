#!/bin/bash
# =============================================================================
# OSA AGENT ANIMATED STATUS LINE - Enhanced Dark Neon Edition
# Operating System Agent - Your OS, Supercharged
# Compatible with bash 3.2 (macOS default)
# =============================================================================

input=$(cat)

# =============================================================================
# PARSE DATA
# =============================================================================

# WORKSPACE
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // "~"')
git_branch=$(echo "$input" | jq -r '.workspace.git_branch // empty')
git_status=$(echo "$input" | jq -r '.workspace.git_status // empty')

# MODEL (ALL model variables!)
model_name=$(echo "$input" | jq -r '.model.display_name // .model // "opus"')
model_id=$(echo "$input" | jq -r '.model.id // empty')
model_tier=$(echo "$input" | jq -r '.model.tier // "elite"')

# CONTEXT WINDOW
remaining=$(echo "$input" | jq -r '.context_window.remaining_percentage // 100' | cut -d. -f1)

# OUTPUT STYLE
output_style=$(echo "$input" | jq -r '.output_style.name // "default"')
output_theme=$(echo "$input" | jq -r '.output_style.theme // empty')

# SESSION (ALL session variables!)
session_id=$(echo "$input" | jq -r '.session.id // empty' | head -c 6)
session_cost=$(echo "$input" | jq -r '.cost.session_cost_usd // 0')
daily_cost=$(echo "$input" | jq -r '.cost.daily_cost_usd // 0')
duration_ms=$(echo "$input" | jq -r '.session.duration_ms // 0')
message_count=$(echo "$input" | jq -r '.session.message_count // 0')

# TASKS
task_id=$(echo "$input" | jq -r '.task.current_id // empty')
pending_tasks=$(echo "$input" | jq -r '.task.pending_count // 0')

# AGENT (ALL agent variables!)
current_agent=$(echo "$input" | jq -r '.agent.current // empty')
agent_tier=$(echo "$input" | jq -r '.agent.tier // empty')

# LEARNING
patterns_stored=$(echo "$input" | jq -r '.learning.patterns_stored // 0')
solutions_stored=$(echo "$input" | jq -r '.learning.solutions_stored // 0')

# PERFORMANCE (ALL performance variables!)
tokens_per_sec=$(echo "$input" | jq -r '.performance.tokens_per_second // 0')
cache_hit_rate=$(echo "$input" | jq -r '.performance.cache_hit_rate // 0')

# =============================================================================
# DARK NEON PALETTE (Cyan dominant - matches banner)
# =============================================================================

R="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"
BLINK="\033[5m"

# Primary palette - cyan dominant
CYAN="\033[38;5;51m"
DCYAN="\033[38;5;44m"
PURPLE="\033[38;5;93m"
DPURPLE="\033[38;5;54m"
WHITE="\033[38;5;255m"
GRAY="\033[38;5;240m"
DGRAY="\033[38;5;236m"

# Accent colors (used sparingly)
PINK="\033[38;5;213m"
NEON_GREEN="\033[38;5;46m"
NEON_YELLOW="\033[38;5;226m"
NEON_ORANGE="\033[38;5;208m"
NEON_RED="\033[38;5;196m"

# =============================================================================
# ANIMATION FRAMES (timestamp-based for smooth motion)
# =============================================================================

# Use nanoseconds for smoother animation when available
if command -v gdate &> /dev/null; then
    MS=$(gdate +%s%N | cut -c1-13)
    TIMESTAMP=$((MS / 1000))
    FAST_TICK=$((MS / 100 % 8))
else
    TIMESTAMP=$(date +%s)
    FAST_TICK=$((TIMESTAMP % 8))
fi

FRAME=$((TIMESTAMP % 8))
SLOW_FRAME=$((TIMESTAMP / 2 % 8))
FAST_FRAME=$((TIMESTAMP * 2 % 8))
PULSE=$((TIMESTAMP % 2))
CAROUSEL=$((TIMESTAMP % 42))

# =============================================================================
# ANIMATED CHARACTERS
# =============================================================================

BRAILLE="⠋⠙⠹⠸⠼⠴⠦⠧"
DOT_PULSE="⣾⣽⣻⢿⡿⣟⣯⣷"
STARS="✦✧★☆✦✧★☆"
MOONS="🌑🌒🌓🌔🌕🌖🌗🌘"
ORBITS="◜◝◞◟◜◝◞◟"
WAVES="▁▂▃▄▅▆▇█"
DIAMONDS="◇◈◆◈◇◈◆◈"
GLITCH="░▒▓█▓▒░█"
ARROWS="←↖↑↗→↘↓↙"
DOTS="⠁⠂⠄⡀⢀⠠⠐⠈"

char_at() {
    local str="$1"
    local pos="$2"
    echo "${str:$pos:1}"
}

# =============================================================================
# ECOSYSTEM ARRAYS
# =============================================================================

ELITE_AGENTS="龍Dragon|⊛Oracle|✸Nova|⚡Blitz|⬡Arch"
COMBAT_AGENTS="♆Angel|◎Cache|⫘Parallel|◬Quantum"
TOOLS="Read|Write|Edit|Bash|Grep|Glob|Task|Web|MCP"
MCPS="github|memory|ctx7|play|jupyter|fs|git|seq"
HOOKS="security|format|learn|telemetry|recovery"
SKILLS="debug|tdd|review|brainstorm|verify|parallel"
MODELS="opus|sonnet|haiku"
TIERS="elite|orch|spec|util"
STYLES="default|verbose|concise|streaming"

get_item() {
    echo "$1" | cut -d'|' -f$(($2 + 1))
}

count_items() {
    echo "$1" | tr '|' '\n' | wc -l | tr -d ' '
}

# =============================================================================
# BUILD STATUS LINE
# =============================================================================

output=""

# ═══════════════════════════════════════════════════════════════════════════
# OSA BADGE + MODEL INDICATOR (Pulsing glow effect)
# ═══════════════════════════════════════════════════════════════════════════

spinner=$(char_at "$BRAILLE" $FRAME)
glitch=$(char_at "$GLITCH" $FAST_FRAME)

# Model badge with EPIC tier-based styling + gradient
model_short=$(echo "$model_name" | sed 's/claude-//' | sed 's/opus/OPUS/' | sed 's/sonnet/SNNT/' | sed 's/haiku/HAIK/' | cut -c1-4)
case "$model_name" in
    *opus*|*Opus*)
        if [ $PULSE -eq 0 ]; then
            output+="${NEON_YELLOW}${BOLD}⟐${R}${CYAN}${BOLD}${spinner}${model_short}${R}"
        else
            output+="${CYAN}${BOLD}⟐${R}${PURPLE}${spinner}${NEON_YELLOW}${model_short}${R}"
        fi
        ;;
    *sonnet*|*Sonnet*)
        output+="${PURPLE}◇${spinner}${model_short}${R}"
        ;;
    *haiku*|*Haiku*)
        output+="${DCYAN}○${spinner}${model_short}${R}"
        ;;
    *)
        output+="${CYAN}◈${spinner}${model_short}${R}"
        ;;
esac

# ═══════════════════════════════════════════════════════════════════════════
# DIRECTORY (compact + clean)
# ═══════════════════════════════════════════════════════════════════════════

if [[ "$cwd" == "$HOME"* ]]; then
    cwd_display="~${cwd#$HOME}"
else
    cwd_display="$cwd"
fi
# Get just the last folder name for compact display
cwd_short=$(basename "$cwd_display")
[ "$cwd_short" = "~" ] && cwd_short="~"

output+=" ${WHITE}${cwd_short}${R}"

# ═══════════════════════════════════════════════════════════════════════════
# GIT BRANCH (PRIMARY) or ANIMATED ECOSYSTEM CAROUSEL
# ═══════════════════════════════════════════════════════════════════════════

output+=" ${DGRAY}│${R} "

star=$(char_at "$STARS" $FRAME)
orbit=$(char_at "$ORBITS" $FRAME)
diamond=$(char_at "$DIAMONDS" $FRAME)
pulse_dot=$(char_at "$DOT_PULSE" $FRAME)

# IF GIT BRANCH EXISTS - ALWAYS SHOW IT (with epic animation)
if [ -n "$git_branch" ] && [ "$git_branch" != "null" ]; then
    # Git status indicators
    git_indicator=""
    if [[ "$git_status" == *"M"* ]] || [[ "$git_status" == *"modified"* ]]; then
        git_indicator="${NEON_YELLOW}${BOLD}±${R}"
    elif [[ "$git_status" == *"A"* ]] || [[ "$git_status" == *"staged"* ]]; then
        git_indicator="${NEON_GREEN}${BOLD}+${R}"
    elif [[ "$git_status" == *"?"* ]]; then
        git_indicator="${NEON_ORANGE}?${R}"
    fi

    # Animated git branch with cycling effects
    git_effect=$((FRAME % 4))
    case $git_effect in
        0) output+="${PURPLE}⎇${R}${CYAN}${BOLD}${git_branch}${R}${git_indicator}" ;;
        1) output+="${CYAN}󰊢${R}${WHITE}${BOLD}${git_branch}${R}${git_indicator}" ;;
        2) output+="${NEON_GREEN}${R}${CYAN}${git_branch}${R}${git_indicator}" ;;
        3) output+="${PINK}⌥${R}${PURPLE}${BOLD}${git_branch}${R}${git_indicator}" ;;
    esac
else
    # NO GIT - Show ecosystem carousel

if [ "$CAROUSEL" -lt 5 ]; then
    # Elite Agents
    count=$(count_items "$ELITE_AGENTS")
    idx=$((SLOW_FRAME % count))
    item=$(get_item "$ELITE_AGENTS" $idx)
    output+="${CYAN}${BOLD}${item}${R}"

elif [ "$CAROUSEL" -lt 10 ]; then
    # Combat Agents
    count=$(count_items "$COMBAT_AGENTS")
    idx=$((SLOW_FRAME % count))
    item=$(get_item "$COMBAT_AGENTS" $idx)
    output+="${DCYAN}${BOLD}${item}${R}"

elif [ "$CAROUSEL" -lt 15 ]; then
    # Tools with animated star
    count=$(count_items "$TOOLS")
    idx=$((FRAME % count))
    item=$(get_item "$TOOLS" $idx)
    output+="${CYAN}${star}${item}${R}"

elif [ "$CAROUSEL" -lt 20 ]; then
    # MCPs with orbit
    count=$(count_items "$MCPS")
    idx=$((SLOW_FRAME % count))
    item=$(get_item "$MCPS" $idx)
    output+="${DCYAN}${orbit}mcp:${item}${R}"

elif [ "$CAROUSEL" -lt 25 ]; then
    # Skills with diamond
    count=$(count_items "$SKILLS")
    idx=$((SLOW_FRAME % count))
    item=$(get_item "$SKILLS" $idx)
    output+="${PURPLE}${diamond}sk:${item}${R}"

elif [ "$CAROUSEL" -lt 30 ]; then
    # Hooks with pulse
    count=$(count_items "$HOOKS")
    idx=$((SLOW_FRAME % count))
    item=$(get_item "$HOOKS" $idx)
    output+="${DPURPLE}${pulse_dot}hk:${item}${R}"

elif [ "$CAROUSEL" -lt 35 ]; then
    # Active agent with tier indicator
    if [ -n "$current_agent" ] && [ "$current_agent" != "null" ]; then
        # Tier badge
        tier_badge=""
        case "$agent_tier" in
            elite) tier_badge="${NEON_YELLOW}★${R}" ;;
            orchestration) tier_badge="${PURPLE}◆${R}" ;;
            specialist) tier_badge="${CYAN}◇${R}" ;;
            utility) tier_badge="${DCYAN}○${R}" ;;
        esac

        case "$current_agent" in
            dragon*|Dragon*) output+="${CYAN}${BOLD}龍${current_agent}${R}${tier_badge}" ;;
            oracle*|Oracle*) output+="${CYAN}${BOLD}⊛${current_agent}${R}${tier_badge}" ;;
            nova*|Nova*) output+="${DCYAN}${BOLD}✸${current_agent}${R}${tier_badge}" ;;
            blitz*|Blitz*) output+="${CYAN}${BOLD}⚡${current_agent}${R}${tier_badge}" ;;
            angel*|Angel*) output+="${DCYAN}♆${current_agent}${R}${tier_badge}" ;;
            cache*|Cache*) output+="${CYAN}◎${current_agent}${R}${tier_badge}" ;;
            parallel*|Parallel*) output+="${DCYAN}⫘${current_agent}${R}${tier_badge}" ;;
            quantum*|Quantum*) output+="${PURPLE}◬${current_agent}${R}${tier_badge}" ;;
            architect*|Architect*) output+="${PURPLE}⬡${current_agent}${R}${tier_badge}" ;;
            master*|orchestrator*) output+="${CYAN}${BOLD}◈${current_agent}${R}${tier_badge}" ;;
            security*|Security*) output+="${NEON_RED}🛡${current_agent}${R}${tier_badge}" ;;
            debugger*|Debugger*) output+="${NEON_ORANGE}🔍${current_agent}${R}${tier_badge}" ;;
            *) output+="${CYAN}◇${current_agent}${R}${tier_badge}" ;;
        esac
    else
        output+="${CYAN}${star}OSA${R}"
    fi

elif [ "$CAROUSEL" -lt 38 ]; then
    # Output style indicator
    style_icon="▣"
    case "$output_style" in
        verbose) style_icon="▣▣" ;;
        concise) style_icon="▢" ;;
        streaming) style_icon="≋" ;;
        *) style_icon="▣" ;;
    esac
    if [ -n "$output_theme" ] && [ "$output_theme" != "null" ]; then
        output+="${DCYAN}${style_icon}${output_style}:${output_theme}${R}"
    else
        output+="${DCYAN}${style_icon}${output_style}${R}"
    fi

else
    # No git, end of carousel - show OSA with glitch
    output+="${PURPLE}${glitch}${CYAN}${BOLD}OSA${R}${PURPLE}${glitch}${R}"
fi
fi  # End of git branch check

# ═══════════════════════════════════════════════════════════════════════════
# EPIC ANIMATED PROGRESS BAR (Rainbow gradient with pulse)
# ═══════════════════════════════════════════════════════════════════════════

output+=" ${DGRAY}│${R} "

width=8
filled=$((remaining * width / 100))
empty=$((width - filled))

# Build bar with RAINBOW gradient based on position
bar=""
GRAD1="\033[38;5;51m"   # Cyan
GRAD2="\033[38;5;45m"   # Light cyan
GRAD3="\033[38;5;39m"   # Blue-cyan
GRAD4="\033[38;5;33m"   # Blue
GRAD5="\033[38;5;93m"   # Purple
GRAD6="\033[38;5;129m"  # Magenta
GRAD7="\033[38;5;165m"  # Pink
GRAD8="\033[38;5;201m"  # Hot pink

gradients=("$GRAD1" "$GRAD2" "$GRAD3" "$GRAD4" "$GRAD5" "$GRAD6" "$GRAD7" "$GRAD8")

for ((i=0; i<filled; i++)); do
    grad_idx=$(( (i + FRAME) % 8 ))
    bar+="${gradients[$grad_idx]}█"
done

# Animated pulse head with braille spinner
if [ "$empty" -gt 0 ]; then
    pulse_char=$(char_at "$DOT_PULSE" $FRAME)
    bar+="${PURPLE}${pulse_char}${DGRAY}"
    empty=$((empty - 1))
fi

for ((i=0; i<empty; i++)); do bar+="░"; done
bar+="${R}"

# Percentage with color + icon based on health
if [ "$remaining" -ge 70 ]; then
    output+="${bar} ${NEON_GREEN}${BOLD}${remaining}%${R}"
elif [ "$remaining" -ge 40 ]; then
    output+="${bar} ${CYAN}${remaining}%${R}"
elif [ "$remaining" -ge 20 ]; then
    output+="${bar} ${NEON_ORANGE}${remaining}%${R}"
else
    warn=$(char_at "$STARS" $FRAME)
    output+="${bar} ${NEON_RED}${BOLD}${remaining}%${warn}${R}"
fi

# ═══════════════════════════════════════════════════════════════════════════
# COST TRACKER (if enabled)
# ═══════════════════════════════════════════════════════════════════════════

if [ "$daily_cost" != "0" ] && [ "$daily_cost" != "null" ] && [ -n "$daily_cost" ]; then
    output+=" ${DGRAY}│${R} "
    cost_val=$(printf "%.2f" "$daily_cost" 2>/dev/null || echo "$daily_cost")
    cost_pct=$(awk "BEGIN {printf \"%.0f\", ($daily_cost / 50) * 100}" 2>/dev/null || echo "0")

    if [ "$cost_pct" -ge 80 ]; then
        output+="${NEON_RED}\$${cost_val}${R}"
    elif [ "$cost_pct" -ge 60 ]; then
        output+="${NEON_ORANGE}\$${cost_val}${R}"
    else
        output+="${CYAN}\$${cost_val}${R}"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# TASKS (with animated indicator)
# ═══════════════════════════════════════════════════════════════════════════

if [ -n "$task_id" ] && [ "$task_id" != "null" ]; then
    task_spin=$(char_at "$ORBITS" $FRAME)
    output+=" ${DGRAY}│${R} ${CYAN}${task_spin}${task_id}${R}"
    [ "$pending_tasks" -gt 0 ] && output+="${DCYAN}+${pending_tasks}${R}"
fi

# ═══════════════════════════════════════════════════════════════════════════
# LEARNING (animated sparkle)
# ═══════════════════════════════════════════════════════════════════════════

if [ "$patterns_stored" -gt 0 ] || [ "$solutions_stored" -gt 0 ]; then
    sparkle=$(char_at "$STARS" $FRAME)
    output+=" ${DGRAY}│${R} ${CYAN}${sparkle}${patterns_stored}/${solutions_stored}${R}"
fi

# ═══════════════════════════════════════════════════════════════════════════
# SESSION INFO (duration + message count + session ID)
# ═══════════════════════════════════════════════════════════════════════════

session_shown=0
if [ "$duration_ms" -gt 0 ]; then
    seconds=$((duration_ms / 1000))
    minutes=$((seconds / 60))
    hours=$((minutes / 60))

    if [ "$hours" -gt 0 ]; then
        dur="${hours}h$((minutes % 60))m"
    elif [ "$minutes" -gt 0 ]; then
        dur="${minutes}m"
    else
        dur="${seconds}s"
    fi
    output+=" ${DGRAY}│${R} ${PURPLE}${dur}${R}"
    session_shown=1
fi

# Message count (shows conversation depth)
if [ "$message_count" -gt 0 ]; then
    msg_icon="⟳"
    if [ "$session_shown" -eq 0 ]; then
        output+=" ${DGRAY}│${R}"
    fi
    output+=" ${DCYAN}${msg_icon}${message_count}${R}"
fi

# Session ID (brief identifier)
if [ -n "$session_id" ] && [ "$session_id" != "null" ]; then
    output+="${DGRAY}#${session_id}${R}"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PERFORMANCE (tokens/sec + cache hit rate)
# ═══════════════════════════════════════════════════════════════════════════

perf_shown=0
if [ "$tokens_per_sec" -gt 0 ]; then
    wave=$(char_at "$WAVES" $FRAME)
    output+=" ${DGRAY}│${R} ${DCYAN}${wave}${tokens_per_sec}t/s${R}"
    perf_shown=1
fi

# Cache hit rate (shows memory efficiency)
if [ "$cache_hit_rate" != "0" ] && [ "$cache_hit_rate" != "null" ] && [ -n "$cache_hit_rate" ]; then
    cache_pct=$(printf "%.0f" "$cache_hit_rate" 2>/dev/null || echo "$cache_hit_rate")
    if [ "$perf_shown" -eq 0 ]; then
        output+=" ${DGRAY}│${R}"
    fi
    if [ "$cache_pct" -ge 80 ]; then
        output+=" ${NEON_GREEN}⚡${cache_pct}%${R}"
    elif [ "$cache_pct" -ge 50 ]; then
        output+=" ${CYAN}◎${cache_pct}%${R}"
    else
        output+=" ${GRAY}◎${cache_pct}%${R}"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# EPIC HEALTH INDICATOR (animated status icons)
# ═══════════════════════════════════════════════════════════════════════════

ROCKETS="🚀🚀🚀🚀🚀🚀🚀🚀"
FLAMES="🔥🔥🔥🔥🔥🔥🔥🔥"
BOLTS="⚡⚡⚡⚡⚡⚡⚡⚡"
SPARKLES="✨💫⭐🌟✨💫⭐🌟"

if [ "$remaining" -ge 70 ]; then
    # OPTIMAL - Rocket with sparkle
    sparkle=$(char_at "$SPARKLES" $FRAME)
    output+=" ${NEON_GREEN}${BOLD}${sparkle}${R}"
elif [ "$remaining" -ge 40 ]; then
    # GOOD - Lightning bolt
    bolt=$(char_at "$BOLTS" $FRAME)
    output+=" ${CYAN}${bolt}${R}"
elif [ "$remaining" -ge 20 ]; then
    # WARNING - Pulsing alert
    orbit=$(char_at "$ORBITS" $FRAME)
    output+=" ${NEON_ORANGE}${BOLD}${orbit}${R}"
else
    # CRITICAL - Fire animation
    flame=$(char_at "$FLAMES" $FRAME)
    output+=" ${NEON_RED}${BOLD}${BLINK}${flame}${R}"
fi

# =============================================================================
# OUTPUT
# =============================================================================

echo -e "$output"
