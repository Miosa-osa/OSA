//! A **real terminal emulator** for tests (ported from Codex's `tui/src/test_backend.rs`).
//!
//! `ratatui::backend::TestBackend` hands back the `Buffer` ratatui *intended* to
//! paint. That is one level too high to catch a whole class of bugs: the escape
//! sequences ratatui actually emits are never executed, so cursor moves, clears,
//! wide-glyph advances and colour resets are all assumed correct. [`VT100Backend`]
//! instead pipes ratatui's real ANSI output through a `vt100` parser, so the
//! assertion runs against the screen a terminal would genuinely show:
//!
//! ```ignore
//! let mut term = Terminal::new(VT100Backend::new(80, 10)).unwrap();
//! term.draw(|f| widget.draw(f, f.area())).unwrap();
//! assert!(term.backend().contents().contains("Working"));
//! ```
//!
//! Importantly this wrapper avoids every crossterm method that writes to (or
//! reads from) the process's real stdout regardless of the writer it was handed —
//! specifically getting the terminal size and getting the cursor position — by
//! answering both from the emulated screen.
//!
//! ## Porting notes (Codex is on ratatui 0.30, OSA on 0.29)
//!
//! * 0.29's `Backend` returns `io::Result<_>` instead of an associated
//!   `type Error`.
//! * `scroll_region_up` / `scroll_region_down` only exist behind 0.29's
//!   `scrolling-regions` feature, which OSA does not enable, so they are not
//!   overridden here.
//! * `CrosstermBackend::writer()` / `writer_mut()` are private in 0.29 (they are
//!   gated behind `unstable-backend-writer`). Rather than change a *runtime*
//!   dependency's feature set for a test-only concern, the parser is held in an
//!   `Rc<RefCell<_>>` shared with the backend, and [`VT100Backend::vt100`] hands
//!   out a `Ref` to it.

#![allow(dead_code)]

use std::cell::{Ref, RefCell};
use std::fmt;
use std::io::{self, Write};
use std::rc::Rc;

use ratatui::backend::{Backend, ClearType, WindowSize};
use ratatui::buffer::Cell;
use ratatui::layout::{Position, Size};
use ratatui::prelude::CrosstermBackend;

/// A `Write` handle onto a shared `vt100::Parser`, so the backend can own a
/// writer while the test still gets to inspect the emulated screen.
struct SharedParser(Rc<RefCell<vt100::Parser>>);

impl Write for SharedParser {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.0.borrow_mut().write(buf)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.0.borrow_mut().flush()
    }
}

/// Wraps a `CrosstermBackend` writing into a `vt100::Parser`, mocking a "real"
/// terminal end to end (ratatui → ANSI → terminal emulator → screen).
pub struct VT100Backend {
    crossterm_backend: CrosstermBackend<SharedParser>,
    parser: Rc<RefCell<vt100::Parser>>,
}

impl VT100Backend {
    /// Create a backend whose emulated screen is `width` x `height` cells.
    pub fn new(width: u16, height: u16) -> Self {
        // Colour is normally suppressed when stdout is not a tty (which it is not
        // under `cargo test`); force it so style regressions are observable.
        crossterm::style::force_color_output(true);
        let parser = Rc::new(RefCell::new(vt100::Parser::new(height, width, 0)));
        Self {
            crossterm_backend: CrosstermBackend::new(SharedParser(Rc::clone(&parser))),
            parser,
        }
    }

    /// The terminal emulator behind this backend. Bind the returned `Ref` to a
    /// local before reaching into `.screen()`:
    ///
    /// ```ignore
    /// let parser = term.backend().vt100();
    /// let screen = parser.screen();
    /// ```
    pub fn vt100(&self) -> Ref<'_, vt100::Parser> {
        self.parser.borrow()
    }

    /// The emulated screen as plain text, one row per line, trailing blanks
    /// stripped by `vt100` itself.
    pub fn contents(&self) -> String {
        self.parser.borrow().screen().contents()
    }

    /// The text of a single emulated cell — `""` for the continuation column of a
    /// wide glyph, which is precisely the detail a `Buffer` snapshot hides.
    pub fn cell_contents(&self, row: u16, col: u16) -> String {
        self.parser
            .borrow()
            .screen()
            .cell(row, col)
            .map(|c| c.contents())
            .unwrap_or_default()
    }
}

impl Write for VT100Backend {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.parser.borrow_mut().write(buf)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.parser.borrow_mut().flush()
    }
}

impl fmt::Display for VT100Backend {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.contents())
    }
}

impl Backend for VT100Backend {
    fn draw<'a, I>(&mut self, content: I) -> io::Result<()>
    where
        I: Iterator<Item = (u16, u16, &'a Cell)>,
    {
        self.crossterm_backend.draw(content)
    }

    fn hide_cursor(&mut self) -> io::Result<()> {
        self.crossterm_backend.hide_cursor()
    }

    fn show_cursor(&mut self) -> io::Result<()> {
        self.crossterm_backend.show_cursor()
    }

    /// Answered from the emulated screen — crossterm's implementation queries the
    /// process's real stdout with a DSR round-trip, which hangs (or lies) in tests.
    ///
    /// `vt100` reports `(row, col)`; `Position` is `(x, y)` — i.e. `(col, row)`.
    fn get_cursor_position(&mut self) -> io::Result<Position> {
        let (row, col) = self.parser.borrow().screen().cursor_position();
        Ok(Position::new(col, row))
    }

    fn set_cursor_position<P: Into<Position>>(&mut self, position: P) -> io::Result<()> {
        self.crossterm_backend.set_cursor_position(position)
    }

    fn clear(&mut self) -> io::Result<()> {
        self.crossterm_backend.clear()
    }

    fn clear_region(&mut self, clear_type: ClearType) -> io::Result<()> {
        self.crossterm_backend.clear_region(clear_type)
    }

    fn append_lines(&mut self, line_count: u16) -> io::Result<()> {
        self.crossterm_backend.append_lines(line_count)
    }

    /// Answered from the emulated screen for the same reason as
    /// [`Self::get_cursor_position`]. `vt100` reports `(rows, cols)`.
    fn size(&self) -> io::Result<Size> {
        let (rows, cols) = self.parser.borrow().screen().size();
        Ok(Size::new(cols, rows))
    }

    fn window_size(&mut self) -> io::Result<WindowSize> {
        let (rows, cols) = self.parser.borrow().screen().size();
        Ok(WindowSize {
            columns_rows: Size::new(cols, rows),
            // Arbitrary: nothing in the TUI relies on pixel geometry.
            pixels: Size {
                width: 640,
                height: 480,
            },
        })
    }

    fn flush(&mut self) -> io::Result<()> {
        self.parser.borrow_mut().flush()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::widgets::Paragraph;
    use ratatui::Terminal;

    #[test]
    fn vt100_backend_reports_its_emulated_size_not_the_real_terminal() {
        let backend = VT100Backend::new(37, 9);
        assert_eq!(backend.size().unwrap(), Size::new(37, 9));
    }

    #[test]
    fn text_survives_the_full_ansi_round_trip() {
        let mut term = Terminal::new(VT100Backend::new(20, 3)).unwrap();
        term.draw(|f| {
            f.render_widget(Paragraph::new("hello vt100"), f.area());
        })
        .unwrap();
        assert!(
            term.backend().contents().contains("hello vt100"),
            "screen was {:?}",
            term.backend().contents()
        );
    }

    /// Wide glyphs must occupy two emulated cells, exactly as on a real terminal
    /// — this is what a `Buffer` snapshot cannot verify.
    #[test]
    fn wide_glyphs_consume_two_terminal_columns() {
        let mut term = Terminal::new(VT100Backend::new(10, 1)).unwrap();
        term.draw(|f| {
            f.render_widget(Paragraph::new("\u{6a21}\u{578b}ab"), f.area());
        })
        .unwrap();
        let b = term.backend();
        // 模 at col 0 (col 1 is its continuation), 型 at col 2, then "ab".
        assert_eq!(b.cell_contents(0, 0), "\u{6a21}");
        assert_eq!(b.cell_contents(0, 2), "\u{578b}");
        assert_eq!(b.cell_contents(0, 4), "a");
        assert_eq!(b.cell_contents(0, 5), "b");
    }

    /// The emulator never lets a row exceed the terminal width, so a row's
    /// display width is a trustworthy overflow oracle.
    #[test]
    fn emulated_rows_never_exceed_the_terminal_width() {
        let mut term = Terminal::new(VT100Backend::new(6, 2)).unwrap();
        term.draw(|f| {
            f.render_widget(Paragraph::new("\u{6a21}\u{578b}\u{6a21}\u{578b}\u{6a21}"), f.area());
        })
        .unwrap();
        for line in term.backend().contents().lines() {
            assert!(crate::util::cols(line) <= 6, "row {line:?} overflows");
        }
    }
}
