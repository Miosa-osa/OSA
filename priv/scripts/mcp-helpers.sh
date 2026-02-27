#!/usr/bin/env bash
# mcp-helpers.sh - Helper functions for common mcp-cli patterns
# Usage: source ~/.osa/scripts/mcp-helpers.sh

# ============================================================================
# CORE HELPERS
# ============================================================================

# Search across all servers for matching tools
# Usage: mcp_search "pattern"
mcp_search() {
    local pattern="$1"
    if [[ -z "$pattern" ]]; then
        echo "Usage: mcp_search <pattern>"
        echo "Example: mcp_search 'file'"
        return 1
    fi

    echo "Searching for tools matching: $pattern"
    echo ""
    mcp-cli grep "*${pattern}*"
}

# Get tool schema with validation
# Usage: mcp_schema <server> <tool>
mcp_schema() {
    local server="$1"
    local tool="$2"

    if [[ -z "$server" || -z "$tool" ]]; then
        echo "Usage: mcp_schema <server> <tool>"
        echo "Example: mcp_schema filesystem read_file"
        return 1
    fi

    echo "Fetching schema for $server/$tool..."
    mcp-cli info "$server" "$tool"
}

# Build JSON safely with validation
# Usage: mcp_json key1=value1 key2=value2
mcp_json() {
    local json="{"
    local first=true

    for arg in "$@"; do
        if [[ ! "$arg" =~ ^([^=]+)=(.+)$ ]]; then
            echo "Error: Invalid format '$arg'. Use key=value"
            return 1
        fi

        local key="${BASH_REMATCH[1]}"
        local value="${BASH_REMATCH[2]}"

        # Add comma if not first item
        if [[ "$first" = false ]]; then
            json+=","
        fi
        first=false

        # Quote string values, pass through others
        if [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" =~ ^(true|false|null)$ ]]; then
            json+="\"$key\":$value"
        else
            # Escape quotes in value
            value="${value//\"/\\\"}"
            json+="\"$key\":\"$value\""
        fi
    done

    json+="}"
    echo "$json"
}

# Call MCP tool with error handling
# Usage: mcp_call <server> <tool> <json>
mcp_call() {
    local server="$1"
    local tool="$2"
    local args="$3"

    if [[ -z "$server" || -z "$tool" ]]; then
        echo "Usage: mcp_call <server> <tool> <json>"
        echo "Example: mcp_call filesystem read_file '{\"path\": \"./file.txt\"}'"
        return 1
    fi

    # Default to empty object if no args
    args="${args:-{}}"

    # Validate JSON
    if ! echo "$args" | jq empty 2>/dev/null; then
        echo "Error: Invalid JSON: $args"
        return 1
    fi

    # Execute with error handling
    local output
    local exit_code

    output=$(mcp-cli call "$server" "$tool" "$args" 2>&1)
    exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        echo "$output"
        return 0
    else
        echo "Error calling $server/$tool (exit code: $exit_code):" >&2
        echo "$output" >&2
        return $exit_code
    fi
}

# ============================================================================
# CHAINING HELPERS
# ============================================================================

# Chain multiple MCP calls with result passing
# Usage: mcp_chain "server1/tool1" '{}' "server2/tool2" 'jq .result'
mcp_chain() {
    local result="{}"

    while [[ $# -gt 0 ]]; do
        local server_tool="$1"
        local args="$2"
        shift 2

        if [[ ! "$server_tool" =~ ^([^/]+)/(.+)$ ]]; then
            echo "Error: Invalid format '$server_tool'. Use server/tool"
            return 1
        fi

        local server="${BASH_REMATCH[1]}"
        local tool="${BASH_REMATCH[2]}"

        echo "[$server/$tool] Executing..." >&2

        # Replace {{result}} placeholder with previous result
        args="${args//\{\{result\}\}/$result}"

        result=$(mcp_call "$server" "$tool" "$args")
        if [[ $? -ne 0 ]]; then
            echo "Chain failed at $server/$tool" >&2
            return 1
        fi

        # Apply jq filter if next arg is a jq expression
        if [[ $# -gt 0 && "$1" =~ ^\. ]]; then
            local filter="$1"
            shift
            result=$(echo "$result" | jq -r "$filter")
        fi
    done

    echo "$result"
}

# Parallel execution of multiple MCP calls
# Usage: mcp_parallel "server1/tool1:{}" "server2/tool2:{}"
mcp_parallel() {
    local pids=()
    local results=()
    local tmpdir
    tmpdir=$(mktemp -d)

    local index=0
    for call in "$@"; do
        if [[ ! "$call" =~ ^([^/]+)/([^:]+):(.+)$ ]]; then
            echo "Error: Invalid format '$call'. Use server/tool:{json}"
            rm -rf "$tmpdir"
            return 1
        fi

        local server="${BASH_REMATCH[1]}"
        local tool="${BASH_REMATCH[2]}"
        local args="${BASH_REMATCH[3]}"

        # Execute in background
        (mcp_call "$server" "$tool" "$args" > "$tmpdir/result_$index" 2>&1) &
        pids+=($!)
        ((index++))
    done

    # Wait for all to complete
    local failed=0
    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
            ((failed++))
        fi
    done

    # Collect results
    for i in $(seq 0 $((index-1))); do
        if [[ -f "$tmpdir/result_$i" ]]; then
            cat "$tmpdir/result_$i"
            echo ""
        fi
    done

    rm -rf "$tmpdir"

    if [[ $failed -gt 0 ]]; then
        echo "Warning: $failed parallel call(s) failed" >&2
        return 1
    fi

    return 0
}

# ============================================================================
# TASK MASTER HELPERS
# ============================================================================

# Quick task operations
tm_next() {
    mcp_call task-master-ai next_task '{}'
}

tm_get() {
    local task_id="$1"
    if [[ -z "$task_id" ]]; then
        echo "Usage: tm_get <task_id>"
        return 1
    fi
    mcp_call task-master-ai get_task "$(mcp_json id="$task_id")"
}

tm_list() {
    mcp_call task-master-ai get_tasks '{}'
}

tm_add() {
    local title="$1"
    if [[ -z "$title" ]]; then
        echo "Usage: tm_add <title>"
        return 1
    fi
    mcp_call task-master-ai add_task "$(mcp_json title="$title")"
}

tm_done() {
    local task_id="$1"
    if [[ -z "$task_id" ]]; then
        echo "Usage: tm_done <task_id>"
        return 1
    fi
    mcp_call task-master-ai set_task_status "$(mcp_json id="$task_id" status=done)"
}

# ============================================================================
# GITHUB HELPERS
# ============================================================================

# Search GitHub repositories
gh_search() {
    local query="$1"
    if [[ -z "$query" ]]; then
        echo "Usage: gh_search <query>"
        return 1
    fi
    mcp_call github search_repositories "$(mcp_json query="$query")"
}

# Get file contents from GitHub
gh_file() {
    local owner="$1"
    local repo="$2"
    local path="$3"

    if [[ -z "$owner" || -z "$repo" || -z "$path" ]]; then
        echo "Usage: gh_file <owner> <repo> <path>"
        return 1
    fi

    mcp_call github get_file_contents "$(mcp_json owner="$owner" repo="$repo" path="$path")"
}

# List pull requests
gh_prs() {
    local owner="$1"
    local repo="$2"

    if [[ -z "$owner" || -z "$repo" ]]; then
        echo "Usage: gh_prs <owner> <repo>"
        return 1
    fi

    mcp_call github list_pull_requests "$(mcp_json owner="$owner" repo="$repo")"
}

# ============================================================================
# FILESYSTEM HELPERS
# ============================================================================

# Read file via MCP
fs_read() {
    local path="$1"
    if [[ -z "$path" ]]; then
        echo "Usage: fs_read <path>"
        return 1
    fi
    mcp_call filesystem read_file "$(mcp_json path="$path")"
}

# Write file via MCP
fs_write() {
    local path="$1"
    local content="$2"

    if [[ -z "$path" || -z "$content" ]]; then
        echo "Usage: fs_write <path> <content>"
        return 1
    fi

    mcp_call filesystem write_file "$(mcp_json path="$path" content="$content")"
}

# List directory via MCP
fs_ls() {
    local path="${1:-.}"
    mcp_call filesystem list_directory "$(mcp_json path="$path")"
}

# Search files via MCP
fs_search() {
    local pattern="$1"
    local path="${2:-.}"

    if [[ -z "$pattern" ]]; then
        echo "Usage: fs_search <pattern> [path]"
        return 1
    fi

    mcp_call filesystem search_files "$(mcp_json pattern="$pattern" path="$path")"
}

# ============================================================================
# MEMORY HELPERS
# ============================================================================

# Search memory graph
mem_search() {
    local query="$1"
    if [[ -z "$query" ]]; then
        echo "Usage: mem_search <query>"
        return 1
    fi
    mcp_call memory search_nodes "$(mcp_json query="$query")"
}

# Create entity in memory
mem_create() {
    local name="$1"
    local type="$2"
    local content="$3"

    if [[ -z "$name" || -z "$type" || -z "$content" ]]; then
        echo "Usage: mem_create <name> <type> <content>"
        return 1
    fi

    mcp_call memory create_entities "$(mcp_json name="$name" entityType="$type" observations="$content")"
}

# Read memory graph
mem_graph() {
    mcp_call memory read_graph '{}'
}

# ============================================================================
# ERROR HANDLING WRAPPERS
# ============================================================================

# Retry wrapper with exponential backoff
mcp_retry() {
    local max_attempts="${MCP_RETRY_MAX:-3}"
    local base_delay="${MCP_RETRY_DELAY:-2}"
    local server="$1"
    local tool="$2"
    local args="$3"

    for attempt in $(seq 1 "$max_attempts"); do
        if mcp_call "$server" "$tool" "$args"; then
            return 0
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            local delay=$((base_delay ** attempt))
            echo "Retry $attempt/$max_attempts failed, waiting ${delay}s..." >&2
            sleep "$delay"
        fi
    done

    echo "All $max_attempts attempts failed" >&2
    return 1
}

# Timeout wrapper
mcp_timeout() {
    local timeout="$1"
    local server="$2"
    local tool="$3"
    local args="$4"

    if [[ -z "$timeout" ]]; then
        echo "Usage: mcp_timeout <seconds> <server> <tool> <json>"
        return 1
    fi

    timeout "$timeout" bash -c "mcp_call '$server' '$tool' '$args'"
}

# ============================================================================
# UTILITY HELPERS
# ============================================================================

# Show all available helpers
mcp_help() {
    cat << 'EOF'
MCP CLI Helper Functions
========================

CORE HELPERS:
  mcp_search <pattern>              - Search tools across servers
  mcp_schema <server> <tool>        - Get tool JSON schema
  mcp_json key=val key2=val2        - Build JSON safely
  mcp_call <srv> <tool> <json>      - Call with error handling

CHAINING:
  mcp_chain "srv/tool" '{}' ...     - Chain multiple calls
  mcp_parallel "srv/tool:{}" ...    - Execute calls in parallel

TASK MASTER:
  tm_next                           - Get next task
  tm_get <id>                       - Get task by ID
  tm_list                           - List all tasks
  tm_add <title>                    - Add new task
  tm_done <id>                      - Mark task done

GITHUB:
  gh_search <query>                 - Search repositories
  gh_file <owner> <repo> <path>     - Get file contents
  gh_prs <owner> <repo>             - List pull requests

FILESYSTEM:
  fs_read <path>                    - Read file
  fs_write <path> <content>         - Write file
  fs_ls [path]                      - List directory
  fs_search <pattern> [path]        - Search files

MEMORY:
  mem_search <query>                - Search knowledge graph
  mem_create <name> <type> <obs>    - Create entity
  mem_graph                         - Read full graph

ERROR HANDLING:
  mcp_retry <srv> <tool> <json>     - Retry with backoff
  mcp_timeout <sec> <srv> <tool>    - Call with timeout

EXAMPLES:
  mcp_search "file"
  mcp_call filesystem read_file '{"path": "./README.md"}'
  mcp_json path="./file.txt" encoding="utf8"
  mcp_chain "task-master-ai/next_task" '{}' "task-master-ai/get_task" '.result.id'
  tm_add "Implement feature X"
  gh_search "mcp server typescript"

ENVIRONMENT:
  MCP_RETRY_MAX=3                   - Max retry attempts
  MCP_RETRY_DELAY=2                 - Base delay for backoff
EOF
}

# List all helper functions
mcp_functions() {
    echo "Available MCP helper functions:"
    declare -F | grep -E '^declare -f (mcp_|tm_|gh_|fs_|mem_)' | awk '{print "  " $3}'
}

# ============================================================================
# EXPORT FUNCTIONS (bash only - zsh handles functions differently)
# ============================================================================

if [[ -n "$BASH_VERSION" ]]; then
    export -f mcp_search 2>/dev/null
    export -f mcp_schema 2>/dev/null
    export -f mcp_json 2>/dev/null
    export -f mcp_call 2>/dev/null
    export -f mcp_chain 2>/dev/null
    export -f mcp_parallel 2>/dev/null
    export -f tm_next 2>/dev/null
    export -f tm_get 2>/dev/null
    export -f tm_list 2>/dev/null
    export -f tm_add 2>/dev/null
    export -f tm_done 2>/dev/null
    export -f gh_search 2>/dev/null
    export -f gh_file 2>/dev/null
    export -f gh_prs 2>/dev/null
    export -f fs_read 2>/dev/null
    export -f fs_write 2>/dev/null
    export -f fs_ls 2>/dev/null
    export -f fs_search 2>/dev/null
    export -f mem_search 2>/dev/null
    export -f mem_create 2>/dev/null
    export -f mem_graph 2>/dev/null
    export -f mcp_retry 2>/dev/null
    export -f mcp_timeout 2>/dev/null
    export -f mcp_help 2>/dev/null
    export -f mcp_functions 2>/dev/null
fi
