// Package common provides shared rendering helpers and formatting utilities
// used across all OSA TUI v2 UI components.
package common

import (
	"fmt"
	"path/filepath"
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/miosa/osa-tui/style"
)

// ---------------------------------------------------------------------------
// Layout helpers
// ---------------------------------------------------------------------------

// CappedWidth returns width capped at maxWidth for readability.
// If maxWidth <= 0, 120 is used as the default cap.
func CappedWidth(width, maxWidth int) int {
	cap := maxWidth
	if cap <= 0 {
		cap = 120
	}
	if width > cap {
		return cap
	}
	return width
}

// ---------------------------------------------------------------------------
// Text truncation / padding
// ---------------------------------------------------------------------------

// Truncate shortens s to maxLen runes, appending "…" if truncated.
func Truncate(s string, maxLen int) string {
	runes := []rune(s)
	if len(runes) <= maxLen {
		return s
	}
	if maxLen <= 1 {
		return "…"
	}
	return string(runes[:maxLen-1]) + "…"
}

// TruncatePath shortens a filesystem path intelligently to fit maxWidth columns.
// Strategy (first that fits): full path → ~/relative → …/last-two → …/basename.
func TruncatePath(path string, maxWidth int) string {
	if lipgloss.Width(path) <= maxWidth {
		return path
	}

	// Try home-relative.
	if home, err := homeDir(); err == nil {
		if rel, err2 := filepath.Rel(home, path); err2 == nil && !strings.HasPrefix(rel, "..") {
			homePath := "~/" + rel
			if lipgloss.Width(homePath) <= maxWidth {
				return homePath
			}
		}
	}

	// Try …/parent/base.
	parts := strings.Split(filepath.Clean(path), string(filepath.Separator))
	if len(parts) >= 2 {
		lastTwo := "…/" + strings.Join(parts[len(parts)-2:], string(filepath.Separator))
		if lipgloss.Width(lastTwo) <= maxWidth {
			return lastTwo
		}
	}

	// Fallback: …/basename.
	base := "…/" + filepath.Base(path)
	if lipgloss.Width(base) <= maxWidth {
		return base
	}

	// Hard truncate.
	return Truncate(base, maxWidth)
}

// PrettyPath shortens path for display: replaces home prefix with ~/ and
// then truncates with TruncatePath using a default maximum of 60 columns.
func PrettyPath(path string) string {
	if home, err := homeDir(); err == nil {
		if rel, err2 := filepath.Rel(home, path); err2 == nil && !strings.HasPrefix(rel, "..") {
			path = "~/" + rel
		}
	}
	return TruncatePath(path, 60)
}

// PadRight pads s on the right with spaces until the rendered display width
// equals width. Returns s unchanged if it already meets or exceeds width.
func PadRight(s string, width int) string {
	w := lipgloss.Width(s)
	if w >= width {
		return s
	}
	return s + strings.Repeat(" ", width-w)
}

// PadCenter centers s within width, padding both sides with spaces.
func PadCenter(s string, width int) string {
	w := lipgloss.Width(s)
	if w >= width {
		return s
	}
	total := width - w
	left := total / 2
	right := total - left
	return strings.Repeat(" ", left) + s + strings.Repeat(" ", right)
}

// Divider returns a horizontal rule of the given width rendered in the border color.
func Divider(width int) string {
	if width <= 0 {
		return ""
	}
	return lipgloss.NewStyle().Foreground(style.Border).Render(strings.Repeat("─", width))
}

// WrapText hard-wraps text so that no rendered line exceeds width columns.
// Existing newlines are preserved; long words are not split.
func WrapText(text string, width int) string {
	if width <= 0 {
		return text
	}
	var out strings.Builder
	paragraphs := strings.Split(text, "\n")
	for i, para := range paragraphs {
		if i > 0 {
			out.WriteByte('\n')
		}
		words := strings.Fields(para)
		if len(words) == 0 {
			continue
		}
		lineLen := 0
		for j, word := range words {
			wLen := lipgloss.Width(word)
			if j == 0 {
				out.WriteString(word)
				lineLen = wLen
				continue
			}
			if lineLen+1+wLen > width {
				out.WriteByte('\n')
				out.WriteString(word)
				lineLen = wLen
			} else {
				out.WriteByte(' ')
				out.WriteString(word)
				lineLen += 1 + wLen
			}
		}
	}
	return out.String()
}

// ---------------------------------------------------------------------------
// Human-readable formatters
// ---------------------------------------------------------------------------

// HumanSize formats a byte count to a compact human-readable string.
//
//	1,572,864 → "1.5MB"
//	2,048     → "2.0KB"
//	512       → "512B"
func HumanSize(bytes int64) string {
	switch {
	case bytes >= 1<<20:
		return fmt.Sprintf("%.1fMB", float64(bytes)/(1<<20))
	case bytes >= 1<<10:
		return fmt.Sprintf("%.1fKB", float64(bytes)/(1<<10))
	default:
		return fmt.Sprintf("%dB", bytes)
	}
}

// HumanTokens formats a token count compactly.
//
//	1_500_000 → "1.5M"
//	3_400     → "3.4k"
//	250       → "250"
func HumanTokens(n int) string {
	switch {
	case n >= 1_000_000:
		return fmt.Sprintf("%.1fM", float64(n)/1_000_000)
	case n >= 1_000:
		return fmt.Sprintf("%.1fk", float64(n)/1_000)
	default:
		return fmt.Sprintf("%d", n)
	}
}

// HumanDuration formats a millisecond duration to a compact human-readable string.
//
//	450   → "450ms"
//	3_200 → "3.2s"
//	90_000 → "1m 30s"
func HumanDuration(ms int64) string {
	switch {
	case ms < 1_000:
		return fmt.Sprintf("%dms", ms)
	case ms < 60_000:
		return fmt.Sprintf("%.1fs", float64(ms)/1_000)
	default:
		m := int(ms) / 60_000
		s := int(ms/1_000) % 60
		return fmt.Sprintf("%dm %ds", m, s)
	}
}

// FormatCost formats a cost in cents as a dollar string, e.g. 12.5 → "$0.13".
func FormatCost(cents float64) string {
	return fmt.Sprintf("$%.2f", cents/100)
}

// ---------------------------------------------------------------------------
// Section / dialog chrome
// ---------------------------------------------------------------------------

// SectionSeparator returns a thin horizontal rule styled for section dividers.
func SectionSeparator(width int) string {
	if width <= 0 {
		return ""
	}
	return style.SectionBorder.Render(strings.Repeat("─", width))
}

// Section renders a bordered section block with a title header and content body.
//
//	┌─ Title ─────────────────┐
//	│ content                  │
//	└──────────────────────────┘
func Section(title, content string, width int) string {
	if width <= 0 {
		width = 40
	}
	// Inner content width accounts for border (1 each side) + padding (1 each side).
	innerWidth := width - 4
	if innerWidth < 1 {
		innerWidth = 1
	}

	titleStr := style.SectionTitle.Render(title)
	titleWidth := lipgloss.Width(titleStr)
	rightFill := innerWidth - titleWidth - 2
	if rightFill < 0 {
		rightFill = 0
	}

	topBar := "┌─ " + titleStr + " " + strings.Repeat("─", rightFill) + "┐"
	body := style.SectionBorder.
		UnsetBorderStyle().
		Width(innerWidth).
		Render(content)

	var sb strings.Builder
	sb.WriteString(topBar)
	sb.WriteByte('\n')
	for _, line := range strings.Split(body, "\n") {
		sb.WriteString("│ ")
		sb.WriteString(PadRight(line, innerWidth))
		sb.WriteString(" │\n")
	}
	sb.WriteString("└" + strings.Repeat("─", width-2) + "┘")
	return sb.String()
}

// DialogTitle renders a gradient-styled dialog title centered within width.
func DialogTitle(title string, width int) string {
	rendered := style.ApplyBoldForegroundGrad(title)
	if width <= 0 {
		return rendered
	}
	// Center the plain title for width calculation, then re-apply gradient.
	plainWidth := lipgloss.Width(title)
	if plainWidth >= width {
		return rendered
	}
	pad := (width - plainWidth) / 2
	return strings.Repeat(" ", pad) + rendered
}

// ---------------------------------------------------------------------------
// Status badge
// ---------------------------------------------------------------------------

// StatusBadge renders a colored status indicator: "● label" green if ok, red otherwise.
func StatusBadge(label string, ok bool) string {
	dot := "●"
	if ok {
		return lipgloss.NewStyle().Foreground(style.Success).Render(dot + " " + label)
	}
	return lipgloss.NewStyle().Foreground(style.Error).Render(dot + " " + label)
}

// ModelInfo renders a formatted model info line suitable for a status bar or header.
//
// Example: "anthropic / claude-opus-4-6  🧠  ctx 45%  $0.03"
func ModelInfo(provider, model string, reasoning bool, contextPct float64, cost string) string {
	parts := []string{
		style.HeaderProvider.Render(provider),
		style.Faint.Render("/"),
		style.HeaderModel.Render(model),
	}
	if reasoning {
		parts = append(parts, style.PrefixThinking.Render("⟳"))
	}
	if contextPct > 0 {
		bar := ContextBar(contextPct, 8)
		pct := fmt.Sprintf("%.0f%%", contextPct*100)
		parts = append(parts, bar+" "+style.Faint.Render(pct))
	}
	if cost != "" {
		parts = append(parts, style.Faint.Render(cost))
	}
	return strings.Join(parts, "  ")
}

// ContextBar renders a compact progress bar for context utilization.
// width controls how many character cells the bar occupies.
func ContextBar(utilization float64, width int) string {
	return style.ContextBarRender(utilization, width)
}

// ---------------------------------------------------------------------------
// Button group
// ---------------------------------------------------------------------------

// ButtonItem describes a single button in a ButtonGroup.
type ButtonItem struct {
	Label        string
	Shortcut     string // single char, e.g. "y"
	Danger       bool   // render as danger style when active
	UnderlineIdx int    // rune index in Label to underline as hotkey hint; -1 to disable
}

// ButtonGroup renders a horizontal row of buttons. activeIdx selects which
// button is highlighted. Returns the rendered string.
func ButtonGroup(buttons []ButtonItem, activeIdx int) string {
	if len(buttons) == 0 {
		return ""
	}
	parts := make([]string, len(buttons))
	for i, btn := range buttons {
		label := btn.Label
		if btn.Shortcut != "" {
			label = "[" + btn.Shortcut + "] " + label
		}

		var rendered string
		switch {
		case i == activeIdx && btn.Danger:
			rendered = style.ButtonDanger.Render(label)
		case i == activeIdx:
			rendered = style.ButtonActive.Render(label)
		default:
			rendered = style.ButtonInactive.Render(label)
		}
		parts[i] = rendered
	}
	return strings.Join(parts, "  ")
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

// homeDir returns the user's home directory via os.UserHomeDir, or an error.
// Separated so TruncatePath can handle the absence gracefully.
func homeDir() (string, error) {
	// Use os package via a thin wrapper to keep the import in one place.
	return osUserHomeDir()
}
