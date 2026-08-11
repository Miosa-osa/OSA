// Collapsed tool summaries — mirrors Claude Code's collapseReadSearch.ts /
// groupToolUses.ts. A run of consecutive same-KIND tool calls collapses to a
// single scrollback line: "Ran N shell commands", "Read N files",
// "Listed N directories", "Searched for N patterns", "Queried <server>".
//
// There is NO minimum count — even a single read collapses to "Read 1 file".
// Non-collapsible tools (edit/write/etc.) bypass this entirely and keep their
// full per-call rendering.
#![allow(dead_code)]

use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};

/// Classification of a finished tool call for collapse grouping.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ToolKind {
    Search,
    Read,
    List,
    Shell,
    Mcp(String),
    NonCollapsible,
}

impl ToolKind {
    pub fn is_collapsible(&self) -> bool {
        !matches!(self, ToolKind::NonCollapsible)
    }

    /// Bucket key — two kinds with the same key merge into one summary.
    fn family_key(&self) -> Option<String> {
        match self {
            ToolKind::Search => Some("search".to_string()),
            ToolKind::Read => Some("read".to_string()),
            ToolKind::List => Some("list".to_string()),
            ToolKind::Shell => Some("shell".to_string()),
            ToolKind::Mcp(server) => Some(format!("mcp:{}", server)),
            ToolKind::NonCollapsible => None,
        }
    }
}

/// Classify a finished tool call by name (+ args) into a collapse kind.
pub fn classify(name: &str, args: &str) -> ToolKind {
    let lower = name.to_lowercase();

    // MCP tools: mcp__server__tool → group by server.
    if lower.starts_with("mcp__") {
        let server = lower.split("__").nth(1).unwrap_or("mcp").to_string();
        return ToolKind::Mcp(server);
    }

    match lower.as_str() {
        // Shell — CC parity (BashTool.isSearchOrReadCommand): only pure
        // search/read/list command pipelines collapse; any other command
        // renders in full with its `● Bash(cmd)` header + `⎿` output block.
        "bash" | "run_bash_command" | "shell" | "shell_execute" => classify_shell_command(args),
        // Read-family.
        "read" | "read_file" | "file_read" | "cat" | "head" | "tail" => ToolKind::Read,
        // Directory listing.
        "ls" | "list_directory" | "dir_list" | "list_dir" | "tree" | "du" => ToolKind::List,
        // Search / pattern matching.
        "grep" | "file_grep" | "glob" | "file_glob" | "rg" | "search" => ToolKind::Search,
        // Everything else (edit/write/web/task/…) renders in full.
        _ => ToolKind::NonCollapsible,
    }
}

/// CC's BASH_* command sets (BashTool.tsx): a compound command collapses only
/// when every non-neutral segment is a search/read/list command. Anything else
/// (build, git, test, …) is NonCollapsible and renders in full.
fn classify_shell_command(args: &str) -> ToolKind {
    const SEARCH: &[&str] = &["find", "grep", "rg", "ag", "ack", "locate", "which", "whereis"];
    const READ: &[&str] = &[
        "cat", "head", "tail", "less", "more", "wc", "stat", "file", "strings", "jq", "awk",
        "cut", "sort", "uniq", "tr",
    ];
    const LIST: &[&str] = &["ls", "tree", "du"];
    const NEUTRAL: &[&str] = &["echo", "printf", "true", "false", ":"];

    let command = match super::parse_json_arg(args, &["command", "cmd", "input"]) {
        Some(c) => c,
        None => return ToolKind::NonCollapsible,
    };

    let (mut has_search, mut has_read, mut has_list, mut any) = (false, false, false, false);
    // Approximation of CC's splitCommandWithOperators: split on ; \n && || |.
    for segment in command
        .split(|c| c == ';' || c == '\n')
        .flat_map(|s| s.split("&&"))
        .flat_map(|s| s.split("||"))
        .flat_map(|s| s.split('|'))
    {
        let mut words = segment.split_whitespace();
        // Skip leading VAR=val assignments.
        let base = loop {
            match words.next() {
                Some(w) if w.contains('=') && !w.starts_with('=') => continue,
                other => break other,
            }
        };
        let base = match base {
            Some(b) => b,
            None => continue,
        };
        // Strip a path prefix: /usr/bin/grep → grep.
        let base = base.rsplit('/').next().unwrap_or(base);
        if NEUTRAL.contains(&base) {
            continue;
        }
        any = true;
        if SEARCH.contains(&base) {
            has_search = true;
        } else if READ.contains(&base) {
            has_read = true;
        } else if LIST.contains(&base) {
            has_list = true;
        } else {
            return ToolKind::NonCollapsible;
        }
    }
    if !any {
        return ToolKind::NonCollapsible;
    }
    if has_search {
        ToolKind::Search
    } else if has_read {
        ToolKind::Read
    } else if has_list {
        ToolKind::List
    } else {
        ToolKind::NonCollapsible
    }
}

fn extract_read_path(args: &str) -> Option<String> {
    super::parse_json_arg(args, &["file_path", "path", "filename", "file"])
}

/// Final path segment — the part that actually identifies a file.
pub(crate) fn basename(path: &str) -> &str {
    let trimmed = path.trim_end_matches('/');
    match trimmed.rsplit_once('/') {
        Some((_, name)) if !name.is_empty() => name,
        _ => trimmed,
    }
}

/// `Read foo.rs` / `Read foo.rs, bar.ex` / `Read foo.rs, bar.ex +3 more`.
fn named_read_summary(paths: &[String]) -> String {
    const SHOWN: usize = 3;
    let names: Vec<&str> = paths.iter().map(|p| basename(p)).collect();
    let head = names
        .iter()
        .take(SHOWN)
        .copied()
        .collect::<Vec<_>>()
        .join(", ");
    if names.len() > SHOWN {
        format!("Read {} +{} more", head, names.len() - SHOWN)
    } else {
        format!("Read {}", head)
    }
}

fn plural(n: usize) -> &'static str {
    if n == 1 {
        ""
    } else {
        "s"
    }
}

/// Accumulates a run of consecutive same-kind collapsible tools.
#[derive(Default)]
pub struct Accumulator {
    family: Option<String>,
    search_count: usize,
    read_paths: Vec<String>,
    read_ops: usize,
    list_count: usize,
    shell_count: usize,
    mcp_server: Option<String>,
    mcp_count: usize,
    any_error: bool,
}

impl Accumulator {
    pub fn is_empty(&self) -> bool {
        self.family.is_none()
    }

    /// True if `kind` belongs to the currently-accumulating bucket.
    pub fn family_matches(&self, kind: &ToolKind) -> bool {
        self.family.as_deref() == kind.family_key().as_deref()
    }

    /// Fold one finished collapsible tool into the run.
    pub fn add(&mut self, kind: &ToolKind, args: &str, success: bool) {
        self.family = kind.family_key();
        if !success {
            self.any_error = true;
        }
        match kind {
            ToolKind::Read => {
                if let Some(p) = extract_read_path(args) {
                    // Ordered + de-duplicated: the summary NAMES these files, so
                    // they must appear in the order the agent read them. A
                    // HashSet would shuffle them on every render.
                    if !self.read_paths.contains(&p) {
                        self.read_paths.push(p);
                    }
                } else {
                    self.read_ops += 1;
                }
            }
            ToolKind::List => self.list_count += 1,
            ToolKind::Shell => self.shell_count += 1,
            ToolKind::Search => self.search_count += 1,
            ToolKind::Mcp(server) => {
                self.mcp_server = Some(server.clone());
                self.mcp_count += 1;
            }
            ToolKind::NonCollapsible => {}
        }
    }

    fn summary_text(&self) -> String {
        if self.shell_count > 0 {
            let n = self.shell_count;
            format!("Ran {} shell command{}", n, plural(n))
        } else if !self.read_paths.is_empty() {
            // NAME the files. "Read 1 file" told the operator nothing about
            // WHICH file, which made a transcript of several reads unusable.
            named_read_summary(&self.read_paths)
        } else if self.read_ops > 0 {
            // Anonymous fallback: the call carried no recoverable path.
            let n = self.read_ops;
            format!("Read {} file{}", n, plural(n))
        } else if self.list_count > 0 {
            let n = self.list_count;
            let noun = if n == 1 { "directory" } else { "directories" };
            format!("Listed {} {}", n, noun)
        } else if self.search_count > 0 {
            let n = self.search_count;
            format!("Searched for {} pattern{}", n, plural(n))
        } else if self.mcp_count > 0 {
            let server = self.mcp_server.clone().unwrap_or_default();
            if self.mcp_count == 1 {
                format!("Queried {}", server)
            } else {
                format!("Queried {} {} times", server, self.mcp_count)
            }
        } else {
            String::new()
        }
    }

    /// Emit the run as a single styled scrollback line and reset. Returns None
    /// when the accumulator is empty.
    pub fn take_summary_line(&mut self) -> Option<Line<'static>> {
        if self.is_empty() {
            return None;
        }
        let text = self.summary_text();
        let err = self.any_error;
        *self = Accumulator::default();
        if text.is_empty() {
            return None;
        }
        let theme = crate::style::theme();
        let icon_color = if err {
            theme.colors.error
        } else {
            theme.colors.success
        };
        Some(Line::from(vec![
            Span::styled(
                format!("{} ", crate::tools::tool_bullet()), // ● (Linux) / ⏺ (macOS)
                Style::default().fg(icon_color).add_modifier(Modifier::BOLD),
            ),
            Span::styled(text, Style::default().fg(theme.colors.muted)),
        ]))
    }
}

// ─── Shared tool-output quality helpers ─────────────────────────────────────
//
// Used by the Bash and generic tool renderers to lift exec/output cells to
// Codex/Claude-Code/grok level: a subtle panel background (grok's `bg_dark`),
// readable JSON pretty-printing (CC's OutputLine tryFormatJson), OSC-8 URL
// linkification, and the shared 3-line-then-`… +N lines (ctrl+o to expand)`
// fold. All output goes through one place so every tool benefits.

/// Subtle, slightly-elevated panel background for tool-output bodies — reads as
/// a distinct block against the transcript, matching grok's `bg_dark` panel.
/// Uses the theme's `tooltip_bg` surface (a muted elevated bg present in every
/// bundled theme).
pub(crate) fn output_panel_bg() -> Color {
    crate::style::theme().colors.tooltip_bg
}

/// Patch `bg` onto every span and right-pad to `cols` visible columns so the
/// output reads as a filled panel block rather than ragged text. `vis_width` is
/// the display width of the visible text (OSC-8 link escapes are zero-width and
/// already excluded by the caller).
fn panelize(mut spans: Vec<Span<'static>>, vis_width: usize, cols: usize, bg: Color) -> Line<'static> {
    for s in &mut spans {
        s.style = s.style.bg(bg);
    }
    if cols > vis_width {
        spans.push(Span::styled(
            " ".repeat(cols - vis_width),
            Style::default().bg(bg),
        ));
    }
    Line::from(spans)
}

/// True when `s` contains a run of >15 consecutive digits — a number that would
/// lose precision if round-tripped through an f64/i64, so we must NOT reformat
/// the JSON (CC's tryFormatJson large-number guard).
fn has_oversized_number(s: &str) -> bool {
    let mut run = 0usize;
    for b in s.bytes() {
        if b.is_ascii_digit() {
            run += 1;
            if run > 15 {
                return true;
            }
        } else {
            run = 0;
        }
    }
    false
}

/// Pretty-print `line` when it is a valid JSON object/array, guarding against
/// precision-losing giant numbers. Returns `None` (leave the line untouched)
/// for non-JSON, scalars, or unsafe numbers. Mirrors CC's OutputLine
/// `tryFormatJson`.
pub(crate) fn try_format_json(line: &str) -> Option<String> {
    let t = line.trim();
    if t.len() < 2 || !(t.starts_with('{') || t.starts_with('[')) {
        return None;
    }
    if has_oversized_number(t) {
        return None;
    }
    let v: serde_json::Value = serde_json::from_str(t).ok()?;
    if !v.is_object() && !v.is_array() {
        return None;
    }
    serde_json::to_string_pretty(&v).ok()
}

/// Expand a raw result into logical display lines, pretty-printing any line that
/// is a JSON object/array.
fn expand_json_lines(result: &str) -> Vec<String> {
    let mut out = Vec::new();
    for line in result.lines() {
        match try_format_json(line) {
            Some(pretty) => out.extend(pretty.lines().map(|l| l.to_string())),
            None => out.push(line.to_string()),
        }
    }
    out
}

/// Locate an `http(s)://` URL starting exactly at byte `i`, returning its end
/// byte offset with trailing sentence punctuation trimmed. `None` if no URL
/// starts there.
fn url_at(text: &str, i: usize) -> Option<usize> {
    let rest = &text[i..];
    let scheme_len = if rest.starts_with("https://") {
        8
    } else if rest.starts_with("http://") {
        7
    } else {
        return None;
    };
    let mut end = i + scheme_len;
    for ch in text[end..].chars() {
        if ch.is_whitespace()
            || ch.is_control()
            || matches!(ch, '"' | '\'' | '<' | '>' | '`' | '|' | '\\' | '^' | '{' | '}')
        {
            break;
        }
        end += ch.len_utf8();
    }
    // Trim trailing punctuation commonly adjacent to (but not part of) a URL.
    while end > i + scheme_len {
        let last = text[..end].chars().next_back().unwrap();
        if matches!(last, '.' | ',' | ';' | ':' | '!' | '?' | ')' | ']') {
            end -= last.len_utf8();
        } else {
            break;
        }
    }
    Some(end)
}

/// Build spans for one plain output row, turning `http(s)://` URLs into OSC-8
/// hyperlinks (degrades to underlined text on terminals without link support).
/// Returns the spans and the row's visible display width.
fn linkify_row(text: &str, base: Style) -> (Vec<Span<'static>>, usize) {
    use unicode_width::UnicodeWidthStr;
    let width = UnicodeWidthStr::width(text);
    let link_style = base.add_modifier(Modifier::UNDERLINED);
    let mut spans: Vec<Span<'static>> = Vec::new();
    let mut seg_start = 0usize;
    let mut idx = 0usize;
    while idx < text.len() {
        if let Some(end) = url_at(text, idx) {
            if seg_start < idx {
                spans.push(Span::styled(text[seg_start..idx].to_string(), base));
            }
            let url = text[idx..end].to_string();
            spans.push(crate::components::osc8::hyperlink_span(
                url.clone(),
                &url,
                link_style,
            ));
            idx = end;
            seg_start = end;
        } else {
            idx += text[idx..].chars().next().map(|c| c.len_utf8()).unwrap_or(1);
        }
    }
    if seg_start < text.len() {
        spans.push(Span::styled(text[seg_start..].to_string(), base));
    }
    if spans.is_empty() {
        spans.push(Span::styled(String::new(), base));
    }
    (spans, width)
}

/// Base output style for a tool body, on the panel background. Errors (stderr /
/// error status) render in the error color, stdout in muted.
fn output_base_style(is_error: bool, bg: Color) -> Style {
    let theme = crate::style::theme();
    let fg = if is_error {
        theme.colors.error
    } else {
        theme.colors.muted
    };
    Style::default().fg(fg).bg(bg)
}

/// Collapsed tool-output block (CC's OutputLine/renderTruncatedContent) with the
/// output-quality upgrades: JSON pretty-print, URL linkify, panel background.
/// Up to 3 dimmed, width-wrapped rows; exactly 4 print in full; more get
/// `… +N lines (ctrl+o to expand)`. Empty result → empty vec.
pub(crate) fn enhanced_collapsed_block(
    result: &str,
    width: u16,
    is_error: bool,
) -> Vec<Line<'static>> {
    let trimmed = result.trim_end();
    if trimmed.is_empty() {
        return Vec::new();
    }
    let theme = crate::style::theme();
    let cols = super::body_wrap_width(width);
    let bg = output_panel_bg();
    let base = output_base_style(is_error, bg);

    let logical = expand_json_lines(trimmed);
    let all: Vec<String> = logical
        .iter()
        .flat_map(|l| super::wrap_plain(l, cols))
        .collect();
    let shown = if all.len() == super::MAX_LINES_TO_SHOW + 1 {
        all.len()
    } else {
        all.len().min(super::MAX_LINES_TO_SHOW)
    };
    let mut body: Vec<Line<'static>> = Vec::with_capacity(shown + 1);
    for row in &all[..shown] {
        let (spans, w) = linkify_row(row, base);
        body.push(panelize(spans, w, cols, bg));
    }
    if all.len() > shown {
        let hint = format!("… +{} lines (ctrl+o to expand)", all.len() - shown);
        let w = unicode_width::UnicodeWidthStr::width(hint.as_str());
        let hint_span = Span::styled(hint, Style::default().fg(theme.colors.dim).bg(bg));
        body.push(panelize(vec![hint_span], w, cols, bg));
    }
    body
}

/// Full (expanded) tool-output body with the same quality upgrades: JSON
/// pretty-print, URL linkify, panel background, width wrapping. No line cap —
/// the caller applies any compact-mode truncation.
pub(crate) fn enhanced_output_lines(
    result: &str,
    width: u16,
    is_error: bool,
) -> Vec<Line<'static>> {
    let cols = super::body_wrap_width(width);
    let bg = output_panel_bg();
    let base = output_base_style(is_error, bg);
    let mut body: Vec<Line<'static>> = Vec::new();
    for l in expand_json_lines(result) {
        for row in super::wrap_plain(&l, cols) {
            let (spans, w) = linkify_row(&row, base);
            body.push(panelize(spans, w, cols, bg));
        }
    }
    body
}

/// Spans for a shell command with a dim `$ ` prefix and light bash syntax
/// coloring (via `render::syntax`); falls back to a bold secondary command when
/// highlighting is unavailable. Multi-line commands keep their line breaks.
pub(crate) fn shell_command_spans(command: &str) -> Vec<Span<'static>> {
    let theme = crate::style::theme();
    let mut spans = vec![Span::styled(
        "$ ".to_string(),
        Style::default().fg(theme.colors.dim),
    )];
    match crate::render::syntax::highlight_line_runs(command, "bash") {
        Some(rows) if !rows.is_empty() => {
            for (ri, row) in rows.iter().enumerate() {
                if ri > 0 {
                    spans.push(Span::raw("\n".to_string()));
                }
                for (text, fg) in row {
                    spans.push(Span::styled(text.clone(), Style::default().fg(*fg)));
                }
            }
        }
        _ => spans.push(Span::styled(
            command.to_string(),
            Style::default()
                .fg(theme.colors.secondary)
                .add_modifier(Modifier::BOLD),
        )),
    }
    spans
}

#[cfg(test)]
mod output_quality_tests {
    use super::*;

    #[test]
    fn json_line_is_pretty_printed() {
        let pretty = try_format_json(r#"{"a":1,"b":[2,3]}"#).expect("valid json");
        assert!(pretty.contains('\n'), "pretty json should be multi-line: {pretty:?}");
        assert!(pretty.contains("\"a\""));
        // Non-JSON and scalar-only lines are left untouched.
        assert!(try_format_json("plain text").is_none());
        assert!(try_format_json("42").is_none());
    }

    #[test]
    fn oversized_numbers_are_not_reformatted() {
        // 20-digit integer would lose precision — guard must reject it.
        assert!(try_format_json(r#"{"id":123456789012345678}"#).is_none());
    }

    #[test]
    #[serial_test::serial]
    fn url_becomes_osc8_link_when_supported() {
        // Force hyperlink support for a deterministic assertion. Both overrides
        // are process-global, so they are scoped to this body and restored on
        // drop, and the test is `#[serial]` so no concurrent test observes the
        // window in which TERM differs.
        let _term = crate::test_env::EnvGuard::set("TERM", "xterm-256color");
        let _links = crate::test_env::EnvGuard::set("OSA_HYPERLINKS", "1");
        assert!(crate::components::osc8::supports_hyperlinks());
        let (spans, _w) = linkify_row("see https://osa.dev/docs now", Style::default());
        let joined: String = spans.iter().map(|s| s.content.as_ref()).collect();
        // OSC-8 introducer wraps the URL.
        assert!(joined.contains("\x1b]8;;https://osa.dev/docs"), "{joined:?}");
        // No manual cleanup: the guards restore TERM and OSA_HYPERLINKS on
        // drop, including if an assertion above unwinds.
    }

    #[test]
    fn collapsed_fold_uses_ellipsis_hint() {
        let block = enhanced_collapsed_block("a\nb\nc\nd\ne", 80, false);
        let last: String = block
            .last()
            .unwrap()
            .spans
            .iter()
            .map(|s| s.content.as_ref())
            .collect();
        assert!(last.starts_with('\u{2026}'), "leading char must be … : {last:?}");
        assert!(last.contains("+2 lines (ctrl+o to expand)"), "{last:?}");
    }

    #[test]
    fn error_output_renders_in_error_color() {
        let theme = crate::style::theme();
        let block = enhanced_collapsed_block("boom", 80, true);
        let fg = block[0].spans[0].style.fg;
        assert_eq!(fg, Some(theme.colors.error));
    }

    #[test]
    fn empty_output_does_not_panic() {
        assert!(enhanced_collapsed_block("", 80, false).is_empty());
        assert!(enhanced_collapsed_block("   \n  ", 80, false).is_empty());
        assert!(enhanced_output_lines("", 80, false).is_empty());
    }
}

#[cfg(test)]
mod shell_classify_tests {
    use super::*;

    #[test]
    fn plain_bash_commands_render_in_full() {
        assert_eq!(
            classify("bash", r#"{"command":"cargo build"}"#),
            ToolKind::NonCollapsible
        );
    }

    #[test]
    fn search_read_list_pipelines_still_collapse() {
        assert_eq!(
            classify("bash", r#"{"command":"grep -rn foo src"}"#),
            ToolKind::Search
        );
        assert_eq!(
            classify("bash", r#"{"command":"cat a.txt | head -5"}"#),
            ToolKind::Read
        );
        assert_eq!(
            classify("bash", r#"{"command":"ls -la && echo done"}"#),
            ToolKind::List
        );
    }

    #[test]
    fn mixed_pipeline_with_mutation_is_not_collapsible() {
        assert_eq!(
            classify("bash", r#"{"command":"grep foo src && cargo test"}"#),
            ToolKind::NonCollapsible
        );
    }

    // ── collapsed reads name their files ─────────────────────────────────
    //
    // "Read 1 file" told the operator nothing about WHICH file. The paths were
    // already being collected — they were just never printed.

    fn read_run(paths: &[&str]) -> String {
        let mut acc = Accumulator::default();
        for p in paths {
            acc.add(&ToolKind::Read, p, true);
        }
        acc.summary_text()
    }

    #[test]
    fn a_single_read_names_the_file() {
        assert_eq!(read_run(&["/proj/src/main.rs"]), "Read main.rs");
    }

    #[test]
    fn a_short_run_names_every_file_in_call_order() {
        assert_eq!(
            read_run(&["/a/zeta.rs", "/b/alpha.ex", "/c/mid.ts"]),
            "Read zeta.rs, alpha.ex, mid.ts"
        );
    }

    #[test]
    fn a_long_run_names_the_first_three_and_counts_the_rest() {
        let summary = read_run(&["/a/one.rs", "/a/two.rs", "/a/three.rs", "/a/four.rs"]);
        assert_eq!(summary, "Read one.rs, two.rs, three.rs +1 more");
    }

    #[test]
    fn repeated_reads_of_the_same_file_are_named_once() {
        assert_eq!(read_run(&["/a/one.rs", "/a/one.rs"]), "Read one.rs");
    }

    #[test]
    fn a_read_with_no_recoverable_path_falls_back_to_a_count() {
        let mut acc = Accumulator::default();
        acc.add(&ToolKind::Read, "", true);
        acc.add(&ToolKind::Read, "", true);
        assert_eq!(acc.summary_text(), "Read 2 files");
    }

    #[test]
    fn shell_execute_collapses_like_bash() {
        // OSA's own shell tool name was missing from `classify`, so a run of
        // read-only shell calls never collapsed.
        assert_eq!(
            classify("shell_execute", r#"{"command":"cat a.txt"}"#),
            ToolKind::Read
        );
    }

    #[test]
    fn basename_handles_edge_shapes() {
        assert_eq!(basename("/a/b/c.rs"), "c.rs");
        assert_eq!(basename("c.rs"), "c.rs");
        assert_eq!(basename("/a/b/"), "b");
        assert_eq!(basename(""), "");
    }
}
