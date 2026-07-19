//! macOS CoreGraphics modifier probe for Shift+Enter (U-T13).
//!
//! Apple Terminal and VS Code's integrated terminal do NOT implement the kitty
//! keyboard protocol, so a Shift+Enter arrives indistinguishable from a bare
//! Enter — the composer can't tell "insert newline" from "submit". On macOS we
//! can ask the window server directly whether Shift is physically down at the
//! instant the ambiguous Enter arrived, via CoreGraphics
//! `CGEventSourceFlagsState`. This is exactly what Claude Code does to recover
//! Shift+Enter on those terminals.
//!
//! Cross-platform contract: the pure bit-test [`shift_is_down_in_flags`] and the
//! public [`shift_currently_down`] both compile everywhere. On non-macOS,
//! `shift_currently_down` returns `None` ("can't tell"); only under
//! `cfg(target_os = "macos")` does it link CoreGraphics and return a real answer.
#![allow(dead_code)]

/// `kCGEventFlagMaskShift` from `<CoreGraphics/CGEventTypes.h>`.
pub const CG_EVENT_FLAG_MASK_SHIFT: u64 = 0x0002_0000;

/// Pure test of the Shift bit in a CoreGraphics event-flags word. Testable on
/// every platform so the masking logic is verified even off macOS.
pub fn shift_is_down_in_flags(flags: u64) -> bool {
    flags & CG_EVENT_FLAG_MASK_SHIFT != 0
}

#[cfg(target_os = "macos")]
mod imp {
    use super::CG_EVENT_FLAG_MASK_SHIFT;

    // CGEventSourceStateID: 1 = kCGEventSourceStateHIDSystemState (physical HW).
    const HID_SYSTEM_STATE: u32 = 1;

    #[link(name = "CoreGraphics", kind = "framework")]
    extern "C" {
        fn CGEventSourceFlagsState(state_id: u32) -> u64;
    }

    /// Query the window server for the live modifier flags and test Shift.
    pub fn shift_currently_down() -> Option<bool> {
        // SAFETY: CGEventSourceFlagsState is a pure read of the current HID
        // modifier state; it takes an enum value and returns a bitmask, no
        // pointers, no allocation.
        let flags = unsafe { CGEventSourceFlagsState(HID_SYSTEM_STATE) };
        Some(flags & CG_EVENT_FLAG_MASK_SHIFT != 0)
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    /// Off macOS there is no window server to ask — "unknown".
    pub fn shift_currently_down() -> Option<bool> {
        None
    }
}

/// Whether the Shift modifier is physically down right now.
///
/// `Some(true)` / `Some(false)` on macOS (via CoreGraphics); `None` elsewhere
/// (caller should fall back to its normal ambiguous-Enter handling). Use this
/// only on Apple Terminal / VS Code where the kitty protocol is unavailable —
/// on a kitty-family terminal the keyboard protocol already disambiguates.
pub fn shift_currently_down() -> Option<bool> {
    imp::shift_currently_down()
}

/// Decide whether an ambiguous Enter should be treated as Shift+Enter (newline).
/// Combines the physical probe with a caller-supplied "did the key report Shift?"
/// hint: if either says Shift, it's a newline. Pure and total.
pub fn enter_is_newline(reported_shift: bool, probed_shift: Option<bool>) -> bool {
    reported_shift || probed_shift.unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shift_mask_bit() {
        assert!(shift_is_down_in_flags(CG_EVENT_FLAG_MASK_SHIFT));
        assert!(shift_is_down_in_flags(0x0002_0000 | 0x0010_0000)); // shift+cmd
        assert!(!shift_is_down_in_flags(0));
        assert!(!shift_is_down_in_flags(0x0010_0000)); // cmd only
    }

    #[test]
    fn enter_newline_decision() {
        // Reported shift alone -> newline.
        assert!(enter_is_newline(true, None));
        // Probe says shift down -> newline even if the key didn't report it
        // (the Apple Terminal / VS Code case).
        assert!(enter_is_newline(false, Some(true)));
        // Neither -> submit.
        assert!(!enter_is_newline(false, Some(false)));
        assert!(!enter_is_newline(false, None));
    }

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn non_macos_probe_is_unknown() {
        assert_eq!(shift_currently_down(), None);
    }
}
