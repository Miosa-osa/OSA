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
    strip_tag_blocks(result, "system-reminder")
}

/// Every tag the backend uses to carry INTERNAL control plumbing in text the
/// model can see. None of it may ever reach the user's screen.
///
/// `task-notification` is here because background completions re-enter the
/// agent's context as a `<task-notification>` XML block (see
/// `Agent.TaskNotifications`). For the Anthropic provider those blocks are
/// hoisted into the system prompt, and models demonstrably echo them back into
/// their own reply — the observed leak was an assistant message whose body was
/// a mangled re-typing of the notification (duplicated `<output-file>`,
/// `</status>` closing an `<output-file>`). A re-typed block is exactly what
/// this must survive, so stripping is tag-scoped and tolerant of malformed
/// innards: everything between the opening and closing root tag goes,
/// whatever it contains.
pub const CONTROL_TAGS: [&str; 2] = ["system-reminder", "task-notification"];

/// Strip every internal control block (see [`CONTROL_TAGS`]) from `text`.
pub fn strip_control_markup(text: &str) -> String {
    if !CONTROL_TAGS.iter().any(|t| text.contains(&format!("<{t}>"))) {
        return text.to_string();
    }
    let mut out = text.to_string();
    for tag in CONTROL_TAGS {
        out = strip_tag_blocks(&out, tag);
    }
    out
}

/// Remove every `<tag>…</tag>` block from `text`.
///
/// An unterminated opening tag truncates the rest of the text, which is the
/// safe direction: better to show less than to leak internal text.
fn strip_tag_blocks(text: &str, tag: &str) -> String {
    let open = format!("<{tag}>");
    let close = format!("</{tag}>");

    if !text.contains(&open) {
        return text.to_string();
    }

    let mut out = String::with_capacity(text.len());
    let mut rest = text;

    while let Some(start) = rest.find(&open) {
        out.push_str(&rest[..start]);
        let after_open = &rest[start + open.len()..];
        match after_open.find(&close) {
            Some(end) => rest = &after_open[end + close.len()..],
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

/// Render a tool call card.
///
/// Both `args` and `result` are fully attacker-reachable — `result` is a shell's
/// stdout, a file body off a hostile repo, grep hits, or an MCP server's
/// payload — and every renderer below turns them into spans. A raw `\x1b` in any
/// of that is carried by ratatui straight to the terminal, which executes it.
///
/// The scrub is applied to the rendered [`Line`]s rather than to `args`, and
/// that is deliberate: most renderers parse `args` as JSON first, so a payload
/// written as `{"command":"cat ]0;PWNED"}` carries no control byte
/// until *after* the parse. Scrubbing the output catches it wherever it entered,
/// covers all ~15 renderers from one place, and covers any renderer added later.
/// See [`crate::render::sanitize::scrub_rendered_lines`], which preserves the
/// OSC 8 wrappers the autolinker legitimately emits.
pub fn render_tool(name: &str, args: &str, result: &str, opts: &RenderOpts) -> Vec<Line<'static>> {
    let mut lines = render_tool_dispatch(name, args, result, opts);
    if opts.status == ToolStatus::Error {
        force_failure_body(&mut lines, result);
    }
    apply_commit_cap(&mut lines);
    crate::render::sanitize::scrub_rendered_lines(&mut lines);
    lines
}

/// Default ceiling on the rows one committed tool block may occupy.
///
/// In a retained-widget TUI an expanded 5000-row body is merely long. OSA is
/// **print-once**: these rows go into the terminal's own scrollback via
/// `insert_before` and can never be re-rendered, re-wrapped or folded again. An
/// uncapped commit therefore dumps thousands of rows the operator cannot
/// usefully scroll past and cannot undo, and bursts them at the writer in one
/// go. 2000 is generous enough that no ordinary tool cell ever meets it.
pub(crate) const DEFAULT_MAX_COMMIT_ROWS: usize = 2000;

/// The configured commit-row ceiling. `OSA_MAX_COMMIT_ROWS=0` means unbounded;
/// an unset or unparseable value means [`DEFAULT_MAX_COMMIT_ROWS`].
pub(crate) fn max_commit_rows() -> usize {
    match std::env::var("OSA_MAX_COMMIT_ROWS") {
        Ok(v) => v.trim().parse::<usize>().unwrap_or(DEFAULT_MAX_COMMIT_ROWS),
        Err(_) => DEFAULT_MAX_COMMIT_ROWS,
    }
}

/// Clip an over-long block to the commit ceiling, replacing the final row with
/// an honest count of what was dropped.
///
/// **The block is laid out at its full height first and only then clipped**, so
/// every surviving row wraps exactly where it would have in an uncapped commit.
/// Re-wrapping at the cap would change the content of rows that were not
/// dropped, which is a different and worse lie than dropping them.
///
/// The pointer is `/transcript` rather than `ctrl+o`, because ctrl+o cannot help
/// here: the expanded form is what overflowed.
fn apply_commit_cap(lines: &mut Vec<Line<'static>>) {
    let cap = max_commit_rows();
    if cap == 0 || lines.len() <= cap {
        return;
    }
    let hidden = lines.len() - (cap - 1);
    lines.truncate(cap - 1);
    let theme = crate::style::theme();
    lines.push(Line::from(Span::styled(
        format!("\u{2026} {} more lines \u{2014} /transcript to view", hidden),
        Style::default()
            .fg(theme.colors.dim)
            .bg(ratatui::style::Color::Reset),
    )));
}

/// The failure of a tool call must be legible as TEXT, not only as the colour of
/// its bullet.
///
/// Most renderers summarise `result` as if it were the tool's *content*, and
/// they do it without consulting `opts.status`. A read that failed therefore
/// rendered
///
/// ```text
/// ● Read(/tmp/x.rs)  40ms
///   ⎿  Read 1 line (ctrl+o to expand)
/// ```
///
/// — the "1 line" being the error message — and a failed grep claimed it had
/// *Found* 1 line. Both are actively false, and the only thing separating them
/// from the successful render was a red vs green `●`: invisible under
/// `NO_COLOR`, in a monochrome terminal, and to a red/green-colour-blind reader.
///
/// So on an errored call: keep the header (it carries the tool, its target and
/// the duration), and make the body the error itself — unless the renderer
/// already put the error text on screen, which Bash and the web tools do, and
/// whose richer failure cells are worth keeping.
fn force_failure_body(lines: &mut Vec<Line<'static>>, result: &str) {
    let body = result.trim();
    if body.is_empty() {
        return;
    }
    // First non-empty line of the error is the part worth promoting.
    let first = body.lines().find(|l| !l.trim().is_empty()).unwrap_or(body).trim();
    let rendered: String = lines
        .iter()
        .flat_map(|l| l.spans.iter())
        .map(|s| s.content.as_ref())
        .collect();
    if rendered.contains(first) {
        return; // the renderer already showed it
    }
    let theme = crate::style::theme();
    let header = lines.first().cloned();
    lines.clear();
    if let Some(h) = header {
        lines.push(h);
    }
    let text = crate::util::truncate_str(first, 200).to_string();
    lines.push(Line::from(vec![
        Span::styled("  ⎿  ".to_string(), Style::default().fg(theme.colors.muted)),
        Span::styled(text, Style::default().fg(theme.colors.error)),
    ]));
}

fn render_tool_dispatch(
    name: &str,
    args: &str,
    result: &str,
    opts: &RenderOpts,
) -> Vec<Line<'static>> {
    // Internal control markup (<system-reminder>, <task-notification>) is
    // model-facing only — never render it as tool output. Done once here so
    // every renderer below is covered.
    let stripped;
    let result: &str = if CONTROL_TAGS.iter().any(|t| result.contains(&format!("<{t}>"))) {
        stripped = strip_control_markup(result);
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

        // Web. `fetch_url` / `search_web` / `search` are OSA's own registered
        // ALIASES for these tools (see the `aliases/0` callbacks); a call made
        // under an alias arrives here under that name and used to fall through
        // to the generic renderer, losing the url / query.
        "web_fetch" | "webfetch" | "fetch" | "fetch_url" => {
            web::WebFetchRenderer.render(name, args, result, opts)
        }
        "web_search" | "websearch" | "search_web" | "search" => {
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
        // Success and Error used the SAME `●`, separated only by colour — so a
        // failed call was indistinguishable from a successful one under
        // NO_COLOR, on a monochrome terminal, or to a red/green-colour-blind
        // reader. Keep Claude Code's error colour, but carry the state in the
        // glyph too (as Canceled's `⊘` and AwaitingPermission's `◐` already do).
        ToolStatus::Error => (
            "✗".to_string(),
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
    out.push(flatten_line(header));

    for (i, line) in body.into_iter().enumerate() {
        let mut spans: Vec<Span<'static>> = Vec::with_capacity(line.spans.len() + 1);
        spans.push(result_connector(i == 0));
        spans.extend(line.spans);
        out.push(Line::from(spans));
    }

    out
}

/// Collapse control whitespace inside a one-row header into spaces.
///
/// A tool header is ONE row, but its content is BACKEND-SUPPLIED — a command
/// string, a file path, an arg summary — and a multi-line command is routine.
/// ratatui treats a `\n` inside a `Span` as a zero-width grapheme rather than a
/// break, so `export A=1\ncd /tmp\nmake` renders as `export A=1cd /tmpmake`:
/// silently wrong, and wrong in a way that misrepresents what is about to run.
///
/// `app/handle_actions.rs` and `components/chat/thinking_box.rs` each guard this
/// at their own call site; the tool-header path had no guard at all. Doing it
/// here covers `render_tool_box`'s callers uniformly.
fn flatten_line(line: Line<'static>) -> Line<'static> {
    let needs = line
        .spans
        .iter()
        .any(|s| s.content.contains(['\n', '\r', '\t']));
    if !needs {
        return line;
    }
    let spans = line
        .spans
        .into_iter()
        .map(|mut s| {
            let flat = s
                .content
                .chars()
                .map(|c| if c == '\n' || c == '\r' || c == '\t' { ' ' } else { c })
                .collect::<String>();
            s.content = flat.into();
            s
        })
        .collect::<Vec<_>>();
    Line::from(spans)
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

    // Shape-accurate but fully generic: the point of the fixture is that a
    // third-party `.claude/skills` path never reaches rendered tool output.
    const REMINDER: &str = "<system-reminder>\nA skill \"example-skill\" is available near a path you just accessed.\nIts definition is at /home/user/.claude/skills/example-skill/SKILL.md\n</system-reminder>";

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

// ---------------------------------------------------------------------------
// Internal <task-notification> control markup must never reach the screen —
// including the MANGLED copies a model produces when it echoes the block back
// out of its own context (duplicated elements, mismatched closing tags).
// ---------------------------------------------------------------------------
#[cfg(test)]
mod task_notification_tests {
    use super::*;

    /// A well-formed block, exactly as `Agent.TaskNotifications.to_xml/1` builds it.
    const NOTIF: &str = "<task-notification>\n  <task-id>bg_5g5byuj8</task-id>\n  <status>done</status>\n  <output-file>/tmp/osa/session-a/tasks/bg_5g5byuj8.out</output-file>\n  <summary>Background command 'mix compile' completed (exit code 0)</summary>\n</task-notification>";

    /// The observed leak: the model re-typed the block, closing `<output-file>`
    /// with `</status>` and emitting `<output-file>` twice.
    const MANGLED: &str = "<task-notification> <task-id>bg_5g5byuj8</task-id> <status>done</status>\n<output-file>/var/var/folders/x/T/osa/s/tasks/bg_5g5byuj8.out</status> <output-file>dup</output-file> <summary>Background command 'mix compile' completed</summary>\n</task-notification>";

    #[test]
    fn strips_a_well_formed_notification() {
        let raw = format!("Compiling now.\n\n{NOTIF}");
        let out = strip_control_markup(&raw);
        assert_eq!(out, "Compiling now.");
        assert!(!out.contains("task-notification"));
    }

    #[test]
    fn strips_a_mangled_echoed_notification() {
        let raw = format!("Here is what happened.\n{MANGLED}\nMoving on.");
        let out = strip_control_markup(&raw);
        assert!(out.starts_with("Here is what happened."));
        assert!(out.ends_with("Moving on."));
        for needle in ["task-notification", "task-id", "output-file", "bg_5g5byuj8"] {
            assert!(!out.contains(needle), "leaked {needle}: {out}");
        }
    }

    #[test]
    fn unterminated_notification_drops_the_remainder() {
        let raw = "Working.\n<task-notification>\n  <task-id>bg_1</task-id>";
        assert_eq!(strip_control_markup(raw), "Working.");
    }

    #[test]
    fn strips_both_control_tags_in_one_pass() {
        let raw = format!("a\n<system-reminder>r</system-reminder>\nb\n{NOTIF}\nc");
        let out = strip_control_markup(&raw);
        assert!(!out.contains("system-reminder"));
        assert!(!out.contains("task-notification"));
        assert!(out.contains('a') && out.contains('b') && out.contains('c'));
    }

    #[test]
    fn leaves_ordinary_prose_untouched() {
        let raw = "The task finished; the notification told me the exit code was 0.";
        assert_eq!(strip_control_markup(raw), raw);
    }

    #[test]
    fn render_tool_never_shows_notification_text() {
        let raw = format!("done\n\n{NOTIF}");
        let opts = RenderOpts {
            status: ToolStatus::Success,
            width: 100,
            expanded: true,
            compact: false,
            spinner_frame: None,
            duration_ms: 0,
            truncated: false,
        };

        for tool in ["shell_execute", "bash_output", "file_read", "some_unknown_tool"] {
            let lines = render_tool(tool, "{}", &raw, &opts);
            let text: String = lines
                .iter()
                .map(|l| l.spans.iter().map(|s| s.content.as_ref()).collect::<String>())
                .collect::<Vec<_>>()
                .join("\n");
            assert!(
                !text.contains("task-notification"),
                "{tool} leaked the notification tag: {text}"
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

#[cfg(test)]
mod tool_header_newline_guard {
    use ratatui::{backend::TestBackend, text::{Line, Span}, widgets::Paragraph, Terminal};

    /// Empirical: ratatui treats a `\n` INSIDE a Span as a zero-width grapheme,
    /// so a multi-line command collapses into one unreadable run rather than
    /// wrapping. This pins the behaviour that makes the guard necessary.
    #[test]
    fn ratatui_silently_eats_a_newline_inside_a_span() {
        let mut term = Terminal::new(TestBackend::new(40, 3)).unwrap();
        term.draw(|f| {
            f.render_widget(
                Paragraph::new(Line::from(Span::raw("export A=1\ncd /tmp\nmake"))),
                f.area(),
            )
        })
        .unwrap();
        let row: String = (0..40)
            .map(|x| term.backend().buffer()[(x, 0)].symbol())
            .collect::<String>();
        assert!(
            row.contains("export A=1cd /tmpmake"),
            "ratatui no longer collapses embedded newlines; re-check the guard: {row:?}"
        );
    }

    /// A tool header is ONE row. Backend-supplied command strings reach it, so
    /// the shared choke point flattens newlines rather than trusting callers.
    #[test]
    fn a_tool_header_flattens_newlines_into_spaces() {
        let header = Line::from(vec![
            Span::raw("Bash "),
            Span::raw("export A=1\ncd /tmp\nmake"),
        ]);
        let out = super::render_tool_box(header, vec![]);
        let joined: String = out[0]
            .spans
            .iter()
            .map(|s| s.content.as_ref())
            .collect::<String>();
        assert!(
            !joined.contains('\n'),
            "a newline survived into a tool header: {joined:?}"
        );
        assert!(
            joined.contains("export A=1 cd /tmp make"),
            "flattening lost or mangled the command: {joined:?}"
        );
    }

    /// Carriage returns and tabs are the same hazard.
    #[test]
    fn a_tool_header_flattens_cr_and_tab_too() {
        let header = Line::from(Span::raw("a\r\nb\tc"));
        let out = super::render_tool_box(header, vec![]);
        let joined: String = out[0]
            .spans
            .iter()
            .map(|s| s.content.as_ref())
            .collect::<String>();
        assert!(!joined.contains('\n') && !joined.contains('\r') && !joined.contains('\t'), "{joined:?}");
    }

    /// A single-line header is passed through byte-identically.
    #[test]
    fn a_single_line_header_is_untouched() {
        let header = Line::from(vec![Span::raw("Read "), Span::raw("/src/main.rs")]);
        let out = super::render_tool_box(header, vec![]);
        let joined: String = out[0]
            .spans
            .iter()
            .map(|s| s.content.as_ref())
            .collect::<String>();
        assert_eq!(joined, "Read /src/main.rs");
    }
}

// ── the print-once commit cap ───────────────────────────────────────────────
//
// These rows go into the terminal's own scrollback and can never be re-wrapped,
// re-rendered or folded again. An uncapped expanded body therefore commits
// thousands of rows the operator cannot undo.
#[cfg(test)]
mod commit_cap_tests {
    use super::*;

    fn block(n: usize) -> Vec<Line<'static>> {
        (0..n).map(|i| Line::from(format!("row {i}"))).collect()
    }

    fn flat(lines: &[Line<'_>]) -> Vec<String> {
        lines
            .iter()
            .map(|l| l.spans.iter().map(|s| s.content.as_ref()).collect())
            .collect()
    }

    fn opts(expanded: bool) -> RenderOpts {
        RenderOpts {
            status: ToolStatus::Success,
            width: 80,
            expanded,
            compact: !expanded,
            spinner_frame: None,
            duration_ms: 1,
            truncated: false,
        }
    }

    #[test]
    #[serial_test::serial]
    fn a_block_under_the_cap_is_untouched() {
        let _g = crate::test_env::EnvGuard::set("OSA_MAX_COMMIT_ROWS", "10");
        let mut lines = block(10);
        apply_commit_cap(&mut lines);
        assert_eq!(lines.len(), 10);
        assert_eq!(flat(&lines).last().unwrap(), "row 9");
    }

    /// The surviving rows are the ones the uncapped commit would have produced,
    /// byte for byte — the block is laid out at full height and only THEN
    /// clipped. Re-wrapping at the cap would change rows that were not dropped.
    #[test]
    #[serial_test::serial]
    fn an_over_long_block_is_clipped_not_rewrapped() {
        let _g = crate::test_env::EnvGuard::set("OSA_MAX_COMMIT_ROWS", "10");
        let mut lines = block(100);
        apply_commit_cap(&mut lines);
        assert_eq!(lines.len(), 10, "exactly the cap, marker included");
        let rendered = flat(&lines);
        for (i, row) in rendered.iter().take(9).enumerate() {
            assert_eq!(row, &format!("row {i}"), "surviving rows are unchanged");
        }
        // 100 rows, 9 survive → 91 dropped, counted exactly.
        assert_eq!(
            rendered.last().unwrap(),
            "\u{2026} 91 more lines \u{2014} /transcript to view"
        );
    }

    #[test]
    #[serial_test::serial]
    fn zero_means_unbounded() {
        let _g = crate::test_env::EnvGuard::set("OSA_MAX_COMMIT_ROWS", "0");
        let mut lines = block(5000);
        apply_commit_cap(&mut lines);
        assert_eq!(lines.len(), 5000);
    }

    #[test]
    #[serial_test::serial]
    fn an_unparseable_setting_falls_back_to_the_default() {
        let _g = crate::test_env::EnvGuard::set("OSA_MAX_COMMIT_ROWS", "banana");
        assert_eq!(max_commit_rows(), DEFAULT_MAX_COMMIT_ROWS);
    }

    /// End-to-end through the one entry point every renderer goes through: an
    /// expanded shell body of 5000 rows commits bounded.
    #[test]
    #[serial_test::serial]
    fn an_expanded_shell_body_commits_bounded() {
        let _g = crate::test_env::EnvGuard::set("OSA_MAX_COMMIT_ROWS", "50");
        let result = (0..5000)
            .map(|i| format!("out {i}"))
            .collect::<Vec<_>>()
            .join("\n");
        let lines = render_tool("bash", r#"{"command":"seq 5000"}"#, &result, &opts(true));
        assert_eq!(lines.len(), 50, "the expanded body must not commit unbounded");
        let last: String = lines
            .last()
            .unwrap()
            .spans
            .iter()
            .map(|s| s.content.as_ref())
            .collect();
        assert!(last.contains("/transcript to view"), "{last:?}");
    }

    /// The COLLAPSED shell cell never reaches the commit cap at all — it is
    /// already bounded by its own head/tail window, which is the point.
    #[test]
    fn the_collapsed_shell_cell_is_bounded_far_below_the_commit_cap() {
        let result = (0..5000)
            .map(|i| format!("out {i}"))
            .collect::<Vec<_>>()
            .join("\n");
        let lines = render_tool("bash", r#"{"command":"seq 5000"}"#, &result, &opts(false));
        assert!(lines.len() <= 5, "header + a small window: {}", lines.len());
    }
}
