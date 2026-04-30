use ratatui::prelude::*;
use ratatui::widgets::{Block, Borders, Clear, Paragraph, Wrap};

use crate::event::Event;

use super::{Component, ComponentAction};

pub struct DiagnosticsPanel;

pub struct DiagnosticsData<'a> {
    pub session_id: &'a str,
    pub app_state: String,
    pub backend_status: &'a str,
    pub auth_status: &'a str,
    pub sse_reconnecting: bool,
    pub provider: &'a str,
    pub model: &'a str,
    pub active_agents: usize,
    pub active_tasks: usize,
    pub background_tasks: usize,
    pub last_backend_error: Option<&'a str>,
    pub recent_events: &'a [String],
}

impl DiagnosticsPanel {
    pub fn new() -> Self {
        Self
    }

    pub fn draw_with_data(&self, frame: &mut Frame, area: Rect, data: DiagnosticsData<'_>) {
        if area.width == 0 || area.height == 0 {
            return;
        }

        let theme = crate::style::theme();
        let width = area.width.min(64).max(area.width.min(36));
        let x = area.x + area.width.saturating_sub(width);
        let panel = Rect::new(x, area.y, width, area.height);
        let inner = Rect::new(
            panel.x.saturating_add(1),
            panel.y.saturating_add(1),
            panel.width.saturating_sub(2),
            panel.height.saturating_sub(2),
        );

        frame.render_widget(Clear, panel);
        frame.render_widget(
            Block::default()
                .title(" Diagnostics ")
                .title_alignment(Alignment::Left)
                .borders(Borders::ALL)
                .border_style(Style::default().fg(theme.colors.border))
                .style(Style::default().bg(theme.colors.modal_bg)),
            panel,
        );

        let sse = if data.sse_reconnecting {
            "reconnecting"
        } else if data.backend_status == "stream connected" {
            "connected"
        } else {
            "not connected"
        };
        let provider = value_or_unknown(data.provider);
        let model = value_or_unknown(data.model);
        let error = data.last_backend_error.unwrap_or("none");
        let active_agents = data.active_agents.to_string();
        let active_tasks = data.active_tasks.to_string();
        let background_tasks = data.background_tasks.to_string();

        let mut lines = vec![
            row("session", data.session_id, theme.colors.primary),
            row("state", &data.app_state, theme.colors.secondary),
            row("backend", data.backend_status, theme.colors.muted),
            row("auth", data.auth_status, theme.colors.muted),
            row("sse", sse, theme.colors.muted),
            row("provider", provider, theme.colors.muted),
            row("model", model, theme.colors.muted),
            row("agents", &active_agents, theme.colors.muted),
            row("tasks", &active_tasks, theme.colors.muted),
            row("background", &background_tasks, theme.colors.muted),
            Line::from(""),
            Line::from(vec![Span::styled("last error", theme.bold())]),
            Line::from(Span::styled(
                error.to_string(),
                Style::default().fg(theme.colors.error),
            )),
            Line::from(""),
            Line::from(vec![Span::styled("recent events", theme.bold())]),
        ];

        if data.recent_events.is_empty() {
            lines.push(Line::from(Span::styled("none", theme.faint())));
        } else {
            let available = inner.height.saturating_sub(lines.len() as u16) as usize;
            let take = available.max(1).min(data.recent_events.len());
            let start = data.recent_events.len().saturating_sub(take);
            for event in &data.recent_events[start..] {
                lines.push(Line::from(vec![
                    Span::styled("- ", theme.faint()),
                    Span::raw(event.clone()),
                ]));
            }
        }

        frame.render_widget(
            Paragraph::new(lines)
                .style(Style::default().bg(theme.colors.modal_bg))
                .wrap(Wrap { trim: true }),
            inner,
        );
    }
}

impl Component for DiagnosticsPanel {
    fn handle_event(&mut self, _event: &Event) -> ComponentAction {
        ComponentAction::Ignored
    }

    fn draw(&self, _frame: &mut Frame, _area: Rect) {}
}

fn row<'a>(label: &'a str, value: &'a str, color: Color) -> Line<'a> {
    Line::from(vec![
        Span::styled(format!("{label:<11}"), Style::default().fg(Color::DarkGray)),
        Span::styled(value, Style::default().fg(color)),
    ])
}

fn value_or_unknown(value: &str) -> &str {
    if value.is_empty() {
        "unknown"
    } else {
        value
    }
}
