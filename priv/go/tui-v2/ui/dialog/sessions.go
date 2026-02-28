package dialog

import (
	"fmt"
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/miosa/osa-tui/style"
)

// SessionEntry describes a single chat session shown in the browser.
type SessionEntry struct {
	ID           string
	Title        string
	CreatedAt    string
	MessageCount int
	Active       bool // currently open session
}

// SessionsModel is a filterable, scrollable session browser dialog.
//
// Emits SessionAction messages for switch / rename / delete / create.
// Pressing Esc emits nothing and the caller should dismiss the dialog.
type SessionsModel struct {
	sessions    []SessionEntry
	filtered    []SessionEntry
	cursor      int
	filterText  string
	renaming    bool
	renameInput InputCursor
	delConfirm  bool // waiting for delete confirmation

	width, height int
	pageSize      int
	offset        int
}

// NewSessions returns a zero-value SessionsModel.
func NewSessions() SessionsModel {
	return SessionsModel{pageSize: 14}
}

// SetSessions populates the browser and resets filter/cursor state.
func (m *SessionsModel) SetSessions(sessions []SessionEntry) {
	m.sessions = sessions
	m.filterText = ""
	m.applyFilter()
	m.cursor = 0
	m.offset = 0
	// Pre-position cursor on the active session.
	for i, s := range m.filtered {
		if s.Active {
			m.cursor = i
			m.scrollToCursor()
			break
		}
	}
}

// SetSize updates terminal dimensions.
func (m *SessionsModel) SetSize(w, h int) {
	m.width = w
	m.height = h
	m.pageSize = h - 12
	if m.pageSize < 4 {
		m.pageSize = 4
	}
}

// ──────────────────────────────────────────────────────────────────────────────
// Update
// ──────────────────────────────────────────────────────────────────────────────

// Update handles keyboard input for the session browser.
//
// Normal mode:
//
//	↑/k      → move cursor up
//	↓/j      → move cursor down
//	enter    → switch to selected session
//	r        → begin rename (inline input)
//	d/delete → prompt delete confirmation
//	n        → create new session
//	esc      → dismiss dialog (no action emitted)
//	any char → append to filter
//	backspace → remove last filter char
//
// Rename mode:
//
//	enter → confirm rename
//	esc   → cancel rename
//	char  → edit rename input
//
// Delete confirmation mode:
//
//	y / enter → confirm delete
//	n / esc   → cancel
func (m SessionsModel) Update(msg tea.Msg) (SessionsModel, tea.Cmd) {
	kp, ok := msg.(tea.KeyPressMsg)
	if !ok {
		return m, nil
	}

	// Rename mode.
	if m.renaming {
		return m.updateRenaming(kp)
	}

	// Delete confirmation mode.
	if m.delConfirm {
		return m.updateDeleteConfirm(kp)
	}

	// Normal navigation mode.
	return m.updateNormal(kp)
}

func (m SessionsModel) updateRenaming(kp tea.KeyPressMsg) (SessionsModel, tea.Cmd) {
	switch kp.Code {
	case tea.KeyEnter:
		if m.cursor < len(m.filtered) {
			entry := m.filtered[m.cursor]
			newName := strings.TrimSpace(m.renameInput.Value)
			m.renaming = false
			if newName == "" || newName == entry.Title {
				return m, nil
			}
			id := entry.ID
			return m, func() tea.Msg {
				return SessionAction{Action: "rename", SessionID: id, NewName: newName}
			}
		}
		m.renaming = false
		return m, nil

	case tea.KeyEscape:
		m.renaming = false
		return m, nil

	case tea.KeyBackspace:
		m.renameInput.Backspace()
		return m, nil

	case tea.KeyLeft:
		if m.renameInput.Cursor > 0 {
			m.renameInput.Cursor--
		}
		return m, nil

	case tea.KeyRight:
		if m.renameInput.Cursor < len([]rune(m.renameInput.Value)) {
			m.renameInput.Cursor++
		}
		return m, nil

	default:
		if kp.Code >= 32 && kp.Code != tea.KeyDelete {
			m.renameInput.Insert(rune(kp.Code))
		}
		return m, nil
	}
}

func (m SessionsModel) updateDeleteConfirm(kp tea.KeyPressMsg) (SessionsModel, tea.Cmd) {
	switch kp.Code {
	case 'y', tea.KeyEnter:
		m.delConfirm = false
		if m.cursor < len(m.filtered) {
			id := m.filtered[m.cursor].ID
			return m, func() tea.Msg {
				return SessionAction{Action: "delete", SessionID: id}
			}
		}
		return m, nil

	default:
		m.delConfirm = false
		return m, nil
	}
}

func (m SessionsModel) updateNormal(kp tea.KeyPressMsg) (SessionsModel, tea.Cmd) {
	switch kp.Code {
	case tea.KeyUp, 'k':
		if m.cursor > 0 {
			m.cursor--
			m.scrollToCursor()
		}
		return m, nil

	case tea.KeyDown, 'j':
		if m.cursor < len(m.filtered)-1 {
			m.cursor++
			m.scrollToCursor()
		}
		return m, nil

	case tea.KeyEnter:
		if m.cursor < len(m.filtered) {
			id := m.filtered[m.cursor].ID
			return m, func() tea.Msg {
				return SessionAction{Action: "switch", SessionID: id}
			}
		}
		return m, nil

	case 'r':
		if m.cursor < len(m.filtered) {
			m.renaming = true
			m.renameInput = InputCursor{Focused: true}
			m.renameInput.SetValue(m.filtered[m.cursor].Title)
		}
		return m, nil

	case 'd', tea.KeyDelete:
		if m.cursor < len(m.filtered) {
			m.delConfirm = true
		}
		return m, nil

	case 'n':
		return m, func() tea.Msg {
			return SessionAction{Action: "create"}
		}

	case tea.KeyEscape:
		// Signal caller to dismiss; no action emitted.
		return m, nil

	case tea.KeyBackspace:
		if len(m.filterText) > 0 {
			runes := []rune(m.filterText)
			m.filterText = string(runes[:len(runes)-1])
			m.applyFilter()
		}
		return m, nil

	default:
		// Any printable rune appends to the filter.
		if kp.Code >= 32 && kp.Code != tea.KeyDelete && kp.Code < 127 {
			m.filterText += string(rune(kp.Code))
			m.applyFilter()
		}
		return m, nil
	}
}

func (m *SessionsModel) applyFilter() {
	if m.filterText == "" {
		m.filtered = make([]SessionEntry, len(m.sessions))
		copy(m.filtered, m.sessions)
		return
	}
	q := strings.ToLower(m.filterText)
	m.filtered = m.filtered[:0]
	for _, s := range m.sessions {
		if strings.Contains(strings.ToLower(s.Title), q) ||
			strings.Contains(strings.ToLower(s.ID), q) {
			m.filtered = append(m.filtered, s)
		}
	}
	m.cursor = 0
	m.offset = 0
}

func (m *SessionsModel) scrollToCursor() {
	if m.cursor < m.offset {
		m.offset = m.cursor
	}
	if m.cursor >= m.offset+m.pageSize {
		m.offset = m.cursor - m.pageSize + 1
	}
	if m.offset < 0 {
		m.offset = 0
	}
}

// ──────────────────────────────────────────────────────────────────────────────
// View
// ──────────────────────────────────────────────────────────────────────────────

// View renders the session browser dialog.
func (m SessionsModel) View() string {
	dw := m.width - 4
	if dw > 80 {
		dw = 80
	}
	if dw < 40 {
		dw = 40
	}

	var sb strings.Builder

	// Title.
	sb.WriteString(GradientTitle("Sessions"))
	sb.WriteByte('\n')
	sb.WriteString(style.DiffContext.Render(strings.Repeat("─", dw-6)))
	sb.WriteByte('\n')

	// Filter box.
	filterPrompt := style.DialogHelpKey.Render("Filter: ")
	filterVal := m.filterText
	if filterVal == "" {
		filterVal = style.Faint.Render("type to filter...")
	} else {
		filterVal = lipgloss.NewStyle().Foreground(style.Secondary).Render(filterVal)
	}
	sb.WriteString(filterPrompt + filterVal)
	sb.WriteByte('\n')
	sb.WriteString(style.DiffContext.Render(strings.Repeat("─", dw-6)))
	sb.WriteByte('\n')

	// Delete confirmation banner.
	if m.delConfirm && m.cursor < len(m.filtered) {
		entry := m.filtered[m.cursor]
		warning := style.ErrorText.Render(
			fmt.Sprintf("Delete \"%s\"? ", entry.Title))
		hint := style.DialogHelp.Render("y to confirm · any key to cancel")
		sb.WriteString(warning + hint)
		sb.WriteByte('\n')
		sb.WriteString(style.DiffContext.Render(strings.Repeat("─", dw-6)))
		sb.WriteByte('\n')
	}

	// Session list.
	if len(m.filtered) == 0 {
		sb.WriteString(style.Faint.Render("  No sessions found"))
		sb.WriteByte('\n')
	} else {
		end := m.offset + m.pageSize
		if end > len(m.filtered) {
			end = len(m.filtered)
		}
		if m.offset > 0 {
			sb.WriteString(style.Faint.Render("  ↑ more above"))
			sb.WriteByte('\n')
		}
		for i := m.offset; i < end; i++ {
			entry := m.filtered[i]
			isCursor := i == m.cursor
			sb.WriteString(m.renderEntry(entry, isCursor))
			sb.WriteByte('\n')
		}
		if end < len(m.filtered) {
			sb.WriteString(style.Faint.Render("  ↓ more below"))
			sb.WriteByte('\n')
		}
	}

	// Inline rename input.
	if m.renaming {
		sb.WriteString(style.DiffContext.Render(strings.Repeat("─", dw-6)))
		sb.WriteByte('\n')
		prompt := style.DialogHelpKey.Render("Rename: ")
		sb.WriteString(prompt + m.renameInput.View())
		sb.WriteByte('\n')
	}

	// Help bar.
	helpItems := []HelpItem{
		{Key: "↑↓", Desc: "navigate"},
		{Key: "enter", Desc: "switch"},
		{Key: "r", Desc: "rename"},
		{Key: "d", Desc: "delete"},
		{Key: "n", Desc: "new"},
		{Key: "esc", Desc: "close"},
	}
	sb.WriteString(style.DiffContext.Render(strings.Repeat("─", dw-6)))
	sb.WriteByte('\n')
	sb.WriteString(RenderHelpBar(helpItems, dw-6))

	frameStyle := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(style.Border).
		Padding(1, 2).
		Width(dw)

	termW := m.width
	if termW <= 0 {
		termW = 80
	}
	termH := m.height
	if termH <= 0 {
		termH = 40
	}

	box := frameStyle.Render(sb.String())
	return lipgloss.Place(termW, termH, lipgloss.Center, lipgloss.Center, box)
}

// renderEntry renders a single session row.
func (m SessionsModel) renderEntry(entry SessionEntry, isCursor bool) string {
	cursor := "  "
	if isCursor {
		cursor = style.PlanSelected.Render("> ")
	}

	var active string
	if entry.Active {
		active = style.RadioOn.Render("● ")
	} else {
		active = style.RadioOff.Render("○ ")
	}

	var title string
	if isCursor {
		title = lipgloss.NewStyle().Foreground(style.Secondary).Bold(true).Render(entry.Title)
	} else {
		title = style.Faint.Render(entry.Title)
	}

	var meta string
	if entry.CreatedAt != "" || entry.MessageCount > 0 {
		parts := []string{}
		if entry.CreatedAt != "" {
			parts = append(parts, entry.CreatedAt)
		}
		if entry.MessageCount > 0 {
			parts = append(parts, fmt.Sprintf("%d msgs", entry.MessageCount))
		}
		meta = style.Faint.Render("  " + strings.Join(parts, " · "))
	}

	return cursor + active + title + meta
}
