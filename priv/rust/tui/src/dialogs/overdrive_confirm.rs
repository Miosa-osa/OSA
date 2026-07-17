use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::{
    prelude::*,
    widgets::{Block, BorderType, Borders, Clear, Paragraph, Wrap},
};

const DIALOG_W: u16 = 58;
const DIALOG_H: u16 = 11;

/// One-shot confirmation shown the first time OSA enters **overdrive (full auto)**
/// — the no-prompts bypass mode. Red-framed, OSA copy. Cancel is focused by
/// default so a stray Enter never enables it. Modeled on `QuitConfirm`.
///
/// `handle_key` returns:
/// * `Some(true)`  — user chose to enable overdrive
/// * `Some(false)` — user cancelled (revert to the previous mode)
/// * `None`        — keep the dialog open
pub struct OverdriveConfirm {
    /// 0 = Enable, 1 = Cancel
    selected: usize,
}

impl OverdriveConfirm {
    pub fn new() -> Self {
        Self { selected: 1 }
    }

    pub fn handle_key(&mut self, key: KeyEvent) -> Option<bool> {
        // Ignore ctrl/alt-modified keys (except plain Esc / letters handled below).
        if key.modifiers.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) {
            return None;
        }
        match key.code {
            KeyCode::Tab | KeyCode::Right => {
                self.selected = (self.selected + 1) % 2;
                None
            }
            KeyCode::BackTab | KeyCode::Left => {
                self.selected = self.selected.checked_sub(1).unwrap_or(1);
                None
            }
            KeyCode::Enter => Some(self.selected == 0),
            // Explicit yes/no quick-keys.
            KeyCode::Char('y') | KeyCode::Char('Y') => Some(true),
            KeyCode::Char('n') | KeyCode::Char('N') | KeyCode::Esc => Some(false),
            _ => None,
        }
    }

    pub fn draw(&self, frame: &mut Frame, area: Rect) {
        let theme = crate::style::theme();

        let x = area.x + area.width.saturating_sub(DIALOG_W) / 2;
        let y = area.y + area.height.saturating_sub(DIALOG_H) / 2;
        let dialog_rect = Rect::new(x, y, DIALOG_W.min(area.width), DIALOG_H.min(area.height));

        frame.render_widget(Clear, dialog_rect);

        // Red border — this is a dangerous mode.
        let block = Block::default()
            .title(Line::from(Span::styled(
                " \u{26A0} Enter overdrive (full auto)? ",
                Style::default()
                    .fg(theme.colors.error)
                    .add_modifier(Modifier::BOLD),
            )))
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(Style::default().fg(theme.colors.error))
            .style(Style::default().bg(theme.colors.dialog_bg));
        frame.render_widget(block, dialog_rect);

        let inner = Rect::new(
            dialog_rect.x + 2,
            dialog_rect.y + 1,
            dialog_rect.width.saturating_sub(4),
            dialog_rect.height.saturating_sub(2),
        );
        if inner.height < 4 {
            return;
        }

        // Body copy — OSA's own wording.
        let body = Paragraph::new(
            "Overdrive runs every tool with NO permission prompts — \
             file writes, shell, and deletes all execute automatically. \
             Only use it in a workspace you trust. You can leave it any \
             time with Shift+Tab.",
        )
        .style(Style::default().fg(theme.colors.muted))
        .wrap(Wrap { trim: true });
        frame.render_widget(
            body,
            Rect::new(inner.x, inner.y + 1, inner.width, inner.height.saturating_sub(3)),
        );

        // Button row at the bottom of the inner area.
        let btn_y = inner.y + inner.height.saturating_sub(1);
        let enable_style = if self.selected == 0 {
            theme.button_danger()
        } else {
            theme.button_inactive()
        };
        let cancel_style = if self.selected == 1 {
            theme.button_active()
        } else {
            theme.button_inactive()
        };
        let buttons = Line::from(vec![
            Span::styled("[ Enable (y) ]", enable_style),
            Span::raw("   "),
            Span::styled("[ Cancel (Esc) ]", cancel_style),
        ]);
        frame.render_widget(
            Paragraph::new(buttons).alignment(Alignment::Center),
            Rect::new(inner.x, btn_y, inner.width, 1),
        );
    }
}

impl Default for OverdriveConfirm {
    fn default() -> Self {
        Self::new()
    }
}
