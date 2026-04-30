// Phase 2+: generic picker dialog — not yet wired to a caller
#![allow(dead_code)]

use std::cell::Cell;

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::{
    prelude::*,
    widgets::{Block, BorderType, Borders, Clear, Paragraph},
};

use super::DialogAction;

const MAX_W: u16 = 80;
const MIN_W: u16 = 40;

/// A single entry in a `Picker`.
#[derive(Debug, Clone)]
pub struct PickerItem {
    /// Primary display label (also used in `PickerSelect`).
    pub label: String,
    /// Secondary detail string shown to the right of the label.
    pub detail: String,
    /// Optional short badge displayed on the right edge (e.g. "active", "7B").
    pub badge: Option<String>,
    /// When `true` the item is marked with `●` instead of `○`.
    pub active: bool,
}

/// Generic scrollable list picker — reusable for model selection, sessions, etc.
///
/// Layout:
/// ```text
/// ╭── <title> ──────────────────────────────────────╮
/// │ > filter                                        │
/// │─────────────────────────────────────────────────│
/// │ ● label          detail                  [badge]│
/// │ ○ label          detail                        │
/// │ ...                                             │
/// ╰─────────────────────────────────────────────────╯
/// ```
pub struct Picker {
    title: String,
    items: Vec<PickerItem>,
    /// Indices into `items` matching the current filter.
    filtered: Vec<usize>,
    filter: String,
    /// Index within `filtered`.
    selected: usize,
    /// First visible item index within `filtered`.
    scroll_offset: usize,
    /// How many list rows fit in the visible area — updated on each draw call
    /// via `Cell` so it is readable from `handle_key` without a mutable draw.
    visible_count: Cell<usize>,
}

impl Picker {
    pub fn new(title: &str) -> Self {
        Self {
            title: title.to_owned(),
            items: Vec::new(),
            filtered: Vec::new(),
            filter: String::new(),
            selected: 0,
            scroll_offset: 0,
            visible_count: Cell::new(10),
        }
    }

    /// Replace all items and reset filter / selection state.
    pub fn set_items(&mut self, items: Vec<PickerItem>) {
        self.items = items;
        self.filter.clear();
        self.selected = 0;
        self.scroll_offset = 0;
        self.refilter();
        // Pre-select the first active item if any.
        if let Some(pos) = self.filtered.iter().position(|&i| self.items[i].active) {
            self.selected = pos;
            self.clamp_scroll();
        }
    }

    /// Handle a key event.  Returns `Some(action)` when the picker should close.
    pub fn handle_key(&mut self, key: KeyEvent) -> Option<DialogAction> {
        if key
            .modifiers
            .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT)
        {
            return None;
        }

        match key.code {
            KeyCode::Esc => Some(DialogAction::PickerCancel),

            KeyCode::Enter => {
                if let Some(&item_idx) = self.filtered.get(self.selected) {
                    let label = self.items[item_idx].label.clone();
                    Some(DialogAction::PickerSelect {
                        index: item_idx,
                        label,
                    })
                } else {
                    Some(DialogAction::PickerCancel)
                }
            }

            KeyCode::Up => {
                if !self.filtered.is_empty() {
                    self.selected = self
                        .selected
                        .checked_sub(1)
                        .unwrap_or(self.filtered.len() - 1);
                    self.clamp_scroll();
                }
                None
            }

            KeyCode::Down => {
                if !self.filtered.is_empty() {
                    self.selected = (self.selected + 1) % self.filtered.len();
                    self.clamp_scroll();
                }
                None
            }

            KeyCode::Backspace => {
                self.filter.pop();
                self.refilter();
                None
            }

            KeyCode::Char(c) => {
                self.filter.push(c);
                self.refilter();
                None
            }

            _ => None,
        }
    }

    /// Draw the centered picker modal over `area`.
    pub fn draw(&self, frame: &mut Frame, area: Rect) {
        let theme = crate::style::theme();

        // Width: clamped to [MIN_W, MAX_W] but never larger than area.
        let w = MAX_W.min(area.width).max(MIN_W.min(area.width));
        // Height: 4 chrome lines (border×2 + filter + separator) + items.
        let item_count = self.filtered.len().min(self.visible_count.get()) as u16;
        let h = (4 + item_count + 1).min(area.height);

        let x = area.x + area.width.saturating_sub(w) / 2;
        let y = area.y + area.height.saturating_sub(h) / 3;

        let picker_rect = Rect::new(x, y, w, h);
        frame.render_widget(Clear, picker_rect);

        let block = Block::default()
            .title(Span::styled(
                format!(" {} ", self.title),
                theme.modal_title(),
            ))
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(Style::default().fg(theme.colors.primary))
            .style(Style::default().bg(theme.colors.modal_bg));
        frame.render_widget(block, picker_rect);

        let inner = Rect::new(
            picker_rect.x + 1,
            picker_rect.y + 1,
            picker_rect.width.saturating_sub(2),
            picker_rect.height.saturating_sub(2),
        );

        if inner.height == 0 {
            return;
        }

        // Filter input line: "> <filter>"
        let filter_line = Line::from(vec![
            Span::styled("> ", theme.prompt_char()),
            Span::styled(
                self.filter.clone(),
                Style::default().fg(theme.colors.secondary),
            ),
        ]);
        frame.render_widget(
            Paragraph::new(filter_line),
            Rect::new(inner.x, inner.y, inner.width, 1),
        );

        if inner.height < 2 {
            return;
        }

        // Separator.
        let sep_y = inner.y + 1;
        let sep = "─".repeat(inner.width as usize);
        frame.render_widget(
            Paragraph::new(Span::styled(sep, Style::default().fg(theme.colors.border))),
            Rect::new(inner.x, sep_y, inner.width, 1),
        );

        // List items start two rows below the top of inner.
        let list_y = inner.y + 2;
        let list_height = inner.height.saturating_sub(2) as usize;

        // Record the measured viewport height for use in clamp_scroll.
        self.visible_count.set(list_height.max(1));

        for (row, &item_idx) in self
            .filtered
            .iter()
            .enumerate()
            .skip(self.scroll_offset)
            .take(list_height)
        {
            let item = &self.items[item_idx];
            let is_selected = row == self.selected;
            let row_y = list_y + (row - self.scroll_offset) as u16;

            if row_y >= inner.y + inner.height {
                break;
            }

            // Activity glyph.
            let glyph = if item.active { "● " } else { "○ " };
            let glyph_style = if item.active {
                Style::default().fg(theme.colors.primary)
            } else {
                Style::default().fg(theme.colors.muted)
            };

            // Row highlight background when selected.
            let row_bg = if is_selected {
                Style::default().bg(theme.colors.dim)
            } else {
                Style::default()
            };

            let label_style = if is_selected {
                Style::default()
                    .fg(theme.colors.primary)
                    .add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(theme.colors.muted)
            };

            let detail_style = Style::default().fg(theme.colors.dim);
            let badge_style = Style::default()
                .fg(theme.colors.secondary)
                .add_modifier(Modifier::BOLD);

            // Compute column widths.
            let avail = inner.width as usize;
            let badge_text = item
                .badge
                .as_ref()
                .map(|b| format!("[{}]", b))
                .unwrap_or_default();
            let badge_len = badge_text.len();
            let glyph_len = 2usize;
            let label_max = (avail / 2).max(8);
            let detail_max = avail
                .saturating_sub(glyph_len + label_max + badge_len + 2)
                .max(0);

            let label = truncate(&item.label, label_max);
            let detail = truncate(&item.detail, detail_max);

            let label_padded = format!("{:<width$}", label, width = label_max);
            let detail_padded = if detail.is_empty() {
                " ".repeat(detail_max)
            } else {
                format!(" {:<width$}", detail, width = detail_max.saturating_sub(1))
            };

            let mut spans = vec![
                Span::styled(glyph, glyph_style.patch(row_bg)),
                Span::styled(label_padded, label_style.patch(row_bg)),
                Span::styled(detail_padded, detail_style.patch(row_bg)),
            ];

            if !badge_text.is_empty() {
                spans.push(Span::styled(badge_text, badge_style.patch(row_bg)));
            }

            frame.render_widget(
                Paragraph::new(Line::from(spans)).style(row_bg),
                Rect::new(inner.x, row_y, inner.width, 1),
            );
        }
    }

    // ── Private helpers ──────────────────────────────────────────────────────

    fn refilter(&mut self) {
        let query = self.filter.to_lowercase();
        if query.is_empty() {
            self.filtered = (0..self.items.len()).collect();
        } else {
            self.filtered = self
                .items
                .iter()
                .enumerate()
                .filter(|(_, item)| {
                    item.label.to_lowercase().contains(&query)
                        || item.detail.to_lowercase().contains(&query)
                })
                .map(|(i, _)| i)
                .collect();
        }
        // Keep selected in bounds.
        if self.filtered.is_empty() {
            self.selected = 0;
            self.scroll_offset = 0;
        } else {
            self.selected = self.selected.min(self.filtered.len() - 1);
            self.clamp_scroll();
        }
    }

    /// Ensure `scroll_offset` keeps `selected` in the visible window.
    fn clamp_scroll(&mut self) {
        let vc = self.visible_count.get().max(1);
        if self.selected < self.scroll_offset {
            self.scroll_offset = self.selected;
        } else if self.selected >= self.scroll_offset + vc {
            self.scroll_offset = self.selected - vc + 1;
        }
    }
}

impl Default for Picker {
    fn default() -> Self {
        Self::new("Pick")
    }
}

/// Truncate a string to at most `max` chars, appending "…" if needed.
fn truncate(s: &str, max: usize) -> String {
    if max == 0 {
        return String::new();
    }
    let chars: Vec<char> = s.chars().collect();
    if chars.len() <= max {
        s.to_owned()
    } else {
        let cut = max.saturating_sub(1);
        let t: String = chars[..cut].iter().collect();
        format!("{}…", t)
    }
}
