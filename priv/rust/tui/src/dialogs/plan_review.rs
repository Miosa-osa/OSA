use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::{
    prelude::*,
    widgets::{Block, BorderType, Borders, Paragraph, Wrap},
};

use super::DialogAction;

/// Inline plan review panel rendered below the chat area.
///
/// Layout:
/// ```text
/// ╭── Plan Review ──────────────────────────────────────────╮
/// │ <plan text, scrollable>                                 │
/// │                                                         │
/// │  ▸ Approve   ○ Reject   ○ Edit                         │
/// ╰─────────────────────────────────────────────────────────╯
/// ```
///
/// Keys:
///   ← / →  — cycle option
///   Enter   — confirm selected option
///   Esc     — reject (safe default)
///   j / ↓   — scroll plan down
///   k / ↑   — scroll plan up
pub struct PlanReview {
    plan: String,
    /// 0 = Approve, 1 = Reject, 2 = Edit
    selected: usize,
    scroll: u16,
}

impl PlanReview {
    pub fn new() -> Self {
        Self {
            plan: String::new(),
            selected: 0,
            scroll: 0,
        }
    }

    /// The current plan text (used to seed the input box for the Edit flow).
    pub fn plan_text(&self) -> &str {
        &self.plan
    }

    /// Replace the displayed plan and reset scroll/selection.
    pub fn set_plan(&mut self, plan: String) {
        self.plan = plan;
        self.scroll = 0;
        self.selected = 0;
    }

    /// Handle a key event.  Returns `Some(action)` when the panel should close.
    pub fn handle_key(&mut self, key: KeyEvent) -> Option<DialogAction> {
        if key.modifiers.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) {
            return None;
        }

        match key.code {
            // Option navigation.
            KeyCode::Left => {
                self.selected = self.selected.checked_sub(1).unwrap_or(2);
                None
            }
            KeyCode::Right => {
                self.selected = (self.selected + 1) % 3;
                None
            }
            // Scroll plan body.
            KeyCode::Up | KeyCode::Char('k') => {
                self.scroll = self.scroll.saturating_sub(1);
                None
            }
            KeyCode::Down | KeyCode::Char('j') => {
                self.scroll = self.scroll.saturating_add(1);
                None
            }
            KeyCode::PageUp => {
                self.scroll = self.scroll.saturating_sub(10);
                None
            }
            KeyCode::PageDown => {
                self.scroll = self.scroll.saturating_add(10);
                None
            }
            // Confirm.
            KeyCode::Enter => match self.selected {
                0 => Some(DialogAction::PlanApprove),
                1 => Some(DialogAction::PlanReject),
                2 => Some(DialogAction::PlanEdit),
                _ => None,
            },
            // Esc = reject (safe default).
            KeyCode::Esc => Some(DialogAction::PlanReject),
            _ => None,
        }
    }

    /// Draw the panel into `area` (full-width inline below the chat).
    pub fn draw(&self, frame: &mut Frame, area: Rect) {
        if area.height < 4 {
            return;
        }

        let theme = crate::style::theme();

        // Outer block.
        let block = Block::default()
            .title(Span::styled(" Plan Review ", theme.dialog_title()))
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(Style::default().fg(theme.colors.primary))
            .style(Style::default().bg(theme.colors.dialog_bg));
        frame.render_widget(block, area);

        let inner = Rect::new(
            area.x + 1,
            area.y + 1,
            area.width.saturating_sub(2),
            area.height.saturating_sub(2),
        );

        if inner.height < 2 {
            return;
        }

        // Reserve 1 line at the bottom for the option selector.
        let body_height = inner.height.saturating_sub(2); // -1 options, -1 gap

        // Plan text body (scrollable).
        if body_height > 0 {
            let plan_para = Paragraph::new(self.plan.as_str())
                .style(Style::default().fg(theme.colors.muted))
                .wrap(Wrap { trim: false })
                .scroll((self.scroll, 0));
            frame.render_widget(
                plan_para,
                Rect::new(inner.x, inner.y, inner.width, body_height),
            );
        }

        // Option selector row.
        let opts_y = inner.y + inner.height.saturating_sub(1);

        let opts = [("Approve", 0usize), ("Reject", 1), ("Edit", 2)];
        let mut spans: Vec<Span> = Vec::new();
        spans.push(Span::raw("  "));

        for (label, idx) in &opts {
            let is_selected = self.selected == *idx;
            let glyph_style = if is_selected {
                theme.plan_selected()
            } else {
                theme.plan_unselected()
            };
            let label_style = if is_selected {
                theme.plan_selected()
            } else {
                theme.plan_unselected()
            };

            let glyph = if is_selected { "▸ " } else { "○ " };
            spans.push(Span::styled(glyph, glyph_style));
            spans.push(Span::styled(label.to_string(), label_style));
            spans.push(Span::raw("   "));
        }

        // Append key hint.
        spans.push(Span::styled(
            "← → navigate  Enter confirm  Esc reject",
            Style::default().fg(theme.colors.dim),
        ));

        frame.render_widget(
            Paragraph::new(Line::from(spans)),
            Rect::new(inner.x, opts_y, inner.width, 1),
        );
    }
}

impl Default for PlanReview {
    fn default() -> Self {
        Self::new()
    }
}
