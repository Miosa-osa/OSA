// Backend API contract types — fields exist because the JSON schema requires them,
// not because Rust code reads every field. Suppress dead_code for the whole module.
#![allow(dead_code)]

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

// === Health ===

#[derive(Debug, Clone, Deserialize)]
pub struct HealthResponse {
    pub status: String,
    pub version: String,
    #[serde(default)]
    pub uptime_seconds: i64,
    pub provider: String,
    pub model: String,
    #[serde(default)]
    pub context_window: Option<u64>,
}

// === Settings ===

#[derive(Debug, Clone, Default, Deserialize)]
pub struct FastPathSettings {
    #[serde(default)]
    pub prefetch: bool,
    #[serde(default)]
    pub adaptive_tools: bool,
    #[serde(default)]
    pub full_capability_fallback: bool,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct SettingsResponse {
    #[serde(default)]
    pub provider: String,
    #[serde(default)]
    pub model: String,
    #[serde(default)]
    pub effort_level: String,
    #[serde(default)]
    pub fast_mode: bool,
    #[serde(default)]
    pub max_iterations: u32,
    #[serde(default)]
    pub max_response_tokens: u64,
    #[serde(default)]
    pub tool_budget: u32,
    #[serde(default)]
    pub fast_path: FastPathSettings,
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

// === Orchestrate ===

#[derive(Debug, Clone, Serialize)]
pub struct OrchestrateRequest {
    pub input: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub user_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub workspace_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub skip_plan: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub working_dir: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct OrchestrateResponse {
    pub session_id: String,
    pub status: String,
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
}

#[derive(Debug, Clone, Serialize)]
pub struct CommandExecuteRequest {
    pub command: String,
    pub arg: String,
    pub session_id: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CommandExecuteResponse {
    pub kind: String,
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

#[derive(Debug, Clone, Deserialize)]
pub struct SessionInfo {
    pub id: String,
    pub created_at: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub message_count: i32,
    #[serde(default)]
    pub messages: Option<Vec<SessionMessage>>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SessionMessage {
    pub role: String,
    pub content: String,
    #[serde(default)]
    pub timestamp: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SessionCreateResponse {
    pub id: String,
    pub created_at: String,
    pub title: String,
}

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

// === Error ===

#[derive(Debug, Clone, Deserialize)]
pub struct ErrorResponse {
    pub error: String,
    #[serde(default)]
    pub code: Option<String>,
    #[serde(default)]
    pub details: Option<String>,
}
