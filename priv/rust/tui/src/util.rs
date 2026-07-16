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
