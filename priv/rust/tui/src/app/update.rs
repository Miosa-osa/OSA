use crossterm::event::{Event as CrosstermEvent, KeyCode, KeyEventKind, KeyModifiers};
use tracing::warn;

use super::App;
use crate::app::state::AppState;
use crate::components::{AppAction, Component, ComponentAction};
use crate::event::Event;

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
                    // instead of raw text.
                    if self.ingest_paste_as_attachments(&text) {
                        return false;
                    }
                    let capped = if text.len() > super::MAX_MESSAGE_SIZE {
                        &text[..super::MAX_MESSAGE_SIZE]
                    } else {
                        &text
                    };

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
        // File picker and reasoning selector are overlays that take priority
        // regardless of the current app state.
        if self.file_picker.is_some() {
            return self.handle_file_picker_key(key);
        }
        if self.reasoning_selector.is_some() {
            return self.handle_reasoning_key(key);
        }

        match self.state {
            AppState::Quit => self.handle_quit_dialog_key(key),
            AppState::Palette => self.handle_palette_key(key),
            AppState::ModelPicker => self.handle_model_picker_key(key),
            AppState::Sessions => self.handle_session_browser_key(key),
            AppState::Onboarding => self.handle_onboarding_key(key),
            AppState::PlanReview => self.handle_plan_review_key(key),
            AppState::Permissions => self.handle_permissions_key(key),
            AppState::Survey => self.handle_survey_key(key),
            AppState::Idle => self.handle_idle_key(key),
            AppState::Processing => self.handle_processing_key(key),
            AppState::Recording => self.handle_recording_key(key),
            _ => false,
        }
    }

    /// Advance the tool-permission mode one step (Shift+Tab). Mirrors Claude
    /// Code's cycle: Default → AcceptEdits → Plan → BypassPermissions → Default.
    ///
    /// The status line reflects the active mode. Reaching BypassPermissions
    /// keeps `config.skip_permissions` and the sidebar YOLO indicator in sync so
    /// the display is internally consistent with `/yolo`. Full backend
    /// enforcement (dangerous-mode sync, AcceptEdits auto-approve of edit
    /// prompts, Plan read-only gating) is not wired yet — those modes currently
    /// change only the displayed state; `/yolo` remains the authoritative bypass
    /// control that notifies the backend.
    fn cycle_permission_mode(&mut self) {
        use crate::components::status_bar::PermissionMode;
        let prev = self.status.permission_mode();
        let next = prev.next();
        self.status.set_permission_mode(next);

        // Keep the sidebar YOLO indicator consistent with the bypass display.
        let bypass = matches!(next, PermissionMode::BypassPermissions);
        self.config.skip_permissions = bypass;
        self.sidebar.set_yolo_mode(bypass);

        // Sync the backend "auto" permission tier / safety guardian with the UI
        // so enforcement matches what's displayed. Toggle on when entering Auto,
        // off when leaving it (mirrors how /yolo notifies dangerous-mode).
        let entering_auto = matches!(next, PermissionMode::Auto);
        let leaving_auto = matches!(prev, PermissionMode::Auto) && !entering_auto;
        if entering_auto {
            self.execute_backend_command("auto_mode", "on");
        } else if leaving_auto {
            self.execute_backend_command("auto_mode", "off");
        }

        self.toasts.push(
            format!("Permission mode: {}", next.title()),
            crate::components::toast::ToastLevel::Info,
        );
    }

    fn handle_idle_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        // Shift+Tab cycles the tool-permission mode (Default → AcceptEdits →
        // Plan → BypassPermissions → Default), matching Claude Code.
        if crate::app::keys::is_permission_cycle(&key) {
            self.cycle_permission_mode();
            return false;
        }

        let input_empty = self.input.is_empty();

        match (key.code, key.modifiers) {
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
                        // A copied file path attaches instead of inserting text.
                        if self.ingest_paste_as_attachments(&text) {
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
                self.open_command_palette();
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
            // @ key: open file picker to insert a file path into input
            (KeyCode::Char('@'), KeyModifiers::NONE) => {
                self.open_file_picker();
                false
            }
            _ => {
                let action =
                    self.input
                        .handle_event(&Event::Terminal(CrosstermEvent::Key(key)));
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
