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

use crossterm::event::{
    KeyCode, KeyEvent, KeyModifiers, MouseButton, MouseEvent, MouseEventKind,
};
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

/// A mouse-drag text selection over the flattened visual lines. Both ends are
/// `(flat_line_index, char_index_within_that_line)`. `anchor` is where the drag
/// began (mouse-down); `head` is the current end (drag / mouse-up). The pair is
/// unordered — `normalize` sorts it before any range math or extraction.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Selection {
    anchor: (usize, usize),
    head: (usize, usize),
}

impl Selection {
    /// Return `(start, end)` with `start <= end` in reading order.
    fn normalize(&self) -> ((usize, usize), (usize, usize)) {
        if self.anchor <= self.head {
            (self.anchor, self.head)
        } else {
            (self.head, self.anchor)
        }
    }

    /// True when the selection covers no characters (a plain click, not a drag).
    fn is_empty(&self) -> bool {
        self.anchor == self.head
    }
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
    /// Active mouse-drag text selection (None when nothing is selected).
    selection: Option<Selection>,
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
            selection: None,
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

        // Any key movement invalidates a lingering mouse-drag selection so its
        // highlight never drifts out of sync with the cursor-driven view.
        self.selection = None;

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

    /// Route a mouse event while the overlay owns the screen. Wheel scrolls the
    /// reader; left-drag selects a text range; releasing the drag copies the
    /// selection. All geometry is recomputed from the live viewport (the overlay
    /// always fills the alternate screen), matching every other method here.
    pub fn handle_mouse(&mut self, me: MouseEvent, entries: &[TranscriptEntry]) -> TranscriptAction {
        let (w, h) = viewport();
        let flat = flatten(entries, body_width(w));
        let total = flat.len();
        let view_h = view_height(h);
        if total == 0 {
            return TranscriptAction::None;
        }
        let max_scroll = total.saturating_sub(view_h);
        let scroll = self.scroll.min(max_scroll);

        match me.kind {
            // Wheel ticks scroll the reader in place (never dismiss it — the
            // overlay is the scroll surface while it is open).
            MouseEventKind::ScrollUp => {
                self.move_cursor(-WHEEL_STEP, total);
                self.ensure_visible(view_h, total);
            }
            MouseEventKind::ScrollDown => {
                self.move_cursor(WHEEL_STEP, total);
                self.ensure_visible(view_h, total);
            }
            MouseEventKind::Down(MouseButton::Left) => {
                if let Some(pos) = mouse_to_pos(me.column, me.row, scroll, view_h, &flat) {
                    self.cursor = pos.0;
                    self.selection = Some(Selection {
                        anchor: pos,
                        head: pos,
                    });
                }
            }
            MouseEventKind::Drag(MouseButton::Left) => {
                if let Some(pos) = mouse_to_pos(me.column, me.row, scroll, view_h, &flat) {
                    if let Some(ref mut sel) = self.selection {
                        sel.head = pos;
                        self.cursor = pos.0;
                        self.ensure_visible(view_h, total);
                    }
                }
            }
            MouseEventKind::Up(MouseButton::Left) => {
                // A real drag (non-empty range) copies on release; a bare click
                // just parks the cursor and clears the empty selection.
                if let Some(sel) = self.selection {
                    if sel.is_empty() {
                        self.selection = None;
                    } else if let Some(text) = selection_text(&flat, sel) {
                        if !text.is_empty() {
                            return copy_to_clipboard(&text, "Copied selection to clipboard");
                        }
                    }
                }
            }
            _ => {}
        }
        TranscriptAction::None
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

        let sel = self.selection.map(|s| s.normalize());
        let mut lines: Vec<Line<'static>> = Vec::with_capacity(view_h);
        if total > 0 {
            let end = (scroll + view_h).min(total);
            for i in scroll..end {
                let line_sel = sel.and_then(|(start, endp)| selection_range_for_line(i, start, endp, &flat[i].text));
                lines.push(render_line(
                    &flat[i],
                    i == cursor,
                    query.as_deref(),
                    line_sel,
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
                " \u{2191}\u{2193}/jk scroll \u{00B7} drag select \u{00B7} / search \u{00B7} y copy \u{00B7} Y all \u{00B7} Esc/Ctrl+O close"
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

// ── Mouse selection math (pure, unit-tested) ───────────────────────────

/// Wheel scroll step (visual lines per tick) inside the reader.
const WHEEL_STEP: isize = 3;

/// Left-gutter width (display columns) a rendered line reserves before its text:
/// headers draw a "▌ " role bar (2 cols); body lines a single leading space (1).
fn line_prefix_width(is_header: bool) -> usize {
    if is_header {
        2
    } else {
        1
    }
}

/// Char count of `text` (selection indices are char-based, not byte-based).
fn char_len(text: &str) -> usize {
    text.chars().count()
}

/// Extract the char range `[lo, hi)` of `text` as an owned `String`.
fn slice_chars(text: &str, lo: usize, hi: usize) -> String {
    text.chars().skip(lo).take(hi.saturating_sub(lo)).collect()
}

/// Char index whose display cell contains `target_col` (0-based display column),
/// or the char count when `target_col` is past the end of `text`. Wide chars
/// (CJK, emoji) advance by their display width, so a click lands on the visible
/// glyph under the cursor rather than drifting.
fn display_to_char_idx(text: &str, target_col: usize) -> usize {
    let mut w = 0usize;
    for (i, ch) in text.chars().enumerate() {
        let cw = UnicodeWidthChar::width(ch).unwrap_or(0);
        if w + cw > target_col {
            return i;
        }
        w += cw;
    }
    char_len(text)
}

/// Map a terminal `(col, row)` inside the full-screen overlay to a
/// `(flat_line, char_index)` selection position. Returns `None` when the click
/// is outside the body rows. The overlay fills the alternate screen from `(0,0)`;
/// row 0 is the header bar, so body rows begin at terminal row 1.
fn mouse_to_pos(
    col: u16,
    row: u16,
    scroll: usize,
    view_h: usize,
    flat: &[FlatLine],
) -> Option<(usize, usize)> {
    const BODY_TOP: u16 = 1;
    if row < BODY_TOP {
        return None;
    }
    let body_row = (row - BODY_TOP) as usize;
    if body_row >= view_h {
        return None;
    }
    let idx = scroll + body_row;
    let fl = flat.get(idx)?;
    let text_col = (col as usize).saturating_sub(line_prefix_width(fl.is_header));
    Some((idx, display_to_char_idx(&fl.text, text_col)))
}

/// The char range `[lo, hi)` of flat line `idx`'s text covered by a normalized
/// selection `(start, end)`. `None` when the line falls outside the selection.
fn selection_range_for_line(
    idx: usize,
    start: (usize, usize),
    end: (usize, usize),
    line_text: &str,
) -> Option<(usize, usize)> {
    if idx < start.0 || idx > end.0 {
        return None;
    }
    let n = char_len(line_text);
    let lo = if idx == start.0 { start.1.min(n) } else { 0 };
    let hi = if idx == end.0 { end.1.min(n) } else { n };
    Some((lo, hi))
}

/// Extract the text a selection covers across the flattened lines, joining
/// spanned lines with newlines. `None` when the anchor is out of range.
fn selection_text(flat: &[FlatLine], sel: Selection) -> Option<String> {
    let (start, end) = sel.normalize();
    if start.0 >= flat.len() {
        return None;
    }
    let end_line = end.0.min(flat.len() - 1);
    let mut out: Vec<String> = Vec::new();
    for idx in start.0..=end_line {
        let text = &flat[idx].text;
        let n = char_len(text);
        let lo = if idx == start.0 { start.1.min(n) } else { 0 };
        let hi = if idx == end.0 { end.1.min(n) } else { n };
        out.push(slice_chars(text, lo, hi));
    }
    Some(out.join("\n"))
}

/// Split `text` into base/reversed/base spans so the char range `[lo, hi)` renders
/// with `REVERSED` (the classic terminal text-selection look, theme-independent).
fn reversed_slice(text: &str, lo: usize, hi: usize, base: Style) -> Vec<Span<'static>> {
    let n = char_len(text);
    let lo = lo.min(n);
    let hi = hi.min(n).max(lo);
    let mut out: Vec<Span<'static>> = Vec::new();
    let pre = slice_chars(text, 0, lo);
    if !pre.is_empty() {
        out.push(Span::styled(pre, base));
    }
    let mid = slice_chars(text, lo, hi);
    if !mid.is_empty() {
        out.push(Span::styled(mid, base.add_modifier(Modifier::REVERSED)));
    }
    let post = slice_chars(text, hi, n);
    if !post.is_empty() {
        out.push(Span::styled(post, base));
    }
    if out.is_empty() {
        out.push(Span::styled(String::new(), base));
    }
    out
}

/// Render a flattened line to a styled `Line`, applying search highlight and a
/// full-width cursor highlight for the selected row.
fn render_line(
    fl: &FlatLine,
    is_cursor: bool,
    query: Option<&str>,
    sel: Option<(usize, usize)>,
    theme: &style::Theme,
    width: u16,
) -> Line<'static> {
    // A non-empty drag selection on this row takes visual priority over both the
    // search highlight and the full-row cursor bar, so the reversed cells read as
    // "this is what will be copied".
    let sel = sel.filter(|(lo, hi)| hi > lo);

    if fl.is_header {
        let bar = Span::styled(
            "\u{258C} ".to_string(),
            Style::default().fg(fl.role.color(theme)),
        );
        let hstyle = fl.role.header_style(theme);
        let mut spans = vec![bar];
        match sel {
            Some((lo, hi)) => spans.extend(reversed_slice(fl.role.label(), lo, hi, hstyle)),
            None => spans.push(Span::styled(fl.role.label().to_string(), hstyle)),
        }
        let line = Line::from(spans);
        if is_cursor && sel.is_none() {
            return line.style(Style::default().bg(theme.colors.selection_bg));
        }
        return line;
    }

    let base = fl.role.body_style(theme);
    let mut spans: Vec<Span<'static>> = vec![Span::styled(" ".to_string(), base)];
    if let Some((lo, hi)) = sel {
        spans.extend(reversed_slice(&fl.text, lo, hi, base));
    } else if let Some(q) = query {
        spans.extend(highlight(&fl.text, q, base, theme));
    } else {
        spans.push(Span::styled(fl.text.clone(), base));
    }

    if is_cursor && sel.is_none() {
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

#[cfg(test)]
mod tests {
    use super::*;

    fn body(entry: usize, text: &str) -> FlatLine {
        FlatLine {
            entry,
            role: TranscriptRole::Agent,
            is_header: false,
            text: text.to_string(),
        }
    }

    fn header(entry: usize) -> FlatLine {
        FlatLine {
            entry,
            role: TranscriptRole::User,
            is_header: true,
            text: TranscriptRole::User.label().to_string(),
        }
    }

    #[test]
    fn display_to_char_idx_ascii() {
        assert_eq!(display_to_char_idx("abc", 0), 0);
        assert_eq!(display_to_char_idx("abc", 1), 1);
        assert_eq!(display_to_char_idx("abc", 2), 2);
        // Past the end clamps to the char count.
        assert_eq!(display_to_char_idx("abc", 3), 3);
        assert_eq!(display_to_char_idx("abc", 99), 3);
        assert_eq!(display_to_char_idx("", 0), 0);
    }

    #[test]
    fn display_to_char_idx_wide_chars() {
        // Each CJK glyph is 2 display columns wide, so column 2 lands on the 2nd.
        let s = "你好x"; // widths: 2,2,1
        assert_eq!(display_to_char_idx(s, 0), 0); // first glyph
        assert_eq!(display_to_char_idx(s, 1), 0); // still inside first glyph's cell
        assert_eq!(display_to_char_idx(s, 2), 1); // second glyph
        assert_eq!(display_to_char_idx(s, 4), 2); // the 'x'
        assert_eq!(display_to_char_idx(s, 5), 3); // past end
    }

    #[test]
    fn slice_chars_respects_char_boundaries() {
        assert_eq!(slice_chars("hello", 1, 4), "ell");
        assert_eq!(slice_chars("hello", 0, 0), "");
        assert_eq!(slice_chars("hello", 3, 99), "lo"); // hi clamps via take
        assert_eq!(slice_chars("héllo", 1, 3), "él");
    }

    #[test]
    fn selection_normalize_orders_endpoints() {
        let s = Selection {
            anchor: (5, 2),
            head: (1, 0),
        };
        assert_eq!(s.normalize(), ((1, 0), (5, 2)));
        let s2 = Selection {
            anchor: (2, 1),
            head: (2, 4),
        };
        assert_eq!(s2.normalize(), ((2, 1), (2, 4)));
        assert!(!s2.is_empty());
        let click = Selection {
            anchor: (2, 1),
            head: (2, 1),
        };
        assert!(click.is_empty());
    }

    #[test]
    fn mouse_to_pos_maps_body_rows_and_gutter() {
        let flat = vec![body(0, "hello world"), body(0, "second line")];
        // Row 0 is the header bar → outside the body.
        assert_eq!(mouse_to_pos(5, 0, 0, 10, &flat), None);
        // Body row 0 = terminal row 1; col 1 is the first text column (1-col gutter).
        assert_eq!(mouse_to_pos(1, 1, 0, 10, &flat), Some((0, 0)));
        // Col 0 lands in the gutter → clamps to char 0.
        assert_eq!(mouse_to_pos(0, 1, 0, 10, &flat), Some((0, 0)));
        // "hello world": col 7 → text col 6 → char 'w'.
        assert_eq!(mouse_to_pos(7, 1, 0, 10, &flat), Some((0, 6)));
        // Second visible row maps to flat[1].
        assert_eq!(mouse_to_pos(1, 2, 0, 10, &flat), Some((1, 0)));
        // Beyond the visible height → None.
        assert_eq!(mouse_to_pos(1, 5, 0, 2, &flat), None);
        // Scroll offset shifts which flat line a row addresses.
        assert_eq!(mouse_to_pos(1, 1, 1, 10, &flat), Some((1, 0)));
    }

    #[test]
    fn mouse_to_pos_header_gutter_is_two_cols() {
        let flat = vec![header(0), body(0, "text")];
        // Header body-row 0: "▌ " gutter is 2 cols, so col 2 → char 0 of the label.
        assert_eq!(mouse_to_pos(2, 1, 0, 10, &flat), Some((0, 0)));
        assert_eq!(mouse_to_pos(3, 1, 0, 10, &flat), Some((0, 1)));
    }

    #[test]
    fn selection_range_for_line_single_and_multi() {
        // Single line: [2, 5).
        assert_eq!(
            selection_range_for_line(3, (3, 2), (3, 5), "abcdefgh"),
            Some((2, 5))
        );
        // First line of a multi-line selection: from start col to end of text.
        assert_eq!(
            selection_range_for_line(3, (3, 2), (5, 4), "abcdef"),
            Some((2, 6))
        );
        // Middle line: whole line.
        assert_eq!(
            selection_range_for_line(4, (3, 2), (5, 4), "abcdef"),
            Some((0, 6))
        );
        // Last line: from 0 to end col.
        assert_eq!(
            selection_range_for_line(5, (3, 2), (5, 4), "abcdef"),
            Some((0, 4))
        );
        // Outside the selection.
        assert_eq!(selection_range_for_line(2, (3, 2), (5, 4), "abc"), None);
        assert_eq!(selection_range_for_line(6, (3, 2), (5, 4), "abc"), None);
    }

    #[test]
    fn selection_text_single_line() {
        let flat = vec![body(0, "hello world")];
        let sel = Selection {
            anchor: (0, 0),
            head: (0, 5),
        };
        assert_eq!(selection_text(&flat, sel).as_deref(), Some("hello"));
        // Reversed endpoints extract the same range.
        let sel_rev = Selection {
            anchor: (0, 5),
            head: (0, 0),
        };
        assert_eq!(selection_text(&flat, sel_rev).as_deref(), Some("hello"));
    }

    #[test]
    fn selection_text_multi_line_joins_with_newlines() {
        let flat = vec![body(0, "hello"), body(0, "brave"), body(0, "world")];
        let sel = Selection {
            anchor: (0, 3),
            head: (2, 2),
        };
        // "lo" + "brave" + "wo"
        assert_eq!(
            selection_text(&flat, sel).as_deref(),
            Some("lo\nbrave\nwo")
        );
    }

    #[test]
    fn selection_text_out_of_range_anchor() {
        let flat = vec![body(0, "hi")];
        let sel = Selection {
            anchor: (5, 0),
            head: (6, 0),
        };
        assert_eq!(selection_text(&flat, sel), None);
    }

    #[test]
    fn reversed_slice_partitions_text() {
        let spans = reversed_slice("hello", 1, 4, Style::default());
        let rendered: String = spans.iter().map(|s| s.content.as_ref()).collect();
        assert_eq!(rendered, "hello");
        // Middle span carries the reversed modifier.
        assert_eq!(spans.len(), 3);
        assert_eq!(spans[0].content.as_ref(), "h");
        assert_eq!(spans[1].content.as_ref(), "ell");
        assert!(spans[1].style.add_modifier.contains(Modifier::REVERSED));
        assert_eq!(spans[2].content.as_ref(), "o");
    }

    #[test]
    fn reversed_slice_full_and_empty() {
        // Empty range still yields a (single, unreversed) span so the row renders.
        let none = reversed_slice("hi", 2, 2, Style::default());
        let joined: String = none.iter().map(|s| s.content.as_ref()).collect();
        assert_eq!(joined, "hi");
        assert!(none.iter().all(|s| !s.style.add_modifier.contains(Modifier::REVERSED)));
        // Out-of-bounds hi clamps to the char count without panicking.
        let all = reversed_slice("hi", 0, 99, Style::default());
        let joined2: String = all.iter().map(|s| s.content.as_ref()).collect();
        assert_eq!(joined2, "hi");
    }

    #[test]
    fn drag_select_then_release_extracts_selection() {
        let entries = vec![TranscriptEntry {
            role: TranscriptRole::Agent,
            text: "hello world".to_string(),
        }];
        // Reconstruct the same geometry the viewer sees.
        let (w, _h) = viewport();
        let flat = flatten(&entries, body_width(w));
        // Find the body line carrying the text.
        let (line_idx, _) = flat
            .iter()
            .enumerate()
            .find(|(_, f)| f.text == "hello world")
            .expect("body line present");

        let mut v = TranscriptViewer::open(&entries);
        // Simulate a drag from char 0 to char 5 on that flat line.
        v.selection = Some(Selection {
            anchor: (line_idx, 0),
            head: (line_idx, 5),
        });
        let sel = v.selection.unwrap();
        assert_eq!(selection_text(&flat, sel).as_deref(), Some("hello"));
        // A key press clears the selection highlight.
        v.handle_key(
            KeyEvent::new(KeyCode::Down, KeyModifiers::NONE),
            &entries,
        );
        assert!(v.selection.is_none());
    }
}
