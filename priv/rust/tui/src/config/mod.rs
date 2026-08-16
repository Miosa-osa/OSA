// Phase 2+: config_path() — wired when config reload command is implemented
#![allow(dead_code)]

pub mod cli;
pub mod keybindings;

use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use tracing::debug;

use crate::config::cli::Cli;

/// Single source of truth for the OSA version, resolved at compile time.
///
/// `build.rs` resolves this from, in order: `$OSA_VERSION` (stamped by the
/// release CI from the git tag), the repo-root `VERSION` file, and only then the
/// crate's `Cargo.toml` literal. It is therefore always defined — the
/// `unwrap_or` is a belt-and-braces fallback for a build with no build script.
///
/// This used to fall straight through to `CARGO_PKG_VERSION`, a hand-maintained
/// literal that drifted (1.0.27 vs a shipped 1.0.45), so every non-CI build
/// displayed a confidently wrong version. Never hardcode a version string
/// anywhere else — call this so the status bar, banner, `/version`, and
/// `--version` can never drift apart or go stale.
pub fn osa_version() -> &'static str {
    option_env!("OSA_VERSION").unwrap_or(env!("CARGO_PKG_VERSION"))
}

/// Where [`osa_version`] came from: `"env"` (release CI), `"file"` (repo
/// `VERSION`), or `"cargo"` (Cargo.toml fallback). Useful when diagnosing a
/// version mismatch between the TUI binary and the backend.
pub fn osa_version_source() -> &'static str {
    option_env!("OSA_VERSION_SOURCE").unwrap_or("cargo")
}

/// Runtime version reported by the backend `GET /health` response. Once set it
/// becomes the single source of truth for the displayed version (the backend's
/// root `VERSION` file — never stale), taking precedence over the compile-time
/// crate version baked into this binary. Stored behind a process-global lock so
/// the free `osa_version_display()` (called from the status bar, welcome banner,
/// and `/version`) can pick it up without threading state through every caller.
static RUNTIME_VERSION: std::sync::RwLock<Option<String>> = std::sync::RwLock::new(None);

/// Record the backend's reported version (from `GET /health`). Empty / blank
/// values are ignored so a missing field can never blank the displayed version.
pub fn set_runtime_version(version: &str) {
    let v = version.trim();
    if v.is_empty() {
        return;
    }
    if let Ok(mut slot) = RUNTIME_VERSION.write() {
        *slot = Some(v.to_string());
    }
}

/// The *display* form of the version. When the backend has reported its version
/// (via `GET /health`), that value is the canonical source of truth — it is the
/// human-facing string from the app's root `VERSION` file (e.g. `1.0.3`), so the
/// UI can never drift from the running backend. Its patch component is
/// zero-padded to three digits (1.0.3 -> 1.0.003) so the human-facing display
/// convention stays consistent. Only when no backend version is known yet do we
/// fall back to the crate's compile-time semver, padded the same way.
///
/// Use this for every user-facing surface: the status-bar chip, the welcome
/// banner, the `/version` command, and `--version`. Use [`osa_version`] for
/// anything a machine parses.
pub fn osa_version_display() -> String {
    if let Ok(slot) = RUNTIME_VERSION.read() {
        if let Some(ref v) = *slot {
            // Pad the backend-reported version too so the human-facing display
            // convention (1.0.3 -> 1.0.003) is consistent regardless of whether
            // the version came from the backend or the compile-time fallback.
            return pad_version_display(v);
        }
    }
    pad_version_display(osa_version())
}

/// Pad the patch component of a semver string to a minimum width of 3.
///
/// The numeric core (`MAJOR.MINOR.PATCH`) is padded; any pre-release/build
/// metadata introduced by the first `-` or `+` is split off and re-appended
/// untouched. If the string is not a 3-part core of all-numeric components it
/// is returned unchanged (so odd/unexpected version strings never get mangled).
fn pad_version_display(v: &str) -> String {
    // Peel off pre-release/build metadata so we only touch the numeric core.
    let (core, suffix) = match v.find(['-', '+']) {
        Some(i) => (&v[..i], &v[i..]),
        None => (v, ""),
    };
    let parts: Vec<&str> = core.split('.').collect();
    let all_numeric = parts.len() == 3
        && parts
            .iter()
            .all(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()));
    if !all_numeric {
        return v.to_string();
    }
    // `{:0>3}` = fill '0', right-align, min width 3 (pads a 1/2-digit patch,
    // leaves 3+ digits as-is).
    format!("{}.{}.{:0>3}{}", parts[0], parts[1], parts[2], suffix)
}

#[cfg(test)]
mod version_display_tests {
    use super::pad_version_display;

    #[test]
    fn pads_patch_to_three_digits() {
        assert_eq!(pad_version_display("1.0.0"), "1.0.000");
        assert_eq!(pad_version_display("1.0.1"), "1.0.001");
        assert_eq!(pad_version_display("1.0.17"), "1.0.017");
        // The current version: semver-internal "1.0.9"/"1.0.10" MUST display
        // zero-padded as "1.0.009"/"1.0.010" (leading zeros are illegal in the
        // internal semver, so padding happens only at display time).
        assert_eq!(pad_version_display("1.0.9"), "1.0.009");
        assert_eq!(pad_version_display("1.0.10"), "1.0.010");
        assert_eq!(pad_version_display("1.0.11"), "1.0.011");
    }

    #[test]
    fn leaves_wide_patch_and_major_minor_alone() {
        assert_eq!(pad_version_display("1.0.128"), "1.0.128");
        assert_eq!(pad_version_display("2.11.5"), "2.11.005");
        assert_eq!(pad_version_display("10.20.30"), "10.20.030");
    }

    #[test]
    fn preserves_prerelease_and_build_suffix() {
        assert_eq!(pad_version_display("1.0.2-rc.1"), "1.0.002-rc.1");
        assert_eq!(pad_version_display("1.0.2+build.5"), "1.0.002+build.5");
        assert_eq!(pad_version_display("1.0.2-rc.1+build.5"), "1.0.002-rc.1+build.5");
    }

    #[test]
    fn passes_through_non_three_part_or_non_numeric() {
        assert_eq!(pad_version_display("1.0"), "1.0");
        assert_eq!(pad_version_display("1.0.0.0"), "1.0.0.0");
        assert_eq!(pad_version_display("nightly"), "nightly");
        assert_eq!(pad_version_display("1.x.0"), "1.x.0");
        assert_eq!(pad_version_display(""), "");
    }
}

fn home_dir() -> PathBuf {
    // Resolve the real home dir cross-platform: BaseDirs honors USERPROFILE /
    // HOMEDRIVE+HOMEPATH on Windows (where HOME is normally unset), and $HOME on
    // unix. Fall back to $HOME, then to "." only as a last resort. Without this,
    // Windows would write config/logs under a per-CWD "./.osa" that never
    // persists to the user's real profile.
    directories::BaseDirs::new()
        .map(|d| d.home_dir().to_path_buf())
        .or_else(|| std::env::var("HOME").ok().map(PathBuf::from))
        .unwrap_or_else(|| PathBuf::from("."))
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    #[serde(default = "default_theme")]
    pub theme: String,
    #[serde(default)]
    pub sidebar_enabled: bool,
    #[serde(default = "default_request_timeout_secs")]
    pub request_timeout_secs: u64,
    /// Max auto-continue cycles for an active /goal before stopping.
    #[serde(default = "default_goal_max_cycles")]
    pub goal_max_cycles: u32,
    /// Screen-reader / plain-text (accessibility) mode. When true, the activity
    /// indicator renders as a single static plain-language status line instead of
    /// the animated star spinner + braille feed. Toggled via `/a11y`.
    #[serde(default)]
    pub a11y: bool,
    /// Print the conversation to the primary screen when OSA exits.
    ///
    /// ON by default, because that is today's behaviour: OSA used to commit the
    /// transcript into the terminal's own scrollback, so quitting left it there
    /// to scroll back through, copy a command out of, or paste into a ticket.
    /// Owning the viewport is what keeps the user's pre-launch shell history
    /// safe across a resize, but it also means the alternate screen takes the
    /// session with it on the way out. This puts it back. Set false for a clean
    /// terminal on exit.
    #[serde(default = "default_exit_transcript")]
    pub exit_transcript: bool,
    /// Lean view: hide tool calls and tool results from the printed
    /// conversation, leaving the model's prose (and its reasoning, which is live
    /// chrome and unaffected). Toggled via `/lean`.
    ///
    /// Durable here rather than in `~/.osa/settings.json` because this is purely
    /// how the client draws — the backend neither knows nor needs to. The
    /// `Agent.AskUserMode` shape (session-sticky ETS + a trust-gated settings
    /// key) exists because that flag changes what the AGENT may do and an
    /// untrusted workspace must not be able to set it; neither applies to a
    /// display preference, and there is no settings payload from the backend to
    /// the TUI to carry one anyway. `a11y` is the existing precedent for exactly
    /// this class and this follows it.
    #[serde(default)]
    pub lean: bool,
    #[serde(skip)]
    pub profile_dir: PathBuf,
    #[serde(skip)]
    pub base_url: String,
    /// When true, auto-approve all tool permissions (--dangerously-skip-permissions / --yolo)
    #[serde(skip)]
    pub skip_permissions: bool,
}

fn default_exit_transcript() -> bool {
    true
}

fn default_theme() -> String {
    "dark".to_string()
}

fn default_request_timeout_secs() -> u64 {
    900
}

fn default_goal_max_cycles() -> u32 {
    25
}

impl Default for Config {
    fn default() -> Self {
        Self {
            theme: default_theme(),
            request_timeout_secs: default_request_timeout_secs(),
            goal_max_cycles: default_goal_max_cycles(),
            a11y: false,
            exit_transcript: default_exit_transcript(),
            lean: false,
            sidebar_enabled: false,
            profile_dir: default_profile_dir(),
            base_url: default_base_url(),
            skip_permissions: false,
        }
    }
}

fn default_profile_dir() -> PathBuf {
    home_dir().join(".osa")
}

fn default_base_url() -> String {
    std::env::var("OSA_URL").unwrap_or_else(|_| "http://localhost:9089".to_string())
}

impl Config {
    pub fn load(cli: &Cli) -> Result<Self> {
        let profile_dir = if let Some(ref profile) = cli.profile {
            default_profile_dir().join("profiles").join(profile)
        } else {
            default_profile_dir()
        };

        let config_path = profile_dir.join("tui.json");
        let mut config = if config_path.exists() {
            let data = std::fs::read_to_string(&config_path)?;
            serde_json::from_str(&data).unwrap_or_default()
        } else {
            Config::default()
        };

        config.profile_dir = profile_dir;
        config.skip_permissions = cli.dangerously_skip_permissions;

        // CLI overrides
        if cli.dev {
            config.base_url = format!(
                "http://localhost:{}",
                std::env::var("OSA_PORT").unwrap_or_else(|_| "19001".to_string())
            );
        } else {
            config.base_url =
                std::env::var("OSA_URL").unwrap_or_else(|_| "http://localhost:9089".to_string());
        }

        debug!(
            "Config loaded: theme={}, sidebar={}, url={}",
            config.theme, config.sidebar_enabled, config.base_url
        );
        Ok(config)
    }

    pub fn save(&self) -> Result<()> {
        std::fs::create_dir_all(&self.profile_dir)?;
        let path = self.profile_dir.join("tui.json");
        let data = serde_json::to_string_pretty(self)?;
        std::fs::write(path, data)?;
        Ok(())
    }

    pub fn config_path(&self) -> PathBuf {
        self.profile_dir.join("tui.json")
    }
}

/// Regression guard for the version-drift bug: the TUI once shipped a
/// hand-maintained `Cargo.toml` literal (1.0.27) while the repo `VERSION` file
/// said 1.0.45, so any non-CI build displayed a confidently wrong version.
/// `build.rs` now resolves the version from `$OSA_VERSION` → repo `VERSION` →
/// `CARGO_PKG_VERSION`; these tests make sure the sources can never silently
/// diverge again.
#[cfg(test)]
mod version_source_tests {
    use super::{osa_version, osa_version_source};

    /// Contents of the repo-root `VERSION` file as captured by `build.rs`, or
    /// `None` when the crate was built detached from the repo.
    fn version_file() -> Option<&'static str> {
        option_env!("OSA_VERSION_FILE")
            .map(str::trim)
            .filter(|s| !s.is_empty())
    }

    #[test]
    fn cargo_toml_literal_matches_the_version_file() {
        let Some(file) = version_file() else {
            return; // built without the repo checkout — nothing to compare
        };
        assert_eq!(
            env!("CARGO_PKG_VERSION"),
            file,
            "priv/rust/tui/Cargo.toml `version` has drifted from the repo VERSION \
             file. Update the Cargo.toml literal to {file}."
        );
    }

    #[test]
    fn compile_time_version_matches_the_version_file() {
        let Some(file) = version_file() else {
            return;
        };
        match osa_version_source() {
            // No CI override in play: the VERSION file IS the version.
            "file" | "cargo" => assert_eq!(
                osa_version(),
                file,
                "osa_version() must equal the repo VERSION file when no \
                 $OSA_VERSION override is set"
            ),
            // Release CI stamped a tag-derived version; it legitimately wins.
            // It must still be a non-empty semver-ish string.
            "env" => assert!(
                !osa_version().is_empty(),
                "$OSA_VERSION override resolved to an empty version"
            ),
            other => panic!("unexpected OSA_VERSION_SOURCE {other:?}"),
        }
    }

    #[test]
    fn version_is_never_empty_or_placeholder() {
        let v = osa_version();
        assert!(!v.is_empty(), "osa_version() must never be empty");
        assert!(
            v.split('.').count() >= 3,
            "osa_version() must look like a semver, got {v:?}"
        );
    }
}
