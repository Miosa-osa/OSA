// Phase 2+: survey_id field — wired when survey Q&A is persisted
#![allow(dead_code)]

use std::cell::Cell;
use std::time::SystemTime;
use ratatui::prelude::*;
use ratatui::buffer::Buffer;
use ratatui::widgets::{Block, Borders, BorderType, Paragraph, Widget, Wrap};
use crate::client::types::Signal;
use crate::style;

/// Message types
#[derive(Debug, Clone)]
pub enum MessageType {
    User,
    Agent,
    /// Like Agent but rendered without the "◈ OSA" header — used for text
    /// chunks that follow the first agent message in the same turn (i.e. text
    /// flushed between tool calls).
    AgentContinuation,
    SystemInfo,
    SystemWarning,
    SystemError,
    ToolCall,
    Help,
    SurveyQA,
    /// A frozen `Plan` checklist snapshot pushed into scrollback when the
    /// task plan meaningfully changes. Renders its pre-built styled lines (carried
    /// in `prerendered_body`) with no border, mirroring the live inline panel.
    Plan,
}

/// Number of rendered lines for the Help message (must match `build_help_lines`).
const HELP_LINE_COUNT: u16 = 52;

/// Sentinel [`ToolCallData::name`] marking a turn-separator carrier.
///
/// A separator reuses the `ToolCall` message type rather than introducing a new
/// [`MessageType`] variant — an exhaustive `match` over `MessageType` in
/// `dialogs/transcript_viewer.rs` would otherwise fail to compile. `draw_tool_call`
/// detects this name and draws a width-reflowing dim rule instead of the baked
/// `lines`, so the rule always spans the CURRENT render width (not a width frozen
/// at enqueue time). The `\u{1}` prefix keeps it from ever colliding with a real
/// tool name.
pub(crate) const TURN_SEPARATOR_MARKER: &str = "\u{1}osa:turn-separator";

/// Stored tool call metadata for rich rendering.
#[derive(Clone)]
pub struct ToolCallData {
    pub name: String,
    /// Backend's stable per-call id, when it sent one. This is what pairs a
    /// result with ITS cell: every shell call shares the name `shell_execute`
    /// and tools run concurrently, so matching on `name` alone routes results
    /// to whichever same-named cell happens to be scanned first. `None` means
    /// the backend predates the id and the legacy name scan is used.
    pub tool_call_id: Option<String>,
    pub args: String,
    pub result: String,
    pub duration_ms: u64,
    pub success: bool,
    /// Whether the tool call is currently in expanded view
    pub expanded: bool,
    /// Pre-rendered styled lines from the tool renderer
    pub lines: Vec<Line<'static>>,
}

/// Stored survey Q&A data for summary rendering.
#[derive(Clone)]
pub struct SurveyQAData {
    pub survey_id: String,
    pub pairs: Vec<(String, String)>, // (question, answer)
}

/// A chat message
pub struct Message {
    pub msg_type: MessageType,
    pub content: String,
    pub signal: Option<Signal>,
    /// Rich tool call data (only for ToolCall messages)
    pub tool_data: Option<ToolCallData>,
    /// Survey Q&A data (only for SurveyQA messages)
    pub survey_data: Option<SurveyQAData>,
    /// Memoized `(width, height)` from the last [`Message::height`] call.
    ///
    /// A `Cell` because `height` takes `&self` — it is called from the render
    /// path, which has no `&mut`. **That is why this field spent its whole life
    /// declared, read, cleared and never once written**: four constructors
    /// initialised it, `height` read it at the top, `invalidate_cache` cleared
    /// it, and nothing could assign it. The cache did not exist.
    pub cached_height: Cell<Option<(u16, u16)>>,
    /// Pre-parsed markdown body for the live streaming preview. When set (only
    /// via `new_agent_prerendered`), `height` and `draw_agent` reuse this parsed
    /// `Text` instead of re-running `render_markdown` over the whole reply — this
    /// is what removes the per-frame / per-token full-buffer re-parse.
    pub prerendered_body: Option<Text<'static>>,
    /// Wall-clock time when this message was created (used for timestamp display).
    /// None for tool calls and survey messages where timestamps are not shown.
    pub timestamp: Option<SystemTime>,
    /// U-T7 (display half): when true, an Agent message renders its RAW markdown
    /// source (tab-expanded, unstyled) instead of the rendered markdown, so the
    /// user can read/copy the literal reply. Only meaningful for Agent /
    /// AgentContinuation messages that carry their own `content` (not the live
    /// pre-rendered preview, whose raw source lives in `Chat::streaming_content`).
    pub raw_mode: bool,
}

impl Message {
    pub fn new(msg_type: MessageType, content: String, signal: Option<Signal>) -> Self {
        Self {
            msg_type,
            content,
            signal,
            tool_data: None,
            survey_data: None,
            cached_height: Cell::new(None),
            timestamp: Some(SystemTime::now()),
            prerendered_body: None,
            raw_mode: false,
        }
    }

    /// Create a tool call message with rich styled lines.
    pub fn new_tool_call(data: ToolCallData) -> Self {
        Self {
            msg_type: MessageType::ToolCall,
            content: String::new(), // not used for rich tool calls
            tool_data: Some(data),
            survey_data: None,
            signal: None,
            cached_height: Cell::new(None),
            timestamp: None,
            prerendered_body: None,
            raw_mode: false,
        }
    }

    /// Create an Agent message whose markdown body is already parsed. Used only
    /// by the live streaming region (`Chat::draw_live`) so the same `Text`
    /// powers both `height` and `draw` without re-parsing the whole reply every
    /// frame or every token.
    pub fn new_agent_prerendered(body: Text<'static>) -> Self {
        Self {
            msg_type: MessageType::Agent,
            content: String::new(),
            signal: None,
            tool_data: None,
            survey_data: None,
            cached_height: Cell::new(None),
            timestamp: None,
            prerendered_body: Some(body),
            raw_mode: false,
        }
    }

    /// Create a `Plan` snapshot cell. `body` is the pre-rendered styled checklist
    /// (header + one line per item) shown in scrollback; `plain` is its plain-text
    /// form, kept in `content` so the transcript log has readable text. Carries no
    /// timestamp (like tool calls) so it reads as an inline status cell.
    pub fn new_plan(body: Text<'static>, plain: String) -> Self {
        Self {
            msg_type: MessageType::Plan,
            content: plain,
            signal: None,
            tool_data: None,
            survey_data: None,
            cached_height: Cell::new(None),
            timestamp: None,
            prerendered_body: Some(body),
            raw_mode: false,
        }
    }

    /// Create a turn separator: an understated dim horizontal rule drawn between
    /// conversation turns. Carried as a `ToolCall` message (see
    /// [`TURN_SEPARATOR_MARKER`]) holding a single placeholder line so its height
    /// is exactly one row; the visible rule is drawn at the render width.
    pub fn new_turn_separator() -> Self {
        Message::new_tool_call(ToolCallData {
            name: TURN_SEPARATOR_MARKER.to_string(),
            tool_call_id: None,
            args: String::new(),
            result: String::new(),
            duration_ms: 0,
            success: true,
            expanded: false,
            lines: vec![Line::from("")], // 1 row; real rule drawn in draw_tool_call
        })
    }

    /// Whether this message is a turn separator (see [`TURN_SEPARATOR_MARKER`]).
    pub(crate) fn is_turn_separator(&self) -> bool {
        self.tool_data
            .as_ref()
            .map_or(false, |td| td.name == TURN_SEPARATOR_MARKER)
    }

    pub fn invalidate_cache(&mut self) {
        self.cached_height.set(None);
    }

    /// U-T7: toggle raw-markdown display for this message. Returns the new state.
    /// Height depends on `raw_mode`, so the height cache is invalidated.
    pub fn toggle_raw_mode(&mut self) -> bool {
        self.raw_mode = !self.raw_mode;
        self.invalidate_cache();
        self.raw_mode
    }

    /// U-T7: set raw-markdown display explicitly (invalidates the height cache).
    pub fn set_raw_mode(&mut self, on: bool) {
        if self.raw_mode != on {
            self.raw_mode = on;
            self.invalidate_cache();
        }
    }

    /// Whether this message is currently showing its raw markdown source.
    pub fn is_raw_mode(&self) -> bool {
        self.raw_mode
    }

    /// True when raw-mode rendering applies: an Agent/AgentContinuation message
    /// with `raw_mode` set that carries its own source (`content`), i.e. not the
    /// live pre-rendered preview.
    fn renders_raw(&self) -> bool {
        self.raw_mode
            && self.prerendered_body.is_none()
            && matches!(
                self.msg_type,
                MessageType::Agent | MessageType::AgentContinuation
            )
    }

    /// Rendered height in rows at `width`, memoized in [`Message::cached_height`].
    ///
    /// The memo is the point. On the commit path `height` and
    /// `render_to_buffer` are called back to back on the same message at the
    /// same width, and for an agent message each one ran a full
    /// `render_markdown` — so every finalized answer was parsed twice on its way
    /// into scrollback. [`Message::prepare_for_commit`] removes the second parse
    /// by sharing one `Text`; this removes the second *measurement*.
    ///
    /// Every mutation that can change the answer routes through
    /// [`Message::invalidate_cache`] (content edits, raw-mode toggles, width
    /// changes), so a stale entry is not reachable.
    pub fn height(&self, width: u16) -> u16 {
        if let Some((cached_w, cached_h)) = self.cached_height.get() {
            if cached_w == width {
                return cached_h;
            }
        }
        let h = self.height_uncached(width);
        self.cached_height.set(Some((width, h)));
        h
    }

    /// Parse the markdown body ONCE, before this message is measured and drawn.
    ///
    /// The commit path (`event_loop`'s `drain_scrollback` loop) calls
    /// `height(w)` and then `render_to_buffer(.., w, ..)`, and for an
    /// Agent/AgentContinuation message both ran their own
    /// `render_markdown(&self.content, w - 2)`. Populating `prerendered_body`
    /// first makes both take the already-parsed branch
    /// (`height` at the `prerendered_body` arm, `draw_agent` /
    /// `draw_agent_continuation` at theirs), so the answer is parsed once.
    ///
    /// **Only safe on a message that is on its way out of `Chat`.** For the live
    /// preview `prerendered_body` is not a cache, it is the body
    /// (`new_agent_prerendered`), and for a Plan message it is the whole
    /// content; neither is touched here, because this only ever *fills* an empty
    /// one. The commit path drains its messages out of `Chat` first and drops
    /// them straight after rendering, so nothing can mutate the content
    /// underneath the parse.
    ///
    /// Width must be the same `width` later handed to `height` and
    /// `render_to_buffer`: all three derive the markdown width as `width - 2`.
    pub fn prepare_for_commit(&mut self, width: u16) {
        if self.prerendered_body.is_some() || self.renders_raw() {
            return;
        }
        if !matches!(
            self.msg_type,
            MessageType::Agent | MessageType::AgentContinuation
        ) {
            return;
        }
        let content_width = width.saturating_sub(2);
        if content_width == 0 {
            return;
        }
        self.prerendered_body = Some(crate::render::markdown::render_markdown(
            &self.content,
            content_width,
        ));
        // The body just changed shape as far as the height cache is concerned.
        self.cached_height.set(None);
    }

    fn height_uncached(&self, width: u16) -> u16 {
        // Help messages have fixed styled content — bypass text-based calc.
        if matches!(self.msg_type, MessageType::Help) {
            return HELP_LINE_COUNT;
        }

        // Plan snapshot: one row per pre-rendered line (header + items).
        if matches!(self.msg_type, MessageType::Plan) {
            return self
                .prerendered_body
                .as_ref()
                .map(|b| b.lines.len() as u16)
                .unwrap_or(1)
                .max(1);
        }

        // Tool call messages with rich data — use line count directly.
        if let Some(ref td) = self.tool_data {
            return (td.lines.len() as u16).max(1);
        }

        // Survey Q&A: 2 lines per pair + 2 for border (top + bottom)
        if let Some(ref sd) = self.survey_data {
            return (sd.pairs.len() as u16 * 2).saturating_add(2);
        }

        let content_width = width.saturating_sub(2); // match draw_agent's markdown width
        if content_width == 0 {
            return 1;
        }

        // For agent messages, use the markdown renderer for accurate line count.
        if matches!(self.msg_type, MessageType::Agent | MessageType::AgentContinuation) {
            // Raw-mode: one row per source line (tab-expanded, no markdown).
            if self.renders_raw() {
                let rendered_lines = raw_source_text(&self.content, &style::theme()).lines.len() as u16;
                let h = if matches!(self.msg_type, MessageType::AgentContinuation) {
                    rendered_lines.max(1)
                } else {
                    rendered_lines.max(1) + 1 // +1 for label
                };
                return h.max(1);
            }
            // Live streaming preview supplies a pre-parsed body (see
            // `Chat::ensure_stream_cache`) so height and draw share ONE markdown
            // parse and can never disagree on line count.
            if let Some(ref body) = self.prerendered_body {
                let rendered_lines = (body.lines.len() as u16).max(1);
                let h = if matches!(self.msg_type, MessageType::AgentContinuation) {
                    rendered_lines
                } else {
                    rendered_lines + 1 // +1 for label
                };
                return h.max(1);
            }
            let rendered = crate::render::markdown::render_markdown(&self.content, content_width);
            let rendered_lines = rendered.lines.len() as u16;
            // AgentContinuation has no header label line.
            let h = if matches!(self.msg_type, MessageType::AgentContinuation) {
                rendered_lines.max(1)
            } else {
                rendered_lines.max(1) + 1 // +1 for label
            };
            return h.max(1);
        }

        // Plain (non-markdown) messages — User/System — render inside a
        // Borders::LEFT block, which insets the text by 1 column (NOT 2). Wrapping
        // at width-2 here over-counts lines and leaves blank rows in scrollback
        // ("scroll adds spaces"). Use width-1 to match the actual render.
        // Count with the SAME wrapper that paints. Ceiling division on the raw
        // line width silently under-counts whenever a word cannot be split at
        // the boundary — `Wrap { trim: false }` is ratatui's `WordWrapper`,
        // which keeps words whole and so needs strictly more rows. The shortfall
        // is not a cosmetic gap: this number sizes the `insert_before` rect, and
        // rows past it are clipped out of scrollback permanently.
        let plain_width = width.saturating_sub(1).max(1);
        let mut height: u16 =
            super::wrap_count::wrapped_row_count(&self.content, plain_width);

        // Label line for user/agent messages (continuation has no label)
        match self.msg_type {
            MessageType::User | MessageType::Agent => height += 1,
            _ => {}
        }
        // AgentContinuation never reaches here (caught above by markdown path),
        // but guard anyway.

        height.max(2)
    }

    pub fn draw(&self, frame: &mut Frame, area: Rect) {
        self.render_to_buffer(area, frame.buffer_mut(), 0);
    }

    /// Draw with `scroll_top` lines skipped from the top of the message. Used when
    /// a message is taller than the space above it in the scroll viewport, so its
    /// BOTTOM is shown (adjacent to the message below) instead of always its top.
    pub fn draw_scrolled(&self, frame: &mut Frame, area: Rect, scroll_top: u16) {
        self.render_to_buffer(area, frame.buffer_mut(), scroll_top);
    }

    /// Render this message directly into a `Buffer`. This is the primitive used
    /// both by `terminal.insert_before` (pushing finalized messages into the
    /// native scrollback) and by the thin `Frame`-based `draw`/`draw_scrolled`
    /// wrappers above (live preview inside `terminal.draw`).
    pub fn render_to_buffer(&self, area: Rect, buf: &mut Buffer, scroll_top: u16) {
        let theme = style::theme();

        match self.msg_type {
            MessageType::User => self.draw_user(buf, area, &theme, scroll_top),
            MessageType::Agent => self.draw_agent(buf, area, &theme, scroll_top),
            MessageType::AgentContinuation => {
                self.draw_agent_continuation(buf, area, &theme, scroll_top)
            }
            MessageType::SystemInfo => {
                self.draw_system(buf, area, &theme, theme.colors.msg_border_system, scroll_top)
            }
            MessageType::SystemWarning => {
                self.draw_system(buf, area, &theme, theme.colors.msg_border_warning, scroll_top)
            }
            MessageType::SystemError => {
                self.draw_system(buf, area, &theme, theme.colors.msg_border_error, scroll_top)
            }
            MessageType::ToolCall => {
                self.draw_tool_call(buf, area, &theme)
            }
            MessageType::Help => {
                self.draw_help(buf, area, &theme)
            }
            MessageType::SurveyQA => {
                self.draw_survey_qa(buf, area, &theme)
            }
            MessageType::Plan => {
                self.draw_plan(buf, area, scroll_top)
            }
        }
    }

    /// Draw a `Plan` snapshot: the frozen styled checklist lines, left-aligned,
    /// with no border or title (same understated grammar as the live panel).
    /// Width-safe — `Paragraph` clips to the area and never panics.
    fn draw_plan(&self, buf: &mut Buffer, area: Rect, scroll_top: u16) {
        if area.height == 0 || area.width == 0 {
            return;
        }
        let text = self
            .prerendered_body
            .clone()
            .unwrap_or_else(|| Text::from(""));
        Paragraph::new(text)
            .scroll((scroll_top, 0))
            .render(area, buf);
    }

    fn draw_user(&self, buf: &mut Buffer, area: Rect, theme: &style::Theme, scroll_top: u16) {
        if area.height == 0 {
            return;
        }

        let mut y = area.y;
        if scroll_top == 0 {
            let label_area = Rect::new(area.x, area.y, area.width, 1);
            let left_spans = vec![
                Span::styled("❯  ", theme.prompt_char()),
                Span::styled("You", theme.user_label()),
            ];
            let ts_text = self.timestamp.and_then(format_timestamp).unwrap_or_default();
            let label = build_header_line(left_spans, ts_text, area.width, theme);
            Paragraph::new(label).render(label_area, buf);
            y = area.y + 1;
        }

        let body_h = (area.y + area.height).saturating_sub(y);
        if body_h > 0 {
            let content_area = Rect::new(area.x, y, area.width, body_h);
            let block = Block::default()
                .borders(Borders::LEFT)
                .border_type(BorderType::Thick)
                .border_style(Style::default().fg(theme.colors.msg_border_user));

            let paragraph = Paragraph::new(self.content.as_str())
                .block(block)
                .wrap(Wrap { trim: false })
                .scroll((scroll_top.saturating_sub(1), 0));
            paragraph.render(content_area, buf);
        }
    }

    fn draw_agent(&self, buf: &mut Buffer, area: Rect, theme: &style::Theme, scroll_top: u16) {
        if area.height == 0 {
            return;
        }

        // When scrolled into the message, the "◈ OSA" header (line 0) is above the
        // viewport — skip it and offset the body by the remaining scrolled lines.
        let mut y = area.y;
        if scroll_top == 0 {
            let label_area = Rect::new(area.x, area.y, area.width, 1);
            let mut label_spans = vec![
                Span::styled("◈ ", theme.agent_label()),
                Span::styled("OSA", theme.agent_label()),
            ];

            if let Some(ref signal) = self.signal {
                if !signal.mode.is_empty() {
                    label_spans.push(Span::styled("  ", Style::default()));
                    label_spans.push(Span::styled(
                        format!("[{}/{}]", signal.mode, signal.genre),
                        theme.status_signal(),
                    ));
                }
            }

            let ts_text = self.timestamp.and_then(format_timestamp).unwrap_or_default();
            let label = build_header_line(label_spans, ts_text, area.width, theme);
            Paragraph::new(label).render(label_area, buf);
            y = area.y + 1;
        }

        let body_h = (area.y + area.height).saturating_sub(y);
        if body_h > 0 {
            let content_area = Rect::new(area.x, y, area.width, body_h);
            let block = Block::default()
                .borders(Borders::LEFT)
                .border_type(BorderType::Thick)
                .border_style(Style::default().fg(theme.colors.msg_border_agent));

            let styled_text = if self.renders_raw() {
                raw_source_text(&self.content, theme)
            } else {
                match self.prerendered_body {
                    Some(ref body) => body.clone(),
                    None => crate::render::markdown::render_markdown(
                        &self.content,
                        content_area.width.saturating_sub(2),
                    ),
                }
            };
            let body_scroll = scroll_top.saturating_sub(1); // header was line 0
            let paragraph = Paragraph::new(styled_text)
                .block(block)
                .scroll((body_scroll, 0));
            paragraph.render(content_area, buf);
        }
    }

    /// Draw a continuation chunk — same left-border style as Agent but no "◈ OSA" header.
    fn draw_agent_continuation(&self, buf: &mut Buffer, area: Rect, theme: &style::Theme, scroll_top: u16) {
        if area.height == 0 {
            return;
        }

        let block = Block::default()
            .borders(Borders::LEFT)
            .border_type(BorderType::Thick)
            .border_style(Style::default().fg(theme.colors.msg_border_agent));

        let styled_text = if self.renders_raw() {
            raw_source_text(&self.content, theme)
        } else {
            match self.prerendered_body {
                Some(ref body) => body.clone(),
                None => crate::render::markdown::render_markdown(
                    &self.content,
                    area.width.saturating_sub(2),
                ),
            }
        };
        // No header on a continuation, so scroll_top applies straight to the body.
        let paragraph = Paragraph::new(styled_text)
            .block(block)
            .scroll((scroll_top, 0));
        paragraph.render(area, buf);
    }

    fn draw_system(
        &self,
        buf: &mut Buffer,
        area: Rect,
        theme: &style::Theme,
        border_color: Color,
        scroll_top: u16,
    ) {
        let block = Block::default()
            .borders(Borders::LEFT)
            .border_type(BorderType::Plain)
            .border_style(Style::default().fg(border_color));

        let style = match self.msg_type {
            MessageType::SystemError => theme.error_text(),
            MessageType::SystemWarning => theme.prefix_thinking(),
            _ => theme.faint(),
        };

        // Use Text::from to preserve newlines in multi-line system messages
        let text = Text::from(
            self.content
                .lines()
                .map(|line| Line::from(Span::styled(line.to_string(), style)))
                .collect::<Vec<_>>(),
        );
        let paragraph = Paragraph::new(text)
            .block(block)
            .wrap(Wrap { trim: false })
            .scroll((scroll_top, 0));
        paragraph.render(area, buf);
    }

    fn draw_tool_call(
        &self,
        buf: &mut Buffer,
        area: Rect,
        theme: &style::Theme,
    ) {
        // Turn separator: draw a width-reflowing dim rule instead of baked lines.
        if self.is_turn_separator() {
            self.draw_turn_separator(buf, area, theme);
            return;
        }

        // Rich tool call: render pre-built styled Lines directly.
        //
        // NOT via `Paragraph`: these lines carry OSC 8 hyperlink escapes (tool
        // headers linkify their file path, and `tools/collapse.rs` linkifies
        // URLs in output rows). `Paragraph` has no `.wrap()` here, so ratatui
        // uses `LineTruncator`, which counts each ESC byte as one display column
        // — about 80 phantom columns for a `file://` header — and cuts the row's
        // visible tail. This content is finalized into the terminal's own
        // scrollback via `insert_before`, so that truncation is permanent.
        if let Some(ref td) = self.tool_data {
            crate::render::cells::render_lines(&td.lines, area, buf, 0);
            return;
        }

        // Fallback: plain text (legacy path)
        let block = Block::default()
            .borders(Borders::LEFT)
            .border_type(BorderType::Plain)
            .border_style(Style::default().fg(theme.colors.border));

        let paragraph = Paragraph::new(Span::styled(
            self.content.as_str(),
            theme.faint(),
        ))
        .block(block)
        .wrap(Wrap { trim: false });
        paragraph.render(area, buf);
    }

    /// Draw a turn separator: a single understated dim horizontal rule that spans
    /// the current render width. Uses the light box char `─` (U+2500) in the
    /// theme's `dim` color so it reads as a faint boundary, not a loud divider.
    /// Width-safe: `repeat(area.width)` reflows on every render and never panics
    /// (width 1 yields a single glyph; width 0 draws nothing).
    fn draw_turn_separator(&self, buf: &mut Buffer, area: Rect, theme: &style::Theme) {
        if area.height == 0 || area.width == 0 {
            return;
        }
        let rule = "\u{2500}".repeat(area.width as usize);
        let line = Line::from(Span::styled(rule, Style::default().fg(theme.colors.dim)));
        let row = Rect::new(area.x, area.y, area.width, 1);
        Paragraph::new(line).render(row, buf);
    }

    fn draw_survey_qa(&self, buf: &mut Buffer, area: Rect, theme: &style::Theme) {
        let sd = match self.survey_data {
            Some(ref d) => d,
            None => return,
        };

        let block = Block::default()
            .title(Span::styled(
                " Survey Complete ",
                Style::default()
                    .fg(theme.colors.secondary)
                    .add_modifier(Modifier::BOLD),
            ))
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(Style::default().fg(theme.colors.secondary));

        let inner = block.inner(area);
        block.render(area, buf);

        let muted_style = Style::default().fg(theme.colors.muted);
        let answer_style = Style::default()
            .fg(theme.colors.primary)
            .add_modifier(Modifier::BOLD);

        let mut lines: Vec<Line<'static>> = Vec::new();
        for (q, a) in &sd.pairs {
            lines.push(Line::from(Span::styled(
                format!("  Q: {}", q),
                muted_style,
            )));
            lines.push(Line::from(Span::styled(
                format!("  A: {}", a),
                answer_style,
            )));
        }

        let paragraph = Paragraph::new(lines);
        paragraph.render(inner, buf);
    }

    fn draw_help(&self, buf: &mut Buffer, area: Rect, theme: &style::Theme) {
        let lines = build_help_lines(theme);
        let paragraph = Paragraph::new(lines);
        paragraph.render(area, buf);
    }
}

/// U-T7: render a message's RAW markdown source as [`Text`] — one line per
/// source line, tabs expanded to 4-column stops, styled muted so it reads as a
/// literal/debug view. No markdown parsing, wrapping, or link handling is done,
/// so the user sees exactly the characters the model emitted.
pub(crate) fn raw_source_text(content: &str, theme: &style::Theme) -> Text<'static> {
    let style = Style::default().fg(theme.colors.muted);
    let lines: Vec<Line<'static>> = content
        .lines()
        .map(|l| Line::from(Span::styled(expand_tabs_4(l), style)))
        .collect();
    if lines.is_empty() {
        Text::from("")
    } else {
        Text::from(lines)
    }
}

/// Expand tabs to 4-column stops for the raw source view (display-width aware).
fn expand_tabs_4(line: &str) -> String {
    if !line.contains('\t') {
        return line.to_string();
    }
    let mut out = String::with_capacity(line.len());
    let mut col = 0usize;
    for ch in line.chars() {
        if ch == '\t' {
            let spaces = 4 - (col % 4);
            for _ in 0..spaces {
                out.push(' ');
            }
            col += spaces;
        } else {
            out.push(ch);
            col += unicode_width::UnicodeWidthChar::width(ch).unwrap_or(0);
        }
    }
    out
}

/// The machine's UTC offset in seconds, resolved once per process.
///
/// Chat timestamps are wall-clock times a human reads off the screen, so they
/// must be LOCAL. This used to be missing entirely: `format_timestamp` took
/// `epoch % 86400` — a raw UTC time-of-day — and stamped "AM"/"PM" on it, so a
/// user in UTC+7 saw `2:23 AM` for a message sent at `9:23 AM`.
///
/// Resolved via `localtime_r` rather than pulling in `chrono`: the TUI has no
/// date/time crate and the offset is the only thing missing.
///
/// Cached, so a DST transition mid-session is not picked up until restart. That
/// is a deliberate trade — the alternative is a libc call per message per frame.
fn local_utc_offset_secs() -> i64 {
    static OFFSET: std::sync::OnceLock<i64> = std::sync::OnceLock::new();
    *OFFSET.get_or_init(resolve_local_utc_offset_secs)
}

#[cfg(unix)]
fn resolve_local_utc_offset_secs() -> i64 {
    // SAFETY: `localtime_r` fills a `tm` we own on the stack and reads a
    // `time_t` we own; unlike `localtime` it touches no shared static and is
    // reentrant. A null return means the conversion failed, in which case we
    // fall back to UTC (offset 0) rather than reading uninitialised memory.
    unsafe {
        let now: libc::time_t = libc::time(std::ptr::null_mut());
        let mut tm: libc::tm = std::mem::zeroed();
        if libc::localtime_r(&now, &mut tm).is_null() {
            return 0;
        }
        tm.tm_gmtoff as i64
    }
}

#[cfg(not(unix))]
fn resolve_local_utc_offset_secs() -> i64 {
    0
}

/// Format a `SystemTime` as a human-readable timestamp string.
///
/// Returns `"2:34 PM"` for messages from today (same LOCAL calendar day)
/// and `"Mar 7, 2:34 PM"` for messages from a previous day. Uses only
/// `std::time` plus a one-off libc offset lookup — no date/time crate.
fn format_timestamp(ts: SystemTime) -> Option<String> {
    let now = SystemTime::now();
    let secs = ts.duration_since(std::time::UNIX_EPOCH).ok()?.as_secs() as i64;
    let now_secs = now.duration_since(std::time::UNIX_EPOCH).ok()?.as_secs() as i64;

    // Shift into local time BEFORE splitting into day / time-of-day. Applying
    // the offset only to the clock would leave the today/yesterday rollover on
    // UTC midnight, so between 00:00 and 07:00 local a message sent minutes ago
    // would render with yesterday's date prefix.
    let offset = local_utc_offset_secs();
    let local = secs.checked_add(offset)?;
    let now_local = now_secs.checked_add(offset)?;

    // Negative local epoch means a pre-1970 timestamp; nothing sane to show.
    let day = local.div_euclid(86400);
    let now_day = now_local.div_euclid(86400);
    if day < 0 {
        return None;
    }
    let is_today = day == now_day;

    let time_of_day = local.rem_euclid(86400);
    let hour_local = (time_of_day / 3600) as u8;
    let minute = ((time_of_day % 3600) / 60) as u8;

    let (hour12, ampm) = match hour_local {
        0 => (12u8, "AM"),
        1..=11 => (hour_local, "AM"),
        12 => (12u8, "PM"),
        _ => (hour_local - 12, "PM"),
    };

    if is_today {
        Some(format!("{}:{:02} {}", hour12, minute, ampm))
    } else {
        let (month_name, day_of_month) = epoch_days_to_month_day(day as u64);
        Some(format!("{} {}, {}:{:02} {}", month_name, day_of_month, hour12, minute, ampm))
    }
}

/// Convert days-since-Unix-epoch to `(month_abbr, day_of_month)` using
/// the proleptic Gregorian calendar.
fn epoch_days_to_month_day(days: u64) -> (&'static str, u32) {
    let mut year = 1970u32;
    let mut remaining = days as u32;

    loop {
        let days_in_year = if is_leap_year(year) { 366 } else { 365 };
        if remaining < days_in_year {
            break;
        }
        remaining -= days_in_year;
        year += 1;
    }

    let months: [(&str, u32); 12] = [
        ("Jan", 31),
        ("Feb", if is_leap_year(year) { 29 } else { 28 }),
        ("Mar", 31),
        ("Apr", 30),
        ("May", 31),
        ("Jun", 30),
        ("Jul", 31),
        ("Aug", 31),
        ("Sep", 30),
        ("Oct", 31),
        ("Nov", 30),
        ("Dec", 31),
    ];

    for (name, days_in_month) in &months {
        if remaining < *days_in_month {
            return (name, remaining + 1);
        }
        remaining -= days_in_month;
    }

    ("Dec", 31) // unreachable, but satisfies the compiler
}

#[inline]
fn is_leap_year(year: u32) -> bool {
    (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
}

/// Build a header `Line` with left-side content and a right-aligned timestamp.
///
/// The timestamp is placed at the far right of `total_width`. If the left
/// content leaves less than `MIN_GAP + ts_len` characters, the timestamp is
/// omitted to prevent overlapping text.
fn build_header_line<'a>(
    left_spans: Vec<Span<'a>>,
    ts_text: String,
    total_width: u16,
    theme: &style::Theme,
) -> Line<'a> {
    if ts_text.is_empty() || total_width == 0 {
        return Line::from(left_spans);
    }

    let left_width: usize = left_spans
        .iter()
        .map(|s| unicode_width::UnicodeWidthStr::width(s.content.as_ref()))
        .sum();

    let ts_len = ts_text.len();
    let total = total_width as usize;
    const MIN_GAP: usize = 2;

    if left_width + MIN_GAP + ts_len > total {
        // Not enough horizontal space — skip the timestamp.
        return Line::from(left_spans);
    }

    let padding = total - left_width - ts_len;
    let mut spans = left_spans;
    spans.push(Span::raw(" ".repeat(padding)));
    spans.push(Span::styled(ts_text, theme.msg_meta()));
    Line::from(spans)
}

/// Build the styled help content. The returned line count MUST equal `HELP_LINE_COUNT`.
fn build_help_lines(theme: &style::Theme) -> Vec<Line<'static>> {
    let key_style = theme.help_key();
    let desc_style = theme.help_desc();
    let title_style = theme.section_title();

    let commands: &[(&str, &str)] = &[
        ("  /help", "Show this help"),
        ("  /clear", "Clear chat"),
        ("  /models", "Browse models"),
        ("  /model <name>", "Switch model"),
        ("  /sessions", "Browse sessions"),
        ("  /session new", "New session"),
        ("  /steer <text>", "Redirect the agent mid-turn (queues if idle)"),
        ("  /bg", "List background turns (Ctrl+B backgrounds one)"),
        ("  /fg", "Bring a backgrounded turn back to the foreground"),
        ("  /agents", "Background-agent dashboard (running + finished)"),
        ("  /rewind", "Restore code/conversation from a checkpoint"),
        ("  /theme <name>", "Switch theme"),
        ("  /verbose", "Toggle tool detail"),
        ("  /yolo", "Toggle auto-approve (dangerous)"),
        ("  /desktop", "Open desktop GUI in browser"),
        ("  /version", "Show OSA version"),
        ("  /exit", "Quit"),
    ];

    let shortcuts: &[(&str, &str)] = &[
        ("  Ctrl+K", "Command palette (empty input)"),
        ("  /", "Slash command list"),
        ("  @", "File-path reference"),
        ("  F1", "This help"),
        ("  F2", "Copy last message"),
        ("  Ctrl+N", "New session"),
        ("  Ctrl+L", "Toggle sidebar"),
        ("  Ctrl+O", "Transcript / expand tool call"),
        ("  Ctrl+R", "Reverse history search"),
        ("  Esc", "Clear input / interrupt turn"),
        ("  Esc Esc", "Edit a previous message (rewind)"),
        ("  Ctrl+C", "Interrupt turn (x2 at idle quits)"),
        ("  Ctrl+D", "Exit (empty input)"),
        ("  Shift+Enter", "Newline (Ctrl+J also works)"),
        ("  Ctrl+A/E", "Line start / end"),
        ("  Ctrl+U/K/W", "Kill line / to-end / word"),
        ("  Ctrl+D (edit)", "Delete char forward"),
        ("  Alt+B/F", "Word left / right"),
        ("  Ctrl+Z/Y", "Undo / redo"),
        ("  Ctrl+G", "Compose in $EDITOR"),
        ("  Ctrl+S", "Stash / restore input"),
        ("  Shift+Tab", "Cycle permission mode"),
        ("  Up/Down", "History / line nav"),
        ("  PgUp/PgDn", "Page scroll"),
        ("  Shift+drag", "Select text to copy"),
    ];

    let voice: &[(&str, &str)] = &[
        ("  Alt+V", "Toggle recording"),
        ("  Enter", "Stop & transcribe"),
        ("  Esc", "Cancel recording"),
        ("  Config", "VOICE_PROVIDER=local|cloud|groq"),
    ];

    let mut lines: Vec<Line<'static>> = Vec::with_capacity(HELP_LINE_COUNT as usize);

    // blank
    lines.push(Line::from(""));
    // section: Commands
    lines.push(Line::from(Span::styled(" Commands", title_style)));
    for &(key, desc) in commands {
        lines.push(Line::from(vec![
            Span::styled(format!("{:<18}", key), key_style),
            Span::styled(desc.to_string(), desc_style),
        ]));
    }

    // blank
    lines.push(Line::from(""));
    // section: Shortcuts
    lines.push(Line::from(Span::styled(" Shortcuts", title_style)));
    for &(key, desc) in shortcuts {
        lines.push(Line::from(vec![
            Span::styled(format!("{:<18}", key), key_style),
            Span::styled(desc.to_string(), desc_style),
        ]));
    }

    // blank
    lines.push(Line::from(""));
    // section: Voice Input
    lines.push(Line::from(Span::styled(" Voice Input", title_style)));
    for &(key, desc) in voice {
        lines.push(Line::from(vec![
            Span::styled(format!("{:<18}", key), key_style),
            Span::styled(desc.to_string(), desc_style),
        ]));
    }

    lines
}

#[cfg(test)]
mod help_tests {
    use super::{build_help_lines, HELP_LINE_COUNT};

    /// The fixed-height help message (`Message::height` returns HELP_LINE_COUNT
    /// for `MessageType::Help`) must exactly match the number of lines actually
    /// built, or the overlay clips its last rows / leaves blank ones.
    #[test]
    fn help_line_count_matches_built_lines() {
        let theme = crate::style::theme();
        let lines = build_help_lines(&theme);
        assert_eq!(
            lines.len(),
            HELP_LINE_COUNT as usize,
            "HELP_LINE_COUNT ({}) must equal built help lines ({})",
            HELP_LINE_COUNT,
            lines.len()
        );
    }
}

#[cfg(test)]
mod turn_separator_render_tests {
    use super::*;
    use ratatui::buffer::Buffer;

    /// Flatten the single rendered row of a separator into a String.
    fn render_row(width: u16) -> String {
        let sep = Message::new_turn_separator();
        let area = Rect::new(0, 0, width, 1);
        let mut buf = Buffer::empty(area);
        sep.render_to_buffer(area, &mut buf, 0);
        buf.content().iter().map(|c| c.symbol()).collect()
    }

    #[test]
    fn separator_is_one_row_tall() {
        assert_eq!(Message::new_turn_separator().height(80), 1);
    }

    #[test]
    fn separator_reflows_to_render_width() {
        for w in [4u16, 20, 80] {
            let row = render_row(w);
            let rule_cells = row.chars().filter(|c| *c == '\u{2500}').count();
            assert_eq!(rule_cells, w as usize, "rule spans the full width {w}");
        }
    }

    #[test]
    fn separator_does_not_panic_at_width_one() {
        // Width 1 must yield exactly one rule glyph and never panic.
        let row = render_row(1);
        assert_eq!(row, "\u{2500}");
    }

    #[test]
    fn separator_detected_via_marker() {
        assert!(Message::new_turn_separator().is_turn_separator());
        assert!(!Message::new(MessageType::Agent, "hi".into(), None).is_turn_separator());
    }
}

#[cfg(test)]
mod raw_mode_tests {
    use super::*;

    fn flat(text: &Text<'_>) -> Vec<String> {
        text.lines
            .iter()
            .map(|l| l.spans.iter().map(|s| s.content.as_ref()).collect())
            .collect()
    }

    #[test]
    fn raw_source_text_is_verbatim_with_tabs_expanded() {
        let theme = crate::style::theme();
        // Markdown markup is preserved literally (not rendered) and tabs expand.
        // "- **a**" is 7 cols → next 4-stop is col 8 → exactly one filler space.
        let t = raw_source_text("# Title\n- **a**\tb", &theme);
        assert_eq!(flat(&t), vec!["# Title".to_string(), "- **a** b".to_string()]);
    }

    #[test]
    fn toggle_flips_and_targets_agent_content() {
        let mut m = Message::new(MessageType::Agent, "**bold** text".into(), None);
        assert!(!m.is_raw_mode());
        assert!(!m.renders_raw());
        assert!(m.toggle_raw_mode()); // → true
        assert!(m.is_raw_mode());
        assert!(m.renders_raw(), "agent message with content renders raw");
        assert!(!m.toggle_raw_mode()); // → false
    }

    #[test]
    fn prerendered_preview_never_renders_raw() {
        // The live preview carries no source in `content`, so it must not switch
        // to the raw path even if the flag is set.
        let mut m = Message::new_agent_prerendered(Text::from("rendered"));
        m.set_raw_mode(true);
        assert!(!m.renders_raw());
    }

    #[test]
    fn raw_mode_height_counts_source_lines() {
        let src = "line one\nline two\nline three";
        let mut m = Message::new(MessageType::Agent, src.into(), None);
        m.set_raw_mode(true);
        // 3 source lines + 1 label row for an Agent message.
        assert_eq!(m.height(80), 4);
    }
}

#[cfg(test)]
mod timestamp_tz_tests {
    use super::*;
    use std::time::{Duration, UNIX_EPOCH};

    fn local_now() -> i64 {
        let secs = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs() as i64;
        secs + local_utc_offset_secs()
    }

    /// The regression: `format_timestamp` used `epoch % 86400` — a raw UTC
    /// time-of-day — and labelled it AM/PM as if it were local. In UTC+7 a
    /// message sent at 9:23 AM rendered as "2:23 AM".
    ///
    /// Asserts the rendered clock matches what libc says local time is, which
    /// is exactly the property that was broken. Timezone-agnostic: it passes in
    /// UTC (where the old code was accidentally right) and in any offset zone
    /// (where it was not), so CI and this machine both exercise it.
    #[test]
    fn today_timestamp_is_local_not_utc() {
        let now = SystemTime::now();
        let rendered = format_timestamp(now).expect("now formats");

        let tod = local_now().rem_euclid(86400);
        let hour = (tod / 3600) as u8;
        let minute = ((tod % 3600) / 60) as u8;
        let (h12, ampm) = match hour {
            0 => (12u8, "AM"),
            1..=11 => (hour, "AM"),
            12 => (12u8, "PM"),
            _ => (hour - 12, "PM"),
        };

        assert_eq!(rendered, format!("{}:{:02} {}", h12, minute, ampm));
    }

    /// The day rollover must use the LOCAL calendar day too. Applying the
    /// offset to the clock but not to the day bucket would make a message sent
    /// minutes ago carry a "Mar 7," date prefix during the hours where UTC is
    /// still on the previous day (00:00-07:00 local at UTC+7).
    #[test]
    fn recent_message_never_gets_a_date_prefix() {
        // Skip within the first two minutes of the local day, where "60s ago"
        // legitimately IS yesterday and a date prefix is correct.
        if local_now().rem_euclid(86400) < 120 {
            return;
        }
        let recent = SystemTime::now() - Duration::from_secs(60);
        let rendered = format_timestamp(recent).expect("recent formats");
        assert!(
            !rendered.contains(','),
            "a message from 60s ago must render as bare time-of-day, got {rendered:?}"
        );
    }

    /// A timestamp from several days back still takes the dated branch, so the
    /// offset change did not collapse the two formats into one.
    #[test]
    fn older_message_keeps_its_date_prefix() {
        let old = SystemTime::now() - Duration::from_secs(5 * 86400);
        let rendered = format_timestamp(old).expect("old formats");
        assert!(
            rendered.contains(','),
            "a 5-day-old message must carry a date prefix, got {rendered:?}"
        );
    }

    /// The offset is a real IANA-style offset: whole minutes, within ±14h.
    /// Guards against `tm_gmtoff` being misread on a platform where it is not
    /// seconds, which would silently shift every timestamp instead of failing.
    #[test]
    fn local_offset_is_plausible() {
        let off = local_utc_offset_secs();
        assert!((-14 * 3600..=14 * 3600).contains(&off), "implausible offset {off}");
        assert_eq!(off % 60, 0, "offset must be a whole number of minutes");
    }
}

#[cfg(test)]
mod commit_parse_tests {
    use super::*;

    /// A markdown body with enough structure that a re-parse is not free, and
    /// enough lines that a height mismatch would be obvious.
    fn body() -> String {
        let mut s = String::from(
            "Here is the answer, written as one long paragraph so that the \
             rendered height genuinely depends on the width it is measured at \
             and a width-keyed cache has something to be wrong about.\n\n",
        );
        for i in 0..30 {
            s.push_str(&format!("- item {i} with some **bold** text\n"));
        }
        s.push_str("\n```rust\nfn main() { println!(\"hi\"); }\n```\n");
        s
    }

    fn agent() -> Message {
        Message::new(MessageType::Agent, body(), None)
    }

    /// **The defect.** `cached_height` was declared, read at the top of
    /// `height`, cleared by `invalidate_cache`, and initialised by four
    /// constructors — and assigned by nothing in the crate. Every `height` call
    /// therefore re-ran the markdown parse. Reverting `height` to a plain
    /// `height_uncached` call leaves this `None` and fails here.
    #[test]
    fn measuring_a_message_populates_its_height_cache() {
        let msg = agent();
        assert_eq!(msg.cached_height.get(), None, "nothing measured it yet");
        let h = msg.height(80);
        assert_eq!(
            msg.cached_height.get(),
            Some((80, h)),
            "height() must record what it computed, keyed by the width it used"
        );
    }

    /// A second call at the same width is served from the memo, and a different
    /// width is not (the cache is keyed by width because the answer rewraps).
    #[test]
    fn the_height_cache_is_keyed_by_width() {
        let msg = agent();
        let narrow = msg.height(40);
        let wide = msg.height(120);
        assert_eq!(msg.cached_height.get(), Some((120, wide)));
        assert_ne!(
            narrow, wide,
            "a 30-item list must wrap differently at 40 columns than at 120; \
             if this ever ties, pick a body where it does not"
        );
        assert_eq!(msg.height(120), wide, "second call must agree with the memo");
    }

    /// Invalidation still reaches it — otherwise the memo would outlive an edit.
    #[test]
    fn invalidating_clears_the_height_cache() {
        let mut msg = agent();
        msg.height(80);
        assert!(msg.cached_height.get().is_some());
        msg.invalidate_cache();
        assert_eq!(msg.cached_height.get(), None);
    }

    /// **The double parse.** On the commit path `height(w)` and
    /// `render_to_buffer(.., w, ..)` each ran their own `render_markdown` over
    /// the whole answer. `prepare_for_commit` parses once and leaves the result
    /// where both of them already look for it.
    #[test]
    fn preparing_for_commit_leaves_a_body_both_consumers_use() {
        let mut msg = agent();
        assert!(msg.prerendered_body.is_none());
        msg.prepare_for_commit(80);
        let prepared = msg
            .prerendered_body
            .as_ref()
            .expect("an agent message must come out of prepare_for_commit parsed");
        assert!(
            prepared.lines.len() > 30,
            "the parsed body must be the real answer, not a stub"
        );
    }

    /// The shared parse must not change the number. If `prepare_for_commit`
    /// measured at a different width than `height` does, every committed block
    /// would be sized wrong and rows would be clipped out of scrollback.
    #[test]
    fn the_shared_parse_measures_the_same_height_as_the_double_parse() {
        for width in [40u16, 80, 120, 200] {
            let plain = agent().height(width);
            let mut prepared = agent();
            prepared.prepare_for_commit(width);
            assert_eq!(
                prepared.height(width),
                plain,
                "sharing the parse changed the committed height at width {width}"
            );
        }
    }

    /// It only ever FILLS an empty body. The live preview and the plan snapshot
    /// carry their content in `prerendered_body`; overwriting it there would
    /// replace the body with a re-parse of an empty `content`.
    #[test]
    fn preparing_never_overwrites_a_body_that_is_the_content() {
        let text: Text<'static> = Text::from("already rendered");
        let mut msg = Message::new_agent_prerendered(text);
        msg.prepare_for_commit(80);
        let body = msg.prerendered_body.as_ref().unwrap();
        assert_eq!(body.lines.len(), 1);
        assert_eq!(
            body.lines[0].spans[0].content.as_ref(),
            "already rendered",
            "prepare_for_commit must leave an existing body untouched"
        );
    }

    /// Raw view shows the literal source, which is not markdown at all — a
    /// parsed body would be ignored by the draw and wrong for the height.
    #[test]
    fn preparing_leaves_a_raw_view_message_alone() {
        let mut msg = agent();
        msg.set_raw_mode(true);
        msg.prepare_for_commit(80);
        assert!(
            msg.prerendered_body.is_none(),
            "raw view renders `content` verbatim; it must not gain a parsed body"
        );
    }

    /// Non-agent messages are not markdown-rendered, so there is nothing to
    /// share and nothing to parse.
    #[test]
    fn preparing_ignores_messages_that_are_not_markdown() {
        let mut user = Message::new(MessageType::User, body(), None);
        user.prepare_for_commit(80);
        assert!(user.prerendered_body.is_none());
    }
}
