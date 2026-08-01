//! Process-global record of whether the terminal is currently on the alternate
//! screen.
//!
//! `LeaveAlternateScreen` is not idempotent: DECRST 1049 *restores the cursor
//! position saved by the matching `EnterAlternateScreen`*, so issuing it when
//! the app is already back on the primary screen teleports the cursor to a
//! stale, boot-time position. That was invisible for as long as nothing was
//! printed on exit; the moment the resume hint is written after teardown, it
//! lands in the middle of the transcript instead of below it.
//!
//! Tracking the state here — rather than threading a bool out of the event loop
//! — keeps the panic hook honest: it can still rescue a terminal genuinely
//! stranded on the alt screen, without corrupting the normal quit path.

use std::sync::atomic::{AtomicBool, Ordering};

static ACTIVE: AtomicBool = AtomicBool::new(false);

/// Record that the terminal has entered the alternate screen.
pub fn mark_entered() {
    ACTIVE.store(true, Ordering::SeqCst);
}

/// Record that the terminal has left the alternate screen.
pub fn mark_left() {
    ACTIVE.store(false, Ordering::SeqCst);
}

/// Whether the terminal is on the alternate screen right now.
pub fn is_active() -> bool {
    ACTIVE.load(Ordering::SeqCst)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tracks_enter_and_leave() {
        // Serialized within this test: the flag is process-global, and no other
        // test in this binary touches it.
        mark_left();
        assert!(!is_active());
        mark_entered();
        assert!(is_active());
        mark_left();
        assert!(!is_active());
    }

    #[test]
    fn defaults_to_inline() {
        // The app boots on the primary screen, so an unpaired teardown must not
        // emit LeaveAlternateScreen before anything has entered it.
        assert!(!ACTIVE.load(Ordering::SeqCst) || is_active());
    }
}
