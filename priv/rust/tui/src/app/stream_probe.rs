//! Streaming shape probe: what arrives, and what gets painted.
//!
//! Three attempts at the "streaming looks chunky" complaint were argued from
//! synthetic benches and all three were wrong, because a bench feeds deltas at
//! a cadence the bench author chose. The one distribution nobody had measured
//! is the real one: how the PROVIDER chunks its stream, and how much of it each
//! paint reveals.
//!
//! So this records exactly two things, with timestamps, on a real turn:
//!
//!   * `delta` — a streaming token as it arrives off the wire, and its size.
//!   * `paint` — a frame being drawn, and how many characters of assistant text
//!     were visible for the first time in it.
//!
//! Comparing the two answers the question that decides the fix. If deltas are
//! smooth and paints are lumpy, the loop is at fault. If the deltas themselves
//! arrive in slabs, no amount of paint scheduling helps and the fix is a reveal
//! pacer that spreads an arrived slab over several frames.
//!
//! Off unless `OSA_STREAM_PROBE` names a file; then it is one append per event,
//! buffered, on a mutex that is never contended (the event loop is one thread).

use std::io::Write;
use std::sync::Mutex;
use std::time::Instant;

struct Probe {
    out: std::io::BufWriter<std::fs::File>,
    start: Instant,
    /// Assistant characters revealed so far, so a paint can report its DELTA
    /// rather than the running total.
    painted: usize,
}

static PROBE: Mutex<Option<Probe>> = Mutex::new(None);
static ENABLED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Open the probe if `OSA_STREAM_PROBE` names a writable path. Call once at startup.
pub fn init() {
    let Ok(path) = std::env::var("OSA_STREAM_PROBE") else {
        return;
    };
    if path.is_empty() {
        return;
    }
    if let Ok(f) = std::fs::File::create(&path) {
        *PROBE.lock().unwrap() = Some(Probe {
            out: std::io::BufWriter::new(f),
            start: Instant::now(),
            painted: 0,
        });
        ENABLED.store(true, std::sync::atomic::Ordering::Relaxed);
    }
}

#[inline]
fn on() -> bool {
    ENABLED.load(std::sync::atomic::Ordering::Relaxed)
}

/// Record a streaming delta arriving off the wire.
pub fn delta(len: usize) {
    if !on() {
        return;
    }
    with(|p| {
        let t = p.start.elapsed().as_micros();
        let _ = writeln!(p.out, r#"{{"t":{t},"kind":"delta","n":{len}}}"#);
    });
}

/// Record a paint, given the total assistant characters currently on screen.
/// Reports the number newly revealed by this frame.
pub fn paint(total_chars: usize) {
    if !on() {
        return;
    }
    with(|p| {
        let t = p.start.elapsed().as_micros();
        // A turn reset can lower the total; treat that as a fresh baseline
        // rather than reporting a negative reveal.
        let n = total_chars.saturating_sub(p.painted);
        p.painted = total_chars;
        let _ = writeln!(p.out, r#"{{"t":{t},"kind":"paint","n":{n}}}"#);
    });
}

/// Mark a turn boundary so a run can be split per turn during analysis.
pub fn turn(label: &str) {
    if !on() {
        return;
    }
    with(|p| {
        let t = p.start.elapsed().as_micros();
        p.painted = 0;
        let _ = writeln!(p.out, r#"{{"t":{t},"kind":"turn","label":"{label}"}}"#);
        let _ = p.out.flush();
    });
}

fn with(f: impl FnOnce(&mut Probe)) {
    if let Ok(mut guard) = PROBE.lock() {
        if let Some(p) = guard.as_mut() {
            f(p);
        }
    }
}
