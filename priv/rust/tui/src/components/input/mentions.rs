//! Composer @-mention structured attachments + frecency recall.
//!
//! Pure, table-tested building blocks for three composer sub-layers:
//!   * U-T1 — an `@`-mention is a *typed* attachment the submit path can carry,
//!     not just inserted text. `@file`, `@file#L10-20` (line range) and
//!     `@agent` each resolve to an [`Attachment`]. Mirrors Claude Code's
//!     `parseAtMentions` (a mention is a word-boundary `@` token) and grok's
//!     file-reference resolver.
//!   * U-T6 — [`Frecency`], a recency+frequency ranker for the `@`-file and
//!     `/`-command recall popups (Firefox/VS Code "frecency"; grok recall).
//!   * U-T30 — [`MentionKind`] carries the popup type glyph (file / dir /
//!     agent) so the dropdown distinguishes candidate kinds at a glance.
//!
//! Everything here is deterministic and side-effect free (the `Frecency` tick
//! is injected/advanced explicitly) so it can be unit-tested without an `App`.
#![allow(dead_code)]

use std::collections::HashMap;

/// The type category of an `@`-mention candidate — drives the popup glyph
/// (U-T30) and how a token resolves to an [`Attachment`] (U-T1).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MentionKind {
    File,
    Dir,
    Agent,
}

impl MentionKind {
    /// A compact type glyph shown left of a popup entry. Emoji are used so the
    /// three kinds are instantly distinguishable; the popup budgets width with
    /// `unicode_width`, so their 2-column advance is accounted for.
    pub fn glyph(self) -> &'static str {
        match self {
            MentionKind::File => "\u{1f4c4}",  // 📄 page
            MentionKind::Dir => "\u{1f4c1}",   // 📁 folder
            MentionKind::Agent => "\u{1f916}", // 🤖 robot
        }
    }
}

/// A resolved `@`-popup candidate: the text inserted after the `@`
/// (`insert`, e.g. `src/main.rs` or `src/` for a dir or an agent name) plus its
/// [`MentionKind`] for the glyph.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Candidate {
    pub insert: String,
    pub kind: MentionKind,
}

impl Candidate {
    pub fn file(insert: impl Into<String>) -> Self {
        let insert = insert.into();
        let kind = if insert.ends_with('/') {
            MentionKind::Dir
        } else {
            MentionKind::File
        };
        Self { insert, kind }
    }

    pub fn agent(name: impl Into<String>) -> Self {
        Self { insert: name.into(), kind: MentionKind::Agent }
    }
}

/// A `#L<start>[-<end>]` line range attached to a file mention.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LineRange {
    pub start: u32,
    pub end: Option<u32>,
}

/// A typed attachment resolved from an `@`-mention token, ready for the submit
/// path to turn into a context reference / content block.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Attachment {
    /// `@path` or `@path#L10-20`.
    File { path: String, range: Option<LineRange> },
    /// `@agent-name` where the token matched a known agent.
    Agent { name: String },
}

/// How a submitted line should be routed (U-T4). The composer computes this at
/// submit time from the first char so the dispatch layer can branch on a typed
/// value instead of re-sniffing the string.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SubmitKind {
    /// Ordinary prompt sent to the model.
    Prompt,
    /// `!cmd` — run as a shell command (own history bucket).
    Shell,
    /// `#note` — quick-capture to memory.
    Memory,
}

impl SubmitKind {
    /// Classify a (non-cleared) composer line by its leading sigil.
    pub fn of(line: &str) -> SubmitKind {
        match line.as_bytes().first() {
            Some(b'!') => SubmitKind::Shell,
            Some(b'#') => SubmitKind::Memory,
            _ => SubmitKind::Prompt,
        }
    }
}

/// Split an `@`-token body (the text after `@`, no surrounding whitespace) into
/// its path and an optional `#L<start>[-<end>]` line range.
///
/// `src/main.rs#L10-20` → (`src/main.rs`, `10..=20`); `a.rs#L5` → (`a.rs`, `5`).
/// A malformed range (`x#Lfoo`, `x#L`) is NOT split — the whole body is treated
/// as the path so nothing is silently dropped, matching CC's lenient parser.
pub fn split_line_range(body: &str) -> (&str, Option<LineRange>) {
    let Some(hash) = body.rfind("#L") else {
        return (body, None);
    };
    let (path, tail) = (&body[..hash], &body[hash + 2..]);
    if path.is_empty() {
        return (body, None);
    }
    let (start_s, end_s) = match tail.split_once('-') {
        Some((a, b)) => (a, Some(b)),
        None => (tail, None),
    };
    let Ok(start) = start_s.parse::<u32>() else {
        return (body, None);
    };
    let end = match end_s {
        None => None,
        Some(b) => match b.parse::<u32>() {
            Ok(e) => Some(e),
            Err(_) => return (body, None), // trailing garbage → keep as path
        },
    };
    (path, Some(LineRange { start, end }))
}

/// True when the char preceding an `@` makes it a mention boundary: start of
/// line or after whitespace / an opening bracket. This is what keeps
/// `user@host` from being read as a mention while `see @file` is one.
fn is_mention_boundary(prev: Option<char>) -> bool {
    match prev {
        None => true,
        Some(c) => c.is_whitespace() || c == '(' || c == '[',
    }
}

/// Extract every structured [`Attachment`] from a submitted `text`. A mention
/// is a word-boundary `@` followed by non-whitespace, non-`@` body. A body
/// whose path matches (case-insensitively) a known agent name resolves to
/// [`Attachment::Agent`]; anything else is a file, with any `#L` range parsed.
pub fn parse_mentions(text: &str, agents: &[String]) -> Vec<Attachment> {
    let mut out = Vec::new();
    let bytes: Vec<char> = text.chars().collect();
    let mut i = 0;
    let mut prev: Option<char> = None;
    while i < bytes.len() {
        let c = bytes[i];
        if c == '@' && is_mention_boundary(prev) {
            // Read the token body up to the next whitespace.
            let mut j = i + 1;
            while j < bytes.len() && !bytes[j].is_whitespace() {
                j += 1;
            }
            let body: String = bytes[i + 1..j].iter().collect();
            // Trim trailing prose punctuation so `(@f.rs)` / `@a.rs,` resolve to
            // the bare path (CC's mention tokenizer strips closing punctuation).
            // A trailing '.' is kept so file extensions survive.
            let body = body.trim_end_matches([')', ']', '}', ',', ';', ':']);
            // Ignore bare `@` and `@@…` (no real body / a second sigil).
            if !body.is_empty() && !body.starts_with('@') {
                let (path, range) = split_line_range(body);
                if agents.iter().any(|a| a.eq_ignore_ascii_case(path)) {
                    out.push(Attachment::Agent { name: path.to_string() });
                } else {
                    out.push(Attachment::File { path: path.to_string(), range });
                }
            }
            prev = bytes.get(j - 1).copied();
            i = j;
            continue;
        }
        prev = Some(c);
        i += 1;
    }
    out
}

/// A recency+frequency ("frecency") ranker for composer recall popups (U-T6).
///
/// Each key tracks a hit count and the tick of its last use. [`boost`] blends
/// them — `count / (1 + age)` — so an item used *often and recently* outranks
/// one used once long ago, and a never-seen key scores 0. The tick advances on
/// every [`record`], so "age" is measured in intervening selections, not wall
/// time (deterministic + testable).
///
/// [`boost`]: Frecency::boost
/// [`record`]: Frecency::record
#[derive(Default)]
pub struct Frecency {
    hits: HashMap<String, (u32, u64)>, // key -> (count, last_tick)
    tick: u64,
}

impl Frecency {
    pub fn new() -> Self {
        Self::default()
    }

    /// Note a use of `key`, advancing the clock.
    pub fn record(&mut self, key: &str) {
        self.tick += 1;
        let e = self.hits.entry(key.to_string()).or_insert((0, 0));
        e.0 += 1;
        e.1 = self.tick;
    }

    /// Frecency score for `key` at the current tick (0.0 if never recorded).
    pub fn boost(&self, key: &str) -> f64 {
        match self.hits.get(key) {
            Some(&(count, last)) => {
                let age = self.tick.saturating_sub(last) as f64;
                count as f64 / (1.0 + age)
            }
            None => 0.0,
        }
    }

    /// Stable-sort `items` best-first purely by frecency (used when a popup has
    /// no fuzzy filter yet, so recents float to the top). Ties keep input order.
    pub fn rank<'a, T, F>(&self, items: &'a [T], key: F) -> Vec<&'a T>
    where
        F: Fn(&T) -> &str,
    {
        let mut idx: Vec<usize> = (0..items.len()).collect();
        idx.sort_by(|&a, &b| {
            let (ka, kb) = (key(&items[a]), key(&items[b]));
            self.boost(kb)
                .partial_cmp(&self.boost(ka))
                .unwrap_or(std::cmp::Ordering::Equal)
                .then(a.cmp(&b))
        });
        idx.into_iter().map(|i| &items[i]).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn split_range_start_only() {
        let (p, r) = split_line_range("src/main.rs#L5");
        assert_eq!(p, "src/main.rs");
        assert_eq!(r, Some(LineRange { start: 5, end: None }));
    }

    #[test]
    fn split_range_start_end() {
        let (p, r) = split_line_range("a/b.rs#L10-20");
        assert_eq!(p, "a/b.rs");
        assert_eq!(r, Some(LineRange { start: 10, end: Some(20) }));
    }

    #[test]
    fn split_range_none_and_malformed_kept_as_path() {
        assert_eq!(split_line_range("plain.rs"), ("plain.rs", None));
        // Malformed range is not split — whole thing stays the path.
        assert_eq!(split_line_range("x.rs#Lfoo").1, None);
        assert_eq!(split_line_range("x.rs#L").1, None);
        assert_eq!(split_line_range("x.rs#L5-bad").1, None);
    }

    #[test]
    fn split_range_uses_last_hashL() {
        // A '#L' inside the path (rare) must not eat the trailing real range.
        let (p, r) = split_line_range("weird#Lname.rs#L3-4");
        assert_eq!(p, "weird#Lname.rs");
        assert_eq!(r, Some(LineRange { start: 3, end: Some(4) }));
    }

    #[test]
    fn parse_file_agent_and_range() {
        let agents = vec!["debugger".to_string(), "code-reviewer".to_string()];
        let got = parse_mentions("look at @src/main.rs#L1-9 then ask @debugger", &agents);
        assert_eq!(
            got,
            vec![
                Attachment::File {
                    path: "src/main.rs".into(),
                    range: Some(LineRange { start: 1, end: Some(9) }),
                },
                Attachment::Agent { name: "debugger".into() },
            ]
        );
    }

    #[test]
    fn parse_ignores_email_and_bare_and_double_at() {
        // user@host is not a boundary mention; bare @ and @@ are skipped.
        let got = parse_mentions("mail user@host.com and @ and @@x and (@f.rs)", &[]);
        assert_eq!(
            got,
            vec![Attachment::File { path: "f.rs".into(), range: None }]
        );
    }

    #[test]
    fn parse_agent_is_case_insensitive() {
        let agents = vec!["Debugger".to_string()];
        let got = parse_mentions("@debugger", &agents);
        assert_eq!(got, vec![Attachment::Agent { name: "debugger".into() }]);
    }

    #[test]
    fn submit_kind_classifies_sigils() {
        assert_eq!(SubmitKind::of("!ls -la"), SubmitKind::Shell);
        assert_eq!(SubmitKind::of("#note this"), SubmitKind::Memory);
        assert_eq!(SubmitKind::of("hello"), SubmitKind::Prompt);
        assert_eq!(SubmitKind::of(""), SubmitKind::Prompt);
    }

    #[test]
    fn candidate_kind_from_shape() {
        assert_eq!(Candidate::file("src/").kind, MentionKind::Dir);
        assert_eq!(Candidate::file("src/x.rs").kind, MentionKind::File);
        assert_eq!(Candidate::agent("debugger").kind, MentionKind::Agent);
    }

    #[test]
    fn frecency_recent_and_frequent_wins() {
        let mut f = Frecency::new();
        // "b" used more and last → must outrank "a".
        f.record("a");
        f.record("b");
        f.record("b");
        assert!(f.boost("b") > f.boost("a"));
        assert_eq!(f.boost("never"), 0.0);
    }

    #[test]
    fn frecency_decays_with_age() {
        let mut f = Frecency::new();
        f.record("old");
        let fresh = f.boost("old");
        for _ in 0..10 {
            f.record("other");
        }
        // Same count, but 10 ticks older → lower score.
        assert!(f.boost("old") < fresh);
    }

    #[test]
    fn frecency_rank_orders_best_first() {
        let mut f = Frecency::new();
        f.record("x");
        f.record("y");
        f.record("y");
        let items = vec!["x".to_string(), "y".to_string(), "z".to_string()];
        let ranked: Vec<&str> = f.rank(&items, |s| s.as_str()).iter().map(|s| s.as_str()).collect();
        assert_eq!(ranked, vec!["y", "x", "z"]);
    }
}
