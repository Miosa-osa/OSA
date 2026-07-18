//! `/persona` — the personality-preset picker.
//!
//! A branded, scrollable overlay that answers "how should OSA talk right now?" —
//! every switchable personality preset the agent ships, each with its one-line
//! description, and the active one marked. Replaces the flat `/persona` text
//! list: type to fuzzily narrow, arrow through the matches, Enter to apply.
//!
//! Stateful: the app owns one [`PersonaPicker`] built from the live preset list
//! (`GET /api/v1/personas`). `handle_key` is type-to-filter first (any char
//! extends the query), so cursor movement uses the arrow keys — `j`/`k` only
//! move when the filter is empty, to stay out of the search box. Esc first
//! clears a non-empty filter and only closes on a second press. Enter returns
//! [`PersonaPickerAction::Apply`] with the selected preset's canonical name.

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
const DIALOG_H: u16 = 24;

/// One personality preset, as surfaced by the backend.
pub struct PersonaEntry {
    /// Canonical name (the value applied on Enter, e.g. `"architect"`).
    pub name: String,
    /// Human display label, e.g. `"Code Reviewer"`.
    pub display: String,
    /// One-line description of the preset's tone/behaviour.
    pub description: String,
    /// True for the currently-active preset (marked, and pre-selected).
    pub current: bool,
}

/// Bubble-up result of persona-picker key handling.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PersonaPickerAction {
    /// Apply the preset with this canonical name, then dismiss.
    Apply(String),
    /// The overlay should be dismissed without applying.
    Close,
    /// Key consumed; keep the overlay open.
    None,
}

pub struct PersonaPicker {
    personas: Vec<PersonaEntry>,
    filter: String,
    /// Cursor index into the ordered/filtered persona list.
    cursor: usize,
    /// Scroll offset in list-row space.
    scroll: usize,
    /// List height measured on the last draw, so `handle_key` scroll/page math
    /// matches the real dialog instead of the `DIALOG_H` upper bound.
    list_viewport: Cell<usize>,
}

impl PersonaPicker {
    pub fn new(personas: Vec<PersonaEntry>) -> Self {
        // Pre-select the active preset so it's under the cursor on open.
        let cursor = personas.iter().position(|p| p.current).unwrap_or(0);
        Self {
            personas,
            filter: String::new(),
            cursor,
            scroll: 0,
            list_viewport: Cell::new((DIALOG_H as usize).saturating_sub(4)),
        }
    }

    fn matches(&self, p: &PersonaEntry, needle: &str) -> bool {
        p.name.to_lowercase().contains(needle)
            || p.display.to_lowercase().contains(needle)
            || p.description.to_lowercase().contains(needle)
    }

    /// Persona indices in display order (original order; filtered by query).
    fn ordered(&self) -> Vec<usize> {
        if self.filter.is_empty() {
            (0..self.personas.len()).collect()
        } else {
            let needle = self.filter.to_lowercase();
            self.personas
                .iter()
                .enumerate()
                .filter(|(_, p)| self.matches(p, &needle))
                .map(|(i, _)| i)
                .collect()
        }
    }

    /// Re-clamp the stored scroll so the cursor row stays visible after a
    /// cursor/filter change (uses the last measured viewport height).
    fn adjust_scroll(&mut self) {
        let vp = self.list_viewport.get().max(1);
        self.scroll = crate::dialogs::clamp_scroll_to_cursor(self.scroll, self.cursor, vp);
    }

    pub fn handle_key(&mut self, key: KeyEvent) -> PersonaPickerAction {
        // Ignore chorded shortcuts — they belong to the app, not the filter box.
        if key.modifiers.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) {
            return PersonaPickerAction::None;
        }
        let ordered = self.ordered();
        let last = ordered.len().saturating_sub(1);
        let page = self.list_viewport.get().max(1);
        match key.code {
            KeyCode::Esc => {
                if self.filter.is_empty() {
                    return PersonaPickerAction::Close;
                }
                self.filter.clear();
                self.cursor = 0;
                self.scroll = 0;
            }
            KeyCode::Enter => {
                if let Some(&pi) = ordered.get(self.cursor) {
                    return PersonaPickerAction::Apply(self.personas[pi].name.clone());
                }
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
        PersonaPickerAction::None
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
                Span::styled("\u{00b7} persona ", Style::default().fg(c.muted)),
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
        let total = self.personas.len();
        let shown = ordered.len();

        // ── count summary ──────────────────────────────────────────────────
        let count = if self.filter.is_empty() {
            format!("{total} personas")
        } else {
            format!("{shown}/{total} personas")
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
            Paragraph::new(Span::styled("\u{2500}".repeat(maxw), Style::default().fg(c.dim))),
            Rect::new(inner.x, cy, iw, 1),
        );
        cy += 1;

        // ── scrollable list ────────────────────────────────────────────────
        let list_h = inner.height.saturating_sub(4); // count + search + sep + help.
        self.list_viewport.set((list_h as usize).max(1));

        if shown == 0 {
            let msg = if self.filter.is_empty() {
                "No personas available".to_string()
            } else {
                format!("No personas match \u{201c}{}\u{201d}", self.filter)
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
            let scroll =
                crate::dialogs::clamp_scroll_to_cursor(self.scroll, self.cursor, (list_h as usize).max(1));

            for rel in 0..(list_h as usize) {
                let abs = rel + scroll;
                if abs >= shown {
                    break;
                }
                let p = &self.personas[ordered[abs]];
                let selected = abs == self.cursor;
                let ry = cy + rel as u16;
                let marker = if p.current { "\u{25CF} " } else { "  " };

                if selected {
                    // Full-width highlight bar (marker + label + inline description).
                    let raw = format!("{marker}{}   {}", p.display, p.description);
                    let mut s = truncate_chars(&raw, maxw);
                    let pad = maxw.saturating_sub(s.chars().count());
                    s.push_str(&" ".repeat(pad));
                    put(
                        frame,
                        Paragraph::new(Line::from(Span::styled(s, theme.button_active()))),
                        Rect::new(inner.x, ry, iw, 1),
                    );
                } else {
                    let marker_style = if p.current {
                        Style::default().fg(c.success)
                    } else {
                        Style::default().fg(c.dim)
                    };
                    let label = truncate_chars(&p.display, maxw.saturating_sub(2));
                    let used = 2 + label.chars().count();
                    let mut spans = vec![
                        Span::styled(marker, marker_style),
                        Span::styled(
                            label,
                            Style::default().fg(c.secondary).add_modifier(Modifier::BOLD),
                        ),
                    ];
                    let remaining = maxw.saturating_sub(used);
                    if remaining > 5 && !p.description.is_empty() {
                        let desc = truncate_chars(&p.description, remaining - 3);
                        spans.push(Span::styled(format!("   {desc}"), Style::default().fg(c.dim)));
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
                Span::styled("type", Style::default().fg(c.secondary).add_modifier(Modifier::BOLD)),
                Span::styled(" filter  ", Style::default().fg(c.dim)),
                Span::styled("\u{2191}\u{2193}", Style::default().fg(c.secondary).add_modifier(Modifier::BOLD)),
                Span::styled(" nav  ", Style::default().fg(c.dim)),
                Span::styled("\u{21b5}", Style::default().fg(c.secondary).add_modifier(Modifier::BOLD)),
                Span::styled(" apply  ", Style::default().fg(c.dim)),
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

/// Char-boundary-safe truncation (multi-byte labels can never panic).
fn truncate_chars(s: &str, max: usize) -> String {
    if s.chars().count() > max {
        let take = max.saturating_sub(1);
        format!("{}\u{2026}", s.chars().take(take).collect::<String>())
    } else {
        s.to_string()
    }
}

// (full #[cfg(test)] module included in the written file: preselects_current_persona,
// filter_narrows_case_insensitively, enter_applies_selected_name,
// esc_clears_filter_then_closes, cursor_clamps_over_filtered_list, empty_list_is_safe,
// draws_at_all_sizes_without_panic over [(1,1),(10,4),(40,12),(70,20),(200,60)])