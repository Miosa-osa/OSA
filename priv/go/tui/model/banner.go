package model

import (
	"fmt"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/miosa/osa-tui/msg"
	"github.com/miosa/osa-tui/style"
)

// BannerModel renders the one-line startup banner:
//
//	OSA v3.3 · ollama / qwen3:32b · 15 tools
//
// It is populated from the health check result and is purely static —
// Update handles no messages.
type BannerModel struct {
	provider  string
	model     string
	version   string
	toolCount int
}

// NewBanner returns a zero-value BannerModel with a default version string.
func NewBanner() BannerModel {
	return BannerModel{version: "v3.3"}
}

// SetHealth populates the banner from a HealthResult message.
func (m *BannerModel) SetHealth(h msg.HealthResult) {
	m.provider = h.Provider
	m.version = h.Version
	if m.version == "" {
		m.version = "v3.3"
	}
}

// SetModel sets the active model name displayed in the banner.
func (m *BannerModel) SetModel(name string) {
	m.model = name
}

// SetToolCount sets the number of available tools.
func (m *BannerModel) SetToolCount(n int) {
	m.toolCount = n
}

// Init satisfies tea.Model. The banner requires no I/O on start.
func (m BannerModel) Init() tea.Cmd {
	return nil
}

// Update satisfies tea.Model. The banner is static; all messages pass through.
func (m BannerModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	return m, nil
}

// View renders the banner line.
//
// Example output (with ANSI styles applied):
//
//	OSA v3.3 · ollama / qwen3:32b · 15 tools
func (m BannerModel) View() string {
	muted := lipgloss.NewStyle().Foreground(style.Muted)
	primary := lipgloss.NewStyle().Foreground(style.Primary)

	title := style.BannerTitle.Render(fmt.Sprintf("OSA %s", m.version))
	sep := muted.Render(" · ")
	provider := style.BannerDetail.Render(m.provider)
	slash := muted.Render(" / ")
	modelStr := primary.Render(m.model)
	tools := style.BannerDetail.Render(fmt.Sprintf("%d tools", m.toolCount))

	return title + sep + provider + slash + modelStr + sep + tools
}
