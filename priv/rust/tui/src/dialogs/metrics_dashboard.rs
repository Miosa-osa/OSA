//! `/metrics` — the telemetry dashboard.
//!
//! A branded overlay that answers "how is OSA performing right now" — a row of
//! headline metric cards (turns, messages, tool/LLM calls, noise-filter rate,
//! active sessions) over a scrollable latency table of every tool and provider
//! the agent has exercised, each with its call count and a color-graded avg/p99
//! bar. Sourced from the backend telemetry summary (`GET /api/v1/metrics`).
//!
//! Stateful: the app owns one [`MetricsDashboard`] built from the fetched
//! payload. The cards are a fixed header; the latency rows scroll. Arrow keys
//! and `j`/`k` move the cursor (kept visible via the shared scroll clamp), and
//! Esc closes. When there is no telemetry yet the table shows an empty hint but
//! the cards still render (all zeros), so the overlay is always meaningful.

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

const DIALOG_W: u16 = 74;
const DIALOG_H: u16 = 26;
/// Cells in each latency bar track.
const BAR_W: usize = 14;

/// A headline metric card (pre-aggregated by the backend).
pub struct MetricCard {
    pub label: String,
    pub value: String,
    pub note: String,
    /// `"good" | "warn" | "bad" | "neutral"` — selects the value color.
    pub tone: String,
}

/// One latency row: a tool or provider with call count and avg/p99 latency.
pub struct LatencyRow {
    pub name: String,
    /// `"tool"` or `"llm"` — rendered as a small group tag.
    pub kind: String,
    pub count: u64,
    pub avg_ms: f64,
    pub p99_ms: u64,
}

/// Everything the dashboard renders. Owned so `draw` never borrows `App`.
pub struct MetricsData {
    pub cards: Vec<MetricCard>,
    pub rows: Vec<LatencyRow>,
}

/// Bubble-up result of metrics-dashboard key handling.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MetricsAction {
    /// The overlay should be dismissed.
    Close,
    /// Key consumed; keep the overlay open.
    None,
}

pub struct MetricsDashboard {
    data: MetricsData,
    /// Cursor index into the latency rows.
    cursor: usize,
    /// Scroll offset in row space.
    scroll: usize,
    /// List height measured on the last draw, so key math matches the frame.
    list_viewport: Cell<usize>,
}

impl MetricsDashboard {
    pub fn new(data: MetricsData) -> Self {
        Self {
            data,
            cursor: 0,
            scroll: 0,
            list_viewport: Cell::new(1),
        }
    }

    fn tone_color(tone: &str, c: &crate::style::ThemeColors) -> Color {
        match tone {
            "good" => c.success,
            "warn" => c.warning,
            "bad" => c.error,
            _ => c.primary,
        }
    }

    /// Grade a p99 latency: snappy → noticeable → slow.
    fn latency_color(p99_ms: u64, c: &crate::style::ThemeColors) -> Color {
        if p99_ms < 500 {
            c.success
        } else if p99_ms < 2000 {
            c.warning
        } else {
            c.error
        }
    }

    /// Largest p99 across the rows (>=1) so bars scale to the worst offender.
    fn max_p99(&self) -> u64 {
        self.data.rows.iter().map(|r| r.p99_ms).max().unwrap_or(0).max(1)
    }

    fn last(&self) -> usize {
        self.data.rows.len().saturating_sub(1)
    }

    fn adjust_scroll(&mut self) {
        let vp = self.list_viewport.get().max(1);
        self.scroll = crate::dialogs::clamp_scroll_to_cursor(self.scroll, self.cursor, vp);
    }

    pub fn handle_key(&mut self, key: KeyEvent) -> MetricsAction {
        // Chorded shortcuts belong to the app, not this overlay.
        if key.modifiers.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) {
            return MetricsAction::None;
        }
        let last = self.last();
        let page = self.list_viewport.get().max(1);
        match key.code {
            KeyCode::Esc | KeyCode::Char('q') => return MetricsAction::Close,
            KeyCode::Up | KeyCode::Char('k') => {
                self.cursor = self.cursor.saturating_sub(1);
                self.adjust_scroll();
            }
            KeyCode::Down | KeyCode::Char('j') => {
                self.cursor = (self.cursor + 1).min(last);
                self.adjust_scroll();
            }
            KeyCode::PageUp => {
                self.cursor = self.cursor.saturating_sub(page);
                self.adjust_scroll();
            }
            KeyCode::PageDown => {
                self.cursor = (self.cursor + page).min(last);
                self.adjust_scroll();
            }
            KeyCode::Home => {
                self.cursor = 0;
                self.adjust_scroll();
            }
            KeyCode::End => {
                self.cursor = last;
                self.adjust_scroll();
            }
            _ => {}
        }
        MetricsAction::None
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
                Span::styled("\u{00b7} metrics ", Style::default().fg(c.muted)),
            ]))
            .style(Style::default().bg(c.dialog_bg));
        put(frame, block, rect);

        let inner = Rect::new(
            rect.x + 2,
            rect.y + 1,
            rect.width.saturating_sub(4),
            rect.height.saturating_sub(2),
        );
        if inner.width < 16 || inner.height < 6 {
            return; // too small; border already drawn.
        }
        let iw = inner.width;
        let maxw = iw as usize;
        let mut cy = inner.y;

        // ── headline cards (grid) ──────────────────────────────────────────
        let card_w: usize = 22;
        let cols = ((maxw + 1) / (card_w + 1)).max(1);
        let card_rows = self.data.cards.len().div_ceil(cols);
        for (i, card) in self.data.cards.iter().enumerate() {
            let col = i % cols;
            let row = i / cols;
            let cx = inner.x + (col * (card_w + 1)) as u16;
            let cw = card_w as u16;
            let base = cy + (row * 3) as u16;
            if base + 1 >= inner.y + inner.height {
                break;
            }
            put(frame, Paragraph::new(Line::from(Span::styled(
                truncate_chars(&card.label.to_uppercase(), card_w),
                Style::default().fg(c.muted).add_modifier(Modifier::BOLD),
            ))), Rect::new(cx, base, cw, 1));
            let vcolor = Self::tone_color(&card.tone, c);
            put(frame, Paragraph::new(Line::from(vec![
                Span::styled(
                    truncate_chars(&card.value, card_w.saturating_sub(1)),
                    Style::default().fg(vcolor).add_modifier(Modifier::BOLD),
                ),
                Span::styled(
                    truncate_chars(&format!("  {}", card.note), card_w.saturating_sub(card.value.chars().count() + 2)),
                    Style::default().fg(c.dim),
                ),
            ])), Rect::new(cx, base + 1, cw, 1));
        }
        cy += (card_rows * 3) as u16;

        // ── separator ──────────────────────────────────────────────────────
        if cy < inner.y + inner.height {
            put(frame, Paragraph::new(Span::styled(
                "\u{2500}".repeat(maxw),
                Style::default().fg(c.dim),
            )), Rect::new(inner.x, cy, iw, 1));
            cy += 1;
        }

        // ── latency table header ───────────────────────────────────────────
        if cy < inner.y + inner.height {
            put(frame, Paragraph::new(Line::from(Span::styled(
                format!("LATENCY  ({} monitored)", self.data.rows.len()),
                Style::default().fg(c.primary).add_modifier(Modifier::BOLD),
            ))), Rect::new(inner.x, cy, iw, 1));
            cy += 1;
        }

        // ── scrollable latency rows ────────────────────────────────────────
        let footer_y = inner.y + inner.height.saturating_sub(1);
        let list_h = footer_y.saturating_sub(cy) as usize;
        self.list_viewport.set(list_h.max(1));

        if self.data.rows.is_empty() {
            put(frame, Paragraph::new(Span::styled(
                "No telemetry recorded yet",
                Style::default().fg(c.muted),
            )).alignment(Alignment::Center),
                Rect::new(inner.x, cy + (list_h as u16) / 2, iw, 1));
        } else if list_h > 0 {
            let max_p99 = self.max_p99();
            let scroll = crate::dialogs::clamp_scroll_to_cursor(self.scroll, self.cursor, list_h);
            for rel in 0..list_h {
                let abs = rel + scroll;
                let Some(r) = self.data.rows.get(abs) else { break };
                let ry = cy + rel as u16;
                let selected = abs == self.cursor;
                self.draw_row(frame, r, max_p99, selected, maxw, Rect::new(inner.x, ry, iw, 1), &theme, c);
            }
        }

        // ── footer hint ────────────────────────────────────────────────────
        put(frame, Paragraph::new(Line::from(vec![
            Span::styled("\u{2191}\u{2193}", Style::default().fg(c.secondary).add_modifier(Modifier::BOLD)),
            Span::styled(" scroll  ", Style::default().fg(c.dim)),
            Span::styled("esc", Style::default().fg(c.secondary).add_modifier(Modifier::BOLD)),
            Span::styled(" close", Style::default().fg(c.dim)),
        ])), Rect::new(inner.x, footer_y, iw, 1));
    }

    #[allow(clippy::too_many_arguments)]
    fn draw_row(
        &self,
        frame: &mut Frame,
        r: &LatencyRow,
        max_p99: u64,
        selected: bool,
        maxw: usize,
        rect: Rect,
        theme: &crate::style::Theme,
        c: &crate::style::ThemeColors,
    ) {
        let bar_fg = Self::latency_color(r.p99_ms, c);
        let filled = ((r.p99_ms as f64 / max_p99 as f64) * BAR_W as f64).round() as usize;
        let filled = filled.min(BAR_W);
        let tag = if r.kind == "llm" { "llm " } else { "tool" };
        // name column is whatever is left after the fixed metrics columns.
        let name_w = maxw.saturating_sub(BAR_W + 30).max(6);
        let name = truncate_chars(&r.name, name_w);

        if selected {
            let raw = format!(
                "{:<tag$} {:<nw$}  {:>5}x  {:>6.0}ms  p99 {:>5}ms",
                tag, name, r.count, r.avg_ms, r.p99_ms,
                tag = 4, nw = name_w,
            );
            let mut s = truncate_chars(&raw, maxw);
            let pad = maxw.saturating_sub(s.chars().count());
            s.push_str(&" ".repeat(pad));
            put(frame, Paragraph::new(Line::from(Span::styled(s, theme.button_active()))), rect);
            return;
        }

        let spans = vec![
            Span::styled(format!("{tag} "), Style::default().fg(c.dim)),
            Span::styled(
                format!("{name:<name_w$}  "),
                Style::default().fg(c.secondary).add_modifier(Modifier::BOLD),
            ),
            Span::styled(format!("{:>5}x ", r.count), Style::default().fg(c.muted)),
            Span::styled("\u{2588}".repeat(filled), Style::default().fg(bar_fg)),
            Span::styled("\u{2591}".repeat(BAR_W - filled), Style::default().fg(c.dim)),
            Span::styled(format!(" p99 {:>5}ms", r.p99_ms), Style::default().fg(bar_fg)),
        ];
        put(frame, Paragraph::new(Line::from(spans)), rect);
    }
}

/// Char-boundary-safe truncation (multi-byte names can never panic).
fn truncate_chars(s: &str, max: usize) -> String {
    if s.chars().count() > max {
        let take = max.saturating_sub(1);
        format!("{}\u{2026}", s.chars().take(take).collect::<String>())
    } else {
        s.to_string()
    }
}

#[cfg(test)]
mod metrics_dashboard_tests {
    use super::*;
    use ratatui::{backend::TestBackend, Terminal};

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::empty())
    }

    fn card(label: &str, value: &str, tone: &str) -> MetricCard {
        MetricCard { label: label.into(), value: value.into(), note: "note".into(), tone: tone.into() }
    }

    fn row(name: &str, kind: &str, count: u64, avg: f64, p99: u64) -> LatencyRow {
        LatencyRow { name: name.into(), kind: kind.into(), count, avg_ms: avg, p99_ms: p99 }
    }

    fn sample() -> MetricsData {
        MetricsData {
            cards: vec![
                card("Turns", "42", "neutral"),
                card("Tool Calls", "310", "good"),
                card("Noise Filter", "62", "warn"),
                card("LLM Calls", "88", "bad"),
            ],
            rows: vec![
                row("read_file", "tool", 120, 3.5, 40),
                row("web_search", "tool", 12, 812.0, 1900),
                row("zhipu", "llm", 88, 2100.0, 4200),
                row("\u{4e2d}\u{6587}\u{5de5}\u{5177}", "tool", 1, 5.0, 5),
            ],
        }
    }

    #[test]
    fn draws_at_all_sizes_without_panic() {
        let states = vec![
            MetricsData { cards: vec![], rows: vec![] },
            sample(),
        ];
        for data in states {
            let mut d = MetricsDashboard::new(data);
            // Push the cursor to the end so scroll math is exercised too.
            for _ in 0..10 {
                d.handle_key(key(KeyCode::Down));
            }
            for (w, h) in [(1u16, 1u16), (10, 4), (40, 12), (70, 20), (200, 60)] {
                let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
                term.draw(|f| d.draw(f, f.area())).unwrap();
            }
        }
    }

    #[test]
    fn cursor_moves_and_clamps() {
        let mut d = MetricsDashboard::new(sample());
        assert_eq!(d.cursor, 0);
        for _ in 0..50 {
            d.handle_key(key(KeyCode::Char('j')));
        }
        assert_eq!(d.cursor, d.data.rows.len() - 1);
        d.handle_key(key(KeyCode::Home));
        assert_eq!(d.cursor, 0);
        d.handle_key(key(KeyCode::End));
        assert_eq!(d.cursor, d.data.rows.len() - 1);
        d.handle_key(key(KeyCode::Up));
        assert_eq!(d.cursor, d.data.rows.len() - 2);
    }

    #[test]
    fn empty_rows_are_safe() {
        let mut d = MetricsDashboard::new(MetricsData { cards: vec![], rows: vec![] });
        // Movement on an empty table must not panic or wander.
        d.handle_key(key(KeyCode::Down));
        assert_eq!(d.cursor, 0);
        assert_eq!(d.handle_key(key(KeyCode::Esc)), MetricsAction::Close);
    }

    #[test]
    fn esc_and_q_close() {
        let mut d = MetricsDashboard::new(sample());
        assert_eq!(d.handle_key(key(KeyCode::Char('q'))), MetricsAction::Close);
        assert_eq!(d.handle_key(key(KeyCode::Esc)), MetricsAction::Close);
    }

    #[test]
    fn latency_grades_and_bar_never_overflows() {
        let c = crate::style::theme().colors;
        assert_eq!(MetricsDashboard::latency_color(100, &c), c.success);
        assert_eq!(MetricsDashboard::latency_color(900, &c), c.warning);
        assert_eq!(MetricsDashboard::latency_color(5000, &c), c.error);
        let d = MetricsDashboard::new(sample());
        let max_p99 = d.max_p99();
        assert!(max_p99 >= 1);
        for r in &d.data.rows {
            let filled = ((r.p99_ms as f64 / max_p99 as f64) * BAR_W as f64).round() as usize;
            assert!(filled.min(BAR_W) <= BAR_W);
        }
    }

    #[test]
    fn chorded_keys_ignored() {
        let mut d = MetricsDashboard::new(sample());
        let ctrl_c = KeyEvent::new(KeyCode::Char('c'), KeyModifiers::CONTROL);
        assert_eq!(d.handle_key(ctrl_c), MetricsAction::None);
        assert_eq!(d.cursor, 0);
    }
}
