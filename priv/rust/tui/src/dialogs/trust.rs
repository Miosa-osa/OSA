/// Workspace trust dialog (CC parity: TrustDialog).
///
/// "Accessing workspace" warning shown before the first tool runs in a
/// folder the user has not yet trusted, enumerating any workspace-supplied
/// executable config (hooks, MCP servers, env vars, bash allow-rules) the
/// backend `Workspace.Trust` module detected. Self-contained: event-loop
/// wiring and the backend endpoint land separately.
use crossterm::event::{KeyCode, KeyEvent};
use ratatui::{
    prelude::*,
    widgets::{Block, BorderType, Borders, Clear, Paragraph},
};

/// Clip-safe render (shared choke point with the onboarding wizard).
fn put<W: ratatui::widgets::Widget>(frame: &mut Frame, widget: W, rect: Rect) {
    crate::app::event_loop::safe_render_widget(frame, widget, rect);
}

const DIALOG_W: u16 = 66;
const MAX_RISK_LINES: usize = 6;

/// Bubble-up result of trust-dialog key handling.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrustAction {
    /// Persist trust for this folder and continue startup.
    Accept,
    /// Decline: the app must exit with code 1 without running anything.
    Exit,
}

pub struct TrustDialog {
    pub cwd: String,
    pub risks: Vec<String>,
    selected: usize, // 0 = "Yes, I trust this folder", 1 = "No, exit"
}

impl TrustDialog {
    pub fn new(cwd: String, risks: Vec<String>) -> Self {
        Self { cwd, risks, selected: 0 }
    }

    pub fn handle_key(&mut self, key: KeyEvent) -> Option<TrustAction> {
        match key.code {
            KeyCode::Up
            | KeyCode::Down
            | KeyCode::Tab
            | KeyCode::Char('k')
            | KeyCode::Char('j') => {
                self.selected = 1 - self.selected;
                None
            }
            KeyCode::Char('1') => Some(TrustAction::Accept),
            KeyCode::Char('2') => Some(TrustAction::Exit),
            KeyCode::Enter => Some(if self.selected == 0 {
                TrustAction::Accept
            } else {
                TrustAction::Exit
            }),
            // Esc can never silently trust (CC parity: Esc = exit).
            KeyCode::Esc => Some(TrustAction::Exit),
            _ => None,
        }
    }

    pub fn draw(&self, frame: &mut Frame, area: Rect) {
        let theme = crate::style::theme();

        let shown_risks = self.risks.len().min(MAX_RISK_LINES);
        let overflow = self.risks.len().saturating_sub(MAX_RISK_LINES);
        let risk_rows: u16 = if self.risks.is_empty() {
            0
        } else {
            (shown_risks + usize::from(overflow > 0) + 2) as u16
        };

        let w = DIALOG_W.min(area.width);
        let h = (12 + risk_rows).min(area.height);
        let x = area.x + area.width.saturating_sub(w) / 2;
        let y = area.y + area.height.saturating_sub(h) / 2;
        let rect = Rect::new(x, y, w, h);

        put(frame, Clear, rect);
        let block = Block::default()
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(Style::default().fg(theme.colors.warning))
            .title(Line::from(" Accessing workspace ").centered())
            .style(Style::default().bg(theme.colors.dialog_bg));
        put(frame, block, rect);

        let inner = Rect::new(
            rect.x + 2,
            rect.y + 1,
            rect.width.saturating_sub(4),
            rect.height.saturating_sub(2),
        );
        if inner.height < 4 || inner.width < 8 {
            return;
        }
        let max_w = inner.width as usize;
        let mut cy = inner.y;

        // Bold cwd
        put(
            frame,
            Paragraph::new(crate::util::ellipsize_path_middle(&self.cwd, max_w)).style(
                Style::default()
                    .fg(Color::White)
                    .add_modifier(Modifier::BOLD),
            ),
            Rect::new(inner.x, cy, inner.width, 1),
        );
        cy += 2;

        for text in [
            "Quick safety check before we start.",
            "OSA will be able to read, edit, and execute files",
            "in this folder.",
        ] {
            put(
                frame,
                Paragraph::new(text).style(Style::default().fg(theme.colors.muted)),
                Rect::new(inner.x, cy, inner.width, 1),
            );
            cy += 1;
        }
        cy += 1;

        if !self.risks.is_empty() {
            put(
                frame,
                Paragraph::new("This workspace supplies config that can run code:")
                    .style(Style::default().fg(theme.colors.warning)),
                Rect::new(inner.x, cy, inner.width, 1),
            );
            cy += 1;
            for risk in self.risks.iter().take(MAX_RISK_LINES) {
                put(
                    frame,
                    Paragraph::new(truncate_chars(&format!("  \u{2022} {}", risk), max_w))
                        .style(Style::default().fg(theme.colors.muted)),
                    Rect::new(inner.x, cy, inner.width, 1),
                );
                cy += 1;
            }
            if overflow > 0 {
                put(
                    frame,
                    Paragraph::new(format!("  \u{2026}and {} more", overflow))
                        .style(Style::default().fg(theme.colors.dim)),
                    Rect::new(inner.x, cy, inner.width, 1),
                );
                cy += 1;
            }
            cy += 1;
        }

        put(
            frame,
            Paragraph::new("Only continue if you trust the source of this code.")
                .style(Style::default().fg(theme.colors.dim)),
            Rect::new(inner.x, cy, inner.width, 1),
        );
        cy += 2;

        let yes_style = if self.selected == 0 {
            theme.button_active()
        } else {
            theme.button_inactive()
        };
        let no_style = if self.selected == 1 {
            theme.button_active()
        } else {
            theme.button_inactive()
        };
        put(
            frame,
            Paragraph::new(Line::from(vec![Span::styled(
                " 1. Yes, I trust this folder ",
                yes_style,
            )])),
            Rect::new(inner.x, cy, inner.width, 1),
        );
        cy += 1;
        put(
            frame,
            Paragraph::new(Line::from(vec![Span::styled(" 2. No, exit ", no_style)])),
            Rect::new(inner.x, cy, inner.width, 1),
        );
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
mod trust_dialog_tests {
    use super::*;
    use crossterm::event::KeyModifiers;
    use ratatui::backend::TestBackend;
    use ratatui::Terminal;

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::empty())
    }

    #[test]
    fn esc_and_enter_semantics() {
        let mut d = TrustDialog::new("/tmp/x".into(), vec![]);
        assert_eq!(d.handle_key(key(KeyCode::Esc)), Some(TrustAction::Exit));
        assert_eq!(d.handle_key(key(KeyCode::Enter)), Some(TrustAction::Accept));
        assert_eq!(d.handle_key(key(KeyCode::Down)), None);
        assert_eq!(d.handle_key(key(KeyCode::Enter)), Some(TrustAction::Exit));
        assert_eq!(d.handle_key(key(KeyCode::Char('1'))), Some(TrustAction::Accept));
        assert_eq!(d.handle_key(key(KeyCode::Char('2'))), Some(TrustAction::Exit));
    }

    #[test]
    fn draws_at_all_sizes_with_multibyte_risks_without_panic() {
        let risks: Vec<String> = (0..9)
            .map(|i| format!("risk \u{20ac}\u{4e2d} number {} with a long label........", i))
            .collect();
        let d = TrustDialog::new("/home/\u{4e2d}\u{6587}/project".into(), risks);
        for (w, h) in [(1u16, 1u16), (10, 3), (40, 12), (80, 24), (200, 60)] {
            let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
            term.draw(|f| {
                let area = f.area();
                d.draw(f, area);
            })
            .unwrap();
        }
    }
}
