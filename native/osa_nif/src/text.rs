use regex::Regex;
use std::sync::OnceLock;

// NIF SAFETY: a panic inside a NIF unwinds across the FFI boundary and ABORTS
// the emulator — every in-flight session is lost, not just this call. So no
// `.expect()`/`unwrap()` on any path reachable from a nif function, even for
// inputs that "cannot" fail. Both patterns below are compile-time constants and
// are covered by `regexes_compile`; if one ever did fail to compile, the NIF now
// degrades (the bonus/penalty simply does not apply) instead of killing the node.
static URGENCY_RE: OnceLock<Option<Regex>> = OnceLock::new();
static NOISE_RE: OnceLock<Option<Regex>> = OnceLock::new();

fn urgency_regex() -> Option<&'static Regex> {
    URGENCY_RE
        .get_or_init(|| Regex::new(r"(?i)\b(urgent|asap|critical|emergency|immediately|now)\b").ok())
        .as_ref()
}

fn noise_regex() -> Option<&'static Regex> {
    NOISE_RE
        .get_or_init(|| Regex::new(r"(?i)\b(hello|thanks|lol|haha|hi|ok|hey|sure)\b").ok())
        .as_ref()
}

/// Scoring logic, kept as a plain function so it is unit-testable — the
/// `#[rustler::nif]` wrapper below is not callable by name from tests.
pub fn calculate_weight_impl(text: &str) -> f64 {
    let base: f64 = 0.5;

    let length_bonus: f64 = (text.chars().count() as f64 / 500.0).min(0.2);

    let question_bonus: f64 = if text.contains('?') { 0.15 } else { 0.0 };

    let urgency_bonus: f64 = match urgency_regex() {
        Some(re) if re.is_match(text) => 0.2,
        _ => 0.0,
    };

    let noise_penalty: f64 = match noise_regex() {
        Some(re) if re.is_match(text) => -0.3,
        _ => 0.0,
    };

    let result = base + length_bonus + question_bonus + urgency_bonus + noise_penalty;
    result.clamp(0.0, 1.0)
}

#[rustler::nif]
fn calculate_weight(text: &str) -> f64 {
    calculate_weight_impl(text)
}

#[rustler::nif]
fn word_count(text: &str) -> usize {
    text.split_whitespace().count()
}

#[cfg(test)]
mod tests {
    use super::*;

    // Guards the constants the NIF no longer panics on: they must still compile,
    // otherwise the scoring silently degrades to "no urgency, no noise".
    #[test]
    fn regexes_compile() {
        assert!(urgency_regex().is_some());
        assert!(noise_regex().is_some());
    }

    #[test]
    fn urgency_raises_and_noise_lowers_weight() {
        let neutral = calculate_weight_impl("a plain sentence");
        assert!(calculate_weight_impl("this is urgent") > neutral);
        assert!(calculate_weight_impl("lol") < neutral);
    }
}
