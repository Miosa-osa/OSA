//! Turn an API error string into the sentence a person should read.
//!
//! Every non-2xx the client sees is formatted for a log line:
//! `HTTP 400 Bad Request from /api/v1/sessions/abc/provider: {"error":…}`. The
//! JSON may itself carry a provider's own error body, one level down, with a
//! `request_id` beside the message. None of that belongs in a toast. What does
//! is the server's human-readable message — `error.message` for OpenAI,
//! Anthropic, OpenRouter and Gemini, the bare `error` string for Ollama,
//! `details` / `message` / `detail` for OSA's own routes — with request ids
//! stripped.
//!
//! Nothing is ever lost silently: when no JSON is present the text passes
//! through (request ids still stripped), and when JSON is present but carries
//! no message the prose in front of it is kept instead of the braces.

use serde_json::Value;

/// The human-readable message inside `raw`, or `raw` itself (minus request
/// ids) when it has none. Unwraps nested bodies (a provider body quoted inside
/// an OSA `details` string) up to a small fixed depth.
pub fn human_error_message(raw: &str) -> String {
    let mut text = raw.trim().to_string();
    for _ in 0..4 {
        match first_json(&text) {
            Some((prefix, value)) => match message_from_json(&value) {
                Some(msg) => text = msg,
                None => {
                    let prefix = prefix.trim().trim_end_matches(':').trim();
                    text = if prefix.is_empty() {
                        "the server returned an error without a message".to_string()
                    } else {
                        prefix.to_string()
                    };
                    break;
                }
            },
            None => break,
        }
    }
    let cleaned = strip_request_ids(&text);
    if cleaned.is_empty() {
        raw.trim().to_string()
    } else {
        cleaned
    }
}

/// The first `{…}` in `s` that parses as a JSON object, with the text before it.
fn first_json(s: &str) -> Option<(&str, Value)> {
    for (i, _) in s.match_indices('{') {
        let mut stream = serde_json::Deserializer::from_str(&s[i..]).into_iter::<Value>();
        if let Some(Ok(v @ Value::Object(_))) = stream.next() {
            return Some((&s[..i], v));
        }
    }
    None
}

fn non_empty_str(v: Option<&Value>) -> Option<String> {
    v.and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

/// An error-CODE string (`invalid_model`, `not_found_error`) rather than a
/// sentence. OSA's own routes put the code in `error` and the sentence in
/// `details`, while Ollama puts its sentence in `error`; this tells them apart.
fn looks_like_code(s: &str) -> bool {
    !s.contains(char::is_whitespace)
}

fn message_from_json(v: &Value) -> Option<String> {
    let error = v.get("error");
    // OpenAI / Anthropic / OpenRouter / Gemini: {"error": {"message": "…"}}
    if let Some(msg) = error.and_then(|e| non_empty_str(e.get("message"))) {
        return Some(msg);
    }
    for key in ["details", "message", "detail", "error_description"] {
        if let Some(msg) = non_empty_str(v.get(key)) {
            return Some(msg);
        }
    }
    // {"errors": [{"message": "…"}]}
    if let Some(msg) = v
        .get("errors")
        .and_then(|e| e.as_array())
        .and_then(|a| a.first())
        .and_then(|e| non_empty_str(e.get("message")))
    {
        return Some(msg);
    }
    // Ollama: {"error": "model \"x\" not found, try pulling it first"}
    match non_empty_str(error) {
        Some(msg) if !looks_like_code(&msg) => Some(msg),
        Some(code) => Some(code.replace('_', " ")),
        None => None,
    }
}

/// Remove request identifiers: `request_id: req_…`, `(Request ID: abc)`,
/// `x-request-id=…`, and bare `req_…` tokens. They are for support tickets,
/// not for the person choosing a model.
fn strip_request_ids(s: &str) -> String {
    let lower = s.to_ascii_lowercase();
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    let bytes = s.as_bytes();
    while i < s.len() {
        let rest = &lower[i..];
        let label = [
            "x-request-id",
            "request_id",
            "request-id",
            "requestid",
            "request id",
        ]
        .iter()
        .find(|l| rest.starts_with(**l))
        .map(|l| l.len());
        let label = label.filter(|n| {
            // A whole label, not the front of a longer word ("request identifier").
            !bytes.get(i + n).is_some_and(|b| b.is_ascii_alphanumeric())
        });
        if let Some(n) = label {
            let mut j = i + n;
            // separators between the label and the id
            while j < s.len() && matches!(bytes[j], b':' | b'=' | b' ' | b'"' | b'\'') {
                j += 1;
            }
            while j < s.len() && is_id_byte(bytes[j]) {
                j += 1;
            }
            while j < s.len() && matches!(bytes[j], b'"' | b'\'') {
                j += 1;
            }
            i = j;
            continue;
        }
        let at_word_start = i == 0 || !is_id_byte(bytes[i - 1]);
        if at_word_start && rest.starts_with("req_") {
            let mut j = i + 4;
            while j < s.len() && is_id_byte(bytes[j]) {
                j += 1;
            }
            if j - i >= 8 {
                i = j;
                continue;
            }
        }
        let ch = s[i..].chars().next().expect("in bounds");
        out.push(ch);
        i += ch.len_utf8();
    }
    tidy(&out)
}

fn is_id_byte(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_' || b == b'-'
}

/// Collapse what the removal left behind: empty `()`/`[]`, doubled spaces, and
/// dangling separators at the end.
fn tidy(s: &str) -> String {
    let mut t = s.to_string();
    for empty in ["()", "[]", "( )", "[ ]"] {
        t = t.replace(empty, "");
    }
    let t = t.split_whitespace().collect::<Vec<_>>().join(" ");
    let t = t.replace(" .", ".").replace(" ,", ",");
    t.trim()
        .trim_end_matches([',', ';', ':', '-', '·'])
        .trim()
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::human_error_message as h;

    #[test]
    fn osa_invalid_model_route_shows_the_details_sentence() {
        let raw = r#"HTTP 400 Bad Request from /api/v1/sessions/abc/provider: {"error":"invalid_model","details":"unknown model \"gpt-9\" for provider openai"}"#;
        assert_eq!(h(raw), r#"unknown model "gpt-9" for provider openai"#);
    }

    #[test]
    fn anthropic_body_drops_type_and_request_id() {
        let raw = r#"HTTP 400 Bad Request from /api/v1/sessions/s/provider: {"error":"invalid_model","details":"Anthropic returned 404: {\"type\":\"error\",\"error\":{\"type\":\"not_found_error\",\"message\":\"model: claude-nope\"},\"request_id\":\"req_011CXyZabc123\"}"}"#;
        let msg = h(raw);
        assert_eq!(msg, "model: claude-nope");
        assert!(!msg.contains("req_"), "{msg}");
    }

    #[test]
    fn openai_body_shows_error_message() {
        let raw = r#"HTTP 404: {"error":{"message":"The model `gpt-9` does not exist or you do not have access to it.","type":"invalid_request_error","param":null,"code":"model_not_found"}}"#;
        assert_eq!(
            h(raw),
            "The model `gpt-9` does not exist or you do not have access to it."
        );
    }

    #[test]
    fn openrouter_body_shows_error_message() {
        let raw = r#"{"error":{"message":"foo/bar is not a valid model ID","code":400},"user_id":"user_2abc"}"#;
        assert_eq!(h(raw), "foo/bar is not a valid model ID");
    }

    #[test]
    fn ollama_bare_error_string_is_the_message() {
        let raw =
            r#"Ollama returned 404: {"error":"model \"llama9\" not found, try pulling it first"}"#;
        assert_eq!(h(raw), r#"model "llama9" not found, try pulling it first"#);
    }

    #[test]
    fn request_ids_in_prose_are_stripped() {
        assert_eq!(
            h("Model not available on your plan (request id: req_abc123XYZ)."),
            "Model not available on your plan."
        );
        assert_eq!(
            h("Model refused. request_id=7f9e2c1a-0b3d x-request-id: abc-123"),
            "Model refused."
        );
    }

    #[test]
    fn plain_text_passes_through() {
        assert_eq!(h("connection refused"), "connection refused");
    }

    #[test]
    fn json_without_a_message_keeps_the_prose_not_the_braces() {
        let msg = h(r#"HTTP 500 Internal Server Error from /x: {"foo":1}"#);
        assert_eq!(msg, "HTTP 500 Internal Server Error from /x");
        assert!(!msg.contains('{'));
    }

    #[test]
    fn bare_error_code_is_humanized_not_dropped() {
        assert_eq!(
            h(r#"{"error":"provider is required"}"#),
            "provider is required"
        );
        assert_eq!(h(r#"{"error":"swap_failed"}"#), "swap failed");
    }
}
