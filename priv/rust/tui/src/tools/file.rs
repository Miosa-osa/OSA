use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};

use super::{
    parse_json_arg, render_tool_box, truncate_lines, RenderOpts, ToolRenderer,
};

// ─── FileViewRenderer (Read) ──────────────────────────────────────────────────

pub struct FileViewRenderer;

impl ToolRenderer for FileViewRenderer {
    fn render(&self, _name: &str, args: &str, result: &str, opts: &RenderOpts) -> Vec<Line<'static>> {
        let theme = crate::style::theme();

        let path = parse_json_arg(args, &["path", "file_path", "filename", "target_file"])
            .unwrap_or_else(|| "…".to_string());

        // Collapsed header with path in cyan+underline
        let (icon, icon_style) = super::status_icon(opts.status, opts.spinner_frame);
        let header = Line::from(vec![
            Span::styled(icon, icon_style),
            Span::raw(" "),
            Span::styled("Read".to_string(), theme.tool_name()),
            Span::raw("  "),
            Span::styled(
                path.clone(),
                Style::default()
                    .fg(theme.colors.secondary)
                    .add_modifier(Modifier::UNDERLINED),
            ),
            {
                let dur = super::format_duration(opts.duration_ms);
                if dur.is_empty() {
                    Span::raw("")
                } else {
                    Span::styled(format!("  {}", dur), theme.tool_duration())
                }
            },
        ]);

        if !opts.expanded {
            // Collapsed: show header + summary line when result is available
            let line_count = if result.is_empty() {
                0usize
            } else {
                result.lines().count()
            };
            if line_count > 0 {
                let summary = Line::from(vec![
                    Span::styled("└ ".to_string(), Style::default().fg(theme.colors.muted)),
                    Span::styled(
                        format!("Read · {} lines", line_count),
                        Style::default().fg(theme.colors.success),
                    ),
                ]);
                let mut out = vec![header, summary];
                // Preview: first 5 lines with dimmed line numbers
                const PREVIEW_LINES: usize = 5;
                for (idx, line_content) in result.lines().take(PREVIEW_LINES).enumerate() {
                    let lineno = idx + 1;
                    out.push(Line::from(vec![
                        Span::styled(
                            format!("  {:>4}  ", lineno),
                            Style::default().fg(theme.colors.dim),
                        ),
                        Span::styled(line_content.to_string(), Style::default().fg(theme.colors.muted)),
                    ]));
                }
                if line_count > PREVIEW_LINES {
                    out.push(Line::from(vec![
                        Span::styled(
                            "         (ctrl+o to expand)".to_string(),
                            Style::default().fg(theme.colors.dim),
                        ),
                    ]));
                }
                return out;
            }
            return vec![header];
        }

        // Expanded body: numbered lines
        let mut body: Vec<Line<'static>> = Vec::new();

        for (idx, line_content) in result.lines().enumerate() {
            let lineno = idx + 1;
            body.push(Line::from(vec![
                Span::styled(
                    format!("{:>4} ", lineno),
                    Style::default().fg(theme.colors.dim),
                ),
                Span::styled("│ ".to_string(), Style::default().fg(theme.colors.border)),
                Span::styled(line_content.to_string(), theme.faint()),
            ]));
        }

        let max_lines = if opts.compact { 6 } else { 10 };
        let body = truncate_lines(body, max_lines);

        render_tool_box(header, body)
    }
}

// ─── FileWriteRenderer (Write) ────────────────────────────────────────────────

pub struct FileWriteRenderer;

impl ToolRenderer for FileWriteRenderer {
    fn render(&self, _name: &str, args: &str, result: &str, opts: &RenderOpts) -> Vec<Line<'static>> {
        let theme = crate::style::theme();

        // Extract path: try args first, then result first line (backend sends path there)
        let path = parse_json_arg(args, &["path", "file_path", "filename", "target_file"])
            .or_else(|| {
                if !result.is_empty() {
                    result.lines().next().map(|l| l.to_string())
                } else {
                    None
                }
            })
            .unwrap_or_else(|| "…".to_string());

        let header = super::make_header(
            opts.status,
            opts.spinner_frame,
            "Write",
            &path,
            opts.duration_ms,
        );

        // Resolve the written content. The backend sends the result as:
        //   /path/to/file\nN lines written\n---\ncode preview lines...
        let content = {
            let raw = if result.contains("---\n") {
                result.splitn(2, "---\n").nth(1).unwrap_or("").to_string()
            } else {
                parse_json_arg(args, &["content", "text", "body"])
                    .unwrap_or_else(|| result.to_string())
            };
            raw.replace("\\n", "\n")
        };

        if !opts.expanded {
            // Collapsed: show header + summary line when content is available
            // Parse real line count from "N lines written" header if present,
            // otherwise fall back to counting preview lines.
            let line_count = {
                let from_header = result.lines()
                    .find(|l| l.contains("lines written"))
                    .and_then(|l| l.split_whitespace().next())
                    .and_then(|n| n.parse::<usize>().ok());
                from_header.unwrap_or_else(|| {
                    if content.is_empty() { 0 } else { content.lines().count() }
                })
            };
            if line_count > 0 {
                let summary = Line::from(vec![
                    Span::styled("└ ".to_string(), Style::default().fg(theme.colors.muted)),
                    Span::styled(
                        format!(
                            "Written · {} line{}",
                            line_count,
                            if line_count == 1 { "" } else { "s" }
                        ),
                        Style::default().fg(theme.colors.success),
                    ),
                ]);
                let mut out = vec![header, summary];
                // Preview: first 5 lines with dimmed line numbers
                const PREVIEW_LINES: usize = 5;
                for (idx, line) in content.lines().take(PREVIEW_LINES).enumerate() {
                    let lineno = idx + 1;
                    out.push(Line::from(vec![
                        Span::styled(
                            format!("  {:>4}  ", lineno),
                            Style::default().fg(theme.colors.dim),
                        ),
                        Span::styled(line.to_string(), Style::default().fg(theme.colors.muted)),
                    ]));
                }
                if line_count > PREVIEW_LINES {
                    out.push(Line::from(vec![
                        Span::styled(
                            "         (ctrl+o to expand)".to_string(),
                            Style::default().fg(theme.colors.dim),
                        ),
                    ]));
                }
                return out;
            }
            return vec![header];
        }

        // Expanded body: line-numbered with green + prefix
        let diff_add_style = Style::default().fg(theme.colors.success);
        let mut body: Vec<Line<'static>> = Vec::new();
        for (idx, line) in content.lines().enumerate() {
            let lineno = idx + 1;
            body.push(Line::from(vec![
                Span::styled(
                    format!("{:>4} ", lineno),
                    Style::default().fg(theme.colors.dim),
                ),
                Span::styled("+ ".to_string(), diff_add_style),
                Span::styled(line.to_string(), diff_add_style),
            ]));
        }

        let max_lines = if opts.compact { 10 } else { 20 };
        let body = truncate_lines(body, max_lines);

        render_tool_box(header, body)
    }
}

// ─── FileEditRenderer (Edit / MultiEdit / Download) ───────────────────────────

pub struct FileEditRenderer;

impl ToolRenderer for FileEditRenderer {
    fn render(&self, name: &str, args: &str, result: &str, opts: &RenderOpts) -> Vec<Line<'static>> {
        let theme = crate::style::theme();

        let path = parse_json_arg(
            args,
            &["path", "file_path", "filename", "target_file", "file"],
        )
        .unwrap_or_else(|| "…".to_string());

        // Pick display name — "Update" for edits (matches the upstream agent CLI style)
        let display_name = match name.to_lowercase().as_str() {
            "download" => "Download",
            "multiedit" | "multi_edit" | "multi_file_edit" => "MultiEdit",
            _ => "Update",
        };

        let (icon, icon_style) = super::status_icon(opts.status, opts.spinner_frame);
        let header = Line::from(vec![
            Span::styled(icon, icon_style),
            Span::raw(" "),
            Span::styled(display_name.to_string(), theme.tool_name()),
            Span::raw("  "),
            Span::styled(
                path,
                Style::default()
                    .fg(theme.colors.secondary)
                    .add_modifier(Modifier::UNDERLINED),
            ),
            {
                let dur = super::format_duration(opts.duration_ms);
                if dur.is_empty() {
                    Span::raw("")
                } else {
                    Span::styled(format!("  {}", dur), theme.tool_duration())
                }
            },
        ]);

        // Parse old/new up front — needed for both collapsed and expanded paths.
        let old = parse_json_arg(args, &["old_string", "old", "original", "before"]);
        let new = parse_json_arg(args, &["new_string", "new", "replacement", "after"]);

        if !opts.expanded {
            // Collapsed: show diff summary + up to 5 changed lines when old/new are available.
            if let (Some(ref old_text), Some(ref new_text)) = (&old, &new) {
                let mut lines = vec![header];
                lines.extend(render_collapsed_diff_preview(old_text, new_text, &theme));
                return lines;
            }
            return vec![header];
        }

        // Expanded: full unified diff.

        let mut body: Vec<Line<'static>> = Vec::new();

        match (old, new) {
            (Some(old_text), Some(new_text)) => {
                body.extend(render_inline_diff(&old_text, &new_text, opts.width, &theme));
            }
            _ => {
                // Fallback: plain result text
                for line in result.lines() {
                    body.push(Line::from(Span::styled(line.to_string(), theme.faint())));
                }
            }
        }

        let max_lines = if opts.compact { 10 } else { 20 };
        let body = truncate_lines(body, max_lines);

        render_tool_box(header, body)
    }
}

/// Collapsed diff summary: `└ Added N, removed M lines` followed by up to 5 changed lines.
/// Removed lines get a subtle red-tinted background; added lines get a subtle green-tinted background.
fn render_collapsed_diff_preview(
    old: &str,
    new: &str,
    theme: &crate::style::Theme,
) -> Vec<Line<'static>> {
    use similar::{ChangeTag, TextDiff};

    let diff = TextDiff::from_lines(old, new);

    // Count totals and collect changed lines (not Equal context).
    let mut added: usize = 0;
    let mut removed: usize = 0;

    // Collect (tag, old_lineno, new_lineno, content) for changed lines only.
    struct DiffLine {
        tag: ChangeTag,
        lineno: usize,
        content: String,
    }
    let mut changed_lines: Vec<DiffLine> = Vec::new();

    for change in diff.iter_all_changes() {
        match change.tag() {
            ChangeTag::Insert => {
                added += 1;
                let lineno = change.new_index().map(|i| i + 1).unwrap_or(0);
                changed_lines.push(DiffLine {
                    tag: ChangeTag::Insert,
                    lineno,
                    content: change.value().trim_end_matches('\n').to_string(),
                });
            }
            ChangeTag::Delete => {
                removed += 1;
                let lineno = change.old_index().map(|i| i + 1).unwrap_or(0);
                changed_lines.push(DiffLine {
                    tag: ChangeTag::Delete,
                    lineno,
                    content: change.value().trim_end_matches('\n').to_string(),
                });
            }
            ChangeTag::Equal => {}
        }
    }

    let mut out: Vec<Line<'static>> = Vec::new();

    // Summary line: └ Added N, removed M lines
    let summary_text = match (added, removed) {
        (0, 0) => "No changes".to_string(),
        (a, 0) => format!("Added {} line{}", a, if a == 1 { "" } else { "s" }),
        (0, r) => format!("Removed {} line{}", r, if r == 1 { "" } else { "s" }),
        (a, r) => format!(
            "Added {}, removed {} line{}",
            a,
            r,
            if r == 1 { "" } else { "s" }
        ),
    };
    out.push(Line::from(vec![
        Span::styled("└ ".to_string(), Style::default().fg(theme.colors.muted)),
        Span::styled(summary_text, Style::default().fg(theme.colors.success)),
    ]));

    // Subtle background tints — fixed Rgb values that work across themes.
    // Dark red tint for removed; dark green/teal tint for added.
    let del_bg = theme.colors.diff_del_bg;
    let add_bg = theme.colors.diff_add_bg;

    // Show up to 5 changed lines.
    let preview: Vec<&DiffLine> = changed_lines.iter().take(5).collect();
    for dl in preview {
        let (prefix, fg, bg) = match dl.tag {
            ChangeTag::Delete => ("-", theme.colors.error, del_bg),
            ChangeTag::Insert => ("+", theme.colors.success, add_bg),
            ChangeTag::Equal => unreachable!(),
        };
        let lineno_str = if dl.lineno > 0 {
            format!("{:>4} ", dl.lineno)
        } else {
            "     ".to_string()
        };
        out.push(Line::from(vec![
            Span::styled(
                "  ".to_string(),
                Style::default().bg(bg),
            ),
            Span::styled(
                lineno_str,
                Style::default().fg(theme.colors.dim).bg(bg),
            ),
            Span::styled(
                format!("{} ", prefix),
                Style::default().fg(fg).bg(bg),
            ),
            Span::styled(
                dl.content.clone(),
                Style::default().fg(fg).bg(bg),
            ),
        ]));
    }

    out
}

/// Inline unified diff renderer with WORD-LEVEL highlighting.
/// Changed words within lines are highlighted in a brighter color.
fn render_inline_diff(
    old: &str,
    new: &str,
    _width: u16,
    theme: &crate::style::Theme,
) -> Vec<Line<'static>> {
    use similar::{ChangeTag, TextDiff};

    let line_diff = TextDiff::from_lines(old, new);
    let mut lines: Vec<Line<'static>> = Vec::new();

    // Collect changes for word-level diffing on adjacent delete+insert pairs
    let changes: Vec<_> = line_diff.iter_all_changes().collect();
    let mut i = 0;

    while i < changes.len() {
        let change = &changes[i];
        match change.tag() {
            ChangeTag::Equal => {
                let content = change.value().trim_end_matches('\n').to_string();
                lines.push(Line::from(vec![
                    Span::styled("  ".to_string(), Style::default().fg(theme.colors.muted)),
                    Span::styled(content, Style::default().fg(theme.colors.muted)),
                ]));
                i += 1;
            }
            ChangeTag::Delete => {
                // Check if next change is an Insert (paired delete+insert = modification)
                let has_insert = i + 1 < changes.len() && changes[i + 1].tag() == ChangeTag::Insert;

                if has_insert {
                    // Word-level diff between the old and new line
                    let old_line = change.value().trim_end_matches('\n');
                    let new_line = changes[i + 1].value().trim_end_matches('\n');

                    let del_bg = Color::Rgb(60, 10, 10);
                    let add_bg = Color::Rgb(10, 45, 20);
                    let del_highlight = theme.colors.diff_del_highlight_fg;
                    let add_highlight = theme.colors.diff_add_highlight_fg;

                    // Render delete line with word highlights
                    let word_diff = TextDiff::from_words(old_line, new_line);
                    let mut del_spans: Vec<Span<'static>> = vec![
                        Span::styled("- ".to_string(), Style::default().fg(theme.colors.error).bg(del_bg)),
                    ];
                    for wc in word_diff.iter_all_changes() {
                        match wc.tag() {
                            ChangeTag::Equal => {
                                del_spans.push(Span::styled(
                                    wc.value().to_string(),
                                    Style::default().fg(theme.colors.error).bg(del_bg),
                                ));
                            }
                            ChangeTag::Delete => {
                                del_spans.push(Span::styled(
                                    wc.value().to_string(),
                                    Style::default().fg(del_highlight).bg(theme.colors.diff_del_highlight_bg)
                                        .add_modifier(Modifier::BOLD),
                                ));
                            }
                            ChangeTag::Insert => {} // shown in the add line
                        }
                    }
                    lines.push(Line::from(del_spans));

                    // Render insert line with word highlights
                    let mut add_spans: Vec<Span<'static>> = vec![
                        Span::styled("+ ".to_string(), Style::default().fg(theme.colors.success).bg(add_bg)),
                    ];
                    for wc in word_diff.iter_all_changes() {
                        match wc.tag() {
                            ChangeTag::Equal => {
                                add_spans.push(Span::styled(
                                    wc.value().to_string(),
                                    Style::default().fg(theme.colors.success).bg(add_bg),
                                ));
                            }
                            ChangeTag::Insert => {
                                add_spans.push(Span::styled(
                                    wc.value().to_string(),
                                    Style::default().fg(add_highlight).bg(theme.colors.diff_add_highlight_bg)
                                        .add_modifier(Modifier::BOLD),
                                ));
                            }
                            ChangeTag::Delete => {} // shown in the del line
                        }
                    }
                    lines.push(Line::from(add_spans));

                    i += 2; // skip both delete and insert
                } else {
                    // Standalone delete (no matching insert)
                    let content = change.value().trim_end_matches('\n').to_string();
                    lines.push(Line::from(vec![
                        Span::styled("- ".to_string(), Style::default().fg(theme.colors.error)),
                        Span::styled(content, Style::default().fg(theme.colors.error)),
                    ]));
                    i += 1;
                }
            }
            ChangeTag::Insert => {
                // Standalone insert (no preceding delete)
                let content = change.value().trim_end_matches('\n').to_string();
                lines.push(Line::from(vec![
                    Span::styled("+ ".to_string(), Style::default().fg(theme.colors.success)),
                    Span::styled(content, Style::default().fg(theme.colors.success)),
                ]));
                i += 1;
            }
        }
    }

    lines
}
