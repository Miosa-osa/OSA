use ratatui::prelude::*;
use ratatui::widgets::Paragraph;

// ─── ThinkingBox ──────────────────────────────────────────────────────────────

/// Collapsible panel that shows extended-thinking / reasoning content.
///
/// Collapsed (default):  ∴ Thinking… (alt+t to expand)
/// Expanded:             Borderless CC-style block — dim-italic "∴ Thinking…"
///                       label + 2-col-indented dim-italic content, capped at
///                       10 visible lines with an overflow indicator.
pub struct ThinkingBox {
    content: String,
    expanded: bool,
    title: String,
}

impl ThinkingBox {
    pub fn new() -> Self {
        Self {
            content: String::new(),
            // CC parity: thinking is collapsed to a one-liner by default.
            expanded: false,
            title: "∴ Thinking".to_string(),
        }
    }

    // ─── Mutation ──────────────────────────────────────────────────────────

    pub fn update(&mut self, text: &str) {
        self.content.push_str(text);
    }

    pub fn clear(&mut self) {
        self.content.clear();
    }

    // Thinking panel expand/collapse (alt+t — chat:thinkingToggle)
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
    /// - Expanded:  1 label line + content lines (max 10) + optional overflow line.
    pub fn height(&self, width: u16) -> u16 {
        if !self.expanded || self.content.is_empty() {
            return 1;
        }

        // Content is indented 2 columns under the label (CC paddingLeft=2).
        let inner_w = (width as usize).saturating_sub(2).max(1);
        let content_lines = self.wrap_lines(inner_w);
        let visible = content_lines.len().min(10);
        let overflow_line = if content_lines.len() > 10 { 1 } else { 0 };

        // 1 label line + visible content + optional overflow indicator
        1 + visible as u16 + overflow_line as u16
    }

    // ─── Draw ──────────────────────────────────────────────────────────────

    pub fn draw(&self, frame: &mut Frame, area: Rect) {
        if area.height == 0 || area.width == 0 {
            return;
        }

        let theme = crate::style::theme();

        if !self.expanded || self.content.is_empty() {
            // Collapsed: CC-style dim italic one-liner with the expand hint.
            let indicator = if self.content.is_empty() {
                "\u{2234} Thinking\u{2026}".to_string()
            } else {
                "\u{2234} Thinking\u{2026} (alt+t to expand)".to_string()
            };
            let line = Line::from(Span::styled(
                indicator,
                theme.faint().add_modifier(Modifier::ITALIC),
            ));
            frame.render_widget(Paragraph::new(line), area);
            return;
        }

        // Expanded — CC parity (AssistantThinkingMessage): no border. A
        // dim-italic "∴ Thinking…" label with the content indented two columns
        // beneath it, all dim italic.
        let inner_w = (area.width as usize).saturating_sub(2).max(1);
        let all_lines = self.wrap_lines(inner_w);
        let total = all_lines.len();
        let visible_count = total.min(10);
        let has_overflow = total > 10;

        let mut text_lines: Vec<Line<'_>> = Vec::with_capacity(visible_count + 2);
        text_lines.push(Line::from(Span::styled(
            format!("{}\u{2026}", self.title),
            theme.faint().add_modifier(Modifier::ITALIC),
        )));
        for l in &all_lines[..visible_count] {
            text_lines.push(Line::from(vec![
                Span::raw("  "),
                Span::styled(
                    l.clone(),
                    theme.thinking_content().add_modifier(Modifier::ITALIC),
                ),
            ]));
        }

        if has_overflow {
            text_lines.push(Line::from(Span::styled(
                format!("  … +{} lines", total - 10),
                theme.faint().add_modifier(Modifier::ITALIC),
            )));
        }

        let paragraph = Paragraph::new(Text::from(text_lines));

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
            // Chunk each source line into width-sized segments
            // (display-width aware — CJK/emoji safe).
            let mut current = String::new();
            let mut col = 0usize;
            for g in unicode_segmentation::UnicodeSegmentation::graphemes(raw_line, true) {
                let gw = unicode_width::UnicodeWidthStr::width(g);
                if col + gw > width && col > 0 {
                    result.push(std::mem::take(&mut current));
                    col = 0;
                }
                current.push_str(g);
                col += gw;
            }
            result.push(current);
        }
        result
    }
}

#[cfg(test)]
mod tests {
    use super::ThinkingBox;

    #[test]
    fn collapsed_by_default_toggle_expands() {
        let mut tb = ThinkingBox::new();
        tb.update("line one\nline two");
        assert_eq!(tb.height(80), 1, "collapsed by default");
        tb.toggle();
        assert!(tb.height(80) > 1, "expanded shows the bordered box");
    }
}
