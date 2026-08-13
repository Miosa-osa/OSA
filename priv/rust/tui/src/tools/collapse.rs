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

/// Semantic kind of a finished tool call.
///
/// Verb, noun and fold policy live HERE, on the kind, and never in the
/// formatter. That placement is the whole point: a newly-added tool that
/// forgets to declare its vocabulary fails to compile rather than silently
/// rendering as `Ran 1 tools`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ToolKind {
    /// A file read.
    File,
    /// A read whose target is a skill definition — counted separately from
    /// files on purpose, because "a skill was loaded" is not "a file was read".
    Skill,
    /// Pattern search — grep / glob / rg.
    Search,
    /// Directory listing.
    Dir,
    /// URL content retrieval.
    WebFetch,
    /// Web search.
    WebSearch,
    /// Memory search.
    MemorySearch,
    /// MCP tool *discovery*.
    IntegrationSearch,
    /// Subagent lifecycle.
    Subagent,
    /// Shell execute.
    Command,
    /// File edit **and** file write. There is deliberately no separate "write"
    /// kind: the reader cares that files changed, not which syscall did it.
    EditFile,
    /// MCP tool *dispatch*, grouped by server.
    McpCall(String),
    /// Anything classified but unrecognised.
    OtherTool,
    /// Lifecycle chrome — never labelled, never counted.
    NonCollapsible,
}

impl ToolKind {
    /// Past tense, or the present participle while the run is still going.
    pub fn verb(&self, running: bool) -> &'static str {
        use ToolKind::*;
        match self {
            File | Skill => {
                if running {
                    "Reading"
                } else {
                    "Read"
                }
            }
            Search | WebSearch | MemorySearch | IntegrationSearch => {
                if running {
                    "Searching"
                } else {
                    "Searched"
                }
            }
            Dir => {
                if running {
                    "Listing"
                } else {
                    "Listed"
                }
            }
            WebFetch => {
                if running {
                    "Fetching"
                } else {
                    "Fetched"
                }
            }
            Subagent | Command | OtherTool => {
                if running {
                    "Running"
                } else {
                    "Ran"
                }
            }
            EditFile => {
                if running {
                    "Editing"
                } else {
                    "Edited"
                }
            }
            McpCall(_) => {
                if running {
                    "Calling"
                } else {
                    "Called"
                }
            }
            NonCollapsible => "",
        }
    }

    /// Pluralization is strictly `count == 1 ? singular : plural`. No special
    /// cases and no zero form — a bucket with zero calls does not exist.
    ///
    /// `dir` and `MCP tool` are abbreviated deliberately: the summary is ONE
    /// row competing for width with three or four other clauses, and
    /// `directories` costs eight columns for no information.
    pub fn noun(&self, count: usize) -> &'static str {
        let one = count == 1;
        use ToolKind::*;
        match self {
            File | EditFile => {
                if one {
                    "file"
                } else {
                    "files"
                }
            }
            Skill => {
                if one {
                    "skill"
                } else {
                    "skills"
                }
            }
            Search => {
                if one {
                    "pattern"
                } else {
                    "patterns"
                }
            }
            Dir => {
                if one {
                    "dir"
                } else {
                    "dirs"
                }
            }
            WebFetch | WebSearch => {
                if one {
                    "website"
                } else {
                    "websites"
                }
            }
            MemorySearch => {
                if one {
                    "memory"
                } else {
                    "memories"
                }
            }
            IntegrationSearch | McpCall(_) => {
                if one {
                    "MCP tool"
                } else {
                    "MCP tools"
                }
            }
            Subagent => {
                if one {
                    "subagent"
                } else {
                    "subagents"
                }
            }
            Command => {
                if one {
                    "command"
                } else {
                    "commands"
                }
            }
            OtherTool => {
                if one {
                    "tool"
                } else {
                    "tools"
                }
            }
            NonCollapsible => "",
        }
    }

    /// Whether a call of this kind folds into the aggregated summary row.
    ///
    /// The "label-only" kinds return false: a shell command, a diff, an MCP
    /// dispatch, a web result or a subagent block is usually the most
    /// interesting thing on screen and keeps its own full rendering. Their
    /// vocabulary still exists so a *truncation* header can say `Ran 6
    /// commands` about rows it is hiding.
    pub fn folds_eagerly(&self) -> bool {
        use ToolKind::*;
        matches!(
            self,
            File | Skill | Search | Dir | MemorySearch | IntegrationSearch
        )
    }

    pub fn is_collapsible(&self) -> bool {
        self.folds_eagerly()
    }
}

/// Classify a finished tool call by name (+ args) into a collapse kind.
pub fn classify(name: &str, args: &str) -> ToolKind {
    let lower = name.to_lowercase();

    // MCP tools: mcp__server__tool → dispatch, grouped by server.
    if lower.starts_with("mcp__") {
        let server = lower.split("__").nth(1).unwrap_or("mcp").to_string();
        return ToolKind::McpCall(server);
    }

    match lower.as_str() {
        // Shell — CC parity (BashTool.isSearchOrReadCommand): only pure
        // search/read/list command pipelines collapse; any other command
        // renders in full with its `● Bash(cmd)` header + `⎿` output block.
        "bash" | "run_bash_command" | "shell" | "shell_execute" => classify_shell_command(args),
        // Read-family. A read of a skill definition is a Skill, not a File.
        "read" | "read_file" | "file_read" | "cat" | "head" | "tail" => classify_read(args),
        // Directory listing.
        "ls" | "list_directory" | "dir_list" | "list_dir" | "tree" | "du" => ToolKind::Dir,
        // Search / pattern matching.
        "grep" | "file_grep" | "glob" | "file_glob" | "rg" | "search" => ToolKind::Search,
        // Web. Label-only: OSA's web renderers carry the URL and the citation
        // list, which a `Fetched 1 website` clause would throw away.
        "web_fetch" | "webfetch" | "fetch" | "fetch_url" => ToolKind::WebFetch,
        "web_search" | "websearch" | "search_web" => ToolKind::WebSearch,
        // Memory / tool discovery — low-information lookups, so they fold.
        "memory_search" | "mem_search" | "recall" => ToolKind::MemorySearch,
        "search_tool" | "search_tools" | "find_tool" => ToolKind::IntegrationSearch,
        // Subagents. Label-only for the same reason as web.
        "task" | "agent" | "sub_agent" | "subagent" | "delegate" | "orchestrate" => {
            ToolKind::Subagent
        }
        // Edits and writes are one kind.
        "edit" | "file_edit" | "write" | "file_write" | "file_create" | "multiedit"
        | "apply_patch" => ToolKind::EditFile,
        "use_tool" | "call_tool" => ToolKind::McpCall("mcp".to_string()),
        "skill" | "invoke_skill" | "slash_command" => ToolKind::Skill,
        // Unclassified: labelled `Ran N tools` in a truncation header, but it
        // keeps its own full rendering in the transcript.
        _ => ToolKind::OtherTool,
    }
}

/// A read is a Skill when its target is a skill definition. Mirrors how
/// `extract_read_path` already recovers the path.
fn classify_read(args: &str) -> ToolKind {
    match extract_read_path(args) {
        Some(p) if is_skill_path(&p) => ToolKind::Skill,
        _ => ToolKind::File,
    }
}

fn is_skill_path(path: &str) -> bool {
    let lower = path.to_lowercase();
    lower.ends_with("/skill.md") || lower == "skill.md" || lower.contains("/skills/")
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
        ToolKind::File
    } else if has_list {
        ToolKind::Dir
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
fn named_read_summary(verb: &str, paths: &[String]) -> String {
    const SHOWN: usize = 3;
    let names: Vec<&str> = paths.iter().map(|p| basename(p)).collect();
    let head = names
        .iter()
        .take(SHOWN)
        .copied()
        .collect::<Vec<_>>()
        .join(", ");
    if names.len() > SHOWN {
        format!("{} {} +{} more", verb, head, names.len() - SHOWN)
    } else {
        format!("{} {}", verb, head)
    }
}

/// One clause of the summary row. Buckets are held in call order.
struct Bucket {
    kind: ToolKind,
    calls: usize,
    /// Read/Skill buckets only, for NAMING rather than counting. Ordered and
    /// de-duplicated: the summary prints these, so they must appear in the
    /// order the agent read them — a HashSet would shuffle them every render.
    read_paths: Vec<String>,
}

/// Accumulates a maximal consecutive run of eagerly-foldable tool calls.
///
/// A run is not restricted to one kind. Each kind gets its own bucket and its
/// own clause, and the clauses appear in the order their FIRST call happened,
/// so the row is a literal trace of what the agent did:
///
/// ```text
/// ◆ Read 1 skill, Searched 8 patterns, Listed 4 dirs, Read 2 files
/// ```
///
/// That line legitimately shows the verb `Read` twice — two buckets, two
/// nouns. Merging them would hide that a skill was loaded.
#[derive(Default)]
pub struct Accumulator {
    buckets: Vec<Bucket>,
    any_error: bool,
    failed: usize,
}

impl Accumulator {
    pub fn is_empty(&self) -> bool {
        self.buckets.is_empty()
    }

    /// Fold one finished collapsible tool into the run.
    pub fn add(&mut self, kind: &ToolKind, args: &str, success: bool) {
        if matches!(kind, ToolKind::NonCollapsible) {
            return;
        }
        if !success {
            self.any_error = true;
            self.failed += 1;
        }
        // Linear lookup, APPEND on miss. Append-on-miss *is* the ordering rule:
        // clauses come out in first-call order, not category order.
        let idx = match self.buckets.iter().position(|b| b.kind == *kind) {
            Some(i) => i,
            None => {
                self.buckets.push(Bucket {
                    kind: kind.clone(),
                    calls: 0,
                    read_paths: Vec::new(),
                });
                self.buckets.len() - 1
            }
        };
        let bucket = &mut self.buckets[idx];
        bucket.calls += 1;
        if matches!(kind, ToolKind::File | ToolKind::Skill) {
            if let Some(p) = extract_read_path(args) {
                if !bucket.read_paths.contains(&p) {
                    bucket.read_paths.push(p);
                }
            }
        }
    }

    /// The clause join of §2.2: `verb SP count SP noun`, separated by `", "`,
    /// no trailing separator and no Oxford-comma special case.
    fn label(&self, running: bool) -> String {
        // A run whose only bucket is a named read stays named. Naming files is
        // strictly more informative than counting them — "Read 1 file" told the
        // operator nothing about WHICH file. With a second bucket present the
        // row falls back to counts so it stays one line.
        if self.buckets.len() == 1 {
            let only = &self.buckets[0];
            if matches!(only.kind, ToolKind::File | ToolKind::Skill)
                && !only.read_paths.is_empty()
            {
                return named_read_summary(only.kind.verb(running), &only.read_paths);
            }
        }
        let mut out = String::new();
        for (i, bucket) in self.buckets.iter().enumerate() {
            if i > 0 {
                out.push_str(", ");
            }
            let n = bucket.calls;
            out.push_str(bucket.kind.verb(running));
            out.push(' ');
            out.push_str(&n.to_string());
            out.push(' ');
            out.push_str(bucket.kind.noun(n));
        }
        out
    }

    fn summary_text(&self) -> String {
        self.label(false)
    }

    /// The one row shape, finished or running. Both forms MUST come from this
    /// single function — two code paths drift, and the composer jumps when
    /// they do.
    fn render_line(&self, running: bool) -> Option<Line<'static>> {
        if self.is_empty() {
            return None;
        }
        let text = self.label(running);
        if text.is_empty() {
            return None;
        }
        let theme = crate::style::theme();
        // A failed run in a collapsed batch was signalled ONLY by recolouring
        // this bullet — so `● Searched 1 pattern` looked identical whether
        // the grep succeeded or blew up, under NO_COLOR or to a colour-blind
        // reader. Carry the failure in the glyph and in words.
        let (icon, icon_color) = if self.any_error {
            ("✗".to_string(), theme.colors.error)
        } else {
            (crate::tools::tool_bullet().to_string(), theme.colors.success)
        };
        let mut spans = vec![
            Span::styled(
                format!("{} ", icon),
                Style::default().fg(icon_color).add_modifier(Modifier::BOLD),
            ),
            Span::styled(text, Style::default().fg(theme.colors.muted)),
        ];
        if self.failed > 1 {
            spans.push(Span::styled(
                format!(" · {} failed", self.failed),
                Style::default().fg(theme.colors.error),
            ));
        } else if self.any_error {
            spans.push(Span::styled(
                " (failed)".to_string(),
                Style::default().fg(theme.colors.error),
            ));
        }
        Some(Line::from(spans))
    }

    /// Emit the run as a single styled scrollback line and reset. Returns None
    /// when the accumulator is empty.
    pub fn take_summary_line(&mut self) -> Option<Line<'static>> {
        let line = self.render_line(false);
        *self = Accumulator::default();
        line
    }

    /// The running label as plain text, for the one-row live status slot.
    /// Shares `label/2` with the committed row, so the live line and the line
    /// it becomes cannot word themselves differently.
    pub fn live_text(&self) -> Option<String> {
        if self.is_empty() {
            return None;
        }
        let text = self.label(true);
        if text.is_empty() {
            None
        } else {
            Some(text)
        }
    }

    /// The same row, in the present tense, without resetting — this is what the
    /// live activity slot paints while the run is still executing. It is fixed
    /// at one row and still shows the counts so far; it never degrades to a
    /// spinner or a generic "working".
    pub fn live_line(&self) -> Option<Line<'static>> {
        self.render_line(true)
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
            ToolKind::File
        );
        assert_eq!(
            classify("bash", r#"{"command":"ls -la && echo done"}"#),
            ToolKind::Dir
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
            acc.add(&ToolKind::File, p, true);
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
        acc.add(&ToolKind::File, "", true);
        acc.add(&ToolKind::File, "", true);
        assert_eq!(acc.summary_text(), "Read 2 files");
    }

    #[test]
    fn shell_execute_collapses_like_bash() {
        // OSA's own shell tool name was missing from `classify`, so a run of
        // read-only shell calls never collapsed.
        assert_eq!(
            classify("shell_execute", r#"{"command":"cat a.txt"}"#),
            ToolKind::File
        );
    }
}

// ── one row per run, not one row per KIND ───────────────────────────────────
//
// A mixed run used to emit a separate line per kind, because a kind change
// flushed the accumulator. Each kind now gets its own clause in one row, and
// the clauses come out in the order their first call happened.
#[cfg(test)]
mod multi_bucket_summary_tests {
    use super::*;

    fn run(calls: &[(ToolKind, &str)]) -> String {
        let mut acc = Accumulator::default();
        for (kind, args) in calls {
            acc.add(kind, args, true);
        }
        acc.summary_text()
    }

    #[test]
    fn a_mixed_run_is_one_row_with_a_clause_per_kind() {
        let mut calls = vec![(ToolKind::Skill, r#"{"path":"/s/skills/x/SKILL.md"}"#)];
        calls.extend(std::iter::repeat_n((ToolKind::Search, ""), 8));
        calls.extend(std::iter::repeat_n((ToolKind::Dir, ""), 4));
        calls.push((ToolKind::File, r#"{"path":"/a.rs"}"#));
        calls.push((ToolKind::File, r#"{"path":"/b.rs"}"#));
        assert_eq!(
            run(&calls),
            "Read 1 skill, Searched 8 patterns, Listed 4 dirs, Read 2 files"
        );
    }

    #[test]
    fn clause_order_follows_first_appearance_not_category() {
        // Same multiset, different call order — the row must read differently.
        assert_eq!(
            run(&[(ToolKind::Dir, ""), (ToolKind::Search, "")]),
            "Listed 1 dir, Searched 1 pattern"
        );
        assert_eq!(
            run(&[(ToolKind::Search, ""), (ToolKind::Dir, "")]),
            "Searched 1 pattern, Listed 1 dir"
        );
    }

    #[test]
    fn nouns_are_terse_and_pluralize_on_count_alone() {
        assert_eq!(run(&[(ToolKind::Dir, "")]), "Listed 1 dir");
        assert_eq!(
            run(&[(ToolKind::Dir, ""), (ToolKind::Dir, "")]),
            "Listed 2 dirs"
        );
    }

    #[test]
    fn a_run_of_one_still_folds() {
        assert_eq!(run(&[(ToolKind::Search, "")]), "Searched 1 pattern");
    }

    #[test]
    fn a_read_of_a_skill_definition_is_a_skill_not_a_file() {
        assert_eq!(
            classify("read", r#"{"path":"/home/u/.osa/skills/foo/SKILL.md"}"#),
            ToolKind::Skill
        );
        assert_eq!(classify("read", r#"{"path":"/src/main.rs"}"#), ToolKind::File);
    }

    #[test]
    fn the_running_form_shows_counts_in_the_present_tense() {
        let mut acc = Accumulator::default();
        acc.add(&ToolKind::File, r#"{"path":"/a.rs"}"#, true);
        acc.add(&ToolKind::Search, "", true);
        let live: String = acc
            .live_line()
            .expect("running run renders")
            .spans
            .iter()
            .map(|s| s.content.as_ref())
            .collect();
        assert!(live.contains("Reading 1 file"), "{live:?}");
        assert!(live.contains("Searching 1 pattern"), "{live:?}");
        // live_line does NOT consume the run.
        assert!(!acc.is_empty());
    }

    #[test]
    fn several_failures_are_counted_not_just_flagged() {
        let mut acc = Accumulator::default();
        acc.add(&ToolKind::Search, "", false);
        acc.add(&ToolKind::Search, "", false);
        let out: String = acc
            .take_summary_line()
            .expect("failed run renders")
            .spans
            .iter()
            .map(|s| s.content.as_ref())
            .collect();
        assert!(out.contains("2 failed"), "{out:?}");
    }

    #[test]
    fn label_only_kinds_keep_their_own_block() {
        for kind in [
            ToolKind::Command,
            ToolKind::EditFile,
            ToolKind::McpCall("x".to_string()),
            ToolKind::WebFetch,
            ToolKind::WebSearch,
            ToolKind::Subagent,
            ToolKind::OtherTool,
        ] {
            assert!(!kind.folds_eagerly(), "{kind:?} must not fold eagerly");
            // …but it still has vocabulary, for truncation headers.
            assert!(!kind.verb(false).is_empty(), "{kind:?} has no verb");
            assert!(!kind.noun(2).is_empty(), "{kind:?} has no plural noun");
        }
    }

    #[test]
    fn basename_handles_edge_shapes() {
        assert_eq!(basename("/a/b/c.rs"), "c.rs");
        assert_eq!(basename("c.rs"), "c.rs");
        assert_eq!(basename("/a/b/"), "b");
        assert_eq!(basename(""), "");
    }
}
