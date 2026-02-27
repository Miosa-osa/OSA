package model

import (
	"strings"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/miosa/osa-tui/style"
)

// InputModel is the text-input bar with history navigation and command
// autocomplete.
//
// History navigation:
//   - Up arrow: walk backwards through submitted inputs
//   - Down arrow: walk forwards (towards the present)
//
// Autocomplete:
//   - Tab when the buffer starts with "/" cycles through matching commands
type InputModel struct {
	ti         textinput.Model
	history    []string
	historyIdx int // points one past the last entry when not navigating

	commands   []string // available slash commands, e.g. ["/commit", "/debug"]
	tabIdx     int      // current autocomplete cursor (-1 = none)
	tabMatches []string // current autocomplete candidate list
}

// NewInput returns a ready-to-use InputModel.
func NewInput() InputModel {
	ti := textinput.New()
	ti.Placeholder = "Ask anything, or type / for commands…"
	ti.CharLimit = 4096

	// historyIdx starts at 0; a fresh model has no history.
	return InputModel{
		ti:         ti,
		historyIdx: 0,
		tabIdx:     -1,
	}
}

// SetCommands replaces the command list used for Tab autocomplete.
func (m *InputModel) SetCommands(cmds []string) {
	m.commands = cmds
}

// Focus gives keyboard focus to the input.
func (m *InputModel) Focus() tea.Cmd {
	return m.ti.Focus()
}

// Blur removes keyboard focus from the input.
func (m *InputModel) Blur() {
	m.ti.Blur()
}

// Value returns the current raw text in the input field.
func (m InputModel) Value() string {
	return m.ti.Value()
}

// Reset clears the input field and resets autocomplete state.
func (m *InputModel) Reset() {
	m.historyIdx = len(m.history)
	m.ti.SetValue("")
	m.resetTab()
}

// Submit appends text to history and then clears the field.
// Use this when you need to preserve the submitted value in history.
func (m *InputModel) Submit(text string) {
	if text != "" {
		m.history = append(m.history, text)
	}
	m.Reset()
}

// resetTab clears autocomplete state.
func (m *InputModel) resetTab() {
	m.tabIdx = -1
	m.tabMatches = nil
}

// Init satisfies tea.Model.
func (m InputModel) Init() tea.Cmd {
	return nil
}

// Update satisfies tea.Model. It intercepts Up/Down for history and Tab for
// autocomplete before delegating remaining keys to the underlying textinput.
func (m InputModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.Type {
		case tea.KeyUp:
			m = m.navigateHistory(-1)
			return m, nil

		case tea.KeyDown:
			m = m.navigateHistory(+1)
			return m, nil

		case tea.KeyTab:
			m = m.cycleComplete()
			return m, nil

		default:
			// Any other key resets tab state so the next Tab starts fresh.
			m.resetTab()
		}
	}

	var cmd tea.Cmd
	m.ti, cmd = m.ti.Update(msg)
	return m, cmd
}

// View renders the prompt character followed by the textinput view.
func (m InputModel) View() string {
	prompt := style.PromptChar.Render("❯ ")
	return prompt + m.ti.View()
}

// navigateHistory moves the history cursor by delta (-1 = older, +1 = newer).
func (m InputModel) navigateHistory(delta int) InputModel {
	if len(m.history) == 0 {
		return m
	}

	next := m.historyIdx + delta

	switch {
	case next < 0:
		next = 0
	case next > len(m.history):
		next = len(m.history)
	}

	m.historyIdx = next

	if next == len(m.history) {
		// Moved past the newest entry — restore blank field.
		m.ti.SetValue("")
	} else {
		m.ti.SetValue(m.history[next])
		// Place cursor at end of restored text.
		m.ti.CursorEnd()
	}

	return m
}

// cycleComplete advances through autocomplete candidates.
// It only activates when the current buffer starts with "/".
func (m InputModel) cycleComplete() InputModel {
	current := m.ti.Value()

	if !strings.HasPrefix(current, "/") {
		return m
	}

	// Build the candidate list on the first Tab press.
	if m.tabIdx == -1 || m.tabMatches == nil {
		m.tabMatches = matchCommands(m.commands, current)
		if len(m.tabMatches) == 0 {
			return m
		}
		m.tabIdx = 0
	} else {
		m.tabIdx = (m.tabIdx + 1) % len(m.tabMatches)
	}

	m.ti.SetValue(m.tabMatches[m.tabIdx])
	m.ti.CursorEnd()
	return m
}

// matchCommands returns all commands that have prefix as a prefix.
func matchCommands(commands []string, prefix string) []string {
	var out []string
	for _, c := range commands {
		if strings.HasPrefix(c, prefix) {
			out = append(out, c)
		}
	}
	return out
}
