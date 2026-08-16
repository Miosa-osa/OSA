use ratatui::layout::{Constraint, Direction, Layout as RLayout};
use ratatui::prelude::*;
use ratatui::widgets::Paragraph;

use crate::client::types::Signal;
use crate::event::Event;
use crate::style;
use crate::util::{cols, fit_cols};

use super::{Component, ComponentAction};

/// Columns row 0 keeps in reserve for the context meter and the trailing chips
/// when deciding whether the session title fits. The meter (`▁▂▃ 42% ctx`) plus
/// its separator is ~16 columns; the rest covers the version chip and a little
/// slack so a title never squeezes the meter off the right edge.
const TITLE_RESERVE_COLS: usize = 26;
/// Below this the title is unreadable, so it is omitted instead of shown as a
/// stub like "Debugging pr…" — a fragment that costs row space and answers
/// nothing. Verified against the rendered row: 80 columns shows a full title,
/// 60 shows none.
const TITLE_MIN_COLS: usize = 16;
/// Upper bound so a long title cannot dominate row 0 on a wide terminal.
const TITLE_MAX_COLS: usize = 32;

/// Tool-permission mode. OSA's Shift+Tab cycle is
/// `ask → auto-edit → plan → overdrive (full auto)`. `Auto` is retained as a
/// separate tier driven by the `/auto` command (the safety guardian) but is not
/// part of the Shift+Tab cycle. `BypassPermissions` is OSA's **overdrive** mode —
/// full auto, no prompts — and is always glossed "(full auto)" and shown in red.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PermissionMode {
    /// "ask" — the default: pause and prompt on each gated tool call.
    Default,
    /// Auto mode — backend "auto" permission tier: the safety guardian
    /// auto-approves safe actions and pauses on dangerous ones for review.
    Auto,
    /// "auto-edit" — auto-approve edit/write tools, still prompt for shell/risky.
    AcceptEdits,
    /// "overdrive (full auto)" — bypass every prompt. Dangerous; red.
    BypassPermissions,
    /// "plan" — read-only, no mutating execution.
    Plan,
}

impl PermissionMode {
    /// Leading symbol for the permission line (`⏵⏵`, `⏸`, or none).
    pub fn symbol(&self) -> &'static str {
        match self {
            PermissionMode::AcceptEdits | PermissionMode::BypassPermissions => "\u{23F5}\u{23F5}",
            PermissionMode::Plan => "\u{23F8}",
            PermissionMode::Auto => "\u{25C8}", // ◈
            PermissionMode::Default => "",
        }
    }

    /// Full title shown on the permission line. Overdrive always carries its
    /// "(full auto)" gloss so the mode is never ambiguous.
    pub fn title(&self) -> &'static str {
        match self {
            PermissionMode::BypassPermissions => "Overdrive (full auto)",
            PermissionMode::AcceptEdits => "Auto-edit",
            PermissionMode::Plan => "Plan mode",
            PermissionMode::Auto => "Auto",
            PermissionMode::Default => "Ask",
        }
    }

    /// Short title used for the status-line mode chip. Overdrive keeps its
    /// "(full auto)" gloss here too.
    pub fn short_title(&self) -> &'static str {
        match self {
            PermissionMode::BypassPermissions => "overdrive (full auto)",
            PermissionMode::AcceptEdits => "auto-edit",
            PermissionMode::Plan => "plan",
            PermissionMode::Auto => "auto",
            PermissionMode::Default => "ask",
        }
    }

    /// Canonical backend token for this mode, sent to the server on every
    /// transition so its enforcement matches the displayed mode.
    pub fn backend_token(&self) -> &'static str {
        match self {
            PermissionMode::BypassPermissions => "overdrive",
            PermissionMode::AcceptEdits => "accept-edits",
            PermissionMode::Plan => "plan",
            PermissionMode::Auto => "auto",
            PermissionMode::Default => "ask",
        }
    }

    pub fn is_default(&self) -> bool {
        matches!(self, PermissionMode::Default)
    }

    /// Whether this is OSA's overdrive (full-auto / bypass) mode.
    pub fn is_overdrive(&self) -> bool {
        matches!(self, PermissionMode::BypassPermissions)
    }

    /// Advance to the next mode in the Shift+Tab cycle:
    /// `ask → auto-edit → plan → overdrive → ask`. `Auto` (set via `/auto`) is
    /// not part of the cycle; from Auto, Shift+Tab drops into `auto-edit`.
    pub fn next(&self) -> PermissionMode {
        match self {
            PermissionMode::Default => PermissionMode::AcceptEdits,
            PermissionMode::Auto => PermissionMode::AcceptEdits,
            PermissionMode::AcceptEdits => PermissionMode::Plan,
            PermissionMode::Plan => PermissionMode::BypassPermissions,
            PermissionMode::BypassPermissions => PermissionMode::Default,
        }
    }

    /// Mode color: OSA blue for the ask/auto-edit/plan/auto tiers, red for
    /// overdrive (full auto).
    fn color(&self, theme: &style::Theme) -> Color {
        match self {
            PermissionMode::BypassPermissions => theme.colors.error, // overdrive — red
            _ => theme.colors.primary,                               // OSA blue
        }
    }
}

/// Build an 8-cell braille context-usage bar (e.g. `⢿░░░░░░░` at ~4%,
/// `⣿⣿⣿⣿⣿⣿⣿⢿` near-full). Leading full cells are `⣿`, the boundary partial
/// cell is `⢿`, trailing empties are `░`. Returns (filled_prefix, empty_suffix)
/// so the two halves can be styled separately.
fn braille_bar(ratio: f64, cells: usize) -> (String, String) {
    let ratio = ratio.clamp(0.0, 1.0);
    let scaled = ratio * cells as f64;
    let full = (scaled.floor() as usize).min(cells);
    let remainder = scaled - full as f64;
    let has_partial = full < cells && remainder > 0.001;

    let mut filled = String::new();
    for _ in 0..full {
        filled.push('\u{28FF}'); // ⣿
    }
    if has_partial {
        filled.push('\u{28BF}'); // ⢿
    }
    let used = full + usize::from(has_partial);
    let empty: String = std::iter::repeat('\u{2591}').take(cells - used).collect(); // ░
    (filled, empty)
}

/// Compact elapsed formatter for the active-goal indicator (Codex
/// `fmt_elapsed_compact`, `status_indicator_widget.rs`). Mirrors Codex exactly:
/// under a minute → `12s`; under an hour → `3m 40s` (seconds zero-padded); an
/// hour or more → `1h 05m 22s` (minutes and seconds zero-padded). Distinct from
/// `util::fmt_elapsed` (which drops trailing zero units) so the goal timer counts
/// up smoothly second-by-second like Codex's thread-goal status line.
pub(crate) fn fmt_elapsed_compact(secs: u64) -> String {
    if secs < 60 {
        format!("{}s", secs)
    } else if secs < 3600 {
        let (m, s) = (secs / 60, secs % 60);
        format!("{}m {:02}s", m, s)
    } else {
        let (h, m, s) = (secs / 3600, (secs % 3600) / 60, secs % 60);
        format!("{}h {:02}m {:02}s", h, m, s)
    }
}

/// U-T25 — integer percent of a USD daily cap already spent, if a cap exists.
/// `None` ⇒ uncapped (no usage % to show). Divide-by-zero safe; clamps to 100.
fn usage_pct(spent: f64, limit: Option<f64>) -> Option<u32> {
    match limit {
        Some(l) if l > 0.0 => Some(((spent / l) * 100.0).round().clamp(0.0, 100.0) as u32),
        _ => None,
    }
}

/// U-T25 — the balance is "low" once ≥ 80% of the daily cap is spent, so the
/// billing chip turns red before the wall is hit.
fn is_low_balance(pct: u32) -> bool {
    pct >= 80
}

/// U-T23 — the idle "watcher" cue. When background work is running while the
/// agent is otherwise idle, name what it is watching: `monitors` = running
/// background shell jobs, `loops` = backgrounded turns/loops. `None` ⇒ nothing
/// to watch ⇒ no cue.
fn watcher_label(monitors: usize, loops: usize) -> Option<String> {
    if monitors == 0 && loops == 0 {
        return None;
    }
    let mut s = String::from("watching");
    if monitors > 0 {
        s.push_str(&format!(" \u{00b7} {} monitor{}", monitors, if monitors == 1 { "" } else { "s" }));
    }
    if loops > 0 {
        s.push_str(&format!(" \u{00b7} {} loop{}", loops, if loops == 1 { "" } else { "s" }));
    }
    Some(s)
}

/// U-T26 — the MCP chip text: "N MCP" once servers are known, `None` when there
/// are none. (LSP is not modelled by the OSA backend, so no "N LSP" half is
/// emitted.)
/// `hooks 54 ok, 19 failed` — or nothing at all before a hook has ever run, so a
/// session with no hooks configured carries no chip for them.
///
/// The failure clause is omitted entirely at zero rather than printed as
/// `0 failed`: a standing zero trains the eye to skip the whole segment, and the
/// number only matters on the rare session where it is not zero.
fn hooks_label(ok: u32, failed: u32) -> Option<String> {
    match (ok, failed) {
        // A running count of SUCCESSFUL hooks is not information. It only ever
        // goes up, nobody acts on "691 ok", and it sat permanently in the
        // status bar next to numbers that do change. Reported as noise, and it
        // was.
        //
        // Failures still surface, because those are the case worth a glance —
        // and the per-row `[hooks: …]` bracket on tool summaries still carries
        // the per-call detail where it is actually attributable.
        (_, 0) => None,
        _ => Some(format!("hooks {} failed", failed)),
    }
}

fn mcp_label(count: usize) -> Option<String> {
    if count > 0 {
        Some(format!("{} MCP", count))
    } else {
        None
    }
}

/// Substrings that mark a "gap" string as a HARNESS DIAGNOSTIC rather than a
/// review finding. A skeptic whose response could not be parsed, or that timed
/// out / crashed, is an internal detail: it belongs in the log, never on the
/// status bar as a `⚠` badge. The backend filters these before emitting, so
/// this is defence in depth — the invariant is asserted by
/// `internal_diagnostics_never_reach_the_status_bar`.
const INTERNAL_GAP_MARKERS: &[&str] = &[
    "unparsable",
    "unparseable",
    "unstructured review",
    "skeptic failed",
    "panel spawn",
    "unrecognized skeptic",
    "no reason given",
];

/// The gaps that may be shown to a user: non-empty, and not a harness
/// diagnostic.
fn displayable_gaps(gaps: &[String]) -> Vec<&str> {
    gaps.iter()
        .map(|g| g.trim())
        .filter(|g| !g.is_empty() && !is_internal_gap(g))
        .collect()
}

fn is_internal_gap(gap: &str) -> bool {
    let lower = gap.to_ascii_lowercase();
    INTERNAL_GAP_MARKERS.iter().any(|m| lower.contains(m))
}

/// Minimum pane width before the chip names the first gap at all — below this
/// the counts alone are all that fits.
const GAP_LABEL_MIN_WIDTH: u16 = 100;

/// The first showable gap, fitted to a share of the pane width. `None` when the
/// pane is too narrow or nothing is showable.
fn first_gap_label(shown: &[&str], width: u16) -> Option<String> {
    if width < GAP_LABEL_MIN_WIDTH {
        return None;
    }
    let first = shown.first()?;
    let budget = ((width as usize) / 3).clamp(20, 60);
    Some(fit_cols_words(first, budget))
}

/// Fit `s` into `max_cols` DISPLAY COLUMNS, ellipsizing on a WORD boundary.
///
/// `util::fit_cols` is already column-correct (never byte/char counting), but it
/// cuts wherever the budget runs out — which is what produced the reported
/// `… (fai…` mid-word. This backs the cut off to the last whitespace so the
/// label always ends on a whole word, falling back to the raw column fit for a
/// single token longer than the whole budget.
fn fit_cols_words(s: &str, max_cols: usize) -> String {
    use crate::util::{cols, fit_cols};
    if cols(s) <= max_cols {
        return s.to_string();
    }
    let clipped = fit_cols(s, max_cols);
    let body = clipped.strip_suffix('\u{2026}').unwrap_or(clipped.as_str());
    match body.rfind(char::is_whitespace) {
        Some(idx) => {
            let head = body[..idx].trim_end();
            // Don't back off so far that almost nothing is left (one very long
            // leading token) — the raw column fit is better than an empty chip.
            if cols(head) * 3 >= max_cols {
                format!("{}\u{2026}", head)
            } else {
                clipped
            }
        }
        None => clipped,
    }
}

/// Cheap local token estimate for the composer's pending input, so the context
/// meter can reflect what the user is about to add before the turn is committed
/// (CC parity). Char/4 heuristic — the same rough ratio the activity counter
/// already uses for streamed output (`stream_chars / 4`, activity.rs) — kept as
/// one small pure function. `ceil` so a single character reads as 1 token, not 0.
pub(crate) fn estimate_tokens(text: &str) -> u64 {
    (text.chars().count() as u64).div_ceil(4)
}

/// Below this many estimated tokens the pending composer input is noise, so the
/// compact `+~Nk` hint stays hidden (CC only surfaces the size of large pastes).
/// At or above it the hint appears next to the context readout.
const PENDING_HINT_MIN_TOKENS: u64 = 1000;

/// Compact `+~Nk` (or `+~N`) pending-size hint text for the composer estimate.
/// Terse by design so it survives on narrow panes.
fn pending_hint(tokens: u64) -> String {
    if tokens >= 1000 {
        format!("+~{}k", (tokens as f64 / 1000.0).round() as u64)
    } else {
        format!("+~{}", tokens)
    }
}

/// Compact `~Nk` token count for the unknown-window context readout, where a
/// percentage cannot be computed honestly. The `~` is deliberate: the figure is
/// the last request's prompt size (or the backend's estimate), not an exact
/// live count.
pub(crate) fn compact_tokens(tokens: u64) -> String {
    if tokens >= 1_000_000 {
        format!("~{:.1}M", tokens as f64 / 1_000_000.0)
    } else if tokens >= 1000 {
        format!("~{:.1}k", tokens as f64 / 1000.0)
    } else {
        format!("~{}", tokens)
    }
}

/// Transient goal-verification indicator state, tied to the active-goal line.
/// Set from the backend `goal_verifier_round` event and cleared on a new turn.
/// Deliberately understated: one compact chip, never a popup.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GoalVerifyState {
    /// The skeptic panel is spawning / voting (`phase: start`).
    Verifying,
    /// Majority did not refute — the goal reads as met (`verdict: complete`).
    OnTrack,
    /// Majority refuted — not done yet; carries the compact gap summary.
    Incomplete { refuted: u32, total: u32, gaps: Vec<String> },
    /// Majority judged the goal unachievable as framed (`verdict: off_track`).
    OffTrack,
}

pub struct StatusBar {
    signal: Option<Signal>,
    provider: String,
    model_name: String,
    context_utilization: f64,
    context_max: u64,
    context_estimated: u64,
    /// Live estimate of the composer's uncommitted input, char/4 (see
    /// `estimate_tokens`). Rendered as a transient overlay ON TOP of the
    /// committed `context_utilization` (never mutating it), and reset to 0 on
    /// submit / clear. 0 ⇒ nothing pending ⇒ meter shows the committed value.
    pending_input_tokens: u64,
    input_tokens: u64,
    output_tokens: u64,
    elapsed_ms: u64,
    llm_iteration: u32,
    active: bool,
    bg_count: usize,
    width: u16,
    recording: bool,
    recording_elapsed_secs: u64,
    transcribing: bool,
    audio_level: u8,
    download_label: String,
    download_pct: u8,
    hands_free: bool,
    permission_mode: PermissionMode,
    /// Coordinator posture: when true the backend restricts the tool surface to
    /// delegation/messaging only; drives the compact `⧉ coordinator` chip.
    coordinator: bool,
    shell_count: usize,
    cwd_basename: String,
    /// Human-readable title of the active session ("Debugging production 500
    /// errors"), pushed from the backend over SSE. None ⇒ untitled (a session
    /// with no prompt yet) ⇒ the segment is omitted.
    session_title: Option<String>,
    /// "goal N/max" indicator when a /goal auto-continue loop is active.
    goal_label: Option<String>,
    /// Transient goal-verification indicator, rendered next to the goal line.
    /// None ⇒ no verifier round this turn ⇒ chip omitted.
    goal_verify: Option<GoalVerifyState>,
    /// Reasoning effort ("fast"|"medium"|"high"|"xhigh"|"ultra") from `/health.effort`.
    /// None ⇒ backend didn't report it ⇒ the chip is omitted.
    effort: Option<String>,
    /// Billing snapshot from `/health.billing`. None ⇒ omit the spend chip.
    billing: Option<crate::client::types::HealthBilling>,
    /// WS12 — % of usable context left before auto-compact (backend
    /// context_pressure `percent_left`). None until the first report.
    percent_left: Option<u32>,
    /// WS12 — backend crossed the low-context warning threshold
    /// (context_pressure `context_low`); drives the red hint + % styling.
    context_low: bool,
    /// Absolute token thresholds from the backend, so `percent_left` and
    /// `context_low` can be DERIVED from `context_estimated` on every update
    /// rather than cached from whichever event last carried them. 0 == unknown.
    context_compact_at: u64,
    context_warn_at: u64,
    /// U-T26 — number of connected MCP servers (from `McpServersLoaded`). 0 ⇒
    /// no chip. Populated on session start and on `/mcp`.
    mcp_count: usize,
    /// U-B5 — live swarm-intelligence status ("swarm · round N"), driven by the
    /// SwarmIntelligence* events. None ⇒ no swarm running ⇒ chip omitted.
    swarm_label: Option<String>,
    /// Hook invocations this session: how many ran, and how many failed.
    ///
    /// Blocks are NOT counted as failures. A policy hook refusing a dangerous
    /// command is the system working; folding that into a failure count would
    /// report a correctly-configured setup as broken. Only a crash, an exit or a
    /// timeout counts here.
    hooks_ok: u32,
    hooks_failed: u32,
    /// U-T28 — active sub-agent count + estimated cost, for the compact
    /// "⛓ N subagents · $cost · ↓ manage" footer cue. 0 ⇒ omitted.
    subagent_count: usize,
    subagent_cost: Option<f64>,
    /// True while the inline `← for agents` FleetSelect roster focus is active,
    /// so the footer swaps the `← for agents` idle hint for the per-row
    /// `Enter to view · x to stop` action hint (CC FleetView).
    fleet_select: bool,
    /// Latest available release when the backend reports one on `/health.update`
    /// (`available: true`). Drives the understated `⬆ vX` chip. `None` ⇒ up to
    /// date / source build / not yet reported ⇒ chip omitted.
    update_latest: Option<String>,
}

impl StatusBar {
    pub fn new() -> Self {
        let cwd_basename = std::env::current_dir()
            .ok()
            .and_then(|p| p.file_name().map(|n| n.to_string_lossy().to_string()))
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "~".to_string());
        Self {
            signal: None,
            provider: String::new(),
            model_name: String::new(),
            context_utilization: 0.0,
            context_max: 0,
            context_estimated: 0,
            pending_input_tokens: 0,
            input_tokens: 0,
            output_tokens: 0,
            elapsed_ms: 0,
            llm_iteration: 0,
            active: false,
            bg_count: 0,
            width: 0,
            recording: false,
            recording_elapsed_secs: 0,
            transcribing: false,
            audio_level: 0,
            download_label: String::new(),
            download_pct: 0,
            hands_free: false,
            permission_mode: PermissionMode::Default,
            coordinator: false,
            shell_count: 0,
            cwd_basename,
            session_title: None,
            goal_label: None,
            goal_verify: None,
            effort: None,
            billing: None,
            percent_left: None,
            context_low: false,
            context_compact_at: 0,
            context_warn_at: 0,
            mcp_count: 0,
            swarm_label: None,
            hooks_ok: 0,
            hooks_failed: 0,
            subagent_count: 0,
            subagent_cost: None,
            fleet_select: false,
            update_latest: None,
        }
    }

    /// Set the folder label from the session's real working directory (the same
    /// source the welcome banner shows), so the status bar can never disagree
    /// with the banner. Shows the basename, or "~" for the home directory. A
    /// blank path leaves the label untouched.
    pub fn set_cwd_path(&mut self, path: &str) {
        let path = path.trim();
        if path.is_empty() {
            return;
        }
        if let Ok(home) = std::env::var("HOME") {
            if !home.is_empty() && path == home {
                self.cwd_basename = "~".to_string();
                return;
            }
        }
        let name = std::path::Path::new(path)
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| path.to_string());
        self.cwd_basename = name;
    }

    /// Set (or clear with None) the session-title segment. Blank titles are
    /// normalized to None so an empty backend value renders nothing rather than
    /// a stray separator.
    ///
    /// The title is **model-generated** (the backend asks the model to name the
    /// conversation) and lands in *persistent chrome* — row 0, redrawn every
    /// frame. That makes it the worst place in the UI for a raw escape: one
    /// injected OSC survives every redraw for the life of the session. Scrubbed
    /// here, at the single setter, so no render site has to remember.
    pub fn set_session_title(&mut self, title: Option<String>) {
        let title = crate::render::sanitize::scrub_untrusted_line_opt(title);
        self.session_title = title
            .map(|t| t.trim().to_string())
            .filter(|t| !t.is_empty());
    }

    /// The active session title, if any.
    pub fn session_title(&self) -> Option<&str> {
        self.session_title.as_deref()
    }

    /// Set (or clear with None) the reasoning-effort chip.
    pub fn set_effort(&mut self, effort: Option<String>) {
        // Normalize away blanks so an empty string never renders "effort:".
        self.effort = effort.filter(|s| !s.trim().is_empty());
    }

    /// The current reasoning-effort tier, if any. Source of truth for the live
    /// thinking segment's "thinking with <effort> effort" suffix (activity.rs).
    pub fn effort(&self) -> Option<String> {
        self.effort.clone()
    }

    /// Set (or clear with None) the billing spend/limit chip.
    pub fn set_billing(&mut self, billing: Option<crate::client::types::HealthBilling>) {
        self.billing = billing;
    }

    /// Set (or clear with None) the active-goal indicator, e.g. "goal 3/25".
    pub fn set_goal_label(&mut self, label: Option<String>) {
        self.goal_label = label;
    }

    /// Set (or clear with None) the transient goal-verification indicator.
    pub fn set_goal_verification(&mut self, state: Option<GoalVerifyState>) {
        self.goal_verify = state;
    }

    /// U-T26 — number of connected MCP servers, feeding the row-0 MCP chip.
    pub fn set_mcp(&mut self, count: usize) {
        self.mcp_count = count;
    }

    /// Record one finished hook invocation. `outcome` is the backend's own
    /// vocabulary rather than a boolean — see `BackendEvent::HookRun`.
    pub fn note_hook_run(&mut self, outcome: &str) {
        match outcome {
            "crashed" | "timed_out" => self.hooks_failed += 1,
            // `blocked` deliberately falls here: the hook ran and did its job.
            _ => self.hooks_ok += 1,
        }
    }

    /// U-B5 — set (or clear with None) the live swarm-intelligence chip.
    pub fn set_swarm(&mut self, label: Option<String>) {
        self.swarm_label = label;
    }

    /// U-T28 — set the active sub-agent count + estimated cost for the footer
    /// cue. `count == 0` clears it.
    /// Toggle the inline FleetSelect roster-focus footer hint.
    pub fn set_fleet_select(&mut self, active: bool) {
        self.fleet_select = active;
    }

    pub fn set_subagents(&mut self, count: usize, cost: Option<f64>) {
        self.subagent_count = count;
        self.subagent_cost = cost;
    }

    /// Set (or clear) the "update available" chip from `/health.update`. Stores
    /// the latest version only when the backend flags one available; anything
    /// else (up to date, source build, absent) clears the chip. Understated by
    /// design — a compact `⬆ vX`, never a nag.
    pub fn set_update_available(&mut self, update: Option<crate::client::types::HealthUpdate>) {
        self.update_latest = match update {
            Some(u) if u.available => {
                u.latest_version.filter(|v| !v.trim().is_empty())
            }
            _ => None,
        };
    }

    /// The latest-version string currently backing the update chip, if any.
    pub fn update_latest(&self) -> Option<&str> {
        self.update_latest.as_deref()
    }

    pub fn set_permission_mode(&mut self, mode: PermissionMode) {
        self.permission_mode = mode;
    }

    pub fn permission_mode(&self) -> PermissionMode {
        self.permission_mode
    }

    /// Set the coordinator posture, driving the `⧉ coordinator` status chip.
    pub fn set_coordinator(&mut self, on: bool) {
        self.coordinator = on;
    }

    /// Whether coordinator mode is currently active.
    pub fn coordinator(&self) -> bool {
        self.coordinator
    }

    pub fn set_shell_count(&mut self, count: usize) {
        self.shell_count = count;
    }

    pub fn set_provider_info(&mut self, provider: &str, model: &str) {
        self.provider = provider.to_string();
        self.model_name = model.to_string();
    }

    /// The provider string this bar is rendering.
    ///
    /// Exposed so the startup banner can be built from the *same* fields the bar
    /// draws (see `App::identity`), rather than from a parallel copy that a
    /// future call site could forget to update. The two surfaces are on screen
    /// together; they must not be able to disagree.
    pub fn provider(&self) -> &str {
        &self.provider
    }

    /// The model string this bar is rendering. See [`Self::provider`].
    pub fn model_name(&self) -> &str {
        &self.model_name
    }

    pub fn set_signal(&mut self, signal: Signal) {
        self.signal = Some(signal);
    }

    pub fn context_max_label(&self) -> String {
        if self.context_max >= 1_000_000 {
            format!("{}M context", self.context_max / 1_000_000)
        } else if self.context_max > 0 {
            format!("{}K context", self.context_max / 1024)
        } else {
            String::new()
        }
    }

    /// `max == 0` means "this source could not resolve the window", which is not
    /// the same claim as "the window is 0" and must never overwrite a window
    /// another source already resolved.
    ///
    /// It did. `/health` seeds the real `context_window` at boot, and a later
    /// `context_pressure` event whose `max_tokens` the backend could not fill in
    /// called straight through to `self.context_max = 0`. The renderer's
    /// unknown-window branch then took over mid-session, so ONE session showed
    /// `░░░░░░░░ 0% ctx` in one frame and `~80.8k ctx` in the next — the same
    /// fact, stated two incompatible ways, because a known denominator had been
    /// regressed to unknown. Forgetting a fact is not an update.
    pub fn set_context(&mut self, utilization: f64, estimated: u64, max: u64) {
        self.context_estimated = estimated;
        if max > 0 {
            self.context_max = max;
        }
        // With a window known (from this call or an earlier one), a zero ratio
        // reported alongside real tokens is a gap in the event, not a
        // measurement. Derive it rather than render a confident "0%".
        let utilization = if utilization <= 0.0 && self.context_max > 0 && estimated > 0 {
            estimated as f64 / self.context_max as f64
        } else {
            utilization
        };
        self.context_utilization = utilization.clamp(0.0, 1.0);
        self.recompute_warning();
    }

    /// Self-heal the context meter from the real last-request size.
    ///
    /// `input_tokens` on an LLM response is the full prompt that was sent
    /// (system + conversation + tool results) = the context actually in use.
    /// The dedicated `context_pressure` event is the authoritative source, but
    /// it does not fire on every provider/turn (e.g. streaming glm/openai-compat
    /// turns) — when it is absent the meter would otherwise stick at 0% while a
    /// real turn is clearly loaded. Deriving utilization from
    /// input_tokens/context_max here mirrors how Claude Code computes
    /// "context used" (the last request's token count over the window) and makes
    /// the meter self-correcting. No-op until we know the window size, so it can
    /// never regress a known value to 0.
    /// When the window is UNKNOWN (`context_max == 0`) the token count is still
    /// recorded — it is exactly what the statusline falls back to rendering
    /// ("~52k ctx") instead of a fabricated percentage. Only the ratio is
    /// skipped, because there is no honest denominator for it. Previously this
    /// bailed out entirely on an unknown window, which left `context_estimated`
    /// frozen at 0 and made the unknown-window readout impossible.
    pub fn note_input_tokens(&mut self, input_tokens: u64) {
        if input_tokens == 0 {
            return;
        }
        self.context_estimated = input_tokens;
        // The banner is derived from the same committed total as the bar, so a
        // self-heal that moves one moves both. Deliberately BEFORE the
        // unknown-window bail-out: the warning thresholds are absolute token
        // counts and do not need `context_max`, so a session that never
        // resolved a window still gets an honest banner.
        self.recompute_warning();

        if self.context_max == 0 {
            return;
        }

        self.context_utilization =
            (input_tokens as f64 / self.context_max as f64).clamp(0.0, 1.0);
    }

    /// Current context utilization ratio (0.0..=1.0), for mirroring into the
    /// sidebar meter so both surfaces agree.
    pub fn context_ratio(&self) -> f64 {
        self.context_utilization
    }

    /// Set the live pending-input token estimate from the composer buffer. A
    /// transient overlay on the committed meter (see `display_context_ratio`);
    /// call with 0 on submit / clear. Never touches `context_utilization`, so
    /// the committed truth the backend owns is preserved.
    pub fn set_pending_input_tokens(&mut self, tokens: u64) {
        self.pending_input_tokens = tokens;
    }

    /// The current pending-input estimate (composer tokens not yet sent).
    pub fn pending_input_tokens(&self) -> u64 {
        self.pending_input_tokens
    }

    /// The context meter ratio to render: the committed utilization PLUS the
    /// live pending-input delta (composer tokens / window), clamped to 1.0. The
    /// delta is a transient overlay only — it never mutates `context_utilization`
    /// — so the bar grows as the user pastes and shrinks on send/clear while the
    /// committed value stays intact. No delta when the window is unknown
    /// (`context_max == 0`), which also avoids a divide-by-zero / fake percent.
    pub fn display_context_ratio(&self) -> f64 {
        let pending_ratio = if self.context_max > 0 {
            self.pending_input_tokens as f64 / self.context_max as f64
        } else {
            0.0
        };
        (self.context_utilization + pending_ratio).clamp(0.0, 1.0)
    }

    /// WS12 — CC TokenWarning parity fields from the backend's context_pressure
    /// event: percent of usable context left before auto-compact, and whether
    /// the low-context warning threshold has been crossed.
    ///
    /// `compact_at` / `warn_at` are the ABSOLUTE thresholds those two were
    /// derived from (0 == the backend could not resolve them). Storing them is
    /// what lets `recompute_warning` re-derive the banner from whatever total
    /// the bar currently holds, instead of leaving a cached percentage next to
    /// a fresher one — see `recompute_warning` for the reported screen.
    pub fn set_context_warning(
        &mut self,
        percent_left: Option<u32>,
        context_low: bool,
        compact_at: u64,
        warn_at: u64,
    ) {
        self.percent_left = percent_left;
        self.context_low = context_low;
        self.context_compact_at = compact_at;
        self.context_warn_at = warn_at;
    }

    /// Re-derive the low-context banner from the committed context total.
    ///
    /// The bar and the banner are two renderings of one fact, but they had
    /// different writers. `context_utilization` is refreshed by BOTH
    /// `set_context` (the `context_pressure` event) and `note_input_tokens`
    /// (every `LlmResponse`), because the pressure event does not fire on every
    /// provider/turn. `percent_left`/`context_low` had only the first. So a
    /// turn that self-healed the bar left the banner describing a superseded
    /// state — REPORTED LIVE, one frame, just after a compaction:
    ///
    /// ```text
    ///     Context low (6% remaining) · Run /compact to compact & continue
    ///     ⟐ grok-4.6 │ ⣿⢿░░░░░░ 15% ctx
    /// ```
    ///
    /// 15% used and 6% left cannot both be true. Deriving both from
    /// `context_estimated` makes that unrepresentable rather than merely fixed
    /// on one path.
    ///
    /// Mirrors `CompactionThresholds.warning_state/2`: `percent_left` is
    /// measured against `compact_at` and floored at 0; the band opens at
    /// `warn_at`. With no thresholds (older backend, or a window the backend
    /// could not resolve) there is nothing to derive from, so the reported
    /// values stand — this is the pre-existing behaviour for those backends.
    fn recompute_warning(&mut self) {
        if self.context_compact_at == 0 {
            return;
        }
        let tokens = self.context_estimated;
        let compact_at = self.context_compact_at;
        let left = compact_at.saturating_sub(tokens) as f64 / compact_at as f64 * 100.0;
        self.percent_left = Some(left.round() as u32);
        self.context_low = self.context_warn_at > 0 && tokens >= self.context_warn_at;
    }

    /// Whether the backend flagged low context (warning threshold crossed).
    pub fn context_low(&self) -> bool {
        self.context_low
    }

    /// Percent of usable context left before auto-compact, if reported.
    pub fn percent_left(&self) -> Option<u32> {
        self.percent_left
    }

    pub fn set_stats(&mut self, input: u64, output: u64, elapsed: u64) {
        self.input_tokens = input;
        self.output_tokens = output;
        self.elapsed_ms = elapsed;
    }

    /// Last-reported output tokens for the session's top-level turn — the token
    /// source for the synthetic `main` roster row (no cumulative per-session
    /// counter exists; this is the freshest LLM-response figure available).
    pub fn output_tokens(&self) -> u64 {
        self.output_tokens
    }

    pub fn set_active(&mut self, active: bool) {
        self.active = active;
    }

    pub fn set_iteration(&mut self, iteration: u32) {
        self.llm_iteration = iteration;
    }

    pub fn set_background_count(&mut self, count: usize) {
        self.bg_count = count;
    }

    pub fn set_width(&mut self, width: u16) {
        self.width = width;
    }

    pub fn set_recording(&mut self, recording: bool) {
        self.recording = recording;
        if !recording {
            self.audio_level = 0;
            self.recording_elapsed_secs = 0;
        }
    }

    pub fn set_transcribing(&mut self, transcribing: bool) {
        self.transcribing = transcribing;
    }

    pub fn set_recording_elapsed(&mut self, secs: u64) {
        self.recording_elapsed_secs = secs;
    }

    pub fn set_audio_level(&mut self, level: u8) {
        self.audio_level = level;
    }

    pub fn set_download_progress(&mut self, label: &str, pct: u8) {
        self.download_label = label.to_string();
        self.download_pct = pct;
    }

    pub fn clear_download_progress(&mut self) {
        self.download_label.clear();
        self.download_pct = 0;
    }

    pub fn set_hands_free(&mut self, enabled: bool) {
        self.hands_free = enabled;
    }

    pub fn context_utilization(&self) -> f64 {
        self.context_utilization
    }

    fn format_tokens(n: u64) -> String {
        if n >= 1000 {
            format!("{:.1}k", n as f64 / 1000.0)
        } else {
            n.to_string()
        }
    }

    /// Compact USD rendering: `$10` for whole amounts, `$0.42` otherwise. Keeps
    /// the billing chip terse so it survives on narrow panes.
    fn format_usd(amount: f64) -> String {
        if (amount.fract()).abs() < 0.005 {
            format!("${}", amount.round() as i64)
        } else {
            format!("${:.2}", amount)
        }
    }

    /// Build the billing chip text. For USD-priced providers this is a spend
    /// chip, e.g. `$0.42/$10 today` (or `$0.42 today` when there's no daily
    /// cap). For non-USD providers (e.g. glm) a dollar figure is meaningless, so
    /// we render token usage instead, e.g. `12.4k tok today`. Returns None when
    /// there's no billing data.
    fn billing_label(&self) -> Option<String> {
        let b = self.billing.as_ref()?;
        // Opt-in only. Provider pricing varies wildly — glm/Ollama have no USD
        // cost at all, and token counts aren't reported by every provider — so a
        // default spend/usage chip is meaningless and produced a broken
        // "0 tok today". Show the chip ONLY when the user has explicitly set a
        // daily USD budget, and only on a USD-priced provider where spend is
        // real. No budget configured → no chip.
        let limit = b.daily_limit_usd?;
        if !b.usd_pricing {
            return None;
        }
        let spent = Self::format_usd(b.daily_spent_usd);
        let base = format!("{}/{} today", spent, Self::format_usd(limit));
        // U-T25 — surface usage-% against the cap, e.g. "$8/$10 today (80%)".
        Some(match usage_pct(b.daily_spent_usd, Some(limit)) {
            Some(pct) => format!("{} ({}%)", base, pct),
            None => base,
        })
    }

    /// U-T25 — whether the daily spend has crossed the low-balance threshold
    /// (≥ 80% of the USD cap), so the billing chip renders as a warning. Always
    /// false for uncapped or non-USD providers (no cap to be low against).
    fn billing_low_balance(&self) -> bool {
        self.billing
            .as_ref()
            .filter(|b| b.usd_pricing)
            .and_then(|b| usage_pct(b.daily_spent_usd, b.daily_limit_usd))
            .map(is_low_balance)
            .unwrap_or(false)
    }

    /// Push signal mode pill + genre label into a span list.
    /// Renders as: ` · [ Code ] Spec` — mode in a colored pill, genre beside it.
    fn push_signal_pill<'a>(&'a self, spans: &mut Vec<Span<'a>>, theme: &style::Theme) {
        if let Some(ref signal) = self.signal {
            if !signal.mode.is_empty() {
                spans.push(Span::styled(" \u{00b7} ", theme.faint()));
                // Mode pill: " Mode " with colored background
                spans.push(Span::styled(
                    format!(" {} ", signal.mode),
                    theme.signal_pill(),
                ));
                // Genre label beside the pill
                if !signal.genre.is_empty() {
                    spans.push(Span::styled(
                        format!(" {}", signal.genre),
                        theme.signal_genre(),
                    ));
                }
                // Type indicator if present
                if !signal.signal_type.is_empty() {
                    spans.push(Span::styled(
                        format!(" \u{00b7} {}", signal.signal_type),
                        theme.faint(),
                    ));
                }
            }
        }
    }
}

impl Component for StatusBar {
    fn handle_event(&mut self, _event: &Event) -> ComponentAction {
        ComponentAction::Ignored
    }

    fn draw(&self, frame: &mut Frame, area: Rect) {
        let theme = style::theme();

        // Split into two rows: status line + permission/shell line.
        let rows = RLayout::default()
            .direction(Direction::Vertical)
            .constraints([Constraint::Length(1), Constraint::Length(1)])
            .split(area);
        // Reserve a 1-column right gutter on both status rows so the right-most
        // segment (version chip / bg counter) never clips mid-glyph against the
        // terminal edge — parity with draw_context_hint's gutter (edd66d5).
        let row0 = Rect { width: rows[0].width.saturating_sub(1), ..rows[0] };
        let row1 = rows
            .get(1)
            .map(|r| Rect { width: r.width.saturating_sub(1), ..*r })
            .unwrap_or(row0);
        let area = row0; // special-case single-line indicators render into row 0

        // Download progress indicator takes top priority
        if !self.download_label.is_empty() {
            let pct = self.download_pct;
            let bar_total = 20usize;
            let filled = (pct as usize * bar_total / 100).min(bar_total);
            let empty = bar_total - filled;
            let bar = format!("[{}{}]", "\u{2588}".repeat(filled), "\u{2591}".repeat(empty));
            let spans = vec![
                Span::styled(
                    format!("\u{21E9} Downloading {}: ", self.download_label),
                    Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD),
                ),
                Span::styled(bar, Style::default().fg(Color::Cyan)),
                Span::styled(format!(" {}%", pct), theme.progress_label()),
            ];
            let line = Line::from(spans);
            frame.render_widget(Paragraph::new(line), area);
            return;
        }

        // Recording indicator takes priority over everything
        if self.recording {
            let mins = self.recording_elapsed_secs / 60;
            let secs = self.recording_elapsed_secs % 60;
            let duration = format!(" {}:{:02}", mins, secs);

            let level = self.audio_level;
            let bar_total = 10usize;
            let filled = (level as usize * bar_total / 100).min(bar_total);
            let empty = bar_total - filled;
            let level_bar = format!("{}{}", "\u{2588}".repeat(filled), "\u{2591}".repeat(empty));
            let level_color = if level > 70 {
                Color::Red
            } else if level > 30 {
                Color::Green
            } else {
                Color::DarkGray
            };
            let mut spans = vec![
                Span::styled(
                    "\u{25C9} Recording",
                    Style::default().fg(Color::Red).add_modifier(Modifier::BOLD),
                ),
                Span::styled(duration, Style::default().fg(Color::Red)),
                Span::styled(" ", Style::default()),
                Span::styled(level_bar, Style::default().fg(level_color)),
            ];
            if self.hands_free {
                spans.push(Span::styled(
                    " \u{00b7} HF",
                    Style::default().fg(Color::Magenta).add_modifier(Modifier::BOLD),
                ));
                spans.push(Span::styled(" \u{2014} auto-stop on silence", theme.faint()));
            } else {
                spans.push(Span::styled(" \u{2014} click \u{25C9} to stop \u{00b7} Esc cancel", theme.faint()));
            }
            let line = Line::from(spans);
            frame.render_widget(Paragraph::new(line), area);
            return;
        }

        // Transcribing indicator — after recording stops, before result arrives
        if self.transcribing {
            let spans = vec![
                Span::styled(
                    "\u{27F3} Transcribing...",
                    Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD),
                ),
            ];
            let line = Line::from(spans);
            frame.render_widget(Paragraph::new(line), area);
            return;
        }

        // ── Row 0: Claude-Code status line ──────────────────────────────
        //   <glyph> MODEL  cwd │ ▣ mode │ <braille bar> P% ☆ [· signal] [· extras]
        let mut spans: Vec<Span<'_>> = Vec::new();

        // Leading glyph.
        spans.push(Span::styled("\u{27D0} ", theme.status_glyph())); // ⟐

        // MODEL name (fall back to provider) + cwd basename.
        let model_label = if !self.model_name.is_empty() {
            self.model_name.as_str()
        } else {
            self.provider.as_str()
        };
        if !model_label.is_empty() {
            spans.push(Span::styled(model_label.to_string(), theme.header_model()));
            spans.push(Span::raw("  "));
        }
        spans.push(Span::styled(self.cwd_basename.clone(), theme.header_provider()));

        // Session title — what this conversation is ABOUT, next to where it is.
        //
        // Budgeted, never unconditional. Row 0 has no global truncation: ratatui
        // simply clips at the right edge, so an unbudgeted label here would push
        // the context meter off-screen on a narrow pane — the meter is the one
        // segment that must always survive. So the title only spends what is
        // left after the segments already built and a reserve for the meter and
        // the trailing chips, and is dropped entirely when that is too little to
        // be worth reading.
        if let Some(title) = self.session_title.as_deref().filter(|t| !t.is_empty()) {
            // Budget off the ACTUAL draw rect, not `self.width`: the live app
            // never calls `set_width` (only test helpers and the inline-viewport
            // path do), so `self.width` is 0 in a real terminal and a
            // self.width-based budget would silently never render the title.
            let used: usize = spans.iter().map(|s| cols(s.content.as_ref())).sum();
            let budget = (area.width as usize)
                .saturating_sub(used)
                .saturating_sub(TITLE_RESERVE_COLS);
            if budget >= TITLE_MIN_COLS {
                let fitted = fit_cols(title, budget.min(TITLE_MAX_COLS));
                spans.push(Span::styled("  ", theme.status_sep()));
                spans.push(Span::styled(fitted, theme.header_model()));
            }
        }

        // Permission mode is shown exactly ONCE — on the ⏵⏵ line (row 1),
        // matching Claude Code's single mode indicator
        // (PromptInputFooterLeftSide.tsx: `{symbol} {title.toLowerCase()} on`).
        // The old row-0 "▣ mode" chip duplicated it (mode rendered twice) and has
        // been removed. The color binding is retained for row 1 and the bg chip.
        let mode_color = self.permission_mode.color(&theme);

        // Braille context-usage bar + percentage.
        spans.push(Span::styled(" \u{2502} ", theme.status_sep()));
        // Committed utilization + the live pending-composer delta, so the meter
        // grows as the user types/pastes and shrinks on send/clear. The pending
        // overlay never mutates the committed `context_utilization`.
        let disp_ratio = self.display_context_ratio();
        // Severity color grades the meter as it approaches the auto-compact
        // threshold (CC parity): primary < 75%, amber >= 75%, red >= 90% OR once
        // the backend flags the low-context warning band (`context_low`, keyed on
        // the real `warn_at` threshold). Both the filled bar and the percentage
        // share the color so the statusline telegraphs pressure at a glance.
        let ctx_color = if self.context_low {
            theme.colors.error
        } else {
            theme.context_bar_color(disp_ratio)
        };
        let pct_style = if self.context_low {
            Style::default().fg(ctx_color).add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(ctx_color)
        };

        // Unknown window (`context_max == 0`) — the backend could not honestly
        // resolve this model's context length, so there is no denominator and a
        // percentage would be fabricated. Render the TOKEN COUNT instead
        // ("~52k ctx"), with no bar and no percent.
        //
        // This is the case that made the meter read a permanent, flat `0% ctx`
        // while 52k tokens were demonstrably in use: every upstream path
        // (`utilization`, the derive fallback, `note_input_tokens`, the pending
        // overlay) is gated on a nonzero window and correctly declines to
        // invent one, so `disp_ratio` collapses to 0.0 — and the renderer had no
        // unknown-window branch, so it printed that 0.0 as a confident "0%".
        // A percentage that is always zero is worse than no percentage: it reads
        // as "context is empty" rather than "context size is unknown".
        if self.context_max == 0 {
            let tokens = self.context_estimated + self.pending_input_tokens;
            if tokens > 0 {
                spans.push(Span::styled(
                    format!("{} ctx", compact_tokens(tokens)),
                    pct_style,
                ));
            }
        } else {
            let (bar_filled, bar_empty) = braille_bar(disp_ratio, 8);
            if !bar_filled.is_empty() {
                spans.push(Span::styled(bar_filled, Style::default().fg(ctx_color)));
            }
            if !bar_empty.is_empty() {
                spans.push(Span::styled(bar_empty, theme.ctx_bar_empty()));
            }
            let pct = (disp_ratio * 100.0).round() as u32;
            // "N% ctx" — labelled like CC's "N% context used" so the number reads
            // as context occupancy (measured against the effective window
            // server-side).
            spans.push(Span::styled(format!(" {}% ctx", pct), pct_style));
        }

        // Large-paste hint: when the pending composer input is big enough to
        // matter (>= ~1000 tokens), surface its compact size (`+~12k`) in the
        // faint style so the user sees roughly how much they are about to add.
        // Below the threshold nothing is shown (no noise for short prompts).
        // Works even when the window is unknown (context_max == 0): the size
        // hint shows while the percentage stays honest at the committed value.
        if self.pending_input_tokens >= PENDING_HINT_MIN_TOKENS {
            spans.push(Span::styled(
                format!(" {}", pending_hint(self.pending_input_tokens)),
                theme.faint(),
            ));
        }

        // Decorative accent.
        spans.push(Span::styled(" \u{2606}", theme.status_glyph())); // ☆

        // Signal pill — still surfaced when classified.
        self.push_signal_pill(&mut spans, &theme);

        // NOTE: the turn elapsed timer is intentionally NOT rendered here. It
        // already lives in the Activity spinner row ("✳ Working… (12s · …)").
        // Rendering it a second time on the status bar produced the "two timers"
        // the user saw — elapsed now has exactly one home (the activity row).

        if self.hands_free {
            spans.push(Span::styled(" \u{2502} ", theme.status_sep()));
            spans.push(Span::styled(
                "HF",
                Style::default().fg(Color::Magenta).add_modifier(Modifier::BOLD),
            ));
        }

        // Active /goal auto-continue loop: "◎ goal N/max".
        if let Some(ref goal_label) = self.goal_label {
            spans.push(Span::styled(" \u{2502} ", theme.status_sep()));
            spans.push(Span::styled(
                format!("\u{25CE} {}", goal_label),
                Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD),
            ));
        }

        // Goal-verification indicator — the agent judging its own work. One
        // compact, understated chip tied to the goal line: dim for the common
        // verifying/on-track cases, warning for a gap, error for off-track.
        // Cleared on a new turn (submit_prompt). Glyphs degrade to plain ASCII
        // on legacy/a11y terminals via render::glyphs, so this never breaks.
        if let Some(ref gv) = self.goal_verify {
            use crate::render::glyphs;
            let legacy = matches!(glyphs::glyph_level(), glyphs::GlyphLevel::Legacy);
            spans.push(Span::styled(" \u{2502} ", theme.status_sep()));
            match gv {
                GoalVerifyState::Verifying => {
                    let sym = if legacy { "?" } else { "\u{2047}" }; // ⁇
                    spans.push(Span::styled(
                        format!("{} verifying goal\u{2026}", sym),
                        theme.faint(),
                    ));
                }
                GoalVerifyState::OnTrack => {
                    spans.push(Span::styled(
                        format!("{} on-track", glyphs::check()),
                        theme.faint(),
                    ));
                }
                GoalVerifyState::Incomplete {
                    refuted,
                    total,
                    gaps,
                } => {
                    let sym = if legacy { "!" } else { "\u{26A0}" }; // ⚠
                    // Only genuine, user-meaningful findings are countable or
                    // showable. Harness diagnostics ("unparsable skeptic
                    // response", "skeptic failed: :timeout") are filtered out
                    // by the backend already; this is defence in depth so an
                    // internal detail can never become a user-facing badge.
                    let shown: Vec<&str> = displayable_gaps(gaps);
                    let mut label = if shown.is_empty() {
                        // Nothing meaningful to name — say the useful thing
                        // (the goal is not confirmed done) rather than "0 gaps".
                        format!("{} {}/{} \u{00b7} goal not confirmed", sym, refuted, total)
                    } else {
                        let plural = if shown.len() == 1 { "" } else { "s" };
                        format!(
                            "{} {}/{} \u{00b7} {} gap{}",
                            sym,
                            refuted,
                            total,
                            shown.len(),
                            plural
                        )
                    };
                    // Only name the first gap when the pane is wide enough that
                    // it won't crowd the line — the chip stays one line, compact.
                    // Ellipsized on a WORD boundary in DISPLAY COLUMNS (never
                    // bytes/chars), so it can never render as `… (fai…`.
                    if let Some(first) = first_gap_label(&shown, self.width) {
                        label.push_str(&format!(" \u{00b7} {}", first));
                    }
                    spans.push(Span::styled(
                        label,
                        Style::default().fg(theme.colors.warning),
                    ));
                }
                GoalVerifyState::OffTrack => {
                    spans.push(Span::styled(
                        format!("{} off-track", glyphs::cross()),
                        Style::default().fg(theme.colors.error),
                    ));
                }
            }
        }

        // Reasoning-effort chip (`effort:medium`). Faint for fast/medium; the
        // heavier high/xhigh/ultra tiers get the accent color so a costly setting
        // is visible at a glance. Omitted entirely when the backend didn't report.
        if let Some(ref effort) = self.effort {
            spans.push(Span::styled(" \u{2502} ", theme.status_sep()));
            let heavy = matches!(effort.as_str(), "high" | "xhigh" | "ultra");
            let style = if heavy {
                Style::default()
                    .fg(theme.colors.primary)
                    .add_modifier(Modifier::BOLD)
            } else {
                theme.faint()
            };
            spans.push(Span::styled(format!("effort:{}", effort), style));
        }

        // MCP chip (`3 MCP`). U-T26. Omitted when no servers.
        if let Some(mcp) = mcp_label(self.mcp_count) {
            spans.push(Span::styled(" \u{2502} ", theme.status_sep()));
            let style = Style::default().fg(theme.colors.primary);
            spans.push(Span::styled(mcp, style));
        }

        // Hook chip (`hooks 54 ok, 19 failed`). Omitted until a hook has run.
        // Coloured by the failure count rather than by category: quiet while
        // everything passes, error-toned the moment one did not, because that is
        // the only state where the number is worth reading.
        if let Some(hooks) = hooks_label(self.hooks_ok, self.hooks_failed) {
            spans.push(Span::styled(" \u{2502} ", theme.status_sep()));
            let style = if self.hooks_failed > 0 {
                Style::default().fg(theme.colors.error)
            } else {
                theme.faint()
            };
            spans.push(Span::styled(hooks, style));
        }

        // Swarm-intelligence chip (`swarm · round 3`). U-B5. Omitted when idle.
        if let Some(ref swarm) = self.swarm_label {
            spans.push(Span::styled(" \u{2502} ", theme.status_sep()));
            spans.push(Span::styled(
                format!("\u{273b} {}", swarm),
                Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD),
            ));
        }

        // Billing chip (`$0.42/$10 today (80%)`). Omitted when billing is absent.
        // U-T25 — turns to a warning color + "low balance" hint at ≥ 80% of cap.
        if let Some(billing_label) = self.billing_label() {
            let low = self.billing_low_balance();
            spans.push(Span::styled(" \u{2502} ", theme.status_sep()));
            let bill_style = if low {
                Style::default()
                    .fg(theme.colors.error)
                    .add_modifier(Modifier::BOLD)
            } else {
                theme.progress_label()
            };
            spans.push(Span::styled(billing_label, bill_style));
            if low {
                spans.push(Span::styled(
                    " \u{26A0} low balance",
                    Style::default()
                        .fg(theme.colors.error)
                        .add_modifier(Modifier::BOLD),
                ));
            }

            // Subscription/plan tier — only when non-null (always null today,
            // so effectively skipped, but wired for the day a plan exists).
            if let Some(plan) = self
                .billing
                .as_ref()
                .and_then(|b| b.subscription.as_ref())
                .filter(|p| !p.trim().is_empty())
            {
                spans.push(Span::styled(
                    format!(" {}", plan),
                    Style::default()
                        .fg(theme.colors.primary)
                        .add_modifier(Modifier::BOLD),
                ));
            }
        }

        // Update-available chip (`⬆ vX`). Understated: dim, no color alarm, and
        // dropped entirely once there's no newer release. Sits just left of the
        // version chip so "v{current} → ⬆ v{latest}" reads together. The user
        // runs `/update` (see the one-time startup transcript notice).
        if let Some(ref latest) = self.update_latest {
            spans.push(Span::styled(" \u{2502} ", theme.status_sep()));
            spans.push(Span::styled(format!("\u{2B06} v{}", latest), theme.faint()));
        }

        // Persistent OSA version chip (single build-time source — never stale).
        // Right-most element so it's the first to be clipped on narrow panes.
        spans.push(Span::styled(" \u{2502} ", theme.status_sep()));
        spans.push(Span::styled(
            format!("v{}", crate::config::osa_version_display()),
            theme.faint(),
        ));

        frame.render_widget(
            Paragraph::new(Line::from(spans)).style(theme.status_bar()),
            row0,
        );

        // ── Row 1: permission / shell / background line ─────────────────
        //   ⏵⏵ bypass permissions on · N shells · N bg
        // Shells and backgrounded turns are distinct: shells are running `!`
        // commands; "N bg" is Ctrl+B'd turns still running (brought back via /fg).
        let shells = self.shell_count;
        let bg = self.bg_count;

        // Build the trailing "· N shells · N bg" fragment once, reused below.
        let mut extras: Vec<Span<'_>> = Vec::new();
        // Coordinator posture chip: a compact, understated `⧉ coordinator` shown
        // only while active. Distinct glyph from the permission-mode indicator so
        // the two never collide. Placed first among the extras so it reads next to
        // the mode label on the ⏵⏵ row.
        if self.coordinator {
            extras.push(Span::styled(" \u{00b7} ", theme.status_sep()));
            extras.push(Span::styled(
                "\u{29C9} coordinator",
                Style::default().fg(theme.colors.primary),
            ));
        }
        // U-T23 — when idle, frame background work as a single "watching" cue
        // (monitors = running background shells, loops = backgrounded turns)
        // instead of the raw in-turn shells/bg detail. During a live turn the
        // raw counts are more useful, so keep them then.
        if !self.active {
            if let Some(label) = watcher_label(shells, bg) {
                extras.push(Span::styled(" \u{00b7} ", theme.status_sep()));
                extras.push(Span::styled(format!("\u{2299} {}", label), theme.faint()));
            }
        } else {
            if shells > 0 {
                extras.push(Span::styled(" \u{00b7} ", theme.status_sep()));
                let label = if shells == 1 {
                    "1 shell".to_string()
                } else {
                    format!("{} shells", shells)
                };
                extras.push(Span::styled(label, theme.faint()));
            }
            if bg > 0 {
                extras.push(Span::styled(" \u{00b7} ", theme.status_sep()));
                extras.push(Span::styled(
                    format!("{} bg", bg),
                    Style::default().fg(mode_color),
                ));
            }
        }

        // U-T28 — compact sub-agent footer cue: count, estimated cost, and the
        // "↓ manage" nav hint into the existing agents dashboard. Shown whenever
        // sub-agents are active (idle or mid-turn).
        if self.subagent_count > 0 {
            extras.push(Span::styled(" \u{00b7} ", theme.status_sep()));
            let plural = if self.subagent_count == 1 { "" } else { "s" };
            let mut label = format!("\u{25C7} {} subagent{}", self.subagent_count, plural);
            if let Some(cost) = self.subagent_cost.filter(|c| *c > 0.0) {
                label.push_str(&format!(" \u{00b7} {}", Self::format_usd(cost)));
            }
            extras.push(Span::styled(
                label,
                Style::default().fg(theme.colors.primary),
            ));
            // CC FleetView nav hints: while the roster is focused
            // (`← for agents` pressed) show the per-row actions; otherwise
            // advertise how to open the roster / the full dashboard.
            let hint = if self.fleet_select {
                " \u{00b7} Enter to view \u{00b7} x to stop"
            } else {
                " \u{00b7} \u{2190} for agents \u{00b7} \u{2193} manage"
            };
            extras.push(Span::styled(hint, theme.faint()));
        }

        if !self.permission_mode.is_default() {
            let mut pspans: Vec<Span<'_>> = Vec::new();
            let sym = self.permission_mode.symbol();
            if !sym.is_empty() {
                pspans.push(Span::styled(
                    format!("{} ", sym),
                    Style::default().fg(mode_color),
                ));
            }
            pspans.push(Span::styled(
                format!("{} on", self.permission_mode.title().to_lowercase()),
                Style::default().fg(mode_color),
            ));
            pspans.extend(extras);
            frame.render_widget(Paragraph::new(Line::from(pspans)), row1);
        } else if !extras.is_empty() {
            // Default mode but shells / background turns running — surface them.
            // Drop the leading " · " separator since there's no mode prefix.
            if let Some(first) = extras.first() {
                if first.content.trim() == "\u{00b7}" {
                    extras.remove(0);
                }
            }
            frame.render_widget(Paragraph::new(Line::from(extras)), row1);
        }
    }
}

#[cfg(test)]
mod status_bar_tests {
    use super::*;

    #[test]
    fn cwd_path_shows_basename_and_home_tilde() {
        let mut sb = StatusBar::new();
        sb.set_cwd_path("/home/user/projects/osa/OSA");
        assert_eq!(sb.cwd_basename, "OSA");
        // A trailing slash still yields the folder name.
        sb.set_cwd_path("/home/user/projects/osa/OSA/");
        assert_eq!(sb.cwd_basename, "OSA");
        // A blank path leaves the label untouched.
        sb.set_cwd_path("   ");
        assert_eq!(sb.cwd_basename, "OSA");
        // The home directory collapses to "~".
        if let Ok(home) = std::env::var("HOME") {
            if !home.is_empty() {
                sb.set_cwd_path(&home);
                assert_eq!(sb.cwd_basename, "~");
            }
        }
    }

    #[test]
    fn context_warning_roundtrip() {
        let mut sb = StatusBar::new();
        assert!(!sb.context_low());
        assert_eq!(sb.percent_left(), None);
        // No thresholds (0/0) — the reported values are stored verbatim, which
        // is the older-backend path.
        sb.set_context_warning(Some(18), true, 0, 0);
        assert!(sb.context_low());
        assert_eq!(sb.percent_left(), Some(18));
        // A fresh report after compaction clears both.
        sb.set_context_warning(None, false, 0, 0);
        assert!(!sb.context_low());
        assert_eq!(sb.percent_left(), None);
    }

    /// The reported screen: `Context low (6% remaining)` above a bar reading
    /// `15% ctx`, in one frame, right after a compaction.
    ///
    /// The bar self-heals from every `LlmResponse` (`note_input_tokens`); the
    /// banner only ever had the `context_pressure` event. So a fold followed by
    /// a smaller request moved one and not the other. Both are now derived from
    /// the committed total, so the disagreement cannot be constructed.
    #[test]
    fn the_low_context_banner_cannot_outlive_the_bar() {
        let mut sb = StatusBar::new();
        // grok-4.6: operative window 200k → compact_at 167k, warn_at 147k.
        sb.set_context_warning(Some(6), true, 167_000, 147_000);
        sb.set_context(0.875, 157_500, 180_000);
        assert!(sb.context_low(), "precondition: the band is open at 157.5k");

        // The next request after the fold is small. Only `note_input_tokens`
        // carries it — no `context_pressure` event has fired yet.
        sb.note_input_tokens(29_300);

        assert!(
            !sb.context_low(),
            "the low-context banner survived a fold that emptied the context"
        );
        let left = sb.percent_left().expect("percent_left must be derivable");
        assert!(
            left > 80,
            "percent_left still reads {left}% with 29.3k of a 167k budget in use"
        );
    }

    /// The banner is derived even when the window is unknown, because the
    /// thresholds are absolute token counts and do not need a denominator.
    #[test]
    fn the_banner_is_derived_without_a_known_window() {
        let mut sb = StatusBar::new();
        sb.set_context_warning(Some(3), true, 167_000, 147_000);
        sb.note_input_tokens(10_000);
        assert!(!sb.context_low());
        assert_eq!(sb.percent_left(), Some(94));
    }

    #[test]
    fn context_meter_self_heals_from_input_tokens() {
        let mut sb = StatusBar::new();
        // Window known (e.g. from ModelChanged), but no context_pressure event yet.
        sb.set_context(0.0, 0, 200_000);
        assert_eq!(sb.context_ratio(), 0.0);
        // A real LLM response arrives with the prompt size: meter must reflect it
        // instead of sticking at 0% (the live bug).
        sb.note_input_tokens(42_000);
        assert!((sb.context_ratio() - 0.21).abs() < 0.01);
        // A zero/unknown input never regresses a known value back to 0.
        sb.note_input_tokens(0);
        assert!((sb.context_ratio() - 0.21).abs() < 0.01);
        // No window size yet -> no-op (avoids divide-by-zero / bogus 100%).
        let mut fresh = StatusBar::new();
        fresh.note_input_tokens(5_000);
        assert_eq!(fresh.context_ratio(), 0.0);
    }

    /// Render the two-row status bar for `mode` and flatten its cells to a
    /// single string (parity with event_loop's buffer-content harness).
    fn render_status_text(mode: PermissionMode) -> String {
        use ratatui::{backend::TestBackend, Terminal};
        let mut sb = StatusBar::new();
        sb.set_permission_mode(mode);
        sb.set_width(120);
        let mut term = Terminal::new(TestBackend::new(120, 2)).unwrap();
        term.draw(|f| sb.draw(f, f.area())).unwrap();
        term.backend()
            .buffer()
            .content()
            .iter()
            .map(|c| c.symbol())
            .collect()
    }

    /// Render row 0 at `width` with an optional session title and flatten it.
    fn render_title_row(width: u16, title: Option<&str>) -> String {
        use ratatui::{backend::TestBackend, Terminal};
        let mut sb = StatusBar::new();
        sb.set_width(width);
        sb.set_provider_info("anthropic", "claude-opus-4");
        sb.set_cwd_path("/home/dev/OSA");
        sb.set_context(0.6, 120_000, 200_000);
        sb.set_session_title(title.map(|t| t.to_string()));
        let mut term = Terminal::new(TestBackend::new(width, 2)).unwrap();
        term.draw(|f| sb.draw(f, f.area())).unwrap();
        let buf = term.backend().buffer().clone();
        // Row 0 only.
        (0..width)
            .map(|x| buf[(x, 0)].symbol().to_string())
            .collect()
    }

    #[test]
    fn session_title_renders_in_the_status_bar() {
        let row = render_title_row(120, Some("Debugging production 500 errors"));
        assert!(
            row.contains("Debugging production 500 errors"),
            "title missing from status row: {row:?}"
        );
    }

    #[test]
    fn session_title_setter_normalizes_blanks() {
        let mut sb = StatusBar::new();
        sb.set_session_title(Some("   ".to_string()));
        assert_eq!(sb.session_title(), None);
        sb.set_session_title(Some("  Rate limiting  ".to_string()));
        assert_eq!(sb.session_title(), Some("Rate limiting"));
        sb.set_session_title(None);
        assert_eq!(sb.session_title(), None);
    }

    #[test]
    fn session_title_never_displaces_the_context_meter() {
        // Row 0 has no global truncation — ratatui clips at the right edge. The
        // context meter is the segment that must always survive, and the PTY
        // harness keys its `status` band on "ctx". A title must never push it
        // off, at ANY width, however long the title is.
        let long = "An extremely long session title that would happily eat the whole row";
        for width in [40u16, 60, 72, 80, 100, 120, 160, 200] {
            let with = render_title_row(width, Some(long));
            assert!(
                with.contains("ctx"),
                "context meter clipped at width {width}: {with:?}"
            );
        }
    }

    #[test]
    fn session_title_is_omitted_when_there_is_no_room() {
        // A narrow pane drops the title entirely rather than rendering a stub.
        // 60 columns is the verified boundary: it omits, 80 shows it in full.
        for width in [40u16, 60] {
            let narrow = render_title_row(width, Some("Debugging production 500 errors"));
            assert!(
                !narrow.contains("Debugging"),
                "width {width} rendered a title stub: {narrow:?}"
            );
            assert!(narrow.contains("ctx"));
        }
        assert!(render_title_row(80, Some("Debugging production 500 errors"))
            .contains("Debugging production 500 errors"));
    }

    #[test]
    fn untitled_session_adds_nothing_to_the_row() {
        // No title ⇒ byte-identical row, i.e. no stray separator is emitted.
        assert_eq!(render_title_row(120, None), render_title_row(120, Some("")));
    }

    #[test]
    fn permission_mode_renders_exactly_once() {
        // The mode label must appear once (the ⏵⏵…on line, CC-parity), never
        // twice. Before the fix a "▣ mode" chip on row 0 duplicated it.
        for (mode, label) in [
            (PermissionMode::BypassPermissions, "overdrive (full auto)"),
            (PermissionMode::AcceptEdits, "auto-edit"),
            (PermissionMode::Plan, "plan mode"),
        ] {
            let text = render_status_text(mode);
            assert_eq!(
                text.matches(label).count(),
                1,
                "mode {:?} label {:?} must render exactly once, got: {:?}",
                mode,
                label,
                text
            );
        }
        // The removed row-0 chip glyph (▣) must never appear.
        assert!(
            !render_status_text(PermissionMode::BypassPermissions).contains('\u{25A3}'),
            "the duplicate ▣ mode chip must be gone"
        );
        // Default (ask) mode shows no persistent mode banner at all (CC hides it).
        let def = render_status_text(PermissionMode::Default);
        assert!(!def.contains("ask on"), "default mode must not print a mode banner");
    }

    /// Render the status bar with a coordinator flag and flatten to a string.
    fn render_with_coordinator(on: bool) -> String {
        use ratatui::{backend::TestBackend, Terminal};
        let mut sb = StatusBar::new();
        sb.set_coordinator(on);
        sb.set_width(120);
        let mut term = Terminal::new(TestBackend::new(120, 2)).unwrap();
        term.draw(|f| sb.draw(f, f.area())).unwrap();
        term.backend()
            .buffer()
            .content()
            .iter()
            .map(|c| c.symbol())
            .collect()
    }

    #[test]
    fn coordinator_chip_renders_only_when_active() {
        let mut sb = StatusBar::new();
        assert!(!sb.coordinator());
        sb.set_coordinator(true);
        assert!(sb.coordinator());

        // Active: the compact `⧉ coordinator` chip is present.
        let on = render_with_coordinator(true);
        assert!(
            on.contains("coordinator") && on.contains('\u{29C9}'),
            "coordinator chip must render when active, got: {:?}",
            on
        );

        // Inactive: no chip.
        let off = render_with_coordinator(false);
        assert!(
            !off.contains("coordinator"),
            "coordinator chip must be hidden when inactive, got: {:?}",
            off
        );
    }

    #[test]
    fn fmt_elapsed_compact_boundaries() {
        // Codex parity: bare seconds under a minute, zero-padded seconds under an
        // hour, zero-padded minutes+seconds at/above an hour.
        assert_eq!(fmt_elapsed_compact(0), "0s");
        assert_eq!(fmt_elapsed_compact(12), "12s");
        assert_eq!(fmt_elapsed_compact(59), "59s"); // just under the minute wall
        assert_eq!(fmt_elapsed_compact(60), "1m 00s"); // the minute wall
        assert_eq!(fmt_elapsed_compact(220), "3m 40s"); // the doc example
        assert_eq!(fmt_elapsed_compact(3599), "59m 59s"); // just under the hour
        assert_eq!(fmt_elapsed_compact(3600), "1h 00m 00s"); // the hour wall
        assert_eq!(fmt_elapsed_compact(3922), "1h 05m 22s"); // the doc example
    }

    #[test]
    fn usage_pct_and_low_balance() {
        // U-T25 — usage % against the daily cap, divide-by-zero/uncapped safe.
        assert_eq!(usage_pct(8.0, Some(10.0)), Some(80));
        assert_eq!(usage_pct(2.5, Some(10.0)), Some(25));
        assert_eq!(usage_pct(12.0, Some(10.0)), Some(100)); // clamp over-cap
        assert_eq!(usage_pct(5.0, None), None); // uncapped ⇒ no %
        assert_eq!(usage_pct(5.0, Some(0.0)), None); // div0 guard
        assert!(!is_low_balance(79));
        assert!(is_low_balance(80));
        assert!(is_low_balance(100));
    }

    #[test]
    fn watcher_and_mcp_labels() {
        // U-T23 — watcher cue names monitors + loops, pluralized; None when idle.
        assert_eq!(watcher_label(0, 0), None);
        assert_eq!(watcher_label(1, 0).unwrap(), "watching \u{00b7} 1 monitor");
        assert_eq!(watcher_label(2, 0).unwrap(), "watching \u{00b7} 2 monitors");
        assert_eq!(watcher_label(0, 1).unwrap(), "watching \u{00b7} 1 loop");
        assert_eq!(
            watcher_label(3, 2).unwrap(),
            "watching \u{00b7} 3 monitors \u{00b7} 2 loops"
        );
        // U-T26 — MCP chip: count when non-zero, else nothing.
        assert_eq!(mcp_label(0), None);
        assert_eq!(mcp_label(3).unwrap(), "3 MCP");
    }

    #[test]
    fn billing_usage_pct_renders_in_label() {
        // U-T25 — the daily label carries the usage-% and low-balance state.
        use crate::client::types::HealthBilling;
        let mut sb = StatusBar::new();
        sb.set_billing(Some(HealthBilling {
            daily_spent_usd: 8.0,
            daily_limit_usd: Some(10.0),
            monthly_spent_usd: 0.0,
            monthly_limit_usd: None,
            currency: "USD".into(),
            subscription: None,
            daily_tokens: 0,
            usd_pricing: true,
        }));
        assert_eq!(sb.billing_label().as_deref(), Some("$8/$10 today (80%)"));
        assert!(sb.billing_low_balance(), "80% of cap is low balance");
        // Opt-in: no budget configured → the chip is HIDDEN entirely. Provider
        // pricing varies too much for a default spend figure to mean anything.
        sb.set_billing(Some(HealthBilling {
            daily_spent_usd: 3.0,
            daily_limit_usd: None,
            monthly_spent_usd: 0.0,
            monthly_limit_usd: None,
            currency: "USD".into(),
            subscription: None,
            daily_tokens: 0,
            usd_pricing: true,
        }));
        assert_eq!(sb.billing_label(), None, "no budget set → no chip");
        assert!(!sb.billing_low_balance());
        // Non-USD provider (glm/Ollama): no USD cost → no chip, even if a limit
        // leaked through. This is the fix for the broken "0 tok today".
        sb.set_billing(Some(HealthBilling {
            daily_spent_usd: 0.0,
            daily_limit_usd: Some(10.0),
            monthly_spent_usd: 0.0,
            monthly_limit_usd: None,
            currency: "".into(),
            subscription: None,
            daily_tokens: 5000,
            usd_pricing: false,
        }));
        assert_eq!(sb.billing_label(), None, "non-USD provider → no chip");
    }

    /// Flatten a fully-configured StatusBar's cells to one string.
    fn render_sb(sb: &StatusBar) -> String {
        use ratatui::{backend::TestBackend, Terminal};
        let mut term = Terminal::new(TestBackend::new(120, 2)).unwrap();
        term.draw(|f| sb.draw(f, f.area())).unwrap();
        term.backend()
            .buffer()
            .content()
            .iter()
            .map(|c| c.symbol())
            .collect()
    }

    #[test]
    fn watcher_cue_shows_only_when_idle() {
        // U-T23 — idle + background work ⇒ watcher cue; active ⇒ raw detail.
        let mut sb = StatusBar::new();
        sb.set_width(120);
        sb.set_shell_count(2);
        sb.set_background_count(1);
        sb.set_active(false);
        let idle = render_sb(&sb);
        assert!(idle.contains("watching"), "idle watcher cue must render, got: {idle:?}");
        assert!(idle.contains("2 monitors") && idle.contains("1 loop"));

        sb.set_active(true);
        let busy = render_sb(&sb);
        assert!(!busy.contains("watching"), "no watcher cue during a turn");
        assert!(busy.contains("2 shells"), "raw shells detail shows mid-turn");
    }

    #[test]
    fn subagent_footer_and_mcp_swarm_chips_render() {
        // U-T28 / U-T26 / U-B5 — chips surface when their state is set.
        let mut sb = StatusBar::new();
        sb.set_width(120);
        sb.set_subagents(3, Some(0.42));
        sb.set_mcp(2);
        sb.set_swarm(Some("swarm \u{00b7} round 4".to_string()));
        let text = render_sb(&sb);
        assert!(text.contains("3 subagents"), "subagent footer, got: {text:?}");
        assert!(text.contains("$0.42"), "subagent cost");
        assert!(text.contains("manage"), "nav hint");
        assert!(text.contains("2 MCP"), "MCP chip");
        assert!(text.contains("round 4"), "swarm chip");
        // Cleared state drops the chips.
        sb.set_subagents(0, None);
        sb.set_mcp(0);
        sb.set_swarm(None);
        let cleared = render_sb(&sb);
        assert!(!cleared.contains("subagents") && !cleared.contains("MCP"));
    }

    #[test]
    fn fleet_select_hint_switches_between_idle_and_roster_focus() {
        // G — the footer cue swaps `← for agents · ↓ manage` (idle) for the
        // per-row `Enter to view · x to stop` action hint while the roster is
        // focused. Both only render alongside the sub-agent footer (count > 0).
        let mut sb = StatusBar::new();
        sb.set_width(120);
        sb.set_subagents(2, None);

        // Idle roster: advertise how to open it + the full dashboard.
        sb.set_fleet_select(false);
        let idle = render_sb(&sb);
        assert!(idle.contains("for agents"), "idle hint present, got: {idle:?}");
        assert!(idle.contains("manage"), "idle hint advertises ↓ manage");
        assert!(!idle.contains("Enter to view"), "no action hint when unfocused");

        // Roster focused (`←` pressed): show the per-row actions instead.
        sb.set_fleet_select(true);
        let focused = render_sb(&sb);
        assert!(focused.contains("Enter to view"), "focused action hint, got: {focused:?}");
        assert!(focused.contains("x to stop"), "focused stop hint");
        assert!(!focused.contains("manage"), "idle hint is replaced when focused");
    }

    #[test]
    fn update_chip_renders_only_when_available() {
        use crate::client::types::HealthUpdate;
        let mut sb = StatusBar::new();
        sb.set_width(120);

        // No update reported → no chip.
        sb.set_update_available(None);
        assert_eq!(sb.update_latest(), None);
        assert!(!render_sb(&sb).contains("\u{2B06}"), "no ⬆ chip when absent");

        // available:false (up to date / source build) → still no chip.
        sb.set_update_available(Some(HealthUpdate {
            available: false,
            current_version: "0.4.6".into(),
            latest_version: Some("0.5.0".into()),
        }));
        assert_eq!(sb.update_latest(), None);
        assert!(!render_sb(&sb).contains("\u{2B06}"), "no chip when not available");

        // available:true → compact "⬆ vX" chip appears.
        sb.set_update_available(Some(HealthUpdate {
            available: true,
            current_version: "0.4.6".into(),
            latest_version: Some("0.5.0".into()),
        }));
        assert_eq!(sb.update_latest(), Some("0.5.0"));
        let text = render_sb(&sb);
        assert!(text.contains("\u{2B06}"), "⬆ chip must render, got: {text:?}");
        assert!(text.contains("v0.5.0"), "chip shows latest version");

        // Cleared again once the backend reports no update.
        sb.set_update_available(None);
        assert!(!render_sb(&sb).contains("\u{2B06}"), "chip disappears when cleared");
    }

    #[test]
    fn goal_verification_indicator_renders_per_verdict_and_clears() {
        let mut sb = StatusBar::new();
        sb.set_width(120);

        // No verifier state → no indicator.
        let none = render_sb(&sb);
        assert!(!none.contains("verifying") && !none.contains("on-track"));

        // Verifying (start phase) → dim "verifying goal…".
        sb.set_goal_verification(Some(GoalVerifyState::Verifying));
        assert!(render_sb(&sb).contains("verifying goal"), "verifying chip");

        // On-track (complete) → brief "on-track".
        sb.set_goal_verification(Some(GoalVerifyState::OnTrack));
        assert!(render_sb(&sb).contains("on-track"), "on-track chip");

        // Incomplete with gaps → "1/3 · 1 gap" plus the first gap label (wide pane).
        sb.set_goal_verification(Some(GoalVerifyState::Incomplete {
            refuted: 2,
            total: 3,
            gaps: vec!["[completeness] error handling".to_string()],
        }));
        let inc = render_sb(&sb);
        assert!(inc.contains("2/3"), "refuted/total, got: {inc:?}");
        assert!(inc.contains("1 gap"), "gap count");
        assert!(inc.contains("completeness"), "first gap label shown on wide pane");

        // Off-track → "off-track".
        sb.set_goal_verification(Some(GoalVerifyState::OffTrack));
        assert!(render_sb(&sb).contains("off-track"), "off-track chip");

        // Cleared → indicator gone.
        sb.set_goal_verification(None);
        let cleared = render_sb(&sb);
        assert!(!cleared.contains("off-track") && !cleared.contains("verifying"));
    }

    #[test]
    fn goal_verification_gap_count_pluralizes() {
        let mut sb = StatusBar::new();
        sb.set_width(120);
        sb.set_goal_verification(Some(GoalVerifyState::Incomplete {
            refuted: 3,
            total: 3,
            gaps: vec![
                "[correctness] wrong branch".to_string(),
                "[verifiability] no test".to_string(),
            ],
        }));
        assert!(render_sb(&sb).contains("2 gaps"), "plural gaps");
    }

    /// The reported regression: a parse failure was leaking onto the status bar
    /// as a `⚠ … [correctness] unparsable skeptic response (fai…` badge. An
    /// internal diagnostic must never be shown, counted, or half-rendered.
    #[test]
    fn internal_diagnostics_never_reach_the_status_bar() {
        let mut sb = StatusBar::new();
        sb.set_width(120);
        sb.set_goal_verification(Some(GoalVerifyState::Incomplete {
            refuted: 3,
            total: 3,
            gaps: vec![
                "[correctness] unparsable skeptic response (fail-closed): blah blah".to_string(),
                "[verifiability] skeptic failed: :timeout".to_string(),
            ],
        }));
        let text = render_sb(&sb);
        assert!(!text.contains("unparsable"), "parse failure leaked: {text:?}");
        assert!(!text.contains("fail-closed"), "internal marker leaked: {text:?}");
        assert!(!text.contains("skeptic failed"), "internal marker leaked: {text:?}");
        assert!(!text.contains("(fai"), "mid-word cut of an internal string: {text:?}");
        // Nothing meaningful to name ⇒ say so, never "0 gaps".
        assert!(!text.contains("0 gap"), "must not report zero gaps: {text:?}");
        assert!(text.contains("goal not confirmed"), "meaningful fallback: {text:?}");
        assert!(text.contains("3/3"), "vote counts still shown: {text:?}");
    }

    /// A mix of real findings and diagnostics counts and shows ONLY the real ones.
    #[test]
    fn gap_count_excludes_internal_diagnostics() {
        let mut sb = StatusBar::new();
        sb.set_width(120);
        sb.set_goal_verification(Some(GoalVerifyState::Incomplete {
            refuted: 2,
            total: 3,
            gaps: vec![
                "[correctness] unparsable skeptic response".to_string(),
                "[completeness] exporter drops the header row".to_string(),
            ],
        }));
        let text = render_sb(&sb);
        assert!(text.contains("1 gap"), "only the real finding counts: {text:?}");
        assert!(!text.contains("1 gaps"), "singular for one gap: {text:?}");
        assert!(text.contains("completeness"), "real finding is named: {text:?}");
        assert!(!text.contains("unparsable"), "diagnostic filtered: {text:?}");
    }

    /// The gap label is fitted in DISPLAY COLUMNS and ellipsized on a word
    /// boundary — never mid-word, never mid-glyph.
    #[test]
    fn gap_label_is_width_aware_and_word_ellipsized() {
        // Long single line, wide-ish pane: must be cut on whitespace.
        let long = "[correctness] the exporter writes CSV output but the goal explicitly asked for newline delimited JSON records";
        let fitted = fit_cols_words(long, 40);
        assert!(crate::util::cols(&fitted) <= 40, "over budget: {fitted:?}");
        assert!(fitted.ends_with('\u{2026}'), "ellipsized: {fitted:?}");
        let body = fitted.trim_end_matches('\u{2026}');
        assert!(
            long.starts_with(body) && (long[body.len()..].starts_with(' ') || body.is_empty()),
            "cut must land on a word boundary, got: {fitted:?}"
        );

        // Short enough ⇒ untouched, no ellipsis.
        assert_eq!(fit_cols_words("short gap", 40), "short gap");

        // Wide (CJK) glyphs are counted at 2 columns, so the result never
        // overflows the budget.
        let cjk = "[correctness] 出力形式が要求と一致していません 詳細は仕様を参照";
        let fitted_cjk = fit_cols_words(cjk, 30);
        assert!(crate::util::cols(&fitted_cjk) <= 30, "cjk over budget: {fitted_cjk:?}");

        // A single unbroken token longer than the budget still yields a
        // non-empty label (falls back to the raw column fit).
        let one_word = "[correctness] aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        let fitted_one = fit_cols_words(one_word, 20);
        assert!(crate::util::cols(&fitted_one) <= 20);
        assert!(fitted_one.len() > 5, "not collapsed to nothing: {fitted_one:?}");
    }

    /// Narrow panes drop the label entirely rather than crowding the line.
    #[test]
    fn gap_label_hidden_on_narrow_panes() {
        let gaps = vec!["[completeness] missing the export step".to_string()];
        let shown = displayable_gaps(&gaps);
        assert!(first_gap_label(&shown, 80).is_none(), "hidden under 100 cols");
        assert!(first_gap_label(&shown, 120).is_some(), "shown on a wide pane");
        // …and an all-diagnostic list yields nothing at any width.
        let internal = vec!["[correctness] unparsable skeptic response".to_string()];
        let none = displayable_gaps(&internal);
        assert!(none.is_empty());
        assert!(first_gap_label(&none, 200).is_none());
    }

    #[test]
    fn estimate_tokens_char_over_four() {
        // Empty ⇒ 0 tokens (no pending overlay).
        assert_eq!(estimate_tokens(""), 0);
        // ceil(chars/4): 1..=4 chars ⇒ 1 token, 5..=8 ⇒ 2, exact multiples land.
        assert_eq!(estimate_tokens("a"), 1);
        assert_eq!(estimate_tokens("abcd"), 1);
        assert_eq!(estimate_tokens("abcde"), 2); // ceil(5/4)
        assert_eq!(estimate_tokens("abcdefgh"), 2); // exact 8/4
        // Large paste: 4000 chars ⇒ 1000 tokens (the hint threshold).
        assert_eq!(estimate_tokens(&"x".repeat(4000)), 1000);
        // Counts Unicode scalar values, not bytes (a 4-byte emoji is one char).
        assert_eq!(estimate_tokens("\u{1F600}\u{1F600}\u{1F600}\u{1F600}"), 1);
    }

    #[test]
    fn pending_input_overlays_meter_without_corrupting_committed() {
        let mut sb = StatusBar::new();
        // Committed 20% of a 200k window; nothing pending yet.
        sb.set_context(0.20, 40_000, 200_000);
        assert!((sb.display_context_ratio() - 0.20).abs() < 1e-9);

        // Paste ~40k tokens of pending input: the RENDERED ratio grows by
        // 40k/200k = 0.20 ⇒ 0.40, but the committed value is untouched.
        sb.set_pending_input_tokens(40_000);
        assert!((sb.display_context_ratio() - 0.40).abs() < 1e-9);
        assert!(
            (sb.context_ratio() - 0.20).abs() < 1e-9,
            "committed context_utilization must NOT change"
        );
        assert_eq!(sb.context_estimated, 40_000, "committed estimate untouched");

        // The bar visibly grows: rendered percent reflects the overlay.
        assert!(render_sb(&sb).contains("40% ctx"));

        // Submit/clear resets pending ⇒ meter snaps back to the committed base.
        sb.set_pending_input_tokens(0);
        assert!((sb.display_context_ratio() - 0.20).abs() < 1e-9);
        assert!(render_sb(&sb).contains("20% ctx"));

        // Combined ratio is clamped to 1.0 (never overflows the bar).
        sb.set_context(0.90, 180_000, 200_000);
        sb.set_pending_input_tokens(200_000); // +100% pending
        assert!((sb.display_context_ratio() - 1.0).abs() < 1e-9);
    }

    #[test]
    fn pending_hint_shows_only_above_threshold() {
        let mut sb = StatusBar::new();
        sb.set_width(120);
        sb.set_context(0.10, 20_000, 200_000);

        // Below threshold: no hint (no noise for short prompts).
        sb.set_pending_input_tokens(PENDING_HINT_MIN_TOKENS - 1);
        assert!(!render_sb(&sb).contains("+~"), "no hint below threshold");

        // At/above threshold: compact "+~Nk" hint appears.
        sb.set_pending_input_tokens(12_000);
        assert!(render_sb(&sb).contains("+~12k"), "large-paste hint shows");

        // Cleared ⇒ hint gone.
        sb.set_pending_input_tokens(0);
        assert!(!render_sb(&sb).contains("+~"));
    }

    #[test]
    fn pending_hint_formats_compactly() {
        assert_eq!(pending_hint(999), "+~999");
        assert_eq!(pending_hint(1000), "+~1k");
        assert_eq!(pending_hint(1499), "+~1k"); // rounds down
        assert_eq!(pending_hint(1500), "+~2k"); // rounds up
        assert_eq!(pending_hint(12_000), "+~12k");
    }

    /// **The same session may not state the context two incompatible ways.**
    ///
    /// The reported screen: `░░░░░░░░ 0% ctx` in one frame and `~80.8k ctx` in
    /// the next, after nothing but a greeting. Both are this bar; the second is
    /// its unknown-window branch, and it took over mid-session because
    /// `set_context` wrote `max_tokens` through unconditionally. `/health` had
    /// already resolved the real window; a later `context_pressure` event whose
    /// `max_tokens` the backend could not fill in then erased it.
    ///
    /// `max == 0` from any source means "I could not resolve it", not "it is
    /// zero", and it may not overwrite a window somebody else did resolve.
    #[test]
    fn an_unresolved_window_never_erases_one_already_known() {
        let mut sb = StatusBar::new();
        sb.set_width(160);
        // `/health` seeds the real window at boot.
        sb.set_context(0.0, 0, 200_000);
        // A later context_pressure arrives with tokens but no window.
        sb.set_context(0.0, 80_800, 0);
        let text = render_sb(&sb);
        assert!(
            text.contains("% ctx"),
            "the window was known; the meter must keep stating a percentage: {text}"
        );
        assert!(
            !text.contains("~80.8k ctx"),
            "the unknown-window readout took over a session with a known window: {text}"
        );
        // 80.8k of 200k, derived rather than left at the reported zero.
        assert!(text.contains("40% ctx"), "expected a real percent, got: {text}");
    }

    /// A window that was never known stays unknown — the fix above must not
    /// invent one.
    #[test]
    fn a_window_that_was_never_resolved_still_renders_the_token_count() {
        let mut sb = StatusBar::new();
        sb.set_width(160);
        sb.set_context(0.0, 80_800, 0);
        let text = render_sb(&sb);
        assert!(text.contains("~80.8k ctx"), "got: {text}");
        assert!(!text.contains("% ctx"), "no fabricated denominator: {text}");
    }

    #[test]
    fn pending_no_percentage_when_window_unknown() {
        // context_max == 0 (window unknown): NO percentage may be rendered — a
        // fabricated denominator is exactly the bug this branch exists to avoid.
        // The size hint still shows and rendering must not panic.
        let mut sb = StatusBar::new();
        sb.set_width(120);
        sb.set_pending_input_tokens(8_000);
        assert!((sb.display_context_ratio() - 0.0).abs() < 1e-9);
        let text = render_sb(&sb);
        assert!(!text.contains("% ctx"), "no percentage when window unknown");
        assert!(text.contains("+~8k"), "size hint still surfaces");
    }

    #[test]
    fn unknown_window_renders_token_count_not_zero_percent() {
        // THE regression: 52.1k tokens in on a model whose window the backend
        // could not resolve. The meter must NEVER read "0% ctx" while tokens are
        // demonstrably in use — it shows the token count with no percentage.
        let mut sb = StatusBar::new();
        sb.set_width(160);
        sb.set_context(0.0, 52_100, 0); // utilization 0, 52.1k used, window unknown

        let text = render_sb(&sb);
        assert!(
            !text.contains("0% ctx"),
            "must not claim 0% while 52.1k tokens are in use, got: {text}"
        );
        assert!(
            text.contains("~52.1k ctx"),
            "token count must be rendered instead, got: {text}"
        );
    }

    #[test]
    fn known_window_still_renders_a_real_percentage() {
        // The unknown-window branch must not regress the normal case: a resolved
        // 1M window with 52.1k used reads ~5%, not a token count.
        let mut sb = StatusBar::new();
        sb.set_width(160);
        sb.set_context(0.0521, 52_100, 1_000_000);

        let text = render_sb(&sb);
        assert!(text.contains("5% ctx"), "expected a real percent, got: {text}");
        assert!(!text.contains("~52.1k ctx"));
    }

    #[test]
    fn input_tokens_track_usage_even_when_window_unknown() {
        // `note_input_tokens` is the self-heal path for providers that do not
        // emit context_pressure every turn (streaming glm/openai-compat). It
        // must still record the token count when the window is unknown —
        // otherwise the unknown-window readout has nothing to render.
        let mut sb = StatusBar::new();
        sb.set_width(160);
        sb.set_context(0.0, 0, 0);
        sb.note_input_tokens(52_100);

        let text = render_sb(&sb);
        assert!(text.contains("~52.1k ctx"), "got: {text}");
        assert!(!text.contains("0% ctx"));
    }

    #[test]
    fn compact_tokens_formats() {
        assert_eq!(compact_tokens(0), "~0");
        assert_eq!(compact_tokens(999), "~999");
        assert_eq!(compact_tokens(52_100), "~52.1k");
        assert_eq!(compact_tokens(1_500_000), "~1.5M");
    }

    #[test]
    fn braille_bar_cell_count_is_stable() {
        let (f, e) = braille_bar(0.0, 8);
        assert_eq!(f.chars().count() + e.chars().count(), 8);
        let (f, e) = braille_bar(1.0, 8);
        assert_eq!(f.chars().count(), 8);
        assert!(e.is_empty());
    }
}

#[cfg(test)]
mod hook_counter_tests {
    use super::{hooks_label, StatusBar};

    #[test]
    fn a_session_with_no_hooks_carries_no_chip() {
        assert_eq!(hooks_label(0, 0), None);
    }

    #[test]
    fn only_failures_earn_a_chip() {
        // A running count of SUCCESSFUL hooks is not information: it only goes
        // up, nobody acts on "691 ok", and it sat permanently beside numbers
        // that do change. Reported as noise by the user, and it was.
        //
        // Failures still surface — that is the case worth a glance — and the
        // per-row `[hooks: …]` bracket keeps the detail where it is
        // attributable to a specific call.
        assert_eq!(hooks_label(54, 0), None);
        assert_eq!(hooks_label(691, 0), None);
        assert_eq!(hooks_label(54, 19).as_deref(), Some("hooks 19 failed"));
    }

    #[test]
    fn blocking_is_not_failing() {
        // A policy hook that refuses a dangerous command is the system working.
        // Counting that as a failure reports a correct setup as broken — which is
        // worse than not counting it at all, because it is a lie the user acts on.
        let mut bar = StatusBar::new();
        bar.note_hook_run("blocked");
        bar.note_hook_run("ok");
        // Both counted as successes, so no chip at all — and crucially, not a
        // failure chip, which is the lie this test guards against.
        assert_eq!(bar.hooks_failed, 0);
        assert_eq!(hooks_label(bar.hooks_ok, bar.hooks_failed), None);
    }

    #[test]
    fn only_crashes_and_timeouts_count_as_failures() {
        let mut bar = StatusBar::new();
        for outcome in ["ok", "blocked", "crashed", "timed_out", "ok"] {
            bar.note_hook_run(outcome);
        }
        assert_eq!(bar.hooks_ok, 3);
        assert_eq!(bar.hooks_failed, 2);
    }

    #[test]
    fn an_unknown_outcome_is_not_a_failure() {
        // The backend owns this vocabulary and may add to it. A new verb must not
        // silently start reddening the status line before anyone has decided it
        // means failure.
        let mut bar = StatusBar::new();
        bar.note_hook_run("rewrote_input");
        assert_eq!(bar.hooks_failed, 0);
        assert_eq!(bar.hooks_ok, 1);
    }
}
