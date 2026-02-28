package model

import (
	"strings"

	"github.com/charmbracelet/bubbles/key"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/miosa/osa-tui/style"
)

// PaletteExecuteMsg is sent when the user selects a command.
type PaletteExecuteMsg struct {
	Command string
}

// PaletteDismissMsg is sent when the user closes the palette.
type PaletteDismissMsg struct{}

// PaletteItem is a single entry in the command palette.
type PaletteItem struct {
	Name        string // e.g. "/help"
	Description string // e.g. "Show available commands"
	Category    string // e.g. "system"
}

// filterValue returns the string used for matching.
func (p PaletteItem) filterValue() string {
	return p.Name + " " + p.Description + " " + p.Category
}

// PaletteModel is a filterable command palette overlay.
type PaletteModel struct {
	active   bool
	filter   textinput.Model
	items    []PaletteItem
	filtered []PaletteItem
	cursor   int
	width    int
	height   int
}

// NewPalette constructs a PaletteModel.
func NewPalette() PaletteModel {
	ti := textinput.New()
	ti.Placeholder = "Type to filter..."
	ti.Prompt = "> "
	ti.PromptStyle = lipgloss.NewStyle().Foreground(style.Primary)
	return PaletteModel{filter: ti}
}

const maxVisible = 12

// Open activates the palette with a list of commands.
func (m *PaletteModel) Open(items []PaletteItem, width, height int) tea.Cmd {
	m.active = true
	m.items = items
	m.filtered = items
	m.cursor = 0
	m.width = width
	m.height = height
	m.filter.SetValue("")
	m.filter.Width = width/2 - 6
	return m.filter.Focus()
}

// IsActive reports whether the palette overlay is visible.
func (m PaletteModel) IsActive() bool { return m.active }

// Update handles keyboard events for the palette.
func (m PaletteModel) Update(msg tea.Msg) (PaletteModel, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch {
		case key.Matches(msg, key.NewBinding(key.WithKeys("esc"))):
			m.active = false
			m.filter.Blur()
			return m, func() tea.Msg { return PaletteDismissMsg{} }

		case key.Matches(msg, key.NewBinding(key.WithKeys("enter"))):
			if len(m.filtered) > 0 && m.cursor < len(m.filtered) {
				cmd := m.filtered[m.cursor].Name
				m.active = false
				m.filter.Blur()
				return m, func() tea.Msg { return PaletteExecuteMsg{Command: cmd} }
			}
			return m, nil

		case key.Matches(msg, key.NewBinding(key.WithKeys("up"))):
			if m.cursor > 0 {
				m.cursor--
			}
			return m, nil

		case key.Matches(msg, key.NewBinding(key.WithKeys("down"))):
			if m.cursor < len(m.filtered)-1 {
				m.cursor++
			}
			return m, nil

		case key.Matches(msg, key.NewBinding(key.WithKeys("ctrl+c"))):
			m.active = false
			m.filter.Blur()
			return m, func() tea.Msg { return PaletteDismissMsg{} }
		}
	}

	// Forward to textinput for character handling
	prevVal := m.filter.Value()
	var cmd tea.Cmd
	m.filter, cmd = m.filter.Update(msg)
	if m.filter.Value() != prevVal {
		m.applyFilter()
	}
	return m, cmd
}

// applyFilter filters items by substring match on the filter value.
func (m *PaletteModel) applyFilter() {
	query := strings.ToLower(m.filter.Value())
	if query == "" {
		m.filtered = m.items
		m.cursor = 0
		return
	}
	var results []PaletteItem
	for _, item := range m.items {
		if strings.Contains(strings.ToLower(item.filterValue()), query) {
			results = append(results, item)
		}
	}
	m.filtered = results
	m.cursor = 0
}

// View renders the palette as a centered overlay.
func (m PaletteModel) View() string {
	if !m.active {
		return ""
	}

	boxWidth := m.width / 2
	if boxWidth < 50 {
		boxWidth = 50
	}
	if boxWidth > m.width-4 {
		boxWidth = m.width - 4
	}

	var sb strings.Builder

	// Title
	title := lipgloss.NewStyle().Foreground(style.Primary).Bold(true).Render("Command Palette")
	sb.WriteString(title)
	sb.WriteByte('\n')

	// Filter input
	sb.WriteString(m.filter.View())
	sb.WriteByte('\n')

	// Separator
	sb.WriteString(lipgloss.NewStyle().Foreground(style.Border).Render(strings.Repeat("─", boxWidth-4)))
	sb.WriteByte('\n')

	// Items
	visible := m.filtered
	if len(visible) > maxVisible {
		// Show items around cursor
		start := m.cursor - maxVisible/2
		if start < 0 {
			start = 0
		}
		end := start + maxVisible
		if end > len(visible) {
			end = len(visible)
			start = end - maxVisible
			if start < 0 {
				start = 0
			}
		}
		visible = visible[start:end]
	}

	if len(visible) == 0 {
		sb.WriteString(lipgloss.NewStyle().Foreground(style.Muted).Render("  No matching commands"))
	}

	for i, item := range visible {
		// Determine actual index in filtered list for cursor comparison
		actualIdx := i
		if len(m.filtered) > maxVisible {
			start := m.cursor - maxVisible/2
			if start < 0 {
				start = 0
			}
			if start+maxVisible > len(m.filtered) {
				start = len(m.filtered) - maxVisible
				if start < 0 {
					start = 0
				}
			}
			actualIdx = start + i
		}

		isCursor := actualIdx == m.cursor

		var line string
		if isCursor {
			marker := lipgloss.NewStyle().Foreground(style.Primary).Bold(true).Render("> ")
			name := lipgloss.NewStyle().Foreground(style.Secondary).Bold(true).Render(item.Name)
			desc := lipgloss.NewStyle().Foreground(style.Muted).Render("  " + item.Description)
			line = marker + name + desc
		} else {
			name := lipgloss.NewStyle().Foreground(style.Secondary).Render(item.Name)
			desc := lipgloss.NewStyle().Foreground(style.Dim).Render("  " + item.Description)
			line = "  " + name + desc
		}

		if item.Category != "" {
			cat := lipgloss.NewStyle().Foreground(style.Dim).Render("  [" + item.Category + "]")
			line += cat
		}

		sb.WriteString(line)
		if i < len(visible)-1 {
			sb.WriteByte('\n')
		}
	}

	if len(m.filtered) > maxVisible {
		sb.WriteByte('\n')
		sb.WriteString(lipgloss.NewStyle().Foreground(style.Muted).Render(
			"  ... and more (type to filter)"))
	}

	// Wrap in a rounded border box and center
	boxStyle := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(style.Border).
		Padding(1, 2).
		Width(boxWidth)

	box := boxStyle.Render(sb.String())
	return lipgloss.Place(m.width, m.height, lipgloss.Center, lipgloss.Center, box)
}
