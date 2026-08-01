// Phase 2+: RenderOpts.truncated field — wired when tool output truncation indicator is added
#![allow(dead_code)]

pub mod agent;
pub mod bash;
pub mod collapse;
pub mod cron;
pub mod diagnostics;
pub mod file;
pub mod generic;
pub mod mcp;
pub mod monitor;
pub mod references;
pub mod search;
pub mod sleep;
pub mod todos;
pub mod web;

use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};

// ─── Status ───────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ToolStatus {
    Pending,
    AwaitingPermission,
    Running,
    Success,
    Error,
    Canceled,
}

// ─── RenderOpts ───────────────────────────────────────────────────────────────

pub struct RenderOpts {
    pub status: ToolStatus,
    pub width: u16,
    pub expanded: bool,
    pub compact: bool,
    pub spinner_frame: Option<char>,
    pub duration_ms: u64,
    pub truncated: bool,
}

// ─── Trait ────────────────────────────────────────────────────────────────────

pub trait ToolRenderer {
    fn render(&self, name: &str, args: &str, result: &str, opts: &RenderOpts) -> Vec<Line<'static>>;
}

// ─── Registry ─────────────────────────────────────────────────────────────────

/// Strip every `<system-reminder>…</system-reminder>` block from a tool result.
///
/// The backend appends cross-cutting reminders (finished background tasks, a
/// nearby `SKILL.md`, post-edit diagnostics) onto the tool result string so the
/// MODEL sees them in the same observation. They are internal steering text and
/// must never reach the user's screen — before this, a Write/Create preview
/// rendered the reminder as if it were the file's own content
/// (`+ <system-reminder>` …), which also exposed absolute paths from other
/// tools' skill directories.
///
/// An unterminated opening tag truncates the rest of the result, which is the
/// safe direction: better to show less than to leak internal text.
pub fn strip_system_reminders(result: &str) -> String {
    const OPEN: &str = "<system-reminder>";
    const CLOSE: &str = "</system-reminder>";

    if !result.contains(OPEN) {
        return result.to_string();
    }

    let mut out = String::with_capacity(result.len());
    let mut rest = result;

    while let Some(start) = rest.find(OPEN) {
        out.push_str(&rest[..start]);
        let after_open = &rest[start + OPEN.len()..];
        match after_open.find(CLOSE) {
            Some(end) => rest = &after_open[end + CLOSE.len()..],
            // Unterminated: drop everything from the opening tag on.
            None => {
                rest = "";
                break;
            }
        }
    }
    out.push_str(rest);
    out.trim_end().to_string()
}

pub fn render_tool(name: &str, args: &str, result: &str, opts: &RenderOpts) -> Vec<Line<'static>> {
    // Internal <system-reminder> steering is model-facing only — never render it
    // as tool output. Done once here so every renderer below is covered.
    let stripped;
    let result: &str = if result.contains("<system-reminder>") {
        stripped = strip_system_reminders(result);
        &stripped
    } else {
        result
    };

    let lower = name.to_lowercase();

    // MCP prefix: mcp__server__tool
    if lower.starts_with("mcp__") || lower == "mcp" || lower == "mcp_tool" {
        return mcp::McpRenderer.render(name, args, result, opts);
    }

    match lower.as_str() {
        // Bash. `shell_execute` is OSA's OWN shell tool name — it was missing
        // here, so every shell call fell through to the generic renderer and
        // lost its command/output card.
        "bash" | "run_bash_command" | "shell" | "shell_execute" => {
            bash::BashRenderer.render(name, args, result, opts)
        }

        // File: Read
        "read" | "read_file" | "file_read" => {
            file::FileViewRenderer.render(name, args, result, opts)
        }

        // File: Write
        "write" | "write_file" | "file_write" => {
            file::FileWriteRenderer.render(name, args, result, opts)
        }

        // File: Edit / MultiEdit / Download
        // `multi_file_edit` and `notebook_edit` are OSA's own names; both were
        // absent and rendered generically (no path, no diff).
        "edit" | "edit_file" | "file_edit" | "str_replace_editor"
        | "multiedit" | "multi_edit" | "multi_file_edit" | "notebook_edit"
        | "download" | "str_replace_based_edit_tool" => {
            file::FileEditRenderer.render(name, args, result, opts)
        }

        // Search: Glob
        "glob" | "file_glob" => {
            search::GlobRenderer.render(name, args, result, opts)
        }

        // Search: Grep
        "grep" | "file_grep" => {
            search::GrepRenderer.render(name, args, result, opts)
        }

        // Search: LS
        "ls" | "list_directory" | "dir_list" | "list_dir" => {
            search::LsRenderer.render(name, args, result, opts)
        }

        // Web
        "web_fetch" | "webfetch" | "fetch" => {
            web::WebFetchRenderer.render(name, args, result, opts)
        }
        "web_search" | "websearch" => {
            web::WebSearchRenderer.render(name, args, result, opts)
        }

        // Agent / Task
        "task" | "agent" | "sub_agent" | "orchestrate" => {
            agent::AgentRenderer.render(name, args, result, opts)
        }
        "delegate" => {
            agent::DelegateRenderer.render(name, args, result, opts)
        }

        // Todos
        "todoread" | "todowrite" | "todos" | "task_write" => {
            todos::TodosRenderer.render(name, args, result, opts)
        }

        // Cron / Schedule
        "cron" | "schedule" => {
            cron::CronRenderer.render(name, args, result, opts)
        }

        // Sleep
        "sleep" | "wait" | "pause" => {
            sleep::SleepRenderer.render(name, args, result, opts)
        }

        // Monitor / Watch
        "monitor" | "watch" => {
            monitor::MonitorRenderer.render(name, args, result, opts)
        }

        // Remote trigger
        "remote_trigger" | "trigger" => {
            cron::CronRenderer.render(name, args, result, opts)
        }

        // Diagnostics
        "diagnostics" => {
            diagnostics::DiagnosticsRenderer.render(name, args, result, opts)
        }

        // References
        "references" => {
            references::ReferencesRenderer.render(name, args, result, opts)
        }

        // Generic fallback
        _ => generic::GenericRenderer.render(name, args, result, opts),
    }
}

// ─── Shared Helpers ───────────────────────────────────────────────────────────

/// The tool/assistant bullet glyph, matching Claude Code's `figures.ts`:
/// `⏺` (U+23FA) only on macOS, `●` (U+25CF) everywhere else. On Linux the
/// record-style `⏺` renders as tofu in most fonts, which is exactly why the
/// bullet looked wrong — real Claude Code shows `●` here.
pub(crate) fn tool_bullet() -> &'static str {
    if cfg!(target_os = "macos") {
        "\u{23fa}" // ⏺
    } else {
        "\u{25cf}" // ●
    }
}

/// Returns `(icon_string, icon_style)` for a given status.
///
/// Colors mirror Claude Code's `ToolUseLoader`: unresolved → dim/default,
/// error → red, success → green. (`color = isUnresolved ? undefined : isError
/// ? "error" : "success"`, with `dimColor` while unresolved.)
pub(crate) fn status_icon(status: ToolStatus, spinner: Option<char>) -> (String, Style) {
    let theme = crate::style::theme();
    let bullet = tool_bullet().to_string();
    match status {
        ToolStatus::Pending => (
            bullet, // dim until it resolves
            Style::default().fg(theme.colors.dim),
        ),
        ToolStatus::AwaitingPermission => (
            "◐".to_string(),
            Style::default()
                .fg(theme.colors.secondary)
                .add_modifier(Modifier::BOLD),
        ),
        ToolStatus::Running => {
            // Claude Code blinks the dimmed circle while a tool is unresolved.
            let icon = spinner
                .map(|c| c.to_string())
                .unwrap_or(bullet);
            (icon, Style::default().fg(theme.colors.muted))
        }
        ToolStatus::Success => (
            bullet, // ● green — Claude Code resolved-success color
            Style::default()
                .fg(theme.colors.success)
                .add_modifier(Modifier::BOLD),
        ),
        ToolStatus::Error => (
            bullet, // ● red — Claude Code error color
            Style::default()
                .fg(theme.colors.error)
                .add_modifier(Modifier::BOLD),
        ),
        ToolStatus::Canceled => (
            "⊘".to_string(),
            Style::default().fg(theme.colors.muted),
        ),
    }
}

/// Human-readable duration: "55ms", "1.2s", "2m 3s".
pub(crate) fn format_duration(ms: u64) -> String {
    if ms == 0 {
        return String::new();
    }
    if ms < 1000 {
        return format!("{}ms", ms);
    }
    let secs = ms as f64 / 1000.0;
    if secs < 60.0 {
        return format!("{:.1}s", secs);
    }
    let minutes = (secs / 60.0) as u64;
    let remaining = secs as u64 % 60;
    format!("{}m {}s", minutes, remaining)
}

/// Truncate `lines` to `max`, appending CC's dim "… +N lines (ctrl+o to expand)" hint.
pub(crate) fn truncate_lines(mut lines: Vec<Line<'static>>, max: usize) -> Vec<Line<'static>> {
    if lines.len() <= max {
        return lines;
    }
    let total = lines.len();
    lines.truncate(max);
    let theme = crate::style::theme();
    lines.push(Line::from(Span::styled(
        format!("… +{} lines (ctrl+o to expand)", total - max),
        Style::default().fg(theme.colors.dim),
    )));
    lines
}

/// CC's OutputLine wrap width: terminal width minus the `  ⎿  ` gutter and a
/// small overflow guard (PADDING_TO_PREVENT_OVERFLOW), never below 10 columns.
pub(crate) fn body_wrap_width(width: u16) -> usize {
    (width as usize).saturating_sub(7).max(10)
}

/// Width-aware hard wrap of one logical line into visual rows so tool output
/// never clips horizontally — the chat Paragraph for tool cards does not wrap,
/// and CC counts WRAPPED rows for its 3-line cap (renderTruncatedContent).
pub(crate) fn wrap_plain(s: &str, cols: usize) -> Vec<String> {
    use unicode_width::UnicodeWidthChar;
    if s.is_empty() {
        return vec![String::new()];
    }
    let mut rows = Vec::new();
    let mut cur = String::new();
    let mut w = 0usize;
    for ch in s.chars() {
        let cw = UnicodeWidthChar::width(ch).unwrap_or(0);
        if w + cw > cols && !cur.is_empty() {
            rows.push(std::mem::take(&mut cur));
            w = 0;
        }
        cur.push(ch);
        w += cw;
    }
    rows.push(cur);
    rows
}

/// CC's collapsed output cap (utils/terminal.ts MAX_LINES_TO_SHOW).
pub(crate) const MAX_LINES_TO_SHOW: usize = 3;

/// CC's collapsed tool output (OutputLine/renderTruncatedContent): up to 3
/// dimmed, width-wrapped visual lines; exactly 4 print in full (CC's
/// remainingLines==1 case); more get "… +N lines (ctrl+o to expand)".
/// Errors render red. Empty result → empty vec (caller decides fallback).
pub(crate) fn collapsed_result_block(
    result: &str,
    width: u16,
    is_error: bool,
) -> Vec<Line<'static>> {
    let theme = crate::style::theme();
    let trimmed = result.trim_end();
    if trimmed.is_empty() {
        return Vec::new();
    }
    let cols = body_wrap_width(width);
    let out_style = if is_error {
        Style::default().fg(theme.colors.error)
    } else {
        Style::default().fg(theme.colors.muted)
    };
    let all: Vec<String> = trimmed.lines().flat_map(|l| wrap_plain(l, cols)).collect();
    let shown = if all.len() == MAX_LINES_TO_SHOW + 1 {
        all.len()
    } else {
        all.len().min(MAX_LINES_TO_SHOW)
    };
    let mut body: Vec<Line<'static>> = Vec::with_capacity(shown + 1);
    for line in &all[..shown] {
        body.push(Line::from(Span::styled(line.clone(), out_style)));
    }
    if all.len() > shown {
        body.push(Line::from(Span::styled(
            format!("… +{} lines (ctrl+o to expand)", all.len() - shown),
            Style::default().fg(theme.colors.dim),
        )));
    }
    body
}

/// Claude Code's result connector (MessageResponse.tsx): the first body line
/// hangs off the header with a dim `  ⎿  `; continuation lines get a matching
/// 5-column indent so the block stays aligned under the connector.
pub(crate) fn result_connector(first: bool) -> Span<'static> {
    let theme = crate::style::theme();
    let glyph = if first { "  \u{23bf}  " } else { "     " };
    Span::styled(glyph.to_string(), Style::default().fg(theme.colors.muted))
}

/// Indent a result body under its header, CC style:
/// `[header, "  ⎿  line1", "     line2", …]`.
pub(crate) fn render_tool_box(
    header: Line<'static>,
    body: Vec<Line<'static>>,
) -> Vec<Line<'static>> {
    let mut out: Vec<Line<'static>> = Vec::with_capacity(body.len() + 1);
    out.push(header);

    for (i, line) in body.into_iter().enumerate() {
        let mut spans: Vec<Span<'static>> = Vec::with_capacity(line.spans.len() + 1);
        spans.push(result_connector(i == 0));
        spans.extend(line.spans);
        out.push(Line::from(spans));
    }

    out
}

/// Path-ish argument keys. When `args` is a BARE string rather than JSON, it is
/// the value of one of these — see [`parse_json_arg`].
const PATH_KEYS: &[&str] = &[
    "path",
    "file_path",
    "filename",
    "target_file",
    "file",
    "notebook_path",
];

/// Extract the first matching key value from a JSON string (args).
/// Handles string and number values.
///
/// `args` is NOT always JSON. The backend's `ToolHint.summarize/1` sends a
/// plain display string for every tool except `file_edit` (which needs its full
/// argument map so the diff can be rendered), so a `file_read`/`file_write`/
/// `dir_list` call arrives as a bare `"/src/main.rs"`. Parsed strictly as JSON
/// that yields `None`, which is why those cells rendered their `"…"` path
/// placeholder and why collapsed runs degraded to an anonymous `Read 1 file`.
/// When the caller is asking for a path and `args` looks like one, the bare
/// string IS the answer.
pub(crate) fn parse_json_arg(args: &str, keys: &[&str]) -> Option<String> {
    let trimmed = args.trim();
    if trimmed.is_empty() {
        return None;
    }

    if !trimmed.starts_with('{') && !trimmed.starts_with('[') {
        // Bare value. Only honour it for a path lookup — handing a raw command
        // string back to a caller asking for `old_string` would be a lie.
        let wants_path = keys.iter().any(|k| PATH_KEYS.contains(k));
        if wants_path && looks_like_path(trimmed) {
            return Some(trimmed.to_string());
        }
        return None;
    }

    let v: serde_json::Value = serde_json::from_str(trimmed).ok()?;
    for key in keys {
        if let Some(val) = v.get(*key) {
            match val {
                serde_json::Value::String(s) => return Some(s.clone()),
                serde_json::Value::Number(n) => return Some(n.to_string()),
                serde_json::Value::Bool(b) => return Some(b.to_string()),
                _ => {}
            }
        }
    }
    None
}

/// Whether a bare argument string is plausibly a filesystem path rather than a
/// command, a question or free prose. Conservative on purpose: a false positive
/// here would put a shell command where a filename belongs.
pub(crate) fn looks_like_path(s: &str) -> bool {
    if s.contains(char::is_whitespace) || s.len() > 512 {
        return false;
    }
    s.starts_with('/') || s.starts_with("./") || s.starts_with("~/") || s.contains('/')
}

/// Build a standard single-line collapsed header:
///   `<icon> <tool_name>  <detail>  <duration>`
pub(crate) fn make_header(
    status: ToolStatus,
    spinner: Option<char>,
    tool_display: &str,
    detail: &str,
    duration_ms: u64,
) -> Line<'static> {
    let theme = crate::style::theme();
    let (icon, icon_style) = status_icon(status, spinner);

    // Shorten $HOME → ~ so tool lines aren't cluttered with long absolute paths.
    let detail = match std::env::var("HOME") {
        Ok(h) if !h.is_empty() && !detail.is_empty() => detail.replace(&h, "~"),
        _ => detail.to_string(),
    };

    // Format: ● ToolName(args) — CC parity: bold tool name, plain args
    // (AssistantToolUseMessage renders <Text bold>{name}</Text><Text>({args})</Text>).
    let mut spans = vec![
        Span::styled(icon, icon_style),
        Span::raw(" "),
        Span::styled(
            tool_display.to_string(),
            theme.tool_name().add_modifier(Modifier::BOLD),
        ),
    ];
    if !detail.is_empty() {
        spans.push(Span::styled(format!("({})", detail), Style::default()));
    }

    // Duration on the same line for compact mode
    let dur = format_duration(duration_ms);
    if !dur.is_empty() {
        spans.push(Span::raw("  "));
        spans.push(Span::styled(dur, theme.tool_duration()));
    }

    Line::from(spans)
}

/// Like [`make_header`], but the parenthesized `detail` is an OSC 8 hyperlink to
/// `full_path` (its `file://` URL) on capable terminals — so the file path in a
/// tool header (`● Read(src/main.rs)`) is cmd/ctrl-clickable and opens in the
/// user's editor/viewer. `display_detail` is what's shown (already ellipsized /
/// `$HOME`-shortened by the caller path); `full_path` is the absolute path used
/// only to build the link target. Falls back to plain text exactly like
/// `make_header` when hyperlinks are unsupported or the path can't be resolved.
pub(crate) fn make_header_path(
    status: ToolStatus,
    spinner: Option<char>,
    tool_display: &str,
    display_detail: &str,
    full_path: &str,
    duration_ms: u64,
) -> Line<'static> {
    let theme = crate::style::theme();
    let (icon, icon_style) = status_icon(status, spinner);

    // Shorten $HOME → ~ for display (matches make_header).
    let detail = match std::env::var("HOME") {
        Ok(h) if !h.is_empty() && !display_detail.is_empty() => display_detail.replace(&h, "~"),
        _ => display_detail.to_string(),
    };

    let mut spans = vec![
        Span::styled(icon, icon_style),
        Span::raw(" "),
        Span::styled(
            tool_display.to_string(),
            theme.tool_name().add_modifier(Modifier::BOLD),
        ),
    ];
    if !detail.is_empty() {
        spans.push(Span::raw("(".to_string()));
        match crate::components::osc8::path_to_file_url(full_path) {
            Some(url) => spans.push(crate::components::osc8::hyperlink_span(
                detail,
                &url,
                Style::default(),
            )),
            None => spans.push(Span::styled(detail, Style::default())),
        }
        spans.push(Span::raw(")".to_string()));
    }

    let dur = format_duration(duration_ms);
    if !dur.is_empty() {
        spans.push(Span::raw("  "));
        spans.push(Span::styled(dur, theme.tool_duration()));
    }

    Line::from(spans)
}

/// Create a tree-line result row: └ Done · 31ms  or  └ Error · reason
pub(crate) fn make_result_line(
    status: ToolStatus,
    duration_ms: u64,
    _result_preview: &str,
) -> Line<'static> {
    let theme = crate::style::theme();
    let status_text = match status {
        ToolStatus::Success => "Done",
        ToolStatus::Error => "Error",
        ToolStatus::Running => "Running",
        ToolStatus::Pending => "Pending",
        ToolStatus::Canceled => "Canceled",
        ToolStatus::AwaitingPermission => "Awaiting",
    };
    let dur = format_duration(duration_ms);
    let detail = if dur.is_empty() {
        status_text.to_string()
    } else {
        format!("{} · {}", status_text, dur)
    };

    Line::from(vec![
        Span::styled("└ ".to_string(), Style::default().fg(theme.colors.muted)),
        Span::styled(
            detail,
            Style::default().fg(if status == ToolStatus::Success {
                theme.colors.success
            } else if status == ToolStatus::Error {
                theme.colors.error
            } else {
                theme.colors.muted
            }),
        ),
    ])
}

// ---------------------------------------------------------------------------
// Regression tests: multi-byte-safe header/preview shortening in every tool
// renderer. Each case feeds a payload whose UTF-8 boundaries do NOT line up
// with the renderer's fixed byte cut points, so the previous `&s[..N]` byte
// slices would panic ("byte index N is not a char boundary"). A leading ASCII
// 'a' shifts the 3-byte '€' run off every multiple-of-3 cut point, guaranteeing
// a mid-char index at 50/55/57/60/80/120. Passing == no panic.
// ---------------------------------------------------------------------------
#[cfg(test)]
mod system_reminder_tests {
    use super::*;

    const REMINDER: &str = "<system-reminder>\nA skill \"writing-great-skills\" is available near a path you just accessed.\nIts definition is at /Users/rhl/.claude/skills/writing-great-skills/SKILL.md\n</system-reminder>";

    #[test]
    fn strips_a_trailing_reminder_block() {
        let raw = format!("Wrote 12 lines to notes.md\n\n{REMINDER}");
        let out = strip_system_reminders(&raw);
        assert_eq!(out, "Wrote 12 lines to notes.md");
        assert!(!out.contains("system-reminder"));
        assert!(!out.contains(".claude/skills"));
    }

    #[test]
    fn strips_multiple_blocks_and_keeps_surrounding_text() {
        let raw = format!("head\n{REMINDER}\nmiddle\n{REMINDER}\ntail");
        let out = strip_system_reminders(&raw);
        assert!(out.starts_with("head"));
        assert!(out.contains("middle"));
        assert!(out.ends_with("tail"));
        assert!(!out.contains("system-reminder"));
    }

    #[test]
    fn leaves_ordinary_output_untouched() {
        let raw = "Replaced in compactor.ex\n--- a\n+++ b\n+ @impl Foo";
        assert_eq!(strip_system_reminders(raw), raw);
    }

    #[test]
    fn unterminated_open_tag_drops_the_remainder() {
        let raw = "Wrote it\n<system-reminder>\nleaked internal text";
        let out = strip_system_reminders(raw);
        assert_eq!(out, "Wrote it");
    }

    #[test]
    fn render_tool_never_shows_reminder_text() {
        let raw = format!("Wrote 12 lines to notes.md\n\n{REMINDER}");
        let opts = RenderOpts {
            status: ToolStatus::Success,
            width: 100,
            expanded: true,
            compact: false,
            spinner_frame: None,
            duration_ms: 0,
            truncated: false,
        };

        for tool in ["file_write", "file_edit", "file_read", "shell_execute", "some_unknown_tool"] {
            let lines = render_tool(tool, "{\"path\":\"notes.md\"}", &raw, &opts);
            let text: String = lines
                .iter()
                .map(|l| {
                    l.spans
                        .iter()
                        .map(|s| s.content.as_ref())
                        .collect::<String>()
                })
                .collect::<Vec<_>>()
                .join("\n");

            assert!(
                !text.contains("system-reminder"),
                "{tool} leaked the reminder tag: {text}"
            );
            assert!(
                !text.contains(".claude/skills"),
                "{tool} leaked a foreign skills path: {text}"
            );
        }
    }
}

#[cfg(test)]
mod render_edge_tests {
    use super::*;

    /// "a" + `n` euro signs — 1 + 3n bytes, so the fixed cut points all land
    /// inside a multi-byte char.
    fn mb(n: usize) -> String {
        format!("a{}", "\u{20ac}".repeat(n))
    }

    fn opts(expanded: bool) -> RenderOpts {
        RenderOpts {
            status: ToolStatus::Success,
            width: 80,
            expanded,
            compact: false,
            spinner_frame: None,
            duration_ms: 1234,
            truncated: false,
        }
    }

    #[test]
    fn bash_renderer_multibyte_never_panics() {
        let args = format!("{{\"command\":\"{}\"}}", mb(40));
        let result = format!("{}\nsecond line", mb(40));
        for exp in [false, true] {
            let _ = bash::BashRenderer.render("Bash", &args, &result, &opts(exp));
        }
        // Non-JSON args path too (command = first-chars fallback).
        let _ = bash::BashRenderer.render("Bash", &mb(40), &mb(40), &opts(false));
    }

    #[test]
    fn web_renderer_multibyte_never_panics() {
        let fetch_args = format!("{{\"url\":\"{}\"}}", mb(40));
        for exp in [false, true] {
            let _ = web::WebFetchRenderer.render("WebFetch", &fetch_args, &mb(50), &opts(exp));
        }
        let search_args = format!("{{\"query\":\"{}\"}}", mb(10));
        let search_result = format!(
            "[{{\"title\":\"{}\",\"url\":\"{}\",\"snippet\":\"{}\"}}]",
            mb(10),
            mb(30),
            mb(60)
        );
        for exp in [false, true] {
            let _ =
                web::WebSearchRenderer.render("WebSearch", &search_args, &search_result, &opts(exp));
        }
    }

    #[test]
    fn mcp_renderer_multibyte_never_panics() {
        let name = format!("mcp__server__{}", mb(30));
        let args = format!("{{\"payload\":\"{}\"}}", mb(40));
        for exp in [false, true] {
            let _ = mcp::McpRenderer.render(&name, &args, &mb(40), &opts(exp));
        }
    }

    #[test]
    fn agent_renderer_multibyte_never_panics() {
        let args = format!("{{\"task\":\"{}\"}}", mb(40));
        for exp in [false, true] {
            let _ = agent::AgentRenderer.render("Agent", &args, &mb(40), &opts(exp));
            let _ = agent::DelegateRenderer.render("Delegate", &args, &mb(40), &opts(exp));
        }
    }

    #[test]
    fn generic_renderer_multibyte_never_panics() {
        // Nested object with no top-level string value forces the compact-JSON
        // fallback path (the one that byte-sliced at 60).
        let args = format!("{{\"k\":{{\"n\":\"{}\"}}}}", mb(40));
        for exp in [false, true] {
            let _ = generic::GenericRenderer.render("mystery_tool", &args, &mb(40), &opts(exp));
        }
    }

    #[test]
    fn dispatcher_multibyte_never_panics() {
        let args = format!("{{\"command\":\"{}\"}}", mb(40));
        for name in ["Bash", "WebFetch", "mcp__srv__tool", "Agent", "whatever"] {
            let _ = render_tool(name, &args, &mb(40), &opts(false));
            let _ = render_tool(name, &args, &mb(40), &opts(true));
        }
    }
}

// ─── Tool-cell identity ──────────────────────────────────────────────────────
//
// Every file-touching cell must NAME ITS FILE. It shipped naming nothing
// ("⏺ Edit" / "⏺ Read 1 file"), which made a transcript of several edits
// unreadable and left the agent unable to confirm its own edit landed.
#[cfg(test)]
mod cell_identity_tests {
    use super::*;

    fn cell_opts() -> RenderOpts {
        RenderOpts {
            status: ToolStatus::Success,
            width: 100,
            expanded: false,
            compact: true,
            spinner_frame: None,
            duration_ms: 12,
            truncated: false,
        }
    }

    fn flatten(lines: &[ratatui::text::Line<'static>]) -> String {
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

    // ── parse_json_arg: the backend does not always send JSON ────────────

    #[test]
    fn a_bare_path_is_accepted_as_the_path() {
        // What `ToolHint.summarize/1` sends for file_read / file_write /
        // dir_list — a plain display string, not a JSON document.
        assert_eq!(
            parse_json_arg("/src/main.rs", &["path", "file_path"]),
            Some("/src/main.rs".to_string())
        );
        assert_eq!(
            parse_json_arg("  ./lib/app.ex  ", &["file_path"]),
            Some("./lib/app.ex".to_string())
        );
    }

    #[test]
    fn a_bare_non_path_is_not_mistaken_for_one() {
        // A shell command must never be shown where a filename belongs.
        assert_eq!(parse_json_arg("cargo test --release", &["path"]), None);
        // ...and a bare value is never handed to a non-path lookup.
        assert_eq!(parse_json_arg("/src/main.rs", &["old_string"]), None);
        assert_eq!(parse_json_arg("", &["path"]), None);
    }

    #[test]
    fn json_args_still_win() {
        let args = r#"{"path":"/src/main.rs","old_string":"a","new_string":"b"}"#;
        assert_eq!(
            parse_json_arg(args, &["path"]),
            Some("/src/main.rs".to_string())
        );
        assert_eq!(parse_json_arg(args, &["old_string"]), Some("a".to_string()));
    }

    // ── the rendered cells ───────────────────────────────────────────────

    #[test]
    fn an_edit_cell_names_its_file_for_every_arg_shape() {
        let shapes = [
            // Full JSON — what file_edit sends so the diff can be rendered.
            r#"{"path":"/proj/src/compactor.ex","old_string":"a\nb","new_string":"a\nc"}"#
                .to_string(),
            // Bare path — the fallback when the arg map cannot be encoded.
            "/proj/src/compactor.ex".to_string(),
        ];
        for args in shapes {
            let out = flatten(&render_tool("file_edit", &args, "", &cell_opts()));
            assert!(
                out.contains("compactor.ex"),
                "edit cell did not name its file for args {args:?}:\n{out}"
            );
        }
    }

    #[test]
    fn a_read_cell_names_its_file() {
        let out = flatten(&render_tool(
            "file_read",
            "/proj/src/main.rs",
            "l1\nl2",
            &cell_opts(),
        ));
        assert!(
            out.contains("main.rs"),
            "read cell did not name its file:\n{out}"
        );
    }

    #[test]
    fn a_write_cell_names_its_file() {
        let out = flatten(&render_tool(
            "file_write",
            "/proj/src/new.rs",
            "",
            &cell_opts(),
        ));
        assert!(
            out.contains("new.rs"),
            "write cell did not name its file:\n{out}"
        );
    }

    // ── dispatch coverage for OSA's own tool names ───────────────────────

    #[test]
    fn osa_tool_names_reach_their_real_renderers() {
        // `shell_execute`, `multi_file_edit` and `notebook_edit` are OSA's own
        // names and were absent from the dispatch, so they fell through to the
        // generic renderer, which prints the raw tool name and no card.
        let shell = flatten(&render_tool(
            "shell_execute",
            r#"{"command":"cargo test"}"#,
            "ok",
            &cell_opts(),
        ));
        assert!(
            !shell.contains("shell_execute("),
            "shell_execute still hits the generic renderer:\n{shell}"
        );
        assert!(shell.contains("cargo test"), "{shell}");

        for name in ["multi_file_edit", "notebook_edit"] {
            let out = flatten(&render_tool(
                name,
                r#"{"path":"/proj/src/main.rs","old_string":"a","new_string":"b"}"#,
                "",
                &cell_opts(),
            ));
            assert!(
                out.contains("main.rs"),
                "{name} did not name its file:\n{out}"
            );
        }
    }
}
