package completions

import (
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/miosa/osa-tui/style"
)

// RenderItem renders a single completion item for standalone display or popup
// rows. selected controls the highlighted style; filter is the current query
// used to bold-highlight matching characters in the name; width is the total
// available cell width for the rendered row.
func RenderItem(item CompletionItem, selected bool, filter string, width int) string {
	var sb strings.Builder

	// Cursor / selection marker (2 cells).
	if selected {
		sb.WriteString(style.PlanSelected.Render("▸ "))
	} else {
		sb.WriteString("  ")
	}

	// Category icon (2 cells including trailing space).
	icon := item.Icon
	if icon == "" {
		icon = CategoryIcon(item.Category)
	}
	if selected {
		sb.WriteString(style.PlanSelected.Render(icon + " "))
	} else {
		sb.WriteString(style.Faint.Render(icon + " "))
	}

	// Name with fuzzy-match highlighting.
	if selected {
		sb.WriteString(style.PlanSelected.Render(item.Name))
	} else {
		sb.WriteString(MatchHighlight(item.Name, matchPositions(item.Name, filter)))
	}

	// Description — right-padded to fill width.
	if item.Description != "" {
		// Use a small fixed gap between name and description.
		gap := "  "
		desc := style.Faint.Render(gap + item.Description)
		sb.WriteString(desc)
	}

	_ = width // reserved for future truncation logic
	return sb.String()
}

// CategoryIcon returns the display icon rune for a completion category.
func CategoryIcon(category string) string {
	switch category {
	case "command", "system":
		return "/"
	case "file":
		return "f" // plain ASCII fallback; callers can override via Icon field
	case "resource":
		return "@"
	case "session":
		return "s"
	case "config":
		return "c"
	default:
		return "·"
	}
}

// MatchHighlight applies bold + Secondary colour styling to the characters in
// text at the given positions (byte indices). Positions outside the string are
// ignored. An empty positions slice returns the plain muted name.
func MatchHighlight(text string, positions []int) string {
	if len(positions) == 0 || text == "" {
		return lipgloss.NewStyle().Foreground(style.Muted).Render(text)
	}

	// Build a set for O(1) lookup.
	posSet := make(map[int]bool, len(positions))
	for _, p := range positions {
		posSet[p] = true
	}

	var sb strings.Builder
	for i, ch := range text {
		s := string(ch)
		if posSet[i] {
			sb.WriteString(lipgloss.NewStyle().Foreground(style.Secondary).Bold(true).Render(s))
		} else {
			sb.WriteString(lipgloss.NewStyle().Foreground(style.Muted).Render(s))
		}
	}
	return sb.String()
}

// matchPositions returns the byte indices of filter characters found
// (contiguously) in text. Returns nil when filter is empty or not found.
func matchPositions(text, filter string) []int {
	if filter == "" {
		return nil
	}
	lower := strings.ToLower(text)
	q := strings.ToLower(filter)
	idx := strings.Index(lower, q)
	if idx == -1 {
		return nil
	}
	positions := make([]int, len(q))
	for i := range q {
		positions[i] = idx + i
	}
	return positions
}
