// Phase 2+: file attachment dialog — not yet wired to input flow
#![allow(dead_code)]

/// File/directory browser dialog.
///
/// # Actions to add to `DialogAction` in mod.rs:
/// ```
/// FilePickerSelect(String),  // absolute path
/// FilePickerCancel,
/// ```
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::{
    prelude::*,
    widgets::{Block, BorderType, Borders, Clear, Paragraph},
};
use std::path::PathBuf;

const MAX_W: u16 = 80;
const MAX_H: u16 = 28;

// ── Action ────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub enum FilePickerAction {
    Select(String),
    Cancel,
}

// ── Entry ─────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
struct FileEntry {
    name: String,
    is_dir: bool,
    size: u64,
}

// ── State ─────────────────────────────────────────────────────────────────────

pub struct FilePicker {
    current_dir: PathBuf,
    entries: Vec<FileEntry>,
    /// Indices into `entries` that pass the current filter
    filtered: Vec<usize>,
    filter: String,
    cursor: usize,
    scroll_offset: usize,
    /// Error message from last `read_dir`, if any
    error: Option<String>,
}

impl FilePicker {
    /// Open a file picker starting at `start_dir`. Falls back to the current
    /// working directory if `start_dir` does not exist.
    pub fn new(start_dir: PathBuf) -> Self {
        let dir = if start_dir.is_dir() {
            start_dir
        } else {
            std::env::current_dir().unwrap_or_else(|_| PathBuf::from("/"))
        };
        let mut picker = Self {
            current_dir: dir,
            entries: Vec::new(),
            filtered: Vec::new(),
            filter: String::new(),
            cursor: 0,
            scroll_offset: 0,
            error: None,
        };
        picker.load_entries();
        picker
    }

    // ── Directory loading ─────────────────────────────────────────────────────

    fn load_entries(&mut self) {
        self.entries.clear();
        self.error = None;

        match std::fs::read_dir(&self.current_dir) {
            Ok(rd) => {
                let mut dirs: Vec<FileEntry> = Vec::new();
                let mut files: Vec<FileEntry> = Vec::new();

                for entry_result in rd {
                    let entry = match entry_result {
                        Ok(e) => e,
                        Err(_) => continue,
                    };
                    let name = entry.file_name().to_string_lossy().to_string();
                    // Skip hidden files (starting with '.')
                    if name.starts_with('.') {
                        continue;
                    }
                    let metadata = entry.metadata().ok();
                    let is_dir = metadata.as_ref().map(|m| m.is_dir()).unwrap_or(false);
                    let size = metadata.as_ref().map(|m| m.len()).unwrap_or(0);

                    let fe = FileEntry { name, is_dir, size };
                    if is_dir {
                        dirs.push(fe);
                    } else {
                        files.push(fe);
                    }
                }

                dirs.sort_by(|a, b| a.name.cmp(&b.name));
                files.sort_by(|a, b| a.name.cmp(&b.name));
                self.entries.extend(dirs);
                self.entries.extend(files);
            }
            Err(e) => {
                self.error = Some(format!("Cannot read directory: {}", e));
            }
        }

        self.cursor = 0;
        self.scroll_offset = 0;
        self.apply_filter();
    }

    fn apply_filter(&mut self) {
        let f = self.filter.to_lowercase();
        self.filtered = (0..self.entries.len())
            .filter(|&i| {
                f.is_empty() || self.entries[i].name.to_lowercase().contains(&f)
            })
            .collect();
        self.cursor = self.cursor.min(self.filtered.len().saturating_sub(1));
        self.adjust_scroll();
    }

    // ── Navigation ────────────────────────────────────────────────────────────

    fn move_up(&mut self) {
        if !self.filtered.is_empty() {
            self.cursor = self.cursor.checked_sub(1).unwrap_or(self.filtered.len() - 1);
            self.adjust_scroll();
        }
    }

    fn move_down(&mut self) {
        if !self.filtered.is_empty() {
            self.cursor = (self.cursor + 1) % self.filtered.len();
            self.adjust_scroll();
        }
    }

    fn adjust_scroll(&mut self) {
        let visible = (MAX_H as usize).saturating_sub(8);
        if self.cursor < self.scroll_offset {
            self.scroll_offset = self.cursor;
        } else if self.cursor >= self.scroll_offset + visible {
            self.scroll_offset = self.cursor - visible + 1;
        }
    }

    fn current_entry(&self) -> Option<&FileEntry> {
        let idx = *self.filtered.get(self.cursor)?;
        self.entries.get(idx)
    }

    fn enter_selected(&mut self) -> Option<FilePickerAction> {
        if let Some(entry) = self.current_entry() {
            if entry.is_dir {
                let mut new_dir = self.current_dir.clone();
                new_dir.push(&entry.name);
                self.current_dir = new_dir;
                self.filter.clear();
                self.load_entries();
                None
            } else {
                let mut path = self.current_dir.clone();
                path.push(&entry.name);
                Some(FilePickerAction::Select(
                    path.to_string_lossy().to_string(),
                ))
            }
        } else {
            None
        }
    }

    fn go_parent(&mut self) {
        if let Some(parent) = self.current_dir.parent() {
            self.current_dir = parent.to_path_buf();
            self.filter.clear();
            self.load_entries();
        }
    }

    // ── Key handling ─────────────────────────────────────────────────────────

    pub fn handle_key(&mut self, key: KeyEvent) -> Option<FilePickerAction> {
        if key.modifiers.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) {
            return None;
        }

        match key.code {
            KeyCode::Esc => return Some(FilePickerAction::Cancel),
            KeyCode::Enter => return self.enter_selected(),
            KeyCode::Up | KeyCode::Char('k') => self.move_up(),
            KeyCode::Down | KeyCode::Char('j') => self.move_down(),
            KeyCode::Backspace => {
                if !self.filter.is_empty() {
                    self.filter.pop();
                    self.apply_filter();
                } else {
                    // Empty filter + backspace = go up
                    self.go_parent();
                }
            }
            KeyCode::Char(c) => {
                self.filter.push(c);
                self.scroll_offset = 0;
                self.cursor = 0;
                self.apply_filter();
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
        frame.render_widget(
            Paragraph::new("Select File")
                .style(theme.dialog_title())
                .alignment(Alignment::Center),
            Rect::new(inner.x, cy, inner.width, 1),
        );
        cy += 1;

        // Current path (truncated to fit)
        let path_str = self.current_dir.to_string_lossy();
        let max_path_w = inner.width.saturating_sub(4) as usize;
        let path_display = if path_str.len() > max_path_w {
            format!("…{}", crate::util::truncate_str_start(&path_str, max_path_w.saturating_sub(1)))
        } else {
            path_str.to_string()
        };
        frame.render_widget(
            Paragraph::new(format!("  {}", path_display))
                .style(Style::default().fg(theme.colors.secondary)),
            Rect::new(inner.x, cy, inner.width, 1),
        );
        cy += 1;

        // Filter bar
        let count = self.filtered.len();
        let filter_display = if self.filter.is_empty() {
            format!("  Filter: _  ({} items)", count)
        } else {
            format!("  Filter: {}_  ({} items)", self.filter, count)
        };
        frame.render_widget(
            Paragraph::new(filter_display)
                .style(Style::default().fg(theme.colors.muted)),
            Rect::new(inner.x, cy, inner.width, 1),
        );
        cy += 1;

        // Error if any
        if let Some(err) = &self.error {
            frame.render_widget(
                Paragraph::new(format!("  ⚠ {}", err))
                    .style(theme.error_text()),
                Rect::new(inner.x, cy, inner.width, 1),
            );
            cy += 1;
        }

        // Separator
        let sep = "─".repeat(inner.width as usize);
        frame.render_widget(
            Paragraph::new(sep.as_str()).style(Style::default().fg(theme.colors.dim)),
            Rect::new(inner.x, cy, inner.width, 1),
        );
        cy += 1;

        // File list
        let list_h = inner.height.saturating_sub(cy - inner.y + 2);
        let visible = self
            .filtered
            .iter()
            .skip(self.scroll_offset)
            .take(list_h as usize);

        for (rel_i, &idx) in visible.enumerate() {
            let abs_i = rel_i + self.scroll_offset;
            let ry = cy + rel_i as u16;
            if ry >= cy + list_h {
                break;
            }

            let entry = &self.entries[idx];
            let is_selected = abs_i == self.cursor;

            let cursor_char = if is_selected { "▸" } else { " " };
            let icon = if entry.is_dir { "▶" } else { " " };

            let name_style = if is_selected {
                Style::default()
                    .fg(theme.colors.primary)
                    .add_modifier(Modifier::BOLD)
            } else if entry.is_dir {
                Style::default().fg(theme.colors.secondary)
            } else {
                Style::default().fg(theme.colors.muted)
            };

            let size_str = if entry.is_dir {
                String::new()
            } else {
                format_size(entry.size)
            };

            // Truncate name
            let max_name = inner.width.saturating_sub(16) as usize;
            let name_display = if entry.name.len() > max_name {
                format!("{}…", crate::util::truncate_str(&entry.name, max_name.saturating_sub(1)))
            } else {
                entry.name.clone()
            };

            let spans = vec![
                Span::styled(format!("{} {} ", cursor_char, icon), name_style),
                Span::styled(name_display, name_style),
                Span::raw("  "),
                Span::styled(size_str, Style::default().fg(theme.colors.dim)),
            ];

            frame.render_widget(
                Paragraph::new(Line::from(spans)),
                Rect::new(inner.x, ry, inner.width, 1),
            );
        }

        // Help bar
        let bottom_y = inner.y + inner.height.saturating_sub(1);
        let help = Line::from(vec![
            Span::styled("↑↓", theme.dialog_help_key()),
            Span::styled(" nav  ", theme.dialog_help()),
            Span::styled("Enter", theme.dialog_help_key()),
            Span::styled(" open  ", theme.dialog_help()),
            Span::styled("⌫", theme.dialog_help_key()),
            Span::styled(" parent/filter  ", theme.dialog_help()),
            Span::styled("Esc", theme.dialog_help_key()),
            Span::styled(" cancel", theme.dialog_help()),
        ]);
        frame.render_widget(
            Paragraph::new(help).alignment(Alignment::Center),
            Rect::new(inner.x, bottom_y, inner.width, 1),
        );
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn format_size(bytes: u64) -> String {
    if bytes >= 1_073_741_824 {
        format!("{:.1}G", bytes as f64 / 1_073_741_824.0)
    } else if bytes >= 1_048_576 {
        format!("{:.1}M", bytes as f64 / 1_048_576.0)
    } else if bytes >= 1_024 {
        format!("{:.1}K", bytes as f64 / 1_024.0)
    } else {
        format!("{}B", bytes)
    }
}

#[cfg(test)]
mod picker_render_tests {
    use super::*;
    use ratatui::backend::TestBackend;
    use ratatui::Terminal;
    use std::path::PathBuf;

    /// Build a directory whose own path AND contents contain multi-byte names,
    /// so both the path-header and file-name shortening paths are exercised
    /// with mid-char cuts on a narrow dialog.
    fn unicode_dir() -> PathBuf {
        let mut dir = std::env::temp_dir();
        dir.push(format!("osa_fp_test_\u{4e2d}\u{6587}_{}", std::process::id()));
        // A deeply-nested unicode path for the from-the-right header shortening.
        dir.push("caf\u{e9}_\u{20ac}\u{20ac}\u{20ac}_directory_with_a_long_unicode_name");
        let _ = std::fs::create_dir_all(&dir);
        let long_name = format!("{}.txt", "\u{20ac}".repeat(40));
        let _ = std::fs::write(dir.join(&long_name), b"x");
        let _ = std::fs::write(dir.join("caf\u{e9}_\u{1f600}_file.md"), b"y");
        dir
    }

    #[test]
    fn file_picker_multibyte_entries_and_path_never_panic() {
        let dir = unicode_dir();
        let picker = FilePicker::new(dir.clone());
        for &(w, h) in &[(1u16, 1u16), (10, 3), (24, 8), (60, 20), (200, 60)] {
            let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
            term.draw(|f| {
                let area = f.area();
                picker.draw(f, area);
            })
            .unwrap();
        }
        // Best-effort cleanup; ignore errors.
        let _ = std::fs::remove_dir_all(std::env::temp_dir().join(format!(
            "osa_fp_test_\u{4e2d}\u{6587}_{}",
            std::process::id()
        )));
    }
}
