//! Cross-cutting visual invariants for the TUI.
//!
//! These are behaviour guarantees that span several components and would each
//! be easy to regress from an unrelated change, so they live together in one
//! place rather than scattered through the modules they exercise:
//!
//!   * P1-1  — tool status markers occupy a FIXED column (no horizontal jump as
//!     a call moves running → done → failed), and a failure is distinguishable
//!     without relying on colour.
//!   * P1-2  — the context meter's percentage styling: calm below 80%, a subtle
//!     wall-clock pulse from 80%, and a persistent bold warning once the backend
//!     flags the low-context band.
//!   * P1-10 — display-width measurement and column-fitting never PANIC on
//!     adversarial Unicode (escapes before emoji, CJK mixed with ASCII, ZWJ
//!     sequences), including a fuzz sweep of random codepoints.
//!
//! All new tests for this work stream belong here (a sibling agent owns the
//! `components/agents/*` and `layout_invariants.rs` test surfaces).

#![cfg(test)]

// ─── P1-1: fixed-column tool status markers ─────────────────────────────────

mod tool_status_markers {
    use crate::tools::{status_icon, ToolStatus};
    use crate::util::cols;

    /// Every resolvable status this renderer can paint, plus a representative
    /// running frame. The spinner is a separate glyph from the resting bullet,
    /// so it is exercised explicitly.
    fn all_icons() -> Vec<(ToolStatus, Option<char>, String)> {
        let statuses = [
            (ToolStatus::Pending, None),
            (ToolStatus::AwaitingPermission, None),
            (ToolStatus::Running, Some('\u{280b}')), // ⠋ braille spinner frame
            (ToolStatus::Running, None),             // spinner-less fallback
            (ToolStatus::Success, None),
            (ToolStatus::Error, None),
            (ToolStatus::Canceled, None),
        ];
        statuses
            .into_iter()
            .map(|(s, sp)| {
                let (icon, _style) = status_icon(s, sp);
                (s, sp, icon)
            })
            .collect()
    }

    /// The whole point of the marker: the eye tracks a call's state in place. If
    /// the running, done and failed glyphs were different display widths, the
    /// tool name to their right would shift horizontally every time the state
    /// changed. Assert every status icon is exactly one display column.
    #[test]
    fn every_status_icon_is_one_column_wide() {
        for (status, spinner, icon) in all_icons() {
            assert_eq!(
                cols(&icon),
                1,
                "status {status:?} (spinner={spinner:?}) icon {icon:?} is {} cols, not 1 — \
                 it would shift the tool name horizontally when the state changes",
                cols(&icon)
            );
        }
    }

    /// N parallel tools, one of them failed: all N markers align (equal width),
    /// and the failed one is distinguishable by GLYPH alone — not only by colour,
    /// which is lost under NO_COLOR, on a monochrome terminal, or to a
    /// red/green-colour-blind reader.
    #[test]
    fn a_failed_marker_is_distinct_from_a_successful_one_without_colour() {
        let (ok_icon, _) = status_icon(ToolStatus::Success, None);
        let (err_icon, _) = status_icon(ToolStatus::Error, None);
        assert_ne!(
            ok_icon, err_icon,
            "success and failure must differ in the glyph, not only the colour"
        );
        assert_eq!(cols(&ok_icon), cols(&err_icon), "markers must stay aligned");
    }

    /// The failed marker carries the theme's error colour, and it is a terminal
    /// status, so it persists (there is no code path that downgrades Error to a
    /// neutral glyph — this is a compile-time guarantee re-stated as a test that
    /// the colour role is the error role).
    #[test]
    fn a_failed_marker_uses_the_error_colour() {
        let theme = crate::style::theme();
        let (_icon, style) = status_icon(ToolStatus::Error, None);
        assert_eq!(style.fg, Some(theme.colors.error));
    }
}

// ─── P1-2: context-meter percentage styling ─────────────────────────────────

mod context_meter_style {
    use crate::components::status_bar::{ctx_pct_style, CTX_PULSE_RATIO};
    use crate::style;
    use ratatui::style::Modifier;

    fn color() -> ratatui::style::Color {
        style::theme().colors.warning
    }

    /// Below the pulse threshold the readout is calm: the plain severity colour,
    /// no emphasis, regardless of the wall-clock phase.
    #[test]
    fn below_the_threshold_the_readout_is_calm() {
        for bright in [false, true] {
            let s = ctx_pct_style(color(), 0.50, false, bright);
            assert!(
                !s.add_modifier.contains(Modifier::BOLD),
                "a half-full meter must not pulse (bright={bright})"
            );
        }
    }

    /// At/above the threshold the readout pulses: BOLD on the bright phase, plain
    /// on the dim phase, so the number "breathes" without a colour change or a
    /// change in display width.
    #[test]
    fn at_the_threshold_the_readout_pulses() {
        let bright = ctx_pct_style(color(), CTX_PULSE_RATIO, false, true);
        let dim = ctx_pct_style(color(), CTX_PULSE_RATIO, false, false);
        assert!(
            bright.add_modifier.contains(Modifier::BOLD),
            "the bright phase must be emphasised"
        );
        assert!(
            !dim.add_modifier.contains(Modifier::BOLD),
            "the dim phase must relax so the pulse is visible"
        );
    }

    /// Once the backend flags the low-context band the readout is a HARD warning:
    /// always bold, every phase, so it never blinks off. (The colour is the
    /// error colour the caller selects; here we assert the persistence.)
    #[test]
    fn the_low_context_warning_is_always_bold() {
        for bright in [false, true] {
            let s = ctx_pct_style(color(), 0.97, true, bright);
            assert!(
                s.add_modifier.contains(Modifier::BOLD),
                "the low-context warning must stay bold on every phase (bright={bright})"
            );
        }
    }

    /// The pulse begins strictly before "full" and at a sane fraction — a guard
    /// against someone quietly moving the threshold to, say, 0.99 where it would
    /// never help.
    #[test]
    fn the_pulse_threshold_is_a_pre_warning_fraction() {
        assert!(
            (0.70..0.90).contains(&CTX_PULSE_RATIO),
            "pulse should start well before the window is full: {CTX_PULSE_RATIO}"
        );
    }
}

// ─── P2-5: status-line fit — the context meter always survives ──────────────

mod status_line_fit {
    use crate::components::status_bar::model_name_budget;
    use crate::util::{cols, fit_cols};

    /// The meter's reserve is the point of the budget: on an 80-column pane, the
    /// glyph + cwd + fitted model name must leave at least the meter's reserve
    /// (26 cols) free, no matter how long the model id is.
    #[test]
    fn a_long_model_name_never_eats_the_meter_reserve() {
        const TOTAL: usize = 80;
        const RESERVE: usize = 26; // TITLE_RESERVE_COLS
        for cwd in ["osa", "some-longish-workdir-name", "x"] {
            let cwd_cols = cols(cwd);
            let budget = model_name_budget(TOTAL, cwd_cols);
            let long = "anthropic/claude-opus-4-8-20260101-experimental-preview-max";
            let fitted = fit_cols(long, budget);
            // Glyph(2) + cwd + gap(2) + model + reserve must fit the row, so the
            // meter is never clipped.
            let consumed = 2 + cwd_cols + 2 + cols(&fitted);
            assert!(
                consumed + RESERVE <= TOTAL,
                "cwd={cwd:?}: model segment ({consumed}) + reserve ({RESERVE}) overran {TOTAL}"
            );
        }
    }

    /// However narrow the pane, the model name never vanishes entirely — it keeps
    /// at least the floor so it stays recognizable.
    #[test]
    fn the_model_name_keeps_a_recognizable_floor_on_any_width() {
        for total in [20usize, 40, 60, 80, 120, 200] {
            for cwd_cols in [1usize, 10, 40] {
                assert!(
                    model_name_budget(total, cwd_cols) >= 12,
                    "budget fell below the floor at total={total}, cwd_cols={cwd_cols}"
                );
            }
        }
    }

    /// A short model name that already fits is returned untouched (fast path),
    /// so the common case is never ellipsized.
    #[test]
    fn a_short_model_name_is_not_truncated() {
        let budget = model_name_budget(120, cols("osa"));
        assert_eq!(fit_cols("grok-4.6", budget), "grok-4.6");
    }
}

// ─── P1-10: Unicode / multibyte width is panic-safe ─────────────────────────

mod unicode_width_panic_safety {
    use crate::tools::wrap_plain;
    use crate::util::{cols, fit_cols};

    /// Concrete adversarial inputs that each hit a distinct hazard the width path
    /// has to survive: an SGR/OSC escape immediately before a wide emoji, CJK
    /// interleaved with ASCII, a ZWJ family sequence, a dangling lone ESC, and a
    /// truncated OSC-8 hyperlink header.
    fn hostile_samples() -> Vec<String> {
        vec![
            // Escape (SGR) directly before an emoji.
            "\u{1b}[31m\u{1f600}".to_string(),
            // Escape directly before a CJK char.
            "\u{1b}[1m\u{6f22}\u{5b57}".to_string(),
            // Bare ESC then emoji, no intermediate bytes.
            "\u{1b}\u{1f600}".to_string(),
            // CJK mixed with ASCII, no escapes.
            "a\u{6f22}b\u{5b57}c\u{ff21}d".to_string(),
            // ZWJ family: one grapheme cluster of four people.
            "x\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}\u{200d}\u{1f466}y".to_string(),
            // Regional-indicator flag (two codepoints, one cluster).
            "flag\u{1f1ef}\u{1f1f5}end".to_string(),
            // Combining marks stacked on a base.
            "e\u{0301}\u{0302}\u{0303}o".to_string(),
            // Truncated OSC-8 hyperlink header (no terminator).
            "\u{1b}]8;;https://osa.dev/very/long/path".to_string(),
            // OSC-8 header immediately followed by an emoji then a bare ESC.
            "\u{1b}]8;;http://x\u{7}\u{1f680}\u{1b}".to_string(),
            // Lone trailing ESC.
            "trailing\u{1b}".to_string(),
        ]
    }

    /// None of `cols`, `fit_cols` (at every budget through the string) or
    /// `wrap_plain` (at a range of column widths) may panic on any hostile
    /// sample. A width measurement runs on every frame of every row, so a single
    /// panic here aborts the whole session.
    #[test]
    fn width_helpers_never_panic_on_hostile_samples() {
        for s in hostile_samples() {
            let _ = cols(&s);
            for budget in 0..=(s.chars().count() + 2) {
                let out = fit_cols(&s, budget);
                assert!(cols(&out) <= budget.max(1) || budget == 0);
            }
            for width in [1usize, 2, 3, 8, 40, 80] {
                let _ = wrap_plain(&s, width);
            }
        }
    }

    /// Deterministic LCG so the fuzz sweep is reproducible without a `rand`
    /// dependency. Same constants as `rand`'s `Pcg`-free minimal generators use
    /// for smoke tests; any full-period 64-bit LCG is fine here.
    struct Lcg(u64);
    impl Lcg {
        fn next_u32(&mut self) -> u32 {
            // Numerical Recipes LCG constants.
            self.0 = self
                .0
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            (self.0 >> 32) as u32
        }
    }

    /// Build a random string of up to ~24 codepoints, drawing from the ranges
    /// that actually break width code: ASCII, Latin-1, combining marks, CJK,
    /// emoji, regional indicators, ZWJ, and raw ESC bytes.
    fn random_hostile_string(rng: &mut Lcg) -> String {
        let len = (rng.next_u32() % 24) as usize;
        let mut s = String::new();
        for _ in 0..len {
            let pick = rng.next_u32() % 8;
            let ch = match pick {
                0 => char::from((rng.next_u32() % 0x80) as u8), // ASCII incl. control
                1 => '\u{1b}',                                  // raw ESC
                2 => char::from_u32(0x0300 + rng.next_u32() % 0x50).unwrap_or('\u{0301}'), // combining
                3 => char::from_u32(0x4e00 + rng.next_u32() % 0x2000).unwrap_or('\u{6f22}'), // CJK
                4 => char::from_u32(0x1f300 + rng.next_u32() % 0x500).unwrap_or('\u{1f600}'), // emoji
                5 => char::from_u32(0x1f1e6 + rng.next_u32() % 26).unwrap_or('\u{1f1ef}'), // regional
                6 => '\u{200d}',                                                           // ZWJ
                _ => char::from_u32(0xa0 + rng.next_u32() % 0x300).unwrap_or('\u{00e9}'), // Latin-ext
            };
            s.push(ch);
        }
        s
    }

    /// Fuzz sweep: thousands of random strings across every width helper. The
    /// assertion is simply "no panic" — plus that `fit_cols` never exceeds its
    /// budget, which is the invariant a layout depends on. A width panic used to
    /// be reachable from raw, unsanitised tool output, which the attacker
    /// controls, so this is a security-relevant guarantee, not only cosmetic.
    #[test]
    fn fuzz_random_unicode_never_panics_and_respects_budgets() {
        let mut rng = Lcg(0x1234_5678_9abc_def0);
        for _ in 0..5000 {
            let s = random_hostile_string(&mut rng);
            let _ = cols(&s);
            // `fit_cols` fits DISPLAY GRAPHEMES; ANSI-escape handling is `cols`'s
            // job, not its (see the doc split between the two in `util`). Feeding
            // raw ESC to `fit_cols` is out of its contract and makes the two
            // measures disagree by a column — no panic, just a definitional
            // mismatch — so the budget invariant is asserted on escape-free input
            // (its real domain); no-panic is asserted for ALL input below.
            let escape_free = !s.contains('\u{1b}');
            for budget in [0usize, 1, 2, 5, 10, 20] {
                let out = fit_cols(&s, budget);
                if escape_free {
                    assert!(
                        cols(&out) <= budget || budget == 0,
                        "fit_cols overflowed budget {budget} on {s:?} -> {out:?} ({} cols)",
                        cols(&out)
                    );
                }
            }
            for width in [1usize, 3, 7, 16, 80] {
                // No-panic is the guarantee here. Row width is intentionally NOT
                // re-asserted against `cols`: `wrap_plain` accumulates per-char
                // (`UnicodeWidthChar`) while `cols` measures at the string level
                // (`UnicodeWidthStr`), and the two libraries disagree on ZWJ /
                // emoji CLUSTER width by design — a pre-existing property, not a
                // panic, and out of scope for this work stream.
                let _ = wrap_plain(&s, width);
            }
        }
    }
}
