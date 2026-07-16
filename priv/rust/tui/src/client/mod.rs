pub mod auth;
// Generated from the Elixir protocol (OptimalSystemAgent.Protocol.TUISchema) by
// `mix osa.gen.tui_types`. Re-exported through `types` so callers keep using
// `crate::client::types::*`; do not edit generated.rs by hand.
pub mod generated;
pub mod http;
pub mod sse;
pub mod types;

// Re-exports for convenience — used via full paths in some places, re-export in others
#[allow(unused_imports)]
pub use auth::AuthState;
#[allow(unused_imports)]
pub use http::ApiClient;
pub use sse::SseClient;
#[allow(unused_imports)]
pub use types::*;
