// Package msg defines all tea.Msg types dispatched within the OSA TUI.
// It has no upstream imports (client, model) to avoid import cycles.
package msg

// -- Signal (mirrors client.Signal) --

// Signal carries signal classification metadata.
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
	ResponseType   string // "plan" or "response"
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

type OrchestratorTaskStarted struct {
	TaskID string `json:"task_id"`
}

type OrchestratorAgentStarted struct {
	AgentName string `json:"agent_name"`
	Role      string `json:"role"`
	Model     string `json:"model"`
}

type OrchestratorAgentProgress struct {
	AgentName     string `json:"agent_name"`
	CurrentAction string `json:"current_action"`
	ToolUses      int    `json:"tool_uses"`
	TokensUsed    int    `json:"tokens_used"`
}

type OrchestratorAgentCompleted struct {
	AgentName  string `json:"agent_name"`
	ToolUses   int    `json:"tool_uses"`
	TokensUsed int    `json:"tokens_used"`
}

type OrchestratorAgentFailed struct {
	AgentName  string `json:"agent_name"`
	Error      string `json:"error"`
	ToolUses   int    `json:"tool_uses"`
	TokensUsed int    `json:"tokens_used"`
}

type OrchestratorWaveStarted struct {
	WaveNumber int `json:"wave_number"`
	TotalWaves int `json:"total_waves"`
}

type OrchestratorTaskCompleted struct {
	TaskID string `json:"task_id"`
}

// -- Thinking events --

type ThinkingDelta struct {
	Text string
}

// -- UI events --

type TickMsg struct{}
type ToggleExpand struct{}
type ToggleSidebar struct{}

// -- Session events --

type SessionInfo struct {
	ID           string
	CreatedAt    string
	Title        string
	MessageCount int
}

type SessionListResult struct {
	Sessions []SessionInfo
	Err      error
}

type SessionMessage struct {
	Role      string
	Content   string
	Timestamp string
}

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

// SSEParseWarning carries a non-fatal SSE parse error.
type SSEParseWarning struct {
	Message string
}

// -- Model selection --

type ModelEntry struct {
	Name     string
	Provider string
	Size     int64
	Active   bool
}

type ModelListResult struct {
	Models   []ModelEntry
	Current  string
	Provider string
	Err      error
}

type ModelSwitchResult struct {
	Provider string
	Model    string
	Err      error
}

// -- Onboarding events --

// OnboardingProvider mirrors client.OnboardingProvider for msg layer.
type OnboardingProvider struct {
	Key          string
	Name         string
	DefaultModel string
	EnvVar       string
}

// OnboardingTemplate describes a discovered OS template.
type OnboardingTemplate struct {
	Name    string
	Path    string
	Stack   map[string]any
	Modules int
}

// OnboardingMachine describes an available machine skill group.
type OnboardingMachine struct {
	Key         string
	Name        string
	Description string
}

// OnboardingChannel describes an available channel.
type OnboardingChannel struct {
	Key         string
	Name        string
	Description string
}

// OnboardingStatusResult from the onboarding status check.
type OnboardingStatusResult struct {
	NeedsOnboarding bool
	Providers       []OnboardingProvider
	Templates       []OnboardingTemplate
	Machines        []OnboardingMachine
	Channels        []OnboardingChannel
	SystemInfo      map[string]any
	Err             error
}

// OnboardingComplete signals successful onboarding setup.
type OnboardingComplete struct {
	Provider string
	Model    string
}

// OnboardingSetupError signals that the setup POST failed.
type OnboardingSetupError struct {
	Err error
}
