// Package msg defines all tea.Msg types dispatched within the OSA TUI.
// It has no upstream imports (client, model) to avoid import cycles.
package msg

// -- Signal (mirrors client.Signal) --

// Signal carries signal classification metadata.
// It mirrors client.Signal so this package remains import-cycle-free.
type Signal struct {
	Mode      string  `json:"mode"`
	Genre     string  `json:"genre"`
	Type      string  `json:"type"`
	Format    string  `json:"format"`
	Weight    float64 `json:"weight"`
	Channel   string  `json:"channel"`
	Timestamp string  `json:"timestamp"`
}

// -- Lifecycle --

// HealthResult from the initial health check.
type HealthResult struct {
	Status        string
	Version       string
	UptimeSeconds int64
	Provider      string
	Err           error
}

// -- User input --

// SubmitInput when the user presses Enter.
type SubmitInput struct {
	Text string
}

// -- HTTP responses --

// OrchestrateResult from POST /orchestrate.
type OrchestrateResult struct {
	SessionID      string
	Output         string
	Signal         *Signal
	ToolsUsed      []string
	IterationCount int
	ExecutionMs    int64
	Err            error
}

// ComplexResult from POST /orchestrate/complex.
type ComplexResult struct {
	TaskID    string
	Status    string
	SessionID string
	Synthesis string
	Err       error
}

// CommandResult from POST /commands/execute.
type CommandResult struct {
	Kind   string
	Output string
	Action string
	Err    error
}

// ClassifyResult from POST /classify.
type ClassifyResult struct {
	Signal Signal
	Err    error
}

// -- SSE events --

// SSEAuthFailed when SSE gets 401/403.
type SSEAuthFailed struct{}

// LoginResult from /login command.
type LoginResult struct {
	Token     string
	ExpiresIn int
	Err       error
}

// LogoutResult from /logout command.
type LogoutResult struct {
	Err error
}

// SSEConnected when the SSE stream is established.
type SSEConnected struct {
	SessionID string
}

// SSEDisconnected when the SSE stream drops.
type SSEDisconnected struct {
	Err error
}

// SSEReconnecting when attempting reconnection.
type SSEReconnecting struct {
	Attempt int
}

// AgentResponse from SSE event "agent_response".
type AgentResponse struct {
	Response string  `json:"response"`
	Signal   *Signal `json:"signal,omitempty"`
}

// ToolCallStart from SSE event "tool_call".
type ToolCallStart struct {
	Name string `json:"name"`
	Args string `json:"args"`
}

// ToolCallEnd from SSE "tool_call" event with phase:"end".
type ToolCallEnd struct {
	Name       string `json:"name"`
	DurationMs int64  `json:"duration_ms"`
	Success    bool   `json:"success"`
}

// LLMRequest from SSE event "llm_request".
type LLMRequest struct {
	Iteration int `json:"iteration"`
}

// LLMResponse from SSE event "llm_response".
type LLMResponse struct {
	DurationMs   int64 `json:"duration_ms"`
	InputTokens  int   `json:"input_tokens"`
	OutputTokens int   `json:"output_tokens"`
}

// -- Orchestrator events --

// OrchestratorTaskStarted from system_event.
type OrchestratorTaskStarted struct {
	TaskID string `json:"task_id"`
}

// OrchestratorAgentStarted from system_event.
type OrchestratorAgentStarted struct {
	AgentName string `json:"agent_name"`
	Role      string `json:"role"`
	Model     string `json:"model"`
}

// OrchestratorAgentProgress from system_event.
type OrchestratorAgentProgress struct {
	AgentName     string `json:"agent_name"`
	CurrentAction string `json:"current_action"`
	ToolUses      int    `json:"tool_uses"`
	TokensUsed    int    `json:"tokens_used"`
}

// OrchestratorAgentCompleted from system_event.
type OrchestratorAgentCompleted struct {
	AgentName  string `json:"agent_name"`
	ToolUses   int    `json:"tool_uses"`
	TokensUsed int    `json:"tokens_used"`
}

// OrchestratorWaveStarted from system_event.
type OrchestratorWaveStarted struct {
	WaveNumber int `json:"wave_number"`
	TotalWaves int `json:"total_waves"`
}

// OrchestratorTaskCompleted from system_event.
type OrchestratorTaskCompleted struct {
	TaskID string `json:"task_id"`
}

// -- Context pressure --

// ContextPressure from system_event.
type ContextPressure struct {
	Utilization     float64 `json:"utilization"`
	EstimatedTokens int     `json:"estimated_tokens"`
	MaxTokens       int     `json:"max_tokens"`
}

// -- UI events --

// TickMsg for periodic timer updates.
type TickMsg struct{}

// WindowSizeMsg from terminal resize.
type WindowSizeMsg struct {
	Width  int
	Height int
}

// ToggleExpand for Ctrl+O.
type ToggleExpand struct{}

// ToggleBackground for Ctrl+B.
type ToggleBackground struct{}
