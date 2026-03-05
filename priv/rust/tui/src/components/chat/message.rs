use ratatui::prelude::*;
use ratatui::widgets::{Block, Borders, BorderType, Paragraph, Wrap};
use crate::client::types::Signal;
use crate::style;

/// Message types
#[derive(Debug, Clone)]
pub enum MessageType {
    User,
    Agent,
    SystemInfo,
    SystemWarning,
    SystemError,
    ToolCall,
    Help,
}

/// Number of rendered lines for the Help message (must match `build_help_lines`).
const HELP_LINE_COUNT: u16 = 21;

/// Stored tool call metadata for rich rendering.
#[derive(Clone)]
pub struct ToolCallData {
    pub name: String,
    pub args: String,
    pub result: String,
    pub duration_ms: u64,
    pub success: bool,
    /// Pre-rendered styled lines from the tool renderer
    pub lines: Vec<Line<'static>>,
}

/// A chat message
pub struct Message {
    pub msg_type: MessageType,
    pub content: String,
    pub signal: Option<Signal>,
    /// Rich tool call data (only for ToolCall messages)
    pub tool_data: Option<ToolCallData>,
    /// Cached height for given width
    cached_height: Option<(u16, u16)>,
}

impl Message {
    pub fn new(msg_type: MessageType, content: String, signal: Option<Signal>) -> Self {
        Self {
            msg_type,
            content,
            signal,
            tool_data: None,
            cached_height: None,
        }
    }

    /// Create a tool call message with rich styled lines.
    pub fn new_tool_call(data: ToolCallData) -> Self {
        Self {
            msg_type: MessageType::ToolCall,
            content: String::new(), // not used for rich tool calls
            tool_data: Some(data),
            signal: None,
            cached_height: None,
        }
    }

    pub fn invalidate_cache(&mut self) {
        self.cached_height = None;
    }

    pub fn height(&self, width: u16) -> u16 {
        // Help messages have fixed styled content — bypass text-based calc.
        if matches!(self.msg_type, MessageType::Help) {
            return HELP_LINE_COUNT;
        }

        // Tool call messages with rich data — use line count directly.
        if let Some(ref td) = self.tool_data {
            return (td.lines.len() as u16).max(1);
        }

        if let Some((cached_w, cached_h)) = self.cached_height {
            if cached_w == width {
                return cached_h;
            }
        }

        let content_width = width.saturating_sub(4); // borders + padding
        if content_width == 0 {
            return 1;
        }

        // For agent messages, use the markdown renderer for accurate line count.
        // Use width-2 to match draw_agent's actual render width (LEFT border = 1
        // char; the block adds 1 char of left padding = 2 total subtracted from
        // area width).
        if matches!(self.msg_type, MessageType::Agent) {
            let render_width = width.saturating_sub(2);
            let rendered = crate::render::markdown::render_markdown(&self.content, render_width);
            let rendered_lines = rendered.lines.len() as u16;
            let h = rendered_lines.max(1) + 1; // +1 for label
            return h.max(2);
        }

        let lines: Vec<&str> = self.content.lines().collect();
        let mut height: u16 = 0;
        for line in &lines {
            let line_len = unicode_width::UnicodeWidthStr::width(*line) as u16;
            let wrapped_lines = if line_len == 0 {
                1
            } else {
                (line_len + content_width - 1) / content_width
            };
            height += wrapped_lines;
        }
        if lines.is_empty() {
            height = 1;
        }

        // Label line for user/agent messages
        match self.msg_type {
            MessageType::User | MessageType::Agent => height += 1,
            _ => {}
        }

        height.max(2)
    }

    pub fn draw(&self, frame: &mut Frame, area: Rect) {
        let theme = style::theme();

        match self.msg_type {
            MessageType::User => self.draw_user(frame, area, &theme),
            MessageType::Agent => self.draw_agent(frame, area, &theme),
            MessageType::SystemInfo => {
                self.draw_system(frame, area, &theme, theme.colors.msg_border_system)
            }
            MessageType::SystemWarning => {
                self.draw_system(frame, area, &theme, theme.colors.msg_border_warning)
            }
            MessageType::SystemError => {
                self.draw_system(frame, area, &theme, theme.colors.msg_border_error)
            }
            MessageType::ToolCall => {
                self.draw_tool_call(frame, area, &theme)
            }
            MessageType::Help => {
                self.draw_help(frame, area, &theme)
            }
        }
    }

    fn draw_user(&self, frame: &mut Frame, area: Rect, theme: &style::Theme) {
        if area.height == 0 {
            return;
        }

        let label_area = Rect::new(area.x, area.y, area.width, 1);
        let label = Line::from(vec![
            Span::styled("❯  ", theme.prompt_char()),
            Span::styled("You", theme.user_label()),
        ]);
        frame.render_widget(Paragraph::new(label), label_area);

        if area.height > 1 {
            let content_area = Rect::new(area.x, area.y + 1, area.width, area.height - 1);
            let block = Block::default()
                .borders(Borders::LEFT)
                .border_type(BorderType::Thick)
                .border_style(Style::default().fg(theme.colors.msg_border_user));

            let paragraph = Paragraph::new(self.content.as_str())
                .block(block)
                .wrap(Wrap { trim: false });
            frame.render_widget(paragraph, content_area);
        }
    }

    fn draw_agent(&self, frame: &mut Frame, area: Rect, theme: &style::Theme) {
        if area.height == 0 {
            return;
        }

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

        frame.render_widget(Paragraph::new(Line::from(label_spans)), label_area);

        if area.height > 1 {
            let content_area = Rect::new(area.x, area.y + 1, area.width, area.height - 1);
            let block = Block::default()
                .borders(Borders::LEFT)
                .border_type(BorderType::Thick)
                .border_style(Style::default().fg(theme.colors.msg_border_agent));

            let styled_text = crate::render::markdown::render_markdown(&self.content, content_area.width.saturating_sub(2));
            let paragraph = Paragraph::new(styled_text)
                .block(block)
                .wrap(Wrap { trim: false });
            frame.render_widget(paragraph, content_area);
        }
    }

    fn draw_system(
        &self,
        frame: &mut Frame,
        area: Rect,
        theme: &style::Theme,
        border_color: Color,
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

        let paragraph = Paragraph::new(Span::styled(self.content.as_str(), style))
            .block(block)
            .wrap(Wrap { trim: false });
        frame.render_widget(paragraph, area);
    }

    fn draw_tool_call(
        &self,
        frame: &mut Frame,
        area: Rect,
        theme: &style::Theme,
    ) {
        // Rich tool call: render pre-built styled Lines directly
        if let Some(ref td) = self.tool_data {
            let paragraph = Paragraph::new(td.lines.clone());
            frame.render_widget(paragraph, area);
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
        frame.render_widget(paragraph, area);
    }

    fn draw_help(&self, frame: &mut Frame, area: Rect, theme: &style::Theme) {
        let lines = build_help_lines(theme);
        let paragraph = Paragraph::new(lines);
        frame.render_widget(paragraph, area);
    }
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
        ("  /theme <name>", "Switch theme"),
        ("  /verbose", "Toggle tool detail"),
        ("  /yolo", "Toggle auto-approve (dangerous)"),
        ("  /exit", "Quit"),
    ];

    let shortcuts: &[(&str, &str)] = &[
        ("  Ctrl+K", "Command palette"),
        ("  Ctrl+N", "New session"),
        ("  Ctrl+L", "Toggle sidebar"),
        ("  Ctrl+O", "Expand/collapse tool call"),
        ("  Ctrl+C", "Cancel / Quit"),
        ("  j/k", "Scroll (input empty)"),
        ("  PgUp/PgDn", "Page scroll"),
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

    lines
}
