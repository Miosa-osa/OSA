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

// ModelEntry describes a single available model.
type ModelEntry struct {
	Name     string `json:"name"`
	Provider string `json:"provider"`
	Size     int64  `json:"size,omitempty"`
	Active   bool   `json:"active,omitempty"`
}

// ModelListResponse from GET /api/v1/models.
type ModelListResponse struct {
	Models   []ModelEntry `json:"models"`
	Current  string       `json:"current"`
	Provider string       `json:"provider"`
}

// ModelSwitchRequest for POST /api/v1/models/switch.
type ModelSwitchRequest struct {
	Provider string `json:"provider"`
	Model    string `json:"model"`
}

// ModelSwitchResponse from POST /api/v1/models/switch.
type ModelSwitchResponse struct {
	Provider string `json:"provider"`
	Model    string `json:"model"`
	Status   string `json:"status"`
}
