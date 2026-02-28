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
	Model         string
	Err           error
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

// CommandResult from POST /commands/execute.
type CommandResult struct {
	Kind   string
	Output string
	Action string
	Err    error
}

// LoginResult from /login command.
type LoginResult struct {
	Token        string
	RefreshToken string
	ExpiresIn    int
	Err          error
}

// LogoutResult from /logout command.
type LogoutResult struct {
	Err error
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

// OrchestratorAgentFailed from system_event.
type OrchestratorAgentFailed struct {
	AgentName  string `json:"agent_name"`
	Error      string `json:"error"`
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

// -- Thinking events --

// ThinkingDelta carries a partial thinking/reasoning token from the LLM.
type ThinkingDelta struct {
	Text string
}

// -- UI events --

// TickMsg for periodic timer updates.
type TickMsg struct{}

// ToggleExpand for Ctrl+O.
type ToggleExpand struct{}

// -- Session events --

// SessionInfo describes a session (mirrors client.SessionInfo without JSON tags).
type SessionInfo struct {
	ID           string
	CreatedAt    string
	Title        string
	MessageCount int
}

// SessionListResult from listing sessions.
type SessionListResult struct {
	Sessions []SessionInfo
	Err      error
}

// SessionMessage mirrors client.SessionMessage without the import cycle.
type SessionMessage struct {
	Role      string
	Content   string
	Timestamp string
}

// SessionSwitchResult from switching or creating sessions.
type SessionSwitchResult struct {
	SessionID string
	Messages  []SessionMessage
	Err       error
}

// ToolResult from SSE event "tool_result".
type ToolResult struct {
	Name    string `json:"name"`
	Result  string `json:"result"`
	Success bool   `json:"success"`
}

// SSEParseWarning carries a non-fatal SSE parse error to surface as a toast.
type SSEParseWarning struct {
	Message string
}

// -- Model selection --

// ModelEntry describes a single available model (mirrors client.ModelEntry).
type ModelEntry struct {
	Name     string
	Provider string
	Size     int64
	Active   bool
}

// ModelListResult from GET /api/v1/models.
type ModelListResult struct {
	Models   []ModelEntry
	Current  string
	Provider string
	Err      error
}

// ModelSwitchResult from POST /api/v1/models/switch.
type ModelSwitchResult struct {
	Provider string
	Model    string
	Err      error
}
