package model

import (
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
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

// ChatMessage is a single entry in the conversation history.
type ChatMessage struct {
	Role      messageRole
	Content   string
	Signal    *Signal
	Timestamp time.Time
}

// ChatModel is a scrollable viewport that displays conversation history.
type ChatModel struct {
	vp       viewport.Model
	messages []ChatMessage
	width    int
	height   int
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
func (m *ChatModel) AddAgentMessage(text string, sig *Signal) {
	m.messages = append(m.messages, ChatMessage{
		Role:      roleAgent,
		Content:   text,
		Signal:    sig,
		Timestamp: time.Now(),
	})
	m.refresh()
}

// AddSystemMessage appends a dimmed system-role message.
func (m *ChatModel) AddSystemMessage(text string) {
	m.messages = append(m.messages, ChatMessage{
		Role:      roleSystem,
		Content:   text,
		Timestamp: time.Now(),
	})
	m.refresh()
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
		return style.Faint.Render("  No messages yet. Type below to get started.")
	}

	var sb strings.Builder
	for i, msg := range m.messages {
		if i > 0 {
			sb.WriteString("\n")
		}
		sb.WriteString(renderMessage(msg))
	}
	return sb.String()
}

// renderMessage converts a single ChatMessage to a display string.
func renderMessage(msg ChatMessage) string {
	switch msg.Role {
	case roleUser:
		return style.UserLabel.Render("❯ You") + "\n" + msg.Content

	case roleAgent:
		label := style.AgentLabel.Render("◈ OSA")
		if msg.Signal != nil && msg.Signal.Mode != "" && msg.Signal.Genre != "" {
			badge := style.StatusSignal.Render(
				fmt.Sprintf(" [%s/%s]", msg.Signal.Mode, msg.Signal.Genre),
			)
			label += badge
		}
		return label + "\n" + markdown.Render(msg.Content)

	case roleSystem:
		return style.Faint.Render(msg.Content)

	default:
		return msg.Content
	}
}
