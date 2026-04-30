use ratatui::style::{Color, Style};
use ratatui::text::{Line, Span};
use std::sync::OnceLock;
use syntect::easy::HighlightLines;
use syntect::highlighting::ThemeSet;
use syntect::parsing::SyntaxSet;
use syntect::util::LinesWithEndings;

static SYNTAX_SET: OnceLock<SyntaxSet> = OnceLock::new();
static THEME_SET: OnceLock<ThemeSet> = OnceLock::new();

fn syntax_set() -> &'static SyntaxSet {
    SYNTAX_SET.get_or_init(SyntaxSet::load_defaults_newlines)
}

fn theme_set() -> &'static ThemeSet {
    THEME_SET.get_or_init(ThemeSet::load_defaults)
}

/// Convert a syntect Color to a ratatui Color::Rgb.
fn syntect_color_to_ratatui(c: syntect::highlighting::Color) -> Color {
    Color::Rgb(c.r, c.g, c.b)
}

/// Highlight a code block with syntax coloring.
/// Returns `Vec<Line<'static>>`. Falls back to plain dim rendering when the
/// language is unknown or syntect cannot tokenize the input.
pub fn highlight(code: &str, language: &str) -> Vec<Line<'static>> {
    let ss = syntax_set();
    let ts = theme_set();

    // Resolve syntect theme — prefer base16-eighties.dark, fall back to the
    // first available theme so we never panic on a stripped theme set.
    let syntect_theme_name = if ts.themes.contains_key("base16-eighties.dark") {
        "base16-eighties.dark"
    } else {
        ts.themes
            .keys()
            .next()
            .map(|s| s.as_str())
            .unwrap_or("base16-ocean.dark")
    };

    // Resolve syntax definition — normalise common aliases first.
    let lang_lower = language.to_lowercase();
    let lang_normalized = match lang_lower.as_str() {
        "rs" => "rust",
        "js" => "javascript",
        "ts" => "typescript",
        "py" => "python",
        "sh" | "bash" | "zsh" => "shell",
        "ex" | "exs" => "elixir",
        other => other,
    };

    let syntax_opt = ss
        .find_syntax_by_token(lang_normalized)
        .or_else(|| ss.find_syntax_by_extension(lang_normalized));

    let syntax = match syntax_opt {
        Some(s) => s,
        None => return plain_fallback(code),
    };

    let syntect_theme = match ts.themes.get(syntect_theme_name) {
        Some(t) => t,
        None => return plain_fallback(code),
    };

    let mut highlighter = HighlightLines::new(syntax, syntect_theme);
    let mut lines: Vec<Line<'static>> = Vec::new();

    for line_str in LinesWithEndings::from(code) {
        let ranges = match highlighter.highlight_line(line_str, ss) {
            Ok(r) => r,
            Err(_) => return plain_fallback(code),
        };

        let spans: Vec<Span<'static>> = ranges
            .into_iter()
            .map(|(style, text)| {
                let fg = syntect_color_to_ratatui(style.foreground);
                let ratatui_style = Style::default().fg(fg);
                // Strip the trailing newline that LinesWithEndings includes so
                // ratatui does not render an extra blank line per source line.
                let owned = text.trim_end_matches('\n').to_owned();
                Span::styled(owned, ratatui_style)
            })
            .filter(|s| !s.content.is_empty())
            .collect();

        lines.push(Line::from(spans));
    }

    lines
}

/// Plain-text fallback: render every line in the dim/muted theme style.
fn plain_fallback(code: &str) -> Vec<Line<'static>> {
    let theme = crate::style::theme();
    let style = theme.faint();
    code.lines()
        .map(|l| Line::from(Span::styled(l.to_owned(), style)))
        .collect()
}
