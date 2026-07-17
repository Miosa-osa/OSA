use ratatui::prelude::*;
use ratatui::widgets::Paragraph;

use crate::style;

/// ANSI Shadow figlet "OSA" logo (matches connecting screen)
const LOGO: &[&str] = &[
    " \u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2557} \u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2557} \u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2557} ",
    "\u{2588}\u{2588}\u{2554}\u{2550}\u{2550}\u{2550}\u{2588}\u{2588}\u{2557}\u{2588}\u{2588}\u{2554}\u{2550}\u{2550}\u{2550}\u{2550}\u{255d}\u{2588}\u{2588}\u{2554}\u{2550}\u{2550}\u{2588}\u{2588}\u{2557}",
    "\u{2588}\u{2588}\u{2551}   \u{2588}\u{2588}\u{2551}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2557}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2551}",
    "\u{2588}\u{2588}\u{2551}   \u{2588}\u{2588}\u{2551}\u{255a}\u{2550}\u{2550}\u{2550}\u{2550}\u{2588}\u{2588}\u{2551}\u{2588}\u{2588}\u{2554}\u{2550}\u{2550}\u{2588}\u{2588}\u{2551}",
    "\u{255a}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2554}\u{255d}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2551}\u{2588}\u{2588}\u{2551}  \u{2588}\u{2588}\u{2551}",
    " \u{255a}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{255d} \u{255a}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{255d}\u{255a}\u{2550}\u{255d}  \u{255a}\u{2550}\u{255d}",
];

pub fn draw_welcome_with_tools(
    frame: &mut Frame,
    area: Rect,
    tool_count: usize,
    provider: Option<&str>,
    model: Option<&str>,
) {
    let lines = welcome_lines(area.width, tool_count, provider, model);
    let content_height = lines.len() as u16;
    let content_area = Rect::new(area.x, area.y, area.width, content_height.min(area.height));
    frame.render_widget(Paragraph::new(Text::from(lines)), content_area);
}

/// Build the "Welcome" banner (bordered box + ASCII OSA logo + model/cwd + tips)
/// as styled lines. Rendered live on the connecting screen AND pushed into the
/// terminal scrollback as the startup banner (Claude-Code style).
pub fn welcome_lines(
    width: u16,
    tool_count: usize,
    provider: Option<&str>,
    model: Option<&str>,
) -> Vec<Line<'static>> {
    let theme = style::theme();

    let cwd = std::env::current_dir()
        .map(|p| {
            let home = std::env::var("HOME").unwrap_or_default();
            let s = p.display().to_string();
            if !home.is_empty() && s.starts_with(&home) {
                format!("~{}", &s[home.len()..])
            } else if s.len() > 50 {
                format!("...{}", crate::util::truncate_str_start(&s, 47))
            } else {
                s
            }
        })
        .unwrap_or_default();

    // Try to read user's name from ~/.osa/USER.md
    let user_name = read_user_name();
    let greeting = if let Some(ref name) = user_name {
        format!("Welcome back, {}!", name)
    } else {
        "Welcome!".to_string()
    };

    let prov_display = provider.unwrap_or("not configured");
    let model_display = model.unwrap_or("none");

    // Responsive: fit the box to the pane instead of a fixed 52 cols, so narrow
    // panes (e.g. many tiled terminals) reflow cleanly instead of clipping.
    // Reserve 4 cols for the "│ " / " │" borders. Floor keeps it readable; the
    // full ASCII logo only fits at ~44+, so it's gated below.
    // Widen the box enough to hold the full ASCII logo whenever the terminal
    // allows it (the compact "O S A" fallback is only for genuinely narrow panes).
    let logo_w: usize = LOGO.iter().map(|l| l.chars().count()).max().unwrap_or(41);
    let box_width: usize = (width as usize).saturating_sub(4).clamp(20, logo_w.max(52));
    let show_logo = box_width >= logo_w;
    let mut lines: Vec<Line<'static>> = Vec::new();

    // Helper: pad content to box_width and wrap with left+right border
    let border_color = theme.colors.primary;
    let left = "\u{2502} ";  // │ + space
    let right = " \u{2502}"; // space + │

    let make_bordered = |content: &str, style: Style| -> Line<'static> {
        // Inner width = box_width - 2 (for the padding spaces in left/right)
        let inner = box_width;
        let visible_len = content.chars().count();
        let padded = if visible_len < inner {
            format!("{}{}", content, " ".repeat(inner - visible_len))
        } else {
            content.chars().take(inner).collect()
        };
        Line::from(vec![
            Span::styled(left.to_string(), Style::default().fg(border_color)),
            Span::styled(padded, style),
            Span::styled(right.to_string(), Style::default().fg(border_color)),
        ])
    };

    // Top border  ╭──────╮
    lines.push(Line::from(Span::styled(
        format!("\u{256d}{}\u{256e}", "\u{2500}".repeat(box_width + 2)),
        Style::default().fg(border_color),
    )));

    // Empty line
    lines.push(make_bordered("", Style::default()));

    // Greeting (centered, bold white)
    let greeting_pad = (box_width.saturating_sub(greeting.len())) / 2;
    let greeting_centered = format!("{}{}", " ".repeat(greeting_pad), greeting);
    lines.push(make_bordered(
        &greeting_centered,
        Style::default().fg(Color::White).add_modifier(Modifier::BOLD),
    ));

    // Empty line
    lines.push(make_bordered("", Style::default()));

    // Logo lines (centered, with gradient) — only when the box is wide enough
    // to hold the full ASCII art. On narrow panes, show a compact "O S A" instead
    // so nothing overflows the border.
    if show_logo {
        for art_line in LOGO {
            let char_count = art_line.chars().count();
            let pad = (box_width.saturating_sub(char_count)) / 2;
            let inner = box_width;
            let right_pad = inner.saturating_sub(pad + char_count);

            let mut spans: Vec<Span<'static>> = Vec::new();
            spans.push(Span::styled(left.to_string(), Style::default().fg(border_color)));
            spans.push(Span::raw(" ".repeat(pad)));

            // Gradient spans for the logo
            let gradient_line = style::gradient::theme_gradient(art_line, true);
            for span in gradient_line.spans {
                spans.push(span);
            }

            spans.push(Span::raw(" ".repeat(right_pad)));
            spans.push(Span::styled(right.to_string(), Style::default().fg(border_color)));
            lines.push(Line::from(spans));
        }
    } else {
        let compact = "O S A";
        let pad = (box_width.saturating_sub(compact.len())) / 2;
        let centered = format!("{}{}", " ".repeat(pad), compact);
        lines.push(make_bordered(
            &centered,
            Style::default().fg(border_color).add_modifier(Modifier::BOLD),
        ));
    }

    // Empty line
    lines.push(make_bordered("", Style::default()));

    // Model info (centered, faint)
    let model_line = format!(
        "{} / {}  \u{00b7}  {} tools",
        prov_display, model_display, tool_count
    );
    let model_pad = (box_width.saturating_sub(model_line.len())) / 2;
    let model_centered = format!("{}{}", " ".repeat(model_pad), model_line);
    lines.push(make_bordered(&model_centered, theme.faint()));

    // Working directory (centered, themed)
    let cwd_pad = (box_width.saturating_sub(cwd.len())) / 2;
    let cwd_centered = format!("{}{}", " ".repeat(cwd_pad), cwd);
    lines.push(make_bordered(&cwd_centered, theme.welcome_cwd()));

    // Empty line
    lines.push(make_bordered("", Style::default()));

    // Bottom border  ╰──────╯
    lines.push(Line::from(Span::styled(
        format!("\u{2570}{}\u{256f}", "\u{2500}".repeat(box_width + 2)),
        Style::default().fg(border_color),
    )));

    // Blank line
    lines.push(Line::from(""));

    // Tips (below the box) — pick the longest variant that fits the pane so it
    // never clips mid-word on narrow terminals.
    let w = width as usize;
    let tip = if w >= 70 {
        "  Ask, code, schedule, delegate  \u{00b7}  /help commands  \u{00b7}  Ctrl+K palette"
    } else if w >= 40 {
        "  /help commands  \u{00b7}  Ctrl+K palette"
    } else {
        "  /help  \u{00b7}  Ctrl+K"
    };
    lines.push(Line::from(Span::styled(tip, theme.welcome_tip())));

    // Resume affordance — OSA verbs, so picking up prior work is discoverable.
    let resume_hint = if w >= 70 {
        "  Pick up earlier work  \u{00b7}  /continue this folder  \u{00b7}  /resume to browse"
    } else if w >= 40 {
        "  /continue  \u{00b7}  /resume earlier work"
    } else {
        "  /resume"
    };
    lines.push(Line::from(Span::styled(resume_hint, theme.faint())));

    lines
}

/// Read user name from ~/.osa/USER.md
fn read_user_name() -> Option<String> {
    let home = std::env::var("HOME").ok()?;
    let path = format!("{}/.osa/USER.md", home);
    let content = std::fs::read_to_string(&path).ok()?;

    // Look for "- **Name:** Roberto" pattern
    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("- **Name:**") {
            let name = trimmed
                .trim_start_matches("- **Name:**")
                .trim();
            if !name.is_empty() {
                return Some(name.to_string());
            }
        }
    }
    None
}

#[cfg(test)]
mod welcome_tests {
    use super::*;
    use ratatui::backend::TestBackend;
    use ratatui::Terminal;

    #[test]
    fn welcome_lines_various_widths_never_panic() {
        for w in [1u16, 8, 20, 40, 52, 80, 200] {
            let _ = welcome_lines(w, 12, Some("openai"), Some("gpt-4o"));
            let _ = welcome_lines(w, 0, None, None);
        }
    }

    #[test]
    fn draw_welcome_never_panics() {
        for &(w, h) in &[(1u16, 1u16), (10, 3), (52, 20), (200, 60)] {
            let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
            term.draw(|f| {
                let area = f.area();
                draw_welcome_with_tools(f, area, 12, Some("openai"), Some("gpt-4o"));
            })
            .unwrap();
        }
    }
}
