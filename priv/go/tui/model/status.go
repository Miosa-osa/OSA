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
	signal          *Signal // local mirror; see Signal type in chat.go
	elapsed         time.Duration
	toolCount       int
	inputTokens     int
	outputTokens    int
	contextUtil     float64 // 0.0–1.0
	contextMax      int
	estimatedTokens int
	active          bool
	provider        string
	modelName       string
	bgCount         int // number of background tasks
}

// NewStatus returns a zero-value StatusModel.
func NewStatus() StatusModel {
	return StatusModel{}
}

// SetProviderInfo stores the provider and model name for idle display.
func (m *StatusModel) SetProviderInfo(provider, modelName string) {
	m.provider = provider
	m.modelName = modelName
}

// SetSignal updates the current signal classification.
func (m *StatusModel) SetSignal(s *Signal) {
	m.signal = s
}

// SetContext updates context utilisation, the token ceiling, and estimated tokens.
func (m *StatusModel) SetContext(util float64, max int, estimated int) {
	m.contextUtil = util
	m.contextMax = max
	m.estimatedTokens = estimated
}

// SetStats updates elapsed time and token/tool counts.
func (m *StatusModel) SetStats(elapsed time.Duration, tools, inputTok, outputTok int) {
	m.elapsed = elapsed
	m.toolCount = tools
	m.inputTokens = inputTok
	m.outputTokens = outputTok
}

// SetBackgroundCount updates the number of background tasks for idle display.
func (m *StatusModel) SetBackgroundCount(n int) {
	m.bgCount = n
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

// View renders the status area.
//
// Processing: context bar only (activity panel already shows timing/tokens).
// Idle: provider/model + optional signal badge + optional context bar.
func (m StatusModel) View() string {
	if m.active {
		// Only context bar — activity panel handles timing/tokens
		return m.contextLine()
	}

	// Idle: provider/model footer + optional signal + context bar
	var parts []string
	if m.provider != "" || m.modelName != "" {
		line := m.idleLine()
		if m.signal != nil && m.signal.Mode != "" {
			line += style.StatusSignal.Render(
				fmt.Sprintf(" · %s/%s", m.signal.Mode, m.signal.Genre),
			)
		}
		if m.bgCount > 0 {
			line += style.Hint.Render(fmt.Sprintf(" · %d bg", m.bgCount))
		}
		parts = append(parts, line)
	}
	if m.contextMax > 0 {
		parts = append(parts, m.contextLine())
	}
	if len(parts) == 0 {
		return ""
	}
	return strings.Join(parts, "\n")
}

// idleLine renders provider/model info when idle.
//
//	ollama / llama3.2
func (m StatusModel) idleLine() string {
	info := m.provider
	if m.modelName != "" {
		if info != "" {
			info += " / " + m.modelName
		} else {
			info = m.modelName
		}
	}
	return style.StatusBar.Render(info)
}

// contextLine builds the context utilisation bar line.
//
//	██████░░░░ ctx 62% (125k/200k)
func (m StatusModel) contextLine() string {
	if m.contextMax <= 0 {
		return ""
	}
	bar := style.ContextBarRender(m.contextUtil, 10)
	pct := int(m.contextUtil * 100)
	if m.estimatedTokens > 0 && m.contextMax > 0 {
		label := style.ContextBar.Render(fmt.Sprintf(" ctx %d%% (%s/%s)",
			pct, formatTokens(m.estimatedTokens), formatTokens(m.contextMax)))
		return bar + label
	}
	label := style.ContextBar.Render(fmt.Sprintf(" ctx %d%%", pct))
	return bar + label
}
