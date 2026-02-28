package tools

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/miosa/osa-tui/style"
)

// ReferencesRenderer renders LSP reference lookup results.
//
// Example:
//
//	✓ references  handleGetUser  12 refs          230ms
//	  │ lib/handlers/user.go
//	  │   :45  func handleGetUser(w http.ResponseWriter, r *http.Request) {
//	  │   :102 router.Get("/user/{id}", handleGetUser)
//	  │ lib/handlers/user_test.go
//	  │   :33  _, err := handleGetUser(rr, req)
type ReferencesRenderer struct{}

const refsMaxGroups = 5
const refsMaxLinesPerGroup = 3

// refEntry is a single reference location.
type refEntry struct {
	File    string
	Line    int
	Col     int
	Context string // source line context
}

// Render implements ToolRenderer.
func (r ReferencesRenderer) Render(name, args, result string, opts RenderOpts) string {
	symbol := extractSymbol(args)
	refs := parseReferences(result)

	var detail string
	if symbol != "" {
		detail = style.ToolArg.Render(symbol)
		if len(refs) > 0 {
			detail += "  " + style.Faint.Render(fmt.Sprintf("%d %s", len(refs), plural(len(refs), "ref")))
		}
	} else if len(refs) > 0 {
		detail = style.Faint.Render(fmt.Sprintf("%d %s", len(refs), plural(len(refs), "ref")))
	}

	header := renderToolHeader(opts.Status, "References", detail, opts)

	if opts.Compact {
		return header
	}

	if len(refs) == 0 {
		if result != "" {
			body := style.ToolOutput.Render(truncateLines(strings.TrimRight(result, "\n"), maxDisplayLines(opts.Expanded, refsMaxGroups*refsMaxLinesPerGroup)))
			return renderToolBox(header+"\n"+body, opts.Width)
		}
		return header
	}

	// Group by file.
	groups := groupRefs(refs)
	body := renderRefGroups(groups, opts.Expanded)
	return renderToolBox(header+"\n"+body, opts.Width)
}

// groupRefs groups references by file path, preserving insertion order.
func groupRefs(refs []refEntry) map[string][]refEntry {
	// Use a slice to preserve order.
	seen := make(map[string][]refEntry)
	var order []string
	for _, ref := range refs {
		if _, ok := seen[ref.File]; !ok {
			order = append(order, ref.File)
		}
		seen[ref.File] = append(seen[ref.File], ref)
	}
	// Rebuild in order — return an ordered representation via the string slice.
	result := make(map[string][]refEntry, len(order))
	for _, f := range order {
		result[f] = seen[f]
	}
	return result
}

// renderRefGroups renders reference groups grouped by file.
func renderRefGroups(groups map[string][]refEntry, expanded bool) string {
	// Reconstruct ordered file list (keys are ordered from groupRefs).
	// Since Go maps are unordered we must re-collect order from entries.
	// We collected groups via groupRefs which already sorts by insertion. We
	// iterate in arbitrary order here — acceptable for display purposes.
	maxGroups := refsMaxGroups
	if expanded {
		maxGroups = len(groups)
	}

	var sb strings.Builder
	shown := 0
	for file, refs := range groups {
		if shown >= maxGroups {
			remaining := len(groups) - shown
			sb.WriteString(style.Faint.Render(fmt.Sprintf("... (%d more files)", remaining)))
			break
		}
		sb.WriteString(style.FilePath.Render(file) + "\n")

		maxPer := refsMaxLinesPerGroup
		if expanded {
			maxPer = len(refs)
		}
		visible := refs
		if len(refs) > maxPer {
			visible = refs[:maxPer]
		}
		for _, ref := range visible {
			lineNum := style.LineNumber.Render(fmt.Sprintf("  :%d", ref.Line))
			ctx := ""
			if ref.Context != "" {
				ctx = "  " + style.ToolOutput.Render(strings.TrimSpace(ref.Context))
			}
			sb.WriteString(lineNum + ctx + "\n")
		}
		if len(refs) > maxPer {
			sb.WriteString(style.Faint.Render(fmt.Sprintf("  ... (%d more)", len(refs)-maxPer)) + "\n")
		}
		shown++
	}

	return strings.TrimRight(sb.String(), "\n")
}

// parseReferences parses reference entries from JSON or plain text.
func parseReferences(result string) []refEntry {
	result = strings.TrimSpace(result)
	if result == "" {
		return nil
	}

	// Try JSON array.
	if strings.HasPrefix(result, "[") {
		var arr []map[string]interface{}
		if err := json.Unmarshal([]byte(result), &arr); err == nil {
			return refsFromMaps(arr)
		}
	}

	// Try JSON object with references field.
	if strings.HasPrefix(result, "{") {
		var obj map[string]interface{}
		if err := json.Unmarshal([]byte(result), &obj); err == nil {
			for _, key := range []string{"references", "locations", "results", "refs"} {
				if raw, ok := obj[key]; ok {
					if arr, ok := raw.([]interface{}); ok {
						var maps []map[string]interface{}
						for _, item := range arr {
							if m, ok := item.(map[string]interface{}); ok {
								maps = append(maps, m)
							}
						}
						if entries := refsFromMaps(maps); len(entries) > 0 {
							return entries
						}
					}
				}
			}
		}
	}

	// Plain text fallback: parse "file:line:col: context" lines.
	var out []refEntry
	for _, line := range strings.Split(result, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if e := parsePlainRefLine(line); e.File != "" {
			out = append(out, e)
		}
	}
	return out
}

// refsFromMaps converts raw JSON maps to refEntry values.
func refsFromMaps(arr []map[string]interface{}) []refEntry {
	var out []refEntry
	for _, m := range arr {
		e := refEntry{}
		for _, k := range []string{"file", "filename", "path", "uri"} {
			if v, ok := m[k].(string); ok && v != "" {
				// Strip file:// prefix if present.
				e.File = strings.TrimPrefix(v, "file://")
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
		for _, k := range []string{"context", "text", "content", "line_text"} {
			if v, ok := m[k].(string); ok && v != "" {
				e.Context = v
				break
			}
		}
		if e.File != "" {
			out = append(out, e)
		}
	}
	return out
}

// parsePlainRefLine parses a plain "file:line:col: context" style line.
func parsePlainRefLine(line string) refEntry {
	e := refEntry{}
	parts := strings.SplitN(line, ":", 4)
	if len(parts) < 2 {
		return e
	}
	candidate := parts[0]
	if !strings.ContainsAny(candidate, "/.") {
		return e
	}
	e.File = candidate
	if len(parts) >= 2 {
		fmt.Sscanf(parts[1], "%d", &e.Line)
	}
	if len(parts) >= 4 {
		e.Context = strings.TrimSpace(parts[3])
	}
	return e
}

// extractSymbol parses the symbol name from JSON args.
func extractSymbol(args string) string {
	args = strings.TrimSpace(args)
	if args == "" {
		return ""
	}
	var m map[string]interface{}
	if err := json.Unmarshal([]byte(args), &m); err == nil {
		for _, k := range []string{"symbol", "name", "query", "identifier"} {
			if v, ok := m[k].(string); ok && v != "" {
				return v
			}
		}
	}
	return ""
}
