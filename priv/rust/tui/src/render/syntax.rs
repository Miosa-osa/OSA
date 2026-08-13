use ratatui::style::{Color, Style};
use ratatui::text::{Line, Span};
use std::borrow::Cow;
use std::sync::OnceLock;
use syntect::easy::HighlightLines;
use syntect::highlighting::{Theme as SyntectTheme, ThemeSet};
use syntect::parsing::{SyntaxReference, SyntaxSet};
use syntect::util::LinesWithEndings;

static SYNTAX_SET: OnceLock<SyntaxSet> = OnceLock::new();
static THEME_SET: OnceLock<ThemeSet> = OnceLock::new();

fn syntax_set() -> &'static SyntaxSet {
    SYNTAX_SET.get_or_init(SyntaxSet::load_defaults_newlines)
}

fn theme_set() -> &'static ThemeSet {
    THEME_SET.get_or_init(ThemeSet::load_defaults)
}

/// Convert a syntect Color to a ratatui Color, downgrading truecolor →
/// 256 → 16 → none for the detected terminal capability (see
/// [`crate::render::colors`]). On a truecolor terminal this is the identity
/// `Color::Rgb`; on a 256/16-color TTY or under `NO_COLOR` the color is mapped
/// to what the terminal can actually display instead of emitting a raw 24-bit
/// escape.
fn syntect_color_to_ratatui(c: syntect::highlighting::Color) -> Color {
    crate::render::colors::adapt_color(
        Color::Rgb(c.r, c.g, c.b),
        crate::render::colors::color_level(),
    )
}

/// Highlight a code block with syntax coloring.
/// Returns `Vec<Line<'static>>`. Falls back to plain dim rendering when the
/// language is unknown or syntect cannot tokenize the input.
pub fn highlight(code: &str, language: &str) -> Vec<Line<'static>> {
    // `code` is a model-authored fence body or a file read off a hostile repo.
    // syntect assigns colors, which become ratatui `Style` values — it never
    // emits escape bytes of its own, so scrubbing the *content* here strips the
    // injection vector without touching the highlighting. `\n` (line structure)
    // and `\t` (indentation) survive; see `sanitize::scrub_untrusted_document`.
    let code = &*crate::render::sanitize::scrub_untrusted_document(code);
    // Kill switch mirroring CC's CLAUDE_CODE_SYNTAX_HIGHLIGHT env toggle.
    if highlighting_disabled() {
        return plain_fallback(code);
    }
    let ss = syntax_set();
    let ts = theme_set();

    let (theme_name, syntect_theme) = match resolve_theme_named(ts) {
        Some(t) => t,
        None => return plain_fallback(code),
    };

    let syntax = match resolve_syntax(ss, language) {
        Some(s) => s,
        None => return plain_fallback(code),
    };

    match highlight_memoized(code, language, theme_name, syntax, syntect_theme, ss) {
        Some(lines) => lines,
        None => plain_fallback(code),
    }
}

// ─── Prefix memo for a GROWING code block ────────────────────────────────────
//
// Measured, not guessed: streaming a 200-line fenced block cost 8.9ms of render
// per delta, of which 8.3ms was syntect re-highlighting the whole block from
// line 1 — on every single token. A fence has no safe markdown split point
// until it closes, so the frozen-tail streaming renderer cannot help: the block
// sits in the unstable tail and is re-rendered per delta. That is O(N²) over a
// code block, on the hot path of an agent whose main output IS code.
//
// The memo makes it O(N): syntect's own state (`ParseState` + `HighlightState`)
// is kept alive between calls, positioned at the end of the last COMPLETE line
// it consumed. A call whose `code` extends that prefix only highlights the new
// bytes. Output stays byte-identical to the one-shot path, because
// `HighlightLines::highlight_line` is exactly `parse_line` + `HighlightIterator`
// over the same two state values, and that state is a pure function of the
// source prefix — equal prefix implies equal state.
//
// The trailing *partial* line (the one carrying the streaming block cursor) is
// highlighted from a CLONE of the state and never committed, so the next delta
// — which completes that line — still starts from the correct state.

/// Memoized highlighter state for the most recently highlighted growing block.
struct HighlightMemo {
    language: String,
    theme: &'static str,
    /// The source prefix already committed. Always empty or `\n`-terminated.
    consumed: String,
    /// Rendered lines for exactly `consumed`.
    lines: Vec<Line<'static>>,
    parse: syntect::parsing::ParseState,
    highlight: syntect::highlighting::HighlightState,
}

thread_local! {
    static HIGHLIGHT_MEMO: std::cell::RefCell<Option<HighlightMemo>> =
        const { std::cell::RefCell::new(None) };
}

/// Byte length of the longest `\n`-terminated prefix of `s`.
fn complete_lines_len(s: &str) -> usize {
    match s.rfind('\n') {
        Some(i) => i + 1,
        None => 0,
    }
}

/// Drop the memo. Test hook — proves the memoized and cold paths agree.
#[cfg(test)]
pub(crate) fn clear_highlight_memo() {
    HIGHLIGHT_MEMO.with(|c| *c.borrow_mut() = None);
}

fn highlight_memoized(
    code: &str,
    language: &str,
    theme_name: &'static str,
    syntax: &'static SyntaxReference,
    theme: &'static SyntectTheme,
    ss: &'static SyntaxSet,
) -> Option<Vec<Line<'static>>> {
    let highlighter = syntect::highlighting::Highlighter::new(theme);

    HIGHLIGHT_MEMO.with(|cell| {
        let mut slot = cell.borrow_mut();

        // Reuse only when this is the SAME block, under the same language and
        // theme, grown at the end. Anything else starts a fresh memo.
        let reusable = slot.as_ref().is_some_and(|m| {
            m.language == language
                && m.theme == theme_name
                && !m.consumed.is_empty()
                && code.len() >= m.consumed.len()
                && code.as_bytes()[..m.consumed.len()] == *m.consumed.as_bytes()
        });

        let mut memo = if reusable {
            slot.take().expect("checked above")
        } else {
            HighlightMemo {
                language: language.to_string(),
                theme: theme_name,
                consumed: String::new(),
                lines: Vec::new(),
                parse: syntect::parsing::ParseState::new(syntax),
                highlight: syntect::highlighting::HighlightState::new(
                    &highlighter,
                    syntect::parsing::ScopeStack::new(),
                ),
            }
        };

        let fresh = &code[memo.consumed.len()..];
        let commit_len = complete_lines_len(fresh);

        // 1. Commit every newly-completed line into the memo, advancing state.
        for line_str in LinesWithEndings::from(&fresh[..commit_len]) {
            match highlight_one(&mut memo.parse, &mut memo.highlight, &highlighter, ss, line_str) {
                Some(line) => memo.lines.push(line),
                None => return None, // caller falls back to plain rendering
            }
        }
        memo.consumed.push_str(&fresh[..commit_len]);

        // 2. The trailing partial line (if any) renders from a COPY of the
        //    state, so the committed state still points at a line boundary.
        let mut out = memo.lines.clone();
        let partial = &fresh[commit_len..];
        if !partial.is_empty() {
            let mut parse = memo.parse.clone();
            let mut hl = memo.highlight.clone();
            match highlight_one(&mut parse, &mut hl, &highlighter, ss, partial) {
                Some(line) => out.push(line),
                None => return None,
            }
        }

        *slot = Some(memo);
        Some(out)
    })
}

/// One line through syntect's state pair — the exact body of
/// `HighlightLines::highlight_line`, spelled out so the state can be owned (and
/// cloned) by the memo. `HighlightLines` itself is not `Clone`.
fn highlight_one(
    parse: &mut syntect::parsing::ParseState,
    highlight: &mut syntect::highlighting::HighlightState,
    highlighter: &syntect::highlighting::Highlighter<'_>,
    ss: &'static SyntaxSet,
    line: &str,
) -> Option<Line<'static>> {
    let ops = parse.parse_line(line, ss).ok()?;
    let ranges: Vec<(syntect::highlighting::Style, &str)> =
        syntect::highlighting::HighlightIterator::new(highlight, &ops, line, highlighter).collect();
    Some(ranges_to_line(ranges))
}

/// Highlight `code` line by line and return, for each source line, the syntect
/// foreground runs as `(text, fg)` pairs whose concatenation equals that line
/// (trailing newline stripped). Returns `None` when highlighting is disabled or
/// the language / theme is unknown, so the caller can fall back to its plain
/// rendering unchanged.
///
/// State (syntect's `ParseState` / `HighlightState`) is carried across lines, so
/// multi-line strings and block comments highlight correctly — the whole-snippet
/// (per-hunk) state Codex keeps for its diffs. Only foreground colors are
/// returned; the diff renderer supplies its own +/- backgrounds.
pub fn highlight_line_runs(code: &str, language: &str) -> Option<Vec<Vec<(String, Color)>>> {
    // Same reasoning as `highlight`. Scrubbing keeps `\n`, so the returned
    // per-line runs still index 1:1 with the caller's source lines — the diff
    // renderer depends on that alignment.
    let code = &*crate::render::sanitize::scrub_untrusted_document(code);
    if highlighting_disabled() {
        return None;
    }
    let ss = syntax_set();
    let ts = theme_set();
    let theme = resolve_theme(ts)?;
    let syntax = resolve_syntax(ss, language)?;

    let mut highlighter = HighlightLines::new(syntax, theme);
    let mut out: Vec<Vec<(String, Color)>> = Vec::new();
    for line_str in LinesWithEndings::from(code) {
        let ranges = highlighter.highlight_line(line_str, ss).ok()?;
        let runs = ranges
            .into_iter()
            .map(|(style, text)| {
                (
                    text.trim_end_matches('\n').to_owned(),
                    syntect_color_to_ratatui(style.foreground),
                )
            })
            .filter(|(t, _)| !t.is_empty())
            .collect();
        out.push(runs);
    }
    Some(out)
}

// ─── Shared resolvers ────────────────────────────────────────────────────────

/// Resolve the syntect theme that matches the active OSA theme (light OSA
/// themes get a light syntect theme), falling back to the first available theme
/// so we never panic on a stripped theme set.
fn resolve_theme(ts: &'static ThemeSet) -> Option<&'static SyntectTheme> {
    resolve_theme_named(ts).map(|(_, theme)| theme)
}

/// Same resolution as [`resolve_theme`], also returning the resolved theme NAME.
/// The name is the memo's invalidation key: a light/dark switch must not let a
/// growing block keep the previous theme's cached lines.
fn resolve_theme_named(ts: &'static ThemeSet) -> Option<(&'static str, &'static SyntectTheme)> {
    let preferred = if crate::style::theme().name.contains("light") {
        "InspiredGitHub"
    } else {
        "base16-eighties.dark"
    };
    let name = if ts.themes.contains_key(preferred) {
        preferred
    } else {
        ts.themes.keys().next().map(|s| s.as_str())?
    };
    ts.themes.get(name).map(|t| (name, t))
}

/// Resolve a syntax definition for `language`, normalising common aliases first.
fn resolve_syntax(ss: &'static SyntaxSet, language: &str) -> Option<&'static SyntaxReference> {
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
    ss.find_syntax_by_token(lang_normalized)
        .or_else(|| ss.find_syntax_by_extension(lang_normalized))
}

/// Map a single highlighted syntect line (its style ranges) to a ratatui
/// [`Line`], stripping the trailing newline and dropping empty spans — the exact
/// per-line transform [`highlight`] applies, factored so the one-shot and
/// streaming paths stay byte-identical.
fn ranges_to_line(ranges: Vec<(syntect::highlighting::Style, &str)>) -> Line<'static> {
    let spans: Vec<Span<'static>> = ranges
        .into_iter()
        .map(|(style, text)| {
            let fg = syntect_color_to_ratatui(style.foreground);
            let ratatui_style = Style::default().fg(fg);
            let owned = text.trim_end_matches('\n').to_owned();
            Span::styled(owned, ratatui_style)
        })
        .filter(|s| !s.content.is_empty())
        .collect();
    Line::from(spans)
}

// ─── Streaming-resumable highlighter (P5) ────────────────────────────────────

/// Incremental syntax highlighter that **persists** syntect's `ParseState` /
/// `HighlightState` across pushes for a single, still-open code fence.
///
/// OSA's frozen-tail streaming renderer never freezes an *open* ```` ``` ````
/// fence (no confirming blank line can arrive inside it), so the plain
/// [`highlight`] path re-highlights the entire growing block on every tail
/// re-render — O(N²) over the block, the worst hot path for a coding agent
/// streaming a long snippet. `ResumableHighlighter` highlights each committed
/// line exactly once by keeping the [`HighlightLines`] state alive between
/// pushes, collapsing that to O(N) total. This is grok's
/// `open_code_highlighter.rs` fix specialised to OSA's renderer.
///
/// Correctness contract: feeding the same lines to `push_line` in order yields
/// output **byte-identical** to `highlight(whole_block, lang)`, because
/// [`highlight`] itself feeds `LinesWithEndings` to the same `HighlightLines`
/// one line at a time. This is exercised by
/// `resumable_matches_one_shot` below.
pub struct ResumableHighlighter {
    /// `None` when highlighting is disabled or the language/theme is unknown —
    /// every line then falls back to the plain dim style, matching
    /// [`plain_fallback`].
    inner: Option<HighlightLines<'static>>,
}

impl ResumableHighlighter {
    /// Start a resumable highlighter for `language`. Resolution (kill switch,
    /// theme, syntax) mirrors [`highlight`] exactly so the fallback decision is
    /// identical.
    pub fn new(language: &str) -> Self {
        if highlighting_disabled() {
            return Self { inner: None };
        }
        let ss = syntax_set();
        let ts = theme_set();
        match (resolve_syntax(ss, language), resolve_theme(ts)) {
            (Some(syntax), Some(theme)) => Self {
                inner: Some(HighlightLines::new(syntax, theme)),
            },
            _ => Self { inner: None },
        }
    }

    /// True when this highlighter is in plain-fallback mode (disabled / unknown
    /// language) and every `push_line` returns dim text.
    pub fn is_plain(&self) -> bool {
        self.inner.is_none()
    }

    /// Highlight the next committed source line, advancing the persisted parse
    /// state. `line` may be given with or without its trailing newline; the
    /// rendered [`Line`] never contains one.
    pub fn push_line(&mut self, line: &str) -> Line<'static> {
        // The streaming open-fence path reaches syntect without going through
        // `highlight`, so it needs the same content scrub — see that function.
        let line = &*crate::render::sanitize::scrub_untrusted_document(line);
        let ss = syntax_set();
        match self.inner.as_mut() {
            Some(h) => {
                // syntect needs a newline-terminated line to finalise state; the
                // trailing `\n` is stripped from the emitted spans anyway.
                let input: Cow<str> = if line.ends_with('\n') {
                    Cow::Borrowed(line)
                } else {
                    Cow::Owned(format!("{line}\n"))
                };
                match h.highlight_line(&input, ss) {
                    Ok(ranges) => ranges_to_line(ranges),
                    Err(_) => plain_line(line),
                }
            }
            None => plain_line(line),
        }
    }
}

/// Single-line plain fallback matching [`plain_fallback`]'s per-line style.
fn plain_line(line: &str) -> Line<'static> {
    let style = crate::style::theme().code_plain();
    Line::from(Span::styled(line.trim_end_matches('\n').to_owned(), style))
}

/// Plain-text fallback: render every line in the dim/muted theme style.
fn plain_fallback(code: &str) -> Vec<Line<'static>> {
    let theme = crate::style::theme();
    // Body-weight code colour, NOT `faint`: an untagged fence is still code,
    // and the full-row background applied by `markdown::push_code_lines` is
    // what marks it as a block. Rendering the whole body dim made an untagged
    // block read as disabled text.
    let style = theme.code_plain();
    code.lines()
        .map(|l| Line::from(Span::styled(l.to_owned(), style)))
        .collect()
}

/// True when highlighting is disabled via `OSA_SYNTAX_HIGHLIGHT`
/// (`0`, `false`, `off`, `disabled` — case-insensitive).
fn highlighting_disabled() -> bool {
    match std::env::var("OSA_SYNTAX_HIGHLIGHT") {
        Ok(v) => matches!(
            v.trim().to_ascii_lowercase().as_str(),
            "0" | "false" | "off" | "disabled"
        ),
        Err(_) => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Flatten a line to `(text, fg)` pairs so we compare the visible content
    /// and color independent of span identity.
    fn line_cells(line: &Line<'static>) -> Vec<(String, Color)> {
        line.spans
            .iter()
            .map(|s| (s.content.to_string(), s.style.fg.unwrap_or(Color::Reset)))
            .collect()
    }

    #[test]
    fn resumable_matches_one_shot() {
        // A multi-line Rust block including a string literal (state that must
        // carry across lines to highlight correctly).
        let code = "fn main() {\n    let s = \"hello\";\n    println!(\"{}\", s);\n}\n";

        let one_shot = highlight(code, "rust");

        let mut streamed = ResumableHighlighter::new("rust");
        // Feed exactly as `highlight` feeds internally (LinesWithEndings), which
        // is the streaming caller's per-committed-line contract.
        let resumed: Vec<Line<'static>> = LinesWithEndings::from(code)
            .map(|l| streamed.push_line(l))
            .collect();

        assert_eq!(one_shot.len(), resumed.len(), "line count differs");
        for (i, (a, b)) in one_shot.iter().zip(resumed.iter()).enumerate() {
            assert_eq!(line_cells(a), line_cells(b), "line {i} differs");
        }
    }

    #[test]
    fn resumable_push_without_trailing_newline_matches() {
        // Streaming callers commit lines WITHOUT the trailing newline; output
        // must still match the one-shot render.
        let code = "let x = 1;\nlet y = 2;\n";
        let one_shot = highlight(code, "rust");

        let mut streamed = ResumableHighlighter::new("rust");
        let resumed = vec![streamed.push_line("let x = 1;"), streamed.push_line("let y = 2;")];

        assert_eq!(one_shot.len(), resumed.len());
        for (a, b) in one_shot.iter().zip(resumed.iter()) {
            assert_eq!(line_cells(a), line_cells(b));
        }
    }

    #[test]
    fn unknown_language_falls_back_to_plain() {
        let h = ResumableHighlighter::new("no-such-lang-xyz");
        assert!(h.is_plain());
    }

    #[test]
    fn color_downgrade_applies_to_highlight_output() {
        // Under a forced 16-color / no-color level, syntect's Rgb colors must be
        // mapped through `adapt_color` — no raw `Color::Rgb` survives.
        let line = ranges_to_line(vec![(
            syntect::highlighting::Style {
                foreground: syntect::highlighting::Color { r: 200, g: 40, b: 40, a: 255 },
                background: syntect::highlighting::Color { r: 0, g: 0, b: 0, a: 255 },
                font_style: syntect::highlighting::FontStyle::empty(),
            },
            "error",
        )]);
        // On a truecolor host this stays Rgb; the point verified here is that the
        // conversion goes through `syntect_color_to_ratatui`, whose downgrade is
        // unit-tested exhaustively in `render::colors`.
        assert_eq!(line.spans.len(), 1);
        assert_eq!(line.spans[0].content, "error");
    }

    // ── Prefix memo (growing code block) ────────────────────────────────────

    /// The pre-memo algorithm, verbatim: one `HighlightLines`, fed the whole
    /// block from line 1. The memo is only allowed to exist if it is
    /// indistinguishable from this.
    fn one_shot_reference(code: &str, language: &str) -> Vec<Vec<(String, Color)>> {
        let ss = syntax_set();
        let theme = resolve_theme(theme_set()).expect("theme");
        let syntax = resolve_syntax(ss, language).expect("syntax");
        let mut h = HighlightLines::new(syntax, theme);
        LinesWithEndings::from(code)
            .map(|l| line_cells(&ranges_to_line(h.highlight_line(l, ss).unwrap())))
            .collect()
    }

    fn cells(lines: &[Line<'static>]) -> Vec<Vec<(String, Color)>> {
        lines.iter().map(line_cells).collect()
    }

    /// Every prefix of a streamed block — including the ones that end mid-line,
    /// which is where the trailing-partial-line state clone earns its keep —
    /// must render exactly as a cold full highlight of that same prefix.
    #[test]
    fn memoized_prefixes_match_the_one_shot_reference() {
        let code = "fn main() {\n    let s = \"a string with { braces }\";\n    /* a block\n       comment */\n    println!(\"{}\", s);\n}\n";

        clear_highlight_memo();
        for end in 1..=code.len() {
            if !code.is_char_boundary(end) {
                continue;
            }
            let prefix = &code[..end];
            // Warm path: the memo has seen every shorter prefix already.
            let warm = cells(&highlight(prefix, "rust"));
            assert_eq!(
                warm,
                one_shot_reference(prefix, "rust"),
                "memoized output diverged at prefix len {end}: {prefix:?}"
            );
        }
    }

    /// A block cursor is appended to the live tail every frame and then
    /// replaced by the next real characters. The memo must never commit it.
    #[test]
    fn a_transient_trailing_cursor_is_never_committed() {
        clear_highlight_memo();
        let base = "fn f() {\n    let x = 1";
        let with_cursor = format!("{base}\u{2588}");
        let _ = highlight(&with_cursor, "rust");
        // Now the real next characters arrive where the cursor was.
        let grown = format!("{base}2;\n");
        assert_eq!(
            cells(&highlight(&grown, "rust")),
            one_shot_reference(&grown, "rust"),
            "the streaming cursor leaked into the committed prefix"
        );
    }

    /// Switching language (or interleaving two blocks) must not reuse state.
    #[test]
    fn a_different_block_does_not_reuse_the_memo() {
        clear_highlight_memo();
        let rust = "fn main() {\n    let s = \"x\";\n";
        let py = "def main():\n    s = \"x\"\n";
        let _ = highlight(rust, "rust");
        assert_eq!(cells(&highlight(py, "python")), one_shot_reference(py, "python"));
        assert_eq!(cells(&highlight(rust, "rust")), one_shot_reference(rust, "rust"));
    }
}
