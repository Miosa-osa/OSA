use ratatui::layout::{Constraint, Direction, Layout as RLayout};
use ratatui::prelude::*;
use ratatui::widgets::Paragraph;

use crate::client::types::Signal;
use crate::event::Event;
use crate::style;

use super::{Component, ComponentAction};

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
fn mcp_label(count: usize) -> Option<String> {
    if count > 0 {
        Some(format!("{} MCP", count))
    } else {
        None
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
    shell_count: usize,
    cwd_basename: String,
    /// "goal N/max" indicator when a /goal auto-continue loop is active.
    goal_label: Option<String>,
    /// Transient goal-verification indicator, rendered next to the goal line.
    /// None ⇒ no verifier round this turn ⇒ chip omitted.
    goal_verify: Option<GoalVerifyState>,
    /// Reasoning effort ("low"|"medium"|"high"|"max") from `/health.effort`.
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
    /// U-T26 — number of connected MCP servers (from `McpServersLoaded`). 0 ⇒
    /// no chip. Populated on session start and on `/mcp`.
    mcp_count: usize,
    /// U-B5 — live swarm-intelligence status ("swarm · round N"), driven by the
    /// SwarmIntelligence* events. None ⇒ no swarm running ⇒ chip omitted.
    swarm_label: Option<String>,
    /// U-T28 — active sub-agent count + estimated cost, for the compact
    /// "⛓ N subagents · $cost · ↓ manage" footer cue. 0 ⇒ omitted.
    subagent_count: usize,
    subagent_cost: Option<f64>,
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
            shell_count: 0,
            cwd_basename,
            goal_label: None,
            goal_verify: None,
            effort: None,
            billing: None,
            percent_left: None,
            context_low: false,
            mcp_count: 0,
            swarm_label: None,
            subagent_count: 0,
            subagent_cost: None,
            update_latest: None,
        }
    }

    /// Override the workspace label with the backend's git-root-aware project
    /// name (from /workspace/identity), so the status bar shows the dir the
    /// agent actually operates in — not a raw launch-dir basename. A blank name
    /// leaves the existing label untouched.
    pub fn set_workspace_name(&mut self, name: Option<String>) {
        if let Some(n) = name.filter(|s| !s.trim().is_empty()) {
            self.cwd_basename = n;
        }
    }

    /// Set (or clear with None) the reasoning-effort chip.
    pub fn set_effort(&mut self, effort: Option<String>) {
        // Normalize away blanks so an empty string never renders "effort:".
        self.effort = effort.filter(|s| !s.trim().is_empty());
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

    /// U-B5 — set (or clear with None) the live swarm-intelligence chip.
    pub fn set_swarm(&mut self, label: Option<String>) {
        self.swarm_label = label;
    }

    /// U-T28 — set the active sub-agent count + estimated cost for the footer
    /// cue. `count == 0` clears it.
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

    pub fn set_shell_count(&mut self, count: usize) {
        self.shell_count = count;
    }

    pub fn set_provider_info(&mut self, provider: &str, model: &str) {
        self.provider = provider.to_string();
        self.model_name = model.to_string();
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

    pub fn set_context(&mut self, utilization: f64, estimated: u64, max: u64) {
        self.context_utilization = utilization.clamp(0.0, 1.0);
        self.context_estimated = estimated;
        self.context_max = max;
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
    pub fn note_input_tokens(&mut self, input_tokens: u64) {
        if input_tokens == 0 || self.context_max == 0 {
            return;
        }
        self.context_estimated = input_tokens;
        self.context_utilization =
            (input_tokens as f64 / self.context_max as f64).clamp(0.0, 1.0);
    }

    /// Current context utilization ratio (0.0..=1.0), for mirroring into the
    /// sidebar meter so both surfaces agree.
    pub fn context_ratio(&self) -> f64 {
        self.context_utilization
    }

    /// WS12 — CC TokenWarning parity fields from the backend's context_pressure
    /// event: percent of usable context left before auto-compact, and whether
    /// the low-context warning threshold has been crossed.
    pub fn set_context_warning(&mut self, percent_left: Option<u32>, context_low: bool) {
        self.percent_left = percent_left;
        self.context_low = context_low;
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

        // Permission mode is shown exactly ONCE — on the ⏵⏵ line (row 1),
        // matching Claude Code's single mode indicator
        // (PromptInputFooterLeftSide.tsx: `{symbol} {title.toLowerCase()} on`).
        // The old row-0 "▣ mode" chip duplicated it (mode rendered twice) and has
        // been removed. The color binding is retained for row 1 and the bg chip.
        let mode_color = self.permission_mode.color(&theme);

        // Braille context-usage bar + percentage.
        spans.push(Span::styled(" \u{2502} ", theme.status_sep()));
        let (bar_filled, bar_empty) = braille_bar(self.context_utilization, 8);
        // Severity color grades the meter as it approaches the auto-compact
        // threshold (CC parity): primary < 75%, amber >= 75%, red >= 90% OR once
        // the backend flags the low-context warning band (`context_low`, keyed on
        // the real `warn_at` threshold). Both the filled bar and the percentage
        // share the color so the statusline telegraphs pressure at a glance.
        let ctx_color = if self.context_low {
            theme.colors.error
        } else {
            theme.context_bar_color(self.context_utilization)
        };
        if !bar_filled.is_empty() {
            spans.push(Span::styled(bar_filled, Style::default().fg(ctx_color)));
        }
        if !bar_empty.is_empty() {
            spans.push(Span::styled(bar_empty, theme.ctx_bar_empty()));
        }
        let pct = (self.context_utilization * 100.0).round() as u32;
        let pct_style = if self.context_low {
            Style::default().fg(ctx_color).add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(ctx_color)
        };
        // "N% ctx" — labelled like CC's "N% context used" so the number reads as
        // context occupancy (measured against the effective window server-side).
        spans.push(Span::styled(format!(" {}% ctx", pct), pct_style));

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
                    let plural = if gaps.len() == 1 { "" } else { "s" };
                    let mut label =
                        format!("{} {}/{} \u{00b7} {} gap{}", sym, refuted, total, gaps.len(), plural);
                    // Only name the first gap when the pane is wide enough that
                    // it won't crowd the line — the chip stays one line, compact.
                    if self.width >= 100 {
                        if let Some(first) = gaps.first().filter(|g| !g.trim().is_empty()) {
                            label.push_str(&format!(" \u{00b7} {}", first));
                        }
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

        // Reasoning-effort chip (`effort:medium`). Faint for low/medium; the
        // heavier high/max tiers get the accent color so a costly setting is
        // visible at a glance. Omitted entirely when the backend didn't report.
        if let Some(ref effort) = self.effort {
            spans.push(Span::styled(" \u{2502} ", theme.status_sep()));
            let heavy = matches!(effort.as_str(), "high" | "max");
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
            extras.push(Span::styled(
                " \u{00b7} \u{2193} manage",
                theme.faint(),
            ));
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
    fn context_warning_roundtrip() {
        let mut sb = StatusBar::new();
        assert!(!sb.context_low());
        assert_eq!(sb.percent_left(), None);
        sb.set_context_warning(Some(18), true);
        assert!(sb.context_low());
        assert_eq!(sb.percent_left(), Some(18));
        // A fresh report after compaction clears both.
        sb.set_context_warning(None, false);
        assert!(!sb.context_low());
        assert_eq!(sb.percent_left(), None);
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

    #[test]
    fn braille_bar_cell_count_is_stable() {
        let (f, e) = braille_bar(0.0, 8);
        assert_eq!(f.chars().count() + e.chars().count(), 8);
        let (f, e) = braille_bar(1.0, 8);
        assert_eq!(f.chars().count(), 8);
        assert!(e.is_empty());
    }
}
