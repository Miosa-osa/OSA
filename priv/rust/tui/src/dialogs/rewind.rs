// /rewind — restore code / conversation / both from a recent checkpoint.
//
// Two-step selection modal:
//   1. Pick a checkpoint (snapshots taken before each user prompt, newest first)
//   2. Pick a restore scope (code / conversation / both)
//
// Mirrors the SessionBrowser wiring: a full-viewport overlay state
// (`AppState::Rewind`) drives `handle_key` / `draw`, and a `RewindAction`
// bubbles back up to the app layer to perform the restore.
#![allow(dead_code)]

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::{
    prelude::*,
    widgets::{Block, BorderType, Borders, Clear, Paragraph},
};

use crate::client::types::{RewindCheckpoint, RewindScope};

const SCOPES: [RewindScope; 3] = [RewindScope::Both, RewindScope::Conversation, RewindScope::Code];

#[derive(Debug, Clone)]
pub enum RewindAction {
    /// Restore the given checkpoint with the chosen scope.
    Restore(String, RewindScope),
    /// Dismiss without restoring.
    Cancel,
}

#[derive(PartialEq, Eq)]
enum Mode {
    PickCheckpoint,
    PickScope,
}

pub struct RewindDialog {
    checkpoints: Vec<RewindCheckpoint>,
    cursor: usize,
    scope_cursor: usize,
    scroll: usize,
    mode: Mode,
}

impl RewindDialog {
    pub fn new(checkpoints: Vec<RewindCheckpoint>) -> Self {
        Self {
            checkpoints,
            cursor: 0,
            scope_cursor: 0,
            scroll: 0,
            mode: Mode::PickCheckpoint,
        }
    }

    pub fn is_empty(&self) -> bool {
        self.checkpoints.is_empty()
    }

    // ── Key handling ─────────────────────────────────────────────────────

    pub fn handle_key(&mut self, key: KeyEvent) -> Option<RewindAction> {
        if key.modifiers.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) {
            // Let Ctrl+C fall through to app-level quit handling.
            return None;
        }

        match self.mode {
            Mode::PickCheckpoint => self.handle_pick_checkpoint(key),
            Mode::PickScope => self.handle_pick_scope(key),
        }
    }

    fn handle_pick_checkpoint(&mut self, key: KeyEvent) -> Option<RewindAction> {
        match key.code {
            KeyCode::Esc | KeyCode::Char('q') => Some(RewindAction::Cancel),
            KeyCode::Up | KeyCode::Char('k') => {
                if self.cursor > 0 {
                    self.cursor -= 1;
                }
                None
            }
            KeyCode::Down | KeyCode::Char('j') => {
                if self.cursor + 1 < self.checkpoints.len() {
                    self.cursor += 1;
                }
                None
            }
            KeyCode::Enter => {
                if self.checkpoints.is_empty() {
                    Some(RewindAction::Cancel)
                } else {
                    self.scope_cursor = 0;
                    self.mode = Mode::PickScope;
                    None
                }
            }
            _ => None,
        }
    }

    fn handle_pick_scope(&mut self, key: KeyEvent) -> Option<RewindAction> {
        match key.code {
            KeyCode::Esc => {
                self.mode = Mode::PickCheckpoint;
                None
            }
            KeyCode::Up | KeyCode::Char('k') => {
                self.scope_cursor = self.scope_cursor.checked_sub(1).unwrap_or(SCOPES.len() - 1);
                None
            }
            KeyCode::Down | KeyCode::Char('j') => {
                self.scope_cursor = (self.scope_cursor + 1) % SCOPES.len();
                None
            }
            KeyCode::Enter => {
                let cp = self.checkpoints.get(self.cursor)?;
                let scope = SCOPES[self.scope_cursor];
                Some(RewindAction::Restore(cp.id.clone(), scope))
            }
            _ => None,
        }
    }

    // ── Drawing ──────────────────────────────────────────────────────────

    pub fn draw(&self, frame: &mut Frame, area: Rect) {
        let theme = crate::style::theme();

        let w = 72u16.min(area.width);
        let h = 20u16.min(area.height);
        let x = area.x + area.width.saturating_sub(w) / 2;
        let y = area.y + area.height.saturating_sub(h) / 2;
        let rect = Rect::new(x, y, w, h);

        frame.render_widget(Clear, rect);

        let block = Block::default()
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(Style::default().fg(theme.colors.primary))
            .style(Style::default().bg(theme.colors.dialog_bg));
        frame.render_widget(block, rect);

        let inner = Rect::new(
            rect.x + 1,
            rect.y + 1,
            rect.width.saturating_sub(2),
            rect.height.saturating_sub(2),
        );
        if inner.height < 4 {
            return;
        }

        let mut cy = inner.y;

        // Title
        frame.render_widget(
            Paragraph::new("Rewind — restore a checkpoint")
                .style(theme.dialog_title())
                .alignment(Alignment::Center),
            Rect::new(inner.x, cy, inner.width, 1),
        );
        cy += 1;

        let sep = "─".repeat(inner.width as usize);
        frame.render_widget(
            Paragraph::new(sep.as_str()).style(Style::default().fg(theme.colors.dim)),
            Rect::new(inner.x, cy, inner.width, 1),
        );
        cy += 1;

        if self.checkpoints.is_empty() {
            frame.render_widget(
                Paragraph::new("No checkpoints yet. Snapshots are taken before each prompt.")
                    .style(Style::default().fg(theme.colors.muted))
                    .alignment(Alignment::Center),
                Rect::new(inner.x, cy + 1, inner.width, 1),
            );
            self.draw_help(frame, inner, &theme);
            return;
        }

        // How many rows we can show for the checkpoint list (reserve room for
        // the scope panel + help when picking a scope).
        let footer = if self.mode == Mode::PickScope { 6 } else { 2 };
        let list_h = inner.height.saturating_sub((cy - inner.y) + footer);
        let list_h = list_h.max(1) as usize;
        // Hard clip: the selected row's extra meta line must never bleed into
        // the reserved footer (it overwrote the scope panel title before).
        let list_bottom = cy + list_h as u16;

        // Simple scroll window around the cursor.
        let start = if self.cursor >= list_h {
            self.cursor - list_h + 1
        } else {
            0
        };

        for (i, cp) in self
            .checkpoints
            .iter()
            .enumerate()
            .skip(start)
            .take(list_h)
        {
            if cy >= list_bottom {
                break;
            }
            let is_cursor = i == self.cursor && self.mode == Mode::PickCheckpoint;
            let is_selected = i == self.cursor;

            let marker = if is_cursor { "▸" } else { " " };
            let code_tag = if cp.has_code { "◆" } else { "·" };

            let label_style = if is_selected {
                Style::default()
                    .fg(theme.colors.primary)
                    .add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(theme.colors.muted)
            };

            let meta = format!(
                "{} msgs · iter {}{}",
                cp.message_count,
                cp.iteration,
                cp.created_at
                    .as_deref()
                    .map(|d| format!(" · {}", short_time(d)))
                    .unwrap_or_default()
            );

            let label = truncate(&cp.label, inner.width.saturating_sub(4) as usize);

            let line = Line::from(vec![
                Span::styled(format!("{} ", marker), label_style),
                Span::styled(format!("{} ", code_tag), Style::default().fg(theme.colors.success)),
                Span::styled(label, label_style),
            ]);
            frame.render_widget(
                Paragraph::new(line),
                Rect::new(inner.x, cy, inner.width, 1),
            );
            cy += 1;

            if is_selected && cy < list_bottom {
                frame.render_widget(
                    Paragraph::new(Line::from(Span::styled(
                        format!("    {}", meta),
                        Style::default().fg(theme.colors.dim),
                    ))),
                    Rect::new(inner.x, cy, inner.width, 1),
                );
                cy += 1;
            }
        }

        // Scope panel
        if self.mode == Mode::PickScope {
            let scope_y = inner.y + inner.height.saturating_sub(5);
            frame.render_widget(
                Paragraph::new("Restore what?").style(theme.dialog_title()),
                Rect::new(inner.x, scope_y, inner.width, 1),
            );
            for (i, scope) in SCOPES.iter().enumerate() {
                let is_cursor = i == self.scope_cursor;
                let radio = if is_cursor { "●" } else { "○" };
                let style = if is_cursor {
                    Style::default()
                        .fg(theme.colors.primary)
                        .add_modifier(Modifier::BOLD)
                } else {
                    Style::default().fg(theme.colors.muted)
                };
                frame.render_widget(
                    Paragraph::new(Line::from(vec![
                        Span::styled(format!(" {} ", radio), style),
                        Span::styled(scope.label(), style),
                    ])),
                    Rect::new(inner.x, scope_y + 1 + i as u16, inner.width, 1),
                );
            }
        }

        self.draw_help(frame, inner, &theme);
    }

    fn draw_help(&self, frame: &mut Frame, inner: Rect, theme: &crate::style::Theme) {
        let bottom_y = inner.y + inner.height.saturating_sub(1);
        let help = match self.mode {
            Mode::PickCheckpoint => Line::from(vec![
                Span::styled("↑↓", theme.dialog_help_key()),
                Span::styled(" move  ", theme.dialog_help()),
                Span::styled("Enter", theme.dialog_help_key()),
                Span::styled(" choose  ", theme.dialog_help()),
                Span::styled("Esc", theme.dialog_help_key()),
                Span::styled(" cancel", theme.dialog_help()),
            ]),
            Mode::PickScope => Line::from(vec![
                Span::styled("↑↓", theme.dialog_help_key()),
                Span::styled(" scope  ", theme.dialog_help()),
                Span::styled("Enter", theme.dialog_help_key()),
                Span::styled(" restore  ", theme.dialog_help()),
                Span::styled("Esc", theme.dialog_help_key()),
                Span::styled(" back", theme.dialog_help()),
            ]),
        };
        frame.render_widget(
            Paragraph::new(help).alignment(Alignment::Center),
            Rect::new(inner.x, bottom_y, inner.width, 1),
        );
    }
}

/// Fit into `max` DISPLAY COLUMNS on grapheme boundaries.
///
/// Delegates to the canonical fitter: a private char-count copy of this used to
/// let a CJK/emoji value over-run its reserved span and shove every column to
/// its right off the pane.
fn truncate(s: &str, max: usize) -> String {
    crate::util::fit_cols(s, max)
}

/// Trim an ISO-8601 timestamp down to `YYYY-MM-DD HH:MM` for compact display.
fn short_time(iso: &str) -> String {
    let cleaned = iso.replace('T', " ");
    match cleaned.char_indices().nth(16) {
        Some((idx, _)) => cleaned[..idx].to_string(),
        None => cleaned,
    }
}
