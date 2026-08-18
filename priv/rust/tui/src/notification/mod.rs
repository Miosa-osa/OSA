//! Notification, focus, and attention layer — the `tui_layers_overlays-input`
//! notification cluster (U-T11..U-T19, U-B3).
//!
//! Submodules:
//!   - [`focus`]    U-T11 real focus tracking via DECSET 1004 (`is_focused()`).
//!   - [`progress`] U-T12 OSC 9;4 taskbar progress + keepalive.
//!   - [`inhibit`]  U-T15 sleep inhibitor for long turns.
//!   - [`sound`]    U-T16 focus-gated audio attention cue.
//!   - [`system`]   native OS notification (macOS Notification Centre / libnotify).
//!   - [`kitty`]    U-T17 kitty 3-part click-to-focus notification; U-B3 keyboard re-push gate.
//!   - [`macos`]    U-T13 CoreGraphics Shift-probe for Shift+Enter recovery.
//!
//! This file adds U-T18: a configurable notification channel + user hooks, and a
//! single [`on_turn_complete`] entry point that ties the focus gate, channel,
//! sound cue, and hooks together.
//!
//! ## Cross-file hooks the lead must wire (one line each — DO NOT edited here)
//!
//! 1. **Focus tracking (U-T11)** — in `app/event_loop.rs::dispatch_event`, right
//!    where the event arrives, fold focus events into the global flag:
//!    ```ignore
//!    if let Event::Terminal(ev) = &event { crate::notification::focus::note_event(ev); }
//!    ```
//!
//! 2. **Turn-complete gate (U-T11/16/17)** — in
//!    `app/handle_backend.rs::notify_turn_complete`, replace the 10s idle
//!    heuristic (`NOTIFY_IDLE_THRESHOLD`) gate with the real focus signal:
//!    ```ignore
//!    if crate::notification::focus::is_unfocused() {
//!        crate::notification::on_turn_complete(&self.notify_cfg);
//!    }
//!    ```
//!    (`notify_cfg` is a `NotificationConfig` built once at startup from env/config.)
//!
//! 3. **Progress lifecycle (U-T12)** — at turn start (first token / send) call
//!    `crate::notification::progress::start()`; on the ~200ms tick during a turn
//!    call `progress::keepalive()`; on turn end call `progress::done()`.
//!
//! 4. **Sleep inhibitor (U-T15)** — hold a `SleepInhibitor` on `App` for the
//!    duration of a turn: `self.inhibitor = Some(SleepInhibitor::begin())` at
//!    turn start, `self.inhibitor = None` at turn end (Drop releases it).
//!
//! 5. **Kitty keyboard re-push (U-B3)** — in `app/update.rs::suspend_to_shell`,
//!    replace `if matches!(supports_keyboard_enhancement(), Ok(true))` with:
//!    ```ignore
//!    if crate::notification::kitty::should_repush_kitty_protocol(
//!        supports_keyboard_enhancement().ok())
//!    ```
//!
//! 6. **Clipboard (U-T7/U-T19)** — per-block/per-message copy handlers call
//!    `crate::clipboard::copy(text)` instead of the arboard-only path.
#![allow(dead_code)]

pub mod focus;
pub mod inhibit;
pub mod kitty;
pub mod macos;
pub mod progress;
pub mod sound;
pub mod system;

#[allow(unused_imports)]
pub use inhibit::SleepInhibitor;

/// User-facing notification channel (U-T18). Mirrors Claude Code's
/// `preferredNotifChannel` (terminal_bell / iterm2 / kitty / notifications_disabled).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum NotifyChannel {
    /// Ring the terminal bell (+ system sound cue). The safe universal default.
    #[default]
    TerminalBell,
    /// Rich kitty click-to-focus notification (falls back to bell off-kitty).
    Kitty,
    /// Native OS notification (macOS Notification Centre / Linux libnotify).
    /// The only channel that reaches a user whose terminal is not on screen -
    /// which is the user a turn-complete notification exists for.
    System,
    /// Notifications fully disabled.
    None,
}

impl NotifyChannel {
    /// Parse a channel name (config value / `OSA_NOTIFY_CHANNEL`). Unknown values
    /// fall back to the terminal bell.
    pub fn parse(s: &str) -> Self {
        match s.trim().to_ascii_lowercase().as_str() {
            "none" | "off" | "disabled" => NotifyChannel::None,
            "kitty" => NotifyChannel::Kitty,
            "system" | "native" | "desktop" | "notification" => NotifyChannel::System,
            "bell" | "terminal_bell" | "terminal-bell" | "" => NotifyChannel::TerminalBell,
            _ => NotifyChannel::TerminalBell,
        }
    }

    /// Whether this channel emits anything at all.
    pub fn is_enabled(self) -> bool {
        !matches!(self, NotifyChannel::None)
    }
}

/// Notification configuration (U-T18): the channel plus user hook commands that
/// run on notification events (à la Claude Code's `Notification` hook).
#[derive(Debug, Clone, Default)]
pub struct NotificationConfig {
    pub channel: NotifyChannel,
    /// Shell commands to run when a notification fires. Each receives the message
    /// on argv and `OSA_NOTIFY_TITLE` / `OSA_NOTIFY_MESSAGE` in the environment.
    pub hooks: Vec<String>,
    /// Rolling id for kitty notifications so successive toasts don't collapse.
    next_kitty_id: u32,
}

impl NotificationConfig {
    /// Build config from the environment. `OSA_NO_NOTIFY` disables entirely;
    /// `OSA_NOTIFY_CHANNEL` selects the channel.
    pub fn from_env() -> Self {
        if std::env::var_os("OSA_NO_NOTIFY").is_some() {
            return Self {
                channel: NotifyChannel::None,
                ..Default::default()
            };
        }
        let channel = std::env::var("OSA_NOTIFY_CHANNEL")
            .ok()
            .map(|v| NotifyChannel::parse(&v))
            .unwrap_or_else(default_channel);
        Self {
            channel,
            hooks: Vec::new(),
            next_kitty_id: 1,
        }
    }

    fn bump_kitty_id(&mut self) -> u32 {
        let id = self.next_kitty_id.max(1);
        self.next_kitty_id = id.wrapping_add(1).max(1);
        id
    }
}

/// Fire a turn-complete notification through the configured channel. The CALLER
/// is responsible for the focus gate (only call this when unfocused) — see hook
/// #2 — matching Claude Code's "notify only when the user is away" behavior.
///
/// - `TerminalBell`: audio attention cue (system sound + BEL).
/// - `Kitty`: click-to-focus kitty notification + audio cue.
/// - `None`: nothing (but hooks still run — hooks are the user's own channel).
pub fn on_turn_complete(cfg: &mut NotificationConfig) {
    const TITLE: &str = "OSA";
    const MESSAGE: &str = "Response ready";

    match cfg.channel {
        NotifyChannel::None => {}
        NotifyChannel::TerminalBell => {
            // Caller already checked focus; force the cue by passing "unfocused".
            sound::attention_cue(/* is_focused */ false);
        }
        NotifyChannel::Kitty => {
            let id = cfg.bump_kitty_id();
            kitty::notify(id, TITLE, MESSAGE);
            sound::attention_cue(false);
        }
        NotifyChannel::System => {
            // Degrade to the bell rather than leaving someone who stepped away
            // with no signal at all, if the notifier vanished since startup.
            if !system::notify(TITLE, MESSAGE) {
                sound::attention_cue(false);
            }
        }
    }
    run_hooks(&cfg.hooks, TITLE, MESSAGE);
}

/// The channel used when the operator has not chosen one.
///
/// A bell is the safe universal default, but on a machine that can post a real
/// notification it is also a *worse* one: the whole point of the turn-complete
/// signal is to reach someone who is not looking at the terminal, and a BEL in
/// a window on another Space reaches nobody. Prefer the native channel where it
/// exists and keep the bell everywhere else.
pub fn default_channel() -> NotifyChannel {
    if system::available() {
        NotifyChannel::System
    } else {
        NotifyChannel::TerminalBell
    }
}

/// Run each user notification hook as a detached shell command. Best-effort:
/// missing binaries / non-zero exits are ignored. The message is passed both on
/// argv and via env so simple and structured hooks both work.
pub fn run_hooks(hooks: &[String], title: &str, message: &str) {
    for hook in hooks {
        let trimmed = hook.trim();
        if trimmed.is_empty() {
            continue;
        }
        let _ = std::process::Command::new("sh")
            .arg("-c")
            .arg(trimmed)
            .arg("osa-notify") // $0 for the -c script
            .arg(message) // $1
            .env("OSA_NOTIFY_TITLE", title)
            .env("OSA_NOTIFY_MESSAGE", message)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn channel_parsing() {
        assert_eq!(NotifyChannel::parse("kitty"), NotifyChannel::Kitty);
        assert_eq!(NotifyChannel::parse("NONE"), NotifyChannel::None);
        assert_eq!(NotifyChannel::parse("off"), NotifyChannel::None);
        assert_eq!(NotifyChannel::parse("bell"), NotifyChannel::TerminalBell);
        assert_eq!(NotifyChannel::parse(""), NotifyChannel::TerminalBell);
        assert_eq!(NotifyChannel::parse("garbage"), NotifyChannel::TerminalBell);
    }

    #[test]
    fn enabled_flag() {
        assert!(NotifyChannel::TerminalBell.is_enabled());
        assert!(NotifyChannel::Kitty.is_enabled());
        assert!(NotifyChannel::System.is_enabled());
        assert!(!NotifyChannel::None.is_enabled());
    }

    #[test]
    fn the_native_channel_is_selectable_by_several_obvious_names() {
        for name in ["system", "native", "desktop", "notification", "SYSTEM", " Native "] {
            assert_eq!(
                NotifyChannel::parse(name),
                NotifyChannel::System,
                "{name:?} should select the native channel"
            );
        }
    }

    #[test]
    fn the_default_prefers_a_real_notification_over_a_bell_when_one_is_possible() {
        // A BEL in a terminal on another Space reaches nobody, which is exactly
        // the user this notification is for.
        let expected = if system::available() {
            NotifyChannel::System
        } else {
            NotifyChannel::TerminalBell
        };
        assert_eq!(default_channel(), expected);
    }

    #[test]
    fn an_explicit_choice_still_beats_the_default() {
        // Someone who asked for a bell must keep getting a bell even on a
        // machine that could post a native notification.
        assert_eq!(NotifyChannel::parse("bell"), NotifyChannel::TerminalBell);
        assert_eq!(NotifyChannel::parse("none"), NotifyChannel::None);
    }

    #[test]
    fn kitty_ids_advance_and_never_zero() {
        let mut cfg = NotificationConfig {
            channel: NotifyChannel::Kitty,
            next_kitty_id: u32::MAX, // force the wrap
            ..Default::default()
        };
        let a = cfg.bump_kitty_id();
        let b = cfg.bump_kitty_id();
        assert_eq!(a, u32::MAX);
        assert_ne!(b, 0, "wrapped id must skip zero");
        assert_eq!(b, 1);
    }
}
