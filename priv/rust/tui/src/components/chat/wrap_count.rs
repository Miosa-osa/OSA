//! **Count the rows `Wrap { trim: false }` will actually produce.**
//!
//! A finalized message is handed to the terminal through `insert_before` at
//! exactly the row count `Message::height` returned, so that number is not a
//! hint — it is the size of the hole the content must fit in. Anything past it
//! is clipped by the rect and is gone from scrollback permanently.
//!
//! `height` used to estimate the plain-message body with ceiling division on the
//! raw line width (`(len + w - 1) / w`). That is the row count of a wrapper that
//! breaks mid-word, and ratatui does not have one on this path: `Wrap { trim:
//! false }` runs [`WordWrapper`], which keeps words whole and therefore needs
//! *at least* as many rows and routinely more. Three 20-column words at width 39
//! is the smallest case — ceiling division says 2, the word wrapper needs 3, and
//! the third word is deleted.
//!
//! [`wrapped_row_count`] is a line-for-line port of `WordWrapper::process_input`
//! (ratatui 0.29 `src/widgets/reflow.rs`) reduced to its row count, specialised
//! to `trim: false` — the only mode any caller here renders with. It is not an
//! approximation and not an upper bound: the sweep in
//! `layout_invariants::reservation_invariants` renders real messages and asserts
//! this count equals the rows the paint actually occupies, so a divergence
//! introduced by a ratatui upgrade fails the suite rather than silently eating
//! text again.
//!
//! [`WordWrapper`]: https://docs.rs/ratatui/0.29/src/ratatui/widgets/reflow.rs.html

use std::collections::VecDeque;

use unicode_segmentation::UnicodeSegmentation;
use unicode_width::UnicodeWidthStr;

/// Non-breaking space — ratatui deliberately does NOT treat this as whitespace,
/// so a word joined by one is never split at it.
const NBSP: &str = "\u{00a0}";
/// Zero-width space — treated as whitespace (a break opportunity) despite
/// having width 0.
const ZWSP: &str = "\u{200b}";

/// `StyledGrapheme::is_whitespace`, verbatim.
fn is_whitespace(symbol: &str) -> bool {
    symbol == ZWSP || symbol.chars().all(char::is_whitespace) && symbol != NBSP
}

/// Rows one input line occupies once word-wrapped to `max_width`.
///
/// Mirrors `WordWrapper::process_input` with `trim = false`. Never returns 0:
/// ratatui emits an empty row for an empty input line, which is what keeps a
/// blank paragraph spacer visible.
fn rows_for_line(line: &str, max_width: u16) -> u16 {
    if max_width == 0 {
        return 0;
    }

    // `wrapped_lines.len()` — the only thing this port needs out of the deque.
    let mut wrapped: u16 = 0;

    let mut line_width: u16 = 0;
    let mut word_width: u16 = 0;
    let mut whitespace_width: u16 = 0;
    let mut non_whitespace_previous = false;

    // `pending_line` / `pending_word` are only ever consulted for emptiness and
    // width, so a count stands in for the grapheme vector. `pending_whitespace`
    // is drained from the front by width, so it keeps its per-grapheme widths.
    let mut pending_line_count: usize = 0;
    let mut pending_word_count: usize = 0;
    let mut pending_whitespace: VecDeque<u16> = VecDeque::new();

    for symbol in line.graphemes(true) {
        let is_ws = is_whitespace(symbol);
        let symbol_width = symbol.width() as u16;

        // ignore symbols wider than line limit
        if symbol_width > max_width {
            continue;
        }

        let word_found = non_whitespace_previous && is_ws;
        // current full word (including whitespace) would overflow. The `trim`
        // variants of this test are dead with `trim: false`.
        let untrimmed_overflow =
            pending_line_count == 0 && word_width + whitespace_width + symbol_width > max_width;

        // append finished segment to current line
        if word_found || untrimmed_overflow {
            // `!self.trim` is always true here, so this branch is unconditional.
            pending_line_count += pending_whitespace.len();
            line_width += whitespace_width;

            pending_line_count += pending_word_count;
            pending_word_count = 0;
            line_width += word_width;

            pending_whitespace.clear();
            whitespace_width = 0;
            word_width = 0;
        }

        // pending line fills up limit
        let line_full = line_width >= max_width;
        // pending word would overflow line limit
        let pending_word_overflow =
            symbol_width > 0 && line_width + whitespace_width + word_width >= max_width;

        if line_full || pending_word_overflow {
            let mut remaining_width = max_width.saturating_sub(line_width);

            wrapped += 1;
            pending_line_count = 0;
            line_width = 0;

            // remove whitespace up to the end of line
            while let Some(&width) = pending_whitespace.front() {
                if width > remaining_width {
                    break;
                }
                whitespace_width -= width;
                remaining_width -= width;
                pending_whitespace.pop_front();
            }

            // don't count first whitespace toward next word
            if is_ws && pending_whitespace.is_empty() {
                continue;
            }
        }

        if is_ws {
            whitespace_width += symbol_width;
            pending_whitespace.push_back(symbol_width);
        } else {
            word_width += symbol_width;
            pending_word_count += 1;
        }

        non_whitespace_previous = !is_ws;
    }

    // append remaining text parts
    if pending_line_count == 0 && pending_word_count == 0 && !pending_whitespace.is_empty() {
        wrapped += 1;
    }
    // `!self.trim` again, so the whitespace always lands on the pending line.
    pending_line_count += pending_whitespace.len();
    pending_line_count += pending_word_count;

    if pending_line_count > 0 {
        wrapped += 1;
    }
    if wrapped == 0 {
        wrapped = 1;
    }
    wrapped
}

/// Rows `Paragraph::new(text).wrap(Wrap { trim: false })` occupies at
/// `max_width`, counting every input line.
///
/// Empty input still costs one row, matching `Text::from("")`.
pub fn wrapped_row_count(text: &str, max_width: u16) -> u16 {
    if max_width == 0 {
        return 0;
    }
    let mut total: u16 = 0;
    let mut saw_line = false;
    for line in text.lines() {
        saw_line = true;
        total = total.saturating_add(rows_for_line(line, max_width));
    }
    if !saw_line {
        return 1;
    }
    total.max(1)
}
