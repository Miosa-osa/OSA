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
        let full_path = parse_json_arg(args, &["path", "file_path", "filename", "target_file"])
            .or_else(|| {
                if !result.is_empty() {
                    result.lines().next().map(|l| l.to_string())
                } else {
                    None
                }
            })
            .unwrap_or_else(|| "…".to_string());

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

        // Real line count: prefer the backend's "N lines written" header, else
        // count the resolved content.
        let line_count = {
            let from_header = result
                .lines()
                .find(|l| l.contains("lines written"))
                .and_then(|l| l.split_whitespace().next())
                .and_then(|n| n.parse::<usize>().ok());
            from_header.unwrap_or_else(|| {
                if content.is_empty() { 0 } else { content.lines().count() }
            })
        };

        // A file WRITE creates content — `Create` verb (or `Update plan` for a
        // plan file). Diffstat is all-additions; the range spans the whole file.
        let verb = if is_plan_file(&full_path) { "Update plan" } else { "Create" };
        let display_path = if opts.expanded {
            relativize_path(&full_path)
        } else {
            basename_of(&full_path).to_string()
        };
        let stats = DiffStats {
            added: line_count,
            removed: 0,
            first: 1,
            last: line_count.max(1),
        };
        let trailer = if line_count > 0 {
            build_edit_trailer(opts.expanded, false, 1, Some(&stats), &theme)
        } else {
            Vec::new()
        };
        let header = semantic_header(
            opts.status,
            opts.spinner_frame,
            verb,
            &display_path,
            &full_path,
            trailer,
            opts.duration_ms,
        );

        if !opts.expanded {
            if line_count > 0 {
                let summary = Line::from(vec![
                    Span::styled(
                        format!(
                            "Wrote {} line{} to {}",
                            line_count,
                            if line_count == 1 { "" } else { "s" },
                            display_path
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

        let full_path = parse_json_arg(
            args,
            &["path", "file_path", "filename", "target_file", "file"],
        )
        .unwrap_or_else(|| "…".to_string());

        // Derive the syntect language token from the file extension. `None` when
        // the file has no extension, which makes the diff renderer fall back to
        // plain (uncolored) content.
        let language = language_from_path(&full_path);

        // Parse old/new up front — needed for the header diffstat, the collapsed
        // preview and the expanded diff.
        let old = parse_json_arg(args, &["old_string", "old", "original", "before"]);
        let new = parse_json_arg(args, &["new_string", "new", "replacement", "after"]);

        // Multi-edit: several hunks in one call. We summarize as `(N edits)` and
        // suppress a single (misleading) diffstat/range.
        let is_multi = matches!(
            name.to_lowercase().as_str(),
            "multiedit" | "multi_edit" | "multi_file_edit"
        );
        let edit_count = if is_multi { count_edits(args) } else { 1 };

        // Semantic verb chosen by operation: Create (new content) / Edit
        // (modify) / Update plan (a plan file) / Download.
        let verb = choose_edit_verb(name, &full_path, old.as_deref());

        // Diffstat + changed line range from the actual snippet diff. Edit args
        // carry only the snippet (not its file offset), so the range is snippet-
        // relative (start_line = 1).
        let stats = match (&old, &new) {
            (Some(o), Some(n)) => Some(compute_diff_stats(o, n)),
            _ => None,
        };

        // Path display: basename when collapsed (compact), cwd-relativized when
        // expanded (so the user can see where the file lives). The OSC-8 link
        // always targets the absolute path.
        let display_path = if opts.expanded {
            relativize_path(&full_path)
        } else {
            basename_of(&full_path).to_string()
        };

        let trailer =
            build_edit_trailer(opts.expanded, is_multi, edit_count, stats.as_ref(), &theme);

        let header = semantic_header(
            opts.status,
            opts.spinner_frame,
            verb,
            &display_path,
            &full_path,
            trailer,
            opts.duration_ms,
        );

        if !opts.expanded {
            // CC parity (FileEditToolUpdatedMessage): `⎿  Added N lines,
            // removed M lines` (bold counts) followed by the full hunk diff
            // (context lines + word-level highlights), capped with a ctrl+o hint.
            if let (Some(ref old_text), Some(ref new_text)) = (&old, &new) {
                let mut body = render_collapsed_diff_preview(
                    old_text,
                    new_text,
                    opts.width,
                    &theme,
                    language.as_deref(),
                );
                body = truncate_lines(body, 20);
                return render_tool_box(header, body);
            }
            return vec![header];
        }

        // Expanded: full unified diff.

        let mut body: Vec<Line<'static>> = Vec::new();

        match (old, new) {
            (Some(old_text), Some(new_text)) => {
                body.extend(render_inline_diff(
                    &old_text,
                    &new_text,
                    opts.width,
                    &theme,
                    language.as_deref(),
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

/// Collapsed diff body, CC style (FileEditToolUpdatedMessage): an
/// `Added N lines, removed M lines` summary with bold counts, followed by the
/// full hunk diff — context lines, word-level highlights, `…` hunk separators.
fn render_collapsed_diff_preview(
    old: &str,
    new: &str,
    width: u16,
    theme: &crate::style::Theme,
    language: Option<&str>,
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
    out.extend(render_inline_diff(old, new, width, theme, language));
    out
}

// ─── Semantic edit header ─────────────────────────────────────────────────────

/// Added/removed line counts plus the changed line range of a snippet diff.
/// `first`/`last` are 1-based line numbers in the NEW text (snippet-relative:
/// Edit args carry only the snippet, so start_line is 1). For a pure deletion
/// the position is where the removed line sat in the new text.
struct DiffStats {
    added: usize,
    removed: usize,
    first: usize,
    last: usize,
}

impl DiffStats {
    /// `L42` for a single line, `L42-58` for a span — the WHERE indicator.
    fn range_label(&self) -> String {
        if self.first == self.last {
            format!("L{}", self.first)
        } else {
            format!("L{}-{}", self.first, self.last)
        }
    }
}

/// Count added/removed lines and locate the changed region of a snippet diff.
fn compute_diff_stats(old: &str, new: &str) -> DiffStats {
    use similar::{ChangeTag, TextDiff};

    let diff = TextDiff::from_lines(old, new);
    let mut added = 0usize;
    let mut removed = 0usize;
    let mut new_ln = 1usize; // 1-based line cursor in the NEW text
    let mut first: Option<usize> = None;
    let mut last: Option<usize> = None;
    for change in diff.iter_all_changes() {
        match change.tag() {
            ChangeTag::Equal => new_ln += 1,
            ChangeTag::Insert => {
                added += 1;
                first.get_or_insert(new_ln);
                last = Some(new_ln);
                new_ln += 1;
            }
            ChangeTag::Delete => {
                removed += 1;
                // A deletion sits between new-text lines; anchor it at the
                // current new-line cursor (do not advance it).
                first.get_or_insert(new_ln);
                last = Some(new_ln);
            }
        }
    }
    DiffStats {
        added,
        removed,
        first: first.unwrap_or(1),
        last: last.unwrap_or_else(|| first.unwrap_or(1)),
    }
}

/// Number of hunks in a MultiEdit call (`edits` array length); 1 when unknown.
fn count_edits(args: &str) -> usize {
    serde_json::from_str::<serde_json::Value>(args)
        .ok()
        .and_then(|v| {
            v.get("edits")
                .and_then(|e| e.as_array())
                .map(|a| a.len())
                .or_else(|| v.get("files").and_then(|f| f.as_array()).map(|a| a.len()))
        })
        .filter(|n| *n > 0)
        .unwrap_or(1)
}

/// Basename of a path, tolerant of `/` and `\\` separators and the `…`
/// placeholder. Never panics on odd input.
fn basename_of(path: &str) -> &str {
    path.rsplit(['/', '\\'])
        .find(|s| !s.is_empty())
        .unwrap_or(path)
}

/// Replace a leading `$HOME` with `~` so long absolute paths stay readable.
fn shorten_home(path: &str) -> String {
    match std::env::var("HOME") {
        Ok(h) if !h.is_empty() && !path.is_empty() => path.replace(&h, "~"),
        _ => path.to_string(),
    }
}

/// Relativize `path` against the current working directory when it lives under
/// it; otherwise fall back to a `$HOME`-shortened absolute path.
fn relativize_path(path: &str) -> String {
    use std::path::Path;
    if let Ok(cwd) = std::env::current_dir() {
        if let Ok(rel) = Path::new(path).strip_prefix(&cwd) {
            let r = rel.to_string_lossy();
            if !r.is_empty() {
                return r.into_owned();
            }
        }
    }
    shorten_home(path)
}

/// True when the file looks like an agent plan file (`plan.md`, `foo-plan.txt`),
/// which gets the `Update plan` verb.
fn is_plan_file(path: &str) -> bool {
    let name = basename_of(path).to_ascii_lowercase();
    let stem = name.rsplit_once('.').map(|(s, _)| s).unwrap_or(name.as_str());
    stem == "plan" || stem.ends_with("-plan") || stem.ends_with("_plan")
}

/// Pick the semantic verb for an edit cell from the tool name, path and whether
/// there is any original text being replaced.
fn choose_edit_verb(name: &str, path: &str, old: Option<&str>) -> &'static str {
    if name.eq_ignore_ascii_case("download") {
        return "Download";
    }
    if is_plan_file(path) {
        return "Update plan";
    }
    // An empty/absent original means content is being CREATED, not modified.
    match old {
        Some(o) if o.trim().is_empty() => "Create",
        _ => "Edit",
    }
}

/// Build the trailing header spans: `+N -M` diffstat (add/delete colors) plus an
/// `Lx-y` range on the collapsed header; a muted `Lx-y` on the expanded header
/// (the worded `Added N lines…` summary already carries the counts there). A
/// multi-edit summarizes as `(N edits)` and suppresses the single diffstat.
fn build_edit_trailer(
    expanded: bool,
    is_multi: bool,
    edit_count: usize,
    stats: Option<&DiffStats>,
    theme: &crate::style::Theme,
) -> Vec<Span<'static>> {
    let mut trailer: Vec<Span<'static>> = Vec::new();
    if is_multi {
        trailer.push(Span::raw("  ".to_string()));
        trailer.push(Span::styled(
            format!("({} edit{})", edit_count, if edit_count == 1 { "" } else { "s" }),
            Style::default().fg(theme.colors.muted),
        ));
        return trailer;
    }
    let Some(s) = stats else {
        return trailer;
    };
    if !expanded {
        trailer.push(Span::raw("  ".to_string()));
        trailer.push(Span::styled(
            format!("+{}", s.added),
            Style::default().fg(theme.colors.success),
        ));
        trailer.push(Span::raw(" ".to_string()));
        trailer.push(Span::styled(
            format!("-{}", s.removed),
            Style::default().fg(theme.colors.error),
        ));
    }
    trailer.push(Span::raw("  ".to_string()));
    trailer.push(Span::styled(
        s.range_label(),
        Style::default().fg(theme.colors.dim),
    ));
    trailer
}

/// Semantic tool header: `<icon> <Verb> <path>  <trailer…>  <duration>`. The
/// verb is bold; the path is drawn in the accent/path color and carries an OSC-8
/// hyperlink to the absolute file (link on the path span only). `trailer`
/// carries the diffstat / range / edit-count spans.
fn semantic_header(
    status: super::ToolStatus,
    spinner: Option<char>,
    verb: &str,
    display_path: &str,
    full_path: &str,
    trailer: Vec<Span<'static>>,
    duration_ms: u64,
) -> Line<'static> {
    let theme = crate::style::theme();
    let (icon, icon_style) = super::status_icon(status, spinner);

    let mut spans = vec![
        Span::styled(icon, icon_style),
        Span::raw(" ".to_string()),
        Span::styled(
            verb.to_string(),
            theme.tool_name().add_modifier(Modifier::BOLD),
        ),
    ];

    if !display_path.is_empty() {
        spans.push(Span::raw(" ".to_string()));
        let path_style = Style::default().fg(theme.colors.primary);
        match crate::components::osc8::path_to_file_url(full_path) {
            Some(url) => spans.push(crate::components::osc8::hyperlink_span(
                display_path.to_string(),
                &url,
                path_style,
            )),
            None => spans.push(Span::styled(display_path.to_string(), path_style)),
        }
    }

    spans.extend(trailer);

    let dur = super::format_duration(duration_ms);
    if !dur.is_empty() {
        spans.push(Span::raw("  ".to_string()));
        spans.push(Span::styled(dur, theme.tool_duration()));
    }

    Line::from(spans)
}

/// Derive a syntect language token from a file path's extension, e.g.
/// `src/main.rs` → `Some("rs")`. Returns `None` when there is no extension, so
/// the diff renderer falls back to plain (uncolored) content. The value is a
/// bare extension; `render::syntax` normalizes aliases and resolves it against
/// the syntax set (by token, then by extension).
fn language_from_path(path: &str) -> Option<String> {
    let name = path.rsplit(['/', '\\']).next().unwrap_or(path);
    // Require a real extension: a dot that is not the leading char (so dotfiles
    // like `.gitignore` are treated as extensionless).
    let (stem, ext) = name.rsplit_once('.')?;
    if stem.is_empty() || ext.is_empty() {
        return None;
    }
    Some(ext.to_ascii_lowercase())
}

/// Inline unified diff renderer — delegates to the shared CC-style renderer
/// in `render::diff` (line-number gutter, solid +/- background bars,
/// bg-only word-level highlights, `…` hunk separators, width-aware wrapping
/// so nothing clips horizontally). `language` (a file extension / syntect token)
/// enables syntax highlighting of the code content when known.
fn render_inline_diff(
    old: &str,
    new: &str,
    width: u16,
    _theme: &crate::style::Theme,
    language: Option<&str>,
) -> Vec<Line<'static>> {
    crate::render::diff::render_diff_body(old, new, width, 1, language)
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
        let rendered = text(&render_inline_diff(old, new, 80, &theme, None));
        assert!(rendered.iter().any(|l| l.trim() == "…"), "{:?}", rendered);
    }

    #[test]
    fn heavily_rewritten_pair_skips_word_highlights() {
        let theme = crate::style::theme();
        let lines = render_inline_diff("alpha beta\n", "zq xw yv\n", 80, &theme, None);
        let has_highlight = lines.iter().flat_map(|l| l.spans.iter()).any(|s| {
            s.style.bg == Some(theme.colors.diff_add_highlight_bg)
                || s.style.bg == Some(theme.colors.diff_del_highlight_bg)
        });
        assert!(!has_highlight);
    }

    #[test]
    fn small_change_gets_word_highlights() {
        let theme = crate::style::theme();
        let lines = render_inline_diff("let count = 1;\n", "let count = 2;\n", 80, &theme, None);
        let has_highlight = lines.iter().flat_map(|l| l.spans.iter()).any(|s| {
            s.style.bg == Some(theme.colors.diff_add_highlight_bg)
                || s.style.bg == Some(theme.colors.diff_del_highlight_bg)
        });
        assert!(has_highlight);
    }

    #[test]
    fn unbalanced_runs_render_all_lines() {
        let theme = crate::style::theme();
        let lines = render_inline_diff("one\ntwo\nthree\n", "uno\n", 80, &theme, None);
        let rendered = text(&lines);
        assert_eq!(rendered.iter().filter(|l| l.contains(" - ")).count(), 3);
        assert_eq!(rendered.iter().filter(|l| l.contains(" + ")).count(), 1);
    }

    fn collapsed_opts() -> RenderOpts {
        RenderOpts {
            status: crate::tools::ToolStatus::Success,
            width: 80,
            expanded: false,
            compact: true,
            spinner_frame: None,
            duration_ms: 0,
            truncated: false,
        }
    }

    #[test]
    fn edit_header_shows_verb_path_and_diffstat() {
        // A one-line replacement: 1 added, 1 removed, on new-file line 2.
        let args = r#"{"path":"/home/x/proj/foo.rs","old_string":"line1\nline2\nline3\n","new_string":"line1\nCHANGED\nline3\n"}"#;
        let lines = FileEditRenderer.render("file_edit", args, "", &collapsed_opts());
        let header = &text(&lines)[0];
        // Semantic verb.
        assert!(header.contains("Edit"), "header verb missing: {header:?}");
        // File named by basename when collapsed.
        assert!(header.contains("foo.rs"), "header path missing: {header:?}");
        // Compact diffstat `+N -M` from the actual diff.
        assert!(header.contains("+1 -1"), "header diffstat missing: {header:?}");
        // WHERE indicator: the changed line landed on L2.
        assert!(header.contains("L2"), "header range missing: {header:?}");
    }

    #[test]
    fn create_vs_edit_verb_selection() {
        // Empty original → Create.
        let create_args = r#"{"path":"/tmp/new.rs","old_string":"","new_string":"fn main() {}\n"}"#;
        let create = text(&FileEditRenderer.render("file_edit", create_args, "", &collapsed_opts()));
        assert!(create[0].contains("Create"), "expected Create verb: {:?}", create[0]);

        // Real original → Edit.
        let edit_args = r#"{"path":"/tmp/new.rs","old_string":"fn main() {}\n","new_string":"fn main() { work(); }\n"}"#;
        let edit = text(&FileEditRenderer.render("file_edit", edit_args, "", &collapsed_opts()));
        assert!(edit[0].contains("Edit"), "expected Edit verb: {:?}", edit[0]);
        assert!(!edit[0].contains("Create"), "must not read Create: {:?}", edit[0]);

        // A plan file → Update plan.
        let plan_args = r#"{"path":"/tmp/plan.md","old_string":"- a\n","new_string":"- a\n- b\n"}"#;
        let plan = text(&FileEditRenderer.render("file_edit", plan_args, "", &collapsed_opts()));
        assert!(plan[0].contains("Update plan"), "expected Update plan: {:?}", plan[0]);
    }

    #[test]
    fn line_range_indicator_matches_hunk() {
        // Change spanning new-file lines 2..=3 (two inserted lines).
        let args = r#"{"path":"/tmp/f.rs","old_string":"a\nb\nc\n","new_string":"a\nB\nB2\nc\n"}"#;
        let header = &text(&FileEditRenderer.render("file_edit", args, "", &collapsed_opts()))[0];
        assert!(header.contains("L2-3"), "range should span L2-3: {header:?}");

        // A single-line change collapses to `L2` (no range dash).
        let one = r#"{"path":"/tmp/f.rs","old_string":"a\nb\nc\n","new_string":"a\nB\nc\n"}"#;
        let h1 = &text(&FileEditRenderer.render("file_edit", one, "", &collapsed_opts()))[0];
        assert!(h1.contains("L2") && !h1.contains("L2-"), "single line range: {h1:?}");
    }

    #[test]
    fn multiedit_summarizes_and_suppresses_single_diffstat() {
        let args = r#"{"path":"/tmp/f.rs","edits":[{"old_string":"a","new_string":"b"},{"old_string":"c","new_string":"d"},{"old_string":"e","new_string":"f"}]}"#;
        let header = &text(&FileEditRenderer.render("multiedit", args, "", &collapsed_opts()))[0];
        assert!(header.contains("(3 edits)"), "multiedit count missing: {header:?}");
        // No misleading single diffstat when several hunks are involved.
        assert!(!header.contains("+1 -1"), "must not show single diffstat: {header:?}");
    }

    #[test]
    fn unknown_or_edge_path_does_not_panic() {
        // No path key at all → placeholder basename, still renders.
        let no_path = r#"{"old_string":"a\n","new_string":"b\n"}"#;
        let lines = FileEditRenderer.render("file_edit", no_path, "", &collapsed_opts());
        assert!(!lines.is_empty(), "edge path must still render");

        // Empty args, empty result → header only, no panic.
        let empty = FileEditRenderer.render("file_edit", "", "", &collapsed_opts());
        assert!(!empty.is_empty());

        // A bare filename (no directory) relativizes/basenames without panic.
        let bare = r#"{"path":"README.md","old_string":"x\n","new_string":"y\n"}"#;
        let bare_lines = FileEditRenderer.render("file_edit", bare, "", &collapsed_opts());
        assert!(text(&bare_lines)[0].contains("README.md"));
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
