//! Terminal tab title (OSC 0) — WS12 chrome.
//!
//! Mirrors Claude Code's `use-terminal-title`: the tab shows "OSA — <dir>"
//! when idle and animates a leading glyph (✳ / ✻, 960ms cadence) while a turn
//! is running, so a backgrounded tab telegraphs busy/idle at a glance.
//! Writes are deduped (emit only on change), tmux/screen DCS-wrapped so they
//! reach the outer terminal, and the title is reset on exit. Disable with the
//! OSA_NO_TITLE env var.

use std::io::Write;
use std::time::{SystemTime, UNIX_EPOCH};

/// Busy-glyph animation period — matches CC's terminal-title cadence.
const BUSY_ANIM_MS: u128 = 960;

use crate::terminal_title::{
    SetTerminalTitleResult, clear_title_sequence, prepare_title_sequence, sanitize_terminal_title,
};

/// Strip control characters, bidi/invisible codepoints and redundant
/// whitespace so directory / workspace names (which can be backend- or
/// model-supplied) can never smuggle escape sequences into the OSC payload or
/// visually reorder the title. See `crate::terminal_title`.
fn sanitize(s: &str) -> String {
    sanitize_terminal_title(s)
}

/// Pure title composition, driven by an explicit clock for testability.
pub fn compose_at(busy: bool, cwd_basename: &str, now_ms: u128) -> String {
    let name = sanitize(cwd_basename);
    if busy {
        let glyph = if (now_ms / BUSY_ANIM_MS) % 2 == 0 {
            "\u{2733}" // ✳
        } else {
            "\u{273b}" // ✻
        };
        format!("{glyph} OSA \u{2014} {name}")
    } else {
        format!("OSA \u{2014} {name}")
    }
}

/// Compose the current title using the wall clock.
pub fn compose(busy: bool, cwd_basename: &str) -> String {
    let now_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    compose_at(busy, cwd_basename, now_ms)
}

/// Build the raw OSC 0 (icon + window title) sequence for an already sanitized
/// payload. Framing lives in `crate::terminal_title`.
#[cfg(test)]
fn build_sequence(title: &str) -> String {
    crate::terminal_title::build_osc_title_sequence(title)
}

/// Deduping terminal-title writer: emits the OSC 0 sequence only when the
/// title actually changed, so the 200ms draw cadence doesn't spam the pty
/// (the busy animation flips at most every 960ms).
pub struct TitleState {
    enabled: bool,
    last: String,
}

impl TitleState {
    pub fn new() -> Self {
        Self {
            enabled: std::env::var_os("OSA_NO_TITLE").is_none(),
            last: String::new(),
        }
    }

    /// Set the terminal title (no-op when unchanged or disabled). The control
    /// sequence is consumed by the terminal, so emitting mid-frame is safe.
    ///
    /// Every write goes through `terminal_title::prepare_title_sequence`, which
    /// sanitizes the untrusted payload. When sanitization leaves nothing
    /// visible we report `NoVisibleContent` and write nothing: an
    /// all-invisible title must not be able to clear the operator's tab title
    /// (clearing is an explicit policy, see `reset`).
    pub fn update(&mut self, title: &str) -> SetTerminalTitleResult {
        let (result, seq) = prepare_title_sequence(title);
        // NoVisibleContent → nothing to emit; the previously written title
        // stays put. Caller policy decides whether to fall back.
        let Some(seq) = seq else { return result };
        // Dedup on the *sanitized* payload so distinct hostile inputs that
        // sanitize to the same title cost at most one write.
        if !self.enabled || seq == self.last {
            return result;
        }
        self.last = seq.clone();
        Self::write(seq);
        result
    }

    /// Restore an empty title on exit so the shell's own title logic takes over.
    pub fn reset(&mut self) {
        if !self.enabled {
            return;
        }
        self.last.clear();
        Self::write(clear_title_sequence());
    }

    fn write(seq: String) {
        let seq = crate::components::notify::wrap_for_multiplexer(seq);
        let mut out = std::io::stdout();
        let _ = out.write_all(seq.as_bytes());
        let _ = out.flush();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compose_idle_and_busy() {
        assert_eq!(compose_at(false, "osa", 0), "OSA \u{2014} osa");
        assert_eq!(compose_at(true, "osa", 0), "\u{2733} OSA \u{2014} osa");
        // Next 960ms frame flips the glyph.
        assert_eq!(compose_at(true, "osa", 960), "\u{273b} OSA \u{2014} osa");
        // Same frame → identical title (upstream dedup sees no change).
        assert_eq!(compose_at(true, "osa", 100), compose_at(true, "osa", 900));
    }

    #[test]
    fn sanitize_strips_control_chars() {
        assert_eq!(
            compose_at(false, "a\x1b]2;pwn\x07b", 0),
            "OSA \u{2014} a]2;pwnb"
        );
    }

    #[test]
    fn osc0_sequence_shape() {
        assert_eq!(build_sequence("hi"), "\x1b]0;hi\x07");
    }

    #[test]
    fn sanitize_strips_bidi_reordering_controls() {
        // A backend/model-supplied workspace name using RLO to disguise itself.
        assert_eq!(
            compose_at(false, "sa\u{202E}fe\u{200B}\u{FEFF}", 0),
            "OSA \u{2014} safe"
        );
    }

    #[test]
    fn sanitize_caps_title_length() {
        let huge = "z".repeat(1000);
        // The basename is bounded on compose, and the whole title is bounded
        // again at the write boundary.
        let title = compose_at(false, &huge, 0);
        assert!(title.chars().count() <= crate::terminal_title::MAX_TERMINAL_TITLE_CHARS + 6);
        let emitted = crate::terminal_title::sanitize_terminal_title(&title);
        assert_eq!(
            emitted.chars().count(),
            crate::terminal_title::MAX_TERMINAL_TITLE_CHARS
        );
    }

    #[test]
    fn update_reports_no_visible_content_and_writes_nothing() {
        // `enabled: false` keeps the test off the real pty; the tri-state is
        // decided before the enabled check, so the security contract still
        // holds here.
        let mut st = TitleState {
            enabled: false,
            last: String::new(),
        };
        assert_eq!(
            st.update("\u{200B}\u{202E}\x1b\x07"),
            SetTerminalTitleResult::NoVisibleContent
        );
        assert_eq!(st.last, "");
        assert_eq!(st.update("OSA \u{2014} osa"), SetTerminalTitleResult::Applied);
    }

    #[test]
    fn update_never_emits_raw_control_chars() {
        let mut st = TitleState {
            enabled: false,
            last: String::new(),
        };
        // Do not actually write: assert on the prepared sequence instead.
        let (_res, seq) = crate::terminal_title::prepare_title_sequence(&compose_at(
            false,
            "a\x07\x1b]2;pwn\x1b\\b",
            0,
        ));
        let seq = seq.expect("visible content");
        assert_eq!(seq.matches('\x1b').count(), 1, "only the OSC introducer");
        assert_eq!(seq.matches('\x07').count(), 1, "only the BEL terminator");
        assert!(seq.starts_with("\x1b]0;") && seq.ends_with('\x07'));
        // Keep `st` used so the writer type stays exercised in this test.
        st.reset();
    }
}
