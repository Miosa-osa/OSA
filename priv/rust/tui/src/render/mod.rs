pub mod colors;
pub mod glyphs;
pub mod latex;
pub mod markdown;
pub mod markdown_stream;
pub mod sanitize;
/// Emulator-level proofs that untrusted text cannot drive the terminal.
#[cfg(test)]
mod injection_proofs;
/// Test-only measurement of the per-delta streaming render cost.
#[cfg(test)]
pub mod stream_bench;
pub mod syntax;
pub mod diff;
// Phase 6:
// pub mod image;
// pub mod logo;
