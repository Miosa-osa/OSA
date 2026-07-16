use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};

use super::{
    format_duration, parse_json_arg, render_tool_box, status_icon, truncate_lines, RenderOpts,
    ToolRenderer, ToolStatus,
};

// ─── AgentRenderer ────────────────────────────────────────────────────────────

pub struct AgentRenderer;

impl ToolRenderer for AgentRenderer {
    fn render(&self, _name: &str, args: &str, result: &str, opts: &RenderOpts) -> Vec<Line<'static>> {
        let theme = crate::style::theme();

        let task_name = parse_json_arg(args, &["task", "description", "name", "input", "prompt"])
            .unwrap_or_else(|| "agent task".to_string());

        let task_display: String = if task_name.len() > 50 {
            format!("{}…", &task_name[..50])
        } else {
            task_name.clone()
        };

        // Agent uses special ◈ icon regardless of status — except for error/cancel
        let (status_icon_str, status_icon_style) = match opts.status {
            ToolStatus::Error | ToolStatus::Canceled => {
                status_icon(opts.status, opts.spinner_frame)
            }
            _ => (
                "◈".to_string(),
                Style::default()
                    .fg(theme.colors.primary)
                    .add_modifier(Modifier::BOLD),
            ),
        };

        // Count tool calls in result (naive: count lines starting with ✓/✘/⏺)
        let tool_count = result
            .lines()
            .filter(|l| {
                let t = l.trim();
                t.starts_with('✓') || t.starts_with('✘') || t.starts_with('⏺')
            })
            .count();

        let dur = format_duration(opts.duration_ms);

        // Build header
        let mut header_spans = vec![
            Span::styled(status_icon_str, status_icon_style),
            Span::raw(" "),
            Span::styled(
                "Agent".to_string(),
                Style::default()
                    .fg(theme.colors.secondary)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::raw("  "),
            Span::styled(task_display, theme.tool_arg()),
        ];

        if !opts.expanded {
            // Collapsed summary: "3 tools, 1.7s"
            let mut summary_parts: Vec<String> = Vec::new();
            if tool_count > 0 {
                summary_parts.push(format!("{} tools", tool_count));
            }
            if !dur.is_empty() {
                summary_parts.push(dur.clone());
            }
            if !summary_parts.is_empty() {
                header_spans.push(Span::raw("  "));
                header_spans.push(Span::styled(
                    summary_parts.join(", "),
                    theme.tool_duration(),
                ));
            }
            return vec![Line::from(header_spans)];
        }

        if !dur.is_empty() {
            header_spans.push(Span::raw("  "));
            header_spans.push(Span::styled(dur, theme.tool_duration()));
        }

        let header = Line::from(header_spans);

        // Expanded body: render result lines as tree
        let mut body: Vec<Line<'static>> = Vec::new();
        let result_lines: Vec<&str> = result.lines().collect();
        let last_idx = result_lines.len().saturating_sub(1);

        for (idx, line) in result_lines.iter().enumerate() {
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }

            let connector = if idx == last_idx { "└─" } else { "├─" };
            let (prefix_icon, prefix_style) = parse_tree_line_prefix(trimmed, &theme);

            body.push(Line::from(vec![
                Span::styled(
                    format!("{} ", connector),
                    Style::default().fg(theme.colors.muted),
                ),
                Span::styled(prefix_icon, prefix_style),
                Span::raw(" "),
                Span::styled(trimmed.to_string(), theme.faint()),
            ]));
        }

        let max_lines = if opts.compact { 8 } else { 20 };
        let body = truncate_lines(body, max_lines);

        render_tool_box(header, body)
    }
}

/// Detect if a tree line starts with a known status icon and return that
/// icon plus an appropriate style.
fn parse_tree_line_prefix(
    line: &str,
    theme: &crate::style::Theme,
) -> (String, Style) {
    if line.starts_with('✓') {
        (
            "✓".to_string(),
            Style::default().fg(theme.colors.success).add_modifier(Modifier::BOLD),
        )
    } else if line.starts_with('✘') {
        (
            "✘".to_string(),
            Style::default().fg(theme.colors.error).add_modifier(Modifier::BOLD),
        )
    } else if line.starts_with('◈') {
        (
            "◈".to_string(),
            Style::default().fg(theme.colors.primary).add_modifier(Modifier::BOLD),
        )
    } else if line.starts_with('⏺') || line.starts_with('●') {
        (
            crate::tools::tool_bullet().to_string(), // ● (Linux) / ⏺ (macOS)
            Style::default().fg(theme.colors.primary).add_modifier(Modifier::BOLD),
        )
    } else {
        (
            "·".to_string(),
            Style::default().fg(theme.colors.muted),
        )
    }
}

// ─── DelegateRenderer ─────────────────────────────────────────────────────────

pub struct DelegateRenderer;

impl ToolRenderer for DelegateRenderer {
    fn render(&self, _name: &str, args: &str, result: &str, opts: &RenderOpts) -> Vec<Line<'static>> {
        let theme = crate::style::theme();

        let task = parse_json_arg(args, &["task", "description", "input", "prompt"])
            .unwrap_or_else(|| "delegate task".to_string());

        let tier = parse_json_arg(args, &["tier", "model_tier", "agent_tier"])
            .unwrap_or_default();

        // Truncate task to 80 chars
        let task_display: String = if task.len() > 80 {
            format!("{}…", &task[..80])
        } else {
            task
        };

        let (icon, icon_style) = status_icon(opts.status, opts.spinner_frame);
        let mut header_spans = vec![
            Span::styled(icon, icon_style),
            Span::raw(" "),
            Span::styled("Delegate".to_string(), theme.tool_name()),
            Span::raw("  "),
            Span::styled(task_display, theme.tool_arg()),
        ];

        if !tier.is_empty() {
            header_spans.push(Span::raw("  "));
            header_spans.push(Span::styled(
                format!("[{}]", tier),
                Style::default().fg(theme.colors.muted),
            ));
        }

        let dur = format_duration(opts.duration_ms);
        if !dur.is_empty() {
            header_spans.push(Span::raw("  "));
            header_spans.push(Span::styled(dur, theme.tool_duration()));
        }

        let header = Line::from(header_spans);

        if !opts.expanded {
            // Collapsed: show first line of result
            let first_line = result.lines().next().unwrap_or("").trim().to_string();
            if !first_line.is_empty() {
                return vec![
                    header,
                    Line::from(Span::styled(
                        format!("  {}", first_line),
                        theme.faint(),
                    )),
                ];
            }
            return vec![header];
        }

        let mut body: Vec<Line<'static>> = Vec::new();
        for line in result.lines() {
            body.push(Line::from(Span::styled(line.to_string(), theme.faint())));
        }

        let max_lines = if opts.compact { 8 } else { 20 };
        let body = truncate_lines(body, max_lines);

        render_tool_box(header, body)
    }
}
