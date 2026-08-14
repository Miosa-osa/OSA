use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span, Text};
use unicode_segmentation::UnicodeSegmentation;
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

/// Convert a Markdown string to a ratatui [`Text`] value.
///
/// Supported constructs:
///   - Headers  `# H1` … `###### H6`  — styled per level
///   - Fenced code blocks  ` ``` [lang] ` … ` ``` ` — syntax-highlighted via [`crate::render::syntax`]
///   - Inline code `` `expr` `` — code colour + BOLD, no background
///   - **Bold**  `**text**`
///   - *Italic*  `*text*`
///   - `~~text~~` — strikethrough; a SINGLE `~` is always literal (`~50ms`)
///   - Task checkboxes  `- [ ] todo` / `- [x] done` — green checkmark or muted
///     circle, never struck through
///   - Unordered lists  `- item` / `* item` — one `•` at every depth, nested by
///     the model's OWN leading whitespace
///   - Ordered lists    `1. item` / `10) item` — the marker is styled, never rewritten
///   - Links  `[text](url)` — text in cyan+underline followed by the URL in dim parens
///   - Blockquotes  `> text` — muted italic with `│ ` prefix
///   - Horizontal rules  `---` / `***` — a three-column `───`
///   - GFM pipe tables  `| H1 | H2 |` — box-drawing grid, content-sized columns,
///     cells wrap WITH their inline styling
///   - Plain text — unstyled
///
/// # Spacing
///
/// `k` consecutive newlines produce `k − 1` blank rows, uniformly, for every
/// pair of block types. There is no `blank_lines_between(a, b)` table and there
/// must not be one — see `docs/design/tui-output-rendering.md` §A.5. The single
/// exception is one synthetic blank row before an *opening* code fence whose
/// previous row has content, because the fence line itself is erased.
pub fn render_markdown(input: &str, width: u16) -> Text<'static> {
    // `input` is the model's reply, verbatim. Everything below styles it with
    // ratatui `Style` values rather than escape bytes, so the *only* way a
    // control character reaches the terminal from here is by riding along inside
    // the content — which is exactly what ratatui does: it fills a cell with the
    // grapheme it was given, ESC included, and the terminal then executes it.
    //
    // Scrubbing at this one entry covers every construct below it, and every
    // construct added later, including the streaming renderer
    // (`markdown_stream`) which funnels its every path through this function.
    // `\n` and `\t` survive because the parser is line-oriented and code blocks
    // indent with tabs.
    let input = &*crate::render::sanitize::scrub_untrusted_document(input);
    let theme = crate::style::theme();
    let mut lines: Vec<Line<'static>> = Vec::new();

    // Code-block accumulator state.
    let mut in_code_block = false;
    let mut code_lang = String::new();
    let mut code_lines: Vec<String> = Vec::new();

    // Table accumulator state.
    let mut in_table = false;
    let mut table_buf: Vec<String> = Vec::new();

    // Paragraph accumulator: consecutive non-blank prose lines are merged into a
    // single paragraph (Markdown soft-break: a lone `\n` renders as a space). A
    // line ending in two+ spaces or a trailing backslash is a *hard* break and
    // keeps the newline. Each stored entry is `(right-trimmed text, hard_break)`.
    let mut para_buf: Vec<(String, bool)> = Vec::new();

    // Flush the pending paragraph (if any) as wrapped, inline-parsed lines.
    macro_rules! flush_para {
        () => {
            if !para_buf.is_empty() {
                flush_paragraph(&mut para_buf, &mut lines, width, &theme);
            }
        };
    }

    for raw_line in input.lines() {
        // ── Fenced code block boundary ──────────────────────────────────────
        if raw_line.trim_start().starts_with("```") {
            if !in_code_block {
                flush_para!(); // a fence right after prose closes the paragraph
                // …and so does a fence right after a table. Without this the
                // table stayed in its accumulator until the NEXT prose line and
                // was emitted *below* the code block it preceded.
                if in_table {
                    in_table = false;
                    lines.extend(render_table(&table_buf, width, &theme));
                    table_buf.clear();
                }
            }
            if in_code_block {
                // Closing fence: flush accumulated code.
                in_code_block = false;
                let code = code_lines.join("\n");
                let highlighted = crate::render::syntax::highlight(&code, &code_lang);
                push_code_lines(&mut lines, highlighted, width);
                code_lang.clear();
                code_lines.clear();
            } else {
                // Opening fence: extract optional language tag.
                //
                // Take the FIRST whitespace-delimited word of the info string,
                // not the whole remainder: models write ```` ```rust ignore ````
                // and ```` ```python title=foo.py ````, and matching the whole
                // string by token finds no syntax at all, silently dropping the
                // highlighting for the entire block.
                in_code_block = true;
                let rest = raw_line.trim_start().trim_start_matches('`').trim();
                code_lang = rest.split_whitespace().next().unwrap_or("").to_owned();

                // NO synthetic blank row here. §A.5's rule is uniform — k
                // newlines produce k-1 blank rows, with no exceptions — and
                // this was an exception.
                //
                // It manufactured one blank before an opening fence when the
                // previous rendered row was non-empty. That condition cannot
                // survive being split: OSA freezes a prefix into scrollback and
                // re-renders the tail, and when the split lands on the newline
                // immediately before a fence, the tail has no previous row and
                // skips the blank. Measured on
                // "Some prose about the fix.\n```rust\nfn main() {}\n```\nAfter." —
                // one-shot renders 4 rows, split-at-the-fence renders 3, so
                // every row below it moves by one when the block is re-rendered.
                //
                // That is the reported symptom: expanding or resizing shifts
                // the transcript. A height that depends on WHERE a render was
                // split is unusable in a surface that re-renders, and the air
                // before a fence is not worth a moving transcript.
                //
                // A model that wants a blank line there can write one, and the
                // uniform rule will honour it.
            }
            continue;
        }

        if in_code_block {
            code_lines.push(raw_line.to_owned());
            continue;
        }

        // A source line ending in two+ spaces (or a trailing backslash) is a
        // Markdown *hard* line break; capture it before we trim/expand.
        let hard_break = raw_line.ends_with("  ") || raw_line.ends_with('\\');
        // Expand tabs to 4-column stops so indentation and table columns align.
        let raw_line = expand_tabs(raw_line, 4);
        let raw_line = raw_line.as_str();

        // ── GFM pipe tables ─────────────────────────────────────────────────
        let trimmed_for_table = raw_line.trim();
        let is_table_line = trimmed_for_table.starts_with('|') && trimmed_for_table.ends_with('|');
        let is_separator_line = trimmed_for_table.starts_with('|') && trimmed_for_table.contains("---");

        if is_table_line || is_separator_line {
            if !in_table {
                flush_para!(); // a table right after prose closes the paragraph
                in_table = true;
                table_buf.clear();
            }
            table_buf.push(trimmed_for_table.to_string());
            continue;
        }

        // Flush table when we hit a non-table line
        if in_table {
            in_table = false;
            let table_lines = render_table(&table_buf, width, &theme);
            lines.extend(table_lines);
            table_buf.clear();
            // Fall through to process current line normally
        }

        // ── Setext headings (underline style) ────────────────────────────────
        // `text\n===` → H1, `text\n---` → H2, but only when a paragraph is
        // pending; a bare `---` with no preceding prose falls through to the
        // horizontal-rule branch below.
        if !para_buf.is_empty() {
            if let Some(level) = is_setext_underline(raw_line.trim()) {
                let text: String = para_buf
                    .iter()
                    .map(|(t, _)| t.as_str())
                    .collect::<Vec<_>>()
                    .join(" ");
                para_buf.clear();
                let style = if level == 1 {
                    Style::default()
                        .fg(theme.colors.primary)
                        .add_modifier(Modifier::BOLD | Modifier::UNDERLINED)
                } else {
                    Style::default()
                        .fg(theme.colors.primary)
                        .add_modifier(Modifier::BOLD)
                };
                lines.push(Line::from(Span::styled(text, style)));
                continue;
            }
        }

        // ── Headers ─────────────────────────────────────────────────────────
        if raw_line.starts_with("###### ") {
            flush_para!();
            let text = &raw_line[7..];
            let style = Style::default().fg(theme.colors.muted).add_modifier(Modifier::ITALIC);
            push_heading_inline(&mut lines, text, width, style, &theme);
            continue;
        }
        if raw_line.starts_with("##### ") {
            flush_para!();
            let text = &raw_line[6..];
            let style = Style::default().fg(theme.colors.muted);
            push_heading_inline(&mut lines, text, width, style, &theme);
            continue;
        }
        if raw_line.starts_with("#### ") {
            flush_para!();
            let text = &raw_line[5..];
            let style = Style::default().fg(theme.colors.secondary).add_modifier(Modifier::BOLD);
            push_heading_inline(&mut lines, text, width, style, &theme);
            continue;
        }
        if raw_line.starts_with("### ") {
            flush_para!();
            let text = &raw_line[4..];
            let style = Style::default()
                .fg(theme.colors.primary)
                .add_modifier(Modifier::BOLD);
            push_heading_raw(&mut lines, text, width, style);
            continue;
        }
        if raw_line.starts_with("## ") {
            let text = &raw_line[3..];
            let style = Style::default()
                .fg(theme.colors.primary)
                .add_modifier(Modifier::BOLD);
            push_heading_raw(&mut lines, text, width, style);
            continue;
        }
        if raw_line.starts_with("# ") {
            let text = &raw_line[2..];
            let style = Style::default()
                .fg(theme.colors.primary)
                .add_modifier(Modifier::BOLD | Modifier::UNDERLINED);
            push_heading_raw(&mut lines, text, width, style);
            continue;
        }

        // ── Horizontal rules ─────────────────────────────────────────────────
        let trimmed = raw_line.trim();
        if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            flush_para!();
            // THREE columns, not the full pane width (§A.1). A full-width rule
            // inside a reply competes with OSA's own turn separator, which *is*
            // legitimately full width; at three columns the two can never be
            // confused for one another.
            lines.push(Line::from(Span::styled("───".to_string(), theme.faint())));
            continue;
        }

        // ── Blockquotes (nested, word-wrapped) ────────────────────────────────
        // Supports arbitrary depth via `>>` / `> >` markers; each level adds one
        // `│ ` gutter. A `>` with no trailing space (`>text`) is still a quote.
        if trimmed.starts_with('>') {
            flush_para!();
            let (depth, content) = parse_quote_depth(trimmed);
            let style = Style::default()
                .fg(theme.colors.muted)
                .add_modifier(Modifier::ITALIC);
            let gutter = depth.saturating_mul(2);
            let wrapped = wrap_text(&content, (width as usize).saturating_sub(gutter + 2));
            for wline in wrapped {
                let mut spans: Vec<Span<'static>> = Vec::with_capacity(depth + 1);
                for _ in 0..depth {
                    spans.push(Span::styled("│ ".to_owned(), Style::default().fg(theme.colors.dim)));
                }
                spans.push(Span::styled(wline, style));
                lines.push(Line::from(spans));
            }
            continue;
        }

        // ── Task checkboxes ──────────────────────────────────────────────────
        if let Some((checked, text)) = detect_checkbox(trimmed) {
            flush_para!();
            let indent_str = source_indent(raw_line);

            let icon_str = if checked {
                format!("{}✓ ", indent_str)
            } else {
                format!("{}○ ", indent_str)
            };
            let icon_style = if checked {
                Style::default().fg(Color::Green)
            } else {
                theme.faint()
            };
            // A checked item is NOT struck through (§A.1). Models routinely
            // write checked items whose text is still the thing the reader
            // needs to read; `CROSSED_OUT` renders exactly that content as
            // retracted, and on several terminals as barely legible.
            let text_style = if checked {
                theme.faint()
            } else {
                Style::default()
            };
            // Hanging-indent wrap: marker on the first line, blank padding of the
            // same display width on continuation lines, so a long checkbox item
            // wraps instead of clipping at the pane edge.
            let prefix_width = UnicodeWidthStr::width(icon_str.as_str());
            let wrap_width = (width as usize).saturating_sub(prefix_width);
            for (i, row) in parse_and_wrap(text, wrap_width, &theme).into_iter().enumerate() {
                let mut spans = Vec::new();
                if i == 0 {
                    spans.push(Span::styled(icon_str.clone(), icon_style));
                } else {
                    spans.push(Span::styled(" ".repeat(prefix_width), Style::default()));
                }
                for s in row {
                    spans.push(Span::styled(s.content, text_style));
                }
                lines.push(Line::from(spans));
            }
            continue;
        }

        // ── Unordered lists (indent-aware, word-wrapped) ─────────────────────
        // DELIBERATE DEVIATION from §A.1, which says `+` is not a bullet and
        // renders literally. Under an overlay renderer "literally" still means
        // one source line per output row; under this line-oriented rebuilder a
        // run of `+ a\n+ b` would instead be swallowed by the paragraph
        // accumulator and glued into a single sentence. Rendering `+` as a
        // bullet is closer to the intent than that is.
        if trimmed.starts_with("- ") || trimmed.starts_with("* ") || trimmed.starts_with("+ ") {
            flush_para!();
            let text = &trimmed[2..];
            // ONE bullet glyph at every depth, and the model's OWN indentation
            // (§A.1). The old `• / ◦ / ▪` ladder was keyed on `indent / 2`,
            // which classifies 3-space CommonMark nesting and 4-space nesting
            // alike and so gave the same logical depth a different glyph
            // depending only on how the model happened to indent. Reusing the
            // source's leading whitespace verbatim is both simpler and correct.
            let indent_str = source_indent(raw_line);
            let prefix = format!("{}• ", indent_str);
            // DISPLAY COLUMNS, not bytes. The bullet glyphs are multi-byte but
            // single-column ("• " is 4 bytes / 2 columns), so `.len()` here indented
            // every continuation line 2 columns further than its own first line — a
            // visible stagger on every wrapped bullet in every reply — and narrowed
            // `wrap_width` by the same amount, wrapping early. The checkbox branch
            // above already measures correctly with `UnicodeWidthStr`.
            let prefix_cols = UnicodeWidthStr::width(prefix.as_str());
            let wrap_width = (width as usize).saturating_sub(prefix_cols);
            let wrapped = parse_and_wrap(text, wrap_width, &theme);
            for (i, row) in wrapped.into_iter().enumerate() {
                let mut spans = vec![];
                if i == 0 {
                    spans.push(Span::styled(prefix.clone(), Style::default().fg(theme.colors.muted)));
                } else {
                    // Continuation lines align under the first line's text.
                    spans.push(Span::styled(" ".repeat(prefix_cols), Style::default()));
                }
                spans.extend(row);
                lines.push(Line::from(spans));
            }
            continue;
        }

        // ── Ordered lists (indent-aware, depth-styled markers) ───────────────
        // The marker is STYLED, never rewritten (§A.1): `1. `, `10) `, `3. `
        // all render literally. The old `1. / a. / i.` depth ladder renamed the
        // model's own numbering, which is wrong every time the model was
        // numbering something the prose then refers back to. Both `. ` and `) `
        // separators are recognised.
        if let Some(marker) = ordered_marker(trimmed) {
            flush_para!();
            let text = trimmed[marker.len() + 1..].trim_start_matches(' ');
            let indent_str = source_indent(raw_line);
            // Hanging-indent wrap, mirroring the unordered-list branch: the
            // numbered marker on the first line, blank padding of the same
            // width on continuation lines. Without this a long numbered item
            // clipped at the pane edge and its tail was silently lost.
            //
            // Measured in DISPLAY COLUMNS. `.len()` (what this used to use)
            // over-indents every continuation row of a multi-byte marker and
            // narrows the wrap width by the same amount.
            let prefix = format!("{}{} ", indent_str, marker);
            let prefix_cols = UnicodeWidthStr::width(prefix.as_str());
            let wrap_width = (width as usize).saturating_sub(prefix_cols);
            for (i, row) in parse_and_wrap(text, wrap_width, &theme).into_iter().enumerate() {
                let mut spans = Vec::new();
                if i == 0 {
                    spans.push(Span::styled(prefix.clone(), Style::default().fg(theme.colors.muted)));
                } else {
                    spans.push(Span::styled(" ".repeat(prefix_cols), Style::default()));
                }
                spans.extend(row);
                lines.push(Line::from(spans));
            }
            continue;
        }

        // ── Empty lines ───────────────────────────────────────────────────────
        if raw_line.trim().is_empty() {
            flush_para!(); // blank line terminates the current paragraph
            lines.push(Line::from(Span::raw("")));
            continue;
        }

        // ── Plain paragraph line: accumulate for soft-break merging ────────────
        // The paragraph is flushed by the next block-level construct, a blank
        // line, or EOF (see `flush_paragraph`).
        //
        // §A.1 CONTINUATION GUARD. A soft break collapses to a space *except*
        // when the byte right after it is `' '`, `'\t'`, `'>'` or `'|'` — those
        // four signal a list, blockquote or table continuation and the line
        // ending has to survive so the continuation gets its own row. `>` and
        // `|` already have their own branches above, so what is left to handle
        // here is leading whitespace: the previous line is marked as ending in
        // a break so this indented line starts a row of its own instead of
        // being glued onto the end of the previous sentence.
        if raw_line.starts_with([' ', '\t']) {
            if let Some(last) = para_buf.last_mut() {
                last.1 = true;
            }
        }
        para_buf.push((raw_line.trim_end().to_string(), hard_break));
    }

    // Flush any paragraph still pending at EOF (the common streaming case: the
    // in-progress reply has no terminating blank line yet).
    flush_para!();

    // If we hit EOF still inside a code block, flush what we have.
    if in_code_block && !code_lines.is_empty() {
        let code = code_lines.join("\n");
        let highlighted = crate::render::syntax::highlight(&code, &code_lang);
        push_code_lines(&mut lines, highlighted, width);
    }

    // If we hit EOF still inside a table, flush what we have.
    if in_table {
        let table_lines = render_table(&table_buf, width, &theme);
        lines.extend(table_lines);
    }

    Text::from(lines)
}

/// Append syntax-highlighted code lines, wrapping any line wider than `width`
/// on grapheme boundaries so code blocks never clip horizontally (CC parity —
/// HighlightedCode wraps to the render width).
///
/// Every emitted row carries the **full-row code background** (§A.1): the
/// `Line`-level style sets it, and the row is padded out to `width` so the
/// background actually paints the trailing empty space rather than stopping at
/// the last token. This is what makes a fence read as a *block* instead of as
/// differently-coloured prose. Blank rows inside the block, and the final
/// newline-less row of an unterminated fence, are padded the same way — which
/// is why membership is decided by "this row came out of `push_code_lines`"
/// rather than by re-testing a byte range.
fn push_code_lines(out: &mut Vec<Line<'static>>, highlighted: Vec<Line<'static>>, width: u16) {
    let max_w = (width as usize).max(1);
    let bg = crate::style::theme().code_block();
    let mut emit = |spans: Vec<Span<'static>>| {
        let w: usize = spans.iter().map(|s| crate::util::cols(&s.content)).sum();
        let mut spans = spans;
        if w < max_w {
            spans.push(Span::styled(" ".repeat(max_w - w), bg));
        }
        out.push(Line::from(spans).style(bg));
    };
    for line in highlighted {
        let total: usize = line
            .spans
            .iter()
            .map(|s| UnicodeWidthStr::width(s.content.as_ref()))
            .sum();
        if total <= max_w {
            emit(line.spans);
            continue;
        }
        let parts: Vec<(String, Style)> = line
            .spans
            .iter()
            .map(|s| (s.content.to_string(), s.style))
            .collect();
        for row in crate::render::diff::wrap_styled(parts, max_w) {
            emit(
                row.into_iter()
                    .map(|(t, st)| Span::styled(t, st))
                    .collect::<Vec<_>>(),
            );
        }
    }
}

// ─── Paragraph / block helpers ───────────────────────────────────────────────

/// Render an accumulated paragraph (`(text, hard_break)` entries) as wrapped,
/// inline-parsed lines. Consecutive soft-broken lines join with a single space
/// (Markdown soft break); a hard break starts a fresh wrapped segment.
fn flush_paragraph(
    para: &mut Vec<(String, bool)>,
    out: &mut Vec<Line<'static>>,
    width: u16,
    theme: &crate::style::Theme,
) {
    if para.is_empty() {
        return;
    }
    let mut segments: Vec<String> = Vec::new();
    let mut cur = String::new();
    for (text, hard) in para.iter() {
        if cur.is_empty() {
            cur.push_str(text);
        } else {
            cur.push(' ');
            cur.push_str(text);
        }
        if *hard {
            segments.push(std::mem::take(&mut cur));
        }
    }
    if !cur.is_empty() {
        segments.push(cur);
    }
    for seg in segments {
        // Parse the WHOLE segment for inline markup first, then wrap the styled
        // spans. Wrapping the raw markdown first (what this used to do) let the
        // break land inside `**bold**` or inside a link label, which rendered
        // the markers as literal text and dropped the link entirely.
        for row in parse_and_wrap(&seg, width as usize, theme) {
            out.push(Line::from(row));
        }
    }
    para.clear();
}

/// Emit a heading as word-wrapped styled lines (raw text, no inline parsing —
/// matches the h1/h2/h3 behaviour where markup stays literal). Without this a
/// heading wider than the pane clips and its tail is silently lost.
fn push_heading_raw(out: &mut Vec<Line<'static>>, text: &str, width: u16, style: Style) {
    for wline in wrap_text(text, (width as usize).max(1)) {
        out.push(Line::from(Span::styled(wline, style)));
    }
}

/// Emit a heading as word-wrapped lines, re-parsing each wrapped segment for
/// inline markup and layering the heading `style` on top (h4/h5/h6 behaviour).
fn push_heading_inline(
    out: &mut Vec<Line<'static>>,
    text: &str,
    width: u16,
    style: Style,
    theme: &crate::style::Theme,
) {
    for row in parse_and_wrap(text, (width as usize).max(1), theme) {
        let spans: Vec<Span<'static>> = row
            .into_iter()
            .map(|s| Span::styled(s.content, style))
            .collect();
        out.push(Line::from(spans));
    }
}

/// Expand tab characters to spaces on `tabstop`-column stops (display-width
/// aware, so CJK/emoji before a tab still align).
fn expand_tabs(line: &str, tabstop: usize) -> String {
    if !line.contains('\t') {
        return line.to_string();
    }
    let stop = tabstop.max(1);
    let mut out = String::with_capacity(line.len());
    let mut col = 0usize;
    for ch in line.chars() {
        if ch == '\t' {
            let spaces = stop - (col % stop);
            for _ in 0..spaces {
                out.push(' ');
            }
            col += spaces;
        } else {
            out.push(ch);
            col += UnicodeWidthChar::width(ch).unwrap_or(0);
        }
    }
    out
}

/// Parse blockquote nesting depth from a `>`-prefixed line. Handles `>>`,
/// `> >`, and `> ` forms. Returns `(depth, remaining_content)` with the markers
/// and their following spaces stripped.
fn parse_quote_depth(line: &str) -> (usize, String) {
    let mut depth = 0usize;
    let mut rest = line.trim_start();
    while let Some(after) = rest.strip_prefix('>') {
        depth += 1;
        rest = after.trim_start();
    }
    (depth.max(1), rest.to_string())
}

/// The model's OWN leading whitespace, verbatim.
///
/// List nesting is expressed by the indentation the model typed, not by a
/// renderer-chosen ladder — see the unordered-list branch. Rounding it to a
/// multiple of two (`"  ".repeat(indent / 2)`, the previous behaviour) both
/// mis-classified 3-space CommonMark nesting and silently re-indented output
/// the model had aligned deliberately. Tabs are already expanded to 4-column
/// stops by [`expand_tabs`], so this is a display-column-safe run of spaces.
fn source_indent(raw_line: &str) -> String {
    raw_line[..raw_line.len() - raw_line.trim_start().len()].to_string()
}

/// An ordered-list marker at the head of `trimmed`: a run of ASCII digits
/// followed by `.` or `)` and then a space. Returns the marker INCLUDING its
/// separator (`"1."`, `"10)"`) and excluding the space, or `None`.
fn ordered_marker(trimmed: &str) -> Option<String> {
    let digits = trimmed
        .find(|c: char| !c.is_ascii_digit())
        .filter(|&i| i > 0)?;
    let sep = trimmed.as_bytes()[digits];
    if sep != b'.' && sep != b')' {
        return None;
    }
    if trimmed.as_bytes().get(digits + 1) != Some(&b' ') {
        return None;
    }
    Some(trimmed[..=digits].to_string())
}

/// A setext heading underline: a run of only `=` (level 1) or only `-` (level
/// 2), non-empty and containing nothing else.
fn is_setext_underline(line: &str) -> Option<u8> {
    if line.is_empty() {
        None
    } else if line.bytes().all(|b| b == b'=') {
        Some(1)
    } else if line.bytes().all(|b| b == b'-') {
        Some(2)
    } else {
        None
    }
}

// ─── GFM pipe table renderer ─────────────────────────────────────────────────

/// Render a GFM pipe table as styled [`Line`]s with box-drawing borders.
fn render_table(rows: &[String], width: u16, theme: &crate::style::Theme) -> Vec<Line<'static>> {
    if rows.is_empty() {
        return vec![];
    }

    let mut result = Vec::new();

    // Column alignments from the separator row: `:---` left, `:---:` center,
    // `---:` right (GFM).
    let alignments: Vec<ColAlign> = rows
        .iter()
        .find(|r| r.contains("---"))
        .map(|r| {
            r.trim_matches('|')
                .split('|')
                .map(|cell| {
                    let c = cell.trim();
                    match (c.starts_with(':'), c.ends_with(':')) {
                        (true, true) => ColAlign::Center,
                        (false, true) => ColAlign::Right,
                        _ => ColAlign::Left,
                    }
                })
                .collect()
        })
        .unwrap_or_default();

    // Parse cells from each row, skipping separator rows (contain ---)
    let parsed: Vec<Vec<String>> = rows
        .iter()
        .filter(|r| !r.contains("---"))
        .map(|r| {
            r.trim_matches('|')
                .split('|')
                .map(|cell| cell.trim().to_string())
                .collect()
        })
        .collect();

    if parsed.is_empty() {
        return vec![];
    }

    // Rows may be ragged (a model routinely emits a short last row); size the
    // table to the WIDEST row and blank-pad the short ones, so every rendered
    // line has the same number of columns and the borders line up.
    let num_cols = parsed.iter().map(Vec::len).max().unwrap_or(0);
    if num_cols == 0 {
        return vec![];
    }

    let muted = theme.faint();
    // The box-drawing grid. Theme-driven (`border`), never a literal colour, so
    // it tracks the active theme and the light/dark toggle.
    let rule = theme.table_rule();

    // Natural column widths: each column's WIDEST cell measured after inline
    // markdown markup is stripped (so `**bold**` measures as `bold`).
    //
    // Alongside them, the TWO FLOORS (§A.2). A minimum column width has to be
    // derived from the content, not fixed at a constant:
    //
    //   * `word_floor[c]` — the widest unbreakable word in the column, using
    //     the same break rule the cell wrapper uses. Below this the wrapper has
    //     to hard-split words mid-token.
    //   * `hard_floor[c]` — the widest single grapheme. This is the narrowest
    //     width at which text can reflow at all without losing content; a
    //     column of CJK cannot be one column wide.
    //
    // A constant `MIN_COL_W = 3` starves a column below its longest word on one
    // side and wastes room on the other, and says nothing at all about whether
    // a bordered table is drawable.
    let mut natural: Vec<usize> = vec![MIN_COL_W; num_cols];
    let mut word_floor: Vec<usize> = vec![1; num_cols];
    let mut hard_floor: Vec<usize> = vec![0; num_cols];
    for row in &parsed {
        for (i, cell) in row.iter().enumerate() {
            if i < num_cols {
                let plain = inline_plain(cell, theme);
                natural[i] = natural[i].max(inline_visible_width(cell, theme));
                word_floor[i] = word_floor[i].max(widest_unbreakable_word(&plain));
                hard_floor[i] = hard_floor[i].max(widest_grapheme(&plain));
            }
        }
    }

    // Chrome = the 2-column `"│ "` lead-in, the 2-column `" │"` tail, and a
    // 3-column `" │ "` between each pair of columns.
    //
    // The old expression was `(num_cols + 1) + 3 * (num_cols - 1)`, which happens
    // to be right for 3 columns and is short by one for 2 and by two for 1 — so a
    // 2-column table always drew one column wider than the terminal and lost its
    // trailing border.
    let chrome = 4 + num_cols.saturating_sub(1) * 3;

    // Too narrow for a bordered table: a box drawn here is pure noise (and
    // would overflow the terminal). Degrade to plain wrapped text so the
    // CONTENT survives.
    //
    // The trigger fires only AFTER the floors have been tried (§A.2): a table
    // is drawable whenever every column can be given at least its widest single
    // grapheme. Below that the grid would clip every cell mid-glyph, which
    // destroys more than it frames.
    let content_budget = (width as usize).saturating_sub(chrome);
    if (width as usize) < chrome + num_cols
        || hard_floor.iter().map(|f| (*f).max(1)).sum::<usize>() > content_budget
    {
        let w = (width as usize).max(1);
        for row in &parsed {
            let joined = row
                .iter()
                .map(|c| inline_plain(c, theme))
                .filter(|c| !c.trim().is_empty())
                .collect::<Vec<_>>()
                .join(" · ");
            for l in wrap_text(&joined, w) {
                result.push(Line::from(Span::styled(clip_cols(&l, w), muted)));
            }
        }
        return result;
    }

    let col_widths = allocate_col_widths(&natural, &word_floor, &hard_floor, content_budget);

    // `true` as soon as any cell's tail had to be dropped, which is the ONLY
    // condition under which the `▼` continues-below marker is drawn.
    let mut elided = false;

    // Top frame.
    result.push(Line::from(Span::styled(
        table_rule_line('┌', '┬', '┐', &col_widths),
        rule,
    )));

    // Header row (first row, accent + bold).
    if let Some(header) = parsed.first() {
        result.extend(render_row_lines(
            header,
            &col_widths,
            &alignments,
            theme.table_header(),
            rule,
            theme,
            &mut elided,
        ));
    }

    // Rule under the header, then a rule between EVERY pair of data rows, so
    // the table reads as a full grid rather than a header underline. A wrapped
    // multi-line row is otherwise indistinguishable from two separate rows.
    for row in parsed.iter().skip(1) {
        result.push(Line::from(Span::styled(
            table_rule_line('├', '┼', '┤', &col_widths),
            rule,
        )));
        result.extend(render_row_lines(
            row,
            &col_widths,
            &alignments,
            Style::default(),
            rule,
            theme,
            &mut elided,
        ));
    }
    if parsed.len() == 1 {
        // Header-only table: still close it off under the header.
        result.push(Line::from(Span::styled(
            table_rule_line('├', '┼', '┤', &col_widths),
            rule,
        )));
    }

    // Bottom frame.
    result.push(Line::from(Span::styled(
        table_rule_line('└', '┴', '┘', &col_widths),
        rule,
    )));

    // Continues-below marker. Deliberately conditional: it is drawn only when
    // the renderer actually cut content off (a cell taller than
    // `MAX_CELL_LINES`), never unconditionally — an always-on arrow would
    // claim there is more to see under every table that fits perfectly.
    if elided {
        let total: usize = chrome + col_widths.iter().sum::<usize>();
        let pad = total.saturating_sub(1) / 2;
        result.push(Line::from(Span::styled(
            format!("{}\u{25bc}", " ".repeat(pad)),
            theme.table_overflow(),
        )));
    }

    // ── Every row OWNS every column of the region ────────────────────────────
    //
    // `allocate_col_widths` returns the natural widths unchanged when the table
    // fits, so a table narrower than the pane emits lines of
    // `chrome + sum(col_widths)` columns and simply stops — the columns to its
    // right are never written.
    //
    // That is not merely cosmetic, and it is PERMANENT. When the terminal
    // renders a glyph wider than `unicode-width` claims (an emoji-presentation
    // `U+FE0F` sequence, or an ambiguous-width CJK codepoint under a non-CJK
    // locale), the row physically occupies more columns than were reserved, the
    // overhang wraps onto the next line, and every row after it shears down by
    // one. OSA hands finalized content to the terminal's own scrollback via
    // `insert_before`, so a sheared row can NEVER be repainted.
    //
    // Padding each line out to the full region width makes the row own the
    // whole span: an overhang then lands on space this row already owns.
    pad_lines_to_width(result, width as usize)
}

/// Pad every line out to exactly `width` display columns, so each rendered row
/// owns every column of its region. See the note at the end of [`render_table`]
/// for why a row that does not own its full width can corrupt the scrollback.
/// The over-wide side is clipped on GRAPHEME boundaries with **no ellipsis**
/// (§A.2). Letting the terminal clip at the edge instead desyncs by a column on
/// any glyph the terminal renders wider than measured, which strands a ghost
/// cell past the trailing border for the rest of the scrollback's life.
fn pad_lines_to_width(lines: Vec<Line<'static>>, width: usize) -> Vec<Line<'static>> {
    lines
        .into_iter()
        .map(|mut l| {
            let w: usize = l.spans.iter().map(|s| crate::util::cols(&s.content)).sum();
            if w < width {
                l.spans.push(Span::raw(" ".repeat(width - w)));
            } else if w > width {
                l.spans = clip_spans(l.spans, width);
                let cw: usize = l.spans.iter().map(|s| crate::util::cols(&s.content)).sum();
                if cw < width {
                    // A straddling wide grapheme left a 1-column gap; the row
                    // still has to own every column of its region.
                    l.spans.push(Span::raw(" ".repeat(width - cw)));
                }
            }
            l
        })
        .collect()
}

/// One horizontal grid line: `left`, a `─` run per column (plus the one column
/// of cell padding on each side), `mid` at every column join, `right` at the
/// end. Shared by the top frame, the row rules, and the bottom frame so all of
/// them are guaranteed to have their joins in the same places.
fn table_rule_line(left: char, mid: char, right: char, col_widths: &[usize]) -> String {
    let mut s = String::new();
    s.push(left);
    s.push('─');
    for (i, w) in col_widths.iter().enumerate() {
        s.push_str(&"─".repeat(*w));
        if i + 1 < col_widths.len() {
            s.push('─');
            s.push(mid);
            s.push('─');
        }
    }
    s.push('─');
    s.push(right);
    s
}

/// Narrowest a table column may shrink to before the whole table degrades to
/// plain text.
const MIN_COL_W: usize = 3;

/// Ceiling on the visual rows a single wrapped cell may occupy. A pathological
/// cell (a pasted paragraph inside a 12-column column) would otherwise push the
/// rest of the table off screen; past this the cell's tail is elided.
const MAX_CELL_LINES: usize = 8;

/// Distribute `avail` display columns across columns whose CONTENT widths are
/// `natural`, by water-filling.
///
/// **This replaces an equal split** (`avail / num_cols` applied to every column
/// alike), which was the bug behind every right-hand cell in a wide table being
/// clipped at an identical point: a `| Topic | OSA | Codex |` table gave the
/// 5-column `Topic` the same 24 columns as the 90-column prose columns, wasting
/// 19 of them and clipping the prose at exactly 23 characters in every row.
///
/// Water-filling instead raises a common ceiling until the budget is spent:
/// columns narrower than the ceiling keep their full natural width and the
/// columns that actually need room split what is left. Any remainder is then
/// handed to the still-clipped columns, largest unmet demand first, so no
/// column is short by more than one column of a fair share.
/// The floors are per-column, content-derived, and tried in order: the
/// word minimums first, the grapheme floors if those do not fit, and a flat 1
/// only if even those do not (the caller has already degraded to plain text by
/// then, so that last case is defensive).
fn allocate_col_widths(
    natural: &[usize],
    word_floor: &[usize],
    hard_floor: &[usize],
    avail: usize,
) -> Vec<usize> {
    let n = natural.len();
    if n == 0 {
        return Vec::new();
    }
    if natural.iter().sum::<usize>() <= avail {
        return natural.to_vec();
    }
    if avail < n {
        // Caller guards against this; stay panic-free regardless.
        return vec![1; n];
    }

    // Per-column floors, in descending order of preference.
    let clamp = |v: &[usize]| -> Vec<usize> {
        v.iter()
            .enumerate()
            .map(|(i, f)| (*f).max(1).min(natural[i].max(1)))
            .collect()
    };
    let words = clamp(word_floor);
    let hards = clamp(hard_floor);
    let floors: Vec<usize> = if words.iter().sum::<usize>() <= avail {
        words
    } else if hards.iter().sum::<usize>() <= avail {
        hards
    } else {
        vec![1; n]
    };

    // Highest ceiling whose capped total still fits, never below a column's own
    // floor. `floors` is known to fit, so `level = 0` always fits and `level` is
    // well-defined.
    let mut level = 0usize;
    let capped = |l: usize| -> usize {
        (0..n)
            .map(|i| natural[i].min(l).max(floors[i]))
            .sum::<usize>()
    };
    for l in 0..=avail {
        if capped(l) <= avail {
            level = l;
        } else {
            break;
        }
    }
    let mut out: Vec<usize> = (0..n)
        .map(|i| natural[i].min(level).max(floors[i]))
        .collect();

    // Spend the remainder on whichever column is still furthest from its
    // content width.
    let mut leftover = avail.saturating_sub(out.iter().sum::<usize>());
    while leftover > 0 {
        let mut best: Option<usize> = None;
        for i in 0..n {
            if natural[i] <= out[i] {
                continue;
            }
            let demand = natural[i] - out[i];
            match best {
                Some(b) if natural[b] - out[b] >= demand => {}
                _ => best = Some(i),
            }
        }
        match best {
            Some(i) => {
                out[i] += 1;
                leftover -= 1;
            }
            None => break,
        }
    }
    out
}

/// Render one table row into as many [`Line`]s as its tallest cell needs.
///
/// Cells that overflow their column WRAP rather than being clipped, so a narrow
/// terminal degrades readably; short cells are blank-padded down to the row's
/// height so the vertical borders stay aligned.
fn render_row_lines(
    cells: &[String],
    col_widths: &[usize],
    alignments: &[ColAlign],
    base: Style,
    muted: Style,
    theme: &crate::style::Theme,
    elided: &mut bool,
) -> Vec<Line<'static>> {
    let n = col_widths.len();
    let per_cell: Vec<Vec<Vec<Span<'static>>>> = (0..n)
        .map(|i| {
            let cell = cells.get(i).map(String::as_str).unwrap_or("");
            let align = alignments.get(i).copied().unwrap_or(ColAlign::Left);
            cell_lines(cell, col_widths[i], align, base, theme, elided)
        })
        .collect();
    let height = per_cell.iter().map(Vec::len).max().unwrap_or(1).max(1);

    let mut out = Vec::with_capacity(height);
    for j in 0..height {
        let mut spans: Vec<Span<'static>> = vec![Span::styled("│ ".to_string(), muted)];
        for (i, cell) in per_cell.iter().enumerate() {
            match cell.get(j) {
                Some(segs) => spans.extend(segs.iter().cloned()),
                None => spans.push(Span::styled(" ".repeat(col_widths[i]), base)),
            }
            if i + 1 < n {
                spans.push(Span::styled(" │ ".to_string(), muted));
            }
        }
        spans.push(Span::styled(" │".to_string(), muted));
        out.push(Line::from(spans));
    }
    out
}

/// GFM column alignment parsed from the table separator row.
#[derive(Clone, Copy, PartialEq)]
enum ColAlign {
    Left,
    Center,
    Right,
}

/// Render a table cell's INLINE markdown (bold / code / links) as one or more
/// visual lines, each padded to exactly `w` display columns per the column
/// alignment. `base` is the cell's default style, under which each inline span's
/// own style is patched (so header bold + a code cell both apply).
///
/// Inline styling survives WRAPPING (§A.2). The wrapped path used to render the
/// markup-stripped plain text, so any cell that did not fit on one line lost
/// its bold, its code colour and its hyperlink — and in a narrow table that is
/// most cells. Wrapping the *styled spans* instead means there is no mapping
/// back from rendered text to source spans at all, and therefore none of the
/// "a linked `aa` followed by a plain `aa`" mis-attribution that a
/// find-the-substring approach has to defend against.
///
/// All measurement and cutting is display-column and grapheme based
/// ([`crate::util::cols`] / [`UnicodeSegmentation::graphemes`]); nothing here
/// slices by byte or by char.
fn cell_lines(
    cell: &str,
    w: usize,
    align: ColAlign,
    base: Style,
    theme: &crate::style::Theme,
    elided: &mut bool,
) -> Vec<Vec<Span<'static>>> {
    if w == 0 {
        return vec![Vec::new()];
    }
    let styled: Vec<Span<'static>> = parse_inline(cell, theme)
        .into_iter()
        .map(|s| Span::styled(s.content, base.patch(s.style)))
        .collect();
    let total: usize = styled.iter().map(|s| visible_width(s.content.as_ref())).sum();

    if total <= w {
        return vec![pad_cell_spans(styled, total, w, align, base)];
    }

    // Overflow: wrap across as many rows as it needs, capped so one runaway
    // cell cannot swallow the screen.
    let mut wrapped = wrap_cell_spans(styled, w);
    if wrapped.is_empty() {
        wrapped.push(Vec::new());
    }
    if wrapped.len() > MAX_CELL_LINES {
        *elided = true;
        wrapped.truncate(MAX_CELL_LINES);
        if let Some(last) = wrapped.last_mut() {
            *last = elide_spans(std::mem::take(last), w, base);
        }
    }
    wrapped
        .into_iter()
        .map(|row| {
            let row = clip_spans(row, w);
            let lw: usize = row.iter().map(|s| visible_width(s.content.as_ref())).sum();
            pad_cell_spans(row, lw, w, align, base)
        })
        .collect()
}

/// Cut a styled row to at most `w` display columns on GRAPHEME boundaries,
/// preserving each span's style. A span carrying an escape sequence (an OSC-8
/// hyperlink) is atomic: it goes out whole or not at all, because half an
/// escape corrupts the terminal.
fn clip_spans(row: Vec<Span<'static>>, w: usize) -> Vec<Span<'static>> {
    let total: usize = row.iter().map(|s| visible_width(s.content.as_ref())).sum();
    if total <= w {
        return row;
    }
    let mut out: Vec<Span<'static>> = Vec::with_capacity(row.len());
    let mut used = 0usize;
    for span in row {
        if used >= w {
            break;
        }
        let sw = visible_width(span.content.as_ref());
        if used + sw <= w {
            used += sw;
            out.push(span);
            continue;
        }
        if span.content.as_bytes().contains(&0x1b) {
            break; // atomic and it does not fit
        }
        let mut buf = String::new();
        for g in UnicodeSegmentation::graphemes(span.content.as_ref(), true) {
            let gw = UnicodeWidthStr::width(g);
            if used + gw > w {
                break;
            }
            buf.push_str(g);
            used += gw;
        }
        if !buf.is_empty() {
            out.push(Span::styled(buf, span.style));
        }
        break;
    }
    out
}

/// Mark a styled row as elided: cut to `w - 1` columns and append `…` in the
/// cell's base style. The marker is ALWAYS added — the caller only reaches here
/// when content past this point is being dropped.
fn elide_spans(row: Vec<Span<'static>>, w: usize, base: Style) -> Vec<Span<'static>> {
    if w == 0 {
        return Vec::new();
    }
    let mut out = clip_spans(row, w.saturating_sub(1));
    // Trailing spaces before the marker read as a gap, not as elision.
    while let Some(last) = out.last_mut() {
        let trimmed = last.content.trim_end().to_string();
        if trimmed.is_empty() {
            out.pop();
            continue;
        }
        if trimmed.len() != last.content.len() {
            *last = Span::styled(trimmed, last.style);
        }
        break;
    }
    out.push(Span::styled("\u{2026}".to_string(), base));
    out
}

/// Pad `spans` (already `total` columns wide) out to exactly `w` columns.
fn pad_cell_spans(
    spans: Vec<Span<'static>>,
    total: usize,
    w: usize,
    align: ColAlign,
    base: Style,
) -> Vec<Span<'static>> {
    let pad = w.saturating_sub(total);
    let (left, right) = match align {
        ColAlign::Left => (0, pad),
        ColAlign::Right => (pad, 0),
        ColAlign::Center => (pad / 2, pad - pad / 2),
    };
    let mut out: Vec<Span<'static>> = Vec::with_capacity(spans.len() + 2);
    if left > 0 {
        out.push(Span::styled(" ".repeat(left), base));
    }
    out.extend(spans);
    if right > 0 {
        out.push(Span::styled(" ".repeat(right), base));
    }
    out
}

/// Cut `s` to at most `w` display columns on GRAPHEME boundaries. Defensive:
/// [`wrap_text`] already force-breaks over-long words, but a zero-width or
/// ambiguous-width sequence must never be allowed to overflow a column.
fn clip_cols(s: &str, w: usize) -> String {
    if crate::util::cols(s) <= w {
        return s.to_string();
    }
    let mut out = String::new();
    let mut used = 0usize;
    for g in UnicodeSegmentation::graphemes(s, true) {
        let gw = UnicodeWidthStr::width(g);
        if used + gw > w {
            break;
        }
        out.push_str(g);
        used += gw;
    }
    out
}

// ─── Cell word separator (§A.2) ──────────────────────────────────────────────

/// Byte offsets inside `token` at which a table cell may be broken, in addition
/// to spaces.
///
/// Prose wraps on spaces; table cells are narrow enough that a column full of
/// `src/render/markdown.rs` or `2026-08-13` would otherwise be forced to
/// hard-split mid-identifier. A break point sits next to a punctuation or
/// symbol character when:
///
///   * the character after it is **alphabetic** — `foo/bar`, `hello-world`; or
///   * the character after it is a **digit and the character before the
///     punctuation was also a digit** — `555-0101`, `2019-03-15` — *unless* the
///     punctuation is `,` or `.`, which is number formatting: `$145,000`,
///     `3.14` and `1.0.2` stay whole. `EMP-1001` also stays whole, because
///     there is no digit before its `-`.
///
/// **URLs are protected**: a token that looks like a URL yields no break points
/// at all, so click-to-open still works on a wrapped cell.
///
/// Each break point attaches the punctuation to whichever side minimises
/// `max(left, right)`, ties going left — `foo/bar` → `foo/` + `bar`, but
/// `ABCD-EFG` → `ABCD` + `-EFG`.
fn cell_break_points(token: &str) -> Vec<usize> {
    if token.contains("://") || token.starts_with("www.") || token.contains('@') {
        return Vec::new();
    }
    let chars: Vec<(usize, char)> = token.char_indices().collect();
    let total = crate::util::cols(token);
    let mut out = Vec::new();
    for k in 0..chars.len() {
        let (i, c) = chars[k];
        if !is_break_punct(c) {
            continue;
        }
        let Some(&(_, next)) = chars.get(k + 1) else {
            continue;
        };
        let prev = k.checked_sub(1).map(|j| chars[j].1);
        let ok = if next.is_alphabetic() {
            true
        } else if next.is_ascii_digit() {
            prev.is_some_and(|p| p.is_ascii_digit()) && c != ',' && c != '.'
        } else {
            false
        };
        if !ok {
            continue;
        }
        // Attachment: break after the punctuation, or before it, whichever
        // balances the two halves better. Ties keep it on the left.
        let after = i + c.len_utf8();
        let left_after = crate::util::cols(&token[..after]);
        let left_before = crate::util::cols(&token[..i]);
        let cost = |left: usize| left.max(total.saturating_sub(left));
        out.push(if cost(left_before) < cost(left_after) { i } else { after });
    }
    out.retain(|&b| b > 0 && b < token.len());
    out.dedup();
    out
}

/// A punctuation or symbol character eligible to carry a cell break point.
/// `_` is deliberately excluded: `snake_case_name` is one word to a reader.
fn is_break_punct(c: char) -> bool {
    c != '_' && !c.is_alphanumeric() && !c.is_whitespace()
}

/// Widest run of text in `s` that the cell wrapper cannot break — the column's
/// word-minimum floor.
fn widest_unbreakable_word(s: &str) -> usize {
    let mut max = 1usize;
    for token in s.split_whitespace() {
        let mut prev = 0usize;
        for b in cell_break_points(token).into_iter().chain([token.len()]) {
            max = max.max(crate::util::cols(&token[prev..b]));
            prev = b;
        }
    }
    max
}

/// Widest single grapheme in `s` — the column's hard floor, below which text
/// cannot reflow without losing content. `0` for an empty string.
fn widest_grapheme(s: &str) -> usize {
    UnicodeSegmentation::graphemes(s, true)
        .map(|g| UnicodeWidthStr::width(g))
        .max()
        .unwrap_or(0)
}

/// A cell's inline markdown rendered to plain text (markup stripped, OSC-8
/// escapes removed) — what the wrapper and the narrow-terminal fallback lay out.
fn inline_plain(cell: &str, theme: &crate::style::Theme) -> String {
    parse_inline(cell, theme)
        .iter()
        .map(|s| strip_escapes(s.content.as_ref()))
        .collect()
}

/// Sum of a cell's inline spans' visible widths (markup stripped, escapes
/// ignored) — used to size table columns.
fn inline_visible_width(cell: &str, theme: &crate::style::Theme) -> usize {
    parse_inline(cell, theme)
        .iter()
        .map(|s| visible_width(s.content.as_ref()))
        .sum()
}

/// Display width of `s` ignoring OSC-8 escape wrappers (`ESC … ST`).
fn visible_width(s: &str) -> usize {
    // Measured on the WHOLE string, not char by char: `unicode-width` 0.2
    // resolves emoji ZWJ sequences at the string level (`👩‍💻` is 2 columns), so
    // summing per-char widths over-counts it by 2 — which is exactly how much a
    // table row with an emoji cell used to overhang its own border.
    crate::util::cols(&strip_escapes(s))
}

/// Strip ANSI escape wrappers from `s`, leaving visible text.
///
/// **This used to delete the remainder of the string.** It scanned forward from
/// `\x1b` for a `\` (the second byte of an ST terminator) and nothing else, so an
/// SGR sequence — `\x1b[0m`, which contains no `\` — drained the iterator and
/// dropped everything after it. Consumers are [`visible_width`] (which sizes
/// table columns) and `inline_plain` (which produces rendered text), so a single
/// stray SGR would have silently truncated a cell AND mis-sized its column.
///
/// It was LATENT rather than live: `render()` scrubs `\x1b` out of its input via
/// `render/sanitize.rs` before anything reaches here, so no input could actually
/// carry an escape this far. Fixed anyway — the scrubber is a separate module
/// and nothing pins the ordering.
///
/// Terminating an escape correctly needs the INTRODUCER, because CSI and OSC end
/// differently: a CSI ends at its final byte (`@`-`~`), while an OSC payload is
/// arbitrary text (a URL, in OSC-8) that ends only at BEL or ST.
fn strip_escapes(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '\x1b' {
            out.push(c);
            continue;
        }
        match chars.peek() {
            // OSC: ESC ] … (BEL | ESC \). The payload may contain anything.
            Some(']') => {
                chars.next();
                while let Some(n) = chars.next() {
                    if n == '\x07' {
                        break;
                    }
                    if n == '\x1b' {
                        // ST is ESC \ — consume the backslash too.
                        if chars.peek() == Some(&'\\') {
                            chars.next();
                        }
                        break;
                    }
                }
            }
            // CSI: ESC [ <params 0x30-0x3F> <intermediates 0x20-0x2F> <final 0x40-0x7E>.
            Some('[') => {
                chars.next();
                for n in chars.by_ref() {
                    if ('\u{40}'..='\u{7e}').contains(&n) {
                        break;
                    }
                }
            }
            // Two-character escape (ESC M, ESC 7, …).
            Some(_) => {
                chars.next();
            }
            None => {}
        }
    }
    out
}

// ─── Task checkbox detector ──────────────────────────────────────────────────

/// Detects GFM task checkboxes: `- [ ] text`, `- [x] text`, `* [X] text`, etc.
/// Returns `Some((checked, remaining_text))` if the line is a checkbox item.
fn detect_checkbox(line: &str) -> Option<(bool, &str)> {
    let trimmed = line.trim_start();
    if trimmed.starts_with("- [x] ") || trimmed.starts_with("- [X] ") {
        Some((true, &trimmed[6..]))
    } else if trimmed.starts_with("- [ ] ") {
        Some((false, &trimmed[6..]))
    } else if trimmed.starts_with("* [x] ") || trimmed.starts_with("* [X] ") {
        Some((true, &trimmed[6..]))
    } else if trimmed.starts_with("* [ ] ") {
        Some((false, &trimmed[6..]))
    } else {
        None
    }
}

// ─── Inline span parser ───────────────────────────────────────────────────────

// ─── Word wrapper ───────────────────────────────────────────────────────────

/// Word-wrap a string to fit within `max_width` columns.
/// Breaks on word boundaries (spaces), preserving words intact when possible.
/// Lines longer than `max_width` with no spaces are force-broken.
/// Word-wrap ALREADY-STYLED spans, preserving each span's style.
///
/// **Wrap the styled representation, never the raw markdown.** `wrap_text`
/// measures source bytes, so a wrap computed on `**bold phrase**` lands inside
/// the run and each half is then parsed on its own — where an unpaired `**` is
/// correctly literal, and the reader sees the asterisks. `[label](url)` split
/// inside the label is worse: the tail falls through `parse_inline`'s
/// `plain.push('[')` branch and the whole URL is printed as prose with no link
/// emitted at all. Long streamed prose wraps on almost every line, so both fire
/// constantly, not in a corner case.
///
/// Wrapping the styled form also measures the RIGHT width: markers are already
/// gone, so a row fills to the pane edge instead of stopping N columns short.
///
/// Word semantics mirror `wrap_text` exactly (break before a word that would
/// overflow; force-break a word wider than the pane; trailing spaces trimmed),
/// with two additions the plain-text version has no need of:
///
///   * a word may SPAN several styled spans (`**bold**tail` is one word in two
///     spans), so words are grouped across span boundaries and never broken at
///     one;
///   * a span carrying an escape sequence (an OSC-8 hyperlink) is atomic. Its
///     bytes are a matched pair — splitting it would emit an unterminated
///     escape — and it is measured with `util::cols`, which skips escapes,
///     rather than `UnicodeWidthStr`, which would count them as glyphs.
pub(crate) fn wrap_spans(spans: Vec<Span<'static>>, max_width: usize) -> Vec<Vec<Span<'static>>> {
    wrap_spans_inner(spans, max_width, false)
}

/// Word-wrap already-styled spans for a **table cell**: identical to
/// [`wrap_spans`] except that the extra punctuation break points of §A.2 are
/// honoured, so `src/render/markdown.rs` can wrap inside a 20-column column
/// instead of being hard-split mid-identifier.
pub(crate) fn wrap_cell_spans(
    spans: Vec<Span<'static>>,
    max_width: usize,
) -> Vec<Vec<Span<'static>>> {
    wrap_spans_inner(spans, max_width, true)
}

fn wrap_spans_inner(
    spans: Vec<Span<'static>>,
    max_width: usize,
    cell_breaks: bool,
) -> Vec<Vec<Span<'static>>> {
    let max_width = max_width.max(1);
    let total: usize = spans.iter().map(|s| crate::util::cols(s.content.as_ref())).sum();
    if total <= max_width {
        return vec![spans];
    }

    // ── 1. Atoms: (text, style, ends_a_word) ─────────────────────────────────
    // `split_inclusive(' ')` keeps the separating space attached to the word it
    // follows, exactly as `wrap_text` does, so trailing-space handling and the
    // column arithmetic stay identical.
    let mut atoms: Vec<(String, Style, bool)> = Vec::new();
    for span in spans {
        let style = span.style;
        let text = span.content.into_owned();
        if text.is_empty() {
            continue;
        }
        if text.as_bytes().contains(&0x1b) {
            // Atomic: an escape-carrying span is one indivisible unit. Whether
            // it ends a word is decided by its last visible byte.
            let ends = text.ends_with(' ');
            atoms.push((text, style, ends));
            continue;
        }
        let mut it = text.split_inclusive(' ').peekable();
        while let Some(piece) = it.next() {
            let ends = piece.ends_with(' ');
            // A piece that neither ends in a space nor is the span's last piece
            // cannot happen with `split_inclusive`; the last piece continues
            // into the NEXT span, which is what `ends` = false expresses.
            let _ = it.peek();
            if !cell_breaks {
                atoms.push((piece.to_string(), style, ends));
                continue;
            }
            // Cell mode: split further at the punctuation break points, each of
            // which ENDS a word (so the wrapper may break there) without
            // consuming any character.
            let token = piece.trim_end_matches(' ');
            let mut prev = 0usize;
            for b in cell_break_points(token) {
                atoms.push((piece[prev..b].to_string(), style, true));
                prev = b;
            }
            atoms.push((piece[prev..].to_string(), style, ends));
        }
    }

    // ── 2. Group atoms into words ────────────────────────────────────────────
    let mut words: Vec<Vec<(String, Style)>> = Vec::new();
    let mut cur_word: Vec<(String, Style)> = Vec::new();
    for (text, style, ends) in atoms {
        cur_word.push((text, style));
        if ends {
            words.push(std::mem::take(&mut cur_word));
        }
    }
    if !cur_word.is_empty() {
        words.push(cur_word);
    }

    // ── 3. Wrap, word by word ────────────────────────────────────────────────
    let mut rows: Vec<Vec<Span<'static>>> = Vec::new();
    let mut cur: Vec<Span<'static>> = Vec::new();
    let mut col = 0usize;

    for word in words {
        let word_w: usize = word.iter().map(|(t, _)| crate::util::cols(t)).sum();
        if col + word_w > max_width && col > 0 {
            trim_row_end(&mut cur);
            rows.push(std::mem::take(&mut cur));
            col = 0;
        }
        if word_w > max_width && col == 0 {
            // Force-break, grapheme by grapheme, keeping each grapheme's style.
            // Escape-carrying pieces are never broken: they go out whole even if
            // that overshoots, because a split escape corrupts the terminal.
            let mut chunk: Vec<Span<'static>> = Vec::new();
            let mut chunk_w = 0usize;
            for (text, style) in word {
                if text.as_bytes().contains(&0x1b) {
                    let w = crate::util::cols(&text);
                    if !chunk.is_empty() && chunk_w + w > max_width {
                        rows.push(std::mem::take(&mut chunk));
                        chunk_w = 0;
                    }
                    chunk.push(Span::styled(text, style));
                    chunk_w += w;
                    continue;
                }
                let mut buf = String::new();
                let mut buf_w = 0usize;
                for g in UnicodeSegmentation::graphemes(text.as_str(), true) {
                    let gw = UnicodeWidthStr::width(g);
                    if chunk_w + buf_w + gw > max_width && (chunk_w + buf_w) > 0 {
                        if !buf.is_empty() {
                            chunk.push(Span::styled(std::mem::take(&mut buf), style));
                        }
                        rows.push(std::mem::take(&mut chunk));
                        chunk_w = 0;
                        buf_w = 0;
                    }
                    buf.push_str(g);
                    buf_w += gw;
                }
                if !buf.is_empty() {
                    chunk.push(Span::styled(buf, style));
                    chunk_w += buf_w;
                }
            }
            cur = chunk;
            col = chunk_w;
        } else {
            for (text, style) in word {
                cur.push(Span::styled(text, style));
            }
            col += word_w;
        }
    }

    trim_row_end(&mut cur);
    if !cur.is_empty() {
        rows.push(cur);
    }
    if rows.is_empty() {
        rows.push(Vec::new());
    }
    rows
}

/// Drop trailing spaces from a wrapped row, mirroring `wrap_text`'s
/// `trim_end`. A row that becomes empty keeps no zero-width spans.
fn trim_row_end(row: &mut Vec<Span<'static>>) {
    while let Some(last) = row.last_mut() {
        let trimmed = last.content.trim_end().to_string();
        if trimmed.is_empty() {
            row.pop();
            continue;
        }
        if trimmed.len() != last.content.len() {
            *last = Span::styled(trimmed, last.style);
        }
        break;
    }
}

/// Parse `text` for inline markup, then word-wrap the STYLED result to `width`.
///
/// The one-call form of "parse first, wrap second" that every prose block wants.
fn parse_and_wrap(
    text: &str,
    width: usize,
    theme: &crate::style::Theme,
) -> Vec<Vec<Span<'static>>> {
    wrap_spans(parse_inline(text, theme), width)
}

pub(crate) fn wrap_text(input: &str, max_width: usize) -> Vec<String> {
    if max_width == 0 || UnicodeWidthStr::width(input) <= max_width {
        return vec![input.to_string()];
    }

    let mut result: Vec<String> = Vec::new();
    let mut current = String::new();
    let mut col = 0;

    for word in input.split_inclusive(' ') {
        let word_width = UnicodeWidthStr::width(word);
        if col + word_width > max_width && col > 0 {
            result.push(current.trim_end().to_string());
            current = String::new();
            col = 0;
        }
        // Force-break words longer than max_width
        if word_width > max_width && col == 0 {
            let mut chunks = Vec::new();
            let mut chunk = String::new();
            let mut chunk_width = 0;

            for grapheme in UnicodeSegmentation::graphemes(word, true) {
                let grapheme_width = UnicodeWidthStr::width(grapheme);
                if !chunk.is_empty() && chunk_width + grapheme_width > max_width {
                    chunks.push(chunk);
                    chunk = String::new();
                    chunk_width = 0;
                }

                chunk.push_str(grapheme);
                chunk_width += grapheme_width;
            }

            if !chunk.is_empty() {
                chunks.push(chunk);
            }

            if let Some(last) = chunks.pop() {
                result.extend(chunks);
                col = UnicodeWidthStr::width(last.as_str());
                current = last;
            }
        } else {
            current.push_str(word);
            col += word_width;
        }
    }

    if !current.trim().is_empty() {
        result.push(current.trim_end().to_string());
    }

    if result.is_empty() {
        vec![input.to_string()]
    } else {
        result
    }
}

/// Walk `input` character-by-character, emitting styled [`Span`]s for inline
/// Markdown constructs: `` `code` ``, `**bold**`, `*italic*`, `[text](url)`.
/// Everything else is emitted as unstyled text.
fn parse_inline(input: &str, theme: &crate::style::Theme) -> Vec<Span<'static>> {
    let mut spans: Vec<Span<'static>> = Vec::new();
    let mut chars = input.chars().peekable();
    let mut plain = String::new();

    // Helper to flush the accumulated plain buffer. Bare http(s)/file URLs in
    // the flushed run are turned into clickable OSC 8 links (cyan+underline) on
    // capable terminals; everything else stays plain text.
    macro_rules! flush_plain {
        () => {
            if !plain.is_empty() {
                push_plain_autolinked(&mut spans, &plain, theme);
                plain.clear();
            }
        };
    }

    while let Some(&ch) = chars.peek() {
        match ch {
            // ── Inline code: `...` ────────────────────────────────────────
            '`' => {
                chars.next(); // consume opening backtick
                let mut code = String::new();
                for c in chars.by_ref() {
                    if c == '`' {
                        break;
                    }
                    code.push(c);
                }
                if !code.is_empty() {
                    flush_plain!();
                    // Code foreground + BOLD, no background (§A.1/§A.3).
                    // Rendering inline code `muted` with no weight made it
                    // *less* prominent than the prose around it, which is
                    // backwards: `retry_after_ms` is the part of the sentence
                    // the reader is looking for.
                    spans.push(Span::styled(code, theme.inline_code()));
                } else {
                    // Lone backtick — treat as literal.
                    plain.push('`');
                }
            }

            // ── Bold-italic / Bold / Italic: *** / ** / * ──────────────────
            '*' => {
                chars.next(); // consume first `*`
                if chars.peek() == Some(&'*') {
                    chars.next(); // consume second `*`
                    if chars.peek() == Some(&'*') {
                        // ── ***bold italic*** — collect until a closing `***` ──
                        chars.next(); // consume third `*`
                        let mut content = String::new();
                        let mut closed = false;
                        while let Some(&nc) = chars.peek() {
                            if nc == '*' {
                                chars.next(); // first closing `*`
                                if chars.peek() == Some(&'*') {
                                    chars.next(); // second
                                    if chars.peek() == Some(&'*') {
                                        chars.next(); // third → closed
                                        closed = true;
                                        break;
                                    }
                                    content.push_str("**");
                                } else {
                                    content.push('*');
                                }
                            } else {
                                chars.next();
                                content.push(nc);
                            }
                        }
                        if closed && !content.is_empty() {
                            flush_plain!();
                            let style = Style::default()
                                .add_modifier(Modifier::BOLD | Modifier::ITALIC);
                            spans.push(Span::styled(content, style));
                        } else {
                            plain.push_str("***");
                            plain.push_str(&content);
                        }
                    } else {
                        // ── **bold** — collect until a closing `**` ──
                        let mut content = String::new();
                        let mut closed = false;
                        while let Some(&nc) = chars.peek() {
                            if nc == '*' {
                                chars.next(); // consume this `*`
                                if chars.peek() == Some(&'*') {
                                    chars.next(); // consume second closing `*`
                                    closed = true;
                                    break;
                                }
                                // Single `*` inside bold — treat as literal.
                                content.push('*');
                            } else {
                                chars.next();
                                content.push(nc);
                            }
                        }
                        if closed && !content.is_empty() {
                            flush_plain!();
                            let style = Style::default().add_modifier(Modifier::BOLD);
                            spans.push(Span::styled(content, style));
                        } else {
                            plain.push_str("**");
                            plain.push_str(&content);
                        }
                    }
                } else {
                    // ── *italic* ──
                    let mut content = String::new();
                    let mut closed = false;
                    for c in chars.by_ref() {
                        if c == '*' {
                            closed = true;
                            break;
                        }
                        content.push(c);
                    }
                    if closed && !content.is_empty() {
                        flush_plain!();
                        let style = Style::default().add_modifier(Modifier::ITALIC);
                        spans.push(Span::styled(content, style));
                    } else {
                        plain.push('*');
                        plain.push_str(&content);
                    }
                }
            }

            // ── Inline LaTeX math: $…$ / $$…$$ → Unicode ──────────────────
            '$' => {
                chars.next(); // consume `$`
                if chars.peek() == Some(&'$') {
                    // Display math `$$…$$`.
                    chars.next(); // consume second `$`
                    let mut content = String::new();
                    let mut closed = false;
                    while let Some(&nc) = chars.peek() {
                        if nc == '$' {
                            chars.next();
                            if chars.peek() == Some(&'$') {
                                chars.next();
                                closed = true;
                                break;
                            }
                            content.push('$');
                        } else {
                            chars.next();
                            content.push(nc);
                        }
                    }
                    if closed && !content.is_empty() {
                        flush_plain!();
                        spans.push(Span::raw(crate::render::latex::render_math(content.trim())));
                    } else {
                        plain.push_str("$$");
                        plain.push_str(&content);
                    }
                } else {
                    // Inline math `$…$`, with a KaTeX-style currency guard: a `$`
                    // directly followed by whitespace or a digit (`$5`, `$ x`) is
                    // a literal dollar sign, not a math opener.
                    match chars.peek().copied() {
                        Some(c) if c.is_whitespace() || c.is_ascii_digit() => {
                            plain.push('$');
                        }
                        None => plain.push('$'),
                        Some(_) => {
                            let mut content = String::new();
                            let mut closed = false;
                            let mut prev = '\0';
                            for c in chars.by_ref() {
                                // A closing `$` must not be preceded by whitespace.
                                if c == '$' && !prev.is_whitespace() {
                                    closed = true;
                                    break;
                                }
                                content.push(c);
                                prev = c;
                            }
                            if closed && !content.is_empty() {
                                flush_plain!();
                                spans.push(Span::raw(crate::render::latex::render_math(&content)));
                            } else {
                                plain.push('$');
                                plain.push_str(&content);
                            }
                        }
                    }
                }
            }

            // ── Strikethrough: `~~x~~` only ───────────────────────────────
            //
            // A SINGLE tilde is literal text and must stay that way: model
            // output is full of `~50ms`, `~**10%**` and `~/src/main.rs`, and
            // striking those through is both wrong and unreadable. Only the
            // doubled, properly-closed form strikes. The previous behaviour
            // disabled strikethrough outright, which over-corrected — `~~x~~`
            // is genuine markdown that models use to mark superseded values.
            '~' => {
                chars.next(); // consume first `~`
                if chars.peek() == Some(&'~') {
                    chars.next(); // consume second `~`
                    let mut content = String::new();
                    let mut closed = false;
                    while let Some(&nc) = chars.peek() {
                        if nc == '~' {
                            chars.next();
                            if chars.peek() == Some(&'~') {
                                chars.next();
                                closed = true;
                                break;
                            }
                            // A lone `~` inside the run stays literal.
                            content.push('~');
                        } else {
                            chars.next();
                            content.push(nc);
                        }
                    }
                    if closed && !content.is_empty() {
                        flush_plain!();
                        spans.push(Span::styled(
                            content,
                            Style::default().add_modifier(Modifier::CROSSED_OUT),
                        ));
                    } else {
                        plain.push_str("~~");
                        plain.push_str(&content);
                    }
                } else {
                    plain.push('~');
                }
            }

            // ── Links: [text](url) ────────────────────────────────────────
            '[' => {
                chars.next(); // consume `[`
                let mut link_text = String::new();
                let mut found_bracket = false;
                for c in chars.by_ref() {
                    if c == ']' {
                        found_bracket = true;
                        break;
                    }
                    link_text.push(c);
                }
                // Check for `(url)` following the `]`.
                if found_bracket && chars.peek() == Some(&'(') {
                    chars.next(); // consume `(`
                    let mut url = String::new();
                    let mut closed = false;
                    for c in chars.by_ref() {
                        if c == ')' {
                            closed = true;
                            break;
                        }
                        url.push(c);
                    }
                    if !closed {
                        // ── Unterminated `[text](url` — emit the source literally.
                        //
                        // Every other unterminated inline construct in this
                        // function already falls back to its literal source
                        // (`**`, `*`, `$`, `[`), and the references agree that a
                        // half-drawn *visual* span is acceptable mid-stream. A
                        // link is the one case where the intermediate state is
                        // **interactive**: without this branch the destination is
                        // whatever bytes have arrived, so `[docs](https://exa`
                        // rendered a live, clickable OSC 8 hyperlink whose target
                        // mutated on every delta — a click during the stream opens
                        // a truncated URL.
                        //
                        // `Span::raw`, not `plain`: pushing to `plain` would send
                        // the partial through `push_plain_autolinked`, which would
                        // re-create the very mutating hyperlink this removes.
                        flush_plain!();
                        spans.push(Span::raw(format!("[{link_text}]({url}")));
                        continue;
                    }
                    // Emit the link text in cyan+underline, then the target in
                    // dim parens so the user can see (and copy) it.
                    // `mailto:` is stripped to the bare address (CC parity).
                    let display_url = url.strip_prefix("mailto:").unwrap_or(&url);
                    let link_style = Style::default()
                        .fg(theme.colors.secondary)
                        .add_modifier(Modifier::UNDERLINED);
                    if !link_text.is_empty() {
                        flush_plain!();
                        let show_url = !display_url.is_empty() && display_url != link_text;
                        let url_suffix = if show_url {
                            Some(Span::styled(
                                format!(" ({})", display_url),
                                Style::default().fg(theme.colors.dim),
                            ))
                        } else {
                            None
                        };
                        // The visible text is the OSC 8 link; the target is the
                        // raw url (mailto: preserved so it opens a mail client).
                        spans.push(crate::components::osc8::hyperlink_span(
                            link_text, &url, link_style,
                        ));
                        if let Some(s) = url_suffix {
                            spans.push(s);
                        }
                    } else if !display_url.is_empty() {
                        // `[](url)` — show the URL itself as the link text.
                        flush_plain!();
                        spans.push(crate::components::osc8::hyperlink_span(
                            display_url.to_string(),
                            &url,
                            link_style,
                        ));
                    }
                } else if found_bracket {
                    // `[…]` with no `(url)` — either an attachment chip
                    // (`[Image #N]` / `[File #N]`) which we linkify to its
                    // stored file, or a plain bracketed run emitted literally.
                    if let Some(idx) = parse_chip_index(&link_text) {
                        flush_plain!();
                        let chip_style = Style::default().fg(theme.colors.secondary);
                        let display = format!("[{}]", link_text);
                        match crate::components::osc8::attachment_file_url(idx) {
                            Some(url) => spans.push(crate::components::osc8::hyperlink_span(
                                display, &url, chip_style,
                            )),
                            None => spans.push(Span::styled(display, chip_style)),
                        }
                    } else {
                        plain.push('[');
                        plain.push_str(&link_text);
                        plain.push(']');
                    }
                } else {
                    // Unterminated `[` — emit literally.
                    plain.push('[');
                    plain.push_str(&link_text);
                }
            }

            // ── Everything else ───────────────────────────────────────────
            other => {
                chars.next();
                plain.push(other);
            }
        }
    }

    flush_plain!();
    spans
}

// ─── Bare-URL autolinking + attachment chips ─────────────────────────────────

/// Push `text` as spans, turning bare `http(s)://` / `file://` URLs into
/// clickable OSC 8 links (cyan+underline) on capable terminals. Non-URL text is
/// emitted as plain `Span::raw`.
fn push_plain_autolinked(
    spans: &mut Vec<Span<'static>>,
    text: &str,
    theme: &crate::style::Theme,
) {
    if text.is_empty() {
        return;
    }
    let link_style = Style::default()
        .fg(theme.colors.secondary)
        .add_modifier(Modifier::UNDERLINED);
    let mut rest = text;
    while let Some((start, len)) = next_bare_url(rest) {
        let (pre, tail) = rest.split_at(start);
        if !pre.is_empty() {
            spans.push(Span::raw(pre.to_string()));
        }
        let (url, after) = tail.split_at(len);
        spans.push(crate::components::osc8::hyperlink_span(
            url.to_string(),
            url,
            link_style,
        ));
        rest = after;
    }
    if !rest.is_empty() {
        spans.push(Span::raw(rest.to_string()));
    }
}

/// Locate the next bare URL in `s`. Returns `(byte_start, byte_len)` of the URL
/// run, or `None`. Recognises `https://`, `http://`, `file://`; the run extends
/// to the first whitespace/delimiter, then trailing sentence punctuation and
/// unbalanced closing brackets are trimmed off. The returned length is always
/// ≥ the scheme length, so callers always make progress.
fn next_bare_url(s: &str) -> Option<(usize, usize)> {
    const SCHEMES: [&str; 3] = ["https://", "http://", "file://"];
    let start = SCHEMES.iter().filter_map(|sc| s.find(sc)).min()?;
    let bytes = s.as_bytes();
    let mut end = start;
    while end < s.len() {
        match bytes[end] {
            b' ' | b'\t' | b'\n' | b'\r' | b'<' | b'>' | b'"' | b'`' | b'\'' => break,
            _ => end += 1,
        }
    }
    let url = &s[start..end];
    let trimmed = trim_url_trailing(url);
    Some((start, trimmed))
}

/// Byte length of `url` after stripping trailing sentence punctuation and
/// unbalanced closing brackets (kept ASCII-only so the cut stays on a char
/// boundary). Never trims below the scheme's `://`.
fn trim_url_trailing(url: &str) -> usize {
    let bytes = url.as_bytes();
    let min = url.find("://").map(|i| i + 3).unwrap_or(0);
    let mut end = url.len();
    while end > min {
        match bytes[end - 1] {
            b'.' | b',' | b';' | b':' | b'!' | b'?' => end -= 1,
            b')' => {
                let seg = &url[..end];
                if seg.bytes().filter(|&b| b == b')').count()
                    > seg.bytes().filter(|&b| b == b'(').count()
                {
                    end -= 1;
                } else {
                    break;
                }
            }
            b']' => {
                let seg = &url[..end];
                if seg.bytes().filter(|&b| b == b']').count()
                    > seg.bytes().filter(|&b| b == b'[').count()
                {
                    end -= 1;
                } else {
                    break;
                }
            }
            _ => break,
        }
    }
    end
}

/// If `s` is an attachment chip label (`Image #N` / `File #N`), return its
/// 1-based index `N`.
fn parse_chip_index(s: &str) -> Option<usize> {
    let num = s
        .strip_prefix("Image #")
        .or_else(|| s.strip_prefix("File #"))?;
    num.parse::<usize>().ok()
}

#[cfg(test)]
mod tests {
    use super::{
        expand_tabs, is_setext_underline, next_bare_url, parse_chip_index,
        parse_inline, parse_quote_depth, render_markdown, trim_url_trailing, wrap_text,
    };
    use ratatui::style::{Modifier, Style};

    /// Flatten a full render to per-line visible strings (OSC-8 stripped).
    fn render_lines(src: &str, width: u16) -> Vec<String> {
        render_markdown(src, width)
            .lines
            .iter()
            .map(|l| strip_osc8(&l.spans.iter().map(|s| s.content.as_ref()).collect::<String>()))
            .collect()
    }

    /// Strip OSC 8 wrappers so assertions test the *visible* text regardless of
    /// whether the test host's terminal enabled hyperlinks.
    fn strip_osc8(s: &str) -> String {
        let mut out = String::new();
        let mut chars = s.chars();
        while let Some(c) = chars.next() {
            if c == '\x1b' {
                // Consume through the String Terminator (`ESC \`).
                for n in chars.by_ref() {
                    if n == '\\' {
                        break;
                    }
                }
            } else {
                out.push(c);
            }
        }
        out
    }

    fn flat(spans: &[ratatui::text::Span<'_>]) -> String {
        let raw: String = spans.iter().map(|s| s.content.as_ref()).collect();
        strip_osc8(&raw)
    }

    #[test]
    fn wraps_streaming_cursor_without_splitting_utf8() {
        let input = "Notes](https://adtools.org/buyers-guide/ai-news-anthropic-claude-code-█";

        let wrapped = wrap_text(input, 71);

        assert_eq!(wrapped, vec![input]);
    }

    /// `~~x~~` strikes; a SINGLE `~` never does.
    ///
    /// The single-tilde demotion is the load-bearing half: models write `~50ms`,
    /// `~**10%**` and `~/src/main.rs` constantly, and a renderer that treats one
    /// tilde as an opener strikes through the rest of the sentence looking for
    /// its partner.
    #[test]
    fn double_tilde_strikes_and_single_tilde_stays_literal() {
        let theme = crate::style::theme();
        let struck = parse_inline("~~gone~~", &theme);
        assert_eq!(flat(&struck), "gone");
        assert!(struck
            .iter()
            .any(|s| s.style.add_modifier.contains(Modifier::CROSSED_OUT)));

        for src in ["~50ms", "about ~10% of the time", "see ~/src/main.rs"] {
            let spans = parse_inline(src, &theme);
            assert_eq!(flat(&spans), src, "single tilde was consumed in {src:?}");
            assert!(
                spans
                    .iter()
                    .all(|s| !s.style.add_modifier.contains(Modifier::CROSSED_OUT)),
                "a single tilde struck through {src:?}"
            );
        }
        // Unclosed `~~` falls back to its literal source.
        let open = parse_inline("~~half written", &theme);
        assert_eq!(flat(&open), "~~half written");
    }

    #[test]
    fn link_url_is_visible() {
        let theme = crate::style::theme();
        let spans = parse_inline("[docs](https://osa.dev)", &theme);
        assert_eq!(flat(&spans), "docs (https://osa.dev)");
    }

    /// An unterminated `[label](url` must NOT become a live hyperlink.
    ///
    /// Before this was fixed, the `(url)` scanner had no "closed" flag: it ran
    /// to end-of-line and emitted an OSC 8 hyperlink pointing at whatever bytes
    /// had arrived. Mid-stream that is a *clickable* element whose destination
    /// changes on every delta, and the `](`/URL source text was swallowed
    /// outright — `[docs](https://exa` rendered as the four characters `docs`.
    #[test]
    fn unterminated_link_renders_literally_not_as_a_hyperlink() {
        let theme = crate::style::theme();
        let spans = parse_inline("see [docs](https://exa", &theme);
        // Visible text is the literal source — nothing swallowed.
        assert_eq!(flat(&spans), "see [docs](https://exa");
        // Nothing is styled as a link (cyan + underline) …
        assert!(
            spans
                .iter()
                .all(|s| !s.style.add_modifier.contains(Modifier::UNDERLINED)),
            "unterminated link rendered as an underlined link span: {spans:?}"
        );
        // … and no OSC 8 escape was emitted for it.
        assert!(
            spans.iter().all(|s| !s.content.contains('\x1b')),
            "unterminated link emitted an OSC 8 escape: {spans:?}"
        );
    }

    /// The partial URL must not be recovered as a *bare* autolink either: the
    /// literal fallback goes out as a raw span rather than through
    /// `push_plain_autolinked`, which would re-create the mutating hyperlink.
    #[test]
    fn unterminated_link_partial_url_is_not_bare_autolinked() {
        let theme = crate::style::theme();
        // Long enough that `next_bare_url` would certainly match `https://…`.
        let spans = parse_inline("[OSA docs](https://osa.dev/guide/strea", &theme);
        assert_eq!(flat(&spans), "[OSA docs](https://osa.dev/guide/strea");
        assert!(
            spans.iter().all(|s| !s.content.contains('\x1b')),
            "partial URL was autolinked: {spans:?}"
        );
    }

    /// Token-by-token: no clickable link exists at any point until the `)`
    /// lands, and the instant it does the real link appears.
    #[test]
    fn link_becomes_clickable_only_on_the_closing_paren() {
        let theme = crate::style::theme();
        let full = "[docs](https://osa.dev)";
        let mut linked_prefixes = Vec::new();
        for end in 1..=full.len() {
            let spans = parse_inline(&full[..end], &theme);
            if spans
                .iter()
                .any(|s| s.style.add_modifier.contains(Modifier::UNDERLINED))
            {
                linked_prefixes.push(&full[..end]);
            }
        }
        assert_eq!(
            linked_prefixes,
            vec![full],
            "a link span appeared before the URL was complete"
        );
    }

    /// The streaming tail is rendered with a block cursor appended, so the
    /// unterminated form seen in practice is `…(https://exa█`. The cursor must
    /// never end up inside a link target.
    #[test]
    fn unterminated_link_with_streaming_cursor_is_literal() {
        let theme = crate::style::theme();
        let spans = parse_inline("[docs](https://exa\u{2588}", &theme);
        assert_eq!(flat(&spans), "[docs](https://exa\u{2588}");
        assert!(
            spans.iter().all(|s| !s.content.contains('\x1b')),
            "cursor leaked into a hyperlink target: {spans:?}"
        );
    }

    #[test]
    fn mailto_is_stripped_and_deduped() {
        let theme = crate::style::theme();
        let spans = parse_inline("[a@b.co](mailto:a@b.co)", &theme);
        assert_eq!(flat(&spans), "a@b.co");
    }

    /// The model's own numbering survives verbatim, at every depth and with
    /// either separator. The old depth ladder rewrote `2.` as `b.` and `4.` as
    /// `iv.` once nested, which renames content the prose refers back to.
    #[test]
    fn ordered_list_markers_are_never_rewritten() {
        assert_eq!(super::ordered_marker("2. x").as_deref(), Some("2."));
        assert_eq!(super::ordered_marker("10) x").as_deref(), Some("10)"));
        assert_eq!(super::ordered_marker("2.x"), None);
        assert_eq!(super::ordered_marker(". x"), None);
        assert_eq!(super::ordered_marker("2a. x"), None);
        let rows = render_lines("1. one\n  2. two\n    10) ten\n", 40);
        assert_eq!(rows, vec!["1. one", "  2. two", "    10) ten"]);
    }

    #[test]
    fn bare_url_is_autolinked_and_visible() {
        let theme = crate::style::theme();
        let spans = parse_inline("see https://osa.dev/docs for more", &theme);
        // Visible text is unchanged (link escapes, if any, are stripped).
        assert_eq!(flat(&spans), "see https://osa.dev/docs for more");
    }

    #[test]
    fn next_bare_url_finds_and_bounds_url() {
        let (start, len) = next_bare_url("go to https://a.co/x now").unwrap();
        assert_eq!(&"go to https://a.co/x now"[start..start + len], "https://a.co/x");
        assert!(next_bare_url("no url here").is_none());
    }

    #[test]
    fn trailing_punctuation_is_trimmed_from_url() {
        // Sentence period is not part of the URL.
        let s = "https://osa.dev.";
        assert_eq!(&s[..trim_url_trailing(s)], "https://osa.dev");
        // Balanced parens inside a path are kept.
        let s = "https://en.wikipedia.org/wiki/Rust_(programming)";
        assert_eq!(&s[..trim_url_trailing(s)], s);
        // An unbalanced trailing paren is dropped.
        let s = "https://osa.dev)";
        assert_eq!(&s[..trim_url_trailing(s)], "https://osa.dev");
    }

    #[test]
    fn chip_index_parses_image_and_file() {
        assert_eq!(parse_chip_index("Image #3"), Some(3));
        assert_eq!(parse_chip_index("File #12"), Some(12));
        assert_eq!(parse_chip_index("not a chip"), None);
        assert_eq!(parse_chip_index("Image #x"), None);
    }

    #[test]
    fn image_chip_renders_as_styled_token() {
        let theme = crate::style::theme();
        // No registered path → styled chip, visible token preserved.
        let spans = parse_inline("look at [Image #1] please", &theme);
        assert_eq!(flat(&spans), "look at [Image #1] please");
    }

    #[test]
    fn table_right_alignment_pads_left() {
        let theme = crate::style::theme();
        let rows = vec![
            "| h |".to_string(),
            "| ---: |".to_string(),
            "| x |".to_string(),
        ];
        let lines = super::render_table(&rows, 80, &theme);
        let data_row: String = lines
            .iter()
            .map(|l| l.spans.iter().map(|s| s.content.as_ref()).collect::<String>())
            .find(|l: &String| l.contains('x'))
            .expect("data row");
        assert!(data_row.contains("  x"), "{:?}", data_row);
    }

    // ── U-T31: combined bold-italic + setext headings ───────────────────────

    #[test]
    fn triple_star_is_bold_italic() {
        let theme = crate::style::theme();
        let spans = parse_inline("say ***loud*** now", &theme);
        assert_eq!(flat(&spans), "say loud now");
        let strong = spans.iter().find(|s| s.content == "loud").expect("bold-italic span");
        assert!(strong.style.add_modifier.contains(Modifier::BOLD));
        assert!(strong.style.add_modifier.contains(Modifier::ITALIC));
    }

    #[test]
    fn triple_star_unclosed_is_literal() {
        let theme = crate::style::theme();
        let spans = parse_inline("***oops", &theme);
        assert_eq!(flat(&spans), "***oops");
    }

    #[test]
    fn setext_underline_detection() {
        assert_eq!(is_setext_underline("==="), Some(1));
        assert_eq!(is_setext_underline("---"), Some(2));
        assert_eq!(is_setext_underline("=-="), None);
        assert_eq!(is_setext_underline(""), None);
    }

    #[test]
    fn setext_h1_and_h2_render() {
        // "Title\n===" → one H1 line "Title" (+ a breathing-room blank).
        let l = render_lines("Title\n===\n", 40);
        assert_eq!(l[0], "Title");
        // A dash underline after prose is H2, NOT a horizontal rule.
        let l2 = render_lines("Subhead\n---\n", 40);
        assert_eq!(l2[0], "Subhead");
        assert!(!l2[0].contains('─'), "must not render as a horizontal rule");
    }

    #[test]
    fn bare_dash_rule_still_works_without_preceding_prose() {
        // No pending paragraph → `---` is a horizontal rule, not setext.
        let l = render_lines("\n---\n", 20);
        assert!(l.iter().any(|s| s.contains('─')), "{:?}", l);
    }

    // ── U-T8: inline LaTeX → Unicode ────────────────────────────────────────

    #[test]
    fn inline_math_converts_to_unicode() {
        let theme = crate::style::theme();
        assert_eq!(flat(&parse_inline("energy $E = mc^2$ here", &theme)), "energy E = mc² here");
        assert_eq!(flat(&parse_inline("$\\alpha + \\beta$", &theme)), "α + β");
        assert_eq!(flat(&parse_inline("water $H_2O$", &theme)), "water H₂O");
    }

    #[test]
    fn dollar_currency_stays_literal() {
        let theme = crate::style::theme();
        // A `$` followed by a digit/space is not a math opener.
        assert_eq!(flat(&parse_inline("it costs $5 and $10", &theme)), "it costs $5 and $10");
    }

    // ── U-T10: table-cell inline markdown, nested quotes, tabs, soft-breaks ──

    #[test]
    fn table_cell_inline_markdown_renders() {
        let l = render_lines("| Name | Note |\n|---|---|\n| **bold** | `code` |\n", 60);
        let body = l.join("\n");
        assert!(body.contains("bold"), "{:?}", l);
        assert!(!body.contains("**bold**"), "asterisks must be consumed: {:?}", l);
        assert!(body.contains("code"), "{:?}", l);
    }

    #[test]
    fn nested_blockquote_depth_and_gutters() {
        assert_eq!(parse_quote_depth("> a"), (1, "a".to_string()));
        assert_eq!(parse_quote_depth(">> b"), (2, "b".to_string()));
        assert_eq!(parse_quote_depth("> > c"), (2, "c".to_string()));
        // Two gutters for a depth-2 quote.
        let l = render_lines(">> deep\n", 40);
        assert_eq!(l[0].matches("│ ").count(), 2, "{:?}", l);
    }

    #[test]
    fn tabs_expand_to_stops() {
        assert_eq!(expand_tabs("a\tb", 4), "a   b");
        assert_eq!(expand_tabs("ab\tc", 4), "ab  c");
        assert_eq!(expand_tabs("abcd\te", 4), "abcd    e");
        assert_eq!(expand_tabs("no tabs", 4), "no tabs");
    }

    #[test]
    fn soft_break_merges_consecutive_prose_lines() {
        // Two consecutive non-blank prose lines → one wrapped paragraph.
        let l = render_lines("line one\nline two\n", 80);
        assert_eq!(l, vec!["line one line two".to_string()]);
    }

    #[test]
    fn hard_break_keeps_the_line_split() {
        // Trailing two spaces force a hard break → two output lines.
        let l = render_lines("line one  \nline two\n", 80);
        assert_eq!(l, vec!["line one".to_string(), "line two".to_string()]);
    }

    // ── B1: ordered lists / checkboxes / headings must word-wrap, not clip ────

    #[test]
    fn long_ordered_list_item_wraps_instead_of_clipping() {
        // A numbered item far wider than the pane must span multiple lines with
        // no visible text lost (previously it rendered one clipped line).
        let src = "1. alpha beta gamma delta epsilon zeta eta theta iota kappa\n";
        let l = render_lines(src, 20);
        assert!(l.len() > 1, "expected wrapping, got {:?}", l);
        // Every source word survives across the wrapped lines.
        let joined = l.join(" ");
        for word in ["alpha", "kappa", "epsilon", "theta"] {
            assert!(joined.contains(word), "lost word {word:?}: {:?}", l);
        }
        // Continuation lines are hanging-indented (start with spaces, no marker).
        assert!(l[0].starts_with("1."), "{:?}", l);
        assert!(l[1].starts_with(' '), "continuation not indented: {:?}", l);
    }

    #[test]
    fn long_heading_wraps_instead_of_clipping() {
        let src = "## alpha beta gamma delta epsilon zeta eta theta iota kappa\n";
        let l = render_lines(src, 20);
        // Drop the trailing breathing-room blank line before counting.
        let content: Vec<&String> = l.iter().filter(|s| !s.is_empty()).collect();
        assert!(content.len() > 1, "expected heading to wrap: {:?}", l);
        let joined = l.join(" ");
        for word in ["alpha", "kappa", "iota"] {
            assert!(joined.contains(word), "lost word {word:?}: {:?}", l);
        }
    }

    #[test]
    fn long_checkbox_item_wraps_instead_of_clipping() {
        let src = "- [ ] alpha beta gamma delta epsilon zeta eta theta iota kappa\n";
        let l = render_lines(src, 20);
        assert!(l.len() > 1, "expected checkbox to wrap: {:?}", l);
        let joined = l.join(" ");
        for word in ["alpha", "kappa", "zeta"] {
            assert!(joined.contains(word), "lost word {word:?}: {:?}", l);
        }
        assert!(l[0].starts_with('○'), "{:?}", l);
    }

    // ── DEFECT 2: table column allocation + cell wrapping ───────────────────

    #[test]
    fn allocate_col_widths_is_identity_when_the_table_fits() {
        assert_eq!(super::allocate_col_widths(&[5, 40, 40], &[5, 6, 6], &[1, 1, 1], 200), vec![5, 40, 40]);
    }

    /// The bug: an equal split gave the 5-column heading the same share as two
    /// prose columns. Water-filling leaves the narrow column untouched and
    /// spends everything it saved on the columns that actually need it.
    #[test]
    fn allocate_col_widths_shrinks_only_the_greedy_columns() {
        let out = super::allocate_col_widths(&[5, 40, 40], &[5, 6, 6], &[1, 1, 1], 60);
        assert_eq!(out.iter().sum::<usize>(), 60, "{out:?} must spend the budget");
        assert_eq!(out[0], 5, "a column that already fits must not be padded: {out:?}");
        assert!(out[1] > 5 && out[2] > 5, "{out:?}");
        assert!(out[1].abs_diff(out[2]) <= 1, "equal demand → equal share: {out:?}");
    }

    /// It must never hand out more than the budget, at any width, and never
    /// panic on the degenerate ones.
    #[test]
    fn allocate_col_widths_never_exceeds_its_budget() {
        let naturals: &[&[usize]] = &[
            &[5, 40, 40],
            &[3, 3, 3],
            &[100],
            &[1, 2, 3, 4, 5, 6, 7],
            &[80, 4, 4, 4],
        ];
        for nat in naturals {
            for avail in 0usize..=200 {
                let floors: Vec<usize> = nat.iter().map(|w| (*w).min(4)).collect();
                let hards: Vec<usize> = vec![1; nat.len()];
                let out = super::allocate_col_widths(nat, &floors, &hards, avail);
                assert_eq!(out.len(), nat.len());
                if avail >= nat.len() {
                    assert!(
                        out.iter().sum::<usize>() <= avail,
                        "{nat:?} @ {avail} → {out:?}"
                    );
                }
                assert!(out.iter().all(|w| *w >= 1), "{nat:?} @ {avail} → {out:?}");
            }
        }
    }

    /// A cell too wide for its column wraps onto extra rows instead of being cut
    /// off with `…`, and every produced row is padded to exactly the column
    /// width in DISPLAY COLUMNS.
    #[test]
    fn table_cell_wraps_and_pads_to_exact_width() {
        let theme = crate::style::theme();
        let out = super::cell_lines(
            "orchestrator.ex (52KB) + OTP supervisors",
            12,
            super::ColAlign::Left,
            Style::default(),
            &theme,
            &mut false,
        );
        assert!(out.len() > 1, "expected the cell to wrap: {out:?}");
        let joined: String = out
            .iter()
            .map(|l| l.iter().map(|s| s.content.as_ref()).collect::<String>())
            .collect::<Vec<_>>()
            .join(" ");
        // `orchestrator.ex` is 15 columns and cannot fit a 12-column column, so
        // it is force-broken — but nothing is DISCARDED, which is the point.
        for word in ["orchestrator", "52KB", "OTP", "supervisors"] {
            assert!(joined.contains(word), "lost {word:?}: {joined:?}");
        }
        for line in &out {
            let w: usize = line.iter().map(|s| crate::util::cols(s.content.as_ref())).sum();
            assert_eq!(w, 12, "cell row is {w} cols, want 12: {line:?}");
        }
    }

    /// A runaway cell is capped at [`super::MAX_CELL_LINES`] rows, with the cut
    /// marked — the one place truncation is still allowed.
    #[test]
    fn table_cell_wrapping_is_capped() {
        let theme = crate::style::theme();
        let cell = "lorem ipsum dolor sit amet ".repeat(40);
        let mut elided = false;
        let out =
            super::cell_lines(&cell, 6, super::ColAlign::Left, Style::default(), &theme, &mut elided);
        assert_eq!(out.len(), super::MAX_CELL_LINES);
        assert!(elided, "the cap must report that content was dropped");
        let last: String = out[out.len() - 1]
            .iter()
            .map(|s| s.content.as_ref())
            .collect();
        assert!(last.contains('\u{2026}'), "elision marker missing: {last:?}");
    }

    /// Wide glyphs are measured at their true 2-column advance, so a CJK cell
    /// pads to the same total as an ASCII one and the box stays square.
    #[test]
    fn table_cell_wide_glyphs_pad_by_columns_not_chars() {
        let theme = crate::style::theme();
        for cell in ["模型", "ｶﾞｶﾞ", "abc", "日本語のテキストがここに入ります"] {
            for w in 3usize..=20 {
                for line in
                    super::cell_lines(cell, w, super::ColAlign::Left, Style::default(), &theme, &mut false)
                {
                    let got: usize =
                        line.iter().map(|s| crate::util::cols(s.content.as_ref())).sum();
                    assert_eq!(got, w, "cell {cell:?} @ {w} produced {got} cols: {line:?}");
                }
            }
        }
    }

    /// Below the width where a bordered table can be drawn at all, the renderer
    /// degrades to plain wrapped rows rather than emitting a broken box that
    /// overflows the terminal.
    #[test]
    fn very_narrow_table_degrades_to_plain_text() {
        let src = "| a | b | c |\n|---|---|---|\n| one | two | three |\n";
        let l = render_lines(src, 8);
        assert!(
            l.iter().all(|s| !s.contains('┼')),
            "expected no box drawing at width 8: {l:?}"
        );
        let joined = l.join(" ");
        for word in ["one", "two", "three"] {
            assert!(joined.contains(word), "lost {word:?}: {l:?}");
        }
    }

    // ── Row ownership: a rendered row must own EVERY column of its region ────
    //
    // `allocate_col_widths` returns the natural widths unchanged when the table
    // fits, so a table narrower than the pane emitted lines of
    // `chrome + sum(col_widths)` columns and simply stopped — the columns to its
    // right were never written.
    //
    // That is not cosmetic and it is PERMANENT. When the terminal renders a glyph
    // wider than `unicode-width` claims (emoji-presentation `U+FE0F`, or
    // ambiguous-width CJK under a non-CJK locale) the row physically occupies
    // more columns than were reserved, the overhang wraps, and every row below
    // shears down by one. OSA hands finalized content to the terminal's own
    // scrollback via `insert_before`, so a sheared row can never be repainted.
    //
    // The existing invariants nearby check adjacent properties and cannot see
    // this: `layout_invariants.rs` asserts rows equal EACH OTHER, and separately
    // that there is no ink BELOW the reserved rows. Neither asserts that every
    // column WITHIN a row was written.

    fn line_cols(l: &ratatui::text::Line<'_>) -> usize {
        l.spans.iter().map(|s| crate::util::cols(&s.content)).sum()
    }

    fn rows_of(src: &str) -> Vec<String> {
        src.lines().map(|s| s.to_string()).collect()
    }

    const NARROW_TABLE: &str = "| a | b |\n|---|---|\n| 1 | 2 |";
    const WIDE_GLYPH_TABLE: &str =
        "| name | note |\n|------|------|\n| \u{65e5}\u{672c}\u{8a9e} | ok |\n| \u{1f389} | done |\n| plain | \u{2714}\u{fe0f} |";

    #[test]
    fn a_table_narrower_than_the_pane_still_owns_every_column() {
        let theme = crate::style::theme();
        for width in [40u16, 60, 80, 120] {
            for (i, l) in super::render_table(&rows_of(NARROW_TABLE), width, &theme)
                .iter()
                .enumerate()
            {
                assert_eq!(
                    line_cols(l),
                    width as usize,
                    "row {i} of a {width}-column region owns only {} columns — the \
                     unwritten tail is where a wider-than-declared glyph wraps and \
                     shears every row below it, permanently",
                    line_cols(l)
                );
            }
        }
    }

    #[test]
    fn a_table_of_wide_glyphs_owns_every_column() {
        let theme = crate::style::theme();
        for width in [30u16, 48, 80] {
            for (i, l) in super::render_table(&rows_of(WIDE_GLYPH_TABLE), width, &theme)
                .iter()
                .enumerate()
            {
                assert_eq!(
                    line_cols(l),
                    width as usize,
                    "row {i} of a {width}-column region owns {} columns",
                    line_cols(l)
                );
            }
        }
    }

    #[test]
    fn no_table_row_ever_exceeds_its_region() {
        let theme = crate::style::theme();
        for src in [NARROW_TABLE, WIDE_GLYPH_TABLE] {
            for width in 20u16..90 {
                for l in super::render_table(&rows_of(src), width, &theme) {
                    assert!(
                        line_cols(&l) <= width as usize,
                        "a row overhung its {width}-column region by {} columns",
                        line_cols(&l) - width as usize
                    );
                }
            }
        }
    }

    // ── The escape stripper that used to eat the rest of the string ──────────

    /// `strip_escapes` scanned forward from `\x1b` for a `\` and nothing else, so
    /// an SGR sequence (which contains no `\`) drained the iterator and DELETED
    /// the remainder of the string. Consumers are `visible_width` (sizes table
    /// columns) and `inline_plain` (produces rendered text).
    ///
    /// LATENT, not live: `render_markdown` scrubs `\x1b` via `render/sanitize.rs`
    /// before anything reaches here. Pinned anyway — the scrubber is a separate
    /// module and nothing enforces the ordering.
    #[test]
    fn an_sgr_sequence_does_not_swallow_the_rest_of_the_line() {
        let w = super::visible_width("a\x1b[0mbcdef");
        assert_eq!(
            w, 6,
            "an SGR sequence swallowed the tail: measured {w} columns instead of 6"
        );
    }

    #[test]
    fn a_bare_sgr_reset_leaves_the_following_text_intact() {
        assert_eq!(super::strip_escapes("keep\x1b[0mthis"), "keepthis");
    }

    #[test]
    fn an_osc8_hyperlink_still_measures_only_its_label() {
        let s = "\x1b]8;;https://example.com/very/long\x07click\x1b]8;;\x07";
        assert_eq!(super::visible_width(s), 5);
    }

    #[test]
    fn an_st_terminated_osc_still_measures_only_its_label() {
        let s = "\x1b]8;;https://example.com\x1b\\label\x1b]8;;\x1b\\";
        assert_eq!(super::visible_width(s), 5);
    }

    #[test]
    fn escape_stripping_leaves_plain_text_alone() {
        assert_eq!(super::visible_width("hello"), 5);
        assert_eq!(super::visible_width("\u{65e5}\u{672c}\u{8a9e}"), 6);
    }
}

#[cfg(test)]
mod wrap_across_inline_markup_tests {
    use super::render_markdown;
    use ratatui::style::Modifier;

    /// Every visible character of a render, per line, with OSC-8 wrappers gone.
    fn visible(src: &str, width: u16) -> Vec<String> {
        render_markdown(src, width)
            .lines
            .iter()
            .map(|l| {
                let joined: String = l.spans.iter().map(|s| s.content.as_ref()).collect();
                strip_osc8(&joined)
            })
            .collect()
    }

    fn strip_osc8(s: &str) -> String {
        let mut out = String::new();
        let mut chars = s.chars();
        while let Some(c) = chars.next() {
            if c == '\x1b' {
                for n in chars.by_ref() {
                    if n == '\\' {
                        break;
                    }
                }
            } else {
                out.push(c);
            }
        }
        out
    }

    /// True if any span anywhere in the render carries BOLD.
    fn has_bold(src: &str, width: u16) -> bool {
        render_markdown(src, width)
            .lines
            .iter()
            .any(|l| l.spans.iter().any(|s| s.style.add_modifier.contains(Modifier::BOLD)))
    }

    /// A bold phrase split by the wrap must still be bold, and its `**` markers
    /// must not survive as visible text.
    ///
    /// Wrapping BEFORE inline parsing is what broke this: `wrap_text` measures
    /// the RAW markdown, so the wrap lands inside `**bold phrase**` and each
    /// half is then handed to `parse_inline` on its own, where an unpaired `**`
    /// is (correctly) literal. Long streamed prose wraps constantly, so this
    /// fires on ordinary replies, not on a corner case.
    #[test]
    fn bold_split_by_a_wrap_stays_bold_and_drops_its_markers() {
        // 20 columns puts the wrap INSIDE the bold run (measured: the raw text
        // breaks as `jumped **over the` / `lazy dog** today`).
        let src = "the quick brown fox jumped **over the lazy dog** today\n";
        let lines = visible(src, 20);
        let joined = lines.join("\n");
        assert!(
            !joined.contains("**"),
            "literal ** survived the wrap:\n{joined}"
        );
        assert!(has_bold(src, 20), "no span kept BOLD across the wrap");
    }

    /// The same defect inside a list item, which is where replies put most of
    /// their emphasis.
    #[test]
    fn bold_split_by_a_wrap_inside_a_bullet_stays_bold() {
        let src = "- the quick brown fox jumped **over the lazy dog** today\n";
        let lines = visible(src, 20);
        let joined = lines.join("\n");
        assert!(!joined.contains("**"), "literal ** survived:\n{joined}");
        assert!(has_bold(src, 20), "no span kept BOLD across the wrap");
    }

    /// An inline link whose LABEL straddles the wrap. Before the fix the split
    /// half fell through `parse_inline`'s `plain.push('[')` path, so the second
    /// row read `label](https://…)` verbatim and no link span was emitted at
    /// all — the URL was shown to the user as prose.
    #[test]
    fn link_label_split_by_a_wrap_still_renders_as_one_label() {
        let src = "see the [very long link label here](https://example.com/x) for more\n";
        let lines = visible(src, 28);
        let joined = lines.join("\n");
        assert!(
            !joined.contains('[') && !joined.contains(']'),
            "a raw link bracket survived the wrap:\n{joined}"
        );
        // Every word of the label must carry the link style, on BOTH rows the
        // wrap produced. Before the fix the second row had no link span at all.
        use ratatui::style::Modifier;
        let labelled: Vec<String> = render_markdown(src, 28)
            .lines
            .iter()
            .map(|l| {
                l.spans
                    .iter()
                    .filter(|s| s.style.add_modifier.contains(Modifier::UNDERLINED))
                    .map(|s| strip_osc8(s.content.as_ref()))
                    .collect::<String>()
            })
            .collect();
        assert_eq!(
            labelled.join(" ").split_whitespace().collect::<Vec<_>>(),
            vec!["very", "long", "link", "label", "here"],
            "the link label did not survive the wrap as one styled label"
        );
    }

    /// Inline code split by a wrap must not leave backticks on screen.
    #[test]
    fn inline_code_split_by_a_wrap_drops_its_backticks() {
        let src = "run `cargo build --release --features everything` now\n";
        let lines = visible(src, 26);
        let joined = lines.join("\n");
        assert!(
            !joined.contains('`'),
            "a literal backtick survived the wrap:\n{joined}"
        );
    }

    /// The wrap must still respect the width once styling is applied — the
    /// styled text is SHORTER than the raw markdown, so a naive fix that wraps
    /// the raw text and strips markers afterwards would under-fill rows.
    #[test]
    fn wrapped_rows_never_exceed_the_width() {
        use unicode_width::UnicodeWidthStr;
        let src = "alpha **beta gamma** delta epsilon zeta eta theta iota kappa lambda mu\n";
        for width in [12u16, 20, 30, 44] {
            for line in visible(src, width) {
                assert!(
                    UnicodeWidthStr::width(line.as_str()) <= width as usize,
                    "row wider than {width}: {line:?}"
                );
            }
        }
    }
}


/// **Part A of `docs/design/tui-output-rendering.md`** — the blank-line policy,
/// the element inventory, and the table rules that were previously only
/// described.
///
/// These are the tests that stop the renderer from drifting back to a
/// per-block-pair spacing table, which is the failure the whole of §A.5 exists
/// to prevent: it looks right on the common case and wrong everywhere the model
/// asked for more or less air.
#[cfg(test)]
mod part_a {
    use super::render_markdown;
    use ratatui::style::Modifier;
    use unicode_width::UnicodeWidthStr;

    fn rows(src: &str, w: u16) -> Vec<String> {
        render_markdown(src, w)
            .lines
            .iter()
            .map(|l| {
                let raw: String = l.spans.iter().map(|s| s.content.as_ref()).collect();
                let mut out = String::new();
                let mut chars = raw.chars();
                while let Some(c) = chars.next() {
                    if c == '\x1b' {
                        for n in chars.by_ref() {
                            if n == '\\' {
                                break;
                            }
                        }
                    } else {
                        out.push(c);
                    }
                }
                out.trim_end().to_string()
            })
            .collect()
    }

    // ── §A.5 the blank-line policy ──────────────────────────────────────────

    /// `k` consecutive newlines produce `k − 1` blank rows, **uniformly**, for
    /// every pair of block types. No lookup table, no per-pair exceptions.
    #[test]
    fn k_newlines_produce_k_minus_one_blank_rows_for_every_block_pair() {
        let blocks = [
            "# Heading",
            "## Sub",
            "Paragraph text",
            "- bullet item",
            "1. numbered item",
            "> quoted line",
            "- [ ] a task",
        ];
        for a in blocks {
            for b in blocks {
                for k in 1usize..=4 {
                    let src = format!("{a}{}{b}", "\n".repeat(k));
                    let got = rows(&src, 60);
                    let blanks = got.iter().filter(|l| l.is_empty()).count();
                    assert_eq!(
                        blanks,
                        k - 1,
                        "{a:?} + {k} newlines + {b:?} produced {blanks} blank rows, want {}\n{got:#?}",
                        k - 1
                    );
                }
            }
        }
    }

    /// The specific regression: a heading must not manufacture air the model
    /// did not ask for. `# A\n# B\n# C` is three adjacent rows.
    #[test]
    fn adjacent_headings_stay_adjacent() {
        assert_eq!(rows("# A\n# B\n# C", 40), vec!["A", "B", "C"]);
        assert_eq!(rows("# Title\nBody", 40), vec!["Title", "Body"]);
        assert_eq!(rows("Setext\n======\nBody", 40), vec!["Setext", "Body"]);
    }

    /// §A.5 Modifier 3 — the ONE blank row the renderer manufactures: before an
    /// *opening* fence whose previous row has content. Erasing the fence line
    /// would otherwise collapse `1. Hello` straight onto the first row of code.
    /// It is not emitted before the *closing* fence, and not when the model
    /// already left a blank line.
    #[test]
    fn no_blank_row_is_ever_manufactured_around_a_fence() {
        // This used to assert the opposite — one synthetic blank before an
        // opening fence when the previous row was non-empty. That exception was
        // removed because it cannot survive a split render: OSA freezes a
        // prefix into scrollback and re-renders the tail, and a split landing
        // on the newline before a fence leaves the tail with no previous row,
        // so it skips the blank and the whole block moves up one line.
        //
        // The reported symptom was exactly that — expanding or resizing shifted
        // the transcript. §A.5's rule is uniform for a reason: a height that
        // depends on WHERE a render was split is unusable in a surface that
        // re-renders.
        assert_eq!(
            rows("1. Hello\n```\nx = 1\n```\nAfter", 40),
            vec!["1. Hello", "x = 1", "After"],
        );
        // The model's own blank line is still honoured, exactly once.
        assert_eq!(
            rows("Para\n\n```\nx = 1\n```\n\nAfter", 40),
            vec!["Para", "", "x = 1", "", "After"],
        );
        assert_eq!(rows("```\nx = 1\n```", 40), vec!["x = 1"]);
    }

    /// Blank rows *inside* a fence are part of the code and survive verbatim.
    #[test]
    fn blank_rows_inside_a_fence_survive() {
        let got = rows("```\na\n\nb\n```", 40);
        assert_eq!(got, vec!["a", "", "b"]);
    }

    // ── §A.1 element inventory ──────────────────────────────────────────────

    /// A markdown rule is three columns, not the pane width: a full-width rule
    /// inside a reply is indistinguishable from OSA's own turn separator.
    #[test]
    fn a_horizontal_rule_is_three_columns() {
        for w in [20u16, 60, 120] {
            assert_eq!(rows("a\n\n---\n\nb", w)[2], "───");
        }
    }

    /// One bullet glyph at every depth, and the model's own indentation.
    #[test]
    fn every_unordered_depth_uses_the_same_bullet_and_the_source_indent() {
        let got = rows("- top\n  - two space\n   - three space\n    - four space", 40);
        assert_eq!(
            got,
            vec!["• top", "  • two space", "   • three space", "    • four space"]
        );
    }

    /// A completed task is not struck through: models write checked items whose
    /// text is still the thing the reader needs.
    #[test]
    fn a_checked_task_is_not_struck_through() {
        let text = render_markdown("- [x] Ship the fix\n", 40);
        for line in &text.lines {
            for span in &line.spans {
                assert!(
                    !span.style.add_modifier.contains(Modifier::CROSSED_OUT),
                    "checked task span {:?} is struck through",
                    span.content
                );
            }
        }
    }

    /// Inline code is the code colour + BOLD, and is never *less* prominent
    /// than the prose around it.
    #[test]
    fn inline_code_is_bold() {
        let text = render_markdown("call `retry_after_ms` now", 40);
        let span = text.lines[0]
            .spans
            .iter()
            .find(|s| s.content.contains("retry_after_ms"))
            .expect("inline code span");
        assert!(span.style.add_modifier.contains(Modifier::BOLD), "{span:?}");
        assert!(!span.content.contains('`'), "backticks survived: {span:?}");
    }

    /// A fenced block paints a full-row background on EVERY row it owns —
    /// including its blank rows — so it reads as a block rather than as
    /// differently-coloured prose. Rows are padded to the pane width for the
    /// background to have anything to paint on.
    #[test]
    fn a_code_block_owns_every_column_of_every_row() {
        let has_bg = crate::style::theme().code_block().bg.is_some();
        let text = render_markdown("before\n\n```rust\nfn a() {}\n\nfn b() {}\n```\n\nafter", 40);
        // Rows 2..=4 are the fence body ("before", "", code, "", code, "",
        // "after" once Modifier 3 and the model's own blanks are applied).
        let body: Vec<_> = text
            .lines
            .iter()
            .filter(|l| {
                let flat: String = l.spans.iter().map(|s| s.content.as_ref()).collect();
                flat.contains("fn a()") || flat.contains("fn b()")
            })
            .collect();
        assert_eq!(body.len(), 2, "both code rows must be present");
        for l in &body {
            let w: usize = l.spans.iter().map(|s| crate::util::cols(&s.content)).sum();
            assert_eq!(w, 40, "code row does not own its full width: {l:?}");
            assert_eq!(l.style.bg.is_some(), has_bg, "code row background: {l:?}");
        }
        if has_bg {
            // Including the blank row BETWEEN them — the whole block is painted.
            let painted = text.lines.iter().filter(|l| l.style.bg.is_some()).count();
            assert_eq!(painted, 3, "the blank row inside the fence lost its background");
            // Prose rows are untouched.
            assert!(text.lines.iter().filter(|l| l.style.bg.is_none()).count() >= 4);
        }
    }

    /// The info string resolves by its FIRST word, so ```` ```rust ignore ````
    /// still highlights instead of silently falling back to plain text.
    #[test]
    fn the_info_string_resolves_by_its_first_word() {
        let tagged = render_markdown("```rust ignore\nfn main() {}\n```", 40);
        let bare = render_markdown("```rust\nfn main() {}\n```", 40);
        let styles = |t: &ratatui::text::Text<'_>| {
            t.lines
                .iter()
                .flat_map(|l| l.spans.iter().map(|s| (s.content.to_string(), s.style)))
                .collect::<Vec<_>>()
        };
        assert_eq!(styles(&tagged), styles(&bare));
    }

    // ── §A.2 tables ─────────────────────────────────────────────────────────

    /// Inline styling survives a cell WRAP. Before this, any cell that did not
    /// fit on one line was re-rendered as markup-stripped plain text and lost
    /// its bold, its code colour and its link — which in a narrow table is most
    /// cells.
    #[test]
    fn a_wrapped_cell_keeps_its_inline_styling() {
        let src = "| Col | Note |\n|---|---|\n| a | **emphasised text** that must wrap over rows |\n";
        let text = render_markdown(src, 34);
        let bold: Vec<String> = text
            .lines
            .iter()
            .flat_map(|l| l.spans.iter())
            .filter(|s| s.style.add_modifier.contains(Modifier::BOLD))
            .map(|s| s.content.to_string())
            .collect();
        let joined = bold.join(" ");
        assert!(
            joined.contains("emphasised") && joined.contains("text"),
            "the wrapped cell lost its bold: {bold:?}"
        );
        // …and the markers are gone, not rendered literally.
        for line in &text.lines {
            let flat: String = line.spans.iter().map(|s| s.content.as_ref()).collect();
            assert!(!flat.contains("**"), "literal markers in {flat:?}");
        }
    }

    /// A repeated substring must not leak styling onto its plain twin — the
    /// classic failure of a find-the-substring span mapper.
    #[test]
    fn a_repeated_substring_does_not_leak_styling() {
        let src = "| H |\n|---|\n| `aa` then aa then more words to force a wrap here |\n";
        let text = render_markdown(src, 26);
        let plain_runs: Vec<&str> = text
            .lines
            .iter()
            .flat_map(|l| l.spans.iter())
            .filter(|s| !s.style.add_modifier.contains(Modifier::BOLD))
            .map(|s| s.content.as_ref())
            .collect();
        assert!(
            plain_runs.iter().any(|s| s.contains("aa")),
            "the plain `aa` was styled as code too: {plain_runs:?}"
        );
    }

    /// The cell word separator: punctuation is a break opportunity, number
    /// formatting is not.
    #[test]
    fn cell_break_points_split_paths_but_not_numbers() {
        fn split(s: &str) -> Vec<&str> {
            let mut out = Vec::new();
            let mut prev = 0;
            for b in super::cell_break_points(s).into_iter().chain([s.len()]) {
                out.push(&s[prev..b]);
                prev = b;
            }
            out
        }
        assert_eq!(split("foo/bar"), vec!["foo/", "bar"]);
        assert_eq!(split("ABCD-EFG"), vec!["ABCD", "-EFG"]);
        assert_eq!(split("$145,000"), vec!["$145,000"]);
        assert_eq!(split("3.14"), vec!["3.14"]);
        assert_eq!(split("1.0.2"), vec!["1.0.2"]);
        assert_eq!(split("EMP-1001"), vec!["EMP-1001"]);
        assert_eq!(split("555-0101"), vec!["555-", "0101"]);
        // URLs are protected so click-to-open survives a wrap.
        assert_eq!(split("https://osa.dev/a/b"), vec!["https://osa.dev/a/b"]);
    }

    /// Every row of a table is exactly the same total display width, at every
    /// width, for content that stresses the wrapper. This is the invariant a
    /// mis-measured cell breaks, and it is permanent once the row reaches
    /// native scrollback.
    #[test]
    fn every_table_row_is_exactly_as_wide_as_every_other() {
        let srcs = [
            "| Path | Note |\n|---|---|\n| src/render/markdown.rs | wraps inside the identifier |\n| 2019-03-15 | $145,000 and 3.14 stay whole |\n",
            "| A | B | C |\n|---|---|---|\n| 模型模型模型 | ｶﾞｶﾞ | 日本語のテキスト |\n",
        ];
        for src in srcs {
            for w in 1u16..=120 {
                let got = rows(src, w);
                let grid: Vec<&String> = got
                    .iter()
                    .filter(|l| l.starts_with(['┌', '├', '└', '│']))
                    .collect();
                if grid.is_empty() {
                    continue;
                }
                let first = UnicodeWidthStr::width(grid[0].as_str());
                for l in &grid {
                    assert_eq!(
                        UnicodeWidthStr::width(l.as_str()),
                        first,
                        "w={w}: ragged row {l:?}\n{}",
                        got.join("\n")
                    );
                    assert!(
                        UnicodeWidthStr::width(l.as_str()) <= w as usize,
                        "w={w}: row {l:?} overflows the pane"
                    );
                }
            }
        }
    }
}

// ── the synthetic blank must not depend on WHERE a render was split ─────────
//
// Reported symptom: expanding/resizing shifts the transcript and "adds spaces".
// Modifier 3 manufactures one blank row before an opening fence, conditional on
// the previous row being non-empty. If a prefix render ends just before a
// fence, the tail render sees NO previous row and skips the blank — so
// prefix ++ tail has one row fewer than the one-shot render of the same text,
// and every row below it moves.
#[cfg(test)]
mod split_stability {
    use super::*;

    fn rows(s: &str, w: u16) -> usize {
        render_markdown(s, w).lines.len()
    }

    fn split_rows(s: &str, at: usize, w: u16) -> usize {
        let (a, b) = s.split_at(at);
        render_markdown(a, w).lines.len() + render_markdown(b, w).lines.len()
    }

    #[test]
    fn a_fence_renders_the_same_height_however_the_text_is_split() {
        // Deliberately WITHOUT a blank line before the fence — that is the case
        // Modifier 3 exists for, and the case where the condition can differ.
        let doc = "Some prose about the fix.\n```rust\nfn main() {}\n```\nAfter.";
        let whole = rows(doc, 80);

        // Line boundaries only — that is where the streaming renderer actually
        // freezes a prefix. A mid-word split is not a case OSA produces.
        let mut at = 0usize;
        for line in doc.split_inclusive('\n') {
            at += line.len();
            if at == 0 || at >= doc.len() {
                continue;
            }
            let split = split_rows(doc, at, 80);
            assert_eq!(
                split, whole,
                "splitting at byte {at} changes height {whole} -> {split}; \
                 the transcript would shift by {} row(s) when re-rendered",
                split as i64 - whole as i64
            );
        }
    }
}
