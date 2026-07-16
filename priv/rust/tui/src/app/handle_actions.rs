use crate::app::state::AppState;
use crate::event::backend::BackendEvent;
use crate::event::Event;
use tracing::{debug, error, info, warn};

use super::App;
use crate::util::truncate_str;

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

                // Welcome injection moved to ToolsLoaded handler (accurate tool count)

                // Seed context bar with model's max context window
                if let Some(ctx) = health.context_window {
                    self.status.set_context(0.0, 0, ctx);
                }
                // Skip banner — go straight to Idle (no jarring screen switch)
                if self.state == AppState::Connecting {
                    self.transition(AppState::Idle);
                }
                self.health_retry_count = 0;

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
                // Clear stale tokens so subsequent requests don't send them
                crate::client::auth::clear_tokens(&self.client.profile_dir);
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

    /// Force-show the onboarding wizard regardless of needs_onboarding status.
    /// Used by /setup command to let users reconfigure anytime.
    pub(crate) fn force_onboarding(&self) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        tokio::spawn(async move {
            match client.onboarding_status().await {
                Ok(mut resp) => {
                    // Force needs_onboarding to true so the wizard always shows
                    resp.needs_onboarding = true;
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
            let truncated = truncate_str(&response, super::MAX_MESSAGE_SIZE);
            format!(
                "{}\n\n... (response truncated at {}KB)",
                truncated,
                super::MAX_MESSAGE_SIZE / 1000
            )
        } else {
            response
        };

        self.chat.clear_streaming();
        // Ensure any completed tool call is committed to scrollback before the
        // final answer text, preserving chronological order.
        self.chat.flush_pending_tools();
        // Emit any pending collapsed tool run ("Read N files", …) before the
        // final answer text.
        self.flush_collapse();

        if self.agent_header_sent {
            // The header was already emitted earlier this turn (either by a
            // ToolCallStart flush or by marking the first tool call). Flush
            // any remaining buffered streaming text as a header-less
            // continuation so we never repeat the "◈ OSA" header.
            //
            // If stream_buf is empty (the LLM produced no trailing text after
            // the last tool call) but display_response has content, use
            // display_response as the continuation rather than silently
            // dropping the final answer.
            let remaining = std::mem::take(&mut self.stream_buf);
            let final_text = if !remaining.is_empty() {
                remaining
            } else if !display_response.trim().is_empty() {
                display_response
            } else {
                String::new()
            };
            if !final_text.is_empty() {
                self.chat.add_agent_continuation(&final_text);
            }
            // Do NOT reset agent_header_sent here. It is reset only when the user
            // submits a new prompt (submit_prompt). Resetting it per response
            // meant a turn that produced more than one agent_response event
            // (e.g. text → subagent/tool → more text) emitted a second "◈ OSA"
            // header, visually splitting one answer into chunks. Keeping it set
            // makes the rest of the turn render as header-less continuations.
        } else {
            // First agent output of this turn — show it under the "◈ OSA"
            // header, then mark the header as sent so any further output this
            // turn (continued text after a tool/subagent) flows underneath the
            // same header instead of starting a new block.
            self.chat
                .add_agent_message(&display_response, signal.as_ref());
            self.agent_header_sent = true;
        }

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

        // Cross-turn keep-going: if a /goal is active, decide whether to stop
        // (DONE / cap / cancelled) or auto-submit the next continue prompt.
        self.maybe_continue_goal();

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
        // Safety net: commit any leftover collapsed tool run before the new turn.
        self.flush_collapse();
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
        self.agent_header_sent = false;

        // Send to backend
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        let session_id = self.session_id.clone();
        let input = text.to_string();
        let working_dir = if self.working_dir.is_empty() {
            None
        } else {
            Some(self.working_dir.clone())
        };
        // Collect pasted/dropped attachments for this turn, then clear them so the
        // next prompt starts fresh (the chips already left the input on submit).
        let images = if self.attachments.is_empty() {
            None
        } else {
            Some(self.attachments.iter().map(|a| a.wire_value()).collect::<Vec<_>>())
        };
        self.attachments.clear();

        tokio::spawn(async move {
            let req = crate::client::types::OrchestrateRequest {
                input,
                session_id: Some(session_id),
                user_id: None,
                workspace_id: None,
                skip_plan: None,
                working_dir,
                images,
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
            "Interrupting...".into(),
            crate::components::toast::ToastLevel::Info,
        );

        // A user interrupt also stops any active /goal auto-continue loop.
        if self.goal.is_some() {
            self.clear_goal(true);
        }

        // Immediately clear the agents panel so the UI reflects the interrupt
        self.agents.task_completed();
        self.recompute_layout();

        // Tell the backend to stop the agent loop (+ all sub-agents)
        let client = self.client.clone();
        let session_id = self.session_id.clone();
        let tx = self.event_tx.clone();
        tokio::spawn(async move {
            if let Err(e) = client.cancel_session(&session_id).await {
                tracing::warn!("Backend cancel failed: {}", e);
            }
            // Also cancel any active swarm
            // (swarm IDs not tracked here, backend cancel propagates to sub-agents)

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
        self.status.set_shell_count(self.bg_tasks.len());
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
        // Provider-first picker: load the provider catalog + detection status
        // (not the flat model list), so we can render ✓ ready / ⚠ needs-key.
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        tokio::spawn(async move {
            let result = client.onboarding_status().await;
            let event = match result {
                Ok(resp) => BackendEvent::ProviderPickerData(Ok(resp)),
                Err(e) => BackendEvent::ProviderPickerData(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    /// Verify a candidate provider key live (picker key screen).
    pub(crate) fn verify_provider_key(
        &self,
        provider: String,
        api_key: Option<String>,
        model: String,
        base_url: Option<String>,
    ) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        tokio::spawn(async move {
            let body = serde_json::json!({
                "provider": provider,
                "api_key": api_key,
                "model": model,
                "base_url": base_url,
            });
            // The authenticated variant attaches a Bearer only when a token
            // exists and works in both contexts: post-onboarding (auth required
            // to pass through a candidate key) and first-run (backend permits
            // params for known providers without a token).
            let result = client.onboarding_health_check_auth(&body).await;
            let event = match result {
                Ok(resp) => BackendEvent::ModelPickerKeyVerified(Ok(resp)),
                Err(e) => BackendEvent::ModelPickerKeyVerified(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    /// Persist a verified key (merging into .env) then switch to it.
    pub(crate) fn save_provider_key_and_switch(
        &self,
        provider: String,
        runtime_provider: String,
        api_key: Option<String>,
        model: String,
        base_url: Option<String>,
    ) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        tokio::spawn(async move {
            let saved = client
                .providers_save_key(
                    &provider,
                    api_key.as_deref(),
                    base_url.as_deref(),
                    Some(&model),
                    true,
                )
                .await;
            match saved {
                Ok(_) => {
                    // Reflect the switch live in the UI header + context window.
                    let req = crate::client::types::ModelSwitchRequest {
                        provider: runtime_provider,
                        model: model.clone(),
                    };
                    let event = match client.switch_model(&req).await {
                        Ok(resp) => BackendEvent::ModelSwitched(Ok(resp)),
                        Err(e) => BackendEvent::ModelSwitched(Err(e.to_string())),
                    };
                    let _ = tx.send(Event::Backend(event));
                }
                Err(e) => {
                    let _ = tx.send(Event::Backend(BackendEvent::ModelSwitched(Err(
                        e.to_string()
                    ))));
                }
            }
        });
    }

    /// Fetch a provider's dynamic model list (miosa / ollama_local / custom).
    pub(crate) fn load_provider_models(
        &self,
        provider: String,
        base_url: Option<String>,
        api_key: Option<String>,
    ) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        tokio::spawn(async move {
            let result = client
                .onboarding_models(&provider, base_url.as_deref(), api_key.as_deref())
                .await;
            let event = match result {
                Ok(resp) => BackendEvent::ProviderModelsLoaded(Ok(resp)),
                Err(e) => BackendEvent::ProviderModelsLoaded(Err(e.to_string())),
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

    /// Open the session browser populated from GET /api/v1/sessions/recent so
    /// past on-disk sessions show with real titles/counts (used by /resume).
    pub(crate) fn load_recent_sessions(&self) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        tokio::spawn(async move {
            let result = client.recent_sessions().await;
            let event = match result {
                Ok(sessions) => BackendEvent::SessionsLoaded(Ok(sessions)),
                Err(e) => BackendEvent::SessionsLoaded(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    /// Directory-scoped resume for the current working folder (used by /continue):
    /// POST /api/v1/sessions with { working_dir }, then switch to the returned
    /// session and pull its transcript back in via the SessionCreated handler.
    pub(crate) fn continue_session(&mut self) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        let working_dir = if self.working_dir.is_empty() {
            std::env::current_dir()
                .ok()
                .map(|p| p.display().to_string())
        } else {
            Some(self.working_dir.clone())
        };
        let working_dir = match working_dir {
            Some(dir) => dir,
            None => {
                self.toasts.push(
                    "Cannot determine working directory to continue".into(),
                    crate::components::toast::ToastLevel::Error,
                );
                return;
            }
        };
        tokio::spawn(async move {
            let result = client.resume_for_dir(working_dir).await;
            let event = match result {
                Ok(resp) => BackendEvent::SessionCreated(Ok(resp)),
                Err(e) => BackendEvent::SessionCreated(Err(e.to_string())),
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
        self.pending_tool_args.clear();
        self.agent_header_sent = false;
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
            format!("Switched to session {}", truncate_str(session_id, 16)),
            crate::components::toast::ToastLevel::Info,
        );
    }

    pub(crate) fn create_session(&mut self) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        // Tag the session to the current folder so it resumes there next time.
        let working_dir = if self.working_dir.is_empty() {
            std::env::current_dir()
                .ok()
                .map(|p| p.display().to_string())
        } else {
            Some(self.working_dir.clone())
        };
        tokio::spawn(async move {
            let result = client.create_session(working_dir).await;
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

    // ── Voice input ──────────────────────────────────────────────

    pub(crate) fn start_recording(&mut self) {
        if self.voice.recording {
            return;
        }
        // Don't allow recording while the LLM is processing
        if self.state == AppState::Processing {
            self.toasts.push(
                "Cannot record while processing".into(),
                crate::components::toast::ToastLevel::Warning,
            );
            return;
        }

        match crate::voice::VoiceCapture::start() {
            Ok(capture) => {
                self.voice.recording = true;
                self.voice.started_at = Some(std::time::Instant::now());
                self.voice.silence_start = None;
                self.voice.capture = Some(capture);
                self.transition(AppState::Recording);
                self.status.set_recording(true);
                self.input.set_recording(true);
                info!("Voice recording started");
            }
            Err(e) => {
                error!("Failed to start recording: {}", e);
                self.toasts.push(
                    format!("Mic error: {}", e),
                    crate::components::toast::ToastLevel::Error,
                );
            }
        }
    }

    pub(crate) fn stop_recording(&mut self) {
        if !self.voice.recording {
            return;
        }

        self.voice.recording = false;
        self.voice.silence_start = None;
        self.status.set_recording(false);
        self.input.set_recording(false);

        let capture = match self.voice.capture.take() {
            Some(c) => c,
            None => {
                if self.state == AppState::Recording {
                    self.transition(AppState::Idle);
                }
                return;
            }
        };

        let buffer = capture.stop();
        self.voice.started_at = None;

        if buffer.duration_secs() < 0.3 {
            self.toasts.push(
                "Recording too short".into(),
                crate::components::toast::ToastLevel::Warning,
            );
            if self.state == AppState::Recording {
                self.transition(AppState::Idle);
            }
            return;
        }

        // Transcribe in background
        let tx = self.event_tx.clone();
        let provider_debug = format!("{:?}", self.voice.provider);
        info!("Transcribing with {}", provider_debug);

        self.status.set_transcribing(true);
        self.toasts.push(
            "Transcribing...".into(),
            crate::components::toast::ToastLevel::Info,
        );

        // Spawn transcription based on provider type
        match &self.voice.provider {
            crate::voice::VoiceProvider::Cloud(c) => {
                let api_key = c.api_key().to_string();
                tokio::spawn(async move {
                    let transcriber = crate::voice::CloudTranscriber::new(api_key);
                    let result = transcriber.transcribe(buffer).await;
                    let event = match result {
                        Ok(text) => crate::event::VoiceEvent::TranscriptionReady(text),
                        Err(e) => crate::event::VoiceEvent::TranscriptionError(e.to_string()),
                    };
                    let _ = tx.send(crate::event::Event::Voice(event));
                });
            }
            crate::voice::VoiceProvider::Groq(g) => {
                let api_key = g.api_key().to_string();
                tokio::spawn(async move {
                    let transcriber = crate::voice::GroqTranscriber::new(api_key);
                    let result = transcriber.transcribe(buffer).await;
                    let event = match result {
                        Ok(text) => crate::event::VoiceEvent::TranscriptionReady(text),
                        Err(e) => crate::event::VoiceEvent::TranscriptionError(e.to_string()),
                    };
                    let _ = tx.send(crate::event::Event::Voice(event));
                });
            }
            crate::voice::VoiceProvider::Local(_) => {
                tokio::spawn(async move {
                    let provider = crate::voice::VoiceProvider::local_or_unavailable();
                    let result = provider
                        .transcribe_with_progress(buffer, Some(&tx))
                        .await;
                    let event = match result {
                        Ok(text) => crate::event::VoiceEvent::TranscriptionReady(text),
                        Err(e) => crate::event::VoiceEvent::TranscriptionError(e.to_string()),
                    };
                    let _ = tx.send(crate::event::Event::Voice(event));
                });
            }
        }
    }

    pub(crate) fn cancel_recording(&mut self) {
        if !self.voice.recording {
            return;
        }

        self.voice.recording = false;
        self.voice.started_at = None;
        self.voice.silence_start = None;
        self.status.set_recording(false);
        self.input.set_recording(false);

        // Drop capture, discarding audio
        if let Some(capture) = self.voice.capture.take() {
            drop(capture);
        }

        if self.state == AppState::Recording {
            self.transition(AppState::Idle);
        }
        self.toasts.push(
            "Recording cancelled".into(),
            crate::components::toast::ToastLevel::Info,
        );
        info!("Voice recording cancelled");
    }

    pub(crate) fn toggle_hands_free(&mut self) {
        self.voice.hands_free = !self.voice.hands_free;
        self.status.set_hands_free(self.voice.hands_free);

        if self.voice.hands_free {
            self.toasts.push(
                "Hands-free: ON (F9 to toggle)".into(),
                crate::components::toast::ToastLevel::Info,
            );
            // Start recording immediately when enabling hands-free
            if !self.voice.recording {
                self.start_recording();
            }
        } else {
            self.toasts.push(
                "Hands-free: OFF".into(),
                crate::components::toast::ToastLevel::Info,
            );
            // Cancel any active recording when disabling
            if self.voice.recording {
                self.cancel_recording();
            }
        }
        info!("Hands-free voice mode: {}", self.voice.hands_free);
    }

    // ── /goal auto-continue (cross-turn keep-going) ──────────────────────────

    /// Start (or replace) an active goal and kick off the first work turn.
    pub(crate) fn set_goal(&mut self, goal: &str) {
        let goal = goal.trim().to_string();
        if goal.is_empty() {
            return;
        }
        self.goal = Some(goal.clone());
        self.goal_cycle = 0;
        self.refresh_goal_status();
        self.chat.add_system_message(
            &format!(
                "Goal set — auto-continuing until achieved (max {} cycles). Reply DONE to stop. Use /goal off to cancel.\n→ {}",
                self.goal_max_cycles, goal
            ),
            "info",
        );
        // Kick off the first turn toward the goal.
        let prompt = self.goal_continue_prompt(&goal);
        self.goal_cycle = 1;
        self.refresh_goal_status();
        self.submit_prompt(&prompt);
    }

    /// Clear the active goal (from /goal off, cancel, DONE, or the cycle cap).
    pub(crate) fn clear_goal(&mut self, notify: bool) {
        let had_goal = self.goal.is_some();
        self.goal = None;
        self.goal_cycle = 0;
        self.status.set_goal_label(None);
        if notify && had_goal {
            self.chat.add_system_message("Goal cleared.", "info");
        }
    }

    /// Show the current goal status without changing it.
    pub(crate) fn show_goal_status(&mut self) {
        match self.goal.clone() {
            Some(goal) => {
                self.chat.add_system_message(
                    &format!(
                        "Active goal (cycle {}/{}):\n→ {}",
                        self.goal_cycle, self.goal_max_cycles, goal
                    ),
                    "info",
                );
            }
            None => {
                self.chat.add_system_message(
                    "No active goal. Set one with /goal <text>.",
                    "info",
                );
            }
        }
    }

    /// The continue prompt sent on each cycle toward the goal.
    fn goal_continue_prompt(&self, goal: &str) -> String {
        format!(
            "Continue toward the goal: {}. When the goal is fully achieved, reply with exactly DONE on its own line and stop.",
            goal
        )
    }

    /// Sync the status-bar "goal N/max" indicator with the current state.
    fn refresh_goal_status(&mut self) {
        if self.goal.is_some() {
            self.status.set_goal_label(Some(format!(
                "goal {}/{}",
                self.goal_cycle, self.goal_max_cycles
            )));
        } else {
            self.status.set_goal_label(None);
        }
    }

    /// True when the assistant reply signals the goal is achieved (a line that
    /// trims to exactly "DONE").
    fn reply_signals_done(reply: &str) -> bool {
        reply.lines().any(|line| line.trim() == "DONE")
    }

    /// Called at the end of each assistant turn. If a goal is active, either
    /// stop (DONE / cap reached) or auto-submit the next continue prompt.
    pub(super) fn maybe_continue_goal(&mut self) {
        let goal = match self.goal.clone() {
            Some(g) => g,
            None => return,
        };
        // Don't auto-continue if the user cancelled this turn.
        if self.cancelled {
            self.clear_goal(true);
            return;
        }

        let last_reply = self.chat.last_agent_message().unwrap_or_default();
        if Self::reply_signals_done(&last_reply) {
            self.chat.add_system_message(
                &format!("Goal achieved in {} cycle(s). Auto-continue stopped.", self.goal_cycle),
                "info",
            );
            self.clear_goal(false);
            return;
        }

        if self.goal_cycle >= self.goal_max_cycles {
            self.chat.add_system_message(
                &format!(
                    "Goal auto-continue reached the {}-cycle cap without a DONE. Stopping. Use /goal <text> to resume.",
                    self.goal_max_cycles
                ),
                "warning",
            );
            self.clear_goal(false);
            return;
        }

        self.goal_cycle += 1;
        self.refresh_goal_status();
        let prompt = self.goal_continue_prompt(&goal);
        self.submit_prompt(&prompt);
    }
}

/// Read user name from ~/.osa/USER.md (sync, for welcome message)
pub fn read_user_name_sync() -> Option<String> {
    let home = std::env::var("HOME").ok()?;
    let path = format!("{}/.osa/USER.md", home);
    let content = std::fs::read_to_string(&path).ok()?;

    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("- **Name:**") {
            let name = trimmed.trim_start_matches("- **Name:**").trim();
            if !name.is_empty() {
                return Some(name.to_string());
            }
        }
    }
    None
}
