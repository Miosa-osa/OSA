//! `/context` — the context-window breakdown overlay.
//!
//! Answers "what is filling my context window right now?" at a glance. The raw
//! `/context` used to print a bare `used/max` number; this replaces it with a
//! branded card that shows *composition*, not just totals: a single full-width
//! segmented bar where the conversation, system prompt, and tool-result shares
//! are three contiguous colored segments sized by their fraction of the window
//! ceiling, trailing off into a dim "free space" run. Below the bar, one aligned
//! row per category (colored dot + label + right-aligned `NN,NNN (PP%)`), then a
//! TOTAL row for the overall fill.
//!
//! Stateless: `event_loop` builds a fresh [`ContextStats`] from live client state
//! on every frame and hands it to [`draw`], so the numbers are never stale. There
//! is no `handle_key` — esc/q/enter dismiss app-side. All percentages are taken
//! against `max_tokens`, guarding `max_tokens == 0` to avoid a divide-by-zero.

use ratatui::{
    prelude::*,
    widgets::{Block, BorderType, Borders, Clear, Paragraph},
};

/// Clip-safe render (shared choke point with the other dialogs).
fn put<W: ratatui::widgets::Widget>(frame: &mut Frame, widget: W, rect: Rect) {
    crate::app::event_loop::safe_render_widget(frame, widget, rect);
}

const DIALOG_W: u16 = 60;

/// Live snapshot the breakdown renders. Owned so `draw` never borrows `App`.
///
/// Mirrors the client-side `ContextStats`: three category token counts, the
/// window ceiling (`max_tokens`), and the reported `used_tokens` total. The
/// category counts need not sum to `used_tokens` — any remainder is folded into
/// an "other" run so the segmented bar always reflects true occupancy.
pub struct ContextStats {
    pub system_tokens: u64,
    pub conversation_tokens: u64,
    pub tool_result_tokens: u64,
    pub max_tokens: u64,
    pub used_tokens: u64,
}

/// One labelled category: dot color, name, token count.
struct Category {
    label: &'static str,
    tokens: u64,
    color: Color,
}

/// Percent of `max` as an integer 0..=100, divide-by-zero-safe.
fn pct_of(tokens: u64, max: u64) -> u64 {
    if max == 0 {
        0
    } else {
        // Round to nearest, saturating so a bogus over-max count shows 100.
        ((tokens.saturating_mul(100) + max / 2) / max).min(100)
    }
}

/// Group-thousands a token count: `12345` -> `"12,345"`.
fn group_thousands(mut n: u64) -> String {
    if n == 0 {
        return "0".to_string();
    }
    let mut groups: Vec<String> = Vec::new();
    while n > 0 {
        let chunk = n % 1000;
        n /= 1000;
        if n > 0 {
            groups.push(format!("{chunk:03}"));
        } else {
            groups.push(chunk.to_string());
        }
    }
    groups.reverse();
    groups.join(",")
}

/// Char-boundary-safe truncation (a long label can never panic).
fn truncate_chars(s: &str, max: usize) -> String {
    if s.chars().count() > max {
        let take = max.saturating_sub(1);
        format!("{}\u{2026}", s.chars().take(take).collect::<String>())
    } else {
        s.to_string()
    }
}

/// Lay `total` cells across the category segments + free space, largest-remainder
/// rounded so the segment widths always sum to exactly `total`. Returns one width
/// per category (in `cats` order) followed by the free-space width.
fn segment_widths(cats: &[Category], max: u64, total: usize) -> Vec<usize> {
    let n = cats.len();
    if total == 0 || max == 0 {
        let mut v = vec![0usize; n];
        v.push(total); // all free space
        return v;
    }
    // Ideal (fractional) cell counts for each category + free space.
    let used: u64 = cats.iter().map(|c| c.tokens).sum();
    let free = max.saturating_sub(used.min(max));
    let mut shares: Vec<u64> = cats.iter().map(|c| c.tokens.min(max)).collect();
    shares.push(free);

    let mut floors: Vec<usize> = Vec::with_capacity(shares.len());
    let mut rema: Vec<(u64, usize)> = Vec::with_capacity(shares.len());
    let mut assigned = 0usize;
    for (i, &s) in shares.iter().enumerate() {
        let exact = s as u128 * total as u128;
        let f = (exact / max as u128) as usize;
        let r = (exact % max as u128) as u64;
        floors.push(f);
        assigned += f;
        rema.push((r, i));
    }
    // Distribute the leftover cells to the largest remainders.
    let mut leftover = total.saturating_sub(assigned);
    rema.sort_by(|a, b| b.0.cmp(&a.0));
    let mut idx = 0;
    while leftover > 0 && !rema.is_empty() {
        floors[rema[idx % rema.len()].1] += 1;
        leftover -= 1;
        idx += 1;
    }
    floors
}

pub fn draw(frame: &mut Frame, area: Rect, stats: &ContextStats) {
    let theme = crate::style::theme();
    let c = &theme.colors;

    // Segment order matters: conversation, system, tool-results (spec colors).
    let cats = [
        Category { label: "Conversation", tokens: stats.conversation_tokens, color: c.secondary },
        Category { label: "System prompt", tokens: stats.system_tokens, color: c.primary },
        Category { label: "Tool results", tokens: stats.tool_result_tokens, color: c.warning },
    ];

    // title-gap(1) bar(1) gap(1) 3 rows(3) sep(1) TOTAL(1) gap(1) footer(1) = 10.
    let content_h: u16 = 11;
    let w = DIALOG_W.min(area.width);
    let h = (content_h + 2).min(area.height);
    let x = area.x + area.width.saturating_sub(w) / 2;
    let y = area.y + area.height.saturating_sub(h) / 2;
    let rect = Rect::new(x, y, w, h);

    put(frame, Clear, rect);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(c.primary))
        .title(Line::from(vec![
            Span::styled(" OSA ", Style::default().fg(c.primary).add_modifier(Modifier::BOLD)),
            Span::styled("\u{00b7} context ", Style::default().fg(c.muted)),
        ]))
        .style(Style::default().bg(c.dialog_bg));
    put(frame, block, rect);

    let inner = Rect::new(
        rect.x + 2,
        rect.y + 1,
        rect.width.saturating_sub(4),
        rect.height.saturating_sub(2),
    );
    if inner.width < 12 || inner.height < 4 {
        return; // too small to render meaningfully; border already drawn.
    }
    let iw = inner.width;
    let mut cy = inner.y;

    // ── Segmented composition bar ──────────────────────────────────────────
    let track = iw as usize;
    let widths = segment_widths(&cats, stats.max_tokens, track);
    let mut bar: Vec<Span> = Vec::with_capacity(cats.len() + 1);
    for (i, cat) in cats.iter().enumerate() {
        let ww = widths.get(i).copied().unwrap_or(0);
        if ww > 0 {
            bar.push(Span::styled("\u{2588}".repeat(ww), Style::default().fg(cat.color)));
        }
    }
    // Trailing free space (last width entry) drawn dim.
    if let Some(&free) = widths.last() {
        if free > 0 {
            bar.push(Span::styled("\u{2591}".repeat(free), Style::default().fg(c.dim)));
        }
    }
    put(frame, Paragraph::new(Line::from(bar)), Rect::new(inner.x, cy, iw, 1));
    cy += 2;

    // ── Per-category rows: dot + label (left), "NN,NNN (PP%)" (right) ──────
    // Reserve the right column for the value; label truncates into the rest.
    let val_w = 18usize.min(iw as usize);
    let label_w = (iw as usize).saturating_sub(val_w);
    for cat in &cats {
        if cy >= inner.y + inner.height {
            break;
        }
        let pct = pct_of(cat.tokens, stats.max_tokens);
        // Left: colored dot + label.
        let left = truncate_chars(cat.label, label_w.saturating_sub(2));
        put(frame, Paragraph::new(Line::from(vec![
            Span::styled("\u{25CF} ", Style::default().fg(cat.color)),
            Span::styled(left, Style::default().fg(c.muted)),
        ])), Rect::new(inner.x, cy, label_w as u16, 1));
        // Right: right-aligned value in bright + dim percent.
        put(frame, Paragraph::new(Line::from(vec![
            Span::styled(
                group_thousands(cat.tokens),
                Style::default().fg(cat.color).add_modifier(Modifier::BOLD),
            ),
            Span::styled(format!(" ({pct}%)"), Style::default().fg(c.dim)),
        ])).alignment(Alignment::Right),
        Rect::new(inner.x + label_w as u16, cy, val_w as u16, 1));
        cy += 1;
    }

    // ── Divider + TOTAL row ────────────────────────────────────────────────
    if cy < inner.y + inner.height {
        put(frame, Paragraph::new(Line::from(Span::styled(
            "\u{2500}".repeat(iw as usize),
            Style::default().fg(c.border),
        ))), Rect::new(inner.x, cy, iw, 1));
        cy += 1;
    }
    if cy < inner.y + inner.height {
        let total_pct = pct_of(stats.used_tokens, stats.max_tokens);
        let total_color = if total_pct >= 90 {
            c.error
        } else if total_pct >= 75 {
            c.warning
        } else {
            c.success
        };
        put(frame, Paragraph::new(Line::from(vec![
            Span::styled("\u{25CF} ", Style::default().fg(total_color)),
            Span::styled("Total used", Style::default().fg(c.muted).add_modifier(Modifier::BOLD)),
        ])), Rect::new(inner.x, cy, label_w as u16, 1));
        put(frame, Paragraph::new(Line::from(vec![
            Span::styled(
                group_thousands(stats.used_tokens),
                Style::default().fg(total_color).add_modifier(Modifier::BOLD),
            ),
            Span::styled(
                format!(" / {}", group_thousands(stats.max_tokens)),
                Style::default().fg(c.dim),
            ),
            Span::styled(format!("  {total_pct}%"), Style::default().fg(total_color)),
        ])).alignment(Alignment::Right),
        Rect::new(inner.x + label_w as u16, cy, val_w as u16, 1));
        cy += 2;
    }

    // ── Footer hint ────────────────────────────────────────────────────────
    if cy < inner.y + inner.height {
        put(frame, Paragraph::new(Line::from(vec![
            Span::styled("esc", Style::default().fg(c.muted).add_modifier(Modifier::BOLD)),
            Span::styled(" close", Style::default().fg(c.dim)),
        ])), Rect::new(inner.x, cy, iw, 1));
    }
}

#[cfg(test)]
mod context_breakdown_tests {
    use super::*;
    use ratatui::{backend::TestBackend, Terminal};

    fn stats() -> ContextStats {
        ContextStats {
            system_tokens: 8_400,
            conversation_tokens: 61_200,
            tool_result_tokens: 24_600,
            max_tokens: 200_000,
            used_tokens: 94_200,
        }
    }

    #[test]
    fn draws_at_all_sizes_without_panic() {
        let cases = [
            stats(),
            // max == 0 must not divide-by-zero anywhere.
            ContextStats { system_tokens: 10, conversation_tokens: 20, tool_result_tokens: 5, max_tokens: 0, used_tokens: 35 },
            // Over-full window (used > max): percentages clamp, bar stays in-track.
            ContextStats { system_tokens: 120_000, conversation_tokens: 120_000, tool_result_tokens: 90_000, max_tokens: 200_000, used_tokens: 330_000 },
            // Empty session.
            ContextStats { system_tokens: 0, conversation_tokens: 0, tool_result_tokens: 0, max_tokens: 200_000, used_tokens: 0 },
        ];
        for s in &cases {
            for (w, h) in [(1u16, 1u16), (10, 4), (40, 12), (70, 20), (200, 60)] {
                let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
                term.draw(|f| draw(f, f.area(), s)).unwrap();
            }
        }
    }

    #[test]
    fn percent_and_grouping_are_correct_and_safe() {
        assert_eq!(pct_of(0, 0), 0);
        assert_eq!(pct_of(100, 0), 0); // div0 guard
        assert_eq!(pct_of(50_000, 200_000), 25);
        assert_eq!(pct_of(300_000, 200_000), 100); // clamp over-max
        assert_eq!(group_thousands(0), "0");
        assert_eq!(group_thousands(999), "999");
        assert_eq!(group_thousands(1_000), "1,000");
        assert_eq!(group_thousands(94_200), "94,200");
        assert_eq!(group_thousands(1_234_567), "1,234,567");
    }

    #[test]
    fn segment_widths_sum_to_track_and_leave_free_space() {
        let cats = [
            Category { label: "a", tokens: 60_000, color: Color::Red },
            Category { label: "b", tokens: 8_000, color: Color::Green },
            Category { label: "c", tokens: 24_000, color: Color::Blue },
        ];
        let track = 50usize;
        let widths = segment_widths(&cats, 200_000, track);
        assert_eq!(widths.len(), 4); // 3 categories + free space
        assert_eq!(widths.iter().sum::<usize>(), track); // exact partition
        assert!(*widths.last().unwrap() > 0); // 92k of 200k used -> free remains

        // max == 0: everything is free space, still sums to track.
        let zero = segment_widths(&cats, 0, track);
        assert_eq!(zero.iter().sum::<usize>(), track);
        assert_eq!(*zero.last().unwrap(), track);
    }
}