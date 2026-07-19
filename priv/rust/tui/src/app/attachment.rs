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

/// U-T1 — the on-disk IMAGE paths among composer `@`-mention attachments, so an
/// `@photo.png` mention rides the same vision `images` wire as a pasted image.
/// Non-image file mentions and `@agent` mentions are intentionally excluded:
/// they already reach the model as inline prompt text, and the `images` wire is
/// image-semantic (a non-image path there would be misinterpreted). Pure over
/// its input (existence is checked by the caller) so it is unit-testable.
pub fn mention_image_paths(atts: &[crate::components::input::mentions::Attachment]) -> Vec<String> {
    use crate::components::input::mentions::Attachment as M;
    atts.iter()
        .filter_map(|a| match a {
            M::File { path, .. } if is_image_path(path) => Some(path.clone()),
            _ => None,
        })
        .collect()
}

/// The non-image `@file` (with optional `#L` range) and `@agent` mentions
/// among composer attachments, converted into wire [`ContextRef`]s so the
/// backend resolves them into real context instead of relying on the
/// mention's inline text alone. IMAGE file mentions are excluded — those
/// already ride `OrchestrateRequest.images` via [`mention_image_paths`].
///
/// [`ContextRef`]: crate::client::types::ContextRef
pub fn mention_context_refs(
    atts: &[crate::components::input::mentions::Attachment],
) -> Vec<crate::client::types::ContextRef> {
    use crate::client::types::ContextRef;
    use crate::components::input::mentions::Attachment as M;

    atts.iter()
        .filter_map(|a| match a {
            M::File { path, .. } if is_image_path(path) => None,
            M::File { path, range } => Some(ContextRef {
                kind: "file".to_string(),
                path: Some(path.clone()),
                range: range.as_ref().map(range_to_wire),
                name: None,
            }),
            M::Agent { name } => Some(ContextRef {
                kind: "agent".to_string(),
                path: None,
                range: None,
                name: Some(name.clone()),
            }),
        })
        .collect()
}

/// Render a [`LineRange`](crate::components::input::mentions::LineRange) as
/// the wire's `"start"` / `"start-end"` string form.
fn range_to_wire(range: &crate::components::input::mentions::LineRange) -> String {
    match range.end {
        Some(end) => format!("{}-{}", range.start, end),
        None => range.start.to_string(),
    }
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

    /// Orphan prune against explicit text (CC PromptInput.tsx:1189-1200):
    /// deleting an "[Image #N]" / "[File #N]" chip from the composer must
    /// delete the attachment too, or a removed image would still be silently
    /// sent with the next prompt. Used as the final before-submit gate, diffed
    /// against the outgoing text.
    pub(crate) fn prune_orphaned_attachments_in(&mut self, content: &str) {
        retain_referenced(&mut self.attachments, content);
    }

    /// Content-changed hook: prune against the live composer buffer. Called
    /// from the key fall-through paths after every composer edit.
    pub(crate) fn prune_orphaned_attachments(&mut self) {
        if self.attachments.is_empty() {
            return;
        }
        let content = self.input.value().to_string();
        retain_referenced(&mut self.attachments, &content);
    }
}

/// Pure core of the orphan prune: retain only attachments whose exact chip
/// token ("[Image #N]" / "[File #N]", closing bracket included so #1 can never
/// be kept alive by #12) still appears in `content`. Split out for unit
/// testing without an `App`.
fn retain_referenced(attachments: &mut Vec<Attachment>, content: &str) {
    if attachments.is_empty() {
        return;
    }
    attachments.retain(|a| content.contains(&a.chip_label()));
}

#[cfg(test)]
mod prune_tests {
    use super::*;

    fn att(index: usize, is_image: bool) -> Attachment {
        Attachment {
            index,
            is_image,
            source: AttachmentSource::Path(format!("/tmp/f{index}")),
        }
    }

    #[test]
    fn deleting_a_chip_drops_its_attachment() {
        let mut atts = vec![att(1, true), att(2, false)];
        // The "[File #2]" chip was deleted from the composer.
        retain_referenced(&mut atts, "look at [Image #1] please");
        assert_eq!(atts.len(), 1);
        assert_eq!(atts[0].index, 1);
    }

    #[test]
    fn chip_index_match_is_exact_not_prefix() {
        // "[Image #1]" must NOT be kept alive by "[Image #12]".
        let mut atts = vec![att(1, true), att(12, true)];
        retain_referenced(&mut atts, "see [Image #12]");
        assert_eq!(atts.len(), 1);
        assert_eq!(atts[0].index, 12);
    }

    #[test]
    fn kind_mismatch_is_not_a_reference() {
        // A [File #1] token does not keep an Image #1 attachment alive.
        let mut atts = vec![att(1, true)];
        retain_referenced(&mut atts, "[File #1]");
        assert!(atts.is_empty());
    }

    #[test]
    fn mention_image_paths_keeps_only_image_files() {
        use crate::components::input::mentions::{Attachment as M, LineRange};
        let atts = vec![
            M::File { path: "docs/diagram.PNG".into(), range: None },
            M::File { path: "src/main.rs".into(), range: Some(LineRange { start: 1, end: None }) },
            M::File { path: "shot.jpeg".into(), range: None },
            M::Agent { name: "reviewer".into() },
        ];
        // Only the two image files survive; the .rs mention and the @agent are
        // excluded (they stay inline prompt text, not on the vision wire).
        assert_eq!(
            mention_image_paths(&atts),
            vec!["docs/diagram.PNG".to_string(), "shot.jpeg".to_string()]
        );
    }

    #[test]
    fn mention_context_refs_carries_non_image_file_and_agent() {
        use crate::components::input::mentions::{Attachment as M, LineRange};
        let atts = vec![
            M::File { path: "docs/diagram.PNG".into(), range: None },
            M::File {
                path: "src/main.rs".into(),
                range: Some(LineRange { start: 10, end: Some(20) }),
            },
            M::File { path: "README.md".into(), range: Some(LineRange { start: 5, end: None }) },
            M::Agent { name: "debugger".into() },
        ];
        let refs = mention_context_refs(&atts);
        // The image mention is excluded (it rides `images` instead).
        assert_eq!(refs.len(), 3);

        assert_eq!(refs[0].kind, "file");
        assert_eq!(refs[0].path.as_deref(), Some("src/main.rs"));
        assert_eq!(refs[0].range.as_deref(), Some("10-20"));
        assert_eq!(refs[0].name, None);

        assert_eq!(refs[1].kind, "file");
        assert_eq!(refs[1].path.as_deref(), Some("README.md"));
        assert_eq!(refs[1].range.as_deref(), Some("5"));

        assert_eq!(refs[2].kind, "agent");
        assert_eq!(refs[2].name.as_deref(), Some("debugger"));
        assert_eq!(refs[2].path, None);
        assert_eq!(refs[2].range, None);
    }

    #[test]
    fn mention_context_refs_empty_when_no_mentions() {
        assert!(mention_context_refs(&[]).is_empty());
    }

    #[test]
    fn empty_content_drops_everything_and_surviving_chips_stay() {
        let mut atts = vec![att(1, true)];
        retain_referenced(&mut atts, "");
        assert!(atts.is_empty());
        let mut atts = vec![att(1, true)];
        retain_referenced(&mut atts, "[Image #1] and text");
        assert_eq!(atts.len(), 1);
    }
}
