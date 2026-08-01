use ratatui::prelude::*;
use ratatui::widgets::Paragraph;

const MAX_HEIGHT: u16 = 12;

pub struct ChecklistItem {
    pub id: String,
    pub subject: String,
    pub status: ChecklistStatus,
    pub active_form: Option<String>,
}

#[derive(Clone, PartialEq)]
pub enum ChecklistStatus {
    Pending,
    InProgress,
    Completed,
    Failed,
}

impl ChecklistStatus {
    /// Stable ordinal used to key a snapshot so status changes are detected
    /// (spinner ticks never touch this, so identical states never re-snapshot).
    fn ordinal(&self) -> u8 {
        match self {
            ChecklistStatus::Pending => 0,
            ChecklistStatus::InProgress => 1,
            ChecklistStatus::Completed => 2,
            ChecklistStatus::Failed => 3,
        }
    }
}

pub struct TaskChecklist {
    items: Vec<ChecklistItem>,
    visible: bool,
    /// Key of the last checklist state pushed to scrollback. `snapshot_if_changed`
    /// compares against this so a snapshot is only emitted when the set of items
    /// or any item's status actually differs from what history already shows.
    last_snapshot_key: Option<String>,
}

impl TaskChecklist {
    pub fn new() -> Self {
        Self {
            items: Vec::new(),
            visible: true,
            last_snapshot_key: None,
        }
    }

    pub fn add(&mut self, id: String, subject: String, active_form: Option<String>) {
        if !self.items.iter().any(|i| i.id == id) {
            self.items.push(ChecklistItem {
                id,
                subject,
                status: ChecklistStatus::Pending,
                active_form,
            });
        }
    }

    pub fn update(&mut self, id: &str, status: ChecklistStatus) {
        if let Some(item) = self.items.iter_mut().find(|i| i.id == id) {
            item.status = status;
        }
    }

    /// The present-continuous `active_form` of the first in-progress task, if any.
    /// Feeds the activity spinner so it shows the current step (Claude Code's
    /// activeForm). Returns `None` when nothing is in progress -- the caller clears
    /// the spinner override in that case.
    pub fn current_active_form(&self) -> Option<String> {
        self.items
            .iter()
            .find(|i| i.status == ChecklistStatus::InProgress)
            .and_then(|i| i.active_form.clone())
    }

    /// The human-readable subject of a task, looked up by the id the backend puts
    /// in a `task_write` argument hint (`"complete 171c8358"`).
    ///
    /// Tolerant of prefix ids in EITHER direction: the model and the tool layer
    /// routinely pass a shortened id while the checklist holds the full one (or
    /// the reverse). A prefix only matches when it is UNAMBIGUOUS — two tasks
    /// sharing the prefix means we cannot say which was meant, so we say nothing
    /// and the caller falls back to showing the raw id.
    pub fn subject_for(&self, id: &str) -> Option<String> {
        let id = id.trim();
        if id.is_empty() {
            return None;
        }
        if let Some(item) = self.items.iter().find(|i| i.id == id) {
            return Some(item.subject.clone());
        }
        let mut matches = self
            .items
            .iter()
            .filter(|i| i.id.starts_with(id) || id.starts_with(i.id.as_str()));
        let first = matches.next()?;
        if matches.next().is_some() {
            return None; // ambiguous prefix — don't guess
        }
        Some(first.subject.clone())
    }

    pub fn show(&mut self) {
        self.visible = true;
    }

    pub fn hide(&mut self) {
        self.visible = false;
    }

    pub fn is_visible(&self) -> bool {
        self.visible && !self.items.is_empty()
    }

    /// Retained for the app loop's per-frame tick. The inline checklist no longer
    /// animates a spinner (InProgress renders a static glyph), so this is a no-op.
    pub fn tick(&mut self) {}

    /// Total height of the inline panel: one header line plus one row per item,
    /// capped so a very long plan can never exceed the live region.
    pub fn height(&self) -> u16 {
        ((self.items.len() + 1) as u16).min(MAX_HEIGHT)
    }

    pub fn clear(&mut self) {
        self.items.clear();
        self.last_snapshot_key = None;
    }

    /// Glyph + style for a status, shared by the live panel and the scrollback
    /// snapshot so both read with the same grammar.
    fn glyph_style(status: &ChecklistStatus, theme: &crate::style::Theme) -> (char, Style) {
        match status {
            // Completed: dimmed and struck through so finished steps recede.
            ChecklistStatus::Completed => (
                '\u{2714}', // heavy check
                theme
                    .task_done()
                    .add_modifier(Modifier::CROSSED_OUT | Modifier::DIM),
            ),
            // InProgress: the current step, accented and bold.
            ChecklistStatus::InProgress => ('\u{25b8}', theme.task_active()), // right-pointing triangle
            // Pending: faint, not yet started.
            ChecklistStatus::Pending => ('\u{25a1}', theme.task_pending()), // white square
            // Failed: red.
            ChecklistStatus::Failed => ('\u{2717}', theme.task_failed()), // ballot X
        }
    }

    /// Dim header line: `Plan` plus a compact `done/total` count. Both spans are
    /// faint so the header stays quiet.
    ///
    /// The title used to flip to `Updated plan` whenever a step was in progress.
    /// That is what made the transcript alternate `Plan 1/3` / `Updated plan 1/3`
    /// down the page — the header was reporting "is a step running right now",
    /// which is a property of the live panel, not a name for the block. One
    /// stable title; the `n/m` count carries the progress.
    fn header_line(&self, theme: &crate::style::Theme) -> Line<'static> {
        let title = "Plan";
        let completed = self
            .items
            .iter()
            .filter(|i| i.status == ChecklistStatus::Completed)
            .count();
        // The header is a LABEL for the block below it, not content. It sits in
        // the quietest tier so the eye goes straight to the one accented row —
        // the in-progress step — which is the only thing in this band that is
        // actually news. The `n/m` count keeps the meta tier: it is the one fact
        // here that changes, and it is what a reader glances at for progress.
        Line::from(vec![
            Span::styled(title.to_string(), theme.recede()),
            Span::styled(format!("  {}/{}", completed, self.items.len()), theme.faint()),
        ])
    }

    /// One styled item line. When `max_width` is `Some`, the subject is truncated
    /// on a char boundary to fit (glyph + space prefix accounted for); `None`
    /// keeps the full subject (used by the frozen scrollback snapshot).
    fn item_line(
        item: &ChecklistItem,
        theme: &crate::style::Theme,
        max_width: Option<usize>,
    ) -> Line<'static> {
        let (glyph, style) = Self::glyph_style(&item.status, theme);
        // Backend subjects are model-written and routinely contain markdown, but
        // this is rendered as a plain styled span (no markdown pass) — strip the
        // markers so `**Add a new page**` doesn't show up literally.
        let raw = crate::util::strip_inline_markdown(&item.subject);
        let subject = match max_width {
            // Fit to COLUMNS. This compared byte length against a column budget and
            // then cut by BYTES, so any non-ASCII subject was truncated to roughly a
            // third of its space. `fit_cols` also guarantees the item occupies
            // exactly one row, which is what the 1-row-per-item height contract
            // assumes — the mismatch is what clipped subjects mid-word.
            Some(w) => crate::util::fit_cols(&raw, w.saturating_sub(2)), // "{glyph} " prefix
            None => raw,
        };
        Line::from(vec![
            Span::styled(format!("{} ", glyph), style),
            Span::styled(subject, style),
        ])
    }

    /// A frozen, full-width snapshot of the current checklist as styled text,
    /// used for the `Plan` scrollback cell.
    fn snapshot_text(&self, theme: &crate::style::Theme, width: u16) -> Text<'static> {
        let mut lines: Vec<Line<'static>> = Vec::with_capacity(self.items.len() + 1);
        lines.push(self.header_line(theme));
        for item in &self.items {
            // Fitted to `width`: the cell reserves 1 row per item, so each item
            // must fit one row (clean ellipsis) rather than be clipped mid-word.
            lines.push(Self::item_line(item, theme, Some(width as usize)));
        }
        Text::from(lines)
    }

    /// Plain-text form of the snapshot, stored on the scrollback cell so the
    /// transcript log has readable text (the styled `Text` is display-only).
    fn snapshot_plain(&self) -> String {
        let mut out = String::from("Plan");
        for item in &self.items {
            let mark = match item.status {
                ChecklistStatus::Completed => "[x]",
                ChecklistStatus::InProgress => "[>]",
                ChecklistStatus::Pending => "[ ]",
                ChecklistStatus::Failed => "[!]",
            };
            out.push('\n');
            out.push_str(mark);
            out.push(' ');
            out.push_str(&item.subject);
        }
        out
    }

    /// Dedupe key: the ordered set of `id:status` pairs. Changes when an item is
    /// added, removed, or transitions status; unaffected by anything cosmetic.
    fn snapshot_key(&self) -> String {
        self.items
            .iter()
            .map(|i| format!("{}:{}", i.id, i.status.ordinal()))
            .collect::<Vec<_>>()
            .join("|")
    }

    /// If the rendered checklist state differs from the last one pushed to
    /// scrollback, return the styled snapshot text and its plain-text form and
    /// remember the new state. Returns `None` when nothing meaningful changed
    /// (identical status, spinner ticks) or when there are no items.
    /// `width` is the column width the snapshot will be rendered at. It is
    /// REQUIRED: the scrollback cell reserves exactly one row per item, so each
    /// item must be fitted to one row here. Passing no width produced full-length
    /// subjects that the un-wrapped `Paragraph` then hard-clipped mid-word.
    pub fn snapshot_if_changed(&mut self, width: u16) -> Option<(Text<'static>, String)> {
        if self.items.is_empty() {
            return None;
        }
        let key = self.snapshot_key();
        if self.last_snapshot_key.as_deref() == Some(key.as_str()) {
            return None;
        }
        self.last_snapshot_key = Some(key);
        let theme = crate::style::theme();
        Some((self.snapshot_text(&theme, width), self.snapshot_plain()))
    }

    /// Draw the live checklist inline, left-aligned, at the bottom of `area`.
    /// No border, no title -- a dim header line then one glyph + text row per
    /// item. Retains every panic-safety clamp of the old panel.
    pub fn draw(&self, frame: &mut Frame, area: Rect) {
        if !self.is_visible() {
            return;
        }

        let theme = crate::style::theme();
        // Clamp the panel height to the parent area: `height()` grows with the
        // item count and can exceed the live region. Left unclamped it once
        // produced a panel that sat ABOVE the inline viewport and wrote outside
        // the frame buffer, panicking with "index outside of buffer". Never
        // taller than the area we were handed.
        let h = self.height().min(area.height);
        let w = area.width;
        if h < 2 || w < 8 {
            return;
        }

        // Bottom-left of the given area.
        let x = area.x;
        let y = area.y + area.height.saturating_sub(h);
        let panel = Rect::new(x, y, w, h);

        // Second line of defense: intersect with the frame's real drawable area.
        // If the (already area-clamped) panel still does not fully fit the frame,
        // render nothing rather than risk writing outside the buffer.
        let bounds = frame.area();
        let panel = panel.intersection(bounds);
        if panel.width == 0 || panel.height == 0 {
            return;
        }

        let width = panel.width as usize;
        let max_rows = panel.height as usize;

        let mut lines: Vec<Line<'static>> = Vec::with_capacity(max_rows);
        lines.push(self.header_line(&theme));
        for item in &self.items {
            if lines.len() >= max_rows {
                break;
            }
            lines.push(Self::item_line(item, &theme, Some(width)));
        }

        let para = Paragraph::new(lines);
        crate::app::event_loop::safe_render_widget(frame, para, panel);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(id: &str, subject: &str, status: ChecklistStatus) -> ChecklistItem {
        ChecklistItem {
            id: id.to_string(),
            subject: subject.to_string(),
            status,
            active_form: None,
        }
    }

    fn checklist(items: Vec<ChecklistItem>) -> TaskChecklist {
        TaskChecklist {
            items,
            visible: true,
            last_snapshot_key: None,
        }
    }

    /// Flatten a `Text` into per-line "glyph+content" strings.
    fn flat(text: &Text<'_>) -> Vec<String> {
        text.lines
            .iter()
            .map(|l| l.spans.iter().map(|s| s.content.as_ref()).collect::<String>())
            .collect()
    }

    /// The header title is STABLE. It used to flip to "Updated plan" whenever any
    /// step was in progress, which is what made a transcript of one plan read as
    /// alternating "Plan 1/3" / "Updated plan 1/3" blocks.
    #[test]
    fn header_title_is_stable_regardless_of_progress() {
        let theme = crate::style::theme();
        let cases = [
            ChecklistStatus::Pending,
            ChecklistStatus::InProgress,
            ChecklistStatus::Completed,
            ChecklistStatus::Failed,
        ];
        for status in cases {
            let c = checklist(vec![item("1", "a", status)]);
            let h: String = c.header_line(&theme).spans.iter().map(|s| s.content.as_ref()).collect();
            assert!(h.starts_with("Plan"), "got {h:?}");
            assert!(!h.contains("Updated"), "header must not flip variants: {h:?}");
        }
        // The plain-text form (transcript log) matches.
        let c = checklist(vec![item("1", "a", ChecklistStatus::InProgress)]);
        assert!(c.snapshot_plain().starts_with("Plan\n"), "{:?}", c.snapshot_plain());
    }

    #[test]
    fn progress_count_renders() {
        let theme = crate::style::theme();
        let c = checklist(vec![
            item("1", "a", ChecklistStatus::Completed),
            item("2", "b", ChecklistStatus::Completed),
            item("3", "c", ChecklistStatus::Pending),
        ]);
        let header: String = c.header_line(&theme).spans.iter().map(|s| s.content.as_ref()).collect();
        assert!(header.contains("2/3"), "expected 2/3 count, got {header:?}");
    }

    #[test]
    fn each_status_uses_its_own_glyph_and_style() {
        let theme = crate::style::theme();
        let cases = [
            (ChecklistStatus::Completed, '\u{2714}'),
            (ChecklistStatus::InProgress, '\u{25b8}'),
            (ChecklistStatus::Pending, '\u{25a1}'),
            (ChecklistStatus::Failed, '\u{2717}'),
        ];
        for (status, glyph) in cases {
            let (g, _style) = TaskChecklist::glyph_style(&status, &theme);
            assert_eq!(g, glyph, "wrong glyph for status");
        }
        // Completed is struck through and dimmed; InProgress is bold.
        let (_g, done) = TaskChecklist::glyph_style(&ChecklistStatus::Completed, &theme);
        assert!(done.add_modifier.contains(Modifier::CROSSED_OUT));
        assert!(done.add_modifier.contains(Modifier::DIM));
        let (_g, active) = TaskChecklist::glyph_style(&ChecklistStatus::InProgress, &theme);
        assert!(active.add_modifier.contains(Modifier::BOLD));
    }

    #[test]
    fn snapshot_text_has_header_plus_one_line_per_item() {
        let theme = crate::style::theme();
        let c = checklist(vec![
            item("1", "first", ChecklistStatus::Completed),
            item("2", "second", ChecklistStatus::InProgress),
        ]);
        let lines = flat(&c.snapshot_text(&theme, 80));
        assert_eq!(lines.len(), 3); // header + 2 items
        assert!(lines[0].starts_with("Plan"));
        assert!(lines[1].contains("first"));
        assert!(lines[2].contains("second"));
    }

    #[test]
    fn snapshot_dedupes_identical_states() {
        let mut c = checklist(vec![item("1", "a", ChecklistStatus::Pending)]);
        // First call snapshots.
        assert!(c.snapshot_if_changed(80).is_some());
        // Identical state -> no new snapshot (simulates a no-op TaskUpdated).
        assert!(c.snapshot_if_changed(80).is_none());
        assert!(c.snapshot_if_changed(80).is_none());
    }

    #[test]
    fn snapshot_fires_again_on_real_status_change() {
        let mut c = checklist(vec![item("1", "a", ChecklistStatus::Pending)]);
        assert!(c.snapshot_if_changed(80).is_some());
        assert!(c.snapshot_if_changed(80).is_none());
        // A real transition changes the key -> new snapshot.
        c.update("1", ChecklistStatus::InProgress);
        assert!(c.snapshot_if_changed(80).is_some());
        // And adding an item also changes the set.
        c.add("2".into(), "b".into(), None);
        assert!(c.snapshot_if_changed(80).is_some());
    }

    #[test]
    fn subject_for_resolves_exact_and_unambiguous_prefix_ids() {
        let c = checklist(vec![
            item("171c8358aa", "Fix invisible tasks", ChecklistStatus::Pending),
            item("fd164248bb", "Fix discarded delegation", ChecklistStatus::Pending),
        ]);
        // Exact.
        assert_eq!(c.subject_for("171c8358aa").as_deref(), Some("Fix invisible tasks"));
        // Checklist holds the full id, the hint carries a prefix.
        assert_eq!(c.subject_for("171c8358").as_deref(), Some("Fix invisible tasks"));
        // …and the reverse.
        assert_eq!(c.subject_for("171c8358aa-extra").as_deref(), Some("Fix invisible tasks"));
        // Unknown / empty resolve to nothing (caller keeps the raw id).
        assert_eq!(c.subject_for("deadbeef"), None);
        assert_eq!(c.subject_for("   "), None);
    }

    #[test]
    fn subject_for_refuses_to_guess_on_an_ambiguous_prefix() {
        let c = checklist(vec![
            item("abc1", "first", ChecklistStatus::Pending),
            item("abc2", "second", ChecklistStatus::Pending),
        ]);
        assert_eq!(c.subject_for("abc"), None);
        assert_eq!(c.subject_for("abc1").as_deref(), Some("first"));
    }

    #[test]
    fn empty_checklist_never_snapshots() {
        let mut c = checklist(vec![]);
        assert!(c.snapshot_if_changed(80).is_none());
    }

    #[test]
    fn draw_has_no_border_or_title() {
        // Render the live panel and assert none of the box-drawing border chars
        // nor the old " Tasks " title appear anywhere in the buffer.
        let c = checklist(vec![
            item("1", "alpha", ChecklistStatus::Completed),
            item("2", "beta", ChecklistStatus::InProgress),
        ]);
        let area = Rect::new(0, 0, 40, 10);
        let backend = ratatui::backend::TestBackend::new(40, 10);
        let mut term = ratatui::Terminal::new(backend).unwrap();
        term.draw(|f| c.draw(f, area)).unwrap();
        let rendered = term.backend().buffer().clone();
        let text: String = rendered.content().iter().map(|cell| cell.symbol()).collect();
        assert!(!text.contains("Tasks"), "no title");
        for border in ['\u{256d}', '\u{256e}', '\u{2570}', '\u{256f}', '\u{2502}', '\u{2500}'] {
            assert!(!text.contains(border), "no border glyph {border:?}");
        }
        // Header and content are present.
        assert!(text.contains("Plan"));
        assert!(text.contains("alpha"));
    }

    #[test]
    fn draw_does_not_panic_at_tiny_or_edge_sizes() {
        let c = checklist(vec![
            item("1", "a very long subject that will need truncation for sure", ChecklistStatus::Pending),
            item("2", "second item", ChecklistStatus::InProgress),
            item("3", "third", ChecklistStatus::Completed),
        ]);
        for (w, h) in [(0u16, 0u16), (1, 1), (2, 2), (8, 1), (8, 2), (10, 3), (200, 200)] {
            let backend = ratatui::backend::TestBackend::new(w.max(1), h.max(1));
            let mut term = ratatui::Terminal::new(backend).unwrap();
            let area = Rect::new(0, 0, w, h);
            // Must never panic regardless of area size.
            term.draw(|f| c.draw(f, area)).unwrap();
        }
    }

    #[test]
    fn draw_noop_when_hidden_or_empty() {
        let mut c = checklist(vec![item("1", "a", ChecklistStatus::Pending)]);
        c.hide();
        assert!(!c.is_visible());
        let empty = checklist(vec![]);
        assert!(!empty.is_visible());
    }
}
