//! **The layout contract, enforced.**
//!
//! `layout_invariants` proves things about what components *paint*. This module
//! proves things about the machinery that decides *where they may paint at all*:
//! the band arbiter (`app::event_loop::measure_bands` → [`fit_bands`] →
//! [`inline_split`]) and the [`Measured`] trait it measures through.
//!
//! It exists because a refactor without enforcement just relocates the
//! discipline. The live region shipped, in one session, a composer duplicating
//! down the screen, a roster reserving 30 rows and drawing 34, a checklist handed
//! the same `Rect` as the chat stream, a plan band counted in one sum and not the
//! other, a mention dropdown painting into rows nothing reserved, and toasts
//! painting over the top of the reply. Every one is the same defect — *a
//! component drew at a size nothing had reserved* — and each was fixed
//! individually because nothing asserted the general property.
//!
//! The four properties asserted here are what make the class unrepresentable:
//!
//! 1. **Rects derive from measurements.** Every band's rect is exactly the height
//!    the arbiter granted it — pinned across a width × height × content sweep, so
//!    a mis-ordered `ROW_*` index or a dropped `Constraint` fails loudly.
//! 2. **No two components share a row.** The rects tile the region exactly:
//!    contiguous, disjoint, summing to the area.
//! 3. **It fits, no matter what.** The region never claims more rows than the
//!    viewport has, at any size, with any combination of bands up.
//! 4. **It degrades by priority, and the composer always survives.** Bands are
//!    shed lowest-priority-first; the interactive surface is never the casualty.

#![cfg(test)]

use crate::app::event_loop::{
    fit_bands, inline_split, Band, Bands, INPUT_FLOOR, ROW_AGENTS, ROW_CHECKLIST, ROW_HINT,
    ROW_INPUT, ROW_POPUP, ROW_STATUS, ROW_STREAM, ROW_SURVEY, ROW_THINK, ROW_TOAST, SHED_ORDER,
    STREAM_FLOOR,
};
use crate::components::measure::Measured;
use ratatui::layout::Rect;

/// Every band paired with the `inline_split` row index that must carry it, and a
/// name for failure messages. **This table is the contract**: if a band is added
/// to `Bands` and not to `inline_split`, or the two disagree about an index, the
/// sweep below fails.
const BAND_ROWS: [(Band, usize, &str); 9] = [
    (Band::Toast, ROW_TOAST, "toast"),
    (Band::Checklist, ROW_CHECKLIST, "checklist"),
    (Band::Think, ROW_THINK, "think"),
    (Band::Agents, ROW_AGENTS, "agents"),
    (Band::Survey, ROW_SURVEY, "survey"),
    (Band::Hint, ROW_HINT, "hint"),
    (Band::Popup, ROW_POPUP, "popup"),
    (Band::Input, ROW_INPUT, "input"),
    (Band::Status, ROW_STATUS, "status"),
];

fn band_of(b: &Bands, band: Band) -> u16 {
    match band {
        Band::Toast => b.toast,
        Band::Agents => b.agents,
        Band::Checklist => b.checklist,
        Band::Think => b.think,
        Band::Hint => b.hint,
        Band::Survey => b.survey,
        Band::Popup => b.popup,
        Band::Status => b.status,
        Band::Input => b.input,
    }
}

/// A spread of band demands, from "idle live region" to "every band up at once",
/// including several that cannot possibly fit so the shed ladder is exercised.
fn demand_sweep() -> Vec<Bands> {
    let mut out = vec![
        // Idle: composer + hint + status only.
        Bands {
            input: 3,
            ..Bands::default()
        },
        // A turn running: activity feed + checklist.
        Bands {
            input: 3,
            think: 6,
            checklist: 5,
            ..Bands::default()
        },
        // A fleet turn with a toast and an open completion popup.
        Bands {
            input: 3,
            think: 9,
            checklist: 8,
            agents: 8,
            toast: 3,
            popup: 12,
            ..Bands::default()
        },
        // A blocking ask.
        Bands {
            input: 5,
            survey: 14,
            ..Bands::default()
        },
        // Everything, at its cap. Fits on nothing short of a very tall terminal.
        Bands {
            toast: 3,
            checklist: 12,
            think: 12,
            agents: 8,
            survey: 14,
            popup: 12,
            input: 8,
            ..Bands::default()
        },
    ];
    // Absurd demands: each band alone asking for far more than any cap.
    for band in SHED_ORDER {
        let mut b = Bands {
            input: 3,
            ..Bands::default()
        };
        let mut tmp = b;
        set(&mut tmp, band, 200);
        b = tmp;
        out.push(b);
    }
    out
}

fn set(b: &mut Bands, band: Band, rows: u16) {
    match band {
        Band::Toast => b.toast = rows,
        Band::Agents => b.agents = rows,
        Band::Checklist => b.checklist = rows,
        Band::Think => b.think = rows,
        Band::Hint => b.hint = rows,
        Band::Survey => b.survey = rows,
        Band::Popup => b.popup = rows,
        Band::Status => b.status = rows,
        Band::Input => b.input = rows,
    }
}

/// Heights from "cannot fit anything" to "fits everything comfortably", one row
/// at a time through the interesting range.
fn height_sweep() -> Vec<u16> {
    (1u16..=48).collect()
}

/// Widths including the narrow ones a drag passes through.
fn width_sweep() -> [u16; 6] {
    [20, 40, 55, 80, 120, 200]
}

// ─────────────────── 1. Rects derive from measurements ───────────────────

/// **Every band is handed exactly the rows it was granted — never more.**
///
/// This is the "reserved == drawn" property at the layout level: a component
/// cannot be handed a rect it did not measure for, because the rect *is* the
/// measurement. The bug it forecloses is the one that shipped repeatedly — the
/// agents roster reserving 30 rows and drawing 34, the checklist handed the
/// stream's own rect — plus the silent variants a `ROW_*` index shuffle would
/// cause.
#[test]
fn every_band_rect_is_exactly_the_height_the_arbiter_granted() {
    for want in demand_sweep() {
        for h in height_sweep() {
            for w in width_sweep() {
                let area = Rect::new(0, 0, w, h);
                let fitted = fit_bands(want, h);
                let rows = inline_split(area, fitted);
                for (band, idx, name) in BAND_ROWS {
                    let granted = band_of(&fitted, band);
                    let drawn = rows[idx].height;
                    assert_eq!(
                        drawn, granted,
                        "{name} band was granted {granted} rows but its rect is {drawn} \
                         at {w}x{h} (wanted {:?}, fitted {:?})",
                        want, fitted
                    );
                }
            }
        }
    }
}

/// The streaming band is the remainder, and it is never negative — i.e. the
/// arbiter never over-commits the region and leaves the reply with a rect
/// computed from an underflow.
#[test]
fn the_stream_band_is_whatever_the_arbiter_did_not_grant_away() {
    for want in demand_sweep() {
        for h in height_sweep() {
            let area = Rect::new(0, 0, 80, h);
            let fitted = fit_bands(want, h);
            let rows = inline_split(area, fitted);
            assert_eq!(
                rows[ROW_STREAM].height,
                h.saturating_sub(fitted.reserved()),
                "the stream band must be exactly the rows nothing else claimed \
                 (h={h}, fitted={fitted:?})"
            );
        }
    }
}

// ─────────────────── 2. No two components share a row ───────────────────

/// **No two components may write to the same row**, and no row of the region is
/// left unowned.
///
/// The checklist interleaving with a streaming markdown table, the `@`-mention
/// dropdown painting above the composer, the toasts painting over the top three
/// rows of the reply — all three were two components addressing one row. Here
/// the rects are asserted to tile the region: contiguous, disjoint, exhaustive.
#[test]
fn the_bands_tile_the_region_with_no_row_shared_and_no_row_lost() {
    for want in demand_sweep() {
        for h in height_sweep() {
            for w in width_sweep() {
                let area = Rect::new(0, 7, w, h); // non-zero origin: y offsets must be honoured
                let rows = inline_split(area, fit_bands(want, h));

                let mut cursor = area.y;
                let mut total = 0u16;
                for (i, r) in rows.iter().enumerate() {
                    assert_eq!(
                        r.y, cursor,
                        "band {i} starts at row {} but the previous band ended at {cursor} \
                         — a gap or an overlap ({w}x{h}, {want:?})",
                        r.y
                    );
                    cursor = r.y + r.height;
                    total += r.height;
                }
                assert_eq!(
                    cursor,
                    area.y + area.height,
                    "the bands stop at {cursor} but the region ends at {} ({w}x{h})",
                    area.y + area.height
                );
                assert_eq!(total, area.height, "the bands must sum to the region ({w}x{h})");
            }
        }
    }
}

// ─────────────────── 3. It fits, no matter what ───────────────────

/// **"It should be able to fit no matter what."**
///
/// The arbiter never grants more rows than the viewport has — at any height,
/// with any demand, including demands an order of magnitude too large. Before it
/// existed, ten bands each clamped themselves against an independently
/// hand-written floor expression and nothing checked the total, which is how one
/// drag left nine live regions on screen, each overflowing the last.
#[test]
fn the_live_region_never_claims_more_rows_than_the_viewport_has() {
    for want in demand_sweep() {
        for h in height_sweep() {
            let fitted = fit_bands(want, h);
            assert!(
                fitted.reserved() <= h,
                "at {h} rows the arbiter granted {} rows of bands ({fitted:?}) from {want:?}",
                fitted.reserved()
            );
        }
    }
}

/// Whenever there is room, the streaming band keeps its floor: the reply, the
/// inline permission prompt and the plan-review panel all live there, and a
/// region with zero stream rows has nothing to say.
#[test]
fn the_stream_keeps_its_floor_whenever_the_viewport_can_afford_one() {
    let min_viable = INPUT_FLOOR + STREAM_FLOOR;
    for want in demand_sweep() {
        for h in height_sweep() {
            if h < min_viable {
                continue;
            }
            let fitted = fit_bands(want, h);
            assert!(
                h - fitted.reserved() >= STREAM_FLOOR,
                "at {h} rows the stream band was squeezed to {} ({fitted:?})",
                h - fitted.reserved()
            );
        }
    }
}

/// **The refactor changes nothing on a terminal that fits.** When the demand
/// already fits, the arbiter is the identity function — so every normal-sized
/// terminal lays out byte-identically to before the arbiter existed. This is
/// what makes the change safe to land: the new behaviour is confined to the
/// sizes that were previously broken.
#[test]
fn an_arbiter_with_room_to_spare_grants_exactly_what_was_asked() {
    for want in demand_sweep() {
        let capped = want.capped();
        let roomy = capped.reserved() + STREAM_FLOOR + 20;
        assert_eq!(
            fit_bands(want, roomy),
            capped,
            "with {roomy} rows available nothing should have been shed from {want:?}"
        );
    }
}

// ────────── 4. Degrade by priority; the composer always survives ──────────

/// **The composer survives every viewport.** It is the only interactive surface;
/// a live region that sheds it has stopped being a terminal UI and become a
/// picture of one.
#[test]
fn the_composer_is_never_shed() {
    for want in demand_sweep() {
        for h in height_sweep() {
            let fitted = fit_bands(want, h);
            assert!(
                fitted.input >= INPUT_FLOOR,
                "the composer was shed to {} rows at height {h} ({fitted:?})",
                fitted.input
            );
        }
    }
}

/// **Bands are shed in priority order.** A band may only be holding rows if
/// every lower-priority band has already been reduced to its FLOOR — the ladder
/// in `SHED_ORDER`, asserted rather than commented.
///
/// Floor, not zero, because two bands have one: the composer (`INPUT_FLOOR` —
/// below it there is no interactive surface) and, while a subagent is actually
/// running, the roster (`AGENTS_FLOOR` — below it there is no evidence the
/// subagent exists). Everything else sheds to nothing.
///
/// Without this, "it fits" could be satisfied by shedding the survey the user is
/// answering while a stale toast keeps its row.
#[test]
fn bands_are_shed_from_the_lowest_priority_up() {
    let want = Bands {
        toast: 3,
        checklist: 12,
        think: 12,
        agents: 8,
        survey: 14,
        popup: 12,
        input: 8,
        ..Bands::default()
    };
    for h in height_sweep() {
        let fitted = fit_bands(want, h);
        let capped = want.capped();
        // Walk the ladder: once a band is intact, every band above it must be
        // intact too; once a band is reduced, every band below it must be gone.
        for (i, band) in SHED_ORDER.iter().enumerate() {
            let asked = band_of(&capped, *band);
            let got = band_of(&fitted, *band);
            if got < asked {
                for lower in &SHED_ORDER[..i] {
                    let floor = crate::app::event_loop::band_floor(&fitted, *lower);
                    assert_eq!(
                        band_of(&fitted, *lower),
                        floor,
                        "at {h} rows {band:?} was reduced ({asked} → {got}) while the \
                         lower-priority {lower:?} still holds \
                         {} rows above its floor of {floor} ({fitted:?})",
                        band_of(&fitted, *lower)
                    );
                }
            }
        }
    }
}

/// A band is *shrunk* before it is *dropped*: a one-row squeeze costs one row,
/// not a whole feature. (The old per-band clamps did this by accident; the
/// arbiter must do it on purpose.)
#[test]
fn a_one_row_squeeze_costs_exactly_one_row() {
    let want = Bands {
        input: 3,
        think: 9,
        checklist: 8,
        ..Bands::default()
    };
    let exact = want.capped().reserved() + STREAM_FLOOR;
    let roomy = fit_bands(want, exact);
    let tight = fit_bands(want, exact - 1);
    assert_eq!(roomy, want.capped());
    assert_eq!(
        tight.reserved(),
        roomy.reserved() - 1,
        "one row less of viewport must cost exactly one row of bands \
         (roomy={roomy:?}, tight={tight:?})"
    );
    // …and it came off the lowest-priority band that had rows.
    assert_eq!(tight.checklist, roomy.checklist - 1);
}

// ─────────────────── The `Measured` trait round-trip ───────────────────

/// A component's `desired_height` is what it is laid out against, so an idle
/// component must claim nothing: an idle live region has no dead rows, which is
/// what keeps the composer sitting tight against the last message.
#[test]
fn idle_components_claim_no_rows() {
    let checklist = crate::components::task_checklist::TaskChecklist::new();
    let toasts = crate::components::toast::Toasts::new();
    let agents = crate::components::agents::Agents::new();
    let thinking = crate::components::chat::thinking_box::ThinkingBox::new();

    for w in width_sweep() {
        assert_eq!(checklist.desired_height(w), 0, "idle checklist at {w}");
        assert_eq!(toasts.desired_height(w), 0, "idle toasts at {w}");
        assert_eq!(agents.desired_height(w), 0, "idle agents at {w}");
        assert_eq!(thinking.desired_height(w), 0, "idle thinking box at {w}");
    }
}

/// The measurement is **pure**: it is called twice per frame — once to size the
/// inline viewport, once to lay it out — and a difference between those two
/// calls is precisely the reserved-vs-drawn defect. Nothing may make a component
/// answer differently the second time.
#[test]
fn measuring_twice_gives_the_same_answer() {
    let checklist = crate::components::task_checklist::TaskChecklist::new();
    let toasts = crate::components::toast::Toasts::new();
    let agents = crate::components::agents::Agents::new();
    let activity = crate::components::activity::Activity::new();
    let input = crate::components::input::InputComponent::new();

    for w in width_sweep() {
        assert_eq!(checklist.desired_height(w), checklist.desired_height(w));
        assert_eq!(toasts.desired_height(w), toasts.desired_height(w));
        assert_eq!(agents.desired_height(w), agents.desired_height(w));
        assert_eq!(activity.desired_height(w), activity.desired_height(w));
        assert_eq!(input.desired_height(w), input.desired_height(w));
        // The composer's popup band is a separate claim with the same contract.
        assert_eq!(input.popup_desired_height(), input.popup_desired_height());
    }
}

/// The composer always claims at least the row the caret sits on, at every
/// width — so `INPUT_FLOOR` is a floor the component agrees with rather than one
/// the arbiter imposes on it.
#[test]
fn the_composer_always_claims_at_least_its_floor() {
    let input = crate::components::input::InputComponent::new();
    for w in width_sweep() {
        assert!(
            input.desired_height(w) >= INPUT_FLOOR,
            "composer claimed {} rows at width {w}",
            input.desired_height(w)
        );
    }
}
