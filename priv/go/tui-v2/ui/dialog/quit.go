package dialog

import (
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/miosa/osa-tui/style"
)

// QuitModel is a simple two-button confirmation dialog.
//
// Emits QuitConfirmed or QuitCancelled.
type QuitModel struct {
	activeBtn int // 0=Quit, 1=Cancel
	width     int
	height    int
}

// NewQuit returns a QuitModel with Cancel pre-selected (safer default).
func NewQuit() QuitModel {
	return QuitModel{activeBtn: 1}
}

// SetWidth constrains the dialog to the terminal width.
func (m *QuitModel) SetWidth(w int) { m.width = w }

// SetSize constrains the dialog to the terminal dimensions.
func (m *QuitModel) SetSize(w, h int) { m.width = w; m.height = h }

// ──────────────────────────────────────────────────────────────────────────────
// Update
// ──────────────────────────────────────────────────────────────────────────────

// Update handles keyboard input for the quit dialog.
//
//	q / enter (when Quit active)  → QuitConfirmed
//	esc / enter (when Cancel)     → QuitCancelled
//	← → / tab                     → cycle buttons
func (m QuitModel) Update(msg tea.Msg) (QuitModel, tea.Cmd) {
	kp, ok := msg.(tea.KeyPressMsg)
	if !ok {
		return m, nil
	}

	switch kp.Code {
	case 'q':
		return m, func() tea.Msg { return QuitConfirmed{} }

	case tea.KeyEscape:
		return m, func() tea.Msg { return QuitCancelled{} }

	case tea.KeyEnter:
		if m.activeBtn == 0 {
			return m, func() tea.Msg { return QuitConfirmed{} }
		}
		return m, func() tea.Msg { return QuitCancelled{} }

	case tea.KeyTab, tea.KeyRight:
		m.activeBtn = (m.activeBtn + 1) % 2
		return m, nil

	case tea.KeyLeft:
		m.activeBtn = (m.activeBtn + 1) % 2
		return m, nil
	}

	return m, nil
}

// ──────────────────────────────────────────────────────────────────────────────
// View
// ──────────────────────────────────────────────────────────────────────────────

// View renders the quit confirmation dialog centered in the terminal.
func (m QuitModel) View() string {
	dw := 42
	if m.width > 0 && m.width-4 < dw {
		dw = m.width - 4
	}
	if dw < 30 {
		dw = 30
	}

	var sb strings.Builder

	sb.WriteString(GradientTitle("Quit OSA"))
	sb.WriteByte('\n')
	sb.WriteString(style.DiffContext.Render(strings.Repeat("─", dw-6)))
	sb.WriteByte('\n')
	sb.WriteString(lipgloss.NewStyle().Foreground(style.Muted).Render("Are you sure you want to quit?"))
	sb.WriteByte('\n')
	sb.WriteByte('\n')

	buttons := []ButtonDef{
		{Label: "Quit (q)", Shortcut: "q", Active: m.activeBtn == 0, Danger: m.activeBtn == 0, Underline: 0},
		{Label: "Cancel (esc)", Shortcut: "esc", Active: m.activeBtn == 1, Underline: -1},
	}
	sb.WriteString(RenderButtons(buttons, dw-6))
	sb.WriteByte('\n')
	sb.WriteByte('\n')

	help := []HelpItem{
		{Key: "← →", Desc: "navigate"},
		{Key: "enter", Desc: "confirm"},
		{Key: "q", Desc: "quit"},
		{Key: "esc", Desc: "cancel"},
	}
	sb.WriteString(RenderHelpBar(help, dw-6))

	frameStyle := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(style.Warning).
		Padding(1, 2).
		Width(dw)

	termW := m.width
	if termW <= 0 {
		termW = 80
	}

	termH := m.height
	if termH <= 0 {
		termH = 24
	}
	box := frameStyle.Render(sb.String())
	return lipgloss.Place(termW, termH, lipgloss.Center, lipgloss.Center, box)
}
