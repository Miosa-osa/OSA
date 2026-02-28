// Package selection provides text selection state management for click-drag-release
// interactions in the OSA TUI. It tracks a rectangular region across rendered
// content lines and can extract or highlight the selected text.
package selection

import (
	"strings"
	"unicode"

	"charm.land/lipgloss/v2"
	"github.com/miosa/osa-tui/style"
)

// doubleClickThresholdMs is the maximum millisecond gap between two clicks
// that qualifies as a double-click.
const doubleClickThresholdMs int64 = 400

// Selection represents a text selection range across rendered content lines.
// Coordinates are in terminal cell space (column, row), where (0,0) is the
// top-left of the rendered content area.
type Selection struct {
	Active bool
	StartX int
	StartY int
	EndX   int
	EndY   int
}

// Model manages text selection state for click-drag-release interactions.
// All coordinate tracking is relative to the content area's top-left corner;
// callers must subtract any viewport offset before passing coordinates in.
type Model struct {
	selection Selection
	dragging  bool

	// Double/triple click tracking.
	lastClickTime int64 // Unix ms timestamp of most recent mouse-down
	lastClickX    int
	lastClickY    int
	clickCount    int // 1=char select, 2=word select, 3=line select
}

// New returns a zero-value Model with no active selection.
func New() Model {
	return Model{}
}

// HandleMouseDown starts a new selection at (x, y).
// If this click follows a recent click at the same position it increments the
// click-count for word/line selection; otherwise it resets to char selection.
func (m *Model) HandleMouseDown(x, y int, nowMs int64) {
	if IsDoubleClick(nowMs, m.lastClickTime, x, y, m.lastClickX, m.lastClickY) {
		m.clickCount++
		if m.clickCount > 3 {
			m.clickCount = 3
		}
	} else {
		m.clickCount = 1
	}

	m.lastClickTime = nowMs
	m.lastClickX = x
	m.lastClickY = y

	m.dragging = true
	m.selection = Selection{
		Active: true,
		StartX: x,
		StartY: y,
		EndX:   x,
		EndY:   y,
	}
}

// HandleMouseMotion extends the active selection to (x, y) during a drag.
// No-ops when no drag is in progress.
func (m *Model) HandleMouseMotion(x, y int) {
	if !m.dragging {
		return
	}
	m.selection.EndX = x
	m.selection.EndY = y
}

// HandleMouseUp finalizes the selection at (x, y). If start == end the
// selection is cleared (treated as a plain click).
func (m *Model) HandleMouseUp(x, y int) {
	m.dragging = false
	m.selection.EndX = x
	m.selection.EndY = y

	// A zero-length selection (plain click) counts as no selection.
	if m.selection.StartX == m.selection.EndX &&
		m.selection.StartY == m.selection.EndY &&
		m.clickCount == 1 {
		m.selection.Active = false
	}
}

// HandleDoubleClick selects the word under (x, y) in the given content string.
// content should be the raw text of line y (no ANSI sequences).
func (m *Model) HandleDoubleClick(x, y int, lineContent string) {
	start, end := WordBoundary(lineContent, x)
	m.selection = Selection{
		Active: true,
		StartX: start,
		StartY: y,
		EndX:   end,
		EndY:   y,
	}
	m.clickCount = 2
}

// HandleTripleClick selects the entire line at row y.
func (m *Model) HandleTripleClick(y int, lineLen int) {
	m.selection = Selection{
		Active: true,
		StartX: 0,
		StartY: y,
		EndX:   lineLen,
		EndY:   y,
	}
	m.clickCount = 3
}

// Clear removes the current selection and resets drag state.
func (m *Model) Clear() {
	m.selection = Selection{}
	m.dragging = false
}

// HasSelection reports whether a non-empty selection is currently active.
func (m Model) HasSelection() bool {
	return m.selection.Active
}

// GetSelection returns the current Selection value.
func (m Model) GetSelection() Selection {
	return m.selection
}

// normalised returns (startY, startX, endY, endX) ensuring start <= end
// in reading order (top-to-bottom, left-to-right).
func (s Selection) normalised() (sy, sx, ey, ex int) {
	sy, sx = s.StartY, s.StartX
	ey, ex = s.EndY, s.EndX

	// Swap if selection was drawn right-to-left or bottom-to-top.
	if sy > ey || (sy == ey && sx > ex) {
		sy, sx, ey, ex = ey, ex, sy, sx
	}
	return
}

// SelectedText extracts the selected text from a slice of rendered content lines.
// Lines are assumed to be plain text (ANSI codes stripped by the caller if needed).
func (m Model) SelectedText(lines []string) string {
	if !m.selection.Active || len(lines) == 0 {
		return ""
	}

	sy, sx, ey, ex := m.selection.normalised()

	// Clamp to actual line count.
	if sy >= len(lines) {
		return ""
	}
	if ey >= len(lines) {
		ey = len(lines) - 1
		ex = len(lines[ey])
	}

	if sy == ey {
		line := lines[sy]
		runes := []rune(line)
		start := clamp(sx, 0, len(runes))
		end := clamp(ex, start, len(runes))
		return string(runes[start:end])
	}

	var sb strings.Builder

	// First partial line.
	{
		runes := []rune(lines[sy])
		start := clamp(sx, 0, len(runes))
		sb.WriteString(string(runes[start:]))
	}

	// Middle full lines.
	for row := sy + 1; row < ey; row++ {
		sb.WriteByte('\n')
		sb.WriteString(lines[row])
	}

	// Last partial line.
	{
		sb.WriteByte('\n')
		runes := []rune(lines[ey])
		end := clamp(ex, 0, len(runes))
		sb.WriteString(string(runes[:end]))
	}

	return sb.String()
}

// RenderWithSelection applies selection highlighting to content.
// offsetY is the row index of the first line of content within the terminal,
// used to translate absolute selection coordinates to content-local row indices.
// Returns the content with the selected region styled with style.TextSelection.
func (m Model) RenderWithSelection(content string, offsetY int) string {
	if !m.selection.Active {
		return content
	}

	lines := strings.Split(content, "\n")
	sy, sx, ey, ex := m.selection.normalised()

	for i, line := range lines {
		row := i + offsetY

		var highlighted string
		switch {
		case row < sy || row > ey:
			// Entirely outside selection — render as-is.
			highlighted = line

		case sy == ey:
			// Single-line selection.
			runes := []rune(line)
			start := clamp(sx, 0, len(runes))
			end := clamp(ex, start, len(runes))
			highlighted = string(runes[:start]) +
				style.TextSelection.Render(string(runes[start:end])) +
				string(runes[end:])

		case row == sy:
			// First line of multi-line selection: from sx to end.
			runes := []rune(line)
			start := clamp(sx, 0, len(runes))
			highlighted = string(runes[:start]) +
				style.TextSelection.Render(string(runes[start:]))

		case row == ey:
			// Last line: from start to ex.
			runes := []rune(line)
			end := clamp(ex, 0, len(runes))
			highlighted = style.TextSelection.Render(string(runes[:end])) +
				string(runes[end:])

		default:
			// Middle lines: fully selected.
			highlighted = style.TextSelection.Render(line)
		}

		lines[i] = highlighted
	}

	return strings.Join(lines, "\n")
}

// RenderHighlight is a convenience wrapper that takes a lipgloss style for the
// selection region, allowing callers to override the default TextSelection style.
func RenderHighlight(content string, sel Selection, offsetY int, selStyle lipgloss.Style) string {
	if !sel.Active {
		return content
	}

	lines := strings.Split(content, "\n")
	sy, sx, ey, ex := sel.normalised()

	for i, line := range lines {
		row := i + offsetY

		runes := []rune(line)
		n := len(runes)

		var highlighted string
		switch {
		case row < sy || row > ey:
			highlighted = line

		case sy == ey:
			start := clamp(sx, 0, n)
			end := clamp(ex, start, n)
			highlighted = string(runes[:start]) +
				selStyle.Render(string(runes[start:end])) +
				string(runes[end:])

		case row == sy:
			start := clamp(sx, 0, n)
			highlighted = string(runes[:start]) + selStyle.Render(string(runes[start:]))

		case row == ey:
			end := clamp(ex, 0, n)
			highlighted = selStyle.Render(string(runes[:end])) + string(runes[end:])

		default:
			highlighted = selStyle.Render(line)
		}

		lines[i] = highlighted
	}

	return strings.Join(lines, "\n")
}

// WordBoundary finds the start and end column positions of the word that
// contains (or is adjacent to) column col in text.
// Word boundaries are defined by whitespace and common punctuation.
// Returns (col, col) when text is empty.
func WordBoundary(text string, col int) (start, end int) {
	runes := []rune(text)
	n := len(runes)
	if n == 0 {
		return 0, 0
	}

	col = clamp(col, 0, n-1)

	isDelim := func(r rune) bool {
		return unicode.IsSpace(r) || strings.ContainsRune(`.,;:!?'"()[]{}/<>|\\`, r)
	}

	// If the cursor is on a delimiter, return a single-char selection.
	if isDelim(runes[col]) {
		return col, col + 1
	}

	// Expand left.
	start = col
	for start > 0 && !isDelim(runes[start-1]) {
		start--
	}

	// Expand right.
	end = col
	for end < n && !isDelim(runes[end]) {
		end++
	}

	return start, end
}

// IsDoubleClick returns true when the current click (now, x, y) is within the
// double-click time threshold and at the same position as the last click.
func IsDoubleClick(now, lastTime int64, x, y, lastX, lastY int) bool {
	if now-lastTime > doubleClickThresholdMs {
		return false
	}
	return x == lastX && y == lastY
}

// clamp constrains v to [lo, hi].
func clamp(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}
