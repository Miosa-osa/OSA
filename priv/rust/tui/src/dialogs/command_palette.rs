// Phase 2+: command palette is_open() method — wired when palette auto-close is added
#![allow(dead_code)]

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::{
    prelude::*,
    widgets::{Block, BorderType, Borders, Clear, Paragraph},
};

use super::DialogAction;

/// Maximum number of visible items in the filtered list.
const MAX_VISIBLE: usize = 12;
/// Minimum palette width.
const MIN_WIDTH: u16 = 50;

/// A single entry exposed by the command palette.
#[derive(Debug, Clone)]
pub struct PaletteItem {
    pub name: String,
    pub description: String,
    pub category: String,
}

/// Ctrl+K fuzzy command palette.
///
/// Layout:
/// ```text
/// ╭── Command Palette ─────────────────────╮
/// │ > filter text                          │
/// │────────────────────────────────────────│
/// │ ▸ Name          description  [cat]     │
/// │   Name          description  [cat]     │
/// │   ...                                  │
/// ╰────────────────────────────────────────╯
/// ```
pub struct CommandPalette {
    filter: String,
    items: Vec<PaletteItem>,
    /// Indices into `items` that pass the current filter.
    filtered: Vec<usize>,
    /// Index within `filtered` that is currently highlighted.
    selected: usize,
    visible: bool,
}

impl CommandPalette {
    pub fn new() -> Self {
        Self {
            filter: String::new(),
            items: Vec::new(),
            filtered: Vec::new(),
            selected: 0,
            visible: false,
        }
    }

    /// Open (or re-open) the palette with a fresh command list.
    pub fn open(&mut self, commands: Vec<PaletteItem>) {
        self.items = commands;
        self.filter.clear();
        self.selected = 0;
        self.visible = true;
        self.refilter();
    }

    /// Close and reset the palette.
    pub fn close(&mut self) {
        self.visible = false;
        self.filter.clear();
        self.selected = 0;
        self.filtered.clear();
    }

    pub fn is_open(&self) -> bool {
        self.visible
    }

    /// Handle a key event while the palette is open.
    /// Returns `Some(action)` when the palette should close.
    pub fn handle_key(&mut self, key: KeyEvent) -> Option<DialogAction> {
        if key.modifiers.contains(KeyModifiers::CONTROL) {
            // Ctrl+K closes the palette.
            if key.code == KeyCode::Char('k') {
                self.close();
                return Some(DialogAction::Dismissed);
            }
            return None;
        }

        match key.code {
            KeyCode::Esc => {
                self.close();
                Some(DialogAction::Dismissed)
            }
            KeyCode::Enter => {
                if let Some(&item_idx) = self.filtered.get(self.selected) {
                    let name = self.items[item_idx].name.clone();
                    self.close();
                    Some(DialogAction::PaletteExecute(name))
                } else {
                    self.close();
                    Some(DialogAction::Dismissed)
                }
            }
            KeyCode::Up => {
                if !self.filtered.is_empty() {
                    self.selected = self.selected.checked_sub(1).unwrap_or(self.filtered.len() - 1);
                }
                None
            }
            KeyCode::Down => {
                if !self.filtered.is_empty() {
                    self.selected = (self.selected + 1) % self.filtered.len();
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

    /// Draw the palette centered over `area`.
    pub fn draw(&self, frame: &mut Frame, area: Rect) {
        if !self.visible {
            return;
        }

        let theme = crate::style::theme();

        // Width: half the terminal, clamped to [MIN_WIDTH, area.width - 4].
        let w = (area.width / 2).max(MIN_WIDTH).min(area.width.saturating_sub(4));
        // Height: 3 (border + filter + separator) + visible items (≥1 row so
        // the empty state fits) + help row + bottom border.
        let item_count = (self.filtered.len().min(MAX_VISIBLE) as u16).max(1);
        let h = (3 + item_count + 2).min(area.height.saturating_sub(4));

        let x = area.x + area.width.saturating_sub(w) / 2;
        let y = area.y + area.height.saturating_sub(h) / 4; // Upper-center feels natural for palettes.

        let palette_rect = Rect::new(x, y, w, h);
        frame.render_widget(Clear, palette_rect);

        // Outer block.
        let block = Block::default()
            .title(Span::styled(" Command Palette ", theme.modal_title()))
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(Style::default().fg(theme.colors.primary))
            .style(Style::default().bg(theme.colors.modal_bg));
        frame.render_widget(block, palette_rect);

        let inner = Rect::new(
            palette_rect.x + 1,
            palette_rect.y + 1,
            palette_rect.width.saturating_sub(2),
            palette_rect.height.saturating_sub(2),
        );

        if inner.height == 0 {
            return;
        }

        // Filter input line: "> <filter>"
        let filter_line = Line::from(vec![
            Span::styled("> ", theme.prompt_char()),
            Span::styled(self.filter.clone(), Style::default().fg(theme.colors.secondary)),
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

        // Item list starts at inner.y + 2; the last inner row is the help bar.
        let list_y = inner.y + 2;
        let list_height = inner.height.saturating_sub(3);

        // Scroll window so the selected item is always visible. Base it on the
        // ACTUAL visible row count (`list_height`), NOT the fixed MAX_VISIBLE
        // cap: on a short terminal fewer than MAX_VISIBLE rows fit, and keying
        // past them must still scroll — otherwise the highlighted row renders
        // below `inner.y + inner.height`, gets clipped by the `break` below, and
        // the user loses sight of their selection while navigating.
        let visible_rows = (list_height as usize).max(1);
        let scroll_start = self.selected.saturating_sub(visible_rows.saturating_sub(1));

        for (row, &item_idx) in self
            .filtered
            .iter()
            .enumerate()
            .skip(scroll_start)
            .take(list_height as usize)
        {
            let item = &self.items[item_idx];
            let is_selected = row == self.selected;
            let row_y = list_y + (row - scroll_start) as u16;

            if row_y >= inner.y + inner.height.saturating_sub(1) {
                break;
            }

            // Prefix glyph.
            let prefix = if is_selected { "▸ " } else { "  " };
            let prefix_style = if is_selected {
                Style::default().fg(theme.colors.primary)
            } else {
                Style::default()
            };

            // Name column: bold when selected.
            let name_style = if is_selected {
                theme.bold()
            } else {
                Style::default().fg(theme.colors.muted)
            };

            // Build the row line.
            let avail = inner.width.saturating_sub(2) as usize; // minus prefix
            let cat_text = format!("[{}]", item.category);
            let cat_len = cat_text.len();
            // Name takes up to 1/3, description fills the middle, category right-aligns.
            let name_max = (avail / 3).max(8);
            let cat_start = avail.saturating_sub(cat_len);
            let desc_max = cat_start.saturating_sub(name_max + 2);

            let name = truncate(&item.name, name_max);
            let desc = truncate(&item.description, desc_max);

            // Pad name to align description column.
            let name_padded = format!("{:<width$}", name, width = name_max);
            let desc_padded = format!("  {:<width$}", desc, width = desc_max);
            let cat_padded = format!("{:>width$}", cat_text, width = cat_len);

            let line = Line::from(vec![
                Span::styled(prefix, prefix_style),
                Span::styled(name_padded, name_style),
                Span::styled(desc_padded, Style::default().fg(theme.colors.muted)),
                Span::styled(cat_padded, Style::default().fg(theme.colors.dim)),
            ]);

            frame.render_widget(
                Paragraph::new(line),
                Rect::new(inner.x, row_y, inner.width, 1),
            );
        }

        // Empty state (CC parity: never a silent blank list).
        if self.filtered.is_empty() && list_height > 0 {
            frame.render_widget(
                Paragraph::new(Span::styled(
                    "  No matching commands",
                    Style::default().fg(theme.colors.dim),
                )),
                Rect::new(inner.x, list_y, inner.width, 1),
            );
        }

        // Bottom keyboard hints (consistent with every other dialog).
        let hint_y = inner.y + inner.height.saturating_sub(1);
        if hint_y > sep_y {
            let help = Line::from(vec![
                Span::styled("↑↓", theme.dialog_help_key()),
                Span::styled(" nav  ", theme.dialog_help()),
                Span::styled("Enter", theme.dialog_help_key()),
                Span::styled(" run  ", theme.dialog_help()),
                Span::styled("Esc", theme.dialog_help_key()),
                Span::styled(" close", theme.dialog_help()),
            ]);
            frame.render_widget(
                Paragraph::new(help).alignment(Alignment::Center),
                Rect::new(inner.x, hint_y, inner.width, 1),
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
                    item.name.to_lowercase().contains(&query)
                        || item.description.to_lowercase().contains(&query)
                        || item.category.to_lowercase().contains(&query)
                })
                .map(|(i, _)| i)
                .collect();
        }
        // Keep selected in bounds.
        if self.filtered.is_empty() {
            self.selected = 0;
        } else {
            self.selected = self.selected.min(self.filtered.len() - 1);
        }
    }
}

impl Default for CommandPalette {
    fn default() -> Self {
        Self::new()
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
        let truncated: String = chars[..cut].iter().collect();
        format!("{}…", truncated)
    }
}
