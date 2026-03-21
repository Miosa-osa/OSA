// src/lib/api/types.ts
// All TypeScript types for the OSA API (localhost:9089/api/v1)

// ── Health ────────────────────────────────────────────────────────────────────

export interface HealthResponse {
  status: "ok" | "degraded" | "error";
  version: string;
  provider: string | null;
  model?: string | null;
  context_window?: number | null;
  /** Optional fields — may not be present in all backend versions */
  uptime_seconds?: number;
  agents_active?: number;
}

// ── Onboarding ────────────────────────────────────────────────────────────────

export interface OnboardingStatus {
  completed: boolean;
  step: "provider" | "model" | "done";
  provider_connected: boolean;
  model_selected: boolean;
}

// ── Sessions ──────────────────────────────────────────────────────────────────

export interface Session {
  id: string;
  title: string | null;
  message_count: number;
  created_at: string | null;
  /** Whether the session's agent loop is still running */
  alive: boolean;
}

export interface CreateSessionRequest {
  title?: string;
  model?: string;
}

export interface CreateSessionResponse {
  /** Backend returns { id, status } on session creation */
  id: string;
  status: string;
}

// ── Messages ──────────────────────────────────────────────────────────────────

export type MessageRole = "user" | "assistant" | "system" | "tool";

export interface ToolCallRef {
  id: string;
  name: string;
  input: Record<string, unknown>;
}

export interface ThinkingBlock {
  type: "thinking";
  thinking: string;
}

export interface Message {
  id: string;
  role: MessageRole;
  content: string;
  timestamp: string;
  tool_calls?: ToolCallRef[];
  /** Extended thinking / reasoning trace, if present */
  thinking?: ThinkingBlock;
}

export interface SendMessageRequest {
  session_id: string;
  content: string;
  model?: string;
  stream?: boolean;
}

export interface SendMessageResponse {
  /** Stream ID to subscribe to via SSE */
  stream_id: string;
  session_id: string;
}

// ── SSE Streaming Events ──────────────────────────────────────────────────────

export type StreamEventType =
  | "streaming_token"
  | "thinking_delta"
  | "tool_call"
  | "tool_result"
  | "system_event"
  | "done"
  | "error";

export interface StreamingTokenEvent {
  type: "streaming_token";
  delta: string;
}

export interface ThinkingDeltaEvent {
  type: "thinking_delta";
  delta: string;
}

export interface ToolCallEvent {
  type: "tool_call";
  tool_use_id: string;
  tool_name: string;
  input: Record<string, unknown>;
  /** Present when the agent is pausing for user permission before executing */
  phase?: "awaiting_permission";
  /** Human-readable description of what the tool will do */
  description?: string;
  /** Relevant file paths or arguments for the permission dialog */
  paths?: string[];
}

export interface ToolResultEvent {
  type: "tool_result";
  tool_use_id: string;
  result: string;
  is_error: boolean;
}

export interface SystemEvent {
  type: "system_event";
  event: string;
  payload?: unknown;
}

export interface DoneEvent {
  type: "done";
  session_id: string;
  message_id: string;
}

export interface ErrorEvent {
  type: "error";
  message: string;
  code?: string;
}

export type StreamEvent =
  | StreamingTokenEvent
  | ThinkingDeltaEvent
  | ToolCallEvent
  | ToolResultEvent
  | SystemEvent
  | DoneEvent
  | ErrorEvent;

// ── Agents ────────────────────────────────────────────────────────────────────

export type AgentStatus = "idle" | "running" | "queued" | "done" | "error";

export interface Agent {
  id: string;
  name: string;
  status: AgentStatus;
  /** 0–100 */
  progress: number;
  task?: string;
  /** Elapsed time in seconds */
  duration?: number;
  /** Tokens consumed in this agent run */
  tokens?: number;
  created_at: string;
  updated_at: string;
  error?: string;
  /** Present only on single-agent GET /api/v1/agents/:id */
  system_prompt?: string;
}

/** Response shape from GET /api/v1/agents */
export interface AgentsListResponse {
  agents: Agent[];
  count: number;
}

/** Response shape from GET /api/v1/agents/hierarchy */
export interface AgentHierarchyResponse {
  hierarchy: HierarchyNode[];
}

// ── Agent Hierarchy ──────────────────────────────────────────────────────────

export type OrgRole = "ceo" | "director" | "lead" | "engineer" | "specialist";

export interface HierarchyNode {
  agent_name: string;
  reports_to: string | null;
  org_role: OrgRole;
  title: string | null;
  org_order: number;
  children: HierarchyNode[];
}

export interface HierarchyUpdateRequest {
  reports_to?: string | null;
  org_role?: OrgRole;
  title?: string | null;
}

// ── Models ────────────────────────────────────────────────────────────────────

export type ModelProvider =
  | "ollama"
  | "ollama-cloud"
  | "anthropic"
  | "openai"
  | "groq"
  | "openrouter";

export interface Model {
  name: string;
  provider: ModelProvider;
  /** Human-readable display name */
  size?: string;
  active: boolean;
  context_window: number;
  description?: string;
  requires_api_key: boolean;
  is_local: boolean;
}

// ── Providers ────────────────────────────────────────────────────────────────

export interface Provider {
  slug: ModelProvider;
  name: string;
  connected: boolean;
  api_key_set: boolean;
}

// ── Settings ──────────────────────────────────────────────────────────────────

export interface Settings {
  provider: ModelProvider;
  model: string;
  api_key?: string;
  working_dir: string;
  budget_daily_usd: number;
  budget_monthly_usd: number;
  theme: "dark" | "light" | "system";
  telemetry: boolean;
  // Fields added in API v1 settings endpoint
  agent_name?: string;
  yolo_mode?: boolean;
  log_level?: "debug" | "info" | "warning" | "error";
  context_window?: number;
}

// ── Orchestrate ───────────────────────────────────────────────────────────────

export interface OrchestrateRequest {
  task: string;
  session_id?: string;
  model?: string;
  agents?: string[];
}

export interface OrchestrateResponse {
  job_id: string;
  session_id: string;
  stream_id: string;
}

// ── Scheduled Runs ───────────────────────────────────────────────────────

export type ScheduledRunStatus =
  | "pending"
  | "running"
  | "succeeded"
  | "failed"
  | "timed_out"
  | "cancelled";

export type RunTriggerType = "schedule" | "manual" | "event" | "assignment";

export interface ScheduledRun {
  id: string;
  scheduled_task_id: string;
  agent_name: string;
  status: ScheduledRunStatus;
  trigger_type: RunTriggerType;
  started_at: string;
  completed_at?: string;
  duration_ms?: number;
  stdout?: string;
  token_usage?: { input: number; output: number; cost_cents: number };
  error_message?: string;
}

export interface CronPreset {
  id: string;
  cron: string;
  label: string;
}

// ── Signals ──────────────────────────────────────────────────────────────────

export type SignalMode =
  | "BUILD"
  | "EXECUTE"
  | "ANALYZE"
  | "MAINTAIN"
  | "ASSIST";
export type SignalGenre = "DIRECT" | "INFORM" | "COMMIT" | "DECIDE" | "EXPRESS";
export type SignalType =
  | "question"
  | "request"
  | "issue"
  | "scheduling"
  | "summary"
  | "report"
  | "general";
export type SignalFormat = "command" | "message" | "notification" | "document";
export type SignalTier = "haiku" | "sonnet" | "opus";

export interface Signal {
  id: string;
  session_id: string;
  channel: string;
  mode: SignalMode;
  genre: SignalGenre;
  type: SignalType;
  format: SignalFormat;
  weight: number;
  tier: SignalTier;
  input_preview: string;
  agent_name: string;
  confidence: "low" | "high";
  metadata: Record<string, unknown>;
  inserted_at: string;
}

export interface SignalStats {
  by_mode: Record<string, number>;
  by_channel: Record<string, number>;
  by_type: Record<string, number>;
  weight_distribution: { haiku: number; sonnet: number; opus: number };
  total: number;
  avg_weight: number;
}

export interface SignalFilters {
  mode?: string;
  type?: string;
  channel?: string;
  weight_min?: number;
  weight_max?: number;
}

export interface SignalPatterns {
  peak_hours: number[];
  avg_weight: number;
  top_agents: { name: string; count: number }[];
  daily_counts: { date: string; count: number }[];
  escalation_count: number;
}

// ── Skills Marketplace ───────────────────────────────────────────────────────

export type SkillSource = "builtin" | "user" | "evolved";
export type SkillCategory =
  | "core"
  | "automation"
  | "reasoning"
  | "workflow"
  | "security"
  | "agent"
  | "utility";

export interface Skill {
  id: string;
  name: string;
  description: string;
  category: SkillCategory;
  source: SkillSource;
  enabled: boolean;
  triggers: string[];
  path: string;
  priority: number;
}

export interface SkillDetail extends Skill {
  instructions: string;
  metadata: Record<string, unknown>;
}

export interface SkillCategoryCount {
  name: string;
  count: number;
}

export interface SkillSearchResult {
  id: string;
  name: string;
  description: string;
  score: number;
}

// ── Dashboard ─────────────────────────────────────────────────────────────────

export interface DashboardKpis {
  active_sessions: number;
  agents_online: number;
  agents_total: number;
  signals_today: number;
  tasks_completed: number;
  tasks_pending: number;
  tokens_used_today: number;
  uptime_seconds: number;
}

export interface DashboardAgent {
  name: string;
  status: "idle" | "running" | "paused";
  current_task?: string;
  last_active?: string;
}

export interface DashboardActivity {
  type: string;
  message: string;
  timestamp: string;
  agent?: string;
  level: "info" | "warning" | "error";
}

export interface DashboardSystemHealth {
  backend: "ok" | "degraded" | "error";
  provider: string | null;
  provider_status: "connected" | "disconnected";
  memory_mb: number;
}

/**
 * Flat response shape returned by GET /api/v1/dashboard.
 * The dashboard store normalizes this into DashboardData.
 */
export interface DashboardApiResponse {
  active_agents: number;
  active_sessions: number;
  memory_entries: number;
  scheduled_tasks: number;
  provider: string | null;
  model: string | null;
  uptime_seconds: number;
  memory_mb: number;
  tools_count: number;
  recent_activity: DashboardActivity[];
  status: "ok" | "degraded" | "error";
}

export interface DashboardData {
  kpis: DashboardKpis;
  active_agents: DashboardAgent[];
  recent_activity: DashboardActivity[];
  system_health: DashboardSystemHealth;
}

// ── Budget & Cost Tracking ────────────────────────────────────────────────────
// ── Projects ─────────────────────────────────────────────────────────────────

export type ProjectStatus = "active" | "completed" | "archived";
export type GoalStatus = "active" | "in_progress" | "completed" | "blocked";
export type GoalPriority = "low" | "medium" | "high";

export interface Project {
  id: number;
  name: string;
  description: string | null;
  goal: string | null;
  workspace_path: string | null;
  status: ProjectStatus;
  slug: string;
  metadata: Record<string, unknown>;
  inserted_at: string;
  updated_at: string;
  /** Server-computed aggregates — present on list/get responses */
  goal_count?: number;
  task_count?: number;
  completed_goal_count?: number;
}

export interface Goal {
  id: number;
  title: string;
  description: string | null;
  parent_id: number | null;
  project_id: number;
  status: GoalStatus;
  priority: GoalPriority;
  metadata: Record<string, unknown>;
  inserted_at: string;
  updated_at: string;
}

export interface GoalTreeNode extends Goal {
  children: GoalTreeNode[];
  task_count?: number;
}

export interface ProjectTask {
  id: number;
  project_id: number;
  task_id: string;
  goal_id: number | null;
  goal: Goal | null;
  inserted_at: string;
}

export interface CreateProjectPayload {
  name: string;
  description?: string;
  goal?: string;
  workspace_path?: string;
}

export interface CreateGoalPayload {
  title: string;
  description?: string;
  parent_id?: number;
  priority?: GoalPriority;
}

// ── Budget & Cost Tracking ───────────────────────────────────────────────────

export interface CostEvent {
  id: number;
  agent_name: string;
  session_id: string | null;
  task_id: string | null;
  provider: string;
  model: string;
  input_tokens: number;
  output_tokens: number;
  cache_read_tokens: number;
  cache_write_tokens: number;
  cost_cents: number;
  inserted_at: string;
}

export interface AgentBudget {
  agent_name: string;
  budget_daily_cents: number;
  budget_monthly_cents: number;
  spent_daily_cents: number;
  spent_monthly_cents: number;
  status: "active" | "paused_budget" | "paused_manual";
  last_reset_daily: string | null;
  last_reset_monthly: string | null;
}

export interface CostSummary {
  daily_spent_cents: number;
  monthly_spent_cents: number;
  daily_limit_cents: number;
  monthly_limit_cents: number;
  daily_events: number;
  monthly_events: number;
}

export interface CostByModel {
  model: string;
  cost_cents: number;
  count: number;
  input_tokens: number;
  output_tokens: number;
}

export interface CostByAgent {
  agent_name: string;
  cost_cents: number;
  count: number;
}

// ── Config Revisions ────────────────────────────────────────────────────────

export interface ConfigRevision {
  id: number;
  entity_type: string;
  entity_id: string;
  revision_number: number;
  previous_config: Record<string, unknown> | null;
  new_config: Record<string, unknown>;
  changed_fields: string[];
  changed_by: string;
  change_reason: string | null;
  metadata: Record<string, unknown>;
  inserted_at: string;
}

export interface ConfigDiff {
  [field: string]: { from: unknown; to: unknown };
}

// ── Resilience ──────────────────────────────────────────────────────────────

export interface QueuedRequest {
  id: string;
  method: string;
  path: string;
  body?: unknown;
  timestamp: number;
}

// ── Workspaces (Canopy protocol) ──────────────────────────────────────────────

export interface Workspace {
  id: string;
  name: string;
  description: string | null;
  directory: string;
  agent_count: number;
  skill_count: number;
  status: "active" | "archived";
  created_at: string;
  updated_at: string;
}

export interface WorkspaceSummary {
  id: string;
  name: string;
  agent_count: number;
  status: "active" | "archived";
}

export interface CreateWorkspacePayload {
  name: string;
  description?: string;
  /** Local filesystem path for the workspace root */
  directory: string;
}

export interface WorkspaceDetail extends Workspace {
  system_md: string | null;
  company_md: string | null;
}

export interface WorkspaceAgent {
  id: string;
  name: string;
  status: AgentStatus;
  task?: string;
}

export interface WorkspaceSkill {
  id: string;
  name: string;
  description: string;
  enabled: boolean;
  category: SkillCategory;
}

export interface WorkspaceConfig {
  system: string | null;
  company: string | null;
  has_system: boolean;
  has_company: boolean;
}

// ── Approvals ────────────────────────────────────────────────────────────────

export type ApprovalType =
  | "agent_create"
  | "budget_change"
  | "task_reassign"
  | "strategy_change"
  | "agent_terminate";
export type ApprovalStatus =
  | "pending"
  | "approved"
  | "rejected"
  | "revision_requested";

export interface Approval {
  id: number;
  type: ApprovalType;
  status: ApprovalStatus;
  title: string;
  description: string | null;
  requested_by: string;
  resolved_by: string | null;
  resolved_at: string | null;
  decision_notes: string | null;
  context: Record<string, unknown>;
  related_entity_type: string | null;
  related_entity_id: string | null;
  inserted_at: string;
  updated_at: string;
}
