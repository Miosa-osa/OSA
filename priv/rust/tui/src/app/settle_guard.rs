//! Client-side mirror of the backend's **output guardrails**, used to decide
//! which completed markdown blocks may be committed to the terminal's native
//! scrollback *before* the turn's terminal `agent_response` arrives.
//!
//! # Why a mirror is needed
//!
//! `AssistantStream::finalize` makes the backend's final text **replace** the
//! streamed accumulation, because the backend post-processes the text it
//! commits to the transcript. Text already handed to `terminal.insert_before`
//! lives in the emulator's own scrollback and can never be mutated or
//! retracted, so an early commit is only sound for a region the post-processing
//! provably cannot touch.
//!
//! Exactly two transforms run, both in `OptimalSystemAgent.Agent.Loop`
//! (`loop.ex`, right after `ReactLoop.run/1` returns), and both only on the
//! **final generation's text** — every earlier generation and every
//! tool-interleaved flush already reaches scrollback unscrubbed today, so this
//! is the one region where the question arises at all.
//!
//! ### 1. `maybe_strip_dead_phrases` → `Guardrails.strip_dead_phrases/1`
//!
//! Fires iff the response contains any of [`DEAD_PHRASES`] (case-insensitive
//! substring). It then
//!
//! * replaces every `\b`-bounded, case-insensitive occurrence of each phrase
//!   with its (short, usually empty) replacement, and
//! * normalises whitespace: `[ \t]{2,}` → one space, whitespace-only lines →
//!   empty, `\n{3,}` → `\n\n`, then trims both ends.
//!
//! Both parts are **local**. No dead phrase contains a newline and a settle
//! boundary only ever sits after a blank line, so a phrase can never straddle
//! two blocks: a region committed while no dead phrase has yet been seen
//! anywhere in the accumulation can never itself be rewritten by the
//! replacement pass. The whitespace pass *can* still reach backwards into it
//! (it runs over the whole response once any phrase, anywhere, triggers it),
//! which is why the finalize-time reconciliation compares
//! whitespace-insensitively — see [`common_prefix_modulo_whitespace`].
//!
//! ### 2. `maybe_scrub_prompt_leak` → `Guardrails.response_contains_prompt_leak?/1`
//!
//! Fires iff **two or more distinct** [`LEAK_FINGERPRINTS`] appear in the
//! response, and then discards the response entirely, replacing it with a fixed
//! refusal. This one is *not* local and is only decidable once the whole
//! response exists, so it cannot be mirrored exactly while streaming.
//!
//! It is instead handled by a **sticky gate**: early committing stops for good
//! the moment the accumulation contains its *first* fingerprint
//! ([`contains_leak_fingerprint`]). Everything committed early therefore
//! contains **zero** fingerprints — and the guardrail's own documented standard
//! is that "a single phrase can appear incidentally in normal conversation; two
//! together indicate a leak". Text with zero fingerprints is, by that
//! detector's own definition, not system-prompt content. The residual is
//! cosmetic rather than a leak: on a real trip the user sees the
//! (fingerprint-free) prose that had already been committed, followed by the
//! refusal, instead of the refusal alone.
//!
//! Both phrase lists are duplicated from
//! `lib/optimal_system_agent/agent/loop/guardrails.ex`, where they are static
//! module attributes.

/// Fingerprint phrases from `Guardrails.@system_prompt_fingerprints`.
/// Matching is a lowercased substring test, exactly as on the Elixir side.
pub(crate) const LEAK_FINGERPRINTS: [&str; 15] = [
    "signal theory",
    "optimal system agent",
    "tool usage policy",
    "explore before you act",
    "mandatory for coding tasks",
    "tool routing rules",
    "signal processing loop",
    "weight calibration",
    "doom loop detection",
    "mandatory verification",
    "tool definitions",
    "banned phrases",
    "code completeness",
    "orchestration",
    "existence denial",
];

/// Phrases from `Guardrails.@dead_phrases` (the keys only — the replacement
/// text is irrelevant here, because a message is barred from settling anything
/// further the moment any of them appears).
pub(crate) const DEAD_PHRASES: [&str; 10] = [
    "i apologize for the frustration",
    "i apologize for any inconvenience",
    "thank you for your patience",
    "i will now proceed to",
    "i'd be happy to help",
    "is there anything else",
    "i'm just a",
    "certainly!",
    "absolutely!",
    "as an ai",
];

/// True when `text` contains at least one prompt-leak fingerprint.
///
/// Deliberately `>= 1`, not the backend's `>= 2`: this is the *gate*, and it
/// has to close before the second fingerprint can ever arrive.
pub(crate) fn contains_leak_fingerprint(text: &str) -> bool {
    let lowered = text.to_lowercase();
    LEAK_FINGERPRINTS.iter().any(|p| lowered.contains(p))
}

/// True when `text` contains any banned dead phrase.
pub(crate) fn contains_dead_phrase(text: &str) -> bool {
    let lowered = text.to_lowercase();
    DEAD_PHRASES.iter().any(|p| lowered.contains(p))
}

/// True when the accumulation so far still permits committing completed blocks
/// early. Callers must treat a `false` as **sticky** for the rest of the
/// message: both risks are about text that arrives *later*, so re-opening the
/// gate would defeat it.
pub(crate) fn may_settle(accumulated: &str) -> bool {
    !contains_leak_fingerprint(accumulated) && !contains_dead_phrase(accumulated)
}

/// Length of the longest prefix of `haystack` that equals `needle` **modulo the
/// whitespace normalisation** `strip_dead_phrases` performs, or `None` when
/// `needle` is not such a prefix at all.
///
/// The equivalence implemented here is exactly the normaliser's:
///
/// * any run of spaces/tabs is interchangeable with any other run (`[ \t]{2,}`
///   collapses to one space, so only "some horizontal space" is preserved), and
/// * any run of two-or-more newlines is interchangeable with any other such run
///   (`\n{3,}` collapses to `\n\n`), while a *single* newline is significant.
///
/// This is what lets already-committed text still be recognised inside the
/// final even when a dead phrase arriving in the tail caused the whole response
/// to be re-whitespaced behind it.
pub(crate) fn common_prefix_modulo_whitespace(haystack: &str, needle: &str) -> Option<usize> {
    let (h, n) = (haystack.as_bytes(), needle.as_bytes());
    let (mut i, mut j) = (0usize, 0usize);

    // Length of the run of `\n` (with interleaved spaces/tabs ignored) starting
    // at `k`, and the offset just past it.
    fn newline_run(b: &[u8], mut k: usize) -> Option<(usize, usize)> {
        let start = k;
        let mut count = 0usize;
        while k < b.len() && matches!(b[k], b'\n' | b' ' | b'\t' | b'\r') {
            if b[k] == b'\n' {
                count += 1;
            }
            k += 1;
        }
        if count == 0 || k == start {
            None
        } else {
            Some((count, k))
        }
    }

    while j < n.len() {
        if i >= h.len() {
            return None;
        }
        // Newline runs first — they subsume any horizontal space around them.
        if n[j] == b'\n' || h[i] == b'\n' {
            match (newline_run(h, i), newline_run(n, j)) {
                (Some((hc, hi)), Some((nc, nj))) => {
                    // 1 vs 1 is fine; >=2 vs >=2 is fine; 1 vs >=2 is not.
                    if (hc >= 2) != (nc >= 2) {
                        return None;
                    }
                    i = hi;
                    j = nj;
                    continue;
                }
                _ => return None,
            }
        }
        if matches!(n[j], b' ' | b'\t') && matches!(h[i], b' ' | b'\t') {
            while i < h.len() && matches!(h[i], b' ' | b'\t') {
                i += 1;
            }
            while j < n.len() && matches!(n[j], b' ' | b'\t') {
                j += 1;
            }
            continue;
        }
        if h[i] != n[j] {
            return None;
        }
        i += 1;
        j += 1;
    }
    Some(i)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn one_fingerprint_closes_the_gate() {
        // The backend needs two to scrub; the gate must close on the first, so
        // nothing containing even one is ever committed early.
        assert!(contains_leak_fingerprint(
            "the orchestration layer picks a provider"
        ));
        assert!(contains_leak_fingerprint("SIGNAL THEORY"), "case-insensitive");
        assert!(!contains_leak_fingerprint(
            "a perfectly ordinary paragraph about cats"
        ));
        assert!(!may_settle("we can discuss orchestration here"));
    }

    #[test]
    fn dead_phrases_are_detected_case_insensitively() {
        assert!(contains_dead_phrase("Certainly! Here is the answer."));
        assert!(contains_dead_phrase("thank you for your patience"));
        assert!(!contains_dead_phrase("Here is the answer."));
        assert!(!may_settle("Certainly! Here is the answer."));
        assert!(may_settle("Here is the answer."));
    }

    #[test]
    fn ordinary_prose_and_code_may_settle() {
        // The common case — including indented code, which the whitespace
        // normaliser WOULD rewrite but only if a dead phrase triggers it.
        assert!(may_settle(
            "Here is the fix.\n\n```rust\nfn main() {\n    let x = 1;\n}\n```\n\nThat's it.\n\n"
        ));
    }

    #[test]
    fn exact_prefix_is_found() {
        assert_eq!(
            common_prefix_modulo_whitespace("alpha\n\nbeta", "alpha\n\n"),
            Some(7)
        );
        assert_eq!(common_prefix_modulo_whitespace("alpha", "alpha"), Some(5));
        assert_eq!(common_prefix_modulo_whitespace("alpha", "beta"), None);
        assert_eq!(common_prefix_modulo_whitespace("al", "alpha"), None);
    }

    #[test]
    fn whitespace_runs_are_interchangeable() {
        // What the normaliser does to already-committed text when a dead phrase
        // in the tail triggers it: `[ \t]{2,}` → " " and `\n{3,}` → "\n\n".
        assert!(common_prefix_modulo_whitespace("a b\n\nrest", "a    b\n\n\n\n").is_some());
        assert!(common_prefix_modulo_whitespace("fn main() {\n let x;\n}\n\nX", "fn main() {\n    let x;\n}\n\n").is_some());
        // A single newline is NOT interchangeable with a blank line — that is a
        // real block boundary, not whitespace noise.
        assert_eq!(common_prefix_modulo_whitespace("a\nb", "a\n\nb"), None);
    }

    /// **Drift guard.** These lists are a copy of the backend's; if the Elixir
    /// side gains a fingerprint or a dead phrase and this file does not, the
    /// gate silently stops covering it and text the backend would have scrubbed
    /// can reach immutable scrollback. Read the source of truth and compare.
    ///
    /// Skips (rather than fails) when the Elixir tree is not beside the crate —
    /// the published binary is also built from tarballs.
    #[test]
    fn phrase_lists_match_the_backend() {
        let src = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../lib/optimal_system_agent/agent/loop/guardrails.ex");
        let Ok(text) = std::fs::read_to_string(&src) else {
            eprintln!("skipping: {} not present", src.display());
            return;
        };

        /// Every double-quoted string inside the `@name [ … ]` attribute list.
        fn attr_strings(text: &str, name: &str) -> Vec<String> {
            let start = text.find(name).expect("attribute not found");
            let body = &text[start + name.len()..];
            let end = body.find("\n\n").unwrap_or(body.len());
            let body = &body[..end];
            let mut out = Vec::new();
            let mut rest = body;
            while let Some(i) = rest.find('"') {
                rest = &rest[i + 1..];
                let Some(j) = rest.find('"') else { break };
                out.push(rest[..j].to_lowercase());
                rest = &rest[j + 1..];
            }
            out
        }

        let mut backend_fps = attr_strings(&text, "@system_prompt_fingerprints [");
        let mut ours: Vec<String> = LEAK_FINGERPRINTS.iter().map(|s| s.to_string()).collect();
        backend_fps.sort();
        ours.sort();
        assert_eq!(
            backend_fps, ours,
            "LEAK_FINGERPRINTS drifted from Guardrails.@system_prompt_fingerprints"
        );

        // `@dead_phrases` is a list of {phrase, replacement} tuples: the phrases
        // are the even-indexed strings.
        let dead = attr_strings(&text, "@dead_phrases [");
        let mut backend_dead: Vec<String> =
            dead.iter().step_by(2).map(|s| s.to_string()).collect();
        let mut ours_dead: Vec<String> = DEAD_PHRASES.iter().map(|s| s.to_string()).collect();
        backend_dead.sort();
        ours_dead.sort();
        assert_eq!(
            backend_dead, ours_dead,
            "DEAD_PHRASES drifted from Guardrails.@dead_phrases"
        );
    }

    #[test]
    fn a_diverged_final_is_rejected_rather_than_fuzzily_matched() {
        // The stream said one thing, the final says another: no prefix.
        assert_eq!(
            common_prefix_modulo_whitespace("Those are the three options.", "Those are the four "),
            None
        );
    }
}
