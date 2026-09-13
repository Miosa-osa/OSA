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
    /// Which tool's config this came from: "osa" for the operator's own
    /// mcp.json, otherwise the tool it was inherited from.
    #[serde(default)]
    pub source: String,
    /// Whether `/mcp` may switch this server on and off. False for OSA's own
    /// entries, which are edited in mcp.json rather than through the allow list.
    #[serde(default)]
    pub toggleable: bool,
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
    /// The command line the backend actually ran, echoed back. Lets a client
    /// tell WHICH outstanding request an answer belongs to — `/compact` and
    /// `/recap` also arrive as `CommandResult`s, and a pending `/goal` poll must
    /// not be settled by one of them.
    #[serde(default)]
    pub command: String,
    /// Authoritative effort after the command ran. Present on backend CLI
    /// command responses so `/fast` and `/effort` can update persistent UI.
    #[serde(default)]
    pub effort: Option<String>,
    /// Present only on a `/goal` response: the backend `GoalTracker`'s own view
    /// of the goal, so a client can act on it instead of parsing `output`.
    #[serde(default)]
    pub goal: Option<GoalStatus>,
}

/// The backend's authoritative goal state, from `GoalTracker`.
///
/// This exists because `/goal` is the one command whose answer the TUI must act
/// on rather than print: it drives the next turn only while the backend still
/// says the goal is live. Everything here is REPORTED, never inferred — the TUI
/// deciding for itself whether a goal is finished is the `DONE`-sentinel defect
/// this type replaces.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct GoalStatus {
    /// `GoalTracker.goal_loop?/1 and GoalTracker.continue?/1` — the same pair
    /// `ReactLoop.goal_continue_due?/1` gates its own re-entry on. False for a
    /// completed goal (only the skeptic panel can set that), a paused one
    /// (stall / run cap / user), and for no goal at all.
    #[serde(default)]
    pub active: bool,
    /// `active` | `off_track` | `paused` | `completed`, or absent when the
    /// session has no tracker entry yet.
    #[serde(default)]
    pub status: Option<String>,
    #[serde(default)]
    pub phase: Option<String>,
    /// The anchored goal text, as the backend stored it.
    #[serde(default)]
    pub goal: Option<String>,
    #[serde(default)]
    pub goal_id: Option<String>,
    /// Turns the backend has counted against this goal.
    #[serde(default)]
    pub turn_count: u32,
    #[serde(default)]
    pub verify_run_count: u32,
    /// Why a `paused` goal paused: `no_progress` | `run_cap` | `off_track` |
    /// `user`. Names the stop condition so an exhausted goal is distinguishable
    /// from a finished one.
    #[serde(default)]
    pub pause_reason: Option<String>,
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
    /// When true the backend persists this choice as the new sticky default
    /// (app-env + ~/.osa/config.json) so a NEW session or a restart keeps it.
    /// The user-initiated picker sets true; the `--model` launch flag and the
    /// onboarding save-key swap set false so a one-off override never becomes
    /// the accidental default.
    pub persist: bool,
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
    #[serde(default)]
    pub old_provider: Option<String>,
    #[serde(default)]
    pub old_model: Option<String>,
    #[serde(default)]
    pub old_context_window: Option<u64>,
    #[serde(default)]
    pub tokens_before: Option<u64>,
    #[serde(default)]
    pub tokens_after: Option<u64>,
    #[serde(default)]
    pub compacted: Option<bool>,
    #[serde(default)]
    pub warning: Option<String>,
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

/// `Default` is derived so the offline fallback catalog (and tests) can build
/// an entry with `..Default::default()` instead of restating every field. Each
/// new field the backend grows would otherwise break every literal in the
/// crate, which is a strong incentive not to model the payload honestly.
#[derive(Debug, Clone, Deserialize, Default)]
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
    /// The auth modes this provider offers, in the catalog's canonical order
    /// (`api_key` first). Absent on an older backend, which is why it is an
    /// `Option` rather than defaulting to `["api_key"]`: "the backend did not
    /// say" and "the backend said key-only" are the same rendering here, but
    /// not the same fact.
    #[serde(default)]
    pub auth_modes: Option<Vec<String>>,
    /// `auth_modes` filtered down to what THIS machine can actually run — a
    /// sign-in whose client id is not compiled into this build, or whose CLI
    /// is not installed, is dropped. Render from this, never from
    /// `auth_modes`: offering a route that cannot complete is worse than not
    /// offering it.
    #[serde(default)]
    pub usable_auth_modes: Option<Vec<String>>,
    /// Which question this provider answers: `"accounts"` (connect a plan you
    /// already pay for) or `"keys"` (paste a credential). A field rather than
    /// something derived from `auth_modes`, because the two come apart — see
    /// `Onboarding.normalize_grouping/2`.
    #[serde(default)]
    pub tab: Option<String>,
    /// Position within the tab. Catalog order, which is already curated.
    #[serde(default)]
    pub order: Option<i64>,
    /// Live connection state. `None` on an older backend, which is why the
    /// picker still falls back to key-detection for readiness.
    #[serde(default)]
    pub auth: Option<ProviderAuthState>,
    #[serde(default)]
    pub models: serde_json::Value,
}

/// What a provider row is allowed to say about itself.
///
/// `connected` and `verified` are separate upstream for a reason (OSA holding
/// a marker is not evidence the sign-in is live), and `state` is the collapsed
/// answer the backend has already decided — the TUI must not re-derive it.
#[derive(Debug, Clone, Deserialize, Default)]
pub struct ProviderAuthState {
    /// `connected` · `connected_unverified` · `expired` · `needs_sign_in` ·
    /// `needs_key` · `unknown`
    #[serde(default)]
    pub state: String,
    #[serde(default)]
    pub can_sign_in: bool,
    #[serde(default)]
    pub can_paste_key: bool,
    #[serde(default)]
    pub account: Option<String>,
    #[serde(default)]
    pub plan: Option<String>,
}

/// A sign-in in flight, as `Auth.LoginBroker` reports it. Carries the code and
/// URL a human must act on and nothing else — no token ever crosses this.
#[derive(Debug, Clone, Deserialize)]
pub struct LoginSessionResponse {
    pub id: String,
    #[serde(default)]
    pub provider: String,
    /// `starting` · `pending` · `connected` · `failed` · `cancelled`
    #[serde(default)]
    pub state: String,
    #[serde(default)]
    pub user_code: Option<String>,
    #[serde(default)]
    pub verification_uri: Option<String>,
    #[serde(default)]
    pub verification_uri_complete: Option<String>,
    #[serde(default)]
    pub message: Option<String>,
    #[serde(default)]
    pub error: Option<String>,
}

/// `Auth.Providers.ClaudeCli.cli_state/0` — everything a sign-in surface needs
/// to drive Anthropic's own CLI instead of telling the user to go and run it.
///
/// Note what is NOT here: any token. This struct describes a binary and an
/// account; the credential the sign-in produces is minted and kept by Claude
/// Code, and a field for it appearing here would mean OSA had stopped being
/// the sanctioned integration.
#[derive(Debug, Clone, Deserialize, Default, PartialEq, Eq)]
pub struct ClaudeCliState {
    #[serde(default)]
    pub installed: bool,
    #[serde(default)]
    pub path: Option<String>,
    #[serde(default)]
    pub version: Option<String>,
    /// `None` means "no binary to ask", NOT "fine". A tri-state on purpose:
    /// "old enough" is a claim about a version we may not have.
    #[serde(default)]
    pub version_ok: Option<bool>,
    #[serde(default)]
    pub min_version: Option<String>,
    #[serde(default)]
    pub signed_in: bool,
    #[serde(default)]
    pub account: Option<String>,
    #[serde(default)]
    pub org: Option<String>,
    #[serde(default)]
    pub plan: Option<String>,
    /// Absolute path to spawn, so the child does not depend on the TUI's own
    /// PATH matching the backend's.
    #[serde(default)]
    pub login_program: Option<String>,
    /// The subcommand this installation actually has, read from its `--help`.
    /// `None` when none could be identified — which is a blocked screen, never
    /// a guess.
    #[serde(default)]
    pub login_argv: Option<Vec<String>>,
    #[serde(default)]
    pub login_display: Option<String>,
    #[serde(default)]
    pub login_error: Option<String>,
    #[serde(default)]
    pub install_argv: Vec<String>,
    #[serde(default)]
    pub install_url: Option<String>,
}

/// One provider's last-reported quota window, from `Usage.RateLimits`.
///
/// Every field is optional because every field is a *measurement* that a
/// provider may simply not have sent. `used_percent: None` is "not reported
/// yet" and must render as such — this codebase's hard rule is that unknown
/// never renders as a number, and the absence of a default here is what makes
/// obeying it the path of least resistance.
#[derive(Debug, Clone, Deserialize, Default, PartialEq)]
pub struct ProviderQuota {
    #[serde(default)]
    pub used_percent: Option<f64>,
    #[serde(default)]
    pub window_minutes: Option<f64>,
    #[serde(default)]
    pub resets_at: Option<String>,
    #[serde(default)]
    pub limit_name: Option<String>,
    /// Unix seconds. The age of the reading is part of the reading: a 40%
    /// figure observed four hours ago is not a claim about right now.
    #[serde(default)]
    pub observed_at: Option<i64>,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct UsageQuotaResponse {
    /// Keyed by provider id. A provider that has reported nothing is ABSENT,
    /// not present-with-zeroes.
    #[serde(default)]
    pub providers: std::collections::HashMap<String, ProviderQuota>,
    #[serde(default)]
    pub now: Option<i64>,
}

/// One row of `Auth.Subscription.status_all/0`.
#[derive(Debug, Clone, Deserialize, Default)]
pub struct SubscriptionStatus {
    #[serde(default)]
    pub provider: String,
    #[serde(default, rename = "connected?")]
    pub connected: bool,
    #[serde(default, rename = "verified?")]
    pub verified: bool,
    #[serde(default)]
    pub account: Option<String>,
    #[serde(default)]
    pub plan: Option<String>,
    /// Present for providers whose marker records one. Displayed beside the
    /// account because an email alone does not say WHICH account: a user with
    /// a personal and a work plan needs the org to tell them apart.
    #[serde(default)]
    pub org: Option<String>,
    #[serde(default, rename = "expired?")]
    pub expired: bool,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct AuthStatusResponse {
    #[serde(default)]
    pub providers: Vec<SubscriptionStatus>,
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
    /// Optional ≤12-char categorising chip rendered before the question text.
    #[serde(default)]
    pub header: Option<String>,
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


// === Local model manager (/models/local) ===

#[derive(Debug, Clone, Deserialize, Default)]
pub struct LocalFit {
    #[serde(default)]
    pub verdict: String,
    #[serde(default)]
    pub est_tps: Option<f64>,
    #[serde(default)]
    pub weights_bytes: u64,
    #[serde(default)]
    pub kv_bytes: u64,
    #[serde(default)]
    pub gpu_share: f64,
    #[serde(default)]
    pub ctx: u64,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct LocalHardware {
    #[serde(default)]
    pub summary: String,
    #[serde(default)]
    pub gpu: Option<String>,
    #[serde(default)]
    pub vram_bytes: u64,
    #[serde(default)]
    pub ram_bytes: u64,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct LocalModelRow {
    #[serde(default)]
    pub tag: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub installed: bool,
    #[serde(default)]
    pub loaded: bool,
    #[serde(default)]
    pub size_bytes: u64,
    #[serde(default)]
    pub params: Option<String>,
    #[serde(default)]
    pub quant: Option<String>,
    #[serde(default)]
    pub capabilities: Vec<String>,
    #[serde(default)]
    pub fit: Option<LocalFit>,
    #[serde(default)]
    pub measured_tps: Option<f64>,
    #[serde(default)]
    pub catalog_id: Option<String>,
    #[serde(default)]
    pub blurb: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct LocalModelsResponse {
    #[serde(default)]
    pub hardware: LocalHardware,
    #[serde(default)]
    pub ctx: u64,
    #[serde(default)]
    pub installed: Vec<LocalModelRow>,
    #[serde(default)]
    pub catalog: Vec<LocalModelRow>,
    #[serde(default)]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct LocalQuantRow {
    #[serde(default)]
    pub quant: String,
    #[serde(default)]
    pub bytes: u64,
    #[serde(default)]
    pub exact: bool,
    #[serde(default)]
    pub fit: Option<LocalFit>,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct LocalModelInfo {
    #[serde(default)]
    pub tag: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub installed: bool,
    #[serde(default)]
    pub capabilities: Vec<String>,
    #[serde(default)]
    pub family: Option<String>,
    #[serde(default)]
    pub params: Option<String>,
    #[serde(default)]
    pub quant: Option<String>,
    #[serde(default)]
    pub context_length: Option<u64>,
    #[serde(default)]
    pub size_bytes: u64,
    #[serde(default)]
    pub fit: Option<LocalFit>,
    #[serde(default)]
    pub quants: Vec<LocalQuantRow>,
    #[serde(default)]
    pub blurb: Option<String>,
    #[serde(default)]
    pub catalog_id: Option<String>,
    #[serde(default)]
    pub measured: Option<serde_json::Value>,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct LocalBench {
    #[serde(default)]
    pub decode_tps: f64,
    #[serde(default)]
    pub prompt_tps: Option<f64>,
    #[serde(default)]
    pub load_ms: u64,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct LocalInstallJob {
    #[serde(default)]
    pub id: String,
    #[serde(default, rename = "ref")]
    pub reff: String,
    #[serde(default)]
    pub tag: Option<String>,
    #[serde(default)]
    pub state: String,
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub completed: u64,
    #[serde(default)]
    pub total: u64,
    #[serde(default)]
    pub bench: Option<LocalBench>,
    #[serde(default)]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct LocalInstallStarted {
    #[serde(default)]
    pub job_id: String,
}
