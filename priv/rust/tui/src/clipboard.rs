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

/// Attempt a single transport. Returns true on success.
fn try_transport(t: Transport, text: &str) -> bool {
    match t {
        Transport::Osc52 => crate::components::osc52::copy(text).is_ok(),
        other => match transport_argv(other) {
            Some((prog, args)) => pipe_to_command(prog, args, text),
            None => false,
        },
    }
}

/// Copy `text` to the clipboard through the layered cascade. Returns the
/// transport that succeeded, or `None` if every layer failed (extraordinarily
/// unlikely — OSC 52 almost always writes).
pub fn copy(text: &str) -> Option<Transport> {
    for t in command_chain(Env::detect()) {
        if try_transport(t, text) {
            tracing::debug!(?t, "clipboard copy succeeded");
            return Some(t);
        }
    }
    tracing::warn!("clipboard copy failed on every transport");
    None
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
