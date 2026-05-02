use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use tracing::debug;

use super::{parse_json_arg, render_tool_box, truncate_lines, RenderOpts, ToolRenderer};

// ─── FileViewRenderer (Read) ──────────────────────────────────────────────────

pub struct FileViewRenderer;

impl ToolRenderer for FileViewRenderer {
    fn render(
        &self,
        _name: &str,
        args: &str,
        result: &str,
        opts: &RenderOpts,
    ) -> Vec<Line<'static>> {
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
                        Span::styled(
                            line_content.to_string(),
                            Style::default().fg(theme.colors.muted),
                        ),
                    ]));
                }
                if line_count > PREVIEW_LINES {
                    out.push(Line::from(vec![Span::styled(
                        "         (ctrl+o to expand)".to_string(),
                        Style::default().fg(theme.colors.dim),
                    )]));
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
    fn render(
        &self,
        _name: &str,
        args: &str,
        result: &str,
        opts: &RenderOpts,
    ) -> Vec<Line<'static>> {
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
                let from_header = result
                    .lines()
                    .find(|l| l.contains("lines written"))
                    .and_then(|l| l.split_whitespace().next())
                    .and_then(|n| n.parse::<usize>().ok());
                from_header.unwrap_or_else(|| {
                    if content.is_empty() {
                        0
                    } else {
                        content.lines().count()
                    }
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
                    out.push(Line::from(vec![Span::styled(
                        "         (ctrl+o to expand)".to_string(),
                        Style::default().fg(theme.colors.dim),
                    )]));
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
    fn render(
        &self,
        name: &str,
        args: &str,
        result: &str,
        opts: &RenderOpts,
    ) -> Vec<Line<'static>> {
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

        // Parse old/new up front — needed for both collapsed and expanded paths.
        let old = parse_json_arg(args, &["old_string", "old", "original", "before"]);
        let new = parse_json_arg(args, &["new_string", "new", "replacement", "after"]);
        let patch = parse_patch_text(args, result);

        if !opts.expanded {
            // Collapsed: show diff summary + up to 5 changed lines when old/new are available.
            if let (Some(ref old_text), Some(ref new_text)) = (&old, &new) {
                let mut lines = vec![header];
                lines.extend(render_collapsed_diff_preview(old_text, new_text, &theme));
                return lines;
            }
            if let Some(ref patch_text) = patch {
                log_patch_render(name, &path, patch_text, "collapsed");
                let mut lines = vec![header];
                lines.extend(render_collapsed_patch_preview(patch_text, &theme));
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
            _ if patch.is_some() => {
                log_patch_render(
                    name,
                    &path,
                    patch.as_deref().unwrap_or_default(),
                    "expanded",
                );
                body.extend(render_patch_diff(
                    patch.as_deref().unwrap_or_default(),
                    &theme,
                ));
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

fn log_patch_render(tool_name: &str, path: &str, patch: &str, mode: &str) {
    let stats = patch_stats(patch);
    debug!(
        target: "osa_tui::tools::file",
        tool_name,
        path,
        mode,
        files_seen = stats.files_seen,
        files_added = stats.files_added,
        files_updated = stats.files_updated,
        files_deleted = stats.files_deleted,
        lines_added = stats.lines_added,
        lines_removed = stats.lines_removed,
        "rendering patch diff tool card"
    );
}

#[derive(Debug, Default, Clone, PartialEq, Eq)]
struct PatchStats {
    files_added: usize,
    files_updated: usize,
    files_deleted: usize,
    files_seen: usize,
    lines_added: usize,
    lines_removed: usize,
}

fn parse_patch_text(args: &str, result: &str) -> Option<String> {
    parse_json_arg(args, &["patch", "diff", "changes", "content", "input"])
        .or_else(|| parse_json_arg(result, &["patch", "diff", "changes", "content", "output"]))
        .or_else(|| {
            if looks_like_patch(args) {
                Some(args.to_string())
            } else {
                None
            }
        })
        .or_else(|| {
            if looks_like_patch(result) {
                Some(result.to_string())
            } else {
                None
            }
        })
        .map(|text| text.replace("\\n", "\n"))
        .filter(|text| looks_like_patch(text))
}

fn looks_like_patch(text: &str) -> bool {
    text.contains("*** Begin Patch")
        || text.contains("diff --git ")
        || text.lines().any(|line| {
            line.starts_with("*** Update File:")
                || line.starts_with("*** Add File:")
                || line.starts_with("*** Delete File:")
                || line.starts_with("@@ ")
        })
}

fn patch_stats(patch: &str) -> PatchStats {
    let mut stats = PatchStats::default();

    for line in patch.lines() {
        if line.starts_with("*** Add File:") {
            stats.files_added += 1;
            stats.files_seen += 1;
        } else if line.starts_with("*** Update File:") {
            stats.files_updated += 1;
            stats.files_seen += 1;
        } else if line.starts_with("*** Delete File:") {
            stats.files_deleted += 1;
            stats.files_seen += 1;
        } else if line.starts_with("diff --git ") {
            stats.files_seen += 1;
        } else if is_added_patch_line(line) {
            stats.lines_added += 1;
        } else if is_removed_patch_line(line) {
            stats.lines_removed += 1;
        }
    }

    stats
}

fn patch_summary(stats: &PatchStats) -> String {
    let files_changed = stats
        .files_seen
        .max(stats.files_added + stats.files_updated + stats.files_deleted);

    let mut parts: Vec<String> = Vec::new();
    if files_changed > 0 {
        parts.push(format!(
            "{} file{}",
            files_changed,
            if files_changed == 1 { "" } else { "s" }
        ));
    }
    if stats.files_added > 0 {
        parts.push(format!("{} added", stats.files_added));
    }
    if stats.files_updated > 0 {
        parts.push(format!("{} edited", stats.files_updated));
    }
    if stats.files_deleted > 0 {
        parts.push(format!("{} deleted", stats.files_deleted));
    }

    let change_text = match (stats.lines_added, stats.lines_removed) {
        (0, 0) => "no line changes".to_string(),
        (added, 0) => format!("+{}", added),
        (0, removed) => format!("-{}", removed),
        (added, removed) => format!("+{} -{}", added, removed),
    };
    parts.push(change_text);

    format!("Changed {}", parts.join(" · "))
}

fn render_collapsed_patch_preview(patch: &str, theme: &crate::style::Theme) -> Vec<Line<'static>> {
    let stats = patch_stats(patch);
    let mut out = vec![Line::from(vec![
        Span::styled("└ ".to_string(), Style::default().fg(theme.colors.muted)),
        Span::styled(
            patch_summary(&stats),
            Style::default().fg(theme.colors.success),
        ),
    ])];

    let mut shown = 0usize;
    for line in patch.lines().filter(|line| is_changed_patch_line(line)) {
        if shown >= 6 {
            out.push(Line::from(vec![Span::styled(
                "         (ctrl+o to expand)".to_string(),
                Style::default().fg(theme.colors.dim),
            )]));
            break;
        }

        let (prefix, content, fg, bg) = if is_added_patch_line(line) {
            (
                "+",
                line.trim_start_matches('+').to_string(),
                theme.colors.success,
                theme.colors.diff_add_bg,
            )
        } else {
            (
                "-",
                line.trim_start_matches('-').to_string(),
                theme.colors.error,
                theme.colors.diff_del_bg,
            )
        };

        out.push(Line::from(vec![
            Span::styled("  ".to_string(), Style::default().bg(bg)),
            Span::styled(format!("{} ", prefix), Style::default().fg(fg).bg(bg)),
            Span::styled(content, Style::default().fg(fg).bg(bg)),
        ]));
        shown += 1;
    }

    out
}

fn render_patch_diff(patch: &str, theme: &crate::style::Theme) -> Vec<Line<'static>> {
    patch
        .lines()
        .map(|line| {
            if line.starts_with("*** Add File:")
                || line.starts_with("*** Update File:")
                || line.starts_with("*** Delete File:")
                || line.starts_with("*** Move to:")
                || line.starts_with("diff --git ")
            {
                Line::from(vec![Span::styled(
                    line.to_string(),
                    Style::default()
                        .fg(theme.colors.secondary)
                        .add_modifier(Modifier::BOLD),
                )])
            } else if line.starts_with("@@") || line.starts_with("--- ") || line.starts_with("+++ ")
            {
                Line::from(vec![Span::styled(
                    line.to_string(),
                    theme.diff_hunk_label(),
                )])
            } else if is_added_patch_line(line) {
                Line::from(vec![
                    Span::styled("+ ".to_string(), Style::default().fg(theme.colors.success)),
                    Span::styled(
                        line.trim_start_matches('+').to_string(),
                        Style::default()
                            .fg(theme.colors.success)
                            .bg(theme.colors.diff_add_bg),
                    ),
                ])
            } else if is_removed_patch_line(line) {
                Line::from(vec![
                    Span::styled("- ".to_string(), Style::default().fg(theme.colors.error)),
                    Span::styled(
                        line.trim_start_matches('-').to_string(),
                        Style::default()
                            .fg(theme.colors.error)
                            .bg(theme.colors.diff_del_bg),
                    ),
                ])
            } else if line.starts_with("*** Begin Patch") || line.starts_with("*** End Patch") {
                Line::from(vec![Span::styled(
                    line.to_string(),
                    Style::default().fg(theme.colors.dim),
                )])
            } else {
                Line::from(vec![Span::styled(line.to_string(), theme.diff_context())])
            }
        })
        .collect()
}

fn is_changed_patch_line(line: &str) -> bool {
    is_added_patch_line(line) || is_removed_patch_line(line)
}

fn is_added_patch_line(line: &str) -> bool {
    line.starts_with('+') && !line.starts_with("+++")
}

fn is_removed_patch_line(line: &str) -> bool {
    line.starts_with('-') && !line.starts_with("---")
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
            Span::styled("  ".to_string(), Style::default().bg(bg)),
            Span::styled(lineno_str, Style::default().fg(theme.colors.dim).bg(bg)),
            Span::styled(format!("{} ", prefix), Style::default().fg(fg).bg(bg)),
            Span::styled(dl.content.clone(), Style::default().fg(fg).bg(bg)),
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
                    let mut del_spans: Vec<Span<'static>> = vec![Span::styled(
                        "- ".to_string(),
                        Style::default().fg(theme.colors.error).bg(del_bg),
                    )];
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
                                    Style::default()
                                        .fg(del_highlight)
                                        .bg(theme.colors.diff_del_highlight_bg)
                                        .add_modifier(Modifier::BOLD),
                                ));
                            }
                            ChangeTag::Insert => {} // shown in the add line
                        }
                    }
                    lines.push(Line::from(del_spans));

                    // Render insert line with word highlights
                    let mut add_spans: Vec<Span<'static>> = vec![Span::styled(
                        "+ ".to_string(),
                        Style::default().fg(theme.colors.success).bg(add_bg),
                    )];
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
                                    Style::default()
                                        .fg(add_highlight)
                                        .bg(theme.colors.diff_add_highlight_bg)
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

#[cfg(test)]
mod tests {
    use super::*;

    const PATCH: &str = r#"*** Begin Patch
*** Update File: src/example.rs
@@
-let old = true;
+let new = true;
 context
*** Add File: src/new.rs
+pub fn added() {}
*** End Patch
"#;

    #[test]
    fn parses_patch_stats_from_apply_patch_payload() {
        let stats = patch_stats(PATCH);

        assert_eq!(stats.files_updated, 1);
        assert_eq!(stats.files_added, 1);
        assert_eq!(stats.lines_added, 2);
        assert_eq!(stats.lines_removed, 1);
        assert_eq!(
            patch_summary(&stats),
            "Changed 2 files · 1 added · 1 edited · +2 -1"
        );
    }

    #[test]
    fn detects_patch_text_from_json_args() {
        let json = serde_json::json!({ "patch": PATCH }).to_string();

        assert_eq!(parse_patch_text(&json, "").as_deref(), Some(PATCH));
    }

    #[test]
    fn collapsed_patch_preview_shows_change_summary_and_lines() {
        let theme = crate::style::theme();
        let lines = render_collapsed_patch_preview(PATCH, &theme);
        let rendered: Vec<String> = lines
            .iter()
            .map(|line| {
                line.spans
                    .iter()
                    .map(|span| span.content.as_ref())
                    .collect::<String>()
            })
            .collect();

        assert!(rendered[0].contains("Changed 2 files"));
        assert!(rendered
            .iter()
            .any(|line| line.contains("+ let new = true;")));
        assert!(rendered
            .iter()
            .any(|line| line.contains("- let old = true;")));
    }
}
