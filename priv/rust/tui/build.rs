//! Build script: resolve the OSA version from the repo's single source of truth.
//!
//! The TUI must never invent its own version. Historically `config::osa_version()`
//! fell back to `env!("CARGO_PKG_VERSION")` — a hand-maintained literal in
//! `Cargo.toml` that silently drifted from the repo `VERSION` file (it sat at
//! 1.0.27 while the repo shipped 1.0.45), so any non-CI build confidently
//! displayed a WRONG version.
//!
//! Resolution order (first hit wins):
//!   1. `OSA_VERSION` in the build environment — stamped by the release CI from
//!      the git tag. CI must always win, so this is checked first.
//!   2. `../../../VERSION` — the repo's single source of truth for local/dev
//!      builds.
//!   3. `CARGO_PKG_VERSION` — last resort when the crate is built detached from
//!      the repo (e.g. a vendored/packaged copy with no VERSION file).
//!
//! Emitted compile-time env vars:
//!   `OSA_VERSION`        the resolved version string
//!   `OSA_VERSION_FILE`   contents of the repo VERSION file ("" if not found)
//!   `OSA_VERSION_SOURCE` "env" | "file" | "cargo" — which rule above matched

use std::path::PathBuf;

fn main() {
    // `cargo:rustc-env` overrides the inherited process env for `env!` /
    // `option_env!`, so we must fold the CI-provided value in here ourselves
    // rather than relying on it leaking through.
    println!("cargo:rerun-if-env-changed=OSA_VERSION");

    let manifest_dir = PathBuf::from(
        std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR is always set by cargo"),
    );
    // priv/rust/tui -> priv/rust -> priv -> <repo root>
    let version_file = manifest_dir.join("../../../VERSION");
    println!("cargo:rerun-if-changed={}", version_file.display());
    println!("cargo:rerun-if-changed=build.rs");

    let file_version = std::fs::read_to_string(&version_file)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());

    let env_version = std::env::var("OSA_VERSION")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());

    let cargo_version =
        std::env::var("CARGO_PKG_VERSION").expect("CARGO_PKG_VERSION is always set by cargo");

    let (resolved, source) = match (&env_version, &file_version) {
        (Some(v), _) => (v.clone(), "env"),
        (None, Some(v)) => (v.clone(), "file"),
        (None, None) => (cargo_version.clone(), "cargo"),
    };

    // Loud, non-fatal warning when the hand-maintained Cargo.toml literal has
    // drifted from the VERSION file. (`cargo test` also asserts this — see
    // `config::version_source_tests` — this is just the early signal.)
    if let Some(ref fv) = file_version {
        if fv != &cargo_version {
            println!(
                "cargo:warning=osa-tui: Cargo.toml version ({cargo_version}) does not match \
                 the repo VERSION file ({fv}) — sync the Cargo.toml `version` line."
            );
        }
    }

    println!("cargo:rustc-env=OSA_VERSION={resolved}");
    println!(
        "cargo:rustc-env=OSA_VERSION_FILE={}",
        file_version.unwrap_or_default()
    );
    println!("cargo:rustc-env=OSA_VERSION_SOURCE={source}");
}
