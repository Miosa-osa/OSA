use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span, Text};

/// Convert a Markdown string to a ratatui [`Text`] value.
///
/// Supported constructs:
///   - Headers  `# H1` … `###### H6`  — styled per level
///   - Fenced code blocks  ` ``` [lang] ` … ` ``` ` — syntax-highlighted via [`crate::render::syntax`]
///   - Inline code `` `expr` `` — dim style
///   - **Bold**  `**text**`
///   - *Italic*  `*text*`
///   - ~~Strikethrough~~ `~~text~~`
///   - Task checkboxes  `- [ ] todo` / `- [x] done` — green checkmark or muted circle
///   - Unordered lists  `- item` / `* item` / `+ item` — nested with indent-aware bullets
///   - Ordered lists    `1. item` — nested with indentation
///   - Links  `[text](url)` — text in cyan+underline, URL dropped
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

    for raw_line in input.lines() {
        // ── Fenced code block boundary ──────────────────────────────────────
        if raw_line.trim_start().starts_with("```") {
            if in_code_block {
                // Closing fence: flush accumulated code.
                in_code_block = false;
                let code = code_lines.join("\n");
                let highlighted = crate::render::syntax::highlight(&code, &code_lang);
                lines.extend(highlighted);
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

        // ── GFM pipe tables ─────────────────────────────────────────────────
        let trimmed_for_table = raw_line.trim();
        let is_table_line = trimmed_for_table.starts_with('|') && trimmed_for_table.ends_with('|');
        let is_separator_line =
            trimmed_for_table.starts_with('|') && trimmed_for_table.contains("---");

        if is_table_line || is_separator_line {
            if !in_table {
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

        // ── Headers ─────────────────────────────────────────────────────────
        if raw_line.starts_with("###### ") {
            let text = &raw_line[7..];
            let spans = parse_inline(text, &theme);
            let styled_spans: Vec<Span> = spans
                .into_iter()
                .map(|s| {
                    Span::styled(
                        s.content,
                        Style::default()
                            .fg(theme.colors.muted)
                            .add_modifier(Modifier::ITALIC),
                    )
                })
                .collect();
            lines.push(Line::from(styled_spans));
            continue;
        }
        if raw_line.starts_with("##### ") {
            let text = &raw_line[6..];
            let spans = parse_inline(text, &theme);
            let styled_spans: Vec<Span> = spans
                .into_iter()
                .map(|s| Span::styled(s.content, Style::default().fg(theme.colors.muted)))
                .collect();
            lines.push(Line::from(styled_spans));
            continue;
        }
        if raw_line.starts_with("#### ") {
            let text = &raw_line[5..];
            let spans = parse_inline(text, &theme);
            let styled_spans: Vec<Span> = spans
                .into_iter()
                .map(|s| {
                    Span::styled(
                        s.content,
                        Style::default()
                            .fg(theme.colors.secondary)
                            .add_modifier(Modifier::BOLD),
                    )
                })
                .collect();
            lines.push(Line::from(styled_spans));
            continue;
        }
        if raw_line.starts_with("### ") {
            let text = raw_line[4..].to_owned();
            let style = Style::default()
                .fg(theme.colors.primary)
                .add_modifier(Modifier::BOLD);
            lines.push(Line::from(Span::styled(text, style)));
            continue;
        }
        if raw_line.starts_with("## ") {
            let text = raw_line[3..].to_owned();
            let style = Style::default()
                .fg(theme.colors.primary)
                .add_modifier(Modifier::BOLD);
            lines.push(Line::from(Span::styled(text, style)));
            lines.push(Line::from(Span::raw(""))); // breathing room after h2
            continue;
        }
        if raw_line.starts_with("# ") {
            let text = raw_line[2..].to_owned();
            let style = Style::default()
                .fg(theme.colors.primary)
                .add_modifier(Modifier::BOLD | Modifier::UNDERLINED);
            lines.push(Line::from(Span::styled(text, style)));
            lines.push(Line::from(Span::raw("")));
            continue;
        }

        // ── Horizontal rules ─────────────────────────────────────────────────
        let trimmed = raw_line.trim();
        if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            let rule = "─".repeat(width.saturating_sub(2) as usize);
            lines.push(Line::from(Span::styled(rule, theme.faint())));
            continue;
        }

        // ── Blockquotes (word-wrapped) ────────────────────────────────────────
        if raw_line.starts_with("> ") {
            let content = &raw_line[2..];
            let style = Style::default()
                .fg(theme.colors.muted)
                .add_modifier(Modifier::ITALIC);
            let wrapped = wrap_text(content, width.saturating_sub(4) as usize);
            for wline in wrapped {
                let border = Span::styled("│ ".to_owned(), Style::default().fg(theme.colors.dim));
                let text_span = Span::styled(wline, style);
                lines.push(Line::from(vec![border, text_span]));
            }
            continue;
        }

        // ── Task checkboxes ──────────────────────────────────────────────────
        if let Some((checked, text)) = detect_checkbox(trimmed) {
            let indent = raw_line.len() - raw_line.trim_start().len();
            let indent_level = indent / 2;
            let indent_str = "  ".repeat(indent_level);

            let icon = if checked {
                Span::styled(
                    format!("{}✓ ", indent_str),
                    Style::default().fg(Color::Green),
                )
            } else {
                Span::styled(format!("{}○ ", indent_str), theme.faint())
            };

            let mut spans = vec![icon];
            let text_style = if checked {
                theme.faint().add_modifier(Modifier::CROSSED_OUT)
            } else {
                Style::default()
            };
            let inline_spans = parse_inline(text, &theme);
            for s in inline_spans {
                spans.push(Span::styled(s.content, text_style));
            }
            lines.push(Line::from(spans));
            continue;
        }

        // ── Unordered lists (indent-aware, word-wrapped) ─────────────────────
        if trimmed.starts_with("- ") || trimmed.starts_with("* ") || trimmed.starts_with("+ ") {
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
                    spans.push(Span::styled(
                        prefix.clone(),
                        Style::default().fg(theme.colors.muted),
                    ));
                } else {
                    // Continuation lines get same indent
                    spans.push(Span::styled(" ".repeat(prefix_len), Style::default()));
                }
                spans.extend(parse_inline(wline, &theme));
                lines.push(Line::from(spans));
            }
            continue;
        }

        // ── Ordered lists (indent-aware) ─────────────────────────────────────
        if let Some(pos) = trimmed.find(". ") {
            let num_part = &trimmed[..pos];
            if !num_part.is_empty() && num_part.chars().all(|c| c.is_ascii_digit()) {
                let text = &trimmed[pos + 2..];
                let indent = raw_line.len() - raw_line.trim_start().len();
                let indent_level = indent / 2;
                let indent_str = "  ".repeat(indent_level);
                let mut spans = vec![Span::styled(
                    format!("{}{}. ", indent_str, num_part),
                    Style::default().fg(theme.colors.muted),
                )];
                spans.extend(parse_inline(text, &theme));
                lines.push(Line::from(spans));
                continue;
            }
        }

        // ── Empty lines ───────────────────────────────────────────────────────
        if raw_line.trim().is_empty() {
            lines.push(Line::from(Span::raw("")));
            continue;
        }

        // ── Plain paragraph / inline formatting (word-wrapped) ─────────────────
        let wrapped = wrap_text(raw_line, width as usize);
        for wline in wrapped {
            let spans = parse_inline(&wline, &theme);
            lines.push(Line::from(spans));
        }
    }

    // If we hit EOF still inside a code block, flush what we have.
    if in_code_block && !code_lines.is_empty() {
        let code = code_lines.join("\n");
        let highlighted = crate::render::syntax::highlight(&code, &code_lang);
        lines.extend(highlighted);
    }

    // If we hit EOF still inside a table, flush what we have.
    if in_table {
        let table_lines = render_table(&table_buf, width, &theme);
        lines.extend(table_lines);
    }

    Text::from(lines)
}

// ─── GFM pipe table renderer ─────────────────────────────────────────────────

/// Render a GFM pipe table as styled [`Line`]s with box-drawing borders.
fn render_table(rows: &[String], width: u16, theme: &crate::style::Theme) -> Vec<Line<'static>> {
    if rows.is_empty() {
        return vec![];
    }

    let mut result = Vec::new();

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

    // Calculate column widths (max content per column)
    let mut col_widths: Vec<usize> = vec![0; num_cols];
    for row in &parsed {
        for (i, cell) in row.iter().enumerate() {
            if i < num_cols {
                col_widths[i] = col_widths[i].max(cell.len());
            }
        }
    }

    // Cap total width to available width
    let total =
        col_widths.iter().sum::<usize>() + (num_cols + 1) + (num_cols.saturating_sub(1)) * 3;
    if total > width as usize && width > 10 {
        let max_per_col = (width as usize).saturating_sub(num_cols + 1) / num_cols.max(1);
        for w in col_widths.iter_mut() {
            *w = (*w).min(max_per_col);
        }
    }

    let muted = theme.faint();

    // Render header row (first row, bold + primary)
    if let Some(header) = parsed.first() {
        let mut spans = Vec::new();
        spans.push(Span::styled("│ ".to_string(), muted));
        for (i, cell) in header.iter().enumerate() {
            let w = col_widths.get(i).copied().unwrap_or(10);
            let padded = format!("{:<width$}", cell, width = w);
            spans.push(Span::styled(
                padded,
                Style::default()
                    .fg(theme.colors.primary)
                    .add_modifier(Modifier::BOLD),
            ));
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
            let padded = format!("{:<width$}", cell, width = w);
            spans.push(Span::styled(padded, Style::default()));
            if i < row.len() - 1 {
                spans.push(Span::styled(" │ ".to_string(), muted));
            }
        }
        spans.push(Span::styled(" │".to_string(), muted));
        result.push(Line::from(spans));
    }

    result
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
    if max_width == 0 || input.len() <= max_width {
        return vec![input.to_string()];
    }

    let mut result: Vec<String> = Vec::new();
    let mut current = String::new();
    let mut col = 0;

    for word in input.split_inclusive(' ') {
        let word_len = word.len();
        if col + word_len > max_width && col > 0 {
            result.push(current.trim_end().to_string());
            current = String::new();
            col = 0;
        }
        // Force-break words longer than max_width
        if word_len > max_width && col == 0 {
            let mut remaining = word;
            while remaining.len() > max_width {
                let (chunk, rest) = remaining.split_at(max_width);
                result.push(chunk.to_string());
                remaining = rest;
            }
            current.push_str(remaining);
            col = remaining.len();
        } else {
            current.push_str(word);
            col += word_len;
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

    // Helper to flush the accumulated plain buffer.
    macro_rules! flush_plain {
        () => {
            if !plain.is_empty() {
                spans.push(Span::raw(plain.clone()));
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

            // ── Bold / Italic: ** or * ────────────────────────────────────
            '*' => {
                chars.next(); // consume first `*`
                if chars.peek() == Some(&'*') {
                    // Possible **bold**
                    chars.next(); // consume second `*`
                    let mut content = String::new();
                    let mut closed = false;
                    // Collect until closing `**`. Use `while let` so that the
                    // mutable borrow from `.next()` is released between
                    // iterations, allowing `.peek()` on the next iteration.
                    while let Some(&nc) = chars.peek() {
                        if nc == '*' {
                            chars.next(); // consume this `*`
                                          // Check the character after it.
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
                        // Not a valid bold span — emit literally.
                        plain.push_str("**");
                        plain.push_str(&content);
                    }
                } else {
                    // Possible *italic*
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

            // ── Strikethrough: ~~text~~ ───────────────────────────────────
            '~' => {
                chars.next(); // consume first `~`
                if chars.peek() == Some(&'~') {
                    chars.next(); // consume second `~`
                    let mut content = String::new();
                    let mut closed = false;
                    while let Some(&nc) = chars.peek() {
                        if nc == '~' {
                            chars.next(); // consume this `~`
                            if chars.peek() == Some(&'~') {
                                chars.next(); // consume second closing `~`
                                closed = true;
                                break;
                            }
                            content.push('~');
                        } else {
                            chars.next();
                            content.push(nc);
                        }
                    }
                    if closed && !content.is_empty() {
                        flush_plain!();
                        let style = Style::default().add_modifier(Modifier::CROSSED_OUT);
                        spans.push(Span::styled(content, style));
                    } else {
                        plain.push_str("~~");
                        plain.push_str(&content);
                    }
                } else {
                    // Single `~` — treat as literal.
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
                    let mut _url = String::new();
                    for c in chars.by_ref() {
                        if c == ')' {
                            break;
                        }
                        _url.push(c);
                    }
                    // Emit the link text in cyan+underline; drop the URL.
                    if !link_text.is_empty() {
                        flush_plain!();
                        let style = Style::default()
                            .fg(theme.colors.secondary)
                            .add_modifier(Modifier::UNDERLINED);
                        spans.push(Span::styled(link_text, style));
                    }
                } else {
                    // Not a valid link — emit literally.
                    plain.push('[');
                    plain.push_str(&link_text);
                    if found_bracket {
                        plain.push(']');
                    }
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
