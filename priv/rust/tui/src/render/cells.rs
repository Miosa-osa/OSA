//! Escape-aware, direct-to-buffer line rendering.
//!
//! # Why this exists
//!
//! OSA emits OSC 8 hyperlinks by embedding the raw escape inside a `Span`'s
//! content (`components::osc8::hyperlink_span`). ratatui measures a span by
//! `symbol.width()` over its grapheme clusters (`widgets/reflow.rs`), and
//! `unicode-width` reports width **1** for ESC — it reports 1 for every
//! `c <= '\u{A0}'`. So an OSC 8 header costs ratatui about 80 phantom columns
//! on a `file://` link.
//!
//! For `Paragraph` without `.wrap()`, ratatui uses `LineTruncator`, which stops
//! emitting the moment `current_line_width + symbol.width() > max_line_width`.
//! On a line carrying a hyperlink that threshold is crossed inside the escape,
//! so the row's visible tail is cut off. Tool headers and markdown links lose
//! their ends, and because finalized content goes to the terminal's own
//! scrollback via `insert_before`, the truncation can never be repainted.
//!
//! # Why the escape cannot simply be carried out of band
//!
//! ratatui 0.29's `Cell` has no hyperlink field, so out-of-band carriage needs a
//! side channel keyed by final cell position — which only exists after layout.
//! The obvious trick, smuggling a zero-width sentinel through the span and
//! patching the buffer afterwards, does not work either: `Paragraph::render_text`
//! (`widgets/paragraph.rs`, the `let width = symbol.width(); if width == 0 {
//! continue; }` guard) **drops** every zero-width grapheme before it reaches the
//! buffer.
//!
//! So the escape has to stay in the span content, and the fix is to stop letting
//! ratatui do the measuring. [`render_lines`] lays the line out itself with true
//! visible widths, and hands each escape to the terminal by prefixing it onto the
//! symbol of the cell that follows it — a cell whose width was already decided by
//! its glyph. Width math never sees the escape bytes.

use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::text::Line;
use unicode_segmentation::UnicodeSegmentation;

/// One laid-out piece of a line: the escape bytes that must be emitted before
/// it, the visible grapheme, and the columns it occupies.
struct Piece<'a> {
    prefix: String,
    grapheme: &'a str,
    width: usize,
}

/// Split a span's content into escape-prefixed visible graphemes.
///
/// Consecutive escapes accumulate onto the next visible grapheme's prefix.
/// Anything left over at the end (a trailing link terminator, say) is returned
/// separately so the caller can flush it onto the last cell it wrote.
fn pieces(content: &str) -> (Vec<Piece<'_>>, String) {
    let mut out: Vec<Piece<'_>> = Vec::new();
    let mut pending = String::new();
    let mut i = 0usize;
    while i < content.len() {
        if let Some(len) = crate::util::escape_len_at(content, i) {
            pending.push_str(&content[i..i + len]);
            i += len;
            continue;
        }
        // Next grapheme cluster, so a base+combining pair or an emoji ZWJ
        // sequence stays in one cell.
        let rest = &content[i..];
        let g = rest.graphemes(true).next().unwrap_or("");
        if g.is_empty() {
            break;
        }
        out.push(Piece {
            prefix: std::mem::take(&mut pending),
            grapheme: g,
            width: unicode_width::UnicodeWidthStr::width(g),
        });
        i += g.len();
    }
    (out, pending)
}

/// True visible width of a [`Line`], ignoring escape bytes.
pub fn line_width(line: &Line<'_>) -> usize {
    line.spans.iter().map(|s| crate::util::cols(&s.content)).sum()
}

/// Render `lines` into `area` of `buf`, one line per row, truncating at the
/// region's real width and NOT wrapping — the escape-aware replacement for
/// `Paragraph::new(lines).render(area, buf)` on content that may carry OSC 8
/// hyperlinks.
///
/// `scroll_y` skips that many leading lines, matching `Paragraph::scroll`.
pub fn render_lines(lines: &[Line<'_>], area: Rect, buf: &mut Buffer, scroll_y: u16) {
    if area.width == 0 || area.height == 0 {
        return;
    }
    let max_w = area.width as usize;
    for (row, line) in lines.iter().skip(scroll_y as usize).enumerate() {
        if row >= area.height as usize {
            break;
        }
        let y = area.top() + row as u16;
        let mut x = 0usize;
        // Column of the last cell we wrote, so trailing escapes have a home.
        let mut last_x: Option<usize> = None;
        let mut carry = String::new();

        for span in &line.spans {
            let (parts, trailing) = pieces(&span.content);
            for p in parts {
                if p.width == 0 {
                    // Zero-width visible content still has to carry its escapes
                    // forward; it owns no cell of its own.
                    carry.push_str(&p.prefix);
                    continue;
                }
                if x + p.width > max_w {
                    // Real truncation, at the real width.
                    carry.clear();
                    break;
                }
                let mut symbol = String::with_capacity(
                    carry.len() + p.prefix.len() + p.grapheme.len(),
                );
                symbol.push_str(&carry);
                carry.clear();
                symbol.push_str(&p.prefix);
                symbol.push_str(p.grapheme);
                let cell = &mut buf[(area.left() + x as u16, y)];
                cell.set_symbol(&symbol);
                cell.set_style(span.style);
                // A wide glyph owns the cell to its right; blank it so a stale
                // symbol underneath does not show through.
                for dx in 1..p.width {
                    if x + dx < max_w {
                        buf[(area.left() + (x + dx) as u16, y)].set_symbol("");
                    }
                }
                last_x = Some(x);
                x += p.width;
            }
            carry.push_str(&trailing);
        }

        // Flush a trailing escape (a link terminator at end of line) onto the
        // last cell written, so the link closes.
        if !carry.is_empty() {
            if let Some(lx) = last_x {
                let cell = &mut buf[(area.left() + lx as u16, y)];
                let joined = format!("{}{}", cell.symbol(), carry);
                cell.set_symbol(&joined);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::style::Style;
    use ratatui::text::Span;
    use ratatui::widgets::{Paragraph, Widget};

    fn osc8(text: &str, url: &str) -> String {
        format!("\x1b]8;;{url}\x1b\\{text}\x1b]8;;\x1b\\")
    }

    /// Collect the VISIBLE text of a buffer row — the cell symbols with escape
    /// sequences stripped, which is what the user actually sees.
    fn visible_row(buf: &Buffer, y: u16) -> String {
        let mut out = String::new();
        for x in 0..buf.area.width {
            let sym = buf[(x, y)].symbol();
            let mut i = 0usize;
            while i < sym.len() {
                if let Some(len) = crate::util::escape_len_at(sym, i) {
                    i += len;
                    continue;
                }
                let c = sym[i..].chars().next().unwrap();
                out.push(c);
                i += c.len_utf8();
            }
        }
        out.trim_end().to_string()
    }

    fn raw_row(buf: &Buffer, y: u16) -> String {
        (0..buf.area.width)
            .map(|x| buf[(x, y)].symbol().to_string())
            .collect()
    }

    /// THE BUG, against ratatui itself: with the hyperlink escape inside the
    /// span, `Paragraph` (LineTruncator) counts every ESC byte as a column and
    /// cuts the row inside/just after the escape, destroying the visible text.
    #[test]
    fn paragraph_truncates_a_hyperlink_row_at_the_fake_width() {
        let link = osc8("a.rs", "file:///home/x/a.rs");
        let line = Line::from(vec![
            Span::raw("Read "),
            Span::raw(link),
            Span::raw(" 120 lines"),
        ]);
        // Visible content is "Read a.rs 120 lines" = 19 columns; give it 40.
        let mut buf = Buffer::empty(Rect::new(0, 0, 40, 1));
        Paragraph::new(vec![line]).render(Rect::new(0, 0, 40, 1), &mut buf);
        let seen = visible_row(&buf, 0);
        assert_ne!(
            seen, "Read a.rs 120 lines",
            "if ratatui ever stops counting ESC as width 1 this guard is obsolete"
        );
        assert!(
            !seen.ends_with("120 lines"),
            "expected the tail to be lost, got {seen:?}"
        );
    }

    /// The fix: the same line through `render_lines` keeps every visible column
    /// and still emits the escape bytes for the terminal.
    #[test]
    fn render_lines_keeps_the_whole_row_and_still_emits_the_link() {
        let link = osc8("a.rs", "file:///home/x/a.rs");
        let line = Line::from(vec![
            Span::raw("Read "),
            Span::raw(link),
            Span::raw(" 120 lines"),
        ]);
        let mut buf = Buffer::empty(Rect::new(0, 0, 40, 1));
        render_lines(&[line], Rect::new(0, 0, 40, 1), &mut buf, 0);
        assert_eq!(visible_row(&buf, 0), "Read a.rs 120 lines");
        // The escape really did reach the buffer, opener and terminator both.
        let raw = raw_row(&buf, 0);
        assert!(raw.contains("\x1b]8;;file:///home/x/a.rs\x1b\\"), "opener missing");
        assert!(raw.contains("\x1b]8;;\x1b\\"), "terminator missing");
        // The opener rides on the cell holding the link's first glyph.
        assert!(buf[(5, 0)].symbol().starts_with("\x1b]8;;file:///home/x/a.rs\x1b\\"));
        assert!(buf[(5, 0)].symbol().ends_with('a'));
    }

    /// Truncation still happens — at the REAL width, not the phantom one.
    #[test]
    fn truncation_uses_visible_width() {
        let link = osc8("hyperlinked", "https://example.com/very/long/path");
        let line = Line::from(vec![Span::raw("ab"), Span::raw(link)]);
        let mut buf = Buffer::empty(Rect::new(0, 0, 8, 1));
        render_lines(&[line], Rect::new(0, 0, 8, 1), &mut buf, 0);
        // 2 + 6 columns of "hyperl" fills exactly 8.
        assert_eq!(visible_row(&buf, 0), "abhyperl");
    }

    /// A link that ends the line still gets its terminator emitted.
    #[test]
    fn trailing_terminator_is_flushed_onto_the_last_cell() {
        let line = Line::from(Span::raw(osc8("x", "https://e.co")));
        let mut buf = Buffer::empty(Rect::new(0, 0, 10, 1));
        render_lines(&[line], Rect::new(0, 0, 10, 1), &mut buf, 0);
        assert_eq!(visible_row(&buf, 0), "x");
        assert!(buf[(0, 0)].symbol().ends_with("\x1b]8;;\x1b\\"));
    }

    /// Wide glyphs advance two columns and blank their continuation cell.
    #[test]
    fn wide_glyphs_take_two_columns() {
        let line = Line::from(Span::raw("日本a"));
        let mut buf = Buffer::empty(Rect::new(0, 0, 10, 1));
        render_lines(&[line], Rect::new(0, 0, 10, 1), &mut buf, 0);
        assert_eq!(buf[(0, 0)].symbol(), "日");
        assert_eq!(buf[(1, 0)].symbol(), "");
        assert_eq!(buf[(2, 0)].symbol(), "本");
        assert_eq!(buf[(4, 0)].symbol(), "a");
    }

    /// Escape-free content renders exactly like `Paragraph` did, so this is a
    /// drop-in for the non-hyperlink majority.
    #[test]
    fn plain_lines_match_paragraph() {
        let lines = vec![
            Line::from(Span::styled("hello world", Style::default())),
            Line::from(Span::raw("second")),
        ];
        let area = Rect::new(0, 0, 20, 2);
        let mut a = Buffer::empty(area);
        Paragraph::new(lines.clone()).render(area, &mut a);
        let mut b = Buffer::empty(area);
        render_lines(&lines, area, &mut b, 0);
        assert_eq!(visible_row(&a, 0), visible_row(&b, 0));
        assert_eq!(visible_row(&a, 1), visible_row(&b, 1));
    }

    #[test]
    fn line_width_ignores_escapes() {
        let link = osc8("a.rs", "file:///home/x/a.rs");
        let line = Line::from(vec![Span::raw("Read "), Span::raw(link)]);
        assert_eq!(line_width(&line), 9);
    }
}
