//! `/mcp` — the MCP server list.
//!
//! A branded, scrollable overlay that answers "which Model Context Protocol
//! servers are wired, and are they actually up?" — one row per configured
//! server with a status dot (connected/connecting/error), its transport and
//! tool count, and an "off" tag when the server is disabled. Distinct from the
//! `mcp_approval` dialog (which gates a *pending* tool call): this is the
//! read-only inventory surfaced by `GET /api/v1/mcp`.
//!
//! Stateful: the app owns one [`McpServers`] built from the live server list.
//! Up/Down (or `j`/`k`) move the cursor, the scroll offset follows it so the
//! selection is always visible, and Esc/`q` close the overlay. Key handling is
//! navigation-only — there is no filter box here, so plain letters that are not
//! movement keys are ignored.

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

/// One MCP server, as surfaced by `GET /api/v1/mcp`.
pub struct McpServer {
    pub name: String,
    pub transport: String,
    pub enabled: bool,
    pub status: String,
    pub tool_count: i64,
    /// Where it came from ("osa" = the operator's own mcp.json).
    pub source: String,
    /// Whether space can switch it on/off here.
    pub toggleable: bool,
}

/// The full `/mcp` view: the server list plus cursor + scroll state.
pub struct McpServers {
    servers: Vec<McpServer>,
    /// Cursor index into `servers` (clamped to the last row).
    cursor: usize,
    /// Scroll offset in row space; kept in sync so the cursor stays visible.
    scroll: usize,
}

/// Bubble-up result of `/mcp` key handling.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum McpServersAction {
    /// The overlay should be dismissed.
    Close,
    /// Switch this server on or off, then refetch. Carries the name rather
    /// than the row index so the caller is not coupled to sort order.
    Toggle(String),
    /// Key consumed; keep the overlay open.
    None,
}

impl McpServers {
    pub fn new(servers: Vec<McpServer>) -> Self {
        Self {
            servers,
            cursor: 0,
            scroll: 0,
        }
    }

    /// Count of servers whose status reads as a live connection.
    fn connected_count(&self) -> usize {
        self.servers
            .iter()
            .filter(|s| is_connected(&s.status))
            .count()
    }

    pub fn handle_key(&mut self, key: KeyEvent) -> McpServersAction {
        // Chorded shortcuts belong to the app, not this list.
        if key.modifiers.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) {
            return McpServersAction::None;
        }
        let last = self.servers.len().saturating_sub(1);
        match key.code {
            KeyCode::Esc | KeyCode::Char('q') => return McpServersAction::Close,
            KeyCode::Up | KeyCode::Char('k') => {
                self.cursor = self.cursor.saturating_sub(1);
            }
            KeyCode::Down | KeyCode::Char('j') => {
                self.cursor = (self.cursor + 1).min(last);
            }
            KeyCode::Home => self.cursor = 0,
            KeyCode::End => self.cursor = last,
            // Space switches the highlighted server on or off. Only inherited
            // servers are toggleable: OSA's own mcp.json entries are the
            // operator's deliberate config and are not rewritten from here, so
            // the key is a no-op on those rather than a silent failure.
            KeyCode::Char(' ') | KeyCode::Enter => {
                if let Some(s) = self.servers.get(self.cursor) {
                    if s.toggleable {
                        return McpServersAction::Toggle(s.name.clone());
                    }
                }
            }
            _ => {}
        }
        McpServersAction::None
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
                Span::styled("\u{00b7} mcp ", Style::default().fg(c.muted)),
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

        // ── header count ────────────────────────────────────────────────────
        let total = self.servers.len();
        let connected = self.connected_count();
        // "available" rows are servers found in another tool's config that the
        // allow list does not name yet. Counting them separately answers the
        // question the old header could not: how many could I turn on?
        let off = self
            .servers
            .iter()
            .filter(|s| s.status.eq_ignore_ascii_case("available"))
            .count();
        let header = if off > 0 {
            format!(
                "{} on ({connected} connected) \u{00b7} {off} available to enable",
                total - off
            )
        } else {
            format!(
                "{total} server{} ({connected} connected)",
                if total == 1 { "" } else { "s" }
            )
        };
        put(
            frame,
            Paragraph::new(Line::from(Span::styled(
                truncate_chars(&header, maxw),
                Style::default().fg(c.primary).add_modifier(Modifier::BOLD),
            ))),
            Rect::new(inner.x, cy, iw, 1),
        );
        cy += 1;

        // ── separator ───────────────────────────────────────────────────────
        put(
            frame,
            Paragraph::new(Span::styled(
                "\u{2500}".repeat(maxw),
                Style::default().fg(c.dim),
            )),
            Rect::new(inner.x, cy, iw, 1),
        );
        cy += 1;

        // ── list / empty state ──────────────────────────────────────────────
        let list_h = inner.height.saturating_sub(3); // header + separator + footer.
        let vp = (list_h as usize).max(1);

        if self.servers.is_empty() {
            let msg = "No MCP servers configured. Add them in .mcp.json or ~/.osa/mcp.json.";
            put(
                frame,
                Paragraph::new(Span::styled(
                    truncate_chars(msg, maxw),
                    Style::default().fg(c.muted),
                ))
                .alignment(Alignment::Center),
                Rect::new(inner.x, cy + list_h / 2, iw, 1),
            );
        } else {
            let scroll = crate::dialogs::clamp_scroll_to_cursor(self.scroll, self.cursor, vp);
            for rel in 0..(list_h as usize) {
                let abs = rel + scroll;
                let Some(s) = self.servers.get(abs) else { break };
                let ry = cy + rel as u16;
                let selected = abs == self.cursor;
                self.draw_row(frame, s, selected, Rect::new(inner.x, ry, iw, 1), c, &theme);
            }
        }

        // ── footer hint ─────────────────────────────────────────────────────
        let hint_y = inner.y + inner.height.saturating_sub(1);
        put(
            frame,
            Paragraph::new(Line::from(vec![
                Span::styled(
                    "\u{2191}\u{2193}",
                    Style::default().fg(c.secondary).add_modifier(Modifier::BOLD),
                ),
                Span::styled(" nav  ", Style::default().fg(c.dim)),
                Span::styled(
                    "space",
                    Style::default().fg(c.secondary).add_modifier(Modifier::BOLD),
                ),
                Span::styled(" enable/disable  ", Style::default().fg(c.dim)),
                Span::styled(
                    "esc",
                    Style::default().fg(c.secondary).add_modifier(Modifier::BOLD),
                ),
                Span::styled(" close", Style::default().fg(c.dim)),
            ])),
            Rect::new(inner.x, hint_y, iw, 1),
        );
    }

    /// One server row: status dot + name (bright), dim "transport · N tools",
    /// and a right-aligned "off" tag when disabled. Selected rows get the
    /// full-width active button bar.
    fn draw_row(
        &self,
        frame: &mut Frame,
        s: &McpServer,
        selected: bool,
        rect: Rect,
        c: &crate::style::ThemeColors,
        theme: &crate::style::Theme,
    ) {
        let maxw = rect.width as usize;
        let dot_color = status_color(&s.status, c);
        let meta = format!(
            "{} \u{00b7} {} tool{}",
            s.transport,
            s.tool_count.max(0),
            if s.tool_count == 1 { "" } else { "s" }
        );
        let off_tag = if s.enabled { "" } else { "off" };

        if selected {
            // Flatten to a single styled bar so the highlight reads cleanly.
            let off_suffix = if off_tag.is_empty() {
                String::new()
            } else {
                format!("  [{off_tag}]")
            };
            let raw = format!("  \u{25CF} {}   {}{}", s.name, meta, off_suffix);
            let line = crate::util::pad_cols(&raw, maxw);
            put(
                frame,
                Paragraph::new(Line::from(Span::styled(line, theme.button_active()))),
                rect,
            );
            return;
        }

        // Reserve space for a right-aligned "off" tag when present.
        let tag_w = if off_tag.is_empty() { 0 } else { crate::util::cols(&off_tag) + 1 };
        let body_w = maxw.saturating_sub(tag_w);

        let dot = Span::styled("\u{25CF} ", Style::default().fg(dot_color));
        let name = truncate_chars(&s.name, body_w.saturating_sub(6));
        let used = 2 + 2 + crate::util::cols(&name); // "  " + dot + name.
        let mut spans = vec![
            Span::raw("  "),
            dot,
            Span::styled(
                name,
                Style::default().fg(c.secondary).add_modifier(Modifier::BOLD),
            ),
        ];
        let remaining = body_w.saturating_sub(used);
        if remaining > 4 {
            let m = truncate_chars(&meta, remaining.saturating_sub(3));
            spans.push(Span::styled(format!("   {m}"), Style::default().fg(c.dim)));
        }
        put(frame, Paragraph::new(Line::from(spans)), rect);

        // Right-aligned "off" tag (drawn as its own clipped paragraph).
        if !off_tag.is_empty() && tag_w < maxw {
            let tag_x = rect.x + rect.width.saturating_sub(tag_w as u16);
            put(
                frame,
                Paragraph::new(Span::styled(
                    off_tag,
                    Style::default().fg(c.dim).add_modifier(Modifier::BOLD),
                )),
                Rect::new(tag_x, rect.y, tag_w as u16, 1),
            );
        }
    }
}

/// Whether a status string reads as an established connection.
fn is_connected(status: &str) -> bool {
    matches!(status.trim().to_lowercase().as_str(), "connected" | "ready" | "up")
}

/// Map a server status to its dot color.
fn status_color(status: &str, c: &crate::style::ThemeColors) -> Color {
    match status.trim().to_lowercase().as_str() {
        "connected" | "ready" | "up" => c.success,
        "connecting" | "starting" | "pending" => c.warning,
        "error" | "failed" | "disconnected" | "down" => c.error,
        _ => c.dim,
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
mod mcp_servers_tests {
    use super::*;
    use ratatui::{backend::TestBackend, Terminal};

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::empty())
    }

    fn sample() -> Vec<McpServer> {
        vec![
            McpServer { name: "filesystem".into(), transport: "stdio".into(), enabled: true, status: "connected".into(), tool_count: 12, source: "claude_code".into(), toggleable: true },
            McpServer { name: "github".into(), transport: "stdio".into(), enabled: true, status: "connecting".into(), tool_count: 0, source: "claude_code".into(), toggleable: true },
            McpServer { name: "postgres".into(), transport: "http".into(), enabled: false, status: "disabled".into(), tool_count: 3, source: "claude_code".into(), toggleable: true },
            McpServer { name: "sentry".into(), transport: "sse".into(), enabled: true, status: "error".into(), tool_count: 1, source: "claude_code".into(), toggleable: true },
            McpServer { name: "\u{4e2d}\u{6587}\u{670d}\u{52a1}\u{5668}".into(), transport: "\u{20ac}".repeat(40), enabled: true, status: "ready".into(), tool_count: 99, source: "claude_code".into(), toggleable: true },
        ]
    }

    #[test]
    fn connected_count_reflects_status() {
        let m = McpServers::new(sample());
        // "connected" + "ready" count; connecting/error/disabled do not.
        assert_eq!(m.connected_count(), 2);
    }

    #[test]
    fn cursor_navigates_and_clamps() {
        let mut m = McpServers::new(sample());
        assert_eq!(m.cursor, 0);
        for _ in 0..20 {
            m.handle_key(key(KeyCode::Down));
        }
        assert_eq!(m.cursor, m.servers.len() - 1);
        m.handle_key(key(KeyCode::Home));
        assert_eq!(m.cursor, 0);
        // 'j'/'k' mirror the arrows.
        m.handle_key(key(KeyCode::Char('j')));
        assert_eq!(m.cursor, 1);
        m.handle_key(key(KeyCode::Char('k')));
        assert_eq!(m.cursor, 0);
    }

    #[test]
    fn esc_and_q_close() {
        let mut m = McpServers::new(sample());
        assert_eq!(m.handle_key(key(KeyCode::Char('q'))), McpServersAction::Close);
        assert_eq!(m.handle_key(key(KeyCode::Esc)), McpServersAction::Close);
    }

    #[test]
    fn empty_list_is_safe() {
        let mut m = McpServers::new(Vec::new());
        assert_eq!(m.connected_count(), 0);
        m.handle_key(key(KeyCode::Down));
        assert_eq!(m.cursor, 0);
        assert_eq!(m.handle_key(key(KeyCode::Esc)), McpServersAction::Close);
    }

    #[test]
    fn draws_at_all_sizes_without_panic() {
        let states: Vec<Vec<McpServer>> = vec![Vec::new(), sample()];
        for servers in states {
            let mut m = McpServers::new(servers);
            // Move the cursor so selection-bar rendering is exercised too.
            for _ in 0..3 {
                m.handle_key(key(KeyCode::Down));
            }
            for (w, h) in [(1u16, 1u16), (10, 4), (40, 12), (70, 20), (200, 60)] {
                let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
                term.draw(|f| m.draw(f, f.area())).unwrap();
            }
        }
    }
}