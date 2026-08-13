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
use crate::config::keybindings::{format_key_event, Action, Context, Keybindings, Resolution};

/// How long a multi-step chord prefix stays pending before it expires.
const CHORD_TIMEOUT: Duration = Duration::from_secs(3);
/// Confirm window for ctrl+x ctrl+k kill-all-agents (press twice within 3s).
const KILL_CONFIRM_WINDOW: Duration = Duration::from_secs(3);

/// Pure outcome of feeding one key into the chord state machine, given any
/// pending prefix. Separated from [`App::resolve_keymap`] so the delicate
/// fall-through-vs-swallow behaviour is unit-testable without an `App`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ChordStep {
    /// The sequence resolved to an action — run it.
    Fire(Action),
    /// The sequence is a live prefix — hold it pending and wait for the rest.
    Hold(Vec<KeyEvent>),
    /// Nothing in the map matched — the caller must let the key fall through to
    /// its hardcoded arms / the composer (NOT swallow it).
    FallThrough,
}

/// Decide what a fresh `key` does given the `pending` chord prefix (if any).
///
/// The important correctness property — and the "standalone Ctrl+X chord
/// swallow" fix — lives in the broken-chord branch: when a pending prefix is
/// followed by a key that neither completes a chord nor starts a new one, the
/// key **falls through** to the composer instead of being eaten. Previously an
/// accidental lone `ctrl+x` (a prefix with no standalone binding) armed the
/// chord and then silently swallowed the very next character the user typed.
pub(crate) fn step_chord(
    keymap: &Keybindings,
    ctx: Context,
    pending: Option<Vec<KeyEvent>>,
    key: KeyEvent,
) -> ChordStep {
    let mut seq = pending.unwrap_or_default();
    let had_prefix = !seq.is_empty();
    seq.push(key);
    match keymap.resolve(ctx, &seq) {
        Resolution::Action(action) => ChordStep::Fire(action),
        Resolution::Prefix => ChordStep::Hold(seq),
        Resolution::None if had_prefix => {
            // Broken chord: retry the fresh key ALONE so a new single-key
            // binding or a new chord-start still works. A key that matches
            // nothing on its own falls through to the composer — never
            // swallowed — so a mistaken prefix can't eat the next keystroke.
            match keymap.resolve(ctx, std::slice::from_ref(&key)) {
                Resolution::Action(action) => ChordStep::Fire(action),
                Resolution::Prefix => ChordStep::Hold(vec![key]),
                Resolution::None => ChordStep::FallThrough,
            }
        }
        Resolution::None => ChordStep::FallThrough,
    }
}

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
        let pending: Option<Vec<KeyEvent>> = self.chord_pending.take().map(|(s, _)| s);
        match step_chord(&self.keymap, ctx, pending, key) {
            ChordStep::Fire(action) => self.dispatch_action(&action),
            ChordStep::Hold(seq) => {
                self.toasts.push(
                    format!(
                        "{} \u{2014} waiting for the rest of the chord",
                        format_key_event(&key)
                    ),
                    crate::components::toast::ToastLevel::Info,
                );
                self.chord_pending = Some((seq, Instant::now()));
                Some(false)
            }
            // A key that matches nothing (including the follow-up to a broken
            // prefix) falls through to the caller's arms / the composer.
            ChordStep::FallThrough => None,
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
                // Ctrl+N is also the composer's emacs history-next. With a draft
                // in the composer, decline so the key falls through and navigates
                // history (CC/fish parity, like Palette on Ctrl+K); an empty
                // composer starts a new session.
                if self.input.is_empty() {
                    self.create_session();
                    Some(false)
                } else {
                    None
                }
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
                // A PIN, not a hide-toggle: `Auto → Pinned → Suppressed → Auto`.
                // Now that the panel auto-hides a finished list, a boolean
                // suppressor could only hide it further — it had no state from
                // which it could bring an auto-hidden list back, which is the
                // main reason to reach for this chord. `Pinned` additionally
                // lifts the row cap and shows the whole plan.
                let pin = self.task_checklist.cycle_pin();
                self.recompute_layout();
                self.toasts.push(pin.label().into(), ToastLevel::Info);
                Some(false)
            }
            Action::CopyLast => {
                self.copy_last_message();
                Some(false)
            }
            Action::RawToggle => {
                // U-T7 — flip rendered markdown ↔ raw source and confirm via toast.
                let raw = self.chat.toggle_raw_view();
                self.recompute_layout();
                self.toasts.push(
                    if raw {
                        "Raw markdown view on"
                    } else {
                        "Rendered view on"
                    }
                    .into(),
                    ToastLevel::Info,
                );
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
        // Roster index space: 0 is the synthetic `main` root (never cancellable),
        // so agents live at 1..=entry_count.
        for idx in 1..=self.agents.entry_count() {
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
                // Route Ctrl+V through the SAME normalization + large-paste pill
                // collapse as bracketed paste (update.rs). The old path inserted
                // the raw clipboard text verbatim, so a Ctrl+V of copied terminal
                // output injected ANSI escape bytes and carriage returns straight
                // into the composer, and a huge clipboard never collapsed into a
                // "[Pasted text #N]" pill the way a terminal-drag paste did.
                let normalized = crate::components::input::normalize_paste(&text);
                let capped = crate::util::truncate_str(&normalized, super::MAX_MESSAGE_SIZE);
                let lines = capped.lines().count();
                self.input.insert_paste(capped);
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

#[cfg(test)]
mod step_chord_tests {
    use super::{step_chord, ChordStep};
    use crate::config::keybindings::{Action, Context, Keybindings};
    use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

    fn ev(c: char, m: KeyModifiers) -> KeyEvent {
        KeyEvent::new(KeyCode::Char(c), m)
    }

    #[test]
    fn lone_prefix_holds() {
        let kb = Keybindings::defaults();
        // ctrl+x is only ever a chord prefix (ctrl+x ctrl+k) — it arms/holds.
        let x = ev('x', KeyModifiers::CONTROL);
        assert_eq!(
            step_chord(&kb, Context::Idle, None, x),
            ChordStep::Hold(vec![x])
        );
    }

    #[test]
    fn completed_chord_fires() {
        let kb = Keybindings::defaults();
        let x = ev('x', KeyModifiers::CONTROL);
        let k = ev('k', KeyModifiers::CONTROL);
        assert_eq!(
            step_chord(&kb, Context::Idle, Some(vec![x]), k),
            ChordStep::Fire(Action::KillAgents)
        );
    }

    #[test]
    fn broken_chord_followup_falls_through_not_swallowed() {
        // The regression under test: ctrl+x then an ordinary 'a'. 'a' completes
        // no chord and starts none, so it must FALL THROUGH to the composer to be
        // typed — never be eaten by the abandoned prefix.
        let kb = Keybindings::defaults();
        let x = ev('x', KeyModifiers::CONTROL);
        let a = ev('a', KeyModifiers::NONE);
        assert_eq!(
            step_chord(&kb, Context::Idle, Some(vec![x]), a),
            ChordStep::FallThrough
        );
    }

    #[test]
    fn broken_chord_followup_that_is_itself_a_binding_fires() {
        // ctrl+x then ctrl+n (a real Idle binding): the abandoned prefix must not
        // block the fresh single-key action.
        let kb = Keybindings::defaults();
        let x = ev('x', KeyModifiers::CONTROL);
        let n = ev('n', KeyModifiers::CONTROL);
        assert_eq!(
            step_chord(&kb, Context::Idle, Some(vec![x]), n),
            ChordStep::Fire(Action::NewSession)
        );
    }

    #[test]
    fn broken_chord_followup_that_is_a_new_prefix_rearms() {
        // ctrl+x then ctrl+x: the second starts a fresh prefix rather than being
        // dropped.
        let kb = Keybindings::defaults();
        let x = ev('x', KeyModifiers::CONTROL);
        assert_eq!(
            step_chord(&kb, Context::Idle, Some(vec![x]), x),
            ChordStep::Hold(vec![x])
        );
    }

    #[test]
    fn unbound_key_with_no_prefix_falls_through() {
        let kb = Keybindings::defaults();
        let a = ev('a', KeyModifiers::NONE);
        assert_eq!(
            step_chord(&kb, Context::Idle, None, a),
            ChordStep::FallThrough
        );
    }
}
