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

/// Why the turn is currently *blocked*, so the spinner can name the wait
/// instead of showing a random flavor verb during a multi-minute stall (grok
/// `WaitingReason::label()`, `acp/tracker.rs:124`). Set from the backend
/// phase signal; `None` ⇒ fall back to the flavor verb.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WaitingReason {
    /// Waiting for the model to (re)start streaming (first token / post-tool gap).
    Model,
    /// Blocked on a running foreground subagent (`delegate` / `Task`).
    Subagent,
    /// Blocked polling/awaiting a background task's output.
    TaskOutput,
    /// Blocked until one or more background tasks finish.
    Tasks,
    /// Explicit sleep / await.
    Sleeping,
    /// Context auto-compaction in progress.
    Compacting,
    /// Verifying / finishing the response.
    Verifying,
}

impl WaitingReason {
    /// Human label for the spinner verb slot. No trailing ellipsis — the
    /// spinner row appends `…` itself.
    pub fn label(self) -> &'static str {
        match self {
            Self::Model => "Waiting for response",
            Self::Subagent => "Waiting on subagent",
            Self::TaskOutput => "Waiting on task output",
            Self::Tasks => "Waiting on tasks",
            Self::Sleeping => "Sleeping",
            Self::Compacting => "Compacting",
            Self::Verifying => "Verifying",
        }
    }
}

/// Live retry / rate-limit state held on the spinner row during a mid-turn
/// stall (grok `turn_status.rs:647`, opencode `prompt/index.tsx:1564`). OSA
/// already receives `BackendEvent::ProviderRetry`; this lets the spinner label
/// itself become `Retrying (attempt N/M)…` in warning-yellow with a live
/// countdown, instead of cheerfully showing a flavor verb during the drop.
#[derive(Debug, Clone)]
pub struct RetryState {
    pub attempt: u32,
    pub max_attempts: u32,
    /// Provider-supplied reason (may be empty).
    pub reason: String,
    /// When the backend expects to resume (`now + delay_ms`); drives the
    /// live "retrying in Ns" countdown.
    pub resume_at: std::time::Instant,
}

/// Position of the moving shimmer/glimmer highlight sweeping across a verb of
/// `len` chars at animation `tick` (CC `SpinnerAnimationRow` `glimmerIndex`).
/// Sweeps left→right with a short tail gap so the glimmer visibly re-enters
/// from the left rather than jumping. Returns an index; `>= len` means the
/// highlight is currently in the off-screen tail (nothing lit).
fn shimmer_index(tick: u32, len: usize) -> usize {
    if len == 0 {
        return 0;
    }
    let span = len + 3; // verb width + tail gap
    (tick as usize) % span
}

/// Whether the pending-user pulse is in its bright phase at `tick` (grok's
/// pulsing `◆`). Alternates every few ticks so the diamond breathes.
fn pulse_bright(tick: u32) -> bool {
    (tick / 3) % 2 == 0
}

/// U-T22 — the persistent interrupt affordance shown in the spinner's status
/// group. After the first in-turn Esc it becomes "esc again to interrupt" so the
/// user knows a second press ends the turn; a lone Esc never kills it.
fn interrupt_affordance(armed: bool) -> &'static str {
    if armed {
        "esc again to interrupt"
    } else {
        "esc to interrupt"
    }
}

/// U-T27 — progressive width-gating for the spinner's " (a · b · c)" status
/// group. Keeps as many LEADING (higher-priority) segments as fit in `budget`
/// columns and drops trailing ones as the pane narrows, charging the 3-column
/// " · " join between kept segments. The first segment is always kept so the
/// row never renders an empty "()".
fn gate_parts(parts: &[String], budget: usize) -> Vec<String> {
    let mut kept: Vec<String> = Vec::new();
    let mut used = 0usize;
    for (i, p) in parts.iter().enumerate() {
        let cost = p.chars().count() + if i == 0 { 0 } else { 3 };
        if i == 0 || used + cost <= budget {
            used += cost;
            kept.push(p.clone());
        } else {
            break;
        }
    }
    kept
}

/// Format large counts compactly (e.g. 1234 → "1.2k")
fn format_count(n: usize) -> String {
    if n >= 1000 {
        format!("{:.1}k", n as f64 / 1000.0)
    } else {
        format!("{}", n)
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
        "use_skill" => (">", "using skill"),

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
    /// Reasoning tokens for the latest iteration (item 4). Included in the true
    /// context total; not summed across iterations.
    reasoning_tokens: u64,
    /// Prompt-cache read tokens (item 4) — the cheap, already-cached context.
    cache_read_tokens: u64,
    /// Prompt-cache write tokens (item 4) — freshly cached this iteration.
    cache_write_tokens: u64,
    /// Cumulative OUTPUT tokens across ALL LLM iterations this turn. `set_tokens`
    /// reports the CURRENT iteration's absolute count (which resets to a small
    /// number each new iteration), so the live "↓ N tokens" must sum them here
    /// or it visibly jumps DOWN mid-turn. Reset in `start()`.
    turn_output_tokens: u64,
    /// The last iteration's absolute output count, so `set_tokens` can add only
    /// the DELTA to `turn_output_tokens` (handles both per-iteration-reset and
    /// monotonic-within-iteration reporting without double counting).
    last_iter_output: u64,
    stream_chars: usize,
    thinking_chars: usize,
    model_name: String,
    llm_iteration: u32,
    /// Per-turn iteration ceiling from the backend (item 6). None on older backends.
    llm_max_iterations: Option<u32>,
    expanded: bool,
    phrase_tick: u32,
    /// Starting index into SPINNER_VERBS for this request, so each one opens on a
    /// different verb instead of always "Accomplishing".
    verb_offset: usize,
    start_time: Option<std::time::Instant>,
    /// When the current thinking stretch began (phase == Thinking). Drives the
    /// CC-style "thinking" status segment; on leaving Thinking the duration is
    /// captured into `thought_for` so "thought for Ns" lingers briefly.
    thinking_since: Option<std::time::Instant>,
    /// (seconds, captured_at) of the last completed thinking stretch. Rendered
    /// as "thought for Ns" for 2s after capture (CC's minimum-display window),
    /// then expires by age check in `draw` — no mutation needed.
    thought_for: Option<(u64, std::time::Instant)>,
    /// When set, overrides the rotating spinner verb with the active task's
    /// present-continuous form (Claude Code's `activeForm`), so the spinner shows
    /// the concrete current step (e.g. "Wiring the checklist…") instead of a
    /// random flavor word. Cleared when no task is in progress.
    active_verb: Option<String>,
    /// Live retry/rate-limit state (item 1). `Some` while the backend is
    /// retrying a failed provider call; cleared the moment the turn resumes
    /// (tokens/stream/non-Waiting phase).
    retry: Option<RetryState>,
    /// Named blocking reason (item 3). When the phase is `Waiting`, this
    /// replaces the flavor verb with e.g. "Waiting on subagent…".
    waiting_reason: Option<WaitingReason>,
    /// Whether the turn is parked on the USER (permission prompt / question /
    /// plan approval). Drives the pulsing ◆ "you're the blocker" cue (item 5).
    pending_user: bool,
    /// U-T22 — the first Esc of an in-turn double-press has been seen, so the
    /// persistent affordance reads "esc again to interrupt" until the second
    /// Esc lands (interrupt) or a non-Esc key disarms it. A single stray Esc
    /// can no longer kill a long turn.
    interrupt_armed: bool,
    /// U-T24 — number of messages queued behind the running turn (WS5 message
    /// queue). Surfaced as an "N queued" segment in the spinner status group.
    queued: usize,
    /// Reduced-motion flag (a11y): when true the shimmer sweep is disabled and
    /// the verb renders in a single flat color.
    reduced_motion: bool,
    pub verbosity: Verbosity,
    /// Screen-reader / plain-text mode. When true, `draw` emits a single static
    /// plain-language status line (no spinner, braille bars, or boxed chrome)
    /// instead of the rich animated activity panel.
    a11y: bool,
}

/// Rotating counter so consecutive requests pick different starting verbs.
static VERB_SEED: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

/// Spinner verbs. A big playful set (seeded from Claude Code's list) PLUS our own
/// OSA / SORX / Signal-Theory flavored ones so it reads as ours, not a copy.
const SPINNER_VERBS: &[&str] = &[
    // — OSA / SORX / Signal Theory (ours) —
    "Signaling", "Denoising", "Optimizing", "Transducing", "Attenuating", "Homeostating",
    "Steering", "Resonating", "Modulating", "Amplifying", "Distilling", "Converging",
    "Pathfinding", "Aligning", "Focusing", "Sharpening", "Cohering", "Phasing",
    "Correlating", "Maximizing", "Signalizing", "Osafying", "Steersmanning", "Sorxing",
    // — playful general set —
    "Accomplishing", "Actioning", "Actualizing", "Architecting", "Baking", "Beaming",
    "Befuddling", "Billowing", "Blanching", "Bloviating", "Boogieing", "Boondoggling",
    "Booping", "Bootstrapping", "Brewing", "Bunning", "Burrowing", "Calculating",
    "Canoodling", "Caramelizing", "Cascading", "Catapulting", "Cerebrating", "Channeling",
    "Choreographing", "Churning", "Coalescing", "Cogitating", "Combobulating", "Composing",
    "Computing", "Concocting", "Considering", "Contemplating", "Cooking", "Crafting",
    "Creating", "Crunching", "Crystallizing", "Cultivating", "Deciphering", "Deliberating",
    "Determining", "Discombobulating", "Doing", "Doodling", "Drizzling", "Ebbing",
    "Effecting", "Elucidating", "Embellishing", "Enchanting", "Envisioning", "Evaporating",
    "Fermenting", "Finagling", "Flibbertigibbeting", "Flowing", "Flummoxing", "Fluttering",
    "Forging", "Forming", "Frolicking", "Frosting", "Gallivanting", "Galloping",
    "Garnishing", "Generating", "Gesticulating", "Germinating", "Grooving", "Gusting",
    "Harmonizing", "Hashing", "Hatching", "Herding", "Honking", "Hullaballooing",
    "Hyperspacing", "Ideating", "Imagining", "Improvising", "Incubating", "Inferring",
    "Infusing", "Ionizing", "Jitterbugging", "Julienning", "Kneading", "Leavening",
    "Levitating", "Lollygagging", "Manifesting", "Marinating", "Meandering", "Metamorphosing",
    "Misting", "Moonwalking", "Moseying", "Mulling", "Mustering", "Musing",
    "Nebulizing", "Nesting", "Noodling", "Nucleating", "Orbiting", "Orchestrating",
    "Osmosing", "Perambulating", "Percolating", "Perusing", "Philosophising", "Photosynthesizing",
    "Pollinating", "Pondering", "Pontificating", "Pouncing", "Precipitating", "Prestidigitating",
    "Processing", "Proofing", "Propagating", "Puttering", "Puzzling", "Quantumizing",
    "Razzmatazzing", "Recombobulating", "Reticulating", "Roosting", "Ruminating", "Scampering",
    "Schlepping", "Scurrying", "Seasoning", "Shenaniganing", "Shimmying", "Simmering",
    "Skedaddling", "Sketching", "Slithering", "Smooshing", "Spelunking", "Spinning",
    "Sprouting", "Stewing", "Sublimating", "Swirling", "Swooping", "Synthesizing",
    "Tempering", "Thinking", "Thundering", "Tinkering", "Tomfoolering", "Transfiguring",
    "Transmuting", "Twisting", "Undulating", "Unfurling", "Unravelling", "Vibing",
    "Waddling", "Wandering", "Warping", "Whirlpooling", "Whirring", "Whisking",
    "Wibbling", "Working", "Wrangling", "Zesting", "Zigzagging",
];

impl Activity {
    pub fn new() -> Self {
        Self {
            active: false,
            phase: ProcessingPhase::Waiting,
            tool_feed: Vec::new(),
            last_tool_name: String::new(),
            input_tokens: 0,
            output_tokens: 0,
            reasoning_tokens: 0,
            cache_read_tokens: 0,
            cache_write_tokens: 0,
            turn_output_tokens: 0,
            last_iter_output: 0,
            stream_chars: 0,
            thinking_chars: 0,
            model_name: String::new(),
            llm_iteration: 0,
            llm_max_iterations: None,
            expanded: false,
            phrase_tick: 0,
            verb_offset: 0,
            start_time: None,
            thinking_since: None,
            thought_for: None,
            active_verb: None,
            retry: None,
            waiting_reason: None,
            pending_user: false,
            interrupt_armed: false,
            queued: 0,
            reduced_motion: false,
            verbosity: Verbosity::All,
            a11y: false,
        }
    }

    /// Enable/disable the shimmer sweep (reduced-motion a11y). When enabled the
    /// verb renders flat; the discrete frame spinner is unaffected.
    pub fn set_reduced_motion(&mut self, on: bool) {
        self.reduced_motion = on;
    }

    /// Item 1 — begin/refresh the live retry indicator. Pass `None` to clear it
    /// explicitly (e.g. on a fatal error path).
    pub fn set_retry(&mut self, retry: Option<RetryState>) {
        self.retry = retry;
    }

    /// Whether a retry indicator is currently held on the spinner row.
    pub fn is_retrying(&self) -> bool {
        self.retry.is_some()
    }

    /// Clear the retry indicator because the turn resumed. Called from every
    /// "work is flowing again" path (tokens, stream/thinking chars, and any
    /// non-Waiting phase transition).
    fn clear_retry(&mut self) {
        self.retry = None;
    }

    /// Item 3 — name the current blocking reason (or `None` to fall back to the
    /// flavor verb). Only surfaced while the phase is `Waiting`.
    pub fn set_waiting_reason(&mut self, reason: Option<WaitingReason>) {
        self.waiting_reason = reason;
    }

    /// Item 5 — mark/unmark the turn as blocked on the USER (permission prompt,
    /// question, or plan approval), driving the pulsing ◆ cue.
    pub fn set_pending_user(&mut self, pending: bool) {
        self.pending_user = pending;
    }

    /// Whether the turn is currently parked on the user.
    pub fn pending_user(&self) -> bool {
        self.pending_user
    }

    /// Item 4 — the true context-window token number: input + output(turn) +
    /// reasoning + cache-read + cache-write (opencode `prompt/index.tsx:271`).
    /// The output component is the turn-cumulative count the spinner shows.
    pub fn total_tokens(&self) -> u64 {
        self.input_tokens
            + self.turn_output_tokens
            + self.reasoning_tokens
            + self.cache_read_tokens
            + self.cache_write_tokens
    }

    /// Enable/disable screen-reader (plain-text) mode.
    pub fn set_a11y(&mut self, on: bool) {
        self.a11y = on;
    }

    /// Whether screen-reader (plain-text) mode is active.
    pub fn a11y(&self) -> bool {
        self.a11y
    }

    /// Plain-language description of the current activity for screen-reader mode.
    /// A running tool takes precedence (announces the concrete action); otherwise
    /// falls back to the active task step, then the processing-phase label.
    fn a11y_status(&self) -> String {
        // Blocking states take precedence so a screen reader announces WHY the
        // turn is stalled, not a flavor verb.
        if self.pending_user {
            return "waiting for your input".to_string();
        }
        if let Some(r) = self.retry.as_ref() {
            return format!("retrying, attempt {} of {}", r.attempt, r.max_attempts);
        }
        if self.phase == ProcessingPhase::Waiting {
            if let Some(reason) = self.waiting_reason {
                return reason.label().to_lowercase();
            }
        }
        if let Some(entry) = self.tool_feed.iter().rev().find(|e| e.duration_ms.is_none()) {
            if entry.detail.is_empty() {
                return format!("{} ({})", entry.verb, entry.name);
            }
            return format!("{} {}", entry.verb, entry.detail);
        }
        if let Some(v) = self.active_verb.as_deref() {
            return v.to_string();
        }
        crate::a11y::phase_label(self.phase).to_string()
    }

    pub fn start(&mut self) {
        self.active = true;
        self.phase = ProcessingPhase::Waiting;
        self.tool_feed.clear();
        self.last_tool_name.clear();
        self.input_tokens = 0;
        self.output_tokens = 0;
        self.reasoning_tokens = 0;
        self.cache_read_tokens = 0;
        self.cache_write_tokens = 0;
        self.turn_output_tokens = 0;
        self.last_iter_output = 0;
        self.stream_chars = 0;
        self.thinking_chars = 0;
        self.llm_iteration = 0;
        self.llm_max_iterations = None;
        self.phrase_tick = 0;
        self.verb_offset =
            VERB_SEED.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        self.start_time = Some(std::time::Instant::now());
        self.thinking_since = None;
        self.thought_for = None;
        self.retry = None;
        self.waiting_reason = None;
        self.pending_user = false;
        self.interrupt_armed = false;
        self.queued = 0;
    }

    pub fn stop(&mut self) {
        self.active = false;
        self.phase = ProcessingPhase::Waiting;
        self.start_time = None;
        self.active_verb = None;
        self.thinking_since = None;
        self.thought_for = None;
        self.retry = None;
        self.waiting_reason = None;
        self.pending_user = false;
        self.interrupt_armed = false;
        self.queued = 0;
    }

    /// U-T22 — arm/disarm the "esc again to interrupt" affordance. Armed by the
    /// first in-turn Esc; disarmed on the interrupting second Esc or any other
    /// key. Idempotent.
    pub fn arm_interrupt(&mut self, armed: bool) {
        self.interrupt_armed = armed;
    }

    /// Whether the in-turn interrupt is armed (first Esc seen).
    pub fn is_interrupt_armed(&self) -> bool {
        self.interrupt_armed
    }

    /// U-T24 — set the number of messages queued behind the running turn.
    pub fn set_queued(&mut self, n: usize) {
        self.queued = n;
    }

    /// Seconds since the spinner clock started (`start()`), if running. This is
    /// the exact clock `draw` renders (floored the same way), exposed so the
    /// turn recap can print the same number the live spinner last showed.
    pub fn elapsed_secs(&self) -> Option<u64> {
        self.start_time.map(|t| t.elapsed().as_secs())
    }

    /// Override the spinner verb with the currently-active task's present-
    /// continuous form (Claude Code's `activeForm`). Pass `None` to fall back to
    /// the rotating flavor verbs (no task in progress).
    pub fn set_active_verb(&mut self, verb: Option<String>) {
        self.active_verb = verb.filter(|v| !v.trim().is_empty());
    }

    /// The spinner's verb: the active task's present-continuous form when a
    /// task is in progress, otherwise ONE flavor verb held for the whole turn
    /// (CC parity — seeded per request via `verb_offset`, never cycled
    /// mid-turn).
    fn spinner_verb(&self) -> &str {
        match self.active_verb.as_deref() {
            Some(v) => v,
            None => SPINNER_VERBS[self.verb_offset % SPINNER_VERBS.len()],
        }
    }

    /// Set processing phase (auto-activates if inactive). Tracks thinking
    /// stretches for the CC-style "thinking" / "thought for Ns" status segment:
    /// entering Thinking stamps the start, leaving it captures the duration
    /// (clamped to 1s minimum, CC's Math.max(1, round) parity).
    pub fn set_phase(&mut self, phase: ProcessingPhase) {
        if phase == ProcessingPhase::Thinking {
            if self.thinking_since.is_none() {
                self.thinking_since = Some(std::time::Instant::now());
            }
        } else if let Some(since) = self.thinking_since.take() {
            let secs = since.elapsed().as_secs().max(1);
            self.thought_for = Some((secs, std::time::Instant::now()));
        }
        self.phase = phase;
        // Any non-Waiting phase means the turn is producing work again, so a
        // held retry indicator and a stale "waiting on X" reason are cleared
        // (item 1/3: "clear on resume").
        if phase != ProcessingPhase::Waiting {
            self.clear_retry();
            self.waiting_reason = None;
            // The user's decision unblocked the turn (work is happening again),
            // so the "you're the blocker" pulse is stale (item 5).
            self.pending_user = false;
        }
        if !self.active {
            self.active = true;
            self.start_time = Some(std::time::Instant::now());
        }
    }

    /// Legacy compat: enable thinking indicator via phase. Routed through
    /// `set_phase` so thinking-stretch tracking sees this path too.
    pub fn set_thinking(&mut self, thinking: bool) {
        if thinking {
            self.set_phase(ProcessingPhase::Thinking);
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
        // Output is flowing again → the turn resumed; drop any retry label.
        if n > 0 {
            self.clear_retry();
        }
    }

    pub fn add_thinking_chars(&mut self, n: usize) {
        self.thinking_chars += n;
        if n > 0 {
            self.clear_retry();
        }
    }

    pub fn set_model_name(&mut self, name: &str) {
        self.model_name = name.to_string();
    }

    pub fn set_iteration(&mut self, iteration: u32) {
        self.llm_iteration = iteration;
    }

    pub fn set_max_iterations(&mut self, max_iterations: Option<u32>) {
        self.llm_max_iterations = max_iterations;
    }

    /// Record a tool call start
    pub fn tool_start(&mut self, name: &str, args: &str) {
        let (emoji, verb) = tool_display(name);
        // Truncate args for detail preview
        let detail = if args.len() > 60 {
            format!("{}...", crate::util::truncate_str(args, 57))
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

    /// Report token counts for the CURRENT LLM iteration. `output` is the
    /// iteration's absolute running count (resets each new iteration), so we add
    /// only the delta into `turn_output_tokens` — the number shown to the user —
    /// which keeps the live count monotonic across a multi-iteration turn instead
    /// of jumping down when a new iteration starts.
    pub fn set_tokens(&mut self, input: u64, output: u64) {
        self.input_tokens = input;
        self.output_tokens = output;
        let delta = if output >= self.last_iter_output {
            output - self.last_iter_output
        } else {
            // New iteration reset the per-iteration count — start it from zero.
            output
        };
        self.turn_output_tokens += delta;
        self.last_iter_output = output;
        // A usage report means the provider call succeeded → the turn resumed;
        // any retry indicator is now stale (item 1).
        self.clear_retry();
    }

    /// Item 4 — richer usage report including the input, reasoning, and prompt-
    /// cache (read/write) breakdown, so the live count reflects the true
    /// context-window number instead of output-only. `input`/`output` are
    /// threaded through `set_tokens` (which keeps the turn-cumulative output
    /// monotonic); the cache/reasoning figures are the latest iteration's
    /// absolute values.
    pub fn set_tokens_detailed(
        &mut self,
        input: u64,
        output: u64,
        reasoning: u64,
        cache_read: u64,
        cache_write: u64,
    ) {
        self.reasoning_tokens = reasoning;
        self.cache_read_tokens = cache_read;
        self.cache_write_tokens = cache_write;
        self.set_tokens(input, output);
    }

    /// Item 2 — render the verb with a moving shimmer/glimmer sweep (CC
    /// `SpinnerAnimationRow` glimmerIndex). A bright highlight travels across
    /// the glyphs, interpolating each char's color between the base spinner
    /// tint and near-white by its distance from the highlight, giving the
    /// "alive, streaming" feel. Under reduced-motion the verb is a single flat
    /// span. The trailing `…` is appended by the caller path via this fn so the
    /// ellipsis rides along uncolored-bright.
    fn shimmer_verb_spans(&self, word: &str, theme: &crate::style::Theme) -> Vec<Span<'static>> {
        let base = Color::Rgb(147, 165, 255); // theme.spinner_verb() tint
        if self.reduced_motion {
            return vec![Span::styled(
                format!("{}\u{2026}", word),
                theme.spinner_verb(),
            )];
        }
        let bright = Color::Rgb(232, 240, 255);
        let chars: Vec<char> = word.chars().collect();
        let len = chars.len();
        let pos = shimmer_index(self.phrase_tick, len) as isize;
        let radius = 2.0_f64; // highlight half-width in chars
        let mut spans: Vec<Span<'static>> = chars
            .into_iter()
            .enumerate()
            .map(|(i, ch)| {
                let dist = (i as isize - pos).abs() as f64;
                // 0 at the highlight, 1 at/beyond the radius.
                let t = (1.0 - (dist / radius)).clamp(0.0, 1.0);
                let color = crate::style::gradient::lerp_color(base, bright, t);
                Span::styled(
                    ch.to_string(),
                    Style::default().fg(color).add_modifier(Modifier::BOLD),
                )
            })
            .collect();
        spans.push(Span::styled("\u{2026}".to_string(), theme.spinner_verb()));
        spans
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
        // Plain-text mode is always a single static status line.
        if self.a11y {
            return 1;
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
        let elapsed = self
            .start_time
            .map(|t| t.elapsed().as_secs())
            .unwrap_or(0);

        // Screen-reader / plain-text mode: one static, unstyled status line. No
        // spinner glyph, no braille feed, no color — just plain language a screen
        // reader can announce ("OSA: running (bash) (12s, 1.5k tokens)").
        if self.a11y {
            let tokens =
                (self.turn_output_tokens as usize).max((self.stream_chars + self.thinking_chars) / 4);
            let mut text = format!("OSA: {} ({}", self.a11y_status(), crate::util::fmt_elapsed(elapsed));
            if tokens > 0 {
                text.push_str(&format!(", {} tokens", format_count(tokens)));
            }
            text.push(')');
            frame.render_widget(
                Paragraph::new(Line::from(Span::raw(text))),
                Rect::new(area.x, area.y, area.width, 1),
            );
            return;
        }

        let theme = crate::style::theme();

        // Star spinner (Claude Code): pulses out then back, ~200ms/frame here.
        let spinner_frames = ["\u{00b7}", "\u{2722}", "\u{2733}", "\u{2736}", "\u{273b}", "\u{273d}",
                              "\u{273d}", "\u{273b}", "\u{2736}", "\u{2733}", "\u{2722}", "\u{00b7}"];
        let spinner_char = spinner_frames[(self.phrase_tick as usize) % spinner_frames.len()];

        // Output-token count for the "↓ N tokens" suffix. Use the turn-cumulative
        // count (summed across iterations), and fall back to / floor with a
        // char-based estimate (~4 chars/token) while streaming before the backend
        // reports the first count — so the number only ever grows within a turn.
        let tokens = {
            let est = (self.stream_chars + self.thinking_chars) / 4;
            (self.turn_output_tokens as usize).max(est)
        };

        // Claude-Code line: "✻ Zesting… (28s · ↓ 1.5k tokens)". Sub-phase detail
        // (which tool is running) shows separately as the ✓ tool-result lines.
        let elapsed_str = crate::util::fmt_elapsed(elapsed);

        // CC SpinnerAnimationRow status parts, in its exact order: suffix slot
        // (our persistent "esc to interrupt" affordance), elapsed timer, token
        // count with a direction glyph (↑ while waiting on the API, ↓ once
        // output streams — CC's SpinnerModeGlyph), then the thinking status —
        // all joined with " · " inside one dim paren group:
        //   ✳ Pondering… (esc to interrupt · 12s · ↓ 1.2k tokens · thinking)
        let mut parts: Vec<String> =
            vec![interrupt_affordance(self.interrupt_armed).to_string(), elapsed_str];

        // Item 1 — live retry countdown, right after the timer so the stall is
        // the most prominent status after "esc to interrupt · Ns".
        if let Some(r) = self.retry.as_ref() {
            let remaining = r
                .resume_at
                .saturating_duration_since(std::time::Instant::now())
                .as_secs();
            if remaining > 0 {
                parts.push(format!("retrying in {}s", remaining));
            }
            if !r.reason.trim().is_empty() {
                parts.push(r.reason.clone());
            }
        }

        // Show the live token count as soon as tokens actually flow — no 30s
        // gate. On a long in-depth turn the user needs to SEE tokens ticking to
        // trust that work is happening; hiding the count for 30s read as "frozen".
        if tokens > 0 {
            let arrow = if self.phase == ProcessingPhase::Waiting {
                "\u{2191}"
            } else {
                "\u{2193}"
            };
            parts.push(format!("{} {} tokens", arrow, format_count(tokens)));
        }
        // Item 4 — surface the input + cache breakdown so the count reflects the
        // true context-window number, not output-only. Input is already tracked
        // but was never shown; cache read+write is folded into one "⚡ cached".
        if self.input_tokens > 0 {
            parts.push(format!("\u{2191} {} in", format_count(self.input_tokens as usize)));
        }
        let cached = self.cache_read_tokens + self.cache_write_tokens;
        if cached > 0 {
            parts.push(format!("\u{26A1} {} cached", format_count(cached as usize)));
        }
        // "thinking" while reasoning deltas stream; "thought for Ns" lingers
        // 2s after the stretch ends (CC's minimum-display window), expiring by
        // age — draw never mutates.
        if self.phase == ProcessingPhase::Thinking {
            parts.push("thinking".to_string());
        } else if let Some((secs, at)) = self.thought_for {
            if at.elapsed() < std::time::Duration::from_secs(2) {
                parts.push(format!("thought for {}s", secs));
            }
        }
        // U-T24 — messages queued behind the running turn. Low priority, so it
        // sits near the end and is the first segment width-gating drops.
        if self.queued > 0 {
            parts.push(format!("{} queued", self.queued));
        }

        // ── Spinner glyph + verb selection ──────────────────────────────
        // Priority of what the spinner row telegraphs:
        //   1. pending-user  → pulsing ◆ "Waiting for your input" (you're the blocker, item 5)
        //   2. retry/stall   → warning "Retrying (attempt N/M)…" (item 1)
        //   3. waiting-reason→ named "Waiting on subagent…" (item 3)
        //   4. normal        → shimmer spinner + flavor/activeForm verb (item 2)
        let (glyph_span, verb_spans): (Span<'_>, Vec<Span<'_>>) = if self.pending_user {
            // Pulsing ◆ in the accent color — one consistent "your turn" cue.
            let color = if pulse_bright(self.phrase_tick) {
                theme.colors.primary
            } else {
                theme.colors.muted
            };
            (
                Span::styled(
                    "\u{25C6} ".to_string(),
                    Style::default().fg(color).add_modifier(Modifier::BOLD),
                ),
                vec![Span::styled(
                    "Waiting for your input\u{2026}".to_string(),
                    Style::default()
                        .fg(theme.colors.primary)
                        .add_modifier(Modifier::BOLD),
                )],
            )
        } else if let Some(r) = self.retry.as_ref() {
            let warn = Style::default().fg(theme.colors.warning);
            (
                Span::styled(format!("{} ", spinner_char), warn),
                vec![Span::styled(
                    format!("Retrying (attempt {}/{})\u{2026}", r.attempt, r.max_attempts),
                    warn.add_modifier(Modifier::BOLD),
                )],
            )
        } else if self.phase == ProcessingPhase::Waiting && self.waiting_reason.is_some() {
            let label = self.waiting_reason.unwrap().label();
            (
                Span::styled(format!("{} ", spinner_char), theme.spinner_verb()),
                vec![Span::styled(format!("{}\u{2026}", label), theme.spinner_verb())],
            )
        } else {
            // When a task is in progress, show its concrete active step (Claude
            // Code's activeForm). Otherwise ONE flavor verb per turn (CC parity).
            let word = self.spinner_verb().to_string();
            (
                Span::styled(format!("{} ", spinner_char), theme.spinner_verb()),
                self.shimmer_verb_spans(&word, &theme),
            )
        };

        // U-T27 — drop trailing status segments as the pane narrows. Budget is
        // the width left after the model prefix, spinner glyph (2 cols) and the
        // verb spans, minus the " (" / ")" wrapper.
        let model_cols = if self.model_name.is_empty() {
            0
        } else {
            self.model_name.chars().count() + 3
        };
        let verb_cols: usize =
            verb_spans.iter().map(|s| s.content.chars().count()).sum::<usize>() + 2;
        let budget = (area.width as usize).saturating_sub(model_cols + verb_cols + 4);
        let parts = gate_parts(&parts, budget);

        let mut spinner_spans: Vec<Span<'_>> = Vec::with_capacity(verb_spans.len() + 3);
        spinner_spans.push(glyph_span);
        spinner_spans.extend(verb_spans);
        spinner_spans.push(Span::styled(
            format!(" ({})", parts.join(" \u{00b7} ")),
            theme.faint(),
        ));

        // Model name prefix (e.g. "qwen3-coder:480b ∙ ")
        if !self.model_name.is_empty() {
            spinner_spans.insert(
                0,
                Span::styled(format!("{} \u{2219} ", self.model_name), theme.faint()),
            );
        }

        // Iteration indicator (only shown for multi-iteration requests). When the
        // backend supplies the per-turn ceiling, show "iter N/max" and switch to a
        // warning color as the loop approaches the cap so the user sees it coming.
        if self.llm_iteration > 1 {
            let (label, style) = match self.llm_max_iterations {
                Some(max) if max > 0 => {
                    // within the last 20% of the ceiling → warn
                    let near_cap = self.llm_iteration.saturating_mul(5) >= max.saturating_mul(4);
                    let style = if near_cap {
                        Style::default().fg(theme.colors.warning)
                    } else {
                        theme.faint()
                    };
                    (format!(" \u{00b7} iter {}/{}", self.llm_iteration, max), style)
                }
                _ => (format!(" \u{00b7} iter {}", self.llm_iteration), theme.faint()),
            };
            spinner_spans.push(Span::styled(label, style));
        }

        // NOTE: token counts are NOT rendered a second time here. They already
        // appear in the CC-style paren group above ("↓ 1.2k tokens"). A separate
        // "▸ Nin/Nout" span duplicated the count on the same line and read as two
        // token displays — removed for a single, uncluttered status line.

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
            frame.render_widget(
                Paragraph::new(line),
                Rect::new(area.x, y, area.width, 1),
            );
        }
    }
}

#[cfg(test)]
mod activity_tests {
    use super::*;

    #[test]
    fn tool_start_multibyte_args_never_panic() {
        // Args whose byte 57 lands inside a multi-byte char (the old &args[..57]
        // slice would panic). Leading 'a' shifts the 3-byte '€' run off byte 57.
        let mb = format!("a{}", "\u{20ac}".repeat(40));
        let mut act = Activity::new();
        act.tool_start("Bash", &mb);
        act.tool_start("Read", "short ascii");
        act.tool_start("Web", &"\u{1f600}".repeat(30)); // 4-byte emoji run
        assert!(!act.tool_feed.is_empty());
    }

    #[test]
    fn thinking_stretch_is_tracked_across_phases() {
        let mut act = Activity::new();
        act.start();
        act.set_phase(ProcessingPhase::Thinking);
        assert!(act.thinking_since.is_some());
        assert!(act.thought_for.is_none());
        act.set_phase(ProcessingPhase::Streaming);
        assert!(act.thinking_since.is_none());
        let (secs, _) = act.thought_for.expect("thought_for captured on leave");
        assert!(secs >= 1, "sub-second stretches clamp to 1s (CC parity)");
        // Legacy set_thinking path routes through set_phase tracking too.
        act.set_thinking(true);
        assert!(act.thinking_since.is_some());
        // A new turn clears both.
        act.start();
        assert!(act.thinking_since.is_none() && act.thought_for.is_none());
    }

    #[test]
    fn spinner_verb_is_stable_for_a_turn() {
        let mut act = Activity::new();
        act.start();
        let v1 = act.spinner_verb().to_string();
        act.tick();
        act.tick();
        // One verb per turn — ticks/time never rotate it.
        assert_eq!(act.spinner_verb(), v1);
        // A concrete task step (activeForm) still overrides the flavor verb.
        act.set_active_verb(Some("Wiring the checklist".into()));
        assert_eq!(act.spinner_verb(), "Wiring the checklist");
        act.set_active_verb(None);
        assert_eq!(act.spinner_verb(), v1);
    }

    /// Render the active spinner row for `act` and flatten its cells to a single
    /// string (parity with status_bar's buffer-content harness).
    fn render_activity_text(act: &Activity) -> String {
        use ratatui::{backend::TestBackend, Terminal};
        let mut term = Terminal::new(TestBackend::new(120, 1)).unwrap();
        term.draw(|f| act.draw(f, f.area())).unwrap();
        term.backend()
            .buffer()
            .content()
            .iter()
            .map(|c| c.symbol())
            .collect()
    }

    #[test]
    fn retry_label_renders_from_provider_retry() {
        // Item 1 — a held RetryState makes the spinner label become the retry
        // notice (with a live countdown), not a flavor verb.
        let mut act = Activity::new();
        act.start();
        assert!(!act.is_retrying());
        act.set_retry(Some(RetryState {
            attempt: 2,
            max_attempts: 5,
            reason: "rate limited".to_string(),
            resume_at: std::time::Instant::now() + std::time::Duration::from_secs(8),
        }));
        assert!(act.is_retrying());
        let text = render_activity_text(&act);
        assert!(
            text.contains("Retrying (attempt 2/5)"),
            "retry verb must render, got: {text:?}"
        );
        assert!(text.contains("retrying in"), "countdown part must render");
        assert!(text.contains("rate limited"), "reason must render");

        // Resuming the turn (a usage report / streamed tokens) clears it.
        act.set_tokens(10, 20);
        assert!(!act.is_retrying(), "retry clears on token report");
        // Streaming chars also clear it.
        act.set_retry(Some(RetryState {
            attempt: 1,
            max_attempts: 3,
            reason: String::new(),
            resume_at: std::time::Instant::now(),
        }));
        act.add_stream_chars(4);
        assert!(!act.is_retrying(), "retry clears on stream resume");
    }

    #[test]
    fn shimmer_index_advances_and_wraps() {
        // Item 2 — the glimmer highlight moves with the tick and wraps within
        // the verb+tail span (deterministic, so the sweep is verifiable).
        let len = 6usize;
        let span = len + 3;
        let p0 = shimmer_index(0, len);
        let p1 = shimmer_index(1, len);
        let p2 = shimmer_index(2, len);
        assert_eq!(p0, 0);
        assert_eq!(p1, 1);
        assert_eq!(p2, 2);
        assert_ne!(p0, p1, "shimmer index must advance with tick");
        // Wraps at the span boundary.
        assert_eq!(shimmer_index(span as u32, len), 0);
        // Empty verb is safe.
        assert_eq!(shimmer_index(5, 0), 0);
        // Reduced-motion renders a flat verb (single styled span, no per-char).
        let act = {
            let mut a = Activity::new();
            a.start();
            a.set_reduced_motion(true);
            a
        };
        let theme = crate::style::theme();
        assert_eq!(
            act.shimmer_verb_spans("Working", &theme).len(),
            1,
            "reduced-motion verb is one flat span"
        );
        // Animated verb is per-char (+1 for the trailing ellipsis span).
        let mut anim = Activity::new();
        anim.start();
        assert_eq!(
            anim.shimmer_verb_spans("Working", &theme).len(),
            "Working".chars().count() + 1
        );
    }

    #[test]
    fn waiting_reason_label_maps() {
        // Item 3 — every reason maps to a distinct, human label.
        assert_eq!(WaitingReason::Model.label(), "Waiting for response");
        assert_eq!(WaitingReason::Subagent.label(), "Waiting on subagent");
        assert_eq!(WaitingReason::TaskOutput.label(), "Waiting on task output");
        assert_eq!(WaitingReason::Tasks.label(), "Waiting on tasks");
        assert_eq!(WaitingReason::Sleeping.label(), "Sleeping");
        assert_eq!(WaitingReason::Compacting.label(), "Compacting");
        assert_eq!(WaitingReason::Verifying.label(), "Verifying");

        // When set during the Waiting phase, the reason replaces the flavor verb.
        let mut act = Activity::new();
        act.start();
        act.set_phase(ProcessingPhase::Waiting);
        act.set_waiting_reason(Some(WaitingReason::Subagent));
        let text = render_activity_text(&act);
        assert!(
            text.contains("Waiting on subagent"),
            "waiting reason must render on the spinner, got: {text:?}"
        );
        // Leaving Waiting clears the reason (turn resumed).
        act.set_phase(ProcessingPhase::Streaming);
        assert!(!render_activity_text(&act).contains("Waiting on subagent"));
    }

    #[test]
    fn token_sum_includes_input_and_cache() {
        // Item 4 — the true total sums input + output + reasoning + cache r/w,
        // not output-only, and the input/cache figures surface on the row.
        let mut act = Activity::new();
        act.start();
        act.set_tokens_detailed(1000, 200, 50, 4000, 100);
        // total = input(1000) + turn_output(200) + reasoning(50)
        //         + cache_read(4000) + cache_write(100) = 5350
        assert_eq!(act.total_tokens(), 5350);
        assert!(
            act.total_tokens() > act.turn_output_tokens,
            "true total must exceed output-only"
        );
        let text = render_activity_text(&act);
        assert!(text.contains("in"), "input tokens must surface, got: {text:?}");
        assert!(text.contains("cached"), "cache tokens must surface");
    }

    #[test]
    fn interrupt_affordance_arms_and_renders() {
        // U-T22 — the affordance text flips on arm, and the spinner shows it.
        assert_eq!(interrupt_affordance(false), "esc to interrupt");
        assert_eq!(interrupt_affordance(true), "esc again to interrupt");

        let mut act = Activity::new();
        act.start();
        assert!(!act.is_interrupt_armed());
        assert!(render_activity_text(&act).contains("esc to interrupt"));
        act.arm_interrupt(true);
        assert!(act.is_interrupt_armed());
        let text = render_activity_text(&act);
        assert!(
            text.contains("esc again to interrupt"),
            "armed affordance must render, got: {text:?}"
        );
        // A fresh turn disarms it.
        act.start();
        assert!(!act.is_interrupt_armed());
    }

    #[test]
    fn queued_hint_renders_and_gates_out_first() {
        // U-T24 — the queued segment surfaces on the spinner.
        let mut act = Activity::new();
        act.start();
        assert!(!render_activity_text(&act).contains("queued"));
        act.set_queued(3);
        let text = render_activity_text(&act);
        assert!(text.contains("3 queued"), "queued hint must render, got: {text:?}");

        // U-T27 — width-gating keeps leading (priority) segments, drops trailing
        // ones (queued is last), and always keeps at least the first segment.
        let parts: Vec<String> = ["esc to interrupt", "12s", "\u{2193} 1.2k tokens", "3 queued"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        // Ample budget keeps everything.
        assert_eq!(gate_parts(&parts, 200).len(), 4);
        // Tight budget keeps only the first, never an empty group.
        let tight = gate_parts(&parts, 3);
        assert_eq!(tight.len(), 1);
        assert_eq!(tight[0], "esc to interrupt");
        // A middling budget drops the trailing "3 queued" before the tokens.
        let mid = gate_parts(&parts, "esc to interrupt".len() + 3 + "12s".len());
        assert!(mid.contains(&"12s".to_string()));
        assert!(!mid.contains(&"3 queued".to_string()));
        // Empty input never panics.
        assert!(gate_parts(&[], 40).is_empty());
    }

    #[test]
    fn pending_user_pulse_toggles() {
        // Item 5 — the pulse alternates bright/dim over ticks, and the flag
        // swaps the spinner to the ◆ "your turn" cue.
        assert!(pulse_bright(0));
        assert!(pulse_bright(2));
        assert!(!pulse_bright(3));
        assert!(!pulse_bright(5));
        assert!(pulse_bright(6));
        // The bright phase must actually alternate across a sweep of ticks.
        let phases: Vec<bool> = (0..12).map(pulse_bright).collect();
        assert!(phases.iter().any(|&b| b) && phases.iter().any(|&b| !b));

        let mut act = Activity::new();
        act.start();
        assert!(!act.pending_user());
        act.set_pending_user(true);
        assert!(act.pending_user());
        let text = render_activity_text(&act);
        assert!(
            text.contains('\u{25C6}'),
            "pending-user renders the pulsing ◆, got: {text:?}"
        );
        assert!(text.contains("Waiting for your input"));
        // A resuming phase clears the pending cue.
        act.set_phase(ProcessingPhase::ToolCall);
        assert!(!act.pending_user());
    }
}
