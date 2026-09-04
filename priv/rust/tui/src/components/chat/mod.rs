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
pub mod wrap_count;

use std::cell::RefCell;

use ratatui::prelude::*;

use crate::client::types::Signal;
use crate::event::Event;

use super::{Component, ComponentAction};
use message::{Message, MessageType, SurveyQAData, ToolCallData};

/// Cached parse of the in-flight streaming reply. See `Chat::stream_cache`.
struct StreamCache {
    /// `Chat::stream_gen` at the moment this cache was parsed.
    ///
    /// This used to be the streaming buffer's byte LENGTH, on the premise that
    /// "the buffer only ever grows within a turn". `update_streaming` does not
    /// grow it — it takes a full replacement string and rewrites the buffer in
    /// place, so any same-length rewrite (a retry that re-sends a corrected
    /// reply, an edit-in-place delta, a resumed stream restating its tail)
    /// keyed identically and served a STALE body. And because the cache hit,
    /// `StreamingRenderer::update`'s own prefix check never ran to catch the
    /// divergence. A generation counter bumped by every mutation of
    /// `streaming_content` identifies the content instead of guessing at it.
    generation: u64,
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
    /// Bumped by every mutation of `streaming_content`. The `stream_cache` key,
    /// so a rewrite that happens to preserve the byte length still misses.
    stream_gen: u64,
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
    /// True once the first conversation turn has begun (first user message
    /// enqueued). Gates the turn separator so none is emitted before the first
    /// turn — a separator is inserted only when a NEW user message opens a turn
    /// while a previous turn already exists.
    turn_started: bool,
    /// Appearance flag: draw an understated dim rule between conversation turns.
    /// Default on; `set_turn_separators(false)` suppresses them entirely.
    turn_separators: bool,
    /// True when the block most recently queued for scrollback was an assistant
    /// prose *chunk* (see [`Chat::add_agent_chunk`]), so the next chunk of the
    /// same message continues it directly with no CC margin. Cleared by every
    /// ordinary block push, so a tool cell landing between two chunks correctly
    /// re-opens the margin.
    agent_flow_open: bool,
    /// Lean view (`/lean`): keep tool cells out of the terminal's native
    /// scrollback so the printed conversation is the model's prose, and its
    /// reasoning, and nothing else. Presentation only — nothing about the turn
    /// changes, the tools still run, and every suppressed cell is still handed
    /// to `transcript_log` through [`Chat::drain_hidden`].
    lean: bool,
    /// Tool cells suppressed by `lean`, awaiting the app loop. They are
    /// drained into the transcript log (ctrl+o) and then dropped, never printed.
    ///
    /// A separate lane rather than a `hidden` flag on `Message` because the
    /// suppression has to happen at PUSH time, not at print time: every block
    /// queued for scrollback is preceded by a blank margin row
    /// ([`Chat::push_scrollback_block`]), and a cell filtered out later would
    /// leave its margin behind as a stray blank line.
    hidden: Vec<Message>,
    /// Tool cells suppressed since the last [`Chat::take_hidden_count`]. Drives
    /// the one-line "N tool calls hidden" receipt at turn end — total silence
    /// while a 60-turn task runs would read as a hang.
    hidden_count: usize,
    /// Monotonic count of blocks that have reached the user's screen.
    ///
    /// Bumped at the two — and only two — places a block is queued for
    /// scrollback, so it is an exact answer to "has anything become visible?"
    /// rather than a flag each caller has to remember to set.
    emitted: u64,
    /// Value of `emitted` at the moment the CURRENT turn's user message was
    /// pushed. Everything after it is this turn's output.
    ///
    /// The mark is taken inside [`Chat::add_user_message`] rather than by the
    /// app, because every submit path in the TUI — typed prompt, queued
    /// message, slash command, resumed draft — opens its turn by echoing the
    /// user's line through that one function. Anchoring it there means a new
    /// submit path cannot be added that forgets to arm it.
    turn_output_mark: u64,
}

impl Chat {
    pub fn new() -> Self {
        Self {
            messages: Vec::new(),
            scrollback: Vec::new(),
            width: 80,
            height: 20,
            streaming_content: None,
            stream_gen: 0,
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
            turn_started: false,
            turn_separators: true,
            agent_flow_open: false,
            lean: false,
            hidden: Vec::new(),
            hidden_count: 0,
            emitted: 0,
            turn_output_mark: 0,
        }
    }

    /// Whether the current turn has put ANYTHING on the user's screen since
    /// their message opened it — assistant prose, a tool cell, a system line.
    ///
    /// The one question that separates "the turn answered" from "the turn
    /// ended and the screen is exactly as the user left it". A turn for which
    /// this is false, and which then renders nothing at its end, is
    /// indistinguishable from a keypress the app threw away.
    ///
    /// A tool cell hidden by the lean view counts: the user chose to hide it,
    /// and the "N tool calls hidden" receipt tells them it happened.
    pub fn turn_produced_output(&self) -> bool {
        self.emitted > self.turn_output_mark || self.hidden_count > 0
    }

    // ── Lean view (`/lean`) ───────────────────────────────────────────

    /// Turn the lean view on or off.
    ///
    /// Takes effect on the next block queued for scrollback. Rows already handed
    /// to `insert_before` are frozen in the terminal's own history at the width
    /// they were wrapped at and cannot be un-printed, so this can never be
    /// retroactive — which is why the command's confirmation says "from here on"
    /// rather than implying a redraw.
    pub fn set_lean(&mut self, on: bool) {
        self.lean = on;
    }

    /// Whether the lean view is active.
    pub fn lean(&self) -> bool {
        self.lean
    }

    /// Suppressed tool cells, for the transcript log. Drained by the app loop in
    /// the same pass as [`Chat::drain_scrollback`], and BEFORE it, so the log
    /// keeps the order the work happened in.
    pub fn drain_hidden(&mut self) -> Vec<Message> {
        std::mem::take(&mut self.hidden)
    }

    /// How many tool cells have been suppressed since this was last called.
    pub fn take_hidden_count(&mut self) -> usize {
        std::mem::take(&mut self.hidden_count)
    }

    /// Toggle the turn-separator appearance flag. Returns the new state.
    pub fn set_turn_separators(&mut self, on: bool) {
        self.turn_separators = on;
    }

    /// Whether turn separators are currently drawn between turns.
    pub fn turn_separators_enabled(&self) -> bool {
        self.turn_separators
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

    /// Invalidate every width-keyed render cache (per-message wrapped-height
    /// cache + the live streaming markdown cache) so nothing re-renders at a
    /// stale width after a terminal resize. `set_size` already does this, but
    /// the resize path calls it explicitly so the width-reflow intent does not
    /// silently depend on `set_size`'s internals.
    pub fn invalidate_width_caches(&mut self) {
        self.invalidate_cache();
    }

    // ── Enqueue helpers (all route to native scrollback) ──────────────

    /// Queue a finalized block for native scrollback with CC-style spacing:
    /// exactly one blank line before every block except the very first
    /// (Claude Code's `addMargin` / `marginTop={1}`).
    fn push_scrollback_block(&mut self, msg: Message) {
        // Lean view: a tool cell is diverted BEFORE the margin row is
        // emitted, so nothing about it reaches the terminal — not the cell, not
        // the blank line it would have been given. `agent_flow_open` is still
        // cleared, so two prose chunks separated by a hidden tool keep the same
        // block structure they have with the tool visible; joining them would
        // weld two assistant messages into one paragraph.
        //
        // The predicate is deliberately narrow: ONLY a tool cell. Errors and
        // turn failures are `SystemError`, loop-guard and control text is
        // `SystemWarning` (the `Loop.TerminalSource` distinction), and a
        // permission prompt is not a message at all — it is an overlay drawn
        // into the stream band. None of them can reach this branch, so no
        // setting of this flag can swallow them.
        if self.lean
            && matches!(msg.msg_type, MessageType::ToolCall)
            && !msg.is_turn_separator()
        {
            self.agent_flow_open = false;
            self.hidden_count += 1;
            self.hidden.push(msg);
            return;
        }
        self.emitted += 1;
        if self.scrollback_started {
            self.scrollback.push(Message::new_tool_call(ToolCallData {
                name: String::new(),
                tool_call_id: None,
                args: String::new(),
                result: String::new(),
                duration_ms: 0,
                success: true,
                expanded: false,
                hook_runs: Default::default(),
                lines: vec![Line::from("")],
            }));
        }
        self.scrollback_started = true;
        self.scrollback.push(msg);
        self.has_messages = true;
        self.agent_flow_open = false;
    }

    /// Queue one **chunk** of an assistant message that is flowing into
    /// scrollback as it completes, rather than all at once at turn end.
    ///
    /// `content` is kept VERBATIM — including the blank line that terminates the
    /// markdown block — because the chunk boundary is a proven safe split point
    /// (`render::markdown_stream::find_frozen_boundary`), for which
    /// `render(a) ++ render(b) == render(a ++ b)` byte for byte. Trimming it, or
    /// inserting the CC margin the way an independent block gets one, would both
    /// break that equality. The margin is therefore emitted only for the chunk
    /// that OPENS the flow.
    ///
    /// `header` draws the "◈ OSA" label; only the first block of a turn gets it.
    pub fn add_agent_chunk(&mut self, content: &str, header: bool, signal: Option<&Signal>) {
        if self.agent_flow_open {
            let joined = match self.last_agent_text.take() {
                Some(mut prev) => {
                    prev.push_str(content);
                    prev
                }
                None => content.to_string(),
            };
            self.last_agent_text = Some(joined);
        } else {
            self.last_agent_text = Some(content.to_string());
        }
        let mut msg = Message::new(
            if header {
                MessageType::Agent
            } else {
                MessageType::AgentContinuation
            },
            content.to_string(),
            signal.cloned(),
        );
        msg.set_raw_mode(self.raw_view);
        if self.agent_flow_open && !header {
            self.scrollback_started = true;
            self.emitted += 1;
            self.scrollback.push(msg);
            self.has_messages = true;
        } else {
            self.push_scrollback_block(msg);
        }
        self.agent_flow_open = true;
    }

    /// Close an open chunk flow: the last chunk still carries the blank line
    /// that separated it from the block that never came, which would leave the
    /// finished message sitting on a spare row. Drop it.
    ///
    /// Only reaches a chunk still queued — one already drained into the
    /// terminal's native scrollback is, by construction, immutable.
    pub fn end_agent_chunk_flow(&mut self) {
        if !self.agent_flow_open {
            return;
        }
        self.agent_flow_open = false;
        if let Some(last) = self.scrollback.last_mut() {
            if matches!(
                last.msg_type,
                MessageType::Agent | MessageType::AgentContinuation
            ) {
                let trimmed = last.content.trim_end();
                if trimmed.len() != last.content.len() {
                    last.content.truncate(trimmed.len());
                    last.invalidate_cache();
                }
            }
        }
    }

    pub fn add_user_message(&mut self, content: &str) {
        self.last_user_text = Some(content.to_string());
        // A new user message opens a turn. If a previous turn already exists,
        // mark the boundary with an understated dim rule (never before the first
        // turn). The separator is a normal scrollback block, so `height()` and
        // the drain/insert_before path treat it like any other line.
        if self.turn_separators && self.turn_started {
            self.push_scrollback_block(Message::new_turn_separator());
        }
        self.turn_started = true;
        self.push_scrollback_block(Message::new(MessageType::User, content.to_string(), None));
        // Arm the per-turn output mark AFTER the echo, so the user's own line
        // never counts as the turn answering them. See `turn_produced_output`.
        self.turn_output_mark = self.emitted;
    }

    /// Echo a user message injected MID-TURN (a send-now steer) into the
    /// transcript. Unlike [`add_user_message`], this does NOT open a new turn or
    /// re-arm the per-turn output mark: the turn is already running, and
    /// re-arming would make output the agent has already produced stop counting,
    /// so a later empty `agent_response` would misclassify as a silent turn and
    /// print a spurious "turn ended with no answer" notice.
    pub fn add_midturn_user_message(&mut self, content: &str) {
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

    /// Push an `Updated plan` snapshot cell into scrollback. `body` is the frozen
    /// styled checklist; `plain` is its plain-text form for the transcript log.
    pub fn add_plan_snapshot(&mut self, body: Text<'static>, plain: String) {
        self.push_scrollback_block(Message::new_plan(body, plain));
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
            tool_call_id: None,
            args: String::new(),
            result: String::new(),
            duration_ms: 0,
            success: true,
            expanded: false,
            hook_runs: Default::default(),
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
            cached_height: std::cell::Cell::new(None),
            timestamp: None,
            prerendered_body: None,
            raw_mode: false,
        });
    }

    /// Attach result data to the tool cell this result BELONGS to, and re-render
    /// its collapsed summary so line-count info appears.
    ///
    /// `id` is the backend's per-call `tool_call_id`. When present it is the
    /// only thing matched on — tools run concurrently and every shell call is
    /// named `shell_execute`, so a name scan hands `df`'s output to the cell
    /// showing `du`'s command whenever completions land out of order.
    /// `None` (older backend that does not emit the id) falls back to the legacy
    /// newest-first name scan.
    ///
    /// Must use the SAME selection rule as [`Self::finalize_tool`], or the cell
    /// that receives the result and the cell flushed to scrollback differ.
    pub fn update_last_tool_result(&mut self, tool_name: &str, id: Option<&str>, result: &str) {
        let width = self.width;
        for msg in self.messages.iter_mut().rev() {
            if let Some(ref mut td) = msg.tool_data {
                let matches = match id {
                    Some(id) => td.tool_call_id.as_deref() == Some(id),
                    None => td.name == tool_name && td.result.is_empty(),
                };
                if matches {
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
                    // The cell was rebuilt from scratch — re-attach the hook
                    // bracket, which lives on the cell precisely because every
                    // re-render would otherwise drop it.
                    self::message::append_hook_bracket(&mut td.lines, td.hook_runs);
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
                self::message::append_hook_bracket(&mut td.lines, td.hook_runs);
                msg.invalidate_cache();
                break;
            }
        }
    }

    /// U-B2 — whether the most recent live-tail tool call is currently collapsed
    /// (i.e. `Ctrl+O` / `chat:expandTools` has something to expand right now).
    /// Only in-progress tool messages in `messages` are expandable; once
    /// finalized into native scrollback a tool call becomes static, so this
    /// returns `false` for them. Used to make Ctrl+O expand the last tool result
    /// FIRST and only open the transcript reader when nothing is expandable.
    pub(crate) fn has_expandable_last_tool(&self) -> bool {
        self.messages
            .iter()
            .rev()
            .find_map(|m| m.tool_data.as_ref())
            .map_or(false, |td| !td.expanded)
    }

    /// Finalize the in-progress tool call this result belongs to into scrollback.
    ///
    /// Keys off `tool_call_id` when the backend sent one. The legacy fallback
    /// searches OLDEST-first by name, which is what
    /// [`Self::update_last_tool_result`]'s legacy fallback pairs with only when
    /// a single same-named call is in flight; with the id both sides select the
    /// exact same cell, so the cell that got the result is the cell that is
    /// flushed.
    pub fn finalize_tool(&mut self, name: &str, id: Option<&str>) {
        let idx = match id {
            Some(id) => self.messages.iter().position(|m| {
                m.tool_data
                    .as_ref()
                    .map_or(false, |t| t.tool_call_id.as_deref() == Some(id))
            }),
            None => self
                .messages
                .iter()
                .position(|m| m.tool_data.as_ref().map_or(false, |t| t.name == name)),
        };
        if let Some(idx) = idx {
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

    pub(crate) fn pending_scrollback(&self) -> &[Message] {
        &self.scrollback
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
        self.stream_gen = self.stream_gen.wrapping_add(1);
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
        self.stream_gen = self.stream_gen.wrapping_add(1);
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
        let generation = self.stream_gen;

        {
            let cache = self.stream_cache.borrow();
            if let Some(c) = cache.as_ref() {
                if c.generation == generation && c.width == width {
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
            generation,
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
        self.stream_gen = self.stream_gen.wrapping_add(1);
        self.streaming_content = None;
        *self.stream_cache.borrow_mut() = None;
        self.stream_renderer.borrow_mut().reset();
        self.last_agent_text = None;
        self.last_user_text = None;
        self.scrollback_started = false;
        self.turn_started = false;
        self.agent_flow_open = false;
        // `/clear` drops the suppressed cells with everything else: they exist
        // only to feed a transcript log that is being cleared in the same
        // breath, and a count carried across the boundary would report work
        // from a conversation that no longer exists.
        self.hidden.clear();
        self.hidden_count = 0;
    }

    pub fn last_agent_message(&self) -> Option<String> {
        self.last_agent_text.clone()
    }

    /// Every assistant block committed to scrollback, in order — the text the
    /// user actually ends up reading. Lets a test assert what was rendered
    /// rather than what some intermediate buffer happened to hold.
    #[cfg(test)]
    pub(crate) fn agent_blocks(&self) -> Vec<String> {
        self.scrollback
            .iter()
            .filter(|m| {
                matches!(
                    m.msg_type,
                    MessageType::Agent | MessageType::AgentContinuation
                )
            })
            .map(|m| m.content.clone())
            .collect()
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
    ///
    /// `header` draws the "◈ OSA" label. Pass false once this turn has already
    /// committed a block to scrollback: that block carries the one label the
    /// answer is owed, and a second one under it reads as two separate replies
    /// split mid-sentence. The label also occupies a row, so its absence shortens
    /// the preview by one — `ensure_stream_cache` counts it unconditionally.
    pub fn draw_live(&self, frame: &mut Frame, area: Rect, header: bool) {
        if area.height == 0 || area.width == 0 {
            return;
        }
        if self.ensure_stream_cache(area.width).is_some() {
            // **Only the rows that will be on screen are built.**
            //
            // This used to clone the WHOLE cached body every frame and then hand
            // it to `draw_scrolled`, which laid out every line and scrolled to the
            // tail — two O(total answer) costs to paint ~10 rows, plus a third
            // clone inside `draw_agent`. Measured in `draw_live_cost_curve`: 1.1ms
            // per frame at 50 lines, 3.2ms at 200, 11.8ms at 800 — a curve, so the
            // TUI got slower the longer the model talked, and every keystroke
            // queued behind a frame inherited it.
            //
            // The preview is bottom-anchored, so the visible rows are always the
            // LAST `h`. Slicing to them first makes the per-frame cost O(visible
            // rows) and independent of the answer's length.
            let (body, full_h, scroll) = {
                let cache = self.stream_cache.borrow();
                let c = cache.as_ref().expect("cache populated by ensure_stream_cache");
                // `c.height` counts the label row; a continuation preview draws
                // no label, so it is exactly one row shorter.
                let full_h = if header {
                    c.height
                } else {
                    c.height.saturating_sub(1).max(1)
                };
                let h = full_h.min(area.height);
                if full_h > area.height {
                    // Taller than the slot: the "◈ OSA" label (message line 0) is
                    // scrolled off, so the visible rows are exactly the last `h`
                    // body lines. `scroll_top = 1` is what tells `draw_agent` the
                    // label is above the viewport; the body itself then starts at
                    // its own line 0, which is where the slice begins.
                    let start = c.body.lines.len().saturating_sub(h as usize);
                    (
                        Text::from(c.body.lines[start..].to_vec()),
                        full_h,
                        if header { 1u16 } else { 0u16 },
                    )
                } else {
                    // Fits: the label is drawn and the whole (short) body shows.
                    (c.body.clone(), full_h, 0u16)
                }
            };
            let msg = Message::new_agent_prerendered(body, header);
            let h = full_h.min(area.height);
            let y = area.y + area.height.saturating_sub(h);
            msg.draw_scrolled(frame, Rect::new(area.x, y, area.width, h), scroll);
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
        self.draw_live(frame, area, true);
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
mod turn_separator_tests {
    use super::*;

    fn sep_count(msgs: &[Message]) -> usize {
        msgs.iter().filter(|m| m.is_turn_separator()).count()
    }

    #[test]
    fn two_turns_get_exactly_one_separator_none_before_first() {
        let mut chat = Chat::new();
        // Turn 1
        chat.add_user_message("q1");
        chat.add_agent_message("a1", None);
        // Turn 2 — opening this turn inserts the separator.
        chat.add_user_message("q2");
        chat.add_agent_message("a2", None);

        let msgs = chat.drain_scrollback();
        assert_eq!(sep_count(&msgs), 1, "exactly one separator between two turns");
        // No separator before the first turn: the first block is the user message.
        assert!(!msgs[0].is_turn_separator());
        assert!(matches!(msgs[0].msg_type, MessageType::User));
        // The separator precedes the second turn's user message.
        let sep_idx = msgs.iter().position(|m| m.is_turn_separator()).unwrap();
        let next_user = msgs[sep_idx + 1..]
            .iter()
            .any(|m| matches!(m.msg_type, MessageType::User));
        assert!(next_user, "separator sits before the next turn's user message");
    }

    #[test]
    fn single_turn_has_no_separator() {
        let mut chat = Chat::new();
        chat.add_user_message("q1");
        chat.add_agent_message("a1", None);
        assert_eq!(sep_count(&chat.drain_scrollback()), 0);
    }

    #[test]
    fn three_turns_get_two_separators() {
        let mut chat = Chat::new();
        for i in 0..3 {
            chat.add_user_message(&format!("q{i}"));
            chat.add_agent_message(&format!("a{i}"), None);
        }
        assert_eq!(sep_count(&chat.drain_scrollback()), 2);
    }

    #[test]
    fn separator_is_a_single_row() {
        let mut chat = Chat::new();
        chat.add_user_message("q1");
        chat.add_agent_message("a1", None);
        chat.add_user_message("q2");
        let msgs = chat.drain_scrollback();
        let sep = msgs.iter().find(|m| m.is_turn_separator()).unwrap();
        // Height must be exactly one row at any width so the height cache stays
        // consistent with what draw_turn_separator renders.
        assert_eq!(sep.height(80), 1);
        assert_eq!(sep.height(1), 1);
    }

    #[test]
    fn toggle_off_disables_separators() {
        let mut chat = Chat::new();
        chat.set_turn_separators(false);
        assert!(!chat.turn_separators_enabled());
        chat.add_user_message("q1");
        chat.add_agent_message("a1", None);
        chat.add_user_message("q2");
        assert_eq!(sep_count(&chat.drain_scrollback()), 0);
    }

    #[test]
    fn clear_resets_turn_tracking() {
        let mut chat = Chat::new();
        chat.add_user_message("q1");
        chat.add_agent_message("a1", None);
        chat.clear();
        // After clear the next user message opens the first turn again — no sep.
        chat.add_user_message("q2");
        assert_eq!(sep_count(&chat.drain_scrollback()), 0);
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
        assert_eq!(cached.generation, chat.stream_gen);
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
            chat.stream_cache.borrow().as_ref().unwrap().generation,
            chat.stream_gen,
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

    /// The rendered body of a rendered line, flattened.
    fn cached_body(chat: &Chat, width: u16) -> String {
        let _ = chat.streaming_height(width);
        let cache = chat.stream_cache.borrow();
        let c = cache.as_ref().expect("cache populated");
        c.body
            .lines
            .iter()
            .map(|l| l.spans.iter().map(|s| s.content.as_ref()).collect::<String>())
            .collect::<Vec<_>>()
            .join("\n")
    }

    /// A same-length rewrite of the streaming buffer must not be served from
    /// cache.
    ///
    /// The cache was keyed on `(content.len(), width)`, so a replacement of the
    /// same byte length hit and returned the PREVIOUS body — and because it
    /// hit, `StreamingRenderer::update`'s prefix check never ran to notice the
    /// divergence. `update_streaming` takes a whole replacement string, so this
    /// is reachable from any retry, correction or resumed stream that restates
    /// its tail at the same length.
    #[test]
    fn same_length_rewrite_is_not_served_from_a_stale_cache() {
        let mut chat = Chat::new();
        chat.update_streaming("the build is green");
        let first = cached_body(&chat, 80);
        assert!(first.contains("green"), "{first:?}");

        // Same byte length, completely different text.
        chat.update_streaming("the build is BROKE");
        let second = cached_body(&chat, 80);
        assert!(
            second.contains("BROKE"),
            "stale body served for a same-length rewrite: {second:?}"
        );
        assert!(
            !second.contains("green"),
            "the superseded text survived in the cache: {second:?}"
        );
    }

    /// The cache must still HIT when nothing changed — the whole point of it is
    /// to keep `draw_live` and `streaming_height` from parsing twice per frame.
    #[test]
    fn unchanged_content_still_hits_the_cache() {
        let mut chat = Chat::new();
        chat.update_streaming("stable text");
        let _ = chat.streaming_height(80);
        let gen_after_first = chat.stream_cache.borrow().as_ref().unwrap().generation;
        // Three more measurement passes, no mutation in between.
        let _ = chat.streaming_height(80);
        let _ = chat.streaming_height(80);
        let _ = chat.streaming_height(80);
        assert_eq!(
            chat.stream_cache.borrow().as_ref().unwrap().generation,
            gen_after_first,
            "the cache was rebuilt even though the content never changed"
        );
    }
}

/// Regression: results must land in the cell of the call they belong to.
///
/// Tools run CONCURRENTLY (`tool_orchestrator` runs up to 10 in parallel) and
/// every shell call is named `shell_execute`, so completions routinely land out
/// of order. Pairing by tool NAME + "most recent cell with an empty result"
/// therefore showed one command's output under a DIFFERENT command's args.
///
/// A second, independent bug lived in the same pair of functions:
/// `update_last_tool_result` scanned NEWEST-first (`.rev()`) while
/// `finalize_tool` scanned OLDEST-first (`.position()`), so even the cell that
/// received the result and the cell flushed to scrollback could differ. Both
/// now key off `tool_call_id`.
#[cfg(test)]
mod concurrent_tool_pairing_tests {
    use super::*;
    use ratatui::text::Line;

    const DU: &str = r#"{"command":"du -sh ."}"#;
    const DF: &str = r#"{"command":"df -h"}"#;

    fn shell_cell(id: Option<&str>, args: &str) -> ToolCallData {
        ToolCallData {
            name: "shell_execute".to_string(),
            tool_call_id: id.map(str::to_string),
            args: args.to_string(),
            result: String::new(),
            duration_ms: 0,
            success: true,
            expanded: false,
            hook_runs: Default::default(),
            lines: vec![Line::from(args.to_string())],
        }
    }

    /// Every finalized cell that carries a call id, as (args, result).
    fn finalized(chat: &mut Chat) -> Vec<(String, String)> {
        chat.drain_scrollback()
            .iter()
            .filter_map(|m| m.tool_data.as_ref())
            .filter(|td| td.tool_call_id.is_some())
            .map(|td| (td.args.clone(), td.result.clone()))
            .collect()
    }

    #[test]
    fn out_of_order_results_land_in_their_own_cell() {
        let mut chat = Chat::new();
        // Two concurrent shell calls — SAME tool name, different commands.
        chat.add_tool_message_rich(shell_cell(Some("call_du"), DU));
        chat.add_tool_message_rich(shell_cell(Some("call_df"), DF));

        // Results arrive in REVERSE order (df finished first).
        chat.update_last_tool_result("shell_execute", Some("call_df"), "df says: 42G free");
        chat.finalize_tool("shell_execute", Some("call_df"));
        chat.update_last_tool_result("shell_execute", Some("call_du"), "du says: 7.1M .");
        chat.finalize_tool("shell_execute", Some("call_du"));

        // Nothing left in flight — both cells reached scrollback.
        assert!(chat.messages.is_empty(), "both cells must be finalized");

        let cells = finalized(&mut chat);
        assert_eq!(cells.len(), 2, "one scrollback cell per call: {cells:?}");

        // Each cell shows ITS OWN command's output. Before the fix the df result
        // attached to the du cell (newest-empty scan) and, worse, finalize_tool
        // then flushed the du cell (oldest-first scan) for the df result.
        for (args, result) in &cells {
            if args.contains("du -sh") {
                assert_eq!(result, "du says: 7.1M .", "du cell got the wrong result");
            } else if args.contains("df -h") {
                assert_eq!(result, "df says: 42G free", "df cell got the wrong result");
            } else {
                panic!("unexpected cell args: {args}");
            }
        }
    }

    #[test]
    fn update_and_finalize_select_the_same_cell() {
        // The independent bug: `.rev()` (newest) vs `.position()` (oldest).
        // With three same-name calls in flight, the result written by
        // `update_last_tool_result` must be on the cell `finalize_tool` flushes.
        let mut chat = Chat::new();
        chat.add_tool_message_rich(shell_cell(Some("a"), r#"{"command":"one"}"#));
        chat.add_tool_message_rich(shell_cell(Some("b"), r#"{"command":"two"}"#));
        chat.add_tool_message_rich(shell_cell(Some("c"), r#"{"command":"three"}"#));

        // Middle call completes first.
        chat.update_last_tool_result("shell_execute", Some("b"), "TWO-RESULT");
        chat.finalize_tool("shell_execute", Some("b"));

        let cells = finalized(&mut chat);
        assert_eq!(cells.len(), 1, "only the completed call is flushed");
        assert!(
            cells[0].0.contains("two"),
            "the flushed cell must be the one that got the result, got {cells:?}"
        );
        assert_eq!(cells[0].1, "TWO-RESULT");
        // The other two are still in flight, still empty.
        assert_eq!(chat.messages.len(), 2);
        assert!(chat.messages.iter().all(|m| m
            .tool_data
            .as_ref()
            .map_or(false, |td| td.result.is_empty())));
    }

    #[test]
    fn legacy_name_matching_still_works_without_an_id() {
        // An older backend emits no tool_call_id — the name-based path must
        // still attach and finalize, so a new TUI keeps working against it.
        let mut chat = Chat::new();
        chat.add_tool_message_rich(shell_cell(None, DU));
        chat.update_last_tool_result("shell_execute", None, "du output");
        chat.finalize_tool("shell_execute", None);

        assert!(chat.messages.is_empty());
        let cells: Vec<_> = chat
            .drain_scrollback()
            .iter()
            .filter_map(|m| m.tool_data.as_ref())
            .filter(|td| td.name == "shell_execute")
            .map(|td| td.result.clone())
            .collect();
        assert_eq!(cells, vec!["du output".to_string()]);
    }

    #[test]
    fn a_result_for_an_unknown_id_touches_nothing() {
        // A stray/duplicated result must never fall back to "some other cell".
        let mut chat = Chat::new();
        chat.add_tool_message_rich(shell_cell(Some("call_du"), DU));
        chat.update_last_tool_result("shell_execute", Some("call_gone"), "orphan");
        chat.finalize_tool("shell_execute", Some("call_gone"));

        assert_eq!(chat.messages.len(), 1, "the live cell must not be flushed");
        assert!(chat.messages[0]
            .tool_data
            .as_ref()
            .map_or(false, |td| td.result.is_empty()));
    }
}

/// The lean view (`/lean`) — what it removes, and what it must never
/// be able to remove.
///
/// The value of the mode is entirely in the second half. A flag that suppresses
/// output is one mistake away from suppressing an approval request, and a
/// session parked on a permission prompt nobody can see is unrecoverable — the
/// exact failure this codebase spent a session removing. So these tests pin the
/// negative space: errors, loop-guard/control text and system notices go through
/// `add_system_message` and stay, turn separators stay, and the suppressed tool
/// cells are still handed over for the ctrl+o transcript rather than dropped.
///
/// Permission prompts are not tested here because they are not messages at all
/// (`dialogs::permissions` draws into the stream band); the structural fact that
/// they never touch `Chat` is what makes them unhidable. The PTY suite asserts
/// that end of it against the real binary.
#[cfg(test)]
mod lean_view_tests {
    use super::*;
    use ratatui::text::Line;

    fn tool(name: &str) -> ToolCallData {
        ToolCallData {
            name: name.to_string(),
            tool_call_id: Some(name.to_string()),
            args: String::new(),
            result: String::new(),
            duration_ms: 0,
            success: true,
            expanded: false,
            hook_runs: Default::default(),
            lines: vec![Line::from(format!("{name} ran"))],
        }
    }

    /// Every block queued for the terminal, as a coarse kind label.
    fn printed(chat: &mut Chat) -> Vec<&'static str> {
        chat.drain_scrollback()
            .iter()
            .map(|m| match m.msg_type {
                MessageType::User => "user",
                MessageType::Agent | MessageType::AgentContinuation => "agent",
                MessageType::SystemError => "error",
                MessageType::SystemWarning => "warning",
                MessageType::SystemInfo => "info",
                MessageType::ToolCall if m.is_turn_separator() => "separator",
                // The CC margin row rides the same carrier as a tool cell, with
                // no tool name. It is spacing, not content.
                MessageType::ToolCall
                    if m.tool_data.as_ref().map_or(true, |t| t.name.is_empty()) =>
                {
                    "margin"
                }
                MessageType::ToolCall => "tool",
                _ => "other",
            })
            .collect()
    }

    #[test]
    fn tool_cells_do_not_reach_the_terminal() {
        let mut chat = Chat::new();
        chat.set_lean(true);
        chat.add_user_message("go");
        chat.add_tool_message_rich(tool("shell_execute"));
        chat.finalize_tool("shell_execute", Some("shell_execute"));
        chat.add_agent_message("here is what I found", None);

        assert_eq!(
            printed(&mut chat),
            vec!["user", "margin", "agent"],
            "a tool cell reached native scrollback with the lean view on"
        );
    }

    /// The margin row goes with the cell. `push_scrollback_block` emits one blank
    /// line before every block, so a cell filtered out anywhere downstream would
    /// leave its blank line stranded — a lean view that accumulates a gap per
    /// hidden tool is not a cleaner screen, it is a gappier one.
    #[test]
    fn a_hidden_tool_leaves_no_blank_row_behind() {
        let mut chat = Chat::new();
        chat.set_lean(true);
        chat.add_agent_message("first", None);
        for n in 0..5 {
            let name = format!("t{n}");
            chat.add_tool_message_rich(tool(&name));
            chat.finalize_tool(&name, Some(&name));
        }
        chat.add_agent_message("second", None);

        // Two prose blocks and exactly ONE margin row between them, which is what
        // two adjacent blocks get with no tools involved at all.
        let blocks = chat.drain_scrollback();
        assert_eq!(
            blocks.len(),
            3,
            "expected agent + margin + agent, got {} blocks",
            blocks.len()
        );
    }

    /// Nothing is lost, only unprinted. The suppressed cells are handed to the
    /// caller for `transcript_log`, which is what ctrl+o reads.
    #[test]
    fn hidden_tools_are_still_handed_over_for_the_transcript() {
        let mut chat = Chat::new();
        chat.set_lean(true);
        chat.add_tool_message_rich(tool("read_file"));
        chat.finalize_tool("read_file", Some("read_file"));

        let hidden = chat.drain_hidden();
        assert_eq!(hidden.len(), 1, "the suppressed cell was dropped outright");
        assert_eq!(
            hidden[0].tool_data.as_ref().map(|t| t.name.as_str()),
            Some("read_file")
        );
        assert!(
            chat.drain_hidden().is_empty(),
            "drain_hidden must not hand the same cell over twice"
        );
    }

    /// The count that becomes the per-turn receipt. Without it the mode is
    /// indistinguishable from a hang.
    #[test]
    fn suppressed_cells_are_counted_once_each() {
        let mut chat = Chat::new();
        chat.set_lean(true);
        for n in 0..3 {
            let name = format!("t{n}");
            chat.add_tool_message_rich(tool(&name));
            chat.finalize_tool(&name, Some(&name));
        }
        assert_eq!(chat.take_hidden_count(), 3);
        assert_eq!(chat.take_hidden_count(), 0, "the count must not repeat");
    }

    /// The load-bearing test. An error, a loop-guard/control message and an
    /// ordinary notice all arrive through `add_system_message`, and no setting of
    /// this flag may touch any of them.
    #[test]
    fn errors_and_system_authored_text_are_never_hidden() {
        let mut chat = Chat::new();
        chat.set_lean(true);
        chat.add_tool_message_rich(tool("shell_execute"));
        chat.finalize_tool("shell_execute", Some("shell_execute"));
        chat.add_system_message("Error (tool_failure): exit 1", "error");
        chat.add_system_message("3 generations produced no tool calls", "warning");
        chat.add_system_message("Reading view: on", "info");

        let kinds = printed(&mut chat);
        assert!(kinds.contains(&"error"), "an error was hidden: {kinds:?}");
        assert!(
            kinds.contains(&"warning"),
            "system-authored text was hidden: {kinds:?}"
        );
        assert!(kinds.contains(&"info"), "a notice was hidden: {kinds:?}");
        assert!(
            !kinds.contains(&"tool"),
            "the tool cell was NOT hidden: {kinds:?}"
        );
    }

    /// Turn separators ride the `ToolCall` carrier (see `TURN_SEPARATOR_MARKER`),
    /// so the narrow predicate has to exclude them or the reading view silently
    /// deletes the rule between turns.
    #[test]
    fn turn_separators_survive() {
        let mut chat = Chat::new();
        chat.set_lean(true);
        chat.add_user_message("one");
        chat.add_agent_message("a", None);
        chat.add_user_message("two");

        let kinds = printed(&mut chat);
        assert!(
            kinds.contains(&"separator"),
            "the turn separator was hidden: {kinds:?}"
        );
    }

    /// Off is off: the default must print exactly what it always did.
    #[test]
    fn the_default_is_unchanged() {
        let mut chat = Chat::new();
        chat.add_user_message("go");
        chat.add_tool_message_rich(tool("shell_execute"));
        chat.finalize_tool("shell_execute", Some("shell_execute"));
        chat.add_agent_message("done", None);

        assert!(printed(&mut chat).contains(&"tool"));
        assert_eq!(chat.take_hidden_count(), 0);
    }

    /// Turning the mode on mid-conversation cannot be retroactive — the earlier
    /// cell is already queued for `insert_before`, where content is frozen at the
    /// width it was wrapped at. This pins the behaviour the confirmation message
    /// promises: it applies from here on, and says so.
    #[test]
    fn toggling_on_applies_forward_only() {
        let mut chat = Chat::new();
        chat.add_tool_message_rich(tool("before"));
        chat.finalize_tool("before", Some("before"));
        chat.set_lean(true);
        chat.add_tool_message_rich(tool("after"));
        chat.finalize_tool("after", Some("after"));

        let names: Vec<String> = chat
            .drain_scrollback()
            .iter()
            .filter_map(|m| m.tool_data.as_ref())
            .map(|t| t.name.clone())
            .filter(|n| !n.is_empty())
            .collect();
        assert_eq!(
            names,
            vec!["before".to_string()],
            "a cell queued before the toggle was retroactively removed"
        );
    }
}
