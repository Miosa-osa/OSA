// Package completions provides a command/file completions popup that appears
// above the input area, growing upward from the bottom of the screen.
package completions

import (
	"strings"

	"charm.land/bubbles/v2/key"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/miosa/osa-tui/style"
)

const maxVisible = 10

// CompletionItem is a single entry in the completions popup.
type CompletionItem struct {
	Name        string
	Description string
	Category    string // "command", "file", "resource", "session", "config"
	Icon        string // optional prefix icon; CategoryIcon used when empty
	Type        string // "command", "file", "resource" — typed dispatch hint
}

// SelectedMsg is emitted when the user accepts a completion item.
type SelectedMsg struct {
	Item CompletionItem
}

// DismissMsg is emitted when the user presses Esc.
type DismissMsg struct{}

// InsertMsg is emitted by UpInsert/DownInsert: the item is "inserted" but the
// popup stays open so the user can keep cycling.
type InsertMsg struct {
	Item CompletionItem
}

// cachedRow holds a pre-rendered row string along with the width it was
// rendered at. The cache is invalidated when width or filter changes.
type cachedRow struct {
	content string
	width   int
}

// Model is the completions popup state.
type Model struct {
	items    []CompletionItem // full unfiltered set
	filtered []CompletionItem // items after fuzzy filter applied
	filter   string           // current filter string
	cursor   int              // index into filtered
	visible  bool
	width    int
	rowCache map[int]cachedRow // index → cached rendered row
	keyMap   KeyMap
}

// New returns a zero-value Model with default key bindings.
func New() Model {
	return Model{
		keyMap: DefaultKeyMap(),
	}
}

// SetItems stores the full set of completable items without showing the popup.
// Call this once when available commands/files change; Show() will reuse them.
func (m *Model) SetItems(items []CompletionItem) {
	m.items = items
	m.rowCache = nil // invalidate cache
}

// Show makes the popup visible. If items is non-nil it replaces the stored set;
// otherwise the existing items (from SetItems or a prior Show) are reused.
func (m *Model) Show(items []CompletionItem, filter string, width int) {
	if items != nil {
		m.items = items
		m.rowCache = nil
	}
	if width != m.width {
		m.rowCache = nil
	}
	m.width = width
	m.visible = true
	m.cursor = 0
	m.setFilter(filter)
}

// Hide dismisses the popup without clearing the stored item set.
func (m *Model) Hide() {
	m.visible = false
	m.filtered = nil
	m.filter = ""
	m.cursor = 0
	m.rowCache = nil
}

// SetFilter updates the filter text and re-scores the filtered list,
// resetting the cursor to the top.
func (m *Model) SetFilter(filter string) {
	if filter != m.filter {
		m.rowCache = nil
	}
	m.setFilter(filter)
}

// setFilter is the internal (pointer receiver) filtering logic.
func (m *Model) setFilter(filter string) {
	m.filter = filter
	if filter == "" {
		m.filtered = make([]CompletionItem, len(m.items))
		copy(m.filtered, m.items)
	} else {
		q := strings.ToLower(filter)
		m.filtered = m.filtered[:0]
		for _, item := range m.items {
			if strings.Contains(strings.ToLower(item.Name), q) ||
				strings.Contains(strings.ToLower(item.Description), q) {
				m.filtered = append(m.filtered, item)
			}
		}
	}
	if m.cursor >= len(m.filtered) {
		m.cursor = 0
	}
}

// IsVisible reports whether the popup is currently shown.
func (m Model) IsVisible() bool { return m.visible }

// Selected returns a pointer to the currently highlighted item, or nil when
// the list is empty.
func (m Model) Selected() *CompletionItem {
	if !m.visible || len(m.filtered) == 0 {
		return nil
	}
	item := m.filtered[m.cursor]
	return &item
}

// optimalWidth computes the popup box width based on the longest item
// name + description, clamped to [40, 80].
func (m Model) optimalWidth() int {
	maxW := 40
	for _, item := range m.filtered {
		// icon(1) + spaces(3) + name + gap(2) + description
		w := 4 + len(item.Name) + 2 + len(item.Description)
		if w > maxW {
			maxW = w
		}
	}
	if maxW > 80 {
		maxW = 80
	}
	return maxW
}

// Update handles keyboard input when the popup is visible.
// Key events arrive as tea.KeyPressMsg in bubbletea v2.
func (m Model) Update(msg tea.Msg) (Model, tea.Cmd) {
	if !m.visible {
		return m, nil
	}

	kp, ok := msg.(tea.KeyPressMsg)
	if !ok {
		return m, nil
	}

	switch {
	// ── Normal up ────────────────────────────────────────────────────────
	case key.Matches(kp, m.keyMap.Up):
		if len(m.filtered) > 0 {
			if m.cursor > 0 {
				m.cursor--
			} else {
				m.cursor = len(m.filtered) - 1
			}
		}

	// ── Normal down ──────────────────────────────────────────────────────
	case key.Matches(kp, m.keyMap.Down):
		if len(m.filtered) > 0 {
			if m.cursor < len(m.filtered)-1 {
				m.cursor++
			} else {
				m.cursor = 0
			}
		}

	// ── UpInsert: accept current item, move up, keep popup open ─────────
	case key.Matches(kp, m.keyMap.UpInsert):
		if item := m.Selected(); item != nil {
			inserted := *item
			if m.cursor > 0 {
				m.cursor--
			} else {
				m.cursor = len(m.filtered) - 1
			}
			return m, func() tea.Msg { return InsertMsg{Item: inserted} }
		}

	// ── DownInsert: accept current item, move down, keep popup open ──────
	case key.Matches(kp, m.keyMap.DownInsert):
		if item := m.Selected(); item != nil {
			inserted := *item
			if m.cursor < len(m.filtered)-1 {
				m.cursor++
			} else {
				m.cursor = 0
			}
			return m, func() tea.Msg { return InsertMsg{Item: inserted} }
		}

	// ── Select (enter / tab) ─────────────────────────────────────────────
	case key.Matches(kp, m.keyMap.Select):
		if item := m.Selected(); item != nil {
			selected := *item
			m.Hide()
			return m, func() tea.Msg { return SelectedMsg{Item: selected} }
		}
		m.Hide()
		return m, func() tea.Msg { return DismissMsg{} }

	// ── Dismiss (esc) ────────────────────────────────────────────────────
	case key.Matches(kp, m.keyMap.Dismiss):
		m.Hide()
		return m, func() tea.Msg { return DismissMsg{} }
	}

	return m, nil
}

// View renders the completions popup. The list grows upward from the input:
// items are rendered in normal top-to-bottom order and placed above the input
// separator by the parent layout. Returns an empty string when not visible.
func (m Model) View() string {
	if !m.visible || len(m.filtered) == 0 {
		return ""
	}

	// Compute the visible window. We show at most maxVisible items, keeping
	// the cursor inside the window.
	total := len(m.filtered)
	pageSize := maxVisible
	if pageSize > total {
		pageSize = total
	}

	// Anchor the window around the cursor.
	start := m.cursor - pageSize/2
	if start < 0 {
		start = 0
	}
	end := start + pageSize
	if end > total {
		end = total
		start = end - pageSize
		if start < 0 {
			start = 0
		}
	}

	window := m.filtered[start:end]

	// Dynamic width based on item content.
	boxWidth := m.optimalWidth()

	// Render each row, using the cache where possible.
	var rows []string
	for i, item := range window {
		actualIdx := start + i
		selected := actualIdx == m.cursor

		// Cache key encodes selection state; selected rows are never cached
		// because they change on every cursor move.
		if !selected {
			if cached, ok := m.rowCache[actualIdx]; ok && cached.width == boxWidth {
				rows = append(rows, cached.content)
				continue
			}
		}

		rendered := renderRow(item, selected, m.filter)

		if !selected {
			if m.rowCache == nil {
				m.rowCache = make(map[int]cachedRow)
			}
			m.rowCache[actualIdx] = cachedRow{content: rendered, width: boxWidth}
		}

		rows = append(rows, rendered)
	}

	content := strings.Join(rows, "\n")

	box := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(style.Border).
		Width(boxWidth).
		Padding(0, 1).
		Render(content)

	return box
}

// renderRow renders a single completion row with icon, name (with fuzzy-match
// highlighting), and description. It is a package-level function so that
// item.go's RenderItem and the View loop share the same logic.
func renderRow(item CompletionItem, selected bool, filter string) string {
	var sb strings.Builder

	// Cursor / selection marker.
	if selected {
		sb.WriteString(style.PlanSelected.Render("▸ "))
	} else {
		sb.WriteString("  ")
	}

	// Optional icon; fall back to category icon.
	icon := item.Icon
	if icon == "" {
		icon = CategoryIcon(item.Category)
	}
	if selected {
		sb.WriteString(style.PlanSelected.Render(icon + " "))
	} else {
		sb.WriteString(style.Faint.Render(icon + " "))
	}

	// Name with fuzzy-match character highlighting.
	if selected {
		sb.WriteString(style.PlanSelected.Render(item.Name))
	} else {
		sb.WriteString(highlightName(item.Name, filter))
	}

	// Description.
	if item.Description != "" {
		pad := "  "
		desc := style.Faint.Render(pad + item.Description)
		sb.WriteString(desc)
	}

	return sb.String()
}

// highlightName renders name with matched characters in Secondary style and
// unmatched characters in Faint style. Match is case-insensitive substring.
func highlightName(name, filter string) string {
	if filter == "" {
		return lipgloss.NewStyle().Foreground(style.Muted).Render(name)
	}

	lower := strings.ToLower(name)
	q := strings.ToLower(filter)

	idx := strings.Index(lower, q)
	if idx == -1 {
		return lipgloss.NewStyle().Foreground(style.Muted).Render(name)
	}

	before := lipgloss.NewStyle().Foreground(style.Muted).Render(name[:idx])
	match := lipgloss.NewStyle().Foreground(style.Secondary).Bold(true).Render(name[idx : idx+len(filter)])
	after := lipgloss.NewStyle().Foreground(style.Muted).Render(name[idx+len(filter):])
	return before + match + after
}
