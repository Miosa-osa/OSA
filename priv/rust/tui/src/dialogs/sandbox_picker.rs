//! `/sandbox` — the sandbox-backend picker overlay.
//!
//! A branded, stateful overlay that lets the operator see every registered
//! sandbox execution backend (host, docker, e2b, miosa, vercel …), which one
//! is currently active (marked with a `●`), and whether each is actually
//! *available* on this machine (credentials present / daemon reachable). The
//! enforcement mode (`optional` vs `required`) is shown in the footer so the
//! operator knows whether host fallback is permitted.
//!
//! Stateful: the app owns one [`SandboxPicker`] built from GET
//! `/api/v1/sandboxes`. [`SandboxPicker::handle_key`] moves the cursor
//! (Up/Down/j/k) and returns a [`SandboxAction`] on Enter (apply the selected
//! backend — the app layer POSTs / persists + re-fetches), `s` (run the
//! selected backend's setup diagnostic) or Esc (close).
//! Unavailable backends can still be selected (matching the CLI `/sandbox`),
//! but are rendered dimmed so the operator sees the risk before committing.
//! The highlighted unavailable row also advertises `[s] set up`, so a backend
//! that needs credentials or a daemon can be fixed from where it is noticed.

use crossterm::event::{KeyCode, KeyEvent};
use ratatui::{
    prelude::*,
    widgets::{Block, BorderType, Borders, Clear, Paragraph},
};

/// Clip-safe render (shared choke point with the other dialogs).
fn put<W: ratatui::widgets::Widget>(frame: &mut Frame, widget: W, rect: Rect) {
    crate::app::event_loop::safe_render_widget(frame, widget, rect);
}

const DIALOG_W: u16 = 60;
/// Hard ceiling on visible backend rows (the registered set is tiny, but guard
/// against growth so the card never outgrows a short terminal).
const MAX_ROWS: usize = 10;

/// One sandbox backend, as surfaced by GET `/api/v1/sandboxes`.
#[derive(Debug, Clone)]
pub struct SandboxBackend {
    /// Short id (`host`, `docker`, `e2b`, `miosa`, `vercel`).
    pub name: String,
    /// Human label (e.g. "MIOSA Platform").
    pub display_name: String,
    /// Credentials present / daemon reachable right now.
    pub available: bool,
    /// The currently-selected backend (marked with `●`).
    pub current: bool,
}

/// Bubble-up result of sandbox-picker key handling.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SandboxAction {
    /// Apply the named backend (app layer persists + re-fetches).
    Apply(String),
    /// Run the named backend's setup diagnostic. Offered only for a backend
    /// that is currently unavailable - selecting one and getting silence is the
    /// dead end this exists to remove.
    Setup(String),
    /// Dismiss without changing the backend.
    Close,
}

pub struct SandboxPicker {
    backends: Vec<SandboxBackend>,
    /// Highlighted row.
    cursor: usize,
    /// Enforcement mode label (`optional` | `required`), for the footer.
    mode: String,
}

impl SandboxPicker {
    /// Build from the backend list, focusing the currently-active backend if
    /// present (otherwise row 0).
    pub fn new(backends: Vec<SandboxBackend>, mode: String) -> Self {
        let cursor = backends.iter().position(|b| b.current).unwrap_or(0);
        Self { backends, cursor, mode }
    }

    /// Backend under the cursor, if any is registered.
    fn selected(&self) -> Option<&SandboxBackend> {
        self.backends.get(self.cursor)
    }

    pub fn handle_key(&mut self, key: KeyEvent) -> Option<SandboxAction> {
        if self.backends.is_empty() {
            return match key.code {
                KeyCode::Esc | KeyCode::Enter => Some(SandboxAction::Close),
                _ => None,
            };
        }
        let last = self.backends.len().saturating_sub(1);
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => {
                self.cursor = self.cursor.saturating_sub(1);
                None
            }
            KeyCode::Down | KeyCode::Char('j') => {
                self.cursor = (self.cursor + 1).min(last);
                None
            }
            KeyCode::Enter => self.selected().map(|b| SandboxAction::Apply(b.name.clone())),
            KeyCode::Char('s') => self
                .selected()
                .filter(|b| !b.available)
                .map(|b| SandboxAction::Setup(b.name.clone())),
            KeyCode::Esc => Some(SandboxAction::Close),
            _ => None,
        }
    }

    pub fn draw(&self, frame: &mut Frame, area: Rect) {
        let theme = crate::style::theme();
        let c = &theme.colors;

        let rows = self.backends.len().min(MAX_ROWS).max(1);
        // rows + gap(1) + mode(1) + gap(1) + footer(1) = rows + 4 content lines.
        let content_h = rows + 4;
        let w = DIALOG_W.min(area.width);
        let h = (content_h as u16 + 2).min(area.height);
        let x = area.x + area.width.saturating_sub(w) / 2;
        let y = area.y + area.height.saturating_sub(h) / 2;
        let rect = Rect::new(x, y, w, h);

        put(frame, Clear, rect);
        let block = Block::default()
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(Style::default().fg(c.primary))
            .title(Line::from(vec![
                Span::styled(
                    " OSA ",
                    Style::default().fg(c.primary).add_modifier(Modifier::BOLD),
                ),
                Span::styled("\u{00b7} sandbox ", Style::default().fg(c.muted)),
            ]))
            .style(Style::default().bg(c.dialog_bg));
        put(frame, block, rect);

        let inner = Rect::new(
            rect.x + 2,
            rect.y + 1,
            rect.width.saturating_sub(4),
            rect.height.saturating_sub(2),
        );
        if inner.width < 12 || inner.height < 3 {
            return; // too small to render meaningfully; border already drawn.
        }
        let iw = inner.width;
        let max_w = iw as usize;
        let mut cy = inner.y;

        if self.backends.is_empty() {
            put(
                frame,
                Paragraph::new(Line::from(Span::styled(
                    "No sandbox backends registered",
                    Style::default().fg(c.muted),
                )))
                .alignment(Alignment::Center),
                Rect::new(inner.x, cy + inner.height / 2, iw, 1),
            );
            return;
        }

        // ── Backend rows ───────────────────────────────────────────────────
        // Reserve the last 2 rows for mode + footer; scroll to keep the cursor
        // visible if the registry ever grows past the row budget.
        let visible = (inner.height as usize).saturating_sub(3).clamp(1, MAX_ROWS);
        let scroll = if self.cursor >= visible {
            self.cursor - visible + 1
        } else {
            0
        };
        let mut drawn = 0usize;
        for (i, b) in self.backends.iter().enumerate().skip(scroll) {
            if drawn >= visible || cy >= inner.y + inner.height.saturating_sub(2) {
                break;
            }
            let is_cursor = i == self.cursor;
            let cursor_char = if is_cursor { "\u{25B8} " } else { "  " };
            let marker = if b.current { "\u{25CF} " } else { "  " };
            let name_style = if is_cursor {
                Style::default().fg(c.primary).add_modifier(Modifier::BOLD)
            } else if b.available {
                Style::default().fg(c.secondary)
            } else {
                Style::default().fg(c.dim)
            };
            // name column (fixed 9) then display name, then availability tag.
            let id = truncate_chars(&b.name, 9);
            let name_col = format!("{id:<9}");
            // Surface the fix on the row the operator is actually looking at.
            // Tagging every unavailable row would just be noise.
            let (avail_txt, avail_color): (String, Color) = if b.available {
                ("available".to_string(), c.success)
            } else if is_cursor {
                ("unavailable \u{2192} [s] set up".to_string(), c.warning)
            } else {
                ("unavailable".to_string(), c.dim)
            };
            // Budget: cursor(2)+marker(2)+name(9)+gap(2)+avail reserved. The tag
            // is no longer a fixed width, and carries a non-ASCII arrow, so
            // measure it in columns rather than bytes.
            let avail_w = crate::util::cols(&avail_txt);
            let reserved = 2 + 2 + 9 + 2 + avail_w + 1;
            let disp_room = max_w.saturating_sub(reserved);
            let mut spans = vec![
                Span::styled(cursor_char, Style::default().fg(c.primary)),
                Span::styled(
                    marker,
                    Style::default().fg(if b.current { c.success } else { c.dim }),
                ),
                Span::styled(name_col, name_style),
            ];
            if disp_room > 3 {
                spans.push(Span::styled(
                    format!("  {}", truncate_chars(&b.display_name, disp_room)),
                    Style::default().fg(if b.available { c.muted } else { c.dim }),
                ));
            }
            // COLUMNS: `name_col` and `display_name` are backend-supplied, so a
            // char-count sum under-measures them and the `available` tag lands
            // past the right edge.
            let used: usize = spans.iter().map(|s| crate::util::cols(&s.content)).sum();
            let pad = max_w.saturating_sub(used + avail_w);
            if pad > 0 {
                spans.push(Span::raw(" ".repeat(pad)));
            }
            spans.push(Span::styled(
                avail_txt.clone(),
                Style::default().fg(avail_color),
            ));
            put(
                frame,
                Paragraph::new(Line::from(spans)),
                Rect::new(inner.x, cy, iw, 1),
            );
            cy += 1;
            drawn += 1;
        }

        // ── Mode line ──────────────────────────────────────────────────────
        cy += 1;
        if cy < inner.y + inner.height.saturating_sub(1) {
            let mode = if self.mode.is_empty() { "—" } else { self.mode.as_str() };
            let mode_color = if mode == "required" { c.warning } else { c.dim };
            put(
                frame,
                Paragraph::new(Line::from(vec![
                    Span::styled("mode ", Style::default().fg(c.muted)),
                    Span::styled(
                        truncate_chars(mode, max_w.saturating_sub(6)),
                        Style::default().fg(mode_color).add_modifier(Modifier::BOLD),
                    ),
                ])),
                Rect::new(inner.x, cy, iw, 1),
            );
        }

        // ── Footer hint ────────────────────────────────────────────────────
        let hint_y = inner.y + inner.height.saturating_sub(1);
        put(
            frame,
            Paragraph::new(Line::from(vec![
                Span::styled(
                    "\u{2191}/\u{2193}",
                    Style::default().fg(c.secondary).add_modifier(Modifier::BOLD),
                ),
                Span::styled(" move  ", Style::default().fg(c.dim)),
                Span::styled(
                    "enter",
                    Style::default().fg(c.secondary).add_modifier(Modifier::BOLD),
                ),
                Span::styled(" apply  ", Style::default().fg(c.dim)),
            ]
            .into_iter()
            .chain(
                self.selected()
                    .filter(|b| !b.available)
                    .map(|_| {
                        vec![
                            Span::styled(
                                "s",
                                Style::default().fg(c.warning).add_modifier(Modifier::BOLD),
                            ),
                            Span::styled(" set up  ", Style::default().fg(c.dim)),
                        ]
                    })
                    .unwrap_or_default(),
            )
            .chain(vec![
                Span::styled(
                    "esc",
                    Style::default().fg(c.secondary).add_modifier(Modifier::BOLD),
                ),
                Span::styled(" close", Style::default().fg(c.dim)),
            ])
            .collect::<Vec<_>>())),
            Rect::new(inner.x, hint_y, iw, 1),
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
mod sandbox_picker_tests {
    use super::*;
    use crossterm::event::{KeyEvent, KeyModifiers};
    use ratatui::{backend::TestBackend, Terminal};

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::empty())
    }

    fn sample() -> Vec<SandboxBackend> {
        vec![
            SandboxBackend { name: "host".into(), display_name: "Host (no sandbox)".into(), available: true, current: false },
            SandboxBackend { name: "docker".into(), display_name: "Docker".into(), available: false, current: false },
            SandboxBackend { name: "e2b".into(), display_name: "E2B Cloud".into(), available: false, current: false },
            SandboxBackend { name: "miosa".into(), display_name: "MIOSA Platform".into(), available: true, current: true },
            SandboxBackend { name: "\u{4e2d}\u{6587}".into(), display_name: "\u{20ac}".repeat(80), available: false, current: false },
        ]
    }

    #[test]
    fn new_focuses_current_backend() {
        let p = SandboxPicker::new(sample(), "optional".into());
        // miosa is `current`, at index 3.
        assert_eq!(p.selected().map(|b| b.name.as_str()), Some("miosa"));
        // No current → row 0.
        let mut b = sample();
        for x in &mut b {
            x.current = false;
        }
        let p2 = SandboxPicker::new(b, "required".into());
        assert_eq!(p2.cursor, 0);
    }

    #[test]
    fn navigation_clamps_and_enter_applies() {
        let mut p = SandboxPicker::new(sample(), "optional".into());
        p.cursor = 0;
        assert_eq!(p.handle_key(key(KeyCode::Up)), None);
        assert_eq!(p.cursor, 0);
        assert_eq!(p.handle_key(key(KeyCode::Down)), None);
        assert_eq!(p.cursor, 1);
        assert_eq!(p.handle_key(key(KeyCode::Char('k'))), None);
        assert_eq!(p.cursor, 0);
        for _ in 0..50 {
            p.handle_key(key(KeyCode::Char('j')));
        }
        assert_eq!(p.cursor, p.backends.len() - 1);
        let name = p.backends[p.cursor].name.clone();
        assert_eq!(p.handle_key(key(KeyCode::Enter)), Some(SandboxAction::Apply(name)));
        assert_eq!(p.handle_key(key(KeyCode::Esc)), Some(SandboxAction::Close));
    }

    #[test]
    fn empty_list_is_safe() {
        let mut p = SandboxPicker::new(Vec::new(), String::new());
        assert!(p.selected().is_none());
        assert_eq!(p.handle_key(key(KeyCode::Down)), None);
        assert_eq!(p.handle_key(key(KeyCode::Enter)), Some(SandboxAction::Close));
    }

    #[test]
    fn draws_at_all_sizes_without_panic() {
        let states = vec![sample(), Vec::new()];
        for backends in states {
            let mut p = SandboxPicker::new(backends, "required".into());
            for _ in 0..p.backends.len().max(1) {
                for (w, h) in [(1u16, 1u16), (10, 4), (40, 12), (70, 20), (200, 60)] {
                    let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
                    term.draw(|f| p.draw(f, f.area())).unwrap();
                }
                p.handle_key(key(KeyCode::Down));
            }
        }
    }

    #[test]
    fn truncate_is_char_boundary_safe() {
        let s = truncate_chars(&"\u{4e2d}\u{6587}\u{7684}\u{540d}\u{5b57}".repeat(4), 6);
        assert!(s.chars().count() <= 6);
        assert!(s.ends_with('\u{2026}'));
    }
    /// Flatten a render to text so footer/row affordances can be asserted.
    fn render_to_text(p: &SandboxPicker, w: u16, h: u16) -> String {
        let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
        term.draw(|f| p.draw(f, f.area())).unwrap();
        term.backend()
            .buffer()
            .content()
            .iter()
            .map(|c| c.symbol())
            .collect()
    }

    #[test]
    fn setup_is_offered_only_where_it_would_do_something() {
        let mut p = SandboxPicker::new(sample(), "optional".into());

        // `host` is available - there is nothing to set up, so `s` must not
        // hijack the key.
        p.cursor = 0;
        assert_eq!(p.selected().map(|b| b.name.as_str()), Some("host"));
        assert_eq!(p.handle_key(key(KeyCode::Char('s'))), None);

        // `docker` is unavailable - `s` offers the diagnostic.
        p.cursor = 1;
        assert_eq!(
            p.handle_key(key(KeyCode::Char('s'))),
            Some(SandboxAction::Setup("docker".into()))
        );
    }

    #[test]
    fn setup_does_not_move_the_cursor_or_apply() {
        let mut p = SandboxPicker::new(sample(), "optional".into());
        p.cursor = 2;
        let before = p.cursor;
        assert_eq!(
            p.handle_key(key(KeyCode::Char('s'))),
            Some(SandboxAction::Setup("e2b".into()))
        );
        assert_eq!(p.cursor, before, "setup must not double as navigation");
    }

    #[test]
    fn an_empty_picker_ignores_the_setup_key() {
        let mut p = SandboxPicker::new(Vec::new(), "optional".into());
        assert_eq!(p.handle_key(key(KeyCode::Char('s'))), None);
    }

    #[test]
    fn the_highlighted_unavailable_row_advertises_the_fix() {
        let mut p = SandboxPicker::new(sample(), "optional".into());

        // Highlighted + unavailable: the affordance is visible, so an operator
        // is never left guessing why a backend cannot be selected.
        p.cursor = 1;
        let text = render_to_text(&p, 80, 14);
        assert!(text.contains("set up"), "no setup affordance: {text:?}");

        // Highlighted + available: no setup offered anywhere.
        p.cursor = 0;
        let available = render_to_text(&p, 80, 14);
        assert!(
            !available.contains("set up"),
            "setup offered for an available backend: {available:?}"
        );
    }

    #[test]
    fn the_setup_affordance_never_clips_the_availability_column() {
        let mut p = SandboxPicker::new(sample(), "optional".into());
        p.cursor = 1;
        // The tag grew and carries a non-ASCII arrow; a byte-length budget used
        // to push the column past the right edge.
        for (w, h) in [(40u16, 14u16), (60, 14), (80, 14), (200, 20)] {
            let text = render_to_text(&p, w, h);
            assert!(
                text.contains("unavailable"),
                "availability column vanished at {w}: {text:?}"
            );
        }
    }

}
