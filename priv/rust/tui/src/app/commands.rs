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
            "/resume" => {
                // Like /sessions, but populated from past on-disk sessions
                // (real titles/counts) so a prior conversation can be reloaded.
                self.load_recent_sessions();
            }
            "/continue" => {
                // Directory-scoped resume: reload this folder's saved session.
                self.continue_session();
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
                self.force_onboarding();
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
                self.status.set_permission_mode(if self.config.skip_permissions {
                    crate::components::status_bar::PermissionMode::BypassPermissions
                } else {
                    crate::components::status_bar::PermissionMode::Default
                });
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
            "/voice" => {
                let label = format!("{:?}", self.voice.provider);
                self.toasts.push(
                    format!("Voice: {}", label),
                    crate::components::toast::ToastLevel::Info,
                );
            }
            "/status" => {
                let model = self.header.model_name();
                let tools = self.header.tool_count();
                let ctx = self.status.context_utilization();
                let msg = format!(
                    "Model: {} | Tools: {} | Context: {:.0}% | Session: {}",
                    model, tools, ctx * 100.0, self.session_id
                );
                self.chat.add_system_message(&msg, "status");
            }
            "/goal" => {
                // Cross-turn keep-going: agent auto-continues toward a stated
                // goal until it replies DONE, the cap is hit, or it's cleared.
                if arg.is_empty() {
                    self.show_goal_status();
                } else if arg.eq_ignore_ascii_case("off")
                    || arg.eq_ignore_ascii_case("stop")
                    || arg.eq_ignore_ascii_case("clear")
                {
                    self.clear_goal(true);
                } else {
                    self.set_goal(arg);
                }
            }
            "/new" => {
                // Create a new session
                self.chat.clear();
                let client = self.client.clone();
                let tx = self.event_tx.clone();
                tokio::spawn(async move {
                    match client.create_session(None).await {
                        Ok(resp) => {
                            let _ = tx.send(Event::Backend(BackendEvent::SessionCreated(Ok(resp))));
                        }
                        Err(e) => {
                            let _ = tx.send(Event::Backend(BackendEvent::SessionCreated(Err(e.to_string()))));
                        }
                    }
                });
                self.toasts.push(
                    "New session started".into(),
                    crate::components::toast::ToastLevel::Info,
                );
            }
            "/channels" | "/ch" => {
                self.execute_backend_command("channels", "status");
            }
            "/memory" | "/mem" => {
                self.execute_backend_command("memory", arg);
            }
            "/doctor" => {
                self.execute_backend_command("doctor", "");
            }
            "/config" => {
                self.toasts.push(
                    "Config: ~/.osa/.env | Run 'osa setup' to reconfigure".into(),
                    crate::components::toast::ToastLevel::Info,
                );
            }
            "/desktop" | "/gui" => {
                // Send to backend — it handles finding and launching the Tauri app
                self.execute_backend_command("desktop", arg);
                self.toasts.push(
                    "Launching OSA Desktop...".to_string(),
                    crate::components::toast::ToastLevel::Info,
                );
            }
            "/context" => {
                // Fetch token-usage breakdown and render a compact summary in chat.
                self.show_context();
            }
            "/compact" => {
                // Trigger proactive compaction on the live loop now.
                self.toasts.push(
                    "Compacting context...".into(),
                    crate::components::toast::ToastLevel::Info,
                );
                self.do_compact();
            }
            "/recap" => {
                // Ask the backend for a short LLM summary of the session so far.
                self.toasts.push(
                    "Summarizing session...".into(),
                    crate::components::toast::ToastLevel::Info,
                );
                self.do_recap();
            }
            "/fork" => {
                // Fork the current session into a new one preserving history.
                self.toasts.push(
                    "Forking session...".into(),
                    crate::components::toast::ToastLevel::Info,
                );
                self.do_fork();
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

    /// GET /sessions/:id/context → render a compact token-usage summary in chat.
    fn show_context(&self) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        let sid = self.session_id.clone();
        tokio::spawn(async move {
            let event = match client.get_context(&sid).await {
                Ok(c) => {
                    let pct = if c.max_tokens > 0 {
                        (c.used_tokens as f64 / c.max_tokens as f64) * 100.0
                    } else {
                        0.0
                    };
                    let output = format!(
                        "Context: {}/{} tokens ({:.0}%)\n  conversation: {}\n  system: {}\n  tool results: {}",
                        c.used_tokens,
                        c.max_tokens,
                        pct,
                        c.conversation_tokens,
                        c.system_tokens,
                        c.tool_result_tokens
                    );
                    BackendEvent::CommandResult(Ok(crate::client::types::CommandExecuteResponse {
                        kind: "info".into(),
                        output,
                        action: None,
                    }))
                }
                Err(e) => BackendEvent::CommandResult(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    /// POST /sessions/:id/compact → trigger proactive compaction, confirm in chat.
    fn do_compact(&self) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        let sid = self.session_id.clone();
        tokio::spawn(async move {
            let event = match client.compact_session(&sid).await {
                Ok(r) => {
                    let output = format!(
                        "Context compacted: {} → {} messages (~{} → ~{} tokens)",
                        r.messages_before, r.messages_after, r.tokens_before, r.tokens_after
                    );
                    BackendEvent::CommandResult(Ok(crate::client::types::CommandExecuteResponse {
                        kind: "info".into(),
                        output,
                        action: None,
                    }))
                }
                Err(e) => BackendEvent::CommandResult(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    /// GET /sessions/:id/recap → render a short LLM summary of the session in chat.
    fn do_recap(&self) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        let sid = self.session_id.clone();
        tokio::spawn(async move {
            let event = match client.recap_session(&sid).await {
                Ok(r) => BackendEvent::CommandResult(Ok(
                    crate::client::types::CommandExecuteResponse {
                        kind: "info".into(),
                        output: format!("Recap:\n{}", r.recap),
                        action: None,
                    },
                )),
                Err(e) => BackendEvent::CommandResult(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    /// POST /sessions/:id/fork → fork into a new session and switch the TUI to it.
    /// Reuses the SessionCreated handler (status "resumed" pulls the seeded
    /// transcript back in) so history is preserved on screen.
    fn do_fork(&self) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        let sid = self.session_id.clone();
        tokio::spawn(async move {
            let event = match client.fork_session(&sid).await {
                Ok(resp) => BackendEvent::SessionCreated(Ok(resp)),
                Err(e) => BackendEvent::SessionCreated(Err(e.to_string())),
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
