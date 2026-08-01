//! **Heights compute, Rects derive.**
//!
//! The second half of the live region's structural cure (the first is
//! `app::frame_size` — one size per frame).
//!
//! OSA's live region grew ~10 components that each published a row count through
//! a differently-named, differently-shaped function — `height()`, `height(width)`,
//! `max_height()`, `band_height(width)`, `content_height(width)`,
//! `completions_popup_height()`, `mention_popup_height()` — and a hand-summed
//! `desired_inline_height` that had to stay in step with a hand-written layout in
//! `draw_inline` **by discipline alone**. The source comments record that
//! discipline failing over and over: "must MATCH `desired_inline_height`'s
//! reservation expression exactly", "a disagreement here is not cosmetic", "the
//! bug that shipped was ONE rect handed to TWO components".
//!
//! Every one of those bugs is the same defect — *a component drew at a size
//! nothing had reserved* — and it was possible because a component could be
//! handed a rect it never measured for.
//!
//! [`Measured`] closes that. A live-region component states its height as a
//! function of the width it will be drawn at, and *nothing else may invent one*.
//! The band arbiter (`app::event_loop::measure_bands` / `fit_bands`) is the only
//! thing that turns those heights into rects, and it is the only place that
//! decides what fits — so "reserved" and "drawn" are two readings of one number
//! rather than two numbers that must be kept equal.
//!
//! Adapted from grok-build's `Renderable::desired_height(width)` (see
//! `reference_grok_build_learnings.md`); the code is ours, the shape is theirs.

/// A component that measures itself before it is laid out.
///
/// The contract, and the reason the trait exists:
///
/// 1. **`desired_height(width)` is the component's whole claim on the region.**
///    A component that wants rows asks for them here; it may not discover later,
///    inside `draw`, that it needs more.
/// 2. **`draw` must fit in what it was given.** A component handed `h` rows
///    paints inside `h` rows — decoration included. (`Activity` painting its
///    accent rail across a slot it only half-filled is why `bottom_anchored`
///    exists.)
/// 3. **Zero means the band collapses.** An idle component reserves nothing, so
///    an idle live region has no dead rows.
/// 4. **The measurement is pure.** Same state and width ⇒ same answer, with no
///    side effects, because it is called twice per frame (once to size the
///    viewport, once to lay it out) and a difference between those two calls is
///    precisely the defect class this trait removes.
pub trait Measured {
    /// Rows this component wants when drawn `width` columns wide.
    ///
    /// Components whose height is independent of the width still take it, so the
    /// arbiter can measure everything through one signature.
    fn desired_height(&self, width: u16) -> u16;
}

impl Measured for crate::components::task_checklist::TaskChecklist {
    /// `height()` is `items + 1` for the header, so an EMPTY checklist reports 1
    /// — a row for a header with nothing under it. The trait's contract is that
    /// zero means the band collapses, so the component's own "have I anything to
    /// show?" predicate belongs here rather than being left for each caller to
    /// remember. (The app-level gates — hidden with Ctrl+T, or a blocking ask
    /// owning the region — stay in `measure_bands`, which is the only thing that
    /// knows about them.)
    fn desired_height(&self, _width: u16) -> u16 {
        if self.is_visible() {
            self.height()
        } else {
            0
        }
    }
}

impl Measured for crate::components::toast::Toasts {
    /// One row per live toast. The EXACT live count rather than a fixed cap: a
    /// toast appearing or expiring is a discrete event, so this costs at most one
    /// viewport rebuild per toast edge and leaves no dead rows.
    fn desired_height(&self, _width: u16) -> u16 {
        self.live_count()
    }
}

impl Measured for crate::components::chat::thinking_box::ThinkingBox {
    /// Collapsed → 1 row; expanded → the box's fixed slot. An EMPTY box reports
    /// 1 from `height()` (there is no "nothing" case in the collapsed branch),
    /// so — as with the checklist — the component's own emptiness test belongs
    /// here, where the trait's "zero means the band collapses" contract is
    /// stated. The a11y branch, which decides whether the box is shown *at all*,
    /// stays in `measure_bands`: that is an app-level display mode, not
    /// something the box knows.
    fn desired_height(&self, width: u16) -> u16 {
        if self.is_empty() {
            0
        } else {
            self.height(width)
        }
    }
}

impl Measured for crate::components::activity::Activity {
    /// The **reserved** height, not the live one. The tool-use feed grows 0→N
    /// rows as tools run; sizing the band to the live count grew the inline
    /// viewport mid-turn, and every growth rebuilt it (a DSR cursor re-anchor),
    /// stacking a fresh composer + status bar down the screen tick after tick.
    /// `max_height()` is derived from the current verbosity — equally stable
    /// (verbosity never changes mid-turn) but exact, where a flat constant
    /// over-reserved the quiet modes and clipped `Verbose`.
    ///
    /// `Activity::height()` (the live content) is still what gets *drawn*, bottom
    /// -anchored inside this slot — see `bottom_anchored`.
    fn desired_height(&self, _width: u16) -> u16 {
        self.max_height()
    }
}

impl Measured for crate::components::agents::Agents {
    /// A FIXED cap whenever the roster is shown, for the same reason `Activity`
    /// reserves its ceiling: the roster gains a row per spawned fleet node, and
    /// sizing to the live count rebuilt the viewport on every spawn.
    fn desired_height(&self, _width: u16) -> u16 {
        if self.height() > 0 {
            crate::app::event_loop::AGENTS_INLINE_CAP
        } else {
            0
        }
    }
}

impl Measured for crate::dialogs::survey::SurveyDialog {
    fn desired_height(&self, width: u16) -> u16 {
        self.band_height(width)
    }
}

impl Measured for crate::dialogs::plan_review::PlanReview {
    fn desired_height(&self, width: u16) -> u16 {
        self.content_height(width)
    }
}

impl Measured for crate::dialogs::permissions::Permissions {
    fn desired_height(&self, width: u16) -> u16 {
        self.content_height(width)
    }
}

impl Measured for crate::components::input::InputComponent {
    /// The composer proper. The completion band it anchors is a SEPARATE band
    /// with its own measurement — see [`crate::components::input::InputComponent::popup_desired_height`].
    fn desired_height(&self, _width: u16) -> u16 {
        self.needed_height()
    }
}

impl Measured for crate::components::chat::Chat {
    /// The streaming reply's **content** height. This is not the band height: the
    /// preview band quantizes it onto the `ROWS + k*STEP` lattice via
    /// `stream_preview_rows`, which is what keeps the viewport from being rebuilt
    /// once per token.
    fn desired_height(&self, width: u16) -> u16 {
        self.streaming_height(width)
    }
}
