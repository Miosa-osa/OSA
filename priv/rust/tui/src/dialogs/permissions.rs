// Enriched permission dialog: diff viewport (set_diff, wired from the
// permission_required event) plus warning/reason metadata lines.
#![allow(dead_code)]

use std::cell::Cell;

use unicode_width::UnicodeWidthStr;

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::{
    prelude::*,
    widgets::{Clear, Paragraph, Wrap},
};

use super::DialogAction;
use crate::render::sanitize::{
    scrub_untrusted_block, scrub_untrusted_line, scrub_untrusted_line_opt,
};

const MIN_W: u16 = 50;
const MAX_W: u16 = 90;
const MIN_H: u16 = 10;

/// Lead-in for the warning / reason metadata rows. Shared by `content_height` and
/// `draw_inline` so the reserved row count and the rendered rows can never drift.
const WARN_PREFIX: &str = "  ⚠ ";
const REASON_PREFIX: &str = "  Why:   ";

/// Wrap `text` into the columns left after `prefix` at `width`.
///
/// Height and draw MUST both go through this. Reserving exactly one row per field
/// while rendering an unwrapped `Paragraph` silently CLIPPED the backend-supplied
/// warning and reason — i.e. the text the user is being asked to make a security
/// decision about could be cut off mid-sentence with no indication.
fn wrapped_rows(prefix: &str, text: &str, width: u16) -> Vec<String> {
    let avail = (width as usize)
        .saturating_sub(UnicodeWidthStr::width(prefix))
        .max(1);
    crate::render::markdown::wrap_text(text, avail)
}

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
    /// Human-facing target of the call (skill name, shell command, path). When
    /// present it replaces the bare tool name in the title: "Allow skill: x?".
    pub target: Option<String>,
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
            target: None,
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
    ///
    /// The tool name and argument payload are scrubbed on the way in — see
    /// [`set_target`](Self::set_target) for why this dialog in particular
    /// cannot display backend text verbatim. `request_id` is opaque and goes
    /// back to the backend untouched.
    pub fn set_tool(&mut self, name: String, args: String, request_id: String) {
        self.tool_name = scrub_untrusted_line(&name);
        self.target = None;
        self.tool_args = scrub_untrusted_block(&args);
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

    /// Attach the human-facing target (skill name, command, path). Empty/blank
    /// values are ignored so the title falls back to the tool name.
    ///
    /// The target is scrubbed here, at ingress, rather than at each render
    /// site: it is the string the "Allow …?" title puts in front of the
    /// operator, and it is chosen by whatever produced the tool call — a
    /// prompt-injected model, a hostile repo, an MCP server. Left verbatim, a
    /// bidi override reorders it so the command the operator reads is not the
    /// command that runs, in the one dialog where that decides whether it runs
    /// at all. The backend does not scrub (verified: `tool_executor.ex`'s
    /// `clip/1` collapses `\s` only, which does not match U+202E), so this is
    /// the only place the defence exists. Scrubbing on the way in also means a
    /// render site added later inherits it for free.
    pub fn set_target(&mut self, target: Option<String>) {
        self.target = target
            .map(|s| scrub_untrusted_line(&s))
            .filter(|s| !s.trim().is_empty());
    }

    /// Syntect language token for the diff, derived from the target's file
    /// extension when the target looks like a path. `None` (extensionless target,
    /// a command, or a skill name) makes the diff render as plain content.
    fn diff_language(&self) -> Option<String> {
        let target = self.target.as_deref()?;
        let name = target.rsplit(['/', '\\']).next().unwrap_or(target);
        let (stem, ext) = name.rsplit_once('.')?;
        if stem.is_empty() || ext.is_empty() {
            return None;
        }
        Some(ext.to_ascii_lowercase())
    }

    /// What the "Allow …?" title names: the concrete target when the backend
    /// supplied one, otherwise the bare tool name.
    pub fn display_label(&self) -> &str {
        match self.target.as_deref() {
            Some(t) => t,
            None => &self.tool_name,
        }
    }

    /// Attach a diff for display in the viewport.
    pub fn set_diff(&mut self, old: String, new: String) {
        self.diff_old = Some(old);
        self.diff_new = Some(new);
        self.scroll = 0;
    }

    /// Attach the enriched metadata (destructive warning + prompt reason).
    ///
    /// Backend-supplied prose, scrubbed on the same grounds as the target: it
    /// is rendered inside the trust decision, and a reordered "reason" is a
    /// reordered justification.
    pub fn set_meta(&mut self, warning: Option<String>, reason: Option<String>) {
        self.warning = scrub_untrusted_line_opt(warning);
        self.reason = scrub_untrusted_line_opt(reason);
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

    /// Rows this inline prompt wants: header + optional warning/reason + a
    /// separator + a capped body preview + choice row + hint row. Capped so a
    /// large diff can never let the prompt swallow the compact live region.
    pub fn content_height(&self, width: u16) -> u16 {
        const BODY_CAP: u16 = 8;
        let mut h: u16 = 1; // header (tool) line
        // Width-AWARE: these wrap, so reserve the rows they will actually occupy.
        if let Some(warning) = &self.warning {
            h += wrapped_rows(WARN_PREFIX, warning, width).len().max(1) as u16;
        }
        if let Some(reason) = &self.reason {
            h += wrapped_rows(REASON_PREFIX, reason, width).len().max(1) as u16;
        }
        h += 1; // separator
        let body: u16 = match (&self.diff_old, &self.diff_new) {
            (Some(old), Some(new)) => {
                crate::render::diff::render_diff(old, new, width, self.diff_language().as_deref())
                    .len() as u16
            }
            _ => self.tool_args.lines().count().max(1) as u16,
        };
        h += body.clamp(1, BODY_CAP);
        h + 2 // choice row + hint row
    }

    /// Draw the approval prompt INLINE in the live region, bottom-anchored within
    /// `area` (the row band directly above the composer). Borderless + compact so
    /// the approval reads as part of the conversation flow, Claude-Code style —
    /// NOT a full-screen modal. Same actions + key handling as before.
    pub fn draw_inline(&self, frame: &mut Frame, area: Rect) {
        let theme = crate::style::theme();
        if area.width == 0 || area.height == 0 {
            return;
        }

        // Content-driven, capped height; hug the composer by anchoring to the
        // bottom of the band.
        let h = self.content_height(area.width).min(area.height);

        // Degenerate room: collapse to a single-line ask so the prompt is never
        // invisible (the user can still answer with y/s/a/n).
        if h < 4 {
            let line = Line::from(vec![
                Span::styled(
                    "▐ ",
                    Style::default()
                        .fg(theme.colors.warning)
                        .add_modifier(Modifier::BOLD),
                ),
                Span::styled("Allow ", Style::default().fg(theme.colors.muted)),
                Span::styled(self.display_label().to_string(), theme.tool_name()),
                Span::styled("?  ", Style::default().fg(theme.colors.muted)),
                Span::styled("y/s/a/n", Style::default().fg(theme.colors.dim)),
            ]);
            let y = area.y + area.height.saturating_sub(1);
            frame.render_widget(Paragraph::new(line), Rect::new(area.x, y, area.width, 1));
            return;
        }

        let inner = Rect::new(area.x, area.y + area.height - h, area.width, h);
        // Wipe the band so stale streaming rows don't bleed through behind the
        // prompt.
        frame.render_widget(Clear, inner);

        let mut cursor_y = inner.y;

        // ── Tool name ────────────────────────────────────────────────────────
        if cursor_y < inner.y + inner.height {
            let tool_line = Line::from(vec![
                Span::styled(
                    "▐ ",
                    Style::default()
                        .fg(theme.colors.warning)
                        .add_modifier(Modifier::BOLD),
                ),
                Span::styled("Allow ", Style::default().fg(theme.colors.muted)),
                Span::styled(self.display_label().to_string(), theme.tool_name()),
                Span::styled("?", Style::default().fg(theme.colors.muted)),
            ]);
            frame.render_widget(
                Paragraph::new(tool_line),
                Rect::new(inner.x, cursor_y, inner.width, 1),
            );
            cursor_y += 1;
        }

        // ── Warning / reason lines (enriched permission event) ───────────────
        // Both fields WRAP (see `wrapped_rows`): continuation rows are indented to
        // the prefix width so the text stays aligned under its first line.
        if let Some(warning) = &self.warning {
            let pad = " ".repeat(UnicodeWidthStr::width(WARN_PREFIX));
            for (i, row) in wrapped_rows(WARN_PREFIX, warning, inner.width)
                .iter()
                .enumerate()
            {
                if cursor_y >= inner.y + inner.height {
                    break;
                }
                let lead = if i == 0 { WARN_PREFIX } else { pad.as_str() };
                let line = Line::from(vec![
                    Span::styled(lead.to_string(), Style::default().fg(theme.colors.warning)),
                    Span::styled(row.clone(), Style::default().fg(theme.colors.warning)),
                ]);
                frame.render_widget(
                    Paragraph::new(line),
                    Rect::new(inner.x, cursor_y, inner.width, 1),
                );
                cursor_y += 1;
            }
        }
        if let Some(reason) = &self.reason {
            let pad = " ".repeat(UnicodeWidthStr::width(REASON_PREFIX));
            for (i, row) in wrapped_rows(REASON_PREFIX, reason, inner.width)
                .iter()
                .enumerate()
            {
                if cursor_y >= inner.y + inner.height {
                    break;
                }
                let lead = if i == 0 { REASON_PREFIX } else { pad.as_str() };
                let line = Line::from(vec![
                    Span::styled(lead.to_string(), Style::default().fg(theme.colors.muted)),
                    Span::styled(row.clone(), Style::default().fg(theme.colors.dim)),
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
                    let diff_lines = crate::render::diff::render_diff(
                        old,
                        new,
                        inner.width,
                        self.diff_language().as_deref(),
                    );
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

#[cfg(test)]
mod tests {
    use super::*;

    /// The other half of the "typing `y` vanished" fix: making printable keys
    /// always reach the composer must NOT disarm the real confirmations. A
    /// permission prompt is a distinct AppState — it is on screen and awaiting
    /// an answer — so its quick-keys keep working exactly as before.
    #[test]
    fn a_displayed_permission_prompt_still_confirms_on_y() {
        let mut d = Permissions::new();
        d.set_tool("shell_execute".into(), "npm test".into(), "req_y".into());
        assert!(matches!(
            d.handle_key(KeyEvent::new(KeyCode::Char('y'), KeyModifiers::NONE)),
            Some(DialogAction::PermissionAllow)
        ));
        assert!(matches!(
            d.handle_key(KeyEvent::new(KeyCode::Char('Y'), KeyModifiers::NONE)),
            Some(DialogAction::PermissionAllow)
        ));
    }

    #[test]
    fn a_displayed_permission_prompt_still_declines_on_n() {
        let mut d = Permissions::new();
        d.set_tool("shell_execute".into(), "rm -rf /".into(), "req_n".into());
        assert!(matches!(
            d.handle_key(KeyEvent::new(KeyCode::Char('n'), KeyModifiers::NONE)),
            Some(DialogAction::PermissionDeny)
        ));
    }

    #[test]
    fn display_label_prefers_target_over_tool_name() {
        let mut d = Permissions::new();
        d.set_tool("use_skill".into(), "lavish".into(), "req_1".into());
        // No target yet → falls back to the tool name.
        assert_eq!(d.display_label(), "use_skill");
        // Backend supplies the concrete target → title names it.
        d.set_target(Some("skill: lavish".into()));
        assert_eq!(d.display_label(), "skill: lavish");
    }

    #[test]
    fn blank_target_is_ignored() {
        let mut d = Permissions::new();
        d.set_tool("shell_execute".into(), "npm test".into(), "req_2".into());
        d.set_target(Some("   ".into()));
        assert_eq!(d.display_label(), "shell_execute");
    }

    // ───────────────── Trojan Source in the trust decision ──────────────────
    //
    // The backend does NOT scrub: `tool_executor.ex`'s `clip/1` only trims and
    // collapses `\s`, which does not match U+202E. So a tool call whose command
    // carries a bidi override arrives here intact, and this dialog is where the
    // operator decides whether it executes. The scrub has to happen here.

    /// A command carrying an RLO renders right-to-left from that point on, so
    /// what the operator reads is not what runs. The override must not survive
    /// into the label at all.
    #[test]
    fn a_bidi_override_never_reaches_the_permission_label() {
        let mut d = Permissions::new();
        d.set_tool("shell_execute".into(), "echo hi".into(), "req_bidi".into());
        // Reads as "rm -rf /tmp/safe" but the tail is reordered by the RLO.
        d.set_target(Some("rm -rf /\u{202E}efas/pmt/".into()));

        let label = d.display_label();
        assert!(
            !label
                .chars()
                .any(crate::render::sanitize::is_invisible_formatting_char),
            "the label must carry no reordering codepoint: {label:?}"
        );
        assert_eq!(label, "rm -rf /efas/pmt/");
    }

    /// The whole Trojan Source family, plus a raw ESC, across every untrusted
    /// field the dialog displays.
    #[test]
    fn every_untrusted_field_is_scrubbed() {
        let mut d = Permissions::new();
        d.set_tool(
            "shell\u{202E}_execute".into(),
            "--flag\u{2066}=1\nsecond\u{200B}line".into(),
            "req_all".into(),
        );
        d.set_target(Some("/tmp/\u{2069}path".into()));
        d.set_meta(
            Some("destruc\u{202D}tive".into()),
            Some("because\u{061C} reasons".into()),
        );

        assert_eq!(d.tool_name, "shell_execute");
        assert_eq!(d.display_label(), "/tmp/path");
        assert_eq!(d.warning.as_deref(), Some("destructive"));
        assert_eq!(d.reason.as_deref(), Some("because reasons"));
        // The block variant keeps line structure, drops everything else.
        assert_eq!(d.tool_args, "--flag=1\nsecondline");

        // A raw escape introducer must never survive into a rendered span.
        d.set_target(Some("cat \x1b]0;pwn\x07/etc/passwd".into()));
        assert_eq!(d.display_label(), "cat ]0;pwn/etc/passwd");
    }

    /// **The escape-injection half of the same gap, and the one that is
    /// genuinely exploitable.**
    ///
    /// Measured against a real terminal emulator (`VT100Backend` pipes
    /// ratatui's actual ANSI output through a vt100 parser), the two families
    /// behave very differently:
    ///
    ///   * bidi controls are zero-width graphemes, and ratatui drops those when
    ///     it fills a `Buffer` cell — so an RLO never reaches the terminal
    ///     through this render path at all;
    ///   * a raw `ESC` is *not* dropped. It survives into the buffer and is
    ///     written straight out, where the terminal executes it.
    ///
    /// So a backend-supplied command of the form `…\x1b]0;PWNED\x07…` does not
    /// display in the permission dialog — it *runs*, retitling the operator's
    /// window from inside the prompt that is asking them to authorize
    /// something, and hiding its own payload from the row while it does. This
    /// asserts on the emulator's state, not on a `Buffer`, because a `Buffer`
    /// assertion cannot tell "displayed" from "executed".
    #[test]
    fn a_command_carrying_an_escape_cannot_drive_the_terminal() {
        use ratatui::Terminal;

        let mut d = Permissions::new();
        d.set_tool("shell_execute".into(), "echo hi".into(), "req_esc".into());
        d.set_target(Some("cat \u{1b}]0;PWNED\u{7}/etc/passwd".into()));

        let mut term = Terminal::new(crate::test_backend::VT100Backend::new(80, 24)).unwrap();
        term.draw(|frame| {
            let area = frame.area();
            d.draw_inline(frame, area);
        })
        .unwrap();

        let title = term.backend().vt100().screen().title().to_string();
        assert_ne!(
            title, "PWNED",
            "backend-supplied text executed an OSC sequence from inside the \
             permission dialog — the escape reached the terminal"
        );

        let screen = term.backend().contents();
        assert!(
            screen.contains("cat ]0;PWNED/etc/passwd"),
            "the neutralized command must still be fully legible so the operator \
             can see exactly what they are authorizing:\n{screen}"
        );
    }

    /// The bidi half, asserted at the same level for completeness. ratatui's
    /// zero-width-grapheme drop already keeps an RLO off the screen, so this
    /// pins that the scrub does not *regress* legibility — the command must
    /// read correctly and carry no reordering codepoint.
    #[test]
    fn the_drawn_dialog_shows_the_command_in_reading_order() {
        let mut d = Permissions::new();
        d.set_tool("shell_execute".into(), "echo hi".into(), "req_draw".into());
        d.set_target(Some("rm -rf /\u{202E}efas/pmt/".into()));

        let buf = crate::layout_invariants::render_to_buffer(
            |frame| {
                let area = frame.area();
                d.draw_inline(frame, area);
            },
            80,
            24,
        );
        let screen = crate::layout_invariants::snapshot_buffer(&buf);

        assert!(
            !screen
                .chars()
                .any(crate::render::sanitize::is_invisible_formatting_char),
            "no reordering codepoint may reach the screen:\n{screen}"
        );
        assert!(
            screen.contains("rm -rf /efas/pmt/"),
            "the scrubbed command must still be legible on screen:\n{screen}"
        );
    }

    /// Over-scrubbing would be its own defect — the operator has to be able to
    /// read a normal command, including non-Latin text and emoji.
    #[test]
    fn ordinary_commands_render_untouched() {
        let mut d = Permissions::new();
        d.set_tool("shell_execute".into(), "npm test".into(), "req_ok".into());
        d.set_target(Some("git commit -m \"fix: 漢字 🎉\"".into()));
        assert_eq!(d.display_label(), "git commit -m \"fix: 漢字 🎉\"");
    }

    #[test]
    fn set_tool_resets_stale_target() {
        let mut d = Permissions::new();
        d.set_target(Some("skill: lavish".into()));
        // A new request must not inherit the previous call's target.
        d.set_tool("file_edit".into(), "lib/foo.ex".into(), "req_3".into());
        assert_eq!(d.display_label(), "file_edit");
    }
}

