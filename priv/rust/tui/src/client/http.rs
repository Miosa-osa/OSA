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

pub struct ApiClient {
    http: HttpClient,
    base_url: String,
    auth: Arc<RwLock<AuthState>>,
    pub(crate) profile_dir: PathBuf,
}

impl ApiClient {
    pub fn new(base_url: String, profile_dir: PathBuf) -> Result<Self> {
        let http = HttpClient::builder().timeout(DEFAULT_TIMEOUT).build()?;

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
    pub async fn login(&self, user_id: Option<&str>) -> Result<LoginResponse> {
        let body = LoginRequest {
            user_id: user_id.map(|s| s.to_string()),
        };
        let url = format!("{}/api/v1/auth/login", self.base_url);
        let resp = self.http.post(&url).json(&body).send().await?;
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
        let resp = self.post("/api/v1/orchestrate", req).await?;
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

    /// GET /api/v1/sessions/:id
    pub async fn get_session(&self, id: &str) -> Result<SessionInfo> {
        let resp = self.get(&format!("/api/v1/sessions/{}", id)).await?;
        Ok(resp.json().await?)
    }

    /// GET /api/v1/sessions/:id/messages
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

    /// POST /api/v1/models/switch
    pub async fn switch_model(&self, req: &ModelSwitchRequest) -> Result<ModelSwitchResponse> {
        let resp = self.post("/api/v1/models/switch", req).await?;
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
        let resp = self.post("/api/v1/orchestrate/complex", req).await?;
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
        let resp = self.get_no_auth(&url).await?;
        Ok(resp.json().await?)
    }

    /// POST /onboarding/health-check
    pub async fn onboarding_health_check(
        &self,
        req: &serde_json::Value,
    ) -> Result<OnboardingHealthCheckResponse> {
        let resp = self.post_no_auth("/onboarding/health-check", req).await?;
        Ok(resp.json().await?)
    }

    /// POST /onboarding/setup
    pub async fn onboarding_setup(
        &self,
        req: &OnboardingSetupRequest,
    ) -> Result<OnboardingSetupResponse> {
        let resp = self.post_no_auth("/onboarding/setup", req).await?;
        Ok(resp.json().await?)
    }

    // -- Permissions --

    /// POST /api/v1/permissions/respond — send Allow/Deny decision back to backend.
    ///
    /// TODO: backend endpoint `/api/v1/permissions/respond` does not yet exist.
    /// This sends the correct payload; wire backend when the route is implemented.
    pub async fn permission_response(&self, request_id: &str, allowed: bool) -> Result<()> {
        let body = serde_json::json!({
            "request_id": request_id,
            "allowed": allowed,
        });
        // Best-effort: ignore errors if the backend endpoint isn't yet present.
        let _ = self.post("/api/v1/permissions/respond", &body).await;
        Ok(())
    }

    // =========================================================================
    // HTTP helpers
    // =========================================================================

    /// GET with auth header (auto-retries on 401 after token refresh).
    async fn get(&self, path: &str) -> Result<reqwest::Response> {
        let url = format!("{}{}", self.base_url, path);
        let mut req = self.http.get(&url);
        if let Ok(token) = self.auth.read().await.require_token() {
            req = req.header("Authorization", format!("Bearer {}", token));
        }
        let resp = req.send().await?;

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
        let resp = self.http
            .post(&url)
            .json(&serde_json::json!({ "refresh_token": refresh_token }))
            .send()
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
        let resp = self.http.get(&url).send().await?;
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

    /// POST JSON without auth (for onboarding endpoints before auth is configured).
    async fn post_no_auth<T: serde::Serialize>(
        &self,
        path: &str,
        body: &T,
    ) -> Result<reqwest::Response> {
        let url = format!("{}{}", self.base_url, path);
        let resp = self.http.post(&url).json(body).send().await?;
        Ok(resp)
    }

    /// POST JSON with auth header.
    async fn post<T: serde::Serialize>(
        &self,
        path: &str,
        body: &T,
    ) -> Result<reqwest::Response> {
        let url = format!("{}{}", self.base_url, path);
        let mut req = self.http.post(&url).json(body);
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
