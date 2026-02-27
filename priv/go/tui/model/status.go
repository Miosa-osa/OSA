package model

import (
	"fmt"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/miosa/osa-tui/style"
)

// StatusModel renders the bottom status line showing signal metadata and
// context utilisation. It has two visual states:
//
//   - active (processing): elapsed · tools · tokens · signal dims + context bar
//   - idle: context bar only (when context data is available)
//
// Signal uses the package-local mirror type defined in chat.go to avoid the
// import cycle between client ↔ msg.
type StatusModel struct {
	signal       *Signal // local mirror; see Signal type in chat.go
	elapsed      time.Duration
	toolCount    int
	inputTokens  int
	outputTokens int
	contextUtil  float64 // 0.0–1.0
	contextMax   int
	active       bool
}

// NewStatus returns a zero-value StatusModel.
func NewStatus() StatusModel {
	return StatusModel{}
}

// SetSignal updates the current signal classification.
func (m *StatusModel) SetSignal(s *Signal) {
	m.signal = s
}

// SetContext updates context utilisation and the token ceiling.
func (m *StatusModel) SetContext(util float64, max int) {
	m.contextUtil = util
	m.contextMax = max
}

// SetStats updates elapsed time and token/tool counts.
func (m *StatusModel) SetStats(elapsed time.Duration, tools, inputTok, outputTok int) {
	m.elapsed = elapsed
	m.toolCount = tools
	m.inputTokens = inputTok
	m.outputTokens = outputTok
}

// SetActive marks the model as processing (true) or idle (false).
func (m *StatusModel) SetActive(active bool) {
	m.active = active
}

// Init satisfies tea.Model. No I/O required on start.
func (m StatusModel) Init() tea.Cmd {
	return nil
}

// Update satisfies tea.Model. StatusModel is driven entirely by setter calls;
// no messages are consumed here.
func (m StatusModel) Update(message tea.Msg) (tea.Model, tea.Cmd) {
	return m, nil
}

// View renders the status area. Returns an empty string when there is nothing
// meaningful to display.
func (m StatusModel) View() string {
	ctxLine := m.contextLine()

	if m.active {
		return m.activeLine() + "\n" + ctxLine
	}

	// Idle: show context bar only when we have real data.
	if m.contextMax > 0 {
		return ctxLine
	}
	return ""
}

// activeLine builds the processing summary line.
//
//	✓ 1.2s · 3 tools · ↓ 4.2k · Linguistic · Spec · w0.92
func (m StatusModel) activeLine() string {
	var b strings.Builder

	b.WriteString(style.StatusBar.Render(
		fmt.Sprintf("✓ %s · %d tools · ↓ %s",
			formatElapsed(m.elapsed),
			m.toolCount,
			formatTokens(m.inputTokens),
		),
	))

	if m.signal != nil {
		b.WriteString(style.StatusSignal.Render(
			fmt.Sprintf(" · %s · %s · w%.2f",
				m.signal.Mode,
				m.signal.Genre,
				m.signal.Weight,
			),
		))
	}

	return b.String()
}

// contextLine builds the context utilisation bar line.
//
//	██████░░░░ ctx 62%
func (m StatusModel) contextLine() string {
	bar := style.ContextBarRender(m.contextUtil, 10)
	pct := int(m.contextUtil * 100)
	label := style.ContextBar.Render(fmt.Sprintf(" ctx %d%%", pct))
	return bar + label
}
