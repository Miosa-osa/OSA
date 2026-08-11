//! Layered clipboard WRITE path (U-T19) + the copy backend for per-block /
//! per-message copy (U-T7, copy half).
//!
//! Today OSA's copy path is arboard-only, which talks to the LOCAL windowing
//! system and silently fails over SSH / on headless boxes / inside some
//! sandboxes. Claude Code copies through a *cascade* of transports and takes the
//! first that works. We mirror that, trying in order:
//!
//!   1. A native clipboard CLI for the platform: `pbcopy` (macOS),
//!      `wl-copy` (Wayland), `xclip`/`xsel` (X11).
//!   2. The tmux paste buffer (`tmux load-buffer -`) when inside tmux — reaches
//!      the multiplexer's own buffer even with no system clipboard.
//!   3. OSC 52 (`components::osc52`), the terminal-driven clipboard that works
//!      across an SSH hop and through tmux/screen passthrough.
//!
//! The first transport that succeeds wins; `copy` returns which one (or `None`
//! if every layer failed). Env-injected [`command_chain`] keeps the ordering
//! pure and unit-testable without touching the real clipboard.
#![allow(dead_code)]

use std::io::Write;
use std::process::{Command, Stdio};

/// A clipboard write transport, in priority order.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Transport {
    /// macOS `pbcopy`.
    PbCopy,
    /// Wayland `wl-copy`.
    WlCopy,
    /// X11 `xclip -selection clipboard`.
    Xclip,
    /// X11 `xsel --clipboard --input`.
    Xsel,
    /// tmux paste buffer via `tmux load-buffer -`.
    TmuxBuffer,
    /// Terminal-driven OSC 52.
    Osc52,
}

/// Environment inputs that decide which transports are worth trying. Pure struct
/// so [`command_chain`] can be exercised for any platform in tests.
#[derive(Debug, Clone, Copy)]
pub struct Env<'a> {
    pub os: &'a str,
    pub wayland: bool,
    pub x11: bool,
    pub tmux: bool,
}

impl Env<'_> {
    /// Read the current process environment.
    pub fn detect() -> Env<'static> {
        Env {
            os: std::env::consts::OS,
            wayland: std::env::var_os("WAYLAND_DISPLAY").is_some(),
            x11: std::env::var_os("DISPLAY").is_some(),
            tmux: std::env::var_os("TMUX").is_some(),
        }
    }
}

/// Ordered list of transports to try for the given environment (U-T19 cascade).
/// Native CLIs first (they hit the real system clipboard), then the tmux buffer,
/// then OSC 52 as the always-available terminal fallback. OSC 52 is ALWAYS last
/// so a copy still lands over SSH even when nothing else is present.
pub fn command_chain(env: Env<'_>) -> Vec<Transport> {
    let mut chain = Vec::new();
    match env.os {
        "macos" => chain.push(Transport::PbCopy),
        _ => {
            // Prefer the compositor-native tool that matches the live session.
            if env.wayland {
                chain.push(Transport::WlCopy);
            }
            if env.x11 {
                chain.push(Transport::Xclip);
                chain.push(Transport::Xsel);
            }
            // Even with neither display var set, wl-copy/xclip may still work
            // (e.g. XWayland quirks); try wl-copy once as a cheap probe.
            if !env.wayland && !env.x11 {
                chain.push(Transport::WlCopy);
                chain.push(Transport::Xclip);
            }
        }
    }
    if env.tmux {
        chain.push(Transport::TmuxBuffer);
    }
    chain.push(Transport::Osc52);
    chain
}

/// The argv for a native-CLI transport, or `None` for transports handled
/// specially (tmux/OSC 52). Pure, for tests.
pub fn transport_argv(t: Transport) -> Option<(&'static str, &'static [&'static str])> {
    match t {
        Transport::PbCopy => Some(("pbcopy", &[])),
        Transport::WlCopy => Some(("wl-copy", &[])),
        Transport::Xclip => Some(("xclip", &["-selection", "clipboard"])),
        Transport::Xsel => Some(("xsel", &["--clipboard", "--input"])),
        Transport::TmuxBuffer => Some(("tmux", &["load-buffer", "-"])),
        Transport::Osc52 => None,
    }
}

/// Pipe `text` into a stdin-consuming CLI (`prog args...`). Returns true iff the
/// process spawned, took the text, and exited 0.
fn pipe_to_command(prog: &str, args: &[&str], text: &str) -> bool {
    let mut child = match Command::new(prog)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
    {
        Ok(c) => c,
        Err(_) => return false,
    };
    if let Some(mut stdin) = child.stdin.take() {
        if stdin.write_all(text.as_bytes()).is_err() {
            let _ = child.kill();
            let _ = child.wait();
            return false;
        }
        // Drop stdin to send EOF before waiting.
        drop(stdin);
    }
    matches!(child.wait(), Ok(status) if status.success())
}

/// How much we actually know about whether the clipboard was set.
///
/// The distinction is the whole point of this type. The native CLIs and the
/// tmux buffer are *processes*: they exit non-zero when they fail, so a success
/// there is a fact. OSC 52 is a one-way escape sequence with no reply — a
/// terminal that has never heard of it, or has clipboard writes disabled (the
/// xterm and VTE DEFAULT), consumes the bytes and does nothing, and looks
/// byte-for-byte identical from here to one that copied. Reporting that as
/// success is how a user copies a long answer over SSH, is told it worked,
/// pastes, and gets their stale clipboard back with the original unrecoverable.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Confidence {
    /// A transport that reports failure succeeded. The clipboard IS set.
    Confirmed,
    /// Bytes were emitted on a channel that cannot acknowledge, to a terminal
    /// not on the known-good allowlist. It may or may not have landed.
    Unverified,
    /// Every transport refused or failed. The clipboard is definitely unchanged.
    Failed,
}

/// Outcome of a copy: what we know, which transport got there, where the text
/// was also saved, and a human-readable reason when something went wrong.
#[derive(Debug, Clone)]
pub struct CopyOutcome {
    pub confidence: Confidence,
    pub transport: Option<Transport>,
    /// Path the payload was also written to whenever the copy is not
    /// [`Confidence::Confirmed`], so the text is never unrecoverable.
    pub fallback_path: Option<std::path::PathBuf>,
    /// Why it is not confirmed (payload over the OSC 52 cap, unknown terminal…).
    pub detail: Option<String>,
}

impl CopyOutcome {
    /// The toast the user should see. Never claims more than is known.
    pub fn message(&self) -> String {
        let saved = |p: &Option<std::path::PathBuf>| match p {
            Some(p) => format!(" — saved to {}", p.display()),
            None => String::new(),
        };
        match self.confidence {
            Confidence::Confirmed => "Copied to clipboard".to_string(),
            Confidence::Unverified => format!(
                "Sent to terminal clipboard (unverified){}",
                saved(&self.fallback_path)
            ),
            Confidence::Failed => match &self.detail {
                Some(d) => format!("Copy failed: {d}{}", saved(&self.fallback_path)),
                None => format!("Copy failed{}", saved(&self.fallback_path)),
            },
        }
    }

    /// Toast severity matching the confidence.
    pub fn level(&self) -> crate::components::toast::ToastLevel {
        match self.confidence {
            Confidence::Confirmed => crate::components::toast::ToastLevel::Info,
            Confidence::Unverified => crate::components::toast::ToastLevel::Warning,
            Confidence::Failed => crate::components::toast::ToastLevel::Error,
        }
    }
}

/// Terminals known to implement OSC 52 clipboard WRITES with it enabled by
/// default. Deliberately narrow: this list is the difference between telling the
/// user a fact and telling them a guess, so an unknown terminal must fall to
/// [`Confidence::Unverified`], never to "Copied".
///
/// Notably absent: xterm (needs `allowWindowOps`/`disallowedWindowOps`, off by
/// default) and VTE/GNOME Terminal (clipboard write is not enabled by default),
/// even though both are on the OSC **8** allowlist in
/// [`crate::components::osc8`] — hyperlinks and clipboard writes are separate
/// capabilities and must not share an allowlist.
const OSC52_KNOWN: &[&str] = &[
    "ghostty", "kitty", "iTerm.app", "iTerm2", "WezTerm", "alacritty", "rio", "foot", "Hyper",
];

/// Whether OSC 52 on this terminal can be reported as a confirmed copy.
/// Pure over an injected environment so the policy is unit-testable.
pub fn osc52_is_known_good(env: impl Fn(&str) -> Option<String>) -> bool {
    // Inside a multiplexer the terminal we can see is the multiplexer, and the
    // copy additionally depends on ITS config (`set-clipboard on` in tmux, off
    // by default in tmux < 3.something). Never claim confirmed through one.
    if crate::components::osc52::multiplexer_with(&env) != crate::components::osc52::Multiplexer::None
    {
        return false;
    }
    for var in ["TERM_PROGRAM", "LC_TERMINAL"] {
        if let Some(v) = env(var) {
            if OSC52_KNOWN.iter().any(|k| k.eq_ignore_ascii_case(v.trim())) {
                return true;
            }
        }
    }
    if let Some(term) = env("TERM") {
        let term = term.to_ascii_lowercase();
        if term.contains("kitty") || term.contains("wezterm") || term.contains("foot") {
            return true;
        }
    }
    // Windows Terminal implements OSC 52 writes.
    if env("WT_SESSION").is_some() {
        return true;
    }
    false
}

/// Where an unconfirmed payload is parked so the user can still get it back.
fn fallback_dir() -> std::path::PathBuf {
    directories::BaseDirs::new()
        .map(|d| d.home_dir().to_path_buf())
        .or_else(|| std::env::var_os("HOME").map(std::path::PathBuf::from))
        .unwrap_or_else(|| std::path::PathBuf::from("."))
        .join(".osa")
        .join("clipboard")
}

/// Write `text` somewhere durable and tell the caller where, so a copy that did
/// not certainly land is never an unrecoverable loss. Created 0600 (it holds
/// whatever the user was copying — answers, secrets, transcript text), and
/// created 0600 BEFORE the bytes go in, never chmod'd afterwards.
fn save_fallback(text: &str) -> Option<std::path::PathBuf> {
    let dir = fallback_dir();
    std::fs::create_dir_all(&dir).ok()?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700));
    }
    let path = dir.join("last-copy.txt");
    let mut opts = std::fs::OpenOptions::new();
    opts.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.mode(0o600);
    }
    // `mode()` only applies at creation time, so a file inherited at 0644 from an
    // older build must be tightened BEFORE the payload is written into it.
    #[cfg(unix)]
    if path.exists() {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    }
    let mut f = opts.open(&path).ok()?;
    f.write_all(text.as_bytes()).ok()?;
    f.flush().ok()?;
    Some(path)
}

/// Result of one transport attempt.
enum Attempt {
    /// The transport reported success and that report is trustworthy.
    Confirmed,
    /// Bytes went out on an unacknowledged channel.
    Emitted,
    /// Did not happen, with a reason worth showing the user.
    Refused(String),
    /// Did not happen, nothing worth saying (binary missing, exited non-zero).
    Failed,
}

/// Grade an OSC 52 write. Pure so the *judgement* — the part that used to be
/// wrong — is testable without touching the real terminal or process env.
///
/// A successful write means only that the bytes left the process. OSC 52 has no
/// reply, so on a terminal we do not recognise the correct answer is
/// [`Attempt::Emitted`], never [`Attempt::Confirmed`].
fn osc52_attempt(
    write: Result<(), crate::components::osc52::Osc52Error>,
    known_good: bool,
) -> Attempt {
    match write {
        Ok(()) if known_good => Attempt::Confirmed,
        Ok(()) => Attempt::Emitted,
        Err(e) => Attempt::Refused(e.to_string()),
    }
}

/// Attempt a single transport.
fn try_transport(t: Transport, text: &str) -> Attempt {
    match t {
        Transport::Osc52 => osc52_attempt(
            crate::components::osc52::copy(text),
            osc52_is_known_good(|k| std::env::var(k).ok()),
        ),
        other => match transport_argv(other) {
            Some((prog, args)) => {
                if pipe_to_command(prog, args, text) {
                    Attempt::Confirmed
                } else {
                    Attempt::Failed
                }
            }
            None => Attempt::Failed,
        },
    }
}

/// Copy `text` to the clipboard through the layered cascade.
///
/// Returns what is actually KNOWN about the outcome — see [`Confidence`]. The
/// old signature returned `Option<Transport>` and every caller read `Some(_)` as
/// "Copied to clipboard"; because OSC 52 sits last in the chain and returns Ok
/// whenever a write to stdout succeeds, that was unconditionally `Some`, so the
/// failure arms were unreachable and the success toast was a lie on every
/// terminal without OSC 52 support.
pub fn copy(text: &str) -> CopyOutcome {
    let mut detail: Option<String> = None;
    let mut emitted_transport: Option<Transport> = None;

    for t in command_chain(Env::detect()) {
        match try_transport(t, text) {
            Attempt::Confirmed => {
                tracing::debug!(?t, "clipboard copy confirmed");
                return CopyOutcome {
                    confidence: Confidence::Confirmed,
                    transport: Some(t),
                    fallback_path: None,
                    detail: None,
                };
            }
            Attempt::Emitted => {
                // Keep going: a later transport could still confirm. Nothing
                // does today (OSC 52 is last), but the ordering is data.
                emitted_transport = Some(t);
            }
            Attempt::Refused(reason) => detail = Some(reason),
            Attempt::Failed => {}
        }
    }

    let fallback_path = save_fallback(text);
    match emitted_transport {
        Some(t) => {
            tracing::warn!(?t, "clipboard copy emitted but unverified");
            CopyOutcome {
                confidence: Confidence::Unverified,
                transport: Some(t),
                fallback_path,
                detail,
            }
        }
        None => {
            tracing::warn!("clipboard copy failed on every transport");
            CopyOutcome {
                confidence: Confidence::Failed,
                transport: None,
                fallback_path,
                detail,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn macos_prefers_pbcopy_then_osc52() {
        let chain = command_chain(Env {
            os: "macos",
            wayland: false,
            x11: false,
            tmux: false,
        });
        assert_eq!(chain, vec![Transport::PbCopy, Transport::Osc52]);
    }

    #[test]
    fn wayland_linux_order() {
        let chain = command_chain(Env {
            os: "linux",
            wayland: true,
            x11: false,
            tmux: false,
        });
        assert_eq!(chain, vec![Transport::WlCopy, Transport::Osc52]);
    }

    #[test]
    fn x11_linux_tries_xclip_then_xsel() {
        let chain = command_chain(Env {
            os: "linux",
            wayland: false,
            x11: true,
            tmux: false,
        });
        assert_eq!(
            chain,
            vec![Transport::Xclip, Transport::Xsel, Transport::Osc52]
        );
    }

    #[test]
    fn tmux_buffer_sits_before_osc52() {
        let chain = command_chain(Env {
            os: "linux",
            wayland: true,
            x11: true,
            tmux: true,
        });
        // native first, then tmux buffer, then OSC 52 always last
        assert_eq!(*chain.last().unwrap(), Transport::Osc52);
        let tmux_idx = chain.iter().position(|t| *t == Transport::TmuxBuffer).unwrap();
        let osc_idx = chain.iter().position(|t| *t == Transport::Osc52).unwrap();
        assert!(tmux_idx < osc_idx);
        assert!(chain.iter().position(|t| *t == Transport::WlCopy).unwrap() < tmux_idx);
    }

    #[test]
    fn osc52_is_always_the_final_fallback() {
        // Headless: no display, no tmux — still ends on OSC 52.
        let chain = command_chain(Env {
            os: "linux",
            wayland: false,
            x11: false,
            tmux: false,
        });
        assert_eq!(*chain.last().unwrap(), Transport::Osc52);
    }

    fn env_of(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
        let map: std::collections::HashMap<String, String> = pairs
            .iter()
            .map(|(k, v)| ((*k).to_string(), (*v).to_string()))
            .collect();
        move |k: &str| map.get(k).cloned()
    }

    /// THE BUG. A copy over SSH into a terminal with no OSC 52 support used to
    /// report "Copied to clipboard": `osc52::copy` returns Ok whenever the write
    /// to stdout succeeds, OSC 52 is always last in the chain, so `copy` was
    /// unconditionally `Some(_)` and the failure arms in `handle_actions.rs` and
    /// `transcript_viewer.rs` were unreachable. An emitted-but-unacknowledged
    /// send must never read as Confirmed.
    #[test]
    fn unknown_terminal_osc52_is_never_reported_as_confirmed() {
        // Plain xterm over SSH: not on the allowlist.
        assert!(!osc52_is_known_good(env_of(&[("TERM", "xterm-256color")])));
        // VTE/GNOME Terminal: on the OSC *8* allowlist, but clipboard writes are
        // not on by default, so it must not confirm a copy.
        assert!(!osc52_is_known_good(env_of(&[
            ("TERM", "xterm-256color"),
            ("VTE_VERSION", "6003"),
        ])));
        // screen/tmux with nothing else known.
        assert!(!osc52_is_known_good(env_of(&[("TERM", "screen-256color")])));
        // And nothing at all.
        assert!(!osc52_is_known_good(env_of(&[])));
    }

    #[test]
    fn known_good_terminals_confirm_osc52() {
        assert!(osc52_is_known_good(env_of(&[
            ("TERM", "xterm-256color"),
            ("TERM_PROGRAM", "ghostty"),
        ])));
        assert!(osc52_is_known_good(env_of(&[("TERM", "xterm-kitty")])));
        assert!(osc52_is_known_good(env_of(&[
            ("TERM", "foot-extra"),
        ])));
        assert!(osc52_is_known_good(env_of(&[
            ("TERM", "xterm-256color"),
            ("WT_SESSION", "abc"),
        ])));
    }

    /// Inside a multiplexer the copy additionally depends on the multiplexer's
    /// own config (tmux `set-clipboard`), which we cannot see — so even a
    /// known-good outer terminal cannot be confirmed through one.
    #[test]
    fn multiplexer_downgrades_a_known_good_terminal_to_unverified() {
        assert!(!osc52_is_known_good(env_of(&[
            ("TERM", "tmux-256color"),
            ("TMUX", "/tmp/tmux-1000/default,1,0"),
            ("TMUX_PANE", "%0"),
            ("LC_TERMINAL", "iTerm2"),
        ])));
    }

    /// THE REGRESSION GUARD for the "every copy reports success" bug. The old
    /// code was `Transport::Osc52 => osc52::copy(text).is_ok()`, i.e. a
    /// successful stdout write graded as a successful copy. On a terminal that
    /// does not implement OSC 52 that is a lie, and since OSC 52 is always last
    /// in the chain it was the answer the user got over SSH.
    #[test]
    fn a_successful_osc52_write_to_an_unknown_terminal_is_not_confirmed() {
        assert!(
            matches!(osc52_attempt(Ok(()), false), Attempt::Emitted),
            "an unacknowledged write to an unrecognised terminal must not confirm"
        );
        assert!(matches!(osc52_attempt(Ok(()), true), Attempt::Confirmed));
        assert!(matches!(
            osc52_attempt(
                Err(crate::components::osc52::Osc52Error::TooLarge {
                    bytes: 900 * 1024,
                    cap: 768 * 1024
                }),
                true
            ),
            Attempt::Refused(_)
        ));
    }

    /// Every non-confirmed outcome must name a message that does NOT claim the
    /// clipboard was set, and must point at a retrievable copy of the payload.
    #[test]
    fn non_confirmed_messages_do_not_claim_success() {
        let unverified = CopyOutcome {
            confidence: Confidence::Unverified,
            transport: Some(Transport::Osc52),
            fallback_path: Some(std::path::PathBuf::from("/home/u/.osa/clipboard/last-copy.txt")),
            detail: None,
        };
        let msg = unverified.message();
        assert!(msg.contains("unverified"), "{msg}");
        assert!(msg.contains("last-copy.txt"), "{msg}");
        assert_ne!(msg, "Copied to clipboard");
        assert!(matches!(
            unverified.level(),
            crate::components::toast::ToastLevel::Warning
        ));

        let failed = CopyOutcome {
            confidence: Confidence::Failed,
            transport: None,
            fallback_path: Some(std::path::PathBuf::from("/home/u/.osa/clipboard/last-copy.txt")),
            detail: Some("payload is 900 KiB, over the 768 KiB OSC 52 limit".into()),
        };
        let msg = failed.message();
        assert!(msg.starts_with("Copy failed"), "{msg}");
        assert!(msg.contains("768 KiB"), "{msg}");
        assert!(msg.contains("last-copy.txt"), "{msg}");

        // Only a confirmed copy gets the flat claim.
        let ok = CopyOutcome {
            confidence: Confidence::Confirmed,
            transport: Some(Transport::Xclip),
            fallback_path: None,
            detail: None,
        };
        assert_eq!(ok.message(), "Copied to clipboard");
    }

    /// The payload must be retrievable after an unconfirmed copy. Owner-only:
    /// it holds whatever the user copied.
    #[test]
    fn fallback_file_is_written_owner_only() {
        let tmp = std::env::temp_dir().join(format!("osa-clip-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();
        // Point the fallback at the temp home for this assertion by writing
        // through the same code path with an overridden HOME.
        let prev = std::env::var_os("HOME");
        // SAFETY: single-threaded assertion over process env; restored below.
        unsafe { std::env::set_var("HOME", &tmp) };
        let path = save_fallback("secret answer text").expect("fallback written");
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "secret answer text");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o600, "fallback holds copied text; must be owner-only");
        }
        match prev {
            Some(v) => unsafe { std::env::set_var("HOME", v) },
            None => unsafe { std::env::remove_var("HOME") },
        }
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn argv_shapes() {
        assert_eq!(transport_argv(Transport::PbCopy), Some(("pbcopy", &[][..])));
        assert_eq!(
            transport_argv(Transport::Xclip),
            Some(("xclip", &["-selection", "clipboard"][..]))
        );
        assert_eq!(
            transport_argv(Transport::TmuxBuffer),
            Some(("tmux", &["load-buffer", "-"][..]))
        );
        assert_eq!(transport_argv(Transport::Osc52), None);
    }
}
