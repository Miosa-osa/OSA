// Enriched permission dialog: diff viewport (set_diff, wired from the
// permission_required event) plus warning/reason metadata lines.
#![allow(dead_code)]

use std::cell::Cell;

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::{
    prelude::*,
    widgets::{Block, BorderType, Borders, Clear, Paragraph, Wrap},
};

use super::DialogAction;

const MIN_W: u16 = 50;
const MAX_W: u16 = 90;
const MIN_H: u16 = 10;

/// Tool permission approval dialog.
///
/// Layout:
/// ```text
/// ╭── Permission Request ──────────────────────────────╮
/// │  Tool:  bash                                        │
/// │  Args:  echo "hello"                               │
/// │  ─────────────────────────────────────             │
/// │  <diff viewport / raw args, scrollable>            │
/// │                                                     │
/// │  [ Allow (y) ] [ Session (s) ] [ Always (a) ] [ Deny (n) ]│
/// │  j/k scroll · Tab cycle · c clarify · Enter confirm │
/// ╰─────────────────────────────────────────────────────╯
/// ```
///
/// Pressing `c` swaps the button row for a free-text field so the user can
/// steer the agent with a short clarification instead of a binary decision.
pub struct Permissions {
    pub tool_name: String,
    pub tool_args: String,
    /// Opaque identifier echoed back to the backend when the user responds.
    request_id: String,
    pub diff_old: Option<String>,
    pub diff_new: Option<String>,
    /// Destructive-command warning from the backend (informational).
    pub warning: Option<String>,
    /// Why the prompt fired (ask rule, safety path, out-of-scope path).
    pub reason: Option<String>,
    /// 0 = Allow, 1 = Allow Session, 2 = Allow Always, 3 = Deny
    pub selected: usize,
    pub scroll: u16,
    /// When `true` the dialog is capturing a free-text clarification instead of
    /// showing the allow/deny buttons.
    clarify_mode: bool,
    /// Buffer holding the in-progress clarification text.
    clarify_input: String,
    /// Measured on each draw call via `Cell` so `handle_key` can clamp page
    /// scrolls without requiring a mutable receiver on `draw`.
    viewport_height: Cell<u16>,
}

/// Number of allow/deny buttons in the row.
const BTN_COUNT: usize = 4;
/// Index of the destructive "Deny" button (danger styling).
const DENY_IDX: usize = 3;

impl Permissions {
    pub fn new() -> Self {
        Self {
            tool_name: String::new(),
            tool_args: String::new(),
            request_id: String::new(),
            diff_old: None,
            diff_new: None,
            warning: None,
            reason: None,
            selected: 0,
            scroll: 0,
            clarify_mode: false,
            clarify_input: String::new(),
            viewport_height: Cell::new(0),
        }
    }

    /// Set the tool being requested and the backend-assigned request identifier.
    pub fn set_tool(&mut self, name: String, args: String, request_id: String) {
        self.tool_name = name;
        self.tool_args = args;
        self.request_id = request_id;
        self.diff_old = None;
        self.diff_new = None;
        self.warning = None;
        self.reason = None;
        self.scroll = 0;
        self.selected = 0;
        self.clarify_mode = false;
        self.clarify_input.clear();
    }

    /// Returns the opaque request identifier assigned by the backend.
    pub fn request_id(&self) -> &str {
        &self.request_id
    }

    /// Attach a diff for display in the viewport.
    pub fn set_diff(&mut self, old: String, new: String) {
        self.diff_old = Some(old);
        self.diff_new = Some(new);
        self.scroll = 0;
    }

    /// Attach the enriched metadata (destructive warning + prompt reason).
    pub fn set_meta(&mut self, warning: Option<String>, reason: Option<String>) {
        self.warning = warning;
        self.reason = reason;
    }

    /// Handle a key event.  Returns `Some(action)` when the dialog should close.
    pub fn handle_key(&mut self, key: KeyEvent) -> Option<DialogAction> {
        if key.modifiers.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) {
            return None;
        }

        // ── Clarify (free-text) capture mode ─────────────────────────────────
        // While active, all printable keys feed the buffer so the user can type
        // an instruction; Enter steers it to the agent, Esc returns to buttons.
        if self.clarify_mode {
            match key.code {
                KeyCode::Esc => {
                    self.clarify_mode = false;
                    self.clarify_input.clear();
                    None
                }
                KeyCode::Enter => {
                    let text = self.clarify_input.trim().to_string();
                    if text.is_empty() {
                        None
                    } else {
                        Some(DialogAction::PermissionClarify(text))
                    }
                }
                KeyCode::Backspace => {
                    self.clarify_input.pop();
                    None
                }
                KeyCode::Char(c) => {
                    self.clarify_input.push(c);
                    None
                }
                _ => None,
            }
        } else {
            match key.code {
                // Quick-keys for each button.
                KeyCode::Char('y') | KeyCode::Char('Y') => Some(DialogAction::PermissionAllow),
                KeyCode::Char('s') | KeyCode::Char('S') => {
                    Some(DialogAction::PermissionAllowSession)
                }
                KeyCode::Char('a') | KeyCode::Char('A') => {
                    Some(DialogAction::PermissionAllowAlways)
                }
                KeyCode::Char('n') | KeyCode::Char('N') | KeyCode::Esc => {
                    Some(DialogAction::PermissionDeny)
                }

                // Enter free-text clarify mode.
                KeyCode::Char('c') | KeyCode::Char('C') => {
                    self.clarify_mode = true;
                    self.clarify_input.clear();
                    None
                }

                // Viewport scrolling.
                KeyCode::Char('j') | KeyCode::Down => {
                    self.scroll = self.scroll.saturating_add(1);
                    None
                }
                KeyCode::Char('k') | KeyCode::Up => {
                    self.scroll = self.scroll.saturating_sub(1);
                    None
                }
                KeyCode::PageDown => {
                    let vh = self.viewport_height.get().max(1);
                    self.scroll = self.scroll.saturating_add(vh);
                    None
                }
                KeyCode::PageUp => {
                    let vh = self.viewport_height.get().max(1);
                    self.scroll = self.scroll.saturating_sub(vh);
                    None
                }

                // Button cycling.
                KeyCode::Tab | KeyCode::Right => {
                    self.selected = (self.selected + 1) % BTN_COUNT;
                    None
                }
                KeyCode::BackTab | KeyCode::Left => {
                    self.selected = self.selected.checked_sub(1).unwrap_or(BTN_COUNT - 1);
                    None
                }

                // Confirm focused button.
                KeyCode::Enter => match self.selected {
                    0 => Some(DialogAction::PermissionAllow),
                    1 => Some(DialogAction::PermissionAllowSession),
                    2 => Some(DialogAction::PermissionAllowAlways),
                    _ => Some(DialogAction::PermissionDeny),
                },

                _ => None,
            }
        }
    }

    /// Draw the centered modal over `area`.
    pub fn draw(&self, frame: &mut Frame, area: Rect) {
        let theme = crate::style::theme();

        // Compute dialog dimensions.
        let w = (area.width * 3 / 4).max(MIN_W).min(MAX_W).min(area.width);
        let h = (area.height * 2 / 3).max(MIN_H).min(area.height);

        let x = area.x + area.width.saturating_sub(w) / 2;
        let y = area.y + area.height.saturating_sub(h) / 2;
        let dialog_rect = Rect::new(x, y, w, h);

        frame.render_widget(Clear, dialog_rect);

        // Title uses a gradient-style two-span sequence (primary → secondary).
        let title_line = Line::from(vec![
            Span::styled(
                " Permission ",
                theme.banner_title(),
            ),
            Span::styled(
                "Request ",
                Style::default()
                    .fg(theme.colors.secondary)
                    .add_modifier(Modifier::BOLD),
            ),
        ]);

        let block = Block::default()
            .title(title_line)
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(Style::default().fg(theme.colors.warning))
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

        let mut cursor_y = inner.y;

        // ── Tool name ────────────────────────────────────────────────────────
        if cursor_y < inner.y + inner.height {
            let tool_line = Line::from(vec![
                Span::styled("  Tool:  ", Style::default().fg(theme.colors.muted)),
                Span::styled(self.tool_name.clone(), theme.tool_name()),
            ]);
            frame.render_widget(
                Paragraph::new(tool_line),
                Rect::new(inner.x, cursor_y, inner.width, 1),
            );
            cursor_y += 1;
        }

        // ── Warning / reason lines (enriched permission event) ───────────────
        if let Some(warning) = &self.warning {
            if cursor_y < inner.y + inner.height {
                let line = Line::from(vec![
                    Span::styled("  ⚠ ", Style::default().fg(theme.colors.warning)),
                    Span::styled(warning.clone(), Style::default().fg(theme.colors.warning)),
                ]);
                frame.render_widget(
                    Paragraph::new(line),
                    Rect::new(inner.x, cursor_y, inner.width, 1),
                );
                cursor_y += 1;
            }
        }
        if let Some(reason) = &self.reason {
            if cursor_y < inner.y + inner.height {
                let line = Line::from(vec![
                    Span::styled("  Why:   ", Style::default().fg(theme.colors.muted)),
                    Span::styled(reason.clone(), Style::default().fg(theme.colors.dim)),
                ]);
                frame.render_widget(
                    Paragraph::new(line),
                    Rect::new(inner.x, cursor_y, inner.width, 1),
                );
                cursor_y += 1;
            }
        }

        // ── Separator ────────────────────────────────────────────────────────
        if cursor_y < inner.y + inner.height {
            let sep = "─".repeat(inner.width as usize);
            frame.render_widget(
                Paragraph::new(Span::styled(
                    sep,
                    Style::default().fg(theme.colors.border),
                )),
                Rect::new(inner.x, cursor_y, inner.width, 1),
            );
            cursor_y += 1;
        }

        // ── Viewport: diff or raw args ─────────────────────────────────────
        // Reserve 2 lines at the bottom: button row + hint row.
        let reserved_bottom: u16 = 2;
        let viewport_top = cursor_y;
        let available_bottom = inner.y + inner.height;
        let viewport_bottom = available_bottom.saturating_sub(reserved_bottom);

        let viewport_h = if viewport_bottom > viewport_top {
            viewport_bottom - viewport_top
        } else {
            0
        };
        // Store the measured height so handle_key can use it for page scrolling.
        self.viewport_height.set(viewport_h);

        if viewport_h > 0 {
            let viewport_rect = Rect::new(inner.x, viewport_top, inner.width, viewport_h);

            match (&self.diff_old, &self.diff_new) {
                (Some(old), Some(new)) => {
                    // Render colored diff lines.
                    let diff_lines = crate::render::diff::render_diff(old, new, inner.width);
                    let total_lines = diff_lines.len() as u16;
                    let scroll_clamped =
                        self.scroll.min(total_lines.saturating_sub(viewport_h));
                    let visible: Vec<Line> = diff_lines
                        .into_iter()
                        .skip(scroll_clamped as usize)
                        .take(viewport_h as usize)
                        .collect();
                    frame.render_widget(Paragraph::new(visible), viewport_rect);
                }
                _ => {
                    // Raw args in muted style.
                    let para = Paragraph::new(self.tool_args.as_str())
                        .style(Style::default().fg(theme.colors.muted))
                        .wrap(Wrap { trim: false })
                        .scroll((self.scroll, 0));
                    frame.render_widget(para, viewport_rect);
                }
            }
        }

        // ── Button row / clarify input ───────────────────────────────────────
        let btn_y = available_bottom.saturating_sub(2);
        if btn_y < inner.y + inner.height {
            if self.clarify_mode {
                // Free-text field replacing the button row.
                let field = Line::from(vec![
                    Span::styled("  › ", Style::default().fg(theme.colors.secondary)),
                    Span::styled(
                        self.clarify_input.clone(),
                        Style::default().fg(theme.colors.primary),
                    ),
                    Span::styled("▌", Style::default().fg(theme.colors.secondary)),
                ]);
                frame.render_widget(
                    Paragraph::new(field),
                    Rect::new(inner.x, btn_y, inner.width, 1),
                );
            } else {
                let btn_data: &[(&str, usize)] = &[
                    ("[ Allow (y) ]", 0),
                    ("[ Session (s) ]", 1),
                    ("[ Always (a) ]", 2),
                    ("[ Deny (n) ]", DENY_IDX),
                ];

                let mut btn_spans: Vec<Span> = vec![Span::raw(" ")];
                for (label, idx) in btn_data {
                    let style = if self.selected == *idx {
                        if *idx == DENY_IDX {
                            theme.button_danger()
                        } else {
                            theme.button_active()
                        }
                    } else {
                        theme.button_inactive()
                    };
                    btn_spans.push(Span::styled(label.to_string(), style));
                    btn_spans.push(Span::raw(" "));
                }

                frame.render_widget(
                    Paragraph::new(Line::from(btn_spans)),
                    Rect::new(inner.x, btn_y, inner.width, 1),
                );
            }
        }

        // ── Hint row ─────────────────────────────────────────────────────────
        let hint_y = available_bottom.saturating_sub(1);
        if hint_y < inner.y + inner.height {
            let hint = if self.clarify_mode {
                "  Enter send to agent · Esc cancel clarification"
            } else {
                "  y/s/a/n · Tab cycle · c clarify · Enter confirm · Esc deny"
            };
            frame.render_widget(
                Paragraph::new(Span::styled(
                    hint,
                    Style::default().fg(theme.colors.dim),
                )),
                Rect::new(inner.x, hint_y, inner.width, 1),
            );
        }
    }
}

impl Default for Permissions {
    fn default() -> Self {
        Self::new()
    }
}
