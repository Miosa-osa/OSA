// Package diff provides rich diff rendering for OSA TUI v2.
// It supports unified diffs, side-by-side split diffs, inline diffs,
// line numbers, context lines, tab expansion, and syntax highlighting
// via Chroma.
package diff

import (
	"fmt"
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/miosa/osa-tui/style"
)

const (
	defaultContext  = 3
	defaultTabWidth = 4
)

// diffOp classifies a single diff line.
type diffOp int

const (
	diffContext diffOp = iota
	diffAdd
	diffRemove
)

// diffLine represents one annotated line produced by the diff engine.
type diffLine struct {
	Op      diffOp
	Content string // original content (no prefix sigil)
	OldNum  int    // 1-based line number in old file; 0 for pure additions
	NewNum  int    // 1-based line number in new file; 0 for pure removals
}

// hunk is a contiguous group of diffLines.
type hunk struct {
	oldStart, newStart int
	lines              []diffLine
}

// --- Public API ---

// RenderUnifiedDiff renders a pre-formatted unified diff string with ANSI
// coloring. Lines starting with + are green, - are red, @@ are the hunk
// header color, and everything else is muted.
func RenderUnifiedDiff(diffText string, width int) string {
	lines := splitLines(diffText)
	var sb strings.Builder
	for i, line := range lines {
		var rendered string
		switch {
		case strings.HasPrefix(line, "+++") || strings.HasPrefix(line, "---"):
			rendered = style.DiffHunkLabel.Render(truncate(line, width))
		case strings.HasPrefix(line, "+"):
			rendered = style.DiffAdd.Render(truncate(line, width))
		case strings.HasPrefix(line, "-"):
			rendered = style.DiffRemove.Render(truncate(line, width))
		case strings.HasPrefix(line, "@@"):
			rendered = style.DiffHunkLabel.Render(truncate(line, width))
		default:
			rendered = style.DiffContext.Render(truncate(line, width))
		}
		sb.WriteString(rendered)
		if i < len(lines)-1 {
			sb.WriteByte('\n')
		}
	}
	return sb.String()
}

// RenderDiff computes and renders a unified-style diff between oldContent and
// newContent. filename is used for syntax highlighting.
func RenderDiff(filename, oldContent, newContent string, width int) string {
	oldLines := expandTabs(splitLines(oldContent), defaultTabWidth)
	newLines := expandTabs(splitLines(newContent), defaultTabWidth)
	hunks := computeHunks(oldLines, newLines, defaultContext)
	if len(hunks) == 0 {
		return style.DiffContext.Render("(no changes)")
	}

	numW := lineNumWidth(maxLineNum(hunks))
	var sb strings.Builder

	for hi, h := range hunks {
		// Hunk header.
		oldCount, newCount := hunkCounts(h)
		header := fmt.Sprintf("@@ -%d,%d +%d,%d @@",
			h.oldStart, oldCount, h.newStart, newCount)
		sb.WriteString(style.DiffHunkLabel.Render(truncate(header, width)))
		sb.WriteByte('\n')

		for _, dl := range h.lines {
			sb.WriteString(renderUnifiedLine(filename, dl, numW, width))
			sb.WriteByte('\n')
		}

		if hi < len(hunks)-1 {
			// Separator between hunks.
			sb.WriteString(style.DiffContext.Render(strings.Repeat("─", min(width, 40))))
			sb.WriteByte('\n')
		}
	}

	return strings.TrimRight(sb.String(), "\n")
}

// RenderSplitDiff renders a side-by-side diff of oldContent vs newContent.
// Each side gets (width-3)/2 columns; the center 3 columns are the divider.
func RenderSplitDiff(filename, oldContent, newContent string, width int) string {
	oldLines := expandTabs(splitLines(oldContent), defaultTabWidth)
	newLines := expandTabs(splitLines(newContent), defaultTabWidth)
	hunks := computeHunks(oldLines, newLines, defaultContext)
	if len(hunks) == 0 {
		return style.DiffContext.Render("(no changes)")
	}

	sideW := (width - 3) / 2
	if sideW < 10 {
		// Fall back to unified if terminal is too narrow.
		return RenderDiff(filename, oldContent, newContent, width)
	}
	numW := lineNumWidth(maxLineNum(hunks))

	divStyle := lipgloss.NewStyle().Foreground(style.Border)
	var sections []string

	for _, h := range hunks {
		header := fmt.Sprintf("@@ -%d +%d @@", h.oldStart, h.newStart)
		hdrLine := style.DiffHunkLabel.Render(truncate(header, width))
		sections = append(sections, hdrLine)

		// Pair up sides: removed on left, added on right.
		// Context lines appear on both sides.
		leftLines, rightLines := splitSides(h.lines)

		maxRows := max(len(leftLines), len(rightLines))
		for row := 0; row < maxRows; row++ {
			var leftStr, rightStr string
			if row < len(leftLines) {
				leftStr = renderSplitCell(filename, leftLines[row], numW, sideW)
			} else {
				leftStr = strings.Repeat(" ", sideW)
			}
			if row < len(rightLines) {
				rightStr = renderSplitCell(filename, rightLines[row], numW, sideW)
			} else {
				rightStr = strings.Repeat(" ", sideW)
			}
			div := divStyle.Render("│")
			row := lipgloss.JoinHorizontal(lipgloss.Top, leftStr, div, rightStr)
			sections = append(sections, row)
		}
	}

	return strings.Join(sections, "\n")
}

// RenderInlineDiff renders a compact inline diff for file-edit tool cards.
// It shows a filename header followed by a unified diff block.
func RenderInlineDiff(filename, diffText string, width int) string {
	header := style.FilePath.Render(truncate(filename, width-2))
	body := RenderUnifiedDiff(diffText, width)
	return header + "\n" + body
}

// --- diff engine ---

// computeEdits produces a flat annotated list using LCS-based diff.
// O(m*n) — adequate for TUI file sizes.
func computeEdits(old, new []string) []diffLine {
	m, n := len(old), len(new)
	dp := make([][]int, m+1)
	for i := range dp {
		dp[i] = make([]int, n+1)
	}
	for i := m - 1; i >= 0; i-- {
		for j := n - 1; j >= 0; j-- {
			if old[i] == new[j] {
				dp[i][j] = dp[i+1][j+1] + 1
			} else if dp[i+1][j] > dp[i][j+1] {
				dp[i][j] = dp[i+1][j]
			} else {
				dp[i][j] = dp[i][j+1]
			}
		}
	}

	var edits []diffLine
	oldNum, newNum := 1, 1
	i, j := 0, 0
	for i < m || j < n {
		switch {
		case i < m && j < n && old[i] == new[j]:
			edits = append(edits, diffLine{diffContext, old[i], oldNum, newNum})
			i++
			j++
			oldNum++
			newNum++
		case j < n && (i >= m || dp[i][j+1] >= dp[i+1][j]):
			edits = append(edits, diffLine{diffAdd, new[j], 0, newNum})
			j++
			newNum++
		default:
			edits = append(edits, diffLine{diffRemove, old[i], oldNum, 0})
			i++
			oldNum++
		}
	}
	return edits
}

// computeHunks groups edits into hunks with ctx lines of context on each side.
func computeHunks(old, new []string, ctx int) []hunk {
	edits := computeEdits(old, new)
	if len(edits) == 0 {
		return nil
	}

	// Find indices of changed lines.
	var changed []int
	for i, e := range edits {
		if e.Op != diffContext {
			changed = append(changed, i)
		}
	}
	if len(changed) == 0 {
		return nil
	}

	// Build hunk ranges: [start, end) with ctx padding.
	type span struct{ s, e int }
	var spans []span
	cs, ce := max(0, changed[0]-ctx), min(len(edits), changed[0]+ctx+1)
	for _, ci := range changed[1:] {
		ns := max(0, ci-ctx)
		ne := min(len(edits), ci+ctx+1)
		if ns <= ce {
			ce = ne
		} else {
			spans = append(spans, span{cs, ce})
			cs, ce = ns, ne
		}
	}
	spans = append(spans, span{cs, ce})

	// Materialise hunks.
	var hunks []hunk
	for _, sp := range spans {
		lines := edits[sp.s:sp.e]
		if len(lines) == 0 {
			continue
		}
		oldStart, newStart := 1, 1
		// Find correct start numbers from first line in slice.
		first := lines[0]
		if first.OldNum > 0 {
			oldStart = first.OldNum
		} else {
			// Addition: old position from preceding context.
			// Walk back to find the last known old line number.
			oldStart = sp.s + 1
		}
		if first.NewNum > 0 {
			newStart = first.NewNum
		} else {
			newStart = sp.s + 1
		}
		hunks = append(hunks, hunk{oldStart, newStart, lines})
	}
	return hunks
}

// --- rendering helpers ---

func renderUnifiedLine(filename string, dl diffLine, numW, width int) string {
	var sigil string
	var lineStyle lipgloss.Style
	switch dl.Op {
	case diffAdd:
		sigil = "+"
		lineStyle = style.DiffAdd
	case diffRemove:
		sigil = "-"
		lineStyle = style.DiffRemove
	default:
		sigil = " "
		lineStyle = style.DiffContext
	}

	oldN := lineNumStr(dl.OldNum, numW)
	newN := lineNumStr(dl.NewNum, numW)
	gutter := style.Faint.Render(oldN) + " " + style.Faint.Render(newN) + " " + sigil + " "
	gutterW := numW*2 + 4
	remaining := width - gutterW
	if remaining < 4 {
		remaining = 4
	}

	content := HighlightLine(filename, dl.Content)
	content = truncate(content, remaining)
	return gutter + lineStyle.Render(content)
}

func renderSplitCell(filename string, dl diffLine, numW, cellW int) string {
	var sigil string
	var lineStyle lipgloss.Style
	switch dl.Op {
	case diffAdd:
		sigil = "+"
		lineStyle = style.DiffAdd
	case diffRemove:
		sigil = "-"
		lineStyle = style.DiffRemove
	default:
		sigil = " "
		lineStyle = style.DiffContext
	}

	var num int
	if dl.Op == diffAdd {
		num = dl.NewNum
	} else {
		num = dl.OldNum
	}

	gutter := style.Faint.Render(lineNumStr(num, numW)) + " " + sigil + " "
	gutterW := numW + 3
	contentW := cellW - gutterW
	if contentW < 4 {
		contentW = 4
	}

	content := HighlightLine(filename, dl.Content)
	content = truncate(content, contentW)
	// Pad to fixed cell width so JoinHorizontal aligns correctly.
	visW := lipgloss.Width(gutter + content)
	if visW < cellW {
		content += strings.Repeat(" ", cellW-visW)
	}
	return gutter + lineStyle.Render(content)
}

// splitSides converts a hunk's diffLines into parallel left/right columns
// for split-view rendering. Context lines appear on both sides; add only
// on the right; remove only on the left.
func splitSides(lines []diffLine) (left, right []diffLine) {
	empty := diffLine{Op: diffContext, Content: ""}
	for _, dl := range lines {
		switch dl.Op {
		case diffContext:
			left = append(left, dl)
			right = append(right, dl)
		case diffRemove:
			left = append(left, dl)
			right = append(right, empty)
		case diffAdd:
			left = append(left, empty)
			right = append(right, dl)
		}
	}
	return
}

// --- hunk arithmetic ---

func hunkCounts(h hunk) (oldCount, newCount int) {
	for _, dl := range h.lines {
		if dl.Op != diffAdd {
			oldCount++
		}
		if dl.Op != diffRemove {
			newCount++
		}
	}
	return
}

func maxLineNum(hunks []hunk) int {
	max := 0
	for _, h := range hunks {
		for _, dl := range h.lines {
			if dl.OldNum > max {
				max = dl.OldNum
			}
			if dl.NewNum > max {
				max = dl.NewNum
			}
		}
	}
	return max
}

func lineNumWidth(n int) int {
	if n < 10 {
		return 1
	}
	w := 0
	for n > 0 {
		w++
		n /= 10
	}
	return w
}

func lineNumStr(n, width int) string {
	if n == 0 {
		return strings.Repeat(" ", width)
	}
	return fmt.Sprintf("%*d", width, n)
}

// --- string utilities ---

// expandTabs replaces tab characters with spaces aligned to tabW-column stops.
func expandTabs(lines []string, tabW int) []string {
	out := make([]string, len(lines))
	for i, line := range lines {
		if !strings.ContainsRune(line, '\t') {
			out[i] = line
			continue
		}
		var sb strings.Builder
		col := 0
		for _, r := range line {
			if r == '\t' {
				spaces := tabW - (col % tabW)
				sb.WriteString(strings.Repeat(" ", spaces))
				col += spaces
			} else {
				sb.WriteRune(r)
				col++
			}
		}
		out[i] = sb.String()
	}
	return out
}

// truncate clips s to at most width visible characters, appending "…" if clipped.
func truncate(s string, width int) string {
	if width <= 0 {
		return s
	}
	if lipgloss.Width(s) <= width {
		return s
	}
	runes := []rune(s)
	var out []rune
	cur := 0
	for _, r := range runes {
		rw := 1
		if r > 0xFF {
			rw = 2
		}
		if cur+rw > width-1 {
			break
		}
		out = append(out, r)
		cur += rw
	}
	return string(out) + "…"
}

// splitLines splits text into lines, dropping a trailing empty element.
func splitLines(s string) []string {
	lines := strings.Split(s, "\n")
	if len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	return lines
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}
