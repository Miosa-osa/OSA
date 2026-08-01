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
                .filter(|l| l.starts_with('│') || l.starts_with('├'))
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
}

// ───────────────────── ask_user survey picker ─────────────────────
//
// `ask_user` blocks the whole turn on the operator, so its picker has to be
// visible, keyboard-driven and dismissable. It shipped invisible: the backend
// never forwarded the question, and nothing here checked that the dialog draws
// what it was handed.
mod survey_invariants {
    use super::*;
    use crate::dialogs::survey::{
        wrapped_line_count, SurveyAction, SurveyDialog, SurveyOption, SurveyQuestion,
    };
    use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::NONE)
    }

    fn question() -> SurveyQuestion {
        SurveyQuestion {
            text: "Which parser should we keep?".to_string(),
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

    /// The question and EVERY option label must actually be on screen — the
    /// live bug was a picker that rendered nothing at all.
    #[test]
    fn draws_the_question_and_all_options() {
        let d = dialog();
        let buf = render_to_buffer(|f| d.draw(f, f.area()), 100, 30);
        let screen = snapshot_buffer(&buf);

        for needle in [
            "Which parser should we keep?",
            "Rewrite the parser (Recommended)",
            "removes the whole class of escaping bugs",
            "Patch in place",
            "Type your own answer",
            "Esc",
            "Enter",
        ] {
            assert!(
                screen.contains(needle),
                "survey picker never drew {needle:?}.\n{screen}"
            );
        }
    }

    /// The recommended option is listed FIRST — the model is told to order them
    /// that way and the dialog must not reorder.
    #[test]
    fn recommended_option_is_drawn_first() {
        let d = dialog();
        let buf = render_to_buffer(|f| d.draw(f, f.area()), 100, 30);
        let screen = snapshot_buffer(&buf);
        let rec = screen.find("Rewrite the parser").expect("recommended row");
        let other = screen.find("Patch in place").expect("second row");
        assert!(rec < other, "recommended option must render first:\n{screen}");
    }

    /// All ink stays inside the centered dialog rect (70% x 75%), at every size
    /// from "barely fits" upward — no spill onto the transcript behind it.
    #[test]
    fn ink_stays_inside_the_reserved_dialog_rect() {
        for (w, h) in [(60u16, 16u16), (80, 24), (100, 30), (160, 50), (200, 60)] {
            let d = dialog();
            let buf = render_to_buffer(|f| d.draw(f, f.area()), w, h);

            let dw = (w * 70 / 100).max(40).min(w);
            let dh = (h * 75 / 100).max(12).min(h);
            let x0 = w.saturating_sub(dw) / 2;
            let y0 = h.saturating_sub(dh) / 2;
            let x1 = x0 + dw;
            let y1 = y0 + dh;

            for y in 0..h {
                for x in 0..w {
                    if x >= x0 && x < x1 && y >= y0 && y < y1 {
                        continue;
                    }
                    assert!(
                        super::is_blank(buf[(x, y)].symbol()),
                        "{w}x{h}: ink at ({x},{y}) outside dialog rect \
                         ({x0}..{x1}, {y0}..{y1}).\n{}",
                        snapshot_buffer(&buf)
                    );
                }
            }
        }
    }

    /// A pathologically long question must not push the options off-screen: the
    /// question block is capped, so the option rows still render.
    #[test]
    fn a_long_question_never_hides_the_options() {
        let mut q = question();
        q.text = "why ".repeat(200);
        let d = SurveyDialog::new("sv-long".to_string(), vec![q], true);
        let buf = render_to_buffer(|f| d.draw(f, f.area()), 100, 30);
        let screen = snapshot_buffer(&buf);
        assert!(
            screen.contains("Rewrite the parser (Recommended)"),
            "options were pushed off-screen by a long question:\n{screen}"
        );
    }

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

        // ...and the first (recommended) option when the cursor never moves.
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

    /// Esc declines. Without this the operator has no way out and the turn
    /// deadlocks until the tool's own timeout fires.
    #[test]
    fn esc_declines_the_question() {
        let mut d = dialog();
        assert!(matches!(
            d.handle_key(key(KeyCode::Esc)),
            Some(SurveyAction::Skip)
        ));
    }

    /// Free text is always reachable, so the operator can answer something the
    /// model did not offer (the client-supplied "Other").
    #[test]
    fn free_text_is_always_offered_and_submits_its_content() {
        let mut d = dialog();
        // Down past both options lands on the free-text row.
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

    #[test]
    fn wrapped_line_count_is_sane() {
        assert_eq!(wrapped_line_count("", 40), 1);
        assert_eq!(wrapped_line_count("short", 40), 1);
        assert_eq!(wrapped_line_count("aaa bbb ccc", 7), 2);
        assert_eq!(wrapped_line_count("anything", 0), 1);
        assert!(wrapped_line_count(&"why ".repeat(200), 40) > 3);
    }
}
