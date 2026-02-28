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
	SkipPlan    bool   `json:"skip_plan,omitempty"`
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
	ResponseType   string   `json:"response_type"`
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
	ID           string           `json:"id"`
	CreatedAt    string           `json:"created_at"`
	Title        string           `json:"title"`
	MessageCount int              `json:"message_count"`
	Messages     []SessionMessage `json:"messages,omitempty"`
}

// SessionMessage is a single message in a session's history.
type SessionMessage struct {
	Role      string `json:"role"` // "user" | "assistant" | "system"
	Content   string `json:"content"`
	Timestamp string `json:"timestamp,omitempty"`
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

// -- Classify -----------------------------------------------------------------

// ClassifyRequest for POST /api/v1/classify.
type ClassifyRequest struct {
	Message string `json:"message"`
	Channel string `json:"channel,omitempty"`
}

// ClassifyResponse from POST /api/v1/classify.
type ClassifyResponse struct {
	Signal Signal `json:"signal"`
}

// -- Tool execution -----------------------------------------------------------

// ToolExecuteRequest for POST /api/v1/tools/:name/execute.
type ToolExecuteRequest struct {
	Arguments map[string]any `json:"arguments,omitempty"`
}

// ToolExecuteResponse from POST /api/v1/tools/:name/execute.
type ToolExecuteResponse struct {
	Tool   string `json:"tool"`
	Status string `json:"status"`
	Result any    `json:"result"`
}

// -- Skills -------------------------------------------------------------------

// SkillEntry from GET /api/v1/skills.
type SkillEntry struct {
	Name        string   `json:"name"`
	Description string   `json:"description"`
	Category    string   `json:"category,omitempty"`
	Triggers    []string `json:"triggers,omitempty"`
	Priority    int      `json:"priority,omitempty"`
}

// SkillCreateRequest for POST /api/v1/skills/create.
type SkillCreateRequest struct {
	Name         string   `json:"name"`
	Description  string   `json:"description"`
	Instructions string   `json:"instructions"`
	Tools        []string `json:"tools,omitempty"`
}

// SkillCreateResponse from POST /api/v1/skills/create.
type SkillCreateResponse struct {
	Status  string `json:"status"`
	Name    string `json:"name"`
	Message string `json:"message"`
}

// -- Complex orchestration ----------------------------------------------------

// ComplexTaskRequest for POST /api/v1/orchestrate/complex.
type ComplexTaskRequest struct {
	Task      string `json:"task"`
	Strategy  string `json:"strategy,omitempty"` // "auto", "parallel", "pipeline"
	SessionID string `json:"session_id,omitempty"`
	Blocking  bool   `json:"blocking,omitempty"`
}

// ComplexTaskResponse from POST /api/v1/orchestrate/complex.
type ComplexTaskResponse struct {
	TaskID    string `json:"task_id"`
	Status    string `json:"status"` // "running" or "completed"
	Synthesis string `json:"synthesis,omitempty"`
	SessionID string `json:"session_id"`
}

// TaskProgress from GET /api/v1/orchestrate/:task_id/progress.
type TaskProgress struct {
	TaskID    string          `json:"task_id"`
	Status    string          `json:"status"`
	Agents    []TaskAgentInfo `json:"agents,omitempty"`
	Formatted string          `json:"formatted,omitempty"`
}

// TaskAgentInfo within TaskProgress.
type TaskAgentInfo struct {
	Name       string `json:"name"`
	Role       string `json:"role"`
	Status     string `json:"status"`
	ToolUses   int    `json:"tool_uses"`
	TokensUsed int    `json:"tokens_used"`
}

// OrchestratedTask from GET /api/v1/orchestrate/tasks.
type OrchestratedTask struct {
	TaskID    string `json:"task_id"`
	Status    string `json:"status"`
	Task      string `json:"task"`
	CreatedAt string `json:"created_at,omitempty"`
}

// -- Swarm management ---------------------------------------------------------

// SwarmLaunchRequest for POST /api/v1/swarm/launch.
type SwarmLaunchRequest struct {
	Task      string `json:"task"`
	Pattern   string `json:"pattern,omitempty"`
	MaxAgents int    `json:"max_agents,omitempty"`
	TimeoutMs int    `json:"timeout_ms,omitempty"`
	SessionID string `json:"session_id,omitempty"`
}

// SwarmLaunchResponse from POST /api/v1/swarm/launch.
type SwarmLaunchResponse struct {
	SwarmID    string `json:"swarm_id"`
	Status     string `json:"status"`
	Pattern    string `json:"pattern"`
	AgentCount int    `json:"agent_count"`
}

// SwarmStatus from GET /api/v1/swarm/:id.
type SwarmStatus struct {
	ID         string `json:"id"`
	Status     string `json:"status"`
	Pattern    string `json:"pattern"`
	AgentCount int    `json:"agent_count"`
	Result     string `json:"result,omitempty"`
	StartedAt  string `json:"started_at,omitempty"`
}

// SwarmListResponse from GET /api/v1/swarm.
type SwarmListResponse struct {
	Swarms      []SwarmStatus `json:"swarms"`
	Count       int           `json:"count"`
	ActiveCount int           `json:"active_count"`
}

// -- Memory -------------------------------------------------------------------

// MemorySaveRequest for POST /api/v1/memory.
type MemorySaveRequest struct {
	Content  string `json:"content"`
	Category string `json:"category,omitempty"`
}

// MemorySaveResponse from POST /api/v1/memory.
type MemorySaveResponse struct {
	Status   string `json:"status"`
	Category string `json:"category"`
}

// MemoryRecallResponse from GET /api/v1/memory/recall.
type MemoryRecallResponse struct {
	Content string `json:"content"`
}

// -- Analytics ----------------------------------------------------------------

// AnalyticsResponse from GET /api/v1/analytics.
type AnalyticsResponse struct {
	Sessions  map[string]any `json:"sessions"`
	Budget    map[string]any `json:"budget"`
	Learning  map[string]any `json:"learning"`
	Hooks     map[string]any `json:"hooks"`
	Compactor map[string]any `json:"compactor"`
}

// -- Scheduler ----------------------------------------------------------------

// SchedulerJob from GET /api/v1/scheduler/jobs.
type SchedulerJob struct {
	Name         string `json:"name"`
	Schedule     string `json:"schedule"`
	FailureCount int    `json:"failure_count"`
	CircuitOpen  bool   `json:"circuit_open"`
}

// -- Machines -----------------------------------------------------------------

// MachineInfo from GET /api/v1/machines.
type MachineInfo struct {
	ID     string `json:"id"`
	Status string `json:"status"`
}
