package tools

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/miosa/osa-tui/style"
)

// BashRenderer renders bash/shell tool invocations.
//
// Collapsed output (15 lines max):
//
//	✓ Bash  go build ./...                       2.3s
//	  │ ok  github.com/miosa/osa-tui
//
// Error output is highlighted in red. Background jobs show a job indicator.
type BashRenderer struct{}

const bashMaxLines = 15

// Render implements ToolRenderer.
func (r BashRenderer) Render(name, args, result string, opts RenderOpts) string {
	cmd := extractBashCommand(args)
	header := renderToolHeader(opts.Status, "Bash", cmd, opts)

	// Compact mode: header only.
	if opts.Compact {
		return header
	}

	// Awaiting permission: show pending content instead of output.
	if opts.Status == ToolAwaitingPermission {
		content := pendingToolContent("Bash")
		return renderToolBox(header+"\n"+content, opts.Width)
	}

	// Pending/running with no output yet.
	if result == "" {
		if opts.Status == ToolRunning && cmd != "" {
			// Show the command preview while running.
			preview := style.Faint.Render("$ " + cmd)
			return renderToolBox(header+"\n"+preview, opts.Width)
		}
		return header
	}

	output := strings.TrimRight(result, "\n")

	// Detect background job.
	bg := isBackgroundJob(args)
	pid := extractPID(result)

	var body strings.Builder

	// Job indicator for background tasks.
	if bg {
		jobLine := style.ToolStatusRunning.Render("⚙ background job")
		if pid != "" {
			jobLine += style.Faint.Render(fmt.Sprintf("  pid=%s", pid))
		}
		body.WriteString(jobLine + "\n")
	}

	// Main output block.
	cap := maxDisplayLines(opts.Expanded, bashMaxLines)
	if opts.Status == ToolError {
		body.WriteString(style.ErrorText.Render(truncateLines(output, cap)))
	} else {
		body.WriteString(style.ToolOutput.Render(truncateLines(output, cap)))
	}

	return renderToolBox(header+"\n"+body.String(), opts.Width)
}

// extractBashCommand parses the command string from JSON args.
// Keys checked: "command", "cmd", "input". Falls back to the raw args string.
func extractBashCommand(args string) string {
	args = strings.TrimSpace(args)
	if args == "" {
		return ""
	}

	var m map[string]interface{}
	if err := json.Unmarshal([]byte(args), &m); err == nil {
		for _, key := range []string{"command", "cmd", "input"} {
			if v, ok := m[key]; ok {
				if s, ok := v.(string); ok {
					return strings.TrimSpace(s)
				}
			}
		}
	}

	// Raw string fallback — strip surrounding quotes if present.
	if len(args) > 1 && args[0] == '"' && args[len(args)-1] == '"' {
		return args[1 : len(args)-1]
	}
	return args
}

// isBackgroundJob returns true when the args JSON contains run_in_background=true.
func isBackgroundJob(args string) bool {
	args = strings.TrimSpace(args)
	if args == "" {
		return false
	}
	var m map[string]interface{}
	if err := json.Unmarshal([]byte(args), &m); err != nil {
		return false
	}
	if v, ok := m["run_in_background"]; ok {
		if b, ok := v.(bool); ok {
			return b
		}
	}
	return false
}

// extractPID looks for a PID in the result text.
// Expects patterns like "pid=1234" or "PID: 1234" or "Job 1 (PID 1234)".
func extractPID(result string) string {
	lower := strings.ToLower(result)
	for _, prefix := range []string{"pid=", "pid: ", "pid:"} {
		if idx := strings.Index(lower, prefix); idx >= 0 {
			rest := result[idx+len(prefix):]
			rest = strings.TrimSpace(rest)
			end := strings.IndexAny(rest, " \t\n)")
			if end < 0 {
				end = len(rest)
			}
			candidate := rest[:end]
			if len(candidate) > 0 && len(candidate) <= 8 {
				return candidate
			}
		}
	}
	return ""
}
