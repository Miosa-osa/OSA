use ratatui::style::{Color, Style};
use ratatui::text::{Line, Span};
use similar::{ChangeTag, TextDiff};
use unicode_segmentation::UnicodeSegmentation;
use unicode_width::UnicodeWidthStr;

/// Proportion of a paired line that may change before word-level highlighting
/// is skipped in favor of plain +/- rendering (CC `Fallback.tsx`
/// `CHANGE_THRESHOLD = 0.4`).
const WORD_DIFF_CHANGE_THRESHOLD: f32 = 0.4;

/// Render a unified diff between `old_text` and `new_text`, Claude Code style
/// (`StructuredDiff` / `StructuredDiffFallback`):
///   - right-aligned line-number gutter + `+` / `-` / ` ` sigil;
///   - solid green/red background bars on added/removed lines, padded to the
///     full render width (CC `formatDiff` pads with `' '.repeat(padding)`);
///   - word-level highlights (darker bg, no bold) on paired changed lines;
///   - dim `…` separator between hunks (3 context lines per hunk);
///   - long lines wrap inside the content column — never clipped.
pub fn render_diff(old_text: &str, new_text: &str, width: u16) -> Vec<Line<'static>> {
    render_diff_body(old_text, new_text, width, 1)
}

/// CC-style diff body. `start_line` is the 1-indexed file line number of the
/// first line of `old`/`new` (pass 1 when unknown — Edit tool args only carry
/// the snippet, not its position in the file).
pub fn render_diff_body(
    old: &str,
    new: &str,
    width: u16,
    start_line: usize,
) -> Vec<Line<'static>> {
    let theme = crate::style::theme();
    let diff = TextDiff::from_lines(old, new);
    let groups = diff.grouped_ops(3);

    // Gutter sized to the largest visible line number (CC computeGutterWidth:
    // right-aligned number + marker + padding).
    let mut max_ln = start_line;
    for group in &groups {
        for op in group {
            max_ln = max_ln
                .max(start_line + op.old_range().end)
                .max(start_line + op.new_range().end);
        }
    }
    let num_w = max_ln.to_string().len();
    let gutter_w = num_w + 3; // number + space + sigil + space
    let avail = (width as usize).saturating_sub(gutter_w).max(4);

    let ctx_style = Style::default().fg(theme.colors.muted);
    let mut lines: Vec<Line<'static>> = Vec::new();

    for (gi, group) in groups.iter().enumerate() {
        if gi > 0 {
            // Dim ellipsis separator between hunks (StructuredDiffList parity).
            lines.push(Line::from(Span::styled(
                "…".to_string(),
                Style::default().fg(theme.colors.dim),
            )));
        }
        for op in group {
            let mut dels: Vec<(Option<usize>, String)> = Vec::new();
            let mut inss: Vec<(Option<usize>, String)> = Vec::new();
            for change in diff.iter_changes(op) {
                let content = change.value().trim_end_matches('\n').to_string();
                match change.tag() {
                    ChangeTag::Equal => {
                        let ln = change.new_index().map(|i| start_line + i);
                        push_diff_row(
                            &mut lines,
                            ln,
                            num_w,
                            ' ',
                            vec![(content, ctx_style)],
                            None,
                            ctx_style,
                            width,
                            avail,
                        );
                    }
                    ChangeTag::Delete => {
                        dels.push((change.old_index().map(|i| start_line + i), content))
                    }
                    ChangeTag::Insert => {
                        inss.push((change.new_index().map(|i| start_line + i), content))
                    }
                }
            }
            render_change_run(&dels, &inss, &theme, num_w, width, avail, &mut lines);
        }
    }

    if lines.is_empty() {
        lines.push(Line::from(Span::styled(
            "(no changes)".to_string(),
            ctx_style,
        )));
    }

    lines
}

fn word_diff_pairs_well(old_line: &str, new_line: &str) -> bool {
    if old_line.trim().is_empty() || new_line.trim().is_empty() {
        return false;
    }
    let ratio = TextDiff::from_words(old_line, new_line).ratio();
    (1.0 - ratio) <= WORD_DIFF_CHANGE_THRESHOLD
}

/// Word-level spans for one side of a paired change line. Unchanged words get
/// the line tint; changed words get the darker highlight bg (CC
/// `diffAddedWord` / `diffRemovedWord` — bg only, no bold).
fn word_spans(
    old_line: &str,
    new_line: &str,
    side: ChangeTag,
    theme: &crate::style::Theme,
) -> Vec<(String, Style)> {
    let word_diff = TextDiff::from_words(old_line, new_line);
    let (base, highlight) = match side {
        ChangeTag::Delete => (
            Style::default()
                .fg(theme.colors.error)
                .bg(theme.colors.diff_del_bg),
            Style::default()
                .fg(theme.colors.diff_del_highlight_fg)
                .bg(theme.colors.diff_del_highlight_bg),
        ),
        _ => (
            Style::default()
                .fg(theme.colors.success)
                .bg(theme.colors.diff_add_bg),
            Style::default()
                .fg(theme.colors.diff_add_highlight_fg)
                .bg(theme.colors.diff_add_highlight_bg),
        ),
    };
    let mut spans: Vec<(String, Style)> = Vec::new();
    for wc in word_diff.iter_all_changes() {
        match (side, wc.tag()) {
            (_, ChangeTag::Equal) => spans.push((wc.value().to_string(), base)),
            (ChangeTag::Delete, ChangeTag::Delete) | (ChangeTag::Insert, ChangeTag::Insert) => {
                spans.push((wc.value().to_string(), highlight))
            }
            _ => {} // the other side's words render on the other line
        }
    }
    spans
}

/// Render a run of removed lines followed by added lines, pairing the i-th
/// delete with the i-th insert for word-level highlights when similar enough
/// (CC `processAdjacentLines`).
#[allow(clippy::too_many_arguments)]
fn render_change_run(
    dels: &[(Option<usize>, String)],
    inss: &[(Option<usize>, String)],
    theme: &crate::style::Theme,
    num_w: usize,
    width: u16,
    avail: usize,
    out: &mut Vec<Line<'static>>,
) {
    let paired = dels.len().min(inss.len());

    for (i, (ln, old_line)) in dels.iter().enumerate() {
        let base = Style::default()
            .fg(theme.colors.error)
            .bg(theme.colors.diff_del_bg);
        let content = if i < paired && word_diff_pairs_well(old_line, &inss[i].1) {
            word_spans(old_line, &inss[i].1, ChangeTag::Delete, theme)
        } else {
            vec![(old_line.clone(), base)]
        };
        push_diff_row(
            out,
            *ln,
            num_w,
            '-',
            content,
            Some(theme.colors.diff_del_bg),
            base,
            width,
            avail,
        );
    }

    for (i, (ln, new_line)) in inss.iter().enumerate() {
        let base = Style::default()
            .fg(theme.colors.success)
            .bg(theme.colors.diff_add_bg);
        let content = if i < paired && word_diff_pairs_well(&dels[i].1, new_line) {
            word_spans(&dels[i].1, new_line, ChangeTag::Insert, theme)
        } else {
            vec![(new_line.clone(), base)]
        };
        push_diff_row(
            out,
            *ln,
            num_w,
            '+',
            content,
            Some(theme.colors.diff_add_bg),
            base,
            width,
            avail,
        );
    }
}

/// Emit one logical diff line as one or more wrapped rows:
/// `{line number:>num_w} {sigil} {content}{padding}`. The number shows only on
/// the first row; the sigil repeats on wrapped rows (CC `formatDiff`). Rows
/// with a `bar_bg` are padded to the full width so they render as solid bars.
#[allow(clippy::too_many_arguments)]
fn push_diff_row(
    out: &mut Vec<Line<'static>>,
    ln: Option<usize>,
    num_w: usize,
    sigil: char,
    content: Vec<(String, Style)>,
    bar_bg: Option<Color>,
    gutter_style: Style,
    width: u16,
    avail: usize,
) {
    for (ri, row) in wrap_styled(content, avail).into_iter().enumerate() {
        let num_str = match (ri, ln) {
            (0, Some(n)) => format!("{:>w$} ", n, w = num_w),
            _ => " ".repeat(num_w + 1),
        };
        let mut spans: Vec<Span<'static>> = Vec::with_capacity(row.len() + 3);
        spans.push(Span::styled(num_str, gutter_style));
        spans.push(Span::styled(format!("{} ", sigil), gutter_style));
        let mut used = 0usize;
        for (text, style) in row {
            used += UnicodeWidthStr::width(text.as_str());
            spans.push(Span::styled(text, style));
        }
        if let Some(bg) = bar_bg {
            let pad = (width as usize).saturating_sub(num_w + 3 + used);
            if pad > 0 {
                spans.push(Span::styled(" ".repeat(pad), Style::default().bg(bg)));
            }
        }
        out.push(Line::from(spans));
    }
}

/// Wrap styled text runs into rows of at most `max_w` display columns,
/// splitting on grapheme boundaries (unicode-width aware). Always returns at
/// least one (possibly empty) row.
pub(crate) fn wrap_styled(
    spans: Vec<(String, Style)>,
    max_w: usize,
) -> Vec<Vec<(String, Style)>> {
    let max_w = max_w.max(1);
    let mut rows: Vec<Vec<(String, Style)>> = Vec::new();
    let mut cur: Vec<(String, Style)> = Vec::new();
    let mut col = 0usize;
    for (text, style) in spans {
        let mut chunk = String::new();
        for g in UnicodeSegmentation::graphemes(text.as_str(), true) {
            let gw = UnicodeWidthStr::width(g);
            if col + gw > max_w && col > 0 {
                if !chunk.is_empty() {
                    cur.push((std::mem::take(&mut chunk), style));
                }
                rows.push(std::mem::take(&mut cur));
                col = 0;
            }
            chunk.push_str(g);
            col += gw;
        }
        if !chunk.is_empty() {
            cur.push((chunk, style));
        }
    }
    rows.push(cur);
    rows
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(lines: &[Line<'static>]) -> Vec<String> {
        lines
            .iter()
            .map(|l| l.spans.iter().map(|s| s.content.as_ref()).collect::<String>())
            .collect()
    }

    #[test]
    fn long_lines_wrap_instead_of_clipping() {
        let new = format!("{}\n", "x".repeat(200));
        let lines = render_diff("short\n", &new, 40);
        for l in text(&lines) {
            assert!(
                UnicodeWidthStr::width(l.as_str()) <= 40,
                "row wider than 40 cols: {:?}",
                l
            );
        }
        assert!(lines.len() >= 6, "200-char line should wrap into many rows");
    }

    #[test]
    fn added_lines_have_bg_bar_and_line_numbers() {
        let theme = crate::style::theme();
        let lines = render_diff("a\n", "a\nb\n", 30);
        let rendered = text(&lines);
        assert!(
            rendered.iter().any(|l| l.contains(" + b")),
            "expected numbered add row: {:?}",
            rendered
        );
        let has_bg = lines
            .iter()
            .flat_map(|l| l.spans.iter())
            .any(|s| s.style.bg == Some(theme.colors.diff_add_bg));
        assert!(has_bg, "add rows must carry the diff_add_bg bar");
    }

    #[test]
    fn identical_texts_render_no_changes_notice() {
        let lines = render_diff("same\n", "same\n", 40);
        let rendered = text(&lines);
        assert_eq!(rendered, vec!["(no changes)".to_string()]);
    }
}
