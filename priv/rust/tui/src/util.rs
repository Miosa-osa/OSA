// Phase 2+: format_size() and truncate_str_start() — wired when file picker and sidebar use them
#![allow(dead_code)]

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
    use super::{truncate_str, truncate_str_start};

    #[test]
    fn truncate_str_respects_utf8_boundaries() {
        let s = "ab\u{1f600}cd";

        assert_eq!(truncate_str(s, 3), "ab");
        assert_eq!(truncate_str(s, 6), "ab\u{1f600}");
        assert_eq!(truncate_str(s, s.len()), s);
    }

    #[test]
    fn truncate_str_start_respects_utf8_boundaries() {
        let s = "ab\u{1f600}cd";

        assert_eq!(truncate_str_start(s, 3), "cd");
        assert_eq!(truncate_str_start(s, 6), "\u{1f600}cd");
        assert_eq!(truncate_str_start(s, s.len()), s);
    }
}
