use std::sync::OnceLock;
use tiktoken_rs::CoreBPE;

static ENCODING: OnceLock<CoreBPE> = OnceLock::new();

fn get_encoding() -> &'static CoreBPE {
    ENCODING.get_or_init(|| {
        tiktoken_rs::cl100k_base().expect("failed to load cl100k_base encoding")
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn count_tokens(text: &str) -> usize {
    match std::panic::catch_unwind(|| get_encoding().encode_ordinary(text).len()) {
        Ok(count) => count,
        Err(_) => 0,
    }
}
