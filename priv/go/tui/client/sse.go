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

// StreamingTokenEvent carries a partial token during streaming responses.
// The TUI accumulates these to show a live response as it's generated.
// Emitted by Agent.Loop via Bus.emit(:system_event, %{event: :streaming_token, ...}).
type StreamingTokenEvent struct {
	Text      string `json:"text"`
	SessionID string `json:"session_id"`
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

// OrchestratorAgentFailedEvent from system_event.
type OrchestratorAgentFailedEvent struct {
	AgentName  string `json:"agent_name"`
	Error      string `json:"error"`
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

// TaskCreatedEvent from system_event.
type TaskCreatedEvent struct {
	TaskID     string `json:"task_id"`
	Subject    string `json:"subject"`
	ActiveForm string `json:"active_form"`
}

// TaskUpdatedEvent from system_event.
type TaskUpdatedEvent struct {
	TaskID string `json:"task_id"`
	Status string `json:"status"`
}

// SwarmStartedEvent from system_event.
type SwarmStartedEvent struct {
	SwarmID     string `json:"swarm_id"`
	Pattern     string `json:"pattern"`
	AgentCount  int    `json:"agent_count"`
	TaskPreview string `json:"task_preview"`
}

// SwarmCompletedEvent from system_event.
type SwarmCompletedEvent struct {
	SwarmID       string `json:"swarm_id"`
	Pattern       string `json:"pattern"`
	AgentCount    int    `json:"agent_count"`
	ResultPreview string `json:"result_preview"`
}

// SwarmFailedEvent from system_event.
type SwarmFailedEvent struct {
	SwarmID string `json:"swarm_id"`
	Reason  string `json:"reason"`
}

// HookBlockedEvent is emitted when a hook blocks an action (e.g. security_check).
type HookBlockedEvent struct {
	HookName string `json:"hook_name"`
	Reason   string `json:"reason"`
}

// BudgetWarningEvent is emitted when spend crosses 80% of daily or monthly limit.
type BudgetWarningEvent struct {
	Utilization float64 `json:"utilization"`
	Message     string  `json:"message"`
}

// BudgetExceededEvent is emitted when a budget limit is hit.
type BudgetExceededEvent struct {
	Message string `json:"message"`
}

// SwarmCancelledEvent is emitted when a swarm is cancelled.
type SwarmCancelledEvent struct {
	SwarmID string `json:"swarm_id"`
}

// SwarmTimeoutEvent is emitted when a swarm times out.
type SwarmTimeoutEvent struct {
	SwarmID string `json:"swarm_id"`
}

// ThinkingDeltaEvent carries a partial thinking/reasoning token from the LLM.
type ThinkingDeltaEvent struct {
	Text string `json:"text"`
}

// SwarmIntelligenceStartedEvent from system_event.
type SwarmIntelligenceStartedEvent struct {
	SwarmID string `json:"swarm_id"`
	Type    string `json:"type"`
	Task    string `json:"task"`
}

// SwarmIntelligenceRoundEvent from system_event.
type SwarmIntelligenceRoundEvent struct {
	SwarmID string `json:"swarm_id"`
	Round   int    `json:"round"`
}

// SwarmIntelligenceConvergedEvent from system_event.
type SwarmIntelligenceConvergedEvent struct {
	SwarmID string `json:"swarm_id"`
	Round   int    `json:"round"`
}

// SwarmIntelligenceCompletedEvent from system_event.
type SwarmIntelligenceCompletedEvent struct {
	SwarmID   string `json:"swarm_id"`
	Converged bool   `json:"converged"`
	Rounds    int    `json:"rounds"`
}

// ToolResultEvent is emitted when a tool invocation returns its result.
type ToolResultEvent struct {
	Name    string `json:"name"`
	Result  string `json:"result"`
	Success bool   `json:"success"`
}

// SignalClassifiedEvent is emitted when the backend classifies the response signal.
type SignalClassifiedEvent struct {
	Mode   string  `json:"mode"`
	Genre  string  `json:"genre"`
	Type   string  `json:"type"`
	Weight float64 `json:"weight"`
}

// SSEParseWarning is emitted when an SSE event cannot be parsed.
// The TUI surfaces it as a toast instead of writing to stderr.
type SSEParseWarning struct {
	Message string
}

// -- SSEClient ----------------------------------------------------------------

// SSEClient manages the Server-Sent Events connection.
type SSEClient struct {
	baseURL   string
	token     string
	sessionID string
	done      chan struct{}
	httpCli   *http.Client
}

// NewSSE creates an SSE client for the given session.
func NewSSE(baseURL, token, sessionID string) *SSEClient {
	return &SSEClient{
		baseURL:   baseURL,
		token:     token,
		sessionID: sessionID,
		done:      make(chan struct{}),
		httpCli:   &http.Client{Timeout: 0},
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

		c := s.httpCli
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

// MaxReconnects is the maximum number of reconnect attempts before giving up.
const MaxReconnects = 10

// ReconnectListenCmd is a tea.Cmd that reconnects the SSE stream with backoff.
// Used by the disconnect handler when an unintentional disconnect occurs.
// After MaxReconnects failed attempts it returns an error instead of looping forever.
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

			if attempt >= MaxReconnects {
				return SSEDisconnectedEvent{
					Err: fmt.Errorf("SSE reconnect failed after %d attempts", MaxReconnects),
				}
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
			if _, ok := result.(SSEDisconnectedEvent); ok || result == nil {
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
		if err := json.Unmarshal(data, &ev); err != nil {
			return SSEParseWarning{Message: fmt.Sprintf("[sse] parse %s: %v", eventType, err)}
		}
		return SSEConnectedEvent{SessionID: ev.SessionID}

	case "agent_response":
		var ev AgentResponseEvent
		if err := json.Unmarshal(data, &ev); err != nil {
			return SSEParseWarning{Message: fmt.Sprintf("[sse] parse %s: %v", eventType, err)}
		}
		return ev

	case "tool_call":
		// Elixir sends a single "tool_call" event with a "phase" field
		// distinguishing start vs end.
		var raw struct {
			Name       string `json:"name"`
			Phase      string `json:"phase"`
			Args       string `json:"args"`
			DurationMs int64  `json:"duration_ms"`
			Success    *bool  `json:"success,omitempty"`
		}
		if err := json.Unmarshal(data, &raw); err != nil {
			return SSEParseWarning{Message: fmt.Sprintf("[sse] parse %s: %v", eventType, err)}
		}
		switch raw.Phase {
		case "end":
			success := true // default if omitted for backward compat
			if raw.Success != nil {
				success = *raw.Success
			}
			return ToolCallEndEvent{
				Name:       raw.Name,
				DurationMs: raw.DurationMs,
				Success:    success,
			}
		default: // "start" or missing
			return ToolCallStartEvent{Name: raw.Name, Args: raw.Args}
		}

	case "llm_request":
		var ev LLMRequestEvent
		if err := json.Unmarshal(data, &ev); err != nil {
			return SSEParseWarning{Message: fmt.Sprintf("[sse] parse %s: %v", eventType, err)}
		}
		return ev

	case "llm_response":
		var raw struct {
			DurationMs int64 `json:"duration_ms"`
			Usage      struct {
				InputTokens  int `json:"input_tokens"`
				OutputTokens int `json:"output_tokens"`
			} `json:"usage"`
		}
		if err := json.Unmarshal(data, &raw); err != nil {
			return SSEParseWarning{Message: fmt.Sprintf("[sse] parse %s: %v", eventType, err)}
		}
		return LLMResponseEvent{
			DurationMs:   raw.DurationMs,
			InputTokens:  raw.Usage.InputTokens,
			OutputTokens: raw.Usage.OutputTokens,
		}

	case "streaming_token":
		var ev StreamingTokenEvent
		if err := json.Unmarshal(data, &ev); err != nil {
			return SSEParseWarning{Message: fmt.Sprintf("[sse] parse %s: %v", eventType, err)}
		}
		return ev

	case "tool_result":
		var ev ToolResultEvent
		if err := json.Unmarshal(data, &ev); err != nil {
			return SSEParseWarning{Message: fmt.Sprintf("[sse] parse %s: %v", eventType, err)}
		}
		return ev

	case "signal_classified":
		var ev SignalClassifiedEvent
		if err := json.Unmarshal(data, &ev); err != nil {
			return SSEParseWarning{Message: fmt.Sprintf("[sse] parse %s: %v", eventType, err)}
		}
		return ev

	case "system_event":
		return parseSystemEvent(data)

	default:
		if eventType != "" {
			return SSEParseWarning{Message: fmt.Sprintf("[sse] unknown event type: %s", eventType)}
		}
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

	case "orchestrator_agent_failed":
		var ev OrchestratorAgentFailedEvent
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

	case "streaming_token":
		var ev StreamingTokenEvent
		if json.Unmarshal(data, &ev) == nil {
			return ev
		}

	case "context_pressure":
		var ev ContextPressureEvent
		if json.Unmarshal(data, &ev) == nil {
			return ev
		}

	case "task_created":
		var ev TaskCreatedEvent
		if json.Unmarshal(data, &ev) == nil {
			return ev
		}

	case "task_updated":
		var ev TaskUpdatedEvent
		if json.Unmarshal(data, &ev) == nil {
			return ev
		}

	case "swarm_started":
		var ev SwarmStartedEvent
		if err := json.Unmarshal(data, &ev); err != nil {
			return SSEParseWarning{Message: fmt.Sprintf("[sse] parse %s: %v", base.Event, err)}
		}
		return ev

	case "swarm_completed":
		var ev SwarmCompletedEvent
		if err := json.Unmarshal(data, &ev); err != nil {
			return SSEParseWarning{Message: fmt.Sprintf("[sse] parse %s: %v", base.Event, err)}
		}
		return ev

	case "swarm_failed":
		var ev SwarmFailedEvent
		if err := json.Unmarshal(data, &ev); err != nil {
			return SSEParseWarning{Message: fmt.Sprintf("[sse] parse %s: %v", base.Event, err)}
		}
		return ev

	case "swarm_cancelled":
		var ev SwarmCancelledEvent
		if err := json.Unmarshal(data, &ev); err != nil {
			return SSEParseWarning{Message: fmt.Sprintf("[sse] parse %s: %v", base.Event, err)}
		}
		return ev

	case "swarm_timeout":
		var ev SwarmTimeoutEvent
		if err := json.Unmarshal(data, &ev); err != nil {
			return SSEParseWarning{Message: fmt.Sprintf("[sse] parse %s: %v", base.Event, err)}
		}
		return ev

	case "hook_blocked":
		var ev struct {
			HookName string `json:"hook_name"`
			Reason   string `json:"reason"`
		}
		if err := json.Unmarshal(data, &ev); err != nil {
			return SSEParseWarning{Message: fmt.Sprintf("[sse] parse %s: %v", base.Event, err)}
		}
		return HookBlockedEvent{HookName: ev.HookName, Reason: ev.Reason}

	case "budget_warning":
		var ev struct {
			Utilization float64 `json:"utilization"`
			Message     string  `json:"message"`
		}
		if err := json.Unmarshal(data, &ev); err != nil {
			return SSEParseWarning{Message: fmt.Sprintf("[sse] parse %s: %v", base.Event, err)}
		}
		return BudgetWarningEvent{Utilization: ev.Utilization, Message: ev.Message}

	case "budget_exceeded":
		var ev struct {
			Message string `json:"message"`
		}
		if err := json.Unmarshal(data, &ev); err != nil {
			return SSEParseWarning{Message: fmt.Sprintf("[sse] parse %s: %v", base.Event, err)}
		}
		return BudgetExceededEvent{Message: ev.Message}

	case "thinking_delta":
		var ev ThinkingDeltaEvent
		if err := json.Unmarshal(data, &ev); err != nil {
			return SSEParseWarning{Message: fmt.Sprintf("[sse] parse %s: %v", base.Event, err)}
		}
		return ev

	case "swarm_intelligence_started":
		var ev SwarmIntelligenceStartedEvent
		if err := json.Unmarshal(data, &ev); err != nil {
			return SSEParseWarning{Message: fmt.Sprintf("[sse] parse %s: %v", base.Event, err)}
		}
		return ev

	case "swarm_intelligence_round":
		var ev SwarmIntelligenceRoundEvent
		if err := json.Unmarshal(data, &ev); err != nil {
			return SSEParseWarning{Message: fmt.Sprintf("[sse] parse %s: %v", base.Event, err)}
		}
		return ev

	case "swarm_intelligence_converged":
		var ev SwarmIntelligenceConvergedEvent
		if err := json.Unmarshal(data, &ev); err != nil {
			return SSEParseWarning{Message: fmt.Sprintf("[sse] parse %s: %v", base.Event, err)}
		}
		return ev

	case "swarm_intelligence_completed":
		var ev SwarmIntelligenceCompletedEvent
		if err := json.Unmarshal(data, &ev); err != nil {
			return SSEParseWarning{Message: fmt.Sprintf("[sse] parse %s: %v", base.Event, err)}
		}
		return ev

	default:
		if base.Event != "" {
			return SSEParseWarning{Message: fmt.Sprintf("[sse] unknown system_event: %s", base.Event)}
		}
	}
	return nil
}
