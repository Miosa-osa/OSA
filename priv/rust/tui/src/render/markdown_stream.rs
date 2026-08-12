//! Streaming frozen-tail markdown renderer.
//!
//! [`StreamingRenderer`] renders assistant markdown that arrives token-by-token
//! without flicker and without re-parsing the whole growing buffer on every
//! update. Completed depth-0 blocks are *frozen* (rendered once, then cached as
//! [`Line`]s); only the unstable *tail* is re-rendered on each update.
//!
//! # Why this is correct for OSA's renderer
//!
//! OSA's [`render_markdown`](super::markdown::render_markdown) is a line-oriented
//! renderer: every source line is turned into output line(s) independently, and
//! the *only* state that carries across a blank line is the open-fenced-code-block
//! flag (GFM tables are flushed by any non-table line, including a blank one). So
//! for OSA a split point `B` is "safe" — meaning
//! `render(src[..B]) ++ render(src[B..]) == render(src)` byte-for-byte — whenever
//!
//!   1. `B` sits at the start of a line (right after a `\n`), and
//!   2. the line just before `B` is blank (a block separator), and
//!   3. `B` is not inside an open ```` ``` ```` fenced code block.
//!
//! That is exactly the grok "depth-0 checkpoint committed after a confirming
//! blank line" rule, specialized to OSA's line-local renderer: a heading /
//! paragraph / closed-code-block freezes only once its terminating blank line has
//! arrived, and anything still nested inside an open list / blockquote / table /
//! code fence stays in the tail until the block closes with a blank line.
//!
//! # Complexity
//!
//! Each byte is rendered into the frozen prefix at most once, and only the
//! current tail (one in-progress block) is re-rendered per update:
//! O(N²) full-buffer re-parsing collapses to ~O(N) total.
//!
//! # Example
//!
//! ```ignore
//! let mut r = StreamingRenderer::new(width);
//! // `update` takes the FULL cumulative buffer (OSA's streaming buffer is
//! // replace-in-place and monotonically growing):
//! r.update("# Title\n\n");
//! r.update("# Title\n\nSome body ");
//! let text = r.body_with_cursor(); // frozen prefix + live tail + block cursor
//! ```

use ratatui::text::{Line, Text};

use super::markdown::render_markdown;

/// Block cursor appended to the live tail while streaming (matches the legacy
/// `format!("{}\u{2588}", content)` path in the chat widget).
const CURSOR: char = '\u{2588}';

/// Incremental markdown renderer that freezes completed depth-0 blocks and
/// re-renders only the unstable tail on each update.
pub struct StreamingRenderer {
    /// Accumulated source text (no cursor). Monotonically grows within a turn.
    source: String,
    /// Wrap width passed through to [`render_markdown`].
    width: u16,
    /// Byte offset (a line start, on a char boundary) marking the end of the
    /// frozen prefix. `source[..frozen_bytes]` is rendered in `frozen_lines`.
    frozen_bytes: usize,
    /// Rendered, cached output for `source[..frozen_bytes]`. Never re-rendered.
    frozen_lines: Vec<Line<'static>>,
    /// Resumable state for the freeze-boundary scan.
    ///
    /// The scan used to restart at byte 0 on every delta, which made a single
    /// reply O(N²) in its own length: the 200-line-fence bench spent 1.1s and
    /// 352µs per delta, against 109µs for a short one. The source is append-only
    /// within a turn, so bytes already examined can never change their verdict —
    /// the scan resumes from `scan.pos`, carrying the fence state with it.
    scan: ScanState,
}

/// Where the incremental freeze scan got to, and what it knew there.
#[derive(Clone, Copy, Default)]
struct ScanState {
    /// Byte offset of the first line not yet examined (always a line start).
    pos: usize,
    /// Whether `pos` sits inside a ``` fenced code block.
    in_code: bool,
    /// Best freeze boundary found so far.
    boundary: usize,
}

impl StreamingRenderer {
    /// Create a renderer that wraps at `width` columns.
    pub fn new(width: u16) -> Self {
        Self {
            source: String::new(),
            width,
            frozen_bytes: 0,
            frozen_lines: Vec::new(),
            scan: ScanState::default(),
        }
    }

    /// Change the wrap width. A width change invalidates every cached line
    /// (wrapping differs), so the frozen prefix is discarded and rebuilt from the
    /// retained source on the next [`update`](Self::update)/[`advance`].
    pub fn set_width(&mut self, width: u16) {
        if self.width != width {
            self.width = width;
            self.frozen_bytes = 0;
            self.frozen_lines.clear();
            self.reset_scan();
            self.advance();
        }
    }

    /// Feed the current FULL streaming buffer.
    ///
    /// OSA's chat widget replaces its streaming buffer in place each token, so
    /// `full` is the entire reply so far (not a delta). The buffer only grows and
    /// keeps the same prefix; on the rare event that it does not (a reset), the
    /// renderer rebuilds from scratch. Cheap when `full` merely extends the
    /// previous source: only the appended bytes are ever considered for freezing.
    pub fn update(&mut self, full: &str) {
        let keeps_prefix = full.len() >= self.source.len()
            && full.as_bytes()[..self.source.len()] == *self.source.as_bytes();
        if keeps_prefix {
            if full.len() == self.source.len() {
                return; // no new bytes
            }
            self.source.push_str(&full[self.source.len()..]);
        } else {
            // Buffer diverged from our prefix (turn reset / rewind): rebuild.
            self.source.clear();
            self.source.push_str(full);
            self.frozen_bytes = 0;
            self.frozen_lines.clear();
            self.reset_scan();
        }
        self.advance();
    }

    /// Replace the whole buffer, discarding any previous content.
    pub fn reset(&mut self) {
        self.source.clear();
        self.frozen_bytes = 0;
        self.frozen_lines.clear();
        self.reset_scan();
    }

    /// Advance the frozen boundary to the last safe checkpoint and render any
    /// newly-frozen region. Rendering `source[frozen_bytes..new_boundary]` in
    /// isolation is output-identical to that slice of a full render because both
    /// ends are safe split points (see the module docs).
    fn advance(&mut self) {
        let new_boundary = self.scan_forward();
        if new_boundary > self.frozen_bytes {
            let newly = render_markdown(&self.source[self.frozen_bytes..new_boundary], self.width);
            self.frozen_lines.extend(newly.lines);
            self.frozen_bytes = new_boundary;
        }
    }

    /// Resume the freeze-boundary scan from `self.scan.pos`.
    ///
    /// Equivalent to `find_frozen_boundary(&self.source)` but linear in the
    /// bytes appended since the last call rather than in the whole reply. Only
    /// COMPLETE lines are consumed: a trailing partial line is left for the next
    /// delta, since its verdict can still change as more bytes arrive.
    fn scan_forward(&mut self) -> usize {
        let bytes = self.source.as_bytes();
        let mut line_start = self.scan.pos;
        let mut i = self.scan.pos;

        while i < bytes.len() {
            if bytes[i] != b'\n' {
                i += 1;
                continue;
            }

            let line = &self.source[line_start..i];
            let trimmed = line.trim_start();
            if trimmed.starts_with("```") {
                // A fence line toggles the code-block state. Its own line is
                // never a freeze point.
                self.scan.in_code = !self.scan.in_code;
            } else if !self.scan.in_code && line.trim().is_empty() {
                // Blank line at depth 0, outside code: everything up to and
                // including this line's terminating newline is safe to freeze.
                self.scan.boundary = i + 1;
            }

            i += 1;
            line_start = i;
        }

        // Stop at the last complete line. The remainder is re-examined next time.
        self.scan.pos = line_start;
        self.scan.boundary
    }

    /// Reset the incremental scan. Called whenever `frozen_bytes` is rolled back
    /// (width change, buffer divergence) so the two never disagree.
    fn reset_scan(&mut self) {
        self.scan = ScanState::default();
    }

    /// Render the unstable tail (`source[frozen_bytes..]`), optionally with the
    /// streaming block cursor appended. O(tail) — one in-progress block.
    fn render_tail(&self, with_cursor: bool) -> Vec<Line<'static>> {
        let tail = &self.source[self.frozen_bytes..];
        if with_cursor {
            let mut buf = String::with_capacity(tail.len() + CURSOR.len_utf8());
            buf.push_str(tail);
            buf.push(CURSOR);
            render_markdown(&buf, self.width).lines
        } else if tail.is_empty() {
            Vec::new()
        } else {
            render_markdown(tail, self.width).lines
        }
    }

    /// The live view: frozen prefix + re-rendered tail + block cursor.
    ///
    /// Byte-identical to `render_markdown(&format!("{full}\u{2588}"), width)` — the
    /// legacy per-token full-buffer path — but the prefix is never re-parsed.
    pub fn body_with_cursor(&self) -> Text<'static> {
        let mut lines = self.frozen_lines.clone();
        lines.extend(self.render_tail(true));
        Text::from(lines)
    }

    /// The view without the streaming cursor (frozen prefix + tail).
    #[allow(dead_code)] // public API + exercised by unit tests
    pub fn body(&self) -> Text<'static> {
        let mut lines = self.frozen_lines.clone();
        lines.extend(self.render_tail(false));
        Text::from(lines)
    }

    /// Finalize: a full one-shot re-render of the accumulated source.
    ///
    /// Guaranteed byte-identical to the non-streaming path used for finalized
    /// messages, so a message can be handed off from the live region to native
    /// scrollback without any visible reflow.
    #[allow(dead_code)] // public API for the live→finalized hand-off; tested
    pub fn finish(&self) -> Text<'static> {
        render_markdown(&self.source, self.width)
    }

    /// The accumulated source text (no cursor).
    #[allow(dead_code)] // inspection hook; exercised by unit tests
    pub fn source(&self) -> &str {
        &self.source
    }

    /// Number of frozen source bytes (test/inspection hook).
    #[allow(dead_code)] // inspection hook; exercised by unit tests
    pub fn frozen_bytes(&self) -> usize {
        self.frozen_bytes
    }

    /// Number of frozen output lines (test/inspection hook).
    #[allow(dead_code)] // inspection hook; exercised by unit tests
    pub fn frozen_line_count(&self) -> usize {
        self.frozen_lines.len()
    }
}

/// Byte offset just past the last **safe freeze point** in `src`: the start of
/// the line following the most recent blank line that sits at depth 0 outside an
/// open fenced code block. Returns `0` when no such separator exists yet (nothing
/// is safe to freeze).
///
/// A blank line inside an open ```` ``` ```` fence is deliberately ignored, so a
/// still-open code block (and anything nested that hasn't closed with a blank
/// separator) stays in the tail.
pub(crate) fn find_frozen_boundary(src: &str) -> usize {
    let bytes = src.as_bytes();
    let mut in_code = false;
    let mut boundary = 0usize;
    let mut line_start = 0usize;
    let mut i = 0usize;

    loop {
        let at_eof = i == bytes.len();
        if at_eof || bytes[i] == b'\n' {
            let line = &src[line_start..i];
            let trimmed = line.trim_start();
            if trimmed.starts_with("```") {
                // A fence line toggles the code-block state. Its own line is
                // never a freeze point.
                in_code = !in_code;
            } else if !in_code && line.trim().is_empty() {
                // Blank line at depth 0, outside code: everything up to and
                // including this line's terminating newline is safe to freeze.
                // At EOF (no terminating newline) we cannot freeze past it while
                // streaming — the "block" after it hasn't started.
                if !at_eof {
                    boundary = i + 1;
                }
            }
            if at_eof {
                break;
            }
            line_start = i + 1;
        }
        i += 1;
    }

    boundary
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::text::Text;

    const W: u16 = 60;

    /// Flatten a `Text` to plain per-line strings (drops styling, keeps content).
    fn flat(text: &Text<'_>) -> Vec<String> {
        text.lines
            .iter()
            .map(|l| l.spans.iter().map(|s| s.content.as_ref()).collect())
            .collect()
    }

    fn full_with_cursor(src: &str) -> Vec<String> {
        let s = format!("{src}\u{2588}");
        flat(&render_markdown(&s, W))
    }

    fn full_plain(src: &str) -> Vec<String> {
        flat(&render_markdown(src, W))
    }

    // ── find_frozen_boundary ────────────────────────────────────────────────

    #[test]
    fn boundary_none_without_blank_line() {
        assert_eq!(find_frozen_boundary(""), 0);
        assert_eq!(find_frozen_boundary("# Heading"), 0);
        assert_eq!(find_frozen_boundary("# Heading\n"), 0);
        assert_eq!(find_frozen_boundary("one line of prose"), 0);
    }

    #[test]
    fn boundary_after_blank_line() {
        // "# H\n\n" → blank line terminates at byte 4, boundary = 5.
        assert_eq!(find_frozen_boundary("# H\n\n"), 5);
        assert_eq!(&"# H\n\n"[..5], "# H\n\n");
    }

    #[test]
    fn boundary_ignores_blank_inside_open_fence() {
        // Blank line is *inside* an unterminated code fence → not a freeze point.
        assert_eq!(find_frozen_boundary("```\nsome code\n\nmore"), 0);
        // Once the fence closes and a blank follows, we can freeze.
        let s = "```\ncode\n```\n\ntail";
        let b = find_frozen_boundary(s);
        assert!(b > 0 && &s[..b] == "```\ncode\n```\n\n", "got {b}: {:?}", &s[..b]);
    }

    #[test]
    fn boundary_takes_last_separator() {
        let s = "# H\n\nPara one.\n\nPara two, still typing";
        let b = find_frozen_boundary(s);
        assert_eq!(&s[..b], "# H\n\nPara one.\n\n");
    }

    // ── frozen prefix stability across pushes ───────────────────────────────

    #[test]
    fn frozen_prefix_is_stable_across_pushes() {
        let mut r = StreamingRenderer::new(W);
        r.update("# Heading\n\n");
        let frozen_after_heading = r.frozen_line_count();
        let frozen_bytes_1 = r.frozen_bytes();
        assert!(frozen_bytes_1 > 0, "a completed heading must freeze");
        let prefix_1 = flat(&r.body_with_cursor())[..frozen_after_heading].to_vec();

        // Keep streaming a paragraph; the heading's frozen lines must not move.
        r.update("# Heading\n\nThis is the body ");
        assert_eq!(
            r.frozen_bytes(),
            frozen_bytes_1,
            "frozen boundary must not retreat"
        );
        let prefix_2 = flat(&r.body_with_cursor())[..frozen_after_heading].to_vec();
        assert_eq!(prefix_1, prefix_2, "frozen heading lines changed");

        // Complete the paragraph: boundary must only ever advance.
        r.update("# Heading\n\nThis is the body of the reply.\n\n");
        assert!(
            r.frozen_bytes() > frozen_bytes_1,
            "completed paragraph should extend the frozen prefix"
        );
        let prefix_3 = flat(&r.body_with_cursor())[..frozen_after_heading].to_vec();
        assert_eq!(prefix_1, prefix_3, "frozen heading lines changed after 3rd push");
    }

    // ── incomplete list / paragraph is NOT frozen ───────────────────────────

    #[test]
    fn incomplete_paragraph_not_frozen() {
        let mut r = StreamingRenderer::new(W);
        r.update("# Title\n\nA paragraph with no terminating blank line yet");
        // Only the heading (up to its confirming blank line) is frozen.
        assert_eq!(r.frozen_bytes(), "# Title\n\n".len());
        assert!(
            r.source()[r.frozen_bytes()..].contains("no terminating blank"),
            "the in-progress paragraph must stay in the tail"
        );
    }

    #[test]
    fn incomplete_list_not_frozen() {
        let mut r = StreamingRenderer::new(W);
        r.update("- one\n- two\n- three");
        assert_eq!(r.frozen_bytes(), 0, "an open list must not freeze");
        assert_eq!(r.frozen_line_count(), 0);

        // A blank line closes the list → it becomes freezable as a whole.
        r.update("- one\n- two\n- three\n\nnext");
        assert_eq!(r.frozen_bytes(), "- one\n- two\n- three\n\n".len());
    }

    #[test]
    fn open_code_fence_not_frozen() {
        let mut r = StreamingRenderer::new(W);
        r.update("```rust\nfn main() {\n    let x = 1;\n");
        assert_eq!(r.frozen_bytes(), 0, "an open code fence must not freeze");
    }

    // ── final output matches one-shot ───────────────────────────────────────

    #[test]
    fn finish_matches_one_shot() {
        let doc = "# Heading\n\nSome **bold** text.\n\n> A quote\n\n- a\n- b\n\n";
        let mut r = StreamingRenderer::new(W);
        // stream in as several cumulative slices
        for cut in [10usize, 25, 40, doc.len()] {
            r.update(&doc[..cut.min(doc.len())]);
        }
        assert_eq!(flat(&r.finish()), full_plain(doc));
        // frozen-prefix + tail (no cursor) must also equal the one-shot render.
        assert_eq!(flat(&r.body()), full_plain(doc));
    }

    /// The strong invariant: at EVERY prefix length, the incremental view (with
    /// cursor) is byte-identical to a full one-shot render of that same prefix.
    fn assert_stream_matches_full(doc: &str, cuts: &[usize]) {
        let mut r = StreamingRenderer::new(W);
        for &cut in cuts {
            let end = cut.min(doc.len());
            // land on a char boundary
            let end = (0..=end).rev().find(|&i| doc.is_char_boundary(i)).unwrap_or(0);
            r.update(&doc[..end]);
            assert_eq!(
                flat(&r.body_with_cursor()),
                full_with_cursor(&doc[..end]),
                "streaming vs full mismatch at prefix len {end}: {:?}",
                &doc[..end]
            );
        }
    }

    const COMPREHENSIVE: &str = "\
# Main Heading

A paragraph with **bold**, *italic*, and `code`.

## Subsection

- Item one
- Item two with **bold**

1. First
2. Second

> A blockquote line.

```rust
fn main() {
    println!(\"hi\");
}
```

Text after the code block.

| A | B |
|---|---|
| 1 | 2 |

Final paragraph, no trailing newline.";

    #[test]
    fn comprehensive_char_by_char_matches_full() {
        let cuts: Vec<usize> = (0..=COMPREHENSIVE.len()).collect();
        assert_stream_matches_full(COMPREHENSIVE, &cuts);
    }

    #[test]
    fn comprehensive_chunked_matches_full() {
        // irregular chunk boundaries
        let mut cuts = Vec::new();
        let mut p = 0;
        for step in [3usize, 7, 5, 11, 2, 17].iter().cycle() {
            p += *step;
            cuts.push(p);
            if p >= COMPREHENSIVE.len() {
                break;
            }
        }
        assert_stream_matches_full(COMPREHENSIVE, &cuts);
    }

    /// Exercises the newer markdown sub-layers (setext headings, `***bold
    /// italic***`, inline `$…$` LaTeX, nested blockquotes, table-cell inline
    /// markdown, and multi-line soft-break paragraphs) under the char-by-char
    /// streaming invariant: the frozen-prefix + tail view must stay byte-identical
    /// to a full one-shot render at every prefix length.
    const NEW_LAYERS: &str = "\
Intro line one
that soft-wraps into a single paragraph.

Setext Title
============

A line with ***bold italic*** and $x^2$ math.

> outer quote
>> nested quote

| Name | Note |
|---|---|
| **b** | `c` |

Wrap up.";

    #[test]
    fn new_layers_char_by_char_matches_full() {
        let cuts: Vec<usize> = (0..=NEW_LAYERS.len()).collect();
        assert_stream_matches_full(NEW_LAYERS, &cuts);
    }

    #[test]
    fn new_layers_finish_matches_one_shot() {
        let mut r = StreamingRenderer::new(W);
        for cut in [12usize, 40, 70, 110, NEW_LAYERS.len()] {
            r.update(&NEW_LAYERS[..cut.min(NEW_LAYERS.len())]);
        }
        assert_eq!(flat(&r.finish()), full_plain(NEW_LAYERS));
        assert_eq!(flat(&r.body()), full_plain(NEW_LAYERS));
    }

    #[test]
    fn code_block_then_paragraph_matches_full() {
        assert_stream_matches_full(
            "```rust\nfn main() {}\n```\n\nAfter the code.\n\n",
            &[8, 16, 24, 32, 44],
        );
    }

    #[test]
    fn table_then_text_matches_full() {
        assert_stream_matches_full(
            "| Feature | Before | After |\n|---|---|---|\n| Cx | O(N^2) | O(N) |\n\nDone.\n\n",
            &[10, 30, 45, 60, 75],
        );
    }

    /// A FULL-GRID table (outer frame + a rule between every row + wrapped
    /// multi-line cells) streamed one byte at a time. Two things are pinned:
    /// the incremental view is identical to a batch render at every single
    /// prefix, and no prefix ever leaves a half-drawn box — every `┌` that has
    /// been emitted is closed by a `└` in the same render, so a partially
    /// received table never shows a frame it then has to take back.
    #[test]
    fn full_grid_table_streams_byte_by_byte_without_a_half_drawn_border() {
        let doc = "\
Intro line.

| Pattern | Keys |
|---|---|
| BYOK multi-provider | Keys, provider billing |
| Managed | OSA billing, one key |

Done.
";
        let mut r = StreamingRenderer::new(W);
        for end in 0..=doc.len() {
            if !doc.is_char_boundary(end) {
                continue;
            }
            r.update(&doc[..end]);
            let streamed = flat(&r.body_with_cursor());
            assert_eq!(
                streamed,
                full_with_cursor(&doc[..end]),
                "streaming vs full mismatch at prefix len {end}: {:?}",
                &doc[..end]
            );
            let opens = streamed.iter().filter(|l| l.starts_with('┌')).count();
            let closes = streamed.iter().filter(|l| l.starts_with('└')).count();
            assert_eq!(
                opens, closes,
                "prefix len {end}: {opens} open frames vs {closes} closed — the table is drawn \
                 half-open\n{}",
                streamed.join("\n")
            );
        }
        // And the settled render really is the full grid.
        let settled = flat(&r.body());
        assert!(settled.iter().any(|l| l.starts_with('┌')));
        assert_eq!(settled.iter().filter(|l| l.starts_with('├')).count(), 2);
    }

    #[test]
    fn multiple_blank_lines_match_full() {
        assert_stream_matches_full("Para one\n\n\n\nPara two\n\n", &[8, 12, 20, 24]);
    }

    #[test]
    fn width_change_rebuilds_consistently() {
        let doc = "# Heading\n\nBody paragraph one.\n\nBody paragraph two.\n\n";
        let mut r = StreamingRenderer::new(W);
        r.update(doc);
        assert_eq!(flat(&r.body()), full_plain(doc));
        r.set_width(40);
        assert_eq!(
            flat(&r.body()),
            flat(&render_markdown(doc, 40)),
            "after a width change the view must match a full render at the new width"
        );
    }
}

/// The freeze boundary must be safe for GFM pipe tables — the property codex's
/// `TableHoldbackScanner` exists to provide, established here by construction
/// rather than by a scanner.
///
/// # Why there is no holdback module next to this one
///
/// codex (`codex-rs/tui/src/streaming/table_holdback.rs`) commits *completed
/// top-level blocks*, and a newline-terminated table row looks like one. So it
/// needs a state machine — `None | PendingHeader | Confirmed` — to pin a table
/// region into the mutable tail: "adding a row can reflow earlier table rows
/// instead of committing a stale render to scrollback."
///
/// OSA's boundary is stricter to begin with. [`find_frozen_boundary`] only ever
/// splits at a **blank line at depth 0 outside a fence**, and
/// [`render_markdown`](super::markdown::render_markdown) flushes its table
/// accumulator at *any* non-table line — a blank one included
/// (`markdown.rs`, `if in_table { … render_table(…) }`). A blank line is
/// therefore always a table *end*, never a table *interior*, so the column
/// widths of everything before a split point are already final and no later row
/// can reflow them.
///
/// That is an argument, and arguments about renderers are exactly what this
/// project has been burned by, so it is also a test. Each case below is driven
/// one byte at a time, and at every prefix the committed region is compared
/// against the head of a one-shot render of the whole document. If a boundary
/// ever landed inside a table, the committed rows would carry column widths
/// computed from a subset of the rows and the comparison would diverge.
///
/// If this ever goes red, a `TableHoldbackScanner` port is the fix: clamp
/// [`find_frozen_boundary`] to `min(boundary, table_start)`.
#[cfg(test)]
mod table_split_safety {
    use super::*;
    use crate::render::markdown::render_markdown;

    const W: u16 = 60;

    fn flat(t: &ratatui::text::Text<'_>) -> Vec<String> {
        t.lines
            .iter()
            .map(|l| l.spans.iter().map(|s| s.content.as_ref()).collect())
            .collect()
    }

    /// Documents chosen to attack the boundary rule specifically: a blank line
    /// *inside* a table region (the case codex's `Confirmed` state pins), a
    /// header with no delimiter yet (its `PendingHeader` state), quoted and
    /// list-nested tables, pipe rows inside a fence, whitespace-only "blank"
    /// lines, CRLF, and ragged rows whose widest cell arrives last.
    const DOCS: &[&str] = &[
        "Here is the data:\n\n| Name | Value |\n| --- | --- |\n| a | 1 |\n| bbbbbbbbbbbbbbbb | 22222 |\n\nDone.\n",
        "| Name | Value |\n| --- | --- |\n| a | 1 |\n\n| Other | T |\n| --- | --- |\n| xxxxxxxxxx | 9 |\n\n",
        "- one\n\n- two\n\nafter\n",
        "| a | b |\n| --- | --- |\n\n| 1 | 2222222222222 |\n\ntail\n",
        "Intro\n\n> quote\n\n> more\n\nend\n",
        // blank line inside a confirmed table, widest cell in the second half
        "| h1 | h2 |\n| --- | --- |\n| a | b |\n   \n| loooooooooooooooooong | c |\n\nx\n",
        // whitespace-only "blank" (a tab) inside a table
        "| h1 | h2 |\n| --- | --- |\n\t\n| q | wwwwwwwwwwwwwwwwww |\n\ndone\n",
        // blockquoted table split by a blank
        "> | h1 | h2 |\n> | --- | --- |\n\n> | aaaaaaaaaaaa | b |\n\nend\n",
        // table indented inside a list item
        "- item\n\n  | h | v |\n  | --- | --- |\n\n  | wwwwwwwwwwwwwwww | 2 |\n\nafter\n",
        // table immediately after a closed fence
        "```rust\nfn a() {}\n```\n\n| h | v |\n| --- | --- |\n\n| llllllllllllllll | 2 |\n\ntail\n",
        // pipe rows INSIDE a fence — must not be treated as a table at all
        "```\n| h | v |\n| --- | --- |\n\n| a | b |\n```\n\nafter\n",
        // CRLF, with a CRLF blank inside the table
        "| h1 | h2 |\r\n| --- | --- |\r\n\r\n| zzzzzzzzzzzzzzzzzz | b |\r\n\r\nend\r\n",
        // header row committed before its delimiter arrives (PendingHeader)
        "| h1 | h2 |\n\n| --- | --- |\n| a | b |\n\nend\n",
        // ragged rows, widest cell last
        "| a | b | c |\n| --- | --- | --- |\n| 1 |\n\n| 1 | 2 | 33333333333333 |\n\nz\n",
        // quote + list + table nested together
        "> - x\n>\n>   | h | v |\n>   | --- | --- |\n\n>   | wwwwwwwwwww | 2 |\n\nq\n",
    ];

    #[test]
    fn no_prefix_ever_commits_a_table_that_a_later_row_would_reflow() {
        let mut checked = 0usize;
        for (di, doc) in DOCS.iter().enumerate() {
            let full = flat(&render_markdown(doc, W));
            for end in 1..=doc.len() {
                if !doc.is_char_boundary(end) {
                    continue;
                }
                let b = find_frozen_boundary(&doc[..end]);
                if b == 0 {
                    continue;
                }
                checked += 1;
                let committed = flat(&render_markdown(&doc[..b], W));
                assert!(
                    full.len() >= committed.len() && full[..committed.len()] == committed[..],
                    "doc {di}: committing {b} bytes at prefix length {end} produced \
                     rows that are not a prefix of the finished render — a table \
                     was split and its columns reflowed.\n  committed: {committed:#?}\n  \
                     finished head: {:#?}\n  source committed: {:?}",
                    &full[..committed.len().min(full.len())],
                    &doc[..b],
                );
            }
        }
        // A guard that never ran would pass silently.
        assert!(checked > 500, "only {checked} prefixes reached a commit");
    }

    /// The complement: a table whose rows are still arriving is never committed
    /// at all. Nothing may settle until the blank line that closes it lands.
    #[test]
    fn a_growing_table_stays_in_the_mutable_tail() {
        let doc = "Results:\n\n| Name | Status |\n| --- | --- |\n| short | ok |\n| a_much_longer_name | failed |\n\nDone.\n";
        let after_intro = "Results:\n\n".len();
        let table_end = doc.find("\n\nDone.").unwrap() + 2;

        let mut r = StreamingRenderer::new(W);
        for end in 1..=doc.len() {
            if !doc.is_char_boundary(end) {
                continue;
            }
            r.update(&doc[..end]);
            let frozen = r.frozen_bytes();
            assert!(
                frozen <= after_intro || frozen >= table_end,
                "froze {frozen} bytes at prefix {end} — that is inside the table \
                 (rows {after_intro}..{table_end}), so the committed columns were \
                 sized from a subset of the rows"
            );
        }
        assert_eq!(
            r.frozen_bytes(),
            table_end,
            "the completed table should freeze as one unit once its blank line lands"
        );
    }
}
