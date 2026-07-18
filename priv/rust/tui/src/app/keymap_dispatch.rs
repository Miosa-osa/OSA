//! WS10 — action dispatch for the user-configurable keybinding layer.
//!
//! `handle_idle_key` / `handle_processing_key` (update.rs) call
//! [`App::resolve_keymap`] before their remaining hardcoded arms. The resolver
//! consults the loaded [`Keybindings`] map (defaults + `~/.osa/keybindings.json`)
//! with pending multi-step-chord state, then [`App::dispatch_action`] performs
//! the matched action. An action may *decline* in the current state (return
//! `None`) so the key falls through to the composer — e.g. `app:palette` on a
//! non-empty composer yields Ctrl+K back to kill-to-end-of-line.

use crossterm::event::KeyEvent;
use std::time::{Duration, Instant};

use super::App;
use crate::config::keybindings::{format_key_event, Action, Context, Resolution};

/// How long a multi-step chord prefix stays pending before it expires.
const CHORD_TIMEOUT: Duration = Duration::from_secs(3);
/// Confirm window for ctrl+x ctrl+k kill-all-agents (press twice within 3s).
const KILL_CONFIRM_WINDOW: Duration = Duration::from_secs(3);

impl App {
    /// Consult the keybinding map for `key` in `ctx`.
    ///
    /// Returns `Some(should_quit)` when the key was consumed (an action ran, or
    /// the key extended a pending chord), `None` when the caller should fall
    /// through to its hardcoded arms / the composer.
    pub(crate) fn resolve_keymap(&mut self, ctx: Context, key: KeyEvent) -> Option<bool> {
        // Expire a stale chord prefix so an old ctrl+x can't pair much later.
        if let Some((_, t)) = &self.chord_pending {
            if t.elapsed() > CHORD_TIMEOUT {
                self.chord_pending = None;
            }
        }
        let mut seq: Vec<KeyEvent> = self
            .chord_pending
            .take()
            .map(|(s, _)| s)
            .unwrap_or_default();
        let had_prefix = !seq.is_empty();
        seq.push(key);
        match self.keymap.resolve(ctx, &seq) {
            Resolution::Action(action) => self.dispatch_action(&action),
            Resolution::Prefix => {
                self.toasts.push(
                    format!("{} \u{2014} waiting for the rest of the chord", format_key_event(&key)),
                    crate::components::toast::ToastLevel::Info,
                );
                self.chord_pending = Some((seq, Instant::now()));
                Some(false)
            }
            Resolution::None if had_prefix => {
                // Broken chord: retry this key alone so a fresh single-key
                // binding (or a new chord start) still works; otherwise the
                // pair is swallowed, matching Claude Code's resolver.
                match self.keymap.resolve(ctx, std::slice::from_ref(&key)) {
                    Resolution::Action(action) => self.dispatch_action(&action),
                    Resolution::Prefix => {
                        self.chord_pending = Some((vec![key], Instant::now()));
                        Some(false)
                    }
                    Resolution::None => Some(false),
                }
            }
            Resolution::None => None,
        }
    }

    /// Perform `action`. `Some(should_quit)` when handled; `None` when the
    /// action declines in the current state (key falls through).
    fn dispatch_action(&mut self, action: &Action) -> Option<bool> {
        use crate::components::toast::ToastLevel;
        match action {
            Action::Unbound => None,
            Action::Help => {
                self.show_help();
                Some(false)
            }
            Action::Redraw => {
                self.force_redraw = true;
                Some(false)
            }
            Action::ToggleSidebar => {
                self.config.sidebar_enabled = !self.config.sidebar_enabled;
                let _ = self.config.save();
                self.recompute_layout();
                Some(false)
            }
            Action::NewSession => {
                self.create_session();
                Some(false)
            }
            Action::Suspend => {
                self.suspend_to_shell();
                Some(false)
            }
            Action::Palette => {
                // Empty composer opens the palette; with text the chord falls
                // through so the composer keeps kill-to-end-of-line on Ctrl+K.
                if self.input.is_empty() {
                    self.open_command_palette();
                    Some(false)
                } else {
                    None
                }
            }
            Action::CycleMode => {
                self.cycle_permission_mode();
                Some(false)
            }
            Action::Voice => {
                if self.voice.recording {
                    self.stop_recording();
                } else {
                    self.start_recording();
                }
                Some(false)
            }
            Action::HandsFree => {
                self.toggle_hands_free();
                Some(false)
            }
            Action::Paste => {
                if self.state.allows_input() {
                    self.paste_from_clipboard();
                    Some(false)
                } else {
                    None
                }
            }
            Action::ExpandTools => {
                if self.agents.is_active() {
                    self.agents.toggle_collapse();
                    self.recompute_layout();
                } else {
                    self.chat.toggle_last_tool_expand(self.width);
                }
                Some(false)
            }
            Action::Background => {
                if self.state.is_processing() {
                    self.background_or_detach();
                    Some(false)
                } else {
                    None
                }
            }
            Action::KillAgents => {
                self.kill_all_agents();
                Some(false)
            }
            Action::ModelPicker => {
                self.load_models();
                Some(false)
            }
            Action::ThinkingToggle => {
                self.thinking_box.toggle();
                self.recompute_layout();
                self.toasts
                    .push("Thinking display toggled".into(), ToastLevel::Info);
                Some(false)
            }
            Action::TodosToggle => {
                self.task_checklist_hidden = !self.task_checklist_hidden;
                self.toasts.push(
                    if self.task_checklist_hidden {
                        "Task panel hidden"
                    } else {
                        "Task panel shown"
                    }
                    .into(),
                    ToastLevel::Info,
                );
                Some(false)
            }
            Action::CopyLast => {
                self.copy_last_message();
                Some(false)
            }
            Action::Interrupt => {
                // WS5 — interrupt through the action layer. Declines at Idle so
                // a bound key falls through to the composer.
                if self.state.is_processing() {
                    self.cancel_processing();
                    Some(false)
                } else {
                    None
                }
            }
            Action::Command(cmd) => {
                self.handle_command(cmd);
                Some(false)
            }
        }
    }

    /// ctrl+x ctrl+k — stop every running sub-agent, guarded by a 3s
    /// press-twice confirm so a stray chord can't nuke a fan-out.
    pub(crate) fn kill_all_agents(&mut self) {
        use crate::components::toast::ToastLevel;
        let now = Instant::now();
        let armed = self
            .kill_agents_armed
            .map(|t| now.duration_since(t) <= KILL_CONFIRM_WINDOW)
            .unwrap_or(false);
        if !armed {
            self.kill_agents_armed = Some(now);
            self.toasts.push(
                "Press ctrl+x ctrl+k again within 3s to stop all agents".into(),
                ToastLevel::Warning,
            );
            return;
        }
        self.kill_agents_armed = None;
        let mut stopped = 0usize;
        for idx in 0..self.agents.entry_count() {
            if !self.agents.is_cancellable(idx) {
                continue;
            }
            if let Some(id) = self.agents.agent_id_at(idx) {
                let client = self.client.clone();
                let target = id.clone();
                tokio::spawn(async move {
                    let _ = client.cancel_agent(&target).await;
                });
                self.agents.mark_cancelled(&id);
                stopped += 1;
            }
        }
        self.toasts.push(
            if stopped == 0 {
                "No running agents to stop".into()
            } else {
                format!("Stopping {stopped} agent(s)")
            },
            ToastLevel::Warning,
        );
    }

    /// Ctrl+V (chat:paste) — paste text or an image from the system clipboard
    /// (arboard). Complements the terminal's bracketed paste, which
    /// mouse-capture and some paste methods (middle-click) don't deliver.
    /// Moved verbatim from the old hardcoded update.rs arm.
    pub(crate) fn paste_from_clipboard(&mut self) {
        use crate::components::toast::ToastLevel;
        // An image on the clipboard becomes an [Image #N] attachment chip.
        if self.ingest_clipboard_image() {
            return;
        }
        match arboard::Clipboard::new().and_then(|mut cb| cb.get_text()) {
            Ok(text) if !text.is_empty() => {
                // A copied file path attaches instead of inserting text — but
                // only when the whole paste is existing file path(s).
                if crate::app::update::paste_is_file_paths(&text)
                    && self.ingest_paste_as_attachments(&text)
                {
                    return;
                }
                let capped: String = text.chars().take(super::MAX_MESSAGE_SIZE).collect();
                let lines = capped.lines().count();
                self.input.insert_str(&capped);
                if lines >= 5 {
                    self.toasts
                        .push(format!("Pasted {} lines", lines), ToastLevel::Info);
                }
            }
            Ok(_) => {
                self.toasts
                    .push("Clipboard is empty".into(), ToastLevel::Info);
            }
            Err(e) => {
                // Surface the failure instead of silently doing nothing, so
                // clipboard access problems are diagnosable.
                self.toasts.push(
                    format!("Paste failed: {} (try Ctrl+Shift+V)", e),
                    ToastLevel::Warning,
                );
            }
        }
    }
}
