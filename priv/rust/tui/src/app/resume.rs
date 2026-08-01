//! Session resume: the exit hint the user copy-pastes, and the process outcome
//! that carries it (or a loud failure) back out to `main`.
//!
//! Two halves, both deliberately PURE so they are testable without a terminal or
//! a backend:
//!
//! * [`resume_command`] renders the command line printed on exit. It replays the
//!   *mode* flags the session was launched with, so copy-pasting the line puts
//!   the user back in the same mode. A bare `osa resume <id>` after an
//!   `--overdrive` run would silently drop them back to prompting, which is the
//!   opposite of what "resume this session" means.
//! * [`ExitOutcome`] is what `App::run` hands `main`. The hint must be printed
//!   AFTER the terminal is restored (the inline viewport is repainted on
//!   teardown, so anything written before it is wiped), and a bad session id
//!   must leave through the `Failed` arm with a non-zero exit — never as a
//!   silently-empty fresh conversation.

use crate::config::cli::Cli;

/// The launch flags worth replaying in the printed resume command.
///
/// Only flags that change *how the session behaves* are replayed. `--dev`,
/// `--setup`, `--no-color` and friends are per-invocation ergonomics, not
/// session identity, so they are deliberately dropped: re-running them is the
/// user's call, and echoing them back would make the line longer than the thing
/// it is trying to make easy.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct LaunchMode {
    /// `--overdrive` / `--yolo` / `--dangerously-skip-permissions`.
    pub overdrive: bool,
    /// `--permission-mode <mode>`; suppressed when `overdrive` is set, since
    /// overdrive already implies bypass and printing both is noise.
    pub permission_mode: Option<String>,
    /// `--profile <name>` — a different profile is a different config/home, so
    /// dropping it would resume against the wrong backend state.
    pub profile: Option<String>,
    /// `--model <name>`.
    pub model: Option<String>,
    /// `--provider <name>`.
    pub provider: Option<String>,
}

impl LaunchMode {
    /// Capture the replay-worthy flags from the parsed CLI.
    pub fn from_cli(cli: &Cli) -> Self {
        Self {
            overdrive: cli.dangerously_skip_permissions,
            permission_mode: cli.permission_mode.clone(),
            profile: cli.profile.clone(),
            model: cli.model.clone(),
            provider: cli.provider.clone(),
        }
    }
}

/// Render the copy-pasteable resume command for `session_id`.
///
/// Flags go BEFORE the `resume` subcommand (`osa --overdrive resume <id>`),
/// matching the ordering the launcher accepts and the one the user asked for.
pub fn resume_command(session_id: &str, mode: &LaunchMode) -> String {
    let mut parts = vec!["osa".to_string()];
    if let Some(profile) = mode.profile.as_deref().filter(|p| !p.is_empty()) {
        parts.push("--profile".into());
        parts.push(profile.to_string());
    }
    if mode.overdrive {
        parts.push("--overdrive".into());
    } else if let Some(pm) = mode.permission_mode.as_deref().filter(|p| !p.is_empty()) {
        parts.push("--permission-mode".into());
        parts.push(pm.to_string());
    }
    if let Some(provider) = mode.provider.as_deref().filter(|p| !p.is_empty()) {
        parts.push("--provider".into());
        parts.push(provider.to_string());
    }
    if let Some(model) = mode.model.as_deref().filter(|m| !m.is_empty()) {
        parts.push("--model".into());
        parts.push(model.to_string());
    }
    parts.push("resume".into());
    parts.push(session_id.to_string());
    parts.join(" ")
}

/// The two-line block printed to the terminal after teardown:
///
/// ```text
///                                            ← blank line from restore_terminal
/// Resume this session with:
/// osa --overdrive resume session-1785539672538-b5473d40b767
/// ```
///
/// The separating blank line is NOT part of this string: `restore_terminal()`
/// already writes a `\r\n` to land the shell prompt below the inline viewport,
/// and the event loop clears the chrome before it, so the block starts on a
/// clean line. Adding another `\n` here produced two blank lines instead of the
/// one Claude Code shows.
pub fn resume_hint_block(session_id: &str, mode: &LaunchMode) -> String {
    format!(
        "Resume this session with:\n{}\n",
        resume_command(session_id, mode)
    )
}

/// How the TUI process ended, carried from `App::run` out to `main`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ExitOutcome {
    /// Normal quit. `Some(block)` is printed to stdout after the terminal is
    /// restored; `None` when there is nothing worth resuming (an empty session
    /// the user opened and immediately quit).
    Normal(Box<Option<String>>),
    /// A launch-time failure that must be LOUD: printed to stderr, exit code 2.
    /// Today this is only "the session id you asked to resume does not exist",
    /// which previously degraded into a blank conversation that looked fine.
    Failed(String),
}

impl ExitOutcome {
    pub fn normal(hint: Option<String>) -> Self {
        ExitOutcome::Normal(Box::new(hint))
    }
}

/// Decide whether a session is worth advertising a resume command for.
///
/// A session with no user turn has nothing to come back to, and printing a
/// resume line for it would be a lie: resuming it restores an empty transcript.
pub fn should_print_hint(session_id: &str, had_user_turn: bool) -> bool {
    had_user_turn && !session_id.is_empty()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mode() -> LaunchMode {
        LaunchMode::default()
    }

    #[test]
    fn plain_session_renders_a_bare_resume_command() {
        assert_eq!(resume_command("sess-1", &mode()), "osa resume sess-1");
    }

    #[test]
    fn overdrive_is_replayed_before_the_subcommand() {
        // The exact ordering the launcher must accept, and the one the user
        // asked for: `osa --overdrive resume <id>`.
        let m = LaunchMode { overdrive: true, ..mode() };
        assert_eq!(resume_command("sess-1", &m), "osa --overdrive resume sess-1");
    }

    #[test]
    fn overdrive_wins_over_permission_mode() {
        // Overdrive already implies bypass; printing both is noise.
        let m = LaunchMode {
            overdrive: true,
            permission_mode: Some("plan".into()),
            ..mode()
        };
        assert_eq!(resume_command("s", &m), "osa --overdrive resume s");
    }

    #[test]
    fn permission_mode_is_replayed_when_not_in_overdrive() {
        let m = LaunchMode {
            permission_mode: Some("plan".into()),
            ..mode()
        };
        assert_eq!(resume_command("s", &m), "osa --permission-mode plan resume s");
    }

    #[test]
    fn profile_model_and_provider_are_replayed() {
        let m = LaunchMode {
            profile: Some("work".into()),
            model: Some("qwen3:8b".into()),
            provider: Some("ollama".into()),
            ..mode()
        };
        assert_eq!(
            resume_command("s", &m),
            "osa --profile work --provider ollama --model qwen3:8b resume s"
        );
    }

    #[test]
    fn empty_flag_values_are_not_replayed() {
        let m = LaunchMode {
            profile: Some(String::new()),
            model: Some(String::new()),
            provider: Some(String::new()),
            permission_mode: Some(String::new()),
            overdrive: false,
        };
        assert_eq!(resume_command("s", &m), "osa resume s");
    }

    #[test]
    fn hint_block_matches_the_requested_shape() {
        let block = resume_hint_block("sess-1", &mode());
        assert_eq!(block, "Resume this session with:\nosa resume sess-1\n");
        // Label on its own line, command on its own line, trailing newline so
        // the shell prompt returns on a fresh row. The separating blank line
        // above comes from `restore_terminal`, not from here.
        let lines: Vec<&str> = block.split('\n').collect();
        assert_eq!(lines[0], "Resume this session with:");
        assert_eq!(lines[1], "osa resume sess-1");
        assert_eq!(lines[2], "");
    }

    #[test]
    fn launch_mode_is_captured_from_the_cli() {
        let cli = Cli::parse_from([
            "--overdrive",
            "--profile",
            "work",
            "--model",
            "m",
            "--provider",
            "p",
        ])
        .unwrap();
        let m = LaunchMode::from_cli(&cli);
        assert!(m.overdrive);
        assert_eq!(m.profile.as_deref(), Some("work"));
        assert_eq!(m.model.as_deref(), Some("m"));
        assert_eq!(m.provider.as_deref(), Some("p"));
    }

    #[test]
    fn every_overdrive_alias_replays_as_the_canonical_flag() {
        for alias in ["--overdrive", "--yolo", "--dangerously-skip-permissions"] {
            let cli = Cli::parse_from([alias]).unwrap();
            let m = LaunchMode::from_cli(&cli);
            assert_eq!(resume_command("s", &m), "osa --overdrive resume s", "{}", alias);
        }
    }

    #[test]
    fn no_hint_without_a_user_turn() {
        assert!(!should_print_hint("sess-1", false));
        assert!(should_print_hint("sess-1", true));
        // No session id resolved at all: nothing to advertise.
        assert!(!should_print_hint("", true));
    }

    #[test]
    fn failed_outcome_is_distinct_from_normal() {
        assert_ne!(
            ExitOutcome::Failed("nope".into()),
            ExitOutcome::normal(Some("nope".into()))
        );
    }
}
