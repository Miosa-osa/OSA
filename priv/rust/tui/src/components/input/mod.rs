// Phase 2+: value() and set_content() — wired when external content injection is added
#![allow(dead_code)]

pub mod completions;
pub mod history;
pub mod textarea;

use crossterm::event::{
    DisableBracketedPaste, EnableBracketedPaste, Event as CrosstermEvent, KeyCode, KeyEvent,
    KeyboardEnhancementFlags, KeyModifiers, PopKeyboardEnhancementFlags,
    PushKeyboardEnhancementFlags,
};
use crossterm::execute;
use crossterm::terminal::{disable_raw_mode, enable_raw_mode, supports_keyboard_enhancement};
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
    /// Text/editing area of the composer (the row(s) between the dividers),
    /// captured on draw for click-to-focus / click-to-position-caret.
    text_area: Cell<Option<Rect>>,
    /// Voice recording active
    recording: bool,
    /// Undo ring — snapshots of (content, cursor) before edits
    undo_stack: Vec<(String, usize)>,
    /// Redo ring — snapshots popped by undo
    redo_stack: Vec<(String, usize)>,
    /// Reverse-incremental history search state (Ctrl+R)
    reverse_search: Option<ReverseSearch>,
    /// Number of messages queued while the agent is Processing. Purely for the
    /// small "N queued" indicator; set by the app via `set_queued_count`.
    queued_count: usize,
    /// Whether the kitty keyboard-enhancement protocol (DISAMBIGUATE_ESCAPE_CODES)
    /// was enabled at startup. Drives the terminal-aware newline hint: when true
    /// the composer advertises "shift+enter newline"; when false it advertises the
    /// universal backslash-continuation that works on every terminal. Set once from
    /// `main.rs` via [`InputComponent::set_kbd_enhanced`].
    kbd_enhanced: bool,
}

/// Ctrl+R reverse-incremental history search over persisted input history.
struct ReverseSearch {
    /// The incremental search query typed after Ctrl+R.
    query: String,
    /// Index into `history.entries()` of the current match, if any.
    match_idx: Option<usize>,
}

impl InputComponent {
    pub fn new() -> Self {
        Self {
            content: String::new(),
            cursor: 0,
            history: history::History::persistent(),
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
            text_area: Cell::new(None),
            recording: false,
            undo_stack: Vec::new(),
            redo_stack: Vec::new(),
            reverse_search: None,
            queued_count: 0,
            // Conservative default: assume no enhancement until main.rs probes the
            // terminal, so the always-works backslash hint shows if never set. The
            // test-only InputComponent::new() call sites (event_loop.rs) rely on this.
            kbd_enhanced: false,
        }
    }

    /// Set the "N queued" indicator (messages waiting for the current turn to
    /// finish). 0 hides it.
    pub fn set_queued_count(&mut self, n: usize) {
        self.queued_count = n;
    }

    /// Record whether the keyboard-enhancement protocol is active (set once from
    /// `main.rs` at startup) so the newline hint matches the terminal's real
    /// capabilities without a per-frame syscall.
    pub fn set_kbd_enhanced(&mut self, enabled: bool) {
        self.kbd_enhanced = enabled;
    }

    pub fn value(&self) -> &str {
        &self.content
    }

    /// Current cursor byte offset. Exposed for tests and cursor-edge decisions.
    pub fn cursor(&self) -> usize {
        self.cursor
    }

    /// Whether the `@`-file-reference search dropdown is currently active. The
    /// app checks this so a plain Esc can be routed to the input (to dismiss the
    /// dropdown) instead of triggering the global single/double-Esc handling.
    pub fn file_search_active(&self) -> bool {
        self.file_search_active
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

    /// Rows the open slash-completions popup wants above the input, or 0 when it
    /// is closed. `desired_inline_height` reserves this so the upward-growing
    /// popup always has room to render real commands (not just a scroll arrow).
    pub fn completions_popup_height(&self) -> u16 {
        self.completions.desired_height()
    }

    /// Set commands with descriptions AND an optional category for the inline
    /// completions popup. The category (e.g. "custom" for user-defined
    /// `~/.osa/commands/*.md` commands) lets the popup tag entries so a
    /// user-authored command is visually distinguished from a built-in.
    pub fn set_command_items(&mut self, commands: Vec<(String, String, Option<String>)>) {
        let items: Vec<CompletionItem> = commands
            .iter()
            .map(|(name, desc, category)| CompletionItem {
                name: format!("/{}", name),
                description: desc.clone(),
                category: category.clone(),
            })
            .collect();
        self.commands = commands.iter().map(|(n, _, _)| n.clone()).collect();
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
        self.snapshot();
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
        self.snapshot();
        self.content.insert_str(self.cursor, s);
        self.cursor += s.len();
        self.tab_matches.clear();
        self.file_search_active = false;
        self.file_matches.clear();
    }

    fn delete_char(&mut self) {
        if self.cursor > 0 {
            self.snapshot();
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

    /// Current cursor column, counted in chars from the start of its line.
    fn cursor_column(&self) -> usize {
        let line_start = self.content[..self.cursor]
            .rfind('\n')
            .map(|p| p + 1)
            .unwrap_or(0);
        self.content[line_start..self.cursor].chars().count()
    }

    /// Byte offset of `col` chars into the line spanning `[start, end)`,
    /// clamped to the line's end.
    fn byte_at_column(&self, start: usize, end: usize, col: usize) -> usize {
        let line = &self.content[start..end];
        match line.char_indices().nth(col) {
            Some((b, _)) => start + b,
            None => end,
        }
    }

    /// Multiline: move the cursor up one line, preserving the column when
    /// possible. On the first line, jump to the start of the buffer.
    fn move_cursor_up(&mut self) {
        let col = self.cursor_column();
        let cur_line_start = self.content[..self.cursor]
            .rfind('\n')
            .map(|p| p + 1)
            .unwrap_or(0);
        if cur_line_start == 0 {
            self.cursor = 0;
            return;
        }
        // Previous line occupies [prev_start, cur_line_start - 1) (excludes its
        // trailing '\n' at cur_line_start - 1).
        let prev_end = cur_line_start - 1;
        let prev_start = self.content[..prev_end]
            .rfind('\n')
            .map(|p| p + 1)
            .unwrap_or(0);
        self.cursor = self.byte_at_column(prev_start, prev_end, col);
    }

    /// Multiline: move the cursor down one line, preserving the column when
    /// possible. On the last line, jump to the end of the buffer.
    fn move_cursor_down(&mut self) {
        let col = self.cursor_column();
        let next_start = match self.content[self.cursor..].find('\n') {
            Some(rel) => self.cursor + rel + 1,
            None => {
                self.cursor = self.content.len();
                return;
            }
        };
        let next_end = self.content[next_start..]
            .find('\n')
            .map(|p| next_start + p)
            .unwrap_or(self.content.len());
        self.cursor = self.byte_at_column(next_start, next_end, col);
    }

    fn handle_tab(&mut self) -> bool {
        // Step 9: If file search is active, cycle through file matches
        if self.file_search_active && !self.file_matches.is_empty() {
            self.snapshot();
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
            // Fuzzy subsequence match + rank (best-first) instead of prefix-only.
            self.tab_matches = crate::util::fuzzy::rank(&self.commands, prefix, |c| c.as_str())
                .into_iter()
                .map(|i| format!("/{}", self.commands[i]))
                .collect();
            self.tab_index = 0;
        } else if !self.tab_matches.is_empty() {
            self.tab_index = (self.tab_index + 1) % self.tab_matches.len();
        }

        if let Some(match_) = self.tab_matches.get(self.tab_index).cloned() {
            self.snapshot();
            self.content = match_;
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

        // Collect fuzzy-matching candidates, then rank best-first.
        let mut candidates = Vec::new();
        if let Ok(cwd) = std::env::current_dir() {
            Self::walk_dir(&cwd, &cwd, query, 3, &mut candidates);
        }

        // Score each candidate by the better of its filename vs. full relative
        // path match, so a query can hit either the leaf name or the path.
        let mut scored: Vec<(i32, usize, String)> = candidates
            .into_iter()
            .filter_map(|rel| {
                let name = rel.rsplit(['/', '\\']).next().unwrap_or(&rel);
                let best = crate::util::fuzzy::score(name, query)
                    .into_iter()
                    .chain(crate::util::fuzzy::score(&rel, query))
                    .max();
                best.map(|s| (s, rel.chars().count(), rel))
            })
            .collect();
        scored.sort_by(|a, b| {
            b.0.cmp(&a.0)
                .then_with(|| a.1.cmp(&b.1))
                .then_with(|| a.2.cmp(&b.2))
        });

        self.file_matches = scored.into_iter().take(10).map(|(_, _, rel)| rel).collect();
        self.file_match_index = 0;
    }

    fn walk_dir(
        base: &std::path::Path,
        dir: &std::path::Path,
        query: &str,
        depth: usize,
        results: &mut Vec<String>,
    ) {
        if depth == 0 || results.len() >= 200 {
            return;
        }
        let entries = match std::fs::read_dir(dir) {
            Ok(e) => e,
            Err(_) => return,
        };
        for entry in entries.flatten() {
            if results.len() >= 200 {
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

            let is_dir = path.is_dir();
            let mut rel = path
                .strip_prefix(base)
                .unwrap_or(&path)
                .to_string_lossy()
                .to_string();
            // Mark directories with a trailing '/' so the mention dropdown
            // distinguishes them from files (and inserts a browsable path).
            if is_dir {
                rel.push('/');
            }

            // Fuzzy subsequence match on either the leaf name or the full path.
            if crate::util::fuzzy::is_match(&name, query)
                || crate::util::fuzzy::is_match(&rel, query)
            {
                results.push(rel.clone());
            }

            if is_dir {
                Self::walk_dir(base, &path, query, depth - 1, results);
            }
        }
    }

    // ── Composer power-features: word motions, kill-line, undo/redo ──────────

    /// Push the current (content, cursor) onto the undo ring and clear redo.
    fn snapshot(&mut self) {
        self.undo_stack.push((self.content.clone(), self.cursor));
        if self.undo_stack.len() > 100 {
            self.undo_stack.remove(0);
        }
        self.redo_stack.clear();
    }

    /// Restore editing state after an undo/redo hop.
    fn restore_state(&mut self, content: String, cursor: usize) {
        self.content = content;
        self.cursor = cursor.min(self.content.len());
        self.multiline = self.content.contains('\n');
        self.tab_matches.clear();
        self.file_search_active = false;
        self.file_matches.clear();
        self.completions.hide();
    }

    fn undo(&mut self) -> bool {
        if let Some((content, cursor)) = self.undo_stack.pop() {
            self.redo_stack.push((self.content.clone(), self.cursor));
            self.restore_state(content, cursor);
            true
        } else {
            false
        }
    }

    fn redo(&mut self) -> bool {
        if let Some((content, cursor)) = self.redo_stack.pop() {
            self.undo_stack.push((self.content.clone(), self.cursor));
            self.restore_state(content, cursor);
            true
        } else {
            false
        }
    }

    /// Byte offset of the previous word boundary (skip whitespace, then word).
    fn word_left(&self) -> usize {
        let upto = &self.content[..self.cursor];
        let mut idx = self.cursor;
        let mut iter = upto.char_indices().rev().peekable();
        while let Some(&(bi, c)) = iter.peek() {
            if c.is_whitespace() {
                idx = bi;
                iter.next();
            } else {
                break;
            }
        }
        while let Some(&(bi, c)) = iter.peek() {
            if !c.is_whitespace() {
                idx = bi;
                iter.next();
            } else {
                break;
            }
        }
        idx
    }

    /// Byte offset of the next word boundary (skip whitespace, then word).
    fn word_right(&self) -> usize {
        let from = &self.content[self.cursor..];
        let mut idx = self.cursor;
        let mut iter = from.char_indices().peekable();
        while let Some(&(bi, c)) = iter.peek() {
            if c.is_whitespace() {
                idx = self.cursor + bi + c.len_utf8();
                iter.next();
            } else {
                break;
            }
        }
        while let Some(&(bi, c)) = iter.peek() {
            if !c.is_whitespace() {
                idx = self.cursor + bi + c.len_utf8();
                iter.next();
            } else {
                break;
            }
        }
        idx
    }

    /// Alt+B — move cursor one word left.
    fn move_word_left(&mut self) {
        self.cursor = self.word_left();
    }

    /// Alt+F — move cursor one word right.
    fn move_word_right(&mut self) {
        self.cursor = self.word_right();
    }

    /// Ctrl+W — delete the word before the cursor.
    fn delete_word_back(&mut self) {
        let start = self.word_left();
        if start < self.cursor {
            self.snapshot();
            self.content.drain(start..self.cursor);
            self.cursor = start;
            self.after_edit();
        }
    }

    /// Ctrl+D (readline delete-forward) — remove the character under the cursor.
    /// A no-op at end-of-buffer. The idle handler only routes Ctrl+D here when
    /// the buffer is non-empty (empty Ctrl+D is EOF/quit), so this never fights
    /// the exit binding.
    fn delete_forward_char(&mut self) {
        if self.cursor < self.content.len() {
            self.snapshot();
            let next = self.content[self.cursor..]
                .chars()
                .next()
                .map(|c| c.len_utf8())
                .unwrap_or(0);
            self.content.drain(self.cursor..self.cursor + next);
            self.after_edit();
        }
    }

    /// Ctrl+K — kill from the cursor to the end of the current line. If the
    /// cursor sits on a newline, kill just that newline.
    fn kill_to_line_end(&mut self) {
        let rest = &self.content[self.cursor..];
        let end = match rest.find('\n') {
            Some(0) => self.cursor + 1,          // on a newline: remove it
            Some(n) => self.cursor + n,          // to end of visual line
            None => self.content.len(),          // last line: to end of buffer
        };
        if end > self.cursor {
            self.snapshot();
            self.content.drain(self.cursor..end);
            self.after_edit();
        }
    }

    /// Shared bookkeeping after a structural edit (kill/word-delete).
    fn after_edit(&mut self) {
        self.tab_matches.clear();
        if !self.content.contains('\n') {
            self.multiline = false;
        }
        if self.content.starts_with('/') && !self.file_search_active {
            let filter = &self.content[1..self.cursor.min(self.content.len())];
            self.completions.update_filter(filter);
        } else {
            self.completions.hide();
        }
        if self.file_search_active {
            if self.cursor <= self.file_search_start {
                self.file_search_active = false;
                self.file_matches.clear();
            } else {
                self.rebuild_file_matches();
            }
        }
    }

    /// Ctrl+G — open the current buffer in `$EDITOR` (then `$VISUAL`, then `vi`),
    /// read it back on exit. Raw mode / bracketed paste are suspended around the
    /// child process and restored afterward. Returns Ok(true) if the buffer
    /// changed. The editor uses its own alternate screen, so the inline viewport
    /// is preserved on return.
    fn open_in_editor(&mut self) -> Result<bool, String> {
        // Out-of-the-box editor: `vi` exists on a default unix box but not on
        // Windows, where `notepad` is always present. $EDITOR / $VISUAL still win.
        let default_editor = if cfg!(windows) { "notepad" } else { "vi" };
        let editor = std::env::var("EDITOR")
            .ok()
            .filter(|s| !s.trim().is_empty())
            .or_else(|| std::env::var("VISUAL").ok().filter(|s| !s.trim().is_empty()))
            .unwrap_or_else(|| default_editor.to_string());

        // Support `EDITOR="code --wait"` style values: first token is the program.
        let mut parts = editor.split_whitespace();
        let program = parts.next().unwrap_or(default_editor).to_string();
        let extra_args: Vec<String> = parts.map(|s| s.to_string()).collect();

        // Temp file seeded with the current buffer (markdown for editor niceties).
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let path = std::env::temp_dir().join(format!("osa-compose-{}.md", nanos));
        std::fs::write(&path, self.content.as_bytes())
            .map_err(|e| format!("compose: write temp failed: {e}"))?;

        // Suspend the TUI's terminal modes around the child.
        let mut out = std::io::stdout();
        let _ = execute!(out, PopKeyboardEnhancementFlags);
        let _ = execute!(out, DisableBracketedPaste);
        let _ = disable_raw_mode();

        let status = std::process::Command::new(&program)
            .args(&extra_args)
            .arg(&path)
            .status();

        // Restore terminal modes exactly as main.rs set them up.
        let _ = enable_raw_mode();
        let _ = execute!(out, EnableBracketedPaste);
        if matches!(supports_keyboard_enhancement(), Ok(true)) {
            let _ = execute!(
                out,
                PushKeyboardEnhancementFlags(KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES)
            );
        }

        let result = match status {
            Ok(st) if st.success() => match std::fs::read_to_string(&path) {
                Ok(text) => {
                    // Editors commonly append a trailing newline; drop one.
                    let text = text.strip_suffix('\n').unwrap_or(&text).to_string();
                    let changed = text != self.content;
                    if changed {
                        self.snapshot();
                        self.content = text;
                        self.cursor = self.content.len();
                        self.multiline = self.content.contains('\n');
                        self.completions.hide();
                        self.file_search_active = false;
                        self.file_matches.clear();
                        self.tab_matches.clear();
                    }
                    Ok(changed)
                }
                Err(e) => Err(format!("compose: read back failed: {e}")),
            },
            Ok(_) => Ok(false), // editor exited non-zero: keep buffer as-is
            Err(e) => Err(format!("compose: launch '{program}' failed: {e}")),
        };

        let _ = std::fs::remove_file(&path);
        result
    }

    /// Handle a key while Ctrl+R reverse-search is active.
    fn handle_reverse_search_key(&mut self, key: KeyEvent) -> ComponentAction {
        let Some(mut rs) = self.reverse_search.take() else {
            return ComponentAction::Ignored;
        };
        let mut keep = true;
        let accept = |this: &mut Self, idx: Option<usize>| {
            if let Some(i) = idx {
                if let Some(entry) = this.history.entries().get(i).cloned() {
                    this.content = entry;
                    this.cursor = this.content.len();
                    this.multiline = this.content.contains('\n');
                }
            }
        };
        match (key.code, key.modifiers) {
            // Ctrl+R again: step to the next-older match.
            (KeyCode::Char('r'), KeyModifiers::CONTROL) => {
                let before = rs.match_idx.unwrap_or(self.history.len());
                if let Some(i) = self.history.search_backward(&rs.query, before) {
                    rs.match_idx = Some(i);
                }
            }
            (KeyCode::Esc, _) => {
                keep = false; // cancel: leave the buffer untouched
            }
            (KeyCode::Enter, _) => {
                accept(self, rs.match_idx);
                keep = false;
            }
            (KeyCode::Left, _) | (KeyCode::Right, _) | (KeyCode::Home, _) | (KeyCode::End, _) => {
                accept(self, rs.match_idx);
                keep = false;
            }
            (KeyCode::Backspace, _) => {
                rs.query.pop();
                rs.match_idx = self.history.search_backward(&rs.query, self.history.len());
            }
            (KeyCode::Char(c), m) if m == KeyModifiers::NONE || m == KeyModifiers::SHIFT => {
                rs.query.push(c);
                rs.match_idx = self.history.search_backward(&rs.query, self.history.len());
            }
            _ => {} // swallow other keys while searching
        }
        if keep {
            self.reverse_search = Some(rs);
        }
        ComponentAction::Consumed
    }
}

impl Component for InputComponent {
    fn handle_event(&mut self, event: &Event) -> ComponentAction {
        if !self.focused {
            return ComponentAction::Ignored;
        }

        match event {
            Event::Terminal(CrosstermEvent::Key(key)) => {
                // Ctrl+R reverse-incremental history search owns all keys while active.
                if self.reverse_search.is_some() {
                    return self.handle_reverse_search_key(*key);
                }

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
                    // Insert a newline (enters multiline mode) rather than submit.
                    // Shift+Enter / Alt+Enter / Ctrl+J all mean "newline, don't
                    // submit", but terminals encode them differently — the single
                    // key-normalization layer owns that quirk so this stays
                    // consistent cross-terminal. Plain Enter always submits (Claude
                    // Code convention); the portable Ctrl+J fallback covers
                    // terminals where Shift+Enter collapses to a bare Enter.
                    _ if crate::app::key_normalize::is_insert_newline(key) => {
                        self.multiline = true;
                        self.insert_char('\n');
                        return ComponentAction::Consumed;
                    }
                    // Escape cancels file search if active
                    (KeyCode::Esc, KeyModifiers::NONE) if self.file_search_active => {
                        self.file_search_active = false;
                        self.file_matches.clear();
                        return ComponentAction::Consumed;
                    }
                    // Universal backslash-continuation newline: works on EVERY
                    // terminal regardless of keyboard protocol. When a plain Enter
                    // arrives and the char immediately left of the cursor is a literal
                    // backslash, drop that backslash and insert a newline instead of
                    // submitting (Claude Code's useTextInput handleEnter). This is the
                    // one newline path that stays reliable even where Shift+Enter
                    // collapses to a bare Enter. Skipped while the @-file dropdown is
                    // active so a plain Enter still selects a match.
                    _ if key.code == KeyCode::Enter
                        && key.modifiers == KeyModifiers::NONE
                        && !self.file_search_active
                        && crate::app::key_normalize::newline_via_backslash(
                            &self.content,
                            self.cursor,
                        ) =>
                    {
                        self.snapshot();
                        // Replace the trailing "\" (1 ASCII byte) with a newline; the
                        // cursor byte offset is unchanged (one byte removed and one
                        // inserted, both at the same spot before the cursor).
                        self.content.remove(self.cursor - 1);
                        self.content.insert(self.cursor - 1, '\n');
                        self.multiline = true;
                        self.tab_matches.clear();
                        self.completions.hide();
                        return ComponentAction::Consumed;
                    }
                    // Enter ALWAYS submits — both single-line and multiline. Submit
                    // routing goes through the key-normalization layer (the single
                    // source of truth) rather than a second literal Enter match, so
                    // "what is a submit?" is answered in exactly one place. (Ctrl+Enter
                    // is accepted too for muscle-memory / terminals that map it.)
                    _ if crate::app::key_normalize::is_submit(key) =>
                    {
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
                    // Multiline: Up/Down move the CURSOR between lines (preserving
                    // column). At the TOP edge (cursor on the first line) Up
                    // crosses into history recall; at the BOTTOM edge Down does —
                    // matching Claude Code, where history is reached only from the
                    // buffer edge. Single-line / empty input recall via the arms
                    // below.
                    (KeyCode::Up, KeyModifiers::NONE)
                        if self.multiline || self.content.contains('\n') =>
                    {
                        if up_crosses_to_history(&self.content, self.cursor) {
                            if let Some(text) = self.history.prev() {
                                self.content = text.to_string();
                                self.cursor = self.content.len();
                                self.multiline = self.content.contains('\n');
                            }
                        } else {
                            self.move_cursor_up();
                        }
                        return ComponentAction::Consumed;
                    }
                    (KeyCode::Down, KeyModifiers::NONE)
                        if self.multiline || self.content.contains('\n') =>
                    {
                        if down_crosses_to_history(&self.content, self.cursor) {
                            if let Some(text) = self.history.next() {
                                self.content = text.to_string();
                                self.cursor = self.content.len();
                                self.multiline = self.content.contains('\n');
                            }
                            // else: already at newest / not navigating — stay put
                            // (cursor is at the buffer end), never wipe the draft.
                        } else {
                            self.move_cursor_down();
                        }
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
                        if !self.content.is_empty() {
                            self.snapshot();
                        }
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
                    // Ctrl+K: kill from cursor to end of line
                    (KeyCode::Char('k'), KeyModifiers::CONTROL) => {
                        self.kill_to_line_end();
                        return ComponentAction::Consumed;
                    }
                    // Ctrl+W: delete word before cursor
                    (KeyCode::Char('w'), KeyModifiers::CONTROL) => {
                        self.delete_word_back();
                        return ComponentAction::Consumed;
                    }
                    // Ctrl+D: delete the char under the cursor (readline
                    // delete-forward). The idle handler routes Ctrl+D here only
                    // when the buffer is non-empty; empty Ctrl+D is EOF/quit.
                    (KeyCode::Char('d'), KeyModifiers::CONTROL) => {
                        self.delete_forward_char();
                        return ComponentAction::Consumed;
                    }
                    // Alt+B: move one word left
                    (KeyCode::Char('b'), KeyModifiers::ALT) => {
                        self.move_word_left();
                        return ComponentAction::Consumed;
                    }
                    // Alt+F: move one word right
                    (KeyCode::Char('f'), KeyModifiers::ALT) => {
                        self.move_word_right();
                        return ComponentAction::Consumed;
                    }
                    // Ctrl+Z: undo
                    (KeyCode::Char('z'), KeyModifiers::CONTROL) => {
                        self.undo();
                        return ComponentAction::Consumed;
                    }
                    // Ctrl+Y: redo
                    (KeyCode::Char('y'), KeyModifiers::CONTROL) => {
                        self.redo();
                        return ComponentAction::Consumed;
                    }
                    // Ctrl+G: open the current buffer in $EDITOR
                    (KeyCode::Char('g'), KeyModifiers::CONTROL) => {
                        return match self.open_in_editor() {
                            Ok(_) => ComponentAction::Consumed,
                            Err(e) => ComponentAction::Emit(AppAction::Toast(e)),
                        };
                    }
                    // Ctrl+R: enter reverse-incremental history search
                    (KeyCode::Char('r'), KeyModifiers::CONTROL) => {
                        if self.history.is_empty() {
                            return ComponentAction::Emit(AppAction::Toast(
                                "History is empty".into(),
                            ));
                        }
                        self.reverse_search = Some(ReverseSearch {
                            query: String::new(),
                            match_idx: None,
                        });
                        return ComponentAction::Consumed;
                    }
                    // Step 10: Ctrl+S toggles stash (stash when non-empty, restore when empty)
                    (KeyCode::Char('s'), KeyModifiers::CONTROL) => {
                        if !self.content.is_empty() {
                            if self.stash() {
                                return ComponentAction::Emit(AppAction::Toast(
                                    "Input stashed".into(),
                                ));
                            }
                        } else if self.restore_stash() {
                            return ComponentAction::Emit(AppAction::Toast("Input restored".into()));
                        }
                        return ComponentAction::Consumed;
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

        // Shell mode: a leading '!' routes the line to OSA's bash tool on submit.
        // Recolor the frame with OSA blue and flag it with a "shell" badge so the
        // switch is obvious while typing.
        let shell_mode = self.content.starts_with('!');
        let divider_style = if shell_mode {
            Style::default().fg(theme.colors.primary)
        } else {
            theme.prompt_border()
        };

        // Top divider — full-width `─` rule (Claude-Code style).
        let sep_area = Rect::new(area.x, area.y, area.width, 1);
        let separator =
            Paragraph::new("\u{2500}".repeat(area.width as usize)).style(divider_style);
        frame.render_widget(separator, sep_area);

        // Right-aligned "shell" badge on the top divider while in shell mode.
        if shell_mode {
            let badge = " shell ";
            let bw = badge.chars().count() as u16;
            if area.width > bw + 4 {
                let badge_area = Rect::new(area.x + area.width - bw - 1, area.y, bw, 1);
                frame.render_widget(
                    Paragraph::new(Span::styled(badge, theme.button_active())),
                    badge_area,
                );
            }
        }

        // Bottom divider — reserve the last row for a matching `─` rule when we
        // have room for it (top div + >=1 text row + bottom div).
        let has_bottom = area.height >= 3;
        if has_bottom {
            let bot_area = Rect::new(area.x, area.y + area.height - 1, area.width, 1);
            let bottom =
                Paragraph::new("\u{2500}".repeat(area.width as usize)).style(divider_style);
            frame.render_widget(bottom, bot_area);

            // Always-visible prefix hint, right-aligned on the bottom divider so
            // OSA's composer affordances are discoverable at a glance. Advertises
            // only prefixes that actually work.
            // Keep this minimal — the essentials only, so the composer reads calm
            // rather than busy. Shell (`!`) / newline / palette stay discoverable
            // via /help and the welcome hint instead of crowding this line.
            // Terminal-aware newline affordance (mirrors Claude Code's
            // getNewlineInstructions): when the kitty keyboard protocol is active
            // Shift+Enter reliably inserts a newline, so advertise it; otherwise
            // advertise the universal backslash-continuation ("\\\u{23ce}"), the one
            // newline that works on every terminal. Fixes the discoverability gap
            // where the only working newline key was invisible. Shown only on wide
            // enough composers so narrow terminals stay calm.
            let nl = if self.kbd_enhanced { "shift+\u{23ce}" } else { "\\\u{23ce}" };
            let w = area.width as usize;
            let hint = if w >= 76 {
                format!("  / commands \u{00b7} @ files \u{00b7} {} newline  ", nl)
            } else if w >= 60 {
                "  / commands \u{00b7} @ files  ".to_string()
            } else {
                String::new()
            };
            let hw = hint.chars().count() as u16;
            if hw > 0 && area.width > hw + 2 {
                let hint_area = Rect::new(area.x + area.width - hw, bot_area.y, hw, 1);
                frame.render_widget(
                    Paragraph::new(Span::styled(hint, theme.hint())),
                    hint_area,
                );
            }
        }

        // Input line(s) — everything between the two dividers.
        let input_h = if has_bottom {
            area.height - 2
        } else {
            area.height - 1
        };
        let input_area = Rect::new(area.x, area.y + 1, area.width, input_h);
        // Remember where the editable text sits so a mouse click can focus the
        // composer and position the caret (see `handle_click`).
        self.text_area.set(Some(input_area));

        // Vertical scroll: once the input has grown to its cap, keep the cursor's
        // line visible by scrolling within the box (so Shift+Enter keeps working
        // past the visible height instead of clipping).
        let v_scroll: u16 = if self.multiline || self.content.contains('\n') {
            let total_lines = self.content.split('\n').count() as u16;
            let cursor_line = self.content[..self.cursor.min(self.content.len())]
                .matches('\n')
                .count() as u16;
            let visible = input_area.height.max(1);
            // Keep lines 0..visible showing while the cursor is near the top; only
            // scroll once the cursor passes the last visible row, and never scroll
            // past the final line (which would blank out the box when it's small).
            let max_scroll = total_lines.saturating_sub(visible);
            cursor_line
                .saturating_sub(visible.saturating_sub(1))
                .min(max_scroll)
        } else {
            0
        };

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

        // Ctrl+R reverse-search overlay replaces the normal input line.
        if let Some(rs) = &self.reverse_search {
            let matched = rs
                .match_idx
                .and_then(|i| self.history.entries().get(i))
                .map(|s| s.replace('\n', " \u{23ce} "))
                .unwrap_or_else(|| "(no match)".to_string());
            let label = format!("(reverse-i-search)`{}': ", rs.query);
            let label_cols = label.chars().count();
            let line = Line::from(vec![
                Span::styled("\u{276f} ", prompt_style),
                Span::styled(label, theme.hint()),
                Span::raw(matched),
            ]);
            frame.render_widget(Paragraph::new(line), input_area);
            if self.focused {
                let cursor_x = area.x + 2 + label_cols as u16;
                let cursor_y = area.y + 1;
                if cursor_x < area.x + area.width {
                    frame.set_cursor_position(Position::new(cursor_x, cursor_y));
                }
            }
            self.mic_area.set(None);
            return;
        }

        if self.content.is_empty() {
            let placeholder = if self.recording {
                "\u{25C9} Recording... press Enter to stop, Esc to cancel"
            } else {
                "Ask OSA anything\u{2026}"
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
                .wrap(ratatui::widgets::Wrap { trim: false })
                .scroll((v_scroll, 0));
            frame.render_widget(paragraph, input_area);
        }

        // Slash command completions popup (draws above input)
        self.completions.draw(frame, area);

        // Step 9: File search dropdown — drawn above the input, growing upward.
        // It must stay inside the frame's real drawable area: the inline
        // viewport's frame buffer starts at `bounds.y`, so rows are clamped to
        // never land above the buffer top (or the input) and each row rect is
        // clipped to `bounds` before rendering.
        let bounds = frame.area();
        if self.file_search_active && !self.file_matches.is_empty() && area.height > 3 {
            // Room available above the input, bounded by the frame's top.
            let room_above = area.y.saturating_sub(bounds.y);
            let max_visible = self.file_matches.len().min(5).min(room_above as usize) as u16;
            let dropdown_y = area.y.saturating_sub(max_visible).max(bounds.y);
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
                let row_area =
                    Rect::new(area.x + 2, row_y, area.width.saturating_sub(4), 1).intersection(bounds);
                if row_area.width == 0 || row_area.height == 0 {
                    continue;
                }
                frame.render_widget(Paragraph::new(line), row_area);
            }
        }

        // Stash indicator
        if self.stash.is_some() && self.content.is_empty() {
            let hint = "[Ctrl+S to restore stash]";
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

        // Message-queue indicator ("N queued") — shown while messages wait for
        // the current turn to finish. During processing the mic button is
        // hidden, so the right edge is free for this badge.
        if self.queued_count > 0 {
            let label = format!(" \u{29d6} {} queued ", self.queued_count);
            let w = label.chars().count() as u16;
            if input_area.width > w + 6 {
                let q_area = Rect::new(
                    input_area.x + input_area.width - w,
                    input_area.y,
                    w,
                    1,
                );
                frame.render_widget(
                    Paragraph::new(Span::styled(label, theme.hint())),
                    q_area,
                );
            }
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
                // Account for the vertical scroll so the caret tracks the cursor
                // line even after the input has scrolled past its visible height.
                let cursor_y = area.y + 1 + (line_idx as u16).saturating_sub(v_scroll);
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

    /// Handle a left-click at terminal cell `(col, row)`. When the click lands in
    /// the composer's text area, focus the composer and move the caret to the
    /// clicked column (best-effort: single-line / first-line accuracy; multiline
    /// clicks land on the first line, which is still an improvement over no
    /// mouse support). Returns true when the click was inside the composer.
    pub fn handle_click(&mut self, col: u16, row: u16) -> bool {
        let Some(area) = self.text_area.get() else {
            return false;
        };
        if col < area.x
            || col >= area.x.saturating_add(area.width)
            || row < area.y
            || row >= area.y.saturating_add(area.height)
        {
            return false;
        }
        self.focused = true;
        if self.content.is_empty() {
            self.cursor = 0;
            return true;
        }
        // Only reposition within the first visual line — the prompt (`❯ ` /
        // `◈ ❯ `) offsets the text there. Deeper lines keep the current caret.
        let prompt_len = if self.processing { 4u16 } else { 2 };
        if row == area.y {
            let rel = col
                .saturating_sub(area.x)
                .saturating_sub(prompt_len);
            self.set_cursor_col(rel);
        }
        true
    }
}

/// True when the cursor sits on the FIRST visual line of `content` (no newline
/// before it). Pure + unit-testable geometry helper.
fn cursor_on_first_line(content: &str, cursor: usize) -> bool {
    let c = cursor.min(content.len());
    !content[..c].contains('\n')
}

/// True when the cursor sits on the LAST visual line of `content` (no newline
/// after it). Pure + unit-testable geometry helper.
fn cursor_on_last_line(content: &str, cursor: usize) -> bool {
    let c = cursor.min(content.len());
    !content[c..].contains('\n')
}

/// Decision for an Up press inside a MULTILINE buffer: cross into history
/// recall only at the very top-of-buffer edge (cursor at offset 0). Anywhere
/// else the caret moves up a line first, so a single stray Up can never replace
/// an in-progress draft — the user must deliberately reach the top-left corner
/// and press Up again (shell-style). Pure + unit-testable.
fn up_crosses_to_history(content: &str, cursor: usize) -> bool {
    cursor == 0 && cursor_on_first_line(content, cursor)
}

/// Decision for a Down press inside a MULTILINE buffer: cross into history at
/// the very end-of-buffer edge. Combined with `History::next()` (which yields
/// nothing unless already navigating), a genuine multiline draft is never
/// clobbered. Pure + unit-testable.
fn down_crosses_to_history(content: &str, cursor: usize) -> bool {
    cursor >= content.len() && cursor_on_last_line(content, cursor)
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

#[cfg(test)]
mod input_edit_tests {
    use super::*;
    use crossterm::event::{Event as CrosstermEvent, KeyCode, KeyEvent, KeyModifiers};

    fn key(code: KeyCode, mods: KeyModifiers) -> Event {
        Event::Terminal(CrosstermEvent::Key(KeyEvent::new(code, mods)))
    }

    /// Build an input with `content` and the cursor placed at byte `cursor`.
    fn at(content: &str, cursor: usize) -> InputComponent {
        let mut input = InputComponent::new();
        input.content = content.to_string();
        input.cursor = cursor.min(input.content.len());
        input.multiline = input.content.contains('\n');
        input
    }

    // ── Ctrl+U / Ctrl+K / Ctrl+W kill operations ────────────────────────────

    #[test]
    fn ctrl_u_clears_whole_buffer() {
        let mut input = at("hello world", 11);
        input.handle_event(&key(KeyCode::Char('u'), KeyModifiers::CONTROL));
        assert_eq!(input.value(), "");
        assert_eq!(input.cursor(), 0);
    }

    #[test]
    fn ctrl_k_kills_to_end_of_line() {
        // Cursor after "hello " (byte 6) — kill to end of the line.
        let mut input = at("hello world", 6);
        input.handle_event(&key(KeyCode::Char('k'), KeyModifiers::CONTROL));
        assert_eq!(input.value(), "hello ");
        assert_eq!(input.cursor(), 6);
    }

    #[test]
    fn ctrl_k_on_multiline_kills_only_current_line() {
        // "abc\ndef", cursor at byte 4 (start of "def") — kill to end of that line.
        let mut input = at("abc\ndef", 4);
        input.handle_event(&key(KeyCode::Char('k'), KeyModifiers::CONTROL));
        assert_eq!(input.value(), "abc\n");
        assert_eq!(input.cursor(), 4);
    }

    #[test]
    fn ctrl_k_on_newline_removes_the_newline() {
        // Cursor sits ON the newline (byte 3 in "abc\ndef") — remove just it.
        let mut input = at("abc\ndef", 3);
        input.handle_event(&key(KeyCode::Char('k'), KeyModifiers::CONTROL));
        assert_eq!(input.value(), "abcdef");
        assert_eq!(input.cursor(), 3);
    }

    #[test]
    fn ctrl_w_deletes_word_before_cursor() {
        let mut input = at("hello world", 11);
        input.handle_event(&key(KeyCode::Char('w'), KeyModifiers::CONTROL));
        assert_eq!(input.value(), "hello ");
        assert_eq!(input.cursor(), 6);
    }

    #[test]
    fn ctrl_w_skips_trailing_whitespace() {
        let mut input = at("hello world   ", 14);
        input.handle_event(&key(KeyCode::Char('w'), KeyModifiers::CONTROL));
        assert_eq!(input.value(), "hello ");
    }

    #[test]
    fn ctrl_d_deletes_char_forward() {
        let mut input = at("hello", 0);
        input.handle_event(&key(KeyCode::Char('d'), KeyModifiers::CONTROL));
        assert_eq!(input.value(), "ello");
        assert_eq!(input.cursor(), 0);
    }

    #[test]
    fn ctrl_d_at_end_is_noop() {
        let mut input = at("hello", 5);
        input.handle_event(&key(KeyCode::Char('d'), KeyModifiers::CONTROL));
        assert_eq!(input.value(), "hello");
        assert_eq!(input.cursor(), 5);
    }

    #[test]
    fn edits_are_utf8_safe() {
        // Multi-byte content: "héllo" ('é' is 2 bytes). Cursor at end.
        let mut input = at("héllo", "héllo".len());
        input.handle_event(&key(KeyCode::Char('w'), KeyModifiers::CONTROL));
        assert_eq!(input.value(), "");
    }

    #[test]
    fn ctrl_j_inserts_newline_not_submit() {
        let mut input = at("abc", 3);
        let action = input.handle_event(&key(KeyCode::Char('j'), KeyModifiers::CONTROL));
        assert!(matches!(action, ComponentAction::Consumed));
        assert_eq!(input.value(), "abc\n");
    }

    // ── Up/Down history-vs-linenav decision at buffer edges ──────────────────

    #[test]
    fn first_last_line_geometry() {
        let content = "one\ntwo\nthree";
        assert!(cursor_on_first_line(content, 0));
        assert!(cursor_on_first_line(content, 3)); // still on line 0 (before \n)
        assert!(!cursor_on_first_line(content, 4)); // start of "two"
        assert!(!cursor_on_last_line(content, 4));
        assert!(cursor_on_last_line(content, 8)); // start of "three"
        assert!(cursor_on_last_line(content, content.len()));
    }

    #[test]
    fn up_crosses_to_history_only_at_top_left_edge() {
        let content = "one\ntwo";
        // At offset 0 (very top-left) → cross into history.
        assert!(up_crosses_to_history(content, 0));
        // Mid first line (offset 2) → NOT yet; caret moves first.
        assert!(!up_crosses_to_history(content, 2));
        // On a later line → never crosses on Up.
        assert!(!up_crosses_to_history(content, 5));
    }

    #[test]
    fn down_crosses_to_history_only_at_bottom_end_edge() {
        let content = "one\ntwo";
        // At the very end → cross into history.
        assert!(down_crosses_to_history(content, content.len()));
        // Mid last line → not yet.
        assert!(!down_crosses_to_history(content, 5));
        // On the first line → never crosses on Down.
        assert!(!down_crosses_to_history(content, 1));
    }

    #[test]
    fn down_at_bottom_edge_without_history_nav_preserves_draft() {
        // A genuine multiline draft; not navigating history. Down at the bottom
        // must NOT wipe it (History::next yields nothing when not navigating).
        let mut input = at("line one\nline two", "line one\nline two".len());
        input.handle_event(&key(KeyCode::Down, KeyModifiers::NONE));
        assert_eq!(input.value(), "line one\nline two");
    }

    #[test]
    fn up_mid_buffer_moves_caret_not_history() {
        // Cursor on the second line; Up moves the caret up, leaving text intact.
        let mut input = at("line one\nline two", 12); // within "line two"
        input.handle_event(&key(KeyCode::Up, KeyModifiers::NONE));
        assert_eq!(input.value(), "line one\nline two");
        // Caret moved onto the first line.
        assert!(cursor_on_first_line(input.value(), input.cursor()));
    }
}
