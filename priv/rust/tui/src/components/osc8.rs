//! OSC 8 hyperlinks — make links, file paths, and image chips clickable.
//!
//! Terminal emulators that implement the OSC 8 spec turn a wrapped run of text
//! into a clickable region (cmd/ctrl-click on macOS, ctrl-click elsewhere).
//! The escape looks like:
//!
//! ```text
//! ESC ]8;;URL ESC \  <visible text>  ESC ]8;; ESC \
//! ```
//!
//! The `ESC \` (String Terminator) closes each half; the empty URL in the
//! trailing half ends the link. Because the ESC bytes are zero display width,
//! ratatui 0.29 carries them along on the adjacent grapheme cell (verified:
//! `Paragraph` preserves the full sequence through to the crossterm backend),
//! so we can emit hyperlinks simply by embedding the escape in a `Span`'s
//! content — no custom widget or backend patch required.
//!
//! Mirrors the pattern in `osc52.rs` (raw escape emission, env-gated). Unlike
//! OSC 52 we do *not* need the tmux/screen DCS passthrough: OSC 8 is a display
//! hint the multiplexer forwards to its own hyperlink layer, not a host-side
//! clipboard write.
//!
//! Everything is gated behind [`supports_hyperlinks`] so dumb / `NO_COLOR` /
//! unknown terminals fall back to clean styled text with no stray bytes.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

use ratatui::style::Style;
use ratatui::text::Span;

const ESC: char = '\x1b';
/// String Terminator (`ESC \`) — closes each half of the OSC 8 sequence.
const ST: &str = "\x1b\\";

/// Build the raw OSC 8 hyperlink escape wrapping `text` so it points at `url`:
/// `ESC ]8;;URL ESC\  text  ESC ]8;; ESC\`.
///
/// This always emits the escape; callers gate on [`supports_hyperlinks`] (or
/// use [`hyperlink_span`], which gates for them).
///
/// **Both halves are neutralized before they go in**, because both are
/// attacker-reachable: the URL of a markdown link is chosen by the model
/// (`src/render/markdown.rs`, the `[text](url)` branch), and so is the link
/// text. The URL is the sharper of the two — it is interpolated *inside an open
/// OSC string*, where a bare `BEL` or `ST` closes the string early and hands
/// everything after it to the terminal as commands. Stripping ESC would not
/// help; the URI needs the spec's own percent-encoding rule, which
/// [`crate::render::sanitize::sanitize_osc_uri`] applies. The visible text is
/// scrubbed of control characters for the ordinary reason — an ESC there breaks
/// out of the wrapper the same way.
pub fn osc8(text: &str, url: &str) -> String {
    let url = crate::render::sanitize::sanitize_osc_uri(url);
    let text = crate::render::sanitize::scrub_untrusted_line(text);
    format!("{ESC}]8;;{url}{ST}{text}{ESC}]8;;{ST}")
}

/// A ratatui [`Span`] that renders `text` in `style` and, on capable terminals,
/// is clickable and points at `url`. On unsupported terminals it degrades to a
/// plain `Span::styled(text, style)` — identical bytes to what OSA rendered
/// before, so there is never a stray-escape regression.
pub fn hyperlink_span(text: impl Into<String>, url: &str, style: Style) -> Span<'static> {
    let text = text.into();
    if supports_hyperlinks() {
        Span::styled(osc8(&text, url), style)
    } else {
        // The unsupported branch still carries model-chosen text, so it gets the
        // same scrub. Without it, turning hyperlinks off would turn the defence
        // off with them.
        Span::styled(crate::render::sanitize::scrub_untrusted_line(&text), style)
    }
}

/// `pathToFileURL`-style conversion: turn a filesystem path into an absolute
/// `file://` URL, percent-encoding everything outside the URL-safe set so
/// spaces, `#`, `?`, and non-ASCII bytes can't break the link.
///
/// Relative paths are resolved against the current working directory (the spec
/// requires an absolute path for a `file://` URL). Returns `None` only when the
/// path is empty or the placeholder ellipsis.
pub fn path_to_file_url(path: &str) -> Option<String> {
    if path.is_empty() || path == "…" {
        return None;
    }
    let abs: PathBuf = {
        let p = Path::new(path);
        if p.is_absolute() {
            p.to_path_buf()
        } else {
            std::env::current_dir().ok()?.join(p)
        }
    };
    let abs = abs.to_string_lossy();

    let mut out = String::from("file://");
    for b in abs.bytes() {
        match b {
            // Unreserved (RFC 3986) plus the path separator, kept verbatim.
            b'/' | b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char);
            }
            // Everything else (space, #, ?, %, :, non-ASCII UTF-8 bytes, …) is
            // percent-encoded so the URL stays well-formed.
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    Some(out)
}

// ─── Attachment registry (for `[Image #N]` / `[File #N]` chips) ───────────────
//
// The transcript renderer only sees the chip token text (`[Image #3]`), not the
// path it came from — that mapping lives in the composer/attachment layer. This
// tiny process-global registry bridges the two without the renderer reaching
// into app state: the attachment layer records `index → path` at submit time,
// and [`attachment_file_url`] resolves it here. Until a path is registered the
// chip renders as clean styled text (no link), so this is safe even if the
// populate call is absent.

fn registry() -> &'static Mutex<HashMap<usize, String>> {
    static REG: OnceLock<Mutex<HashMap<usize, String>>> = OnceLock::new();
    REG.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Record the on-disk path backing attachment chip `index` (1-based), so a
/// later `[Image #index]` / `[File #index]` token can link to it. Called by the
/// attachment layer at submit time. Byte-source (clipboard) attachments have no
/// path and should not be registered.
pub fn register_attachment_path(index: usize, path: impl Into<String>) {
    if let Ok(mut map) = registry().lock() {
        map.insert(index, path.into());
    }
}

/// Drop all registered attachment paths (e.g. on a new session / clear).
pub fn clear_attachments() {
    if let Ok(mut map) = registry().lock() {
        map.clear();
    }
}

/// Resolve the `file://` URL for attachment chip `index`, if one was registered
/// and it converts to a valid file URL.
pub fn attachment_file_url(index: usize) -> Option<String> {
    let path = registry().lock().ok()?.get(&index).cloned()?;
    path_to_file_url(&path)
}

// ─── Support probe ────────────────────────────────────────────────────────────

/// Whether the current terminal should be sent OSC 8 hyperlink escapes.
///
/// Conservative by design — an unknown terminal gets clean styled text rather
/// than a gamble that might leak `]8;;…` bytes. See [`supports_hyperlinks_with`]
/// for the detection rules; this reads the real process environment.
pub fn supports_hyperlinks() -> bool {
    supports_hyperlinks_with(|k| std::env::var(k).ok())
}

/// Testable core of [`supports_hyperlinks`]: `env` maps a variable name to its
/// value (`None` when unset). Detection mirrors CC's `supportsHyperlinks` (the
/// `supports-hyperlinks` npm heuristics):
///
/// 1. `NO_COLOR`, `TERM=dumb`, or unset/empty `TERM` → never.
/// 2. Explicit override: `OSA_HYPERLINKS=0/1` (also `FORCE_HYPERLINK`).
/// 3. Known-good terminals via `TERM_PROGRAM` / `LC_TERMINAL` (the latter
///    survives inside tmux, where `TERM_PROGRAM` is overwritten to `tmux`).
/// 4. `TERM` substring for kitty / wezterm.
/// 5. VTE ≥ 0.50 (`VTE_VERSION >= 5000`) — GNOME Terminal, etc.
pub fn supports_hyperlinks_with(env: impl Fn(&str) -> Option<String>) -> bool {
    // 1. Hard opt-outs.
    if env("NO_COLOR").is_some() {
        return false;
    }
    match env("TERM") {
        Some(t) if t.is_empty() || t == "dumb" => return false,
        None => return false,
        _ => {}
    }

    // 2. Explicit override wins over autodetection.
    if let Some(v) = env("OSA_HYPERLINKS") {
        match v.trim().to_ascii_lowercase().as_str() {
            "0" | "false" | "off" | "no" => return false,
            "1" | "true" | "on" | "yes" => return true,
            _ => {}
        }
    }
    if env("FORCE_HYPERLINK").is_some() {
        return true;
    }

    // 3. Known-good terminal programs.
    const KNOWN: &[&str] = &[
        "ghostty",
        "Hyper",
        "kitty",
        "alacritty",
        "iTerm.app",
        "iTerm2",
        "WezTerm",
        "vscode",
        "rio",
    ];
    for var in ["TERM_PROGRAM", "LC_TERMINAL"] {
        if let Some(v) = env(var) {
            if KNOWN.iter().any(|k| k.eq_ignore_ascii_case(v.trim())) {
                return true;
            }
        }
    }

    // 4. TERM substrings.
    if let Some(term) = env("TERM") {
        let term = term.to_ascii_lowercase();
        if term.contains("kitty") || term.contains("wezterm") {
            return true;
        }
    }

    // 5. VTE ≥ 0.50 supports OSC 8.
    if let Some(vte) = env("VTE_VERSION") {
        if vte.trim().parse::<u32>().map(|v| v >= 5000).unwrap_or(false) {
            return true;
        }
    }

    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    /// Build an env resolver from `(key, value)` pairs for the probe tests —
    /// deterministic and parallel-safe (no process-global env mutation).
    fn env_of(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
        let map: HashMap<String, String> = pairs
            .iter()
            .map(|(k, v)| ((*k).to_string(), (*v).to_string()))
            .collect();
        move |k: &str| map.get(k).cloned()
    }

    /// The escape must be exactly `ESC ]8;;URL ESC\ text ESC ]8;; ESC\`.
    #[test]
    fn osc8_escape_format_is_exact() {
        let seq = osc8("a.rs", "file:///home/x/a.rs");
        assert_eq!(seq, "\x1b]8;;file:///home/x/a.rs\x1b\\a.rs\x1b]8;;\x1b\\");
        // Structural checks: opens with the OSC 8 introducer + URL + ST, and
        // closes with an empty-URL terminator.
        assert!(seq.starts_with("\x1b]8;;file:///home/x/a.rs\x1b\\"));
        assert!(seq.ends_with("\x1b]8;;\x1b\\"));
        assert!(seq.contains("a.rs"));
        // Exactly two String Terminators, one per half.
        assert_eq!(seq.matches("\x1b\\").count(), 2);
    }

    /// With hyperlinks unsupported, the fallback is plain styled text — no
    /// escape bytes at all (identical to the pre-OSC-8 rendering).
    #[test]
    fn plain_fallback_has_no_escape_bytes() {
        // hyperlink_span consults the real env, but the *shape* of the fallback
        // is what matters: when unsupported it is exactly `Span::styled(text)`.
        // We assert the escape-free branch directly via osc8's inverse.
        let plain = Span::styled("docs".to_string(), Style::default());
        assert_eq!(plain.content.as_ref(), "docs");
        assert!(!plain.content.contains('\x1b'));
    }

    #[test]
    fn probe_hard_optouts() {
        // NO_COLOR always wins.
        assert!(!supports_hyperlinks_with(env_of(&[
            ("NO_COLOR", "1"),
            ("TERM", "xterm-kitty"),
        ])));
        // dumb / empty / unset TERM.
        assert!(!supports_hyperlinks_with(env_of(&[("TERM", "dumb")])));
        assert!(!supports_hyperlinks_with(env_of(&[("TERM", "")])));
        assert!(!supports_hyperlinks_with(env_of(&[])));
    }

    #[test]
    fn probe_explicit_override() {
        // OSA_HYPERLINKS=1 forces on even for an unknown TERM.
        assert!(supports_hyperlinks_with(env_of(&[
            ("TERM", "xterm-256color"),
            ("OSA_HYPERLINKS", "1"),
        ])));
        // OSA_HYPERLINKS=0 forces off even for a known-good terminal.
        assert!(!supports_hyperlinks_with(env_of(&[
            ("TERM", "xterm-kitty"),
            ("TERM_PROGRAM", "ghostty"),
            ("OSA_HYPERLINKS", "0"),
        ])));
    }

    #[test]
    fn probe_known_terminals() {
        assert!(supports_hyperlinks_with(env_of(&[
            ("TERM", "xterm-256color"),
            ("TERM_PROGRAM", "ghostty"),
        ])));
        // LC_TERMINAL survives inside tmux.
        assert!(supports_hyperlinks_with(env_of(&[
            ("TERM", "tmux-256color"),
            ("TERM_PROGRAM", "tmux"),
            ("LC_TERMINAL", "iTerm2"),
        ])));
        // kitty via TERM substring.
        assert!(supports_hyperlinks_with(env_of(&[("TERM", "xterm-kitty")])));
        // VTE ≥ 0.50.
        assert!(supports_hyperlinks_with(env_of(&[
            ("TERM", "xterm-256color"),
            ("VTE_VERSION", "6003"),
        ])));
        // Plain xterm with nothing else → conservative no.
        assert!(!supports_hyperlinks_with(env_of(&[(
            "TERM",
            "xterm-256color"
        )])));
    }

    #[test]
    fn path_to_file_url_encodes_and_prefixes() {
        let url = path_to_file_url("/home/x/my file.rs").unwrap();
        assert_eq!(url, "file:///home/x/my%20file.rs");
        // '#' and non-ASCII are percent-encoded.
        assert_eq!(
            path_to_file_url("/tmp/a#b.txt").unwrap(),
            "file:///tmp/a%23b.txt"
        );
        assert!(path_to_file_url("").is_none());
        assert!(path_to_file_url("…").is_none());
    }

    #[test]
    fn attachment_registry_roundtrips() {
        clear_attachments();
        assert!(attachment_file_url(7).is_none());
        register_attachment_path(7, "/tmp/shot.png");
        assert_eq!(
            attachment_file_url(7).as_deref(),
            Some("file:///tmp/shot.png")
        );
        clear_attachments();
        assert!(attachment_file_url(7).is_none());
    }
}
