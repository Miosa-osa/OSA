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

/// Strip control characters so directory names can never smuggle escape
/// sequences into the OSC payload.
fn sanitize(s: &str) -> String {
    s.chars().filter(|c| !c.is_control()).collect()
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

/// Build the raw OSC 0 (icon + window title) sequence.
fn build_sequence(title: &str) -> String {
    format!("\x1b]0;{}\x07", title)
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
    pub fn update(&mut self, title: &str) {
        if !self.enabled || title == self.last {
            return;
        }
        self.last = title.to_string();
        Self::write(build_sequence(title));
    }

    /// Restore an empty title on exit so the shell's own title logic takes over.
    pub fn reset(&mut self) {
        if !self.enabled {
            return;
        }
        self.last.clear();
        Self::write(build_sequence(""));
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
}
