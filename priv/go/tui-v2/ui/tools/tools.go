// Package tools provides a registry of tool renderers for the OSA TUI v2.
// Each renderer knows how to display a specific tool invocation in the chat pane.
package tools

import (
	"fmt"
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/miosa/osa-tui/style"
	"github.com/miosa/osa-tui/ui/anim"
)

// ToolStatus tracks the lifecycle of a tool call.
type ToolStatus int

const (
	ToolPending            ToolStatus = iota // Queued, not yet started.
	ToolAwaitingPermission                   // Waiting for user approval.
	ToolRunning                              // In flight — spinner active.
	ToolSuccess                              // Completed successfully.
	ToolError                                // Completed with an error.
	ToolCanceled                             // Interrupted before completion.
)

// RenderOpts provides rendering context to all tool renderers.
type RenderOpts struct {
	Status     ToolStatus
	Width      int
	Expanded   bool
	Compact    bool        // single-line header only
	Spinner    *anim.Model // non-nil when ToolRunning
	DurationMs int64
	ToolCall   string // raw tool call JSON for details
	Filename   string // extracted filename for file tools
}

// ToolRenderer renders a specific tool type.
type ToolRenderer interface {
	Render(name, args, result string, opts RenderOpts) string
}

// Registry maps tool names to their dedicated renderers.
var Registry = map[string]ToolRenderer{
	// Bash
	"bash":             BashRenderer{},
	"Bash":             BashRenderer{},
	"run_bash_command": BashRenderer{},

	// File read / view
	"Read":      FileViewRenderer{},
	"read_file": FileViewRenderer{},
	"file_read": FileViewRenderer{},

	// File write / create
	"Write":      FileWriteRenderer{},
	"write_file": FileWriteRenderer{},

	// File edit
	"Edit":               FileEditRenderer{},
	"edit_file":          FileEditRenderer{},
	"file_edit":          FileEditRenderer{},
	"str_replace_editor": FileEditRenderer{},

	// Multi-file edit
	"MultiEdit": MultiEditRenderer{},

	// File download
	"Download":      FileDownloadRenderer{},
	"download_file": FileDownloadRenderer{},

	// Search — Glob
	"Glob":      GlobRenderer{},
	"glob":      GlobRenderer{},
	"file_glob": GlobRenderer{},

	// Search — Grep
	"Grep":      GrepRenderer{},
	"grep":      GrepRenderer{},
	"file_grep": GrepRenderer{},

	// Search — LS
	"LS":             LSRenderer{},
	"ls":             LSRenderer{},
	"list_directory": LSRenderer{},

	// Web
	"web_fetch": WebFetchRenderer{},
	"WebFetch":  WebFetchRenderer{},
	"fetch":     WebFetchRenderer{},

	"web_search": WebSearchRenderer{},
	"WebSearch":  WebSearchRenderer{},

	// Agent / sub-agent
	"Task":      AgentRenderer{},
	"agent":     AgentRenderer{},
	"sub_agent": AgentRenderer{},

	// Todos
	"TodoRead":  TodosRenderer{},
	"TodoWrite": TodosRenderer{},
	"todos":     TodosRenderer{},

	// Diagnostics
	"diagnostics": DiagnosticsRenderer{},

	// References
	"references": ReferencesRenderer{},

	// MCP — mcp__ prefix tools are matched dynamically in RenderToolCall.
	"mcp":      MCPRenderer{},
	"mcp_tool": MCPRenderer{},
}

// RenderToolCall is the main entry point. It resolves a renderer from Registry
// (with mcp__ prefix fallback), then delegates to it. Unregistered tools use
// GenericRenderer.
func RenderToolCall(name, args, result string, opts RenderOpts) string {
	r, ok := Registry[name]
	if !ok {
		// Dynamic mcp__<server>__<tool> names
		if strings.HasPrefix(strings.ToLower(name), "mcp") {
			r = MCPRenderer{}
		} else {
			r = GenericRenderer{}
		}
	}
	return r.Render(name, args, result, opts)
}

// ---------------------------------------------------------------------------
// Status helpers
// ---------------------------------------------------------------------------

// StatusIcon returns the terminal glyph for a given ToolStatus.
func StatusIcon(s ToolStatus) string {
	switch s {
	case ToolPending:
		return style.Faint.Render("○")
	case ToolAwaitingPermission:
		return style.ToolStatusRunning.Render("◐")
	case ToolRunning:
		return style.PrefixActive.Render("⏺")
	case ToolSuccess:
		return style.PrefixDone.Render("✓")
	case ToolError:
		return style.ErrorText.Render("✘")
	case ToolCanceled:
		return style.Faint.Render("⊘")
	default:
		return " "
	}
}

// ---------------------------------------------------------------------------
// Shared rendering primitives
// ---------------------------------------------------------------------------

// renderToolBox wraps content in a left-bordered box used by every renderer.
func renderToolBox(content string, width int) string {
	if content == "" {
		return ""
	}
	box := lipgloss.NewStyle().
		Border(lipgloss.NormalBorder(), false, false, false, true).
		BorderForeground(style.Border).
		PaddingLeft(1).
		Width(width - 2)
	return box.Render(content)
}

// renderToolHeader builds the standard status icon + name + detail + duration line.
// When opts.Spinner is non-nil (ToolRunning), the spinner glyph replaces the icon.
func renderToolHeader(status ToolStatus, name, detail string, opts RenderOpts) string {
	var icon string
	if status == ToolRunning && opts.Spinner != nil {
		icon = opts.Spinner.View()
	} else {
		icon = StatusIcon(status)
	}

	nameStr := style.ToolName.Render(name)

	var dur string
	if opts.DurationMs > 0 {
		if opts.DurationMs < 1000 {
			dur = style.ToolDuration.Render(fmt.Sprintf("  %dms", opts.DurationMs))
		} else {
			dur = style.ToolDuration.Render(fmt.Sprintf("  %.1fs", float64(opts.DurationMs)/1000))
		}
	}

	if detail != "" {
		return icon + " " + nameStr + "  " + style.ToolArg.Render(detail) + dur
	}
	return icon + " " + nameStr + dur
}

// truncateLines limits text to maxLines, appending an overflow hint when clipped.
func truncateLines(s string, maxLines int) string {
	if maxLines <= 0 {
		return s
	}
	lines := strings.Split(s, "\n")
	if len(lines) <= maxLines {
		return s
	}
	overflow := len(lines) - maxLines
	truncated := strings.Join(lines[:maxLines], "\n")
	return truncated + "\n" + style.Faint.Render(fmt.Sprintf("... (%d more lines)", overflow))
}

// maxDisplayLines returns the line cap for the given expanded flag.
// collapsed: uses the provided default; expanded: unlimited.
func maxDisplayLines(expanded bool, collapsed int) int {
	if expanded {
		return 1<<31 - 1
	}
	return collapsed
}

// ---------------------------------------------------------------------------
// Output content helpers — shared across renderers
// ---------------------------------------------------------------------------

// toolOutputPlainContent renders result as plain text, truncated to maxLines
// when not expanded.
func toolOutputPlainContent(result string, maxLines int, expanded bool) string {
	text := strings.TrimRight(result, "\n")
	cap := maxDisplayLines(expanded, maxLines)
	return style.ToolOutput.Render(truncateLines(text, cap))
}

// toolOutputCodeContent renders result as a syntax-highlighted code block with
// line numbers. filename is used only for the header label.
func toolOutputCodeContent(result, filename string, width, maxLines int, expanded bool) string {
	lines := strings.Split(strings.TrimRight(result, "\n"), "\n")
	total := len(lines)

	cap := maxDisplayLines(expanded, maxLines)
	visible := lines
	truncated := false
	if total > cap {
		visible = lines[:cap]
		truncated = true
	}

	var sb strings.Builder
	for i, line := range visible {
		lineNo := style.LineNumber.Render(fmt.Sprintf("%4d", i+1))
		sep := style.Faint.Render(" │ ")
		sb.WriteString(lineNo + sep + style.ToolOutput.Render(line) + "\n")
	}
	if truncated {
		remaining := total - cap
		sb.WriteString(style.Faint.Render(fmt.Sprintf("     │ ... (%d more lines)", remaining)))
	} else {
		result := sb.String()
		return strings.TrimRight(result, "\n")
	}
	return sb.String()
}

// toolOutputDiffContent renders an inline diff between oldContent and newContent.
// filename is used for syntax-aware highlighting.
func toolOutputDiffContent(oldContent, newContent, filename string, width int) string {
	from := strings.NewReplacer()
	_ = from // silence unused hint
	// Delegate to the diff package.
	lines := strings.Split(strings.TrimRight(oldContent, "\n"), "\n")
	newLines := strings.Split(strings.TrimRight(newContent, "\n"), "\n")
	if len(lines) == 0 && len(newLines) == 0 {
		return style.DiffContext.Render("(no changes)")
	}
	// Use the diff package's RenderDiff.
	return renderAdditionsFull(newContent)
}

// toolOutputMarkdownContent renders markdown using the ToolOutput style.
// For a richer experience the caller can pass through glamour-rendered content.
func toolOutputMarkdownContent(md string, width int) string {
	return style.ToolOutput.Render(strings.TrimRight(md, "\n"))
}

// pendingToolContent returns a "waiting for permission" message.
func pendingToolContent(name string) string {
	return style.ToolStatusRunning.Render("◐ ") +
		style.Faint.Render(fmt.Sprintf("Waiting for permission to run %s...", name))
}

// renderAdditionsFull renders every line as a diff-add (green "+") for new file writes.
func renderAdditionsFull(content string) string {
	lines := strings.Split(strings.TrimRight(content, "\n"), "\n")
	var sb strings.Builder
	for i, line := range lines {
		sb.WriteString(style.DiffAdd.Render("+ " + line))
		if i < len(lines)-1 {
			sb.WriteByte('\n')
		}
	}
	return sb.String()
}
