use ratatui::prelude::*;
use ratatui::widgets::Paragraph;

use crate::event::Event;

use super::{Component, ComponentAction};

// ─── Types ────────────────────────────────────────────────────────────────────

struct SidebarSection {
    title: String,
    items: Vec<(String, String)>, // (label, value)
}

// ─── Sidebar ─────────────────────────────────────────────────────────────────

/// Vertical side panel displaying session and context metadata.
///
/// Layout (per section):
///   [title]
///   label  value
///   ...
///
/// A dim left-border character is drawn at x=0 of the area on each row.
pub struct Sidebar {
    provider: String,
    model: String,
    session_id: String,
    tool_count: usize,
    context_pct: f64,
    // ── New fields ──────────────────────────────────────────────────────────
    /// Cumulative input tokens across all LlmResponse events this session.
    input_tokens: u64,
    /// Cumulative output tokens across all LlmResponse events this session.
    output_tokens: u64,
    /// Elapsed milliseconds of the current (or last) processing run.
    elapsed_ms: u64,
    /// Current agent name / role — empty when none active.
    current_agent: String,
    /// Whether --dangerously-skip-permissions / --yolo mode is active.
    yolo_mode: bool,
    /// Whether proactive mode is enabled.
    proactive: bool,
    /// Signal Theory mode from last ClassifyResult.
    signal_mode: String,
    /// Signal Theory genre from last ClassifyResult.
    signal_genre: String,
    // ────────────────────────────────────────────────────────────────────────
    sections: Vec<SidebarSection>,
    width: u16,
}

impl Sidebar {
    pub fn new() -> Self {
        let mut s = Self {
            provider: String::new(),
            model: String::new(),
            session_id: String::new(),
            tool_count: 0,
            context_pct: 0.0,
            input_tokens: 0,
            output_tokens: 0,
            elapsed_ms: 0,
            current_agent: String::new(),
            yolo_mode: false,
            proactive: false,
            signal_mode: String::new(),
            signal_genre: String::new(),
            sections: Vec::new(),
            width: 24,
        };
        s.rebuild_sections();
        s
    }

    // ─── Configuration setters ────────────────────────────────────────────

    // Phase 2: wired when sidebar supports dynamic resize from layout
    #[allow(dead_code)]
    pub fn set_width(&mut self, w: u16) {
        self.width = w;
    }

    pub fn set_provider_info(&mut self, provider: impl Into<String>, model: impl Into<String>) {
        self.provider = provider.into();
        self.model = model.into();
        self.rebuild_sections();
    }

    pub fn set_session(&mut self, id: impl Into<String>) {
        self.session_id = id.into();
        self.rebuild_sections();
    }

    pub fn set_tool_count(&mut self, n: usize) {
        self.tool_count = n;
        self.rebuild_sections();
    }

    pub fn set_context(&mut self, pct: f64) {
        self.context_pct = pct.clamp(0.0, 1.0);
        self.rebuild_sections();
    }

    /// Accumulate token counts from an LlmResponse event.
    pub fn set_tokens(&mut self, input: u64, output: u64) {
        self.input_tokens += input;
        self.output_tokens += output;
        self.rebuild_sections();
    }

    /// Set the current agent name/role. Pass an empty string to clear.
    pub fn set_current_agent(&mut self, name: impl Into<String>) {
        self.current_agent = name.into();
        self.rebuild_sections();
    }

    /// Update elapsed processing time in milliseconds.
    /// Called from the tick handler while processing is active.
    pub fn set_elapsed_ms(&mut self, ms: u64) {
        self.elapsed_ms = ms;
        self.rebuild_sections();
    }

    /// Set signal mode and genre from ClassifyResult.
    pub fn set_signal_info(&mut self, mode: &str, genre: &str) {
        self.signal_mode = mode.to_string();
        self.signal_genre = genre.to_string();
        self.rebuild_sections();
    }

    /// Set whether --yolo / --dangerously-skip-permissions mode is active.
    pub fn set_yolo_mode(&mut self, enabled: bool) {
        self.yolo_mode = enabled;
        self.rebuild_sections();
    }

    /// Set whether proactive mode is enabled.
    pub fn set_proactive(&mut self, enabled: bool) {
        self.proactive = enabled;
        self.rebuild_sections();
    }

    // ─── Layout ───────────────────────────────────────────────────────────

    /// Total height occupied by all sections (title + items + gap).
    pub fn height(&self) -> u16 {
        let mut h = 0u16;
        for section in &self.sections {
            h += 1; // title
            h += section.items.len() as u16;
            h += 1; // blank gap between sections
        }
        h.saturating_sub(1) // no trailing blank after last section
    }

    // ─── Private helpers ──────────────────────────────────────────────────

    fn rebuild_sections(&mut self) {
        self.sections.clear();

        // ── Mode indicators (shown first when active) ─────────────────────
        {
            let mut mode_items = Vec::new();
            if self.yolo_mode {
                mode_items.push(("yolo".into(), "ON".into()));
            }
            if self.proactive {
                mode_items.push(("proactive".into(), "ON".into()));
            }
            if !mode_items.is_empty() {
                self.sections.push(SidebarSection {
                    title: "Mode".into(),
                    items: mode_items,
                });
            }
        }

        // ── Provider / Model ──────────────────────────────────────────────
        if !self.provider.is_empty() || !self.model.is_empty() {
            self.sections.push(SidebarSection {
                title: "Provider".into(),
                items: vec![
                    ("via".into(), self.provider.clone()),
                    ("model".into(), self.truncate_value(&self.model, 14)),
                ],
            });
        }

        // ── Session ───────────────────────────────────────────────────────
        if !self.session_id.is_empty() {
            let short_id = self.truncate_session_id(&self.session_id);
            self.sections.push(SidebarSection {
                title: "Session".into(),
                items: vec![("id".into(), short_id)],
            });
        }

        // ── Agent ─────────────────────────────────────────────────────────
        if !self.current_agent.is_empty() {
            self.sections.push(SidebarSection {
                title: "Agent".into(),
                items: vec![("role".into(), self.truncate_value(&self.current_agent, 14))],
            });
        }

        // ── Signal ───────────────────────────────────────────────────────
        if !self.signal_mode.is_empty() || !self.signal_genre.is_empty() {
            self.sections.push(SidebarSection {
                title: "Signal".into(),
                items: vec![
                    ("mode".into(), self.truncate_value(&self.signal_mode, 14)),
                    ("genre".into(), self.truncate_value(&self.signal_genre, 14)),
                ],
            });
        }

        // ── Context window ────────────────────────────────────────────────
        {
            // Visual bar width = inner width - label prefix "ctx " (4)
            let bar_w = (self.width as usize).saturating_sub(8).max(4);
            let filled = ((self.context_pct * bar_w as f64).round() as usize).min(bar_w);
            let empty = bar_w - filled;
            let bar = format!("{}{}", "\u{2588}".repeat(filled), "\u{2591}".repeat(empty));
            let pct_str = format!("{}%", (self.context_pct * 100.0) as u32);

            self.sections.push(SidebarSection {
                title: "Context".into(),
                items: vec![
                    ("ctx".into(), bar),
                    ("use".into(), pct_str),
                ],
            });
        }

        // ── Tokens ────────────────────────────────────────────────────────
        if self.input_tokens > 0 || self.output_tokens > 0 {
            self.sections.push(SidebarSection {
                title: "Tokens".into(),
                items: vec![
                    ("in".into(), Self::format_tokens(self.input_tokens)),
                    ("out".into(), Self::format_tokens(self.output_tokens)),
                ],
            });
        }

        // ── Timing ────────────────────────────────────────────────────────
        if self.elapsed_ms > 0 {
            self.sections.push(SidebarSection {
                title: "Timing".into(),
                items: vec![("elap".into(), Self::format_elapsed(self.elapsed_ms))],
            });
        }

        // ── Tools ─────────────────────────────────────────────────────────
        self.sections.push(SidebarSection {
            title: "Tools".into(),
            items: vec![("count".into(), self.tool_count.to_string())],
        });
    }

    /// Format a token count as a compact human-readable string.
    ///
    /// Examples: 42 → "42", 1_200 → "1.2K", 85_000 → "85K", 1_500_000 → "1.5M"
    fn format_tokens(n: u64) -> String {
        if n >= 1_000_000 {
            let m = n as f64 / 1_000_000.0;
            if (m.fract() * 10.0).round() == 0.0 {
                format!("{}M", m as u64)
            } else {
                format!("{:.1}M", m)
            }
        } else if n >= 1_000 {
            let k = n as f64 / 1_000.0;
            if (k.fract() * 10.0).round() == 0.0 {
                format!("{}K", k as u64)
            } else {
                format!("{:.1}K", k)
            }
        } else {
            n.to_string()
        }
    }

    /// Format elapsed milliseconds as a compact human-readable string.
    ///
    /// Examples: 500 → "500ms", 1_200 → "1.2s", 62_000 → "1m2s"
    fn format_elapsed(ms: u64) -> String {
        let total_secs = ms / 1_000;
        let mins = total_secs / 60;
        let secs = total_secs % 60;
        if mins > 0 {
            format!("{}m{}s", mins, secs)
        } else if ms < 1_000 {
            format!("{}ms", ms)
        } else {
            let frac = (ms % 1_000) / 100; // tenths of a second
            if frac == 0 {
                format!("{}s", total_secs)
            } else {
                format!("{}.{}s", total_secs, frac)
            }
        }
    }

    fn truncate_value(&self, s: &str, max: usize) -> String {
        if max == 0 {
            return String::new();
        }
        let char_count: usize = s.chars().count();
        if char_count <= max {
            s.to_string()
        } else {
            let truncated: String = s.chars().take(max.saturating_sub(1)).collect();
            format!("{}…", truncated)
        }
    }

    fn truncate_session_id(&self, id: &str) -> String {
        // Show last 12 chars prefixed with "…"
        if id.len() > 12 {
            format!("\u{2026}{}", crate::util::truncate_str_start(id, 12))
        } else {
            id.to_string()
        }
    }
}

impl Component for Sidebar {
    fn handle_event(&mut self, _event: &Event) -> ComponentAction {
        ComponentAction::Ignored
    }

    fn draw(&self, frame: &mut Frame, area: Rect) {
        if area.height == 0 || area.width < 3 {
            return;
        }
        let theme = crate::style::theme();

        // Inner area for text (leave column 0 for the left border glyph).
        let inner_x = area.x + 2;
        let inner_w = area.width.saturating_sub(2);

        let mut y = area.y;

        let section_count = self.sections.len();
        for (si, section) in self.sections.iter().enumerate() {
            if y >= area.y + area.height {
                break;
            }

            // Left border on every row of this section (title + items + gap)
            let section_h = 1 + section.items.len() as u16 + if si + 1 < section_count { 1 } else { 0 };
            for row in 0..section_h {
                let ry = y + row;
                if ry >= area.y + area.height {
                    break;
                }
                frame.render_widget(
                    Paragraph::new(Line::from(Span::styled(
                        "\u{2502}",
                        theme.sidebar_separator(),
                    ))),
                    Rect::new(area.x, ry, 1, 1),
                );
            }

            // Section title — "Mode" gets yellow+bold when YOLO is active
            if inner_w > 0 {
                let title_style = if section.title == "Mode" && self.yolo_mode {
                    theme.sidebar_title().fg(Color::Yellow).bold()
                } else {
                    theme.sidebar_title()
                };
                frame.render_widget(
                    Paragraph::new(Line::from(Span::styled(
                        &section.title,
                        title_style,
                    ))),
                    Rect::new(inner_x, y, inner_w, 1),
                );
            }
            y += 1;

            // Items: "label  value"
            for (label, value) in &section.items {
                if y >= area.y + area.height {
                    break;
                }

                // label column: 5 chars wide
                let label_col = 5usize;
                let label_trunc = self.truncate_value(label, label_col);
                let value_max = (inner_w as usize).saturating_sub(label_col + 1);
                let value_trunc = self.truncate_value(value, value_max);

                // "yolo ON" value gets yellow+bold highlight
                let value_style = if label == "yolo" && self.yolo_mode {
                    theme.sidebar_value().fg(Color::Yellow).bold()
                } else {
                    theme.sidebar_value()
                };

                let line = Line::from(vec![
                    Span::styled(format!("{:<5} ", label_trunc), theme.sidebar_label()),
                    Span::styled(value_trunc, value_style),
                ]);

                if inner_w > 0 {
                    frame.render_widget(
                        Paragraph::new(line),
                        Rect::new(inner_x, y, inner_w, 1),
                    );
                }
                y += 1;
            }

            // Gap between sections (except after the last one)
            if si + 1 < section_count {
                y += 1;
            }
        }
    }
}
