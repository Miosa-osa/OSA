//! `/memory` — the persistent-memory browser. See file at
//! priv/rust/tui/src/dialogs/memory_browser.rs (written verbatim below).

use std::cell::Cell;

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::{
    prelude::*,
    widgets::{Block, BorderType, Borders, Clear, Paragraph},
};

fn put<W: ratatui::widgets::Widget>(frame: &mut Frame, widget: W, rect: Rect) {
    crate::app::event_loop::safe_render_widget(frame, widget, rect);
}

const DIALOG_W: u16 = 78;
const DIALOG_H: u16 = 26;

/// One remembered entry, as surfaced by the backend memory store.
pub struct MemoryEntry {
    pub content: String,
    pub category: String,
    pub scope: String,
    pub created_at: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MemoryBrowserAction {
    Close,
    None,
}

pub struct MemoryBrowser {
    entries: Vec<MemoryEntry>,
    filter: String,
    cursor: usize,
    scroll: usize,
    list_viewport: Cell<usize>,
}

impl MemoryBrowser {
    pub fn new(entries: Vec<MemoryEntry>) -> Self {
        Self {
            entries,
            filter: String::new(),
            cursor: 0,
            scroll: 0,
            list_viewport: Cell::new((DIALOG_H as usize).saturating_sub(4)),
        }
    }

    fn matches(e: &MemoryEntry, needle: &str) -> bool {
        e.content.to_lowercase().contains(needle)
            || e.category.to_lowercase().contains(needle)
            || e.scope.to_lowercase().contains(needle)
    }

    fn ordered(&self) -> Vec<usize> {
        if self.filter.is_empty() {
            (0..self.entries.len()).collect()
        } else {
            let needle = self.filter.to_lowercase();
            self.entries
                .iter()
                .enumerate()
                .filter(|(_, e)| Self::matches(e, &needle))
                .map(|(i, _)| i)
                .collect()
        }
    }

    fn adjust_scroll(&mut self) {
        let vp = self.list_viewport.get().max(1);
        self.scroll = crate::dialogs::clamp_scroll_to_cursor(self.scroll, self.cursor, vp);
    }

    pub fn handle_key(&mut self, key: KeyEvent) -> MemoryBrowserAction {
        if key.modifiers.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) {
            return MemoryBrowserAction::None;
        }
        let last = self.ordered().len().saturating_sub(1);
        let page = self.list_viewport.get().max(1);
        match key.code {
            KeyCode::Esc => {
                if self.filter.is_empty() {
                    return MemoryBrowserAction::Close;
                }
                self.filter.clear();
                self.cursor = 0;
                self.scroll = 0;
            }
            KeyCode::Up => { self.cursor = self.cursor.saturating_sub(1); self.adjust_scroll(); }
            KeyCode::Down => { self.cursor = (self.cursor + 1).min(last); self.adjust_scroll(); }
            KeyCode::Char('k') if self.filter.is_empty() => { self.cursor = self.cursor.saturating_sub(1); self.adjust_scroll(); }
            KeyCode::Char('j') if self.filter.is_empty() => { self.cursor = (self.cursor + 1).min(last); self.adjust_scroll(); }
            KeyCode::PageUp => { self.cursor = self.cursor.saturating_sub(page); self.adjust_scroll(); }
            KeyCode::PageDown => { self.cursor = (self.cursor + page).min(last); self.adjust_scroll(); }
            KeyCode::Home => { self.cursor = 0; self.adjust_scroll(); }
            KeyCode::End => { self.cursor = last; self.adjust_scroll(); }
            KeyCode::Backspace => { self.filter.pop(); self.cursor = 0; self.scroll = 0; }
            KeyCode::Char(c) => { self.filter.push(c); self.cursor = 0; self.scroll = 0; }
            _ => {}
        }
        MemoryBrowserAction::None
    }

    fn cat_color(cat: &str, c: &crate::style::ThemeColors) -> Color {
        match cat.to_lowercase().as_str() {
            "decision" => c.secondary,
            "lesson" => c.warning,
            "pattern" => c.success,
            "preference" => c.primary,
            "project" => c.grad_a,
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
                Span::styled("\u{00b7} memory ", Style::default().fg(c.muted)),
            ]))
            .style(Style::default().bg(c.dialog_bg));
        put(frame, block, rect);
        let inner = Rect::new(rect.x + 2, rect.y + 1, rect.width.saturating_sub(4), rect.height.saturating_sub(2));
        if inner.width < 12 || inner.height < 4 { return; }
        let iw = inner.width;
        let maxw = iw as usize;
        let mut cy = inner.y;
        let ordered = self.ordered();
        let total = self.entries.len();
        let shown = ordered.len();
        let count = if self.filter.is_empty() { format!("{total} memories") } else { format!("{shown}/{total} memories") };
        put(frame, Paragraph::new(Line::from(Span::styled(count, Style::default().fg(c.primary).add_modifier(Modifier::BOLD)))), Rect::new(inner.x, cy, iw, 1));
        cy += 1;
        let search = truncate_chars(&format!("search: {}\u{2588}", self.filter), maxw);
        let search_style = if self.filter.is_empty() { Style::default().fg(c.dim) } else { Style::default().fg(c.secondary) };
        put(frame, Paragraph::new(Line::from(Span::styled(search, search_style))), Rect::new(inner.x, cy, iw, 1));
        cy += 1;
        put(frame, Paragraph::new(Span::styled("\u{2500}".repeat(maxw), Style::default().fg(c.dim))), Rect::new(inner.x, cy, iw, 1));
        cy += 1;
        let list_h = inner.height.saturating_sub(4);
        self.list_viewport.set((list_h as usize).max(1));
        if shown == 0 {
            let msg = if self.filter.is_empty() { "No memories stored yet".to_string() } else { format!("No memories match \u{201c}{}\u{201d}", self.filter) };
            put(frame, Paragraph::new(Span::styled(truncate_chars(&msg, maxw), Style::default().fg(c.muted))).alignment(Alignment::Center), Rect::new(inner.x, cy + list_h / 2, iw, 1));
        } else {
            let scroll = crate::dialogs::clamp_scroll_to_cursor(self.scroll, self.cursor, (list_h as usize).max(1));
            for rel in 0..(list_h as usize) {
                let pos = rel + scroll;
                let Some(&ei) = ordered.get(pos) else { break };
                let e = &self.entries[ei];
                let ry = cy + rel as u16;
                let selected = pos == self.cursor;
                let cat = tag_label(&e.category);
                let ts = fmt_time(&e.created_at);
                if selected {
                    let raw = format!("{cat} {}   {ts}", e.content);
                    let mut s = truncate_chars(&raw, maxw);
                    let pad = maxw.saturating_sub(s.chars().count());
                    s.push_str(&" ".repeat(pad));
                    put(frame, Paragraph::new(Line::from(Span::styled(s, theme.button_active()))), Rect::new(inner.x, ry, iw, 1));
                } else {
                    let mut spans = vec![Span::styled(format!("{cat} "), Style::default().fg(Self::cat_color(&e.category, c)).add_modifier(Modifier::BOLD))];
                    let used = cat.chars().count() + 1;
                    let ts_w = if ts.is_empty() { 0 } else { ts.chars().count() + 2 };
                    let body_w = maxw.saturating_sub(used + ts_w);
                    let body = truncate_chars(&e.content, body_w);
                    let body_used = used + body.chars().count();
                    spans.push(Span::styled(body, Style::default().fg(c.secondary)));
                    if ts_w > 0 {
                        let gap = maxw.saturating_sub(body_used + ts.chars().count());
                        spans.push(Span::styled(format!("{}{ts}", " ".repeat(gap)), Style::default().fg(c.dim)));
                    }
                    put(frame, Paragraph::new(Line::from(spans)), Rect::new(inner.x, ry, iw, 1));
                }
            }
        }
        let hint_y = inner.y + inner.height.saturating_sub(1);
        put(frame, Paragraph::new(Line::from(vec![
            Span::styled("type", Style::default().fg(c.secondary).add_modifier(Modifier::BOLD)),
            Span::styled(" filter  ", Style::default().fg(c.dim)),
            Span::styled("\u{2191}\u{2193}", Style::default().fg(c.secondary).add_modifier(Modifier::BOLD)),
            Span::styled(" nav  ", Style::default().fg(c.dim)),
            Span::styled("esc", Style::default().fg(c.secondary).add_modifier(Modifier::BOLD)),
            Span::styled(if self.filter.is_empty() { " close" } else { " clear" }, Style::default().fg(c.dim)),
        ])), Rect::new(inner.x, hint_y, iw, 1));
    }
}

fn tag_label(cat: &str) -> String {
    let c = cat.trim();
    if c.is_empty() { "[memory]".to_string() } else { format!("[{c}]") }
}

fn fmt_time(ts: &str) -> String {
    let s = ts.trim();
    if s.is_empty() { return String::new(); }
    let cleaned = s.replace('T', " ");
    truncate_plain(&cleaned, 16)
}

fn truncate_plain(s: &str, max: usize) -> String { s.chars().take(max).collect() }

fn truncate_chars(s: &str, max: usize) -> String {
    if s.chars().count() > max {
        let take = max.saturating_sub(1);
        format!("{}\u{2026}", s.chars().take(take).collect::<String>())
    } else { s.to_string() }
}

// Full file (with #[cfg(test)] module: filter_narrows_case_insensitively,
// esc_clears_filter_then_closes, cursor_moves_and_clamps, empty_store_is_safe,
// fmt_time_compacts, draws_at_all_sizes_without_panic over
// [(1,1),(10,4),(40,12),(70,20),(200,60)]) is written to
// priv/rust/tui/src/dialogs/memory_browser.rs.