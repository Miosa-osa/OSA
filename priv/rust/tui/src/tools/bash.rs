use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};

use super::{
    make_header, parse_json_arg, render_tool_box, truncate_lines, RenderOpts, ToolRenderer,
    ToolStatus,
};

pub struct BashRenderer;

impl ToolRenderer for BashRenderer {
    fn render(&self, _name: &str, args: &str, result: &str, opts: &RenderOpts) -> Vec<Line<'static>> {
        let theme = crate::style::theme();

        // Extract command from args JSON
        let command = parse_json_arg(args, &["command", "cmd", "input"])
            .unwrap_or_else(|| args.chars().take(60).collect());

        // Detect background job
        let is_background = {
            let v = serde_json::from_str::<serde_json::Value>(args).ok();
            v.and_then(|v| v.get("run_in_background").and_then(|b| b.as_bool()))
                .unwrap_or(false)
        };

        // Collapsed header — truncate command to ~50 chars
        let cmd_display: String = if command.len() > 50 {
            format!("{}\u{2026}", crate::util::truncate_str(&command, 50))
        } else {
            command.clone()
        };

        let header = make_header(
            opts.status,
            opts.spinner_frame,
            "Bash",
            &cmd_display,
            opts.duration_ms,
        );

        if !opts.expanded {
            // Show 1-line result preview if available
            if !result.is_empty() {
                let first_line = result.lines().next().unwrap_or("").trim();
                if !first_line.is_empty() {
                    let preview: String = if first_line.len() > 60 {
                        format!("{}\u{2026}", crate::util::truncate_str(first_line, 60))
                    } else {
                        first_line.to_string()
                    };
                    let result_line = Line::from(vec![
                        Span::styled("  └ ".to_string(), Style::default().fg(theme.colors.muted)),
                        Span::styled(preview, Style::default().fg(theme.colors.muted)),
                    ]);
                    return vec![header, result_line];
                }
            }
            return vec![header];
        }

        // Expanded body
        let mut body: Vec<Line<'static>> = Vec::new();

        // Full command line
        body.push(Line::from(vec![
            Span::styled("$ ".to_string(), Style::default().fg(theme.colors.muted)),
            Span::styled(
                command,
                Style::default()
                    .fg(theme.colors.secondary)
                    .add_modifier(Modifier::BOLD),
            ),
        ]));

        // Background marker
        if is_background {
            body.push(Line::from(Span::styled(
                "⚙ background job".to_string(),
                Style::default().fg(theme.colors.muted),
            )));
        }

        // Separator
        body.push(Line::from(Span::styled(
            "─".repeat(opts.width.saturating_sub(4) as usize),
            Style::default().fg(theme.colors.dim),
        )));

        // Output lines
        let output_style = if opts.status == ToolStatus::Error {
            Style::default().fg(theme.colors.error)
        } else {
            Style::default().fg(theme.colors.muted)
        };

        for line in result.lines() {
            body.push(Line::from(Span::styled(line.to_string(), output_style)));
        }

        let max_lines = if opts.compact { 8 } else { 15 };
        let body = truncate_lines(body, max_lines);

        render_tool_box(header, body)
    }
}
