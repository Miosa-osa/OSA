use super::App;
use crate::app::state::AppState;
use crate::event::backend::BackendEvent;
use crate::event::Event;

/// Known providers for /model routing
const KNOWN_PROVIDERS: &[&str] = &[
    "ollama",
    "anthropic",
    "openai",
    "groq",
    "together",
    "fireworks",
    "deepseek",
    "perplexity",
    "mistral",
    "replicate",
    "openrouter",
    "google",
    "cohere",
    "qwen",
    "moonshot",
    "zhipu",
    "volcengine",
    "baichuan",
];

impl App {
    pub fn handle_command(&mut self, input: &str) {
        let parts: Vec<&str> = input.splitn(2, ' ').collect();
        let cmd = parts[0];
        let arg = parts.get(1).unwrap_or(&"").trim();

        match cmd {
            "/exit" | "/quit" => {
                if let Some(cancel) = self.sse_cancel.take() {
                    cancel.cancel();
                }
                self.transition(AppState::Quit);
            }
            "/help" => {
                self.show_help();
            }
            "/clear" => {
                self.chat.clear();
                self.tasks.clear();
                self.toasts.push(
                    "Chat cleared".into(),
                    crate::components::toast::ToastLevel::Info,
                );
            }
            "/theme" => {
                if arg.is_empty() {
                    let themes = crate::style::themes::available().join(", ");
                    self.toasts.push(
                        format!("Themes: {} (current: {})", themes, self.config.theme),
                        crate::components::toast::ToastLevel::Info,
                    );
                } else if let Some(theme) = crate::style::themes::by_name(arg) {
                    self.config.theme = arg.to_string();
                    let _ = self.config.save();
                    crate::style::set_theme(theme);
                    self.toasts.push(
                        format!("Theme: {}", arg),
                        crate::components::toast::ToastLevel::Info,
                    );
                } else {
                    self.toasts.push(
                        format!(
                            "Unknown theme: {}. Available: {}",
                            arg,
                            crate::style::themes::available().join(", ")
                        ),
                        crate::components::toast::ToastLevel::Error,
                    );
                }
            }
            "/models" => {
                self.load_models();
            }
            "/model" => {
                if arg.is_empty() {
                    // No args — open picker
                    self.load_models();
                } else if arg.contains('/') {
                    // provider/model format
                    let parts: Vec<&str> = arg.splitn(2, '/').collect();
                    if parts.len() >= 2 && !parts[1].is_empty() {
                        self.switch_model(parts[0], parts[1]);
                    } else {
                        self.chat.add_system_message(
                            "Usage: /model provider/model_name",
                            "warning",
                        );
                    }
                } else if let Some((first, rest)) = arg.split_once(' ') {
                    if KNOWN_PROVIDERS.contains(&first) {
                        // "/model ollama qwen3:8b" → provider=ollama, model=qwen3:8b
                        self.switch_model(first, rest.trim());
                    } else {
                        // "/model some model" — assume ollama
                        self.switch_model("ollama", arg);
                    }
                } else if KNOWN_PROVIDERS.contains(&arg) {
                    // Just a provider name — open picker filtered to it
                    self.load_models();
                } else {
                    // Bare model name — default to ollama
                    self.switch_model("ollama", arg);
                }
            }
            "/sessions" => {
                self.load_sessions();
            }
            "/session" => {
                if arg.is_empty() {
                    self.toasts.push(
                        format!("Current session: {}", self.session_id),
                        crate::components::toast::ToastLevel::Info,
                    );
                } else if arg == "new" {
                    self.create_session();
                } else {
                    self.switch_session(arg);
                }
            }
            "/login" => {
                let user_id = if arg.is_empty() { None } else { Some(arg) };
                self.do_login_with_user(user_id);
            }
            "/logout" => {
                self.do_logout();
            }
            "/bg" => {
                if self.bg_tasks.is_empty() {
                    self.toasts.push(
                        "No background tasks".into(),
                        crate::components::toast::ToastLevel::Info,
                    );
                } else {
                    let msg = self
                        .bg_tasks
                        .iter()
                        .enumerate()
                        .map(|(i, t)| format!("{}. {}", i + 1, t))
                        .collect::<Vec<_>>()
                        .join(", ");
                    self.toasts.push(msg, crate::components::toast::ToastLevel::Info);
                }
            }
            "/setup" => {
                self.check_onboarding();
            }
            "/verbose" => {
                self.activity.verbosity = self.activity.verbosity.cycle();
                self.toasts.push(
                    format!("Tool verbosity: {}", self.activity.verbosity.label()),
                    crate::components::toast::ToastLevel::Info,
                );
            }
            "/yolo" | "/dangerous" => {
                self.config.skip_permissions = !self.config.skip_permissions;
                let state = if self.config.skip_permissions {
                    "ON — auto-approving all tools"
                } else {
                    "OFF — permission prompts enabled"
                };
                self.sidebar.set_yolo_mode(self.config.skip_permissions);
                self.toasts.push(
                    format!("YOLO mode: {}", state),
                    crate::components::toast::ToastLevel::Warning,
                );
                // Notify backend to toggle dangerous mode
                self.execute_backend_command("dangerous_mode", if self.config.skip_permissions { "on" } else { "off" });
            }
            "/tools" => {
                let count = self.header.tool_count();
                self.toasts.push(
                    format!("{} tools available", count),
                    crate::components::toast::ToastLevel::Info,
                );
            }
            "/usage" => {
                self.toasts.push(
                    format!(
                        "Session: {} | Context: {:.0}%",
                        self.session_id,
                        self.status.context_utilization() * 100.0,
                    ),
                    crate::components::toast::ToastLevel::Info,
                );
            }
            "/retry" => {
                if let Some(last) = self.chat.last_user_message() {
                    self.submit_prompt(&last);
                } else {
                    self.toasts.push(
                        "Nothing to retry".into(),
                        crate::components::toast::ToastLevel::Warning,
                    );
                }
            }
            "/undo" => {
                self.chat.undo_last_exchange();
                self.toasts.push(
                    "Last exchange removed".into(),
                    crate::components::toast::ToastLevel::Info,
                );
            }
            "/reasoning" => {
                if arg.is_empty() {
                    // Open the reasoning level selector dialog
                    self.open_reasoning_selector();
                } else {
                    // Accept direct level: /reasoning off|low|medium|high
                    self.execute_reasoning_command(arg);
                }
            }
            _ => {
                // Unknown slash command -> send to backend
                let cmd_name = &cmd[1..]; // strip leading /
                self.execute_backend_command(cmd_name, arg);
            }
        }
    }

    pub(crate) fn switch_model(&self, provider: &str, model: &str) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        let provider = provider.to_string();
        let model = model.to_string();
        tokio::spawn(async move {
            let req = crate::client::types::ModelSwitchRequest {
                provider: provider.clone(),
                model: model.clone(),
            };
            let result = client.switch_model(&req).await;
            let event = match result {
                Ok(resp) => BackendEvent::ModelSwitched(Ok(resp)),
                Err(e) => BackendEvent::ModelSwitched(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    fn execute_backend_command(&mut self, command: &str, arg: &str) {
        self.transition(AppState::Processing);
        self.activity.start();
        self.status.set_active(true);

        let client = self.client.clone();
        let tx = self.event_tx.clone();
        let req = crate::client::types::CommandExecuteRequest {
            command: command.to_string(),
            arg: arg.to_string(),
            session_id: self.session_id.clone(),
        };
        tokio::spawn(async move {
            let result = client.execute_command(&req).await;
            let event = match result {
                Ok(resp) => BackendEvent::CommandResult(Ok(resp)),
                Err(e) => BackendEvent::CommandResult(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    fn do_login_with_user(&self, user_id: Option<&str>) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        let user = user_id.map(String::from);
        tokio::spawn(async move {
            let result = client.login(user.as_deref()).await;
            let event = match result {
                Ok(resp) => BackendEvent::LoginResult(Ok(resp)),
                Err(e) => BackendEvent::LoginResult(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    fn do_logout(&self) {
        let client = self.client.clone();
        tokio::spawn(async move {
            let _ = client.logout().await;
        });
    }
}
