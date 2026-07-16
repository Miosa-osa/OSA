use anyhow::Result;
use crossterm::{
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

        // Initial health check
        self.check_health();

        // The terminal was built Inline; the app boots in Connecting (which wants
        // the full viewport), so the first iteration flips to full before drawing.
        let mut was_full = false;

        loop {
            // 1. Reconcile the terminal's viewport mode with what the app wants.
            let want_full = self.wants_full_viewport();
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
                    switch_to_inline(&mut terminal, inline_h)?;
                    term_handle = terminal::spawn_terminal_reader(self.event_tx.clone());
                }
                was_full = want_full;
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
                    let h = msg.height(w);
                    if h == 0 {
                        continue;
                    }
                    terminal.insert_before(h, |buf| {
                        msg.render_to_buffer(Rect::new(0, 0, w, h), buf, 0);
                    })?;
                }
            }

            // 3. Draw the live region (inline) or the modal / fullscreen view (full).
            terminal.draw(|frame| self.draw(frame))?;

            // 4. Block until at least one event is available.
            let event = match self.event_rx.recv().await {
                Some(event) => event,
                None => break, // all senders dropped
            };
            let mut should_quit = self.update(event);

            // Coalesce: apply every queued event before redrawing. During streaming
            // the backend emits one StreamingToken per token; draining the backlog
            // collapses a burst into a single redraw (the main lever for smooth,
            // fast streaming). FIFO order is preserved.
            while !should_quit {
                match self.event_rx.try_recv() {
                    Ok(event) => should_quit = self.update(event),
                    Err(_) => break,
                }
            }

            if should_quit {
                break;
            }
        }

        // Cleanup
        tick_handle.abort();
        term_handle.abort();
        if let Some(cancel) = self.sse_cancel.take() {
            cancel.cancel();
        }

        info!("App exiting cleanly");
        Ok(())
    }

    fn draw(&self, frame: &mut Frame) {
        let area = frame.area();

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
                _ => {
                    // File picker overlay takes highest modal priority.
                    if let Some(ref picker) = self.file_picker {
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
                self.toasts.draw(frame, toast_rect(area));
            }
        } else {
            self.draw_inline(frame, area);
        }
    }

    /// Draw the compact inline live region: streaming preview, thinking/activity,
    /// status, and input. Finalized conversation lives in native scrollback.
    fn draw_inline(&self, frame: &mut Frame, area: Rect) {
        let input_h = self
            .input
            .needed_height()
            .min(area.height.saturating_sub(2))
            .max(1);
        let think_h: u16 = if !self.thinking_box.is_empty() {
            1
        } else {
            self.activity.height().min(1)
        };
        let rows = RLayout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Min(1),          // streaming preview
                Constraint::Length(think_h), // thinking / activity
                Constraint::Length(1),       // status
                Constraint::Length(input_h), // input
            ])
            .split(area);

        self.chat.draw_live(frame, rows[0]);
        if !self.thinking_box.is_empty() {
            self.thinking_box.draw(frame, rows[1]);
        } else {
            self.activity.draw(frame, rows[1]);
        }
        self.status.draw(frame, rows[2]);
        self.input.draw(frame, rows[3]);
        if self.toasts.has_toasts() {
            self.toasts.draw(frame, toast_rect(area));
        }
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
    Err(anyhow::anyhow!(
        "failed to rebuild inline viewport after retries: {:?}",
        last_err
    ))
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
