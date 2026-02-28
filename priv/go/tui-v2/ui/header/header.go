package header

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/miosa/osa-tui/msg"
	"github.com/miosa/osa-tui/style"
	"github.com/miosa/osa-tui/ui/logo"
)

// OsaLogo is the ASCII art logo rendered on startup and connecting screens.
// Kept for backward compatibility; prefer logo.FullLogo for new code.
const OsaLogo = logo.FullLogo

// Model holds the state for the compact TUI header.
type Model struct {
	provider  string
	modelName string
	version   string
	toolCount int
	workspace string
	width     int
}

// NewHeader returns a Model with the default version string.
func NewHeader() Model {
	return Model{version: "v0.2.5"}
}

// SetHealth applies provider and model info from a health-check result.
func (m *Model) SetHealth(h msg.HealthResult) {
	m.provider = h.Provider
	m.modelName = h.Model
	if h.Version != "" {
		m.version = h.Version
	}
}

// SetToolCount updates the displayed tool count.
func (m *Model) SetToolCount(n int) { m.toolCount = n }

// SetWorkspace updates the displayed workspace path.
func (m *Model) SetWorkspace(path string) { m.workspace = path }

// SetWidth updates the terminal width used for separator and box sizing.
func (m *Model) SetWidth(w int) { m.width = w }

// SetModelOverride overrides both provider and model (used after model switch).
func (m *Model) SetModelOverride(provider, modelName string) {
	m.provider = provider
	m.modelName = modelName
}

// Provider returns the current provider string.
func (m Model) Provider() string { return m.provider }

// ModelName returns the current model name.
func (m Model) ModelName() string { return m.modelName }

// Version returns the OSA version string.
func (m Model) Version() string { return m.version }

// Workspace returns the current workspace path.
func (m Model) Workspace() string { return m.workspace }

// WelcomeLine returns a summary like "ollama · llama3.2 · 15 tools" for the
// welcome screen.
func (m Model) WelcomeLine() string {
	var parts []string
	if m.provider != "" {
		parts = append(parts, m.provider)
	}
	if m.modelName != "" {
		parts = append(parts, m.modelName)
	}
	parts = append(parts, fmt.Sprintf("%d tools", m.toolCount))
	return strings.Join(parts, " · ")
}

// View returns the compact one-line header shown after the banner fades.
func (m Model) View() string {
	muted := lipgloss.NewStyle().Foreground(style.Muted)
	primary := lipgloss.NewStyle().Foreground(style.Primary)

	title := style.BannerTitle.Render(fmt.Sprintf("OSA %s", m.version))
	sep := muted.Render(" · ")
	provider := style.BannerDetail.Render(m.provider)
	tools := style.BannerDetail.Render(fmt.Sprintf("%d tools", m.toolCount))

	if m.modelName != "" {
		slash := muted.Render(" / ")
		modelStr := primary.Render(m.modelName)
		return title + sep + provider + slash + modelStr + sep + tools
	}
	return title + sep + provider + sep + tools
}

// HeaderView returns the compact header plus a thin separator line.
func (m Model) HeaderView() string {
	header := m.View()
	sep := lipgloss.NewStyle().Foreground(style.Border).Render(strings.Repeat("─", m.width))
	return header + "\n" + sep
}

// ViewFull renders the startup banner with ASCII art logo in a rounded box.
func (m Model) ViewFull() string {
	muted := lipgloss.NewStyle().Foreground(style.Muted)
	primary := lipgloss.NewStyle().Foreground(style.Primary).Bold(true)

	renderedLogo := logo.RenderWithGradient(m.width)

	titleLeft := primary.Render("◈ OSA Agent")
	titleRight := muted.Render(m.version)

	var detailParts []string
	if m.provider != "" {
		detailParts = append(detailParts, m.provider)
	}
	if m.modelName != "" {
		detailParts = append(detailParts, m.modelName)
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
	content.WriteString(renderedLogo)
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
