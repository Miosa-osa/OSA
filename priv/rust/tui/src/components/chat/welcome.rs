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

#[derive(Debug, Clone, Default)]
pub struct StartupBriefing {
    pub folder: String,
    pub project_type: Option<String>,
    pub files: Vec<String>,
    pub git: Option<String>,
    pub memory_hints: Vec<String>,
    pub session_hints: Vec<String>,
    pub first_actions: Vec<String>,
}

pub fn draw_welcome_with_tools(
    frame: &mut Frame,
    area: Rect,
    tool_count: usize,
    provider: Option<&str>,
    model: Option<&str>,
    fast_mode: bool,
    startup_briefing: Option<&StartupBriefing>,
) {
    let theme = style::theme();

    let cwd = startup_briefing
        .map(|briefing| abbreviate_path(&briefing.folder))
        .unwrap_or_else(|| {
            std::env::current_dir()
                .map(|p| abbreviate_path(&p.display().to_string()))
                .unwrap_or_default()
        });

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

    if let Some(briefing) = startup_briefing {
        push_briefing_lines(&mut lines, briefing, box_width, &make_bordered, &theme);
    }

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

fn push_briefing_lines(
    lines: &mut Vec<Line<'static>>,
    briefing: &StartupBriefing,
    box_width: usize,
    make_bordered: &dyn Fn(&str, Style) -> Line<'static>,
    theme: &crate::style::Theme,
) {
    let label_style = theme.faint();
    let value_style = Style::default().fg(Color::White);
    let hint_style = theme.welcome_tip();

    lines.push(make_bordered("", Style::default()));

    if let Some(project_type) = briefing.project_type.as_deref() {
        push_kv(
            lines,
            "Project",
            project_type,
            box_width,
            make_bordered,
            value_style,
        );
    }

    if !briefing.files.is_empty() {
        let files = briefing.files.join(", ");
        push_kv(
            lines,
            "Files",
            &files,
            box_width,
            make_bordered,
            value_style,
        );
    }

    if let Some(git) = briefing.git.as_deref() {
        push_kv(lines, "Git", git, box_width, make_bordered, value_style);
    }

    let hints: Vec<&str> = briefing
        .memory_hints
        .iter()
        .chain(briefing.session_hints.iter())
        .map(String::as_str)
        .take(2)
        .collect();
    if !hints.is_empty() {
        push_kv(
            lines,
            "Hints",
            &hints.join(" / "),
            box_width,
            make_bordered,
            hint_style,
        );
    }

    if !briefing.first_actions.is_empty() {
        lines.push(make_bordered("", Style::default()));
        lines.push(make_bordered("First actions", label_style));
        for action in briefing.first_actions.iter().take(3) {
            let line = format!("  - {}", action);
            lines.push(make_bordered(&fit(&line, box_width), hint_style));
        }
    }
}

fn push_kv(
    lines: &mut Vec<Line<'static>>,
    label: &str,
    value: &str,
    box_width: usize,
    make_bordered: &dyn Fn(&str, Style) -> Line<'static>,
    style: Style,
) {
    let label = format!("{:<8}", label);
    let value_width = box_width.saturating_sub(label.chars().count() + 2);
    let line = format!("{}  {}", label, fit(value, value_width));
    lines.push(make_bordered(&line, style));
}

fn fit(value: &str, max_width: usize) -> String {
    let count = value.chars().count();
    if count <= max_width {
        return value.to_string();
    }
    if max_width <= 3 {
        return ".".repeat(max_width);
    }
    let keep = max_width - 3;
    format!(
        "{}...",
        value.chars().take(keep).collect::<String>().trim_end()
    )
}

fn abbreviate_path(path: &str) -> String {
    let home = std::env::var("HOME").unwrap_or_default();
    if !home.is_empty() && path.starts_with(&home) {
        format!("~{}", &path[home.len()..])
    } else if path.chars().count() > 50 {
        let tail: String = path
            .chars()
            .rev()
            .take(47)
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect();
        format!("...{}", tail)
    } else {
        path.to_string()
    }
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
