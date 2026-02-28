package tools

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/miosa/osa-tui/style"
)

// MCPRenderer renders MCP (Model Context Protocol) tool invocations.
//
// Example:
//
//	✓ [filesystem] → read_file                  45ms
//	  │ /Users/rhl/project/main.go (1.2KB)
type MCPRenderer struct{}

const mcpMaxLines = 15

// Render implements ToolRenderer.
func (r MCPRenderer) Render(name, args, result string, opts RenderOpts) string {
	server, tool := extractMCPServerTool(name, args)
	displayName, detail := buildMCPHeader(name, server, tool)

	header := renderToolHeader(opts.Status, displayName, detail, opts)

	if result == "" {
		return header
	}

	preview := truncateLines(strings.TrimRight(result, "\n"), maxDisplayLines(opts.Expanded, mcpMaxLines))
	body := style.ToolOutput.Render(preview)
	return renderToolBox(header+"\n"+body, opts.Width)
}

// buildMCPHeader produces the display name and detail for the header line.
//
// When server and tool are both known:    displayName="[filesystem]", detail="→ read_file"
// When only server is known:             displayName="[filesystem]", detail=""
// When neither is known:                 displayName=name, detail=""
func buildMCPHeader(rawName, server, tool string) (displayName, detail string) {
	if server != "" && tool != "" {
		displayName = fmt.Sprintf("[%s]", server)
		detail = fmt.Sprintf("→ %s", tool)
		return
	}
	if server != "" {
		displayName = fmt.Sprintf("[%s]", server)
		return
	}
	displayName = style.ToolName.Render(rawName)
	return
}

// extractMCPServerTool resolves the server and tool name from the invocation.
//
// Resolution order:
//  1. mcp__<server>__<tool> naming convention (Claude Code style)
//  2. JSON args fields "server" and "tool"
func extractMCPServerTool(name, args string) (server, tool string) {
	// Pattern: mcp__filesystem__read_file → server=filesystem, tool=read_file
	parts := strings.Split(name, "__")
	if len(parts) == 3 && strings.ToLower(parts[0]) == "mcp" {
		return parts[1], parts[2]
	}

	// Try JSON args for explicit server / tool fields.
	args = strings.TrimSpace(args)
	if args != "" {
		var m map[string]interface{}
		if err := json.Unmarshal([]byte(args), &m); err == nil {
			s, _ := m["server"].(string)
			t, _ := m["tool"].(string)
			if s != "" || t != "" {
				return s, t
			}
		}
	}

	return "", ""
}
