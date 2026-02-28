package tools

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/miosa/osa-tui/style"
)

// ---------------------------------------------------------------------------
// GlobRenderer
// ---------------------------------------------------------------------------

// GlobRenderer renders glob/file-find tool invocations.
//
// Example:
//
//	✓ Glob  **/*.go                              312ms
//	  │ lib/app.go
//	  │ lib/router.go
//	  │ (12 files)
type GlobRenderer struct{}

const globMaxLines = 15

// Render implements ToolRenderer.
func (r GlobRenderer) Render(name, args, result string, opts RenderOpts) string {
	pattern := extractSearchPattern(args)
	header := renderToolHeader(opts.Status, "Glob", pattern, opts)

	if opts.Compact {
		return header
	}

	if result == "" {
		return header
	}

	body := renderGlobResults(result, maxDisplayLines(opts.Expanded, globMaxLines))
	return renderToolBox(header+"\n"+body, opts.Width)
}

// renderGlobResults formats a list of file paths from glob output.
func renderGlobResults(result string, maxLines int) string {
	lines := strings.Split(strings.TrimRight(result, "\n"), "\n")
	// Filter empty lines.
	var files []string
	for _, l := range lines {
		if strings.TrimSpace(l) != "" {
			files = append(files, l)
		}
	}
	total := len(files)

	visible := files
	if total > maxLines {
		visible = files[:maxLines]
	}

	var sb strings.Builder
	for _, f := range visible {
		sb.WriteString(style.FilePath.Render(strings.TrimSpace(f)) + "\n")
	}

	if total > maxLines {
		sb.WriteString(style.Faint.Render(fmt.Sprintf("... (%d more files)", total-maxLines)))
	} else {
		sb.WriteString(style.Faint.Render(fmt.Sprintf("(%d files)", total)))
	}

	return sb.String()
}

// ---------------------------------------------------------------------------
// GrepRenderer
// ---------------------------------------------------------------------------

// GrepRenderer renders grep/search tool invocations.
//
// Example:
//
//	✓ Grep  pattern="TODO" path="lib/"          312ms
//	  │ lib/app.ex:45: # TODO: fix this
//	  │ lib/utils.ex:12: # TODO: refactor
//	  │ (3 results)
type GrepRenderer struct{}

const grepMaxLines = 15

// Render implements ToolRenderer.
func (r GrepRenderer) Render(name, args, result string, opts RenderOpts) string {
	detail := buildGrepDetail(args)
	header := renderToolHeader(opts.Status, "Grep", detail, opts)

	if opts.Compact {
		return header
	}

	if result == "" {
		return header
	}

	body := renderGrepResults(result, maxDisplayLines(opts.Expanded, grepMaxLines))
	return renderToolBox(header+"\n"+body, opts.Width)
}

// buildGrepDetail extracts key parameters from args to display in the header.
func buildGrepDetail(args string) string {
	args = strings.TrimSpace(args)
	if args == "" {
		return ""
	}

	var m map[string]interface{}
	if err := json.Unmarshal([]byte(args), &m); err != nil {
		if len(args) > 60 {
			return args[:57] + "…"
		}
		return args
	}

	var parts []string
	for _, key := range []string{"pattern", "query", "regex", "glob"} {
		if v, ok := m[key]; ok {
			if s, ok := v.(string); ok && s != "" {
				parts = append(parts, fmt.Sprintf("%s=%q", key, s))
				break
			}
		}
	}
	for _, key := range []string{"path", "directory", "dir", "include"} {
		if v, ok := m[key]; ok {
			if s, ok := v.(string); ok && s != "" {
				parts = append(parts, fmt.Sprintf("path=%q", s))
				break
			}
		}
	}

	return strings.Join(parts, " ")
}

// renderGrepResults formats result lines, highlighting file paths and
// appending a result count.
func renderGrepResults(result string, maxLines int) string {
	lines := strings.Split(strings.TrimRight(result, "\n"), "\n")
	total := len(lines)

	visible := lines
	if total > maxLines {
		visible = lines[:maxLines]
	}

	var sb strings.Builder
	for _, line := range visible {
		if line == "" {
			continue
		}
		if col := filePathPrefix(line); col > 0 {
			// file:line:content format — highlight the path segment.
			path := line[:col]
			rest := line[col:]
			sb.WriteString(style.FilePath.Render(path) + style.ToolOutput.Render(rest) + "\n")
		} else {
			sb.WriteString(style.ToolOutput.Render(line) + "\n")
		}
	}

	if total > maxLines {
		sb.WriteString(style.Faint.Render(fmt.Sprintf("... (%d more results)", total-maxLines)))
	} else {
		sb.WriteString(style.Faint.Render(fmt.Sprintf("(%d results)", total)))
	}

	return sb.String()
}

// ---------------------------------------------------------------------------
// LSRenderer
// ---------------------------------------------------------------------------

// LSRenderer renders directory listing tool invocations.
//
// Example:
//
//	✓ LS  lib/                                  23ms
//	  │ app.ex  router.ex  utils.ex
//	  │ config/ test/
//	  │ (8 entries)
type LSRenderer struct{}

const lsMaxLines = 20

// Render implements ToolRenderer.
func (r LSRenderer) Render(name, args, result string, opts RenderOpts) string {
	dir := extractDirectory(args)
	header := renderToolHeader(opts.Status, "LS", style.FilePath.Render(dir), opts)

	if opts.Compact {
		return header
	}

	if result == "" {
		return header
	}

	body := renderLSResults(result, opts.Width-4, maxDisplayLines(opts.Expanded, lsMaxLines))
	return renderToolBox(header+"\n"+body, opts.Width)
}

// renderLSResults formats directory listing in columns.
func renderLSResults(result string, width, maxLines int) string {
	lines := strings.Split(strings.TrimRight(result, "\n"), "\n")
	var entries []string
	for _, l := range lines {
		t := strings.TrimSpace(l)
		if t != "" {
			entries = append(entries, t)
		}
	}
	total := len(entries)

	visible := entries
	if total > maxLines {
		visible = entries[:maxLines]
	}

	// Split into dirs and files for visual grouping.
	var dirs, files []string
	for _, e := range visible {
		if strings.HasSuffix(e, "/") || strings.HasSuffix(e, "\\") {
			dirs = append(dirs, e)
		} else {
			files = append(files, e)
		}
	}

	var sb strings.Builder

	// Render dirs.
	if len(dirs) > 0 {
		var row strings.Builder
		col := 0
		for i, d := range dirs {
			entry := style.FilePath.Render(d)
			w := len(d) + 2
			if col > 0 && col+w > width {
				sb.WriteString(strings.TrimRight(row.String(), " ") + "\n")
				row.Reset()
				col = 0
			}
			row.WriteString(style.ToolOutput.Render(d) + "  ")
			col += w
			if i == len(dirs)-1 {
				sb.WriteString(strings.TrimRight(row.String(), " ") + "\n")
				_ = entry
			}
		}
	}

	// Render files.
	if len(files) > 0 {
		var row strings.Builder
		col := 0
		for i, f := range files {
			w := len(f) + 2
			if col > 0 && col+w > width {
				sb.WriteString(strings.TrimRight(row.String(), " ") + "\n")
				row.Reset()
				col = 0
			}
			row.WriteString(style.ToolOutput.Render(f) + "  ")
			col += w
			if i == len(files)-1 {
				sb.WriteString(strings.TrimRight(row.String(), " ") + "\n")
			}
		}
	}

	if total > maxLines {
		sb.WriteString(style.Faint.Render(fmt.Sprintf("... (%d more entries)", total-maxLines)))
	} else {
		sb.WriteString(style.Faint.Render(fmt.Sprintf("(%d entries)", total)))
	}

	return sb.String()
}

// ---------------------------------------------------------------------------
// Shared search helpers
// ---------------------------------------------------------------------------

// extractSearchPattern parses the search pattern from JSON args.
func extractSearchPattern(args string) string {
	args = strings.TrimSpace(args)
	if args == "" {
		return ""
	}
	var m map[string]interface{}
	if err := json.Unmarshal([]byte(args), &m); err == nil {
		for _, key := range []string{"pattern", "glob", "query", "regex", "path"} {
			if v, ok := m[key]; ok {
				if s, ok := v.(string); ok && s != "" {
					return s
				}
			}
		}
	}
	// Raw string fallback.
	if len(args) > 60 {
		return args[:57] + "…"
	}
	return args
}

// extractDirectory parses the directory path from JSON args.
func extractDirectory(args string) string {
	args = strings.TrimSpace(args)
	if args == "" {
		return "."
	}
	var m map[string]interface{}
	if err := json.Unmarshal([]byte(args), &m); err == nil {
		for _, key := range []string{"path", "directory", "dir"} {
			if v, ok := m[key]; ok {
				if s, ok := v.(string); ok && s != "" {
					return s
				}
			}
		}
	}
	return "."
}

// isFileLine returns true for lines that look like standalone file paths.
func isFileLine(line string) bool {
	trimmed := strings.TrimSpace(line)
	if trimmed == "" {
		return false
	}
	return strings.HasPrefix(trimmed, "/") ||
		strings.HasPrefix(trimmed, "./") ||
		strings.HasPrefix(trimmed, "~/")
}

// filePathPrefix returns the byte index of the first colon separating a file
// path from line:content in grep output (e.g. "lib/app.ex:45:...").
// Returns 0 if the line does not appear to have a path prefix.
func filePathPrefix(line string) int {
	if idx := strings.Index(line, ":"); idx > 0 {
		candidate := line[:idx]
		if strings.ContainsAny(candidate, "/.") {
			return idx
		}
	}
	return 0
}
