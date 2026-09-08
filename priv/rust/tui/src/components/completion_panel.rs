//! Full-screen goal-COMPLETION panel (item #3).
//!
//! Every other surface in the live region reports a goal as an ongoing
//! process — "goal 3/25", a verifier chip, the roster's activity line — and
//! none of them ever say the run is OVER. When a durable goal reaches a
//! terminal state (`COMPLETED` / `BLOCKED` / `ABANDONED`, from the backend's
//! `goal_tracker_transition` frame), the user is otherwise left staring at
//! whatever the last live surface happened to say, with no banner, no work
//! summary, and no accounting of which acceptance criteria were actually met.
//! A finished run looked identical to one still quietly working.
//!
//! This panel is that missing terminal report: a banner naming the outcome,
//! the goal, a summary of the work done, a criteria checklist, and — for a
//! blocked/abandoned run — the gaps that stopped it. Read-only; the only
//! interaction is scrolling a report too long for the screen, and Esc/Enter/q
//! close it.

use std::cell::Cell;

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::{
    prelude::*,
    widgets::{Block, BorderType, Borders, Clear, Paragraph},
};

/// How the durable goal ended. Mirrors the backend's `status` vocabulary on
/// `goal_tracker_transition` (see [`CompletionOutcome::from_status`]) — kept
/// as a parsed enum so every rendering decision is made on a known set
/// rather than by re-matching strings at each call site.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CompletionOutcome {
    /// The goal was met.
    Completed,
    /// The run stopped short of the goal but did NOT give up — e.g. capped
    /// by a turn/budget limit, or waiting on something outside the agent's
    /// control. Distinct from `Abandoned`: the work may still be resumable.
    Blocked,
    /// The run was given up on — by the user, or because the backend judged
    /// the goal unachievable as framed.
    Abandoned,
}

impl CompletionOutcome {
    /// Parse the backend's `status` string into a terminal outcome, or `None`
    /// for anything that is not one of the three terminal states (`active`,
    /// `off_track`, …) — those are NOT this panel's business; the ordinary
    /// goal-tracker/status-line chips already cover them.
    ///
    /// Field-name and vocabulary reconciliation: the exact strings the
    /// backend's goal-completion emitter sends were not yet finalized at the
    /// time this was written, so every plausible spelling is accepted here
    /// rather than gating on one guess. Extend this match, not the callers,
    /// if the backend settles on a different word.
    pub fn from_status(status: &str) -> Option<Self> {
        match status.trim().to_ascii_lowercase().as_str() {
            "completed" | "complete" | "done" | "succeeded" => Some(Self::Completed),
            "blocked" | "stalled" | "capped" | "stuck" => Some(Self::Blocked),
            "abandoned" | "cancelled" | "canceled" | "gave_up" | "give_up" => {
                Some(Self::Abandoned)
            }
            _ => None,
        }
    }

    /// The banner glyph + label + theme color key for this outcome.
    fn banner(&self, theme: &crate::style::Theme) -> (&'static str, &'static str, Color) {
        match self {
            Self::Completed => ("\u{2713}", "Goal Completed", theme.colors.success),
            Self::Blocked => ("\u{23f8}", "Goal Blocked", theme.colors.warning),
            Self::Abandoned => ("\u{2717}", "Goal Abandoned", theme.colors.error),
        }
    }
}

/// The decoded report this panel renders — mirrors
/// `BackendEvent::GoalCompletionOverview` (see `GoalTracker.completion_overview/1`).
/// Built by the caller from the backend's one-time completion frame; `App`
/// owns exactly one at a time (`None` when no goal has reached a terminal
/// state, or the report was dismissed). Every text field is a plain `String`;
/// blank/empty just omits that section, the same convention `goal` already
/// used before this struct grew the rest of the report.
#[derive(Debug, Clone)]
pub struct CompletionReport {
    pub outcome: CompletionOutcome,
    /// The goal as originally stated.
    pub goal: String,
    /// Distinct file paths touched this session (the backend's
    /// VerificationEvidence ledger) — a LIST of paths, not prose; rendered as
    /// a bulleted list.
    pub work_summary: Vec<String>,
    /// The frozen acceptance-criteria text, when the backend reported one
    /// distinct from the goal text.
    pub acceptance_criteria: String,
    /// Goal-verifier-panel findings. Commonly EMPTY for `Blocked`/`Abandoned`
    /// — those stop via `claim_blocked`/`abandon` rather than a panel
    /// verdict, not because there is nothing to report — so this section is
    /// shown whenever non-empty, regardless of outcome.
    pub gaps: Vec<String>,
    /// Why a Blocked/Abandoned run stopped, when the backend reported one.
    pub pause_reason: String,
    /// Most recent goal-tracker history line, for extra context.
    pub latest: String,
}

/// Bubble-up result of the panel's key handling.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CompletionPanelAction {
    /// The panel should be dismissed.
    Close,
    /// Key consumed; keep the panel open.
    None,
}

pub struct CompletionPanel {
    report: CompletionReport,
    /// Top content line (cursor) — nonzero only on a terminal too short to
    /// fit the whole report.
    scroll: usize,
    /// Content viewport height measured on the last draw, so `handle_key`
    /// clamps against the real rendered height rather than a guess.
    viewport: Cell<usize>,
}

impl CompletionPanel {
    pub fn new(report: CompletionReport) -> Self {
        Self {
            report,
            scroll: 0,
            viewport: Cell::new(1),
        }
    }

    /// The report currently displayed.
    pub fn report(&self) -> &CompletionReport {
        &self.report
    }

    /// Build the scrollable content lines (the banner lives outside this, as
    /// its own fixed row). `maxw` bounds wrapping/truncation but never
    /// changes the line COUNT differently than a real draw would, so
    /// `handle_key` can measure scroll bounds the same way `draw` paints.
    fn build_lines(&self, maxw: usize, theme: &crate::style::Theme) -> Vec<Line<'static>> {
        let c = &theme.colors;
        let mut out: Vec<Line<'static>> = Vec::with_capacity(16);
        let maxw = maxw.max(1);

        let hdr = |s: &str| {
            Line::from(Span::styled(
                s.to_string(),
                Style::default().fg(c.primary).add_modifier(Modifier::BOLD),
            ))
        };

        if !self.report.goal.trim().is_empty() {
            out.push(hdr("GOAL"));
            for line in crate::render::markdown::wrap_text(self.report.goal.trim(), maxw) {
                out.push(Line::from(Span::styled(line, Style::default())));
            }
            out.push(Line::from(""));
        }

        if !self.report.acceptance_criteria.trim().is_empty() {
            out.push(hdr("ACCEPTANCE CRITERIA"));
            for line in
                crate::render::markdown::wrap_text(self.report.acceptance_criteria.trim(), maxw)
            {
                out.push(Line::from(Span::styled(line, Style::default())));
            }
            out.push(Line::from(""));
        }

        if !self.report.work_summary.is_empty() {
            let n = self.report.work_summary.len();
            out.push(hdr(&format!(
                "WORK SUMMARY \u{2014} {n} file{}",
                if n == 1 { "" } else { "s" }
            )));
            for path in &self.report.work_summary {
                let wrapped =
                    crate::render::markdown::wrap_text(path.trim(), maxw.saturating_sub(2).max(1));
                for (i, line) in wrapped.into_iter().enumerate() {
                    let prefix = if i == 0 { "  \u{2022} " } else { "    " };
                    out.push(Line::from(Span::styled(
                        format!("{prefix}{line}"),
                        Style::default(),
                    )));
                }
            }
            out.push(Line::from(""));
        }

        // Shown whenever non-empty, regardless of outcome: the verifier
        // panel that produces `gaps` runs on the completion path, not on
        // blocked/abandoned, so gating this on `outcome != Completed` would
        // have hidden the one case where it is actually populated.
        if !self.report.gaps.is_empty() {
            out.push(hdr("GAPS"));
            for gap in &self.report.gaps {
                let wrapped = crate::render::markdown::wrap_text(gap.trim(), maxw.saturating_sub(2).max(1));
                for (i, line) in wrapped.into_iter().enumerate() {
                    let prefix = if i == 0 { "  \u{2022} " } else { "    " };
                    out.push(Line::from(Span::styled(
                        format!("{prefix}{line}"),
                        Style::default().fg(c.warning),
                    )));
                }
            }
            out.push(Line::from(""));
        }

        // Compact trailer — extra context the backend reported, secondary to
        // everything above so it never competes with the goal/summary/gaps.
        if !self.report.pause_reason.trim().is_empty() {
            out.push(Line::from(vec![
                Span::styled(
                    "Reason: ",
                    Style::default().fg(c.muted).add_modifier(Modifier::BOLD),
                ),
                Span::styled(
                    self.report.pause_reason.trim().to_string(),
                    Style::default().fg(c.muted),
                ),
            ]));
        }
        if !self.report.latest.trim().is_empty() {
            out.push(Line::from(vec![
                Span::styled(
                    "Last update: ",
                    Style::default().fg(c.muted).add_modifier(Modifier::BOLD),
                ),
                Span::styled(
                    self.report.latest.trim().to_string(),
                    Style::default().fg(c.muted),
                ),
            ]));
        }

        if out.last().is_some_and(|l| l.spans.is_empty() || l.spans.iter().all(|s| s.content.is_empty())) {
            out.pop();
        }

        if out.is_empty() {
            out.push(Line::from(Span::styled(
                "No further detail was reported.",
                Style::default().fg(c.muted),
            )));
        }

        out
    }

    fn content_len(&self) -> usize {
        let theme = crate::style::theme();
        self.build_lines(usize::MAX, &theme).len()
    }

    fn max_scroll(&self) -> usize {
        self.content_len().saturating_sub(self.viewport.get().max(1))
    }

    pub fn handle_key(&mut self, key: KeyEvent) -> CompletionPanelAction {
        if key.modifiers.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) {
            return CompletionPanelAction::None;
        }
        let max = self.max_scroll();
        let page = self.viewport.get().max(1);
        match key.code {
            KeyCode::Esc | KeyCode::Char('q') | KeyCode::Enter => {
                return CompletionPanelAction::Close
            }
            KeyCode::Up | KeyCode::Char('k') => self.scroll = self.scroll.saturating_sub(1),
            KeyCode::Down | KeyCode::Char('j') => self.scroll = (self.scroll + 1).min(max),
            KeyCode::PageUp => self.scroll = self.scroll.saturating_sub(page),
            KeyCode::PageDown => self.scroll = (self.scroll + page).min(max),
            KeyCode::Home => self.scroll = 0,
            KeyCode::End => self.scroll = max,
            _ => {}
        }
        CompletionPanelAction::None
    }

    /// Draw the panel as a near-full-screen overlay (a small margin on every
    /// side, unlike the smaller fixed-size dialogs) — this is the durable
    /// terminal report for a whole run, not a quick status peek.
    pub fn draw(&self, frame: &mut Frame, area: Rect) {
        let theme = crate::style::theme();
        let c = &theme.colors;

        const MARGIN_X: u16 = 2;
        const MARGIN_Y: u16 = 1;
        let w = area.width.saturating_sub(MARGIN_X * 2).max(1);
        let h = area.height.saturating_sub(MARGIN_Y * 2).max(1);
        let rect = Rect::new(
            area.x + (area.width.saturating_sub(w)) / 2,
            area.y + (area.height.saturating_sub(h)) / 2,
            w,
            h,
        );

        frame.render_widget(Clear, rect);

        let (glyph, label, accent) = self.report.outcome.banner(&theme);
        let block = Block::default()
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(Style::default().fg(accent))
            .title(Line::from(vec![
                Span::styled(format!(" {glyph} "), Style::default().fg(accent).add_modifier(Modifier::BOLD)),
                Span::styled(label, Style::default().fg(accent).add_modifier(Modifier::BOLD)),
                Span::raw(" "),
            ]))
            .style(Style::default().bg(c.dialog_bg));
        frame.render_widget(block, rect);

        let inner = Rect::new(
            rect.x + 2,
            rect.y + 1,
            rect.width.saturating_sub(4),
            rect.height.saturating_sub(2),
        );
        if inner.width < 8 || inner.height < 3 {
            return; // too small; border + title already say enough.
        }
        let maxw = inner.width as usize;

        // Reserve the last inner row for the footer hint; the rest scrolls.
        let list_h = inner.height.saturating_sub(1) as usize;
        self.viewport.set(list_h.max(1));

        let lines = self.build_lines(maxw, &theme);
        let max = lines.len().saturating_sub(list_h);
        let scroll = self.scroll.min(max);

        for rel in 0..list_h {
            let Some(line) = lines.get(rel + scroll) else { break };
            frame.render_widget(
                Paragraph::new(line.clone()),
                Rect::new(inner.x, inner.y + rel as u16, inner.width, 1),
            );
        }

        let hint_y = inner.y + inner.height.saturating_sub(1);
        let mut spans = vec![
            Span::styled("esc", Style::default().fg(c.secondary).add_modifier(Modifier::BOLD)),
            Span::styled(" close", Style::default().fg(c.dim)),
        ];
        if lines.len() > list_h {
            spans.push(Span::styled(
                "   \u{2191}\u{2193}",
                Style::default().fg(c.secondary).add_modifier(Modifier::BOLD),
            ));
            spans.push(Span::styled(" scroll", Style::default().fg(c.dim)));
        }
        frame.render_widget(Paragraph::new(Line::from(spans)), Rect::new(inner.x, hint_y, inner.width, 1));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::{backend::TestBackend, Terminal};

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::empty())
    }

    fn completed_report() -> CompletionReport {
        CompletionReport {
            outcome: CompletionOutcome::Completed,
            goal: "Ship the v1.0.185 release".into(),
            work_summary: vec!["lib/foo.ex".into(), "lib/bar.ex".into()],
            acceptance_criteria: "All tests pass and CHANGELOG updated".into(),
            gaps: vec!["docs still reference the old flag name".into()],
            pause_reason: String::new(),
            latest: "verified complete".into(),
        }
    }

    fn blocked_report() -> CompletionReport {
        CompletionReport {
            outcome: CompletionOutcome::Blocked,
            goal: "Migrate the billing service".into(),
            work_summary: vec!["lib/billing/client.ex".into()],
            acceptance_criteria: String::new(),
            gaps: vec![],
            pause_reason: "blocked".into(),
            latest: "3 consecutive claim_blocked calls".into(),
        }
    }

    // ── outcome parsing ──────────────────────────────────────────────────

    #[test]
    fn from_status_recognizes_every_terminal_spelling() {
        for s in ["completed", "Complete", "DONE", "succeeded"] {
            assert_eq!(CompletionOutcome::from_status(s), Some(CompletionOutcome::Completed), "{s}");
        }
        for s in ["blocked", "stalled", "capped", "STUCK"] {
            assert_eq!(CompletionOutcome::from_status(s), Some(CompletionOutcome::Blocked), "{s}");
        }
        for s in ["abandoned", "cancelled", "canceled", "gave_up"] {
            assert_eq!(CompletionOutcome::from_status(s), Some(CompletionOutcome::Abandoned), "{s}");
        }
    }

    #[test]
    fn from_status_is_none_for_a_non_terminal_status() {
        for s in ["active", "off_track", "paused", ""] {
            assert_eq!(CompletionOutcome::from_status(s), None, "{s}");
        }
    }

    // ── rendering ────────────────────────────────────────────────────────

    #[test]
    fn draws_at_every_size_without_panicking() {
        for report in [completed_report(), blocked_report()] {
            let mut panel = CompletionPanel::new(report);
            panel.handle_key(key(KeyCode::End)); // exercise scroll clamping too
            for (w, h) in [(1u16, 1u16), (10, 4), (40, 12), (80, 24), (200, 60)] {
                let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
                term.draw(|f| panel.draw(f, f.area())).unwrap();
            }
        }
    }

    fn render_text(panel: &CompletionPanel, w: u16, h: u16) -> String {
        let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
        term.draw(|f| panel.draw(f, f.area())).unwrap();
        term.backend().buffer().content().iter().map(|c| c.symbol()).collect()
    }

    #[test]
    fn completed_banner_shows_goal_criteria_summary_and_gaps() {
        // The verifier panel that produces `gaps` runs on the completion
        // path, so a Completed report CAN carry non-empty gaps (a residual
        // note despite an overall pass) — this must still render them.
        let panel = CompletionPanel::new(completed_report());
        let text = render_text(&panel, 100, 24);
        assert!(text.contains("Goal Completed"), "{text:?}");
        assert!(text.contains("Ship the v1.0.185 release"), "{text:?}");
        assert!(text.contains("All tests pass and CHANGELOG updated"), "{text:?}");
        assert!(text.contains("lib/foo.ex"), "work summary must list files: {text:?}");
        assert!(text.contains("2 files"), "the file count is stated: {text:?}");
        assert!(text.contains("docs still reference"), "{text:?}");
        assert!(text.contains("verified complete"), "the latest history line: {text:?}");
    }

    #[test]
    fn blocked_banner_shows_the_reason_when_gaps_are_empty() {
        // Blocked/abandoned stop via claim_blocked/abandon rather than a
        // panel verdict, so `gaps` is commonly empty there — `pause_reason` /
        // `latest` are what explain the outcome instead.
        let panel = CompletionPanel::new(blocked_report());
        let text = render_text(&panel, 100, 24);
        assert!(text.contains("Goal Blocked"), "{text:?}");
        assert!(text.contains("lib/billing/client.ex"), "{text:?}");
        assert!(!text.contains("GAPS"), "no gaps were reported: {text:?}");
        assert!(text.contains("Reason:") && text.contains("blocked"), "{text:?}");
        assert!(text.contains("claim_blocked calls"), "{text:?}");
    }

    #[test]
    fn a_missing_acceptance_criteria_omits_that_section() {
        let panel = CompletionPanel::new(blocked_report());
        let text = render_text(&panel, 100, 24);
        assert!(!text.contains("ACCEPTANCE CRITERIA"), "{text:?}");
    }

    #[test]
    fn a_bare_minimal_report_omits_every_optional_section_without_panicking() {
        let report = CompletionReport {
            outcome: CompletionOutcome::Abandoned,
            goal: String::new(),
            work_summary: vec![],
            acceptance_criteria: String::new(),
            gaps: vec![],
            pause_reason: String::new(),
            latest: String::new(),
        };
        let panel = CompletionPanel::new(report);
        let text = render_text(&panel, 100, 24);
        assert!(text.contains("Goal Abandoned"), "{text:?}");
        assert!(!text.contains("GOAL"), "{text:?}");
        assert!(!text.contains("WORK SUMMARY"), "{text:?}");
        assert!(!text.contains("ACCEPTANCE CRITERIA"), "{text:?}");
        assert!(!text.contains("GAPS"), "{text:?}");
        assert!(!text.contains("Reason:"), "{text:?}");
    }

    // ── key handling ─────────────────────────────────────────────────────

    #[test]
    fn esc_enter_and_q_all_close() {
        for code in [KeyCode::Esc, KeyCode::Enter, KeyCode::Char('q')] {
            let mut panel = CompletionPanel::new(completed_report());
            assert_eq!(panel.handle_key(key(code)), CompletionPanelAction::Close);
        }
    }

    #[test]
    fn scroll_keys_do_not_close_and_clamp_at_the_ends() {
        let mut panel = CompletionPanel::new(blocked_report());
        panel.viewport.set(2); // force a scrollable state
        assert_eq!(panel.handle_key(key(KeyCode::Down)), CompletionPanelAction::None);
        for _ in 0..200 {
            panel.handle_key(key(KeyCode::Char('j')));
        }
        assert_eq!(panel.scroll, panel.max_scroll());
        panel.handle_key(key(KeyCode::Home));
        assert_eq!(panel.scroll, 0);
        panel.handle_key(key(KeyCode::Up)); // saturates, does not panic
        assert_eq!(panel.scroll, 0);
        panel.handle_key(key(KeyCode::End));
        assert_eq!(panel.scroll, panel.max_scroll());
    }

    #[test]
    fn chorded_keys_are_ignored_not_closed() {
        let mut panel = CompletionPanel::new(completed_report());
        let chorded = KeyEvent::new(KeyCode::Char('c'), KeyModifiers::CONTROL);
        assert_eq!(panel.handle_key(chorded), CompletionPanelAction::None);
    }
}
