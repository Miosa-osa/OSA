//! Paste-burst detection for terminals without bracketed paste.
//!
//! OSA enables bracketed paste at startup (`main.rs` → `EnableBracketedPaste`), so on a
//! well-behaved terminal a paste arrives as ONE `CrosstermEvent::Paste(String)` and is routed
//! through `App::insert_paste_text` → [`InputComponent::insert_paste`]. This module is the
//! **fallback** for the terminals that never deliver that event (older Windows consoles, some
//! multiplexer/ssh configurations, middle-click X11 primary-selection paste): there, a paste
//! arrives as a rapid stream of `KeyCode::Char` + `KeyCode::Enter` key events, indistinguishable
//! from typing except by timing.
//!
//! Without this, a multi-line paste "submits halfway through": the first embedded newline is read
//! as a plain Enter and the composer fires `AppAction::Submit` with half the paste, dropping the
//! rest into the next turn. That is the entire bug class this fixes.
//!
//! The two paths never double-handle: an explicit paste calls
//! [`PasteBurst::clear_after_explicit_paste`], which drops all transient burst state, and burst
//! detection only ever sees `Key(Char)` events (a bracketed paste produces none).
//!
//! # Purity
//!
//! This is a pure state machine. It never touches the textarea and never calls `Instant::now()` —
//! every entry point takes `now: Instant` as a parameter, so the whole thing is unit-testable
//! without a terminal or a real clock. Callers interpret the returned decisions and apply the
//! corresponding edits themselves.
//!
//! # Three behaviours
//!
//! 1. **Flicker suppression** — the first fast ASCII char is *held* for up to
//!    [`PASTE_BURST_CHAR_INTERVAL`] instead of being rendered, so we never draw a typed char and
//!    then reclassify it as paste one frame later. Only used in buffering mode (see below).
//! 2. **Coalescing** — a burst accumulates into one `String` that the caller applies through the
//!    normal paste path, so a burst-pasted blob gets the same normalization / large-paste pill
//!    treatment as a bracketed paste.
//! 3. **Enter suppression** — while a burst window is open, Enter inserts a newline instead of
//!    submitting.
//!
//! # Modes
//!
//! [`PasteBurst`] supports the two caller contracts Codex uses:
//!
//! - **Direct-insert** (OSA's default): the caller inserts every char into the textarea
//!   immediately and uses the machine purely for classification —
//!   [`PasteBurst::on_plain_char_no_hold`] + [`PasteBurst::extend_window`] to keep the window
//!   alive, and [`PasteBurst::direct_insert_newline_should_insert`] in the Enter handler. Nothing
//!   is ever buffered, so no periodic flush tick is required and text can never get "stuck"
//!   invisible. This alone fixes behaviour (3), which is the actual data-loss bug.
//! - **Buffering** (opt-in, `OSA_TUI_PASTE_BURST_BUFFER=1`): the full contract with held first
//!   char, buffering and retro-capture. This gives behaviours (1) and (2) as well, but it requires
//!   the host to call [`PasteBurst::flush_if_due`] on a timer faster than
//!   [`PASTE_BURST_ACTIVE_IDLE_TIMEOUT`] (OSA's app loop currently ticks at 200ms and does not
//!   forward ticks to the composer), otherwise the tail of a burst stays buffered until the next
//!   keystroke. Keep it off until a fast composer tick exists.
//!
//! # Retro-capture
//!
//! When chars were already inserted as normal typing and the stream is only *then* classified as
//! paste-like, [`CharDecision::BeginBuffer`] carries a **character** count.
//! [`PasteBurst::decide_begin_buffer`] converts that count into a UTF-8 **byte** index with
//! [`retro_start_index`], so the caller removes exactly `start_byte..cursor` from the textarea and
//! the eventual paste sees one contiguous string. The char→byte conversion is what makes this
//! correct for multibyte / emoji input.
//!
//! # Clearing vs flushing
//!
//! - [`PasteBurst::flush_before_modified_input`] returns buffered text so the caller can apply it
//!   through the paste path before handling unrelated input.
//! - [`PasteBurst::clear_window_after_non_char`] only clears the *classification* window so the
//!   next keystroke is not grouped into the previous burst. It assumes the caller already flushed.

use std::time::Duration;
use std::time::Instant;

/// Number of consecutive fast chars before a stream is treated as paste-like.
const PASTE_BURST_MIN_CHARS: u16 = 3;

/// How long Enter keeps meaning "newline" after burst activity.
pub const PASTE_ENTER_SUPPRESS_WINDOW: Duration = Duration::from_millis(120);

/// Maximum delay between consecutive chars for them to belong to one burst.
/// Also bounds how long the held first char is retained.
pub const PASTE_BURST_CHAR_INTERVAL: Duration = Duration::from_millis(8);

/// Once buffering is active, how long to wait after the last char before
/// flushing the accumulated buffer as a single paste.
pub const PASTE_BURST_ACTIVE_IDLE_TIMEOUT: Duration = Duration::from_millis(60);

/// Pure paste-burst classifier. See the module docs for the caller contract.
pub struct PasteBurst {
    /// Master switch (`disable_paste_burst`). When false every entry point is a
    /// no-op and callers fall back to plain typing behaviour.
    enabled: bool,
    /// Whether the caller uses the buffering contract (hold + buffer +
    /// retro-capture) rather than direct-insert. Buffering needs a periodic
    /// [`PasteBurst::flush_if_due`] tick.
    buffering: bool,
    /// Timestamp of the most recent plain char, for the interval heuristic.
    last_plain_char_time: Option<Instant>,
    /// How many consecutive chars have arrived within [`PASTE_BURST_CHAR_INTERVAL`].
    consecutive_plain_char_burst: u16,
    /// Deadline until which Enter means "newline". Outlives the buffer itself.
    burst_window_until: Option<Instant>,
    /// Accumulated burst text, flushed as one `Paste(String)`.
    buffer: String,
    /// True while still actively accepting chars into the current burst.
    active: bool,
    /// One held ASCII char (flicker suppression). The caller must NOT render it.
    pending_first_char: Option<(char, Instant)>,
}

impl Default for PasteBurst {
    fn default() -> Self {
        Self::new(true)
    }
}

/// What the caller should do with the char it just fed in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CharDecision {
    /// Start buffering and retroactively capture `retro_chars` already-inserted
    /// **characters** (not bytes) from before the cursor.
    BeginBuffer { retro_chars: u16 },
    /// A burst is active; append the current char into the buffer.
    BufferAppend,
    /// Do not insert/render this char yet — it is held while we wait to see
    /// whether a burst follows.
    RetainFirstChar,
    /// Begin buffering from the previously held char (no retro grab needed).
    BeginBufferFromPending,
}

/// A resolved retro-capture: the byte offset in the pre-cursor slice where the
/// grabbed text starts, and the grabbed text itself.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RetroGrab {
    pub start_byte: usize,
    pub grabbed: String,
}

/// Outcome of a periodic [`PasteBurst::flush_if_due`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FlushResult {
    /// Apply this text through the normal paste path.
    Paste(String),
    /// Insert this single char as ordinary typing (the held char timed out).
    Typed(char),
    /// Nothing to do.
    None,
}

impl PasteBurst {
    /// A machine with burst detection on and the direct-insert contract.
    pub fn new(enabled: bool) -> Self {
        Self {
            enabled,
            buffering: false,
            last_plain_char_time: None,
            consecutive_plain_char_burst: 0,
            burst_window_until: None,
            buffer: String::new(),
            active: false,
            pending_first_char: None,
        }
    }

    /// A fully disabled machine (`disable_paste_burst = true`).
    pub fn disabled() -> Self {
        Self::new(false)
    }

    /// Opt into the buffering contract (hold + buffer + retro-capture). Requires
    /// the host to call [`Self::flush_if_due`] on a tick faster than
    /// [`PASTE_BURST_ACTIVE_IDLE_TIMEOUT`].
    pub fn with_buffering(mut self, buffering: bool) -> Self {
        self.buffering = buffering;
        self
    }

    pub fn is_enabled(&self) -> bool {
        self.enabled
    }

    pub fn buffering_enabled(&self) -> bool {
        self.enabled && self.buffering
    }

    /// Delay a caller (or test) should wait so a held first char flushes out as
    /// ordinary typed input.
    pub fn recommended_flush_delay() -> Duration {
        PASTE_BURST_CHAR_INTERVAL + Duration::from_millis(1)
    }

    /// Delay after which an *active* buffer flushes as a paste.
    pub fn recommended_active_flush_delay() -> Duration {
        PASTE_BURST_ACTIVE_IDLE_TIMEOUT + Duration::from_millis(1)
    }

    /// Feed a plain ASCII char. May hold the first one (flicker suppression).
    /// Returns `None` when the caller should just insert the char normally.
    pub fn on_plain_char(&mut self, ch: char, now: Instant) -> Option<CharDecision> {
        if !self.enabled {
            return None;
        }
        self.note_plain_char(now);

        if self.active {
            self.burst_window_until = Some(now + PASTE_ENTER_SUPPRESS_WINDOW);
            return Some(CharDecision::BufferAppend);
        }

        // A held char plus a second fast char: begin buffering with no retro
        // grab, because the held char was never rendered.
        if let Some((held, held_at)) = self.pending_first_char {
            if now.duration_since(held_at) <= PASTE_BURST_CHAR_INTERVAL {
                self.active = true;
                self.pending_first_char = None;
                self.buffer.push(held);
                self.burst_window_until = Some(now + PASTE_ENTER_SUPPRESS_WINDOW);
                return Some(CharDecision::BeginBufferFromPending);
            }
        }

        if self.consecutive_plain_char_burst >= PASTE_BURST_MIN_CHARS {
            return Some(CharDecision::BeginBuffer {
                retro_chars: self.consecutive_plain_char_burst.saturating_sub(1),
            });
        }

        self.pending_first_char = Some((ch, now));
        Some(CharDecision::RetainFirstChar)
    }

    /// Like [`Self::on_plain_char`] but never holds the char. Used for non-ASCII
    /// / IME input (holding a composed char feels like dropped input) and by the
    /// direct-insert contract. Only ever returns `BufferAppend` or `BeginBuffer`.
    pub fn on_plain_char_no_hold(&mut self, now: Instant) -> Option<CharDecision> {
        if !self.enabled {
            return None;
        }
        self.note_plain_char(now);

        if self.active {
            self.burst_window_until = Some(now + PASTE_ENTER_SUPPRESS_WINDOW);
            return Some(CharDecision::BufferAppend);
        }

        if self.consecutive_plain_char_burst >= PASTE_BURST_MIN_CHARS {
            return Some(CharDecision::BeginBuffer {
                retro_chars: self.consecutive_plain_char_burst.saturating_sub(1),
            });
        }

        None
    }

    fn note_plain_char(&mut self, now: Instant) {
        match self.last_plain_char_time {
            Some(prev) if now.duration_since(prev) <= PASTE_BURST_CHAR_INTERVAL => {
                self.consecutive_plain_char_burst =
                    self.consecutive_plain_char_burst.saturating_add(1)
            }
            _ => self.consecutive_plain_char_burst = 1,
        }
        self.last_plain_char_time = Some(now);
    }

    /// Flush the buffered burst once the idle timeout has elapsed.
    ///
    /// Uses `>` (not `>=`) so callers/tests must cross the threshold by at least
    /// 1ms — see [`Self::recommended_flush_delay`].
    pub fn flush_if_due(&mut self, now: Instant) -> FlushResult {
        if !self.enabled {
            return FlushResult::None;
        }
        let timeout = if self.has_buffer() {
            PASTE_BURST_ACTIVE_IDLE_TIMEOUT
        } else {
            PASTE_BURST_CHAR_INTERVAL
        };
        let timed_out = self
            .last_plain_char_time
            .is_some_and(|t| now.duration_since(t) > timeout);
        if timed_out && self.has_buffer() {
            self.active = false;
            FlushResult::Paste(std::mem::take(&mut self.buffer))
        } else if timed_out {
            match self.pending_first_char.take() {
                Some((ch, _at)) => FlushResult::Typed(ch),
                None => FlushResult::None,
            }
        } else {
            FlushResult::None
        }
    }

    /// While bursting, swallow Enter into the buffer as a newline instead of
    /// submitting. Returns true when the newline was captured.
    pub fn append_newline_if_active(&mut self, now: Instant) -> bool {
        if self.is_active() {
            self.buffer.push('\n');
            self.burst_window_until = Some(now + PASTE_ENTER_SUPPRESS_WINDOW);
            true
        } else {
            false
        }
    }

    /// True while Enter should mean "newline" for the buffering contract.
    pub fn newline_should_insert_instead_of_submit(&self, now: Instant) -> bool {
        if !self.enabled {
            return false;
        }
        let in_window = self.burst_window_until.is_some_and(|until| now <= until);
        self.is_active() || in_window
    }

    /// True while Enter should mean "newline" for the direct-insert contract.
    ///
    /// Wider than [`Self::newline_should_insert_instead_of_submit`]: it also
    /// covers the case where only 1-2 fast chars have arrived (below the burst
    /// threshold) and the paste's first newline lands immediately after them —
    /// e.g. pasting "ab\ncd", which would otherwise submit "ab".
    pub fn direct_insert_newline_should_insert(&self, now: Instant) -> bool {
        if !self.enabled {
            return false;
        }
        self.newline_should_insert_instead_of_submit(now)
            || self
                .last_plain_char_time
                .is_some_and(|t| now.duration_since(t) <= PASTE_BURST_CHAR_INTERVAL)
    }

    /// True when the composer is inside a paste burst and transient UI (slash
    /// completions, `@`-file popups) should not react to the pasted chars.
    pub fn in_burst_context(&self, now: Instant) -> bool {
        self.direct_insert_newline_should_insert(now)
    }

    /// Keep the Enter-suppression window alive.
    pub fn extend_window(&mut self, now: Instant) {
        if !self.enabled {
            return;
        }
        self.burst_window_until = Some(now + PASTE_ENTER_SUPPRESS_WINDOW);
    }

    /// Begin buffering seeded with retroactively grabbed text.
    pub fn begin_with_retro_grabbed(&mut self, grabbed: String, now: Instant) {
        if !self.enabled {
            return;
        }
        if !grabbed.is_empty() {
            self.buffer.push_str(&grabbed);
        }
        self.active = true;
        self.burst_window_until = Some(now + PASTE_ENTER_SUPPRESS_WINDOW);
    }

    /// Append a char into the burst buffer.
    pub fn append_char_to_buffer(&mut self, ch: char, now: Instant) {
        if !self.enabled {
            return;
        }
        self.buffer.push(ch);
        self.burst_window_until = Some(now + PASTE_ENTER_SUPPRESS_WINDOW);
    }

    /// Append into the burst buffer only when a burst is already running.
    /// Returns true when the char was captured.
    pub fn try_append_char_if_active(&mut self, ch: char, now: Instant) -> bool {
        if self.enabled && self.has_buffer() {
            self.append_char_to_buffer(ch, now);
            true
        } else {
            false
        }
    }

    /// Decide whether to begin buffering by retroactively capturing the last
    /// `retro_chars` **characters** of `before` (the slice left of the cursor).
    ///
    /// Heuristic: the grabbed slice must look paste-like — contain whitespace, or
    /// be at least 16 chars long. Short words typed quickly therefore stay
    /// ordinary typing.
    ///
    /// On `Some`, the caller must remove `start_byte..cursor` from the textarea;
    /// the text is already in the burst buffer.
    pub fn decide_begin_buffer(
        &mut self,
        now: Instant,
        before: &str,
        retro_chars: usize,
    ) -> Option<RetroGrab> {
        if !self.enabled {
            return None;
        }
        let start_byte = retro_start_index(before, retro_chars);
        let grabbed = before[start_byte..].to_string();
        let looks_pastey = grabbed.chars().any(char::is_whitespace) || grabbed.chars().count() >= 16;
        if looks_pastey {
            self.begin_with_retro_grabbed(grabbed.clone(), now);
            Some(RetroGrab {
                start_byte,
                grabbed,
            })
        } else {
            None
        }
    }

    /// Flush buffered burst text (plus any held char) before unrelated input is
    /// applied, so nothing is left stuck.
    pub fn flush_before_modified_input(&mut self) -> Option<String> {
        if !self.enabled || !self.is_active() {
            return None;
        }
        self.active = false;
        let mut out = std::mem::take(&mut self.buffer);
        if let Some((ch, _at)) = self.pending_first_char.take() {
            out.push(ch);
        }
        Some(out)
    }

    /// Clear the classification window so the next keystroke is not grouped into
    /// the previous burst. Does NOT emit the buffer — flush first.
    pub fn clear_window_after_non_char(&mut self) {
        self.consecutive_plain_char_burst = 0;
        self.last_plain_char_time = None;
        self.burst_window_until = None;
        self.active = false;
        self.pending_first_char = None;
    }

    /// True while any transient burst state exists (buffering, non-empty buffer,
    /// or a held first char).
    pub fn is_active(&self) -> bool {
        self.enabled && (self.has_buffer() || self.pending_first_char.is_some())
    }

    fn has_buffer(&self) -> bool {
        self.active || !self.buffer.is_empty()
    }

    /// Drop all burst state after an explicit (bracketed / clipboard) paste, so
    /// the two paths can never double-handle the same text.
    pub fn clear_after_explicit_paste(&mut self) {
        self.last_plain_char_time = None;
        self.consecutive_plain_char_burst = 0;
        self.burst_window_until = None;
        self.active = false;
        self.buffer.clear();
        self.pending_first_char = None;
    }

    #[cfg(test)]
    fn buffer(&self) -> &str {
        &self.buffer
    }
}

/// Byte index where the last `retro_chars` characters of `before` start.
///
/// Character-count → byte-offset conversion; correct for multibyte and emoji
/// input, where `retro_chars` and the byte length differ.
pub fn retro_start_index(before: &str, retro_chars: usize) -> usize {
    if retro_chars == 0 {
        return before.len();
    }
    before
        .char_indices()
        .rev()
        .nth(retro_chars.saturating_sub(1))
        .map(|(idx, _)| idx)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn buffering() -> PasteBurst {
        PasteBurst::new(true).with_buffering(true)
    }

    /// Feed `s` as a fast burst through the buffering contract, returning the
    /// text the composer would have inserted directly (should be empty for a
    /// clean burst) alongside the machine.
    fn feed_fast(burst: &mut PasteBurst, s: &str, t0: Instant) -> Instant {
        let mut t = t0;
        for ch in s.chars() {
            match burst.on_plain_char(ch, t) {
                Some(CharDecision::RetainFirstChar) => {}
                Some(CharDecision::BeginBufferFromPending)
                | Some(CharDecision::BufferAppend) => burst.append_char_to_buffer(ch, t),
                Some(CharDecision::BeginBuffer { .. }) | None => {
                    burst.append_char_to_buffer(ch, t)
                }
            }
            t += Duration::from_millis(1);
        }
        t
    }

    // ── flicker suppression ────────────────────────────────────────────────

    #[test]
    fn ascii_first_char_is_held_then_flushes_as_typed() {
        let mut burst = buffering();
        let t0 = Instant::now();
        assert_eq!(
            burst.on_plain_char('a', t0),
            Some(CharDecision::RetainFirstChar)
        );

        let t1 = t0 + PasteBurst::recommended_flush_delay();
        assert_eq!(burst.flush_if_due(t1), FlushResult::Typed('a'));
        assert!(!burst.is_active());
    }

    #[test]
    fn held_char_is_not_flushed_before_the_interval_elapses() {
        let mut burst = buffering();
        let t0 = Instant::now();
        burst.on_plain_char('a', t0);
        // Exactly at the threshold: `>` means not yet due.
        assert_eq!(
            burst.flush_if_due(t0 + PASTE_BURST_CHAR_INTERVAL),
            FlushResult::None
        );
        assert!(burst.is_active());
    }

    // ── coalescing ─────────────────────────────────────────────────────────

    #[test]
    fn fast_burst_coalesces_to_one_paste() {
        let mut burst = buffering();
        let t0 = Instant::now();
        let t_end = feed_fast(&mut burst, "hello world", t0);

        let t_flush = t_end + PasteBurst::recommended_active_flush_delay();
        assert_eq!(
            burst.flush_if_due(t_flush),
            FlushResult::Paste("hello world".to_string())
        );
    }

    #[test]
    fn two_fast_chars_begin_buffer_from_pending() {
        let mut burst = buffering();
        let t0 = Instant::now();
        assert_eq!(
            burst.on_plain_char('a', t0),
            Some(CharDecision::RetainFirstChar)
        );
        let t1 = t0 + Duration::from_millis(1);
        assert_eq!(
            burst.on_plain_char('b', t1),
            Some(CharDecision::BeginBufferFromPending)
        );
        burst.append_char_to_buffer('b', t1);

        let t2 = t1 + PasteBurst::recommended_active_flush_delay();
        assert_eq!(burst.flush_if_due(t2), FlushResult::Paste("ab".to_string()));
    }

    #[test]
    fn slow_typing_never_coalesces() {
        let mut burst = buffering();
        let mut t = Instant::now();
        for ch in "hello".chars() {
            // Every char is its own held-then-typed cycle: nothing buffers.
            assert_eq!(
                burst.on_plain_char(ch, t),
                Some(CharDecision::RetainFirstChar),
                "slow char {ch} must be held, never buffered"
            );
            t += PasteBurst::recommended_flush_delay();
            assert_eq!(burst.flush_if_due(t), FlushResult::Typed(ch));
            t += Duration::from_millis(120);
        }
        assert!(!burst.is_active());
    }

    #[test]
    fn slow_typing_never_opens_the_enter_window() {
        let mut burst = PasteBurst::new(true); // direct-insert
        let mut t = Instant::now();
        for _ in 0..10 {
            assert_eq!(burst.on_plain_char_no_hold(t), None);
            t += Duration::from_millis(50);
            assert!(!burst.direct_insert_newline_should_insert(t));
        }
    }

    #[test]
    fn idle_timeout_ends_the_burst() {
        let mut burst = buffering();
        let t0 = Instant::now();
        let t_end = feed_fast(&mut burst, "abcdef", t0);
        // `feed_fast` leaves the clock one step PAST the final char.
        let t_last = t_end - Duration::from_millis(1);

        // Not yet idle...
        assert_eq!(
            burst.flush_if_due(t_last + PASTE_BURST_ACTIVE_IDLE_TIMEOUT),
            FlushResult::None
        );
        assert!(burst.is_active());
        // ...now idle.
        let t_flush = t_end + PasteBurst::recommended_active_flush_delay();
        assert_eq!(
            burst.flush_if_due(t_flush),
            FlushResult::Paste("abcdef".to_string())
        );
        assert!(!burst.is_active());
        assert_eq!(burst.buffer(), "");
        // A later burst starts clean rather than appending to the old one.
        let t2 = t_flush + Duration::from_secs(1);
        feed_fast(&mut burst, "xy", t2);
        let t3 = t2 + Duration::from_millis(2) + PasteBurst::recommended_active_flush_delay();
        assert_eq!(burst.flush_if_due(t3), FlushResult::Paste("xy".to_string()));
    }

    // ── Enter handling ─────────────────────────────────────────────────────

    #[test]
    fn enter_inside_burst_window_becomes_a_newline() {
        let mut burst = buffering();
        let t0 = Instant::now();
        let t_end = feed_fast(&mut burst, "abc", t0);

        assert!(burst.newline_should_insert_instead_of_submit(t_end));
        assert!(burst.append_newline_if_active(t_end));

        let t_flush = t_end + PasteBurst::recommended_active_flush_delay();
        assert_eq!(
            burst.flush_if_due(t_flush),
            FlushResult::Paste("abc\n".to_string())
        );
    }

    #[test]
    fn enter_outside_the_window_still_submits() {
        let mut burst = buffering();
        let t0 = Instant::now();
        let t_end = feed_fast(&mut burst, "abc", t0);
        let t_flush = t_end + PasteBurst::recommended_active_flush_delay();
        assert!(matches!(burst.flush_if_due(t_flush), FlushResult::Paste(_)));

        // Still inside the 120ms suppression window right after the flush.
        assert!(burst.newline_should_insert_instead_of_submit(t_flush));
        // Well past it: Enter submits again.
        let t_late = t_end + PASTE_ENTER_SUPPRESS_WINDOW + Duration::from_millis(1);
        assert!(!burst.newline_should_insert_instead_of_submit(t_late));
        assert!(!burst.direct_insert_newline_should_insert(t_late));
    }

    #[test]
    fn direct_insert_enter_covers_a_two_char_prefix() {
        // "ab\ncd" pasted char-by-char: only 2 chars precede the newline, below
        // the 3-char burst threshold, so the wider direct-insert rule must fire.
        let mut burst = PasteBurst::new(true);
        let t0 = Instant::now();
        assert_eq!(burst.on_plain_char_no_hold(t0), None);
        let t1 = t0 + Duration::from_millis(1);
        assert_eq!(burst.on_plain_char_no_hold(t1), None);

        let t_enter = t1 + Duration::from_millis(1);
        assert!(!burst.newline_should_insert_instead_of_submit(t_enter));
        assert!(burst.direct_insert_newline_should_insert(t_enter));
    }

    #[test]
    fn direct_insert_window_extends_across_a_long_paste() {
        let mut burst = PasteBurst::new(true);
        let t0 = Instant::now();
        let mut t = t0;
        for _ in 0..5 {
            if burst.on_plain_char_no_hold(t).is_some() {
                burst.extend_window(t);
            }
            t += Duration::from_millis(2);
        }
        // Window open well beyond the 8ms char interval.
        assert!(burst.direct_insert_newline_should_insert(t + Duration::from_millis(100)));
        assert!(!burst.direct_insert_newline_should_insert(
            t + PASTE_ENTER_SUPPRESS_WINDOW + Duration::from_millis(10)
        ));
    }

    // ── retro-capture ──────────────────────────────────────────────────────

    #[test]
    fn retro_start_index_counts_characters_not_bytes() {
        assert_eq!(retro_start_index("abc", 0), 3);
        assert_eq!(retro_start_index("abc", 1), 2);
        assert_eq!(retro_start_index("abc", 3), 0);
        // More chars requested than available clamps to the start.
        assert_eq!(retro_start_index("abc", 99), 0);
        // 3-byte CJK chars.
        let cjk = "日本語"; // 9 bytes
        assert_eq!(cjk.len(), 9);
        assert_eq!(retro_start_index(cjk, 1), 6);
        assert_eq!(retro_start_index(cjk, 2), 3);
        assert_eq!(retro_start_index(cjk, 3), 0);
        // 4-byte emoji mixed with ASCII.
        let emoji = "a🎉b🚀"; // 1 + 4 + 1 + 4 = 10 bytes
        assert_eq!(emoji.len(), 10);
        assert_eq!(retro_start_index(emoji, 1), 6);
        assert_eq!(retro_start_index(emoji, 2), 5);
        assert_eq!(retro_start_index(emoji, 3), 1);
        assert_eq!(retro_start_index(emoji, 4), 0);
    }

    #[test]
    fn retro_capture_grabs_the_exact_byte_range_for_multibyte_input() {
        let mut burst = buffering();
        // Drive three fast chars so the machine is in the state that actually
        // produces `BeginBuffer` (and so `flush_if_due` has a timestamp).
        let mut now = Instant::now();
        for _ in 0..3 {
            burst.on_plain_char_no_hold(now);
            now += Duration::from_millis(1);
        }
        let before = "keep 日本 語🎉";
        let grab = burst
            .decide_begin_buffer(now, before, 4)
            .expect("whitespace in the grabbed slice makes it paste-like");
        // Last 4 chars are "語🎉" preceded by ' ' and '本'? Count from the end:
        // '🎉','語',' ','本' → start at the '本'.
        assert_eq!(grab.grabbed, "本 語🎉");
        assert_eq!(&before[grab.start_byte..], grab.grabbed);
        assert!(before.is_char_boundary(grab.start_byte));
        assert!(burst.is_active());
        // The grabbed text is what a later flush emits.
        let t = now + PasteBurst::recommended_active_flush_delay();
        assert_eq!(
            burst.flush_if_due(t),
            FlushResult::Paste("本 語🎉".to_string())
        );
    }

    #[test]
    fn retro_capture_only_triggers_for_pastey_prefixes() {
        let mut burst = buffering();
        let now = Instant::now();

        // Short, no whitespace → ordinary typing.
        assert!(burst.decide_begin_buffer(now, "ab", 2).is_none());
        assert!(!burst.is_active());

        // Whitespace → paste-like.
        let grab = burst.decide_begin_buffer(now, "a b", 2).unwrap();
        assert_eq!(grab.start_byte, 1);
        assert_eq!(grab.grabbed, " b");
        assert!(burst.is_active());
    }

    #[test]
    fn retro_capture_triggers_on_long_whitespace_free_runs() {
        let mut burst = buffering();
        let now = Instant::now();
        let url = "https://example.com/a/very/long/path";
        let grab = burst
            .decide_begin_buffer(now, url, 20)
            .expect(">= 16 chars is paste-like");
        assert_eq!(grab.grabbed.chars().count(), 20);
        assert_eq!(&url[grab.start_byte..], grab.grabbed);
    }

    #[test]
    fn begin_buffer_reports_a_retro_char_count_after_the_threshold() {
        let mut burst = PasteBurst::new(true);
        let t0 = Instant::now();
        // Three consecutive fast chars: the third crosses PASTE_BURST_MIN_CHARS.
        assert_eq!(burst.on_plain_char_no_hold(t0), None);
        assert_eq!(
            burst.on_plain_char_no_hold(t0 + Duration::from_millis(1)),
            None
        );
        assert_eq!(
            burst.on_plain_char_no_hold(t0 + Duration::from_millis(2)),
            Some(CharDecision::BeginBuffer { retro_chars: 2 })
        );
    }

    // ── flush / clear plumbing ─────────────────────────────────────────────

    #[test]
    fn flush_before_modified_input_includes_pending_first_char() {
        let mut burst = buffering();
        let t0 = Instant::now();
        assert_eq!(
            burst.on_plain_char('a', t0),
            Some(CharDecision::RetainFirstChar)
        );
        assert_eq!(burst.flush_before_modified_input(), Some("a".to_string()));
        assert!(!burst.is_active());
    }

    #[test]
    fn flush_before_modified_input_appends_pending_char_after_buffer() {
        let mut burst = buffering();
        let t0 = Instant::now();
        burst.begin_with_retro_grabbed("xy".to_string(), t0);
        burst.pending_first_char = Some(('z', t0));
        assert_eq!(burst.flush_before_modified_input(), Some("xyz".to_string()));
    }

    #[test]
    fn clear_window_after_non_char_stops_grouping() {
        let mut burst = PasteBurst::new(true);
        let t0 = Instant::now();
        burst.on_plain_char_no_hold(t0);
        burst.extend_window(t0);
        assert!(burst.direct_insert_newline_should_insert(t0));

        burst.clear_window_after_non_char();
        assert!(!burst.direct_insert_newline_should_insert(t0));
        // The next fast char restarts the count from 1.
        assert_eq!(
            burst.on_plain_char_no_hold(t0 + Duration::from_millis(1)),
            None
        );
    }

    #[test]
    fn clear_after_explicit_paste_drops_everything() {
        let mut burst = buffering();
        let t0 = Instant::now();
        feed_fast(&mut burst, "abc", t0);
        assert!(burst.is_active());
        burst.clear_after_explicit_paste();
        assert!(!burst.is_active());
        assert_eq!(burst.buffer(), "");
        assert!(!burst.direct_insert_newline_should_insert(t0));
        assert_eq!(
            burst.flush_if_due(t0 + Duration::from_secs(1)),
            FlushResult::None
        );
    }

    #[test]
    fn try_append_char_if_active_only_captures_during_a_burst() {
        let mut burst = buffering();
        let t0 = Instant::now();
        assert!(!burst.try_append_char_if_active('a', t0));
        burst.begin_with_retro_grabbed("x".to_string(), t0);
        assert!(burst.try_append_char_if_active('a', t0));
        assert_eq!(burst.buffer(), "xa");
    }

    // ── disable switch ─────────────────────────────────────────────────────

    #[test]
    fn disabled_machine_is_inert() {
        let mut burst = PasteBurst::disabled();
        let t0 = Instant::now();
        let mut t = t0;
        for ch in "abcdef".chars() {
            assert_eq!(burst.on_plain_char(ch, t), None);
            assert_eq!(burst.on_plain_char_no_hold(t), None);
            t += Duration::from_millis(1);
        }
        assert!(!burst.is_active());
        assert!(!burst.direct_insert_newline_should_insert(t));
        assert!(!burst.newline_should_insert_instead_of_submit(t));
        assert!(burst.decide_begin_buffer(t, "a b c", 3).is_none());
        assert_eq!(burst.flush_before_modified_input(), None);
        assert_eq!(burst.flush_if_due(t + Duration::from_secs(1)), FlushResult::None);
    }
}
