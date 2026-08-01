//! **One size per frame.**
//!
//! The live region kept producing the same defect in new disguises — a composer
//! duplicating down the screen on resize, a roster reserving 30 rows and drawing
//! 34, a plan band stealing rows from the streaming reply — and every instance
//! had the same shape: *two parts of one frame disagreed about how big the
//! terminal was.*
//!
//! It was structurally possible because a single frame read the terminal size
//! from THREE independent places:
//!
//!   * `desired_inline_height` queried `crossterm::terminal::size()` live for the
//!     row count,
//!   * the same function read `App::width` for the column count — a value written
//!     by the *Resize event*, which lags the ioctl,
//!   * the scrollback-commit path read `terminal.get_frame().area().width`, which
//!     is whatever width the viewport was last *built* at.
//!
//! During a resize drag those three are routinely three different numbers, so
//! the height computed for the viewport, the width the bands were measured at,
//! and the width the finalized messages were rendered at all disagreed — and a
//! disagreement between a reservation and a paint is, by construction, a
//! component drawing where nothing reserved.
//!
//! The cure is the one Codex pins with a test (`codex-rs/tui/custom_terminal.rs`,
//! `resize_draw_applies_event_dimensions_without_querying_backend_size`): a frame
//! gets ONE size, captured once, threaded everywhere, and the backend is not
//! consulted again while that frame is being laid out.
//!
//! Here that is [`FrameSize`], sampled exactly once per run-loop iteration by
//! `App::sample_frame_size`. This module owns the *only* call to
//! `crossterm::terminal::size()` in the TUI; the
//! `terminal_size_is_read_from_exactly_one_place` test walks the source tree and
//! fails if a second one appears, so the invariant cannot rot back in.

use std::sync::atomic::{AtomicUsize, Ordering};

/// Fallback used when the terminal cannot report its size (not a tty, an ioctl
/// failure under an exotic multiplexer). The historical value every call site
/// already used independently.
pub(crate) const FALLBACK: (u16, u16) = (80, 24);

/// Number of times the backend has been asked for its size. Process-global and
/// always compiled in (a relaxed atomic increment is free next to an ioctl), so
/// the "a resize frame does not query the backend" property is observable from a
/// test without a mock backend.
static PROBES: AtomicUsize = AtomicUsize::new(0);

/// The terminal size ONE frame is laid out against.
///
/// Both fields come from the same observation. Passing this struct around —
/// rather than a bare `term_rows` with the columns read from somewhere else — is
/// what makes "the height and the width came from the same moment" a type-level
/// fact instead of a convention.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct FrameSize {
    pub cols: u16,
    pub rows: u16,
}

impl FrameSize {
    pub(crate) fn new(cols: u16, rows: u16) -> Self {
        Self { cols, rows }
    }

    /// The dimensions carried by a terminal `Resize` event.
    ///
    /// Preferred over [`probe`] whenever an event is pending: the event *is* the
    /// authoritative report of the reflow that just happened, and taking it
    /// means a resize frame never consults the backend — Codex's rule, and the
    /// property `resize_frame_does_not_probe_the_backend` asserts.
    pub(crate) fn from_resize_event(cols: u16, rows: u16) -> Self {
        Self::new(cols, rows)
    }
}

/// Ask the terminal how big it is. **The only `crossterm::terminal::size()` call
/// site in the TUI** — see the module docs and the source-guard test.
pub(crate) fn probe() -> FrameSize {
    PROBES.fetch_add(1, Ordering::Relaxed);
    let (cols, rows) = crossterm::terminal::size().unwrap_or(FALLBACK);
    FrameSize::new(cols, rows)
}

/// How many times the backend has been asked for its size so far.
pub(crate) fn probe_count() -> usize {
    PROBES.load(Ordering::Relaxed)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A resize frame takes its dimensions from the EVENT, never from the
    /// backend. The direct analogue of Codex's
    /// `resize_draw_applies_event_dimensions_without_querying_backend_size`.
    #[test]
    fn resize_frame_does_not_probe_the_backend() {
        let before = probe_count();
        let size = FrameSize::from_resize_event(132, 43);
        assert_eq!(size.cols, 132);
        assert_eq!(size.rows, 43);
        assert_eq!(
            probe_count(),
            before,
            "constructing a frame size from a resize event must not query the terminal"
        );
    }

    /// A non-resize frame samples the backend EXACTLY once.
    #[test]
    fn a_probe_costs_exactly_one_backend_query() {
        let before = probe_count();
        let _ = probe();
        assert_eq!(probe_count(), before + 1);
    }

    /// **The enforcement test.** Walks the whole TUI source tree and fails if
    /// `crossterm::terminal::size` is called anywhere but here.
    ///
    /// Three independent size reads per frame is what made the layout bugs
    /// possible; a comment saying "don't do that again" is not an invariant. A
    /// grep is. Doc comments and this module are exempt (they name the symbol
    /// deliberately); everything else must go through [`probe`].
    #[test]
    fn terminal_size_is_read_from_exactly_one_place() {
        fn walk(dir: &std::path::Path, out: &mut Vec<std::path::PathBuf>) {
            let Ok(entries) = std::fs::read_dir(dir) else {
                return;
            };
            for entry in entries.flatten() {
                let path = entry.path();
                if path.is_dir() {
                    walk(&path, out);
                } else if path.extension().is_some_and(|e| e == "rs") {
                    out.push(path);
                }
            }
        }

        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
        let mut files = Vec::new();
        walk(&root, &mut files);
        assert!(!files.is_empty(), "found no sources under {}", root.display());

        let mut offenders: Vec<String> = Vec::new();
        for path in files {
            if path.file_name().is_some_and(|f| f == "frame_size.rs") {
                continue; // this module owns the call
            }
            let Ok(text) = std::fs::read_to_string(&path) else {
                continue;
            };
            for (i, line) in text.lines().enumerate() {
                let trimmed = line.trim_start();
                // Prose is allowed to name it; code is not.
                if trimmed.starts_with("//") || trimmed.starts_with("*") {
                    continue;
                }
                if line.contains("crossterm::terminal::size") || line.contains("terminal::size()") {
                    offenders.push(format!("{}:{}: {}", path.display(), i + 1, line.trim()));
                }
            }
        }

        assert!(
            offenders.is_empty(),
            "the terminal size must be read only via `app::frame_size::probe()`, so one \
             frame is laid out against ONE size. Extra call sites:\n{}",
            offenders.join("\n")
        );
    }
}
