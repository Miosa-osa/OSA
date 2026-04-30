// Phase 2+: task checklist constants and tick() — wired when animation lands
#![allow(dead_code)]

use ratatui::prelude::*;
use ratatui::widgets::{Block, BorderType, Borders, Paragraph};

const SPINNER_FRAMES: &[char] = &['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
const PANEL_WIDTH: u16 = 34;
const MAX_HEIGHT: u16 = 12;

pub struct ChecklistItem {
    pub id: String,
    pub subject: String,
    pub status: ChecklistStatus,
    pub active_form: Option<String>,
}

#[derive(Clone, PartialEq)]
pub enum ChecklistStatus {
    Pending,
    InProgress,
    Completed,
    Failed,
}

pub struct TaskChecklist {
    items: Vec<ChecklistItem>,
    visible: bool,
    tick: u64,
}

impl TaskChecklist {
    pub fn new() -> Self {
        Self {
            items: Vec::new(),
            visible: true,
            tick: 0,
        }
    }

    pub fn add(&mut self, id: String, subject: String, active_form: Option<String>) {
        if !self.items.iter().any(|i| i.id == id) {
            self.items.push(ChecklistItem {
                id,
                subject,
                status: ChecklistStatus::Pending,
                active_form,
            });
        }
    }

    pub fn update(&mut self, id: &str, status: ChecklistStatus) {
        if let Some(item) = self.items.iter_mut().find(|i| i.id == id) {
            item.status = status;
        }
    }

    pub fn show(&mut self) {
        self.visible = true;
    }

    pub fn hide(&mut self) {
        self.visible = false;
    }

    pub fn is_visible(&self) -> bool {
        self.visible && !self.items.is_empty()
    }

    pub fn tick(&mut self) {
        self.tick = self.tick.wrapping_add(1);
    }

    /// Total height including border (items + header line + 2 border rows).
    pub fn height(&self) -> u16 {
        // +2 for top/bottom border, +1 for the counter line
        ((self.items.len() + 3) as u16).min(MAX_HEIGHT)
    }

    pub fn clear(&mut self) {
        self.items.clear();
    }

    pub fn draw(&self, frame: &mut Frame, area: Rect) {
        if !self.is_visible() || area.width < PANEL_WIDTH || area.height < 4 {
            return;
        }

        let theme = crate::style::theme();
        let h = self.height();
        let w = PANEL_WIDTH.min(area.width);

        // Position: bottom-right of the given area
        let x = area.x + area.width.saturating_sub(w);
        let y = area.y + area.height.saturating_sub(h);
        let panel = Rect::new(x, y, w, h);

        let block = Block::default()
            .title(" Tasks ")
            .title_style(theme.section_title())
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(Style::default().fg(theme.colors.border));

        let inner = block.inner(panel);
        frame.render_widget(block, panel);

        if inner.height == 0 || inner.width == 0 {
            return;
        }

        let completed = self
            .items
            .iter()
            .filter(|i| i.status == ChecklistStatus::Completed)
            .count();
        let total = self.items.len();
        let max_subject_len = (inner.width as usize).saturating_sub(4); // "  X " prefix

        let mut lines: Vec<Line> = Vec::with_capacity(total + 1);

        // Counter line
        lines.push(Line::from(Span::styled(
            format!("  {} of {} completed", completed, total),
            theme.faint(),
        )));

        // Item lines
        let spinner_char = SPINNER_FRAMES[(self.tick as usize) % SPINNER_FRAMES.len()];
        for item in &self.items {
            let (icon, style) = match item.status {
                ChecklistStatus::Completed => ('✓', theme.task_done()),
                ChecklistStatus::InProgress => (spinner_char, theme.task_active()),
                ChecklistStatus::Pending => ('○', theme.task_pending()),
                ChecklistStatus::Failed => ('✗', theme.task_failed()),
            };

            let subject = if item.subject.len() > max_subject_len {
                format!("{}…", &item.subject[..max_subject_len.saturating_sub(1)])
            } else {
                item.subject.clone()
            };

            lines.push(Line::from(vec![
                Span::styled(format!("  {} ", icon), style),
                Span::styled(subject, style),
            ]));
        }

        let para = Paragraph::new(lines);
        frame.render_widget(para, inner);
    }
}
