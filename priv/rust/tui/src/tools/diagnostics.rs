use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};

use super::{make_header, render_tool_box, truncate_lines, RenderOpts, ToolRenderer};

pub struct DiagnosticsRenderer;

impl ToolRenderer for DiagnosticsRenderer {
    fn render(
        &self,
        _name: &str,
        _args: &str,
        result: &str,
        opts: &RenderOpts,
    ) -> Vec<Line<'static>> {
        let theme = crate::style::theme();

        // Parse entries from result JSON
        let entries = parse_diagnostics(result);

        let (error_count, warning_count, info_count) = count_severities(&entries);

        // Build summary string for header detail
        let mut summary_parts: Vec<String> = Vec::new();
        if error_count > 0 {
            summary_parts.push(format!("{} errors", error_count));
        }
        if warning_count > 0 {
            summary_parts.push(format!("{} warnings", warning_count));
        }
        if info_count > 0 {
            summary_parts.push(format!("{} info", info_count));
        }
        let summary = if summary_parts.is_empty() {
            "no issues".to_string()
        } else {
            summary_parts.join(", ")
        };

        let header = make_header(
            opts.status,
            opts.spinner_frame,
            "Diagnostics",
            &summary,
            opts.duration_ms,
        );

        if !opts.expanded {
            return vec![header];
        }

        let mut body: Vec<Line<'static>> = Vec::new();

        if entries.is_empty() {
            // Try plain-text rendering
            for line in result.lines() {
                let (icon, style, rest) = classify_plain_line(line.trim(), &theme);
                body.push(Line::from(vec![
                    Span::styled(icon, style),
                    Span::raw(" "),
                    Span::styled(rest.to_string(), style),
                ]));
            }
        } else {
            for entry in &entries {
                let (icon, icon_style) = severity_icon(&entry.severity, &theme);
                let file_display = match (&entry.file, entry.line) {
                    (Some(f), Some(l)) => format!("{}:{}", f, l),
                    (Some(f), None) => f.clone(),
                    _ => String::new(),
                };

                body.push(Line::from(vec![
                    Span::styled(icon, icon_style),
                    Span::raw(" "),
                    Span::styled(entry.message.clone(), icon_style),
                    if !file_display.is_empty() {
                        Span::styled(
                            format!("  {}", file_display),
                            Style::default().fg(theme.colors.muted),
                        )
                    } else {
                        Span::raw("")
                    },
                ]));
            }
        }

        let max_lines = if opts.compact { 10 } else { 20 };
        let body = truncate_lines(body, max_lines);

        render_tool_box(header, body)
    }
}

// ─── Diagnostic Entry ─────────────────────────────────────────────────────────

#[derive(Debug)]
struct DiagnosticEntry {
    severity: String,
    message: String,
    file: Option<String>,
    line: Option<u64>,
}

fn parse_diagnostics(result: &str) -> Vec<DiagnosticEntry> {
    let v: serde_json::Value = match serde_json::from_str(result) {
        Ok(v) => v,
        Err(_) => return Vec::new(),
    };

    let arr = match v.as_array() {
        Some(a) => a,
        None => return Vec::new(),
    };

    arr.iter()
        .filter_map(|item| {
            let severity = item
                .get("severity")
                .or_else(|| item.get("level"))
                .or_else(|| item.get("type"))
                .and_then(|s| s.as_str())
                .unwrap_or("info")
                .to_lowercase();

            let message = item
                .get("message")
                .or_else(|| item.get("msg"))
                .or_else(|| item.get("text"))
                .and_then(|s| s.as_str())?
                .to_string();

            let file = item
                .get("file")
                .or_else(|| item.get("path"))
                .or_else(|| item.get("source"))
                .and_then(|s| s.as_str())
                .map(|s| s.to_string());

            let line = item
                .get("line")
                .or_else(|| item.get("row"))
                .and_then(|n| n.as_u64());

            Some(DiagnosticEntry {
                severity,
                message,
                file,
                line,
            })
        })
        .collect()
}

fn count_severities(entries: &[DiagnosticEntry]) -> (usize, usize, usize) {
    let mut errors = 0;
    let mut warnings = 0;
    let mut infos = 0;
    for e in entries {
        match e.severity.as_str() {
            "error" => errors += 1,
            "warning" | "warn" => warnings += 1,
            _ => infos += 1,
        }
    }
    (errors, warnings, infos)
}

fn severity_icon(severity: &str, theme: &crate::style::Theme) -> (String, Style) {
    match severity {
        "error" => (
            "✘".to_string(),
            Style::default()
                .fg(theme.colors.error)
                .add_modifier(Modifier::BOLD),
        ),
        "warning" | "warn" => ("⚠".to_string(), Style::default().fg(theme.colors.warning)),
        "hint" => ("·".to_string(), Style::default().fg(theme.colors.muted)),
        _ => ("ℹ".to_string(), Style::default().fg(theme.colors.muted)),
    }
}

/// Classify a plain-text diagnostic line by common prefixes.
fn classify_plain_line<'a>(line: &'a str, theme: &crate::style::Theme) -> (String, Style, &'a str) {
    let lower = line.to_lowercase();
    if lower.starts_with("error") || lower.contains(": error") {
        (
            "✘".to_string(),
            Style::default()
                .fg(theme.colors.error)
                .add_modifier(Modifier::BOLD),
            line,
        )
    } else if lower.starts_with("warning") || lower.contains(": warning") {
        (
            "⚠".to_string(),
            Style::default().fg(theme.colors.warning),
            line,
        )
    } else if lower.starts_with("hint") {
        (
            "·".to_string(),
            Style::default().fg(theme.colors.muted),
            line,
        )
    } else {
        (
            "ℹ".to_string(),
            Style::default().fg(theme.colors.muted),
            line,
        )
    }
}
