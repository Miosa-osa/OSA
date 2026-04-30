// Sleep tool renderer.
//
// Pairs with the Elixir sleep tool at
// lib/optimal_system_agent/tools/builtins/sleep/.
//
// Tool args: {"seconds": <int>, "reason": "..."}

#![allow(dead_code)]

use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};

use super::{make_header, parse_json_arg, RenderOpts, ToolRenderer};

pub struct SleepRenderer;

impl ToolRenderer for SleepRenderer {
    fn render(
        &self,
        _name: &str,
        args: &str,
        result: &str,
        opts: &RenderOpts,
    ) -> Vec<Line<'static>> {
        let theme = crate::style::theme();

        let seconds = parse_json_arg(args, &["seconds"]).unwrap_or_default();
        let reason = parse_json_arg(args, &["reason"]).unwrap_or_default();

        let detail = if reason.is_empty() {
            format!("{}s", seconds)
        } else {
            format!("{}s · {}", seconds, reason)
        };

        let header = make_header(opts.status, opts.spinner_frame, "Sleep", &detail, opts.duration_ms);

        if !opts.expanded || result.is_empty() {
            return vec![header];
        }

        let mut body: Vec<Line<'static>> = vec![header];

        for line in result.lines() {
            body.push(Line::from(vec![
                Span::styled("  ".to_string(), Style::default()),
                Span::styled(
                    line.to_string(),
                    Style::default()
                        .fg(theme.colors.muted)
                        .add_modifier(Modifier::ITALIC),
                ),
            ]));
        }

        body
    }
}
