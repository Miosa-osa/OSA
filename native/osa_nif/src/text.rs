use regex::Regex;
use std::sync::OnceLock;

static URGENCY_RE: OnceLock<Regex> = OnceLock::new();
static NOISE_RE: OnceLock<Regex> = OnceLock::new();

fn urgency_regex() -> &'static Regex {
    URGENCY_RE.get_or_init(|| {
        Regex::new(r"(?i)\b(urgent|asap|critical|emergency|immediately|now)\b")
            .expect("invalid urgency regex")
    })
}

fn noise_regex() -> &'static Regex {
    NOISE_RE.get_or_init(|| {
        Regex::new(r"(?i)\b(hello|thanks|lol|haha|hi|ok|hey|sure)\b")
            .expect("invalid noise regex")
    })
}

#[rustler::nif]
fn calculate_weight(text: &str) -> f64 {
    let base: f64 = 0.5;

    let length_bonus: f64 = (text.chars().count() as f64 / 500.0).min(0.2);

    let question_bonus: f64 = if text.contains('?') { 0.15 } else { 0.0 };

    let urgency_bonus: f64 = if urgency_regex().is_match(text) {
        0.2
    } else {
        0.0
    };

    let noise_penalty: f64 = if noise_regex().is_match(text) {
        -0.3
    } else {
        0.0
    };

    let result = base + length_bonus + question_bonus + urgency_bonus + noise_penalty;
    result.clamp(0.0, 1.0)
}

#[rustler::nif]
fn word_count(text: &str) -> usize {
    text.split_whitespace().count()
}
