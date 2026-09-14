use ratatui::prelude::*;
use ratatui::widgets::Paragraph;

use crate::event::Event;
use crate::style;

use super::{Component, ComponentAction};

pub struct Header {
    provider: String,
    model_name: String,
    version: String,
    tool_count: usize,
}

impl Header {
    pub fn new() -> Self {
        Self {
            provider: String::new(),
            model_name: String::new(),
            version: env!("CARGO_PKG_VERSION").to_string(),
            tool_count: 0,
        }
    }

    pub fn set_provider_info(&mut self, provider: &str, model: &str) {
        self.provider = provider.to_string();
        self.model_name = model.to_string();
    }

    pub fn set_tool_count(&mut self, count: usize) {
        self.tool_count = count;
    }

    pub fn tool_count(&self) -> usize {
        self.tool_count
    }

    pub fn provider(&self) -> &str {
        &self.provider
    }

    pub fn model_name(&self) -> &str {
        &self.model_name
    }

    /// Compact one-liner: "OSA v0.2.5 . provider / model . N tools"
    pub fn draw_compact(&self, frame: &mut Frame, area: Rect) {
        let theme = style::theme();

        let mut spans = vec![
            Span::styled("OSA ", theme.banner_title()),
            Span::styled(format!("v{}", self.version), theme.header_version()),
        ];

        if !self.provider.is_empty() {
            spans.push(Span::styled(" \u{00b7} ", theme.header_separator()));
            spans.push(Span::styled(&self.provider, theme.header_provider()));
            spans.push(Span::styled(" / ", theme.header_separator()));
            spans.push(Span::styled(&self.model_name, theme.header_model()));
        }

        if self.tool_count > 0 {
            spans.push(Span::styled(" \u{00b7} ", theme.header_separator()));
            spans.push(Span::styled(
                format!("{} tools", self.tool_count),
                theme.faint(),
            ));
        }

        let line = Line::from(spans);
        let header = Paragraph::new(line);
        frame.render_widget(header, area);

        // Separator line
        if area.height > 1 {
            let sep_area = Rect::new(area.x, area.y + 1, area.width, 1);
            let separator = Paragraph::new("\u{2500}".repeat(area.width as usize))
                .style(theme.header_separator());
            frame.render_widget(separator, sep_area);
        }
    }
}

impl Component for Header {
    fn handle_event(&mut self, _event: &Event) -> ComponentAction {
        ComponentAction::Ignored
    }

    fn draw(&self, frame: &mut Frame, area: Rect) {
        self.draw_compact(frame, area);
    }
}
