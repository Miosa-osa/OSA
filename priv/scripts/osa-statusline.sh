#!/bin/bash
# =============================================================================
# OSA AGENT STATUS LINE v1.0 - The Ultimate AI Agent Interface
# =============================================================================
# OSA (Orchestrated System Architecture) Agent
# Designed for: OSO's M5 Mac | Multi-Agent AI Development System
# =============================================================================

# Read JSON input
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
duration_ms=$(echo "$input" | jq -r '.session.duration_ms // 0')
message_count=$(echo "$input" | jq -r '.session.message_count // 0')

# Task info
task_id=$(echo "$input" | jq -r '.task.current_id // empty')
pending_tasks=$(echo "$input" | jq -r '.task.pending_count // 0')

# Agent info
current_agent=$(echo "$input" | jq -r '.agent.current // empty')
agent_tier=$(echo "$input" | jq -r '.agent.tier // "orchestrator"')

# Learning metrics
patterns_stored=$(echo "$input" | jq -r '.learning.patterns_stored // 0')
solutions_stored=$(echo "$input" | jq -r '.learning.solutions_stored // 0')

# Performance
tokens_per_sec=$(echo "$input" | jq -r '.performance.tokens_per_second // 0')

# =============================================================================
# OSA AGENT COLORS (Custom palette)
# =============================================================================

R="\033[0m"

# OSA Brand Colors
OSA_PRIMARY="\033[38;5;39m"      # Electric blue
OSA_SECONDARY="\033[38;5;213m"  # Pink/magenta
OSA_ACCENT="\033[38;5;220m"     # Gold
OSA_SUCCESS="\033[38;5;46m"     # Bright green
OSA_WARNING="\033[38;5;208m"    # Orange
OSA_DANGER="\033[38;5;196m"     # Red
OSA_MUTED="\033[38;5;240m"      # Gray

# Tier colors
TIER_ELITE="\033[38;5;220m"     # Gold
TIER_COMBAT="\033[38;5;201m"    # Magenta
TIER_SPEC="\033[38;5;51m"       # Cyan
TIER_UTIL="\033[38;5;46m"       # Green

BOLD="\033[1m"
DIM="\033[2m"
BLINK="\033[5m"

# =============================================================================
# OSA AGENT ICONS
# =============================================================================

# OSA Brand
ICON_OSA="◈"
ICON_OSA_FULL="⟨OSA⟩"

# System
ICON_FOLDER=""
ICON_GIT=""
ICON_BRANCH=""
ICON_MODIFIED=""
ICON_BRAIN="󰧠"
ICON_CLOCK=""
ICON_TASK=""
ICON_CHART=""
ICON_DOLLAR=""
ICON_WARNING=""
ICON_SPARKLE="✦"
ICON_ROCKET=""
ICON_GEAR=""
ICON_FIRE=""
ICON_LIGHTNING=""
ICON_SHIELD="󰒃"

# Agent Icons - OSA Codenames
ICON_DRAGON="龍"       # Dragon - Ultra performance
ICON_ORACLE="⊛"        # Oracle - AI/ML
ICON_NOVA="✸"          # Nova - Platform
ICON_BLITZ="⚡"         # Blitz - Speed
ICON_ANGEL="♆"         # Angel - DevOps
ICON_CACHE="◎"         # Cache - Memory
ICON_PARALLEL="⫘"      # Parallel - Concurrency
ICON_QUANTUM="◬"       # Quantum - Real-time
ICON_CROWN="◆"         # Master Orchestrator
ICON_ROBOT="◇"         # Default agent

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# OSA-style progress bar
progress_bar() {
    local percent=$1
    local width=${2:-8}
    local filled=$((percent * width / 100))
    local empty=$((width - filled))

    local bar=""
    local color

    if [ "$percent" -ge 70 ]; then
        color="$OSA_SUCCESS"
    elif [ "$percent" -ge 40 ]; then
        color="$OSA_WARNING"
    else
        color="$OSA_DANGER"
    fi

    bar+="${color}"
    for ((i=0; i<filled; i++)); do bar+="▰"; done
    bar+="${OSA_MUTED}"
    for ((i=0; i<empty; i++)); do bar+="▱"; done
    bar+="${R}"

    echo -e "$bar"
}

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
        architect*|master*|orchestrator*) echo "$ICON_CROWN" ;;
        security*) echo "$ICON_SHIELD" ;;
        *) echo "$ICON_ROBOT" ;;
    esac
}

get_tier_color() {
    local tier=$1
    case "$tier" in
        elite) echo "$TIER_ELITE" ;;
        combat) echo "$TIER_COMBAT" ;;
        specialist) echo "$TIER_SPEC" ;;
        utility) echo "$TIER_UTIL" ;;
        *) echo "$OSA_PRIMARY" ;;
    esac
}

# =============================================================================
# BUILD OSA STATUS LINE
# =============================================================================

output=""

# ─────────────────────────────────────────────────────────────────────────────
# OSA BADGE
# ─────────────────────────────────────────────────────────────────────────────

output+="${OSA_PRIMARY}${BOLD}${ICON_OSA}${R}"

# ─────────────────────────────────────────────────────────────────────────────
# DIRECTORY + GIT
# ─────────────────────────────────────────────────────────────────────────────

if [[ "$cwd" == "$HOME"* ]]; then
    cwd_display="~${cwd#$HOME}"
else
    cwd_display="$cwd"
fi

if [ ${#cwd_display} -gt 25 ]; then
    cwd_display="…${cwd_display: -22}"
fi

output+=" ${OSA_PRIMARY}${cwd_display}${R}"

if [ -n "$git_branch" ]; then
    output+="${OSA_MUTED}:${R}${OSA_SECONDARY}${git_branch}${R}"
    if [ -n "$git_status" ]; then
        if [[ "$git_status" == *"modified"* ]] || [[ "$git_status" == *"M"* ]]; then
            output+="${OSA_WARNING}${ICON_MODIFIED}${R}"
        fi
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# MODEL + AGENT
# ─────────────────────────────────────────────────────────────────────────────

output+=" ${OSA_MUTED}│${R} "

# Model badge
case "$model" in
    *opus*|*Opus*)
        output+="${TIER_ELITE}${BOLD}${model}${R}"
        ;;
    *sonnet*|*Sonnet*)
        output+="${OSA_SECONDARY}${model}${R}"
        ;;
    *haiku*|*Haiku*)
        output+="${TIER_SPEC}${model}${R}"
        ;;
    *)
        output+="${OSA_PRIMARY}${model}${R}"
        ;;
esac

# Active agent
if [ -n "$current_agent" ] && [ "$current_agent" != "null" ]; then
    agent_icon=$(get_agent_icon "$current_agent")
    tier_color=$(get_tier_color "$agent_tier")
    output+=" ${tier_color}${agent_icon}${R}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# CONTEXT WINDOW
# ─────────────────────────────────────────────────────────────────────────────

output+=" ${OSA_MUTED}│${R} "

bar=$(progress_bar "$remaining" 6)
output+="${bar} ${remaining}%"

if [ "$remaining" -lt 20 ]; then
    output+=" ${OSA_DANGER}${BLINK}!${R}"
elif [ "$remaining" -lt 40 ]; then
    output+=" ${OSA_WARNING}${ICON_WARNING}${R}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# COST
# ─────────────────────────────────────────────────────────────────────────────

if [ "$session_cost" != "0" ] && [ "$session_cost" != "null" ]; then
    output+=" ${OSA_MUTED}│${R} "

    if [ "$daily_cost" != "0" ] && [ "$daily_cost" != "null" ]; then
        cost_percent=$(awk "BEGIN {printf \"%.0f\", ($daily_cost / $daily_budget) * 100}" 2>/dev/null || echo "0")
        if [ "$cost_percent" -ge 80 ]; then
            cost_color="$OSA_DANGER"
        elif [ "$cost_percent" -ge 60 ]; then
            cost_color="$OSA_WARNING"
        else
            cost_color="$OSA_SUCCESS"
        fi
        output+="${cost_color}${ICON_DOLLAR}${daily_cost}${R}"
    else
        output+="${OSA_SUCCESS}${ICON_DOLLAR}${session_cost}${R}"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# TASKS
# ─────────────────────────────────────────────────────────────────────────────

if [ -n "$task_id" ] && [ "$task_id" != "null" ]; then
    output+=" ${OSA_MUTED}│${R} ${OSA_ACCENT}${ICON_TASK}${task_id}${R}"
fi

if [ "$pending_tasks" -gt 0 ]; then
    output+="${OSA_WARNING}(${pending_tasks})${R}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# LEARNING
# ─────────────────────────────────────────────────────────────────────────────

if [ "$patterns_stored" -gt 0 ] || [ "$solutions_stored" -gt 0 ]; then
    output+=" ${OSA_MUTED}│${R} ${OSA_SUCCESS}${ICON_SPARKLE}${patterns_stored}/${solutions_stored}${R}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# DURATION
# ─────────────────────────────────────────────────────────────────────────────

if [ "$duration_ms" -gt 0 ]; then
    duration=$(format_duration "$duration_ms")
    output+=" ${OSA_MUTED}│${R} ${OSA_PRIMARY}${duration}${R}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PERFORMANCE
# ─────────────────────────────────────────────────────────────────────────────

if [ "$tokens_per_sec" -gt 0 ]; then
    output+=" ${OSA_MUTED}│${R} ${TIER_SPEC}${ICON_LIGHTNING}${tokens_per_sec}${R}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# HEALTH STATUS
# ─────────────────────────────────────────────────────────────────────────────

cost_pct=${cost_percent:-0}
if [ "$remaining" -ge 60 ] && [ "$cost_pct" -lt 80 ]; then
    output+=" ${OSA_SUCCESS}${ICON_ROCKET}${R}"
elif [ "$remaining" -ge 30 ]; then
    output+=" ${OSA_WARNING}${ICON_GEAR}${R}"
else
    output+=" ${OSA_DANGER}${ICON_FIRE}${R}"
fi

# =============================================================================
# OUTPUT
# =============================================================================

echo -e "$output"
