//! **Reserved-vs-drawn layout invariants** — the test infrastructure OSA was missing.
//!
//! OSA's live region is built out of components that publish a row count
//! (`height()` / `max_height()` / `desired_height()`) which the inline viewport
//! *reserves*, and separately a `draw()` that *paints*. Nothing in the suite ever
//! compared the two, so a whole class of regressions shipped green:
//!
//!   * a component reserving 6 rows and drawing 1 (5 dead rows, which the accent
//!     rail then paints as bare glyphs above the composer),
//!   * two widgets drawing into the same rect because one under-reserved,
//!   * a status line rendering two duplicate timers.
//!
//! ~676 existing tests assert on *declared* numbers agreeing with each other
//! (`height() <= max_height()`) or on text appearing *somewhere* in a buffer.
//! Neither can see the gap between the reservation and the paint.
//!
//! This module supplies the missing primitive — [`drawn_row_extent`], the index
//! of the last row a widget actually put ink on, plus one — and sweeps OSA's
//! live-region components with it.
//!
//! Codex has no generic assertion of this shape; the helpers here are modelled on
//! its `bottom_pane` `snapshot_buffer` / `render_snapshot` pair
//! (`codex-rs/tui/src/bottom_pane/mod.rs`), generalised into an invariant.

#![cfg(test)]

use ratatui::backend::TestBackend;
use ratatui::buffer::Buffer;
use ratatui::Frame;
use ratatui::Terminal;

// ─────────────────────────── primitives ───────────────────────────

/// Render `render` into a `width` x `height` buffer and hand it back.
pub fn render_to_buffer<F>(render: F, width: u16, height: u16) -> Buffer
where
    F: FnOnce(&mut Frame),
{
    let mut term = Terminal::new(TestBackend::new(width.max(1), height.max(1))).unwrap();
    term.draw(render).unwrap();
    term.backend().buffer().clone()
}

/// Dump a buffer as plain text: one line per row, trailing blanks trimmed.
///
/// The direct analogue of Codex's `snapshot_buffer`; use it in assertion
/// messages so a failure shows the screen instead of two bare integers.
pub fn snapshot_buffer(buf: &Buffer) -> String {
    let area = buf.area();
    (0..area.height)
        .map(|y| {
            let row: String = (0..area.width)
                .map(|x| buf[(area.x + x, area.y + y)].symbol())
                .collect();
            row.trim_end().to_string()
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// True when a cell has no visible ink (blank symbol, or nothing but spaces).
fn is_blank(sym: &str) -> bool {
    sym.trim().is_empty()
}

/// **The missing assertion primitive.** Render `render` into a `width` x `height`
/// buffer and return `last_non_blank_row + 1` — i.e. how many rows the widget
/// actually DREW into. `0` means it painted nothing.
///
/// Compare this against the row count the widget told the layout to reserve:
///   * `drawn > reserved` → the widget is clipped (rows silently dropped).
///   * `drawn < reserved` → dead space (blank rows, or bare decoration).
pub fn drawn_row_extent<F>(render: F, width: u16, height: u16) -> u16
where
    F: FnOnce(&mut Frame),
{
    let buf = render_to_buffer(render, width, height);
    buffer_row_extent(&buf, 0, width)
}

/// [`drawn_row_extent`] restricted to the half-open column range `x0..x1`.
///
/// Needed for widgets that paint full-height DECORATION in a gutter — OSA's
/// `Activity` fills a 2-column accent rail down the entire rect it is handed, so
/// a whole-width extent is always `height` and the invariant would be vacuous.
/// Measuring the CONTENT columns is what actually answers "how many rows of
/// content did this widget produce".
pub fn drawn_row_extent_in_cols<F>(render: F, width: u16, height: u16, x0: u16, x1: u16) -> u16
where
    F: FnOnce(&mut Frame),
{
    let buf = render_to_buffer(render, width, height);
    buffer_row_extent(&buf, x0, x1)
}

fn buffer_row_extent(buf: &Buffer, x0: u16, x1: u16) -> u16 {
    let area = *buf.area();
    let lo = x0.min(area.width);
    let hi = x1.min(area.width);
    for y in (0..area.height).rev() {
        let inked = (lo..hi).any(|x| !is_blank(buf[(area.x + x, area.y + y)].symbol()));
        if inked {
            return y + 1;
        }
    }
    0
}

/// The text of buffer row `y`, reconstructed the way a terminal would show it.
///
/// A wide glyph occupies ONE ratatui cell whose symbol is the glyph, followed by
/// `width-1` placeholder cells that ratatui fills with a space. Naively
/// concatenating every cell symbol therefore reports `模型` as 6 columns instead
/// of 4 — so the placeholders are skipped here.
pub fn buffer_row_text(buf: &Buffer, y: u16) -> String {
    let area = *buf.area();
    let mut out = String::new();
    let mut x = 0u16;
    while x < area.width {
        let sym = buf[(area.x + x, area.y + y)].symbol();
        out.push_str(sym);
        let w = crate::util::cols(sym).max(1) as u16;
        x += w;
    }
    out.trim_end().to_string()
}

// ─────────────────────── Activity invariants ───────────────────────

mod activity_invariants {
    use super::*;
    use crate::components::activity::{Activity, Verbosity};
    use crate::components::Component;

    const ALL_VERBOSITIES: [Verbosity; 4] = [
        Verbosity::Off,
        Verbosity::New,
        Verbosity::All,
        Verbosity::Verbose,
    ];

    /// Width used for every sweep: comfortably past the 2-column accent rail's
    /// `width > 10` threshold, so the rail is on and content starts at x=2.
    const W: u16 = 100;
    /// First content column (the rail owns 0 and its 1-column gutter owns 1).
    const CONTENT_X: u16 = 2;

    fn started(verbosity: Verbosity, a11y: bool) -> Activity {
        let mut act = Activity::new();
        act.start();
        act.verbosity = verbosity;
        act.set_a11y(a11y);
        act
    }

    /// Feed saturated well past every per-verbosity cap.
    fn saturated(verbosity: Verbosity, a11y: bool) -> Activity {
        let mut act = started(verbosity, a11y);
        for i in 0..20 {
            act.tool_start(&format!("tool{i}"), "{}");
        }
        act
    }

    /// Rows of CONTENT the activity actually paints when handed `rows` rows.
    fn drawn(act: &Activity, rows: u16) -> u16 {
        drawn_row_extent_in_cols(|f| act.draw(f, f.area()), W, rows.max(1), CONTENT_X, W)
    }

    fn screen(act: &Activity, rows: u16) -> String {
        snapshot_buffer(&render_to_buffer(
            |f| act.draw(f, f.area()),
            W,
            rows.max(1),
        ))
    }

    /// **Clipping half of the invariant.** `app::event_loop::draw_inline` hands the
    /// activity a rect of exactly `height()` rows (bottom-anchored inside the
    /// larger, verbosity-derived `max_height()` slot). Whatever `draw()` paints
    /// into that rect must fit: over-drawing means the oldest feed rows are
    /// silently dropped.
    #[test]
    fn activity_never_draws_past_the_rows_it_declared() {
        for verbosity in ALL_VERBOSITIES {
            for a11y in [false, true] {
                for act in [started(verbosity, a11y), saturated(verbosity, a11y)] {
                    let declared = act.height();
                    let reserved = act.max_height();
                    assert!(
                        declared <= reserved,
                        "{verbosity:?} (a11y={a11y}): height() {declared} exceeds the \
                         max_height() {reserved} slot the viewport reserves"
                    );
                    let drawn = drawn(&act, declared);
                    assert!(
                        drawn <= declared,
                        "{verbosity:?} (a11y={a11y}): declared {declared} rows but drew into \
                         {drawn} — the feed is clipped.\n{}",
                        screen(&act, declared)
                    );
                }
            }
        }
    }

    /// **LATENT HAZARD, pinned.** `Activity::draw` sizes its tool feed from the
    /// RECT it is handed (`budget = content.height - next_y`), not from its own
    /// `height()`. So the reserved-vs-drawn invariant above holds only because
    /// `draw_inline` is careful to pass exactly `height()` rows.
    ///
    /// Hand it a taller rect — which any future caller might, e.g. by passing the
    /// whole `max_height()` slot instead of bottom-anchoring inside it — and it
    /// happily paints feed rows all the way down, over whatever the layout gave
    /// to the widget below. This test records that behaviour so the coupling is
    /// visible and a change to it is loud rather than silent.
    ///
    /// The fix (in `components/activity.rs`, which this module does not own)
    /// would be for `draw` to clamp `content.height` to `self.height()`.
    #[test]
    fn activity_draw_is_rect_driven_not_reservation_driven() {
        let act = saturated(Verbosity::New, false);
        assert_eq!(act.height(), 2, "New declares 2 rows");
        let overdrawn = drawn(&act, 6);
        assert_eq!(
            overdrawn, 6,
            "handed 6 rows, `New` fills all 6 despite declaring 2.\n{}",
            screen(&act, 6)
        );
    }

    /// **Dead-space half of the invariant, saturated.** With the feed past every
    /// cap the per-frame `height()` must equal what is painted, exactly. Slack
    /// renders as blank rows (and, because the rail paints the full rect, as bare
    /// accent glyphs) between the spinner and the composer.
    #[test]
    fn activity_saturated_height_matches_what_it_draws() {
        for verbosity in ALL_VERBOSITIES {
            for a11y in [false, true] {
                let act = saturated(verbosity, a11y);
                let declared = act.height();
                let drawn = drawn(&act, declared);
                assert_eq!(
                    drawn, declared,
                    "{verbosity:?} (a11y={a11y}): height() says {declared} rows, draw() inked \
                     {drawn} — {} rows of dead space.\n{}",
                    declared as i32 - drawn as i32,
                    screen(&act, declared)
                );
            }
        }
    }

    /// **Dead-space half, empty feed.** A turn that has started but not yet run a
    /// tool is the single most common state on screen; its reservation must be
    /// honest too.
    ///
    /// `#[ignore]`d: this FAILS today and the fix belongs in
    /// `components/activity.rs`, which this module does not own.
    ///
    /// REAL BUG (Verbosity::New, empty feed): `height()` returns a hard-coded
    /// `2 + details`, but `draw()` paints the spinner row and then has nothing to
    /// put on row 1 — `visible_feed_count()` is 0 for an empty feed and the live
    /// tail is explicitly suppressed in `New`. Result: 1 permanently blank row
    /// carrying only a rail glyph, for the entire pre-first-tool phase of every
    /// turn in `New` mode. The fix is for the `New` arm of `height()` to use
    /// `1 + details + visible_feed_count()` like the `All`/`Verbose` arms do
    /// (`max_height()` may keep its constant 2 — that is a deliberate ceiling).
    #[test]
    #[ignore = "surfaces a real dead-space bug in Activity::height() for Verbosity::New; fix belongs in components/activity.rs"]
    fn activity_empty_feed_height_matches_what_it_draws() {
        for verbosity in ALL_VERBOSITIES {
            for a11y in [false, true] {
                let act = started(verbosity, a11y);
                let declared = act.height();
                let drawn = drawn(&act, declared);
                assert_eq!(
                    drawn, declared,
                    "{verbosity:?} (a11y={a11y}, empty feed): height() says {declared} rows, \
                     draw() inked {drawn}.\n{}",
                    screen(&act, declared)
                );
            }
        }
    }

    /// The regression above, pinned as a passing characterisation test so the
    /// suite records the current (wrong) behaviour and fails loudly the moment
    /// somebody fixes or worsens it.
    #[test]
    fn activity_new_verbosity_wastes_one_row_before_the_first_tool() {
        let act = started(Verbosity::New, false);
        assert_eq!(act.height(), 2, "height() reserves a constant 2 rows");
        assert_eq!(
            drawn(&act, 2),
            1,
            "…but only the spinner row is inked before the first tool.\n{}",
            screen(&act, 2)
        );
    }

    /// The `└ ` details block must be reserved by exactly as many rows as it
    /// paints, at the width it is painted at. `details_rows()` reads a
    /// `Cell<u16>` populated during the previous `draw()`, so this sweeps a
    /// second render to check the settled value — the shape of bug where a
    /// component is only correct after it has been drawn once.
    #[test]
    fn activity_details_block_is_reserved_exactly_as_drawn() {
        for lines in [1usize, 2, 3] {
            let mut act = started(Verbosity::Off, false);
            act.set_details(
                Some("running a fairly long command whose text wraps across the block".into()),
                lines,
            );
            // First draw settles `details_width`.
            let _ = drawn(&act, act.max_height() + 4);
            let declared = act.height();
            let painted = drawn(&act, declared);
            assert_eq!(
                painted, declared,
                "details(max_lines={lines}): reserved {declared}, drew {painted}.\n{}",
                screen(&act, declared)
            );
        }
    }

    /// **REAL BUG, pinned as `#[ignore]`.** The `└ ` details loop in
    /// `Activity::draw` double-advances its row cursor:
    ///
    /// ```ignore
    /// let mut next_y = content.y + 1;
    /// for (i, row) in ...enumerate() {
    ///     render_widget(.., Rect::new(content.x, next_y + i as u16, w, 1));
    ///     next_y = content.y + 1 + i as u16 + 1;   // <- also advances
    /// }
    /// ```
    ///
    /// `next_y` already moves down one row per iteration, and the `+ i` offset
    /// moves it again, so the painted row index is `1 + 2*i`, not `1 + i`:
    /// row 1, row 3, row 5 … With a details block of two or more wrapped lines
    /// this
    ///   1. leaves row 2 blank (dead space inside the block), and
    ///   2. writes at `content.y + 3` in a rect `height()` sized to 3 rows —
    ///      i.e. **outside the frame buffer**, which ratatui panics on
    ///      (`index outside of buffer`).
    ///
    /// The whole TUI process dies. It has not been seen in the wild only because
    /// `set_details` currently has no production caller — the block is
    /// implemented and reserved for (`details_rows()` feeds both `height()` and
    /// `max_height()`) but not yet wired up. The moment it is, any details text
    /// long enough to wrap crashes the app.
    ///
    /// Fix (in `components/activity.rs`, not owned by this module): drop the
    /// `+ i` and let `next_y` be the only cursor, or drop the `next_y`
    /// reassignment and let `+ i` be the only cursor. Also bound the write to
    /// `content.y + content.height`.
    #[test]
    // FIXED in components/activity.rs: the details loop now derives its row from `i` alone.
    fn activity_details_block_paints_consecutive_rows() {
        let mut act = started(Verbosity::Off, false);
        // Long enough to wrap to two rows at the content width.
        let long = "reading /very/long/path/to/a/source/file.rs and then summarising every \
                    single one of its public functions for the reasoning trace"
            .to_string();
        act.set_details(Some(long), 2);
        // Settle `details_width` with a generous first draw.
        let _ = drawn(&act, 12);
        let declared = act.height();
        assert_eq!(declared, 3, "spinner + 2 wrapped details rows");
        // Panics today: the second details row is written at y=3 of a 3-row rect.
        let painted = drawn(&act, declared);
        assert_eq!(
            painted, declared,
            "details rows must be consecutive.\n{}",
            screen(&act, declared)
        );
    }

    /// The live command tail shares the feed budget rather than extending it, so
    /// 200 lines of `make` output must not change how many rows are declared, nor
    /// leave any of the declared rows blank.
    #[test]
    fn activity_live_output_neither_grows_nor_hollows_the_slot() {
        for verbosity in ALL_VERBOSITIES {
            let mut act = started(verbosity, false);
            act.tool_start("Bash", r#"{"command":"make"}"#);
            let before = (act.height(), act.max_height());
            for i in 0..200 {
                act.push_command_output("make", &format!("compiling unit {i}\n"));
            }
            assert_eq!(
                (act.height(), act.max_height()),
                before,
                "{verbosity:?}: the live tail changed the reservation"
            );
            let declared = act.height();
            let drawn = drawn(&act, declared);
            assert_eq!(
                drawn, declared,
                "{verbosity:?}: declared {declared} rows, live tail + feed inked {drawn}.\n{}",
                screen(&act, declared)
            );
        }
    }

    /// A status line that renders the elapsed time twice is exactly the bug that
    /// shipped (`2m31s · 2m35s`). Pin it: the single status row may contain at
    /// most one `<n>s`-shaped duration token.
    #[test]
    fn activity_status_line_shows_exactly_one_timer() {
        for verbosity in ALL_VERBOSITIES {
            let mut act = started(verbosity, false);
            act.set_model_name("claude-opus");
            act.set_tokens(4000, 2000);
            let row = screen(&act, act.max_height().max(1))
                .lines()
                .next()
                .unwrap_or_default()
                .to_string();
            // Duration tokens look like `12s`, `2m31s`, `0.4s`, `0.4s...`.
            let timers = row
                .split_whitespace()
                .filter(|tok| {
                    let t = tok.trim_end_matches('.').trim_end_matches("...");
                    t.ends_with('s')
                        && t.chars()
                            .next()
                            .map(|c| c.is_ascii_digit())
                            .unwrap_or(false)
                        && t.chars().all(|c| c.is_ascii_digit() || matches!(c, 'm' | 's' | '.'))
                })
                .count();
            assert!(
                timers <= 1,
                "{verbosity:?}: status row shows {timers} durations, expected one: {row:?}"
            );
        }
    }
}

// ─────────────────── TaskChecklist / Agents invariants ───────────────────

mod panel_invariants {
    use super::*;
    use crate::components::agents::Agents;
    use crate::components::task_checklist::{ChecklistStatus, TaskChecklist};
    use crate::components::Component;

    const W: u16 = 100;

    /// `TaskChecklist::height()` is `items + 1` (header), capped. It bottom-anchors
    /// inside the rect it is given, so we hand it exactly its own height and the
    /// anchoring is a no-op — any gap is then genuine dead space.
    #[test]
    fn task_checklist_reserved_height_matches_what_it_draws() {
        for n in 1usize..=15 {
            let mut cl = TaskChecklist::new();
            for i in 0..n {
                cl.add(format!("t{i}"), format!("step number {i}"), None);
            }
            cl.update("t0", ChecklistStatus::InProgress);
            let reserved = cl.height();
            let drawn = drawn_row_extent(|f| cl.draw(f, f.area()), W, reserved);
            assert_eq!(
                drawn, reserved,
                "{n} items: reserved {reserved} rows, drew {drawn}.\n{}",
                snapshot_buffer(&render_to_buffer(|f| cl.draw(f, f.area()), W, reserved))
            );
        }
    }

    /// And it must not spill when handed MORE room than it asked for — the panel
    /// bottom-anchors, so measure from the bottom edge upward.
    #[test]
    fn task_checklist_never_exceeds_its_reserved_height() {
        for n in 1usize..=15 {
            let mut cl = TaskChecklist::new();
            for i in 0..n {
                cl.add(format!("t{i}"), format!("step number {i}"), None);
            }
            let reserved = cl.height();
            let area_h = reserved + 5;
            let buf = render_to_buffer(|f| cl.draw(f, f.area()), W, area_h);
            let first_inked = (0..area_h)
                .find(|&y| {
                    (0..W).any(|x| !super::is_blank(buf[(x, y)].symbol()))
                })
                .unwrap_or(area_h);
            let used = area_h - first_inked;
            assert!(
                used <= reserved,
                "{n} items: reserved {reserved} rows but occupied {used}.\n{}",
                snapshot_buffer(&buf)
            );
        }
    }

    /// The sweep above uses short, narrow, bare subjects — which is exactly why
    /// the sibling `Agents` overdraw shipped green: nothing in it could ever
    /// WRAP. Model-written task subjects are long prose, contain markdown and
    /// wide (CJK / emoji) glyphs, and are routinely far wider than the pane.
    ///
    /// The 1-row-per-item height contract only holds if `draw` fits every subject
    /// to the pane width; if it ever stopped, an item would take two rows and the
    /// panel would silently paint one row past its reservation — straight over
    /// whatever sits above it.
    #[test]
    fn task_checklist_reserved_height_holds_for_wrapping_content() {
        // Long prose, markdown markers, wide glyphs, and a subject with no spaces
        // (no wrap opportunity) — every shape that can defeat a naive fit.
        let subjects: [&str; 5] = [
            "Test invisible tasks fix — create tasks and verify they render in both TUIs, with no spiral and no duplicated blocks anywhere",
            "**Bold plan step** with `inline code` and _emphasis_ that must be stripped before it is measured",
            "検証する非常に長い日本語のタスクの説明であり、全角文字は一文字で二桁分の幅を占有します",
            "supercalifragilisticexpialidocious/no/word/break/anywhere/in/this/entire/subject/at/all/nope",
            "mixed 混在 content with emoji 🚀 and ascii tail that runs well past any sane pane width",
        ];
        for &width in &[24u16, 40, 60, 100, 200] {
            for n in 1usize..=15 {
                let mut cl = TaskChecklist::new();
                for i in 0..n {
                    cl.add(format!("t{i}"), subjects[i % subjects.len()].to_string(), None);
                }
                cl.update("t0", ChecklistStatus::InProgress);
                if n > 1 {
                    cl.update("t1", ChecklistStatus::Completed);
                }
                let reserved = cl.height();
                let drawn = drawn_row_extent(|f| cl.draw(f, f.area()), width, reserved);
                assert_eq!(
                    drawn, reserved,
                    "w={width}, {n} wide items: reserved {reserved} rows, drew {drawn}.\n{}",
                    snapshot_buffer(&render_to_buffer(|f| cl.draw(f, f.area()), width, reserved))
                );

                // And handed MORE room, it must still occupy only `reserved` rows
                // measured from the bottom (it bottom-anchors).
                let area_h = reserved + 4;
                let buf = render_to_buffer(|f| cl.draw(f, f.area()), width, area_h);
                let first_inked = (0..area_h)
                    .find(|&y| (0..width).any(|x| !super::is_blank(buf[(x, y)].symbol())))
                    .unwrap_or(area_h);
                assert!(
                    area_h - first_inked <= reserved,
                    "w={width}, {n} wide items: reserved {reserved} but occupied {}.\n{}",
                    area_h - first_inked,
                    snapshot_buffer(&buf)
                );
            }
        }
    }

    /// No item line may exceed the pane width — a line wider than the pane is what
    /// a `Paragraph` would wrap (or hard-clip mid-word) and is the precondition for
    /// an item taking two rows.
    #[test]
    fn task_checklist_item_rows_never_exceed_the_pane_width() {
        for &width in &[20u16, 33, 48, 81] {
            let mut cl = TaskChecklist::new();
            for i in 0..6 {
                cl.add(
                    format!("t{i}"),
                    format!(
                        "step {i}: a deliberately overlong 混在 subject 🚀 that cannot fit in a narrow pane at all"
                    ),
                    None,
                );
            }
            let h = cl.height();
            let buf = render_to_buffer(|f| cl.draw(f, f.area()), width, h);
            for y in 0..h {
                let text = buffer_row_text(&buf, y);
                assert!(
                    crate::util::cols(&text) <= width as usize,
                    "w={width} row {y} is {} cols: {text:?}",
                    crate::util::cols(&text)
                );
            }
        }
    }

    /// **The regression that shipped.** `draw_inline` used to hand the checklist
    /// the SAME rect it had just handed `Chat::draw_live`, so a plan painted
    /// straight over the streaming reply (a checklist row landing mid-way through
    /// a rendered markdown table row). The checklist now owns a band; the split
    /// must keep the two disjoint at every size.
    #[test]
    fn checklist_band_never_shares_a_row_with_the_stream_band() {
        use crate::app::event_loop::{
            fit_bands, inline_split, Bands, ROW_CHECKLIST, ROW_STREAM,
        };
        use ratatui::layout::Rect;

        for area_h in 8u16..=40 {
            for n in 1usize..=15 {
                let mut cl = TaskChecklist::new();
                for i in 0..n {
                    cl.add(format!("t{i}"), format!("step {i}"), None);
                }
                let think_h = 3u16;
                let agents_h = 0u16;
                let input_h = 3u16;
                let want = Bands {
                    checklist: cl.height(),
                    think: think_h,
                    agents: agents_h,
                    survey: 0,
                    input: input_h,
                    ..Default::default()
                };
                let bands = fit_bands(want, area_h);
                let area = Rect::new(0, 0, W, area_h);
                let rows = inline_split(area, bands);
                let stream = rows[ROW_STREAM];
                let list = rows[ROW_CHECKLIST];
                assert_eq!(
                    stream.intersection(list).height,
                    0,
                    "h={area_h}, {n} items: stream {stream:?} overlaps checklist {list:?}"
                );
                // The chrome below must survive: the composer never gets starved
                // to nothing by a long plan.
                assert!(
                    rows[crate::app::event_loop::ROW_INPUT].height >= 1,
                    "h={area_h}, {n} items: composer starved to 0 rows"
                );
                // The disjointness assertion above is satisfied trivially at
                // heights where the arbiter has shed the checklist to zero, so
                // pin the two things that stay load-bearing there: the stream
                // keeps its floor, and the checklist is only ever shed under
                // real pressure — never while there is room for it.
                assert!(
                    stream.height >= crate::app::event_loop::STREAM_FLOOR,
                    "h={area_h}, {n} items: stream band starved below its floor"
                );
                if want.capped().reserved() + crate::app::event_loop::STREAM_FLOOR <= area_h {
                    assert_eq!(
                        list.height,
                        cl.height().min(crate::app::event_loop::CHECKLIST_INLINE_CAP),
                        "h={area_h}, {n} items: the plan band was shed with room to spare"
                    );
                }
            }
        }
    }

    /// Ink proof of the same thing: fill the stream band, draw the checklist into
    /// its own band, and the stream band's content must come out untouched.
    #[test]
    fn drawing_the_checklist_does_not_erase_the_stream_band() {
        use crate::app::event_loop::{
            fit_bands, inline_split, Bands, ROW_CHECKLIST, ROW_STREAM,
        };
        use ratatui::layout::Rect;
        use ratatui::widgets::Paragraph;

        let area_h = 24u16;
        let mut cl = TaskChecklist::new();
        for i in 0..4 {
            cl.add(format!("t{i}"), format!("plan step {i}"), None);
        }
        let (think_h, agents_h, input_h) = (3u16, 0u16, 3u16);
        let bands = fit_bands(
            Bands {
                checklist: cl.height(),
                think: think_h,
                agents: agents_h,
                survey: 0,
                input: input_h,
                ..Default::default()
            },
            area_h,
        );
        assert!(bands.checklist > 0, "checklist must reserve a band");

        let buf = render_to_buffer(
            |f| {
                let area = Rect::new(0, 0, W, area_h);
                let rows = inline_split(area, bands);
                // Stand in for a streaming markdown table.
                let filler: Vec<ratatui::text::Line<'static>> = (0..rows[ROW_STREAM].height)
                    .map(|_| ratatui::text::Line::from("│ table cell │ table cell │"))
                    .collect();
                f.render_widget(Paragraph::new(filler), rows[ROW_STREAM]);
                cl.draw(f, rows[ROW_CHECKLIST]);
            },
            W,
            area_h,
        );

        let rows = inline_split(Rect::new(0, 0, W, area_h), bands);
        for y in rows[ROW_STREAM].y..(rows[ROW_STREAM].y + rows[ROW_STREAM].height) {
            let text = buffer_row_text(&buf, y);
            assert!(
                text.starts_with("│ table cell │"),
                "stream row {y} was overpainted: {text:?}\n{}",
                snapshot_buffer(&buf)
            );
        }
        // …and the checklist really did paint into its own band.
        let list_text = buffer_row_text(&buf, rows[ROW_CHECKLIST].y);
        assert!(list_text.starts_with("Plan"), "got {list_text:?}\n{}", snapshot_buffer(&buf));
    }

    /// **The turn-completion defect.** With a plan on screen, the FINAL response
    /// came out short with the plan block sitting where the rest of it should
    /// have been. Root cause: `streaming_inline_height` built its `want` from the
    /// chrome + `STREAM_PREVIEW_ROWS` only, then `clamp(base, hi)`ed it. The
    /// checklist's rows were in `base` but not in `want`, and because `want >
    /// base` in the normal case the clamp returned `want` — so the reservation
    /// silently lost the plan's height while `draw_inline` still carved the band
    /// out of the same area. The streaming preview absorbed the whole deficit.
    ///
    /// The invariant: whatever the plan's height, the stream band must still get
    /// its full `STREAM_PREVIEW_ROWS` out of the reserved viewport.
    #[test]
    fn a_visible_plan_never_steals_rows_from_the_streaming_reply() {
        use crate::app::event_loop::{
            fit_bands, inline_split, Bands, streaming_inline_height, ROW_STREAM,
            STREAM_PREVIEW_ROWS,
        };
        use ratatui::layout::Rect;

        let term_rows = 60u16;
        let hi = term_rows - 1;
        let (think_h, agents_h, input_h) = (1u16, 0u16, 3u16);
        let overhead = think_h + 1 + 2; // activity + ctx hint + status
        let base = 6u16;

        for n in 1usize..=12 {
            let mut cl = TaskChecklist::new();
            for i in 0..n {
                cl.add(format!("t{i}"), format!("step {i}"), None);
            }
            let want_checklist = cl.height().min(12);
            let area_h = streaming_inline_height(
                base.saturating_add(want_checklist),
                overhead,
                input_h,
                agents_h,
                want_checklist,
                0,
                STREAM_PREVIEW_ROWS,
                hi,
            );
            let area = Rect::new(0, 0, W, area_h);
            let bands = fit_bands(
                Bands {
                    checklist: want_checklist,
                    think: think_h,
                    agents: agents_h,
                    survey: 0,
                    input: input_h,
                    ..Default::default()
                },
                area_h,
            );
            let checklist_h = bands.checklist;
            let rows = inline_split(area, bands);
            assert_eq!(
                checklist_h, want_checklist,
                "{n} tasks: the plan band was squeezed ({want_checklist} → {checklist_h})"
            );
            assert!(
                rows[ROW_STREAM].height >= STREAM_PREVIEW_ROWS,
                "{n} tasks: the plan ate the reply — stream band is {} rows, \
                 needs {STREAM_PREVIEW_ROWS}",
                rows[ROW_STREAM].height
            );
        }
    }

    /// Ink proof of the same thing at TURN COMPLETION: the final assistant block
    /// occupies the stream band while the plan sits in its own, and every row of
    /// the committed text must survive verbatim.
    #[test]
    fn a_committed_final_block_survives_beside_the_plan_band() {
        use crate::app::event_loop::{
            fit_bands, inline_split, Bands, streaming_inline_height, ROW_CHECKLIST,
            ROW_STREAM,
        };
        use ratatui::layout::Rect;
        use ratatui::widgets::Paragraph;

        let mut cl = TaskChecklist::new();
        for i in 0..5 {
            cl.add(format!("t{i}"), format!("plan step {i}"), None);
        }
        let (think_h, agents_h, input_h) = (1u16, 0u16, 3u16);
        let want_checklist = cl.height().min(12);
        let area_h = streaming_inline_height(
            6 + want_checklist,
            think_h + 1 + 2,
            input_h,
            agents_h,
            want_checklist,
            0,
            crate::app::event_loop::STREAM_PREVIEW_ROWS,
            59,
        );
        let bands = fit_bands(
            Bands {
                checklist: want_checklist,
                think: think_h,
                agents: agents_h,
                survey: 0,
                input: input_h,
                ..Default::default()
            },
            area_h,
        );
        let area = Rect::new(0, 0, W, area_h);
        let rows = inline_split(area, bands);

        let final_text = "The parser rewrite is done; here is what changed and why.";
        let buf = render_to_buffer(
            |f| {
                let lines: Vec<ratatui::text::Line<'static>> = (0..rows[ROW_STREAM].height)
                    .map(|_| ratatui::text::Line::from(final_text))
                    .collect();
                f.render_widget(Paragraph::new(lines), rows[ROW_STREAM]);
                cl.draw(f, rows[ROW_CHECKLIST]);
            },
            W,
            area_h,
        );
        for y in rows[ROW_STREAM].y..(rows[ROW_STREAM].y + rows[ROW_STREAM].height) {
            assert_eq!(
                buffer_row_text(&buf, y).trim_end(),
                final_text,
                "final-response row {y} was clobbered by the plan band\n{}",
                snapshot_buffer(&buf)
            );
        }
        assert!(
            buffer_row_text(&buf, rows[ROW_CHECKLIST].y).starts_with("Plan"),
            "the plan must still render in its own band\n{}",
            snapshot_buffer(&buf)
        );
    }

    /// An invisible checklist must paint nothing at all, so the caller's `0`-row
    /// reservation is honest.
    #[test]
    fn hidden_task_checklist_draws_nothing() {
        let mut cl = TaskChecklist::new();
        cl.add("a".into(), "step".into(), None);
        cl.hide();
        assert_eq!(drawn_row_extent(|f| cl.draw(f, f.area()), W, 8), 0);
    }

    fn roster(n: usize) -> Agents {
        let mut a = Agents::new();
        for i in 0..n {
            a.agent_started(
                &format!("worker-{i}"),
                "researcher",
                "",
                &format!("scan module {i}"),
                None,
            );
        }
        a
    }

    /// `Agents::height()` drives the fleet panel's reservation. Sweep roster sizes
    /// across (and past) the `INLINE_ROSTER_MAX_AGENTS` overflow boundary.
    #[test]
    fn agents_never_draws_past_its_reserved_height() {
        for n in 0usize..=12 {
            let a = roster(n);
            let reserved = a.height();
            if reserved == 0 {
                assert_eq!(
                    drawn_row_extent(|f| a.draw(f, f.area()), W, 4),
                    0,
                    "{n} agents: reserved 0 rows but painted something"
                );
                continue;
            }
            let probe = reserved + 4;
            let drawn = drawn_row_extent(|f| a.draw(f, f.area()), W, probe);
            assert!(
                drawn <= reserved,
                "{n} agents: reserved {reserved} rows but drew into {drawn}.\n{}",
                snapshot_buffer(&render_to_buffer(|f| a.draw(f, f.area()), W, probe))
            );
        }
    }

    /// The other direction: the reservation must not be wastefully larger than
    /// the paint.
    ///
    /// ALLOWANCE for a deliberate trailing spacer row, in rows.
    ///
    /// Set to **0**: `Agents` is currently exact at every roster size swept below,
    /// including across the `INLINE_ROSTER_MAX_AGENTS` overflow boundary, so no
    /// slack is granted. The knob exists (rather than the literal being inlined)
    /// because a future design that intentionally puts a blank spacer under the
    /// roster should raise it *explicitly and with a comment* rather than quietly
    /// weakening the assertion.
    const AGENTS_ALLOWED_TRAILING_BLANK: u16 = 0;

    #[test]
    fn agents_reserved_height_is_not_wastefully_larger_than_drawn() {
        for n in 1usize..=12 {
            let a = roster(n);
            let reserved = a.height();
            let drawn = drawn_row_extent(|f| a.draw(f, f.area()), W, reserved);
            assert!(
                reserved.saturating_sub(drawn) <= AGENTS_ALLOWED_TRAILING_BLANK,
                "{n} agents: reserved {reserved} rows, drew {drawn} — {} rows of dead space \
                 (allowance {AGENTS_ALLOWED_TRAILING_BLANK}).\n{}",
                reserved - drawn,
                snapshot_buffer(&render_to_buffer(|f| a.draw(f, f.area()), W, reserved))
            );
        }
    }

    // ───────────────────── fleet-view (multi-agent) invariants ─────────────────
    //
    // The multi-agent view reintroduced the exact regression the Activity status
    // line had already been fixed for: FOUR live durations on screen at once
    // (turn clock on the status line, the SAME turn clock on the `main` roster
    // row in a DIFFERENT format, the delegate feed line's running timer, and each
    // worker's own age). It shipped test-green because nothing counted timers on
    // the fleet surface. These pin it.

    /// Duration-shaped tokens in one rendered row: `12s`, `54s`, `1m02s`,
    /// `1m 02s`, `10m 25s`, `0.4s`, `0.4s...`, `1h 05m 22s`.
    ///
    /// Spaced forms (`1m 02s`) are joined before counting so `1m` + `02s` is ONE
    /// timer, not two — otherwise the assertion would be trivially satisfied by
    /// switching formats, which is itself one of the defects (the fleet view was
    /// rendering `1m02s` and `1m 02s` for the same clock).
    fn duration_tokens(row: &str) -> Vec<String> {
        fn is_duration(tok: &str) -> bool {
            let t = tok.trim_end_matches('.');
            !t.is_empty()
                && t.ends_with(|c| matches!(c, 's' | 'm' | 'h'))
                && t.starts_with(|c: char| c.is_ascii_digit())
                && t.chars().all(|c| c.is_ascii_digit() || matches!(c, 'h' | 'm' | 's' | '.'))
        }
        let toks: Vec<&str> = row.split_whitespace().collect();
        let mut out: Vec<String> = Vec::new();
        let mut i = 0usize;
        while i < toks.len() {
            if is_duration(toks[i]) {
                // Absorb the continuation halves of a spaced duration.
                let mut joined = toks[i].to_string();
                while i + 1 < toks.len() && is_duration(toks[i + 1]) {
                    joined.push_str(toks[i + 1]);
                    i += 1;
                }
                out.push(joined);
            }
            i += 1;
        }
        out
    }

    /// A running fleet: `main` carrying the turn elapsed, plus workers each with
    /// their own age and a child action trail.
    fn running_fleet(n: usize, turn_secs: u64) -> Agents {
        let mut a = Agents::new();
        a.set_main_row("shipping the fleet view", turn_secs, 678);
        for i in 0..n {
            a.agent_started(
                &format!("agent:session-1785539672538-b5473d40b767:osa-explorer-{i}"),
                "explorer",
                "",
                &format!("scan module {i}"),
                None,
            );
            a.agent_progress(
                &format!("agent:session-1785539672538-b5473d40b767:osa-explorer-{i}"),
                "dir_list",
                6,
                0,
                "",
                vec![
                    "dir_list".into(),
                    "dir_list".into(),
                    "file_glob: /w/codex".into(),
                    "dir_list: /w/codex".into(),
                ],
            );
        }
        a
    }

    /// **The multi-timer assertion.** Sweeping the agent count, NO row of the
    /// fleet panel may carry more than one duration, and the roster root (`main`)
    /// must carry none at all — its elapsed IS the turn clock the activity status
    /// line already owns, and one turn gets exactly one clock.
    #[test]
    fn fleet_view_rows_show_at_most_one_duration_and_main_shows_none() {
        for n in 1usize..=6 {
            let a = running_fleet(n, 62); // 62s → "1m02s" / "1m 02s"
            let buf = render_to_buffer(|f| a.draw(f, f.area()), W, a.height().max(1));
            for row in snapshot_buffer(&buf).lines() {
                let timers = duration_tokens(row);
                assert!(
                    timers.len() <= 1,
                    "{n} agents: fleet row shows {} durations {timers:?}: {row:?}",
                    timers.len()
                );
                if row.contains("main") {
                    assert!(
                        timers.is_empty(),
                        "{n} agents: the `main` roster row must not restate the turn \
                         clock (found {timers:?}): {row:?}"
                    );
                }
            }
        }
    }

    /// The turn clock must be rendered in exactly one FORMAT too. `1m02s` (the
    /// status line) and `1m 02s` (the old `main` row) are the same 62 seconds
    /// spelled two ways, which is what made the panel read as broken.
    #[test]
    fn fleet_view_never_renders_the_turn_clock_in_a_second_format() {
        let a = running_fleet(2, 62);
        let screen = snapshot_buffer(&render_to_buffer(
            |f| a.draw(f, f.area()),
            W,
            a.height().max(1),
        ));
        assert!(
            !screen.contains("1m02s") && !screen.contains("1m 02s"),
            "the fleet panel must not render the turn elapsed at all:\n{screen}"
        );
    }

    /// One agent's child list is a bounded status strip, not a log: it may never
    /// exceed `TRAIL_MAX_ROWS` (the `All`-verbosity feed ceiling in
    /// `Activity::max_height`), and it may not repeat the row's own label.
    #[test]
    fn fleet_view_child_list_is_bounded_and_deduplicated() {
        let a = running_fleet(1, 30);
        let reserved = a.height();
        let screen = snapshot_buffer(&render_to_buffer(|f| a.draw(f, f.area()), W, reserved));
        // header + main + 1 agent row + at most TRAIL_MAX_ROWS children.
        let child_rows = screen
            .lines()
            .filter(|l| l.trim_start().starts_with('\u{2514}') || l.contains("\u{2502}  \u{2514}"))
            .count();
        assert!(
            child_rows <= crate::components::agents::TRAIL_MAX_ROWS,
            "child list drew {child_rows} rows, ceiling is {}:\n{screen}",
            crate::components::agents::TRAIL_MAX_ROWS
        );
        // The agent row already says `dir_list`; a child must not repeat it bare.
        let bare_repeats = screen
            .lines()
            .filter(|l| l.trim_end().ends_with("\u{2514}\u{2500} dir_list"))
            .count();
        assert_eq!(
            bare_repeats, 0,
            "child list repeats the row's own current-action label:\n{screen}"
        );
    }

    /// Reserved-vs-drawn across the same agent-count sweep, with the trail and
    /// `main` row populated — the shape the capture actually showed (the existing
    /// sweep uses bare `agent_started` rows with no progress trail).
    #[test]
    fn fleet_view_with_trails_never_draws_past_its_reservation() {
        for n in 0usize..=12 {
            let a = running_fleet(n, 45);
            let reserved = a.height();
            let probe = reserved + 6;
            let drawn = drawn_row_extent(|f| a.draw(f, f.area()), W, probe);
            assert!(
                drawn <= reserved,
                "{n} agents: reserved {reserved} rows but drew into {drawn}.\n{}",
                snapshot_buffer(&render_to_buffer(|f| a.draw(f, f.area()), W, probe))
            );
            assert!(
                reserved.saturating_sub(drawn) <= AGENTS_ALLOWED_TRAILING_BLANK,
                "{n} agents: reserved {reserved} rows, drew {drawn} — dead space.\n{}",
                snapshot_buffer(&render_to_buffer(|f| a.draw(f, f.area()), W, reserved))
            );
        }
    }

    /// The internal routing key must never reach the screen: it is meaningless to
    /// a reader and long enough to push the interrupt hint off the status line.
    #[test]
    fn fleet_view_shows_short_agent_labels_not_routing_keys() {
        let a = running_fleet(2, 20);
        let screen = snapshot_buffer(&render_to_buffer(
            |f| a.draw(f, f.area()),
            W,
            a.height().max(1),
        ));
        assert!(
            !screen.contains("session-1785539672538"),
            "raw routing key leaked into the fleet panel:\n{screen}"
        );
        assert!(
            screen.contains("explorer"),
            "the short human label is missing:\n{screen}"
        );
    }

    /// A fleet grouped into a real backend batch, whose id is the internal
    /// routing key the orchestrator actually mints.
    fn batched_fleet(batch: &str) -> Agents {
        let mut a = Agents::new();
        a.set_main_row("shipping the fleet view", 40, 678);
        for i in 0..2 {
            let name = format!("agent:session-1785550977551-3f4a8179a573:osa-verifier-{i}");
            a.agent_started(&name, "goal-verifier-skeptic", "", "verify the goal", Some(batch.to_string()));
            a.agent_progress(
                &name,
                "dir_list: /Users/rhl/.osa/workspace/src",
                9,
                0,
                "",
                vec![
                    "dir_list".into(),
                    "file_read".into(),
                    "file_read: /Users/rhl/.osa/backend.log".into(),
                ],
            );
        }
        a
    }

    /// A fleet split across SEVERAL backend batches — the only case in which a
    /// separator rule has anything to separate.
    fn multi_batch_fleet(batches: &[&str]) -> Agents {
        let mut a = Agents::new();
        a.set_main_row("shipping the fleet view", 40, 678);
        for (b, batch) in batches.iter().enumerate() {
            for i in 0..2 {
                let name = format!("agent:session-1785550977551-3f4a8179a573:osa-verifier-{b}-{i}");
                a.agent_started(
                    &name,
                    "goal-verifier-skeptic",
                    "",
                    "verify the goal",
                    Some((*batch).to_string()),
                );
            }
        }
        a
    }

    /// Rows that are a full-width batch separator rule.
    fn batch_rules(screen: &str) -> Vec<String> {
        screen
            .lines()
            .filter(|l| l.trim_start().starts_with("\u{2500}\u{2500}\u{2500}"))
            .map(|l| l.trim_end().to_string())
            .collect()
    }

    /// **DEFECT 1.** The batch header may never print a session id. It is the
    /// widest single string the panel handles and it consumes the whole
    /// separator row to say nothing a reader can act on.
    #[test]
    fn fleet_view_batch_header_never_shows_a_session_id() {
        let a = multi_batch_fleet(&[
            "team:session-1785550977551-3f4a8179a573:207491",
            "team:session-1785550977551-3f4a8179a573:207492",
        ]);
        let screen = snapshot_buffer(&render_to_buffer(
            |f| a.draw(f, f.area()),
            W,
            a.height().max(1),
        ));
        assert!(
            screen.contains("Batch 1"),
            "the batch header lost its ordinal:\n{screen}"
        );
        for leak in ["session-", "1785550977551", "3f4a8179a573", "207491"] {
            assert!(
                !screen.contains(leak),
                "routing-key fragment {leak:?} reached the batch header:\n{screen}"
            );
        }
    }

    /// **DEFECT 1, the degenerate case the capture caught.** After the routing
    /// key's id-shaped segments are stripped, the only survivor is often the
    /// generic noun the heading already says — `Batch 1: batch`. A label that
    /// restates its own heading is pure width, so the ordinal must stand alone.
    #[test]
    fn fleet_view_batch_header_drops_a_label_that_only_restates_the_heading() {
        for noise in ["batch", "team", "group", "run", "task", "session", "Batch", "TEAM"] {
            let id = format!("{noise}:session-1785550977551-3f4a8179a573:207491");
            let a = multi_batch_fleet(&[&id, "alpha"]);
            let screen = snapshot_buffer(&render_to_buffer(
                |f| a.draw(f, f.area()),
                W,
                a.height().max(1),
            ));
            let rules = batch_rules(&screen);
            assert!(!rules.is_empty(), "{noise}: no batch rule drawn:\n{screen}");
            assert!(
                !rules[0].contains(':'),
                "{noise}: a noise-word label survived onto the rule: {:?}\n{screen}",
                rules[0]
            );
            assert!(
                rules[0].contains("Batch 1"),
                "{noise}: the ordinal must survive alone: {:?}\n{screen}",
                rules[0]
            );
        }
    }

    /// **DEFECT 1, structural.** A separator rule must have something to
    /// separate. With every agent in ONE batch the rule was drawing a full-width
    /// line directly under the roster header whose only content restated that
    /// header — a whole scarce row spent on decoration.
    #[test]
    fn fleet_view_draws_no_batch_rule_for_a_single_group() {
        let a = batched_fleet("team:session-1785550977551-3f4a8179a573:207491");
        let reserved = a.height().max(1);
        let screen = snapshot_buffer(&render_to_buffer(|f| a.draw(f, f.area()), W, reserved));
        assert!(
            batch_rules(&screen).is_empty(),
            "a single group must not draw a separator rule:\n{screen}"
        );
        // …and the reservation must agree, or the panel leaves a dead row.
        assert_eq!(
            drawn_row_extent(|f| a.draw(f, f.area()), W, reserved),
            reserved,
            "reserved {reserved} rows but the drawn extent disagrees:\n{screen}"
        );
    }

    /// A batch id that IS a word keeps it — only the machine-shaped segments and
    /// the generic nouns are dropped, so a meaningful team name still labels its
    /// section. The rule also carries the group's size, which is what earns it a
    /// row at all.
    #[test]
    fn fleet_view_batch_header_keeps_a_human_label_and_a_count() {
        let a = multi_batch_fleet(&["alpha", "beta"]);
        let screen = snapshot_buffer(&render_to_buffer(
            |f| a.draw(f, f.area()),
            W,
            a.height().max(1),
        ));
        assert!(
            screen.contains("Batch 1: alpha"),
            "a human batch name must survive:\n{screen}"
        );
        assert!(
            screen.contains("2 agents"),
            "the rule must carry the group size, or it is decoration:\n{screen}"
        );
    }

    /// Every child-trail row of a running agent, and the row's own action label.
    /// A trail row looks like `   └─ <text>` or `│  └─ <text>`.
    fn trail_texts(screen: &str) -> Vec<String> {
        screen
            .lines()
            .filter_map(|l| l.split_once("\u{2514}\u{2500} "))
            .map(|(_, rest)| rest.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect()
    }

    /// **DEFECT 3.** No trail entry may be a bare tool verb. The backend records
    /// each call twice — `file_read: <path>` on start and a naked `file_read` on
    /// end — and the naked half identifies nothing, so it must not reach a row of
    /// its own. Entries that survive all carry their value.
    #[test]
    fn fleet_view_trail_entries_all_carry_a_detail() {
        let a = batched_fleet("team:session-1785550977551-3f4a8179a573:207491");
        let screen = snapshot_buffer(&render_to_buffer(
            |f| a.draw(f, f.area()),
            W,
            a.height().max(1),
        ));
        let trail = trail_texts(&screen);
        assert!(!trail.is_empty(), "no trail rows drawn at all:\n{screen}");
        for t in &trail {
            // The counter line is the one legitimate non-action row.
            if t.contains("tool uses") {
                continue;
            }
            assert!(
                crate::components::agents::action_has_detail(t),
                "trail row {t:?} is a bare verb with no identifying value:\n{screen}"
            );
        }
    }

    /// **DEFECT 4.** The overflow counter stands for the calls that happened
    /// BEFORE the visible entries (the trail is drawn oldest → newest), so it
    /// belongs at the top of the block — and it must SAY so ("earlier", not the
    /// old "+N more tool uses", which read as a trailing overflow indicator
    /// printed above the very items it summarized).
    ///
    /// It no longer takes a ROW, though: a bookkeeping number rendered at the
    /// same weight as the work itself read as a peer of that work, and cost one
    /// row per agent in the scarcest region of the screen. It is now a quiet
    /// prefix on the oldest visible trail row — same chronological position,
    /// zero rows.
    #[test]
    fn fleet_view_overflow_counter_is_framed_as_earlier_work() {
        let a = batched_fleet("team:session-1785550977551-3f4a8179a573:207491");
        let screen = snapshot_buffer(&render_to_buffer(
            |f| a.draw(f, f.area()),
            W,
            a.height().max(1),
        ));
        let trail = trail_texts(&screen);
        let counter = trail
            .iter()
            .position(|t| t.contains("earlier"))
            .unwrap_or_else(|| panic!("no overflow counter drawn:\n{screen}"));
        // It rides the FIRST (oldest) visible row, not a row of its own.
        assert_eq!(
            counter, 0,
            "the counter must prefix the oldest visible entry, got {trail:?}:\n{screen}"
        );
        assert!(
            trail[0].contains('\u{00b7}') && trail[0].len() > "+8 earlier \u{00b7} ".len(),
            "the counter must be a PREFIX on a real action row, got {:?}:\n{screen}",
            trail[0]
        );
        assert!(
            !screen.contains("more tool uses"),
            "the unframed 'more tool uses' wording is back:\n{screen}"
        );
        // It heads its own block: the row directly after it is a real action.
        assert!(
            trail
                .get(counter + 1)
                .map(|t| !t.contains("tool uses"))
                .unwrap_or(false),
            "the counter must be followed by the actions it precedes:\n{screen}"
        );
    }

    // ─────────────────── the captured scene (v1.0.052) ────────────────────
    //
    // The user's screenshot, reproduced exactly: two sub-agents under one batch,
    // each walking sibling directories deep inside the agent sandbox, `main`
    // carrying nothing but a token count. Every assertion below is a defect that
    // capture showed.

    /// Two explorers listing three sibling directories under
    /// `~/.osa/workspace/codex/codex-rs/` — the exact trail from the capture.
    fn captured_scene() -> Agents {
        let mut a = Agents::new();
        a.set_workspace_root("/Users/rhl/projects/osa");
        // `display_path`'s home tier is what fires for the sandbox, so the
        // fixture must pin HOME rather than inherit the test runner's.
        unsafe { std::env::set_var("HOME", "/Users/rhl") };
        a.set_workspace_root("/Users/rhl/projects/osa");
        // No goal → `main` has nothing of its own to say.
        a.set_main_row("", 231, 2_800);
        for i in 0..2 {
            let name = format!("agent:session-1785539672538-b5473d40b767:osa-explorer-{i}");
            a.agent_started(&name, "explorer", "", "compare the two agents", Some("batch:207491".into()));
            a.agent_progress(
                &name,
                "dir_list",
                11,
                0,
                "",
                vec![
                    "dir_list: /Users/rhl/.osa/workspace/codex/codex-rs/exec-server".into(),
                    "dir_list: /Users/rhl/.osa/workspace/codex/codex-rs/sandboxing".into(),
                    "dir_list: /Users/rhl/.osa/workspace/codex/codex-rs/hooks".into(),
                ],
            );
        }
        a
    }

    /// **DEFECT 2.** Absolute paths under a known root are rewritten to the form
    /// the user would type, and the directory head a row shares with the row
    /// above it collapses to `…/` — so the differing tail, the only part that
    /// carries information, lands at a shallow fixed column instead of past
    /// column 40 on every line.
    #[test]
    fn fleet_view_trail_paths_are_workspace_relative_and_elide_shared_prefixes() {
        let a = captured_scene();
        let screen = snapshot_buffer(&render_to_buffer(
            |f| a.draw(f, f.area()),
            W,
            a.height().max(1),
        ));
        assert!(
            !screen.contains("/Users/rhl"),
            "a fully-qualified path reached the trail:\n{screen}"
        );
        let trail = trail_texts(&screen);
        // `recent_actions` is newest-first and `trail_actions` flips it, so the
        // OLDEST call heads the block. It states the path in full (relative);
        // every sibling after it elides.
        assert!(
            trail
                .iter()
                .any(|t| t.contains("codex/codex-rs/hooks") && !t.contains('\u{2026}')),
            "the oldest row must state the path in full, got {trail:?}:\n{screen}"
        );
        let elided = trail.iter().filter(|t| t.contains("\u{2026}/")).count();
        assert!(
            elided >= 2,
            "sibling rows must elide their shared head, got {trail:?}:\n{screen}"
        );
        // Elision never hides WHICH tool ran, and never doubles up.
        for t in &trail {
            assert!(
                !t.contains("\u{2026}/\u{2026}"),
                "double elision in {t:?}:\n{screen}"
            );
        }
    }

    /// **DEFECT 5 + the detail-per-surface rule.** The delegation is described by
    /// three neighbouring surfaces (roster header, `main` row, roster tree). Each
    /// may state its own fact once; none may restate another's.
    #[test]
    fn no_fleet_surface_restates_another() {
        let a = captured_scene();
        let screen = snapshot_buffer(&render_to_buffer(
            |f| a.draw(f, f.area()),
            W,
            a.height().max(1),
        ));
        // The agent count is stated exactly once, by the header that owns it.
        assert_eq!(
            screen.matches("2 agents").count(),
            1,
            "the fleet size is stated more than once:\n{screen}"
        );
        // `main` earns no row here: no goal, not selected. Its one fact (session
        // tokens) moved onto the header.
        assert!(
            !screen.lines().any(|l| l.trim_start().starts_with("\u{25cf} main")),
            "the empty `main` row is back:\n{screen}"
        );
        assert!(
            screen.contains("\u{2193}2.8k"),
            "the folded session tokens were lost, not folded:\n{screen}"
        );
        // The routing key never reaches the screen, on any surface.
        for leak in ["session-", "1785539672538", "b5473d40b767", "osa-explorer"] {
            assert!(!screen.contains(leak), "{leak:?} leaked:\n{screen}");
        }
    }

    /// `main` still gets its row when it has something only it can say (the goal)
    /// or when it is the selection the user is about to act on. Folding a
    /// selection the user cannot see would be a worse bug than a crowded panel.
    #[test]
    fn main_row_returns_when_it_carries_a_goal_or_the_selection() {
        for (label, mut a) in [
            ("goal", {
                let mut a = captured_scene();
                a.set_main_row("port the Codex placement model", 231, 2_800);
                a
            }),
            ("selected", captured_scene()),
        ] {
            if label == "selected" {
                a.set_roster_selected(Some(0));
            }
            let reserved = a.height().max(1);
            let screen = snapshot_buffer(&render_to_buffer(|f| a.draw(f, f.area()), W, reserved));
            assert!(
                screen.lines().any(|l| l.trim_start().starts_with("\u{25cf} main")),
                "{label}: the `main` row must be drawn:\n{screen}"
            );
            // Reservation follows the same rule, both ways.
            assert_eq!(
                drawn_row_extent(|f| a.draw(f, f.area()), W, reserved),
                reserved,
                "{label}: reserved {reserved} rows, drew a different extent:\n{screen}"
            );
        }
    }

    /// The whole scene must survive a width sweep: nothing overflows, nothing
    /// panics, and the reservation matches the ink at every column count. A
    /// design that only works at 120 columns is not done.
    #[test]
    fn the_captured_scene_holds_across_a_width_sweep() {
        for w in [40u16, 56, 72, 80, 100, 120, 160] {
            let a = captured_scene();
            let reserved = a.height().max(1);
            let buf = render_to_buffer(|f| a.draw(f, f.area()), w, reserved);
            let screen = snapshot_buffer(&buf);
            assert_eq!(
                drawn_row_extent(|f| a.draw(f, f.area()), w, reserved),
                reserved,
                "w={w}: reserved {reserved} rows but the drawn extent disagrees:\n{screen}"
            );
            for line in screen.lines() {
                assert!(
                    crate::util::cols(line.trim_end()) <= w as usize,
                    "w={w}: row overflows the pane: {line:?}\n{screen}"
                );
            }
        }
    }

    /// A CJK/emoji path must still land the right-aligned meta column in the same
    /// place as an ASCII one — every truncation here goes through `fit_cols`
    /// (COLUMNS), never bytes or chars.
    #[test]
    fn a_wide_glyph_trail_path_still_aligns_the_meta_column() {
        let mut a = Agents::new();
        unsafe { std::env::set_var("HOME", "/Users/rhl") };
        a.set_workspace_root("/Users/rhl/projects/osa");
        a.set_main_row("", 40, 2_800);
        a.agent_started("agent:x:osa-explorer", "explorer", "", "scan", None);
        a.agent_progress(
            "agent:x:osa-explorer",
            "dir_list",
            9,
            0,
            "",
            vec![
                "dir_list: /Users/rhl/projects/osa/\u{6f22}\u{5b57}\u{1f600}dir/beta".into(),
                "dir_list: /Users/rhl/projects/osa/\u{6f22}\u{5b57}\u{1f600}dir/alpha".into(),
            ],
        );
        for w in [48u16, 72, 100] {
            let reserved = a.height().max(1);
            let buf = render_to_buffer(|f| a.draw(f, f.area()), w, reserved);
            let screen = snapshot_buffer(&buf);
            for line in screen.lines() {
                assert!(
                    crate::util::cols(line.trim_end()) <= w as usize,
                    "w={w}: wide-glyph row overflows: {line:?}\n{screen}"
                );
            }
            // The roster row's meta stays flush right (within one column of the
            // pane edge), which is what a byte/char-based fit would break.
            let roster = screen
                .lines()
                .find(|l| l.contains("explorer"))
                .unwrap_or_else(|| panic!("w={w}: no roster row:\n{screen}"));
            let used = crate::util::cols(roster.trim_end());
            assert!(
                used + 1 >= w as usize,
                "w={w}: meta column is not flush right ({used} of {w}): {roster:?}\n{screen}"
            );
        }
    }

    /// The background-terminals summary renders even with no live agents, so it
    /// must contribute its row to the reservation.
    #[test]
    fn agents_background_summary_row_is_reserved() {
        let mut a = Agents::new();
        a.set_bg_summary(3);
        let reserved = a.height();
        let drawn = drawn_row_extent(|f| a.draw(f, f.area()), W, reserved.max(1) + 2);
        assert!(
            drawn <= reserved,
            "bg summary drew into {drawn} rows of a {reserved}-row reservation"
        );
    }
}

// ───────────────────── width x time sweep (Codex-style) ─────────────────────

/// Narrow-terminal sweeps with hostile Unicode. Modelled on Codex's
/// width x elapsed status-line sweep.
///
/// Fixtures, each chosen because a different naive width computation breaks on it:
///   * `模型` — CJK, 2 display columns per char (`.chars().count()` under-counts,
///     `.len()` over-counts by 3x).
///   * `👩‍💻` — ZWJ sequence: 3 scalar values (woman + ZWJ + computer) that render
///     as ONE glyph; splitting inside it produces a different picture entirely.
///   * `ｶﾞ` — half-width katakana KA + combining dakuten: 2 scalars, 1 column,
///     and the dakuten has width 0.
mod width_sweep {
    use super::*;
    use crate::util::{cols, fit_cols};

    const FIXTURES: &[&str] = &[
        "\u{6a21}\u{578b}",                     // 模型
        "\u{1f469}\u{200d}\u{1f4bb}",           // 👩‍💻
        "\u{ff76}\u{ff9e}",                     // ｶﾞ
        "\u{6a21}\u{578b} \u{1f469}\u{200d}\u{1f4bb} \u{ff76}\u{ff9e}",
        "\u{6a21}\u{578b}-sonnet-4.5",
        "Working \u{6a21}\u{578b} 2m31s \u{1f469}\u{200d}\u{1f4bb}",
    ];

    /// Fixtures whose column advance is UNAMBIGUOUS, so an exact
    /// buffer-vs-terminal comparison is meaningful.
    ///
    /// ZWJ emoji are deliberately excluded: how many columns `👩‍💻` advances is
    /// genuinely terminal-dependent (2 on terminals that ligate the sequence, 4
    /// on those that do not), so a strict round-trip there would assert an
    /// opinion rather than a bug. It is still swept by
    /// [`activity_status_line_survives_every_narrow_width`], which only asserts
    /// properties that hold either way.
    const DETERMINISTIC_FIXTURES: &[&str] = &[
        "\u{6a21}\u{578b}",         // 模型
        "\u{ff76}\u{ff9e}",         // ｶﾞ
        "\u{6a21}\u{578b}-sonnet-4.5",
        "\u{6a21}\u{578b} \u{ff76}\u{ff9e} ok",
    ];

    /// A few elapsed values covering every branch of the duration formatter.
    const ELAPSED: &[u64] = &[0, 9, 59, 60, 151, 3600, 7325];

    /// `fit_cols` is the canonical column fitter every live-region layout budgets
    /// against. Its output must NEVER exceed the budget it was given, at any
    /// width, for any of the fixtures — including the degenerate widths 0 and 1
    /// where the single-column ellipsis alone already fills (or overflows) the
    /// budget.
    #[test]
    fn fit_cols_never_overflows_its_budget() {
        for s in FIXTURES {
            for w in 0u16..=12 {
                let out = fit_cols(s, w as usize);
                assert!(
                    cols(&out) <= w as usize,
                    "fit_cols({s:?}, {w}) = {out:?} is {} cols wide, budget was {w}",
                    cols(&out)
                );
            }
        }
    }

    /// Same sweep, but with the elapsed-time token spliced in the way the status
    /// line composes it — width x time, as in Codex's sweep.
    #[test]
    fn fit_cols_never_overflows_with_an_elapsed_token() {
        for s in FIXTURES {
            for secs in ELAPSED {
                let line = format!("{s} {}", crate::util::fmt_elapsed(*secs));
                for w in 0u16..=12 {
                    let out = fit_cols(&line, w as usize);
                    assert!(
                        cols(&out) <= w as usize,
                        "fit_cols({line:?}, {w}) = {out:?} is {} cols wide",
                        cols(&out)
                    );
                }
            }
        }
    }

    /// And it must not throw away room it was given: when the input already fits
    /// it comes back untouched.
    #[test]
    fn fit_cols_is_identity_when_the_text_already_fits() {
        for s in FIXTURES {
            let w = cols(s);
            assert_eq!(fit_cols(s, w), *s, "fit_cols({s:?}, {w}) must not truncate");
        }
    }

    fn narrow_activity(name: &str, verbosity: Verbosity, a11y: bool, secs: u64) -> Activity {
        let mut act = Activity::new();
        act.start();
        act.verbosity = verbosity;
        act.set_a11y(a11y);
        act.set_model_name(name);
        // A ONE-LINE details block only. A block that wraps to two or more rows
        // panics `Activity::draw` outright — see
        // `activity_invariants::activity_details_block_paints_consecutive_rows`,
        // which pins that bug on its own so this sweep can still cover the status
        // line, the tool feed and the live tail.
        act.set_details(Some(name.to_string()), 1);
        act.tool_start("Bash", r#"{"command":"make"}"#);
        act.push_command_output("make", &format!("{name} linking {secs}\n"));
        act
    }

    use crate::components::activity::{Activity, Verbosity};
    use crate::components::Component;

    /// The live status line itself, swept over width x elapsed x verbosity with
    /// the hostile fixtures as the model name.
    ///
    /// `0..=12` straddles the accent rail's `width > RAIL_W + 8` threshold, so
    /// both the railed and rail-less paths run, as well as the degenerate widths
    /// where the details block's prefix alone exceeds the budget. Nothing may
    /// panic, and the widget must still respect the rows it declared.
    #[test]
    fn activity_status_line_survives_every_narrow_width() {
        for name in FIXTURES {
            for verbosity in [
                Verbosity::Off,
                Verbosity::New,
                Verbosity::All,
                Verbosity::Verbose,
            ] {
                for a11y in [false, true] {
                    for secs in ELAPSED {
                        let act = narrow_activity(name, verbosity, a11y, *secs);
                        for w in 0u16..=12 {
                            let h = act.height().max(1);
                            let buf = render_to_buffer(|f| act.draw(f, f.area()), w, h);
                            let extent = buffer_row_extent(&buf, 0, w.max(1));
                            assert!(
                                extent <= h,
                                "{name:?} {verbosity:?} a11y={a11y} secs={secs} w={w}: \
                                 declared {h} rows, inked {extent}.\n{}",
                                snapshot_buffer(&buf)
                            );
                        }
                    }
                }
            }
        }
    }

    /// **DEFECT 5 — the interrupt hint must never be truncated.**
    ///
    /// It is the one control the user has mid-turn, and it renders to the RIGHT
    /// of the spinner verb. During orchestration the verb is
    /// `@<agent>: <tool>: <absolute path>`, which is wider than the pane on its
    /// own — it pushed the hint past the edge and the renderer clipped it
    /// ("esc to inte"). The line now reserves the hint FIRST and gives the verb
    /// the remainder, ellipsizing the path so its tail survives.
    ///
    /// Swept across every width wide enough to hold the hint at all, and through
    /// the REAL terminal emulator so a wide-glyph advance bug cannot hide.
    #[test]
    fn activity_status_line_never_truncates_the_interrupt_hint() {
        use crate::test_backend::VT100Backend;

        const HINT: &str = "esc to interrupt";
        let verbs = [
            "@goal-verifier-skeptic: dir_list: /Users/rhl/.osa/workspace/src",
            "@explorer: file_read: /Users/rhl/.osa/deeply/nested/path/to/backend.log",
            // Wide glyphs in both the label and the detail.
            "@\u{6a21}\u{578b}-worker: shell_execute: /w/\u{6a21}\u{578b}/build.sh",
            "Working",
        ];

        for verb in verbs {
            // Both hint widths: the armed form ("esc again to interrupt") is the
            // widest the reservation ever has to hold.
            for armed in [false, true] {
                let hint = if armed { "esc again to interrupt" } else { HINT };
                for w in 60u16..=140 {
                    let mut act = Activity::new();
                    act.start();
                    act.set_model_name("glm-5.2:cloud");
                    act.set_active_verb(Some(verb.to_string()));
                    act.arm_interrupt(armed);

                    let h = act.height().max(1);
                    let screen =
                        snapshot_buffer(&render_to_buffer(|f| act.draw(f, f.area()), w, h));
                    assert!(
                        screen.contains(hint),
                        "verb {verb:?} armed={armed} w={w}: the interrupt hint was \
                         truncated off the status line:\n{screen}"
                    );

                    // …and the emulator agrees, row for row, with no overflow.
                    let mut term = Terminal::new(VT100Backend::new(w, h)).unwrap();
                    term.draw(|f| act.draw(f, f.area())).unwrap();
                    let backend = term.backend();
                    let mut emulated = String::new();
                    for y in 0..h {
                        let mut x = 0u16;
                        while x < w {
                            let sym = backend.cell_contents(y, x);
                            if sym.is_empty() {
                                emulated.push(' ');
                                x += 1;
                            } else {
                                x += cols(&sym).max(1) as u16;
                                emulated.push_str(&sym);
                            }
                        }
                        emulated.push('\n');
                    }
                    assert!(
                        emulated.contains(hint),
                        "verb {verb:?} armed={armed} w={w}: the emulated terminal lost \
                         the interrupt hint:\n{emulated}"
                    );
                }
            }
        }
    }

    /// **DEFECT 2 — exactly ONE passive context indicator.**
    ///
    /// The status bar and the hint row above the composer both used to state
    /// "context used", from the same `StatusBar` but through different
    /// expressions of it: the status bar knows an unknown window has no honest
    /// denominator and renders the token count, the hint row printed
    /// `context_utilization()` raw — which is exactly 0.0 when the window is
    /// unknown. On screen that read "0% context used" against "~53.3k ctx".
    ///
    /// The passive readout now lives only on the status bar. This pins that the
    /// second renderer is gone (so the two can never disagree again) and that the
    /// surviving one carries the unknown-window semantics.
    #[test]
    fn only_one_passive_context_indicator_exists() {
        // The hint row keeps the reconnect notice and the actionable low-context
        // warning; it must not render a passive percentage of its own.
        const EVENT_LOOP_SRC: &str = include_str!("app/event_loop.rs");
        assert!(
            !EVENT_LOOP_SRC.contains("format!(\"{}% context used\""),
            "a second passive context readout has reappeared in event_loop.rs — \
             the status bar is the single source for it"
        );

        // And the surviving indicator declines to fabricate a percentage when the
        // window is unknown, which is precisely the state that produced the "0%".
        use crate::components::status_bar::StatusBar;
        let mut sb = StatusBar::new();
        sb.set_context(0.0, 0, 0); // unknown window
        sb.note_input_tokens(53_300);
        let screen = snapshot_buffer(&render_to_buffer(|f| sb.draw(f, f.area()), 160, 2));
        assert!(
            screen.contains("ctx"),
            "the one context indicator vanished:\n{screen}"
        );
        assert!(
            !screen.contains("0% ctx"),
            "the surviving indicator fabricated a zero percent:\n{screen}"
        );
    }

    /// The same sweep through the REAL terminal emulator ([`crate::test_backend`]).
    ///
    /// This executes the ANSI ratatui actually emits instead of trusting the
    /// `Buffer`, then asserts the emulated screen matches the buffer row for row.
    /// A wide-glyph cursor-advance bug, a stray `CUP`, or a wide glyph parked in
    /// the final column (which a real terminal wraps to the next line) all show up
    /// here as a divergence — and are all invisible to a `Buffer` snapshot, which
    /// is what every other render test in this crate asserts on.
    #[test]
    fn activity_status_line_round_trips_through_a_real_terminal() {
        use crate::test_backend::VT100Backend;

        for name in DETERMINISTIC_FIXTURES {
            for secs in ELAPSED {
                for verbosity in [Verbosity::Off, Verbosity::All] {
                    let act = narrow_activity(name, verbosity, false, *secs);
                    // From 2: a 1-column terminal makes `vt100` 0.15 panic on its
                    // own (`grid.rs` `col_wrap` unwraps a row that scrolled away
                    // when a 2-column glyph cannot fit) — an emulator limitation,
                    // not an OSA one. Width 1 is still swept on the buffer path.
                    for w in 2u16..=12 {
                        let h = act.height().max(1);
                        let buf = render_to_buffer(|f| act.draw(f, f.area()), w, h);

                        let mut term = Terminal::new(VT100Backend::new(w, h)).unwrap();
                        term.draw(|f| act.draw(f, f.area())).unwrap();
                        let backend = term.backend();

                        for y in 0..h {
                            // Reconstruct the emulated row the same way
                            // `buffer_row_text` reconstructs the intended one: a
                            // wide glyph lives in one cell and its continuation
                            // cell is skipped, and `vt100` reports an untouched
                            // cell as "" where ratatui's buffer holds " ".
                            let mut emulated = String::new();
                            let mut x = 0u16;
                            while x < w {
                                let sym = backend.cell_contents(y, x);
                                if sym.is_empty() {
                                    emulated.push(' ');
                                    x += 1;
                                } else {
                                    let adv = cols(&sym).max(1) as u16;
                                    emulated.push_str(&sym);
                                    x += adv;
                                }
                            }
                            let emulated = emulated.trim_end().to_string();
                            let intended = buffer_row_text(&buf, y);
                            assert_eq!(
                                emulated, intended,
                                "{name:?} {verbosity:?} secs={secs} w={w} row {y}: the terminal \
                                 shows {emulated:?} but ratatui intended {intended:?}"
                            );
                            assert!(
                                cols(&emulated) <= w as usize,
                                "{name:?} w={w} row {y}: emulated {emulated:?} is {} cols",
                                cols(&emulated)
                            );
                        }
                    }
                }
            }
        }
    }
}

// ───────────────────── GFM table invariants ─────────────────────

/// **DEFECT 2 — markdown table column allocation.**
///
/// `render::markdown::render_table` used to cap an over-wide table by handing
/// EVERY column the same `(width - chrome) / num_cols` share. On the 3-column
/// `| Topic | OSA | Codex |` tables the model writes, that gave the 5-column
/// `Topic` heading the same budget as two columns of prose and then hard-clipped
/// the prose at an identical point in every single row — `Rust (T…`,
/// `single thre…`, `orchestrator.ex (52KB) + OTP s…`. The table was unreadable.
///
/// The renderer now (a) sizes columns from actual content by water-filling and
/// (b) WRAPS an over-long cell instead of clipping it. These tests pin both,
/// plus the wide-character correctness of the padding that keeps the box
/// aligned.
mod table_invariants {
    use super::*;
    use crate::render::markdown::render_markdown;
    use crate::util::cols;

    /// The live table from the defect report, trimmed to its shape.
    const DEFECT_TABLE: &str = "\
| Topic | OSA | Codex |
|---|---|---|
| Language | Elixir (BEAM) | Rust (Tokio, single binary) |
| Concurrency | BEAM processes, supervision trees | single threaded async runtime |
| Core | orchestrator.ex (52KB) + OTP supervisors | core crate + session state machine |
| Sandbox | shell_execute allowlists | linux-sandbox/, bwrap/, execpolicy crates |
| Delegation | fleet supervisor | codex_delegate.rs (33KB), thread pool |
";

    /// Wide-character fixtures: CJK (2 columns/char), a ZWJ emoji (3 scalars,
    /// one glyph), and half-width katakana + a zero-width combining dakuten.
    /// Every one of them breaks a `.len()` or `.chars().count()` width model.
    const CJK_TABLE: &str = "\
| 模型 | 説明 |
|---|---|
| 模型模型模型 | 日本語のテキストがここに入ります、折り返しが必要です |
| 👩‍💻 dev | 👩‍💻 pairs with 模型 and ｶﾞ in one cell to stress the wrapper |
| ｶﾞｶﾞｶﾞ | short |
";

    fn lines_at(src: &str, w: u16) -> Vec<String> {
        render_markdown(src, w)
            .lines
            .iter()
            .map(|l| {
                let raw: String = l.spans.iter().map(|s| s.content.as_ref()).collect();
                // Strip OSC-8 wrappers so widths measure what is on screen.
                let mut out = String::new();
                let mut chars = raw.chars();
                while let Some(c) = chars.next() {
                    if c == '\x1b' {
                        for n in chars.by_ref() {
                            if n == '\\' {
                                break;
                            }
                        }
                    } else {
                        out.push(c);
                    }
                }
                out
            })
            .collect()
    }

    /// Column widths read back off the rendered separator row
    /// (`├─xxx─┼─yyy─┼─zzz─┤`), which is the ground truth the cells pad to.
    fn column_widths(rendered: &[String]) -> Option<Vec<usize>> {
        let sep = rendered.iter().find(|l| l.starts_with('├'))?;
        let inner: &str = sep.trim_start_matches('├').trim_end_matches('┤');
        Some(
            inner
                .split('┼')
                .map(|seg| seg.chars().filter(|c| *c == '─').count().saturating_sub(2))
                .collect(),
        )
    }

    /// **The regression itself.** A short heading column must NOT be given the
    /// same budget as a column full of prose. Under the old equal split all
    /// three columns came back identical; now the content-poor column keeps only
    /// what it needs and the prose columns get the rest.
    #[test]
    fn table_columns_are_sized_from_content_not_split_evenly() {
        for w in [80u16, 100, 120, 160] {
            let rendered = lines_at(DEFECT_TABLE, w);
            let widths = column_widths(&rendered)
                .unwrap_or_else(|| panic!("w={w}: no separator row in\n{}", rendered.join("\n")));
            assert_eq!(widths.len(), 3, "w={w}: {widths:?}");
            assert!(
                widths[0] < widths[1] && widths[0] < widths[2],
                "w={w}: column widths {widths:?} — the narrow `Topic` column was handed as much \
                 room as the prose columns, which is the equal-split bug.\n{}",
                rendered.join("\n")
            );
        }
    }

    /// **Content survives.** The old renderer clipped every cell of a column at
    /// the same point, destroying the tail of all of them. Wrapping means the
    /// full text is still on screen — possibly across several rows — so every
    /// word of the widest cell must be findable in the render.
    #[test]
    fn table_cells_wrap_instead_of_being_clipped() {
        for w in [70u16, 90, 110, 140] {
            let rendered = lines_at(DEFECT_TABLE, w);
            let flat = rendered.join("\n");
            for token in [
                "execpolicy",
                "supervisors",
                "allowlists",
                "runtime",
                "Tokio",
                "machine",
            ] {
                assert!(
                    flat.contains(token),
                    "w={w}: {token:?} was lost — cells are still being clipped.\n{flat}"
                );
            }
        }
    }

    /// **Width sweep.** Across every plausible terminal width the renderer must
    /// not panic and must not emit a line wider than the terminal — including
    /// the degenerate widths where a bordered table cannot be drawn at all and
    /// the renderer falls back to plain wrapped rows.
    #[test]
    fn table_width_sweep_never_overflows_and_never_panics() {
        for src in [DEFECT_TABLE, CJK_TABLE] {
            for w in 1u16..=200 {
                for line in lines_at(src, w) {
                    assert!(
                        cols(&line) <= w as usize,
                        "w={w}: line {line:?} is {} cols wide",
                        cols(&line)
                    );
                }
            }
        }
    }

    /// **Wide-char padding correctness.** Every line of a bordered table pads to
    /// the same total, so all of them — header, separator, and every wrapped
    /// data row — must measure identically in DISPLAY COLUMNS. Measuring a CJK
    /// or emoji cell by chars or bytes instead makes the box visibly ragged;
    /// this catches that without asserting any particular glyph width.
    #[test]
    fn table_rows_all_measure_the_same_width_with_wide_glyphs() {
        for w in [40u16, 60, 80, 120] {
            let rendered = lines_at(CJK_TABLE, w);
            let table: Vec<&String> = rendered
                .iter()
                .filter(|l| l.starts_with(['│', '├', '┌', '└']))
                .collect();
            assert!(!table.is_empty(), "w={w}: no table rendered");
            let first = cols(table[0]);
            for line in &table {
                assert_eq!(
                    cols(line),
                    first,
                    "w={w}: ragged table row {line:?} ({} cols vs {first})\n{}",
                    cols(line),
                    rendered.join("\n")
                );
            }
        }
    }

    /// **No mid-grapheme splits.** Wrapping cuts on grapheme boundaries, so a
    /// multi-scalar cluster is never broken across two rows: `ｶﾞ`'s combining
    /// dakuten must never open a line, and the ZWJ inside `👩‍💻` must never be
    /// the first or last scalar of a row.
    #[test]
    fn table_wrapping_never_splits_a_grapheme_cluster() {
        for w in 8u16..=120 {
            for line in lines_at(CJK_TABLE, w) {
                // A ZWJ may only appear BETWEEN the two halves of the emoji it
                // joins. Finding one next to a space or a border means the
                // cluster was cut open at the join.
                let chars: Vec<char> = line.chars().collect();
                for (i, c) in chars.iter().enumerate() {
                    if *c != '\u{200d}' {
                        continue;
                    }
                    let prev = i.checked_sub(1).map(|j| chars[j]);
                    let next = chars.get(i + 1).copied();
                    for (side, ch) in [("before", prev), ("after", next)] {
                        let ch = ch.unwrap_or_else(|| {
                            panic!("w={w}: ZWJ at the edge of {line:?} — cluster split")
                        });
                        assert!(
                            !ch.is_whitespace() && ch != '│',
                            "w={w}: ZWJ has {ch:?} {side} it in {line:?} — cluster split"
                        );
                    }
                }
                let trimmed = line.trim_start_matches(['│', '├', ' ']);
                assert!(
                    !trimmed.starts_with('\u{ff9e}'),
                    "w={w}: line {line:?} starts with a combining dakuten — its base char was \
                     left on the previous row"
                );
            }
        }
    }

    /// The same table pushed through the REAL terminal emulator: the emulated
    /// screen must match the buffer ratatui intended, row for row. A wide glyph
    /// mis-measured by one column parks a 2-column glyph in the final cell,
    /// which a real terminal wraps to the next line — invisible to a `Buffer`
    /// snapshot, loud here.
    #[test]
    fn table_round_trips_through_a_real_terminal() {
        use crate::test_backend::VT100Backend;
        use ratatui::widgets::Paragraph;

        // CJK only: how many columns a ZWJ emoji advances is genuinely
        // terminal-dependent, so a strict round-trip on it would assert an
        // opinion rather than a bug.
        let src = "| 模型 | 説明 |\n|---|---|\n| 模型模型 | ｶﾞｶﾞ ok |\n| plain | 日本語のテキスト |\n";

        for w in [24u16, 32, 48, 64, 96] {
            let text = render_markdown(src, w);
            let h = (text.lines.len() as u16).max(1);
            let buf = render_to_buffer(
                |f| f.render_widget(Paragraph::new(text.clone()), f.area()),
                w,
                h,
            );

            let mut term = Terminal::new(VT100Backend::new(w, h)).unwrap();
            term.draw(|f| f.render_widget(Paragraph::new(text.clone()), f.area()))
                .unwrap();
            let backend = term.backend();

            for y in 0..h {
                let mut emulated = String::new();
                let mut x = 0u16;
                while x < w {
                    let sym = backend.cell_contents(y, x);
                    if sym.is_empty() {
                        emulated.push(' ');
                        x += 1;
                    } else {
                        let adv = cols(&sym).max(1) as u16;
                        emulated.push_str(&sym);
                        x += adv;
                    }
                }
                let emulated = emulated.trim_end().to_string();
                let intended = buffer_row_text(&buf, y);
                assert_eq!(
                    emulated, intended,
                    "w={w} row {y}: the terminal shows {emulated:?} but ratatui intended \
                     {intended:?}"
                );
                assert!(
                    cols(&emulated) <= w as usize,
                    "w={w} row {y}: emulated {emulated:?} is {} cols",
                    cols(&emulated)
                );
            }
        }
    }

    // ─────────── full-grid borders, header styling, overflow marker ───────────
    //
    // The reference the operator supplied draws a CLOSED grid: an outer frame,
    // a vertical rule between every pair of columns, and a horizontal rule
    // between every pair of rows — with cell content wrapping inside its column
    // and the row growing to the tallest cell. The renderer already had
    // content-sized columns, wrapping, top-aligned cells and a bold accent
    // header; it drew only ONE horizontal rule (under the header) and had no
    // outer frame, so a wrapped two-line row was indistinguishable from two
    // separate rows. These tests pin the grid that replaced it.

    /// Glyphs that may carry the grid.
    const FRAME: [char; 10] = ['┌', '┬', '┐', '├', '┼', '┤', '└', '┴', '┘', '│'];

    fn is_grid_line(l: &str) -> bool {
        l.starts_with(['┌', '├', '└', '│'])
    }

    /// DISPLAY-COLUMN offsets of every grid glyph on a line. Grapheme-based, so
    /// a CJK or emoji cell shifts the offsets by its true advance rather than
    /// by a char count.
    fn grid_cols(line: &str) -> Vec<usize> {
        use unicode_segmentation::UnicodeSegmentation;
        let mut out = Vec::new();
        let mut at = 0usize;
        for g in UnicodeSegmentation::graphemes(line, true) {
            if g.chars().count() == 1 && FRAME.contains(&g.chars().next().unwrap()) {
                out.push(at);
            }
            at += cols(g);
        }
        out
    }

    /// Every line of a table — frame, rules, single-line rows and each visual
    /// row of a WRAPPED cell — must put its grid glyphs at exactly the same
    /// display columns. The failure mode this catches is a wrapped continuation
    /// line escaping its column and pushing the right-hand border out of true.
    #[test]
    fn table_grid_joins_align_at_every_width() {
        for src in [DEFECT_TABLE, CJK_TABLE, WRAPPING_TABLE] {
            for w in 1u16..=200 {
                let rendered = lines_at(src, w);
                let grid: Vec<&String> = rendered.iter().filter(|l| is_grid_line(l)).collect();
                if grid.is_empty() {
                    continue; // below the bordered-table threshold: plain fallback
                }
                let want = grid_cols(grid[0]);
                assert!(want.len() >= 2, "w={w}: {:?} has no frame", grid[0]);
                for line in &grid {
                    assert_eq!(
                        grid_cols(line),
                        want,
                        "w={w}: {line:?} breaks the column boundaries\n{}",
                        rendered.join("\n")
                    );
                }
            }
        }
    }

    /// The grid is CLOSED and ruled per row: a top frame, a rule before every
    /// data row (so `rows` rules for `rows` data rows counting the header
    /// underline), and a bottom frame.
    #[test]
    fn table_is_a_closed_grid_with_a_rule_between_every_row() {
        let rendered = lines_at(DEFECT_TABLE, 100);
        let grid: Vec<&String> = rendered.iter().filter(|l| is_grid_line(l)).collect();
        assert!(grid[0].starts_with('┌') && grid[0].ends_with('┐'), "{:?}", grid[0]);
        let last = grid[grid.len() - 1];
        assert!(last.starts_with('└') && last.ends_with('┘'), "{last:?}");
        // DEFECT_TABLE: 1 header + 5 data rows → 5 interior rules.
        let rules = grid.iter().filter(|l| l.starts_with('├')).count();
        assert_eq!(rules, 5, "want a rule under the header and between every data row\n{}",
            rendered.join("\n"));
    }

    /// The header row is the accent colour and bold; NO data row is. (The old
    /// renderer got this right and it must not regress when the styling moved
    /// behind `Theme::table_header`.)
    #[test]
    fn header_styling_applies_to_the_header_row_only() {
        use ratatui::style::Modifier;
        let theme = crate::style::theme();
        let text = render_markdown(WRAPPING_TABLE, 60);
        let mut saw_header = false;
        let mut saw_data = false;
        for line in &text.lines {
            let flat: String = line.spans.iter().map(|s| s.content.as_ref()).collect();
            let content_spans = || {
                line.spans
                    .iter()
                    .filter(|s| !s.content.chars().all(|c| FRAME.contains(&c) || c == ' '))
            };
            if flat.contains("Pattern") {
                saw_header = true;
                for s in content_spans() {
                    assert!(
                        s.style.add_modifier.contains(Modifier::BOLD)
                            && s.style.fg == Some(theme.colors.primary),
                        "header span {:?} is not accent-bold: {:?}",
                        s.content,
                        s.style
                    );
                }
            } else if flat.contains("BYOK") || flat.contains("Managed") {
                saw_data = true;
                for s in content_spans() {
                    assert!(
                        !s.style.add_modifier.contains(Modifier::BOLD),
                        "data span {:?} picked up the header's bold",
                        s.content
                    );
                }
            }
        }
        assert!(saw_header && saw_data, "fixture did not produce both row kinds");
    }

    /// The `▼` continues-below marker is TRUTHFUL: absent whenever the whole
    /// table is on screen, present only when the renderer actually cut a cell's
    /// tail off (`MAX_CELL_LINES`).
    #[test]
    fn overflow_marker_appears_only_when_content_is_clipped() {
        // Across the whole width sweep the marker must track the ONE thing that
        // actually drops content — a cell capped at `MAX_CELL_LINES`, which
        // leaves a `…` behind. Never present without it (a lie), never absent
        // with it (a silent truncation).
        for w in 1u16..=200 {
            for src in [DEFECT_TABLE, CJK_TABLE, WRAPPING_TABLE] {
                let flat = lines_at(src, w).join("\n");
                assert_eq!(
                    flat.contains('\u{25bc}'),
                    flat.contains('\u{2026}'),
                    "w={w}: the ▼ marker and the actual truncation disagree\n{flat}"
                );
            }
        }
        // At a comfortable width nothing is dropped, so neither appears.
        for src in [DEFECT_TABLE, WRAPPING_TABLE] {
            let flat = lines_at(src, 120).join("\n");
            assert!(!flat.contains('\u{25bc}'), "w=120: nothing was clipped\n{flat}");
        }
        // A cell far taller than the per-cell cap: content IS being dropped.
        let runaway = format!("| A | B |\n|---|---|\n| {} | y |\n", "word ".repeat(80));
        let rendered = lines_at(&runaway, 30);
        let marker = rendered
            .iter()
            .find(|l| l.contains('\u{25bc}'))
            .unwrap_or_else(|| panic!("no ▼ under a clipped table\n{}", rendered.join("\n")));
        assert!(
            marker.trim() == "\u{25bc}" && marker.starts_with(' '),
            "the marker must be centred on its own line: {marker:?}"
        );
    }

    /// A table whose cells wrap: two columns, both of which need more than one
    /// visual line at the widths under test.
    const WRAPPING_TABLE: &str = "\
| Pattern | Keys |
|---|---|
| BYOK multi-provider | Keys, provider billing |
| Managed | OSA billing, one key |
";
}

// ─────────────── ask_user survey band (INLINE, never an overlay) ───────────────
//
// `ask_user` blocks the whole turn on the operator, so its picker has to be
// visible, keyboard-driven and dismissable. It shipped invisible (the backend
// never forwarded the question), and when it was finally reachable it was a
// full-screen modal that hid the conversation the operator needed in order to
// answer. It is now a BOUNDED INLINE BAND above the composer, reserved through
// `App::survey_slot` → `inline_split(ROW_SURVEY)` exactly like the task
// checklist. These tests hold that shape: drawn ≤ reserved at every size, and
// the band never shares a row with the chat stream or the composer.
mod survey_invariants {
    use super::*;
    use crate::app::event_loop::{
        fit_bands, inline_split, Bands, ROW_INPUT, ROW_STREAM, ROW_SURVEY,
    };
    use crate::dialogs::survey::{
        option_columns, option_window, question_rows, wrap_to, wrapped_line_count, SurveyAction,
        SurveyDialog, SurveyOption, SurveyQuestion, MAX_VISIBLE_OPTIONS, SURVEY_INLINE_CAP,
    };
    use crate::util::cols;
    use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
    use ratatui::layout::Rect;

    const W: u16 = 100;

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::NONE)
    }

    fn question() -> SurveyQuestion {
        SurveyQuestion {
            text: "Which parser should we keep?".to_string(),
            header: None,
            multi_select: false,
            options: vec![
                SurveyOption {
                    label: "Rewrite the parser (Recommended)".to_string(),
                    description: Some("removes the whole class of escaping bugs".to_string()),
                },
                SurveyOption {
                    label: "Patch in place".to_string(),
                    description: Some("faster but the bug class stays".to_string()),
                },
            ],
            skippable: true,
        }
    }

    fn dialog() -> SurveyDialog {
        SurveyDialog::new("sv-1".to_string(), vec![question()], true)
    }

    /// `n` options with deliberately awkward content: a very long label, CJK and
    /// an emoji, so the column budget is exercised on real wide glyphs.
    fn wide_question(n: usize) -> SurveyQuestion {
        let fixtures = [
            (
                "Rewrite the parser end to end so every escaping edge case dies at once",
                "removes the whole class of escaping bugs but takes a week of work",
            ),
            ("日本語のラベルはここにあります", "説明も日本語で書かれています"),
            ("🚀 Ship it 🎉", "emoji labels advance two columns each"),
            ("Patch in place", "faster but the bug class stays"),
        ];
        SurveyQuestion {
            text: "パーサをどうしますか — which parser should we keep going forward?".to_string(),
            header: Some("parser".to_string()),
            multi_select: false,
            options: (0..n)
                .map(|i| {
                    let (l, d) = fixtures[i % fixtures.len()];
                    SurveyOption {
                        label: format!("{} #{}", l, i + 1),
                        description: Some(d.to_string()),
                    }
                })
                .collect(),
            skippable: true,
        }
    }

    fn multi_question_dialog() -> SurveyDialog {
        let qs = vec![
            SurveyQuestion {
                text: "Which visual direction?".to_string(),
                header: Some("style".to_string()),
                multi_select: false,
                options: vec![
                    SurveyOption {
                        label: "Minimal & terminal-native".to_string(),
                        description: Some("keyboard-first, no excess chrome".to_string()),
                    },
                    SurveyOption {
                        label: "Bold & expressive".to_string(),
                        description: Some("strong visuals, gradients".to_string()),
                    },
                ],
                skippable: true,
            },
            SurveyQuestion {
                text: "Which backend?".to_string(),
                header: None,
                multi_select: false,
                options: vec![
                    SurveyOption {
                        label: "Postgres".to_string(),
                        description: None,
                    },
                    SurveyOption {
                        label: "SQLite".to_string(),
                        description: None,
                    },
                ],
                skippable: true,
            },
            SurveyQuestion {
                text: "Ship behind a flag?".to_string(),
                header: None,
                multi_select: false,
                options: vec![
                    SurveyOption {
                        label: "Yes".to_string(),
                        description: None,
                    },
                    SurveyOption {
                        label: "No".to_string(),
                        description: None,
                    },
                ],
                skippable: true,
            },
        ];
        SurveyDialog::new("sv-multi".to_string(), qs, true)
    }

    // ── The core invariant: drawn ≤ reserved, swept ────────────────────────

    /// **Drawn ≤ reserved**, across an option-count sweep × widths, with long
    /// labels, CJK and emoji. This is the assertion the old full-screen dialog
    /// never had: the band is handed exactly `band_height()` rows and must not
    /// put ink outside them.
    #[test]
    fn drawn_never_exceeds_the_reserved_band() {
        for n in 1usize..=12 {
            for w in [24u16, 40, 60, 100, 200] {
                let mut d = SurveyDialog::new("sv".into(), vec![wide_question(n)], true);
                d.set_turn_meta(431, 53_600);
                let reserved = d.band_height(w);
                assert!(
                    reserved <= SURVEY_INLINE_CAP,
                    "n={n} w={w}: band wants {reserved} rows, cap is {SURVEY_INLINE_CAP}"
                );
                // Give the renderer a taller canvas than it reserved: anything it
                // paints below `reserved` is an overflow it would have inflicted
                // on the composer.
                let canvas = reserved + 4;
                let drawn = drawn_row_extent(
                    |f| d.draw_inline(f, Rect::new(0, 0, w, reserved)),
                    w,
                    canvas,
                );
                assert!(
                    drawn <= reserved,
                    "n={n} w={w}: reserved {reserved} rows but drew into {drawn}\n{}",
                    snapshot_buffer(&render_to_buffer(
                        |f| d.draw_inline(f, Rect::new(0, 0, w, reserved)),
                        w,
                        canvas,
                    ))
                );
                // …and no row may overflow its width (wide glyphs measured as 2).
                let buf = render_to_buffer(
                    |f| d.draw_inline(f, Rect::new(0, 0, w, reserved)),
                    w,
                    canvas,
                );
                for y in 0..canvas {
                    let text = buffer_row_text(&buf, y);
                    assert!(
                        cols(&text) <= w as usize,
                        "n={n} w={w} row {y} is {} cols: {text:?}",
                        cols(&text)
                    );
                }
            }
        }
    }

    /// A 12-option question must SCROLL, not grow: the band is capped and the
    /// cursor's option stays on screen wherever it is.
    #[test]
    fn many_options_scroll_internally_instead_of_growing_the_band() {
        let mut d = SurveyDialog::new("sv".into(), vec![wide_question(12)], true);
        // 12 options, but only MAX_VISIBLE_OPTIONS rows of them — the band stops
        // at the cap and the rest scroll inside it.
        assert!(
            d.band_height(W) <= SURVEY_INLINE_CAP,
            "12 options must not exceed the cap, got {}",
            d.band_height(W)
        );
        assert_eq!(
            d.band_height(W),
            d.band_height(W).min(4 + 1 + MAX_VISIBLE_OPTIONS),
            "the option rows must be clamped to MAX_VISIBLE_OPTIONS"
        );
        // Walk the cursor to the last option; the window must follow it.
        for _ in 0..11 {
            d.handle_key(key(KeyCode::Down));
        }
        let buf = render_to_buffer(
            |f| d.draw_inline(f, Rect::new(0, 0, W, SURVEY_INLINE_CAP)),
            W,
            SURVEY_INLINE_CAP,
        );
        let screen = snapshot_buffer(&buf);
        assert!(
            screen.contains("#12"),
            "the cursor's option scrolled out of the band:\n{screen}"
        );
    }

    /// The option window keeps the cursor visible at every position.
    #[test]
    fn option_window_always_contains_the_cursor() {
        for total in 1usize..=20 {
            for visible in 1usize..=10 {
                for cursor in 0..total {
                    let (start, len) = option_window(total, cursor, visible);
                    assert!(len <= visible && len <= total, "{total}/{visible}/{cursor}");
                    if total > visible {
                        assert!(
                            cursor >= start && cursor < start + len,
                            "cursor {cursor} outside window [{start},{})",
                            start + len
                        );
                    }
                }
            }
        }
    }

    // ── Band vs. stream / composer: the ink proof ─────────────────────────

    /// **The regression class this band must not repeat.** `draw_inline` once
    /// handed ONE rect to TWO components, so the checklist painted over the
    /// streaming reply. The survey band is a real slot in `inline_split`; the
    /// split must keep it disjoint from the stream band AND leave the composer
    /// alive, at every terminal height and option count.
    #[test]
    fn survey_band_never_shares_a_row_with_stream_or_composer() {
        for area_h in 10u16..=40 {
            for n in 1usize..=12 {
                let d = SurveyDialog::new("sv".into(), vec![wide_question(n)], true);
                let (think_h, agents_h, checklist_h, input_h) = (3u16, 0u16, 0u16, 3u16);
                let want = Bands {
                    checklist: checklist_h,
                    think: think_h,
                    agents: agents_h,
                    survey: d.band_height(W),
                    input: input_h,
                    ..Default::default()
                };
                let bands = fit_bands(want, area_h);
                let area = Rect::new(0, 0, W, area_h);
                let rows = inline_split(area, bands);
                assert_eq!(
                    rows[ROW_STREAM].intersection(rows[ROW_SURVEY]).height,
                    0,
                    "h={area_h} n={n}: stream {:?} overlaps survey {:?}",
                    rows[ROW_STREAM],
                    rows[ROW_SURVEY]
                );
                assert_eq!(
                    rows[ROW_INPUT].intersection(rows[ROW_SURVEY]).height,
                    0,
                    "h={area_h} n={n}: composer {:?} overlaps survey {:?}",
                    rows[ROW_INPUT],
                    rows[ROW_SURVEY]
                );
                assert!(
                    rows[ROW_INPUT].height >= 1,
                    "h={area_h} n={n}: composer starved to 0 rows by the survey band"
                );
                // Both disjointness assertions above hold vacuously once the
                // arbiter has shed the survey to zero rows, so pin what stays
                // load-bearing at those heights: the band is only ever shed
                // under real pressure. The user is being ASKED something — it
                // must not vanish while the region has room for it.
                if want.capped().reserved() + crate::app::event_loop::STREAM_FLOOR <= area_h {
                    assert_eq!(
                        rows[ROW_SURVEY].height,
                        d.band_height(W).min(SURVEY_INLINE_CAP),
                        "h={area_h} n={n}: the question band was shed with room to spare"
                    );
                }
            }
        }
    }

    /// Ink proof of the same thing: fill the stream band with a "streaming
    /// markdown table", draw the survey into its own band, and every stream row
    /// must come out verbatim.
    #[test]
    fn drawing_the_survey_does_not_erase_the_stream_band() {
        use ratatui::widgets::Paragraph;

        let area_h = 30u16;
        let d = SurveyDialog::new("sv".into(), vec![wide_question(4)], true);
        let (think_h, agents_h, checklist_h, input_h) = (3u16, 0u16, 0u16, 3u16);
        let bands = fit_bands(
            Bands {
                checklist: checklist_h,
                think: think_h,
                agents: agents_h,
                survey: d.band_height(W),
                input: input_h,
                ..Default::default()
            },
            area_h,
        );
        assert!(bands.survey > 0, "the survey must reserve a band");

        let area = Rect::new(0, 0, W, area_h);
        let rows = inline_split(area, bands);
        let buf = render_to_buffer(
            |f| {
                let filler: Vec<ratatui::text::Line<'static>> = (0..rows[ROW_STREAM].height)
                    .map(|_| ratatui::text::Line::from("│ table cell │ table cell │"))
                    .collect();
                f.render_widget(Paragraph::new(filler), rows[ROW_STREAM]);
                d.draw_inline(f, rows[ROW_SURVEY]);
            },
            W,
            area_h,
        );
        for y in rows[ROW_STREAM].y..(rows[ROW_STREAM].y + rows[ROW_STREAM].height) {
            let text = buffer_row_text(&buf, y);
            assert!(
                text.starts_with("│ table cell │"),
                "stream row {y} was overpainted by the survey: {text:?}\n{}",
                snapshot_buffer(&buf)
            );
        }
        // …and the survey really did paint into its own band.
        let head = buffer_row_text(&buf, rows[ROW_SURVEY].y);
        assert!(
            head.contains("Waiting"),
            "survey header missing from its band: {head:?}\n{}",
            snapshot_buffer(&buf)
        );
    }

    /// A final assistant block committing to scrollback while the question band
    /// is up must not be interleaved with it: the band is bounded and reserved,
    /// so the rows above it belong entirely to the transcript.
    #[test]
    fn a_committed_block_survives_beside_the_survey_band() {
        use ratatui::widgets::Paragraph;

        let area_h = 26u16;
        let d = SurveyDialog::new("sv".into(), vec![wide_question(3)], true);
        let (think_h, agents_h, checklist_h, input_h) = (1u16, 0u16, 4u16, 3u16);
        let bands = fit_bands(
            Bands {
                checklist: checklist_h,
                think: think_h,
                agents: agents_h,
                survey: d.band_height(W),
                input: input_h,
                ..Default::default()
            },
            area_h,
        );
        let area = Rect::new(0, 0, W, area_h);
        let rows = inline_split(area, bands);

        // Stand in for the just-committed final assistant block.
        let final_text = "The parser rewrite is done; here is the summary of what changed.";
        let buf = render_to_buffer(
            |f| {
                let lines: Vec<ratatui::text::Line<'static>> = (0..rows[ROW_STREAM].height)
                    .map(|_| ratatui::text::Line::from(final_text))
                    .collect();
                f.render_widget(Paragraph::new(lines), rows[ROW_STREAM]);
                d.draw_inline(f, rows[ROW_SURVEY]);
            },
            W,
            area_h,
        );
        for y in rows[ROW_STREAM].y..(rows[ROW_STREAM].y + rows[ROW_STREAM].height) {
            assert_eq!(
                buffer_row_text(&buf, y).trim_end(),
                final_text,
                "committed block row {y} was clobbered by the survey band\n{}",
                snapshot_buffer(&buf)
            );
        }
    }

    // ── Content ───────────────────────────────────────────────────────────

    /// The question text, EVERY option label, the free-text row and the footer
    /// affordances must actually be on screen.
    #[test]
    fn draws_the_question_options_and_footer() {
        let d = dialog();
        let h = d.band_height(W);
        let buf = render_to_buffer(|f| d.draw_inline(f, Rect::new(0, 0, W, h)), W, h);
        let screen = snapshot_buffer(&buf);
        for needle in [
            "Waiting",
            "Which parser should we keep?",
            "Rewrite the parser (Recommended)",
            "removes the whole class of escaping bugs",
            "Patch in place",
            "Type your answer here",
            "navigate",
            "Enter:",
        ] {
            assert!(
                screen.contains(needle),
                "inline survey never drew {needle:?}.\n{screen}"
            );
        }
        // Numbered gutter + radio glyphs, per the reference design.
        assert!(screen.contains('\u{25c9}') || screen.contains('\u{25cb}'), "no radio glyph:\n{screen}");
        assert!(screen.contains(" 1 "), "no numbered gutter:\n{screen}");
        assert!(screen.contains(" z "), "no free-text gutter:\n{screen}");
    }

    /// The recommended option is listed FIRST — the model is told to order them
    /// that way and the band must not reorder.
    #[test]
    fn recommended_option_is_drawn_first() {
        let d = dialog();
        let h = d.band_height(W);
        let buf = render_to_buffer(|f| d.draw_inline(f, Rect::new(0, 0, W, h)), W, h);
        let screen = snapshot_buffer(&buf);
        let rec = screen.find("Rewrite the parser").expect("recommended row");
        let other = screen.find("Patch in place").expect("second row");
        assert!(rec < other, "recommended option must render first:\n{screen}");
    }

    /// Descriptions degrade before labels do: at a width where both cannot fit,
    /// the label survives and the description is dropped.
    #[test]
    fn descriptions_degrade_before_labels() {
        // Wide: a description column exists.
        let (_lw, dw) = option_columns(100, 30);
        assert!(dw.is_some(), "a 100-col band must keep descriptions");
        // Narrow: no room, so the label takes everything.
        let (lw, dw) = option_columns(24, 30);
        assert!(dw.is_none(), "a 24-col band must drop descriptions");
        assert!(lw > 0, "the label column must survive");

        let d = dialog();
        let h = d.band_height(24);
        let buf = render_to_buffer(|f| d.draw_inline(f, Rect::new(0, 0, 24, h)), 24, h);
        let screen = snapshot_buffer(&buf);
        assert!(
            !screen.contains("escaping bugs"),
            "description survived at 24 cols where the label should have won:\n{screen}"
        );
    }

    /// A pathologically long question is capped at two rows, so the options the
    /// operator has to interact with are never pushed out of the band.
    #[test]
    fn a_long_question_never_hides_the_options() {
        let mut q = question();
        q.text = "why ".repeat(200);
        let d = SurveyDialog::new("sv-long".to_string(), vec![q], true);
        assert!(d.band_height(W) <= SURVEY_INLINE_CAP);
        let h = d.band_height(W);
        let buf = render_to_buffer(|f| d.draw_inline(f, Rect::new(0, 0, W, h)), W, h);
        let screen = snapshot_buffer(&buf);
        assert!(
            screen.contains("Rewrite the parser"),
            "options were pushed out of the band by a long question:\n{screen}"
        );
    }

    // ── Keyboard ──────────────────────────────────────────────────────────

    /// Down/Up move the cursor and Enter returns the chosen option's label —
    /// the value that travels back to the blocked tool.
    #[test]
    fn enter_submits_the_highlighted_option() {
        let mut d = dialog();
        assert!(d.handle_key(key(KeyCode::Down)).is_none());
        match d.handle_key(key(KeyCode::Enter)) {
            Some(SurveyAction::Submit(result)) => {
                assert_eq!(result.survey_id, "sv-1");
                assert_eq!(result.answers.len(), 1);
                assert_eq!(result.answers[0].selected, vec!["Patch in place".to_string()]);
            }
            other => panic!("expected Submit, got {other:?}"),
        }

        // …and the first (recommended) option when the cursor never moves.
        let mut d = dialog();
        match d.handle_key(key(KeyCode::Enter)) {
            Some(SurveyAction::Submit(result)) => assert_eq!(
                result.answers[0].selected,
                vec!["Rewrite the parser (Recommended)".to_string()]
            ),
            other => panic!("expected Submit, got {other:?}"),
        }

        // Up from the top wraps to the free-text row rather than dead-ending.
        let mut d = dialog();
        assert!(d.handle_key(key(KeyCode::Up)).is_none());
        assert!(
            d.handle_key(key(KeyCode::Enter)).is_none(),
            "Enter on the free-text row opens the editor, it does not submit"
        );
    }

    /// Number keys jump straight to an option and answer with it.
    #[test]
    fn number_keys_jump_directly_to_an_option() {
        let mut d = dialog();
        match d.handle_key(key(KeyCode::Char('2'))) {
            Some(SurveyAction::Submit(r)) => {
                assert_eq!(r.answers[0].selected, vec!["Patch in place".to_string()])
            }
            other => panic!("expected Submit, got {other:?}"),
        }
        // A digit past the end of the list is inert, not a panic.
        let mut d = dialog();
        assert!(d.handle_key(key(KeyCode::Char('9'))).is_none());
    }

    /// `z` jumps to the free-text row and starts capturing keystrokes.
    #[test]
    fn z_opens_the_free_text_row() {
        let mut d = dialog();
        assert!(d.handle_key(key(KeyCode::Char('z'))).is_none());
        assert!(d.is_typing(), "z must put the band into free-text capture");
        for c in "custom".chars() {
            assert!(d.handle_key(key(KeyCode::Char(c))).is_none());
        }
        match d.handle_key(key(KeyCode::Enter)) {
            Some(SurveyAction::Submit(r)) => {
                assert_eq!(r.answers[0].free_text.as_deref(), Some("custom"))
            }
            other => panic!("expected Submit, got {other:?}"),
        }
    }

    /// Free text is always reachable via the list too, so the operator can
    /// answer something the model did not offer (the client-supplied "Other").
    #[test]
    fn free_text_is_always_offered_and_submits_its_content() {
        let mut d = dialog();
        d.handle_key(key(KeyCode::Down));
        d.handle_key(key(KeyCode::Down));
        assert!(d.handle_key(key(KeyCode::Enter)).is_none());
        for c in "neither".chars() {
            d.handle_key(key(KeyCode::Char(c)));
        }
        match d.handle_key(key(KeyCode::Enter)) {
            Some(SurveyAction::Submit(result)) => {
                assert_eq!(result.answers[0].free_text.as_deref(), Some("neither"));
            }
            other => panic!("expected Submit, got {other:?}"),
        }
    }

    /// While the free-text row is capturing, ordinary characters must NOT be
    /// interpreted as option shortcuts — `x` would otherwise decline mid-word.
    #[test]
    fn free_text_capture_swallows_shortcut_characters() {
        let mut d = dialog();
        d.handle_key(key(KeyCode::Char('z')));
        for c in "xz1 fix".chars() {
            assert!(
                d.handle_key(key(KeyCode::Char(c))).is_none(),
                "typing {c:?} escaped the free-text row"
            );
        }
        match d.handle_key(key(KeyCode::Enter)) {
            Some(SurveyAction::Submit(r)) => {
                assert_eq!(r.answers[0].free_text.as_deref(), Some("xz1 fix"))
            }
            other => panic!("expected Submit, got {other:?}"),
        }
    }

    /// Esc declines, from the option list, immediately. Without this the
    /// operator has no way out and the turn deadlocks until the tool's own
    /// timeout fires. Esc INSIDE the editor only leaves the editor.
    #[test]
    fn esc_declines_without_hanging() {
        let mut d = dialog();
        assert!(matches!(
            d.handle_key(key(KeyCode::Esc)),
            Some(SurveyAction::Skip)
        ));

        // In the editor, Esc backs out to the list and the NEXT Esc declines.
        let mut d = dialog();
        d.handle_key(key(KeyCode::Char('z')));
        assert!(d.handle_key(key(KeyCode::Esc)).is_none());
        assert!(!d.is_typing());
        assert!(matches!(
            d.handle_key(key(KeyCode::Esc)),
            Some(SurveyAction::Skip)
        ));
    }

    /// The `[×]` header affordance, on the keyboard: `x` declines exactly like
    /// Esc (mouse capture is off outside the transcript reader).
    #[test]
    fn x_declines_like_esc() {
        let mut d = dialog();
        assert!(matches!(
            d.handle_key(key(KeyCode::Char('x'))),
            Some(SurveyAction::Skip)
        ));
    }

    /// Ctrl/Alt chords are NOT swallowed — Ctrl+C must still reach the app's
    /// interrupt path.
    #[test]
    fn control_chords_fall_through_to_the_app() {
        let mut d = dialog();
        assert!(d
            .handle_key(KeyEvent::new(KeyCode::Char('c'), KeyModifiers::CONTROL))
            .is_none());
    }

    // ── Multi-question navigation ─────────────────────────────────────────

    /// ←/→ move between questions without submitting, `[n/N]` tracks position,
    /// and an already-answered question comes back SHOWING its answer rather
    /// than resetting to a blank list.
    #[test]
    fn multi_question_navigation_preserves_answers() {
        let mut d = multi_question_dialog();
        let h = d.band_height(W);
        let screen = |d: &SurveyDialog| {
            snapshot_buffer(&render_to_buffer(
                |f| d.draw_inline(f, Rect::new(0, 0, W, h)),
                W,
                h,
            ))
        };
        assert!(screen(&d).contains("[1/3]"), "{}", screen(&d));
        assert!(screen(&d).contains("Which visual direction?"), "{}", screen(&d));

        // Answer Q1 with option 2 → auto-advance to Q2.
        assert!(d.handle_key(key(KeyCode::Char('2'))).is_none());
        let s = screen(&d);
        assert!(s.contains("[2/3]"), "did not advance to Q2:\n{s}");
        assert!(s.contains("Which backend?"), "Q2 text missing:\n{s}");

        // → reviews Q3 without submitting, ← walks back to Q1.
        assert!(d.handle_key(key(KeyCode::Right)).is_none());
        assert!(screen(&d).contains("[3/3]"));
        assert!(d.handle_key(key(KeyCode::Left)).is_none());
        assert!(d.handle_key(key(KeyCode::Left)).is_none());
        let s = screen(&d);
        assert!(s.contains("[1/3]"), "← did not return to Q1:\n{s}");
        // Q1 reads as ANSWERED: the chosen value is shown and its radio is filled.
        assert!(
            s.contains("answered: Bold & expressive"),
            "an answered question must show its answer:\n{s}"
        );
        assert!(s.contains('\u{25c9}'), "the chosen option's radio must be filled:\n{s}");

        // ← on the first question is a no-op, not an underflow.
        assert!(d.handle_key(key(KeyCode::Left)).is_none());
        assert!(screen(&d).contains("[1/3]"));
    }

    /// Enter on the LAST question submits every answer collected so far.
    #[test]
    fn the_last_question_submits_the_whole_survey() {
        let mut d = multi_question_dialog();
        assert!(d.handle_key(key(KeyCode::Enter)).is_none()); // Q1 → Q2
        assert!(d.handle_key(key(KeyCode::Enter)).is_none()); // Q2 → Q3
        match d.handle_key(key(KeyCode::Enter)) {
            Some(SurveyAction::Submit(r)) => {
                assert_eq!(r.answers.len(), 3, "every question must be reported");
                assert_eq!(r.answers[0].selected, vec!["Minimal & terminal-native".to_string()]);
                assert_eq!(r.answers[2].selected, vec!["Yes".to_string()]);
            }
            other => panic!("expected Submit, got {other:?}"),
        }
    }

    /// Multi-select questions get toggles instead of pick-and-advance.
    #[test]
    fn multi_select_toggles_with_space_and_confirms_with_enter() {
        let mut q = question();
        q.multi_select = true;
        let mut d = SurveyDialog::new("sv-multi-select".into(), vec![q], true);
        assert!(d.handle_key(key(KeyCode::Char(' '))).is_none());
        assert!(d.handle_key(key(KeyCode::Down)).is_none());
        assert!(d.handle_key(key(KeyCode::Char(' '))).is_none());
        match d.handle_key(key(KeyCode::Enter)) {
            Some(SurveyAction::Submit(r)) => assert_eq!(r.answers[0].selected.len(), 2),
            other => panic!("expected Submit, got {other:?}"),
        }
        // A digit toggles rather than submitting in multi-select.
        let mut q = question();
        q.multi_select = true;
        let mut d = SurveyDialog::new("sv2".into(), vec![q], true);
        assert!(d.handle_key(key(KeyCode::Char('1'))).is_none());
    }

    // ── Pure helpers ──────────────────────────────────────────────────────

    #[test]
    fn wrapped_line_count_is_sane() {
        assert_eq!(wrapped_line_count("", 40), 1);
        assert_eq!(wrapped_line_count("short", 40), 1);
        assert_eq!(wrapped_line_count("aaa bbb ccc", 7), 2);
        assert_eq!(wrapped_line_count("anything", 0), 1);
        assert!(wrapped_line_count(&"why ".repeat(200), 40) > 3);
    }

    #[test]
    fn question_rows_is_capped_at_two() {
        assert_eq!(question_rows("short", 80), 1);
        assert_eq!(question_rows(&"why ".repeat(200), 40), 2);
        // A zero width degrades to the 2-row cap rather than panicking.
        assert_eq!(question_rows("anything", 0), 2);
    }

    /// `wrap_to` is column-aware and never returns a line wider than asked, on
    /// CJK and emoji as well as ASCII.
    #[test]
    fn wrap_to_respects_columns_on_wide_glyphs() {
        for text in [
            "plain english words that will need to wrap somewhere",
            "日本語のテキストはここで折り返されます、たぶん",
            "🚀🚀🚀 rocket rocket rocket 🎉🎉🎉",
        ] {
            for w in [8u16, 12, 20, 40] {
                for rows in 1u16..=3 {
                    let out = wrap_to(text, w, rows);
                    assert!(out.len() as u16 <= rows);
                    for l in &out {
                        assert!(cols(l) <= w as usize, "{l:?} is {} cols, cap {w}", cols(l));
                    }
                }
            }
        }
        assert!(wrap_to("anything", 0, 2).is_empty());
        assert!(wrap_to("anything", 10, 0).is_empty());
    }

    /// The band's own arithmetic: chrome + question + options, capped.
    #[test]
    fn band_height_is_bounded_and_monotonic() {
        let mut prev = 0u16;
        for n in 0usize..=12 {
            let d = SurveyDialog::new("sv".into(), vec![wide_question(n.max(1))], true);
            let h = d.band_height(W);
            assert!(h <= SURVEY_INLINE_CAP, "n={n}: {h} > cap");
            assert!(h >= prev, "n={n}: band shrank ({prev} → {h})");
            prev = h;
        }
        // The option window itself is what stops growth past the cap.
        assert_eq!(
            option_window(12, 0, MAX_VISIBLE_OPTIONS as usize).1,
            MAX_VISIBLE_OPTIONS as usize
        );
    }

    /// A zero-height or zero-width band draws nothing rather than panicking.
    #[test]
    fn a_degenerate_band_draws_nothing() {
        let d = dialog();
        assert_eq!(drawn_row_extent(|f| d.draw_inline(f, Rect::new(0, 0, W, 0)), W, 4), 0);
        assert_eq!(drawn_row_extent(|f| d.draw_inline(f, Rect::new(0, 0, 0, 4)), 4, 4), 0);
        // A 1-row band draws only its header and stops.
        assert!(drawn_row_extent(|f| d.draw_inline(f, Rect::new(0, 0, W, 1)), W, 4) <= 1);
    }
}


/// **Turn-completion invariants.**
///
/// The reported defect: "the output renders in a small window and then when it's
/// done it shows the whole thing — it's weird." Two causes, pinned here.
///
/// 1. The streaming preview was a permanently 10-row letterbox, so a long reply
///    was only ever legible after it landed in scrollback. It now grows — but on
///    a coarse lattice with a hard ceiling, because every height change rebuilds
///    the inline viewport and mid-turn rebuilds are the stacked-chrome bug class.
/// 2. At completion the working chrome (spinner, tool feed, reasoning box, agent
///    roster) kept its reserved rows through the shrink debounce, so the finished
///    answer arrived with a tall band of dead machinery underneath it.
#[cfg(test)]
mod turn_completion_invariants {
    use super::*;
    use crate::app::assistant_stream::{commit_assistant_block, AssistantStream, Finalize};
    use crate::app::event_loop::{
        fit_bands, inline_split, settle_working_chrome, stream_preview_ceiling,
        Bands,
        stream_preview_rows, streaming_inline_height, ROW_AGENTS,
        ROW_CHECKLIST, ROW_INPUT, ROW_STREAM, ROW_SURVEY, ROW_THINK, STREAM_PREVIEW_MAX,
        STREAM_PREVIEW_ROWS, STREAM_PREVIEW_STEP,
    };
    use crate::components::chat::Chat;
    use crate::components::task_checklist::TaskChecklist;
    use ratatui::layout::Rect;

    const W: u16 = 100;

    // ── (3) The preview may grow, but only in bounded steps ───────────────

    /// Growth is quantized, monotonic and capped — the three properties that make
    /// it impossible for a growing reply to churn the inline viewport.
    ///
    /// A per-delta-sized preview would rebuild the viewport (and issue a DSR
    /// cursor query tmux/SSH can drop) on every token. This sweeps a reply
    /// growing row by row past the ceiling and asserts the reserved slot changes
    /// only a handful of times for the WHOLE turn.
    #[test]
    fn the_preview_grows_in_bounded_steps_and_never_shrinks_mid_turn() {
        for term_rows in [24u16, 30, 40, 60, 120] {
            let ceiling = stream_preview_ceiling(term_rows);
            let mut hw = 0u16;
            let mut heights = Vec::new();
            // A reply rendering to 1…200 rows, then DIPPING back (a fenced block
            // closing / a table collapsing) — the shape that would oscillate a
            // naively content-sized slot.
            let progress = (1u16..=200).chain((1u16..=200).rev());
            for content_h in progress {
                let rows = stream_preview_rows(content_h, hw, ceiling);
                assert!(
                    rows >= hw,
                    "term_rows={term_rows} content={content_h}: the preview SHRANK \
                     mid-turn ({hw} → {rows}); a shrink/grow pair rebuilds the \
                     viewport twice"
                );
                assert!(
                    (STREAM_PREVIEW_ROWS..=ceiling).contains(&rows),
                    "term_rows={term_rows} content={content_h}: {rows} rows is \
                     outside [{STREAM_PREVIEW_ROWS}, {ceiling}]"
                );
                assert!(
                    rows == ceiling
                        || (rows - STREAM_PREVIEW_ROWS) % STREAM_PREVIEW_STEP == 0,
                    "term_rows={term_rows} content={content_h}: {rows} is off the \
                     ROWS + k*STEP lattice — growth is not quantized"
                );
                hw = rows;
                heights.push(rows);
            }
            heights.dedup();
            let max_steps = (STREAM_PREVIEW_MAX - STREAM_PREVIEW_ROWS)
                .div_ceil(STREAM_PREVIEW_STEP) as usize
                + 1;
            assert!(
                heights.len() <= max_steps,
                "term_rows={term_rows}: the preview changed height {} times in one \
                 turn ({heights:?}); at most {max_steps} viewport rebuilds are allowed",
                heights.len()
            );
        }
    }

    /// The live region is not allowed to eat the scrollback the user is reading:
    /// the preview ceiling never exceeds half the terminal, and never the hard cap.
    #[test]
    fn the_preview_ceiling_never_takes_more_than_half_the_terminal() {
        for term_rows in 4u16..=300 {
            let c = stream_preview_ceiling(term_rows);
            assert!(c <= STREAM_PREVIEW_MAX, "term_rows={term_rows}: ceiling {c} > cap");
            assert!(
                c <= (term_rows / 2).max(STREAM_PREVIEW_ROWS),
                "term_rows={term_rows}: ceiling {c} takes more than half the screen"
            );
            assert!(c >= STREAM_PREVIEW_ROWS, "term_rows={term_rows}: ceiling {c} below floor");
        }
    }

    /// **Drawn ≤ reserved, with a GROWN preview and both bands present.**
    ///
    /// The bug this guards is the one that already shipped once in the other
    /// direction: `streaming_inline_height` must count every band in BOTH its
    /// `base` and its `want`, or the extra rows the preview grew by get taken out
    /// of the checklist / survey / composer instead of being added to the
    /// viewport. Swept over every preview step with a plan AND an inline question
    /// on screen.
    #[test]
    fn a_grown_preview_never_starves_the_bands_or_the_composer() {
        let term_rows = 60u16;
        let hi = term_rows - 1;
        let (think_h, agents_h, input_h) = (1u16, 0u16, 3u16);
        let overhead = think_h + 1 + 2;
        let ceiling = stream_preview_ceiling(term_rows);

        let mut preview = STREAM_PREVIEW_ROWS;
        while preview <= ceiling {
            for n_tasks in 0usize..=8 {
                for survey_want in [0u16, 5, 9] {
                    let mut cl = TaskChecklist::new();
                    for i in 0..n_tasks {
                        cl.add(format!("t{i}"), format!("step {i}"), None);
                    }
                    let want_checklist = if n_tasks == 0 { 0 } else { cl.height().min(12) };
                    let bands = want_checklist.saturating_add(survey_want);

                    let area_h = streaming_inline_height(
                        crate::LIVE_H_BASE.saturating_add(bands),
                        overhead,
                        input_h,
                        agents_h,
                        bands,
                        0,
                        preview,
                        hi,
                    );
                    let area = Rect::new(0, 0, W, area_h);
                    let fitted = fit_bands(
                        Bands {
                            checklist: want_checklist,
                            think: think_h,
                            agents: agents_h,
                            survey: survey_want,
                            input: input_h,
                            ..Default::default()
                        },
                        area_h,
                    );
                    let checklist_h = fitted.checklist;
                    let survey_h = fitted.survey;
                    let rows = inline_split(area, fitted);

                    let ctx = format!(
                        "preview={preview} tasks={n_tasks} survey={survey_want} area_h={area_h}"
                    );
                    assert_eq!(
                        checklist_h, want_checklist,
                        "{ctx}: the grown preview squeezed the plan band"
                    );
                    assert_eq!(
                        survey_h, survey_want,
                        "{ctx}: the grown preview squeezed the survey band"
                    );
                    assert!(
                        rows[ROW_STREAM].height >= preview,
                        "{ctx}: the reply got {} rows, not the {preview} reserved",
                        rows[ROW_STREAM].height
                    );
                    assert!(rows[ROW_INPUT].height >= 1, "{ctx}: composer starved to 0 rows");
                    // No two components share a row — the invariant a growing
                    // stream band must not be allowed to break.
                    let bands_rects = [
                        rows[ROW_CHECKLIST],
                        rows[ROW_THINK],
                        rows[ROW_AGENTS],
                        rows[ROW_SURVEY],
                        rows[ROW_INPUT],
                    ];
                    for (i, a) in bands_rects.iter().enumerate() {
                        assert_eq!(
                            rows[ROW_STREAM].intersection(*a).height,
                            0,
                            "{ctx}: stream band overlaps band {i}"
                        );
                        for b in bands_rects.iter().skip(i + 1) {
                            assert_eq!(
                                a.intersection(*b).height,
                                0,
                                "{ctx}: two reserved bands share a row: {a:?} / {b:?}"
                            );
                        }
                    }
                }
            }
            if preview == ceiling {
                break;
            }
            preview = (preview + STREAM_PREVIEW_STEP).min(ceiling);
        }
    }

    // ── (1) The working chrome is gone at turn end ────────────────────────

    /// After the turn-end edge, none of the working chrome reserves a row.
    ///
    /// The spinner row, the live tool feed, the frozen reasoning box and the
    /// multi-agent roster are all machinery. `settle_working_chrome` is the single
    /// place they are retired, driven off the `Processing → Idle` edge (a TURN
    /// boundary, not a message boundary — one turn contains several generations).
    #[test]
    fn settling_the_turn_retires_every_working_chrome_row() {
        use crate::components::activity::Activity;
        use crate::components::agents::Agents;
        use crate::components::chat::thinking_box::ThinkingBox;

        let mut act = Activity::new();
        act.start();
        act.set_active_verb(Some("shell_execute: cargo build".to_string()));
        act.tool_start_with_id("file_read", "src/main.rs", Some("tc1"));
        act.tool_start_with_id("shell_execute", "cargo build", Some("tc2"));

        let mut agents = Agents::new();
        agents.task_started("task-1");
        agents.agent_started("explorer", "research", "glm", "map the tree", None);
        agents.agent_started("reviewer", "review", "glm", "review the diff", None);

        let mut tb = ThinkingBox::new();
        tb.update("weighing two approaches to the parser rewrite");

        assert!(act.height() > 0 && agents.height() > 0 && !tb.is_empty());

        settle_working_chrome(&mut act, &mut agents, &mut tb);

        assert_eq!(act.height(), 0, "the spinner / tool feed still reserves rows");
        assert_eq!(act.max_height(), 0, "the activity slot is still reserved");
        assert_eq!(agents.height(), 0, "the agent roster still reserves rows");
        assert!(tb.is_empty(), "the reasoning box still reserves rows");

        // Idempotent: the edge can be re-entered (a late duplicate finalization,
        // a reconnect replay) without doing anything different.
        settle_working_chrome(&mut act, &mut agents, &mut tb);
        assert_eq!(act.height() + agents.height(), 0);
    }

    /// A background terminal is NOT working chrome — it is a job that really is
    /// still running, so its summary row legitimately survives the turn.
    #[test]
    fn settling_the_turn_keeps_the_background_terminals_summary() {
        use crate::components::activity::Activity;
        use crate::components::agents::Agents;
        use crate::components::chat::thinking_box::ThinkingBox;

        let mut act = Activity::new();
        act.start();
        let mut agents = Agents::new();
        agents.set_bg_summary(2);
        let mut tb = ThinkingBox::new();

        settle_working_chrome(&mut act, &mut agents, &mut tb);

        assert_eq!(
            agents.height(),
            1,
            "the background-terminals summary was retired with the working chrome"
        );
    }

    // ── (2) No visible double-render ──────────────────────────────────────

    /// The completed answer appears EXACTLY ONCE.
    ///
    /// `insert_before` writes into the terminal's native scrollback and cannot be
    /// mutated afterwards, so the commit-on-complete step is load-bearing. What
    /// must not happen is the preview surviving beside the committed block — the
    /// user would read the tail of the answer twice, in two places. The preview
    /// is therefore dropped in the same event that commits.
    #[test]
    fn the_final_answer_is_committed_once_and_the_preview_is_gone() {
        let answer = "Here is the fix.\n\n1. The parser drops the escape.\n2. The \
                      writer re-adds it.\n\nBoth paths now go through `unescape`.";

        let mut chat = Chat::new();
        let mut stream = AssistantStream::new();
        let mut header = false;

        // Stream it in deltas, as `StreamingToken` does.
        for chunk in answer.as_bytes().chunks(11) {
            let part = std::str::from_utf8(chunk).unwrap();
            assert!(stream.push(Some("m1"), part).is_none());
            chat.update_streaming(stream.text());
        }
        assert!(
            chat.streaming_height(W) > 0,
            "nothing was previewing before completion"
        );

        // …then complete it, as `handle_agent_response` does.
        chat.clear_streaming();
        match stream.finalize(Some("m1"), answer.to_string()) {
            Finalize::Emit(text) => {
                commit_assistant_block(&mut chat, &mut header, &text, None)
            }
            Finalize::Duplicate => panic!("the first finalization must render"),
        }

        // The working chrome's last remnant — the live preview — is gone…
        assert_eq!(
            chat.streaming_height(W),
            0,
            "the live preview survived beside the committed block: the user reads \
             the tail of the answer twice"
        );
        // …and the answer is in scrollback exactly once, byte-identical to what
        // streamed.
        let blocks = chat.agent_blocks();
        assert_eq!(blocks, vec![answer.to_string()], "committed text is not verbatim");
        assert_eq!(
            blocks.join("\n").matches("Both paths now go through").count(),
            1,
            "the answer was rendered more than once"
        );
    }

    /// One turn, SEVERAL generations. Teardown hangs on the turn, not the message:
    /// a superseded generation still commits as its own block, the survivor is not
    /// welded onto it, and the preview is empty only at the end.
    #[test]
    fn several_generations_in_one_turn_each_commit_once() {
        let mut chat = Chat::new();
        let mut stream = AssistantStream::new();
        let mut header = false;

        for (id, text) in [("m1", "First pass at the answer."), ("m2", "Second, better pass.")] {
            if let Some(superseded) = stream.push(Some(id), text) {
                chat.clear_streaming();
                commit_assistant_block(&mut chat, &mut header, &superseded, None);
            }
            chat.update_streaming(stream.text());
            // Mid-turn the preview is live — teardown must NOT have fired here.
            assert!(chat.streaming_height(W) > 0, "the preview died mid-turn at {id}");
        }

        chat.clear_streaming();
        match stream.finalize(Some("m2"), "Second, better pass.".to_string()) {
            Finalize::Emit(t) => commit_assistant_block(&mut chat, &mut header, &t, None),
            Finalize::Duplicate => panic!("m2 must render"),
        }

        assert_eq!(
            chat.agent_blocks(),
            vec![
                "First pass at the answer.".to_string(),
                "Second, better pass.".to_string(),
            ]
        );
        assert_eq!(chat.streaming_height(W), 0, "the preview outlived the turn");
    }

    /// **Ink proof.** Render the committed final block into the stream band while
    /// BOTH bands are on screen with a grown preview: every row of the answer must
    /// survive verbatim. This is the committed-scrollback invariant, extended to
    /// the taller stream band.
    #[test]
    fn a_committed_block_survives_a_grown_preview_beside_both_bands() {
        use ratatui::widgets::Paragraph;

        let mut cl = TaskChecklist::new();
        for i in 0..4 {
            cl.add(format!("t{i}"), format!("plan step {i}"), None);
        }
        let (think_h, agents_h, input_h) = (1u16, 0u16, 3u16);
        let want_checklist = cl.height().min(12);
        let survey_want = 6u16;
        let bands = want_checklist + survey_want;
        let preview = stream_preview_ceiling(60);
        let area_h = streaming_inline_height(
            crate::LIVE_H_BASE + bands,
            think_h + 1 + 2,
            input_h,
            agents_h,
            bands,
            0,
            preview,
            59,
        );
        let fitted = fit_bands(
            Bands {
                checklist: want_checklist,
                think: think_h,
                agents: agents_h,
                survey: survey_want,
                input: input_h,
                ..Default::default()
            },
            area_h,
        );
        let area = Rect::new(0, 0, W, area_h);
        let rows = inline_split(area, fitted);
        assert!(rows[ROW_STREAM].height >= preview);

        const LINE: &str = "the committed answer, row for row";
        let buf = render_to_buffer(
            |f| {
                let lines: Vec<ratatui::text::Line<'static>> = (0..rows[ROW_STREAM].height)
                    .map(|_| ratatui::text::Line::from(LINE))
                    .collect();
                f.render_widget(Paragraph::new(lines), rows[ROW_STREAM]);
                cl.draw(f, rows[ROW_CHECKLIST]);
            },
            W,
            area_h,
        );
        for y in rows[ROW_STREAM].y..(rows[ROW_STREAM].y + rows[ROW_STREAM].height) {
            assert_eq!(
                buffer_row_text(&buf, y),
                LINE,
                "row {y} of the committed block was overpainted:\n{}",
                snapshot_buffer(&buf)
            );
        }
    }
}

// ───────── composer popups + toasts (the last unreserved overlays) ─────────
//
// Two components were still painting into rows nothing had reserved — the same
// defect shape as the task checklist ("one rect handed to two components") and
// the agents tree ("reserved 30, drew 34"):
//
//   * the `@`-mention dropdown and the `/`-command popup were drawn from inside
//     `InputComponent::draw` at `area.y - n`, i.e. ABOVE the composer's own rect,
//     into rows owned by the context-hint row and whatever band sat above it.
//     (The `/` popup's height was at least ADDED to the viewport total, so the
//     region was tall enough — but no band ever claimed the rows, so it still
//     painted over its neighbours. The `@` dropdown was not even counted, so it
//     also silently squeezed the streaming preview.)
//   * toasts were painted, after every band had been laid out, into
//     `toast_rect(area)` — the top three rows of the STREAM band.
//
// Both now own real bands (`ROW_POPUP` between the hint row and the composer,
// `ROW_TOAST` above the stream), reserved through `App::popup_slot` /
// `App::toast_slot` exactly like `checklist_slot` and `survey_slot`. These tests
// hold the shape: drawn ≤ reserved at every width and content size, neighbouring
// ink survives verbatim, a toast expiring gives its rows back, and opening or
// closing the dropdown costs a bounded number of viewport rebuilds.
#[cfg(test)]
mod popup_and_toast_invariants {
    use super::*;
    use crate::app::event_loop::{
        fit_bands, inline_split, Bands, ROW_HINT, ROW_INPUT, ROW_POPUP,
        ROW_STREAM, ROW_TOAST, TOAST_INLINE_CAP,
    };
    use crate::components::input::{InputComponent, MENTION_POPUP_ROWS};
    use crate::components::toast::{ToastLevel, Toasts, MAX_VISIBLE};
    use crate::components::Component;
    use crate::util::cols;
    use ratatui::layout::Rect;
    use ratatui::widgets::Paragraph;

    const W: u16 = 100;

    /// Deliberately hostile mention candidates: a plain path, a very long path,
    /// a CJK path (2 display columns per char) and an emoji one. Width handling
    /// that measures bytes or chars breaks on at least one of these.
    fn wide_paths(n: usize) -> Vec<String> {
        let fixtures = [
            "src/app/event_loop.rs",
            "src/components/input/completions_and_a_very_long_file_name_indeed.rs",
            "ドキュメント/設計/日本語のファイル名.md",
            "assets/🚀-launch-🎉/README.md",
            "priv/rust/tui/src/layout_invariants.rs",
        ];
        (0..n)
            .map(|i| format!("{}#{}", fixtures[i % fixtures.len()], i + 1))
            .collect()
    }

    fn dropdown(n: usize, selected: usize) -> InputComponent {
        let owned = wide_paths(n);
        let refs: Vec<&str> = owned.iter().map(|s| s.as_str()).collect();
        let mut input = InputComponent::new();
        input.set_width(W);
        input.seed_mention_dropdown(&refs, selected);
        input
    }

    fn slash_popup(w: u16) -> InputComponent {
        use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
        let mut input = InputComponent::new();
        input.set_width(w);
        input.set_commands_with_descriptions(
            [
                ("help", "Show all commands"),
                ("compact", "Compact the conversation to free context"),
                ("resume", "Browse and resume a past session"),
                ("model", "Switch the active model"),
                ("quit", "Exit OSA"),
            ]
            .iter()
            .map(|(a, b)| (a.to_string(), b.to_string()))
            .collect(),
        );
        input.handle_event(&crate::event::Event::Terminal(
            crossterm::event::Event::Key(KeyEvent::new(KeyCode::Char('/'), KeyModifiers::NONE)),
        ));
        input
    }

    fn toasts_with(msgs: &[&str]) -> Toasts {
        let mut t = Toasts::new();
        for (i, m) in msgs.iter().enumerate() {
            let level = match i % 4 {
                0 => ToastLevel::Info,
                1 => ToastLevel::Success,
                2 => ToastLevel::Warning,
                _ => ToastLevel::Error,
            };
            t.push((*m).to_string(), level);
        }
        t
    }

    /// Render `draw` with its band parked `above` rows down a taller buffer, and
    /// return the rows that received ink OUTSIDE the band (which must be none).
    fn ink_outside_band<F>(
        w: u16,
        above: u16,
        band_h: u16,
        below: u16,
        draw: F,
    ) -> Vec<(u16, String)>
    where
        F: FnOnce(&mut ratatui::Frame, Rect),
    {
        let total = above + band_h + below;
        let band = Rect::new(0, above, w, band_h);
        let buf = render_to_buffer(|f| draw(f, band), w, total.max(1));
        (0..total)
            .filter(|y| *y < above || *y >= above + band_h)
            .map(|y| (y, buffer_row_text(&buf, y)))
            .filter(|(_, t)| !t.trim().is_empty())
            .collect()
    }

    // ── @-mention dropdown ────────────────────────────────────────────────

    /// **Reserved-vs-drawn sweep.** Across widths AND content sizes (a 1-item
    /// dropdown through a 20-item one), the dropdown must put ink only on the
    /// rows its reservation claimed. The band is parked partway down a taller
    /// buffer so a widget drawing "upward from the composer" — the old
    /// behaviour — lands on rows the assertion can see.
    #[test]
    fn mention_dropdown_never_draws_past_its_reserved_band() {
        for w in [30u16, 40, 60, 80, 100, 140] {
            for n in [1usize, 2, 3, 5, 7, 20] {
                for sel in [0usize, n / 2, n - 1] {
                    let mut input = dropdown(n, sel);
                    input.set_width(w);
                    let reserved = input.mention_popup_height();
                    assert_eq!(
                        reserved, MENTION_POPUP_ROWS,
                        "w={w} n={n}: an open dropdown must reserve a CONSTANT slot"
                    );
                    let stray = ink_outside_band(w, 4, reserved, 4, |f, band| {
                        input.draw_popup(f, band)
                    });
                    assert!(
                        stray.is_empty(),
                        "w={w} n={n} sel={sel}: the dropdown painted outside its \
                         {reserved}-row band: {stray:?}"
                    );
                }
            }
        }
    }

    /// A closed dropdown reserves nothing and draws nothing — an idle live
    /// region must be byte-for-byte what it was before the band existed.
    #[test]
    fn a_closed_dropdown_reserves_and_draws_nothing() {
        let input = InputComponent::new();
        assert_eq!(input.mention_popup_height(), 0);
        let stray = ink_outside_band(W, 2, 0, 6, |f, band| input.draw_popup(f, band));
        assert!(stray.is_empty(), "a closed dropdown painted something: {stray:?}");
    }

    /// **Rebuild budget.** The dropdown re-filters on every keystroke of a
    /// mention, and every inline-viewport height change costs a rebuild (a DSR
    /// cursor query tmux/SSH can drop — the stacked-composer bug class). The
    /// reservation is therefore a CONSTANT while open: a whole typing session,
    /// however many characters and however wildly the match count swings, may
    /// change the reserved height at most twice — once on open, once on close.
    ///
    /// Same shape as `the_preview_grows_in_bounded_steps_and_never_shrinks_mid_turn`.
    #[test]
    fn opening_and_closing_the_dropdown_costs_at_most_two_rebuilds() {
        let mut heights = vec![InputComponent::new().mention_popup_height()];
        // A realistic session: `@` (20 loose matches) narrowing to 1, widening
        // again as the user backspaces, then dismissed.
        for n in [20usize, 12, 7, 3, 1, 2, 6, 20, 9, 1] {
            heights.push(dropdown(n, 0).mention_popup_height());
        }
        heights.push(InputComponent::new().mention_popup_height());
        heights.dedup();
        assert!(
            heights.len() <= 3,
            "the dropdown changed the reserved height {} times ({heights:?}); an \
             open→close session may change it at most twice",
            heights.len()
        );
        assert_eq!(heights.first(), Some(&0));
        assert_eq!(heights.last(), Some(&0));
    }

    /// The popup band never shares a row with the context hint, the composer or
    /// the stream, at any region height or popup size.
    #[test]
    fn popup_band_never_shares_a_row_with_its_neighbours() {
        for area_h in 10u16..=40 {
            for want in 0u16..=12 {
                let wanted = Bands {
                    think: 1,
                    popup: want,
                    input: 3,
                    ..Default::default()
                };
                let bands = fit_bands(wanted, area_h);
                let area = Rect::new(0, 0, W, area_h);
                let rows = inline_split(area, bands);
                for (name, idx) in [("hint", ROW_HINT), ("composer", ROW_INPUT), ("stream", ROW_STREAM)] {
                    assert_eq!(
                        rows[ROW_POPUP].intersection(rows[idx]).height,
                        0,
                        "h={area_h} want={want}: popup {:?} overlaps {name} {:?}",
                        rows[ROW_POPUP],
                        rows[idx]
                    );
                }
                assert!(
                    rows[ROW_INPUT].height >= 1,
                    "h={area_h} want={want}: composer starved by the popup band"
                );
                // Disjointness is vacuous once the arbiter has shed the popup,
                // so also pin that it is only shed under real pressure: the
                // user opened this menu one keystroke ago.
                if wanted.capped().reserved() + crate::app::event_loop::STREAM_FLOOR <= area_h {
                    assert_eq!(
                        rows[ROW_POPUP].height,
                        want.min(crate::app::event_loop::POPUP_INLINE_CAP),
                        "h={area_h} want={want}: the completion band was shed with room to spare"
                    );
                }
            }
        }
    }

    /// **The ink proof.** Fill the neighbouring bands with known content, open
    /// the dropdown into its own band, and every neighbouring row must come out
    /// verbatim. This is the pattern that proved the checklist fix.
    #[test]
    fn drawing_the_mention_dropdown_does_not_erase_its_neighbours() {
        const STREAM: &str = "| table cell | table cell | table cell |";
        const HINT: &str = "42% context used";
        for n in [1usize, 20] {
            let area_h = 28u16;
            let input = dropdown(n, 0);
            let bands = fit_bands(
                Bands {
                    think: 1,
                    popup: input.mention_popup_height(),
                    input: 3,
                    ..Default::default()
                },
                area_h,
            );
            assert!(bands.popup > 0, "the dropdown must reserve a band");
            let area = Rect::new(0, 0, W, area_h);
            let rows = inline_split(area, bands);
            let buf = render_to_buffer(
                |f| {
                    let lines: Vec<ratatui::text::Line<'static>> = (0..rows[ROW_STREAM].height)
                        .map(|_| ratatui::text::Line::from(STREAM))
                        .collect();
                    f.render_widget(Paragraph::new(lines), rows[ROW_STREAM]);
                    f.render_widget(Paragraph::new(HINT), rows[ROW_HINT]);
                    input.draw_popup(f, rows[ROW_POPUP]);
                },
                W,
                area_h,
            );
            for y in rows[ROW_STREAM].y..(rows[ROW_STREAM].y + rows[ROW_STREAM].height) {
                assert_eq!(
                    buffer_row_text(&buf, y).trim_end(),
                    STREAM,
                    "n={n}: stream row {y} was overpainted by the dropdown\n{}",
                    snapshot_buffer(&buf)
                );
            }
            assert_eq!(
                buffer_row_text(&buf, rows[ROW_HINT].y).trim_end(),
                HINT,
                "n={n}: the context-hint row was overpainted by the dropdown\n{}",
                snapshot_buffer(&buf)
            );
            // …and the dropdown really did paint into its own band: the LAST row
            // of the band carries the bottom-anchored content.
            let last = buffer_row_text(&buf, rows[ROW_POPUP].y + bands.popup - 1);
            assert!(
                !last.trim().is_empty(),
                "n={n}: the dropdown band came out blank\n{}",
                snapshot_buffer(&buf)
            );
        }
    }

    /// **Width-aware truncation.** Every drawn row is fitted with `util::fit_cols`
    /// (display COLUMNS, never bytes or chars), so a mention of a file with CJK
    /// or emoji in its path can never overflow the band — at any width.
    #[test]
    fn mention_dropdown_rows_never_exceed_the_band_width() {
        for w in [20u16, 24, 30, 40, 60, 80, 120] {
            let mut input = dropdown(5, 0);
            input.set_width(w);
            let h = input.mention_popup_height();
            let buf = render_to_buffer(
                |f| input.draw_popup(f, Rect::new(0, 0, w, h)),
                w,
                h,
            );
            for y in 0..h {
                let text = buffer_row_text(&buf, y);
                assert!(
                    cols(&text) <= w as usize,
                    "w={w}: dropdown row {y} is {} columns wide: {text:?}",
                    cols(&text)
                );
            }
        }
    }

    /// The visible window always contains the selection. The old overlay always
    /// drew `file_matches[0..5]`, so cycling with ↑/↓ past the fifth of the ten
    /// candidates highlighted a row that was not on screen.
    #[test]
    fn the_dropdown_window_always_contains_the_selection() {
        let n = 10usize;
        let paths = wide_paths(n);
        for sel in 0..n {
            let mut input = dropdown(n, sel);
            input.set_width(W);
            let h = input.mention_popup_height();
            let buf =
                render_to_buffer(|f| input.draw_popup(f, Rect::new(0, 0, W, h)), W, h);
            // Reconstructed the way a terminal shows them — `buffer_row_text`
            // skips the placeholder cells a wide glyph occupies, so a CJK path
            // is not spuriously spaced out.
            let lines: Vec<String> = (0..h).map(|y| buffer_row_text(&buf, y)).collect();
            let screen = lines.join("\n");
            let marked = lines.iter().find(|l| l.contains('\u{25b8}'));
            let marked = marked.unwrap_or_else(|| {
                panic!("sel={sel}: no selection marker on screen\n{screen}")
            });
            // The selected candidate's leaf name must be on the MARKED row (the
            // path is middle-ellipsized, so match on the tail).
            let leaf = paths[sel].rsplit('/').next().unwrap().to_string();
            let tail: String = leaf.chars().rev().take(6).collect::<Vec<_>>().into_iter().rev().collect();
            assert!(
                marked.contains(&tail),
                "sel={sel}: selected candidate {leaf:?} is not the highlighted row\n{screen}"
            );
        }
    }

    /// The `/`-command popup shares the same band and the same contract.
    #[test]
    fn slash_popup_draws_only_inside_its_reserved_band() {
        for w in [40u16, 60, 92, 120] {
            let input = slash_popup(w);
            let reserved = input.completions_popup_height();
            assert!(reserved >= 3, "w={w}: an open `/` popup should want rows");
            let stray =
                ink_outside_band(w, 5, reserved, 5, |f, band| input.draw_popup(f, band));
            assert!(
                stray.is_empty(),
                "w={w}: the `/` popup painted outside its {reserved}-row band: {stray:?}"
            );
        }
    }

    /// Exactly one popup ever paints, so the two can never share a row: with a
    /// `/` popup open the mention dropdown is not drawn.
    #[test]
    fn only_one_popup_ever_paints_into_the_band() {
        let mut input = slash_popup(W);
        input.seed_mention_dropdown(&["src/main.rs", "src/app/mod.rs"], 0);
        let h = input.completions_popup_height().max(input.mention_popup_height());
        let buf = render_to_buffer(|f| input.draw_popup(f, Rect::new(0, 0, W, h)), W, h);
        let screen = snapshot_buffer(&buf);
        assert!(
            screen.contains("/help"),
            "the `/` popup must win the shared band\n{screen}"
        );
        assert!(
            !screen.contains("main.rs"),
            "the mention dropdown painted into the same rows as the `/` popup\n{screen}"
        );
    }

    // ── toasts ────────────────────────────────────────────────────────────

    /// **Reserved-vs-drawn sweep** for toasts: across widths, toast counts and a
    /// short vs. a long wrapping message, the drawn rows equal the reserved ones.
    #[test]
    fn toast_reserved_height_matches_what_it_draws() {
        let long = "the background terminal for the release build exited with status 1 \
                    after 12 minutes — 日本語のメッセージ 🚀 — see the transcript";
        for w in [24u16, 40, 60, 100, 160] {
            for msgs in [
                vec!["saved"],
                vec!["saved", "compacted"],
                vec!["saved", "compacted", "model switched"],
                vec![long],
                vec![long, long, long],
            ] {
                let t = toasts_with(&msgs);
                let reserved = t.live_count();
                assert_eq!(
                    reserved,
                    msgs.len().min(MAX_VISIBLE) as u16,
                    "w={w}: toast reservation must be the live count"
                );
                let stray = ink_outside_band(w, 3, reserved, 5, |f, band| t.draw(f, band));
                assert!(
                    stray.is_empty(),
                    "w={w} msgs={}: toasts painted outside their {reserved}-row band: {stray:?}",
                    msgs.len()
                );
                // Every reserved row is used — no dead rows above the reply.
                let buf = render_to_buffer(
                    |f| t.draw(f, Rect::new(0, 0, w, reserved)),
                    w,
                    reserved.max(1),
                );
                for y in 0..reserved {
                    let text = buffer_row_text(&buf, y);
                    assert!(
                        !text.trim().is_empty(),
                        "w={w}: reserved toast row {y} was left blank\n{}",
                        snapshot_buffer(&buf)
                    );
                    assert!(
                        cols(&text) <= w as usize,
                        "w={w}: toast row {y} is {} columns wide: {text:?}",
                        cols(&text)
                    );
                }
            }
        }
    }

    /// The toast band never shares a row with the stream band or the composer.
    #[test]
    fn toast_band_never_shares_a_row_with_the_stream_band() {
        for area_h in 10u16..=40 {
            for live in 0u16..=TOAST_INLINE_CAP {
                let wanted = Bands {
                    toast: live,
                    think: 1,
                    input: 3,
                    ..Default::default()
                };
                let bands = fit_bands(wanted, area_h);
                let area = Rect::new(0, 0, W, area_h);
                let rows = inline_split(area, bands);
                assert_eq!(
                    rows[ROW_TOAST].intersection(rows[ROW_STREAM]).height,
                    0,
                    "h={area_h} live={live}: toast {:?} overlaps stream {:?}",
                    rows[ROW_TOAST],
                    rows[ROW_STREAM]
                );
                assert_eq!(
                    rows[ROW_TOAST].intersection(rows[ROW_INPUT]).height,
                    0,
                    "h={area_h} live={live}: toast band overlaps the composer"
                );
                assert!(rows[ROW_INPUT].height >= 1);
                // Toasts are first on the shed ladder, so at tight heights the
                // disjointness above is vacuous. Pin the other half: with room
                // to spare, every live toast gets its row.
                if wanted.capped().reserved() + crate::app::event_loop::STREAM_FLOOR <= area_h {
                    assert_eq!(
                        rows[ROW_TOAST].height,
                        live.min(TOAST_INLINE_CAP),
                        "h={area_h} live={live}: the toast band was shed with room to spare"
                    );
                }
            }
        }
    }

    /// **The ink proof for toasts**, short and long/wrapping alike: fill the
    /// stream band with a streaming markdown table, raise the toasts, and every
    /// stream row must survive verbatim. This is the exact defect that shipped —
    /// `toast_rect(area)` used to be the top three rows of the stream band.
    #[test]
    fn raising_a_toast_does_not_erase_the_stream_band() {
        const STREAM: &str = "| table cell | table cell | table cell |";
        let long = "the release build exited with status 1 — 日本語 🚀 — see transcript";
        for msgs in [vec!["saved"], vec![long, long, long]] {
            let area_h = 26u16;
            let t = toasts_with(&msgs);
            let bands = fit_bands(
                Bands {
                    toast: t.live_count(),
                    think: 1,
                    input: 3,
                    ..Default::default()
                },
                area_h,
            );
            assert!(bands.toast > 0, "live toasts must reserve a band");
            let area = Rect::new(0, 0, W, area_h);
            let rows = inline_split(area, bands);
            let buf = render_to_buffer(
                |f| {
                    let lines: Vec<ratatui::text::Line<'static>> = (0..rows[ROW_STREAM].height)
                        .map(|_| ratatui::text::Line::from(STREAM))
                        .collect();
                    f.render_widget(Paragraph::new(lines), rows[ROW_STREAM]);
                    t.draw(f, crate::app::event_loop::toast_window(rows[ROW_TOAST]));
                },
                W,
                area_h,
            );
            for y in rows[ROW_STREAM].y..(rows[ROW_STREAM].y + rows[ROW_STREAM].height) {
                assert_eq!(
                    buffer_row_text(&buf, y).trim_end(),
                    STREAM,
                    "stream row {y} was overpainted by a toast\n{}",
                    snapshot_buffer(&buf)
                );
            }
            assert!(
                !buffer_row_text(&buf, rows[ROW_TOAST].y).trim().is_empty(),
                "the toast band came out blank\n{}",
                snapshot_buffer(&buf)
            );
        }
    }

    /// **Expiry restores what the toast covered.** Once the dwell elapses the
    /// band collapses to zero rows and the stream gets them back — with the
    /// reply's own content on them, not a hole.
    #[test]
    fn toast_expiry_restores_the_rows_it_covered() {
        use std::time::Duration;
        const STREAM: &str = "| table cell | table cell | table cell |";
        let area_h = 26u16;
        let mut t = toasts_with(&["saved", "compacted", "model switched"]);

        let live_bands = |live: u16| {
            fit_bands(
                Bands {
                    toast: live,
                    think: 1,
                    input: 3,
                    ..Default::default()
                },
                area_h,
            )
        };
        let with_toasts = live_bands(t.live_count()).toast;
        assert_eq!(with_toasts, 3, "three live toasts reserve three rows");

        // Dwell elapses (errors linger longest at 6s).
        t.age_all(Duration::from_secs(30));
        t.tick();
        assert!(!t.has_toasts(), "the dwell elapsed; no toast should be live");
        assert_eq!(t.live_count(), 0, "an expired toast must give its rows back");

        let area = Rect::new(0, 0, W, area_h);
        let after = inline_split(area, live_bands(t.live_count()));
        let before = inline_split(area, live_bands(3));
        assert_eq!(
            after[ROW_STREAM].height,
            before[ROW_STREAM].height + with_toasts,
            "the stream band did not get the toast's rows back"
        );

        // And the reply repaints onto them — the rows the toast covered are the
        // reply's again, verbatim.
        let buf = render_to_buffer(
            |f| {
                let lines: Vec<ratatui::text::Line<'static>> = (0..after[ROW_STREAM].height)
                    .map(|_| ratatui::text::Line::from(STREAM))
                    .collect();
                f.render_widget(Paragraph::new(lines), after[ROW_STREAM]);
                if after[ROW_TOAST].height > 0 {
                    t.draw(f, crate::app::event_loop::toast_window(after[ROW_TOAST]));
                }
            },
            W,
            area_h,
        );
        for y in after[ROW_STREAM].y..(after[ROW_STREAM].y + after[ROW_STREAM].height) {
            assert_eq!(
                buffer_row_text(&buf, y).trim_end(),
                STREAM,
                "row {y} did not come back after the toast expired\n{}",
                snapshot_buffer(&buf)
            );
        }
    }
}

/// ── Settling: completed prose reaches scrollback while the turn is still running
///
/// The reply used to live entirely inside the capped inline preview until the
/// turn ended, which produced two halves of one complaint:
///
///   * completion *revealed* the answer — the user had been watching text they
///     were never allowed to read in place; and
///   * while the turn ran, each tool-progress row appended below the prose
///     pushed a row of prose off the top of the capped region. The live region
///     is not scrollback: what falls off the top is gone.
///
/// `AssistantStream::settle` fixes both by handing completed markdown blocks to
/// native scrollback as they complete. These are the invariants that keep it
/// honest: the transcript must end up byte-identical to the authoritative final,
/// exactly once, however the text was sliced on the way there.
#[cfg(test)]
mod settling_invariants {
    use crate::app::assistant_stream::{
        commit_assistant_block, commit_assistant_chunk, AssistantStream, Finalize,
    };
    use crate::app::settle_guard;
    use crate::components::chat::Chat;
    use crate::render::markdown::render_markdown;

    const W: u16 = 80;

    /// A long reply with every block kind that has a freeze rule.
    const LONG: &str = "\
# Findings

The parser drops the escape before the writer sees it.

## Where it goes wrong

- `unescape` is called twice on the same span
- the second call is a no-op, so nothing looks broken
- the *third* caller then re-escapes

```rust
fn unescape(s: &str) -> Cow<'_, str> {
    if !s.contains('x') { return Cow::Borrowed(s); }
    Cow::Owned(s.replace(\"a\", \"b\"))
}
```

| Path | Before | After |
|---|---|---|
| read | 2 calls | 1 call |
| write | 1 call | 1 call |

> Both paths now go through the same helper.

That is the whole change.";

    /// Drive the two handlers the way the app does: deltas settle blocks into
    /// scrollback as they complete, then the final commits whatever is left.
    /// Returns the chat plus how many blocks settled early.
    fn run_turn(full: &str, final_text: &str, chunk: usize) -> (Chat, usize) {
        let mut chat = Chat::new();
        let mut stream = AssistantStream::new();
        let mut header = false;
        let mut settled = 0usize;

        let mut cut = 0usize;
        while cut < full.len() {
            let mut end = (cut + chunk).min(full.len());
            while !full.is_char_boundary(end) {
                end += 1;
            }
            // `StreamingToken`
            assert!(stream.push(Some("m1"), &full[cut..end]).is_none());
            while let Some(block) = stream.settle() {
                settled += 1;
                commit_assistant_chunk(&mut chat, &mut header, &block, None);
            }
            chat.update_streaming(stream.tail());
            cut = end;
        }

        // `AgentResponse`
        chat.clear_streaming();
        match stream.finalize(Some("m1"), final_text.to_string()) {
            Finalize::Emit(rest) => {
                commit_assistant_chunk(&mut chat, &mut header, &rest, None);
                chat.end_agent_chunk_flow();
            }
            Finalize::Duplicate => panic!("the first finalization must render"),
        }
        (chat, settled)
    }

    /// **The headline invariant.** A long multi-block reply ends with the full
    /// text in scrollback exactly once, byte-identical to the final — no matter
    /// how much of it was committed early.
    #[test]
    fn a_long_reply_lands_in_scrollback_exactly_once_and_verbatim() {
        for chunk in [1usize, 3, 17, 64, LONG.len()] {
            let (chat, settled) = run_turn(LONG, LONG, chunk);
            let joined = chat.agent_blocks().join("");
            assert_eq!(
                joined, LONG,
                "chunk={chunk}: scrollback is not byte-identical to the final"
            );
            // Nothing rendered twice — the most distinctive line appears once.
            assert_eq!(
                joined.matches("That is the whole change.").count(),
                1,
                "chunk={chunk}: the tail was rendered more than once"
            );
            assert_eq!(
                joined.matches("The parser drops the escape").count(),
                1,
                "chunk={chunk}: an early-committed block was repeated by the final"
            );
            if chunk < LONG.len() {
                assert!(
                    settled > 0,
                    "chunk={chunk}: nothing settled early — the whole reply still \
                     appeared only at completion"
                );
            }
        }
    }

    /// The point of the whole change, stated directly: by the time the turn ends,
    /// nearly all of the reply is ALREADY in scrollback. Completion reveals only
    /// the last, still-unfinished block.
    #[test]
    fn completion_reveals_only_the_unfinished_tail() {
        let mut chat = Chat::new();
        let mut stream = AssistantStream::new();
        let mut header = false;

        for chunk in LONG.as_bytes().chunks(7) {
            let part = std::str::from_utf8(chunk).unwrap();
            stream.push(Some("m1"), part);
            while let Some(block) = stream.settle() {
                commit_assistant_chunk(&mut chat, &mut header, &block, None);
            }
        }
        let already_read: usize = chat.agent_blocks().iter().map(|b| b.len()).sum();
        assert!(
            already_read * 100 / LONG.len() >= 90,
            "only {already_read}/{} bytes were readable before completion — the \
             answer still materialises at turn end",
            LONG.len()
        );

        // Whatever completion adds is the final block only.
        let before = chat.agent_blocks().len();
        match stream.finalize(Some("m1"), LONG.to_string()) {
            Finalize::Emit(rest) => {
                assert!(
                    rest.len() * 4 < LONG.len(),
                    "completion still had to render {} of {} bytes",
                    rest.len(),
                    LONG.len()
                );
                commit_assistant_chunk(&mut chat, &mut header, &rest, None);
            }
            Finalize::Duplicate => panic!("the first finalization must render"),
        }
        assert!(chat.agent_blocks().len() >= before);
    }

    /// **Stream-vs-batch equivalence, at the rendering layer.** Committing block
    /// by block must produce exactly the rows a one-shot render of the whole
    /// message produces — that is the property `find_frozen_boundary` exists to
    /// guarantee, and settling is a new consumer of it.
    #[test]
    fn chunked_commits_render_identically_to_one_batch_render() {
        fn flat(t: &ratatui::text::Text<'_>) -> Vec<String> {
            t.lines
                .iter()
                .map(|l| l.spans.iter().map(|s| s.content.as_ref()).collect())
                .collect()
        }
        let (chat, settled) = run_turn(LONG, LONG, 5);
        assert!(settled > 1, "the reply must have settled in several pieces");

        let mut chunked: Vec<String> = Vec::new();
        for block in chat.agent_blocks() {
            chunked.extend(flat(&render_markdown(&block, W - 2)));
        }
        let batch = flat(&render_markdown(LONG, W - 2));
        assert_eq!(
            chunked, batch,
            "chunk-by-chunk rendering diverged from a one-shot render"
        );
    }

    /// Several generations in one turn still commit once each. Blocks that
    /// settled under a superseded generation must NOT be handed back for a second
    /// render when that generation is flushed.
    #[test]
    fn several_generations_each_commit_once_with_settling() {
        let gen1 = "First pass at the answer.\n\nWith a second paragraph.\n\nAnd a trailing thought";
        let gen2 = "Second, better pass.\n\nAlso in two paragraphs.\n\nDone";

        let mut chat = Chat::new();
        let mut stream = AssistantStream::new();
        let mut header = false;

        for (id, text) in [("m1", gen1), ("m2", gen2)] {
            for chunk in text.as_bytes().chunks(9) {
                let part = std::str::from_utf8(chunk).unwrap();
                if let Some(superseded) = stream.push(Some(id), part) {
                    chat.clear_streaming();
                    commit_assistant_block(&mut chat, &mut header, &superseded, None);
                }
                while let Some(block) = stream.settle() {
                    commit_assistant_chunk(&mut chat, &mut header, &block, None);
                }
                chat.update_streaming(stream.tail());
            }
        }
        chat.clear_streaming();
        match stream.finalize(Some("m2"), gen2.to_string()) {
            Finalize::Emit(rest) => {
                commit_assistant_chunk(&mut chat, &mut header, &rest, None);
                chat.end_agent_chunk_flow();
            }
            Finalize::Duplicate => panic!("m2 must render"),
        }

        // NUL-joined so a block boundary is visible: welding is two generations
        // inside ONE block, which the separator would not hide.
        let joined = chat.agent_blocks().join("\u{0}");
        // The exact reported corruption must stay impossible.
        assert!(
            !joined.contains("thoughtSecond, better pass"),
            "a superseded generation was welded to its replacement: {joined:?}"
        );
        for needle in [
            "First pass at the answer.",
            "With a second paragraph.",
            "And a trailing thought",
            "Second, better pass.",
            "Also in two paragraphs.",
        ] {
            assert_eq!(joined.matches(needle).count(), 1, "{needle} rendered twice");
        }
    }

    /// A repeat `agent_response` after settling is still a no-op: the duplicate
    /// record holds the FULL final, not the residue that was emitted.
    #[test]
    fn a_replayed_final_renders_nothing_after_settling() {
        let mut chat = Chat::new();
        let mut stream = AssistantStream::new();
        let mut header = false;

        for chunk in LONG.as_bytes().chunks(13) {
            stream.push(Some("m1"), std::str::from_utf8(chunk).unwrap());
            while let Some(b) = stream.settle() {
                commit_assistant_chunk(&mut chat, &mut header, &b, None);
            }
        }
        match stream.finalize(Some("m1"), LONG.to_string()) {
            Finalize::Emit(rest) => commit_assistant_chunk(&mut chat, &mut header, &rest, None),
            Finalize::Duplicate => panic!("the first finalization must render"),
        }
        let after_first = chat.agent_blocks();
        assert_eq!(
            stream.finalize(Some("m1"), LONG.to_string()),
            Finalize::Duplicate,
            "an SSE replay must not render a second copy"
        );
        assert_eq!(chat.agent_blocks(), after_first);
    }

    // ── The guardrail gate ────────────────────────────────────────────────

    /// The prompt-leak scrub throws the whole response away. Nothing containing
    /// even ONE fingerprint may be committed early, so the text that is already
    /// on screen when the scrub fires contains zero — which is, by the detector's
    /// own documented standard ("a single phrase can appear incidentally; two
    /// together indicate a leak"), not system-prompt content.
    #[test]
    fn a_leaking_reply_settles_nothing_from_the_fingerprint_onward() {
        let leak = "Here is a harmless opening.\n\nMy tool usage policy says to \
                    explore before you act.\n\nAnd more.\n\ntail";
        let mut stream = AssistantStream::new();
        let mut committed = String::new();
        for chunk in leak.as_bytes().chunks(6) {
            stream.push(Some("m1"), std::str::from_utf8(chunk).unwrap());
            while let Some(b) = stream.settle() {
                committed.push_str(&b);
            }
        }
        assert!(
            !committed.is_empty(),
            "the fingerprint-free opening should still have settled"
        );
        assert!(
            !settle_guard::contains_leak_fingerprint(&committed),
            "committed text carries a fingerprint: {committed:?}"
        );
        assert!(
            !committed.contains("explore before you act"),
            "the gate let leaked text through"
        );

        // …and the refusal that replaces the response still renders, in full.
        let refusal = "I can't share my internal configuration or system instructions.";
        match stream.finalize(Some("m1"), refusal.to_string()) {
            Finalize::Emit(t) => assert_eq!(t, refusal),
            Finalize::Duplicate => panic!("the refusal must render"),
        }
    }

    /// A dead phrase closes the gate too: `strip_dead_phrases` rewrites the
    /// response, so nothing may settle behind it.
    #[test]
    fn a_dead_phrase_closes_the_gate() {
        let text = "A clean first paragraph.\n\nCertainly! Here is more.\n\nAnd a third.\n\ntail";
        let mut stream = AssistantStream::new();
        let mut committed = String::new();
        for chunk in text.as_bytes().chunks(5) {
            stream.push(Some("m1"), std::str::from_utf8(chunk).unwrap());
            while let Some(b) = stream.settle() {
                committed.push_str(&b);
            }
        }
        assert_eq!(committed, "A clean first paragraph.\n\n");
        assert!(!settle_guard::contains_dead_phrase(&committed));
    }

    /// A final that was re-whitespaced behind the committed prefix (what the dead
    /// phrase strip does to the WHOLE response once it fires) is still recognised,
    /// so the settled blocks are not re-rendered under it.
    #[test]
    fn a_rewhitespaced_final_does_not_duplicate_the_settled_prefix() {
        let streamed = "Intro line.\n\nBody with  a double space.\n\nEnd";
        let mut stream = AssistantStream::new();
        let mut committed = String::new();
        for chunk in streamed.as_bytes().chunks(4) {
            stream.push(Some("m1"), std::str::from_utf8(chunk).unwrap());
            while let Some(b) = stream.settle() {
                committed.push_str(&b);
            }
        }
        assert!(committed.starts_with("Intro line."));
        // The backend's normalisation collapsed the double space.
        let scrubbed = "Intro line.\n\nBody with a double space.\n\nEnd";
        match stream.finalize(Some("m1"), scrubbed.to_string()) {
            Finalize::Emit(rest) => {
                assert!(
                    !rest.contains("Intro line."),
                    "the settled prefix was re-emitted under a re-whitespaced final: {rest:?}"
                );
                assert!(rest.ends_with("End"));
            }
            Finalize::Duplicate => panic!("must render"),
        }
    }

    /// A final that genuinely diverges is never matched fuzzily: the residue
    /// retreats to a settled BLOCK boundary, never to the middle of a sentence.
    #[test]
    fn a_diverged_final_retreats_to_a_block_boundary() {
        let streamed = "Block one.\n\nBlock two.\n\nBlock three";
        let mut stream = AssistantStream::new();
        for chunk in streamed.as_bytes().chunks(4) {
            stream.push(Some("m1"), std::str::from_utf8(chunk).unwrap());
            while stream.settle().is_some() {}
        }
        assert!(stream.settled_bytes() > 0);
        // Backend replaced everything from block two onwards.
        let diverged = "Block one.\n\nSomething else entirely.";
        match stream.finalize(Some("m1"), diverged.to_string()) {
            Finalize::Emit(rest) => {
                assert_eq!(
                    rest, "Something else entirely.",
                    "divergence must resume at a block boundary"
                );
            }
            Finalize::Duplicate => panic!("must render"),
        }
    }

    /// A tool call flushing mid-message must hand over only what has NOT already
    /// settled — otherwise the tool-interleaved flush re-renders the paragraphs
    /// the user has been reading.
    #[test]
    fn a_tool_flush_hands_over_only_the_unsettled_tail() {
        let mut stream = AssistantStream::new();
        let mut committed = String::new();
        for chunk in "Let me check that.\n\nReading the file now"
            .as_bytes()
            .chunks(5)
        {
            stream.push(Some("m1"), std::str::from_utf8(chunk).unwrap());
            while let Some(b) = stream.settle() {
                committed.push_str(&b);
            }
        }
        assert_eq!(committed, "Let me check that.\n\n");
        assert_eq!(stream.take(), "Reading the file now");
        assert!(stream.is_empty());
    }

    // ── Rebuild budget ────────────────────────────────────────────────────

    /// Every `insert_before` is a full viewport rebuild, so per-block committing
    /// could have turned one rebuild per reply into one per paragraph. The drain
    /// batches everything queued in the same iteration into ONE call, so the cost
    /// is bounded by *frames in which something settled*, not by blocks.
    ///
    /// Mirrors the batching arithmetic in `event_loop`'s step 2 exactly.
    #[test]
    fn a_sixty_block_reply_stays_within_the_rebuild_budget() {
        const BLOCKS: usize = 60;
        const TERM_ROWS: u16 = 40;

        let mut doc = String::new();
        for i in 0..BLOCKS {
            doc.push_str(&format!("Paragraph number {i} of the reply.\n\n"));
        }

        /// One drain pass: how many `insert_before` calls it costs.
        fn rebuilds(heights: &[u16], cap: u16) -> usize {
            let (mut calls, mut acc) = (0usize, 0u16);
            for &h in heights {
                if h == 0 {
                    continue;
                }
                if acc > 0 && acc.saturating_add(h) > cap {
                    calls += 1;
                    acc = 0;
                }
                acc = acc.saturating_add(h);
            }
            if acc > 0 {
                calls += 1;
            }
            calls
        }

        // Worst case for the batcher: the reply trickles in, so every paragraph
        // settles as its OWN queued block, and they are then drained together in
        // one pass. (When a whole reply lands in one delta the boundary scan
        // coalesces it into a single block for free — that case costs 1 call.)
        let mut chat = Chat::new();
        let mut stream = AssistantStream::new();
        let mut header = false;
        let mut blocks = 0;
        for byte in doc.as_bytes().chunks(1) {
            stream.push(Some("m1"), std::str::from_utf8(byte).unwrap());
            while let Some(b) = stream.settle() {
                blocks += 1;
                commit_assistant_chunk(&mut chat, &mut header, &b, None);
            }
        }
        assert_eq!(blocks, BLOCKS, "each paragraph should have settled separately");
        let heights: Vec<u16> = chat
            .drain_scrollback()
            .iter()
            .map(|m| m.height(W))
            .collect();
        let total: u16 = heights.iter().copied().sum();
        let calls = rebuilds(&heights, TERM_ROWS);
        // Only the screenful cap may split the batch — never the block count.
        let floor = (total as usize).div_ceil(TERM_ROWS as usize);
        assert!(
            calls <= floor + 1,
            "a {BLOCKS}-block reply drained in one pass cost {calls} viewport \
             rebuilds ({total} rows, cap {TERM_ROWS}); the batcher should need \
             about {floor}"
        );
        assert!(
            calls * 4 < BLOCKS,
            "batching did not help: {calls} rebuilds for {BLOCKS} separately \
             queued blocks"
        );

        // And the arithmetic degenerates correctly: one tall message still goes
        // out on its own rather than being dropped.
        assert_eq!(rebuilds(&[100], TERM_ROWS), 1);
        assert_eq!(rebuilds(&[], TERM_ROWS), 0);
        assert_eq!(rebuilds(&[1, 1, 1], TERM_ROWS), 1);
    }
}


// ─────────────────── resize / reflow invariants ───────────────────
//
// Resize has been OSA's most repeatedly-regressed surface: the composer
// duplicating down the screen, a DSR crash on a width-only resize, a full wipe
// firing on every height change, and — the one that motivated this module — a
// cascade of markdown-table rules deposited into scrollback, one per step of a
// window drag.
//
// Those were four local fixes to one structural problem: a resize is the only
// path that touches the terminal OUTSIDE the region OSA owns, and nothing
// asserted what it was allowed to touch. The invariants below state the rules
// directly.
//
// The load-bearing one is the ED2 ban. `Clear(ClearType::All)` and
// `MoveTo(0,0) + Clear(FromCursorDown)` are visually identical and only one of
// them is an erase: the VTE family (GNOME Terminal and every other libvte
// embedder) implements ED2 by SCROLLING the screen into scrollback, so emitting
// it once per resize step permanently deposits one snapshot of the live region
// per step. `vt100` — like xterm — models ED2 as a pure erase, so no
// screen-level assertion can see this. The only place the difference is visible
// is the emitted byte stream, which is where it is asserted.
#[cfg(test)]
mod resize_invariants {
    use ratatui::layout::Rect;
    use ratatui::{Terminal, TerminalOptions, Viewport};

    use crate::app::assistant_stream::{commit_assistant_chunk, AssistantStream};
    use crate::app::event_loop::{clear_screen_for_resize, purge_scrollback_into};
    use crate::components::chat::message::{Message, MessageType};
    use crate::components::chat::Chat;
    use crate::test_backend::VT100Backend;

    /// ED2. Never legal on the inline path.
    const ED2: &str = "\u{1b}[2J";
    /// ED0 in both the explicit and defaulted forms crossterm may emit.
    const ED0: [&str; 2] = ["\u{1b}[J", "\u{1b}[0J"];
    /// ED3 (erase saved lines) — the only sequence allowed to touch history,
    /// and only for `/clear`.
    const ED3: &str = "\u{1b}[3J";

    fn emitted(f: impl FnOnce(&mut Vec<u8>)) -> String {
        let mut out: Vec<u8> = Vec::new();
        f(&mut out);
        String::from_utf8(out).expect("escape sequences are ASCII")
    }

    /// A reply of exactly the shape that produced the cascade: prose, a bordered
    /// markdown table, a thematic break, more prose.
    const TABLE_REPLY: &str = "\
Here are the three options.

| Option | Cost | Notes |
|---|---|---|
| Alpha | 1 | cheapest |
| Beta | 2 | balanced |
| Gamma | 3 | fastest |

---

Beta is the one I would pick.
";

    /// Glyphs unique to one committed block, used to count copies. `┌` appears
    /// exactly once per rendered table (its top-left frame corner).
    const TABLE_CORNER: char = '\u{250c}';

    /// How many rows anywhere the user can still reach — scroll history plus the
    /// live screen — contain `needle`.
    fn copies_reachable(backend: &VT100Backend, needle: char) -> usize {
        backend
            .scrollback_lines()
            .iter()
            .map(String::as_str)
            .chain(backend.contents().lines())
            .filter(|l| l.contains(needle))
            .count()
    }

    /// The event loop's resize step, end to end: the emulator reflows, the
    /// screen is erased, the inline viewport is rebuilt fresh at the new size.
    fn resize_step(term: Terminal<VT100Backend>, w: u16, h: u16, inline_h: u16) -> Terminal<VT100Backend> {
        let mut backend = term.backend().fork();
        drop(term);
        backend.resize(w, h);
        clear_screen_for_resize(&mut backend).unwrap();
        Terminal::with_options(
            backend,
            TerminalOptions {
                viewport: Viewport::Inline(inline_h.min(h.saturating_sub(1)).max(1)),
            },
        )
        .unwrap()
    }

    /// The event loop's step 2: drain queued blocks into native scrollback in
    /// one batched `insert_before`, rendered at the CURRENT width.
    fn commit_all(term: &mut Terminal<VT100Backend>, msgs: Vec<Message>) {
        let w = term.get_frame().area().width;
        let sized: Vec<(Message, u16)> = msgs
            .into_iter()
            .map(|m| {
                let h = m.height(w);
                (m, h)
            })
            .filter(|(_, h)| *h > 0)
            .collect();
        let total: u16 = sized.iter().map(|(_, h)| *h).sum();
        if total == 0 {
            return;
        }
        term.insert_before(total, |buf| {
            let mut y = 0u16;
            for (m, h) in sized.iter() {
                m.render_to_buffer(Rect::new(0, y, w, *h), buf, 0);
                y = y.saturating_add(*h);
            }
        })
        .unwrap();
    }

    // ── the ban itself ──────────────────────────────────────────────

    /// **The regression.** A resize may erase the screen; it may not push it
    /// into scroll history. On VTE that distinction is the whole bug.
    #[test]
    fn resize_clear_erases_in_place_and_never_scrolls_into_history() {
        let seq = emitted(|out| clear_screen_for_resize(out).unwrap());
        assert!(
            !seq.contains(ED2),
            "the resize clear emitted ED2 (ESC[2J). On the VTE family that \
             SCROLLS the live region into scrollback instead of erasing it, so \
             a window drag leaves one unreflowable snapshot per step — the \
             table-rule cascade. Use MoveTo(0,0) + ClearType::FromCursorDown. \
             Emitted: {seq:?}"
        );
        assert!(
            ED0.iter().any(|e| seq.contains(e)),
            "the resize clear must still erase the whole screen (ED0 from \
             home); emitted {seq:?}"
        );
        assert!(
            !seq.contains(ED3),
            "a resize must never purge the user's scroll history; that is \
             /clear's job alone. Emitted: {seq:?}"
        );
    }

    /// `/clear` is the ONLY caller allowed to destroy history — and it has the
    /// same ED2 hazard in reverse: purging and then emitting ED2 hands one
    /// final screenful back to the scrollback it just emptied.
    #[test]
    fn clear_command_erases_the_screen_before_purging_and_never_uses_ed2() {
        let seq = emitted(|out| purge_scrollback_into(out).unwrap());
        assert!(
            !seq.contains(ED2),
            "/clear emitted ED2 after ED3; on VTE that re-deposits the visible \
             screen into the history it just purged. Emitted: {seq:?}"
        );
        assert!(ed3_follows_an_erase(&seq), "the visible screen must be erased BEFORE the purge; emitted {seq:?}");
    }

    fn ed3_follows_an_erase(seq: &str) -> bool {
        let purge = match seq.find(ED3) {
            Some(i) => i,
            None => return false,
        };
        ED0.iter()
            .filter_map(|e| seq.find(e))
            .any(|i| i < purge)
    }

    // ── committed blocks are committed once ─────────────────────────

    /// **The invariant the cascade violated**, stated positively and swept: a
    /// block that has reached native scrollback stays there exactly once, no
    /// matter how the terminal is subsequently resized.
    ///
    /// The sweep covers every shape of resize the loop distinguishes — shrink,
    /// grow, width-only, height-only, and rapid alternation — because each took
    /// a different branch in the code that regressed.
    #[test]
    fn a_committed_block_survives_a_resize_sweep_exactly_once() {
        // Small screen + a tall reply, so the commit genuinely scrolls into the
        // emulator's history rather than merely landing on screen.
        let (w0, h0) = (72u16, 10u16);
        let mut term = Terminal::with_options(
            VT100Backend::with_scrollback(w0, h0, 4000),
            TerminalOptions { viewport: Viewport::Inline(4) },
        )
        .unwrap();

        commit_all(
            &mut term,
            vec![Message::new(MessageType::Agent, TABLE_REPLY.to_string(), None)],
        );
        assert_eq!(
            copies_reachable(term.backend(), TABLE_CORNER),
            1,
            "sanity: the table must be committed exactly once to begin with"
        );

        // width-only ↓, width-only ↑, height-only, both, and a rapid drag.
        let sweep: Vec<(u16, u16)> = vec![
            (71, 10), (70, 10), (69, 10), (68, 10),      // the drag that regressed
            (68, 14), (68, 9),                            // height-only
            (100, 9), (40, 9),                            // width jumps
            (40, 24), (120, 30), (60, 12),                // both
            (61, 12), (60, 12), (61, 12), (60, 12),       // alternation
        ];
        for (w, h) in sweep {
            term = resize_step(term, w, h, 4);
            term.draw(|f| {
                let a = f.area();
                f.render_widget(
                    ratatui::widgets::Paragraph::new("> "),
                    Rect::new(a.x, a.y, a.width, 1.min(a.height)),
                );
            })
            .unwrap();
            let n = copies_reachable(term.backend(), TABLE_CORNER);
            assert_eq!(
                n, 1,
                "after resizing to {w}x{h} the committed table is reachable \
                 {n} times, not once. >1 means the resize re-emitted content \
                 the user had already been given (the cascade); 0 means it \
                 destroyed history it does not own."
            );
        }
    }

    /// Same invariant for a reply that is still STREAMING when the resize
    /// lands: blocks that settled early are already immutable history, and the
    /// unsettled tail must not be committed by the resize at all.
    #[test]
    fn a_resize_mid_stream_neither_duplicates_settled_blocks_nor_commits_the_tail() {
        let mut term = Terminal::with_options(
            VT100Backend::with_scrollback(72, 10, 4000),
            TerminalOptions { viewport: Viewport::Inline(4) },
        )
        .unwrap();

        let mut chat = Chat::new();
        let mut stream = AssistantStream::new();
        let mut header = false;

        // Stream up to (but not past) the closing paragraph. A table only
        // freezes once a following block proves it finished growing, so the
        // trailing `---` has to be in the buffer for the table to settle — and
        // the final paragraph is then the part still in flight.
        let cut = TABLE_REPLY.find("Beta is").unwrap();
        for byte in TABLE_REPLY[..cut].as_bytes().chunks(1) {
            stream.push(Some("m1"), std::str::from_utf8(byte).unwrap());
            while let Some(b) = stream.settle() {
                commit_assistant_chunk(&mut chat, &mut header, &b, None);
            }
        }
        commit_all(&mut term, chat.drain_scrollback());
        assert_eq!(
            copies_reachable(term.backend(), TABLE_CORNER),
            1,
            "sanity: the settled table must be in history exactly once"
        );

        for (w, h) in [(71u16, 10u16), (68, 10), (68, 20), (44, 20), (90, 8)] {
            term = resize_step(term, w, h, 4);
            // A resize must not make the stream hand anything back: `settle`
            // has no width input, and re-settling after a resize is exactly the
            // re-commit that produced the cascade.
            assert!(
                stream.settle().is_none(),
                "resizing to {w}x{h} caused the in-flight stream to re-settle \
                 bytes it had already committed"
            );
            assert!(
                !chat.has_pending_scrollback(),
                "resizing to {w}x{h} queued a block for scrollback; a resize is \
                 not a commit point"
            );
            term.draw(|f| {
                f.render_widget(ratatui::widgets::Paragraph::new("> "), f.area());
            })
            .unwrap();
            let n = copies_reachable(term.backend(), TABLE_CORNER);
            assert_eq!(
                n, 1,
                "after a mid-stream resize to {w}x{h} the settled table is \
                 reachable {n} times, not once"
            );
        }
    }

    /// The commit queue itself must be width-independent: draining is what
    /// commits, and no amount of re-laying-out may put a drained block back.
    ///
    /// This is the cheap, total version of the invariant above — it holds for
    /// every block kind at once, without a terminal.
    #[test]
    fn a_width_sweep_never_re_queues_an_already_drained_block() {
        let mut chat = Chat::new();
        chat.add_user_message("compare the options");
        let mut stream = AssistantStream::new();
        let mut header = false;
        stream.push(Some("m1"), TABLE_REPLY);
        while let Some(b) = stream.settle() {
            commit_assistant_chunk(&mut chat, &mut header, &b, None);
        }

        let drained = chat.drain_scrollback();
        assert!(!drained.is_empty(), "sanity: something must have been queued");
        assert!(!chat.has_pending_scrollback());

        for w in (20u16..=200).step_by(3) {
            chat.set_size(w, 24);
            chat.invalidate_width_caches();
            assert!(
                !chat.has_pending_scrollback(),
                "re-laying out at width {w} re-queued an already-committed \
                 block; commits must be idempotent per block across resize"
            );
            assert!(chat.drain_scrollback().is_empty(), "width {w}");
        }
    }

    /// A block's committed height must match the rows it actually paints at the
    /// width it was committed at — for every width in the sweep. A disagreement
    /// here is how a resize leaves half a table stranded above the viewport.
    #[test]
    fn reserved_equals_drawn_for_a_committed_table_at_every_width() {
        for w in 20u16..=200 {
            let msg = Message::new(MessageType::Agent, TABLE_REPLY.to_string(), None);
            let h = msg.height(w);
            assert!(h > 0, "width {w}: a non-empty reply must reserve rows");
            let mut buf = ratatui::buffer::Buffer::empty(Rect::new(0, 0, w, h + 4));
            msg.render_to_buffer(Rect::new(0, 0, w, h), &mut buf, 0);
            for y in h..h + 4 {
                for x in 0..w {
                    assert_eq!(
                        buf[(x, y)].symbol().trim(),
                        "",
                        "width {w}: reserved {h} rows but painted ink on row {y}"
                    );
                }
            }
        }
    }

    // ── the drag: one live region, however many columns it crossed ───

    /// The three rows a user counts when they say "the composer duplicated".
    ///
    /// Deliberately synthetic rather than the real `InputComponent` /
    /// `StatusBar`: this bug is geometric, not textual, and a marker that cannot
    /// drift keeps the assertion ("exactly one of each, anywhere the user can
    /// still reach") readable and independent of copy changes in the chrome.
    /// The SHAPE mirrors `App::draw_inline_chrome` — a full-width rule, the
    /// composer, the hint row, the status bar — plus, optionally, the bands a
    /// live turn puts above them.
    const COMPOSER: &str = "COMPOSER\u{2588}";
    const HINT: &str = "HINT\u{2588}";
    const STATUS: &str = "STATUS\u{2588}";
    /// A band row, in shed-priority order: the LAST one is dropped first.
    const BANDS: [&str; 3] = ["TOAST\u{2588}", "CHECKLIST\u{2588}", "SURVEY\u{2588}"];

    /// How tall the live region wants to be, given how many bands are up.
    /// `1` rule + `1` composer + `1` hint + `1` status + one row per band.
    fn chrome_height(bands: usize) -> u16 {
        4 + bands as u16
    }

    /// Paint the live region into `area`, shedding bands from the lowest
    /// priority up until it fits. The composer and the status bar are the two
    /// rows that must survive any height — "it should fit no matter what".
    fn render_chrome(f: &mut ratatui::Frame<'_>, area: Rect, bands: usize) {
        if area.height == 0 || area.width == 0 {
            return;
        }
        let w = area.width as usize;
        // Rows in priority order, most important LAST so truncation from the
        // front sheds the cheapest rows first.
        let mut rows: Vec<String> = Vec::new();
        for b in BANDS.iter().take(bands) {
            rows.push((*b).to_string());
        }
        rows.push("\u{2500}".repeat(w));
        rows.push(format!("\u{276f} {COMPOSER}"));
        rows.push(HINT.to_string());
        rows.push(STATUS.to_string());
        let keep = (area.height as usize).min(rows.len());
        let rows = rows.split_off(rows.len() - keep);
        f.render_widget(
            ratatui::widgets::Paragraph::new(rows.join("\n")),
            Rect::new(area.x, area.y, area.width, keep as u16),
        );
        // The composer's caret, exactly as the real composer sets it — it is
        // what the cursor query in a viewport rebuild reads back.
        let caret_row = area.y + keep.saturating_sub(3) as u16;
        f.set_cursor_position((2, caret_row.min(area.y + area.height - 1)));
    }

    /// `App::run`'s per-iteration terminal reconciliation, headless.
    ///
    /// The real loop needs an `App` (a backend connection, a tokio runtime, a
    /// live provider), so this is a MODEL — but it is faithful in the four
    /// respects that decide what the screen looks like across a resize, and it
    /// is those four that this bug lives in:
    ///
    ///   1. **Where the size comes from.** The loop reads the ROW count live
    ///      from the terminal every iteration, but the COLUMN count from
    ///      `App::width`, which is written only when the crossterm `Resize`
    ///      EVENT is dispatched. The kernel changes the size at SIGWINCH; the
    ///      event arrives later, over the reader task. [`sigwinch`] and
    ///      [`deliver_resize_event`] are those two moments, separately.
    ///   2. **When it erases and rebuilds** — `resize_dirty`, or a wanted
    ///      height that no longer matches the built one.
    ///   3. **That it commits finalized output with `insert_before` BEFORE it
    ///      draws.** This is the step that stranded renders: `insert_before`
    ///      does not autoresize (ratatui-0.29 `terminal.rs:579`); it scrolls by
    ///      `last_known_area.height` and paints rows at `last_known_area.width`
    ///      (`terminal.rs:617`, `:772`) — the geometry the viewport was last
    ///      BUILT at. Run it while the terminal has already reflowed and the
    ///      scroll amount is wrong, so the outgoing viewport is never scrolled
    ///      away and the new one is set below it.
    ///   4. **That the draw is a real ratatui draw**, so `autoresize` gets its
    ///      chance to re-anchor the viewport behind the app's back.
    ///
    /// [`iterate`](Self::iterate) is therefore a mirror of `App::run`'s loop
    /// body, and is meant to be kept one. As written it mirrors the behaviour
    /// that ships the bug: the loop learns a terminal's new width only when the
    /// crossterm `Resize` event is dispatched, so the frame drawn in between is
    /// laid out at a width the terminal no longer has. The three assertions
    /// below fail against that shape, on purpose. When the loop adopts the
    /// ioctl size at the top of every iteration (and erases and rebuilds before
    /// committing or drawing at it), mirror that here — move the
    /// `deliver_resize_event` effect into the top of `iterate` — and they pass.
    /// A change that makes them pass any other way has not fixed anything.
    struct LoopModel {
        term: Option<Terminal<VT100Backend>>,
        /// `App::width` / `App::height`. Written by whichever observer sees a
        /// resize FIRST — the top-of-loop ioctl sample (`App::sample_frame_size`)
        /// or the crossterm Resize event — both funnelling through
        /// `App::adopt_frame_size`.
        app_size: (u16, u16),
        resize_dirty: bool,
        /// Size the resize-settle window is currently timing. `Some` means a
        /// burst is still moving and this iteration must produce nothing
        /// observable. Models `RESIZE_SETTLE` deterministically: one iteration
        /// of quiet at an unchanged size counts as settled.
        resize_settle: Option<(u16, u16)>,
        cur_inline_h: u16,
        last_inline_top: Option<u16>,
        bands: usize,
        /// Output waiting to go into native scrollback (a live turn always has
        /// some: tool results, settled paragraphs).
        pending: Vec<Message>,
        /// One entry per frame actually drawn: (width it was laid out at, width
        /// the terminal really had).
        drawn_at: Vec<(u16, u16)>,
        /// Erase-and-rebuild count.
        rebuilds: usize,
    }

    impl LoopModel {
        fn new(w: u16, h: u16, bands: usize) -> Self {
            let inline_h = chrome_height(bands).min(h.saturating_sub(1)).max(1);
            let term = Terminal::with_options(
                VT100Backend::with_scrollback(w, h, 8000),
                TerminalOptions { viewport: Viewport::Inline(inline_h) },
            )
            .unwrap();
            Self {
                term: Some(term),
                app_size: (w, h),
                resize_dirty: false,
                resize_settle: None,
                cur_inline_h: inline_h,
                last_inline_top: None,
                bands,
                pending: Vec::new(),
                drawn_at: Vec::new(),
                rebuilds: 0,
            }
        }

        fn term(&mut self) -> &mut Terminal<VT100Backend> {
            self.term.as_mut().unwrap()
        }

        fn backend(&self) -> &VT100Backend {
            self.term.as_ref().unwrap().backend()
        }

        fn real_size(&self) -> (u16, u16) {
            let s = ratatui::backend::Backend::size(self.backend()).unwrap();
            (s.width, s.height)
        }

        /// The window changed. The emulator reflows NOW; the app is not told.
        fn sigwinch(&mut self, w: u16, h: u16) {
            self.term.as_mut().unwrap().backend_mut().resize(w, h);
        }

        /// The crossterm `Resize` event finally reaches `App::update`.
        fn deliver_resize_event(&mut self) {
            // Idempotent: the top-of-loop ioctl sample has usually adopted this
            // already, exactly as `App::adopt_frame_size` no-ops on a second
            // observation of the same size.
            let now = self.real_size();
            if now != self.app_size {
                self.app_size = now;
                self.resize_dirty = true;
            }
        }

        /// Queue a finalized block for native scrollback, as a live turn does.
        fn queue_output(&mut self, text: &str) {
            self.pending
                .push(Message::new(MessageType::Agent, text.to_string(), None));
        }

        /// One pass of the run loop.
        fn iterate(&mut self) {
            // ── ONE SIZE PER FRAME, READ FIRST ────────────────────────────
            // The ioctl reflects the kernel's view as of SIGWINCH, strictly
            // earlier than the crossterm Resize event (which has to travel
            // through the reader task). Adopting it here is what stops ratatui's
            // `autoresize` from noticing the change first and re-anchoring the
            // inline viewport behind the app — which clears only the NEW rect
            // and strands the old one on screen, once per intermediate width.
            let sampled = self.real_size();
            if sampled != self.app_size {
                self.app_size = sampled;
                self.resize_dirty = true;
            }

            // ── RESIZE-BURST SETTLE WINDOW ────────────────────────────────
            // While the size is still moving, produce NOTHING observable: no
            // rebuild, no `insert_before`, no draw. Reaching `Terminal::draw` is
            // what hands control to `autoresize`, so skipping the draw is not an
            // optimisation — it is what keeps an intermediate width from ever
            // being rendered at all.
            if self.resize_dirty {
                match self.resize_settle {
                    Some(last) if last == sampled => self.resize_settle = None,
                    _ => {
                        self.resize_settle = Some(sampled);
                        return;
                    }
                }
            }

            let (real_w, real_h) = sampled;
            let term_rows = real_h;
            // Laid out at the size this frame sampled — by construction the size
            // the terminal really has.
            let laid_out_w = self.app_size.0;
            let desired = chrome_height(self.bands)
                .min(term_rows.saturating_sub(1))
                .max(1);

            let resized = std::mem::take(&mut self.resize_dirty);
            if resized || desired != self.cur_inline_h {
                let mut out = self.backend().fork();
                if resized {
                    clear_screen_for_resize(&mut out).unwrap();
                } else if let Some(top) = self.last_inline_top {
                    let max_row = term_rows.saturating_sub(1);
                    crossterm::execute!(
                        out,
                        crossterm::cursor::MoveTo(0, top.min(max_row)),
                        crossterm::terminal::Clear(
                            crossterm::terminal::ClearType::FromCursorDown
                        ),
                    )
                    .unwrap();
                }
                let backend = self.backend().fork();
                self.term = None; // drop the old Terminal, exactly as `rebuild_inline` does
                self.term = Some(
                    Terminal::with_options(
                        backend,
                        TerminalOptions { viewport: Viewport::Inline(desired) },
                    )
                    .unwrap(),
                );
                self.cur_inline_h = desired;
                self.rebuilds += 1;
            }

            // Step 2 — commit finalized output into native scrollback.
            if !self.pending.is_empty() {
                // This frame's sampled width. `get_frame().area().width` is a
                // THIRD size source — the width the viewport was last BUILT at —
                // so mid-drag it lags and commits finalized messages into native
                // scrollback, permanently, at a width the terminal no longer has.
                let w = laid_out_w;
                let msgs = std::mem::take(&mut self.pending);
                let sized: Vec<(Message, u16)> = msgs
                    .into_iter()
                    .map(|m| {
                        let h = m.height(w);
                        (m, h)
                    })
                    .filter(|(_, h)| *h > 0)
                    .collect();
                let total: u16 = sized.iter().map(|(_, h)| *h).sum();
                if total > 0 {
                    self.term()
                        .insert_before(total, |buf| {
                            let mut y = 0u16;
                            for (m, h) in sized.iter() {
                                m.render_to_buffer(Rect::new(0, y, w, *h), buf, 0);
                                y = y.saturating_add(*h);
                            }
                        })
                        .unwrap();
                }
            }
            self.last_inline_top = Some(self.term().get_frame().area().top());

            // Step 3 — draw.
            self.drawn_at.push((laid_out_w, real_w));
            let bands = self.bands;
            self.term()
                .draw(|f| {
                    let a = f.area();
                    render_chrome(f, a, bands);
                })
                .unwrap();
        }

        /// Every live-region row, counted across screen AND scroll history.
        fn copies(&self) -> (usize, usize, usize) {
            // ONE walk of the history: `scrollback_lines` re-pages the emulator,
            // and this runs on every step of a 178-column sweep.
            let mut all = self.backend().scrollback_lines();
            let screen = self.backend().contents();
            all.extend(screen.lines().map(str::to_string));
            let count = |needle: &str| all.iter().filter(|l| l.contains(needle)).count();
            (count(COMPOSER), count(HINT), count(STATUS))
        }

        /// **No frame may be laid out at a width the terminal no longer has.**
        ///
        /// This is the precondition every stranded render is downstream of. A
        /// frame drawn or committed while `App::width` disagrees with the real
        /// terminal is a frame ratatui reconciles by itself — `Terminal::draw`
        /// re-anchors the inline viewport through `autoresize`, and
        /// `insert_before` scrolls by a `last_known_area` that describes a
        /// terminal that no longer exists — and finalized messages committed in
        /// that state are written into native scrollback, permanently, at the
        /// wrong width.
        ///
        /// The loop must adopt the size the moment the ioctl reports it, not
        /// when the crossterm event eventually arrives.
        fn assert_no_frame_used_a_stale_width(&self, ctx: &str) {
            if let Some((laid_out, real)) =
                self.drawn_at.iter().copied().find(|(a, b)| a != b)
            {
                panic!(
                    "{ctx}: a frame was laid out at {laid_out} columns while the \
                     terminal was {real} columns wide. The kernel changed the size \
                     at SIGWINCH; the crossterm Resize event had not arrived yet, \
                     and the loop drew (and committed to scrollback) anyway."
                );
            }
        }

        fn assert_single_live_region(&self, ctx: &str) {
            let (c, h, s) = self.copies();
            assert_eq!(
                (c, h, s),
                (1, 1, 1),
                "{ctx}: the user can reach {c} composers, {h} hint rows and {s} \
                 status bars. There is exactly ONE live region; every extra copy \
                 is a render a resize left behind instead of replacing.\n\
                 --- screen ---\n{}\n--- history ---\n{}",
                self.backend().contents(),
                self.backend().scrollback_lines().join("\n"),
            );
        }
    }

    /// The widths a drag crosses: every single column from 40 to 120 and back,
    /// plus the rapid one-column alternation a pointer produces when it jitters
    /// on the edge.
    fn drag_widths() -> Vec<u16> {
        let mut v: Vec<u16> = (40u16..=120).collect();
        v.extend((40u16..=120).rev());
        for _ in 0..8 {
            v.push(79);
            v.push(80);
        }
        v
    }

    /// **The regression, stated as the user states it.** A drag crosses 160+
    /// columns; afterwards there must be ONE composer, ONE hint row and ONE
    /// status bar reachable — not one per column crossed.
    #[test]
    fn a_resize_sweep_leaves_exactly_one_composer_hint_and_status() {
        let mut m = LoopModel::new(40, 24, 0);
        m.queue_output("A first answer, so the live region is bottom-anchored\n");
        m.iterate();
        m.assert_single_live_region("before the drag");

        for w in drag_widths() {
            // The window moves: the emulator reflows now, the app is not told.
            m.sigwinch(w, 24);
            // The loop wakes on the 200ms tick and runs a full iteration —
            // commit + draw — against a terminal it still thinks is the old
            // size. THIS is the frame that strands a render.
            m.iterate();
            // The crossterm Resize event finally lands; the loop rebuilds.
            m.deliver_resize_event();
            m.iterate();
            m.assert_single_live_region(&format!("after dragging to {w} columns"));
        }
        m.assert_no_frame_used_a_stale_width("during the drag");
    }

    /// The same drag during a LIVE TURN: bands up (toast, checklist, survey)
    /// and finalized output flowing into scrollback on nearly every iteration,
    /// which is the state the nine stacked renders were captured in.
    #[test]
    fn a_resize_sweep_during_a_live_turn_leaves_exactly_one_live_region() {
        let mut m = LoopModel::new(40, 24, BANDS.len());
        m.queue_output("The turn opens with a paragraph of prose.\n");
        m.iterate();
        m.assert_single_live_region("before the drag");

        for (i, w) in drag_widths().into_iter().enumerate() {
            // A live turn is settling blocks into scrollback continuously.
            m.queue_output(&format!("tool result {i}: ran a command and got output\n"));
            m.sigwinch(w, 24);
            m.iterate();
            m.deliver_resize_event();
            m.iterate();
            m.assert_single_live_region(&format!("mid-turn, after dragging to {w} columns"));
        }
        m.assert_no_frame_used_a_stale_width("during the mid-turn drag");
    }

    /// **"It should fit no matter what."** At heights a live region cannot
    /// fully fit in, it sheds bands from the lowest priority up — it never
    /// overflows, and it never pushes the composer or the status bar off the
    /// screen into scroll history, where the user cannot type into them.
    #[test]
    fn a_short_terminal_sheds_bands_and_never_loses_the_composer_or_status_bar() {
        for rows in [6u16, 8, 10] {
            // The product's own sizing rule, asserted directly: however much
            // the composer wants, the live region is clamped so at least one
            // row of transcript survives above it, and never below the height
            // that fits the composer and the status bar.
            for input_needed in 1u16..=12 {
                let h = crate::app::event_loop::live_region_height(input_needed, rows);
                assert!(
                    h <= rows.saturating_sub(1).max(1),
                    "{rows} rows / composer wants {input_needed}: live region \
                     reserved {h} rows and would overflow the terminal"
                );
                assert!(h >= 3, "{rows} rows: reserved {h} rows, too few for composer + status");
            }
            let mut m = LoopModel::new(80, rows, BANDS.len());
            m.queue_output("An answer that was already on screen.\n");
            m.iterate();
            m.assert_single_live_region(&format!("{rows} rows, before the drag"));

            for w in [79u16, 60, 100, 41, 120, 80] {
                m.sigwinch(w, rows);
                m.iterate();
                m.deliver_resize_event();
                m.iterate();
                m.assert_single_live_region(&format!("{rows} rows, after dragging to {w}"));
                // The two rows the user interacts with must be on the LIVE
                // screen, not banished into history.
                let screen = m.backend().contents();
                assert!(
                    screen.contains(COMPOSER),
                    "{rows}x{w}: the composer left the screen; a live region that \
                     cannot fit must shed bands, never the composer.\n{screen}"
                );
                assert!(
                    screen.contains(STATUS),
                    "{rows}x{w}: the status bar left the screen.\n{screen}"
                );
            }
        }
    }

    /// **The size-source pin** (Codex's
    /// `resize_draw_applies_event_dimensions_without_querying_backend_size`).
    ///
    /// A frame is laid out against ONE size. `Terminal::draw` is allowed to read
    /// the backend's size once — that is `autoresize` checking — but it must
    /// never go on to query the CURSOR, because a cursor query during a draw
    /// means `autoresize` decided the size had changed and re-anchored the
    /// inline viewport itself, clearing only the new rect and leaving the
    /// previous render on screen. The app must always have learned about the
    /// resize first.
    #[test]
    fn a_frame_never_lets_ratatui_reanchor_the_viewport_behind_the_app() {
        let mut m = LoopModel::new(60, 20, 1);
        m.queue_output("Something already committed.\n");
        m.iterate();
        // Constructing an Inline viewport legitimately queries the cursor once
        // (`compute_inline_size` at `Terminal::with_options`), and so does the
        // first commit + draw. The invariant under test is about the frames
        // drawn AFTER the terminal changes size, so start the count there.
        m.backend().reset_probes();

        for w in [61u16, 62, 63, 70, 55, 54, 100] {
            m.sigwinch(w, 20);
            m.iterate();
            let probes = (m.backend().size_probes(), m.backend().cursor_probes());
            m.backend().reset_probes();
            assert_eq!(
                probes.1, 0,
                "drawing at {w} columns made ratatui query the cursor \
                 ({} size reads, {} cursor reads). That only happens inside \
                 `autoresize` → `Terminal::resize` → `compute_inline_size`, i.e. \
                 ratatui re-anchored the live region because the app had not \
                 noticed the resize yet. The app must adopt the new size — and \
                 erase — before any frame is drawn at it.",
                probes.0, probes.1
            );
            m.deliver_resize_event();
            m.iterate();
            m.backend().reset_probes();
        }
    }
}
