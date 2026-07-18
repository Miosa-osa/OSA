// Phase 2+: config_path() — wired when config reload command is implemented
#![allow(dead_code)]

pub mod cli;

use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use tracing::debug;

use crate::config::cli::Cli;

/// Single source of truth for the OSA version, resolved at compile time.
///
/// Prefers `OSA_VERSION` (stamped by the release CI from the git tag) and falls
/// back to the crate's `Cargo.toml` version so a plain `cargo build` still shows
/// a correct, non-empty semver. Never hardcode a version string anywhere else —
/// call this so the status bar, banner, `/version`, and `--version` can never
/// drift apart or go stale.
pub fn osa_version() -> &'static str {
    option_env!("OSA_VERSION").unwrap_or(env!("CARGO_PKG_VERSION"))
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
    #[serde(skip)]
    pub profile_dir: PathBuf,
    #[serde(skip)]
    pub base_url: String,
    /// When true, auto-approve all tool permissions (--dangerously-skip-permissions / --yolo)
    #[serde(skip)]
    pub skip_permissions: bool,
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
