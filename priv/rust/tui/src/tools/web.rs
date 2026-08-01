use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};

use super::{
    make_header, parse_json_arg, render_tool_box, truncate_lines, RenderOpts, ToolRenderer,
    ToolStatus,
};

// ─── Shared helpers ───────────────────────────────────────────────────────────

/// Recover the value that IDENTIFIES a web call (the url, the query) from the
/// backend's argument hint.
///
/// `args` is JSON only for tools whose renderer needs the whole map (file
/// edits). For every other tool `ToolHint.summarize/1` sends a PLAIN STRING —
/// so a `web_search` call arrives as `"MCP server npm install"` and a
/// `web_fetch` as `"https://bestmcp.dev/"`. `parse_json_arg` returns `None` for
/// a bare string that isn't a path, which is why these cells rendered as
/// `WebSearch(…)` / `WebFetch(…)` and threw away the one thing the operator
/// needed. `arg_summary` handles both shapes, so it is the fallback.
fn identifying_arg(args: &str, keys: &[&str]) -> Option<String> {
    parse_json_arg(args, keys).or_else(|| {
        let s = crate::util::arg_summary(args);
        if s.trim().is_empty() {
            None
        } else {
            Some(s.trim().to_string())
        }
    })
}

/// Columns available for the header's detail slot: the row also carries the
/// status icon, the tool name and the duration.
fn detail_budget(width: u16) -> usize {
    (width as usize).saturating_sub(28).clamp(24, 96)
}

/// `https://github.com/a/b` -> `github.com`.
fn host_of(url: &str) -> &str {
    let s = url
        .strip_prefix("https://")
        .or_else(|| url.strip_prefix("http://"))
        .unwrap_or(url);
    match s.find('/') {
        Some(i) => &s[..i],
        None => s,
    }
}

fn format_size(bytes: usize) -> String {
    if bytes >= 1024 * 1024 {
        format!("{:.1}MB", bytes as f64 / (1024.0 * 1024.0))
    } else if bytes >= 1024 {
        format!("{:.1}KB", bytes as f64 / 1024.0)
    } else {
        format!("{}B", bytes)
    }
}

fn expand_hint() -> Span<'static> {
    Span::styled(
        "  (ctrl+o to expand)".to_string(),
        Style::default().fg(crate::style::theme().colors.dim),
    )
}

/// First non-empty line of a failure body, fitted to the row.
fn failure_line(result: &str, width: u16) -> Line<'static> {
    let theme = crate::style::theme();
    let first = result
        .lines()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .unwrap_or("failed");
    let first = first.strip_prefix("Error:").unwrap_or(first).trim();
    Line::from(Span::styled(
        crate::util::fit_cols(first, (width as usize).saturating_sub(6).max(20)),
        Style::default().fg(theme.colors.error),
    ))
}

/// The `web_fetch` success envelope, as built by
/// `WebFetch.Handler.follow_redirects/3`:
///
/// ```text
/// <final url after redirects>
/// HTTP <status> <content-type>
/// ---
/// <content>
/// ```
struct FetchMeta {
    final_url: String,
    status: String,
    content_type: String,
    /// Byte length of the CONTENT, excluding the envelope above.
    content_bytes: usize,
}

fn parse_fetch_meta(result: &str) -> Option<FetchMeta> {
    let mut lines = result.splitn(4, '\n');
    let final_url = lines.next()?.trim().to_string();
    let http_line = lines.next()?.trim().to_string();
    let sep = lines.next()?;
    if sep.trim() != "---" || !http_line.starts_with("HTTP ") {
        return None;
    }
    let rest = http_line["HTTP ".len()..].trim();
    let (status, content_type) = match rest.split_once(' ') {
        Some((s, ct)) => (s.to_string(), ct.trim().to_string()),
        None => (rest.to_string(), String::new()),
    };
    let body = lines.next().unwrap_or("");
    Some(FetchMeta {
        final_url,
        status,
        content_type,
        content_bytes: body.len(),
    })
}

/// `text/html; charset=utf-8` -> `text/html`.
fn short_content_type(ct: &str) -> &str {
    ct.split(';').next().unwrap_or(ct).trim()
}

// ─── WebFetchRenderer ─────────────────────────────────────────────────────────

pub struct WebFetchRenderer;

impl ToolRenderer for WebFetchRenderer {
    fn render(&self, _name: &str, args: &str, result: &str, opts: &RenderOpts) -> Vec<Line<'static>> {
        let theme = crate::style::theme();

        let url = identifying_arg(args, &["url", "uri", "endpoint", "input"])
            .unwrap_or_else(|| "\u{2026}".to_string());

        // The URL is the identity of this cell — keep the host and the tail of
        // the path visible instead of a head-truncated stub.
        let url_display = crate::util::ellipsize_url(&url, detail_budget(opts.width));

        let header = make_header(
            opts.status,
            opts.spinner_frame,
            "WebFetch",
            &url_display,
            opts.duration_ms,
        );

        let meta = parse_fetch_meta(result);

        if !opts.expanded {
            if result.is_empty() {
                return vec![header];
            }
            // A failed fetch (bad status, empty body, bot-block) must read as a
            // FAILURE, never as "Received 78B" — that 78 bytes was an error
            // string the model then treated as documentation.
            if opts.status == ToolStatus::Error {
                return render_tool_box(header, vec![failure_line(result, opts.width)]);
            }
            // "Received 20.2KB  ·  HTTP 200 text/html  ·  bestmcp.dev"
            let mut spans = vec![Span::raw("Received ".to_string())];
            match &meta {
                Some(m) => {
                    spans.push(Span::styled(
                        format_size(m.content_bytes),
                        Style::default().add_modifier(Modifier::BOLD),
                    ));
                    spans.push(Span::styled(
                        format!(
                            "  \u{b7}  HTTP {} {}",
                            m.status,
                            short_content_type(&m.content_type)
                        ),
                        Style::default().fg(theme.colors.dim),
                    ));
                    spans.push(Span::styled(
                        format!("  \u{b7}  {}", host_of(&m.final_url)),
                        Style::default().fg(theme.colors.dim),
                    ));
                }
                None => spans.push(Span::styled(
                    format_size(result.len()),
                    Style::default().add_modifier(Modifier::BOLD),
                )),
            }
            spans.push(expand_hint());
            return render_tool_box(header, vec![Line::from(spans)]);
        }

        let mut body: Vec<Line<'static>> = Vec::new();

        // Expanded head line: the FINAL url (post-redirect), status and size.
        let (shown_url, size_label, status_label) = match &meta {
            Some(m) => (
                m.final_url.clone(),
                format_size(m.content_bytes),
                format!("HTTP {} {}", m.status, short_content_type(&m.content_type)),
            ),
            None => (url.clone(), format_size(result.len()), String::new()),
        };

        let mut head = vec![
            Span::styled(
                shown_url,
                Style::default()
                    .fg(theme.colors.secondary)
                    .add_modifier(Modifier::UNDERLINED),
            ),
            Span::raw("  "),
            Span::styled(
                format!("({})", size_label),
                Style::default().fg(theme.colors.dim),
            ),
        ];
        if !status_label.is_empty() {
            head.push(Span::raw("  "));
            head.push(Span::styled(
                status_label,
                Style::default().fg(theme.colors.dim),
            ));
        }
        body.push(Line::from(head));

        // Separator
        body.push(Line::from(Span::styled(
            "─".repeat(opts.width.saturating_sub(4) as usize),
            Style::default().fg(theme.colors.dim),
        )));

        // Content lines — skip the envelope when we recognised one.
        let content = match &meta {
            Some(_) => result.splitn(4, '\n').nth(3).unwrap_or(""),
            None => result,
        };
        let content_style = if opts.status == ToolStatus::Error {
            Style::default().fg(theme.colors.error)
        } else {
            theme.faint()
        };
        for line in content.lines() {
            body.push(Line::from(Span::styled(line.to_string(), content_style)));
        }

        let max_lines = if opts.compact { 8 } else { 15 };
        let body = truncate_lines(body, max_lines);

        render_tool_box(header, body)
    }
}

// ─── WebSearchRenderer ────────────────────────────────────────────────────────

/// One parsed search hit.
struct Hit {
    title: String,
    url: String,
    snippet: String,
}

/// Parse the `web_search` result envelope built by
/// `WebSearch.Handler.format_results/1`:
///
/// ```text
/// Search results for: <query>
///
/// 1. [title](https://url)
///    snippet
/// ```
fn parse_markdown_hits(result: &str) -> Vec<Hit> {
    let mut hits: Vec<Hit> = Vec::new();
    for raw in result.lines() {
        let line = raw.trim_end();
        let trimmed = line.trim_start();
        // "<n>. [title](url)"
        let numbered = trimmed.split_once(". ").filter(|(n, rest)| {
            !n.is_empty() && n.chars().all(|c| c.is_ascii_digit()) && rest.starts_with('[')
        });
        if let Some((_, rest)) = numbered {
            if let Some(close) = rest.find("](") {
                let title = rest[1..close].to_string();
                let after = &rest[close + 2..];
                let url = after.strip_suffix(')').unwrap_or(after).to_string();
                hits.push(Hit {
                    title,
                    url,
                    snippet: String::new(),
                });
                continue;
            }
        }
        // Indented continuation line = the snippet of the previous hit.
        if !trimmed.is_empty() && line.starts_with("   ") {
            if let Some(last) = hits.last_mut() {
                if last.snippet.is_empty() {
                    last.snippet = trimmed.to_string();
                }
            }
        }
    }
    hits
}

/// Hits from a JSON result payload (an array, or `{"results": [...]}`).
fn parse_json_hits(result: &str) -> Vec<Hit> {
    let Ok(v) = serde_json::from_str::<serde_json::Value>(result) else {
        return Vec::new();
    };
    let arr = match v.as_array() {
        Some(a) => a.clone(),
        None => match v.get("results").and_then(|r| r.as_array()) {
            Some(a) => a.clone(),
            None => return Vec::new(),
        },
    };
    arr.iter()
        .map(|item| Hit {
            title: item
                .get("title")
                .and_then(|t| t.as_str())
                .unwrap_or("(no title)")
                .to_string(),
            url: item
                .get("url")
                .or_else(|| item.get("link"))
                .and_then(|u| u.as_str())
                .unwrap_or("")
                .to_string(),
            snippet: item
                .get("snippet")
                .or_else(|| item.get("description"))
                .or_else(|| item.get("body"))
                .and_then(|s| s.as_str())
                .unwrap_or("")
                .to_string(),
        })
        .collect()
}

fn parse_hits(result: &str) -> Vec<Hit> {
    let json = parse_json_hits(result);
    if json.is_empty() {
        parse_markdown_hits(result)
    } else {
        json
    }
}

pub struct WebSearchRenderer;

impl ToolRenderer for WebSearchRenderer {
    fn render(&self, _name: &str, args: &str, result: &str, opts: &RenderOpts) -> Vec<Line<'static>> {
        let theme = crate::style::theme();

        let query = identifying_arg(args, &["query", "q", "search_query", "input"])
            .unwrap_or_else(|| "\u{2026}".to_string());

        let query_display = crate::util::fit_arg_summary(&query, detail_budget(opts.width));

        let header = make_header(
            opts.status,
            opts.spinner_frame,
            "WebSearch",
            &query_display,
            opts.duration_ms,
        );

        let hits = parse_hits(result);

        if !opts.expanded {
            if result.is_empty() {
                return vec![header];
            }
            if opts.status == ToolStatus::Error {
                return render_tool_box(header, vec![failure_line(result, opts.width)]);
            }
            // "Did 1 search" told the operator nothing. Report HOW MANY results
            // came back and WHERE from.
            if hits.is_empty() {
                let dur = super::format_duration(opts.duration_ms);
                let text = if dur.is_empty() {
                    "No results".to_string()
                } else {
                    format!("No results in {}", dur)
                };
                return render_tool_box(
                    header,
                    vec![Line::from(vec![Span::raw(text), expand_hint()])],
                );
            }
            let count_label = if hits.len() == 1 {
                "Found 1 result".to_string()
            } else {
                format!("Found {} results", hits.len())
            };
            let mut hosts: Vec<String> = Vec::new();
            for h in hits.iter() {
                let host = host_of(&h.url).to_string();
                if !host.is_empty() && !hosts.contains(&host) {
                    hosts.push(host);
                }
                if hosts.len() == 3 {
                    break;
                }
            }
            let mut spans = vec![Span::styled(
                count_label,
                Style::default().add_modifier(Modifier::BOLD),
            )];
            if !hosts.is_empty() {
                let tail = if hits.len() > hosts.len() { ", \u{2026}" } else { "" };
                spans.push(Span::styled(
                    format!("  \u{b7}  {}{}", hosts.join(", "), tail),
                    Style::default().fg(theme.colors.dim),
                ));
            }
            spans.push(expand_hint());
            return render_tool_box(header, vec![Line::from(spans)]);
        }

        let mut body: Vec<Line<'static>> = Vec::new();
        let limit = if opts.compact { 3 } else { 5 };

        if hits.is_empty() {
            for line in result.lines() {
                body.push(Line::from(Span::styled(line.to_string(), theme.faint())));
            }
        } else {
            let shown = hits.len().min(limit);
            for (idx, hit) in hits.iter().take(limit).enumerate() {
                body.push(Line::from(vec![
                    Span::styled(
                        format!("{}. ", idx + 1),
                        Style::default().fg(theme.colors.muted),
                    ),
                    Span::styled(
                        hit.title.clone(),
                        Style::default()
                            .fg(theme.colors.secondary)
                            .add_modifier(Modifier::BOLD),
                    ),
                ]));

                if !hit.url.is_empty() {
                    body.push(Line::from(vec![
                        Span::raw("   "),
                        Span::styled(
                            hit.url.clone(),
                            Style::default()
                                .fg(theme.colors.secondary)
                                .add_modifier(Modifier::UNDERLINED),
                        ),
                    ]));
                }

                if !hit.snippet.is_empty() {
                    let snip = crate::util::fit_cols(
                        &hit.snippet,
                        (opts.width as usize).saturating_sub(6).clamp(20, 120),
                    );
                    body.push(Line::from(vec![
                        Span::raw("   "),
                        Span::styled(snip, theme.faint()),
                    ]));
                }

                if idx + 1 < shown {
                    body.push(Line::from(""));
                }
            }
        }

        let max_lines = if opts.compact { 10 } else { 25 };
        let body = truncate_lines(body, max_lines);

        render_tool_box(header, body)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn opts(status: ToolStatus, expanded: bool) -> RenderOpts {
        RenderOpts {
            status,
            width: 100,
            expanded,
            compact: true,
            spinner_frame: None,
            duration_ms: 1000,
            truncated: false,
        }
    }

    fn text_of(lines: &[Line<'static>]) -> String {
        lines
            .iter()
            .map(|l| {
                l.spans
                    .iter()
                    .map(|s| s.content.as_ref())
                    .collect::<String>()
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    const SEARCH_RESULT: &str = "Search results for: mcp servers\n\n\
1. [Model Context Protocol servers](https://github.com/modelcontextprotocol/servers)\n   \
Reference implementations\n\n\
2. [Best MCP](https://bestmcp.dev/directory)\n   A directory";

    // ── DEFECT 1: the committed cell must NAME the call ───────────────────

    #[test]
    fn search_cell_shows_its_query_from_a_plain_hint() {
        // The backend sends the hint as a PLAIN STRING, not JSON — that is what
        // used to render as `WebSearch(…)`.
        let lines = WebSearchRenderer.render(
            "web_search",
            "MCP server npm install filesystem",
            SEARCH_RESULT,
            &opts(ToolStatus::Success, false),
        );
        let out = text_of(&lines);
        assert!(
            out.contains("MCP server npm install filesystem"),
            "query missing from cell: {out}"
        );
        assert!(
            !out.contains("WebSearch(\u{2026})"),
            "placeholder query: {out}"
        );
    }

    #[test]
    fn search_cell_shows_its_query_from_json_args() {
        let lines = WebSearchRenderer.render(
            "web_search",
            r#"{"query":"ratatui layout","limit":5}"#,
            SEARCH_RESULT,
            &opts(ToolStatus::Success, false),
        );
        assert!(text_of(&lines).contains("ratatui layout"));
    }

    #[test]
    fn fetch_cell_shows_its_url_from_a_plain_hint() {
        let lines = WebFetchRenderer.render(
            "web_fetch",
            "https://github.com/modelcontextprotocol/servers",
            "https://github.com/modelcontextprotocol/servers\nHTTP 200 text/html\n---\nhello world",
            &opts(ToolStatus::Success, false),
        );
        let out = text_of(&lines);
        assert!(out.contains("github.com"), "host missing: {out}");
        assert!(out.contains("servers"), "path tail missing: {out}");
    }

    #[test]
    fn fetch_cell_keeps_host_and_tail_when_the_url_is_long() {
        let long = "https://example.com/a/very/deeply/nested/set/of/path/segments/that/will/not/fit/anywhere/final-page.html";
        let mut o = opts(ToolStatus::Success, false);
        o.width = 60;
        let lines =
            WebFetchRenderer.render("web_fetch", long, "x\nHTTP 200 text/html\n---\nbody", &o);
        let out = text_of(&lines);
        assert!(out.contains("example.com"), "host elided: {out}");
        assert!(out.contains("final-page.html"), "tail elided: {out}");
    }

    // ── DEFECT 1: the result line must be informative ─────────────────────

    #[test]
    fn search_result_line_reports_count_and_hosts() {
        let lines = WebSearchRenderer.render(
            "web_search",
            "mcp servers",
            SEARCH_RESULT,
            &opts(ToolStatus::Success, false),
        );
        let out = text_of(&lines);
        assert!(out.contains("Found 2 results"), "no result count: {out}");
        assert!(out.contains("github.com"), "no host: {out}");
        assert!(!out.contains("Did 1 search"), "old uninformative line: {out}");
    }

    #[test]
    fn fetch_result_line_reports_status_size_and_final_host() {
        let body = "x".repeat(2048);
        let result =
            format!("https://docs.rs/serde/latest\nHTTP 200 text/html; charset=utf-8\n---\n{body}");
        let lines = WebFetchRenderer.render(
            "web_fetch",
            "https://docs.rs/serde",
            &result,
            &opts(ToolStatus::Success, false),
        );
        let out = text_of(&lines);
        assert!(out.contains("HTTP 200"), "no status: {out}");
        assert!(out.contains("2.0KB"), "size excludes envelope: {out}");
        assert!(out.contains("docs.rs"), "no final host: {out}");
    }

    // ── DEFECT 2: a failed fetch must not read as content ─────────────────

    #[test]
    fn failed_fetch_shows_the_reason_not_a_byte_count() {
        let err = "Error: HTTP 403 Forbidden fetching https://bestmcp.dev/ — the server refused the request (bot protection or auth required). No content was retrieved.";
        let lines = WebFetchRenderer.render(
            "web_fetch",
            "https://bestmcp.dev/",
            err,
            &opts(ToolStatus::Error, false),
        );
        let out = text_of(&lines);
        assert!(out.contains("HTTP 403"), "status missing: {out}");
        assert!(
            !out.contains("Received"),
            "failure rendered as content: {out}"
        );
    }

    #[test]
    fn failed_search_shows_the_reason() {
        let lines = WebSearchRenderer.render(
            "web_search",
            "obscure query",
            "Error: No results found for \"obscure query\".",
            &opts(ToolStatus::Error, false),
        );
        let out = text_of(&lines);
        assert!(out.contains("No results found"), "{out}");
        assert!(!out.contains("Found 1"), "{out}");
    }

    #[test]
    fn expanded_fetch_hides_the_envelope_and_shows_the_final_url() {
        let result = "https://final.example.com/page\nHTTP 200 text/html\n---\nreal content here";
        let lines = WebFetchRenderer.render(
            "web_fetch",
            "https://start.example.com/page",
            result,
            &opts(ToolStatus::Success, true),
        );
        let out = text_of(&lines);
        assert!(out.contains("https://final.example.com/page"), "{out}");
        assert!(out.contains("real content here"), "{out}");
        assert!(!out.contains("HTTP 200 text/html\n---"), "envelope leaked: {out}");
    }

    #[test]
    fn markdown_hits_parse_titles_urls_and_snippets() {
        let hits = parse_markdown_hits(SEARCH_RESULT);
        assert_eq!(hits.len(), 2);
        assert_eq!(hits[0].title, "Model Context Protocol servers");
        assert_eq!(hits[0].url, "https://github.com/modelcontextprotocol/servers");
        assert_eq!(hits[0].snippet, "Reference implementations");
        assert_eq!(hits[1].url, "https://bestmcp.dev/directory");
    }
}
