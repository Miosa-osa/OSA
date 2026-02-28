package tools

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/miosa/osa-tui/style"
)

// AgentRenderer renders nested agent/sub-agent tool invocations as a tree.
//
// Collapsed:
//
//	◈ Agent  summarise-codebase  3 tools, 1.7s
//
// Expanded:
//
//	◈ Agent  summarise-codebase
//	├─ ✓ Read   main.go           120ms
//	├─ ✓ Edit   router.go         340ms
//	└─ ✓ Bash   go build          1.2s
type AgentRenderer struct{}

const agentMaxTools = 20

// agentToolEntry represents a single tool invocation inside an agent result.
type agentToolEntry struct {
	Name       string
	Args       string
	Result     string
	Status     ToolStatus
	DurationMs int64
}

// Render implements ToolRenderer.
func (r AgentRenderer) Render(name, args, result string, opts RenderOpts) string {
	taskName := extractAgentTask(args)
	nestedTools := parseAgentTools(result)

	// Build summary for header / compact mode.
	var summaryParts []string
	if taskName != "" {
		summaryParts = append(summaryParts, taskName)
	}

	detail := strings.Join(summaryParts, " ")

	// Status icon: use a special ◈ for agents.
	agentIcon := style.PrefixActive.Render("◈")
	if opts.Status == ToolSuccess {
		agentIcon = style.PrefixDone.Render("◈")
	} else if opts.Status == ToolError {
		agentIcon = style.ErrorText.Render("◈")
	}

	nameStr := style.AgentName.Render("Agent")
	var dur string
	if opts.DurationMs > 0 {
		if opts.DurationMs < 1000 {
			dur = style.ToolDuration.Render(fmt.Sprintf("  %dms", opts.DurationMs))
		} else {
			dur = style.ToolDuration.Render(fmt.Sprintf("  %.1fs", float64(opts.DurationMs)/1000))
		}
	}

	header := agentIcon + " " + nameStr
	if detail != "" {
		header += "  " + style.ToolArg.Render(detail)
	}

	// Collapsed summary: show tool count + total duration inline.
	if opts.Compact || (!opts.Expanded && len(nestedTools) > 0) {
		summary := buildAgentSummary(nestedTools)
		if summary != "" {
			header += "  " + style.Faint.Render(summary)
		}
		header += dur
		return header
	}

	header += dur

	if len(nestedTools) == 0 {
		return header
	}

	// Expanded tree view.
	tree := buildAgentTree(nestedTools, opts.Width-4)
	return renderToolBox(header+"\n"+tree, opts.Width)
}

// buildAgentSummary builds a compact "3 tools, 1.7s" annotation.
func buildAgentSummary(tools []agentToolEntry) string {
	if len(tools) == 0 {
		return ""
	}
	var totalMs int64
	for _, t := range tools {
		totalMs += t.DurationMs
	}
	count := countLabel(len(tools), "tool")
	if totalMs > 0 {
		if totalMs < 1000 {
			return fmt.Sprintf("%s, %dms", count, totalMs)
		}
		return fmt.Sprintf("%s, %.1fs", count, float64(totalMs)/1000)
	}
	return count
}

// buildAgentTree renders the nested tools as a box-drawing tree.
func buildAgentTree(tools []agentToolEntry, width int) string {
	cap := agentMaxTools
	visible := tools
	if len(tools) > cap {
		visible = tools[:cap]
	}

	var sb strings.Builder
	last := len(visible) - 1

	for i, t := range visible {
		var connector string
		if i == last {
			connector = style.Connector.Render("└─ ")
		} else {
			connector = style.Connector.Render("├─ ")
		}

		icon := StatusIcon(t.Status)
		toolName := style.ToolName.Render(resolveTreeToolName(t.Name))
		detail := extractTreeDetail(t.Name, t.Args)

		var dur string
		if t.DurationMs > 0 {
			if t.DurationMs < 1000 {
				dur = style.ToolDuration.Render(fmt.Sprintf("  %dms", t.DurationMs))
			} else {
				dur = style.ToolDuration.Render(fmt.Sprintf("  %.1fs", float64(t.DurationMs)/1000))
			}
		}

		line := connector + icon + " " + toolName
		if detail != "" {
			line += "  " + style.ToolArg.Render(detail)
		}
		line += dur
		sb.WriteString(line + "\n")
	}

	if len(tools) > cap {
		sb.WriteString(style.Faint.Render(fmt.Sprintf("  ... (%d more tools)", len(tools)-cap)))
	}

	return strings.TrimRight(sb.String(), "\n")
}

// resolveTreeToolName returns a short display name for a nested tool.
func resolveTreeToolName(name string) string {
	switch {
	case name == "bash" || name == "Bash" || name == "run_bash_command":
		return "Bash"
	case name == "Read" || name == "read_file" || name == "file_read":
		return "Read"
	case name == "Write" || name == "write_file":
		return "Write"
	case name == "Edit" || name == "edit_file" || name == "str_replace_editor":
		return "Edit"
	case name == "Glob" || name == "glob":
		return "Glob"
	case name == "Grep" || name == "grep":
		return "Grep"
	case name == "LS" || name == "ls":
		return "LS"
	case name == "web_fetch" || name == "WebFetch" || name == "fetch":
		return "WebFetch"
	case name == "web_search" || name == "WebSearch":
		return "WebSearch"
	case name == "Task" || name == "agent" || name == "sub_agent":
		return "Agent"
	default:
		if len(name) > 16 {
			return name[:15] + "…"
		}
		return name
	}
}

// extractTreeDetail extracts a short detail string for inline tree display.
func extractTreeDetail(name, args string) string {
	args = strings.TrimSpace(args)
	if args == "" {
		return ""
	}
	switch {
	case name == "bash" || name == "Bash" || name == "run_bash_command":
		cmd := extractBashCommand(args)
		return truncateString(cmd, 30)
	case name == "Read" || name == "read_file" || name == "file_read",
		name == "Write" || name == "write_file",
		name == "Edit" || name == "edit_file" || name == "str_replace_editor":
		return truncateString(extractFilePath(args), 30)
	case name == "Grep" || name == "grep":
		return truncateString(extractSearchPattern(args), 30)
	case name == "Glob" || name == "glob":
		return truncateString(extractSearchPattern(args), 30)
	case name == "web_fetch" || name == "WebFetch" || name == "fetch":
		return truncateString(extractURL(args), 30)
	case name == "web_search" || name == "WebSearch":
		return truncateString(extractQuery(args), 30)
	}
	return ""
}

// extractAgentTask parses the task name/description from agent args.
func extractAgentTask(args string) string {
	args = strings.TrimSpace(args)
	if args == "" {
		return ""
	}
	var m map[string]interface{}
	if err := json.Unmarshal([]byte(args), &m); err == nil {
		for _, key := range []string{"task", "name", "description", "prompt", "query"} {
			if v, ok := m[key].(string); ok && v != "" {
				return truncateString(v, 40)
			}
		}
	}
	if len(args) > 40 {
		return args[:37] + "…"
	}
	return args
}

// parseAgentTools attempts to parse nested tool invocations from the agent result.
// Expected shapes:
//   - JSON array of tool objects: [{"name": "Read", "args": {...}, "result": "..."}]
//   - JSON object with "tool_calls" array.
//   - Plain text (returns empty slice).
func parseAgentTools(result string) []agentToolEntry {
	result = strings.TrimSpace(result)
	if result == "" {
		return nil
	}

	// Try direct array.
	if strings.HasPrefix(result, "[") {
		var arr []map[string]interface{}
		if err := json.Unmarshal([]byte(result), &arr); err == nil {
			return mapToEntries(arr)
		}
	}

	// Try object with nested arrays.
	if strings.HasPrefix(result, "{") {
		var obj map[string]interface{}
		if err := json.Unmarshal([]byte(result), &obj); err == nil {
			for _, key := range []string{"tool_calls", "tools", "steps", "actions"} {
				if raw, ok := obj[key]; ok {
					if arr, ok := raw.([]interface{}); ok {
						var maps []map[string]interface{}
						for _, item := range arr {
							if m, ok := item.(map[string]interface{}); ok {
								maps = append(maps, m)
							}
						}
						if entries := mapToEntries(maps); len(entries) > 0 {
							return entries
						}
					}
				}
			}
		}
	}

	return nil
}

// mapToEntries converts a slice of raw JSON maps to agentToolEntry values.
func mapToEntries(arr []map[string]interface{}) []agentToolEntry {
	var out []agentToolEntry
	for _, item := range arr {
		e := agentToolEntry{Status: ToolSuccess}

		for _, k := range []string{"name", "tool", "type"} {
			if v, ok := item[k].(string); ok && v != "" {
				e.Name = v
				break
			}
		}

		// Args may be a string or nested object.
		if v, ok := item["args"]; ok {
			switch vv := v.(type) {
			case string:
				e.Args = vv
			default:
				if b, err := json.Marshal(vv); err == nil {
					e.Args = string(b)
				}
			}
		}

		if v, ok := item["result"].(string); ok {
			e.Result = v
		}
		if v, ok := item["status"].(string); ok {
			switch v {
			case "error", "failed":
				e.Status = ToolError
			case "running":
				e.Status = ToolRunning
			case "canceled":
				e.Status = ToolCanceled
			}
		}
		if v, ok := item["duration_ms"].(float64); ok {
			e.DurationMs = int64(v)
		}

		if e.Name != "" {
			out = append(out, e)
		}
	}
	return out
}
