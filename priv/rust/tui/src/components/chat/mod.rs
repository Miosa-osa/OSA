// Phase 2+: add_tool_message (legacy path) — kept for compatibility, replaced by rich path
#![allow(dead_code)]

pub mod message;
pub mod thinking_box;
pub mod welcome;

use ratatui::prelude::*;
use ratatui::widgets::{Paragraph, Scrollbar, ScrollbarOrientation, ScrollbarState};

use crate::client::types::Signal;
use crate::event::Event;
use crate::style;

use super::{Component, ComponentAction};
use message::{Message, MessageType, SurveyQAData, ToolCallData};

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
    pub has_messages: bool,
    /// Welcome screen metadata (Hermes-style inventory)
    welcome_provider: Option<String>,
    welcome_model: Option<String>,
    welcome_tool_count: usize,
    welcome_fast_mode: bool,
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
            welcome_fast_mode: false,
        }
    }

    pub fn set_size(&mut self, width: u16, height: u16) {
        self.width = width;
        self.height = height;
        self.invalidate_cache();
    }

    /// Returns true when the user is at the bottom of the chat (no manual scroll).
    fn is_at_bottom(&self) -> bool {
        self.scroll_offset == 0
    }

    /// Auto-scroll to the bottom, but only when the user hasn't manually scrolled up.
    fn auto_scroll_to_bottom(&mut self) {
        if self.is_at_bottom() {
            self.scroll_offset = 0;
        }
    }

    pub fn add_user_message(&mut self, content: &str) {
        self.messages
            .push(Message::new(MessageType::User, content.to_string(), None));
        self.has_messages = true;
        // Always jump to bottom when the user sends a new message.
        self.scroll_to_bottom();
    }

    pub fn add_agent_message(&mut self, content: &str, signal: Option<&Signal>) {
        self.messages.push(Message::new(
            MessageType::Agent,
            content.to_string(),
            signal.cloned(),
        ));
        self.has_messages = true;
        self.auto_scroll_to_bottom();
    }

    /// Add a continuation chunk for the current agent turn — same left-border
    /// style as an agent message but rendered without the "◈ OSA" header.
    /// Use this when flushing streaming text that precedes a tool call, so that
    /// only the very first text block of a turn shows the header.
    pub fn add_agent_continuation(&mut self, content: &str) {
        self.messages.push(Message::new(
            MessageType::AgentContinuation,
            content.to_string(),
            None,
        ));
        self.has_messages = true;
        self.auto_scroll_to_bottom();
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
        self.auto_scroll_to_bottom();
    }

    /// Add a styled help message (no content needed — rendering is hardcoded).
    pub fn add_help_message(&mut self) {
        self.messages
            .push(Message::new(MessageType::Help, String::new(), None));
        self.has_messages = true;
        self.auto_scroll_to_bottom();
    }

    /// Add an inline tool-call summary to the chat (compact one-liner, legacy).
    pub fn add_tool_message(&mut self, content: &str) {
        self.messages.push(Message::new(
            MessageType::ToolCall,
            content.to_string(),
            None,
        ));
        self.has_messages = true;
        self.auto_scroll_to_bottom();
    }

    /// Add a rich tool-call message with pre-rendered styled Lines.
    pub fn add_tool_message_rich(&mut self, data: ToolCallData) {
        self.messages.push(Message::new_tool_call(data));
        self.has_messages = true;
        self.auto_scroll_to_bottom();
    }

    /// Add a survey Q&A summary to the chat.
    pub fn add_survey_summary(&mut self, survey_id: String, pairs: Vec<(String, String)>) {
        self.messages.push(Message {
            msg_type: MessageType::SurveyQA,
            content: String::new(),
            signal: None,
            tool_data: None,
            survey_data: Some(SurveyQAData { survey_id, pairs }),
            cached_height: None,
            timestamp: None,
        });
        self.has_messages = true;
        self.auto_scroll_to_bottom();
    }

    /// Attach result data to the last matching tool call and re-render the
    /// collapsed summary so line-count info appears without needing Ctrl+O.
    pub fn update_last_tool_result(&mut self, tool_name: &str, result: &str) {
        let width = self.width;
        for msg in self.messages.iter_mut().rev() {
            if let Some(ref mut td) = msg.tool_data {
                if td.name == tool_name && td.result.is_empty() {
                    td.result = result.to_string();
                    // Re-render the collapsed view so the summary line reflects
                    // the now-known line count (Written · N lines / Read · N lines).
                    let status = if td.success {
                        crate::tools::ToolStatus::Success
                    } else {
                        crate::tools::ToolStatus::Error
                    };
                    let opts = crate::tools::RenderOpts {
                        status,
                        width,
                        expanded: false,
                        compact: true,
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
    }

    /// Toggle expand/collapse on the most recent tool call message (Ctrl+O).
    pub fn toggle_last_tool_expand(&mut self, width: u16) {
        for msg in self.messages.iter_mut().rev() {
            if let Some(ref mut td) = msg.tool_data {
                td.expanded = !td.expanded;
                let status = if td.success {
                    crate::tools::ToolStatus::Success
                } else {
                    crate::tools::ToolStatus::Error
                };
                let opts = crate::tools::RenderOpts {
                    status,
                    width,
                    expanded: td.expanded,
                    compact: !td.expanded,
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
        self.auto_scroll_to_bottom();
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
        // Remove trailing agent message(s) — including continuation chunks —
        // then the user message.
        while let Some(msg) = self.messages.last() {
            if matches!(
                msg.msg_type,
                MessageType::Agent | MessageType::AgentContinuation
            ) {
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

    pub fn set_welcome_info(
        &mut self,
        provider: &str,
        model: &str,
        tool_count: usize,
        fast_mode: bool,
    ) {
        self.welcome_provider = Some(provider.to_string());
        self.welcome_model = Some(model.to_string());
        self.welcome_tool_count = tool_count;
        self.welcome_fast_mode = fast_mode;
    }

    pub fn set_welcome_fast_mode(&mut self, fast_mode: bool) {
        self.welcome_fast_mode = fast_mode;
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

    /// Public accessor for layout — returns total content height in lines.
    pub fn content_height(&self) -> u16 {
        self.compute_content_height()
    }

    fn compute_content_height(&self) -> u16 {
        let msg_height: u16 = self
            .messages
            .iter()
            .map(|m| m.height(self.width).saturating_add(1)) // +1 for spacing
            .sum();

        let streaming_height: u16 = if let Some(ref content) = self.streaming_content {
            // Measure the real height of the live streaming message so scroll
            // bounds are accurate and scroll_up() is not incorrectly capped.
            let streaming_msg = Message::new(MessageType::Agent, format!("{}█", content), None);
            streaming_msg.height(self.width).saturating_add(1) // +1 for spacing
        } else {
            0
        };

        msg_height.saturating_add(streaming_height)
    }

    /// Top-down renderer: messages anchored to the top of the chat area.
    /// Used when content fits in the viewport (no scrolling needed).
    fn draw_top_down(&self, frame: &mut Frame, area: Rect) {
        let mut y = area.y;

        // Render messages top-down
        for msg in &self.messages {
            if y >= area.y + area.height {
                break;
            }

            let h = msg.height(area.width);
            let available = (area.y + area.height).saturating_sub(y);
            let render_h = h.min(available);

            if render_h > 0 {
                let msg_area = Rect::new(area.x, y, area.width, render_h);
                msg.draw(frame, msg_area);
                y += render_h;
                // spacing
                if y < area.y + area.height {
                    y += 1;
                }
            }
        }

        // Render streaming content after messages
        if let Some(ref streaming) = self.streaming_content {
            if y < area.y + area.height {
                let streaming_msg =
                    Message::new(MessageType::Agent, format!("{}█", streaming), None);
                let h = streaming_msg.height(area.width);
                let available = (area.y + area.height).saturating_sub(y);
                let render_h = h.min(available);

                if render_h > 0 {
                    let msg_area = Rect::new(area.x, y, area.width, render_h);
                    streaming_msg.draw(frame, msg_area);
                }
            }
        }
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
                self.welcome_fast_mode,
            );
            return;
        }

        let theme = style::theme();
        let total_height = self.compute_content_height();

        // When content fits in the viewport, render TOP-DOWN (anchored to top).
        // When content overflows, render BOTTOM-UP with scroll (anchored to bottom).
        if total_height <= area.height && self.scroll_offset == 0 {
            self.draw_top_down(frame, area);
            return;
        }

        // Render messages from bottom up, accounting for scroll
        let mut y = area.y + area.height;
        let mut remaining_skip = self.scroll_offset;

        // Render streaming content first (at bottom)
        if let Some(ref streaming) = self.streaming_content {
            let streaming_msg = Message::new(MessageType::Agent, format!("{}█", streaming), None);
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

        // Render messages in reverse order (bottom-up)
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
                    // Partial skip: this message straddles the scroll boundary.
                    // Render the visible portion (clamped by ratatui).
                    let visible_h = h.saturating_sub(remaining_skip);
                    remaining_skip = 0;
                    let available = y.saturating_sub(area.y);
                    let render_h = visible_h.min(available);
                    if render_h > 0 {
                        y -= render_h;
                        let msg_area = Rect::new(area.x, y, area.width, render_h);
                        msg.draw(frame, msg_area);
                        if y > area.y {
                            y -= 1;
                        }
                    }
                    continue;
                }
            }

            // Clamp to available space instead of breaking on overflow
            let available = y.saturating_sub(area.y);
            if available == 0 {
                break;
            }
            let render_h = h.min(available);
            y -= render_h;
            let msg_area = Rect::new(area.x, y, area.width, render_h);
            msg.draw(frame, msg_area);
            // spacing
            if y > area.y {
                y -= 1;
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

        // Scroll position indicator -- shown only when scrolled up (scroll_offset > 0).
        // scroll_offset equals the number of lines hidden below the current viewport.
        if self.scroll_offset > 0 && area.height >= 1 {
            let lines_below = self.scroll_offset;
            let label = format!(" ↓ {} more ", lines_below);
            let label_width = label.len() as u16;

            // Position: bottom-right of chat area, 1 col left of the scrollbar track.
            // Guard against label wider than the usable area.
            if label_width < area.width.saturating_sub(1) {
                let indicator_x = area.x + area.width - label_width - 1;
                let indicator_y = area.y + area.height - 1;
                let indicator_area = Rect::new(indicator_x, indicator_y, label_width, 1);

                let indicator_style = Style::default()
                    .fg(theme.colors.button_active_text)
                    .bg(theme.colors.tooltip_bg)
                    .add_modifier(Modifier::BOLD);

                frame.render_widget(Paragraph::new(label).style(indicator_style), indicator_area);
            }
        }
    }
}
