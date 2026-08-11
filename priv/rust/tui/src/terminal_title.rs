//! Terminal-title sanitization and OSC framing.
//!
//! This module owns the low-level OSC title write path and the sanitization
//! that happens immediately before we emit it. It is intentionally narrow:
//! callers decide *when* the title should change and whether an empty title
//! means "leave the old title alone" or "clear the title OSA last wrote".
//! We deliberately do not try to read or restore the terminal's previous title
//! because that is not portable across terminals.
//!
//! Sanitization is necessary because title content is assembled from untrusted
//! text sources: model output, backend-supplied workspace/session names, project
//! paths, and config. Before we place that text inside an OSC sequence we strip:
//!
//!   * control characters that could terminate or reshape the escape sequence
//!     (a raw `\x07` / `\x1b\\` in the payload ends the OSC early and lets the
//!     remainder of the string be interpreted by the terminal as commands),
//!   * bidi / invisible formatting codepoints that can visually reorder or hide
//!     text — the Trojan Source family of attacks,
//!   * redundant whitespace, so titles stay a single scannable line,
//!
//! and we bound the result so a hostile name cannot blow up the tab bar.

/// Practical upper bound on title length, measured in Rust `char`s.
///
/// Most terminals silently truncate titles beyond a few hundred characters.
/// 240 leaves headroom for the OSC framing bytes (and any tmux/screen DCS
/// wrapper) while keeping titles readable in tab bars and window managers.
pub const MAX_TERMINAL_TITLE_CHARS: usize = 240;

/// Outcome of preparing a terminal title for write.
#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum SetTerminalTitleResult {
    /// A sanitized title survived and was written.
    Applied,
    /// Sanitization removed every visible character, so no title was emitted.
    ///
    /// This is distinct from *clearing* the title. Callers decide whether an
    /// empty post-sanitization value should be a no-op, should clear the title
    /// OSA manages, or should fall back to something else. We never clear
    /// implicitly, because "the model sent an all-invisible name" must not be
    /// able to wipe the operator's tab title.
    NoVisibleContent,
}

/// Normalizes untrusted title text into a single bounded display line.
///
/// Removes terminal control characters, strips invisible/bidi formatting
/// characters, collapses any whitespace run into a single ASCII space, drops
/// leading/trailing whitespace, and truncates after
/// [`MAX_TERMINAL_TITLE_CHARS`] emitted characters.
pub fn sanitize_terminal_title(title: &str) -> String {
    let mut sanitized = String::new();
    let mut chars_written = 0usize;
    let mut pending_space = false;

    for ch in title.chars() {
        if ch.is_whitespace() {
            // Only mark a pending space once we've written content; this drops
            // leading whitespace without a second trim pass, and trailing
            // whitespace never gets flushed because nothing follows it.
            pending_space = !sanitized.is_empty();
            continue;
        }

        if is_disallowed_terminal_title_char(ch) {
            continue;
        }

        if pending_space {
            let remaining = MAX_TERMINAL_TITLE_CHARS.saturating_sub(chars_written);
            if remaining > 1 {
                sanitized.push(' ');
                chars_written += 1;
            }
            pending_space = false;
        }

        if chars_written >= MAX_TERMINAL_TITLE_CHARS {
            break;
        }

        sanitized.push(ch);
        chars_written += 1;
    }

    sanitized
}

/// Returns whether `ch` should be dropped from terminal-title output.
///
/// Covers plain control characters plus the invisible/text-reordering
/// codepoints owned by [`crate::render::sanitize`] — the same policy every
/// other untrusted display surface applies, so the title path and the
/// permission dialog cannot drift apart.
fn is_disallowed_terminal_title_char(ch: char) -> bool {
    ch.is_control() || crate::render::sanitize::is_invisible_formatting_char(ch)
}

/// Build the raw OSC 0 (icon + window title) sequence around an already
/// sanitized payload. Terminated with BEL, which every terminal we target
/// accepts (ST shows up in some process decorations).
pub fn build_osc_title_sequence(sanitized_title: &str) -> String {
    format!("\x1b]0;{sanitized_title}\x07")
}

/// Sanitize `title` and, if anything visible survived, produce the OSC sequence
/// to write.
///
/// Returns [`SetTerminalTitleResult::NoVisibleContent`] (and no sequence) when
/// sanitization emptied the title, leaving the clear-vs-keep decision to the
/// caller.
pub fn prepare_title_sequence(title: &str) -> (SetTerminalTitleResult, Option<String>) {
    let sanitized = sanitize_terminal_title(title);
    if sanitized.is_empty() {
        return (SetTerminalTitleResult::NoVisibleContent, None);
    }
    let seq = build_osc_title_sequence(&sanitized);
    (SetTerminalTitleResult::Applied, Some(seq))
}

/// Sequence that clears the title OSA manages.
///
/// This is an explicit caller policy (used on exit), never something an
/// all-invisible untrusted title can trigger on its own.
pub fn clear_title_sequence() -> String {
    build_osc_title_sequence("")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_control_chars_and_collapses_whitespace() {
        let sanitized =
            sanitize_terminal_title("  Project\t|\nWorking\x1b\x07\u{009D}\u{009C} |  Thread  ");
        assert_eq!(sanitized, "Project | Working | Thread");
    }

    #[test]
    fn strips_osc_terminators_so_payload_cannot_escape() {
        // A hostile workspace name that tries to close OSC 0 and start a new
        // command must come out as inert text.
        let sanitized = sanitize_terminal_title("safe\x07\x1b]2;pwn\x1b\\tail");
        assert!(!sanitized.contains('\x07'));
        assert!(!sanitized.contains('\x1b'));
        assert_eq!(sanitized, "safe]2;pwn\\tail");
    }

    #[test]
    fn strips_bidi_and_invisible_codepoints() {
        // RLO/LRI/RLM/ALM/ZWSP/BOM/word-joiner — Trojan Source reordering.
        let sanitized = sanitize_terminal_title(
            "Pro\u{202E}j\u{2066}e\u{200F}c\u{061C}t\u{200B} \u{FEFF}T\u{2060}itle",
        );
        assert_eq!(sanitized, "Project Title");
    }

    #[test]
    fn strips_rlo_alone() {
        assert_eq!(sanitize_terminal_title("a\u{202E}b"), "ab");
    }

    #[test]
    fn caps_length() {
        let input = "a".repeat(MAX_TERMINAL_TITLE_CHARS + 64);
        let sanitized = sanitize_terminal_title(&input);
        assert_eq!(sanitized.chars().count(), MAX_TERMINAL_TITLE_CHARS);
    }

    #[test]
    fn truncation_prefers_visible_char_over_pending_space() {
        let input = format!("{} b", "a".repeat(MAX_TERMINAL_TITLE_CHARS - 1));
        let sanitized = sanitize_terminal_title(&input);
        assert_eq!(sanitized.chars().count(), MAX_TERMINAL_TITLE_CHARS);
        assert_eq!(sanitized.chars().last(), Some('b'));
    }

    #[test]
    fn empty_after_sanitize_reports_no_visible_content() {
        for hostile in ["", "   ", "\x1b\x07", "\u{200B}\u{202E}\u{FEFF}"] {
            let (result, seq) = prepare_title_sequence(hostile);
            assert_eq!(
                result,
                SetTerminalTitleResult::NoVisibleContent,
                "input {hostile:?}"
            );
            assert!(seq.is_none(), "input {hostile:?}");
        }
    }

    #[test]
    fn applied_returns_framed_sequence() {
        let (result, seq) = prepare_title_sequence("  hi  there ");
        assert_eq!(result, SetTerminalTitleResult::Applied);
        assert_eq!(seq.as_deref(), Some("\x1b]0;hi there\x07"));
    }

    #[test]
    fn osc0_sequence_shape() {
        assert_eq!(build_osc_title_sequence("hi"), "\x1b]0;hi\x07");
        assert_eq!(clear_title_sequence(), "\x1b]0;\x07");
    }
}
