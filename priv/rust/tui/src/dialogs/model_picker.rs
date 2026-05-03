/// Model picker dialog — enhanced browser with provider groups, size badges,
/// reasoning badges, and recently-used section.
///
/// # Actions to add to `DialogAction` in mod.rs:
/// ```
/// ModelPickerSelect { provider: String, model: String },
/// ModelPickerCancel,
/// ```
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::{
    prelude::*,
    widgets::{Block, BorderType, Borders, Clear, Paragraph},
};

use crate::client::types::ModelEntry;

const MAX_W: u16 = 80;
const MAX_H: u16 = 28;

// ── Action ──────────────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub enum ModelPickerAction {
    Select { provider: String, model: String },
    Cancel,
}

// ── Internal types ───────────────────────────────────────────────────────────

/// A logical group header row.
struct ModelGroup {
    provider: String,
    /// Indices into `ModelPicker::models`
    model_indices: Vec<usize>,
}

/// A single row in the rendered list — either a group header or a model entry.
#[derive(Clone)]
enum Row {
    Header(String),
    Model { model_idx: usize },
}

// ── State ────────────────────────────────────────────────────────────────────

pub struct ModelPicker {
    models: Vec<ModelEntry>,
    groups: Vec<ModelGroup>,
    /// Flat list of renderable rows (built on construction / filter change)
    rows: Vec<Row>,
    /// Current filter text typed by the user
    filter: String,
    /// Index into `rows` (headers are skipped during navigation)
    cursor: usize,
    scroll_offset: usize,
    /// Model names in MRU order (most-recent first)
    recent: Vec<String>,
}

impl ModelPicker {
    pub fn new(models: Vec<ModelEntry>, recent: Vec<String>) -> Self {
        let mut picker = Self {
            models,
            groups: Vec::new(),
            rows: Vec::new(),
            filter: String::new(),
            cursor: 0,
            scroll_offset: 0,
            recent,
        };
        picker.rebuild();
        picker
    }

    // ── Filter / rebuild ─────────────────────────────────────────────────────

    fn rebuild(&mut self) {
        let filter = self.filter.to_lowercase();

        // Partition into recent and non-recent groups
        let mut recent_indices: Vec<usize> = Vec::new();
        let mut by_provider: std::collections::BTreeMap<String, Vec<usize>> =
            std::collections::BTreeMap::new();

        for (i, m) in self.models.iter().enumerate() {
            let name_lc = m.name.to_lowercase();
            let provider_lc = m.provider.to_lowercase();
            let capability_lc = m.capabilities.join(" ").to_lowercase();
            let source_lc = m.source.clone().unwrap_or_default().to_lowercase();
            if !filter.is_empty()
                && !name_lc.contains(&filter)
                && !provider_lc.contains(&filter)
                && !capability_lc.contains(&filter)
                && !source_lc.contains(&filter)
            {
                continue;
            }
            if self.recent.contains(&m.name) {
                recent_indices.push(i);
            }
            by_provider.entry(m.provider.clone()).or_default().push(i);
        }

        // Build groups
        self.groups.clear();
        if !recent_indices.is_empty() {
            self.groups.push(ModelGroup {
                provider: "Recently Used".into(),
                model_indices: recent_indices,
            });
        }
        for (provider, indices) in by_provider {
            self.groups.push(ModelGroup {
                provider,
                model_indices: indices,
            });
        }

        // Build flat row list
        self.rows.clear();
        for g in &self.groups {
            self.rows.push(Row::Header(g.provider.clone()));
            for &idx in &g.model_indices {
                self.rows.push(Row::Model { model_idx: idx });
            }
        }

        // Clamp cursor to a selectable row
        self.cursor = self.cursor.min(self.rows.len().saturating_sub(1));
        self.ensure_on_model();
    }

    /// Advance cursor forward until it lands on a Model row.
    fn ensure_on_model(&mut self) {
        if self.rows.is_empty() {
            return;
        }
        // Try forward first
        let start = self.cursor;
        let mut i = self.cursor;
        loop {
            if matches!(self.rows[i], Row::Model { .. }) {
                self.cursor = i;
                return;
            }
            i = (i + 1) % self.rows.len();
            if i == start {
                break; // no model rows at all
            }
        }
    }

    fn move_up(&mut self) {
        if self.rows.is_empty() {
            return;
        }
        let start = self.cursor;
        let mut i = self.cursor;
        loop {
            i = if i == 0 { self.rows.len() - 1 } else { i - 1 };
            if matches!(self.rows[i], Row::Model { .. }) {
                self.cursor = i;
                break;
            }
            if i == start {
                break;
            }
        }
        self.adjust_scroll();
    }

    fn move_down(&mut self) {
        if self.rows.is_empty() {
            return;
        }
        let start = self.cursor;
        let mut i = self.cursor;
        loop {
            i = (i + 1) % self.rows.len();
            if matches!(self.rows[i], Row::Model { .. }) {
                self.cursor = i;
                break;
            }
            if i == start {
                break;
            }
        }
        self.adjust_scroll();
    }

    fn adjust_scroll(&mut self) {
        let visible = MAX_H as usize - 6; // header + filter + footer
        if self.cursor < self.scroll_offset {
            self.scroll_offset = self.cursor;
        } else if self.cursor >= self.scroll_offset + visible {
            self.scroll_offset = self.cursor - visible + 1;
        }
    }

    fn selected_model(&self) -> Option<&ModelEntry> {
        match self.rows.get(self.cursor)? {
            Row::Model { model_idx } => self.models.get(*model_idx),
            Row::Header(_) => None,
        }
    }

    fn model_count(&self) -> usize {
        self.rows
            .iter()
            .filter(|r| matches!(r, Row::Model { .. }))
            .count()
    }

    // ── Key handling ─────────────────────────────────────────────────────────

    pub fn handle_key(&mut self, key: KeyEvent) -> Option<ModelPickerAction> {
        if key
            .modifiers
            .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT)
        {
            return None;
        }

        match key.code {
            KeyCode::Esc => return Some(ModelPickerAction::Cancel),
            KeyCode::Enter => {
                if let Some(m) = self.selected_model() {
                    return Some(ModelPickerAction::Select {
                        provider: m.provider.clone(),
                        model: m.name.clone(),
                    });
                }
            }
            KeyCode::Up | KeyCode::Char('k') => self.move_up(),
            KeyCode::Down | KeyCode::Char('j') => self.move_down(),
            KeyCode::Backspace => {
                self.filter.pop();
                let old_cursor = self.cursor;
                self.rebuild();
                // Preserve cursor position rather than jumping to top
                self.cursor = old_cursor.min(self.rows.len().saturating_sub(1));
                self.ensure_on_model();
                self.adjust_scroll();
            }
            KeyCode::Char(c) => {
                self.filter.push(c);
                self.scroll_offset = 0;
                self.cursor = 0;
                self.rebuild();
            }
            _ => {}
        }
        None
    }

    // ── Drawing ───────────────────────────────────────────────────────────────

    pub fn draw(&self, frame: &mut Frame, area: Rect) {
        let theme = crate::style::theme();

        let w = MAX_W.min(area.width);
        let h = MAX_H.min(area.height);
        let x = area.x + area.width.saturating_sub(w) / 2;
        let y = area.y + area.height.saturating_sub(h) / 2;
        let dialog_rect = Rect::new(x, y, w, h);

        frame.render_widget(Clear, dialog_rect);

        let block = Block::default()
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(Style::default().fg(theme.colors.primary))
            .style(Style::default().bg(theme.colors.dialog_bg));
        frame.render_widget(block, dialog_rect);

        let inner = Rect::new(
            dialog_rect.x + 1,
            dialog_rect.y + 1,
            dialog_rect.width.saturating_sub(2),
            dialog_rect.height.saturating_sub(2),
        );
        if inner.height < 4 {
            return;
        }

        let mut cy = inner.y;

        // Title
        let title = Paragraph::new("Select Model")
            .style(theme.dialog_title())
            .alignment(Alignment::Center);
        frame.render_widget(title, Rect::new(inner.x, cy, inner.width, 1));
        cy += 1;

        // Filter bar
        let count = self.model_count();
        let filter_display = if self.filter.is_empty() {
            format!("  Filter: _  ({} models)", count)
        } else {
            format!("  Filter: {}_  ({} models)", self.filter, count)
        };
        let filter_para =
            Paragraph::new(filter_display).style(Style::default().fg(theme.colors.secondary));
        frame.render_widget(filter_para, Rect::new(inner.x, cy, inner.width, 1));
        cy += 1;

        // Separator
        let sep = "─".repeat(inner.width as usize);
        frame.render_widget(
            Paragraph::new(sep.as_str()).style(Style::default().fg(theme.colors.dim)),
            Rect::new(inner.x, cy, inner.width, 1),
        );
        cy += 1;

        // List area
        let list_h = inner.height.saturating_sub(cy - inner.y + 2); // 2 = separator + help

        // Empty state: show a centered message when the filter matches nothing
        if self.model_count() == 0 {
            if list_h > 0 {
                let msg_y = cy + list_h / 2;
                frame.render_widget(
                    Paragraph::new(Span::styled(
                        "No matching models",
                        Style::default().fg(theme.colors.muted),
                    ))
                    .alignment(Alignment::Center),
                    Rect::new(inner.x, msg_y, inner.width, 1),
                );
            }
        }

        let visible_rows = self
            .rows
            .iter()
            .skip(self.scroll_offset)
            .take(list_h as usize);

        for (rel_i, row) in visible_rows.enumerate() {
            let abs_i = rel_i + self.scroll_offset;
            let ry = cy + rel_i as u16;
            if ry >= cy + list_h {
                break;
            }

            match row {
                Row::Header(provider) => {
                    let header = format!("  {} ", provider.to_uppercase());
                    frame.render_widget(
                        Paragraph::new(header).style(
                            Style::default()
                                .fg(theme.colors.muted)
                                .add_modifier(Modifier::BOLD),
                        ),
                        Rect::new(inner.x, ry, inner.width, 1),
                    );
                }
                Row::Model { model_idx } => {
                    let m = &self.models[*model_idx];
                    let is_active = m.active.unwrap_or(false);
                    let is_selected = abs_i == self.cursor;

                    let dot = if is_active {
                        "●"
                    } else if m.configured {
                        "○"
                    } else {
                        "◌"
                    };
                    let dot_style = if is_active {
                        Style::default().fg(theme.colors.success)
                    } else if m.configured {
                        Style::default().fg(theme.colors.dim)
                    } else {
                        Style::default().fg(theme.colors.warning)
                    };

                    // Size badge
                    let size_badge = m.size.map(|s| {
                        let gb = s as f64 / 1_000_000_000.0;
                        if gb >= 1.0 {
                            format!(" {:.0}B", gb)
                        } else {
                            let mb = s as f64 / 1_000_000.0;
                            format!(" {:.0}M", mb)
                        }
                    });

                    // Context window badge
                    let ctx_badge = m.context_window.map(|tokens| {
                        if tokens >= 1_000_000 {
                            format!(" {}M ctx", tokens / 1_000_000)
                        } else if tokens >= 1_000 {
                            format!(" {}K ctx", tokens / 1_000)
                        } else {
                            format!(" {} ctx", tokens)
                        }
                    });

                    let has_cap = |needle: &str| m.capabilities.iter().any(|c| c == needle);
                    let has_reasoning = has_cap("reasoning")
                        || m.name.contains("reasoning")
                        || m.name.contains("think")
                        || m.name.contains("r1")
                        || m.name.contains("o1")
                        || m.name.contains("o3");

                    let row_style = if is_selected {
                        Style::default()
                            .fg(theme.colors.primary)
                            .add_modifier(Modifier::BOLD)
                    } else {
                        Style::default().fg(theme.colors.muted)
                    };

                    let cursor_char = if is_selected { "▸" } else { " " };

                    let mut spans = vec![
                        Span::styled(format!("{} ", cursor_char), row_style),
                        Span::styled(dot, dot_style),
                        Span::raw(" "),
                        Span::styled(m.name.clone(), row_style),
                    ];

                    if let Some(badge) = &size_badge {
                        spans.push(Span::styled(
                            badge.clone(),
                            Style::default().fg(theme.colors.dim),
                        ));
                    }

                    if let Some(badge) = &ctx_badge {
                        spans.push(Span::styled(
                            badge.clone(),
                            Style::default().fg(theme.colors.dim),
                        ));
                    }

                    if has_reasoning {
                        spans.push(Span::styled(
                            " ⚡reasoning",
                            Style::default().fg(theme.colors.warning),
                        ));
                    }

                    if has_cap("coding") || has_cap("agent") {
                        spans.push(Span::styled(
                            " code",
                            Style::default().fg(theme.colors.secondary),
                        ));
                    }

                    if has_cap("cloud") || m.source.as_deref() == Some("ollama-cloud") {
                        spans.push(Span::styled(
                            " cloud",
                            Style::default().fg(theme.colors.primary),
                        ));
                    }

                    if !m.configured {
                        spans.push(Span::styled(
                            " setup",
                            Style::default().fg(theme.colors.warning),
                        ));
                    }

                    let line = Line::from(spans);
                    frame.render_widget(
                        Paragraph::new(line),
                        Rect::new(inner.x, ry, inner.width, 1),
                    );
                }
            }
        }

        // Help bar at bottom
        let bottom_y = inner.y + inner.height.saturating_sub(1);
        let help = Line::from(vec![
            Span::styled("↑↓/jk", theme.dialog_help_key()),
            Span::styled(" nav  ", theme.dialog_help()),
            Span::styled("Enter", theme.dialog_help_key()),
            Span::styled(" select  ", theme.dialog_help()),
            Span::styled("Esc", theme.dialog_help_key()),
            Span::styled(" cancel  ", theme.dialog_help()),
            Span::styled("type", theme.dialog_help_key()),
            Span::styled(" filter", theme.dialog_help()),
        ]);
        frame.render_widget(
            Paragraph::new(help).alignment(Alignment::Center),
            Rect::new(inner.x, bottom_y, inner.width, 1),
        );
    }
}
