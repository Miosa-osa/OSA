// Phase 2+: survey_id field — wired when survey Q&A is persisted
#![allow(dead_code)]

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
    /// A frozen "Updated plan" checklist snapshot pushed into scrollback when the
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
    /// Cached height for given width
    pub cached_height: Option<(u16, u16)>,
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
            cached_height: None,
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
            cached_height: None,
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
            cached_height: None,
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
            cached_height: None,
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
        self.cached_height = None;
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

    pub fn height(&self, width: u16) -> u16 {
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

        if let Some((cached_w, cached_h)) = self.cached_height {
            if cached_w == width {
                return cached_h;
            }
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
        let plain_width = width.saturating_sub(1).max(1);
        let lines: Vec<&str> = self.content.lines().collect();
        let mut height: u16 = 0;
        for line in &lines {
            let line_len = unicode_width::UnicodeWidthStr::width(*line) as u16;
            let wrapped_lines = if line_len == 0 {
                1
            } else {
                (line_len + plain_width - 1) / plain_width
            };
            height += wrapped_lines;
        }
        if lines.is_empty() {
            height = 1;
        }

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

        // Rich tool call: render pre-built styled Lines directly
        if let Some(ref td) = self.tool_data {
            let paragraph = Paragraph::new(td.lines.clone());
            paragraph.render(area, buf);
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

/// Format a `SystemTime` as a human-readable timestamp string.
///
/// Returns `"2:34 PM"` for messages from today (same UTC calendar day)
/// and `"Mar 7, 2:34 PM"` for messages from a previous day. Uses only
/// `std::time` — no external crate dependency.
fn format_timestamp(ts: SystemTime) -> Option<String> {
    let now = SystemTime::now();
    let secs = ts.duration_since(std::time::UNIX_EPOCH).ok()?.as_secs();
    let now_secs = now.duration_since(std::time::UNIX_EPOCH).ok()?.as_secs();

    let day = secs / 86400;
    let now_day = now_secs / 86400;
    let is_today = day == now_day;

    // Compute time-of-day components (UTC).
    let time_of_day = secs % 86400;
    let hour_utc = (time_of_day / 3600) as u8;
    let minute = ((time_of_day % 3600) / 60) as u8;

    let (hour12, ampm) = match hour_utc {
        0 => (12u8, "AM"),
        1..=11 => (hour_utc, "AM"),
        12 => (12u8, "PM"),
        _ => (hour_utc - 12, "PM"),
    };

    if is_today {
        Some(format!("{}:{:02} {}", hour12, minute, ampm))
    } else {
        let (month_name, day_of_month) = epoch_days_to_month_day(day);
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
        ("  ?", "This help (empty input)"),
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
        ("  j/k", "Scroll (input empty)"),
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
