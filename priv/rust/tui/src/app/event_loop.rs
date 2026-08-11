use anyhow::Result;
use crossterm::{
    event::{
        DisableMouseCapture, EnableMouseCapture, Event as CrosstermEvent, KeyEvent, KeyEventKind,
    },
    execute,
    terminal::{EnterAlternateScreen, LeaveAlternateScreen},
};
use ratatui::layout::{Constraint, Direction, Layout as RLayout};
use ratatui::prelude::*;
use ratatui::{TerminalOptions, Viewport};
use std::time::Duration;
use tokio::time;
use tracing::info;

use super::App;
use crate::app::frame_size::FrameSize;
use crate::app::state::AppState;
use crate::components::measure::Measured;
use crate::components::Component;
use crate::event::{terminal, Event};

type Term = Terminal<CrosstermBackend<std::io::Stdout>>;

/// Intersect `rect` with the frame's drawable area, returning a rect guaranteed
/// to lie within `frame.area()` (possibly zero-sized). Pass the result as the
/// `area` to any component's `draw`: because every downstream `render_widget`
/// stays inside this rect, an oversized or misplaced area degrades gracefully
/// instead of panicking with "index outside of buffer".
pub fn clamp_to_frame(frame: &Frame, rect: Rect) -> Rect {
    rect.intersection(frame.area())
}

/// Compute the inline-viewport height the live region wants, given the
/// composer's current needed height. The chrome overhead (context hint +
/// 2-row status) is a fixed 3 rows — the streaming preview and activity rows are
/// added on demand (they are 0 when idle), so an idle live region reserves NO dead
/// rows and the composer sits tight against the last message. An empty
/// composer (needed height 3) yields exactly [`crate::LIVE_H_BASE`]. Only the
/// composer's own height drives growth, so the viewport doesn't churn as
/// transient activity rows come and go mid-turn. The result is clamped to
/// `[LIVE_H_BASE, term_rows - 1]` (with the floor lowered on tiny terminals so
/// the clamp bounds never invert).
/// Max rows the inline agents panel may occupy so multi-agent activity is
/// visible without swallowing the compact live region. `Agents::height()`
/// returns 0 when there's nothing to show, so the row collapses when idle.
pub(crate) const AGENTS_INLINE_CAP: u16 = 8;

/// Rows the live task checklist may occupy inside the inline region.
///
/// The checklist used to be drawn as an OVERLAY into the streaming band's own
/// rect (`draw_inline` passed `a_stream` to both `Chat::draw_live` and
/// `TaskChecklist::draw`). Nothing reserved space for it, so it painted straight
/// over whatever the reply had already drawn there — the interleaved
/// "Plan 3/3" on top of a markdown table row. It now gets its OWN band; this cap
/// only bounds how much of the stream band it may take.
pub(crate) const CHECKLIST_INLINE_CAP: u16 = 12;

/// Rows the ephemeral toast band may occupy — one row per live toast, bounded by
/// [`crate::components::toast::MAX_VISIBLE`].
///
/// Toasts USED to be a bare overlay: `draw_inline` finished laying out every
/// band and then painted `toast_rect(area)` — the top 3 rows of the live region,
/// which belong to the STREAMING band — straight over whatever the reply had
/// already drawn there. Nothing reserved those rows, so a toast firing mid-reply
/// ate the top of the answer. The toast now owns a real band above the stream.
pub(crate) const TOAST_INLINE_CAP: u16 = crate::components::toast::MAX_VISIBLE as u16;

/// Rows the composer-anchored completion band may occupy: the `/`-command
/// popup (≤ `max_visible` 8 + 2 border rows) or the `@`-mention dropdown
/// ([`crate::components::input::MENTION_POPUP_ROWS`]).
pub(crate) const POPUP_INLINE_CAP: u16 = 12;

/// Row indices into [`inline_split`]'s result.
pub(crate) const ROW_TOAST: usize = 0;
pub(crate) const ROW_STREAM: usize = 1;
pub(crate) const ROW_CHECKLIST: usize = 2;
pub(crate) const ROW_THINK: usize = 3;
pub(crate) const ROW_AGENTS: usize = 4;
pub(crate) const ROW_SURVEY: usize = 5;
pub(crate) const ROW_HINT: usize = 6;
pub(crate) const ROW_POPUP: usize = 7;
pub(crate) const ROW_INPUT: usize = 8;
pub(crate) const ROW_STATUS: usize = 9;

/// Every reserved band height the inline live region is laid out from.
///
/// A struct rather than a positional argument list because the band count keeps
/// growing (checklist → survey → toast + completion popup) and a mis-ordered
/// `u16` argument is exactly the silent, invisible defect this layout keeps
/// producing. `..Default::default()` means a caller that does not care about a
/// band collapses it to 0 explicitly.
/// Every band is listed here — including the two that used to be hard-coded
/// `Constraint::Length` literals inside [`inline_split`] (the context-hint row
/// and the status bar). A band the arbiter cannot see is a band it cannot shed,
/// and an unsheddable band on a 6-row terminal is an overflow.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Bands {
    /// Ephemeral notifications (top of the region).
    pub toast: u16,
    /// Live task checklist.
    pub checklist: u16,
    /// Thinking box / tool-use activity feed.
    pub think: u16,
    /// Multi-agent roster + background-terminals summary.
    pub agents: u16,
    /// Inline `ask_user` question band.
    pub survey: u16,
    /// `/`-command popup or `@`-mention dropdown, anchored to the composer.
    pub popup: u16,
    /// Composer (top + bottom dividers included).
    pub input: u16,
    /// Right-aligned notice row above the composer.
    pub hint: u16,
    /// Status line + permission/shell line.
    pub status: u16,
}

/// `hint` and `status` default to the rows they have always occupied (1 and 2),
/// NOT to zero: `..Default::default()` in a caller means "I do not care about
/// the optional bands", and silently collapsing the chrome would be a different
/// layout, not an unspecified one.
impl Default for Bands {
    fn default() -> Self {
        Self {
            toast: 0,
            checklist: 0,
            think: 0,
            agents: 0,
            survey: 0,
            popup: 0,
            input: 0,
            hint: HINT_ROWS,
            status: STATUS_ROWS,
        }
    }
}

/// The right-aligned notice row above the composer.
pub(crate) const HINT_ROWS: u16 = 1;
/// Status line + permission/shell line.
pub(crate) const STATUS_ROWS: u16 = 2;
/// Rows the streaming band keeps even when every sheddable band has been shed.
/// The reply, the inline permission prompt and the plan-review panel all live
/// here, so a region with zero stream rows has nothing to say.
pub(crate) const STREAM_FLOOR: u16 = 1;
/// Rows the composer keeps no matter what. Below this there is no interactive
/// surface left and OSA is a picture of a terminal.
pub(crate) const INPUT_FLOOR: u16 = 1;

/// A band, for the arbiter to name when it sheds one.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Band {
    Toast,
    Agents,
    Checklist,
    Think,
    Hint,
    Survey,
    Popup,
    Status,
    Input,
}

/// **The shed ladder — lowest priority first.**
///
/// The live region must FIT any viewport, degrading rather than overflowing. On
/// a terminal too short for every band, something has to go; the failure mode
/// that shipped was that nothing did, because ten bands each independently
/// claimed rows and no single thing decided what fitted.
///
/// The order, and why:
///
/// | shed | band | reasoning |
/// |------|------|-----------|
/// | 1st | toast | ephemeral by definition; it re-fires, and it is the only band whose whole purpose is to be transient |
/// | 2nd | agents | a roster of who is working — informative, never load-bearing |
/// | 3rd | checklist | the plan is also committed to scrollback, so losing the live copy loses nothing permanently |
/// | 4th | think | the tool feed is progress, not content |
/// | 5th | hint | passive chrome; the status bar already states the context number |
/// | 6th | survey | the user is being ASKED something — shed only under real pressure |
/// | 7th | popup | a completion menu the user opened deliberately, one keystroke ago |
/// | 8th | status | the last chrome to go, and only when the alternative is losing the composer |
/// | 9th | input | never shed below [`INPUT_FLOOR`]; it is the only interactive surface |
///
/// `survey` and `popup` outrank the informational bands because both are live
/// asks: something is waiting on the operator, and hiding it strands the turn.
/// They still sit below `status`/`input` because a question you cannot answer is
/// worse than a question you cannot see.
pub(crate) const SHED_ORDER: [Band; 9] = [
    Band::Toast,
    Band::Agents,
    Band::Checklist,
    Band::Think,
    Band::Hint,
    Band::Survey,
    Band::Popup,
    Band::Status,
    Band::Input,
];

impl Bands {
    fn get(&self, band: Band) -> u16 {
        match band {
            Band::Toast => self.toast,
            Band::Agents => self.agents,
            Band::Checklist => self.checklist,
            Band::Think => self.think,
            Band::Hint => self.hint,
            Band::Survey => self.survey,
            Band::Popup => self.popup,
            Band::Status => self.status,
            Band::Input => self.input,
        }
    }

    fn set(&mut self, band: Band, rows: u16) {
        match band {
            Band::Toast => self.toast = rows,
            Band::Agents => self.agents = rows,
            Band::Checklist => self.checklist = rows,
            Band::Think => self.think = rows,
            Band::Hint => self.hint = rows,
            Band::Survey => self.survey = rows,
            Band::Popup => self.popup = rows,
            Band::Status => self.status = rows,
            Band::Input => self.input = rows,
        }
    }

    /// Rows every fixed band reserves. The streaming preview is the `Min(0)`
    /// remainder, so it is deliberately NOT counted here — `area_h - reserved()`
    /// is exactly what is left for the reply.
    pub(crate) fn reserved(&self) -> u16 {
        [
            self.toast,
            self.checklist,
            self.think,
            self.agents,
            self.survey,
            self.popup,
            self.input,
            self.hint,
            self.status,
        ]
        .into_iter()
        .fold(0u16, |acc, h| acc.saturating_add(h))
    }

    /// Clamp each band to its own ceiling. Independent of the viewport: a band
    /// may not claim more than its cap even on a very tall terminal, because
    /// these caps are what keep the live region from swallowing the scrollback
    /// the user is reading.
    pub(crate) fn capped(mut self) -> Self {
        self.toast = self.toast.min(TOAST_INLINE_CAP);
        self.checklist = self.checklist.min(CHECKLIST_INLINE_CAP);
        self.agents = self.agents.min(AGENTS_INLINE_CAP);
        self.survey = self.survey.min(crate::dialogs::survey::SURVEY_INLINE_CAP);
        self.popup = self.popup.min(POPUP_INLINE_CAP);
        self.input = self.input.max(INPUT_FLOOR);
        self
    }
}

/// **The arbiter.** Turn the bands the components *asked* for into the bands
/// that actually fit in `area_h` rows.
///
/// This is the single place that decides what fits, and it is the answer to
/// "it should be able to fit no matter what". Before it existed, each band
/// clamped itself against an independently hand-written floor expression
/// (`think + agents + checklist + survey + popup + 1 + 2 + 2`, repeated five
/// times with a different prefix each time, and separately re-summed in
/// `desired_inline_height`) — five chances to write the wrong prefix, and no
/// global guarantee that the total fitted at all.
///
/// Guarantees, all pinned by tests:
/// * the result never claims more than `area_h` rows, so `inline_split`'s
///   `Min(0)` stream band is never negative and no band overflows into its
///   neighbour;
/// * bands are shed in [`SHED_ORDER`], partially (a band shrinks before it
///   disappears) so a 1-row squeeze costs one row and not a whole feature;
/// * the composer survives to [`INPUT_FLOOR`] on any viewport;
/// * at any size where everything fits, the result is the input unchanged — so
///   normal terminals see byte-identical layout to before the arbiter existed.
pub(crate) fn fit_bands(want: Bands, area_h: u16) -> Bands {
    let mut b = want.capped();
    for band in SHED_ORDER {
        let claimed = b.reserved().saturating_add(STREAM_FLOOR);
        if claimed <= area_h {
            break;
        }
        let excess = claimed - area_h;
        let floor = match band {
            Band::Input => INPUT_FLOOR,
            _ => 0,
        };
        let cur = b.get(band);
        let take = excess.min(cur.saturating_sub(floor));
        b.set(band, cur - take);
    }
    b
}

/// The inline live region's vertical split. Kept as a free function so the
/// "no two components share a row" invariant is testable against the REAL
/// layout instead of a hand-copied mirror of it — the checklist overdraw bug
/// was invisible precisely because nothing exercised this split.
pub(crate) fn inline_split(area: Rect, b: Bands) -> std::rc::Rc<[Rect]> {
    RLayout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(b.toast), // toasts (own band, never over the reply)
            Constraint::Min(0),          // streaming preview (collapses to 0 when idle)
            Constraint::Length(b.checklist), // live task checklist (own band)
            Constraint::Length(b.think), // thinking / activity
            Constraint::Length(b.agents), // agents panel / background summary
            Constraint::Length(b.survey), // inline ask_user question band (own band)
            Constraint::Length(b.hint),  // right-aligned notice row
            Constraint::Length(b.popup), // `/` popup / `@` dropdown (own band, never over the hint)
            Constraint::Length(b.input), // input box (top + bottom dividers)
            Constraint::Length(b.status), // status line + permission/shell line
        ])
        .split(area)
}

/// Shrink `slot` to its bottom `content` rows.
///
/// The live region reserves STABLE per-turn slots (so the inline viewport never
/// rebuilds mid-turn — a rebuild re-anchors via a DSR cursor query and stacks
/// chrome). A component whose content is shorter than its slot must therefore be
/// handed only the rows it actually fills: components paint decoration (accent
/// rails, backgrounds) across the whole rect they are given, so passing the full
/// slot trails bare decoration down the empty rows. Anchoring to the BOTTOM keeps
/// the live content tight against the composer and leaves the slack above it,
/// where it reads as padding rather than a gap.
///
/// `content` is clamped to the slot; a zero result is safe (components early-out
/// on `area.height == 0`).
pub(crate) fn bottom_anchored(slot: Rect, content: u16) -> Rect {
    let h = content.min(slot.height);
    Rect {
        y: slot.y + slot.height.saturating_sub(h),
        height: h,
        ..slot
    }
}


pub(crate) fn live_region_height(input_needed: u16, term_rows: u16) -> u16 {
    const OVERHEAD: u16 = 3;
    let want = OVERHEAD.saturating_add(input_needed);
    let hi = term_rows.saturating_sub(1).max(1);
    let lo = crate::LIVE_H_BASE.min(hi);
    want.clamp(lo, hi)
}

/// Fixed row count of the inline streaming-preview slot (the "real cure").
///
/// While a reply streams, the newest lines scroll INTERNALLY within this
/// constant slot — `Chat::draw_live` bottom-anchors the tail — rather than the
/// inline viewport growing per token. Keeping the reserved height constant for
/// the whole turn is what eliminates the mid-turn viewport rebuild (and its DSR
/// cursor re-anchor under tmux/SSH) that produced the stacking / whitespace
/// artifacts. Mirrors Claude Code's Ink `<Static>` + transient split and grok's
/// fixed `xai-grok-pager` preview window: a bounded window over a growing body.
pub(crate) const STREAM_PREVIEW_ROWS: u16 = 10;

/// Hard ceiling on the streaming preview slot, and the granularity it grows in.
///
/// A permanently 10-row window is what made a long reply feel like it was being
/// read through a letterbox: the answer scrolled past inside a small box and only
/// became legible once it landed in scrollback. The preview may therefore GROW
/// with the reply — but growth is the dangerous direction. Every height change
/// rebuilds the inline viewport, and every rebuild issues a DSR cursor query that
/// tmux/SSH can drop (the stacked-composer / duplicated-chrome class of bug).
///
/// So growth is **quantized and bounded**, never per-delta:
/// * it moves in whole [`STREAM_PREVIEW_STEP`] jumps, so a 40-row reply costs at
///   most `(MAX - ROWS) / STEP` rebuilds for the entire turn (two, today) rather
///   than one per token;
/// * it is monotonic within a turn (see `App::stream_preview_hw`), so a reply
///   whose rendered height dips — a fenced block closing, a table collapsing —
///   cannot oscillate the viewport;
/// * it never exceeds [`stream_preview_ceiling`], which also refuses to let the
///   live region eat more than half the terminal, because the rows above it are
///   the scrollback the user is reading.
pub(crate) const STREAM_PREVIEW_MAX: u16 = 22;
pub(crate) const STREAM_PREVIEW_STEP: u16 = 6;

/// Largest preview slot allowed on a terminal of `term_rows` rows.
///
/// Half the terminal, clamped into `[STREAM_PREVIEW_ROWS, STREAM_PREVIEW_MAX]`.
/// The lower clamp keeps the historical floor on short terminals (where the
/// outer `clamp(base, hi)` in [`streaming_inline_height`] already governs), the
/// upper one keeps a long reply from turning the live region into the whole
/// screen.
pub(crate) fn stream_preview_ceiling(term_rows: u16) -> u16 {
    (term_rows / 2).clamp(STREAM_PREVIEW_ROWS, STREAM_PREVIEW_MAX)
}

/// Rows the streaming preview should reserve for a reply currently rendering to
/// `content_h` rows, given this turn's high-water mark and the ceiling.
///
/// Pure and monotonic: the result is never below `STREAM_PREVIEW_ROWS`, never
/// below `high_water` (clamped to the ceiling), never above `ceiling`, and only
/// ever takes values on the `ROWS + k*STEP` lattice — the three properties that
/// together make mid-turn viewport churn impossible.
pub(crate) fn stream_preview_rows(content_h: u16, high_water: u16, ceiling: u16) -> u16 {
    let ceiling = ceiling.max(STREAM_PREVIEW_ROWS);
    let overflow = content_h.saturating_sub(STREAM_PREVIEW_ROWS);
    let steps = overflow.div_ceil(STREAM_PREVIEW_STEP);
    let want = STREAM_PREVIEW_ROWS.saturating_add(steps.saturating_mul(STREAM_PREVIEW_STEP));
    want.min(ceiling).max(high_water.min(ceiling))
}

/// Retire the working chrome at the TURN-end edge.
///
/// "Turn complete" and "message complete" are different events — one turn can
/// contain several assistant generations (the ReAct loop re-enters on the
/// auto-continue nudge, the coding nudge, the verification gate, the goal
/// verifier…), and each generation finalizes its own message. Teardown must hang
/// on the former, so this is driven from the run loop's `Processing → Idle` edge
/// rather than from any single `agent_response`.
///
/// What it retires is only the machinery: the live preview remnant, the spinner
/// / tool-progress feed, the frozen reasoning box, the multi-agent roster. What
/// legitimately persists is untouched — committed tool cells and the frozen plan
/// snapshot are already in `chat`'s scrollback queue on their way to the
/// terminal's native buffer, and the background-terminals summary keeps its own
/// row because those jobs really are still running.
///
/// Kept as a free function over the components (rather than an `App` method) so
/// the "after a turn ends, none of the working chrome reserves a row" invariant
/// is unit-testable without constructing a full `App`. Every call is idempotent.
pub(crate) fn settle_working_chrome(
    activity: &mut crate::components::activity::Activity,
    agents: &mut crate::components::agents::Agents,
    thinking_box: &mut crate::components::chat::thinking_box::ThinkingBox,
) {
    activity.stop();
    agents.task_completed();
    thinking_box.clear();
}

/// Inline-viewport height while a reply is streaming.
///
/// `preview_rows` is the streaming preview's reserved slot — [`STREAM_PREVIEW_ROWS`]
/// for a short reply, a quantized step above it for a long one (see
/// [`stream_preview_rows`]). It is passed in rather than read from the constant
/// so this stays a pure function AND so the caller is forced to use the same
/// number `draw_inline` will lay out against.
///
/// Deliberately takes no *continuous* measure of how much has streamed: within
/// one quantization step the streaming height does not change as the reply grows,
/// so the viewport is not rebuilt per token. Kept as a free pure function so the
/// invariant is unit-testable without constructing a full `App`.
///
/// `bands_h` is EVERY reserved band that `inline_split` carves out of the
/// `Min(0)` stream slot — today the task checklist and the inline `ask_user`
/// survey. **Omitting it is a real bug that shipped:** `want` was built from the
/// chrome + `STREAM_PREVIEW_ROWS` alone and then `clamp(base, hi)`ed. Whenever
/// `want > base` (the normal case) the clamp returns `want`, so the checklist's
/// rows — counted in `base` but not in `want` — silently vanished from the
/// reservation. `draw_inline` still carved the checklist band out of the same
/// area, so the streaming preview collapsed from 10 rows to whatever was left,
/// and the final response came out truncated with the plan block sitting where
/// the rest of it should have been. Every band that consumes stream rows must be
/// counted in BOTH terms.
pub(crate) fn streaming_inline_height(
    base: u16,
    overhead: u16,
    input_needed: u16,
    agents_h: u16,
    bands_h: u16,
    popup_h: u16,
    preview_rows: u16,
    hi: u16,
) -> u16 {
    let want = overhead
        .saturating_add(input_needed)
        .saturating_add(preview_rows)
        .saturating_add(agents_h)
        .saturating_add(bands_h)
        .saturating_add(popup_h);
    want.clamp(base, hi)
}

/// Render `widget` into `rect` after clipping it to the frame's drawable area.
/// Skips the draw entirely when nothing survives the clip. This is the single
/// choke point that guarantees a widget can never index outside the frame
/// buffer, no matter how the target rect was computed.
pub fn safe_render_widget<W: ratatui::widgets::Widget>(frame: &mut Frame, widget: W, rect: Rect) {
    let clipped = rect.intersection(frame.area());
    if clipped.width == 0 || clipped.height == 0 {
        return;
    }
    frame.render_widget(widget, clipped);
}

impl App {
    /// Run the app to completion.
    ///
    /// Returns how the process should end (see `app::resume::ExitOutcome`): the
    /// copy-pasteable resume hint on a normal quit, or a loud failure message
    /// when a launch-time `resume <id>` could not be honoured. Neither is
    /// printed here — the inline viewport is repainted during teardown, so
    /// anything written before `restore_terminal()` is wiped off the screen.
    /// `main` prints it AFTER the terminal is restored.
    pub async fn run(
        &mut self,
        mut terminal: Term,
        inline_h: u16,
    ) -> Result<crate::app::resume::ExitOutcome> {
        // Spawn terminal event reader (reassigned when we pause it around an
        // inline-viewport rebuild — see the switch below).
        let mut term_handle = terminal::spawn_terminal_reader(self.event_tx.clone());

        // Spawn tick timer
        let tick_tx = self.event_tx.clone();
        let tick_handle = tokio::spawn(async move {
            let mut interval = time::interval(Duration::from_millis(200));
            loop {
                interval.tick().await;
                if tick_tx.send(Event::Tick).is_err() {
                    break;
                }
            }
        });

        // Seed screen-reader (plain-text) mode from persisted config, or auto-detect
        // from the environment (NO_COLOR / accessibility hints) on first run.
        self.activity
            .set_a11y(self.config.a11y || crate::a11y::env_hint());

        // Initial health check
        self.check_health();

        // The terminal was built Inline; the app boots in Connecting (which wants
        // the full viewport), so the first iteration flips to full before drawing.
        let mut was_full = false;
        // Whether mouse capture is currently enabled. It is scoped ONLY to the
        // transcript overlay's lifetime: enabled when the reader opens, disabled
        // the instant it closes (Esc, q, Ctrl+O, scroll-off, backend swap, error —
        // every path funnels through `self.transcript` going back to None, which
        // this reconciler observes). The main view therefore never inherits a
        // stuck capture, which is what would break native wheel scrollback. A
        // final release also runs on loop exit, and `restore_terminal` disables it
        // unconditionally on process teardown / panic — three independent nets.
        let mut mouse_captured = false;
        // Current inline-viewport height. The composer grows the live region (up
        // to ~5 text lines) and a terminal resize reshapes it, so this tracks the
        // height the viewport is currently built at and is rebuilt when the wanted
        // height changes. Seeded with the height main.rs constructed the viewport.
        let mut cur_inline_h = inline_h;
        // Shrink-debounce state for the inline viewport (see the rebuild block
        // below). The wanted height dips transiently almost every tick (activity
        // spinner, streaming quantization, transient notices). Rebuilding on each
        // dip churns the viewport and, because every rebuild issues a DSR cursor
        // query tmux can drop, degrades into stale copies of the composer +
        // status bar stacked into scrollback. Count consecutive iterations a
        // *smaller* height has been wanted and only give the rows back once it
        // settles; grows still commit immediately.
        let mut shrink_streak: u8 = 0;
        const SHRINK_SETTLE_TICKS: u8 = 4; // ~0.8s at the 200ms tick cadence
        // Height of the slash-completions popup on the previous frame. Opening a
        // popup grows the viewport (already committed immediately); CLOSING it
        // (running a command) shrinks it, which the debounce above would hold for
        // ~0.8s -- long enough to leave the old, taller composer + status chrome
        // visibly STACKED below the new content the moment you run a command. A
        // popup open/close is a discrete user action, not a streaming dip, so it
        // must rebuild cleanly and immediately (like a resize), never debounced.
        let mut prev_popup_h: u16 = 0;
        // Top row (absolute terminal row) of the inline viewport the last time we
        // were inline, captured the instant BEFORE switching to the full/alternate
        // screen. `EnterAlternateScreen`/`LeaveAlternateScreen` (DECSET 1049) save
        // and restore the cursor position on the PRIMARY screen across the trip,
        // but ratatui's `Viewport::Inline` reconstruction anchors the new region on
        // wherever the cursor happens to be when it queries it back — which is
        // wherever the last inline draw left it (typically inside/below the
        // composer's own text-cursor row), NOT the top of the old chrome. Without
        // this, `switch_to_inline` builds the fresh region starting mid-way through
        // the OLD composer + status rows, leaving the rows above (the rest of the
        // old chrome) stranded on screen as a visible duplicate. Remembering the
        // real top lets us explicitly clear from there before rebuilding, so
        // exactly one copy of the chrome ever exists. See `switch_to_inline`.
        let mut last_inline_top: Option<u16> = None;
        // Whether a turn was in flight on the PREVIOUS iteration. The falling edge
        // of this is the one true "turn complete" event — see `turn_just_ended`
        // below and `App::settle_turn_chrome`.
        let mut prev_turn_active = false;
        // Resize-burst settle window. A window drag emits a Resize per
        // intermediate width; acting on each one produced ONE stranded live
        // region per step (the "nine ascending stacks" report), because every
        // rebuild re-anchors through a DSR cursor query and erases only the rect
        // it just computed. While the size is still moving we therefore do
        // NOTHING observable — no rebuild, no `insert_before`, no draw — and
        // commit once at the settled size. Codex settles for 75ms, grok for 16;
        // 50ms is comfortably longer than a drag's inter-event gap and still
        // below the ~100ms at which a resize starts to feel sticky.
        //
        // Ordering note: this is a burst *coalescer*, not the fix. The erase /
        // re-anchor defect is fixed independently (see `sample_frame_size` and
        // the resize arm of the rebuild block below); a debounce alone would
        // just reduce the number of stranded copies from nine to one.
        let mut resize_settle: Option<(FrameSize, std::time::Instant)> = None;
        const RESIZE_SETTLE: Duration = Duration::from_millis(50);
        // How long to nap between re-samples while a burst settles. Short enough
        // that the settle window dominates the latency, long enough not to spin.
        const RESIZE_POLL: Duration = Duration::from_millis(8);

        loop {
            // 1. Reconcile the terminal's viewport mode with what the app wants.
            let want_full = self.wants_full_viewport();

            // 0. Turn-completion edge. `turn_is_active()` covers the app being in
            // `Processing` AND a turn parked on the return stack under an overlay,
            // so its falling edge is the boundary of the whole TURN — not of one
            // assistant message, of which a turn can contain several (the ReAct
            // loop re-enters on the auto-continue nudge, the coding nudge, the
            // verification gate, the goal verifier…). Detecting it here, once,
            // rather than in each handler means completion, interrupt, cancel and
            // disconnect all settle identically.
            //
            // This runs BEFORE `desired_inline_height` so the height computed
            // below already reflects the retired chrome — the tear-down and the
            // shrink land in the SAME iteration, and with the same frame's
            // `insert_before` of the finished answer (step 2). That is what makes
            // completion read as the answer settling into place instead of the
            // working chrome hanging around beside it while the debounce runs out.
            let turn_active_now = self.turn_is_active();
            let turn_just_ended = prev_turn_active && !turn_active_now;
            prev_turn_active = turn_active_now;
            if turn_just_ended {
                self.settle_turn_chrome();
            }

            // ONE SIZE PER FRAME. Sampled exactly once, here, and threaded
            // through everything this iteration does — viewport sizing, band
            // measurement, the scrollback commit width, the surgical clear's
            // bottom clamp. Nothing below may ask the terminal again; see
            // `app::frame_size` and its source-guard test for why.
            let size = self.sample_frame_size();

            // Hold a moving resize. `self.resize_dirty` is set by whichever
            // observer saw the change first (the ioctl above, or the crossterm
            // Resize event); while the size is STILL moving, this iteration
            // produces nothing observable and simply re-samples.
            //
            // Critically it does not reach `terminal.draw` — a draw is what
            // hands control to ratatui's `autoresize`, and `autoresize` is what
            // re-anchors the viewport and leaves the previous one on screen.
            // Skipping the draw is therefore not an optimisation; it is the
            // thing that stops an intermediate width from ever being rendered.
            if !want_full && self.resize_dirty {
                let settled = match resize_settle {
                    Some((last, since)) if last == size => since.elapsed() >= RESIZE_SETTLE,
                    // First sighting, or the size moved again: restart the clock.
                    _ => {
                        resize_settle = Some((size, std::time::Instant::now()));
                        false
                    }
                };
                if !settled {
                    // Keep draining events (so a Resize still updates the size,
                    // and a Ctrl+C during a drag is still honoured), then loop.
                    match time::timeout(RESIZE_POLL, self.event_rx.recv()).await {
                        Ok(Some(event)) => {
                            if self.dispatch_event(event) {
                                break;
                            }
                        }
                        Ok(None) => break,
                        Err(_) => {}
                    }
                    continue;
                }
                resize_settle = None;
            }

            // Height the inline live region wants right now (grows with the
            // composer, always clamped to the terminal so it can't overflow).
            let desired_inline_h = self.desired_inline_height(size);
            // Did a terminal resize (pane split / drag) land since the last
            // frame? Consumed once here. The whole event backlog is drained by
            // `dispatch_event` before this runs, so a burst of Resize events from
            // a drag has already collapsed to the FINAL size in `self.width/height`
            // — a single rebuild at the settled size, never a per-event thrash.
            // Treat a slash-popup open/close exactly like a resize: force the
            // immediate clean rebuild (clear + rebuild) so a command that closes
            // the popup never leaves stacked chrome behind during the shrink
            // debounce. This is the fix for "it duplicates the composer/status
            // every time I run a command".
            // Both composer-anchored popups (`/` commands and the `@`-mention
            // dropdown) share one reserved band, so both share this edge.
            let popup_h_now = self.input.popup_desired_height();
            let popup_changed = popup_h_now != prev_popup_h;
            prev_popup_h = popup_h_now;
            // A REAL terminal resize (pane drag / window change). ONLY this may take
            // the destructive full-screen clear in the rebuild block below: the
            // emulator reflowed the whole screen, so the old chrome's position is
            // genuinely unknowable and a surgical clear cannot find it.
            let terminal_resized = std::mem::take(&mut self.resize_dirty);
            // Commit immediately (bypassing the shrink debounce) for a real resize
            // AND for a slash-popup open/close, so a command that closes the popup
            // never leaves stacked chrome behind mid-debounce.
            //
            // These two were previously ONE flag, and that was a real bug: the
            // completions popup recomputes its height on EVERY keystroke of a `/`
            // command (`/` → 10 rows, `/c` → 7, `/co` → 4 …), so aliasing it to
            // "resized" made every keypress take the full-screen `ClearType::All`
            // path — wiping the transcript and re-anchoring the viewport at row 0 on
            // each character typed. A popup change is a LOCAL height change: it must
            // commit promptly, but clear surgically.
            // A turn ending is the third exemption from the shrink debounce, and
            // for the same reason as the other two: it is a single, deliberate,
            // non-oscillating event, not a transient dip. `settle_turn_chrome`
            // above just retired the spinner, the tool feed, the reasoning box and
            // the agent roster, so the live region wants to be several rows
            // shorter — holding that shrink for SHRINK_SETTLE_TICKS is precisely
            // what left a tall band of dead chrome sitting under the finished
            // answer. Gated on the height actually changing so a turn whose chrome
            // was already minimal does not pay for a pointless DSR rebuild.
            let force_commit = terminal_resized
                || popup_changed
                || (turn_just_ended && desired_inline_h != cur_inline_h);
            // /clear was run: the in-memory transcript is already wiped
            // (commands.rs), but in inline mode the finalized messages were
            // flushed into the terminal's REAL scrollback via `insert_before`,
            // which no in-memory clear can touch. Only meaningful while inline —
            // a dialog owns the whole screen anyway, so there is no scrollback to
            // purge until we return. Handled before the mode-switch reconciliation
            // below so it never races a simultaneous dialog close.
            // Only actually consume the flag when we act on it. `/clear` can only
            // be typed from the composer (inline), but if it ever landed while a
            // dialog owns the full screen, leaving the flag set (instead of
            // `mem::take`-ing it unconditionally) means the clear is deferred
            // until we're back inline rather than silently dropped.
            let do_clear = !want_full && self.pending_clear;
            if do_clear {
                self.pending_clear = false;
                term_handle.abort();
                let _ = term_handle.await;
                purge_scrollback()?;
                rebuild_inline(&mut terminal, desired_inline_h)?;
                term_handle = terminal::spawn_terminal_reader(self.event_tx.clone());
                cur_inline_h = desired_inline_h;
                shrink_streak = 0;
                last_inline_top = Some(terminal.get_frame().area().top());
            } else if want_full != was_full {
                if want_full {
                    // Remember where the inline chrome currently starts (its real
                    // top row) before we leave it for the alternate screen — see
                    // `last_inline_top` above.
                    last_inline_top = Some(terminal.get_frame().area().top());
                    // Full screen (Terminal::new) does NOT query the cursor, so no
                    // reader contention — switch directly.
                    switch_to_full(&mut terminal)?;
                } else {
                    // Rebuilding the inline viewport issues a cursor-position query
                    // (DSR). The event reader shares stdin and would eat the
                    // response, timing the query out. Pause the reader, rebuild,
                    // then respawn it. The pause is a few ms; no input is lost in
                    // practice (the user just closed a dialog).
                    term_handle.abort();
                    let _ = term_handle.await;
                    switch_to_inline(&mut terminal, desired_inline_h, last_inline_top, size)?;
                    term_handle = terminal::spawn_terminal_reader(self.event_tx.clone());
                    cur_inline_h = desired_inline_h;
                    last_inline_top = Some(terminal.get_frame().area().top());
                }
                was_full = want_full;
                // A mode switch rebuilds the viewport fresh (switch_to_* clear +
                // reconstruct), so any pending resize is already absorbed.
            } else if want_full {
                // Staying full-screen (a dialog / onboarding owns the viewport).
                // ratatui's autoresize reflows the alt-screen buffer on the next
                // draw, but a resize can leave stale diff state — clear so every
                // cell repaints at the new size.
                if terminal_resized {
                    let _ = terminal.clear();
                }
            } else if force_commit || desired_inline_h != cur_inline_h {
                // Staying inline, and either a real resize landed or the wanted
                // height changed. Rebuilding the inline viewport issues a DSR
                // cursor query that tmux can drop, so every rebuild risks leaving
                // a stale copy of the composer + status bar in scrollback. The
                // wanted height oscillates tick to tick (activity spinner,
                // streaming quantization, transient notices such as "Reconnecting
                // to backend…" that live in the fixed hint row), so rebuilding on
                // every change churns the viewport and stacks duplicate chrome.
                //
                // Debounce it as a high-water mark. A GROW commits immediately
                // (the composer must feel responsive and streaming content must
                // never clip off the bottom); a SHRINK is held until the smaller
                // height has been wanted for SHRINK_SETTLE_TICKS consecutive
                // iterations. A momentary dip that bounces back up to the current
                // height therefore never triggers a rebuild at all.
                //
                // A RESIZE is exempt from the debounce: a pane split / drag is a
                // deliberate size change, so it commits immediately even when the
                // height shrinks — and even when the height is UNCHANGED (a
                // horizontal split changes only the width), so the viewport is
                // rebuilt fresh and the old-width rows are cleared. This is what
                // makes the transcript / composer / status bar reflow cleanly to
                // the new width instead of leaving stale, misaligned rows.
                let commit = if force_commit {
                    shrink_streak = 0;
                    true
                } else if desired_inline_h > cur_inline_h {
                    shrink_streak = 0;
                    true
                } else {
                    shrink_streak = shrink_streak.saturating_add(1);
                    shrink_streak >= SHRINK_SETTLE_TICKS
                };
                if commit {
                    shrink_streak = 0;
                    // Erase the OLD inline chrome before rebuilding fresh. Pause the
                    // reader FIRST (shared stdin) so the DSR cursor query below isn't
                    // eaten by it, exactly as the full→inline switch does.
                    term_handle.abort();
                    let _ = term_handle.await;

                    if terminal_resized {
                        // ACTUAL terminal resize. The emulator reflowed the whole
                        // screen, so the old chrome floated to an unknown row — and on
                        // terminals that DROP the DSR cursor query mid-resize, no
                        // surgical anchor can find it (the "N% context used" staircase)
                        // and deferring to ratatui's autoresize surfaces the failed
                        // query as the "cursor position could not be read" CRASH. The
                        // only reflow-proof, DSR-free option is to wipe the whole
                        // screen and rebuild. Cost: the on-screen transcript is cleared
                        // on resize (still in scrollback history + the transcript
                        // viewer). This ONLY runs on a real resize.
                        //
                        // The erase is ED0-from-home (`ESC[H` + `ESC[J`), NOT ED2
                        // (`ESC[2J`). Visually the two are identical — both leave a
                        // blank screen with the cursor at (0, 0) — but ED2 is NOT a
                        // pure erase on the VTE family (GNOME Terminal, Tilix,
                        // Terminator, and every other libvte embedder): VTE
                        // implements it by SCROLLING the current screen into the
                        // scrollback buffer, which is why `clear(1)` there leaves the
                        // old screen readable above. Emitting it once per resize step
                        // therefore deposited a full snapshot of the live region —
                        // composer, status bar, and whatever markdown was mid-render
                        // — into unreflowable scrollback on EVERY step of a window
                        // drag. A drag through 15 columns left 15 stacked copies, each
                        // one column narrower than the last: the "cascade of
                        // horizontal rules" a bordered markdown table produced, and
                        // the same mechanism behind the older "composer duplicates
                        // down the screen on resize" reports.
                        //
                        // ED0 (erase from cursor to end of screen) is specified as an
                        // in-place erase and is implemented as one by VTE, xterm,
                        // kitty and Alacritty alike, so it wipes the screen without
                        // touching scroll history. Every other inline clear in this
                        // file already uses it; this was the one hole.
                        //
                        // EXCEPT inside a multiplexer, where the premise above
                        // is false. The whole justification for the
                        // full-screen wipe is "the emulator reflowed, so the
                        // old chrome's row is unknowable" — but tmux and
                        // screen do NOT reflow on a width change. The remembered
                        // `last_inline_top` therefore stays valid, and the
                        // surgical clear used for height changes is both
                        // sufficient and non-destructive.
                        //
                        // This matters because the full-screen path was the
                        // stranding: under tmux the live region scrolls into
                        // pane history as it redraws at each new width, and no
                        // erase reaches history — a 12-step drag left 13 copies
                        // (`test/pty/tmux_resize.py`). Clearing from the known
                        // top instead means the old chrome is overwritten in
                        // place and never becomes history in the first place,
                        // which is how Claude Code survives the identical drag
                        // with one prompt box (measured, same harness).
                        //
                        // The rejected alternative was ED3 (purge pane
                        // history). It worked, but destroyed the user's
                        // scrollback on every resize to clean up a mess this
                        // branch did not need to make.
                        let surgical_top = if in_multiplexer() { last_inline_top } else { None };
                        if let Some(top) = surgical_top {
                            let max_row = size.rows.saturating_sub(1);
                            let _ = execute!(
                                std::io::stdout(),
                                crossterm::cursor::MoveTo(0, top.min(max_row)),
                                crossterm::terminal::Clear(
                                    crossterm::terminal::ClearType::FromCursorDown
                                ),
                            );
                        } else {
                            let _ = clear_screen_for_resize(&mut std::io::stdout());
                        }
                    } else if let Some(top) = last_inline_top {
                        // Pure HEIGHT change (composer grew/shrank, a transient notice
                        // appeared) — NOT a resize. The terminal did NOT reflow, so the
                        // region's tracked top is still valid and the transcript above
                        // it must be preserved. Clear ONLY from that row down. Wiping
                        // the whole screen here (the earlier bug) repainted on every
                        // notice / keystroke / scroll and stacked chrome. Clamp into
                        // the current screen in case a shrink left the row past bottom.
                        let max_row = size.rows.saturating_sub(1);
                        let _ = execute!(
                            std::io::stdout(),
                            crossterm::cursor::MoveTo(0, top.min(max_row)),
                            crossterm::terminal::Clear(
                                crossterm::terminal::ClearType::FromCursorDown
                            ),
                        );
                    }

                    // Rebuild fresh to bypass ratatui's in-place inline-resize
                    // (which can misplace the viewport on a shrink).
                    rebuild_inline(&mut terminal, desired_inline_h)?;
                    term_handle = terminal::spawn_terminal_reader(self.event_tx.clone());
                    cur_inline_h = desired_inline_h;
                    last_inline_top = Some(terminal.get_frame().area().top());
                }
            } else {
                // Staying inline, wanted height already matches what's built, no
                // resize — reset the shrink debounce so a later transient dip
                // starts its settle window fresh instead of firing on the first
                // dip.
                shrink_streak = 0;
            }

            // 1a2. Reconcile mouse capture with the transcript overlay lifetime.
            // Capture is scoped to the reader ONLY: enabling it globally would
            // steal the wheel from the terminal's native scrollback in the main
            // view. This transition-driven reconcile guarantees release on EVERY
            // close path (the overlay just sets `self.transcript = None`), so a
            // leaked EnableMouseCapture can never strand the main view.
            let want_mouse = self.transcript.is_some();
            if want_mouse != mouse_captured {
                let mut out = std::io::stdout();
                let _ = if want_mouse {
                    execute!(out, EnableMouseCapture)
                } else {
                    execute!(out, DisableMouseCapture)
                };
                mouse_captured = want_mouse;
            }

            // 1b. Emit the OSA welcome banner (bordered box + ASCII logo) into the
            //     scrollback exactly once, before any messages, so it sits at the top.
            if !was_full {
                if let Some((tool_count, provider, model)) =
                    self.pending_welcome_banner.take()
                {
                    // This frame's width (the inline frame area can lag a resize
                    // and under-report it, which is why the banner must use the
                    // frame's sampled size rather than `get_frame().area()`).
                    let w = size.cols;
                    let lines = crate::components::chat::welcome::welcome_lines(
                        w,
                        tool_count,
                        provider.as_deref(),
                        model.as_deref(),
                        Some(self.working_dir.as_str()),
                    );
                    let h = lines.len() as u16;
                    if h > 0 {
                        terminal.insert_before(h, |buf| {
                            ratatui::widgets::Widget::render(
                                ratatui::widgets::Paragraph::new(ratatui::text::Text::from(lines)),
                                Rect::new(0, 0, w, h),
                                buf,
                            );
                        })?;
                    }
                }
            }

            // 2. Flush finalized messages into the terminal's native scrollback.
            //    Only meaningful in inline mode — the alt screen (full mode) has no
            //    persistent scrollback, so queued items wait until we return inline.
            //    Batched: every `insert_before` is a full viewport rebuild, so a
            //    reply that now flows into scrollback block by block (see
            //    `AssistantStream::settle`) would otherwise pay one rebuild per
            //    completed paragraph. Everything drained in the same iteration
            //    goes out in ONE call, rendered at stacked y-offsets — so the
            //    rebuild count is bounded by frames in which something settled,
            //    not by blocks. The batch is flushed whenever adding the next
            //    message would take it past a screenful, which keeps a single
            //    `insert_before` from ever having to scroll more than the
            //    terminal can show at once (an over-tall single message still
            //    goes out alone, exactly as before).
            if !was_full && self.chat.has_pending_scrollback() {
                // Both from this frame's ONE size. `get_frame().area().width` was
                // a third, independent size source: it reports the width the
                // viewport was last BUILT at, so mid-drag it lags the ioctl and
                // finalized messages were rendered — permanently, into native
                // scrollback — at a width the terminal no longer had.
                let w = size.cols;
                let cap = size.rows.max(1);
                let mut batch: Vec<(crate::components::chat::message::Message, u16)> = Vec::new();
                let mut batch_h: u16 = 0;

                fn flush(
                    terminal: &mut ratatui::Terminal<impl ratatui::backend::Backend>,
                    batch: &mut Vec<(crate::components::chat::message::Message, u16)>,
                    batch_h: u16,
                    w: u16,
                ) -> std::io::Result<()> {
                    if batch_h == 0 {
                        batch.clear();
                        return Ok(());
                    }
                    terminal.insert_before(batch_h, |buf| {
                        let mut y = 0u16;
                        for (msg, h) in batch.iter() {
                            msg.render_to_buffer(Rect::new(0, y, w, *h), buf, 0);
                            y = y.saturating_add(*h);
                        }
                    })?;
                    batch.clear();
                    Ok(())
                }

                for msg in self.chat.drain_scrollback() {
                    // Capture a text copy for the on-demand transcript viewer as
                    // each finalized message flows into native scrollback. This is
                    // the single choke point every message passes through, so it
                    // retains the full conversation regardless of which handler
                    // produced it.
                    if let Some(entry) =
                        crate::dialogs::transcript_viewer::entry_from_message(&msg)
                    {
                        self.transcript_log.push(entry);
                    }
                    let h = msg.height(w);
                    if h == 0 {
                        continue;
                    }
                    if batch_h > 0 && batch_h.saturating_add(h) > cap {
                        flush(&mut terminal, &mut batch, batch_h, w)?;
                        batch_h = 0;
                    }
                    batch_h = batch_h.saturating_add(h);
                    batch.push((msg, h));
                }
                flush(&mut terminal, &mut batch, batch_h, w)?;
            }

            // `insert_before` (the welcome banner + every finalized-message flush
            // above) moves the inline viewport's REAL top DOWN by the inserted
            // height (ratatui `set_viewport_area`). `last_inline_top` is otherwise
            // refreshed only at rebuild points, so without this it goes stale the
            // moment a message flushes to scrollback — and the next surgical
            // height-change clear then anchors `FromCursorDown` at that stale,
            // higher row and WIPES the just-flushed transcript rows. Re-read the
            // real top here so the tracked value always matches where the region
            // actually is. Cheap: `get_frame().area()` is a cached Rect.
            if !was_full {
                last_inline_top = Some(terminal.get_frame().area().top());
            }

            // 2b. Hard repaint (Ctrl+L / return from a Ctrl+Z suspend): drop
            // the terminal's diff state so the next draw repaints every cell,
            // recovering the live region from any stray output corruption.
            if self.force_redraw {
                self.force_redraw = false;
                let _ = terminal.clear();
            }

            // 2c. WS12 chrome: terminal tab title (busy animation) + the 6s
            // unanswered-permission desktop ping. Deduped internally, so the
            // 200ms tick cadence costs nothing when idle.
            self.sync_chrome();

            // 2d. U-T12/T15 — reconcile taskbar progress + sleep inhibitor with
            // the live-turn state (start on turn entry, keepalive on tick, clear
            // on turn end). Cheap when idle; the reconciler self-throttles.
            self.sync_turn_effects();

            // 3. Draw the live region (inline) or the modal / fullscreen view (full).
            // Wrap the frame in a DEC 2026 synchronized update (BSU/ESU) so the
            // terminal composites the whole frame atomically — no tearing or
            // half-drawn streaming rows on the frequently-rebuilt inline viewport.
            // The pair is written synchronously around this single draw (no await
            // between), so it can never dangle; unsupported terminals ignore the
            // private-mode sequence. Errors are non-fatal — the frame still draws.
            let mut sync_out = std::io::stdout();
            let _ = execute!(sync_out, crossterm::terminal::BeginSynchronizedUpdate);
            let draw_res = terminal.draw(|frame| self.draw(frame));
            let _ = execute!(sync_out, crossterm::terminal::EndSynchronizedUpdate);
            draw_res?;

            // 4. Block until at least one event is available.
            let event = match self.event_rx.recv().await {
                Some(event) => event,
                None => break, // all senders dropped
            };
            let mut should_quit = self.dispatch_event(event);

            // Coalesce: apply every queued event before redrawing. During streaming
            // the backend emits one StreamingToken per token; draining the backlog
            // collapses a burst into a single redraw (the main lever for smooth,
            // fast streaming). FIFO order is preserved.
            while !should_quit {
                match self.event_rx.try_recv() {
                    Ok(event) => should_quit = self.dispatch_event(event),
                    Err(_) => break,
                }
            }

            // A failed launch-time resume is a quit condition in its own right:
            // there is no session to sit in, and staying would present an empty
            // conversation as if it were the one the user asked for.
            if should_quit || self.fatal_exit.is_some() {
                break;
            }
        }

        // Cleanup
        // Belt-and-braces: if the loop broke while the overlay was still open,
        // release mouse capture so the shell never inherits a captured terminal.
        // (`restore_terminal` also disables it unconditionally on teardown/panic.)
        if mouse_captured {
            let _ = execute!(std::io::stdout(), DisableMouseCapture);
        }
        self.chrome_title.reset(); // hand the tab title back to the shell
        tick_handle.abort();
        term_handle.abort();

        // If a dialog still owned the full/alternate screen when the loop broke
        // (quitting through the `/quit` confirm does exactly this), come back to
        // the primary screen FIRST. Everything below — and the exit hint `main`
        // prints — has to act on the surface the shell will inherit.
        if was_full && crate::app::alt_screen::is_active() {
            let _ = execute!(std::io::stdout(), LeaveAlternateScreen);
            crate::app::alt_screen::mark_left();
        }

        // Erase the inline chrome (composer + status rows) on the way out, so
        // the exit hint lands on clean lines instead of half-overwriting the
        // status bar. The chrome is bottom-anchored at `term_rows - inline_h`
        // (the geometry asserted by `resize_clear_top_from_bottom`), so clearing
        // from there down erases exactly it and never the real transcript
        // scrollback above it.
        // Teardown runs after the last frame, so this is a fresh sample of its
        // own rather than a frame's threaded size.
        let term_rows = crate::app::frame_size::probe().rows;
        if let Some(top) = clamp_inline_top(Some(term_rows.saturating_sub(cur_inline_h)), term_rows)
        {
            let _ = execute!(
                std::io::stdout(),
                crossterm::cursor::MoveTo(0, top),
                crossterm::terminal::Clear(crossterm::terminal::ClearType::FromCursorDown)
            );
        }
        if let Some(cancel) = self.sse_cancel.take() {
            cancel.cancel();
        }

        // A launch-time resume that could not be resolved leaves through the
        // LOUD arm: stderr + exit 2, never a blank conversation that reads as a
        // normal fresh session.
        if let Some(msg) = self.fatal_exit.take() {
            info!("App exiting with a launch failure: {}", msg);
            return Ok(crate::app::resume::ExitOutcome::Failed(msg));
        }

        info!("App exiting cleanly");
        Ok(crate::app::resume::ExitOutcome::normal(self.exit_resume_hint()))
    }

    /// The `Resume this session with: …` block to print after teardown, or
    /// `None` when this session has nothing worth coming back to.
    fn exit_resume_hint(&self) -> Option<String> {
        let had_user_turn = self.chat.last_user_message().is_some();
        if !crate::app::resume::should_print_hint(&self.session_id, had_user_turn) {
            return None;
        }
        Some(crate::app::resume::resume_hint_block(
            &self.session_id,
            &self.launch_mode,
        ))
    }

    /// Route an event through the transcript overlay layer before the normal
    /// `update` pipeline. This keeps the Ctrl+O reader self-contained: it owns key
    /// input while open, toggles from the plain chat surface, and records keypress
    /// activity for the completion-notification idle heuristic.
    fn dispatch_event(&mut self, event: Event) -> bool {
        // U-T11 — fold terminal focus transitions (DECSET 1004 FocusGained/Lost,
        // enabled in main.rs) into the process-global focus flag so the
        // turn-complete notifier can gate on real "user is away" state. A no-op
        // for every non-focus event.
        if let Event::Terminal(ref ev) = event {
            crate::notification::focus::note_event(ev);
            // Regaining focus forces one full repaint of the live region.
            //
            // An outer layer can repaint OSA's pane out of band with no PTY
            // resize at all — tmux redrawing a pane after a layout change,
            // nvim's `:terminal` restoring a window, a multiplexer client
            // re-attaching. ratatui only rewrites cells whose own model
            // changed, so rows it does not know were damaged stay damaged
            // (stranded, doubled or half-erased chrome) until something else
            // happens to repaint them. There is no event that reports the
            // damage, but focus is regained on essentially every path that
            // causes it, which makes `FocusGained` a cheap and reliable heal.
            //
            // `force_redraw` clears only the inline viewport (ratatui's inline
            // `clear` is viewport-top + ED0) and repaints it, so it can never
            // reach the transcript above — a repaint, not a wipe. Borrowed from
            // grok-build, which pins the same behaviour with a PTY test that
            // injects a stranded row and asserts `ESC[I` removes it.
            if matches!(ev, CrosstermEvent::FocusGained) {
                self.force_redraw = true;
            }
        }
        if let Event::Terminal(CrosstermEvent::Key(key)) = &event {
            if key.kind == KeyEventKind::Press {
                // Any keypress counts as activity (turn-complete idle heuristic).
                self.last_user_input = Some(std::time::Instant::now());

                // While open, the transcript overlay is modal over key input.
                if self.transcript.is_some() {
                    return self.handle_transcript_key(*key);
                }
                // Ctrl+O opens the reader from the normal chat surface only.
                if is_ctrl_o(key) && self.transcript_can_open() {
                    self.transcript =
                        Some(crate::dialogs::transcript_viewer::TranscriptViewer::open(
                            &self.transcript_log,
                        ));
                    return false;
                }
            }
        }
        // Mouse capture is enabled ONLY while the transcript overlay is open (see
        // the run-loop reconciler), so mouse reports arrive only then — route them
        // to the reader for wheel-scroll / drag-select / copy. Outside the overlay
        // no capture is active and the main view keeps native wheel scrollback.
        if let Event::Terminal(CrosstermEvent::Mouse(me)) = &event {
            if self.transcript.is_some() {
                return self.handle_transcript_mouse(*me);
            }
        }
        self.update(event)
    }

    /// Whether Ctrl+O should open the transcript reader right now. Declines when
    /// another overlay owns Ctrl+O (agents panel collapse, file picker, reasoning
    /// selector, dialogs) or there is nothing to show, so existing bindings and
    /// the update-layer Ctrl+O handling are left intact.
    pub(crate) fn transcript_can_open(&self) -> bool {
        !self.transcript_log.is_empty()
            && !self.agents.is_active()
            && self.file_picker.is_none()
            && self.reasoning_selector.is_none()
            // U-B2 — when the last tool result is still collapsed, Ctrl+O should
            // EXPAND it first (via chat:expandTools in the update layer). Only
            // once nothing is expandable does Ctrl+O open the transcript reader.
            && !self.chat.has_expandable_last_tool()
            && matches!(
                self.state,
                AppState::Idle | AppState::Processing | AppState::Recording
            )
    }

    /// Route a key to the open transcript overlay and act on its result.
    fn handle_transcript_key(&mut self, key: KeyEvent) -> bool {
        use crate::dialogs::transcript_viewer::TranscriptAction;
        // Disjoint field borrows: `transcript` (mut) and the entry source (shared).
        let entries: &[crate::dialogs::transcript_viewer::TranscriptEntry] =
            if let Some(ref o) = self.transcript_override {
                o
            } else {
                &self.transcript_log
            };
        let action = match self.transcript {
            Some(ref mut tv) => tv.handle_key(key, entries),
            None => return false,
        };
        match action {
            TranscriptAction::None => {}
            TranscriptAction::Close => {
                self.transcript = None;
                self.transcript_override = None;
            }
            TranscriptAction::Toast(msg) => {
                self.toasts
                    .push(msg, crate::components::toast::ToastLevel::Info);
            }
        }
        false
    }

    /// Route a mouse event to the open transcript overlay (wheel scroll, drag
    /// selection, copy-on-release). Only reached while `transcript.is_some()`,
    /// which is also the only time mouse capture is enabled.
    fn handle_transcript_mouse(&mut self, me: crossterm::event::MouseEvent) -> bool {
        use crate::dialogs::transcript_viewer::TranscriptAction;
        let entries: &[crate::dialogs::transcript_viewer::TranscriptEntry] =
            if let Some(ref o) = self.transcript_override {
                o
            } else {
                &self.transcript_log
            };
        let action = match self.transcript {
            Some(ref mut tv) => tv.handle_mouse(me, entries),
            None => return false,
        };
        match action {
            TranscriptAction::None => {}
            TranscriptAction::Close => {
                self.transcript = None;
                self.transcript_override = None;
            }
            TranscriptAction::Toast(msg) => {
                self.toasts
                    .push(msg, crate::components::toast::ToastLevel::Info);
            }
        }
        false
    }

    fn draw(&self, frame: &mut Frame) {
        let area = frame.area();

        // Transcript overlay takes the whole viewport when open (additive reader;
        // native scrollback is untouched underneath).
        if let Some(ref tv) = self.transcript {
            let entries: &[crate::dialogs::transcript_viewer::TranscriptEntry] =
                if let Some(ref o) = self.transcript_override {
                    o
                } else {
                    &self.transcript_log
                };
            tv.draw(frame, area, entries);
            if self.toasts.has_toasts() {
                self.toasts
                    .draw(frame, toast_rect(area, self.toasts.live_count()).intersection(area));
            }
            return;
        }

        if self.wants_full_viewport() {
            frame.render_widget(ratatui::widgets::Clear, area);
            match self.state {
                AppState::Connecting => {
                    crate::view::connecting::draw_connecting(frame, area);
                }
                AppState::Onboarding => {
                    if let Some(ref wizard) = self.onboarding {
                        crate::view::onboarding_flow::draw_onboarding_flow(frame, area, wizard);
                    } else {
                        crate::view::connecting::draw_connecting(frame, area);
                    }
                }
                AppState::AgentsDashboard => {
                    let bg_rows = self.dashboard_bg_rows();
                    self.agents.draw_dashboard(
                        frame,
                        area,
                        self.agents_dashboard_selected,
                        &bg_rows,
                        self.bg_shell_count,
                    );
                }
                _ => {
                    // Floating Option-overlays take highest modal priority (drawn
                    // over whatever state is underneath). The priority order is
                    // resolved ONCE by `active_modal_overlay`, shared verbatim with
                    // the key router (update.rs) so the overlay painted on top is
                    // always the one that receives the keys.
                    use crate::app::ModalOverlay;
                    match self.active_modal_overlay() {
                        Some(ModalOverlay::Overdrive) => {
                            if let Some(ref d) = self.overdrive_confirm {
                                d.draw(frame, area);
                            }
                        }
                        Some(ModalOverlay::ConfigEditor) => {
                            if let Some(ref editor) = self.config_editor {
                                editor.draw(frame, area);
                            }
                        }
                        Some(ModalOverlay::FilePicker) => {
                            if let Some(ref picker) = self.file_picker {
                                picker.draw(frame, area);
                            }
                        }
                        Some(ModalOverlay::Reasoning) => {
                            // `/reasoning` (no arg) sets this Option-overlay and its
                            // key handler is wired (update.rs); without this arm it
                            // opened an INVISIBLE modal that swallowed keystrokes.
                            if let Some(ref sel) = self.reasoning_selector {
                                sel.draw(frame, area);
                            }
                        }
                        None => {
                            match self.state {
                            AppState::Quit => self.quit_dialog.draw(frame, area),
                            AppState::Palette => self.palette.draw(frame, area),
                            AppState::ModelPicker => {
                                if let Some(ref m) = self.model_picker {
                                    m.draw(frame, area);
                                }
                            }
                            AppState::Sessions => {
                                if let Some(ref b) = self.session_browser {
                                    b.draw(frame, area);
                                }
                            }
                            AppState::Rewind => {
                                if let Some(ref d) = self.rewind_dialog {
                                    d.draw(frame, area);
                                }
                            }
                            // AppState::Permissions has no draw arm here: the
                            // permission ask renders inline (see draw_inline), and
                            // Permissions is not an is_overlay() state, so this
                            // full-viewport branch was unreachable dead code and was
                            // removed. It falls through to the `_ => {}` no-op.
                            // AppState::PlanReview has no draw arm here: like the
                            // permission ask, the plan-review panel renders INLINE
                            // (see draw_inline), and PlanReview is no longer an
                            // is_overlay() state, so this full-viewport branch was
                            // unreachable. It falls through to the `_ => {}` no-op.
                            // AppState::Survey has no draw arm either: the
                            // ask_user picker renders INLINE in its own reserved
                            // band (see `survey_slot` / `draw_inline`) and Survey
                            // is no longer an is_overlay() state, so this
                            // full-viewport branch is unreachable. It falls
                            // through to the `_ => {}` no-op.
                            AppState::Status => {
                                // Stateless: build a live snapshot each frame so the
                                // dashboard numbers are never stale.
                                let view = crate::dialogs::status_dashboard::StatusView {
                                    model: self.header.model_name().to_string(),
                                    provider: self.header.provider().to_string(),
                                    tools: self.header.tool_count(),
                                    context_util: self.status.context_utilization(),
                                    context_max: self.status.context_max_label(),
                                    mode: self.status.permission_mode(),
                                    session: self.session_id.clone(),
                                    version: crate::config::osa_version_display().to_string(),
                                };
                                crate::dialogs::status_dashboard::draw(frame, area, &view);
                            }
                            AppState::ThemePicker => {
                                if let Some(ref d) = self.theme_picker {
                                    d.draw(frame, area);
                                }
                            }
                            AppState::Keybindings => {
                                if let Some(ref d) = self.keybindings_viewer {
                                    d.draw(frame, area);
                                }
                            }
                            AppState::Tools => {
                                if let Some(ref d) = self.tools_browser {
                                    d.draw(frame, area);
                                }
                            }
                            AppState::ContextBreakdown => {
                                if let Some(ref s) = self.context_stats {
                                    crate::dialogs::context_breakdown::draw(frame, area, s);
                                }
                            }
                            AppState::Trust => {
                                if let Some(ref d) = self.trust_dialog {
                                    d.draw(frame, area);
                                }
                            }
                            AppState::PermissionsManager => {
                                if let Some(ref d) = self.permissions_manager {
                                    d.draw(frame, area);
                                }
                            }
                            AppState::Hooks => {
                                if let Some(ref d) = self.hooks_viewer {
                                    d.draw(frame, area);
                                }
                            }
                            AppState::Mcp => {
                                if let Some(ref d) = self.mcp_servers {
                                    d.draw(frame, area);
                                }
                            }
                            AppState::Cost => {
                                if let Some(ref d) = self.cost_dashboard {
                                    d.draw(frame, area);
                                }
                            }
                            AppState::Skills => {
                                if let Some(ref d) = self.skills_browser {
                                    d.draw(frame, area);
                                }
                            }
                            AppState::Channels => {
                                if let Some(ref d) = self.channels_panel {
                                    d.draw(frame, area);
                                }
                            }
                            AppState::Memory => {
                                if let Some(ref d) = self.memory_browser {
                                    d.draw(frame, area);
                                }
                            }
                            AppState::Persona => {
                                if let Some(ref d) = self.persona_picker {
                                    d.draw(frame, area);
                                }
                            }
                            AppState::Sandbox => {
                                if let Some(ref d) = self.sandbox_picker {
                                    d.draw(frame, area);
                                }
                            }
                            AppState::Metrics => {
                                if let Some(ref d) = self.metrics_dashboard {
                                    d.draw(frame, area);
                                }
                            }
                            AppState::Tasks => {
                                if let Some(ref d) = self.tasks_panel {
                                    d.draw(frame, area);
                                }
                            }
                            _ => {}
                            }
                        }
                    }
                }
            }
            if self.toasts.has_toasts() {
                self.toasts
                    .draw(frame, toast_rect(area, self.toasts.live_count()).intersection(area));
            }
        } else {
            self.draw_inline(frame, area);
        }
    }

    /// Height the inline viewport wants right now. Driven by the composer's
    /// current needed height (so pressing Shift+Enter visibly grows the live
    /// region up to ~5 text lines), with a fixed chrome overhead and a clamp to
    /// the terminal size — see [`live_region_height`]. Kept independent of
    /// transient activity rows so the viewport doesn't churn mid-turn.
    ///
    /// While a reply is streaming, the live region reserves a FIXED-height
    /// preview slot ([`STREAM_PREVIEW_ROWS`]) instead of growing with the reply.
    /// The newest lines scroll INTERNALLY within the slot (`Chat::draw_live`
    /// bottom-anchors the tail, same markdown/wrapping render as the finalized
    /// transcript), so the inline-viewport height is constant for the whole turn.
    /// This is the "real cure": the old growth branch rebuilt the viewport
    /// mid-turn, and each rebuild issued a DSR cursor query tmux/SSH can drop,
    /// leaving stacked / whitespace artifacts. A pending plan-review panel is
    /// reserved the same way (fixed slot), and completed content still flushes to
    /// native scrollback as before.
    /// This frame's size. Written exactly once per run-loop iteration by
    /// [`Self::sample_frame_size`]; every measurement and every layout inside
    /// the frame reads it from here, so a reservation and the paint it governs
    /// are computed against the same numbers by construction.
    pub(crate) fn frame_size(&self) -> FrameSize {
        FrameSize::new(self.width, self.height)
    }

    /// Capture the ONE size this frame is laid out against — **first**, before
    /// anything else in the iteration can observe a different one.
    ///
    /// "One size per frame" is only half the invariant. The other half is *read
    /// first*: if OSA learns of a resize later than ratatui does, ratatui
    /// reconciles behind it and the unification buys nothing.
    ///
    /// It really does reconcile. In ratatui 0.29 (`terminal/terminal.rs`),
    /// `Terminal::draw` → `autoresize()` (line 242) queries `backend.size()` on
    /// EVERY draw of an inline viewport and, on any mismatch with
    /// `last_known_area`, calls `resize()` (line 212) → `compute_inline_size()`
    /// (line 824). That issues a **DSR cursor query**, re-anchors the viewport,
    /// and then calls `self.clear()` — which clears the viewport area *it just
    /// computed*, i.e. the NEW rect. The old rect is never erased. One stranded
    /// live region per intermediate width is precisely the "nine ascending
    /// stacks after one drag" report. `insert_before` has the same dependency:
    /// it scrolls by `last_known_area.height` and renders at
    /// `last_known_area.width` (lines 617, 772, 795), so a stale value commits
    /// finalized messages to native scrollback at a width the terminal no longer
    /// has.
    ///
    /// So the size is taken from the **ioctl**, which reflects the kernel's view
    /// as of SIGWINCH — strictly earlier than the crossterm `Resize` event,
    /// which has to travel through the reader task first. Adopting it here means
    /// OSA has already marked the viewport dirty (and, with the settle window
    /// below, will not draw at all) before ratatui gets a chance to reconcile.
    ///
    /// The result is stored into `self.width` / `self.height`, which is what
    /// every component measures itself at — so "measured at one width, laid out
    /// at another" stops being expressible.
    fn sample_frame_size(&mut self) -> FrameSize {
        let size = crate::app::frame_size::probe();
        self.adopt_frame_size(size);
        size
    }

    /// Adopt a terminal size observed by *either* observer — the top-of-loop
    /// ioctl or the crossterm `Resize` event — and re-lay-out for it.
    ///
    /// Returns whether the size actually changed. Idempotent, so whichever
    /// observer notices first does the work and the other is a no-op; that is
    /// what lets the ioctl run ahead of the event without doing it twice.
    pub(crate) fn adopt_frame_size(&mut self, size: FrameSize) -> bool {
        if self.width == size.cols && self.height == size.rows {
            return false;
        }
        let width_changed = self.width != size.cols;
        self.width = size.cols;
        self.height = size.rows;
        // Re-derive every wrap width and push it into chat/input/status;
        // `Chat::set_size` invalidates the width-keyed render caches (per-message
        // wrapped height + the live streaming markdown cache) so nothing renders
        // at the stale width.
        self.recompute_layout();
        // A width change additionally forces a defensive re-invalidation of the
        // width-keyed caches — `recompute_layout` already did this via
        // `set_size`, but keep the intent explicit and independent of that
        // call's internals so a future refactor cannot silently drop the reflow.
        if width_changed {
            self.chat.invalidate_width_caches();
        }
        // Signal the run loop to rebuild the inline viewport fresh at the new
        // size. Without this a width-only resize (a horizontal split) leaves the
        // viewport at its old geometry with stale rows, and a height shrink
        // would be held by the transient-dip debounce for ~0.8s.
        self.resize_dirty = true;
        true
    }

    pub fn desired_inline_height(&self, size: FrameSize) -> u16 {
        let term_rows = size.rows;
        // ONE measurement, shared with `draw_inline`. Sizing and layout used to
        // be two hand-written sums of the same ten numbers, each maintained by
        // discipline; every band that ever "silently stole rows from the
        // streaming reply" was one of them drifting from the other.
        let b = self.measure_bands(size);
        let input_needed = b.input;
        let hi0 = term_rows.saturating_sub(1).max(1);
        let base = live_region_height(input_needed, term_rows)
            .saturating_add(b.agents)
            .saturating_add(b.checklist)
            .saturating_add(b.survey)
            .saturating_add(b.toast)
            .saturating_add(b.popup)
            .saturating_add(b.think)
            .min(hi0);

        // A pending permission prompt renders inline above the composer; grow the
        // live region to fit its compact height so the ask isn't clipped.
        if let Some(ref perm) = self.permissions {
            let perm_rows = perm.desired_height(size.cols);
            let overhead: u16 = b.think + b.hint + b.status;
            let want = overhead
                .saturating_add(input_needed)
                .saturating_add(perm_rows)
                .saturating_add(b.agents)
                .saturating_add(b.toast)
                .saturating_add(b.popup);
            let hi = term_rows.saturating_sub(1).max(1);
            return want.clamp(base, hi);
        }

        // A pending plan-review panel renders INLINE in the stream band (it is no
        // longer an is_overlay() full-viewport state — see state.rs). Reserve its
        // fixed panel height so the inline viewport is built tall enough to show
        // the bordered panel without clipping. The plan text scrolls internally
        // (j/k), so this reserved height is constant regardless of plan length —
        // the same fixed-slot principle as the streaming preview below. Mirrors
        // the permission-prompt branch above.
        if let Some(ref review) = self.plan_review {
            let overhead: u16 = b.think + b.hint + b.status;
            let want = overhead
                .saturating_add(input_needed)
                .saturating_add(review.desired_height(size.cols))
                .saturating_add(b.agents)
                .saturating_add(b.toast)
                .saturating_add(b.popup);
            let hi = term_rows.saturating_sub(1).max(1);
            return want.clamp(base, hi);
        }

        // Streaming preview — FIXED-height, internally-scrolled slot (the real
        // cure). The reserved slot is a constant STREAM_PREVIEW_ROWS, quantized
        // upward in whole steps for a long reply, so the inline-viewport height
        // is stable for the whole turn: growing it per token rebuilt the viewport
        // mid-turn → a DSR cursor re-anchor tmux/SSH can drop → stacked chrome.
        let content_h = self.chat.desired_height(size.cols);
        let streaming = content_h > 1;
        if !streaming {
            // Not streaming ⇒ no turn's worth of growth to remember. Releasing the
            // high-water mark HERE (rather than from a handler) means every path
            // that ends a turn — completion, interrupt, cancel, disconnect — is
            // covered by construction: none of them can leave the next turn's
            // preview pre-grown.
            self.stream_preview_hw.set(0);
            return base;
        }
        // Quantized, monotonic growth of the preview slot (see
        // `stream_preview_rows`). The high-water mark is what makes it monotonic
        // for the turn: without it a reply whose rendered height dips would shrink
        // the slot back, and the shrink/grow pair is exactly the mid-turn viewport
        // churn that stacks chrome.
        let preview_rows = stream_preview_rows(
            content_h,
            self.stream_preview_hw.get(),
            stream_preview_ceiling(term_rows),
        );
        self.stream_preview_hw.set(preview_rows);
        // Every band that consumes stream rows is counted in BOTH `base` and
        // `want`. Omitting one from `want` is a real bug that shipped: whenever
        // `want > base` the clamp returns `want`, so a band counted only in
        // `base` silently vanished from the reservation while `draw_inline` still
        // carved it out — the plan block sitting where the rest of the reply
        // should have been. Taking every number from ONE `measure_bands` call is
        // what makes the omission unwritable.
        let overhead: u16 = b.think + b.hint + b.status;
        let hi = term_rows.saturating_sub(1).max(1);
        streaming_inline_height(
            base,
            overhead,
            input_needed,
            b.agents,
            b.checklist.saturating_add(b.survey).saturating_add(b.toast),
            b.popup,
            preview_rows,
            hi,
        )
    }

    /// **Measure every live-region band, once, for this frame.**
    ///
    /// The single source of truth for BOTH the viewport height
    /// ([`Self::desired_inline_height`]) and the layout ([`Self::draw_inline`]).
    ///
    /// This function replaced five near-identical `*_slot()` methods plus a
    /// `think_row_height()`, each of which had to be called from two places and
    /// kept in agreement by hand. The source comments on those methods are a
    /// record of the agreement failing: "must MATCH `desired_inline_height`'s
    /// reservation expression exactly", "a disagreement here is not cosmetic",
    /// "the bug that shipped was ONE rect handed to TWO components". With one
    /// measurement feeding both consumers, a disagreement is not expressible.
    ///
    /// Every height comes from the component itself, through
    /// [`crate::components::measure::Measured`]; what stays here is only the
    /// *app-level gating* a component cannot know — which bands stand down while
    /// a blocking ask owns the region, and which display mode the a11y setting
    /// selects.
    ///
    /// The result is [`Bands::capped`]: these are the rows each band may claim on
    /// an arbitrarily tall terminal. Fitting them into a real one is
    /// [`fit_bands`]'s job, and only [`fit_bands`]'s job.
    pub(crate) fn measure_bands(&self, size: FrameSize) -> Bands {
        let w = size.cols;
        // An inline permission prompt or plan-review panel takes over the stream
        // band while pending. The informational bands stand down: two blocking
        // asks are never stacked, and the panel needs the rows.
        let blocking_ask = self.permissions.is_some() || self.plan_review.is_some();

        // The checklist owns a real band. It used to be drawn as an OVERLAY into
        // the stream band's own rect — the same rect the reply had already
        // painted into — so a plan and a streaming markdown table interleaved.
        let checklist = if self.task_checklist_hidden
            || blocking_ask
            || !self.task_checklist.is_visible()
        {
            0
        } else {
            self.task_checklist.desired_height(w)
        };

        // Inline `ask_user` question band — a REAL band, never an overlay, for
        // exactly the reason above.
        let survey = match self.survey {
            Some(ref s) if !blocking_ask => s.desired_height(w),
            _ => 0,
        };

        // NOTE the `a11y` predicate: the boxed thinking display is skipped for
        // screen readers in favour of the activity's 1-row plain-text line.
        // Measuring with a DIFFERENT predicate than the draw reserved the box's
        // 12 rows and painted 1, leaving 11 dead rows above the composer.
        let think = if !self.thinking_box.is_empty() && !self.activity.a11y() {
            self.thinking_box.desired_height(w)
        } else if self.activity.height() > 0 {
            self.activity.desired_height(w)
        } else {
            0
        };

        Bands {
            toast: self.toasts.desired_height(w),
            checklist,
            think,
            agents: self.agents.desired_height(w),
            survey,
            popup: self.input.popup_desired_height(),
            input: self.input.desired_height(w),
            ..Bands::default()
        }
        .capped()
    }


    /// Draw the compact inline live region: streaming preview, thinking/activity,
    /// status, and input. Finalized conversation lives in native scrollback.
    fn draw_inline(&self, frame: &mut Frame, area: Rect) {
        // **Heights compute, Rects derive.** One measurement, arbitrated once
        // into what actually fits, then split into rects. `draw_inline` used to
        // re-derive all six band heights here with its own copy of the floor
        // expressions ("must MATCH `desired_inline_height`'s reservation exactly"
        // appears five times in the deleted code); every band that ever painted
        // where nothing had reserved was one of those copies drifting.
        //
        // Nothing below may compute a height. It may only read a rect.
        let bands = fit_bands(self.measure_bands(self.frame_size()), area.height);
        let rows = inline_split(area, bands);

        // Wipe the whole inline region first so no stale rows from a previous,
        // differently-sized frame bleed through (belt-and-braces against the
        // duplicated/overlapping banners the user saw after a resize).
        let bounds = frame.area();
        frame.render_widget(ratatui::widgets::Clear, bounds);

        // Bounds-check every live-region rect against the frame's real drawable
        // area before handing it to a component. The layout is derived from
        // `area`, but a lagged resize or an under-reported inline viewport can
        // leave a row partly outside the frame buffer; clamping keeps each
        // component's internal `render_widget` calls inside the buffer.
        let a_toast = clamp_to_frame(frame, rows[ROW_TOAST]);
        let a_stream = clamp_to_frame(frame, rows[ROW_STREAM]);
        let a_checklist = clamp_to_frame(frame, rows[ROW_CHECKLIST]);
        let a_think = clamp_to_frame(frame, rows[ROW_THINK]);
        let a_agents = clamp_to_frame(frame, rows[ROW_AGENTS]);
        let a_survey = clamp_to_frame(frame, rows[ROW_SURVEY]);
        let a_hint = clamp_to_frame(frame, rows[ROW_HINT]);
        let a_popup = clamp_to_frame(frame, rows[ROW_POPUP]);
        let a_input = clamp_to_frame(frame, rows[ROW_INPUT]);
        let a_status = clamp_to_frame(frame, rows[ROW_STATUS]);

        if let Some(ref perm) = self.permissions {
            // Inline approval prompt takes over the stream band while pending.
            perm.draw_inline(frame, a_stream);
        } else if let Some(ref review) = self.plan_review {
            // Plan-review panel renders inline in the stream band (no longer a
            // full-viewport is_overlay() state — see state.rs). Its fixed height is
            // reserved by desired_inline_height's plan_review branch.
            review.draw(frame, a_stream);
        } else {
            self.chat.draw_live(frame, a_stream);
        }
        // In screen-reader mode the boxed thinking display is skipped in favor of
        // the activity's plain-text status line (screen readers choke on the box).
        if !self.thinking_box.is_empty() && !self.activity.a11y() {
            self.thinking_box.draw(frame, a_think);
        } else {
            // Bottom-anchor the activity INSIDE its reserved slot. The slot is sized
            // to the verbosity ceiling (stable, so the viewport never rebuilds
            // mid-turn), but the live feed is usually shorter — and `Activity::draw`
            // paints its accent rail across the FULL rect it is handed. Passing the
            // whole slot therefore trailed bare `┃` rail glyphs down every empty row
            // between the spinner and the composer. Handing it exactly the content
            // rows, anchored to the bottom, keeps the spinner tight above the
            // composer and leaves any slack above it as plain padding.
            self.activity.draw(frame, bottom_anchored(a_think, self.activity.height()));
        }
        // Multi-agent activity + background-terminals summary (no-ops when empty).
        // Same treatment: the slot is a stable cap, the roster paints only its rows.
        self.agents.draw(frame, bottom_anchored(a_agents, self.agents.height()));
        self.draw_context_hint(frame, a_hint);
        self.input.draw(frame, a_input);
        // `/` popup or `@` dropdown, in the band reserved by `popup_slot` — never
        // painted over the hint row / stream band from inside the composer's own
        // draw, which is what both used to do.
        if a_popup.height > 0 {
            self.input.draw_popup(frame, a_popup);
        }
        self.status.draw(frame, a_status);
        // Live task checklist (Claude Code's todo panel), drawn into the band
        // reserved for it above the activity row — NEVER into `a_stream`, which
        // the reply owns. `checklist_h` is already `height()`-derived, so the
        // component fills its band exactly; it still clamps internally.
        if a_checklist.height > 0 {
            self.task_checklist.draw(frame, a_checklist);
        }
        // Inline `ask_user` question band, in the rows reserved by `survey_slot`
        // — again NEVER `a_stream`. The conversation above stays visible and
        // scrollable while the operator answers, and the composer keeps its rows.
        if a_survey.height > 0 {
            if let Some(ref survey) = self.survey {
                survey.draw_inline(frame, a_survey);
            }
        }
        // Ephemeral notifications, in the band reserved by `toast_slot` — never
        // an overlay over `a_stream`. The band is full-width; `toast_window`
        // keeps the historical right-hand 40-column placement.
        if a_toast.height > 0 {
            self.toasts.draw(frame, toast_window(a_toast).intersection(bounds));
        }
    }

    /// Right-aligned notice row just above the input box's top divider (mirrors
    /// Claude Code's notification row above the prompt): the backend reconnect
    /// state, or the actionable low-context warning. The PASSIVE context readout
    /// is not drawn here — it is stated once, on the status bar, so the two can
    /// never disagree (see the note at the end of this function).
    fn draw_context_hint(&self, frame: &mut Frame, area: Rect) {
        if area.height == 0 {
            return;
        }
        // Keep a 1-column gutter on each side so right-aligned notices
        // ("Reconnecting to backend…", "Context low…", "N% context used") never
        // touch — and clip against — the terminal's far edge (CC parity).
        let area = Rect {
            x: area.x.saturating_add(1),
            width: area.width.saturating_sub(2),
            ..area
        };
        if area.width == 0 {
            return;
        }
        // WS13 — surface the SSE reconnect state (previously a dead flag):
        // while the event stream is down and being re-established, this row
        // shows a reconnect notice instead of the passive context hint.
        if self.sse_reconnecting {
            let para = ratatui::widgets::Paragraph::new(ratatui::text::Line::from(
                ratatui::text::Span::styled(
                    "Reconnecting to backend\u{2026}",
                    ratatui::style::Style::default()
                        .fg(crate::style::theme().colors.warning)
                        .add_modifier(ratatui::style::Modifier::BOLD),
                ),
            ))
            .alignment(ratatui::layout::Alignment::Right);
            frame.render_widget(para, area);
            return;
        }
        // WS12 — CC TokenWarning parity: once the backend's context_pressure
        // report crosses the low threshold, the passive "N% context used" hint
        // becomes an explicit red warning showing the % LEFT until auto-compact
        // and the action to take.
        if self.status.context_low() {
            // Suppress the misleading "0% remaining" when the backend flagged
            // context_low but sent no percent_left (phantom-zero, budget-chip
            // class): show the warning without a fabricated number.
            let text = match self.status.percent_left() {
                Some(left) => format!(
                    "Context low ({}% remaining) \u{00b7} Run /compact to compact & continue",
                    left
                ),
                None => {
                    "Context low \u{00b7} Run /compact to compact & continue".to_string()
                }
            };
            let para = ratatui::widgets::Paragraph::new(ratatui::text::Line::from(
                ratatui::text::Span::styled(
                    text,
                    ratatui::style::Style::default()
                        .fg(crate::style::theme().colors.error)
                        .add_modifier(ratatui::style::Modifier::BOLD),
                ),
            ))
            .alignment(ratatui::layout::Alignment::Right);
            frame.render_widget(para, area);
            return;
        }
        // ONE context indicator. The passive "N% context used" readout used to be
        // drawn here as well as on the status bar, from the same `StatusBar` —
        // but through a DIFFERENT expression of it: this row printed
        // `context_utilization()` as a raw percentage, while the status bar was
        // taught that an unknown context window (`context_max == 0`) has no
        // honest denominator and must render the token count instead. With the
        // window unknown, `context_utilization()` is exactly 0.0, so the screen
        // carried "0% context used" down here and "~53.3k ctx" up there — two
        // indicators disagreeing about the same fact, one of them fabricated.
        //
        // Rather than teach a second widget the same unknown-window rule and
        // leave two numbers that can drift apart again, the passive readout is
        // now stated once, on the status bar. This row keeps only what the status
        // bar cannot say: the reconnect notice and the actionable low-context
        // warning, both handled above.
    }
}

/// Enter the alternate screen and rebuild the terminal at full height. Used for
/// dialogs, onboarding, connecting, and the file picker.
fn switch_to_full(terminal: &mut Term) -> Result<()> {
    execute!(std::io::stdout(), EnterAlternateScreen)?;
    crate::app::alt_screen::mark_entered();
    *terminal = Terminal::new(CrosstermBackend::new(std::io::stdout()))?;
    terminal.clear()?; // fresh diff state after rebuild
    Ok(())
}

/// Whether a remembered inline-viewport top row is still safe to clear from
/// on the current terminal. `top` is captured BEFORE a full/alternate-screen
/// excursion; if the terminal shrank (or was resized to something tiny) while
/// a dialog owned the screen, the row may no longer exist. Kept as a free,
/// pure function so the boundary logic is unit-testable without a real
/// terminal (see `render_tests::clamp_inline_top_*`).
fn clamp_inline_top(top: Option<u16>, term_rows: u16) -> Option<u16> {
    top.filter(|&t| t < term_rows)
}

/// Absolute terminal row to start clearing from when erasing the OLD inline
/// chrome before a resize rebuild, given the terminal's ACTUAL current cursor
/// row (queried fresh via DSR after the resize, i.e. where the emulator left it
/// inside the reflowed old region) and the height the old inline region had
/// (`prev_inline_h`).
///
/// The old inline chrome occupies at most `prev_inline_h` rows ending at (or
/// just above) the cursor — the composer parks the terminal's text cursor on its
/// own row near the bottom of the region — so clearing from `cursor -
/// (prev_inline_h - 1)` downward wipes exactly the old region and nothing above
/// it (the transcript scrollback the user wants to keep). Saturating so a cursor
/// high on the screen can never underflow past row 0.
///
/// Kept as a free, pure function so the anchor arithmetic is unit-testable
/// without a real terminal (see `render_tests::resize_clear_top_*`).
/// Absolute top row of the bottom-anchored inline live region, given the
/// terminal's CURRENT height (`term_rows`) and the region's height (`inline_h`).
///
/// The inline chrome (composer + status bar) is pinned to the bottom `inline_h`
/// rows of the screen — the bottom-anchored model asserted directly in the
/// resize tests (`old_top = old_rows - old_h`). So the region's first row is
/// `term_rows - inline_h`, and clearing from there downward erases exactly the
/// old chrome and nothing above it.
///
/// `term_rows` comes from `crossterm::terminal::size()` (an ioctl reflecting the
/// just-applied resize), NOT a DSR cursor round-trip — which tmux and some
/// emulators drop or answer with a stale row during a resize burst, the failure
/// that stranded a duplicate composer on screen. Saturating so a region briefly
/// taller than the terminal (mid-shrink) clamps to row 0 instead of underflowing
/// to a huge row that would move the clear off-screen.
///
/// No longer used by the resize path (which now does a DSR-free full-screen wipe,
/// the only approach robust to terminals that drop the cursor query), but retained
/// as a tested pure helper documenting the bottom-anchored geometry.
#[cfg(test)]
fn resize_clear_top_from_bottom(term_rows: u16, inline_h: u16) -> u16 {
    term_rows.saturating_sub(inline_h)
}

/// Leave the alternate screen and rebuild the inline viewport, restoring the
/// host terminal's scrollback untouched.
///
/// `prev_inline_top` is the top row of the inline chrome as it stood the last
/// time we were inline (captured by the caller right before entering the
/// alternate screen). Ratatui's `Viewport::Inline` reconstruction anchors the
/// new region wherever the cursor is queried back to be — which, after
/// `LeaveAlternateScreen` restores the primary-screen cursor, is wherever the
/// LAST inline draw physically left it (typically the composer's own text
/// cursor, partway through the old chrome), not the top of the old region.
/// Left alone, that strands the rows of the old chrome ABOVE that point still
/// on screen while a fresh copy is drawn below/at it — the "two chat things"
/// duplicate. Explicitly homing the cursor to the remembered top and clearing
/// downward before rebuilding erases exactly the old chrome (never the real
/// transcript scrollback above `prev_inline_top`, which this never touches)
/// so the freshly built viewport lands in the same place the old one started.
fn switch_to_inline(
    terminal: &mut Term,
    inline_h: u16,
    prev_inline_top: Option<u16>,
    size: FrameSize,
) -> Result<()> {
    execute!(std::io::stdout(), LeaveAlternateScreen)?;
    crate::app::alt_screen::mark_left();

    // Viewport::Inline queries the cursor (DSR); the first query after leaving the
    // alt screen can be dropped and time out ("cursor position could not be read"),
    // which would crash the session on every dialog close. Prime it, then retry the
    // rebuild instead of aborting.
    for _ in 0..40 {
        if crossterm::cursor::position().is_ok() {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(25));
    }

    // Erase the old inline chrome before rebuilding. `size` is THIS frame's
    // size — sampled once at the top of the run loop, and already re-adopted if
    // a resize landed while the dialog owned the screen — so the remembered top
    // row is re-validated against the terminal as it stands now rather than
    // trusted blindly. It used to be a second, independent
    // `crossterm::terminal::size()` here; see `app::frame_size`.
    let term_rows = size.rows;
    if let Some(top) = clamp_inline_top(prev_inline_top, term_rows) {
        let _ = execute!(
            std::io::stdout(),
            crossterm::cursor::MoveTo(0, top),
            crossterm::terminal::Clear(crossterm::terminal::ClearType::FromCursorDown),
        );
    }

    let mut last_err = None;
    for attempt in 0..6u64 {
        match Terminal::with_options(
            CrosstermBackend::new(std::io::stdout()),
            TerminalOptions {
                viewport: Viewport::Inline(inline_h),
            },
        ) {
            Ok(t) => {
                *terminal = t;
                return Ok(());
            }
            Err(e) => {
                last_err = Some(e);
                std::thread::sleep(std::time::Duration::from_millis(40 * (attempt + 1)));
            }
        }
    }
    // Every DSR query was dropped. Rather than bubble a "cursor position could
    // not be read" error up to the user (which aborts the whole session on a
    // dialog close), degrade to a full-screen terminal — `Terminal::new` never
    // queries the cursor, so it can't fail. The viewport reconciliation will
    // recover the inline region on a later iteration if the terminal recovers.
    info!("inline rebuild failed ({:?}); degrading to full-screen", last_err);
    *terminal = Terminal::new(CrosstermBackend::new(std::io::stdout()))?;
    let _ = terminal.clear();
    Ok(())
}

/// Rebuild the inline viewport at a new height *without* leaving/entering the
/// alt screen (we're already inline). Used when the live region grows/shrinks or
/// the terminal is resized. Like [`switch_to_inline`] it primes the cursor query
/// (DSR) and retries, since the query can be dropped intermittently. The caller
/// must have paused the terminal event reader first (shared stdin) and should
/// `terminal.clear()` beforehand so no stale rows of the old-sized region remain.
fn rebuild_inline(terminal: &mut Term, inline_h: u16) -> Result<()> {
    for _ in 0..40 {
        if crossterm::cursor::position().is_ok() {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(25));
    }
    let mut last_err = None;
    for attempt in 0..6u64 {
        match Terminal::with_options(
            CrosstermBackend::new(std::io::stdout()),
            TerminalOptions {
                viewport: Viewport::Inline(inline_h),
            },
        ) {
            Ok(t) => {
                *terminal = t;
                return Ok(());
            }
            Err(e) => {
                last_err = Some(e);
                std::thread::sleep(std::time::Duration::from_millis(40 * (attempt + 1)));
            }
        }
    }
    // As in `switch_to_inline`: never surface the DSR timeout to the user. If the
    // cursor query keeps failing, fall back to a full-screen terminal (which does
    // not query the cursor) so the live-region resize can't crash the session.
    info!("inline height rebuild failed ({:?}); degrading to full-screen", last_err);
    *terminal = Terminal::new(CrosstermBackend::new(std::io::stdout()))?;
    let _ = terminal.clear();
    Ok(())
}

/// Purge the terminal's REAL scrollback (`/clear`). In inline mode every
/// finalized message was flushed into the host terminal's native scrollback
/// via `insert_before` (step 2 of the run loop) — it never lived in a ratatui
/// buffer, so `terminal.clear()` (which only resets ratatui's own diff state
/// and the live viewport region) cannot touch it, and neither can wiping
/// `self.chat` / `self.transcript_log`.
///
/// Order matters, and it is the opposite of the obvious one. The visible screen
/// is erased FIRST, with ED0-from-home (`ESC[H` + `ESC[J`) rather than ED2
/// (`ESC[2J`): on the VTE family ED2 scrolls the screen into scrollback instead
/// of erasing it, so the old `Purge`-then-`All` sequence emptied the scroll
/// history and then immediately pushed one final screenful back into it — a
/// `/clear` that visibly left the last screen scrollable. ED0 erases in place on
/// every emulator, so nothing is deposited.
///
/// `ClearType::Purge` (`ESC[3J`, erase saved lines) then drops the real scroll
/// history. It is supported by every xterm-compatible terminal in mainstream
/// use; emulators without it simply ignore the private sequence and only the
/// visible screen clears, which is still a correct, if smaller, clear.
///
/// Homing the cursor to (0, 0) means the caller's following `Viewport::Inline`
/// rebuild anchors fresh at the very top instead of wherever the old composer
/// happened to leave the cursor.
fn purge_scrollback() -> Result<()> {
    purge_scrollback_into(&mut std::io::stdout())
}

/// [`purge_scrollback`] against an arbitrary sink, so the byte sequence itself is
/// assertable in tests.
pub(crate) fn purge_scrollback_into(out: &mut impl std::io::Write) -> Result<()> {
    execute!(
        out,
        crossterm::cursor::MoveTo(0, 0),
        crossterm::terminal::Clear(crossterm::terminal::ClearType::FromCursorDown),
        crossterm::terminal::Clear(crossterm::terminal::ClearType::Purge),
        crossterm::cursor::MoveTo(0, 0),
    )?;
    Ok(())
}

/// Erase the whole visible screen for a REAL terminal resize, without depositing
/// a copy of it in the terminal's scroll history.
///
/// This is the one clear in the inline path that has to be unanchored: an actual
/// resize reflows the emulator's screen, so the old chrome's row is genuinely
/// unknowable and no surgical `FromCursorDown` from a remembered top can find
/// it. Homing first and erasing forward covers the same ground as a full-screen
/// clear while staying an ERASE.
///
/// It must never become `ClearType::All` (`ESC[2J`). ED2 looks identical but is
/// not an erase on the VTE family (GNOME Terminal and every other libvte
/// embedder), which implements it by scrolling the screen into scrollback — one
/// permanent, unreflowable snapshot of the live region per resize step. See
/// `resize_clear_erases_in_place_and_never_scrolls_into_history`.
pub(crate) fn clear_screen_for_resize(out: &mut impl std::io::Write) -> Result<()> {
    execute!(
        out,
        crossterm::cursor::MoveTo(0, 0),
        crossterm::terminal::Clear(crossterm::terminal::ClearType::FromCursorDown),
    )?;
    Ok(())
}

/// True when this process is running inside a terminal multiplexer.
///
/// `$TMUX` is set for every process in a tmux pane; the `tmux`/`screen` TERM
/// prefixes cover a scrubbed environment and GNU screen, which shares the
/// properties that matter here — its own screen model and no reflow on a
/// width change.
pub(crate) fn in_multiplexer() -> bool {
    if std::env::var_os("TMUX").is_some() {
        return true;
    }
    match std::env::var("TERM") {
        Ok(t) => t.starts_with("tmux") || t.starts_with("screen"),
        Err(_) => false,
    }
}

/// True when `key` is Ctrl+O (the transcript-viewer toggle). Delegates to the
/// single key-normalization layer so terminal-modifier quirks are decided in one
/// place.
fn is_ctrl_o(key: &KeyEvent) -> bool {
    crate::app::key_normalize::is_ctrl_o(key)
}

/// The right-hand 40-column window of an already-reserved toast band.
///
/// Only the horizontal placement — the HEIGHT comes from the band, which the
/// layout reserved (`App::toast_slot` → `ROW_TOAST`). It used to also invent a
/// 3-row height at `area.y`, which is how toasts came to be painted over the top
/// of the streaming reply.
pub(crate) fn toast_window(band: Rect) -> Rect {
    Rect::new(
        band.x + band.width.saturating_sub(40),
        band.y,
        40.min(band.width),
        band.height,
    )
}

/// Top-right toast rectangle for the FULL-VIEWPORT (dialog) surfaces.
///
/// Here an overlay is genuinely correct: a dialog owns the whole screen, is
/// repainted in full every frame, and has no live region to budget. The overlay
/// is BOUNDED to the rows it actually writes (one per live toast, ≤
/// [`TOAST_INLINE_CAP`]) rather than a blanket 3, and because the dialog redraws
/// beneath it every frame the covered content returns the moment the toast
/// expires. The inline live region does NOT use this — it has a reserved band.
fn toast_rect(area: Rect, live: u16) -> Rect {
    Rect::new(
        area.x + area.width.saturating_sub(40),
        area.y,
        40.min(area.width),
        live.min(TOAST_INLINE_CAP).min(area.height),
    )
}

// ---------------------------------------------------------------------------
// Render-hardening tests
//
// A ratatui panic ("index outside of buffer") crashed the whole TUI when a
// widget wrote outside its frame buffer — the task-checklist overlay computed a
// panel that could land above the live region. These tests render the
// crash-prone components and the live-region layout across a wide range of
// terminal sizes and states, asserting that `draw` never panics. They exercise
// the component `draw` fns directly against a `TestBackend` frame — no App, no
// network — so a regression that writes out of bounds fails the test instead of
// crashing a user's session.
// ---------------------------------------------------------------------------
#[cfg(test)]
mod render_tests {
    use super::{
        clamp_to_frame, inline_split, safe_render_widget, Bands, ROW_INPUT, ROW_POPUP, ROW_STATUS,
    };
    use ratatui::backend::Backend;
    use ratatui::backend::TestBackend;
    use ratatui::layout::{Constraint, Direction, Layout as RLayout, Rect};
    use ratatui::Frame;
    use ratatui::widgets::{Block, Borders, Paragraph};
    use ratatui::Terminal;

    // `Activity::draw` and `InputComponent::draw` are `Component` trait methods.
    use crate::components::activity::{Activity, ProcessingPhase};
    use crate::components::agents::Agents;
    use crate::components::input::InputComponent;
    use crate::components::task_checklist::{ChecklistStatus, TaskChecklist};
    use crate::components::Component;

    /// The terminal sizes every case is exercised at, from absurdly tiny to large.
    const SIZES: &[(u16, u16)] = &[
        (10, 3),
        (20, 5),
        (40, 10),
        (80, 24),
        (120, 40),
        (200, 60),
    ];

    /// Run `f` inside a `TestBackend` draw at every size. Any panic in `f`
    /// (including a ratatui out-of-buffer index) fails the test.
    fn for_each_size(mut f: impl FnMut(&mut ratatui::Frame<'_>, Rect)) {
        for &(w, h) in SIZES {
            let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
            term.draw(|frame| {
                let area = frame.area();
                f(frame, area);
            })
            .unwrap();
        }
    }

    /// Build a checklist with `n` items in a mix of statuses, including a
    /// multi-byte subject to guard the truncation path.
    fn checklist_with(n: usize) -> TaskChecklist {
        let mut cl = TaskChecklist::new();
        for i in 0..n {
            cl.add(
                format!("task-{i}"),
                format!("Refactor the ünîcode module and wire up subsystem number {i} end-to-end"),
                Some(format!("refactoring subsystem {i}")),
            );
        }
        // Spread statuses so every icon/style branch renders.
        for i in 0..n {
            let status = match i % 4 {
                0 => ChecklistStatus::Completed,
                1 => ChecklistStatus::InProgress,
                2 => ChecklistStatus::Pending,
                _ => ChecklistStatus::Failed,
            };
            cl.update(&format!("task-{i}"), status);
        }
        cl
    }

    /// Mirror `App::draw_inline`'s vertical split so the checklist is exercised
    /// through the exact bottom-anchored, self-positioning path that crashed.
    fn split_live_region(area: Rect, think_h: u16, input_h: u16) -> std::rc::Rc<[Rect]> {
        RLayout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Min(1),
                Constraint::Length(think_h),
                Constraint::Length(1),
                Constraint::Length(input_h),
                Constraint::Length(2),
            ])
            .split(area)
    }

    #[test]
    fn safe_render_widget_skips_out_of_bounds_rects() {
        // Oversized, negatively-offset-equivalent, and zero rects must all be
        // clipped to the frame instead of panicking.
        for_each_size(|frame, area| {
            let oversized = Rect::new(0, 0, area.width + 100, area.height + 100);
            safe_render_widget(frame, Block::default().borders(Borders::ALL), oversized);

            let below = Rect::new(0, area.height.saturating_sub(1), area.width, 50);
            safe_render_widget(frame, Paragraph::new("way too tall"), below);

            let right = Rect::new(area.width.saturating_sub(1), 0, 50, area.height);
            safe_render_widget(frame, Paragraph::new("way too wide"), right);

            let zero = Rect::new(area.width, area.height, 0, 0);
            safe_render_widget(frame, Paragraph::new("nothing"), zero);

            // clamp_to_frame never returns a rect outside the frame.
            let clamped = clamp_to_frame(frame, oversized);
            assert!(clamped.right() <= area.right());
            assert!(clamped.bottom() <= area.bottom());
        });
    }

    #[test]
    fn task_checklist_full_frame_never_panics() {
        for n in [0usize, 1, 5, 15, 40] {
            let cl = checklist_with(n);
            for_each_size(|frame, area| cl.draw(frame, area));
        }
    }

    #[test]
    fn task_checklist_live_region_split_never_panics() {
        // The original crash: the bottom-anchored overlay, given the small
        // streaming row, computed a fixed-height panel that spilled above the
        // inline viewport. Drive that exact path with a heavy 15-item list.
        for n in [0usize, 3, 15, 30] {
            let cl = checklist_with(n);
            for think_h in [0u16, 1] {
                for input_h in [1u16, 3, 6, 11] {
                    for_each_size(|frame, area| {
                        let rows = split_live_region(area, think_h, input_h);
                        // Checklist floats over the streaming region (rows[0]).
                        cl.draw(frame, rows[0]);
                    });
                }
            }
        }
    }

    #[test]
    fn task_checklist_misplaced_oversized_area_never_panics() {
        // Adversarial: hand the overlay areas that themselves extend past the
        // frame (simulating a lagged resize / under-reported viewport). It must
        // clamp internally and degrade gracefully, never write out of bounds.
        let cl = checklist_with(15);
        for_each_size(|frame, area| {
            let bogus = [
                Rect::new(0, area.height.saturating_sub(2), area.width, 30),
                Rect::new(0, 0, area.width + 50, area.height + 50),
                Rect::new(
                    area.width.saturating_sub(5),
                    area.height.saturating_sub(5),
                    40,
                    20,
                ),
                Rect::new(0, area.height, area.width, 20),
            ];
            for b in bogus {
                cl.draw(frame, b);
            }
        });
    }

    #[test]
    fn activity_never_panics() {
        for a11y in [false, true] {
            let mut act = Activity::new();
            act.set_a11y(a11y);
            act.start();
            act.set_model_name("test-model");
            act.set_phase(ProcessingPhase::ToolCall);
            act.set_active_verb(Some("orchestrating".to_string()));
            for i in 0..12 {
                act.tool_start(if i % 2 == 0 { "Bash" } else { "Read" }, "some args");
                act.tool_end("Bash", 42, i % 3 != 0);
            }
            act.set_tokens(1234, 5678);
            act.add_stream_chars(9000);
            for_each_size(|frame, area| {
                // Activity draws within whatever single-ish row it's given.
                let row = Rect::new(area.x, area.y, area.width, area.height.min(6));
                act.draw(frame, row);
            });
        }
    }

    #[test]
    fn input_never_panics() {
        let contents = [
            "",
            "short",
            "a line that is long enough to wrap across narrow terminals repeatedly and then some more",
            "line one\nline two\nline three\nline four\nline five\nline six\nline seven",
            "ünîcode ✓ ○ ✗ mixed with ascii and a trailing …",
        ];
        for content in contents {
            for &(w, _h) in SIZES {
                let mut input = InputComponent::new();
                input.set_width(w);
                input.set_content(content);
                for_each_size(|frame, area| {
                    let needed = input.needed_height().min(area.height);
                    let row = Rect::new(area.x, area.y, area.width, needed);
                    input.draw(frame, row);
                });
            }
        }
    }

    // ── Reproduction: the slash-completions popup out-of-buffer crash ────────
    //
    // The real crash (`index outside of buffer: the area is Rect { x: 0, y: 13,
    // width: 92, height: 8 } but index is (0, 9)`) only manifests when the frame
    // buffer's area starts at y > 0 — a genuine inline viewport parked partway
    // down the terminal. Under a plain `TestBackend` the frame starts at y=0, so
    // the popup's `saturating_sub` floored to 0 and the panic never reproduced.
    // Here we build a *real* `Inline` viewport whose top sits at `top` and render
    // the exact live chrome (input + open slash popup + status bar) through the
    // same clamped layout as `App::draw_inline`.
    use crate::components::status_bar::StatusBar;
    use crossterm::event::{Event as CrosstermEvent, KeyCode, KeyEvent, KeyModifiers};
    use ratatui::layout::Position;
    use ratatui::{TerminalOptions, Viewport};

    fn sample_commands() -> Vec<(String, String)> {
        [
            ("help", "Show all commands"),
            ("compact", "Compact the conversation to free context"),
            ("continue", "Continue earlier work in this folder"),
            ("resume", "Browse and resume a past session"),
            ("model", "Switch the active model"),
            ("clear", "Clear the screen"),
            ("steer", "Redirect the current turn mid-flight"),
            ("goal", "Set an auto-continue goal loop"),
            ("permissions", "Edit tool permissions"),
            ("quit", "Exit OSA"),
        ]
        .iter()
        .map(|(a, b)| (a.to_string(), b.to_string()))
        .collect()
    }

    /// Press a single character key into the input.
    fn press(input: &mut InputComponent, ch: char) {
        let ev = crate::event::Event::Terminal(CrosstermEvent::Key(KeyEvent::new(
            KeyCode::Char(ch),
            KeyModifiers::NONE,
        )));
        input.handle_event(&ev);
    }

    /// An input with the slash-completions popup open (content "/…").
    fn input_with_slash_popup(w: u16) -> InputComponent {
        let mut input = InputComponent::new();
        input.set_width(w);
        input.set_commands_with_descriptions(sample_commands());
        press(&mut input, '/'); // opens the completions popup (all items match "")
        input
    }

    /// Mirror `App::draw_inline`'s clamped vertical split, rendering the input
    /// (with its popup) and the status bar — the crash-prone live chrome.
    fn draw_inline_chrome(frame: &mut Frame, input: &InputComponent, status: &StatusBar) {
        let area = frame.area();
        let think_h = 1u16;
        // The composer-anchored popups draw into their OWN reserved band
        // (`ROW_POPUP`) — never over the composer's neighbours — so the mirror
        // uses the REAL `inline_split` rather than a hand-rolled copy of it.
        let popup_want = input
            .completions_popup_height()
            .max(input.mention_popup_height());
        // Size the composer against the popup the ARBITER granted, not the one
        // it asked for: on a short viewport those differ, and sizing against
        // the request is how a band ends up claiming rows nothing reserved.
        let popup_h = super::fit_bands(
            Bands {
                think: think_h,
                popup: popup_want,
                input: super::INPUT_FLOOR,
                ..Default::default()
            },
            area.height,
        )
        .popup;
        let overhead = think_h + popup_h + 1 + 2;
        let input_h = input
            .needed_height()
            .min(area.height.saturating_sub(overhead + 1))
            .max(1);
        let rows = inline_split(
            area,
            super::fit_bands(
                Bands {
                    think: think_h,
                    popup: popup_h,
                    input: input_h,
                    ..Default::default()
                },
                area.height,
            ),
        );
        input.draw(frame, clamp_to_frame(frame, rows[ROW_INPUT]));
        input.draw_popup(frame, clamp_to_frame(frame, rows[ROW_POPUP]));
        status.draw(frame, clamp_to_frame(frame, rows[ROW_STATUS]));
    }

    /// Build a real `Inline` viewport whose top sits at `top` and render the
    /// live chrome into it. Any out-of-buffer write panics the test.
    fn render_inline(top: u16, w: u16, view_h: u16, input: &InputComponent, status: &StatusBar) {
        let total_h = top.saturating_add(view_h).saturating_add(4).max(1);
        let mut backend = TestBackend::new(w, total_h);
        backend.set_cursor_position(Position { x: 0, y: top }).unwrap();
        let mut term = Terminal::with_options(
            backend,
            TerminalOptions {
                viewport: Viewport::Inline(view_h),
            },
        )
        .unwrap();
        term.draw(|frame| draw_inline_chrome(frame, input, status))
            .unwrap();
    }

    #[test]
    fn inline_slash_popup_never_panics_at_offset() {
        // width 92 (the report) plus narrow panes; viewport heights from tiny to
        // huge; and the viewport parked at several y-offsets (0 never reproduced
        // the bug, 13 is the exact report geometry).
        for &(w, vh) in &[
            (92u16, 3u16),
            (92, 5),
            (92, 8),
            (92, 10),
            (92, 200),
            (40, 8),
            (20, 5),
            (10, 3),
            (1, 1),
        ] {
            for &top in &[0u16, 5, 13] {
                let input = input_with_slash_popup(w);
                let mut status = StatusBar::new();
                status.set_width(w);
                status.set_provider_info("openclaw", "glm-5.2:cloud");
                status.set_context(0.0, 0, 200_000);
                render_inline(top, w, vh, &input, &status);
            }
        }
    }

    #[test]
    fn inline_slash_popup_survives_resize() {
        // Mirror the app's real resize strategy: on a terminal size change it
        // rebuilds the inline viewport fresh at a height clamped to the new rows
        // (via `live_region_height`), then draws. This walks a sequence of sizes
        // — including a hard shrink and a grow — with the slash popup open. The
        // viewport is parked at a non-zero offset each time (the geometry that
        // reproduced the original crash).
        let sizes = [(92u16, 30u16), (50, 6), (120, 40), (40, 5), (200, 60), (10, 3)];
        for &(w, rows) in &sizes {
            let input = input_with_slash_popup(w);
            let mut status = StatusBar::new();
            status.set_width(w);
            status.set_provider_info("openclaw", "glm-5.2:cloud");
            let view_h = super::live_region_height(input.needed_height(), rows);
            // Park the viewport as low as it can sit for this terminal.
            let top = rows.saturating_sub(view_h);
            render_inline(top, w, view_h, &input, &status);
        }
    }

    #[test]
    fn resize_reflows_layout_wrap_widths() {
        // The transcript, composer, and status bar are all wrapped/sized off the
        // layout's chat width (and the terminal width for the status bar), so a
        // resize reflowing cleanly depends on those tracking the new terminal
        // dims. A width shrink must shrink the wrap width; a width grow must grow
        // it; a rows shrink must shrink the chat height. Round-tripping back to
        // the original size must reproduce the original layout exactly (converge
        // to the final size, no hysteresis).
        use crate::app::layout::Layout;
        let wide = Layout::compute(120, 40, false, 0, 0);
        let narrow = Layout::compute(60, 40, false, 0, 0);
        assert!(
            narrow.chat_width < wide.chat_width,
            "narrower terminal must yield a narrower wrap width: {} !< {}",
            narrow.chat_width,
            wide.chat_width,
        );
        let short = Layout::compute(120, 12, false, 0, 0);
        assert!(
            short.chat_height < wide.chat_height,
            "fewer rows must yield a shorter chat height: {} !< {}",
            short.chat_height,
            wide.chat_height,
        );
        let back = Layout::compute(120, 40, false, 0, 0);
        assert_eq!(back.chat_width, wide.chat_width, "width must converge on round-trip");
        assert_eq!(back.chat_height, wide.chat_height, "height must converge on round-trip");
    }

    #[test]
    fn resize_reflows_chat_wrap_and_drops_width_cache() {
        // The chat holds the width-keyed render caches (per-message wrapped
        // height + the live streaming markdown cache). A resize must reflow the
        // streaming reply to the new width — proving the width cache did NOT pin
        // the old geometry. This exercises the exact resize path update.rs runs:
        // recompute_layout -> Chat::set_size, then the explicit
        // invalidate_width_caches on a width change.
        use crate::components::chat::Chat;
        let mut chat = Chat::new();
        chat.update_streaming(
            "a fairly long streamed reply that will wrap to a different number of rows at different widths",
        );
        let h_wide = chat.streaming_height(120);
        chat.set_size(24, 10);
        chat.invalidate_width_caches();
        let h_narrow = chat.streaming_height(24);
        assert!(
            h_narrow > h_wide,
            "a narrower width must wrap the streaming reply to MORE rows (cache must not pin old width): {h_narrow} !> {h_wide}",
        );
    }

    #[test]
    fn inline_chrome_reflows_to_each_width_on_resize() {
        // Walk a resize sequence (wide -> narrow -> wide -> tiny) the way a
        // pane-drag does. At every step the inline chrome must render into a
        // buffer of EXACTLY the new width, with the composer/status re-laid-out
        // to fit — proof the live region reflows to the resized width instead of
        // keeping the old geometry (stale/misaligned rows). Also a panic guard
        // for the rebuilt-fresh-at-new-size resize path.
        for &w in &[120u16, 48, 90, 10, 200] {
            let mut input = InputComponent::new();
            input.set_width(w);
            input.set_content("summarize this long instruction that must wrap on narrow panes");
            let mut status = StatusBar::new();
            status.set_width(w);
            status.set_provider_info("openclaw", "glm-5.2:cloud");
            let view_h = super::live_region_height(input.needed_height(), 40);
            let total_h = view_h.saturating_add(4).max(1);
            let mut backend = TestBackend::new(w, total_h);
            backend.set_cursor_position(Position { x: 0, y: 0 }).unwrap();
            let mut term = Terminal::with_options(
                backend,
                TerminalOptions {
                    viewport: Viewport::Inline(view_h),
                },
            )
            .unwrap();
            term.draw(|frame| draw_inline_chrome(frame, &input, &status))
                .unwrap();
            assert_eq!(
                term.backend().buffer().area.width,
                w,
                "inline chrome must render at the resized width, not the old one",
            );
        }
    }

    #[test]
    fn inline_slash_popup_renders_real_commands() {
        // Regression for "/ shows no commands": with the popup open the inline
        // viewport must be grown by `completions_popup_height()` so the
        // upward-growing popup has room above the input and renders actual
        // command names, not just a \u{25bc} scroll arrow.
        let w = 92u16;
        let input = input_with_slash_popup(w);
        let mut status = StatusBar::new();
        status.set_width(w);
        status.set_provider_info("openclaw", "glm-5.2:cloud");
        status.set_context(0.0, 0, 200_000);

        // The popup wants rows now that it is open (all sample commands match "").
        let popup_h = input.completions_popup_height();
        assert!(popup_h >= 3, "open popup should want >= 3 rows, got {popup_h}");

        // Viewport height the event loop would build: live region + popup rows.
        let view_h = super::live_region_height(input.needed_height(), 40)
            .saturating_add(popup_h);
        let total_h = view_h + 4;

        let mut backend = TestBackend::new(w, total_h);
        backend.set_cursor_position(Position { x: 0, y: 0 }).unwrap();
        let mut term = Terminal::with_options(
            backend,
            TerminalOptions {
                viewport: Viewport::Inline(view_h),
            },
        )
        .unwrap();
        term.draw(|frame| draw_inline_chrome(frame, &input, &status))
            .unwrap();

        // The rendered buffer must contain at least one real command name from
        // the sample list — proof the popup shows commands, not an empty box or
        // a lone \u{25bc} arrow (the reported bug).
        let text: String = term
            .backend()
            .buffer()
            .content()
            .iter()
            .map(|c| c.symbol())
            .collect();
        assert!(
            sample_commands()
                .iter()
                .any(|(name, _)| text.contains(name.as_str())),
            "slash popup must render a real command name; buffer had none"
        );
    }

    // ── Bug 1 repro/fix: "two chat things" (duplicated composer+status) ──────
    //
    // Root cause: `Viewport::Inline` reconstruction (`Terminal::with_options`)
    // anchors the fresh region wherever the backend's cursor is queried to be
    // (ratatui's `compute_inline_size`), not at the top of whatever inline
    // chrome was on screen before. After `LeaveAlternateScreen` restores the
    // primary-screen cursor, that position is wherever the LAST inline draw
    // physically left it (the composer's own text-cursor row), which sits
    // INSIDE the old chrome, not above it. Rebuilding there without clearing
    // strands the old chrome's rows above the new viewport, still holding the
    // previous frame's rendered characters — the visible duplicate.
    use super::{clamp_inline_top, resize_clear_top_from_bottom};

    #[test]
    fn clamp_inline_top_accepts_row_within_current_terminal() {
        assert_eq!(clamp_inline_top(Some(5), 30), Some(5));
        assert_eq!(clamp_inline_top(Some(0), 30), Some(0));
    }

    #[test]
    fn clamp_inline_top_rejects_row_the_terminal_shrank_past() {
        // A resize while a dialog owned the screen can invalidate the
        // remembered row; using it anyway would move the cursor out of bounds.
        assert_eq!(clamp_inline_top(Some(25), 10), None);
        assert_eq!(clamp_inline_top(Some(10), 10), None); // top must be < rows
        assert_eq!(clamp_inline_top(None, 30), None);
    }

    // ── Bug 3 repro/fix: content duplicates / stacks on terminal RESIZE ───────
    //
    // Root cause: the resize-commit path cleared the old inline chrome with
    // `terminal.clear()` before rebuilding fresh. `Terminal::clear` (ratatui
    // 0.29) erases from `self.viewport_area`, a Rect ratatui only recomputes
    // inside `draw`/`autoresize`. Between the last draw (at the OLD size) and the
    // resize rebuild it still holds the PRE-resize geometry, so after a height
    // change its top row is stale — below the resized screen entirely on a
    // shrink. That clear therefore missed the old chrome, and the following
    // `Viewport::Inline` rebuild scrolled the stale copy up into scrollback: one
    // duplicate per resize commit, stacking as a pane-drag fires many of them.
    //
    // Fix: anchor the clear to the bottom-anchored region geometry derived from
    // the terminal's CURRENT height (crossterm::terminal::size) via
    // `resize_clear_top_from_bottom`, wiping from the region's first row downward,
    // instead of trusting ratatui's stale `viewport_area` OR a DSR cursor query
    // that a resize burst can drop or answer stale.

    #[test]
    fn resize_clear_top_from_bottom_lands_on_region_first_row() {
        // The inline live region is pinned to the bottom `inline_h` rows. On a
        // 24-row terminal a height-6 region occupies rows 18..=23, so the clear
        // must start at row 18 and wipe to the bottom — erasing the whole region
        // and nothing above it. Derived from the terminal's CURRENT height
        // (crossterm::terminal::size), never a fragile DSR cursor query.
        assert_eq!(resize_clear_top_from_bottom(24, 6), 18);
        // Height-1 region on a 24-row terminal starts on the last row.
        assert_eq!(resize_clear_top_from_bottom(24, 1), 23);
    }

    #[test]
    fn resize_clear_top_from_bottom_saturates_when_region_taller_than_screen() {
        // A region momentarily taller than the terminal (mid-shrink, before the
        // height is rebuilt) must clamp to row 0 rather than underflow to a huge
        // row that would move the clear off-screen.
        assert_eq!(resize_clear_top_from_bottom(4, 6), 0);
        assert_eq!(resize_clear_top_from_bottom(0, 10), 0);
        assert_eq!(resize_clear_top_from_bottom(6, 6), 0);
    }

    #[test]
    fn stale_viewport_area_after_shrink_is_why_naive_clear_missed_the_chrome() {
        // Demonstrates the root cause directly against a real `Terminal`: after
        // the backend shrinks, the terminal's cached inline geometry
        // (`viewport_area`, surfaced by `get_frame().area()`) still points at the
        // OLD rows — out of bounds for the new size. `Terminal::clear` would have
        // homed the cursor to exactly this stale top, so it could not have
        // cleared the old chrome. The fix stops trusting this Rect and anchors to
        // the terminal's current height instead (see `resize_clear_top_from_bottom`).
        let w = 40u16;
        let old_rows = 24u16;
        let old_h = 6u16;
        let old_top = old_rows - old_h; // 18 — bottom-anchored live region
        let mut backend = TestBackend::new(w, old_rows);
        backend
            .set_cursor_position(Position { x: 0, y: old_top })
            .unwrap();
        let mut term = Terminal::with_options(
            backend,
            TerminalOptions { viewport: Viewport::Inline(old_h) },
        )
        .unwrap();
        let input = InputComponent::new();
        let mut status = StatusBar::new();
        status.set_width(w);
        status.set_provider_info("openclaw", "glm-5.2:cloud");
        term.draw(|frame| draw_inline_chrome(frame, &input, &status))
            .unwrap();
        assert_eq!(term.get_frame().area().top(), old_top);

        // A pane-drag shrinks the terminal to fewer rows than the old region top.
        let new_rows = 12u16;
        term.backend_mut().resize(w, new_rows);

        // ratatui has NOT recomputed the inline geometry yet (no draw/autoresize
        // between the resize event and the rebuild), so the cached top is stale
        // and now out of bounds — the exact reason the old `terminal.clear()`
        // could not erase the on-screen chrome.
        let stale_top = term.get_frame().area().top();
        assert_eq!(stale_top, old_top, "cached inline top must still be the pre-resize row");
        assert!(
            stale_top >= new_rows,
            "root cause: the stale viewport top ({stale_top}) is out of bounds for the shrunk terminal ({new_rows} rows), so a clear anchored to it misses the old chrome",
        );

        // The fix anchors the clear to the bottom-anchored region geometry derived
        // from the terminal's CURRENT height (crossterm::terminal::size), which is
        // always in-bounds — no DSR cursor round-trip that a resize burst can drop
        // or answer stale. On the shrunk 12-row screen a height-6 region starts at
        // row 6, so the clear lands on real rows and erases the old chrome.
        let fix_top = resize_clear_top_from_bottom(new_rows, old_h);
        assert!(
            fix_top < new_rows,
            "fix: the size-anchored clear top ({fix_top}) is within the resized terminal ({new_rows} rows)",
        );
        assert_eq!(fix_top, new_rows - old_h, "fix: clear starts on the region's first row");
    }

    /// True if any cell in `row` holds non-blank rendered content.
    fn row_has_content(backend: &TestBackend, row: u16) -> bool {
        let area = backend.buffer().area;
        if row >= area.bottom() {
            return false;
        }
        (0..area.width).any(|x| backend.buffer()[(x, row)].symbol() != " ")
    }

    /// First row in `[top, top + h)` that has rendered (non-blank) content.
    /// The exact row a given widget lands on within the chrome (composer vs.
    /// status vs. an empty spacer row) is an implementation detail of
    /// `draw_inline_chrome`'s layout, so tests locate it dynamically instead
    /// of hard-coding a row index that could silently start asserting nothing
    /// if that layout ever changes.
    fn first_content_row(backend: &TestBackend, top: u16, h: u16) -> u16 {
        (top..top + h)
            .find(|&r| row_has_content(backend, r))
            .expect("the drawn chrome must render at least one non-blank row")
    }

    #[test]
    fn full_to_inline_naive_rebuild_strands_stale_chrome_rows() {
        // Demonstrates the BUG mechanism directly against ratatui's real
        // `Viewport::Inline` reconstruction: rebuilding anchored at a cursor row
        // INSIDE the old chrome (not its top) leaves the rows above it stale.
        let w = 40u16;
        let old_top = 5u16;
        let old_h = 6u16;
        let total_h = 30u16;

        let mut backend = TestBackend::new(w, total_h);
        backend.set_cursor_position(Position { x: 0, y: old_top }).unwrap();
        let mut term = Terminal::with_options(
            backend,
            TerminalOptions { viewport: Viewport::Inline(old_h) },
        )
        .unwrap();
        assert_eq!(term.get_frame().area().top(), old_top);

        let input = InputComponent::new();
        let mut status = StatusBar::new();
        status.set_width(w);
        status.set_provider_info("openclaw", "glm-5.2:cloud");
        term.draw(|frame| draw_inline_chrome(frame, &input, &status))
            .unwrap();
        let content_row = first_content_row(term.backend(), old_top, old_h);

        // Simulate the return from the alternate screen: the restored cursor
        // sits inside the old chrome (its last-drawn row), not at the top.
        let stale_cursor_row = old_top + old_h - 1;
        let mut carried = term.backend().clone();
        carried
            .set_cursor_position(Position { x: 0, y: stale_cursor_row })
            .unwrap();

        // The buggy path: rebuild WITHOUT clearing first.
        let new_h = 8u16;
        let mut buggy = Terminal::with_options(carried, TerminalOptions { viewport: Viewport::Inline(new_h) })
            .unwrap();
        let new_top = buggy.get_frame().area().top();

        assert!(
            new_top > old_top,
            "bug mechanism: naive rebuild anchors below the old chrome's top (new_top={new_top}, old_top={old_top})"
        );
        assert!(
            row_has_content(buggy.backend(), content_row),
            "bug mechanism: the old chrome's content row is left stale once it falls above the new viewport"
        );
    }

    #[test]
    fn full_to_inline_fixed_rebuild_leaves_no_stale_chrome() {
        // The FIX: clear from the remembered top before rebuilding (mirrors
        // `switch_to_inline`'s `clamp_inline_top` + explicit
        // `MoveTo`/`Clear(FromCursorDown)`, exercised here through
        // `TestBackend`'s equivalent `ClearType::AfterCursor`).
        let w = 40u16;
        let old_top = 5u16;
        let old_h = 6u16;
        let total_h = 30u16;

        let mut backend = TestBackend::new(w, total_h);
        backend.set_cursor_position(Position { x: 0, y: old_top }).unwrap();
        let mut term = Terminal::with_options(
            backend,
            TerminalOptions { viewport: Viewport::Inline(old_h) },
        )
        .unwrap();
        let input = InputComponent::new();
        let mut status = StatusBar::new();
        status.set_width(w);
        status.set_provider_info("openclaw", "glm-5.2:cloud");
        term.draw(|frame| draw_inline_chrome(frame, &input, &status))
            .unwrap();
        let content_row = first_content_row(term.backend(), old_top, old_h);

        // last_inline_top, captured right before the full-screen excursion.
        let remembered_top = Some(old_top);

        let mut fixed = term.backend().clone();
        let term_rows = fixed.size().unwrap().height;
        let top = clamp_inline_top(remembered_top, term_rows).expect("top must be in bounds");
        fixed.set_cursor_position(Position { x: 0, y: top }).unwrap();
        fixed.clear_region(ratatui::backend::ClearType::AfterCursor).unwrap();
        assert!(
            !row_has_content(&fixed, content_row),
            "clearing from the remembered top must wipe the old chrome"
        );

        let new_h = 8u16;
        let mut fixed_term = Terminal::with_options(fixed, TerminalOptions { viewport: Viewport::Inline(new_h) })
            .unwrap();
        assert_eq!(
            fixed_term.get_frame().area().top(),
            old_top,
            "fixed rebuild must anchor exactly where the old chrome started, not below it"
        );
        assert!(
            !row_has_content(fixed_term.backend(), content_row),
            "fixed path: no row anywhere the old chrome used to be may still hold stale content"
        );
    }

    #[test]
    fn full_to_inline_fix_preserves_transcript_above_old_chrome() {
        // The clear must never reach ABOVE the remembered top — that is real
        // transcript scrollback, not chrome, and must survive untouched.
        let w = 40u16;
        let old_top = 6u16;
        let old_h = 5u16;
        let total_h = 30u16;

        let mut backend = TestBackend::new(w, total_h);
        // Paint a fake transcript line directly into the row just above the
        // chrome (row old_top - 1), standing in for a finalized message that
        // was flushed into native scrollback via insert_before.
        {
            use ratatui::widgets::Widget;
            let mut buf = ratatui::buffer::Buffer::empty(Rect::new(0, old_top - 1, w, 1));
            Paragraph::new("earlier transcript line").render(buf.area, &mut buf);
            backend.draw(buf.content().iter().enumerate().map(|(i, c)| {
                let x = (i as u16) % w;
                let y = old_top - 1;
                (x, y, c)
            }))
            .unwrap();
        }
        assert!(
            row_has_content(&backend, old_top - 1),
            "sanity: fake transcript row must have content before the clear"
        );

        backend.set_cursor_position(Position { x: 0, y: old_top }).unwrap();
        let mut term = Terminal::with_options(
            backend,
            TerminalOptions { viewport: Viewport::Inline(old_h) },
        )
        .unwrap();
        let input = InputComponent::new();
        let mut status = StatusBar::new();
        status.set_width(w);
        status.set_provider_info("openclaw", "glm-5.2:cloud");
        term.draw(|frame| draw_inline_chrome(frame, &input, &status))
            .unwrap();

        let mut fixed = term.backend().clone();
        let top = clamp_inline_top(Some(old_top), fixed.size().unwrap().height).unwrap();
        fixed.set_cursor_position(Position { x: 0, y: top }).unwrap();
        fixed.clear_region(ratatui::backend::ClearType::AfterCursor).unwrap();

        assert!(
            row_has_content(&fixed, old_top - 1),
            "the real transcript row directly above the old chrome must survive the clear"
        );
    }

    // ── Bug 2 repro/fix: `/clear` doesn't visibly clear ──────────────────────
    //
    // Root cause: in inline mode every finalized message is flushed into the
    // terminal's REAL scrollback via `insert_before` (run-loop step 2), not
    // into any ratatui-owned buffer. `/clear`'s in-memory resets (`self.chat`,
    // `self.transcript_log`, ...) cannot touch that scrollback, and neither
    // can `Terminal::clear()` (it only resets ratatui's own diff state / the
    // live viewport region, never the host terminal's scroll history). The fix
    // signals the event loop (which owns the terminal) via `pending_clear` to
    // run `purge_scrollback()` (`ESC[3J` + `ESC[2J` + home) and rebuild the
    // inline viewport fresh at the top. `ESC[3J` (erase saved lines) has no
    // ratatui-level `ClearType` equivalent (it is a raw terminal/scrollback
    // concept `TestBackend`'s in-memory model doesn't represent), so the
    // scrollback purge itself can only be verified on a real TTY — see the
    // manual verification note below. What IS covered here at the logic level:
    // the App-side signal contract (set-once, consumed-once, deferred while a
    // dialog owns the screen) and the shared "clear + rebuild lands the fresh
    // viewport at the top" mechanism the two bugs both rely on.

    #[test]
    fn pending_clear_signal_is_consumed_exactly_once_when_inline() {
        // Mirrors the run loop's `let do_clear = !want_full && self.pending_clear;`
        // followed by `self.pending_clear = false;` inside the `if do_clear` arm
        // -- consuming the flag only when it is actually acted on.
        let mut pending_clear = true;
        let want_full = false;
        let do_clear = !want_full && pending_clear;
        if do_clear {
            pending_clear = false;
        }
        assert!(do_clear, "must fire while inline");
        assert!(!pending_clear, "flag must be consumed exactly once");

        // A second iteration with nothing new pending must not fire again.
        let do_clear_again = !want_full && pending_clear;
        assert!(!do_clear_again, "must not re-fire after being consumed");
    }

    #[test]
    fn pending_clear_signal_is_deferred_not_dropped_while_full_screen() {
        // If `/clear` somehow lands while a dialog owns the full screen, the
        // flag must survive to the next inline iteration rather than being
        // silently eaten by an unconditional `mem::take`.
        let pending_clear = true;
        let want_full = true;
        let do_clear = !want_full && pending_clear;
        assert!(!do_clear, "must not clear while a dialog owns the viewport");
        // The (bugged) alternative -- `std::mem::take(&mut pending_clear) &&
        // !want_full` -- would have zeroed `pending_clear` here even though
        // `do_clear` is false, permanently losing the request. The fixed
        // contract only writes `pending_clear = false` inside `if do_clear`.
        assert!(pending_clear, "flag must remain set until we return inline");
    }

    #[test]
    fn purged_and_rebuilt_inline_viewport_lands_at_the_top() {
        // The scrollback purge itself (ESC[3J) has no TestBackend equivalent,
        // but the second half of the fix -- home the cursor, then rebuild the
        // inline viewport fresh -- is the exact same "clear + rebuild anchors
        // the new viewport where the cursor was left" mechanism as Bug 1's
        // fix, just anchored at (0, 0) instead of the old chrome's top. Proves
        // the composer + status redraw at the very top of the (now empty)
        // screen, not wherever the old composer happened to leave the cursor.
        let w = 40u16;
        let old_top = 12u16;
        let old_h = 6u16;
        let total_h = 30u16;

        let mut backend = TestBackend::new(w, total_h);
        backend.set_cursor_position(Position { x: 0, y: old_top }).unwrap();
        let mut term = Terminal::with_options(
            backend,
            TerminalOptions { viewport: Viewport::Inline(old_h) },
        )
        .unwrap();
        let input = InputComponent::new();
        let mut status = StatusBar::new();
        status.set_width(w);
        status.set_provider_info("openclaw", "glm-5.2:cloud");
        term.draw(|frame| draw_inline_chrome(frame, &input, &status))
            .unwrap();

        // purge_scrollback()'s ClearType::All + MoveTo(0, 0), modeled with the
        // nearest TestBackend equivalent (a full clear + cursor home).
        let mut purged = term.backend().clone();
        purged.clear().unwrap(); // ClearType::All
        purged.set_cursor_position(Position { x: 0, y: 0 }).unwrap();

        for row in 0..total_h {
            assert!(
                !row_has_content(&purged, row),
                "every row must be blank immediately after the purge"
            );
        }

        let mut rebuilt = Terminal::with_options(purged, TerminalOptions { viewport: Viewport::Inline(old_h) })
            .unwrap();
        assert_eq!(
            rebuilt.get_frame().area().top(),
            0,
            "the re-primed inline viewport must land at the very top of the screen"
        );
    }

    #[test]
    fn composer_grows_with_newlines() {
        // Shift+Enter must visibly add composer rows (up to ~5 text lines).
        let mut input = InputComponent::new();
        input.set_width(92);
        let base = input.needed_height();
        for _ in 0..4 {
            input.handle_event(&crate::event::Event::Terminal(CrosstermEvent::Key(
                KeyEvent::new(KeyCode::Enter, KeyModifiers::SHIFT),
            )));
            press(&mut input, 'x');
        }
        let grown = input.needed_height();
        assert!(
            grown >= base + 4,
            "composer should grow with newlines: base={base} grown={grown}"
        );
        assert!(grown >= 7, "5-line composer should need >= 7 rows, got {grown}");
    }

    #[test]
    fn live_region_height_grows_and_clamps() {
        use super::live_region_height;
        // Idle composer (needs 3 rows) → exactly the base height.
        assert_eq!(live_region_height(3, 40), crate::LIVE_H_BASE);
        // 5-line composer (needs 7 rows) → grows to fit (overhead 3 + 7 = 10).
        assert_eq!(live_region_height(7, 40), 10);
        // Never exceeds term_rows - 1 (tiny terminal).
        assert_eq!(live_region_height(7, 6), 5);
        // Never below the base on a roomy terminal.
        assert!(live_region_height(1, 40) >= crate::LIVE_H_BASE);
    }

    #[test]
    fn streaming_inline_height_is_fixed_within_a_preview_step() {
        // The cure, refined: the reserved height must not track stream progress
        // CONTINUOUSLY (that is what rebuilt the viewport per token → DSR
        // re-anchor → stacked/whitespace artifacts). `streaming_inline_height`
        // itself takes no measure of the reply at all — the only stream-derived
        // input is `preview_rows`, which moves on a coarse lattice
        // (`stream_preview_rows`, exercised separately below).
        use super::{streaming_inline_height, STREAM_PREVIEW_ROWS};
        let base = crate::LIVE_H_BASE; // 6
        let overhead = 3u16;
        let input_needed = 3u16;
        let hi = 40u16;

        let h0 = streaming_inline_height(
            base,
            overhead,
            input_needed,
            0,
            0,
            0,
            STREAM_PREVIEW_ROWS,
            hi,
        );
        for _simulated_stream_rows in [1u16, 5, 20, 200, 9999] {
            let h = streaming_inline_height(
                base,
                overhead,
                input_needed,
                0,
                0,
                0,
                STREAM_PREVIEW_ROWS,
                hi,
            );
            assert_eq!(
                h, h0,
                "streaming inline height must stay constant within a preview step"
            );
        }
        // The slot is exactly the preview window stacked on the chrome, and it
        // sits above the idle base (so a preview row band is actually reserved).
        assert_eq!(h0, overhead + input_needed + STREAM_PREVIEW_ROWS);
        assert!(h0 > base, "streaming reserves the preview slot above idle base");

        // A grown preview is reserved rows-for-rows — the growth must reach the
        // viewport, or `draw_inline` would carve the extra rows out of somewhere
        // else (the composer), which is the band-accounting bug in reverse.
        for extra in [0u16, super::STREAM_PREVIEW_STEP, super::STREAM_PREVIEW_STEP * 2] {
            let grown = streaming_inline_height(
                base,
                overhead,
                input_needed,
                0,
                0,
                0,
                STREAM_PREVIEW_ROWS + extra,
                hi,
            );
            assert_eq!(grown, h0 + extra, "a {extra}-row taller preview must reserve {extra} more rows");
        }
    }

    #[test]
    fn streaming_inline_height_clamps_to_base_and_terminal() {
        use super::{streaming_inline_height, STREAM_PREVIEW_ROWS};
        const P: u16 = STREAM_PREVIEW_ROWS;
        // Never exceed the terminal clamp (term_rows - 1) on a tiny terminal.
        let hi = 5u16;
        assert_eq!(streaming_inline_height(3, 3, 3, 0, 0, 0, P, hi), hi);
        // Never drop below the idle base even when the chrome is minimal.
        let base = 20u16;
        assert!(streaming_inline_height(base, 1, 0, 0, 0, 0, P, 40) >= base);
        // Agents panel + slash popup rows are additive in the streaming branch too
        // (kept in lockstep with draw_inline's layout), still independent of stream
        // length.
        let with_extras = streaming_inline_height(6, 3, 3, 4, 0, 3, P, 40);
        let without = streaming_inline_height(6, 3, 3, 0, 0, 0, P, 40);
        assert_eq!(with_extras, without + 4 + 3);

        // **The regression that clipped the final response.** The reserved BANDS
        // (checklist + inline survey) are carved out of the same `Min(0)` slot
        // the streaming preview lives in. They used to be counted in `base` but
        // NOT in `want` — and since `want > base` in the normal case, the clamp
        // returned `want`, so the band's rows silently disappeared from the
        // reservation and the visible reply shrank by exactly the plan's height.
        for bands in 1u16..=12 {
            let with_bands = streaming_inline_height(6, 3, 3, 0, bands, 0, P, 60);
            assert_eq!(
                with_bands,
                without + bands,
                "a {bands}-row band must add {bands} rows to the streaming reservation"
            );
        }
    }

    #[test]
    fn agents_inline_panel_never_panics() {
        // Exercise the inline tree renderer (draw_tree) — now wired into the live
        // region — with live entries, the background-terminals summary line, and
        // the "↓ to manage" header hint, across every terminal size and a squeezed
        // live-region split. Any out-of-bounds write panics the test.
        for n in [0usize, 1, 4, 12] {
            for bg in [0usize, 1, 7] {
                let mut agents = Agents::new();
                for i in 0..n {
                    agents.agent_started(
                        format!("agent-{i}"),
                        "explorer",
                        "test-model",
                        format!("investigating subject number {i}"),
                        Some("background".to_string()),
                    );
                    agents.agent_progress(
                        &format!("agent-{i}"),
                        "reading files",
                        i as u32,
                        100,
                        "",
                        vec!["file_read: a.rs".into(), "file_grep: foo".into()],
                    );
                }
                agents.set_bg_summary(bg);
                for_each_size(|frame, area| {
                    agents.draw(frame, area);
                    // Also through the squeezed live-region agents row (rows[2]).
                    let rows = split_live_region(area, 1, 3);
                    if rows.len() > 2 {
                        agents.draw(frame, rows[2]);
                    }
                });
            }
        }
    }

    #[test]
    fn agents_dashboard_never_panics() {
        for n in [0usize, 1, 6, 20] {
            let mut agents = Agents::new();
            for i in 0..n {
                agents.agent_started(
                    format!("agent-{i}"),
                    "explorer",
                    "test-model",
                    format!("investigating a fairly long subject line number {i}"),
                    Some("batch-1".to_string()),
                );
                agents.agent_progress(
                    &format!("agent-{i}"),
                    "reading files",
                    i as u32,
                    100,
                    "",
                    Vec::new(),
                );
            }
            let bg_rows = vec![
                crate::components::agents::BgTerminalRow {
                    id: 1,
                    summary: "a backgrounded turn with a long summary line".to_string(),
                    elapsed_secs: 42,
                    done: false,
                },
                crate::components::agents::BgTerminalRow {
                    id: 2,
                    summary: "done turn".to_string(),
                    elapsed_secs: 7,
                    done: true,
                },
            ];
            for selected in [0usize, n.saturating_sub(1), n + 1, 999] {
                for_each_size(|frame, area| {
                    agents.draw_dashboard(frame, area, selected, &bg_rows, 2);
                });
            }
        }
    }
}
