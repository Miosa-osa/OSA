// Phase 2+: format_size() and truncate_str_start() — wired when file picker and sidebar use them
#![allow(dead_code)]

pub mod fuzzy;

/// Fit `s` into at most `max_cols` DISPLAY COLUMNS, appending `…` (1 column) when
/// it does not fit.
///
/// **This is the canonical column-fitter — prefer it for anything laid out against
/// a terminal width.** The two tempting alternatives are both wrong for non-ASCII:
///
///   * [`truncate_str`] takes **bytes**. Comparing `s.len()` to a column budget
///     cuts CJK/emoji text to roughly a third of the space it was given, leaving a
///     large empty gutter (this is why session titles and filenames looked broken).
///   * `.chars().count()` treats every char as 1 column, so wide glyphs OVERFLOW
///     the reserved span and get hard-clipped by the renderer, shoving neighbouring
///     columns off-screen.
///
/// Wide chars are counted at their true 2-column advance, so the result never
/// overflows `max_cols`.
pub fn fit_cols(s: &str, max_cols: usize) -> String {
    use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};
    if UnicodeWidthStr::width(s) <= max_cols {
        return s.to_string();
    }
    if max_cols == 0 {
        return String::new();
    }
    let budget = max_cols - 1; // reserve 1 column for the ellipsis
    let mut out = String::new();
    let mut acc = 0usize;
    for ch in s.chars() {
        let cw = UnicodeWidthChar::width(ch).unwrap_or(0);
        if acc + cw > budget {
            break;
        }
        out.push(ch);
        acc += cw;
    }
    out.push('\u{2026}');
    out
}

/// Display width of `s` in terminal columns (wide glyphs count as 2).
pub fn cols(s: &str) -> usize {
    unicode_width::UnicodeWidthStr::width(s)
}

/// Strip the inline-markdown emphasis markers the model routinely writes into
/// short backend-supplied strings (todo subjects, task titles) that are rendered
/// as PLAIN styled spans rather than through the markdown renderer — otherwise a
/// literal `**Add a new page**` shows up on screen.
///
/// Deliberately conservative: only paired `**`, `__` and backticks are removed.
/// Single `*` / `_` are left alone because they legitimately appear in globs and
/// filenames (`*.tsx`, `snake_case`), where stripping would corrupt the text.
pub fn strip_inline_markdown(s: &str) -> String {
    let mut out = s.replace("**", "").replace("__", "");
    if out.contains('`') {
        out = out.replace('`', "");
    }
    out
}

/// Truncate a UTF-8 string to at most `max_bytes` bytes, ensuring the cut falls
/// on a char boundary so the result is always valid UTF-8.
///
/// **Byte-oriented — do not use for terminal layout.** Use [`fit_cols`] when the
/// budget is a column count.
pub fn truncate_str(s: &str, max_bytes: usize) -> &str {
    if s.len() <= max_bytes {
        return s;
    }
    let mut idx = max_bytes.min(s.len());
    while idx > 0 && !s.is_char_boundary(idx) {
        idx -= 1;
    }
    &s[..idx]
}

/// Format an elapsed duration (in seconds) compactly and identically across the
/// live spinner, agents panel, dashboard, teammate-finished chat lines,
/// background completions, and the turn recap: `45s → 2m 15s → 1h 3m` (spaced,
/// non-zero-padded, trailing zero units dropped — `2m`, `1h`; Claude Code's
/// formatDuration style). This is the ONLY duration formatter — every surface
/// must call it so the spinner→recap transition never renders the same
/// duration two different ways (`2m 15s` vs `2m15s`).
pub fn fmt_elapsed(secs: u64) -> String {
    if secs < 60 {
        format!("{}s", secs)
    } else if secs < 3600 {
        let (m, s) = (secs / 60, secs % 60);
        if s == 0 {
            format!("{}m", m)
        } else {
            format!("{}m {}s", m, s)
        }
    } else {
        let (h, m) = (secs / 3600, (secs % 3600) / 60);
        if m == 0 {
            format!("{}h", h)
        } else {
            format!("{}h {}m", h, m)
        }
    }
}

/// Wall-clock threshold (seconds) above which a turn with zero substantive
/// tool calls still earns a "✻ Worked for …" recap line. Compared with `>=`
/// against whole (floored) seconds, so the first qualifying display is exactly
/// "Worked for 10s" — the same number the user just watched the spinner show.
pub const RECAP_ELAPSED_THRESHOLD_SECS: u64 = 10;

/// True for internal bookkeeping tools that fire automatically (memory
/// persistence / recall, session history search) and therefore must NOT, on
/// their own, trigger the end-of-turn "✻ Worked for …" recap. Without this
/// gate a trivial reply like "Yeah?" still prints "Worked for 3s · 1 tool use"
/// because a memory tool auto-fired. Everything else — shell_execute,
/// file_read/write/edit, web_search/fetch, dir_list, git, … — is substantive,
/// user-visible work and counts toward the recap. The server applies the same
/// filter (Telemetry.internal_tool?/1) before counting; this client copy is
/// defense-in-depth for legacy payloads that only carry the name list.
pub fn is_internal_tool(name: &str) -> bool {
    let n = name.trim().to_ascii_lowercase();
    n.starts_with("memory")
        || matches!(n.as_str(), "session_search" | "session_recall" | "recall")
}

/// Count the substantive (user-visible) tools in a turn's tool list, excluding
/// internal bookkeeping tools (see [`is_internal_tool`]).
pub fn substantive_tool_count<S: AsRef<str>>(tools: &[S]) -> usize {
    tools
        .iter()
        .filter(|t| !is_internal_tool(t.as_ref()))
        .count()
}

/// Take the last `max_bytes` bytes of a UTF-8 string, advancing the start
/// index forward until it lands on a char boundary.
pub fn truncate_str_start(s: &str, max_bytes: usize) -> &str {
    if s.len() <= max_bytes {
        return s;
    }
    let start = s.len() - max_bytes;
    let mut idx = start;
    while idx < s.len() && !s.is_char_boundary(idx) {
        idx += 1;
    }
    &s[idx..]
}

/// Argument keys, in priority order, that actually IDENTIFY a tool call. The
/// first one present wins. Ordered so the most specific identifier (the file a
/// file-tool touches, the command a shell runs) beats a generic free-text field.
const IDENTIFYING_ARG_KEYS: &[&str] = &[
    "path",
    "file_path",
    "filename",
    "target_file",
    "file",
    "notebook_path",
    "command",
    "cmd",
    "question",
    "skill_name",
    "agent_name",
    "subagent_type",
    "agent",
    "name",
    "pattern",
    "query",
    "url",
    "task",
    "title",
    "subject",
    "description",
    "prompt",
    "message",
    "text",
];

/// Reduce a backend argument hint to something worth showing next to a tool name.
///
/// Three inputs have to be handled, because the backend sends all three:
///
///   * a plain display string (`"cargo test"`, `"/src/main.rs"`) — passed through;
///   * a JSON blob (file-edit calls ship their full args so the diff renderer can
///     work) — reduced to the single identifying value, because dumping
///     `{"new_string":"  @doc \"Start…` into the live feed tells the user nothing
///     about WHICH file is being edited;
///   * a list of schema PARAMETER NAMES (`"options, question"`) from the
///     backend's old key-name fallback — dropped entirely, see
///     [`crate::components::activity`]'s guard.
///
/// Returns an empty string when nothing identifying could be recovered — an
/// empty detail is strictly better than schema noise or raw JSON.
pub fn arg_summary(hint: &str) -> String {
    let hint = hint.trim();
    if !(hint.starts_with('{') || hint.starts_with('[')) {
        return hint.to_string();
    }

    let Ok(value) = serde_json::from_str::<serde_json::Value>(hint) else {
        // Malformed / truncated JSON — never show the fragment.
        return String::new();
    };

    // A fan-out array (e.g. delegate's `tasks`): summarize the first entry.
    let obj = match &value {
        serde_json::Value::Object(map) => map,
        serde_json::Value::Array(items) => match items.first() {
            Some(serde_json::Value::Object(map)) => map,
            _ => return String::new(),
        },
        _ => return String::new(),
    };

    for key in IDENTIFYING_ARG_KEYS {
        match obj.get(*key) {
            Some(serde_json::Value::String(s)) if !s.trim().is_empty() => {
                return s.trim().to_string()
            }
            Some(serde_json::Value::Number(n)) => return n.to_string(),
            _ => {}
        }
    }

    String::new()
}

/// Fit an argument summary into `max_cols` display columns. Paths keep their
/// TAIL (the filename is what identifies the file); everything else keeps its
/// head. Always width-aware — never cuts by bytes or chars.
pub fn fit_arg_summary(summary: &str, max_cols: usize) -> String {
    if cols(summary) <= max_cols {
        return summary.to_string();
    }
    if summary.contains('/') && !summary.contains(' ') {
        ellipsize_path_middle(summary, max_cols)
    } else {
        fit_cols(summary, max_cols)
    }
}

/// Middle-ellipsize a path to at most `max_cols` DISPLAY columns, preserving the
/// final path segment (the filename) — Claude Code `truncatePathMiddle` parity.
/// `src/components/deeply/nested/MyComponent.tsx` -> `src/components/…/MyComponent.tsx`.
/// Width-aware (unicode_width) and never splits a char. Falls back to a tail-only
/// `…name` when the filename alone won't fit.
pub fn ellipsize_path_middle(path: &str, max_cols: usize) -> String {
    use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};
    if path.width() <= max_cols {
        return path.to_string();
    }
    if max_cols <= 1 {
        return "\u{2026}".to_string();
    }
    let (dir, file) = match path.rfind('/') {
        Some(i) => (&path[..i], &path[i..]), // keep the leading '/' with the filename
        None => ("", path),
    };
    let file_w = file.width();
    // Filename alone doesn't fit → keep the tail end, prefixed with an ellipsis.
    if file_w + 1 >= max_cols {
        let budget = max_cols.saturating_sub(1);
        let mut kept = String::new();
        let mut w = 0usize;
        for ch in path.chars().rev() {
            let cw = UnicodeWidthChar::width(ch).unwrap_or(0);
            if w + cw > budget {
                break;
            }
            kept.push(ch);
            w += cw;
        }
        let tail: String = kept.chars().rev().collect();
        return format!("\u{2026}{}", tail);
    }
    let avail_for_dir = max_cols - 1 - file_w; // -1 for the ellipsis
    let mut kept = String::new();
    let mut w = 0usize;
    for ch in dir.chars() {
        let cw = UnicodeWidthChar::width(ch).unwrap_or(0);
        if w + cw > avail_for_dir {
            break;
        }
        kept.push(ch);
        w += cw;
    }
    format!("{}\u{2026}{}", kept, file)
}

/// Fit a URL into `max_cols` display columns while keeping the parts that
/// IDENTIFY it: the host and the tail of the path.
///
/// The scheme carries no information for the operator, so it is dropped first
/// (`https://docs.rs/x` -> `docs.rs/x`); a trailing `/` goes too. If the result
/// still doesn't fit, the MIDDLE of the path is elided so both the host at the
/// head and the last segment at the tail survive — a plain head-truncation
/// would leave `https://gith…`, which names neither the site nor the page.
/// When even the host doesn't fit, the tail wins (`…/servers`).
pub fn ellipsize_url(url: &str, max_cols: usize) -> String {
    let stripped = url
        .strip_prefix("https://")
        .or_else(|| url.strip_prefix("http://"))
        .unwrap_or(url);
    // A bare host keeps its trailing slash off: "bestmcp.dev/" -> "bestmcp.dev".
    let stripped = stripped.strip_suffix('/').unwrap_or(stripped);
    if cols(stripped) <= max_cols {
        return stripped.to_string();
    }
    ellipsize_path_middle(stripped, max_cols)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn truncate_str_never_splits_a_char() {
        // "€" is 3 bytes; every non-multiple-of-3 limit lands mid-char.
        let s = "\u{20ac}\u{20ac}\u{20ac}\u{20ac}"; // 12 bytes, 4 chars
        for limit in 0..=13 {
            let out = truncate_str(s, limit);
            assert!(s.starts_with(out));
            assert!(out.len() <= limit.min(s.len()));
            // Result is always valid UTF-8 (guaranteed by &str), and a prefix.
        }
    }

    #[test]
    fn ellipsize_url_drops_the_scheme_and_keeps_host_plus_tail() {
        assert_eq!(ellipsize_url("https://bestmcp.dev/", 40), "bestmcp.dev");
        assert_eq!(
            ellipsize_url("https://github.com/modelcontextprotocol/servers", 60),
            "github.com/modelcontextprotocol/servers"
        );
        let long = "https://example.com/a/very/deeply/nested/path/final-page.html";
        let out = ellipsize_url(long, 30);
        assert!(cols(&out) <= 30, "over budget: {out}");
        assert!(out.starts_with("example.com"), "host lost: {out}");
        assert!(out.ends_with("final-page.html"), "tail lost: {out}");
    }

    #[test]
    fn truncate_str_returns_whole_when_under_limit() {
        assert_eq!(truncate_str("abc", 100), "abc");
        assert_eq!(truncate_str("", 0), "");
    }

    #[test]
    fn truncate_str_start_never_splits_a_char() {
        let s = "a\u{20ac}\u{20ac}\u{20ac}\u{20ac}"; // 1 + 12 = 13 bytes
        for limit in 0..=14 {
            let out = truncate_str_start(s, limit);
            assert!(s.ends_with(out));
        }
    }

    #[test]
    fn fmt_elapsed_matches_spinner_style() {
        assert_eq!(fmt_elapsed(0), "0s");
        assert_eq!(fmt_elapsed(45), "45s");
        assert_eq!(fmt_elapsed(60), "1m");
        assert_eq!(fmt_elapsed(135), "2m 15s");
        assert_eq!(fmt_elapsed(3600), "1h");
        assert_eq!(fmt_elapsed(3780), "1h 3m");
        assert_eq!(fmt_elapsed(9180), "2h 33m");
    }

    #[test]
    fn internal_tools_do_not_count_as_substantive() {
        assert!(is_internal_tool("memory_save"));
        assert!(is_internal_tool("memory_recall"));
        assert!(is_internal_tool("session_search"));
        assert!(is_internal_tool(" Session_Search "));
        assert!(!is_internal_tool("shell_execute"));
        assert!(!is_internal_tool("file_read"));
        assert_eq!(
            substantive_tool_count(&["memory_save", "session_search", "shell_execute"]),
            1
        );
    }

    #[test]
    fn truncate_str_handles_large_paste_boundary() {
        // Mirror the paste-cap use: a big multi-byte blob capped at an arbitrary
        // byte limit must never panic and must stay a valid prefix.
        let big = "x".repeat(50) + &"\u{1f600}".repeat(1000); // emoji = 4 bytes
        for limit in [1usize, 49, 50, 51, 100_000, big.len()] {
            let out = truncate_str(&big, limit);
            assert!(big.starts_with(out));
        }
    }

    // ── arg_summary: what the tool cell actually shows ──────────────────
    //
    // Three shapes reached the screen and none was useful: schema PARAMETER
    // NAMES ("options, question"), a raw JSON dump of the whole argument map,
    // and an unshortened path whose filename fell off the right edge.

    #[test]
    fn arg_summary_passes_plain_strings_through() {
        assert_eq!(arg_summary("cargo test --release"), "cargo test --release");
        assert_eq!(arg_summary("/src/main.rs"), "/src/main.rs");
        assert_eq!(arg_summary("  spaced  "), "spaced");
        assert_eq!(arg_summary(""), "");
    }

    #[test]
    fn arg_summary_reduces_file_edit_json_to_the_path() {
        // The backend ships the whole arg map so the diff renderer can work.
        // The live feed must show the FILE, not `{"new_string":"  @doc \"…`.
        let json = r#"{"new_string":"  @doc \"Start the Compactor GenServer.\"\n","old_string":"x","path":"/src/compactor.ex","replace_all":false}"#;
        assert_eq!(arg_summary(json), "/src/compactor.ex");
    }

    #[test]
    fn arg_summary_prefers_the_identifying_key_over_free_text() {
        let json = r#"{"description":"a long prose description","path":"/src/main.rs"}"#;
        assert_eq!(arg_summary(json), "/src/main.rs");

        let json = r#"{"prompt":"go do the thing","name":"smoke-e2e"}"#;
        assert_eq!(arg_summary(json), "smoke-e2e");
    }

    #[test]
    fn arg_summary_handles_a_fan_out_array() {
        let json = r#"[{"prompt":"first worker","subagent_type":"explorer"}]"#;
        assert_eq!(arg_summary(json), "explorer");
    }

    #[test]
    fn arg_summary_drops_json_it_cannot_identify_or_parse() {
        // A cut-off JSON fragment must never be shown.
        assert_eq!(arg_summary(r#"{"new_string":"  @doc \"Start the Comp"#), "");
        // Parseable, but nothing identifying in it.
        assert_eq!(arg_summary(r#"{"replace_all":true,"dry_run":false}"#), "");
    }

    #[test]
    fn fit_arg_summary_keeps_the_filename_of_a_long_path() {
        let path =
            "/home/user/projects/osa/OSA/lib/optimal_system_agent/agent/loop/tool_executor.ex";
        let fitted = fit_arg_summary(path, 40);
        assert!(cols(&fitted) <= 40, "overflowed: {fitted:?}");
        assert!(
            fitted.ends_with("tool_executor.ex"),
            "the filename is the part that identifies the file: {fitted:?}"
        );
    }

    #[test]
    fn fit_arg_summary_keeps_the_head_of_prose_and_commands() {
        let cmd = "cargo test --release --workspace --all-features -- --nocapture";
        let fitted = fit_arg_summary(cmd, 20);
        assert!(cols(&fitted) <= 20, "overflowed: {fitted:?}");
        assert!(fitted.starts_with("cargo test"), "{fitted:?}");
    }

    #[test]
    fn fit_arg_summary_is_width_aware_not_byte_aware() {
        // Wide glyphs advance two columns each.
        let wide = "\u{5EFA}\u{7ACB}\u{89E3}\u{6790}\u{5668}\u{6D4B}\u{8BD5}";
        for max in 1usize..=16 {
            let fitted = fit_arg_summary(wide, max);
            assert!(
                cols(&fitted) <= max,
                "max={max} produced {fitted:?} at {} cols",
                cols(&fitted)
            );
        }
    }

    #[test]
    fn fit_arg_summary_leaves_short_values_untouched() {
        assert_eq!(fit_arg_summary("smoke-e2e", 60), "smoke-e2e");
    }
}
