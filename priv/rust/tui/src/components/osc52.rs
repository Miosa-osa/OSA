//! OSC 52 clipboard write — the SSH-safe way to set the system clipboard.
//!
//! `arboard` talks to the local windowing system (X11/Wayland/macOS/Win32),
//! which silently fails when OSA runs over SSH on a headless box: there is no
//! local display to write to. OSC 52 sidesteps that by asking the *terminal
//! emulator* to update its host's clipboard, so the copy lands on whatever
//! machine the user is actually sitting at — even across an SSH hop.
//!
//! Ported from Hermes `lib/osc52.ts` (MIT). We only implement the write path;
//! paste stays on arboard + bracketed paste.

use std::io::{self, Write};

use base64::{engine::general_purpose::STANDARD, Engine as _};

const ESC: char = '\x1b';
const BEL: char = '\x07';
const ST: &str = "\x1b\\";

/// Largest payload we will hand to OSC 52, in bytes of the ORIGINAL text.
///
/// There is no acknowledgement on this channel, so an over-long sequence does
/// not fail loudly — the terminal (or the multiplexer in front of it) simply
/// drops it, and the user is told the copy worked while their clipboard still
/// holds whatever was in it before. Refusing up front is the only way to be
/// honest about it. 768 KiB matches the reference implementation's cap.
pub const MAX_PAYLOAD_BYTES: usize = 768 * 1024;

/// Why an OSC 52 write did not happen. Distinct from a plain io error because
/// the caller must be able to say *which* to the user: a payload we refused is
/// a definite non-copy, and a write error is a definite non-copy, but a
/// successful write is only ever "the bytes left the process".
#[derive(Debug)]
pub enum Osc52Error {
    /// Payload exceeded [`MAX_PAYLOAD_BYTES`]; nothing was emitted.
    TooLarge { bytes: usize, cap: usize },
    /// stdout write/flush failed.
    Io(io::Error),
}

impl std::fmt::Display for Osc52Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Osc52Error::TooLarge { bytes, cap } => write!(
                f,
                "payload is {} KiB, over the {} KiB OSC 52 limit",
                bytes / 1024,
                cap / 1024
            ),
            Osc52Error::Io(e) => write!(f, "{e}"),
        }
    }
}

/// Base64-encode `text` and build the raw `OSC 52 ; c ; <b64>` sequence that
/// sets the primary ("clipboard") selection.
fn build_sequence(text: &str) -> String {
    let b64 = STANDARD.encode(text.as_bytes());
    format!("{ESC}]52;c;{b64}{BEL}")
}

/// The multiplexer whose DCS passthrough the sequence must be wrapped in, if
/// any. Decided from the environment by [`multiplexer_with`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Multiplexer {
    None,
    Tmux,
    Screen,
}

/// Environment markers set by terminal emulators that RUN INSIDE a multiplexer
/// pane. Their children inherit `$TMUX`/`$STY` from the pane, but the emulator
/// immediately in front of them is the editor's own terminal (libvterm, etc.),
/// not tmux — so the DCS passthrough must not be used.
const NESTED_TERMINAL_MARKERS: &[&str] = &[
    // Neovim `:terminal` (nvim >= 0.5 exports $NVIM to the job's environment).
    "NVIM",
    // Older Neovim / remote-plugin hosts.
    "NVIM_LISTEN_ADDRESS",
    // Vim 8 `:terminal`.
    "VIM_TERMINAL",
    // Emacs term/vterm/eshell.
    "INSIDE_EMACS",
    // Zellij panes: $ZELLIJ is set by zellij itself, which is the immediate
    // emulator even if the whole session was launched from inside tmux.
    "ZELLIJ",
];

/// Decide which multiplexer passthrough (if any) applies, from an injectable
/// environment. Pure so the nesting rules are unit-testable.
///
/// `$TMUX` and `$STY` are **inherited by every descendant of the pane**, not
/// just by the shell talking directly to the multiplexer. Keying purely off
/// their presence — which is what this used to do — means that inside
/// `nvim :terminal` (a tmux pane child) OSA wraps the sequence for tmux, but the
/// emulator actually reading stdout is the editor's libvterm, which does not
/// implement the `ESC P tmux;` passthrough. The wrapper is then printed into the
/// buffer as literal `ESC Ptmux;…` garbage and the copy does not land.
///
/// So: require the multiplexer marker AND the absence of any nested-terminal
/// marker AND a `TERM` that the multiplexer itself would have set.
pub fn multiplexer_with(env: impl Fn(&str) -> Option<String>) -> Multiplexer {
    if NESTED_TERMINAL_MARKERS
        .iter()
        .any(|k| env(k).is_some_and(|v| !v.is_empty()))
    {
        return Multiplexer::None;
    }
    let term = env("TERM").unwrap_or_default();
    // tmux sets TERM to `tmux*` (or `screen*` under its compat terminfo) and
    // exports $TMUX_PANE alongside $TMUX for every pane it owns.
    if env("TMUX").is_some()
        && env("TMUX_PANE").is_some()
        && (term.starts_with("tmux") || term.starts_with("screen"))
    {
        return Multiplexer::Tmux;
    }
    // GNU screen: $STY has exactly the same inheritance problem as $TMUX, so it
    // gets the same treatment. screen always sets TERM to `screen*`.
    if env("STY").is_some() && term.starts_with("screen") {
        return Multiplexer::Screen;
    }
    Multiplexer::None
}

/// Terminal multiplexers swallow OSC sequences that aren't addressed to them,
/// so a raw OSC 52 never reaches the outer terminal. tmux and screen each
/// expose a DCS passthrough that forwards the wrapped bytes verbatim.
///
/// - tmux: `ESC P tmux ; <seq, ESC doubled> ESC \`
/// - screen: `ESC P <seq> ESC \`
pub fn wrap_for(mux: Multiplexer, sequence: String) -> String {
    match mux {
        Multiplexer::Tmux => {
            let escaped = sequence.replace(ESC, &format!("{ESC}{ESC}"));
            format!("{ESC}Ptmux;{escaped}{ST}")
        }
        Multiplexer::Screen => format!("{ESC}P{sequence}{ST}"),
        Multiplexer::None => sequence,
    }
}

/// Whether the process is running under a multiplexer whose passthrough we use.
pub fn detected_multiplexer() -> Multiplexer {
    multiplexer_with(|k| std::env::var(k).ok())
}

/// Write `text` to the system clipboard via the terminal (OSC 52).
///
/// Works over SSH and inside tmux/screen. Emitting to stdout is safe while the
/// TUI holds the terminal in raw mode: the sequence is invisible and does not
/// disturb the rendered frame.
///
/// **`Ok(())` means "the bytes were written to stdout", NOT "the clipboard was
/// set".** OSC 52 has no reply, so a terminal that does not implement it (or has
/// it disabled, which is the xterm/VTE default) is indistinguishable here from
/// one that does. Callers must not translate this into a "Copied" message on its
/// own — see [`crate::clipboard::copy`], which pairs it with a capability probe
/// and an on-disk fallback.
pub fn copy(text: &str) -> Result<(), Osc52Error> {
    if text.len() > MAX_PAYLOAD_BYTES {
        return Err(Osc52Error::TooLarge {
            bytes: text.len(),
            cap: MAX_PAYLOAD_BYTES,
        });
    }
    let sequence = wrap_for(detected_multiplexer(), build_sequence(text));
    let mut stdout = io::stdout();
    stdout.write_all(sequence.as_bytes()).map_err(Osc52Error::Io)?;
    stdout.flush().map_err(Osc52Error::Io)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn env_of(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
        let map: HashMap<String, String> = pairs
            .iter()
            .map(|(k, v)| ((*k).to_string(), (*v).to_string()))
            .collect();
        move |k: &str| map.get(k).cloned()
    }

    /// A real tmux pane: wrap.
    #[test]
    fn tmux_pane_gets_the_passthrough() {
        assert_eq!(
            multiplexer_with(env_of(&[
                ("TMUX", "/tmp/tmux-1000/default,123,0"),
                ("TMUX_PANE", "%4"),
                ("TERM", "tmux-256color"),
            ])),
            Multiplexer::Tmux
        );
    }

    /// `nvim :terminal` INSIDE a tmux pane inherits $TMUX/$TMUX_PANE, but the
    /// immediate emulator is the editor's libvterm. Wrapping there prints
    /// literal `ESC Ptmux;…` into the buffer and the copy never lands.
    #[test]
    fn nested_editor_terminal_does_not_get_the_tmux_passthrough() {
        assert_eq!(
            multiplexer_with(env_of(&[
                ("TMUX", "/tmp/tmux-1000/default,123,0"),
                ("TMUX_PANE", "%4"),
                ("TERM", "xterm-256color"),
                ("NVIM", "/run/user/1000/nvim.1.0"),
            ])),
            Multiplexer::None
        );
        // Even with a tmux-looking TERM, the nested marker wins.
        assert_eq!(
            multiplexer_with(env_of(&[
                ("TMUX", "/tmp/tmux-1000/default,123,0"),
                ("TMUX_PANE", "%4"),
                ("TERM", "tmux-256color"),
                ("INSIDE_EMACS", "29.1,vterm"),
            ])),
            Multiplexer::None
        );
    }

    /// $TMUX leaked into a child whose TERM is not tmux's is not a tmux pane.
    #[test]
    fn inherited_tmux_env_alone_is_not_enough() {
        assert_eq!(
            multiplexer_with(env_of(&[
                ("TMUX", "/tmp/tmux-1000/default,123,0"),
                ("TERM", "xterm-256color"),
            ])),
            Multiplexer::None
        );
    }

    /// $STY has the identical inheritance problem, so it gets the identical gate.
    #[test]
    fn screen_needs_a_screen_term_and_no_nesting() {
        assert_eq!(
            multiplexer_with(env_of(&[("STY", "1234.pts-0.host"), ("TERM", "screen")])),
            Multiplexer::Screen
        );
        assert_eq!(
            multiplexer_with(env_of(&[
                ("STY", "1234.pts-0.host"),
                ("TERM", "screen"),
                ("NVIM", "/run/user/1000/nvim.1.0"),
            ])),
            Multiplexer::None
        );
    }

    #[test]
    fn plain_terminal_is_unwrapped() {
        assert_eq!(
            multiplexer_with(env_of(&[("TERM", "xterm-256color")])),
            Multiplexer::None
        );
        assert_eq!(wrap_for(Multiplexer::None, "\x1b]52;c;YQ==\x07".into()), "\x1b]52;c;YQ==\x07");
    }

    #[test]
    fn tmux_wrapper_doubles_escapes() {
        let wrapped = wrap_for(Multiplexer::Tmux, "\x1b]52;c;YQ==\x07".into());
        assert!(wrapped.starts_with("\x1bPtmux;"));
        assert!(wrapped.ends_with("\x1b\\"));
        assert!(wrapped.contains("\x1b\x1b]52;c;YQ=="));
    }

    /// A payload over the cap is REFUSED rather than emitted-and-dropped, so the
    /// caller can tell the user the truth instead of "Copied to clipboard".
    #[test]
    fn oversized_payload_is_refused_not_silently_dropped() {
        let big = "x".repeat(MAX_PAYLOAD_BYTES + 1);
        match copy(&big) {
            Err(Osc52Error::TooLarge { bytes, cap }) => {
                assert_eq!(bytes, MAX_PAYLOAD_BYTES + 1);
                assert_eq!(cap, MAX_PAYLOAD_BYTES);
            }
            other => panic!("expected TooLarge, got {other:?}"),
        }
    }

    #[test]
    fn sequence_shape_is_osc52_clipboard() {
        let seq = build_sequence("hi");
        assert_eq!(seq, "\x1b]52;c;aGk=\x07");
    }
}
