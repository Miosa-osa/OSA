// Phase 2+: activity panel — Synthesizing variant, set_thinking wired when agent mesh arrives
#![allow(dead_code)]

use ratatui::prelude::*;
use ratatui::widgets::Paragraph;

use crate::event::Event;

use super::{Component, ComponentAction};

// The bounded live-output ring buffer lives in its own file but is mounted here
// (rather than in `components/mod.rs`) so the streaming feature is self-contained.
#[path = "live_output.rs"]
pub mod live_output;

use live_output::LiveCommandOutput;

/// Rows of live command output rendered under the tool feed. Kept small: the
/// live region is a status strip, not a pager — the full output still lands in
/// scrollback when the tool completes.
pub const LIVE_OUTPUT_PREVIEW_LINES: usize = 5;

/// Processing phase — drives the activity display with real backend state
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ProcessingPhase {
    /// Submitted, waiting for first backend event
    Waiting,
    /// ThinkingDelta events arriving (model reasoning)
    Thinking,
    /// StreamingToken events arriving
    Streaming,
    /// Tool call in progress
    ToolCall,
    /// Post-processing / synthesizing final response
    Synthesizing,
}

/// Why the turn is currently *blocked*, so the spinner can name the wait
/// instead of showing a random flavor verb during a multi-minute stall (grok
/// `WaitingReason::label()`, `acp/tracker.rs:124`). Set from the backend
/// phase signal; `None` ⇒ fall back to the flavor verb.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WaitingReason {
    /// Waiting for the model to (re)start streaming (first token / post-tool gap).
    Model,
    /// Blocked on a running foreground subagent (`delegate` / `Task`).
    Subagent,
    /// Blocked polling/awaiting a background task's output.
    TaskOutput,
    /// Blocked until one or more background tasks finish.
    Tasks,
    /// Explicit sleep / await.
    Sleeping,
    /// Context auto-compaction in progress.
    Compacting,
    /// Verifying / finishing the response.
    Verifying,
}

impl WaitingReason {
    /// Human label for the spinner verb slot. No trailing ellipsis — the
    /// spinner row appends `…` itself.
    pub fn label(self) -> &'static str {
        match self {
            Self::Model => "Waiting for response",
            Self::Subagent => "Waiting on subagent",
            Self::TaskOutput => "Waiting on task output",
            Self::Tasks => "Waiting on tasks",
            Self::Sleeping => "Sleeping",
            Self::Compacting => "Compacting",
            Self::Verifying => "Verifying",
        }
    }
}

/// Live retry / rate-limit state held on the spinner row during a mid-turn
/// stall (grok `turn_status.rs:647`, opencode `prompt/index.tsx:1564`). OSA
/// already receives `BackendEvent::ProviderRetry`; this lets the spinner label
/// itself become `Retrying (attempt N/M)…` in warning-yellow with a live
/// countdown, instead of cheerfully showing a flavor verb during the drop.
#[derive(Debug, Clone)]
pub struct RetryState {
    pub attempt: u32,
    pub max_attempts: u32,
    /// Provider-supplied reason (may be empty).
    pub reason: String,
    /// When the backend expects to resume (`now + delay_ms`); drives the
    /// live "retrying in Ns" countdown.
    pub resume_at: std::time::Instant,
}

/// Position of the moving shimmer/glimmer highlight sweeping across a verb of
/// `len` chars at animation `tick` (CC `SpinnerAnimationRow` `glimmerIndex`).
/// Sweeps left→right with a short tail gap so the glimmer visibly re-enters
/// from the left rather than jumping. Returns an index; `>= len` means the
/// highlight is currently in the off-screen tail (nothing lit).
fn shimmer_index(tick: u32, len: usize) -> usize {
    if len == 0 {
        return 0;
    }
    let span = len + 3; // verb width + tail gap
    (tick as usize) % span
}

/// Whether the pending-user pulse is in its bright phase at `tick` (grok's
/// pulsing `◆`). Alternates every few ticks so the diamond breathes.
fn pulse_bright(tick: u32) -> bool {
    (tick / 3) % 2 == 0
}

/// U-T22 — the persistent interrupt affordance shown in the spinner's status
/// group. After the first in-turn Esc it becomes "esc again to interrupt" so the
/// user knows a second press ends the turn; a lone Esc never kills it.
fn interrupt_affordance(armed: bool) -> &'static str {
    if armed {
        "esc again to interrupt"
    } else {
        "esc to interrupt"
    }
}

/// U-T27 — progressive width-gating for the spinner's " (a · b · c)" status
/// group. Keeps as many LEADING (higher-priority) segments as fit in `budget`
/// columns and drops trailing ones as the pane narrows, charging the 3-column
/// " · " join between kept segments. The first segment is always kept so the
/// row never renders an empty "()".
fn gate_parts(parts: &[String], budget: usize) -> Vec<String> {
    let mut kept: Vec<String> = Vec::new();
    let mut used = 0usize;
    for (i, p) in parts.iter().enumerate() {
        // Columns, not chars — a wide glyph in a status segment costs 2.
        let cost = crate::util::cols(p) + if i == 0 { 0 } else { 3 };
        if i == 0 || used + cost <= budget {
            used += cost;
            kept.push(p.clone());
        } else {
            break;
        }
    }
    kept
}

/// Floor on the columns the spinner verb may be squeezed to. Below this the
/// pane is too narrow for the row to be readable at all, and shrinking the verb
/// further buys the interrupt hint nothing.
const MIN_VERB_COLS: usize = 8;

/// Fit the spinner's live verb into `max_cols` display columns, preserving the
/// part that actually identifies the work.
///
/// The verb is `@<agent>: <tool>: <argument>` during orchestration and the
/// argument is usually an absolute path. Cutting from the right would keep the
/// prefix the reader already knows (`@goal-verifier-skeptic: dir_list: /Users/…`)
/// and destroy the only part that says WHAT is being touched, so the detail
/// after the last `": "` is fitted with [`crate::util::fit_arg_summary`], which
/// ellipsizes a path so its final segment survives. Column-measured throughout.
fn fit_verb(verb: &str, max_cols: usize) -> String {
    use crate::util::{cols, fit_arg_summary, fit_cols};
    if cols(verb) <= max_cols {
        return verb.to_string();
    }
    if let Some(i) = verb.rfind(": ") {
        let (head, detail) = verb.split_at(i + 2);
        let head_w = cols(head);
        // Only keep the labels if the detail still gets room to say something.
        if !detail.trim().is_empty() && head_w + 6 <= max_cols {
            return format!("{}{}", head, fit_arg_summary(detail, max_cols - head_w));
        }
    }
    fit_cols(verb, max_cols)
}

/// Fit `s` into `max_cols` display columns, ALWAYS ending in `…`.
///
/// Distinct from [`crate::util::fit_cols`], which returns the string untouched
/// when it already fits: the details block calls this only on a row it has
/// decided to cut, so the ellipsis is the signal that content was dropped and
/// must appear even when the kept text happens to fit.
fn ellipsize_cols(s: &str, max_cols: usize) -> String {
    if max_cols == 0 {
        return String::new();
    }
    let budget = max_cols - 1; // reserve one column for the ellipsis
    let mut out = String::new();
    let mut acc = 0usize;
    for ch in s.chars() {
        let cw = unicode_width::UnicodeWidthChar::width(ch).unwrap_or(0);
        if acc + cw > budget {
            break;
        }
        out.push(ch);
        acc += cw;
    }
    out.push('\u{2026}');
    out
}

/// Format large counts compactly (e.g. 1234 → "1.2k")
fn format_count(n: usize) -> String {
    if n >= 1000 {
        format!("{:.1}k", n as f64 / 1000.0)
    } else {
        format!("{}", n)
    }
}

/// Ultra-compact short-number for the live token counter (CC's context-token
/// indicator, e.g. `⇣12k`): a bare integer below 1k, one decimal in the low
/// thousands (`1.5k`), and a rounded whole-k once it's large enough that the
/// decimal is noise (`12k`).
fn short_number(n: u64) -> String {
    if n < 1000 {
        n.to_string()
    } else {
        let k = n as f64 / 1000.0;
        if k >= 10.0 {
            format!("{}k", k.round() as u64)
        } else {
            format!("{:.1}k", k)
        }
    }
}

/// Tight elapsed formatter for the spinner's dual live timers (grok
/// `turn_status`, e.g. `1m20s`): bare seconds under a minute, no-space
/// `m`+zero-padded-`s` under an hour, `h`+`m`+`s` above. Deliberately spaceless
/// so the phase and turn timers pack into the dim status group without eating
/// width the way `util::fmt_elapsed`'s spaced form would.
fn fmt_compact_tight(secs: u64) -> String {
    if secs < 60 {
        format!("{}s", secs)
    } else if secs < 3600 {
        format!("{}m{:02}s", secs / 60, secs % 60)
    } else {
        format!("{}h{:02}m{:02}s", secs / 3600, (secs % 3600) / 60, secs % 60)
    }
}

/// Format a TOOL-CALL duration for the live feed.
///
/// Delegates to `tools::format_duration` — the same formatter the transcript
/// tool headers below the feed use — so one call never reads two ways on one
/// screen. The feed used to print `{:.1}s` unconditionally, which floored every
/// call faster than 50 ms to a literal `0.0s` while the transcript line for the
/// SAME call said `40ms`.
///
/// `format_duration` returns an empty string for 0, its "nothing to report"
/// signal. Here 0 is never unknown — an unmeasured call is `duration_ms: None`
/// and takes the running branch — so a 0 is a real sub-millisecond measurement
/// and is rendered as such.
fn fmt_tool_duration(ms: u64) -> String {
    let s = crate::tools::format_duration(ms);
    if s.is_empty() {
        "<1ms".to_string()
    } else {
        s
    }
}

/// Ease the displayed token counter one animation step toward `target` (CC's
/// SpinnerAnimationRow token-count easing): step by a fraction of the gap, at
/// least +3 so it visibly ticks, capped at +50 so a big jump animates instead of
/// snapping, and never past `target` (no overshoot). Returns the new displayed
/// value; when already at/above the target it holds (tokens are monotonic within
/// a turn, so it never counts down).
fn ease_tokens(displayed: u64, target: u64) -> u64 {
    if displayed >= target {
        return displayed;
    }
    let gap = target - displayed;
    let step = (gap / 10).clamp(3, 50).min(gap);
    displayed + step
}

/// Stall intensity in `0.0..=1.0` (CC `stalledIntensity`): 0 until output has
/// been silent for the ~3s threshold, then ramps linearly to fully-red over the
/// next ~3s. Drives interpolation of the spinner/label color toward error-red so
/// a frozen turn visibly reddens instead of cheerfully spinning.
fn stall_t(stall_secs: f64) -> f64 {
    const THRESHOLD: f64 = 3.0;
    const RAMP: f64 = 3.0;
    ((stall_secs - THRESHOLD) / RAMP).clamp(0.0, 1.0)
}


/// Escalating verb for the live thinking segment (CC parity:
/// "thinking" → "thinking more" → "thinking harder" as the current thinking
/// stretch grows). `secs` is the elapsed time in the active thinking phase.
fn thinking_phrase(secs: u64) -> &'static str {
    if secs < 8 {
        "thinking"
    } else if secs < 20 {
        "thinking more"
    } else {
        "thinking harder"
    }
}

/// Tool symbol + verb mapping for activity feed
fn tool_display(name: &str) -> (&'static str, &'static str) {
    match name {
        // Search tools
        "web_search" | "WebSearch" => (">", "searching"),
        "grep" | "Grep" | "file_grep" => (">", "searching"),
        "glob" | "Glob" | "file_glob" => (">", "finding"),

        // Read tools
        "read" | "Read" | "file_read" => (">", "reading"),
        "web_fetch" | "WebFetch" => (">", "fetching"),

        // Write tools
        "write" | "Write" | "file_write" => (">", "writing"),
        "file_edit" | "Edit" => (">", "editing"),

        // Execute tools
        "bash" | "Bash" | "terminal" | "shell_execute" => ("$", "executing"),

        // Directory
        "dir_list" => (">", "listing"),

        // Agent tools
        "delegate" | "Delegate" | "Task" => (">", "delegating"),
        "orchestrate" => (">", "orchestrating"),
        "use_skill" => (">", "using skill"),

        // Task tools
        "task_write" | "TaskWrite" | "TaskCreate" => (">", "planning"),
        "task_read" | "TaskRead" | "TaskList" => (">", "checking"),
        "ask_user" => ("?", "asking"),

        // Diagnostics
        "diagnostics" | "doctor" => (">", "diagnosing"),

        // Memory
        "memory" | "recall" | "session_search" => (">", "recalling"),

        // MCP
        _ if name.starts_with("mcp__") => (">", "extending"),

        // Fallback
        _ => (">", "running"),
    }
}

/// True for the tools that SPAWN a sub-agent. Their live feed line must not
/// carry a duration: the fleet roster already shows that worker's age on its own
/// row, and the turn clock lives on the status line — a third number for the
/// same work is exactly the multi-timer clutter this feed is meant to avoid.
fn is_agent_tool(name: &str) -> bool {
    matches!(
        name,
        "delegate" | "Delegate" | "Task" | "orchestrate" | "spawn_agent"
    )
}

/// Whether `hint` is the backend's *parameter-name* fallback rather than a real
/// argument preview.
///
/// The backend's `tool_call_hint/1` ends with
/// `args |> Map.keys() |> Enum.take(2) |> Enum.join(", ")` for any tool it has no
/// specific clause for — so a `delegate` call arrived as the literal string
/// `"name, role"`, i.e. the SCHEMA's parameter names. Rendered as the tool label
/// it produced `delegatingname, role`: meaningless, and actively misleading (it
/// looks like a value). Detect that exact shape — two-or-more comma-separated
/// bare identifiers — and drop it, rather than painting schema noise. A genuine
/// hint (a path, a command, a query, a skill name) contains separators, spaces
/// or punctuation and is never mistaken for one.
fn is_param_name_list(hint: &str) -> bool {
    let parts: Vec<&str> = hint.split(',').map(|p| p.trim()).collect();
    parts.len() >= 2
        && parts.iter().all(|p| {
            !p.is_empty()
                && p.chars()
                    .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
        })
}

/// Tool activity entry in the feed
struct ToolEntry {
    name: String,
    emoji: &'static str,
    verb: &'static str,
    detail: String,
    start: std::time::Instant,
    duration_ms: Option<u64>,
    success: Option<bool>,
    /// Backend call ids currently merged into this row. Pairing `ToolCallEnd`
    /// against these (rather than against the tool NAME) is what keeps two
    /// concurrent `delegate` calls from ending each other's row.
    call_ids: Vec<String>,
    /// How many in-flight calls this single row represents. `>1` when identical
    /// concurrent calls were folded together; rendered as a `×N` multiplier
    /// instead of N byte-identical lines stacked on top of each other.
    concurrent: usize,
}

/// Verbosity level for tool display (Hermes-inspired 4-level toggle)
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Verbosity {
    Off,
    New,
    All,
    Verbose,
}

impl Verbosity {
    pub fn cycle(self) -> Self {
        match self {
            Self::Off => Self::New,
            Self::New => Self::All,
            Self::All => Self::Verbose,
            Self::Verbose => Self::Off,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::New => "new",
            Self::All => "all",
            Self::Verbose => "verbose",
        }
    }
}

/// Activity panel showing real-time processing state, tool feed, and backend metrics
pub struct Activity {
    active: bool,
    phase: ProcessingPhase,
    tool_feed: Vec<ToolEntry>,
    last_tool_name: String,
    input_tokens: u64,
    output_tokens: u64,
    /// Reasoning tokens for the latest iteration (item 4). Included in the true
    /// context total; not summed across iterations.
    reasoning_tokens: u64,
    /// Prompt-cache read tokens (item 4) — the cheap, already-cached context.
    cache_read_tokens: u64,
    /// Prompt-cache write tokens (item 4) — freshly cached this iteration.
    cache_write_tokens: u64,
    /// Cumulative OUTPUT tokens across ALL LLM iterations this turn. `set_tokens`
    /// reports the CURRENT iteration's absolute count (which resets to a small
    /// number each new iteration), so the live "↓ N tokens" must sum them here
    /// or it visibly jumps DOWN mid-turn. Reset in `start()`.
    turn_output_tokens: u64,
    /// The last iteration's absolute output count, so `set_tokens` can add only
    /// the DELTA to `turn_output_tokens` (handles both per-iteration-reset and
    /// monotonic-within-iteration reporting without double counting).
    last_iter_output: u64,
    stream_chars: usize,
    thinking_chars: usize,
    model_name: String,
    llm_iteration: u32,
    /// Per-turn iteration ceiling from the backend (item 6). None on older backends.
    llm_max_iterations: Option<u32>,
    expanded: bool,
    phrase_tick: u32,
    /// Starting index into SPINNER_VERBS for this request, so each one opens on a
    /// different verb instead of always "Accomplishing".
    verb_offset: usize,
    start_time: Option<std::time::Instant>,
    /// When the CURRENT processing phase began (stamped on every `set_phase`
    /// transition). Drives the phase-elapsed timer in the dual-timer status group
    /// so the row shows both "time in this activity" and "time in the turn".
    phase_since: Option<std::time::Instant>,
    /// When output last flowed (streamed/thinking chars, a usage report, or a
    /// tool edge). Drives the stall→red interpolation: no progress for ~3s bleeds
    /// the spinner/label color toward error-red (CC `stalledIntensity`).
    last_output_at: Option<std::time::Instant>,
    /// Eased on-screen token counter — steps toward the real value in `tick()`
    /// (CC token easing) so the count glides instead of snapping on each usage
    /// report. Reset in `start()`.
    displayed_tokens: u64,
    /// Whether the turn is being cancelled (interrupt landed, teardown pending).
    /// Drives the red "Cancelling…" spinner label. Set via `set_cancelling`.
    cancelling: bool,
    /// When the current thinking stretch began (phase == Thinking). Drives the
    /// CC-style "thinking" status segment; on leaving Thinking the duration is
    /// captured into `thought_for` so "thought for Ns" lingers briefly.
    thinking_since: Option<std::time::Instant>,
    /// (seconds, captured_at) of the last completed thinking stretch. Rendered
    /// as "thought for Ns" for 2s after capture (CC's minimum-display window),
    /// then expires by age check in `draw` — no mutation needed.
    thought_for: Option<(u64, std::time::Instant)>,
    /// Current reasoning-effort tier ("fast"|"medium"|"high"|"xhigh"|"ultra"),
    /// synced each frame from the status bar (`set_current_effort`). Rendered
    /// inside the live thinking segment as CC's "thinking with <effort> effort".
    /// A session setting, so it is NOT reset by `start()`/`stop()`.
    current_effort: Option<String>,
    /// When set, overrides the rotating spinner verb with the active task's
    /// present-continuous form (Claude Code's `activeForm`), so the spinner shows
    /// the concrete current step (e.g. "Wiring the checklist…") instead of a
    /// random flavor word. Cleared when no task is in progress.
    active_verb: Option<String>,
    /// Live retry/rate-limit state (item 1). `Some` while the backend is
    /// retrying a failed provider call; cleared the moment the turn resumes
    /// (tokens/stream/non-Waiting phase).
    retry: Option<RetryState>,
    /// Named blocking reason (item 3). When the phase is `Waiting`, this
    /// replaces the flavor verb with e.g. "Waiting on subagent…".
    waiting_reason: Option<WaitingReason>,
    /// Whether the turn is parked on the USER (permission prompt / question /
    /// plan approval). Drives the pulsing ◆ "you're the blocker" cue (item 5).
    pending_user: bool,
    /// U-T22 — the first Esc of an in-turn double-press has been seen, so the
    /// persistent affordance reads "esc again to interrupt" until the second
    /// Esc lands (interrupt) or a non-Esc key disarms it. A single stray Esc
    /// can no longer kill a long turn.
    interrupt_armed: bool,
    /// U-T24 — number of messages queued behind the running turn (WS5 message
    /// queue). Surfaced as an "N queued" segment in the spinner status group.
    queued: usize,
    /// Reduced-motion flag (a11y): when true the shimmer sweep is disabled and
    /// the verb renders in a single flat color.
    reduced_motion: bool,
    pub verbosity: Verbosity,
    /// Screen-reader / plain-text mode. When true, `draw` emits a single static
    /// plain-language status line (no spinner, braille bars, or boxed chrome)
    /// instead of the rich animated activity panel.
    a11y: bool,

    // ── Codex-style details block (`status_indicator_widget.rs`) ──────────
    /// Optional secondary context rendered under the status line as wrapped
    /// `  └ ` rows (e.g. the concrete command being run, or the live reasoning
    /// summary). `None` ⇒ the block occupies no rows at all.
    details: Option<String>,
    /// Hard cap on rendered detail rows; the last kept row is ellipsized when
    /// the text overflows. Defaults to [`ACTIVITY_DETAILS_DEFAULT_MAX_LINES`].
    details_max_lines: usize,
    /// Content width seen by the most recent `draw`, so `height()`/`max_height()`
    /// can report the SAME row count the renderer will actually paint. `0` (no
    /// draw yet) falls back to the maximum, which over-reserves rather than
    /// clipping. Interior-mutable because `draw` takes `&self` (same pattern as
    /// `dialogs::permissions::viewport_height`).
    details_width: std::cell::Cell<u16>,

    // ── Pausable turn clock (Codex `pause_timer_at` / `resume_timer`) ─────
    /// Time already banked from previous (unpaused) stretches of this turn.
    elapsed_running: std::time::Duration,
    /// When the current unpaused stretch began. `None` while inactive.
    last_resume_at: Option<std::time::Instant>,
    /// Whether the clock is currently stopped (an approval modal owns the
    /// screen). While paused, `elapsed` does not advance.
    timer_paused: bool,

    // ── Live shell-command output ────────────────────────────────────────
    /// Bounded preview of the output streamed by the currently running shell
    /// command (`command_output_delta` events). Empty when nothing is
    /// streaming, in which case the feed renders exactly as it always did.
    /// One bounded preview buffer PER in-flight command, keyed by the owning
    /// `tool_call_id` (falling back to the command string when an older backend
    /// does not emit one).
    ///
    /// A SINGLE shared buffer was a live corruption bug: routing by command
    /// string meant two concurrent commands thrashed it (every delta from a
    /// different command cleared it), while the SAME command run twice
    /// concurrently never cleared and both streams interleaved into one buffer.
    live_streams: std::collections::HashMap<String, LiveCommandOutput>,
    /// Key of the stream most recently written to — the one the preview shows.
    /// (The activity slot has room for one tail; the freshest wins.)
    live_command: Option<String>,
}

/// Default cap on the number of `  └ ` detail rows shown under the status line
/// (Codex `STATUS_DETAILS_DEFAULT_MAX_LINES`).
pub const ACTIVITY_DETAILS_DEFAULT_MAX_LINES: usize = 3;

/// The hanging-indent prefix for the details block. Its DISPLAY WIDTH (4 cols)
/// is what continuation rows are indented by, so the wrapped text sits in one
/// clean column under the `└`.
const DETAILS_PREFIX: &str = "  \u{2514} ";

/// Width, in cells, of the compaction progress bar.
const PROGRESS_BAR_CELLS: usize = 20;

/// Render a MEASURED progress bar: `▰▰▰▰▰▰▱▱▱▱ 60% · chunk 6/10`.
///
/// # This function may only be called with real counts
///
/// It takes `done` and `total` because it renders a *fraction of known work* —
/// there is no time-based or animated variant on purpose. The only compaction
/// signal carrying a genuine ratio is `CompactionProgress`, which the backend
/// emits once per finished divide-and-conquer chunk against a `chunk_total`
/// fixed before summarization starts. Compactions that do not chunk (the
/// `/compact` manual path is a single summarizer call) emit no progress at all
/// and must render spinner + elapsed only.
///
/// A bar that sweeps on a timer while the system has no idea how far along it
/// is tells the user something the program does not know. That is a lie about
/// the state of the system, and it is worse than showing nothing, because the
/// user calibrates their patience against it.
///
/// Filled and empty cells use different GLYPHS (▰ / ▱), not different colours,
/// so the bar is readable in a monochrome terminal and by anyone who cannot
/// distinguish the two hues.
pub fn progress_bar(done: u32, total: u32) -> String {
    if total == 0 {
        return String::new();
    }
    let done = done.min(total);
    let ratio = done as f64 / total as f64;
    // Floor, so the bar only fills a cell that is genuinely earned and can
    // never read as complete before the last chunk lands.
    let filled = ((ratio * PROGRESS_BAR_CELLS as f64).floor() as usize).min(PROGRESS_BAR_CELLS);
    format!(
        "{}{} {}% · chunk {}/{}",
        "\u{25B0}".repeat(filled),
        "\u{25B1}".repeat(PROGRESS_BAR_CELLS - filled),
        (ratio * 100.0).floor() as u32,
        done,
        total
    )
}

/// Rotating counter so consecutive requests pick different starting verbs.
static VERB_SEED: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

/// Spinner verbs. A big playful set (seeded from Claude Code's list) PLUS our own
/// OSA / SORX / Signal-Theory flavored ones so it reads as ours, not a copy.
const SPINNER_VERBS: &[&str] = &[
    // — OSA / SORX / Signal Theory (ours) —
    "Signaling", "Denoising", "Optimizing", "Transducing", "Attenuating", "Homeostating",
    "Steering", "Resonating", "Modulating", "Amplifying", "Distilling", "Converging",
    "Pathfinding", "Aligning", "Focusing", "Sharpening", "Cohering", "Phasing",
    "Correlating", "Maximizing", "Signalizing", "Osafying", "Steersmanning", "Sorxing",
    // — playful general set —
    "Accomplishing", "Actioning", "Actualizing", "Architecting", "Baking", "Beaming",
    "Befuddling", "Billowing", "Blanching", "Bloviating", "Boogieing", "Boondoggling",
    "Booping", "Bootstrapping", "Brewing", "Bunning", "Burrowing", "Calculating",
    "Canoodling", "Caramelizing", "Cascading", "Catapulting", "Cerebrating", "Channeling",
    "Choreographing", "Churning", "Coalescing", "Cogitating", "Combobulating", "Composing",
    "Computing", "Concocting", "Considering", "Contemplating", "Cooking", "Crafting",
    "Creating", "Crunching", "Crystallizing", "Cultivating", "Deciphering", "Deliberating",
    "Determining", "Discombobulating", "Doing", "Doodling", "Drizzling", "Ebbing",
    "Effecting", "Elucidating", "Embellishing", "Enchanting", "Envisioning", "Evaporating",
    "Fermenting", "Finagling", "Flibbertigibbeting", "Flowing", "Flummoxing", "Fluttering",
    "Forging", "Forming", "Frolicking", "Frosting", "Gallivanting", "Galloping",
    "Garnishing", "Generating", "Gesticulating", "Germinating", "Grooving", "Gusting",
    "Harmonizing", "Hashing", "Hatching", "Herding", "Honking", "Hullaballooing",
    "Hyperspacing", "Ideating", "Imagining", "Improvising", "Incubating", "Inferring",
    "Infusing", "Ionizing", "Jitterbugging", "Julienning", "Kneading", "Leavening",
    "Levitating", "Lollygagging", "Manifesting", "Marinating", "Meandering", "Metamorphosing",
    "Misting", "Moonwalking", "Moseying", "Mulling", "Mustering", "Musing",
    "Nebulizing", "Nesting", "Noodling", "Nucleating", "Orbiting", "Orchestrating",
    "Osmosing", "Perambulating", "Percolating", "Perusing", "Philosophising", "Photosynthesizing",
    "Pollinating", "Pondering", "Pontificating", "Pouncing", "Precipitating", "Prestidigitating",
    "Processing", "Proofing", "Propagating", "Puttering", "Puzzling", "Quantumizing",
    "Razzmatazzing", "Recombobulating", "Reticulating", "Roosting", "Ruminating", "Scampering",
    "Schlepping", "Scurrying", "Seasoning", "Shenaniganing", "Shimmying", "Simmering",
    "Skedaddling", "Sketching", "Slithering", "Smooshing", "Spelunking", "Spinning",
    "Sprouting", "Stewing", "Sublimating", "Swirling", "Swooping", "Synthesizing",
    "Tempering", "Thinking", "Thundering", "Tinkering", "Tomfoolering", "Transfiguring",
    "Transmuting", "Twisting", "Undulating", "Unfurling", "Unravelling", "Vibing",
    "Waddling", "Wandering", "Warping", "Whirlpooling", "Whirring", "Whisking",
    "Wibbling", "Working", "Wrangling", "Zesting", "Zigzagging",
];

impl Activity {
    pub fn new() -> Self {
        Self {
            active: false,
            phase: ProcessingPhase::Waiting,
            tool_feed: Vec::new(),
            last_tool_name: String::new(),
            input_tokens: 0,
            output_tokens: 0,
            reasoning_tokens: 0,
            cache_read_tokens: 0,
            cache_write_tokens: 0,
            turn_output_tokens: 0,
            last_iter_output: 0,
            stream_chars: 0,
            thinking_chars: 0,
            model_name: String::new(),
            llm_iteration: 0,
            llm_max_iterations: None,
            expanded: false,
            phrase_tick: 0,
            verb_offset: 0,
            start_time: None,
            phase_since: None,
            last_output_at: None,
            displayed_tokens: 0,
            cancelling: false,
            thinking_since: None,
            thought_for: None,
            current_effort: None,
            active_verb: None,
            retry: None,
            waiting_reason: None,
            pending_user: false,
            interrupt_armed: false,
            queued: 0,
            reduced_motion: false,
            verbosity: Verbosity::All,
            a11y: false,
            details: None,
            details_max_lines: ACTIVITY_DETAILS_DEFAULT_MAX_LINES,
            details_width: std::cell::Cell::new(0),
            elapsed_running: std::time::Duration::ZERO,
            last_resume_at: None,
            timer_paused: false,
            live_streams: std::collections::HashMap::new(),
            live_command: None,
        }
    }

    /// Sync the current reasoning-effort tier (from the status bar) so the live
    /// thinking segment can read "thinking with <effort> effort" (CC parity).
    /// Pass `None`/blank to hide the effort suffix. Additive: never touches the
    /// existing "Thought for Ns" timer or verb rotation.
    pub fn set_current_effort(&mut self, effort: Option<String>) {
        self.current_effort = effort.filter(|s| !s.trim().is_empty() && s.trim() != "off");
    }

    /// Enable/disable the shimmer sweep (reduced-motion a11y). When enabled the
    /// verb renders flat; the discrete frame spinner is unaffected.
    pub fn set_reduced_motion(&mut self, on: bool) {
        self.reduced_motion = on;
    }

    /// Item 1 — begin/refresh the live retry indicator. Pass `None` to clear it
    /// explicitly (e.g. on a fatal error path).
    pub fn set_retry(&mut self, retry: Option<RetryState>) {
        self.retry = retry;
    }

    /// Whether a retry indicator is currently held on the spinner row.
    pub fn is_retrying(&self) -> bool {
        self.retry.is_some()
    }

    /// Clear the retry indicator because the turn resumed. Called from every
    /// "work is flowing again" path (tokens, stream/thinking chars, and any
    /// non-Waiting phase transition).
    fn clear_retry(&mut self) {
        self.retry = None;
    }

    /// Item 3 — name the current blocking reason (or `None` to fall back to the
    /// flavor verb). Only surfaced while the phase is `Waiting`.
    pub fn set_waiting_reason(&mut self, reason: Option<WaitingReason>) {
        self.waiting_reason = reason;
    }

    /// Item 5 — mark/unmark the turn as blocked on the USER (permission prompt,
    /// question, or plan approval), driving the pulsing ◆ cue.
    pub fn set_pending_user(&mut self, pending: bool) {
        self.pending_user = pending;
    }

    /// Whether the turn is currently parked on the user.
    pub fn pending_user(&self) -> bool {
        self.pending_user
    }

    /// Item 4 — the true context-window token number: input + output(turn) +
    /// reasoning + cache-read + cache-write (opencode `prompt/index.tsx:271`).
    /// The output component is the turn-cumulative count the spinner shows.
    pub fn total_tokens(&self) -> u64 {
        self.input_tokens
            + self.turn_output_tokens
            + self.reasoning_tokens
            + self.cache_read_tokens
            + self.cache_write_tokens
    }

    /// Enable/disable screen-reader (plain-text) mode.
    pub fn set_a11y(&mut self, on: bool) {
        self.a11y = on;
    }

    /// Whether screen-reader (plain-text) mode is active.
    pub fn a11y(&self) -> bool {
        self.a11y
    }

    /// Plain-language description of the current activity for screen-reader mode.
    /// A running tool takes precedence (announces the concrete action); otherwise
    /// falls back to the active task step, then the processing-phase label.
    fn a11y_status(&self) -> String {
        // Blocking states take precedence so a screen reader announces WHY the
        // turn is stalled, not a flavor verb.
        if self.pending_user {
            return "waiting for your input".to_string();
        }
        if let Some(r) = self.retry.as_ref() {
            return format!("retrying, attempt {} of {}", r.attempt, r.max_attempts);
        }
        if self.phase == ProcessingPhase::Waiting {
            if let Some(reason) = self.waiting_reason {
                return reason.label().to_lowercase();
            }
        }
        if let Some(entry) = self.tool_feed.iter().rev().find(|e| e.duration_ms.is_none()) {
            if entry.detail.is_empty() {
                return format!("{} ({})", entry.verb, entry.name);
            }
            return format!("{} {}", entry.verb, entry.detail);
        }
        if let Some(v) = self.active_verb.as_deref() {
            return v.to_string();
        }
        crate::a11y::phase_label(self.phase).to_string()
    }

    /// Append a `command_output_delta` chunk to the live preview of the stream
    /// identified by `key` (the owning `tool_call_id`, or the command string on
    /// an older backend). Each key owns its OWN buffer, so concurrent commands
    /// never overwrite or interleave each other's output. The stream just
    /// written to becomes the one the preview shows.
    pub fn push_command_output(&mut self, key: &str, chunk: &str) {
        self.live_streams
            .entry(key.to_string())
            .or_insert_with(LiveCommandOutput::new)
            .push_str(chunk);
        if self.live_command.as_deref() != Some(key) {
            self.live_command = Some(key.to_string());
        }
        // Output flowed — reset the stall bleed exactly like streaming text does.
        self.last_output_at = Some(std::time::Instant::now());
    }

    /// Drop EVERY live preview (the turn ended / a fresh turn started).
    pub fn clear_command_output(&mut self) {
        self.live_streams.clear();
        self.live_command = None;
    }

    /// Drop only the preview owned by `key` (that one command finished). Other
    /// still-running commands keep their buffers. If the dropped stream was the
    /// one on screen, fall back to any other stream that still has output.
    pub fn clear_command_output_for(&mut self, key: &str) {
        self.live_streams.remove(key);
        if self.live_command.as_deref() == Some(key) {
            self.live_command = self
                .live_streams
                .iter()
                .find(|(_, buf)| !buf.is_empty())
                .map(|(k, _)| k.clone());
        }
    }

    /// Whether the stream owned by `key` has produced nothing yet. Used to decide
    /// whether a delta with `seq > 0` must seed from the rolling `tail` snapshot.
    pub fn live_stream_is_empty(&self, key: &str) -> bool {
        self.live_streams.get(key).map_or(true, |b| b.is_empty())
    }

    /// The rows the live preview currently wants to render (0 when idle).
    pub fn live_output_lines(&self) -> Vec<String> {
        match self
            .live_command
            .as_deref()
            .and_then(|k| self.live_streams.get(k))
        {
            Some(buf) if !buf.is_empty() => buf.tail_lines(LIVE_OUTPUT_PREVIEW_LINES),
            _ => Vec::new(),
        }
    }

    pub fn start(&mut self) {
        self.active = true;
        self.phase = ProcessingPhase::Waiting;
        self.tool_feed.clear();
        self.clear_command_output();
        self.last_tool_name.clear();
        self.input_tokens = 0;
        self.output_tokens = 0;
        self.reasoning_tokens = 0;
        self.cache_read_tokens = 0;
        self.cache_write_tokens = 0;
        self.turn_output_tokens = 0;
        self.last_iter_output = 0;
        self.stream_chars = 0;
        self.thinking_chars = 0;
        self.llm_iteration = 0;
        self.llm_max_iterations = None;
        self.phrase_tick = 0;
        self.verb_offset =
            VERB_SEED.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let now = std::time::Instant::now();
        self.start_time = Some(now);
        self.phase_since = Some(now);
        self.last_output_at = Some(now);
        // Fresh turn ⇒ fresh (running) clock.
        self.elapsed_running = std::time::Duration::ZERO;
        self.last_resume_at = Some(now);
        self.timer_paused = false;
        self.details = None;
        self.details_max_lines = ACTIVITY_DETAILS_DEFAULT_MAX_LINES;
        self.displayed_tokens = 0;
        self.cancelling = false;
        self.thinking_since = None;
        self.thought_for = None;
        self.retry = None;
        self.waiting_reason = None;
        self.pending_user = false;
        self.interrupt_armed = false;
        self.queued = 0;
    }

    pub fn stop(&mut self) {
        self.active = false;
        self.phase = ProcessingPhase::Waiting;
        self.clear_command_output();
        self.start_time = None;
        self.elapsed_running = std::time::Duration::ZERO;
        self.last_resume_at = None;
        self.timer_paused = false;
        self.details = None;
        self.details_max_lines = ACTIVITY_DETAILS_DEFAULT_MAX_LINES;
        self.phase_since = None;
        self.last_output_at = None;
        self.displayed_tokens = 0;
        self.cancelling = false;
        self.active_verb = None;
        self.thinking_since = None;
        self.thought_for = None;
        self.retry = None;
        self.waiting_reason = None;
        self.pending_user = false;
        self.interrupt_armed = false;
        self.queued = 0;
    }

    /// Mark/unmark the turn as being cancelled, driving the red "Cancelling…"
    /// spinner label. Cleared by `start()`/`stop()` on the next turn edge.
    pub fn set_cancelling(&mut self, cancelling: bool) {
        self.cancelling = cancelling;
    }

    /// Whether the spinner is showing the cancelling state.
    pub fn is_cancelling(&self) -> bool {
        self.cancelling
    }

    /// U-T22 — arm/disarm the "esc again to interrupt" affordance. Armed by the
    /// first in-turn Esc; disarmed on the interrupting second Esc or any other
    /// key. Idempotent.
    pub fn arm_interrupt(&mut self, armed: bool) {
        self.interrupt_armed = armed;
    }

    /// Whether the in-turn interrupt is armed (first Esc seen).
    pub fn is_interrupt_armed(&self) -> bool {
        self.interrupt_armed
    }

    /// U-T24 — set the number of messages queued behind the running turn.
    pub fn set_queued(&mut self, n: usize) {
        self.queued = n;
    }

    /// Seconds of AGENT time since the spinner clock started (`start()`), if
    /// running. This is the exact clock `draw` renders (floored the same way),
    /// exposed so the turn recap can print the same number the live spinner last
    /// showed.
    ///
    /// Note this is NOT wall-clock: stretches where the clock was paused
    /// ([`Self::pause_timer`], while an approval modal owns the screen) are
    /// excluded, so the reported duration is time the AGENT spent working, not
    /// time the human spent reading a prompt.
    pub fn elapsed_secs(&self) -> Option<u64> {
        self.start_time
            .map(|_| self.elapsed_duration_at(std::time::Instant::now()).as_secs())
    }

    /// Accumulated agent time at `now`: everything banked from earlier stretches
    /// plus the currently-running one (Codex `elapsed_duration_at`).
    fn elapsed_duration_at(&self, now: std::time::Instant) -> std::time::Duration {
        let mut elapsed = self.elapsed_running;
        if !self.timer_paused {
            if let Some(resumed) = self.last_resume_at {
                elapsed += now.saturating_duration_since(resumed);
            }
        }
        elapsed
    }

    #[cfg(test)]
    fn elapsed_secs_at(&self, now: std::time::Instant) -> u64 {
        self.elapsed_duration_at(now).as_secs()
    }

    /// Stop the turn clock — call when an approval/permission modal takes over
    /// the screen. Idempotent: a second pause is a no-op, so overlapping modals
    /// cannot double-bank the same stretch.
    pub fn pause_timer(&mut self) {
        self.pause_timer_at(std::time::Instant::now());
    }

    /// Restart the turn clock after a modal is dismissed. Idempotent.
    pub fn resume_timer(&mut self) {
        self.resume_timer_at(std::time::Instant::now());
    }

    fn pause_timer_at(&mut self, now: std::time::Instant) {
        if self.timer_paused {
            return;
        }
        if let Some(resumed) = self.last_resume_at {
            self.elapsed_running += now.saturating_duration_since(resumed);
        }
        self.timer_paused = true;
    }

    fn resume_timer_at(&mut self, now: std::time::Instant) {
        if !self.timer_paused {
            return;
        }
        self.last_resume_at = Some(now);
        self.timer_paused = false;
    }

    /// Whether the turn clock is currently stopped.
    pub fn is_timer_paused(&self) -> bool {
        self.timer_paused
    }

    /// Set (or clear with `None`) the `  └ ` details block shown under the status
    /// line — the concrete thing behind the verb (a command, a path, the live
    /// reasoning summary). `max_lines` caps the rendered rows (clamped to >= 1;
    /// pass [`ACTIVITY_DETAILS_DEFAULT_MAX_LINES`] for the Codex default).
    ///
    /// Blank/whitespace-only text clears the block rather than reserving an
    /// empty row.
    pub fn set_details(&mut self, details: Option<String>, max_lines: usize) {
        self.details_max_lines = max_lines.max(1);
        self.details = details
            .map(|d| d.trim().to_string())
            .filter(|d| !d.is_empty());
    }

    /// The details text currently held, if any.
    pub fn details(&self) -> Option<&str> {
        self.details.as_deref()
    }

    /// Wrap the details text to `width` columns with a hanging indent aligned
    /// under [`DETAILS_PREFIX`], truncating to `details_max_lines` and
    /// ellipsizing the last kept row when it overflows (Codex
    /// `wrapped_details_lines`).
    fn wrapped_details_lines(&self, width: u16) -> Vec<String> {
        let Some(details) = self.details.as_deref() else {
            return Vec::new();
        };
        let prefix_cols = crate::util::cols(DETAILS_PREFIX);
        if width == 0 || (width as usize) <= prefix_cols {
            return Vec::new();
        }
        let content_cols = (width as usize).saturating_sub(prefix_cols).max(1);
        let indent = " ".repeat(prefix_cols);

        let mut out: Vec<String> = Vec::new();
        let mut overflowed = false;
        'outer: for logical in details.lines() {
            for piece in crate::render::markdown::wrap_text(logical, content_cols) {
                if out.len() == self.details_max_lines {
                    // One more row than we can show ⇒ the last kept row gets `…`.
                    overflowed = true;
                    break 'outer;
                }
                let prefix = if out.is_empty() { DETAILS_PREFIX } else { &indent };
                out.push(format!("{}{}", prefix, piece));
            }
        }

        if overflowed {
            // Both prefixes are the same char/column count, so stripping the
            // first `prefix_chars` chars leaves exactly the wrapped body.
            let prefix_chars = DETAILS_PREFIX.chars().count();
            let on_first_row = out.len() == 1;
            if let Some(last) = out.last_mut() {
                let body: String = last.chars().skip(prefix_chars).collect();
                let prefix = if on_first_row { DETAILS_PREFIX } else { indent.as_str() };
                *last = format!("{}{}", prefix, ellipsize_cols(&body, content_cols));
            }
        }
        out
    }

    /// Rows the details block contributes to BOTH [`Self::height`] and
    /// [`Self::max_height`] — they must agree or the inline viewport either
    /// clips the block or leaves dead rows under it.
    fn details_rows(&self) -> u16 {
        if self.details.is_none() || self.a11y {
            return 0;
        }
        let width = self.details_width.get();
        if width == 0 {
            // Not drawn yet: reserve the ceiling rather than under-reserve.
            return self.details_max_lines as u16;
        }
        self.wrapped_details_lines(width).len() as u16
    }

    /// Override the spinner verb with the currently-active task's present-
    /// continuous form (Claude Code's `activeForm`). Pass `None` to fall back to
    /// the rotating flavor verbs (no task in progress).
    pub fn set_active_verb(&mut self, verb: Option<String>) {
        self.active_verb = verb.filter(|v| !v.trim().is_empty());
    }

    /// The spinner's verb: the active task's present-continuous form when a
    /// task is in progress, otherwise ONE flavor verb held for the whole turn
    /// (CC parity — seeded per request via `verb_offset`, never cycled
    /// mid-turn).
    fn spinner_verb(&self) -> &str {
        match self.active_verb.as_deref() {
            Some(v) => v,
            None => SPINNER_VERBS[self.verb_offset % SPINNER_VERBS.len()],
        }
    }

    /// Set processing phase (auto-activates if inactive). Tracks thinking
    /// stretches for the CC-style "thinking" / "thought for Ns" status segment:
    /// entering Thinking stamps the start, leaving it captures the duration
    /// (clamped to 1s minimum, CC's Math.max(1, round) parity).
    pub fn set_phase(&mut self, phase: ProcessingPhase) {
        // A phase transition restarts the phase-elapsed clock (the dual-timer's
        // "time in this activity" leg).
        if phase != self.phase {
            self.phase_since = Some(std::time::Instant::now());
        }
        if phase == ProcessingPhase::Thinking {
            if self.thinking_since.is_none() {
                self.thinking_since = Some(std::time::Instant::now());
            }
        } else if let Some(since) = self.thinking_since.take() {
            let secs = since.elapsed().as_secs().max(1);
            self.thought_for = Some((secs, std::time::Instant::now()));
        }
        // Any real work phase counts as progress, so it also refreshes the
        // stall clock (a phase change is the turn moving forward, not frozen).
        if phase != ProcessingPhase::Waiting {
            self.last_output_at = Some(std::time::Instant::now());
        }
        self.phase = phase;
        // Any non-Waiting phase means the turn is producing work again, so a
        // held retry indicator and a stale "waiting on X" reason are cleared
        // (item 1/3: "clear on resume").
        if phase != ProcessingPhase::Waiting {
            self.clear_retry();
            self.waiting_reason = None;
            // The user's decision unblocked the turn (work is happening again),
            // so the "you're the blocker" pulse is stale (item 5).
            self.pending_user = false;
        }
        if !self.active {
            self.active = true;
            let now = std::time::Instant::now();
            self.start_time = Some(now);
            // Keep the pausable clock in step with `start_time` on this
            // implicit-activation path, or `elapsed` would read 0 forever.
            self.elapsed_running = std::time::Duration::ZERO;
            self.last_resume_at = Some(now);
            self.timer_paused = false;
        }
    }

    /// Legacy compat: enable thinking indicator via phase. Routed through
    /// `set_phase` so thinking-stretch tracking sees this path too.
    pub fn set_thinking(&mut self, thinking: bool) {
        if thinking {
            self.set_phase(ProcessingPhase::Thinking);
        }
    }

    pub fn is_thinking(&self) -> bool {
        self.phase == ProcessingPhase::Thinking
    }

    pub fn is_active(&self) -> bool {
        self.active
    }

    pub fn add_stream_chars(&mut self, n: usize) {
        self.stream_chars += n;
        // Output is flowing again → the turn resumed; drop any retry label and
        // refresh the stall clock (progress means "not frozen").
        if n > 0 {
            self.clear_retry();
            self.last_output_at = Some(std::time::Instant::now());
        }
    }

    pub fn add_thinking_chars(&mut self, n: usize) {
        self.thinking_chars += n;
        if n > 0 {
            self.clear_retry();
            self.last_output_at = Some(std::time::Instant::now());
        }
    }

    pub fn set_model_name(&mut self, name: &str) {
        self.model_name = name.to_string();
    }

    pub fn set_iteration(&mut self, iteration: u32) {
        self.llm_iteration = iteration;
    }

    pub fn set_max_iterations(&mut self, max_iterations: Option<u32>) {
        self.llm_max_iterations = max_iterations;
    }

    /// Record a tool call start
    pub fn tool_start(&mut self, name: &str, args: &str) {
        self.tool_start_with_id(name, args, None);
    }

    /// Record a tool call start, carrying the backend's stable per-call id when
    /// it sent one. The id is what lets [`Self::tool_end_with_id`] close the
    /// RIGHT row when several same-name calls are in flight at once.
    ///
    /// Identical concurrent calls (same tool, same argument hint, both still
    /// running) are folded into ONE row with a `×N` multiplier: two `delegate`
    /// calls previously drew two byte-identical lines, which read as a rendering
    /// glitch rather than as two workers.
    pub fn tool_start_with_id(&mut self, name: &str, args: &str, call_id: Option<&str>) {
        let (emoji, verb) = tool_display(name);
        // Argument preview. Three shapes have to be rejected or reduced here:
        //   * schema parameter-name fallbacks (`"options, question"`) — dropped;
        //   * raw JSON args (file-edit ships its whole arg map so the diff
        //     renderer can work) — reduced to the identifying value, i.e. the
        //     PATH, instead of dumping `{"new_string":"  @doc \"Start…`;
        //   * anything over the column budget — width-aware, and for a path the
        //     filename (the tail) is what survives, not the head.
        let hint = crate::util::arg_summary(args.trim());
        let hint = hint.trim();
        let detail = if hint.is_empty() || is_param_name_list(hint) {
            String::new()
        } else {
            crate::util::fit_arg_summary(hint, 60)
        };

        // Fold an identical still-running call into the existing row.
        if let Some(existing) = self
            .tool_feed
            .iter_mut()
            .rev()
            .find(|e| e.name == name && e.detail == detail && e.duration_ms.is_none())
        {
            existing.concurrent += 1;
            if let Some(id) = call_id {
                existing.call_ids.push(id.to_string());
            }
            self.last_tool_name = name.to_string();
            self.last_output_at = Some(std::time::Instant::now());
            return;
        }

        self.tool_feed.push(ToolEntry {
            name: name.to_string(),
            emoji,
            verb,
            detail,
            start: std::time::Instant::now(),
            duration_ms: None,
            success: None,
            call_ids: call_id.map(|id| vec![id.to_string()]).unwrap_or_default(),
            concurrent: 1,
        });
        self.last_tool_name = name.to_string();
        self.last_output_at = Some(std::time::Instant::now());
        // Keep feed bounded
        if self.tool_feed.len() > 20 {
            self.tool_feed.remove(0);
        }
    }

    /// Record a tool call end
    pub fn tool_end(&mut self, name: &str, duration_ms: u64, success: bool) {
        self.tool_end_with_id(name, duration_ms, success, None);
    }

    /// Close a tool call, pairing by the backend's per-call id when present.
    ///
    /// Name-only pairing closed whichever same-name row happened to be last,
    /// so with two concurrent `delegate` calls the first completion froze the
    /// second worker's line. When the id is known we close the row that actually
    /// owns it; a row standing in for several folded concurrent calls just loses
    /// one of them and keeps running until the last id is retired.
    pub fn tool_end_with_id(
        &mut self,
        name: &str,
        duration_ms: u64,
        success: bool,
        call_id: Option<&str>,
    ) {
        let idx = call_id
            .and_then(|id| {
                self.tool_feed
                    .iter()
                    .rposition(|e| e.duration_ms.is_none() && e.call_ids.iter().any(|c| c == id))
            })
            .or_else(|| {
                self.tool_feed
                    .iter()
                    .rposition(|e| e.name == name && e.duration_ms.is_none())
            });
        if let Some(i) = idx {
            let entry = &mut self.tool_feed[i];
            if let Some(id) = call_id {
                entry.call_ids.retain(|c| c != id);
            }
            if entry.concurrent > 1 {
                // Other folded calls are still in flight — the row keeps running.
                entry.concurrent -= 1;
            } else {
                // The wire type is a bare `u64`, so a 0 is ambiguous: either the
                // backend did not track this call, or the call really did finish
                // in under a millisecond. Disambiguate with the TUI-side clock,
                // which is an UPPER bound on the true duration (it also contains
                // the SSE round trip).
                //
                // Below the threshold a 0 is credible and is kept — substituting
                // the TUI measurement there would inflate a genuine 0.4 ms read
                // into "15ms" of mostly transport latency. Above it, the call was
                // demonstrably not instant, so the backend simply did not report
                // and the TUI measurement is the only number available.
                const UNREPORTED_MS: u64 = 250;
                let observed_ms = entry.start.elapsed().as_millis() as u64;
                let effective_ms = if duration_ms == 0 && observed_ms >= UNREPORTED_MS {
                    observed_ms
                } else {
                    duration_ms
                };
                entry.duration_ms = Some(effective_ms);
                entry.success = Some(success);
            }
        }
        self.last_output_at = Some(std::time::Instant::now());
    }

    /// Report token counts for the CURRENT LLM iteration. `output` is the
    /// iteration's absolute running count (resets each new iteration), so we add
    /// only the delta into `turn_output_tokens` — the number shown to the user —
    /// which keeps the live count monotonic across a multi-iteration turn instead
    /// of jumping down when a new iteration starts.
    pub fn set_tokens(&mut self, input: u64, output: u64) {
        self.input_tokens = input;
        self.output_tokens = output;
        let delta = if output >= self.last_iter_output {
            output - self.last_iter_output
        } else {
            // New iteration reset the per-iteration count — start it from zero.
            output
        };
        self.turn_output_tokens += delta;
        self.last_iter_output = output;
        // A usage report means the provider call succeeded → the turn resumed;
        // any retry indicator is now stale (item 1), and the stall clock resets.
        self.clear_retry();
        self.last_output_at = Some(std::time::Instant::now());
    }

    /// Item 4 — richer usage report including the input, reasoning, and prompt-
    /// cache (read/write) breakdown, so the live count reflects the true
    /// context-window number instead of output-only. `input`/`output` are
    /// threaded through `set_tokens` (which keeps the turn-cumulative output
    /// monotonic); the cache/reasoning figures are the latest iteration's
    /// absolute values.
    pub fn set_tokens_detailed(
        &mut self,
        input: u64,
        output: u64,
        reasoning: u64,
        cache_read: u64,
        cache_write: u64,
    ) {
        self.reasoning_tokens = reasoning;
        self.cache_read_tokens = cache_read;
        self.cache_write_tokens = cache_write;
        self.set_tokens(input, output);
    }

    /// Item 2 — render the verb with a moving shimmer/glimmer sweep (CC
    /// `SpinnerAnimationRow` glimmerIndex). A bright highlight travels across
    /// the glyphs, interpolating each char's color between the base spinner
    /// tint and near-white by its distance from the highlight, giving the
    /// "alive, streaming" feel. Under reduced-motion the verb is a single flat
    /// span. The trailing `…` is appended by the caller path via this fn so the
    /// ellipsis rides along uncolored-bright.
    fn shimmer_verb_spans(
        &self,
        word: &str,
        base: Color,
        theme: &crate::style::Theme,
    ) -> Vec<Span<'static>> {
        if self.reduced_motion {
            return vec![Span::styled(
                format!("{}\u{2026}", word),
                Style::default().fg(base).add_modifier(Modifier::BOLD),
            )];
        }
        let bright = Color::Rgb(232, 240, 255);
        let chars: Vec<char> = word.chars().collect();
        let len = chars.len();
        let pos = shimmer_index(self.phrase_tick, len) as isize;
        let radius = 2.0_f64; // highlight half-width in chars
        let mut spans: Vec<Span<'static>> = chars
            .into_iter()
            .enumerate()
            .map(|(i, ch)| {
                let dist = (i as isize - pos).abs() as f64;
                // 0 at the highlight, 1 at/beyond the radius.
                let t = (1.0 - (dist / radius)).clamp(0.0, 1.0);
                let color = crate::style::gradient::lerp_color(base, bright, t);
                Span::styled(
                    ch.to_string(),
                    Style::default().fg(color).add_modifier(Modifier::BOLD),
                )
            })
            .collect();
        spans.push(Span::styled(
            "\u{2026}".to_string(),
            Style::default().fg(base).add_modifier(Modifier::BOLD),
        ));
        spans
    }

    /// The live token target: the turn-cumulative output count, floored by a
    /// char-based estimate (~4 chars/token) so the number only ever grows while
    /// streaming, before the backend reports the first usage.
    fn token_target(&self) -> u64 {
        let est = ((self.stream_chars + self.thinking_chars) / 4) as u64;
        self.turn_output_tokens.max(est)
    }

    /// Advance spinner animation on each tick, and ease the displayed token
    /// counter one step toward its real value (CC token easing) so the count
    /// glides up instead of snapping on each usage report.
    pub fn tick(&mut self) {
        if self.active {
            self.phrase_tick += 1;
            self.displayed_tokens = ease_tokens(self.displayed_tokens, self.token_target());
        }
    }

    /// Base color for the spinner glyph + verb, keyed on the current activity
    /// (grok `turn_status` colored labels): green while a tool runs, gray while
    /// thinking/responding, otherwise the light-blue "working" accent — then
    /// interpolated toward error-red by the stall intensity so a frozen turn
    /// visibly reddens. Retry/cancel states are colored at the call site.
    fn verb_base_color(&self, theme: &crate::style::Theme, stall: f64) -> Color {
        let tool_running = self
            .tool_feed
            .iter()
            .any(|e| e.duration_ms.is_none());
        let base = if tool_running {
            theme.colors.success
        } else if matches!(
            self.phase,
            ProcessingPhase::Thinking | ProcessingPhase::Streaming
        ) {
            theme.colors.muted
        } else {
            Color::Rgb(147, 165, 255)
        };
        crate::style::gradient::lerp_color(base, theme.colors.error, stall)
    }

    /// The rail's target accent for the current state (grok state→color map):
    /// cancelling ⇒ error red, pending-on-user ⇒ primary (its frozen full
    /// color), retrying ⇒ warning yellow, otherwise working ⇒ success green.
    fn rail_accent(&self, theme: &crate::style::Theme) -> Color {
        if self.cancelling {
            theme.colors.error
        } else if self.pending_user {
            theme.colors.primary
        } else if self.retry.is_some() {
            theme.colors.warning
        } else {
            theme.colors.success
        }
    }

    /// Whether the rail is frozen to a solid full-accent column (no traveling
    /// wave): when the turn is parked on the user, is being cancelled, or
    /// reduced-motion is set (a11y). Otherwise the wave animates.
    fn rail_frozen(&self) -> bool {
        self.cancelling || self.pending_user || self.reduced_motion
    }

    /// Paint the left luminance-wave accent rail down the live region's left
    /// edge (grok `wave_brightness`). Each row blends the theme surface toward
    /// the activity accent by the wave brightness at that (tick, row), so a
    /// crest travels down while the turn runs. Frozen states and reduced-motion
    /// paint a solid full-accent rail instead. Uses the caller's `tick` (the
    /// spinner's `frame_idx`) so it shares the one animation clock. Never called
    /// in a11y (plain-text) mode.
    fn draw_rail(
        &self,
        frame: &mut Frame,
        x: u16,
        y: u16,
        height: u16,
        tick: u64,
        theme: &crate::style::Theme,
    ) {
        let glyph = crate::render::glyphs::heavy_rail();
        let accent = self.rail_accent(theme);
        let bg = theme.colors.modal_bg;
        let frozen = self.rail_frozen();
        for r in 0..height {
            let brightness = if frozen {
                1.0
            } else {
                crate::render::colors::wave_brightness(tick, r, height)
            };
            let color = crate::render::colors::blend_color(bg, accent, brightness);
            frame.render_widget(
                Paragraph::new(Line::from(Span::styled(
                    glyph.to_string(),
                    Style::default().fg(color),
                ))),
                Rect::new(x, y + r, 1, 1),
            );
        }
    }

    pub fn height(&self) -> u16 {
        if !self.active {
            return 0;
        }
        // Plain-text mode is always a single static status line.
        if self.a11y {
            return 1;
        }
        // The `└ ` details block sits between the status line and the feed, so it
        // adds rows in EVERY verbosity (including `Off`, which is "status line
        // only" — the details are part of that status row, not the tool feed).
        let details = self.details_rows();
        match self.verbosity {
            Verbosity::Off => 1 + details,
            Verbosity::New => 2 + details,
            Verbosity::All => {
                let feed_lines = self.visible_feed_count().min(4) as u16;
                1 + details + feed_lines // spinner + details + feed
            }
            Verbosity::Verbose => {
                let feed_lines = self.visible_feed_count().min(8) as u16;
                1 + details + feed_lines
            }
        }
    }

    /// The MAXIMUM rows [`Self::height`] can return for the CURRENT mode, independent
    /// of how many tools are currently in the feed.
    ///
    /// The inline viewport reserves THIS so the slot height stays constant for the
    /// whole turn: a slot that tracks the live feed grows one row per tool, and every
    /// growth rebuilds the viewport (a DSR cursor re-anchor) — which stacks a fresh
    /// composer + status bar down the screen. Reserving a mode-derived ceiling is
    /// stable (verbosity only changes on explicit user action, never mid-turn) while
    /// never UNDER-reserving: the previous flat 6-row cap clipped `Verbose` (which
    /// wants 9), silently dropping the three oldest feed rows.
    pub fn max_height(&self) -> u16 {
        if !self.active {
            return 0;
        }
        if self.a11y {
            return 1;
        }
        // Must use the SAME `details_rows()` as `height()` — a details block that
        // is drawn but not reserved gets clipped; one reserved but not drawn
        // leaves dead rows (bare accent-rail glyphs) above the composer.
        let details = self.details_rows();
        match self.verbosity {
            Verbosity::Off => 1 + details,
            Verbosity::New => 2 + details,
            // spinner + details + the per-verbosity feed cap used by `height()`.
            Verbosity::All => 1 + details + 4,
            Verbosity::Verbose => 1 + details + 8,
        }
    }

    fn visible_feed_count(&self) -> usize {
        match self.verbosity {
            Verbosity::Off => 0,
            Verbosity::New => {
                // Only show if tool changed
                if self.tool_feed.is_empty() {
                    0
                } else {
                    1
                }
            }
            Verbosity::All => self.tool_feed.len().min(4),
            Verbosity::Verbose => self.tool_feed.len().min(8),
        }
    }
}

impl Component for Activity {
    fn handle_event(&mut self, _event: &Event) -> ComponentAction {
        ComponentAction::Ignored
    }

    fn draw(&self, frame: &mut Frame, area: Rect) {
        if !self.active || area.height == 0 {
            return;
        }
        // AGENT time, not wall-clock: paused stretches (an approval modal owning
        // the screen) are excluded, so a turn the user sat on for two minutes
        // still reports the seconds the agent actually worked.
        let elapsed = self.elapsed_secs().unwrap_or(0);

        // Screen-reader / plain-text mode: one static, unstyled status line. No
        // spinner glyph, no braille feed, no color — just plain language a screen
        // reader can announce ("OSA: running (bash) (12s, 1.5k tokens)").
        if self.a11y {
            let tokens =
                (self.turn_output_tokens as usize).max((self.stream_chars + self.thinking_chars) / 4);
            let mut text = format!("OSA: {} ({}", self.a11y_status(), crate::util::fmt_elapsed(elapsed));
            if tokens > 0 {
                text.push_str(&format!(", {} tokens", format_count(tokens)));
            }
            text.push(')');
            frame.render_widget(
                Paragraph::new(Line::from(Span::raw(text))),
                Rect::new(area.x, area.y, area.width, 1),
            );
            return;
        }

        let theme = crate::style::theme();

        // ── Left luminance-wave accent rail (grok `wave_brightness`) ─────
        // A subtle rail down the live region's left edge so the running turn
        // reads as "alive". Only the live region repaints each frame, so the
        // wave rides the existing spinner clock at no extra cost. The rail
        // reserves a 2-col gutter (rail glyph + a space); when the pane is too
        // narrow to spare it we drop the rail and keep the full width for text.
        // Never drawn in a11y (plain-text) mode — that path returned above.
        const RAIL_W: u16 = 2;
        let rail_on = area.width > RAIL_W + 8;
        // Record the width the details block will be wrapped at, so the NEXT
        // `height()`/`max_height()` reserves exactly what is painted here.
        self.details_width.set(if rail_on {
            area.width.saturating_sub(RAIL_W)
        } else {
            area.width
        });
        let content = if rail_on {
            Rect::new(area.x + RAIL_W, area.y, area.width - RAIL_W, area.height)
        } else {
            area
        };

        // Stall intensity: seconds since output last flowed → 0..1 red bleed
        // (CC stalledIntensity). Drives both the spinner-glyph/verb color and, if
        // the turn freezes, the whole row reddening.
        let stall_secs = self
            .last_output_at
            .map(|t| t.elapsed().as_secs_f64())
            .unwrap_or(0.0);
        let stall = stall_t(stall_secs);

        // Braille spinner (render::glyphs, legacy-fallback to |/-\). Advance on a
        // wall clock at ~7.5fps (133ms/frame) so it spins smoothly regardless of
        // the coarser ~200ms tick cadence.
        let frame_idx = self
            .start_time
            .map(|t| (t.elapsed().as_millis() / 133) as usize)
            .unwrap_or(self.phrase_tick as usize);
        let spinner_char = crate::render::glyphs::spinner_frame(frame_idx);

        // Paint the accent rail using the SAME spinner clock (`frame_idx`), so
        // the wave advances at the ~7.5fps cadence without a second timer.
        if rail_on {
            self.draw_rail(frame, area.x, area.y, area.height, frame_idx as u64, &theme);
        }

        // Live token counter: the EASED on-screen value (glides toward the real
        // count in tick()). Gated like CC — hidden until ~30s in unless the user
        // asked for verbose — so short turns stay uncluttered while long ones show
        // tokens ticking to prove work is flowing.
        let show_tokens = self.displayed_tokens > 0
            && (elapsed >= 30 || self.verbosity == Verbosity::Verbose);

        // ONE timer, measured from turn start.
        //
        // This used to push a SECOND raw value (phase-elapsed) alongside the turn
        // timer, rendering as "2m31s · 2m35s" — two bare numbers that read as a
        // duplicated or broken clock. Both reference implementations show exactly
        // one elapsed value and express "what it is doing right now" through the
        // VERB instead (Codex swaps the header word: Working / the live reasoning
        // topic / "Waiting for background terminal"; Claude Code uses the todo's
        // activeForm). OSA already varies its verb the same way via
        // `thinking_phrase`, so the phase number was pure redundancy.
        //
        // If a second duration is ever wanted here, it must be a LABELLED PHRASE
        // ("thought for 8s") and transient — never a second bare number, which is
        // precisely what makes it unreadable.
        //
        // `phase_elapsed` is still computed — but it now only drives the VERB
        // (`thinking_phrase`), never a rendered number. That is the whole point:
        // the phase is communicated by the word, the duration by the single timer.
        let phase_elapsed = self
            .phase_since
            .map(|t| t.elapsed().as_secs())
            .unwrap_or(elapsed);
        let turn_timer = fmt_compact_tight(elapsed);

        // Status parts, priority-ordered high→low: `gate_parts` keeps leading and
        // drops trailing as the pane narrows.
        //
        // Elapsed is bound to the interrupt hint in the SAME leading part so the two
        // things the user actually needs — how long it has been going, and how to
        // stop it — are the last to be shed. Codex states the rule directly: "Keep
        // optional context after elapsed/interrupt text so that core interrupt
        // affordances stay in a fixed visual location."
        let mut parts: Vec<String> = vec![format!(
            "{} · {}",
            turn_timer,
            interrupt_affordance(self.interrupt_armed)
        )];

        // Item 1 — live retry countdown (a stall notice), just under the hint.
        if let Some(r) = self.retry.as_ref() {
            let remaining = r
                .resume_at
                .saturating_duration_since(std::time::Instant::now())
                .as_secs();
            if remaining > 0 {
                parts.push(format!("retrying in {}s", remaining));
            }
            if !r.reason.trim().is_empty() {
                parts.push(r.reason.clone());
            }
        }

        // Token counter "⇣12k" (render::glyphs token_arrow + short-number). Highest
        // of the {thinking, timer, tokens} triple so it survives narrowing longest.
        if show_tokens {
            parts.push(format!(
                "{}{}",
                crate::render::glyphs::token_arrow(),
                short_number(self.displayed_tokens)
            ));
        }

        // (The turn timer is already the leading part, bound to the interrupt hint.)

        // Item 4 — input + cache breakdown, so the count reflects the true
        // context-window number, not output-only.
        if self.input_tokens > 0 {
            parts.push(format!("\u{2191} {} in", format_count(self.input_tokens as usize)));
        }
        let cached = self.cache_read_tokens + self.cache_write_tokens;
        if cached > 0 {
            parts.push(format!("\u{26A1} {} cached", format_count(cached as usize)));
        }
        // "thinking" while reasoning deltas stream; "thought for Ns" lingers 2s
        // after the stretch ends. Lowest of the triple → first to width-gate out.
        if self.phase == ProcessingPhase::Thinking {
            // CC-style live thinking segment: the verb escalates with the
            // thinking-phase elapsed ("thinking" → "thinking more" → "thinking
            // harder"), and the current effort tier is appended when known
            // ("thinking with medium effort"). Additive — the "thought for Ns"
            // timer + verb rotation are untouched.
            let phrase = thinking_phrase(phase_elapsed);
            match self.current_effort.as_deref() {
                Some(eff) => parts.push(format!("{} with {} effort", phrase, eff)),
                None => parts.push(phrase.to_string()),
            }
        } else if let Some((secs, at)) = self.thought_for {
            if at.elapsed() < std::time::Duration::from_secs(2) {
                parts.push(format!("thought for {}s", secs));
            }
        }
        // U-T24 — messages queued behind the running turn. Lowest priority.
        if self.queued > 0 {
            parts.push(format!("{} queued", self.queued));
        }

        // ── Spinner glyph + verb selection ──────────────────────────────
        // Priority of what the spinner row telegraphs:
        //   0. cancelling    → red "Cancelling…" (interrupt landing)
        //   1. pending-user  → pulsing ◆ "Waiting for your input" (you're the blocker, item 5)
        //   2. retry/stall   → warning "Retrying (attempt N/M)…" (item 1)
        //   3. waiting-reason→ named "Waiting on subagent…" (item 3)
        //   4. normal        → shimmer spinner + activity-colored verb (green tool /
        //                      gray thinking / working accent), reddened by stall
        // ── Verb budget: the interrupt hint is RESERVED FIRST ───────────────
        //
        // `parts[0]` is `"<turn timer> · esc to interrupt"` — the one control the
        // user needs mid-turn — and it renders to the RIGHT of the verb. A long
        // verb therefore does not merely crowd it, it pushes it past the pane
        // edge where the renderer hard-clips it ("… esc to inte"). During
        // orchestration the verb is `@<agent>: <tool>: <argument>` (
        // `@goal-verifier-skeptic: dir_list: /Users/rhl/.osa/workspace/src`),
        // which is routinely wider than the whole line on its own. `gate_parts`
        // could not save it: it only drops TRAILING optional segments, and index
        // 0 is unconditionally kept — it was kept, and then clipped.
        //
        // So the row is budgeted in priority order: model prefix + spinner glyph
        // (fixed), then the required status part, then the verb takes whatever
        // remains. All measured in COLUMNS (`util::cols`), never chars/bytes.
        let model_cols = if self.model_name.is_empty() {
            0
        } else {
            crate::util::cols(&self.model_name) + 3
        };
        // The status group is wrapped in " (" … ")" — 3 columns of chrome.
        let status_reserve = crate::util::cols(&parts[0]) + 3;
        // 2 columns of spinner glyph + trailing space.
        let verb_budget = (content.width as usize)
            .saturating_sub(model_cols + 2 + status_reserve)
            .max(MIN_VERB_COLS);

        let (glyph_span, verb_spans): (Span<'_>, Vec<Span<'_>>) = if self.cancelling {
            let err = Style::default().fg(theme.colors.error);
            (
                Span::styled(format!("{} ", spinner_char), err),
                vec![Span::styled(
                    "Cancelling\u{2026}".to_string(),
                    err.add_modifier(Modifier::BOLD),
                )],
            )
        } else if self.pending_user {
            // Pulsing ◆ in the accent color — one consistent "your turn" cue.
            let color = if pulse_bright(self.phrase_tick) {
                theme.colors.primary
            } else {
                theme.colors.muted
            };
            (
                Span::styled(
                    "\u{25C6} ".to_string(),
                    Style::default().fg(color).add_modifier(Modifier::BOLD),
                ),
                vec![Span::styled(
                    "Waiting for your input\u{2026}".to_string(),
                    Style::default()
                        .fg(theme.colors.primary)
                        .add_modifier(Modifier::BOLD),
                )],
            )
        } else if let Some(r) = self.retry.as_ref() {
            let warn = Style::default().fg(theme.colors.warning);
            (
                Span::styled(format!("{} ", spinner_char), warn),
                vec![Span::styled(
                    format!("Retrying (attempt {}/{})\u{2026}", r.attempt, r.max_attempts),
                    warn.add_modifier(Modifier::BOLD),
                )],
            )
        } else if self.phase == ProcessingPhase::Waiting && self.waiting_reason.is_some() {
            let label = self.waiting_reason.unwrap().label();
            (
                Span::styled(format!("{} ", spinner_char), theme.spinner_verb()),
                vec![Span::styled(format!("{}\u{2026}", label), theme.spinner_verb())],
            )
        } else {
            // When a task is in progress, show its concrete active step (Claude
            // Code's activeForm). Otherwise ONE flavor verb per turn (CC parity).
            // The verb + glyph are colored by activity (green tool / gray thinking
            // / working accent) and interpolated toward error-red by the stall.
            // Fitted to the budget above so the interrupt hint always survives.
            let word = fit_verb(self.spinner_verb(), verb_budget);
            let base = self.verb_base_color(&theme, stall);
            (
                Span::styled(
                    format!("{} ", spinner_char),
                    Style::default().fg(base).add_modifier(Modifier::BOLD),
                ),
                self.shimmer_verb_spans(&word, base, &theme),
            )
        };

        // U-T27 — drop trailing status segments as the pane narrows. Budget is
        // the width left after the model prefix, spinner glyph (2 cols) and the
        // verb spans, minus the " (" / ")" wrapper. (`model_cols` is computed
        // above, where the verb budget is derived from it.)
        let verb_cols: usize = verb_spans
            .iter()
            .map(|s| crate::util::cols(s.content.as_ref()))
            .sum::<usize>()
            + 2;
        let budget = (content.width as usize).saturating_sub(model_cols + verb_cols + 4);
        let parts = gate_parts(&parts, budget);

        let mut spinner_spans: Vec<Span<'_>> = Vec::with_capacity(verb_spans.len() + 3);
        spinner_spans.push(glyph_span);
        spinner_spans.extend(verb_spans);
        spinner_spans.push(Span::styled(
            format!(" ({})", parts.join(" \u{00b7} ")),
            theme.faint(),
        ));

        // Model name prefix (e.g. "qwen3-coder:480b ∙ ")
        if !self.model_name.is_empty() {
            spinner_spans.insert(
                0,
                Span::styled(format!("{} \u{2219} ", self.model_name), theme.faint()),
            );
        }

        // Iteration indicator (only shown for multi-iteration requests). When the
        // backend supplies the per-turn ceiling, show "iter N/max" and switch to a
        // warning color as the loop approaches the cap so the user sees it coming.
        if self.llm_iteration > 1 {
            let (label, style) = match self.llm_max_iterations {
                Some(max) if max > 0 => {
                    // within the last 20% of the ceiling → warn
                    let near_cap = self.llm_iteration.saturating_mul(5) >= max.saturating_mul(4);
                    let style = if near_cap {
                        Style::default().fg(theme.colors.warning)
                    } else {
                        theme.faint()
                    };
                    (format!(" \u{00b7} iter {}/{}", self.llm_iteration, max), style)
                }
                _ => (format!(" \u{00b7} iter {}", self.llm_iteration), theme.faint()),
            };
            spinner_spans.push(Span::styled(label, style));
        }

        // NOTE: token counts are NOT rendered a second time here. They already
        // appear in the CC-style paren group above ("↓ 1.2k tokens"). A separate
        // "▸ Nin/Nout" span duplicated the count on the same line and read as two
        // token displays — removed for a single, uncluttered status line.

        let spinner_line = Line::from(spinner_spans);
        frame.render_widget(
            Paragraph::new(spinner_line),
            Rect::new(content.x, content.y, content.width, 1),
        );

        // ── `└ ` details block (Codex status_indicator_widget) ───────────
        // The concrete thing behind the verb, wrapped with a hanging indent and
        // ellipsized on the last kept row. Rendered whenever the slot has spare
        // height, ABOVE the tool feed and regardless of verbosity (it is part of
        // the status row, not the feed).
        let mut next_y = content.y + 1;
        if content.height > 1 {
            let room = (content.height - 1) as usize;
            for (i, row) in self
                .wrapped_details_lines(content.width)
                .into_iter()
                .take(room)
                .enumerate()
            {
                // Row i goes at content.y + 1 + i. Derive the rect from `i` alone --
                // advancing `next_y` AND offsetting by `i` double-counts, which skips
                // every other row and walks off the end of the frame buffer.
                let y = content.y + 1 + i as u16;
                frame.render_widget(
                    Paragraph::new(Line::from(Span::styled(row, theme.faint()))),
                    Rect::new(content.x, y, content.width, 1),
                );
                next_y = y + 1;
            }
        }

        if self.verbosity == Verbosity::Off || next_y >= content.y + content.height {
            return;
        }

        // Live command output claims the BOTTOM rows of the remaining budget.
        //
        // It deliberately does NOT add rows: `height()`/`max_height()` reserve a
        // fixed slot for the whole turn, and growing that slot mid-turn rebuilds
        // the inline viewport (a DSR cursor re-anchor that stacks a fresh
        // composer down the screen — see `max_height`'s note). So the live tail
        // SHARES the feed budget rather than extending it.
        let budget = (content.y + content.height - next_y) as usize;
        let live_lines = if self.verbosity == Verbosity::New {
            // "New" mode is a single summary row — no room for a tail.
            Vec::new()
        } else {
            let mut lines = self.live_output_lines();
            // Never let the tail swallow the feed: keep one row for the running
            // tool itself when there is one.
            let cap = budget.saturating_sub(usize::from(!self.tool_feed.is_empty()));
            if lines.len() > cap {
                lines.drain(..lines.len() - cap);
            }
            lines
        };

        // Tool feed lines (Hermes-style: ┊ emoji verb  detail  duration)
        let max_lines = budget - live_lines.len();
        let feed_start = if self.tool_feed.len() > max_lines {
            self.tool_feed.len() - max_lines
        } else {
            0
        };

        for (i, entry) in self.tool_feed[feed_start..].iter().enumerate() {
            if i >= max_lines {
                break;
            }
            let y = next_y + i as u16;
            if y >= content.y + content.height {
                break;
            }

            // `{:<10}` alone produced `delegatingname, role`: the verb "delegating"
            // is exactly 10 chars, so the pad emitted NOTHING and the detail was
            // glued straight onto it. The trailing space is unconditional so every
            // verb — short or exactly-at-the-pad — is separated from its detail.
            // WEIGHT ENCODES STATE, not category.
            //
            // Every feed row painted its verb in the same bold accent, so four
            // finished calls shouted exactly as loudly as the one still running —
            // and the feed as a whole shouted as loudly as the spinner verb
            // directly above it. Colour is rationed to state (all three reference
            // TUIs converge on this): the RUNNING call keeps the accent, finished
            // ones recede to the meta tier, and their outcome is already carried
            // by the duration span's colour at the end of the row.
            //
            // The gutter is chrome and therefore always the quietest tier.
            let running = entry.duration_ms.is_none();
            let verb_style = if running {
                theme.prefix_active()
            } else {
                theme.faint()
            };
            let mut spans: Vec<Span<'_>> = vec![
                Span::styled("\u{2506} ", theme.recede()),
                Span::raw(format!("{} ", entry.emoji)),
                Span::styled(format!("{:<10} ", entry.verb), verb_style),
            ];

            if !entry.detail.is_empty() && self.verbosity != Verbosity::New {
                spans.push(Span::styled(&entry.detail, theme.faint()));
                spans.push(Span::raw("  "));
            }

            // Concurrency multiplier for folded identical calls (`×2`), so two
            // workers read as two workers instead of one duplicated line.
            if entry.concurrent > 1 {
                spans.push(Span::styled(
                    format!("\u{00d7}{}  ", entry.concurrent),
                    theme.faint(),
                ));
            }

            // Duration / status.
            //
            // ONE clock per surface: a RUNNING sub-agent tool gets no duration
            // here at all. Its age is already on that worker's fleet-roster row,
            // and the turn clock is on the status line above — printing it a third
            // time on the delegate line is what put four live timers on screen.
            // Completed calls still report their duration (the roster row is gone
            // by then, and the number is now a fact, not a competing clock).
            let suppress_running_timer = is_agent_tool(&entry.name);
            match (entry.duration_ms, entry.success) {
                (Some(ms), Some(true)) => {
                    spans.push(Span::styled(fmt_tool_duration(ms), theme.task_done()));
                }
                (Some(ms), Some(false)) => {
                    spans.push(Span::styled(
                        format!("{} [error]", fmt_tool_duration(ms)),
                        theme.error_text(),
                    ));
                }
                // Duration known but the outcome is not: report the fact we have
                // and stay silent about the one we don't, rather than falling
                // through to the running branch and restarting a dead clock.
                (Some(ms), None) => {
                    spans.push(Span::styled(fmt_tool_duration(ms), theme.faint()));
                }
                _ if suppress_running_timer => {}
                _ => {
                    // Still running — a live, still-growing measurement.
                    let running_ms = entry.start.elapsed().as_millis() as u64;
                    spans.push(Span::styled(
                        format!("{}...", fmt_tool_duration(running_ms)),
                        theme.faint(),
                    ));
                }
            }

            let line = Line::from(spans);
            frame.render_widget(
                Paragraph::new(line),
                Rect::new(content.x, y, content.width, 1),
            );
        }

        // ── Live command output tail ─────────────────────────────────────
        // Rendered under the feed, faint and dim, so the eye reads it as the
        // machine's voice rather than OSA's. Each row is clipped to the pane
        // width (never wrapped) so one long line can never displace the rows
        // below it.
        let live_y0 = next_y + max_lines.min(self.tool_feed.len().saturating_sub(feed_start)) as u16;
        for (i, text) in live_lines.iter().enumerate() {
            let y = live_y0 + i as u16;
            if y >= content.y + content.height {
                break;
            }
            let avail = content.width.saturating_sub(2) as usize;
            let body = sanitize_live_line(text, avail);
            let line = Line::from(vec![
                // Gutter is chrome: quietest tier, same as the feed above it, so
                // the two blocks read as one column rather than two.
                Span::styled("\u{2506} ", theme.recede()),
                Span::styled(body, theme.faint()),
            ]);
            frame.render_widget(
                Paragraph::new(line),
                Rect::new(content.x, y, content.width, 1),
            );
        }
    }
}

/// Make one line of raw command output safe to paint on a single row: strip
/// control characters (a stray `\r`/`\t`/ANSI escape would corrupt the cursor
/// position of the whole live region) and clip to `max_cols` display columns.
fn sanitize_live_line(s: &str, max_cols: usize) -> String {
    if max_cols == 0 {
        return String::new();
    }
    let mut out = String::new();
    let mut acc = 0usize;
    let mut i = 0usize;
    while i < s.len() {
        // Drop escape sequences wholesale rather than rendering their payload as
        // literal text.
        //
        // This used to break on the first ASCII alphabetic, which is right for
        // CSI but WRONG for OSC: an OSC string runs to BEL or ST, so
        // `ESC ]8;;http://x ESC \` stopped at the `h` of `http`, leaked
        // `ttp://x` onto the row as visible text, and then the trailing `ESC \`
        // opened a fresh "escape" that ate the real output after it.
        // `escape_len_at` knows each introducer's real terminator.
        if let Some(len) = crate::util::escape_len_at(s, i) {
            i += len;
            continue;
        }
        let ch = s[i..].chars().next().expect("at a char boundary");
        i += ch.len_utf8();
        let ch = if ch == '\t' { ' ' } else { ch };
        if ch.is_control() {
            continue;
        }
        let cw = unicode_width::UnicodeWidthChar::width(ch).unwrap_or(0);
        if acc + cw > max_cols {
            break;
        }
        out.push(ch);
        acc += cw;
    }
    out
}

#[cfg(test)]
mod activity_tests {
    use super::*;

    #[test]
    fn tool_start_multibyte_args_never_panic() {
        // Args whose byte 57 lands inside a multi-byte char (the old &args[..57]
        // slice would panic). Leading 'a' shifts the 3-byte '€' run off byte 57.
        let mb = format!("a{}", "\u{20ac}".repeat(40));
        let mut act = Activity::new();
        act.tool_start("Bash", &mb);
        act.tool_start("Read", "short ascii");
        act.tool_start("Web", &"\u{1f600}".repeat(30)); // 4-byte emoji run
        assert!(!act.tool_feed.is_empty());
    }

    // ── effects that must survive the tool-feed deletion ───────────────────
    //
    // `tool_start` / `tool_end_with_id` do three things besides pushing a feed
    // row, and those three have readers OUTSIDE the band — which is exactly
    // where a silent regression hides when the row-pushing is removed. These
    // pin the effects to behaviour rather than to the diff.

    #[test]
    fn a_starting_tool_keeps_the_stall_clock_alive() {
        // `last_output_at` drives the stall intensity: seconds since output
        // last flowed, bleeding the whole status row red when a turn freezes.
        // A tool starting IS output flowing. If the row-push removal takes this
        // with it, a healthy turn full of tool calls reddens as though hung —
        // green on every unit test, wrong on screen.
        let mut act = Activity::new();
        act.start();
        // `start()` arms the clock, so clear it to observe tool_start alone.
        act.last_output_at = None;

        act.tool_start("Read", r#"{"path":"/a.rs"}"#);
        let marked = act.last_output_at.expect("tool_start must mark output");
        assert!(
            marked.elapsed().as_secs() < 1,
            "the stall clock must be fresh, not stale"
        );
    }

    #[test]
    fn a_finishing_tool_keeps_the_stall_clock_alive() {
        let mut act = Activity::new();
        act.start();
        act.tool_start("Read", r#"{"path":"/a.rs"}"#);
        act.last_output_at = None;

        act.tool_end_with_id("Read", 12, true, None);
        assert!(
            act.last_output_at.is_some(),
            "tool_end must mark output, or a run of fast tools reads as a stall"
        );
    }

    #[test]
    fn a_fresh_turn_arms_the_stall_clock() {
        // `start()` arms the clock rather than clearing it, and that is
        // deliberate: a turn that produces nothing for thirty seconds IS a
        // stall, and an unset clock reports 0.0 intensity forever.
        let mut act = Activity::new();
        act.start();
        let armed = act.last_output_at.expect("start() must arm the stall clock");
        assert!(armed.elapsed().as_secs() < 1);
    }

    #[test]
    fn concurrent_identical_calls_still_mark_output() {
        // The concurrent-identical fold returns EARLY from tool_start, before
        // the push. The stall-clock update lives on that early path too, and
        // has to stay there when the push around it goes away.
        let mut act = Activity::new();
        act.start();
        act.tool_start("delegate", r#"{"task":"a"}"#);
        act.last_output_at = None;
        act.tool_start("delegate", r#"{"task":"a"}"#);
        assert!(
            act.last_output_at.is_some(),
            "the folded-call early return must still mark output"
        );
    }

    #[test]
    fn thinking_stretch_is_tracked_across_phases() {
        let mut act = Activity::new();
        act.start();
        act.set_phase(ProcessingPhase::Thinking);
        assert!(act.thinking_since.is_some());
        assert!(act.thought_for.is_none());
        act.set_phase(ProcessingPhase::Streaming);
        assert!(act.thinking_since.is_none());
        let (secs, _) = act.thought_for.expect("thought_for captured on leave");
        assert!(secs >= 1, "sub-second stretches clamp to 1s (CC parity)");
        // Legacy set_thinking path routes through set_phase tracking too.
        act.set_thinking(true);
        assert!(act.thinking_since.is_some());
        // A new turn clears both.
        act.start();
        assert!(act.thinking_since.is_none() && act.thought_for.is_none());
    }

    #[test]
    fn thinking_phrase_escalates_with_elapsed() {
        // CC parity: the live thinking verb intensifies as the stretch grows.
        assert_eq!(thinking_phrase(0), "thinking");
        assert_eq!(thinking_phrase(7), "thinking");
        assert_eq!(thinking_phrase(8), "thinking more");
        assert_eq!(thinking_phrase(19), "thinking more");
        assert_eq!(thinking_phrase(20), "thinking harder");
        assert_eq!(thinking_phrase(600), "thinking harder");
    }

    #[test]
    fn thinking_segment_appends_effort_when_known() {
        // The live thinking segment reads "thinking with <effort> effort" once an
        // effort tier is synced; "off"/blank tiers are suppressed (no suffix).
        let mut act = Activity::new();
        act.start();
        act.set_phase(ProcessingPhase::Thinking);
        act.set_current_effort(Some("medium".into()));
        let text = render_activity_text(&act);
        assert!(text.contains("thinking"), "thinking segment present: {text:?}");
        assert!(text.contains("with medium effort"), "effort suffix present: {text:?}");

        // "off" / blank must not render an effort suffix.
        act.set_current_effort(Some("off".into()));
        assert_eq!(act.current_effort, None, "'off' effort is suppressed");
        act.set_current_effort(Some("   ".into()));
        assert_eq!(act.current_effort, None, "blank effort is suppressed");
    }

    #[test]
    fn spinner_verb_is_stable_for_a_turn() {
        let mut act = Activity::new();
        act.start();
        let v1 = act.spinner_verb().to_string();
        act.tick();
        act.tick();
        // One verb per turn — ticks/time never rotate it.
        assert_eq!(act.spinner_verb(), v1);
        // A concrete task step (activeForm) still overrides the flavor verb.
        act.set_active_verb(Some("Wiring the checklist".into()));
        assert_eq!(act.spinner_verb(), "Wiring the checklist");
        act.set_active_verb(None);
        assert_eq!(act.spinner_verb(), v1);
    }

    /// Render the active spinner row for `act` and flatten its cells to a single
    /// string (parity with status_bar's buffer-content harness).
    fn render_activity_text(act: &Activity) -> String {
        use ratatui::{backend::TestBackend, Terminal};
        let mut term = Terminal::new(TestBackend::new(120, 1)).unwrap();
        term.draw(|f| act.draw(f, f.area())).unwrap();
        term.backend()
            .buffer()
            .content()
            .iter()
            .map(|c| c.symbol())
            .collect()
    }

    #[test]
    fn retry_label_renders_from_provider_retry() {
        // Item 1 — a held RetryState makes the spinner label become the retry
        // notice (with a live countdown), not a flavor verb.
        let mut act = Activity::new();
        act.start();
        assert!(!act.is_retrying());
        act.set_retry(Some(RetryState {
            attempt: 2,
            max_attempts: 5,
            reason: "rate limited".to_string(),
            resume_at: std::time::Instant::now() + std::time::Duration::from_secs(8),
        }));
        assert!(act.is_retrying());
        let text = render_activity_text(&act);
        assert!(
            text.contains("Retrying (attempt 2/5)"),
            "retry verb must render, got: {text:?}"
        );
        assert!(text.contains("retrying in"), "countdown part must render");
        assert!(text.contains("rate limited"), "reason must render");

        // Resuming the turn (a usage report / streamed tokens) clears it.
        act.set_tokens(10, 20);
        assert!(!act.is_retrying(), "retry clears on token report");
        // Streaming chars also clear it.
        act.set_retry(Some(RetryState {
            attempt: 1,
            max_attempts: 3,
            reason: String::new(),
            resume_at: std::time::Instant::now(),
        }));
        act.add_stream_chars(4);
        assert!(!act.is_retrying(), "retry clears on stream resume");
    }

    #[test]
    fn shimmer_index_advances_and_wraps() {
        // Item 2 — the glimmer highlight moves with the tick and wraps within
        // the verb+tail span (deterministic, so the sweep is verifiable).
        let len = 6usize;
        let span = len + 3;
        let p0 = shimmer_index(0, len);
        let p1 = shimmer_index(1, len);
        let p2 = shimmer_index(2, len);
        assert_eq!(p0, 0);
        assert_eq!(p1, 1);
        assert_eq!(p2, 2);
        assert_ne!(p0, p1, "shimmer index must advance with tick");
        // Wraps at the span boundary.
        assert_eq!(shimmer_index(span as u32, len), 0);
        // Empty verb is safe.
        assert_eq!(shimmer_index(5, 0), 0);
        // Reduced-motion renders a flat verb (single styled span, no per-char).
        let act = {
            let mut a = Activity::new();
            a.start();
            a.set_reduced_motion(true);
            a
        };
        let theme = crate::style::theme();
        let base = Color::Rgb(147, 165, 255);
        assert_eq!(
            act.shimmer_verb_spans("Working", base, &theme).len(),
            1,
            "reduced-motion verb is one flat span"
        );
        // Animated verb is per-char (+1 for the trailing ellipsis span).
        let mut anim = Activity::new();
        anim.start();
        assert_eq!(
            anim.shimmer_verb_spans("Working", base, &theme).len(),
            "Working".chars().count() + 1
        );
    }

    #[test]
    fn waiting_reason_label_maps() {
        // Item 3 — every reason maps to a distinct, human label.
        assert_eq!(WaitingReason::Model.label(), "Waiting for response");
        assert_eq!(WaitingReason::Subagent.label(), "Waiting on subagent");
        assert_eq!(WaitingReason::TaskOutput.label(), "Waiting on task output");
        assert_eq!(WaitingReason::Tasks.label(), "Waiting on tasks");
        assert_eq!(WaitingReason::Sleeping.label(), "Sleeping");
        assert_eq!(WaitingReason::Compacting.label(), "Compacting");
        assert_eq!(WaitingReason::Verifying.label(), "Verifying");

        // When set during the Waiting phase, the reason replaces the flavor verb.
        let mut act = Activity::new();
        act.start();
        act.set_phase(ProcessingPhase::Waiting);
        act.set_waiting_reason(Some(WaitingReason::Subagent));
        let text = render_activity_text(&act);
        assert!(
            text.contains("Waiting on subagent"),
            "waiting reason must render on the spinner, got: {text:?}"
        );
        // Leaving Waiting clears the reason (turn resumed).
        act.set_phase(ProcessingPhase::Streaming);
        assert!(!render_activity_text(&act).contains("Waiting on subagent"));
    }

    #[test]
    fn token_sum_includes_input_and_cache() {
        // Item 4 — the true total sums input + output + reasoning + cache r/w,
        // not output-only, and the input/cache figures surface on the row.
        let mut act = Activity::new();
        act.start();
        act.set_tokens_detailed(1000, 200, 50, 4000, 100);
        // total = input(1000) + turn_output(200) + reasoning(50)
        //         + cache_read(4000) + cache_write(100) = 5350
        assert_eq!(act.total_tokens(), 5350);
        assert!(
            act.total_tokens() > act.turn_output_tokens,
            "true total must exceed output-only"
        );
        let text = render_activity_text(&act);
        assert!(text.contains("in"), "input tokens must surface, got: {text:?}");
        assert!(text.contains("cached"), "cache tokens must surface");
    }

    #[test]
    fn interrupt_affordance_arms_and_renders() {
        // U-T22 — the affordance text flips on arm, and the spinner shows it.
        assert_eq!(interrupt_affordance(false), "esc to interrupt");
        assert_eq!(interrupt_affordance(true), "esc again to interrupt");

        let mut act = Activity::new();
        act.start();
        assert!(!act.is_interrupt_armed());
        assert!(render_activity_text(&act).contains("esc to interrupt"));
        act.arm_interrupt(true);
        assert!(act.is_interrupt_armed());
        let text = render_activity_text(&act);
        assert!(
            text.contains("esc again to interrupt"),
            "armed affordance must render, got: {text:?}"
        );
        // A fresh turn disarms it.
        act.start();
        assert!(!act.is_interrupt_armed());
    }

    #[test]
    fn queued_hint_renders_and_gates_out_first() {
        // U-T24 — the queued segment surfaces on the spinner.
        let mut act = Activity::new();
        act.start();
        assert!(!render_activity_text(&act).contains("queued"));
        act.set_queued(3);
        let text = render_activity_text(&act);
        assert!(text.contains("3 queued"), "queued hint must render, got: {text:?}");

        // U-T27 — width-gating keeps leading (priority) segments, drops trailing
        // ones (queued is last), and always keeps at least the first segment.
        let parts: Vec<String> = ["esc to interrupt", "12s", "\u{2193} 1.2k tokens", "3 queued"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        // Ample budget keeps everything.
        assert_eq!(gate_parts(&parts, 200).len(), 4);
        // Tight budget keeps only the first, never an empty group.
        let tight = gate_parts(&parts, 3);
        assert_eq!(tight.len(), 1);
        assert_eq!(tight[0], "esc to interrupt");
        // A middling budget drops the trailing "3 queued" before the tokens.
        let mid = gate_parts(&parts, "esc to interrupt".len() + 3 + "12s".len());
        assert!(mid.contains(&"12s".to_string()));
        assert!(!mid.contains(&"3 queued".to_string()));
        // Empty input never panics.
        assert!(gate_parts(&[], 40).is_empty());
    }

    #[test]
    fn pending_user_pulse_toggles() {
        // Item 5 — the pulse alternates bright/dim over ticks, and the flag
        // swaps the spinner to the ◆ "your turn" cue.
        assert!(pulse_bright(0));
        assert!(pulse_bright(2));
        assert!(!pulse_bright(3));
        assert!(!pulse_bright(5));
        assert!(pulse_bright(6));
        // The bright phase must actually alternate across a sweep of ticks.
        let phases: Vec<bool> = (0..12).map(pulse_bright).collect();
        assert!(phases.iter().any(|&b| b) && phases.iter().any(|&b| !b));

        let mut act = Activity::new();
        act.start();
        assert!(!act.pending_user());
        act.set_pending_user(true);
        assert!(act.pending_user());
        let text = render_activity_text(&act);
        assert!(
            text.contains('\u{25C6}'),
            "pending-user renders the pulsing ◆, got: {text:?}"
        );
        assert!(text.contains("Waiting for your input"));
        // A resuming phase clears the pending cue.
        act.set_phase(ProcessingPhase::ToolCall);
        assert!(!act.pending_user());
    }

    #[test]
    fn progress_bar_is_measured_not_decorative() {
        // Every cell is earned: the fill is a floor of the real ratio, so the bar
        // can never read fuller than the work actually completed.
        let half = progress_bar(5, 10);
        assert_eq!(half.matches('\u{25B0}').count(), 10);
        assert_eq!(half.matches('\u{25B1}').count(), 10);
        assert!(half.contains("50%"), "{}", half);
        assert!(half.contains("chunk 5/10"), "{}", half);

        // Nothing done → nothing filled. No "starter" cell to look busy with.
        let none = progress_bar(0, 8);
        assert_eq!(none.matches('\u{25B0}').count(), 0);
        assert!(none.contains("0%"), "{}", none);

        // Only the genuinely-final chunk produces a full bar at 100%.
        let all = progress_bar(8, 8);
        assert_eq!(all.matches('\u{25B0}').count(), PROGRESS_BAR_CELLS);
        assert!(all.contains("100%"), "{}", all);

        // 7/8 must NOT round up to a full bar — that would announce completion
        // one whole LLM call early.
        let nearly = progress_bar(7, 8);
        assert!(nearly.matches('\u{25B0}').count() < PROGRESS_BAR_CELLS, "{}", nearly);
        assert!(!nearly.contains("100%"), "{}", nearly);
    }

    #[test]
    fn progress_bar_refuses_to_invent_a_ratio() {
        // No known total ⇒ no bar at all. The caller renders spinner + elapsed
        // only. This is the guard that keeps a non-chunking compaction (the
        // `/compact` single-summarizer path) from growing a fake bar.
        assert_eq!(progress_bar(3, 0), "");

        // Filled vs empty differ by GLYPH, not colour, so the bar survives a
        // monochrome terminal and colour-blind readers.
        let bar = progress_bar(1, 4);
        assert!(bar.contains('\u{25B0}') && bar.contains('\u{25B1}'), "{}", bar);
    }

    #[test]
    fn compacting_names_the_wait_on_the_spinner_row() {
        // The spinner must say what is blocking the turn. A flavour verb here
        // would imply the model is thinking when it is actually folding history.
        assert_eq!(WaitingReason::Compacting.label(), "Compacting");
    }

    #[test]
    fn fmt_compact_tight_is_spaceless() {
        // grok turn_status "1m20s" style — no spaces, zero-padded lower units.
        assert_eq!(fmt_compact_tight(5), "5s");
        assert_eq!(fmt_compact_tight(59), "59s");
        assert_eq!(fmt_compact_tight(80), "1m20s");
        assert_eq!(fmt_compact_tight(3600), "1h00m00s");
        assert_eq!(fmt_compact_tight(3922), "1h05m22s");
    }

    #[test]
    fn short_number_is_terse() {
        assert_eq!(short_number(0), "0");
        assert_eq!(short_number(999), "999");
        assert_eq!(short_number(1500), "1.5k");
        assert_eq!(short_number(12_000), "12k");
        assert_eq!(short_number(12_400), "12k");
    }

    #[test]
    fn token_counter_eases_toward_target_without_overshoot() {
        // The eased counter always moves TOWARD the target and never past it, and
        // it converges. This is the CC token-easing invariant.
        let target = 4_000u64;
        let mut displayed = 0u64;
        let mut prev = 0u64;
        for _ in 0..1_000 {
            displayed = ease_tokens(displayed, target);
            assert!(displayed <= target, "must never overshoot the target");
            assert!(displayed >= prev, "must be monotonic toward the target");
            prev = displayed;
        }
        assert_eq!(displayed, target, "must converge exactly to the target");

        // Small gap steps by at least +3 (visible tick) but never past target.
        assert_eq!(ease_tokens(0, 5), 3);
        assert_eq!(ease_tokens(0, 2), 2); // gap smaller than the min step → land on target
        // Large gap is capped at +50 so a big jump animates instead of snapping.
        assert_eq!(ease_tokens(0, 100_000), 50);
        // At/over the target it holds (tokens are monotonic; never counts down).
        assert_eq!(ease_tokens(500, 500), 500);
        assert_eq!(ease_tokens(600, 500), 600);
    }

    #[test]
    fn token_counter_easing_advances_on_tick() {
        // A usage report sets a big target; each tick eases the on-screen value up
        // without ever exceeding it.
        let mut act = Activity::new();
        act.start();
        act.set_tokens(0, 900); // turn_output_tokens = 900
        assert_eq!(act.displayed_tokens, 0, "starts at zero before any tick");
        act.tick();
        assert!(act.displayed_tokens > 0, "tick eases the counter up");
        assert!(act.displayed_tokens <= 900, "never past the real value");
        for _ in 0..1_000 {
            act.tick();
        }
        assert_eq!(act.displayed_tokens, 900, "converges to the real value");
    }

    #[test]
    fn stall_flips_color_after_threshold() {
        // Below the ~3s threshold there is no red bleed; past it the intensity
        // ramps up, so a base color interpolates toward error-red.
        assert_eq!(stall_t(0.0), 0.0);
        assert_eq!(stall_t(2.9), 0.0);
        assert_eq!(stall_t(3.0), 0.0, "exactly at the threshold is still calm");
        assert!(stall_t(4.5) > 0.0 && stall_t(4.5) < 1.0, "ramps in the band");
        assert_eq!(stall_t(6.0), 1.0, "fully red a few seconds past threshold");
        assert_eq!(stall_t(100.0), 1.0, "saturates, never exceeds 1");

        // The interpolation actually moves the color: calm keeps the base, a full
        // stall lands on error-red.
        let base = Color::Rgb(147, 165, 255);
        let red = Color::Rgb(255, 0, 0);
        assert_eq!(crate::style::gradient::lerp_color(base, red, stall_t(0.0)), base);
        assert_ne!(crate::style::gradient::lerp_color(base, red, stall_t(5.0)), base);
        assert_eq!(crate::style::gradient::lerp_color(base, red, stall_t(6.0)), red);
    }

    #[test]
    fn cancelling_renders_red_label() {
        // set_cancelling flips the spinner label to the red "Cancelling…" cue and
        // start()/stop() clear it.
        let mut act = Activity::new();
        act.start();
        assert!(!act.is_cancelling());
        act.set_cancelling(true);
        assert!(act.is_cancelling());
        let text = render_activity_text(&act);
        assert!(
            text.contains("Cancelling"),
            "cancelling label must render, got: {text:?}"
        );
        act.start();
        assert!(!act.is_cancelling(), "a fresh turn clears cancelling");
    }

    #[test]
    fn token_counter_gated_until_thirty_seconds_unless_verbose() {
        // The eased counter is hidden on short turns (no 30s elapsed) but shows
        // immediately under verbose, matching CC's gate.
        let mut act = Activity::new();
        act.start();
        act.set_tokens(0, 4_000);
        for _ in 0..1_000 {
            act.tick();
        }
        // Fresh turn (elapsed ~0s), default verbosity → the token counter (4.0k)
        // is gated out. Check the numeric text (glyph-level independent).
        assert!(
            !render_activity_text(&act).contains("4.0k"),
            "token counter is hidden before ~30s at default verbosity"
        );
        // Verbose surfaces it right away.
        act.verbosity = Verbosity::Verbose;
        assert!(
            render_activity_text(&act).contains("4.0k"),
            "verbose shows the token counter immediately"
        );
    }

    #[test]
    fn rail_present_while_active_absent_when_idle() {
        // The left accent rail is painted only while a turn is active; an idle
        // Activity draws nothing (no distracting rail when nothing is happening).
        let rail = crate::render::glyphs::heavy_rail();
        let mut act = Activity::new();
        assert!(
            !render_activity_text(&act).contains(rail),
            "no rail when idle"
        );
        act.start();
        assert!(
            render_activity_text(&act).contains(rail),
            "rail must show while active, glyph {rail:?}"
        );
    }

    #[test]
    fn rail_accent_and_freeze_map_states() {
        // grok state→color map + frozen-vs-wave selection.
        let theme = crate::style::theme();
        let mut act = Activity::new();
        act.start();
        // Working (default) → success green, animated wave.
        assert_eq!(act.rail_accent(&theme), theme.colors.success);
        assert!(!act.rail_frozen());
        // Retrying → warning yellow, still a wave.
        act.set_retry(Some(RetryState {
            attempt: 1,
            max_attempts: 3,
            reason: String::new(),
            resume_at: std::time::Instant::now(),
        }));
        assert_eq!(act.rail_accent(&theme), theme.colors.warning);
        assert!(!act.rail_frozen());
        act.set_retry(None);
        // Pending-on-user → primary accent, frozen to solid full color.
        act.set_pending_user(true);
        assert_eq!(act.rail_accent(&theme), theme.colors.primary);
        assert!(act.rail_frozen());
        act.set_pending_user(false);
        // Cancelling → error red, frozen (takes precedence over the rest).
        act.set_cancelling(true);
        assert_eq!(act.rail_accent(&theme), theme.colors.error);
        assert!(act.rail_frozen());
        act.set_cancelling(false);
        // Reduced-motion freezes the wave to a static rail even while working.
        act.set_reduced_motion(true);
        assert_eq!(act.rail_accent(&theme), theme.colors.success);
        assert!(act.rail_frozen(), "reduced-motion paints a static full rail");
    }

    #[test]
    fn elapsed_does_not_advance_while_paused() {
        // Codex parity: the reported duration is AGENT time. A modal owning the
        // screen pauses the clock, so the seconds the human spent reading an
        // approval prompt are never billed to the turn.
        use std::time::{Duration, Instant};
        let mut act = Activity::new();
        act.start();
        let base = Instant::now();
        act.last_resume_at = Some(base);
        act.elapsed_running = Duration::ZERO;

        assert_eq!(act.elapsed_secs_at(base + Duration::from_secs(5)), 5);

        // Pause at t=5: the clock freezes at 5s no matter how long the modal sits.
        act.pause_timer_at(base + Duration::from_secs(5));
        assert!(act.is_timer_paused());
        assert_eq!(act.elapsed_secs_at(base + Duration::from_secs(10)), 5);
        assert_eq!(act.elapsed_secs_at(base + Duration::from_secs(300)), 5);

        // A second pause must not double-bank the stretch.
        act.pause_timer_at(base + Duration::from_secs(300));
        assert_eq!(act.elapsed_secs_at(base + Duration::from_secs(300)), 5);

        // Resume at t=300: only agent time accrues again.
        act.resume_timer_at(base + Duration::from_secs(300));
        assert!(!act.is_timer_paused());
        assert_eq!(act.elapsed_secs_at(base + Duration::from_secs(303)), 8);
        // Redundant resume is a no-op (does not restart the stretch).
        act.resume_timer_at(base + Duration::from_secs(303));
        assert_eq!(act.elapsed_secs_at(base + Duration::from_secs(303)), 8);

        // A fresh turn resets the accumulator and unpauses.
        act.pause_timer();
        act.start();
        assert!(!act.is_timer_paused());
        assert_eq!(act.elapsed_running, Duration::ZERO);
        assert!(act.elapsed_secs().is_some_and(|s| s < 2));
        // Idle activity has no clock at all.
        act.stop();
        assert_eq!(act.elapsed_secs(), None);
    }

    #[test]
    fn details_wrap_with_hanging_indent_and_ellipsize() {
        let mut act = Activity::new();
        act.start();
        assert!(act.details().is_none());
        assert_eq!(act.wrapped_details_lines(40).len(), 0, "no details ⇒ no rows");

        // Blank text clears rather than reserving an empty row.
        act.set_details(Some("   ".into()), ACTIVITY_DETAILS_DEFAULT_MAX_LINES);
        assert!(act.details().is_none());

        // Fits on one row: just the prefix, no wrapping, no ellipsis.
        act.set_details(Some("cargo test".into()), ACTIVITY_DETAILS_DEFAULT_MAX_LINES);
        let rows = act.wrapped_details_lines(40);
        assert_eq!(rows, vec!["  \u{2514} cargo test".to_string()]);

        // Wraps with a hanging indent aligned under the `└ ` prefix (4 cols).
        act.set_details(
            Some("A man a plan a canal panama".into()),
            ACTIVITY_DETAILS_DEFAULT_MAX_LINES,
        );
        let rows = act.wrapped_details_lines(30);
        assert_eq!(rows.len(), 2, "one wrap at width 30, got {rows:?}");
        assert!(rows[0].starts_with("  \u{2514} "));
        assert!(rows[1].starts_with("    "), "continuation is indented: {rows:?}");
        assert!(!rows[1].starts_with("  \u{2514}"), "prefix only on the first row");
        for r in &rows {
            assert!(crate::util::cols(r) <= 30, "row overflows width: {r:?}");
        }

        // Narrow width: truncated to max_lines with `…` on the last kept row.
        act.set_details(
            Some("abcd abcd abcd abcd".into()),
            ACTIVITY_DETAILS_DEFAULT_MAX_LINES,
        );
        let rows = act.wrapped_details_lines(10);
        assert_eq!(rows.len(), ACTIVITY_DETAILS_DEFAULT_MAX_LINES);
        assert!(
            rows.last().unwrap().ends_with('\u{2026}'),
            "overflowing details ellipsize the last row: {rows:?}"
        );
        for r in &rows {
            assert!(crate::util::cols(r) <= 10, "row overflows width: {r:?}");
        }

        // max_lines = 1 collapses the whole block onto one ellipsized row.
        act.set_details(Some("abcd abcd abcd abcd".into()), 1);
        let rows = act.wrapped_details_lines(12);
        assert_eq!(rows.len(), 1);
        assert!(rows[0].starts_with("  \u{2514} ") && rows[0].ends_with('\u{2026}'));
        // max_lines is clamped to at least one row.
        act.set_details(Some("x".into()), 0);
        assert_eq!(act.wrapped_details_lines(20).len(), 1);

        // Degenerate widths never panic and never emit a prefix-only row.
        for w in [0u16, 1, 3, 4, 5] {
            let rows = act.wrapped_details_lines(w);
            assert!(rows.iter().all(|r| crate::util::cols(r) <= w as usize));
        }
    }

    #[test]
    fn details_rows_are_reserved_and_drawn_together() {
        // The slot invariant with a details block: whatever `height()` claims
        // must equal `max_height()` once the feed is saturated, in every mode.
        for verbosity in [
            Verbosity::Off,
            Verbosity::New,
            Verbosity::All,
            Verbosity::Verbose,
        ] {
            let mut act = Activity::new();
            act.start();
            act.verbosity = verbosity;
            for i in 0..20 {
                act.tool_start(&format!("tool{i}"), "{}");
            }
            let bare = act.height();
            act.set_details(
                Some("a fairly long details string that wraps a few times over".into()),
                ACTIVITY_DETAILS_DEFAULT_MAX_LINES,
            );
            // Before any draw the width is unknown ⇒ reserve the ceiling.
            assert_eq!(act.height(), bare + ACTIVITY_DETAILS_DEFAULT_MAX_LINES as u16);
            assert!(act.height() <= act.max_height());
            assert_eq!(act.height(), act.max_height());

            // After a draw the reservation tightens to the rows actually painted.
            let text = render_activity_text_sized(&act, 120, act.height());
            assert!(text.contains('\u{2514}'), "details row must render: {text:?}");
            assert_eq!(act.details_rows(), 1, "wide pane ⇒ a single details row");
            assert_eq!(act.height(), bare + 1);
            assert_eq!(act.height(), act.max_height());

            // a11y (plain-text) mode stays one flat line regardless of details.
            act.set_a11y(true);
            assert_eq!(act.height(), 1);
            assert_eq!(act.max_height(), 1);
        }
    }

    /// Like `render_activity_text` but with an explicit viewport size.
    fn render_activity_text_sized(act: &Activity, w: u16, h: u16) -> String {
        use ratatui::{backend::TestBackend, Terminal};
        let mut term = Terminal::new(TestBackend::new(w, h.max(1))).unwrap();
        term.draw(|f| act.draw(f, f.area())).unwrap();
        term.backend()
            .buffer()
            .content()
            .iter()
            .map(|c| c.symbol())
            .collect()
    }

    #[test]
    fn rail_never_panics_at_tiny_sizes() {
        // Height 0/1 and widths too narrow for the gutter must not panic.
        use ratatui::{backend::TestBackend, Terminal};
        let mut act = Activity::new();
        act.start();
        for (w, h) in [(120u16, 0u16), (120, 1), (120, 3), (4, 2), (1, 1)] {
            let mut term = Terminal::new(TestBackend::new(w.max(1), h.max(1))).unwrap();
            term.draw(|f| {
                let mut a = f.area();
                a.height = h; // force the height-0 early-return path too
                act.draw(f, a);
            })
            .unwrap();
        }
    }
}

#[cfg(test)]
mod slot_invariant_tests {
    use super::*;

    /// Build an activity with a feed saturated well past every per-verbosity cap.
    fn saturated(verbosity: Verbosity, a11y: bool) -> Activity {
        let mut act = Activity::new();
        act.start();
        act.verbosity = verbosity;
        act.set_a11y(a11y);
        for i in 0..20 {
            act.tool_start(&format!("tool{i}"), "{}");
        }
        act
    }

    const ALL_VERBOSITIES: [Verbosity; 4] = [
        Verbosity::Off,
        Verbosity::New,
        Verbosity::All,
        Verbosity::Verbose,
    ];

    /// THE LIVE-REGION INVARIANT: the rows the inline viewport RESERVES for the
    /// activity slot (`max_height`) must always be >= the rows actually DRAWN
    /// (`height`).
    ///
    /// This is the test that was missing while every layout regression shipped
    /// green. Reserving less than is drawn silently clips the feed — a flat 6-row
    /// cap did exactly that to `Verbose` (which wants 9), dropping the three
    /// oldest tool rows with no indication.
    #[test]
    fn reserved_slot_is_never_smaller_than_what_is_drawn() {
        for verbosity in ALL_VERBOSITIES {
            for a11y in [false, true] {
                let act = saturated(verbosity, a11y);
                assert!(
                    act.height() <= act.max_height(),
                    "{verbosity:?} (a11y={a11y}): draws {} rows into a {}-row slot — the feed is clipped",
                    act.height(),
                    act.max_height(),
                );
            }
        }
    }

    /// The other half of the invariant: with the feed saturated the reservation
    /// must be EXACTLY what is drawn. Any slack is dead space — it renders as
    /// blank rows between the spinner and the composer (and, when the component
    /// paints decoration across its whole rect, as bare accent-rail glyphs).
    #[test]
    fn reserved_slot_is_tight_when_the_feed_is_saturated() {
        for verbosity in ALL_VERBOSITIES {
            for a11y in [false, true] {
                let act = saturated(verbosity, a11y);
                assert_eq!(
                    act.height(),
                    act.max_height(),
                    "{verbosity:?} (a11y={a11y}): reserved {} rows but a saturated feed only fills {} — the difference is dead space",
                    act.max_height(),
                    act.height(),
                );
            }
        }
    }

    // ── Sub-agent (delegate) feed lines ──────────────────────────────────

    /// Render the whole activity slot (status line + feed) as one string per row.
    fn feed_rows(act: &Activity, w: u16, h: u16) -> Vec<String> {
        use ratatui::{backend::TestBackend, Terminal};
        let mut term = Terminal::new(TestBackend::new(w, h.max(1))).unwrap();
        term.draw(|f| act.draw(f, f.area())).unwrap();
        let cells: Vec<String> = term
            .backend()
            .buffer()
            .content()
            .iter()
            .map(|c| c.symbol().to_string())
            .collect();
        (0..h as usize)
            .map(|y| cells[y * w as usize..(y + 1) * w as usize].concat())
            .collect()
    }

    fn delegating(act: &Activity) -> Vec<String> {
        feed_rows(act, 120, act.max_height().max(2))
            .into_iter()
            .filter(|r| r.contains("delegating"))
            .collect()
    }

    /// The verb "delegating" is exactly the 10 columns the pad reserved, so
    /// `{:<10}` emitted NOTHING and the detail was glued straight onto it:
    /// `delegatingname, role`. The separator must be unconditional.
    #[test]
    fn tool_feed_always_separates_the_verb_from_its_detail() {
        let mut act = Activity::new();
        act.start();
        act.verbosity = Verbosity::All;
        // A hint that is a real value (not the schema's parameter names).
        act.tool_start("delegate", "/w/codex");
        let rows = delegating(&act);
        assert_eq!(rows.len(), 1, "one delegate row: {rows:?}");
        assert!(
            !rows[0].contains("delegating/w/codex"),
            "verb ran into its detail: {rows:?}"
        );
        assert!(rows[0].contains("delegating "), "missing separator: {rows:?}");
    }

    /// The backend's `tool_call_hint/1` falls back to the SCHEMA's parameter
    /// names (`args |> Map.keys() |> Enum.take(2) |> Enum.join(", ")`), so a
    /// `delegate` call arrived as the literal string `"name, role"`. That is not
    /// a preview of anything and must never be painted as the tool's label.
    #[test]
    fn schema_parameter_name_hints_are_not_rendered_as_a_label() {
        assert!(is_param_name_list("name, role"));
        assert!(is_param_name_list("task_id, prompt"));
        // Real hints must survive.
        assert!(!is_param_name_list("/Users/user/.osa/workspace/codex"));
        assert!(!is_param_name_list("cargo test --release"));
        assert!(!is_param_name_list("explorer"));
        assert!(!is_param_name_list("find the dead code, then report"));

        // The backend no longer emits the key-name shape at all (it returns an
        // empty hint instead — see `Loop.ToolHint`), so this guard is now
        // belt-and-braces for older backends. What matters is that it does not
        // swallow the summaries the fixed backend DOES send.
        for legitimate in [
            "Which parser should we keep?",  // ask_user
            "/proj/lib/agent/loop.ex",       // file tools
            "cargo test --release",          // shell_execute
            "smoke-e2e",                     // delegate teammate
            "Refactor the parser +2 more",   // task_write add_multiple
            "complete t-7",                  // task_write status change
        ] {
            assert!(
                !is_param_name_list(legitimate),
                "guard swallowed a real summary: {legitimate:?}"
            );
        }

        let mut act = Activity::new();
        act.start();
        act.verbosity = Verbosity::All;
        act.tool_start("delegate", "name, role");
        let rows = delegating(&act);
        assert_eq!(rows.len(), 1, "one delegate row: {rows:?}");
        assert!(
            !rows[0].contains("name, role"),
            "schema parameter names leaked into the label: {rows:?}"
        );
    }

    /// ONE clock per surface. A RUNNING sub-agent's age belongs to its fleet
    /// roster row; the turn clock belongs to the status line. The delegate feed
    /// line must add no third live timer.
    #[test]
    fn running_delegate_line_carries_no_timer() {
        let mut act = Activity::new();
        act.start();
        act.verbosity = Verbosity::All;
        act.tool_start("delegate", "/w/codex");
        let rows = delegating(&act);
        let has_timer = rows[0]
            .split_whitespace()
            .any(|t| {
                let t = t.trim_end_matches('.');
                t.ends_with('s')
                    && t.starts_with(|c: char| c.is_ascii_digit())
                    && t.chars().all(|c| c.is_ascii_digit() || matches!(c, 'm' | 's' | '.'))
            });
        assert!(!has_timer, "running delegate line shows a timer: {rows:?}");

        // A COMPLETED call still reports its duration — the roster row is gone by
        // then, so the number is a fact rather than a competing clock.
        act.tool_end("delegate", 4200, true);
        let done = delegating(&act);
        assert!(done[0].contains("4.2s"), "finished delegate keeps its duration: {done:?}");
    }

    /// Two concurrent `delegate` calls drew two byte-identical lines. Fold them
    /// into one row with a `×N` multiplier instead.
    #[test]
    fn identical_concurrent_calls_fold_into_one_row_with_a_multiplier() {
        let mut act = Activity::new();
        act.start();
        act.verbosity = Verbosity::All;
        act.tool_start_with_id("delegate", "name, role", Some("call-a"));
        act.tool_start_with_id("delegate", "name, role", Some("call-b"));
        let rows = delegating(&act);
        assert_eq!(rows.len(), 1, "identical concurrent calls fold: {rows:?}");
        assert!(rows[0].contains("\u{00d7}2"), "missing ×2 multiplier: {rows:?}");
        assert_eq!(act.tool_feed.len(), 1, "one feed entry backs the folded row");
    }

    /// Pairing by tool NAME closed whichever same-name row happened to be last,
    /// so the first completion froze the OTHER worker's line. With per-call ids
    /// the row stays live until its last id is retired.
    #[test]
    fn tool_end_pairs_by_call_id_not_by_tool_name() {
        let mut act = Activity::new();
        act.start();
        act.verbosity = Verbosity::All;
        act.tool_start_with_id("delegate", "name, role", Some("call-a"));
        act.tool_start_with_id("delegate", "name, role", Some("call-b"));

        // First completion retires one of the two folded calls; the row runs on.
        act.tool_end_with_id("delegate", 1000, true, Some("call-a"));
        assert_eq!(act.tool_feed[0].concurrent, 1, "one call still in flight");
        assert!(act.tool_feed[0].duration_ms.is_none(), "row must stay live");

        // Second completion closes it for real.
        act.tool_end_with_id("delegate", 2500, true, Some("call-b"));
        assert_eq!(act.tool_feed[0].duration_ms, Some(2500));

        // Distinct details are NOT folded, and each id closes its own row.
        let mut act = Activity::new();
        act.start();
        act.tool_start_with_id("delegate", "/a", Some("id-a"));
        act.tool_start_with_id("delegate", "/b", Some("id-b"));
        assert_eq!(act.tool_feed.len(), 2);
        act.tool_end_with_id("delegate", 900, true, Some("id-a"));
        assert_eq!(act.tool_feed[0].duration_ms, Some(900), "id-a's own row closed");
        assert!(act.tool_feed[1].duration_ms.is_none(), "id-b still running");
    }

    /// An inactive activity must reserve nothing, so the slot collapses when idle.
    #[test]
    fn idle_activity_reserves_no_rows() {
        let act = Activity::new();
        assert_eq!(act.height(), 0);
        assert_eq!(act.max_height(), 0);
    }

    // ── Live command output ──────────────────────────────────────────────

    /// Render the activity into a `w`x`h` test terminal and return its cells as
    /// one flat string (same trick as `render_activity_text`, but sized).
    fn render_live(act: &Activity, w: u16, h: u16) -> String {
        use ratatui::{backend::TestBackend, Terminal};
        let mut term = Terminal::new(TestBackend::new(w, h.max(1))).unwrap();
        term.draw(|f| act.draw(f, f.area())).unwrap();
        term.backend()
            .buffer()
            .content()
            .iter()
            .map(|c| c.symbol())
            .collect()
    }

    #[test]
    fn live_output_shows_the_last_lines_of_the_running_command() {
        let mut act = Activity::new();
        act.start();
        act.tool_start("Bash", r#"{"command":"make"}"#);
        for i in 0..40 {
            act.push_command_output("make", &format!("compiling unit {i}\n"));
        }
        let lines = act.live_output_lines();
        assert_eq!(lines.len(), LIVE_OUTPUT_PREVIEW_LINES);
        assert_eq!(lines[lines.len() - 1], "compiling unit 39");
    }

    #[test]
    fn a_different_command_resets_the_live_tail() {
        let mut act = Activity::new();
        act.start();
        act.push_command_output("first", "from first\n");
        act.push_command_output("second", "from second\n");
        assert_eq!(act.live_output_lines(), vec!["from second"]);
    }

    #[test]
    fn concurrent_streams_do_not_corrupt_each_other() {
        // Regression: there used to be ONE shared buffer routed by the COMMAND
        // STRING. Two concurrent commands thrashed it (every delta from the
        // other command cleared it), and the SAME command run twice never
        // cleared, so both streams interleaved into one buffer. Keyed by the
        // owning tool_call id, each call owns its own buffer.
        let mut act = Activity::new();
        act.start();

        // Two concurrent calls, interleaved deltas.
        act.push_command_output("call_du", "du line 1\n");
        act.push_command_output("call_df", "df line 1\n");
        act.push_command_output("call_du", "du line 2\n");
        act.push_command_output("call_df", "df line 2\n");

        // The preview shows the freshest stream — df — and ONLY df's lines.
        let df_view = act.live_output_lines();
        assert_eq!(df_view, vec!["df line 1", "df line 2"], "df stream leaked du output");

        // du's buffer is intact and uncontaminated: a delta on it brings its
        // own complete history back into view.
        act.push_command_output("call_du", "du line 3\n");
        assert_eq!(
            act.live_output_lines(),
            vec!["du line 1", "du line 2", "du line 3"],
            "du stream was cleared or mixed with df"
        );

        // Two concurrent runs of the SAME command text are distinct streams.
        act.push_command_output("call_x1", "x1\n");
        act.push_command_output("call_x2", "x2\n");
        assert_eq!(act.live_output_lines(), vec!["x2"]);

        // One call finishing drops only ITS buffer.
        act.clear_command_output_for("call_x2");
        assert!(act.live_stream_is_empty("call_x2"));
        assert!(!act.live_stream_is_empty("call_du"), "du must survive x2 ending");
        assert!(!act.live_stream_is_empty("call_x1"));

        // Turn end drops everything.
        act.clear_command_output();
        assert!(act.live_output_lines().is_empty());
        assert!(act.live_stream_is_empty("call_du"));
    }

    #[test]
    fn live_output_never_grows_the_reserved_slot() {
        // The live tail SHARES the feed budget — it must not change the number
        // of rows the inline viewport reserves, or every delta would re-anchor
        // the viewport mid-turn.
        let mut act = Activity::new();
        act.start();
        act.tool_start("Bash", r#"{"command":"make"}"#);
        let (h, max) = (act.height(), act.max_height());
        for i in 0..200 {
            act.push_command_output("make", &format!("line {i}\n"));
        }
        assert_eq!(act.height(), h);
        assert_eq!(act.max_height(), max);
    }

    #[test]
    fn live_output_renders_into_the_feed_area() {
        let mut act = Activity::new();
        act.start();
        act.tool_start("Bash", r#"{"command":"make"}"#);
        act.push_command_output("make", "linking target\n");
        let text = render_live(&act, 100, act.max_height().max(1));
        assert!(
            text.contains("linking target"),
            "live tail must be painted: {text:?}"
        );
    }

    #[test]
    fn clearing_live_output_removes_it_from_the_feed() {
        let mut act = Activity::new();
        act.start();
        act.push_command_output("make", "linking target\n");
        act.clear_command_output();
        assert!(act.live_output_lines().is_empty());
        let text = render_live(&act, 100, act.max_height().max(1));
        assert!(!text.contains("linking target"));
    }

    #[test]
    fn sanitize_live_line_strips_control_bytes_and_ansi() {
        assert_eq!(sanitize_live_line("plain", 40), "plain");
        assert_eq!(sanitize_live_line("a\u{1b}[31mred\u{1b}[0m", 40), "ared");
        assert_eq!(sanitize_live_line("tab\there", 40), "tab here");
        assert_eq!(sanitize_live_line("cr\rrewrite", 40), "crrewrite");
        // Clipped to the column budget, never wrapped.
        assert_eq!(sanitize_live_line("abcdefghij", 4), "abcd");
        assert_eq!(sanitize_live_line("anything", 0), "");

        // OSC, not CSI: an OSC string runs to BEL or ST, so a skipper that
        // breaks on the first ASCII alphabetic stops inside the URL, leaks its
        // tail as visible text, and then the trailing `ESC \` eats real output.
        assert_eq!(
            sanitize_live_line("a\u{1b}]8;;http://x\u{1b}\\link\u{1b}]8;;\u{1b}\\b", 40),
            "alinkb"
        );
        // BEL-terminated OSC (window title) — the other legal terminator.
        assert_eq!(
            sanitize_live_line("x\u{1b}]0;my title\u{7}y", 40),
            "xy"
        );
        // The tmux DCS passthrough wrapper is a string-family escape too.
        assert_eq!(
            sanitize_live_line("p\u{1b}P tmux;junk\u{1b}\\q", 40),
            "pq"
        );
        // Wide chars are measured in COLUMNS, not bytes.
        assert_eq!(sanitize_live_line("\u{4f60}\u{597d}", 3), "\u{4f60}");
    }

    #[test]
    fn newline_free_flood_never_breaks_the_render() {
        // The pathological `\r` progress-bar case: one enormous line, no
        // newline. Must stay one bounded row and must not panic.
        let mut act = Activity::new();
        act.start();
        act.tool_start("Bash", r#"{"command":"dd"}"#);
        let blob = "z".repeat(64 * 1024);
        for _ in 0..64 {
            act.push_command_output("dd", &blob);
        }
        assert_eq!(act.live_output_lines().len(), 1);
        let _ = render_live(&act, 80, act.max_height().max(1));
    }
}

// ---------------------------------------------------------------------------
// Tool-duration rendering in the live activity feed.
//
// The feed printed EVERY completed tool's duration as `{:.1}s`, so anything
// faster than 50 ms floored to a literal `0.0s` while the very same call
// rendered `40ms` in the transcript below it (`tools::format_duration`). These
// tests pin the feed to that one shared formatter.
// ---------------------------------------------------------------------------
#[cfg(test)]
mod duration_render_tests {
    use super::*;

    fn render(act: &Activity, w: u16) -> String {
        use ratatui::{backend::TestBackend, Terminal};
        let h = act.max_height().max(1);
        let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
        term.draw(|f| act.draw(f, f.area())).unwrap();
        term.backend()
            .buffer()
            .content()
            .iter()
            .map(|c| c.symbol())
            .collect()
    }

    fn feed_with(duration_ms: u64, success: bool) -> Activity {
        let mut act = Activity::new();
        act.start();
        act.verbosity = Verbosity::All;
        act.tool_start_with_id("file_read", "/tmp/x.rs", Some("c1"));
        act.tool_end_with_id("file_read", duration_ms, success, Some("c1"));
        act
    }

    #[test]
    fn sub_second_tool_durations_keep_millisecond_resolution() {
        // A 40 ms read is a real measurement, not zero.
        let act = feed_with(40, true);
        let out = render(&act, 100);
        assert!(out.contains("40ms"), "expected millisecond resolution: {out:?}");
        assert!(
            !out.contains("0.0s"),
            "a 40ms call must never render as zero seconds: {out:?}"
        );
    }

    #[test]
    fn a_failed_sub_second_call_also_keeps_millisecond_resolution() {
        let act = feed_with(12, false);
        let out = render(&act, 100);
        assert!(out.contains("12ms"), "expected 12ms: {out:?}");
        assert!(!out.contains("0.0s"), "failed fast call showed 0.0s: {out:?}");
    }

    #[test]
    fn multi_second_durations_still_render_in_seconds() {
        let act = feed_with(2_500, true);
        let out = render(&act, 100);
        assert!(out.contains("2.5s"), "expected 2.5s: {out:?}");
    }
}

#[cfg(test)]
mod turn_start_indicator_tests {
    use super::*;
    use ratatui::layout::Rect;
    use ratatui::{backend::TestBackend, Terminal};

    /// **A turn that has started must SAY so, before any token arrives.**
    ///
    /// `App::submit_prompt` commits the user's prompt, transitions to
    /// `Processing` and calls `Activity::start()`. Between that moment and the
    /// model's first token — seconds, on a large context — the activity band is
    /// the only thing on screen that reports a turn is running. Measured on a
    /// real PTY (`test/pty/smoothness_probe.py`), that window rendered the
    /// prompt, two blank rows and an idle-looking composer: the band was
    /// RESERVED and painted nothing, which reads as a freeze.
    #[test]
    fn a_started_turn_paints_something_before_the_first_token() {
        let mut activity = Activity::new();
        activity.start();

        assert!(
            activity.height() > 0,
            "a started turn must reserve at least the spinner row"
        );

        let h = activity.height();
        let mut term = Terminal::new(TestBackend::new(80, h)).unwrap();
        term.draw(|f| activity.draw(f, Rect::new(0, 0, 80, h))).unwrap();
        let buf = term.backend().buffer().clone();

        let painted: String = (0..h)
            .flat_map(|y| (0..80u16).map(move |x| (x, y)))
            .map(|(x, y)| buf[(x, y)].symbol().to_string())
            .collect();

        assert!(
            !painted.trim().is_empty(),
            "the activity band reserved {} row(s) and painted nothing — the user \
             sees a blank gap and an idle composer while the turn runs",
            activity.height()
        );
    }
}
