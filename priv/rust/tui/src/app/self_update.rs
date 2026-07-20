//! In-app self-update (`/update`).
//!
//! Shells out to the installed `osa` launcher's rollback-safe staged updater
//! (`osa update --staged`) so a running OSA can update itself without freezing
//! the UI. The staged flow stages a fresh build, boot-probes it, and atomically
//! swaps `$OSA_HOME/current` — the running process keeps the OLD version until
//! the next launch, so the swap is non-disruptive and this command never tries
//! to hot-swap the live binary. On success we tell the user to relaunch.
//!
//! Streaming: the child's stdout is read line-by-line; recognised phase lines
//! (Staging / Building / Health check / Switching …) are surfaced as progress
//! notices so the user sees work happening instead of a frozen screen. When the
//! terminal success / "already up to date" line is seen we record the outcome
//! and kill the child — the launcher would otherwise fall through to LAUNCHING a
//! fresh OSA, which we must not do from inside a running TUI.
//!
//! Everything network/process is confined here; the parsing that turns update
//! output into a user-facing message + level is a set of pure functions with
//! unit tests (no process is ever spawned in a test).

use tokio::io::{AsyncBufReadExt, AsyncReadExt, BufReader};
use tokio::process::Command;

use super::App;
use crate::components::toast::ToastLevel;
use crate::event::backend::BackendEvent;
use crate::event::Event;

/// Severity of a self-update notice, kept independent of `ToastLevel` so the
/// event type can derive `Debug` (ToastLevel does not) and so the parsing layer
/// has no UI dependency.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum NoticeLevel {
    Info,
    Success,
    Error,
}

impl NoticeLevel {
    fn to_toast(self) -> ToastLevel {
        match self {
            NoticeLevel::Info => ToastLevel::Info,
            NoticeLevel::Success => ToastLevel::Success,
            NoticeLevel::Error => ToastLevel::Error,
        }
    }
}

/// A message sent from the background update task back to the UI thread.
#[derive(Debug, Clone)]
pub(crate) enum SelfUpdateEvent {
    /// A phase transition (Staging/Building/…). Surfaced as a short info notice.
    Progress(String),
    /// The terminal outcome: final user-facing message + severity.
    Result { message: String, level: NoticeLevel },
}

/// The parsed meaning of an update terminal line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ParsedUpdate {
    pub message: String,
    pub level: NoticeLevel,
    /// True when a new version was actually installed (vs already up to date).
    pub updated: bool,
}

impl App {
    /// Handle `/update`: kick off the staged self-update without blocking input.
    pub(crate) fn start_self_update(&mut self) {
        // Initial toast + a durable scrollback line so screen-reader users also
        // get the "started" signal.
        self.toasts.push(
            "Updating OSA...".into(),
            crate::components::toast::ToastLevel::Info,
        );
        self.chat.add_system_message(
            "Updating OSA (staged, rollback-safe). This can take about a minute; input stays live.",
            "info",
        );

        let tx = self.event_tx.clone();
        tokio::spawn(async move {
            run_self_update(tx).await;
        });
    }

    /// Apply a `SelfUpdateEvent` produced by the background task.
    pub(crate) fn handle_self_update(&mut self, ev: SelfUpdateEvent) {
        match ev {
            SelfUpdateEvent::Progress(msg) => {
                // Phase transitions only (not every line), so this stays a few
                // toasts rather than a flood.
                self.toasts
                    .push(msg, crate::components::toast::ToastLevel::Info);
            }
            SelfUpdateEvent::Result { message, level } => {
                self.toasts.push(message.clone(), level.to_toast());
                let kind = match level {
                    NoticeLevel::Error => "error",
                    _ => "info",
                };
                // Durable scrollback record with the version + relaunch note.
                self.chat.add_system_message(&message, kind);
            }
        }
    }
}

/// Outcome of a single launcher invocation.
enum RunOutcome {
    /// Reached a terminal update line and parsed it.
    Done(ParsedUpdate),
    /// The launcher can't do a staged update (no helper) — retry in-place.
    NeedsFallback,
    /// The `osa` launcher is not on PATH.
    NotFound,
    /// Any other failure (non-zero exit / stderr), with a message.
    Failed(String),
}

/// Drive the update: try the staged (rollback-safe) path first, fall back to the
/// in-place path if the launcher can't stage, and report the result.
async fn run_self_update(tx: tokio::sync::mpsc::UnboundedSender<Event>) {
    let outcome = match run_osa_update(&tx, true).await {
        RunOutcome::NeedsFallback => {
            let _ = tx.send(Event::Backend(BackendEvent::SelfUpdate(
                SelfUpdateEvent::Progress(
                    "Staged update unavailable, updating in place...".into(),
                ),
            )));
            run_osa_update(&tx, false).await
        }
        other => other,
    };

    let (message, level) = match outcome {
        RunOutcome::Done(parsed) => (parsed.message, parsed.level),
        RunOutcome::NotFound => (
            "Update failed: the `osa` launcher is not on your PATH. \
             This looks like a source checkout — run `osa update` (or `bin/osa update`) \
             from a terminal instead."
                .to_string(),
            NoticeLevel::Error,
        ),
        RunOutcome::NeedsFallback => (
            "Update failed: could not stage or apply an update.".to_string(),
            NoticeLevel::Error,
        ),
        RunOutcome::Failed(err) => (format!("Update failed: {}", err), NoticeLevel::Error),
    };

    let _ = tx.send(Event::Backend(BackendEvent::SelfUpdate(
        SelfUpdateEvent::Result { message, level },
    )));
}

/// Spawn `osa update [--staged]`, stream phase lines, and detect the terminal
/// outcome. On a terminal success line the child is killed so the launcher never
/// falls through to relaunching OSA.
async fn run_osa_update(
    tx: &tokio::sync::mpsc::UnboundedSender<Event>,
    staged: bool,
) -> RunOutcome {
    let mut cmd = Command::new("osa");
    cmd.arg("update");
    if staged {
        cmd.arg("--staged");
    }
    cmd.stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);

    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return RunOutcome::NotFound,
        Err(e) => return RunOutcome::Failed(e.to_string()),
    };

    // Drain stderr concurrently so a failing child's diagnostics are available
    // and the pipe never fills and blocks the child.
    let stderr = child.stderr.take();
    let stderr_task = tokio::spawn(async move {
        let mut buf = String::new();
        if let Some(mut e) = stderr {
            let _ = e.read_to_string(&mut buf).await;
        }
        buf
    });

    let stdout = match child.stdout.take() {
        Some(s) => s,
        None => return RunOutcome::Failed("could not capture update output".into()),
    };
    let mut lines = BufReader::new(stdout).lines();

    let mut needs_fallback = false;
    let mut terminal: Option<ParsedUpdate> = None;

    while let Ok(Some(raw)) = lines.next_line().await {
        let line = strip_ansi(&raw);
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        if is_fallback_signal(trimmed) {
            needs_fallback = true;
            continue;
        }
        if let Some(label) = phase_label(trimmed) {
            let _ = tx.send(Event::Backend(BackendEvent::SelfUpdate(
                SelfUpdateEvent::Progress(label),
            )));
            continue;
        }
        if let Some(parsed) = parse_update_result(trimmed) {
            terminal = Some(parsed);
            // The launcher would now fall through to launching a fresh OSA;
            // the staged swap is already durable, so kill the child to stop it.
            let _ = child.start_kill();
            break;
        }
    }

    // Reap the child and collect stderr regardless of how we exited the loop.
    let status = child.wait().await;
    let stderr_out = stderr_task.await.unwrap_or_default();

    if let Some(parsed) = terminal {
        return RunOutcome::Done(parsed);
    }
    if needs_fallback && staged {
        return RunOutcome::NeedsFallback;
    }

    match status {
        Ok(s) if s.success() => RunOutcome::Failed(
            "the updater exited without reporting a result. Run `osa update` from a terminal.".into(),
        ),
        _ => {
            let msg = stderr_out
                .lines()
                .map(strip_ansi)
                .map(|l| l.trim().to_string())
                .filter(|l| !l.is_empty())
                .last()
                .unwrap_or_else(|| "the updater exited with an error".to_string());
            RunOutcome::Failed(msg)
        }
    }
}

/// True when the launcher told us it cannot do a staged update (missing helper),
/// so the caller should retry the plain in-place path.
fn is_fallback_signal(line: &str) -> bool {
    let l = line.to_ascii_lowercase();
    l.contains("cannot do a staged update") || l.contains("osa-update not found")
}

/// Map a launcher phase / progress line to a short user-facing label, or `None`
/// if the line isn't a phase transition worth surfacing.
fn phase_label(line: &str) -> Option<String> {
    // Staged phases look like "[3/5] Building (~60s)". Surface the title.
    if let Some(rest) = line.strip_prefix('[') {
        if let Some(idx) = rest.find(']') {
            let title = rest[idx + 1..].trim();
            if !title.is_empty() {
                return Some(title.to_string());
            }
        }
    }
    // In-place path: a plain "Checking for updates..." progress line.
    let l = line.to_ascii_lowercase();
    if l.contains("checking for updates") {
        return Some("Checking for updates...".into());
    }
    // Staged intermediate confirmations worth showing.
    if l.starts_with("staged v") || l == "build succeeded" || l == "boots cleanly" {
        return Some(line.to_string());
    }
    None
}

/// Parse a terminal update line into a user-facing message + level.
///
/// Recognises both the staged launcher phrasing ("Already up to date: v1.0.13",
/// "Updated v1.0.13 -> v1.0.14") and the simpler generic phrasing
/// ("Already up to date (1.0.13)", "Updated to 1.0.14"). Returns `None` for any
/// line that is not a terminal outcome. Pure — unit-tested.
pub(crate) fn parse_update_result(line: &str) -> Option<ParsedUpdate> {
    let clean = strip_ansi(line);
    let trimmed = clean.trim();
    let lower = trimmed.to_ascii_lowercase();

    if lower.contains("already up to date") || lower.contains("already up-to-date") {
        let msg = match last_version(trimmed) {
            Some(v) => format!("OSA is already up to date ({}).", v),
            None => "OSA is already up to date.".to_string(),
        };
        return Some(ParsedUpdate {
            message: msg,
            level: NoticeLevel::Info,
            updated: false,
        });
    }

    // "Updated ..." (but not "Updating"/"Update failed"). Require a version so a
    // stray "updated" word in prose isn't treated as the outcome.
    if (lower.starts_with("updated") || lower.contains(" updated "))
        && !lower.contains("fail")
    {
        if let Some(v) = last_version(trimmed) {
            return Some(ParsedUpdate {
                message: format!("Updated to {}. Relaunch OSA to apply.", v),
                level: NoticeLevel::Success,
                updated: true,
            });
        }
    }

    None
}

/// Extract the LAST `vX.Y.Z` / `X.Y.Z` version token in a line, normalised to a
/// leading `v`. For "Updated v1.0.13 -> v1.0.14" this yields the target
/// (`v1.0.14`); for "Updated to 1.0.14" it yields `v1.0.14`.
fn last_version(line: &str) -> Option<String> {
    let mut found: Option<String> = None;
    // Split on any non-version character so "(1.0.13)" and "v1.0.14," both work.
    for tok in line.split(|c: char| !(c.is_ascii_digit() || c == '.' || c == 'v' || c == 'V')) {
        let t = tok.trim_start_matches(['v', 'V']);
        if is_semver_core(t) {
            found = Some(format!("v{}", t));
        }
    }
    found
}

/// True for a bare `major.minor.patch` numeric core (no prefix/suffix).
fn is_semver_core(s: &str) -> bool {
    let parts: Vec<&str> = s.split('.').collect();
    parts.len() == 3
        && parts
            .iter()
            .all(|p| !p.is_empty() && p.chars().all(|c| c.is_ascii_digit()))
}

/// Remove ANSI SGR escape sequences (colour codes) from launcher output so the
/// text can be matched and shown cleanly.
fn strip_ansi(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\u{1b}' {
            // ESC — skip a CSI sequence: '[' … final byte in @..~ range.
            if chars.peek() == Some(&'[') {
                chars.next();
                for c2 in chars.by_ref() {
                    if ('@'..='~').contains(&c2) {
                        break;
                    }
                }
            }
            continue;
        }
        out.push(c);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_generic_already_up_to_date() {
        let p = parse_update_result("Already up to date (1.0.13)").expect("recognised");
        assert_eq!(p.level, NoticeLevel::Info);
        assert!(!p.updated);
        assert_eq!(p.message, "OSA is already up to date (v1.0.13).");
    }

    #[test]
    fn parses_launcher_already_up_to_date_with_ansi_and_prefix() {
        let line = "\u{1b}[32m\u{2713}\u{1b}[0m Already up to date: v1.0.13 (abc123)";
        let p = parse_update_result(line).expect("recognised");
        assert_eq!(p.level, NoticeLevel::Info);
        assert!(!p.updated);
        // The rev "abc123" is not a semver core, so the version wins.
        assert_eq!(p.message, "OSA is already up to date (v1.0.13).");
    }

    #[test]
    fn parses_generic_updated_to() {
        let p = parse_update_result("Updated to 1.0.14").expect("recognised");
        assert_eq!(p.level, NoticeLevel::Success);
        assert!(p.updated);
        assert_eq!(p.message, "Updated to v1.0.14. Relaunch OSA to apply.");
    }

    #[test]
    fn parses_launcher_updated_range_picks_target() {
        let p = parse_update_result("Updated v1.0.13 -> v1.0.14 (aaa -> bbb)").expect("recognised");
        assert_eq!(p.level, NoticeLevel::Success);
        assert!(p.updated);
        assert_eq!(p.message, "Updated to v1.0.14. Relaunch OSA to apply.");
    }

    #[test]
    fn non_terminal_lines_are_ignored() {
        assert!(parse_update_result("Building (~60s)").is_none());
        assert!(parse_update_result("Updating OSA...").is_none());
        assert!(parse_update_result("Update failed. Current install untouched.").is_none());
        assert!(parse_update_result("").is_none());
    }

    #[test]
    fn phase_labels_are_extracted() {
        assert_eq!(phase_label("[3/5] Building (~60s)").as_deref(), Some("Building (~60s)"));
        assert_eq!(phase_label("[2/5] Staging abc123").as_deref(), Some("Staging abc123"));
        assert_eq!(
            phase_label("Checking for updates...").as_deref(),
            Some("Checking for updates...")
        );
        assert!(phase_label("some unrelated line").is_none());
    }

    #[test]
    fn fallback_signal_detected() {
        assert!(is_fallback_signal(
            "bin/osa-update not found, cannot do a staged update."
        ));
        assert!(!is_fallback_signal("Building (~60s)"));
    }

    #[test]
    fn strip_ansi_removes_colour_codes() {
        assert_eq!(strip_ansi("\u{1b}[32m\u{2713}\u{1b}[0m ok"), "\u{2713} ok");
    }
}
