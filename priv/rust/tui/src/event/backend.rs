// Phase 2+: SSE wire format fields — parsed from JSON but not all fields consumed by UI yet
#![allow(dead_code)]

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
    //
    // `message_id` is the backend's stable identity for the assistant message
    // these deltas belong to — the text analogue of `tool_call_id`. ONE turn can
    // produce SEVERAL assistant messages (the backend re-enters its ReAct loop
    // after a text-only response for the auto-continue / coding / verification /
    // goal-verifier nudges), and with no tool call between them nothing else
    // marks the boundary: without the id the deltas of a superseded generation
    // and its replacement land in one buffer and render welded together.
    //
    // `Option` on purpose — a new TUI must still work against an older backend
    // that does not emit it, in which case the client keeps its legacy
    // single-buffer behaviour.
    StreamingToken {
        text: String,
        session_id: String,
        message_id: Option<String>,
    },
    ThinkingDelta { text: String },

    // === Agent Response ===
    //
    // The turn's finished assistant text. `message_id` says WHICH message this
    // finalizes, so the client can replace exactly that generation's streamed
    // accumulation and can ignore a repeat delivery of the same finalization.
    AgentResponse {
        response: String,
        response_type: String,
        signal: Option<Signal>,
        message_id: Option<String>,
    },

    // === Tool Calls ===
    //
    // `tool_call_id` is the backend's stable per-call identity and is the ONLY
    // correct way to pair a start with its end/result: tools run concurrently
    // and every shell call is named `shell_execute`, so name-based pairing
    // shuffles results between cells whenever completions land out of order.
    // It is `Option` on purpose — a new TUI must still work against an older
    // backend that does not emit it, in which case consumers fall back to the
    // legacy name-based path.
    ToolCallStart {
        name: String,
        args: String,
        tool_call_id: Option<String>,
    },
    ToolCallEnd {
        name: String,
        duration_ms: u64,
        success: bool,
        tool_call_id: Option<String>,
    },
    ToolResult {
        name: String,
        result: String,
        success: bool,
        tool_call_id: Option<String>,
    },

    /// Live stdout/stderr from a still-running foreground shell command
    /// (`command_output_delta`). Emitted at most ~4/sec while the command runs
    /// so a long build isn't a silent spinner. `chunk` is the incremental bytes
    /// since the previous delta; `tail` is a rolling snapshot of the end of the
    /// output for a client that connected late or dropped frames; `seq` is a
    /// per-command counter so gaps are detectable.
    /// `tool_call_id` identifies the owning shell call so concurrent commands
    /// each get their own preview buffer. `Option` for old-backend compat.
    CommandOutputDelta {
        command: String,
        chunk: String,
        tail: String,
        seq: u64,
        tool_call_id: Option<String>,
    },

    // === LLM ===
    LlmRequest { iteration: u32, max_iterations: Option<u32> },
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
        batch_id: Option<String>,
    },
    OrchestratorAgentProgress {
        agent_name: String,
        current_action: String,
        tool_uses: u32,
        tokens_used: u32,
        subject: String,
        /// Last few tool actions, newest first (empty from older backends).
        recent_actions: Vec<String>,
    },
    OrchestratorAgentCompleted {
        agent_name: String,
        status: String,
        tool_uses: u32,
        tokens_used: u32,
        /// Compact one-line preview of the worker's final result (<=~140 chars),
        /// surfaced under the finished row. `None` from older backends.
        summary: Option<String>,
    },
    OrchestratorAgentFailed {
        agent_name: String,
        error: String,
        tool_uses: u32,
        tokens_used: u32,
        /// Compact one-line error preview (<=~140 chars). `None` from older backends.
        summary: Option<String>,
    },
    OrchestratorWaveStarted {
        wave_number: u32,
        total_waves: u32,
    },
    OrchestratorSynthesizing { agent_count: usize },
    OrchestratorTaskCompleted { task_id: String },

    // === Fleet (full-power background nodes → CC FleetView roster) ===
    /// A full-power fleet node was spawned (Part 3.2 of FLEETVIEW_DESIGN). Drives
    /// the shared `Agents` roster identically to an orchestrator worker.
    FleetNodeStarted {
        node_id: String,
        agent_type: String,
        task: String,
        /// "full" (full-power Loop) or "worker" (lightweight delegate).
        flavor: String,
        depth: u32,
    },
    /// Live progress for a fleet node (current action + cumulative counters).
    FleetNodeProgress {
        node_id: String,
        current_action: String,
        tool_uses: u32,
        tokens_used: u32,
        /// Last few tool actions, newest first (empty from older backends).
        recent_actions: Vec<String>,
    },
    /// A fleet node reached a terminal state ("completed" | "failed" |
    /// "cancelled"), with a compact one-line result/error preview.
    FleetNodeCompleted {
        node_id: String,
        summary: Option<String>,
        status: String,
    },
    /// Fleet-wide live counters for the roster header (Part 4.2 of
    /// FLEETVIEW_DESIGN): `running/cap agents`, plus a "large fleet" warning
    /// once `warn` (>=25 scheduled) so the header reflects the bounded pool.
    FleetSummary {
        running: u32,
        queued: u32,
        cap: u32,
        total_spawned: u32,
        warn: bool,
    },

    // === Background Agents (fire-and-forget subagents) ===
    /// Fetched sidechain transcript for a subagent run (dashboard "view" /
    /// nested Ctrl+O expansion). Ok payload is (agent_id, transcript text).
    AgentTranscript(Result<(String, String), String>),
    /// A subagent was launched in the background via `run_background`.
    BackgroundAgentStarted {
        agent_id: String,
        role: String,
    },
    /// A background subagent finished successfully; `result` is a short preview.
    BackgroundAgentCompleted {
        agent_id: String,
        role: String,
        result: String,
        duration_ms: u64,
    },
    /// A background subagent errored out; `error` is the failure reason.
    BackgroundAgentFailed {
        agent_id: String,
        role: String,
        error: String,
        duration_ms: u64,
    },

    // === Multi-agent workflow (Claude Code parity) ===
    /// A named teammate/sub-agent finished. Rendered as a scrollback line
    /// `⏺ Teammate @{display_name} finished · {duration}`.
    AgentFinished {
        display_name: String,
        duration_ms: u64,
        batch_id: Option<String>,
    },
    /// An inbound message relayed from another agent to the user. Rendered as
    /// `› Message from @{from}: {text}`.
    AgentMessage {
        from: String,
        text: String,
    },
    /// A background shell command finished. Rendered as a toast + scrollback line
    /// `Background command '{command}' completed (exit code {exit_code})`.
    BackgroundCommandCompleted {
        exit_code: i32,
        command: String,
        task_id: String,
    },
    /// Queued background `<task-notification>`s were folded into the agent's
    /// context (busy-turn drain or idle poke). Rendered as a system line so
    /// the user sees WHY the agent pivots to a finished background task.
    TaskNotification {
        count: u32,
        summary: String,
    },
    /// Result of a Ctrl+B mid-run detach request (POST /sessions/:id/detach-shell).
    /// `Ok(background_id)` when the running foreground command was promoted to the
    /// background; `Err(reason)` when there was nothing to detach (or it failed).
    ShellDetached(Result<String, String>),
    /// End-of-turn recap. Persisted as a permanent `✻ Worked for {elapsed}` line
    /// so the elapsed timer survives past the live activity spinner.
    /// `tool_calls` counts substantive tool USES made by this turn (per-call,
    /// internal bookkeeping tools filtered server-side); `tools_used` lists the
    /// turn's distinct substantive tool names (legacy fallback for the count).
    TurnRecap {
        elapsed_ms: u64,
        tool_calls: u32,
        tools_used: Vec<String>,
    },

    // === Context ===
    ContextPressure {
        utilization: f64,
        estimated_tokens: u64,
        max_tokens: u64,
        /// WS8/WS12 — CC token-warning parity: % of usable context left before
        /// auto-compact, and whether the low-context threshold is crossed.
        /// None/absent from older backends.
        percent_left: Option<u32>,
        context_low: Option<bool>,
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
    TaskChecklistShow {
        tasks: Vec<crate::client::types::ChecklistTaskWire>,
    },
    TaskChecklistHide,

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

    // === Goal Verification (independent skeptic panel) ===
    /// The harness-owned goal verifier ran (or is running) a skeptic-panel
    /// round. `phase` is "start" while the panel spawns, "done" once it voted.
    /// On a done round `verdict` is "complete" | "incomplete" | "off_track";
    /// `gaps` carries at most the first couple of lens-tagged findings so the
    /// status indicator can name WHAT is missing. Surfaced as a single compact,
    /// dim indicator tied to the goal line, never a popup.
    GoalVerification {
        phase: String,
        verdict: String,
        round: u32,
        max_runs: u32,
        refuted: u32,
        total: u32,
        gaps: Vec<String>,
    },
    SwarmIntelligenceConverged { swarm_id: String, round: u32 },

    // === Shared scratchpad (multi-agent coordination surface) ===
    /// An agent wrote or appended to the shared file-based scratchpad during a
    /// fan-out. Surfaced as a compact dim line under the agents panel so the
    /// user watches coordination artifacts accumulate. Carries no file contents
    /// — only who/what/size. Transient: cleared when the team finishes or a new
    /// top-level turn starts.
    ScratchpadActivity {
        /// Writing agent id (a worker session id or the coordinator's own).
        agent: String,
        /// Entry name written, e.g. `findings.md`.
        entry: String,
        /// "write" or "append" (mapped to a past-tense verb at render time).
        action: String,
        /// Byte size of the write.
        bytes: u64,
    },
    SwarmIntelligenceCompleted {
        swarm_id: String,
        converged: bool,
        rounds: u32,
    },

    // === Auto Mode (safety guardian) ===
    /// The auto-mode safety guardian paused the run because it blocked one or
    /// more dangerous actions that need human review (`/resume` or approve).
    AutoModePaused {
        blocked_count: u32,
        message: String,
    },

    // === Hooks/Budget ===
    HookBlocked { hook_name: String, reason: String },
    BudgetWarning { utilization: f64, message: String },
    BudgetExceeded { message: String },

    // === Retry / Error visibility (WS1 item 8) ===
    /// Provider call failed and the backend is retrying after `delay_ms`.
    ProviderRetry {
        attempt: u32,
        max_attempts: u32,
        delay_ms: u64,
        reason: String,
    },
    /// Turn-fatal backend error (`llm_error` / `context_overflow`).
    TurnError { kind: String, reason: String },

    // === Parse Warnings ===
    ParseWarning { message: String },

    // === HTTP Response Results ===
    HealthResult(Result<HealthResponse, String>),
    LoginResult(Result<LoginResponse, String>),
    OrchestrateResult(Result<OrchestrateResponse, String>),
    CommandsLoaded(Result<Vec<CommandEntry>, String>),
    ToolsLoaded(Result<Vec<ToolEntry>, String>),
    /// `/context` fetch result → opens the breakdown overlay.
    ContextLoaded(Result<crate::client::types::ContextStats, String>),
    /// `/trust` fetch result → opens the workspace-trust dialog.
    TrustLoaded(Result<crate::client::types::TrustStatus, String>),
    /// `/workspace/identity` fetch result → reconciles status-bar/title/welcome name.
    WorkspaceIdentityLoaded(Result<crate::client::types::WorkspaceIdentity, String>),
    /// Management-surface fetch results → open their overlays.
    PermissionRulesLoaded(Result<crate::client::types::PermissionRulesResponse, String>),
    HooksLoaded(Result<crate::client::types::HooksResponse, String>),
    /// MCP server list fetch. The `bool` is `open`: `true` opens the `/mcp`
    /// dialog (an explicit `/mcp` request), `false` is a quiet background
    /// refresh that only updates the status-bar chip count.
    McpServersLoaded(Result<crate::client::types::McpServersResponse, String>, bool),
    CostLoaded(Result<crate::client::types::CostResponse, String>),
    SkillsBrowserLoaded(Result<Vec<crate::client::types::SkillEntry>, String>),
    MemoriesLoaded(Result<crate::client::types::MemoriesResponse, String>),
    TasksListLoaded(Result<crate::client::types::TasksResponse, String>),
    MetricsLoaded(Result<crate::client::types::MetricsResponse, String>),
    PersonasLoaded(Result<crate::client::types::PersonasResponse, String>),
    SandboxesLoaded(Result<crate::client::types::SandboxesResponse, String>),
    ChannelsListLoaded(Result<crate::client::types::ChannelsListResponse, String>),
    CommandResult(Result<CommandExecuteResponse, String>),
    /// Progress / result of the in-app `/update` self-updater (see
    /// `crate::app::self_update`). Carried on this channel so the background
    /// update task can stream phases and the final outcome to the UI thread.
    SelfUpdate(crate::app::self_update::SelfUpdateEvent),
    SessionsLoaded(Result<Vec<SessionInfo>, String>),
    SessionCreated(Result<SessionCreateResponse, String>),
    /// The active session's human-readable title, pushed over SSE. Arrives as
    /// soon as the first prompt is sent (heuristic) and again if the backend's
    /// small-model refinement produces a better one.
    SessionTitle {
        title: String,
    },
    RewindCheckpointsLoaded(Result<Vec<RewindCheckpoint>, String>),
    RewindRestored(Result<RewindRestoreResponse, String>),
    // (removed: legacy `ModelsLoaded` flat-model-list event — it had no producer
    // and its handler was a no-op. The picker is provider-first via
    // `ProviderPickerData`.)
    ModelSwitched(Result<ModelSwitchResponse, String>),
    OnboardingStatus(Result<OnboardingStatusResponse, String>),

    // === Additional HTTP Response Results (Phase 2+) ===
    SessionMessages(Result<Vec<SessionMessage>, String>),
    /// Outcome of resolving a launch-time `osa resume <ref>` (full id or an
    /// unambiguous prefix). `Ok(id)` switches to that session; `Err(explanation)`
    /// is FATAL — the TUI quits with the message on stderr rather than dropping
    /// the user into an empty conversation that looks like the one they asked for.
    SessionResolved(Result<String, String>),
    // (removed: dead `SkillsLoaded` event — it had no producer (the skills
    // browser is fed by `SkillsBrowserLoaded`) and its handler only logged.
    // U-B5: dead feed pruned rather than wired to a second, redundant UI.)
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
    OnboardingHealthCheck(Result<OnboardingHealthCheckResponse, String>),

    // === Provider-first model picker (3-mode machine) ===
    /// Provider list + detection loaded → open the provider-first picker.
    ProviderPickerData(Result<OnboardingStatusResponse, String>),
    /// Result of verifying a candidate provider key from the key screen.
    ModelPickerKeyVerified(Result<OnboardingHealthCheckResponse, String>),
    /// One poll of an in-flight account sign-in (`/auth/login/status/:id`).
    /// Carries the whole session so the picker can render code + URL + state
    /// from a single source rather than reassembling it from several events.
    AccountLoginUpdate(Result<crate::client::types::LoginSessionResponse, String>),
    /// A provider's dynamic model list loaded → switch picker to Models mode.
    ProviderModelsLoaded(Result<OnboardingModelsResponse, String>),
    /// A reading of `/auth/cli/claude` — what to install, what to run, and who
    /// is signed in. Drives the in-TUI vendor-CLI sign-in screen.
    ClaudeCliState(Result<crate::client::types::ClaudeCliState, String>),
    /// One repaint beat while a vendor CLI owns the pty. Faster than the
    /// app's 200ms tick, because a terminal that lags a fifth of a second
    /// behind the keys being typed into it does not feel like a terminal.
    CliLoginTick,
    /// `/auth/status` + `/usage/quota` for the picker's usage panel. One event
    /// for both, so the panel can never draw an account from one instant
    /// beside a quota window from another.
    ProviderUsage(
        Result<
            (
                crate::client::types::AuthStatusResponse,
                crate::client::types::UsageQuotaResponse,
            ),
            String,
        >,
    ),

    // === Dialogs ===
    /// Backend requesting tool permission approval from the user.
    PermissionRequired {
        tool: String,
        args: String,
        request_id: String,
        /// Human-facing target of the call (skill name, shell command, file
        /// path, delegate task). Shown in the dialog title in place of the bare
        /// tool name — e.g. "Allow skill: lavish?". `None` falls back to `tool`.
        target: Option<String>,
        /// Request kind: "bash" | "file_edit" | "file_write" | "file_delete" | "fetch" | "mcp" | "other".
        kind: String,
        /// Old/new content when the request is an edit/write (diff rendering).
        old_content: Option<String>,
        new_content: Option<String>,
        /// Destructive-command warning (informational).
        warning: Option<String>,
        /// Why the prompt fired (ask rule, out-of-scope path, safety path).
        reason: Option<String>,
    },
    /// Backend proposing a plan for the user to review before execution.
    PlanProposed {
        plan: String,
        request_id: String,
    },
    /// Backend asking the user a survey / multi-question form.
    AskUserQuestion {
        survey_id: String,
        questions: Vec<crate::client::types::SurveyQuestionWire>,
        skippable: bool,
    },
    /// Survey answers have been submitted and acknowledged.
    SurveyAnswered {
        survey_id: String,
        summary: Vec<(String, String)>, // (question, answer_text) pairs
    },

    // === Proactive Mode ===
    ProactiveMessage {
        message: String,
        message_type: String,
    },
    ProactiveModeChanged {
        enabled: bool,
    },

    // === Coordinator Mode ===
    /// The backend coordinator posture changed. When `active` the tool surface is
    /// restricted to delegation/messaging only. Drives the `⧉ coordinator` chip.
    CoordinatorMode {
        active: bool,
    },

    // === Cancel ===
    /// Fired 3s after cancel request if the SSE stream hasn't delivered a response.
    /// Forces the UI back to Idle to prevent getting stuck.
    CancelTimeout,
}
