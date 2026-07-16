// Phase 2+: fuzzy ranking helpers — used by slash-command and @-file completions.
#![allow(dead_code)]

//! Lightweight fuzzy subsequence matching with word-boundary / camelCase
//! scoring. A query matches a candidate when its characters appear, in order,
//! as a (case-insensitive) subsequence of the candidate. Matches are scored so
//! that hits at word boundaries (`/ \ _ - . : space`), camelCase humps, and
//! consecutive runs rank above scattered ones — mirroring the feel of fzf.

/// Bonus for a character that starts a new "word" (boundary or camelCase hump).
const BOUNDARY_BONUS: i32 = 12;
/// Bonus for a camelCase hump (lower char immediately followed by upper).
const CAMEL_BONUS: i32 = 10;
/// Base score for any matched character.
const MATCH_SCORE: i32 = 2;
/// Extra score that grows with each additional consecutive matched char.
const CONSECUTIVE_BONUS: i32 = 6;
/// Small reward for an exact-case match (helps stable tie-breaks).
const CASE_BONUS: i32 = 1;
/// Penalty per leading unmatched char before the first hit (prefer early hits).
const LEADING_PENALTY: i32 = 3;
/// Max leading penalty applied, so very long paths aren't unfairly buried.
const MAX_LEADING_PENALTY: i32 = 30;

fn eq_ci(a: char, b: char) -> bool {
    a == b || a.to_ascii_lowercase() == b.to_ascii_lowercase()
}

fn is_boundary(prev: char) -> bool {
    matches!(prev, '/' | '\\' | '_' | '-' | '.' | ':' | ' ' | '@')
}

/// Score `candidate` against `query`. Returns `None` when `query` is not a
/// subsequence of `candidate`. An empty query always matches with score 0.
/// Higher is better.
pub fn score(candidate: &str, query: &str) -> Option<i32> {
    if query.is_empty() {
        return Some(0);
    }
    let cand: Vec<char> = candidate.chars().collect();
    let q: Vec<char> = query.chars().collect();

    let mut qi = 0usize;
    let mut total = 0i32;
    let mut run = 0i32; // length of the current consecutive-match run
    let mut prev_matched = false;
    let mut first_hit: Option<usize> = None;

    for (ci, &c) in cand.iter().enumerate() {
        if qi >= q.len() {
            break;
        }
        if eq_ci(c, q[qi]) {
            if first_hit.is_none() {
                first_hit = Some(ci);
            }
            let mut bonus = MATCH_SCORE;

            let at_boundary = ci == 0 || is_boundary(cand[ci - 1]);
            let camel_hump = ci > 0 && cand[ci - 1].is_lowercase() && c.is_uppercase();
            if at_boundary {
                bonus += BOUNDARY_BONUS;
            } else if camel_hump {
                bonus += CAMEL_BONUS;
            }
            if c == q[qi] {
                bonus += CASE_BONUS;
            }
            if prev_matched {
                run += 1;
                bonus += run * CONSECUTIVE_BONUS;
            } else {
                run = 0;
            }

            total += bonus;
            qi += 1;
            prev_matched = true;
        } else {
            prev_matched = false;
        }
    }

    if qi != q.len() {
        return None;
    }

    if let Some(fi) = first_hit {
        total -= (fi as i32 * LEADING_PENALTY).min(MAX_LEADING_PENALTY);
    }
    Some(total)
}

/// Convenience predicate: does `candidate` fuzzy-match `query`?
pub fn is_match(candidate: &str, query: &str) -> bool {
    score(candidate, query).is_some()
}

/// Rank `items` against `query`, returning indices of matching items sorted
/// best-first. Ties break by shorter candidate, then original order (stable).
/// An empty query returns every index in original order.
pub fn rank<T, F>(items: &[T], query: &str, key: F) -> Vec<usize>
where
    F: Fn(&T) -> &str,
{
    let mut scored: Vec<(usize, i32, usize)> = items
        .iter()
        .enumerate()
        .filter_map(|(i, item)| {
            let cand = key(item);
            score(cand, query).map(|s| (i, s, cand.chars().count()))
        })
        .collect();

    // Higher score first; on tie, shorter candidate; on tie, original order.
    scored.sort_by(|a, b| {
        b.1.cmp(&a.1)
            .then_with(|| a.2.cmp(&b.2))
            .then_with(|| a.0.cmp(&b.0))
    });
    scored.into_iter().map(|(i, _, _)| i).collect()
}

/// Rank a slice of strings against `query`, returning the matching strings
/// cloned in best-first order.
pub fn rank_strings(items: &[String], query: &str) -> Vec<String> {
    rank(items, query, |s| s.as_str())
        .into_iter()
        .map(|i| items[i].clone())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_query_matches_everything() {
        assert_eq!(score("anything", ""), Some(0));
        assert!(is_match("anything", ""));
    }

    #[test]
    fn non_subsequence_is_none() {
        assert_eq!(score("model", "xyz"), None);
        assert_eq!(score("abc", "abcd"), None);
    }

    #[test]
    fn subsequence_matches() {
        assert!(is_match("compact", "cmp"));
        assert!(is_match("src/util/fuzzy.rs", "fuzzy"));
    }

    #[test]
    fn boundary_beats_scattered() {
        // "sc" as a prefix should outrank "sc" split across a longer word.
        let strong = score("scroll", "sc").unwrap();
        let weak = score("discloses", "sc").unwrap();
        assert!(strong > weak, "{strong} !> {weak}");
    }

    #[test]
    fn camel_case_hump_scores() {
        assert!(is_match("getUserName", "gun"));
        let humped = score("getUserName", "gun").unwrap();
        let flat = score("gunnery", "gun").unwrap();
        // Consecutive prefix run should still win, but camel path must match.
        assert!(humped > 0 && flat > 0);
    }

    #[test]
    fn rank_orders_best_first() {
        let items = vec![
            "clear".to_string(),
            "compact".to_string(),
            "context".to_string(),
        ];
        let out = rank_strings(&items, "co");
        // "clear" has no 'o' after 'c' → excluded; a "co…" prefix ranks first.
        assert!(!out.iter().any(|s| s == "clear"));
        assert!(matches!(out.first().map(|s| s.as_str()), Some("compact") | Some("context")));
    }
}
