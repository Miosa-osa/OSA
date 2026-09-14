use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};

use super::{
    make_header, parse_json_arg, render_tool_box, truncate_lines, RenderOpts, ToolRenderer,
};

pub struct ReferencesRenderer;

impl ToolRenderer for ReferencesRenderer {
    fn render(
        &self,
        _name: &str,
        args: &str,
        result: &str,
        opts: &RenderOpts,
    ) -> Vec<Line<'static>> {
        let theme = crate::style::theme();

        let symbol = parse_json_arg(args, &["symbol", "query", "name", "identifier"])
            .unwrap_or_else(|| "symbol".to_string());

        let header = make_header(
            opts.status,
            opts.spinner_frame,
            "References",
            &symbol,
            opts.duration_ms,
        );

        if !opts.expanded {
            return vec![header];
        }

        let file_style = Style::default()
            .fg(theme.colors.secondary)
            .add_modifier(Modifier::UNDERLINED);
        let line_no_style = Style::default().fg(theme.colors.dim);
        let content_style = theme.faint();

        let mut body: Vec<Line<'static>> = Vec::new();

        let groups = parse_reference_groups(result);

        if groups.is_empty() {
            // Plain fallback
            for line in result.lines() {
                body.push(Line::from(Span::styled(line.to_string(), content_style)));
            }
        } else {
            // Render grouped by file — 5 groups of 3 lines each
            let max_groups = if opts.compact { 3 } else { 5 };
            let max_refs_per_group = if opts.compact { 2 } else { 3 };

            for group in groups.iter().take(max_groups) {
                // File header
                body.push(Line::from(Span::styled(group.file.clone(), file_style)));

                for reference in group.refs.iter().take(max_refs_per_group) {
                    let line_part = format!(":{}", reference.line_no);
                    body.push(Line::from(vec![
                        Span::raw("  "),
                        Span::styled(line_part, line_no_style),
                        Span::raw("  "),
                        Span::styled(reference.content.clone(), content_style),
                    ]));
                }

                if group.refs.len() > max_refs_per_group {
                    body.push(Line::from(Span::styled(
                        format!("  … ({} more)", group.refs.len() - max_refs_per_group),
                        line_no_style,
                    )));
                }

                // Gap between groups
                body.push(Line::from(""));
            }

            if groups.len() > max_groups {
                body.push(Line::from(Span::styled(
                    format!("… ({} more files)", groups.len() - max_groups),
                    line_no_style,
                )));
            }
        }

        let max_lines = if opts.compact { 12 } else { 30 };
        let body = truncate_lines(body, max_lines);

        render_tool_box(header, body)
    }
}

// ─── Reference parsing ────────────────────────────────────────────────────────

struct RefEntry {
    line_no: u64,
    content: String,
}

struct RefGroup {
    file: String,
    refs: Vec<RefEntry>,
}

/// Parse references from either JSON or `file:line:content` plain text.
fn parse_reference_groups(result: &str) -> Vec<RefGroup> {
    // Try JSON first
    if let Ok(v) = serde_json::from_str::<serde_json::Value>(result) {
        if let Some(arr) = v.as_array() {
            return parse_json_references(arr);
        }
    }

    // Plain text: `file:line:content`
    parse_plain_references(result)
}

fn parse_json_references(arr: &[serde_json::Value]) -> Vec<RefGroup> {
    use std::collections::HashMap;
    let mut file_map: HashMap<String, Vec<RefEntry>> = HashMap::new();
    let mut file_order: Vec<String> = Vec::new();

    for item in arr {
        let file = item
            .get("file")
            .or_else(|| item.get("path"))
            .and_then(|s| s.as_str())
            .unwrap_or("unknown")
            .to_string();

        let line_no = item
            .get("line")
            .or_else(|| item.get("row"))
            .and_then(|n| n.as_u64())
            .unwrap_or(0);

        let content = item
            .get("content")
            .or_else(|| item.get("text"))
            .or_else(|| item.get("snippet"))
            .and_then(|s| s.as_str())
            .unwrap_or("")
            .trim()
            .to_string();

        if !file_map.contains_key(&file) {
            file_order.push(file.clone());
        }
        file_map
            .entry(file)
            .or_default()
            .push(RefEntry { line_no, content });
    }

    file_order
        .into_iter()
        .filter_map(|f| file_map.remove(&f).map(|refs| RefGroup { file: f, refs }))
        .collect()
}

fn parse_plain_references(text: &str) -> Vec<RefGroup> {
    use std::collections::HashMap;
    let mut file_map: HashMap<String, Vec<RefEntry>> = HashMap::new();
    let mut file_order: Vec<String> = Vec::new();

    for raw_line in text.lines() {
        let parts: Vec<&str> = raw_line.splitn(3, ':').collect();
        if parts.len() < 2 {
            continue;
        }

        let file = parts[0].trim().to_string();
        if file.is_empty() {
            continue;
        }

        let line_no: u64 = parts[1].trim().parse().unwrap_or(0);
        let content = parts
            .get(2)
            .map(|s| s.trim().to_string())
            .unwrap_or_default();

        if !file_map.contains_key(&file) {
            file_order.push(file.clone());
        }
        file_map
            .entry(file)
            .or_default()
            .push(RefEntry { line_no, content });
    }

    file_order
        .into_iter()
        .filter_map(|f| file_map.remove(&f).map(|refs| RefGroup { file: f, refs }))
        .collect()
}
