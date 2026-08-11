//! `/doctor` — the backend diagnostics panel.
//!
//! A branded, scrollable overlay that answers "is OSA healthy right now?" — every
//! check the backend runs (runtime, CLI/TUI binaries, HTTP API, provider creds,
//! event router, workspace, Postgres/AMQP …) with a pass/fail/optional dot and its
//! one-line detail. Replaces the flat CLI text dump: a color-graded READY banner up
//! top, arrow through the checks, and press `f` to hide the passing ones and focus
//! on what's broken.
//!
//! Stateful: the app owns one [`DoctorPanel`] built from the live `/api/v1/doctor`
//! report. `handle_key` drives cursor/scroll and the failing-only filter. Esc first
//! clears an active filter, then closes on a second press (or when unfiltered).

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

const DIALOG_W: u16 = 76;
const DIALOG_H: u16 = 26;

/// Outcome of a single diagnostic check, mirroring the backend `:pass|:fail|:optional`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CheckStatus {
    Pass,
    Fail,
    Optional,
}

impl CheckStatus {
    /// Lenient parse of the backend's stringified status. Unknown → `Optional`
    /// (a non-alarming neutral), so a schema drift never renders a false failure.
    pub fn from_status(s: &str) -> Self {
        match s.trim().to_lowercase().as_str() {
            "pass" | "ok" | "true" => CheckStatus::Pass,
            "fail" | "error" | "false" => CheckStatus::Fail,
            _ => CheckStatus::Optional,
        }
    }

    fn dot_color(self, c: &crate::style::ThemeColors) -> Color {
        match self {
            CheckStatus::Pass => c.success,
            CheckStatus::Fail => c.error,
            CheckStatus::Optional => c.warning,
        }
    }

    fn glyph(self) -> &'static str {
        match self {
            CheckStatus::Pass => "\u{2713}",     // ✓
            CheckStatus::Fail => "\u{2717}",     // ✗
            CheckStatus::Optional => "\u{25CB}", // ○
        }
    }
}

/// One diagnostic row surfaced by the `/doctor` report.
pub struct DoctorCheck {
    pub name: String,
    pub status: CheckStatus,
    pub detail: String,
}

/// Bubble-up result of doctor-panel key handling.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DoctorPanelAction {
    /// The overlay should be dismissed.
    Close,
    /// Key consumed; keep the overlay open.
    None,
}

pub struct DoctorPanel {
    checks: Vec<DoctorCheck>,
    /// When true, only `Fail` rows are shown.
    failing_only: bool,
    /// Cursor index into the currently-visible (filtered) list.
    cursor: usize,
    /// Scroll offset in visible-row space.
    scroll: usize,
    /// List height measured on the last draw, so key math matches the real dialog.
    list_viewport: Cell<usize>,
}

impl DoctorPanel {
    pub fn new(checks: Vec<DoctorCheck>) -> Self {
        Self {
            checks,
            failing_only: false,
            cursor: 0,
            scroll: 0,
            list_viewport: Cell::new((DIALOG_H as usize).saturating_sub(5)),
        }
    }

    fn count(&self, want: CheckStatus) -> usize {
        self.checks.iter().filter(|c| c.status == want).count()
    }

    fn ready(&self) -> bool {
        self.count(CheckStatus::Fail) == 0
    }

    /// Indices of the checks visible under the current filter (original order).
    fn visible(&self) -> Vec<usize> {
        self.checks
            .iter()
            .enumerate()
            .filter(|(_, c)| !self.failing_only || c.status == CheckStatus::Fail)
            .map(|(i, _)| i)
            .collect()
    }

    fn adjust_scroll(&mut self) {
        let vp = self.list_viewport.get().max(1);
        self.scroll = crate::dialogs::clamp_scroll_to_cursor(self.scroll, self.cursor, vp);
    }

    pub fn handle_key(&mut self, key: KeyEvent) -> DoctorPanelAction {
        // Chorded shortcuts belong to the app, not this panel.
        if key.modifiers.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) {
            return DoctorPanelAction::None;
        }
        let last = self.visible().len().saturating_sub(1);
        let page = self.list_viewport.get().max(1);
        match key.code {
            KeyCode::Esc => {
                if self.failing_only {
                    self.failing_only = false;
                    self.cursor = 0;
                    self.scroll = 0;
                } else {
                    return DoctorPanelAction::Close;
                }
            }
            KeyCode::Char('f') | KeyCode::Char('F') => {
                // Toggle the failing-only filter; keep cursor in-bounds after.
                self.failing_only = !self.failing_only;
                self.cursor = 0;
                self.scroll = 0;
            }
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
        DoctorPanelAction::None
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
                Span::styled("\u{00b7} doctor ", Style::default().fg(c.muted)),
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
        let mut cy = inner.y;

        let (passed, failed, optional) =
            (self.count(CheckStatus::Pass), self.count(CheckStatus::Fail), self.count(CheckStatus::Optional));

        // ── READY banner ───────────────────────────────────────────────────
        let (banner, banner_color) = if self.checks.is_empty() {
            ("UNKNOWN", c.muted)
        } else if self.ready() {
            ("READY", c.success)
        } else {
            ("NOT READY", c.error)
        };
        put(
            frame,
            Paragraph::new(Line::from(vec![
                Span::styled("\u{25CF} ", Style::default().fg(banner_color)),
                Span::styled(banner, Style::default().fg(banner_color).add_modifier(Modifier::BOLD)),
                Span::styled(
                    format!(
                        "   {passed} pass \u{00b7} {failed} fail \u{00b7} {optional} optional"
                    ),
                    Style::default().fg(c.dim),
                ),
            ])),
            Rect::new(inner.x, cy, iw, 1),
        );
        cy += 1;

        // ── separator ──────────────────────────────────────────────────────
        put(
            frame,
            Paragraph::new(Span::styled("\u{2500}".repeat(maxw), Style::default().fg(c.dim))),
            Rect::new(inner.x, cy, iw, 1),
        );
        cy += 1;

        // ── scrollable check list ──────────────────────────────────────────
        let list_h = inner.height.saturating_sub(3); // banner + separator + footer.
        self.list_viewport.set((list_h as usize).max(1));

        let visible = self.visible();
        if visible.is_empty() {
            let msg = if self.checks.is_empty() {
                "No diagnostics available".to_string()
            } else {
                "No failing checks \u{2014} all healthy".to_string()
            };
            put(
                frame,
                Paragraph::new(Span::styled(truncate_chars(&msg, maxw), Style::default().fg(c.muted)))
                    .alignment(Alignment::Center),
                Rect::new(inner.x, cy + list_h / 2, iw, 1),
            );
        } else {
            let scroll =
                crate::dialogs::clamp_scroll_to_cursor(self.scroll, self.cursor, (list_h as usize).max(1));
            for rel in 0..(list_h as usize) {
                let abs = rel + scroll;
                let Some(&ci) = visible.get(abs) else { break };
                let check = &self.checks[ci];
                let ry = cy + rel as u16;
                let selected = abs == self.cursor;
                let dot_color = check.status.dot_color(c);

                if selected {
                    // Full-width highlight bar: glyph + name + inline detail.
                    let raw = format!("{} {}   {}", check.status.glyph(), check.name, check.detail);
                    let s = crate::util::pad_cols(&raw, maxw);
                    put(
                        frame,
                        Paragraph::new(Line::from(Span::styled(s, theme.button_active()))),
                        Rect::new(inner.x, ry, iw, 1),
                    );
                } else {
                    let name = truncate_chars(&check.name, maxw.saturating_sub(4));
                    // glyph(1) + space(1) + name + gap(3)
                    let used = 2 + crate::util::cols(&name);
                    let mut spans = vec![
                        Span::styled(format!("{} ", check.status.glyph()), Style::default().fg(dot_color)),
                        Span::styled(name, Style::default().fg(c.secondary).add_modifier(Modifier::BOLD)),
                    ];
                    let remaining = maxw.saturating_sub(used);
                    if remaining > 5 && !check.detail.is_empty() {
                        let detail = truncate_chars(&check.detail, remaining - 3);
                        spans.push(Span::styled(format!("   {detail}"), Style::default().fg(c.dim)));
                    }
                    put(
                        frame,
                        Paragraph::new(Line::from(spans)),
                        Rect::new(inner.x, ry, iw, 1),
                    );
                }
            }
        }

        // ── footer hint ────────────────────────────────────────────────────
        let hint_y = inner.y + inner.height.saturating_sub(1);
        put(
            frame,
            Paragraph::new(Line::from(vec![
                Span::styled("\u{2191}\u{2193}", Style::default().fg(c.secondary).add_modifier(Modifier::BOLD)),
                Span::styled(" nav  ", Style::default().fg(c.dim)),
                Span::styled("f", Style::default().fg(c.secondary).add_modifier(Modifier::BOLD)),
                Span::styled(
                    if self.failing_only { " all  " } else { " failing  " },
                    Style::default().fg(c.dim),
                ),
                Span::styled("esc", Style::default().fg(c.secondary).add_modifier(Modifier::BOLD)),
                Span::styled(
                    if self.failing_only { " clear" } else { " close" },
                    Style::default().fg(c.dim),
                ),
            ])),
            Rect::new(inner.x, hint_y, iw, 1),
        );
    }
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
mod doctor_panel_tests {
    use super::*;
    use ratatui::{backend::TestBackend, Terminal};

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::empty())
    }

    fn sample() -> Vec<DoctorCheck> {
        vec![
            DoctorCheck { name: "Runtime".into(), status: CheckStatus::Pass, detail: "OTP 27".into() },
            DoctorCheck { name: "TUI".into(), status: CheckStatus::Fail, detail: "binary not found".into() },
            DoctorCheck { name: "PostgreSQL".into(), status: CheckStatus::Optional, detail: "not configured".into() },
            DoctorCheck { name: "\u{4e2d}\u{6587}".into(), status: CheckStatus::Fail, detail: "\u{20ac}".repeat(90) },
        ]
    }

    #[test]
    fn from_status_is_lenient() {
        assert_eq!(CheckStatus::from_status("pass"), CheckStatus::Pass);
        assert_eq!(CheckStatus::from_status("FAIL"), CheckStatus::Fail);
        assert_eq!(CheckStatus::from_status("optional"), CheckStatus::Optional);
        // Unknown / drifted values fall back to the neutral Optional.
        assert_eq!(CheckStatus::from_status("weird"), CheckStatus::Optional);
    }

    #[test]
    fn ready_reflects_failures() {
        let p = DoctorPanel::new(sample());
        assert!(!p.ready());
        assert_eq!(p.count(CheckStatus::Fail), 2);
        let healthy = DoctorPanel::new(vec![DoctorCheck {
            name: "Runtime".into(),
            status: CheckStatus::Pass,
            detail: "ok".into(),
        }]);
        assert!(healthy.ready());
    }

    #[test]
    fn failing_filter_narrows_and_toggles() {
        let mut p = DoctorPanel::new(sample());
        assert_eq!(p.visible().len(), 4);
        p.handle_key(key(KeyCode::Char('f')));
        assert!(p.failing_only);
        assert_eq!(p.visible().len(), 2); // only the two Fail rows
        // Esc clears the filter before closing.
        assert_eq!(p.handle_key(key(KeyCode::Esc)), DoctorPanelAction::None);
        assert!(!p.failing_only);
        assert_eq!(p.handle_key(key(KeyCode::Esc)), DoctorPanelAction::Close);
    }

    #[test]
    fn cursor_moves_and_clamps() {
        let mut p = DoctorPanel::new(sample());
        for _ in 0..20 {
            p.handle_key(key(KeyCode::Down));
        }
        assert_eq!(p.cursor, p.visible().len() - 1);
        p.handle_key(key(KeyCode::Home));
        assert_eq!(p.cursor, 0);
    }

    #[test]
    fn empty_report_is_safe() {
        let mut p = DoctorPanel::new(Vec::new());
        assert!(p.ready()); // no failures ⇒ vacuously ready
        assert_eq!(p.visible().len(), 0);
        p.handle_key(key(KeyCode::Down));
        assert_eq!(p.cursor, 0);
        assert_eq!(p.handle_key(key(KeyCode::Esc)), DoctorPanelAction::Close);
    }

    #[test]
    fn draws_at_all_sizes_without_panic() {
        let states: Vec<(Vec<DoctorCheck>, bool)> = vec![
            (Vec::new(), false),
            (sample(), false),
            (sample(), true),
        ];
        for (checks, failing_only) in states {
            let mut p = DoctorPanel::new(checks);
            if failing_only {
                p.handle_key(key(KeyCode::Char('f')));
            }
            for (w, h) in [(1u16, 1u16), (10, 4), (40, 12), (70, 20), (200, 60)] {
                let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
                term.draw(|f| p.draw(f, f.area())).unwrap();
            }
        }
    }
}
