//! A `CrosstermBackend` that can be told where the cursor is instead of asking.
//!
//! # Why this exists
//!
//! Ratatui builds a `Viewport::Inline` region by asking the terminal where the
//! cursor is — `Terminal::with_options` → `compute_inline_size` →
//! `Backend::get_cursor_position`, which for `CrosstermBackend` is a **DSR round
//! trip**: write `ESC[6n`, then block reading stdin until the reply arrives.
//!
//! OSA rebuilds that viewport whenever the live region changes height, and while
//! a reply streams the preview grows a row at a time. Measured on a real PTY
//! against a real provider: **26 rebuilds in a single 5-second turn** (5.1/s),
//! each one emitting two `ESC[6n` (one from the caller's priming probe, one from
//! ratatui's own construction).
//!
//! The round trip is not the expensive part on its own. The expensive part is
//! everything it forces around itself:
//!
//! * the DSR reply arrives on **stdin**, which the terminal event reader also
//!   owns, so every rebuild had to `abort()` the reader task and respawn it
//!   afterwards — and a keystroke that lands inside that window is read by
//!   nobody. Mid-stream, 7 of 7 keystrokes were never echoed within 5 s each,
//!   and a paste never appeared at all. That is the "the composer is frozen
//!   while it streams" report, in full;
//! * the caller primed the query in a loop of **up to 40 × 25 ms blocking
//!   sleeps** on the event loop's own thread, so a terminal that drops the
//!   reply (tmux and SSH both do, intermittently) stalls the whole UI for up to
//!   a second per rebuild — 26 times a turn.
//!
//! # The observation this rests on
//!
//! **Every inline rebuild already knows where the cursor is, because it just put
//! it there.** The rebuild paths in `event_loop` compute the row the region must
//! start on (`new_top`) and `MoveTo(0, new_top)` immediately before rebuilding —
//! precisely so `Viewport::Inline` anchors where they want it. Asking the
//! terminal to read that row back is a round trip to learn a number we wrote.
//!
//! So: hand ratatui the answer. [`InlineBackend::primed_at`] returns the primed
//! position from `get_cursor_position` **once** and then falls through to the
//! real query, because ratatui asks exactly once per construction and any later
//! caller (a stray `autoresize`) deserves the truth rather than a stale row.
//! Every other `Backend` method delegates untouched.
//!
//! With no DSR there is no stdin read, so there is nothing for the event reader
//! to steal — and therefore no reason to tear the reader down. That is the half
//! of this that the composer actually feels.
//!
//! # Where the primed row is *not* known
//!
//! Boot ([`crate::main`]) primes from the startup probe's CPR answer when the
//! terminal gave one. Only a boot whose probe went unanswered, and the
//! fallback ladders in `event_loop`, still construct unprimed
//! ([`InlineBackend::inline`]) and query for real — each behind a retry ladder
//! that degrades to full screen rather than failing.
//!
//! # The other query: ratatui's `autoresize`
//!
//! Priming covers construction. It did not cover the query ratatui issues on
//! its own: every `Terminal::draw` begins with `autoresize`, which compares
//! `Backend::size()` against the size the viewport was built at and, for an
//! inline viewport, re-anchors it through `compute_inline_size` — a fresh,
//! unprimed `ESC[6n`. A resize that lands between the run loop's one size
//! sample and its draw (routine during a drag, and far more likely when the
//! machine is busy) therefore issued a DSR from inside `draw`, and a reply that
//! did not arrive in crossterm's 2 s window came back as
//! `The cursor position could not be read within a normal duration` — which
//! `draw()?` propagated as fatal, killing the TUI mid-resize. Backtraces from
//! the PTY resize suite put every one of those exits on
//! `draw → autoresize → resize → compute_inline_size`.
//!
//! That re-anchor was never wanted anyway: OSA owns resizes itself (the
//! resize-settle window, then `InlineChrome` purging and replaying at a known
//! top), and `app::frame_size` already forbids a second size observer inside a
//! frame. So an inline backend is **built for one size** — the run loop's
//! [`FrameSize`](crate::app::frame_size::FrameSize) for the frame that built
//! it — and [`Backend::size`] answers that size for the backend's whole life.
//! `autoresize` then never sees a mismatch, never re-anchors, and never
//! queries. The real resize is still seen — by the next iteration's
//! `frame_size::probe`, which marks the viewport dirty and rebuilds it through
//! `InlineChrome` with a fresh backend built for the new size.
//!
//! Taking the size from the frame rather than from a fresh ioctl at
//! construction is load-bearing, not tidiness: under a resize storm the ioctl
//! can already report a NEWER size than the one the frame is laid out at, and
//! the scrollback replay then renders rows `FrameSize::cols` wide into
//! `insert_before` buffers built at the narrower ioctl width — an
//! out-of-bounds buffer index, i.e. a panic, reproduced by the same PTY drag.
//!
//! Full-screen terminals (the alternate screen) use [`InlineBackend::new`],
//! which neither primes nor latches: a full-screen `autoresize` issues no
//! cursor query, and the dialogs rely on it to reflow.

use ratatui::backend::{Backend, ClearType, CrosstermBackend, WindowSize};
use ratatui::buffer::Cell;
use ratatui::layout::{Position, Size};
use std::io;

/// `CrosstermBackend` with an optional, one-shot answer for the cursor query
/// and, for inline viewports, a size fixed at construction.
pub struct InlineBackend<W: io::Write> {
    inner: CrosstermBackend<W>,
    /// Where the cursor is *known* to be, if the caller put it there. Taken by
    /// the first [`Backend::get_cursor_position`]; `None` afterwards, so a
    /// second asker gets the real terminal rather than a stale row.
    primed: Option<Position>,
    /// The size an inline backend was built for, answered by every
    /// [`Backend::size`] call; `None` (live) for full screen. See the module
    /// docs, "The other query".
    latched: Option<Size>,
    /// Test seam: how many cursor queries reached the real terminal.
    #[cfg(test)]
    real_queries: usize,
}

impl<W: io::Write> InlineBackend<W> {
    /// A full-screen backend: live size, and it answers the cursor query by
    /// asking the terminal (`ESC[6n`). Ratatui never asks on a full-screen
    /// viewport, so in practice it never does.
    pub fn new(writer: W) -> Self {
        Self {
            inner: CrosstermBackend::new(writer),
            primed: None,
            latched: None,
            #[cfg(test)]
            real_queries: 0,
        }
    }

    /// An inline backend for a terminal of `size` whose cursor position is
    /// NOT known: the one query ratatui makes while constructing the viewport
    /// goes to the terminal. Its size is fixed like every inline backend's, so
    /// that construction query is the only one it will ever issue.
    pub fn inline(writer: W, size: Size) -> Self {
        Self {
            latched: Some(size),
            ..Self::new(writer)
        }
    }

    /// An inline backend for a terminal of `size` whose first cursor query is
    /// answered with row `top`, column 0, without any terminal round trip — and
    /// whose size is fixed, so there is no second query either.
    ///
    /// The caller must have actually placed the cursor there (every inline
    /// rebuild path does, with an explicit `MoveTo`). Lying here would misplace
    /// the viewport exactly as a wrong DSR reply would.
    pub fn primed_at(writer: W, top: u16, size: Size) -> Self {
        Self {
            primed: Some(Position { x: 0, y: top }),
            ..Self::inline(writer, size)
        }
    }

    /// The answer still pending, if any. Test seam: it is the difference between
    /// a construction that will round-trip and one that will not.
    #[cfg(test)]
    pub(crate) fn primed(&self) -> Option<Position> {
        self.primed
    }
}

impl<W: io::Write> io::Write for InlineBackend<W> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.inner.write(buf)
    }
    fn flush(&mut self) -> io::Result<()> {
        io::Write::flush(&mut self.inner)
    }
}

impl<W: io::Write> Backend for InlineBackend<W> {
    fn draw<'a, I>(&mut self, content: I) -> io::Result<()>
    where
        I: Iterator<Item = (u16, u16, &'a Cell)>,
    {
        self.inner.draw(content)
    }

    fn hide_cursor(&mut self) -> io::Result<()> {
        self.inner.hide_cursor()
    }

    fn show_cursor(&mut self) -> io::Result<()> {
        self.inner.show_cursor()
    }

    /// **The whole point of this type.** One primed answer, then the truth.
    fn get_cursor_position(&mut self) -> io::Result<Position> {
        match self.primed.take() {
            Some(pos) => Ok(pos),
            None => {
                #[cfg(test)]
                {
                    self.real_queries += 1;
                }
                self.inner.get_cursor_position()
            }
        }
    }

    fn set_cursor_position<P: Into<Position>>(&mut self, position: P) -> io::Result<()> {
        self.inner.set_cursor_position(position)
    }

    fn clear(&mut self) -> io::Result<()> {
        self.inner.clear()
    }

    fn clear_region(&mut self, clear_type: ClearType) -> io::Result<()> {
        self.inner.clear_region(clear_type)
    }

    fn append_lines(&mut self, n: u16) -> io::Result<()> {
        self.inner.append_lines(n)
    }

    /// Live for full screen; fixed for inline — see the module docs. The
    /// fixed size is what keeps `Terminal::draw`'s `autoresize` from
    /// re-anchoring an inline viewport through an unprimed, possibly-fatal DSR
    /// query.
    fn size(&self) -> io::Result<Size> {
        match self.latched {
            Some(size) => Ok(size),
            None => self.inner.size(),
        }
    }

    fn window_size(&mut self) -> io::Result<WindowSize> {
        self.inner.window_size()
    }

    fn flush(&mut self) -> io::Result<()> {
        Backend::flush(&mut self.inner)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SIZE: Size = Size {
        width: 80,
        height: 24,
    };

    /// A primed backend answers from the number it was given — no round trip.
    ///
    /// This is the assertion the whole fix rests on, and it is checkable here
    /// because a `Vec<u8>` sink is not a terminal: `CrosstermBackend`'s own
    /// `get_cursor_position` would go to the real stdin and fail (or block).
    #[test]
    fn a_primed_backend_answers_without_asking_the_terminal() {
        let mut backend = InlineBackend::primed_at(Vec::new(), 17, SIZE);
        assert_eq!(
            backend.get_cursor_position().unwrap(),
            Position { x: 0, y: 17 },
            "the primed row must be handed back verbatim; ratatui anchors \
             Viewport::Inline on exactly this number"
        );
    }

    /// One-shot. Ratatui asks once per construction; anything asking later (a
    /// stray `autoresize`) must get the terminal's real answer rather than a row
    /// that was true several frames ago.
    #[test]
    fn the_primed_answer_is_consumed_by_the_first_asker() {
        let mut backend = InlineBackend::primed_at(Vec::new(), 4, SIZE);
        assert!(backend.primed().is_some());
        let _ = backend.get_cursor_position().unwrap();
        assert_eq!(
            backend.primed(),
            None,
            "a second query must fall through to the real terminal"
        );
    }

    /// The unprimed constructor keeps the old behaviour verbatim: it has no
    /// answer, so it will query. Boot and the alt-screen return path rely on it.
    #[test]
    fn an_unprimed_backend_has_nothing_to_hand_back() {
        let backend = InlineBackend::new(Vec::new());
        assert_eq!(backend.primed(), None);
    }

    /// **The resize crash.** A draw after the terminal changed size must not
    /// query the cursor. Ratatui's `draw` starts with `autoresize`, which for an
    /// inline viewport re-anchors through an unprimed `ESC[6n` whenever
    /// `Backend::size()` differs from the size the viewport was built at; a
    /// reply that missed crossterm's 2 s window killed the TUI mid-resize.
    ///
    /// The latched size makes that mismatch impossible, so `autoresize` is a
    /// no-op and the only query (construction) was the primed one. The real
    /// resize is OSA's to handle, on the next loop iteration.
    #[test]
    fn a_draw_on_an_inline_viewport_never_queries_the_cursor() {
        use ratatui::{Terminal, TerminalOptions, Viewport};

        let backend = InlineBackend::primed_at(Vec::new(), 10, SIZE);
        let mut terminal = Terminal::with_options(
            backend,
            TerminalOptions {
                viewport: Viewport::Inline(6),
            },
        )
        .expect("a primed, latched construction does no terminal I/O that can fail");
        assert_eq!(terminal.get_frame().area().top(), 10);

        for _ in 0..3 {
            terminal
                .draw(|_| {})
                .expect("a draw must never fail on a cursor query");
        }
        assert_eq!(
            terminal.backend().real_queries,
            0,
            "no draw may reach the terminal with a DSR query"
        );
        assert_eq!(
            terminal.backend().size().unwrap(),
            SIZE,
            "an inline backend's size is the frame size it was built for"
        );
    }

    /// Full-screen backends are not latched: their `autoresize` is how a
    /// dialog reflows, and it never queries the cursor.
    #[test]
    fn only_inline_backends_fix_their_size() {
        assert_eq!(InlineBackend::new(Vec::new()).latched, None);
        assert_eq!(InlineBackend::inline(Vec::new(), SIZE).latched, Some(SIZE));
        assert_eq!(
            InlineBackend::primed_at(Vec::new(), 0, SIZE).latched,
            Some(SIZE)
        );
    }

    /// Writes pass through untouched — this is a `CrosstermBackend` in every
    /// respect except the one query. (`CrosstermBackend::writer()` is private in
    /// ratatui 0.29, hence the shared sink.)
    #[test]
    fn writes_reach_the_inner_writer() {
        use std::cell::RefCell;
        use std::io::Write as _;
        use std::rc::Rc;

        struct Shared(Rc<RefCell<Vec<u8>>>);
        impl io::Write for Shared {
            fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
                self.0.borrow_mut().extend_from_slice(buf);
                Ok(buf.len())
            }
            fn flush(&mut self) -> io::Result<()> {
                Ok(())
            }
        }

        let sink = Rc::new(RefCell::new(Vec::new()));
        let mut backend = InlineBackend::new(Shared(Rc::clone(&sink)));
        backend.write_all(b"hello").unwrap();
        io::Write::flush(&mut backend).unwrap();
        assert_eq!(&*sink.borrow(), b"hello");
    }
}
