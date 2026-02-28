package sidebar

import (
	"fmt"
	"os"
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/miosa/osa-tui/style"
	"github.com/miosa/osa-tui/ui/logo"
)

// FileChange describes a modified file with diff statistics.
type FileChange struct {
	Path      string
	Additions int
	Deletions int
}

// LSPStatus holds the current state of an LSP language server.
type LSPStatus struct {
	Name     string
	State    string // "starting", "ready", "error", "disabled"
	Errors   int
	Warnings int
}

// MCPStatus holds the current state of an MCP server connection.
type MCPStatus struct {
	Name    string
	State   string // "connected", "connecting", "error"
	Tools   int
	Prompts int
}

// Model is the sidebar pane shown when LayoutSidebar mode is active.
type Model struct {
	// Session / workspace
	sessionTitle string
	workDir      string

	// Model info
	provider  string
	modelName string
	reasoning bool
	cost      float64 // session cost in cents

	// Context utilization
	contextPct  float64
	contextMax  int
	contextUsed int

	// Tool / background counts
	toolCount int
	bgCount   int

	// Rich sections
	files      []FileChange
	lspServers []LSPStatus
	mcpServers []MCPStatus

	// Dimensions
	width  int
	height int
}

// New returns a zero-value sidebar Model.
func New() Model {
	return Model{}
}

// ---------------------------------------------------------------------------
// Setters
// ---------------------------------------------------------------------------

// SetSessionInfo updates the session title and working directory.
func (m *Model) SetSessionInfo(title, workDir string) {
	m.sessionTitle = title
	m.workDir = workDir
}

// SetModelInfo updates the provider and model name.
func (m *Model) SetModelInfo(provider, modelName string) {
	m.provider = provider
	m.modelName = modelName
}

// SetContext updates the context utilization bar values.
func (m *Model) SetContext(pct float64, max, used int) {
	m.contextPct = pct
	m.contextMax = max
	m.contextUsed = used
}

// SetToolCount sets the number of available tools.
func (m *Model) SetToolCount(n int) { m.toolCount = n }

// SetBackgroundCount sets the number of active background tasks.
func (m *Model) SetBackgroundCount(n int) { m.bgCount = n }

// SetFiles replaces the tracked file changes list.
func (m *Model) SetFiles(files []FileChange) {
	m.files = make([]FileChange, len(files))
	copy(m.files, files)
}

// AddFile appends a single file change to the list.
func (m *Model) AddFile(f FileChange) {
	m.files = append(m.files, f)
}

// ClearFiles removes all tracked files.
func (m *Model) ClearFiles() { m.files = nil }

// SetLSPServers replaces the LSP server status list.
func (m *Model) SetLSPServers(servers []LSPStatus) {
	m.lspServers = make([]LSPStatus, len(servers))
	copy(m.lspServers, servers)
}

// SetMCPServers replaces the MCP server status list.
func (m *Model) SetMCPServers(servers []MCPStatus) {
	m.mcpServers = make([]MCPStatus, len(servers))
	copy(m.mcpServers, servers)
}

// SetCost sets the session cost in cents.
func (m *Model) SetCost(cents float64) { m.cost = cents }

// SetReasoning sets whether reasoning mode is enabled.
func (m *Model) SetReasoning(enabled bool) { m.reasoning = enabled }

// SetSize updates the sidebar dimensions.
func (m *Model) SetSize(w, h int) {
	m.width = w
	m.height = h
}

// ---------------------------------------------------------------------------
// View
// ---------------------------------------------------------------------------

// View renders the sidebar panel with all sections.
//
// Section order:
//  1. Logo (if width >= 30)
//  2. Session title
//  3. Working directory
//  4. Model info (provider/model + reasoning + cost)
//  5. Context utilization bar with percentage
//  6. Files section with +N/-N diff stats (max 10)
//  7. LSP section with server statuses
//  8. MCP section with server statuses
//  9. Tool count + background count
func (m Model) View() string {
	innerWidth := m.width - 4 // account for border + padding
	if innerWidth < 10 {
		innerWidth = 10
	}

	var sb strings.Builder

	// 1. Logo
	if m.width >= 30 {
		sb.WriteString(logo.RenderWithGradient(m.width))
		sb.WriteByte('\n')
		sb.WriteString(style.SidebarSeparator.Render(strings.Repeat("─", innerWidth)))
		sb.WriteByte('\n')
	}

	// 2. Session title
	sb.WriteString(style.SidebarTitle.Render("Session"))
	sb.WriteByte('\n')
	if m.sessionTitle != "" {
		title := truncateToWidth(m.sessionTitle, innerWidth*2)
		if len(title) > innerWidth {
			sb.WriteString(style.SidebarValue.Render(title[:innerWidth]))
			sb.WriteByte('\n')
			sb.WriteString(style.SidebarValue.Render(title[innerWidth:]))
		} else {
			sb.WriteString(style.SidebarValue.Render(title))
		}
	} else {
		sb.WriteString(style.SidebarValue.Render("(untitled)"))
	}
	sb.WriteByte('\n')

	// 3. Working directory
	sb.WriteString(style.SidebarLabel.Render("cwd"))
	sb.WriteByte('\n')
	cwd := abbreviateHome(m.workDir)
	if len(cwd) > innerWidth {
		cwd = "…" + cwd[len(cwd)-innerWidth+1:]
	}
	sb.WriteString(style.SidebarValue.Render(cwd))
	sb.WriteByte('\n')

	// 4. Model info
	sb.WriteString(style.SidebarSeparator.Render(strings.Repeat("─", innerWidth)))
	sb.WriteByte('\n')
	sb.WriteString(style.SidebarLabel.Render("model"))
	sb.WriteByte('\n')
	modelStr := buildModelString(m.provider, m.modelName)
	if len(modelStr) > innerWidth {
		modelStr = modelStr[:innerWidth-1] + "…"
	}
	sb.WriteString(style.SidebarValue.Render(modelStr))
	sb.WriteByte('\n')

	// Reasoning indicator + cost on the same line.
	var metaParts []string
	if m.reasoning {
		metaParts = append(metaParts, style.LSPStarting.Render("⟳ reasoning"))
	}
	if m.cost > 0 {
		metaParts = append(metaParts, style.SidebarLabel.Render(fmt.Sprintf("$%.4f", m.cost/100)))
	}
	if len(metaParts) > 0 {
		sb.WriteString(strings.Join(metaParts, " "))
		sb.WriteByte('\n')
	}

	// 5. Context bar
	sb.WriteString(style.SidebarSeparator.Render(strings.Repeat("─", innerWidth)))
	sb.WriteByte('\n')
	barWidth := innerWidth - 7 // leave room for " 100%" suffix
	if barWidth < 5 {
		barWidth = 5
	}
	bar := style.ContextBarRender(m.contextPct, barWidth)
	pct := fmt.Sprintf(" %d%%", int(m.contextPct*100))
	sb.WriteString(bar + style.SidebarLabel.Render(pct))
	sb.WriteByte('\n')
	if m.contextMax > 0 {
		ctxDetail := fmt.Sprintf("%s / %s",
			formatTokens(m.contextUsed),
			formatTokens(m.contextMax),
		)
		sb.WriteString(style.SidebarLabel.Render(ctxDetail))
		sb.WriteByte('\n')
	}

	// 6. Files section
	sb.WriteString(renderSectionHeader("Files", innerWidth))
	if len(m.files) == 0 {
		sb.WriteString(style.SidebarLabel.Render("none"))
		sb.WriteByte('\n')
	} else {
		shown := m.files
		if len(shown) > 10 {
			shown = shown[:10]
		}
		for _, f := range shown {
			display := abbreviateHome(f.Path)
			maxFileWidth := innerWidth - 10 // reserve space for +N/-N
			if maxFileWidth < 10 {
				maxFileWidth = 10
			}
			if len(display) > maxFileWidth {
				display = "…" + display[len(display)-maxFileWidth+1:]
			}
			addStr := style.DiffAdditions.Render(fmt.Sprintf("+%d", f.Additions))
			delStr := style.DiffDeletions.Render(fmt.Sprintf("-%d", f.Deletions))
			fileLine := style.SidebarFileItem.Render(display) + " " + addStr + " " + delStr
			sb.WriteString(fileLine)
			sb.WriteByte('\n')
		}
		if len(m.files) > 10 {
			sb.WriteString(style.SidebarLabel.Render(
				fmt.Sprintf("+%d more", len(m.files)-10),
			))
			sb.WriteByte('\n')
		}
	}

	// 7. LSP section
	if len(m.lspServers) > 0 {
		sb.WriteString(renderSectionHeader("LSP", innerWidth))
		for _, srv := range m.lspServers {
			indicator, stateStyle := lspStateStyle(srv.State)
			name := srv.Name
			if len(name) > innerWidth-8 {
				name = name[:innerWidth-9] + "…"
			}
			line := indicator + " " + stateStyle.Render(name)
			if srv.Errors > 0 {
				line += " " + style.LSPError.Render(fmt.Sprintf("%de", srv.Errors))
			}
			if srv.Warnings > 0 {
				line += " " + style.LSPStarting.Render(fmt.Sprintf("%dw", srv.Warnings))
			}
			sb.WriteString(line)
			sb.WriteByte('\n')
		}
	}

	// 8. MCP section
	if len(m.mcpServers) > 0 {
		sb.WriteString(renderSectionHeader("MCP", innerWidth))
		for _, srv := range m.mcpServers {
			indicator, stateStyle := mcpStateStyle(srv.State)
			name := srv.Name
			if len(name) > innerWidth-8 {
				name = name[:innerWidth-9] + "…"
			}
			line := indicator + " " + stateStyle.Render(name)
			if srv.Tools > 0 {
				line += " " + style.SidebarLabel.Render(fmt.Sprintf("%dt", srv.Tools))
			}
			sb.WriteString(line)
			sb.WriteByte('\n')
		}
	}

	// 9. Tool count + background count
	sb.WriteString(style.SidebarSeparator.Render(strings.Repeat("─", innerWidth)))
	sb.WriteByte('\n')
	statsLine := fmt.Sprintf("%d tools", m.toolCount)
	if m.bgCount > 0 {
		statsLine += fmt.Sprintf(" · %d bg", m.bgCount)
	}
	sb.WriteString(style.SidebarLabel.Render(statsLine))
	sb.WriteByte('\n')

	// Wrap in sidebar border style.
	_ = lipgloss.NewStyle().Background(style.SidebarBg) // kept for future use
	return style.SidebarStyle.
		Width(m.width).
		Height(m.height).
		Render(strings.TrimRight(sb.String(), "\n"))
}

// ---------------------------------------------------------------------------
// Section helpers
// ---------------------------------------------------------------------------

// renderSectionHeader renders a titled horizontal divider: ─── Title ───
func renderSectionHeader(title string, width int) string {
	if width <= 0 {
		return title + "\n"
	}
	inner := style.SidebarTitle.Render(title)
	// Compute raw character widths (ignoring ANSI).
	dashCount := width - len(title) - 2 // 2 spaces around title
	if dashCount < 2 {
		dashCount = 2
	}
	left := dashCount / 2
	right := dashCount - left
	sep := style.SidebarSeparator.Render
	return sep(strings.Repeat("─", left)) + " " + inner + " " + sep(strings.Repeat("─", right)) + "\n"
}

// lspStateStyle returns the indicator rune and lipgloss style for an LSP state.
func lspStateStyle(state string) (string, lipgloss.Style) {
	switch state {
	case "ready":
		return style.LSPReady.Render("●"), style.LSPReady
	case "error":
		return style.LSPError.Render("●"), style.LSPError
	case "starting":
		return style.LSPStarting.Render("◐"), style.LSPStarting
	default: // "disabled" or unknown
		return style.SidebarLabel.Render("○"), style.SidebarLabel
	}
}

// mcpStateStyle returns the indicator rune and lipgloss style for an MCP state.
func mcpStateStyle(state string) (string, lipgloss.Style) {
	switch state {
	case "connected":
		return style.MCPConnected.Render("●"), style.MCPConnected
	case "error":
		return style.MCPError.Render("●"), style.MCPError
	default: // "connecting" or unknown
		return style.LSPStarting.Render("◐"), style.LSPStarting
	}
}

// ---------------------------------------------------------------------------
// String / format helpers
// ---------------------------------------------------------------------------

// buildModelString produces "provider/modelName" or whichever parts are non-empty.
func buildModelString(provider, modelName string) string {
	switch {
	case provider != "" && modelName != "":
		return provider + "/" + modelName
	case modelName != "":
		return modelName
	case provider != "":
		return provider
	default:
		return "—"
	}
}

// truncateToWidth truncates s to at most maxLen bytes, appending "…" if needed.
func truncateToWidth(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen-1] + "…"
}

// abbreviateHome replaces the user home directory prefix with "~".
func abbreviateHome(path string) string {
	if path == "" {
		return path
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return path
	}
	if strings.HasPrefix(path, home) {
		return "~" + path[len(home):]
	}
	return path
}

// formatTokens converts a raw token count to a compact display string.
func formatTokens(n int) string {
	switch {
	case n >= 1_000_000:
		return fmt.Sprintf("%.1fM", float64(n)/1_000_000)
	case n >= 1_000:
		return fmt.Sprintf("%.1fk", float64(n)/1_000)
	default:
		return fmt.Sprintf("%d", n)
	}
}
