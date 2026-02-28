// Package status provides the bottom status bar model for OSA TUI v2.
// It renders provider/model info, signal classification, and context utilization.
package status

import (
	"fmt"
	"strings"
	"time"

	"github.com/miosa/osa-tui/style"
)

// Signal carries signal classification metadata attached to an agent response.
type Signal struct {
	Mode   string
	Genre  string
	Type   string
	Weight float64
}

// Model is the status bar state. Drive it via setter methods; it has no Update loop.
type Model struct {
	signal          *Signal
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
	bgCount         int
}

// New returns a zero-value Model.
func New() Model {
	return Model{}
}

// SetProviderInfo stores provider and model name for idle display.
func (m *Model) SetProviderInfo(provider, modelName string) {
	m.provider = provider
	m.modelName = modelName
}

// SetSignal updates the current signal classification.
func (m *Model) SetSignal(s *Signal) {
	m.signal = s
}

// SetContext updates context utilisation, the token ceiling, and estimated token count.
func (m *Model) SetContext(util float64, max int, estimated int) {
	m.contextUtil = util
	m.contextMax = max
	m.estimatedTokens = estimated
}

// SetStats updates elapsed time and token/tool counts.
func (m *Model) SetStats(elapsed time.Duration, tools, inputTok, outputTok int) {
	m.elapsed = elapsed
	m.toolCount = tools
	m.inputTokens = inputTok
	m.outputTokens = outputTok
}

// SetBackgroundCount updates the number of background tasks shown in idle display.
func (m *Model) SetBackgroundCount(n int) {
	m.bgCount = n
}

// SetActive marks the model as processing (true) or idle (false).
func (m *Model) SetActive(active bool) {
	m.active = active
}

// View renders the status area.
//
// Active: context bar only (activity panel already shows timing/tokens).
// Idle: provider/model footer + optional signal badge + optional context bar.
func (m Model) View() string {
	if m.active {
		return m.contextLine()
	}

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

// idleLine renders provider/model info: "ollama / llama3.2"
func (m Model) idleLine() string {
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

// contextLine builds the context utilisation bar: "██████░░░░ ctx 62% (125k/200k)"
func (m Model) contextLine() string {
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

// formatTokens returns a human-readable token count: 1500 → "1.5k", 200000 → "200k".
func formatTokens(n int) string {
	if n >= 1000 {
		return fmt.Sprintf("%dk", n/1000)
	}
	return fmt.Sprintf("%d", n)
}
