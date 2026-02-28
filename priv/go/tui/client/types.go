package client

// HealthResponse from GET /health.
type HealthResponse struct {
	Status        string `json:"status"`
	Version       string `json:"version"`
	UptimeSeconds int64  `json:"uptime_seconds"`
	Provider      string `json:"provider"`
	Model         string `json:"model"`
}

// OrchestrateRequest for POST /api/v1/orchestrate.
type OrchestrateRequest struct {
	Input       string `json:"input"`
	SessionID   string `json:"session_id,omitempty"`
	UserID      string `json:"user_id,omitempty"`
	WorkspaceID string `json:"workspace_id,omitempty"`
}

// Signal classification metadata.
type Signal struct {
	Mode      string  `json:"mode"`
	Genre     string  `json:"genre"`
	Type      string  `json:"type"`
	Format    string  `json:"format"`
	Weight    float64 `json:"weight"`
	Channel   string  `json:"channel"`
	Timestamp string  `json:"timestamp"`
}

// OrchestrateResponse from POST /api/v1/orchestrate.
type OrchestrateResponse struct {
	SessionID      string   `json:"session_id"`
	Output         string   `json:"output"`
	Signal         *Signal  `json:"signal,omitempty"`
	ToolsUsed      []string `json:"tools_used"`
	IterationCount int      `json:"iteration_count"`
	ExecutionMs    int64    `json:"execution_ms"`
}

// ComplexRequest for POST /api/v1/orchestrate/complex.
type ComplexRequest struct {
	Task      string `json:"task"`
	Strategy  string `json:"strategy,omitempty"`
	SessionID string `json:"session_id,omitempty"`
	Blocking  bool   `json:"blocking"`
}

// ComplexResponse from POST /api/v1/orchestrate/complex.
type ComplexResponse struct {
	TaskID    string `json:"task_id"`
	Status    string `json:"status"`
	SessionID string `json:"session_id"`
	Synthesis string `json:"synthesis,omitempty"`
}

// ProgressAgent represents a single agent's progress.
type ProgressAgent struct {
	ID            string `json:"id"`
	Name          string `json:"name"`
	Role          string `json:"role"`
	Status        string `json:"status"`
	ToolUses      int    `json:"tool_uses"`
	TokensUsed    int    `json:"tokens_used"`
	CurrentAction string `json:"current_action"`
}

// ProgressResponse from GET /api/v1/orchestrate/:task_id/progress.
type ProgressResponse struct {
	TaskID      string          `json:"task_id"`
	Status      string          `json:"status"`
	Agents      []ProgressAgent `json:"agents"`
	Formatted   string          `json:"formatted"`
	StartedAt   string          `json:"started_at"`
	CompletedAt string          `json:"completed_at,omitempty"`
}

// CommandEntry from GET /api/v1/commands.
type CommandEntry struct {
	Name        string `json:"name"`
	Description string `json:"description"`
	Category    string `json:"category,omitempty"`
}

// CommandExecuteRequest for POST /api/v1/commands/execute.
type CommandExecuteRequest struct {
	Command   string `json:"command"`
	Arg       string `json:"arg"`
	SessionID string `json:"session_id"`
}

// CommandExecuteResponse from POST /api/v1/commands/execute.
type CommandExecuteResponse struct {
	Kind   string `json:"kind"`
	Output string `json:"output"`
	Action string `json:"action,omitempty"`
}

// ToolEntry from GET /api/v1/tools.
type ToolEntry struct {
	Name        string `json:"name"`
	Description string `json:"description"`
	Module      string `json:"module,omitempty"`
}

// ClassifyRequest for POST /api/v1/classify.
type ClassifyRequest struct {
	Input string `json:"input"`
}

// ClassifyResponse from POST /api/v1/classify.
type ClassifyResponse struct {
	Signal Signal `json:"signal"`
}

// ErrorResponse for API errors.
type ErrorResponse struct {
	Error   string `json:"error"`
	Code    string `json:"code,omitempty"`
	Details string `json:"details,omitempty"`
}

// LoginRequest for POST /api/v1/auth/login.
type LoginRequest struct {
	UserID string `json:"user_id,omitempty"`
}

// LoginResponse from POST /api/v1/auth/login.
type LoginResponse struct {
	Token        string `json:"token"`
	RefreshToken string `json:"refresh_token"`
	ExpiresIn    int    `json:"expires_in"`
}

// RefreshRequest for POST /api/v1/auth/refresh.
type RefreshRequest struct {
	RefreshToken string `json:"refresh_token"`
}

// RefreshResponse from POST /api/v1/auth/refresh.
type RefreshResponse struct {
	Token     string `json:"token"`
	ExpiresIn int    `json:"expires_in"`
}

// SessionInfo from GET /api/v1/sessions.
type SessionInfo struct {
	ID           string `json:"id"`
	CreatedAt    string `json:"created_at"`
	Title        string `json:"title"`
	MessageCount int    `json:"message_count"`
}

// SessionCreateResponse from POST /api/v1/sessions.
type SessionCreateResponse struct {
	ID        string `json:"id"`
	CreatedAt string `json:"created_at"`
	Title     string `json:"title"`
}
