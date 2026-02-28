package model

import (
	"strings"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/miosa/osa-tui/style"
)

type InputModel struct {
	ti         textinput.Model
	history    []string
	historyIdx int
	commands   []string
	tabIdx     int
	tabMatches []string
	width      int
}

func NewInput() InputModel {
	ti := textinput.New()
	ti.Prompt = ""
	ti.Placeholder = "Ask anything, or type / for commands..."
	ti.CharLimit = 4096
	ti.Width = 76
	return InputModel{ti: ti, historyIdx: 0, tabIdx: -1, width: 80}
}

func (m *InputModel) SetCommands(cmds []string) { m.commands = cmds }
func (m *InputModel) SetWidth(w int)            { m.width = w; m.ti.Width = w - 4 }
func (m *InputModel) Focus() tea.Cmd            { return m.ti.Focus() }
func (m *InputModel) Blur()                     { m.ti.Blur() }
func (m InputModel) Value() string              { return m.ti.Value() }

func (m *InputModel) Reset() {
	m.historyIdx = len(m.history)
	m.ti.SetValue("")
	m.resetTab()
}

func (m *InputModel) Submit(text string) {
	if text != "" {
		m.history = append(m.history, text)
	}
	m.Reset()
}

func (m *InputModel) resetTab() {
	m.tabIdx = -1
	m.tabMatches = nil
}

func (m InputModel) Init() tea.Cmd { return nil }

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
			m.resetTab()
		}
	}
	var cmd tea.Cmd
	m.ti, cmd = m.ti.Update(msg)
	return m, cmd
}

func (m InputModel) View() string {
	w := m.width
	if w < 10 {
		w = 80
	}
	sep := lipgloss.NewStyle().Foreground(style.Border).Render(strings.Repeat("─", w))
	prompt := style.PromptChar.Render("❯ ")
	return sep + "\n" + prompt + m.ti.View()
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
		m.ti.SetValue("")
	} else {
		m.ti.SetValue(m.history[next])
		m.ti.CursorEnd()
	}
	return m
}

func (m InputModel) cycleComplete() InputModel {
	current := m.ti.Value()
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
	m.ti.SetValue(m.tabMatches[m.tabIdx])
	m.ti.CursorEnd()
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
