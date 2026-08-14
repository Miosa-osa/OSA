use ratatui::prelude::*;
use ratatui::widgets::{Clear, Paragraph};

use crate::style;

/// Block-letter ASCII art logo (same as welcome)
const LOGO_ART: &[&str] = &[
    " \u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2557} \u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2557} \u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2557} ",
    "\u{2588}\u{2588}\u{2554}\u{2550}\u{2550}\u{2550}\u{2588}\u{2588}\u{2557}\u{2588}\u{2588}\u{2554}\u{2550}\u{2550}\u{2550}\u{2550}\u{255d}\u{2588}\u{2588}\u{2554}\u{2550}\u{2550}\u{2588}\u{2588}\u{2557}",
    "\u{2588}\u{2588}\u{2551}   \u{2588}\u{2588}\u{2551}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2557}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2551}",
    "\u{2588}\u{2588}\u{2551}   \u{2588}\u{2588}\u{2551}\u{255a}\u{2550}\u{2550}\u{2550}\u{2550}\u{2588}\u{2588}\u{2551}\u{2588}\u{2588}\u{2554}\u{2550}\u{2550}\u{2588}\u{2588}\u{2551}",
    "\u{255a}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2554}\u{255d}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2551}\u{2588}\u{2588}\u{2551}  \u{2588}\u{2588}\u{2551}",
    " \u{255a}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{255d} \u{255a}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{255d}\u{255a}\u{2550}\u{255d}  \u{255a}\u{2550}\u{255d}",
    "        a g e n t  \u{25c8}",
];

/// The one key that is guaranteed to work on this screen, printed on it.
///
/// The splash used to print nothing but a spinner while `App::handle_key` had
/// no `Connecting` arm at all, so every key — Ctrl+C included — was discarded.
/// Now that quit works, the screen has to say so: a user waiting out a backend
/// that will not start has no other way to learn there is a way out.
pub const QUIT_HINT: &str = "Ctrl+C to quit";

/// Shown once anything has been typed into the wait. The characters are held in
/// the real composer and arrive with it; what must NOT be implied is that
/// Enter will do anything yet, because it deliberately does not.
pub const DRAFT_HINT: &str = "saved for the composer \u{2014} not sent until connected";

/// Longest draft echoed back before it is elided. The splash is a status
/// screen, not an editor; it only has to prove the keystrokes were kept.
const DRAFT_PREVIEW_COLS: usize = 60;

/// One line of draft preview, elided from the FRONT so the most recently typed
/// characters — the ones a user is watching for — always stay on screen.
fn draft_preview(draft: &str) -> String {
    // `\r` is dropped rather than mapped to a space so a CRLF pair collapses to
    // ONE separator instead of two.
    let single: String = draft
        .chars()
        .filter(|c| *c != '\r')
        .map(|c| if c == '\n' { ' ' } else { c })
        .collect();
    let n = single.chars().count();
    if n <= DRAFT_PREVIEW_COLS {
        return single;
    }
    let tail: String = single
        .chars()
        .skip(n - DRAFT_PREVIEW_COLS.saturating_sub(1))
        .collect();
    format!("\u{2026}{tail}")
}

pub fn draw_connecting(frame: &mut Frame, area: Rect, draft: &str) {
    let theme = style::theme();

    // Fill background
    frame.render_widget(Clear, area);

    let preview = draft_preview(draft);
    // logo + blank + spinner + blank + quit hint, plus 2 rows when a draft is
    // being echoed (the draft itself and the "saved for the composer" note).
    let draft_rows = if preview.is_empty() { 0 } else { 3 };
    let content_height = (LOGO_ART.len() + 4 + draft_rows) as u16;
    let y_offset = area.height.saturating_sub(content_height) / 2;

    let mut lines: Vec<Line<'static>> = Vec::new();

    // Block-letter logo with gradient
    for art_line in LOGO_ART {
        lines.push(style::gradient::theme_gradient(art_line, true));
    }

    lines.push(Line::from(""));

    // Spinner + status
    let dots = match (std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        / 400)
        % 4
    {
        0 => "   ",
        1 => ".  ",
        2 => ".. ",
        _ => "...",
    };

    lines.push(Line::from(vec![
        Span::styled("\u{25ce} ", Style::default().fg(theme.colors.primary)),
        Span::styled("Connecting", Style::default().fg(theme.colors.muted)),
        Span::styled(dots, Style::default().fg(theme.colors.dim)),
    ]));

    // Anything typed into the wait is buffered into the composer. Echo it, so
    // "my keystrokes disappeared" cannot be the user's reading of the screen.
    //
    // Deliberately NOT prefixed with the composer's `❯` glyph: this is a status
    // echo on a splash, not a live composer, and dressing it as one would claim
    // an Enter that is not accepted yet.
    if !preview.is_empty() {
        lines.push(Line::from(""));
        lines.push(Line::from(Span::styled(
            preview,
            Style::default().fg(theme.colors.secondary),
        )));
        lines.push(Line::from(Span::styled(
            DRAFT_HINT,
            Style::default().fg(theme.colors.dim),
        )));
    }

    // The escape hatch, always printed. See `QUIT_HINT`.
    lines.push(Line::from(""));
    lines.push(Line::from(Span::styled(
        QUIT_HINT,
        Style::default().fg(theme.colors.dim),
    )));

    let content_area = Rect::new(
        area.x,
        area.y + y_offset,
        area.width,
        content_height.min(area.height),
    );

    let text = Text::from(lines);
    let paragraph = Paragraph::new(text).alignment(Alignment::Center);
    frame.render_widget(paragraph, content_area);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_draft_means_no_echo() {
        assert_eq!(draft_preview(""), "");
    }

    #[test]
    fn a_short_draft_is_echoed_verbatim() {
        assert_eq!(draft_preview("fix the parser"), "fix the parser");
    }

    /// Elided from the FRONT: the characters a user is watching for are the
    /// ones they just typed, so a preview that keeps the head and drops the
    /// tail would look exactly like input having stopped being accepted.
    #[test]
    fn a_long_draft_keeps_its_tail() {
        let draft = "x".repeat(200) + "THE-END";
        let p = draft_preview(&draft);
        assert!(p.ends_with("THE-END"), "got {p:?}");
        assert!(p.starts_with('\u{2026}'), "got {p:?}");
        assert_eq!(p.chars().count(), DRAFT_PREVIEW_COLS);
    }

    /// A newline in the buffered draft must not become a second line on a
    /// splash whose height is computed from a fixed row count.
    #[test]
    fn newlines_are_flattened() {
        assert_eq!(draft_preview("a\nb\r\nc"), "a b c");
    }

    /// The preview must not wear the composer's prompt glyph: the PTY harness
    /// counts `^\s*❯` to decide the app has booted, and more importantly a user
    /// reading a composer would expect Enter to submit, which it does not yet.
    #[test]
    fn the_preview_is_not_dressed_as_a_composer() {
        assert!(!draft_preview("hello").contains('\u{276f}'));
        assert!(!DRAFT_HINT.contains('\u{276f}'));
    }

    /// The escape hatch has to be nameable by the test that proves it works.
    #[test]
    fn the_quit_hint_names_the_key_that_quits() {
        assert!(QUIT_HINT.contains("Ctrl+C"));
    }
}
