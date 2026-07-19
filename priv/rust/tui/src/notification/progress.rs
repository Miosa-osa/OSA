//! Taskbar / dock progress via OSC 9;4 (U-T12).
//!
//! `OSC 9 ; 4 ; <state> ; <pct> ST` is the ConEmu progress protocol, adopted by
//! Windows Terminal, WezTerm, ghostty, and others. It paints a progress bar on
//! the taskbar/dock icon so a backgrounded OSA turn shows life. States:
//!   0 = clear/remove   1 = normal (0..100%)   2 = error
//!   3 = indeterminate  4 = warning (paused)
//!
//! Claude Code uses the indeterminate state (3) for the duration of a turn and
//! clears it (0) on completion; we mirror that, and additionally support a
//! determinate value so a lane with real progress (e.g. a long tool with a
//! percentage) can show it. A `keepalive` re-emit exists because some terminals
//! time the bar out; re-issuing the same indeterminate sequence keeps it lit.
//!
//! Sequences are consumed by the terminal, so writing them mid-render never
//! disturbs the ratatui frame. tmux/screen passthrough mirrors `osc52.rs`.
#![allow(dead_code)]

use std::io::Write;

const ESC: char = '\x1b';
const BEL: char = '\x07';
const ST: &str = "\x1b\\";

/// A progress state to render on the taskbar icon.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Progress {
    /// Remove the progress indicator (state 0).
    Clear,
    /// Busy with no known percentage (state 3) — the long-turn default.
    Indeterminate,
    /// Determinate 0..=100 percent (state 1). Values are clamped.
    Value(u8),
    /// Error stop (state 2).
    Error,
    /// Paused / warning (state 4).
    Warning,
}

impl Progress {
    /// ConEmu numeric state code.
    fn state_code(self) -> u8 {
        match self {
            Progress::Clear => 0,
            Progress::Value(_) => 1,
            Progress::Error => 2,
            Progress::Indeterminate => 3,
            Progress::Warning => 4,
        }
    }

    /// Percent field (0 for non-determinate states; clamped to 100).
    fn pct(self) -> u8 {
        match self {
            Progress::Value(p) => p.min(100),
            _ => 0,
        }
    }
}

/// Build the raw `OSC 9 ; 4 ; state ; pct` sequence (BEL-terminated, the widely
/// accepted form). No multiplexer wrapping.
pub fn build_sequence(progress: Progress) -> String {
    format!(
        "{ESC}]9;4;{};{}{BEL}",
        progress.state_code(),
        progress.pct()
    )
}

/// tmux/screen DCS passthrough (same contract as `osc52::wrap_for_multiplexer`).
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

/// Emit a progress state to the terminal.
fn emit(progress: Progress) {
    let seq = wrap_for_multiplexer(build_sequence(progress));
    let mut out = std::io::stdout();
    let _ = out.write_all(seq.as_bytes());
    let _ = out.flush();
}

/// Begin an indeterminate (busy) progress bar for a long turn.
pub fn start() {
    emit(Progress::Indeterminate);
}

/// Re-assert the indeterminate bar so terminals that time it out keep it lit.
/// Call on a slow cadence (e.g. every few seconds) during a long turn.
pub fn keepalive() {
    emit(Progress::Indeterminate);
}

/// Update to a determinate percentage (0..=100).
pub fn set_percent(pct: u8) {
    emit(Progress::Value(pct));
}

/// Clear the progress bar (turn complete / cancelled).
pub fn done() {
    emit(Progress::Clear);
}

/// Show the error/stop state (turn failed).
pub fn error() {
    emit(Progress::Error);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn state_codes_and_percent() {
        assert_eq!(build_sequence(Progress::Clear), "\x1b]9;4;0;0\x07");
        assert_eq!(build_sequence(Progress::Value(42)), "\x1b]9;4;1;42\x07");
        assert_eq!(build_sequence(Progress::Error), "\x1b]9;4;2;0\x07");
        assert_eq!(build_sequence(Progress::Indeterminate), "\x1b]9;4;3;0\x07");
        assert_eq!(build_sequence(Progress::Warning), "\x1b]9;4;4;0\x07");
    }

    #[test]
    fn percent_is_clamped() {
        assert_eq!(build_sequence(Progress::Value(255)), "\x1b]9;4;1;100\x07");
        assert_eq!(build_sequence(Progress::Value(100)), "\x1b]9;4;1;100\x07");
        assert_eq!(build_sequence(Progress::Value(0)), "\x1b]9;4;1;0\x07");
    }
}
