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

/// Quantize `color` to what `level` can render — the single, documented entry
/// point for color downgrading (truecolor → 256 → 16 → none).
///
/// This is a thin, stable alias over [`adapt_color`]: `TrueColor` keeps
/// `Color::Rgb` as-is, `Ansi256` maps it into the xterm-256 palette, `Ansi16`
/// maps it to the nearest named ANSI color, and [`ColorLevel::NoColor`] drops
/// all color to [`Color::Reset`]. Prefer calling this from new code so the
/// quantization pipeline has one obvious name.
///
/// ```ignore
/// quantize(Color::Rgb(255, 0, 0), ColorLevel::Ansi256) == Color::Indexed(196);
/// quantize(Color::Rgb(255, 0, 0), ColorLevel::NoColor) == Color::Reset;
/// ```
pub fn quantize(color: Color, level: ColorLevel) -> Color {
    adapt_color(color, level)
}

/// Quantize `color` for the terminal's detected color level (see [`color_level`]).
pub fn quantize_for_terminal(color: Color) -> Color {
    quantize(color, color_level())
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

// ---------------------------------------------------------------------------
// Luminance-wave helpers (grok xai-grok-pager `wave_brightness`)
//
// A running activity paints a left rail whose per-row brightness follows a
// sin^2 wave that travels down the column as the animation tick advances, so
// the live region reads as "alive". These are pure math + a blend that reuses
// the same truecolor -> 256 -> 16 -> none quantization pipeline as the rest of
// this module, so the rail downgrades correctly on limited terminals.
// ---------------------------------------------------------------------------

/// Per-row brightness in `0.0..=1.0` for a luminance wave that travels down a
/// rail of `wave_rows` rows at animation `tick` (grok `wave_brightness`).
///
/// `brightness = sin^2((row / wave_rows) * 2π + tick * SPEED)`. The spatial term
/// gives the wave its shape down the column; the temporal `tick * SPEED` term
/// slides that shape so the crest travels (a fixed row's brightness changes with
/// the tick). `sin^2` keeps the result in `[0, 1]` with no negative lobe, so it
/// blends cleanly from background toward the accent.
pub fn wave_brightness(tick: u64, row: u16, wave_rows: u16) -> f32 {
    // Radians the wave advances per animation frame. Chosen so the crest travels
    // roughly one rail-height every couple of seconds at the ~7.5fps spinner
    // clock: brisk enough to read as alive, slow enough to stay subtle.
    const SPEED: f32 = 0.35;
    let rows = wave_rows.max(1) as f32;
    let phase = (row as f32 / rows) * std::f32::consts::TAU + tick as f32 * SPEED;
    let s = phase.sin();
    s * s
}

/// Temporal-only pulse brightness in `0.0..=1.0` (a non-moving `sin^2` breathe).
/// Every row shares one value at a given `tick`, so a rail painted with it
/// pulses in place rather than showing a traveling crest. Kept for callers that
/// want a "breathing" cue without spatial motion.
#[allow(dead_code)]
pub fn pulse_brightness(tick: u64) -> f32 {
    const SPEED: f32 = 0.35;
    let s = (tick as f32 * SPEED).sin();
    s * s
}

/// Blend `bg` toward `fg` by `t` (`0.0` ⇒ `bg`, `1.0` ⇒ `fg`), interpolating each
/// RGB channel, then quantize the result for the detected terminal color level
/// (the same [`quantize_for_terminal`] pipeline every other color takes). Both
/// endpoints are expected to be [`Color::Rgb`] (theme colors are); a non-Rgb
/// endpoint falls back to a midpoint pick before quantization.
pub fn blend_color(bg: Color, fg: Color, t: f32) -> Color {
    let t = t.clamp(0.0, 1.0);
    let blended = match (bg, fg) {
        (Color::Rgb(r1, g1, b1), Color::Rgb(r2, g2, b2)) => {
            let lerp = |a: u8, b: u8| -> u8 {
                (a as f32 + (b as f32 - a as f32) * t).round().clamp(0.0, 255.0) as u8
            };
            Color::Rgb(lerp(r1, r2), lerp(g1, g2), lerp(b1, b2))
        }
        _ => {
            if t < 0.5 {
                bg
            } else {
                fg
            }
        }
    };
    quantize_for_terminal(blended)
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
    fn quantize_entry_point_maps_across_levels() {
        // The public entry point walks truecolor -> 256 -> 16 -> none.
        let red = Color::Rgb(255, 0, 0);
        assert_eq!(quantize(red, ColorLevel::TrueColor), red);
        assert_eq!(quantize(red, ColorLevel::Ansi256), Color::Indexed(196));
        assert!(matches!(
            quantize(red, ColorLevel::Ansi16),
            Color::Red | Color::LightRed
        ));
        assert_eq!(quantize(red, ColorLevel::NoColor), Color::Reset);
        // It is a faithful alias of adapt_color.
        assert_eq!(
            quantize(red, ColorLevel::Ansi256),
            adapt_color(red, ColorLevel::Ansi256)
        );
    }

    #[test]
    fn wave_brightness_stays_in_unit_range() {
        // sin^2 is bounded to [0, 1] for every row/tick, so the blend it drives
        // never over- or under-shoots the bg..fg segment.
        for tick in 0u64..50 {
            for row in 0u16..20 {
                let b = wave_brightness(tick, row, 8);
                assert!((0.0..=1.0).contains(&b), "brightness {b} out of range");
            }
        }
        // wave_rows == 0 must not divide-by-zero / NaN (clamped to 1).
        let b = wave_brightness(3, 0, 0);
        assert!(b.is_finite() && (0.0..=1.0).contains(&b));
    }

    #[test]
    fn wave_brightness_is_a_traveling_wave() {
        // Varies down the column at a fixed tick (spatial shape)...
        let rows = 8u16;
        let col: Vec<f32> = (0..rows).map(|r| wave_brightness(0, r, rows)).collect();
        assert!(
            col.windows(2).any(|w| (w[0] - w[1]).abs() > 1e-4),
            "brightness must vary across rows"
        );
        // ...and the crest travels: a fixed row's brightness changes with the
        // tick for some offset k (that is what makes the wave move, not pulse).
        let row = 2u16;
        let base = wave_brightness(0, row, rows);
        assert!(
            (1..8).any(|k| (wave_brightness(k, row, rows) - base).abs() > 1e-3),
            "a fixed row must change over ticks (traveling wave)"
        );
    }

    #[test]
    fn pulse_brightness_is_temporal_only() {
        // Every row shares one value at a tick (no spatial term), and it still
        // moves over ticks.
        assert!((0.0..=1.0).contains(&pulse_brightness(0)));
        let a = pulse_brightness(1);
        let b = pulse_brightness(4);
        assert!((a - b).abs() > 1e-3, "pulse must change across ticks");
    }

    #[test]
    fn blend_color_hits_endpoints() {
        // t=0 lands on ~bg, t=1 on ~fg (post-quantize tolerant: on a truecolor
        // terminal the quantizer is the identity, on a downgraded one both ends
        // still map through the same pipeline the theme colors take).
        let bg = Color::Rgb(17, 24, 39); // theme surface (#111827)
        let fg = Color::Rgb(78, 186, 101); // success green
        let want_bg = quantize_for_terminal(bg);
        let want_fg = quantize_for_terminal(fg);
        assert_eq!(blend_color(bg, fg, 0.0), want_bg, "t=0 returns ~bg");
        assert_eq!(blend_color(bg, fg, 1.0), want_fg, "t=1 returns ~fg");
        // A midpoint sits between the two on at least one channel (before
        // quantization); under truecolor we can read it back directly.
        if let (Color::Rgb(_, mg, _), Color::Rgb(_, _, _)) =
            (blend_color(bg, fg, 0.5), fg)
        {
            assert!(mg > 24 && mg < 186, "green channel interpolates, got {mg}");
        }
        // Clamps out-of-range t without panic.
        assert_eq!(blend_color(bg, fg, -1.0), want_bg);
        assert_eq!(blend_color(bg, fg, 2.0), want_fg);
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

// ── code blocks must stay readable after quantization ───────────────────────
//
// The fenced-code background is the one colour decision that cannot be taken
// back: those rows are committed into NATIVE SCROLLBACK, where the app can
// never repaint them. If the background quantises onto the foreground on a
// 16-colour terminal, the code is unreadable for the rest of that session and
// no redraw fixes it.
//
// `cargo test` cannot see a terminal, but it CAN see the quantiser, which is
// where the collision would happen.
#[cfg(test)]
mod code_block_contrast {
    use super::*;
    use crate::style::themes;

    fn themes_under_test() -> Vec<(&'static str, crate::style::Theme)> {
        vec![
            ("dark", themes::dark()),
            ("light", themes::light()),
            ("catppuccin", themes::by_name("catppuccin").unwrap_or_else(themes::dark)),
            ("tokyo-night", themes::by_name("tokyo-night").unwrap_or_else(themes::dark)),
        ]
    }

    #[test]
    fn code_fg_never_collapses_onto_code_bg_at_any_colour_depth() {
        for (name, theme) in themes_under_test() {
            let fg = theme.colors.code_fg;
            let bg = theme.colors.code_bg;

            for level in [ColorLevel::TrueColor, ColorLevel::Ansi256, ColorLevel::Ansi16] {
                let qfg = adapt_color(fg, level);
                let qbg = adapt_color(bg, level);
                assert_ne!(
                    qfg, qbg,
                    "{name} at {level:?}: code foreground and background quantise to the \
                     same colour — code would be invisible, permanently, in scrollback"
                );
            }
        }
    }

    #[test]
    fn no_color_drops_the_code_background_entirely() {
        // Under NO_COLOR the background must not survive as a block of colour
        // the terminal then renders against its own foreground.
        for (name, theme) in themes_under_test() {
            assert_eq!(
                adapt_color(theme.colors.code_bg, ColorLevel::NoColor),
                Color::Reset,
                "{name}: NO_COLOR must drop the code background"
            );
            assert_eq!(
                adapt_color(theme.colors.code_fg, ColorLevel::NoColor),
                Color::Reset,
                "{name}: NO_COLOR must drop the code foreground"
            );
        }
    }

}
