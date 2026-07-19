//! Sleep / idle inhibitor for long-running turns (U-T15).
//!
//! Directly serves OSA's long-running-agent goal: a turn that runs for many
//! minutes (or now, unbounded) must not be killed by the OS suspending the
//! machine or the session going idle. We hold an OS-level inhibitor for the
//! duration of a turn and release it the instant the turn ends (or the process
//! dies — the child is reaped on `Drop`).
//!
//! Per-OS transport:
//!   - Linux (systemd): `systemd-inhibit --what=idle:sleep --mode=block ... sleep infinity`
//!     The lock is held for as long as the child lives; killing it releases.
//!   - macOS: `caffeinate -i -m -s` — prevents idle sleep while it runs.
//!
//! Both are spawned detached from our stdio; if the binary is missing the spawn
//! simply fails and we run without an inhibitor (best-effort, never fatal).
#![allow(dead_code)]

/// The argv (program + args) for the sleep inhibitor on a given OS, or `None`
/// when we don't know how to inhibit there. Pure so it can be unit-tested on any
/// platform. `os` is a `std::env::consts::OS` value ("linux", "macos", ...).
pub fn inhibit_argv(os: &str) -> Option<(&'static str, Vec<&'static str>)> {
    match os {
        "linux" => Some((
            "systemd-inhibit",
            vec![
                "--what=idle:sleep",
                "--who=OSA",
                "--why=OSA agent turn in progress",
                "--mode=block",
                "sleep",
                "infinity",
            ],
        )),
        "macos" => Some((
            // -i no idle sleep, -m no disk sleep, -s prevent system sleep on AC.
            "caffeinate",
            vec!["-i", "-m", "-s"],
        )),
        _ => None,
    }
}

/// Holds an OS sleep inhibitor for its lifetime. Create with [`SleepInhibitor::begin`]
/// at the start of a long turn; drop it (or call [`SleepInhibitor::release`]) when
/// the turn ends. Idempotent and panic-free.
#[derive(Debug, Default)]
pub struct SleepInhibitor {
    child: Option<std::process::Child>,
}

impl SleepInhibitor {
    /// Start inhibiting sleep. No-op (returns an empty guard) when the platform
    /// is unknown or the helper binary can't be spawned.
    pub fn begin() -> Self {
        let child = inhibit_argv(std::env::consts::OS).and_then(|(prog, args)| {
            std::process::Command::new(prog)
                .args(args)
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .spawn()
                .ok()
        });
        if child.is_some() {
            tracing::debug!("sleep inhibitor engaged for turn");
        }
        Self { child }
    }

    /// True when an inhibitor process is actually held.
    pub fn is_active(&self) -> bool {
        self.child.is_some()
    }

    /// Release the inhibitor early (also happens automatically on drop).
    pub fn release(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
            tracing::debug!("sleep inhibitor released");
        }
    }
}

impl Drop for SleepInhibitor {
    fn drop(&mut self) {
        self.release();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn linux_uses_systemd_inhibit_blocking_idle_and_sleep() {
        let (prog, args) = inhibit_argv("linux").expect("linux inhibitor");
        assert_eq!(prog, "systemd-inhibit");
        assert!(args.contains(&"--mode=block"));
        assert!(args.iter().any(|a| a.starts_with("--what=") && a.contains("sleep")));
        // Must spawn a long-lived holder process.
        assert!(args.ends_with(&["sleep", "infinity"]));
    }

    #[test]
    fn macos_uses_caffeinate_idle() {
        let (prog, args) = inhibit_argv("macos").expect("macos inhibitor");
        assert_eq!(prog, "caffeinate");
        assert!(args.contains(&"-i"));
    }

    #[test]
    fn unknown_os_has_no_inhibitor() {
        assert!(inhibit_argv("plan9").is_none());
        // A begin() on an unknown platform yields an inert guard, never panics.
        // (On the test host this may actually spawn; either way release is safe.)
        let mut guard = SleepInhibitor { child: None };
        assert!(!guard.is_active());
        guard.release();
    }
}
