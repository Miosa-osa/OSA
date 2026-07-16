// Image/file paste + drag-drop attachments, shown as "[Image #N]" / "[File #N]"
// chips in the input and sent to vision-capable models via OrchestrateRequest.images.
#![allow(dead_code)]

use std::path::Path;

use super::App;
use crate::components::toast::ToastLevel;

/// A pasted or drag-dropped attachment, rendered in the input as a chip token.
#[derive(Debug, Clone)]
pub struct Attachment {
    /// Display index N shown in the chip token (1-based, per submit).
    pub index: usize,
    /// True when the source is a recognised image type.
    pub is_image: bool,
    /// The underlying data — a filesystem path or decoded image bytes.
    pub source: AttachmentSource,
}

#[derive(Debug, Clone)]
pub enum AttachmentSource {
    /// An on-disk file path (from paste text or a terminal drag-drop).
    Path(String),
    /// Decoded image bytes (e.g. a PNG grabbed from the clipboard), sent base64.
    Bytes(Vec<u8>),
}

impl Attachment {
    /// The chip label token inserted into the input, e.g. "[Image #1]".
    pub fn chip_label(&self) -> String {
        if self.is_image {
            format!("[Image #{}]", self.index)
        } else {
            format!("[File #{}]", self.index)
        }
    }

    /// Value placed in OrchestrateRequest.images — a path, or base64 for raw bytes.
    pub fn wire_value(&self) -> String {
        match &self.source {
            AttachmentSource::Path(p) => p.clone(),
            AttachmentSource::Bytes(b) => {
                use base64::{engine::general_purpose::STANDARD, Engine as _};
                STANDARD.encode(b)
            }
        }
    }
}

/// Image file extensions recognised for chip labelling.
const IMAGE_EXTS: &[&str] = &[
    "png", "jpg", "jpeg", "gif", "webp", "bmp", "svg", "tiff", "tif", "heic", "heif", "avif",
];

pub fn is_image_path(path: &str) -> bool {
    Path::new(path)
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| IMAGE_EXTS.contains(&e.to_ascii_lowercase().as_str()))
        .unwrap_or(false)
}

/// Strip a single matching pair of surrounding quotes.
fn unquote(s: &str) -> String {
    let s = s.trim();
    for q in ['\'', '"'] {
        if s.len() >= 2 && s.starts_with(q) && s.ends_with(q) {
            return s[1..s.len() - 1].to_string();
        }
    }
    s.to_string()
}

/// Undo shell-style escaping a terminal may apply to dropped paths ("\ " -> " ").
fn unescape(s: &str) -> String {
    s.replace("\\ ", " ").replace("\\\\", "\\")
}

/// Extract existing file paths from pasted/dropped text. Returns empty when the
/// text is ordinary prose (so it falls through to normal text insertion).
pub fn parse_attachment_paths(text: &str) -> Vec<String> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Vec::new();
    }

    // Fast path: the whole payload is a single (possibly quoted) path — handles
    // paths containing spaces, which the token split below would break apart.
    let whole = unescape(&unquote(trimmed));
    if Path::new(&whole).is_file() {
        return vec![whole];
    }

    // Otherwise treat it as one-or-more whitespace/newline separated paths and
    // keep only the tokens that actually resolve to files on disk.
    let mut out = Vec::new();
    for token in trimmed.split_whitespace() {
        let cand = unescape(&unquote(token));
        if Path::new(&cand).is_file() {
            out.push(cand);
        }
    }
    out
}

impl App {
    /// Register an attachment: insert its chip token into the input and store it.
    fn push_attachment(&mut self, source: AttachmentSource, is_image: bool) {
        let index = self.attachments.len() + 1;
        let att = Attachment {
            index,
            is_image,
            source,
        };
        let label = att.chip_label();
        // Chip token + trailing space so the cursor sits after it.
        self.input.insert_str(&format!("{} ", label));
        self.attachments.push(att);
        self.toasts
            .push(format!("Attached {}", label), ToastLevel::Info);
    }

    /// If `text` is one-or-more file paths (paste or drag-drop), turn them into
    /// attachment chips and return true. Otherwise return false (treat as text).
    pub(crate) fn ingest_paste_as_attachments(&mut self, text: &str) -> bool {
        let paths = parse_attachment_paths(text);
        if paths.is_empty() {
            return false;
        }
        for path in paths {
            let is_image = is_image_path(&path);
            self.push_attachment(AttachmentSource::Path(path), is_image);
        }
        true
    }

    /// Grab a raw image from the system clipboard (Ctrl/Cmd+V of an image),
    /// encode it as PNG and attach it. Returns false when there is no image.
    pub(crate) fn ingest_clipboard_image(&mut self) -> bool {
        let img = match arboard::Clipboard::new().and_then(|mut cb| cb.get_image()) {
            Ok(img) => img,
            Err(_) => return false,
        };
        let (w, h) = (img.width as u32, img.height as u32);
        let buf = match image::RgbaImage::from_raw(w, h, img.bytes.into_owned()) {
            Some(b) => b,
            None => return false,
        };
        let mut png: Vec<u8> = Vec::new();
        if buf
            .write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
            .is_err()
        {
            return false;
        }
        self.push_attachment(AttachmentSource::Bytes(png), true);
        true
    }
}
