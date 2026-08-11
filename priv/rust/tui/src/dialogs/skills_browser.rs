//! `/skill` `/skills` — the loaded-skill browser.
//!
//! A branded, scrollable overlay that answers "which skills can OSA auto-trigger
//! right now?" — every skill the registry has loaded, grouped by category, with
//! its one-line description, the phrases that trigger it, and its priority.
//! Replaces the flat `/skills` text dump: type to narrow the list, arrow through
//! the matches, and read each skill's purpose, triggers, and priority inline.
//!
//! Read-only. Enable/disable is a future POST (`/api/v1/skills/<name>/toggle`);
//! this overlay only surfaces state. Stateful: the app owns one [`SkillsBrowser`]
//! built from `client.list_skills()`. `handle_key` is type-to-filter first (any
//! char extends the query), so cursor movement uses the arrow keys — `j`/`k` only
//! move when the filter is empty. Esc clears a non-empty filter first, then closes.

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
const DIALOG_H: u16 = 28;

/// One loaded skill, as surfaced by `GET /api/v1/skills`
/// (`{skills:[{name,description,category,triggers,priority}],count}`).
#[derive(Debug, Clone)]
pub struct SkillItem {
    pub name: String,
    pub description: String,
    /// Grouping bucket; `None` renders under the "general" group.
    pub category: Option<String>,
    /// Phrases/events that auto-fire the skill.
    pub triggers: Vec<String>,
    /// Higher fires first; `None` renders as unranked.
    pub priority: Option<i32>,
}

/// Bubble-up result of skills-browser key handling.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkillsBrowserAction {
    /// The overlay should be dismissed.
    Close,
    /// Key consumed; keep the overlay open.
    None,
}

/// A single rendered line: a category header, or a skill at `usize` position in
/// the currently-ordered (filtered) list.
enum RenderRow {
    Header(String),
    Skill(usize),
}

pub struct SkillsBrowser {
    skills: Vec<SkillItem>,
    filter: String,
    /// Cursor index into the ordered/filtered skill list (never over headers).
    cursor: usize,
    /// Scroll offset in *render-row* space (headers included).
    scroll: usize,
    /// List height measured on the last draw, so `handle_key` scroll/page math
    /// matches the real dialog instead of the `DIALOG_H` upper bound.
    list_viewport: Cell<usize>,
}

impl SkillsBrowser {
    pub fn new(skills: Vec<SkillItem>) -> Self {
        Self {
            skills,
            filter: String::new(),
            cursor: 0,
            scroll: 0,
            list_viewport: Cell::new((DIALOG_H as usize).saturating_sub(4)),
        }
    }

    /// Group label for a skill's category (`None` → "general").
    fn category_label(cat: &Option<String>) -> &str {
        match cat {
            Some(s) if !s.is_empty() => s,
            _ => "general",
        }
    }

    fn matches(&self, s: &SkillItem, needle: &str) -> bool {
        s.name.to_lowercase().contains(needle)
            || s.description.to_lowercase().contains(needle)
            || Self::category_label(&s.category).to_lowercase().contains(needle)
            || s.triggers.iter().any(|t| t.to_lowercase().contains(needle))
    }

    /// Skill indices in display order. Unfiltered: grouped by category in
    /// first-seen order. Filtered: original order, case-insensitive `contains`.
    fn ordered(&self) -> Vec<usize> {
        if self.filter.is_empty() {
            let mut groups: Vec<&str> = Vec::new();
            for s in &self.skills {
                let g = Self::category_label(&s.category);
                if !groups.contains(&g) {
                    groups.push(g);
                }
            }
            let mut out = Vec::with_capacity(self.skills.len());
            for g in groups {
                for (i, s) in self.skills.iter().enumerate() {
                    if Self::category_label(&s.category) == g {
                        out.push(i);
                    }
                }
            }
            out
        } else {
            let needle = self.filter.to_lowercase();
            self.skills
                .iter()
                .enumerate()
                .filter(|(_, s)| self.matches(s, &needle))
                .map(|(i, _)| i)
                .collect()
        }
    }

    /// Build the flat renderable rows (headers interleaved when unfiltered).
    fn render_rows(&self, ordered: &[usize]) -> Vec<RenderRow> {
        let mut rows = Vec::with_capacity(ordered.len() + 8);
        if self.filter.is_empty() {
            let mut cur: Option<&str> = None;
            for (pos, &si) in ordered.iter().enumerate() {
                let label = Self::category_label(&self.skills[si].category);
                if cur != Some(label) {
                    rows.push(RenderRow::Header(label.to_string()));
                    cur = Some(label);
                }
                rows.push(RenderRow::Skill(pos));
            }
        } else {
            for pos in 0..ordered.len() {
                rows.push(RenderRow::Skill(pos));
            }
        }
        rows
    }

    /// Render-row index of the currently-selected skill (0 if none).
    fn selected_render_idx(rows: &[RenderRow], cursor: usize) -> usize {
        rows.iter()
            .position(|r| matches!(r, RenderRow::Skill(p) if *p == cursor))
            .unwrap_or(0)
    }

    /// Re-clamp the stored scroll so the cursor's row stays visible after a
    /// cursor/filter change (uses the last measured viewport height).
    fn adjust_scroll(&mut self) {
        let ordered = self.ordered();
        let rows = self.render_rows(&ordered);
        let sel = Self::selected_render_idx(&rows, self.cursor);
        let vp = self.list_viewport.get().max(1);
        self.scroll = crate::dialogs::clamp_scroll_to_cursor(self.scroll, sel, vp);
    }

    pub fn handle_key(&mut self, key: KeyEvent) -> SkillsBrowserAction {
        // Ignore chorded shortcuts — they belong to the app, not the filter box.
        if key.modifiers.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) {
            return SkillsBrowserAction::None;
        }
        let len = self.ordered().len();
        let last = len.saturating_sub(1);
        let page = self.list_viewport.get().max(1);
        match key.code {
            KeyCode::Esc => {
                if self.filter.is_empty() {
                    return SkillsBrowserAction::Close;
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
            KeyCode::Char(c) => {
                self.filter.push(c);
                self.cursor = 0;
                self.scroll = 0;
            }
            _ => {}
        }
        SkillsBrowserAction::None
    }

    /// Priority badge, e.g. `p9` (empty when unranked).
    fn priority_badge(p: Option<i32>) -> String {
        p.map(|n| format!("p{n}")).unwrap_or_default()
    }

    /// `⟨t1, t2⟩` trigger summary (empty when the skill lists none).
    fn triggers_summary(triggers: &[String]) -> String {
        if triggers.is_empty() {
            String::new()
        } else {
            format!("\u{27e8}{}\u{27e9}", triggers.join(", "))
        }
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
                Span::styled("\u{00b7} skills ", Style::default().fg(c.muted)),
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

        let ordered = self.ordered();
        let total = self.skills.len();
        let shown = ordered.len();

        // ── count summary ──────────────────────────────────────────────────
        let count = if self.filter.is_empty() {
            format!("{total} skills loaded")
        } else {
            format!("{shown}/{total} skills")
        };
        put(
            frame,
            Paragraph::new(Line::from(Span::styled(
                count,
                Style::default().fg(c.primary).add_modifier(Modifier::BOLD),
            ))),
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
            Paragraph::new(Span::styled(
                "\u{2500}".repeat(maxw),
                Style::default().fg(c.dim),
            )),
            Rect::new(inner.x, cy, iw, 1),
        );
        cy += 1;

        // ── scrollable list ────────────────────────────────────────────────
        let list_h = inner.height.saturating_sub(4); // count + search + sep + footer.
        self.list_viewport.set((list_h as usize).max(1));

        if shown == 0 {
            let msg = if self.filter.is_empty() {
                "No skills loaded".to_string()
            } else {
                format!("No skills match \u{201c}{}\u{201d}", self.filter)
            };
            put(
                frame,
                Paragraph::new(Span::styled(
                    truncate_chars(&msg, maxw),
                    Style::default().fg(c.muted),
                ))
                .alignment(Alignment::Center),
                Rect::new(inner.x, cy + list_h / 2, iw, 1),
            );
        } else {
            let rows = self.render_rows(&ordered);
            let sel = Self::selected_render_idx(&rows, self.cursor);
            let scroll =
                crate::dialogs::clamp_scroll_to_cursor(self.scroll, sel, (list_h as usize).max(1));

            for rel in 0..(list_h as usize) {
                let abs = rel + scroll;
                let Some(row) = rows.get(abs) else { break };
                let ry = cy + rel as u16;
                match row {
                    RenderRow::Header(label) => {
                        put(
                            frame,
                            Paragraph::new(Line::from(Span::styled(
                                truncate_chars(label, maxw),
                                Style::default().fg(c.primary).add_modifier(Modifier::BOLD),
                            ))),
                            Rect::new(inner.x, ry, iw, 1),
                        );
                    }
                    RenderRow::Skill(pos) => {
                        let s = &self.skills[ordered[*pos]];
                        let badge = Self::priority_badge(s.priority);
                        let trigs = Self::triggers_summary(&s.triggers);
                        let selected = *pos == self.cursor;
                        if selected {
                            // Full-width highlight bar: name + priority + desc + triggers.
                            let mut raw = format!("  {}", s.name);
                            if !badge.is_empty() {
                                raw.push_str(&format!("  {badge}"));
                            }
                            if !s.description.is_empty() {
                                raw.push_str(&format!("   {}", s.description));
                            }
                            if !trigs.is_empty() {
                                raw.push_str(&format!("   {trigs}"));
                            }
                            let line = crate::util::pad_cols(&raw, maxw);
                            put(
                                frame,
                                Paragraph::new(Line::from(Span::styled(line, theme.button_active()))),
                                Rect::new(inner.x, ry, iw, 1),
                            );
                        } else {
                            let name = truncate_chars(&s.name, maxw.saturating_sub(4));
                            let mut used = 2 + crate::util::cols(&name);
                            let mut spans = vec![
                                Span::raw("  "),
                                Span::styled(
                                    name,
                                    Style::default().fg(c.secondary).add_modifier(Modifier::BOLD),
                                ),
                            ];
                            if !badge.is_empty() && maxw.saturating_sub(used) > crate::util::cols(&badge) + 2 {
                                spans.push(Span::styled(
                                    format!("  {badge}"),
                                    Style::default().fg(c.warning).add_modifier(Modifier::BOLD),
                                ));
                                used += 2 + crate::util::cols(&badge);
                            }
                            // Description then triggers fill the remaining width.
                            let mut tail = String::new();
                            if !s.description.is_empty() {
                                tail.push_str(&format!("   {}", s.description));
                            }
                            if !trigs.is_empty() {
                                tail.push_str(&format!("   {trigs}"));
                            }
                            let remaining = maxw.saturating_sub(used);
                            if remaining > 5 && !tail.is_empty() {
                                spans.push(Span::styled(
                                    truncate_chars(&tail, remaining),
                                    Style::default().fg(c.dim),
                                ));
                            }
                            put(
                                frame,
                                Paragraph::new(Line::from(spans)),
                                Rect::new(inner.x, ry, iw, 1),
                            );
                        }
                    }
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

/// Fit into `max` DISPLAY COLUMNS on grapheme boundaries.
///
/// Delegates to the canonical fitter: a private char-count copy of this used to
/// let a CJK/emoji value over-run its reserved span and shove every column to
/// its right off the pane.
fn truncate_chars(s: &str, max: usize) -> String {
    crate::util::fit_cols(s, max)
}

#[cfg(test)]
mod skills_browser_tests {
    use super::*;
    use crossterm::event::KeyModifiers;
    use ratatui::{backend::TestBackend, Terminal};

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::empty())
    }

    fn sample() -> Vec<SkillItem> {
        vec![
            SkillItem {
                name: "systematic-debugging".into(),
                description: "7-step root-cause debug process".into(),
                category: Some("quality".into()),
                triggers: vec!["bug".into(), "error".into(), "crash".into()],
                priority: Some(5),
            },
            SkillItem {
                name: "code-review".into(),
                description: "Multi-dimension quality check".into(),
                category: Some("quality".into()),
                triggers: vec!["review".into()],
                priority: Some(3),
            },
            SkillItem {
                name: "brainstorming".into(),
                description: "Generate 3 options with pros/cons".into(),
                category: Some("planning".into()),
                triggers: vec!["feature".into()],
                priority: None,
            },
            SkillItem {
                name: "memory-query-first".into(),
                description: "Search memory before solving".into(),
                category: None,
                triggers: vec![],
                priority: Some(1),
            },
            SkillItem {
                name: "\u{4e2d}\u{6587}\u{6280}\u{80fd}".into(),
                description: "\u{20ac}".repeat(90),
                category: Some("\u{4e2d}".into()),
                triggers: vec!["\u{20ac}".repeat(40)],
                priority: Some(9),
            },
        ]
    }

    #[test]
    fn filter_narrows_case_insensitively_over_all_fields() {
        let mut b = SkillsBrowser::new(sample());
        assert_eq!(b.ordered().len(), 5);
        // "QUALITY" matches two skills by category (case-insensitive).
        for ch in "QUALITY".chars() {
            b.handle_key(key(KeyCode::Char(ch)));
        }
        assert_eq!(b.ordered().len(), 2);
        b.handle_key(key(KeyCode::Esc)); // clears filter
        assert_eq!(b.ordered().len(), 5);
    }

    #[test]
    fn filter_matches_trigger_phrases() {
        let mut b = SkillsBrowser::new(sample());
        for ch in "crash".chars() {
            b.handle_key(key(KeyCode::Char(ch)));
        }
        // Only systematic-debugging lists "crash" as a trigger.
        assert_eq!(b.ordered().len(), 1);
    }

    #[test]
    fn esc_clears_filter_then_closes() {
        let mut b = SkillsBrowser::new(sample());
        b.handle_key(key(KeyCode::Char('c')));
        assert!(!b.filter.is_empty());
        assert_eq!(b.handle_key(key(KeyCode::Esc)), SkillsBrowserAction::None);
        assert!(b.filter.is_empty());
        assert_eq!(b.handle_key(key(KeyCode::Esc)), SkillsBrowserAction::Close);
    }

    #[test]
    fn cursor_moves_over_list_and_clamps() {
        let mut b = SkillsBrowser::new(sample());
        for _ in 0..20 {
            b.handle_key(key(KeyCode::Char('j'))); // j/k only when filter empty
        }
        assert_eq!(b.cursor, b.ordered().len() - 1);
        b.handle_key(key(KeyCode::Home));
        assert_eq!(b.cursor, 0);
        b.handle_key(key(KeyCode::End));
        assert_eq!(b.cursor, b.ordered().len() - 1);
    }

    #[test]
    fn empty_registry_is_safe() {
        let mut b = SkillsBrowser::new(Vec::new());
        assert_eq!(b.ordered().len(), 0);
        b.handle_key(key(KeyCode::Down));
        assert_eq!(b.cursor, 0);
        assert_eq!(b.handle_key(key(KeyCode::Esc)), SkillsBrowserAction::Close);
    }

    #[test]
    fn badge_and_triggers_format() {
        assert_eq!(SkillsBrowser::priority_badge(Some(9)), "p9");
        assert_eq!(SkillsBrowser::priority_badge(None), "");
        assert!(SkillsBrowser::triggers_summary(&["a".into(), "b".into()]).contains("a, b"));
        assert_eq!(SkillsBrowser::triggers_summary(&[]), "");
    }

    #[test]
    fn draws_at_all_sizes_without_panic() {
        let states: Vec<(Vec<SkillItem>, &str)> = vec![
            (Vec::new(), ""),
            (sample(), ""),
            (sample(), "quality"),
            (sample(), "zzz"),
        ];
        for (skills, filter) in states {
            let mut b = SkillsBrowser::new(skills);
            for ch in filter.chars() {
                b.handle_key(key(KeyCode::Char(ch)));
            }
            for (w, h) in [(1u16, 1u16), (10, 4), (40, 12), (70, 20), (200, 60)] {
                let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
                term.draw(|f| b.draw(f, f.area())).unwrap();
            }
        }
    }
}
