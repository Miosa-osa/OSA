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
///
/// The break point is a GRAPHEME CLUSTER, never a `char`. Cutting between chars
/// splits user-perceived glyphs: half a regional-indicator flag renders as a
/// stray boxed letter, and a cut inside an emoji ZWJ sequence turns 👨‍👩‍👧 into two
/// unrelated people. (Zero-width combining marks happen to survive char
/// iteration because they never trip the budget check — clusters whose parts
/// both have width are the ones that break.) `render/diff.rs` already segments
/// this way; this is the same rule.
pub fn fit_cols(s: &str, max_cols: usize) -> String {
    use unicode_segmentation::UnicodeSegmentation;
    use unicode_width::UnicodeWidthStr;
    if UnicodeWidthStr::width(s) <= max_cols {
        return s.to_string();
    }
    if max_cols == 0 {
        return String::new();
    }
    let budget = max_cols - 1; // reserve 1 column for the ellipsis
    let mut out = String::new();
    let mut acc = 0usize;
    for g in s.graphemes(true) {
        // Width of the whole cluster, not of its first char: a base + combining
        // mark is one cell, and an emoji ZWJ sequence is two.
        let gw = UnicodeWidthStr::width(g);
        if acc + gw > budget {
            break;
        }
        out.push_str(g);
        acc += gw;
    }
    out.push('\u{2026}');
    out
}

/// Display width of `s` in terminal columns (wide glyphs count as 2).
pub fn cols(s: &str) -> usize {
    unicode_width::UnicodeWidthStr::width(s)
}

/// Spaces needed to pad `s` out to `width` DISPLAY COLUMNS.
///
/// **Use this, never `width - s.chars().count()` and never `width - s.len()`.**
/// A pad computed from a char count leaves a wide glyph occupying two columns
/// where one was reserved, so everything to its right is pushed over and the
/// trailing badge/timestamp falls off the pane; a pad computed from bytes
/// over-counts non-ASCII and collapses the column instead.
pub fn pad_width(s: &str, width: usize) -> usize {
    width.saturating_sub(cols(s))
}

/// Fit `s` to `width` DISPLAY COLUMNS and right-pad it with spaces so the result
/// occupies exactly `width` columns — the left-aligned column primitive.
pub fn pad_cols(s: &str, width: usize) -> String {
    let t = fit_cols(s, width);
    let pad = pad_width(&t, width);
    if pad == 0 {
        return t;
    }
    let mut out = String::with_capacity(t.len() + pad);
    out.push_str(&t);
    out.push_str(&" ".repeat(pad));
    out
}

/// Fit `s` to `width` DISPLAY COLUMNS and LEFT-pad it with spaces — the
/// right-aligned column primitive (tags, counts, timestamps).
pub fn pad_cols_start(s: &str, width: usize) -> String {
    let t = fit_cols(s, width);
    let pad = pad_width(&t, width);
    if pad == 0 {
        return t;
    }
    let mut out = String::with_capacity(t.len() + pad);
    out.push_str(&" ".repeat(pad));
    out.push_str(&t);
    out
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

/// Rewrite an absolute path into the shortest form that still IDENTIFIES it to
/// the reader.
///
/// Trail rows in the fleet roster were rendering fully-qualified paths
/// (`/Users/rhl/.osa/workspace/codex/codex-rs/hooks`), so three sibling rows spent
/// ~40 of their columns repeating a prefix that carries no information — the
/// differing tail, the only part the eye needs, was pushed to the far right or
/// truncated away entirely.
///
/// Applied in order, first match wins:
///   1. under `workspace_root` (the session's own cwd) → strip it, so paths read
///      the way the user would type them;
///   2. under the agent sandbox `<home>/.osa/workspace/` → strip it, leaving the
///      checkout name as the leading segment (`codex/codex-rs/hooks`). Sub-agents
///      work here, not in the TUI's cwd, so rule 1 alone never fires for them;
///   3. under `home` → `~/…`.
///
/// A path matching nothing is returned untouched: this shortens, it never lies.
/// The prefix must land on a `/` boundary, so `/Users/rhl2` is not treated as
/// living under `/Users/rhl`.
pub fn display_path(path: &str, workspace_root: Option<&str>, home: Option<&str>) -> String {
    fn under<'a>(path: &'a str, root: &str) -> Option<&'a str> {
        let root = root.trim_end_matches('/');
        if root.is_empty() {
            return None;
        }
        let rest = path.strip_prefix(root)?;
        // Boundary check: `/a/b` is under `/a`, `/ab` is not.
        match rest.strip_prefix('/') {
            Some(tail) if !tail.is_empty() => Some(tail),
            _ => None,
        }
    }

    let p = path.trim();
    if !p.starts_with('/') && !p.starts_with('~') {
        return p.to_string();
    }
    if let Some(root) = workspace_root {
        if let Some(rest) = under(p, root) {
            return rest.to_string();
        }
    }
    if let Some(h) = home {
        let sandbox = format!("{}/.osa/workspace", h.trim_end_matches('/'));
        if let Some(rest) = under(p, &sandbox) {
            return rest.to_string();
        }
        if let Some(rest) = under(p, h) {
            return format!("~/{}", rest);
        }
    }
    p.to_string()
}

/// Minimum shared prefix, in COLUMNS, worth eliding from a sibling row.
///
/// Below this the `…/` marker costs as much as it saves and the row just looks
/// mangled for no gain.
const ELIDE_MIN_COLS: usize = 6;

/// Collapse the leading directory components a trail row shares with the row
/// directly above it into a single `…/`.
///
/// Three consecutive `dir_list: <same 34 columns>/<one different word>` rows read
/// as one smear; the reader has to scan to column 40 on every line to find the
/// only part that differs. Eliding the shared head puts the differing tail at a
/// fixed, shallow column:
///
/// ```text
///   dir_list: codex/codex-rs/hooks
///   dir_list: …/sandboxing
///   dir_list: …/exec-server
/// ```
///
/// Deliberately conservative — it only fires when
///   * both rows are `verb: value` shaped and the VERBS are identical (otherwise
///     the elision would hide which tool ran), and
///   * the shared part ends on a `/` boundary and is at least
///     [`ELIDE_MIN_COLS`] columns wide, and
///   * a non-empty tail survives.
///
/// Anything else returns `cur` unchanged. Comparison is by `char`, and the cut is
/// taken at a `/` boundary, so this can never split a multi-byte grapheme.
pub fn elide_shared_prefix(prev: &str, cur: &str) -> String {
    let Some((pv, pa)) = prev.split_once(':') else {
        return cur.to_string();
    };
    let Some((cv, ca)) = cur.split_once(':') else {
        return cur.to_string();
    };
    if pv.trim() != cv.trim() {
        return cur.to_string();
    }
    let (pa, ca) = (pa.trim(), ca.trim());
    if pa.is_empty() || ca.is_empty() {
        return cur.to_string();
    }

    // Longest common prefix, cut back to the last `/` inside it.
    let common: usize = pa
        .char_indices()
        .zip(ca.char_indices())
        .take_while(|((_, a), (_, b))| a == b)
        .map(|((i, c), _)| i + c.len_utf8())
        .last()
        .unwrap_or(0);
    let Some(cut) = ca[..common].rfind('/') else {
        return cur.to_string();
    };
    let head = &ca[..=cut];
    let tail = &ca[cut + 1..];
    if tail.is_empty() || cols(head) < ELIDE_MIN_COLS {
        return cur.to_string();
    }
    format!("{}: \u{2026}/{}", cv.trim(), tail)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Shared assertion for the grapheme-cluster tests: `out` must be a prefix of
    // `s` cut only at CLUSTER boundaries (plus the trailing ellipsis), and must
    // fit the column budget. Restores the helper the cluster tests share.
    fn assert_whole_cluster_prefix(s: &str, out: &str, budget: usize) {
        use unicode_segmentation::UnicodeSegmentation;

        assert!(
            cols(out) <= budget,
            "overflowed budget {budget}: {out:?}"
        );

        let body = out.strip_suffix('\u{2026}').unwrap_or(out);

        // Every cluster emitted must be a whole cluster of the input, in order.
        let src: Vec<&str> = s.graphemes(true).collect();
        let got: Vec<&str> = body.graphemes(true).collect();

        assert!(
            got.len() <= src.len(),
            "emitted more clusters than the input had: {out:?}"
        );

        for (i, g) in got.iter().enumerate() {
            assert_eq!(
                *g, src[i],
                "cluster {i} was split or altered at budget {budget}: {out:?}"
            );
        }
    }

    // NOTE on halfwidth kana: ｶ + U+FF9E VOICED SOUND MARK is one cluster, but
    // unicode-width reports the sound mark as ZERO columns, so a char-wise walk
    // never stops between them — that case cannot actually be split and has no
    // test here. The clusters that DO break are the ones whose parts each have
    // non-zero width: regional-indicator flags and emoji ZWJ sequences, below.
    #[test]
    fn fit_cols_never_splits_a_regional_indicator_flag() {
        // A flag is TWO regional indicators forming one cluster, and unlike a
        // combining mark both halves have non-zero width — so a char-wise walk
        // really does stop between them and render half a flag as a stray boxed
        // letter. This is the same class of bug as the ZWJ case below.
        let flag = "\u{1F1EF}\u{1F1F5}"; // 🇯🇵
        let s = format!("ab{flag}cd");
        for budget in 3..=9 {
            assert_whole_cluster_prefix(&s, &fit_cols(&s, budget), budget);
        }
    }

    // Regression guard, not a discriminator: a zero-width combining mark is
    // already safe under char iteration (width 0 never trips the budget check),
    // so this passed before the grapheme fix too. It is kept so a future
    // "optimization" back to chars — or a width table change — cannot silently
    // start orphaning accents.
    #[test]
    fn fit_cols_keeps_combining_marks_with_their_base() {
        let s = "abce\u{0301}defg";
        for budget in 1..=8 {
            assert_whole_cluster_prefix(s, &fit_cols(s, budget), budget);
        }
    }

    #[test]
    fn fit_cols_never_cuts_inside_an_emoji_zwj_sequence() {
        // Family emoji: 4 people joined by ZWJ = ONE grapheme cluster.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
        let s = format!("ab{family}cd");
        // The sequence is either kept whole or dropped whole — never half of it.
        // Char-wise iteration keeps "man + ZWJ + woman" and drops the girl,
        // which renders as two unrelated people.
        for budget in 3..=9 {
            let out = fit_cols(&s, budget);
            assert!(
                !out.contains('\u{1F468}') || out.contains(family),
                "ZWJ sequence split at budget {budget}: {out:?}"
            );
            assert!(
                !out.ends_with("\u{200D}\u{2026}"),
                "cut left a dangling ZWJ at budget {budget}: {out:?}"
            );
            assert!(cols(&out) <= budget);
        }
    }

    #[test]
    fn fit_cols_still_respects_the_column_budget_and_short_circuits() {
        assert_eq!(fit_cols("short", 10), "short");
        assert_eq!(fit_cols("anything", 0), "");
        assert!(cols(&fit_cols("日本語のテキストです", 7)) <= 7);
        assert!(fit_cols("abcdefghij", 5).ends_with('\u{2026}'));
        assert!(cols(&fit_cols("abcdefghij", 5)) <= 5);
    }

    #[test]
    fn display_path_prefers_the_workspace_root_then_sandbox_then_home() {
        let home = Some("/Users/rhl");
        // 1. session cwd wins.
        assert_eq!(
            display_path("/Users/rhl/projects/osa/src/lib.rs", Some("/Users/rhl/projects/osa"), home),
            "src/lib.rs"
        );
        // 2. agent sandbox — the sub-agent case the roster actually shows.
        assert_eq!(
            display_path("/Users/rhl/.osa/workspace/codex/codex-rs/hooks", None, home),
            "codex/codex-rs/hooks"
        );
        // 3. plain home.
        assert_eq!(display_path("/Users/rhl/notes.md", None, home), "~/notes.md");
        // Nothing matches → untouched, never a lie.
        assert_eq!(display_path("/etc/hosts", None, home), "/etc/hosts");
        // Sibling directory is NOT under the root (boundary must be `/`).
        assert_eq!(display_path("/Users/rhl2/x", None, home), "/Users/rhl2/x");
        // The root itself has no tail to show; left alone.
        assert_eq!(display_path("/Users/rhl", None, home), "/Users/rhl");
        // Relative paths pass straight through.
        assert_eq!(display_path("src/main.rs", Some("/Users/rhl"), home), "src/main.rs");
    }

    #[test]
    fn elide_shared_prefix_collapses_sibling_directories() {
        let a = "dir_list: codex/codex-rs/hooks";
        let b = "dir_list: codex/codex-rs/sandboxing";
        assert_eq!(elide_shared_prefix(a, b), "dir_list: \u{2026}/sandboxing");
    }

    #[test]
    fn elide_shared_prefix_refuses_when_it_would_hide_information() {
        // Different verbs — eliding would hide which tool ran.
        assert_eq!(
            elide_shared_prefix("dir_list: a/b/c", "file_read: a/b/d"),
            "file_read: a/b/d"
        );
        // No shared directory component.
        assert_eq!(elide_shared_prefix("dir_list: a/x", "dir_list: b/y"), "dir_list: b/y");
        // Shared head too short to be worth a marker ("a/" is 2 cols).
        assert_eq!(elide_shared_prefix("dir_list: a/x", "dir_list: a/y"), "dir_list: a/y");
        // Not `verb: value` shaped at all.
        assert_eq!(elide_shared_prefix("thinking", "planning"), "planning");
        // Identical rows leave no tail.
        assert_eq!(
            elide_shared_prefix("dir_list: a/bbbbbb/c", "dir_list: a/bbbbbb/c"),
            "dir_list: \u{2026}/c"
        );
    }

    #[test]
    fn elide_shared_prefix_never_splits_a_wide_grapheme() {
        // Shared head contains CJK + emoji; the cut must land on the `/`.
        let a = "dir_list: \u{6f22}\u{5b57}\u{1f600}dir/alpha";
        let b = "dir_list: \u{6f22}\u{5b57}\u{1f600}dir/beta";
        let out = elide_shared_prefix(a, b);
        assert_eq!(out, "dir_list: \u{2026}/beta");
        assert!(out.is_char_boundary(out.len()));
    }

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
