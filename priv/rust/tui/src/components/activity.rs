// Phase 2+: activity panel — Synthesizing variant, set_thinking wired when agent mesh arrives
#![allow(dead_code)]

use ratatui::prelude::*;
use ratatui::widgets::Paragraph;

use crate::event::Event;

use super::{Component, ComponentAction};

/// Processing phase — drives the activity display with real backend state
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ProcessingPhase {
    /// Submitted, waiting for first backend event
    Waiting,
    /// ThinkingDelta events arriving (model reasoning)
    Thinking,
    /// StreamingToken events arriving
    Streaming,
    /// Tool call in progress
    ToolCall,
    /// Post-processing / synthesizing final response
    Synthesizing,
}

/// Format large counts compactly (e.g. 1234 → "1.2k")
fn format_count(n: usize) -> String {
    if n >= 1000 {
        format!("{:.1}k", n as f64 / 1000.0)
    } else {
        format!("{}", n)
    }
}

/// Format elapsed seconds into human-readable duration: 45s → 2m 15s → 1h 3m
fn format_elapsed(secs: u64) -> String {
    if secs < 60 {
        format!("{}s", secs)
    } else if secs < 3600 {
        let m = secs / 60;
        let s = secs % 60;
        if s == 0 {
            format!("{}m", m)
        } else {
            format!("{}m {}s", m, s)
        }
    } else {
        let h = secs / 3600;
        let m = (secs % 3600) / 60;
        if m == 0 {
            format!("{}h", h)
        } else {
            format!("{}h {}m", h, m)
        }
    }
}

/// Tool symbol + verb mapping for activity feed
fn tool_display(name: &str) -> (&'static str, &'static str) {
    match name {
        // Search tools
        "web_search" | "WebSearch" => (">", "searching"),
        "grep" | "Grep" | "file_grep" => (">", "searching"),
        "glob" | "Glob" | "file_glob" => (">", "finding"),

        // Read tools
        "read" | "Read" | "file_read" => (">", "reading"),
        "web_fetch" | "WebFetch" => (">", "fetching"),

        // Write tools
        "write" | "Write" | "file_write" => (">", "writing"),
        "file_edit" | "Edit" => (">", "editing"),

        // Execute tools
        "bash" | "Bash" | "terminal" | "shell_execute" => ("$", "executing"),

        // Directory
        "dir_list" => (">", "listing"),

        // Agent tools
        "delegate" | "Delegate" | "Task" => (">", "delegating"),
        "orchestrate" => (">", "orchestrating"),

        // Task tools
        "task_write" | "TaskWrite" | "TaskCreate" => (">", "planning"),
        "task_read" | "TaskRead" | "TaskList" => (">", "checking"),
        "ask_user" => ("?", "asking"),

        // Diagnostics
        "diagnostics" | "doctor" => (">", "diagnosing"),

        // Memory
        "memory" | "recall" | "session_search" => (">", "recalling"),

        // MCP
        _ if name.starts_with("mcp__") => (">", "extending"),

        // Fallback
        _ => (">", "running"),
    }
}

/// Tool activity entry in the feed
struct ToolEntry {
    name: String,
    emoji: &'static str,
    verb: &'static str,
    detail: String,
    start: std::time::Instant,
    duration_ms: Option<u64>,
    success: Option<bool>,
}

/// Verbosity level for tool display (Hermes-inspired 4-level toggle)
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Verbosity {
    Off,
    New,
    All,
    Verbose,
}

impl Verbosity {
    pub fn cycle(self) -> Self {
        match self {
            Self::Off => Self::New,
            Self::New => Self::All,
            Self::All => Self::Verbose,
            Self::Verbose => Self::Off,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::New => "new",
            Self::All => "all",
            Self::Verbose => "verbose",
        }
    }
}

/// Activity panel showing real-time processing state, tool feed, and backend metrics
pub struct Activity {
    active: bool,
    phase: ProcessingPhase,
    tool_feed: Vec<ToolEntry>,
    last_tool_name: String,
    input_tokens: u64,
    output_tokens: u64,
    stream_chars: usize,
    thinking_chars: usize,
    model_name: String,
    llm_iteration: u32,
    expanded: bool,
    phrase_tick: u32,
    start_time: Option<std::time::Instant>,
    pub verbosity: Verbosity,
}

impl Activity {
    pub fn new() -> Self {
        Self {
            active: false,
            phase: ProcessingPhase::Waiting,
            tool_feed: Vec::new(),
            last_tool_name: String::new(),
            input_tokens: 0,
            output_tokens: 0,
            stream_chars: 0,
            thinking_chars: 0,
            model_name: String::new(),
            llm_iteration: 0,
            expanded: false,
            phrase_tick: 0,
            start_time: None,
            verbosity: Verbosity::All,
        }
    }

    pub fn start(&mut self) {
        self.active = true;
        self.phase = ProcessingPhase::Waiting;
        self.tool_feed.clear();
        self.last_tool_name.clear();
        self.input_tokens = 0;
        self.output_tokens = 0;
        self.stream_chars = 0;
        self.thinking_chars = 0;
        self.llm_iteration = 0;
        self.phrase_tick = 0;
        self.start_time = Some(std::time::Instant::now());
    }

    pub fn stop(&mut self) {
        self.active = false;
        self.phase = ProcessingPhase::Waiting;
        self.start_time = None;
    }

    /// Set processing phase (auto-activates if inactive)
    pub fn set_phase(&mut self, phase: ProcessingPhase) {
        self.phase = phase;
        if !self.active {
            self.active = true;
            self.start_time = Some(std::time::Instant::now());
        }
    }

    /// Legacy compat: enable thinking indicator via phase
    pub fn set_thinking(&mut self, thinking: bool) {
        if thinking {
            self.phase = ProcessingPhase::Thinking;
            if !self.active {
                self.active = true;
                self.start_time = Some(std::time::Instant::now());
            }
        }
    }

    pub fn is_thinking(&self) -> bool {
        self.phase == ProcessingPhase::Thinking
    }

    pub fn is_active(&self) -> bool {
        self.active
    }

    pub fn add_stream_chars(&mut self, n: usize) {
        self.stream_chars += n;
    }

    pub fn add_thinking_chars(&mut self, n: usize) {
        self.thinking_chars += n;
    }

    pub fn set_model_name(&mut self, name: &str) {
        self.model_name = name.to_string();
    }

    pub fn set_iteration(&mut self, iteration: u32) {
        self.llm_iteration = iteration;
    }

    /// Record a tool call start
    pub fn tool_start(&mut self, name: &str, args: &str) {
        let (emoji, verb) = tool_display(name);
        // Truncate args for detail preview
        let detail = if args.len() > 60 {
            format!("{}...", &args[..57])
        } else {
            args.to_string()
        };
        self.tool_feed.push(ToolEntry {
            name: name.to_string(),
            emoji,
            verb,
            detail,
            start: std::time::Instant::now(),
            duration_ms: None,
            success: None,
        });
        self.last_tool_name = name.to_string();
        // Keep feed bounded
        if self.tool_feed.len() > 20 {
            self.tool_feed.remove(0);
        }
    }

    /// Record a tool call end
    pub fn tool_end(&mut self, name: &str, duration_ms: u64, success: bool) {
        // Find the last matching entry without a duration
        if let Some(entry) = self
            .tool_feed
            .iter_mut()
            .rev()
            .find(|e| e.name == name && e.duration_ms.is_none())
        {
            // If the backend sends 0 (missing or untracked), measure from the
            // TUI-side start Instant so the display shows real elapsed time.
            let effective_ms = if duration_ms == 0 {
                entry.start.elapsed().as_millis() as u64
            } else {
                duration_ms
            };
            entry.duration_ms = Some(effective_ms);
            entry.success = Some(success);
        }
    }

    pub fn set_tokens(&mut self, input: u64, output: u64) {
        self.input_tokens = input;
        self.output_tokens = output;
    }

    /// Advance spinner animation on each tick
    pub fn tick(&mut self) {
        if self.active {
            self.phrase_tick += 1;
        }
    }

    pub fn height(&self) -> u16 {
        if !self.active {
            return 0;
        }
        match self.verbosity {
            Verbosity::Off => 1,
            Verbosity::New => 2,
            Verbosity::All => {
                let feed_lines = self.visible_feed_count().min(4) as u16;
                1 + feed_lines // spinner + feed
            }
            Verbosity::Verbose => {
                let feed_lines = self.visible_feed_count().min(8) as u16;
                1 + feed_lines
            }
        }
    }

    fn visible_feed_count(&self) -> usize {
        match self.verbosity {
            Verbosity::Off => 0,
            Verbosity::New => {
                // Only show if tool changed
                if self.tool_feed.is_empty() {
                    0
                } else {
                    1
                }
            }
            Verbosity::All => self.tool_feed.len().min(4),
            Verbosity::Verbose => self.tool_feed.len().min(8),
        }
    }
}

impl Component for Activity {
    fn handle_event(&mut self, _event: &Event) -> ComponentAction {
        ComponentAction::Ignored
    }

    fn draw(&self, frame: &mut Frame, area: Rect) {
        if !self.active || area.height == 0 {
            return;
        }
        let theme = crate::style::theme();
        let elapsed = self.start_time.map(|t| t.elapsed().as_secs()).unwrap_or(0);

        // Spinner animation
        let spinner_frames = ["\u{25cb}", "\u{25d4}", "\u{25d1}", "\u{25d5}", "\u{25cf}"];
        let spinner_char = spinner_frames[(self.phrase_tick as usize / 2) % spinner_frames.len()];

        // Phase-driven spinner line — shows real backend state
        let elapsed_str = format_elapsed(elapsed);
        let mut spinner_spans: Vec<Span<'_>> = match self.phase {
            ProcessingPhase::Waiting => vec![
                Span::styled(format!("{} ", spinner_char), theme.spinner()),
                Span::styled("waiting for response...", theme.prefix_active()),
                Span::styled(format!(" ({})", elapsed_str), theme.faint()),
            ],
            ProcessingPhase::Thinking => {
                let chars = format_count(self.thinking_chars);
                vec![
                    Span::styled(format!("\u{1f9e0} {} ", spinner_char), theme.spinner()),
                    Span::styled("thinking", theme.prefix_active()),
                    Span::styled(format!(" ({})", elapsed_str), theme.faint()),
                    Span::styled(format!(" \u{00b7} {} chars", chars), theme.faint()),
                ]
            }
            ProcessingPhase::Streaming => {
                let chars = format_count(self.stream_chars);
                vec![
                    Span::styled(format!("{} ", spinner_char), theme.spinner()),
                    Span::styled("streaming", theme.prefix_active()),
                    Span::styled(format!(" ({}, {})", chars, elapsed_str), theme.faint()),
                ]
            }
            ProcessingPhase::ToolCall => vec![
                Span::styled(format!("{} ", spinner_char), theme.spinner()),
                Span::styled(
                    format!("tool: {}", self.last_tool_name),
                    theme.prefix_active(),
                ),
                Span::styled(format!(" ({})", elapsed_str), theme.faint()),
            ],
            ProcessingPhase::Synthesizing => vec![
                Span::styled(format!("{} ", spinner_char), theme.spinner()),
                Span::styled("synthesizing", theme.prefix_active()),
                Span::styled(format!(" ({})", elapsed_str), theme.faint()),
            ],
        };

        // Model name prefix (e.g. "qwen3-coder:480b ∙ ")
        if !self.model_name.is_empty() {
            spinner_spans.insert(
                0,
                Span::styled(format!("{} \u{2219} ", self.model_name), theme.faint()),
            );
        }

        // Iteration indicator (only shown for multi-iteration requests)
        if self.llm_iteration > 1 {
            spinner_spans.push(Span::styled(
                format!(" \u{00b7} iter {}", self.llm_iteration),
                theme.faint(),
            ));
        }

        // Token counts from LlmResponse events
        if self.input_tokens > 0 || self.output_tokens > 0 {
            spinner_spans.push(Span::styled(
                format!(
                    "  \u{25b8} {}in/{}out",
                    self.input_tokens, self.output_tokens
                ),
                theme.faint(),
            ));
        }

        let spinner_line = Line::from(spinner_spans);
        frame.render_widget(
            Paragraph::new(spinner_line),
            Rect::new(area.x, area.y, area.width, 1),
        );

        if self.verbosity == Verbosity::Off || area.height < 2 {
            return;
        }

        // Tool feed lines (Hermes-style: ┊ emoji verb  detail  duration)
        let max_lines = (area.height - 1) as usize;
        let feed_start = if self.tool_feed.len() > max_lines {
            self.tool_feed.len() - max_lines
        } else {
            0
        };

        for (i, entry) in self.tool_feed[feed_start..].iter().enumerate() {
            if i >= max_lines {
                break;
            }
            let y = area.y + 1 + i as u16;
            if y >= area.y + area.height {
                break;
            }

            let mut spans: Vec<Span<'_>> = vec![
                Span::styled("\u{2506} ", theme.faint()),
                Span::raw(format!("{} ", entry.emoji)),
                Span::styled(format!("{:<10}", entry.verb), theme.prefix_active()),
            ];

            if !entry.detail.is_empty() && self.verbosity != Verbosity::New {
                spans.push(Span::styled(&entry.detail, theme.faint()));
                spans.push(Span::raw("  "));
            }

            // Duration / status
            match (entry.duration_ms, entry.success) {
                (Some(ms), Some(true)) => {
                    spans.push(Span::styled(
                        format!("{:.1}s", ms as f64 / 1000.0),
                        theme.task_done(),
                    ));
                }
                (Some(ms), Some(false)) => {
                    spans.push(Span::styled(
                        format!("{:.1}s [error]", ms as f64 / 1000.0),
                        theme.error_text(),
                    ));
                }
                _ => {
                    // Still running
                    let running_ms = entry.start.elapsed().as_millis();
                    spans.push(Span::styled(
                        format!("{:.1}s...", running_ms as f64 / 1000.0),
                        theme.faint(),
                    ));
                }
            }

            let line = Line::from(spans);
            frame.render_widget(Paragraph::new(line), Rect::new(area.x, y, area.width, 1));
        }
    }
}
