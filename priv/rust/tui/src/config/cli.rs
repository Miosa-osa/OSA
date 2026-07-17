use std::path::PathBuf;

fn home_dir() -> PathBuf {
    // Cross-platform home resolution (see config/mod.rs::home_dir). BaseDirs
    // honors USERPROFILE on Windows so logs land under the real profile instead
    // of a per-CWD "./.osa/logs".
    directories::BaseDirs::new()
        .map(|d| d.home_dir().to_path_buf())
        .or_else(|| std::env::var("HOME").ok().map(PathBuf::from))
        .unwrap_or_else(|| PathBuf::from("."))
}

/// OSA Agent TUI CLI arguments
pub struct Cli {
    pub profile: Option<String>,
    pub dev: bool,
    pub setup: bool,
    pub no_color: bool,
    pub version: bool,
    /// Enter overdrive (full auto): skip all tool permission prompts. Canonical
    /// spelling is `--overdrive`; `--dangerously-skip-permissions` is a silent
    /// hidden alias kept for muscle memory / scripts.
    pub dangerously_skip_permissions: bool,
    /// `-c` / `--continue`: resume this directory's most recent session.
    pub continue_last: bool,
    /// `--resume [id]`: `Some(Some(id))` resumes a specific session; `Some(None)`
    /// (flag with no id) opens the session browser at startup; `None` = not set.
    pub resume: Option<Option<String>>,
    /// `--permission-mode <mode>`: seed the initial mode
    /// (ask|auto-edit|plan|auto|overdrive|bypass|default).
    pub permission_mode: Option<String>,
}

impl Cli {
    pub fn parse_args() -> Self {
        let mut cli = Self {
            profile: None,
            dev: false,
            setup: false,
            no_color: false,
            version: false,
            dangerously_skip_permissions: false,
            continue_last: false,
            resume: None,
            permission_mode: None,
        };

        let args: Vec<String> = std::env::args().skip(1).collect();
        let mut i = 0;
        while i < args.len() {
            match args[i].as_str() {
                "--profile" => {
                    i += 1;
                    if i < args.len() {
                        cli.profile = Some(args[i].clone());
                    }
                }
                "--dev" => cli.dev = true,
                "--setup" => cli.setup = true,
                "--no-color" => cli.no_color = true,
                "--version" | "-V" => cli.version = true,
                // Canonical overdrive flag + hidden legacy aliases.
                "--overdrive" | "--dangerously-skip-permissions" | "--yolo" => {
                    cli.dangerously_skip_permissions = true;
                }
                "-c" | "--continue" => cli.continue_last = true,
                "--resume" => {
                    // Optional session id: only consume the next token if it
                    // isn't itself a flag.
                    if i + 1 < args.len() && !args[i + 1].starts_with('-') {
                        i += 1;
                        cli.resume = Some(Some(args[i].clone()));
                    } else {
                        cli.resume = Some(None);
                    }
                }
                "--permission-mode" => {
                    i += 1;
                    if i < args.len() {
                        cli.permission_mode = Some(args[i].to_ascii_lowercase());
                    }
                }
                _ => {}
            }
            i += 1;
        }

        if cli.version {
            println!("osagent {}", env!("CARGO_PKG_VERSION"));
            std::process::exit(0);
        }

        cli
    }

    pub fn log_dir(&self) -> PathBuf {
        let base = if let Some(ref profile) = self.profile {
            home_dir().join(".osa").join("profiles").join(profile)
        } else {
            home_dir().join(".osa")
        };
        base.join("logs")
    }
}
