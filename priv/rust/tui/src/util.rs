// Phase 2+: format_size() and truncate_str_start() — wired when file picker and sidebar use them
#![allow(dead_code)]

pub mod fuzzy;

/// Fit `s` into at most `max_cols` DISPLAY COLUMNS, appending `…` (1 column) when
/// it does not fit.
///
/// **This is the canonical column-fitter — prefer it for anything laid out against
/// a terminal width.** The two tempting alternatives are both wrong for non-ASCII:
///
///   * [`truncate_str`] takes **bytes**. Comparing `s.len()` to a column budget
///     cuts CJK/emoji text to roughly a third of the space it was given, leaving a
///     large empty gutter (this is why session titles and filenames looked broken).
///   * `.chars().count()` treats every char as 1 column, so wide glyphs OVERFLOW
///     the reserved span and get hard-clipped by the renderer, shoving neighbouring
///     columns off-screen.
///
/// Wide chars are counted at their true 2-column advance, so the result never
/// overflows `max_cols`.
pub fn fit_cols(s: &str, max_cols: usize) -> String {
    use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};
    if UnicodeWidthStr::width(s) <= max_cols {
        return s.to_string();
    }
    if max_cols == 0 {
        return String::new();
    }
    let budget = max_cols - 1; // reserve 1 column for the ellipsis
    let mut out = String::new();
    let mut acc = 0usize;
    for ch in s.chars() {
        let cw = UnicodeWidthChar::width(ch).unwrap_or(0);
        if acc + cw > budget {
            break;
        }
        out.push(ch);
        acc += cw;
    }
    out.push('\u{2026}');
    out
}

/// Display width of `s` in terminal columns (wide glyphs count as 2).
pub fn cols(s: &str) -> usize {
    unicode_width::UnicodeWidthStr::width(s)
}

/// Strip the inline-markdown emphasis markers the model routinely writes into
/// short backend-supplied strings (todo subjects, task titles) that are rendered
/// as PLAIN styled spans rather than through the markdown renderer — otherwise a
/// literal `**Add a new page**` shows up on screen.
///
/// Deliberately conservative: only paired `**`, `__` and backticks are removed.
/// Single `*` / `_` are left alone because they legitimately appear in globs and
/// filenames (`*.tsx`, `snake_case`), where stripping would corrupt the text.
pub fn strip_inline_markdown(s: &str) -> String {
    let mut out = s.replace("**", "").replace("__", "");
    if out.contains('`') {
        out = out.replace('`', "");
    }
    out
}

/// Truncate a UTF-8 string to at most `max_bytes` bytes, ensuring the cut falls
/// on a char boundary so the result is always valid UTF-8.
///
/// **Byte-oriented — do not use for terminal layout.** Use [`fit_cols`] when the
/// budget is a column count.
pub fn truncate_str(s: &str, max_bytes: usize) -> &str {
    if s.len() <= max_bytes {
        return s;
    }
    let mut idx = max_bytes.min(s.len());
    while idx > 0 && !s.is_char_boundary(idx) {
        idx -= 1;
    }
    &s[..idx]
}

/// Format an elapsed duration (in seconds) compactly and identically across the
/// live spinner, agents panel, dashboard, teammate-finished chat lines,
/// background completions, and the turn recap: `45s → 2m 15s → 1h 3m` (spaced,
/// non-zero-padded, trailing zero units dropped — `2m`, `1h`; Claude Code's
/// formatDuration style). This is the ONLY duration formatter — every surface
/// must call it so the spinner→recap transition never renders the same
/// duration two different ways (`2m 15s` vs `2m15s`).
pub fn fmt_elapsed(secs: u64) -> String {
    if secs < 60 {
        format!("{}s", secs)
    } else if secs < 3600 {
        let (m, s) = (secs / 60, secs % 60);
        if s == 0 {
            format!("{}m", m)
        } else {
            format!("{}m {}s", m, s)
        }
    } else {
        let (h, m) = (secs / 3600, (secs % 3600) / 60);
        if m == 0 {
            format!("{}h", h)
        } else {
            format!("{}h {}m", h, m)
        }
    }
}

/// Wall-clock threshold (seconds) above which a turn with zero substantive
/// tool calls still earns a "✻ Worked for …" recap line. Compared with `>=`
/// against whole (floored) seconds, so the first qualifying display is exactly
/// "Worked for 10s" — the same number the user just watched the spinner show.
pub const RECAP_ELAPSED_THRESHOLD_SECS: u64 = 10;

/// True for internal bookkeeping tools that fire automatically (memory
/// persistence / recall, session history search) and therefore must NOT, on
/// their own, trigger the end-of-turn "✻ Worked for …" recap. Without this
/// gate a trivial reply like "Yeah?" still prints "Worked for 3s · 1 tool use"
/// because a memory tool auto-fired. Everything else — shell_execute,
/// file_read/write/edit, web_search/fetch, dir_list, git, … — is substantive,
/// user-visible work and counts toward the recap. The server applies the same
/// filter (Telemetry.internal_tool?/1) before counting; this client copy is
/// defense-in-depth for legacy payloads that only carry the name list.
pub fn is_internal_tool(name: &str) -> bool {
    let n = name.trim().to_ascii_lowercase();
    n.starts_with("memory")
        || matches!(n.as_str(), "session_search" | "session_recall" | "recall")
}

/// Count the substantive (user-visible) tools in a turn's tool list, excluding
/// internal bookkeeping tools (see [`is_internal_tool`]).
pub fn substantive_tool_count<S: AsRef<str>>(tools: &[S]) -> usize {
    tools
        .iter()
        .filter(|t| !is_internal_tool(t.as_ref()))
        .count()
}

/// Take the last `max_bytes` bytes of a UTF-8 string, advancing the start
/// index forward until it lands on a char boundary.
pub fn truncate_str_start(s: &str, max_bytes: usize) -> &str {
    if s.len() <= max_bytes {
        return s;
    }
    let start = s.len() - max_bytes;
    let mut idx = start;
    while idx < s.len() && !s.is_char_boundary(idx) {
        idx += 1;
    }
    &s[idx..]
}

/// Middle-ellipsize a path to at most `max_cols` DISPLAY columns, preserving the
/// final path segment (the filename) — Claude Code `truncatePathMiddle` parity.
/// `src/components/deeply/nested/MyComponent.tsx` -> `src/components/…/MyComponent.tsx`.
/// Width-aware (unicode_width) and never splits a char. Falls back to a tail-only
/// `…name` when the filename alone won't fit.
pub fn ellipsize_path_middle(path: &str, max_cols: usize) -> String {
    use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};
    if path.width() <= max_cols {
        return path.to_string();
    }
    if max_cols <= 1 {
        return "\u{2026}".to_string();
    }
    let (dir, file) = match path.rfind('/') {
        Some(i) => (&path[..i], &path[i..]), // keep the leading '/' with the filename
        None => ("", path),
    };
    let file_w = file.width();
    // Filename alone doesn't fit → keep the tail end, prefixed with an ellipsis.
    if file_w + 1 >= max_cols {
        let budget = max_cols.saturating_sub(1);
        let mut kept = String::new();
        let mut w = 0usize;
        for ch in path.chars().rev() {
            let cw = UnicodeWidthChar::width(ch).unwrap_or(0);
            if w + cw > budget {
                break;
            }
            kept.push(ch);
            w += cw;
        }
        let tail: String = kept.chars().rev().collect();
        return format!("\u{2026}{}", tail);
    }
    let avail_for_dir = max_cols - 1 - file_w; // -1 for the ellipsis
    let mut kept = String::new();
    let mut w = 0usize;
    for ch in dir.chars() {
        let cw = UnicodeWidthChar::width(ch).unwrap_or(0);
        if w + cw > avail_for_dir {
            break;
        }
        kept.push(ch);
        w += cw;
    }
    format!("{}\u{2026}{}", kept, file)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn truncate_str_never_splits_a_char() {
        // "€" is 3 bytes; every non-multiple-of-3 limit lands mid-char.
        let s = "\u{20ac}\u{20ac}\u{20ac}\u{20ac}"; // 12 bytes, 4 chars
        for limit in 0..=13 {
            let out = truncate_str(s, limit);
            assert!(s.starts_with(out));
            assert!(out.len() <= limit.min(s.len()));
            // Result is always valid UTF-8 (guaranteed by &str), and a prefix.
        }
    }

    #[test]
    fn truncate_str_returns_whole_when_under_limit() {
        assert_eq!(truncate_str("abc", 100), "abc");
        assert_eq!(truncate_str("", 0), "");
    }

    #[test]
    fn truncate_str_start_never_splits_a_char() {
        let s = "a\u{20ac}\u{20ac}\u{20ac}\u{20ac}"; // 1 + 12 = 13 bytes
        for limit in 0..=14 {
            let out = truncate_str_start(s, limit);
            assert!(s.ends_with(out));
        }
    }

    #[test]
    fn fmt_elapsed_matches_spinner_style() {
        assert_eq!(fmt_elapsed(0), "0s");
        assert_eq!(fmt_elapsed(45), "45s");
        assert_eq!(fmt_elapsed(60), "1m");
        assert_eq!(fmt_elapsed(135), "2m 15s");
        assert_eq!(fmt_elapsed(3600), "1h");
        assert_eq!(fmt_elapsed(3780), "1h 3m");
        assert_eq!(fmt_elapsed(9180), "2h 33m");
    }

    #[test]
    fn internal_tools_do_not_count_as_substantive() {
        assert!(is_internal_tool("memory_save"));
        assert!(is_internal_tool("memory_recall"));
        assert!(is_internal_tool("session_search"));
        assert!(is_internal_tool(" Session_Search "));
        assert!(!is_internal_tool("shell_execute"));
        assert!(!is_internal_tool("file_read"));
        assert_eq!(
            substantive_tool_count(&["memory_save", "session_search", "shell_execute"]),
            1
        );
    }

    #[test]
    fn truncate_str_handles_large_paste_boundary() {
        // Mirror the paste-cap use: a big multi-byte blob capped at an arbitrary
        // byte limit must never panic and must stay a valid prefix.
        let big = "x".repeat(50) + &"\u{1f600}".repeat(1000); // emoji = 4 bytes
        for limit in [1usize, 49, 50, 51, 100_000, big.len()] {
            let out = truncate_str(&big, limit);
            assert!(big.starts_with(out));
        }
    }
}
