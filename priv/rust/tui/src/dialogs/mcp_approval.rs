/// Project-scoped MCP server approval dialog (CC parity: MCP.ProjectApproval).
///
/// Repo-committed `.mcp.json` stdio servers can execute arbitrary code, so they
/// are never started automatically. This dialog renders the backend
/// `MCP.ProjectApproval.dialog_copy/0` warning + option specs and returns the
/// operator's decision, which the app layer persists via `approve/1`,
/// `approve_all/0`, and `reject/1`. Self-contained: event-loop wiring and the
/// backend round-trip land separately (mirrors the trust dialog scaffold).
use crossterm::event::{KeyCode, KeyEvent};
use ratatui::{
    prelude::*,
    widgets::{Block, BorderType, Borders, Clear, Paragraph},
};

/// Clip-safe render (shared choke point with the trust/onboarding dialogs).
fn put<W: ratatui::widgets::Widget>(frame: &mut Frame, widget: W, rect: Rect) {
    crate::app::event_loop::safe_render_widget(frame, widget, rect);
}

const DIALOG_W: u16 = 68;
const MAX_ROWS: usize = 8;
const WARNING: &str =
    "MCP servers may execute code or access system resources. All tool calls require approval.";
const DOCS_URL: &str = "https://osa.dev/docs/mcp";

/// Bubble-up result of MCP-approval key handling. Maps 1:1 onto the backend
/// `MCP.ProjectApproval` callbacks: `ApproveAll` -> `approve_all/0`, the `approve`
/// list -> `approve/1` per name, the `reject` list -> `reject/1` per name.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum McpApprovalAction {
    /// Persist the per-server split (approve some, reject the rest).
    Approve { approve: Vec<String>, reject: Vec<String> },
    /// Enable this and all future project MCP servers.
    ApproveAll,
    /// Reject every pending project server.
    RejectAll,
}

pub struct McpApprovalDialog {
    /// Pending project-scope server names the operator has not decided about.
    servers: Vec<String>,
    /// Single-server mode: 0 = yes_all, 1 = yes, 2 = no.
    single_choice: usize,
    /// Multi-server mode: cursor row over `servers`.
    cursor: usize,
    /// Multi-server mode: per-server selection (all pre-selected, CC parity).
    checked: Vec<bool>,
}

impl McpApprovalDialog {
    pub fn new(servers: Vec<String>) -> Self {
        let checked = vec![true; servers.len()];
        Self { servers, single_choice: 0, cursor: 0, checked }
    }

    /// True when several servers are pending (multiselect variant).
    fn is_multi(&self) -> bool {
        self.servers.len() > 1
    }

    pub fn handle_key(&mut self, key: KeyEvent) -> Option<McpApprovalAction> {
        if self.servers.is_empty() {
            // Nothing to decide -- Esc/Enter both dismiss as reject-none.
            return match key.code {
                KeyCode::Esc | KeyCode::Enter => Some(McpApprovalAction::RejectAll),
                _ => None,
            };
        }
        if self.is_multi() {
            self.handle_multi(key)
        } else {
            self.handle_single(key)
        }
    }

    fn handle_single(&mut self, key: KeyEvent) -> Option<McpApprovalAction> {
        let name = self.servers[0].clone();
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => {
                self.single_choice = (self.single_choice + 2) % 3;
                None
            }
            KeyCode::Down | KeyCode::Tab | KeyCode::Char('j') => {
                self.single_choice = (self.single_choice + 1) % 3;
                None
            }
            KeyCode::Char('1') => Some(McpApprovalAction::ApproveAll),
            KeyCode::Char('2') => {
                Some(McpApprovalAction::Approve { approve: vec![name], reject: vec![] })
            }
            KeyCode::Char('3') => Some(McpApprovalAction::RejectAll),
            KeyCode::Enter => Some(match self.single_choice {
                0 => McpApprovalAction::ApproveAll,
                1 => McpApprovalAction::Approve { approve: vec![name], reject: vec![] },
                _ => McpApprovalAction::RejectAll,
            }),
            // Esc can never silently trust (CC parity: Esc = reject all).
            KeyCode::Esc => Some(McpApprovalAction::RejectAll),
            _ => None,
        }
    }

    fn handle_multi(&mut self, key: KeyEvent) -> Option<McpApprovalAction> {
        let last = self.servers.len().saturating_sub(1);
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => {
                self.cursor = self.cursor.saturating_sub(1);
                None
            }
            KeyCode::Down | KeyCode::Char('j') | KeyCode::Tab => {
                self.cursor = (self.cursor + 1).min(last);
                None
            }
            KeyCode::Char(' ') => {
                if let Some(c) = self.checked.get_mut(self.cursor) {
                    *c = !*c;
                }
                None
            }
            KeyCode::Enter => {
                let mut approve = Vec::new();
                let mut reject = Vec::new();
                for (i, name) in self.servers.iter().enumerate() {
                    if *self.checked.get(i).unwrap_or(&false) {
                        approve.push(name.clone());
                    } else {
                        reject.push(name.clone());
                    }
                }
                Some(if approve.is_empty() {
                    McpApprovalAction::RejectAll
                } else {
                    McpApprovalAction::Approve { approve, reject }
                })
            }
            KeyCode::Esc => Some(McpApprovalAction::RejectAll),
            _ => None,
        }
    }

    pub fn draw(&self, frame: &mut Frame, area: Rect) {
        let theme = crate::style::theme();

        let body_rows = if self.is_multi() {
            self.servers.len().min(MAX_ROWS)
        } else {
            3
        };
        let overflow = if self.is_multi() {
            self.servers.len().saturating_sub(MAX_ROWS)
        } else {
            0
        };
        // warning(2) + docs(1) + blank(1) + body + optional overflow + blank(1) + hint(1)
        let content_h = 6 + body_rows + usize::from(overflow > 0);

        let w = DIALOG_W.min(area.width);
        let h = (content_h as u16 + 2).min(area.height);
        let x = area.x + area.width.saturating_sub(w) / 2;
        let y = area.y + area.height.saturating_sub(h) / 2;
        let rect = Rect::new(x, y, w, h);

        put(frame, Clear, rect);
        let title = if self.is_multi() {
            " MCP servers "
        } else {
            " MCP server "
        };
        let block = Block::default()
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(Style::default().fg(theme.colors.warning))
            .title(Line::from(title).centered())
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

        // Warning (wrapped to two lines within the dialog width).
        for text in wrap_two(WARNING, max_w) {
            put(
                frame,
                Paragraph::new(text).style(Style::default().fg(theme.colors.warning)),
                Rect::new(inner.x, cy, inner.width, 1),
            );
            cy += 1;
        }
        put(
            frame,
            Paragraph::new(truncate_chars(&format!("Docs: {}", DOCS_URL), max_w))
                .style(Style::default().fg(theme.colors.dim)),
            Rect::new(inner.x, cy, inner.width, 1),
        );
        cy += 2;

        if self.is_multi() {
            for (i, name) in self.servers.iter().take(MAX_ROWS).enumerate() {
                let mark = if *self.checked.get(i).unwrap_or(&false) {
                    "[x]"
                } else {
                    "[ ]"
                };
                let label = truncate_chars(&format!(" {} {}", mark, name), max_w);
                let style = if i == self.cursor {
                    theme.button_active()
                } else {
                    theme.button_inactive()
                };
                put(
                    frame,
                    Paragraph::new(Line::from(Span::styled(label, style))),
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
            put(
                frame,
                Paragraph::new(
                    "Space toggle \u{00b7} Enter confirm \u{00b7} Esc reject all",
                )
                .style(Style::default().fg(theme.colors.muted)),
                Rect::new(inner.x, cy, inner.width, 1),
            );
        } else {
            let name = self.servers.first().cloned().unwrap_or_default();
            let opts = [
                format!(" 1. Use this and all future MCP servers ({})", name),
                format!(" 2. Use this MCP server ({})", name),
                " 3. Continue without using it".to_string(),
            ];
            for (i, opt) in opts.iter().enumerate() {
                let style = if i == self.single_choice {
                    theme.button_active()
                } else {
                    theme.button_inactive()
                };
                put(
                    frame,
                    Paragraph::new(Line::from(Span::styled(
                        truncate_chars(opt, max_w),
                        style,
                    ))),
                    Rect::new(inner.x, cy, inner.width, 1),
                );
                cy += 1;
            }
            cy += 1;
            put(
                frame,
                Paragraph::new("\u{2191}/\u{2193} choose \u{00b7} Enter confirm \u{00b7} Esc reject")
                    .style(Style::default().fg(theme.colors.muted)),
                Rect::new(inner.x, cy, inner.width, 1),
            );
        }
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

/// Split `s` into at most two width-clamped lines on a word boundary.
fn wrap_two(s: &str, max: usize) -> Vec<String> {
    if crate::util::cols(&s) <= max || max == 0 {
        return vec![s.to_string()];
    }
    let mut split = max;
    // Prefer the last space at/under the width.
    if let Some(pos) = s[..s.char_indices().nth(max).map(|(i, _)| i).unwrap_or(s.len())]
        .rfind(' ')
    {
        split = s[..pos].chars().count();
    }
    let first: String = s.chars().take(split).collect();
    let rest: String = s.chars().skip(split).collect();
    vec![first.trim_end().to_string(), truncate_chars(rest.trim_start(), max)]
}

#[cfg(test)]
mod mcp_approval_tests {
    use super::*;
    use crossterm::event::{KeyEvent, KeyModifiers};
    use ratatui::backend::TestBackend;
    use ratatui::Terminal;

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::empty())
    }

    #[test]
    fn single_server_semantics() {
        let mut d = McpApprovalDialog::new(vec!["fs".into()]);
        // Default choice 0 (yes_all).
        assert_eq!(d.handle_key(key(KeyCode::Enter)), Some(McpApprovalAction::ApproveAll));
        assert_eq!(d.handle_key(key(KeyCode::Char('1'))), Some(McpApprovalAction::ApproveAll));
        assert_eq!(
            d.handle_key(key(KeyCode::Char('2'))),
            Some(McpApprovalAction::Approve { approve: vec!["fs".into()], reject: vec![] })
        );
        assert_eq!(d.handle_key(key(KeyCode::Char('3'))), Some(McpApprovalAction::RejectAll));
        assert_eq!(d.handle_key(key(KeyCode::Esc)), Some(McpApprovalAction::RejectAll));
        // Down moves to option 1 (yes).
        assert_eq!(d.handle_key(key(KeyCode::Down)), None);
        assert_eq!(
            d.handle_key(key(KeyCode::Enter)),
            Some(McpApprovalAction::Approve { approve: vec!["fs".into()], reject: vec![] })
        );
    }

    #[test]
    fn multi_server_toggle_and_confirm() {
        let mut d = McpApprovalDialog::new(vec!["a".into(), "b".into(), "c".into()]);
        // All pre-selected -> Enter approves everything.
        match d.handle_key(key(KeyCode::Enter)) {
            Some(McpApprovalAction::Approve { approve, reject }) => {
                assert_eq!(approve, vec!["a", "b", "c"]);
                assert!(reject.is_empty());
            }
            other => panic!("unexpected {:?}", other),
        }
        // Move to row 1 and untick it.
        assert_eq!(d.handle_key(key(KeyCode::Down)), None);
        assert_eq!(d.handle_key(key(KeyCode::Char(' '))), None);
        match d.handle_key(key(KeyCode::Enter)) {
            Some(McpApprovalAction::Approve { approve, reject }) => {
                assert_eq!(approve, vec!["a", "c"]);
                assert_eq!(reject, vec!["b"]);
            }
            other => panic!("unexpected {:?}", other),
        }
        // Esc rejects all regardless of ticks.
        assert_eq!(d.handle_key(key(KeyCode::Esc)), Some(McpApprovalAction::RejectAll));
    }

    #[test]
    fn multi_all_unticked_is_reject_all() {
        let mut d = McpApprovalDialog::new(vec!["a".into(), "b".into()]);
        d.handle_key(key(KeyCode::Char(' '))); // untick a
        d.handle_key(key(KeyCode::Down));
        d.handle_key(key(KeyCode::Char(' '))); // untick b
        assert_eq!(d.handle_key(key(KeyCode::Enter)), Some(McpApprovalAction::RejectAll));
    }

    #[test]
    fn draws_at_all_sizes_with_multibyte_names_without_panic() {
        let servers: Vec<String> = (0..11)
            .map(|i| format!("server-\u{20ac}\u{4e2d}-{}-with-a-long-name.........", i))
            .collect();
        for set in [vec!["solo-\u{4e2d}".to_string()], servers] {
            let d = McpApprovalDialog::new(set);
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
}
