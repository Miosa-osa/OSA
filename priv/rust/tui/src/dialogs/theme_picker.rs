//! `/theme` — the theme picker overlay.
//!
//! A branded, stateful overlay that lets the operator browse OSA's registered
//! color themes and switch the live UI palette. Each row is a theme name; the
//! currently-active theme is marked with a `●`, and the highlighted row shows a
//! live PREVIEW SWATCH built from *that theme's own* colors (primary, secondary,
//! success, warning, error) — pulled fresh via [`crate::style::themes::by_name`]
//! — so the operator sees the palette before committing to it.
//!
//! Stateful: the app owns one [`ThemePicker`]; [`ThemePicker::handle_key`] moves
//! the cursor (Up/Down/j/k) and returns a [`ThemeAction`] on Enter (apply the
//! selected theme) or Esc (close). The app layer applies the action by calling
//! `crate::style::set_theme(...)` with the resolved theme and persisting the
//! choice. Themes whose lookup fails (`by_name` → `None`) degrade gracefully:
//! the swatch is simply omitted rather than panicking.

use crossterm::event::{KeyCode, KeyEvent};
use ratatui::{
    prelude::*,
    widgets::{Block, BorderType, Borders, Clear, Paragraph},
};

/// Clip-safe render (shared choke point with the other dialogs).
fn put<W: ratatui::widgets::Widget>(frame: &mut Frame, widget: W, rect: Rect) {
    crate::app::event_loop::safe_render_widget(frame, widget, rect);
}

const DIALOG_W: u16 = 52;
/// Hard ceiling on visible theme rows before we stop drawing (dialogs stay
/// compact; the registered theme set is small, but guard against growth).
const MAX_ROWS: usize = 12;

/// Bubble-up result of theme-picker key handling.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ThemeAction {
    /// Apply the named theme (app layer resolves + `set_theme` + persists).
    Apply(String),
    /// Dismiss without changing the theme.
    Close,
}

pub struct ThemePicker {
    /// Registered theme names, in registry order.
    names: Vec<String>,
    /// Highlighted row.
    cursor: usize,
    /// Name of the theme active when the picker opened (marked with `●`).
    current: String,
}

impl ThemePicker {
    /// Build from the live theme registry, focusing the currently-active theme
    /// if it is present in the list (otherwise row 0).
    pub fn new(current_theme: String) -> Self {
        let names: Vec<String> = crate::style::themes::available()
            .into_iter()
            .map(str::to_string)
            .collect();
        let cursor = names.iter().position(|n| *n == current_theme).unwrap_or(0);
        Self { names, cursor, current: current_theme }
    }

    /// Name under the cursor, if any theme is registered.
    fn selected(&self) -> Option<&str> {
        self.names.get(self.cursor).map(String::as_str)
    }

    pub fn handle_key(&mut self, key: KeyEvent) -> Option<ThemeAction> {
        if self.names.is_empty() {
            // Nothing to pick — any dismiss key closes.
            return match key.code {
                KeyCode::Esc | KeyCode::Enter => Some(ThemeAction::Close),
                _ => None,
            };
        }
        let last = self.names.len().saturating_sub(1);
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => {
                self.cursor = self.cursor.saturating_sub(1);
                None
            }
            KeyCode::Down | KeyCode::Char('j') => {
                self.cursor = (self.cursor + 1).min(last);
                None
            }
            KeyCode::Enter => self.selected().map(|n| ThemeAction::Apply(n.to_string())),
            KeyCode::Esc => Some(ThemeAction::Close),
            _ => None,
        }
    }

    pub fn draw(&self, frame: &mut Frame, area: Rect) {
        let theme = crate::style::theme();
        let c = &theme.colors;

        let rows = self.names.len().min(MAX_ROWS);
        // title-gap handled by border. rows + gap(1) + swatch label(1) +
        // swatch(1) + gap(1) + footer(1) = rows + 5 content lines.
        let content_h = rows + 5;
        let w = DIALOG_W.min(area.width);
        let h = (content_h as u16 + 2).min(area.height);
        let x = area.x + area.width.saturating_sub(w) / 2;
        let y = area.y + area.height.saturating_sub(h) / 2;
        let rect = Rect::new(x, y, w, h);

        put(frame, Clear, rect);
        let block = Block::default()
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(Style::default().fg(c.primary))
            .title(Line::from(vec![
                Span::styled(
                    " OSA ",
                    Style::default().fg(c.primary).add_modifier(Modifier::BOLD),
                ),
                Span::styled("\u{00b7} theme ", Style::default().fg(c.muted)),
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
            return; // too small to render meaningfully; border already drawn.
        }
        let iw = inner.width;
        let max_w = iw as usize;
        let mut cy = inner.y;

        // ── Theme rows ─────────────────────────────────────────────────────
        // Scroll so the cursor stays visible even if the registry grows past
        // the visible row budget.
        let visible = (inner.height as usize).saturating_sub(4).clamp(1, MAX_ROWS);
        let scroll = if self.cursor >= visible {
            self.cursor - visible + 1
        } else {
            0
        };
        let mut drawn = 0usize;
        for (i, name) in self.names.iter().enumerate().skip(scroll) {
            if drawn >= visible || cy >= inner.y + inner.height.saturating_sub(3) {
                break;
            }
            let is_cursor = i == self.cursor;
            let is_active = *name == self.current;
            let marker = if is_active { "\u{25CF} " } else { "  " };
            let cursor_char = if is_cursor { "\u{25B8} " } else { "  " };
            let name_style = if is_cursor {
                Style::default().fg(c.primary).add_modifier(Modifier::BOLD)
            } else if is_active {
                Style::default().fg(c.secondary)
            } else {
                Style::default().fg(c.muted)
            };
            let mut spans = vec![
                Span::styled(cursor_char, Style::default().fg(c.primary)),
                Span::styled(marker, Style::default().fg(c.success)),
                Span::styled(truncate_chars(name, max_w.saturating_sub(6)), name_style),
            ];
            if is_active {
                spans.push(Span::styled("  (active)", Style::default().fg(c.dim)));
            }
            put(
                frame,
                Paragraph::new(Line::from(spans)),
                Rect::new(inner.x, cy, iw, 1),
            );
            cy += 1;
            drawn += 1;
        }
        cy += 1;

        // ── Live preview swatch for the SELECTED theme ─────────────────────
        // Pull the selected theme's OWN palette (not the active one) so the
        // operator previews before applying. `by_name` → None degrades to a
        // muted note instead of a swatch.
        if cy + 1 < inner.y + inner.height {
            let sel = self.selected().unwrap_or("");
            put(
                frame,
                Paragraph::new(Line::from(Span::styled(
                    format!("preview: {}", truncate_chars(sel, max_w.saturating_sub(9))),
                    Style::default().fg(c.dim),
                ))),
                Rect::new(inner.x, cy, iw, 1),
            );
            cy += 1;

            match crate::style::themes::by_name(sel) {
                Some(preview) => {
                    let p = &preview.colors;
                    let block = "\u{2588}\u{2588}";
                    let swatch = [
                        (p.primary, "primary"),
                        (p.secondary, "secondary"),
                        (p.success, "success"),
                        (p.warning, "warning"),
                        (p.error, "error"),
                    ];
                    let mut spans: Vec<Span> = Vec::with_capacity(swatch.len() * 2);
                    for (color, _) in swatch {
                        spans.push(Span::styled(block, Style::default().fg(color)));
                        spans.push(Span::raw(" "));
                    }
                    put(
                        frame,
                        Paragraph::new(Line::from(spans)),
                        Rect::new(inner.x, cy, iw, 1),
                    );
                }
                None => {
                    put(
                        frame,
                        Paragraph::new(Line::from(Span::styled(
                            "  (palette unavailable)",
                            Style::default().fg(c.warning),
                        ))),
                        Rect::new(inner.x, cy, iw, 1),
                    );
                }
            }
            cy += 1;
        }

        // ── Footer hint ────────────────────────────────────────────────────
        cy += 1;
        if cy < inner.y + inner.height {
            put(
                frame,
                Paragraph::new(Line::from(vec![
                    Span::styled(
                        "\u{2191}/\u{2193}",
                        Style::default().fg(c.secondary).add_modifier(Modifier::BOLD),
                    ),
                    Span::styled(" move  ", Style::default().fg(c.dim)),
                    Span::styled(
                        "enter",
                        Style::default().fg(c.secondary).add_modifier(Modifier::BOLD),
                    ),
                    Span::styled(" apply  ", Style::default().fg(c.dim)),
                    Span::styled(
                        "esc",
                        Style::default().fg(c.secondary).add_modifier(Modifier::BOLD),
                    ),
                    Span::styled(" close", Style::default().fg(c.dim)),
                ])),
                Rect::new(inner.x, cy, iw, 1),
            );
        }
    }
}

/// Char-boundary-safe truncation (multi-byte theme names can never panic).
fn truncate_chars(s: &str, max: usize) -> String {
    if s.chars().count() > max {
        let take = max.saturating_sub(1);
        format!("{}\u{2026}", s.chars().take(take).collect::<String>())
    } else {
        s.to_string()
    }
}

#[cfg(test)]
mod theme_picker_tests {
    use super::*;
    use crossterm::event::{KeyEvent, KeyModifiers};
    use ratatui::{backend::TestBackend, Terminal};

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::empty())
    }

    #[test]
    fn new_focuses_current_theme() {
        let p = ThemePicker::new("catppuccin".to_string());
        assert_eq!(p.selected(), Some("catppuccin"));
        // Unknown current falls back to row 0.
        let p2 = ThemePicker::new("does-not-exist".to_string());
        assert_eq!(p2.cursor, 0);
    }

    #[test]
    fn navigation_clamps_and_enter_applies() {
        let mut p = ThemePicker::new("dark".to_string());
        // Up at the top is a no-op (saturating).
        assert_eq!(p.handle_key(key(KeyCode::Up)), None);
        assert_eq!(p.cursor, 0);
        // Down moves; j/k are aliases.
        assert_eq!(p.handle_key(key(KeyCode::Down)), None);
        assert_eq!(p.cursor, 1);
        assert_eq!(p.handle_key(key(KeyCode::Char('k'))), None);
        assert_eq!(p.cursor, 0);
        // Walk to the very bottom and confirm Down clamps.
        for _ in 0..50 {
            p.handle_key(key(KeyCode::Char('j')));
        }
        assert_eq!(p.cursor, p.names.len() - 1);
        // Enter applies the selected name; Esc closes.
        let name = p.names[p.cursor].clone();
        assert_eq!(p.handle_key(key(KeyCode::Enter)), Some(ThemeAction::Apply(name)));
        assert_eq!(p.handle_key(key(KeyCode::Esc)), Some(ThemeAction::Close));
    }

    #[test]
    fn draws_at_all_sizes_without_panic() {
        let currents = ["dark", "tokyo-night", "unknown-theme"];
        for cur in currents {
            let mut p = ThemePicker::new(cur.to_string());
            // Exercise each cursor position so every preview swatch renders.
            for _ in 0..p.names.len().max(1) {
                for (w, h) in [(1u16, 1u16), (10, 4), (40, 12), (70, 20), (200, 60)] {
                    let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
                    term.draw(|f| p.draw(f, f.area())).unwrap();
                }
                p.handle_key(key(KeyCode::Down));
            }
        }
    }

    #[test]
    fn truncate_is_char_boundary_safe() {
        let s = truncate_chars(&"\u{4e2d}\u{6587}\u{7684}\u{4e3b}\u{9898}".repeat(4), 6);
        assert!(s.chars().count() <= 6);
        assert!(s.ends_with('\u{2026}'));
    }
}