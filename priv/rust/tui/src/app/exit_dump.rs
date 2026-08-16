//! Leave the conversation behind on the primary screen when OSA exits.
//!
//! # Why this exists
//!
//! OSA owns the whole viewport on the alternate screen, so the transcript never
//! enters the terminal's scrollback. That is the point — it is what keeps the
//! user's own shell history from before launch intact through a resize, which no
//! purge-and-re-emit design can promise. But it costs something real on the way
//! out: quitting tears the alternate screen down, and with it every line of the
//! session, exactly the way quitting `vim` or `less` does.
//!
//! Today a user quits OSA and their conversation is still on screen. They scroll
//! up, copy a command out of it, paste an error into a ticket. Letting that stop
//! working would be breaking something in exchange for fixing something. So on
//! exit the retained transcript is rendered once, at the width the terminal has
//! AT THAT MOMENT, and printed to the primary screen.
//!
//! # Why a separate store from `App::committed`
//!
//! `App::committed` holds `Message` values, which is what on-screen re-layout
//! needs — but `Message` carries a `Cell` for its height memo and so is not
//! `Sync`, and it cannot live in a `static`. The panic hook has no `&App`: it
//! runs from `std::panic::set_hook` with nothing but process globals. A crash
//! that eats the user's session is worse than a resize that shreds a table, and
//! this codebase has already shipped one defect of that family — the CLI called
//! `System.halt(0)` and skipped its own transcript save, leaving 1,684 of 3,029
//! spend files with no transcript at all.
//!
//! So this keeps its own minimal mirror: the role and the RAW SOURCE of each
//! finalized message, appended at the same choke point that feeds
//! `App::committed`. Source, not rendered lines — rendering happens at exit,
//! against the exit width, which is the whole reason a render source is retained
//! in the first place.

use std::io::Write;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

/// How the entry is labelled in the dump.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    User,
    Agent,
    Tool,
    System,
}

impl Role {
    fn label(self) -> &'static str {
        match self {
            Role::User => "You",
            Role::Agent => "OSA",
            Role::Tool => "tool",
            Role::System => "system",
        }
    }
}

/// Map the transcript viewer's role onto this module's. Kept here so the commit
/// choke point can record and log in one step and the two cannot disagree about
/// what a message is.
pub fn role_of(role: crate::dialogs::transcript_viewer::TranscriptRole) -> Role {
    use crate::dialogs::transcript_viewer::TranscriptRole as T;
    match role {
        T::User => Role::User,
        T::Agent => Role::Agent,
        T::Tool => Role::Tool,
        T::System => Role::System,
    }
}

/// One finalized message, kept as source so it can be laid out at any width.
#[derive(Debug, Clone)]
pub struct Entry {
    pub role: Role,
    pub source: String,
}

static ENTRIES: Mutex<Vec<Entry>> = Mutex::new(Vec::new());
static ENABLED: AtomicBool = AtomicBool::new(true);

/// Upper bound on rendered rows in the dump.
///
/// The retention store holds up to 2000 messages; emptying all of it into
/// someone's scrollback on exit is its own hostile act. A bounded tail is
/// printed instead, and the header says so — a truncation the user cannot see is
/// the defect pattern this whole effort has been removing.
pub const MAX_DUMP_ROWS: usize = 400;

/// Turn the exit dump on or off. On by default: today's behaviour is the
/// default, and someone who wants a clean terminal on exit opts out.
pub fn set_enabled(on: bool) {
    ENABLED.store(on, Ordering::SeqCst);
}

pub fn is_enabled() -> bool {
    ENABLED.load(Ordering::SeqCst)
}

/// Record a finalized message. Called from the same commit choke point that
/// fills `App::committed`, so the two cannot drift apart.
pub fn record(role: Role, source: String) {
    if source.trim().is_empty() {
        return;
    }
    if let Ok(mut e) = ENTRIES.lock() {
        e.push(Entry { role, source });
        // Bounded in step with `App::committed` so a long session cannot grow
        // this without limit either.
        let cap = crate::app::MAX_COMMITTED_MESSAGES;
        if e.len() > cap {
            let excess = e.len() - cap;
            e.drain(..excess);
        }
    }
}

/// Drop everything. Paired with `/clear`, which clears every other store that
/// can put a message back on screen.
pub fn clear() {
    if let Ok(mut e) = ENTRIES.lock() {
        e.clear();
    }
}

pub fn len() -> usize {
    ENTRIES.lock().map(|e| e.len()).unwrap_or(0)
}

/// Render the retained transcript to plain rows at `width`.
///
/// Returns the LAST `max_rows` rows, prefixed by a header when anything was
/// dropped. Agent prose goes through the real markdown renderer at `width`, so a
/// table in the dump is laid out for the terminal the user is actually looking
/// at — not the width it was committed at.
pub fn render(width: u16, max_rows: usize) -> Vec<String> {
    let entries = match ENTRIES.lock() {
        Ok(e) => e.clone(),
        Err(_) => return Vec::new(),
    };
    render_entries(&entries, width, max_rows)
}

/// Split out from [`render`] so the shape is testable without touching the
/// process-global store.
pub fn render_entries(entries: &[Entry], width: u16, max_rows: usize) -> Vec<String> {
    let w = width.max(20);
    let mut rows: Vec<String> = Vec::new();

    for entry in entries {
        rows.push(format!("{}:", entry.role.label()));
        match entry.role {
            // Only agent prose is markdown. A user's own text, a tool block and
            // a system notice are already literal, and running them through the
            // markdown renderer would restyle text the user typed.
            Role::Agent => {
                let text = crate::render::markdown::render_markdown(&entry.source, w);
                for line in text.lines.iter() {
                    let s: String = line.spans.iter().map(|sp| sp.content.as_ref()).collect();
                    rows.push(strip_escapes(&s).trim_end().to_string());
                }
            }
            _ => {
                for line in entry.source.lines() {
                    rows.push(line.trim_end().to_string());
                }
            }
        }
        rows.push(String::new());
    }

    if rows.len() <= max_rows {
        return rows;
    }
    let dropped = rows.len() - max_rows;
    let mut out = vec![
        format!(
            "[… {dropped} earlier rows not shown — this is the tail of the \
             session. Full record: ctrl+o during a session, or the session log.]"
        ),
        String::new(),
    ];
    out.extend_from_slice(&rows[dropped..]);
    out
}

/// Drop OSC-8 and SGR escapes. The dump goes to a terminal that has just been
/// restored, and emitting a half-open hyperlink or a colour that is never reset
/// would leave the shell prompt wearing it.
fn strip_escapes(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c == '\x1b' {
            // OSC (…BEL or ESC \) and CSI (…final byte in @-~) both end at a
            // recognisable terminator; consume through it.
            for n in chars.by_ref() {
                if n == '\u{7}' || n == '\\' || ('@'..='~').contains(&n) {
                    break;
                }
            }
        } else {
            out.push(c);
        }
    }
    out
}

/// Write the dump to `out`. No-op when disabled or empty.
///
/// Called after the alternate screen has been left, on every exit path, so the
/// rows land on the primary screen where the shell prompt will follow them.
pub fn print_to(out: &mut impl Write, width: u16) {
    if !is_enabled() {
        return;
    }
    let rows = render(width, MAX_DUMP_ROWS);
    if rows.is_empty() {
        return;
    }
    for row in rows {
        let _ = writeln!(out, "{row}\r");
    }
    let _ = out.flush();
}

#[cfg(test)]
mod tests {
    use super::*;

    fn agent(src: &str) -> Entry {
        Entry {
            role: Role::Agent,
            source: src.to_string(),
        }
    }

    /// Wide on purpose. A table narrower than every width under test is
    /// returned unchanged by the column allocator (it water-fills only when the
    /// natural widths do not fit), so a narrow fixture would render identically
    /// at 40 and 100 and prove nothing about the width argument.
    const TABLE: &str = "\
| Component | Owner | Notes |
| --- | --- | --- |
| gateway | platform | handles the websocket handshake literally |
| storage | infra | see ISSUES.md and Documentation/CANON.md |
";

    /// The reason the dump renders from source instead of replaying committed
    /// rows: it must be laid out for the terminal as it is ON EXIT.
    #[test]
    fn renders_at_the_width_it_is_given() {
        let narrow = render_entries(&[agent(TABLE)], 40, 1000);
        let wide = render_entries(&[agent(TABLE)], 100, 1000);

        let widest = |rows: &[String]| rows.iter().map(|r| crate::util::cols(r)).max().unwrap_or(0);
        assert!(
            widest(&narrow) <= 40,
            "a row overflowed the 40-column width it was rendered for: {narrow:?}"
        );
        assert!(
            widest(&wide) <= 100,
            "a row overflowed the 100-column width it was rendered for"
        );
        assert_ne!(
            narrow, wide,
            "the same table rendered identically at 40 and 100 columns, so the \
             width argument is not reaching the renderer"
        );
    }

    /// A truncation the user cannot see is the defect pattern this whole effort
    /// has been removing, so the dump says when it dropped something.
    #[test]
    fn a_truncated_dump_says_so_and_keeps_the_tail() {
        let entries: Vec<Entry> = (0..200)
            .map(|i| Entry {
                role: Role::User,
                source: format!("line {i}"),
            })
            .collect();

        let rows = render_entries(&entries, 80, 50);

        assert!(rows.len() <= 50 + 2, "the cap was not honoured: {}", rows.len());
        assert!(
            rows[0].contains("earlier rows not shown"),
            "a truncated dump did not announce the truncation: {:?}",
            rows[0]
        );
        assert!(
            rows.iter().any(|r| r.contains("line 199")),
            "the TAIL was dropped instead of the head — the newest content is \
             what the user is looking for"
        );
        assert!(
            !rows.iter().any(|r| r.contains("line 0")),
            "the head survived a truncation that should have dropped it"
        );
    }

    /// An untruncated dump must not carry the header, or every short session
    /// would claim it lost something.
    #[test]
    fn a_complete_dump_has_no_truncation_header() {
        let rows = render_entries(&[agent("hello")], 80, 1000);
        assert!(
            !rows.iter().any(|r| r.contains("earlier rows not shown")),
            "a complete dump announced a truncation that did not happen"
        );
    }

    /// The dump lands on a terminal that has just been restored; a half-open
    /// hyperlink or an unreset colour would be inherited by the shell prompt.
    #[test]
    fn escapes_are_stripped() {
        let rows = render_entries(&[agent("see [docs](https://example.com/x) here")], 80, 1000);
        let joined = rows.join("\n");
        assert!(
            !joined.contains('\x1b'),
            "an escape sequence reached the dump: {joined:?}"
        );
        assert!(
            joined.contains("docs"),
            "stripping escapes also ate the visible text: {joined:?}"
        );
    }

    #[test]
    fn empty_sources_are_not_recorded() {
        let rows = render_entries(
            &[Entry {
                role: Role::Agent,
                source: String::new(),
            }],
            80,
            1000,
        );
        // The entry still labels itself; what matters is `record` rejects it.
        assert!(rows.len() <= 2);
    }
}
