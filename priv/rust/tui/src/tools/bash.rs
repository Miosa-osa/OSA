use ratatui::style::Style;
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
            // The capped execute block: a bounded head+tail window over the
            // command's output with the elision marker between the halves, so a
            // long run shows both what it started doing and how it ended. A
            // head-only fold spent this cell's whole budget on a build's
            // `Compiling …` preamble and hid the error that made it interesting.
            // Errors render red; finished-but-empty shows "(No output)".
            let body = super::collapse::capped_execute_block(
                result,
                opts.width,
                opts.status == ToolStatus::Error,
            );
            if body.is_empty() {
                if !matches!(opts.status, ToolStatus::Success | ToolStatus::Error) {
                    return vec![header];
                }
                return render_tool_box(
                    header,
                    vec![Line::from(Span::styled(
                        "(No output)".to_string(),
                        Style::default().fg(theme.colors.dim),
                    ))],
                );
            }
            return render_tool_box(header, body);
        }

        // Expanded body
        let mut body: Vec<Line<'static>> = Vec::new();

        // Full command line — dim `$ ` prefix + light bash syntax coloring.
        body.push(Line::from(super::collapse::shell_command_spans(&command)));

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

        // Output body — JSON pretty-print + URL linkify + panel background,
        // width-wrapped. stderr/error status renders in the error color.
        body.extend(super::collapse::enhanced_output_lines(
            result,
            opts.width,
            opts.status == ToolStatus::Error,
        ));

        // CC parity: expanded (ctrl+o / verbose) shows the full output; only
        // compact contexts keep a cap.
        let body = if opts.compact {
            truncate_lines(body, 8)
        } else {
            body
        };

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

    /// The collapsed cell is a head+tail window, not a head-only fold: the first
    /// row of output hangs off the `⎿` connector, the elision marker sits in the
    /// middle counting exactly what it hides, and the command's LAST rows — the
    /// ones carrying its verdict — are the ones that survive.
    #[test]
    fn collapsed_output_keeps_the_tail_and_counts_the_middle() {
        let result = "l1\nl2\nl3\nl4\nl5\nl6";
        let lines = BashRenderer.render("Bash", r#"{"command":"seq 6"}"#, result, &opts());
        let rendered = flat(&lines);
        assert_eq!(rendered.len(), 5, "header + 1 head + marker + 2 tail: {rendered:?}");
        assert!(rendered[1].starts_with("  \u{23bf}  l1"), "{rendered:?}");
        assert!(
            rendered[2].contains("+3 lines (ctrl+o to expand)"),
            "the marker sits between the halves: {rendered:?}"
        );
        assert!(rendered[3].contains("l5"), "{rendered:?}");
        assert!(rendered[4].contains("l6"), "{rendered:?}");
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
