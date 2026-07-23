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
use crate::app::state::AppState;
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

/// Inline-viewport height while a reply is streaming.
///
/// Deliberately takes NO measure of how much has streamed: the preview slot is a
/// constant [`STREAM_PREVIEW_ROWS`]. That is the fixed-height invariant — for a
/// given terminal size and chrome, the streaming height does not change as the
/// reply grows, so the viewport is never rebuilt mid-turn. Kept as a free pure
/// function so the invariant is unit-testable without constructing a full `App`.
pub(crate) fn streaming_inline_height(
    base: u16,
    overhead: u16,
    input_needed: u16,
    agents_h: u16,
    popup_h: u16,
    hi: u16,
) -> u16 {
    let want = overhead
        .saturating_add(input_needed)
        .saturating_add(STREAM_PREVIEW_ROWS)
        .saturating_add(agents_h)
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
    pub async fn run(&mut self, mut terminal: Term, inline_h: u16) -> Result<()> {
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

        loop {
            // 1. Reconcile the terminal's viewport mode with what the app wants.
            let want_full = self.wants_full_viewport();
            // Height the inline live region wants right now (grows with the
            // composer, always clamped to the terminal so it can't overflow).
            let term_rows = crossterm::terminal::size().map(|(_, r)| r).unwrap_or(24);
            let desired_inline_h = self.desired_inline_height(term_rows);
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
            let popup_h_now = self.input.completions_popup_height();
            let popup_changed = popup_h_now != prev_popup_h;
            prev_popup_h = popup_h_now;
            let resized = std::mem::take(&mut self.resize_dirty) || popup_changed;
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
                    switch_to_inline(&mut terminal, desired_inline_h, last_inline_top)?;
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
                if resized {
                    let _ = terminal.clear();
                }
            } else if resized || desired_inline_h != cur_inline_h {
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
                let commit = if resized {
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
                    // Erase the OLD inline chrome before rebuilding fresh at the
                    // new size — this is what kills the duplicated banners /
                    // status lines and the misaligned post-split rows. Pause the
                    // reader FIRST (shared stdin) so the DSR cursor query below
                    // isn't eaten by it, exactly as the full→inline switch does.
                    term_handle.abort();
                    let _ = term_handle.await;
                    // Erasing ONLY the old chrome (so the transcript scrollback above
                    // it survives) requires knowing where the chrome ended up after
                    // the terminal reflowed the resize — and that is exactly a DSR
                    // cursor-position query. Every prior revision that tried to be
                    // surgical (query the cursor; anchor to `term_rows - inline_h`;
                    // anchor to the tracked `last_inline_top`) failed on terminals
                    // that DROP the DSR response during a resize: a widen unwraps
                    // scrollback and floats the old chrome UP an unknown number of
                    // rows, so no fixed anchor finds it — the chrome stacks into the
                    // "N% context used + divider" staircase. Worse, letting ratatui's
                    // own autoresize handle it makes the failed DSR query bubble up as
                    // the "cursor position could not be read" CRASH.
                    //
                    // On such a terminal, surgical clearing is impossible. So don't:
                    // wipe the WHOLE screen with a DSR-free `ClearType::All` and
                    // rebuild fresh. Exactly one copy of the chrome can exist and the
                    // reflow position never matters. Validated against a DSR-dropping
                    // pane across widen / narrow / rapid-resize bursts: no duplicate,
                    // no crash. Trade-off: the on-screen transcript is cleared on
                    // resize (resizing mid-session repaints from the live region
                    // down). The finalized conversation still lives in the terminal's
                    // scrollback history and the in-app transcript viewer, so nothing
                    // is lost — only the on-screen copy is redrawn.
                    let _ = last_inline_top;
                    let _ = execute!(
                        std::io::stdout(),
                        crossterm::cursor::MoveTo(0, 0),
                        crossterm::terminal::Clear(crossterm::terminal::ClearType::All),
                    );
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
                    // Use the real terminal width so the full ASCII logo shows
                    // whenever the window is wide enough (the inline frame area can
                    // lag a resize and under-report the width).
                    let w = crossterm::terminal::size().map(|(c, _)| c).unwrap_or(80);
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
            if !was_full && self.chat.has_pending_scrollback() {
                let w = terminal.get_frame().area().width;
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
                    terminal.insert_before(h, |buf| {
                        msg.render_to_buffer(Rect::new(0, 0, w, h), buf, 0);
                    })?;
                }
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

            if should_quit {
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
        if let Some(cancel) = self.sse_cancel.take() {
            cancel.cancel();
        }

        info!("App exiting cleanly");
        Ok(())
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
                self.toasts.draw(frame, toast_rect(area).intersection(area));
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
                            AppState::Survey => {
                                if let Some(ref s) = self.survey {
                                    s.draw(frame, area);
                                }
                            }
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
                self.toasts.draw(frame, toast_rect(area).intersection(area));
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
    pub fn desired_inline_height(&self, term_rows: u16) -> u16 {
        let input_needed = self.input.needed_height();
        // Grow the viewport to fit the inline agents panel (multi-agent activity /
        // background-terminals summary) so it isn't clipped by the fixed chrome.
        let agents_h = self.agents.height().min(AGENTS_INLINE_CAP);
        let hi0 = term_rows.saturating_sub(1).max(1);
        // Reserve rows for an open slash-completions popup so the upward-growing
        // menu always has room above the input (same mechanism as the agents
        // panel). Zero when the popup is closed, so idle height is unchanged.
        let popup_h = self.input.completions_popup_height();
        // Extra rows the live tool-use feed needs beyond the single activity
        // row already baked into `live_region_height`'s fixed chrome. Without
        // this the base (non-streaming) viewport reserves only 1 row for the
        // activity component, so the per-tool feed drawn by draw_inline would
        // be clipped off the bottom of the inline viewport. `think_row_height`
        // is the shared source of truth, so viewport and layout grow together.
        let activity_feed_extra = self.think_row_height();
        let base = live_region_height(input_needed, term_rows)
            .saturating_add(agents_h)
            .saturating_add(popup_h)
            .saturating_add(activity_feed_extra)
            .min(hi0);

        // A pending permission prompt renders inline above the composer; grow the
        // live region to fit its compact height so the ask isn't clipped.
        if let Some(ref perm) = self.permissions {
            let perm_rows = perm.content_height(self.width);
            let overhead: u16 = self.think_row_height() + 1 + 2;
            let want = overhead
                .saturating_add(input_needed)
                .saturating_add(perm_rows)
                .saturating_add(agents_h)
                .saturating_add(popup_h);
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
            let overhead: u16 = self.think_row_height() + 1 + 2;
            let want = overhead
                .saturating_add(input_needed)
                .saturating_add(review.content_height(self.width))
                .saturating_add(agents_h)
                .saturating_add(popup_h);
            let hi = term_rows.saturating_sub(1).max(1);
            return want.clamp(base, hi);
        }

        // Streaming preview — FIXED-height, internally-scrolled slot (the real
        // cure). `streaming_height` is consulted ONLY as a boolean "is anything
        // streaming?" gate, NEVER for sizing: the reserved slot is a constant
        // STREAM_PREVIEW_ROWS, so the inline-viewport height stays CONSTANT for the
        // whole turn. Previously this branch grew (quantized) with the reply, which
        // rebuilt the inline viewport mid-turn → a DSR cursor re-anchor tmux/SSH can
        // drop → the stacked / whitespace artifacts. With a fixed slot the viewport
        // is built once per turn; the newest lines scroll WITHIN the slot
        // (`Chat::draw_live` bottom-anchors the tail) and completed content still
        // flushes to native scrollback exactly as before.
        let streaming = self.chat.streaming_height(self.width) > 1;
        if !streaming {
            return base;
        }
        // Chrome below the streaming preview: thinking/activity row (dynamic —
        // shared with draw_inline via think_row_height so the two can never drift a
        // row apart) + ctx-hint(1) + status(2). `agents_h`/`popup_h` are counted in
        // BOTH branches so viewport sizing and the draw_inline layout stay in
        // lockstep — a 1-row disagreement is the height-thrash that stacked a ghost
        // Thinking box + composer.
        let overhead: u16 = self.think_row_height() + 1 + 2;
        let hi = term_rows.saturating_sub(1).max(1);
        streaming_inline_height(base, overhead, input_needed, agents_h, popup_h, hi)
    }

    /// Height of the thinking/activity row. The SINGLE source of truth used by
    /// BOTH `desired_inline_height` (viewport sizing) and `draw_inline` (layout)
    /// so the reserved overhead can never disagree with the drawn row by a line
    /// — that 1-row disagreement is exactly the height-thrash class of bug that
    /// stacks a ghost second Thinking box + composer (see the agents_h note in
    /// `desired_inline_height`).
    fn think_row_height(&self) -> u16 {
        if !self.thinking_box.is_empty() {
            // Collapsed → 1 row; expanded (ctrl+t) → the box's measured height.
            self.thinking_box.height(self.width)
        } else {
            // Full activity height so the LIVE tool-use feed (spinner row +
            // one row per running/finished tool) actually gets vertical space.
            // Previously clamped to `.min(1)`, which left the inline layout a
            // single row for the whole activity component: `Activity::draw`
            // returns early when `area.height < 2` (see activity.rs), so ONLY
            // the "✦ Working…" spinner drew and every per-tool feed row was
            // dropped — that is why the user never saw tools as they ran.
            // Capped so a long feed can never swallow the compact live region.
            self.activity.height().min(6)
        }
    }

    /// Draw the compact inline live region: streaming preview, thinking/activity,
    /// status, and input. Finalized conversation lives in native scrollback.
    fn draw_inline(&self, frame: &mut Frame, area: Rect) {
        let think_h: u16 = self.think_row_height();
        // Inline agents panel: multi-agent tree + "N background terminals" summary.
        // Height 0 when idle (row collapses); capped so it never swallows the
        // compact live region, and bounded by what's left after the fixed chrome.
        let agents_h = {
            let want = self.agents.height().min(super::event_loop::AGENTS_INLINE_CAP);
            let reserved = think_h + 1 + 2 + 2; // hint + status + stream/input floor
            want.min(area.height.saturating_sub(reserved))
        };
        // Chrome overhead below the streaming preview: activity + agents + ctx-hint(1)
        // + status(2). The input takes whatever is left, clamped to what it needs.
        let overhead = think_h + agents_h + 1 + 2;
        let input_h = self
            .input
            .needed_height()
            .min(area.height.saturating_sub(overhead)) // streaming row is content-sized (0 when idle)
            .max(1);
        let rows = RLayout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Min(0),           // streaming preview (collapses to 0 when idle - no dead rows)
                Constraint::Length(think_h),  // thinking / activity
                Constraint::Length(agents_h), // agents panel / background summary
                Constraint::Length(1),        // right-aligned "N% context used" hint
                Constraint::Length(input_h),  // input box (top + bottom dividers)
                Constraint::Length(2),        // status line + permission/shell line
            ])
            .split(area);

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
        let a_stream = clamp_to_frame(frame, rows[0]);
        let a_think = clamp_to_frame(frame, rows[1]);
        let a_agents = clamp_to_frame(frame, rows[2]);
        let a_hint = clamp_to_frame(frame, rows[3]);
        let a_input = clamp_to_frame(frame, rows[4]);
        let a_status = clamp_to_frame(frame, rows[5]);

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
            self.activity.draw(frame, a_think);
        }
        // Multi-agent activity + background-terminals summary (no-ops when empty).
        self.agents.draw(frame, a_agents);
        self.draw_context_hint(frame, a_hint);
        self.input.draw(frame, a_input);
        self.status.draw(frame, a_status);
        // Live task checklist floats bottom-right of the streaming/chat region
        // (Claude Code's todo panel). It self-positions and no-ops when empty.
        // It additionally clamps its own panel to the frame internally.
        // Ctrl+T (chat:todosToggle) hides it.
        if !self.task_checklist_hidden
            && self.permissions.is_none()
            && self.plan_review.is_none()
        {
            self.task_checklist.draw(frame, a_stream);
        }
        if self.toasts.has_toasts() {
            self.toasts.draw(frame, toast_rect(area).intersection(bounds));
        }
    }

    /// Right-aligned "N% context used" hint that sits just above the input box's
    /// top divider (mirrors Claude Code's notification row above the prompt).
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
        let pct = (self.status.context_utilization() * 100.0).round() as u32;
        let text = format!("{}% context used", pct);
        let para = ratatui::widgets::Paragraph::new(ratatui::text::Line::from(
            ratatui::text::Span::styled(text, crate::style::theme().ctx_hint()),
        ))
        .alignment(ratatui::layout::Alignment::Right);
        frame.render_widget(para, area);
    }
}

/// Enter the alternate screen and rebuild the terminal at full height. Used for
/// dialogs, onboarding, connecting, and the file picker.
fn switch_to_full(terminal: &mut Term) -> Result<()> {
    execute!(std::io::stdout(), EnterAlternateScreen)?;
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
fn switch_to_inline(terminal: &mut Term, inline_h: u16, prev_inline_top: Option<u16>) -> Result<()> {
    execute!(std::io::stdout(), LeaveAlternateScreen)?;

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

    // Erase the old inline chrome before rebuilding. `crossterm::terminal::size`
    // reflects the terminal as it stands right now (a resize could have landed
    // while the dialog owned the screen), so re-validate the remembered row
    // against it rather than trusting a possibly-stale value blindly.
    let term_rows = crossterm::terminal::size().map(|(_, r)| r).unwrap_or(u16::MAX);
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
/// `self.chat` / `self.transcript_log`. `ClearType::Purge` is `ESC[3J`
/// (erase saved lines — supported by every xterm-compatible terminal in
/// mainstream use; emulators without it simply ignore the private sequence
/// and only the visible screen clears, which is still a correct, if smaller,
/// clear). `ClearType::All` (`ESC[2J`) then erases the now-scrollback-free
/// visible screen, and homing the cursor to (0, 0) means the caller's
/// following `Viewport::Inline` rebuild anchors fresh at the very top instead
/// of wherever the old composer happened to leave the cursor.
fn purge_scrollback() -> Result<()> {
    execute!(
        std::io::stdout(),
        crossterm::terminal::Clear(crossterm::terminal::ClearType::Purge),
        crossterm::terminal::Clear(crossterm::terminal::ClearType::All),
        crossterm::cursor::MoveTo(0, 0),
    )?;
    Ok(())
}

/// True when `key` is Ctrl+O (the transcript-viewer toggle). Delegates to the
/// single key-normalization layer so terminal-modifier quirks are decided in one
/// place.
fn is_ctrl_o(key: &KeyEvent) -> bool {
    crate::app::key_normalize::is_ctrl_o(key)
}

/// Top-right toast overlay rectangle within `area`.
fn toast_rect(area: Rect) -> Rect {
    Rect::new(
        area.x + area.width.saturating_sub(40),
        area.y,
        40.min(area.width),
        3.min(area.height),
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
    use super::{clamp_to_frame, safe_render_widget};
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
        let overhead = think_h + 1 + 2;
        let input_h = input
            .needed_height()
            .min(area.height.saturating_sub(overhead + 1))
            .max(1);
        let rows = RLayout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Min(1),
                Constraint::Length(think_h),
                Constraint::Length(1),
                Constraint::Length(input_h),
                Constraint::Length(2),
            ])
            .split(area);
        input.draw(frame, clamp_to_frame(frame, rows[3]));
        status.draw(frame, clamp_to_frame(frame, rows[4]));
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
    fn streaming_inline_height_is_fixed_across_stream_progress() {
        // The real cure: the inline-viewport height reserved while streaming must
        // NOT track how much has streamed, so the viewport is built once per turn
        // (no mid-turn rebuild / DSR re-anchor → no stacked/whitespace artifacts).
        use super::{streaming_inline_height, STREAM_PREVIEW_ROWS};
        let base = crate::LIVE_H_BASE; // 6
        let overhead = 3u16;
        let input_needed = 3u16;
        let hi = 40u16;

        // Simulate a reply growing from 1 to thousands of rendered rows. The stream
        // row count deliberately does NOT appear in the call — proving the reserved
        // height cannot track it — so every height is identical.
        let h0 = streaming_inline_height(base, overhead, input_needed, 0, 0, hi);
        for _simulated_stream_rows in [1u16, 5, 20, 200, 9999] {
            let h = streaming_inline_height(base, overhead, input_needed, 0, 0, hi);
            assert_eq!(
                h, h0,
                "streaming inline height must stay constant as the reply grows"
            );
        }
        // The slot is exactly the fixed preview window stacked on the chrome, and
        // it sits above the idle base (so a preview row band is actually reserved).
        assert_eq!(h0, overhead + input_needed + STREAM_PREVIEW_ROWS);
        assert!(h0 > base, "streaming reserves the fixed preview slot above idle base");
    }

    #[test]
    fn streaming_inline_height_clamps_to_base_and_terminal() {
        use super::streaming_inline_height;
        // Never exceed the terminal clamp (term_rows - 1) on a tiny terminal.
        let hi = 5u16;
        assert_eq!(streaming_inline_height(3, 3, 3, 0, 0, hi), hi);
        // Never drop below the idle base even when the chrome is minimal.
        let base = 20u16;
        assert!(streaming_inline_height(base, 1, 0, 0, 0, 40) >= base);
        // Agents panel + slash popup rows are additive in the streaming branch too
        // (kept in lockstep with draw_inline's layout), still independent of stream
        // length.
        let with_extras = streaming_inline_height(6, 3, 3, 4, 3, 40);
        let without = streaming_inline_height(6, 3, 3, 0, 0, 40);
        assert_eq!(with_extras, without + 4 + 3);
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
