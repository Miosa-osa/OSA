use ratatui::prelude::*;
use ratatui::widgets::Paragraph;

use crate::client::types::Signal;
use crate::event::Event;
use crate::style;

use super::{Component, ComponentAction};

pub struct StatusBar {
    signal: Option<Signal>,
    provider: String,
    model_name: String,
    context_utilization: f64,
    context_max: u64,
    context_estimated: u64,
    input_tokens: u64,
    output_tokens: u64,
    elapsed_ms: u64,
    llm_iteration: u32,
    active: bool,
    bg_count: usize,
    width: u16,
}

impl StatusBar {
    pub fn new() -> Self {
        Self {
            signal: None,
            provider: String::new(),
            model_name: String::new(),
            context_utilization: 0.0,
            context_max: 0,
            context_estimated: 0,
            input_tokens: 0,
            output_tokens: 0,
            elapsed_ms: 0,
            llm_iteration: 0,
            active: false,
            bg_count: 0,
            width: 0,
        }
    }

    pub fn set_provider_info(&mut self, provider: &str, model: &str) {
        self.provider = provider.to_string();
        self.model_name = model.to_string();
    }

    pub fn set_signal(&mut self, signal: Signal) {
        self.signal = Some(signal);
    }

    pub fn set_context(&mut self, utilization: f64, estimated: u64, max: u64) {
        self.context_utilization = utilization;
        self.context_estimated = estimated;
        self.context_max = max;
    }

    pub fn set_stats(&mut self, input: u64, output: u64, elapsed: u64) {
        self.input_tokens = input;
        self.output_tokens = output;
        self.elapsed_ms = elapsed;
    }

    pub fn set_active(&mut self, active: bool) {
        self.active = active;
    }

    pub fn set_iteration(&mut self, iteration: u32) {
        self.llm_iteration = iteration;
    }

    pub fn set_background_count(&mut self, count: usize) {
        self.bg_count = count;
    }

    pub fn set_width(&mut self, width: u16) {
        self.width = width;
    }

    pub fn context_utilization(&self) -> f64 {
        self.context_utilization
    }

    fn format_tokens(n: u64) -> String {
        if n >= 1000 {
            format!("{:.1}k", n as f64 / 1000.0)
        } else {
            n.to_string()
        }
    }

    /// Push signal mode pill + genre label into a span list.
    /// Renders as: ` · [ Code ] Spec` — mode in a colored pill, genre beside it.
    fn push_signal_pill<'a>(&'a self, spans: &mut Vec<Span<'a>>, theme: &style::Theme) {
        if let Some(ref signal) = self.signal {
            if !signal.mode.is_empty() {
                spans.push(Span::styled(" \u{00b7} ", theme.faint()));
                // Mode pill: " Mode " with colored background
                spans.push(Span::styled(
                    format!(" {} ", signal.mode),
                    theme.signal_pill(),
                ));
                // Genre label beside the pill
                if !signal.genre.is_empty() {
                    spans.push(Span::styled(
                        format!(" {}", signal.genre),
                        theme.signal_genre(),
                    ));
                }
                // Type indicator if present
                if !signal.signal_type.is_empty() {
                    spans.push(Span::styled(
                        format!(" \u{00b7} {}", signal.signal_type),
                        theme.faint(),
                    ));
                }
            }
        }
    }
}

impl Component for StatusBar {
    fn handle_event(&mut self, _event: &Event) -> ComponentAction {
        ComponentAction::Ignored
    }

    fn draw(&self, frame: &mut Frame, area: Rect) {
        let theme = style::theme();

        if self.active {
            // Active: show model · signal pill · iteration · tokens · context
            let mut spans: Vec<Span<'_>> = Vec::new();

            if !self.provider.is_empty() {
                spans.push(Span::styled(&self.provider, theme.header_provider()));
                spans.push(Span::styled("/", theme.faint()));
                spans.push(Span::styled(&self.model_name, theme.header_model()));
            }

            // Signal pill — always visible when classified
            self.push_signal_pill(&mut spans, &theme);

            if self.llm_iteration > 1 {
                spans.push(Span::styled(" \u{00b7} ", theme.faint()));
                spans.push(Span::styled(
                    format!("iter {}", self.llm_iteration),
                    theme.progress_label(),
                ));
            }

            if self.input_tokens > 0 || self.output_tokens > 0 {
                spans.push(Span::styled(" \u{00b7} ", theme.faint()));
                spans.push(Span::styled(
                    format!(
                        "{}/{} tokens",
                        Self::format_tokens(self.input_tokens),
                        Self::format_tokens(self.output_tokens),
                    ),
                    theme.progress_label(),
                ));
            }

            if self.context_max > 0 {
                let pct = (self.context_utilization * 100.0) as u32;
                spans.push(Span::styled(" \u{00b7} ", theme.faint()));
                spans.push(Span::styled(
                    format!("ctx {}%", pct),
                    theme.progress_label(),
                ));
            }

            let line = Line::from(spans);
            frame.render_widget(Paragraph::new(line), area);
        } else {
            // Idle: provider/model + signal pill + bg count + context bar
            let mut spans: Vec<Span<'_>> = Vec::new();

            if !self.provider.is_empty() {
                spans.push(Span::styled(&self.provider, theme.header_provider()));
                spans.push(Span::styled(" / ", theme.faint()));
                spans.push(Span::styled(&self.model_name, theme.header_model()));
            }

            // Signal pill — always visible when classified
            self.push_signal_pill(&mut spans, &theme);

            if self.bg_count > 0 {
                spans.push(Span::styled(" \u{00b7} ", theme.faint()));
                spans.push(Span::styled(
                    format!("{} bg", self.bg_count),
                    theme.faint(),
                ));
            }

            // Context bar on the right side if there's room
            if self.context_max > 0 && area.width > 60 {
                let bar_width = 15u16;
                let (bar, bar_style) =
                    theme.render_context_bar(self.context_utilization, bar_width);
                let pct = (self.context_utilization * 100.0) as u32;

                // Calculate padding
                let left_len: usize = spans.iter().map(|s| s.width()).sum();
                let right_text_len = 1 + bar.len() + 1 + format!("{}%", pct).len();
                let total = left_len + right_text_len;
                if area.width as usize > total {
                    let padding = area.width as usize - total;
                    spans.push(Span::raw(" ".repeat(padding)));
                }
                spans.push(Span::styled(bar, bar_style));
                spans.push(Span::styled(format!(" {}%", pct), theme.progress_label()));
            }

            let line = Line::from(spans);
            frame.render_widget(Paragraph::new(line), area);
        }
    }
}
