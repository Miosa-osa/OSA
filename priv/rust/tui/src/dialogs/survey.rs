// Phase 2+: survey dialog fields — wire when survey results are persisted
#![allow(dead_code)]

//! The `ask_user` question picker, rendered as an INLINE band in the chat flow.
//!
//! This used to be a centered 70% × 75% full-screen overlay. `ask_user` blocks
//! the whole turn on the operator, and burying the conversation behind a modal
//! is exactly the wrong trade: the user needs to SEE what was said in order to
//! answer. It is now a bounded band that sits directly above the composer — the
//! transcript above stays visible and scrollable, the composer stays on screen,
//! and the band never exceeds [`SURVEY_INLINE_CAP`] rows.
//!
//! ```text
//! ⁝ Waiting on answers for 3 questions        [turn: 7s, ↓53.6k] [×]
//!  Which visual direction should the CLI take?
//!  1  ◉  Minimal & terminal-native   Clean, keyboard-first, no chrome
//!  2  ○  Bold & expressive           Strong visuals, gradients
//!  z  ○  Type your answer here
//!
//!  [1/3]  ↑/↓ navigate · ←/→ question              ┃ Enter:select ┃
//! ```
//!
//! **The band is a reserved layout slot, never an overlay.** `App::survey_slot`
//! is the single source of truth shared by `desired_inline_height` (viewport
//! sizing) and `draw_inline` (layout) — the same contract the task checklist
//! uses. Handing ONE rect to TWO components is what let the checklist paint over
//! the streaming reply; the survey must never repeat that.

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::{prelude::*, widgets::Paragraph};
use unicode_width::UnicodeWidthStr;

use crate::util::{cols, fit_cols};

// ── Bounds ──────────────────────────────────────────────────────────────────

/// Hard ceiling on the rows the inline survey band may occupy.
///
/// 14 rows = header(1) + question(≤2) + options(≤8) + free-text(1) + spacer(1)
/// + footer(1). A 12-option question therefore scrolls INTERNALLY (see
/// [`option_window`]) instead of eating the screen: the conversation above the
/// band always keeps the rest of the terminal.
pub const SURVEY_INLINE_CAP: u16 = 14;

/// Most option rows drawn at once; the rest scroll within the window.
pub const MAX_VISIBLE_OPTIONS: u16 = 8;

/// Rows the band always spends around the option list: header(1) +
/// free-text row(1) + spacer(1) + footer(1). Question rows are counted
/// separately because they are width-dependent.
const CHROME_ROWS: u16 = 4;

/// Columns consumed by the `" 1 ◉  "` row lead-in (pad, gutter, pad, glyph,
/// double pad). Shared by the width budget and the renderer so the label column
/// can never disagree with where the label is actually painted.
const PREFIX_COLS: u16 = 6;

/// Minimum columns a description needs to be worth drawing. Below this the
/// description is DROPPED and the label takes the full width — descriptions
/// degrade before labels do.
const MIN_DESC_COLS: u16 = 12;

/// Longest header chip rendered before a question (the tool schema asks the
/// model for ≤12 characters; the client enforces it rather than trusting it).
const MAX_HEADER_COLS: usize = 12;

// ── Action ──────────────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub enum SurveyAction {
    Submit(SurveyResult),
    /// The operator declined (Esc, `x`, or the `[×]` affordance). Resolves the
    /// blocked tool with the non-fatal "No answer — you declined…" result.
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
    /// Short (≤12 col) categorising chip drawn before the question text.
    pub header: Option<String>,
    pub multi_select: bool,
    pub options: Vec<SurveyOption>,
    pub skippable: bool,
}

// ── Pure layout helpers ─────────────────────────────────────────────────────

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

/// Width budget for one option row: `(label_cols, Option<desc_cols>)`.
///
/// Descriptions align in a FIXED column so the list reads as a table rather than
/// a ragged edge. The label column is the widest label, clamped to 45% of the
/// content width so one long label cannot starve every description; when what is
/// left falls under [`MIN_DESC_COLS`] the description column is dropped entirely
/// and the label takes everything — descriptions degrade first, labels last.
///
/// Pure and column-aware; all fitting downstream goes through
/// [`crate::util::fit_cols`], never bytes or chars.
pub(crate) fn option_columns(width: u16, max_label_cols: u16) -> (u16, Option<u16>) {
    // One trailing column of padding so the full-bleed selection band never
    // butts against the terminal's far edge.
    let content = width.saturating_sub(PREFIX_COLS).saturating_sub(1);
    if content == 0 {
        return (0, None);
    }
    let ceiling = (content * 45 / 100).max(1);
    let label = max_label_cols.clamp(1, ceiling).min(content);
    let rest = content.saturating_sub(label).saturating_sub(2); // 2-col gap
    if rest >= MIN_DESC_COLS {
        (label, Some(rest))
    } else {
        (content, None)
    }
}

/// Rows the band spends on question text at `width`, capped at 2 so a runaway
/// question can never squeeze out the options the operator has to interact with.
pub(crate) fn question_rows(text: &str, width: u16) -> u16 {
    wrapped_line_count(text, width.max(1)).clamp(1, 2)
}

/// The `[start, start+len)` slice of options to draw so `cursor` stays visible
/// inside a window of `visible` rows. Pure, so the internal-scroll arithmetic is
/// testable without a terminal.
pub(crate) fn option_window(total: usize, cursor: usize, visible: usize) -> (usize, usize) {
    if visible == 0 || total == 0 {
        return (0, 0);
    }
    if total <= visible {
        return (0, total);
    }
    let half = visible / 2;
    let start = cursor.saturating_sub(half).min(total - visible);
    (start, visible)
}

/// Word-wrap `text` into at most `rows` lines of `width` columns, marking the
/// last line with `…` when text was dropped. Column-aware (never bytes/chars),
/// so CJK and emoji wrap at their true advance.
pub(crate) fn wrap_to(text: &str, width: u16, rows: u16) -> Vec<String> {
    if width == 0 || rows == 0 {
        return Vec::new();
    }
    let w_max = width as usize;
    let mut lines: Vec<String> = Vec::new();
    let mut cur = String::new();
    let mut cur_w = 0usize;
    let mut overflow = false;

    for word in text.split_whitespace() {
        let ww = cols(word);
        if cur_w == 0 {
            cur = fit_cols(word, w_max);
            cur_w = cols(&cur);
        } else if cur_w + 1 + ww <= w_max {
            cur.push(' ');
            cur.push_str(word);
            cur_w += 1 + ww;
        } else {
            if lines.len() as u16 + 1 >= rows {
                overflow = true;
                break;
            }
            lines.push(std::mem::take(&mut cur));
            cur = fit_cols(word, w_max);
            cur_w = cols(&cur);
        }
    }
    if !cur.is_empty() {
        lines.push(cur);
    }
    if overflow {
        if let Some(last) = lines.last_mut() {
            *last = fit_cols(&format!("{}\u{2026}", last), w_max);
        }
    }
    lines.truncate(rows as usize);
    lines
}

/// `1`..`9` for the first nine options, then a dim `·` — they stay reachable
/// with ↑/↓, the digit shortcut simply runs out.
pub(crate) fn digit_gutter(n: usize) -> String {
    if n < 9 {
        ((b'1' + n as u8) as char).to_string()
    } else {
        "\u{00b7}".to_string()
    }
}

/// Compact token count for the header chip: `53.6k`, `912`.
pub(crate) fn fmt_tokens(n: u64) -> String {
    if n >= 1000 {
        format!("{:.1}k", n as f64 / 1000.0)
    } else {
        n.to_string()
    }
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
    /// Live turn elapsed + session output tokens, mirrored in from the app tick
    /// so the header carries the same `[turn: …, ↓…]` chip the rest of the live
    /// region shows. Purely cosmetic; zero when unknown.
    turn_elapsed_secs: u64,
    turn_tokens: u64,
}

impl SurveyDialog {
    pub fn new(survey_id: String, questions: Vec<SurveyQuestion>, skippable: bool) -> Self {
        let num_questions = questions.len();
        let initial_checked = questions
            .first()
            .map(|q| vec![false; q.options.len() + 1]) // +1 for the free-text row
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
            turn_elapsed_secs: 0,
            turn_tokens: 0,
        }
    }

    /// Mirror the live turn clock / token counter into the header chip.
    pub fn set_turn_meta(&mut self, elapsed_secs: u64, tokens: u64) {
        self.turn_elapsed_secs = elapsed_secs;
        self.turn_tokens = tokens;
    }

    /// True while the free-text row is capturing keystrokes — the composer must
    /// not also be showing a cursor.
    pub fn is_typing(&self) -> bool {
        self.focus == FocusMode::FreeText
    }

    // ── State helpers ───────────────────────────────────────────────────────

    fn current_question(&self) -> Option<&SurveyQuestion> {
        self.questions.get(self.current_step)
    }

    /// Total selectable rows including the free-text (`z`) entry.
    fn option_count(&self) -> usize {
        self.current_question()
            .map(|q| q.options.len() + 1)
            .unwrap_or(0)
    }

    /// Index of the free-text row in cursor / `checked` space.
    fn free_text_index(&self) -> usize {
        self.current_question().map(|q| q.options.len()).unwrap_or(0)
    }

    fn cursor_on_free_text(&self) -> bool {
        self.cursor == self.free_text_index()
    }

    fn multi(&self) -> bool {
        self.current_question()
            .map(|q| q.multi_select)
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

    /// Rehydrate widget state for `current_step`. An ALREADY-ANSWERED question
    /// comes back showing what was chosen (radio filled, free text restored,
    /// cursor parked on the choice) rather than resetting to a blank list —
    /// ←/→ is review-and-revise, not answer-again-from-scratch.
    fn load_step_state(&mut self) {
        let count = self.option_count();
        self.cursor = 0;
        self.focus = FocusMode::OptionList;
        self.free_text_buf.clear();
        self.free_text_cursor = 0;
        self.checked = vec![false; count];

        let prev = match self.answers.get(self.current_step) {
            Some(Some(a)) => a.clone(),
            _ => return,
        };
        let q = &self.questions[self.current_step];
        for (i, opt) in q.options.iter().enumerate() {
            if prev.selected.contains(&opt.label) {
                self.checked[i] = true;
                self.cursor = i;
            }
        }
        if let Some(ref ft) = prev.free_text {
            self.free_text_buf = ft.clone();
            self.free_text_cursor = ft.len();
            let ft_idx = q.options.len();
            if ft_idx < self.checked.len() {
                self.checked[ft_idx] = true;
                self.cursor = ft_idx;
            }
        }
    }

    /// True when `step` already carries a saved answer (drives the "answered"
    /// cue shown while navigating with ←/→).
    pub(crate) fn step_is_answered(&self, step: usize) -> bool {
        matches!(
            self.answers.get(step),
            Some(Some(a)) if !a.selected.is_empty() || a.free_text.is_some()
        )
    }

    /// The value already chosen for `step`, if any.
    pub(crate) fn step_answer_summary(&self, step: usize) -> Option<String> {
        let a = self.answers.get(step)?.as_ref()?;
        if let Some(ref ft) = a.free_text {
            return Some(ft.clone());
        }
        if a.selected.is_empty() {
            return None;
        }
        Some(a.selected.join(", "))
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

    /// ←: previous question, saving what is on screen first. No-op on the first.
    fn retreat(&mut self) -> Option<SurveyAction> {
        self.save_current_answer();
        if self.current_step == 0 {
            return None;
        }
        self.current_step -= 1;
        self.load_step_state();
        None
    }

    /// →: next question WITHOUT submitting (review navigation). No-op on the
    /// last question — Enter is what submits.
    fn forward(&mut self) -> Option<SurveyAction> {
        self.save_current_answer();
        if self.current_step + 1 >= self.questions.len() {
            return None;
        }
        self.current_step += 1;
        self.load_step_state();
        None
    }

    fn build_result(&self) -> Option<SurveyAction> {
        let answers: Vec<QuestionAnswer> = self.answers.iter().filter_map(|a| a.clone()).collect();
        Some(SurveyAction::Submit(SurveyResult {
            survey_id: self.survey_id.clone(),
            answers,
        }))
    }

    /// Select exactly `idx` (single-select semantics).
    fn select_only(&mut self, idx: usize) {
        for c in self.checked.iter_mut() {
            *c = false;
        }
        if idx < self.checked.len() {
            self.checked[idx] = true;
        }
    }

    // ── Key handling ────────────────────────────────────────────────────────

    /// While the band is up it OWNS ↑/↓/←/→, Enter, the digit keys, `z`, `x` and
    /// Esc, and — in free-text mode — every printable character, so the composer
    /// can never steal the operator's typing. Ctrl/Alt chords fall through to the
    /// app so Ctrl+C still interrupts.
    pub fn handle_key(&mut self, key: KeyEvent) -> Option<SurveyAction> {
        if key
            .modifiers
            .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT)
        {
            return None;
        }

        // Esc declines from the option list. Without it the operator has no way
        // out and the turn deadlocks until the tool's own timeout fires. From
        // inside the free-text editor Esc only leaves the editor — declining
        // there would throw away what was just typed.
        if key.code == KeyCode::Esc && self.focus == FocusMode::OptionList {
            return Some(SurveyAction::Skip);
        }

        match self.focus {
            FocusMode::OptionList => self.handle_key_option_list(key),
            FocusMode::FreeText => self.handle_key_free_text(key),
        }
    }

    fn handle_key_option_list(&mut self, key: KeyEvent) -> Option<SurveyAction> {
        let count = self.option_count();
        let multi = self.multi();
        let ft_idx = self.free_text_index();

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
            // ←/→ move between QUESTIONS (the reference's `←/→ question`).
            KeyCode::Left => self.retreat(),
            KeyCode::Right => self.forward(),
            // The `[×]` dismiss affordance, on the keyboard. Mouse capture is
            // off outside the transcript reader (native wheel scrollback depends
            // on that), so the glyph is driven by `x` — identical to Esc.
            KeyCode::Char('x') | KeyCode::Char('X') => Some(SurveyAction::Skip),
            // `z` jumps straight to the free-text row and starts typing.
            KeyCode::Char('z') | KeyCode::Char('Z') => {
                self.cursor = ft_idx;
                if ft_idx < self.checked.len() {
                    if multi {
                        self.checked[ft_idx] = true;
                    } else {
                        self.select_only(ft_idx);
                    }
                }
                self.focus = FocusMode::FreeText;
                None
            }
            // Number keys jump directly: toggle in multi-select, pick-and-advance
            // in single-select (Claude Code / Codex behaviour).
            KeyCode::Char(c @ '1'..='9') => {
                let idx = (c as u8 - b'1') as usize;
                if idx >= ft_idx {
                    return None;
                }
                self.cursor = idx;
                if multi {
                    if idx < self.checked.len() {
                        self.checked[idx] = !self.checked[idx];
                    }
                    None
                } else {
                    self.select_only(idx);
                    self.advance()
                }
            }
            KeyCode::Char(' ') if multi => {
                if self.cursor < self.checked.len() {
                    self.checked[self.cursor] = !self.checked[self.cursor];
                }
                None
            }
            KeyCode::Enter => {
                if self.cursor_on_free_text() {
                    if ft_idx < self.checked.len() {
                        if multi {
                            self.checked[ft_idx] = true;
                        } else {
                            self.select_only(ft_idx);
                        }
                    }
                    self.focus = FocusMode::FreeText;
                    None
                } else if multi {
                    self.advance()
                } else {
                    let idx = self.cursor;
                    self.select_only(idx);
                    self.advance()
                }
            }
            KeyCode::Tab => {
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
            KeyCode::Enter => self.advance(),
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

    // ── Sizing ──────────────────────────────────────────────────────────────

    /// Rows the band wants at `width`. The SINGLE source of truth for BOTH
    /// `App::desired_inline_height` (viewport sizing) and `App::draw_inline`
    /// (layout) — via `App::survey_slot` — so the reserved band and the drawn
    /// band can never disagree by a row.
    ///
    /// Always ≤ [`SURVEY_INLINE_CAP`]: a 12-option question scrolls internally
    /// rather than growing the band.
    pub fn band_height(&self, width: u16) -> u16 {
        let Some(q) = self.current_question() else {
            return 0;
        };
        let q_rows = question_rows(&q.text, width.saturating_sub(2));
        let opt_rows = (q.options.len() as u16).min(MAX_VISIBLE_OPTIONS);
        CHROME_ROWS
            .saturating_add(q_rows)
            .saturating_add(opt_rows)
            .min(SURVEY_INLINE_CAP)
    }

    // ── Drawing ─────────────────────────────────────────────────────────────

    /// Draw the band into EXACTLY `area` — the rows the caller reserved via
    /// `App::survey_slot`. Nothing is painted outside it, so the streaming reply
    /// above and the composer below keep their own rows.
    pub fn draw_inline(&self, frame: &mut Frame, area: Rect) {
        if area.height == 0 || area.width == 0 {
            return;
        }
        let theme = crate::style::theme();
        let Some(question) = self.current_question() else {
            return;
        };

        // ── Header row — above the panel, on the terminal background ────────
        let total = self.questions.len();
        let head_left = if total <= 1 {
            "\u{22ee} Waiting on your answer".to_string()
        } else {
            format!("\u{22ee} Waiting on answers for {} questions", total)
        };
        let head_right = format!(
            "[turn: {}, \u{2193}{}] [\u{00d7}]",
            crate::components::status_bar::fmt_elapsed_compact(self.turn_elapsed_secs),
            fmt_tokens(self.turn_tokens),
        );
        let header_row = Rect::new(area.x, area.y, area.width, 1);
        let dim = Style::default().fg(theme.colors.dim);
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                fit_cols(&head_left, area.width as usize),
                dim,
            ))),
            header_row,
        );
        // Only when it fits WITHOUT colliding with the left label — otherwise
        // the two right-align into each other at narrow widths.
        if cols(&head_left) + cols(&head_right) + 2 <= area.width as usize {
            frame.render_widget(
                Paragraph::new(Line::from(Span::styled(head_right, dim)))
                    .alignment(Alignment::Right),
                header_row,
            );
        }
        if area.height < 2 {
            return;
        }

        // ── Panel — a quiet background block, no box-drawing frame ──────────
        let panel = Rect::new(area.x, area.y + 1, area.width, area.height - 1);
        let panel_style = Style::default().bg(theme.colors.dialog_bg);
        frame.render_widget(ratatui::widgets::Block::default().style(panel_style), panel);

        // Row budget INSIDE the panel. Everything derives from the rect we were
        // handed, so a short band degrades instead of overflowing.
        let footer_y = panel.y + panel.height - 1;
        let spacer: u16 = if panel.height >= 4 { 1 } else { 0 };
        let body_h = panel.height.saturating_sub(1 + spacer);
        if body_h == 0 {
            self.draw_footer(frame, panel, footer_y, &theme);
            return;
        }

        // Question rows, always leaving one body row for the free-text entry.
        let q_rows = question_rows(&question.text, panel.width.saturating_sub(2))
            .min(body_h.saturating_sub(1));
        let opt_visible = body_h.saturating_sub(q_rows).saturating_sub(1) as usize;

        let mut cy = panel.y;
        if q_rows > 0 {
            let chip = question
                .header
                .as_deref()
                .map(str::trim)
                .filter(|h| !h.is_empty())
                .map(|h| fit_cols(h, MAX_HEADER_COLS));
            let chip_w = chip.as_deref().map(|c| cols(c) as u16 + 2).unwrap_or(0);
            let text_w = panel.width.saturating_sub(2);
            for (i, line) in wrap_to(&question.text, text_w, q_rows).into_iter().enumerate() {
                let y = cy + i as u16;
                let mut spans: Vec<Span> = Vec::new();
                let mut avail = text_w;
                if i == 0 {
                    if let Some(ref c) = chip {
                        spans.push(Span::styled(format!(" {} ", c), theme.button_active()));
                        spans.push(Span::styled(" ", panel_style));
                        avail = avail.saturating_sub(chip_w + 1);
                    }
                }
                spans.push(Span::styled(
                    fit_cols(&line, avail as usize),
                    panel_style
                        .fg(theme.colors.primary)
                        .add_modifier(Modifier::BOLD),
                ));
                frame.render_widget(
                    Paragraph::new(Line::from(spans)).style(panel_style),
                    Rect::new(panel.x + 1, y, panel.width.saturating_sub(1), 1),
                );
            }
            cy += q_rows;
        }

        // ── Option rows (internally scrolled) ──────────────────────────────
        let (start, len) = option_window(question.options.len(), self.cursor, opt_visible);
        let max_label = question
            .options
            .iter()
            .map(|o| cols(&o.label) as u16)
            .max()
            .unwrap_or(0);
        let (label_w, desc_w) = option_columns(panel.width, max_label);

        for (n, opt) in question.options.iter().enumerate().skip(start).take(len) {
            let focused = self.cursor == n && self.focus == FocusMode::OptionList;
            // In a SINGLE-select question the focused row IS the pending choice,
            // so its radio reads filled — the reference design's `◉` on the
            // highlighted row. Multi-select keeps the glyph honest: it means
            // "toggled on", and Space is what toggles it.
            let checked = self.checked.get(n).copied().unwrap_or(false)
                || (focused && !question.multi_select);
            self.draw_row(
                frame,
                Rect::new(panel.x, cy, panel.width, 1),
                &digit_gutter(n),
                checked,
                focused,
                &opt.label,
                opt.description.as_deref(),
                label_w,
                desc_w,
                false,
                &theme,
            );
            cy += 1;
        }

        // ── Free-text (`z`) row — dimmest of all until typed into ───────────
        let ft_idx = self.free_text_index();
        let focused = self.cursor == ft_idx;
        let empty = self.free_text_buf.is_empty();
        let text = if empty {
            "Type your answer here".to_string()
        } else {
            self.free_text_buf.clone()
        };
        let ft_row = Rect::new(panel.x, cy, panel.width, 1);
        self.draw_row(
            frame,
            ft_row,
            "z",
            self.checked.get(ft_idx).copied().unwrap_or(false)
                || (focused && !question.multi_select),
            focused,
            &text,
            None,
            // The free-text value gets the WHOLE content width — it is a value,
            // not a label in a table column.
            panel.width.saturating_sub(PREFIX_COLS).saturating_sub(1),
            None,
            empty,
            &theme,
        );
        if self.focus == FocusMode::FreeText {
            let before = cols(&self.free_text_buf[..self.free_text_cursor]) as u16;
            let cx = ft_row.x + PREFIX_COLS + before;
            if cx < ft_row.x + ft_row.width {
                frame.set_cursor_position(Position::new(cx, ft_row.y));
            }
        }

        self.draw_footer(frame, panel, footer_y, &theme);
    }

    /// One option row: ` n  ◉  Label            description`.
    ///
    /// The focused row is a FULL-WIDTH lighter background band across the whole
    /// panel — no bracket, no arrow marker. Every span is fitted with
    /// [`crate::util::fit_cols`], so CJK/emoji labels reserve their true column
    /// advance and the row can never overflow its rect.
    #[allow(clippy::too_many_arguments)]
    fn draw_row(
        &self,
        frame: &mut Frame,
        row: Rect,
        gutter: &str,
        checked: bool,
        focused: bool,
        label: &str,
        desc: Option<&str>,
        label_w: u16,
        desc_w: Option<u16>,
        placeholder: bool,
        theme: &crate::style::Theme,
    ) {
        if row.width == 0 || row.height == 0 {
            return;
        }
        let bg = if focused {
            theme.colors.selection_bg
        } else {
            theme.colors.dialog_bg
        };
        let base = Style::default().bg(bg);

        let glyph = if checked { "\u{25c9}" } else { "\u{25cb}" };
        let glyph_style = if checked {
            base.fg(theme.colors.primary).add_modifier(Modifier::BOLD)
        } else {
            base.fg(theme.colors.muted)
        };
        let label_style = if placeholder {
            base.fg(theme.colors.dim)
        } else if focused {
            base.fg(theme.colors.primary).add_modifier(Modifier::BOLD)
        } else {
            base.add_modifier(Modifier::BOLD)
        };

        let label_w = label_w.min(row.width.saturating_sub(PREFIX_COLS)) as usize;
        let fitted = fit_cols(label, label_w);
        let pad = label_w.saturating_sub(cols(&fitted));

        let mut spans = vec![
            Span::styled(" ", base),
            Span::styled(fit_cols(gutter, 1), base.fg(theme.colors.dim)),
            Span::styled(" ", base),
            Span::styled(glyph, glyph_style),
            Span::styled("  ", base),
            Span::styled(fitted, label_style),
        ];
        if let (Some(d), Some(dw)) = (desc, desc_w) {
            spans.push(Span::styled(" ".repeat(pad + 2), base));
            spans.push(Span::styled(
                fit_cols(d, dw as usize),
                base.fg(theme.colors.muted),
            ));
        }
        frame.render_widget(Paragraph::new(Line::from(spans)).style(base), row);
    }

    /// `[1/3]  ↑/↓ navigate · ←/→ question             ┃ Enter:select ┃`
    fn draw_footer(&self, frame: &mut Frame, panel: Rect, y: u16, theme: &crate::style::Theme) {
        if y < panel.y || y >= panel.y + panel.height || panel.width == 0 {
            return;
        }
        let base = Style::default().bg(theme.colors.dialog_bg);
        let dim = base.fg(theme.colors.dim);
        let key = base.fg(theme.colors.secondary).add_modifier(Modifier::BOLD);
        let row = Rect::new(panel.x, y, panel.width, 1);

        let mut left = vec![
            Span::styled(" ", base),
            Span::styled(
                format!("[{}/{}]", self.current_step + 1, self.questions.len()),
                dim,
            ),
            Span::styled("  ", base),
            Span::styled("\u{2191}/\u{2193}", key),
            Span::styled(" navigate", dim),
        ];
        if self.questions.len() > 1 {
            left.push(Span::styled("  \u{00b7}  ", dim));
            left.push(Span::styled("\u{2190}/\u{2192}", key));
            left.push(Span::styled(" question", dim));
        }
        if self.multi() {
            left.push(Span::styled("  \u{00b7}  ", dim));
            left.push(Span::styled("Space", key));
            left.push(Span::styled(" toggle", dim));
        }
        // Reviewing an already-answered question: say so, and say what was picked.
        if let Some(sum) = self.step_answer_summary(self.current_step) {
            left.push(Span::styled("  \u{00b7}  ", dim));
            left.push(Span::styled(
                fit_cols(&format!("answered: {}", sum), 28),
                base.fg(theme.colors.success),
            ));
        }
        // Trim the whole hint line to the columns actually available so it can
        // never spill past the panel (and never collide with the Enter button).
        let btn_text = format!(
            " {} ",
            if self.focus == FocusMode::FreeText {
                "Enter:answer"
            } else if self.current_step + 1 >= self.questions.len() {
                "Enter:submit"
            } else {
                "Enter:select"
            }
        );
        let btn_w = cols(&btn_text) + 1;
        let left_budget = (row.width as usize).saturating_sub(btn_w + 1);
        let mut used = 0usize;
        let mut trimmed: Vec<Span> = Vec::new();
        for s in left {
            let w = cols(&s.content);
            if used + w > left_budget {
                break;
            }
            used += w;
            trimmed.push(s);
        }
        frame.render_widget(Paragraph::new(Line::from(trimmed)).style(base), row);

        if btn_w + 2 <= row.width as usize {
            frame.render_widget(
                Paragraph::new(Line::from(vec![
                    Span::styled(btn_text, theme.button_active()),
                    Span::styled(" ", base),
                ]))
                .alignment(Alignment::Right)
                .style(base),
                row,
            );
        }
    }
}
