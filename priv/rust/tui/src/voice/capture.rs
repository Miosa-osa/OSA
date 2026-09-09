use anyhow::{Context, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::{Arc, Mutex};
use tracing::{error, info, warn};

/// Captured audio buffer — accumulated PCM samples at 16kHz mono
#[derive(Clone)]
pub struct AudioBuffer {
    pub samples: Arc<Mutex<Vec<f32>>>,
    pub sample_rate: u32,
}

impl AudioBuffer {
    fn new(sample_rate: u32) -> Self {
        Self {
            samples: Arc::new(Mutex::new(Vec::with_capacity(sample_rate as usize * 300))),
            sample_rate,
        }
    }

    /// Get total duration of captured audio in seconds
    pub fn duration_secs(&self) -> f32 {
        let len = self.samples.lock().unwrap().len();
        len as f32 / self.sample_rate as f32
    }

    /// Export as 16-bit PCM WAV bytes
    pub fn to_wav_bytes(&self) -> Result<Vec<u8>> {
        let samples = self.samples.lock().unwrap();
        let spec = hound::WavSpec {
            channels: 1,
            sample_rate: self.sample_rate,
            bits_per_sample: 16,
            sample_format: hound::SampleFormat::Int,
        };
        let mut cursor = std::io::Cursor::new(Vec::new());
        {
            let mut writer =
                hound::WavWriter::new(&mut cursor, spec).context("Failed to create WAV writer")?;
            for &s in samples.iter() {
                let pcm = (s * 32767.0).clamp(-32768.0, 32767.0) as i16;
                writer.write_sample(pcm)?;
            }
            writer.finalize()?;
        }
        Ok(cursor.into_inner())
    }

    /// Export as raw f32 samples (for whisper-rs which takes &[f32])
    #[allow(dead_code)]
    pub fn raw_samples(&self) -> Vec<f32> {
        self.samples.lock().unwrap().clone()
    }
}

/// Voice capture — manages the cpal input stream
pub struct VoiceCapture {
    stream: Option<cpal::Stream>,
    buffer: AudioBuffer,
    /// Current audio input level (0-100), updated from capture callback
    level: Arc<AtomicU8>,
}

// cpal::Stream is not Send by default on all platforms, but we need it
// for the tokio runtime. The stream is only accessed from the main thread.
unsafe impl Send for VoiceCapture {}

impl VoiceCapture {
    /// Start capturing audio from the default input device
    /// Uses the device's native format and resamples to 16kHz mono
    pub fn start() -> Result<Self> {
        let host = cpal::default_host();
        let device = host
            .default_input_device()
            .context("No audio input device found")?;

        let device_name = device.name().unwrap_or_else(|_| "unknown".into());
        info!("Using audio input device: {}", device_name);

        // Use the device's default input config instead of forcing 16kHz
        let supported = device
            .default_input_config()
            .context("No supported input config")?;

        let device_sample_rate = supported.sample_rate().0;
        let device_channels = supported.channels() as usize;
        info!(
            "Device native format: {}Hz, {} channels",
            device_sample_rate, device_channels
        );

        let config = cpal::StreamConfig {
            channels: device_channels as u16,
            sample_rate: cpal::SampleRate(device_sample_rate),
            buffer_size: cpal::BufferSize::Default,
        };

        let target_sample_rate = 16000u32;
        let buffer = AudioBuffer::new(target_sample_rate);
        let write_buf = buffer.samples.clone();
        let level = Arc::new(AtomicU8::new(0));
        let level_write = level.clone();

        // Pre-compute resample ratio
        let ratio = device_sample_rate as f64 / target_sample_rate as f64;

        let err_fn = |err: cpal::StreamError| {
            error!("Audio capture error: {}", err);
        };

        let stream = device
            .build_input_stream(
                &config,
                move |data: &[f32], _: &cpal::InputCallbackInfo| {
                    if let Ok(mut buf) = write_buf.lock() {
                        // Downmix to mono, then resample to 16kHz
                        let mono_samples: Vec<f32> = data
                            .chunks(device_channels)
                            .map(|frame| frame.iter().sum::<f32>() / device_channels as f32)
                            .collect();

                        // Compute RMS level from mono samples (0.0-1.0 → 0-100)
                        if !mono_samples.is_empty() {
                            let sum_sq: f32 = mono_samples.iter().map(|s| s * s).sum();
                            let rms = (sum_sq / mono_samples.len() as f32).sqrt();
                            // Scale: typical speech is ~0.01-0.1 RMS, clamp to 0-100
                            let scaled = (rms * 500.0).clamp(0.0, 100.0) as u8;
                            level_write.store(scaled, Ordering::Relaxed);
                        }

                        // Simple linear resampling from device rate to 16kHz
                        let out_len = (mono_samples.len() as f64 / ratio).ceil() as usize;
                        for i in 0..out_len {
                            let src_idx = i as f64 * ratio;
                            let idx0 = src_idx as usize;
                            let frac = src_idx - idx0 as f64;
                            let s0 = mono_samples.get(idx0).copied().unwrap_or(0.0);
                            let s1 = mono_samples.get(idx0 + 1).copied().unwrap_or(s0);
                            let sample = s0 + (s1 - s0) * frac as f32;
                            buf.push(sample);
                        }
                    }
                },
                err_fn,
                None,
            )
            .context("Failed to build audio input stream")?;

        stream.play().context("Failed to start audio capture")?;
        info!(
            "Audio capture started (device {}Hz {}ch -> 16kHz mono)",
            device_sample_rate, device_channels
        );

        Ok(Self {
            stream: Some(stream),
            buffer,
            level,
        })
    }

    /// Stop capturing and return the audio buffer
    pub fn stop(mut self) -> AudioBuffer {
        if let Some(stream) = self.stream.take() {
            drop(stream);
        }
        info!(
            "Audio capture stopped — {:.1}s recorded",
            self.buffer.duration_secs()
        );
        self.buffer.clone()
    }

    /// Deprecated: recording is no longer capped. Always returns false.
    #[deprecated(note = "Recording cap removed — buffer grows unbounded")]
    #[allow(dead_code)]
    pub fn is_at_limit(&self) -> bool {
        false
    }

    /// Current recording duration in seconds
    #[allow(dead_code)]
    pub fn duration_secs(&self) -> f32 {
        self.buffer.duration_secs()
    }

    /// Current audio input level (0-100)
    pub fn level(&self) -> u8 {
        self.level.load(Ordering::Relaxed)
    }
}

impl Drop for VoiceCapture {
    fn drop(&mut self) {
        if let Some(stream) = self.stream.take() {
            drop(stream);
            warn!("VoiceCapture dropped while still recording");
        }
    }
}
