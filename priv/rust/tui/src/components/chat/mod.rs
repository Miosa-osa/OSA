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

use std::cell::RefCell;

use ratatui::prelude::*;

use crate::client::types::Signal;
use crate::event::Event;

use super::{Component, ComponentAction};
use message::{Message, MessageType, SurveyQAData, ToolCallData};

/// Cached parse of the in-flight streaming reply. See `Chat::stream_cache`.
struct StreamCache {
    /// Byte length of `streaming_content` this cache was parsed from. The
    /// streaming buffer only ever grows within a turn, so a length change is a
    /// reliable "content changed" signal and a valid cache key.
    content_len: usize,
    /// Viewport width the body was wrapped at.
    width: u16,
    /// Parsed markdown body (includes the trailing block cursor). Cloned once
    /// per frame in `draw_live`; never re-parsed until content or width changes.
    body: Text<'static>,
    /// Total rendered height: body rows + 1 for the "◈ OSA" label row.
    height: u16,
}

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
    /// True once any block has been queued for scrollback — used to emit a
    /// single blank spacer line between blocks (Claude Code's `addMargin`),
    /// never before the first one.
    scrollback_started: bool,
    /// Lazy render cache for the live streaming reply so the full-buffer markdown
    /// parse runs at most once per frame — not 2–3× per frame (old
    /// `streaming_height` + `draw_live` each re-parsed the whole buffer) and not
    /// once per token. Keyed by (content byte length, width). Interior
    /// mutability lets the `&self` render paths populate it lazily, which also
    /// coalesces multiple tokens arriving between two frames into a single parse.
    stream_cache: RefCell<Option<StreamCache>>,
    /// Frozen-tail incremental markdown renderer backing the live preview. Keeps
    /// completed depth-0 blocks rendered-once and re-parses only the streaming
    /// tail, so growing a long reply is ~O(N) instead of O(N²) full-buffer
    /// re-parses. Produces output byte-identical to the legacy full-buffer
    /// `render_markdown(&format!("{content}\u{2588}"), …)` path.
    stream_renderer: RefCell<crate::render::markdown_stream::StreamingRenderer>,
    /// U-T7 (display half): raw-markdown view toggle. When on, agent replies are
    /// shown as their literal markdown SOURCE instead of rendered. This is the
    /// "targeted message" state — it applies to agent messages finalized while
    /// the toggle is active (and, once the lead wires it, the live preview). The
    /// copy-to-clipboard half of U-T7 is owned by another lane.
    raw_view: bool,
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
            scrollback_started: false,
            stream_cache: RefCell::new(None),
            stream_renderer: RefCell::new(
                crate::render::markdown_stream::StreamingRenderer::new(80),
            ),
            raw_view: false,
        }
    }

    /// U-T7: toggle the raw-markdown view. Returns the new state. Invalidates the
    /// live stream cache so the preview rebuilds under the new mode on next draw.
    pub fn toggle_raw_view(&mut self) -> bool {
        self.raw_view = !self.raw_view;
        *self.stream_cache.borrow_mut() = None;
        self.raw_view
    }

    /// Whether the raw-markdown view is currently active.
    pub fn raw_view(&self) -> bool {
        self.raw_view
    }

    /// Set the raw-markdown view explicitly (invalidates the live stream cache).
    pub fn set_raw_view(&mut self, on: bool) {
        if self.raw_view != on {
            self.raw_view = on;
            *self.stream_cache.borrow_mut() = None;
        }
    }

    pub fn set_size(&mut self, width: u16, height: u16) {
        self.width = width;
        self.height = height;
        self.invalidate_cache();
    }

    // ── Enqueue helpers (all route to native scrollback) ──────────────

    /// Queue a finalized block for native scrollback with CC-style spacing:
    /// exactly one blank line before every block except the very first
    /// (Claude Code's `addMargin` / `marginTop={1}`).
    fn push_scrollback_block(&mut self, msg: Message) {
        if self.scrollback_started {
            self.scrollback.push(Message::new_tool_call(ToolCallData {
                name: String::new(),
                args: String::new(),
                result: String::new(),
                duration_ms: 0,
                success: true,
                expanded: false,
                lines: vec![Line::from("")],
            }));
        }
        self.scrollback_started = true;
        self.scrollback.push(msg);
        self.has_messages = true;
    }

    pub fn add_user_message(&mut self, content: &str) {
        self.last_user_text = Some(content.to_string());
        self.push_scrollback_block(Message::new(MessageType::User, content.to_string(), None));
    }

    pub fn add_agent_message(&mut self, content: &str, signal: Option<&Signal>) {
        self.last_agent_text = Some(content.to_string());
        let mut msg = Message::new(
            MessageType::Agent,
            content.trim_end().to_string(),
            signal.cloned(),
        );
        msg.set_raw_mode(self.raw_view); // U-T7: honor the raw-view toggle
        self.push_scrollback_block(msg);
    }

    /// Add a continuation chunk — same left-border style as an agent message but
    /// rendered without the "◈ OSA" header.
    pub fn add_agent_continuation(&mut self, content: &str) {
        self.last_agent_text = Some(content.to_string());
        let mut msg = Message::new(
            MessageType::AgentContinuation,
            content.trim_end().to_string(),
            None,
        );
        msg.set_raw_mode(self.raw_view); // U-T7: honor the raw-view toggle
        self.push_scrollback_block(msg);
    }

    pub fn add_system_message(&mut self, content: &str, severity: &str) {
        let msg_type = match severity {
            "error" => MessageType::SystemError,
            "warning" => MessageType::SystemWarning,
            _ => MessageType::SystemInfo,
        };
        self.push_scrollback_block(Message::new(msg_type, content.to_string(), None));
    }

    /// Add a styled help message (rendering is hardcoded).
    pub fn add_help_message(&mut self) {
        self.push_scrollback_block(Message::new(MessageType::Help, String::new(), None));
    }

    /// Add an inline tool-call summary to the chat (compact one-liner, legacy).
    pub fn add_tool_message(&mut self, content: &str) {
        self.push_scrollback_block(Message::new(MessageType::ToolCall, content.to_string(), None));
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
        self.push_scrollback_block(Message::new_tool_call(ToolCallData {
            name: String::new(),
            args: String::new(),
            result: String::new(),
            duration_ms: 0,
            success: true,
            expanded: false,
            lines: vec![line],
        }));
    }

    /// Add a survey Q&A summary to the chat.
    pub fn add_survey_summary(&mut self, survey_id: String, pairs: Vec<(String, String)>) {
        self.push_scrollback_block(Message {
            msg_type: MessageType::SurveyQA,
            content: String::new(),
            signal: None,
            tool_data: None,
            survey_data: Some(SurveyQAData { survey_id, pairs }),
            cached_height: None,
            timestamp: None,
            prerendered_body: None,
            raw_mode: false,
        });
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
            self.push_scrollback_block(msg);
        }
    }

    /// Move every in-progress tool call into scrollback (turn-end safety net so a
    /// tool that never emitted a result is still shown).
    pub fn flush_pending_tools(&mut self) {
        let pending: Vec<Message> = self.messages.drain(..).collect();
        for msg in pending {
            self.push_scrollback_block(msg);
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
        // Reuse the existing allocation instead of reallocating a fresh String
        // each token. No markdown parse happens here — the cache is rebuilt
        // lazily on the next render, so multiple tokens arriving between two
        // frames coalesce into a single parse.
        match self.streaming_content {
            Some(ref mut s) => {
                s.clear();
                s.push_str(content);
            }
            None => self.streaming_content = Some(content.to_string()),
        }
        self.has_messages = true;
    }

    pub fn clear_streaming(&mut self) {
        self.streaming_content = None;
        *self.stream_cache.borrow_mut() = None;
        self.stream_renderer.borrow_mut().reset();
    }

    /// Parse the live streaming markdown at most once per (content length, width),
    /// caching the parsed body + height. Returns the total rendered height (body
    /// rows + label row), or `None` when nothing is streaming. This is the single
    /// choke point that kills the old O(n²) hot path: `draw_live` and
    /// `streaming_height` (called 2–3× per frame) now share one parse, and
    /// successive tokens within a frame don't each re-parse the whole reply.
    fn ensure_stream_cache(&self, width: u16) -> Option<u16> {
        let content = self.streaming_content.as_ref()?;
        if content.is_empty() {
            return None;
        }
        let content_len = content.len();

        {
            let cache = self.stream_cache.borrow();
            if let Some(c) = cache.as_ref() {
                if c.content_len == content_len && c.width == width {
                    return Some(c.height);
                }
            }
        }

        // Cache miss: refresh the frozen-tail renderer. It freezes completed
        // depth-0 blocks and re-parses only the streaming tail (with the block
        // cursor appended), so this is ~O(tail) rather than an O(N) full-buffer
        // re-parse each time content grows. Match `draw_agent`'s body width
        // (width − 2). Output is byte-identical to the legacy full-buffer path.
        let body = {
            let mut r = self.stream_renderer.borrow_mut();
            r.set_width(width.saturating_sub(2));
            r.update(content);
            r.body_with_cursor()
        };
        let height = (body.lines.len() as u16).max(1) + 1; // +1 for the "◈ OSA" label

        *self.stream_cache.borrow_mut() = Some(StreamCache {
            content_len,
            width,
            body,
            height,
        });
        Some(height)
    }

    /// Rendered height, in terminal rows, that the in-progress streaming reply
    /// occupies at `width` — 0 when nothing is streaming. Backed by the shared
    /// `ensure_stream_cache` parse (label + markdown body + cursor row), so the
    /// inline live region grows to fit the reply as it streams in place without
    /// re-parsing the whole buffer for the measurement pass.
    pub fn streaming_height(&self, width: u16) -> u16 {
        self.ensure_stream_cache(width).unwrap_or(0)
    }

    pub fn clear(&mut self) {
        self.messages.clear();
        self.scrollback.clear();
        self.has_messages = false;
        self.streaming_content = None;
        *self.stream_cache.borrow_mut() = None;
        self.stream_renderer.borrow_mut().reset();
        self.last_agent_text = None;
        self.last_user_text = None;
        self.scrollback_started = false;
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
        // A width change (only caller: `set_size`) invalidates the stream cache
        // too; the width key would force a rebuild anyway, but clear it eagerly.
        *self.stream_cache.borrow_mut() = None;
    }

    /// Render the live streaming preview, bottom-anchored so the newest lines
    /// stay visible. When idle, the region is left blank (finalized content lives
    /// in the terminal's native scrollback).
    pub fn draw_live(&self, frame: &mut Frame, area: Rect) {
        if area.height == 0 || area.width == 0 {
            return;
        }
        if self.ensure_stream_cache(area.width).is_some() {
            // One clone of the cached body per frame (O(lines), not a re-parse);
            // height comes straight from the cache so it can't drift from draw.
            let (body, full_h) = {
                let cache = self.stream_cache.borrow();
                let c = cache.as_ref().expect("cache populated by ensure_stream_cache");
                (c.body.clone(), c.height)
            };
            let msg = Message::new_agent_prerendered(body);
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

#[cfg(test)]
mod spacing_tests {
    use super::*;

    #[test]
    fn blocks_get_single_blank_spacer_between_them() {
        let mut chat = Chat::new();
        chat.add_user_message("hi");
        chat.add_agent_message("hello", None);
        let msgs = chat.drain_scrollback();
        assert_eq!(msgs.len(), 3, "user, spacer, agent");
        assert!(matches!(msgs[0].msg_type, MessageType::User));
        assert_eq!(msgs[1].height(80), 1, "spacer is exactly one blank row");
        assert!(matches!(msgs[2].msg_type, MessageType::Agent));
    }

    #[test]
    fn first_block_has_no_leading_spacer() {
        let mut chat = Chat::new();
        chat.add_agent_message("hello", None);
        assert_eq!(chat.drain_scrollback().len(), 1);
    }

    #[test]
    fn clear_resets_spacing_state() {
        let mut chat = Chat::new();
        chat.add_user_message("hi");
        chat.clear();
        chat.add_user_message("again");
        assert_eq!(chat.drain_scrollback().len(), 1, "no spacer after clear");
    }
}

#[cfg(test)]
mod stream_cache_tests {
    use super::*;

    #[test]
    fn empty_stream_has_zero_height() {
        let chat = Chat::new();
        assert_eq!(chat.streaming_height(80), 0);
        assert!(chat.stream_cache.borrow().is_none());
    }

    #[test]
    fn streaming_height_is_stable_and_cached() {
        let mut chat = Chat::new();
        chat.update_streaming("hello world");
        let h1 = chat.streaming_height(80);
        let h2 = chat.streaming_height(80);
        assert_eq!(h1, h2);
        assert!(h1 >= 2, "label row + at least one body row");
        let cache = chat.stream_cache.borrow();
        let cached = cache.as_ref().expect("cache populated after render");
        assert_eq!(cached.content_len, "hello world".len());
        assert_eq!(cached.width, 80);
        assert_eq!(cached.height, h1);
    }

    #[test]
    fn cache_rebuilds_when_content_grows() {
        let mut chat = Chat::new();
        chat.update_streaming("a");
        let _ = chat.streaming_height(80);
        let grown = "a much longer streamed reply that will wrap across several rows";
        chat.update_streaming(grown);
        let _ = chat.streaming_height(80);
        assert_eq!(
            chat.stream_cache.borrow().as_ref().unwrap().content_len,
            grown.len(),
            "cache re-parses when the streaming buffer grows"
        );
    }

    #[test]
    fn cache_rebuilds_on_width_change() {
        let mut chat = Chat::new();
        chat.update_streaming("some streamed text that wraps differently at narrow widths");
        let _ = chat.streaming_height(80);
        let _ = chat.streaming_height(20);
        assert_eq!(chat.stream_cache.borrow().as_ref().unwrap().width, 20);
    }

    #[test]
    fn clear_streaming_drops_cache() {
        let mut chat = Chat::new();
        chat.update_streaming("hi");
        let _ = chat.streaming_height(80);
        assert!(chat.stream_cache.borrow().is_some());
        chat.clear_streaming();
        assert_eq!(chat.streaming_height(80), 0);
        assert!(chat.stream_cache.borrow().is_none());
    }

    #[test]
    fn update_streaming_reuses_allocation() {
        let mut chat = Chat::new();
        chat.update_streaming("a");
        let cap_before = chat
            .streaming_content
            .as_ref()
            .map(|s| s.capacity())
            .unwrap_or(0);
        // Same-length replacement must not allocate a new String.
        chat.update_streaming("b");
        let cap_after = chat
            .streaming_content
            .as_ref()
            .map(|s| s.capacity())
            .unwrap_or(0);
        assert!(cap_after >= cap_before);
        assert_eq!(chat.streaming_content.as_deref(), Some("b"));
    }
}
