use ratatui::prelude::*;
use ratatui::widgets::Paragraph;

/// Total rows the panel may claim on its own, **header row included**, before
/// it starts folding items behind a `+N more` marker.
///
/// The reference caps at 8 *items*; OSA counts the header in, so 12 here is 11
/// items. Either convention is defensible — this one is stated so the two never
/// silently disagree about what the number means.
///
/// The cap does not apply while the panel is [`PanelPin::Pinned`]: pinning is
/// the operator asking to see the whole list, and the sizing caller still
/// clamps whatever comes back to the screen.
const MAX_HEIGHT: u16 = 12;

/// What the operator's Ctrl+T chord has most recently asked of the panel.
///
/// This is a **pin**, not a hide-toggle, and the distinction is load-bearing.
/// Once the panel auto-hides a finished list, a boolean suppressor can only
/// ever hide it *further* — there is no state from which the chord makes an
/// auto-hidden list appear, which is the single most likely reason to reach for
/// the chord ("let me see the list I just finished").
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum PanelPin {
    /// The panel decides for itself, every frame (§4.3).
    #[default]
    Auto,
    /// Always visible, and the row cap is lifted.
    Pinned,
    /// Always hidden, whatever the auto-rule says.
    Suppressed,
}

impl PanelPin {
    /// `Auto → Pinned → Suppressed → Auto`.
    pub fn cycled(self) -> Self {
        match self {
            PanelPin::Auto => PanelPin::Pinned,
            PanelPin::Pinned => PanelPin::Suppressed,
            PanelPin::Suppressed => PanelPin::Auto,
        }
    }

    /// Short label for the confirmation toast.
    pub fn label(self) -> &'static str {
        match self {
            PanelPin::Auto => "Task panel: auto",
            PanelPin::Pinned => "Task panel: pinned (full list)",
            PanelPin::Suppressed => "Task panel: hidden",
        }
    }
}

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
    /// The operator's standing instruction from Ctrl+T.
    pin: PanelPin,
}

impl TaskChecklist {
    pub fn new() -> Self {
        Self {
            items: Vec::new(),
            visible: true,
            last_snapshot_key: None,
            pin: PanelPin::Auto,
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

    /// Advance the Ctrl+T pin one step and report the new state (for the toast).
    pub fn cycle_pin(&mut self) -> PanelPin {
        self.pin = self.pin.cycled();
        self.pin
    }

    pub fn pin(&self) -> PanelPin {
        self.pin
    }

    /// Whether the row cap is lifted — pinned means "show me all of it".
    fn expanded(&self) -> bool {
        self.pin == PanelPin::Pinned
    }

    /// The panel decides its own visibility every frame (§4.3).
    ///
    /// The rule that matters is the last clause: **a list with nothing left to
    /// do hides itself**, even mid-turn. Without it, last turn's finished
    /// checklist sits at the top of this turn's live region saying nothing, and
    /// the operator reads a stale `Plan 6/6` as if it described current work.
    /// The rule is stateless, so a new turn that creates fresh pending tasks
    /// re-shows the panel immediately with nothing to reset.
    pub fn is_visible(&self) -> bool {
        if self.items.is_empty() {
            return false;
        }
        match self.pin {
            PanelPin::Pinned => true,
            PanelPin::Suppressed => false,
            PanelPin::Auto => {
                self.visible
                    && self.items.iter().any(|i| {
                        matches!(
                            i.status,
                            ChecklistStatus::Pending | ChecklistStatus::InProgress
                        )
                    })
            }
        }
    }

    /// Retained for the app loop's per-frame tick. The inline checklist no longer
    /// animates a spinner (InProgress renders a static glyph), so this is a no-op.
    pub fn tick(&mut self) {}

    /// Total height of the inline panel: one header line plus one row per item,
    /// capped so a very long plan can never exceed the live region.
    ///
    /// When the cap bites, the last row is spent on the `+N more` marker rather
    /// than on an item — see [`Self::visible_rows`]. That costs one item of
    /// visibility and buys the guarantee that the panel never lies about how
    /// long the plan is, which is the trade the old code got backwards: it drew
    /// exactly `MAX_HEIGHT` rows and dropped everything past them with no
    /// indication that anything had been dropped at all.
    pub fn height(&self) -> u16 {
        let want = (self.items.len() + 1) as u16;
        if self.expanded() {
            want
        } else {
            want.min(MAX_HEIGHT)
        }
    }

    /// Split `rows` total panel rows (header included) into
    /// `(items_shown, hidden)`.
    ///
    /// `hidden == 0` means every item fits and no marker row is drawn; otherwise
    /// the caller draws `items_shown` items followed by the marker, for exactly
    /// `rows` rows either way. **Height parity is the whole point of returning
    /// both numbers from one function**: the reservation and the paint compute
    /// their row count here or not at all.
    fn visible_rows(&self, rows: u16) -> (usize, usize) {
        let total = self.items.len();
        let body = (rows as usize).saturating_sub(1); // header
        if total <= body {
            return (total, 0);
        }
        // One body row goes to the marker.
        let shown = body.saturating_sub(1);
        (shown, total - shown)
    }

    /// `… +7 more · ctrl+t to expand`, dim.
    ///
    /// The chord hint is dropped once the panel is already pinned: at that point
    /// the rows are missing because the *screen* is too short, not because the
    /// panel chose to fold them, and offering a chord that cannot help is worse
    /// than offering nothing.
    fn overflow_line(&self, hidden: usize, theme: &crate::style::Theme, max_width: usize) -> Line<'static> {
        let text = if self.expanded() {
            format!("\u{2026} +{} more", hidden)
        } else {
            format!("\u{2026} +{} more \u{00b7} ctrl+t to expand", hidden)
        };
        Line::from(Span::styled(
            crate::util::fit_cols(&text, max_width),
            theme.faint(),
        ))
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

        // One split, shared with `height()`, so the rows reserved and the rows
        // painted are the same number by construction rather than by agreement.
        let (shown, hidden) = self.visible_rows(max_rows as u16);
        let mut lines: Vec<Line<'static>> = Vec::with_capacity(max_rows);
        lines.push(self.header_line(&theme));
        for item in self.items.iter().take(shown) {
            lines.push(Self::item_line(item, &theme, Some(width)));
        }
        if hidden > 0 {
            lines.push(self.overflow_line(hidden, &theme, width));
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
            pin: PanelPin::Auto,
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

    // ── auto-hide (§4.3) ────────────────────────────────────────────────
    //
    // The complaint this fixes: last turn's finished checklist sitting at the
    // top of this turn's live region, saying nothing, while the operator reads
    // a stale `Plan 6/6` as if it described current work.

    #[test]
    fn a_list_with_work_left_is_shown() {
        for status in [ChecklistStatus::Pending, ChecklistStatus::InProgress] {
            let c = checklist(vec![
                item("1", "done", ChecklistStatus::Completed),
                item("2", "next", status),
            ]);
            assert!(c.is_visible(), "a list with work left must show");
        }
    }

    #[test]
    fn a_finished_list_hides_itself_even_mid_turn() {
        let c = checklist(vec![
            item("1", "a", ChecklistStatus::Completed),
            item("2", "b", ChecklistStatus::Failed),
        ]);
        assert!(!c.is_visible(), "nothing left to do — the panel must stand down");
    }

    /// The rule is stateless, so a new turn's fresh tasks re-show the panel with
    /// nothing to reset.
    #[test]
    fn fresh_tasks_re_show_the_panel_with_no_reset() {
        let mut c = checklist(vec![item("1", "a", ChecklistStatus::Completed)]);
        assert!(!c.is_visible());
        c.add("2".into(), "b".into(), None);
        assert!(c.is_visible());
    }

    // ── the pin tri-state (§4.7 gap 3) ──────────────────────────────────

    #[test]
    fn the_chord_cycles_auto_pinned_suppressed() {
        let mut c = checklist(vec![item("1", "a", ChecklistStatus::Pending)]);
        assert_eq!(c.pin(), PanelPin::Auto);
        assert_eq!(c.cycle_pin(), PanelPin::Pinned);
        assert_eq!(c.cycle_pin(), PanelPin::Suppressed);
        assert_eq!(c.cycle_pin(), PanelPin::Auto);
    }

    /// The whole reason a boolean was not enough: from `Auto` on a finished
    /// list, the chord has to make the panel APPEAR.
    #[test]
    fn pinning_un_hides_an_auto_hidden_finished_list() {
        let mut c = checklist(vec![item("1", "a", ChecklistStatus::Completed)]);
        assert!(!c.is_visible(), "auto-hidden");
        c.cycle_pin();
        assert!(c.is_visible(), "the pin must be able to bring it back");
        c.cycle_pin();
        assert!(!c.is_visible(), "suppressed hides it again");
    }

    #[test]
    fn suppressing_hides_a_live_list() {
        let mut c = checklist(vec![item("1", "a", ChecklistStatus::InProgress)]);
        c.cycle_pin(); // Pinned
        c.cycle_pin(); // Suppressed
        assert!(!c.is_visible());
    }

    // ── the overflow row (§4.7 gap 2) ───────────────────────────────────
    //
    // The actual bug: items past the cap were dropped with NO indication that
    // anything had been dropped.

    fn long_list(n: usize) -> TaskChecklist {
        checklist(
            (0..n)
                .map(|i| item(&i.to_string(), &format!("task {i}"), ChecklistStatus::Pending))
                .collect(),
        )
    }

    fn drawn(c: &TaskChecklist, w: u16, h: u16) -> Vec<String> {
        let backend = ratatui::backend::TestBackend::new(w, h);
        let mut term = ratatui::Terminal::new(backend).unwrap();
        term.draw(|f| c.draw(f, Rect::new(0, 0, w, h))).unwrap();
        let buf = term.backend().buffer().clone();
        (0..h)
            .map(|y| {
                (0..w)
                    .map(|x| buf[(x, y)].symbol())
                    .collect::<String>()
                    .trim_end()
                    .to_string()
            })
            .collect()
    }

    #[test]
    fn items_past_the_cap_are_counted_not_silently_dropped() {
        let c = long_list(30);
        let rows = drawn(&c, 60, MAX_HEIGHT);
        let marker = rows.last().unwrap();
        assert!(marker.starts_with('\u{2026}'), "last row must be the marker: {rows:?}");
        // 30 items, MAX_HEIGHT=12 → header + 10 items + marker → 20 hidden.
        assert!(marker.contains("+20 more"), "exact count: {marker:?}");
        assert!(marker.contains("ctrl+t to expand"), "{marker:?}");
    }

    /// The count is exact at every size: shown + hidden is always the whole list.
    #[test]
    fn the_overflow_count_is_exact_at_every_size() {
        for n in 1..25usize {
            let c = long_list(n);
            let (shown, hidden) = c.visible_rows(c.height());
            assert_eq!(shown + hidden, n, "{n} items");
            if hidden > 0 {
                assert_eq!(
                    (shown + 2) as u16,
                    c.height(),
                    "header + items + marker must fill the reservation exactly ({n} items)"
                );
            }
        }
    }

    /// Pinned lifts the cap — and when the SCREEN is still too short, the chord
    /// hint is dropped, because the chord can no longer help.
    #[test]
    fn pinning_lifts_the_cap_and_drops_the_chord_hint() {
        let mut c = long_list(30);
        assert_eq!(c.height(), MAX_HEIGHT);
        c.cycle_pin();
        assert_eq!(c.height(), 31, "pinned reports the full list");
        // A short screen still folds, but now without a hint that cannot help.
        let rows = drawn(&c, 60, 6);
        let marker = rows.last().unwrap();
        assert!(marker.contains("+26 more"), "{marker:?}");
        assert!(!marker.contains("ctrl+t"), "no dead-end hint when pinned: {marker:?}");
    }

    /// A list that fits gets no marker — the marker only appears when something
    /// is behind it.
    #[test]
    fn a_list_that_fits_shows_no_marker() {
        let c = long_list(4);
        let rows = drawn(&c, 60, c.height());
        assert!(
            !rows.iter().any(|r| r.starts_with('\u{2026}')),
            "no marker when nothing is hidden: {rows:?}"
        );
        assert!(rows.iter().any(|r| r.contains("task 3")), "{rows:?}");
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
