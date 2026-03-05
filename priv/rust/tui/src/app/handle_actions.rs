use crate::app::state::AppState;
use crate::event::backend::BackendEvent;
use crate::event::Event;
use tracing::{debug, error, info, warn};

use super::App;

impl App {
    pub(super) fn handle_health_result(
        &mut self,
        result: Result<crate::client::types::HealthResponse, String>,
    ) {
        match result {
            Ok(health) => {
                info!(
                    "Backend healthy: {} v{} ({}/{})",
                    health.status, health.version, health.provider, health.model
                );
                self.header
                    .set_provider_info(&health.provider, &health.model);
                self.status
                    .set_provider_info(&health.provider, &health.model);
                self.sidebar
                    .set_provider_info(&health.provider, &health.model);
                self.chat.set_welcome_info(
                    &health.provider,
                    &health.model,
                    self.header.tool_count(),
                );
                // Skip banner — go straight to Idle (no jarring screen switch)
                self.transition(AppState::Idle);

                // Start auth + SSE
                self.do_login();
            }
            Err(e) => {
                self.health_retry_count += 1;
                warn!("Health check failed (attempt {}): {}", self.health_retry_count, e);

                // Auto-start backend on first failure
                if !self.backend_spawn_attempted {
                    self.backend_spawn_attempted = true;
                    self.try_spawn_backend();
                }

                // Give up after 12 retries (60s total)
                if self.health_retry_count >= 12 {
                    error!("Backend unreachable after {} attempts", self.health_retry_count);
                    self.transition(AppState::Idle);
                    self.toasts.push(
                        "Backend unreachable — start it manually or check config".into(),
                        crate::components::toast::ToastLevel::Error,
                    );
                    return;
                }

                // Retry after delay
                let tx = self.event_tx.clone();
                tokio::spawn(async move {
                    tokio::time::sleep(super::HEALTH_RETRY_DELAY).await;
                    let _ = tx.send(Event::HealthRetry);
                });
            }
        }
    }

    pub(super) fn handle_login_result(
        &mut self,
        result: Result<crate::client::types::LoginResponse, String>,
    ) {
        match result {
            Ok(_) => {
                info!("Login successful");
                // Load commands and tools in parallel
                self.load_commands();
                self.load_tools();
                // Start SSE
                self.start_sse();
                // Check if onboarding is needed
                self.check_onboarding();
            }
            Err(e) => {
                warn!("Login failed: {}", e);
                self.toasts.push(
                    format!("Login failed: {}", e),
                    crate::components::toast::ToastLevel::Error,
                );
            }
        }
    }

    pub(crate) fn check_onboarding(&self) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        tokio::spawn(async move {
            match client.onboarding_status().await {
                Ok(resp) => {
                    let _ = tx.send(Event::Backend(BackendEvent::OnboardingStatus(Ok(resp))));
                }
                Err(e) => {
                    let _ = tx.send(Event::Backend(BackendEvent::OnboardingStatus(Err(e.to_string()))));
                }
            }
        });
    }

    pub(super) fn handle_agent_response(
        &mut self,
        response: String,
        signal: Option<crate::client::types::Signal>,
    ) {
        // Truncate if too long
        let display_response = if response.len() > super::MAX_MESSAGE_SIZE {
            let truncated = &response[..super::MAX_MESSAGE_SIZE];
            format!(
                "{}\n\n... (response truncated at {}KB)",
                truncated,
                super::MAX_MESSAGE_SIZE / 1000
            )
        } else {
            response
        };

        self.chat.clear_streaming();
        self.chat
            .add_agent_message(&display_response, signal.as_ref());

        // Clear streaming state
        self.stream_buf.clear();
        self.thinking_buf.clear();
        self.thinking_box.clear();
        self.activity.stop();
        self.status.set_active(false);
        self.cancelled = false;

        // Transition back to idle
        if self.state.is_processing() {
            self.transition(AppState::Idle);
        }

        // Update signal in status bar
        if let Some(signal) = signal {
            self.status.set_signal(signal);
        }

        self.recompute_layout();
    }

    pub(super) fn handle_command_result(
        &mut self,
        result: Result<crate::client::types::CommandExecuteResponse, String>,
    ) {
        match result {
            Ok(resp) => {
                match resp.kind.as_str() {
                    "error" => {
                        self.chat
                            .add_system_message(&resp.output, "error");
                    }
                    "prompt" => {
                        // Feed output back as prompt
                        self.submit_prompt(&resp.output);
                    }
                    "action" => {
                        if let Some(action) = resp.action {
                            self.handle_command_action(&action);
                        }
                    }
                    _ => {
                        if !resp.output.is_empty() {
                            self.chat
                                .add_system_message(&resp.output, "info");
                        }
                    }
                }
            }
            Err(e) => {
                self.toasts.push(
                    format!("Command error: {}", e),
                    crate::components::toast::ToastLevel::Error,
                );
            }
        }

        if self.state.is_processing() {
            self.transition(AppState::Idle);
            self.activity.stop();
            self.status.set_active(false);
        }
    }

    fn handle_command_action(&mut self, action: &str) {
        match action {
            ":new_session" => self.create_session(),
            ":clear" => {
                self.chat.clear();
                self.tasks.clear();
            }
            _ => {
                debug!("Unhandled command action: {}", action);
            }
        }
    }

    pub fn submit_input(&mut self, text: &str) {
        let text = text.trim();
        if text.is_empty() {
            return;
        }

        if text.starts_with('/') {
            self.handle_command(text);
        } else if let Some(shell_cmd) = text.strip_prefix('!') {
            self.execute_shell(shell_cmd.trim());
        } else {
            self.submit_prompt(text);
        }
    }

    fn execute_shell(&mut self, cmd: &str) {
        if cmd.is_empty() {
            self.toasts.push(
                "Usage: !<command>".into(),
                crate::components::toast::ToastLevel::Warning,
            );
            return;
        }

        self.chat.add_system_message(&format!("$ {}", cmd), "shell");
        self.transition(AppState::Processing);
        self.activity.start();
        self.status.set_active(true);
        self.processing_start = Some(std::time::Instant::now());

        let client = self.client.clone();
        let tx = self.event_tx.clone();
        let session_id = self.session_id.clone();
        let shell_cmd = cmd.to_string();

        tokio::spawn(async move {
            let req = crate::client::types::CommandExecuteRequest {
                command: "shell".to_string(),
                arg: shell_cmd,
                session_id,
            };
            let result = client.execute_command(&req).await;
            let event = match result {
                Ok(resp) => BackendEvent::CommandResult(Ok(resp)),
                Err(e) => BackendEvent::CommandResult(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    pub(crate) fn submit_prompt(&mut self, text: &str) {
        self.chat.add_user_message(text);
        if self.state != AppState::Processing {
            self.transition(AppState::Processing);
        }
        self.activity.start();
        self.activity.set_model_name(self.header.model_name());
        self.status.set_active(true);
        self.processing_start = Some(std::time::Instant::now());
        self.stream_buf.clear();
        self.thinking_buf.clear();

        // Send to backend
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        let session_id = self.session_id.clone();
        let input = text.to_string();

        tokio::spawn(async move {
            let req = crate::client::types::OrchestrateRequest {
                input,
                session_id: Some(session_id),
                user_id: None,
                workspace_id: None,
                skip_plan: None,
            };
            let result = client.orchestrate(&req).await;
            let event = match result {
                Ok(resp) => BackendEvent::OrchestrateResult(Ok(resp)),
                Err(e) => BackendEvent::OrchestrateResult(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    pub(super) fn cancel_processing(&mut self) {
        self.cancelled = true;
        self.toasts.push(
            "Cancelling...".into(),
            crate::components::toast::ToastLevel::Info,
        );

        // Tell the backend to stop the agent loop
        let client = self.client.clone();
        let session_id = self.session_id.clone();
        let tx = self.event_tx.clone();
        tokio::spawn(async move {
            if let Err(e) = client.cancel_session(&session_id).await {
                tracing::warn!("Backend cancel failed: {}", e);
            }
            // The SSE stream will deliver the final "Cancelled by user." response,
            // which triggers handle_agent_response → resets UI to Idle.
            // If SSE doesn't fire within 3s, force-reset the UI.
            tokio::time::sleep(std::time::Duration::from_secs(3)).await;
            let _ = tx.send(Event::Backend(BackendEvent::CancelTimeout));
        });
    }

    pub(super) fn background_task(&mut self) {
        if self.state != AppState::Processing {
            return;
        }
        let summary = format!(
            "Background task ({}s)",
            self.processing_start
                .map(|t| t.elapsed().as_secs())
                .unwrap_or(0)
        );
        self.bg_tasks.push(summary);
        self.status.set_background_count(self.bg_tasks.len());
        self.toasts.push(
            "Moved to background".into(),
            crate::components::toast::ToastLevel::Info,
        );
        // Don't cancel processing, just hide the activity
        self.activity.stop();
        self.transition(AppState::Idle);
    }

    pub fn check_health(&self) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        tokio::spawn(async move {
            let result = client.health().await;
            let event = match result {
                Ok(resp) => BackendEvent::HealthResult(Ok(resp)),
                Err(e) => BackendEvent::HealthResult(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    pub(super) fn do_login(&self) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        tokio::spawn(async move {
            let result = client.login(Some("local")).await;
            let event = match result {
                Ok(resp) => BackendEvent::LoginResult(Ok(resp)),
                Err(e) => BackendEvent::LoginResult(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    pub(super) fn load_commands(&self) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        tokio::spawn(async move {
            let result = client.list_commands().await;
            let event = match result {
                Ok(commands) => BackendEvent::CommandsLoaded(Ok(commands)),
                Err(e) => BackendEvent::CommandsLoaded(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    pub(crate) fn load_models(&self) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        tokio::spawn(async move {
            let result = client.list_models().await;
            let event = match result {
                Ok(resp) => BackendEvent::ModelsLoaded(Ok(resp)),
                Err(e) => BackendEvent::ModelsLoaded(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    pub(crate) fn load_sessions(&self) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        tokio::spawn(async move {
            let result = client.list_sessions().await;
            let event = match result {
                Ok(sessions) => BackendEvent::SessionsLoaded(Ok(sessions)),
                Err(e) => BackendEvent::SessionsLoaded(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    pub(super) fn load_tools(&self) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        tokio::spawn(async move {
            let result = client.list_tools().await;
            let event = match result {
                Ok(tools) => BackendEvent::ToolsLoaded(Ok(tools)),
                Err(e) => BackendEvent::ToolsLoaded(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    fn try_spawn_backend(&self) {
        let candidates: Vec<Option<std::path::PathBuf>> = vec![
            // From binary location: target/release/osagent → ../../.. = priv/rust/tui → ../../../ = root
            std::env::current_exe()
                .ok()
                .and_then(|p| {
                    p.parent()?.parent()?.parent()?.parent()?.parent()?.parent()
                        .map(|p| p.to_path_buf())
                }),
            // Stored project root
            std::fs::read_to_string(
                std::path::PathBuf::from(
                        std::env::var("HOME").unwrap_or_default()
                    ).join(".osa/project_root"),
            )
            .ok()
            .map(|s| std::path::PathBuf::from(s.trim())),
            // CWD
            std::env::current_dir().ok(),
        ];

        for candidate in candidates.into_iter().flatten() {
            if candidate.join("mix.exs").exists() {
                info!("Auto-starting backend from: {}", candidate.display());
                let project_dir = candidate;
                let log_dir = std::path::PathBuf::from(
                        std::env::var("HOME").unwrap_or_default()
                    ).join(".osa/logs/backend.log");
                std::thread::spawn(move || {
                    let log_file = std::fs::OpenOptions::new()
                        .create(true)
                        .append(true)
                        .open(&log_dir)
                        .ok();
                    let stdout = log_file
                        .as_ref()
                        .and_then(|f| f.try_clone().ok())
                        .map(std::process::Stdio::from)
                        .unwrap_or_else(std::process::Stdio::null);
                    let stderr = log_file
                        .map(|f| std::process::Stdio::from(f))
                        .unwrap_or_else(std::process::Stdio::null);
                    let _ = std::process::Command::new("mix")
                        .arg("osa.serve")
                        .current_dir(&project_dir)
                        .stdout(stdout)
                        .stderr(stderr)
                        .spawn();
                });
                return;
            }
        }
        warn!("Could not find project root to auto-start backend. \
               Run from the project directory or create ~/.osa/project_root");
    }

    pub(super) fn start_sse(&mut self) {
        // Cancel any previous SSE connection before starting a new one.
        if let Some(old_cancel) = self.sse_cancel.take() {
            old_cancel.cancel();
        }

        let tx = self.event_tx.clone();
        let session_id = self.session_id.clone();
        let base_url = self.config.base_url.clone();
        let client = self.client.clone();
        let cancel = tokio_util::sync::CancellationToken::new();
        self.sse_cancel = Some(cancel.clone());

        tokio::spawn(async move {
            if cancel.is_cancelled() {
                return;
            }

            let token = match client.token().await {
                Some(t) => t,
                None => {
                    warn!("No auth token for SSE");
                    return;
                }
            };

            if cancel.is_cancelled() {
                return;
            }

            let sse = crate::client::SseClient::with_cancel(
                session_id,
                base_url,
                token,
                tx,
                cancel,
            );
            sse.connect();
        });
    }

    pub(crate) fn show_help(&mut self) {
        self.chat.add_help_message();
    }

    pub(crate) fn switch_session(&mut self, session_id: &str) {
        // Cancel any active SSE connection
        if let Some(cancel) = self.sse_cancel.take() {
            cancel.cancel();
        }

        // Update session and clear state
        self.session_id = session_id.to_string();
        self.chat.clear();
        self.tasks.clear();
        self.stream_buf.clear();
        self.thinking_buf.clear();
        self.activity.stop();
        self.status.set_active(false);

        if self.state.is_processing() {
            self.transition(AppState::Idle);
        }

        // Load session history
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        let sid = session_id.to_string();
        tokio::spawn(async move {
            match client.get_session_messages(&sid).await {
                Ok(messages) => {
                    let _ = tx.send(Event::Backend(BackendEvent::SessionMessages(Ok(messages))));
                }
                Err(e) => {
                    let _ = tx.send(Event::Backend(BackendEvent::SessionMessages(Err(e.to_string()))));
                }
            }
        });

        // Reconnect SSE with new session
        self.start_sse();

        self.toasts.push(
            format!("Switched to session {}", &session_id[..session_id.len().min(16)]),
            crate::components::toast::ToastLevel::Info,
        );
    }

    pub(crate) fn create_session(&mut self) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        tokio::spawn(async move {
            let result = client.create_session().await;
            let event = match result {
                Ok(resp) => BackendEvent::SessionCreated(Ok(resp)),
                Err(e) => BackendEvent::SessionCreated(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    pub(super) fn copy_last_message(&mut self) {
        if let Some(msg) = self.chat.last_agent_message() {
            match arboard::Clipboard::new().and_then(|mut cb| cb.set_text(msg)) {
                Ok(_) => {
                    self.toasts.push(
                        "Copied to clipboard".into(),
                        crate::components::toast::ToastLevel::Info,
                    );
                }
                Err(e) => {
                    warn!("Failed to copy: {}", e);
                    self.toasts.push(
                        format!("Copy failed: {}", e),
                        crate::components::toast::ToastLevel::Warning,
                    );
                }
            }
        }
    }
}
