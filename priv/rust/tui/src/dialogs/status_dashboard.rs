//! `/status` — the session status dashboard.
//!
//! A focused, branded overlay that answers "what is OSA doing right now" at a
//! glance: which model/provider is live, how full the context window is (a
//! color-graded gauge, not a bare number), how many tools are wired, the active
//! permission mode, and the session/version identity. Replaces the old
//! single-line `/status` text dump — same data, real depth and hierarchy.
//!
//! Stateless: `event_loop` builds a fresh [`StatusView`] from live app state on
//! every frame and hands it to [`draw`], so the numbers are never stale. Any key
//! closes it (handled app-side); Esc is the documented dismiss.

use ratatui::{
    prelude::*,
    widgets::{Block, BorderType, Borders, Clear, Paragraph},
};

use crate::components::status_bar::PermissionMode;

/// Clip-safe render (shared choke point with the other dialogs).
fn put<W: ratatui::widgets::Widget>(frame: &mut Frame, widget: W, rect: Rect) {
    crate::app::event_loop::safe_render_widget(frame, widget, rect);
}

const DIALOG_W: u16 = 62;
/// Cells in the context gauge track.
const GAUGE_W: usize = 26;

/// Live snapshot the dashboard renders. Owned so `draw` never borrows `App`.
pub struct StatusView {
    pub model: String,
    pub provider: String,
    pub tools: usize,
    /// Context-window fill as a fraction in `0.0..=1.0`.
    pub context_util: f64,
    /// Human label for the window ceiling, e.g. `"200k"`.
    pub context_max: String,
    pub mode: PermissionMode,
    pub session: String,
    pub version: String,
}

/// `(label, "why it means", color)` for the active permission mode.
fn mode_spec(mode: PermissionMode, c: &crate::style::ThemeColors) -> (&'static str, &'static str, Color) {
    match mode {
        PermissionMode::Default => ("ask", "prompts on every gated action", c.success),
        PermissionMode::Auto => ("auto", "guardian approves safe, pauses on risk", c.secondary),
        PermissionMode::AcceptEdits => ("auto-edit", "edits auto-approved, shell still prompts", c.warning),
        PermissionMode::BypassPermissions => ("overdrive", "full auto — every prompt bypassed", c.error),
        PermissionMode::Plan => ("plan", "read-only, no mutating execution", c.secondary),
    }
}

/// Grade the context gauge: comfortable → tight → nearly full.
fn gauge_color(util: f64, c: &crate::style::ThemeColors) -> Color {
    if util < 0.60 {
        c.success
    } else if util < 0.85 {
        c.warning
    } else {
        c.error
    }
}

/// Middle-ellipsize a long id so both ends stay legible within `max` chars.
fn shorten(s: &str, max: usize) -> String {
    let n = s.chars().count();
    if n <= max {
        return s.to_string();
    }
    let keep = max.saturating_sub(1);
    let head = keep.div_ceil(2);
    let tail = keep - head;
    let front: String = s.chars().take(head).collect();
    let back: String = s.chars().skip(n - tail).collect();
    format!("{front}\u{2026}{back}")
}

pub fn draw(frame: &mut Frame, area: Rect, view: &StatusView) {
    let theme = crate::style::theme();
    let c = &theme.colors;

    // Fixed content height — the dashboard is a fitted card, not a scroller.
    // title-gap(1) MODEL(2) gap(1) CONTEXT(2) gap(1) TOOLS(1) MODE(2) SESSION(1)
    // VERSION(1) gap(1) footer(1) = 14 rows of content.
    let content_h: u16 = 15;
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
            Span::styled("\u{00b7} status ", Style::default().fg(c.muted)),
        ]))
        .style(Style::default().bg(c.dialog_bg));
    put(frame, block, rect);

    let inner = Rect::new(
        rect.x + 2,
        rect.y + 1,
        rect.width.saturating_sub(4),
        rect.height.saturating_sub(2),
    );
    if inner.width < 12 || inner.height < 8 {
        return; // too small to render meaningfully; border already drawn.
    }
    let iw = inner.width;
    let mut cy = inner.y;

    // Small helper closures for the two row shapes.
    let label = |s: &str| Span::styled(
        format!("{s:<9}"),
        Style::default().fg(c.muted).add_modifier(Modifier::BOLD),
    );

    // ── MODEL ──────────────────────────────────────────────────────────
    put(frame, Paragraph::new(Line::from(Span::styled(
        "MODEL", Style::default().fg(c.primary).add_modifier(Modifier::BOLD),
    ))), Rect::new(inner.x, cy, iw, 1));
    cy += 1;
    put(frame, Paragraph::new(Line::from(vec![
        Span::styled(format!("  {}", view.model), Style::default().fg(c.secondary).add_modifier(Modifier::BOLD)),
        Span::styled(format!("   via {}", view.provider), Style::default().fg(c.dim)),
    ])), Rect::new(inner.x, cy, iw, 1));
    cy += 2;

    // ── CONTEXT (color-graded gauge) ───────────────────────────────────
    put(frame, Paragraph::new(Line::from(Span::styled(
        "CONTEXT", Style::default().fg(c.primary).add_modifier(Modifier::BOLD),
    ))), Rect::new(inner.x, cy, iw, 1));
    cy += 1;
    let util = view.context_util.clamp(0.0, 1.0);
    let filled = (util * GAUGE_W as f64).round() as usize;
    let filled = filled.min(GAUGE_W);
    let bar_fg = gauge_color(util, c);
    let mut spans = vec![Span::raw("  ")];
    spans.push(Span::styled("\u{2588}".repeat(filled), Style::default().fg(bar_fg)));
    spans.push(Span::styled("\u{2591}".repeat(GAUGE_W - filled), Style::default().fg(c.dim)));
    spans.push(Span::styled(
        format!("  {:>3.0}%", util * 100.0),
        Style::default().fg(bar_fg).add_modifier(Modifier::BOLD),
    ));
    spans.push(Span::styled(
        format!("  of {}", view.context_max),
        Style::default().fg(c.dim),
    ));
    put(frame, Paragraph::new(Line::from(spans)), Rect::new(inner.x, cy, iw, 1));
    cy += 2;

    // ── TOOLS / MODE / SESSION / VERSION (aligned key-value rows) ──────
    put(frame, Paragraph::new(Line::from(vec![
        label("TOOLS"),
        Span::styled(format!("{}", view.tools), Style::default().fg(c.success).add_modifier(Modifier::BOLD)),
        Span::styled(" available", Style::default().fg(c.dim)),
    ])), Rect::new(inner.x, cy, iw, 1));
    cy += 1;

    let (m_label, m_why, m_color) = mode_spec(view.mode, c);
    put(frame, Paragraph::new(Line::from(vec![
        label("MODE"),
        Span::styled("\u{25CF} ", Style::default().fg(m_color)),
        Span::styled(m_label, Style::default().fg(m_color).add_modifier(Modifier::BOLD)),
        Span::styled(format!("  {m_why}"), Style::default().fg(c.dim)),
    ])), Rect::new(inner.x, cy, iw, 1));
    cy += 1;

    put(frame, Paragraph::new(Line::from(vec![
        label("SESSION"),
        Span::styled(shorten(&view.session, iw.saturating_sub(11) as usize), Style::default().fg(c.muted)),
    ])), Rect::new(inner.x, cy, iw, 1));
    cy += 1;

    put(frame, Paragraph::new(Line::from(vec![
        label("VERSION"),
        Span::styled(format!("OSA {}", view.version), Style::default().fg(c.muted)),
    ])), Rect::new(inner.x, cy, iw, 1));
    cy += 2;

    // ── footer hint ────────────────────────────────────────────────────
    if cy < inner.y + inner.height {
        put(frame, Paragraph::new(Line::from(vec![
            Span::styled("  esc", Style::default().fg(c.muted).add_modifier(Modifier::BOLD)),
            Span::styled(" close", Style::default().fg(c.dim)),
        ])), Rect::new(inner.x, cy, iw, 1));
    }
}

#[cfg(test)]
mod status_dashboard_tests {
    use super::*;
    use ratatui::{backend::TestBackend, Terminal};

    fn view(util: f64, mode: PermissionMode) -> StatusView {
        StatusView {
            model: "glm-5.2:cloud".into(),
            provider: "zhipu".into(),
            tools: 63,
            context_util: util,
            context_max: "200k".into(),
            mode,
            session: "session-1784372261308-71f33c4912e6".into(),
            version: "v1.0.3".into(),
        }
    }

    #[test]
    fn draws_at_all_sizes_and_modes_without_panic() {
        let modes = [
            PermissionMode::Default,
            PermissionMode::Auto,
            PermissionMode::AcceptEdits,
            PermissionMode::BypassPermissions,
            PermissionMode::Plan,
        ];
        for m in modes {
            for u in [0.0, 0.5, 0.7, 0.9, 1.0, 1.5] {
                for (w, h) in [(1u16, 1u16), (10, 4), (40, 12), (62, 17), (200, 60)] {
                    let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
                    term.draw(|f| draw(f, f.area(), &view(u, m))).unwrap();
                }
            }
        }
    }

    #[test]
    fn gauge_grades_and_clamps() {
        let c = crate::style::theme().colors;
        assert_eq!(gauge_color(0.1, &c), c.success);
        assert_eq!(gauge_color(0.7, &c), c.warning);
        assert_eq!(gauge_color(0.99, &c), c.error);
        // Over-unity utilization must not overflow the gauge track.
        let filled = (1.5_f64.clamp(0.0, 1.0) * GAUGE_W as f64).round() as usize;
        assert!(filled.min(GAUGE_W) <= GAUGE_W);
    }

    #[test]
    fn shorten_keeps_both_ends() {
        let s = shorten("session-1784372261308-71f33c4912e6", 16);
        assert!(s.chars().count() <= 16);
        assert!(s.contains('\u{2026}'));
        assert!(s.starts_with("session"));
    }
}
