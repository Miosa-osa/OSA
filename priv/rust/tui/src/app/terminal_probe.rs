//! Batched startup terminal probe.
//!
//! At startup OSA needs three answers from the terminal:
//!   1. the cursor position (so ratatui's inline viewport lands on a warmed-up
//!      terminal instead of timing out on a dropped DSR query), and
//!   2. whether the kitty keyboard protocol is supported (so Shift+Enter can be a
//!      reliable newline chord instead of collapsing to a bare Enter/submit).
//!   3. (best effort) the terminal's default fg/bg colors — currently unused by
//!      OSA but queried in the same burst so the terminal is fully warmed.
//!
//! The previous approach fired these as SEPARATE sequential probes — a
//! `cursor::position()` priming loop and a `supports_keyboard_enhancement()`
//! retry — which raced each other during OSA's busy startup. crossterm's
//! `supports_keyboard_enhancement()` also blocks up to ~2s and can flake to
//! `false` on the first try, silently breaking Shift+Enter.
//!
//! This module fires ALL queries in ONE burst under a single caller deadline:
//!   CPR cursor (ESC[6n) + OSC10 fg + OSC11 bg + kitty keyboard flags (ESC[?u)
//!   + Primary Device Attributes / DA1 (ESC[c) as a guaranteed done-marker.
//! DA1 is answered by effectively every terminal, so a terminal WITHOUT the
//! kitty protocol still answers DA1 and we learn "unsupported" immediately
//! instead of waiting out the full deadline.
//!
//! On Unix the probe dups the tty fds, sets the reader O_NONBLOCK, and `poll()`s
//! for responses within the deadline. It never hangs: if the terminal never
//! answers, every field is left `None` and the caller degrades gracefully
//! (full-screen viewport / assume no keyboard enhancement).
//!
//! Probes must run while the crossterm event stream is absent (i.e. before the
//! event loop starts). Bytes read while looking for responses are consumed from
//! the terminal, so this must only run during the short exclusive startup window.

use ratatui::layout::Position;
use std::time::Duration;

/// Default wall-clock budget for the startup probe burst.
///
/// A little more generous than a local-only budget because remote/SSH devices
/// have round-trip latency; still short enough to be imperceptible at startup
/// and to fall back before the first frame if the terminal stays silent.
pub(crate) const DEFAULT_TIMEOUT: Duration = Duration::from_millis(150);

/// Terminal default foreground/background colors (OSC 10 / OSC 11).
#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub(crate) struct DefaultColors {
    pub(crate) fg: (u8, u8, u8),
    pub(crate) bg: (u8, u8, u8),
}

/// Results of the one-shot startup terminal probe. Any field may be `None` when
/// the terminal did not answer within the deadline.
#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub(crate) struct StartupProbe {
    pub(crate) cursor_position: Option<Position>,
    pub(crate) default_colors: Option<DefaultColors>,
    pub(crate) keyboard_enhancement_supported: Option<bool>,
}

impl StartupProbe {
    /// An all-`None` probe, used when the probe could not run at all.
    pub(crate) const fn empty() -> Self {
        Self {
            cursor_position: None,
            default_colors: None,
            keyboard_enhancement_supported: None,
        }
    }
}

// The single burst sent to the terminal:
//   ESC[6n        -> CPR cursor position report
//   ESC]10;?ST    -> OSC 10 default foreground
//   ESC]11;?ST    -> OSC 11 default background
//   ESC[?u        -> query current kitty keyboard flags (answered only if supported)
//   ESC[c         -> DA1 primary device attributes (guaranteed done-marker)
const BURST: &[u8] = b"\x1B[6n\x1B]10;?\x1B\\\x1B]11;?\x1B\\\x1B[?u\x1B[c";

// ---------------------------------------------------------------------------
// Parsing helpers (platform-agnostic so unit tests run everywhere).
// ---------------------------------------------------------------------------

/// Parses a CPR cursor-position report `ESC [ row ; col R` (1-based) into a
/// 0-based `Position`. Tolerates leading unrelated bytes (e.g. a focus report).
fn parse_cursor_position(buffer: &[u8]) -> Option<Position> {
    for start in find_all_subslices(buffer, b"\x1B[") {
        let rest = &buffer[start + 2..];
        let Some(end) = rest.iter().position(|b| *b == b'R') else {
            continue;
        };
        let Ok(payload) = std::str::from_utf8(&rest[..end]) else {
            continue;
        };
        let Some((row, col)) = payload.split_once(';') else {
            continue;
        };
        let Ok(row) = row.parse::<u16>() else {
            continue;
        };
        let Ok(col) = col.parse::<u16>() else {
            continue;
        };
        return Some(Position {
            x: col.saturating_sub(1),
            y: row.saturating_sub(1),
        });
    }
    None
}

/// Kitty keyboard flags report is `ESC [ ? <bits> u`. Returns whether a
/// well-formed flags report is present (nonzero-length numeric payload).
fn has_keyboard_flags(buffer: &[u8]) -> bool {
    for start in find_all_subslices(buffer, b"\x1B[?") {
        let rest = &buffer[start + 3..];
        let Some(end) = rest.iter().position(|b| *b == b'u') else {
            continue;
        };
        if end == 0 {
            continue;
        }
        if rest[..end].iter().all(|b| b.is_ascii_digit()) {
            return true;
        }
    }
    false
}

/// DA1 primary-device-attributes report is `ESC [ ? <params> c`. Used as the
/// fallback done-marker: a terminal that answers DA1 but NOT the kitty flags
/// query does not support the kitty keyboard protocol.
fn has_primary_device_attributes(buffer: &[u8]) -> bool {
    for start in find_all_subslices(buffer, b"\x1B[?") {
        let rest = &buffer[start + 3..];
        let Some(end) = rest.iter().position(|b| *b == b'c') else {
            continue;
        };
        if end > 0 && rest[..end].iter().all(|b| b.is_ascii_digit() || *b == b';') {
            return true;
        }
    }
    false
}

/// Keyboard-enhancement resolution derived from the current buffer.
#[derive(Debug, Clone, Copy, Eq, PartialEq)]
enum KeyboardProbeState {
    /// Neither the kitty flags nor DA1 have arrived yet.
    Pending,
    /// Kitty flags arrived (supported); DA1 may or may not have arrived.
    Supported,
    /// DA1 arrived without kitty flags — unsupported.
    UnsupportedFallback,
}

fn keyboard_probe_state(buffer: &[u8]) -> KeyboardProbeState {
    match (has_keyboard_flags(buffer), has_primary_device_attributes(buffer)) {
        (true, _) => KeyboardProbeState::Supported,
        (false, true) => KeyboardProbeState::UnsupportedFallback,
        (false, false) => KeyboardProbeState::Pending,
    }
}

/// Parses an OSC color slot (`ESC ] <slot> ; rgb:RR/GG/BB ST`).
fn parse_osc_color(buffer: &[u8], slot: u8) -> Option<(u8, u8, u8)> {
    let prefix = format!("\x1B]{slot};");
    let start = find_subslice(buffer, prefix.as_bytes())?;
    let rest = &buffer[start + prefix.len()..];
    let payload_end = osc_payload_end(rest)?;
    let payload = std::str::from_utf8(&rest[..payload_end]).ok()?;
    parse_osc_rgb(payload)
}

fn parse_default_colors(buffer: &[u8]) -> Option<DefaultColors> {
    let fg = parse_osc_color(buffer, /*slot*/ 10)?;
    let bg = parse_osc_color(buffer, /*slot*/ 11)?;
    Some(DefaultColors { fg, bg })
}

/// Returns the payload length up to (not including) the OSC terminator (BEL or ST).
fn osc_payload_end(buffer: &[u8]) -> Option<usize> {
    let mut idx = 0;
    while idx < buffer.len() {
        match buffer[idx] {
            0x07 => return Some(idx),
            0x1B if buffer.get(idx + 1) == Some(&b'\\') => return Some(idx),
            _ => idx += 1,
        }
    }
    None
}

fn parse_osc_rgb(payload: &str) -> Option<(u8, u8, u8)> {
    let (prefix, values) = payload.trim().split_once(':')?;
    if !prefix.eq_ignore_ascii_case("rgb") && !prefix.eq_ignore_ascii_case("rgba") {
        return None;
    }
    let mut parts = values.split('/');
    let r = parse_osc_component(parts.next()?)?;
    let g = parse_osc_component(parts.next()?)?;
    let b = parse_osc_component(parts.next()?)?;
    if prefix.eq_ignore_ascii_case("rgba") {
        parse_osc_component(parts.next()?)?;
    }
    parts.next().is_none().then_some((r, g, b))
}

fn parse_osc_component(component: &str) -> Option<u8> {
    match component.len() {
        2 => u8::from_str_radix(component, 16).ok(),
        4 => u16::from_str_radix(component, 16)
            .ok()
            .map(|value| (value / 257) as u8),
        _ => None,
    }
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

fn find_all_subslices<'a>(
    haystack: &'a [u8],
    needle: &'a [u8],
) -> impl Iterator<Item = usize> + 'a {
    haystack
        .windows(needle.len())
        .enumerate()
        .filter_map(move |(idx, window)| (window == needle).then_some(idx))
}

// ---------------------------------------------------------------------------
// Accumulation logic (platform-agnostic, unit-tested).
// ---------------------------------------------------------------------------

/// Folds newly-available `buffer` bytes into `probe`, tracking whether we've
/// seen the kitty flags so a deadline-timeout can still resolve support.
fn update_probe(probe: &mut StartupProbe, saw_keyboard_flags: &mut bool, buffer: &[u8]) {
    if probe.cursor_position.is_none() {
        probe.cursor_position = parse_cursor_position(buffer);
    }
    if probe.default_colors.is_none() {
        probe.default_colors = parse_default_colors(buffer);
    }
    if probe.keyboard_enhancement_supported.is_none() {
        match keyboard_probe_state(buffer) {
            KeyboardProbeState::Supported => {
                *saw_keyboard_flags = true;
                // If DA1 has also arrived we can resolve immediately; otherwise
                // wait a touch longer for DA1 so its bytes don't leak into the
                // event stream, but we already know the answer is "true".
                if has_primary_device_attributes(buffer) {
                    probe.keyboard_enhancement_supported = Some(true);
                }
            }
            KeyboardProbeState::UnsupportedFallback => {
                probe.keyboard_enhancement_supported = Some(false);
            }
            KeyboardProbeState::Pending => {}
        }
    }
}

/// True once every field has resolved (so we can stop early before the deadline).
fn probe_complete(probe: &StartupProbe) -> bool {
    probe.cursor_position.is_some()
        && probe.default_colors.is_some()
        && probe.keyboard_enhancement_supported.is_some()
}

/// Called when the deadline expired: if we saw kitty flags but never the DA1
/// marker, resolve support as `true` anyway (the flags are proof enough).
fn finish_probe(probe: &mut StartupProbe, saw_keyboard_flags: bool) {
    if probe.keyboard_enhancement_supported.is_none() && saw_keyboard_flags {
        probe.keyboard_enhancement_supported = Some(true);
    }
}

// ---------------------------------------------------------------------------
// Unix implementation: dup tty, O_NONBLOCK, poll().
// ---------------------------------------------------------------------------

#[cfg(unix)]
mod imp {
    use super::{
        finish_probe, probe_complete, update_probe, StartupProbe, BURST,
    };
    use std::fs::{File, OpenOptions};
    use std::io::{self, Write};
    use std::os::fd::{AsRawFd, FromRawFd};
    use std::time::{Duration, Instant};

    /// A temporary, exclusive terminal handle used for the probe.
    ///
    /// Reader and writer are SEPARATE file descriptions so switching the reader
    /// to O_NONBLOCK does not also make writes fail with `WouldBlock`. Prefers
    /// duplicated stdio (replies land on the same input crossterm reads), and
    /// falls back to `/dev/tty` for redirected/embedded environments.
    struct Tty {
        reader: File,
        writer: File,
        original_flags: libc::c_int,
    }

    impl Tty {
        fn open() -> io::Result<Self> {
            match (dup_file(libc::STDIN_FILENO), dup_file(libc::STDOUT_FILENO)) {
                (Ok(reader), Ok(writer)) => Self::new(reader, writer),
                _ => {
                    let reader = OpenOptions::new().read(true).open("/dev/tty")?;
                    let writer = OpenOptions::new().write(true).open("/dev/tty")?;
                    Self::new(reader, writer)
                }
            }
        }

        fn new(reader: File, writer: File) -> io::Result<Self> {
            let fd = reader.as_raw_fd();
            let original_flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
            if original_flags == -1 {
                return Err(io::Error::last_os_error());
            }
            if unsafe { libc::fcntl(fd, libc::F_SETFL, original_flags | libc::O_NONBLOCK) } == -1 {
                return Err(io::Error::last_os_error());
            }
            Ok(Self {
                reader,
                writer,
                original_flags,
            })
        }

        fn write_all(&mut self, bytes: &[u8]) -> io::Result<()> {
            self.writer.write_all(bytes)?;
            self.writer.flush()
        }

        /// Drains everything currently readable (non-blocking) into `buffer`.
        fn read_available(&mut self, buffer: &mut Vec<u8>) -> io::Result<()> {
            let mut chunk = [0_u8; 256];
            loop {
                let count = unsafe {
                    libc::read(
                        self.reader.as_raw_fd(),
                        chunk.as_mut_ptr().cast::<libc::c_void>(),
                        chunk.len(),
                    )
                };
                if count > 0 {
                    buffer.extend_from_slice(&chunk[..count as usize]);
                    continue;
                }
                if count == 0 {
                    return Ok(());
                }
                let err = io::Error::last_os_error();
                if matches!(
                    err.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                ) {
                    return Ok(());
                }
                return Err(err);
            }
        }

        /// Waits up to `timeout` for the reader to become readable.
        fn poll_readable(&self, timeout: Duration) -> io::Result<bool> {
            let mut fd = libc::pollfd {
                fd: self.reader.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            };
            let deadline = Instant::now() + timeout;
            loop {
                let now = Instant::now();
                if now >= deadline {
                    return Ok(false);
                }
                let timeout_ms = deadline
                    .saturating_duration_since(now)
                    .as_millis()
                    .min(libc::c_int::MAX as u128) as libc::c_int;
                let result = unsafe { libc::poll(&mut fd, /*nfds*/ 1, timeout_ms) };
                if result > 0 {
                    return Ok((fd.revents & libc::POLLIN) != 0);
                }
                if result == 0 {
                    return Ok(false);
                }
                let err = io::Error::last_os_error();
                if err.kind() != io::ErrorKind::Interrupted {
                    return Err(err);
                }
            }
        }
    }

    impl Drop for Tty {
        fn drop(&mut self) {
            // Restore the reader's original blocking flags so we don't leave the
            // fd (which is a dup of the real stdin) in a surprising state.
            let _ =
                unsafe { libc::fcntl(self.reader.as_raw_fd(), libc::F_SETFL, self.original_flags) };
        }
    }

    fn dup_file(fd: libc::c_int) -> io::Result<File> {
        let duplicated = unsafe { libc::dup(fd) };
        if duplicated == -1 {
            return Err(io::Error::last_os_error());
        }
        Ok(unsafe { File::from_raw_fd(duplicated) })
    }

    /// Fires the batched burst and reads responses under one shared deadline.
    /// Never blocks longer than `timeout`; unresolved fields are left `None`.
    pub(crate) fn startup(timeout: Duration) -> io::Result<StartupProbe> {
        let mut tty = Tty::open()?;
        tty.write_all(BURST)?;

        let deadline = Instant::now() + timeout;
        let mut buffer = Vec::new();
        let mut probe = StartupProbe::empty();
        let mut saw_keyboard_flags = false;

        loop {
            tty.read_available(&mut buffer)?;
            update_probe(&mut probe, &mut saw_keyboard_flags, &buffer);
            if probe_complete(&probe) {
                return Ok(probe);
            }
            let now = Instant::now();
            if now >= deadline {
                finish_probe(&mut probe, saw_keyboard_flags);
                return Ok(probe);
            }
            if !tty.poll_readable(deadline.saturating_duration_since(now))? {
                finish_probe(&mut probe, saw_keyboard_flags);
                return Ok(probe);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Non-Unix fallback: use crossterm's blocking helpers. OSA ships on Linux/macOS,
// so this path is only a compile-time safety net.
// ---------------------------------------------------------------------------

#[cfg(not(unix))]
mod imp {
    use super::{StartupProbe, DefaultColors};
    use std::io;
    use std::time::Duration;

    pub(crate) fn startup(_timeout: Duration) -> io::Result<StartupProbe> {
        let cursor_position = crossterm::cursor::position()
            .ok()
            .map(|(col, row)| ratatui::layout::Position { x: col, y: row });
        let keyboard_enhancement_supported =
            crossterm::terminal::supports_keyboard_enhancement().ok();
        let _ = DefaultColors { fg: (0, 0, 0), bg: (0, 0, 0) }; // keep type referenced
        Ok(StartupProbe {
            cursor_position,
            default_colors: None,
            keyboard_enhancement_supported,
        })
    }
}

/// Fires the batched startup terminal-probe burst under `timeout`.
///
/// Returns a best-effort [`StartupProbe`]; on any I/O failure or timeout the
/// unresolved fields are `None`. This NEVER hangs longer than `timeout` and
/// NEVER aborts startup — callers degrade gracefully from `None` values.
pub(crate) fn run(timeout: Duration) -> StartupProbe {
    match imp::startup(timeout) {
        Ok(probe) => probe,
        Err(err) => {
            tracing::warn!("startup terminal probe failed: {err}");
            StartupProbe::empty()
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_cursor_position_zero_based() {
        assert_eq!(
            parse_cursor_position(b"\x1B[20;10R"),
            Some(Position { x: 9, y: 19 })
        );
        // Tolerates a leading focus-in report before the CPR.
        assert_eq!(
            parse_cursor_position(b"\x1B[I\x1B[20;10R"),
            Some(Position { x: 9, y: 19 })
        );
        assert_eq!(parse_cursor_position(b""), None);
        assert_eq!(parse_cursor_position(b"\x1B[garbageR"), None);
    }

    #[test]
    fn keyboard_flags_vs_da1() {
        assert!(has_keyboard_flags(b"\x1B[?7u"));
        assert!(!has_keyboard_flags(b"\x1B[?u")); // empty payload = the query echo, not a report
        assert!(has_primary_device_attributes(b"\x1B[?64;1;2c"));
        assert!(!has_primary_device_attributes(b"\x1B[?7u"));
    }

    #[test]
    fn keyboard_probe_state_transitions() {
        assert_eq!(keyboard_probe_state(b""), KeyboardProbeState::Pending);
        assert_eq!(
            keyboard_probe_state(b"\x1B[?7u"),
            KeyboardProbeState::Supported
        );
        assert_eq!(
            keyboard_probe_state(b"\x1B[?64;1;2c"),
            KeyboardProbeState::UnsupportedFallback
        );
        // Flags win even if DA1 also present.
        assert_eq!(
            keyboard_probe_state(b"\x1B[?64;1;2c\x1B[?7u"),
            KeyboardProbeState::Supported
        );
    }

    #[test]
    fn parses_osc_default_colors_bel_and_st() {
        assert_eq!(
            parse_default_colors(b"\x1B]10;rgb:eeee/eeee/eeee\x1B\\\x1B]11;rgb:1111/1111/1111\x07"),
            Some(DefaultColors {
                fg: (238, 238, 238),
                bg: (17, 17, 17)
            })
        );
        // Order-independent.
        assert_eq!(
            parse_default_colors(b"\x1B]11;rgb:1111/1111/1111\x07\x1B]10;rgb:eeee/eeee/eeee\x1B\\"),
            Some(DefaultColors {
                fg: (238, 238, 238),
                bg: (17, 17, 17)
            })
        );
        // Missing bg -> None.
        assert_eq!(parse_default_colors(b"\x1B]10;rgb:eeee/eeee/eeee\x1B\\"), None);
    }

    #[test]
    fn osc_components_two_and_four_digit() {
        assert_eq!(parse_osc_rgb("rgb:00/80/ff"), Some((0, 128, 255)));
        assert_eq!(parse_osc_rgb("rgba:ffff/8000/0000/ffff"), Some((255, 127, 0)));
        assert_eq!(parse_osc_rgb("rgb:zz/00/00"), None);
    }

    /// Full batched burst response arriving in one buffer resolves every field
    /// and short-circuits (complete before deadline).
    #[test]
    fn update_probe_parses_full_batched_response() {
        let mut probe = StartupProbe::empty();
        let mut saw = false;
        update_probe(
            &mut probe,
            &mut saw,
            b"\x1B[20;10R\x1B]11;rgb:1111/1111/1111\x07\x1B[?64;1;2c\x1B]10;rgb:eeee/eeee/eeee\x1B\\\x1B[?7u",
        );
        assert_eq!(
            probe,
            StartupProbe {
                cursor_position: Some(Position { x: 9, y: 19 }),
                default_colors: Some(DefaultColors {
                    fg: (238, 238, 238),
                    bg: (17, 17, 17),
                }),
                keyboard_enhancement_supported: Some(true),
            }
        );
        assert!(probe_complete(&probe));
    }

    /// Unsupported terminal: DA1 arrives, no kitty flags -> resolves false
    /// immediately (no waiting out the deadline).
    #[test]
    fn update_probe_unsupported_resolves_false() {
        let mut probe = StartupProbe::empty();
        let mut saw = false;
        update_probe(&mut probe, &mut saw, b"\x1B[1;1R\x1B[?64;1;2c");
        assert_eq!(probe.keyboard_enhancement_supported, Some(false));
        assert!(!saw);
    }

    /// Deadline behavior: kitty flags seen but DA1 (done-marker) never arrived
    /// before the deadline. `finish_probe` must still resolve support = true.
    #[test]
    fn finish_probe_resolves_true_from_flags_only_on_timeout() {
        let mut probe = StartupProbe::empty();
        let mut saw = false;
        update_probe(&mut probe, &mut saw, b"\x1B[?7u");
        // Flags seen, but not yet resolved because DA1 hasn't arrived.
        assert_eq!(probe.keyboard_enhancement_supported, None);
        assert!(saw);
        // Simulate the deadline firing with only partial data.
        finish_probe(&mut probe, saw);
        assert_eq!(probe.keyboard_enhancement_supported, Some(true));
    }

    /// Deadline behavior: terminal stayed completely silent. Every field is
    /// left `None` so the caller can degrade gracefully.
    #[test]
    fn finish_probe_leaves_none_when_silent() {
        let mut probe = StartupProbe::empty();
        let saw = false;
        finish_probe(&mut probe, saw);
        assert_eq!(probe, StartupProbe::empty());
        assert!(!probe_complete(&probe));
    }
}
