use anyhow::Result;
use crossterm::{
    event::{Event as CrosstermEvent, KeyEvent, KeyEventKind},
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
/// composer's current needed height. The chrome overhead (streaming preview +
/// activity + context hint + 2-row status) is a fixed 5 rows, sized so an empty
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
    const OVERHEAD: u16 = 5;
    let want = OVERHEAD.saturating_add(input_needed);
    let hi = term_rows.saturating_sub(1).max(1);
    let lo = crate::LIVE_H_BASE.min(hi);
    want.clamp(lo, hi)
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
        // Current inline-viewport height. The composer grows the live region (up
        // to ~5 text lines) and a terminal resize reshapes it, so this tracks the
        // height the viewport is currently built at and is rebuilt when the wanted
        // height changes. Seeded with the height main.rs constructed the viewport.
        let mut cur_inline_h = inline_h;

        loop {
            // 1. Reconcile the terminal's viewport mode with what the app wants.
            let want_full = self.wants_full_viewport();
            // Height the inline live region wants right now (grows with the
            // composer, always clamped to the terminal so it can't overflow).
            let term_rows = crossterm::terminal::size().map(|(_, r)| r).unwrap_or(24);
            let desired_inline_h = self.desired_inline_height(term_rows);
            if want_full != was_full {
                if want_full {
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
                    switch_to_inline(&mut terminal, desired_inline_h)?;
                    term_handle = terminal::spawn_terminal_reader(self.event_tx.clone());
                    cur_inline_h = desired_inline_h;
                }
                was_full = want_full;
            } else if !was_full && desired_inline_h != cur_inline_h {
                // Staying inline, but the wanted height changed — the composer
                // grew/shrank or the terminal was resized. Rebuild the inline
                // viewport at the new height so it fits (grow) and so ratatui's
                // in-place inline-resize path (which can misplace the viewport on
                // a shrink) is bypassed entirely. Clear first so no stale rows of
                // the previous, differently-sized live region are left behind —
                // this is what kills the duplicated banners / status lines the
                // user saw after resizing. Pause the reader around the DSR query,
                // exactly as the full→inline switch does.
                let _ = terminal.clear();
                term_handle.abort();
                let _ = term_handle.await;
                rebuild_inline(&mut terminal, desired_inline_h)?;
                term_handle = terminal::spawn_terminal_reader(self.event_tx.clone());
                cur_inline_h = desired_inline_h;
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

            // 3. Draw the live region (inline) or the modal / fullscreen view (full).
            terminal.draw(|frame| self.draw(frame))?;

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
                    // Config editor and file picker overlays take highest modal
                    // priority (drawn over whatever state is underneath). The
                    // overdrive confirm sits above even those.
                    if let Some(ref d) = self.overdrive_confirm {
                        d.draw(frame, area);
                    } else if let Some(ref editor) = self.config_editor {
                        editor.draw(frame, area);
                    } else if let Some(ref picker) = self.file_picker {
                        picker.draw(frame, area);
                    } else {
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
                            AppState::Permissions => {
                                if let Some(ref d) = self.permissions {
                                    d.draw(frame, area);
                                }
                            }
                            AppState::PlanReview => {
                                if let Some(ref r) = self.plan_review {
                                    r.draw(frame, area);
                                }
                            }
                            AppState::Survey => {
                                if let Some(ref s) = self.survey {
                                    s.draw(frame, area);
                                }
                            }
                            _ => {}
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
    /// While a reply is streaming, the live region additionally grows to fit the
    /// in-progress message so it renders TOP-TO-BOTTOM in place — tokens landing
    /// at the bottom, the region auto-scrolling to follow — with the same
    /// markdown/wrapping render as the finalized transcript message, instead of
    /// a self-replacing 1-row preview. Growth is quantized into coarse steps so
    /// the viewport rebuilds only a handful of times per turn (not once per
    /// line), and is capped so it never swallows the whole terminal.
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
        let base = live_region_height(input_needed, term_rows)
            .saturating_add(agents_h)
            .saturating_add(popup_h)
            .min(hi0);

        // Rows the streaming reply currently renders to (0 when idle).
        let stream_rows = self.chat.streaming_height(self.width);
        if stream_rows <= 1 {
            return base;
        }

        // Chrome below the streaming preview: thinking/activity row (dynamic —
        // shared with draw_inline via think_row_height so the two can never
        // drift a row apart) + ctx-hint(1) + status(2). The streaming region
        // gets `stream_preview` rows on top.
        let overhead: u16 = self.think_row_height() + 1 + 2;
        const MAX_STREAM_PREVIEW: u16 = 18;
        const STEP: u16 = 6;
        // Quantize upward to the next STEP so a growing reply changes the
        // viewport height in a few discrete jumps rather than every new line.
        let stepped = ((stream_rows.min(MAX_STREAM_PREVIEW) + STEP - 1) / STEP) * STEP;
        let stream_preview = stepped.clamp(STEP, MAX_STREAM_PREVIEW);

        // `agents_h` MUST be added here too: `draw_inline` reserves a dedicated
        // agents-panel row, so if the streaming viewport the event loop builds
        // omits it, the terminal viewport ends up shorter than the layout
        // `draw_inline` produces. That height disagreement makes the rebuild
        // logic (`desired_inline_h != cur_inline_h`) thrash and leaves a ghost
        // copy of the live-region chrome — the second Thinking box + composer the
        // user saw stacked. Counting it in both branches keeps them in lockstep.
        let want = overhead
            .saturating_add(input_needed)
            .saturating_add(stream_preview)
            .saturating_add(agents_h)
            .saturating_add(popup_h);
        let hi = term_rows.saturating_sub(1).max(1);
        want.clamp(base, hi)
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
            self.activity.height().min(1)
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
            .min(area.height.saturating_sub(overhead + 1)) // keep >=1 for streaming
            .max(1);
        let rows = RLayout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Min(1),           // streaming preview
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

        self.chat.draw_live(frame, a_stream);
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
        if !self.task_checklist_hidden {
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
            let left = self.status.percent_left().unwrap_or(0);
            let text = format!(
                "Context low ({}% remaining) \u{00b7} Run /compact to compact & continue",
                left
            );
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

/// Leave the alternate screen and rebuild the inline viewport, restoring the
/// host terminal's scrollback untouched.
fn switch_to_inline(terminal: &mut Term, inline_h: u16) -> Result<()> {
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
        // 5-line composer (needs 7 rows) → grows to fit (overhead 5 + 7 = 12).
        assert_eq!(live_region_height(7, 40), 12);
        // Never exceeds term_rows - 1 (tiny terminal).
        assert_eq!(live_region_height(7, 6), 5);
        // Never below the base on a roomy terminal.
        assert!(live_region_height(1, 40) >= crate::LIVE_H_BASE);
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
