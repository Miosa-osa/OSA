//! `/tasks` — the current-task panel.
//!
//! A branded, scrollable overlay that answers "what is OSA working on?" — the
//! session's tracker tasks grouped by status, each with a colored status dot
//! and a priority tag. Replaces the flat `/tasks` text dump with real hierarchy:
//! in-progress work floats to the top, pending waits below it, and finished or
//! failed tasks settle at the bottom, each group headed by its name and count.
//!
//! Stateful: the app owns one [`TasksPanel`] built from the live tracker list
//! (fetched via `GET /api/v1/tasks-list`). `handle_key` is pure navigation —
//! arrows / `j`/`k` / paging move the cursor over the flat task order (never
//! over the group headers), and Esc closes. Scroll math uses the real measured
//! viewport so a cursor at the end of a long list stays on screen.

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

/// One tracker task, as surfaced by the backend.
pub struct TaskEntry {
    pub id: String,
    pub description: String,
    /// Lifecycle status: `pending | in_progress | completed | failed` (any
    /// other string sinks into a trailing "other" group).
    pub status: String,
    /// Free-form priority label, e.g. `high | normal | low`.
    pub priority: String,
}

/// Bubble-up result of tasks-panel key handling.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TasksPanelAction {
    /// The overlay should be dismissed.
    Close,
    /// Key consumed; keep the overlay open.
    None,
}

/// A single rendered line: a status group header, or the task at `usize`
/// position in the currently-ordered list.
enum RenderRow {
    Header(&'static str, usize),
    Task(usize),
}

/// Canonical status ordering: active work first, terminal states last.
const STATUS_ORDER: [&str; 5] = ["in_progress", "pending", "blocked", "completed", "failed"];

pub struct TasksPanel {
    tasks: Vec<TaskEntry>,
    /// Cursor index into the ordered task list (never over headers).
    cursor: usize,
    /// Scroll offset in *render-row* space (headers included).
    scroll: usize,
    /// List height measured on the last draw, so `handle_key` scroll/page math
    /// matches the real dialog instead of the `DIALOG_H` upper bound.
    list_viewport: Cell<usize>,
}

impl TasksPanel {
    pub fn new(tasks: Vec<TaskEntry>) -> Self {
        Self {
            tasks,
            cursor: 0,
            scroll: 0,
            list_viewport: Cell::new((DIALOG_H as usize).saturating_sub(4)),
        }
    }

    /// Normalized group key for a status string (lowercased, unknowns → "other").
    fn group_key(status: &str) -> &'static str {
        let s = status.to_lowercase();
        STATUS_ORDER
            .iter()
            .copied()
            .find(|k| *k == s.as_str())
            .unwrap_or("other")
    }

    /// Task indices in display order: grouped by status in canonical order,
    /// with any unrecognized status trailing under "other".
    fn ordered(&self) -> Vec<usize> {
        let mut out = Vec::with_capacity(self.tasks.len());
        for key in STATUS_ORDER.iter().copied().chain(std::iter::once("other")) {
            for (i, t) in self.tasks.iter().enumerate() {
                if Self::group_key(&t.status) == key {
                    out.push(i);
                }
            }
        }
        out
    }

    /// Build the flat renderable rows, inserting a header (with per-group count)
    /// whenever the group changes.
    fn render_rows(&self, ordered: &[usize]) -> Vec<RenderRow> {
        let mut rows = Vec::with_capacity(ordered.len() + STATUS_ORDER.len());
        let mut cur: Option<&'static str> = None;
        // First pass: per-group counts so the header can show "pending · 3".
        for (pos, &ti) in ordered.iter().enumerate() {
            let key = Self::group_key(&self.tasks[ti].status);
            if cur != Some(key) {
                let count = ordered
                    .iter()
                    .filter(|&&j| Self::group_key(&self.tasks[j].status) == key)
                    .count();
                rows.push(RenderRow::Header(key, count));
                cur = Some(key);
            }
            rows.push(RenderRow::Task(pos));
        }
        rows
    }

    /// Render-row index of the currently-selected task (0 if none).
    fn selected_render_idx(rows: &[RenderRow], cursor: usize) -> usize {
        rows.iter()
            .position(|r| matches!(r, RenderRow::Task(p) if *p == cursor))
            .unwrap_or(0)
    }

    /// Re-clamp the stored scroll so the cursor's row stays visible after a
    /// cursor change (uses the last measured viewport height).
    fn adjust_scroll(&mut self) {
        let ordered = self.ordered();
        let rows = self.render_rows(&ordered);
        let sel = Self::selected_render_idx(&rows, self.cursor);
        let vp = self.list_viewport.get().max(1);
        self.scroll = crate::dialogs::clamp_scroll_to_cursor(self.scroll, sel, vp);
    }

    pub fn handle_key(&mut self, key: KeyEvent) -> TasksPanelAction {
        // Chorded shortcuts belong to the app, not this overlay.
        if key.modifiers.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) {
            return TasksPanelAction::None;
        }
        let last = self.ordered().len().saturating_sub(1);
        let page = self.list_viewport.get().max(1);
        match key.code {
            KeyCode::Esc | KeyCode::Char('q') => return TasksPanelAction::Close,
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
        TasksPanelAction::None
    }

    /// Human label + dot color for a status group.
    fn status_style(key: &str, c: &crate::style::ThemeColors) -> (&'static str, Color) {
        match key {
            "in_progress" => ("in progress", c.warning),
            "pending" => ("pending", c.secondary),
            "blocked" => ("blocked", c.error),
            "completed" => ("completed", c.success),
            "failed" => ("failed", c.error),
            _ => ("other", c.muted),
        }
    }

    /// Color for a priority tag.
    fn priority_color(priority: &str, c: &crate::style::ThemeColors) -> Color {
        match priority.to_lowercase().as_str() {
            "high" | "critical" | "urgent" => c.error,
            "low" => c.dim,
            _ => c.muted,
        }
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
                Span::styled("\u{00b7} tasks ", Style::default().fg(c.muted)),
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

        let ordered = self.ordered();
        let total = self.tasks.len();

        // ── count summary ──────────────────────────────────────────────────
        let count = if total == 1 {
            "1 task".to_string()
        } else {
            format!("{total} tasks")
        };
        put(
            frame,
            Paragraph::new(Line::from(Span::styled(
                count,
                Style::default().fg(c.primary).add_modifier(Modifier::BOLD),
            ))),
            Rect::new(inner.x, cy, iw, 1),
        );
        cy += 1;

        // ── separator ──────────────────────────────────────────────────────
        put(
            frame,
            Paragraph::new(Span::styled(
                "\u{2500}".repeat(maxw),
                Style::default().fg(c.dim),
            )),
            Rect::new(inner.x, cy, iw, 1),
        );
        cy += 1;

        // ── scrollable list ────────────────────────────────────────────────
        let list_h = inner.height.saturating_sub(3); // summary + separator + help.
        self.list_viewport.set((list_h as usize).max(1));

        if ordered.is_empty() {
            put(
                frame,
                Paragraph::new(Span::styled(
                    "No active tasks",
                    Style::default().fg(c.muted),
                ))
                .alignment(Alignment::Center),
                Rect::new(inner.x, cy + list_h / 2, iw, 1),
            );
        } else {
            let rows = self.render_rows(&ordered);
            let sel = Self::selected_render_idx(&rows, self.cursor);
            let scroll =
                crate::dialogs::clamp_scroll_to_cursor(self.scroll, sel, (list_h as usize).max(1));

            for rel in 0..(list_h as usize) {
                let abs = rel + scroll;
                let Some(row) = rows.get(abs) else { break };
                let ry = cy + rel as u16;
                match row {
                    RenderRow::Header(key, n) => {
                        let (label, dot) = Self::status_style(key, c);
                        put(
                            frame,
                            Paragraph::new(Line::from(vec![
                                Span::styled("\u{25CF} ", Style::default().fg(dot)),
                                Span::styled(
                                    truncate_chars(label, maxw.saturating_sub(6)),
                                    Style::default().fg(c.primary).add_modifier(Modifier::BOLD),
                                ),
                                Span::styled(format!("  \u{00b7} {n}"), Style::default().fg(c.dim)),
                            ])),
                            Rect::new(inner.x, ry, iw, 1),
                        );
                    }
                    RenderRow::Task(pos) => {
                        let t = &self.tasks[ordered[*pos]];
                        let (_, dot) = Self::status_style(Self::group_key(&t.status), c);
                        let selected = *pos == self.cursor;
                        // Priority tag reserves a right-aligned slot when it fits.
                        let ptag = format!("[{}]", t.priority);
                        let pw = crate::util::cols(&ptag);
                        let show_tag = maxw > pw + 12 && !t.priority.is_empty();
                        let desc_budget = if show_tag {
                            maxw.saturating_sub(pw + 6) // "  \u{25CF} " + gap
                        } else {
                            maxw.saturating_sub(4)
                        };
                        let desc = truncate_chars(&t.description, desc_budget);

                        if selected {
                            let mut s = format!("  \u{25CF} {desc}");
                            if show_tag {
                                let used = crate::util::cols(&s);
                                let pad = maxw.saturating_sub(used + pw);
                                s.push_str(&" ".repeat(pad));
                                s.push_str(&ptag);
                            }
                            let s = crate::util::pad_cols(&s, maxw);
                            put(
                                frame,
                                Paragraph::new(Line::from(Span::styled(s, theme.button_active()))),
                                Rect::new(inner.x, ry, iw, 1),
                            );
                        } else {
                            let mut spans = vec![
                                Span::raw("  "),
                                Span::styled("\u{25CF} ", Style::default().fg(dot)),
                                Span::styled(desc, Style::default().fg(c.secondary)),
                            ];
                            if show_tag {
                                let used = 4 + t
                                    .description
                                    .chars()
                                    .count()
                                    .min(desc_budget);
                                let pad = maxw.saturating_sub(used + pw);
                                spans.push(Span::raw(" ".repeat(pad)));
                                spans.push(Span::styled(
                                    ptag,
                                    Style::default().fg(Self::priority_color(&t.priority, c)),
                                ));
                            }
                            put(
                                frame,
                                Paragraph::new(Line::from(spans)),
                                Rect::new(inner.x, ry, iw, 1),
                            );
                        }
                    }
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
                Span::styled("esc", Style::default().fg(c.secondary).add_modifier(Modifier::BOLD)),
                Span::styled(" close", Style::default().fg(c.dim)),
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
mod tasks_panel_tests {
    use super::*;
    use crossterm::event::KeyModifiers;
    use ratatui::{backend::TestBackend, Terminal};

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::empty())
    }

    fn sample() -> Vec<TaskEntry> {
        vec![
            TaskEntry { id: "t1".into(), description: "Write the parser".into(), status: "completed".into(), priority: "normal".into() },
            TaskEntry { id: "t2".into(), description: "Wire the endpoint".into(), status: "in_progress".into(), priority: "high".into() },
            TaskEntry { id: "t3".into(), description: "Draft the tests".into(), status: "pending".into(), priority: "low".into() },
            TaskEntry { id: "t4".into(), description: "Ship it".into(), status: "pending".into(), priority: "normal".into() },
            TaskEntry { id: "t5".into(), description: "\u{4e2d}\u{6587}\u{4efb}\u{52a1}".repeat(30), status: "failed".into(), priority: "\u{20ac}".repeat(40) },
            TaskEntry { id: "t6".into(), description: "Weird one".into(), status: "unknown_state".into(), priority: "".into() },
        ]
    }

    #[test]
    fn groups_in_canonical_status_order() {
        let p = TasksPanel::new(sample());
        let ordered = p.ordered();
        // in_progress must come before pending, pending before completed/failed.
        let status_at = |pos: usize| p.tasks[ordered[pos]].status.clone();
        assert_eq!(status_at(0), "in_progress");
        // Every task is represented exactly once.
        assert_eq!(ordered.len(), 6);
        // Unknown status sinks to the trailing "other" group (last).
        assert_eq!(status_at(ordered.len() - 1), "unknown_state");
    }

    #[test]
    fn cursor_navigates_and_clamps_over_tasks_only() {
        let mut p = TasksPanel::new(sample());
        for _ in 0..50 {
            p.handle_key(key(KeyCode::Down));
        }
        assert_eq!(p.cursor, p.ordered().len() - 1);
        p.handle_key(key(KeyCode::Home));
        assert_eq!(p.cursor, 0);
        // j/k mirror the arrows.
        p.handle_key(key(KeyCode::Char('j')));
        assert_eq!(p.cursor, 1);
        p.handle_key(key(KeyCode::Char('k')));
        assert_eq!(p.cursor, 0);
    }

    #[test]
    fn esc_and_q_close() {
        let mut p = TasksPanel::new(sample());
        assert_eq!(p.handle_key(key(KeyCode::Esc)), TasksPanelAction::Close);
        assert_eq!(p.handle_key(key(KeyCode::Char('q'))), TasksPanelAction::Close);
    }

    #[test]
    fn empty_list_is_safe() {
        let mut p = TasksPanel::new(Vec::new());
        assert_eq!(p.ordered().len(), 0);
        p.handle_key(key(KeyCode::Down));
        assert_eq!(p.cursor, 0);
        assert_eq!(p.handle_key(key(KeyCode::Esc)), TasksPanelAction::Close);
    }

    #[test]
    fn draws_at_all_sizes_without_panic() {
        let states: Vec<Vec<TaskEntry>> = vec![Vec::new(), sample()];
        for tasks in states {
            let mut p = TasksPanel::new(tasks);
            // Drive the cursor to the end so the end-of-list scroll path renders.
            for _ in 0..10 {
                p.handle_key(key(KeyCode::Down));
            }
            for (w, h) in [(1u16, 1u16), (10, 4), (40, 12), (70, 20), (200, 60)] {
                let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
                term.draw(|f| p.draw(f, f.area())).unwrap();
            }
        }
    }
}
