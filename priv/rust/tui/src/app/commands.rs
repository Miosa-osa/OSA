use super::App;
use crate::app::state::AppState;
use crate::event::backend::BackendEvent;
use crate::event::Event;

/// Built-in slash commands the TUI handles (name WITHOUT the leading `/`, plus a
/// one-line description). This is the authoritative discovery list for the
/// inline `/` completions popup and the Ctrl+K palette: it seeds the popup at
/// startup so `/` works immediately (even before — or without — the backend
/// `GET /commands` response), and is merged with the backend registry so a
/// TUI-only affordance is always listed. Names are slash-less because the
/// completions layer prepends the `/` itself.
pub(crate) const BUILTIN_SLASH_COMMANDS: &[(&str, &str)] = &[
    ("help", "Show the command menu"),
    ("clear", "Clear the conversation view"),
    ("model", "Switch the active model"),
    ("models", "Browse and pick a model"),
    ("sessions", "Browse sessions"),
    ("resume", "Resume a past session"),
    ("continue", "Resume this folder's last session"),
    ("session", "Show or switch session"),
    ("new", "Start a fresh session"),
    ("skill", "List, run, enable, or disable a skill"),
    ("steer", "Redirect the agent mid-turn (queues if idle)"),
    ("bg", "List background turns (Ctrl+B backgrounds one)"),
    ("fg", "Bring a backgrounded turn to the foreground"),
    ("agents", "Background-agent dashboard"),
    ("rewind", "Restore code/conversation from a checkpoint"),
    ("fork", "Fork this session, keeping history"),
    ("compact", "Compact the conversation to free context"),
    ("recap", "Summarize the session so far"),
    ("context", "Show the token-usage breakdown"),
    ("cost", "Show cost & token accounting"),
    ("status", "Show model, tools, context, session"),
    ("usage", "Show session context usage"),
    ("tools", "Show how many tools are available"),
    ("version", "Show the OSA version"),
    ("reasoning", "Set the reasoning effort level"),
    ("verbose", "Cycle tool output detail"),
    ("theme", "Switch the color theme"),
    ("keybindings", "Show the keybinding map + config file"),
    ("config", "Open the settings editor"),
    ("goal", "Set an auto-continue goal loop"),
    ("auto", "Toggle the safety-guardian auto mode"),
    ("overdrive", "Toggle overdrive (full auto)"),
    ("yolo", "Toggle overdrive (full auto)"),
    ("memory", "Save or recall a memory"),
    ("channels", "Show channel connectivity"),
    ("doctor", "Run backend diagnostics"),
    ("permissions", "View and manage permission rules"),
    ("hooks", "View registered + settings hooks"),
    ("add-dir", "Allow file access in an additional directory"),
    ("trust", "Show or accept workspace trust"),
    ("desktop", "Open the desktop GUI"),
    ("retry", "Re-send the last prompt"),
    ("undo", "Drop the last exchange"),
    ("setup", "Re-run the setup wizard"),
    ("a11y", "Toggle screen-reader mode"),
    ("login", "Authenticate with the backend"),
    ("logout", "Sign out"),
    ("voice", "Show the voice provider"),
    ("exit", "Quit OSA"),
    ("quit", "Quit OSA"),
];

/// Built-in slash commands as owned `(name, description)` pairs (name WITHOUT the
/// leading `/`), for seeding the inline completions popup at startup.
pub(crate) fn builtin_slash_commands() -> Vec<(String, String)> {
    BUILTIN_SLASH_COMMANDS
        .iter()
        .map(|(n, d)| (n.to_string(), d.to_string()))
        .collect()
}

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
                self.enter_overlay(AppState::Quit);
            }
            "/help" => {
                // Open the interactive, filterable command menu (the Ctrl+K
                // palette) rather than dumping a static wall of text — the menu
                // IS the help. The full keyboard-shortcut reference is still on
                // the `?` key for anyone who wants the printed cheatsheet.
                self.open_command_palette();
            }
            "/skill" | "/skills" => {
                // Skills are backend-managed (list / run / create). Route the
                // verb + args straight to the backend skill command; empty args
                // list available skills.
                self.execute_backend_command("skill", arg);
            }
            "/clear" => {
                // Local transcript reset...
                self.chat.clear();
                self.tasks.clear();
                self.transcript_log.clear();
                self.attachments.clear();
                // ...AND a backend context reset (POST /sessions/:id/clear).
                // Without it the model still carries the "cleared" context —
                // CC commands/clear/conversation.ts parity. Failure surfaces
                // as a CommandResult error toast so the user knows the model
                // may still remember.
                let client = self.client.clone();
                let tx = self.event_tx.clone();
                let sid = self.session_id.clone();
                tokio::spawn(async move {
                    if let Err(e) = client.clear_session(&sid).await {
                        let _ = tx.send(Event::Backend(BackendEvent::CommandResult(Err(
                            format!(
                                "/clear: backend reset failed ({}) \u{2014} the model may still remember earlier context",
                                e
                            ),
                        ))));
                    }
                });
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
            "/keybindings" => {
                let path = self.config.profile_dir.join("keybindings.json");
                let mut msg = format!(
                    "Keybindings file: {}\nFormat: [{{\"context\": \"global|idle|processing\", \"bindings\": {{\"ctrl+n\": \"app:newSession\"}}}}]\nUse \"none\" to unbind; values starting with / run that slash command.\nCurrent bindings:\n{}",
                    path.display(),
                    self.keymap.describe(),
                );
                for w in self.keymap.load_warnings() {
                    msg.push_str(&format!("\nwarning: {}", w));
                }
                self.chat.add_system_message(&msg, "info");
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
                self.toasts.push(
                    "Signed out".into(),
                    crate::components::toast::ToastLevel::Info,
                );
            }
            "/bg" => {
                // List backgrounded turns with live/done status. Backgrounding
                // (Ctrl+B) keeps the turn running on the backend; `/fg` brings
                // the most recent running one back to the foreground.
                if self.bg_tasks.is_empty() {
                    self.toasts.push(
                        "No background tasks — Ctrl+B backgrounds the running turn".into(),
                        crate::components::toast::ToastLevel::Info,
                    );
                } else {
                    let mut out = String::from("Background tasks:");
                    for t in &self.bg_tasks {
                        let (mark, state) = if t.done {
                            ("\u{2713}", "done") // ✓
                        } else {
                            ("\u{25CF}", "running") // ●
                        };
                        out.push_str(&format!(
                            "\n  {} [{}] {} ({})",
                            mark, t.id, t.summary, state
                        ));
                    }
                    if self.bg_running_count() > 0 {
                        out.push_str("\n  /fg brings the most recent running turn back");
                    }
                    self.chat.add_system_message(&out, "info");
                }
            }
            "/fg" | "/foreground" => {
                // Bring the most recent still-running background turn back to the
                // foreground activity view (BG -> FG return path).
                self.foreground_task();
            }
            "/agents" => {
                // Open the full-screen background-agent dashboard (running +
                // background subagents grouped by state).
                self.open_agents_dashboard();
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
            "/a11y" | "/screenreader" | "/screen-reader" => {
                // Toggle screen-reader (plain-text) mode. Accepts an explicit
                // on/off arg, otherwise flips the current state.
                let on = match arg.to_ascii_lowercase().as_str() {
                    "on" | "true" | "1" | "yes" => true,
                    "off" | "false" | "0" | "no" => false,
                    _ => !self.activity.a11y(),
                };
                self.activity.set_a11y(on);
                self.config.a11y = on;
                let _ = self.config.save();
                let msg = if on {
                    "Screen reader mode: on — plain-text status, spinner disabled"
                } else {
                    "Screen reader mode: off — rich activity display restored"
                };
                // Announce as a plain scrollback line (a screen reader reads this),
                // and also toast for sighted users.
                self.chat.add_system_message(msg, "info");
                self.toasts
                    .push(msg.to_string(), crate::components::toast::ToastLevel::Info);
            }
            "/overdrive" | "/yolo" | "/dangerous" => {
                // Overdrive (full auto) toggle. Turning ON the first time on this
                // install routes through the one-time red confirm (shared with the
                // Shift+Tab cycle); afterward it enters directly. Turning OFF
                // returns to ask mode and notifies the backend.
                if self.status.permission_mode().is_overdrive() {
                    self.status.set_permission_mode(
                        crate::components::status_bar::PermissionMode::Default,
                    );
                    self.config.skip_permissions = false;
                    self.sidebar.set_yolo_mode(false);
                    self.spawn_backend_command("dangerous_mode", "off");
                    self.toasts.push(
                        "Overdrive OFF — permission prompts enabled".into(),
                        crate::components::toast::ToastLevel::Warning,
                    );
                    self.announce_a11y("permission mode: ask (permission prompts enabled)");
                } else if self.overdrive_acked() {
                    self.enter_overdrive();
                } else {
                    self.overdrive_prev_mode = self.status.permission_mode();
                    self.overdrive_confirm =
                        Some(crate::dialogs::overdrive_confirm::OverdriveConfirm::new());
                }
            }
            "/auto" => {
                // Toggle the backend "auto" permission tier + safety guardian.
                // The guardian auto-approves safe actions and pauses on dangerous
                // ones for review. Mirrors /yolo but for the Auto mode.
                use crate::components::status_bar::PermissionMode;
                let turning_on = self.status.permission_mode() != PermissionMode::Auto;
                if turning_on {
                    self.status.set_permission_mode(PermissionMode::Auto);
                    // Auto is not a full bypass — keep skip_permissions/YOLO off.
                    self.config.skip_permissions = false;
                    self.sidebar.set_yolo_mode(false);
                } else {
                    self.status.set_permission_mode(PermissionMode::Default);
                }
                let state = if turning_on {
                    "ON — guardian auto-approves safe actions, pauses on dangerous ones"
                } else {
                    "OFF — back to default permission prompts"
                };
                self.toasts.push(
                    format!("Auto mode: {}", state),
                    crate::components::toast::ToastLevel::Info,
                );
                self.announce_a11y(if turning_on {
                    "permission mode: auto (guardian auto-approves safe actions)"
                } else {
                    "permission mode: default (permission prompts enabled)"
                });
                // Notify backend to toggle the auto permission tier.
                self.execute_backend_command("auto_mode", if turning_on { "on" } else { "off" });
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
                    // Accept direct level: /reasoning off|low|medium|high|max.
                    // Validate BEFORE dispatch — execute_reasoning_command
                    // optimistically stamps the status line with the level, so
                    // an unvalidated typo would display a bogus effort while
                    // the backend rejects it.
                    let lvl = arg.to_ascii_lowercase();
                    if matches!(lvl.as_str(), "off" | "low" | "medium" | "high" | "max") {
                        self.execute_reasoning_command(&lvl);
                    } else {
                        self.chat.add_system_message(
                            "Usage: /reasoning off|low|medium|high|max",
                            "warning",
                        );
                    }
                }
            }
            "/voice" => {
                let label = format!("{:?}", self.voice.provider);
                self.toasts.push(
                    format!("Voice: {}", label),
                    crate::components::toast::ToastLevel::Info,
                );
            }
            "/version" => {
                // Version from the single build-time source (tag-stamped or Cargo
                // semver). Rendered into scrollback so it stays visible.
                self.chat.add_system_message(
                    &format!("OSA {}", crate::config::osa_version_display()),
                    "info",
                );
                self.toasts.push(
                    format!("OSA {}", crate::config::osa_version_display()),
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
                // Backend diagnostics — rendered into chat via CommandResult.
                self.execute_backend_command("doctor", "");
            }
            "/cost" => {
                // Cost & token accounting (Budget.get_status) — rendered into chat
                // via CommandResult, matching the CLI breakdown.
                self.execute_backend_command("cost", "");
            }
            "/config" => {
                // Open the unified full-screen settings editor.
                self.open_config_editor();
            }
            "/desktop" | "/gui" => {
                // Send to backend — it finds and launches the desktop app and
                // reports the REAL outcome via CommandResult. No eager toast:
                // it used to claim "Launching..." even when the backend had no
                // desktop handler at all and the app was not installed.
                self.execute_backend_command("desktop", arg);
            }
            "/context" => {
                // Fetch token-usage breakdown and render a compact summary in chat.
                self.show_context();
            }
            "/compact" => {
                // Trigger proactive compaction on the live loop now. An optional
                // argument becomes custom summarization instructions (CC parity:
                // `/compact <instructions>`).
                self.toasts.push(
                    "Compacting context...".into(),
                    crate::components::toast::ToastLevel::Info,
                );
                self.do_compact(arg);
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
            "/rewind" => {
                // Open the rewind dialog: restore code / conversation / both from
                // a checkpoint snapshotted before an earlier prompt.
                self.load_rewind_checkpoints();
            }
            _ => {
                // Unknown slash command -> send to backend
                let cmd_name = &cmd[1..]; // strip leading /
                self.execute_backend_command(cmd_name, arg);
            }
        }
    }

    /// Announce a state change as a plain scrollback line, but only in
    /// screen-reader mode (sighted users already get toasts / rich chrome).
    /// Keeps the reader informed of permission-mode and similar transitions.
    pub(crate) fn announce_a11y(&mut self, msg: &str) {
        if self.activity.a11y() {
            self.chat.add_system_message(msg, "info");
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

    /// POST /sessions/:id/compact → trigger proactive compaction, confirm in
    /// chat. A non-empty `instructions` string is threaded into the summary
    /// prompt (CC `/compact <instructions>` parity).
    fn do_compact(&self, instructions: &str) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        let sid = self.session_id.clone();
        let instructions = instructions.to_string();
        tokio::spawn(async move {
            let event = match client.compact_session(&sid, &instructions).await {
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

    pub(crate) fn execute_backend_command(&mut self, command: &str, arg: &str) {
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
