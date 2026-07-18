//! `/permissions` — the permission-rules manager.
//!
//! A branded, scrollable overlay that answers "what has OSA been told it may or
//! may not do?" — every standing permission rule the backend evaluates, in the
//! exact priority order it resolves them. Each row is a colored behavior badge
//! (allow / deny / ask), the rule pattern itself, and a dim right-aligned tag
//! naming where the rule came from (session, flag, local, project, user…).
//!
//! Stateful: the app owns one [`PermissionsManager`] built from the live
//! `GET /api/v1/permission-rules` payload. `handle_key` is type-to-filter first
//! (any char narrows the list by rule text), so cursor movement uses the arrow
//! keys — `j`/`k` only move when the filter is empty, to stay out of the way of
//! the search box. Esc first clears a non-empty filter, and only closes the
//! overlay on a second press (or when the filter is already empty).
//!
//! Read-only for now: rules are surfaced, not edited. A future revision can add
//! a delete action that POSTs back to the rules endpoint (see module notes).

use std::cell::Cell;

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::{
    prelude::*,
    widgets::{Block, BorderType, Borders, Clear, Paragraph},
};

/// Clip-safe render (shared choke point with the other dialogs).
fn put<W: ratatui::widgets::Widget>(frame: &mut Frame, widget: W, rect: Rect) {
    crate::app::event_loop::safe_render_widget(frame, widget, rect);
}

const DIALOG_W: u16 = 78;
const DIALOG_H: u16 = 26;

/// One standing permission rule as surfaced by the backend, in evaluation order.
pub struct Rule {
    /// `"allow"` | `"deny"` | `"ask"` (anything else renders as a neutral badge).
    pub behavior: String,
    /// The rule pattern, e.g. `Tool(content)` / `Bash(git commit:*)`.
    pub rule: String,
    /// Origin: `session` | `flag` | `local` | `project` | `user` | `legacy` …
    pub source: String,
}

/// Bubble-up result of permissions-manager key handling.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PermissionsAction {
    /// The overlay should be dismissed.
    Close,
    /// Key consumed; keep the overlay open.
    None,
}

pub struct PermissionsManager {
    rules: Vec<Rule>,
    filter: String,
    /// Cursor index into the ordered/filtered rule list.
    cursor: usize,
    /// Scroll offset in rule-row space.
    scroll: usize,
    /// List height measured on the last draw, so `handle_key` scroll/page math
    /// matches the real dialog instead of the `DIALOG_H` upper bound.
    list_viewport: Cell<usize>,
}

impl PermissionsManager {
    pub fn new(rules: Vec<Rule>) -> Self {
        Self {
            rules,
            filter: String::new(),
            cursor: 0,
            scroll: 0,
            list_viewport: Cell::new((DIALOG_H as usize).saturating_sub(4)),
        }
    }

    /// Rule indices in display order: backend/priority order, filtered by a
    /// case-insensitive `contains` over the rule text (and its source tag).
    fn ordered(&self) -> Vec<usize> {
        if self.filter.is_empty() {
            (0..self.rules.len()).collect()
        } else {
            let needle = self.filter.to_lowercase();
            self.rules
                .iter()
                .enumerate()
                .filter(|(_, r)| {
                    r.rule.to_lowercase().contains(&needle)
                        || r.source.to_lowercase().contains(&needle)
                })
                .map(|(i, _)| i)
                .collect()
        }
    }

    /// `(count_allow, count_deny, count_ask)` across every rule (unfiltered).
    fn tallies(&self) -> (usize, usize, usize) {
        let mut a = 0;
        let mut d = 0;
        let mut k = 0;
        for r in &self.rules {
            match r.behavior.as_str() {
                "allow" => a += 1,
                "deny" => d += 1,
                "ask" => k += 1,
                _ => {}
            }
        }
        (a, d, k)
    }

    /// Behavior badge color for a rule.
    fn badge_color(behavior: &str, c: &crate::style::ThemeColors) -> Color {
        match behavior {
            "allow" => c.success,
            "deny" => c.error,
            "ask" => c.warning,
            _ => c.muted,
        }
    }

    /// Re-clamp the stored scroll so the cursor stays visible after a cursor or
    /// filter change (uses the last measured viewport height).
    fn adjust_scroll(&mut self) {
        let vp = self.list_viewport.get().max(1);
        self.scroll = crate::dialogs::clamp_scroll_to_cursor(self.scroll, self.cursor, vp);
    }

    pub fn handle_key(&mut self, key: KeyEvent) -> PermissionsAction {
        // Ignore chorded shortcuts — they belong to the app, not the filter box.
        if key.modifiers.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) {
            return PermissionsAction::None;
        }
        let last = self.ordered().len().saturating_sub(1);
        let page = self.list_viewport.get().max(1);
        match key.code {
            KeyCode::Esc => {
                if self.filter.is_empty() {
                    return PermissionsAction::Close;
                }
                self.filter.clear();
                self.cursor = 0;
                self.scroll = 0;
            }
            KeyCode::Up => {
                self.cursor = self.cursor.saturating_sub(1);
                self.adjust_scroll();
            }
            KeyCode::Down => {
                self.cursor = (self.cursor + 1).min(last);
                self.adjust_scroll();
            }
            KeyCode::Char('k') if self.filter.is_empty() => {
                self.cursor = self.cursor.saturating_sub(1);
                self.adjust_scroll();
            }
            KeyCode::Char('j') if self.filter.is_empty() => {
                self.cursor = (self.cursor + 1).min(last);
                self.adjust_scroll();
            }
            KeyCode::PageUp => {
                self.cursor = self.cursor.saturating_sub(page);
                self.adjust_scroll();
            }
            KeyCode::PageDown => {
                self.cursor = (self.cursor + page).min(last);
                self.adjust_scroll();
            }
            KeyCode::Home => {
                self.cursor = 0;
                self.adjust_scroll();
            }
            KeyCode::End => {
                self.cursor = last;
                self.adjust_scroll();
            }
            KeyCode::Backspace => {
                self.filter.pop();
                self.cursor = 0;
                self.scroll = 0;
            }
            KeyCode::Char(ch) => {
                self.filter.push(ch);
                self.cursor = 0;
                self.scroll = 0;
            }
            _ => {}
        }
        PermissionsAction::None
    }

    pub fn draw(&self, frame: &mut Frame, area: Rect) {
        let theme = crate::style::theme();
        let c = &theme.colors;

        let w = DIALOG_W.min(area.width);
        let h = DIALOG_H.min(area.height);
        let x = area.x + area.width.saturating_sub(w) / 2;
        let y = area.y + area.height.saturating_sub(h) / 2;
        let rect = Rect::new(x, y, w, h);

        put(frame, Clear, rect);
        let block = Block::default()
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(Style::default().fg(c.primary))
            .title(Line::from(vec![
                Span::styled(" OSA ", Style::default().fg(c.primary).add_modifier(Modifier::BOLD)),
                Span::styled("\u{00b7} permissions ", Style::default().fg(c.muted)),
            ]))
            .style(Style::default().bg(c.dialog_bg));
        put(frame, block, rect);

        let inner = Rect::new(
            rect.x + 2,
            rect.y + 1,
            rect.width.saturating_sub(4),
            rect.height.saturating_sub(2),
        );
        if inner.width < 12 || inner.height < 4 {
            return; // too small; border already drawn.
        }
        let iw = inner.width;
        let maxw = iw as usize;
        let mut cy = inner.y;

        // ── counts-per-behavior header ─────────────────────────────────────
        let (na, nd, nk) = self.tallies();
        let sep = Style::default().fg(c.dim);
        put(
            frame,
            Paragraph::new(Line::from(vec![
                Span::styled(format!("{na} allow"), Style::default().fg(c.success).add_modifier(Modifier::BOLD)),
                Span::styled(" \u{00b7} ", sep),
                Span::styled(format!("{nd} deny"), Style::default().fg(c.error).add_modifier(Modifier::BOLD)),
                Span::styled(" \u{00b7} ", sep),
                Span::styled(format!("{nk} ask"), Style::default().fg(c.warning).add_modifier(Modifier::BOLD)),
            ])),
            Rect::new(inner.x, cy, iw, 1),
        );
        cy += 1;

        // ── search line ────────────────────────────────────────────────────
        let search = truncate_chars(&format!("search: {}\u{2588}", self.filter), maxw);
        let search_style = if self.filter.is_empty() {
            Style::default().fg(c.dim)
        } else {
            Style::default().fg(c.secondary)
        };
        put(
            frame,
            Paragraph::new(Line::from(Span::styled(search, search_style))),
            Rect::new(inner.x, cy, iw, 1),
        );
        cy += 1;

        // ── separator ──────────────────────────────────────────────────────
        put(
            frame,
            Paragraph::new(Span::styled("\u{2500}".repeat(maxw), Style::default().fg(c.dim))),
            Rect::new(inner.x, cy, iw, 1),
        );
        cy += 1;

        // ── scrollable rule list ───────────────────────────────────────────
        let list_h = inner.height.saturating_sub(4); // 3 header lines + 1 help.
        self.list_viewport.set((list_h as usize).max(1));

        let ordered = self.ordered();
        if ordered.is_empty() {
            let msg = if self.rules.is_empty() {
                "No permission rules \u{2014} decisions you make with 'always' land here.".to_string()
            } else {
                format!("No rules match \u{201c}{}\u{201d}", self.filter)
            };
            put(
                frame,
                Paragraph::new(Span::styled(truncate_chars(&msg, maxw), Style::default().fg(c.muted)))
                    .alignment(Alignment::Center),
                Rect::new(inner.x, cy + list_h / 2, iw, 1),
            );
        } else {
            let scroll =
                crate::dialogs::clamp_scroll_to_cursor(self.scroll, self.cursor, (list_h as usize).max(1));
            for rel in 0..(list_h as usize) {
                let abs = rel + scroll;
                let Some(&ri) = ordered.get(abs) else { break };
                let r = &self.rules[ri];
                let ry = cy + rel as u16;
                let selected = abs == self.cursor;

                // Fixed-width badge: "● allow", padded so rule text aligns.
                let badge = format!("\u{25CF} {:<5}", r.behavior);
                let src = format!("[{}]", r.source);
                let bw = badge.chars().count();
                let sw = src.chars().count();

                if selected {
                    // Full-width highlight bar: badge + rule + right-aligned source.
                    let gap = 2usize;
                    let rule_room = maxw.saturating_sub(bw + 1 + gap + sw);
                    let rule_txt = truncate_chars(&r.rule, rule_room);
                    let mut s = format!("{badge} {rule_txt}");
                    let pad = maxw.saturating_sub(s.chars().count() + sw);
                    s.push_str(&" ".repeat(pad));
                    s.push_str(&src);
                    let s = truncate_chars(&s, maxw);
                    put(
                        frame,
                        Paragraph::new(Line::from(Span::styled(s, theme.button_active()))),
                        Rect::new(inner.x, ry, iw, 1),
                    );
                } else {
                    let rule_room = maxw.saturating_sub(bw + 1 + 2 + sw);
                    let rule_txt = truncate_chars(&r.rule, rule_room);
                    let used = bw + 1 + rule_txt.chars().count();
                    let pad = maxw.saturating_sub(used + sw);
                    let spans = vec![
                        Span::styled(badge, Style::default().fg(Self::badge_color(&r.behavior, c)).add_modifier(Modifier::BOLD)),
                        Span::raw(" "),
                        Span::styled(rule_txt, Style::default().fg(c.secondary).add_modifier(Modifier::BOLD)),
                        Span::raw(" ".repeat(pad)),
                        Span::styled(src, Style::default().fg(c.dim)),
                    ];
                    put(
                        frame,
                        Paragraph::new(Line::from(spans)),
                        Rect::new(inner.x, ry, iw, 1),
                    );
                }
            }
        }

        // ── footer hint ────────────────────────────────────────────────────
        let hint_y = inner.y + inner.height.saturating_sub(1);
        put(
            frame,
            Paragraph::new(Line::from(vec![
                Span::styled("type", Style::default().fg(c.secondary).add_modifier(Modifier::BOLD)),
                Span::styled(" filter  ", Style::default().fg(c.dim)),
                Span::styled("\u{2191}\u{2193}", Style::default().fg(c.secondary).add_modifier(Modifier::BOLD)),
                Span::styled(" nav  ", Style::default().fg(c.dim)),
                Span::styled("esc", Style::default().fg(c.secondary).add_modifier(Modifier::BOLD)),
                Span::styled(
                    if self.filter.is_empty() { " close" } else { " clear" },
                    Style::default().fg(c.dim),
                ),
            ])),
            Rect::new(inner.x, hint_y, iw, 1),
        );
    }
}

/// Char-boundary-safe truncation (multi-byte rule text can never panic).
fn truncate_chars(s: &str, max: usize) -> String {
    if s.chars().count() > max {
        let take = max.saturating_sub(1);
        format!("{}\u{2026}", s.chars().take(take).collect::<String>())
    } else {
        s.to_string()
    }
}

#[cfg(test)]
mod permissions_manager_tests {
    use super::*;
    use ratatui::{backend::TestBackend, Terminal};

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::empty())
    }

    fn sample() -> Vec<Rule> {
        vec![
            Rule { behavior: "allow".into(), rule: "Bash(git status:*)".into(), source: "session".into() },
            Rule { behavior: "deny".into(), rule: "Bash(rm -rf:*)".into(), source: "project".into() },
            Rule { behavior: "ask".into(), rule: "Write(**/*.rs)".into(), source: "user".into() },
            Rule { behavior: "allow".into(), rule: "Read(\u{4e2d}\u{6587}/**)".into(), source: "local".into() },
            Rule { behavior: "deny".into(), rule: "\u{20ac}".repeat(90), source: "legacy".into() },
        ]
    }

    #[test]
    fn tallies_count_each_behavior() {
        let m = PermissionsManager::new(sample());
        assert_eq!(m.tallies(), (2, 2, 1));
    }

    #[test]
    fn filter_narrows_case_insensitively() {
        let mut m = PermissionsManager::new(sample());
        assert_eq!(m.ordered().len(), 5);
        for ch in "BASH".chars() {
            m.handle_key(key(KeyCode::Char(ch)));
        }
        assert_eq!(m.ordered().len(), 2);
        m.handle_key(key(KeyCode::Backspace));
        assert!(m.ordered().len() >= 2);
    }

    #[test]
    fn esc_clears_filter_then_closes() {
        let mut m = PermissionsManager::new(sample());
        m.handle_key(key(KeyCode::Char('r')));
        assert!(!m.filter.is_empty());
        assert_eq!(m.handle_key(key(KeyCode::Esc)), PermissionsAction::None);
        assert!(m.filter.is_empty());
        assert_eq!(m.handle_key(key(KeyCode::Esc)), PermissionsAction::Close);
    }

    #[test]
    fn cursor_navigates_and_clamps() {
        let mut m = PermissionsManager::new(sample());
        for _ in 0..20 {
            m.handle_key(key(KeyCode::Char('j')));
        }
        assert_eq!(m.cursor, m.ordered().len() - 1);
        m.handle_key(key(KeyCode::Home));
        assert_eq!(m.cursor, 0);
    }

    #[test]
    fn empty_rules_is_safe() {
        let mut m = PermissionsManager::new(Vec::new());
        assert_eq!(m.ordered().len(), 0);
        m.handle_key(key(KeyCode::Down));
        assert_eq!(m.cursor, 0);
        assert_eq!(m.handle_key(key(KeyCode::Esc)), PermissionsAction::Close);
    }

    #[test]
    fn draws_at_all_sizes_without_panic() {
        let states: Vec<(Vec<Rule>, &str)> = vec![
            (Vec::new(), ""),
            (sample(), ""),
            (sample(), "bash"),
            (sample(), "zzz"),
        ];
        for (rules, filter) in states {
            let mut m = PermissionsManager::new(rules);
            for ch in filter.chars() {
                m.handle_key(key(KeyCode::Char(ch)));
            }
            for (w, h) in [(1u16, 1u16), (10, 4), (40, 12), (70, 20), (200, 60)] {
                let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
                term.draw(|f| m.draw(f, f.area())).unwrap();
            }
        }
    }
}