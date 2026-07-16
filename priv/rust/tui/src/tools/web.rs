use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};

use super::{
    make_header, parse_json_arg, render_tool_box, truncate_lines, RenderOpts, ToolRenderer,
};

// ─── WebFetchRenderer ─────────────────────────────────────────────────────────

pub struct WebFetchRenderer;

impl ToolRenderer for WebFetchRenderer {
    fn render(&self, _name: &str, args: &str, result: &str, opts: &RenderOpts) -> Vec<Line<'static>> {
        let theme = crate::style::theme();

        let url = parse_json_arg(args, &["url", "uri", "endpoint", "input"])
            .unwrap_or_else(|| "…".to_string());

        // Truncate URL for header display
        let url_display: String = if url.len() > 60 {
            format!("{}\u{2026}", crate::util::truncate_str(&url, 60))
        } else {
            url.clone()
        };

        let header = make_header(
            opts.status,
            opts.spinner_frame,
            "WebFetch",
            &url_display,
            opts.duration_ms,
        );

        if !opts.expanded {
            return vec![header];
        }

        let mut body: Vec<Line<'static>> = Vec::new();

        // Size annotation
        let byte_count = result.len();
        let size_label = if byte_count >= 1024 {
            format!("({:.1}KB)", byte_count as f64 / 1024.0)
        } else {
            format!("({}B)", byte_count)
        };

        body.push(Line::from(vec![
            Span::styled(
                url.clone(),
                Style::default()
                    .fg(theme.colors.secondary)
                    .add_modifier(Modifier::UNDERLINED),
            ),
            Span::raw("  "),
            Span::styled(size_label, Style::default().fg(theme.colors.dim)),
        ]));

        // Separator
        body.push(Line::from(Span::styled(
            "─".repeat(opts.width.saturating_sub(4) as usize),
            Style::default().fg(theme.colors.dim),
        )));

        // Content lines
        for line in result.lines() {
            body.push(Line::from(Span::styled(
                line.to_string(),
                theme.faint(),
            )));
        }

        let max_lines = if opts.compact { 8 } else { 15 };
        let body = truncate_lines(body, max_lines);

        render_tool_box(header, body)
    }
}

// ─── WebSearchRenderer ────────────────────────────────────────────────────────

pub struct WebSearchRenderer;

impl ToolRenderer for WebSearchRenderer {
    fn render(&self, _name: &str, args: &str, result: &str, opts: &RenderOpts) -> Vec<Line<'static>> {
        let theme = crate::style::theme();

        let query = parse_json_arg(args, &["query", "q", "search_query", "input"])
            .unwrap_or_else(|| "…".to_string());

        let header = make_header(
            opts.status,
            opts.spinner_frame,
            "WebSearch",
            &query,
            opts.duration_ms,
        );

        if !opts.expanded {
            return vec![header];
        }

        let mut body: Vec<Line<'static>> = Vec::new();

        // Try to parse result as JSON array of search results
        let parsed = serde_json::from_str::<serde_json::Value>(result).ok();
        let results_opt = parsed.as_ref().and_then(|v| {
            v.as_array()
                .or_else(|| v.get("results").and_then(|r| r.as_array()))
        });

        if let Some(results) = results_opt {
            let limit = if opts.compact { 3 } else { 5 };
            for (idx, item) in results.iter().take(limit).enumerate() {
                let title = item
                    .get("title")
                    .and_then(|t| t.as_str())
                    .unwrap_or("(no title)")
                    .to_string();
                let url = item
                    .get("url")
                    .or_else(|| item.get("link"))
                    .and_then(|u| u.as_str())
                    .unwrap_or("")
                    .to_string();
                let snippet = item
                    .get("snippet")
                    .or_else(|| item.get("description"))
                    .or_else(|| item.get("body"))
                    .and_then(|s| s.as_str())
                    .unwrap_or("")
                    .to_string();

                // Numbered title
                body.push(Line::from(vec![
                    Span::styled(
                        format!("{}. ", idx + 1),
                        Style::default().fg(theme.colors.muted),
                    ),
                    Span::styled(
                        title,
                        Style::default()
                            .fg(theme.colors.secondary)
                            .add_modifier(Modifier::BOLD),
                    ),
                ]));

                // URL
                if !url.is_empty() {
                    body.push(Line::from(vec![
                        Span::raw("   "),
                        Span::styled(
                            url,
                            Style::default()
                                .fg(theme.colors.secondary)
                                .add_modifier(Modifier::UNDERLINED),
                        ),
                    ]));
                }

                // Snippet (truncate to 120 chars)
                if !snippet.is_empty() {
                    let snip: String = if snippet.len() > 120 {
                        format!("{}\u{2026}", crate::util::truncate_str(&snippet, 120))
                    } else {
                        snippet
                    };
                    body.push(Line::from(vec![
                        Span::raw("   "),
                        Span::styled(snip, theme.faint()),
                    ]));
                }

                // Gap between results
                if idx + 1 < results.len().min(limit) {
                    body.push(Line::from(""));
                }
            }
        } else {
            // Plain text fallback
            for line in result.lines() {
                body.push(Line::from(Span::styled(line.to_string(), theme.faint())));
            }
        }

        let max_lines = if opts.compact { 10 } else { 25 };
        let body = truncate_lines(body, max_lines);

        render_tool_box(header, body)
    }
}
