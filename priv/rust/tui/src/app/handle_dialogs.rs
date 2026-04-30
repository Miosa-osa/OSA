use crate::app::state::AppState;
use crate::dialogs::command_palette::PaletteItem;
use crate::dialogs::permissions::PermissionRequest;
use crate::dialogs::DialogAction;
use crate::event::backend::BackendEvent;
use crate::event::Event;
use tracing::{debug, warn};

use super::App;

impl App {
    pub(super) fn show_permission_request(&mut self, request: PermissionRequest) {
        if !request.has_request_id() {
            warn!(
                "Ignoring permission request for tool '{}' with empty request_id",
                request.tool_name
            );
            self.toasts.push(
                "Ignored permission request with missing id".into(),
                crate::components::toast::ToastLevel::Warning,
            );
            return;
        }

        if self.state == AppState::Permissions && self.permissions.is_some() {
            debug!(
                "Queueing permission request {} while another dialog is active",
                request.request_id
            );
            self.permission_queue.push_back(request);
            return;
        }

        if !self.state.can_transition_to(AppState::Permissions)
            && self.state != AppState::Permissions
        {
            debug!(
                "Queueing permission request {} while app is in {}",
                request.request_id, self.state
            );
            self.permission_queue.push_back(request);
            return;
        }

        self.open_permission_dialog(request);
    }

    fn open_permission_dialog(&mut self, request: PermissionRequest) {
        let mut dialog = crate::dialogs::permissions::Permissions::new();
        dialog.set_request(request);
        self.permissions = Some(dialog);

        if self.state != AppState::Permissions {
            self.transition(AppState::Permissions);
        }
    }

    fn next_queued_permission(&mut self) -> Option<PermissionRequest> {
        while let Some(request) = self.permission_queue.pop_front() {
            if request.has_request_id() {
                return Some(request);
            }

            warn!(
                "Dropping queued permission request for tool '{}' with empty request_id",
                request.tool_name
            );
        }

        None
    }

    fn return_state_after_permissions(&self) -> AppState {
        if matches!(self.prev_state, Some(AppState::Processing)) && self.activity.is_active() {
            AppState::Processing
        } else {
            AppState::Idle
        }
    }

    fn finish_permission_dialog(&mut self) {
        if let Some(request) = self.next_queued_permission() {
            self.open_permission_dialog(request);
            return;
        }

        self.permissions = None;
        if self.state == AppState::Permissions {
            self.transition(self.return_state_after_permissions());
        }
    }

    fn send_permission_response(&self, request_id: String, allowed: bool) {
        if request_id.trim().is_empty() {
            warn!("Skipping permission response with empty request_id");
            return;
        }

        let client = self.client.clone();
        tokio::spawn(async move {
            let _ = client.permission_response(&request_id, allowed).await;
        });
    }

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
        if let Some(ref mut picker) = self.model_picker {
            if let Some(action) = picker.handle_key(key) {
                match action {
                    crate::dialogs::model_picker::ModelPickerAction::Select { provider, model } => {
                        self.transition(AppState::Idle);
                        self.switch_model(&provider, &model);
                    }
                    crate::dialogs::model_picker::ModelPickerAction::Cancel => {
                        self.transition(AppState::Idle);
                    }
                }
                self.model_picker = None;
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
                        self.switch_session(&id);
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
                                    let _ = tx.send(Event::Backend(BackendEvent::CommandResult(
                                        Err(e.to_string()),
                                    )));
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
        if let Some(ref mut review) = self.plan_review {
            if let Some(action) = review.handle_key(key) {
                match action {
                    DialogAction::PlanApprove => {
                        self.transition(AppState::Processing);
                        self.toasts.push(
                            "Plan approved".into(),
                            crate::components::toast::ToastLevel::Info,
                        );
                        let client = self.client.clone();
                        let tx = self.event_tx.clone();
                        let session_id = self.session_id.clone();
                        tokio::spawn(async move {
                            let req = crate::client::types::CommandExecuteRequest {
                                command: "plan_approve".into(),
                                arg: String::new(),
                                session_id,
                            };
                            let event = match client.execute_command(&req).await {
                                Ok(resp) => BackendEvent::CommandResult(Ok(resp)),
                                Err(e) => BackendEvent::CommandResult(Err(e.to_string())),
                            };
                            let _ = tx.send(Event::Backend(event));
                        });
                        self.plan_review = None;
                    }
                    DialogAction::PlanReject => {
                        self.transition(AppState::Idle);
                        self.toasts.push(
                            "Plan rejected".into(),
                            crate::components::toast::ToastLevel::Info,
                        );
                        let client = self.client.clone();
                        let tx = self.event_tx.clone();
                        let session_id = self.session_id.clone();
                        tokio::spawn(async move {
                            let req = crate::client::types::CommandExecuteRequest {
                                command: "plan_reject".into(),
                                arg: String::new(),
                                session_id,
                            };
                            let event = match client.execute_command(&req).await {
                                Ok(resp) => BackendEvent::CommandResult(Ok(resp)),
                                Err(e) => BackendEvent::CommandResult(Err(e.to_string())),
                            };
                            let _ = tx.send(Event::Backend(event));
                        });
                        self.plan_review = None;
                    }
                    DialogAction::PlanEdit => {
                        self.transition(AppState::Idle);
                        self.toasts.push(
                            "Plan edit requested".into(),
                            crate::components::toast::ToastLevel::Info,
                        );
                        let client = self.client.clone();
                        let tx = self.event_tx.clone();
                        let session_id = self.session_id.clone();
                        tokio::spawn(async move {
                            let req = crate::client::types::CommandExecuteRequest {
                                command: "plan_edit".into(),
                                arg: String::new(),
                                session_id,
                            };
                            let event = match client.execute_command(&req).await {
                                Ok(resp) => BackendEvent::CommandResult(Ok(resp)),
                                Err(e) => BackendEvent::CommandResult(Err(e.to_string())),
                            };
                            let _ = tx.send(Event::Backend(event));
                        });
                        self.plan_review = None;
                    }
                    _ => {}
                }
            }
        }
        false
    }

    pub(super) fn handle_permissions_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        if self.permissions.is_some() {
            let action_and_request_id = self.permissions.as_mut().and_then(|dialog| {
                dialog
                    .handle_key(key)
                    .map(|action| (action, dialog.request_id().to_string()))
            });

            if let Some((action, request_id)) = action_and_request_id {
                match action {
                    DialogAction::PermissionAllow => {
                        self.toasts.push(
                            "Permission granted".into(),
                            crate::components::toast::ToastLevel::Info,
                        );
                        self.send_permission_response(request_id, true);
                        self.finish_permission_dialog();
                    }
                    DialogAction::PermissionAllowSession => {
                        self.toasts.push(
                            "Permission granted for session".into(),
                            crate::components::toast::ToastLevel::Info,
                        );
                        self.send_permission_response(request_id, true);
                        self.finish_permission_dialog();
                    }
                    DialogAction::PermissionDeny => {
                        self.toasts.push(
                            "Permission denied".into(),
                            crate::components::toast::ToastLevel::Warning,
                        );
                        self.send_permission_response(request_id, false);
                        self.finish_permission_dialog();
                    }
                    _ => {}
                }
            }
        } else if self.state == AppState::Permissions {
            warn!("Permissions state had no active dialog; recovering");
            self.finish_permission_dialog();
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
                            answers: result
                                .answers
                                .iter()
                                .map(|a| crate::client::types::SurveyAnswerEntry {
                                    question_index: a.question_index,
                                    question_text: a.question_text.clone(),
                                    selected: a.selected.clone(),
                                    free_text: a.free_text.clone(),
                                })
                                .collect(),
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
            PaletteItem {
                name: "help".into(),
                description: "Show help".into(),
                category: "system".into(),
            },
            PaletteItem {
                name: "clear".into(),
                description: "Clear chat".into(),
                category: "system".into(),
            },
            PaletteItem {
                name: "models".into(),
                description: "Browse models".into(),
                category: "system".into(),
            },
            PaletteItem {
                name: "sessions".into(),
                description: "Browse sessions".into(),
                category: "system".into(),
            },
            PaletteItem {
                name: "theme".into(),
                description: "Switch theme".into(),
                category: "system".into(),
            },
            PaletteItem {
                name: "exit".into(),
                description: "Quit".into(),
                category: "system".into(),
            },
        ];
        all_items.extend(items);

        self.palette.open(all_items);
        self.transition(AppState::Palette);
    }
}
