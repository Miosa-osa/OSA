/// Session browser dialog — list, switch, rename, and delete sessions.
///
/// # Actions to add to `DialogAction` in mod.rs:
/// ```
/// SessionSwitch(String),
/// SessionCreate,
/// SessionRename { id: String, new_title: String },
/// SessionDelete(String),
/// SessionBrowserCancel,
/// ```
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::{
    prelude::*,
    widgets::{Block, BorderType, Borders, Clear, Paragraph},
};

use crate::client::types::SessionInfo;

const MAX_W: u16 = 80;
const MAX_H: u16 = 28;

// ── Action ──────────────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub enum SessionAction {
    Switch(String),
    Create,
    Rename(String, String), // id, new_title
    Delete(String),
    Cancel,
}

// ── Mode ─────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq)]
enum SessionMode {
    Browse,
    Rename,
    DeleteConfirm,
}

// ── State ────────────────────────────────────────────────────────────────────

pub struct SessionBrowser {
    sessions: Vec<SessionInfo>,
    active_id: String,
    filter: String,
    /// Indices into `sessions` that pass the current filter
    filtered: Vec<usize>,
    cursor: usize,
    scroll_offset: usize,
    mode: SessionMode,
    rename_buf: String,
    delete_confirm: bool,
}

impl SessionBrowser {
    pub fn new(sessions: Vec<SessionInfo>, active_id: String) -> Self {
        let filtered: Vec<usize> = (0..sessions.len()).collect();
        Self {
            sessions,
            active_id,
            filter: String::new(),
            filtered,
            cursor: 0,
            scroll_offset: 0,
            mode: SessionMode::Browse,
            rename_buf: String::new(),
            delete_confirm: false,
        }
    }

    // ── Filter ────────────────────────────────────────────────────────────────

    fn rebuild_filter(&mut self) {
        let f = self.filter.to_lowercase();
        self.filtered = (0..self.sessions.len())
            .filter(|&i| {
                let s = &self.sessions[i];
                f.is_empty()
                    || s.title.to_lowercase().contains(&f)
                    || s.id.to_lowercase().contains(&f)
            })
            .collect();
        self.cursor = self.cursor.min(self.filtered.len().saturating_sub(1));
        self.adjust_scroll();
    }

    // ── Navigation ────────────────────────────────────────────────────────────

    fn move_up(&mut self) {
        if !self.filtered.is_empty() {
            self.cursor = self.cursor.checked_sub(1).unwrap_or(self.filtered.len() - 1);
            self.adjust_scroll();
        }
    }

    fn move_down(&mut self) {
        if !self.filtered.is_empty() {
            self.cursor = (self.cursor + 1) % self.filtered.len();
            self.adjust_scroll();
        }
    }

    fn adjust_scroll(&mut self) {
        let visible: usize = (MAX_H as usize).saturating_sub(7);
        if self.cursor < self.scroll_offset {
            self.scroll_offset = self.cursor;
        } else if self.cursor >= self.scroll_offset + visible {
            self.scroll_offset = self.cursor - visible + 1;
        }
    }

    fn current_session(&self) -> Option<&SessionInfo> {
        let idx = *self.filtered.get(self.cursor)?;
        self.sessions.get(idx)
    }

    // ── Key handling ─────────────────────────────────────────────────────────

    pub fn handle_key(&mut self, key: KeyEvent) -> Option<SessionAction> {
        if key.modifiers.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) {
            return None;
        }

        match self.mode {
            SessionMode::Browse => self.handle_browse(key),
            SessionMode::Rename => self.handle_rename(key),
            SessionMode::DeleteConfirm => self.handle_delete_confirm(key),
        }
    }

    fn handle_browse(&mut self, key: KeyEvent) -> Option<SessionAction> {
        match key.code {
            KeyCode::Esc => return Some(SessionAction::Cancel),
            KeyCode::Enter => {
                if let Some(s) = self.current_session() {
                    return Some(SessionAction::Switch(s.id.clone()));
                }
            }
            KeyCode::Char('n') => return Some(SessionAction::Create),
            KeyCode::Char('r') => {
                if let Some(s) = self.current_session() {
                    self.rename_buf = if s.title.is_empty() {
                        "Untitled".to_string()
                    } else {
                        s.title.clone()
                    };
                    self.mode = SessionMode::Rename;
                }
            }
            KeyCode::Char('d') => {
                if self.current_session().is_some() {
                    self.delete_confirm = false;
                    self.mode = SessionMode::DeleteConfirm;
                }
            }
            KeyCode::Up | KeyCode::Char('k') => {
                if self.filter.is_empty() {
                    self.move_up();
                } else {
                    self.move_up();
                }
            }
            KeyCode::Down | KeyCode::Char('j') => self.move_down(),
            KeyCode::Backspace => {
                self.filter.pop();
                self.rebuild_filter();
            }
            KeyCode::Char(c) if c.is_alphanumeric() || c == ' ' || c == '-' || c == '_' => {
                self.filter.push(c);
                self.rebuild_filter();
            }
            _ => {}
        }
        None
    }

    fn handle_rename(&mut self, key: KeyEvent) -> Option<SessionAction> {
        match key.code {
            KeyCode::Enter => {
                if let Some(s) = self.current_session() {
                    let id = s.id.clone();
                    let new_title = self.rename_buf.trim().to_string();
                    self.mode = SessionMode::Browse;
                    if !new_title.is_empty() {
                        return Some(SessionAction::Rename(id, new_title));
                    }
                }
                self.mode = SessionMode::Browse;
            }
            KeyCode::Esc => {
                self.mode = SessionMode::Browse;
            }
            KeyCode::Backspace => {
                self.rename_buf.pop();
            }
            KeyCode::Char(c) => {
                self.rename_buf.push(c);
            }
            _ => {}
        }
        None
    }

    fn handle_delete_confirm(&mut self, key: KeyEvent) -> Option<SessionAction> {
        match key.code {
            KeyCode::Char('y') | KeyCode::Char('Y') | KeyCode::Enter => {
                if let Some(s) = self.current_session() {
                    let id = s.id.clone();
                    self.mode = SessionMode::Browse;
                    return Some(SessionAction::Delete(id));
                }
                self.mode = SessionMode::Browse;
            }
            _ => {
                // Any other key cancels
                self.mode = SessionMode::Browse;
            }
        }
        None
    }

    // ── Drawing ───────────────────────────────────────────────────────────────

    pub fn draw(&self, frame: &mut Frame, area: Rect) {
        let theme = crate::style::theme();

        let w = MAX_W.min(area.width);
        let h = MAX_H.min(area.height);
        let x = area.x + area.width.saturating_sub(w) / 2;
        let y = area.y + area.height.saturating_sub(h) / 2;
        let dialog_rect = Rect::new(x, y, w, h);

        frame.render_widget(Clear, dialog_rect);

        let border_style = match self.mode {
            SessionMode::DeleteConfirm => Style::default().fg(theme.colors.error),
            _ => Style::default().fg(theme.colors.primary),
        };

        let block = Block::default()
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(border_style)
            .style(Style::default().bg(theme.colors.dialog_bg));
        frame.render_widget(block, dialog_rect);

        let inner = Rect::new(
            dialog_rect.x + 1,
            dialog_rect.y + 1,
            dialog_rect.width.saturating_sub(2),
            dialog_rect.height.saturating_sub(2),
        );
        if inner.height < 4 {
            return;
        }

        let mut cy = inner.y;

        // Title
        let title_text = match self.mode {
            SessionMode::Browse => "Sessions",
            SessionMode::Rename => "Rename Session",
            SessionMode::DeleteConfirm => "Delete Session?",
        };
        frame.render_widget(
            Paragraph::new(title_text)
                .style(theme.dialog_title())
                .alignment(Alignment::Center),
            Rect::new(inner.x, cy, inner.width, 1),
        );
        cy += 1;

        // Delete confirmation banner
        if self.mode == SessionMode::DeleteConfirm {
            let banner = Paragraph::new(
                "  Press y / Enter to confirm delete, any other key to cancel",
            )
            .style(Style::default().fg(theme.colors.error));
            frame.render_widget(banner, Rect::new(inner.x, cy, inner.width, 1));
            cy += 1;
        }

        // Filter / rename bar
        let bar_text = match self.mode {
            SessionMode::Rename => {
                format!("  Rename: {}_", self.rename_buf)
            }
            _ => {
                let count = self.filtered.len();
                if self.filter.is_empty() {
                    format!("  Filter: _  ({} sessions)", count)
                } else {
                    format!("  Filter: {}_  ({} sessions)", self.filter, count)
                }
            }
        };
        frame.render_widget(
            Paragraph::new(bar_text).style(Style::default().fg(theme.colors.secondary)),
            Rect::new(inner.x, cy, inner.width, 1),
        );
        cy += 1;

        // Separator
        let sep = "─".repeat(inner.width as usize);
        frame.render_widget(
            Paragraph::new(sep.as_str()).style(Style::default().fg(theme.colors.dim)),
            Rect::new(inner.x, cy, inner.width, 1),
        );
        cy += 1;

        // List
        let list_h = inner.height.saturating_sub(cy - inner.y + 2);
        let visible_sessions = self
            .filtered
            .iter()
            .skip(self.scroll_offset)
            .take(list_h as usize);

        for (rel_i, &idx) in visible_sessions.enumerate() {
            let abs_i = rel_i + self.scroll_offset;
            let ry = cy + rel_i as u16;
            if ry >= cy + list_h {
                break;
            }

            let s = &self.sessions[idx];
            let is_active = s.id == self.active_id;
            let is_selected = abs_i == self.cursor;
            let is_renaming = is_selected && self.mode == SessionMode::Rename;

            let dot = if is_active { "●" } else { "○" };
            let dot_style = if is_active {
                Style::default().fg(theme.colors.success)
            } else {
                Style::default().fg(theme.colors.dim)
            };

            let cursor_char = if is_selected { "▸" } else { " " };
            let row_style = if is_selected {
                Style::default()
                    .fg(theme.colors.primary)
                    .add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(theme.colors.muted)
            };

            let title_str = if is_renaming {
                format!("{}_", self.rename_buf)
            } else if s.title.is_empty() {
                "Untitled".to_string()
            } else {
                s.title.clone()
            };

            // Truncate title
            let max_title = inner.width.saturating_sub(30) as usize;
            let title_display = if title_str.len() > max_title {
                format!("{}…", crate::util::truncate_str(&title_str, max_title.saturating_sub(1)))
            } else {
                title_str
            };

            // Date — prefer last-active time (from /recent listings) when
            // present, otherwise fall back to the creation date. Just the date
            // portion (YYYY-MM-DD) to keep the column narrow.
            let date_source = match &s.last_active {
                Some(la) if !la.is_empty() => la.as_str(),
                _ => s.created_at.as_str(),
            };
            let date_display = if date_source.len() >= 10 {
                crate::util::truncate_str(date_source, 10).to_string()
            } else {
                date_source.to_string()
            };

            let msg_count = format!(" {}msg", s.message_count);

            let spans = vec![
                Span::styled(format!("{} ", cursor_char), row_style),
                Span::styled(dot, dot_style),
                Span::raw(" "),
                Span::styled(title_display, row_style),
                Span::raw("  "),
                Span::styled(date_display, Style::default().fg(theme.colors.dim)),
                Span::styled(msg_count, Style::default().fg(theme.colors.dim)),
            ];

            frame.render_widget(
                Paragraph::new(Line::from(spans)),
                Rect::new(inner.x, ry, inner.width, 1),
            );
        }

        // Help bar
        let bottom_y = inner.y + inner.height.saturating_sub(1);
        let help = match self.mode {
            SessionMode::Browse => Line::from(vec![
                Span::styled("↑↓", theme.dialog_help_key()),
                Span::styled(" nav  ", theme.dialog_help()),
                Span::styled("Enter", theme.dialog_help_key()),
                Span::styled(" switch  ", theme.dialog_help()),
                Span::styled("r", theme.dialog_help_key()),
                Span::styled(" rename  ", theme.dialog_help()),
                Span::styled("d", theme.dialog_help_key()),
                Span::styled(" delete  ", theme.dialog_help()),
                Span::styled("n", theme.dialog_help_key()),
                Span::styled(" new  ", theme.dialog_help()),
                Span::styled("Esc", theme.dialog_help_key()),
                Span::styled(" cancel", theme.dialog_help()),
            ]),
            SessionMode::Rename => Line::from(vec![
                Span::styled("Enter", theme.dialog_help_key()),
                Span::styled(" confirm  ", theme.dialog_help()),
                Span::styled("Esc", theme.dialog_help_key()),
                Span::styled(" cancel", theme.dialog_help()),
            ]),
            SessionMode::DeleteConfirm => Line::from(vec![
                Span::styled("y/Enter", theme.dialog_help_key()),
                Span::styled(" confirm  ", theme.dialog_help()),
                Span::styled("any", theme.dialog_help_key()),
                Span::styled(" cancel", theme.dialog_help()),
            ]),
        };

        frame.render_widget(
            Paragraph::new(help).alignment(Alignment::Center),
            Rect::new(inner.x, bottom_y, inner.width, 1),
        );
    }
}

#[cfg(test)]
mod sessions_render_tests {
    use super::*;
    use ratatui::backend::TestBackend;
    use ratatui::Terminal;

    fn sessions_with_multibyte_titles() -> Vec<SessionInfo> {
        let mk = |id: &str, title: String, date: &str| -> SessionInfo {
            serde_json::from_value(serde_json::json!({
                "id": id,
                "created_at": date,
                "title": title,
                "message_count": 3,
                "last_active": date,
            }))
            .unwrap()
        };
        vec![
            mk("s1", "\u{20ac}".repeat(60), "2026-07-17T10:00:00Z"),
            mk("s2", format!("caf\u{e9} \u{1f600} session"), "2026-07-16T09:00:00Z"),
            mk("s3", "\u{4e2d}\u{6587}\u{6807}\u{9898}".to_string(), "2026-07-15"),
        ]
    }

    #[test]
    fn sessions_dialog_multibyte_titles_never_panic() {
        let dialog = SessionBrowser::new(sessions_with_multibyte_titles(), "s1".to_string());
        for &(w, h) in &[(1u16, 1u16), (10, 3), (30, 10), (80, 24), (200, 60)] {
            let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
            term.draw(|f| {
                let area = f.area();
                dialog.draw(f, area);
            })
            .unwrap();
        }
    }
}
