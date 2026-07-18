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
            // CC parity (OutputLine/renderTruncatedContent): up to 3 dimmed
            // output lines under a `⎿` connector; exactly 4 lines print in
            // full (CC's remainingLines==1 special case); more get a dim
            // "… +N lines (ctrl+o to expand)" hint. Errors render red.
            let trimmed = result.trim_end();
            if trimmed.is_empty() {
                return vec![header];
            }
            let out_style = if opts.status == ToolStatus::Error {
                Style::default().fg(theme.colors.error)
            } else {
                Style::default().fg(theme.colors.muted)
            };
            const MAX_LINES_TO_SHOW: usize = 3;
            let all: Vec<&str> = trimmed.lines().collect();
            let shown = if all.len() == MAX_LINES_TO_SHOW + 1 {
                all.len() // exactly one extra line: just show it
            } else {
                all.len().min(MAX_LINES_TO_SHOW)
            };
            let mut body: Vec<Line<'static>> = Vec::with_capacity(shown + 1);
            for line in &all[..shown] {
                body.push(Line::from(Span::styled((*line).to_string(), out_style)));
            }
            if all.len() > shown {
                body.push(Line::from(Span::styled(
                    format!("… +{} lines (ctrl+o to expand)", all.len() - shown),
                    Style::default().fg(theme.colors.dim),
                )));
            }
            return render_tool_box(header, body);
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

#[cfg(test)]
mod collapsed_output_tests {
    use super::*;

    fn opts() -> RenderOpts {
        RenderOpts {
            status: ToolStatus::Success,
            width: 80,
            expanded: false,
            compact: true,
            spinner_frame: None,
            duration_ms: 10,
            truncated: false,
        }
    }

    fn flat(lines: &[Line<'_>]) -> Vec<String> {
        lines
            .iter()
            .map(|l| l.spans.iter().map(|s| s.content.as_ref()).collect::<String>())
            .collect()
    }

    #[test]
    fn collapsed_output_caps_at_three_lines_with_expand_hint() {
        let result = "l1\nl2\nl3\nl4\nl5\nl6";
        let lines = BashRenderer.render("Bash", r#"{"command":"seq 6"}"#, result, &opts());
        let rendered = flat(&lines);
        assert!(rendered[1].starts_with("  \u{23bf}  l1"), "{:?}", rendered);
        assert!(
            rendered.last().unwrap().contains("+3 lines (ctrl+o to expand)"),
            "{:?}",
            rendered
        );
    }

    #[test]
    fn exactly_four_lines_render_in_full() {
        let result = "l1\nl2\nl3\nl4";
        let lines = BashRenderer.render("Bash", r#"{"command":"seq 4"}"#, result, &opts());
        let rendered = flat(&lines);
        assert_eq!(rendered.len(), 5, "{:?}", rendered); // header + all 4 lines
        assert!(!rendered.last().unwrap().contains("ctrl+o"), "{:?}", rendered);
    }
}
