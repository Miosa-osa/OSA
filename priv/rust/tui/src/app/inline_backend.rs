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
//! Boot ([`crate::main`]) and the alternate-screen return path with no
//! remembered top have no such number: the cursor is wherever the shell or the
//! dialog left it. Those construct with [`InlineBackend::new`], which queries
//! for real, exactly as before.

use ratatui::backend::{Backend, ClearType, CrosstermBackend, WindowSize};
use ratatui::buffer::Cell;
use ratatui::layout::{Position, Size};
use std::io;

/// `CrosstermBackend` with an optional, one-shot answer for the cursor query.
pub struct InlineBackend<W: io::Write> {
    inner: CrosstermBackend<W>,
    /// Where the cursor is *known* to be, if the caller put it there. Taken by
    /// the first [`Backend::get_cursor_position`]; `None` afterwards, so a
    /// second asker gets the real terminal rather than a stale row.
    primed: Option<Position>,
}

impl<W: io::Write> InlineBackend<W> {
    /// A backend that answers the cursor query by asking the terminal (`ESC[6n`).
    pub fn new(writer: W) -> Self {
        Self {
            inner: CrosstermBackend::new(writer),
            primed: None,
        }
    }

    /// A backend whose first cursor query is answered with row `top`, column 0,
    /// without any terminal round trip.
    ///
    /// The caller must have actually placed the cursor there (every inline
    /// rebuild path does, with an explicit `MoveTo`). Lying here would misplace
    /// the viewport exactly as a wrong DSR reply would.
    pub fn primed_at(writer: W, top: u16) -> Self {
        Self {
            inner: CrosstermBackend::new(writer),
            primed: Some(Position { x: 0, y: top }),
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
            None => self.inner.get_cursor_position(),
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

    fn size(&self) -> io::Result<Size> {
        self.inner.size()
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

    /// A primed backend answers from the number it was given — no round trip.
    ///
    /// This is the assertion the whole fix rests on, and it is checkable here
    /// because a `Vec<u8>` sink is not a terminal: `CrosstermBackend`'s own
    /// `get_cursor_position` would go to the real stdin and fail (or block).
    #[test]
    fn a_primed_backend_answers_without_asking_the_terminal() {
        let mut backend = InlineBackend::primed_at(Vec::new(), 17);
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
        let mut backend = InlineBackend::primed_at(Vec::new(), 4);
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
