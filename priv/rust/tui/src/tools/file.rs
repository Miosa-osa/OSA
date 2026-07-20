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

        // CC-style header: ● Read(path) — bold name, plain parenthesized path.
        let path = crate::util::ellipsize_path_middle(
            &path,
            (opts.width as usize).saturating_sub(16).max(12),
        );
        let header = super::make_header(
            opts.status,
            opts.spinner_frame,
            "Read",
            &path,
            opts.duration_ms,
        );

        if !opts.expanded {
            // CC parity: a Read collapses to a single connector line —
            // `⎿  Read N lines (ctrl+o to expand)` — no content preview.
            let line_count = if result.is_empty() {
                0usize
            } else {
                result.lines().count()
            };
            if line_count > 0 {
                let summary = Line::from(vec![
                    Span::styled(
                        format!(
                            "Read {} line{}",
                            line_count,
                            if line_count == 1 { "" } else { "s" }
                        ),
                        Style::default().fg(theme.colors.muted),
                    ),
                    Span::styled(
                        " (ctrl+o to expand)".to_string(),
                        Style::default().fg(theme.colors.dim),
                    ),
                ]);
                return render_tool_box(header, vec![summary]);
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

        let path = crate::util::ellipsize_path_middle(
            &path,
            (opts.width as usize).saturating_sub(16).max(12),
        );
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
            // CC parity: `⎿  Wrote N lines to <path> (ctrl+o to expand)`.
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
                    Span::styled(
                        format!(
                            "Wrote {} line{} to {}",
                            line_count,
                            if line_count == 1 { "" } else { "s" },
                            path
                        ),
                        Style::default().fg(theme.colors.muted),
                    ),
                    Span::styled(
                        " (ctrl+o to expand)".to_string(),
                        Style::default().fg(theme.colors.dim),
                    ),
                ]);
                let mut body = vec![summary];
                // Show WHAT is being written as an all-additions (green `+`) diff
                // preview, so a file WRITE ("building something") surfaces its
                // content in the tool card during the turn instead of only a line
                // count. Mirrors the edit card's collapsed diff; the full content
                // is still available on ctrl+o expand.
                if !content.is_empty() {
                    let diff_add_style = Style::default().fg(theme.colors.success);
                    for line in content.lines() {
                        body.push(Line::from(vec![
                            Span::styled("+ ".to_string(), diff_add_style),
                            Span::styled(line.to_string(), diff_add_style),
                        ]));
                    }
                    body = truncate_lines(body, 15);
                }
                return render_tool_box(header, body);
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

        // CC-style header: ● Update(path)
        let path = crate::util::ellipsize_path_middle(
            &path,
            (opts.width as usize).saturating_sub(16).max(12),
        );
        let header = super::make_header(
            opts.status,
            opts.spinner_frame,
            display_name,
            &path,
            opts.duration_ms,
        );

        // Parse old/new up front — needed for both collapsed and expanded paths.
        let old = parse_json_arg(args, &["old_string", "old", "original", "before"]);
        let new = parse_json_arg(args, &["new_string", "new", "replacement", "after"]);

        if !opts.expanded {
            // CC parity (FileEditToolUpdatedMessage): `⎿  Added N lines,
            // removed M lines` (bold counts) followed by the full hunk diff
            // (context lines + word-level highlights), capped with a ctrl+o hint.
            if let (Some(ref old_text), Some(ref new_text)) = (&old, &new) {
                let mut body = render_collapsed_diff_preview(old_text, new_text, opts.width, &theme);
                body = truncate_lines(body, 20);
                return render_tool_box(header, body);
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

/// Collapsed diff body, CC style (FileEditToolUpdatedMessage): an
/// `Added N lines, removed M lines` summary with bold counts, followed by the
/// full hunk diff — context lines, word-level highlights, `…` hunk separators.
fn render_collapsed_diff_preview(
    old: &str,
    new: &str,
    width: u16,
    theme: &crate::style::Theme,
) -> Vec<Line<'static>> {
    use similar::{ChangeTag, TextDiff};

    let diff = TextDiff::from_lines(old, new);
    let mut added: usize = 0;
    let mut removed: usize = 0;
    for change in diff.iter_all_changes() {
        match change.tag() {
            ChangeTag::Insert => added += 1,
            ChangeTag::Delete => removed += 1,
            ChangeTag::Equal => {}
        }
    }

    let mut out: Vec<Line<'static>> = Vec::new();

    // Summary line: Added N lines, removed M lines — CC bolds the counts.
    let bold = Style::default().add_modifier(Modifier::BOLD);
    let mut spans: Vec<Span<'static>> = Vec::new();
    match (added, removed) {
        (0, 0) => spans.push(Span::raw("No changes".to_string())),
        (a, r) => {
            if a > 0 {
                spans.push(Span::raw("Added ".to_string()));
                spans.push(Span::styled(a.to_string(), bold));
                spans.push(Span::raw(format!(" line{}", if a == 1 { "" } else { "s" })));
            }
            if a > 0 && r > 0 {
                spans.push(Span::raw(", ".to_string()));
            }
            if r > 0 {
                spans.push(Span::raw(
                    if a == 0 { "Removed " } else { "removed " }.to_string(),
                ));
                spans.push(Span::styled(r.to_string(), bold));
                spans.push(Span::raw(format!(" line{}", if r == 1 { "" } else { "s" })));
            }
        }
    }
    out.push(Line::from(spans));

    // Full hunk diff with context + word-level highlights (StructuredDiffList).
    out.extend(render_inline_diff(old, new, width, theme));
    out
}

/// Inline unified diff renderer — delegates to the shared CC-style renderer
/// in `render::diff` (line-number gutter, solid +/- background bars,
/// bg-only word-level highlights, `…` hunk separators, width-aware wrapping
/// so nothing clips horizontally).
fn render_inline_diff(
    old: &str,
    new: &str,
    width: u16,
    _theme: &crate::style::Theme,
) -> Vec<Line<'static>> {
    crate::render::diff::render_diff_body(old, new, width, 1)
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
        assert!(rendered.iter().any(|l| l.trim() == "…"), "{:?}", rendered);
    }

    #[test]
    fn heavily_rewritten_pair_skips_word_highlights() {
        let theme = crate::style::theme();
        let lines = render_inline_diff("alpha beta\n", "zq xw yv\n", 80, &theme);
        let has_highlight = lines.iter().flat_map(|l| l.spans.iter()).any(|s| {
            s.style.bg == Some(theme.colors.diff_add_highlight_bg)
                || s.style.bg == Some(theme.colors.diff_del_highlight_bg)
        });
        assert!(!has_highlight);
    }

    #[test]
    fn small_change_gets_word_highlights() {
        let theme = crate::style::theme();
        let lines = render_inline_diff("let count = 1;\n", "let count = 2;\n", 80, &theme);
        let has_highlight = lines.iter().flat_map(|l| l.spans.iter()).any(|s| {
            s.style.bg == Some(theme.colors.diff_add_highlight_bg)
                || s.style.bg == Some(theme.colors.diff_del_highlight_bg)
        });
        assert!(has_highlight);
    }

    #[test]
    fn unbalanced_runs_render_all_lines() {
        let theme = crate::style::theme();
        let lines = render_inline_diff("one\ntwo\nthree\n", "uno\n", 80, &theme);
        let rendered = text(&lines);
        assert_eq!(rendered.iter().filter(|l| l.contains(" - ")).count(), 3);
        assert_eq!(rendered.iter().filter(|l| l.contains(" + ")).count(), 1);
    }

    #[test]
    fn file_write_collapsed_shows_content_additions_preview() {
        // A file WRITE ("building something") must surface WHAT is being written
        // as a green additions preview in the collapsed card, not just a count.
        let opts = RenderOpts {
            status: crate::tools::ToolStatus::Success,
            width: 80,
            expanded: false,
            compact: true,
            spinner_frame: None,
            duration_ms: 12,
            truncated: false,
        };
        let args = r#"{"path":"/tmp/new.rs","content":"fn main() {}\nprintln!(\"hi\");"}"#;
        let lines = FileWriteRenderer.render("file_write", args, "", &opts);
        let rendered = text(&lines);
        // The written source shows up as `+ ` additions in the collapsed card.
        assert!(
            rendered.iter().any(|l| l.contains("+ fn main() {}")),
            "collapsed write must preview content additions, got: {:?}",
            rendered
        );
    }
}
