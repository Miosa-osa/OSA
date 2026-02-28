// Package input provides the OSA TUI v2 multi-line input component.
//
// Features:
//   - Multi-line textarea (alt+enter inserts newline, enter submits)
//   - Command history (up/down when single-line)
//   - Tab-cycle completion (legacy fallback)
//   - Completions popup integration (ui/completions)
//   - File attachment chips (ui/attachments)
//   - Character-count indicator when approaching limit
//   - Line-count indicator for multi-line content
//   - Focused/blurred prompt character rendering
package input

import (
	"fmt"
	"strings"

	"charm.land/bubbles/v2/key"
	"charm.land/bubbles/v2/textarea"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/miosa/osa-tui/style"
	"github.com/miosa/osa-tui/ui/attachments"
	"github.com/miosa/osa-tui/ui/completions"
)

const (
	charLimit        = 1000
	charWarnAt       = 800 // show counter once this many chars are used
	maxHistoryHeight = 6
)

// Model wraps a textarea for multi-line input with history, tab completion,
// completions popup, and file attachments.
type Model struct {
	ta          textarea.Model
	history     []string
	historyIdx  int
	commands    []string // slash-commands for tab-cycle completion
	tabIdx      int
	tabMatches  []string
	width       int
	multiline   bool
	completions completions.Model
	attachs     attachments.Model
}

// New returns a configured input Model ready for use.
func New() Model {
	ta := textarea.New()
	ta.Prompt = ""
	ta.Placeholder = "Ask anything, or type / for commands..."
	ta.CharLimit = charLimit
	ta.ShowLineNumbers = false
	ta.SetWidth(76)
	ta.SetHeight(1)
	ta.MaxHeight = maxHistoryHeight

	// Strip cursor-line highlight to keep single-line look.
	s := ta.Styles()
	s.Focused.CursorLine = lipgloss.NewStyle()
	s.Blurred.CursorLine = lipgloss.NewStyle()
	ta.SetStyles(s)

	// Alt+Enter inserts a newline; bare Enter is intercepted by the parent
	// model to trigger submission.
	ta.KeyMap.InsertNewline = key.NewBinding(key.WithKeys("alt+enter"))

	return Model{
		ta:          ta,
		historyIdx:  0,
		tabIdx:      -1,
		width:       80,
		completions: completions.New(),
		attachs:     attachments.New(),
	}
}

// ─── Public accessors ───────────────────────────────────────────────────────

// SetCommands sets the slash-commands available for tab-cycle completion.
func (m *Model) SetCommands(cmds []string) { m.commands = cmds }

// SetWidth constrains the input area to the given terminal width.
func (m *Model) SetWidth(w int) {
	m.width = w
	m.ta.SetWidth(w - 4) // reserve 4 cols for prompt + right margin
	m.attachs.SetWidth(w)
}

// Focus grants keyboard focus to the textarea and returns the init command.
func (m Model) Focus() tea.Cmd { return m.ta.Focus() }

// Blur removes keyboard focus from the textarea.
func (m *Model) Blur() { m.ta.Blur() }

// IsFocused reports whether the textarea currently has keyboard focus.
func (m Model) IsFocused() bool { return m.ta.Focused() }

// Value returns the current textarea content.
func (m Model) Value() string { return m.ta.Value() }

// SetValue sets the textarea content and recalculates height.
func (m *Model) SetValue(s string) {
	m.ta.SetValue(s)
	m.updateHeight()
}

// Reset clears the input, resets history navigation, and hides the completions popup.
func (m *Model) Reset() {
	m.historyIdx = len(m.history)
	m.ta.SetValue("")
	m.multiline = false
	m.ta.SetHeight(1)
	m.resetTab()
	m.completions.Hide()
}

// Submit records text in history and then resets the input.
func (m *Model) Submit(text string) {
	if text != "" {
		m.history = append(m.history, text)
	}
	m.Reset()
}

// ClearInput clears content without recording history.
func (m *Model) ClearInput() {
	m.ta.SetValue("")
	m.multiline = false
	m.ta.SetHeight(1)
	m.resetTab()
	m.completions.Hide()
}

// ─── Completions popup ──────────────────────────────────────────────────────

// SetCompletions stores the items available in the completions popup.
// The popup remains hidden until the user types a "/" prefix.
func (m *Model) SetCompletions(items []completions.CompletionItem) {
	m.completions.SetItems(items)
}

// ShowCompletions makes the completions popup visible, pre-filtered to the
// current input value.
func (m *Model) ShowCompletions() {
	filter := ""
	if v := m.ta.Value(); strings.HasPrefix(v, "/") {
		filter = strings.TrimPrefix(v, "/")
	}
	m.completions.Show(nil, filter, m.width)
}

// HideCompletions dismisses the completions popup.
func (m *Model) HideCompletions() { m.completions.Hide() }

// ─── Attachments ─────────────────────────────────────────────────────────────

// AttachFile adds a file to the attachment list. Returns an error if the path
// is invalid, a directory, or already attached.
func (m *Model) AttachFile(path string) error {
	return m.attachs.Add(path)
}

// ClearAttachments removes all file attachments.
func (m *Model) ClearAttachments() { m.attachs.Clear() }

// Attachments returns the absolute paths of all currently attached files.
func (m Model) Attachments() []string { return m.attachs.Paths() }

// ─── Update ──────────────────────────────────────────────────────────────────

// Update handles messages. Key events are tea.KeyPressMsg in bubbletea v2.
func (m Model) Update(msg tea.Msg) (Model, tea.Cmd) {
	// ── Route to completions popup first when visible ──────────────────────
	if m.completions.IsVisible() {
		var popupCmd tea.Cmd
		m.completions, popupCmd = m.completions.Update(msg)
		if popupCmd != nil {
			// Completions consumed the event (selection or dismiss).
			return m, popupCmd
		}
	}

	// ── Route to attachments delete-mode when active ───────────────────────
	if m.attachs.InDeleteMode() {
		var aCmd tea.Cmd
		m.attachs, aCmd = m.attachs.Update(msg)
		return m, aCmd
	}

	switch msg := msg.(type) {
	case tea.KeyPressMsg:
		k := msg.Code
		switch {
		// History navigation — only in single-line mode.
		case k == tea.KeyUp && !m.multiline && !m.completions.IsVisible():
			m = m.navigateHistory(-1)
			return m, nil

		case k == tea.KeyDown && !m.multiline && !m.completions.IsVisible():
			m = m.navigateHistory(+1)
			return m, nil

		// Tab-cycle completion.
		case k == tea.KeyTab:
			m = m.cycleComplete()
			return m, nil

		// Auto-show completions popup when user types a printable character
		// or deletes, so the popup tracks the current "/" prefix.
		case k >= ' ' || k == tea.KeyBackspace || k == tea.KeyDelete:
			m.resetTab()
			// Let the textarea handle the key first, then re-evaluate.
			var cmd tea.Cmd
			m.ta, cmd = m.ta.Update(msg)
			m.updateHeight()
			m.autoShowCompletions()
			return m, cmd

		default:
			m.resetTab()
		}

	// Completions popup: item selected → fill input.
	case completions.SelectedMsg:
		m.ta.SetValue(msg.Item.Name)
		m.updateHeight()
		m.completions.Hide()
		return m, nil

	// Completions popup: dismissed.
	case completions.DismissMsg:
		m.completions.Hide()
		return m, nil

	// Attachments: file removed.
	case attachments.RemovedMsg:
		// No extra action needed; attachments model already updated.
		return m, nil
	}

	var cmd tea.Cmd
	m.ta, cmd = m.ta.Update(msg)
	m.updateHeight()
	return m, cmd
}

// ─── View ────────────────────────────────────────────────────────────────────

// View renders:
//  1. Attachment chips row (if any files attached)
//  2. Completions popup (if visible), rendered above the separator
//  3. Horizontal separator
//  4. Prompt character + textarea + char-count / line-count hint
func (m Model) View() string {
	w := m.width
	if w < 10 {
		w = 80
	}

	var sb strings.Builder

	// Attachment chips.
	if !m.attachs.IsEmpty() {
		sb.WriteString(m.attachs.View())
		sb.WriteByte('\n')
	}

	// Completions popup (lives above the separator).
	if m.completions.IsVisible() {
		popup := m.completions.View()
		if popup != "" {
			sb.WriteString(popup)
			sb.WriteByte('\n')
		}
	}

	// Separator.
	sep := lipgloss.NewStyle().Foreground(style.Border).Render(strings.Repeat("─", w))
	sb.WriteString(sep)
	sb.WriteByte('\n')

	// Prompt character — brighter when focused.
	var prompt string
	if m.ta.Focused() {
		prompt = style.PromptChar.Render("❯ ")
	} else {
		prompt = style.Faint.Render("❯ ")
	}
	sb.WriteString(prompt)
	sb.WriteString(m.ta.View())

	// Right-aligned hint: char count or line indicator.
	hint := m.hintText()
	if hint != "" {
		sb.WriteString(hint)
	}

	return sb.String()
}

// ─── Internal helpers ────────────────────────────────────────────────────────

// hintText builds the trailing hint: char count when approaching limit,
// line count when multi-line.
func (m Model) hintText() string {
	val := m.ta.Value()
	chars := len([]rune(val))

	if m.multiline {
		lines := strings.Count(val, "\n") + 1
		return " " + style.Hint.Render(fmt.Sprintf("[%d lines · alt+enter newline]", lines))
	}

	if chars >= charWarnAt {
		remaining := charLimit - chars
		var cs lipgloss.Style
		if remaining <= 50 {
			cs = lipgloss.NewStyle().Foreground(style.Error)
		} else {
			cs = lipgloss.NewStyle().Foreground(style.Warning)
		}
		return " " + cs.Render(fmt.Sprintf("%d/%d", chars, charLimit))
	}

	return ""
}

// updateHeight adjusts textarea height based on newline count.
func (m *Model) updateHeight() {
	val := m.ta.Value()
	m.multiline = strings.Contains(val, "\n")
	if m.multiline {
		h := strings.Count(val, "\n") + 1
		if h > maxHistoryHeight {
			h = maxHistoryHeight
		}
		m.ta.SetHeight(h)
	} else {
		m.ta.SetHeight(1)
	}
}

// resetTab clears tab-cycle completion state.
func (m *Model) resetTab() {
	m.tabIdx = -1
	m.tabMatches = nil
}

// autoShowCompletions shows/updates the completions popup when the current
// input starts with "/", or hides it otherwise.
func (m *Model) autoShowCompletions() {
	v := m.ta.Value()
	if strings.HasPrefix(v, "/") {
		filter := strings.TrimPrefix(v, "/")
		if m.completions.IsVisible() {
			m.completions.SetFilter(filter)
		} else {
			m.completions.Show(nil, filter, m.width)
		}
	} else {
		m.completions.Hide()
	}
}

// navigateHistory moves through command history by delta (-1=older, +1=newer).
func (m Model) navigateHistory(delta int) Model {
	if len(m.history) == 0 {
		return m
	}
	next := m.historyIdx + delta
	if next < 0 {
		next = 0
	}
	if next > len(m.history) {
		next = len(m.history)
	}
	m.historyIdx = next
	if next == len(m.history) {
		m.ta.SetValue("")
	} else {
		m.ta.SetValue(m.history[next])
	}
	m.updateHeight()
	return m
}

// cycleComplete cycles through tab-completion matches for the current slash input.
func (m Model) cycleComplete() Model {
	current := m.ta.Value()
	if !strings.HasPrefix(current, "/") {
		return m
	}
	if m.tabIdx == -1 || m.tabMatches == nil {
		m.tabMatches = matchCommands(m.commands, current)
		if len(m.tabMatches) == 0 {
			return m
		}
		m.tabIdx = 0
	} else {
		m.tabIdx = (m.tabIdx + 1) % len(m.tabMatches)
	}
	m.ta.SetValue(m.tabMatches[m.tabIdx])
	return m
}

// matchCommands returns commands that have the given prefix.
func matchCommands(commands []string, prefix string) []string {
	var out []string
	for _, c := range commands {
		if strings.HasPrefix(c, prefix) {
			out = append(out, c)
		}
	}
	return out
}
