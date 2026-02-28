package model

import (
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/miosa/osa-tui/markdown"
	"github.com/miosa/osa-tui/style"
)

// Signal mirrors client.Signal to avoid an import cycle.
// (client imports msg; model must not import client.)
type Signal struct {
	Mode      string
	Genre     string
	Type      string
	Format    string
	Weight    float64
	Channel   string
	Timestamp string
}

// messageRole identifies who sent a message.
type messageRole int

const (
	roleUser messageRole = iota
	roleAgent
	roleSystem
)

// systemLevel classifies system message severity.
type systemLevel int

const (
	levelInfo    systemLevel = iota // default — dim gray border
	levelWarning                    // amber border
	levelError                      // red border
)

// ChatMessage is a single entry in the conversation history.
type ChatMessage struct {
	Role       messageRole
	Content    string
	Signal     *Signal
	Timestamp  time.Time
	DurationMs int64       // agent response wall time
	ModelName  string      // model that produced the response
	Level      systemLevel // system message severity (only for roleSystem)
}

// ChatModel is a scrollable viewport that displays conversation history.
type ChatModel struct {
	vp             viewport.Model
	messages       []ChatMessage
	width          int
	height         int
	welcomeVersion string
	welcomeDetail  string
	welcomeCwd     string
	processingView string // activity/thinking rendered inline after messages during processing
}

// NewChat constructs a ChatModel sized to width x height.
func NewChat(width, height int) ChatModel {
	vp := viewport.New(width, height)
	vp.SetContent("")
	return ChatModel{
		vp:     vp,
		width:  width,
		height: height,
	}
}

// SetWelcomeData populates the welcome screen with version, provider detail, and CWD.
func (m *ChatModel) SetWelcomeData(version, detail, cwd string) {
	m.welcomeVersion = version
	m.welcomeDetail = detail
	m.welcomeCwd = cwd
	if len(m.messages) == 0 {
		m.refresh()
	}
}

// AddUserMessage appends a user-role message and scrolls to the bottom.
func (m *ChatModel) AddUserMessage(text string) {
	m.messages = append(m.messages, ChatMessage{
		Role:      roleUser,
		Content:   text,
		Timestamp: time.Now(),
	})
	m.refresh()
}

// AddAgentMessage appends an agent-role message with optional Signal metadata.
func (m *ChatModel) AddAgentMessage(text string, sig *Signal, durationMs int64, modelName string) {
	m.messages = append(m.messages, ChatMessage{
		Role:       roleAgent,
		Content:    text,
		Signal:     sig,
		Timestamp:  time.Now(),
		DurationMs: durationMs,
		ModelName:  modelName,
	})
	m.refresh()
}

// AddSystemMessage appends a dimmed system-role message (info level).
func (m *ChatModel) AddSystemMessage(text string) {
	m.messages = append(m.messages, ChatMessage{
		Role:      roleSystem,
		Content:   text,
		Timestamp: time.Now(),
		Level:     levelInfo,
	})
	m.refresh()
}

// AddSystemWarning appends a warning-level system message with amber border.
func (m *ChatModel) AddSystemWarning(text string) {
	m.messages = append(m.messages, ChatMessage{
		Role:      roleSystem,
		Content:   text,
		Timestamp: time.Now(),
		Level:     levelWarning,
	})
	m.refresh()
}

// AddSystemError appends an error-level system message with red border.
func (m *ChatModel) AddSystemError(text string) {
	m.messages = append(m.messages, ChatMessage{
		Role:      roleSystem,
		Content:   text,
		Timestamp: time.Now(),
		Level:     levelError,
	})
	m.refresh()
}

// SetProcessingView sets the inline activity/thinking view shown below messages
// during processing. Pass empty string to clear.
func (m *ChatModel) SetProcessingView(view string) {
	m.processingView = view
	m.refresh()
}

// ClearProcessingView removes the inline processing indicator.
func (m *ChatModel) ClearProcessingView() {
	m.processingView = ""
	m.refresh()
}

// ScrollToTop scrolls the chat viewport to the very top.
func (m *ChatModel) ScrollToTop() {
	m.vp.GotoTop()
}

// ScrollToBottom scrolls the chat viewport to the very bottom.
func (m *ChatModel) ScrollToBottom() {
	m.vp.GotoBottom()
}

// SetSize resizes the underlying viewport.
func (m *ChatModel) SetSize(width, height int) {
	m.width = width
	m.height = height
	m.vp.Width = width
	m.vp.Height = height
	m.refresh()
}

// Init satisfies tea.Model.
func (m ChatModel) Init() tea.Cmd {
	return nil
}

// Update forwards keyboard and mouse events to the viewport.
// It satisfies tea.Model so callers can type-assert the return value.
func (m ChatModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	var cmd tea.Cmd
	m.vp, cmd = m.vp.Update(msg)
	return m, cmd
}

// View returns the rendered viewport content.
func (m ChatModel) View() string {
	return m.vp.View()
}

// refresh re-renders all messages into the viewport and scrolls to the bottom.
func (m *ChatModel) refresh() {
	m.vp.SetContent(m.renderAll())
	m.vp.GotoBottom()
}

// renderAll builds the full string of all rendered messages.
func (m *ChatModel) renderAll() string {
	if len(m.messages) == 0 {
		return m.renderWelcome()
	}

	var sb strings.Builder
	for i, msg := range m.messages {
		if i > 0 {
			sb.WriteString("\n")
		}
		sb.WriteString(m.renderMessage(msg))
	}
	// Append inline processing/activity view during processing
	if m.processingView != "" {
		sb.WriteString("\n")
		sb.WriteString(m.processingView)
	}
	return sb.String()
}

// renderWelcome produces the vertically-centered welcome screen shown when
// no messages exist yet.
func (m *ChatModel) renderWelcome() string {
	logoStyle := lipgloss.NewStyle().Foreground(style.Primary)
	logo := logoStyle.Render(OsaLogo)

	title := style.WelcomeTitle.Render(fmt.Sprintf("◈ OSA Agent  %s", m.welcomeVersion))
	detail := style.WelcomeMeta.Render(m.welcomeDetail)
	// Truncate CWD to fit viewport width with some margin
	cwdPath := m.welcomeCwd
	maxCwd := m.width - 10
	if maxCwd < 20 {
		maxCwd = 20
	}
	if len(cwdPath) > maxCwd {
		cwdPath = truncatePath(cwdPath, maxCwd)
	}
	cwd := style.WelcomeCwd.Render(cwdPath)
	tip := style.WelcomeTip.Render("/help for help  ·  Ctrl+O expand  ·  Ctrl+B background")

	// Center each line
	center := func(s string) string {
		w := lipgloss.Width(s)
		if w >= m.width {
			return s
		}
		pad := (m.width - w) / 2
		return strings.Repeat(" ", pad) + s
	}

	var lines []string
	for _, l := range strings.Split(logo, "\n") {
		lines = append(lines, center(l))
	}
	lines = append(lines, "")
	lines = append(lines, center(title))
	lines = append(lines, center(detail))
	if cwd != "" {
		lines = append(lines, center(cwd))
	}
	lines = append(lines, "")
	lines = append(lines, center(tip))

	return strings.Join(lines, "\n")
}

// renderMessage converts a single ChatMessage to a display string with
// OpenCode-style thick left borders.
func (m *ChatModel) renderMessage(msg ChatMessage) string {
	contentWidth := m.width - 5 // border (2) + padding (2) + margin
	if contentWidth < 20 {
		contentWidth = 20
	}

	switch msg.Role {
	case roleUser:
		label := style.UserLabel.Render("❯  You")
		border := lipgloss.NewStyle().
			Border(lipgloss.ThickBorder(), false, false, false, true).
			BorderForeground(style.MsgBorderUser).
			PaddingLeft(1).
			Width(contentWidth)
		return border.Render(label + "\n" + msg.Content)

	case roleAgent:
		label := style.AgentLabel.Render("◈ OSA")
		if msg.Signal != nil && msg.Signal.Mode != "" && msg.Signal.Genre != "" {
			badge := style.StatusSignal.Render(
				fmt.Sprintf(" [%s/%s]", msg.Signal.Mode, msg.Signal.Genre),
			)
			label += badge
		}

		rendered := markdown.RenderWidth(msg.Content, contentWidth-2)
		rendered = strings.TrimRight(rendered, "\n")

		// Metadata footer
		var meta string
		if msg.ModelName != "" || msg.DurationMs > 0 {
			var parts []string
			if msg.ModelName != "" {
				parts = append(parts, msg.ModelName)
			}
			if msg.DurationMs > 0 {
				parts = append(parts, formatDuration(msg.DurationMs))
			}
			meta = "\n" + style.MsgMeta.Render("— "+strings.Join(parts, " · "))
		}

		border := lipgloss.NewStyle().
			Border(lipgloss.ThickBorder(), false, false, false, true).
			BorderForeground(style.MsgBorderAgent).
			PaddingLeft(1).
			Width(contentWidth)
		return border.Render(label + "\n" + rendered + meta)

	case roleSystem:
		// Choose border color based on level
		borderColor := style.MsgBorderSystem
		switch msg.Level {
		case levelWarning:
			borderColor = style.MsgBorderWarning
		case levelError:
			borderColor = style.MsgBorderError
		}

		var content string
		switch msg.Level {
		case levelError:
			content = style.ErrorText.Render(msg.Content)
		case levelWarning:
			content = lipgloss.NewStyle().Foreground(style.Warning).Render(msg.Content)
		default:
			content = style.Faint.Render(msg.Content)
		}

		border := lipgloss.NewStyle().
			Border(lipgloss.NormalBorder(), false, false, false, true).
			BorderForeground(borderColor).
			PaddingLeft(1).
			Width(contentWidth)
		return border.Render(content)

	default:
		return msg.Content
	}
}

// formatDuration converts milliseconds to a human-readable duration.
func formatDuration(ms int64) string {
	if ms < 1000 {
		return fmt.Sprintf("%dms", ms)
	}
	return fmt.Sprintf("%.1fs", float64(ms)/1000.0)
}
