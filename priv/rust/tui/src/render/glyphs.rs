//! Cross-terminal decorative-glyph catalog with equal-width legacy fallbacks.
//!
//! OSA's UI leans on decorative glyphs (bullets, rails, checks, spinners) that
//! render fine on modern UTF-8 terminals but show as tofu — or, worse, at the
//! WRONG column width — on Windows ConHost, the Linux VT console, and other
//! minimal terminals. A width change is the dangerous case: ratatui lays every
//! cell out by [`unicode_width`], so a fallback that is one column wider or
//! narrower than the glyph it replaces shifts the whole line and corrupts the
//! frame diff.
//!
//! This module is the single catalog of those glyphs, mirroring grok-build's
//! `glyphs.rs`. Each accessor returns the real glyph on a capable terminal and
//! an ASCII (CP437-safe) fallback of IDENTICAL [`unicode_width`] on a legacy
//! one, so layouts never move. Detection is conservative in the same spirit as
//! [`crate::render::colors`]: we assume Unicode unless a concrete downgrade
//! signal is present.
//!
//! Note: every primary glyph in this catalog measures one column under
//! `unicode-width`, so every fallback is a single-column ASCII char. `⎿` and
//! the arrows read as "2 wide" in some fonts, but ratatui trusts `unicode-width`
//! (width 1), so matching that — not the visual rendering — is what keeps the
//! layout stable.

use std::sync::OnceLock;

/// Glyph-rendering capability of the terminal.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GlyphLevel {
    /// Full UTF-8: decorative glyphs render as authored.
    Unicode,
    /// Legacy/limited (ConHost, VT console, `TERM=dumb`): use ASCII fallbacks of
    /// equal column width.
    Legacy,
}

static LEVEL: OnceLock<GlyphLevel> = OnceLock::new();

/// The detected glyph level for this process (cached after first call).
pub fn glyph_level() -> GlyphLevel {
    *LEVEL.get_or_init(detect_glyph_level)
}

/// Detect the terminal's glyph capability from the environment.
///
/// Precedence: explicit `OSA_GLYPH_LEVEL` override → `TERM=dumb|linux|empty`
/// (legacy) → legacy Windows ConHost (Windows without `WT_SESSION`) → default
/// `Unicode`. Only a concrete downgrade signal drops us to `Legacy`, preserving
/// OSA's rendering on modern terminals.
fn detect_glyph_level() -> GlyphLevel {
    if let Ok(v) = std::env::var("OSA_GLYPH_LEVEL") {
        if let Some(l) = parse_level(&v) {
            return l;
        }
    }
    if let Ok(term) = std::env::var("TERM") {
        // `dumb`/empty carry no line-drawing; the Linux VT console is CP437-ish
        // and mangles most decorative glyphs.
        if term == "dumb" || term.is_empty() || term == "linux" {
            return GlyphLevel::Legacy;
        }
    }
    // Windows Terminal exports `WT_SESSION`; its absence on Windows means the
    // classic ConHost, which renders wide/ambiguous glyphs unreliably.
    if cfg!(windows) && std::env::var_os("WT_SESSION").is_none() {
        return GlyphLevel::Legacy;
    }
    GlyphLevel::Unicode
}

fn parse_level(v: &str) -> Option<GlyphLevel> {
    match v.trim().to_ascii_lowercase().as_str() {
        "legacy" | "ascii" | "cp437" | "1" => Some(GlyphLevel::Legacy),
        "unicode" | "utf8" | "utf-8" | "full" | "0" => Some(GlyphLevel::Unicode),
        _ => None,
    }
}

/// Pick between the Unicode glyph and its equal-width legacy fallback for the
/// current terminal.
#[inline]
fn pick(unicode: &'static str, legacy: &'static str) -> &'static str {
    match glyph_level() {
        GlyphLevel::Unicode => unicode,
        GlyphLevel::Legacy => legacy,
    }
}

// ---------------------------------------------------------------------------
// Glyph catalog. Every fallback is width-matched to its primary (see tests).
// ---------------------------------------------------------------------------

/// Result/tool-output branch connector (`⎿`, CC's `AgentTool` rail).
pub fn result_branch() -> &'static str {
    pick("\u{23bf}", "\\") // ⎿ -> backslash (both width 1)
}

/// Tool / assistant bullet (`●`).
pub fn bullet() -> &'static str {
    pick("\u{25cf}", "*") // ● -> *
}

/// Diamond marker (`◆`, e.g. rewind "has code" tag).
pub fn diamond() -> &'static str {
    pick("\u{25c6}", "*") // ◆ -> *
}

/// Heavy vertical rail (`┃`). Falls back to the light rail `│`, which every
/// CP437 / line-drawing terminal renders at the same single-column width.
pub fn heavy_rail() -> &'static str {
    pick("\u{2503}", "\u{2502}") // ┃ -> │
}

/// Success check (`✓`).
pub fn check() -> &'static str {
    pick("\u{2713}", "+") // ✓ -> +
}

/// Failure cross (`✗`).
pub fn cross() -> &'static str {
    pick("\u{2717}", "x") // ✗ -> x
}

/// Ellipsis (`…`). Its ASCII expansion `...` is three columns wide, which would
/// shift layout, so on a legacy terminal we KEEP `…` (width 1) rather than break
/// alignment — the glyph is broadly supported even where others are not.
pub fn ellipsis() -> &'static str {
    pick("\u{2026}", "\u{2026}") // … (unchanged; width-safe ASCII does not exist)
}

/// Token/count down-arrow (`⇣`, CC's context-token indicator).
pub fn token_arrow() -> &'static str {
    pick("\u{21e3}", "v") // ⇣ -> v
}

/// Effort/progress dots: empty → half → full (`○ ◐ ◉`), indexed 0..=2. Any other
/// index clamps to the nearest end.
pub fn effort_dot(level: u8) -> &'static str {
    match level {
        0 => pick("\u{25cb}", "."),      // ○ -> .
        1 => pick("\u{25d0}", "o"),      // ◐ -> o
        _ => pick("\u{25c9}", "O"),      // ◉ -> O
    }
}

/// All three effort dots in ascending order, for callers that render a ramp.
pub fn effort_dots() -> [&'static str; 3] {
    [effort_dot(0), effort_dot(1), effort_dot(2)]
}

/// Braille spinner frames (`⠋⠙⠹⠸⠼⠴⠦⠧`). On a legacy terminal these become the
/// classic ASCII `|/-\` cycle, expanded to the same 8-frame length so callers
/// can index frames uniformly. Every frame is one column wide.
pub fn spinner_frames() -> &'static [&'static str] {
    match glyph_level() {
        GlyphLevel::Unicode => &[
            "\u{280b}", "\u{2819}", "\u{2839}", "\u{2838}", // ⠋ ⠙ ⠹ ⠸
            "\u{283c}", "\u{2834}", "\u{2826}", "\u{2827}", // ⠼ ⠴ ⠦ ⠧
        ],
        GlyphLevel::Legacy => &["|", "/", "-", "\\", "|", "/", "-", "\\"],
    }
}

/// The spinner frame at `tick` (wraps around the frame count).
pub fn spinner_frame(tick: usize) -> &'static str {
    let frames = spinner_frames();
    frames[tick % frames.len()]
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use unicode_width::UnicodeWidthStr;

    /// Every glyph and its legacy fallback MUST occupy the same number of
    /// columns, or a fallback would shift the layout on a legacy terminal.
    #[test]
    fn primary_and_fallback_widths_match() {
        let pairs: &[(&str, &str)] = &[
            ("\u{23bf}", "\\"),   // result_branch
            ("\u{25cf}", "*"),    // bullet
            ("\u{25c6}", "*"),    // diamond
            ("\u{2503}", "\u{2502}"), // heavy_rail
            ("\u{2713}", "+"),    // check
            ("\u{2717}", "x"),    // cross
            ("\u{2026}", "\u{2026}"), // ellipsis
            ("\u{21e3}", "v"),    // token_arrow
            ("\u{25cb}", "."),    // effort 0
            ("\u{25d0}", "o"),    // effort 1
            ("\u{25c9}", "O"),    // effort 2
        ];
        for (primary, fallback) in pairs {
            assert_eq!(
                primary.width(),
                fallback.width(),
                "{primary:?} ({}) != fallback {fallback:?} ({})",
                primary.width(),
                fallback.width(),
            );
        }
    }

    /// Every spinner frame — Unicode and ASCII — is exactly one column, and the
    /// two sets have matching lengths so a frame index maps cleanly across levels.
    #[test]
    fn spinner_frames_are_uniform_width() {
        let unicode: &[&str] = &[
            "\u{280b}", "\u{2819}", "\u{2839}", "\u{2838}",
            "\u{283c}", "\u{2834}", "\u{2826}", "\u{2827}",
        ];
        let legacy: &[&str] = &["|", "/", "-", "\\", "|", "/", "-", "\\"];
        assert_eq!(unicode.len(), legacy.len());
        for (u, l) in unicode.iter().zip(legacy) {
            assert_eq!(u.width(), 1, "unicode frame {u:?} not width 1");
            assert_eq!(l.width(), 1, "legacy frame {l:?} not width 1");
        }
    }

    #[test]
    fn env_override_selects_level() {
        assert_eq!(parse_level("legacy"), Some(GlyphLevel::Legacy));
        assert_eq!(parse_level("CP437"), Some(GlyphLevel::Legacy));
        assert_eq!(parse_level("unicode"), Some(GlyphLevel::Unicode));
        assert_eq!(parse_level(" Full "), Some(GlyphLevel::Unicode));
        assert_eq!(parse_level("nonsense"), None);
    }

    #[test]
    fn accessors_return_nonempty_for_current_level() {
        // Whatever the ambient level, no accessor yields an empty string.
        assert!(!result_branch().is_empty());
        assert!(!bullet().is_empty());
        assert!(!diamond().is_empty());
        assert!(!heavy_rail().is_empty());
        assert!(!check().is_empty());
        assert!(!cross().is_empty());
        assert!(!ellipsis().is_empty());
        assert!(!token_arrow().is_empty());
        assert_eq!(effort_dots().len(), 3);
        assert_eq!(spinner_frames().len(), 8);
        assert_eq!(spinner_frame(9), spinner_frame(1)); // wraps
    }

    #[test]
    fn effort_dot_clamps_high_index() {
        assert_eq!(effort_dot(2), effort_dot(7));
    }
}
