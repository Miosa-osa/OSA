package app

import (
	"fmt"
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/miosa/osa-tui/client"
	"github.com/miosa/osa-tui/style"
	"github.com/miosa/osa-tui/ui/logo"
)

// renderSearchBar returns the search bar string when search mode is active,
// or an empty string otherwise.
func (m Model) renderSearchBar() string {
	if !m.searchMode {
		return ""
	}
	count := len(m.searchMatches)
	var statusStr string
	if m.searchQuery == "" {
		statusStr = style.Faint.Render("type to search")
	} else if count == 0 {
		statusStr = style.Faint.Render("no matches")
	} else {
		statusStr = style.Faint.Render(fmt.Sprintf("%d/%d  n next · N prev", m.searchCursor+1, count))
	}
	cursor := lipgloss.NewStyle().Foreground(style.Primary).Render("█")
	label := lipgloss.NewStyle().Foreground(style.Secondary).Render("/ ") + m.searchQuery + cursor
	hint := style.Faint.Render("  Esc close")
	return lipgloss.NewStyle().
		BorderStyle(lipgloss.NormalBorder()).
		BorderTop(true).
		BorderForeground(style.Border).
		Padding(0, 1).
		Render(label + "  " + statusStr + hint)
}

// scrollHint returns a one-line indicator when the chat is not at the bottom.
// Returns an empty string when the user is already at the latest message.
func (m Model) scrollHint() string {
	if m.chat.AtBottom() {
		return ""
	}
	pct := int(m.chat.ScrollPercent() * 100)
	hint := fmt.Sprintf("  ↓ scroll to latest  [%d%%]  End", pct)
	return style.Faint.Render(hint)
}

// -- View ---------------------------------------------------------------------

// View returns the tea.View for the current frame.
// AltScreen, MouseMode, and ReportFocus are set on every frame.
func (m Model) View() tea.View {
	content := m.renderView()
	v := tea.NewView(content)
	v.AltScreen = true
	v.MouseMode = tea.MouseModeCellMotion
	v.ReportFocus = true
	return v
}

// renderView composes the full terminal frame as a string.
func (m Model) renderView() string {
	// Full-screen overlay states — shortcut out.
	if m.state == StatePalette && m.palette.IsActive() {
		return m.palette.View()
	}
	if m.state == StatePermissions {
		return m.permissions.View()
	}
	if m.state == StateQuit {
		return m.quit.View()
	}
	if m.state == StateSessions {
		return m.sessions.View()
	}
	if m.state == StateModels {
		return m.models.View()
	}
	if m.state == StateOnboarding {
		return m.onboarding.View()
	}

	var sections []string

	switch m.state {
	case StateConnecting:
		sections = append(sections, m.renderConnecting())

	case StateBanner:
		sections = append(sections, m.header.ViewFull())
		sections = append(sections, "")
		sections = append(sections, m.input.View())

	default:
		// Header is common to all non-connecting, non-banner states.
		sections = append(sections, m.header.HeaderView())

		// Main content: optional sidebar | chat
		mainContent := m.renderMain()
		sections = append(sections, mainContent)

		// Task checklist
		if m.tasks.HasTasks() {
			sections = append(sections, m.tasks.View())
		}

		// Multi-agent panel (processing state only)
		if m.state == StateProcessing && m.agents.IsActive() {
			sections = append(sections, m.agents.View())
		}

		// Plan overlay (replaces input when reviewing)
		if m.state == StatePlanReview {
			sections = append(sections, m.plan.View())
		}

		// Model picker overlay
		if m.state == StateModelPicker {
			sections = append(sections, m.picker.View())
		}

		// Scroll hint (visible only when scrolled up, hidden at bottom)
		if hint := m.scrollHint(); hint != "" {
			sections = append(sections, hint)
		}

		// Search bar (visible when Ctrl+F is active)
		if bar := m.renderSearchBar(); bar != "" {
			sections = append(sections, bar)
		}

		// Status bar
		sections = append(sections, m.status.View())

		// Input (hidden during plan review and model picker)
		if m.state != StatePlanReview && m.state != StateModelPicker {
			sections = append(sections, m.input.View())
		}
	}

	// Toasts overlay
	if m.toasts.HasToasts() {
		sections = append(sections, m.toasts.View(m.width))
	}

	// (confirmQuit replaced by QuitModel dialog)

	return strings.Join(sections, "\n")
}

// renderMain returns the main chat area, optionally side-by-side with the sidebar.
// The chat model's View() already renders the welcome screen when there are no messages.
func (m Model) renderMain() string {
	chatView := m.chat.View()

	if m.layout.Mode == LayoutSidebar && m.layout.SidebarWidth > 0 {
		return lipgloss.JoinHorizontal(lipgloss.Top, m.sidebar.View(), chatView)
	}
	return chatView
}

// -- Rendering helpers --------------------------------------------------------

// renderConnecting shows the ASCII logo with a connecting message.
func (m Model) renderConnecting() string {
	gradLogo := logo.RenderWithGradient(m.width)
	label := style.BannerTitle.Render("  Connecting to OSA backend...")
	return gradLogo + "\n\n" + label
}

// osaLogo is the ASCII art displayed on startup and the connecting screen.
const osaLogo = ` ██████╗ ███████╗ █████╗
██╔═══██╗██╔════╝██╔══██╗
██║   ██║███████╗███████║
██║   ██║╚════██║██╔══██║
╚██████╔╝███████║██║  ██║
 ╚═════╝ ╚══════╝╚═╝  ╚═╝`

// -- Help text ----------------------------------------------------------------

// dynamicHelpText builds grouped help from fetched command entries.
// Falls back to staticHelpText when no commands have been fetched.
func (m Model) dynamicHelpText() string {
	if len(m.commandEntries) == 0 {
		return staticHelpText()
	}

	categoryOrder := []string{
		"info", "session", "channels", "context", "intelligence",
		"config", "agents", "workflow", "priming", "security",
		"memory", "scheduler", "tasks", "analytics", "auth", "system",
	}
	categoryLabels := map[string]string{
		"info": "Info", "session": "Session", "channels": "Channels",
		"context": "Context", "intelligence": "Intelligence",
		"config": "Configuration", "agents": "Agents & Swarms",
		"workflow": "Workflow", "priming": "Context Priming",
		"security": "Security", "memory": "Memory",
		"scheduler": "Scheduler", "tasks": "Tasks",
		"analytics": "Analytics & Tools", "auth": "Authentication",
		"system": "System",
	}

	groups := make(map[string][]client.CommandEntry)
	for _, cmd := range m.commandEntries {
		cat := cmd.Category
		if cat == "" {
			cat = "system"
		}
		groups[cat] = append(groups[cat], cmd)
	}

	var b strings.Builder
	b.WriteString("Available commands:\n")

	for _, cat := range categoryOrder {
		cmds, ok := groups[cat]
		if !ok || len(cmds) == 0 {
			continue
		}
		label := categoryLabels[cat]
		if label == "" {
			label = cat
		}
		b.WriteString(fmt.Sprintf("\n  %s:\n", label))
		for _, cmd := range cmds {
			b.WriteString(fmt.Sprintf("    /%-18s %s\n", cmd.Name, cmd.Description))
		}
	}

	// Any categories not in the order list.
	for cat, cmds := range groups {
		found := false
		for _, c := range categoryOrder {
			if c == cat {
				found = true
				break
			}
		}
		if !found && len(cmds) > 0 {
			b.WriteString(fmt.Sprintf("\n  %s:\n", cat))
			for _, cmd := range cmds {
				b.WriteString(fmt.Sprintf("    /%-18s %s\n", cmd.Name, cmd.Description))
			}
		}
	}

	b.WriteString(keybindingsHelp())
	return b.String()
}

func staticHelpText() string {
	return `Commands:
  /help          Show this help
  /status        System status
  /models        Browse & switch models (↑↓ picker)
  /model         Show current model
  /model <name>  Switch to model (e.g. /model qwen3:8b)
  /agents        List agent roster
  /tools         List available tools
  /sessions      List all sessions
  /session       Show current session
  /session new   Create new session
  /session <id>  Switch to session
  /bg            List background tasks
  /theme         List or switch themes
  /setup         Open setup wizard (re-configure provider, agent name, etc.)
  /clear         Clear chat history
  /exit          Exit OSA
` + keybindingsHelp()
}

func keybindingsHelp() string {
	return `
Keybindings:
  Enter        Submit message
  Alt+Enter    Insert newline (multi-line input)
  Ctrl+C       Cancel / quit
  Ctrl+L       Toggle sidebar
  Ctrl+O       Expand/collapse details
  Ctrl+T       Toggle thinking box
  Ctrl+B       Move task to background
  Ctrl+K       Command palette
  Ctrl+N       New session
  Ctrl+U       Clear input
  F1           Show this help
  Home         Scroll to top
  End          Scroll to bottom
  PgUp/PgDn    Scroll chat history
  j/k          Scroll (when input not focused)
  u/d          Half-page scroll (when input not focused)
  Tab          Autocomplete commands
  Up/Down      Navigate input history

Tips:
  · Use Alt+Enter to compose multi-line messages
  · Ctrl+B moves a running task to background
  · Ctrl+L toggles the sidebar panel
  · /sessions lists sessions; /session <id> to switch`
}
