use crate::app::state::AppState;
use crate::dialogs::command_palette::PaletteItem;
use crate::dialogs::DialogAction;
use crate::event::backend::BackendEvent;
use crate::event::Event;

use super::App;

impl App {
    pub(super) fn handle_quit_dialog_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        if let Some(action) = self.quit_dialog.handle_key(key) {
            match action {
                DialogAction::QuitConfirmed => return true,
                DialogAction::Dismissed => self.transition(AppState::Idle),
                _ => {}
            }
        }
        false
    }

    pub(super) fn handle_palette_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        if let Some(action) = self.palette.handle_key(key) {
            match action {
                DialogAction::PaletteExecute(name) => {
                    self.transition(AppState::Idle);
                    self.handle_command(&format!("/{}", name));
                }
                DialogAction::Dismissed => {
                    self.transition(AppState::Idle);
                }
                _ => {}
            }
        }
        false
    }

    pub(super) fn handle_model_picker_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        use crate::dialogs::model_picker::ModelPickerAction;

        let action = self
            .model_picker
            .as_mut()
            .and_then(|picker| picker.handle_key(key));

        if let Some(action) = action {
            match action {
                // Terminal actions — close the picker.
                ModelPickerAction::SelectModel {
                    provider,
                    runtime_provider,
                    model,
                    base_url,
                } => {
                    self.transition(AppState::Idle);
                    self.model_picker = None;
                    // Persist selection into .env (merge, set active) and switch
                    // live. For a re-select of the current default this is a no-op
                    // switch, which is harmless.
                    self.save_provider_key_and_switch(
                        provider,
                        runtime_provider,
                        None,
                        model,
                        base_url,
                    );
                }
                ModelPickerAction::Cancel => {
                    self.transition(AppState::Idle);
                    self.model_picker = None;
                }
                ModelPickerAction::SaveKeyAndSwitch {
                    provider,
                    runtime_provider,
                    api_key,
                    model,
                    base_url,
                } => {
                    self.transition(AppState::Idle);
                    self.model_picker = None;
                    self.save_provider_key_and_switch(
                        provider,
                        runtime_provider,
                        api_key,
                        model,
                        base_url,
                    );
                }
                // Non-terminal actions — KEEP the picker alive (critical: do not
                // clear it, or the "Verifying…" / Models transition is lost).
                ModelPickerAction::VerifyKey {
                    provider,
                    api_key,
                    model,
                    base_url,
                } => {
                    self.verify_provider_key(provider, api_key, model, base_url);
                }
                ModelPickerAction::LoadProviderModels {
                    provider,
                    base_url,
                    api_key,
                } => {
                    self.load_provider_models(provider, base_url, api_key);
                }
            }
        }
        false
    }

    pub(super) fn handle_session_browser_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        if let Some(ref mut browser) = self.session_browser {
            if let Some(action) = browser.handle_key(key) {
                match action {
                    crate::dialogs::sessions::SessionAction::Switch(id) => {
                        self.transition(AppState::Idle);
                        self.session_id = id;
                        self.chat.clear();
                        self.tasks.clear();
                        self.stream_buf.clear();
                        self.thinking_buf.clear();
                        self.agent_header_sent = false;
                        self.toasts.push(
                            "Session switched".into(),
                            crate::components::toast::ToastLevel::Info,
                        );
                    }
                    crate::dialogs::sessions::SessionAction::Create => {
                        self.transition(AppState::Idle);
                        self.create_session();
                    }
                    crate::dialogs::sessions::SessionAction::Cancel => {
                        self.transition(AppState::Idle);
                    }
                    crate::dialogs::sessions::SessionAction::Rename(id, new_title) => {
                        let client = self.client.clone();
                        let tx = self.event_tx.clone();
                        tokio::spawn(async move {
                            match client.rename_session(&id, &new_title).await {
                                Ok(_) => {}
                                Err(e) => {
                                    let _ = tx.send(Event::Backend(
                                        BackendEvent::CommandResult(Err(e.to_string())),
                                    ));
                                }
                            }
                        });
                        self.toasts.push(
                            "Session renamed".into(),
                            crate::components::toast::ToastLevel::Info,
                        );
                        return false;
                    }
                    crate::dialogs::sessions::SessionAction::Delete(id) => {
                        let client = self.client.clone();
                        tokio::spawn(async move {
                            let _ = client.delete_session(&id).await;
                        });
                        self.toasts.push(
                            "Session deleted".into(),
                            crate::components::toast::ToastLevel::Info,
                        );
                        return false;
                    }
                }
                self.session_browser = None;
            }
        }
        false
    }

    pub(super) fn handle_onboarding_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        if let Some(ref mut wizard) = self.onboarding {
            if let Some(action) = wizard.handle_key(key) {
                match action {
                    crate::dialogs::onboarding::OnboardingAction::Complete(result) => {
                        self.transition(AppState::Idle);
                        self.toasts.push(
                            "Setup complete!".into(),
                            crate::components::toast::ToastLevel::Success,
                        );
                        // Send onboarding result to backend
                        let client = self.client.clone();
                        let tx = self.event_tx.clone();
                        tokio::spawn(async move {
                            let channel_tokens = if result.channel_tokens.is_empty() {
                                None
                            } else {
                                Some(result.channel_tokens)
                            };
                            let req = crate::client::types::OnboardingSetupRequest {
                                provider: result.provider,
                                model: result.model,
                                api_key: result.api_key,
                                base_url: result.base_url,
                                channel_tokens,
                                user_name: result.user_name,
                                agent_name: result.agent_name,
                            };
                            let event = match client.onboarding_setup(&req).await {
                                Ok(resp) => BackendEvent::OnboardingComplete(Ok(resp)),
                                Err(e) => BackendEvent::OnboardingComplete(Err(e.to_string())),
                            };
                            let _ = tx.send(Event::Backend(event));
                        });
                        self.onboarding = None;
                    }
                    crate::dialogs::onboarding::OnboardingAction::Cancel => {
                        self.transition(AppState::Idle);
                        self.onboarding = None;
                    }
                }
            }

            // After handling the key, check if we need to fire a health check
            if let Some(ref wizard) = self.onboarding {
                if wizard.needs_health_check() {
                    if let Some(params) = wizard.get_health_check_params() {
                        let client = self.client.clone();
                        let tx = self.event_tx.clone();
                        tokio::spawn(async move {
                            let event = match client.onboarding_health_check(&params).await {
                                Ok(resp) => BackendEvent::OnboardingHealthCheck(Ok(resp)),
                                Err(e) => BackendEvent::OnboardingHealthCheck(Err(e.to_string())),
                            };
                            let _ = tx.send(Event::Backend(event));
                        });
                    }
                }
            }
        }
        false
    }

    pub(super) fn handle_plan_review_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        // Resolve the action first (mutable borrow of `plan_review`), then act on
        // `self` freely — avoids overlapping borrows when we touch input/activity.
        let action = self
            .plan_review
            .as_mut()
            .and_then(|review| review.handle_key(key));
        let Some(action) = action else {
            return false;
        };

        match action {
            DialogAction::PlanApprove => {
                // Approve → resume execution. Drive the processing indicator so the
                // spinner comes back immediately; SSE events resume the turn.
                self.plan_review = None;
                self.transition(AppState::Processing);
                self.activity.start();
                self.status.set_active(true);
                self.processing_start = Some(std::time::Instant::now());
                self.toasts.push(
                    "Plan approved — resuming".into(),
                    crate::components::toast::ToastLevel::Info,
                );
                self.send_plan_command("plan_approve", String::new());
            }
            DialogAction::PlanReject => {
                self.plan_review = None;
                self.transition(AppState::Idle);
                self.toasts.push(
                    "Plan rejected".into(),
                    crate::components::toast::ToastLevel::Info,
                );
                self.send_plan_command("plan_reject", String::new());
            }
            DialogAction::PlanEdit => {
                // Edit → seed the input box with the plan text so the user can
                // revise and re-submit it as the next message (the edited plan
                // goes back to the agent). Release the backend gate too.
                let plan_text = self
                    .plan_review
                    .as_ref()
                    .map(|r| r.plan_text().to_string())
                    .unwrap_or_default();
                self.plan_review = None;
                self.transition(AppState::Idle);
                if !plan_text.is_empty() {
                    self.input.reset();
                    self.input.insert_str(&plan_text);
                }
                self.toasts.push(
                    "Edit the plan and press Enter to send it back".into(),
                    crate::components::toast::ToastLevel::Info,
                );
                self.send_plan_command("plan_edit", String::new());
            }
            _ => {}
        }
        false
    }

    /// Fire a plan-mode command (`plan_approve` / `plan_reject` / `plan_edit`) at
    /// the backend for the current session, routing the result back as a
    /// `CommandResult` event.
    fn send_plan_command(&self, command: &str, arg: String) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        let session_id = self.session_id.clone();
        let command = command.to_string();
        tokio::spawn(async move {
            let req = crate::client::types::CommandExecuteRequest {
                command,
                arg,
                session_id,
            };
            let event = match client.execute_command(&req).await {
                Ok(resp) => BackendEvent::CommandResult(Ok(resp)),
                Err(e) => BackendEvent::CommandResult(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    pub(super) fn handle_permissions_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        if let Some(ref mut dialog) = self.permissions {
            if let Some(action) = dialog.handle_key(key) {
                match action {
                    DialogAction::PermissionAllow => {
                        self.transition(AppState::Idle);
                        self.toasts.push(
                            "Permission granted".into(),
                            crate::components::toast::ToastLevel::Info,
                        );
                        if let Some(ref d) = self.permissions {
                            let client = self.client.clone();
                            let request_id = d.request_id().to_string();
                            tokio::spawn(async move {
                                let _ = client.permission_response(&request_id, true).await;
                            });
                        }
                        self.permissions = None;
                    }
                    DialogAction::PermissionAllowSession => {
                        self.transition(AppState::Idle);
                        self.toasts.push(
                            "Permission granted for session".into(),
                            crate::components::toast::ToastLevel::Info,
                        );
                        if let Some(ref d) = self.permissions {
                            let client = self.client.clone();
                            let request_id = d.request_id().to_string();
                            tokio::spawn(async move {
                                let _ = client.permission_response(&request_id, true).await;
                            });
                        }
                        self.permissions = None;
                    }
                    DialogAction::PermissionAllowAlways => {
                        self.transition(AppState::Idle);
                        self.toasts.push(
                            "Permission granted (always)".into(),
                            crate::components::toast::ToastLevel::Info,
                        );
                        if let Some(ref d) = self.permissions {
                            let client = self.client.clone();
                            let request_id = d.request_id().to_string();
                            // Reuse the permission-response mechanism; the
                            // always-allow flag asks the backend to persist a rule.
                            tokio::spawn(async move {
                                let _ = client
                                    .permission_response_always(&request_id, true)
                                    .await;
                            });
                        }
                        self.permissions = None;
                    }
                    DialogAction::PermissionClarify(text) => {
                        // Release the pending gate, then steer the clarification
                        // back to the agent as an ordinary message.
                        if let Some(ref d) = self.permissions {
                            let client = self.client.clone();
                            let request_id = d.request_id().to_string();
                            tokio::spawn(async move {
                                let _ = client.permission_response(&request_id, false).await;
                            });
                        }
                        self.permissions = None;
                        self.submit_prompt(&text);
                    }
                    DialogAction::PermissionDeny => {
                        self.transition(AppState::Idle);
                        self.toasts.push(
                            "Permission denied".into(),
                            crate::components::toast::ToastLevel::Warning,
                        );
                        if let Some(ref d) = self.permissions {
                            let client = self.client.clone();
                            let request_id = d.request_id().to_string();
                            tokio::spawn(async move {
                                let _ = client.permission_response(&request_id, false).await;
                            });
                        }
                        self.permissions = None;
                    }
                    _ => {}
                }
            }
        }
        false
    }

    pub(crate) fn open_file_picker(&mut self) {
        let start_dir = std::env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from("/"));
        self.file_picker = Some(crate::dialogs::file_picker::FilePicker::new(start_dir));
        // File picker is an overlay — don't transition app state; render as overlay on Idle.
    }

    pub(super) fn handle_file_picker_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        if let Some(ref mut picker) = self.file_picker {
            if let Some(action) = picker.handle_key(key) {
                match action {
                    crate::dialogs::file_picker::FilePickerAction::Select(path) => {
                        // Insert the selected path as an @-prefixed file reference.
                        // The trailing space lets the user continue typing immediately.
                        let insertion = format!("@{} ", path);
                        self.input.insert_str(&insertion);
                        self.file_picker = None;
                    }
                    crate::dialogs::file_picker::FilePickerAction::Cancel => {
                        self.file_picker = None;
                    }
                }
            }
        }
        false
    }

    pub(crate) fn open_reasoning_selector(&mut self) {
        use crate::dialogs::reasoning::{ReasoningLevel, ReasoningSelector};
        self.reasoning_selector = Some(ReasoningSelector::new(ReasoningLevel::Off));
    }

    // ── Rewind (/rewind) ────────────────────────────────────────────────

    /// Fetch recent rewind checkpoints for the current session and open the
    /// restore dialog once they arrive (GET /api/v1/rewind/:session_id).
    pub(crate) fn load_rewind_checkpoints(&self) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        let sid = self.session_id.clone();
        tokio::spawn(async move {
            let event = match client.list_rewind_checkpoints(&sid).await {
                Ok(cps) => crate::event::backend::BackendEvent::RewindCheckpointsLoaded(Ok(cps)),
                Err(e) => crate::event::backend::BackendEvent::RewindCheckpointsLoaded(Err(
                    e.to_string(),
                )),
            };
            let _ = tx.send(crate::event::Event::Backend(event));
        });
    }

    pub(super) fn handle_rewind_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        if let Some(ref mut dialog) = self.rewind_dialog {
            if let Some(action) = dialog.handle_key(key) {
                match action {
                    crate::dialogs::rewind::RewindAction::Restore(id, scope) => {
                        use crate::client::types::RewindScope;
                        self.rewind_dialog = None;
                        self.transition(AppState::Idle);

                        // If the conversation is being restored, reset the visible
                        // scrollback — the live loop's context is swapped server-side.
                        if matches!(scope, RewindScope::Conversation | RewindScope::Both) {
                            self.chat.clear();
                            self.tasks.clear();
                            self.stream_buf.clear();
                            self.thinking_buf.clear();
                            self.agent_header_sent = false;
                            self.chat.add_system_message(
                                "Rewound conversation to an earlier checkpoint.",
                                "info",
                            );
                        }

                        let client = self.client.clone();
                        let tx = self.event_tx.clone();
                        let sid = self.session_id.clone();
                        tokio::spawn(async move {
                            let event = match client.restore_rewind(&sid, &id, scope).await {
                                Ok(resp) => {
                                    crate::event::backend::BackendEvent::RewindRestored(Ok(resp))
                                }
                                Err(e) => crate::event::backend::BackendEvent::RewindRestored(Err(
                                    e.to_string(),
                                )),
                            };
                            let _ = tx.send(crate::event::Event::Backend(event));
                        });
                    }
                    crate::dialogs::rewind::RewindAction::Cancel => {
                        self.rewind_dialog = None;
                        self.transition(AppState::Idle);
                    }
                }
            }
        }
        false
    }

    pub(super) fn handle_reasoning_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        if let Some(ref mut selector) = self.reasoning_selector {
            if let Some(action) = selector.handle_key(key) {
                match action {
                    crate::dialogs::reasoning::ReasoningAction::Select(level) => {
                        let label = match level {
                            crate::dialogs::reasoning::ReasoningLevel::Off => "off",
                            crate::dialogs::reasoning::ReasoningLevel::Low => "low",
                            crate::dialogs::reasoning::ReasoningLevel::Medium => "medium",
                            crate::dialogs::reasoning::ReasoningLevel::High => "high",
                        };
                        self.reasoning_selector = None;
                        // Send reasoning toggle to backend via command
                        self.execute_reasoning_command(label);
                    }
                    crate::dialogs::reasoning::ReasoningAction::Cancel => {
                        self.reasoning_selector = None;
                    }
                }
            }
        }
        false
    }

    pub(crate) fn execute_reasoning_command(&mut self, level: &str) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        let req = crate::client::types::CommandExecuteRequest {
            command: "reasoning".to_string(),
            arg: level.to_string(),
            session_id: self.session_id.clone(),
        };
        tokio::spawn(async move {
            let result = client.execute_command(&req).await;
            let event = match result {
                Ok(resp) => crate::event::backend::BackendEvent::CommandResult(Ok(resp)),
                Err(e) => crate::event::backend::BackendEvent::CommandResult(Err(e.to_string())),
            };
            let _ = tx.send(crate::event::Event::Backend(event));
        });
        self.toasts.push(
            format!("Reasoning: {}", level),
            crate::components::toast::ToastLevel::Info,
        );
    }

    // ── Config editor (/config) ────────────────────────────────────────────

    /// Open the unified `/config` full-screen settings editor, seeded from the
    /// live config, status bar, header, and `~/.osa/.env`.
    pub(crate) fn open_config_editor(&mut self) {
        use crate::components::status_bar::PermissionMode;
        use crate::dialogs::config_editor::{ConfigEditor, ConfigSnapshot};

        let env = self.client.read_env_map();
        let get = |k: &str| env.get(k).cloned().unwrap_or_default();

        let provider = {
            let p = get("OSA_PROVIDER");
            if p.is_empty() {
                self.header.provider().to_string()
            } else {
                p
            }
        };
        let model = {
            let m = get("OSA_MODEL");
            if m.is_empty() {
                self.header.model_name().to_string()
            } else {
                m
            }
        };
        let reasoning_effort = {
            let r = get("OSA_REASONING_EFFORT");
            if r.is_empty() {
                "medium".to_string()
            } else {
                r
            }
        };
        let permission_mode = match self.status.permission_mode() {
            PermissionMode::Default => "default",
            PermissionMode::Auto => "auto",
            PermissionMode::AcceptEdits => "acceptEdits",
            PermissionMode::Plan => "plan",
            PermissionMode::BypassPermissions => "bypass",
        }
        .to_string();
        let sandbox_backend = {
            let s = get("OSA_SANDBOX_BACKEND");
            if s.is_empty() {
                "miosa".to_string()
            } else {
                s
            }
        };

        let snapshot = ConfigSnapshot {
            provider,
            model,
            reasoning_effort,
            theme: self.config.theme.clone(),
            permission_mode,
            notifications: self.notify_on_complete,
            sandbox_backend,
            api_base_url: get("OSA_API_BASE"),
            themes: crate::style::themes::available()
                .iter()
                .map(|s| s.to_string())
                .collect(),
        };

        self.config_editor = Some(ConfigEditor::new(snapshot));
    }

    pub(super) fn handle_config_editor_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        use crate::dialogs::config_editor::ConfigAction;

        let action = self
            .config_editor
            .as_mut()
            .and_then(|editor| editor.handle_key(key));

        let Some(action) = action else {
            return false;
        };

        match action {
            ConfigAction::Close => {
                self.config_editor = None;
            }
            ConfigAction::OpenModelPicker => {
                // Hand off to the existing provider/model picker flow.
                self.config_editor = None;
                self.load_models();
            }
            ConfigAction::SetValue { field, value } => {
                self.apply_config_value(field, &value);
            }
        }
        false
    }

    /// Persist + apply a single committed config value.
    fn apply_config_value(&mut self, field: crate::dialogs::config_editor::ConfigField, value: &str) {
        use crate::components::status_bar::PermissionMode;
        use crate::dialogs::config_editor::ConfigField;

        match field {
            ConfigField::ReasoningEffort => {
                let _ = self.client.set_env_var("OSA_REASONING_EFFORT", value);
                self.execute_reasoning_command(value);
            }
            ConfigField::Theme => {
                if let Some(theme) = crate::style::themes::by_name(value) {
                    self.config.theme = value.to_string();
                    let _ = self.config.save();
                    crate::style::set_theme(theme);
                    self.toasts.push(
                        format!("Theme: {}", value),
                        crate::components::toast::ToastLevel::Info,
                    );
                }
            }
            ConfigField::PermissionMode => {
                let mode = match value {
                    "auto" => PermissionMode::Auto,
                    "acceptEdits" => PermissionMode::AcceptEdits,
                    "plan" => PermissionMode::Plan,
                    "bypass" => PermissionMode::BypassPermissions,
                    _ => PermissionMode::Default,
                };
                self.status.set_permission_mode(mode);
                let bypass = matches!(mode, PermissionMode::BypassPermissions);
                self.config.skip_permissions = bypass;
                self.sidebar.set_yolo_mode(bypass);
                let _ = self.client.set_env_var("OSA_PERMISSION_MODE", value);
                self.toasts.push(
                    format!("Permission mode: {}", mode.title()),
                    crate::components::toast::ToastLevel::Info,
                );
            }
            ConfigField::Notifications => {
                let on = value == "on";
                self.notify_on_complete = on;
                let _ = self
                    .client
                    .set_env_var("OSA_NOTIFY", if on { "on" } else { "off" });
                self.toasts.push(
                    format!("Notifications: {}", if on { "on" } else { "off" }),
                    crate::components::toast::ToastLevel::Info,
                );
            }
            ConfigField::SandboxBackend => {
                let _ = self.client.set_env_var("OSA_SANDBOX_BACKEND", value);
                self.toasts.push(
                    format!("Sandbox backend: {}", value),
                    crate::components::toast::ToastLevel::Info,
                );
            }
            ConfigField::ApiBaseUrl => {
                let _ = self.client.set_env_var("OSA_API_BASE", value);
                self.toasts.push(
                    "API base URL saved (restart to apply)".into(),
                    crate::components::toast::ToastLevel::Info,
                );
            }
            // Provider/Model are edited via the model picker (OpenModelPicker),
            // not through SetValue.
            ConfigField::Provider | ConfigField::Model => {}
        }
    }

    pub(super) fn handle_survey_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        use crate::dialogs::survey::SurveyAction;

        if let Some(ref mut survey) = self.survey {
            if let Some(action) = survey.handle_key(key) {
                match action {
                    SurveyAction::Submit(result) => {
                        let session_id = self.session_id.clone();
                        let client = self.client.clone();
                        let request = crate::client::types::SurveyAnswerRequest {
                            survey_id: result.survey_id.clone(),
                            answers: result.answers.iter().map(|a| {
                                crate::client::types::SurveyAnswerEntry {
                                    question_index: a.question_index,
                                    question_text: a.question_text.clone(),
                                    selected: a.selected.clone(),
                                    free_text: a.free_text.clone(),
                                }
                            }).collect(),
                            session_id: session_id.clone(),
                        };
                        tokio::spawn(async move {
                            let _ = client.submit_survey_answer(&session_id, request).await;
                        });
                        self.survey = None;
                        let target = self.prev_state.unwrap_or(AppState::Idle);
                        self.transition(target);
                    }
                    SurveyAction::Skip => {
                        let session_id = self.session_id.clone();
                        let client = self.client.clone();
                        let survey_id = survey.survey_id.clone();
                        tokio::spawn(async move {
                            let _ = client.skip_survey(&session_id, &survey_id).await;
                        });
                        self.survey = None;
                        let target = self.prev_state.unwrap_or(AppState::Idle);
                        self.transition(target);
                    }
                }
            }
        }
        false
    }

    /// Open the full-screen background-agent dashboard. No-op with a hint if no
    /// agents have run this session.
    pub(crate) fn open_agents_dashboard(&mut self) {
        if !self.agents.has_entries() {
            self.toasts.push(
                "No agents have run yet".into(),
                crate::components::toast::ToastLevel::Info,
            );
            return;
        }
        let count = self.agents.entry_count();
        if self.agents_dashboard_selected >= count {
            self.agents_dashboard_selected = count.saturating_sub(1);
        }
        if self.state.can_transition_to(AppState::AgentsDashboard) {
            self.transition(AppState::AgentsDashboard);
        } else {
            self.toasts.push(
                "Cannot open the agent dashboard right now".into(),
                crate::components::toast::ToastLevel::Warning,
            );
        }
    }

    /// Close the dashboard, returning to whichever state opened it.
    pub(super) fn close_agents_dashboard(&mut self) {
        let target = match self.prev_state {
            Some(AppState::Processing) => AppState::Processing,
            _ => AppState::Idle,
        };
        self.transition(target);
    }

    /// Cancel the currently-selected running agent via the backend and reflect it
    /// optimistically in the dashboard.
    pub(super) fn cancel_selected_agent(&mut self) {
        let idx = self.agents_dashboard_selected;
        if !self.agents.is_cancellable(idx) {
            self.toasts.push(
                "Selected agent is not running".into(),
                crate::components::toast::ToastLevel::Info,
            );
            return;
        }
        if let Some(id) = self.agents.agent_id_at(idx) {
            let client = self.client.clone();
            let target = id.clone();
            tokio::spawn(async move {
                let _ = client.cancel_agent(&target).await;
            });
            self.agents.mark_cancelled(&id);
            self.toasts.push(
                format!("Cancelling agent {}", id),
                crate::components::toast::ToastLevel::Warning,
            );
        }
    }

    pub(super) fn open_command_palette(&mut self) {
        let items: Vec<PaletteItem> = self
            .command_entries
            .iter()
            .map(|c| PaletteItem {
                name: c.name.clone(),
                description: c.description.clone(),
                category: c.category.clone().unwrap_or_default(),
            })
            .collect();

        // Add built-in commands
        let mut all_items = vec![
            PaletteItem { name: "help".into(), description: "Show help".into(), category: "system".into() },
            PaletteItem { name: "clear".into(), description: "Clear chat".into(), category: "system".into() },
            PaletteItem { name: "models".into(), description: "Browse models".into(), category: "system".into() },
            PaletteItem { name: "sessions".into(), description: "Browse sessions".into(), category: "system".into() },
            PaletteItem { name: "theme".into(), description: "Switch theme".into(), category: "system".into() },
            PaletteItem { name: "exit".into(), description: "Quit".into(), category: "system".into() },
        ];
        all_items.extend(items);

        self.palette.open(all_items);
        self.transition(AppState::Palette);
    }
}
