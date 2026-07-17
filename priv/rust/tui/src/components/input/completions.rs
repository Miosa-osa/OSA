// Phase 2+: completions category field — used when completions are grouped by type
#![allow(dead_code)]

use crossterm::event::{KeyCode, KeyEvent};
use ratatui::prelude::*;
use ratatui::widgets::{Block, BorderType, Borders, Clear, Paragraph};

pub struct Completions {
    items: Vec<CompletionItem>,
    filtered: Vec<usize>,
    selected: usize,
    visible: bool,
    filter: String,
    max_visible: usize,
    scroll_offset: usize,
}

pub struct CompletionItem {
    pub name: String,
    pub description: String,
    pub category: Option<String>,
}

pub enum CompletionAction {
    Select(String),
    Dismiss,
}

impl Completions {
    pub fn new() -> Self {
        Self {
            items: Vec::new(),
            filtered: Vec::new(),
            selected: 0,
            visible: false,
            filter: String::new(),
            max_visible: 8,
            scroll_offset: 0,
        }
    }

    pub fn set_items(&mut self, items: Vec<CompletionItem>) {
        self.items = items;
        self.apply_filter();
    }

    pub fn show(&mut self, filter: &str) {
        self.filter = filter.to_string();
        self.apply_filter();
        if !self.filtered.is_empty() {
            self.visible = true;
            self.selected = 0;
            self.scroll_offset = 0;
        }
    }

    pub fn hide(&mut self) {
        self.visible = false;
    }

    pub fn is_visible(&self) -> bool {
        self.visible
    }

    pub fn update_filter(&mut self, filter: &str) {
        self.filter = filter.to_string();
        self.apply_filter();
        if self.filtered.is_empty() {
            self.visible = false;
        } else {
            if self.selected >= self.filtered.len() {
                self.selected = self.filtered.len().saturating_sub(1);
            }
            self.clamp_scroll();
        }
    }

    pub fn selected_name(&self) -> Option<&str> {
        self.filtered
            .get(self.selected)
            .and_then(|&idx| self.items.get(idx))
            .map(|item| item.name.as_str())
    }

    pub fn handle_key(&mut self, key: KeyEvent) -> Option<CompletionAction> {
        if !self.visible {
            return None;
        }
        match key.code {
            KeyCode::Up => {
                let len = self.filtered.len();
                if len == 0 {
                    return None;
                }
                self.selected = if self.selected == 0 {
                    len - 1
                } else {
                    self.selected - 1
                };
                self.clamp_scroll();
                None
            }
            KeyCode::Down => {
                let len = self.filtered.len();
                if len == 0 {
                    return None;
                }
                self.selected = (self.selected + 1) % len;
                self.clamp_scroll();
                None
            }
            KeyCode::Tab | KeyCode::Enter => {
                let name = self.selected_name().map(|s| s.to_string());
                if let Some(n) = name {
                    self.visible = false;
                    Some(CompletionAction::Select(n))
                } else {
                    None
                }
            }
            KeyCode::Esc => {
                self.visible = false;
                Some(CompletionAction::Dismiss)
            }
            _ => None,
        }
    }

    pub fn draw(&self, frame: &mut Frame, area: Rect) {
        if !self.visible || self.filtered.is_empty() {
            return;
        }

        let theme = crate::style::theme();

        // The popup is bottom-anchored above the input and grows upward. It MUST
        // stay inside the frame's real drawable area: the inline viewport's frame
        // buffer starts at `bounds.y` (e.g. y=13 when parked partway down the
        // terminal), so a naive `area.y - popup_height` lands ABOVE the buffer
        // top and a popup taller than the viewport spills BELOW its bottom —
        // either writes outside the buffer and panics ratatui. We therefore fit
        // the popup to the space available *above the input, within the frame*,
        // and clip every widget to `bounds` before rendering.
        let bounds = frame.area();
        if bounds.width == 0 || bounds.height == 0 {
            return;
        }

        // Compute desired popup dimensions.
        let longest = self
            .filtered
            .iter()
            .filter_map(|&i| self.items.get(i))
            .map(|item| {
                // name + gaps + description + optional " custom" tag width
                let tag = item.category.as_deref().map_or(0, |c| c.len() + 3);
                item.name.len() + 2 + item.description.len() + 4 + tag
            })
            .max()
            .unwrap_or(20);
        let popup_width = (longest as u16)
            .max(20)
            .min(60)
            .min(area.width)
            .min(bounds.width);

        let visible_count = self.filtered.len().min(self.max_visible) as u16;
        let desired_height = visible_count + 2; // border top + bottom

        // Room available above the input line, bounded by the frame's top. The
        // popup can be at most this tall; if there isn't room for even a border
        // pair + one row, skip drawing rather than overflow.
        let room_above = area.y.saturating_sub(bounds.y);
        let popup_height = desired_height.min(room_above);
        if popup_height < 3 {
            return;
        }

        let popup_y = area.y.saturating_sub(popup_height).max(bounds.y);
        let popup_x = area.x.max(bounds.x).min(bounds.right().saturating_sub(1));

        let popup_rect = Rect {
            x: popup_x,
            y: popup_y,
            width: popup_width,
            height: popup_height,
        }
        .intersection(bounds);
        if popup_rect.width == 0 || popup_rect.height == 0 {
            return;
        }

        // Clear background + bordered container (both already inside `bounds`).
        frame.render_widget(Clear, popup_rect);
        let block = Block::default()
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(Style::default().fg(theme.colors.border));
        frame.render_widget(block, popup_rect);

        // Inner area (inside the border) — still clipped to `bounds`.
        let inner = Rect {
            x: popup_rect.x + 1,
            y: popup_rect.y + 1,
            width: popup_rect.width.saturating_sub(2),
            height: popup_rect.height.saturating_sub(2),
        }
        .intersection(bounds);
        if inner.width == 0 || inner.height == 0 {
            return;
        }

        // Only as many rows as physically fit inside the (possibly shrunken)
        // inner area — never index a row past the popup's clipped height.
        let rows_fit = inner.height.min(visible_count);
        let show_scroll_up = self.scroll_offset > 0;
        let show_scroll_down = self.scroll_offset + self.max_visible < self.filtered.len();

        for row in 0..rows_fit {
            let list_idx = self.scroll_offset + row as usize;
            let item_idx = match self.filtered.get(list_idx) {
                Some(&i) => i,
                None => break,
            };
            let item = match self.items.get(item_idx) {
                Some(i) => i,
                None => break,
            };

            let is_selected = list_idx == self.selected;
            let is_first = row == 0;
            let is_last = row == rows_fit - 1;

            let row_rect = Rect {
                x: inner.x,
                y: inner.y + row,
                width: inner.width,
                height: 1,
            }
            .intersection(bounds);
            if row_rect.width == 0 || row_rect.height == 0 {
                continue;
            }

            // Scroll indicator rows
            if is_first && show_scroll_up {
                frame.render_widget(
                    Paragraph::new("  \u{25b2}").style(theme.completion_normal()),
                    row_rect,
                );
                continue;
            }
            if is_last && show_scroll_down {
                frame.render_widget(
                    Paragraph::new("  \u{25bc}").style(theme.completion_normal()),
                    row_rect,
                );
                continue;
            }

            // Row background + content
            let (row_style, name_style, desc_style) = if is_selected {
                let sel = theme.completion_selected();
                (sel, sel.add_modifier(Modifier::BOLD), sel)
            } else {
                (
                    theme.completion_normal(),
                    theme.completion_match(),
                    theme.completion_normal(),
                )
            };

            // Fill background for the whole row
            frame.render_widget(Paragraph::new("").style(row_style), row_rect);

            let mut spans = vec![
                Span::raw("  "),
                Span::styled(item.name.clone(), name_style),
                Span::raw("  "),
                Span::styled(item.description.clone(), desc_style),
            ];

            // Tag user-defined "custom" commands (~/.osa/commands/*.md) so they
            // stand out from built-ins in the popup. Selected rows keep the
            // selection style for legibility; otherwise use the category accent.
            if item.category.as_deref() == Some("custom") {
                let tag_style = if is_selected {
                    row_style
                } else {
                    theme.completion_category()
                };
                spans.push(Span::raw(" "));
                spans.push(Span::styled("custom", tag_style));
            }

            let line = Line::from(spans);

            frame.render_widget(Paragraph::new(line).style(row_style), row_rect);
        }
    }

    // --- private ---

    fn apply_filter(&mut self) {
        // Fuzzy subsequence match + rank (best-first), scoring against the
        // command name with its leading '/' stripped so "cmp" matches "/compact".
        self.filtered = crate::util::fuzzy::rank(&self.items, &self.filter, |item| {
            item.name.strip_prefix('/').unwrap_or(&item.name)
        });
        self.selected = 0;
        self.scroll_offset = 0;
    }

    fn clamp_scroll(&mut self) {
        if self.selected >= self.scroll_offset + self.max_visible {
            self.scroll_offset = self.selected + 1 - self.max_visible;
        }
        if self.selected < self.scroll_offset {
            self.scroll_offset = self.selected;
        }
    }
}
