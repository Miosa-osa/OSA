use ratatui::style::{Modifier, Style};
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

/// Inline unified diff renderer with hunk grouping and WORD-LEVEL highlighting.
///
/// CC parity (`StructuredDiff*` / `Fallback.tsx`):
///   - hunks come from `grouped_ops(3)` (3 context lines) with a dim `…`
///     separator line between hunks;
///   - within a change run, the i-th removed line pairs with the i-th added
///     line for word-level highlights (runs of N deletes + N inserts pair,
///     not just 1:1);
///   - word highlights apply only when the pair is similar enough
///     (`CHANGE_THRESHOLD = 0.4` — more than 40% changed renders plain).
fn render_inline_diff(
    old: &str,
    new: &str,
    _width: u16,
    theme: &crate::style::Theme,
) -> Vec<Line<'static>> {
    use similar::{ChangeTag, TextDiff};

    let line_diff = TextDiff::from_lines(old, new);
    let mut lines: Vec<Line<'static>> = Vec::new();

    let groups = line_diff.grouped_ops(3);
    for (gi, group) in groups.iter().enumerate() {
        if gi > 0 {
            // Dim ellipsis separator between hunks (StructuredDiffList parity).
            lines.push(Line::from(Span::styled(
                "  …".to_string(),
                Style::default().fg(theme.colors.dim),
            )));
        }
        for op in group {
            let mut dels: Vec<String> = Vec::new();
            let mut inss: Vec<String> = Vec::new();
            for change in line_diff.iter_changes(op) {
                let content = change.value().trim_end_matches('\n').to_string();
                match change.tag() {
                    ChangeTag::Equal => {
                        lines.push(Line::from(vec![
                            Span::styled("  ".to_string(), Style::default().fg(theme.colors.muted)),
                            Span::styled(content, Style::default().fg(theme.colors.muted)),
                        ]));
                    }
                    ChangeTag::Delete => dels.push(content),
                    ChangeTag::Insert => inss.push(content),
                }
            }
            render_change_run(&dels, &inss, theme, &mut lines);
        }
    }

    if lines.is_empty() {
        lines.push(Line::from(Span::styled(
            "(no changes)".to_string(),
            Style::default().fg(theme.colors.muted),
        )));
    }

    lines
}

/// Proportion of a paired line that may change before word-level highlighting
/// is skipped in favor of plain +/- lines (CC `Fallback.tsx` CHANGE_THRESHOLD).
const WORD_DIFF_CHANGE_THRESHOLD: f32 = 0.4;

fn word_diff_pairs_well(old_line: &str, new_line: &str) -> bool {
    if old_line.trim().is_empty() || new_line.trim().is_empty() {
        return false;
    }
    let ratio = similar::TextDiff::from_words(old_line, new_line).ratio();
    (1.0 - ratio) <= WORD_DIFF_CHANGE_THRESHOLD
}

/// Render a run of removed lines followed by added lines, pairing the i-th
/// delete with the i-th insert for word-level highlights when similar enough.
fn render_change_run(
    dels: &[String],
    inss: &[String],
    theme: &crate::style::Theme,
    out: &mut Vec<Line<'static>>,
) {
    use similar::{ChangeTag, TextDiff};

    let paired = dels.len().min(inss.len());

    for (i, old_line) in dels.iter().enumerate() {
        if i < paired && word_diff_pairs_well(old_line, &inss[i]) {
            let word_diff = TextDiff::from_words(old_line.as_str(), inss[i].as_str());
            let del_bg = theme.colors.diff_del_bg;
            let mut spans: Vec<Span<'static>> = vec![Span::styled(
                "- ".to_string(),
                Style::default().fg(theme.colors.error).bg(del_bg),
            )];
            for wc in word_diff.iter_all_changes() {
                match wc.tag() {
                    ChangeTag::Equal => spans.push(Span::styled(
                        wc.value().to_string(),
                        Style::default().fg(theme.colors.error).bg(del_bg),
                    )),
                    ChangeTag::Delete => spans.push(Span::styled(
                        wc.value().to_string(),
                        Style::default()
                            .fg(theme.colors.diff_del_highlight_fg)
                            .bg(theme.colors.diff_del_highlight_bg)
                            .add_modifier(Modifier::BOLD),
                    )),
                    ChangeTag::Insert => {} // shown in the add line
                }
            }
            out.push(Line::from(spans));
        } else {
            out.push(Line::from(vec![
                Span::styled("- ".to_string(), Style::default().fg(theme.colors.error)),
                Span::styled(old_line.clone(), Style::default().fg(theme.colors.error)),
            ]));
        }
    }

    for (i, new_line) in inss.iter().enumerate() {
        if i < paired && word_diff_pairs_well(&dels[i], new_line) {
            let word_diff = TextDiff::from_words(dels[i].as_str(), new_line.as_str());
            let add_bg = theme.colors.diff_add_bg;
            let mut spans: Vec<Span<'static>> = vec![Span::styled(
                "+ ".to_string(),
                Style::default().fg(theme.colors.success).bg(add_bg),
            )];
            for wc in word_diff.iter_all_changes() {
                match wc.tag() {
                    ChangeTag::Equal => spans.push(Span::styled(
                        wc.value().to_string(),
                        Style::default().fg(theme.colors.success).bg(add_bg),
                    )),
                    ChangeTag::Insert => spans.push(Span::styled(
                        wc.value().to_string(),
                        Style::default()
                            .fg(theme.colors.diff_add_highlight_fg)
                            .bg(theme.colors.diff_add_highlight_bg)
                            .add_modifier(Modifier::BOLD),
                    )),
                    ChangeTag::Delete => {} // shown in the del line
                }
            }
            out.push(Line::from(spans));
        } else {
            out.push(Line::from(vec![
                Span::styled("+ ".to_string(), Style::default().fg(theme.colors.success)),
                Span::styled(new_line.clone(), Style::default().fg(theme.colors.success)),
            ]));
        }
    }
}

#[cfg(test)]
mod diff_render_tests {
    use super::*;

    fn text(lines: &[Line<'static>]) -> Vec<String> {
        lines
            .iter()
            .map(|l| l.spans.iter().map(|s| s.content.as_ref()).collect::<String>())
            .collect()
    }

    #[test]
    fn distant_changes_get_hunk_ellipsis_separator() {
        let old = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\n";
        let new = "A\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nL\n";
        let theme = crate::style::theme();
        let rendered = text(&render_inline_diff(old, new, 80, &theme));
        assert!(rendered.iter().any(|l| l == "  …"), "{:?}", rendered);
    }

    #[test]
    fn heavily_rewritten_pair_skips_word_highlights() {
        let theme = crate::style::theme();
        let lines = render_inline_diff("alpha beta\n", "zq xw yv\n", 80, &theme);
        let has_bold = lines
            .iter()
            .flat_map(|l| l.spans.iter())
            .any(|s| s.style.add_modifier.contains(Modifier::BOLD));
        assert!(!has_bold);
    }

    #[test]
    fn small_change_gets_word_highlights() {
        let theme = crate::style::theme();
        let lines = render_inline_diff("let count = 1;\n", "let count = 2;\n", 80, &theme);
        let has_bold = lines
            .iter()
            .flat_map(|l| l.spans.iter())
            .any(|s| s.style.add_modifier.contains(Modifier::BOLD));
        assert!(has_bold);
    }

    #[test]
    fn unbalanced_runs_render_all_lines() {
        let theme = crate::style::theme();
        let lines = render_inline_diff("one\ntwo\nthree\n", "uno\n", 80, &theme);
        let rendered = text(&lines);
        assert_eq!(rendered.iter().filter(|l| l.starts_with("- ")).count(), 3);
        assert_eq!(rendered.iter().filter(|l| l.starts_with("+ ")).count(), 1);
    }
}
