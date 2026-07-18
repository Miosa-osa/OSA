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
    /// Transcription language passed to whisper-cli's `-l` flag. `auto` lets
    /// whisper.cpp auto-detect. Set from `WHISPER_LANG`.
    lang: String,
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

        let lang = whisper_lang();

        Self { osa_dir, model_name, lang }
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

    /// Ensure a whisper-cli binary is available: use the one in `~/.osa/bin`, one
    /// already on PATH, or auto-provision a pre-built binary for this platform.
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

        // Auto-provision a pre-built binary. Cross-platform: on Windows this pulls
        // the upstream whisper.cpp release; on macOS/Linux it succeeds when
        // `OSA_WHISPER_URL` points at a compatible archive, otherwise it returns an
        // actionable error (install whisper.cpp locally or use cloud).
        self.download_whisper_binary(progress_tx).await
    }

    /// Download and extract a pre-built whisper-cli binary for this platform.
    /// Cross-platform: on Windows this pulls the upstream whisper.cpp release
    /// zip; on macOS/Linux it succeeds only when `OSA_WHISPER_URL` points at a
    /// compatible archive (upstream publishes no macOS/Linux CLI binaries).
    async fn download_whisper_binary(&self, progress_tx: Option<&tokio::sync::mpsc::UnboundedSender<crate::event::Event>>) -> Result<std::path::PathBuf> {
        let bin = self.whisper_bin();

        std::fs::create_dir_all(self.bin_dir())
            .context("Failed to create the OSA bin directory")?;

        let url = resolve_binary_download_url()?;
        info!("Downloading whisper-cli: {}", url);

        let response = reqwest::Client::new()
            .get(&url)
            .send()
            .await
            .context("Failed to download whisper-cli")?;

        if !response.status().is_success() {
            anyhow::bail!(
                "Failed to download whisper-cli: HTTP {} ({}). The pinned asset may \
                 have been renamed or removed \u{2014} override the release tag with \
                 OSA_WHISPER_TAG, point OSA_WHISPER_URL at a working archive, or use \
                 cloud transcription (export VOICE_PROVIDER=cloud).",
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

        self.extract_whisper_archive(&body)?;

        if !bin.exists() {
            anyhow::bail!("whisper-cli binary not found in the downloaded archive ({})", url);
        }

        info!("whisper-cli installed to {:?}", bin);
        Ok(bin)
    }

    /// Extract the whisper-cli binary (and its runtime deps) from a downloaded
    /// zip archive into the OSA bin dir. OS-aware: Windows keeps the CLI plus its
    /// DLLs; unix keeps the CLI (published as `whisper-cli` or `main`) plus any
    /// shared objects, and marks them executable.
    fn extract_whisper_archive(&self, body: &[u8]) -> Result<()> {
        let cursor = std::io::Cursor::new(body);
        let mut archive = zip::ZipArchive::new(cursor)
            .context("Failed to open whisper zip archive")?;

        for i in 0..archive.len() {
            let mut file = archive.by_index(i)?;
            let name = file.name().to_string();
            let basename = name
                .rsplit(|c| c == '/' || c == '\\')
                .next()
                .unwrap_or(&name)
                .to_string();
            if basename.is_empty() || !wanted_archive_member(&basename) {
                continue;
            }
            // Unix upstream/mirror builds may name the CLI `main`; normalise so
            // `whisper_bin()` resolves it.
            let dest_name = if !cfg!(windows) && basename == "main" {
                "whisper-cli".to_string()
            } else {
                basename.clone()
            };
            let dest = self.bin_dir().join(&dest_name);
            {
                let mut out = std::fs::File::create(&dest)
                    .with_context(|| format!("Failed to create {}", dest.display()))?;
                std::io::copy(&mut file, &mut out)?;
            }
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                if let Ok(meta) = std::fs::metadata(&dest) {
                    let mut perms = meta.permissions();
                    perms.set_mode(perms.mode() | 0o755);
                    let _ = std::fs::set_permissions(&dest, perms);
                }
            }
            info!("Extracted: {}", dest_name);
        }
        Ok(())
    }

    /// Best-effort synchronous check for whether local transcription can run:
    /// the binary exists, is on PATH, this platform auto-provisions it (Windows),
    /// or a download URL is configured. Used to grey the mic at startup.
    pub fn engine_available(&self) -> bool {
        if self.whisper_bin().exists() {
            return true;
        }
        if which_whisper_on_path() {
            return true;
        }
        cfg!(target_os = "windows")
            || std::env::var("OSA_WHISPER_URL")
                .map(|u| !u.trim().is_empty())
                .unwrap_or(false)
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

        // Write WAV to a per-process/per-call unique temp file under the OSA data
        // dir (never the shared system temp) so concurrent recordings or multiple
        // OSA instances never race on a fixed filename (truncation, cross-
        // contamination, or EACCES on a stale root-owned file in a shared /tmp).
        let wav_bytes = buffer.to_wav_bytes()?;
        let tmp_dir = self.osa_dir.join("tmp");
        std::fs::create_dir_all(&tmp_dir)
            .context("Failed to create the OSA tmp directory")?;
        let nonce = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let wav_path = tmp_dir.join(format!("osa_voice_{}_{}.wav", std::process::id(), nonce));
        std::fs::write(&wav_path, &wav_bytes)
            .context("Failed to write temp WAV file")?;

        info!("Running whisper-cli on {:.1}KB audio", wav_bytes.len() as f64 / 1024.0);

        // Run whisper-cli: outputs plain text to stdout
        let output = tokio::process::Command::new(&bin)
            .arg("-m").arg(&model)
            .arg("-f").arg(&wav_path)
            .arg("-l").arg(&self.lang)
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

/// Default whisper.cpp release tag used to build the upstream download URL when
/// neither `OSA_WHISPER_URL` nor `OSA_WHISPER_TAG` is set. Overridable at runtime
/// so a renamed/removed asset can be repinned without rebuilding.
const DEFAULT_WHISPER_TAG: &str = "v1.8.3";

/// Resolve the whisper.cpp release tag: `OSA_WHISPER_TAG` env override, else the
/// pinned default.
fn whisper_tag() -> String {
    std::env::var("OSA_WHISPER_TAG")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| DEFAULT_WHISPER_TAG.to_string())
}

/// Platform token used to build the upstream whisper.cpp release asset name
/// (`whisper-bin-<token>.zip`). Upstream publishes only Windows assets today, so
/// the non-Windows tokens matter only for a self-hosted mirror set via
/// `OSA_WHISPER_URL`.
fn platform_archive_name() -> &'static str {
    if cfg!(target_os = "windows") {
        if cfg!(target_arch = "x86_64") { "x64" } else { "Win32" }
    } else if cfg!(target_os = "macos") {
        if cfg!(target_arch = "aarch64") { "macos-arm64" } else { "macos-x64" }
    } else if cfg!(target_arch = "aarch64") {
        "linux-arm64"
    } else {
        "linux-x64"
    }
}

/// Resolve the whisper-cli download URL for this platform. `OSA_WHISPER_URL` (a
/// direct link to a zip containing a `whisper-cli`/`main` binary) wins on every
/// OS — the way macOS/Linux users point OSA at a self-hosted or CI-built
/// binary. Otherwise we fall back to the upstream whisper.cpp release zip, which
/// only exists for Windows; on other platforms this returns an actionable error.
fn resolve_binary_download_url() -> Result<String> {
    if let Ok(url) = std::env::var("OSA_WHISPER_URL") {
        if !url.trim().is_empty() {
            return Ok(url);
        }
    }

    if cfg!(target_os = "windows") {
        let archive = format!("whisper-bin-{}.zip", platform_archive_name());
        Ok(format!(
            "https://github.com/ggerganov/whisper.cpp/releases/download/{}/{}",
            whisper_tag(), archive
        ))
    } else {
        anyhow::bail!(
            "no prebuilt whisper-cli is published for this platform ({}/{}). \
             Set OSA_WHISPER_URL to a .zip containing a `whisper-cli` binary, \
             install whisper.cpp yourself (e.g. `brew install whisper-cpp` on macOS), \
             or use cloud transcription (export VOICE_PROVIDER=cloud).",
            std::env::consts::OS,
            std::env::consts::ARCH
        )
    }
}

/// Whether an archive member (by basename) is one we need to extract. OS-aware:
/// Windows keeps the CLI plus its DLLs; unix keeps the CLI (`whisper-cli`/`main`)
/// plus any shared objects (`.so`/`.dylib`).
fn wanted_archive_member(basename: &str) -> bool {
    #[cfg(target_os = "windows")]
    {
        const NEEDED: &[&str] = &[
            "whisper-cli.exe", "whisper.dll", "ggml.dll", "ggml-base.dll", "ggml-cpu.dll",
        ];
        NEEDED.contains(&basename)
    }
    #[cfg(not(target_os = "windows"))]
    {
        basename == "whisper-cli"
            || basename == "main"
            || basename.ends_with(".so")
            || basename.contains(".so.")
            || basename.ends_with(".dylib")
    }
}

/// True when a `whisper-cli` binary is resolvable on the system PATH.
fn which_whisper_on_path() -> bool {
    std::process::Command::new(if cfg!(windows) { "where" } else { "which" })
        .arg("whisper-cli")
        .output()
        .map(|o| o.status.success() && !o.stdout.is_empty())
        .unwrap_or(false)
}

/// Resolve the transcription language from `WHISPER_LANG`. Defaults to `auto`
/// (whisper.cpp auto-detects; cloud/groq omit the field to auto-detect).
fn whisper_lang() -> String {
    std::env::var("WHISPER_LANG")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "auto".to_string())
}

/// Map the configured language to an OpenAI/Groq API `language` value. `auto`
/// (or empty) means "let the service auto-detect", so the field is omitted.
fn api_language(lang: &str) -> Option<String> {
    let l = lang.trim();
    if l.is_empty() || l.eq_ignore_ascii_case("auto") {
        None
    } else {
        Some(l.to_string())
    }
}

// ── Cloud transcriber (always available) ─────────────────────

pub struct CloudTranscriber {
    api_key: String,
    lang: String,
}

impl CloudTranscriber {
    pub fn new(api_key: String) -> Self {
        Self { api_key, lang: whisper_lang() }
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

        let mut form = reqwest::multipart::Form::new()
            .text("model", "whisper-1")
            .text("response_format", "text");
        if let Some(lang) = api_language(&self.lang) {
            form = form.text("language", lang);
        }
        let form = form.part("file", part);

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
    lang: String,
}

impl GroqTranscriber {
    pub fn new(api_key: String) -> Self {
        Self { api_key, lang: whisper_lang() }
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

        let mut form = reqwest::multipart::Form::new()
            .text("model", "whisper-large-v3-turbo")
            .text("response_format", "text");
        if let Some(lang) = api_language(&self.lang) {
            form = form.text("language", lang);
        }
        let form = form.part("file", part);

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
