//! Native OS notification channel — macOS Notification Centre / Linux libnotify.
//!
//! The other channels in this module talk to the *terminal*: a BEL, an OSC 9
//! escape, a sound. They reach someone whose terminal is on screen. A user who
//! has switched to another Space, or another machine's display, sees none of
//! it — which is precisely the person a turn-complete notification is for.
//!
//! ## macOS: why `terminal-notifier` is preferred
//!
//! `osascript -e 'display notification'` is attributed by macOS to the script
//! host, so the toast carries Script Editor's icon, cannot be clicked through
//! to anything, and stacks one entry per call. `terminal-notifier` supports
//! `-group` (replace the previous OSA toast rather than piling up) and
//! `-sender` (borrow an app's identity, supplying both icon and click target).
//!
//! It is optional. Without it we fall back to `osascript`, which still
//! delivers — it just looks like it always did.
//!
//! Set `OSA_NOTIFY_SENDER` to a bundle id (`com.github.wez.wezterm`,
//! `com.apple.Terminal`, …) to get click-to-focus on that app.
//!
//! Two flags are emitted for it, because they age differently. `-activate`
//! names the app to raise when the toast is clicked and is still honoured.
//! `-sender` additionally borrows that app's *identity*, which is what would
//! supply its icon — recent macOS validates the posting bundle and ignores the
//! masquerade, so the toast shows terminal-notifier's own icon instead. That is
//! still better than Script Editor's scroll, and `-sender` costs nothing where
//! it does work, so both are sent.

use std::process::{Command, Stdio};

/// Group id so successive OSA toasts occupy one rolling slot.
const GROUP: &str = "com.miosa.osa";

/// Which native notifier this machine actually has.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Notifier {
    /// macOS, `terminal-notifier` on PATH — icon, grouping, click target.
    TerminalNotifier(String),
    /// macOS fallback — always present, but unbranded and unclickable.
    Osascript(String),
    /// Linux libnotify.
    NotifySend(String),
}

/// Resolve a binary on `PATH` without pulling in a `which` crate.
fn find_exe(name: &str) -> Option<String> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|dir| dir.join(name))
        .find(|candidate| candidate.is_file())
        .map(|p| p.to_string_lossy().into_owned())
}

/// The best notifier available here, or `None` when the platform has none.
pub fn notifier() -> Option<Notifier> {
    if cfg!(target_os = "macos") {
        if let Some(p) = find_exe("terminal-notifier") {
            return Some(Notifier::TerminalNotifier(p));
        }
        return find_exe("osascript").map(Notifier::Osascript);
    }
    if cfg!(target_os = "linux") {
        return find_exe("notify-send").map(Notifier::NotifySend);
    }
    None
}

/// Whether a native notification can be delivered on this machine.
pub fn available() -> bool {
    notifier().is_some()
}

/// `-sender <bundle-id>` when the operator named one. Clicking the toast then
/// raises that app, and its icon replaces Script Editor's.
fn sender_args() -> Vec<String> {
    match std::env::var("OSA_NOTIFY_SENDER") {
        Ok(id) if !id.trim().is_empty() => vec!["-sender".to_string(), id],
        _ => Vec::new(),
    }
}

/// argv for `terminal-notifier`. No shell is involved, so title/message pass
/// through as literal arguments — nothing to escape, nothing to inject into.
pub fn terminal_notifier_args(title: &str, message: &str, sender: Option<&str>) -> Vec<String> {
    let mut args = vec![
        "-title".to_string(),
        title.to_string(),
        "-subtitle".to_string(),
        "OSA".to_string(),
        "-message".to_string(),
        message.to_string(),
        "-group".to_string(),
        GROUP.to_string(),
    ];
    if let Some(id) = sender.filter(|s| !s.trim().is_empty()) {
        // `-activate` is the one that reliably survives on current macOS.
        args.push("-activate".to_string());
        args.push(id.to_string());
        args.push("-sender".to_string());
        args.push(id.to_string());
    }
    args
}

/// AppleScript for the fallback path.
///
/// This one *is* a script, so a quote in a model-authored title would end the
/// string literal and the remainder would be evaluated. Escape backslashes
/// first — doing it second would re-escape the ones just introduced.
pub fn osascript_script(title: &str, message: &str) -> String {
    let esc = |s: &str| s.replace('\\', "\\\\").replace('"', "\\\"");
    format!(
        r#"display notification "{}" with title "{}" subtitle "OSA""#,
        esc(message),
        esc(title)
    )
}

/// argv for `notify-send`.
pub fn notify_send_args(title: &str, message: &str) -> Vec<String> {
    vec![
        "-a".to_string(),
        "OSA".to_string(),
        title.to_string(),
        message.to_string(),
    ]
}

/// Fire a native notification. Returns whether one was actually dispatched, so
/// the caller can fall back to the terminal bell rather than leaving a user
/// who stepped away with no signal at all.
///
/// Best-effort and non-blocking: the child is spawned and never waited on. A
/// notifier that hangs must not stall the render loop.
pub fn notify(title: &str, message: &str) -> bool {
    let Some(n) = notifier() else {
        return false;
    };

    let (program, args) = match n {
        Notifier::TerminalNotifier(path) => {
            let sender = std::env::var("OSA_NOTIFY_SENDER").ok();
            (path, terminal_notifier_args(title, message, sender.as_deref()))
        }
        Notifier::Osascript(path) => (path, vec!["-e".to_string(), osascript_script(title, message)]),
        Notifier::NotifySend(path) => (path, notify_send_args(title, message)),
    };

    Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn terminal_notifier_args_carry_title_message_and_a_group() {
        let args = terminal_notifier_args("Done", "Response ready", None);

        assert!(args.contains(&"-title".to_string()));
        assert!(args.contains(&"Done".to_string()));
        assert!(args.contains(&"-message".to_string()));
        assert!(args.contains(&"Response ready".to_string()));
        // Without a group every turn leaves another toast behind.
        assert!(args.contains(&"-group".to_string()));
        assert!(!args.contains(&"-sender".to_string()));
    }

    #[test]
    fn a_sender_adds_a_click_target_as_well_as_the_identity() {
        let args = terminal_notifier_args("t", "m", Some("com.github.wez.wezterm"));
        // `-sender` alone is not enough: recent macOS ignores the identity
        // masquerade, and without `-activate` the toast becomes unclickable.
        assert!(args.contains(&"-activate".to_string()), "no click target: {args:?}");
        assert!(args.contains(&"-sender".to_string()));
        assert_eq!(
            args.iter().filter(|a| *a == "com.github.wez.wezterm").count(),
            2,
            "both flags need the bundle id: {args:?}"
        );
    }

    #[test]
    fn a_blank_sender_is_treated_as_unset() {
        let args = terminal_notifier_args("t", "m", Some("   "));
        assert!(!args.contains(&"-sender".to_string()));
        assert!(!args.contains(&"-activate".to_string()));
    }

    /// Count the quotes AppleScript would treat as string delimiters, i.e.
    /// those not preceded by a backslash. Substring checks cannot answer this:
    /// an escaped payload still *contains* the attacker's text, correctly
    /// defanged, so matching on it reports a failure that is not there.
    fn unescaped_quotes(s: &str) -> usize {
        let mut count = 0;
        let mut chars = s.chars();
        while let Some(c) = chars.next() {
            match c {
                '\\' => {
                    chars.next();
                }
                '"' => count += 1,
                _ => {}
            }
        }
        count
    }

    #[test]
    fn a_quote_in_the_title_cannot_escape_the_applescript_string() {
        // A model-authored title reaches this verbatim. Unescaped, the quote
        // would close the literal and `do shell script` would be evaluated.
        let script = osascript_script(r#"done" & (do shell script "id") & ""#, "body");

        // Three string literals - message, title, subtitle - so six delimiters
        // and not one more. Any extra means the payload broke out.
        assert_eq!(
            unescaped_quotes(&script),
            6,
            "payload escaped its literal: {script}"
        );
    }

    #[test]
    fn a_benign_title_still_yields_exactly_three_literals() {
        // Guards the counter itself: if it miscounted, the injection test above
        // would pass for the wrong reason.
        let script = osascript_script("Done", "Response ready");
        assert_eq!(unescaped_quotes(&script), 6, "{script}");
    }

    #[test]
    fn backslashes_are_escaped_before_quotes_not_after() {
        // Escaping quotes first would then double the backslashes it just
        // introduced, corrupting the payload.
        let script = osascript_script("a\\b", "m");
        assert!(script.contains("a\\\\b"), "got {script}");
    }

    #[test]
    fn notify_send_args_name_the_app() {
        let args = notify_send_args("Done", "Response ready");
        assert_eq!(args[0], "-a");
        assert_eq!(args[1], "OSA");
        assert!(args.contains(&"Done".to_string()));
    }

    #[test]
    fn a_platform_with_no_notifier_reports_unavailable_rather_than_pretending() {
        // On macOS `osascript` is always present, so this only asserts the
        // contract holds: available() and notifier() agree.
        assert_eq!(available(), notifier().is_some());
    }
}
