pub mod capture;
pub mod transcribe;

pub use capture::VoiceCapture;
pub use transcribe::{VoiceProvider, CloudTranscriber, GroqTranscriber};

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
    /// Whether voice input can run right now (local engine present/provisionable
    /// or a cloud API key configured). Drives the greyed mic affordance.
    pub available: bool,
}

impl VoiceState {
    pub fn new() -> Self {
        let provider = match std::env::var("VOICE_PROVIDER").as_deref() {
            Ok("groq") => {
                if let Ok(key) = std::env::var("GROQ_API_KEY") {
                    VoiceProvider::Groq(GroqTranscriber::new(key))
                } else {
                    tracing::warn!("VOICE_PROVIDER=groq but no GROQ_API_KEY, falling back to local");
                    VoiceProvider::local_or_unavailable()
                }
            }
            Ok("cloud") | Ok("openai") => {
                if let Ok(key) = std::env::var("OPENAI_API_KEY") {
                    VoiceProvider::Cloud(CloudTranscriber::new(key))
                } else {
                    tracing::warn!("VOICE_PROVIDER=cloud but no OPENAI_API_KEY, falling back to local");
                    VoiceProvider::local_or_unavailable()
                }
            }
            _ => VoiceProvider::local_or_unavailable(),
        };

        let available = provider_available(&provider);

        Self {
            recording: false,
            started_at: None,
            capture: None,
            provider,
            hands_free: false,
            silence_start: None,
            available,
        }
    }

    /// One-line startup warning when voice cannot run out of the box, else None.
    /// Suitable for a startup toast alongside the greyed mic.
    #[allow(dead_code)]
    pub fn preflight_warning(&self) -> Option<String> {
        if self.available {
            None
        } else {
            Some(
                "Voice input unavailable \u{2014} no local whisper engine and no \
                 OPENAI_API_KEY/GROQ_API_KEY. Install whisper.cpp, set \
                 OSA_WHISPER_URL, or run with VOICE_PROVIDER=cloud."
                    .to_string(),
            )
        }
    }

    /// Elapsed recording time in seconds
    pub fn elapsed_secs(&self) -> u64 {
        self.started_at
            .map(|s| s.elapsed().as_secs())
            .unwrap_or(0)
    }
}

/// Whether the selected provider can transcribe right now (drives the mic state).
fn provider_available(provider: &VoiceProvider) -> bool {
    match provider {
        VoiceProvider::Cloud(c) => !c.api_key().is_empty(),
        VoiceProvider::Groq(g) => !g.api_key().is_empty(),
        VoiceProvider::Local(l) => l.engine_available(),
    }
}
