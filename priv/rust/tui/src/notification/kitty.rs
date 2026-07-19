//! kitty desktop-notification protocol (U-T17) + kitty keyboard re-push gate (U-B3).
//!
//! ## Notifications (U-T17)
//! kitty's `OSC 99` notification protocol lets us send a rich notification in
//! multiple escapes sharing an `i=<id>`, ending with `d=1` to mark it done. We
//! send it as three parts, matching how Claude Code drives kitty:
//!   1. metadata + title, `a=focus,report` so clicking the toast focuses the
//!      terminal window (click-to-focus) and reports activation,
//!   2. the body payload,
//!   3. a terminator escape (`d=1`) that commits the notification.
//!
//! `a=focus` is the click-to-focus action; `report` asks kitty to send an
//! activation report back so a future lane could raise the window itself.
//!
//! ## Keyboard protocol re-push (U-B3)
//! When OSA suspends (Ctrl+Z) and resumes (`fg`/SIGCONT), the kitty keyboard
//! protocol must be re-pushed or Shift+Enter silently reverts to submit. The
//! resume path currently gates the re-push on a *runtime* `supports_keyboard_
//! enhancement()` query, which returns `false`/`Err` on kitty-family terminals
//! reached through tmux/SSH that we only recognise by ENV. [`should_repush_kitty_
//! protocol`] fixes that: trust the runtime answer when it's `Some`, else fall
//! back to env detection — so an env-detected kitty terminal keeps Shift+Enter
//! working across a suspend/resume.
#![allow(dead_code)]

use std::io::Write;

const ESC: char = '\x1b';
const ST: &str = "\x1b\\";

/// Strip control chars and the `:`/`;` field separators so a title/body can't
/// break out of the OSC 99 encoding.
fn sanitize(s: &str) -> String {
    s.chars()
        .filter(|c| !c.is_control() && *c != ';' && *c != ':')
        .collect()
}

/// Build the 3-part kitty `OSC 99` notification (metadata+title, body, done).
/// `id` groups the three escapes; `a=focus,report` makes the toast click-to-focus.
pub fn build_notification(id: u32, title: &str, body: &str) -> String {
    let title = sanitize(title);
    let body = sanitize(body);
    // Part 1: open notification `id`, declare it's the title chunk, not done,
    // request the focus + report actions.
    let part1 = format!("{ESC}]99;i={id}:p=title:d=0:a=focus,report;{title}{ST}");
    // Part 2: the body chunk (same id, still not done).
    let part2 = format!("{ESC}]99;i={id}:p=body:d=0;{body}{ST}");
    // Part 3: terminator — commit and display the notification.
    let part3 = format!("{ESC}]99;i={id}:d=1;{ST}");
    format!("{part1}{part2}{part3}")
}

/// tmux/screen DCS passthrough (same contract as `osc52::wrap_for_multiplexer`).
pub(crate) fn wrap_for_multiplexer(sequence: String) -> String {
    if std::env::var_os("TMUX").is_some() {
        let escaped = sequence.replace(ESC, &format!("{ESC}{ESC}"));
        return format!("{ESC}Ptmux;{escaped}{ST}");
    }
    if std::env::var_os("STY").is_some() {
        return format!("{ESC}P{sequence}{ST}");
    }
    sequence
}

/// Emit a click-to-focus kitty notification to the terminal.
pub fn notify(id: u32, title: &str, body: &str) {
    let seq = wrap_for_multiplexer(build_notification(id, title, body));
    let mut out = std::io::stdout();
    let _ = out.write_all(seq.as_bytes());
    let _ = out.flush();
}

/// Env-based detection of a terminal that implements the kitty keyboard
/// protocol. Mirrors `main.rs::terminal_known_kitty_protocol` so a flaky runtime
/// probe can't strand a capable terminal. Pure over injected env for testing.
pub fn env_supports_kitty_keyboard_from(
    term: Option<&str>,
    term_program: Option<&str>,
    kitty_window: bool,
    ghostty_dir: bool,
    wezterm_pane: bool,
) -> bool {
    let t = term.unwrap_or("").to_ascii_lowercase();
    let p = term_program.unwrap_or("").to_ascii_lowercase();
    t.contains("ghostty")
        || t.contains("kitty")
        || t.contains("foot")
        || t.contains("wezterm")
        || p.contains("ghostty")
        || p.contains("kitty")
        || p.contains("wezterm")
        || kitty_window
        || ghostty_dir
        || wezterm_pane
}

/// Live env-based detection (reads the process environment).
pub fn env_supports_kitty_keyboard() -> bool {
    use std::env::{var, var_os};
    env_supports_kitty_keyboard_from(
        var("TERM").ok().as_deref(),
        var("TERM_PROGRAM").ok().as_deref(),
        var_os("KITTY_WINDOW_ID").is_some(),
        var_os("GHOSTTY_RESOURCES_DIR").is_some(),
        var_os("WEZTERM_PANE").is_some(),
    )
}

/// Whether to re-push the kitty keyboard protocol on resume (U-B3).
///
/// `runtime` is the answer from crossterm's `supports_keyboard_enhancement()`
/// mapped to `Option<bool>` (`Ok(v)` -> `Some(v)`, `Err(_)` -> `None`). We trust
/// a definitive runtime answer; only when it's unknown do we fall back to env
/// detection — so an env-detected kitty terminal behind tmux/SSH keeps
/// Shift+Enter working across suspend/resume instead of silently reverting.
pub fn should_repush_kitty_protocol(runtime: Option<bool>) -> bool {
    match runtime {
        Some(supported) => supported,
        None => env_supports_kitty_keyboard(),
    }
}

/// Convenience over the env-only decision, for the case where the resume path
/// has no runtime probe to offer.
pub fn should_repush_kitty_protocol_env_only() -> bool {
    env_supports_kitty_keyboard()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn three_parts_share_id_and_request_focus() {
        let seq = build_notification(7, "OSA", "Response ready");
        // metadata/title chunk carries the click-to-focus action
        assert!(seq.contains("\x1b]99;i=7:p=title:d=0:a=focus,report;OSA\x1b\\"));
        // body chunk
        assert!(seq.contains("\x1b]99;i=7:p=body:d=0;Response ready\x1b\\"));
        // terminator commits the notification
        assert!(seq.ends_with("\x1b]99;i=7:d=1;\x1b\\"));
    }

    #[test]
    fn payload_is_sanitized() {
        let seq = build_notification(1, "a;b:c", "x\x07y");
        assert!(seq.contains("p=title:d=0:a=focus,report;abc\x1b\\"));
        assert!(seq.contains("p=body:d=0;xy\x1b\\"));
    }

    #[test]
    fn env_detection_matches_known_terminals() {
        assert!(env_supports_kitty_keyboard_from(
            Some("xterm-kitty"), None, false, false, false
        ));
        assert!(env_supports_kitty_keyboard_from(
            Some("xterm-256color"), None, true, false, false // KITTY_WINDOW_ID
        ));
        assert!(env_supports_kitty_keyboard_from(
            Some("screen"), Some("ghostty"), false, false, false
        ));
        assert!(!env_supports_kitty_keyboard_from(
            Some("xterm-256color"), Some("Apple_Terminal"), false, false, false
        ));
    }

    #[test]
    fn repush_trusts_runtime_then_env() {
        // Definitive runtime answers win.
        assert!(should_repush_kitty_protocol(Some(true)));
        assert!(!should_repush_kitty_protocol(Some(false)));
        // Unknown -> env fallback. We can't assert the host env, but the call
        // must not panic and must equal the env probe.
        assert_eq!(
            should_repush_kitty_protocol(None),
            env_supports_kitty_keyboard()
        );
    }
}
