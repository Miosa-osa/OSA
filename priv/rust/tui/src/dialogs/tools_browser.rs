//! `/tools` — the wired-tool browser.
//!
//! A branded, scrollable overlay that answers "what can OSA actually call right
//! now?" — every tool the agent has available, with its one-line description and
//! (when unfiltered) grouped under the module that registered it. Replaces the
//! flat, unsearchable `/tools` text dump: type to fuzzily narrow the list, arrow
//! through the matches, and read each tool's purpose inline.
//!
//! Stateful: the app owns one [`ToolsBrowser`] built from the live tool registry.
//! `handle_key` is type-to-filter first (any char extends the query), so cursor
//! movement uses the arrow keys — `j`/`k` only move when the filter is empty, to
//! stay out of the way of the search box. Esc first clears a non-empty filter,
//! and only closes the overlay on a second press (or when already empty).

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

/// One available tool, as surfaced by the backend registry.
pub struct ToolEntry {
    pub name: String,
    pub description: String,
    /// Registering module/extension; `None` renders under the "core" group.
    pub module: Option<String>,
}

/// Bubble-up result of tools-browser key handling.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ToolsBrowserAction {
    /// The overlay should be dismissed.
    Close,
    /// Key consumed; keep the overlay open.
    None,
}

/// A single rendered line: a module group header, or a tool at `usize` position
/// in the currently-ordered (filtered) list.
enum RenderRow {
    Header(String),
    Tool(usize),
}

pub struct ToolsBrowser {
    tools: Vec<ToolEntry>,
    filter: String,
    /// Cursor index into the ordered/filtered tool list (never over headers).
    cursor: usize,
    /// Scroll offset in *render-row* space (headers included).
    scroll: usize,
    /// List height measured on the last draw, so `handle_key` scroll/page math
    /// matches the real dialog instead of the `DIALOG_H` upper bound.
    list_viewport: Cell<usize>,
}

impl ToolsBrowser {
    pub fn new(tools: Vec<ToolEntry>) -> Self {
        Self {
            tools,
            filter: String::new(),
            cursor: 0,
            scroll: 0,
            list_viewport: Cell::new((DIALOG_H as usize).saturating_sub(4)),
        }
    }

    /// Group label for a tool's module (`None` → "core").
    fn module_label(m: &Option<String>) -> &str {
        m.as_deref().unwrap_or("core")
    }

    fn matches(&self, t: &ToolEntry, needle: &str) -> bool {
        t.name.to_lowercase().contains(needle)
            || t.description.to_lowercase().contains(needle)
            || Self::module_label(&t.module).to_lowercase().contains(needle)
    }

    /// Tool indices in display order. Unfiltered: grouped by module in first-seen
    /// order. Filtered: original order, case-insensitive `contains` match.
    fn ordered(&self) -> Vec<usize> {
        if self.filter.is_empty() {
            let mut groups: Vec<&str> = Vec::new();
            for t in &self.tools {
                let g = Self::module_label(&t.module);
                if !groups.contains(&g) {
                    groups.push(g);
                }
            }
            let mut out = Vec::with_capacity(self.tools.len());
            for g in groups {
                for (i, t) in self.tools.iter().enumerate() {
                    if Self::module_label(&t.module) == g {
                        out.push(i);
                    }
                }
            }
            out
        } else {
            let needle = self.filter.to_lowercase();
            self.tools
                .iter()
                .enumerate()
                .filter(|(_, t)| self.matches(t, &needle))
                .map(|(i, _)| i)
                .collect()
        }
    }

    /// Build the flat renderable rows (headers interleaved when unfiltered).
    fn render_rows(&self, ordered: &[usize]) -> Vec<RenderRow> {
        let mut rows = Vec::with_capacity(ordered.len() + 8);
        if self.filter.is_empty() {
            let mut cur: Option<&str> = None;
            for (pos, &ti) in ordered.iter().enumerate() {
                let label = Self::module_label(&self.tools[ti].module);
                if cur != Some(label) {
                    rows.push(RenderRow::Header(label.to_string()));
                    cur = Some(label);
                }
                rows.push(RenderRow::Tool(pos));
            }
        } else {
            for pos in 0..ordered.len() {
                rows.push(RenderRow::Tool(pos));
            }
        }
        rows
    }

    /// Render-row index of the currently-selected tool (0 if none).
    fn selected_render_idx(rows: &[RenderRow], cursor: usize) -> usize {
        rows.iter()
            .position(|r| matches!(r, RenderRow::Tool(p) if *p == cursor))
            .unwrap_or(0)
    }

    /// Re-clamp the stored scroll so the cursor's row stays visible after a
    /// cursor/filter change (uses the last measured viewport height).
    fn adjust_scroll(&mut self) {
        let ordered = self.ordered();
        let rows = self.render_rows(&ordered);
        let sel = Self::selected_render_idx(&rows, self.cursor);
        let vp = self.list_viewport.get().max(1);
        self.scroll = crate::dialogs::clamp_scroll_to_cursor(self.scroll, sel, vp);
    }

    pub fn handle_key(&mut self, key: KeyEvent) -> ToolsBrowserAction {
        // Ignore chorded shortcuts — they belong to the app, not the filter box.
        if key.modifiers.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) {
            return ToolsBrowserAction::None;
        }
        let len = self.ordered().len();
        let last = len.saturating_sub(1);
        let page = self.list_viewport.get().max(1);
        match key.code {
            KeyCode::Esc => {
                if self.filter.is_empty() {
                    return ToolsBrowserAction::Close;
                }
                self.filter.clear();
                self.cursor = 0;
                self.scroll = 0;
            }
            KeyCode::Up => {
                self.cursor = self.cursor.saturating_sub(1);
                self.adjust_scroll();
            }
            KeyCode::Down => {
                self.cursor = (self.cursor + 1).min(last);
                self.adjust_scroll();
            }
            KeyCode::Char('k') if self.filter.is_empty() => {
                self.cursor = self.cursor.saturating_sub(1);
                self.adjust_scroll();
            }
            KeyCode::Char('j') if self.filter.is_empty() => {
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
            KeyCode::Backspace => {
                self.filter.pop();
                self.cursor = 0;
                self.scroll = 0;
            }
            KeyCode::Char(c) => {
                self.filter.push(c);
                self.cursor = 0;
                self.scroll = 0;
            }
            _ => {}
        }
        ToolsBrowserAction::None
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
                Span::styled("\u{00b7} tools ", Style::default().fg(c.muted)),
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
        let total = self.tools.len();
        let shown = ordered.len();

        // ── count summary ──────────────────────────────────────────────────
        let count = if self.filter.is_empty() {
            format!("{total} tools")
        } else {
            format!("{shown}/{total} tools")
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

        // ── search line ────────────────────────────────────────────────────
        let search = truncate_chars(&format!("search: {}\u{2588}", self.filter), maxw);
        let search_style = if self.filter.is_empty() {
            Style::default().fg(c.dim)
        } else {
            Style::default().fg(c.secondary)
        };
        put(
            frame,
            Paragraph::new(Line::from(Span::styled(search, search_style))),
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
        let list_h = inner.height.saturating_sub(4); // 3 header lines + 1 help.
        self.list_viewport.set((list_h as usize).max(1));

        if shown == 0 {
            let msg = if self.filter.is_empty() {
                "No tools available".to_string()
            } else {
                format!("No tools match \u{201c}{}\u{201d}", self.filter)
            };
            put(
                frame,
                Paragraph::new(Span::styled(
                    truncate_chars(&msg, maxw),
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
                    RenderRow::Header(label) => {
                        put(
                            frame,
                            Paragraph::new(Line::from(Span::styled(
                                truncate_chars(&format!("{label}"), maxw),
                                Style::default().fg(c.primary).add_modifier(Modifier::BOLD),
                            ))),
                            Rect::new(inner.x, ry, iw, 1),
                        );
                    }
                    RenderRow::Tool(pos) => {
                        let t = &self.tools[ordered[*pos]];
                        let selected = *pos == self.cursor;
                        if selected {
                            // Full-width highlight bar (name + inline description).
                            let raw = format!("  {}   {}", t.name, t.description);
                            let s = crate::util::pad_cols(&raw, maxw);
                            put(
                                frame,
                                Paragraph::new(Line::from(Span::styled(s, theme.button_active()))),
                                Rect::new(inner.x, ry, iw, 1),
                            );
                        } else {
                            let name = truncate_chars(&t.name, maxw.saturating_sub(4));
                            let used = 2 + crate::util::cols(&name);
                            let mut spans = vec![
                                Span::raw("  "),
                                Span::styled(
                                    name,
                                    Style::default()
                                        .fg(c.secondary)
                                        .add_modifier(Modifier::BOLD),
                                ),
                            ];
                            let remaining = maxw.saturating_sub(used);
                            if remaining > 5 && !t.description.is_empty() {
                                let desc = truncate_chars(&t.description, remaining - 3);
                                spans.push(Span::styled(
                                    format!("   {desc}"),
                                    Style::default().fg(c.dim),
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
                Span::styled("type", Style::default().fg(c.secondary).add_modifier(Modifier::BOLD)),
                Span::styled(" filter  ", Style::default().fg(c.dim)),
                Span::styled("\u{2191}\u{2193}", Style::default().fg(c.secondary).add_modifier(Modifier::BOLD)),
                Span::styled(" nav  ", Style::default().fg(c.dim)),
                Span::styled("esc", Style::default().fg(c.secondary).add_modifier(Modifier::BOLD)),
                Span::styled(
                    if self.filter.is_empty() { " close" } else { " clear" },
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
mod tools_browser_tests {
    use super::*;
    use crossterm::event::KeyModifiers;
    use ratatui::{backend::TestBackend, Terminal};

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::empty())
    }

    fn sample() -> Vec<ToolEntry> {
        vec![
            ToolEntry { name: "read_file".into(), description: "Read a file from disk".into(), module: None },
            ToolEntry { name: "write_file".into(), description: "Write a file to disk".into(), module: None },
            ToolEntry { name: "web_search".into(), description: "Search the web".into(), module: Some("web".into()) },
            ToolEntry { name: "web_fetch".into(), description: "Fetch a URL".into(), module: Some("web".into()) },
            ToolEntry { name: "\u{4e2d}\u{6587}\u{5de5}\u{5177}".into(), description: "\u{20ac}".repeat(80), module: Some("\u{4e2d}".into()) },
        ]
    }

    #[test]
    fn filter_narrows_case_insensitively() {
        let mut b = ToolsBrowser::new(sample());
        assert_eq!(b.ordered().len(), 5);
        for ch in "WEB".chars() {
            b.handle_key(key(KeyCode::Char(ch)));
        }
        // "web" matches the two web tools by name (case-insensitive).
        assert_eq!(b.ordered().len(), 2);
        // Backspace widens the match set again.
        b.handle_key(key(KeyCode::Backspace));
        assert!(b.ordered().len() >= 2);
    }

    #[test]
    fn esc_clears_filter_then_closes() {
        let mut b = ToolsBrowser::new(sample());
        b.handle_key(key(KeyCode::Char('r')));
        assert!(!b.filter.is_empty());
        // First Esc clears the filter but keeps the overlay open.
        assert_eq!(b.handle_key(key(KeyCode::Esc)), ToolsBrowserAction::None);
        assert!(b.filter.is_empty());
        // Second Esc (empty filter) closes.
        assert_eq!(b.handle_key(key(KeyCode::Esc)), ToolsBrowserAction::Close);
    }

    #[test]
    fn cursor_moves_over_filtered_list_and_clamps() {
        let mut b = ToolsBrowser::new(sample());
        // j/k navigate only when the filter is empty.
        for _ in 0..20 {
            b.handle_key(key(KeyCode::Char('j')));
        }
        assert_eq!(b.cursor, b.ordered().len() - 1);
        b.handle_key(key(KeyCode::Home));
        assert_eq!(b.cursor, 0);
    }

    #[test]
    fn empty_registry_is_safe() {
        let mut b = ToolsBrowser::new(Vec::new());
        assert_eq!(b.ordered().len(), 0);
        // Movement on an empty list must not panic or wander.
        b.handle_key(key(KeyCode::Down));
        assert_eq!(b.cursor, 0);
        assert_eq!(b.handle_key(key(KeyCode::Esc)), ToolsBrowserAction::Close);
    }

    #[test]
    fn draws_at_all_sizes_without_panic() {
        let states: Vec<(Vec<ToolEntry>, &str)> = vec![
            (Vec::new(), ""),
            (sample(), ""),
            (sample(), "web"),
            (sample(), "zzz"),
        ];
        for (tools, filter) in states {
            let mut b = ToolsBrowser::new(tools);
            for ch in filter.chars() {
                b.handle_key(key(KeyCode::Char(ch)));
            }
            for (w, h) in [(1u16, 1u16), (10, 4), (40, 12), (70, 20), (200, 60)] {
                let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
                term.draw(|f| b.draw(f, f.area())).unwrap();
            }
        }
    }
}
