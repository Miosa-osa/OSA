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
#[derive(Debug)]
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
    /// `--model <name>`: run THIS session on `<name>`, overriding whatever
    /// `~/.osa/config.toml` / the global default says. Applied session-scoped
    /// once the session id exists (see `App::apply_startup_model_override`).
    pub model: Option<String>,
    /// `--provider <name>`: pair with (or stand alone from) `--model`. When
    /// omitted and `--model` is set, the backend infers the owning provider.
    pub provider: Option<String>,
    /// Everything after a bare `--`. Reserved passthrough; nothing consumes it
    /// today, but collecting it keeps `--` from tripping the unknown-flag error.
    pub passthrough: Vec<String>,
}

/// Usage text. Kept in sync with `print_help` in `scripts/install.sh`; this is
/// what an unknown flag prints, so it must list every flag we actually accept.
pub const USAGE: &str = "\
osagent — the OSA terminal UI

Usage: osa [command] [flags]

Flags:
  --model <name>            Run this session on <name> (overrides saved config)
  --provider <name>         Provider for --model (inferred when omitted)
  --permission-mode <mode>  ask · auto-edit · plan · auto · overdrive · bypass
  --profile <name>          Use the named ~/.osa/profiles/<name> profile
  -c, --continue            Resume this folder's newest session
  --resume [id]             Resume a session (no id opens the picker)
  --overdrive, --yolo       Full auto — skip all tool permission prompts
  --dev                     Developer mode
  --setup                   Run the setup wizard
  --no-color                Disable colored output
  -V, --version             Print the version and exit
  -h, --help                Show this help and exit
";

/// A CLI parse outcome that the caller turns into a process exit.
#[derive(Debug, PartialEq, Eq)]
pub enum CliError {
    /// An argument we do not recognise. Never silently ignored: a typo or an
    /// unsupported flag must NOT look like it worked.
    UnknownArg(String),
    /// A flag that requires a value was given none.
    MissingValue(&'static str),
}

impl CliError {
    pub fn message(&self) -> String {
        match self {
            CliError::UnknownArg(a) => format!("error: unknown argument '{}'", a),
            CliError::MissingValue(flag) => {
                format!("error: {} requires a value", flag)
            }
        }
    }
}

impl Cli {
    fn empty() -> Self {
        Self {
            profile: None,
            dev: false,
            setup: false,
            no_color: false,
            version: false,
            dangerously_skip_permissions: false,
            continue_last: false,
            resume: None,
            permission_mode: None,
            model: None,
            provider: None,
            passthrough: Vec::new(),
        }
    }

    /// Pure parser over an explicit argv tail (no `argv[0]`), so the flag table
    /// is unit-testable without spawning a process.
    pub fn parse_from<I, S>(argv: I) -> Result<Self, CliError>
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        let mut cli = Self::empty();
        let args: Vec<String> = argv.into_iter().map(Into::into).collect();
        let mut i = 0;
        while i < args.len() {
            match args[i].as_str() {
                "--profile" => {
                    i += 1;
                    match args.get(i) {
                        Some(v) => cli.profile = Some(v.clone()),
                        None => return Err(CliError::MissingValue("--profile")),
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
                    match args.get(i) {
                        Some(v) => cli.permission_mode = Some(v.to_ascii_lowercase()),
                        None => return Err(CliError::MissingValue("--permission-mode")),
                    }
                }
                "--model" | "-m" => {
                    i += 1;
                    match args.get(i) {
                        Some(v) if !v.is_empty() => cli.model = Some(v.clone()),
                        _ => return Err(CliError::MissingValue("--model")),
                    }
                }
                "--provider" => {
                    i += 1;
                    match args.get(i) {
                        Some(v) if !v.is_empty() => cli.provider = Some(v.clone()),
                        _ => return Err(CliError::MissingValue("--provider")),
                    }
                }
                // Everything after a bare `--` is passthrough, not our business.
                "--" => {
                    cli.passthrough = args[i + 1..].to_vec();
                    break;
                }
                // FAIL LOUDLY. The old `_ => {}` swallowed typos and unsupported
                // flags, so OSA appeared to work while ignoring what was asked.
                other => return Err(CliError::UnknownArg(other.to_string())),
            }
            i += 1;
        }

        Ok(cli)
    }

    pub fn parse_args() -> Self {
        let args: Vec<String> = std::env::args().skip(1).collect();

        // `--help` short-circuits before validation so a user who is lost gets
        // the usage text rather than an error about the rest of their line.
        if args.iter().any(|a| a == "--help" || a == "-h") {
            print!("{}", USAGE);
            std::process::exit(0);
        }

        let cli = match Self::parse_from(args) {
            Ok(cli) => cli,
            Err(e) => {
                eprintln!("{}", e.message());
                eprintln!();
                eprint!("{}", USAGE);
                std::process::exit(2);
            }
        };

        if cli.version {
            // Single source of truth (tag-stamped OSA_VERSION, else Cargo semver).
            println!("osagent {}", crate::config::osa_version_display());
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

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(args: &[&str]) -> Cli {
        Cli::parse_from(args.iter().copied()).expect("should parse")
    }

    // === FIX 1: unknown args must NOT be silently swallowed ===

    #[test]
    fn unknown_long_flag_is_an_error() {
        let err = Cli::parse_from(["--nope"]).unwrap_err();
        assert_eq!(err, CliError::UnknownArg("--nope".into()));
        assert!(err.message().contains("--nope"));
        assert!(err.message().starts_with("error: unknown argument"));
    }

    #[test]
    fn typo_of_a_real_flag_is_an_error() {
        // The exact class of bug this fixes: `--mdoel gpt-4` used to run the
        // configured model while looking like it honoured the request.
        assert!(Cli::parse_from(["--mdoel", "gpt-4"]).is_err());
        assert!(Cli::parse_from(["--overdrve"]).is_err());
    }

    #[test]
    fn unknown_short_flag_is_an_error() {
        assert!(Cli::parse_from(["-x"]).is_err());
    }

    #[test]
    fn stray_positional_is_an_error() {
        // Nothing consumes positionals, so accepting them silently is the bug.
        assert!(Cli::parse_from(["do-the-thing"]).is_err());
    }

    #[test]
    fn unknown_flag_after_valid_flags_still_errors() {
        assert!(Cli::parse_from(["--dev", "--no-color", "--bogus"]).is_err());
    }

    #[test]
    fn usage_text_lists_every_accepted_flag() {
        for flag in [
            "--model",
            "--provider",
            "--permission-mode",
            "--profile",
            "--continue",
            "--resume",
            "--overdrive",
            "--yolo",
            "--dev",
            "--setup",
            "--no-color",
            "--version",
            "--help",
        ] {
            assert!(USAGE.contains(flag), "USAGE is missing {}", flag);
        }
    }

    // === Every pre-existing flag still parses (no regressions) ===

    #[test]
    fn no_args_parses_to_defaults() {
        let cli = parse(&[]);
        assert!(cli.profile.is_none());
        assert!(!cli.dev);
        assert!(!cli.setup);
        assert!(!cli.no_color);
        assert!(!cli.version);
        assert!(!cli.dangerously_skip_permissions);
        assert!(!cli.continue_last);
        assert!(cli.resume.is_none());
        assert!(cli.permission_mode.is_none());
        assert!(cli.model.is_none());
        assert!(cli.provider.is_none());
    }

    #[test]
    fn profile_takes_a_value() {
        assert_eq!(parse(&["--profile", "work"]).profile.as_deref(), Some("work"));
        assert_eq!(
            Cli::parse_from(["--profile"]).unwrap_err(),
            CliError::MissingValue("--profile")
        );
    }

    #[test]
    fn boolean_flags_parse() {
        assert!(parse(&["--dev"]).dev);
        assert!(parse(&["--setup"]).setup);
        assert!(parse(&["--no-color"]).no_color);
        assert!(parse(&["--version"]).version);
        assert!(parse(&["-V"]).version);
    }

    #[test]
    fn overdrive_and_its_aliases_parse() {
        for a in ["--overdrive", "--yolo", "--dangerously-skip-permissions"] {
            assert!(
                parse(&[a]).dangerously_skip_permissions,
                "{} did not set overdrive",
                a
            );
        }
    }

    #[test]
    fn continue_parses_in_both_spellings() {
        assert!(parse(&["-c"]).continue_last);
        assert!(parse(&["--continue"]).continue_last);
    }

    #[test]
    fn resume_with_and_without_an_id() {
        assert_eq!(parse(&["--resume", "sess-1"]).resume, Some(Some("sess-1".into())));
        assert_eq!(parse(&["--resume"]).resume, Some(None));
        // A following flag must not be eaten as the session id.
        let cli = parse(&["--resume", "--dev"]);
        assert_eq!(cli.resume, Some(None));
        assert!(cli.dev);
    }

    #[test]
    fn permission_mode_is_lowercased() {
        assert_eq!(
            parse(&["--permission-mode", "Plan"]).permission_mode.as_deref(),
            Some("plan")
        );
        assert_eq!(
            Cli::parse_from(["--permission-mode"]).unwrap_err(),
            CliError::MissingValue("--permission-mode")
        );
    }

    #[test]
    fn the_whole_legacy_flag_set_parses_together() {
        let cli = parse(&[
            "--profile",
            "work",
            "--dev",
            "--setup",
            "--no-color",
            "--overdrive",
            "--continue",
            "--resume",
            "abc",
            "--permission-mode",
            "auto",
        ]);
        assert_eq!(cli.profile.as_deref(), Some("work"));
        assert!(cli.dev && cli.setup && cli.no_color);
        assert!(cli.dangerously_skip_permissions);
        assert!(cli.continue_last);
        assert_eq!(cli.resume, Some(Some("abc".into())));
        assert_eq!(cli.permission_mode.as_deref(), Some("auto"));
    }

    // === FIX 2: --model / --provider ===

    #[test]
    fn model_and_provider_parse() {
        let cli = parse(&["--model", "qwen3:8b", "--provider", "ollama"]);
        assert_eq!(cli.model.as_deref(), Some("qwen3:8b"));
        assert_eq!(cli.provider.as_deref(), Some("ollama"));
    }

    #[test]
    fn model_alone_parses_with_no_provider() {
        let cli = parse(&["--model", "claude-sonnet-4-6"]);
        assert_eq!(cli.model.as_deref(), Some("claude-sonnet-4-6"));
        assert!(cli.provider.is_none());
    }

    #[test]
    fn short_model_alias_parses() {
        assert_eq!(parse(&["-m", "gpt-oss:20b"]).model.as_deref(), Some("gpt-oss:20b"));
    }

    #[test]
    fn model_and_provider_require_values() {
        assert_eq!(
            Cli::parse_from(["--model"]).unwrap_err(),
            CliError::MissingValue("--model")
        );
        assert_eq!(
            Cli::parse_from(["--provider"]).unwrap_err(),
            CliError::MissingValue("--provider")
        );
        // Empty string is a missing value, not a model named "".
        assert!(Cli::parse_from(["--model", ""]).is_err());
    }

    #[test]
    fn model_composes_with_the_other_launch_flags() {
        let cli = parse(&["--continue", "--model", "llama3.1:8b", "--overdrive"]);
        assert!(cli.continue_last);
        assert!(cli.dangerously_skip_permissions);
        assert_eq!(cli.model.as_deref(), Some("llama3.1:8b"));
    }

    // === `--` passthrough ===

    #[test]
    fn double_dash_collects_the_rest_instead_of_erroring() {
        let cli = parse(&["--dev", "--", "--not-ours", "positional"]);
        assert!(cli.dev);
        assert_eq!(cli.passthrough, vec!["--not-ours", "positional"]);
    }
}
