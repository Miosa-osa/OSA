use std::time::{Duration, Instant};

use ratatui::prelude::*;
use ratatui::widgets::Paragraph;

// ─── ThinkingBox ──────────────────────────────────────────────────────────────

/// Collapsible panel that shows extended-thinking / reasoning content.
///
/// Header states (grok `thinking.rs:150` / opencode `ReasoningHeader`):
///   - running: `∴ Thinking… 2.3s`   (live elapsed, ticks each frame)
///   - done:    `∴ Thought for 3.4s`  (frozen once [`finish`](Self::finish) fires)
/// A leading `**Bold title**` in the reasoning stream is promoted into the
/// header (`∴ Thought for 3.4s · Inspecting PR workflow`) — opencode
/// `reasoningSummary` (thinking.ts:12).
///
/// Collapsed (default):  the header line + an `(alt+t to expand)` hint.
/// Expanded:             the header + the reasoning body rendered through the
///                       Markdown renderer (lists / code / headings), indented
///                       two columns and dimmed-italic, capped at 10 visible
///                       lines with an overflow indicator.
pub struct ThinkingBox {
    content: String,
    expanded: bool,
    /// When reasoning first started streaming (set on the first
    /// [`update`](Self::update)/[`start`](Self::start)). `None` before any
    /// content arrives.
    started_at: Option<Instant>,
    /// Frozen elapsed once [`finish`](Self::finish) is called. While `None` and
    /// `running`, the header shows the live elapsed from `started_at`.
    elapsed: Option<Duration>,
    /// True from the first content until [`finish`](Self::finish); drives the
    /// running-vs-done header (spinner-ish `Thinking…` vs `Thought for Ns`).
    running: bool,
    /// A leading `**Bold title**` promoted from the reasoning body, if any.
    reasoning_title: Option<String>,
}

impl ThinkingBox {
    pub fn new() -> Self {
        Self {
            content: String::new(),
            // CC parity: thinking is collapsed to a one-liner by default.
            expanded: false,
            started_at: None,
            elapsed: None,
            running: false,
            reasoning_title: None,
        }
    }

    // ─── Mutation ──────────────────────────────────────────────────────────

    /// Append streamed reasoning text. Starts the elapsed timer on the first
    /// content of a run and re-extracts the reasoning title.
    pub fn update(&mut self, text: &str) {
        if self.started_at.is_none() {
            self.started_at = Some(Instant::now());
            self.running = true;
            self.elapsed = None;
        }
        self.content.push_str(text);
        self.reasoning_title = split_title_body(&self.content).0;
    }

    /// Explicitly mark reasoning as started (idempotent). Useful when a turn
    /// begins reasoning before any delta text has arrived.
    pub fn start(&mut self) {
        if self.started_at.is_none() {
            self.started_at = Some(Instant::now());
            self.running = true;
            self.elapsed = None;
        }
    }

    /// Freeze the elapsed time and switch the header to the done state
    /// (`Thought for Ns`). Call this on the reasoning→answer transition so the
    /// summary persists instead of resetting. No-op if not running.
    pub fn finish(&mut self) {
        if self.running {
            self.elapsed = Some(self.started_at.map(|t| t.elapsed()).unwrap_or_default());
            self.running = false;
        }
    }

    pub fn clear(&mut self) {
        self.content.clear();
        self.started_at = None;
        self.elapsed = None;
        self.running = false;
        self.reasoning_title = None;
    }

    // Thinking panel expand/collapse (alt+t — chat:thinkingToggle). Wired via
    // keymap_dispatch Action::ThinkingToggle.
    pub fn toggle(&mut self) {
        self.expanded = !self.expanded;
    }

    pub fn is_empty(&self) -> bool {
        self.content.is_empty()
    }

    /// The elapsed reasoning time — frozen value once finished, else the live
    /// value ticking up from `started_at`.
    pub fn elapsed(&self) -> Option<Duration> {
        self.elapsed
            .or_else(|| self.started_at.map(|t| t.elapsed()))
    }

    // ─── Layout ────────────────────────────────────────────────────────────

    /// Compute required height for the given render width.
    ///
    /// - Collapsed: always 1 line.
    /// - Expanded:  1 header line + body lines (max 10) + optional overflow line.
    pub fn height(&self, width: u16) -> u16 {
        if !self.expanded || self.content.is_empty() {
            return 1;
        }

        // Body is indented 2 columns under the header (CC paddingLeft=2).
        let inner_w = (width as usize).saturating_sub(2).max(1);
        let body = self.body_lines(inner_w);
        let visible = body.len().min(10);
        let overflow_line = if body.len() > 10 { 1 } else { 0 };

        // 1 header line + visible body + optional overflow indicator
        1 + visible as u16 + overflow_line as u16
    }

    // ─── Draw ──────────────────────────────────────────────────────────────

    pub fn draw(&self, frame: &mut Frame, area: Rect) {
        if area.height == 0 || area.width == 0 {
            return;
        }

        let theme = crate::style::theme();
        let header = self.header_text();

        if !self.expanded || self.content.is_empty() {
            // Collapsed: dim-italic one-liner. Show the expand hint once there is
            // body content to expand.
            let indicator = if self.content.is_empty() {
                header
            } else {
                format!("{header} (alt+t to expand)")
            };
            let line = Line::from(Span::styled(
                indicator,
                theme.faint().add_modifier(Modifier::ITALIC),
            ));
            frame.render_widget(Paragraph::new(line), area);
            return;
        }

        // Expanded — no border (CC AssistantThinkingMessage parity): a dim-italic
        // header line, then the Markdown-rendered reasoning body indented two
        // columns beneath it, dimmed and italic.
        let inner_w = (area.width as usize).saturating_sub(2).max(1);
        let body = self.body_lines(inner_w);
        let total = body.len();
        let visible_count = total.min(10);
        let has_overflow = total > 10;

        let mut text_lines: Vec<Line<'static>> = Vec::with_capacity(visible_count + 2);
        text_lines.push(Line::from(Span::styled(
            header,
            theme.faint().add_modifier(Modifier::ITALIC),
        )));

        let dim = theme.colors.dim;
        for line in &body[..visible_count] {
            let mut spans: Vec<Span<'static>> = Vec::with_capacity(line.spans.len() + 1);
            spans.push(Span::raw("  "));
            for sp in &line.spans {
                // Keep the Markdown structure's colors (headings / code / links)
                // but italicise, and dim any span that had no explicit color so
                // plain reasoning prose stays subdued.
                let mut st = sp.style.add_modifier(Modifier::ITALIC);
                if st.fg.is_none() {
                    st = st.fg(dim);
                }
                spans.push(Span::styled(sp.content.to_string(), st));
            }
            text_lines.push(Line::from(spans));
        }

        if has_overflow {
            text_lines.push(Line::from(Span::styled(
                format!("  … +{} lines", total - 10),
                theme.faint().add_modifier(Modifier::ITALIC),
            )));
        }

        frame.render_widget(Paragraph::new(Text::from(text_lines)), area);
    }

    // ─── Internal helpers ──────────────────────────────────────────────────

    /// The header string for the current running/done + title state.
    fn header_text(&self) -> String {
        compose_header(self.running, self.elapsed(), self.reasoning_title.as_deref())
    }

    /// The reasoning body (content minus any promoted title) rendered through
    /// the Markdown renderer at `inner_w` columns. Both [`height`](Self::height)
    /// and [`draw`](Self::draw) route through this so their line counts agree.
    fn body_lines(&self, inner_w: usize) -> Vec<Line<'static>> {
        let (_, body) = split_title_body(&self.content);
        crate::render::markdown::render_markdown(body, inner_w as u16).lines
    }
}

// ─── Free helpers (pure, unit-tested) ────────────────────────────────────────

/// Build the collapsed/expanded header string.
///
/// - running → `∴ Thinking… [Ns]`
/// - done    → `∴ Thought for Ns`
/// - a promoted reasoning title is appended as ` · Title`.
fn compose_header(running: bool, elapsed: Option<Duration>, title: Option<&str>) -> String {
    let mut s = String::new();
    match (running, elapsed) {
        (true, Some(d)) => {
            s.push_str("\u{2234} Thinking\u{2026} ");
            s.push_str(&format_duration(d));
        }
        (true, None) => s.push_str("\u{2234} Thinking\u{2026}"),
        (false, Some(d)) => {
            s.push_str("\u{2234} Thought for ");
            s.push_str(&format_duration(d));
        }
        (false, None) => s.push_str("\u{2234} Thinking\u{2026}"),
    }
    if let Some(t) = title {
        if !t.is_empty() {
            s.push_str(" \u{00b7} ");
            s.push_str(t);
        }
    }
    s
}

/// Format an elapsed duration for the header: `3.4s` under a minute, `1m 4s`
/// beyond (grok `thinking.rs:150 format_time` parity).
fn format_duration(d: Duration) -> String {
    let secs = d.as_secs_f64();
    if secs < 60.0 {
        format!("{secs:.1}s")
    } else {
        let total = secs.round() as u64;
        format!("{}m {}s", total / 60, total % 60)
    }
}

/// Split a leading `**Bold title**` off the reasoning content.
///
/// Returns `(Some(title), body_without_title)` when the content begins with a
/// single-line `**…**` run (opencode `reasoningSummary` regex
/// `^\*\*([^*\n]+)\*\*`), else `(None, whole_content)`. Up to two leading
/// newlines after the title are consumed so the body starts at real text.
fn split_title_body(content: &str) -> (Option<String>, &str) {
    let leading_ws = content.len() - content.trim_start().len();
    let after_ws = &content[leading_ws..];
    if let Some(rest) = after_ws.strip_prefix("**") {
        if let Some(end) = rest.find("**") {
            let title = &rest[..end];
            if !title.is_empty() && !title.contains('\n') {
                let mut body = &rest[end + 2..];
                body = body.strip_prefix('\r').unwrap_or(body);
                body = body.strip_prefix('\n').unwrap_or(body);
                body = body.strip_prefix('\r').unwrap_or(body);
                body = body.strip_prefix('\n').unwrap_or(body);
                return (Some(title.trim().to_string()), body);
            }
        }
    }
    (None, content)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn collapsed_by_default_toggle_expands() {
        let mut tb = ThinkingBox::new();
        tb.update("line one\nline two");
        assert_eq!(tb.height(80), 1, "collapsed by default");
        tb.toggle();
        assert!(tb.height(80) > 1, "expanded shows the box");
    }

    // ── Item 1: "Thought for Ns" formatting + running/done header ──────────

    #[test]
    fn thought_for_ns_formats_sub_minute_and_minutes() {
        assert_eq!(format_duration(Duration::from_millis(3400)), "3.4s");
        assert_eq!(format_duration(Duration::from_millis(800)), "0.8s");
        assert_eq!(format_duration(Duration::from_secs(64)), "1m 4s");
        assert_eq!(format_duration(Duration::from_secs(600)), "10m 0s");
    }

    #[test]
    fn header_running_vs_done_state() {
        let running = compose_header(true, Some(Duration::from_millis(2300)), None);
        assert!(running.contains("Thinking"), "{running}");
        assert!(running.contains("2.3s"), "{running}");

        let done = compose_header(false, Some(Duration::from_millis(3400)), None);
        assert_eq!(done, "\u{2234} Thought for 3.4s");
    }

    #[test]
    fn finish_freezes_elapsed_and_flips_to_done() {
        let mut tb = ThinkingBox::new();
        tb.update("reasoning…");
        assert!(tb.running, "running after first delta");
        tb.finish();
        assert!(!tb.running, "done after finish");
        assert!(tb.elapsed().is_some(), "elapsed frozen");
        // Header is now the done state.
        assert!(tb.header_text().starts_with("\u{2234} Thought for"), "{}", tb.header_text());
    }

    // ── Item 2: Markdown inside the thinking body ──────────────────────────

    #[test]
    fn markdown_list_renders_in_thinking_body() {
        let mut tb = ThinkingBox::new();
        tb.update("Here is a plan:\n\n- first step\n- second step\n");
        let body = tb.body_lines(40);
        let flat: String = body
            .iter()
            .flat_map(|l| l.spans.iter().map(|s| s.content.to_string()))
            .collect::<Vec<_>>()
            .join("\n");
        // The unordered-list renderer emits bullets — flat dim text would not.
        assert!(flat.contains('\u{2022}'), "expected a bullet, got: {flat:?}");
        assert!(flat.contains("first step"), "{flat:?}");
        assert!(flat.contains("second step"), "{flat:?}");
    }

    // ── Item 3: reasoning title extraction from a bold lead ────────────────

    #[test]
    fn title_extracted_from_bold_lead_and_stripped_from_body() {
        let (title, body) =
            split_title_body("**Inspecting PR workflow**\n\nNow I check the CI config.");
        assert_eq!(title.as_deref(), Some("Inspecting PR workflow"));
        assert_eq!(body, "Now I check the CI config.");
    }

    #[test]
    fn no_title_when_no_bold_lead() {
        let (title, body) = split_title_body("Just plain reasoning with no title.");
        assert_eq!(title, None);
        assert_eq!(body, "Just plain reasoning with no title.");
        // A bold run that is not a lead is left alone.
        let (title, _) = split_title_body("Some text then **bold** later.");
        assert_eq!(title, None);
    }

    #[test]
    fn extracted_title_appears_in_header() {
        let mut tb = ThinkingBox::new();
        tb.update("**Inspecting PR workflow**\n\nchecking the config");
        tb.finish();
        let header = tb.header_text();
        assert!(header.contains("Inspecting PR workflow"), "{header}");
        assert!(header.contains("Thought for"), "{header}");
    }
}
