use crossterm::event::{Event as CrosstermEvent, KeyCode, KeyEventKind, KeyModifiers};
use tracing::warn;

use super::App;
use crate::app::state::AppState;
use crate::components::{AppAction, Component, ComponentAction};
use crate::event::Event;

/// True only when a pasted string is entirely one-or-more existing filesystem
/// paths (drag-drop of files or a copied path), as opposed to ordinary text.
/// Ordinary prose — even prose that happens to contain a word matching a
/// filename — returns false so it is inserted as text rather than hijacked into
/// an attachment chip.
fn paste_is_file_paths(text: &str) -> bool {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return false;
    }
    // Whole paste is a single existing path (handles paths containing spaces).
    if std::path::Path::new(trimmed).exists() {
        return true;
    }
    // Otherwise accept only when EVERY whitespace/newline-separated token is an
    // existing path (multi-file drag-drop). A single non-path token means text.
    let mut tokens = trimmed.split_whitespace();
    let mut any = false;
    for tok in &mut tokens {
        any = true;
        if !std::path::Path::new(tok).exists() {
            return false;
        }
    }
    any
}

impl App {
    /// Main update function. Returns true if the app should quit.
    pub fn update(&mut self, event: Event) -> bool {
        match event {
            Event::Terminal(CrosstermEvent::Resize(w, h)) => {
                self.width = w;
                self.height = h;
                self.recompute_layout();
                false
            }
            Event::Terminal(CrosstermEvent::Key(key))
                if key.kind == KeyEventKind::Press =>
            {
                self.handle_key(key)
            }
            Event::Terminal(CrosstermEvent::Key(_)) => false, // ignore Release/Repeat
            // Mouse events are not captured (the host terminal owns wheel scroll).
            Event::Terminal(CrosstermEvent::Paste(text)) => {
                // Route paste to onboarding wizard if active
                if self.state == AppState::Onboarding {
                    if let Some(ref mut wizard) = self.onboarding {
                        wizard.handle_paste(&text);
                    }
                } else if self.state == AppState::ModelPicker
                    && self
                        .model_picker
                        .as_ref()
                        .map(|p| p.is_key_entry())
                        .unwrap_or(false)
                {
                    // Paste-friendly API key entry on the picker's key screen.
                    if let Some(ref mut picker) = self.model_picker {
                        picker.handle_paste(&text);
                    }
                } else if self.state.allows_input() {
                    // Drag-drop / a pasted file path becomes an attachment chip
                    // instead of raw text — but ONLY when the paste is entirely
                    // existing file path(s). Ordinary text (even text that happens
                    // to contain a word matching a filename) is inserted as-is.
                    if paste_is_file_paths(&text) && self.ingest_paste_as_attachments(&text) {
                        return false;
                    }
                    // Char-boundary-safe cap: truncate_str floors to a UTF-8
                    // boundary and returns the whole string when under the limit,
                    // so a large multi-byte paste can never slice mid-char.
                    let capped = crate::util::truncate_str(&text, super::MAX_MESSAGE_SIZE);

                    let line_count = capped.lines().count();
                    if line_count >= 5 {
                        self.toasts.push(
                            format!("Large paste ({} lines) \u{2014} sent as context", line_count),
                            crate::components::toast::ToastLevel::Info,
                        );
                    }

                    self.input.insert_str(capped);
                }
                false
            }
            Event::Terminal(_) => false,
            Event::Backend(backend_event) => self.handle_backend_event(backend_event),
            Event::Voice(voice_event) => {
                self.handle_voice_event(voice_event);
                false
            }
            Event::Tick => {
                self.handle_tick();
                false
            }
            Event::HealthRetry => {
                self.check_health();
                false
            }
        }
    }

    fn handle_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        // The overdrive confirmation is a modal overlay with the highest key
        // priority — nothing else may run while it awaits a yes/no.
        if self.overdrive_confirm.is_some() {
            return self.handle_overdrive_confirm_key(key);
        }
        // File picker and reasoning selector are overlays that take priority
        // regardless of the current app state.
        if self.file_picker.is_some() {
            return self.handle_file_picker_key(key);
        }
        if self.reasoning_selector.is_some() {
            return self.handle_reasoning_key(key);
        }
        if self.config_editor.is_some() {
            return self.handle_config_editor_key(key);
        }

        match self.state {
            AppState::Quit => self.handle_quit_dialog_key(key),
            AppState::Palette => self.handle_palette_key(key),
            AppState::ModelPicker => self.handle_model_picker_key(key),
            AppState::Sessions => self.handle_session_browser_key(key),
            AppState::Rewind => self.handle_rewind_key(key),
            AppState::Onboarding => self.handle_onboarding_key(key),
            AppState::PlanReview => self.handle_plan_review_key(key),
            AppState::Permissions => self.handle_permissions_key(key),
            AppState::Survey => self.handle_survey_key(key),
            AppState::Idle => self.handle_idle_key(key),
            AppState::Processing => self.handle_processing_key(key),
            AppState::Recording => self.handle_recording_key(key),
            AppState::AgentsDashboard => self.handle_agents_dashboard_key(key),
            _ => false,
        }
    }

    /// Key handling for the full-screen background-agent dashboard.
    /// ↑/↓ (and j/k) move the selection, c/x cancel the selected running agent,
    /// Esc/q close and return to the previous state.
    fn handle_agents_dashboard_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        let count = self.agents.entry_count();
        match (key.code, key.modifiers) {
            (KeyCode::Esc, _) | (KeyCode::Char('q'), KeyModifiers::NONE) => {
                self.close_agents_dashboard();
            }
            (KeyCode::Up, _) | (KeyCode::Char('k'), KeyModifiers::NONE) => {
                if count > 0 && self.agents_dashboard_selected > 0 {
                    self.agents_dashboard_selected -= 1;
                }
            }
            (KeyCode::Down, _) | (KeyCode::Char('j'), KeyModifiers::NONE) => {
                if count > 0 && self.agents_dashboard_selected + 1 < count {
                    self.agents_dashboard_selected += 1;
                }
            }
            (KeyCode::Char('c'), KeyModifiers::NONE)
            | (KeyCode::Char('x'), KeyModifiers::NONE) => {
                self.cancel_selected_agent();
            }
            (KeyCode::Char('c'), KeyModifiers::CONTROL) => {
                self.close_agents_dashboard();
            }
            _ => {}
        }
        false
    }

    /// Advance the tool-permission mode one step (Shift+Tab). OSA's cycle is
    /// `ask → auto-edit → plan → overdrive (full auto) → ask`.
    ///
    /// Every transition notifies the backend (`permission_mode <token>`) so its
    /// enforcement tracks the displayed mode. Entering **overdrive** the first
    /// time on this install pops a red confirm dialog (reusing the QuitConfirm
    /// pattern); once acknowledged it enters directly. Overdrive keeps
    /// `config.skip_permissions`, the sidebar indicator, and the backend
    /// `dangerous_mode` toggle in lockstep so it converges with `/yolo`.
    fn cycle_permission_mode(&mut self) {
        let prev = self.status.permission_mode();
        let next = prev.next();

        // Entering overdrive: gate behind a one-time confirmation.
        if next.is_overdrive() {
            if self.overdrive_acked() {
                self.enter_overdrive();
            } else {
                // Park the request behind the confirm dialog; keep the current
                // mode on screen until the user decides.
                self.overdrive_prev_mode = prev;
                self.overdrive_confirm =
                    Some(crate::dialogs::overdrive_confirm::OverdriveConfirm::new());
            }
            return;
        }

        // Leaving overdrive: clear the bypass state + tell the backend.
        if prev.is_overdrive() {
            self.config.skip_permissions = false;
            self.sidebar.set_yolo_mode(false);
            self.spawn_backend_command("dangerous_mode", "off");
        }

        self.status.set_permission_mode(next);
        self.spawn_backend_command("permission_mode", next.backend_token());
        self.toasts.push(
            format!("Permission mode: {}", next.title()),
            crate::components::toast::ToastLevel::Info,
        );
        self.announce_a11y(&format!("permission mode: {}", next.short_title()));
    }

    /// Commit to overdrive (full auto): mode + bypass flag + sidebar + backend
    /// `dangerous_mode on`, with a loud red warning toast. Shared by the
    /// confirm-accept path and the already-acked fast path.
    pub(crate) fn enter_overdrive(&mut self) {
        use crate::components::status_bar::PermissionMode;
        self.status.set_permission_mode(PermissionMode::BypassPermissions);
        self.config.skip_permissions = true;
        self.sidebar.set_yolo_mode(true);
        self.spawn_backend_command("dangerous_mode", "on");
        self.spawn_backend_command("permission_mode", "overdrive");
        self.toasts.push(
            "Overdrive (full auto) ON — every tool runs without prompts".into(),
            crate::components::toast::ToastLevel::Warning,
        );
        self.announce_a11y("permission mode: overdrive full auto, no prompts");
    }

    /// Path to the one-shot overdrive acknowledgement marker (per install/profile).
    fn overdrive_ack_path(&self) -> std::path::PathBuf {
        self.config.profile_dir.join(".overdrive_ack")
    }

    /// Whether the user has already confirmed overdrive once on this install.
    pub(crate) fn overdrive_acked(&self) -> bool {
        self.overdrive_ack_path().exists()
    }

    /// Persist the overdrive acknowledgement so the confirm only shows once.
    fn set_overdrive_acked(&self) {
        let path = self.overdrive_ack_path();
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = std::fs::write(path, b"acknowledged\n");
    }

    /// Handle a key while the overdrive confirmation overlay is open.
    fn handle_overdrive_confirm_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        if let Some(dialog) = self.overdrive_confirm.as_mut() {
            if let Some(decision) = dialog.handle_key(key) {
                self.overdrive_confirm = None;
                if decision {
                    self.set_overdrive_acked();
                    self.enter_overdrive();
                } else {
                    // Cancelled — revert to whatever mode was active before.
                    let prev = self.overdrive_prev_mode;
                    self.status.set_permission_mode(prev);
                    self.toasts.push(
                        "Overdrive cancelled".into(),
                        crate::components::toast::ToastLevel::Info,
                    );
                }
            }
        }
        false
    }

    /// Fire-and-forget backend command that must NOT disturb the UI state
    /// (unlike `execute_backend_command`, which flips into Processing). Used for
    /// lightweight mode toggles on every Shift+Tab.
    pub(crate) fn spawn_backend_command(&self, command: &str, arg: &str) {
        let client = self.client.clone();
        let session_id = self.session_id.clone();
        let req = crate::client::types::CommandExecuteRequest {
            command: command.to_string(),
            arg: arg.to_string(),
            session_id,
        };
        tokio::spawn(async move {
            let _ = client.execute_command(&req).await;
        });
    }

    fn handle_idle_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        // Any non-Esc key breaks a pending double-Esc pair so a stale first Esc
        // can never combine with a much later one.
        if key.code != KeyCode::Esc {
            self.esc_tracker.reset();
        }

        // Shift+Tab cycles the tool-permission mode (Default → AcceptEdits →
        // Plan → BypassPermissions → Default), matching Claude Code.
        if crate::app::keys::is_permission_cycle(&key) {
            self.cycle_permission_mode();
            return false;
        }

        let input_empty = self.input.is_empty();

        match (key.code, key.modifiers) {
            // Esc — context-appropriate cancel, with a time-gated double-press
            // chord. Single Esc: clear the composer when it holds text (Claude
            // Code semantics); no-op when empty. Double Esc (two within the
            // window, no key between): open the rewind / jump-to-previous-message
            // picker — OSA's equivalent of Claude Code's "press esc twice to go
            // up a few messages". The @-file dropdown, when open, gets the Esc
            // first (dismiss) and never starts a chord.
            (KeyCode::Esc, _) => {
                if self.input.file_search_active() {
                    self.input
                        .handle_event(&Event::Terminal(CrosstermEvent::Key(key)));
                    self.esc_tracker.reset();
                    return false;
                }
                let now = std::time::Instant::now();
                if self.esc_tracker.press(now) {
                    // Completed a double-Esc → open the rewind picker.
                    self.load_rewind_checkpoints();
                } else if !input_empty {
                    self.input.reset();
                    self.recompute_layout();
                    self.toasts.push(
                        "Input cleared \u{2014} press Esc again to edit a previous message".into(),
                        crate::components::toast::ToastLevel::Info,
                    );
                } else {
                    self.toasts.push(
                        "Press Esc again to edit a previous message".into(),
                        crate::components::toast::ToastLevel::Info,
                    );
                }
                false
            }
            // ? on empty input — open the keyboard-shortcut / help overlay
            // (Claude Code '?'). With text already present it inserts a literal
            // '?' via the composer (the fall-through arm), so typing a question
            // mark mid-message still works.
            (KeyCode::Char('?'), m)
                if input_empty
                    && (m == KeyModifiers::NONE || m == KeyModifiers::SHIFT) =>
            {
                self.show_help();
                false
            }
            (KeyCode::Char('c'), KeyModifiers::CONTROL) if input_empty => {
                self.transition(AppState::Quit);
                false
            }
            (KeyCode::Char('c'), KeyModifiers::CONTROL) => {
                self.input.reset();
                false
            }
            (KeyCode::Char('d'), KeyModifiers::CONTROL) if input_empty => true,
            (KeyCode::F(1), _) => {
                self.show_help();
                false
            }
            (KeyCode::Char('v'), KeyModifiers::ALT) => {
                self.start_recording();
                false
            }
            (KeyCode::F(9), _) => {
                self.toggle_hands_free();
                false
            }
            (KeyCode::Char('n'), KeyModifiers::CONTROL) => {
                self.create_session();
                false
            }
            // Ctrl+V — paste from the system clipboard directly (via arboard).
            // Complements the terminal's bracketed paste, which mouse-capture and
            // some paste methods (middle-click, right-click) don't deliver.
            (KeyCode::Char('v'), KeyModifiers::CONTROL) if self.state.allows_input() => {
                // An image on the clipboard becomes an [Image #N] attachment chip.
                if self.ingest_clipboard_image() {
                    return false;
                }
                match arboard::Clipboard::new().and_then(|mut cb| cb.get_text()) {
                    Ok(text) if !text.is_empty() => {
                        // A copied file path attaches instead of inserting text —
                        // but only when the whole paste is existing file path(s).
                        if paste_is_file_paths(&text) && self.ingest_paste_as_attachments(&text) {
                            return false;
                        }
                        let capped: String =
                            text.chars().take(super::MAX_MESSAGE_SIZE).collect();
                        let lines = capped.lines().count();
                        self.input.insert_str(&capped);
                        if lines >= 5 {
                            self.toasts.push(
                                format!("Pasted {} lines", lines),
                                crate::components::toast::ToastLevel::Info,
                            );
                        }
                    }
                    Ok(_) => {
                        self.toasts.push(
                            "Clipboard is empty".into(),
                            crate::components::toast::ToastLevel::Info,
                        );
                    }
                    Err(e) => {
                        // Surface the failure instead of silently doing nothing, so
                        // clipboard access problems are diagnosable.
                        self.toasts.push(
                            format!("Paste failed: {} (try Ctrl+Shift+V)", e),
                            crate::components::toast::ToastLevel::Warning,
                        );
                    }
                }
                false
            }
            (KeyCode::Char('l'), KeyModifiers::CONTROL) => {
                self.config.sidebar_enabled = !self.config.sidebar_enabled;
                let _ = self.config.save();
                self.recompute_layout();
                false
            }
            (KeyCode::Char('k'), KeyModifiers::CONTROL) => {
                // Empty input: open the command palette. Otherwise let the composer
                // handle Ctrl+K (kill-to-end-of-line) so both bindings coexist.
                if input_empty {
                    self.open_command_palette();
                } else {
                    self.input
                        .handle_event(&Event::Terminal(CrosstermEvent::Key(key)));
                }
                false
            }
            // / on empty input — type '/' into input to trigger inline completions
            (KeyCode::Char('/'), KeyModifiers::NONE) if input_empty => {
                self.input
                    .handle_event(&Event::Terminal(CrosstermEvent::Key(key)));
                false
            }
            (KeyCode::Char('o'), KeyModifiers::CONTROL) => {
                if self.agents.is_active() {
                    self.agents.toggle_collapse();
                    self.recompute_layout();
                } else {
                    self.chat.toggle_last_tool_expand(self.width);
                }
                false
            }
            // Chat scrolling is delegated to the host terminal's native
            // scrollback (mouse wheel / terminal keybindings). `j`/`k`/`u`/`d`,
            // Page/Home/End fall through to the input editor.
            (KeyCode::Char('y'), KeyModifiers::NONE) if input_empty => {
                self.copy_last_message();
                false
            }
            // Ctrl+R on an empty composer expands the last tool result inline
            // (parity with Claude Code's verbose-expand). With text present it
            // falls through to the composer's reverse-i-search, so both survive.
            (KeyCode::Char('r'), KeyModifiers::CONTROL) if input_empty => {
                self.chat.toggle_last_tool_expand(self.width);
                false
            }
            // '@' is handled inline by the composer (fuzzy file/dir mention
            // dropdown) — let it fall through to the input rather than opening a
            // separate modal, so the path is inserted in place.
            _ => {
                let action =
                    self.input
                        .handle_event(&Event::Terminal(CrosstermEvent::Key(key)));
                // The input may have grown or shrunk (Shift+Enter newline, paste,
                // clear) — recompute so the box height tracks the content instead
                // of staying stuck at its previous size.
                self.recompute_layout();
                match action {
                    ComponentAction::Emit(AppAction::Submit(text)) => {
                        self.submit_input(&text);
                        false
                    }
                    _ => false,
                }
            }
        }
    }

    fn handle_processing_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        // Shift+Tab cycles the permission mode even mid-turn, matching Claude Code.
        if crate::app::keys::is_permission_cycle(&key) {
            self.cycle_permission_mode();
            return false;
        }

        match (key.code, key.modifiers) {
            (KeyCode::Esc, _) => {
                self.cancel_processing();
                false
            }
            (KeyCode::Char('c'), KeyModifiers::CONTROL) => {
                let now = std::time::Instant::now();
                if let Some(last) = self.last_cancel_attempt {
                    if now.duration_since(last) < std::time::Duration::from_millis(1000) {
                        self.cancel_processing();
                        return false;
                    }
                }
                self.last_cancel_attempt = Some(now);
                self.toasts.push(
                    "Press Ctrl+C again to interrupt".into(),
                    crate::components::toast::ToastLevel::Warning,
                );
                false
            }
            (KeyCode::Char('b'), KeyModifiers::CONTROL) => {
                self.background_task();
                false
            }
            (KeyCode::Char('o'), KeyModifiers::CONTROL) => {
                if self.agents.is_active() {
                    self.agents.toggle_collapse();
                    self.recompute_layout();
                } else {
                    self.chat.toggle_last_tool_expand(self.width);
                }
                false
            }
            // Ctrl+R on an empty composer expands the last tool result (parity
            // with Ctrl+O / CC verbose-expand); with text it reaches reverse-search.
            (KeyCode::Char('r'), KeyModifiers::CONTROL) if self.input.is_empty() => {
                self.chat.toggle_last_tool_expand(self.width);
                false
            }
            (KeyCode::Char('l'), KeyModifiers::CONTROL) => {
                self.config.sidebar_enabled = !self.config.sidebar_enabled;
                let _ = self.config.save();
                self.recompute_layout();
                false
            }
            // Chat scrolling is delegated to the host terminal's native scrollback.
            _ => {
                let action =
                    self.input
                        .handle_event(&Event::Terminal(CrosstermEvent::Key(key)));
                // The input may have grown or shrunk (Shift+Enter newline, paste,
                // submit/clear) — recompute so the box height tracks the content
                // instead of staying stuck at its previous size.
                self.recompute_layout();
                match action {
                    ComponentAction::Emit(AppAction::Submit(text)) => {
                        self.submit_input(&text);
                        false
                    }
                    _ => false,
                }
            }
        }
    }

    fn handle_recording_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        match (key.code, key.modifiers) {
            (KeyCode::Enter, _) => {
                self.stop_recording();
                false
            }
            (KeyCode::Char('v'), KeyModifiers::ALT) => {
                self.stop_recording();
                false
            }
            (KeyCode::Esc, _) => {
                self.cancel_recording();
                false
            }
            (KeyCode::Char('c'), KeyModifiers::CONTROL) => {
                self.cancel_recording();
                false
            }
            _ => false,
        }
    }

    fn handle_voice_event(&mut self, event: crate::event::VoiceEvent) {
        use crate::event::VoiceEvent;
        match event {
            VoiceEvent::TranscriptionReady(text) => {
                self.status.clear_download_progress();
                self.status.set_transcribing(false);
                let trimmed = text.trim();
                let is_hands_free = self.voice.hands_free;

                if trimmed.is_empty() {
                    self.toasts.push(
                        "No speech detected".into(),
                        crate::components::toast::ToastLevel::Warning,
                    );
                } else if is_hands_free {
                    // Hands-free: auto-submit the transcribed text
                    self.input.insert_str(trimmed);
                    self.submit_input(trimmed);
                    self.input.reset();
                } else if trimmed.starts_with('/') {
                    // Auto-submit slash commands without review
                    self.input.insert_str(trimmed);
                    self.submit_input(trimmed);
                    self.input.reset();
                } else {
                    self.input.insert_str(&text);
                    self.toasts.push(
                        "Voice transcribed \u{2014} review and press Enter".into(),
                        crate::components::toast::ToastLevel::Info,
                    );
                }
                if self.state == AppState::Recording {
                    self.transition(AppState::Idle);
                }

                // Hands-free: auto-restart recording after a brief delay
                if is_hands_free {
                    let tx = self.event_tx.clone();
                    tokio::spawn(async move {
                        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                        // Send a tick to trigger recording restart
                        let _ = tx.send(crate::event::Event::Voice(
                            crate::event::VoiceEvent::HandsFreeRestart,
                        ));
                    });
                }
            }
            VoiceEvent::TranscriptionError(err) => {
                self.status.clear_download_progress();
                self.status.set_transcribing(false);
                if err.contains("whisper-cli not found") || err.contains("whisper not found") {
                    self.toasts.push(
                        "Install: brew install whisper-cpp (or set VOICE_PROVIDER=cloud)".into(),
                        crate::components::toast::ToastLevel::Error,
                    );
                } else {
                    self.toasts.push(
                        format!("Voice error: {}", err),
                        crate::components::toast::ToastLevel::Error,
                    );
                }
                if self.state == AppState::Recording {
                    self.transition(AppState::Idle);
                }
            }
            VoiceEvent::RecordingStopped => {
                self.stop_recording();
            }
            VoiceEvent::DownloadProgress { label, downloaded, total } => {
                let pct = if total > 0 {
                    ((downloaded as f64 / total as f64) * 100.0).min(100.0) as u8
                } else {
                    0
                };
                self.status.set_download_progress(&label, pct);
                self.toasts.push(
                    format!("Downloading whisper model: {}%", pct),
                    crate::components::toast::ToastLevel::Info,
                );
            }
            VoiceEvent::AudioLevel(level) => {
                self.status.set_audio_level((level * 100.0).clamp(0.0, 100.0) as u8);
            }
            VoiceEvent::HandsFreeRestart => {
                if self.voice.hands_free && !self.voice.recording {
                    self.start_recording();
                }
            }
        }
    }

    fn handle_tick(&mut self) {
        self.toasts.tick();
        self.activity.tick();
        self.agents.tick();
        self.task_checklist.tick();

        // Poll audio level and elapsed time from active voice capture
        if self.voice.recording {
            self.status.set_recording_elapsed(self.voice.elapsed_secs());
            if let Some(ref capture) = self.voice.capture {
                let level = capture.level();
                self.status.set_audio_level(level);

                // Hands-free VAD: auto-stop on sustained silence
                if self.voice.hands_free {
                    if level < 5 {
                        // Silence detected — start or continue tracking
                        if self.voice.silence_start.is_none() {
                            self.voice.silence_start = Some(std::time::Instant::now());
                        }
                        if let Some(silence_start) = self.voice.silence_start {
                            let silence_dur = silence_start.elapsed();
                            let recorded_secs = self.voice.elapsed_secs();
                            if silence_dur >= std::time::Duration::from_millis(1500)
                                && recorded_secs >= 1
                            {
                                // Enough silence after meaningful audio — auto-stop
                                self.stop_recording();
                            }
                        }
                    } else {
                        // Sound detected — reset silence tracker
                        self.voice.silence_start = None;
                    }
                }
            }
        }

        if self.state.is_processing() {
            if let Some(start) = self.processing_start {
                let ms = start.elapsed().as_millis() as u64;
                self.sidebar.set_elapsed_ms(ms);
            }
        }

        if self.state.is_processing() {
            if let Some(start) = self.processing_start {
                let elapsed = start.elapsed();
                let timeout_secs = self.config.request_timeout_secs;
                let warning_secs = (timeout_secs * 4) / 5; // 80% threshold

                if elapsed >= std::time::Duration::from_secs(timeout_secs) {
                    warn!("Processing timed out after {}s", timeout_secs);
                    if let Some(cancel) = self.sse_cancel.take() {
                        cancel.cancel();
                    }
                    self.chat.clear_streaming();
                    self.stream_buf.clear();
                    self.thinking_buf.clear();
                    self.agent_header_sent = false;
                    self.activity.stop();
                    self.status.set_active(false);
                    self.transition(AppState::Idle);
                    self.toasts.push(
                        format!("Request timed out ({}m)", timeout_secs / 60),
                        crate::components::toast::ToastLevel::Error,
                    );
                    // If a /goal auto-continue loop was active, the stalled turn
                    // silently kills it. Clear the (now-stale) goal indicator and
                    // tell the user, rather than leaving a misleading "◎ goal N/max".
                    if self.goal.is_some() {
                        self.chat.add_system_message(
                            "Goal auto-continue stopped: the turn timed out before completing. Use /goal <text> to resume.",
                            "warning",
                        );
                        self.clear_goal(false);
                    }
                    self.start_sse();
                } else if elapsed >= std::time::Duration::from_secs(warning_secs) {
                    // Fire warning once when crossing the 80% threshold
                    let prev_elapsed =
                        elapsed.saturating_sub(std::time::Duration::from_millis(200));
                    if prev_elapsed < std::time::Duration::from_secs(warning_secs) {
                        let remaining = timeout_secs.saturating_sub(elapsed.as_secs());
                        let remaining_str = if remaining >= 60 {
                            format!("{}m", remaining / 60)
                        } else {
                            format!("{}s", remaining)
                        };
                        self.toasts.push(
                            format!(
                                "Processing for {}m, timing out in {}",
                                elapsed.as_secs() / 60,
                                remaining_str,
                            ),
                            crate::components::toast::ToastLevel::Warning,
                        );
                    }
                }
            }
        }
    }
}
