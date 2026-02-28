package model

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/bubbles/key"
	"github.com/charmbracelet/bubbles/textarea"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/miosa/osa-tui/style"
)

// InputModel wraps a textarea for multi-line input with history and tab completion.
// Enter submits; Alt+Enter inserts a newline for multi-line editing.
type InputModel struct {
	ta         textarea.Model
	history    []string
	historyIdx int
	commands   []string
	tabIdx     int
	tabMatches []string
	width      int
	multiline  bool
}

func NewInput() InputModel {
	ta := textarea.New()
	ta.Prompt = ""
	ta.Placeholder = "Ask anything, or type / for commands..."
	ta.CharLimit = 4096
	ta.ShowLineNumbers = false
	ta.SetWidth(76)
	ta.SetHeight(1)
	ta.MaxHeight = 6
	// Minimal styling — match textinput look (no cursor-line highlight)
	ta.FocusedStyle.CursorLine = lipgloss.NewStyle()
	ta.BlurredStyle.CursorLine = lipgloss.NewStyle()
	// Alt+Enter inserts newline; bare Enter is intercepted by app for submit
	ta.KeyMap.InsertNewline = key.NewBinding(key.WithKeys("alt+enter"))
	return InputModel{ta: ta, historyIdx: 0, tabIdx: -1, width: 80}
}

func (m *InputModel) SetCommands(cmds []string) { m.commands = cmds }
func (m *InputModel) SetWidth(w int)            { m.width = w; m.ta.SetWidth(w - 4) }
func (m *InputModel) Focus() tea.Cmd            { return m.ta.Focus() }
func (m *InputModel) Blur()                     { m.ta.Blur() }
func (m InputModel) Value() string              { return m.ta.Value() }
func (m *InputModel) SetValue(s string) {
	m.ta.SetValue(s)
	m.updateHeight()
}

func (m *InputModel) Reset() {
	m.historyIdx = len(m.history)
	m.ta.SetValue("")
	m.multiline = false
	m.ta.SetHeight(1)
	m.resetTab()
}

func (m *InputModel) Submit(text string) {
	if text != "" {
		m.history = append(m.history, text)
	}
	m.Reset()
}

// ClearInput clears the current input without recording history.
func (m *InputModel) ClearInput() {
	m.ta.SetValue("")
	m.multiline = false
	m.ta.SetHeight(1)
	m.resetTab()
}

func (m *InputModel) resetTab() {
	m.tabIdx = -1
	m.tabMatches = nil
}

// updateHeight adjusts textarea visible height based on content line count.
func (m *InputModel) updateHeight() {
	val := m.ta.Value()
	m.multiline = strings.Contains(val, "\n")
	if m.multiline {
		lines := strings.Count(val, "\n") + 1
		h := lines
		if h > 6 {
			h = 6
		}
		m.ta.SetHeight(h)
	} else {
		m.ta.SetHeight(1)
	}
}

func (m InputModel) Init() tea.Cmd { return nil }

func (m InputModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch {
		case msg.Type == tea.KeyUp && !m.multiline:
			m = m.navigateHistory(-1)
			return m, nil
		case msg.Type == tea.KeyDown && !m.multiline:
			m = m.navigateHistory(+1)
			return m, nil
		case msg.Type == tea.KeyTab:
			m = m.cycleComplete()
			return m, nil
		default:
			m.resetTab()
		}
	}
	var cmd tea.Cmd
	m.ta, cmd = m.ta.Update(msg)
	m.updateHeight()
	return m, cmd
}

func (m InputModel) View() string {
	w := m.width
	if w < 10 {
		w = 80
	}
	sep := lipgloss.NewStyle().Foreground(style.Border).Render(strings.Repeat("─", w))
	prompt := style.PromptChar.Render("❯ ")
	hint := ""
	if m.multiline {
		lines := strings.Count(m.ta.Value(), "\n") + 1
		hint = " " + style.Hint.Render(fmt.Sprintf("[%d lines · alt+enter newline]", lines))
	}
	return sep + "\n" + prompt + m.ta.View() + hint
}

func (m InputModel) navigateHistory(delta int) InputModel {
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

func (m InputModel) cycleComplete() InputModel {
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

func matchCommands(commands []string, prefix string) []string {
	var out []string
	for _, c := range commands {
		if strings.HasPrefix(c, prefix) {
			out = append(out, c)
		}
	}
	return out
}
