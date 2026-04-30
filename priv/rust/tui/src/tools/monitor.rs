// Monitor tool renderer.
//
// Pairs with the Elixir monitor tool at
// lib/optimal_system_agent/tools/builtins/monitor/.
//
// Tool args: {"kind": "file|process|url|command", "target": "...", "duration_seconds": <int>}

#![allow(dead_code)]

use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};

use super::{make_header, parse_json_arg, RenderOpts, ToolRenderer};

pub struct MonitorRenderer;

impl ToolRenderer for MonitorRenderer {
    fn render(
        &self,
        _name: &str,
        args: &str,
        result: &str,
        opts: &RenderOpts,
    ) -> Vec<Line<'static>> {
        let theme = crate::style::theme();

        let kind = parse_json_arg(args, &["kind"]).unwrap_or_default();
        let target = parse_json_arg(args, &["target"]).unwrap_or_default();
        let duration = parse_json_arg(args, &["duration_seconds"]).unwrap_or_default();

        let detail = if duration.is_empty() {
            format!("{}: {}", kind, target)
        } else {
            format!("{}: {} · {}s", kind, target, duration)
        };

        let header = make_header(
            opts.status,
            opts.spinner_frame,
            "Monitor",
            &detail,
            opts.duration_ms,
        );

        if !opts.expanded || result.is_empty() {
            return vec![header];
        }

        let mut body: Vec<Line<'static>> = vec![header];

        // First line is usually the summary; rest is before/after diff
        let mut iter = result.lines();
        if let Some(summary) = iter.next() {
            let style = if summary.contains("change detected") {
                Style::default()
                    .fg(theme.colors.success)
                    .add_modifier(Modifier::BOLD)
            } else if summary.contains("interrupted") {
                Style::default().fg(theme.colors.warning)
            } else {
                Style::default().fg(theme.colors.muted)
            };

            body.push(Line::from(vec![
                Span::styled("  ".to_string(), Style::default()),
                Span::styled(summary.to_string(), style),
            ]));
        }

        for line in iter {
            body.push(Line::from(vec![
                Span::styled("    ".to_string(), Style::default()),
                Span::styled(line.to_string(), Style::default().fg(theme.colors.dim)),
            ]));
        }

        body
    }
}
