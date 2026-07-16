// Phase 2+: value() and set_content() — wired when external content injection is added
#![allow(dead_code)]

pub mod completions;
pub mod history;
pub mod textarea;

use crossterm::event::{Event as CrosstermEvent, KeyCode, KeyModifiers};
use ratatui::prelude::*;
use ratatui::widgets::Paragraph;
use std::cell::Cell;

use crate::event::Event;
use crate::style;

use self::completions::{CompletionAction, CompletionItem, Completions};
use super::{AppAction, Component, ComponentAction};

pub struct InputComponent {
    /// The text content
    content: String,
    /// Cursor position within content
    cursor: usize,
    /// Command history
    history: history::History,
    /// Whether the input is focused
    focused: bool,
    /// Width for rendering
    width: u16,
    /// Multiline mode
    multiline: bool,
    /// Available commands for tab completion
    commands: Vec<String>,
    /// Tab completion state
    tab_matches: Vec<String>,
    tab_index: usize,
    /// Processing indicator (Step 4)
    processing: bool,
    /// Stash slot for Ctrl+S/Ctrl+R (Step 10)
    stash: Option<String>,
    /// File search active (Step 9: @ file refs)
    file_search_active: bool,
    /// File search matches
    file_matches: Vec<String>,
    /// File search cursor
    file_match_index: usize,
    /// File search prefix position (byte offset of '@')
    file_search_start: usize,
    /// Completions popup for slash commands
    completions: Completions,
    /// Mic button area for click detection
    mic_area: Cell<Option<Rect>>,
    /// Voice recording active
    recording: bool,
}

impl InputComponent {
    pub fn new() -> Self {
        Self {
            content: String::new(),
            cursor: 0,
            history: history::History::new(100),
            focused: true,
            width: 80,
            multiline: false,
            commands: Vec::new(),
            tab_matches: Vec::new(),
            tab_index: 0,
            processing: false,
            stash: None,
            file_search_active: false,
            file_matches: Vec::new(),
            file_match_index: 0,
            file_search_start: 0,
            completions: Completions::new(),
            mic_area: Cell::new(None),
            recording: false,
        }
    }

    pub fn value(&self) -> &str {
        &self.content
    }

    pub fn is_empty(&self) -> bool {
        self.content.trim().is_empty()
    }

    pub fn set_width(&mut self, width: u16) {
        self.width = width;
    }

    pub fn set_commands(&mut self, commands: Vec<String>) {
        self.commands = commands;
    }

    /// Set commands with descriptions for the inline completions popup.
    pub fn set_commands_with_descriptions(&mut self, commands: Vec<(String, String)>) {
        let items: Vec<CompletionItem> = commands
            .iter()
            .map(|(name, desc)| CompletionItem {
                name: format!("/{}", name),
                description: desc.clone(),
                category: None,
            })
            .collect();
        self.commands = commands.iter().map(|(n, _)| n.clone()).collect();
        self.completions.set_items(items);
    }

    /// Return the total height this input needs: top divider + text lines +
    /// bottom divider (Claude-Code frames the prompt with a rule above AND below).
    /// Single-line: 3. Multiline or wrapped: 2 + extra lines (capped at 11).
    pub fn needed_height(&self) -> u16 {
        if self.content.is_empty() {
            return 3; // top divider + 1 text row + bottom divider
        }
        let prompt_len: usize = if self.processing { 4 } else { 2 };
        let avail = (self.width as usize).saturating_sub(prompt_len + 1); // usable chars
        if avail == 0 {
            return 3;
        }
        let char_count = self.content.chars().count();
        let wrap_lines = ((char_count + avail - 1) / avail) as u16; // ceil division
        let newline_lines = self.content.lines().count().max(1) as u16;
        let text_lines = wrap_lines.max(newline_lines);
        (2 + text_lines).min(11) // top divider + text + bottom divider, cap at 11
    }

    /// Set processing indicator state (Step 4)
    pub fn set_processing(&mut self, active: bool) {
        self.processing = active;
    }

    /// Set voice recording state — changes placeholder text
    pub fn set_recording(&mut self, active: bool) {
        self.recording = active;
    }

    pub fn submit(&mut self) -> String {
        let text = self.content.clone();
        if !text.trim().is_empty() {
            self.history.push(text.clone());
        }
        self.content.clear();
        self.cursor = 0;
        self.multiline = false;
        self.tab_matches.clear();
        self.file_search_active = false;
        self.file_matches.clear();
        self.completions.hide();
        text
    }

    pub fn reset(&mut self) {
        self.content.clear();
        self.cursor = 0;
        self.multiline = false;
        self.tab_matches.clear();
        self.file_search_active = false;
        self.file_matches.clear();
        self.completions.hide();
    }

    pub fn set_content(&mut self, text: &str) {
        self.content = text.to_string();
        self.cursor = self.content.len();
    }

    /// Set cursor to approximate column position (for mouse click).
    pub fn set_cursor_col(&mut self, col: u16) {
        let target = col as usize;
        let mut byte_pos = 0;
        let mut char_col = 0;
        for ch in self.content.chars() {
            if char_col >= target {
                break;
            }
            byte_pos += ch.len_utf8();
            char_col += 1;
        }
        self.cursor = byte_pos.min(self.content.len());
    }

    fn insert_char(&mut self, ch: char) {
        self.content.insert(self.cursor, ch);
        self.cursor += ch.len_utf8();
        self.tab_matches.clear();

        // Slash command completions popup
        if self.content.starts_with('/') && !self.file_search_active {
            let filter = &self.content[1..self.cursor]; // text after '/'
            self.completions.show(filter);
        } else {
            self.completions.hide();
        }

        // Step 9: Detect '@' to trigger file search
        if ch == '@' {
            self.file_search_active = true;
            self.file_search_start = self.cursor - 1; // byte position of '@'
            self.file_matches.clear();
            self.file_match_index = 0;
            self.rebuild_file_matches();
        } else if self.file_search_active {
            self.rebuild_file_matches();
        }
    }

    pub fn insert_str(&mut self, s: &str) {
        self.content.insert_str(self.cursor, s);
        self.cursor += s.len();
        self.tab_matches.clear();
        self.file_search_active = false;
        self.file_matches.clear();
    }

    fn delete_char(&mut self) {
        if self.cursor > 0 {
            let prev = self.content[..self.cursor]
                .chars()
                .last()
                .map(|c| c.len_utf8())
                .unwrap_or(0);
            self.content.drain(self.cursor - prev..self.cursor);
            self.cursor -= prev;
            self.tab_matches.clear();

            // Update completions popup filter
            if self.content.starts_with('/') && !self.file_search_active {
                let filter = &self.content[1..self.cursor];
                self.completions.update_filter(filter);
            } else {
                self.completions.hide();
            }

            // If we deleted back past the '@', cancel file search
            if self.file_search_active && self.cursor <= self.file_search_start {
                self.file_search_active = false;
                self.file_matches.clear();
            } else if self.file_search_active {
                self.rebuild_file_matches();
            }
        }
    }

    fn move_left(&mut self) {
        if self.cursor > 0 {
            let prev = self.content[..self.cursor]
                .chars()
                .last()
                .map(|c| c.len_utf8())
                .unwrap_or(0);
            self.cursor -= prev;
        }
    }

    fn move_right(&mut self) {
        if self.cursor < self.content.len() {
            let next = self.content[self.cursor..]
                .chars()
                .next()
                .map(|c| c.len_utf8())
                .unwrap_or(0);
            self.cursor += next;
        }
    }

    fn handle_tab(&mut self) -> bool {
        // Step 9: If file search is active, cycle through file matches
        if self.file_search_active && !self.file_matches.is_empty() {
            let selected = self.file_matches[self.file_match_index].clone();
            // Replace from '@' to cursor with '@selected_path'
            let end = self.cursor;
            self.content.drain(self.file_search_start..end);
            let insertion = format!("@{}", selected);
            self.content.insert_str(self.file_search_start, &insertion);
            self.cursor = self.file_search_start + insertion.len();
            self.file_match_index = (self.file_match_index + 1) % self.file_matches.len();
            return true;
        }

        // Regular command tab completion
        if !self.content.starts_with('/') {
            return false;
        }

        if self.tab_matches.is_empty() {
            let prefix = &self.content[1..]; // skip the /
            self.tab_matches = self
                .commands
                .iter()
                .filter(|cmd| cmd.starts_with(prefix))
                .map(|cmd| format!("/{}", cmd))
                .collect();
            self.tab_index = 0;
        } else if !self.tab_matches.is_empty() {
            self.tab_index = (self.tab_index + 1) % self.tab_matches.len();
        }

        if let Some(match_) = self.tab_matches.get(self.tab_index) {
            self.content = match_.clone();
            self.cursor = self.content.len();
        }
        true
    }

    /// Step 10: Stash current input
    pub fn stash(&mut self) -> bool {
        if self.content.is_empty() {
            return false;
        }
        self.stash = Some(self.content.clone());
        self.content.clear();
        self.cursor = 0;
        self.multiline = false;
        true
    }

    /// Step 10: Restore from stash
    pub fn restore_stash(&mut self) -> bool {
        if let Some(stashed) = self.stash.take() {
            self.content = stashed;
            self.cursor = self.content.len();
            self.multiline = self.content.contains('\n');
            true
        } else {
            false
        }
    }

    /// Step 9: Rebuild file matches from cwd
    fn rebuild_file_matches(&mut self) {
        // Extract the search query after '@'
        let query_start = self.file_search_start + 1; // skip '@'
        if query_start > self.content.len() {
            self.file_matches.clear();
            return;
        }
        let query = &self.content[query_start..self.cursor];
        if query.is_empty() {
            self.file_matches.clear();
            return;
        }

        let query_lower = query.to_lowercase();
        let mut matches = Vec::new();

        // Walk cwd (bounded to 3 levels deep, max 50 results)
        if let Ok(cwd) = std::env::current_dir() {
            Self::walk_dir(&cwd, &cwd, &query_lower, 3, &mut matches);
        }

        matches.sort();
        matches.truncate(10); // Show at most 10 completions
        self.file_matches = matches;
        self.file_match_index = 0;
    }

    fn walk_dir(
        base: &std::path::Path,
        dir: &std::path::Path,
        query: &str,
        depth: usize,
        results: &mut Vec<String>,
    ) {
        if depth == 0 || results.len() >= 50 {
            return;
        }
        let entries = match std::fs::read_dir(dir) {
            Ok(e) => e,
            Err(_) => return,
        };
        for entry in entries.flatten() {
            if results.len() >= 50 {
                break;
            }
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().to_string();

            // Skip hidden dirs/files
            if name.starts_with('.') {
                continue;
            }
            // Skip common noise dirs
            if name == "node_modules" || name == "target" || name == "_build" || name == "deps" {
                continue;
            }

            let rel = path
                .strip_prefix(base)
                .unwrap_or(&path)
                .to_string_lossy()
                .to_string();

            if name.to_lowercase().contains(query) || rel.to_lowercase().contains(query) {
                results.push(rel.clone());
            }

            if path.is_dir() {
                Self::walk_dir(base, &path, query, depth - 1, results);
            }
        }
    }
}

impl Component for InputComponent {
    fn handle_event(&mut self, event: &Event) -> ComponentAction {
        if !self.focused {
            return ComponentAction::Ignored;
        }

        match event {
            Event::Terminal(CrosstermEvent::Key(key)) => {
                // Route to completions popup first when visible
                if self.completions.is_visible() {
                    if let Some(action) = self.completions.handle_key(*key) {
                        match action {
                            CompletionAction::Select(name) => {
                                // Replace input with selected command
                                self.content = format!("{} ", name);
                                self.cursor = self.content.len();
                                self.tab_matches.clear();
                                return ComponentAction::Consumed;
                            }
                            CompletionAction::Dismiss => {
                                return ComponentAction::Consumed;
                            }
                        }
                    }
                    // Up/Down consumed by completions but returned None — still consumed
                    match key.code {
                        KeyCode::Up | KeyCode::Down => return ComponentAction::Consumed,
                        _ => {}
                    }
                }

                match (key.code, key.modifiers) {
                    // Submit (single-line mode)
                    (KeyCode::Enter, KeyModifiers::NONE) if !self.multiline => {
                        // If file search dropdown is active and we have matches, select current match
                        if self.file_search_active && !self.file_matches.is_empty() {
                            let selected = self.file_matches[self.file_match_index].clone();
                            let end = self.cursor;
                            self.content.drain(self.file_search_start..end);
                            let insertion = format!("@{} ", selected);
                            self.content.insert_str(self.file_search_start, &insertion);
                            self.cursor = self.file_search_start + insertion.len();
                            self.file_search_active = false;
                            self.file_matches.clear();
                            return ComponentAction::Consumed;
                        }

                        if self.content.trim().is_empty() {
                            return ComponentAction::Consumed;
                        }
                        let text = self.submit();
                        return ComponentAction::Emit(AppAction::Submit(text));
                    }
                    // Escape cancels file search if active
                    (KeyCode::Esc, KeyModifiers::NONE) if self.file_search_active => {
                        self.file_search_active = false;
                        self.file_matches.clear();
                        return ComponentAction::Consumed;
                    }
                    // Alt+Enter or Shift+Enter: insert newline (enters multiline mode)
                    (KeyCode::Enter, m)
                        if m == KeyModifiers::ALT || m == KeyModifiers::SHIFT =>
                    {
                        self.multiline = true;
                        self.insert_char('\n');
                        return ComponentAction::Consumed;
                    }
                    // Ctrl+Enter in multiline: submit
                    (KeyCode::Enter, m) if self.multiline && m == KeyModifiers::CONTROL => {
                        if self.content.trim().is_empty() {
                            return ComponentAction::Consumed;
                        }
                        let text = self.submit();
                        return ComponentAction::Emit(AppAction::Submit(text));
                    }
                    // Enter in multiline: insert newline
                    (KeyCode::Enter, KeyModifiers::NONE) if self.multiline => {
                        self.insert_char('\n');
                        return ComponentAction::Consumed;
                    }
                    // Backspace
                    (KeyCode::Backspace, KeyModifiers::NONE) => {
                        self.delete_char();
                        if !self.content.contains('\n') {
                            self.multiline = false;
                        }
                        return ComponentAction::Consumed;
                    }
                    // Arrow keys — up/down navigate file matches when file search active
                    (KeyCode::Up, KeyModifiers::NONE) if self.file_search_active && !self.file_matches.is_empty() => {
                        if self.file_match_index > 0 {
                            self.file_match_index -= 1;
                        } else {
                            self.file_match_index = self.file_matches.len() - 1;
                        }
                        return ComponentAction::Consumed;
                    }
                    (KeyCode::Down, KeyModifiers::NONE) if self.file_search_active && !self.file_matches.is_empty() => {
                        self.file_match_index = (self.file_match_index + 1) % self.file_matches.len();
                        return ComponentAction::Consumed;
                    }
                    (KeyCode::Left, KeyModifiers::NONE) => {
                        self.move_left();
                        return ComponentAction::Consumed;
                    }
                    (KeyCode::Right, KeyModifiers::NONE) => {
                        self.move_right();
                        return ComponentAction::Consumed;
                    }
                    // Home/End within input
                    (KeyCode::Home, KeyModifiers::NONE) => {
                        self.cursor = 0;
                        return ComponentAction::Consumed;
                    }
                    (KeyCode::End, KeyModifiers::NONE) => {
                        self.cursor = self.content.len();
                        return ComponentAction::Consumed;
                    }
                    // History up/down (only in single-line mode, not during file search)
                    (KeyCode::Up, KeyModifiers::NONE) if !self.multiline => {
                        if let Some(text) = self.history.prev() {
                            self.content = text.to_string();
                            self.cursor = self.content.len();
                        }
                        return ComponentAction::Consumed;
                    }
                    (KeyCode::Down, KeyModifiers::NONE) if !self.multiline => {
                        if let Some(text) = self.history.next() {
                            self.content = text.to_string();
                            self.cursor = self.content.len();
                        } else {
                            self.content.clear();
                            self.cursor = 0;
                        }
                        return ComponentAction::Consumed;
                    }
                    // Tab completion
                    (KeyCode::Tab, KeyModifiers::NONE) => {
                        self.handle_tab();
                        return ComponentAction::Consumed;
                    }
                    // Ctrl+U: clear
                    (KeyCode::Char('u'), KeyModifiers::CONTROL) => {
                        self.reset();
                        return ComponentAction::Consumed;
                    }
                    // Ctrl+A: move to start
                    (KeyCode::Char('a'), KeyModifiers::CONTROL) => {
                        self.cursor = 0;
                        return ComponentAction::Consumed;
                    }
                    // Ctrl+E: move to end
                    (KeyCode::Char('e'), KeyModifiers::CONTROL) => {
                        self.cursor = self.content.len();
                        return ComponentAction::Consumed;
                    }
                    // Step 10: Ctrl+S: stash
                    (KeyCode::Char('s'), KeyModifiers::CONTROL) => {
                        if self.stash() {
                            return ComponentAction::Emit(AppAction::Toast("Input stashed".into()));
                        }
                        return ComponentAction::Consumed;
                    }
                    // Step 10: Ctrl+R: restore stash
                    (KeyCode::Char('r'), KeyModifiers::CONTROL) => {
                        if self.restore_stash() {
                            return ComponentAction::Emit(AppAction::Toast("Input restored".into()));
                        } else {
                            return ComponentAction::Emit(AppAction::Toast("Nothing stashed".into()));
                        }
                    }
                    // Regular character input
                    (KeyCode::Char(ch), m)
                        if m == KeyModifiers::NONE || m == KeyModifiers::SHIFT =>
                    {
                        self.insert_char(ch);
                        return ComponentAction::Consumed;
                    }
                    _ => {}
                }
                ComponentAction::Ignored
            }
            _ => ComponentAction::Ignored,
        }
    }

    fn draw(&self, frame: &mut Frame, area: Rect) {
        let theme = style::theme();

        if area.height < 2 {
            return;
        }

        // Top divider — full-width `─` rule (Claude-Code style).
        let sep_area = Rect::new(area.x, area.y, area.width, 1);
        let separator =
            Paragraph::new("\u{2500}".repeat(area.width as usize)).style(theme.prompt_border());
        frame.render_widget(separator, sep_area);

        // Bottom divider — reserve the last row for a matching `─` rule when we
        // have room for it (top div + >=1 text row + bottom div).
        let has_bottom = area.height >= 3;
        if has_bottom {
            let bot_area = Rect::new(area.x, area.y + area.height - 1, area.width, 1);
            let bottom = Paragraph::new("\u{2500}".repeat(area.width as usize))
                .style(theme.prompt_border());
            frame.render_widget(bottom, bot_area);
        }

        // Input line(s) — everything between the two dividers.
        let input_h = if has_bottom {
            area.height - 2
        } else {
            area.height - 1
        };
        let input_area = Rect::new(area.x, area.y + 1, area.width, input_h);

        // Step 4: Processing-aware prompt
        let (prompt, prompt_len) = if self.processing {
            ("\u{25c8} \u{276f} ", 4) // "◈ ❯ " — 4 display chars
        } else if self.focused {
            ("\u{276f} ", 2) // "❯ " — 2 display chars
        } else {
            ("  ", 2)
        };
        let prompt_style = if self.processing {
            Style::default().fg(theme.colors.secondary)
        } else if self.focused {
            theme.prompt_char()
        } else {
            theme.faint()
        };

        if self.content.is_empty() {
            let placeholder = if self.recording {
                "\u{25C9} Recording... press Enter to stop, Esc to cancel"
            } else {
                "Type a message..."
            };
            let placeholder_style = if self.recording {
                Style::default().fg(Color::Red)
            } else {
                theme.input_placeholder()
            };
            let line = Line::from(vec![
                Span::styled(prompt, prompt_style),
                Span::styled(placeholder, placeholder_style),
            ]);
            frame.render_widget(Paragraph::new(line), input_area);
        } else {
            // Available width for text (after prompt)
            let avail = (input_area.width as usize).saturating_sub(prompt_len + 1);

            // Build text with prompt on first line, wrapping enabled
            let mut text_lines: Vec<Line<'_>> = Vec::new();
            let content_str: &str = &self.content;

            if self.multiline || content_str.contains('\n') {
                // Multiline: split on newlines, each line gets wrapped by Paragraph
                for (i, text_line) in content_str.split('\n').enumerate() {
                    if i == 0 {
                        let mut spans = vec![Span::styled(prompt, prompt_style)];
                        spans.extend(chip_spans(text_line, theme.attachment_chip()));
                        text_lines.push(Line::from(spans));
                    } else {
                        let mut spans = vec![Span::raw("  ".to_string())]; // indent
                        spans.extend(chip_spans(text_line, theme.attachment_chip()));
                        text_lines.push(Line::from(spans));
                    }
                }
            } else if avail > 0 && content_str.chars().count() > avail {
                // Single-line but too long: horizontal scroll to keep cursor visible
                let cursor_char_pos = content_str[..self.cursor].chars().count();
                let start = if cursor_char_pos >= avail {
                    cursor_char_pos - avail + 1
                } else {
                    0
                };
                let visible: String = content_str.chars().skip(start).take(avail).collect();
                let mut spans = vec![Span::styled(prompt, prompt_style)];
                spans.extend(chip_spans(&visible, theme.attachment_chip()));
                text_lines.push(Line::from(spans));
            } else {
                let mut spans = vec![Span::styled(prompt, prompt_style)];
                spans.extend(chip_spans(content_str, theme.attachment_chip()));
                text_lines.push(Line::from(spans));
            }

            let paragraph = ratatui::widgets::Paragraph::new(Text::from(text_lines))
                .wrap(ratatui::widgets::Wrap { trim: false });
            frame.render_widget(paragraph, input_area);

            // Right-aligned hints for multiline
            if self.multiline {
                let line_count = self.content.lines().count();
                let hint = format!("[{} lines \u{00b7} ctrl+enter submit]", line_count);
                let hint_width = hint.len() as u16;
                if input_area.width > hint_width + 10 {
                    let hint_area = Rect::new(
                        input_area.x + input_area.width - hint_width,
                        input_area.y,
                        hint_width,
                        1,
                    );
                    frame.render_widget(
                        Paragraph::new(Span::styled(hint, theme.hint())),
                        hint_area,
                    );
                }
            }
        }

        // Slash command completions popup (draws above input)
        self.completions.draw(frame, area);

        // Step 9: File search dropdown
        if self.file_search_active && !self.file_matches.is_empty() && area.height > 3 {
            // Draw dropdown above the input (going upward from separator)
            let max_visible = self.file_matches.len().min(5) as u16;
            let dropdown_y = area.y.saturating_sub(max_visible);
            for (i, path) in self.file_matches.iter().take(max_visible as usize).enumerate() {
                let row_y = dropdown_y + i as u16;
                if row_y >= area.y {
                    break;
                }
                let is_selected = i == self.file_match_index;
                let style = if is_selected {
                    Style::default()
                        .fg(theme.colors.primary)
                        .add_modifier(Modifier::BOLD)
                } else {
                    Style::default().fg(theme.colors.muted)
                };
                let prefix = if is_selected { "\u{25b8} " } else { "  " };
                let display = format!("{}{}", prefix, path);
                let line = Line::from(Span::styled(display, style));
                let row_area = Rect::new(area.x + 2, row_y, area.width.saturating_sub(4), 1);
                frame.render_widget(Paragraph::new(line), row_area);
            }
        }

        // Stash indicator
        if self.stash.is_some() && self.content.is_empty() {
            let hint = "[Ctrl+R to restore stash]";
            let hint_width = hint.len() as u16;
            if input_area.width > hint_width + 10 {
                let hint_area = Rect::new(
                    input_area.x + input_area.width - hint_width,
                    input_area.y,
                    hint_width,
                    1,
                );
                frame.render_widget(
                    Paragraph::new(Span::styled(hint, theme.hint())),
                    hint_area,
                );
            }
        }

        // Mic button — always visible, clickable
        if !self.processing && input_area.width > 10 {
            let btn = " \u{25C9} ";
            let btn_width = 4u16;
            let mic_rect = Rect::new(
                input_area.x + input_area.width - btn_width,
                input_area.y,
                btn_width,
                1,
            );
            self.mic_area.set(Some(mic_rect));
            frame.render_widget(
                Paragraph::new(Span::styled(btn, Style::default().fg(Color::Yellow))),
                mic_rect,
            );
        } else {
            self.mic_area.set(None);
        }

        // Show cursor
        if self.focused {
            let avail = (area.width as usize).saturating_sub(prompt_len + 1);

            if self.multiline || self.content.contains('\n') {
                // Multiline cursor: find which line and column
                let before_cursor = &self.content[..self.cursor];
                let line_idx = before_cursor.matches('\n').count();
                let last_newline = before_cursor.rfind('\n');
                let col = match last_newline {
                    Some(pos) => before_cursor[pos + 1..].chars().count(),
                    None => before_cursor.chars().count(),
                };
                let indent: u16 = if line_idx == 0 { prompt_len as u16 } else { 2 };
                let cursor_x = area.x + indent + col as u16;
                let cursor_y = area.y + 1 + line_idx as u16;
                if cursor_x < area.x + area.width && cursor_y < area.y + area.height {
                    frame.set_cursor_position(Position::new(cursor_x, cursor_y));
                }
            } else {
                // Single-line cursor (accounts for horizontal scroll)
                let cursor_char_pos = self.content[..self.cursor].chars().count();
                let scroll_start = if avail > 0 && cursor_char_pos >= avail {
                    cursor_char_pos - avail + 1
                } else {
                    0
                };
                let visible_cursor = (cursor_char_pos - scroll_start) as u16;
                let cursor_x = area.x + prompt_len as u16 + visible_cursor;
                let cursor_y = area.y + 1;
                if cursor_x < area.x + area.width {
                    frame.set_cursor_position(Position::new(cursor_x, cursor_y));
                }
            }
        }
    }

    fn set_focused(&mut self, focused: bool) {
        self.focused = focused;
    }
}

impl InputComponent {
    /// Returns the rect of the mic button if it was drawn, for click detection
    pub fn mic_area(&self) -> Option<Rect> {
        self.mic_area.get()
    }
}

/// True when `tok` is an attachment chip token like "[Image #3]" or "[File #12]".
fn is_chip_token(tok: &str) -> bool {
    let inner = match tok.strip_prefix('[').and_then(|s| s.strip_suffix(']')) {
        Some(i) => i,
        None => return false,
    };
    for prefix in ["Image #", "File #"] {
        if let Some(num) = inner.strip_prefix(prefix) {
            return !num.is_empty() && num.bytes().all(|b| b.is_ascii_digit());
        }
    }
    false
}

/// Split `text` into spans, styling attachment chip tokens ("[Image #N]",
/// "[File #N]") distinctly with `chip_style` and leaving the rest as-is.
fn chip_spans(text: &str, chip_style: Style) -> Vec<Span<'static>> {
    let mut spans: Vec<Span<'static>> = Vec::new();
    let mut rest = text;
    while let Some(open) = rest.find('[') {
        if let Some(rel) = rest[open..].find(']') {
            let close = open + rel;
            let token = &rest[open..=close];
            if is_chip_token(token) {
                if open > 0 {
                    spans.push(Span::raw(rest[..open].to_string()));
                }
                spans.push(Span::styled(token.to_string(), chip_style));
                rest = &rest[close + 1..];
                continue;
            }
        }
        // A '[' that doesn't open a chip: emit through it and keep scanning.
        spans.push(Span::raw(rest[..=open].to_string()));
        rest = &rest[open + 1..];
    }
    if !rest.is_empty() {
        spans.push(Span::raw(rest.to_string()));
    }
    spans
}
