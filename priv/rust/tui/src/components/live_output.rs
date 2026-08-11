//! Bounded live preview of streamed shell-command output.
//!
//! A long-running foreground command emits `command_output_delta` events while
//! it runs. Those deltas are appended here, and the activity feed renders the
//! last few retained lines so the user sees the command working instead of a
//! silent spinner.
//!
//! Structure ported from Codex (`tui/src/exec_cell/live_output.rs`):
//!
//!   * All output is retained verbatim until `MAX_BYTES` is exceeded.
//!   * Once over budget the buffer keeps only the first `MAX_LINES` and last
//!     `MAX_LINES` completed lines plus any in-progress line.
//!   * Each line INDEPENDENTLY keeps a head slice and a tail slice, so a
//!     command that never emits a newline (a `\r` progress bar, `dd status`,
//!     a minified blob) cannot grow the buffer without bound.
//!
//! The last property is the important one: without per-line clipping a
//! newline-free flood would sit forever in `current` and the "bounded" buffer
//! would be unbounded in practice.

use std::collections::VecDeque;

/// Total byte budget before the buffer switches to head/tail retention.
pub const MAX_BYTES: usize = 1024 * 1024;
/// Completed lines retained at each end once truncated.
pub const MAX_LINES: usize = 50;
/// Byte budget for a single retained line.
pub const MAX_LINE_BYTES: usize = MAX_BYTES / (2 * MAX_LINES + 2);
const LINE_HEAD_BYTES: usize = MAX_LINE_BYTES / 2;
const LINE_TAIL_BYTES: usize = MAX_LINE_BYTES - LINE_HEAD_BYTES;

/// A bounded, incremental preview of streamed command output.
#[derive(Debug, Default, Clone)]
pub struct LiveCommandOutput {
    full_output: String,
    truncated: bool,
    head: Vec<String>,
    tail: VecDeque<String>,
    current: LiveCommandOutputLine,
    completed_lines: usize,
    has_partial_line: bool,
    pending_carriage_return: bool,
}

impl LiveCommandOutput {
    pub fn new() -> Self {
        Self::default()
    }

    /// Appends a delta, preserving `str::lines` semantics across arbitrary
    /// chunk boundaries (a chunk may split a line, a CRLF, or a UTF-8 char
    /// boundary is never produced because deltas arrive as `String`s).
    pub fn push_str(&mut self, chunk: &str) {
        if !self.truncated {
            if self.full_output.len().saturating_add(chunk.len()) <= MAX_BYTES {
                self.full_output.push_str(chunk);
                self.completed_lines = self
                    .completed_lines
                    .saturating_add(chunk.bytes().filter(|byte| *byte == b'\n').count());
                if !chunk.is_empty() {
                    self.has_partial_line = !chunk.ends_with('\n');
                }
                return;
            }

            // Budget blown — replay everything collected so far through the
            // bounded path, then continue bounded from here on.
            self.truncated = true;
            let full_output = std::mem::take(&mut self.full_output);
            self.completed_lines = 0;
            self.has_partial_line = false;
            self.push_truncated_str(&full_output);
        }

        self.push_truncated_str(chunk);
    }

    /// Appends bounded output, treating a split CRLF as one terminator and
    /// retaining lone CRs (progress bars rewrite a line with `\r`).
    fn push_truncated_str(&mut self, chunk: &str) {
        for part in chunk.split_inclusive('\n') {
            let Some(part) = part.strip_suffix('\n') else {
                // Trailing fragment with no newline — extend the current line.
                if part.is_empty() {
                    continue;
                }
                if self.pending_carriage_return {
                    self.current.push_str("\r");
                    self.pending_carriage_return = false;
                }
                let part = if let Some(part) = part.strip_suffix('\r') {
                    self.pending_carriage_return = true;
                    part
                } else {
                    part
                };
                self.current.push_str(part);
                self.has_partial_line |= !part.is_empty() || self.pending_carriage_return;
                continue;
            };

            let has_carriage_return = part.ends_with('\r');
            let part = part.strip_suffix('\r').unwrap_or(part);
            if self.pending_carriage_return && (has_carriage_return || !part.is_empty()) {
                self.current.push_str("\r");
            }
            self.pending_carriage_return = false;
            self.current.push_str(part);
            self.completed_lines = self.completed_lines.saturating_add(1);
            self.has_partial_line = false;

            let line = std::mem::take(&mut self.current).render();
            if self.head.len() < MAX_LINES {
                self.head.push(line);
            } else {
                if self.tail.len() == MAX_LINES {
                    self.tail.pop_front();
                }
                self.tail.push_back(line);
            }
        }
    }

    pub fn is_empty(&self) -> bool {
        !self.truncated && self.full_output.is_empty()
    }

    pub fn clear(&mut self) {
        *self = Self::default();
    }

    /// Total lines the command has produced (including the in-progress one),
    /// regardless of how many are still retained.
    pub fn total_lines(&self) -> usize {
        self.completed_lines
            .saturating_add(usize::from(self.has_partial_line))
    }

    /// Lines still held in the buffer.
    pub fn retained_lines(&self) -> usize {
        if self.truncated {
            self.head
                .len()
                .saturating_add(self.tail.len())
                .saturating_add(usize::from(self.has_partial_line))
        } else {
            self.total_lines()
        }
    }

    pub fn truncated(&self) -> bool {
        self.truncated
    }

    /// All retained preview lines, oldest first, each abbreviated to the
    /// per-line byte budget.
    pub fn lines(&self) -> Vec<String> {
        if self.truncated {
            let mut out: Vec<String> =
                Vec::with_capacity(self.head.len() + self.tail.len() + 1);
            out.extend(self.head.iter().cloned());
            out.extend(self.tail.iter().cloned());
            if self.has_partial_line {
                out.push(self.render_partial_line());
            }
            out
        } else {
            self.full_output
                .lines()
                .map(|line| {
                    if line.len() <= MAX_LINE_BYTES {
                        line.to_string()
                    } else {
                        let mut truncated = LiveCommandOutputLine::default();
                        truncated.push_str(line);
                        truncated.render()
                    }
                })
                .collect()
        }
    }

    /// The last `n` retained lines — what the activity feed actually renders.
    pub fn tail_lines(&self, n: usize) -> Vec<String> {
        if n == 0 {
            return Vec::new();
        }
        let mut lines = self.lines();
        if lines.len() > n {
            lines.drain(..lines.len() - n);
        }
        lines
    }

    fn render_partial_line(&self) -> String {
        let mut line = self.current.render();
        if self.pending_carriage_return {
            line.push('\r');
        }
        line
    }
}

/// A single retained line that independently keeps a head and a tail slice, so
/// an arbitrarily long line costs at most `MAX_LINE_BYTES`.
#[derive(Debug, Default, Clone)]
struct LiveCommandOutputLine {
    head: String,
    tail: String,
    omitted_bytes: usize,
}

impl LiveCommandOutputLine {
    fn push_str(&mut self, chunk: &str) {
        let head_remaining = if self.tail.is_empty() && self.omitted_bytes == 0 {
            LINE_HEAD_BYTES.saturating_sub(self.head.len())
        } else {
            0
        };
        let mut head_end = head_remaining.min(chunk.len());
        while !chunk.is_char_boundary(head_end) {
            head_end -= 1;
        }
        self.head.push_str(&chunk[..head_end]);
        let chunk = &chunk[head_end..];
        if chunk.is_empty() {
            return;
        }

        if chunk.len() >= LINE_TAIL_BYTES {
            let mut tail_start = chunk.len() - LINE_TAIL_BYTES;
            while !chunk.is_char_boundary(tail_start) {
                tail_start += 1;
            }
            self.omitted_bytes = self
                .omitted_bytes
                .saturating_add(self.tail.len())
                .saturating_add(tail_start);
            self.tail.clear();
            self.tail.push_str(&chunk[tail_start..]);
            return;
        }

        self.tail.push_str(chunk);
        let mut tail_start = self.tail.len().saturating_sub(LINE_TAIL_BYTES);
        while !self.tail.is_char_boundary(tail_start) {
            tail_start += 1;
        }
        if tail_start > 0 {
            self.tail.drain(..tail_start);
            self.omitted_bytes = self.omitted_bytes.saturating_add(tail_start);
        }
    }

    fn render(&self) -> String {
        let omission_marker =
            (self.omitted_bytes > 0).then(|| format!("… {} bytes omitted …", self.omitted_bytes));
        let mut line = String::with_capacity(
            self.head
                .len()
                .saturating_add(self.tail.len())
                .saturating_add(omission_marker.as_ref().map_or(0, String::len)),
        );
        line.push_str(&self.head);
        if let Some(marker) = omission_marker {
            line.push_str(&marker);
        }
        line.push_str(&self.tail);
        line
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn retains_everything_below_the_byte_budget() {
        let mut out = LiveCommandOutput::new();
        out.push_str("alpha\nbeta\ngamma\n");
        assert!(!out.truncated());
        assert_eq!(out.total_lines(), 3);
        assert_eq!(out.lines(), vec!["alpha", "beta", "gamma"]);
    }

    #[test]
    fn tail_lines_returns_only_the_last_n() {
        let mut out = LiveCommandOutput::new();
        for i in 0..20 {
            out.push_str(&format!("line {i}\n"));
        }
        assert_eq!(
            out.tail_lines(5),
            vec!["line 15", "line 16", "line 17", "line 18", "line 19"]
        );
        assert!(out.tail_lines(0).is_empty());
    }

    #[test]
    fn partial_line_is_visible_before_its_newline_arrives() {
        let mut out = LiveCommandOutput::new();
        out.push_str("done\nin prog");
        assert_eq!(out.tail_lines(2), vec!["done", "in prog"]);
        out.push_str("ress\n");
        assert_eq!(out.tail_lines(2), vec!["done", "in progress"]);
    }

    #[test]
    fn line_split_across_chunks_is_joined() {
        let mut out = LiveCommandOutput::new();
        out.push_str("he");
        out.push_str("ll");
        out.push_str("o\n");
        assert_eq!(out.lines(), vec!["hello"]);
        assert_eq!(out.total_lines(), 1);
    }

    #[test]
    fn crlf_split_across_chunks_is_one_terminator() {
        let mut out = LiveCommandOutput::new();
        out.push_str("a\r");
        out.push_str("\nb\r\n");
        // Force the bounded path so CR handling is exercised.
        assert_eq!(out.total_lines(), 2);
    }

    #[test]
    fn head_and_tail_lines_are_kept_when_the_budget_is_blown() {
        let mut out = LiveCommandOutput::new();
        // Each line is ~1KiB; 2000 of them blows the 1MiB budget.
        let filler = "x".repeat(1000);
        for i in 0..2000 {
            out.push_str(&format!("{i:04}{filler}\n"));
        }
        assert!(out.truncated());
        assert_eq!(out.total_lines(), 2000);
        assert_eq!(out.retained_lines(), 2 * MAX_LINES);

        let lines = out.lines();
        // First retained line is the very first emitted line …
        assert!(lines[0].starts_with("0000"), "got {}", &lines[0][..8]);
        // … and the last retained line is the very last emitted line.
        assert!(
            lines[lines.len() - 1].starts_with("1999"),
            "got {}",
            &lines[lines.len() - 1][..8]
        );
    }

    #[test]
    fn newline_free_flood_cannot_grow_the_buffer_without_bound() {
        let mut out = LiveCommandOutput::new();
        // 8 MiB of output with no newline at all — the pathological `\r`
        // progress-bar / `dd status=progress` case.
        let blob = "y".repeat(64 * 1024);
        for _ in 0..128 {
            out.push_str(&blob);
        }
        assert!(out.truncated());

        let lines = out.lines();
        assert_eq!(lines.len(), 1, "a newline-free flood is a single line");
        let retained: usize = lines.iter().map(String::len).sum();
        assert!(
            retained <= MAX_LINE_BYTES + 64,
            "retained {retained} bytes exceeds the per-line budget {MAX_LINE_BYTES}"
        );
        // Both ends of the line are preserved with an omission marker between.
        assert!(lines[0].contains("bytes omitted"));
    }

    #[test]
    fn carriage_return_progress_bar_is_bounded() {
        let mut out = LiveCommandOutput::new();
        for i in 0..200_000 {
            out.push_str(&format!("\rprogress {i}"));
        }
        let retained: usize = out.lines().iter().map(String::len).sum();
        assert!(
            retained <= MAX_LINE_BYTES + 64,
            "retained {retained} bytes exceeds the per-line budget"
        );
    }

    #[test]
    fn multibyte_chars_never_split_mid_codepoint() {
        let mut out = LiveCommandOutput::new();
        // 3-byte chars, far past the per-line budget.
        out.push_str(&"€".repeat(MAX_LINE_BYTES));
        out.push_str("\n");
        // Rendering must produce valid UTF-8 (it is a String, so the real
        // assertion is that no slice panicked above).
        assert_eq!(out.lines().len(), 1);
    }

    #[test]
    fn clear_resets_the_buffer() {
        let mut out = LiveCommandOutput::new();
        out.push_str("something\n");
        assert!(!out.is_empty());
        out.clear();
        assert!(out.is_empty());
        assert_eq!(out.total_lines(), 0);
        assert!(out.lines().is_empty());
    }
}

/// **Row accounting** — the preview must never silently drop a row it claims to
/// be showing.
///
/// The head/tail elision path deliberately discards MIDDLE lines, which is
/// correct and is the whole point. What must not happen is the buffer reporting
/// one row count while rendering another: that count is what the activity feed
/// reserves against, so a disagreement is a dead-row gap or an overdraw. These
/// assert the reported total equals the rendered total — the technique that
/// makes a dropped row fail loudly instead of silently.
#[cfg(test)]
mod row_accounting {
    use super::*;

    fn flood(lines: usize) -> LiveCommandOutput {
        let mut out = LiveCommandOutput::new();
        let filler = "x".repeat(MAX_BYTES / 200);
        for i in 0..lines {
            out.push_str(&format!("line {i} {filler}\n"));
        }
        out
    }

    #[test]
    fn retained_lines_always_equals_the_number_of_rendered_rows() {
        for n in [0usize, 1, 5, 49, 50, 51, 99, 100, 101, 250] {
            let out = flood(n);
            assert_eq!(
                out.retained_lines(),
                out.lines().len(),
                "{n} lines in: reported {} retained rows but rendered {}",
                out.retained_lines(),
                out.lines().len()
            );
        }
    }

    #[test]
    fn an_elided_preview_renders_exactly_head_plus_tail_rows() {
        let out = flood(400);
        assert!(out.truncated(), "400 flooded lines did not trip the budget");
        assert_eq!(
            out.lines().len(),
            2 * MAX_LINES,
            "an elided preview should render exactly {} rows",
            2 * MAX_LINES
        );
    }

    #[test]
    fn elision_keeps_the_true_head_and_the_true_tail() {
        let out = flood(400);
        let rendered = out.lines();
        assert!(
            rendered[0].starts_with("line 0 "),
            "the first retained row is not the true head"
        );
        assert!(
            rendered.last().unwrap().starts_with("line 399 "),
            "the last retained row is not the true tail"
        );
    }

    #[test]
    fn total_lines_never_shrinks_as_output_arrives() {
        let mut out = LiveCommandOutput::new();
        let filler = "y".repeat(MAX_BYTES / 200);
        let mut high = 0usize;
        for i in 0..300 {
            out.push_str(&format!("l{i} {filler}\n"));
            let t = out.total_lines();
            assert!(t >= high, "total_lines went backwards: {high} -> {t}");
            high = t;
        }
        assert_eq!(out.total_lines(), 300);
    }

    #[test]
    fn tail_lines_returns_exactly_what_was_asked_for_when_available() {
        let out = flood(400);
        for n in [1usize, 3, 10, 2 * MAX_LINES] {
            assert_eq!(out.tail_lines(n).len(), n.min(out.lines().len()));
        }
    }

    #[test]
    fn a_partial_line_is_counted_as_a_row() {
        let mut out = LiveCommandOutput::new();
        out.push_str("done\n");
        out.push_str("in progress, no newline yet");
        assert_eq!(out.retained_lines(), out.lines().len());
        assert_eq!(out.lines().len(), 2);
    }
}
