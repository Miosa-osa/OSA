package client

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// -- Raw SSE event types (client-internal; callers convert to msg.*) ----------

// SSEAuthFailedEvent is dispatched when the SSE stream gets a 401/403.
type SSEAuthFailedEvent struct{}

// SSEConnectedEvent is dispatched when the SSE stream is established.
type SSEConnectedEvent struct {
	SessionID string
}

// SSEDisconnectedEvent is dispatched when the SSE stream drops or closes.
type SSEDisconnectedEvent struct {
	Err error
}

// SSEReconnectingEvent is dispatched before each reconnect attempt.
type SSEReconnectingEvent struct {
	Attempt int
}

// AgentResponseEvent carries agent text output and optional signal metadata.
type AgentResponseEvent struct {
	Response string  `json:"response"`
	Signal   *Signal `json:"signal,omitempty"`
}

// ToolCallStartEvent is dispatched when a tool invocation begins.
type ToolCallStartEvent struct {
	Name string `json:"name"`
	Args string `json:"args"`
}

// ToolCallEndEvent is dispatched when a tool invocation completes.
type ToolCallEndEvent struct {
	Name       string `json:"name"`
	DurationMs int64  `json:"duration_ms"`
	Success    bool   `json:"success"`
}

// LLMRequestEvent signals the start of an LLM call.
type LLMRequestEvent struct {
	Iteration int `json:"iteration"`
}

// LLMResponseEvent carries token usage and timing from the LLM.
type LLMResponseEvent struct {
	DurationMs   int64
	InputTokens  int
	OutputTokens int
}

// OrchestratorTaskStartedEvent from system_event.
type OrchestratorTaskStartedEvent struct {
	TaskID string `json:"task_id"`
}

// OrchestratorAgentStartedEvent from system_event.
type OrchestratorAgentStartedEvent struct {
	AgentName string `json:"agent_name"`
	Role      string `json:"role"`
	Model     string `json:"model"`
}

// OrchestratorAgentProgressEvent from system_event.
type OrchestratorAgentProgressEvent struct {
	AgentName     string `json:"agent_name"`
	CurrentAction string `json:"current_action"`
	ToolUses      int    `json:"tool_uses"`
	TokensUsed    int    `json:"tokens_used"`
}

// OrchestratorAgentCompletedEvent from system_event.
type OrchestratorAgentCompletedEvent struct {
	AgentName  string `json:"agent_name"`
	ToolUses   int    `json:"tool_uses"`
	TokensUsed int    `json:"tokens_used"`
}

// OrchestratorWaveStartedEvent from system_event.
type OrchestratorWaveStartedEvent struct {
	WaveNumber int `json:"wave_number"`
	TotalWaves int `json:"total_waves"`
}

// OrchestratorTaskCompletedEvent from system_event.
type OrchestratorTaskCompletedEvent struct {
	TaskID string `json:"task_id"`
}

// ContextPressureEvent from system_event.
type ContextPressureEvent struct {
	Utilization     float64 `json:"utilization"`
	EstimatedTokens int     `json:"estimated_tokens"`
	MaxTokens       int     `json:"max_tokens"`
}

// -- SSEClient ----------------------------------------------------------------

// SSEClient manages the Server-Sent Events connection.
type SSEClient struct {
	baseURL   string
	token     string
	sessionID string
	done      chan struct{}
}

// NewSSE creates an SSE client for the given session.
func NewSSE(baseURL, token, sessionID string) *SSEClient {
	return &SSEClient{
		baseURL:   baseURL,
		token:     token,
		sessionID: sessionID,
		done:      make(chan struct{}),
	}
}

// Close signals the SSE client to stop.
func (s *SSEClient) Close() {
	select {
	case <-s.done:
	default:
		close(s.done)
	}
}

// IsClosed reports whether the SSE client has been intentionally closed.
func (s *SSEClient) IsClosed() bool {
	select {
	case <-s.done:
		return true
	default:
		return false
	}
}

// ListenCmd returns a tea.Cmd that reads SSE events and sends them as messages.
func (s *SSEClient) ListenCmd(p *tea.Program) tea.Cmd {
	return func() tea.Msg {
		url := fmt.Sprintf("%s/api/v1/stream/%s", s.baseURL, s.sessionID)
		req, err := http.NewRequest("GET", url, nil)
		if err != nil {
			return SSEDisconnectedEvent{Err: err}
		}
		req.Header.Set("Accept", "text/event-stream")
		req.Header.Set("Cache-Control", "no-cache")
		if s.token != "" {
			req.Header.Set("Authorization", "Bearer "+s.token)
		}

		c := &http.Client{Timeout: 0} // no timeout for SSE
		resp, err := c.Do(req)
		if err != nil {
			return SSEDisconnectedEvent{Err: err}
		}
		defer resp.Body.Close()

		if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
			return SSEAuthFailedEvent{}
		}
		if resp.StatusCode != http.StatusOK {
			return SSEDisconnectedEvent{
				Err: fmt.Errorf("SSE stream returned %d", resp.StatusCode),
			}
		}

		// Signal connected.
		p.Send(SSEConnectedEvent{SessionID: s.sessionID})

		scanner := bufio.NewScanner(resp.Body)
		scanner.Buffer(make([]byte, 0), 1024*1024) // 1 MB

		var eventType string

		for scanner.Scan() {
			select {
			case <-s.done:
				return SSEDisconnectedEvent{Err: nil}
			default:
			}

			line := scanner.Text()

			switch {
			case line == "":
				eventType = ""

			case strings.HasPrefix(line, ":"):
				// keepalive comment — ignore

			case strings.HasPrefix(line, "event: "):
				eventType = strings.TrimPrefix(line, "event: ")

			case strings.HasPrefix(line, "data: "):
				data := strings.TrimPrefix(line, "data: ")
				if m := parseSSEEvent(eventType, []byte(data)); m != nil {
					p.Send(m)
				}
			}
		}

		if err := scanner.Err(); err != nil {
			return SSEDisconnectedEvent{Err: err}
		}
		return SSEDisconnectedEvent{Err: nil}
	}
}

// ReconnectListenCmd is a tea.Cmd that reconnects the SSE stream with backoff.
// Used by the disconnect handler when an unintentional disconnect occurs.
func (s *SSEClient) ReconnectListenCmd(p *tea.Program) tea.Cmd {
	return func() tea.Msg {
		attempt := 0
		maxBackoff := 30 * time.Second

		for {
			select {
			case <-s.done:
				return SSEDisconnectedEvent{Err: nil}
			default:
			}

			attempt++
			shift := attempt
			if shift > 5 {
				shift = 5 // cap at 32s to prevent int64 overflow
			}
			backoff := time.Duration(1<<uint(shift)) * time.Second
			if backoff > maxBackoff {
				backoff = maxBackoff
			}

			select {
			case <-time.After(backoff):
			case <-s.done:
				return SSEDisconnectedEvent{Err: nil}
			}

			// Attempt reconnect by running ListenCmd inline.
			p.Send(SSEReconnectingEvent{Attempt: attempt})
			result := s.ListenCmd(p)()
			if result == nil {
				continue
			}
			// If ListenCmd returned a disconnect, loop and retry.
			if _, ok := result.(SSEDisconnectedEvent); ok {
				continue
			}
			return result
		}
	}
}

// parseSSEEvent converts an SSE event type + JSON data into a tea.Msg.
func parseSSEEvent(eventType string, data []byte) tea.Msg {
	switch eventType {
	case "connected":
		var ev struct {
			SessionID string `json:"session_id"`
		}
		if json.Unmarshal(data, &ev) == nil {
			return SSEConnectedEvent{SessionID: ev.SessionID}
		}

	case "agent_response":
		var ev AgentResponseEvent
		if json.Unmarshal(data, &ev) == nil {
			return ev
		}

	case "tool_call":
		// Elixir sends a single "tool_call" event with a "phase" field
		// distinguishing start vs end.
		var raw struct {
			Name       string `json:"name"`
			Phase      string `json:"phase"`
			Args       string `json:"args"`
			DurationMs int64  `json:"duration_ms"`
		}
		if json.Unmarshal(data, &raw) == nil {
			switch raw.Phase {
			case "end":
				return ToolCallEndEvent{
					Name:       raw.Name,
					DurationMs: raw.DurationMs,
					Success:    true, // Elixir omits success; default true
				}
			default: // "start" or missing
				return ToolCallStartEvent{Name: raw.Name, Args: raw.Args}
			}
		}

	case "llm_request":
		var ev LLMRequestEvent
		if json.Unmarshal(data, &ev) == nil {
			return ev
		}

	case "llm_response":
		var raw struct {
			DurationMs int64 `json:"duration_ms"`
			Usage      struct {
				InputTokens  int `json:"input_tokens"`
				OutputTokens int `json:"output_tokens"`
			} `json:"usage"`
		}
		if json.Unmarshal(data, &raw) == nil {
			return LLMResponseEvent{
				DurationMs:   raw.DurationMs,
				InputTokens:  raw.Usage.InputTokens,
				OutputTokens: raw.Usage.OutputTokens,
			}
		}

	case "system_event":
		return parseSystemEvent(data)
	}
	return nil
}

// parseSystemEvent dispatches system_event subtypes.
func parseSystemEvent(data []byte) tea.Msg {
	var base struct {
		Event string `json:"event"`
	}
	if json.Unmarshal(data, &base) != nil {
		return nil
	}

	switch base.Event {
	case "orchestrator_task_started":
		var ev OrchestratorTaskStartedEvent
		if json.Unmarshal(data, &ev) == nil {
			return ev
		}

	case "orchestrator_agent_started":
		var ev OrchestratorAgentStartedEvent
		if json.Unmarshal(data, &ev) == nil {
			return ev
		}

	case "orchestrator_agent_progress":
		var ev OrchestratorAgentProgressEvent
		if json.Unmarshal(data, &ev) == nil {
			return ev
		}

	case "orchestrator_agent_completed":
		var ev OrchestratorAgentCompletedEvent
		if json.Unmarshal(data, &ev) == nil {
			return ev
		}

	case "orchestrator_wave_started":
		var ev OrchestratorWaveStartedEvent
		if json.Unmarshal(data, &ev) == nil {
			return ev
		}

	case "orchestrator_task_completed":
		var ev OrchestratorTaskCompletedEvent
		if json.Unmarshal(data, &ev) == nil {
			return ev
		}

	case "context_pressure":
		var ev ContextPressureEvent
		if json.Unmarshal(data, &ev) == nil {
			return ev
		}
	}
	return nil
}
