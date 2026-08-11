//! Scrubbing of untrusted text before it reaches the screen.
//!
//! Everything the backend hands the TUI to *display* — tool names, shell
//! commands, file paths, model prose, warnings — is attacker-reachable: a
//! prompt-injected model, a hostile repo, or a compromised MCP server all get
//! to choose those bytes. Two families of codepoint make that dangerous at the
//! display site, independent of anything the backend does:
//!
//!   * **control characters**, which can terminate or reshape an escape
//!     sequence we are building (a raw `\x07` inside an OSC payload ends it
//!     early and hands the remainder to the terminal as commands), and which
//!     corrupt cell accounting in a grid renderer;
//!   * **bidi and invisible formatting codepoints** — the Trojan Source family.
//!     These do not change the bytes, they change the *reading order*, so a
//!     string renders as something other than what it is. In a permission
//!     dialog that is the whole ballgame: the operator reads one command and
//!     authorizes another.
//!
//! This module owns the character policy. [`crate::terminal_title`] applies it
//! on the OSC-title path (where it started, and where it is joined by
//! whitespace collapsing and a length bound); the permission dialog applies it
//! to the label, command and metadata it asks the user to make a trust decision
//! about. The defence lives here, at the display site, precisely because we
//! cannot assume any producer upstream scrubbed — today, none does.

/// Whether `ch` is an invisible or text-reordering formatting codepoint.
///
/// These render as nothing (or as a change to *other* characters' order), which
/// is exactly what makes them unsafe in text a human is asked to verify. The
/// bidi entries — `U+202A`–`U+202E` overrides/embeddings and the `U+2066`–
/// `U+2069` isolates inside the `U+2060`–`U+206F` block — are the Trojan Source
/// controls.
///
/// Control characters are deliberately *not* covered here; callers pair this
/// with [`char::is_control`] so each display surface can decide whether a
/// newline is structure it wants to keep.
pub fn is_invisible_formatting_char(ch: char) -> bool {
    matches!(
        ch,
        '\u{00AD}'                  // SOFT HYPHEN
            | '\u{034F}'            // COMBINING GRAPHEME JOINER
            | '\u{061C}'            // ARABIC LETTER MARK
            | '\u{180E}'            // MONGOLIAN VOWEL SEPARATOR
            | '\u{200B}'..='\u{200F}' // ZWSP/ZWNJ/ZWJ/LRM/RLM
            | '\u{202A}'..='\u{202E}' // LRE/RLE/PDF/LRO/RLO  (Trojan Source)
            | '\u{2060}'..='\u{206F}' // word joiner, invisible ops, LRI/RLI/FSI/PDI, deprecated bidi
            | '\u{FE00}'..='\u{FE0F}' // variation selectors
            | '\u{FEFF}'            // BOM / ZWNBSP
            | '\u{FFF9}'..='\u{FFFB}' // interlinear annotation
            | '\u{1BCA0}'..='\u{1BCA3}' // shorthand format controls
            | '\u{E0100}'..='\u{E01EF}' // variation selectors supplement
    )
}

/// Scrub untrusted text destined for a **single display line**.
///
/// Drops every control character (including the tabs and newlines that would
/// break a one-line span) and every invisible/reordering codepoint. What comes
/// back renders in the order it reads.
///
/// Nothing else is altered: no truncation, no whitespace collapsing, no
/// escaping. Width-fitting stays the caller's job so this can be applied at
/// ingress without pre-empting layout.
pub fn scrub_untrusted_line(text: &str) -> String {
    text.chars()
        .filter(|ch| !ch.is_control() && !is_invisible_formatting_char(*ch))
        .collect()
}

/// Scrub untrusted text destined for a **multi-line block** (e.g. a tool's
/// argument payload rendered as a `Paragraph`).
///
/// Identical to [`scrub_untrusted_line`] except that `\n` survives, because
/// line structure is meaningful there. `\r` is dropped along with the other
/// controls so a lone carriage return cannot overprint a row.
pub fn scrub_untrusted_block(text: &str) -> String {
    text.chars()
        .filter(|ch| *ch == '\n' || (!ch.is_control() && !is_invisible_formatting_char(*ch)))
        .collect()
}

/// [`scrub_untrusted_line`] over an optional field, preserving `None`.
pub fn scrub_untrusted_line_opt(text: Option<String>) -> Option<String> {
    text.map(|t| scrub_untrusted_line(&t))
}

// ─── Rich-document scrubbing ─────────────────────────────────────────────────
//
// The line/block scrubbers above are for text a human is asked to *verify*, so
// they are maximally aggressive: anything invisible goes. The rich renderers
// (markdown, syntax highlighting, diffs) are a different trade. They carry the
// model's prose and a repo's source, where two of the "invisible" families are
// load-bearing rather than hostile:
//
//   * ZERO WIDTH JOINER glues emoji sequences together (`👩‍💻` is one glyph, two
//     columns); dropping it splits one grapheme into three,
//   * variation selectors pick emoji-vs-text presentation (`❤️` vs `❤`).
//
// Neither can reorder text or terminate an escape, so neither is a Trojan
// Source or injection vector. Stripping them would be over-scrubbing — a
// visible regression bought for no security. Everything else in the invisible
// set, plus every control character other than the `\n`/`\t` these renderers
// are built on, is still removed.

/// Whether `ch` is an invisible codepoint that legitimately appears *inside a
/// grapheme cluster* — the joiner and presentation selectors that make emoji
/// sequences render as one glyph.
///
/// Carved out of the scrub in [`scrub_untrusted_document`] only. These cannot
/// change reading order and cannot close an escape sequence.
fn is_emoji_sequence_char(ch: char) -> bool {
    matches!(
        ch,
        '\u{200D}'                    // ZERO WIDTH JOINER
            | '\u{FE00}'..='\u{FE0F}' // variation selectors
            | '\u{E0100}'..='\u{E01EF}' // variation selectors supplement
    )
}

/// Scrub untrusted text destined for a **rich renderer** — markdown prose,
/// syntax-highlighted code, diff bodies.
///
/// Keeps `\n` and `\t`, which those renderers treat as structure (line breaks
/// and indentation). Drops every other control character — crucially `\x1b`,
/// which ratatui carries through its cell fill untouched and the terminal then
/// *executes* — and every reordering/invisible codepoint except the emoji
/// joiners of [`is_emoji_sequence_char`].
///
/// Borrows when there is nothing to remove, so the common path costs one scan
/// and no allocation: these run on every frame.
pub fn scrub_untrusted_document(text: &str) -> std::borrow::Cow<'_, str> {
    let keep = |ch: char| {
        ch == '\n'
            || ch == '\t'
            || is_emoji_sequence_char(ch)
            || (!ch.is_control() && !is_invisible_formatting_char(ch))
    };
    if text.chars().all(keep) {
        std::borrow::Cow::Borrowed(text)
    } else {
        std::borrow::Cow::Owned(text.chars().filter(|c| keep(*c)).collect())
    }
}

// ─── Rendered-span scrubbing (the tool-output backstop) ──────────────────────
//
// Markdown, syntax and diff each have a single text entry to scrub. The ~15
// tool renderers do not: their untrusted content arrives as a JSON `args` blob
// and a `result` string, and most of them *parse* the JSON before rendering it.
// Scrubbing the raw `args` string would miss the payload entirely, because
// `{"command":"cat ]0;PWNED"}` carries no control character until
// serde decodes those `\u` escapes into real bytes.
//
// So the tool backstop is applied on the far side instead — to the `Line`s the
// renderers produce, at `crate::tools::render_tool`, the one function all three
// call sites go through. That covers every renderer, every parsed field, and
// every renderer added later.
//
// The complication is that a rendered span may *legitimately* contain escapes:
// tool output is autolinked, and an OSC 8 hyperlink is escape bytes by
// construction. Those are already safe — `components::osc8::osc8` percent-
// encodes its URI — so the scrub recognises a well-formed hyperlink wrapper and
// passes it through intact rather than shredding every clickable path in the
// transcript.

/// The OSC 8 introducer, and the String Terminator that closes each half.
const OSC8_OPEN: &str = "\u{1b}]8;;";
const OSC8_ST: &str = "\u{1b}\\";

/// Scrub one **already-rendered span**: drop control characters and reordering
/// codepoints, but carry well-formed OSC 8 hyperlink wrappers through verbatim.
///
/// `\t` is preserved (spans that carry tab-indented file bodies would otherwise
/// lose their indentation); `\r`, `\n` and every escape introducer that is not
/// the start of a complete hyperlink wrapper are dropped, since a span is one
/// row and any of those corrupts the row and everything after it.
///
/// Borrows unchanged text, so the overwhelmingly common escape-free span costs
/// a scan and no allocation.
pub fn scrub_rendered_span(text: &str) -> std::borrow::Cow<'_, str> {
    let benign = |ch: char| {
        ch == '\t'
            || is_emoji_sequence_char(ch)
            || (!ch.is_control() && !is_invisible_formatting_char(ch))
    };
    if text.chars().all(benign) {
        return std::borrow::Cow::Borrowed(text);
    }

    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while !rest.is_empty() {
        // A complete `ESC ]8;; … ESC \` run is a hyperlink we emitted; keep it.
        if let Some(tail) = rest.strip_prefix(OSC8_OPEN) {
            if let Some(end) = tail.find(OSC8_ST) {
                out.push_str(&rest[..OSC8_OPEN.len() + end + OSC8_ST.len()]);
                rest = &tail[end + OSC8_ST.len()..];
                continue;
            }
        }
        let ch = rest.chars().next().expect("non-empty");
        if benign(ch) {
            out.push(ch);
        }
        rest = &rest[ch.len_utf8()..];
    }
    std::borrow::Cow::Owned(out)
}

/// Apply [`scrub_rendered_span`] to every span of every line, in place.
///
/// The backstop for `crate::tools::render_tool`. Styles are untouched — this
/// only rewrites span *content*, so a renderer's colors, backgrounds and
/// gutters come through exactly as they were built.
pub fn scrub_rendered_lines(lines: &mut [ratatui::text::Line<'static>]) {
    for line in lines.iter_mut() {
        for span in line.spans.iter_mut() {
            if let std::borrow::Cow::Owned(clean) = scrub_rendered_span(span.content.as_ref()) {
                span.content = std::borrow::Cow::Owned(clean);
            }
        }
    }
}

// ─── OSC 8 URI escaping ──────────────────────────────────────────────────────

/// Percent-encode `uri` so it is safe as the payload of an OSC 8 hyperlink.
///
/// Stripping ESC is *not* sufficient here, and this is the one place where the
/// character policy above would have been the wrong tool. The hyperlink escape
/// is `ESC ]8;;URI ESC\`, so the URI sits inside an open OSC string: a raw
/// `BEL` (`\x07`) closes that string early on every terminal, and so does a C1
/// `ST` (`\u{9C}`). Whatever follows is no longer a URI — it is the next
/// command the terminal runs. `[click](http://x\x07<payload>)` is a working
/// injection through a link the model chose.
///
/// The OSC 8 specification's own rule is the fix: the URI may contain only
/// bytes in the printable ASCII range, and everything else must be
/// percent-encoded. That is what this does, over *bytes* so multi-byte UTF-8 is
/// encoded per byte as URI syntax requires. Space is encoded too (a literal
/// space is not legal in a URI). `%` is left alone so already-encoded URLs —
/// everything [`super::super::components::osc8::path_to_file_url`] produces —
/// pass through byte-identical.
pub fn sanitize_osc_uri(uri: &str) -> std::borrow::Cow<'_, str> {
    let safe = |b: u8| (0x21..=0x7E).contains(&b);
    if uri.bytes().all(safe) {
        return std::borrow::Cow::Borrowed(uri);
    }
    let mut out = String::with_capacity(uri.len());
    for b in uri.bytes() {
        if safe(b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    std::borrow::Cow::Owned(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The Trojan Source shape: an `RLO` makes the tail render right-to-left, so
    /// a destructive command can read as a harmless one. Scrubbing must leave
    /// the codepoints that decide reading order out of the string entirely.
    #[test]
    fn bidi_overrides_are_stripped_from_a_line() {
        let hostile = "rm -rf /\u{202E}# ohce";
        let scrubbed = scrub_untrusted_line(hostile);

        assert!(
            !scrubbed.chars().any(is_invisible_formatting_char),
            "no reordering codepoint may survive: {scrubbed:?}"
        );
        assert_eq!(scrubbed, "rm -rf /# ohce");
    }

    /// Every override, embedding and isolate — the full Trojan Source set.
    #[test]
    fn the_whole_trojan_source_family_is_covered() {
        for ch in [
            '\u{202A}', '\u{202B}', '\u{202C}', '\u{202D}', '\u{202E}', // embeddings/overrides
            '\u{2066}', '\u{2067}', '\u{2068}', '\u{2069}', // isolates
            '\u{200E}', '\u{200F}', '\u{061C}', // marks
        ] {
            assert!(
                is_invisible_formatting_char(ch),
                "U+{:04X} must be treated as invisible formatting",
                ch as u32
            );
            assert_eq!(
                scrub_untrusted_line(&format!("a{ch}b")),
                "ab",
                "U+{:04X} must be scrubbed",
                ch as u32
            );
        }
    }

    /// Escape introducers must never survive into a rendered span — a raw ESC
    /// lets untrusted text drive the terminal directly.
    #[test]
    fn control_characters_are_stripped_from_a_line() {
        assert_eq!(scrub_untrusted_line("safe\x1b]0;pwn\x07tail"), "safe]0;pwntail");
        assert_eq!(scrub_untrusted_line("a\tb\nc\rd"), "abcd");
    }

    /// Ordinary text — including non-Latin scripts and emoji — is untouched.
    /// Over-scrubbing would be its own defect: the operator must still be able
    /// to read the command.
    #[test]
    fn legitimate_text_survives_unchanged() {
        for s in [
            "rm -rf /tmp/build",
            "git commit -m \"fix: 漢字とemoji 🎉\"",
            "/Users/rhl/projects/osa/priv/rust/tui",
            "grep -rn 'a|b' --include=*.rs .",
        ] {
            assert_eq!(scrub_untrusted_line(s), s, "must pass through unchanged: {s:?}");
        }
    }

    /// The block variant keeps line structure but nothing else.
    #[test]
    fn the_block_variant_keeps_newlines_only() {
        assert_eq!(scrub_untrusted_block("one\ntwo\tthree\rfour"), "one\ntwothreefour");
        assert_eq!(scrub_untrusted_block("a\u{202E}b\nc"), "ab\nc");
    }

    /// The document variant keeps the two whitespace characters the rich
    /// renderers are built on, and nothing else.
    #[test]
    fn the_document_variant_keeps_newline_and_tab_only() {
        assert_eq!(
            &*scrub_untrusted_document("a\n\tb\rc\u{1b}d\u{7}e"),
            "a\n\tbcde"
        );
        assert_eq!(&*scrub_untrusted_document("rm -rf /\u{202E}# ohce"), "rm -rf /# ohce");
    }

    /// Emoji joiners and variation selectors are invisible but not dangerous:
    /// they cannot reorder text or close an escape. Stripping them from prose
    /// would split one glyph into several — over-scrubbing is its own defect.
    #[test]
    fn the_document_variant_preserves_emoji_sequences() {
        for s in ["\u{1F469}\u{200D}\u{1F4BB}", "\u{2764}\u{FE0F}"] {
            assert_eq!(&*scrub_untrusted_document(s), s);
        }
        // …while the reordering codepoints in the same block still go.
        assert_eq!(&*scrub_untrusted_document("a\u{2066}b\u{200E}c"), "abc");
    }

    /// Clean text is borrowed, not rebuilt — these run on every frame.
    #[test]
    fn the_document_variant_borrows_clean_text() {
        assert!(matches!(
            scrub_untrusted_document("fn main() {\n\tok();\n}\n"),
            std::borrow::Cow::Borrowed(_)
        ));
        assert!(matches!(
            scrub_untrusted_document("x\u{1b}y"),
            std::borrow::Cow::Owned(_)
        ));
    }

    /// A URI is interpolated *inside an open OSC string*, so stripping ESC is
    /// not enough — BEL and C1 ST close that string too. Encode, don't strip:
    /// the link must still point where it said it did.
    #[test]
    fn osc_uri_encoding_neutralizes_every_string_terminator() {
        assert_eq!(sanitize_osc_uri("http://x\u{7}y"), "http://x%07y");
        assert_eq!(sanitize_osc_uri("http://x\u{1b}y"), "http://x%1By");
        // C1 ST is two UTF-8 bytes, and URI encoding is per byte.
        assert_eq!(sanitize_osc_uri("http://x\u{9c}y"), "http://x%C2%9Cy");
        assert_eq!(sanitize_osc_uri("http://x y"), "http://x%20y");
    }

    /// An ordinary URL — including one that is already percent-encoded — passes
    /// through byte-identical and unallocated. Double-encoding `%` would break
    /// every file link the app emits.
    #[test]
    fn osc_uri_encoding_leaves_ordinary_urls_alone() {
        for url in [
            "https://example.com/a/b?c=1&d=2#frag",
            "file:///home/x/my%20file.rs",
            "mailto:a@b.co",
        ] {
            assert!(
                matches!(sanitize_osc_uri(url), std::borrow::Cow::Borrowed(_)),
                "clean URL was rewritten: {url:?}"
            );
            assert_eq!(sanitize_osc_uri(url), url);
        }
    }

    /// The rendered-span backstop keeps a complete hyperlink wrapper (those
    /// escapes are ours, and already safe) but not an unterminated one, which is
    /// an open OSC string — i.e. the attack itself.
    #[test]
    fn the_span_backstop_distinguishes_a_hyperlink_from_an_open_osc_string() {
        let link = "\u{1b}]8;;file:///tmp/a.rs\u{1b}\\a.rs\u{1b}]8;;\u{1b}\\";
        assert_eq!(scrub_rendered_span(link), link);

        let open = "\u{1b}]8;;http://x\u{7}payload";
        assert_eq!(scrub_rendered_span(open), "]8;;http://xpayload");

        // Mixed: the link survives, the injection next to it does not.
        let mixed = format!("see {link} and \u{1b}]0;PWNED\u{7}done");
        assert_eq!(
            scrub_rendered_span(&mixed),
            format!("see {link} and ]0;PWNEDdone")
        );
    }

    /// A span is one row, so `\t` is kept (tab-indented file bodies) but `\n`
    /// and `\r` are not — either would corrupt the row and everything under it.
    #[test]
    fn the_span_backstop_keeps_tabs_and_drops_row_breaking_controls() {
        assert_eq!(scrub_rendered_span("a\tb"), "a\tb");
        assert_eq!(scrub_rendered_span("a\nb\rc"), "abc");
        assert!(matches!(
            scrub_rendered_span("ordinary output"),
            std::borrow::Cow::Borrowed(_)
        ));
    }

    #[test]
    fn the_optional_variant_preserves_none() {
        assert_eq!(scrub_untrusted_line_opt(None), None);
        assert_eq!(
            scrub_untrusted_line_opt(Some("dele\u{202E}te".to_string())),
            Some("delete".to_string())
        );
    }
}

