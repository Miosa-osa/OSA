use anyhow::Result;
use ratatui::prelude::*;
use std::time::Duration;
use tokio::time;
use tracing::info;

use super::App;
use crate::event::{terminal, Event};

impl App {
    pub async fn run(
        &mut self,
        terminal: &mut Terminal<CrosstermBackend<std::io::Stdout>>,
    ) -> Result<()> {
        // Spawn terminal event reader
        let term_handle = terminal::spawn_terminal_reader(self.event_tx.clone());

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

        // Main loop
        loop {
            // Render once per batch of events.
            terminal.draw(|frame| self.draw(frame))?;

            // Block until at least one event is available.
            let event = match self.event_rx.recv().await {
                Some(event) => event,
                None => break, // all senders dropped
            };
            let mut should_quit = self.update(event);

            // Coalesce: apply every event already queued before redrawing. During
            // streaming the backend emits one StreamingToken per token; drawing
            // per token re-renders the full markdown of the growing message every
            // time (O(n^2)) and floods the terminal. Draining the backlog here
            // collapses a burst of tokens into a single redraw — the main lever
            // for smooth, fast streaming output. Events are still processed in
            // FIFO order, so behavior is unchanged.
            while !should_quit {
                match self.event_rx.try_recv() {
                    Ok(event) => should_quit = self.update(event),
                    // Empty (nothing queued) or Disconnected (the next recv()
                    // returns None and breaks) — stop draining and redraw.
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

        match self.state {
            crate::app::state::AppState::Connecting => {
                crate::view::connecting::draw_connecting(frame, area);
            }
            crate::app::state::AppState::Onboarding => {
                // Full-screen conversational onboarding flow
                if let Some(ref wizard) = self.onboarding {
                    crate::view::onboarding_flow::draw_onboarding_flow(frame, area, wizard);
                } else {
                    crate::view::connecting::draw_connecting(frame, area);
                }
            }
            _ => {
                // Normal layout — pass activity height so the chat Rect never
                // overlaps the spinner.
                //
                // Recompute the layout per frame using the current input
                // height. The cached `self.layout` is set on resize and on
                // explicit `recompute_layout()` calls, but the input height
                // changes on every keystroke (single-line → multi-line wrap).
                // Refresh here so the input area grows downward as the user
                // types, instead of overflowing horizontally.
                let activity_lines = self.activity.height();
                let chat_content = if self.chat.has_messages {
                    Some(self.chat.content_height())
                } else {
                    None // welcome screen — don't shrink
                };
                let input_h = self.input.needed_height();
                let layout = crate::app::layout::Layout::compute_with_input_height(
                    self.width,
                    self.height,
                    self.config.sidebar_enabled,
                    self.tasks.height(),
                    self.agents.height(),
                    input_h,
                );
                let areas = crate::view::main_layout::LayoutAreas::compute_with_chat_height(
                    area,
                    &layout,
                    self.tasks.height(),
                    self.agents.height(),
                    activity_lines,
                    chat_content,
                );

                // Header hidden — info shown in welcome message + status bar
                // Reclaim the 2 header lines for chat space
                // self.header.draw_compact(frame, areas.header);

                // Chat
                self.chat.draw(frame, areas.chat);

                // Sidebar
                if let Some(sidebar_area) = areas.sidebar {
                    self.sidebar.draw(frame, sidebar_area);
                }

                // Tasks
                if let Some(task_area) = areas.tasks {
                    self.tasks.draw(frame, task_area);
                }

                // Agents
                if let Some(agent_area) = areas.agents {
                    self.agents.draw(frame, agent_area);
                }

                // Activity spinner — dedicated area below agents, above status bar
                if let Some(activity_area) = areas.activity {
                    self.activity.draw(frame, activity_area);
                }

                // Thinking box (collapsed indicator above status when thinking)
                if !self.thinking_box.is_empty() {
                    let tb_height = self.thinking_box.height(areas.chat.width).min(2);
                    let tb_y = areas.status.y.saturating_sub(tb_height);
                    let thinking_area = Rect::new(
                        areas.chat.x,
                        tb_y,
                        areas.chat.width,
                        tb_height,
                    );
                    self.thinking_box.draw(frame, thinking_area);
                }

                // Status bar
                self.status.draw(frame, areas.status);

                // Input
                self.input.draw(frame, areas.input);

                // Toast overlay
                if self.toasts.has_toasts() {
                    self.toasts.draw(frame, areas.toast);
                }

                // File picker overlay — drawn independently of AppState because it
                // is a lightweight Optional overlay, not a full state transition.
                // Must be drawn BEFORE the state-based overlays so it appears on top.
                if let Some(ref picker) = self.file_picker {
                    picker.draw(frame, area);
                }

                // Dialog overlays (drawn last = on top)
                if self.state.is_overlay() {
                    match self.state {
                        crate::app::state::AppState::Quit => {
                            self.quit_dialog.draw(frame, area);
                        }
                        crate::app::state::AppState::Palette => {
                            self.palette.draw(frame, area);
                        }
                        crate::app::state::AppState::ModelPicker => {
                            if let Some(ref picker) = self.model_picker {
                                picker.draw(frame, area);
                            }
                        }
                        crate::app::state::AppState::Sessions => {
                            if let Some(ref browser) = self.session_browser {
                                browser.draw(frame, area);
                            }
                        }
                        // Onboarding is now full-screen (handled above), not an overlay
                        crate::app::state::AppState::Permissions => {
                            if let Some(ref dialog) = self.permissions {
                                dialog.draw(frame, area);
                            }
                        }
                        crate::app::state::AppState::PlanReview => {
                            if let Some(ref review) = self.plan_review {
                                review.draw(frame, area);
                            }
                        }
                        crate::app::state::AppState::Survey => {
                            if let Some(ref survey) = self.survey {
                                survey.draw(frame, area);
                            }
                        }
                        _ => {}
                    }
                }
            }
        }
    }
}

// Components implement the Component trait for draw/handle_event.
// We call draw methods directly on concrete types in draw() above.
use crate::components::Component;
