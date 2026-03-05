use crate::client::types::*;

/// Agent info emitted during the spawning phase (before agents start running).
#[derive(Debug, Clone)]
pub struct SpawningAgent {
    pub name: String,
    pub role: String,
}

/// Events from the backend (SSE stream + HTTP responses)
#[derive(Debug, Clone)]
pub enum BackendEvent {
    // === SSE Connection Lifecycle ===
    SseConnected { session_id: String },
    SseDisconnected { error: Option<String> },
    SseReconnecting { attempt: u32 },
    SseAuthFailed,

    // === Streaming ===
    StreamingToken { text: String, session_id: String },
    ThinkingDelta { text: String },

    // === Agent Response ===
    AgentResponse {
        response: String,
        response_type: String,
        signal: Option<Signal>,
    },

    // === Tool Calls ===
    ToolCallStart {
        name: String,
        args: String,
    },
    ToolCallEnd {
        name: String,
        duration_ms: u64,
        success: bool,
    },
    ToolResult {
        name: String,
        result: String,
        success: bool,
    },

    // === LLM ===
    LlmRequest { iteration: u32 },
    LlmResponse {
        duration_ms: u64,
        input_tokens: u64,
        output_tokens: u64,
    },

    // === Signal ===
    SignalClassified { signal: Signal },

    // === Orchestrator ===
    OrchestratorTaskStarted { task_id: String },
    OrchestratorAgentsSpawning {
        agent_count: usize,
        agents: Vec<SpawningAgent>,
    },
    OrchestratorTaskAppraised {
        estimated_cost_usd: f64,
        estimated_hours: f64,
    },
    OrchestratorAgentStarted {
        agent_name: String,
        role: String,
        model: String,
        subject: String,
    },
    OrchestratorAgentProgress {
        agent_name: String,
        current_action: String,
        tool_uses: u32,
        tokens_used: u32,
        subject: String,
    },
    OrchestratorAgentCompleted {
        agent_name: String,
        status: String,
        tool_uses: u32,
        tokens_used: u32,
    },
    OrchestratorAgentFailed {
        agent_name: String,
        error: String,
        tool_uses: u32,
        tokens_used: u32,
    },
    OrchestratorWaveStarted {
        wave_number: u32,
        total_waves: u32,
    },
    OrchestratorSynthesizing { agent_count: usize },
    OrchestratorTaskCompleted { task_id: String },

    // === Context ===
    ContextPressure {
        utilization: f64,
        estimated_tokens: u64,
        max_tokens: u64,
    },

    // === Tasks ===
    TaskCreated {
        task_id: String,
        subject: String,
        active_form: String,
    },
    TaskUpdated {
        task_id: String,
        status: String,
    },

    // === Swarm ===
    SwarmStarted {
        swarm_id: String,
        pattern: String,
        agent_count: u32,
        task_preview: String,
    },
    SwarmCompleted {
        swarm_id: String,
        pattern: String,
        agent_count: u32,
        result_preview: String,
    },
    SwarmFailed { swarm_id: String, reason: String },
    SwarmCancelled { swarm_id: String },
    SwarmTimeout { swarm_id: String },

    // === Swarm Intelligence ===
    SwarmIntelligenceStarted {
        swarm_id: String,
        intelligence_type: String,
        task: String,
    },
    SwarmIntelligenceRound { swarm_id: String, round: u32 },
    SwarmIntelligenceConverged { swarm_id: String, round: u32 },
    SwarmIntelligenceCompleted {
        swarm_id: String,
        converged: bool,
        rounds: u32,
    },

    // === Hooks/Budget ===
    HookBlocked { hook_name: String, reason: String },
    BudgetWarning { utilization: f64, message: String },
    BudgetExceeded { message: String },

    // === Parse Warnings ===
    ParseWarning { message: String },

    // === HTTP Response Results ===
    HealthResult(Result<HealthResponse, String>),
    LoginResult(Result<LoginResponse, String>),
    OrchestrateResult(Result<OrchestrateResponse, String>),
    CommandsLoaded(Result<Vec<CommandEntry>, String>),
    ToolsLoaded(Result<Vec<ToolEntry>, String>),
    CommandResult(Result<CommandExecuteResponse, String>),
    SessionsLoaded(Result<Vec<SessionInfo>, String>),
    SessionCreated(Result<SessionCreateResponse, String>),
    ModelsLoaded(Result<ModelListResponse, String>),
    ModelSwitched(Result<ModelSwitchResponse, String>),
    OnboardingStatus(Result<OnboardingStatusResponse, String>),

    // === Additional HTTP Response Results (Phase 2+) ===
    SessionMessages(Result<Vec<SessionMessage>, String>),
    SkillsLoaded(Result<Vec<SkillEntry>, String>),
    SkillCreated(Result<SkillCreateResponse, String>),
    ClassifyResult(Result<ClassifyResponse, String>),
    ComplexTaskResult(Result<ComplexTaskResponse, String>),
    TaskProgressResult(Result<TaskProgress, String>),
    TasksLoaded(Result<Vec<OrchestratedTask>, String>),
    SwarmLaunched(Result<SwarmLaunchResponse, String>),
    SwarmsLoaded(Result<SwarmListResponse, String>),
    SwarmStatusResult(Result<SwarmStatus, String>),
    SwarmCancelResult(Result<(), String>),
    MemorySaved(Result<MemorySaveResponse, String>),
    MemoryRecalled(Result<MemoryRecallResponse, String>),
    AnalyticsResult(Result<AnalyticsResponse, String>),
    SchedulerJobs(Result<Vec<SchedulerJob>, String>),
    SchedulerReloaded(Result<(), String>),
    MachinesLoaded(Result<Vec<MachineInfo>, String>),
    OnboardingComplete(Result<OnboardingSetupResponse, String>),

    // === Dialogs ===
    /// Backend requesting tool permission approval from the user.
    PermissionRequired {
        tool: String,
        args: String,
        request_id: String,
    },
    /// Backend proposing a plan for the user to review before execution.
    PlanProposed {
        plan: String,
        request_id: String,
    },

    // === Cancel ===
    /// Fired 3s after cancel request if the SSE stream hasn't delivered a response.
    /// Forces the UI back to Idle to prevent getting stuck.
    CancelTimeout,
}
