// Package chat provides the full-featured, trait-based chat message list for OSA TUI v2.
//
// Architecture:
//
//	Item interface  — every message type implements Height/Render/ID/ContentVersion
//	messageItem     — sealed union (user | agent | system) with per-item render cache
//	ThinkingBox     — collapsible extended-thinking widget (▸/▾ toggle)
//	Model           — viewport-backed list that owns the item slice and ephemeral overlays
//
// Rendering is cached per-item by (width, ContentVersion). Cache is invalidated on resize
// or content mutation so each frame only re-renders dirty items.
package chat

import (
	"fmt"
	"strings"
	"time"

	"charm.land/bubbles/v2/viewport"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/glamour"
	"github.com/miosa/osa-tui/style"
	"github.com/miosa/osa-tui/ui/tools"
)

// ---------------------------------------------------------------------------
// Public types shared with app.go
// ---------------------------------------------------------------------------

// MessageRole identifies the originator of a chat message.
type MessageRole int

const (
	RoleUser   MessageRole = iota
	RoleAgent              // assistant / OSA
	RoleSystem             // info / warning / error system notices
)

// SystemLevel classifies the severity of a system message.
type SystemLevel int

const (
	LevelInfo    SystemLevel = iota // dim gray border
	LevelWarning                    // amber border
	LevelError                      // red border
)

// Signal carries signal-classification metadata attached to agent messages.
type Signal struct {
	Mode      string
	Genre     string
	Type      string
	Format    string
	Channel   string
	Timestamp string
	Weight    float64
}

// ToolCallDisplay is a snapshot of a tool invocation embedded in an agent message.
type ToolCallDisplay struct {
	Name       string
	Args       string
	Result     string
	DurationMs int64
	Done       bool
	Success    bool
}

// ToolStatus describes the lifecycle state of a tool call.
type ToolStatus int

const (
	ToolPending  ToolStatus = iota
	ToolRunning             // in flight
	ToolSuccess             // finished successfully
	ToolError               // finished with error
	ToolCanceled            // cancelled before completion
)

// ---------------------------------------------------------------------------
// Item interface — trait system for message items
// ---------------------------------------------------------------------------

// Item is the trait every message variant must satisfy.
// Height and Render receive the current usable content width (not the full
// terminal width) so callers do not need to account for borders/padding.
type Item interface {
	// ID returns a stable identifier for this item (used in debug output).
	ID() string
	// ContentVersion is incremented whenever the item's content changes.
	// The render cache is invalidated when this value or width change.
	ContentVersion() int
	// Height returns the number of terminal lines this item occupies at width.
	Height(width int) string
	// Render produces the full styled display string at the given width.
	Render(width int) string
}

// ---------------------------------------------------------------------------
// Per-item render cache
// ---------------------------------------------------------------------------

type renderCache struct {
	output        string
	cachedWidth   int
	cachedVersion int
}

func (c *renderCache) get(width, version int) (string, bool) {
	if c.cachedWidth == width && c.cachedVersion == version {
		return c.output, true
	}
	return "", false
}

func (c *renderCache) set(width, version int, output string) {
	c.cachedWidth = width
	c.cachedVersion = version
	c.output = output
}

// ---------------------------------------------------------------------------
// Width helpers
// ---------------------------------------------------------------------------

const maxContentWidth = 120

// cappedWidth caps the content width at maxContentWidth for readability.
func cappedWidth(w int) int {
	if w > maxContentWidth {
		return maxContentWidth
	}
	return w
}

// ---------------------------------------------------------------------------
// ThinkingBox — collapsible extended-thinking widget
// ---------------------------------------------------------------------------

const thinkingCollapsedLines = 10

// ThinkingBox holds the live extended-thinking content and its collapse state.
type ThinkingBox struct {
	content    string
	expanded   bool
	startedAt  time.Time
	durationMs int64 // set when thinking finishes; 0 means still active
}

// SetContent replaces the thinking text.
func (tb *ThinkingBox) SetContent(s string) {
	if s != "" && tb.content == "" {
		tb.startedAt = time.Now()
	}
	tb.content = s
}

// SetDuration records the final thinking duration in milliseconds.
func (tb *ThinkingBox) SetDuration(ms int64) { tb.durationMs = ms }

// Toggle flips the collapsed/expanded state.
func (tb *ThinkingBox) Toggle() { tb.expanded = !tb.expanded }

// IsExpanded reports whether the box is currently expanded.
func (tb *ThinkingBox) IsExpanded() bool { return tb.expanded }

// HasContent reports whether there is any thinking text.
func (tb *ThinkingBox) HasContent() bool { return tb.content != "" }

// HandleMouseClick toggles expansion when the user clicks on the header row.
// clickY is the y-coordinate of the click relative to the top of the ThinkingBox.
func (tb *ThinkingBox) HandleMouseClick(clickY int) {
	if clickY == 0 {
		tb.Toggle()
	}
}

// activeDurationLabel returns a live "Xs" duration string while thinking is running.
func (tb *ThinkingBox) activeDurationLabel() string {
	if tb.durationMs > 0 {
		return formatDuration(tb.durationMs)
	}
	if !tb.startedAt.IsZero() {
		ms := time.Since(tb.startedAt).Milliseconds()
		return formatDuration(ms)
	}
	return ""
}

// Render produces the styled thinking box at the given content width.
func (tb *ThinkingBox) Render(contentWidth int) string {
	cw := cappedWidth(contentWidth)

	toggle := "▸"
	if tb.expanded {
		toggle = "▾"
	}

	lines := strings.Split(tb.content, "\n")
	totalLines := len(lines)

	dur := tb.activeDurationLabel()
	durLabel := ""
	if dur != "" {
		durLabel = " (" + dur + ")"
	}

	var headerSuffix string
	if !tb.expanded && totalLines > thinkingCollapsedLines {
		headerSuffix = fmt.Sprintf(" (%d lines)", totalLines)
	}
	header := style.ThinkingHeader.Render(toggle + " Thinking" + durLabel + headerSuffix)

	displayLines := lines
	if !tb.expanded && totalLines > thinkingCollapsedLines {
		displayLines = append(
			lines[:thinkingCollapsedLines],
			style.Faint.Render(fmt.Sprintf(
				"… %d more lines (Ctrl+T to expand)", totalLines-thinkingCollapsedLines,
			)),
		)
	}
	body := style.ThinkingContent.Render(strings.Join(displayLines, "\n"))

	box := lipgloss.NewStyle().
		Border(lipgloss.NormalBorder(), false, false, false, true).
		BorderForeground(style.Warning).
		PaddingLeft(1).
		Width(cw)
	return box.Render(header + "\n" + body)
}

// ---------------------------------------------------------------------------
// Concrete Item implementations
// ---------------------------------------------------------------------------

// userMessageItem wraps a user-sent message.
type userMessageItem struct {
	id      string
	content string
	ts      time.Time
	version int
	cache   renderCache
}

func newUserItem(id, content string) *userMessageItem {
	return &userMessageItem{id: id, content: content, ts: time.Now()}
}

func (u *userMessageItem) ID() string              { return u.id }
func (u *userMessageItem) ContentVersion() int     { return u.version }
func (u *userMessageItem) Height(width int) string { return u.Render(width) }

func (u *userMessageItem) Render(cw int) string {
	cw = cappedWidth(cw)
	if out, ok := u.cache.get(cw, u.version); ok {
		return out
	}
	label := style.UserLabel.Render("❯  You")
	border := lipgloss.NewStyle().
		Border(lipgloss.ThickBorder(), false, false, false, true).
		BorderForeground(style.MsgBorderUser).
		PaddingLeft(1).
		Width(cw)
	out := border.Render(label + "\n" + u.content)
	u.cache.set(cw, u.version, out)
	return out
}

// assistantMessageItem wraps an agent / OSA message with all metadata.
type assistantMessageItem struct {
	id           string
	content      string
	signal       *Signal
	toolCalls    []ToolCallDisplay
	durationMs   int64
	modelName    string
	inputTokens  int64
	outputTokens int64
	ts           time.Time
	version      int
	isError      bool // render with error styling
	isCancelled  bool // render as cancelled/faded
	cache        renderCache
}

func newAssistantItem(id, content string, sig *Signal, durationMs int64, model string) *assistantMessageItem {
	return &assistantMessageItem{
		id:         id,
		content:    content,
		signal:     sig,
		durationMs: durationMs,
		modelName:  model,
		ts:         time.Now(),
	}
}

func (a *assistantMessageItem) ID() string              { return a.id }
func (a *assistantMessageItem) ContentVersion() int     { return a.version }
func (a *assistantMessageItem) Height(width int) string { return a.Render(width) }

// shouldSkip returns true when this message has no content and no tool calls —
// nothing meaningful to render.
func (a *assistantMessageItem) shouldSkip() bool {
	return strings.TrimSpace(a.content) == "" && len(a.toolCalls) == 0
}

func (a *assistantMessageItem) Render(cw int) string {
	cw = cappedWidth(cw)
	if out, ok := a.cache.get(cw, a.version); ok {
		return out
	}

	// Error state: red border, error prefix.
	borderColor := style.MsgBorderAgent
	if a.isError {
		borderColor = style.MsgBorderError
	} else if a.isCancelled {
		borderColor = style.MsgBorderSystem
	}

	// Label + optional signal badge
	labelText := "◈ OSA"
	if a.isError {
		labelText = "✗ OSA"
	} else if a.isCancelled {
		labelText = "◈ OSA (cancelled)"
	}
	label := style.AgentLabel.Render(labelText)
	if a.signal != nil && a.signal.Mode != "" && a.signal.Genre != "" {
		badge := style.StatusSignal.Render(
			fmt.Sprintf(" [%s/%s]", a.signal.Mode, a.signal.Genre),
		)
		label += badge
	}

	// Markdown-rendered body
	var body string
	if a.isCancelled {
		body = style.Faint.Render(a.content)
	} else if a.isError {
		body = style.ErrorText.Render(a.content)
	} else {
		body = renderMarkdown(a.content, cw-2)
	}

	// Tool calls dispatched to the tools registry
	var toolSection string
	if len(a.toolCalls) > 0 {
		var tb strings.Builder
		for _, tc := range a.toolCalls {
			tb.WriteString("\n")
			status := toolCallStatus(tc)
			tb.WriteString(tools.RenderToolCall(
				tc.Name, tc.Args, tc.Result,
				tools.RenderOpts{
					Status:     tools.ToolStatus(status),
					Width:      cw - 2,
					Expanded:   false,
					DurationMs: tc.DurationMs,
				},
			))
		}
		toolSection = tb.String()
	}

	// Metadata footer: — model-name · 2.3s · ↓1.2k ↑0.8k
	var meta string
	if a.modelName != "" || a.durationMs > 0 {
		var parts []string
		if a.modelName != "" {
			parts = append(parts, a.modelName)
		}
		if a.durationMs > 0 {
			parts = append(parts, formatDuration(a.durationMs))
		}
		if a.inputTokens > 0 || a.outputTokens > 0 {
			parts = append(parts, fmt.Sprintf("↓%s ↑%s",
				formatTokens(a.inputTokens),
				formatTokens(a.outputTokens),
			))
		}
		meta = "\n" + style.MsgMeta.Render("— "+strings.Join(parts, " · "))
	}

	border := lipgloss.NewStyle().
		Border(lipgloss.ThickBorder(), false, false, false, true).
		BorderForeground(borderColor).
		PaddingLeft(1).
		Width(cw)
	out := border.Render(label + "\n" + body + toolSection + meta)
	a.cache.set(cw, a.version, out)
	return out
}

// toolCallStatus maps the legacy ToolCallDisplay bool pair to ToolStatus.
func toolCallStatus(tc ToolCallDisplay) ToolStatus {
	if !tc.Done {
		return ToolRunning
	}
	if tc.Success {
		return ToolSuccess
	}
	return ToolError
}

// systemMessageItem wraps an info / warning / error system notice.
type systemMessageItem struct {
	id      string
	content string
	level   SystemLevel
	ts      time.Time
	version int
	cache   renderCache
}

func newSystemItem(id, content string, level SystemLevel) *systemMessageItem {
	return &systemMessageItem{id: id, content: content, level: level, ts: time.Now()}
}

func (s *systemMessageItem) ID() string              { return s.id }
func (s *systemMessageItem) ContentVersion() int     { return s.version }
func (s *systemMessageItem) Height(width int) string { return s.Render(width) }

func (s *systemMessageItem) Render(cw int) string {
	cw = cappedWidth(cw)
	if out, ok := s.cache.get(cw, s.version); ok {
		return out
	}

	borderColor := style.MsgBorderSystem
	switch s.level {
	case LevelWarning:
		borderColor = style.MsgBorderWarning
	case LevelError:
		borderColor = style.MsgBorderError
	}

	var text string
	switch s.level {
	case LevelError:
		text = style.ErrorText.Render(s.content)
	case LevelWarning:
		text = lipgloss.NewStyle().Foreground(style.Warning).Render(s.content)
	default:
		text = style.Faint.Render(s.content)
	}

	border := lipgloss.NewStyle().
		Border(lipgloss.NormalBorder(), false, false, false, true).
		BorderForeground(borderColor).
		PaddingLeft(1).
		Width(cw)
	out := border.Render(text)
	s.cache.set(cw, s.version, out)
	return out
}

// ---------------------------------------------------------------------------
// ChatMessage — legacy data type kept for internal use
// ---------------------------------------------------------------------------

// ChatMessage is the internal storage record for a conversation entry.
// It backs the concrete Item implementations above.
type ChatMessage struct {
	Role       MessageRole
	Content    string
	Signal     *Signal
	Timestamp  time.Time
	DurationMs int64
	ModelName  string
	Level      SystemLevel
	ToolCalls  []ToolCallDisplay
}

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

// Model is the Bubble Tea model for the scrollable chat message list.
type Model struct {
	vp      viewport.Model
	items   []Item // ordered slice of all persistent message items
	width   int
	height  int
	focused bool // when true, the active message receives a brighter border

	// Welcome screen data
	welcomeVersion string
	welcomeDetail  string
	welcomeCwd     string

	// Ephemeral overlays (not stored as persistent items)
	processingView   string
	streamingContent string
	thinkingBox      ThinkingBox

	// Tool call accumulator — populated during processing, attached to agent message on completion.
	pendingToolCalls []ToolCallDisplay

	// ID counter for stable item IDs
	nextID int
}

// New constructs a chat Model sized to width × height.
func New(width, height int) Model {
	vp := viewport.New(
		viewport.WithWidth(width),
		viewport.WithHeight(height),
	)
	vp.SetContent("")
	return Model{
		vp:     vp,
		width:  width,
		height: height,
	}
}

// ---------------------------------------------------------------------------
// Mutation methods called by app.go
// ---------------------------------------------------------------------------

// SetSize resizes the viewport and re-renders all content.
// Item render caches are width-keyed, so they are automatically invalidated.
func (m *Model) SetSize(w, h int) {
	m.width = w
	m.height = h
	vp := viewport.New(
		viewport.WithWidth(w),
		viewport.WithHeight(h),
	)
	vp.SetContent("")
	m.vp = vp
	m.refresh()
}

// SetFocused sets the focused state on the chat list. When focused, the
// active assistant message receives a brighter border highlight.
func (m *Model) SetFocused(focused bool) {
	if m.focused == focused {
		return
	}
	m.focused = focused
	m.refresh()
}

// AddUserMessage appends a user message and scrolls to bottom.
func (m *Model) AddUserMessage(text string) {
	m.items = append(m.items, newUserItem(m.genID(), text))
	m.refresh()
}

// AddAgentMessage appends an agent message with optional Signal metadata.
// Any accumulated tool calls from the processing phase are attached and cleared.
func (m *Model) AddAgentMessage(text string, sig *Signal, durationMs int64, modelName string) {
	item := newAssistantItem(m.genID(), text, sig, durationMs, modelName)
	if len(m.pendingToolCalls) > 0 {
		item.toolCalls = make([]ToolCallDisplay, len(m.pendingToolCalls))
		copy(item.toolCalls, m.pendingToolCalls)
		m.pendingToolCalls = m.pendingToolCalls[:0]
	}
	m.items = append(m.items, item)
	m.refresh()
}

// TrackToolStart records the start of a tool invocation during processing.
func (m *Model) TrackToolStart(name, args string) {
	m.pendingToolCalls = append(m.pendingToolCalls, ToolCallDisplay{
		Name: name,
		Args: args,
	})
}

// TrackToolResult attaches the result to the most recent matching tool call.
func (m *Model) TrackToolResult(name, result string, success bool) {
	for i := len(m.pendingToolCalls) - 1; i >= 0; i-- {
		if m.pendingToolCalls[i].Name == name && !m.pendingToolCalls[i].Done {
			m.pendingToolCalls[i].Result = result
			m.pendingToolCalls[i].Success = success
			return
		}
	}
	// Tool result arrived with no matching start — still track it.
	m.pendingToolCalls = append(m.pendingToolCalls, ToolCallDisplay{
		Name:    name,
		Result:  result,
		Done:    true,
		Success: success,
	})
}

// TrackToolEnd marks a tool call as completed with its duration.
func (m *Model) TrackToolEnd(name string, durationMs int64, success bool) {
	for i := len(m.pendingToolCalls) - 1; i >= 0; i-- {
		if m.pendingToolCalls[i].Name == name && !m.pendingToolCalls[i].Done {
			m.pendingToolCalls[i].Done = true
			m.pendingToolCalls[i].DurationMs = durationMs
			m.pendingToolCalls[i].Success = success
			return
		}
	}
}

// ClearPendingToolCalls resets the tool accumulator (e.g. on cancel).
func (m *Model) ClearPendingToolCalls() {
	m.pendingToolCalls = m.pendingToolCalls[:0]
}

// AddSystemMessage appends an info-level system message.
func (m *Model) AddSystemMessage(text string) {
	m.items = append(m.items, newSystemItem(m.genID(), text, LevelInfo))
	m.refresh()
}

// AddSystemWarning appends a warning-level system message.
func (m *Model) AddSystemWarning(text string) {
	m.items = append(m.items, newSystemItem(m.genID(), text, LevelWarning))
	m.refresh()
}

// AddSystemError appends an error-level system message.
func (m *Model) AddSystemError(text string) {
	m.items = append(m.items, newSystemItem(m.genID(), text, LevelError))
	m.refresh()
}

// SetWelcomeData populates the welcome screen fields shown before any messages.
func (m *Model) SetWelcomeData(version, detail, cwd string) {
	m.welcomeVersion = version
	m.welcomeDetail = detail
	m.welcomeCwd = cwd
	if len(m.items) == 0 {
		m.refresh()
	}
}

// SetProcessingView sets the inline processing indicator shown below messages.
func (m *Model) SetProcessingView(view string) {
	m.processingView = view
	m.refresh()
}

// ClearProcessingView removes the inline processing indicator and streaming content.
func (m *Model) ClearProcessingView() {
	m.processingView = ""
	m.streamingContent = ""
	m.refresh()
}

// SetStreamingContent updates the partial agent response shown during streaming.
func (m *Model) SetStreamingContent(text string) {
	m.streamingContent = text
	m.refresh()
}

// SetThinkingContent updates the extended-thinking text in the ThinkingBox.
func (m *Model) SetThinkingContent(text string) {
	m.thinkingBox.SetContent(text)
	m.refresh()
}

// ToggleThinkingExpanded flips the ThinkingBox between collapsed (10 lines) and full.
func (m *Model) ToggleThinkingExpanded() {
	m.thinkingBox.Toggle()
	m.refresh()
}

// HasMessages reports whether any conversation items have been added.
func (m Model) HasMessages() bool {
	return len(m.items) > 0
}

// ScrollToTop scrolls the viewport to the very top.
func (m *Model) ScrollToTop() {
	m.vp.GotoTop()
}

// ScrollToBottom scrolls the viewport to the very bottom.
func (m *Model) ScrollToBottom() {
	_ = m.vp.GotoBottom()
}

// CopyLastMessage returns the raw text of the most recent agent message.
// Returns an empty string when there are no agent messages.
func (m Model) CopyLastMessage() string {
	for i := len(m.items) - 1; i >= 0; i-- {
		if a, ok := m.items[i].(*assistantMessageItem); ok {
			return a.content
		}
	}
	return ""
}

// ---------------------------------------------------------------------------
// Bubble Tea interface
// ---------------------------------------------------------------------------

// Update forwards keyboard and mouse events to the underlying viewport.
func (m Model) Update(msg tea.Msg) (Model, tea.Cmd) {
	var cmd tea.Cmd
	m.vp, cmd = m.vp.Update(msg)
	return m, cmd
}

// View returns the rendered viewport output.
func (m Model) View() string {
	return m.vp.View()
}

// WelcomeView returns the welcome screen rendered at the current width.
// Callers that need the welcome screen independently of the viewport can use this.
func (m Model) WelcomeView() string {
	return renderWelcome(m.width, m.welcomeVersion, m.welcomeDetail, m.welcomeCwd)
}

// ---------------------------------------------------------------------------
// Internal rendering
// ---------------------------------------------------------------------------

// genID returns a unique string ID for a new item.
func (m *Model) genID() string {
	m.nextID++
	return fmt.Sprintf("msg-%d", m.nextID)
}

// contentWidth returns the usable text width inside a left-bordered message block.
// ThickBorder(1) + PaddingLeft(1) + lipgloss outer padding(2) + margin(1) = 5
func (m *Model) contentWidth() int {
	cw := m.width - 5
	if cw < 20 {
		cw = 20
	}
	return cw
}

// refresh re-renders all content into the viewport and scrolls to bottom.
func (m *Model) refresh() {
	m.vp.SetContent(m.renderAll())
	_ = m.vp.GotoBottom()
}

// streamingCursor returns the blinking block cursor appended to streaming text.
// Uses a simple Unicode block — bubbletea will re-render each frame while streaming.
const streamingCursor = "█"

// renderAll builds the complete display string: items + thinking box + streaming overlay.
func (m *Model) renderAll() string {
	if len(m.items) == 0 {
		return renderWelcome(m.width, m.welcomeVersion, m.welcomeDetail, m.welcomeCwd)
	}

	cw := m.contentWidth()
	var sb strings.Builder

	// Track the index of the last non-skipped assistant item to apply focus border.
	lastAgentIdx := -1
	if m.focused {
		for i := len(m.items) - 1; i >= 0; i-- {
			if a, ok := m.items[i].(*assistantMessageItem); ok && !a.shouldSkip() {
				lastAgentIdx = i
				break
			}
		}
	}

	rendered := 0
	for i, item := range m.items {
		// Skip assistant messages that have no content and no tool calls.
		if a, ok := item.(*assistantMessageItem); ok && a.shouldSkip() {
			continue
		}

		if rendered > 0 {
			// One blank line between messages for readability.
			sb.WriteString("\n\n")
		}

		if m.focused && i == lastAgentIdx {
			if a, ok := item.(*assistantMessageItem); ok {
				sb.WriteString(renderFocusedAssistant(a, cw))
			} else {
				sb.WriteString(item.Render(cw))
			}
		} else {
			sb.WriteString(item.Render(cw))
		}
		rendered++
	}

	// ThinkingBox — shown during streaming when extended-thinking content exists.
	if m.thinkingBox.HasContent() {
		if rendered > 0 {
			sb.WriteString("\n\n")
		}
		sb.WriteString(m.thinkingBox.Render(cw))
		rendered++
	}

	// Streaming partial response takes priority over processingView.
	if m.streamingContent != "" {
		label := style.AgentLabel.Render("◈ OSA")
		border := lipgloss.NewStyle().
			Border(lipgloss.ThickBorder(), false, false, false, true).
			BorderForeground(style.MsgBorderAgent).
			PaddingLeft(1).
			Width(cappedWidth(cw))
		if rendered > 0 {
			sb.WriteString("\n\n")
		}
		// Append cursor to indicate active streaming.
		cursorStyle := lipgloss.NewStyle().Foreground(style.Primary)
		sb.WriteString(border.Render(label + "\n" + m.streamingContent + cursorStyle.Render(streamingCursor)))
	} else if m.processingView != "" {
		if rendered > 0 {
			sb.WriteString("\n\n")
		}
		sb.WriteString(m.processingView)
	}

	return sb.String()
}

// renderFocusedAssistant renders an assistantMessageItem with a brighter border
// to indicate it is the focused (active) message.
func renderFocusedAssistant(a *assistantMessageItem, cw int) string {
	cw = cappedWidth(cw)

	// Label + optional signal badge
	label := style.AgentLabel.Render("◈ OSA")
	if a.signal != nil && a.signal.Mode != "" && a.signal.Genre != "" {
		badge := style.StatusSignal.Render(
			fmt.Sprintf(" [%s/%s]", a.signal.Mode, a.signal.Genre),
		)
		label += badge
	}

	body := renderMarkdown(a.content, cw-2)

	var toolSection string
	if len(a.toolCalls) > 0 {
		var tb strings.Builder
		for _, tc := range a.toolCalls {
			tb.WriteString("\n")
			status := toolCallStatus(tc)
			tb.WriteString(tools.RenderToolCall(
				tc.Name, tc.Args, tc.Result,
				tools.RenderOpts{
					Status:     tools.ToolStatus(status),
					Width:      cw - 2,
					Expanded:   false,
					DurationMs: tc.DurationMs,
				},
			))
		}
		toolSection = tb.String()
	}

	var meta string
	if a.modelName != "" || a.durationMs > 0 {
		var parts []string
		if a.modelName != "" {
			parts = append(parts, a.modelName)
		}
		if a.durationMs > 0 {
			parts = append(parts, formatDuration(a.durationMs))
		}
		if a.inputTokens > 0 || a.outputTokens > 0 {
			parts = append(parts, fmt.Sprintf("↓%s ↑%s",
				formatTokens(a.inputTokens),
				formatTokens(a.outputTokens),
			))
		}
		meta = "\n" + style.MsgMeta.Render("— "+strings.Join(parts, " · "))
	}

	// Use Primary (brighter) color for the border when focused.
	border := lipgloss.NewStyle().
		Border(lipgloss.ThickBorder(), false, false, false, true).
		BorderForeground(style.Primary).
		PaddingLeft(1).
		Width(cw)
	return border.Render(label + "\n" + body + toolSection + meta)
}

// ---------------------------------------------------------------------------
// Markdown rendering
// ---------------------------------------------------------------------------

// renderMarkdown renders markdown text using glamour, falling back to plain text on error.
func renderMarkdown(md string, width int) string {
	if strings.TrimSpace(md) == "" {
		return md
	}
	r, err := glamour.NewTermRenderer(
		glamour.WithAutoStyle(),
		glamour.WithWordWrap(width),
	)
	if err != nil {
		return md
	}
	out, err := r.Render(md)
	if err != nil {
		return md
	}
	return strings.TrimRight(out, "\n")
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// formatDuration converts milliseconds to a human-readable string.
func formatDuration(ms int64) string {
	if ms < 1000 {
		return fmt.Sprintf("%dms", ms)
	}
	return fmt.Sprintf("%.1fs", float64(ms)/1000.0)
}

// formatTokens converts a token count to a compact human-readable string.
// e.g. 1234 → "1.2k", 800 → "800".
func formatTokens(n int64) string {
	if n == 0 {
		return "0"
	}
	if n >= 1000 {
		return fmt.Sprintf("%.1fk", float64(n)/1000.0)
	}
	return fmt.Sprintf("%d", n)
}
