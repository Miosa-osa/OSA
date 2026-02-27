#!/usr/bin/env bash
# mcp-cli-init.sh - Initialize mcp-cli environment with optimal settings
# Usage: source ~/.osa/scripts/mcp-cli-init.sh

# ============================================================================
# ENVIRONMENT VARIABLES
# ============================================================================

# MCP daemon timeout (in milliseconds)
# Default: 30000 (30 seconds)
# Increase for slow servers or complex operations
export MCP_DAEMON_TIMEOUT="${MCP_DAEMON_TIMEOUT:-30000}"

# Maximum concurrent MCP connections
# Default: 10
# Adjust based on system resources
export MCP_CONCURRENCY="${MCP_CONCURRENCY:-10}"

# MCP config file path
# Default: ~/.osa/mcp.json
export MCP_CONFIG_PATH="${MCP_CONFIG_PATH:-$HOME/.config/mcp/mcp_servers.json}"

# Enable debug mode (verbose logging)
# Default: false
export MCP_DEBUG="${MCP_DEBUG:-false}"

# Cache directory for mcp-cli results
export MCP_CACHE_DIR="${MCP_CACHE_DIR:-$HOME/.cache/mcp-cli}"
mkdir -p "$MCP_CACHE_DIR"

# Cache TTL in seconds (default: 5 minutes)
export MCP_CACHE_TTL="${MCP_CACHE_TTL:-300}"

# ============================================================================
# ALIASES
# ============================================================================

# Quick discovery
alias mcp='mcp-cli'
alias mcpls='mcp-cli'
alias mcplist='mcp-cli'

# Server exploration
alias mcpi='mcp-cli info'
alias mcpinfo='mcp-cli info'
alias mcpsearch='mcp-cli grep'
alias mcpgrep='mcp-cli grep'

# Tool execution
alias mcpc='mcp-cli call'
alias mcpcall='mcp-cli call'

# Common patterns
alias mcpservers='mcp-cli | grep "^[a-z]" | cut -d" " -f1'
alias mcptools='mcp-cli info'

# Shortcuts for frequently used servers
alias mcptm='mcp-cli info task-master-ai'        # Task Master
alias mcpgh='mcp-cli info github'                 # GitHub
alias mcpfs='mcp-cli info filesystem'             # Filesystem
alias mcpmem='mcp-cli info memory'                # Memory
alias mcpgit='mcp-cli info git'                   # Git
alias mcppw='mcp-cli info playwright'             # Playwright
alias mcpc7='mcp-cli info context7'               # Context7
alias mcpgrep='mcp-cli info greptile'             # Greptile

# ============================================================================
# HELPER FUNCTIONS (sourced from mcp-helpers.sh if available)
# ============================================================================

if [[ -f "$HOME/.osa/scripts/mcp-helpers.sh" ]]; then
    source "$HOME/.osa/scripts/mcp-helpers.sh"
fi

# ============================================================================
# COMPLETION HELPERS
# ============================================================================

# Generate server list for completion
_mcp_servers() {
    if [[ -f "$MCP_CONFIG_PATH" ]]; then
        jq -r '.mcpServers | keys[]' "$MCP_CONFIG_PATH" 2>/dev/null
    fi
}

# Simple completion for mcp-cli
_mcp_complete() {
    local cur prev
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    case "$prev" in
        mcp-cli|mcp|mcpls)
            COMPREPLY=($(compgen -W "info call grep" -- "$cur"))
            ;;
        info|mcpi|mcpinfo)
            COMPREPLY=($(compgen -W "$(_mcp_servers)" -- "$cur"))
            ;;
        call|mcpc|mcpcall)
            COMPREPLY=($(compgen -W "$(_mcp_servers)" -- "$cur"))
            ;;
    esac
}

# Register completion
if command -v complete &>/dev/null; then
    complete -F _mcp_complete mcp-cli mcp mcpls mcpi mcpinfo mcpc mcpcall
fi

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# Check if mcp-cli is installed
mcp_check_install() {
    if ! command -v mcp-cli &>/dev/null; then
        echo "Error: mcp-cli not found in PATH"
        echo "Install from: https://github.com/wong2/mcp-cli"
        return 1
    fi
    return 0
}

# Show mcp-cli environment info
mcp_env_info() {
    echo "MCP CLI Environment:"
    echo "  Config: $MCP_CONFIG_PATH"
    echo "  Cache:  $MCP_CACHE_DIR"
    echo "  Cache TTL: ${MCP_CACHE_TTL}s"
    echo "  Timeout: ${MCP_DAEMON_TIMEOUT}ms"
    echo "  Concurrency: $MCP_CONCURRENCY"
    echo "  Debug: $MCP_DEBUG"
    echo ""
    if mcp_check_install; then
        echo "  mcp-cli: $(which mcp-cli)"
        echo "  Status: Ready"
    fi
}

# Clear mcp-cli cache
mcp_clear_cache() {
    if [[ -d "$MCP_CACHE_DIR" ]]; then
        rm -rf "$MCP_CACHE_DIR"/*
        echo "MCP cache cleared: $MCP_CACHE_DIR"
    fi
}

# Enable debug mode
mcp_debug_on() {
    export MCP_DEBUG=true
    echo "MCP debug mode enabled"
}

# Disable debug mode
mcp_debug_off() {
    export MCP_DEBUG=false
    echo "MCP debug mode disabled"
}

# ============================================================================
# INITIALIZATION
# ============================================================================

# Check installation
if mcp_check_install; then
    # Verify config exists
    if [[ ! -f "$MCP_CONFIG_PATH" ]]; then
        echo "Warning: MCP config not found at $MCP_CONFIG_PATH"
    fi

    # Show quick help if this is first time
    if [[ ! -f "$HOME/.cache/mcp-cli/.initialized" ]]; then
        echo "MCP CLI initialized. Quick start:"
        echo "  mcp              - List all servers and tools"
        echo "  mcp info <srv>   - Show server tools"
        echo "  mcp call <srv> <tool> '{}'  - Execute tool"
        echo ""
        echo "Run 'mcp_env_info' for environment details"
        echo "Run 'mcp_help' for helper functions"
        mkdir -p "$HOME/.cache/mcp-cli"
        touch "$HOME/.cache/mcp-cli/.initialized"
    fi
fi

# Export functions for subshells (bash only - zsh handles this differently)
if [[ -n "$BASH_VERSION" ]]; then
    export -f mcp_check_install 2>/dev/null
    export -f mcp_env_info 2>/dev/null
    export -f mcp_clear_cache 2>/dev/null
    export -f mcp_debug_on 2>/dev/null
    export -f mcp_debug_off 2>/dev/null
fi
