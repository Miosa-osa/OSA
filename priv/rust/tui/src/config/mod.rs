// Phase 2+: config_path() — wired when config reload command is implemented
#![allow(dead_code)]

pub mod cli;

use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use tracing::debug;

use crate::config::cli::Cli;

fn home_dir() -> PathBuf {
    std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("."))
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
    std::env::var("OSA_URL").unwrap_or_else(|_| "http://localhost:8089".to_string())
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
                std::env::var("OSA_URL").unwrap_or_else(|_| "http://localhost:8089".to_string());
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
