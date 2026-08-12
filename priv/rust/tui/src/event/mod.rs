pub mod backend;
pub mod terminal;

use backend::BackendEvent;
use crossterm::event::Event as CrosstermEvent;

/// Voice subsystem events
#[derive(Debug)]
#[allow(dead_code)]
pub enum VoiceEvent {
    /// Transcription completed successfully
    TranscriptionReady(String),
    /// Transcription failed
    TranscriptionError(String),
    /// Recording hit a time/size limit (kept for future use)
    RecordingStopped,
    /// Download progress for whisper binary or model
    DownloadProgress {
        label: String,
        downloaded: u64,
        total: u64,
    },
    /// Audio input level (RMS 0.0..1.0) from mic capture
    AudioLevel(f32),
    /// Hands-free mode: restart recording after transcription
    HandsFreeRestart,
}

/// Unified event type — all event sources merge into this
#[derive(Debug)]
pub enum Event {
    /// Terminal input (keys, mouse, resize)
    Terminal(CrosstermEvent),
    /// Backend SSE or HTTP response events
    Backend(BackendEvent),
    /// Voice input events
    Voice(VoiceEvent),
    /// App-internal timer events
    Tick,
    /// A repaint request for a running animation, and NOTHING else.
    ///
    /// `Tick` is a 200ms bookkeeping pulse: it advances toasts, the agents
    /// panel, the checklist and the activity phrase counter, and it is the
    /// cadence the inline-viewport shrink debounce is counted in. It cannot be
    /// sped up without retuning all of that.
    ///
    /// But 200ms is also the ONLY thing that repaints the screen while the app
    /// sits waiting on the provider, so the spinner ran at 5fps — and the glyph
    /// index is a 133ms wall clock, so frames aliased and the spinner visibly
    /// skipped. Every reference harness repaints its status indicator on its own
    /// timer at ~30fps (codex's `status_indicator_widget` self-schedules every
    /// 32ms). This is that timer: it carries no state and mutates nothing. Its
    /// entire job is to make the loop come round and draw.
    AnimationFrame,
    /// Health retry
    HealthRetry,
}
