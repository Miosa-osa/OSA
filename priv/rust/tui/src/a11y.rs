//! Screen-reader / accessibility (plain-text) mode helpers.
//!
//! Screen readers choke on the rich TUI chrome — boxed borders, braille progress
//! bars, animated star spinners, and glyph-decorated feed lines all read as noise.
//! The a11y (plain-text) mode renders the activity indicator as a single static,
//! plain-language status line and announces state transitions as plain scrollback
//! text instead. It is opt-in via `/a11y` (persisted in config) but can also be
//! auto-detected from the environment.

use crate::components::activity::ProcessingPhase;

/// Detect a screen-reader / plain-text hint from the environment.
///
/// Honors `NO_COLOR` (https://no-color.org) and a few common screen-reader /
/// accessibility opt-in variables, plus `TERM=dumb` (a terminal with no cursor
/// addressing, which is what most plain readers present). Any hit means "prefer
/// the plain-text activity surface by default"; the user can still toggle it off
/// in-session with `/a11y`.
pub fn env_hint() -> bool {
    // NO_COLOR: spec says presence (non-empty) is the signal, regardless of value.
    if std::env::var_os("NO_COLOR").is_some_and(|v| !v.is_empty()) {
        return true;
    }
    // Explicit accessibility / screen-reader opt-ins.
    for key in ["OSA_A11Y", "OSA_SCREEN_READER", "SCREEN_READER", "ACCESSIBILITY"] {
        if let Some(v) = std::env::var_os(key) {
            let v = v.to_string_lossy();
            if !v.is_empty() && v != "0" && !v.eq_ignore_ascii_case("false") {
                return true;
            }
        }
    }
    // TERM=dumb: no cursor addressing — typically a plain / reader context.
    if std::env::var("TERM").map(|t| t == "dumb").unwrap_or(false) {
        return true;
    }
    false
}

/// Plain-language label for a processing phase — announced on the static status
/// line (no spinner, no glyphs) in screen-reader mode.
pub fn phase_label(phase: ProcessingPhase) -> &'static str {
    match phase {
        ProcessingPhase::Waiting => "working",
        ProcessingPhase::Thinking => "thinking",
        ProcessingPhase::Streaming => "responding",
        ProcessingPhase::ToolCall => "running tool",
        ProcessingPhase::Synthesizing => "finishing response",
    }
}
