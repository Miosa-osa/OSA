//! A de-jitter buffer between the provider's deltas and the assistant buffer.
//!
//! **Default OFF.** Read "What the measurements actually said" before turning
//! it on — on the streams measured here it is not needed, and the honest reason
//! is written down rather than the flattering one.
//!
//! # What the field does
//!
//! Five reference agents were read for this specifically.
//!
//! * **codex** paces, and is the module this one follows. Completed lines are
//!   enqueued *invisibly* (`codex-rs/tui/src/streaming/mod.rs`) and released one
//!   per commit tick — `COMMIT_ANIMATION_TICK = TARGET_FRAME_INTERVAL` ≈ 8.33 ms
//!   (`tui/src/app.rs:401-405`), driven by a dedicated thread posting
//!   `AppEvent::CommitTick`. It is adaptive: `AdaptiveChunkingPolicy`
//!   (`tui/src/streaming/chunking.rs:85-116`) switches Smooth → CatchUp at 8
//!   queued lines *or* a 120 ms oldest-queued age, and CatchUp drains the whole
//!   backlog in one tick. On by default, with no flag.
//! * **Claude Code** does not pace, but it never shows a partial line either:
//!   `streamingText.substring(0, lastIndexOf('\n') + 1)` withholds the
//!   in-progress line entirely (`screens/REPL.tsx:1472-1476`), so text becomes
//!   visible in whole lines. Its 16 ms Ink render throttle is a ceiling only.
//! * **hermes**' prompt_toolkit CLI does the same on newline boundaries
//!   (`cli.py:6990`).
//! * **grok-build** and **opencode** do not pace at all — every chunk is applied
//!   to the render tree on arrival and only the *paint* is capped (16 ms /
//!   60 fps), which grok's own comment says is about not starving keyboard
//!   input, not about smoothness.
//!
//! So the standard exists but is not universal: one of five paces, one more
//! reveals by whole lines, three do neither.
//!
//! # What the measurements actually said
//!
//! Two instruments were built for this and both are in `test/pty`:
//! `delta_shape.py` reads the backend's SSE stream directly and reports how
//! deltas arrive; `pace_probe.py` drives a real PTY against a real backend and
//! reports what each *paint* revealed, using OSA's synchronized-update markers
//! as unambiguous frame boundaries.
//!
//! Against the owner's model (`glm-5.2:cloud`, ~2.4 kB reply in ~8 s):
//!
//! | | arrival (SSE) | paint (PTY) |
//! |---|---|---|
//! | unit size, p50 | 5 chars/delta, ~13 chars/**burst** | **8-9 chars/paint** |
//! | interval, p50 | 0.2 ms (61% under 1 ms), ~42 ms between bursts | **~22 ms** |
//!
//! The "28-character chunk" of the original report is not one delta: it is
//! several 5-character deltas landing inside the same millisecond. Measuring
//! per delta sees 5 and calls the stream smooth; measuring per *burst* sees ~13
//! and is right — which is why [`observe`] accumulates bursts, and why the
//! first version of this module (which keyed on per-delta size) never engaged
//! on the very stream it was written for.
//!
//! But the decisive number is the last column. **OSA already paints more often,
//! and in smaller pieces, than the provider delivers**: ~8 characters every
//! ~22 ms against bursts of ~13 every ~42 ms. There is no headroom left for a
//! pacer to smooth. Worse, the only cadence available to release on is the 32 ms
//! `Event::AnimationFrame`, which is *coarser* than the 22 ms the renderer
//! already achieves — so engaging would make the median interval worse, not
//! better.
//!
//! That was then tested rather than argued. Four PTY turns each, same binary,
//! same backend, same prompt, pooled:
//!
//! | | paints | gap p50 | gap p90 | chars/paint p90 | paints > 50 chars |
//! |---|---|---|---|---|---|
//! | `off` | 378 | 35.7 ms | 142 ms | **21** | 4.8%, carrying 52% of the text |
//! | `on` | 458 | 19.0 ms | 60 ms | **59** | 10.9%, carrying **63%** of the text |
//!
//! Pacing improves the *interval* and makes the *chunking worse* — which is the
//! opposite of the point. The mechanism is plain once measured: bursts arrive
//! ~42 ms apart and the only release cadence available is 32 ms, so holding text
//! back accumulates more than a burst and then releases it in one larger piece.
//! A pacer can only help when it releases FASTER than text arrives; here it
//! cannot. Hence [`PaceMode::Off`] by default — a measured answer, not caution.
//!
//! What the same probe DID find is a real defect, and it is not this one: about
//! 4% of paints reveal more than 50 characters and those few carry **48% of the
//! whole reply**, with single frames revealing up to ~330 characters. Those
//! frames coincide with growth in the terminal's scrollback, i.e. with the
//! settle-to-scrollback commit, not with anything the provider did. The visible
//! chunking is OSA's own — see the report accompanying this change.
//!
//! # What this module does, for the providers that ARE clumped
//!
//! Kept because the mechanism is sound and cheap, and because a provider whose
//! bursts are genuinely coarser than the paint cadence (a slow link, a heavily
//! batching endpoint) is exactly the case it fixes.
//!
//! * Deltas are appended to a buffer instead of being rendered.
//! * A release runs on the cadence the app already has (the 32 ms
//!   `Event::AnimationFrame`, armed whenever the activity indicator is on
//!   screen — i.e. exactly while a turn streams) and hands over a *slice* sized
//!   to drain the backlog within [`LAG_BUDGET`].
//! * If the oldest held character reaches [`LAG_BUDGET`], everything is released
//!   at once. This is codex's CatchUp, and it is what makes the added latency
//!   *bounded* rather than merely small.
//! * It engages only while arrival is measurably clumped ([`ENGAGE_CHUNK_CHARS`],
//!   [`ENGAGE_GAP_MS`]), with hysteresis, and never during the first
//!   [`WARMUP_DELTAS`] bursts — which is what keeps time-to-first-token intact.
//!
//! Character granularity rather than codex's line granularity because OSA's
//! live preview reveals characters: withholding the in-progress line the way
//! Claude Code does would make a prose paragraph — one source line — appear all
//! at once, which is a *bigger* clump than the one complained about.
//!
//! # What it deliberately does NOT do
//!
//! It does not touch the draw loop, the 16 ms floor, or the preview's height
//! band. It sits strictly upstream of [`AssistantStream`], so settling,
//! scrollback commits, guardrail gating and the final-replaces-the-accumulation
//! subtraction all see exactly the byte sequence they saw before — just spread
//! over more frames. Every boundary that matters (turn end, a tool call, an
//! error, an interrupt) calls [`StreamPacer::flush`], so nothing the user needs
//! to see is ever waiting on a tick.
//!
//! [`AssistantStream`]: crate::app::assistant_stream::AssistantStream
//! [`observe`]: StreamPacer::observe

use std::time::{Duration, Instant};

/// The hard bound on latency this buffer may add, and the age at which a held
/// character forces a full release.
///
/// One clump interval on the owner's model is ~130 ms (gap p90 126 ms), so this
/// is about one clump: enough room to spread a clump over several frames,
/// little enough that it cannot read as lag. codex uses the same 120 ms as its
/// CatchUp entry threshold (`streaming/chunking.rs`, `ENTER_OLDEST_AGE`).
pub(crate) const LAG_BUDGET: Duration = Duration::from_millis(120);

/// Bursts observed before the pacer may engage. A pass-through warm-up is what
/// keeps the first tokens of every turn instant, and it is also the smallest
/// sample that says anything about arrival shape.
const WARMUP_DELTAS: u32 = 6;

/// Deltas closer together than this are one *burst* — one arrival as far as the
/// screen is concerned, because no paint can fall between them.
///
/// This distinction is the one that decides whether the pacer is useful, and
/// getting it wrong is what made the first version of this module a no-op on
/// the very stream it was written for. Measured directly off the backend's SSE
/// stream on the owner's model (`test/pty/delta_shape.py`): **490 deltas, p50
/// 5 characters each, 61% of the gaps between them under 1 ms**, p90 gap 35 ms.
/// So the "28-character chunk" is not one delta — it is six 5-character deltas
/// landing in the same millisecond. A statistic taken per *delta* sees 5 and
/// concludes the stream is smooth; a statistic taken per *burst* sees 30 and is
/// right.
const BURST_GAP_MS: f64 = 5.0;

/// Mean chars per burst at or above which arrival counts as clumped. Measured:
/// ~30 on the owner's cloud model, ~4.5 on a local one (whose deltas are 8 ms
/// apart, so each is its own burst).
const ENGAGE_CHUNK_CHARS: f64 = 12.0;

/// Mean inter-*burst* gap (ms) at or above which there is room to smooth. Below
/// this, arrival is already faster than the paint cadence and pacing would only
/// add latency.
const ENGAGE_GAP_MS: f64 = 40.0;

/// Disengage thresholds, held below the engage thresholds so a stream hovering
/// near the boundary does not flap between paced and unpaced mid-reply.
const RELEASE_CHUNK_CHARS: f64 = 8.0;
const RELEASE_GAP_MS: f64 = 25.0;

/// EWMA smoothing factor for both arrival statistics. 0.25 reacts within a
/// handful of deltas without chasing a single outlier.
const EWMA_ALPHA: f64 = 0.25;

/// Whether the pacer may engage at all.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PaceMode {
    /// Never buffer — every delta is handed on the moment it arrives.
    Off,
    /// Engage only while arrival is measurably clumped. The default.
    Auto,
    /// Always engage, warm-up aside. Diagnostic; not a recommended setting.
    On,
}

impl PaceMode {
    /// `OSA_STREAM_PACE` = `off` | `auto` | `on`.
    ///
    /// **Unset is [`PaceMode::Off`]**, and the reason is measured rather than
    /// cautious: on the streams tested, OSA's renderer already paints more
    /// often and in smaller pieces than the provider delivers, so there is
    /// nothing left for a pacer to smooth and engaging one would only coarsen
    /// the cadence to the 32 ms animation frame. See the module docs. `auto`
    /// opts in to the adaptive behaviour for a provider that is genuinely
    /// clumpier than the paint rate.
    pub(crate) fn from_env() -> Self {
        match std::env::var("OSA_STREAM_PACE")
            .unwrap_or_default()
            .trim()
            .to_ascii_lowercase()
            .as_str()
        {
            "on" | "1" | "true" | "always" => PaceMode::On,
            "auto" | "adaptive" => PaceMode::Auto,
            _ => PaceMode::Off,
        }
    }
}

#[derive(Debug)]
pub(crate) struct StreamPacer {
    mode: PaceMode,
    /// Characters accepted but not yet handed on.
    buf: String,
    /// When the oldest character still in `buf` arrived. `None` when empty.
    /// This is what bounds the lag: it is an *arrival* time, so a slow trickle
    /// cannot let the buffer age past [`LAG_BUDGET`] unnoticed.
    oldest: Option<Instant>,
    /// When the last release happened, so a tick knows how much time it is
    /// paying out.
    last_release: Option<Instant>,
    /// Arrival of the previous delta, for the gap statistic.
    last_arrival: Option<Instant>,
    /// EWMA of chars per burst.
    ewma_chunk: f64,
    /// EWMA of the inter-burst gap, in milliseconds.
    ewma_gap: f64,
    /// Characters accumulated in the burst currently open.
    burst_chars: f64,
    /// Bursts COMPLETED this turn — what the warm-up counts, so a turn whose
    /// deltas all land in one burst has still only been seen once.
    seen: u32,
    /// Whether the buffer is currently holding text back.
    engaged: bool,
}

impl StreamPacer {
    pub(crate) fn new(mode: PaceMode) -> Self {
        Self {
            mode,
            buf: String::new(),
            oldest: None,
            last_release: None,
            last_arrival: None,
            ewma_chunk: 0.0,
            ewma_gap: 0.0,
            burst_chars: 0.0,
            seen: 0,
            engaged: false,
        }
    }

    /// Is any text being held back? The event loop uses this to know a tick has
    /// work to do.
    pub(crate) fn is_pending(&self) -> bool {
        !self.buf.is_empty()
    }

    /// Whether the pacer is currently smoothing. Diagnostic only.
    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) fn is_engaged(&self) -> bool {
        self.engaged
    }

    /// Accept a delta, and return what may be rendered right now.
    ///
    /// When not engaged this is `text` itself, unchanged and undelayed — the
    /// pass-through case, which is the whole of a local model's stream and the
    /// warm-up of every turn.
    pub(crate) fn push(&mut self, text: &str, now: Instant) -> String {
        self.observe(text, now);
        if !self.should_engage() {
            // Anything still held from a moment ago goes out with this delta,
            // in order. Disengaging must never strand text behind.
            self.engaged = false;
            self.last_release = Some(now);
            let mut out = std::mem::take(&mut self.buf);
            self.oldest = None;
            out.push_str(text);
            return out;
        }
        if self.buf.is_empty() {
            self.oldest = Some(now);
            // Time that passed while there was nothing to release is not credit
            // to spend now. Without this reset the gap BETWEEN clumps — 130 ms
            // on the owner's model, more than a whole budget — would be paid out
            // against the clump that just arrived, and every clump would go
            // straight back out in one piece.
            self.last_release = Some(now);
        }
        self.engaged = true;
        self.buf.push_str(text);
        // A delta is also a chance to pay out: it is the most frequent event
        // during a stream, so releasing here keeps the cadence even when
        // animation frames are scarce.
        self.release(now)
    }

    /// Release whatever this instant is owed. Returns an empty string when
    /// nothing is due, which callers treat as "no repaint needed".
    pub(crate) fn tick(&mut self, now: Instant) -> String {
        if self.buf.is_empty() {
            return String::new();
        }
        self.release(now)
    }

    /// Hand back everything immediately, whatever the cadence says.
    ///
    /// Every boundary the user must not wait on goes through here: the turn
    /// ending, a tool call starting, an error, an interrupt. It also clears the
    /// engaged flag, so a boundary can never leave the buffer half-armed.
    pub(crate) fn flush(&mut self) -> String {
        self.engaged = false;
        self.oldest = None;
        self.last_release = None;
        std::mem::take(&mut self.buf)
    }

    /// Full per-turn reset: drops held text AND the arrival statistics, so the
    /// next turn decides for itself whether it is clumped.
    pub(crate) fn reset(&mut self) {
        self.buf.clear();
        self.oldest = None;
        self.last_release = None;
        self.last_arrival = None;
        self.ewma_chunk = 0.0;
        self.ewma_gap = 0.0;
        self.burst_chars = 0.0;
        self.seen = 0;
        self.engaged = false;
    }

    // ── internals ────────────────────────────────────────────────────────

    /// Fold this delta into the arrival statistics, at BURST granularity.
    ///
    /// A delta arriving within [`BURST_GAP_MS`] of the previous one extends the
    /// current burst rather than starting a new one; the statistics only move
    /// when a burst *ends*. That is what makes them describe what the screen
    /// can see: deltas inside one burst cannot be told apart by any paint.
    fn observe(&mut self, text: &str, now: Instant) {
        let chars = text.chars().count() as f64;
        let gap_ms = self
            .last_arrival
            .map(|prev| now.saturating_duration_since(prev).as_secs_f64() * 1000.0);
        self.last_arrival = Some(now);

        match gap_ms {
            // First delta of the turn. The wait for it is time-to-first-token,
            // not an inter-burst gap; seeding the gap statistic with it would
            // read as a hugely clumped stream on every single turn.
            None => {
                self.burst_chars = chars;
            }
            // Same burst — accumulate, and do not disturb the averages.
            Some(gap) if gap < BURST_GAP_MS => {
                self.burst_chars += chars;
            }
            // The previous burst just ended: fold it in, and open a new one.
            Some(gap) => {
                self.seen = self.seen.saturating_add(1);
                let closed = self.burst_chars;
                self.burst_chars = chars;
                if self.seen == 1 {
                    self.ewma_chunk = closed;
                    self.ewma_gap = gap;
                } else {
                    self.ewma_chunk = EWMA_ALPHA * closed + (1.0 - EWMA_ALPHA) * self.ewma_chunk;
                    self.ewma_gap = EWMA_ALPHA * gap + (1.0 - EWMA_ALPHA) * self.ewma_gap;
                }
            }
        }
    }

    /// The adaptive decision, with hysteresis.
    fn should_engage(&self) -> bool {
        match self.mode {
            PaceMode::Off => false,
            PaceMode::On => self.seen > WARMUP_DELTAS,
            PaceMode::Auto => {
                if self.seen <= WARMUP_DELTAS {
                    return false;
                }
                if self.engaged {
                    // Stay engaged until arrival is clearly smooth.
                    self.ewma_chunk >= RELEASE_CHUNK_CHARS && self.ewma_gap >= RELEASE_GAP_MS
                } else {
                    self.ewma_chunk >= ENGAGE_CHUNK_CHARS && self.ewma_gap >= ENGAGE_GAP_MS
                }
            }
        }
    }

    /// Pay out the slice this instant is owed.
    ///
    /// Two rules, and the second is the load-bearing one:
    ///
    /// 1. **Rate.** Spend the elapsed time against the budget *remaining* to
    ///    the oldest held character, not against the whole budget. That makes
    ///    the drain finish exactly at the deadline instead of trailing off
    ///    exponentially, and it means a bigger backlog drains faster rather
    ///    than lasting longer. At least one character, so a trickle still moves
    ///    and the very first frame of a clump always shows something.
    /// 2. **Age.** If the oldest held character has reached the budget, release
    ///    *everything*. This is what makes the added latency bounded rather
    ///    than merely small: whatever the arrival rate does, no character can
    ///    sit here for longer than one budget.
    fn release(&mut self, now: Instant) -> String {
        let total = self.buf.chars().count();
        if total == 0 {
            return String::new();
        }
        let age = self
            .oldest
            .map(|t| now.saturating_duration_since(t))
            .unwrap_or(LAG_BUDGET);
        let take = if age >= LAG_BUDGET {
            total
        } else {
            let remaining = LAG_BUDGET - age;
            let elapsed = self
                .last_release
                .map(|t| now.saturating_duration_since(t))
                .unwrap_or(remaining);
            let share = elapsed.as_secs_f64() / remaining.as_secs_f64();
            let want = (total as f64 * share).ceil() as usize;
            want.clamp(1, total)
        };
        self.last_release = Some(now);
        if take >= total {
            self.oldest = None;
            return std::mem::take(&mut self.buf);
        }
        // Char-boundary split: `take` counts characters, never bytes.
        let cut = self
            .buf
            .char_indices()
            .nth(take)
            .map(|(i, _)| i)
            .unwrap_or(self.buf.len());
        let out = self.buf[..cut].to_string();
        self.buf.drain(..cut);
        // `oldest` is deliberately NOT refreshed here. What remains is no
        // younger than what left, and a buffer that is always partially drained
        // would otherwise keep resetting its own age clock and evade the bound.
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Arrival shaped like the owner's cloud model: 28-char clumps, 130 ms
    /// apart.
    fn clumpy(n: usize) -> Vec<(String, Duration)> {
        (0..n)
            .map(|i| ("x".repeat(28), Duration::from_millis(if i == 0 { 0 } else { 130 })))
            .collect()
    }

    /// Arrival shaped like a local model: 4-5 chars, 8 ms apart.
    fn smooth(n: usize) -> Vec<(String, Duration)> {
        (0..n)
            .map(|i| ("abcd".to_string(), Duration::from_millis(if i == 0 { 0 } else { 8 })))
            .collect()
    }

    /// Drive a script of (text, gap-before) through the pacer, ticking every
    /// `tick` in between, and collect everything that was released with the
    /// instant it went out.
    fn drive(
        p: &mut StreamPacer,
        script: &[(String, Duration)],
        tick: Duration,
    ) -> (String, Vec<(Instant, usize)>) {
        let start = Instant::now();
        let mut now = start;
        let mut out = String::new();
        let mut events = Vec::new();
        for (text, gap) in script {
            // Ticks that fall inside the gap.
            let mut t = now;
            while t + tick < now + *gap {
                t += tick;
                let s = p.tick(t);
                if !s.is_empty() {
                    out.push_str(&s);
                    events.push((t, s.chars().count()));
                }
            }
            now += *gap;
            let s = p.push(text, now);
            if !s.is_empty() {
                out.push_str(&s);
                events.push((now, s.chars().count()));
            }
        }
        // Turn end.
        let s = p.flush();
        if !s.is_empty() {
            out.push_str(&s);
            events.push((now, s.chars().count()));
        }
        (out, events)
    }

    fn joined(script: &[(String, Duration)]) -> String {
        script.iter().map(|(t, _)| t.as_str()).collect()
    }

    #[test]
    fn every_byte_comes_out_exactly_once_and_in_order() {
        // The only invariant that is non-negotiable: pacing may change WHEN
        // text appears, never WHAT appears.
        for script in [clumpy(20), smooth(60)] {
            let mut p = StreamPacer::new(PaceMode::Auto);
            let (out, _) = drive(&mut p, &script, Duration::from_millis(32));
            assert_eq!(out, joined(&script));
            assert!(!p.is_pending());
        }
    }

    #[test]
    fn a_clumped_stream_is_spread_over_several_paints() {
        let script = clumpy(20);
        let mut p = StreamPacer::new(PaceMode::Auto);
        let (out, events) = drive(&mut p, &script, Duration::from_millis(32));
        assert_eq!(out, joined(&script));
        assert!(p.is_engaged() || !p.is_pending());

        // Count only the steady state — the warm-up is deliberately unpaced.
        let steady: Vec<usize> = events
            .iter()
            .skip(WARMUP_DELTAS as usize + 1)
            .map(|(_, n)| *n)
            .collect();
        assert!(
            steady.len() > script.len() - WARMUP_DELTAS as usize,
            "pacing produced no extra paints: {steady:?}"
        );
        let biggest = steady.iter().copied().max().unwrap_or(0);
        assert!(
            biggest < 28,
            "a whole 28-char clump still went out in one paint: {steady:?}"
        );
    }

    #[test]
    fn a_smooth_stream_is_never_paced() {
        // A local model must be handed straight through: pacing it would only
        // make it slower, and every delta must come out on the instant it
        // arrived.
        let script = smooth(60);
        let mut p = StreamPacer::new(PaceMode::Auto);
        let start = Instant::now();
        let mut now = start;
        let mut n_delayed = 0;
        for (text, gap) in &script {
            now += *gap;
            let out = p.push(text, now);
            if out != *text {
                n_delayed += 1;
            }
        }
        assert_eq!(n_delayed, 0, "a smooth stream was buffered");
        assert!(!p.is_engaged());
        assert!(!p.is_pending());
    }

    #[test]
    fn the_first_deltas_of_a_turn_are_never_held() {
        // Time to first token is the most visible latency in the app; the
        // warm-up exists so the pacer cannot touch it.
        let mut p = StreamPacer::new(PaceMode::On);
        let mut now = Instant::now();
        for i in 0..WARMUP_DELTAS {
            now += Duration::from_millis(130);
            assert_eq!(p.push("hello", now), "hello", "delta {i} was held during warm-up");
        }
    }

    #[test]
    fn held_text_never_ages_past_the_budget() {
        // The bound that makes the added latency honest. Deltas keep arriving
        // and ticks keep firing; no character may sit in the buffer for longer
        // than one budget.
        let mut p = StreamPacer::new(PaceMode::On);
        let start = Instant::now();
        let mut now = start;
        // Warm up.
        for _ in 0..=WARMUP_DELTAS {
            now += Duration::from_millis(130);
            let _ = p.push("x".repeat(28).as_str(), now);
        }
        let mut worst = Duration::ZERO;
        for _ in 0..60 {
            now += Duration::from_millis(130);
            let _ = p.push("y".repeat(28).as_str(), now);
            // Ticks across the gap.
            for k in 1..4 {
                let t = now + Duration::from_millis(32 * k);
                let _ = p.tick(t);
                if let Some(oldest) = p.oldest {
                    worst = worst.max(t.saturating_duration_since(oldest));
                }
            }
        }
        assert!(
            worst <= LAG_BUDGET,
            "held text aged {worst:?}, past the {LAG_BUDGET:?} budget"
        );
    }

    #[test]
    fn a_burst_far_larger_than_the_budget_still_drains_within_it() {
        // A single huge delta (a whole paragraph in one flush) must not take
        // proportionally longer to appear.
        let mut p = StreamPacer::new(PaceMode::On);
        let start = Instant::now();
        let mut now = start;
        for _ in 0..=WARMUP_DELTAS {
            now += Duration::from_millis(130);
            let _ = p.push("x".repeat(28).as_str(), now);
        }
        let burst_at = now + Duration::from_millis(130);
        let mut got = p.push(&"z".repeat(4000), burst_at).chars().count();
        let mut t = burst_at;
        while got < 4000 && t < burst_at + LAG_BUDGET {
            t += Duration::from_millis(16);
            got += p.tick(t).chars().count();
        }
        // Anything still held at the budget is released by the age rule.
        let t_end = burst_at + LAG_BUDGET;
        got += p.tick(t_end).chars().count();
        assert!(!p.is_pending(), "{} chars still held a budget later", 4000 - got);
    }

    #[test]
    fn flush_releases_everything_and_disarms() {
        let mut p = StreamPacer::new(PaceMode::On);
        let mut now = Instant::now();
        let mut pushed = 0usize;
        let mut released = 0usize;
        // Warm up with ticks in between, exactly as the app drives it, so the
        // buffer is in its ordinary mid-clump state rather than aged out.
        for _ in 0..=WARMUP_DELTAS {
            now += Duration::from_millis(130);
            pushed += 28;
            released += p.push(&"x".repeat(28), now).chars().count();
            for k in 1..4 {
                released += p.tick(now + Duration::from_millis(32 * k)).chars().count();
            }
        }
        // One more clump, and flush the instant it lands.
        now += Duration::from_millis(130);
        pushed += 28;
        released += p.push(&"q".repeat(28), now).chars().count();
        let held = pushed - released;
        assert!(held > 0, "nothing was held, the test proves nothing");
        assert_eq!(p.flush().chars().count(), held);
        assert!(!p.is_pending());
        assert!(!p.is_engaged());
        // A second flush is a no-op, not a repeat.
        assert!(p.flush().is_empty());
    }

    #[test]
    fn mode_off_is_a_pure_pass_through() {
        let script = clumpy(30);
        let mut p = StreamPacer::new(PaceMode::Off);
        let mut now = Instant::now();
        for (text, gap) in &script {
            now += *gap;
            assert_eq!(&p.push(text, now), text);
        }
        assert!(!p.is_pending());
    }

    #[test]
    fn disengaging_hands_back_everything_it_was_holding() {
        // A stream that turns smooth mid-reply must not strand the tail of the
        // clumped part behind, and must not reorder it.
        let mut p = StreamPacer::new(PaceMode::Auto);
        let mut now = Instant::now();
        let mut out = String::new();
        for _ in 0..12 {
            now += Duration::from_millis(130);
            out.push_str(&p.push(&"x".repeat(28), now));
        }
        assert!(p.is_engaged());
        // Now a long run of fast small deltas.
        for _ in 0..40 {
            now += Duration::from_millis(6);
            out.push_str(&p.push("ab", now));
        }
        out.push_str(&p.flush());
        assert!(!p.is_engaged(), "pacer stayed engaged on a smooth stream");
        assert_eq!(out, format!("{}{}", "x".repeat(28 * 12), "ab".repeat(40)));
    }

    #[test]
    fn multibyte_text_is_never_split_mid_character() {
        let mut p = StreamPacer::new(PaceMode::On);
        let mut now = Instant::now();
        let text = "日本語のテキストとえもじ🚀🚀🚀";
        let mut out = String::new();
        for _ in 0..30 {
            now += Duration::from_millis(130);
            out.push_str(&p.push(text, now));
            for k in 1..4 {
                out.push_str(&p.tick(now + Duration::from_millis(32 * k)));
            }
        }
        out.push_str(&p.flush());
        assert_eq!(out, text.repeat(30));
    }

    #[test]
    fn reset_forgets_the_previous_turns_shape() {
        let mut p = StreamPacer::new(PaceMode::Auto);
        let mut now = Instant::now();
        for _ in 0..20 {
            now += Duration::from_millis(130);
            let _ = p.push(&"x".repeat(28), now);
        }
        assert!(p.is_engaged());
        p.reset();
        assert!(!p.is_engaged());
        assert!(!p.is_pending());
        // A fresh turn is unpaced again until it has earned it.
        now += Duration::from_millis(500);
        assert_eq!(p.push("hi", now), "hi");
    }

    #[test]
    fn env_parsing() {
        // Only the explicit words switch the mode; anything else is Auto.
        // Unset — and anything unrecognised — is OFF. The measurements say a
        // pacer is not wanted on the streams tested, so it must be opted into.
        for (v, want) in [
            ("off", PaceMode::Off),
            ("OFF", PaceMode::Off),
            ("0", PaceMode::Off),
            ("on", PaceMode::On),
            ("always", PaceMode::On),
            ("auto", PaceMode::Auto),
            ("AUTO", PaceMode::Auto),
            ("", PaceMode::Off),
            ("nonsense", PaceMode::Off),
        ] {
            // SAFETY: single-threaded test, and the value is read immediately.
            unsafe { std::env::set_var("OSA_STREAM_PACE", v) };
            assert_eq!(PaceMode::from_env(), want, "for {v:?}");
        }
        unsafe { std::env::remove_var("OSA_STREAM_PACE") };
    }
}
