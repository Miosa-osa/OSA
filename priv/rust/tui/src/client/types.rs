// Backend API contract types — fields exist because the JSON schema requires them,
// not because Rust code reads every field. Suppress dead_code for the whole module.
#![allow(dead_code)]

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

// Protocol-driven payloads live in `generated.rs` (produced from the Elixir
// source of truth by `mix osa.gen.tui_types`). Re-export them here so the rest
// of the crate keeps referring to `crate::client::types::*` unchanged, while the
// covered shapes can no longer drift from the Elixir HTTP API.
//
// Covered here: HealthResponse, OrchestrateRequest/Response, SessionInfo,
// SessionMessage, SessionListResponse, SessionCreateResponse,
// SessionMessagesResponse, ContextStats, CompactResponse, RecapResponse,
// RunSummary/RunListResponse/RunCancelResponse, RewindCheckpoint,
// RewindListResponse, RewindRestoreRequest/Response, ErrorResponse.
//
// Everything below is hand-written for payloads codegen does not reach yet.
pub use super::generated::*;

// === Management surfaces (GET /api/v1/permission-rules|hooks|mcp|cost) ===

#[derive(Debug, Clone, Deserialize)]
pub struct PermissionRuleDto {
    #[serde(default)]
    pub behavior: String,
    #[serde(default)]
    pub rule: String,
    #[serde(default)]
    pub source: String,
}
#[derive(Debug, Clone, Deserialize)]
pub struct PermissionRulesResponse {
    #[serde(default)]
    pub rules: Vec<PermissionRuleDto>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct HookEntryDto {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub priority: i64,
}
#[derive(Debug, Clone, Deserialize)]
pub struct HookMetricDto {
    #[serde(default)]
    pub calls: i64,
    #[serde(default)]
    pub avg_us: i64,
}
#[derive(Debug, Clone, Deserialize)]
pub struct HooksResponse {
    #[serde(default)]
    pub hooks: std::collections::HashMap<String, Vec<HookEntryDto>>,
    #[serde(default)]
    pub metrics: std::collections::HashMap<String, HookMetricDto>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct McpServerDto {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub transport: String,
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub tool_count: i64,
}
#[derive(Debug, Clone, Deserialize)]
pub struct McpServersResponse {
    #[serde(default)]
    pub servers: Vec<McpServerDto>,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct CostResponse {
    #[serde(default)]
    pub total_cost_usd: f64,
    #[serde(default)]
    pub total_tokens: u64,
    #[serde(default)]
    pub input_tokens: u64,
    #[serde(default)]
    pub output_tokens: u64,
    #[serde(default)]
    pub sessions: u64,
    #[serde(default)]
    pub since: String,
}

// === Command-surface data (memories/tasks/metrics/personas/sandboxes/channels) ===

#[derive(Debug, Clone, Deserialize)]
pub struct MemoryEntryDto {
    #[serde(default)]
    pub content: String,
    #[serde(default)]
    pub category: String,
    #[serde(default)]
    pub scope: String,
    #[serde(default)]
    pub created_at: String,
}
#[derive(Debug, Clone, Deserialize, Default)]
pub struct MemoriesResponse {
    #[serde(default)]
    pub entries: Vec<MemoryEntryDto>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct TaskDto {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub priority: String,
}
#[derive(Debug, Clone, Deserialize, Default)]
pub struct TasksResponse {
    #[serde(default)]
    pub tasks: Vec<TaskDto>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct MetricCardDto {
    #[serde(default)]
    pub label: String,
    #[serde(default)]
    pub value: String,
    #[serde(default)]
    pub note: String,
    #[serde(default)]
    pub tone: String,
}
#[derive(Debug, Clone, Deserialize)]
pub struct LatencyRowDto {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub kind: String,
    #[serde(default)]
    pub count: u64,
    #[serde(default)]
    pub avg_ms: f64,
    #[serde(default)]
    pub p99_ms: u64,
}
#[derive(Debug, Clone, Deserialize, Default)]
pub struct MetricsResponse {
    #[serde(default)]
    pub cards: Vec<MetricCardDto>,
    #[serde(default)]
    pub rows: Vec<LatencyRowDto>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PersonaDto {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub display: String,
    #[serde(default)]
    pub description: String,
}
#[derive(Debug, Clone, Deserialize, Default)]
pub struct PersonasResponse {
    #[serde(default)]
    pub current: String,
    #[serde(default)]
    pub personas: Vec<PersonaDto>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SandboxDto {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub display_name: String,
    #[serde(default)]
    pub available: bool,
    #[serde(default)]
    pub current: bool,
}
#[derive(Debug, Clone, Deserialize, Default)]
pub struct SandboxesResponse {
    #[serde(default)]
    pub mode: String,
    #[serde(default)]
    pub backends: Vec<SandboxDto>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ChannelDto {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub connected: bool,
    #[serde(default)]
    pub module: Option<String>,
}
#[derive(Debug, Clone, Deserialize, Default)]
pub struct ChannelsListResponse {
    #[serde(default)]
    pub channels: Vec<ChannelDto>,
}

// === Workspace trust (GET/POST /api/v1/workspace/trust) ===

/// One reason a directory is flagged risky (e.g. untracked executables).
#[derive(Debug, Clone, Deserialize)]
pub struct TrustRisk {
    /// Machine tag for the risk category (backend atom → string).
    #[serde(default)]
    pub kind: String,
    /// Human-readable one-line description shown in the dialog.
    pub label: String,
}

/// Trust status for a workspace path, as returned by GET /workspace/trust and
/// POST /workspace/trust/accept.
#[derive(Debug, Clone, Deserialize)]
pub struct TrustStatus {
    pub path: String,
    pub trusted: bool,
    #[serde(default)]
    pub risks: Vec<TrustRisk>,
    #[serde(default)]
    pub session_only: bool,
}

/// Git-root-aware workspace identity, as returned by GET /workspace/identity.
/// Drives the status-bar name, terminal title, and welcome banner so the label
/// reflects the directory the agent actually operates in (not a raw basename).
#[derive(Debug, Clone, Deserialize)]
pub struct WorkspaceIdentity {
    pub cwd: String,
    #[serde(default)]
    pub project_root: String,
    pub name: String,
    #[serde(default)]
    pub is_git: bool,
}

// === Auth ===

#[derive(Debug, Clone, Serialize)]
pub struct LoginRequest {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub user_id: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct LoginResponse {
    pub token: String,
    pub refresh_token: String,
    pub expires_in: i32,
}

// === Signal ===

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Signal {
    #[serde(default)]
    pub mode: String,
    #[serde(default)]
    pub genre: String,
    #[serde(rename = "type", default)]
    pub signal_type: String,
    #[serde(default)]
    pub format: String,
    #[serde(default)]
    pub weight: f64,
    #[serde(default)]
    pub channel: String,
    #[serde(default)]
    pub timestamp: String,
}

// === Commands ===

#[derive(Debug, Clone, Deserialize)]
pub struct CommandEntry {
    pub name: String,
    pub description: String,
    #[serde(default)]
    pub category: Option<String>,
    /// Backend tool names this command needs to be useful. Empty (the default,
    /// and the case for every legacy/ungated command) means "always available".
    /// The TUI hides a command from the `/` palette and `/help` until every
    /// listed tool is present in the session, so there are no dead commands.
    #[serde(default)]
    pub required_tools: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct CommandExecuteRequest {
    pub command: String,
    pub arg: String,
    pub session_id: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CommandExecuteResponse {
    // Some backend command responses only send `{output, command}` (no kind);
    // default to an empty string so those still deserialize and route to the
    // plain-info render path rather than failing the whole response.
    #[serde(default)]
    pub kind: String,
    #[serde(default)]
    pub output: String,
    #[serde(default)]
    pub action: Option<String>,
}

// === Tools ===

#[derive(Debug, Clone, Deserialize)]
pub struct ToolEntry {
    pub name: String,
    pub description: String,
    #[serde(default)]
    pub module: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ToolExecuteRequest {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub arguments: Option<HashMap<String, serde_json::Value>>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ToolExecuteResponse {
    pub tool: String,
    pub status: String,
    pub result: serde_json::Value,
}

// === Sessions ===
//
// SessionInfo and SessionMessage are generated (re-exported above). RecentSession
// is a hand-written listing helper that converts into the generated SessionInfo.

/// A row from GET /api/v1/sessions/recent — past on-disk sessions with real
/// message counts and titles derived from the first user message.
#[derive(Debug, Clone, Deserialize)]
pub struct RecentSession {
    pub session_id: String,
    #[serde(default)]
    pub message_count: i32,
    #[serde(default)]
    pub started_at: Option<String>,
    #[serde(default)]
    pub last_active: Option<String>,
    #[serde(default)]
    pub first_message: Option<String>,
}

impl From<RecentSession> for SessionInfo {
    fn from(r: RecentSession) -> Self {
        SessionInfo {
            id: r.session_id,
            created_at: r.started_at.unwrap_or_default(),
            title: r.first_message.unwrap_or_default(),
            message_count: r.message_count,
            messages: None,
            last_active: r.last_active,
        }
    }
}

// SessionMessage, ContextStats, CompactResponse, RecapResponse and
// SessionCreateResponse are generated (re-exported at the top of this module).

// === Models ===

#[derive(Debug, Clone, Deserialize)]
pub struct ModelEntry {
    pub name: String,
    pub provider: String,
    #[serde(default)]
    pub size: Option<i64>,
    #[serde(default)]
    pub active: Option<bool>,
    #[serde(default)]
    pub context_window: Option<u64>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ModelListResponse {
    pub models: Vec<ModelEntry>,
    pub current: String,
    pub provider: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct ModelSwitchRequest {
    pub provider: String,
    pub model: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ModelSwitchResponse {
    pub provider: String,
    pub model: String,
    pub status: String,
    #[serde(default)]
    pub context_window: Option<u64>,
    /// Reasoning effort of the newly-selected model. When present it refreshes
    /// the status-bar effort chip so it never shows the previous model's value
    /// after a switch (A2). Absent ⇒ the chip is left as-is.
    #[serde(default)]
    pub effort: Option<String>,
}

// === Classify ===

#[derive(Debug, Clone, Serialize)]
pub struct ClassifyRequest {
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub channel: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ClassifyResponse {
    pub signal: Signal,
}

// === Skills ===

#[derive(Debug, Clone, Deserialize)]
pub struct SkillEntry {
    pub name: String,
    pub description: String,
    #[serde(default)]
    pub category: Option<String>,
    #[serde(default)]
    pub triggers: Option<Vec<String>>,
    #[serde(default)]
    pub priority: Option<i32>,
}

#[derive(Debug, Clone, Serialize)]
pub struct SkillCreateRequest {
    pub name: String,
    pub description: String,
    pub instructions: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tools: Option<Vec<String>>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SkillCreateResponse {
    pub status: String,
    pub name: String,
    pub message: String,
}

// === Complex Tasks ===

#[derive(Debug, Clone, Serialize)]
pub struct ComplexTaskRequest {
    pub task: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub strategy: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub blocking: Option<bool>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ComplexTaskResponse {
    pub task_id: String,
    pub status: String,
    #[serde(default)]
    pub synthesis: Option<String>,
    pub session_id: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct TaskProgress {
    pub task_id: String,
    pub status: String,
    #[serde(default)]
    pub agents: Option<Vec<TaskAgentInfo>>,
    #[serde(default)]
    pub formatted: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct TaskAgentInfo {
    pub name: String,
    pub role: String,
    pub status: String,
    pub tool_uses: i32,
    pub tokens_used: i32,
}

#[derive(Debug, Clone, Deserialize)]
pub struct OrchestratedTask {
    pub task_id: String,
    pub status: String,
    pub task: String,
    #[serde(default)]
    pub created_at: Option<String>,
}

// === Swarm ===

#[derive(Debug, Clone, Serialize)]
pub struct SwarmLaunchRequest {
    pub task: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pattern: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_agents: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub timeout_ms: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SwarmLaunchResponse {
    pub swarm_id: String,
    pub status: String,
    pub pattern: String,
    pub agent_count: i32,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SwarmStatus {
    pub id: String,
    pub status: String,
    pub pattern: String,
    pub agent_count: i32,
    #[serde(default)]
    pub result: Option<String>,
    #[serde(default)]
    pub started_at: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SwarmListResponse {
    pub swarms: Vec<SwarmStatus>,
    pub count: i32,
    pub active_count: i32,
}

// === Memory ===

#[derive(Debug, Clone, Serialize)]
pub struct MemorySaveRequest {
    pub content: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub category: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct MemorySaveResponse {
    pub status: String,
    pub category: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct MemoryRecallResponse {
    pub content: String,
}

// === Analytics ===

#[derive(Debug, Clone, Deserialize)]
pub struct AnalyticsResponse {
    #[serde(default)]
    pub sessions: HashMap<String, serde_json::Value>,
    #[serde(default)]
    pub budget: HashMap<String, serde_json::Value>,
    #[serde(default)]
    pub learning: HashMap<String, serde_json::Value>,
    #[serde(default)]
    pub hooks: HashMap<String, serde_json::Value>,
    #[serde(default)]
    pub compactor: HashMap<String, serde_json::Value>,
}

// === Scheduler ===

#[derive(Debug, Clone, Deserialize)]
pub struct SchedulerJob {
    pub name: String,
    pub schedule: String,
    pub failure_count: i32,
    pub circuit_open: bool,
}

// === Machines ===

#[derive(Debug, Clone, Deserialize)]
pub struct MachineInfo {
    pub id: String,
    pub status: String,
}

// === Onboarding ===

#[derive(Debug, Clone, Deserialize)]
pub struct OnboardingModel {
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub ctx: u64,
    #[serde(default)]
    pub tools: bool,
    #[serde(default)]
    pub recommended: bool,
    #[serde(default)]
    pub note: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct OnboardingProvider {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub group: String,
    #[serde(default)]
    pub requires_key: serde_json::Value,
    #[serde(default)]
    pub env_var: Option<String>,
    #[serde(default)]
    pub default_model: Option<String>,
    #[serde(default)]
    pub base_url: Option<String>,
    #[serde(default)]
    pub signup_url: Option<String>,
    #[serde(default)]
    pub models: serde_json::Value,
}

#[derive(Debug, Clone, Deserialize)]
pub struct DetectedProvider {
    pub provider: String,
    pub source: String,
    pub key_preview: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct OllamaLocalStatus {
    #[serde(default)]
    pub reachable: bool,
    #[serde(default)]
    pub url: String,
    #[serde(default)]
    pub model_count: usize,
}

#[derive(Debug, Clone, Deserialize)]
pub struct DetectedProvidersResponse {
    #[serde(default)]
    pub detected: Vec<DetectedProvider>,
    #[serde(default)]
    pub ollama_local: Option<OllamaLocalStatus>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct OnboardingStatusResponse {
    pub needs_onboarding: bool,
    #[serde(default)]
    pub needs_bootstrap: bool,
    #[serde(default)]
    pub system_info: HashMap<String, serde_json::Value>,
    #[serde(default)]
    pub providers: Vec<OnboardingProvider>,
    #[serde(default)]
    pub detected: Option<DetectedProvidersResponse>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct OnboardingModelsResponse {
    #[serde(default)]
    pub models: Vec<OnboardingModel>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct OnboardingHealthCheckResponse {
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub latency_ms: Option<u64>,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub message: Option<String>,
    #[serde(default)]
    pub warning: Option<String>,
    /// Three-way classification from the backend hotfix: "ok" | "key_rejected"
    /// | "unverified". Preferred over guessing from `error` codes when
    /// present; falls back to the old error-code heuristic when absent (older
    /// backend / other providers not yet returning this).
    #[serde(default)]
    pub verified: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct OnboardingSetupRequest {
    pub provider: String,
    pub model: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub api_key: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub base_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub channel_tokens: Option<HashMap<String, String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub user_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub agent_name: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct OnboardingSetupResponse {
    pub status: String,
    #[serde(default)]
    pub provider: Option<String>,
    #[serde(default)]
    pub model: Option<String>,
}

// === Survey ===

#[derive(Debug, Clone, serde::Deserialize)]
pub struct SurveyOptionWire {
    pub label: String,
    pub description: Option<String>,
}

#[derive(Debug, Clone, serde::Deserialize)]
pub struct SurveyQuestionWire {
    pub text: String,
    #[serde(default)]
    pub multi_select: bool,
    pub options: Vec<SurveyOptionWire>,
    #[serde(default)]
    pub skippable: bool,
}

#[derive(Debug, Clone, serde::Deserialize)]
pub struct ChecklistTaskWire {
    pub id: String,
    pub subject: String,
    pub status: String,
    pub active_form: Option<String>,
}

#[derive(Debug, serde::Serialize)]
pub struct SurveyAnswerRequest {
    pub survey_id: String,
    pub answers: Vec<SurveyAnswerEntry>,
    pub session_id: String,
}

#[derive(Debug, serde::Serialize)]
pub struct SurveyAnswerEntry {
    pub question_index: usize,
    pub question_text: String,
    pub selected: Vec<String>,
    pub free_text: Option<String>,
}

// === Rewind checkpoints (/rewind) ===
//
// RewindCheckpoint, RewindRestoreRequest and RewindRestoreResponse are generated
// (re-exported at the top of this module). RewindScope is a hand-written client
// enum that renders into the generated request's `scope: String`.

/// Restore scope for POST /api/v1/rewind/restore.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RewindScope {
    Code,
    Conversation,
    Both,
}

impl RewindScope {
    pub fn as_str(self) -> &'static str {
        match self {
            RewindScope::Code => "code",
            RewindScope::Conversation => "conversation",
            RewindScope::Both => "both",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            RewindScope::Code => "Code only",
            RewindScope::Conversation => "Conversation only",
            RewindScope::Both => "Code + conversation",
        }
    }
}

// RewindRestoreRequest, RewindRestoreResponse and ErrorResponse are generated
// (re-exported at the top of this module).

#[cfg(test)]
mod health_update_parse_tests {
    use super::HealthResponse;

    const BASE: &str = r#"{"status":"ok","version":"0.4.6","provider":"ollama","model":"glm"#;

    #[test]
    fn parses_update_object_when_available() {
        let json = format!(
            r#"{BASE}","update":{{"available":true,"current_version":"0.4.6","latest_version":"0.5.0"}}}}"#
        );
        let h: HealthResponse = serde_json::from_str(&json).unwrap();
        let update = h.update.expect("update object present");
        assert!(update.available);
        assert_eq!(update.current_version, "0.4.6");
        assert_eq!(update.latest_version.as_deref(), Some("0.5.0"));
    }

    #[test]
    fn parses_available_false_with_null_latest() {
        let json = format!(
            r#"{BASE}","update":{{"available":false,"current_version":"0.4.6","latest_version":null}}}}"#
        );
        let h: HealthResponse = serde_json::from_str(&json).unwrap();
        let update = h.update.expect("update object present");
        assert!(!update.available);
        assert_eq!(update.latest_version, None);
    }

    #[test]
    fn absent_update_field_is_none_backward_compatible() {
        // An older backend that omits `update` must still decode.
        let json = format!(r#"{BASE}"}}"#);
        let h: HealthResponse = serde_json::from_str(&json).unwrap();
        assert!(h.update.is_none());
    }
}
