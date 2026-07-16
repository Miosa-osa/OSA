use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};

use super::{
    render_tool_box, status_icon, format_duration, truncate_lines, RenderOpts, ToolRenderer,
};

pub struct McpRenderer;

impl ToolRenderer for McpRenderer {
    fn render(&self, name: &str, args: &str, result: &str, opts: &RenderOpts) -> Vec<Line<'static>> {
        let theme = crate::style::theme();

        // Parse `mcp__server__tool` convention
        let (server, tool_name) = parse_mcp_name(name);

        // Build display label: `[server] → tool`
        let detail = if server.is_empty() {
            tool_name.clone()
        } else {
            format!("[{}] → {}", server, tool_name)
        };

        let detail_display: String = if detail.len() > 55 {
            format!("{}\u{2026}", crate::util::truncate_str(&detail, 55))
        } else {
            detail
        };

        let (icon, icon_style) = status_icon(opts.status, opts.spinner_frame);
        let dur = format_duration(opts.duration_ms);

        let mut header_spans = vec![
            Span::styled(icon, icon_style),
            Span::raw(" "),
            Span::styled(
                "MCP".to_string(),
                Style::default()
                    .fg(theme.colors.secondary)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::raw("  "),
            Span::styled(detail_display, theme.tool_arg()),
        ];

        if !dur.is_empty() {
            header_spans.push(Span::raw("  "));
            header_spans.push(Span::styled(dur, theme.tool_duration()));
        }

        let header = Line::from(header_spans);

        if !opts.expanded {
            return vec![header];
        }

        // Expanded body
        let mut body: Vec<Line<'static>> = Vec::new();

        // Show args summary
        if !args.is_empty() && args != "{}" {
            let args_display: String = if args.len() > 80 {
                format!("{}\u{2026}", crate::util::truncate_str(args, 80))
            } else {
                args.to_string()
            };
            body.push(Line::from(vec![
                Span::styled("args  ".to_string(), Style::default().fg(theme.colors.dim)),
                Span::styled(args_display, theme.faint()),
            ]));
        }

        // Separator
        body.push(Line::from(Span::styled(
            "─".repeat(opts.width.saturating_sub(4) as usize),
            Style::default().fg(theme.colors.dim),
        )));

        // Result — try pretty-print JSON, fall back to plain
        let result_lines = if result.starts_with('{') || result.starts_with('[') {
            pretty_json_lines(result, &theme)
        } else {
            result
                .lines()
                .map(|l| Line::from(Span::styled(l.to_string(), theme.faint())))
                .collect()
        };

        body.extend(result_lines);

        let max_lines = if opts.compact { 8 } else { 15 };
        let body = truncate_lines(body, max_lines);

        render_tool_box(header, body)
    }
}

/// Parse `mcp__server__tool` → `(server, tool)`.
/// Also handles `mcp_tool`, `mcp`, or plain names.
fn parse_mcp_name(name: &str) -> (String, String) {
    // Strip leading `mcp__` prefix
    if let Some(rest) = name.strip_prefix("mcp__") {
        // Split on next `__`
        if let Some(idx) = rest.find("__") {
            let server = rest[..idx].to_string();
            let tool = rest[idx + 2..].to_string();
            return (server, tool);
        }
        // Only server, no tool suffix
        return (rest.to_string(), String::new());
    }

    // `mcp_tool` or generic `mcp`
    (String::new(), name.to_string())
}

/// Render JSON value as colored lines (simple heuristic, not full pretty-printer).
fn pretty_json_lines(json_str: &str, theme: &crate::style::Theme) -> Vec<Line<'static>> {
    // Use serde_json to pretty-print
    let pretty = serde_json::from_str::<serde_json::Value>(json_str)
        .ok()
        .and_then(|v| serde_json::to_string_pretty(&v).ok())
        .unwrap_or_else(|| json_str.to_string());

    pretty
        .lines()
        .map(|l| {
            let trimmed = l.trim_start();
            let style = if trimmed.starts_with('"') && trimmed.contains(':') {
                // Key
                Style::default().fg(theme.colors.secondary)
            } else if trimmed.starts_with('"') {
                // String value
                Style::default().fg(theme.colors.success)
            } else if trimmed == "{" || trimmed == "}" || trimmed == "[" || trimmed == "]"
                || trimmed == "}," || trimmed == "],"
            {
                Style::default().fg(theme.colors.muted)
            } else {
                theme.faint()
            };
            Line::from(Span::styled(l.to_string(), style))
        })
        .collect()
}
