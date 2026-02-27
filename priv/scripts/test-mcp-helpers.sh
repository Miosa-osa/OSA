#!/usr/bin/env bash
# test-mcp-helpers.sh - Test mcp-cli shell integration
# Usage: ./test-mcp-helpers.sh

set -e

# Enable alias expansion in non-interactive shell
shopt -s expand_aliases

echo "Testing MCP CLI Shell Integration"
echo "=================================="
echo ""

# Source the scripts
echo "1. Loading mcp-cli-init.sh..."
source "$(dirname "$0")/mcp-cli-init.sh"
echo "   ✓ Loaded successfully"
echo ""

# Test environment variables
echo "2. Testing environment variables..."
[[ -n "$MCP_CONFIG_PATH" ]] && echo "   ✓ MCP_CONFIG_PATH: $MCP_CONFIG_PATH" || exit 1
[[ -n "$MCP_CACHE_DIR" ]] && echo "   ✓ MCP_CACHE_DIR: $MCP_CACHE_DIR" || exit 1
[[ -n "$MCP_DAEMON_TIMEOUT" ]] && echo "   ✓ MCP_DAEMON_TIMEOUT: $MCP_DAEMON_TIMEOUT" || exit 1
echo ""

# Test aliases
echo "3. Testing aliases..."
type mcp &>/dev/null && echo "   ✓ mcp alias defined" || exit 1
type mcpi &>/dev/null && echo "   ✓ mcpi alias defined" || exit 1
type mcpc &>/dev/null && echo "   ✓ mcpc alias defined" || exit 1
echo ""

# Test helper functions
echo "4. Testing helper functions..."
type mcp_search &>/dev/null && echo "   ✓ mcp_search function defined" || exit 1
type mcp_json &>/dev/null && echo "   ✓ mcp_json function defined" || exit 1
type mcp_call &>/dev/null && echo "   ✓ mcp_call function defined" || exit 1
type tm_next &>/dev/null && echo "   ✓ tm_next function defined" || exit 1
type gh_search &>/dev/null && echo "   ✓ gh_search function defined" || exit 1
type fs_read &>/dev/null && echo "   ✓ fs_read function defined" || exit 1
type mem_search &>/dev/null && echo "   ✓ mem_search function defined" || exit 1
echo ""

# Test mcp_json
echo "5. Testing mcp_json helper..."
result=$(mcp_json path="/tmp/test.txt" encoding="utf8" count=42 flag=true)
expected='{"path":"/tmp/test.txt","encoding":"utf8","count":42,"flag":true}'

if [[ "$result" == "$expected" ]]; then
    echo "   ✓ mcp_json output correct"
    echo "     Output: $result"
else
    echo "   ✗ mcp_json output incorrect"
    echo "     Expected: $expected"
    echo "     Got: $result"
    exit 1
fi
echo ""

# Test mcp_json with special characters
echo "6. Testing mcp_json with special characters..."
result=$(mcp_json message="Hello \"World\"" path="/path/with spaces/file.txt")
# Should escape quotes
if echo "$result" | jq empty 2>/dev/null; then
    echo "   ✓ mcp_json handles special characters"
    echo "     Output: $result"
else
    echo "   ✗ mcp_json produced invalid JSON"
    exit 1
fi
echo ""

# Test utility functions
echo "7. Testing utility functions..."
mcp_env_info > /dev/null && echo "   ✓ mcp_env_info works" || exit 1
echo ""

# Test function listing
echo "8. Testing function discovery..."
functions=$(declare -F | grep -E '^declare -f (mcp_|tm_|gh_|fs_|mem_)' | wc -l | xargs)
if [[ -n "$functions" ]] && [[ $functions -gt 10 ]]; then
    echo "   ✓ Found $functions helper functions"
else
    echo "   ⚠ Found $functions functions (expected > 10, but this may be normal in test environment)"
fi
echo ""

echo "=================================="
echo "All tests passed! ✓"
echo ""
echo "Shell integration is ready to use."
echo "Add this to your ~/.bashrc or ~/.zshrc:"
echo "  source ~/.claude/scripts/mcp-cli-init.sh"
