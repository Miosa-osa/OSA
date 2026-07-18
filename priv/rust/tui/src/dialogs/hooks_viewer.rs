//! `/hooks` — the registered-hooks viewer.
//!
//! A branded, scrollable overlay that answers "what fires around my tool calls,
//! and how expensive is it?" — every hook OSA has wired, grouped under the
//! lifecycle event it listens on (`pre_tool_use`, `post_tool_use`, …). Each
//! event is a bold header carrying a dim, right-aligned metric summary (call
//! count + average latency, when the backend reported metrics), followed by its
//! hooks indented and sorted by priority so the execution order reads top-down —
//! lower priority runs first. A footer tallies the total hook count.
//!
//! Stateful: the app owns one [`HooksViewer`] built from the live
//! `GET /api/v1/hooks` payload. Navigation is plain cursor movement over the
//! flattened header+hook row list (no filter box), keeping the selected row
//! visible as it scrolls. Esc/`q` closes.

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

const DIALOG_W: u16 = 72;
const DIALOG_H: u16 = 26;

/// One hook registered on an event: a name and its ordering priority.
pub struct HookEntry {
    pub name: String,
    pub priority: i64,
}

/// A lifecycle event and the hooks bound to it, plus rolled-up metrics for the
/// event (`calls`/`avg_us`; `calls == 0` means the backend reported no metrics).
pub struct EventHooks {
    pub event: String,
    pub hooks: Vec<HookEntry>,
    pub calls: i64,
    pub avg_us: i64,
}

/// Bubble-up result of hooks-viewer key handling.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HooksViewerAction {
    /// The overlay should be dismissed.
    Close,
    /// Key consumed; keep the overlay open.
    None,
}

/// One flattened, navigable line: an event header, or a hook at `(event, hook)`.
enum Row {
    Header(usize),
    Hook(usize, usize),
}

pub struct HooksViewer {
    events: Vec<EventHooks>,
    /// Cursor index into the flattened header+hook row list.
    cursor: usize,
    /// Scroll offset in flattened-row space.
    scroll: usize,
    /// List height measured on the last draw, so `handle_key` page/scroll math
    /// matches the real dialog rather than the `DIALOG_H` upper bound.
    list_viewport: Cell<usize>,
}

impl HooksViewer {
    /// Build the viewer, sorting each event's hooks by ascending priority so the
    /// rendered order matches real execution order (lower priority runs first).
    pub fn new(mut events: Vec<EventHooks>) -> Self {
        for e in &mut events {
            e.hooks.sort_by(|a, b| a.priority.cmp(&b.priority).then(a.name.cmp(&b.name)));
        }
        Self {
            events,
            cursor: 0,
            scroll: 0,
            list_viewport: Cell::new((DIALOG_H as usize).saturating_sub(3)),
        }
    }

    /// Total hooks across every event (the footer tally).
    fn total_hooks(&self) -> usize {
        self.events.iter().map(|e| e.hooks.len()).sum()
    }

    /// Flatten events into the navigable row list (header then its hooks).
    fn rows(&self) -> Vec<Row> {
        let mut rows = Vec::with_capacity(self.events.len() + self.total_hooks());
        for (ei, e) in self.events.iter().enumerate() {
            rows.push(Row::Header(ei));
            for hi in 0..e.hooks.len() {
                rows.push(Row::Hook(ei, hi));
            }
        }
        rows
    }

    /// Re-clamp the stored scroll so the cursor row stays visible (uses the last
    /// measured viewport height).
    fn adjust_scroll(&mut self) {
        let vp = self.list_viewport.get().max(1);
        self.scroll = crate::dialogs::clamp_scroll_to_cursor(self.scroll, self.cursor, vp);
    }

    pub fn handle_key(&mut self, key: KeyEvent) -> HooksViewerAction {
        // Chorded shortcuts belong to the app, not this overlay.
        if key.modifiers.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) {
            return HooksViewerAction::None;
        }
        let last = self.rows().len().saturating_sub(1);
        let page = self.list_viewport.get().max(1);
        match key.code {
            KeyCode::Esc | KeyCode::Char('q') => return HooksViewerAction::Close,
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
        HooksViewerAction::None
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
                Span::styled("\u{00b7} hooks ", Style::default().fg(c.muted)),
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

        // ── scrollable list (reserve last row for the footer tally) ─────────
        let list_h = inner.height.saturating_sub(1);
        self.list_viewport.set((list_h as usize).max(1));

        if self.events.is_empty() {
            put(
                frame,
                Paragraph::new(Span::styled(
                    truncate_chars("No hooks registered", maxw),
                    Style::default().fg(c.muted),
                ))
                .alignment(Alignment::Center),
                Rect::new(inner.x, inner.y + list_h / 2, iw, 1),
            );
        } else {
            let rows = self.rows();
            let scroll =
                crate::dialogs::clamp_scroll_to_cursor(self.scroll, self.cursor, (list_h as usize).max(1));

            for rel in 0..(list_h as usize) {
                let abs = rel + scroll;
                let Some(row) = rows.get(abs) else { break };
                let ry = inner.y + rel as u16;
                let selected = abs == self.cursor;
                match row {
                    Row::Header(ei) => self.draw_header(frame, c, &theme, *ei, selected, maxw, Rect::new(inner.x, ry, iw, 1)),
                    Row::Hook(ei, hi) => self.draw_hook(frame, c, &theme, *ei, *hi, selected, maxw, Rect::new(inner.x, ry, iw, 1)),
                }
            }
        }

        // ── footer: total tally + ordering note + dismiss hint ──────────────
        let total = self.total_hooks();
        let n_ev = self.events.len();
        let footer_y = inner.y + inner.height.saturating_sub(1);
        put(
            frame,
            Paragraph::new(Line::from(vec![
                Span::styled(
                    format!("{total} hooks"),
                    Style::default().fg(c.primary).add_modifier(Modifier::BOLD),
                ),
                Span::styled(format!(" across {n_ev} events  "), Style::default().fg(c.dim)),
                Span::styled("lower priority runs first  ", Style::default().fg(c.muted)),
                Span::styled("esc", Style::default().fg(c.secondary).add_modifier(Modifier::BOLD)),
                Span::styled(" close", Style::default().fg(c.dim)),
            ])),
            Rect::new(inner.x, footer_y, iw, 1),
        );
    }

    /// Event header: bold name on the left, dim metric summary right-aligned.
    fn draw_header(&self, frame: &mut Frame, c: &crate::style::ThemeColors, theme: &crate::style::Theme, ei: usize, selected: bool, maxw: usize, rect: Rect) {
        let e = &self.events[ei];
        let metric = if e.calls > 0 {
            format!("{} calls \u{00b7} avg {} \u{00b5}s", e.calls, e.avg_us)
        } else {
            String::new()
        };
        let name = truncate_chars(&e.event, maxw);

        if selected {
            // Full-width highlight bar carrying name and (if it fits) the metric.
            let raw = if metric.is_empty() {
                name.clone()
            } else {
                format!("{name}   {metric}")
            };
            let mut s = truncate_chars(&raw, maxw);
            let pad = maxw.saturating_sub(s.chars().count());
            s.push_str(&" ".repeat(pad));
            put(frame, Paragraph::new(Line::from(Span::styled(s, theme.button_active()))), rect);
            return;
        }

        let name_len = name.chars().count();
        let metric_len = metric.chars().count();
        let mut spans = vec![Span::styled(
            name,
            Style::default().fg(c.primary).add_modifier(Modifier::BOLD),
        )];
        if !metric.is_empty() && name_len + 2 + metric_len <= maxw {
            let pad = maxw - name_len - metric_len;
            spans.push(Span::raw(" ".repeat(pad)));
            spans.push(Span::styled(metric, Style::default().fg(c.dim)));
        }
        put(frame, Paragraph::new(Line::from(spans)), rect);
    }

    /// Hook row: indented `priority  name`, sorted so it reads in run order.
    fn draw_hook(&self, frame: &mut Frame, c: &crate::style::ThemeColors, theme: &crate::style::Theme, ei: usize, hi: usize, selected: bool, maxw: usize, rect: Rect) {
        let hook = &self.events[ei].hooks[hi];
        if selected {
            let raw = format!("  {:>4}  {}", hook.priority, hook.name);
            let mut s = truncate_chars(&raw, maxw);
            let pad = maxw.saturating_sub(s.chars().count());
            s.push_str(&" ".repeat(pad));
            put(frame, Paragraph::new(Line::from(Span::styled(s, theme.button_active()))), rect);
            return;
        }
        let prio = format!("  {:>4}  ", hook.priority);
        let used = prio.chars().count();
        let name = truncate_chars(&hook.name, maxw.saturating_sub(used));
        put(
            frame,
            Paragraph::new(Line::from(vec![
                Span::styled(prio, Style::default().fg(c.dim)),
                Span::styled(name, Style::default().fg(c.secondary)),
            ])),
            rect,
        );
    }
}

/// Char-boundary-safe truncation (multi-byte hook/event names can never panic).
fn truncate_chars(s: &str, max: usize) -> String {
    if s.chars().count() > max {
        let take = max.saturating_sub(1);
        format!("{}\u{2026}", s.chars().take(take).collect::<String>())
    } else {
        s.to_string()
    }
}

#[cfg(test)]
mod hooks_viewer_tests {
    use super::*;
    use ratatui::{backend::TestBackend, Terminal};

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::empty())
    }

    fn sample() -> Vec<EventHooks> {
        vec![
            EventHooks {
                event: "pre_tool_use".into(),
                hooks: vec![
                    HookEntry { name: "guardrail_check".into(), priority: 50 },
                    HookEntry { name: "audit_log".into(), priority: 10 },
                ],
                calls: 128,
                avg_us: 42,
            },
            EventHooks {
                event: "post_tool_use".into(),
                hooks: vec![HookEntry { name: "\u{4e2d}\u{6587}\u{30d5}\u{30c3}\u{30af}".into(), priority: 5 }],
                calls: 0, // no metrics reported
                avg_us: 0,
            },
        ]
    }

    #[test]
    fn hooks_sort_by_priority_ascending() {
        let v = HooksViewer::new(sample());
        // Lower priority must run (render) first within an event.
        assert_eq!(v.events[0].hooks[0].priority, 10);
        assert_eq!(v.events[0].hooks[1].priority, 50);
    }

    #[test]
    fn total_and_rows_account_for_headers() {
        let v = HooksViewer::new(sample());
        assert_eq!(v.total_hooks(), 3);
        // 2 headers + 3 hook rows.
        assert_eq!(v.rows().len(), 5);
    }

    #[test]
    fn cursor_clamps_over_flattened_rows() {
        let mut v = HooksViewer::new(sample());
        for _ in 0..50 {
            v.handle_key(key(KeyCode::Down));
        }
        assert_eq!(v.cursor, v.rows().len() - 1);
        v.handle_key(key(KeyCode::Home));
        assert_eq!(v.cursor, 0);
        assert_eq!(v.handle_key(key(KeyCode::Esc)), HooksViewerAction::Close);
        assert_eq!(v.handle_key(key(KeyCode::Char('q'))), HooksViewerAction::Close);
    }

    #[test]
    fn empty_is_safe() {
        let mut v = HooksViewer::new(Vec::new());
        assert_eq!(v.total_hooks(), 0);
        v.handle_key(key(KeyCode::Down)); // must not panic or wander
        assert_eq!(v.cursor, 0);
    }

    #[test]
    fn draws_at_all_sizes_without_panic() {
        let states = [sample(), Vec::new()];
        for events in states {
            let mut v = HooksViewer::new(events);
            v.handle_key(key(KeyCode::End));
            for (w, h) in [(1u16, 1u16), (10, 4), (40, 12), (70, 20), (200, 60)] {
                let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
                term.draw(|f| v.draw(f, f.area())).unwrap();
            }
        }
    }
}