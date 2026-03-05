use crossterm::event::{Event as CrosstermEvent, KeyCode, KeyEventKind, KeyModifiers, MouseEventKind};
use tracing::warn;

use super::App;
use crate::app::state::AppState;
use crate::components::{AppAction, Component, ComponentAction};
use crate::event::Event;

impl App {
    /// Main update function. Returns true if the app should quit.
    pub fn update(&mut self, event: Event) -> bool {
        match event {
            Event::Terminal(CrosstermEvent::Resize(w, h)) => {
                self.width = w;
                self.height = h;
                self.recompute_layout();
                false
            }
            Event::Terminal(CrosstermEvent::Key(key))
                if key.kind == KeyEventKind::Press =>
            {
                self.handle_key(key)
            }
            Event::Terminal(CrosstermEvent::Key(_)) => false, // ignore Release/Repeat
            Event::Terminal(CrosstermEvent::Mouse(mouse)) => {
                self.handle_mouse(mouse);
                false
            }
            Event::Terminal(CrosstermEvent::Paste(text)) => {
                if self.state.allows_input() {
                    let capped = if text.len() > super::MAX_MESSAGE_SIZE {
                        &text[..super::MAX_MESSAGE_SIZE]
                    } else {
                        &text
                    };

                    let line_count = capped.lines().count();
                    if line_count >= 5 {
                        self.toasts.push(
                            format!("Large paste ({} lines) \u{2014} sent as context", line_count),
                            crate::components::toast::ToastLevel::Info,
                        );
                    }

                    self.input.insert_str(capped);
                }
                false
            }
            Event::Terminal(_) => false,
            Event::Backend(backend_event) => self.handle_backend_event(backend_event),
            Event::Tick => {
                self.handle_tick();
                false
            }
            Event::HealthRetry => {
                self.check_health();
                false
            }
        }
    }

    fn handle_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        // File picker and reasoning selector are overlays that take priority
        // regardless of the current app state.
        if self.file_picker.is_some() {
            return self.handle_file_picker_key(key);
        }
        if self.reasoning_selector.is_some() {
            return self.handle_reasoning_key(key);
        }

        match self.state {
            AppState::Quit => self.handle_quit_dialog_key(key),
            AppState::Palette => self.handle_palette_key(key),
            AppState::ModelPicker => self.handle_model_picker_key(key),
            AppState::Sessions => self.handle_session_browser_key(key),
            AppState::Onboarding => self.handle_onboarding_key(key),
            AppState::PlanReview => self.handle_plan_review_key(key),
            AppState::Permissions => self.handle_permissions_key(key),
            AppState::Idle => self.handle_idle_key(key),
            AppState::Processing => self.handle_processing_key(key),
            _ => false,
        }
    }

    fn handle_idle_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        let input_empty = self.input.is_empty();

        match (key.code, key.modifiers) {
            (KeyCode::Char('c'), KeyModifiers::CONTROL) if input_empty => {
                self.transition(AppState::Quit);
                false
            }
            (KeyCode::Char('c'), KeyModifiers::CONTROL) => {
                self.input.reset();
                false
            }
            (KeyCode::Char('d'), KeyModifiers::CONTROL) if input_empty => true,
            (KeyCode::F(1), _) => {
                self.show_help();
                false
            }
            (KeyCode::Char('n'), KeyModifiers::CONTROL) => {
                self.create_session();
                false
            }
            (KeyCode::Char('l'), KeyModifiers::CONTROL) => {
                self.config.sidebar_enabled = !self.config.sidebar_enabled;
                let _ = self.config.save();
                self.recompute_layout();
                false
            }
            (KeyCode::Char('k'), KeyModifiers::CONTROL) => {
                self.open_command_palette();
                false
            }
            (KeyCode::Char('o'), KeyModifiers::CONTROL) => {
                if self.agents.is_active() {
                    self.agents.toggle_collapse();
                    self.recompute_layout();
                } else {
                    self.chat.toggle_last_tool_expand(self.width);
                }
                false
            }
            (KeyCode::Char('j'), KeyModifiers::NONE) if input_empty => {
                self.chat.scroll_down(1);
                false
            }
            (KeyCode::Char('k'), KeyModifiers::NONE) if input_empty => {
                self.chat.scroll_up(1);
                false
            }
            (KeyCode::Char('u'), KeyModifiers::NONE) if input_empty => {
                let half = self.height / 2;
                self.chat.scroll_up(half);
                false
            }
            (KeyCode::Char('d'), KeyModifiers::NONE) if input_empty => {
                let half = self.height / 2;
                self.chat.scroll_down(half);
                false
            }
            (KeyCode::PageUp, _) => {
                self.chat.scroll_up(self.height.saturating_sub(2));
                false
            }
            (KeyCode::PageDown, _) => {
                self.chat.scroll_down(self.height.saturating_sub(2));
                false
            }
            (KeyCode::Home, _) if input_empty => {
                self.chat.scroll_to_top();
                false
            }
            (KeyCode::End, _) if input_empty => {
                self.chat.scroll_to_bottom();
                false
            }
            (KeyCode::Char('y'), KeyModifiers::NONE) if input_empty => {
                self.copy_last_message();
                false
            }
            // @ key: open file picker to insert a file path into input
            (KeyCode::Char('@'), KeyModifiers::NONE) => {
                self.open_file_picker();
                false
            }
            _ => {
                let action =
                    self.input
                        .handle_event(&Event::Terminal(CrosstermEvent::Key(key)));
                match action {
                    ComponentAction::Emit(AppAction::Submit(text)) => {
                        self.submit_input(&text);
                        false
                    }
                    _ => false,
                }
            }
        }
    }

    fn handle_processing_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        let input_empty = self.input.is_empty();

        match (key.code, key.modifiers) {
            (KeyCode::Esc, _) => {
                self.cancel_processing();
                false
            }
            (KeyCode::Char('c'), KeyModifiers::CONTROL) => {
                let now = std::time::Instant::now();
                if let Some(last) = self.last_cancel_attempt {
                    if now.duration_since(last) < std::time::Duration::from_millis(1000) {
                        self.cancel_processing();
                        return false;
                    }
                }
                self.last_cancel_attempt = Some(now);
                self.toasts.push(
                    "Press Ctrl+C again to cancel".into(),
                    crate::components::toast::ToastLevel::Warning,
                );
                false
            }
            (KeyCode::Char('b'), KeyModifiers::CONTROL) => {
                self.background_task();
                false
            }
            (KeyCode::Char('l'), KeyModifiers::CONTROL) => {
                self.config.sidebar_enabled = !self.config.sidebar_enabled;
                let _ = self.config.save();
                self.recompute_layout();
                false
            }
            (KeyCode::Char('j'), KeyModifiers::NONE) if input_empty => {
                self.chat.scroll_down(1);
                false
            }
            (KeyCode::Char('k'), KeyModifiers::NONE) if input_empty => {
                self.chat.scroll_up(1);
                false
            }
            (KeyCode::PageUp, _) => {
                self.chat.scroll_up(self.height.saturating_sub(2));
                false
            }
            (KeyCode::PageDown, _) => {
                self.chat.scroll_down(self.height.saturating_sub(2));
                false
            }
            _ => {
                let action =
                    self.input
                        .handle_event(&Event::Terminal(CrosstermEvent::Key(key)));
                match action {
                    ComponentAction::Emit(AppAction::Submit(text)) => {
                        self.submit_input(&text);
                        false
                    }
                    _ => false,
                }
            }
        }
    }

    fn handle_mouse(&mut self, mouse: crossterm::event::MouseEvent) {
        let areas = crate::view::main_layout::LayoutAreas::compute(
            ratatui::prelude::Rect::new(0, 0, self.width, self.height),
            &self.layout,
            self.tasks.height(),
            self.agents.height(),
        );

        match mouse.kind {
            MouseEventKind::ScrollUp => {
                if mouse.row >= areas.chat.y
                    && mouse.row < areas.chat.y + areas.chat.height
                {
                    self.chat.scroll_up(3);
                }
            }
            MouseEventKind::ScrollDown => {
                if mouse.row >= areas.chat.y
                    && mouse.row < areas.chat.y + areas.chat.height
                {
                    self.chat.scroll_down(3);
                }
            }
            MouseEventKind::Down(crossterm::event::MouseButton::Left) => {
                if mouse.row >= areas.input.y
                    && mouse.row < areas.input.y + areas.input.height
                {
                    let col = mouse.column.saturating_sub(areas.input.x + 2);
                    self.input.set_cursor_col(col);
                }
                if let Some(sb) = areas.sidebar {
                    if mouse.column >= sb.x && mouse.column < sb.x + sb.width
                        && mouse.row >= sb.y && mouse.row < sb.y + sb.height
                    {
                    }
                }
            }
            _ => {}
        }
    }

    fn handle_tick(&mut self) {
        self.toasts.tick();
        self.activity.tick();
        self.agents.tick();

        if self.state.is_processing() {
            if let Some(start) = self.processing_start {
                let ms = start.elapsed().as_millis() as u64;
                self.sidebar.set_elapsed_ms(ms);
            }
        }

        if self.state.is_processing() {
            if let Some(start) = self.processing_start {
                let elapsed = start.elapsed();
                let timeout_secs = self.config.request_timeout_secs;
                let warning_secs = (timeout_secs * 4) / 5; // 80% threshold

                if elapsed >= std::time::Duration::from_secs(timeout_secs) {
                    warn!("Processing timed out after {}s", timeout_secs);
                    if let Some(cancel) = self.sse_cancel.take() {
                        cancel.cancel();
                    }
                    self.chat.clear_streaming();
                    self.stream_buf.clear();
                    self.thinking_buf.clear();
                    self.activity.stop();
                    self.status.set_active(false);
                    self.transition(AppState::Idle);
                    self.toasts.push(
                        format!("Request timed out ({}m)", timeout_secs / 60),
                        crate::components::toast::ToastLevel::Error,
                    );
                    self.start_sse();
                } else if elapsed >= std::time::Duration::from_secs(warning_secs) {
                    // Fire warning once when crossing the 80% threshold
                    let prev_elapsed =
                        elapsed.saturating_sub(std::time::Duration::from_millis(200));
                    if prev_elapsed < std::time::Duration::from_secs(warning_secs) {
                        let remaining = timeout_secs.saturating_sub(elapsed.as_secs());
                        let remaining_str = if remaining >= 60 {
                            format!("{}m", remaining / 60)
                        } else {
                            format!("{}s", remaining)
                        };
                        self.toasts.push(
                            format!(
                                "Processing for {}m, timing out in {}",
                                elapsed.as_secs() / 60,
                                remaining_str,
                            ),
                            crate::components::toast::ToastLevel::Warning,
                        );
                    }
                }
            }
        }
    }
}
