use anyhow::Result;
use ratatui::prelude::*;
use std::time::Duration;
use tokio::time;
use tracing::info;

use super::App;
use crate::components::diagnostics::DiagnosticsData;
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
            // Render
            terminal.draw(|frame| self.draw(frame))?;

            // Wait for next event
            match self.event_rx.recv().await {
                Some(event) => {
                    let should_quit = self.update(event);
                    if should_quit {
                        break;
                    }
                }
                None => break, // all senders dropped
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
                let areas = self.layout_areas(area);

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
                    let thinking_area = Rect::new(areas.chat.x, tb_y, areas.chat.width, tb_height);
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

                if self.diagnostics_visible {
                    let recent_events: Vec<String> =
                        self.diagnostic_events.iter().cloned().collect();
                    self.diagnostics.draw_with_data(
                        frame,
                        area,
                        DiagnosticsData {
                            session_id: &self.session_id,
                            app_state: self.state.to_string(),
                            backend_status: &self.backend_status,
                            auth_status: &self.auth_status,
                            sse_reconnecting: self.sse_reconnecting,
                            provider: self.header.provider(),
                            model: self.header.model_name(),
                            active_agents: self.agents.active_count(),
                            active_tasks: self.tasks.active_count(),
                            background_tasks: self.bg_tasks.len(),
                            last_backend_error: self.last_backend_error.as_deref(),
                            recent_events: &recent_events,
                        },
                    );
                }
            }
        }
    }
}

// Components implement the Component trait for draw/handle_event.
// We call draw methods directly on concrete types in draw() above.
use crate::components::Component;
