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

/// Base64-encode `text` and build the raw `OSC 52 ; c ; <b64>` sequence that
/// sets the primary ("clipboard") selection.
fn build_sequence(text: &str) -> String {
    let b64 = STANDARD.encode(text.as_bytes());
    format!("{ESC}]52;c;{b64}{BEL}")
}

/// Terminal multiplexers swallow OSC sequences that aren't addressed to them,
/// so a raw OSC 52 never reaches the outer terminal. tmux and screen each
/// expose a DCS passthrough that forwards the wrapped bytes verbatim.
///
/// - tmux (`$TMUX`): `ESC P tmux ; <seq, ESC doubled> ESC \`
/// - screen (`$STY`): `ESC P <seq> ESC \`
fn wrap_for_multiplexer(sequence: String) -> String {
    if std::env::var_os("TMUX").is_some() {
        let escaped = sequence.replace(ESC, &format!("{ESC}{ESC}"));
        return format!("{ESC}Ptmux;{escaped}{ST}");
    }
    if std::env::var_os("STY").is_some() {
        return format!("{ESC}P{sequence}{ST}");
    }
    sequence
}

/// Write `text` to the system clipboard via the terminal (OSC 52).
///
/// Works over SSH and inside tmux/screen. Emitting to stdout is safe while the
/// TUI holds the terminal in raw mode: the sequence is invisible and does not
/// disturb the rendered frame. Returns any write/flush error so the caller can
/// fall back to `arboard`.
pub fn copy(text: &str) -> io::Result<()> {
    let sequence = wrap_for_multiplexer(build_sequence(text));
    let mut stdout = io::stdout();
    stdout.write_all(sequence.as_bytes())?;
    stdout.flush()
}
