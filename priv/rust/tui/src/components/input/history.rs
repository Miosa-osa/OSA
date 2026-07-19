// Phase 2+: history reset_navigation — wired when history navigation is extended
#![allow(dead_code)]

use std::path::PathBuf;

/// Default cap for the persisted history ring.
const DEFAULT_MAX: usize = 1000;

/// Command history with navigation, persisted to `~/.osa/tui_history`.
///
/// Entries are a bounded ring (newest at the back). Multi-line entries are
/// stored one-per-file-line by escaping `\` → `\\` and newlines → `\n`, so a
/// pasted multi-line prompt round-trips intact.
pub struct History {
    entries: Vec<String>,
    index: Option<usize>,
    max_size: usize,
    path: Option<PathBuf>,
}

fn history_path() -> Option<PathBuf> {
    named_history_path("tui_history")
}

/// U-T4 — separate on-disk bucket for `!`-shell submissions.
fn shell_history_path() -> Option<PathBuf> {
    named_history_path("tui_shell_history")
}

fn named_history_path(name: &str) -> Option<PathBuf> {
    // Cross-platform home resolution (see config/mod.rs::home_dir). BaseDirs
    // honors USERPROFILE on Windows, where HOME is normally unset — otherwise
    // command history is never loaded/persisted and up-arrow recall silently
    // does nothing for the whole session.
    let home = directories::BaseDirs::new()
        .map(|d| d.home_dir().to_path_buf())
        .or_else(|| std::env::var("HOME").ok().map(PathBuf::from))?;
    Some(home.join(".osa").join(name))
}

/// Encode a (possibly multi-line) entry into a single storage line.
fn encode(entry: &str) -> String {
    let mut out = String::with_capacity(entry.len());
    for ch in entry.chars() {
        match ch {
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => {} // drop bare CRs; \n carries the newline
            c => out.push(c),
        }
    }
    out
}

/// Decode a storage line back into its original entry.
fn decode(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut chars = line.chars();
    while let Some(ch) = chars.next() {
        if ch == '\\' {
            match chars.next() {
                Some('n') => out.push('\n'),
                Some('\\') => out.push('\\'),
                Some(other) => {
                    out.push('\\');
                    out.push(other);
                }
                None => out.push('\\'),
            }
        } else {
            out.push(ch);
        }
    }
    out
}

impl History {
    /// In-memory-only history (no persistence). Kept for tests / fallback.
    pub fn new(max_size: usize) -> Self {
        Self {
            entries: Vec::new(),
            index: None,
            max_size: max_size.max(1),
            path: None,
        }
    }

    /// Persistent history backed by `~/.osa/tui_history`, loading any existing
    /// entries. Falls back to in-memory if the home dir can't be resolved.
    pub fn persistent() -> Self {
        Self::load_from(history_path())
    }

    /// U-T4 — persistent `!`-shell-command history (`~/.osa/tui_shell_history`),
    /// a bucket separate from the prompt history.
    pub fn shell_persistent() -> Self {
        Self::load_from(shell_history_path())
    }

    fn load_from(path: Option<PathBuf>) -> Self {
        let max_size = DEFAULT_MAX;
        let entries = path
            .as_ref()
            .and_then(|p| std::fs::read_to_string(p).ok())
            .map(|contents| {
                let mut v: Vec<String> = contents
                    .lines()
                    .filter(|l| !l.is_empty())
                    .map(decode)
                    .collect();
                if v.len() > max_size {
                    let drop = v.len() - max_size;
                    v.drain(0..drop);
                }
                v
            })
            .unwrap_or_default();
        Self {
            entries,
            index: None,
            max_size,
            path,
        }
    }

    pub fn push(&mut self, entry: String) {
        // Don't add duplicates of the last entry
        if self.entries.last().map(|e| e.as_str()) == Some(&entry) {
            self.index = None;
            return;
        }
        self.entries.push(entry);
        if self.entries.len() > self.max_size {
            let drop = self.entries.len() - self.max_size;
            self.entries.drain(0..drop);
        }
        self.index = None;
        self.persist();
    }

    /// Rewrite the whole ring to disk. Cheap at ~1000 lines; keeps the file
    /// bounded instead of growing without limit.
    fn persist(&self) {
        let Some(path) = self.path.as_ref() else {
            return;
        };
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let mut buf = String::new();
        for entry in &self.entries {
            buf.push_str(&encode(entry));
            buf.push('\n');
        }
        let _ = std::fs::write(path, buf);
    }

    pub fn prev(&mut self) -> Option<&str> {
        if self.entries.is_empty() {
            return None;
        }
        let idx = match self.index {
            None => self.entries.len() - 1,
            Some(0) => 0,
            Some(i) => i - 1,
        };
        self.index = Some(idx);
        self.entries.get(idx).map(|s| s.as_str())
    }

    pub fn next(&mut self) -> Option<&str> {
        match self.index {
            None => None,
            Some(i) => {
                if i + 1 >= self.entries.len() {
                    self.index = None;
                    None
                } else {
                    self.index = Some(i + 1);
                    self.entries.get(i + 1).map(|s| s.as_str())
                }
            }
        }
    }

    pub fn reset_navigation(&mut self) {
        self.index = None;
    }

    /// Whether a history-recall walk is in progress (the caller is showing a
    /// recalled entry rather than editing a fresh line). Used to decide when to
    /// stash a half-typed draft before the first step into history.
    pub fn is_navigating(&self) -> bool {
        self.index.is_some()
    }

    /// All entries, oldest-first. Used by reverse-incremental search.
    pub fn entries(&self) -> &[String] {
        &self.entries
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Reverse-incremental search: find the newest entry at or before
    /// `before_idx` (exclusive upper bound) that contains `query`
    /// (case-insensitive). Returns the matching entry index.
    pub fn search_backward(&self, query: &str, before_idx: usize) -> Option<usize> {
        if self.entries.is_empty() {
            return None;
        }
        let q = query.to_lowercase();
        let start = before_idx.min(self.entries.len());
        (0..start)
            .rev()
            .find(|&i| q.is_empty() || self.entries[i].to_lowercase().contains(&q))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode_roundtrip_multiline() {
        let s = "line1\nline2\\end";
        assert_eq!(decode(&encode(s)), s);
    }

    #[test]
    fn ring_caps_entries() {
        let mut h = History::new(3);
        for i in 0..5 {
            h.push(format!("cmd{i}"));
        }
        assert_eq!(h.len(), 3);
        assert_eq!(h.entries(), &["cmd2", "cmd3", "cmd4"]);
    }

    #[test]
    fn search_backward_finds_newest_match() {
        let mut h = History::new(10);
        for s in ["ls", "git status", "git commit", "cargo build"] {
            h.push(s.to_string());
        }
        // Newest "git" match, searching from the end.
        let idx = h.search_backward("git", h.len()).unwrap();
        assert_eq!(h.entries()[idx], "git commit");
        // Continue older.
        let older = h.search_backward("git", idx).unwrap();
        assert_eq!(h.entries()[older], "git status");
    }
}
