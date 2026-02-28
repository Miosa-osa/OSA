package tools

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/miosa/osa-tui/style"
)

// DiagnosticsRenderer renders diagnostic/linting tool results.
//
// Example:
//
//	✓ diagnostics  3 errors, 5 warnings          340ms
//	  │ ✘ lib/app.go:45: undefined: fooBar
//	  │ ⚠ lib/router.go:12: unused variable x
//	  │ ⚠ lib/router.go:30: deprecated function
type DiagnosticsRenderer struct{}

const diagMaxLines = 20

// diagSeverity classifies a diagnostic entry.
type diagSeverity int

const (
	diagError diagSeverity = iota
	diagWarning
	diagInfo
	diagHint
)

// diagEntry is a single parsed diagnostic item.
type diagEntry struct {
	File     string
	Line     int
	Col      int
	Message  string
	Severity diagSeverity
}

// Render implements ToolRenderer.
func (r DiagnosticsRenderer) Render(name, args, result string, opts RenderOpts) string {
	entries := parseDiagnostics(result)

	// Build header detail: "3 errors, 5 warnings".
	detail := buildDiagSummary(entries)
	header := renderToolHeader(opts.Status, "Diagnostics", detail, opts)

	if opts.Compact {
		return header
	}

	if len(entries) == 0 {
		if result != "" {
			body := style.ToolOutput.Render(truncateLines(strings.TrimRight(result, "\n"), maxDisplayLines(opts.Expanded, diagMaxLines)))
			return renderToolBox(header+"\n"+body, opts.Width)
		}
		return header
	}

	var sb strings.Builder
	cap := maxDisplayLines(opts.Expanded, diagMaxLines)
	visible := entries
	if len(entries) > cap {
		visible = entries[:cap]
	}

	for _, e := range visible {
		sb.WriteString(renderDiagEntry(e) + "\n")
	}
	if len(entries) > cap {
		sb.WriteString(style.Faint.Render(fmt.Sprintf("... (%d more)", len(entries)-cap)))
	}

	return renderToolBox(header+"\n"+strings.TrimRight(sb.String(), "\n"), opts.Width)
}

// buildDiagSummary returns a "3 errors, 5 warnings" style summary.
func buildDiagSummary(entries []diagEntry) string {
	var errors, warnings, infos int
	for _, e := range entries {
		switch e.Severity {
		case diagError:
			errors++
		case diagWarning:
			warnings++
		default:
			infos++
		}
	}

	var parts []string
	if errors > 0 {
		parts = append(parts, style.ErrorText.Render(fmt.Sprintf("%d %s", errors, plural(errors, "error"))))
	}
	if warnings > 0 {
		parts = append(parts, style.ToolStatusRunning.Render(fmt.Sprintf("%d %s", warnings, plural(warnings, "warning"))))
	}
	if infos > 0 {
		parts = append(parts, style.Faint.Render(fmt.Sprintf("%d %s", infos, plural(infos, "info"))))
	}
	if len(parts) == 0 && len(entries) > 0 {
		parts = append(parts, style.Faint.Render(fmt.Sprintf("%d issues", len(entries))))
	}
	return strings.Join(parts, ", ")
}

// renderDiagEntry renders a single diagnostic line.
func renderDiagEntry(e diagEntry) string {
	var icon string
	switch e.Severity {
	case diagError:
		icon = style.ErrorText.Render("✘")
	case diagWarning:
		icon = style.ToolStatusRunning.Render("⚠")
	case diagInfo:
		icon = style.Faint.Render("ℹ")
	default:
		icon = style.Faint.Render("·")
	}

	location := ""
	if e.File != "" {
		location = style.FilePath.Render(e.File)
		if e.Line > 0 {
			location += style.Faint.Render(fmt.Sprintf(":%d", e.Line))
			if e.Col > 0 {
				location += style.Faint.Render(fmt.Sprintf(":%d", e.Col))
			}
		}
		location += " "
	}

	return icon + " " + location + style.ToolOutput.Render(e.Message)
}

// parseDiagnostics parses diagnostic entries from JSON or plain text.
func parseDiagnostics(result string) []diagEntry {
	result = strings.TrimSpace(result)
	if result == "" {
		return nil
	}

	// Try JSON array.
	if strings.HasPrefix(result, "[") {
		var arr []map[string]interface{}
		if err := json.Unmarshal([]byte(result), &arr); err == nil {
			return diagsFromMaps(arr)
		}
	}

	// Try JSON object with diagnostics field.
	if strings.HasPrefix(result, "{") {
		var obj map[string]interface{}
		if err := json.Unmarshal([]byte(result), &obj); err == nil {
			for _, key := range []string{"diagnostics", "issues", "errors", "results"} {
				if raw, ok := obj[key]; ok {
					if arr, ok := raw.([]interface{}); ok {
						var maps []map[string]interface{}
						for _, item := range arr {
							if m, ok := item.(map[string]interface{}); ok {
								maps = append(maps, m)
							}
						}
						if entries := diagsFromMaps(maps); len(entries) > 0 {
							return entries
						}
					}
				}
			}
		}
	}

	// Plain text fallback: parse "file:line:col: message" lines.
	var out []diagEntry
	for _, line := range strings.Split(result, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		e := parsePlainDiagLine(line)
		if e.Message != "" {
			out = append(out, e)
		}
	}
	return out
}

// diagsFromMaps converts raw JSON maps to diagEntry values.
func diagsFromMaps(arr []map[string]interface{}) []diagEntry {
	var out []diagEntry
	for _, m := range arr {
		e := diagEntry{}

		for _, k := range []string{"file", "filename", "path", "source"} {
			if v, ok := m[k].(string); ok && v != "" {
				e.File = v
				break
			}
		}
		if v, ok := m["line"].(float64); ok {
			e.Line = int(v)
		}
		if v, ok := m["col"].(float64); ok {
			e.Col = int(v)
		} else if v, ok := m["column"].(float64); ok {
			e.Col = int(v)
		}

		for _, k := range []string{"message", "msg", "text", "description"} {
			if v, ok := m[k].(string); ok && v != "" {
				e.Message = v
				break
			}
		}

		sevStr, _ := m["severity"].(string)
		if sevStr == "" {
			sevStr, _ = m["level"].(string)
		}
		e.Severity = parseDiagSeverity(sevStr)

		if e.Message != "" {
			out = append(out, e)
		}
	}
	return out
}

// parsePlainDiagLine parses a plain text diagnostic line like:
// "lib/app.go:45:3: error: undefined: foo"
func parsePlainDiagLine(line string) diagEntry {
	e := diagEntry{Message: line, Severity: diagError}

	// Detect severity from keywords.
	lower := strings.ToLower(line)
	if strings.Contains(lower, "warning") || strings.Contains(lower, "warn") {
		e.Severity = diagWarning
	} else if strings.Contains(lower, "info") || strings.Contains(lower, "note") {
		e.Severity = diagInfo
	}

	// Try to parse "file:line:col: message".
	parts := strings.SplitN(line, ":", 4)
	if len(parts) >= 3 {
		candidate := parts[0]
		if strings.ContainsAny(candidate, "/.") {
			e.File = candidate
			var lineNo int
			if _, err := fmt.Sscanf(parts[1], "%d", &lineNo); err == nil {
				e.Line = lineNo
			}
			if len(parts) >= 4 {
				e.Message = strings.TrimSpace(parts[len(parts)-1])
			}
		}
	}

	return e
}

// parseDiagSeverity converts string to diagSeverity.
func parseDiagSeverity(s string) diagSeverity {
	switch strings.ToLower(s) {
	case "error", "err", "fatal", "critical":
		return diagError
	case "warning", "warn":
		return diagWarning
	case "info", "information":
		return diagInfo
	default:
		return diagHint
	}
}

// plural returns word with an "s" suffix when n != 1.
func plural(n int, word string) string {
	if n == 1 {
		return word
	}
	return word + "s"
}
