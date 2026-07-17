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
    /// Reasoning effort ("low"|"medium"|"high"|"max") from `/health.effort`.
    /// None ⇒ backend didn't report it ⇒ the chip is omitted.
    effort: Option<String>,
    /// Billing snapshot from `/health.billing`. None ⇒ omit the spend chip.
    billing: Option<crate::client::types::HealthBilling>,
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
            effort: None,
            billing: None,
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
        if !b.usd_pricing {
            // Non-USD provider: never show a `$` figure — show token usage.
            return Some(format!("{} tok today", Self::format_tokens(b.daily_tokens)));
        }
        let spent = Self::format_usd(b.daily_spent_usd);
        let label = match b.daily_limit_usd {
            Some(limit) => format!("{}/{} today", spent, Self::format_usd(limit)),
            None => format!("{} today", spent),
        };
        Some(label)
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
        let row0 = rows[0];
        let row1 = rows.get(1).copied().unwrap_or(row0);
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

        // Mode chip: ▣ mode
        spans.push(Span::styled(" \u{2502} ", theme.status_sep()));
        let mode_color = self.permission_mode.color(&theme);
        spans.push(Span::styled(
            "\u{25A3} ".to_string(), // ▣
            Style::default().fg(mode_color),
        ));
        spans.push(Span::styled(
            self.permission_mode.short_title().to_string(),
            Style::default().fg(mode_color),
        ));

        // Braille context-usage bar + percentage.
        spans.push(Span::styled(" \u{2502} ", theme.status_sep()));
        let (bar_filled, bar_empty) = braille_bar(self.context_utilization, 8);
        if !bar_filled.is_empty() {
            spans.push(Span::styled(bar_filled, theme.ctx_bar_fill()));
        }
        if !bar_empty.is_empty() {
            spans.push(Span::styled(bar_empty, theme.ctx_bar_empty()));
        }
        let pct = (self.context_utilization * 100.0).round() as u32;
        spans.push(Span::styled(format!(" {}%", pct), theme.progress_label()));

        // Decorative accent.
        spans.push(Span::styled(" \u{2606}", theme.status_glyph())); // ☆

        // Signal pill — still surfaced when classified.
        self.push_signal_pill(&mut spans, &theme);

        // Active extras: elapsed time so streaming still shows progress.
        if self.active && self.elapsed_ms > 0 {
            let elapsed_label = if self.elapsed_ms >= 60_000 {
                let mins = self.elapsed_ms / 60_000;
                let secs = (self.elapsed_ms % 60_000) / 1000;
                format!("{}m{}s", mins, secs)
            } else if self.elapsed_ms >= 1_000 {
                format!("{:.1}s", self.elapsed_ms as f64 / 1000.0)
            } else {
                format!("{}ms", self.elapsed_ms)
            };
            spans.push(Span::styled(" \u{2502} ", theme.status_sep()));
            spans.push(Span::styled(elapsed_label, theme.progress_label()));
        }

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

        // Billing chip (`$0.42/$10 today`). Omitted when billing is absent.
        if let Some(billing_label) = self.billing_label() {
            spans.push(Span::styled(" \u{2502} ", theme.status_sep()));
            spans.push(Span::styled(billing_label, theme.progress_label()));

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
