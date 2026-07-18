// Phase 2+: format_size() and truncate_str_start() — wired when file picker and sidebar use them
#![allow(dead_code)]

pub mod fuzzy;

/// Truncate a UTF-8 string to at most `max_bytes` bytes, ensuring the cut falls
/// on a char boundary so the result is always valid UTF-8.
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
