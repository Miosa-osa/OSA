use ratatui::style::Style;
use ratatui::text::{Line, Span};

use super::{
    make_header, render_tool_box, truncate_lines, RenderOpts, ToolRenderer,
};

/// Fallback renderer for all unregistered tools.
pub struct GenericRenderer;

impl ToolRenderer for GenericRenderer {
    fn render(&self, name: &str, args: &str, result: &str, opts: &RenderOpts) -> Vec<Line<'static>> {
        let theme = crate::style::theme();

        // Use the raw tool name as display, collapse args into a short preview
        let args_preview = args_summary(args);

        let header = make_header(
            opts.status,
            opts.spinner_frame,
            name,
            &args_preview,
            opts.duration_ms,
        );

        if !opts.expanded {
            return vec![header];
        }

        let mut body: Vec<Line<'static>> = Vec::new();

        // Try pretty-print JSON result
        let result_lines: Vec<Line<'static>> =
            if result.starts_with('{') || result.starts_with('[') {
                render_json(result, &theme)
            } else {
                result
                    .lines()
                    .map(|l| Line::from(Span::styled(l.to_string(), theme.faint())))
                    .collect()
            };

        body.extend(result_lines);

        let max_lines = if opts.compact { 6 } else { 10 };
        let body = truncate_lines(body, max_lines);

        render_tool_box(header, body)
    }
}

/// Build a short summary of the args for display in the header.
fn args_summary(args: &str) -> String {
    let trimmed = args.trim();
    if trimmed.is_empty() || trimmed == "{}" {
        return String::new();
    }

    // Try to extract the first string value from JSON
    if let Ok(v) = serde_json::from_str::<serde_json::Value>(trimmed) {
        if let Some(obj) = v.as_object() {
            for val in obj.values() {
                if let Some(s) = val.as_str() {
                    let preview: String = s.chars().take(50).collect();
                    return if s.len() > 50 {
                        format!("{}…", preview)
                    } else {
                        preview
                    };
                }
            }
        }
        // Compact JSON as fallback
        let compact = v.to_string();
        return if compact.len() > 60 {
            format!("{}\u{2026}", crate::util::truncate_str(&compact, 60))
        } else {
            compact
        };
    }

    // Plain string args
    let preview: String = trimmed.chars().take(60).collect();
    if trimmed.len() > 60 {
        format!("{}…", preview)
    } else {
        preview
    }
}

/// Render JSON with basic key/value coloring.
fn render_json(json_str: &str, theme: &crate::style::Theme) -> Vec<Line<'static>> {
    let pretty = serde_json::from_str::<serde_json::Value>(json_str)
        .ok()
        .and_then(|v| serde_json::to_string_pretty(&v).ok())
        .unwrap_or_else(|| json_str.to_string());

    pretty
        .lines()
        .map(|l| {
            let trimmed = l.trim_start();
            let style: Style = if trimmed.starts_with('"') && trimmed.contains(':') {
                Style::default().fg(theme.colors.secondary)
            } else if trimmed.starts_with('"') {
                Style::default().fg(theme.colors.success)
            } else if trimmed.parse::<f64>().is_ok() {
                Style::default().fg(theme.colors.warning)
            } else if trimmed == "true" || trimmed == "false" || trimmed == "null"
                || trimmed.starts_with("true,") || trimmed.starts_with("false,")
            {
                Style::default().fg(theme.colors.primary)
            } else {
                theme.faint()
            };
            Line::from(Span::styled(l.to_string(), style))
        })
        .collect()
}
