---
name: mcp-cli
description: "Dynamic MCP server discovery and tool execution via CLI. Reduces token usage by 99% compared to static MCP loading. Use for all MCP server interactions."
user-invocable: false
disable-model-invocation: false
---

# MCP-CLI - Dynamic MCP Discovery

Access MCP servers through the command line with **dynamic discovery** - only load tool schemas when needed, reducing token usage from ~47,000 to ~400 tokens.

## Commands

| Command | Output |
|---------|--------|
| `mcp-cli` | List all servers and tool names |
| `mcp-cli info <server>` | Show tools with parameters |
| `mcp-cli info <server> <tool>` | Get tool JSON schema |
| `mcp-cli grep "<pattern>"` | Search tools by name |
| `mcp-cli call <server> <tool> '{}'` | Call tool with arguments |

**Both formats work:** `info <server> <tool>` or `info <server>/<tool>`

**Add `-d` to include descriptions** (e.g., `mcp-cli info filesystem -d`)

## Workflow

1. **Discover**: `mcp-cli` → see available servers and tools
2. **Explore**: `mcp-cli info <server>` → see tools with parameters
3. **Inspect**: `mcp-cli info <server> <tool>` → get full JSON input schema
4. **Execute**: `mcp-cli call <server> <tool> '{}'` → run with arguments

## Available MCP Servers

```
task-master-ai   - Task management, dependencies, autopilot (64 tools)
github           - PRs, issues, commits, branches (28 tools)
playwright       - Browser automation, E2E testing (25 tools)
claude-in-chrome - Chrome automation, debugging (17 tools)
filesystem       - File operations (15 tools)
memory           - Knowledge graph, entities (12 tools)
greptile         - Code review, PR comments (12 tools)
git              - Git operations (12 tools)
context7         - Documentation queries (2 tools)
claude-flow      - Agent orchestration, swarms (199 tools)
```

## Examples

```bash
# List all servers and tool names
mcp-cli

# See all tools with parameters
mcp-cli info filesystem

# With descriptions (more verbose)
mcp-cli info filesystem -d

# Get JSON schema for specific tool
mcp-cli info filesystem read_file

# Call the tool
mcp-cli call filesystem read_file '{"path": "./README.md"}'

# Search for tools
mcp-cli grep "*file*"

# GitHub: Search repositories
mcp-cli call github search_repositories '{"query": "mcp server"}'

# Task Master: Get next task
mcp-cli call task-master-ai next_task '{}'

# Memory: Search knowledge graph
mcp-cli call memory search_nodes '{"query": "authentication patterns"}'

# Playwright: Take screenshot
mcp-cli call playwright browser_take_screenshot '{"name": "test.png"}'
```

## Complex JSON Patterns

```bash
# Heredoc for complex JSON with quotes
mcp-cli call server tool <<EOF
{"content": "Text with 'quotes' inside"}
EOF

# Pipe from a file/command
cat args.json | mcp-cli call server tool

# Chain: search and read first result
mcp-cli call filesystem search_files '{"path": "src/", "pattern": "*.ts"}' \
  | jq -r '.content[0].text | split("\n")[0]' \
  | xargs -I {} mcp-cli call filesystem read_file '{"path": "{}"}'

# Build JSON with jq
jq -n '{query: "mcp", filters: ["active"]}' | mcp-cli call github search
```

## Options

| Flag | Purpose |
|------|---------|
| `-d` | Include descriptions |
| `-c <path>` | Custom config file path |

## Exit Codes

- `0`: Success
- `1`: Client error (bad args, missing config)
- `2`: Server error (tool failed)
- `3`: Network error

## When to Use mcp-cli vs Native MCP

**Use mcp-cli when:**
- You need to discover what tools are available
- You want to inspect a tool's schema before calling it
- You're chaining multiple MCP calls in a bash pipeline
- You need dynamic, just-in-time tool loading

**Use native MCP tools when:**
- You already know the exact tool and parameters
- The tool is frequently used and schema is memorized
- You need streaming responses

## Integration with Agents

All agents can use mcp-cli for MCP interactions. The dynamic discovery pattern:

1. **Memory check**: `/mem-search <topic>` first
2. **Tool discovery**: `mcp-cli grep "*keyword*"`
3. **Schema inspection**: `mcp-cli info server tool`
4. **Execution**: `mcp-cli call server tool '{params}'`

This ensures minimal token usage while maintaining full MCP capability.

## Shell Integration

Load helper functions and environment:

```bash
# In ~/.bashrc or ~/.zshrc
source ~/.osa/scripts/mcp-cli-init.sh
```

### Helper Functions

The shell integration provides convenient wrappers for common patterns:

#### Core Helpers

```bash
# Search tools across all servers
mcp_search "file"

# Get tool schema with validation
mcp_schema filesystem read_file

# Build JSON safely (handles quoting/escaping)
mcp_json path="/tmp/file.txt" encoding="utf8"
# Output: {"path":"/tmp/file.txt","encoding":"utf8"}

# Call with error handling
mcp_call filesystem read_file '{"path": "./README.md"}'
```

#### Chaining Patterns

```bash
# Chain multiple calls (result passing)
mcp_chain \
  "task-master-ai/next_task" '{}' \
  "task-master-ai/get_task" '.result.id'

# Parallel execution (background jobs)
mcp_parallel \
  "github/search_repositories:{\"query\":\"mcp\"}" \
  "memory/search_nodes:{\"query\":\"authentication\"}" \
  "filesystem/list_directory:{\"path\":\".\"}"
```

#### Domain-Specific Helpers

```bash
# Task Master shortcuts
tm_next                    # Get next task
tm_get 42                  # Get task by ID
tm_list                    # List all tasks
tm_add "New feature"       # Add task
tm_done 42                 # Mark done

# GitHub shortcuts
gh_search "typescript mcp"
gh_file owner repo path/to/file.ts
gh_prs owner repo

# Filesystem shortcuts
fs_read "./config.json"
fs_write "./output.txt" "content"
fs_ls "./src"
fs_search "*.ts" "./src"

# Memory shortcuts
mem_search "authentication patterns"
mem_create "JWT" "pattern" "Use httpOnly cookies"
mem_graph
```

#### Error Handling

```bash
# Retry with exponential backoff (default: 3 attempts)
mcp_retry filesystem read_file '{"path": "./file.txt"}'

# With custom retry settings
MCP_RETRY_MAX=5 MCP_RETRY_DELAY=3 \
  mcp_retry github search_repositories '{"query": "mcp"}'

# Timeout wrapper
mcp_timeout 10 filesystem search_files '{"pattern": "*.ts", "path": "."}'
```

### Environment Variables

```bash
MCP_DAEMON_TIMEOUT=30000   # Daemon timeout (ms)
MCP_CONCURRENCY=10         # Max concurrent connections
MCP_CONFIG_PATH=~/.osa/mcp.json
MCP_DEBUG=false            # Enable verbose logging
MCP_CACHE_DIR=~/.cache/mcp-cli
MCP_CACHE_TTL=300          # Cache TTL (seconds)
MCP_RETRY_MAX=3            # Max retry attempts
MCP_RETRY_DELAY=2          # Base delay for backoff
```

### Aliases

```bash
mcp                        # mcp-cli
mcpi <server>              # mcp-cli info <server>
mcpc <server> <tool>       # mcp-cli call <server> <tool>
mcpgrep <pattern>          # mcp-cli grep <pattern>

# Server shortcuts
mcptm                      # mcp-cli info task-master-ai
mcpgh                      # mcp-cli info github
mcpfs                      # mcp-cli info filesystem
mcpmem                     # mcp-cli info memory
mcpgit                     # mcp-cli info git
```

### Utility Commands

```bash
mcp_env_info               # Show environment settings
mcp_clear_cache            # Clear cached results
mcp_debug_on               # Enable debug mode
mcp_debug_off              # Disable debug mode
mcp_help                   # Show all helper functions
mcp_functions              # List available functions
```

## Advanced Patterns

### Pipeline Integration

```bash
# Chain with jq
mcp_call task-master-ai get_tasks '{}' | jq -r '.tasks[] | select(.status=="pending") | .id'

# Iterate over results
mcp_call filesystem list_directory '{"path": "./src"}' \
  | jq -r '.files[]' \
  | while read -r file; do
      mcp_call filesystem read_file "{\"path\":\"$file\"}"
    done

# Combine with standard tools
mcp_call github search_repositories '{"query": "mcp typescript"}' \
  | jq -r '.items[].html_url' \
  | head -5
```

### Error Recovery

```bash
# Graceful fallback
if ! mcp_call memory search_nodes '{"query": "pattern"}'; then
    echo "Memory search failed, trying local search..."
    grep -r "pattern" ./docs/
fi

# Conditional execution
mcp_call task-master-ai next_task '{}' \
  && echo "Task found" \
  || echo "No tasks available"
```

### Batch Operations

```bash
# Process multiple files
for file in src/**/*.ts; do
    echo "Processing $file..."
    mcp_call filesystem read_file "{\"path\":\"$file\"}" \
      | jq -r '.content' \
      | grep -q "TODO" \
      && echo "  Found TODOs in $file"
done

# Parallel batch processing
find src -name "*.ts" | xargs -P 4 -I {} bash -c '
    mcp_call filesystem read_file "{\"path\":\"{}\"}"
'
```

### Complex Chaining

```bash
# Multi-stage pipeline
TASK_ID=$(mcp_call task-master-ai next_task '{}' | jq -r '.id')
TASK_DETAILS=$(mcp_call task-master-ai get_task "{\"id\":\"$TASK_ID\"}")
FILES=$(echo "$TASK_DETAILS" | jq -r '.files[]')

for file in $FILES; do
    mcp_call filesystem read_file "{\"path\":\"$file\"}"
done

# Result aggregation
{
    mcp_call memory search_nodes '{"query": "patterns"}' &
    mcp_call github search_code '{"query": "authentication"}' &
    mcp_call filesystem search_files '{"pattern": "auth*"}' &
    wait
} | jq -s 'add'
```

### Safe JSON Construction

```bash
# Using mcp_json helper (handles escaping)
path="/path/with spaces/file.txt"
query="value with 'quotes'"
mcp_call filesystem read_file "$(mcp_json path="$path")"
mcp_call github search_repositories "$(mcp_json query="$query")"

# Using jq for complex structures
jq -n \
  --arg path "$path" \
  --arg query "$query" \
  '{path: $path, query: $query}' \
  | mcp_call server tool

# Heredoc for readability
mcp_call github create_issue <<'EOF'
{
  "owner": "username",
  "repo": "project",
  "title": "Bug Report",
  "body": "Description with\nmultiple lines"
}
EOF
```
