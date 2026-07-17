use anyhow::{Context, Result};
use futures::StreamExt;
use tracing::info;

use super::capture::AudioBuffer;

/// Transcription provider — local CLI whisper.cpp, cloud OpenAI, or Groq
pub enum VoiceProvider {
    Local(LocalTranscriber),
    Cloud(CloudTranscriber),
    Groq(GroqTranscriber),
}

impl VoiceProvider {
    /// Transcribe audio buffer to text
    #[allow(dead_code)]
    pub async fn transcribe(&self, buffer: AudioBuffer) -> Result<String> {
        match self {
            VoiceProvider::Local(local) => local.transcribe(buffer).await,
            VoiceProvider::Cloud(cloud) => cloud.transcribe(buffer).await,
            VoiceProvider::Groq(groq) => groq.transcribe(buffer).await,
        }
    }

    /// Transcribe with download progress events sent to the given channel
    pub async fn transcribe_with_progress(
        &self,
        buffer: AudioBuffer,
        progress_tx: Option<&tokio::sync::mpsc::UnboundedSender<crate::event::Event>>,
    ) -> Result<String> {
        match self {
            VoiceProvider::Local(local) => local.transcribe_with_progress(buffer, progress_tx).await,
            VoiceProvider::Cloud(cloud) => cloud.transcribe(buffer).await,
            VoiceProvider::Groq(groq) => groq.transcribe(buffer).await,
        }
    }

    /// Create a local provider (always available — uses CLI binary)
    pub fn local_or_unavailable() -> Self {
        VoiceProvider::Local(LocalTranscriber::new())
    }
}

impl std::fmt::Debug for VoiceProvider {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            VoiceProvider::Local(_) => write!(f, "Local(whisper-cli)"),
            VoiceProvider::Cloud(_) => write!(f, "Cloud(OpenAI whisper-1)"),
            VoiceProvider::Groq(_) => write!(f, "Groq(whisper-large-v3-turbo)"),
        }
    }
}

// ── Local transcriber (CLI-based, no LLVM needed) ────────────

pub struct LocalTranscriber {
    osa_dir: std::path::PathBuf,
    model_name: String,
}

impl LocalTranscriber {
    pub fn new() -> Self {
        let osa_dir = std::env::var("OSA_HOME")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|_| {
                directories::BaseDirs::new()
                    .map(|d| d.home_dir().join(".osa"))
                    .unwrap_or_else(|| std::path::PathBuf::from(".osa"))
            });

        let model_name = std::env::var("WHISPER_MODEL")
            .unwrap_or_else(|_| "tiny".to_string());

        Self { osa_dir, model_name }
    }

    fn bin_dir(&self) -> std::path::PathBuf {
        self.osa_dir.join("bin")
    }

    fn models_dir(&self) -> std::path::PathBuf {
        self.osa_dir.join("models")
    }

    fn whisper_bin(&self) -> std::path::PathBuf {
        let name = if cfg!(windows) { "whisper-cli.exe" } else { "whisper-cli" };
        self.bin_dir().join(name)
    }

    fn model_path(&self) -> std::path::PathBuf {
        self.models_dir().join(format!("ggml-{}.bin", self.model_name))
    }

    /// Download the pre-built whisper-cli binary for this platform
    #[cfg_attr(not(target_os = "windows"), allow(unused_variables))]
    async fn ensure_binary(&self, progress_tx: Option<&tokio::sync::mpsc::UnboundedSender<crate::event::Event>>) -> Result<std::path::PathBuf> {
        let bin = self.whisper_bin();
        if bin.exists() {
            return Ok(bin);
        }

        // Check if whisper-cli is already on the system PATH
        if let Ok(output) = std::process::Command::new(if cfg!(windows) { "where" } else { "which" })
            .arg("whisper-cli")
            .output()
        {
            if output.status.success() {
                let path_str = String::from_utf8_lossy(&output.stdout).trim().lines().next().unwrap_or("").to_string();
                if !path_str.is_empty() {
                    let system_bin = std::path::PathBuf::from(&path_str);
                    if system_bin.exists() {
                        info!("Found system whisper-cli: {}", path_str);
                        return Ok(system_bin);
                    }
                }
            }
        }

        // On Windows, download pre-built binary from whisper.cpp releases
        #[cfg(target_os = "windows")]
        {
            return self.download_whisper_binary(progress_tx).await;
        }

        // macOS/Linux: no pre-built CLI binaries available from upstream
        #[cfg(not(target_os = "windows"))]
        {
            let install_hint = if cfg!(target_os = "macos") {
                "brew install whisper-cpp"
            } else {
                "sudo apt install whisper-cpp   # or build from source: https://github.com/ggerganov/whisper.cpp"
            };
            anyhow::bail!(
                "whisper-cli not found. Install it and try again:\n  {}\n\nOr use cloud transcription: export VOICE_PROVIDER=cloud",
                install_hint
            );
        }
    }

    /// Download and extract the pre-built Windows whisper-cli binary
    #[cfg(target_os = "windows")]
    async fn download_whisper_binary(&self, progress_tx: Option<&tokio::sync::mpsc::UnboundedSender<crate::event::Event>>) -> Result<std::path::PathBuf> {
        let bin = self.whisper_bin();

        std::fs::create_dir_all(self.bin_dir())
            .context("Failed to create ~/.osa/bin")?;

        let platform = platform_archive_name();
        let tag = "v1.8.3";
        let archive_name = format!("whisper-bin-{}.zip", platform);
        let url = format!(
            "https://github.com/ggerganov/whisper.cpp/releases/download/{}/{}",
            tag, archive_name
        );

        info!("Downloading whisper-cli: {}", url);

        let response = reqwest::Client::new()
            .get(&url)
            .send()
            .await
            .context("Failed to download whisper-cli")?;

        if !response.status().is_success() {
            anyhow::bail!(
                "Failed to download whisper-cli: HTTP {} ({})",
                response.status(), url
            );
        }

        let total_size = response.content_length().unwrap_or(0);
        let mut downloaded: u64 = 0;
        let mut body = Vec::new();
        let mut stream = response.bytes_stream();
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.context("Error reading download stream")?;
            downloaded += chunk.len() as u64;
            body.extend_from_slice(&chunk);
            if let Some(tx) = &progress_tx {
                if total_size > 0 {
                    let _ = tx.send(crate::event::Event::Voice(
                        crate::event::VoiceEvent::DownloadProgress {
                            label: "whisper-cli".into(),
                            downloaded,
                            total: total_size,
                        },
                    ));
                }
            }
        }
        info!("Downloaded {:.1}MB, extracting...", body.len() as f64 / 1_048_576.0);

        // Extract whisper-cli + required DLLs from the zip
        let cursor = std::io::Cursor::new(&body);
        let mut archive = zip::ZipArchive::new(cursor)
            .context("Failed to open whisper zip archive")?;

        let needed: &[&str] = &["whisper-cli.exe", "whisper.dll", "ggml.dll", "ggml-base.dll", "ggml-cpu.dll"];

        for i in 0..archive.len() {
            let mut file = archive.by_index(i)?;
            let name = file.name().to_string();
            let basename = name.rsplit('/').next().unwrap_or(&name);
            if needed.iter().any(|n| *n == basename) {
                let dest = self.bin_dir().join(basename);
                let mut out = std::fs::File::create(&dest)
                    .with_context(|| format!("Failed to create {}", dest.display()))?;
                std::io::copy(&mut file, &mut out)?;
                info!("Extracted: {}", basename);
            }
        }

        if !bin.exists() {
            anyhow::bail!("whisper-cli not found in archive");
        }

        info!("whisper-cli installed to {:?}", bin);
        Ok(bin)
    }

    /// Download the ggml model if not present
    async fn ensure_model(&self, progress_tx: Option<&tokio::sync::mpsc::UnboundedSender<crate::event::Event>>) -> Result<std::path::PathBuf> {
        let path = self.model_path();
        if path.exists() {
            return Ok(path);
        }

        std::fs::create_dir_all(self.models_dir())
            .context("Failed to create ~/.osa/models")?;

        let url = format!(
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-{}.bin",
            self.model_name
        );

        info!("Downloading whisper model: {}", url);

        let response = reqwest::Client::new()
            .get(&url)
            .send()
            .await
            .context("Failed to download whisper model")?;

        if !response.status().is_success() {
            anyhow::bail!("Failed to download model: HTTP {}", response.status());
        }

        let total_size = response.content_length().unwrap_or(0);
        let mut downloaded: u64 = 0;
        let mut file = std::fs::File::create(&path)
            .context("Failed to create whisper model file")?;
        let mut stream = response.bytes_stream();
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.context("Error reading model download stream")?;
            downloaded += chunk.len() as u64;
            std::io::Write::write_all(&mut file, &chunk)
                .context("Failed to write whisper model chunk")?;
            if let Some(tx) = &progress_tx {
                if total_size > 0 {
                    let _ = tx.send(crate::event::Event::Voice(
                        crate::event::VoiceEvent::DownloadProgress {
                            label: format!("ggml-{}.bin", self.model_name),
                            downloaded,
                            total: total_size,
                        },
                    ));
                }
            }
        }

        info!("Whisper model downloaded: {:.1}MB", downloaded as f64 / 1_048_576.0);
        Ok(path)
    }

    #[allow(dead_code)]
    pub async fn transcribe(&self, buffer: AudioBuffer) -> Result<String> {
        self.transcribe_with_progress(buffer, None).await
    }

    pub async fn transcribe_with_progress(
        &self,
        buffer: AudioBuffer,
        progress_tx: Option<&tokio::sync::mpsc::UnboundedSender<crate::event::Event>>,
    ) -> Result<String> {
        let bin = self.ensure_binary(progress_tx).await?;
        let model = self.ensure_model(progress_tx).await?;

        // Write WAV to temp file
        let wav_bytes = buffer.to_wav_bytes()?;
        let tmp_dir = std::env::temp_dir();
        let wav_path = tmp_dir.join("osa_voice_input.wav");
        std::fs::write(&wav_path, &wav_bytes)
            .context("Failed to write temp WAV file")?;

        info!("Running whisper-cli on {:.1}KB audio", wav_bytes.len() as f64 / 1024.0);

        // Run whisper-cli: outputs plain text to stdout
        let output = tokio::process::Command::new(&bin)
            .arg("-m").arg(&model)
            .arg("-f").arg(&wav_path)
            .arg("-l").arg("en")
            .arg("--no-timestamps")
            .arg("-nt")  // no timestamps in output
            .output()
            .await
            .context("Failed to run whisper-cli")?;

        // Clean up temp file
        let _ = std::fs::remove_file(&wav_path);

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            anyhow::bail!("whisper-cli failed: {}", stderr);
        }

        let text = String::from_utf8_lossy(&output.stdout)
            .trim()
            .to_string();

        info!("Local transcription complete: {} chars", text.len());
        Ok(text)
    }
}

/// Get platform archive name for whisper.cpp release downloads
#[allow(dead_code)]
fn platform_archive_name() -> &'static str {
    if cfg!(target_os = "windows") {
        if cfg!(target_arch = "x86_64") { "x64" }
        else { "Win32" }
    } else if cfg!(target_os = "macos") {
        "apple-darwin"  // not distributed via GitHub, but placeholder
    } else {
        "x64"  // Linux x64
    }
}

// ── Cloud transcriber (always available) ─────────────────────

pub struct CloudTranscriber {
    api_key: String,
}

impl CloudTranscriber {
    pub fn new(api_key: String) -> Self {
        Self { api_key }
    }

    pub fn api_key(&self) -> &str {
        &self.api_key
    }

    pub async fn transcribe(&self, buffer: AudioBuffer) -> Result<String> {
        let wav_bytes = buffer.to_wav_bytes()?;

        if wav_bytes.len() < 100 {
            return Ok(String::new());
        }

        info!("Sending {:.1}KB audio to OpenAI Whisper API", wav_bytes.len() as f64 / 1024.0);

        let client = reqwest::Client::new();
        let part = reqwest::multipart::Part::bytes(wav_bytes)
            .file_name("audio.wav")
            .mime_str("audio/wav")?;

        let form = reqwest::multipart::Form::new()
            .text("model", "whisper-1")
            .text("language", "en")
            .text("response_format", "text")
            .part("file", part);

        let response = client
            .post("https://api.openai.com/v1/audio/transcriptions")
            .bearer_auth(&self.api_key)
            .multipart(form)
            .send()
            .await
            .context("Failed to call OpenAI Whisper API")?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            anyhow::bail!("OpenAI Whisper API error: {} — {}", status, body);
        }

        let text = response.text().await?;
        info!("Cloud transcription complete: {} chars", text.len());
        Ok(text.trim().to_string())
    }
}

// ── Groq transcriber (Whisper via Groq API) ──────────────────

pub struct GroqTranscriber {
    api_key: String,
}

impl GroqTranscriber {
    pub fn new(api_key: String) -> Self {
        Self { api_key }
    }

    pub fn api_key(&self) -> &str {
        &self.api_key
    }

    pub async fn transcribe(&self, buffer: AudioBuffer) -> Result<String> {
        let wav_bytes = buffer.to_wav_bytes()?;

        if wav_bytes.len() < 100 {
            return Ok(String::new());
        }

        info!("Sending {:.1}KB audio to Groq Whisper API", wav_bytes.len() as f64 / 1024.0);

        let client = reqwest::Client::new();
        let part = reqwest::multipart::Part::bytes(wav_bytes)
            .file_name("audio.wav")
            .mime_str("audio/wav")?;

        let form = reqwest::multipart::Form::new()
            .text("model", "whisper-large-v3-turbo")
            .text("language", "en")
            .text("response_format", "text")
            .part("file", part);

        let response = client
            .post("https://api.groq.com/openai/v1/audio/transcriptions")
            .bearer_auth(&self.api_key)
            .multipart(form)
            .send()
            .await
            .context("Failed to call Groq Whisper API")?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            anyhow::bail!("Groq Whisper API error: {} — {}", status, body);
        }

        let text = response.text().await?;
        info!("Groq transcription complete: {} chars", text.len());
        Ok(text.trim().to_string())
    }
}
