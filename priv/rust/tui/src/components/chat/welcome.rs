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
    fast_mode: bool,
) {
    let theme = style::theme();

    let cwd = std::env::current_dir()
        .map(|p| {
            let home = std::env::var("HOME").unwrap_or_default();
            let s = p.display().to_string();
            if !home.is_empty() && s.starts_with(&home) {
                format!("~{}", &s[home.len()..])
            } else if s.len() > 50 {
                format!("...{}", &s[s.len() - 47..])
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

    let box_width: usize = 52;
    let mut lines: Vec<Line<'static>> = Vec::new();

    // Helper: pad content to box_width and wrap with left+right border
    let border_color = theme.colors.primary;
    let left = "\u{2502} "; // │ + space
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
        Style::default()
            .fg(Color::White)
            .add_modifier(Modifier::BOLD),
    ));

    // Empty line
    lines.push(make_bordered("", Style::default()));

    // Logo lines (centered, with gradient)
    for art_line in LOGO {
        let char_count = art_line.chars().count();
        let pad = (box_width.saturating_sub(char_count)) / 2;
        let inner = box_width;
        let right_pad = inner.saturating_sub(pad + char_count);

        let mut spans: Vec<Span<'static>> = Vec::new();
        spans.push(Span::styled(
            left.to_string(),
            Style::default().fg(border_color),
        ));
        spans.push(Span::raw(" ".repeat(pad)));

        // Gradient spans for the logo
        let gradient_line = style::gradient::theme_gradient(art_line, true);
        for span in gradient_line.spans {
            spans.push(span);
        }

        spans.push(Span::raw(" ".repeat(right_pad)));
        spans.push(Span::styled(
            right.to_string(),
            Style::default().fg(border_color),
        ));
        lines.push(Line::from(spans));
    }

    // Empty line
    lines.push(make_bordered("", Style::default()));

    // Model info (centered, faint)
    let fast_label = if fast_mode { "  \u{00b7}  FAST" } else { "" };
    let model_line = format!(
        "{} / {}  \u{00b7}  {} tools",
        prov_display, model_display, tool_count
    );
    let model_line = format!("{}{}", model_line, fast_label);
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

    // Tips (below the box)
    lines.push(Line::from(Span::styled(
        "  Ask, code, schedule, delegate  \u{00b7}  /fast turbo  \u{00b7}  Ctrl+K palette",
        theme.welcome_tip(),
    )));

    // Render at the TOP (not centered)
    let content_height = lines.len() as u16;
    let content_area = Rect::new(area.x, area.y, area.width, content_height.min(area.height));

    let text = Text::from(lines);
    let paragraph = Paragraph::new(text);
    frame.render_widget(paragraph, content_area);
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
            let name = trimmed.trim_start_matches("- **Name:**").trim();
            if !name.is_empty() {
                return Some(name.to_string());
            }
        }
    }
    None
}
