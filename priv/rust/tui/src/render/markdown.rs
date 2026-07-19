use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span, Text};
use unicode_segmentation::UnicodeSegmentation;
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

/// Convert a Markdown string to a ratatui [`Text`] value.
///
/// Supported constructs:
///   - Headers  `# H1` … `###### H6`  — styled per level
///   - Fenced code blocks  ` ``` [lang] ` … ` ``` ` — syntax-highlighted via [`crate::render::syntax`]
///   - Inline code `` `expr` `` — dim style
///   - **Bold**  `**text**`
///   - *Italic*  `*text*`
///   - `~~text~~` — passes through literally (strikethrough deliberately
///     disabled, CC parity: models write `~~100ms~~` meaning "approximately")
///   - Task checkboxes  `- [ ] todo` / `- [x] done` — green checkmark or muted circle
///   - Unordered lists  `- item` / `* item` / `+ item` — nested with indent-aware bullets
///   - Ordered lists    `1. item` — depth-styled markers (1. / a. / i.)
///   - Links  `[text](url)` — text in cyan+underline followed by the URL in dim parens
///   - Blockquotes  `> text` — muted italic with `│ ` prefix
///   - Horizontal rules  `---` / `***` — full-width `─`
///   - GFM pipe tables  `| H1 | H2 |` — styled with box-drawing borders
///   - Plain text — unstyled
pub fn render_markdown(input: &str, width: u16) -> Text<'static> {
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
                in_code_block = true;
                let rest = raw_line.trim_start().trim_start_matches('`').trim();
                code_lang = rest.to_owned();
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
                lines.push(Line::from(Span::raw("")));
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
            lines.push(Line::from(Span::raw(""))); // breathing room after h2
            continue;
        }
        if raw_line.starts_with("# ") {
            let text = &raw_line[2..];
            let style = Style::default()
                .fg(theme.colors.primary)
                .add_modifier(Modifier::BOLD | Modifier::UNDERLINED);
            push_heading_raw(&mut lines, text, width, style);
            lines.push(Line::from(Span::raw("")));
            continue;
        }

        // ── Horizontal rules ─────────────────────────────────────────────────
        let trimmed = raw_line.trim();
        if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            flush_para!();
            let rule = "─".repeat(width.saturating_sub(2) as usize);
            lines.push(Line::from(Span::styled(rule, theme.faint())));
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
            let indent = raw_line.len() - raw_line.trim_start().len();
            let indent_level = indent / 2;
            let indent_str = "  ".repeat(indent_level);

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
            let text_style = if checked {
                theme.faint().add_modifier(Modifier::CROSSED_OUT)
            } else {
                Style::default()
            };
            // Hanging-indent wrap: marker on the first line, blank padding of the
            // same display width on continuation lines, so a long checkbox item
            // wraps instead of clipping at the pane edge.
            let prefix_width = UnicodeWidthStr::width(icon_str.as_str());
            let wrap_width = (width as usize).saturating_sub(prefix_width);
            for (i, wline) in wrap_text(text, wrap_width).iter().enumerate() {
                let mut spans = Vec::new();
                if i == 0 {
                    spans.push(Span::styled(icon_str.clone(), icon_style));
                } else {
                    spans.push(Span::styled(" ".repeat(prefix_width), Style::default()));
                }
                for s in parse_inline(wline, &theme) {
                    spans.push(Span::styled(s.content, text_style));
                }
                lines.push(Line::from(spans));
            }
            continue;
        }

        // ── Unordered lists (indent-aware, word-wrapped) ─────────────────────
        if trimmed.starts_with("- ") || trimmed.starts_with("* ") || trimmed.starts_with("+ ") {
            flush_para!();
            let text = &trimmed[2..];
            let indent = raw_line.len() - raw_line.trim_start().len();
            let indent_level = indent / 2;
            let indent_str = "  ".repeat(indent_level);
            let bullet = match indent_level {
                0 => "• ",
                1 => "◦ ",
                _ => "▪ ",
            };
            let prefix = format!("{}{}", indent_str, bullet);
            let prefix_len = prefix.len();
            let wrap_width = (width as usize).saturating_sub(prefix_len);
            let wrapped = wrap_text(text, wrap_width);
            for (i, wline) in wrapped.iter().enumerate() {
                let mut spans = vec![];
                if i == 0 {
                    spans.push(Span::styled(prefix.clone(), Style::default().fg(theme.colors.muted)));
                } else {
                    // Continuation lines get same indent
                    spans.push(Span::styled(" ".repeat(prefix_len), Style::default()));
                }
                spans.extend(parse_inline(wline, &theme));
                lines.push(Line::from(spans));
            }
            continue;
        }

        // ── Ordered lists (indent-aware, depth-styled markers) ───────────────
        if let Some(pos) = trimmed.find(". ") {
            let num_part = &trimmed[..pos];
            if !num_part.is_empty() && num_part.chars().all(|c| c.is_ascii_digit()) {
                flush_para!();
                let text = &trimmed[pos + 2..];
                let indent = raw_line.len() - raw_line.trim_start().len();
                let indent_level = indent / 2;
                let indent_str = "  ".repeat(indent_level);
                let marker = match num_part.parse::<usize>() {
                    Ok(n) => format_list_number(n, indent_level),
                    Err(_) => format!("{}.", num_part),
                };
                // Hanging-indent wrap, mirroring the unordered-list branch: the
                // numbered marker on the first line, blank padding of the same
                // width on continuation lines. Without this a long numbered item
                // clipped at the pane edge and its tail was silently lost.
                let prefix = format!("{}{} ", indent_str, marker);
                let prefix_len = prefix.len();
                let wrap_width = (width as usize).saturating_sub(prefix_len);
                for (i, wline) in wrap_text(text, wrap_width).iter().enumerate() {
                    let mut spans = Vec::new();
                    if i == 0 {
                        spans.push(Span::styled(prefix.clone(), Style::default().fg(theme.colors.muted)));
                    } else {
                        spans.push(Span::styled(" ".repeat(prefix_len), Style::default()));
                    }
                    spans.extend(parse_inline(wline, &theme));
                    lines.push(Line::from(spans));
                }
                continue;
            }
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
fn push_code_lines(out: &mut Vec<Line<'static>>, highlighted: Vec<Line<'static>>, width: u16) {
    let max_w = (width as usize).max(1);
    for line in highlighted {
        let total: usize = line
            .spans
            .iter()
            .map(|s| UnicodeWidthStr::width(s.content.as_ref()))
            .sum();
        if total <= max_w {
            out.push(line);
            continue;
        }
        let parts: Vec<(String, Style)> = line
            .spans
            .iter()
            .map(|s| (s.content.to_string(), s.style))
            .collect();
        for row in crate::render::diff::wrap_styled(parts, max_w) {
            out.push(Line::from(
                row.into_iter()
                    .map(|(t, st)| Span::styled(t, st))
                    .collect::<Vec<_>>(),
            ));
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
        for wline in wrap_text(&seg, width as usize) {
            out.push(Line::from(parse_inline(&wline, theme)));
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
    for wline in wrap_text(text, (width as usize).max(1)) {
        let spans: Vec<Span<'static>> = parse_inline(&wline, theme)
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

    let num_cols = parsed[0].len();

    // Calculate column widths from each cell's VISIBLE width after inline
    // markdown markup is stripped (so `**bold**` measures as `bold`), min 3.
    let mut col_widths: Vec<usize> = vec![3; num_cols];
    for row in &parsed {
        for (i, cell) in row.iter().enumerate() {
            if i < num_cols {
                col_widths[i] = col_widths[i].max(inline_visible_width(cell, theme));
            }
        }
    }

    // Cap total width to available width
    let total = col_widths.iter().sum::<usize>() + (num_cols + 1) + (num_cols.saturating_sub(1)) * 3;
    if total > width as usize && width > 10 {
        let max_per_col = (width as usize).saturating_sub(num_cols + 1) / num_cols.max(1);
        for w in col_widths.iter_mut() {
            *w = (*w).min(max_per_col).max(3);
        }
    }

    let muted = theme.faint();

    // Render header row (first row, bold + primary)
    if let Some(header) = parsed.first() {
        let mut spans = Vec::new();
        spans.push(Span::styled("│ ".to_string(), muted));
        let header_base = Style::default()
            .fg(theme.colors.primary)
            .add_modifier(Modifier::BOLD);
        for (i, cell) in header.iter().enumerate() {
            let w = col_widths.get(i).copied().unwrap_or(10);
            let align = alignments.get(i).copied().unwrap_or(ColAlign::Left);
            spans.extend(fit_cell_spans(cell, w, align, header_base, theme));
            if i < header.len() - 1 {
                spans.push(Span::styled(" │ ".to_string(), muted));
            }
        }
        spans.push(Span::styled(" │".to_string(), muted));
        result.push(Line::from(spans));
    }

    // Render separator line
    {
        let mut sep = String::from("├─");
        for (i, w) in col_widths.iter().enumerate() {
            sep.push_str(&"─".repeat(*w));
            if i < col_widths.len() - 1 {
                sep.push_str("─┼─");
            }
        }
        sep.push_str("─┤");
        result.push(Line::from(Span::styled(sep, muted)));
    }

    // Render data rows (skip header)
    for row in parsed.iter().skip(1) {
        let mut spans = Vec::new();
        spans.push(Span::styled("│ ".to_string(), muted));
        for (i, cell) in row.iter().enumerate() {
            let w = col_widths.get(i).copied().unwrap_or(10);
            let align = alignments.get(i).copied().unwrap_or(ColAlign::Left);
            spans.extend(fit_cell_spans(cell, w, align, Style::default(), theme));
            if i < row.len() - 1 {
                spans.push(Span::styled(" │ ".to_string(), muted));
            }
        }
        spans.push(Span::styled(" │".to_string(), muted));
        result.push(Line::from(spans));
    }

    result
}

/// GFM column alignment parsed from the table separator row.
#[derive(Clone, Copy, PartialEq)]
enum ColAlign {
    Left,
    Center,
    Right,
}

/// Render a table cell's INLINE markdown (bold / code / links) as styled spans,
/// padded (or truncated with `…`) to exactly `w` display columns per the column
/// alignment. `base` is the cell's default style, under which each inline span's
/// own style is patched (so header bold + a code cell both apply).
///
/// When the styled content fits, full inline styling is preserved. In the rare
/// capped-width overflow case the cell degrades to plain truncated text — inline
/// styling is dropped there rather than mis-measuring escape-laden spans.
fn fit_cell_spans(
    cell: &str,
    w: usize,
    align: ColAlign,
    base: Style,
    theme: &crate::style::Theme,
) -> Vec<Span<'static>> {
    let styled: Vec<Span<'static>> = parse_inline(cell, theme)
        .into_iter()
        .map(|s| Span::styled(s.content, base.patch(s.style)))
        .collect();
    let total: usize = styled.iter().map(|s| visible_width(s.content.as_ref())).sum();

    if total <= w {
        let pad = w - total;
        let (left, right) = match align {
            ColAlign::Left => (0, pad),
            ColAlign::Right => (pad, 0),
            ColAlign::Center => (pad / 2, pad - pad / 2),
        };
        let mut out: Vec<Span<'static>> = Vec::with_capacity(styled.len() + 2);
        if left > 0 {
            out.push(Span::styled(" ".repeat(left), base));
        }
        out.extend(styled);
        if right > 0 {
            out.push(Span::styled(" ".repeat(right), base));
        }
        return out;
    }

    // Overflow: grapheme-truncate the plain (markup-stripped) text.
    let plain: String = styled.iter().map(|s| strip_escapes(s.content.as_ref())).collect();
    let mut out = String::new();
    let mut used = 0;
    for g in UnicodeSegmentation::graphemes(plain.as_str(), true) {
        let gw = UnicodeWidthStr::width(g);
        if used + gw > w.saturating_sub(1) {
            break;
        }
        out.push_str(g);
        used += gw;
    }
    out.push('…');
    let final_w = UnicodeWidthStr::width(out.as_str());
    if final_w < w {
        out.push_str(&" ".repeat(w - final_w));
    }
    vec![Span::styled(out, base)]
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
    let mut w = 0;
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c == '\x1b' {
            for n in chars.by_ref() {
                if n == '\\' {
                    break;
                }
            }
        } else {
            w += UnicodeWidthChar::width(c).unwrap_or(0);
        }
    }
    w
}

/// Strip OSC-8 escape wrappers (`ESC … ST`) from `s`, leaving visible text.
fn strip_escapes(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
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

/// Depth-styled ordered-list markers (CC `getListNumber` parity):
/// depth 0-1 → `1.`, depth 2 → `a.`, depth 3+ → `i.` (lowercase roman).
fn format_list_number(n: usize, depth: usize) -> String {
    match depth {
        0 | 1 => format!("{}.", n),
        2 => format!("{}.", number_to_letter(n)),
        _ => format!("{}.", number_to_roman(n)),
    }
}

fn number_to_letter(n: usize) -> String {
    // 1→a … 26→z, 27→aa (spreadsheet-style)
    let mut n = n.max(1);
    let mut s = String::new();
    while n > 0 {
        let rem = ((n - 1) % 26) as u8;
        s.insert(0, (b'a' + rem) as char);
        n = (n - 1) / 26;
    }
    s
}

fn number_to_roman(n: usize) -> String {
    if n == 0 || n > 3999 {
        return n.to_string();
    }
    const VALS: [(usize, &str); 13] = [
        (1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"),
        (90, "xc"), (50, "l"), (40, "xl"), (10, "x"), (9, "ix"),
        (5, "v"), (4, "iv"), (1, "i"),
    ];
    let mut n = n;
    let mut s = String::new();
    for (v, sym) in VALS {
        while n >= v {
            s.push_str(sym);
            n -= v;
        }
    }
    s
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
fn wrap_text(input: &str, max_width: usize) -> Vec<String> {
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
                    let style = Style::default().fg(theme.colors.muted);
                    spans.push(Span::styled(code, style));
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

            // ── `~` is always literal ─────────────────────────────────────
            // Strikethrough is deliberately disabled (CC parity, marked's
            // del() override): models write `~~100ms~~` meaning
            // "approximately", so CROSSED_OUT rendering corrupts the reply.
            '~' => {
                chars.next();
                plain.push('~');
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
                    for c in chars.by_ref() {
                        if c == ')' {
                            break;
                        }
                        url.push(c);
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
        expand_tabs, format_list_number, is_setext_underline, next_bare_url, parse_chip_index,
        parse_inline, parse_quote_depth, render_markdown, trim_url_trailing, wrap_text,
    };
    use ratatui::style::Modifier;

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

    #[test]
    fn strikethrough_is_disabled_and_renders_literally() {
        let theme = crate::style::theme();
        let spans = parse_inline("~~100ms~~", &theme);
        assert_eq!(flat(&spans), "~~100ms~~");
        assert!(spans.iter().all(|s| !s
            .style
            .add_modifier
            .contains(ratatui::style::Modifier::CROSSED_OUT)));
    }

    #[test]
    fn link_url_is_visible() {
        let theme = crate::style::theme();
        let spans = parse_inline("[docs](https://osa.dev)", &theme);
        assert_eq!(flat(&spans), "docs (https://osa.dev)");
    }

    #[test]
    fn mailto_is_stripped_and_deduped() {
        let theme = crate::style::theme();
        let spans = parse_inline("[a@b.co](mailto:a@b.co)", &theme);
        assert_eq!(flat(&spans), "a@b.co");
    }

    #[test]
    fn ordered_list_depth_markers() {
        assert_eq!(format_list_number(2, 0), "2.");
        assert_eq!(format_list_number(2, 2), "b.");
        assert_eq!(format_list_number(4, 3), "iv.");
        assert_eq!(format_list_number(27, 2), "aa.");
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
        let data_row: String = lines[2].spans.iter().map(|s| s.content.as_ref()).collect();
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
}
