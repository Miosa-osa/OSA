// Package common — text selection and highlight rendering for OSA TUI v2.
package common

import (
	"strings"
	"unicode"

	"charm.land/lipgloss/v2"
	"github.com/miosa/osa-tui/style"
)

// Highlight describes a rectangular selection region in a multi-line text block.
// Lines and columns are 0-indexed.
type Highlight struct {
	StartLine int
	EndLine   int
	StartCol  int
	EndCol    int
}

// IsEmpty reports whether the highlight covers no characters.
func (h Highlight) IsEmpty() bool {
	return h.StartLine == h.EndLine && h.StartCol == h.EndCol
}

// HighlightLine returns a Highlight that selects the entire content of the
// given line (0-indexed) within text.
func HighlightLine(content string, line int) Highlight {
	lines := strings.Split(content, "\n")
	if line < 0 || line >= len(lines) {
		return Highlight{}
	}
	return Highlight{
		StartLine: line,
		EndLine:   line,
		StartCol:  0,
		EndCol:    len([]rune(lines[line])),
	}
}

// HighlightWord returns the start and end rune column indices of the word
// that contains (or is adjacent to) column col on the given line of content.
// Follows UAX#29 simple word boundary rules: a "word" is a maximal run of
// non-whitespace runes.
func HighlightWord(content string, line, col int) (start, end int) {
	lines := strings.Split(content, "\n")
	if line < 0 || line >= len(lines) {
		return col, col
	}
	runes := []rune(lines[line])
	n := len(runes)
	if col < 0 {
		col = 0
	}
	if col >= n {
		col = n - 1
	}
	if n == 0 {
		return 0, 0
	}

	// If the cursor is on whitespace, return a zero-width selection.
	if unicode.IsSpace(runes[col]) {
		return col, col
	}

	// Expand left.
	s := col
	for s > 0 && !unicode.IsSpace(runes[s-1]) {
		s--
	}

	// Expand right.
	e := col
	for e < n && !unicode.IsSpace(runes[e]) {
		e++
	}

	return s, e
}

// RenderHighlighted renders content applying the TextSelection style to the
// region described by hl. Lines outside [hl.StartLine, hl.EndLine] are
// rendered without modification. The width parameter is reserved for future
// truncation; pass 0 to disable.
func RenderHighlighted(content string, hl *Highlight, width int) string {
	if hl == nil || hl.IsEmpty() {
		if width > 0 {
			return lipgloss.NewStyle().MaxWidth(width).Render(content)
		}
		return content
	}

	lines := strings.Split(content, "\n")
	sel := style.TextSelection

	var out strings.Builder
	for i, line := range lines {
		if i > 0 {
			out.WriteByte('\n')
		}

		runes := []rune(line)
		n := len(runes)

		if i < hl.StartLine || i > hl.EndLine {
			// Outside selection — render verbatim.
			out.WriteString(line)
			continue
		}

		// Compute column bounds for this line.
		colStart := 0
		colEnd := n

		if i == hl.StartLine {
			colStart = hl.StartCol
			if colStart < 0 {
				colStart = 0
			}
		}
		if i == hl.EndLine {
			colEnd = hl.EndCol
			if colEnd > n {
				colEnd = n
			}
		}
		if colStart > n {
			colStart = n
		}
		if colEnd < colStart {
			colEnd = colStart
		}

		// before | selected | after
		before := string(runes[:colStart])
		selected := string(runes[colStart:colEnd])
		after := string(runes[colEnd:])

		out.WriteString(before)
		if selected != "" {
			out.WriteString(sel.Render(selected))
		}
		out.WriteString(after)
	}

	result := out.String()
	if width > 0 {
		result = lipgloss.NewStyle().MaxWidth(width).Render(result)
	}
	return result
}
