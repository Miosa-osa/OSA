// Chat now owns two lanes:
//   * `scrollback`  — finalized messages queued for the terminal's native
//                     scrollback (drained by the app loop via `insert_before`).
//   * `messages`    — only in-progress tool calls awaiting their result; these
//                     live briefly, then get finalized into `scrollback`.
// The live inline region renders only `streaming_content` (the reply in flight).
#![allow(dead_code)]

pub mod message;
pub mod thinking_box;
pub mod welcome;

use ratatui::prelude::*;

use crate::client::types::Signal;
use crate::event::Event;

use super::{Component, ComponentAction};
use message::{Message, MessageType, SurveyQAData, ToolCallData};

/// Chat state for the native-scrollback TUI.
pub struct Chat {
    /// In-progress tool calls awaiting their result. Not rendered in the inline
    /// live region; each is moved to `scrollback` once finalized.
    messages: Vec<Message>,
    /// Finalized messages queued for the terminal's native scrollback.
    scrollback: Vec<Message>,
    /// Viewport dimensions (width used for height measurement / wrapping).
    width: u16,
    height: u16,
    /// Streaming content (live while processing).
    streaming_content: Option<String>,
    /// Whether we have produced any content (used to gate the welcome banner).
    pub has_messages: bool,
    /// Welcome screen metadata (Hermes-style inventory).
    welcome_provider: Option<String>,
    welcome_model: Option<String>,
    welcome_tool_count: usize,
    /// Last agent / user text, tracked for /retry and copy-last-message since
    /// finalized messages are pushed to native scrollback and no longer retained.
    last_agent_text: Option<String>,
    last_user_text: Option<String>,
}

impl Chat {
    pub fn new() -> Self {
        Self {
            messages: Vec::new(),
            scrollback: Vec::new(),
            width: 80,
            height: 20,
            streaming_content: None,
            has_messages: false,
            welcome_provider: None,
            welcome_model: None,
            welcome_tool_count: 0,
            last_agent_text: None,
            last_user_text: None,
        }
    }

    pub fn set_size(&mut self, width: u16, height: u16) {
        self.width = width;
        self.height = height;
        self.invalidate_cache();
    }

    // ── Enqueue helpers (all route to native scrollback) ──────────────

    pub fn add_user_message(&mut self, content: &str) {
        self.last_user_text = Some(content.to_string());
        self.scrollback
            .push(Message::new(MessageType::User, content.to_string(), None));
        self.has_messages = true;
    }

    pub fn add_agent_message(&mut self, content: &str, signal: Option<&Signal>) {
        self.last_agent_text = Some(content.to_string());
        self.scrollback.push(Message::new(
            MessageType::Agent,
            content.to_string(),
            signal.cloned(),
        ));
        self.has_messages = true;
    }

    /// Add a continuation chunk — same left-border style as an agent message but
    /// rendered without the "◈ OSA" header.
    pub fn add_agent_continuation(&mut self, content: &str) {
        self.last_agent_text = Some(content.to_string());
        self.scrollback.push(Message::new(
            MessageType::AgentContinuation,
            content.to_string(),
            None,
        ));
        self.has_messages = true;
    }

    pub fn add_system_message(&mut self, content: &str, severity: &str) {
        let msg_type = match severity {
            "error" => MessageType::SystemError,
            "warning" => MessageType::SystemWarning,
            _ => MessageType::SystemInfo,
        };
        self.scrollback
            .push(Message::new(msg_type, content.to_string(), None));
        self.has_messages = true;
    }

    /// Add a styled help message (rendering is hardcoded).
    pub fn add_help_message(&mut self) {
        self.scrollback
            .push(Message::new(MessageType::Help, String::new(), None));
        self.has_messages = true;
    }

    /// Add an inline tool-call summary to the chat (compact one-liner, legacy).
    pub fn add_tool_message(&mut self, content: &str) {
        self.scrollback
            .push(Message::new(MessageType::ToolCall, content.to_string(), None));
        self.has_messages = true;
    }

    /// Add a rich tool-call message. Held in the live tail (`messages`) until its
    /// result arrives, then finalized into scrollback.
    pub fn add_tool_message_rich(&mut self, data: ToolCallData) {
        self.messages.push(Message::new_tool_call(data));
        self.has_messages = true;
    }

    /// Push a pre-rendered collapsed tool summary line (e.g. "Read 3 files")
    /// straight into native scrollback. Reuses the ToolCall message carrier so
    /// the styled line renders verbatim via `draw_tool_call`.
    pub fn add_collapsed_tool_summary(&mut self, line: ratatui::text::Line<'static>) {
        self.scrollback.push(Message::new_tool_call(ToolCallData {
            name: String::new(),
            args: String::new(),
            result: String::new(),
            duration_ms: 0,
            success: true,
            expanded: false,
            lines: vec![line],
        }));
        self.has_messages = true;
    }

    /// Add a survey Q&A summary to the chat.
    pub fn add_survey_summary(&mut self, survey_id: String, pairs: Vec<(String, String)>) {
        self.scrollback.push(Message {
            msg_type: MessageType::SurveyQA,
            content: String::new(),
            signal: None,
            tool_data: None,
            survey_data: Some(SurveyQAData { survey_id, pairs }),
            cached_height: None,
            timestamp: None,
        });
        self.has_messages = true;
    }

    /// Attach result data to the last matching in-progress tool call and
    /// re-render its collapsed summary so line-count info appears.
    pub fn update_last_tool_result(&mut self, tool_name: &str, result: &str) {
        let width = self.width;
        for msg in self.messages.iter_mut().rev() {
            if let Some(ref mut td) = msg.tool_data {
                if td.name == tool_name && td.result.is_empty() {
                    td.result = result.to_string();
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

    /// Toggle expand/collapse on the most recent in-progress tool call (Ctrl+O).
    /// Note: once finalized into native scrollback, tool calls become static.
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

    /// Finalize a specific in-progress tool call (by name) into scrollback.
    pub fn finalize_tool(&mut self, name: &str) {
        if let Some(idx) = self
            .messages
            .iter()
            .position(|m| m.tool_data.as_ref().map_or(false, |t| t.name == name))
        {
            let msg = self.messages.remove(idx);
            self.scrollback.push(msg);
        }
    }

    /// Move every in-progress tool call into scrollback (turn-end safety net so a
    /// tool that never emitted a result is still shown).
    pub fn flush_pending_tools(&mut self) {
        for msg in self.messages.drain(..) {
            self.scrollback.push(msg);
        }
    }

    // ── Scrollback draining (app loop → insert_before) ────────────────

    pub fn has_pending_scrollback(&self) -> bool {
        !self.scrollback.is_empty()
    }

    pub fn drain_scrollback(&mut self) -> Vec<Message> {
        std::mem::take(&mut self.scrollback)
    }

    // ── Streaming preview ─────────────────────────────────────────────

    pub fn update_streaming(&mut self, content: &str) {
        self.streaming_content = Some(content.to_string());
        self.has_messages = true;
    }

    pub fn clear_streaming(&mut self) {
        self.streaming_content = None;
    }

    /// Rendered height, in terminal rows, that the in-progress streaming reply
    /// occupies at `width` — 0 when nothing is streaming. Computed through the
    /// exact same `Message` render path `draw_live` uses (markdown + label +
    /// cursor row), so the inline live region can grow to fit the reply as it
    /// streams in place instead of churning it through a cramped 1-row preview.
    pub fn streaming_height(&self, width: u16) -> u16 {
        match self.streaming_content {
            Some(ref s) if !s.is_empty() => {
                Message::new(MessageType::Agent, format!("{}\u{2588}", s), None).height(width)
            }
            _ => 0,
        }
    }

    pub fn clear(&mut self) {
        self.messages.clear();
        self.scrollback.clear();
        self.has_messages = false;
        self.streaming_content = None;
        self.last_agent_text = None;
        self.last_user_text = None;
    }

    pub fn last_agent_message(&self) -> Option<String> {
        self.last_agent_text.clone()
    }

    pub fn last_user_message(&self) -> Option<String> {
        self.last_user_text.clone()
    }

    /// Historically removed the last user+agent exchange. With native scrollback
    /// the terminal owns already-printed lines and they cannot be un-printed, so
    /// this only clears the tracked "last" texts (retry/copy targets).
    pub fn undo_last_exchange(&mut self) {
        self.last_agent_text = None;
    }

    pub fn set_welcome_info(&mut self, provider: &str, model: &str, tool_count: usize) {
        self.welcome_provider = Some(provider.to_string());
        self.welcome_model = Some(model.to_string());
        self.welcome_tool_count = tool_count;
    }

    fn invalidate_cache(&mut self) {
        for msg in &mut self.messages {
            msg.invalidate_cache();
        }
        for msg in &mut self.scrollback {
            msg.invalidate_cache();
        }
    }

    /// Render the live streaming preview, bottom-anchored so the newest lines
    /// stay visible. When idle, the region is left blank (finalized content lives
    /// in the terminal's native scrollback).
    pub fn draw_live(&self, frame: &mut Frame, area: Rect) {
        if area.height == 0 || area.width == 0 {
            return;
        }
        if let Some(ref s) = self.streaming_content {
            let msg = Message::new(MessageType::Agent, format!("{}\u{2588}", s), None);
            let full_h = msg.height(area.width);
            let h = full_h.min(area.height);
            let y = area.y + area.height.saturating_sub(h);
            msg.draw_scrolled(
                frame,
                Rect::new(area.x, y, area.width, h),
                full_h.saturating_sub(h),
            );
        }
    }
}

impl Component for Chat {
    fn handle_event(&mut self, _event: &Event) -> ComponentAction {
        ComponentAction::Ignored
    }

    fn draw(&self, frame: &mut Frame, area: Rect) {
        // The chat no longer owns a scroll viewport; the live region is drawn via
        // `draw_live`. This trait impl remains for the Component contract.
        self.draw_live(frame, area);
    }
}
