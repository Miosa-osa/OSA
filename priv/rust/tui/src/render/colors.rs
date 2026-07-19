//! Terminal color-capability detection and truecolor → 256 → 16 → none
//! downgrade.
//!
//! OSA's syntax highlighter (and any theme color) emits [`Color::Rgb`]
//! unconditionally. On a 256-color TTY, a 16-color TTY, or under `NO_COLOR`,
//! raw 24-bit SGR escapes either render wrong or get stripped inconsistently by
//! the terminal / multiplexer. This module detects the terminal's color level
//! once and maps every emitted color down to what the terminal can actually
//! display — the same job grok's `xai-grok-markdown/src/colors.rs`
//! (`ColorLevel` / `detect_color_level` / `adapt_style`) performs.
//!
//! Detection is conservative: unless a *downgrade* signal is present
//! (`NO_COLOR`, `TERM=dumb`, `TERM=*-256color`, or an explicit
//! `OSA_COLOR_LEVEL` override) we keep truecolor, preserving OSA's existing
//! rendering on capable terminals.

use ratatui::style::Color;
use std::sync::OnceLock;

/// Color depth a terminal can render.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColorLevel {
    /// 24-bit truecolor (`Color::Rgb` passes through unchanged).
    TrueColor,
    /// 256-color palette (`Color::Indexed`, 6×6×6 cube + grayscale ramp).
    Ansi256,
    /// 16-color palette (the 8 base + 8 bright named colors).
    Ansi16,
    /// No color at all (`NO_COLOR` / `TERM=dumb`) — everything becomes
    /// [`Color::Reset`] so only the terminal's default fg/bg is used.
    NoColor,
}

static LEVEL: OnceLock<ColorLevel> = OnceLock::new();

/// The detected color level for this process (cached after first call).
pub fn color_level() -> ColorLevel {
    *LEVEL.get_or_init(detect_color_level)
}

/// Detect the terminal color level from the environment.
///
/// Precedence: explicit `OSA_COLOR_LEVEL` override → `NO_COLOR` → `TERM=dumb`
/// → `COLORTERM=truecolor|24bit` → `TERM=*256color*` → default `TrueColor`.
fn detect_color_level() -> ColorLevel {
    if let Some(l) = std::env::var("OSA_COLOR_LEVEL")
        .ok()
        .and_then(|v| parse_level(&v))
    {
        return l;
    }
    // `NO_COLOR` (any value, per no-color.org) disables color entirely.
    if std::env::var_os("NO_COLOR").is_some() {
        return ColorLevel::NoColor;
    }
    if let Ok(term) = std::env::var("TERM") {
        if term == "dumb" || term.is_empty() {
            return ColorLevel::NoColor;
        }
    }
    if let Ok(ct) = std::env::var("COLORTERM") {
        let ct = ct.to_ascii_lowercase();
        if ct.contains("truecolor") || ct.contains("24bit") {
            return ColorLevel::TrueColor;
        }
    }
    if let Ok(term) = std::env::var("TERM") {
        if term.contains("256color") || term.contains("256") {
            return ColorLevel::Ansi256;
        }
        if term.contains("16color") {
            return ColorLevel::Ansi16;
        }
    }
    // Unknown terminal: keep truecolor (OSA's historical behavior). Only an
    // explicit downgrade signal above drops us below 24-bit.
    ColorLevel::TrueColor
}

fn parse_level(v: &str) -> Option<ColorLevel> {
    match v.trim().to_ascii_lowercase().as_str() {
        "truecolor" | "24bit" | "24" | "16m" | "3" => Some(ColorLevel::TrueColor),
        "256" | "8bit" | "2" => Some(ColorLevel::Ansi256),
        "16" | "4bit" | "ansi" | "1" => Some(ColorLevel::Ansi16),
        "none" | "no" | "off" | "0" => Some(ColorLevel::NoColor),
        _ => None,
    }
}

/// Downgrade `color` to what `level` can render. Non-`Rgb` colors pass through
/// unchanged (except under [`ColorLevel::NoColor`], which drops all color).
pub fn adapt_color(color: Color, level: ColorLevel) -> Color {
    match level {
        ColorLevel::TrueColor => color,
        ColorLevel::Ansi256 => match color {
            Color::Rgb(r, g, b) => Color::Indexed(rgb_to_256(r, g, b)),
            other => other,
        },
        ColorLevel::Ansi16 => match color {
            Color::Rgb(r, g, b) => rgb_to_ansi16(r, g, b),
            Color::Indexed(i) if i >= 16 => rgb_to_ansi16_from_index(i),
            other => other,
        },
        ColorLevel::NoColor => Color::Reset,
    }
}

/// Map a 24-bit RGB triple to the nearest xterm-256 palette index (16–255):
/// the 6×6×6 color cube plus the 24-step grayscale ramp.
pub fn rgb_to_256(r: u8, g: u8, b: u8) -> u8 {
    // Grayscale ramp (232–255) when the channels are near-equal — it has finer
    // steps than the cube's gray diagonal.
    if r == g && g == b {
        if r < 8 {
            return 16;
        }
        if r > 248 {
            return 231;
        }
        return 232 + (((r as u16 - 8) * 24) / 247) as u8;
    }
    let ri = channel_to_cube(r);
    let gi = channel_to_cube(g);
    let bi = channel_to_cube(b);
    16 + 36 * ri + 6 * gi + bi
}

/// Map one 0–255 channel to a 0–5 cube coordinate using the xterm cube levels
/// (0, 95, 135, 175, 215, 255).
fn channel_to_cube(v: u8) -> u8 {
    const LEVELS: [u8; 6] = [0, 95, 135, 175, 215, 255];
    let mut best = 0u8;
    let mut best_dist = u16::MAX;
    for (i, &lv) in LEVELS.iter().enumerate() {
        let d = (lv as i16 - v as i16).unsigned_abs();
        if d < best_dist {
            best_dist = d;
            best = i as u8;
        }
    }
    best
}

/// Standard 16-color ANSI palette as approximate RGB (xterm defaults), paired
/// with the ratatui named color that renders each slot.
const ANSI16: [(Color, (u8, u8, u8)); 16] = [
    (Color::Black, (0, 0, 0)),
    (Color::Red, (205, 0, 0)),
    (Color::Green, (0, 205, 0)),
    (Color::Yellow, (205, 205, 0)),
    (Color::Blue, (0, 0, 238)),
    (Color::Magenta, (205, 0, 205)),
    (Color::Cyan, (0, 205, 205)),
    (Color::Gray, (229, 229, 229)),
    (Color::DarkGray, (127, 127, 127)),
    (Color::LightRed, (255, 0, 0)),
    (Color::LightGreen, (0, 255, 0)),
    (Color::LightYellow, (255, 255, 0)),
    (Color::LightBlue, (92, 92, 255)),
    (Color::LightMagenta, (255, 0, 255)),
    (Color::LightCyan, (0, 255, 255)),
    (Color::White, (255, 255, 255)),
];

/// Nearest ANSI-16 named color to an RGB triple by squared Euclidean distance.
pub fn rgb_to_ansi16(r: u8, g: u8, b: u8) -> Color {
    let mut best = Color::White;
    let mut best_dist = u32::MAX;
    for (col, (cr, cg, cb)) in ANSI16 {
        let dr = cr as i32 - r as i32;
        let dg = cg as i32 - g as i32;
        let db = cb as i32 - b as i32;
        let dist = (dr * dr + dg * dg + db * db) as u32;
        if dist < best_dist {
            best_dist = dist;
            best = col;
        }
    }
    best
}

/// Downgrade a 256-palette index (≥16) to the nearest ANSI-16 color by first
/// reconstructing its approximate RGB.
fn rgb_to_ansi16_from_index(i: u8) -> Color {
    let (r, g, b) = index256_to_rgb(i);
    rgb_to_ansi16(r, g, b)
}

/// Approximate RGB for a 256-palette index in the cube/grayscale range (16–255).
fn index256_to_rgb(i: u8) -> (u8, u8, u8) {
    if i >= 232 {
        // Grayscale ramp: 232 → 8, step 10.
        let v = 8u16 + (i as u16 - 232) * 10;
        let v = v.min(255) as u8;
        (v, v, v)
    } else {
        const LEVELS: [u8; 6] = [0, 95, 135, 175, 215, 255];
        let idx = i as u16 - 16;
        let r = LEVELS[(idx / 36) as usize];
        let g = LEVELS[((idx % 36) / 6) as usize];
        let b = LEVELS[(idx % 6) as usize];
        (r, g, b)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn truecolor_passes_rgb_through_unchanged() {
        let c = Color::Rgb(12, 200, 77);
        assert_eq!(adapt_color(c, ColorLevel::TrueColor), c);
    }

    #[test]
    fn no_color_drops_every_color_to_reset() {
        assert_eq!(adapt_color(Color::Rgb(255, 0, 0), ColorLevel::NoColor), Color::Reset);
        assert_eq!(adapt_color(Color::Green, ColorLevel::NoColor), Color::Reset);
        assert_eq!(adapt_color(Color::Indexed(200), ColorLevel::NoColor), Color::Reset);
    }

    #[test]
    fn ansi256_maps_rgb_to_indexed() {
        // Pure red → cube coordinate (5,0,0) = 16 + 36*5 = 196.
        assert_eq!(adapt_color(Color::Rgb(255, 0, 0), ColorLevel::Ansi256), Color::Indexed(196));
        // Pure white → 231 (top of the cube) or grayscale 255; both are white.
        match adapt_color(Color::Rgb(255, 255, 255), ColorLevel::Ansi256) {
            Color::Indexed(i) => assert!(i == 231 || i == 255, "got {i}"),
            other => panic!("expected indexed, got {other:?}"),
        }
        // Non-Rgb colors pass through under 256.
        assert_eq!(adapt_color(Color::Cyan, ColorLevel::Ansi256), Color::Cyan);
    }

    #[test]
    fn ansi16_maps_rgb_to_nearest_named() {
        // Bright red maps to a red slot.
        assert!(matches!(
            adapt_color(Color::Rgb(255, 10, 10), ColorLevel::Ansi16),
            Color::Red | Color::LightRed
        ));
        // Near-black maps to black/dark gray.
        assert!(matches!(
            adapt_color(Color::Rgb(4, 4, 4), ColorLevel::Ansi16),
            Color::Black | Color::DarkGray
        ));
        // Near-white maps to white/gray.
        assert!(matches!(
            adapt_color(Color::Rgb(250, 250, 250), ColorLevel::Ansi16),
            Color::White | Color::Gray
        ));
    }

    #[test]
    fn cube_index_reconstructs_close_rgb() {
        // Round-trip sanity: a cube color's reconstructed RGB re-encodes to itself.
        for &i in &[16u8, 21, 46, 196, 226, 231] {
            let (r, g, b) = index256_to_rgb(i);
            assert_eq!(rgb_to_256(r, g, b), i, "index {i} did not round-trip");
        }
    }
}
