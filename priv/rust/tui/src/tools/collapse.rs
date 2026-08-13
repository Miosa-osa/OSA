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
    /// Plan / todo-list mutation.
    Todo,
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
            Todo => {
                if running {
                    "Updating"
                } else {
                    "Updated"
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
            Todo => {
                if one {
                    "todo"
                } else {
                    "todos"
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
            File | Skill | Search | Dir | MemorySearch | IntegrationSearch | Todo
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
        // Plan mutations. A single plan is built with one call PER STEP, so a
        // six-step plan emitted six identical `Todos` rows — the tool that
        // reports progress was the noisiest thing on screen, and the committed
        // plan snapshot at turn end already shows the outcome.
        "todoread" | "todowrite" | "todos" | "task_write" | "update_plan" => ToolKind::Todo,
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

// ─── The hook counter bracket ───────────────────────────────────────────────

/// Per-group / per-call tally of finished hook invocations.
///
/// Three outcomes, not two. **Blocked is not a failure**: a policy hook that
/// denies a dangerous command is the system working exactly as configured, and
/// folding it into `failed` would report a correctly-wired setup as broken. A
/// *skipped* hook increments nothing at all — it did not run, so it is not a
/// data point, and a group whose every hook was skipped renders no bracket.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct HookRunCounts {
    pub ok: usize,
    pub blocked: usize,
    pub failed: usize,
}

impl HookRunCounts {
    /// Fold in one `BackendEvent::HookRun`, using the backend's own outcome
    /// vocabulary rather than a boolean (`agent/hooks/dispatch.ex` `classify/1`).
    pub fn note(&mut self, outcome: &str) {
        match outcome {
            "crashed" | "timed_out" | "failed" | "error" => self.failed += 1,
            "blocked" | "denied" | "deny" | "block" => self.blocked += 1,
            // `skip`/`skipped` never ran — deliberately uncounted (§3.1).
            "skip" | "skipped" => {}
            _ => self.ok += 1,
        }
    }

    pub fn total(&self) -> usize {
        self.ok + self.blocked + self.failed
    }

    pub fn is_empty(&self) -> bool {
        self.total() == 0
    }

    fn add(&mut self, other: HookRunCounts) {
        self.ok += other.ok;
        self.blocked += other.blocked;
        self.failed += other.failed;
    }
}

/// Which bracket shape a row gets.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HookBracket {
    /// Aggregate/group rows: `[hooks: 54 ok, 3 blocked, 19 failed]`. Every
    /// outcome is NAMED, because a group row shows no member detail that could
    /// explain the numbers.
    Labeled,
    /// Individual rows: `[hooks: 9/1]` — completed/failed. `completed` counts
    /// blocked hooks in its numerator: they completed normally, and the row's
    /// own detail explains any block.
    Compact,
}

/// The trailing `  [hooks: …]` suffix for a row, or `None`.
///
/// **`None` at zero is the whole contract of §3.4**: no brackets, no
/// `[hooks: 0]`, no trailing spaces. A user with no hooks configured never sees
/// the word "hooks" anywhere in their transcript, and neither does a user whose
/// hooks all skipped.
pub fn hook_bracket(counts: HookRunCounts, shape: HookBracket) -> Option<Vec<Span<'static>>> {
    if counts.is_empty() {
        return None;
    }
    let theme = crate::style::theme();
    // Chrome tier for the punctuation, and DIM on every number so the whole
    // bracket recedes below the label it trails.
    let chrome = theme.recede();
    let dim = Modifier::DIM;
    let ok_style = Style::default().fg(theme.colors.success).add_modifier(dim);
    let blocked_style = Style::default().fg(theme.colors.warning).add_modifier(dim);
    let failed_style = Style::default().fg(theme.colors.error).add_modifier(dim);

    let mut spans = vec![Span::styled("  [hooks: ".to_string(), chrome)];
    match shape {
        HookBracket::Labeled => {
            // Fixed order ok → blocked → failed; zero-count outcomes are omitted
            // ENTIRELY rather than printed as `0 ok`.
            let mut first = true;
            let mut seg = |n: usize, label: &str, style: Style, spans: &mut Vec<Span<'static>>| {
                if n == 0 {
                    return;
                }
                if !first {
                    spans.push(Span::styled(", ".to_string(), chrome));
                }
                first = false;
                spans.push(Span::styled(format!("{}", n), style));
                if !label.is_empty() {
                    spans.push(Span::styled(format!(" {}", label), style));
                }
            };
            // With nothing to disambiguate, the label word is noise: a clean run
            // reads `[hooks: 54]`, not `[hooks: 54 ok]`.
            let bare = counts.blocked == 0 && counts.failed == 0;
            seg(counts.ok, if bare { "" } else { "ok" }, ok_style, &mut spans);
            seg(counts.blocked, "blocked", blocked_style, &mut spans);
            seg(counts.failed, "failed", failed_style, &mut spans);
        }
        HookBracket::Compact => {
            // Blocked hooks completed normally, so they stay in the numerator.
            let completed = counts.ok + counts.blocked;
            let failed = counts.failed;
            if completed > 0 {
                spans.push(Span::styled(format!("{}", completed), ok_style));
            }
            // The `/` is emitted only when BOTH sides are non-zero — a run of
            // pure failures is `[hooks: 3]` in the error colour, not `[hooks: /3]`.
            if completed > 0 && failed > 0 {
                spans.push(Span::styled("/".to_string(), chrome));
            }
            if failed > 0 {
                spans.push(Span::styled(format!("{}", failed), failed_style));
            }
        }
    }
    spans.push(Span::styled("]".to_string(), chrome));
    Some(spans)
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
    /// Hook runs summed across the MEMBERS of this run, per §3.2 — not a
    /// session total. It resets with the run, because the row it labels
    /// describes only the calls folded into that row.
    hooks: HookRunCounts,
}

impl Accumulator {
    pub fn is_empty(&self) -> bool {
        self.buckets.is_empty()
    }

    /// Fold one finished collapsible tool into the run.
    pub fn add(&mut self, kind: &ToolKind, args: &str, success: bool) {
        self.add_with_hooks(kind, args, success, HookRunCounts::default());
    }

    /// [`Self::add`], carrying the hook runs that wrapped THIS call. The counts
    /// come in with the member rather than being sampled off a wall clock: a
    /// group row's bracket must describe the calls it labels and nothing else.
    pub fn add_with_hooks(
        &mut self,
        kind: &ToolKind,
        args: &str,
        success: bool,
        hooks: HookRunCounts,
    ) {
        if matches!(kind, ToolKind::NonCollapsible) {
            return;
        }
        self.hooks.add(hooks);
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
        // The labeled shape (§3.3): this is an aggregate row, so no member
        // detail is on screen to explain the numbers and every outcome is named.
        if let Some(bracket) = hook_bracket(self.hooks, HookBracket::Labeled) {
            spans.extend(bracket);
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

// ─── The committed capped execute block ─────────────────────────────────────
//
// Shell output is the noisiest thing in the transcript, and the live activity
// band that used to carry a running command's tail no longer exists — so this
// block is the ONLY place a command's output is ever seen. That raises the bar
// on it twice over: it has to stay small, and it has to be the *informative*
// small.
//
// The old cell was head-only: the first three wrapped rows and then a count.
// For the commands people actually run that is precisely the wrong three rows.
// A failing `cargo build` spent its whole budget on `Compiling foo v0.1.0` and
// hid the error; a test run showed the runner banner and hid `812 passed`. The
// verdict of a command is at the END of its output, essentially always.
//
// So the window is head + tail with the elision marker BETWEEN them, at the
// same total height the head-only cell used. The marker's placement is not
// cosmetic: a marker at the bottom would claim the hidden rows come after the
// last row shown, which would be a lie about which rows were dropped. Rows are
// never dropped silently — every hidden row is counted in the marker.

/// Head/tail split of a **successful** execute block: one row of what the
/// command started doing, two rows of what it concluded. Plus the marker that
/// is four rows — the same ceiling the head-only cell had.
const EXEC_HEAD_OK: usize = 1;
const EXEC_TAIL_OK: usize = 2;

/// Head/tail split of a **failed** execute block. The entire budget goes to the
/// tail: when a command fails, none of the evidence is at the top. One extra
/// row over the success case, because a failure is the one time the operator is
/// actually going to read this cell.
const EXEC_HEAD_ERR: usize = 0;
const EXEC_TAIL_ERR: usize = 4;

/// Apply terminal carriage-return semantics to one raw line, then drop the CR.
///
/// A progress bar (`cargo`, `pip`, `npm`, `docker pull`, anything using `\r` to
/// redraw in place) emits every frame it ever painted into a single logical
/// line. `scrub_rendered_span` drops the `\r` as a control character, which
/// concatenated all of those frames into one multi-kilobyte row that then wrapped
/// into dozens of rows of the same word repeated — a large part of the "shows
/// some shit" complaint. A terminal shows only the last frame, so we do too.
fn apply_carriage_returns(line: &str) -> &str {
    match line.rfind('\r') {
        Some(i) => &line[i + 1..],
        None => line,
    }
}

/// Logical output rows, compacted without dropping anything a reader needs.
///
/// Three passes, all of them information-preserving:
/// 1. JSON object/array lines are pretty-printed (existing behaviour).
/// 2. Carriage-return redraws collapse to the frame that would actually be on
///    screen (see [`apply_carriage_returns`]).
/// 3. Leading/trailing blank rows are dropped and interior runs of blanks
///    squeeze to one. Vertical whitespace carries no information in a capped
///    window, and it was competing for the budget with rows that do.
fn normalized_output_rows(result: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut pending_blank = false;
    for raw in result.lines() {
        let logical = apply_carriage_returns(raw);
        let expanded = match try_format_json(logical) {
            Some(pretty) => pretty.lines().map(|l| l.to_string()).collect::<Vec<_>>(),
            None => vec![logical.to_string()],
        };
        for line in expanded {
            if line.trim().is_empty() {
                // Never emit a leading blank; remember at most one interior run.
                if !out.is_empty() {
                    pending_blank = true;
                }
                continue;
            }
            if pending_blank {
                out.push(String::new());
                pending_blank = false;
            }
            out.push(line);
        }
    }
    // `pending_blank` is deliberately not flushed: a trailing blank run is dropped.
    out
}

/// The dim elision marker. `hidden` is the exact number of wrapped rows the
/// window is not showing — never an estimate, never rounded.
fn elision_marker(hidden: usize, cols: usize, bg: Color) -> Line<'static> {
    let theme = crate::style::theme();
    let text = format!("… +{} lines (ctrl+o to expand)", hidden);
    let w = unicode_width::UnicodeWidthStr::width(text.as_str());
    let span = Span::styled(text, Style::default().fg(theme.colors.dim).bg(bg));
    panelize(vec![span], w, cols, bg)
}

/// The capped execute block: a bounded head+tail window over a command's output
/// with an honest middle elision marker.
///
/// Height is bounded by `head + tail + 1` **regardless of how much the command
/// printed**, which is what makes this safe in a print-once architecture: the
/// rows this returns are the rows committed to native scrollback, and they can
/// never be re-rendered or scrolled back through.
///
/// A block that fits in the window prints in full with no marker — the marker
/// only ever appears when there is something behind it.
pub(crate) fn capped_execute_block(
    result: &str,
    width: u16,
    is_error: bool,
) -> Vec<Line<'static>> {
    let (head, tail) = if is_error {
        (EXEC_HEAD_ERR, EXEC_TAIL_ERR)
    } else {
        (EXEC_HEAD_OK, EXEC_TAIL_OK)
    };
    capped_execute_block_with(result, width, is_error, head, tail)
}

/// [`capped_execute_block`] with an explicit window, so tests can pin the shape
/// without depending on the tuned constants.
pub(crate) fn capped_execute_block_with(
    result: &str,
    width: u16,
    is_error: bool,
    head: usize,
    tail: usize,
) -> Vec<Line<'static>> {
    let cols = super::body_wrap_width(width);
    let bg = output_panel_bg();
    let base = output_base_style(is_error, bg);

    let all: Vec<String> = normalized_output_rows(result)
        .iter()
        .flat_map(|l| super::wrap_plain(l, cols))
        .collect();
    if all.is_empty() {
        return Vec::new();
    }

    let row = |text: &str| -> Line<'static> {
        let (spans, w) = linkify_row(text, base);
        panelize(spans, w, cols, bg)
    };

    // The window plus its marker is the same height as printing that many rows
    // outright, so a block only one row over the window prints in full rather
    // than spending a row to say it hid one row.
    let budget = head + tail + 1;
    if all.len() <= budget {
        return all.iter().map(|r| row(r)).collect();
    }

    let hidden = all.len() - head - tail;
    let mut body: Vec<Line<'static>> = Vec::with_capacity(budget);
    for r in &all[..head] {
        body.push(row(r));
    }
    body.push(elision_marker(hidden, cols, bg));
    for r in &all[all.len() - tail..] {
        body.push(row(r));
    }
    body
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
    // Same normalization as the capped block — carriage-return redraws collapse
    // to their last frame and blank runs squeeze — so expanding a cell shows
    // MORE of the same output rather than a differently-shaped rendering of it.
    for l in normalized_output_rows(result) {
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

// ── the committed capped execute block ──────────────────────────────────────
//
// The cell is bounded in height whatever the command printed, and it is bounded
// around the part of the output that carries the verdict. Every row it does not
// show is counted.
#[cfg(test)]
mod capped_execute_block_tests {
    use super::*;

    fn flat(lines: &[Line<'_>]) -> Vec<String> {
        lines
            .iter()
            .map(|l| {
                l.spans
                    .iter()
                    .map(|s| s.content.as_ref())
                    .collect::<String>()
                    .trim_end()
                    .to_string()
            })
            .collect()
    }

    fn build(result: &str) -> Vec<String> {
        flat(&capped_execute_block(result, 80, false))
    }

    /// The regression this block exists for. A build's first rows are
    /// `Compiling …`; its LAST rows are the error that made the operator look.
    /// A head-only fold showed the former and hid the latter.
    #[test]
    fn a_long_run_shows_its_verdict_not_only_its_preamble() {
        let mut out = String::from("Compiling foo v0.1.0\n");
        for i in 0..40 {
            out.push_str(&format!("Compiling dep{} v0.1.0\n", i));
        }
        out.push_str("error: could not compile `baz`\nwarning: build failed\n");
        let rows = build(&out);
        let joined = rows.join("\n");
        assert!(
            joined.contains("error: could not compile `baz`"),
            "the verdict must survive the fold: {rows:?}"
        );
        assert!(
            joined.contains("warning: build failed"),
            "the last row must survive the fold: {rows:?}"
        );
        assert!(
            rows[0].contains("Compiling foo"),
            "the head row is still the first row of output: {rows:?}"
        );
    }

    /// The marker sits BETWEEN the halves, because that is where the hidden rows
    /// are. A marker at the bottom would misdescribe which rows were dropped.
    #[test]
    fn the_marker_sits_between_the_halves() {
        let rows = build(&(1..=20).map(|i| format!("l{i}")).collect::<Vec<_>>().join("\n"));
        let marker = rows
            .iter()
            .position(|r| r.starts_with('\u{2026}'))
            .expect("a folded block has a marker");
        assert!(marker > 0, "head rows come first: {rows:?}");
        assert!(marker < rows.len() - 1, "tail rows come after: {rows:?}");
    }

    /// Nothing is ever dropped silently: the count is the exact number of
    /// wrapped rows between the head and the tail.
    #[test]
    fn the_marker_counts_every_hidden_row_exactly() {
        // 20 rows, window 1 + 2 → 17 hidden.
        let rows = build(&(1..=20).map(|i| format!("l{i}")).collect::<Vec<_>>().join("\n"));
        assert!(
            rows.iter().any(|r| r.contains("+17 lines")),
            "hidden count must be exact: {rows:?}"
        );
        // Shown + hidden accounts for the whole output, with the marker's own
        // row excluded from the tally.
        assert_eq!(rows.len() - 1 + 17, 20, "{rows:?}");
    }

    /// A block only one row over the window prints in full: spending a row to
    /// say one row was hidden is strictly worse than showing the row.
    #[test]
    fn a_block_that_fits_the_window_prints_in_full() {
        for n in 1..=4 {
            let rows = build(&(1..=n).map(|i| format!("l{i}")).collect::<Vec<_>>().join("\n"));
            assert_eq!(rows.len(), n, "{n} rows must print in full: {rows:?}");
            assert!(!rows.iter().any(|r| r.starts_with('\u{2026}')), "{rows:?}");
        }
    }

    /// A failure spends the whole budget on the tail — none of the evidence for
    /// a failed command is at the top of its output.
    #[test]
    fn a_failed_block_is_all_tail() {
        let out = (1..=20).map(|i| format!("l{i}")).collect::<Vec<_>>().join("\n");
        let rows = flat(&capped_execute_block(&out, 80, true));
        assert!(rows[0].starts_with('\u{2026}'), "marker leads: {rows:?}");
        assert_eq!(rows.len(), 1 + EXEC_TAIL_ERR, "{rows:?}");
        assert!(rows.last().unwrap().contains("l20"), "{rows:?}");
    }

    /// The height ceiling is what makes this safe to COMMIT: these rows go into
    /// native scrollback and can never be re-rendered.
    #[test]
    fn height_is_bounded_regardless_of_how_much_the_command_printed() {
        for n in [5usize, 50, 500, 5000] {
            let out = (1..=n).map(|i| format!("line {i}")).collect::<Vec<_>>().join("\n");
            let ok = capped_execute_block(&out, 80, false).len();
            let err = capped_execute_block(&out, 80, true).len();
            assert!(ok <= EXEC_HEAD_OK + EXEC_TAIL_OK + 1, "{n} rows → {ok}");
            assert!(err <= EXEC_HEAD_ERR + EXEC_TAIL_ERR + 1, "{n} rows → {err}");
        }
    }

    /// A progress bar redraws in place with `\r`. Dropping the CR as a bare
    /// control character concatenated every frame it ever painted into one
    /// enormous row, which then wrapped into dozens. A terminal shows the last
    /// frame; so do we.
    #[test]
    fn carriage_return_redraws_collapse_to_their_last_frame() {
        let rows = build("Downloading 10%\rDownloading 60%\rDownloading 100%\ndone");
        assert_eq!(rows, vec!["Downloading 100%", "done"], "{rows:?}");
    }

    /// Blank rows carry no information and were competing for a budget measured
    /// in single rows.
    #[test]
    fn blank_runs_squeeze_and_the_edges_are_dropped() {
        let rows = build("\n\n  \nalpha\n\n\n\nbeta\n\n  \n");
        assert_eq!(rows, vec!["alpha", "", "beta"], "{rows:?}");
    }

    /// Squeezing must not erase content: an all-blank result is empty, not a
    /// block of empty rows.
    #[test]
    fn an_empty_or_blank_result_yields_no_block() {
        assert!(capped_execute_block("", 80, false).is_empty());
        assert!(capped_execute_block("\n\n   \n", 80, false).is_empty());
    }

    /// Long single lines still wrap first and are counted as the rows they
    /// occupy — the cap is over VISUAL rows, which is what the screen spends.
    #[test]
    fn wrapped_rows_are_what_the_cap_counts() {
        let long = "x".repeat(1000);
        let rows = flat(&capped_execute_block_with(&long, 80, false, 1, 1));
        assert_eq!(rows.len(), 3, "head + marker + tail: {rows:?}");
        assert!(rows[1].contains("lines"), "{rows:?}");
    }
}

// ── the hook counter bracket ────────────────────────────────────────────────
#[cfg(test)]
mod hook_bracket_tests {
    use super::*;

    fn text(counts: HookRunCounts, shape: HookBracket) -> Option<String> {
        hook_bracket(counts, shape)
            .map(|spans| spans.iter().map(|s| s.content.as_ref()).collect())
    }

    fn counts(ok: usize, blocked: usize, failed: usize) -> HookRunCounts {
        HookRunCounts { ok, blocked, failed }
    }

    /// §3.4. A user with no hooks configured never sees the word "hooks".
    #[test]
    fn zero_runs_render_nothing_at_all() {
        assert_eq!(text(HookRunCounts::default(), HookBracket::Labeled), None);
        assert_eq!(text(HookRunCounts::default(), HookBracket::Compact), None);
    }

    /// Skipped hooks did not run, so they are not counted — and a group where
    /// every hook skipped renders no bracket either.
    #[test]
    fn skipped_runs_are_uncounted() {
        let mut c = HookRunCounts::default();
        for outcome in ["skip", "skipped"] {
            c.note(outcome);
        }
        assert!(c.is_empty(), "{c:?}");
        assert_eq!(text(c, HookBracket::Labeled), None);
    }

    /// Blocking is a hook doing its job. It is counted apart from failure, and
    /// it never lands in the failure bucket.
    #[test]
    fn the_backend_vocabulary_maps_onto_three_outcomes() {
        let mut c = HookRunCounts::default();
        for outcome in ["ok", "rewrote_input", "allow"] {
            c.note(outcome);
        }
        for outcome in ["blocked", "denied"] {
            c.note(outcome);
        }
        for outcome in ["crashed", "timed_out"] {
            c.note(outcome);
        }
        assert_eq!(c, counts(3, 2, 2));
    }

    /// The bare form: with nothing to disambiguate, the label word is noise.
    #[test]
    fn a_clean_run_drops_the_label_word() {
        assert_eq!(
            text(counts(54, 0, 0), HookBracket::Labeled).as_deref(),
            Some("  [hooks: 54]")
        );
    }

    /// Fixed order, `", "` separator, and zero-count outcomes omitted ENTIRELY
    /// rather than printed as `0 ok`.
    #[test]
    fn the_labeled_shape_names_every_nonzero_outcome_in_order() {
        assert_eq!(
            text(counts(54, 0, 19), HookBracket::Labeled).as_deref(),
            Some("  [hooks: 54 ok, 19 failed]")
        );
        assert_eq!(
            text(counts(54, 3, 19), HookBracket::Labeled).as_deref(),
            Some("  [hooks: 54 ok, 3 blocked, 19 failed]")
        );
        assert_eq!(
            text(counts(0, 0, 3), HookBracket::Labeled).as_deref(),
            Some("  [hooks: 3 failed]")
        );
    }

    /// Compact: `completed/failed`, where completed = ok + blocked. The slash
    /// appears only when both sides are non-zero.
    #[test]
    fn the_compact_shape_keeps_blocked_in_the_numerator() {
        assert_eq!(
            text(counts(8, 1, 1), HookBracket::Compact).as_deref(),
            Some("  [hooks: 9/1]")
        );
        assert_eq!(
            text(counts(9, 0, 0), HookBracket::Compact).as_deref(),
            Some("  [hooks: 9]")
        );
        // Only failures: a bare number in the error colour, never `/3`.
        assert_eq!(
            text(counts(0, 0, 3), HookBracket::Compact).as_deref(),
            Some("  [hooks: 3]")
        );
    }

    /// Colour roles: each number carries its outcome's accent plus DIM, so the
    /// bracket recedes below the label it trails.
    #[test]
    fn numbers_carry_their_outcome_colour_and_recede() {
        let theme = crate::style::theme();
        let spans = hook_bracket(counts(5, 2, 1), HookBracket::Labeled).unwrap();
        let find = |needle: &str| {
            spans
                .iter()
                .find(|s| s.content.as_ref() == needle)
                .unwrap_or_else(|| panic!("missing span {needle:?}"))
                .style
        };
        for (needle, colour) in [
            ("5", theme.colors.success),
            ("2", theme.colors.warning),
            ("1", theme.colors.error),
        ] {
            let st = find(needle);
            assert_eq!(st.fg, Some(colour), "{needle}");
            assert!(st.add_modifier.contains(Modifier::DIM), "{needle}");
        }
    }

    /// Counts are per GROUP, not per session: the accumulator sums its members'
    /// runs and resets with the run it labels.
    #[test]
    fn a_group_row_sums_its_members_and_resets_with_the_run() {
        let mut acc = Accumulator::default();
        acc.add_with_hooks(&ToolKind::Search, "", true, counts(4, 0, 0));
        acc.add_with_hooks(&ToolKind::Dir, "", true, counts(2, 0, 1));
        let row: String = acc
            .take_summary_line()
            .expect("a run renders")
            .spans
            .iter()
            .map(|s| s.content.as_ref())
            .collect();
        assert!(row.contains("[hooks: 6 ok, 1 failed]"), "{row:?}");
        // The next run starts from zero — this is not a session tally.
        let mut acc2 = Accumulator::default();
        acc2.add(&ToolKind::Search, "", true);
        let row2: String = acc2
            .take_summary_line()
            .unwrap()
            .spans
            .iter()
            .map(|s| s.content.as_ref())
            .collect();
        assert!(!row2.contains("hooks"), "a hookless run says nothing: {row2:?}");
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
    fn a_plan_built_step_by_step_is_one_row_not_six() {
        // Observed: six consecutive `Todos` rows for one six-step plan, each
        // with its own duration. The plan panel already shows the result.
        let mut acc = Accumulator::default();
        for _ in 0..6 {
            acc.add(&classify("todowrite", "{}"), "{}", true);
        }
        assert_eq!(acc.summary_text(), "Updated 6 todos");
    }

    #[test]
    fn every_todo_tool_alias_folds() {
        for name in ["todoread", "todowrite", "todos", "task_write", "update_plan"] {
            let kind = classify(name, "{}");
            assert_eq!(kind, ToolKind::Todo, "{name} must classify as a todo");
            assert!(kind.folds_eagerly(), "{name} must fold");
        }
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
