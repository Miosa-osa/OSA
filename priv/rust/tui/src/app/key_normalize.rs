//! Single normalization layer for cross-terminal keyboard quirks.
//!
//! Terminals disagree on how they encode a handful of keys, and those
//! disagreements are the source of most cross-terminal key bugs:
//!
//! * **Kitty keyboard protocol** (ghostty / wezterm / kitty / foot): OSA enables
//!   `DISAMBIGUATE_ESCAPE_CODES` in `main.rs` so distinct chords like Shift+Enter
//!   report as `Enter+SHIFT` instead of collapsing to a bare `Enter`. Under the
//!   protocol a terminal may also attach extra modifier bits (e.g.
//!   `SHIFT+KEYPAD`) or emit `Release`/`Repeat` `KeyEventKind`s that legacy
//!   terminals never send.
//! * **macOS modifiers**: Terminal.app / iTerm often deliver Shift+Enter as a
//!   bare `Enter` (no protocol), and Option/Alt as either `ALT` or a composed
//!   character — so a portable "insert newline" must also accept Ctrl+J, which
//!   every terminal delivers identically.
//! * **Shift+Tab**: most terminals emit `BackTab` (sometimes with a stray
//!   `SHIFT`, sometimes `NONE`); a few report `Tab`+`SHIFT`.
//!
//! Rather than scatter these `matches!` special-cases across the input
//! component, the update loop and the dialogs, every semantic key decision that
//! depends on a terminal quirk is answered *here*. Handlers ask questions like
//! "is this an insert-newline key?" instead of re-encoding the quirk, so adding
//! support for a new terminal touches exactly one file.

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

/// True when `event` is the Shift+Tab permission-mode cycle. Terminals disagree
/// on how they encode Shift+Tab: most emit `KeyCode::BackTab` (sometimes with a
/// stray SHIFT modifier, sometimes NONE), a few report `Tab`+SHIFT. Accept all
/// of them so the cycle fires consistently across terminals.
pub fn is_permission_cycle(event: &KeyEvent) -> bool {
    matches!(event.code, KeyCode::BackTab)
        || (event.code == KeyCode::Tab && event.modifiers.contains(KeyModifiers::SHIFT))
}

/// True when `event` should insert a hard newline into the composer rather than
/// submit. This unifies the terminal-specific encodings of "newline, don't
/// submit":
///
/// * **Shift+Enter / Alt+Enter** — the primary chord. Matched via `contains`
///   (not exact equality) so a terminal that attaches extra modifier bits under
///   the kitty protocol still disambiguates to a newline.
/// * **Ctrl+J** — the guaranteed-portable fallback (Claude Code's
///   `chat:newline`): every terminal delivers `Ctrl+J` identically, so it works
///   even where Shift+Enter collapses to a bare Enter.
pub fn is_insert_newline(event: &KeyEvent) -> bool {
    match event.code {
        KeyCode::Enter => {
            event.modifiers.contains(KeyModifiers::ALT)
                || event.modifiers.contains(KeyModifiers::SHIFT)
        }
        // Exact-CONTROL match: Ctrl+J is the portable newline; other modifier
        // combinations on `j` are ordinary text / bindings.
        KeyCode::Char('j') => event.modifiers == KeyModifiers::CONTROL,
        _ => false,
    }
}

/// True when `event` submits the composer. Plain Enter always submits (Claude
/// Code convention); Ctrl+Enter is accepted too for terminals/muscle-memory that
/// map it. Shift/Alt+Enter are deliberately excluded — those insert a newline
/// (see [`is_insert_newline`]).
///
/// Part of the normalization layer's public surface: the input component keeps
/// its literal Enter-submit arm today, but this is the single source of truth
/// for "is this a submit?" that new handlers route through.
#[allow(dead_code)]
pub fn is_submit(event: &KeyEvent) -> bool {
    event.code == KeyCode::Enter
        && (event.modifiers == KeyModifiers::NONE || event.modifiers == KeyModifiers::CONTROL)
}

/// True when `event` is Ctrl+O (the transcript-viewer toggle). Matched via
/// `contains` so a stray protocol modifier bit doesn't hide the binding.
pub fn is_ctrl_o(event: &KeyEvent) -> bool {
    matches!(event.code, KeyCode::Char('o')) && event.modifiers.contains(KeyModifiers::CONTROL)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crossterm::event::KeyEvent;

    fn ev(code: KeyCode, mods: KeyModifiers) -> KeyEvent {
        KeyEvent::new(code, mods)
    }

    #[test]
    fn permission_cycle_accepts_all_encodings() {
        assert!(is_permission_cycle(&ev(KeyCode::BackTab, KeyModifiers::NONE)));
        assert!(is_permission_cycle(&ev(KeyCode::BackTab, KeyModifiers::SHIFT)));
        assert!(is_permission_cycle(&ev(KeyCode::Tab, KeyModifiers::SHIFT)));
        assert!(!is_permission_cycle(&ev(KeyCode::Tab, KeyModifiers::NONE)));
    }

    #[test]
    fn insert_newline_covers_shift_alt_enter_and_ctrl_j() {
        assert!(is_insert_newline(&ev(KeyCode::Enter, KeyModifiers::SHIFT)));
        assert!(is_insert_newline(&ev(KeyCode::Enter, KeyModifiers::ALT)));
        // Extra protocol modifier bits still disambiguate to newline.
        assert!(is_insert_newline(&ev(
            KeyCode::Enter,
            KeyModifiers::SHIFT | KeyModifiers::CONTROL
        )));
        assert!(is_insert_newline(&ev(KeyCode::Char('j'), KeyModifiers::CONTROL)));
        // Not a newline.
        assert!(!is_insert_newline(&ev(KeyCode::Enter, KeyModifiers::NONE)));
        assert!(!is_insert_newline(&ev(KeyCode::Enter, KeyModifiers::CONTROL)));
        assert!(!is_insert_newline(&ev(KeyCode::Char('j'), KeyModifiers::NONE)));
    }

    #[test]
    fn submit_is_plain_or_ctrl_enter_only() {
        assert!(is_submit(&ev(KeyCode::Enter, KeyModifiers::NONE)));
        assert!(is_submit(&ev(KeyCode::Enter, KeyModifiers::CONTROL)));
        assert!(!is_submit(&ev(KeyCode::Enter, KeyModifiers::SHIFT)));
        assert!(!is_submit(&ev(KeyCode::Enter, KeyModifiers::ALT)));
    }

    #[test]
    fn newline_and_submit_are_disjoint() {
        // Every Enter chord is exactly one of newline / submit (never both).
        for mods in [
            KeyModifiers::NONE,
            KeyModifiers::SHIFT,
            KeyModifiers::ALT,
            KeyModifiers::CONTROL,
        ] {
            let e = ev(KeyCode::Enter, mods);
            assert!(!(is_insert_newline(&e) && is_submit(&e)));
        }
    }

    #[test]
    fn ctrl_o_detected() {
        assert!(is_ctrl_o(&ev(KeyCode::Char('o'), KeyModifiers::CONTROL)));
        assert!(!is_ctrl_o(&ev(KeyCode::Char('o'), KeyModifiers::NONE)));
    }
}
