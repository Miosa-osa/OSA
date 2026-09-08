use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::{
    prelude::*,
    widgets::{Block, BorderType, Borders, Clear, Paragraph},
};

use super::DialogAction;

const DIALOG_W: u16 = 42;
const DIALOG_H: u16 = 7;

/// Two-button quit confirmation modal.
///
/// Buttons: `[ Quit (q) ]`  `[ Cancel (Esc) ]` — Cancel is focused by default.
/// Layout:
///
/// ```text
/// ╭──────────────────────────────────────╮
/// │           Quit OSA Agent?            │
/// │                                      │
/// │    Are you sure you want to quit?    │
/// │                                      │
/// │   [ Quit (q) ]   [ Cancel (Esc) ]   │
/// ╰──────────────────────────────────────╯
/// ```
pub struct QuitConfirm {
    /// 0 = Quit, 1 = Cancel
    selected: usize,
}

impl QuitConfirm {
    /// Create a new dialog with Cancel pre-selected (safe default).
    pub fn new() -> Self {
        Self { selected: 1 }
    }

    /// Reset focus to Cancel — call this every time the dialog is re-opened.
    pub fn reset(&mut self) {
        self.selected = 1;
    }

    /// Handle a key event. Returns `Some(action)` when the dialog should close.
    pub fn handle_key(&mut self, key: KeyEvent) -> Option<DialogAction> {
        // Ctrl+C in the quit dialog = confirm quit (double Ctrl+C pattern)
        if key.code == KeyCode::Char('c') && key.modifiers.contains(KeyModifiers::CONTROL) {
            return Some(DialogAction::QuitConfirmed);
        }

        // Ignore other ctrl/alt modified keys
        if key
            .modifiers
            .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT)
        {
            return None;
        }

        match key.code {
            // Cycle focus forward
            KeyCode::Tab | KeyCode::Right => {
                self.selected = (self.selected + 1) % 2;
                None
            }
            // Cycle focus backward
            KeyCode::BackTab | KeyCode::Left => {
                self.selected = self.selected.checked_sub(1).unwrap_or(1);
                None
            }
            // Confirm the currently focused button
            KeyCode::Enter => {
                if self.selected == 0 {
                    Some(DialogAction::QuitConfirmed)
                } else {
                    Some(DialogAction::Dismissed)
                }
            }
            // 'q' always triggers quit regardless of focus
            KeyCode::Char('q') | KeyCode::Char('Q') => Some(DialogAction::QuitConfirmed),
            // Escape always cancels
            KeyCode::Esc => Some(DialogAction::Dismissed),
            _ => None,
        }
    }

    /// Draw the centered modal over `area`.
    pub fn draw(&self, frame: &mut Frame, area: Rect) {
        let theme = crate::style::theme();

        // Center the dialog box.
        let x = area.x + area.width.saturating_sub(DIALOG_W) / 2;
        let y = area.y + area.height.saturating_sub(DIALOG_H) / 2;
        let dialog_rect = Rect::new(x, y, DIALOG_W.min(area.width), DIALOG_H.min(area.height));

        // Clear the background area first so we get a clean modal.
        frame.render_widget(Clear, dialog_rect);

        // Outer border.
        let border_style = Style::default().fg(theme.colors.warning);
        let block = Block::default()
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(border_style)
            .style(Style::default().bg(theme.colors.dialog_bg));
        frame.render_widget(block, dialog_rect);

        // Inner area (inside the border).
        let inner = Rect::new(
            dialog_rect.x + 1,
            dialog_rect.y + 1,
            dialog_rect.width.saturating_sub(2),
            dialog_rect.height.saturating_sub(2),
        );

        if inner.height < 3 {
            return;
        }

        // Title line.
        let title = Paragraph::new("Quit OSA Agent?")
            .style(theme.banner_title())
            .alignment(Alignment::Center);
        frame.render_widget(title, Rect::new(inner.x, inner.y, inner.width, 1));

        // Body text (one line below title).
        let body_y = inner.y + 2;
        if body_y < inner.y + inner.height {
            let body = Paragraph::new("Are you sure you want to quit?")
                .style(Style::default().fg(theme.colors.muted))
                .alignment(Alignment::Center);
            frame.render_widget(body, Rect::new(inner.x, body_y, inner.width, 1));
        }

        // Button row at the bottom of the inner area.
        let btn_y = inner.y + inner.height.saturating_sub(1);
        if btn_y >= inner.y + inner.height {
            return;
        }

        let quit_style = if self.selected == 0 {
            theme.button_active()
        } else {
            theme.button_inactive()
        };
        let cancel_style = if self.selected == 1 {
            theme.button_active()
        } else {
            theme.button_inactive()
        };

        let buttons = Line::from(vec![
            Span::raw("  "),
            Span::styled("[ Quit (q) ]", quit_style),
            Span::raw("   "),
            Span::styled("[ Cancel (Esc) ]", cancel_style),
            Span::raw("  "),
        ]);

        let btn_para = Paragraph::new(buttons).alignment(Alignment::Center);
        frame.render_widget(btn_para, Rect::new(inner.x, btn_y, inner.width, 1));
    }
}

impl Default for QuitConfirm {
    fn default() -> Self {
        Self::new()
    }
}
