#!/bin/bash
# =============================================================================
# EPIC STATUS LINE v1.0 - The Craziest Status Line Known to Claude Code
# =============================================================================
# Designed for: OSO's M5 Mac | Claude Code Ecosystem v3.3
# Features: Visual progress bars, Nerd Font icons, color gradients,
#           git integration, cost tracking, agent indicators, learning metrics
# =============================================================================

# Read JSON input from Claude Code
input=$(cat)

# =============================================================================
# PARSE ALL AVAILABLE DATA
# =============================================================================

# Workspace
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // "~"')
git_branch=$(echo "$input" | jq -r '.workspace.git_branch // empty')
git_status=$(echo "$input" | jq -r '.workspace.git_status // empty')

# Model info
model=$(echo "$input" | jq -r '.model.display_name // .model.id // "opus"')
model_tier=$(echo "$input" | jq -r '.model.tier // "elite"')

# Context window
remaining=$(echo "$input" | jq -r '.context_window.remaining_percentage // 100' | cut -d. -f1)

# Cost tracking
session_cost=$(echo "$input" | jq -r '.cost.session_cost_usd // 0')
daily_cost=$(echo "$input" | jq -r '.cost.daily_cost_usd // 0')
daily_budget=$(echo "$input" | jq -r '.cost.daily_budget // 50')

# Session info
session_id=$(echo "$input" | jq -r '.session.id // empty' | head -c 8)
duration_ms=$(echo "$input" | jq -r '.session.duration_ms // 0')
message_count=$(echo "$input" | jq -r '.session.message_count // 0')

# Task info
task_id=$(echo "$input" | jq -r '.task.current_id // empty')
pending_tasks=$(echo "$input" | jq -r '.task.pending_count // 0')

# Agent info
current_agent=$(echo "$input" | jq -r '.agent.current // "master"')
agent_tier=$(echo "$input" | jq -r '.agent.tier // "orchestrator"')

# Learning metrics
patterns_stored=$(echo "$input" | jq -r '.learning.patterns_stored // 0')
solutions_stored=$(echo "$input" | jq -r '.learning.solutions_stored // 0')

# Performance
tokens_per_sec=$(echo "$input" | jq -r '.performance.tokens_per_second // 0')
cache_hit_rate=$(echo "$input" | jq -r '.performance.cache_hit_rate // 0')

# Output style
output_style=$(echo "$input" | jq -r '.output_style.name // "default"')

# =============================================================================
# COLORS (ANSI 256 for maximum vibes)
# =============================================================================

# Reset
R="\033[0m"

# Foreground colors
FG_BLACK="\033[38;5;0m"
FG_RED="\033[38;5;196m"
FG_GREEN="\033[38;5;46m"
FG_YELLOW="\033[38;5;226m"
FG_BLUE="\033[38;5;33m"
FG_MAGENTA="\033[38;5;201m"
FG_CYAN="\033[38;5;51m"
FG_WHITE="\033[38;5;255m"
FG_ORANGE="\033[38;5;208m"
FG_PURPLE="\033[38;5;141m"
FG_PINK="\033[38;5;213m"
FG_LIME="\033[38;5;154m"
FG_GOLD="\033[38;5;220m"
FG_GRAY="\033[38;5;240m"
FG_DIM="\033[2m"

# Special effects
BOLD="\033[1m"
DIM="\033[2m"
ITALIC="\033[3m"
BLINK="\033[5m"

# =============================================================================
# NERD FONT ICONS (Requires Nerd Font - you have eza with icons!)
# =============================================================================

ICON_FOLDER=""
ICON_GIT=""
ICON_BRANCH=""
ICON_MODIFIED=""
ICON_STAGED=""
ICON_BRAIN="󰧠"
ICON_CPU=""
ICON_MEMORY="󰍛"
ICON_CLOCK=""
ICON_TASK=""
ICON_CHECK=""
ICON_FIRE=""
ICON_LIGHTNING=""
ICON_STAR=""
ICON_ROBOT="󰚩"
ICON_CHART=""
ICON_DOLLAR=""
ICON_WARNING=""
ICON_ERROR=""
ICON_SPARKLE="✨"
ICON_ROCKET=""
ICON_DIAMOND="󰀚"
ICON_CROWN=""
ICON_SHIELD="󰒃"
ICON_GEAR=""
ICON_ATOM=""
ICON_DRAGON="󰩃"
ICON_ORACLE="󰜫"
ICON_NOVA=""
ICON_BLITZ="󱐋"
ICON_CACHE="󰆏"
ICON_QUANTUM=""
ICON_PARALLEL="󱓞"
ICON_ANGEL="󰯈"

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# Progress bar with gradient colors
progress_bar() {
    local percent=$1
    local width=${2:-10}
    local filled=$((percent * width / 100))
    local empty=$((width - filled))

    local bar=""
    local color

    # Color based on percentage (gradient from green to red)
    if [ "$percent" -ge 80 ]; then
        color="$FG_GREEN"
    elif [ "$percent" -ge 60 ]; then
        color="$FG_LIME"
    elif [ "$percent" -ge 40 ]; then
        color="$FG_YELLOW"
    elif [ "$percent" -ge 20 ]; then
        color="$FG_ORANGE"
    else
        color="$FG_RED"
    fi

    bar+="${color}"
    for ((i=0; i<filled; i++)); do bar+="█"; done
    bar+="${FG_GRAY}"
    for ((i=0; i<empty; i++)); do bar+="░"; done
    bar+="${R}"

    echo -e "$bar"
}

# Format duration
format_duration() {
    local ms=$1
    local seconds=$((ms / 1000))
    local minutes=$((seconds / 60))
    local hours=$((minutes / 60))

    if [ "$hours" -gt 0 ]; then
        echo "${hours}h$((minutes % 60))m"
    elif [ "$minutes" -gt 0 ]; then
        echo "${minutes}m$((seconds % 60))s"
    else
        echo "${seconds}s"
    fi
}

# Get agent icon based on name
get_agent_icon() {
    local agent=$1
    case "$agent" in
        dragon*) echo "$ICON_DRAGON" ;;
        oracle*) echo "$ICON_ORACLE" ;;
        nova*) echo "$ICON_NOVA" ;;
        blitz*) echo "$ICON_BLITZ" ;;
        cache*) echo "$ICON_CACHE" ;;
        quantum*) echo "$ICON_QUANTUM" ;;
        parallel*) echo "$ICON_PARALLEL" ;;
        angel*) echo "$ICON_ANGEL" ;;
        architect*) echo "$ICON_DIAMOND" ;;
        master*|orchestrator*) echo "$ICON_CROWN" ;;
        security*) echo "$ICON_SHIELD" ;;
        *) echo "$ICON_ROBOT" ;;
    esac
}

# Get tier color
get_tier_color() {
    local tier=$1
    case "$tier" in
        elite) echo "$FG_GOLD" ;;
        orchestration) echo "$FG_PURPLE" ;;
        specialist) echo "$FG_CYAN" ;;
        utility) echo "$FG_GREEN" ;;
        *) echo "$FG_WHITE" ;;
    esac
}

# Get model color
get_model_color() {
    local model=$1
    case "$model" in
        *opus*|*Opus*) echo "$FG_GOLD$BOLD" ;;
        *sonnet*|*Sonnet*) echo "$FG_PURPLE" ;;
        *haiku*|*Haiku*) echo "$FG_CYAN" ;;
        *) echo "$FG_WHITE" ;;
    esac
}

# =============================================================================
# BUILD THE EPIC STATUS LINE
# =============================================================================

output=""

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 1: Directory + Git
# ─────────────────────────────────────────────────────────────────────────────

# Shorten home directory
if [[ "$cwd" == "$HOME"* ]]; then
    cwd_display="~${cwd#$HOME}"
else
    cwd_display="$cwd"
fi

# Truncate long paths
if [ ${#cwd_display} -gt 30 ]; then
    cwd_display="…${cwd_display: -27}"
fi

output+="${FG_CYAN}${ICON_FOLDER} ${BOLD}${cwd_display}${R}"

# Git info
if [ -n "$git_branch" ]; then
    output+=" ${FG_GRAY}│${R} ${FG_PURPLE}${ICON_BRANCH} ${git_branch}${R}"

    # Git status indicators
    if [ -n "$git_status" ]; then
        if [[ "$git_status" == *"modified"* ]] || [[ "$git_status" == *"M"* ]]; then
            output+="${FG_YELLOW}${ICON_MODIFIED}${R}"
        fi
        if [[ "$git_status" == *"staged"* ]] || [[ "$git_status" == *"A"* ]]; then
            output+="${FG_GREEN}${ICON_STAGED}${R}"
        fi
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 2: Model + Agent
# ─────────────────────────────────────────────────────────────────────────────

output+=" ${FG_GRAY}│${R} "

# Model with color
model_color=$(get_model_color "$model")
output+="${model_color}${ICON_BRAIN} ${model}${R}"

# Agent indicator
if [ -n "$current_agent" ] && [ "$current_agent" != "null" ] && [ "$current_agent" != "master" ]; then
    agent_icon=$(get_agent_icon "$current_agent")
    tier_color=$(get_tier_color "$agent_tier")
    output+=" ${tier_color}${agent_icon}${R}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 3: Context Window Progress Bar
# ─────────────────────────────────────────────────────────────────────────────

output+=" ${FG_GRAY}│${R} "

# Progress bar
bar=$(progress_bar "$remaining" 8)
output+="${ICON_CHART} ${bar} ${remaining}%"

# Warning indicator
if [ "$remaining" -lt 20 ]; then
    output+=" ${FG_RED}${BLINK}${ICON_WARNING}${R}"
elif [ "$remaining" -lt 40 ]; then
    output+=" ${FG_ORANGE}${ICON_WARNING}${R}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 4: Cost Tracking
# ─────────────────────────────────────────────────────────────────────────────

# Only show if tracking
if [ "$session_cost" != "0" ] && [ "$session_cost" != "null" ]; then
    output+=" ${FG_GRAY}│${R} "

    # Format cost (handle decimals with bc or awk)
    if [ "$daily_cost" != "0" ] && [ "$daily_cost" != "null" ]; then
        # Use awk for floating point math
        cost_percent=$(awk "BEGIN {printf \"%.0f\", ($daily_cost / $daily_budget) * 100}" 2>/dev/null || echo "0")
        if [ "$cost_percent" -ge 80 ]; then
            cost_color="$FG_RED"
        elif [ "$cost_percent" -ge 60 ]; then
            cost_color="$FG_ORANGE"
        else
            cost_color="$FG_GREEN"
        fi
        output+="${cost_color}${ICON_DOLLAR}\$${daily_cost}/\$${daily_budget}${R}"
    else
        output+="${FG_GREEN}${ICON_DOLLAR}\$${session_cost}${R}"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 5: Task Info
# ─────────────────────────────────────────────────────────────────────────────

if [ -n "$task_id" ] && [ "$task_id" != "null" ]; then
    output+=" ${FG_GRAY}│${R} ${FG_YELLOW}${ICON_TASK}#${task_id}${R}"
fi

if [ "$pending_tasks" -gt 0 ]; then
    output+=" ${FG_ORANGE}(${pending_tasks})${R}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 6: Learning Metrics (if available)
# ─────────────────────────────────────────────────────────────────────────────

if [ "$patterns_stored" -gt 0 ] || [ "$solutions_stored" -gt 0 ]; then
    output+=" ${FG_GRAY}│${R} ${FG_LIME}${ICON_SPARKLE}${patterns_stored}p/${solutions_stored}s${R}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 7: Session Duration
# ─────────────────────────────────────────────────────────────────────────────

if [ "$duration_ms" -gt 0 ]; then
    duration=$(format_duration "$duration_ms")
    output+=" ${FG_GRAY}│${R} ${FG_BLUE}${ICON_CLOCK}${duration}${R}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 8: Performance Indicators
# ─────────────────────────────────────────────────────────────────────────────

if [ "$tokens_per_sec" -gt 0 ]; then
    output+=" ${FG_GRAY}│${R} ${FG_CYAN}${ICON_LIGHTNING}${tokens_per_sec}t/s${R}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# FINAL: Status indicator based on system health
# ─────────────────────────────────────────────────────────────────────────────

# Overall health indicator
cost_pct=${cost_percent:-0}
if [ "$remaining" -ge 60 ] && [ "$cost_pct" -lt 80 ]; then
    output+=" ${FG_GREEN}${ICON_ROCKET}${R}"
elif [ "$remaining" -ge 30 ]; then
    output+=" ${FG_YELLOW}${ICON_GEAR}${R}"
else
    output+=" ${FG_RED}${ICON_FIRE}${R}"
fi

# =============================================================================
# OUTPUT
# =============================================================================

echo -e "$output"
