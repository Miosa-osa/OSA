use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};

use super::{
    make_header, parse_json_arg, render_tool_box, truncate_lines, RenderOpts, ToolRenderer,
};

/// CC's SearchResultSummary collapsed row: `Found N files  (ctrl+o to expand)`
/// — bold count, singular/plural noun, dim expand hint only when N > 0.
fn found_line(verb: &str, n: usize, singular: &str, plural: &str) -> Line<'static> {
    let theme = crate::style::theme();
    let noun = if n == 1 { singular } else { plural };
    let mut spans = vec![
        Span::raw(format!("{} ", verb)),
        Span::styled(n.to_string(), Style::default().add_modifier(Modifier::BOLD)),
        Span::raw(format!(" {}", noun)),
    ];
    if n > 0 {
        spans.push(Span::styled(
            "  (ctrl+o to expand)".to_string(),
            Style::default().fg(theme.colors.dim),
        ));
    }
    Line::from(spans)
}

/// Header-only while the tool is still running (avoids bogus "Found 0 …").
fn resolved(status: super::ToolStatus) -> bool {
    matches!(status, super::ToolStatus::Success | super::ToolStatus::Error)
}

// ─── GlobRenderer ─────────────────────────────────────────────────────────────

pub struct GlobRenderer;

impl ToolRenderer for GlobRenderer {
    fn render(&self, _name: &str, args: &str, result: &str, opts: &RenderOpts) -> Vec<Line<'static>> {
        let theme = crate::style::theme();

        let pattern =
            parse_json_arg(args, &["pattern", "glob", "query", "regex", "path"])
                .unwrap_or_else(|| "…".to_string());

        let header = make_header(
            opts.status,
            opts.spinner_frame,
            "Glob",
            &pattern,
            opts.duration_ms,
        );

        if !opts.expanded {
            if !resolved(opts.status) {
                return vec![header];
            }
            let n = result.lines().filter(|l| !l.trim().is_empty()).count();
            return render_tool_box(header, vec![found_line("Found", n, "file", "files")]);
        }

        let file_style = Style::default()
            .fg(theme.colors.secondary)
            .add_modifier(Modifier::UNDERLINED);

        let mut body: Vec<Line<'static>> = Vec::new();
        let mut count = 0usize;

        for path in result.lines() {
            if path.trim().is_empty() {
                continue;
            }
            body.push(Line::from(Span::styled(path.to_string(), file_style)));
            count += 1;
        }

        // Footer
        body.push(Line::from(Span::styled(
            format!("({} files)", count),
            Style::default().fg(theme.colors.dim),
        )));

        let max_lines = if opts.compact { 8 } else { 15 };
        let body = truncate_lines(body, max_lines);

        render_tool_box(header, body)
    }
}

// ─── GrepRenderer ─────────────────────────────────────────────────────────────

pub struct GrepRenderer;

impl ToolRenderer for GrepRenderer {
    fn render(&self, _name: &str, args: &str, result: &str, opts: &RenderOpts) -> Vec<Line<'static>> {
        let theme = crate::style::theme();

        let pattern =
            parse_json_arg(args, &["pattern", "query", "regex", "search", "input"])
                .unwrap_or_else(|| "…".to_string());

        let header = make_header(
            opts.status,
            opts.spinner_frame,
            "Grep",
            &pattern,
            opts.duration_ms,
        );

        if !opts.expanded {
            if !resolved(opts.status) {
                return vec![header];
            }
            let n = result.lines().filter(|l| !l.trim().is_empty()).count();
            return render_tool_box(header, vec![found_line("Found", n, "line", "lines")]);
        }

        let file_style = Style::default()
            .fg(theme.colors.secondary)
            .add_modifier(Modifier::UNDERLINED);
        let rest_style = Style::default().fg(theme.colors.muted);

        let mut body: Vec<Line<'static>> = Vec::new();
        let mut count = 0usize;

        for raw_line in result.lines() {
            if raw_line.trim().is_empty() {
                continue;
            }
            count += 1;
            // Attempt to parse file:line:content format
            let line = render_grep_line(raw_line, file_style, rest_style);
            body.push(line);
        }

        body.push(Line::from(Span::styled(
            format!("({} results)", count),
            Style::default().fg(theme.colors.dim),
        )));

        let max_lines = if opts.compact { 8 } else { 15 };
        let body = truncate_lines(body, max_lines);

        render_tool_box(header, body)
    }
}

/// Split `file:line:content` and style the file portion in cyan+underline.
fn render_grep_line(
    raw: &str,
    file_style: Style,
    rest_style: Style,
) -> Line<'static> {
    // Try to split off file component (first segment before a colon that looks
    // like a path — does not start with a digit).
    let parts: Vec<&str> = raw.splitn(3, ':').collect();
    if parts.len() >= 3 {
        let file_part = parts[0];
        let line_part = parts[1];
        let content_part = parts[2];

        // Heuristic: if the first part contains a `/` or `.` it's a path
        if file_part.contains('/') || file_part.contains('.') {
            return Line::from(vec![
                Span::styled(file_part.to_string(), file_style),
                Span::styled(":".to_string(), rest_style),
                Span::styled(line_part.to_string(), rest_style),
                Span::styled(":".to_string(), rest_style),
                Span::styled(content_part.to_string(), rest_style),
            ]);
        }
    }

    Line::from(Span::styled(raw.to_string(), rest_style))
}

// ─── LsRenderer ───────────────────────────────────────────────────────────────

pub struct LsRenderer;

impl ToolRenderer for LsRenderer {
    fn render(&self, _name: &str, args: &str, result: &str, opts: &RenderOpts) -> Vec<Line<'static>> {
        let theme = crate::style::theme();

        let path = parse_json_arg(args, &["path", "directory", "dir", "input"])
            .unwrap_or_else(|| ".".to_string());

        let header = make_header(
            opts.status,
            opts.spinner_frame,
            "LS",
            &path,
            opts.duration_ms,
        );

        if !opts.expanded {
            if !resolved(opts.status) {
                return vec![header];
            }
            let n = result.lines().filter(|l| !l.trim().is_empty()).count();
            return render_tool_box(header, vec![found_line("Listed", n, "path", "paths")]);
        }

        let dir_style = Style::default()
            .fg(theme.colors.secondary)
            .add_modifier(Modifier::BOLD);
        let file_style = Style::default().fg(theme.colors.muted);

        // Separate dirs (trailing /) from files
        let mut dirs: Vec<String> = Vec::new();
        let mut files: Vec<String> = Vec::new();

        for entry in result.lines() {
            let trimmed = entry.trim().to_string();
            if trimmed.is_empty() {
                continue;
            }
            if trimmed.ends_with('/') {
                dirs.push(trimmed);
            } else {
                files.push(trimmed);
            }
        }

        let col_width = (opts.width.saturating_sub(6) / 2).max(20) as usize;
        let mut body: Vec<Line<'static>> = Vec::new();

        // Render dirs first, then files — two per row where space allows
        let all_dirs: Vec<Line<'static>> = dirs
            .iter()
            .map(|d| Line::from(Span::styled(d.clone(), dir_style)))
            .collect();
        let all_files: Vec<Line<'static>> = files
            .iter()
            .map(|f| Line::from(Span::styled(f.clone(), file_style)))
            .collect();

        // Columnar layout: pair up entries
        let pairs = pair_columns(&dirs, col_width, dir_style)
            .into_iter()
            .chain(pair_columns(&files, col_width, file_style));

        for line in pairs {
            body.push(line);
        }

        // Fallback if pairing produced nothing (e.g., single entry)
        if body.is_empty() {
            body.extend(all_dirs);
            body.extend(all_files);
        }

        let max_lines = if opts.compact { 10 } else { 20 };
        let body = truncate_lines(body, max_lines);

        render_tool_box(header, body)
    }
}

/// Lay out `entries` two per line, each padded to `col_width`.
fn pair_columns(entries: &[String], col_width: usize, style: Style) -> Vec<Line<'static>> {
    let mut lines = Vec::new();
    let mut iter = entries.iter().peekable();
    while let Some(left) = iter.next() {
        let left_padded = format!("{:<width$}", left, width = col_width);
        if let Some(right) = iter.next() {
            lines.push(Line::from(vec![
                Span::styled(left_padded, style),
                Span::styled("  ".to_string(), Style::default()),
                Span::styled(right.clone(), style),
            ]));
        } else {
            lines.push(Line::from(Span::styled(left_padded, style)));
        }
    }
    lines
}
