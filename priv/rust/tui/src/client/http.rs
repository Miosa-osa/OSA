// Backend API client — methods exist for the full API surface, wired as features mature
#![allow(dead_code)]

use anyhow::Result;
use reqwest::Client as HttpClient;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::RwLock;
use tracing::{debug, info};

use super::auth::{self, AuthState};
use super::types::*;

const DEFAULT_TIMEOUT: Duration = Duration::from_secs(300);

/// Ceiling for the endpoints that hold a connection open for a WHOLE TURN.
///
/// `POST /api/v1/orchestrate` is not a request/response call; it is a long-poll
/// the backend answers only once the turn is finished. `DEFAULT_TIMEOUT` (300s)
/// therefore was not a network-health guard on that path — it was a hidden,
/// undocumented ceiling on how long ANY turn was allowed to take, and it sat
/// BELOW every ceiling the backend enforces:
///
/// | ceiling                                                  | value |
/// |----------------------------------------------------------|-------|
/// | this client's `DEFAULT_TIMEOUT`                           | 300s  |
/// | `ClaudeCli.@default_timeout_ms` (one provider call)       | 600s  |
/// | `Anthropic` receive_timeout with thinking on              | 600s  |
/// | `LLMClient` absolute safety net (one provider call)       | 3600s |
///
/// So a turn between 5 and 10 minutes died HERE, as
/// `Orchestrate failed: error decoding response body` — a message that names
/// neither the timeout nor the turn — while the backend went on running it to
/// its own limit, holding the session busy and billing for work whose answer
/// could no longer be delivered. A turn is also not one provider call: it is a
/// loop of them plus tool execution, so 600s is not its ceiling either.
///
/// The turn's ceiling belongs to the backend, which owns the cancel flag, the
/// idle watchdog and the absolute net — and to the user, who can interrupt.
/// This value exists only so a genuinely wedged socket cannot hang the TUI
/// forever; it is deliberately ABOVE the backend's own absolute net so the
/// backend's diagnosis always arrives first and the user is told what happened
/// instead of being handed a decode error.
const TURN_TIMEOUT: Duration = Duration::from_secs(3900);

/// Pull the backend's human-readable `details` out of an API error string.
///
/// `ApiClient::get` formats non-2xx as `HTTP 404 Not Found from /path: {json}`,
/// which is the right thing for a log line and the wrong thing to put in front
/// of a user. When the embedded body carries a `details` (or `message`) field,
/// that sentence is returned on its own; otherwise the original string is
/// passed through unchanged so nothing is ever lost.
pub(crate) fn extract_error_details(raw: &str) -> String {
    let Some(start) = raw.find('{') else {
        return raw.to_string();
    };
    let Ok(json) = serde_json::from_str::<serde_json::Value>(&raw[start..]) else {
        return raw.to_string();
    };
    json.get("details")
        .or_else(|| json.get("message"))
        .and_then(|d| d.as_str())
        .filter(|d| !d.is_empty())
        .map(|d| d.to_string())
        .unwrap_or_else(|| raw.to_string())
}

/// Percent-encode a value for use in a query string.
///
/// Hand-rolled rather than pulling in a crate: the only caller is the session
/// resolver, whose input is a user-typed session reference. Unreserved
/// characters (RFC 3986 §2.3) pass through, everything else — including the
/// `&`/`=`/`#`/space that would otherwise let a typo restructure the URL — is
/// escaped.
pub(crate) fn percent_encode_query(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*byte as char)
            }
            other => out.push_str(&format!("%{:02X}", other)),
        }
    }
    out
}

pub struct ApiClient {
    http: HttpClient,
    base_url: String,
    auth: Arc<RwLock<AuthState>>,
    pub(crate) profile_dir: PathBuf,
}

impl ApiClient {
    pub fn new(base_url: String, profile_dir: PathBuf) -> Result<Self> {
        let http = HttpClient::builder()
            .timeout(DEFAULT_TIMEOUT)
            // Evict idle pooled sockets well before Bandit/Thousand_Island's
            // ~60s server-side idle close, so reqwest never writes a request
            // onto a keep-alive socket the backend has already closed.
            .pool_idle_timeout(Duration::from_secs(15))
            .tcp_keepalive(Duration::from_secs(30))
            .build()?;

        // Try to load saved tokens
        let auth_state = match auth::load_tokens(&profile_dir) {
            Some((token, refresh_token)) => {
                info!("Loaded saved authentication tokens");
                AuthState::Authenticated {
                    token,
                    refresh_token,
                }
            }
            None => AuthState::Unauthenticated,
        };

        Ok(Self {
            http,
            base_url,
            auth: Arc::new(RwLock::new(auth_state)),
            profile_dir,
        })
    }

    /// Expose base URL for SSE client construction.
    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    /// Get current auth token (if authenticated).
    pub async fn token(&self) -> Option<String> {
        let auth = self.auth.read().await;
        auth.require_token().ok().map(|s| s.to_string())
    }

    /// Check if authenticated.
    pub async fn is_authenticated(&self) -> bool {
        self.auth.read().await.is_authenticated()
    }

    // =========================================================================
    // Phase 1: Fully implemented methods
    // =========================================================================

    /// GET /health -- no auth required.
    pub async fn health(&self) -> Result<HealthResponse> {
        let resp = self.get_no_auth("/health").await?;
        Ok(resp.json().await?)
    }

    /// POST /api/v1/auth/login
    ///
    /// Runs right after the health check succeeds, on the SAME connection
    /// pool that just finished (possibly retried) health polling — a
    /// stale-socket/ECONNRESET blip here is exactly as likely as the one
    /// that hit the onboarding health-check POST, but this call had no
    /// retry protection at all: a single transient failure meant no SSE
    /// connect, no onboarding check, no commands/tools load, dropping a
    /// fresh install straight into an empty Idle screen with the onboarding
    /// wizard never even offered. `send_retry_body` covers the same
    /// transport-only retry as every other hardened onboarding call; login
    /// has no side effect to double-apply (it just mints a fresh token), so
    /// retrying is safe.
    pub async fn login(&self, user_id: Option<&str>) -> Result<LoginResponse> {
        let body = LoginRequest {
            user_id: user_id.map(|s| s.to_string()),
        };
        let url = format!("{}/api/v1/auth/login", self.base_url);
        let resp = self
            .send_retry_body(self.http.post(&url).json(&body))
            .await?;
        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            anyhow::bail!("HTTP {} from /api/v1/auth/login: {}", status, body);
        }
        let result: LoginResponse = resp.json().await?;

        // Update auth state and persist
        {
            let mut auth = self.auth.write().await;
            *auth = AuthState::Authenticated {
                token: result.token.clone(),
                refresh_token: result.refresh_token.clone(),
            };
        }
        auth::save_tokens(&self.profile_dir, &result.token, &result.refresh_token)?;
        info!("Login successful, tokens saved");

        Ok(result)
    }

    /// POST /api/v1/auth/refresh
    pub async fn refresh_token(&self) -> Result<LoginResponse> {
        let refresh = {
            let auth = self.auth.read().await;
            auth.refresh_token()
                .map(|s| s.to_string())
                .ok_or_else(|| anyhow::anyhow!("No refresh token available"))?
        };

        let url = format!("{}/api/v1/auth/refresh", self.base_url);
        let body = serde_json::json!({ "refresh_token": refresh });
        let resp = self.http.post(&url).json(&body).send().await?;
        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            anyhow::bail!("HTTP {} from /api/v1/auth/refresh: {}", status, body);
        }
        let result: LoginResponse = resp.json().await?;

        // Update auth state and persist
        {
            let mut auth = self.auth.write().await;
            *auth = AuthState::Authenticated {
                token: result.token.clone(),
                refresh_token: result.refresh_token.clone(),
            };
        }
        auth::save_tokens(&self.profile_dir, &result.token, &result.refresh_token)?;
        debug!("Token refresh successful");

        Ok(result)
    }

    /// POST /api/v1/auth/logout
    pub async fn logout(&self) -> Result<()> {
        // Best-effort server logout
        let _ = self.post("/api/v1/auth/logout", &serde_json::json!({})).await;

        // Always clear local state
        {
            let mut auth = self.auth.write().await;
            *auth = AuthState::Unauthenticated;
        }
        auth::clear_tokens(&self.profile_dir);
        info!("Logged out");
        Ok(())
    }

    /// GET /api/v1/commands
    pub async fn list_commands(&self) -> Result<Vec<CommandEntry>> {
        let resp = self.get("/api/v1/commands").await?;
        let wrapper: serde_json::Value = resp.json().await?;
        let commands: Vec<CommandEntry> =
            serde_json::from_value(wrapper.get("commands").cloned().unwrap_or_default())?;
        Ok(commands)
    }

    /// GET /api/v1/tools
    pub async fn list_tools(&self) -> Result<Vec<ToolEntry>> {
        let resp = self.get("/api/v1/tools").await?;
        let wrapper: serde_json::Value = resp.json().await?;
        let tools: Vec<ToolEntry> =
            serde_json::from_value(wrapper.get("tools").cloned().unwrap_or_default())?;
        Ok(tools)
    }

    /// POST /api/v1/orchestrate
    pub async fn orchestrate(&self, req: &OrchestrateRequest) -> Result<OrchestrateResponse> {
        let resp = self.post_turn("/api/v1/orchestrate", req).await?;
        Ok(resp.json().await?)
    }

    /// POST /api/v1/commands/execute
    pub async fn execute_command(
        &self,
        req: &CommandExecuteRequest,
    ) -> Result<CommandExecuteResponse> {
        let resp = self.post("/api/v1/commands/execute", req).await?;
        Ok(resp.json().await?)
    }

    // =========================================================================
    // Stub methods -- Phase 2+
    // =========================================================================

    // -- Sessions --

    /// GET /api/v1/sessions
    pub async fn list_sessions(&self) -> Result<Vec<SessionInfo>> {
        let resp = self.get("/api/v1/sessions").await?;
        let wrapper: serde_json::Value = resp.json().await?;
        let sessions: Vec<SessionInfo> =
            serde_json::from_value(wrapper.get("sessions").cloned().unwrap_or_default())?;
        Ok(sessions)
    }

    /// POST /api/v1/sessions
    /// Create a session, or resume the one for `working_dir` if it exists
    /// (directory-scoped, Claude Code style).
    pub async fn create_session(
        &self,
        working_dir: Option<String>,
    ) -> Result<SessionCreateResponse> {
        let body = match working_dir {
            Some(dir) => serde_json::json!({ "working_dir": dir }),
            None => serde_json::json!({}),
        };
        let resp = self.post("/api/v1/sessions", &body).await?;
        Ok(resp.json().await?)
    }

    /// GET /api/v1/sessions/recent
    /// Past on-disk sessions with real titles/message counts/last-active times.
    pub async fn recent_sessions(&self) -> Result<Vec<SessionInfo>> {
        let resp = self.get("/api/v1/sessions/recent").await?;
        let wrapper: serde_json::Value = resp.json().await?;
        let recents: Vec<RecentSession> =
            serde_json::from_value(wrapper.get("sessions").cloned().unwrap_or_default())?;
        Ok(recents.into_iter().map(SessionInfo::from).collect())
    }

    /// GET /api/v1/rewind/:session_id — list recent rewind checkpoints
    /// (conversation + code snapshots taken before each user prompt).
    pub async fn list_rewind_checkpoints(&self, session_id: &str) -> Result<Vec<RewindCheckpoint>> {
        let resp = self
            .get(&format!("/api/v1/rewind/{}", session_id))
            .await?;
        let wrapper: serde_json::Value = resp.json().await?;
        let checkpoints: Vec<RewindCheckpoint> =
            serde_json::from_value(wrapper.get("checkpoints").cloned().unwrap_or_default())?;
        Ok(checkpoints)
    }

    /// POST /api/v1/rewind/restore — restore code / conversation / both from a
    /// rewind checkpoint.
    pub async fn restore_rewind(
        &self,
        session_id: &str,
        checkpoint_id: &str,
        scope: RewindScope,
    ) -> Result<RewindRestoreResponse> {
        let body = RewindRestoreRequest {
            session_id: session_id.to_string(),
            checkpoint_id: checkpoint_id.to_string(),
            scope: scope.as_str().to_string(),
        };
        let resp = self.post("/api/v1/rewind/restore", &body).await?;
        Ok(resp.json().await?)
    }

    /// POST /api/v1/sessions with { working_dir } — directory-scoped resume.
    /// Returns the existing session for `working_dir` (status "resumed") if one
    /// exists on disk, otherwise a freshly created one (status "created").
    pub async fn resume_for_dir(&self, working_dir: String) -> Result<SessionCreateResponse> {
        let body = serde_json::json!({ "working_dir": working_dir });
        let resp = self.post("/api/v1/sessions", &body).await?;
        Ok(resp.json().await?)
    }

    /// GET /api/v1/sessions/:id
    pub async fn get_session(&self, id: &str) -> Result<SessionInfo> {
        let resp = self.get(&format!("/api/v1/sessions/{}", id)).await?;
        Ok(resp.json().await?)
    }

    /// GET /api/v1/sessions/:id/health
    pub async fn get_session_health(&self, id: &str) -> Result<serde_json::Value> {
        let resp = self
            .get(&format!("/api/v1/sessions/{}/health", id))
            .await?;
        Ok(resp.json().await?)
    }

    /// GET /api/v1/sessions/:id/context — token-usage breakdown for the session.
    pub async fn get_context(&self, id: &str) -> Result<ContextStats> {
        let resp = self
            .get(&format!("/api/v1/sessions/{}/context", id))
            .await?;
        Ok(resp.json().await?)
    }

    /// GET /api/v1/permission-rules — standing permission rules with provenance.
    pub async fn get_permission_rules(
        &self,
    ) -> Result<crate::client::types::PermissionRulesResponse> {
        let resp = self.get("/api/v1/permission-rules").await?;
        Ok(resp.json().await?)
    }

    /// GET /api/v1/hooks — registered hooks per event + metrics.
    pub async fn get_hooks(&self) -> Result<crate::client::types::HooksResponse> {
        let resp = self.get("/api/v1/hooks").await?;
        Ok(resp.json().await?)
    }

    /// GET /api/v1/mcp — configured MCP servers + status.
    pub async fn get_mcp_servers(&self) -> Result<crate::client::types::McpServersResponse> {
        let resp = self.get("/api/v1/mcp").await?;
        Ok(resp.json().await?)
    }

    /// POST /api/v1/mcp/:name/toggle — flip an inherited server on or off.
    ///
    /// The backend owns the allow-list edit (`mcp_import_only` in user
    /// settings) and reloads the client, so the caller only has to refetch.
    pub async fn toggle_mcp_server(&self, name: &str) -> Result<()> {
        let path = format!("/api/v1/mcp/{name}/toggle");
        let _ = self.post(&path, &serde_json::json!({})).await?;
        Ok(())
    }

    /// GET /api/v1/cost — spend + token accounting.
    pub async fn get_cost(&self) -> Result<crate::client::types::CostResponse> {
        let resp = self.get("/api/v1/cost").await?;
        Ok(resp.json().await?)
    }

    /// GET /api/v1/memories — persistent memory entries.
    pub async fn get_memories(&self) -> Result<crate::client::types::MemoriesResponse> {
        Ok(self.get("/api/v1/memories").await?.json().await?)
    }
    /// GET /api/v1/tasks-list — task queue.
    pub async fn get_tasks_list(&self) -> Result<crate::client::types::TasksResponse> {
        Ok(self.get("/api/v1/tasks-list").await?.json().await?)
    }
    /// GET /api/v1/metrics — telemetry summary (cards + latency rows).
    pub async fn get_metrics(&self) -> Result<crate::client::types::MetricsResponse> {
        Ok(self.get("/api/v1/metrics").await?.json().await?)
    }
    /// GET /api/v1/personas — persona presets + current.
    pub async fn get_personas(&self) -> Result<crate::client::types::PersonasResponse> {
        Ok(self.get("/api/v1/personas").await?.json().await?)
    }
    /// GET /api/v1/sandboxes — sandbox backends + current.
    pub async fn get_sandboxes(&self) -> Result<crate::client::types::SandboxesResponse> {
        Ok(self.get("/api/v1/sandboxes").await?.json().await?)
    }
    /// GET /api/v1/channels — connected channel adapters.
    pub async fn get_channels(&self) -> Result<crate::client::types::ChannelsListResponse> {
        Ok(self.get("/api/v1/channels").await?.json().await?)
    }

    /// GET /api/v1/workspace/identity — git-root-aware workspace name for chrome.
    pub async fn get_workspace_identity(
        &self,
    ) -> Result<crate::client::types::WorkspaceIdentity> {
        Ok(self.get("/api/v1/workspace/identity").await?.json().await?)
    }

    /// GET /api/v1/workspace/trust?path=<dir> — current trust status + risks.
    pub async fn get_trust(&self, path: &str) -> Result<crate::client::types::TrustStatus> {
        let enc: String = path
            .chars()
            .map(|ch| match ch {
                ' ' => "%20".to_string(),
                '#' => "%23".to_string(),
                '?' => "%3F".to_string(),
                '&' => "%26".to_string(),
                c => c.to_string(),
            })
            .collect();
        let resp = self
            .get(&format!("/api/v1/workspace/trust?path={}", enc))
            .await?;
        Ok(resp.json().await?)
    }

    /// POST /api/v1/workspace/trust/accept — persist trust for <dir>.
    pub async fn accept_trust(&self, path: &str) -> Result<crate::client::types::TrustStatus> {
        let resp = self
            .post(
                "/api/v1/workspace/trust/accept",
                &serde_json::json!({ "path": path }),
            )
            .await?;
        Ok(resp.json().await?)
    }

    /// POST /api/v1/sessions/:id/compact — trigger proactive compaction now.
    /// A non-empty `instructions` string is sent as custom summarization
    /// guidance (CC `/compact <instructions>` parity).
    pub async fn compact_session(&self, id: &str, instructions: &str) -> Result<CompactResponse> {
        let body = if instructions.trim().is_empty() {
            serde_json::json!({})
        } else {
            serde_json::json!({ "instructions": instructions })
        };
        let resp = self
            .post(&format!("/api/v1/sessions/{}/compact", id), &body)
            .await?;
        Ok(resp.json().await?)
    }

    /// POST /api/v1/sessions/:id/clear — reset the backend session context
    /// (session_end hooks → save → fresh loop with parent lineage →
    /// session_start hooks; workstream M).
    ///
    /// The endpoint is a session SWAP, not an in-place wipe: it stops the old
    /// loop and returns a BRAND NEW session id (`{id, status: "cleared",
    /// parent_session, working_dir}`), which deserializes into
    /// `SessionCreateResponse`. The caller MUST adopt that id.
    ///
    /// This used to return `Result<()>` and drop the body, which made `/clear`
    /// a lie in the one way that matters. Keeping the old id meant the next
    /// `POST /orchestrate` addressed the session the clear had just stopped;
    /// `ensure_loop` restarted it, and `Loop.init` found no checkpoint (the
    /// clear had wiped it) and fell through to `load_persisted_messages/1` —
    /// reading back the very file the clear endpoint itself had just written
    /// via its pre-clear `auto_save`. The entire "cleared" conversation was
    /// reloaded into the model, and the fresh session the backend had built
    /// was orphaned, never addressed by anyone.
    pub async fn clear_session(&self, id: &str) -> Result<SessionCreateResponse> {
        let resp = self
            .post(
                &format!("/api/v1/sessions/{}/clear", id),
                &serde_json::json!({}),
            )
            .await?;
        Ok(resp.json().await?)
    }

    /// GET /api/v1/sessions/:id/recap — short LLM summary of the session so far.
    pub async fn recap_session(&self, id: &str) -> Result<RecapResponse> {
        let resp = self.get(&format!("/api/v1/sessions/{}/recap", id)).await?;
        Ok(resp.json().await?)
    }

    /// POST /api/v1/sessions/:id/fork — fork into a new session seeded with the
    /// current transcript. Returns the new session (SessionCreateResponse).
    pub async fn fork_session(&self, id: &str) -> Result<SessionCreateResponse> {
        let resp = self
            .post(
                &format!("/api/v1/sessions/{}/fork", id),
                &serde_json::json!({}),
            )
            .await?;
        Ok(resp.json().await?)
    }

    /// GET /api/v1/sessions/:id/messages
    /// GET /api/v1/sessions/resolve?id=<ref> — turn a user-typed session
    /// reference (full id, or an unambiguous PREFIX of one) into the one real
    /// session id it names.
    ///
    /// Deliberately surfaces non-2xx as an `Err` carrying the backend's own
    /// explanation. `get_session_messages` answers 200 + `[]` for an id that
    /// never existed, so resolving through THIS call is what makes a bad
    /// `osa resume <id>` fail loudly instead of opening a blank conversation
    /// that looks exactly like a healthy one.
    pub async fn resolve_session(&self, session_ref: &str) -> Result<String> {
        let resp = match self
            .get(&format!(
                "/api/v1/sessions/resolve?id={}",
                percent_encode_query(session_ref)
            ))
            .await
        {
            Ok(resp) => resp,
            // `get` turns any non-2xx into `HTTP <status> from <path>: <body>`.
            // That is the right default everywhere else, but this message is
            // shown to the USER on a failed `osa resume`, so unwrap the
            // backend's own explanation out of it.
            Err(e) => anyhow::bail!("{}", extract_error_details(&e.to_string())),
        };
        let body: serde_json::Value = resp.json().await.unwrap_or(serde_json::Value::Null);
        match body.get("id").and_then(|i| i.as_str()) {
            Some(id) if !id.is_empty() => Ok(id.to_string()),
            // A 200 with no id would be a backend contract break; treat it as a
            // failure rather than switching to an empty string session.
            _ => anyhow::bail!("session resolve returned no id for {:?}", session_ref),
        }
    }

    pub async fn get_session_messages(&self, id: &str) -> Result<Vec<SessionMessage>> {
        let resp = self.get(&format!("/api/v1/sessions/{}/messages", id)).await?;
        let wrapper: serde_json::Value = resp.json().await?;
        let messages: Vec<SessionMessage> =
            serde_json::from_value(wrapper.get("messages").cloned().unwrap_or_default())?;
        Ok(messages)
    }

    // -- Models --

    /// GET /api/v1/models
    pub async fn list_models(&self) -> Result<ModelListResponse> {
        let resp = self.get("/api/v1/models").await?;
        Ok(resp.json().await?)
    }

    /// POST /api/v1/models/switch — GLOBAL default only (affects future
    /// sessions, not any session that already has a live `Loop` GenServer).
    /// Kept for onboarding/first-run flows where no session exists yet.
    /// Do NOT use this to switch the model of the CURRENT session — use
    /// `switch_session_model` instead, or the live turn keeps calling the
    /// old provider/model while the UI silently claims success.
    pub async fn switch_model(&self, req: &ModelSwitchRequest) -> Result<ModelSwitchResponse> {
        let resp = self.post("/api/v1/models/switch", req).await?;
        Ok(resp.json().await?)
    }

    /// POST /api/v1/sessions/:id/provider — hot-swap the LLM provider/model on
    /// the LIVE session's `Loop` GenServer (`Loop.handle_call({:swap_provider,
    /// ...})`). This is the endpoint that actually changes what the current
    /// conversation uses on its next turn; `switch_model` above only updates
    /// process-wide defaults that a brand-new session would pick up.
    pub async fn switch_session_model(
        &self,
        session_id: &str,
        req: &ModelSwitchRequest,
    ) -> Result<ModelSwitchResponse> {
        let resp = self
            .post(&format!("/api/v1/sessions/{}/provider", session_id), req)
            .await?;
        Ok(resp.json().await?)
    }

    // -- Classify --

    /// POST /api/v1/classify
    pub async fn classify(&self, req: &ClassifyRequest) -> Result<ClassifyResponse> {
        let resp = self.post("/api/v1/classify", req).await?;
        Ok(resp.json().await?)
    }

    // -- Skills --

    /// GET /api/v1/skills
    pub async fn list_skills(&self) -> Result<Vec<SkillEntry>> {
        let resp = self.get("/api/v1/skills").await?;
        let wrapper: serde_json::Value = resp.json().await?;
        let skills: Vec<SkillEntry> =
            serde_json::from_value(wrapper.get("skills").cloned().unwrap_or_default())?;
        Ok(skills)
    }

    /// POST /api/v1/skills/create
    pub async fn create_skill(&self, req: &SkillCreateRequest) -> Result<SkillCreateResponse> {
        let resp = self.post("/api/v1/skills/create", req).await?;
        Ok(resp.json().await?)
    }

    // -- Complex orchestration --

    /// POST /api/v1/orchestrate/complex
    pub async fn complex_task(&self, req: &ComplexTaskRequest) -> Result<ComplexTaskResponse> {
        let resp = self.post_turn("/api/v1/orchestrate/complex", req).await?;
        Ok(resp.json().await?)
    }

    /// GET /api/v1/orchestrate/:task_id/progress
    pub async fn task_progress(&self, task_id: &str) -> Result<TaskProgress> {
        let resp = self
            .get(&format!("/api/v1/orchestrate/{}/progress", task_id))
            .await?;
        Ok(resp.json().await?)
    }

    /// GET /api/v1/orchestrate/tasks
    pub async fn list_tasks(&self) -> Result<Vec<OrchestratedTask>> {
        let resp = self.get("/api/v1/orchestrate/tasks").await?;
        let wrapper: serde_json::Value = resp.json().await?;
        let tasks: Vec<OrchestratedTask> =
            serde_json::from_value(wrapper.get("tasks").cloned().unwrap_or_default())?;
        Ok(tasks)
    }

    // -- Swarm --

    /// POST /api/v1/swarm/launch
    pub async fn launch_swarm(&self, req: &SwarmLaunchRequest) -> Result<SwarmLaunchResponse> {
        let resp = self.post("/api/v1/swarm/launch", req).await?;
        Ok(resp.json().await?)
    }

    /// GET /api/v1/swarm
    pub async fn list_swarms(&self) -> Result<SwarmListResponse> {
        let resp = self.get("/api/v1/swarm").await?;
        Ok(resp.json().await?)
    }

    /// GET /api/v1/swarm/:id
    pub async fn get_swarm(&self, swarm_id: &str) -> Result<SwarmStatus> {
        let resp = self.get(&format!("/api/v1/swarm/{}", swarm_id)).await?;
        Ok(resp.json().await?)
    }

    /// DELETE /api/v1/swarm/:id
    pub async fn cancel_swarm(&self, swarm_id: &str) -> Result<()> {
        let _ = self.delete(&format!("/api/v1/swarm/{}", swarm_id)).await?;
        Ok(())
    }

    // -- Memory --

    /// POST /api/v1/memory
    pub async fn save_memory(&self, req: &MemorySaveRequest) -> Result<MemorySaveResponse> {
        let resp = self.post("/api/v1/memory", req).await?;
        Ok(resp.json().await?)
    }

    /// GET /api/v1/memory/recall
    pub async fn recall_memory(&self) -> Result<MemoryRecallResponse> {
        let resp = self.get("/api/v1/memory/recall").await?;
        Ok(resp.json().await?)
    }

    // -- Analytics --

    /// GET /api/v1/analytics
    pub async fn analytics(&self) -> Result<AnalyticsResponse> {
        let resp = self.get("/api/v1/analytics").await?;
        Ok(resp.json().await?)
    }

    // -- Scheduler --

    /// GET /api/v1/scheduler/jobs
    pub async fn list_scheduler_jobs(&self) -> Result<Vec<SchedulerJob>> {
        let resp = self.get("/api/v1/scheduler/jobs").await?;
        let wrapper: serde_json::Value = resp.json().await?;
        let jobs: Vec<SchedulerJob> =
            serde_json::from_value(wrapper.get("jobs").cloned().unwrap_or_default())?;
        Ok(jobs)
    }

    /// POST /api/v1/scheduler/reload
    pub async fn reload_scheduler(&self) -> Result<()> {
        let _ = self
            .post("/api/v1/scheduler/reload", &serde_json::json!({}))
            .await?;
        Ok(())
    }

    // -- Machines --

    /// GET /api/v1/machines
    pub async fn list_machines(&self) -> Result<Vec<MachineInfo>> {
        let resp = self.get("/api/v1/machines").await?;
        let wrapper: serde_json::Value = resp.json().await?;
        let machines: Vec<MachineInfo> =
            serde_json::from_value(wrapper.get("machines").cloned().unwrap_or_default())?;
        Ok(machines)
    }

    // -- Session mutations --

    /// PUT /api/v1/sessions/:id
    pub async fn rename_session(&self, id: &str, title: &str) -> Result<()> {
        let body = serde_json::json!({ "title": title });
        let _ = self.put(&format!("/api/v1/sessions/{}", id), &body).await?;
        Ok(())
    }

    /// DELETE /api/v1/sessions/:id
    pub async fn delete_session(&self, id: &str) -> Result<()> {
        let _ = self.delete(&format!("/api/v1/sessions/{}", id)).await?;
        Ok(())
    }

    /// DELETE /api/v1/agents/:id — terminate a running (background) agent session.
    pub async fn cancel_agent(&self, id: &str) -> Result<()> {
        let _ = self.delete(&format!("/api/v1/agents/{}", id)).await?;
        Ok(())
    }

    /// GET /api/v1/runs/:id/transcript — full sidechain transcript for a
    /// subagent run (nested Ctrl+O expansion / dashboard view).
    pub async fn agent_transcript(&self, id: &str) -> Result<String> {
        let resp = self.get(&format!("/api/v1/runs/{}/transcript", id)).await?;
        let v: serde_json::Value = resp.json().await?;
        match v.get("transcript").and_then(|t| t.as_str()) {
            Some(t) => Ok(t.to_string()),
            None => {
                let msg = v
                    .get("message")
                    .and_then(|m| m.as_str())
                    .unwrap_or("no transcript for this agent");
                Err(anyhow::anyhow!("{}", msg))
            }
        }
    }

    /// POST /api/v1/sessions/:id/cancel — cancel a running agent loop.
    pub async fn cancel_session(&self, id: &str) -> Result<()> {
        let _ = self
            .post(
                &format!("/api/v1/sessions/{}/cancel", id),
                &serde_json::json!({}),
            )
            .await?;
        Ok(())
    }

    /// POST /api/v1/sessions/:id/detach-shell — promote the foreground shell
    /// command currently running in this session to a supervised background task
    /// (TUI Ctrl+B mid-run). Returns the new background_id on success; errors
    /// (e.g. 404 no_active_command) surface as `Err` for the caller to toast.
    pub async fn detach_shell(&self, id: &str) -> Result<String> {
        let resp = self
            .post(
                &format!("/api/v1/sessions/{}/detach-shell", id),
                &serde_json::json!({}),
            )
            .await?;

        #[derive(serde::Deserialize)]
        struct Resp {
            #[serde(default)]
            background_id: String,
        }

        let parsed: Resp = resp.json().await?;
        Ok(parsed.background_id)
    }

    /// POST /api/v1/sessions/:id/steer — inject a mid-turn steer directive into
    /// a RUNNING turn (primitive #32). The backend folds the text into the live
    /// ReAct loop at its next step boundary so the agent adapts without the turn
    /// being cancelled and in-flight work lost.
    pub async fn steer_session(&self, id: &str, text: &str) -> Result<()> {
        let _ = self
            .post(
                &format!("/api/v1/sessions/{}/steer", id),
                &serde_json::json!({ "text": text }),
            )
            .await?;
        Ok(())
    }

    // -- Survey --

    /// POST /api/v1/sessions/:id/survey/answer
    pub async fn submit_survey_answer(
        &self,
        session_id: &str,
        request: crate::client::types::SurveyAnswerRequest,
    ) -> Result<()> {
        let _ = self
            .post(
                &format!("/api/v1/sessions/{}/survey/answer", session_id),
                &request,
            )
            .await?;
        Ok(())
    }

    /// POST /api/v1/sessions/:id/survey/skip
    pub async fn skip_survey(
        &self,
        session_id: &str,
        survey_id: &str,
    ) -> Result<()> {
        let body = serde_json::json!({ "survey_id": survey_id });
        let _ = self
            .post(
                &format!("/api/v1/sessions/{}/survey/skip", session_id),
                &body,
            )
            .await?;
        Ok(())
    }

    // -- Onboarding --

    /// GET /onboarding/status
    pub async fn onboarding_status(&self) -> Result<OnboardingStatusResponse> {
        let resp = self.get_no_auth("/onboarding/status").await?;
        Ok(resp.json().await?)
    }

    /// GET /onboarding/models?provider=X&base_url=Y&api_key=Z
    pub async fn onboarding_models(
        &self,
        provider: &str,
        base_url: Option<&str>,
        api_key: Option<&str>,
    ) -> Result<OnboardingModelsResponse> {
        let mut url = format!("/onboarding/models?provider={}", provider);
        if let Some(bu) = base_url {
            url.push_str(&format!("&base_url={}", Self::percent_encode(bu)));
        }
        if let Some(ak) = api_key {
            url.push_str(&format!("&api_key={}", Self::percent_encode(ak)));
        }
        // Authenticated `get`, not `get_no_auth`. The backend strips
        // caller-supplied `base_url`/`api_key` from an unauthenticated caller
        // (SSRF surface) and honours them from an authenticated one — the
        // picker's whole purpose is passing a CANDIDATE endpoint, so sending
        // the token is the difference between listing the models the user is
        // about to configure and listing the ones they already have.
        // `get` attaches a Bearer only when a token exists, so first-run
        // onboarding (no token yet) is unchanged.
        let resp = self.get(&url).await?;
        Ok(resp.json().await?)
    }

    // -- Account sign-in (Auth.LoginBroker) --

    /// POST /auth/login/start — begin, or re-attach to, a provider sign-in.
    ///
    /// Returns immediately with a session handle. A device-code provider comes
    /// back `pending` with the code to render; a verification-style provider
    /// is often already `connected`. The caller polls either way, which is
    /// what lets the TUI have one sign-in screen instead of one per provider.
    pub async fn auth_login_start(&self, provider: &str) -> Result<LoginSessionResponse> {
        let body = serde_json::json!({ "provider": provider });
        let resp = self.post("/auth/login/start", &body).await?;
        Ok(resp.json().await?)
    }

    /// GET /auth/login/status/:id
    pub async fn auth_login_status(&self, id: &str) -> Result<LoginSessionResponse> {
        let resp = self
            .get(&format!("/auth/login/status/{}", Self::percent_encode(id)))
            .await?;
        Ok(resp.json().await?)
    }

    /// GET /auth/cli/claude — what to install, what to run, and who is signed in.
    ///
    /// One call rather than four, because a screen that makes four separate
    /// decisions about the same binary makes them at four different instants
    /// and can end up describing a state that never existed.
    pub async fn claude_cli_state(&self) -> Result<ClaudeCliState> {
        let resp = self.get("/auth/cli/claude").await?;
        Ok(resp.json().await?)
    }

    /// GET /usage/quota — the last quota window each provider reported.
    ///
    /// A provider absent from the map has reported nothing yet. That absence
    /// is the payload's way of forbidding a zero: there is no field to default.
    pub async fn usage_quota(&self) -> Result<UsageQuotaResponse> {
        let resp = self.get("/usage/quota").await?;
        Ok(resp.json().await?)
    }

    /// GET /auth/status — a pure read of every sign-in-capable provider.
    pub async fn auth_status(&self) -> Result<AuthStatusResponse> {
        let resp = self.get("/auth/status").await?;
        Ok(resp.json().await?)
    }

    /// POST /auth/login/cancel
    pub async fn auth_login_cancel(&self, id: &str) -> Result<()> {
        let body = serde_json::json!({ "session_id": id });
        let _ = self.post("/auth/login/cancel", &body).await?;
        Ok(())
    }

    /// POST /onboarding/health-check
    ///
    /// Read-only probe (no backend state mutation — see
    /// `Onboarding.health_check/1`), so it is safe to retry on a transient
    /// transport failure the same way idempotent GETs already are. Without
    /// this, a one-off stale-socket/ECONNRESET hiccup on the TUI<->local
    /// backend hop surfaced raw as "error sending request for url" on the
    /// onboarding "Verifying connection" screen with no retry at all, even
    /// though every GET on this same client already gets 2 free retries via
    /// `send_retry`.
    pub async fn onboarding_health_check(
        &self,
        req: &serde_json::Value,
    ) -> Result<OnboardingHealthCheckResponse> {
        let url = format!("{}/onboarding/health-check", self.base_url);
        let resp = self.send_retry_body(self.http.post(&url).json(req)).await?;
        Ok(resp.json().await?)
    }

    /// POST /onboarding/health-check WITH auth (post-onboarding candidate-key
    /// verification). The backend only honours caller-supplied api_key/base_url
    /// for authenticated callers once setup is complete.
    ///
    /// Same retry rationale as `onboarding_health_check` above — this is the
    /// in-app "verify key" path (model picker), an equally read-only probe.
    pub async fn onboarding_health_check_auth(
        &self,
        req: &serde_json::Value,
    ) -> Result<OnboardingHealthCheckResponse> {
        // Note: the endpoint returns HTTP 200 even on provider errors, so we
        // must not rely on `post`'s status check — use a raw authenticated POST.
        let url = format!("{}/onboarding/health-check", self.base_url);
        let mut req_builder = self.http.post(&url).json(req);
        if let Ok(token) = self.auth.read().await.require_token() {
            req_builder = req_builder.header("Authorization", format!("Bearer {}", token));
        }
        let resp = self.send_retry_body(req_builder).await?;
        Ok(resp.json().await?)
    }

    /// POST /onboarding/setup
    pub async fn onboarding_setup(
        &self,
        req: &OnboardingSetupRequest,
    ) -> Result<OnboardingSetupResponse> {
        let resp = self.post_no_auth("/onboarding/setup", req).await?;
        // A retried POST that lands after the write already succeeded returns 409
        // (setup_already_complete). That is success from the user's point of view,
        // so report it as such using the choices we just sent, rather than trying
        // to decode the 409 body into a setup response and surfacing a spurious
        // "error decoding response body" on what was actually a completed setup.
        if resp.status() == reqwest::StatusCode::CONFLICT {
            return Ok(OnboardingSetupResponse {
                status: "ok".to_string(),
                provider: Some(req.provider.clone()),
                model: Some(req.model.clone()),
            });
        }
        Ok(resp.json().await?)
    }

    /// POST /api/v1/providers/key — the authenticated single save path for the
    /// in-UI picker. Merges into ~/.osa/.env so keys accumulate and persist.
    pub async fn providers_save_key(
        &self,
        provider: &str,
        api_key: Option<&str>,
        base_url: Option<&str>,
        model: Option<&str>,
        set_active: bool,
    ) -> Result<()> {
        let body = serde_json::json!({
            "provider": provider,
            "api_key": api_key,
            "base_url": base_url,
            "model": model,
            "set_active": set_active,
        });
        // Idempotent config write (merges the key into ~/.osa/.env), so retry
        // transient transport failures the same way the onboarding-path POSTs
        // do, rather than surfacing a stale-socket blip as a raw error. Scoped
        // here on purpose: the shared `post` helper stays un-retried so it can
        // keep guarding non-idempotent mutating endpoints.
        let url = format!("{}/api/v1/providers/key", self.base_url);
        let mut req = self.http.post(&url).json(&body);
        if let Ok(token) = self.auth.read().await.require_token() {
            req = req.header("Authorization", format!("Bearer {}", token));
        }
        let resp = self.send_retry_body(req).await?;
        if !resp.status().is_success() {
            let status = resp.status();
            let text = resp.text().await.unwrap_or_default();
            anyhow::bail!("HTTP {} from /api/v1/providers/key: {}", status, text);
        }
        Ok(())
    }

    // -- Permissions --

    /// POST /api/v1/permissions/respond — resume the parked tool call with the
    /// user's decision. `decision` must be one of the backend's canonical
    /// strings (tool_routes.ex → PermissionBroker.canonical/1): `allow_once`,
    /// `allow_session`, `allow_always`, `deny`, `deny_always`, `clarify`;
    /// `note` carries clarify/steer text. `request_id` is the opaque id carried on the
    /// `permission_required` SSE event; the backend uses it to release the exact
    /// call the agent loop is blocked on.
    ///
    /// A missing/unreachable endpoint is tolerated (the decision is best-effort)
    /// so an older backend never wedges the UI, but transport-level failures are
    /// still logged by the caller when it cares about the result.
    pub async fn permission_respond(
        &self,
        request_id: &str,
        decision: &str,
        note: Option<&str>,
    ) -> Result<()> {
        let body = serde_json::json!({
            "request_id": request_id,
            "decision": decision,
            "note": note,
        });
        match self.post("/api/v1/permissions/respond", &body).await {
            Ok(_) => Ok(()),
            Err(e) => {
                tracing::warn!("permission respond failed (best-effort): {}", e);
                Ok(())
            }
        }
    }


    // =========================================================================
    // Local config store (~/.osa/.env)
    // =========================================================================

    /// Absolute path to the profile's `.env` config store.
    pub fn env_path(&self) -> PathBuf {
        self.profile_dir.join(".env")
    }

    /// Read `~/.osa/.env` into a KEY=VALUE map. Missing file → empty map. Lines
    /// that are blank, comments (`#`), or lack an `=` are skipped. A leading
    /// `export ` prefix and surrounding quotes on the value are stripped.
    pub fn read_env_map(&self) -> std::collections::HashMap<String, String> {
        let mut map = std::collections::HashMap::new();
        let path = self.env_path();
        let Ok(contents) = std::fs::read_to_string(&path) else {
            return map;
        };
        for line in contents.lines() {
            let trimmed = line.trim();
            if trimmed.is_empty() || trimmed.starts_with('#') {
                continue;
            }
            let trimmed = trimmed.strip_prefix("export ").unwrap_or(trimmed);
            if let Some((k, v)) = trimmed.split_once('=') {
                let key = k.trim().to_string();
                let val = v
                    .trim()
                    .trim_matches('"')
                    .trim_matches('\'')
                    .to_string();
                if !key.is_empty() {
                    map.insert(key, val);
                }
            }
        }
        map
    }

    /// Read a single value from `~/.osa/.env`.
    pub fn read_env_var(&self, key: &str) -> Option<String> {
        self.read_env_map().get(key).cloned()
    }

    /// Merge a single KEY=VALUE into `~/.osa/.env`, preserving other lines,
    /// comments, and ordering. Rewrites the matching key in place if present,
    /// otherwise appends it. Creates the file (and profile dir) if needed.
    pub fn set_env_var(&self, key: &str, value: &str) -> Result<()> {
        std::fs::create_dir_all(&self.profile_dir)?;
        let path = self.env_path();
        let existing = std::fs::read_to_string(&path).unwrap_or_default();

        let mut out: Vec<String> = Vec::new();
        let mut replaced = false;
        for line in existing.lines() {
            let trimmed = line.trim_start();
            let body = trimmed.strip_prefix("export ").unwrap_or(trimmed);
            let matches_key = body
                .split_once('=')
                .map(|(k, _)| k.trim() == key)
                .unwrap_or(false);
            if matches_key && !trimmed.starts_with('#') {
                out.push(format!("{}={}", key, value));
                replaced = true;
            } else {
                out.push(line.to_string());
            }
        }
        if !replaced {
            out.push(format!("{}={}", key, value));
        }
        let mut data = out.join("\n");
        data.push('\n');
        std::fs::write(&path, data)?;
        Ok(())
    }

    // =========================================================================
    // HTTP helpers
    // =========================================================================

    /// Send an idempotent request, retrying on transport-level failures that
    /// indicate a stale pooled socket — Claude Code's `isStaleConnectionError`
    /// -> disableKeepAlive -> fresh-client pattern (withRetry.ts / proxy.ts),
    /// and the same class fetchTelemetry.ts classifies as retryable
    /// (ECONNRESET / "connection closed before message completed").
    ///
    /// reqwest evicts the dead socket on the failed send, so every retry opens a
    /// FRESH TCP connection. We retry only `is_connect()` / `is_request()`
    /// errors and explicitly EXCLUDE `is_timeout()` — a timeout means the real
    /// 300s budget was exhausted and must not be silently multiplied. HTTP
    /// status errors are never seen here (a completed send returns `Ok(resp)`);
    /// the caller handles status. Only for idempotent, bodyless GETs, so a
    /// retry can never double-submit a mutation and `try_clone()` always
    /// succeeds. Max 3 attempts with a short 120ms/240ms backoff so the UI
    /// never hangs.
    async fn send_retry(
        &self,
        req_builder: reqwest::RequestBuilder,
    ) -> Result<reqwest::Response> {
        let mut attempt: u32 = 0;
        loop {
            let rb = req_builder
                .try_clone()
                .expect("idempotent GET has a cloneable (bodyless) request");
            match rb.send().await {
                Ok(resp) => return Ok(resp),
                Err(e)
                    if attempt < 2
                        && !e.is_timeout()
                        && (e.is_connect() || e.is_request()) =>
                {
                    attempt += 1;
                    debug!(
                        "transport error (stale socket?), retry {}/2: {}",
                        attempt, e
                    );
                    tokio::time::sleep(Duration::from_millis(120 * attempt as u64)).await;
                    continue;
                }
                Err(e) => return Err(e.into()),
            }
        }
    }

    /// Same transport-error retry as `send_retry`, but for a request that may
    /// carry a body (used only for genuinely idempotent, side-effect-free
    /// POSTs, e.g. the onboarding health-check probe). `.json(&body)` always
    /// produces a fully-buffered `Bytes` body, so `try_clone()` succeeds; if
    /// it somehow doesn't (defensive — never observed in practice), fall
    /// back to a single un-retried send instead of panicking, since a
    /// missed retry is far preferable to crashing the TUI.
    async fn send_retry_body(
        &self,
        req_builder: reqwest::RequestBuilder,
    ) -> Result<reqwest::Response> {
        let mut attempt: u32 = 0;
        let mut pending = req_builder;
        loop {
            // Snapshot a clone to retry with before consuming `pending` in
            // `.send()`. If the body can't be cloned, send as-is with no
            // retry rather than panicking.
            let retry_clone = pending.try_clone();
            match pending.send().await {
                Ok(resp) => return Ok(resp),
                Err(e)
                    if attempt < 2
                        && !e.is_timeout()
                        && (e.is_connect() || e.is_request()) =>
                {
                    let Some(next) = retry_clone else {
                        return Err(e.into());
                    };
                    attempt += 1;
                    debug!(
                        "transport error on POST (stale socket?), retry {}/2: {}",
                        attempt, e
                    );
                    tokio::time::sleep(Duration::from_millis(120 * attempt as u64)).await;
                    pending = next;
                    continue;
                }
                Err(e) => return Err(e.into()),
            }
        }
    }

    /// GET with auth header (auto-retries on 401 after token refresh).
    async fn get(&self, path: &str) -> Result<reqwest::Response> {
        let url = format!("{}{}", self.base_url, path);
        let mut req = self.http.get(&url);
        if let Ok(token) = self.auth.read().await.require_token() {
            req = req.header("Authorization", format!("Bearer {}", token));
        }
        let resp = self.send_retry(req).await?;

        // Auto-refresh on 401: try refresh_token, then retry unauthenticated
        if resp.status() == reqwest::StatusCode::UNAUTHORIZED {
            debug!("Got 401 from {}, attempting token refresh", path);

            if self.try_refresh_token().await {
                let mut retry_req = self.http.get(&url);
                if let Ok(token) = self.auth.read().await.require_token() {
                    retry_req = retry_req.header("Authorization", format!("Bearer {}", token));
                }
                let retry_resp = retry_req.send().await?;
                if retry_resp.status().is_success() {
                    return Ok(retry_resp);
                }
            }

            // Refresh failed or retry still 401 — clear tokens and retry unauthenticated
            debug!("Token refresh failed, clearing tokens and retrying unauthenticated");
            auth::clear_tokens(&self.profile_dir);
            *self.auth.write().await = AuthState::Unauthenticated;

            let retry_resp = self.http.get(&url).send().await?;
            if !retry_resp.status().is_success() {
                let status = retry_resp.status();
                let body = retry_resp.text().await.unwrap_or_default();
                anyhow::bail!("HTTP {} from {}: {}", status, path, body);
            }
            return Ok(retry_resp);
        }

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            anyhow::bail!("HTTP {} from {}: {}", status, path, body);
        }
        Ok(resp)
    }

    /// Attempt to refresh the auth token using the refresh_token.
    pub async fn try_refresh_token(&self) -> bool {
        let refresh_token = {
            let auth = self.auth.read().await;
            match auth.refresh_token() {
                Some(rt) => rt.to_string(),
                None => return false,
            }
        };

        let url = format!("{}/api/v1/auth/refresh", self.base_url);
        // Retry transient transport blips (a stale pooled socket or brief reset)
        // so a network hiccup during refresh is not mistaken for a rejected token,
        // which would clear the session and log the user out on a passing blip.
        // Only a real HTTP response, or exhausted retries, decides success/failure.
        let resp = self
            .send_retry_body(
                self.http
                    .post(&url)
                    .json(&serde_json::json!({ "refresh_token": refresh_token })),
            )
            .await;

        match resp {
            Ok(r) if r.status().is_success() => {
                if let Ok(body) = r.json::<serde_json::Value>().await {
                    if let (Some(token), Some(refresh)) = (
                        body.get("token").and_then(|t| t.as_str()),
                        body.get("refresh_token").and_then(|t| t.as_str()),
                    ) {
                        let _ = auth::save_tokens(&self.profile_dir, token, refresh);
                        *self.auth.write().await = AuthState::Authenticated {
                            token: token.to_string(),
                            refresh_token: refresh.to_string(),
                        };
                        debug!("Token refreshed successfully");
                        return true;
                    }
                }
                false
            }
            _ => false,
        }
    }

    /// GET without auth header (for unauthenticated endpoints like /health).
    async fn get_no_auth(&self, path: &str) -> Result<reqwest::Response> {
        let url = format!("{}{}", self.base_url, path);
        let resp = self.send_retry(self.http.get(&url)).await?;
        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            anyhow::bail!("HTTP {} from {}: {}", status, path, body);
        }
        Ok(resp)
    }

    /// Simple percent-encoding for query parameter values.
    fn percent_encode(s: &str) -> String {
        let mut result = String::with_capacity(s.len());
        for byte in s.bytes() {
            match byte {
                b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                    result.push(byte as char);
                }
                _ => {
                    result.push_str(&format!("%{:02X}", byte));
                }
            }
        }
        result
    }

    /// POST JSON without auth (for onboarding endpoints before auth is
    /// configured — currently only `/onboarding/setup`, the final
    /// "save the wizard's choices" step).
    ///
    /// Same transport-error retry as the onboarding health-check probes
    /// (`send_retry_body`). Without this, a one-off stale-socket/ECONNRESET
    /// blip on this exact hop right after the health-check screen succeeds
    /// was fatal and un-retried, even though every GET and the health-check
    /// POSTs already get 2 free retries. `write_setup/1` on the backend is
    /// an idempotent upsert (writes the same config fields every time), so
    /// retrying a transport failure here can never double-apply or corrupt
    /// state — at worst a retry that lands after the first attempt actually
    /// succeeded hits the backend's `setup_already_complete` 409 guard,
    /// which is a harmless no-op from the caller's perspective.
    async fn post_no_auth<T: serde::Serialize>(
        &self,
        path: &str,
        body: &T,
    ) -> Result<reqwest::Response> {
        let url = format!("{}{}", self.base_url, path);
        let resp = self.send_retry_body(self.http.post(&url).json(body)).await?;
        Ok(resp)
    }

    /// POST JSON with auth header, returning the response WITHOUT bailing on a
    /// non-2xx status. Used for endpoints (like /onboarding/health-check) that
    /// signal provider-level failures in the JSON body while still replying 200.
    async fn post_allow_status<T: serde::Serialize>(
        &self,
        path: &str,
        body: &T,
    ) -> Result<reqwest::Response> {
        let url = format!("{}{}", self.base_url, path);
        let mut req = self.http.post(&url).json(body);
        if let Ok(token) = self.auth.read().await.require_token() {
            req = req.header("Authorization", format!("Bearer {}", token));
        }
        Ok(req.send().await?)
    }

    /// POST JSON with auth header.
    async fn post<T: serde::Serialize>(
        &self,
        path: &str,
        body: &T,
    ) -> Result<reqwest::Response> {
        self.post_with_timeout(path, body, None).await
    }

    /// POST JSON with auth header, for an endpoint that holds the connection
    /// open for a whole turn. See `TURN_TIMEOUT`.
    async fn post_turn<T: serde::Serialize>(
        &self,
        path: &str,
        body: &T,
    ) -> Result<reqwest::Response> {
        self.post_with_timeout(path, body, Some(TURN_TIMEOUT)).await
    }

    async fn post_with_timeout<T: serde::Serialize>(
        &self,
        path: &str,
        body: &T,
        timeout: Option<Duration>,
    ) -> Result<reqwest::Response> {
        let url = format!("{}{}", self.base_url, path);
        let mut req = self.http.post(&url).json(body);
        if let Some(t) = timeout {
            req = req.timeout(t);
        }
        if let Ok(token) = self.auth.read().await.require_token() {
            req = req.header("Authorization", format!("Bearer {}", token));
        }
        let resp = req.send().await?;
        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            anyhow::bail!("HTTP {} from {}: {}", status, path, body);
        }
        Ok(resp)
    }

    /// PUT JSON with auth header.
    async fn put<T: serde::Serialize>(
        &self,
        path: &str,
        body: &T,
    ) -> Result<reqwest::Response> {
        let url = format!("{}{}", self.base_url, path);
        let mut req = self.http.put(&url).json(body);
        if let Ok(token) = self.auth.read().await.require_token() {
            req = req.header("Authorization", format!("Bearer {}", token));
        }
        let resp = req.send().await?;
        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            anyhow::bail!("HTTP {} from {}: {}", status, path, body);
        }
        Ok(resp)
    }

    /// DELETE with auth header.
    async fn delete(&self, path: &str) -> Result<reqwest::Response> {
        let url = format!("{}{}", self.base_url, path);
        let mut req = self.http.delete(&url);
        if let Ok(token) = self.auth.read().await.require_token() {
            req = req.header("Authorization", format!("Bearer {}", token));
        }
        let resp = req.send().await?;
        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            anyhow::bail!("HTTP {} from {}: {}", status, path, body);
        }
        Ok(resp)
    }
}

#[cfg(test)]
mod health_check_retry_tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    fn make_client(base_url: String) -> ApiClient {
        let profile_dir = std::env::temp_dir().join(format!(
            "osa-tui-test-{}-{}",
            std::process::id(),
            rand_suffix()
        ));
        ApiClient::new(base_url, profile_dir).expect("client builds")
    }

    fn rand_suffix() -> u64 {
        use std::time::{SystemTime, UNIX_EPOCH};
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos() as u64
    }

    const VALID_HEALTH_RESPONSE: &str = "{\"status\":\"ok\",\"latency_ms\":5}";

    fn http_ok_response(body: &str) -> String {
        format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(),
            body
        )
    }

    /// Regression test for the "error sending request for url" onboarding
    /// bug: a POST /onboarding/health-check whose FIRST attempt hits a dead
    /// socket (server accepts the TCP connection then closes it without
    /// writing anything — the exact "connection closed before message
    /// completed" transport failure GETs were already immune to via
    /// `send_retry`) must now be transparently retried and succeed, instead
    /// of surfacing the raw transport error to the onboarding "Verifying
    /// connection" screen.
    #[tokio::test]
    async fn health_check_retries_past_a_dead_first_connection() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let base_url = format!("http://{}", addr);

        tokio::spawn(async move {
            // Connection #1: accept then drop immediately, no bytes written —
            // simulates a stale pooled socket the server already tore down.
            if let Ok((stream, _)) = listener.accept().await {
                drop(stream);
            }
            // Connection #2 (the retry): serve a real 200 with a valid body.
            if let Ok((mut stream, _)) = listener.accept().await {
                let mut buf = [0u8; 4096];
                let _ = stream.read(&mut buf).await;
                let _ = stream
                    .write_all(http_ok_response(VALID_HEALTH_RESPONSE).as_bytes())
                    .await;
                let _ = stream.shutdown().await;
            }
        });

        let client = make_client(base_url);
        let result = client
            .onboarding_health_check(&serde_json::json!({
                "provider": "custom",
                "base_url": "http://example.invalid",
                "api_key": "test"
            }))
            .await;

        assert!(
            result.is_ok(),
            "expected the dead first connection to be retried transparently, got: {:?}",
            result.err()
        );
        assert_eq!(result.unwrap().status, "ok");
    }

    /// Same regression coverage for the authenticated verify path used by
    /// the in-app model picker's "verify key" screen.
    #[tokio::test]
    async fn health_check_auth_retries_past_a_dead_first_connection() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let base_url = format!("http://{}", addr);

        tokio::spawn(async move {
            if let Ok((stream, _)) = listener.accept().await {
                drop(stream);
            }
            if let Ok((mut stream, _)) = listener.accept().await {
                let mut buf = [0u8; 4096];
                let _ = stream.read(&mut buf).await;
                let _ = stream
                    .write_all(http_ok_response(VALID_HEALTH_RESPONSE).as_bytes())
                    .await;
                let _ = stream.shutdown().await;
            }
        });

        let client = make_client(base_url);
        let result = client
            .onboarding_health_check_auth(&serde_json::json!({
                "provider": "custom",
                "base_url": "http://example.invalid",
                "api_key": "test"
            }))
            .await;

        assert!(
            result.is_ok(),
            "expected the dead first connection to be retried transparently, got: {:?}",
            result.err()
        );
        assert_eq!(result.unwrap().status, "ok");
    }

    /// Without a healthy connection ever available, the call must still
    /// fail cleanly (bounded retries, not an infinite loop) with the same
    /// transport-error shape users saw in production.
    #[tokio::test]
    async fn health_check_fails_cleanly_when_every_connection_is_dead() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let base_url = format!("http://{}", addr);

        tokio::spawn(async move {
            // Every connection attempt (initial + both retries) gets dropped.
            for _ in 0..3 {
                if let Ok((stream, _)) = listener.accept().await {
                    drop(stream);
                } else {
                    break;
                }
            }
        });

        let client = make_client(base_url);
        let result = client
            .onboarding_health_check(&serde_json::json!({
                "provider": "custom",
                "base_url": "http://example.invalid",
                "api_key": "test"
            }))
            .await;

        assert!(result.is_err(), "expected a transport error, got Ok");
    }

    const VALID_LOGIN_RESPONSE: &str =
        "{\"token\":\"tok-abc\",\"refresh_token\":\"ref-abc\",\"expires_in\":3600}";

    /// Regression test: `login()` runs immediately after the health check
    /// succeeds, on the same connection pool, so it is just as exposed to a
    /// stale-pooled-socket/ECONNRESET blip as the onboarding health-check
    /// POST was. Before this fix a dead first connection here was fatal —
    /// no retry — and dropped a fresh install straight into an empty Idle
    /// screen with SSE never started and onboarding never checked.
    #[tokio::test]
    async fn login_retries_past_a_dead_first_connection() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let base_url = format!("http://{}", addr);

        tokio::spawn(async move {
            if let Ok((stream, _)) = listener.accept().await {
                drop(stream);
            }
            if let Ok((mut stream, _)) = listener.accept().await {
                let mut buf = [0u8; 4096];
                let _ = stream.read(&mut buf).await;
                let _ = stream
                    .write_all(http_ok_response(VALID_LOGIN_RESPONSE).as_bytes())
                    .await;
                let _ = stream.shutdown().await;
            }
        });

        let client = make_client(base_url);
        let result = client.login(Some("local")).await;

        assert!(
            result.is_ok(),
            "expected the dead first connection to be retried transparently, got: {:?}",
            result.err()
        );
        assert_eq!(result.unwrap().token, "tok-abc");
    }

    const VALID_ONBOARDING_SETUP_RESPONSE: &str =
        "{\"status\":\"ok\",\"provider\":\"ollama_cloud\",\"model\":\"glm-5.2:cloud\"}";

    /// Regression test: the final "save the wizard's choices" POST
    /// (`/onboarding/setup`, via `post_no_auth`) had zero retry protection —
    /// the exact same bug class as the onboarding verify POST — even though
    /// the TUI already shows "Setup complete!" and drops the user into the
    /// Idle chat screen the instant this call is fired, so a transient
    /// failure here silently left the backend never actually configured.
    #[tokio::test]
    async fn onboarding_setup_retries_past_a_dead_first_connection() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let base_url = format!("http://{}", addr);

        tokio::spawn(async move {
            if let Ok((stream, _)) = listener.accept().await {
                drop(stream);
            }
            if let Ok((mut stream, _)) = listener.accept().await {
                let mut buf = [0u8; 4096];
                let _ = stream.read(&mut buf).await;
                let _ = stream
                    .write_all(http_ok_response(VALID_ONBOARDING_SETUP_RESPONSE).as_bytes())
                    .await;
                let _ = stream.shutdown().await;
            }
        });

        let client = make_client(base_url);
        let req = crate::client::types::OnboardingSetupRequest {
            provider: "ollama_cloud".to_string(),
            model: "glm-5.2:cloud".to_string(),
            api_key: None,
            base_url: None,
            channel_tokens: None,
            user_name: None,
            agent_name: None,
        };
        let result = client.onboarding_setup(&req).await;

        assert!(
            result.is_ok(),
            "expected the dead first connection to be retried transparently, got: {:?}",
            result.err()
        );
        assert_eq!(result.unwrap().status, "ok");
    }

    /// Without a healthy connection ever available, `/onboarding/setup` must
    /// still fail cleanly (bounded retries) rather than hang or panic.
    #[tokio::test]
    async fn onboarding_setup_fails_cleanly_when_every_connection_is_dead() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let base_url = format!("http://{}", addr);

        tokio::spawn(async move {
            for _ in 0..3 {
                if let Ok((stream, _)) = listener.accept().await {
                    drop(stream);
                } else {
                    break;
                }
            }
        });

        let client = make_client(base_url);
        let req = crate::client::types::OnboardingSetupRequest {
            provider: "ollama_cloud".to_string(),
            model: "glm-5.2:cloud".to_string(),
            api_key: None,
            base_url: None,
            channel_tokens: None,
            user_name: None,
            agent_name: None,
        };
        let result = client.onboarding_setup(&req).await;

        assert!(result.is_err(), "expected a transport error, got Ok");
    }

    /// Regression test: `/model` (and the model-picker "save key and switch"
    /// flow) must hit the SESSION-scoped `POST /sessions/:id/provider` route
    /// so the CURRENT live session's `Loop` GenServer actually picks up the
    /// new provider/model on its next turn. A prior version called the
    /// global-only `POST /models/switch`, which updated process-wide
    /// defaults but left an already-running session silently stuck on the
    /// old provider while the UI reported success.
    #[tokio::test]
    async fn switch_session_model_posts_to_the_session_scoped_route() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let base_url = format!("http://{}", addr);

        let (line_tx, line_rx) = tokio::sync::oneshot::channel();
        tokio::spawn(async move {
            if let Ok((mut stream, _)) = listener.accept().await {
                let mut buf = [0u8; 4096];
                let n = stream.read(&mut buf).await.unwrap_or(0);
                let request = String::from_utf8_lossy(&buf[..n]).to_string();
                let request_line = request.lines().next().unwrap_or("").to_string();
                let _ = line_tx.send(request_line);

                let body = "{\"status\":\"ok\",\"provider\":\"ollama\",\"model\":\"qwen3:8b\",\"context_window\":32000}";
                let _ = stream.write_all(http_ok_response(body).as_bytes()).await;
                let _ = stream.shutdown().await;
            }
        });

        let client = make_client(base_url);
        let req = crate::client::types::ModelSwitchRequest {
            provider: "ollama".to_string(),
            model: "qwen3:8b".to_string(),
        };
        let result = client.switch_session_model("session-abc-123", &req).await;

        assert!(result.is_ok(), "expected Ok, got: {:?}", result.err());
        let resp = result.unwrap();
        assert_eq!(resp.provider, "ollama");
        assert_eq!(resp.model, "qwen3:8b");

        let request_line = line_rx.await.expect("server observed a request");
        assert_eq!(
            request_line, "POST /api/v1/sessions/session-abc-123/provider HTTP/1.1",
            "switch_session_model must hit the session-scoped route, not the global /models/switch"
        );
    }

    /// Serve one request with an arbitrary status + JSON body, reporting the
    /// request line the client actually sent.
    async fn serve_once(status_line: &'static str, body: &'static str) -> (String, tokio::sync::oneshot::Receiver<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let base_url = format!("http://{}", addr);
        let (line_tx, line_rx) = tokio::sync::oneshot::channel::<String>();
        tokio::spawn(async move {
            if let Ok((mut stream, _)) = listener.accept().await {
                let mut buf = [0u8; 4096];
                let n = stream.read(&mut buf).await.unwrap_or(0);
                let request = String::from_utf8_lossy(&buf[..n]).to_string();
                let _ = line_tx.send(request.lines().next().unwrap_or("").to_string());
                let resp = format!(
                    "HTTP/1.1 {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    status_line,
                    body.len(),
                    body
                );
                let _ = stream.write_all(resp.as_bytes()).await;
                let _ = stream.shutdown().await;
            }
        });
        (base_url, line_rx)
    }

    // === `osa resume <id>` resolution ===

    #[tokio::test]
    async fn resolve_session_returns_the_full_id_and_hits_the_resolve_route() {
        let (base_url, line_rx) =
            serve_once("200 OK", "{\"id\":\"session-1785-abcdef\",\"ref\":\"session-1785\"}").await;
        let client = make_client(base_url);

        let resolved = client.resolve_session("session-1785").await;
        assert_eq!(resolved.unwrap(), "session-1785-abcdef");

        let line = line_rx.await.expect("server observed a request");
        assert_eq!(line, "GET /api/v1/sessions/resolve?id=session-1785 HTTP/1.1");
    }

    #[tokio::test]
    async fn resolve_session_fails_loudly_on_an_unknown_id() {
        // THE regression this endpoint exists for: a 404 must surface as an
        // Err carrying the backend's explanation, never as an empty session.
        let (base_url, _rx) = serve_once(
            "404 Not Found",
            "{\"error\":\"session_not_found\",\"details\":\"No session matches \\\"nope\\\".\"}",
        )
        .await;
        let client = make_client(base_url);

        let err = client.resolve_session("nope").await.unwrap_err();
        assert!(err.to_string().contains("No session matches"), "got: {}", err);
    }

    #[tokio::test]
    async fn resolve_session_fails_loudly_on_an_ambiguous_prefix() {
        let (base_url, _rx) = serve_once(
            "409 Conflict",
            "{\"error\":\"session_ref_ambiguous\",\"details\":\"matches 2 sessions. Use more characters.\",\"candidates\":[\"a\",\"b\"]}",
        )
        .await;
        let client = make_client(base_url);

        let err = client.resolve_session("ses").await.unwrap_err();
        assert!(err.to_string().contains("Use more characters"), "got: {}", err);
    }

    #[tokio::test]
    async fn resolve_session_rejects_a_200_with_no_id() {
        // A contract break must not degrade into switching to an empty-string
        // session id, which would look exactly like a fresh conversation.
        let (base_url, _rx) = serve_once("200 OK", "{\"ref\":\"x\"}").await;
        let client = make_client(base_url);
        assert!(client.resolve_session("x").await.is_err());
    }

    #[test]
    fn error_details_are_unwrapped_for_the_user() {
        assert_eq!(
            extract_error_details(
                r#"HTTP 404 Not Found from /api/v1/sessions/resolve?id=x: {"error":"session_not_found","details":"No session matches \"x\"."}"#
            ),
            r#"No session matches "x"."#
        );
    }

    #[test]
    fn error_details_pass_through_when_there_is_nothing_to_unwrap() {
        assert_eq!(extract_error_details("connection refused"), "connection refused");
        // Valid JSON with no details field: keep the full context.
        let raw = r#"HTTP 500 from /x: {"error":"boom"}"#;
        assert_eq!(extract_error_details(raw), raw);
        // Not JSON at all after the brace: keep the full context.
        let raw = "HTTP 502 from /x: {not json";
        assert_eq!(extract_error_details(raw), raw);
    }

    #[test]
    fn query_encoding_escapes_everything_that_could_restructure_the_url() {
        assert_eq!(percent_encode_query("session-1785_abc.def~x"), "session-1785_abc.def~x");
        assert_eq!(percent_encode_query("a&b=c"), "a%26b%3Dc");
        assert_eq!(percent_encode_query("a b"), "a%20b");
        assert_eq!(percent_encode_query("a#b"), "a%23b");
    }
}
