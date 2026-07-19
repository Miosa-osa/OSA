//! Optional modal (vim) editing layer for the composer.
//!
//! Off by default; enabled via the `OSA_TUI_VIM=1` env flag or the `/vim`
//! toggle (see [`super::InputComponent::toggle_vim`]). When disabled the layer
//! is bypassed entirely so it can never interfere with the default
//! emacs/readline bindings.
//!
//! The state machine here is deliberately small — normal/insert with a single
//! pending-operator slot — mirroring Claude Code's `src/vim/`. The motion
//! helpers are pure functions over `(content, byte_cursor)` so they are unit
//! testable in isolation; the operators that mutate the buffer live on
//! `InputComponent` (they need the undo ring + completion bookkeeping).

/// Editing mode. `Normal` interprets keys as motions/operators; `Insert` types
/// text like the non-vim composer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VimMode {
    Normal,
    Insert,
}

/// Modal state: the current mode plus a one-key pending operator (`d`, `c`, or
/// `g`) awaiting its second key (`dd`, `dw`, `cc`, `gg`, …).
#[derive(Debug, Clone)]
pub struct VimState {
    pub mode: VimMode,
    pub pending: Option<char>,
}

impl Default for VimState {
    fn default() -> Self {
        // Start in Insert so enabling vim mid-draft doesn't strand the user in a
        // mode they didn't ask for; Esc drops to Normal.
        Self { mode: VimMode::Insert, pending: None }
    }
}

impl VimState {
    pub fn is_normal(&self) -> bool {
        self.mode == VimMode::Normal
    }

    /// Short indicator for the composer badge.
    pub fn label(&self) -> &'static str {
        match self.mode {
            VimMode::Normal => "NORMAL",
            VimMode::Insert => "INSERT",
        }
    }
}

/// Whether `c` counts as a "word" char for vim word motions. Everything that
/// isn't whitespace is treated as one class (simplified `w`/`b`/`e`, closer to
/// vim's `W`/`B`/`E`) — good enough for a composer and avoids surprising splits
/// on punctuation-heavy paths like `src/app/mod.rs`.
fn is_word(c: char) -> bool {
    !c.is_whitespace()
}

/// Byte offset of the start of the line containing `cur`.
pub fn line_start(content: &str, cur: usize) -> usize {
    content[..cur.min(content.len())]
        .rfind('\n')
        .map(|p| p + 1)
        .unwrap_or(0)
}

/// Byte offset of the end of the line containing `cur` (the next `\n`, or EOF).
pub fn line_end(content: &str, cur: usize) -> usize {
    let c = cur.min(content.len());
    content[c..]
        .find('\n')
        .map(|p| c + p)
        .unwrap_or(content.len())
}

/// Byte offset of the first non-blank char on `cur`'s line (vim `^`).
pub fn first_non_blank(content: &str, cur: usize) -> usize {
    let s = line_start(content, cur);
    let e = line_end(content, cur);
    for (b, ch) in content[s..e].char_indices() {
        if !ch.is_whitespace() {
            return s + b;
        }
    }
    s
}

/// vim `w` — start of the next word (byte offset). Skips the current word then
/// any whitespace; clamps to EOF.
pub fn word_forward(content: &str, cur: usize) -> usize {
    let len = content.len();
    let mut i = cur.min(len);
    // Skip the rest of the current word.
    while i < len {
        let ch = char_at(content, i);
        if is_word(ch) {
            i += ch.len_utf8();
        } else {
            break;
        }
    }
    // Skip whitespace to the next word start.
    while i < len {
        let ch = char_at(content, i);
        if ch.is_whitespace() {
            i += ch.len_utf8();
        } else {
            break;
        }
    }
    i
}

/// vim `b` — start of the previous word (byte offset).
pub fn word_back(content: &str, cur: usize) -> usize {
    let mut i = cur.min(content.len());
    // Step back over any whitespace.
    while i > 0 {
        let ch = char_before(content, i);
        if ch.is_whitespace() {
            i -= ch.len_utf8();
        } else {
            break;
        }
    }
    // Step back to the start of this word.
    while i > 0 {
        let ch = char_before(content, i);
        if is_word(ch) {
            i -= ch.len_utf8();
        } else {
            break;
        }
    }
    i
}

/// vim `e` — end of the next word (byte offset of the LAST char of the word,
/// i.e. the caret rests on it).
pub fn word_end(content: &str, cur: usize) -> usize {
    let len = content.len();
    let mut i = cur.min(len);
    // Advance at least one char so a repeated `e` progresses.
    if i < len {
        i += char_at(content, i).len_utf8();
    }
    // Skip whitespace.
    while i < len {
        let ch = char_at(content, i);
        if ch.is_whitespace() {
            i += ch.len_utf8();
        } else {
            break;
        }
    }
    // Advance to the last char of the word.
    let mut last = i;
    while i < len {
        let ch = char_at(content, i);
        if is_word(ch) {
            last = i;
            i += ch.len_utf8();
        } else {
            break;
        }
    }
    last
}

/// The char starting at byte offset `i` (caller guarantees `i < len` and that
/// `i` is a char boundary).
fn char_at(content: &str, i: usize) -> char {
    content[i..].chars().next().unwrap_or('\0')
}

/// The char ending at byte offset `i` (the char immediately left of `i`).
fn char_before(content: &str, i: usize) -> char {
    content[..i].chars().next_back().unwrap_or('\0')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn word_motions_over_path_like_text() {
        let s = "one two three";
        assert_eq!(word_forward(s, 0), 4); // → "two"
        assert_eq!(word_forward(s, 4), 8); // → "three"
        assert_eq!(word_back(s, 8), 4); // ← "two"
        assert_eq!(word_back(s, 4), 0); // ← "one"
        assert_eq!(word_end(s, 0), 2); // last char of "one"
        assert_eq!(word_end(s, 4), 6); // last char of "two"
    }

    #[test]
    fn line_helpers() {
        let s = "  ab\ncd";
        assert_eq!(line_start(s, 6), 5); // second line starts after '\n'
        assert_eq!(line_end(s, 0), 4); // first line ends at the '\n'
        assert_eq!(first_non_blank(s, 0), 2); // skips the two leading spaces
    }

    #[test]
    fn word_forward_clamps_at_eof() {
        let s = "word";
        assert_eq!(word_forward(s, 0), 4);
        assert_eq!(word_forward(s, 4), 4);
    }

    #[test]
    fn state_transitions_label() {
        let mut st = VimState::default();
        assert_eq!(st.label(), "INSERT");
        st.mode = VimMode::Normal;
        assert!(st.is_normal());
        assert_eq!(st.label(), "NORMAL");
    }
}
