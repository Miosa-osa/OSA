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
    recording: bool,
    recording_elapsed_secs: u64,
    transcribing: bool,
    audio_level: u8,
    download_label: String,
    download_pct: u8,
    hands_free: bool,
    fast_mode: bool,
    effort_level: String,
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
            recording: false,
            recording_elapsed_secs: 0,
            transcribing: false,
            audio_level: 0,
            download_label: String::new(),
            download_pct: 0,
            hands_free: false,
            fast_mode: false,
            effort_level: String::new(),
        }
    }

    pub fn set_provider_info(&mut self, provider: &str, model: &str) {
        self.provider = provider.to_string();
        self.model_name = model.to_string();
    }

    pub fn set_signal(&mut self, signal: Signal) {
        self.signal = Some(signal);
    }

    pub fn context_max_label(&self) -> String {
        if self.context_max >= 1_000_000 {
            format!("{}M context", self.context_max / 1_000_000)
        } else if self.context_max > 0 {
            format!("{}K context", self.context_max / 1024)
        } else {
            String::new()
        }
    }

    pub fn set_context(&mut self, utilization: f64, estimated: u64, max: u64) {
        self.context_utilization = utilization.clamp(0.0, 1.0);
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

    pub fn set_recording(&mut self, recording: bool) {
        self.recording = recording;
        if !recording {
            self.audio_level = 0;
            self.recording_elapsed_secs = 0;
        }
    }

    pub fn set_transcribing(&mut self, transcribing: bool) {
        self.transcribing = transcribing;
    }

    pub fn set_recording_elapsed(&mut self, secs: u64) {
        self.recording_elapsed_secs = secs;
    }

    pub fn set_audio_level(&mut self, level: u8) {
        self.audio_level = level;
    }

    pub fn set_download_progress(&mut self, label: &str, pct: u8) {
        self.download_label = label.to_string();
        self.download_pct = pct;
    }

    pub fn clear_download_progress(&mut self) {
        self.download_label.clear();
        self.download_pct = 0;
    }

    pub fn set_hands_free(&mut self, enabled: bool) {
        self.hands_free = enabled;
    }

    pub fn set_fast_mode(&mut self, enabled: bool, effort: &str) {
        self.fast_mode = enabled;
        self.effort_level = effort.to_string();
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

    fn push_fast_pill<'a>(&'a self, spans: &mut Vec<Span<'a>>, theme: &style::Theme) {
        if self.fast_mode {
            spans.push(Span::styled(" \u{00b7} ", theme.faint()));
            spans.push(Span::styled(
                " FAST ",
                Style::default()
                    .fg(Color::Black)
                    .bg(Color::LightGreen)
                    .add_modifier(Modifier::BOLD),
            ));
            if !self.effort_level.is_empty() {
                spans.push(Span::styled(
                    format!(" {}", self.effort_level),
                    theme.faint(),
                ));
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

        // Download progress indicator takes top priority
        if !self.download_label.is_empty() {
            let pct = self.download_pct;
            let bar_total = 20usize;
            let filled = (pct as usize * bar_total / 100).min(bar_total);
            let empty = bar_total - filled;
            let bar = format!(
                "[{}{}]",
                "\u{2588}".repeat(filled),
                "\u{2591}".repeat(empty)
            );
            let spans = vec![
                Span::styled(
                    format!("\u{21E9} Downloading {}: ", self.download_label),
                    Style::default()
                        .fg(Color::Cyan)
                        .add_modifier(Modifier::BOLD),
                ),
                Span::styled(bar, Style::default().fg(Color::Cyan)),
                Span::styled(format!(" {}%", pct), theme.progress_label()),
            ];
            let line = Line::from(spans);
            frame.render_widget(Paragraph::new(line), area);
            return;
        }

        // Recording indicator takes priority over everything
        if self.recording {
            let mins = self.recording_elapsed_secs / 60;
            let secs = self.recording_elapsed_secs % 60;
            let duration = format!(" {}:{:02}", mins, secs);

            let level = self.audio_level;
            let bar_total = 10usize;
            let filled = (level as usize * bar_total / 100).min(bar_total);
            let empty = bar_total - filled;
            let level_bar = format!("{}{}", "\u{2588}".repeat(filled), "\u{2591}".repeat(empty));
            let level_color = if level > 70 {
                Color::Red
            } else if level > 30 {
                Color::Green
            } else {
                Color::DarkGray
            };
            let mut spans = vec![
                Span::styled(
                    "\u{25C9} Recording",
                    Style::default().fg(Color::Red).add_modifier(Modifier::BOLD),
                ),
                Span::styled(duration, Style::default().fg(Color::Red)),
                Span::styled(" ", Style::default()),
                Span::styled(level_bar, Style::default().fg(level_color)),
            ];
            if self.hands_free {
                spans.push(Span::styled(
                    " \u{00b7} HF",
                    Style::default()
                        .fg(Color::Magenta)
                        .add_modifier(Modifier::BOLD),
                ));
                spans.push(Span::styled(
                    " \u{2014} auto-stop on silence",
                    theme.faint(),
                ));
            } else {
                spans.push(Span::styled(
                    " \u{2014} click \u{25C9} to stop \u{00b7} Esc cancel",
                    theme.faint(),
                ));
            }
            let line = Line::from(spans);
            frame.render_widget(Paragraph::new(line), area);
            return;
        }

        // Transcribing indicator — after recording stops, before result arrives
        if self.transcribing {
            let spans = vec![Span::styled(
                "\u{27F3} Transcribing...",
                Style::default()
                    .fg(Color::Yellow)
                    .add_modifier(Modifier::BOLD),
            )];
            let line = Line::from(spans);
            frame.render_widget(Paragraph::new(line), area);
            return;
        }

        if self.active {
            // Active: provider/model · signal pill · tokens · context · elapsed
            let mut spans: Vec<Span<'_>> = Vec::new();

            if !self.provider.is_empty() {
                spans.push(Span::styled(&self.provider, theme.header_provider()));
                spans.push(Span::styled(" / ", theme.faint()));
                spans.push(Span::styled(&self.model_name, theme.header_model()));
            }

            self.push_fast_pill(&mut spans, &theme);

            // Signal pill — always visible when classified
            self.push_signal_pill(&mut spans, &theme);

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

            // Only show context when we have real data (hide the broken 0%)
            if self.context_estimated > 0 && self.context_max > 0 {
                let pct = (self.context_utilization * 100.0).round() as u32;
                spans.push(Span::styled(" \u{00b7} ", theme.faint()));
                spans.push(Span::styled(
                    format!(
                        "ctx {}% ({}/{})",
                        pct,
                        Self::format_tokens(self.context_estimated),
                        Self::format_tokens(self.context_max),
                    ),
                    theme.progress_label(),
                ));
            }

            if self.elapsed_ms > 0 {
                spans.push(Span::styled(" \u{00b7} ", theme.faint()));
                let elapsed_label = if self.elapsed_ms >= 60_000 {
                    let mins = self.elapsed_ms / 60_000;
                    let secs = (self.elapsed_ms % 60_000) / 1000;
                    format!("{}m{}s", mins, secs)
                } else if self.elapsed_ms >= 1_000 {
                    format!("{:.1}s", self.elapsed_ms as f64 / 1000.0)
                } else {
                    format!("{}ms", self.elapsed_ms)
                };
                spans.push(Span::styled(elapsed_label, theme.progress_label()));
            }

            let line = Line::from(spans);
            frame.render_widget(Paragraph::new(line), area);
        } else {
            // Idle: provider/model · signal pill · tokens with context %
            let mut spans: Vec<Span<'_>> = Vec::new();

            if !self.provider.is_empty() {
                spans.push(Span::styled(&self.provider, theme.header_provider()));
                spans.push(Span::styled(" / ", theme.faint()));
                spans.push(Span::styled(&self.model_name, theme.header_model()));
            }

            self.push_fast_pill(&mut spans, &theme);

            // Signal pill — always visible when classified
            self.push_signal_pill(&mut spans, &theme);

            // Token display: show context usage like OpenClaw: "tokens 19.3k/1.0m (2%)"
            if self.context_estimated > 0 && self.context_max > 0 {
                let pct = (self.context_utilization * 100.0).round() as u32;
                spans.push(Span::styled(" \u{00b7} ", theme.faint()));
                spans.push(Span::styled(
                    format!(
                        "tokens {}/{} ({}%)",
                        Self::format_tokens(self.context_estimated),
                        Self::format_tokens(self.context_max),
                        pct,
                    ),
                    theme.progress_label(),
                ));
            } else if self.input_tokens > 0 || self.output_tokens > 0 {
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

            // Only show context when we have real data (hide the broken 0%)
            if self.context_estimated > 0 && self.context_max > 0 {
                let pct = (self.context_utilization * 100.0).round() as u32;
                spans.push(Span::styled(" \u{00b7} ", theme.faint()));
                spans.push(Span::styled(
                    format!(
                        "ctx {}% ({}/{})",
                        pct,
                        Self::format_tokens(self.context_estimated),
                        Self::format_tokens(self.context_max),
                    ),
                    theme.progress_label(),
                ));
            }

            if self.bg_count > 0 {
                spans.push(Span::styled(" \u{00b7} ", theme.faint()));
                spans.push(Span::styled(format!("{} bg", self.bg_count), theme.faint()));
            }

            if self.hands_free {
                spans.push(Span::styled(" \u{00b7} ", theme.faint()));
                spans.push(Span::styled(
                    "HF",
                    Style::default()
                        .fg(Color::Magenta)
                        .add_modifier(Modifier::BOLD),
                ));
            }

            let line = Line::from(spans);
            frame.render_widget(Paragraph::new(line), area);
        }
    }
}
