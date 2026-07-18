//! `/channels` — the connected-messaging-channels panel.
//!
//! A branded, scrollable overlay that answers "which messaging surfaces is OSA
//! wired to right now?" — every registered channel adapter (Telegram, Slack,
//! Discord, Signal, WhatsApp, Matrix, Email, Line, DingTalk, Feishu, WeCom),
//! each with a live status dot, its display name, and a dim kind/status tail.
//! Mirrors `Channels.Manager.list_channels/0`: a fixed roster where each row is
//! either connected (a green dot) or idle/errored (a dim/red dot).
//!
//! Stateful: the app owns one [`ChannelsPanel`] built from the backend snapshot.
//! Arrow / `j`/`k` / PageUp·Down / Home·End move the cursor, the scroll offset
//! is re-clamped every frame so the selected row stays visible, and `Esc`/`q`
//! close the overlay. There is no filter box — the channel roster is small and
//! fixed, so navigation is pure cursor movement.

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

const DIALOG_W: u16 = 64;
const DIALOG_H: u16 = 22;

/// One messaging channel adapter, as surfaced by `Channels.Manager`.
pub struct ChannelEntry {
    /// Display name, e.g. `"telegram"`.
    pub name: String,
    /// Whether the adapter process is live and connected.
    pub connected: bool,
    /// Free-text status tail, e.g. `"running"`, `"not configured"`, `"error"`.
    pub status: String,
    /// Channel kind/transport, e.g. `"bot"`, `"webhook"`, `"xmpp"`.
    pub kind: String,
}

/// Bubble-up result of channels-panel key handling.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChannelsPanelAction {
    /// The overlay should be dismissed.
    Close,
    /// Key consumed; keep the overlay open.
    None,
}

pub struct ChannelsPanel {
    channels: Vec<ChannelEntry>,
    /// Cursor index into `channels` (clamped to the last row).
    cursor: usize,
    /// Scroll offset in row space.
    scroll: usize,
    /// List height measured on the last draw, so `handle_key` page/scroll math
    /// matches the real dialog instead of the `DIALOG_H` upper bound.
    list_viewport: Cell<usize>,
}

impl ChannelsPanel {
    pub fn new(channels: Vec<ChannelEntry>) -> Self {
        Self {
            channels,
            cursor: 0,
            scroll: 0,
            list_viewport: Cell::new((DIALOG_H as usize).saturating_sub(4)),
        }
    }

    /// Count of currently-connected channels.
    fn connected_count(&self) -> usize {
        self.channels.iter().filter(|c| c.connected).count()
    }

    /// Re-clamp the stored scroll so the cursor stays visible after a move
    /// (uses the last measured viewport height).
    fn adjust_scroll(&mut self) {
        let vp = self.list_viewport.get().max(1);
        self.scroll = crate::dialogs::clamp_scroll_to_cursor(self.scroll, self.cursor, vp);
    }

    pub fn handle_key(&mut self, key: KeyEvent) -> ChannelsPanelAction {
        // Ignore chorded shortcuts — they belong to the app, not this overlay.
        if key.modifiers.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) {
            return ChannelsPanelAction::None;
        }
        let last = self.channels.len().saturating_sub(1);
        let page = self.list_viewport.get().max(1);
        match key.code {
            KeyCode::Esc | KeyCode::Char('q') => return ChannelsPanelAction::Close,
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
        ChannelsPanelAction::None
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
                Span::styled(
                    " OSA ",
                    Style::default().fg(c.primary).add_modifier(Modifier::BOLD),
                ),
                Span::styled("\u{00b7} channels ", Style::default().fg(c.muted)),
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

        // ── count summary ──────────────────────────────────────────────────
        let total = self.channels.len();
        let live = self.connected_count();
        put(
            frame,
            Paragraph::new(Line::from(vec![
                Span::styled(
                    format!("{live}"),
                    Style::default().fg(c.success).add_modifier(Modifier::BOLD),
                ),
                Span::styled(
                    format!(" connected \u{00b7} {total} channels"),
                    Style::default().fg(c.muted),
                ),
            ])),
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
        let list_h = inner.height.saturating_sub(3); // count + separator + help.
        self.list_viewport.set((list_h as usize).max(1));

        if total == 0 {
            put(
                frame,
                Paragraph::new(Span::styled(
                    truncate_chars("No channels registered", maxw),
                    Style::default().fg(c.muted),
                ))
                .alignment(Alignment::Center),
                Rect::new(inner.x, cy + list_h / 2, iw, 1),
            );
        } else {
            let scroll = crate::dialogs::clamp_scroll_to_cursor(
                self.scroll,
                self.cursor,
                (list_h as usize).max(1),
            );
            for rel in 0..(list_h as usize) {
                let abs = rel + scroll;
                let Some(ch) = self.channels.get(abs) else {
                    break;
                };
                let ry = cy + rel as u16;
                let selected = abs == self.cursor;

                // Status dot: connected → success, errored → error, else dim.
                let dot_color = if ch.connected {
                    c.success
                } else if is_error(&ch.status) {
                    c.error
                } else {
                    c.dim
                };
                // Trailing detail: kind + status, dim.
                let tail = channel_tail(ch);

                if selected {
                    // Full-width highlight bar. The dot keeps its own color so
                    // connection state stays legible even on the active row.
                    let name = truncate_chars(&ch.name, maxw.saturating_sub(4));
                    let head = format!("  \u{25CF} {name}");
                    let mut line = head.clone();
                    if !tail.is_empty() {
                        line.push_str(&format!("   {tail}"));
                    }
                    let mut s = truncate_chars(&line, maxw);
                    let pad = maxw.saturating_sub(s.chars().count());
                    s.push_str(&" ".repeat(pad));
                    put(
                        frame,
                        Paragraph::new(Line::from(vec![Span::styled(s, theme.button_active())])),
                        Rect::new(inner.x, ry, iw, 1),
                    );
                } else {
                    let name = truncate_chars(&ch.name, maxw.saturating_sub(4));
                    let used = 4 + name.chars().count(); // "  ● " + name.
                    let mut spans = vec![
                        Span::styled("  \u{25CF} ", Style::default().fg(dot_color)),
                        Span::styled(
                            name,
                            Style::default()
                                .fg(if ch.connected { c.secondary } else { c.muted })
                                .add_modifier(Modifier::BOLD),
                        ),
                    ];
                    let remaining = maxw.saturating_sub(used);
                    if remaining > 5 && !tail.is_empty() {
                        let t = truncate_chars(&tail, remaining - 3);
                        spans.push(Span::styled(
                            format!("   {t}"),
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

        // ── footer hint ────────────────────────────────────────────────────
        let hint_y = inner.y + inner.height.saturating_sub(1);
        put(
            frame,
            Paragraph::new(Line::from(vec![
                Span::styled(
                    "\u{2191}\u{2193}",
                    Style::default().fg(c.secondary).add_modifier(Modifier::BOLD),
                ),
                Span::styled(" nav   ", Style::default().fg(c.dim)),
                Span::styled(
                    "esc",
                    Style::default().fg(c.secondary).add_modifier(Modifier::BOLD),
                ),
                Span::styled(" close", Style::default().fg(c.dim)),
            ])),
            Rect::new(inner.x, hint_y, iw, 1),
        );
    }
}

/// A status string that reads as an error condition (dot goes red).
fn is_error(status: &str) -> bool {
    let s = status.to_lowercase();
    s.contains("error") || s.contains("fail") || s.contains("dead")
}

/// Build the dim `kind · status` detail tail, skipping empty parts.
fn channel_tail(ch: &ChannelEntry) -> String {
    match (ch.kind.trim().is_empty(), ch.status.trim().is_empty()) {
        (true, true) => String::new(),
        (false, true) => ch.kind.clone(),
        (true, false) => ch.status.clone(),
        (false, false) => format!("{} \u{00b7} {}", ch.kind, ch.status),
    }
}

/// Char-boundary-safe truncation (multi-byte channel names can never panic).
fn truncate_chars(s: &str, max: usize) -> String {
    if s.chars().count() > max {
        let take = max.saturating_sub(1);
        format!("{}\u{2026}", s.chars().take(take).collect::<String>())
    } else {
        s.to_string()
    }
}

#[cfg(test)]
mod channels_panel_tests {
    use super::*;
    use ratatui::{backend::TestBackend, Terminal};

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::empty())
    }

    fn sample() -> Vec<ChannelEntry> {
        vec![
            ChannelEntry { name: "telegram".into(), connected: true, status: "running".into(), kind: "bot".into() },
            ChannelEntry { name: "slack".into(), connected: false, status: "not configured".into(), kind: "app".into() },
            ChannelEntry { name: "discord".into(), connected: true, status: "running".into(), kind: "bot".into() },
            ChannelEntry { name: "signal".into(), connected: false, status: "error: socket".into(), kind: "cli".into() },
            ChannelEntry { name: "whatsapp".into(), connected: false, status: "".into(), kind: "".into() },
            ChannelEntry { name: "\u{4e2d}\u{6587}\u{6e20}\u{9053}".into(), connected: true, status: "\u{20ac}".repeat(80), kind: "xmpp".into() },
        ]
    }

    #[test]
    fn connected_count_is_accurate() {
        let p = ChannelsPanel::new(sample());
        assert_eq!(p.connected_count(), 3);
    }

    #[test]
    fn cursor_moves_and_clamps() {
        let mut p = ChannelsPanel::new(sample());
        for _ in 0..50 {
            p.handle_key(key(KeyCode::Char('j')));
        }
        assert_eq!(p.cursor, p.channels.len() - 1);
        p.handle_key(key(KeyCode::Home));
        assert_eq!(p.cursor, 0);
        p.handle_key(key(KeyCode::End));
        assert_eq!(p.cursor, p.channels.len() - 1);
        // Up past the top saturates at 0.
        for _ in 0..50 {
            p.handle_key(key(KeyCode::Up));
        }
        assert_eq!(p.cursor, 0);
    }

    #[test]
    fn esc_and_q_close() {
        let mut p = ChannelsPanel::new(sample());
        assert_eq!(p.handle_key(key(KeyCode::Char('j'))), ChannelsPanelAction::None);
        assert_eq!(p.handle_key(key(KeyCode::Esc)), ChannelsPanelAction::Close);
        assert_eq!(p.handle_key(key(KeyCode::Char('q'))), ChannelsPanelAction::Close);
    }

    #[test]
    fn chorded_keys_are_ignored() {
        let mut p = ChannelsPanel::new(sample());
        let ev = KeyEvent::new(KeyCode::Char('q'), KeyModifiers::CONTROL);
        // Ctrl+q belongs to the app; the panel must not close on it.
        assert_eq!(p.handle_key(ev), ChannelsPanelAction::None);
    }

    #[test]
    fn empty_roster_is_safe() {
        let mut p = ChannelsPanel::new(Vec::new());
        assert_eq!(p.connected_count(), 0);
        p.handle_key(key(KeyCode::Down));
        assert_eq!(p.cursor, 0);
        assert_eq!(p.handle_key(key(KeyCode::Esc)), ChannelsPanelAction::Close);
    }

    #[test]
    fn error_and_tail_helpers() {
        assert!(is_error("error: socket"));
        assert!(is_error("connection FAILED"));
        assert!(!is_error("running"));
        let both = channel_tail(&ChannelEntry {
            name: "x".into(), connected: true, status: "up".into(), kind: "bot".into(),
        });
        assert!(both.contains("bot") && both.contains("up"));
        let empty = channel_tail(&ChannelEntry {
            name: "x".into(), connected: false, status: "".into(), kind: "".into(),
        });
        assert_eq!(empty, "");
    }

    #[test]
    fn draws_at_all_sizes_without_panic() {
        let states: Vec<Vec<ChannelEntry>> = vec![Vec::new(), sample()];
        for chans in states {
            let mut p = ChannelsPanel::new(chans);
            // Move the cursor mid-list so the highlight + scroll paths render.
            for _ in 0..3 {
                p.handle_key(key(KeyCode::Down));
            }
            for (w, h) in [(1u16, 1u16), (10, 4), (40, 12), (70, 20), (200, 60)] {
                let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
                term.draw(|f| p.draw(f, f.area())).unwrap();
            }
        }
    }
}
