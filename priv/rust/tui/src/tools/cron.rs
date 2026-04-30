// Cron / Schedule tool renderer.
//
// Pairs with the Elixir cron tool at
// lib/optimal_system_agent/tools/builtins/cron/.
//
// Tool args shape:
//   {"action": "create", "task": "...", "schedule": "0 */6 * * *"}
//   {"action": "list"}
//   {"action": "delete", "job_id": "..."}
//   {"action": "trigger", "job_id": "..."}

#![allow(dead_code)]

use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};

use super::{make_header, parse_json_arg, status_icon, RenderOpts, ToolRenderer};

pub struct CronRenderer;

impl ToolRenderer for CronRenderer {
    fn render(
        &self,
        _name: &str,
        args: &str,
        result: &str,
        opts: &RenderOpts,
    ) -> Vec<Line<'static>> {
        let theme = crate::style::theme();

        let action = parse_json_arg(args, &["action"]).unwrap_or_else(|| "?".to_string());

        // Per-action header text + detail
        let (label, detail) = match action.as_str() {
            "create" => {
                let task = parse_json_arg(args, &["task"]).unwrap_or_default();
                let schedule = parse_json_arg(args, &["schedule"]).unwrap_or_default();
                let detail = if schedule.is_empty() {
                    task.clone()
                } else {
                    format!("{}  ·  {}", task, schedule)
                };
                ("Schedule", detail)
            }
            "list" => ("Schedule list", String::new()),
            "delete" => {
                let job_id = parse_json_arg(args, &["job_id"]).unwrap_or_default();
                ("Schedule remove", job_id)
            }
            "trigger" => {
                let job_id = parse_json_arg(args, &["job_id"]).unwrap_or_default();
                ("Schedule fire", job_id)
            }
            other => ("Schedule", other.to_string()),
        };

        let header = make_header(
            opts.status,
            opts.spinner_frame,
            label,
            &detail,
            opts.duration_ms,
        );

        if !opts.expanded || result.is_empty() {
            return vec![header];
        }

        let mut body: Vec<Line<'static>> = vec![header];

        match action.as_str() {
            "list" => render_job_list(&mut body, result, &theme),
            "create" => render_create_result(&mut body, result, &theme),
            _ => render_plain_result(&mut body, result, &theme),
        }

        body
    }
}

fn render_job_list(body: &mut Vec<Line<'static>>, result: &str, theme: &crate::style::Theme) {
    // Lines from the Elixir handler look like:
    //   "abc123 | 0 */6 * * * | Update news feed | enabled"
    // or one per row, separated however the handler emits. We render best-effort.
    for line in result.lines() {
        if line.trim().is_empty() {
            continue;
        }

        // Best-effort split on " | " — fall back to raw line.
        let parts: Vec<&str> = line.splitn(4, " | ").collect();
        if parts.len() == 4 {
            let id = parts[0].trim();
            let schedule = parts[1].trim();
            let task = parts[2].trim();
            let status = parts[3].trim();

            let status_style = if status.eq_ignore_ascii_case("enabled") {
                Style::default().fg(theme.colors.success)
            } else {
                Style::default().fg(theme.colors.muted)
            };

            body.push(Line::from(vec![
                Span::styled("  ".to_string(), Style::default()),
                Span::styled(
                    id.to_string(),
                    Style::default()
                        .fg(theme.colors.muted)
                        .add_modifier(Modifier::DIM),
                ),
                Span::raw("  "),
                Span::styled(
                    schedule.to_string(),
                    Style::default().fg(theme.colors.secondary),
                ),
                Span::raw("  "),
                Span::styled(task.to_string(), Style::default().fg(theme.colors.primary)),
                Span::raw("  "),
                Span::styled(status.to_string(), status_style),
            ]));
        } else {
            body.push(Line::from(Span::styled(
                line.to_string(),
                Style::default().fg(theme.colors.muted),
            )));
        }
    }
}

fn render_create_result(body: &mut Vec<Line<'static>>, result: &str, theme: &crate::style::Theme) {
    for line in result.lines() {
        body.push(Line::from(vec![
            Span::styled("  ".to_string(), Style::default()),
            Span::styled(line.to_string(), Style::default().fg(theme.colors.success)),
        ]));
    }
}

fn render_plain_result(body: &mut Vec<Line<'static>>, result: &str, theme: &crate::style::Theme) {
    for line in result.lines() {
        body.push(Line::from(Span::styled(
            line.to_string(),
            Style::default().fg(theme.colors.muted),
        )));
    }
    let _ = status_icon; // keep import used across configurations
    let _ = Color::Reset;
}
