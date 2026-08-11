//! `/cost` — the spend & budget dashboard.
//!
//! A branded, read-only overlay that answers "what has this OSA run cost?" at a
//! glance: total spend rendered large, the input/output/total token split
//! (grouped in thousands so a 1_234_567 count is legible), the number of billed
//! sessions, and — when the payload carries budget limits — a color-graded
//! spend-vs-limit gauge in the same visual language as the `/status` context
//! gauge (comfortable → tight → over budget).
//!
//! Fed by `GET /api/v1/cost` (see `cost_routes.ex`): the summary object plus, if
//! merged from `GET /cost/budgets`, the optional monthly/daily limit fields. The
//! app owns one [`CostDashboard`] built from that decoded payload. It is
//! read-only — the only navigation is scrolling when a short terminal can't fit
//! the whole card; Esc or `q` closes it.

use std::cell::Cell;

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::{
    prelude::*,
    widgets::{Block, BorderType, Borders, Clear, Paragraph},
};

/// Clip-safe render (shared choke point with the other dialogs).
fn put<W: ratatui::widgets::Widget>(frame: &mut Frame, widget: W, rect: Rect) {
    crate::app::event_loop::safe_render_widget(frame, widget, rect);
}

const DIALOG_W: u16 = 60;
const DIALOG_H: u16 = 20;
/// Cells in the spend-vs-limit gauge track.
const GAUGE_W: usize = 24;

/// Decoded `GET /api/v1/cost` payload the dashboard renders. Owned so `draw`
/// never borrows `App`. The first six fields mirror the cost-summary JSON
/// verbatim; the budget fields are `Option` because they are only present when
/// the caller has merged in the limits from `GET /cost/budgets`.
pub struct CostView {
    /// `total_cost_usd` — aggregate spend for the window (from monthly spend).
    pub total_cost_usd: f64,
    /// `total_tokens` — input + output combined.
    pub total_tokens: u64,
    /// `input_tokens` — prompt tokens billed.
    pub input_tokens: u64,
    /// `output_tokens` — completion tokens billed.
    pub output_tokens: u64,
    /// `sessions` — number of ledger entries / billed sessions.
    pub sessions: u64,
    /// `since` — ISO-8601 start of the accounting window.
    pub since: String,
    /// Monthly spend ceiling in USD, when budget limits are known.
    pub monthly_limit_usd: Option<f64>,
    /// Monthly spend used so far in USD; falls back to `total_cost_usd`.
    pub monthly_spent_usd: Option<f64>,
    /// Daily spend ceiling in USD, when budget limits are known.
    pub daily_limit_usd: Option<f64>,
    /// Daily spend used so far in USD.
    pub daily_spent_usd: Option<f64>,
}

/// Bubble-up result of cost-dashboard key handling.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CostDashboardAction {
    /// The overlay should be dismissed.
    Close,
    /// Key consumed; keep the overlay open.
    None,
}

pub struct CostDashboard {
    view: CostView,
    /// Top content line (cursor) — only ever nonzero on a terminal too short to
    /// fit the whole card.
    scroll: usize,
    /// Content viewport height measured on the last draw, so `handle_key`
    /// clamps against the real card instead of the `DIALOG_H` upper bound.
    viewport: Cell<usize>,
}

impl CostDashboard {
    pub fn new(view: CostView) -> Self {
        Self { view, scroll: 0, viewport: Cell::new((DIALOG_H as usize).saturating_sub(3)) }
    }

    /// Grade a spend fraction: comfortable → tight → over/near budget. Mirrors
    /// the `/status` context gauge so the two dashboards read the same.
    fn gauge_color(frac: f64, c: &crate::style::ThemeColors) -> Color {
        if frac < 0.60 {
            c.success
        } else if frac < 0.85 {
            c.warning
        } else {
            c.error
        }
    }

    /// Effective monthly spend for the gauge — the explicit `monthly_spent_usd`
    /// if present, else the summary total.
    fn spent(&self) -> f64 {
        self.view.monthly_spent_usd.unwrap_or(self.view.total_cost_usd)
    }

    /// Build the scrollable content lines (title and footer live outside this).
    /// `maxw` bounds truncation but never changes the line *count*, so
    /// `handle_key` can count rows by calling with `usize::MAX`.
    fn build_lines(&self, maxw: usize, c: &crate::style::ThemeColors) -> Vec<Line<'static>> {
        let v = &self.view;
        let mut out: Vec<Line<'static>> = Vec::with_capacity(16);
        let hdr = |s: &str| {
            Line::from(Span::styled(
                s.to_string(),
                Style::default().fg(c.primary).add_modifier(Modifier::BOLD),
            ))
        };
        let kv = |k: &str, val: String, val_c: Color| {
            Line::from(vec![
                Span::styled(format!("  {k:<10}"), Style::default().fg(c.muted)),
                Span::styled(val, Style::default().fg(val_c).add_modifier(Modifier::BOLD)),
            ])
        };

        // ── SPEND (rendered large via a bold, spaced figure) ────────────────
        out.push(hdr("SPEND"));
        out.push(Line::from(vec![Span::styled(
            truncate_chars(&format!("  {}", fmt_usd(v.total_cost_usd)), maxw),
            Style::default().fg(c.secondary).add_modifier(Modifier::BOLD),
        )]));
        out.push(Line::from(Span::styled(
            truncate_chars(&format!("  since {}", fmt_since(&v.since)), maxw),
            Style::default().fg(c.dim),
        )));
        out.push(Line::from(""));

        // ── BUDGET gauge (only when limits are known) ───────────────────────
        if let Some(limit) = v.monthly_limit_usd.filter(|l| *l > 0.0) {
            let spent = self.spent();
            let frac = (spent / limit).clamp(0.0, 1.0);
            let filled = ((frac * GAUGE_W as f64).round() as usize).min(GAUGE_W);
            let bar = Self::gauge_color(frac, c);
            out.push(hdr("BUDGET"));
            out.push(Line::from(vec![
                Span::raw("  "),
                Span::styled("\u{2588}".repeat(filled), Style::default().fg(bar)),
                Span::styled("\u{2591}".repeat(GAUGE_W - filled), Style::default().fg(c.dim)),
                Span::styled(
                    format!("  {:>3.0}%", frac * 100.0),
                    Style::default().fg(bar).add_modifier(Modifier::BOLD),
                ),
            ]));
            out.push(Line::from(Span::styled(
                truncate_chars(
                    &format!("  {} of {} monthly", fmt_usd(spent), fmt_usd(limit)),
                    maxw,
                ),
                Style::default().fg(c.dim),
            )));
            if let Some(dl) = v.daily_limit_usd.filter(|l| *l > 0.0) {
                let ds = v.daily_spent_usd.unwrap_or(0.0);
                out.push(Line::from(Span::styled(
                    truncate_chars(&format!("  {} of {} today", fmt_usd(ds), fmt_usd(dl)), maxw),
                    Style::default().fg(c.dim),
                )));
            }
            out.push(Line::from(""));
        }

        // ── TOKENS (grouped thousands) ──────────────────────────────────────
        out.push(hdr("TOKENS"));
        out.push(kv("input", group_thousands(v.input_tokens), c.success));
        out.push(kv("output", group_thousands(v.output_tokens), c.success));
        out.push(kv("total", group_thousands(v.total_tokens), c.secondary));
        out.push(Line::from(""));

        // ── SESSIONS ────────────────────────────────────────────────────────
        out.push(hdr("SESSIONS"));
        out.push(kv("billed", group_thousands(v.sessions), c.secondary));

        out
    }

    /// Number of content lines for the current payload (width-independent).
    fn content_len(&self) -> usize {
        let theme = crate::style::theme();
        self.build_lines(usize::MAX, &theme.colors).len()
    }

    /// Largest valid scroll offset given the last measured viewport.
    fn max_scroll(&self) -> usize {
        self.content_len().saturating_sub(self.viewport.get().max(1))
    }

    pub fn handle_key(&mut self, key: KeyEvent) -> CostDashboardAction {
        // Chorded shortcuts belong to the app, not the dashboard.
        if key.modifiers.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) {
            return CostDashboardAction::None;
        }
        let max = self.max_scroll();
        let page = self.viewport.get().max(1);
        match key.code {
            KeyCode::Esc | KeyCode::Char('q') => return CostDashboardAction::Close,
            KeyCode::Up | KeyCode::Char('k') => self.scroll = self.scroll.saturating_sub(1),
            KeyCode::Down | KeyCode::Char('j') => self.scroll = (self.scroll + 1).min(max),
            KeyCode::PageUp => self.scroll = self.scroll.saturating_sub(page),
            KeyCode::PageDown => self.scroll = (self.scroll + page).min(max),
            KeyCode::Home => self.scroll = 0,
            KeyCode::End => self.scroll = max,
            _ => {}
        }
        CostDashboardAction::None
    }

    pub fn draw(&self, frame: &mut Frame, area: Rect) {
        let theme = crate::style::theme();
        let c = &theme.colors;

        let w = DIALOG_W.min(area.width);
        let h = DIALOG_H.min(area.height);
        let x = area.x + area.width.saturating_sub(w) / 2;
        let y = area.y + area.height.saturating_sub(h) / 2;
        let rect = Rect::new(x, y, w, h);

        put(frame, Clear, rect);
        let block = Block::default()
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(Style::default().fg(c.primary))
            .title(Line::from(vec![
                Span::styled(" OSA ", Style::default().fg(c.primary).add_modifier(Modifier::BOLD)),
                Span::styled("\u{00b7} cost ", Style::default().fg(c.muted)),
            ]))
            .style(Style::default().bg(c.dialog_bg));
        put(frame, block, rect);

        let inner = Rect::new(
            rect.x + 2,
            rect.y + 1,
            rect.width.saturating_sub(4),
            rect.height.saturating_sub(2),
        );
        if inner.width < 12 || inner.height < 4 {
            return; // too small; border already drawn.
        }
        let iw = inner.width;
        let maxw = iw as usize;

        // Reserve the last inner row for the footer hint; the rest scrolls.
        let list_h = inner.height.saturating_sub(1) as usize;
        self.viewport.set(list_h.max(1));

        let lines = self.build_lines(maxw, c);
        let max = lines.len().saturating_sub(list_h);
        let scroll = self.scroll.min(max);

        for rel in 0..list_h {
            let Some(line) = lines.get(rel + scroll) else { break };
            put(
                frame,
                Paragraph::new(line.clone()),
                Rect::new(inner.x, inner.y + rel as u16, iw, 1),
            );
        }

        // ── footer hint ─────────────────────────────────────────────────────
        let hint_y = inner.y + inner.height.saturating_sub(1);
        let mut spans = vec![
            Span::styled("esc", Style::default().fg(c.secondary).add_modifier(Modifier::BOLD)),
            Span::styled(" close", Style::default().fg(c.dim)),
        ];
        if lines.len() > list_h {
            spans.push(Span::styled("   \u{2191}\u{2193}", Style::default().fg(c.secondary).add_modifier(Modifier::BOLD)));
            spans.push(Span::styled(" scroll", Style::default().fg(c.dim)));
        }
        put(frame, Paragraph::new(Line::from(spans)), Rect::new(inner.x, hint_y, iw, 1));
    }
}

/// Format a USD amount: cents for readable sums, extra precision for sub-cent
/// spend so a tiny real cost never collapses to `$0.00`.
fn fmt_usd(v: f64) -> String {
    let v = if v.is_finite() { v.max(0.0) } else { 0.0 };
    if v > 0.0 && v < 0.01 {
        format!("${v:.4}")
    } else {
        format!("${v:.2}")
    }
}

/// Keep just the calendar date from an ISO-8601 timestamp; pass through anything
/// that doesn't look like one.
fn fmt_since(s: &str) -> String {
    match s.split_once('T') {
        Some((date, _)) if date.len() == 10 => date.to_string(),
        _ => s.to_string(),
    }
}

/// Group an integer in thousands with `,` separators (`1234567` → `1,234,567`).
fn group_thousands(n: u64) -> String {
    let s = n.to_string();
    let len = s.len();
    let mut out = String::with_capacity(len + len / 3);
    for (i, ch) in s.chars().enumerate() {
        if i > 0 && (len - i) % 3 == 0 {
            out.push(',');
        }
        out.push(ch);
    }
    out
}

/// Fit into `max` DISPLAY COLUMNS on grapheme boundaries.
///
/// Delegates to the canonical fitter: a private char-count copy of this used to
/// let a CJK/emoji value over-run its reserved span and shove every column to
/// its right off the pane.
fn truncate_chars(s: &str, max: usize) -> String {
    crate::util::fit_cols(s, max)
}

#[cfg(test)]
mod cost_dashboard_tests {
    use super::*;
    use crossterm::event::KeyModifiers;
    use ratatui::{backend::TestBackend, Terminal};

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::empty())
    }

    fn budgeted() -> CostView {
        CostView {
            total_cost_usd: 42.678,
            total_tokens: 1_234_567,
            input_tokens: 987_654,
            output_tokens: 246_913,
            sessions: 128,
            since: "2026-07-18T00:00:00Z".into(),
            monthly_limit_usd: Some(50.0),
            monthly_spent_usd: Some(42.678),
            daily_limit_usd: Some(5.0),
            daily_spent_usd: Some(3.20),
        }
    }

    fn bare() -> CostView {
        CostView {
            total_cost_usd: 0.0,
            total_tokens: 0,
            input_tokens: 0,
            output_tokens: 0,
            sessions: 0,
            since: "2026-07-18T00:00:00Z".into(),
            monthly_limit_usd: None,
            monthly_spent_usd: None,
            daily_limit_usd: None,
            daily_spent_usd: None,
        }
    }

    #[test]
    fn draws_at_all_sizes_without_panic() {
        for make in [budgeted as fn() -> CostView, bare] {
            let mut d = CostDashboard::new(make());
            // Scroll to the bottom first so tiny-viewport clamping is exercised.
            d.handle_key(key(KeyCode::End));
            for (w, h) in [(1u16, 1u16), (10, 4), (40, 12), (70, 20), (200, 60)] {
                let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
                term.draw(|f| d.draw(f, f.area())).unwrap();
            }
        }
    }

    #[test]
    fn esc_and_q_close_scroll_keys_do_not() {
        let mut d = CostDashboard::new(budgeted());
        assert_eq!(d.handle_key(key(KeyCode::Down)), CostDashboardAction::None);
        assert_eq!(d.handle_key(key(KeyCode::Char('j'))), CostDashboardAction::None);
        assert_eq!(d.handle_key(key(KeyCode::Esc)), CostDashboardAction::Close);
        assert_eq!(d.handle_key(key(KeyCode::Char('q'))), CostDashboardAction::Close);
    }

    #[test]
    fn scroll_clamps_and_home_end_bound() {
        let mut d = CostDashboard::new(budgeted());
        d.viewport.set(4); // force a scrollable state.
        for _ in 0..100 {
            d.handle_key(key(KeyCode::Down));
        }
        assert_eq!(d.scroll, d.max_scroll());
        d.handle_key(key(KeyCode::Home));
        assert_eq!(d.scroll, 0);
        d.handle_key(key(KeyCode::Up)); // saturating at zero.
        assert_eq!(d.scroll, 0);
        d.handle_key(key(KeyCode::End));
        assert_eq!(d.scroll, d.max_scroll());
    }

    #[test]
    fn budget_lines_appear_only_with_limits() {
        let c = crate::style::theme().colors;
        let with = CostDashboard::new(budgeted()).build_lines(usize::MAX, &c).len();
        let without = CostDashboard::new(bare()).build_lines(usize::MAX, &c).len();
        assert!(with > without, "budget gauge should add rows");
    }

    #[test]
    fn thousands_grouping_and_usd_precision() {
        assert_eq!(group_thousands(0), "0");
        assert_eq!(group_thousands(999), "999");
        assert_eq!(group_thousands(1_234_567), "1,234,567");
        assert_eq!(fmt_usd(0.0), "$0.00");
        assert_eq!(fmt_usd(42.678), "$42.68");
        assert_eq!(fmt_usd(0.0004), "$0.0004");
        assert_eq!(fmt_since("2026-07-18T00:00:00Z"), "2026-07-18");
    }

    #[test]
    fn gauge_grades_and_clamps() {
        let c = crate::style::theme().colors;
        assert_eq!(CostDashboard::gauge_color(0.1, &c), c.success);
        assert_eq!(CostDashboard::gauge_color(0.7, &c), c.warning);
        assert_eq!(CostDashboard::gauge_color(0.99, &c), c.error);
        // Over-budget spend must not overflow the gauge track.
        let filled = ((1.8_f64.clamp(0.0, 1.0) * GAUGE_W as f64).round() as usize).min(GAUGE_W);
        assert!(filled <= GAUGE_W);
    }
}
