// Phase 2+: active_form field — wired when task form tracking is added
#![allow(dead_code)]

use ratatui::prelude::*;
use ratatui::widgets::Paragraph;

use crate::event::Event;

use super::{Component, ComponentAction};

pub struct Tasks {
    items: Vec<TaskItem>,
}

pub struct TaskItem {
    pub id: String,
    pub subject: String,
    pub active_form: String,
    pub status: String,
}

impl Tasks {
    pub fn new() -> Self {
        Self { items: Vec::new() }
    }

    pub fn add(&mut self, id: String, subject: String, active_form: String) {
        if !self.items.iter().any(|t| t.id == id) {
            self.items.push(TaskItem {
                id,
                subject,
                active_form,
                status: "pending".into(),
            });
        }
    }

    pub fn update(&mut self, id: &str, status: &str) {
        if let Some(task) = self.items.iter_mut().find(|t| t.id == id) {
            task.status = status.to_string();
        }
    }

    pub fn height(&self) -> u16 {
        if self.items.is_empty() {
            0
        } else {
            self.items.len().min(5) as u16
        }
    }

    pub fn clear(&mut self) {
        self.items.clear();
    }
}

impl Component for Tasks {
    fn handle_event(&mut self, _event: &Event) -> ComponentAction {
        ComponentAction::Ignored
    }

    fn draw(&self, frame: &mut Frame, area: Rect) {
        if self.items.is_empty() || area.height == 0 {
            return;
        }
        let theme = crate::style::theme();

        for (i, task) in self.items.iter().enumerate() {
            if i as u16 >= area.height {
                break;
            }
            let row = Rect::new(area.x, area.y + i as u16, area.width, 1);
            let (icon, style) = match task.status.as_str() {
                "completed" => ("\u{2714}", theme.task_done()),
                "in_progress" => ("\u{25fc}", theme.task_active()),
                "failed" => ("\u{2718}", theme.task_failed()),
                _ => ("\u{25fb}", theme.task_pending()),
            };
            // The subject is model-written backend text rendered as a plain span:
            // strip inline markdown so `**bold**` doesn't show literally, and fit it
            // to the COLUMNS left after the "  {icon} " prefix. Previously it was
            // rendered raw with no width clamp and no wrap, so a long subject was
            // hard-clipped at the pane edge with no ellipsis. Height stays 1 row per
            // item, which is what `height()` reserves.
            let prefix = format!("  {} ", icon);
            let avail = (area.width as usize).saturating_sub(crate::util::cols(&prefix));
            let subject =
                crate::util::fit_cols(&crate::util::strip_inline_markdown(&task.subject), avail);
            let line = Line::from(vec![
                Span::styled(prefix, style),
                Span::styled(subject, style),
            ]);
            frame.render_widget(Paragraph::new(line), row);
        }
    }
}
