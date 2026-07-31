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
