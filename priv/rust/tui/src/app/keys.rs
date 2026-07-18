// Phase 3: Centralized keymap — wire when splitting update.rs key handlers
#![allow(dead_code)]

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use std::time::{Duration, Instant};

/// Default window in which a second Esc counts as a "double-Esc" chord.
/// 800ms — Claude Code's double-press window (useDoublePress).
pub const ESC_DOUBLE_WINDOW: Duration = Duration::from_millis(800);

/// Time-gated detector for the Esc-vs-Esc-Esc distinction.
///
/// A single Esc performs the context-appropriate cancel and never destroys a
/// draft; two Escs pressed within `window` (with no intervening key) are a
/// distinct chord — OSA maps it to clear-the-draft (pushed into input history
/// so ↑ restores it) when the composer holds text, or to the rewind /
/// jump-to-previous-message picker when empty, matching Claude Code.
///
/// The type is deliberately pure (no wall-clock reads inside) so the decision
/// logic is unit-testable: callers pass `Instant::now()` in, and any non-Esc
/// key must call `reset()` so an old Esc can't pair with a much-later one.
pub struct EscTracker {
    last: Option<Instant>,
    window: Duration,
}

impl Default for EscTracker {
    fn default() -> Self {
        Self::new(ESC_DOUBLE_WINDOW)
    }
}

impl EscTracker {
    pub fn new(window: Duration) -> Self {
        Self { last: None, window }
    }

    /// Register an Esc press at `now`. Returns `true` when it completes a
    /// double-press (a prior press within `window`), consuming the pending
    /// state so a third Esc starts a fresh pair. Otherwise records this press
    /// as the (new) first Esc and returns `false`.
    pub fn press(&mut self, now: Instant) -> bool {
        match self.last.take() {
            Some(prev) if now.duration_since(prev) <= self.window => true,
            _ => {
                self.last = Some(now);
                false
            }
        }
    }

    /// Whether a single Esc is currently "pending" (waiting for a possible
    /// second press). Used to decide whether to show the double-Esc hint.
    pub fn is_pending(&self) -> bool {
        self.last.is_some()
    }

    /// Any non-Esc key breaks the pair — call this so a stale first Esc cannot
    /// combine with a much later one.
    pub fn reset(&mut self) {
        self.last = None;
    }
}

/// Key binding definition
pub struct KeyBinding {
    pub code: KeyCode,
    pub modifiers: KeyModifiers,
    pub help: &'static str,
}

impl KeyBinding {
    pub const fn new(code: KeyCode, modifiers: KeyModifiers, help: &'static str) -> Self {
        Self {
            code,
            modifiers,
            help,
        }
    }

    pub fn matches(&self, event: &KeyEvent) -> bool {
        event.code == self.code && event.modifiers.contains(self.modifiers)
    }
}

/// True when `event` is the Shift+Tab permission-mode cycle.
///
/// The cross-terminal encoding quirk lives in the single key-normalization
/// layer ([`crate::app::key_normalize`]); this thin delegate keeps the historical
/// `keys::is_permission_cycle` call sites working while the decision is made in
/// one place.
pub fn is_permission_cycle(event: &KeyEvent) -> bool {
    crate::app::key_normalize::is_permission_cycle(event)
}

/// All key bindings — 22 bindings matching Go keymap
pub struct KeyMap {
    pub submit: KeyBinding,
    pub cancel: KeyBinding,
    pub quit_eof: KeyBinding,
    pub escape: KeyBinding,
    pub help: KeyBinding,
    pub page_up: KeyBinding,
    pub page_down: KeyBinding,
    pub scroll_top: KeyBinding,
    pub scroll_bottom: KeyBinding,
    pub scroll_up: KeyBinding,
    pub scroll_down: KeyBinding,
    pub half_page_up: KeyBinding,
    pub half_page_down: KeyBinding,
    pub toggle_expand: KeyBinding,
    /// Ctrl+O — toggle the full-screen transcript viewer (scroll/search/copy).
    /// The live binding is enforced in `event_loop::dispatch_event`; this entry
    /// documents it and keeps the keymap authoritative.
    pub transcript: KeyBinding,
    pub toggle_thinking: KeyBinding,
    pub toggle_background: KeyBinding,
    pub toggle_sidebar: KeyBinding,
    pub tab: KeyBinding,
    pub permission_cycle: KeyBinding,
    pub clear_input: KeyBinding,
    pub new_session: KeyBinding,
    pub palette: KeyBinding,
    pub copy_message: KeyBinding,
    pub voice_toggle: KeyBinding,
    pub voice_hands_free: KeyBinding,
}

impl Default for KeyMap {
    fn default() -> Self {
        Self {
            submit: KeyBinding::new(KeyCode::Enter, KeyModifiers::NONE, "submit"),
            cancel: KeyBinding::new(KeyCode::Char('c'), KeyModifiers::CONTROL, "cancel/quit"),
            quit_eof: KeyBinding::new(KeyCode::Char('d'), KeyModifiers::CONTROL, "quit"),
            escape: KeyBinding::new(KeyCode::Esc, KeyModifiers::NONE, "cancel"),
            help: KeyBinding::new(KeyCode::F(1), KeyModifiers::NONE, "help"),
            page_up: KeyBinding::new(KeyCode::PageUp, KeyModifiers::NONE, "page up"),
            page_down: KeyBinding::new(KeyCode::PageDown, KeyModifiers::NONE, "page down"),
            scroll_top: KeyBinding::new(KeyCode::Home, KeyModifiers::NONE, "scroll top"),
            scroll_bottom: KeyBinding::new(KeyCode::End, KeyModifiers::NONE, "scroll bottom"),
            scroll_up: KeyBinding::new(KeyCode::Char('k'), KeyModifiers::NONE, "scroll up"),
            scroll_down: KeyBinding::new(KeyCode::Char('j'), KeyModifiers::NONE, "scroll down"),
            half_page_up: KeyBinding::new(KeyCode::Char('u'), KeyModifiers::NONE, "half page up"),
            half_page_down: KeyBinding::new(
                KeyCode::Char('d'),
                KeyModifiers::NONE,
                "half page down",
            ),
            toggle_expand: KeyBinding::new(
                KeyCode::Char('o'),
                KeyModifiers::CONTROL,
                "expand/collapse",
            ),
            transcript: KeyBinding::new(
                KeyCode::Char('o'),
                KeyModifiers::CONTROL,
                "transcript viewer",
            ),
            toggle_thinking: KeyBinding::new(
                KeyCode::Char('t'),
                KeyModifiers::CONTROL,
                "toggle thinking",
            ),
            toggle_background: KeyBinding::new(
                KeyCode::Char('b'),
                KeyModifiers::CONTROL,
                "background task",
            ),
            toggle_sidebar: KeyBinding::new(
                KeyCode::Char('l'),
                KeyModifiers::CONTROL.union(KeyModifiers::SHIFT),
                "toggle sidebar",
            ),
            tab: KeyBinding::new(KeyCode::Tab, KeyModifiers::NONE, "autocomplete"),
            permission_cycle: KeyBinding::new(
                KeyCode::BackTab,
                KeyModifiers::NONE,
                "cycle permission mode",
            ),
            clear_input: KeyBinding::new(
                KeyCode::Char('u'),
                KeyModifiers::CONTROL,
                "clear input",
            ),
            new_session: KeyBinding::new(
                KeyCode::Char('n'),
                KeyModifiers::CONTROL,
                "new session",
            ),
            palette: KeyBinding::new(
                KeyCode::Char('k'),
                KeyModifiers::CONTROL,
                "command palette",
            ),
            copy_message: KeyBinding::new(
                KeyCode::Char('y'),
                KeyModifiers::NONE,
                "copy last message",
            ),
            voice_toggle: KeyBinding::new(
                KeyCode::Char('v'),
                KeyModifiers::ALT,
                "voice input",
            ),
            voice_hands_free: KeyBinding::new(
                KeyCode::F(9),
                KeyModifiers::NONE,
                "hands-free voice",
            ),
        }
    }
}

#[cfg(test)]
mod esc_tracker_tests {
    use super::EscTracker;
    use std::time::{Duration, Instant};

    #[test]
    fn single_press_is_not_a_double() {
        let mut t = EscTracker::new(Duration::from_millis(500));
        let now = Instant::now();
        assert!(!t.press(now), "first Esc must not be a double-press");
        assert!(t.is_pending(), "a lone Esc should be pending a second press");
    }

    #[test]
    fn second_press_within_window_is_a_double() {
        let mut t = EscTracker::new(Duration::from_millis(500));
        let start = Instant::now();
        assert!(!t.press(start));
        // 200ms later — inside the window.
        assert!(t.press(start + Duration::from_millis(200)));
        // The pair is consumed: a third press starts fresh.
        assert!(!t.is_pending());
        assert!(!t.press(start + Duration::from_millis(220)));
    }

    #[test]
    fn second_press_outside_window_is_not_a_double() {
        let mut t = EscTracker::new(Duration::from_millis(500));
        let start = Instant::now();
        assert!(!t.press(start));
        // 700ms later — the window lapsed; treat as a new first press.
        assert!(!t.press(start + Duration::from_millis(700)));
        assert!(t.is_pending());
    }

    #[test]
    fn reset_breaks_the_pair() {
        let mut t = EscTracker::new(Duration::from_millis(500));
        let start = Instant::now();
        assert!(!t.press(start));
        t.reset(); // an intervening non-Esc key
        assert!(!t.is_pending());
        // The next Esc is a fresh first press, not a double.
        assert!(!t.press(start + Duration::from_millis(100)));
    }

    #[test]
    fn boundary_exactly_at_window_counts_as_double() {
        let mut t = EscTracker::new(Duration::from_millis(500));
        let start = Instant::now();
        assert!(!t.press(start));
        assert!(t.press(start + Duration::from_millis(500)));
    }
}
