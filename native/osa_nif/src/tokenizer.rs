use rustler::{Atom, Error as NifError};
use std::sync::OnceLock;
use tiktoken_rs::CoreBPE;

mod atoms {
    rustler::atoms! {
        tokenizer_unavailable,
        tokenizer_panicked,
    }
}

/// Why a token count could not be produced.
///
/// The point of this type is that there IS one — the previous implementation
/// had no failure representation at all and folded every error into `0`.
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum TokenizeError {
    /// The encoding could not be loaded.
    Unavailable,
    /// The encode itself panicked.
    Panicked,
}

// `cl100k_base` is OpenAI's encoding. It is used here for EVERY provider, which
// makes the count materially wrong for Anthropic and Gemini (routinely 10-20%
// off). That is a separate, provider-routing problem and is NOT fixed here —
// see the report. What is fixed here is failing OPEN.
static ENCODING: OnceLock<Option<CoreBPE>> = OnceLock::new();

// `.expect()` in a NIF is an ABORT: a panic unwinding across the NIF boundary
// takes down the whole BEAM and every in-flight session with it. Load the
// encoding into an Option instead and let callers see an error term.
fn get_encoding() -> Option<&'static CoreBPE> {
    ENCODING
        .get_or_init(|| tiktoken_rs::cl100k_base().ok())
        .as_ref()
}

/// Count tokens in `text`, or explain why it could not.
///
/// FAILS CLOSED. The previous implementation returned `0` when the encode
/// panicked, and `0` means "this content is free" to every budget check
/// upstream — so a panicking tokenizer silently admitted unbounded content into
/// the context window instead of rejecting it. Returning an error forces the
/// caller to decide (and lets the pure-Elixir fallback take over).
pub fn count_tokens_impl(text: &str) -> Result<usize, TokenizeError> {
    let encoding = get_encoding().ok_or(TokenizeError::Unavailable)?;

    // catch_unwind still guards the encode: a panic here must become an Erlang
    // exception, never an abort of the emulator.
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        encoding.encode_ordinary(text).len()
    }))
    .map_err(|_| TokenizeError::Panicked)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn count_tokens(text: &str) -> Result<usize, NifError> {
    count_tokens_impl(text).map_err(|e| {
        raise(match e {
            TokenizeError::Unavailable => atoms::tokenizer_unavailable(),
            TokenizeError::Panicked => atoms::tokenizer_panicked(),
        })
    })
}

fn raise(atom: Atom) -> NifError {
    NifError::Term(Box::new(atom))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counts_tokens_for_real_text() {
        assert!(count_tokens_impl("hello world").unwrap() > 0);
    }

    // THE regression: a failure must never be reported as 0, because 0 reads as
    // "this content is free" to every budget check upstream. On the old code
    // this assertion could not even be written — the return type was `usize`
    // and the panic branch returned 0.
    #[test]
    fn failure_is_an_error_not_zero() {
        let outcome: Result<usize, TokenizeError> =
            count_tokens_impl("some non-empty content that costs tokens");
        match outcome {
            Ok(n) => assert!(n > 0, "non-empty text must not count as 0 tokens"),
            Err(e) => assert!(
                matches!(e, TokenizeError::Unavailable | TokenizeError::Panicked),
                "failure must be explicit, got {e:?}"
            ),
        }
    }

    #[test]
    fn empty_text_is_zero_tokens() {
        assert_eq!(count_tokens_impl("").unwrap(), 0);
    }

    // Zero is reserved for genuinely empty input. If this ever fires for
    // non-empty text, a budget check somewhere is being told the content is free.
    #[test]
    fn zero_is_only_ever_returned_for_empty_input() {
        for s in ["a", "hello", "日本語", "\u{1F600}"] {
            assert_ne!(count_tokens_impl(s), Ok(0), "{s:?} counted as free");
        }
    }
}
