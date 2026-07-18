// ─── Types ────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum AgentStatus {
    Spawning,
    Running,
    Completed,
    Failed,
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
}

impl AgentEntry {
    /// Wall-clock elapsed for this agent: live for running agents, frozen at the
    /// terminal transition for completed/failed ones.
    pub fn elapsed_secs(&self) -> u64 {
        let end = self.finished_at.unwrap_or_else(std::time::Instant::now);
        end.saturating_duration_since(self.started_at).as_secs()
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

