//! Terminal-injection proofs for the rich renderers, measured on a real
//! terminal emulator.
//!
//! # Why these tests do not assert on a `Buffer`
//!
//! This whole class of bug stayed invisible because it was being looked for in
//! the wrong place. A ratatui `Buffer` is a grid of *intended* glyphs. Assert on
//! it and you learn what the renderer meant to draw — never what the terminal
//! then did with those bytes. The two diverge in precisely the dangerous case:
//!
//!   * a bidi override (`U+202E`) is a zero-width grapheme, and ratatui drops
//!     zero-width graphemes on cell fill, so it never leaves the buffer — a
//!     `Buffer` assertion shows the *harmless* family being handled;
//!   * a raw `ESC` is width-1 as far as the cell fill is concerned, so it is
//!     carried through untouched, written straight to the terminal, and
//!     **executed** — and a `Buffer` assertion cannot tell "this cell contains
//!     ESC" from "this cell displayed ESC", because a `Buffer` has no notion of
//!     a terminal that obeys it.
//!
//! So every proof below runs ratatui's real ANSI output through a `vt100`
//! parser ([`crate::test_backend::VT100Backend`]) and asserts on the
//! **emulator's** observable state: the window title it was told to set, where
//! its cursor ended up, and what is actually on its screen.
//!
//! # The shape of each proof
//!
//! Each surface gets two arms:
//!
//!   1. a **control** that renders the payload the way the surface rendered it
//!      before the fix — a plain `Span` carrying the untrusted bytes — and
//!      asserts the emulator *is* driven. That arm is what makes the test a
//!      proof rather than an assertion of faith: it demonstrates the emulator
//!      would report the compromise if it happened, so the second arm passing
//!      means something;
//!   2. the **fixed path**, asserting the emulator is untouched *and* that the
//!      neutralized text is still legible on screen. Silently swallowing the
//!      line would also pass an "is the terminal safe" check, and would be its
//!      own defect.

use ratatui::style::Color;
use ratatui::text::{Line, Span, Text};
use ratatui::widgets::Paragraph;
use ratatui::Terminal;

use crate::test_backend::VT100Backend;

/// What the emulator observably did, after being handed a widget's real output.
struct Observed {
    /// The window title the terminal was told to set. Non-empty ⇒ an OSC ran.
    title: String,
    /// `(row, col)` the cursor was left at. Moves ⇒ a CSI ran.
    cursor: (u16, u16),
    /// The visible screen, one row per line.
    screen: String,
}

/// Render `text` as a `Paragraph` filling an 80x24 emulated terminal and report
/// what the terminal did with it.
fn observe(text: Text<'static>) -> Observed {
    let mut term = Terminal::new(VT100Backend::new(80, 24)).unwrap();
    term.draw(|frame| {
        frame.render_widget(Paragraph::new(text), frame.area());
    })
    .unwrap();
    let title = term.backend().vt100().screen().title().to_string();
    let cursor = term.backend().vt100().screen().cursor_position();
    let screen = term.backend().contents();
    Observed {
        title,
        cursor,
        screen,
    }
}

/// The payload: retitle the operator's window, then jump the cursor. Both are
/// observable on the emulator and neither is observable on a `Buffer`.
const PAYLOAD: &str = "\u{1b}]0;PWNED\u{7}\u{1b}[9;30H";

/// What the payload collapses to under the **character-level** scrubs
/// (`scrub_untrusted_line` / `_document`, used by markdown prose and the session
/// title). Those filter the `\x1b` byte and leave its parameters behind as
/// literal text. It stays fully legible — that is the point on those surfaces.
const NEUTRALIZED: &str = "]0;PWNED[9;30H";

/// What the payload collapses to under the **rendered-span backstop**
/// (`scrub_rendered_span`, the tool-output path): **nothing**.
///
/// That scrub consumes whole sequences via `util::escape_len_at` rather than
/// filtering the introducer alone, so no residue reaches the screen. Filtering
/// the introducer alone is what turned a build banner's `ESC[1m` into a visible
/// `[1m` and rendered ordinary coloured tool output as `[1mvite v5.4.10[0m`;
/// the tool path carries real SGR colour from real programs, so it is the one
/// surface where leftover parameters are routine rather than exotic.
///
/// The two levels are deliberately distinct — see `render::sanitize`.
const NEUTRALIZED_SPAN: &str = "";

/// The control arm, shared by every surface: prove the emulator reports a
/// compromise when the untrusted bytes reach it in a plain span — i.e. exactly
/// the way each of these renderers emitted prose before the fix.
fn control_arm_is_exploitable(prefix: &str) {
    let hostile = format!("{prefix}{PAYLOAD}tail");
    let obs = observe(Text::from(Line::from(Span::raw(hostile))));
    assert_eq!(
        obs.title, "PWNED",
        "the control arm must actually be exploitable, or the fixed arm proves \
         nothing — a raw span carrying ESC has to reach and drive the terminal"
    );
    assert_ne!(
        obs.cursor,
        (0, 0),
        "the CSI half of the payload must move the emulator's cursor in the \
         control arm"
    );
}

/// Assert the emulator was not driven, and that the text survived legibly.
fn assert_neutralized(obs: &Observed, must_contain: &str) {
    assert_eq!(
        obs.title, "",
        "untrusted text executed an OSC sequence — an escape reached the \
         terminal:\n{}",
        obs.screen
    );
    assert!(
        !obs.screen.contains('\u{1b}'),
        "a raw ESC is still on screen:\n{:?}",
        obs.screen
    );
    assert!(
        obs.screen.contains(must_contain),
        "the neutralized text must stay legible — swallowing the line would be \
         its own regression. Expected {must_contain:?} in:\n{}",
        obs.screen
    );
}

// ─── markdown: every assistant reply ─────────────────────────────────────────

#[test]
fn a_markdown_reply_cannot_drive_the_terminal() {
    control_arm_is_exploitable("The answer is ");

    let obs = observe(super::markdown::render_markdown(
        &format!("The answer is {PAYLOAD}tail"),
        80,
    ));
    assert_neutralized(&obs, &format!("The answer is {NEUTRALIZED}tail"));
}

/// Headings, list items, blockquotes and table cells all reach the screen
/// through different branches of the parser. Scrubbing at the single entry is
/// what makes one fix cover all of them — and any branch added later.
#[test]
fn every_markdown_construct_is_covered_by_the_single_entry_scrub() {
    for src in [
        format!("# Heading {PAYLOAD}"),
        format!("- list item {PAYLOAD}"),
        format!("1. ordered item {PAYLOAD}"),
        format!("> quoted {PAYLOAD}"),
        format!("**bold {PAYLOAD}**"),
        format!("`inline code {PAYLOAD}`"),
        format!("| a | b |\n|---|---|\n| {PAYLOAD} | x |"),
        format!("- [ ] todo {PAYLOAD}"),
    ] {
        let obs = observe(super::markdown::render_markdown(&src, 80));
        assert_eq!(
            obs.title, "",
            "markdown construct drove the terminal: {src:?}\n{}",
            obs.screen
        );
        assert!(
            !obs.screen.contains('\u{1b}'),
            "raw ESC survived construct {src:?}"
        );
    }
}

// ─── syntax: fenced code blocks ──────────────────────────────────────────────

#[test]
fn a_highlighted_code_fence_cannot_drive_the_terminal() {
    control_arm_is_exploitable("fn main() { ");

    let code = format!("fn main() {{ let x = \"{PAYLOAD}\"; }}");
    let obs = observe(Text::from(super::syntax::highlight(&code, "rust")));
    assert_neutralized(&obs, NEUTRALIZED);
}

/// Through the markdown fence path as well, since that is how a model actually
/// reaches the highlighter.
#[test]
fn a_code_fence_inside_a_reply_cannot_drive_the_terminal() {
    let src = format!("here:\n\n```rust\nlet s = \"{PAYLOAD}\";\n```\n");
    let obs = observe(super::markdown::render_markdown(&src, 80));
    assert_neutralized(&obs, NEUTRALIZED);
}

// ─── diff ────────────────────────────────────────────────────────────────────

#[test]
fn a_diff_cannot_drive_the_terminal() {
    control_arm_is_exploitable("- ");

    // Both sides are untrusted: the old text is a file off a hostile repo, the
    // new text is the model's proposal.
    let old = format!("let a = 1;\nlet victim = \"{PAYLOAD}\";\n");
    let new = format!("let a = 2;\nlet victim = \"{PAYLOAD}\";\n");
    let obs = observe(Text::from(super::diff::render_diff(
        &old,
        &new,
        80,
        Some("rust"),
    )));
    assert_neutralized(&obs, NEUTRALIZED);

    // And on the unhighlighted path, which composes different spans.
    let obs = observe(Text::from(super::diff::render_diff(&old, &new, 80, None)));
    assert_neutralized(&obs, NEUTRALIZED);
}

// ─── OSC 8 hyperlinks: the sharpest case ─────────────────────────────────────

/// A markdown link URL is model-chosen and is interpolated *inside an open OSC
/// string*: `ESC ]8;;URL ESC\`. Stripping ESC from the URL is not enough — a
/// bare `BEL` closes an OSC string on every terminal, and so does a C1 `ST`
/// (`\u{9C}`). So `[click](http://x\x07<payload>)` ends the hyperlink early and
/// the remainder is no longer a URL: it is the next command the terminal runs.
///
/// The control arm builds the sequence the way `osc8` built it before the fix
/// (raw interpolation) and proves the emulator is driven by it.
#[test]
fn an_osc8_url_cannot_terminate_its_own_sequence() {
    let hostile_url = format!("http://example.com/x{PAYLOAD}");

    // Control: raw interpolation, i.e. the pre-fix `osc8` body verbatim.
    let raw = format!("\u{1b}]8;;{hostile_url}\u{1b}\\click\u{1b}]8;;\u{1b}\\");
    let obs = observe(Text::from(Line::from(Span::raw(raw))));
    assert_eq!(
        obs.title, "PWNED",
        "the control arm must be exploitable: a BEL inside the URI has to close \
         the OSC string and let the rest execute"
    );

    // Fixed: the URI is percent-encoded per the OSC 8 spec, so no byte in it can
    // close the string.
    let obs = observe(Text::from(Line::from(Span::raw(super::super::components::osc8::osc8(
        "click",
        &hostile_url,
    )))));
    assert_eq!(
        obs.title, "",
        "a hyperlink URL still drove the terminal:\n{}",
        obs.screen
    );
    assert!(
        obs.screen.contains("click"),
        "the link text must still render:\n{}",
        obs.screen
    );
}

/// The same hole reached the way a model actually reaches it — a markdown link
/// in a reply.
#[test]
fn a_markdown_link_cannot_drive_the_terminal() {
    let src = format!("see [click](http://example.com/x{PAYLOAD}) for details");
    let obs = observe(super::markdown::render_markdown(&src, 80));
    assert_eq!(
        obs.title, "",
        "a markdown link drove the terminal:\n{}",
        obs.screen
    );
    assert!(
        obs.screen.contains("click"),
        "link text missing:\n{}",
        obs.screen
    );
}

/// Every byte that can close an OSC string must be encoded out of the URI, not
/// merely the ESC introducer.
#[test]
fn every_osc_string_terminator_is_encoded_out_of_a_uri() {
    for (name, terminator) in [
        ("BEL", "\u{7}"),
        ("ESC", "\u{1b}"),
        ("C1 ST", "\u{9c}"),
        ("NUL-adjacent SOH", "\u{1}"),
    ] {
        let seq = super::super::components::osc8::osc8("t", &format!("http://x{terminator}y"));
        // Exactly four ESCs survive: the two introducers and the two String
        // Terminators the wrapper itself emits. Anything else means the payload
        // contributed one.
        assert_eq!(
            seq.matches('\u{1b}').count(),
            4,
            "{name} disturbed the escape structure: {seq:?}"
        );

        // Isolate the URI field itself — everything between the opening
        // `ESC ]8;;` and the ST that closes it — and require it to be free of
        // the terminator. Slicing from byte 0 would trivially "find" the
        // introducer's own ESC and say nothing about the payload.
        let uri = seq
            .strip_prefix("\u{1b}]8;;")
            .and_then(|t| t.split("\u{1b}\\").next())
            .expect("well-formed OSC 8 wrapper");
        assert!(
            !uri.contains(terminator),
            "{name} survived into the URI payload: {uri:?} (full: {seq:?})"
        );
        // Percent-encoded, not merely dropped: the URI still points where it
        // said it did, it just can no longer close its own escape. Encoding is
        // per UTF-8 byte, as URI syntax requires — the C1 ST is two bytes.
        let expected: String = terminator
            .bytes()
            .map(|b| format!("%{b:02X}"))
            .collect::<Vec<_>>()
            .concat();
        assert_eq!(
            uri,
            format!("http://x{expected}y"),
            "{name} must be percent-encoded, not merely dropped: {uri:?}"
        );
    }
}

// ─── tool output: bash stdout, grep hits, file bodies, MCP payloads ──────────

/// Render options matching an ordinary expanded transcript card.
fn tool_opts() -> crate::tools::RenderOpts {
    crate::tools::RenderOpts {
        status: crate::tools::ToolStatus::Success,
        width: 78,
        expanded: true,
        compact: false,
        spinner_frame: None,
        duration_ms: 12,
        truncated: false,
    }
}

/// Render a tool card the way the app does and observe the terminal.
fn observe_tool(name: &str, args: &str, result: &str) -> Observed {
    observe(Text::from(crate::tools::render_tool(
        name,
        args,
        result,
        &tool_opts(),
    )))
}

/// Every tool renderer, through the one choke point that guards them all.
///
/// The payload is placed in `result` — a shell's stdout, a file body, a grep
/// hit, an MCP server's reply — which is the field an attacker most easily
/// controls: it is whatever the command printed.
#[test]
fn no_tool_result_can_drive_the_terminal() {
    for (name, args) in [
        ("bash", r#"{"command":"ls"}"#),
        ("read", r#"{"file_path":"/tmp/a.rs"}"#),
        ("write", r#"{"file_path":"/tmp/a.rs","content":"x"}"#),
        ("grep", r#"{"pattern":"foo"}"#),
        ("glob", r#"{"pattern":"**/*.rs"}"#),
        ("ls", r#"{"path":"/tmp"}"#),
        ("webfetch", r#"{"url":"http://example.com"}"#),
        ("websearch", r#"{"query":"rust"}"#),
        ("mcp__srv__tool", r#"{"a":1}"#),
        ("task", r#"{"description":"go"}"#),
        ("todowrite", r#"{"todos":[]}"#),
        ("diagnostics", "{}"),
        ("references", "{}"),
        ("some_unknown_tool_xyz", "{}"),
    ] {
        let obs = observe_tool(name, args, &format!("line one\n{PAYLOAD}\nline three"));
        assert_eq!(
            obs.title, "",
            "tool {name:?} let its result drive the terminal:\n{}",
            obs.screen
        );
        assert!(
            !obs.screen.contains('\u{1b}'),
            "tool {name:?} left a raw ESC on screen"
        );
    }
}

/// The same hole reached through `args` — and reached the way a payload
/// actually survives to the renderer, as a **JSON `\u` escape**.
///
/// This is why the tool backstop scrubs the rendered lines rather than the raw
/// `args` string: the text below contains no control character at all until
/// serde decodes it, so an ingress-side scrub of `args` would pass it straight
/// through and the renderer would then materialise the ESC itself.
#[test]
fn a_json_escaped_payload_in_tool_args_cannot_drive_the_terminal() {
    let args = "{\"command\":\"cat \\u001b]0;PWNED\\u0007/etc/passwd\"}";
    assert!(
        !args.contains('\u{1b}'),
        "precondition: the raw args string is escape-free, so only a scrub \
         downstream of the JSON parse can catch this"
    );

    let obs = observe_tool("bash", args, "root:x:0:0");
    assert_eq!(
        obs.title, "",
        "a JSON-escaped payload in tool args drove the terminal:\n{}",
        obs.screen
    );
    assert!(
        !obs.screen.contains("]0;PWNED"),
        "the escape's parameters leaked onto the screen as literal text — the \
         sequence must be consumed whole:\n{}",
        obs.screen
    );
}

/// Tool output is autolinked, and those links are real OSC 8 escapes. The
/// backstop must recognise them and leave them alone — shredding every
/// clickable path in the transcript would be a worse regression than the bug.
#[test]
fn the_tool_backstop_preserves_legitimate_hyperlinks() {
    let link = super::super::components::osc8::osc8("a.rs", "file:///tmp/a.rs");
    let mut lines = vec![Line::from(vec![
        Span::raw("see "),
        Span::raw(link.clone()),
        Span::raw(format!(" and {PAYLOAD} not this")),
    ])];
    super::sanitize::scrub_rendered_lines(&mut lines);

    let flat: String = lines[0]
        .spans
        .iter()
        .map(|s| s.content.as_ref())
        .collect::<String>();
    assert!(
        flat.contains(&link),
        "a well-formed hyperlink was destroyed by the backstop: {flat:?}"
    );
    assert!(
        flat.contains(&format!(" and {NEUTRALIZED_SPAN} not this")),
        "the injected payload was not neutralized: {flat:?}"
    );
    // Only the hyperlink's own four ESCs remain.
    assert_eq!(flat.matches('\u{1b}').count(), 4, "stray ESC left: {flat:?}");
}

/// An *incomplete* hyperlink wrapper is not a hyperlink — it is an open OSC
/// string, which is the attack. It must not get the passthrough.
#[test]
fn an_unterminated_osc8_wrapper_is_not_treated_as_a_hyperlink() {
    let mut lines = vec![Line::from(Span::raw(
        "\u{1b}]8;;http://x\u{7}rest-of-payload".to_string(),
    ))];
    super::sanitize::scrub_rendered_lines(&mut lines);
    let flat: String = lines[0]
        .spans
        .iter()
        .map(|s| s.content.as_ref())
        .collect::<String>();
    assert!(
        !flat.contains('\u{1b}'),
        "an unterminated OSC 8 wrapper was passed through: {flat:?}"
    );
    // The BEL terminates the OSC string, so the sequence — introducer and
    // parameters alike — is consumed whole and only the text after it survives.
    assert_eq!(flat, "rest-of-payload");
}

/// Ordinary tool output renders identically — the backstop must be invisible.
#[test]
fn ordinary_tool_output_is_unchanged_by_the_backstop() {
    let opts = tool_opts();
    let result = "src/main.rs:12:    let x = 1;\nsrc/lib.rs:3:    let y = 2;\n";
    let lines = crate::tools::render_tool("grep", r#"{"pattern":"let"}"#, result, &opts);
    let unscrubbed = crate::tools::render_tool("grep", r#"{"pattern":"let"}"#, result, &opts);

    let flat = |ls: &[Line<'static>]| -> String {
        ls.iter()
            .map(|l| {
                l.spans
                    .iter()
                    .map(|s| s.content.as_ref())
                    .collect::<String>()
            })
            .collect::<Vec<_>>()
            .join("\n")
    };
    assert_eq!(flat(&lines), flat(&unscrubbed));
    assert!(
        flat(&lines).contains("src/main.rs"),
        "grep hits disappeared: {}",
        flat(&lines)
    );
}

// ─── status bar: the payload that survives every redraw ──────────────────────

/// The session title is model-generated and lives in persistent chrome, redrawn
/// on every frame — so an escape there is not a one-shot, it re-executes for the
/// life of the session.
#[test]
fn the_session_title_cannot_drive_the_terminal() {
    use crate::components::Component;

    let mut sb = crate::components::status_bar::StatusBar::new();
    sb.set_session_title(Some(format!("Debugging {PAYLOAD} errors")));

    let mut term = Terminal::new(VT100Backend::new(120, 24)).unwrap();
    // Redraw several times: a surviving escape in chrome fires once per frame,
    // and this is the surface where that distinction matters.
    for _ in 0..3 {
        term.draw(|frame| {
            let area = ratatui::layout::Rect::new(0, 0, 120, 2);
            sb.draw(frame, area);
        })
        .unwrap();
    }

    let title = term.backend().vt100().screen().title().to_string();
    assert_eq!(
        title, "",
        "the model-generated session title drove the terminal from persistent \
         chrome:\n{}",
        term.backend().contents()
    );
    assert_eq!(
        sb.session_title(),
        Some(format!("Debugging {NEUTRALIZED} errors").as_str()),
        "the title must stay legible after scrubbing"
    );
}

// ─── Non-regression: the styling these renderers emit is untouched ───────────
//
// Getting this wrong is worse than the bug. The renderers style with ratatui
// `Style` values, and the scrub only removes control characters from *content*,
// so none of it should move — these pin that.

/// Collect the distinct foreground colors a rendered line set actually uses.
fn fg_colors(lines: &[Line<'static>]) -> Vec<Color> {
    let mut seen: Vec<Color> = Vec::new();
    for line in lines {
        for span in &line.spans {
            if let Some(c) = span.style.fg {
                if !seen.contains(&c) {
                    seen.push(c);
                }
            }
        }
    }
    seen
}

fn bg_colors(lines: &[Line<'static>]) -> Vec<Color> {
    let mut seen: Vec<Color> = Vec::new();
    for line in lines {
        for span in &line.spans {
            if let Some(c) = span.style.bg {
                if !seen.contains(&c) {
                    seen.push(c);
                }
            }
        }
    }
    seen
}

/// A highlighted fence must still be *highlighted* — several distinct
/// foregrounds, not one flat color. Turning every code block into plain text
/// would be a far worse regression than the bug being fixed.
#[test]
fn syntax_highlighting_is_byte_identical_for_clean_code() {
    let code = "fn main() {\n    let x: u32 = 42;\n    println!(\"hi {}\", x);\n}\n";

    let lines = super::syntax::highlight(code, "rust");
    let colors = fg_colors(&lines);
    assert!(
        colors.len() > 2,
        "clean Rust must still highlight with multiple colors, got {colors:?}"
    );

    // And the text is unchanged, span for span.
    let flat: String = lines
        .iter()
        .map(|l| {
            l.spans
                .iter()
                .map(|s| s.content.as_ref())
                .collect::<String>()
        })
        .collect::<Vec<_>>()
        .join("\n");
    assert!(flat.contains("println!"), "code text altered: {flat:?}");
    assert!(
        flat.contains("    let x: u32 = 42;"),
        "leading indentation was lost: {flat:?}"
    );
}

/// Tabs are indentation, not a control character to strip: code indented with
/// tabs must survive.
#[test]
fn tab_indentation_survives_the_scrub() {
    let code = "fn main() {\n\tlet x = 1;\n}\n";
    let lines = super::syntax::highlight(code, "rust");
    let flat: String = lines
        .iter()
        .map(|l| {
            l.spans
                .iter()
                .map(|s| s.content.as_ref())
                .collect::<String>()
        })
        .collect();
    assert!(flat.contains('\t'), "tab indentation was stripped: {flat:?}");
}

/// A diff must still be a *coloured* diff: +/- background bars intact.
#[test]
fn diff_colouring_is_intact() {
    let old = "let a = 1;\nlet b = 2;\nlet c = 3;\n";
    let new = "let a = 1;\nlet b = 20;\nlet c = 3;\n";

    let hl = super::diff::render_diff(old, new, 80, Some("rust"));
    let plain = super::diff::render_diff(old, new, 80, None);

    assert!(
        bg_colors(&hl).len() >= 2,
        "the +/- background bars are gone: {:?}",
        bg_colors(&hl)
    );
    assert!(
        fg_colors(&hl).len() > fg_colors(&plain).len(),
        "syntax highlighting inside the diff was lost — highlighted and plain \
         renders now use the same foregrounds"
    );
}

/// A clean hyperlink is still a working hyperlink, and a clean URL passes
/// through the encoder byte-identical (no gratuitous percent-escaping of an
/// ordinary link).
#[test]
fn a_clean_hyperlink_is_unchanged() {
    let url = "https://example.com/a/b?c=1&d=2#frag";
    let seq = super::super::components::osc8::osc8("docs", url);
    assert_eq!(seq, format!("\u{1b}]8;;{url}\u{1b}\\docs\u{1b}]8;;\u{1b}\\"));

    // And it renders as clickable text on a real emulator: the escape is
    // consumed, the label is on screen.
    let obs = observe(Text::from(Line::from(Span::raw(seq))));
    assert!(
        obs.screen.contains("docs"),
        "hyperlink label missing:\n{}",
        obs.screen
    );
    assert_eq!(obs.title, "", "a clean hyperlink must not set a title");
}

/// Emoji that depend on invisible joiners must survive. The line/block scrubbers
/// strip ZWJ and variation selectors — correct for a command a human must
/// verify, wrong for prose, where it would split one glyph into three.
#[test]
fn emoji_sequences_survive_the_document_scrub() {
    for s in ["👩‍💻", "❤️", "👨‍👩‍👧‍👦", "1️⃣"] {
        assert_eq!(
            &*super::sanitize::scrub_untrusted_document(s),
            s,
            "emoji sequence was mangled: {s:?}"
        );
    }

    // …and through the real markdown path.
    let out = super::markdown::render_markdown("pair 👩‍💻 done", 40);
    let flat: String = out
        .lines
        .iter()
        .map(|l| {
            l.spans
                .iter()
                .map(|s| s.content.as_ref())
                .collect::<String>()
        })
        .collect();
    assert!(flat.contains("👩‍💻"), "ZWJ emoji lost in markdown: {flat:?}");
}

/// Ordinary prose, code and links pass through untouched — the scrub must be
/// invisible on everything that is not an attack.
#[test]
fn ordinary_content_is_borrowed_not_rewritten() {
    for s in [
        "A normal sentence with punctuation: it's fine!",
        "let x = foo(&bar[0]);\n\tindented\n",
        "漢字とemoji 🎉 and Ελληνικά",
        "https://example.com/path?q=a%20b",
    ] {
        assert!(
            matches!(
                super::sanitize::scrub_untrusted_document(s),
                std::borrow::Cow::Borrowed(_)
            ),
            "clean text should not be reallocated: {s:?}"
        );
    }
}
