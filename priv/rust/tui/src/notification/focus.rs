//! Terminal focus tracking via DECSET 1004 (U-T11).
//!
//! Replaces the old 10-second "idle heuristic" (last-keypress age) with a real
//! signal from the terminal: after `EnableFocusChange` (CSI ? 1004 h) the
//! terminal emits `CSI I` on focus-in and `CSI O` on focus-out, which crossterm
//! surfaces as `Event::FocusGained` / `Event::FocusLost`. We fold those into a
//! process-global `AtomicBool` so any lane (turn-complete notifier, audio cue,
//! kitty notification) can ask "is the terminal focused right now?" without
//! threading state through `App` / `update.rs`.
//!
//! Matches Claude Code's `Terminal.tsx` focus tracking: CC enables 1004, tracks
//! a `focused` boolean, and gates its completion bell/notification on it so a
//! turn the user is actively watching never dings.
//!
//! SELF-CONTAINED: state lives here in a static. The only wiring the lead needs
//! is a single call to [`note_event`] wherever crossterm events are read (see
//! the hook note in the module docs of `notification/mod.rs`). It deliberately
//! does NOT route through `update.rs`.
#![allow(dead_code)]

use std::sync::atomic::{AtomicBool, Ordering};

use crossterm::event::Event as CrosstermEvent;

/// Whether the terminal window currently holds focus. Starts `true`: at launch
/// the user just typed the command, so we are focused until told otherwise, and
/// a terminal that never reports focus (1004 unsupported) stays "focused" so we
/// degrade to *always notify* rather than *never notify* — the safe default.
static IS_FOCUSED: AtomicBool = AtomicBool::new(true);

/// True when the terminal window is focused (or focus is unknown — see above).
pub fn is_focused() -> bool {
    IS_FOCUSED.load(Ordering::Relaxed)
}

/// True when the user is away (terminal unfocused). Convenience inverse used by
/// the focus-gated notifiers.
pub fn is_unfocused() -> bool {
    !is_focused()
}

/// Directly set the focus flag. Exposed for tests and for any lane that learns
/// focus by another means.
pub fn set_focused(focused: bool) {
    IS_FOCUSED.store(focused, Ordering::Relaxed);
}

/// Fold a crossterm event into the focus state. Returns `Some(new_state)` when
/// the event WAS a focus transition (so a caller could react), `None` for every
/// other event — making it a cheap, total, no-op-on-miss call to drop into the
/// event dispatch path.
///
/// This is the whole integration surface: `note_event(&crossterm_event)`.
pub fn note_event(event: &CrosstermEvent) -> Option<bool> {
    match event {
        CrosstermEvent::FocusGained => {
            set_focused(true);
            Some(true)
        }
        CrosstermEvent::FocusLost => {
            set_focused(false);
            Some(false)
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // These tests share the process-global flag, so keep them in one function to
    // avoid cross-test ordering races on the atomic.
    #[test]
    fn focus_events_toggle_state() {
        set_focused(true);
        assert!(is_focused());
        assert!(!is_unfocused());

        // A non-focus event leaves state untouched and reports a miss.
        let miss = note_event(&CrosstermEvent::Resize(80, 24));
        assert_eq!(miss, None);
        assert!(is_focused());

        // Focus lost.
        let lost = note_event(&CrosstermEvent::FocusLost);
        assert_eq!(lost, Some(false));
        assert!(!is_focused());
        assert!(is_unfocused());

        // Focus regained.
        let gained = note_event(&CrosstermEvent::FocusGained);
        assert_eq!(gained, Some(true));
        assert!(is_focused());
    }
}
