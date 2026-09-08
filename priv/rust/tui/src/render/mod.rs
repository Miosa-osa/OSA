/// Escape-aware direct-to-buffer line rendering (OSC 8 hyperlinks).
pub mod cells;
pub mod colors;
pub mod diff;
pub mod glyphs;
/// Emulator-level proofs that untrusted text cannot drive the terminal.
#[cfg(test)]
mod injection_proofs;
pub mod latex;
pub mod markdown;
pub mod markdown_stream;
pub mod sanitize;
/// Test-only measurement of the per-delta streaming render cost.
#[cfg(test)]
pub mod stream_bench;
pub mod syntax;
// Phase 6:
// pub mod image;
// pub mod logo;
