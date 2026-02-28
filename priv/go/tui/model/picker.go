package model

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/miosa/osa-tui/style"
)

// PickerItem is a single entry in the model picker.
type PickerItem struct {
	Name     string
	Provider string
	Size     int64
	Active   bool
}

// PickerChoice is emitted when the user selects a model.
type PickerChoice struct {
	Name     string
	Provider string
}

// PickerCancel is emitted when the user presses Esc.
type PickerCancel struct{}

// PickerModel renders a vertical list of models with arrow-key navigation.
type PickerModel struct {
	items    []PickerItem
	cursor   int
	active   bool
	width    int
	offset   int // scroll offset for long lists
	pageSize int // visible items per page
}

// NewPicker returns a zero-value PickerModel.
func NewPicker() PickerModel {
	return PickerModel{pageSize: 12}
}

// SetItems populates the picker and activates it.
func (m *PickerModel) SetItems(items []PickerItem) {
	m.items = items
	m.cursor = 0
	m.offset = 0
	m.active = true
	// Start cursor on the active model
	for i, item := range items {
		if item.Active {
			m.cursor = i
			// Ensure active item is visible
			if m.cursor >= m.pageSize {
				m.offset = m.cursor - m.pageSize/2
				if m.offset+m.pageSize > len(m.items) {
					m.offset = len(m.items) - m.pageSize
				}
				if m.offset < 0 {
					m.offset = 0
				}
			}
			break
		}
	}
}

// Clear deactivates the picker.
func (m *PickerModel) Clear() {
	m.active = false
	m.items = nil
	m.cursor = 0
	m.offset = 0
}

// IsActive reports whether the picker is currently visible.
func (m PickerModel) IsActive() bool {
	return m.active
}

// SetWidth constrains the picker to the terminal width.
func (m *PickerModel) SetWidth(w int) {
	m.width = w
}

// Init satisfies tea.Model.
func (m PickerModel) Init() tea.Cmd {
	return nil
}

// Update handles keyboard input when the picker is active.
func (m PickerModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	if !m.active || len(m.items) == 0 {
		return m, nil
	}

	keyMsg, ok := msg.(tea.KeyMsg)
	if !ok {
		return m, nil
	}

	switch keyMsg.Type {
	case tea.KeyUp:
		if m.cursor > 0 {
			m.cursor--
			if m.cursor < m.offset {
				m.offset = m.cursor
			}
		} else {
			// Wrap to bottom
			m.cursor = len(m.items) - 1
			if m.cursor >= m.offset+m.pageSize {
				m.offset = m.cursor - m.pageSize + 1
			}
		}

	case tea.KeyDown:
		if m.cursor < len(m.items)-1 {
			m.cursor++
			if m.cursor >= m.offset+m.pageSize {
				m.offset = m.cursor - m.pageSize + 1
			}
		} else {
			// Wrap to top
			m.cursor = 0
			m.offset = 0
		}

	case tea.KeyEnter:
		item := m.items[m.cursor]
		m.Clear()
		return m, func() tea.Msg {
			return PickerChoice{Name: item.Name, Provider: item.Provider}
		}

	case tea.KeyEsc:
		m.Clear()
		return m, func() tea.Msg { return PickerCancel{} }
	}

	return m, nil
}

// View renders the picker panel.
func (m PickerModel) View() string {
	if !m.active || len(m.items) == 0 {
		return ""
	}

	innerWidth := m.width - 6
	if innerWidth < 40 {
		innerWidth = 60
	}

	var sb strings.Builder

	// Header
	header := lipgloss.NewStyle().
		Foreground(style.Primary).
		Bold(true).
		Render("◈ Select Model")
	hint := lipgloss.NewStyle().
		Foreground(style.Muted).
		Render("  ↑↓ navigate · Enter select · Esc cancel")
	sb.WriteString(header + hint + "\n\n")

	// Determine visible range
	end := m.offset + m.pageSize
	if end > len(m.items) {
		end = len(m.items)
	}

	// Scroll indicator (top)
	if m.offset > 0 {
		sb.WriteString(lipgloss.NewStyle().Foreground(style.Muted).Render("  ↑ more above") + "\n")
	}

	// Group items by provider for display
	lastProvider := ""
	for i := m.offset; i < end; i++ {
		item := m.items[i]

		// Provider header
		if item.Provider != lastProvider {
			lastProvider = item.Provider
			provLabel := lipgloss.NewStyle().
				Foreground(style.Secondary).
				Bold(true).
				Render("  " + item.Provider)
			sb.WriteString(provLabel + "\n")
		}

		// Item line
		isCursor := (i == m.cursor)
		sb.WriteString(m.renderItem(item, isCursor))
		sb.WriteString("\n")
	}

	// Scroll indicator (bottom)
	if end < len(m.items) {
		sb.WriteString(lipgloss.NewStyle().Foreground(style.Muted).Render("  ↓ more below") + "\n")
	}

	// Count
	countText := lipgloss.NewStyle().
		Foreground(style.Muted).
		Render(fmt.Sprintf("\n  %d model(s) available", len(m.items)))
	sb.WriteString(countText)

	// Wrap in border
	boxStyle := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(style.Border).
		Padding(0, 1)
	if m.width > 0 {
		boxStyle = boxStyle.Width(m.width - 2)
	}

	return boxStyle.Render(sb.String())
}

// renderItem renders a single model line.
func (m PickerModel) renderItem(item PickerItem, isCursor bool) string {
	// Cursor indicator
	var cursor string
	if isCursor {
		cursor = lipgloss.NewStyle().Foreground(style.Primary).Bold(true).Render("  > ")
	} else {
		cursor = "    "
	}

	// Active marker
	var marker string
	if item.Active {
		marker = lipgloss.NewStyle().Foreground(style.Success).Render("●")
	} else {
		marker = lipgloss.NewStyle().Foreground(style.Muted).Render("○")
	}

	// Model name
	nameStyle := lipgloss.NewStyle()
	if isCursor {
		nameStyle = nameStyle.Bold(true)
	}
	name := nameStyle.Render(item.Name)

	// Size badge (for Ollama models with known size)
	var sizeBadge string
	if item.Size > 0 {
		gb := float64(item.Size) / 1e9
		sizeBadge = lipgloss.NewStyle().
			Foreground(style.Muted).
			Render(fmt.Sprintf("  %.1f GB", gb))
	}

	// Active label
	var activeLabel string
	if item.Active {
		activeLabel = lipgloss.NewStyle().
			Foreground(style.Success).
			Render("  active")
	}

	return cursor + marker + " " + name + sizeBadge + activeLabel
}
