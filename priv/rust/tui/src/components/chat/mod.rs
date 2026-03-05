pub mod message;
pub mod thinking_box;
pub mod welcome;

use ratatui::prelude::*;
use ratatui::widgets::{Scrollbar, ScrollbarOrientation, ScrollbarState};

use crate::client::types::Signal;
use crate::event::Event;
use crate::style;

use super::{Component, ComponentAction};
use message::{Message, MessageType, ToolCallData};

/// Chat viewport managing a scrollable list of messages
pub struct Chat {
    messages: Vec<Message>,
    /// Scroll offset (0 = bottom, positive = scrolled up)
    scroll_offset: u16,
    /// Viewport dimensions
    width: u16,
    height: u16,
    /// Streaming content (live while processing)
    streaming_content: Option<String>,
    /// Whether we have items (vs showing welcome)
    has_messages: bool,
    /// Welcome screen metadata (Hermes-style inventory)
    welcome_provider: Option<String>,
    welcome_model: Option<String>,
    welcome_tool_count: usize,
}

impl Chat {
    pub fn new() -> Self {
        Self {
            messages: Vec::new(),
            scroll_offset: 0,
            width: 80,
            height: 20,
            streaming_content: None,
            has_messages: false,
            welcome_provider: None,
            welcome_model: None,
            welcome_tool_count: 0,
        }
    }

    pub fn set_size(&mut self, width: u16, height: u16) {
        self.width = width;
        self.height = height;
        self.invalidate_cache();
    }

    pub fn add_user_message(&mut self, content: &str) {
        self.messages.push(Message::new(
            MessageType::User,
            content.to_string(),
            None,
        ));
        self.has_messages = true;
        self.scroll_to_bottom();
    }

    pub fn add_agent_message(&mut self, content: &str, signal: Option<&Signal>) {
        self.messages.push(Message::new(
            MessageType::Agent,
            content.to_string(),
            signal.cloned(),
        ));
        self.has_messages = true;
        self.scroll_to_bottom();
    }

    pub fn add_system_message(&mut self, content: &str, severity: &str) {
        let msg_type = match severity {
            "error" => MessageType::SystemError,
            "warning" => MessageType::SystemWarning,
            _ => MessageType::SystemInfo,
        };
        self.messages
            .push(Message::new(msg_type, content.to_string(), None));
        self.has_messages = true;
        self.scroll_to_bottom();
    }

    /// Add a styled help message (no content needed — rendering is hardcoded).
    pub fn add_help_message(&mut self) {
        self.messages
            .push(Message::new(MessageType::Help, String::new(), None));
        self.has_messages = true;
        self.scroll_to_bottom();
    }

    /// Add an inline tool-call summary to the chat (compact one-liner, legacy).
    pub fn add_tool_message(&mut self, content: &str) {
        self.messages
            .push(Message::new(MessageType::ToolCall, content.to_string(), None));
        self.has_messages = true;
        self.scroll_to_bottom();
    }

    /// Add a rich tool-call message with pre-rendered styled Lines.
    pub fn add_tool_message_rich(&mut self, data: ToolCallData) {
        self.messages.push(Message::new_tool_call(data));
        self.has_messages = true;
        self.scroll_to_bottom();
    }

    /// Attach result data to the last matching tool call (for expand toggle).
    pub fn update_last_tool_result(&mut self, tool_name: &str, result: &str) {
        for msg in self.messages.iter_mut().rev() {
            if let Some(ref mut td) = msg.tool_data {
                if td.name == tool_name && td.result.is_empty() {
                    td.result = result.to_string();
                    break;
                }
            }
        }
    }

    /// Toggle expand/collapse on the most recent tool call message (Ctrl+O).
    pub fn toggle_last_tool_expand(&mut self, width: u16) {
        for msg in self.messages.iter_mut().rev() {
            if let Some(ref mut td) = msg.tool_data {
                // Re-render with expanded=true if currently collapsed (1 line), or collapsed if expanded
                let is_expanded = td.lines.len() > 1;
                let status = if td.success {
                    crate::tools::ToolStatus::Success
                } else {
                    crate::tools::ToolStatus::Error
                };
                let opts = crate::tools::RenderOpts {
                    status,
                    width,
                    expanded: !is_expanded,
                    compact: is_expanded, // when collapsing, use compact
                    spinner_frame: None,
                    duration_ms: td.duration_ms,
                    truncated: false,
                };
                td.lines = crate::tools::render_tool(&td.name, &td.args, &td.result, &opts);
                msg.invalidate_cache();
                break;
            }
        }
    }

    pub fn update_streaming(&mut self, content: &str) {
        self.streaming_content = Some(content.to_string());
        self.has_messages = true; // ensure welcome screen is dismissed
        // Auto-scroll to follow new content only when the user has not manually
        // scrolled up.  scroll_offset == 0 means the viewport is pinned to the
        // bottom; any positive value means the user scrolled up intentionally.
        if self.scroll_offset == 0 {
            self.scroll_to_bottom();
        }
    }

    pub fn clear_streaming(&mut self) {
        self.streaming_content = None;
    }

    pub fn clear(&mut self) {
        self.messages.clear();
        self.has_messages = false;
        self.streaming_content = None;
        self.scroll_offset = 0;
    }

    pub fn last_agent_message(&self) -> Option<String> {
        self.messages
            .iter()
            .rev()
            .find(|m| matches!(m.msg_type, MessageType::Agent))
            .map(|m| m.content.clone())
    }

    pub fn last_user_message(&self) -> Option<String> {
        self.messages
            .iter()
            .rev()
            .find(|m| matches!(m.msg_type, MessageType::User))
            .map(|m| m.content.clone())
    }

    /// Remove last user+agent exchange (for /undo)
    pub fn undo_last_exchange(&mut self) {
        // Remove trailing agent message(s) then the user message
        while let Some(msg) = self.messages.last() {
            if matches!(msg.msg_type, MessageType::Agent) {
                self.messages.pop();
            } else {
                break;
            }
        }
        // Remove the user message
        if let Some(msg) = self.messages.last() {
            if matches!(msg.msg_type, MessageType::User) {
                self.messages.pop();
            }
        }
        self.has_messages = !self.messages.is_empty();
    }

    pub fn set_welcome_info(&mut self, provider: &str, model: &str, tool_count: usize) {
        self.welcome_provider = Some(provider.to_string());
        self.welcome_model = Some(model.to_string());
        self.welcome_tool_count = tool_count;
    }

    pub fn scroll_up(&mut self, lines: u16) {
        let max_scroll = self.compute_content_height().saturating_sub(self.height);
        self.scroll_offset = (self.scroll_offset + lines).min(max_scroll);
    }

    pub fn scroll_down(&mut self, lines: u16) {
        self.scroll_offset = self.scroll_offset.saturating_sub(lines);
    }

    pub fn scroll_to_top(&mut self) {
        self.scroll_offset = self.compute_content_height().saturating_sub(self.height);
    }

    pub fn scroll_to_bottom(&mut self) {
        self.scroll_offset = 0;
    }

    fn invalidate_cache(&mut self) {
        for msg in &mut self.messages {
            msg.invalidate_cache();
        }
    }

    fn compute_content_height(&self) -> u16 {
        let msg_height: u16 = self
            .messages
            .iter()
            .map(|m| m.height(self.width).saturating_add(1)) // +1 for spacing
            .sum();

        let streaming_height: u16 = if let Some(ref streaming) = self.streaming_content {
            // Use the same height calculation as the real draw path so that
            // scroll accounting and scrollbar positioning are accurate.
            let streaming_msg = message::Message::new(
                message::MessageType::Agent,
                format!("{}█", streaming),
                None,
            );
            streaming_msg.height(self.width).saturating_add(1) // +1 for spacing
        } else {
            0
        };

        msg_height.saturating_add(streaming_height)
    }
}

impl Component for Chat {
    fn handle_event(&mut self, _event: &Event) -> ComponentAction {
        ComponentAction::Ignored
    }

    fn draw(&self, frame: &mut Frame, area: Rect) {
        if area.height == 0 || area.width == 0 {
            return;
        }

        if !self.has_messages {
            welcome::draw_welcome_with_tools(
                frame,
                area,
                self.welcome_tool_count,
                self.welcome_provider.as_deref(),
                self.welcome_model.as_deref(),
            );
            return;
        }

        let theme = style::theme();
        let total_height = self.compute_content_height();

        // Render messages from bottom up, accounting for scroll
        let mut y = area.y + area.height;
        let mut remaining_skip = self.scroll_offset;

        // Render streaming content first (at bottom)
        if let Some(ref streaming) = self.streaming_content {
            let streaming_msg = Message::new(
                MessageType::Agent,
                format!("{}█", streaming),
                None,
            );
            let h = streaming_msg.height(area.width);

            if remaining_skip > 0 {
                if remaining_skip >= h {
                    remaining_skip -= h;
                } else {
                    let visible_h = h - remaining_skip;
                    remaining_skip = 0;
                    if y >= area.y + visible_h {
                        y -= visible_h;
                        let msg_area = Rect::new(area.x, y, area.width, visible_h);
                        streaming_msg.draw(frame, msg_area);
                    }
                }
            } else if y >= area.y + h {
                y -= h;
                let msg_area = Rect::new(area.x, y, area.width, h);
                streaming_msg.draw(frame, msg_area);
                // spacing
                if y > area.y {
                    y -= 1;
                }
            }
        }

        // Render messages in reverse order
        for msg in self.messages.iter().rev() {
            if y <= area.y {
                break;
            }

            let h = msg.height(area.width);
            let total_h = h.saturating_add(1); // include spacing

            if remaining_skip > 0 {
                if remaining_skip >= total_h {
                    remaining_skip -= total_h;
                    continue;
                } else {
                    remaining_skip = 0;
                }
            }

            if y >= area.y + h {
                y -= h;
                let msg_area = Rect::new(area.x, y, area.width, h);
                msg.draw(frame, msg_area);
                // spacing
                if y > area.y {
                    y -= 1;
                }
            } else {
                break;
            }
        }

        // Scrollbar
        if total_height > area.height {
            let max_scroll = total_height.saturating_sub(area.height);
            let position = max_scroll.saturating_sub(self.scroll_offset) as usize;
            let mut scrollbar_state = ScrollbarState::default()
                .content_length(max_scroll as usize)
                .position(position)
                .viewport_content_length(area.height as usize);

            let scrollbar = Scrollbar::new(ScrollbarOrientation::VerticalRight)
                .thumb_style(theme.scrollbar_thumb())
                .track_style(theme.scrollbar_track());

            frame.render_stateful_widget(scrollbar, area, &mut scrollbar_state);
        }
    }
}
