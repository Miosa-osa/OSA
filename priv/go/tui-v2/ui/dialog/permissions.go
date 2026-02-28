package dialog

import (
	"fmt"
	"strings"

	"charm.land/bubbles/v2/viewport"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/miosa/osa-tui/style"
)

// ──────────────────────────────────────────────────────────────────────────────
// PermissionsModel
// ──────────────────────────────────────────────────────────────────────────────

// PermissionsModel is the tool permission approval dialog. It is the most
// critical dialog in OSA TUI: every tool call that requires user approval
// flows through here.
//
// For edit tools it renders a diff view (unified or split), scrollable via
// a viewport. For other tools it shows the tool name and raw arguments.
//
// Emits PermissionDecision when dismissed.
type PermissionsModel struct {
	toolName    string
	toolArgs    string // raw JSON args
	description string // human-readable description
	diffContent string // unified diff (pre-formatted)
	oldContent  string // original file content (split diff left)
	newContent  string // new file content (split diff right)
	filename    string

	viewport   viewport.Model
	splitView  bool // toggle unified ↔ split diff
	fullscreen bool
	activeBtn  int // 0=Allow, 1=AllowSession, 2=Deny
	toolCallID string

	width, height int
	hasDiff       bool
}

// NewPermissions returns a zero-value PermissionsModel ready to be populated.
func NewPermissions() PermissionsModel {
	vp := viewport.New(viewport.WithWidth(60), viewport.WithHeight(10))
	vp.SoftWrap = true
	return PermissionsModel{
		viewport: vp,
	}
}

// SetTool configures the dialog for a non-diff tool invocation.
func (m *PermissionsModel) SetTool(toolCallID, name, args, description string) {
	m.toolCallID = toolCallID
	m.toolName = name
	m.toolArgs = args
	m.description = description
	m.hasDiff = false
	m.activeBtn = 0
	m.rebuildViewport()
}

// SetDiff adds diff content for file-editing tools. Call after SetTool.
func (m *PermissionsModel) SetDiff(old, newContent, filename string) {
	m.oldContent = old
	m.newContent = newContent
	m.filename = filename
	m.hasDiff = true
	m.rebuildViewport()
}

// SetSize updates terminal dimensions and resizes the viewport accordingly.
func (m *PermissionsModel) SetSize(w, h int) {
	m.width = w
	m.height = h
	m.resizeViewport()
}

func (m *PermissionsModel) resizeViewport() {
	vpW := m.dialogWidth() - 6 // border (1) + padding (2) each side
	if vpW < 20 {
		vpW = 20
	}
	vpH := m.viewportHeight()
	m.viewport.SetWidth(vpW)
	m.viewport.SetHeight(vpH)
}

func (m PermissionsModel) dialogWidth() int {
	if m.fullscreen {
		if m.width > 0 {
			return m.width - 2
		}
		return 100
	}
	w := m.width - 4
	if w > 90 {
		w = 90
	}
	if w < 50 {
		w = 50
	}
	return w
}

func (m PermissionsModel) viewportHeight() int {
	// Total dialog height minus: title(2) + tool header(3) + buttons(3) + help(2) + borders(4)
	available := m.height - 14
	if m.fullscreen {
		available = m.height - 12
	}
	if available < 5 {
		available = 5
	}
	if available > 30 {
		available = 30
	}
	return available
}

func (m *PermissionsModel) rebuildViewport() {
	m.resizeViewport()
	m.viewport.SetContent(m.buildViewportContent())
	m.viewport.SetYOffset(0)
}

func (m PermissionsModel) buildViewportContent() string {
	if !m.hasDiff {
		return m.buildArgsContent()
	}
	if m.splitView {
		return m.buildSplitDiff()
	}
	return m.buildUnifiedDiff()
}

func (m PermissionsModel) buildArgsContent() string {
	if m.description != "" {
		desc := lipgloss.NewStyle().Foreground(style.Muted).Render(m.description)
		if m.toolArgs == "" {
			return desc
		}
		args := lipgloss.NewStyle().Foreground(style.Secondary).Render(m.toolArgs)
		return desc + "\n\n" + args
	}
	if m.toolArgs != "" {
		return lipgloss.NewStyle().Foreground(style.Secondary).Render(m.toolArgs)
	}
	return lipgloss.NewStyle().Foreground(style.Muted).Render("(no arguments)")
}

func (m PermissionsModel) buildUnifiedDiff() string {
	if m.diffContent != "" {
		return renderDiffLines(m.diffContent)
	}
	// Generate a simple unified diff from old/new content.
	return renderDiffLines(generateSimpleDiff(m.oldContent, m.newContent, m.filename))
}

func (m PermissionsModel) buildSplitDiff() string {
	oldLines := strings.Split(m.oldContent, "\n")
	newLines := strings.Split(m.newContent, "\n")

	halfW := (m.viewport.Width() - 3) / 2
	if halfW < 10 {
		halfW = 10
	}

	var sb strings.Builder
	sep := style.DiffContext.Render(strings.Repeat("│", 1))

	maxLines := len(oldLines)
	if len(newLines) > maxLines {
		maxLines = len(newLines)
	}

	for i := 0; i < maxLines; i++ {
		var left, right string

		if i < len(oldLines) {
			left = truncateStr(oldLines[i], halfW)
			if strings.HasPrefix(oldLines[i], "-") || (i >= len(newLines)) {
				left = style.DiffRemove.Render(fmt.Sprintf("%-*s", halfW, left))
			} else {
				left = style.DiffContext.Render(fmt.Sprintf("%-*s", halfW, left))
			}
		} else {
			left = strings.Repeat(" ", halfW)
		}

		if i < len(newLines) {
			right = truncateStr(newLines[i], halfW)
			if strings.HasPrefix(newLines[i], "+") || (i >= len(oldLines)) {
				right = style.DiffAdd.Render(right)
			} else {
				right = style.DiffContext.Render(right)
			}
		}

		sb.WriteString(left + " " + sep + " " + right)
		if i < maxLines-1 {
			sb.WriteByte('\n')
		}
	}
	return sb.String()
}

// renderDiffLines applies color styling to a unified diff string.
func renderDiffLines(diff string) string {
	lines := strings.Split(diff, "\n")
	var out []string
	for _, line := range lines {
		switch {
		case strings.HasPrefix(line, "+++") || strings.HasPrefix(line, "---"):
			out = append(out, style.FilePath.Render(line))
		case strings.HasPrefix(line, "+"):
			out = append(out, style.DiffAdd.Render(line))
		case strings.HasPrefix(line, "-"):
			out = append(out, style.DiffRemove.Render(line))
		case strings.HasPrefix(line, "@@"):
			out = append(out, style.DiffHunkLabel.Render(line))
		default:
			out = append(out, style.DiffContext.Render(line))
		}
	}
	return strings.Join(out, "\n")
}

// generateSimpleDiff produces a minimal unified diff header from old/new content.
func generateSimpleDiff(oldContent, newContent, filename string) string {
	if oldContent == "" && newContent == "" {
		return "(empty diff)"
	}
	var sb strings.Builder
	if filename != "" {
		sb.WriteString(fmt.Sprintf("--- a/%s\n+++ b/%s\n", filename, filename))
	}
	oldLines := strings.Split(oldContent, "\n")
	newLines := strings.Split(newContent, "\n")
	sb.WriteString(fmt.Sprintf("@@ -%d +%d @@\n", len(oldLines), len(newLines)))
	for _, l := range oldLines {
		if l != "" {
			sb.WriteString("-" + l + "\n")
		}
	}
	for _, l := range newLines {
		if l != "" {
			sb.WriteString("+" + l + "\n")
		}
	}
	return strings.TrimRight(sb.String(), "\n")
}

func truncateStr(s string, max int) string {
	runes := []rune(s)
	if len(runes) <= max {
		return s
	}
	if max <= 3 {
		return string(runes[:max])
	}
	return string(runes[:max-3]) + "..."
}

// ──────────────────────────────────────────────────────────────────────────────
// Update
// ──────────────────────────────────────────────────────────────────────────────

// Update handles keyboard input for the permissions dialog.
// Key map:
//
//	y / enter       → Allow
//	s               → Allow Session
//	n / esc         → Deny
//	tab / → / ←    → cycle button focus
//	ctrl+s          → toggle split/unified diff
//	f               → toggle fullscreen
//	j / k / ↑ / ↓  → scroll viewport
//	page down/up    → page scroll
func (m PermissionsModel) Update(msg tea.Msg) (PermissionsModel, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyPressMsg:
		switch msg.Code {
		// Decision shortcuts.
		case 'y':
			return m, m.decide("allow")

		case 's':
			// ctrl+s toggles diff view; plain 's' selects AllowSession.
			if msg.Mod&tea.ModCtrl != 0 {
				if m.hasDiff {
					m.splitView = !m.splitView
					m.viewport.SetContent(m.buildViewportContent())
				}
				return m, nil
			}
			return m, m.decide("allow_session")

		case 'n':
			return m, m.decide("deny")

		case tea.KeyEnter:
			return m, m.decideByActiveBtn()

		case tea.KeyEscape:
			return m, m.decide("deny")

		// Button navigation.
		case tea.KeyTab:
			m.activeBtn = (m.activeBtn + 1) % 3
			return m, nil

		case tea.KeyRight:
			m.activeBtn = (m.activeBtn + 1) % 3
			return m, nil

		case tea.KeyLeft:
			m.activeBtn = (m.activeBtn + 2) % 3
			return m, nil

		// Viewport scrolling.
		case 'j', tea.KeyDown:
			m.viewport.SetYOffset(m.viewport.YOffset() + 1)
			return m, nil

		case 'k', tea.KeyUp:
			m.viewport.SetYOffset(m.viewport.YOffset() - 1)
			return m, nil

		case tea.KeyPgDown:
			m.viewport.SetYOffset(m.viewport.YOffset() + m.viewportHeight())
			return m, nil

		case tea.KeyPgUp:
			m.viewport.SetYOffset(m.viewport.YOffset() - m.viewportHeight())
			return m, nil

		// Fullscreen toggle.
		case 'f':
			m.fullscreen = !m.fullscreen
			m.resizeViewport()
			m.viewport.SetContent(m.buildViewportContent())
			return m, nil
		}
	}

	// Forward remaining messages to viewport.
	var cmd tea.Cmd
	m.viewport, cmd = m.viewport.Update(msg)
	return m, cmd
}

func (m PermissionsModel) decide(decision string) tea.Cmd {
	id := m.toolCallID
	return func() tea.Msg {
		return PermissionDecision{ToolCallID: id, Decision: decision}
	}
}

func (m PermissionsModel) decideByActiveBtn() tea.Cmd {
	switch m.activeBtn {
	case 0:
		return m.decide("allow")
	case 1:
		return m.decide("allow_session")
	default:
		return m.decide("deny")
	}
}

// ──────────────────────────────────────────────────────────────────────────────
// View
// ──────────────────────────────────────────────────────────────────────────────

// View renders the full permissions dialog.
func (m PermissionsModel) View() string {
	dw := m.dialogWidth()

	var sb strings.Builder

	// Title row.
	title := GradientTitle("Permission Request")
	sb.WriteString(title)
	sb.WriteByte('\n')
	sb.WriteString(style.DiffContext.Render(strings.Repeat("─", dw-6)))
	sb.WriteByte('\n')

	// Tool identification.
	toolLabel := style.ToolHeader.Render(m.toolName)
	if m.filename != "" {
		fileLabel := style.FilePath.Render("  " + m.filename)
		sb.WriteString(toolLabel + fileLabel)
	} else {
		sb.WriteString(toolLabel)
	}
	sb.WriteByte('\n')
	sb.WriteByte('\n')

	// Diff mode toggle hint (only when diff is present).
	if m.hasDiff {
		var modeStr string
		if m.splitView {
			modeStr = "split"
		} else {
			modeStr = "unified"
		}
		modeLabel := lipgloss.NewStyle().Foreground(style.Muted).
			Render(fmt.Sprintf("  diff: %s  ctrl+s to toggle", modeStr))
		sb.WriteString(modeLabel)
		sb.WriteByte('\n')
	}

	// Viewport (scrollable content area).
	sb.WriteString(m.viewport.View())
	sb.WriteByte('\n')
	sb.WriteByte('\n')

	// Buttons.
	buttons := []ButtonDef{
		{Label: "Allow (y)", Shortcut: "y", Active: m.activeBtn == 0, Underline: 0},
		{Label: "Allow Session (s)", Shortcut: "s", Active: m.activeBtn == 1, Underline: 6},
		{Label: "Deny (n)", Shortcut: "n", Active: m.activeBtn == 2, Danger: m.activeBtn == 2, Underline: 0},
	}
	sb.WriteString(RenderButtons(buttons, dw-6))
	sb.WriteByte('\n')
	sb.WriteByte('\n')

	// Help bar.
	helpItems := []HelpItem{
		{Key: "← →", Desc: "navigate"},
		{Key: "y", Desc: "allow"},
		{Key: "s", Desc: "session"},
		{Key: "n", Desc: "deny"},
		{Key: "j/k", Desc: "scroll"},
		{Key: "f", Desc: "fullscreen"},
	}
	if m.hasDiff {
		helpItems = append(helpItems, HelpItem{Key: "ctrl+s", Desc: "toggle diff"})
	}
	sb.WriteString(RenderHelpBar(helpItems, dw-6))

	// Frame.
	frameStyle := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(style.Primary).
		Padding(1, 2).
		Width(dw)

	var termW, termH int
	if m.width > 0 {
		termW = m.width
	} else {
		termW = 100
	}
	if m.height > 0 {
		termH = m.height
	} else {
		termH = 40
	}

	box := frameStyle.Render(sb.String())
	return lipgloss.Place(termW, termH, lipgloss.Center, lipgloss.Center, box)
}
