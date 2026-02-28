package model

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/miosa/osa-tui/msg"
	"github.com/miosa/osa-tui/style"
)

// truncatePath shortens a filesystem path to fit within maxWidth characters.
// It tries: full path → ~/relative → …/last-two-segments → …/basename.
func truncatePath(path string, maxWidth int) string {
	if len(path) <= maxWidth {
		return path
	}
	// Try replacing home dir with ~
	if home, err := os.UserHomeDir(); err == nil && home != "" && strings.HasPrefix(path, home) {
		short := "~" + path[len(home):]
		if len(short) <= maxWidth {
			return short
		}
	}
	// Try last two path segments
	dir := filepath.Dir(path)
	base := filepath.Base(path)
	parent := filepath.Base(dir)
	short := "…/" + parent + "/" + base
	if len(short) <= maxWidth {
		return short
	}
	// Just basename
	short = "…/" + base
	if len(short) <= maxWidth {
		return short
	}
	// Hard truncate
	if maxWidth > 3 {
		return path[:maxWidth-1] + "…"
	}
	return path[:maxWidth]
}

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

func (m *BannerModel) SetToolCount(n int)       { m.toolCount = n }
func (m *BannerModel) SetWorkspace(path string) { m.workspace = path }
func (m *BannerModel) SetWidth(w int)           { m.width = w }
func (m BannerModel) Provider() string          { return m.provider }
func (m BannerModel) ModelName() string         { return m.model }
func (m BannerModel) Version() string           { return m.version }
func (m BannerModel) Workspace() string         { return m.workspace }

// SetModelOverride updates both provider and model (used after model switch).
func (m *BannerModel) SetModelOverride(provider, modelName string) {
	m.provider = provider
	m.model = modelName
}

// WelcomeLine returns a summary like "ollama · llama3.2 · 15 tools" for the welcome screen.
func (m BannerModel) WelcomeLine() string {
	var parts []string
	if m.provider != "" {
		parts = append(parts, m.provider)
	}
	if m.model != "" {
		parts = append(parts, m.model)
	}
	parts = append(parts, fmt.Sprintf("%d tools", m.toolCount))
	return strings.Join(parts, " · ")
}
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
	hintLine := muted.Render("/help for help")
	boxWidth := m.width - 4
	if boxWidth < 40 {
		boxWidth = 40
	}
	if boxWidth > 80 {
		boxWidth = 80
	}
	wsLine := ""
	if m.workspace != "" {
		// Truncate path to fit box content area (boxWidth - border - padding - indent)
		maxPathWidth := boxWidth - 8 // 2 border + 4 padding + 2 indent
		if maxPathWidth < 20 {
			maxPathWidth = 20
		}
		wsLine = muted.Render(truncatePath(m.workspace, maxPathWidth))
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
