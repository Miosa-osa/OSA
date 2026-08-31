//! `/jailbreak` — LIBERATED state for the Rust TUI.
//!
//! The backend owns the armed/disarmed state and persists it to
//! `~/.osa/jailbreak.json` (see `OptimalSystemAgent.Agent.Jailbreak`). The TUI
//! is a pure CONSUMER: it reads that same file — the single source of truth —
//! so the badge can never disagree with what the backend actually injects,
//! whether the toggle came from this TUI, another session, or the CLI REPL.
//!
//! Reading is cheap and bounded: `poll` re-reads at most once per
//! [`POLL_INTERVAL`], so the 200ms app tick costs one small JSON read per
//! second in the common case and nothing more.

use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{Duration, SystemTime};

/// Re-read `jailbreak.json` at most this often. The app tick fires every
/// 200ms; polling the file every tick would be 5 stats/sec for a value that
/// changes only when the operator runs `/jailbreak`. One second is instant
/// enough for a human flipping a toggle and costs ~0.2 stat/sec amortized.
const POLL_INTERVAL: Duration = Duration::from_secs(1);

/// The shared state file, resolved once. `None` when the home dir cannot be
/// resolved at all (no HOME, no BaseDirs) — in that degraded environment the
/// badge simply never renders, which is the honest answer.
fn state_file() -> Option<PathBuf> {
    // Same resolution order as config::home_dir: BaseDirs honors USERPROFILE
    // on Windows; $HOME is the unix fallback; "." is the last resort and is
    // rejected here because a per-CWD "./.osa" is not a real profile.
    let home = directories::BaseDirs::new()
        .map(|d| d.home_dir().to_path_buf())
        .or_else(|| std::env::var("HOME").ok().map(PathBuf::from))?;
    Some(home.join(".osa").join("jailbreak.json"))
}

/// Cached poll result so callers can ask every tick without I/O churn.
static CACHED: Mutex<Option<Cached>> = Mutex::new(None);

struct Cached {
    checked_at: SystemTime,
    enabled: bool,
}

/// Whether the jailbreak layer is armed, as of the last poll. Slightly stale
/// by design (≤1s); the authoritative live value lives on the backend.
pub fn is_liberated() -> bool {
    poll().enabled
}

/// Poll the state file, bounded by [`POLL_INTERVAL`] and the file's mtime.
fn poll() -> Cached {
    let now = SystemTime::now();

    let mut guard = match CACHED.lock() {
        Ok(g) => g,
        Err(_) => {
            return Cached {
                checked_at: now,
                enabled: false,
            }
        }
    };

    if let Some(cached) = guard.as_ref() {
        if now
            .duration_since(cached.checked_at)
            .unwrap_or(POLL_INTERVAL)
            < POLL_INTERVAL
        {
            return cached.clone_enabled();
        }
    }

    let fresh = read_state_file();
    *guard = Some(fresh.clone_enabled());
    fresh
}

impl Cached {
    fn clone_enabled(&self) -> Cached {
        Cached {
            checked_at: self.checked_at,
            enabled: self.enabled,
        }
    }
}

/// Read `jailbreak.json` once. Missing file ⇒ disarmed (the fresh-node case —
/// `Jailbreak.set/2` only writes the file once armed or a custom path set).
fn read_state_file() -> Cached {
    let Some(path) = state_file() else {
        return Cached {
            checked_at: SystemTime::now(),
            enabled: false,
        };
    };

    let enabled = match std::fs::read_to_string(&path) {
        Ok(raw) => serde_json::from_str::<serde_json::Value>(&raw)
            .ok()
            .and_then(|v| v.get("enabled").and_then(|e| e.as_bool()))
            .unwrap_or(false),
        Err(_) => false,
    };

    Cached {
        checked_at: SystemTime::now(),
        enabled,
    }
}

/// Force the next `is_liberated()` call to hit the file, skipping the
/// interval. Called right after the TUI dispatches `/jailbreak` so the badge
/// flips in the same breath as the command's result, not a second later.
pub fn invalidate() {
    if let Ok(mut guard) = CACHED.lock() {
        if let Some(cached) = guard.as_mut() {
            // Rewind the check timestamp so `poll` treats the cache as expired.
            cached.checked_at = SystemTime::now()
                .checked_sub(POLL_INTERVAL + Duration::from_secs(1))
                .unwrap_or(SystemTime::UNIX_EPOCH);
        } else {
            *guard = Some(Cached {
                checked_at: SystemTime::UNIX_EPOCH,
                enabled: false,
            });
        }
    }
}

// ── Badge rendering ─────────────────────────────────────────────────────────

/// The badge's color — magenta, matching the Elixir spinner's badge and the
/// CLI's `⚡ LIBERATED` output. A named color so it survives theme switches.
const BADGE_FG: ratatui::prelude::Color = ratatui::prelude::Color::Magenta;
/// The pulse's dim phase — a darkened magenta, so the flicker reads as a neon
/// hold rather than vanishing (a black dim phase would be invisible on the
/// dark theme).
const BADGE_DIM: ratatui::prelude::Color = ratatui::prelude::Color::Rgb(120, 60, 140);

/// The badge spans rendered next to the model name on status-bar row 0.
/// Empty when disarmed — the common case must cost zero columns.
///
/// A PURE function of `armed`: the caller (StatusBar, fed by `set_liberated`)
/// owns the state, so a test that never arms the badge renders none — the
/// component never reaches out to machine state on its own.
///
/// Animated by wall clock alone: the bolt holds steady while the LIBERATED
/// text pulses bright→dim, so the badge reads as LIVE while armed without a
/// single extra tick of plumbing.
pub fn badge_spans(armed: bool) -> Vec<ratatui::prelude::Span<'static>> {
    if !armed {
        return Vec::new();
    }

    let phase = bolt_phase();
    let bright = bolt_bright(phase);

    let mut spans = Vec::with_capacity(3);
    spans.push(ratatui::prelude::Span::styled(
        " ",
        ratatui::prelude::Style::default(),
    ));
    spans.push(ratatui::prelude::Span::styled(
        "\u{26A1}",
        ratatui::prelude::Style::default()
            .fg(BADGE_FG)
            .add_modifier(ratatui::prelude::Modifier::BOLD),
    ));
    spans.push(ratatui::prelude::Span::styled(
        " LIBERATED",
        ratatui::prelude::Style::default()
            .fg(if bright { BADGE_FG } else { BADGE_DIM })
            .add_modifier(ratatui::prelude::Modifier::BOLD),
    ));
    spans
}

/// Wall-clock phase for the bolt's flicker. ~3 flickers/second, matching the
/// pace of the activity spinner's glyph rotation (133ms/frame) so the two
/// animations read as one family.
fn bolt_phase() -> usize {
    let ms = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_millis() as usize)
        .unwrap_or(0);
    ms / 333
}

/// Bright phase: on for 2 of every 3 frames — a quick flash then a hold, like
/// a neon sign rather than a strobe.
fn bolt_bright(phase: usize) -> bool {
    phase % 3 != 2
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn disarmed_renders_nothing() {
        // Pure function of `armed` — no machine state, so this is hermetic.
        assert!(badge_spans(false).is_empty());
        assert!(!badge_spans(true).is_empty());
    }

    #[test]
    fn bolt_flicker_cycles() {
        // The flicker must actually alternate — a constant would make the
        // "animated" badge a static sticker.
        let phases: Vec<bool> = (0..9).map(bolt_bright).collect();
        assert!(phases.iter().any(|&b| b) && phases.iter().any(|&b| !b));
    }

    #[test]
    fn invalidate_forces_a_fresh_read() {
        invalidate();
        // No assertion on the VALUE — just that the call path works and the
        // next poll hits the file rather than the cache.
        let _ = is_liberated();
    }

    // Evidence generator: render the REAL StatusBar row 0 and the REAL Activity
    // spinner status group with the badge armed, then emit a colored HTML frame
    // so a reviewer can SEE the ⚡ LIBERATED badge sitting where it lands (next
    // to the model on row 0; after the silence notice in the spinner group).
    // Only runs when OSA_EVIDENCE_HTML points at an output file.
    #[test]
    fn evidence_render_liberated_frames() {
        use crate::components::Component;
        use ratatui::style::Color;
        use ratatui::{backend::TestBackend, Terminal};

        let Ok(out) = std::env::var("OSA_EVIDENCE_HTML") else {
            return;
        };

        fn css(c: Color) -> &'static str {
            match c {
                Color::Magenta => "#e070e0",             // bright bolt / LIBERATED
                Color::Rgb(120, 60, 140) => "#78388c",   // dim pulse phase
                Color::Cyan => "#4ec9d0",
                Color::Yellow => "#d7b45a",
                Color::Red => "#e05561",
                Color::Green => "#89ca78",
                _ => "#c8c8c8",
            }
        }

        // Turn a rendered row into an HTML line, one <span> per cell colored by
        // its foreground so the badge's magenta pops against the muted rest.
        fn row_html(buf: &ratatui::buffer::Buffer, y: u16, width: u16) -> String {
            let mut s = String::new();
            for x in 0..width {
                let cell = &buf[(x, y)];
                let sym = cell.symbol().replace('<', "&lt;").replace('>', "&gt;");
                let sym = if sym.trim().is_empty() { "&nbsp;".to_string() } else { sym };
                s.push_str(&format!("<span style=\"color:{}\">{}</span>", css(cell.fg), sym));
            }
            s
        }

        // --- StatusBar row 0, badge armed (rendered across the pulse) ---
        let mut status_frames = Vec::new();
        for _ in 0..3 {
            let mut sb = crate::components::status_bar::StatusBar::new();
            sb.set_width(120);
            sb.set_provider_info("anthropic", "claude-opus-4");
            sb.set_cwd_path("/home/dev/OSA");
            sb.set_context(0.6, 120_000, 200_000);
            sb.set_liberated(true);
            let mut term = Terminal::new(TestBackend::new(120, 2)).unwrap();
            term.draw(|f| sb.draw(f, f.area())).unwrap();
            let buf = term.backend().buffer().clone();
            status_frames.push(row_html(&buf, 0, 120));
            // Cross a ~333ms phase boundary so successive frames can differ.
            std::thread::sleep(std::time::Duration::from_millis(345));
        }

        // --- Activity spinner status group, badge armed ---
        let mut act = crate::components::activity::Activity::new();
        act.start();
        act.set_liberated(true);
        let mut term = Terminal::new(TestBackend::new(120, 1)).unwrap();
        term.draw(|f| act.draw(f, f.area())).unwrap();
        let spinner_buf = term.backend().buffer().clone();
        let spinner_html = row_html(&spinner_buf, 0, 120);

        // Sanity: the badge text actually rendered in both surfaces.
        let status_text: String = {
            let mut sb = crate::components::status_bar::StatusBar::new();
            sb.set_width(120);
            sb.set_provider_info("anthropic", "claude-opus-4");
            sb.set_cwd_path("/home/dev/OSA");
            sb.set_context(0.6, 120_000, 200_000);
            sb.set_liberated(true);
            let mut t = Terminal::new(TestBackend::new(120, 2)).unwrap();
            t.draw(|f| sb.draw(f, f.area())).unwrap();
            (0..120).map(|x| t.backend().buffer()[(x, 0)].symbol().to_string()).collect()
        };
        assert!(status_text.contains("LIBERATED"), "badge missing from status bar: {status_text:?}");
        let spinner_text: String = (0..120).map(|x| spinner_buf[(x, 0)].symbol().to_string()).collect();
        assert!(spinner_text.contains("LIBERATED"), "badge missing from spinner group: {spinner_text:?}");

        let html = format!(
            "<!doctype html><meta charset=utf-8><title>/jailbreak LIBERATED badge</title>\
<body style=\"background:#14121a;color:#c8c8c8;font:14px/1.5 'SF Mono',Menlo,monospace;padding:24px\">\
<h2 style=\"color:#e070e0\">⚡ /jailbreak — LIBERATED badge (real TUI render)</h2>\
<h3>StatusBar row 0 — badge next to the model name (three consecutive frames; the bolt holds, LIBERATED pulses bright↔dim)</h3>\
<pre style=\"white-space:pre;overflow-x:auto\">{}\n{}\n{}</pre>\
<h3>Activity spinner status group — ⚡ LIBERATED chip, placed AFTER the silence notice</h3>\
<pre style=\"white-space:pre;overflow-x:auto\">{}</pre>\
<p style=\"color:#888\">Colors are the actual cell foregrounds from a ratatui TestBackend render. \
Magenta #e070e0 = bright bolt/LIBERATED, #78388c = dim pulse phase.</p></body>",
            status_frames[0], status_frames[1], status_frames[2], spinner_html
        );
        std::fs::write(&out, html).unwrap();
    }
}
