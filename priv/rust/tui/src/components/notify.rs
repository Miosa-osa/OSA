//! Desktop notifications through the terminal — WS12 chrome.
//!
//! Channel-selected the way Claude Code's notifier is: ghostty gets OSC 777,
//! kitty gets OSC 99, everything else gets OSC 9 (iTerm2 et al. consume it;
//! terminals that don't simply ignore it) — always followed by a BEL so a
//! plain terminal still dings. Sequences are tmux/screen DCS-wrapped so they
//! reach the outer terminal (same passthrough contract as osc52.rs).

use std::io::Write;

const ESC: char = '\x1b';
const ST: &str = "\x1b\\";

/// Notification transport picked from the terminal environment.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Channel {
    /// ghostty / urxvt style: `OSC 777;notify;<title>;<body>`.
    Osc777,
    /// kitty desktop-notification protocol: `OSC 99;i=1:d=0;<text>`.
    Osc99,
    /// iTerm2 / generic growl-style: `OSC 9;<text>`.
    Osc9,
}

/// Detect the best notification channel for the current terminal.
pub fn detect_channel() -> Channel {
    detect_channel_from(
        std::env::var("TERM_PROGRAM").ok().as_deref(),
        std::env::var("TERM").ok().as_deref(),
        std::env::var_os("KITTY_WINDOW_ID").is_some(),
    )
}

/// Pure, env-injected detection for tests.
pub fn detect_channel_from(
    term_program: Option<&str>,
    term: Option<&str>,
    kitty_window: bool,
) -> Channel {
    let tp = term_program.unwrap_or("").to_ascii_lowercase();
    let t = term.unwrap_or("").to_ascii_lowercase();
    if tp.contains("ghostty") || t.contains("ghostty") {
        return Channel::Osc777;
    }
    if kitty_window || t.contains("kitty") {
        return Channel::Osc99;
    }
    Channel::Osc9
}

/// Strip control characters and the OSC field separator so titles/bodies can
/// never break out of the sequence.
fn sanitize(s: &str) -> String {
    s.chars()
        .filter(|c| !c.is_control() && *c != ';')
        .collect()
}

/// Build the raw notification sequence (no multiplexer wrapping, no BEL).
pub fn build_sequence(channel: Channel, title: &str, body: &str) -> String {
    let title = sanitize(title);
    let body = sanitize(body);
    match channel {
        Channel::Osc777 => format!("\x1b]777;notify;{title};{body}\x07"),
        Channel::Osc99 => format!("\x1b]99;i=1:d=0;{title}: {body}\x1b\\"),
        Channel::Osc9 => format!("\x1b]9;{title}: {body}\x07"),
    }
}

/// tmux/screen DCS passthrough (same contract as `osc52::wrap_for_multiplexer`)
/// so notifications and titles escape multiplexers and reach the real terminal.
///
/// - tmux (`$TMUX`): `ESC P tmux ; <seq, ESC doubled> ESC \\`
/// - screen (`$STY`): `ESC P <seq> ESC \\`
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

/// Fire a desktop notification through the detected channel, then a BEL for
/// terminals with no notification support. Control sequences are consumed by
/// the terminal, so this never disturbs the ratatui frame.
pub fn notify(title: &str, body: &str) {
    let seq = wrap_for_multiplexer(build_sequence(detect_channel(), title, body));
    let mut out = std::io::stdout();
    let _ = out.write_all(seq.as_bytes());
    let _ = out.write_all(b"\x07");
    let _ = out.flush();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn channel_detection() {
        assert_eq!(detect_channel_from(Some("ghostty"), None, false), Channel::Osc777);
        assert_eq!(detect_channel_from(None, Some("xterm-ghostty"), false), Channel::Osc777);
        assert_eq!(detect_channel_from(None, Some("xterm-kitty"), false), Channel::Osc99);
        assert_eq!(detect_channel_from(None, None, true), Channel::Osc99);
        assert_eq!(
            detect_channel_from(Some("iTerm.app"), Some("xterm-256color"), false),
            Channel::Osc9
        );
    }

    #[test]
    fn sequences_are_sanitized() {
        // Control chars and OSC field separators are stripped from the payload.
        assert_eq!(
            build_sequence(Channel::Osc9, "OSA", "a\x1b;b"),
            "\x1b]9;OSA: ab\x07"
        );
        assert_eq!(
            build_sequence(Channel::Osc777, "OSA", "ready"),
            "\x1b]777;notify;OSA;ready\x07"
        );
    }
}
