use ratatui::prelude::*;
use ratatui::widgets::{Block, Borders, Paragraph, Wrap};

// ─── ThinkingBox ──────────────────────────────────────────────────────────────

/// Collapsible panel that shows extended-thinking / reasoning content.
///
/// Collapsed (default):  ▶ Thinking... (N chars)
/// Expanded:             Dashed-border block with dim-italic wrapped content,
///                       capped at 20 visible lines with overflow indicator.
pub struct ThinkingBox {
    content: String,
    expanded: bool,
    title: String,
}

impl ThinkingBox {
    pub fn new() -> Self {
        Self {
            content: String::new(),
            expanded: true,
            title: "Thinking".to_string(),
        }
    }

    // ─── Mutation ──────────────────────────────────────────────────────────

    pub fn update(&mut self, text: &str) {
        self.content.push_str(text);
    }

    pub fn clear(&mut self) {
        self.content.clear();
    }

    #[allow(dead_code)]
    pub fn toggle(&mut self) {
        self.expanded = !self.expanded;
    }

    pub fn is_empty(&self) -> bool {
        self.content.is_empty()
    }

    // ─── Layout ────────────────────────────────────────────────────────────

    /// Compute required height for the given render width.
    ///
    /// - Collapsed: always 1 line.
    /// - Expanded:  2 (border) + content lines (max 20) + optional overflow line.
    pub fn height(&self, width: u16) -> u16 {
        if !self.expanded || self.content.is_empty() {
            return 1;
        }

        // Inner width subtracts border (2) and one padding char each side (2).
        let inner_w = (width as usize).saturating_sub(4).max(1);
        let content_lines = self.wrap_lines(inner_w);
        let visible = content_lines.len().min(10);
        let overflow_line = if content_lines.len() > 10 { 1 } else { 0 };

        // 2 border lines + visible content + optional overflow indicator
        2 + visible as u16 + overflow_line as u16
    }

    // ─── Draw ──────────────────────────────────────────────────────────────

    pub fn draw(&self, frame: &mut Frame, area: Rect) {
        if area.height == 0 || area.width == 0 {
            return;
        }

        let theme = crate::style::theme();

        if !self.expanded || self.content.is_empty() {
            // Collapsed: single indicator line.
            let char_count = self.content.chars().count();
            let indicator = if self.content.is_empty() {
                "\u{25b6} Thinking...".to_string()
            } else {
                format!("\u{25b6} Thinking... ({} chars)", char_count)
            };
            let line = Line::from(Span::styled(
                indicator,
                theme.thinking_header().add_modifier(Modifier::ITALIC),
            ));
            frame.render_widget(Paragraph::new(line), area);
            return;
        }

        // Expanded: bordered block with content.
        let inner_w = (area.width as usize).saturating_sub(4).max(1);
        let all_lines = self.wrap_lines(inner_w);
        let total = all_lines.len();
        let visible_count = total.min(10);
        let has_overflow = total > 10;

        // Build Text from visible lines.
        let mut text_lines: Vec<Line<'_>> = all_lines[..visible_count]
            .iter()
            .map(|l| {
                Line::from(Span::styled(
                    l.as_str(),
                    theme.thinking_content().add_modifier(Modifier::ITALIC),
                ))
            })
            .collect();

        if has_overflow {
            text_lines.push(Line::from(Span::styled(
                format!("... ({} more lines)", total - 20),
                theme.faint().add_modifier(Modifier::ITALIC),
            )));
        }

        let block = Block::default()
            .title(Span::styled(&self.title, theme.thinking_header()))
            .borders(Borders::ALL)
            .border_type(ratatui::widgets::BorderType::Plain)
            .border_style(theme.faint());

        let paragraph = Paragraph::new(Text::from(text_lines))
            .block(block)
            .wrap(Wrap { trim: false });

        frame.render_widget(paragraph, area);
    }

    // ─── Internal helpers ──────────────────────────────────────────────────

    /// Word-wrap the content at `width` characters, returning owned strings.
    fn wrap_lines(&self, width: usize) -> Vec<String> {
        let mut result = Vec::new();
        for raw_line in self.content.lines() {
            if raw_line.is_empty() {
                result.push(String::new());
                continue;
            }
            // Chunk each source line into width-sized segments.
            let chars: Vec<char> = raw_line.chars().collect();
            let mut start = 0;
            while start < chars.len() {
                let end = (start + width).min(chars.len());
                result.push(chars[start..end].iter().collect());
                start = end;
            }
        }
        result
    }
}
