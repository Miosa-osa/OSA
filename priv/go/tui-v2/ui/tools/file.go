package tools

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/miosa/osa-tui/style"
	"github.com/miosa/osa-tui/ui/diff"
)

// ---------------------------------------------------------------------------
// FileViewRenderer — Read / View
// ---------------------------------------------------------------------------

// FileViewRenderer renders file read/view tool invocations with line numbers.
//
// Example:
//
//	✓ Read  config/runtime.exs                  23ms
//	  │  1 │ import Config
//	  │  2 │
//	  │  3 │ config :app, :key, "value"
//	  │    │ ... (47 more lines)
type FileViewRenderer struct{}

const fileViewMaxLines = 10

// Render implements ToolRenderer.
func (r FileViewRenderer) Render(name, args, result string, opts RenderOpts) string {
	filePath := extractFilePath(args)
	detail := ""
	if filePath != "" {
		detail = style.FilePath.Render(filePath)
	}

	header := renderToolHeader(opts.Status, "Read", detail, opts)

	if opts.Compact {
		return header
	}

	if opts.Status == ToolAwaitingPermission {
		return renderToolBox(header+"\n"+pendingToolContent("Read"), opts.Width)
	}

	if result == "" {
		return header
	}

	preview := buildReadPreview(result, maxDisplayLines(opts.Expanded, fileViewMaxLines))
	return renderToolBox(header+"\n"+preview, opts.Width)
}

// buildReadPreview produces a numbered-line preview of file content, truncated
// to maxLines. It respects `cat -n`-style numeric prefixes already present in
// the content (e.g. from the Read tool's output format).
func buildReadPreview(content string, maxLines int) string {
	lines := strings.Split(strings.TrimRight(content, "\n"), "\n")
	total := len(lines)

	// Detect line offset from `cat -n` style numeric prefix on the first line.
	offset := 1
	if len(lines) > 0 {
		first := strings.TrimSpace(lines[0])
		var n int
		if _, err := fmt.Sscanf(first, "%d", &n); err == nil && n > 1 {
			offset = n
		}
	}

	visible := lines
	truncated := false
	if total > maxLines {
		visible = lines[:maxLines]
		truncated = true
	}

	var sb strings.Builder
	for i, line := range visible {
		lineNo := style.LineNumber.Render(fmt.Sprintf("%4d", offset+i))
		sep := style.Faint.Render(" │ ")
		sb.WriteString(lineNo + sep + line + "\n")
	}

	if truncated {
		remaining := total - maxLines
		hint := style.Faint.Render(fmt.Sprintf("     │ ... (%d more lines)", remaining))
		sb.WriteString(hint)
	} else {
		result := sb.String()
		return strings.TrimRight(result, "\n")
	}

	return sb.String()
}

// ---------------------------------------------------------------------------
// FileWriteRenderer — Write / Create
// ---------------------------------------------------------------------------

// FileWriteRenderer renders file write/create tool invocations showing all
// content as additions.
//
// Example:
//
//	✓ Write  lib/new_module.ex                  89ms
//	  │ + defmodule NewModule do
//	  │ +   def hello, do: :world
//	  │ + end
type FileWriteRenderer struct{}

const fileWriteMaxLines = 20

// Render implements ToolRenderer.
func (r FileWriteRenderer) Render(name, args, result string, opts RenderOpts) string {
	filePath := extractFilePath(args)
	detail := ""
	if filePath != "" {
		detail = style.FilePath.Render(filePath)
	}

	header := renderToolHeader(opts.Status, "Write", detail, opts)

	if opts.Compact {
		return header
	}

	if opts.Status == ToolAwaitingPermission {
		return renderToolBox(header+"\n"+pendingToolContent("Write"), opts.Width)
	}

	if result == "" && opts.Status != ToolSuccess {
		return header
	}

	content := extractFileContent(args)
	if content == "" && result != "" {
		content = result
	}
	if content == "" {
		return header
	}

	additions := renderAdditions(content)
	truncated := truncateLines(additions, maxDisplayLines(opts.Expanded, fileWriteMaxLines))
	return renderToolBox(header+"\n"+truncated, opts.Width)
}

// extractFileContent parses file content from JSON args.
// Keys checked: "content", "new_content", "text".
func extractFileContent(args string) string {
	args = strings.TrimSpace(args)
	if args == "" {
		return ""
	}
	var m map[string]interface{}
	if err := json.Unmarshal([]byte(args), &m); err != nil {
		return ""
	}
	for _, key := range []string{"content", "new_content", "text"} {
		if v, ok := m[key]; ok {
			if s, ok := v.(string); ok && s != "" {
				return s
			}
		}
	}
	return ""
}

// ---------------------------------------------------------------------------
// FileEditRenderer — Edit / str_replace_editor
// ---------------------------------------------------------------------------

// FileEditRenderer renders file edit tool invocations with an inline diff.
//
// Example:
//
//	✓ Edit  lib/app.ex                          89ms
//	  │ @@ -68,0 +69,8 @@
//	  │ + def strip_thinking_tokens(nil), do: ""
//	  │ + def strip_thinking_tokens(content) do
type FileEditRenderer struct{}

const fileEditMaxLines = 20

// Render implements ToolRenderer.
func (r FileEditRenderer) Render(name, args, result string, opts RenderOpts) string {
	filePath := extractFilePath(args)
	displayName := resolveEditDisplayName(name)

	detail := ""
	if filePath != "" {
		detail = style.FilePath.Render(filePath)
	}

	header := renderToolHeader(opts.Status, displayName, detail, opts)

	if opts.Compact {
		return header
	}

	if opts.Status == ToolAwaitingPermission {
		return renderToolBox(header+"\n"+pendingToolContent(displayName), opts.Width)
	}

	if result == "" && opts.Status != ToolSuccess {
		return header
	}

	diffContent := buildEditDiff(args, result, opts.Width-4)
	if diffContent == "" {
		return header
	}

	truncated := truncateLines(diffContent, maxDisplayLines(opts.Expanded, fileEditMaxLines))
	return renderToolBox(header+"\n"+truncated, opts.Width)
}

// resolveEditDisplayName maps internal tool names to user-facing labels.
func resolveEditDisplayName(name string) string {
	switch name {
	case "Write":
		return "Write"
	case "str_replace_editor", "edit_file", "file_edit", "Edit":
		return "Edit"
	default:
		return name
	}
}

// extractFilePath parses the file path from JSON args.
// Keys checked: "path", "file_path", "filename", "target_file".
func extractFilePath(args string) string {
	args = strings.TrimSpace(args)
	if args == "" {
		return ""
	}
	var m map[string]interface{}
	if err := json.Unmarshal([]byte(args), &m); err == nil {
		for _, key := range []string{"path", "file_path", "filename", "target_file"} {
			if v, ok := m[key]; ok {
				if s, ok := v.(string); ok && s != "" {
					return s
				}
			}
		}
	}
	return ""
}

// buildEditDiff produces a colored diff string from the args JSON.
//
//   - str_replace_editor / Edit: uses old_string vs new_string via diff.RenderDiff.
//   - Write: shows all content lines as additions.
//   - Fallback: renders result verbatim via ToolOutput style.
func buildEditDiff(args, result string, width int) string {
	args = strings.TrimSpace(args)

	var m map[string]interface{}
	if err := json.Unmarshal([]byte(args), &m); err != nil {
		if result != "" {
			return style.ToolOutput.Render(strings.TrimSpace(result))
		}
		return ""
	}

	oldStr, _ := m["old_string"].(string)
	newStr, _ := m["new_string"].(string)

	// str_replace_editor / Edit path: render inline diff.
	if oldStr != "" || newStr != "" {
		fp, _ := m["path"].(string)
		return diff.RenderDiff(fp, oldStr, newStr, width)
	}

	// Write path: show content as pure additions.
	content, _ := m["content"].(string)
	if content != "" {
		return renderAdditions(content)
	}

	// Fallback to result text.
	if result != "" {
		return style.ToolOutput.Render(strings.TrimSpace(result))
	}
	return ""
}

// renderAdditions renders every line as a diff-add (green "+") for new file writes.
func renderAdditions(content string) string {
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

// ---------------------------------------------------------------------------
// MultiEditRenderer — MultiEdit
// ---------------------------------------------------------------------------

// MultiEditRenderer renders multi-file edit operations as a sequence of diffs
// with a summary header.
//
// Example:
//
//	✓ MultiEdit  3 files                        1.2s
//	  │ lib/app.ex
//	  │ @@ -68,0 +69,8 @@
//	  │ + def foo, do: :bar
//	  │ ──────────────────
//	  │ lib/router.ex
//	  │ @@ -12,1 +12,1 @@
type MultiEditRenderer struct{}

const multiEditMaxLines = 30

// Render implements ToolRenderer.
func (r MultiEditRenderer) Render(name, args, result string, opts RenderOpts) string {
	files := extractMultiEditFiles(args)
	count := len(files)

	var detail string
	if count == 1 {
		detail = style.FilePath.Render(files[0].path)
	} else if count > 1 {
		detail = style.Faint.Render(fmt.Sprintf("%d files", count))
	}

	header := renderToolHeader(opts.Status, "MultiEdit", detail, opts)

	if opts.Compact {
		return header
	}

	if opts.Status == ToolAwaitingPermission {
		return renderToolBox(header+"\n"+pendingToolContent("MultiEdit"), opts.Width)
	}

	if len(files) == 0 {
		return header
	}

	var body strings.Builder
	sep := style.Faint.Render(strings.Repeat("─", 40))
	for i, f := range files {
		if i > 0 {
			body.WriteString(sep + "\n")
		}
		body.WriteString(style.FilePath.Render(f.path) + "\n")
		d := diff.RenderDiff(f.path, f.oldStr, f.newStr, opts.Width-4)
		body.WriteString(d)
		if i < len(files)-1 {
			body.WriteByte('\n')
		}
	}

	truncated := truncateLines(body.String(), maxDisplayLines(opts.Expanded, multiEditMaxLines))
	return renderToolBox(header+"\n"+truncated, opts.Width)
}

type multiEditFile struct {
	path   string
	oldStr string
	newStr string
}

// extractMultiEditFiles parses the edits array from MultiEdit args JSON.
// Expected shape: {"edits": [{"path": "...", "old_string": "...", "new_string": "..."}, ...]}
func extractMultiEditFiles(args string) []multiEditFile {
	args = strings.TrimSpace(args)
	if args == "" {
		return nil
	}
	var m map[string]interface{}
	if err := json.Unmarshal([]byte(args), &m); err != nil {
		return nil
	}

	editsRaw, ok := m["edits"]
	if !ok {
		return nil
	}
	editsSlice, ok := editsRaw.([]interface{})
	if !ok {
		return nil
	}

	var out []multiEditFile
	for _, item := range editsSlice {
		entry, ok := item.(map[string]interface{})
		if !ok {
			continue
		}
		f := multiEditFile{}
		for _, key := range []string{"path", "file_path", "filename"} {
			if v, ok := entry[key].(string); ok && v != "" {
				f.path = v
				break
			}
		}
		f.oldStr, _ = entry["old_string"].(string)
		f.newStr, _ = entry["new_string"].(string)
		out = append(out, f)
	}
	return out
}

// ---------------------------------------------------------------------------
// FileDownloadRenderer — Download
// ---------------------------------------------------------------------------

// FileDownloadRenderer renders file download tool invocations.
//
// Example:
//
//	✓ Download  model.bin                        3.4s
//	  │ https://huggingface.co/.../model.bin
//	  │ 1.2GB
type FileDownloadRenderer struct{}

// Render implements ToolRenderer.
func (r FileDownloadRenderer) Render(name, args, result string, opts RenderOpts) string {
	url := extractDownloadURL(args)
	filename := extractFilePath(args)
	if filename == "" && opts.Filename != "" {
		filename = opts.Filename
	}

	detail := filename
	if detail == "" {
		detail = url
	}

	header := renderToolHeader(opts.Status, "Download", style.FilePath.Render(detail), opts)

	if opts.Compact {
		return header
	}

	if result == "" {
		return header
	}

	var body strings.Builder
	if url != "" && filename != "" {
		body.WriteString(style.ToolOutput.Render(url) + "\n")
	}
	size := extractDownloadSize(result)
	if size != "" {
		body.WriteString(style.Faint.Render(size))
	} else {
		body.WriteString(style.ToolOutput.Render(strings.TrimRight(result, "\n")))
	}

	return renderToolBox(header+"\n"+body.String(), opts.Width)
}

// extractDownloadURL parses the URL from JSON args.
func extractDownloadURL(args string) string {
	args = strings.TrimSpace(args)
	if args == "" {
		return ""
	}
	var m map[string]interface{}
	if err := json.Unmarshal([]byte(args), &m); err != nil {
		return ""
	}
	for _, key := range []string{"url", "source", "src", "uri"} {
		if v, ok := m[key].(string); ok && v != "" {
			return v
		}
	}
	return ""
}

// extractDownloadSize tries to extract a human-readable size from the result.
func extractDownloadSize(result string) string {
	lower := strings.ToLower(result)
	for _, unit := range []string{"gb", "mb", "kb", "bytes"} {
		if strings.Contains(lower, unit) {
			// Return the first line that mentions a size.
			for _, line := range strings.Split(result, "\n") {
				if strings.Contains(strings.ToLower(line), unit) {
					return strings.TrimSpace(line)
				}
			}
		}
	}
	return ""
}
