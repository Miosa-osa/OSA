// Phase 2+: survey dialog fields — wire when survey results are persisted
#![allow(dead_code)]

/// Multi-step survey dialog with single/multi-select questions and free-text input.
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::{
    prelude::*,
    widgets::{Block, BorderType, Borders, Clear, Paragraph},
};
use unicode_width::UnicodeWidthStr;

// ── Action ──────────────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub enum SurveyAction {
    Submit(SurveyResult),
    Skip,
}

// ── Result types ────────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub struct SurveyResult {
    pub survey_id: String,
    pub answers: Vec<QuestionAnswer>,
}

#[derive(Debug, Clone)]
pub struct QuestionAnswer {
    pub question_index: usize,
    pub question_text: String,
    pub selected: Vec<String>,
    pub free_text: Option<String>,
}

// ── Question types ──────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub struct SurveyOption {
    pub label: String,
    pub description: Option<String>,
}

#[derive(Debug, Clone)]
pub struct SurveyQuestion {
    pub text: String,
    pub multi_select: bool,
    pub options: Vec<SurveyOption>,
    pub skippable: bool,
}

// ── Helpers ─────────────────────────────────────────────────────────────────

/// Rows a word-wrapped `text` occupies at `width` columns. Mirrors ratatui's
/// `Wrap { trim: true }` closely enough to reserve the right height.
pub(crate) fn wrapped_line_count(text: &str, width: u16) -> u16 {
    if width == 0 {
        return 1;
    }
    let width = width as usize;
    let mut rows: u16 = 1;
    let mut col = 0usize;
    for word in text.split_whitespace() {
        let w = UnicodeWidthStr::width(word).max(1);
        if col == 0 {
            col = w;
        } else if col + 1 + w <= width {
            col += 1 + w;
        } else {
            rows = rows.saturating_add(1);
            col = w;
        }
        // A single word longer than the line spills onto further rows.
        while col > width {
            rows = rows.saturating_add(1);
            col -= width;
        }
    }
    rows
}

// ── Focus mode ──────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum FocusMode {
    OptionList,
    FreeText,
}

// ── Dialog state ────────────────────────────────────────────────────────────

pub struct SurveyDialog {
    pub survey_id: String,
    pub questions: Vec<SurveyQuestion>,
    pub skippable: bool,
    current_step: usize,
    cursor: usize,
    checked: Vec<bool>,
    focus: FocusMode,
    free_text_buf: String,
    free_text_cursor: usize,
    answers: Vec<Option<QuestionAnswer>>,
}

impl SurveyDialog {
    pub fn new(survey_id: String, questions: Vec<SurveyQuestion>, skippable: bool) -> Self {
        let num_questions = questions.len();
        let initial_checked = questions
            .first()
            .map(|q| vec![false; q.options.len() + 1]) // +1 for "Type your own"
            .unwrap_or_default();
        Self {
            survey_id,
            questions,
            skippable,
            current_step: 0,
            cursor: 0,
            checked: initial_checked,
            focus: FocusMode::OptionList,
            free_text_buf: String::new(),
            free_text_cursor: 0,
            answers: vec![None; num_questions],
        }
    }

    // ── Helpers ─────────────────────────────────────────────────────────────

    fn current_question(&self) -> Option<&SurveyQuestion> {
        self.questions.get(self.current_step)
    }

    /// Total option count including the "Type your own" entry.
    fn option_count(&self) -> usize {
        self.current_question()
            .map(|q| q.options.len() + 1)
            .unwrap_or(0)
    }

    /// Whether the cursor is on the "Type your own" row.
    fn cursor_on_free_text(&self) -> bool {
        self.current_question()
            .map(|q| self.cursor == q.options.len())
            .unwrap_or(false)
    }

    fn save_current_answer(&mut self) {
        let Some(q) = self.questions.get(self.current_step) else {
            return;
        };
        let mut selected: Vec<String> = Vec::new();
        for (i, opt) in q.options.iter().enumerate() {
            if self.checked.get(i).copied().unwrap_or(false) {
                selected.push(opt.label.clone());
            }
        }
        // Check if free-text option is checked
        let free_text_idx = q.options.len();
        let has_free_text = self.checked.get(free_text_idx).copied().unwrap_or(false)
            && !self.free_text_buf.trim().is_empty();
        let free_text = if has_free_text {
            Some(self.free_text_buf.trim().to_string())
        } else {
            None
        };
        self.answers[self.current_step] = Some(QuestionAnswer {
            question_index: self.current_step,
            question_text: q.text.clone(),
            selected,
            free_text,
        });
    }

    fn load_step_state(&mut self) {
        let count = self.option_count();
        self.cursor = 0;
        self.focus = FocusMode::OptionList;
        self.free_text_buf.clear();
        self.free_text_cursor = 0;

        if let Some(Some(prev)) = self.answers.get(self.current_step) {
            // Restore previous selections
            let q = &self.questions[self.current_step];
            self.checked = vec![false; count];
            for (i, opt) in q.options.iter().enumerate() {
                if prev.selected.contains(&opt.label) {
                    self.checked[i] = true;
                }
            }
            if let Some(ref ft) = prev.free_text {
                self.free_text_buf = ft.clone();
                self.free_text_cursor = ft.len();
                let ft_idx = q.options.len();
                if ft_idx < self.checked.len() {
                    self.checked[ft_idx] = true;
                }
            }
        } else {
            self.checked = vec![false; count];
        }
    }

    fn advance(&mut self) -> Option<SurveyAction> {
        self.save_current_answer();
        if self.current_step + 1 >= self.questions.len() {
            return self.build_result();
        }
        self.current_step += 1;
        self.load_step_state();
        None
    }

    fn retreat(&mut self) -> Option<SurveyAction> {
        self.save_current_answer();
        if self.current_step == 0 {
            return None; // already at first step
        }
        self.current_step -= 1;
        self.load_step_state();
        None
    }

    fn build_result(&self) -> Option<SurveyAction> {
        let answers: Vec<QuestionAnswer> = self
            .answers
            .iter()
            .filter_map(|a| a.clone())
            .collect();
        Some(SurveyAction::Submit(SurveyResult {
            survey_id: self.survey_id.clone(),
            answers,
        }))
    }

    // ── Key handling ────────────────────────────────────────────────────────

    pub fn handle_key(&mut self, key: KeyEvent) -> Option<SurveyAction> {
        if key.modifiers.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) {
            return None;
        }

        // Global: Esc skips entire survey if skippable
        if key.code == KeyCode::Esc && self.skippable {
            return Some(SurveyAction::Skip);
        }

        match self.focus {
            FocusMode::OptionList => self.handle_key_option_list(key),
            FocusMode::FreeText => self.handle_key_free_text(key),
        }
    }

    fn handle_key_option_list(&mut self, key: KeyEvent) -> Option<SurveyAction> {
        let count = self.option_count();
        let multi = self
            .current_question()
            .map(|q| q.multi_select)
            .unwrap_or(false);

        match key.code {
            KeyCode::Up | KeyCode::Char('k') => {
                if count > 0 {
                    self.cursor = self.cursor.checked_sub(1).unwrap_or(count - 1);
                }
                None
            }
            KeyCode::Down | KeyCode::Char('j') => {
                if count > 0 {
                    self.cursor = (self.cursor + 1) % count;
                }
                None
            }
            KeyCode::Char(' ') if multi => {
                // Toggle checkbox in multi-select
                if self.cursor < self.checked.len() {
                    self.checked[self.cursor] = !self.checked[self.cursor];
                }
                None
            }
            KeyCode::Enter => {
                if self.cursor_on_free_text() {
                    // Switch to free-text input mode
                    let ft_idx = self.option_count() - 1;
                    if ft_idx < self.checked.len() {
                        self.checked[ft_idx] = true;
                    }
                    self.focus = FocusMode::FreeText;
                    None
                } else if multi {
                    // Confirm multi-select and advance
                    self.advance()
                } else {
                    // Single-select: select this option and auto-advance
                    // Clear all, set only current
                    for c in self.checked.iter_mut() {
                        *c = false;
                    }
                    if self.cursor < self.checked.len() {
                        self.checked[self.cursor] = true;
                    }
                    self.advance()
                }
            }
            KeyCode::Left | KeyCode::Char('b') => self.retreat(),
            KeyCode::Tab => {
                // If free-text has content, toggle to it
                if self.cursor_on_free_text() || !self.free_text_buf.is_empty() {
                    self.focus = FocusMode::FreeText;
                }
                None
            }
            _ => None,
        }
    }

    fn handle_key_free_text(&mut self, key: KeyEvent) -> Option<SurveyAction> {
        match key.code {
            KeyCode::Esc | KeyCode::Tab => {
                self.focus = FocusMode::OptionList;
                None
            }
            KeyCode::Enter => {
                // Confirm free text and advance
                self.advance()
            }
            KeyCode::Backspace => {
                if self.free_text_cursor > 0 {
                    let prev_len = self.free_text_buf[..self.free_text_cursor]
                        .chars()
                        .last()
                        .map(|c| c.len_utf8())
                        .unwrap_or(0);
                    let new_cursor = self.free_text_cursor - prev_len;
                    self.free_text_buf.drain(new_cursor..self.free_text_cursor);
                    self.free_text_cursor = new_cursor;
                }
                None
            }
            KeyCode::Left => {
                if self.free_text_cursor > 0 {
                    let prev_len = self.free_text_buf[..self.free_text_cursor]
                        .chars()
                        .last()
                        .map(|c| c.len_utf8())
                        .unwrap_or(0);
                    self.free_text_cursor -= prev_len;
                }
                None
            }
            KeyCode::Right => {
                if self.free_text_cursor < self.free_text_buf.len() {
                    let next_len = self.free_text_buf[self.free_text_cursor..]
                        .chars()
                        .next()
                        .map(|c| c.len_utf8())
                        .unwrap_or(0);
                    self.free_text_cursor += next_len;
                }
                None
            }
            KeyCode::Home => {
                self.free_text_cursor = 0;
                None
            }
            KeyCode::End => {
                self.free_text_cursor = self.free_text_buf.len();
                None
            }
            KeyCode::Char(c) => {
                self.free_text_buf.insert(self.free_text_cursor, c);
                self.free_text_cursor += c.len_utf8();
                None
            }
            _ => None,
        }
    }

    // ── Drawing ─────────────────────────────────────────────────────────────

    pub fn draw(&self, frame: &mut Frame, area: Rect) {
        let theme = crate::style::theme();

        // 70% width, 75% height
        let w = (area.width * 70 / 100).max(40).min(area.width);
        let h = (area.height * 75 / 100).max(12).min(area.height);
        let x = area.x + area.width.saturating_sub(w) / 2;
        let y = area.y + area.height.saturating_sub(h) / 2;
        let dialog_rect = Rect::new(x, y, w, h);

        frame.render_widget(Clear, dialog_rect);

        // Title with step counter
        let total = self.questions.len();
        let current = self.current_step + 1;
        // Short header label — Claude Code / Codex keep it under ~12 chars.
        let title = if total <= 1 {
            " Question ".to_string()
        } else {
            format!(" {} of {} ", current, total)
        };

        // Progress dots for the right side of the title
        let dots: String = (0..total)
            .map(|i| {
                if i <= self.current_step {
                    "\u{25CF}" // filled circle
                } else {
                    "\u{25CB}" // hollow circle
                }
            })
            .collect::<Vec<_>>()
            .join(" ");

        let block = Block::default()
            .title(Line::from(Span::styled(
                title,
                Style::default()
                    .fg(theme.colors.primary)
                    .add_modifier(Modifier::BOLD),
            )))
            .title(
                Line::from(Span::styled(
                    format!(" {} ", dots),
                    Style::default().fg(theme.colors.primary),
                ))
                .alignment(Alignment::Right),
            )
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(Style::default().fg(theme.colors.primary))
            .style(Style::default().bg(theme.colors.dialog_bg));
        frame.render_widget(block, dialog_rect);

        let inner = Rect::new(
            dialog_rect.x + 2,
            dialog_rect.y + 1,
            dialog_rect.width.saturating_sub(4),
            dialog_rect.height.saturating_sub(2),
        );
        if inner.height < 5 {
            return;
        }

        let Some(question) = self.current_question() else {
            return;
        };

        let mut cy = inner.y + 1;

        // Question text (bold). Questions are full sentences, so wrap them —
        // but cap the block at 3 rows so a runaway question can never push the
        // options (the part the operator has to interact with) off-screen.
        let q_rows = wrapped_line_count(&question.text, inner.width).clamp(1, 3);
        frame.render_widget(
            Paragraph::new(question.text.as_str())
                .wrap(ratatui::widgets::Wrap { trim: true })
                .style(
                    Style::default()
                        .fg(Color::White)
                        .add_modifier(Modifier::BOLD),
                ),
            Rect::new(inner.x, cy, inner.width, q_rows),
        );
        cy += q_rows;

        // Subtitle
        let subtitle = if question.multi_select {
            "Select one or more"
        } else {
            "Select one answer"
        };
        frame.render_widget(
            Paragraph::new(subtitle).style(Style::default().fg(theme.colors.muted)),
            Rect::new(inner.x, cy, inner.width, 1),
        );
        cy += 2;

        // Options — window scrolled so the cursor row (plus its description or
        // the free-text input line) is always visible on short terminals.
        let option_area_bottom = inner.y + inner.height.saturating_sub(2);
        let mut costs: Vec<u16> = question
            .options
            .iter()
            .map(|o| if o.description.is_some() { 2 } else { 1 })
            .collect();
        costs.push(2); // "Type your own answer" row + its input line
        let avail = option_area_bottom.saturating_sub(cy);
        let mut start = self.cursor.min(costs.len().saturating_sub(1));
        let mut used = costs[start];
        while start > 0 && used + costs[start - 1] <= avail {
            start -= 1;
            used += costs[start];
        }
        for (i, opt) in question.options.iter().enumerate().skip(start) {
            if cy >= option_area_bottom {
                break;
            }
            let is_selected = self.cursor == i && self.focus == FocusMode::OptionList;
            let is_checked = self.checked.get(i).copied().unwrap_or(false);

            // Indicator
            let indicator = if question.multi_select {
                if is_checked { "[x]" } else { "[ ]" }
            } else {
                if is_checked { " * " } else { " o " }
            };

            let line_style = if is_selected {
                Style::default().bg(theme.colors.primary).fg(Color::White)
            } else {
                Style::default().fg(Color::White)
            };

            let label = format!("{} {}", indicator, opt.label);
            frame.render_widget(
                Paragraph::new(label).style(line_style),
                Rect::new(inner.x, cy, inner.width, 1),
            );
            cy += 1;

            // Description (muted, indented)
            if let Some(ref desc) = opt.description {
                if cy < option_area_bottom {
                    let desc_style = if is_selected {
                        Style::default().bg(theme.colors.primary).fg(Color::White)
                    } else {
                        Style::default().fg(theme.colors.dim)
                    };
                    frame.render_widget(
                        Paragraph::new(format!("    {}", desc)).style(desc_style),
                        Rect::new(inner.x, cy, inner.width, 1),
                    );
                    cy += 1;
                }
            }
        }

        // "Type your own answer" option
        if cy < option_area_bottom {
            let ft_idx = question.options.len();
            let is_selected = self.cursor == ft_idx && self.focus == FocusMode::OptionList;
            let is_checked = self.checked.get(ft_idx).copied().unwrap_or(false);

            let indicator = if question.multi_select {
                if is_checked { "[x]" } else { "[ ]" }
            } else {
                if is_checked { " * " } else { " o " }
            };

            let line_style = if is_selected {
                Style::default().bg(theme.colors.primary).fg(Color::White)
            } else {
                Style::default().fg(Color::White)
            };

            frame.render_widget(
                Paragraph::new(format!("{} Type your own answer", indicator)).style(line_style),
                Rect::new(inner.x, cy, inner.width, 1),
            );
            cy += 1;

            // Free text input line
            if cy < option_area_bottom {
                let ft_display = if self.focus == FocusMode::FreeText {
                    format!("    {}", self.free_text_buf)
                } else if self.free_text_buf.is_empty() {
                    "    Type your answer...".to_string()
                } else {
                    format!("    {}", self.free_text_buf)
                };
                let ft_style = if self.focus == FocusMode::FreeText {
                    Style::default()
                        .fg(theme.colors.primary)
                        .add_modifier(Modifier::BOLD)
                } else {
                    Style::default().fg(theme.colors.dim)
                };
                let ft_area = Rect::new(inner.x, cy, inner.width, 1);
                frame.render_widget(
                    Paragraph::new(ft_display).style(ft_style),
                    ft_area,
                );
                // Position terminal cursor at the correct column when focused
                if self.focus == FocusMode::FreeText {
                    // 4 spaces indent + display width of text before cursor
                    let prefix_width = 4u16;
                    let text_before = &self.free_text_buf[..self.free_text_cursor];
                    let text_width = UnicodeWidthStr::width(text_before) as u16;
                    let cursor_x = ft_area.x + prefix_width + text_width;
                    let cursor_y = ft_area.y;
                    if cursor_x < ft_area.x + ft_area.width {
                        frame.set_cursor_position(Position::new(cursor_x, cursor_y));
                    }
                }
            }
        }

        // ── Bottom bar: keyboard hints (left: dismiss · right: nav) ─────────
        let bottom_y = inner.y + inner.height.saturating_sub(1);
        if self.skippable {
            frame.render_widget(
                Paragraph::new(Line::from(vec![
                    Span::styled("Esc", theme.dialog_help_key()),
                    Span::styled(" dismiss", theme.dialog_help()),
                ])),
                Rect::new(inner.x, bottom_y, inner.width, 1),
            );
        }

        let mut right: Vec<Span> = Vec::new();
        if question.multi_select {
            right.push(Span::styled("Space", theme.dialog_help_key()));
            right.push(Span::styled(" toggle   ", theme.dialog_help()));
        }
        if self.current_step > 0 {
            right.push(Span::styled("←", theme.dialog_help_key()));
            right.push(Span::styled(" back   ", theme.dialog_help()));
        }
        let is_last = self.current_step + 1 >= self.questions.len();
        right.push(Span::styled("Enter", theme.dialog_help_key()));
        right.push(Span::styled(
            if is_last { " submit" } else { " next" },
            Style::default()
                .fg(theme.colors.primary)
                .add_modifier(Modifier::BOLD),
        ));
        frame.render_widget(
            Paragraph::new(Line::from(right)).alignment(Alignment::Right),
            Rect::new(inner.x, bottom_y, inner.width, 1),
        );
    }
}
