package model

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/miosa/osa-tui/msg"
	"github.com/miosa/osa-tui/style"
)

const maxCollapsed = 3

// ToolCallInfo tracks a single tool invocation.
type ToolCallInfo struct {
	Name       string
	Args       string
	DurationMs int64
	Done       bool
	Success    bool
}

// ActivityModel renders an elapsed timer and tool call feed.
type ActivityModel struct {
	active           bool
	startTime        time.Time
	toolCalls        []ToolCallInfo
	totalToolUses    int
	inputTokens      int
	outputTokens     int
	expanded         bool
	thinkingMs       int64     // LLM thinking/reasoning duration
	isThinking       bool      // true while receiving thinking deltas
	thinkingStart    time.Time // when thinking started (for live duration)
	iterationCount   int       // current iteration (from llm_request)
	currentPhrase    string    // current witty phrase displayed in header
	currentPhraseIdx int       // index of current phrase for avoiding repeats
	phraseRotateTime time.Time // when the current phrase was set
}

// NewActivity constructs an ActivityModel.
func NewActivity() ActivityModel {
	return ActivityModel{}
}

// Start activates the activity display and resets the elapsed timer.
func (m *ActivityModel) Start() {
	m.active = true
	m.startTime = time.Now()
	m.currentPhrase, m.currentPhraseIdx = pickPhrase(-1)
	m.phraseRotateTime = time.Now()
}

// Stop hides the activity display.
func (m *ActivityModel) Stop() {
	m.active = false
}

// Reset clears all accumulated state. Call before a new request.
func (m *ActivityModel) Reset() {
	m.active = false
	m.startTime = time.Time{}
	m.toolCalls = nil
	m.totalToolUses = 0
	m.inputTokens = 0
	m.outputTokens = 0
	m.expanded = false
	m.thinkingMs = 0
	m.isThinking = false
	m.thinkingStart = time.Time{}
	m.iterationCount = 0
	m.currentPhrase = ""
	m.currentPhraseIdx = -1
	m.phraseRotateTime = time.Time{}
}

// SetExpanded controls whether all tool calls are shown.
func (m *ActivityModel) SetExpanded(v bool) {
	m.expanded = v
}

// Summary returns a compact done-state string for embedding in chat history.
func (m *ActivityModel) Summary() string {
	elapsed := time.Since(m.startTime)
	tokens := m.inputTokens + m.outputTokens
	return fmt.Sprintf("Done (%d tools · %s tokens · %s)",
		m.totalToolUses, formatTokens(tokens), formatElapsed(elapsed))
}

// IsExpanded reports whether the tool detail view is expanded.
func (m ActivityModel) IsExpanded() bool { return m.expanded }

// ToolCount returns the total number of tool invocations so far.
func (m ActivityModel) ToolCount() int { return m.totalToolUses }

// InputTokens returns the accumulated input token count.
func (m ActivityModel) InputTokens() int { return m.inputTokens }

// OutputTokens returns the accumulated output token count.
func (m ActivityModel) OutputTokens() int { return m.outputTokens }

// Init satisfies tea.Model.
func (m ActivityModel) Init() tea.Cmd {
	return nil
}

// Update handles spinner ticks, timer ticks, and tool call events.
func (m ActivityModel) Update(teaMsg tea.Msg) (ActivityModel, tea.Cmd) {
	switch v := teaMsg.(type) {
	case msg.TickMsg:
		// Rotate witty phrase every 4 seconds.
		if m.active && time.Since(m.phraseRotateTime) >= 4*time.Second {
			m.currentPhrase, m.currentPhraseIdx = pickPhrase(m.currentPhraseIdx)
			m.phraseRotateTime = time.Now()
		}
		return m, nil

	case msg.LLMRequest:
		m.iterationCount = v.Iteration + 1
		return m, nil

	case msg.ToolCallStart:
		m.toolCalls = append(m.toolCalls, ToolCallInfo{
			Name:    v.Name,
			Args:    v.Args,
			Done:    false,
			Success: true, // default until end event
		})
		m.totalToolUses++
		return m, nil

	case msg.ToolCallEnd:
		// Mark the most recent matching tool as done.
		for i := len(m.toolCalls) - 1; i >= 0; i-- {
			if m.toolCalls[i].Name == v.Name && !m.toolCalls[i].Done {
				m.toolCalls[i].Done = true
				m.toolCalls[i].DurationMs = v.DurationMs
				m.toolCalls[i].Success = v.Success
				break
			}
		}
		return m, nil

	case msg.ToolResult:
		// Annotate the most recent matching tool call with its success state.
		// This supplements ToolCallEnd for backends that emit both events.
		for i := len(m.toolCalls) - 1; i >= 0; i-- {
			if m.toolCalls[i].Name == v.Name {
				m.toolCalls[i].Success = v.Success
				break
			}
		}
		return m, nil

	case msg.ThinkingDelta:
		if !m.isThinking {
			m.isThinking = true
			m.thinkingStart = time.Now()
		}
		return m, nil

	case msg.LLMResponse:
		m.inputTokens += v.InputTokens
		m.outputTokens += v.OutputTokens
		if m.isThinking {
			// Use live-measured thinking duration
			m.thinkingMs = time.Since(m.thinkingStart).Milliseconds()
			m.isThinking = false
		} else if v.DurationMs > 0 {
			m.thinkingMs = v.DurationMs
		}
		return m, nil

	case msg.ToggleExpand:
		m.expanded = !m.expanded
		return m, nil
	}

	return m, nil
}

// View renders the activity panel. Returns "" when inactive.
func (m ActivityModel) View() string {
	if !m.active {
		return ""
	}

	elapsed := time.Since(m.startTime)

	// Use witty phrase or fallback
	phrase := m.currentPhrase
	if phrase == "" {
		phrase = "Reasoning…"
	}

	// Header: ⏺ Filtering noise… (8s · 2 tools · ↓ 4.2k ↑ 1.1k · iter 3 · thought for 3s)
	var hdr strings.Builder
	hdr.WriteString(style.PrefixActive.Render("⏺"))
	hdr.WriteString(fmt.Sprintf(" %s (", phrase))
	hdr.WriteString(formatElapsed(elapsed))
	hdr.WriteString(" · ")
	hdr.WriteString(fmt.Sprintf("%d tools", m.totalToolUses))
	hdr.WriteString(" · ↓ ")
	hdr.WriteString(formatTokens(m.inputTokens))
	hdr.WriteString(" ↑ ")
	hdr.WriteString(formatTokens(m.outputTokens))
	if m.iterationCount > 1 {
		hdr.WriteString(fmt.Sprintf(" · iter %d", m.iterationCount))
	}
	if m.isThinking {
		thinkElapsed := time.Since(m.thinkingStart).Milliseconds()
		hdr.WriteString(fmt.Sprintf(" · thinking %s", formatMs(thinkElapsed)))
	} else if m.thinkingMs > 2000 {
		hdr.WriteString(fmt.Sprintf(" · thought for %s", formatMs(m.thinkingMs)))
	}
	hdr.WriteString(")")

	if len(m.toolCalls) == 0 {
		return hdr.String()
	}

	var sb strings.Builder
	sb.WriteString(hdr.String())

	visible := m.toolCalls
	overflow := 0
	if !m.expanded && len(m.toolCalls) > maxCollapsed {
		overflow = len(m.toolCalls) - maxCollapsed
		visible = m.toolCalls[len(m.toolCalls)-maxCollapsed:]
	}

	last := len(visible) - 1
	for i, tc := range visible {
		sb.WriteByte('\n')
		isLast := (i == last) && overflow == 0
		sb.WriteString(renderToolCall(tc, isLast))
	}

	if overflow > 0 {
		sb.WriteByte('\n')
		sb.WriteString(style.Hint.Render(
			fmt.Sprintf("     +%d more (ctrl+o to expand)", overflow),
		))
	}

	// Background hint
	sb.WriteByte('\n')
	sb.WriteString(style.Hint.Render("     ctrl+b to run in background"))

	return sb.String()
}

// renderToolCall formats a single tool call line with tree connector.
func renderToolCall(tc ToolCallInfo, isLast bool) string {
	connector := "  ├─ "
	if isLast {
		connector = "  └─ "
	}

	name := style.ToolName.Render(tc.Name)
	desc := contextualDescription(tc.Name, tc.Args)

	var suffix string
	if tc.Done {
		dur := formatToolDuration(tc.DurationMs)
		if tc.Success {
			suffix = style.ToolDuration.Render(fmt.Sprintf(" ✓ %s", dur))
		} else {
			suffix = style.ErrorText.Render(fmt.Sprintf(" ✘ %s", dur))
		}
	} else {
		suffix = style.ToolDuration.Render(" (running…)")
	}

	return connector + name + " " + desc + suffix
}

// contextualDescription returns a human-readable description for a tool call.
func contextualDescription(name, args string) string {
	extracted := extractArg(name, args)
	switch name {
	case "file_read", "Read":
		if extracted != "" {
			return style.Faint.Render("Reading " + extracted)
		}
		return style.Faint.Render("Reading file…")
	case "file_edit", "Edit":
		if extracted != "" {
			return style.Faint.Render("Editing " + extracted)
		}
		return style.Faint.Render("Editing file…")
	case "file_write", "Write":
		if extracted != "" {
			return style.Faint.Render("Writing " + extracted)
		}
		return style.Faint.Render("Writing file…")
	case "file_glob", "Glob":
		if extracted != "" {
			return style.Faint.Render("Matching " + extracted)
		}
		return style.Faint.Render("Searching for patterns…")
	case "file_grep", "Grep":
		if extracted != "" {
			return style.Faint.Render("Searching for " + extracted)
		}
		return style.Faint.Render("Searching files…")
	case "shell_execute", "bash", "Bash":
		if extracted != "" {
			return style.Faint.Render("Running " + extracted)
		}
		return style.Faint.Render("Running command…")
	case "orchestrate":
		return style.Faint.Render("Running agents…")
	case "web_search":
		if extracted != "" {
			return style.Faint.Render("Searching " + extracted)
		}
		return style.Faint.Render("Searching the web…")
	case "web_fetch":
		if extracted != "" {
			return style.Faint.Render("Fetching " + extracted)
		}
		return style.Faint.Render("Fetching URL…")
	case "memory_recall":
		if extracted != "" {
			return style.Faint.Render("Recalling " + extracted)
		}
		return style.Faint.Render("Searching memory…")
	case "memory_save":
		return style.Faint.Render("Saving to memory…")
	default:
		if extracted != "" {
			return style.ToolArg.Render("— " + extracted)
		}
		return ""
	}
}

// extractArg tries to pull the most relevant argument from raw args.
// For JSON args, it extracts key fields (path, command, query, url, pattern).
// For plain strings, it truncates to 60 chars.
func extractArg(toolName, args string) string {
	if args == "" {
		return ""
	}
	// Try JSON extraction
	if strings.HasPrefix(strings.TrimSpace(args), "{") {
		var parsed map[string]interface{}
		if json.Unmarshal([]byte(args), &parsed) == nil {
			// Try common keys in priority order based on tool
			keys := []string{"path", "file_path", "command", "query", "pattern", "url", "content"}
			for _, k := range keys {
				if v, ok := parsed[k]; ok {
					if s, ok := v.(string); ok && s != "" {
						return truncateStr(s, 60)
					}
				}
			}
		}
	}
	return truncateStr(args, 60)
}

// truncateStr shortens s to maxLen, appending "…" if truncated.
func truncateStr(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen-1] + "…"
}

// formatToolDuration renders tool duration concisely.
func formatToolDuration(ms int64) string {
	if ms < 1000 {
		return fmt.Sprintf("%dms", ms)
	}
	return fmt.Sprintf("%.1fs", float64(ms)/1000.0)
}

// formatElapsed renders a duration as a concise string.
// Examples: 3s, 1m 23s
func formatElapsed(d time.Duration) string {
	total := int(d.Seconds())
	if total < 60 {
		return fmt.Sprintf("%ds", total)
	}
	m := total / 60
	s := total % 60
	return fmt.Sprintf("%dm %ds", m, s)
}

// formatMs converts milliseconds to a concise duration string.
func formatMs(ms int64) string {
	s := ms / 1000
	if s < 1 {
		return fmt.Sprintf("%dms", ms)
	}
	return fmt.Sprintf("%ds", s)
}
