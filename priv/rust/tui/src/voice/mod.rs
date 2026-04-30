pub mod capture;
pub mod transcribe;

pub use capture::VoiceCapture;
pub use transcribe::{CloudTranscriber, GroqTranscriber, VoiceProvider};

use std::time::Instant;

/// Voice recording state held by the App
pub struct VoiceState {
    /// Whether we are currently recording
    pub recording: bool,
    /// When recording started
    pub started_at: Option<Instant>,
    /// The active capture handle (holds the cpal stream)
    pub capture: Option<VoiceCapture>,
    /// Which transcription provider to use
    pub provider: VoiceProvider,
    /// Hands-free mode: auto-record, auto-stop on silence, auto-submit
    pub hands_free: bool,
    /// When silence started (for VAD stop detection)
    pub silence_start: Option<Instant>,
}

impl VoiceState {
    pub fn new() -> Self {
        let provider = match std::env::var("VOICE_PROVIDER").as_deref() {
            Ok("groq") => {
                if let Ok(key) = std::env::var("GROQ_API_KEY") {
                    VoiceProvider::Groq(GroqTranscriber::new(key))
                } else {
                    tracing::warn!(
                        "VOICE_PROVIDER=groq but no GROQ_API_KEY, falling back to local"
                    );
                    VoiceProvider::local_or_unavailable()
                }
            }
            Ok("cloud") | Ok("openai") => {
                if let Ok(key) = std::env::var("OPENAI_API_KEY") {
                    VoiceProvider::Cloud(CloudTranscriber::new(key))
                } else {
                    tracing::warn!(
                        "VOICE_PROVIDER=cloud but no OPENAI_API_KEY, falling back to local"
                    );
                    VoiceProvider::local_or_unavailable()
                }
            }
            _ => VoiceProvider::local_or_unavailable(),
        };

        Self {
            recording: false,
            started_at: None,
            capture: None,
            provider,
            hands_free: false,
            silence_start: None,
        }
    }

    /// Elapsed recording time in seconds
    pub fn elapsed_secs(&self) -> u64 {
        self.started_at.map(|s| s.elapsed().as_secs()).unwrap_or(0)
    }
}
