// ─── Types ────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum AgentStatus {
    Spawning,
    Running,
    /// The backend has sent nothing for this agent in a long while and we do
    /// NOT know why. Silence is not death: a background subagent emits
    /// `started` BEFORE it waits for a concurrency slot and emits nothing at
    /// all while queued, so a perfectly healthy agent can be silent for
    /// minutes. This state says exactly that — "we lost the signal" — instead
    /// of inventing a failure. It is NOT terminal: any later progress event
    /// returns the row to `Running`, and a terminal event still decides
    /// Completed/Failed.
    Unknown,
    /// The BACKEND reported this agent as making no progress
    /// (`background_agent_stalled`, phase-aware). Unlike `Unknown` this is a
    /// positive observation from the side that can actually see the run, so
    /// the row states the measured duration. Still not terminal — a stalled
    /// agent can recover, and only a terminal event may end it.
    Stalled,
    Completed,
    Failed,
}

impl AgentStatus {
    /// Terminal states are the ONLY ones a completion event may produce. Used
    /// by the roster/footer counters (a finished agent is not "running") and by
    /// the retain-window reaper.
    pub fn is_terminal(self) -> bool {
        matches!(self, AgentStatus::Completed | AgentStatus::Failed)
    }
}

#[derive(Debug, Clone)]
pub struct AgentEntry {
    pub name: String,
    pub role: String,
    pub model: String,
    pub subject: String,
    pub status: AgentStatus,
    pub current_action: String,
    /// Last few completed tool actions, NEWEST FIRST (backend sends up to 5);
    /// the tree renders the last 3 as a trail with a "+N more" counter.
    pub recent_actions: Vec<String>,
    pub tool_uses: u32,
    pub tokens_used: u32,
    pub batch_id: Option<String>,
    /// When this agent entry was first created — drives the dashboard "elapsed"
    /// column for running agents.
    pub started_at: std::time::Instant,
    /// Set when the agent reaches a terminal state (Completed/Failed) so its
    /// elapsed time freezes instead of ticking forever.
    pub finished_at: Option<std::time::Instant>,
    /// Last time the backend sent ANY signal for this agent (spawn / start /
    /// progress). If a running agent goes silent (crashed, rate-limited, backend
    /// dropped it) it stops updating this — so the panel can detect it as stale
    /// and stop showing a dead "Running … 14m" ghost forever.
    pub last_activity: std::time::Instant,
    /// Compact one-line preview of what this worker PRODUCED, set when it reaches
    /// a terminal state (the first meaningful line of its final result, or a
    /// short error on failure). Rendered as a dim `⎿ <summary>` line under the
    /// finished row so a fan-out shows the outcome, not just "@name finished".
    /// `None` while running or when the backend sent no summary.
    pub result_summary: Option<String>,
    /// What this agent cost in USD, as reported by the backend's durable spend
    /// record on its terminal event.
    ///
    /// `None` is load-bearing and means "we were not told", which is NOT the
    /// same claim as `Some(0.0)`. It renders as `—`; rendering it as `$0.00`
    /// would be the panel asserting a measurement nobody made.
    pub cost_usd: Option<f64>,
}

impl AgentEntry {
    /// Wall-clock elapsed for this agent: live for running agents, frozen at the
    /// terminal transition for completed/failed ones.
    pub fn elapsed_secs(&self) -> u64 {
        let end = self.finished_at.unwrap_or_else(std::time::Instant::now);
        end.saturating_duration_since(self.started_at).as_secs()
    }

    /// A still-"running" agent that hasn't sent any signal for `secs` seconds.
    /// This means the TUI has lost the signal — NOT that the agent died. It may
    /// be queued behind the background concurrency cap, waiting on a slow first
    /// completion, or genuinely wedged; the panel cannot tell the difference
    /// and must not pretend it can.
    pub fn is_stale(&self, secs: u64) -> bool {
        matches!(self.status, AgentStatus::Running | AgentStatus::Spawning)
            && self.last_activity.elapsed().as_secs() >= secs
    }

    /// Whole minutes since the last backend signal, floored at 1 so the
    /// `Unknown` row never claims "0m ago" for a gap it only noticed because it
    /// was already long.
    pub fn silent_mins(&self) -> u64 {
        (self.last_activity.elapsed().as_secs() / 60).max(1)
    }
}

/// A background "terminal" row for the dashboard management view: a Ctrl+B'd
/// turn kept running on the backend. Built by `App` from its `bg_tasks` and
/// passed into `draw_dashboard` so the dashboard can list, select, view and stop
/// background terminals alongside sub-agents.
#[derive(Debug, Clone)]
pub struct BgTerminalRow {
    /// Stable 1-based label shown as "[N]".
    pub id: usize,
    /// Short human summary (the prompt that started the turn).
    pub summary: String,
    /// Wall-clock elapsed since the turn started.
    pub elapsed_secs: u64,
    /// True once the backgrounded turn's answer has landed.
    pub done: bool,
}

/// One recent write/append to the shared file-based scratchpad during a
/// fan-out. Rendered as a compact dim line under the agent rows so the user
/// watches coordination artifacts accumulate. Carries no file contents — only
/// who/what/size. Transient: the whole list is cleared when the team finishes or
/// a new top-level turn starts.
#[derive(Debug, Clone)]
pub struct ScratchpadNote {
    /// Writing agent id (a session id like `agent:<parent>:1`, or the
    /// coordinator's own session for a top-level write).
    pub agent: String,
    /// Entry name written, e.g. `findings.md`.
    pub entry: String,
    /// Past-tense verb shown to the user: "wrote" (write) or "appended" (append).
    pub action: &'static str,
    /// Byte size of the write, formatted compactly (2100 → "2.1k").
    pub bytes: u64,
}

/// Synthetic `main` root row shown at the top of the roster (inline + full
/// dashboard). It is NOT a backend agent — the TUI synthesizes it from live
/// session state (top-level action, turn elapsed, session output tokens). Always
/// roster index 0, never cancellable; selecting it detaches back to the main
/// transcript.
#[derive(Debug, Clone, Default)]
pub struct MainRow {
    /// One-line summary of the current top-level action (goal / working state).
    pub activity: String,
    /// Turn elapsed in seconds (frozen at 0 when idle).
    pub elapsed_secs: u64,
    /// Cumulative session output tokens.
    pub tokens: u32,
}

#[derive(Debug, Clone)]
pub struct WaveInfo {
    pub current: u32,
    pub total: u32,
}

#[derive(Debug, Clone)]
pub struct SwarmInfo {
    pub id: String,
    pub pattern: String,
    pub agent_count: u32,
    pub status: SwarmStatus,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum SwarmStatus {
    Running,
    Completed,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum SynthesisState {
    Idle,
    Synthesizing { count: usize },
}

impl Default for SynthesisState {
    fn default() -> Self {
        Self::Idle
    }
}

