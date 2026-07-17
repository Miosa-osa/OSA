use std::collections::VecDeque;
use std::time::{Duration, Instant};

use ratatui::prelude::*;
use ratatui::widgets::Paragraph;

use crate::event::Event;

use super::{Component, ComponentAction};

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum ToastLevel {
    Info,
    Success,
    Warning,
    Error,
}

impl ToastLevel {
    /// Glyph at the head of the toast — one per level so severity reads at a
    /// glance without relying on colour alone.
    fn icon(self) -> &'static str {
        match self {
            ToastLevel::Info => "\u{2139}",    // ℹ
            ToastLevel::Success => "\u{2713}", // ✓
            ToastLevel::Warning => "\u{26a0}", // ⚠
            ToastLevel::Error => "\u{2718}",   // ✗
        }
    }

    /// On-screen dwell. Errors linger longest so they aren't missed; routine
    /// info clears quickly to stay out of the way.
    fn dwell(self) -> Duration {
        match self {
            ToastLevel::Info | ToastLevel::Success => Duration::from_secs(4),
            ToastLevel::Warning => Duration::from_secs(5),
            ToastLevel::Error => Duration::from_secs(6),
        }
    }

    #[allow(dead_code)]
    fn label(self) -> &'static str {
        match self {
            ToastLevel::Info => "info",
            ToastLevel::Success => "success",
            ToastLevel::Warning => "warning",
            ToastLevel::Error => "error",
        }
    }
}

struct Toast {
    message: String,
    level: ToastLevel,
    created: Instant,
}

/// A record of a notification that fired, retained after the toast itself has
/// cleared so the user has a lightweight scrollback of what happened.
#[allow(dead_code)]
pub struct ToastRecord {
    pub message: String,
    pub level: ToastLevel,
    pub at: Instant,
}

/// Most toasts shown at once — they stack one-per-row without overlap.
const MAX_VISIBLE: usize = 3;
/// Cap on the retained notification history.
const HISTORY_CAP: usize = 50;

pub struct Toasts {
    queue: Vec<Toast>,
    history: VecDeque<ToastRecord>,
}

impl Toasts {
    pub fn new() -> Self {
        Self {
            queue: Vec::new(),
            history: VecDeque::new(),
        }
    }

    pub fn push(&mut self, message: String, level: ToastLevel) {
        // Coalesce an immediate duplicate (same text + level) so repeated events
        // don't stack identical toasts — just refresh its dwell timer.
        if let Some(last) = self.queue.last_mut() {
            if last.level == level && last.message == message {
                last.created = Instant::now();
                return;
            }
        }

        self.history.push_back(ToastRecord {
            message: message.clone(),
            level,
            at: Instant::now(),
        });
        while self.history.len() > HISTORY_CAP {
            self.history.pop_front();
        }

        self.queue.push(Toast {
            message,
            level,
            created: Instant::now(),
        });
        // Keep only the newest MAX_VISIBLE live toasts on screen.
        while self.queue.len() > MAX_VISIBLE {
            self.queue.remove(0);
        }
    }

    pub fn tick(&mut self) {
        self.queue
            .retain(|t| t.created.elapsed() < t.level.dwell());
    }

    pub fn has_toasts(&self) -> bool {
        !self.queue.is_empty()
    }

    /// Recent notifications (oldest → newest), a scrollback record of what fired.
    #[allow(dead_code)]
    pub fn history(&self) -> impl Iterator<Item = &ToastRecord> {
        self.history.iter()
    }

    /// The last `n` notifications formatted as "<icon> <message>" lines.
    #[allow(dead_code)]
    pub fn recent_lines(&self, n: usize) -> Vec<String> {
        let start = self.history.len().saturating_sub(n);
        self.history
            .iter()
            .skip(start)
            .map(|r| format!("{} {}", r.level.icon(), r.message))
            .collect()
    }
}

impl Component for Toasts {
    fn handle_event(&mut self, _event: &Event) -> ComponentAction {
        ComponentAction::Ignored
    }

    fn draw(&self, frame: &mut Frame, area: Rect) {
        if area.width == 0 || area.height == 0 {
            return;
        }
        let theme = crate::style::theme();
        for (i, toast) in self.queue.iter().enumerate() {
            // One toast per row, top-down; never draw past the toast area.
            if i as u16 >= area.height {
                break;
            }
            let row = Rect::new(area.x, area.y + i as u16, area.width, 1);

            // Coherent per-level styling: info reads neutral, success green,
            // warning amber, error red — icon AND colour agree on severity.
            let style = match toast.level {
                ToastLevel::Info => theme.status_signal(),
                ToastLevel::Success => theme.task_done(),
                ToastLevel::Warning => theme.prefix_thinking(),
                ToastLevel::Error => theme.error_text(),
            };

            let raw = format!("{} {}", toast.level.icon(), toast.message);
            // Fit to the toast width so a long message can't spill/clip (the row
            // is right-aligned, so overflow would otherwise drop the start).
            let text = fit_to_width(&raw, area.width as usize);
            let line = Line::from(Span::styled(text, style));
            let p = Paragraph::new(line).alignment(Alignment::Right);
            frame.render_widget(p, row);
        }
    }
}

/// Clip a string to at most `max` display columns, appending an ellipsis when it
/// would overflow.
fn fit_to_width(s: &str, max: usize) -> String {
    if max == 0 {
        return String::new();
    }
    let count = s.chars().count();
    if count <= max {
        return s.to_string();
    }
    if max == 1 {
        return "\u{2026}".to_string();
    }
    let mut out: String = s.chars().take(max - 1).collect();
    out.push('\u{2026}');
    out
}
