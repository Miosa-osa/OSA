// Full-screen transcript overlay (Claude Code Ctrl+O style).
//
// This is ADDITIVE. OSA renders finalized conversation into the host terminal's
// native scrollback (the correct, primary history surface) and that behaviour is
// untouched. The transcript viewer is an on-demand reader layered on top of it:
// it re-renders the full in-memory conversation in a scrollable, searchable,
// selectable full-viewport overlay so the user can jump around and copy without
// fighting the terminal's own scrollback.
//
// State (scroll / cursor / search) lives in `TranscriptViewer`. The conversation
// itself is retained in `App::transcript_log` as finalized messages drain into
// native scrollback (see `entry_from_message`), so the overlay never has to fight
// the chat store for ownership.
#![allow(dead_code)]

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::prelude::*;
use ratatui::widgets::{Clear, Paragraph};
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

use crate::components::chat::message::{Message, MessageType};
use crate::style;

/// Speaker role for a captured transcript entry (drives colour + header label).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TranscriptRole {
    User,
    Agent,
    Tool,
    System,
}

impl TranscriptRole {
    fn label(self) -> &'static str {
        match self {
            TranscriptRole::User => "You",
            TranscriptRole::Agent => "OSA",
            TranscriptRole::Tool => "tool",
            TranscriptRole::System => "system",
        }
    }

    fn color(self, theme: &style::Theme) -> Color {
        match self {
            TranscriptRole::User => theme.colors.msg_border_user,
            TranscriptRole::Agent => theme.colors.msg_border_agent,
            TranscriptRole::Tool => theme.colors.muted,
            TranscriptRole::System => theme.colors.warning,
        }
    }

    fn header_style(self, theme: &style::Theme) -> Style {
        Style::default()
            .fg(self.color(theme))
            .add_modifier(Modifier::BOLD)
    }

    fn body_style(self, theme: &style::Theme) -> Style {
        match self {
            TranscriptRole::Tool | TranscriptRole::System => {
                Style::default().fg(theme.colors.muted)
            }
            _ => Style::default(),
        }
    }
}

/// One captured conversation message, retained for the transcript viewer.
#[derive(Debug, Clone)]
pub struct TranscriptEntry {
    pub role: TranscriptRole,
    pub text: String,
}

/// Build a `TranscriptEntry` from a finalized chat `Message`. Returns `None` for
/// messages that carry no useful text to log (e.g. the styled Help block).
pub fn entry_from_message(msg: &Message) -> Option<TranscriptEntry> {
    let role = match msg.msg_type {
        MessageType::User => TranscriptRole::User,
        MessageType::Agent | MessageType::AgentContinuation => TranscriptRole::Agent,
        MessageType::SystemInfo | MessageType::SystemWarning | MessageType::SystemError => {
            TranscriptRole::System
        }
        MessageType::ToolCall => TranscriptRole::Tool,
        MessageType::SurveyQA => TranscriptRole::System,
        MessageType::Help => return None,
    };

    // Rich tool calls / survey summaries carry no `content` — reconstruct their
    // text from the structured data instead.
    let text = if let Some(ref td) = msg.tool_data {
        td.lines
            .iter()
            .map(line_to_plain)
            .collect::<Vec<_>>()
            .join("\n")
    } else if let Some(ref sd) = msg.survey_data {
        sd.pairs
            .iter()
            .map(|(q, a)| format!("Q: {}\nA: {}", q, a))
            .collect::<Vec<_>>()
            .join("\n")
    } else {
        msg.content.clone()
    };

    let text = text.trim_end().to_string();
    if text.is_empty() {
        return None;
    }
    Some(TranscriptEntry { role, text })
}

fn line_to_plain(line: &Line) -> String {
    line.spans.iter().map(|s| s.content.as_ref()).collect()
}

/// Action bubbled back to the app after a key is routed to the overlay.
pub enum TranscriptAction {
    /// Nothing further for the app to do.
    None,
    /// Close the overlay.
    Close,
    /// Surface a toast (e.g. copy result).
    Toast(String),
}

/// A single flattened, wrapped visual line, tagged with its source entry so the
/// cursor can map back to a full message for copy-of-selection.
struct FlatLine {
    entry: usize,
    role: TranscriptRole,
    is_header: bool,
    text: String,
}

/// Full-screen transcript reader state.
pub struct TranscriptViewer {
    /// Index (into the flattened line list) of the top visible row.
    scroll: usize,
    /// Selected line — the copy-of-selection target and search anchor.
    cursor: usize,
    /// True while typing an incremental search query.
    searching: bool,
    /// Current search query.
    query: String,
    /// Flattened line indices matching the confirmed query.
    matches: Vec<usize>,
}

impl TranscriptViewer {
    /// Open at the bottom of the transcript (most recent message), like a pager.
    pub fn open(entries: &[TranscriptEntry]) -> Self {
        let (w, h) = viewport();
        let flat = flatten(entries, body_width(w));
        let total = flat.len();
        let view_h = view_height(h);
        let mut v = Self {
            scroll: 0,
            cursor: total.saturating_sub(1),
            searching: false,
            query: String::new(),
            matches: Vec::new(),
        };
        v.ensure_visible(view_h, total);
        v
    }

    pub fn handle_key(&mut self, key: KeyEvent, entries: &[TranscriptEntry]) -> TranscriptAction {
        let (w, h) = viewport();
        let flat = flatten(entries, body_width(w));
        let total = flat.len();
        let view_h = view_height(h);

        // Search-input mode captures typing until Enter/Esc.
        if self.searching {
            match key.code {
                KeyCode::Esc => {
                    self.searching = false;
                    self.query.clear();
                    self.matches.clear();
                }
                KeyCode::Enter => {
                    self.searching = false;
                    self.recompute_matches(&flat);
                    self.jump_to_match_from_cursor(false);
                    self.ensure_visible(view_h, total);
                }
                KeyCode::Backspace => {
                    self.query.pop();
                }
                KeyCode::Char(c) => {
                    self.query.push(c);
                }
                _ => {}
            }
            return TranscriptAction::None;
        }

        match (key.code, key.modifiers) {
            // Ctrl+O toggles the overlay closed (matches the open binding).
            (KeyCode::Char('o'), KeyModifiers::CONTROL) => return TranscriptAction::Close,
            (KeyCode::Esc, _) | (KeyCode::Char('q'), KeyModifiers::NONE) => {
                return TranscriptAction::Close
            }
            (KeyCode::Up, _) | (KeyCode::Char('k'), KeyModifiers::NONE) => {
                self.move_cursor(-1, total)
            }
            (KeyCode::Down, _) | (KeyCode::Char('j'), KeyModifiers::NONE) => {
                self.move_cursor(1, total)
            }
            (KeyCode::PageUp, _) | (KeyCode::Char('u'), KeyModifiers::CONTROL) => {
                self.move_cursor(-(view_h as isize), total)
            }
            (KeyCode::PageDown, _) | (KeyCode::Char('d'), KeyModifiers::CONTROL) => {
                self.move_cursor(view_h as isize, total)
            }
            (KeyCode::Home, _) | (KeyCode::Char('g'), KeyModifiers::NONE) => {
                self.cursor = 0;
            }
            (KeyCode::End, _) | (KeyCode::Char('G'), _) => {
                self.cursor = total.saturating_sub(1);
            }
            (KeyCode::Char('/'), _) => {
                self.searching = true;
                self.query.clear();
                self.matches.clear();
                return TranscriptAction::None;
            }
            (KeyCode::Char('n'), KeyModifiers::NONE) => self.jump_to_match_from_cursor(false),
            (KeyCode::Char('N'), _) | (KeyCode::Char('n'), KeyModifiers::SHIFT) => {
                self.jump_to_match_from_cursor(true)
            }
            (KeyCode::Char('y'), KeyModifiers::NONE) => {
                if let Some(text) = self.selected_entry_text(&flat, entries) {
                    return copy_to_clipboard(&text, "Copied message to clipboard");
                }
            }
            (KeyCode::Char('Y'), _) => {
                let all = entries
                    .iter()
                    .map(|e| format!("{}:\n{}", e.role.label(), e.text))
                    .collect::<Vec<_>>()
                    .join("\n\n");
                return copy_to_clipboard(&all, "Copied full transcript to clipboard");
            }
            _ => {}
        }

        self.ensure_visible(view_h, total);
        TranscriptAction::None
    }

    /// Scroll the reader by `delta` visual lines (negative = up) in response to a
    /// mouse-wheel tick. Returns `true` only when a downward scroll is requested
    /// while the view is already parked at the last line — the caller reads that
    /// as "scrolled off the bottom" and dismisses the overlay cleanly.
    pub fn scroll_by(&mut self, delta: isize, entries: &[TranscriptEntry]) -> bool {
        let (w, h) = viewport();
        let flat = flatten(entries, body_width(w));
        let total = flat.len();
        let view_h = view_height(h);
        let at_bottom = self.cursor + 1 >= total;
        if delta > 0 && at_bottom {
            return true;
        }
        self.move_cursor(delta, total);
        self.ensure_visible(view_h, total);
        false
    }

    pub fn draw(&self, frame: &mut Frame, area: Rect, entries: &[TranscriptEntry]) {
        let theme = style::theme();
        frame.render_widget(Clear, area);

        let rows = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Length(1), // header bar
                Constraint::Min(1),    // body
                Constraint::Length(1), // footer / search input
            ])
            .split(area);

        // ── Header ────────────────────────────────────────────────────
        let header = Line::from(vec![
            Span::styled(
                " \u{27D0} Transcript ",
                Style::default()
                    .fg(theme.colors.primary)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(format!("\u{00B7} {} messages", entries.len()), theme.faint()),
        ]);
        frame.render_widget(Paragraph::new(header), rows[0]);

        // ── Body ──────────────────────────────────────────────────────
        let body = rows[1];
        let flat = flatten(entries, body_width(body.width));
        let total = flat.len();
        let view_h = body.height as usize;
        let max_scroll = total.saturating_sub(view_h);
        let scroll = self.scroll.min(max_scroll);
        let cursor = self.cursor.min(total.saturating_sub(1));
        let query = (!self.query.is_empty()).then(|| self.query.to_lowercase());

        let mut lines: Vec<Line<'static>> = Vec::with_capacity(view_h);
        if total > 0 {
            let end = (scroll + view_h).min(total);
            for i in scroll..end {
                lines.push(render_line(
                    &flat[i],
                    i == cursor,
                    query.as_deref(),
                    &theme,
                    body.width,
                ));
            }
        }
        frame.render_widget(Paragraph::new(lines), body);

        // ── Footer ────────────────────────────────────────────────────
        let footer = if self.searching {
            Line::from(vec![
                Span::styled(" /", Style::default().fg(theme.colors.primary)),
                Span::styled(
                    self.query.clone(),
                    Style::default().fg(theme.colors.primary),
                ),
                Span::styled("\u{258F}", Style::default().fg(theme.colors.primary)),
                Span::styled("  enter to search \u{00B7} esc to cancel", theme.faint()),
            ])
        } else if self.matches.is_empty() {
            Line::from(Span::styled(
                " \u{2191}\u{2193}/jk scroll \u{00B7} PgUp/PgDn \u{00B7} g/G top/bottom \u{00B7} / search \u{00B7} y copy \u{00B7} Y all \u{00B7} Esc/Ctrl+O close"
                    .to_string(),
                theme.faint(),
            ))
        } else {
            Line::from(Span::styled(
                format!(
                    " {} matches \u{00B7} n/N next/prev \u{00B7} / search \u{00B7} y copy \u{00B7} Esc close",
                    self.matches.len()
                ),
                theme.faint(),
            ))
        };
        frame.render_widget(Paragraph::new(footer), rows[2]);
    }

    // ── Internal helpers ──────────────────────────────────────────────

    fn move_cursor(&mut self, delta: isize, total: usize) {
        if total == 0 {
            return;
        }
        let max = total as isize - 1;
        let next = (self.cursor as isize + delta).clamp(0, max);
        self.cursor = next as usize;
    }

    fn ensure_visible(&mut self, view_h: usize, total: usize) {
        if total == 0 {
            self.scroll = 0;
            self.cursor = 0;
            return;
        }
        if self.cursor >= total {
            self.cursor = total - 1;
        }
        if view_h == 0 {
            self.scroll = self.cursor;
            return;
        }
        if self.cursor < self.scroll {
            self.scroll = self.cursor;
        } else if self.cursor >= self.scroll + view_h {
            self.scroll = self.cursor + 1 - view_h;
        }
        let max_scroll = total.saturating_sub(view_h);
        if self.scroll > max_scroll {
            self.scroll = max_scroll;
        }
    }

    fn recompute_matches(&mut self, flat: &[FlatLine]) {
        self.matches.clear();
        if self.query.is_empty() {
            return;
        }
        let q = self.query.to_lowercase();
        for (i, fl) in flat.iter().enumerate() {
            if !fl.is_header && fl.text.to_lowercase().contains(&q) {
                self.matches.push(i);
            }
        }
    }

    /// Move the cursor to the next (or previous) search match relative to its
    /// current position, wrapping around the ends.
    fn jump_to_match_from_cursor(&mut self, prev: bool) {
        if self.matches.is_empty() {
            return;
        }
        let target = if prev {
            self.matches
                .iter()
                .rev()
                .find(|&&l| l < self.cursor)
                .copied()
                .or_else(|| self.matches.last().copied())
        } else {
            self.matches
                .iter()
                .find(|&&l| l > self.cursor)
                .copied()
                .or_else(|| self.matches.first().copied())
        };
        if let Some(l) = target {
            self.cursor = l;
        }
    }

    fn selected_entry_text(
        &self,
        flat: &[FlatLine],
        entries: &[TranscriptEntry],
    ) -> Option<String> {
        let fl = flat.get(self.cursor.min(flat.len().saturating_sub(1)))?;
        entries.get(fl.entry).map(|e| e.text.clone())
    }
}

// ── Free helpers ──────────────────────────────────────────────────────

/// Current full-viewport size. The overlay always runs in the alternate-screen
/// full viewport, so the terminal size equals the drawable area.
fn viewport() -> (u16, u16) {
    crossterm::terminal::size().unwrap_or((80, 24))
}

/// Body wrap width for a given viewport/area width (1-column left gutter).
fn body_width(width: u16) -> u16 {
    width.saturating_sub(1)
}

/// Body height for a given viewport/area height (header + footer = 2 rows).
fn view_height(height: u16) -> usize {
    height.saturating_sub(2).max(1) as usize
}

/// Flatten entries into wrapped visual lines: one header line per entry, its
/// wrapped body, then a blank spacer.
fn flatten(entries: &[TranscriptEntry], body_w: u16) -> Vec<FlatLine> {
    let w = body_w.max(1) as usize;
    let mut out = Vec::new();
    for (ei, e) in entries.iter().enumerate() {
        out.push(FlatLine {
            entry: ei,
            role: e.role,
            is_header: true,
            text: e.role.label().to_string(),
        });
        for body in wrap_plain(&e.text, w) {
            out.push(FlatLine {
                entry: ei,
                role: e.role,
                is_header: false,
                text: body,
            });
        }
        out.push(FlatLine {
            entry: ei,
            role: e.role,
            is_header: false,
            text: String::new(),
        });
    }
    out
}

/// Greedy word-wrap to `width` display columns, honouring existing newlines and
/// hard-splitting words longer than the wrap width.
fn wrap_plain(text: &str, width: usize) -> Vec<String> {
    let width = width.max(1);
    let mut out = Vec::new();
    for raw in text.split('\n') {
        if raw.is_empty() {
            out.push(String::new());
            continue;
        }
        let mut cur = String::new();
        let mut cur_w = 0usize;
        for word in raw.split(' ') {
            let ww = UnicodeWidthStr::width(word);
            if ww > width {
                // Word alone exceeds the line — flush, then hard-split by char.
                if !cur.is_empty() {
                    out.push(std::mem::take(&mut cur));
                }
                let mut chunk = String::new();
                let mut chunk_w = 0usize;
                for ch in word.chars() {
                    let cw = UnicodeWidthChar::width(ch).unwrap_or(0);
                    if chunk_w + cw > width && !chunk.is_empty() {
                        out.push(std::mem::take(&mut chunk));
                        chunk_w = 0;
                    }
                    chunk.push(ch);
                    chunk_w += cw;
                }
                cur = chunk;
                cur_w = chunk_w;
                continue;
            }
            let projected = if cur.is_empty() { ww } else { cur_w + 1 + ww };
            if projected > width {
                out.push(std::mem::take(&mut cur));
                cur.push_str(word);
                cur_w = ww;
            } else {
                if !cur.is_empty() {
                    cur.push(' ');
                    cur_w += 1;
                }
                cur.push_str(word);
                cur_w += ww;
            }
        }
        out.push(cur);
    }
    out
}

/// Render a flattened line to a styled `Line`, applying search highlight and a
/// full-width cursor highlight for the selected row.
fn render_line(
    fl: &FlatLine,
    is_cursor: bool,
    query: Option<&str>,
    theme: &style::Theme,
    width: u16,
) -> Line<'static> {
    if fl.is_header {
        let bar = Span::styled(
            "\u{258C} ".to_string(),
            Style::default().fg(fl.role.color(theme)),
        );
        let label = Span::styled(fl.role.label().to_string(), fl.role.header_style(theme));
        let line = Line::from(vec![bar, label]);
        if is_cursor {
            return line.style(Style::default().bg(theme.colors.selection_bg));
        }
        return line;
    }

    let base = fl.role.body_style(theme);
    let mut spans: Vec<Span<'static>> = vec![Span::styled(" ".to_string(), base)];
    if let Some(q) = query {
        spans.extend(highlight(&fl.text, q, base, theme));
    } else {
        spans.push(Span::styled(fl.text.clone(), base));
    }

    if is_cursor {
        // Pad to full width so the whole row highlights.
        let cur_w: usize = spans
            .iter()
            .map(|s| UnicodeWidthStr::width(s.content.as_ref()))
            .sum();
        let pad = (width as usize).saturating_sub(cur_w);
        if pad > 0 {
            spans.push(Span::raw(" ".repeat(pad)));
        }
        return Line::from(spans).style(Style::default().bg(theme.colors.selection_bg));
    }
    Line::from(spans)
}

/// Split `text` into spans, highlighting case-insensitive matches of `q`
/// (already lowercased). Uses `.get()` guards so exotic-unicode offset drift can
/// never panic — at worst a highlight is skipped.
fn highlight(text: &str, q: &str, base: Style, theme: &style::Theme) -> Vec<Span<'static>> {
    if q.is_empty() {
        return vec![Span::styled(text.to_string(), base)];
    }
    let hay = text.to_lowercase();
    let hl = Style::default().fg(Color::Black).bg(theme.colors.warning);
    let mut spans: Vec<Span<'static>> = Vec::new();
    let mut idx = 0usize;
    while let Some(rel) = hay.get(idx..).and_then(|s| s.find(q)) {
        let start = idx + rel;
        let end = start + q.len();
        if let Some(pre) = text.get(idx..start) {
            if !pre.is_empty() {
                spans.push(Span::styled(pre.to_string(), base));
            }
        }
        match text.get(start..end) {
            Some(m) => spans.push(Span::styled(m.to_string(), hl)),
            None => break, // offset drift on non-ASCII — stop highlighting
        }
        idx = end;
    }
    match text.get(idx..) {
        Some(rest) if !rest.is_empty() => spans.push(Span::styled(rest.to_string(), base)),
        _ => {}
    }
    if spans.is_empty() {
        spans.push(Span::styled(text.to_string(), base));
    }
    spans
}

fn copy_to_clipboard(text: &str, ok_msg: &str) -> TranscriptAction {
    // U-T7/U-T19 — layered clipboard cascade (native CLI → tmux buffer → OSC 52)
    // so copy works over SSH / headless / tmux, not just on a local windowing
    // system as the old arboard-only path did.
    match crate::clipboard::copy(text) {
        Some(_) => TranscriptAction::Toast(ok_msg.to_string()),
        None => TranscriptAction::Toast("Copy failed".to_string()),
    }
}
