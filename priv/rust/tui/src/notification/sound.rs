//! Audio attention cue on turn completion (U-T16), focus-gated.
//!
//! Claude Code plays a subtle sound when a turn finishes AND the terminal is
//! unfocused (never while you're watching). We mirror that: the cue is emitted
//! only when [`crate::notification::focus`] reports the terminal is unfocused.
//!
//! Two layers, best-effort:
//!   1. A real system sound via the OS player (`paplay`/`afplay`) when we can
//!      find one — a pleasant ding rather than a raw beep.
//!   2. A terminal BEL (`\x07`) fallback, which every terminal can make audible.
//!
//! The player is spawned detached; a missing binary or sound file just falls
//! through to the BEL. Never blocks, never panics.
#![allow(dead_code)]

use std::io::Write;

/// Whether an attention cue should fire, given focus state. Pure so the gate is
/// unit-testable: cue only when the user is away.
pub fn should_play(is_focused: bool) -> bool {
    !is_focused
}

/// The argv for a system-sound player on a given OS, or `None` to fall back to
/// the BEL. Pure for testing. Uses sounds that ship with the OS so there is no
/// asset to bundle.
pub fn player_argv(os: &str) -> Option<(&'static str, Vec<&'static str>)> {
    match os {
        // macOS: the classic completion tink.
        "macos" => Some(("afplay", vec!["/System/Library/Sounds/Glass.aiff"])),
        // Linux: freedesktop "complete" sound if present; paplay tolerates a
        // missing file by exiting non-zero, which we ignore.
        "linux" => Some((
            "paplay",
            vec!["/usr/share/sounds/freedesktop/stereo/complete.oga"],
        )),
        _ => None,
    }
}

/// Emit the terminal BEL (audible ding on every terminal).
fn bell() {
    let mut out = std::io::stdout();
    let _ = out.write_all(b"\x07");
    let _ = out.flush();
}

/// Try to play a real system sound; return true if a player was spawned.
fn play_system_sound() -> bool {
    if let Some((prog, args)) = player_argv(std::env::consts::OS) {
        let spawned = std::process::Command::new(prog)
            .args(args)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .is_ok();
        if spawned {
            return true;
        }
    }
    false
}

/// Fire the attention cue *if* the user is away. Prefers a system sound and
/// always also rings the BEL so a terminal without an audio player still dings.
pub fn attention_cue(is_focused: bool) {
    if !should_play(is_focused) {
        return;
    }
    // The BEL is the reliable baseline; the system sound is a nicety on top.
    let _ = play_system_sound();
    bell();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_plays_when_unfocused() {
        assert!(!should_play(true));
        assert!(should_play(false));
    }

    #[test]
    fn player_per_os() {
        assert_eq!(player_argv("macos").unwrap().0, "afplay");
        assert_eq!(player_argv("linux").unwrap().0, "paplay");
        assert!(player_argv("freebsd").is_none());
    }
}
