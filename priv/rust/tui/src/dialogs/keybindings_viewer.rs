//! `/keybindings` — a scrollable, branded viewer for the live keybinding map.
//!
//! The old `/keybindings` command dumped the whole `keymap.describe()` blob into
//! scrollback, where a 40-line binding table shoves the conversation off-screen
//! and can't be paged. This overlay renders the *same* text as a proper two-column
//! reference — `key` on the left (fixed, `c.secondary` bold), `action` on the
//! right (`c.muted`) — with section headings spanning the full width, a live
//! scrollbar, and a `row X of N` position hint.
//!
//! The data source is deliberately LOCAL and format-tolerant: `new(text)` takes a
//! single multi-line String. Each line is parsed into a typed [`Row`] — a
//! `Bind { key, action }` when it splits on the first of `" -> "`, `" => "`, or a
//! run of 2+ spaces; otherwise the whole line is a `Heading`. That way it renders
//! sensibly whether `describe()` emits `"ctrl+n -> app:newSession"`,
//! `"ctrl+n   new session"`, or bare section labels — and multibyte binding
//! descriptions never panic, because every slice goes through char-safe helpers.
//!
//! Stateful: the App owns one `KeybindingsViewer` and routes keys to
//! [`handle_key`], which scrolls (Up/Down/j/k, PageUp/PageDown, Home/End) and
//! reports [`ViewerAction::Close`] on Esc/q.

use crossterm::event::{KeyCode, KeyEvent};
use ratatui::{
    prelude::*,
    widgets::{Block, BorderType, Borders, Clear, Paragraph},
};

/// Clip-safe render (shared choke point with the other dialogs).
fn put<W: ratatui::widgets::Widget>(frame: &mut Frame, widget: W, rect: Rect) {
    crate::app::event_loop::safe_render_widget(frame, widget, rect);
}

const DIALOG_W: u16 = 76;
const MAX_H: u16 = 30;
/// Rows moved by PageUp / PageDown.
const PAGE: usize = 10;

/// A single parsed line of the keybinding description.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Row {
    /// A section label (unsplit line), rendered full-width in the accent color.
    Heading(String),
    /// A `key → action` binding pair.
    Bind { key: String, action: String },
}

/// Result of routing a key to the viewer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ViewerAction {
    /// Dismiss the overlay.
    Close,
    /// Key consumed, nothing to bubble up.
    None,
}

pub struct KeybindingsViewer {
    rows: Vec<Row>,
    /// Index of the top visible row.
    scroll: usize,
}

impl KeybindingsViewer {
    pub fn new(text: String) -> Self {
        Self { rows: parse_rows(&text), scroll: 0 }
    }

    /// Largest valid top-row index (clamped again at draw time against the real
    /// viewport, so `End` never leaves a blank tail).
    fn max_index(&self) -> usize {
        self.rows.len().saturating_sub(1)
    }

    pub fn handle_key(&mut self, key: KeyEvent) -> ViewerAction {
        let max = self.max_index();
        match key.code {
            KeyCode::Esc | KeyCode::Char('q') => return ViewerAction::Close,
            KeyCode::Up | KeyCode::Char('k') => {
                self.scroll = self.scroll.saturating_sub(1);
            }
            KeyCode::Down | KeyCode::Char('j') => {
                self.scroll = (self.scroll + 1).min(max);
            }
            KeyCode::PageUp => {
                self.scroll = self.scroll.saturating_sub(PAGE);
            }
            KeyCode::PageDown => {
                self.scroll = (self.scroll + PAGE).min(max);
            }
            KeyCode::Home => self.scroll = 0,
            KeyCode::End => self.scroll = max,
            _ => {}
        }
        ViewerAction::None
    }

    pub fn draw(&self, frame: &mut Frame, area: Rect) {
        let theme = crate::style::theme();
        let c = &theme.colors;

        // Fit the card to the content, capped by the terminal and MAX_H.
        // inner content = N list rows + 1 footer row.
        let desired_inner = self.rows.len().max(1) + 1;
        let h = ((desired_inner as u16).saturating_add(2)).min(MAX_H).min(area.height);
        let w = DIALOG_W.min(area.width);
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
                Span::styled("\u{00b7} keybindings ", Style::default().fg(c.muted)),
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

        // Reserve the last inner row for the footer/position hint.
        let list_h = inner.height.saturating_sub(1) as usize;
        let total = self.rows.len();

        if total == 0 {
            put(
                frame,
                Paragraph::new(Span::styled(
                    "no keybindings",
                    Style::default().fg(c.muted),
                ))
                .alignment(Alignment::Center),
                Rect::new(inner.x, inner.y + inner.height / 2, inner.width, 1),
            );
            return;
        }

        // A scrollbar only earns its column when content overflows.
        let overflow = total > list_h;
        let bar_col = u16::from(overflow);
        let row_w = inner.width.saturating_sub(bar_col);

        // Column geometry: key column ~1/3 of the row, bounded to sane widths.
        let key_w = ((row_w as usize) / 3).clamp(6, 22);
        let gap = 2usize;
        let action_w = (row_w as usize).saturating_sub(key_w + gap);

        // Clamp the stored offset against the REAL viewport so the last page is
        // always full (handle_key only knows row count, not height).
        let max_scroll = total.saturating_sub(list_h);
        let scroll = self.scroll.min(max_scroll);

        for rel in 0..list_h {
            let abs = rel + scroll;
            if abs >= total {
                break;
            }
            let ry = inner.y + rel as u16;
            match &self.rows[abs] {
                Row::Heading(h) => {
                    put(
                        frame,
                        Paragraph::new(Line::from(Span::styled(
                            truncate_chars(h, row_w as usize),
                            Style::default().fg(c.primary).add_modifier(Modifier::BOLD),
                        ))),
                        Rect::new(inner.x, ry, row_w, 1),
                    );
                }
                Row::Bind { key, action } => {
                    let key_txt = pad_or_truncate(key, key_w);
                    let act_txt = truncate_chars(action, action_w);
                    put(
                        frame,
                        Paragraph::new(Line::from(vec![
                            Span::styled(
                                key_txt,
                                Style::default().fg(c.secondary).add_modifier(Modifier::BOLD),
                            ),
                            Span::raw(" ".repeat(gap)),
                            Span::styled(act_txt, Style::default().fg(c.muted)),
                        ])),
                        Rect::new(inner.x, ry, row_w, 1),
                    );
                }
            }
        }

        // ── Scrollbar (right edge of the list area) ────────────────────────
        if overflow {
            let (thumb_start, thumb_len) = scrollbar_thumb(total, list_h, scroll);
            let bar_x = inner.x + inner.width - 1;
            for rel in 0..list_h {
                let (glyph, style) = if rel >= thumb_start && rel < thumb_start + thumb_len {
                    ("\u{2588}", Style::default().fg(c.primary))
                } else {
                    ("\u{2502}", Style::default().fg(c.dim))
                };
                put(
                    frame,
                    Paragraph::new(Span::styled(glyph, style)),
                    Rect::new(bar_x, inner.y + rel as u16, 1, 1),
                );
            }
        }

        // ── Footer: hint + position ────────────────────────────────────────
        let fy = inner.y + inner.height - 1;
        let bind_count = self.rows.iter().filter(|r| matches!(r, Row::Bind { .. })).count();
        put(
            frame,
            Paragraph::new(Line::from(vec![
                Span::styled("esc/q", Style::default().fg(c.secondary).add_modifier(Modifier::BOLD)),
                Span::styled(" close  ", Style::default().fg(c.dim)),
                Span::styled("\u{2191}\u{2193}/jk", Style::default().fg(c.secondary).add_modifier(Modifier::BOLD)),
                Span::styled(" scroll  ", Style::default().fg(c.dim)),
                Span::styled(format!("{bind_count} binds"), Style::default().fg(c.dim)),
            ])),
            Rect::new(inner.x, fy, inner.width.saturating_sub(14), 1),
        );
        put(
            frame,
            Paragraph::new(Span::styled(
                format!("row {} of {}  ", scroll + 1, total),
                Style::default().fg(c.muted),
            ))
            .alignment(Alignment::Right),
            Rect::new(inner.x, fy, inner.width, 1),
        );
    }
}

/// Split the description text into typed rows. Blank lines are dropped.
fn parse_rows(text: &str) -> Vec<Row> {
    let mut rows = Vec::new();
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() {
            continue;
        }
        match split_bind(line) {
            Some((key, action)) => rows.push(Row::Bind { key, action }),
            None => rows.push(Row::Heading(line.to_string())),
        }
    }
    rows
}

/// Tolerant key/action split: `" -> "`, `" => "`, then a run of 2+ spaces.
/// All separators are ASCII, so `str::find` byte offsets land on char
/// boundaries; the trimmed halves are re-owned safely.
fn split_bind(s: &str) -> Option<(String, String)> {
    for sep in [" -> ", " => "] {
        if let Some(idx) = s.find(sep) {
            let key = s[..idx].trim();
            let action = s[idx + sep.len()..].trim();
            if !key.is_empty() && !action.is_empty() {
                return Some((key.to_string(), action.to_string()));
            }
        }
    }
    if let Some(idx) = s.find("  ") {
        let key = s[..idx].trim();
        let action = s[idx..].trim();
        if !key.is_empty() && !action.is_empty() {
            return Some((key.to_string(), action.to_string()));
        }
    }
    None
}

/// Char-boundary-safe truncation (multibyte descriptions can never panic).
fn truncate_chars(s: &str, max: usize) -> String {
    if max == 0 {
        return String::new();
    }
    if s.chars().count() > max {
        let take = max.saturating_sub(1);
        format!("{}\u{2026}", s.chars().take(take).collect::<String>())
    } else {
        s.to_string()
    }
}

/// Truncate to `width` chars (char-safe) then right-pad with spaces so the key
/// column stays aligned regardless of the underlying byte length.
fn pad_or_truncate(s: &str, width: usize) -> String {
    let t = truncate_chars(s, width);
    let n = t.chars().count();
    if n < width {
        format!("{t}{}", " ".repeat(width - n))
    } else {
        t
    }
}

/// Compute `(thumb_start_row, thumb_len)` for a `viewport`-row scrollbar over
/// `total` items currently scrolled to `scroll`. Always at least one cell tall,
/// and pinned to the bottom when scrolled to the end.
fn scrollbar_thumb(total: usize, viewport: usize, scroll: usize) -> (usize, usize) {
    if total <= viewport || viewport == 0 {
        return (0, viewport);
    }
    let thumb_len = (viewport * viewport / total).max(1);
    let max_scroll = total - viewport;
    let track = viewport - thumb_len;
    let start = if max_scroll == 0 {
        0
    } else {
        (scroll * track + max_scroll / 2) / max_scroll
    };
    (start.min(track), thumb_len)
}

#[cfg(test)]
mod keybindings_viewer_tests {
    use super::*;
    use crossterm::event::{KeyEvent, KeyModifiers};
    use ratatui::{backend::TestBackend, Terminal};

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::empty())
    }

    const SAMPLE: &str = "Global\nctrl+n -> app:newSession\nctrl+o => transcript\ntab    complete\nEditing\nctrl+c  cancel\nplain heading with no split\n\u{4e2d}\u{6587}key -> \u{7ffb}\u{8bd1}\u{52a8}\u{4f5c}\u{8fd9}\u{662f}\u{4e00}\u{4e2a}\u{5f88}\u{957f}\u{7684}\u{63cf}\u{8ff0}";

    #[test]
    fn parses_all_three_separator_forms_and_headings() {
        let rows = parse_rows(SAMPLE);
        assert_eq!(rows[0], Row::Heading("Global".into()));
        assert_eq!(rows[1], Row::Bind { key: "ctrl+n".into(), action: "app:newSession".into() });
        assert_eq!(rows[2], Row::Bind { key: "ctrl+o".into(), action: "transcript".into() });
        assert_eq!(rows[3], Row::Bind { key: "tab".into(), action: "complete".into() });
        assert_eq!(rows[4], Row::Heading("Editing".into()));
        assert_eq!(rows[5], Row::Bind { key: "ctrl+c".into(), action: "cancel".into() });
        assert_eq!(rows[6], Row::Heading("plain heading with no split".into()));
        // Blank line dropped, multibyte bind kept.
        assert!(matches!(rows[7], Row::Bind { .. }));
    }

    #[test]
    fn scroll_keys_clamp_within_bounds() {
        let mut v = KeybindingsViewer::new(SAMPLE.into());
        let max = v.max_index();
        v.handle_key(key(KeyCode::Up)); // already at top, saturates
        assert_eq!(v.scroll, 0);
        v.handle_key(key(KeyCode::End));
        assert_eq!(v.scroll, max);
        v.handle_key(key(KeyCode::Down)); // at end, saturates
        assert_eq!(v.scroll, max);
        v.handle_key(key(KeyCode::Home));
        assert_eq!(v.scroll, 0);
        v.handle_key(key(KeyCode::PageDown));
        assert!(v.scroll <= max);
        assert_eq!(v.handle_key(key(KeyCode::Esc)), ViewerAction::Close);
        assert_eq!(v.handle_key(key(KeyCode::Char('q'))), ViewerAction::Close);
    }

    #[test]
    fn scrollbar_thumb_stays_in_track() {
        // 100 rows over a 10-row viewport, scrolled to the very bottom.
        let (start, len) = scrollbar_thumb(100, 10, 90);
        assert!(len >= 1);
        assert!(start + len <= 10, "thumb {start}+{len} overruns track");
    }

    #[test]
    fn draws_at_all_sizes_without_panic() {
        let inputs = [
            String::new(),
            "solo heading".to_string(),
            SAMPLE.to_string(),
            (0..80).map(|i| format!("key{i} -> action \u{20ac}\u{4e2d} {i}")).collect::<Vec<_>>().join("\n"),
        ];
        for text in inputs {
            let v = KeybindingsViewer::new(text);
            for (w, h) in [(1u16, 1u16), (10, 4), (40, 12), (70, 20), (200, 60)] {
                let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
                term.draw(|f| v.draw(f, f.area())).unwrap();
            }
        }
    }
}