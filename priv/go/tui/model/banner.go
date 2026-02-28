package model

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/miosa/osa-tui/msg"
	"github.com/miosa/osa-tui/style"
)

// OsaLogo is the ASCII art logo rendered on startup and connecting screens.
const OsaLogo = ` ██████╗ ███████╗ █████╗
██╔═══██╗██╔════╝██╔══██╗
██║   ██║███████╗███████║
██║   ██║╚════██║██╔══██║
╚██████╔╝███████║██║  ██║
 ╚═════╝ ╚══════╝╚═╝  ╚═╝`

type BannerModel struct {
	provider  string
	model     string
	version   string
	toolCount int
	workspace string
	width     int
}

func NewBanner() BannerModel {
	return BannerModel{version: "v0.2.5"}
}

func (m *BannerModel) SetHealth(h msg.HealthResult) {
	m.provider = h.Provider
	m.model = h.Model
	if h.Version != "" {
		m.version = h.Version
	}
}

func (m *BannerModel) SetModel(name string)                   { m.model = name }
func (m *BannerModel) SetToolCount(n int)                     { m.toolCount = n }
func (m *BannerModel) SetWorkspace(path string)               { m.workspace = path }
func (m *BannerModel) SetWidth(w int)                         { m.width = w }
func (m BannerModel) Provider() string                        { return m.provider }
func (m BannerModel) ModelName() string                       { return m.model }
func (m BannerModel) Init() tea.Cmd                           { return nil }
func (m BannerModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) { return m, nil }

// View returns the compact one-line header shown after the banner fades.
func (m BannerModel) View() string {
	muted := lipgloss.NewStyle().Foreground(style.Muted)
	primary := lipgloss.NewStyle().Foreground(style.Primary)
	title := style.BannerTitle.Render(fmt.Sprintf("OSA %s", m.version))
	sep := muted.Render(" · ")
	provider := style.BannerDetail.Render(m.provider)
	tools := style.BannerDetail.Render(fmt.Sprintf("%d tools", m.toolCount))
	if m.model != "" {
		slash := muted.Render(" / ")
		modelStr := primary.Render(m.model)
		return title + sep + provider + slash + modelStr + sep + tools
	}
	return title + sep + provider + sep + tools
}

// HeaderView returns the compact header plus a thin separator line.
func (m BannerModel) HeaderView() string {
	header := m.View()
	sep := lipgloss.NewStyle().Foreground(style.Border).Render(strings.Repeat("─", m.width))
	return header + "\n" + sep
}

// ViewFull renders the startup banner with ASCII art logo in a rounded box.
func (m BannerModel) ViewFull() string {
	muted := lipgloss.NewStyle().Foreground(style.Muted)
	primary := lipgloss.NewStyle().Foreground(style.Primary).Bold(true)

	// Render ASCII logo in primary color
	logoStyle := lipgloss.NewStyle().Foreground(style.Primary)
	logo := logoStyle.Render(OsaLogo)

	titleLeft := primary.Render("◈ OSA Agent")
	titleRight := muted.Render(m.version)
	var detailParts []string
	if m.provider != "" {
		detailParts = append(detailParts, m.provider)
	}
	if m.model != "" {
		detailParts = append(detailParts, m.model)
	}
	detailParts = append(detailParts, fmt.Sprintf("%d tools", m.toolCount))
	detailLine := muted.Render(strings.Join(detailParts, " · "))
	wsLine := ""
	if m.workspace != "" {
		wsLine = muted.Render(m.workspace)
	}
	hintLine := muted.Render("/help for help")
	boxWidth := m.width - 4
	if boxWidth < 40 {
		boxWidth = 60
	}
	if boxWidth > 70 {
		boxWidth = 70
	}
	titlePadding := boxWidth - lipgloss.Width(titleLeft) - lipgloss.Width(titleRight) - 4
	if titlePadding < 2 {
		titlePadding = 2
	}
	var content strings.Builder
	content.WriteString(logo)
	content.WriteString("\n\n")
	content.WriteString(titleLeft + strings.Repeat(" ", titlePadding) + titleRight)
	content.WriteString("\n  " + detailLine)
	if wsLine != "" {
		content.WriteString("\n  " + wsLine)
	}
	content.WriteString("\n")
	content.WriteString("\n  " + hintLine)
	boxStyle := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(style.Border).
		Padding(0, 2).
		Width(boxWidth)
	return boxStyle.Render(content.String())
}
