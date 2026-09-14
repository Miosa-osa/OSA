//! **One owner for the inline chrome's on-screen geometry.**
//!
//! The composer + hint row + status bar (the "chrome") live in a ratatui
//! `Viewport::Inline` region whose absolute screen position moves constantly:
//! the composer grows and shrinks, the terminal resizes, a dialog takes over
//! the full screen and gives it back. Getting any one of those transitions
//! wrong strands a stale copy of the chrome on screen — the single defect
//! class behind eight releases of fixes (v1.0.103/.104/.105/.109/.115/.179/
//! .185/.189) and, as of this writing, a live doubled-chrome bug in v1.0.189.
//!
//! Before this module, the geometry (`last_inline_top`, `cur_inline_h`,
//! `was_full`) was a trio of loop-locals inside `App::run`, hand-threaded into
//! eight free functions and six independent branches, each of which decided
//! separately whether to clear the screen and how. Any branch that forgot a
//! step, or read a stale value, corrupted the display — and there was no
//! single place a reviewer (or a future editor) could look to see the whole
//! contract.
//!
//! [`InlineChrome`] is that place. It owns the three fields, and it is the
//! *only* thing that ever calls the erase/rebuild primitives
//! (`switch_to_full`, `switch_to_inline`, `rebuild_inline`, `purge_scrollback`)
//! or writes to the fields they update. A caller cannot forget the erase: the
//! primitives are private to `event_loop` (`pub(super)`) precisely so nothing
//! outside this type can hand-roll the sequence.
//!
//! # What this module does NOT change
//!
//! This is a **behavior-preserving extraction**. The six branches in
//! `App::run` still decide *when* to relocate the chrome — the resize-settle
//! debounce, the shrink-streak damper, `force_commit` — none of that policy
//! moved. What moved is *who performs the mechanics once the decision is
//! made*: compute the clear region from the geometry this type already owns,
//! clear it, rebuild the viewport, and record the new geometry, in that order,
//! every time, with no branch able to skip a step.
//!
//! # The one structural hardening this DOES add
//!
//! The pre-existing code cleared from `new_top` alone in the in-place
//! (non-resize) relocation, which was only safe because `new_top` happened to
//! always be `<= old_top` by construction (`new_top = old_top.min(...)`) — an
//! invariant enforced by one call site, nowhere checked. [`relocate`] instead
//! clears from `min(old_top, new_top)` unconditionally, so the erased span is
//! a superset of both the outgoing and incoming rect regardless of which
//! direction the top moves. This is a no-op today (the min already equals
//! `new_top` under the existing invariant) and closes the gap by construction
//! rather than by convention, which is what a debounce-policy change on either
//! side of this type could otherwise silently reopen.
//!
//! [`relocate`]: InlineChrome::relocate

use anyhow::Result;
use crossterm::{cursor::MoveTo, execute};
use std::io::Write as _;

use super::event_loop::{
    clear_screen_for_resize, erase_rows_in_place, purge_scrollback, rebuild_inline,
    resize_clear_strategy, resize_clear_top_from_bottom, surgical_clear_top, switch_to_full,
    switch_to_inline, ResizeClear, Term, TermIdent,
};
use super::frame_size::FrameSize;

/// Which screen the chrome's viewport currently lives on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ChromeMode {
    /// `Viewport::Inline`, sharing the primary screen with native scrollback.
    Inline,
    /// The alternate screen, owned outright by a dialog / onboarding / the
    /// file picker. The chrome has no presence here; `top`/`height` describe
    /// where it will resume when [`InlineChrome::to_inline`] is called.
    Full,
}

/// The inline chrome's on-screen geometry, and the only thing allowed to
/// change it.
///
/// `top` and `height` are the SOURCE OF TRUTH for where the composer/hint/
/// status rows currently are (or, in `Full` mode, where they were the instant
/// before the alternate screen was entered). Every method that moves the
/// chrome updates them before returning, and every method that erases the old
/// chrome reads them first — never a value recomputed from the terminal's
/// current size, which is what let a caller's guess drift from reality.
pub(crate) struct InlineChrome {
    top: u16,
    height: u16,
    mode: ChromeMode,
}

impl InlineChrome {
    /// A chrome freshly constructed at `height`, anchored at `top` (the row
    /// `main.rs` built the initial inline viewport at).
    pub(crate) fn new(top: u16, height: u16) -> Self {
        Self {
            top,
            height,
            mode: ChromeMode::Inline,
        }
    }

    /// Current live-region height (`cur_inline_h`, formerly a loop-local).
    pub(crate) fn height(&self) -> u16 {
        self.height
    }

    /// Whether the alternate screen currently owns the display (`was_full`,
    /// formerly a loop-local).
    pub(crate) fn is_full(&self) -> bool {
        self.mode == ChromeMode::Full
    }

    /// Re-read the chrome's real top row from the terminal.
    ///
    /// Call after anything that moves the viewport WITHOUT going through this
    /// type — today, that is only `Terminal::insert_before` (the welcome
    /// banner and every finalized-message flush into native scrollback),
    /// which shifts the inline viewport down by the inserted height as a side
    /// effect of ratatui's own scrolling. A no-op in `Full` mode, since the
    /// alternate screen has no inline viewport to read back.
    pub(crate) fn resync_top(&mut self, terminal: &mut Term) {
        if !self.is_full() {
            self.top = terminal.get_frame().area().top();
        }
    }

    /// Enter the alternate screen (a dialog / onboarding / the file picker
    /// wants the whole display).
    ///
    /// Captures the inline chrome's current top BEFORE leaving, so
    /// [`to_inline`](Self::to_inline) knows where to resume without a DSR
    /// round trip on the way back.
    pub(crate) fn to_full(&mut self, terminal: &mut Term) -> Result<()> {
        self.top = terminal.get_frame().area().top();
        switch_to_full(terminal)?;
        self.mode = ChromeMode::Full;
        Ok(())
    }

    /// Leave the alternate screen and rebuild the inline viewport at `height`.
    ///
    /// Erases the remembered old chrome (if the terminal is still big enough
    /// to have kept it) before rebuilding, so exactly one copy ever exists —
    /// see `switch_to_inline`'s own doc for why that erase has to happen here
    /// rather than be left to ratatui's cursor-anchored reconstruction.
    pub(crate) fn to_inline(
        &mut self,
        terminal: &mut Term,
        height: u16,
        size: FrameSize,
    ) -> Result<()> {
        let prev_top = if self.mode == ChromeMode::Full {
            Some(self.top)
        } else {
            None
        };
        switch_to_inline(terminal, height, prev_top, size)?;
        self.mode = ChromeMode::Inline;
        self.height = height;
        self.top = terminal.get_frame().area().top();
        Ok(())
    }

    /// Staying on the alternate screen across a real terminal resize.
    /// `ratatui::autoresize` reflows the alt-screen buffer on the next draw
    /// but can leave stale diff state, so every cell must repaint — this is
    /// the whole reason `terminal.clear()` still needs calling.
    pub(crate) fn resize_while_full(&self, terminal: &mut Term) {
        let _ = terminal.clear();
    }

    /// `/clear`, and a source-backed resize replay: both purge the terminal's
    /// real scrollback themselves and need the viewport rebuilt fresh at row
    /// 0 afterward. Kept distinct from [`relocate`](Self::relocate) because
    /// the caller has ALREADY erased everything (there is nothing of the old
    /// chrome left to reclaim) — calling `relocate` here would erase a second
    /// time for no reason and, worse, would compute its erase span from a
    /// `self.top` that the purge has already invalidated.
    pub(crate) fn rebuild_at_top0(&mut self, terminal: &mut Term, height: u16) -> Result<()> {
        rebuild_inline(terminal, height, Some(0))?;
        self.height = height;
        self.top = terminal.get_frame().area().top();
        Ok(())
    }

    /// Purge native scrollback and rebuild at row 0 — the `/clear` command's
    /// whole effect on the chrome. A thin wrapper so `App::run` never calls
    /// `purge_scrollback` directly (the ordering — purge before rebuild — is
    /// exactly the kind of step a call site could otherwise get backwards).
    pub(crate) fn clear_and_rebuild(&mut self, terminal: &mut Term, height: u16) -> Result<()> {
        purge_scrollback()?;
        self.rebuild_at_top0(terminal, height)
    }

    /// Relocate the inline viewport to `new_height`, staying inline.
    ///
    /// The one primary operation this type exists for. Reclaims whatever the
    /// PREVIOUSLY owned geometry (`self.top`/`self.height`) occupies, clears
    /// it, rebuilds the viewport at the computed new top, and records the new
    /// geometry — in that order, unconditionally, so no caller can perform
    /// only part of the sequence.
    ///
    /// `terminal_resized` selects the clear strategy: a REAL terminal resize
    /// reflowed the emulator's screen, so the old chrome's row is genuinely
    /// unknowable and only a full wipe (or, inside a multiplexer that doesn't
    /// reflow, a surgical erase from the remembered top) is sound. A pure
    /// height change (composer grew, spinner came up, turn ended) moved
    /// nothing on screen, so only the rows between the old and new geometry
    /// need to move, and only as far as a taller region needs to stay on the
    /// screen — see the module docs for why the erase floor is
    /// `min(old_top, new_top)` rather than trusting `new_top` alone.
    pub(crate) fn relocate(
        &mut self,
        terminal: &mut Term,
        size: FrameSize,
        new_height: u16,
        terminal_resized: bool,
    ) -> Result<()> {
        let old_top = self.top;
        let max_row = size.rows.saturating_sub(1);

        // Which erase this relocation will use decides where the region may
        // be rebuilt, so resolve it once and let both follow from it — see
        // `surgical_clear_top`'s doc for the incident this avoids repeating.
        let resize_clear = if terminal_resized {
            Some(resize_clear_strategy(&TermIdent::from_env()))
        } else {
            None
        };
        let new_top = match resize_clear {
            Some(ResizeClear::FullScreen) => resize_clear_top_from_bottom(size.rows, new_height),
            _ => old_top.min(size.rows.saturating_sub(new_height)),
        };

        if terminal_resized {
            let surgical_top = match resize_clear {
                Some(ResizeClear::Surgical) => Some(old_top),
                _ => None,
            };
            if let Some(top) = surgical_top {
                let top = surgical_clear_top(top, new_top);
                // Per-row EL, not a single whole-screen ED0 — see
                // `erase_rows_in_place`. `top` is frequently 0 here (every
                // erase that follows a `/clear`, which always leaves the
                // region pinned at row 0), which is exactly the tmux 3.6a
                // case a raw `Clear(FromCursorDown)` gets wrong.
                erase_rows_in_place(&mut std::io::stdout(), top, size.rows)?;
            } else {
                clear_screen_for_resize(&mut std::io::stdout())?;
            }
        } else {
            // Pure height change, not a resize — nothing on screen moved by
            // itself, so nothing above the region may move now either. The
            // one case that needs the screen to move is a region that has
            // grown past the bottom: scroll exactly that many rows so the
            // rows the region is about to occupy are made, not taken, and the
            // scrolled-off rows flow into native scrollback through the same
            // path a commit uses (`Terminal::scroll_up` / `append_lines`),
            // never `ESC[S` (which loses them on the VTE family).
            let mut out = std::io::stdout();
            let scroll = old_top.saturating_sub(new_top);
            if scroll > 0 {
                execute!(out, MoveTo(0, max_row))?;
                for _ in 0..scroll {
                    out.write_all(b"\n")?;
                }
                out.flush()?;
            }
            // See `erase_floor`'s doc for why this is the older of the two
            // tops rather than `new_top` alone — that is the fossil-reclaim
            // property a move-DOWN relies on. Per-row EL
            // (`erase_rows_in_place`), not a single whole-screen ED0: this
            // floor is 0 every time this branch fires right after a `/clear`
            // (which always rebuilds pinned at row 0), and a whole-screen ED0
            // from row 0 is the exact case tmux 3.6a deposits into real,
            // permanent pane history instead of erasing.
            let clear_top = erase_floor(old_top, new_top, max_row);
            erase_rows_in_place(&mut out, clear_top, size.rows)?;
        }

        // Put the cursor where the rebuilt region must start: `rebuild_inline`
        // is handed this row directly (`known_top`), so no DSR cursor query
        // ever runs on this path — see `rebuild_inline`'s doc for why that
        // round trip was the frozen-composer defect.
        let placed_top = new_top.min(max_row);
        execute!(std::io::stdout(), MoveTo(0, placed_top))?;
        rebuild_inline(terminal, new_height, Some(placed_top))?;

        self.height = new_height;
        self.top = terminal.get_frame().area().top();
        Ok(())
    }
}

/// Where a pure-height-change [`InlineChrome::relocate`] must start its
/// erase so that BOTH the outgoing region (`old_top`, height whatever it
/// was) and the incoming one (`new_top`, `new_height`) end up cleared —
/// `erase_rows_in_place` erases every row from this one down to the bottom
/// of the screen, so anchoring it at the OLDER of the two tops is what
/// makes the erase a superset of both rects regardless of which direction
/// the top moves.
///
/// This is the fossil-reclaim property: on a move DOWN (`new_top >
/// old_top`, e.g. the composer shrinking after a turn ends), a floor of
/// `new_top` alone would erase only the incoming rect and leave the rows
/// `old_top..new_top` — the outgoing chrome's own top rows — on screen,
/// permanently stranded above the relocated viewport and, if that region
/// is at or near the bottom of a scrolling terminal, flushed into
/// scrollback as a fossil the next time anything scrolls. Anchoring at
/// `old_top.min(new_top)` instead means the erase always starts at or
/// above wherever the outgoing chrome actually was, so there is nothing
/// left for a future scroll to carry into history.
fn erase_floor(old_top: u16, new_top: u16, max_row: u16) -> u16 {
    old_top.min(new_top).min(max_row)
}

#[cfg(test)]
mod tests {
    use super::erase_floor;

    #[test]
    fn move_down_reclaims_the_outgoing_region_instead_of_only_the_incoming_one() {
        // The exact shape of the reproduced fossil: the region moves DOWN
        // (composer shrinks, so its bottom-anchored top row increases) and a
        // floor of `new_top` alone — the pre-fix formula — would leave
        // `old_top..new_top` unerased, stranding the outgoing chrome's own
        // rows above the relocated viewport.
        let old_top = 10u16;
        let new_top = 16u16;
        let max_row = 49u16;

        let floor = erase_floor(old_top, new_top, max_row);
        assert_eq!(
            floor, old_top,
            "a move down must erase starting at the OLD top, not the new one, \
             or rows old_top..new_top strand as a fossil"
        );

        let buggy_floor_that_reproduced_the_bug = new_top.min(max_row);
        assert!(
            floor < buggy_floor_that_reproduced_the_bug,
            "the fix's floor must sit strictly above the pre-fix floor for a \
             move down, or it reclaims nothing the old formula didn't already"
        );
    }

    #[test]
    fn move_up_still_erases_from_the_new_top_since_it_is_now_the_older_one() {
        // Symmetric case: the region moves UP (composer grows). Here
        // `new_top` is already the smaller value, so the fix must coincide
        // with the pre-fix formula — this is the "no-op today" the module
        // docs describe, kept as a test so it stays a no-op on purpose.
        let old_top = 16u16;
        let new_top = 10u16;
        let max_row = 49u16;

        assert_eq!(erase_floor(old_top, new_top, max_row), new_top);
    }

    #[test]
    fn floor_never_exceeds_the_last_row_on_screen() {
        // A terminal shorter than either remembered top (a hard shrink mid-
        // relocate) must still clamp into bounds rather than hand
        // `MoveTo`/`Clear` a row past the buffer.
        assert_eq!(erase_floor(30, 5, 8), 5);
        assert_eq!(erase_floor(5, 30, 8), 5);
    }
}
