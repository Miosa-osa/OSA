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
    ("model", "Choose a provider, then one of its models"),
    ("models", "Pick a model from the current provider"),
    ("provider", "Choose a provider — connect an account or paste a key"),
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
    ("revert", "Restore files N mutating-tool steps ago (transcript kept)"),
    ("fork", "Fork this session, keeping history"),
    ("compact", "Compact the conversation to free context"),
    ("recap", "Summarize the session so far"),
    ("context", "Show the token-usage breakdown"),
    ("cost", "Show cost & token accounting"),
    ("status", "Show model, tools, context, session"),
    ("usage", "Show account quota and token usage"),
    ("tools", "Show how many tools are available"),
    ("version", "Show the OSA version"),
    ("update", "Update OSA to the latest version"),
    ("reasoning", "Set the reasoning effort level"),
    ("verbose", "Cycle tool output detail"),
    ("lean", "Lean view — print the model's words, not its tool calls"),
    ("theme", "Switch the color theme"),
    ("keybindings", "Show the keybinding map + config file"),
    ("config", "Open the settings editor"),
    ("goal", "Set an auto-continue goal loop"),
    ("auto", "Toggle the safety-guardian auto mode"),
    ("overdrive", "Toggle overdrive (full auto)"),
    ("yolo", "Toggle overdrive (full auto)"),
    ("coordinator", "Toggle coordinator mode (delegation only)"),
    ("ask-user", "Let the agent ask you questions mid-task (off by default)"),
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
    ("login", "Connect a provider account"),
    ("logout", "Sign out of a provider account"),
    ("voice", "Show the voice provider"),
    (
        "jailbreak",
        "LIBERATE the model — operator override on every system prompt",
    ),
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
                // Bare command opens the branded skills browser; a verb
                // (run/enable/disable/create…) routes to the backend as before.
                if arg.is_empty() && !self.activity.a11y() {
                    self.open_skills_browser();
                } else {
                    self.execute_backend_command("skill", arg);
                }
            }
            "/clear" => {
                // Local transcript reset...
                self.chat.clear();
                self.tasks.clear();
                self.transcript_log.clear();
                // The re-layout store is a second thing that can put a message
                // back on screen, so it clears with the rest. Leaving it would
                // resurrect the whole conversation on the next resize.
                self.committed.clear();
                self.welcome_banner = None;
                crate::app::exit_dump::clear();
                self.attachments.clear();
                // ...including everything that can PUT A MESSAGE BACK.
                //
                // `/clear` cleared what was on screen and nothing that could
                // repaint it. The queue was the visible half: prompts typed
                // during a turn are held in `message_queue` and rendered as dim
                // rows directly above the composer, so after the transcript and
                // the real scrollback were purged, the top of an otherwise empty
                // screen showed the user's own last message back at them —
                // reported as "it showed me the duplicate of the thing at the
                // top". It was not a duplicate and not a rendering artefact: it
                // was a live queue entry that `/clear` had no opinion about,
                // still waiting to be sent. The user retyped the message because
                // the thing on screen was never in the composer to begin with.
                //
                // `last_submitted_prompt` is the same hazard by another route —
                // the interrupt path re-inserts it into the composer when the
                // queue is empty, which after a clear would resurrect a prompt
                // from the conversation the user just discarded.
                self.message_queue.clear();
                self.input.set_queued_items(Vec::new());
                self.last_submitted_prompt = None;
                // Per-turn accumulators. A clear that leaves these behind lets a
                // half-streamed reply from the old context finish rendering into
                // the new one.
                self.assistant_stream.reset();
                self.thinking_buf.clear();
                self.agent_header_sent = false;
                // The context meter measures the model's context, which the
                // backend swap has just emptied — so it reads 0 until the next
                // turn reports a real figure. Leaving it alone (what it did)
                // meant the bar kept showing the discarded conversation's usage,
                // which is the one number a user checks to confirm a clear
                // actually happened.
                self.status.note_input_tokens(0);
                self.status.set_pending_input_tokens(0);
                self.sidebar.set_context(0.0);
                // In inline mode the finalized transcript lives in the real
                // terminal scrollback (each message was flushed there via
                // insert_before), which the clears above never touch. Signal
                // the event loop (which owns the terminal) to purge the real
                // scrollback and re-prime the inline viewport on its next
                // iteration, or /clear looks like it silently did nothing.
                self.pending_clear = true;
                // ...AND a backend context reset (POST /sessions/:id/clear).
                // Without it the model still carries the "cleared" context —
                // CC commands/clear/conversation.ts parity. Failure surfaces
                // as a CommandResult error toast so the user knows the model
                // may still remember.
                let client = self.client.clone();
                let tx = self.event_tx.clone();
                let sid = self.session_id.clone();
                tokio::spawn(async move {
                    match client.clear_session(&sid).await {
                        // The clear SWAPPED sessions — adopt the id the backend
                        // returned. Routed through the existing `SessionCreated`
                        // handler because adopting an id is never just a field
                        // write: it also has to reconnect SSE to the new stream
                        // and drop the old session's title. Dropping this
                        // response (which is what the code did) left the TUI
                        // talking to the stopped session, whose history the
                        // backend then reloaded from disk — see `clear_session`.
                        Ok(resp) => {
                            let _ = tx.send(Event::Backend(BackendEvent::SessionCreated(Ok(resp))));
                        }
                        Err(e) => {
                            let _ = tx.send(Event::Backend(BackendEvent::CommandResult(Err(
                                format!(
                                    "/clear: backend reset failed ({}) \u{2014} the model may still remember earlier context",
                                    e
                                ),
                            ))));
                        }
                    }
                });
                self.toasts.push(
                    "Chat cleared".into(),
                    crate::components::toast::ToastLevel::Info,
                );
            }
            "/theme" => {
                if arg.is_empty() {
                    // Open the picker with a live palette swatch. A direct
                    // `/theme <name>` still applies without the overlay.
                    self.open_theme_picker();
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
                // Open the scrollable key→action viewer. a11y path keeps the
                // flat scrollback dump a screen reader can consume.
                if self.activity.a11y() {
                    let path = self.config.profile_dir.join("keybindings.json");
                    let mut msg = format!(
                        "Keybindings file: {}\nCurrent bindings:\n{}",
                        path.display(),
                        self.keymap.describe(),
                    );
                    for w in self.keymap.load_warnings() {
                        msg.push_str(&format!("\nwarning: {}", w));
                    }
                    self.chat.add_system_message(&msg, "info");
                } else {
                    self.open_keybindings_viewer();
                }
            }
            // `/models` and `/model` used to be the same command. They now
            // name different things: `/models` is "the models I can pick right
            // now", `/model` (and `/provider`) is "which provider".
            "/models" => {
                self.models_jump_pending = true;
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
            // `/provider` is an ALIAS for the `/model` surface, not a second
            // dialog. The picker is already provider-first — you choose a
            // provider, then a model — so a distinct command would be a near
            // duplicate of the same screen and a second thing to keep in sync.
            // It exists because "provider" is the word users reach for when
            // they want to change *who* is serving the model rather than
            // which model, and a capability nobody can name is not shipped.
            "/provider" | "/providers" => {
                self.load_models();
            }
            // `/login` opens the provider surface — the place account sign-in
            // actually happens — instead of the backend's JWT handshake.
            //
            // The JWT login is machinery: the TUI performs it automatically at
            // boot, and a user typing `/login` has never once meant "re-issue
            // my local API token". They mean "sign in to a provider", and
            // pointing the verb at the internal handshake is why `/login`
            // read as doing nothing. With a provider named, go straight to it.
            "/login" => {
                if arg.is_empty() {
                    self.load_models();
                } else {
                    self.execute_backend_command("login", arg);
                }
            }
            // Routed to the backend so the REPL, `osa auth logout` and this
            // share one implementation (`CLI.Auth`) and cannot disagree about
            // who is signed in. `--all` is handled there too.
            "/logout" => {
                self.execute_backend_command("logout", arg);
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
            "/lean" => {
                // Lean view: print what the model SAYS, not the machinery it
                // used. Same shape as `/a11y` above — an explicit on/off arg,
                // else a flip — because it is the same KIND of thing: a
                // client-side display preference, persisted in `tui.json`.
                //
                // Only tool cells are affected. Errors, loop-guard and control
                // text (the `Loop.TerminalSource` distinction) and permission
                // prompts are structurally out of reach of the filter; see
                // `Chat::push_scrollback_block`.
                let on = match arg.to_ascii_lowercase().as_str() {
                    "on" | "true" | "1" | "yes" | "enable" => true,
                    "off" | "false" | "0" | "no" | "disable" => false,
                    _ => !self.chat.lean(),
                };
                self.chat.set_lean(on);
                self.config.lean = on;
                let _ = self.config.save();
                // The confirmation says "from here on" and it means it.
                // Finalized rows went out through `insert_before`, which writes
                // into the terminal's OWN scrollback at the width they were
                // wrapped at; nothing in this process can reach back and repaint
                // them. A message implying the screen had been cleaned up would
                // be a quiet lie, and turning the mode OFF cannot resurrect the
                // cells it hid either — ctrl+o is where those live.
                let msg = if on {
                    "Lean view: on \u{2014} tool calls hidden from here on. \
                     The model's words and its reasoning still show, as do errors \
                     and permission prompts; ctrl+o for the full transcript."
                } else {
                    "Lean view: off \u{2014} tool calls shown from here on. \
                     Already-hidden calls stay in ctrl+o only."
                };
                self.chat.add_system_message(msg, "info");
                self.toasts.push(
                    if on {
                        "Lean view: on".to_string()
                    } else {
                        "Lean view: off".to_string()
                    },
                    crate::components::toast::ToastLevel::Info,
                );
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
            "/coordinator" => {
                // Toggle the coordinator posture: the backend restricts the tool
                // surface to delegation and messaging only. Applied in place on
                // the live session (no restart). An explicit on/off arg is passed
                // through; otherwise the backend flips the current state. The chip
                // and toast are driven by the coordinator_mode event the backend
                // echoes back, so the UI reflects the AUTHORITATIVE server state.
                let verb = match arg.to_ascii_lowercase().as_str() {
                    "on" | "true" | "1" | "yes" => "on",
                    "off" | "false" | "0" | "no" => "off",
                    _ => "toggle",
                };
                self.execute_backend_command("coordinator", verb);
            }
            "/ask-user" => {
                // May the agent stop mid-task and ask a question? OFF by default,
                // everywhere — an unattended run that parks on a question nobody
                // answers is the failure this exists to remove.
                //
                // Unlike /coordinator there is NO toggle verb: a bare `/ask-user`
                // reports the current state instead of flipping it. Whether the
                // agent can interrupt you is not something to find out by
                // accident. The chip and toast come from the backend's
                // `ask_user_mode` echo, so the UI shows the authoritative state.
                let verb = match arg.to_ascii_lowercase().as_str() {
                    "on" | "true" | "1" | "yes" | "enable" => "on",
                    "off" | "false" | "0" | "no" | "disable" => "off",
                    _ => "status",
                };
                self.execute_backend_command("ask-user", verb);
            }
            "/tools" => {
                // Fetch the full tool list and open the searchable browser when
                // it arrives (ToolsLoaded handler checks tools_browser_pending).
                self.open_tools_browser();
            }
            "/jailbreak" => {
                // Backend-owned state (`~/.osa/jailbreak.json`), backend-run
                // command — but the badge must flip the instant the answer
                // lands, not a second later on the next poll. Invalidate the
                // TUI's cache before dispatch so the post-result poll reads
                // the fresh file, and keep the palette/popup entry pointing
                // here (see BUILTIN_SLASH_COMMANDS).
                crate::components::jailbreak::invalidate();
                self.execute_backend_command("jailbreak", arg);
            }
            "/usage" => {
                // Account quota + OSA's own token count, rendered by the
                // backend into chat. This used to be a toast showing context
                // utilisation, which is a different number entirely: context
                // is how full this conversation is, not what the plan has
                // left. `/context` is still the command for the former.
                self.execute_backend_command("usage", arg);
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
                    // Accept direct level: /reasoning off|fast|medium|high|xhigh.
                    // Validate BEFORE dispatch — execute_reasoning_command
                    // optimistically stamps the status line with the level, so
                    // an unvalidated typo would display a bogus effort while
                    // the backend rejects it.
                    let lvl = arg.to_ascii_lowercase();
                    if matches!(lvl.as_str(), "off" | "fast" | "medium" | "high" | "xhigh" | "ultra") {
                        self.execute_reasoning_command(&lvl);
                    } else {
                        self.chat.add_system_message(
                            "Usage: /reasoning off|fast|medium|high|xhigh|ultra",
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
                // Open the branded status dashboard overlay (model/provider,
                // context gauge, tools, permission mode, session, version). The
                // a11y path still gets a flat scrollback line since a screen
                // reader can't see the overlay.
                if self.activity.a11y() {
                    let msg = format!(
                        "Model: {} | Tools: {} | Context: {:.0}% | Mode: {} | Session: {}",
                        self.header.model_name(),
                        self.header.tool_count(),
                        self.status.context_utilization() * 100.0,
                        self.status.permission_mode().title(),
                        self.session_id
                    );
                    self.chat.add_system_message(&msg, "status");
                } else if self.state.can_transition_to(AppState::Status) {
                    self.enter_overlay(AppState::Status);
                }
            }
            "/goal" => {
                // Cross-turn keep-going, anchored on the BACKEND. Every form —
                // status, pause/resume, clear, and `<text> [:: <criteria>]` —
                // goes to `GoalTracker`; the TUI only drives turns while the
                // backend still reports the goal active. See
                // `App::dispatch_goal_command`.
                self.dispatch_goal_command(arg);
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
                if self.activity.a11y() {
                    self.execute_backend_command("channels", "status");
                } else {
                    self.open_channels_panel();
                }
            }
            "/trust" => {
                // Open the workspace-trust dialog (fetches GET /workspace/trust
                // then opens on TrustLoaded). a11y keeps the flat backend text.
                if self.activity.a11y() {
                    self.execute_backend_command("trust", arg);
                } else {
                    self.open_trust_dialog();
                }
            }
            "/memory" | "/mem" => {
                // Bare command opens the browser; a subcommand (save/search/
                // recall <x>) routes to the backend.
                if arg.is_empty() && !self.activity.a11y() {
                    self.open_memory_browser();
                } else {
                    self.execute_backend_command("memory", arg);
                }
            }
            "/tasks" => {
                if self.activity.a11y() {
                    self.execute_backend_command("tasks", arg);
                } else {
                    self.open_tasks_panel();
                }
            }
            "/metrics" => {
                if self.activity.a11y() {
                    self.execute_backend_command("metrics", arg);
                } else {
                    self.open_metrics_dashboard();
                }
            }
            "/persona" => {
                // Bare opens the picker; `/persona <name>` switches directly.
                if arg.is_empty() && !self.activity.a11y() {
                    self.open_persona_picker();
                } else {
                    self.execute_backend_command("persona", arg);
                }
            }
            "/sandbox" => {
                if arg.is_empty() && !self.activity.a11y() {
                    self.open_sandbox_picker();
                } else {
                    self.execute_backend_command("sandbox", arg);
                }
            }
            "/doctor" => {
                // Backend diagnostics — rendered into chat via CommandResult.
                self.execute_backend_command("doctor", "");
            }
            "/cost" => {
                // Branded cost dashboard (spend + tokens + sessions); a11y keeps
                // the flat CLI breakdown in chat.
                if self.activity.a11y() {
                    self.execute_backend_command("cost", "");
                } else {
                    self.open_cost_dashboard();
                }
            }
            "/permissions" => {
                if self.activity.a11y() {
                    self.execute_backend_command("permissions", arg);
                } else {
                    self.open_permissions_manager();
                }
            }
            "/hooks" => {
                if self.activity.a11y() {
                    self.execute_backend_command("hooks", arg);
                } else {
                    self.open_hooks_viewer();
                }
            }
            "/mcp" => {
                // Previously had NO handler (fell through to unknown-command).
                self.open_mcp_servers();
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
                // a11y: flat chat summary. Otherwise: open the segmented
                // breakdown overlay once the fetch returns (ContextLoaded).
                if self.activity.a11y() {
                    self.show_context();
                } else {
                    self.open_context_breakdown();
                }
            }
            "/compact" => {
                // Trigger proactive compaction on the live loop now. An optional
                // argument becomes custom summarization instructions (CC parity:
                // `/compact <instructions>`).
                // Show the running indicator OPTIMISTICALLY rather than toasting.
                // The backend's `compaction_started` says the same thing a moment
                // later; a toast plus a spinner both reading "Compacting" is the
                // same fact twice. Starting the spinner here instead makes the
                // acknowledgement instant AND persistent for the whole (often
                // multi-minute) run. `compaction_completed` / `compaction_failed`
                // clear it; so does the turn ending, so a dropped SSE connection
                // cannot strand it on screen forever.
                if !self.activity.is_active() {
                    self.activity.start();
                }
                self.activity.set_waiting_reason(Some(
                    crate::components::activity::WaitingReason::Compacting,
                ));
                self.recompute_layout();
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
            "/revert" => {
                match arg {
                    "list" | "ls" => self.do_step_revert_list(),
                    "" => {
                        let output = "Usage: /revert N  (restore files N mutating-tool steps ago)\n       /revert list".to_string();
                        self.toasts.push(
                            output,
                            crate::components::toast::ToastLevel::Info,
                        );
                    }
                    other => match other.parse::<u32>() {
                        Ok(n) if n >= 1 => self.do_step_revert(n),
                        _ => self.toasts.push(
                            "Usage: /revert N  (N is a positive integer)".into(),
                            crate::components::toast::ToastLevel::Warning,
                        ),
                    },
                }
            }
            "/update" => {
                // Self-update via the installed `osa` launcher's rollback-safe
                // staged updater. Runs in the background (non-blocking, cancel-
                // safe): input stays live, phases stream in as toasts, and the
                // final result reports the new version + a relaunch reminder.
                // The swap only takes effect on the next launch, so we never try
                // to hot-swap the running binary.
                self.start_self_update();
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

    fn do_step_revert_list(&self) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        let sid = self.session_id.clone();
        tokio::spawn(async move {
            let event = match client.list_step_snapshots(&sid).await {
                Ok(msg) => BackendEvent::CommandResult(Ok(
                    crate::client::types::CommandExecuteResponse {
                        kind: "info".into(),
                        output: msg,
                        action: None,
                        command: "revert".into(),
                        effort: None,
                        goal: None,
                    },
                )),
                Err(e) => BackendEvent::CommandResult(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    fn do_step_revert(&self, steps: u32) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        let sid = self.session_id.clone();
        tokio::spawn(async move {
            let event = match client.revert_steps(&sid, steps).await {
                Ok(msg) => BackendEvent::CommandResult(Ok(
                    crate::client::types::CommandExecuteResponse {
                        kind: "info".into(),
                        output: msg,
                        action: None,
                        command: "revert".into(),
                        effort: None,
                        goal: None,
                    },
                )),
                Err(e) => BackendEvent::CommandResult(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    pub(crate) fn switch_model(&self, provider: &str, model: &str) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        let sid = self.session_id.clone();
        let provider = provider.to_string();
        let model = model.to_string();
        tokio::spawn(async move {
            let req = crate::client::types::ModelSwitchRequest {
                provider: provider.clone(),
                model: model.clone(),
                // User-initiated picker: make the choice sticky so a new session
                // or restart keeps it instead of reverting to the boot default.
                persist: true,
            };
            // Session-scoped: hot-swaps the LIVE session's Loop GenServer so
            // the very next turn in THIS conversation actually uses the new
            // model. The old `/api/v1/models/switch` call only updated
            // process-wide defaults — the UI would show "Model: x/y" and the
            // header/status bar would update, but the running session kept
            // silently calling the previous provider until it was recreated.
            let result = client.switch_session_model(&sid, &req).await;
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
                        "Context: {}/{} tokens ({:.0}%)\n  conversation: {}\n  system: {}\n  tool schemas: {}\n  tool results: {}",
                        c.used_tokens,
                        c.max_tokens,
                        pct,
                        c.conversation_tokens,
                        c.system_tokens,
                        c.tool_schema_tokens,
                        c.tool_result_tokens
                    );
                    BackendEvent::CommandResult(Ok(crate::client::types::CommandExecuteResponse {
                        kind: "info".into(),
                        output,
                        action: None,
                        command: "context".into(),
                        effort: None,
                        goal: None,
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
                    // The success line is NOT written here. A real compaction
                    // broadcasts `compaction_started`/`compaction_completed` on
                    // the session topic, and the SSE handler renders the
                    // spinner and the `✓ Compacted …` line from those. Printing
                    // the HTTP result too would report the same event twice.
                    //
                    // The one case the events cannot cover: the backend
                    // declines to compact because history is already below the
                    // "worth an LLM round-trip" floor. It returns unchanged
                    // counts and emits nothing — so without this branch,
                    // `/compact` would appear to do nothing at all. Say so.
                    if r.messages_before == r.messages_after
                        && r.tokens_before == r.tokens_after
                    {
                        BackendEvent::CommandResult(Ok(
                            crate::client::types::CommandExecuteResponse {
                                kind: "info".into(),
                                output: "Nothing to compact — the conversation is \
                                         already below the compaction threshold."
                                    .into(),
                                action: None,
                                command: "compact".into(),
                                effort: None,
                                goal: None,
                            },
                        ))
                    } else {
                        return;
                    }
                }
                // Transport/HTTP failures never produce a backend event, so this
                // is the only place the user would hear about them.
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
                        command: "recap".into(),
                        effort: None,
                        goal: None,
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

    /// The same wire call as [`Self::execute_backend_command`], without the turn
    /// chrome.
    ///
    /// The end-of-turn goal liveness check is not a turn. Flipping to
    /// `Processing` and starting the activity spinner for it would paint a turn
    /// that is not happening, and the `Idle` landing on the way out would fight
    /// the real turn its answer is about to start.
    pub(crate) fn execute_backend_command_quiet(&mut self, command: &str, arg: &str) {
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

#[cfg(test)]
mod tests {
    use super::BUILTIN_SLASH_COMMANDS;

    #[test]
    fn update_command_is_registered() {
        // `/update` must be discoverable in the completions popup / palette.
        let entry = BUILTIN_SLASH_COMMANDS
            .iter()
            .find(|(name, _)| *name == "update");
        assert!(
            entry.is_some(),
            "`update` missing from BUILTIN_SLASH_COMMANDS"
        );
        assert_eq!(entry.unwrap().1, "Update OSA to the latest version");
    }

    #[test]
    fn coordinator_command_is_registered() {
        // `/coordinator` must be discoverable in the completions popup / palette.
        let entry = BUILTIN_SLASH_COMMANDS
            .iter()
            .find(|(name, _)| *name == "coordinator");
        assert!(
            entry.is_some(),
            "`coordinator` missing from BUILTIN_SLASH_COMMANDS"
        );
        assert_eq!(entry.unwrap().1, "Toggle coordinator mode (delegation only)");
    }

    #[test]
    fn ask_user_command_is_registered() {
        // `/ask-user` must be discoverable, and its description must say the
        // default out loud. An operator who cannot see that questions are OFF
        // will read a session that never asks as a broken agent.
        let entry = BUILTIN_SLASH_COMMANDS
            .iter()
            .find(|(name, _)| *name == "ask-user");
        assert!(
            entry.is_some(),
            "`ask-user` missing from BUILTIN_SLASH_COMMANDS"
        );
        assert!(
            entry.unwrap().1.contains("off by default"),
            "the /ask-user description must state the default"
        );
    }
}
