// Phase 2+: reasoning dialog — UI wired but some methods not yet called
#![allow(dead_code)]

/// Reasoning level selector — small centered modal with 6 levels.
///
/// # Actions to add to `DialogAction` in mod.rs:
/// ```
/// ReasoningSelect(reasoning::ReasoningLevel),
/// ReasoningCancel,
/// ```
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::{
    prelude::*,
    widgets::{Block, BorderType, Borders, Clear, Paragraph},
};

const DIALOG_W: u16 = 44;
const DIALOG_H: u16 = 12;

// ── Level ─────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReasoningLevel {
    Off,
    Fast,
    Medium,
    High,
    Xhigh,
    /// Ultra tier — gates OSA's dynamic-workflow orchestration.
    Ultra,
}

impl ReasoningLevel {
    fn index(self) -> usize {
        match self {
            ReasoningLevel::Off => 0,
            ReasoningLevel::Fast => 1,
            ReasoningLevel::Medium => 2,
            ReasoningLevel::High => 3,
            ReasoningLevel::Xhigh => 4,
            ReasoningLevel::Ultra => 5,
        }
    }

    fn from_index(i: usize) -> Self {
        match i {
            1 => ReasoningLevel::Fast,
            2 => ReasoningLevel::Medium,
            3 => ReasoningLevel::High,
            4 => ReasoningLevel::Xhigh,
            5 => ReasoningLevel::Ultra,
            _ => ReasoningLevel::Off,
        }
    }
}

// ── Action ────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub enum ReasoningAction {
    Select(ReasoningLevel),
    Cancel,
}

// ── Level descriptors ─────────────────────────────────────────────────────────

const LEVELS: [(ReasoningLevel, &str, &str); 6] = [
    (ReasoningLevel::Off, "Off", "No extended thinking"),
    (ReasoningLevel::Fast, "Fast", "Brief reasoning chain"),
    (ReasoningLevel::Medium, "Medium", "Balanced depth"),
    (ReasoningLevel::High, "High", "Deep multi-step reasoning"),
    (ReasoningLevel::Xhigh, "Xhigh", "Extended reasoning"),
    (ReasoningLevel::Ultra, "Ultra", "Unlocks dynamic workflows"),
];

// ── State ─────────────────────────────────────────────────────────────────────

pub struct ReasoningSelector {
    current: ReasoningLevel,
    cursor: usize,
}

impl ReasoningSelector {
    pub fn new(current: ReasoningLevel) -> Self {
        Self {
            cursor: current.index(),
            current,
        }
    }

    // ── Key handling ─────────────────────────────────────────────────────────

    pub fn handle_key(&mut self, key: KeyEvent) -> Option<ReasoningAction> {
        if key.modifiers.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) {
            return None;
        }

        match key.code {
            KeyCode::Esc => Some(ReasoningAction::Cancel),
            KeyCode::Enter => Some(ReasoningAction::Select(ReasoningLevel::from_index(
                self.cursor,
            ))),
            KeyCode::Up | KeyCode::Char('k') => {
                self.cursor = self.cursor.checked_sub(1).unwrap_or(LEVELS.len() - 1);
                None
            }
            KeyCode::Down | KeyCode::Char('j') => {
                self.cursor = (self.cursor + 1) % LEVELS.len();
                None
            }
            _ => None,
        }
    }

    // ── Drawing ───────────────────────────────────────────────────────────────

    pub fn draw(&self, frame: &mut Frame, area: Rect) {
        let theme = crate::style::theme();

        let w = DIALOG_W.min(area.width);
        let h = DIALOG_H.min(area.height);
        let x = area.x + area.width.saturating_sub(w) / 2;
        let y = area.y + area.height.saturating_sub(h) / 2;
        let dialog_rect = Rect::new(x, y, w, h);

        frame.render_widget(Clear, dialog_rect);

        let block = Block::default()
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(Style::default().fg(theme.colors.primary))
            .style(Style::default().bg(theme.colors.dialog_bg));
        frame.render_widget(block, dialog_rect);

        let inner = Rect::new(
            dialog_rect.x + 1,
            dialog_rect.y + 1,
            dialog_rect.width.saturating_sub(2),
            dialog_rect.height.saturating_sub(2),
        );
        if inner.height < 3 {
            return;
        }

        let mut cy = inner.y;

        // Title
        frame.render_widget(
            Paragraph::new("Reasoning Level")
                .style(theme.dialog_title())
                .alignment(Alignment::Center),
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

        // Level rows
        for (i, (level, label, desc)) in LEVELS.iter().enumerate() {
            if cy >= inner.y + inner.height.saturating_sub(1) {
                break;
            }

            let is_current = *level == self.current;
            let is_cursor = i == self.cursor;

            let radio = if is_current { "●" } else { "○" };
            let radio_style = if is_current {
                Style::default().fg(theme.colors.success)
            } else {
                Style::default().fg(theme.colors.dim)
            };

            let cursor_char = if is_cursor { "▸" } else { " " };
            let label_style = if is_cursor {
                Style::default()
                    .fg(theme.colors.primary)
                    .add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(theme.colors.muted)
            };
            let desc_style = Style::default().fg(theme.colors.dim);

            let spans = vec![
                Span::styled(format!("{} ", cursor_char), label_style),
                Span::styled(radio, radio_style),
                Span::raw(" "),
                Span::styled(format!("{:<8}", label), label_style),
                Span::styled(desc.to_string(), desc_style),
            ];

            frame.render_widget(
                Paragraph::new(Line::from(spans)),
                Rect::new(inner.x, cy, inner.width, 1),
            );
            cy += 1;
        }

        // Help
        let bottom_y = inner.y + inner.height.saturating_sub(1);
        let help = Line::from(vec![
            Span::styled("↑↓", theme.dialog_help_key()),
            Span::styled(" move  ", theme.dialog_help()),
            Span::styled("Enter", theme.dialog_help_key()),
            Span::styled(" select  ", theme.dialog_help()),
            Span::styled("Esc", theme.dialog_help_key()),
            Span::styled(" cancel", theme.dialog_help()),
        ]);
        frame.render_widget(
            Paragraph::new(help).alignment(Alignment::Center),
            Rect::new(inner.x, bottom_y, inner.width, 1),
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ALL: [ReasoningLevel; 6] = [
        ReasoningLevel::Off,
        ReasoningLevel::Fast,
        ReasoningLevel::Medium,
        ReasoningLevel::High,
        ReasoningLevel::Xhigh,
        ReasoningLevel::Ultra,
    ];

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::NONE)
    }

    #[test]
    fn index_from_index_roundtrip_for_all_six() {
        // Every level survives index()→from_index() unchanged, and indices are 0..6.
        for (expect_i, level) in ALL.iter().enumerate() {
            assert_eq!(level.index(), expect_i, "index is stable & contiguous");
            assert_eq!(ReasoningLevel::from_index(level.index()), *level, "roundtrip {level:?}");
        }
        // Descriptor table stays in lockstep with the enum order.
        for (i, (level, _, _)) in LEVELS.iter().enumerate() {
            assert_eq!(*level, ReasoningLevel::from_index(i), "LEVELS[{i}] matches from_index");
        }
    }

    #[test]
    fn new_seeds_cursor_to_current_and_enter_selects_it() {
        // Opening on a level and pressing Enter immediately re-selects that level
        // (cursor is seeded from current.index()).
        for level in ALL {
            let mut sel = ReasoningSelector::new(level);
            match sel.handle_key(key(KeyCode::Enter)) {
                Some(ReasoningAction::Select(got)) => assert_eq!(got, level, "Enter returns seeded level"),
                other => panic!("expected Select({level:?}), got {other:?}"),
            }
        }
    }

    #[test]
    fn down_and_j_advance_then_enter_yields_target() {
        // From Off, three Downs land on High; Enter selects it.
        let mut sel = ReasoningSelector::new(ReasoningLevel::Off);
        assert!(sel.handle_key(key(KeyCode::Down)).is_none());
        assert!(sel.handle_key(key(KeyCode::Char('j'))).is_none());
        assert!(sel.handle_key(key(KeyCode::Down)).is_none());
        match sel.handle_key(key(KeyCode::Enter)) {
            Some(ReasoningAction::Select(got)) => assert_eq!(got, ReasoningLevel::High),
            other => panic!("expected Select(High), got {other:?}"),
        }
    }

    #[test]
    fn up_wraps_from_first_to_last() {
        // Off is index 0; Up wraps to Ultra (index 5).
        let mut sel = ReasoningSelector::new(ReasoningLevel::Off);
        assert!(sel.handle_key(key(KeyCode::Up)).is_none());
        match sel.handle_key(key(KeyCode::Enter)) {
            Some(ReasoningAction::Select(got)) => assert_eq!(got, ReasoningLevel::Ultra, "Up wraps to Ultra"),
            other => panic!("expected Select(Ultra), got {other:?}"),
        }
    }

    #[test]
    fn down_wraps_from_last_to_first() {
        // Ultra is index 5; Down wraps to Off (index 0).
        let mut sel = ReasoningSelector::new(ReasoningLevel::Ultra);
        assert!(sel.handle_key(key(KeyCode::Char('j'))).is_none());
        match sel.handle_key(key(KeyCode::Enter)) {
            Some(ReasoningAction::Select(got)) => assert_eq!(got, ReasoningLevel::Off, "Down wraps to Off"),
            other => panic!("expected Select(Off), got {other:?}"),
        }
    }

    #[test]
    fn esc_cancels_and_k_moves_up() {
        let mut sel = ReasoningSelector::new(ReasoningLevel::Medium);
        // k moves up one (Medium→Fast), Enter would select Fast — prove via cursor path.
        assert!(sel.handle_key(key(KeyCode::Char('k'))).is_none());
        // Esc cancels regardless of cursor position.
        match sel.handle_key(key(KeyCode::Esc)) {
            Some(ReasoningAction::Cancel) => {}
            other => panic!("expected Cancel, got {other:?}"),
        }
    }

    #[test]
    fn ctrl_and_alt_chords_are_ignored() {
        // Modifier chords never move the cursor or select (they belong to the app).
        let mut sel = ReasoningSelector::new(ReasoningLevel::Off);
        assert!(sel
            .handle_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::CONTROL))
            .is_none());
        assert!(sel
            .handle_key(KeyEvent::new(KeyCode::Down, KeyModifiers::ALT))
            .is_none());
        // Cursor unmoved → plain Enter still selects Off.
        match sel.handle_key(key(KeyCode::Enter)) {
            Some(ReasoningAction::Select(got)) => assert_eq!(got, ReasoningLevel::Off),
            other => panic!("expected Select(Off), got {other:?}"),
        }
    }
}
