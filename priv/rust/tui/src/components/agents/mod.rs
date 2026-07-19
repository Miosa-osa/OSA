pub mod entry;
mod render;

use ratatui::prelude::*;

use crate::event::Event;
use crate::event::backend::SpawningAgent;

use super::{Component, ComponentAction};
use entry::{AgentEntry, SwarmInfo, SwarmStatus, SynthesisState, WaveInfo};
pub use entry::AgentStatus;
pub use entry::BgTerminalRow;

// ─── Batch grouping ──────────────────────────────────────────────────────────

pub(super) struct BatchGroup {
    pub batch_id: Option<String>,
    pub entries: Vec<usize>, // indices into Agents.entries
}


// ─── Component ────────────────────────────────────────────────────────────────

pub struct Agents {
    active: bool,
    task_id: Option<String>,
    entries: Vec<AgentEntry>,
    wave: Option<WaveInfo>,
    swarm: Option<SwarmInfo>,
    collapsed: bool,
    synthesis: SynthesisState,
    tick: u64,
    /// Count of background "terminals" (Ctrl+B'd turns + running background shell
    /// commands) that aren't tree entries. Drives the always-visible
    /// "N background terminals · ↓ to manage" summary line. Set by `App`.
    bg_summary: usize,
    /// Task-level appraised cost in USD from `orchestrator_task_appraised`. The
    /// backend does NOT report per-agent cost, so this whole-task estimate is the
    /// only cost signal available; the dashboard surfaces it and notes the
    /// per-agent breakdown is absent (rather than fabricating one from tokens).
    est_cost_usd: Option<f64>,
}

impl Agents {
    pub fn new() -> Self {
        Self {
            active: false,
            task_id: None,
            entries: Vec::new(),
            wave: None,
            swarm: None,
            collapsed: false,
            synthesis: SynthesisState::Idle,
            tick: 0,
            bg_summary: 0,
            est_cost_usd: None,
        }
    }

    /// Set the combined background-terminals count shown in the summary line.
    pub fn set_bg_summary(&mut self, count: usize) {
        self.bg_summary = count;
    }

    /// Record the task-level appraised cost (USD) surfaced in the dashboard.
    pub fn set_estimated_cost(&mut self, usd: f64) {
        self.est_cost_usd = Some(usd);
    }

    /// Task-level appraised cost in USD, if the backend has appraised the task.
    pub fn est_cost_usd(&self) -> Option<f64> {
        self.est_cost_usd
    }

    /// One-line "name — action" summary for the entry at `idx`, used when the
    /// dashboard "view" action is invoked on an agent (the TUI keeps no separate
    /// per-agent output buffer, so this is the richest state available).
    pub fn entry_summary_at(&self, idx: usize) -> Option<String> {
        self.entries.get(idx).map(|e| {
            let who = if e.subject.is_empty() { &e.name } else { &e.subject };
            let action = match e.status {
                AgentStatus::Completed => "done".to_string(),
                AgentStatus::Failed if e.current_action.is_empty() => "failed".to_string(),
                _ if e.current_action.is_empty() => "starting…".to_string(),
                _ => e.current_action.clone(),
            };
            format!(
                "{} — {} · {} tool{} · {} tok · {}",
                who,
                action,
                e.tool_uses,
                if e.tool_uses == 1 { "" } else { "s" },
                e.tokens_used,
                crate::util::fmt_elapsed(e.elapsed_secs()),
            )
        })
    }

    /// Number of running/spawning background subagents tracked in the panel
    /// (tagged with the "background" batch id at spawn time).
    pub fn background_summary_count(&self) -> usize {
        self.entries
            .iter()
            .filter(|e| {
                e.batch_id.as_deref() == Some("background")
                    && matches!(e.status, AgentStatus::Running | AgentStatus::Spawning)
            })
            .count()
    }

    pub fn is_active(&self) -> bool {
        self.active
    }

    /// Number of tracked agent entries (running + finished). Used by the
    /// full-screen dashboard for selection bounds.
    pub fn entry_count(&self) -> usize {
        self.entries.len()
    }

    /// True if any agent has ever been tracked this session — gates opening the
    /// dashboard.
    pub fn has_entries(&self) -> bool {
        !self.entries.is_empty()
    }

    /// Stable id (entry name / agent_id) of the entry at `idx` in dashboard order,
    /// used to target the backend cancel endpoint.
    pub fn agent_id_at(&self, idx: usize) -> Option<String> {
        self.entries.get(idx).map(|e| e.name.clone())
    }

    /// True when the entry at `idx` is still cancellable (running or spawning).
    pub fn is_cancellable(&self, idx: usize) -> bool {
        self.entries
            .get(idx)
            .map(|e| matches!(e.status, AgentStatus::Running | AgentStatus::Spawning))
            .unwrap_or(false)
    }

    /// Total render height: 0 when inactive, else header + 2*agents + batch headers + optional synth + swarm.
    /// Capped at 30 to prevent degenerate cases.
    pub fn height(&self) -> u16 {
        // The background-terminals summary line renders even when the agent tree
        // is inactive, so it contributes a row on its own.
        let summary_line = if self.bg_summary > 0 { 1u16 } else { 0 };
        if !self.active {
            return summary_line;
        }
        if self.collapsed {
            return 1 + summary_line;
        }
        let agent_lines: u16 = self.entries.iter().map(Self::entry_rows).sum();
        let batch_header_lines = {
            let groups = self.grouped_entries();
            // Only show batch headers if any entry has a batch_id
            let has_batches = groups.iter().any(|g| g.batch_id.is_some());
            if has_batches { groups.len() as u16 } else { 0 }
        };
        let synth_lines = if matches!(self.synthesis, SynthesisState::Synthesizing { .. }) {
            1u16
        } else {
            0
        };
        let swarm_lines = if self.swarm.is_some() { 1u16 } else { 0 };
        // summary + 1 header + batch headers + agents + synth + swarm
        let total =
            summary_line + 1 + batch_header_lines + agent_lines + synth_lines + swarm_lines;
        total.min(30)
    }

    /// Rows the tree needs for one agent: 1 subject row + the action trail.
    /// Running agents show up to the last 3 recent actions plus a "+N more tool
    /// uses" counter line (CC MAX_PROGRESS_MESSAGES_TO_SHOW=3); terminal agents
    /// keep the compact 2-row layout. MUST stay in lockstep with the trail
    /// built in `draw_tree` or the layout desyncs.
    pub(super) fn entry_rows(entry: &AgentEntry) -> u16 {
        match entry.status {
            AgentStatus::Running | AgentStatus::Spawning => {
                let shown = entry.recent_actions.len().min(3);
                let more = usize::from(entry.tool_uses as usize > shown);
                1 + (shown + more).max(1) as u16
            }
            _ => 2,
        }
    }

    /// Advance spinner animation frame + clear dead/stale ghosts so the panel
    /// never shows a "Running … 14m" row for an agent that actually died.
    pub fn tick(&mut self) {
        self.tick = self.tick.wrapping_add(1);
        self.prune_stale();
    }

    /// How long a still-"Running" agent may go silent before we treat it as dead.
    const STALE_SECS: u64 = 90;
    /// How long a finished (Completed/Failed) row lingers before it's removed so
    /// the panel doesn't accumulate old rows.
    const RETAIN_SECS: u64 = 20;

    /// Reconcile the panel with reality: mark silent running agents as Failed
    /// (they crashed / were rate-limited / the backend dropped their stream), and
    /// drop finished rows that have lingered past the retain window. Idempotent,
    /// cheap, safe to call every tick.
    pub fn prune_stale(&mut self) {
        // 1. Silent runners → Failed (stops the forever-"Running" ghost).
        for e in self.entries.iter_mut() {
            if e.is_stale(Self::STALE_SECS) {
                e.status = AgentStatus::Failed;
                if e.current_action.is_empty() || e.current_action == "complete" {
                    e.current_action = "stalled".into();
                }
                e.finished_at.get_or_insert_with(std::time::Instant::now);
            }
        }
        // 2. Old finished rows → removed.
        self.entries.retain(|e| match e.status {
            AgentStatus::Completed | AgentStatus::Failed => e
                .finished_at
                .map(|t| t.elapsed().as_secs() < Self::RETAIN_SECS)
                .unwrap_or(true),
            _ => true,
        });
        // Panel goes idle once nothing is left to show.
        if self.entries.is_empty() {
            self.active = false;
        }
    }

    // ─── Public mutation API ─────────────────────────────────────────────────

    pub fn task_started(&mut self, task_id: impl Into<String>) {
        self.active = true;
        self.task_id = Some(task_id.into());
        self.entries.clear();
        self.wave = None;
        self.swarm = None;
        self.synthesis = SynthesisState::Idle;
        self.collapsed = false;
        self.est_cost_usd = None;
    }

    pub fn on_agents_spawning(&mut self, agents: &[SpawningAgent]) {
        // Pre-populate entries in Spawning state
        for agent in agents {
            if !self.entries.iter().any(|e| e.name == agent.name) {
                self.entries.push(AgentEntry {
                    name: agent.name.clone(),
                    role: agent.role.clone(),
                    model: String::new(),
                    subject: String::new(),
                    status: AgentStatus::Spawning,
                    current_action: String::new(),
                    recent_actions: Vec::new(),
                    tool_uses: 0,
                    tokens_used: 0,
                    batch_id: None,
                    started_at: std::time::Instant::now(),
                    finished_at: None,
                    last_activity: std::time::Instant::now(),
                });
            }
        }
        self.active = true;
    }

    pub fn agent_started(
        &mut self,
        name: impl Into<String>,
        role: impl Into<String>,
        model: impl Into<String>,
        subject: impl Into<String>,
        batch_id: Option<String>,
    ) {
        let name = name.into();
        let subject = subject.into();
        // Upgrade Spawning→Running by name match, or insert new
        if let Some(entry) = self.entries.iter_mut().find(|e| e.name == name) {
            entry.status = AgentStatus::Running;
            entry.model = model.into();
            entry.role = role.into();
            if !subject.is_empty() {
                entry.subject = subject;
            }
            entry.current_action = String::new();
            entry.recent_actions.clear();
            entry.tool_uses = 0;
            entry.tokens_used = 0;
            entry.started_at = std::time::Instant::now();
            entry.finished_at = None;
            entry.last_activity = std::time::Instant::now();
            if batch_id.is_some() {
                entry.batch_id = batch_id;
            }
        } else {
            self.entries.push(AgentEntry {
                name,
                role: role.into(),
                model: model.into(),
                subject,
                status: AgentStatus::Running,
                current_action: String::new(),
                recent_actions: Vec::new(),
                tool_uses: 0,
                tokens_used: 0,
                batch_id,
                started_at: std::time::Instant::now(),
                finished_at: None,
                last_activity: std::time::Instant::now(),
            });
        }
        self.active = true;
    }

    pub fn agent_progress(
        &mut self,
        name: &str,
        action: impl Into<String>,
        tool_uses: u32,
        tokens: u32,
        subject: impl Into<String>,
        recent: Vec<String>,
    ) {
        let subject = subject.into();
        if let Some(entry) = self.entries.iter_mut().find(|e| e.name == name) {
            entry.last_activity = std::time::Instant::now();
            entry.current_action = action.into();
            entry.tool_uses = tool_uses;
            entry.tokens_used = tokens;
            if !recent.is_empty() {
                entry.recent_actions = recent;
            } else {
                // Older backends don't send the trail — synthesize it from the
                // successive current_action values (newest first, keep 5).
                let cur = entry.current_action.clone();
                if !cur.is_empty() && entry.recent_actions.first() != Some(&cur) {
                    entry.recent_actions.insert(0, cur);
                    entry.recent_actions.truncate(5);
                }
            }
            if !subject.is_empty() && entry.subject.is_empty() {
                entry.subject = subject;
            }
        }
    }

    pub fn agent_completed(&mut self, name: &str, tool_uses: u32, tokens: u32) {
        if let Some(entry) = self.entries.iter_mut().find(|e| e.name == name) {
            entry.status = AgentStatus::Completed;
            entry.current_action = "complete".into();
            entry.tool_uses = tool_uses;
            entry.tokens_used = tokens;
            entry.finished_at = Some(std::time::Instant::now());
        }
    }

    pub fn agent_failed(
        &mut self,
        name: &str,
        error: impl Into<String>,
        tool_uses: u32,
        tokens: u32,
    ) {
        if let Some(entry) = self.entries.iter_mut().find(|e| e.name == name) {
            entry.status = AgentStatus::Failed;
            entry.current_action = error.into();
            entry.tool_uses = tool_uses;
            entry.tokens_used = tokens;
            entry.finished_at = Some(std::time::Instant::now());
        }
    }

    /// Optimistically flag an agent as cancelled (preserving its recorded
    /// tool/token counts) so the dashboard reflects the action immediately, even
    /// before the backend's terminal event lands.
    pub fn mark_cancelled(&mut self, name: &str) {
        if let Some(entry) = self.entries.iter_mut().find(|e| e.name == name) {
            if matches!(entry.status, AgentStatus::Running | AgentStatus::Spawning) {
                entry.status = AgentStatus::Failed;
                entry.current_action = "cancelled".into();
                entry.finished_at = Some(std::time::Instant::now());
            }
        }
    }

    pub fn wave_started(&mut self, current: u32, total: u32) {
        self.wave = Some(WaveInfo { current, total });
    }

    pub fn on_synthesizing(&mut self, count: usize) {
        self.synthesis = SynthesisState::Synthesizing { count };
    }

    pub fn task_completed(&mut self) {
        self.synthesis = SynthesisState::Idle;
        // Keep active briefly so the user can see final state; caller hides.
        self.active = false;
    }

    pub fn toggle_collapse(&mut self) {
        self.collapsed = !self.collapsed;
    }

    pub fn swarm_started(
        &mut self,
        id: impl Into<String>,
        pattern: impl Into<String>,
        count: u32,
    ) {
        self.swarm = Some(SwarmInfo {
            id: id.into(),
            pattern: pattern.into(),
            agent_count: count,
            status: SwarmStatus::Running,
        });
        self.active = true;
    }

    pub fn swarm_completed(&mut self, id: &str) {
        if let Some(ref mut s) = self.swarm {
            if s.id == id {
                s.status = SwarmStatus::Completed;
            }
        }
    }

    pub fn swarm_failed(&mut self, id: &str, _reason: &str) {
        if let Some(ref mut s) = self.swarm {
            if s.id == id {
                s.status = SwarmStatus::Failed;
            }
        }
    }

    /// Group entries by batch_id, preserving order of first appearance.
    /// Entries with `batch_id: None` go in a single "default" group.
    pub(super) fn grouped_entries(&self) -> Vec<BatchGroup> {
        let mut groups: Vec<BatchGroup> = Vec::new();
        for (i, entry) in self.entries.iter().enumerate() {
            if let Some(group) = groups.iter_mut().find(|g| g.batch_id == entry.batch_id) {
                group.entries.push(i);
            } else {
                groups.push(BatchGroup {
                    batch_id: entry.batch_id.clone(),
                    entries: vec![i],
                });
            }
        }
        groups
    }

    // Phase 2: called when session resets wipe agent panel state
    #[allow(dead_code)]
    pub fn clear(&mut self) {
        self.active = false;
        self.task_id = None;
        self.entries.clear();
        self.wave = None;
        self.swarm = None;
        self.synthesis = SynthesisState::Idle;
        self.collapsed = false;
        self.bg_summary = 0;
        self.est_cost_usd = None;
    }
}

impl Component for Agents {
    fn handle_event(&mut self, _event: &Event) -> ComponentAction {
        ComponentAction::Ignored
    }

    fn draw(&self, frame: &mut Frame, area: Rect) {
        // Draw when the agent tree is active OR there's a background-terminals
        // summary to surface (the summary renders even with no live agents).
        if (!self.active && self.bg_summary == 0) || area.height == 0 || area.width == 0 {
            return;
        }
        self.draw_tree(frame, area);
    }
}
