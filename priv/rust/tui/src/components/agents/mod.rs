pub mod entry;
mod render;

use ratatui::prelude::*;

use crate::event::backend::SpawningAgent;
use crate::event::Event;

use super::{Component, ComponentAction};
pub use entry::AgentStatus;
pub use entry::BgTerminalRow;
use entry::{
    AgentEntry, AgentPhase, MainRow, ScratchpadNote, SwarmInfo, SwarmStatus, SynthesisState,
    WaveInfo,
};

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
    /// Last few writes/appends to the shared file-based scratchpad, NEWEST FIRST.
    /// Capped at `SCRATCHPAD_CAP` so it never grows unbounded, and cleared when
    /// the team finishes or a new top-level turn starts — a transient, dim
    /// coordination surface, never a scrolling log.
    scratchpad: Vec<ScratchpadNote>,
    /// Synthetic `main` root row (roster index 0), fed each frame from live
    /// session state by `App::sync_chrome`. `None` until the App populates it.
    main_row: Option<MainRow>,
    /// Selection cursor in ROSTER index space (0 = `main`, 1..=entries), set
    /// while the inline `← for agents` FleetSelect mode is active; `None` when
    /// the roster is not focused (no highlight drawn).
    roster_selected: Option<usize>,
    /// Live fleet-wide counters from a `fleet_summary` frame (Part 4.2). Drives
    /// the roster header's `<running>/<cap> agents` gauge + "large fleet" hint;
    /// `None` until the backend reports, in which case the header omits it.
    fleet: Option<FleetCounts>,
    /// The session's working directory and the user's home, used ONLY to shorten
    /// paths for display (see [`crate::util::display_path`]). Trail rows were
    /// spending ~40 columns per line on a fully-qualified prefix that is identical
    /// on every sibling row and identifies nothing. Set once by `App` at startup;
    /// `None` degrades to printing the path as-is, never to a wrong path.
    workspace_root: Option<String>,
    home: Option<String>,
}

/// Fleet-wide live counts for the roster header gauge (`14/16 agents`).
#[derive(Debug, Clone, Copy)]
pub(super) struct FleetCounts {
    pub running: u32,
    pub queued: u32,
    pub cap: u32,
    pub total_spawned: u32,
    /// Backend "large fleet" signal (>=25 scheduled); drives a dim header hint.
    pub warn: bool,
}

/// Most recent shared-scratchpad writes retained + rendered under the panel.
const SCRATCHPAD_CAP: usize = 5;

/// Cap on how many agent rows the INLINE under-composer roster renders before
/// collapsing the remainder into a dim "+K more agents" summary line. Keeps the
/// inline panel bounded no matter how large the fleet grows; the full-screen
/// `/agents` dashboard (`draw_dashboard`) still lists every node.
pub(super) const INLINE_ROSTER_MAX_AGENTS: usize = 8;

/// Most recent per-agent actions rendered as the child list under one agent row
/// (CC `MAX_PROGRESS_MESSAGES_TO_SHOW`).
pub(crate) const TRAIL_MAX_ACTIONS: usize = 3;

/// Hard ceiling on the rows one agent's child list may occupy (actions + the
/// optional "+N more tool uses" counter). Deliberately equal to the `All`
/// verbosity feed ceiling in [`crate::components::activity::Activity::max_height`]
/// so a fleet row's detail block can never be taller than the tool feed it sits
/// beside — the child list is a bounded status strip, not a scrolling log.
pub(crate) const TRAIL_MAX_ROWS: usize = 4;

/// The label rendered on an agent's roster row: its live current action, falling
/// back to the subject it was spawned with.
pub(super) fn row_activity(entry: &AgentEntry) -> &str {
    // Unknown / Stalled rows state their condition on the line BELOW them, and
    // `current_action` for those rows holds that same condition string — so
    // using it here printed the identical sentence twice, stacked. It also has
    // no business claiming to be "live activity" for an agent that is by
    // definition not sending any. The head row says what the agent was given to
    // do; the line under it says what we know about its state.
    if matches!(entry.status, AgentStatus::Unknown | AgentStatus::Stalled) {
        return entry.subject.trim();
    }
    if !entry.current_action.trim().is_empty() {
        entry.current_action.trim()
    } else {
        entry.subject.trim()
    }
}

/// The de-duplicated, bounded child action list for one running agent, ordered
/// oldest → newest (the order it is drawn in).
///
/// Two sources of repetition are removed here, because both were visibly on
/// screen at once:
///   * the newest recent action is usually the SAME string the roster row
///     already shows as the agent's current action (the backend-less fallback in
///     `agent_progress` pushes `current_action` straight into `recent_actions`),
///     so the row read `explorer  dir_list` with a child `dir_list`;
///   * a tool run repeatedly with the same argument (or with none) emitted the
///     identical trail line several times.
///
/// MUST stay in lockstep with [`Agents::entry_rows`] and the trail built in
/// `draw_tree`, which is why all three go through this one function.
pub(super) fn trail_actions(entry: &AgentEntry) -> Vec<String> {
    let head = row_activity(entry);
    let mut out: Vec<String> = Vec::new();
    // `recent_actions` is newest-first; collect newest-first, then flip.
    for a in entry.recent_actions.iter() {
        let t = a.trim();
        if t.is_empty() || (!head.is_empty() && t == head) {
            continue;
        }
        // A bare verb identifies nothing. See `action_has_detail`.
        if !action_has_detail(t) {
            continue;
        }
        if out.iter().any(|e| e == t) {
            continue;
        }
        out.push(t.to_string());
        if out.len() == TRAIL_MAX_ACTIONS {
            break;
        }
    }
    out.reverse();
    out
}

/// True when a trail entry carries the VALUE that identifies the call, not just
/// the tool's verb.
///
/// The backend records a progress line twice per tool call, and the two halves
/// are not the same shape (`Orchestrator.forwarder_loop` / `Fleet.watch_loop`):
///
///   * the `start` phase records `format_action(tool, args)` → `"file_read:
///     /Users/rhl/.osa/backend.log"` — the tool AND its argument;
///   * the `end` phase records `to_string(tool_name)` → `"file_read"` — a bare
///     verb with the argument thrown away.
///
/// Both land in `recent_actions`, and `RunStore.progress`'s duplicate collapse
/// only folds CONSECUTIVE identical strings, so the two halves both survive.
/// That is exactly the trail the capture showed: `file_read: …/backend.log`
/// followed by a naked `file_read` and a naked `dir_list`, entries that tell the
/// reader nothing they did not already know from the row above.
///
/// A trail line's whole job is to name a distinct piece of work, so an entry
/// that cannot is dropped rather than rendered as a bare verb — the dropped call
/// is still counted by the "+N earlier tool uses" line, so nothing is lost.
pub fn action_has_detail(action: &str) -> bool {
    let t = action.trim();
    if t.is_empty() {
        return false;
    }
    // `verb: value` — the shape `format_action/2` emits when it has an argument.
    if let Some((verb, rest)) = t.split_once(':') {
        if !verb.trim().is_empty() && !rest.trim().is_empty() {
            return true;
        }
    }
    // Anything phrased as more than a single token ("click (3, 4)", "waiting on
    // review") is already saying something beyond the verb.
    t.split_whitespace().count() > 1
}

/// Human label for a batch header, or `None` when the batch id carries no
/// human-readable part and the header should read "Batch N" alone.
///
/// Batch ids are internal routing keys —
/// `team:session-1785550977551-3f4a8179a573:207491`. Rendered raw they ate the
/// whole separator line with a session id no reader can act on. Keep only the
/// segments that are actual words (`team`, `alpha`, `background`) and drop every
/// id-shaped one (`session-…`, hex blobs, bare numbers); when nothing survives,
/// the ordinal alone is the honest label.
/// Words that name the CONTAINER rather than its contents.
///
/// A section rule has to earn its row, and the only thing that justifies one is a
/// label that tells the reader something the heading did not. `Batch 1: batch`
/// is the degenerate case the capture caught: `short_batch_label` stripped the
/// session id and the ordinal out of `batch:session-…:207491`, and the one
/// surviving word was the noun the header already says. `Batch 1: team` and
/// `Batch 1: run` are the same failure with a different routing key.
const BATCH_NOISE_WORDS: &[&str] = &[
    "batch", "team", "group", "run", "task", "session", "agent", "agents", "fleet", "job", "work",
];
pub fn short_batch_label(batch_id: &str) -> Option<String> {
    fn id_shaped(seg: &str) -> bool {
        let s = seg.trim();
        if s.is_empty() {
            return true;
        }
        // `session-…`, `run-…`, `task-…` prefixed handles, bare numbers, and
        // long hex/digit blobs are machine identity, never a human label.
        if s.starts_with("session-") || s.starts_with("run-") || s.starts_with("task-") {
            return true;
        }
        if s.chars().all(|c| c.is_ascii_digit()) {
            return true;
        }
        let hexish = s.len() >= 8
            && s.chars()
                .all(|c| c.is_ascii_hexdigit() || c == '-' || c == '_');
        hexish && s.chars().any(|c| c.is_ascii_digit())
    }

    let kept: Vec<&str> = batch_id
        .split(':')
        .map(str::trim)
        .filter(|s| !s.is_empty() && !id_shaped(s))
        // A label that only restates the heading adds nothing but width. Dropping
        // the noise word here (rather than at the call site) means every caller
        // gets `None` — "render the ordinal alone" — for free.
        .filter(|s| !BATCH_NOISE_WORDS.contains(&s.to_ascii_lowercase().as_str()))
        .collect();
    if kept.is_empty() {
        return None;
    }
    let label = kept.join(":");
    // A surviving label is still bounded — the separator line is one row, and the
    // ordinal already carries the identity.
    Some(crate::util::fit_cols(&label, 24))
}

/// Compact an internal agent routing key into a short human label.
///
/// The backend names workers by their full routing key —
/// `agent:session-1785539672538-b5473d40b767:osa-explorer` — which is
/// meaningless to a reader and, on the spinner row, ate the whole line and
/// truncated the "esc to interrupt" affordance. Keep the trailing segment (the
/// role the worker was spawned as) and drop the `osa-` vendor prefix, so the
/// label matches the `explorer` shown on that worker's roster row.
pub fn short_agent_label(name: &str) -> String {
    let trimmed = name.trim().trim_start_matches('@');
    let tail = trimmed
        .rsplit(':')
        .find(|s| !s.trim().is_empty())
        .unwrap_or(trimmed);
    let tail = tail.trim();
    let tail = tail.strip_prefix("osa-").unwrap_or(tail);
    if tail.is_empty() {
        trimmed.to_string()
    } else {
        tail.to_string()
    }
}

impl Agents {
    /// Human label for `name` as the roster would show it: the tracked entry's
    /// role when known (the identity the worker rows display), otherwise the
    /// routing key compacted by [`short_agent_label`].
    pub fn display_label(&self, name: &str) -> String {
        if let Some(e) = self.entries.iter().find(|e| e.name == name) {
            if !e.role.trim().is_empty() {
                return e.role.trim().to_string();
            }
        }
        short_agent_label(name)
    }
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
            scratchpad: Vec::new(),
            main_row: None,
            roster_selected: None,
            fleet: None,
            workspace_root: None,
            home: std::env::var("HOME").ok().filter(|h| !h.trim().is_empty()),
        }
    }

    /// Rewrite the path inside one trail row relative to the workspace (or `~`).
    ///
    /// Display-only, and it refuses rather than guesses: a row that is not
    /// `verb: value` shaped, or whose value is not under any known root, comes
    /// back untouched.
    ///
    /// Sibling-prefix elision is deliberately NOT done here — it is a function of
    /// the row ABOVE, so the caller folds it over the shortened sequence (see
    /// `trail_display_rows`).
    pub(super) fn trail_shorten(&self, action: &str) -> String {
        match action.split_once(':') {
            // Only the value is a path; the verb must survive intact or the row
            // stops saying which tool ran.
            Some((verb, arg)) if !verb.trim().is_empty() && !arg.trim().is_empty() => format!(
                "{}: {}",
                verb.trim(),
                crate::util::display_path(
                    arg.trim(),
                    self.workspace_root.as_deref(),
                    self.home.as_deref(),
                )
            ),
            _ => action.trim().to_string(),
        }
    }

    /// The trail of one running agent as it will be DRAWN: shortened, then with
    /// each row's shared directory head collapsed against the row above it.
    ///
    /// Elision compares full shortened forms, never already-elided ones, so a run
    /// of three siblings yields `…/b`, `…/c` and not `…//c`.
    ///
    /// Row COUNT is unchanged by this function — it only rewrites text — so
    /// `entry_rows` stays authoritative for the reservation.
    pub(super) fn trail_display_rows(&self, entry: &AgentEntry) -> Vec<String> {
        let mut prev: Option<String> = None;
        let mut out = Vec::new();
        for a in trail_actions(entry) {
            let shortened = self.trail_shorten(&a);
            out.push(match prev {
                Some(ref p) => crate::util::elide_shared_prefix(p, &shortened),
                None => shortened.clone(),
            });
            prev = Some(shortened);
        }
        out
    }

    /// Record fleet-wide live counters from a `fleet_summary` frame. Drives the
    /// roster header gauge (`<running>/<cap> agents`) + "large fleet" hint.
    pub fn set_fleet_summary(
        &mut self,
        running: u32,
        queued: u32,
        cap: u32,
        total_spawned: u32,
        warn: bool,
    ) {
        self.fleet = Some(FleetCounts {
            running,
            queued,
            cap,
            total_spawned,
            warn,
        });
    }

    /// Feed the synthetic `main` root row from live session state (top-level
    /// action, turn elapsed, session output tokens). Rendered as roster index 0.
    pub fn set_main_row(&mut self, activity: impl Into<String>, elapsed_secs: u64, tokens: u32) {
        self.main_row = Some(MainRow {
            activity: activity.into(),
            elapsed_secs,
            tokens,
        });
    }

    /// Tell the panel where "here" is, so trail rows can print paths the way the
    /// user would type them instead of fully qualified. Display-only: it never
    /// affects which agent, tool or path anything actually refers to.
    pub fn set_workspace_root(&mut self, cwd: &str) {
        let cwd = cwd.trim();
        self.workspace_root = (!cwd.is_empty()).then(|| cwd.to_string());
        self.home = std::env::var("HOME").ok().filter(|h| !h.trim().is_empty());
    }

    /// Enter/update inline roster focus with the selection cursor in ROSTER
    /// index space (0 = `main`, 1..=entries). Pass `None` to leave focus (no
    /// selection highlight drawn).
    pub fn set_roster_selected(&mut self, sel: Option<usize>) {
        self.roster_selected = sel;
    }

    /// Number of selectable rows in the INLINE roster: `main` (always present)
    /// plus one per tracked agent entry. Bounds the `← for agents` nav cursor.
    pub fn roster_count(&self) -> usize {
        1 + self.entries.len()
    }

    /// Record a shared-scratchpad write/append. Pushed newest-first and capped at
    /// `SCRATCHPAD_CAP`. Activates the panel so a fan-out that coordinates purely
    /// through files still surfaces something to watch.
    pub fn scratchpad_activity(
        &mut self,
        agent: impl Into<String>,
        entry: impl Into<String>,
        action: &str,
        bytes: u64,
    ) {
        let verb = if action == "append" {
            "appended"
        } else {
            "wrote"
        };
        self.scratchpad.insert(
            0,
            ScratchpadNote {
                agent: agent.into(),
                entry: entry.into(),
                action: verb,
                bytes,
            },
        );
        self.scratchpad.truncate(SCRATCHPAD_CAP);
        self.active = true;
    }

    /// Number of recent shared-scratchpad notes currently retained (test/render aid).
    pub fn scratchpad_len(&self) -> usize {
        self.scratchpad.len()
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

    /// One-line "name — action" summary for the roster row at `idx`, used when
    /// the dashboard/inline "view" action is invoked on an agent (the TUI keeps
    /// no separate per-agent output buffer, so this is the richest state
    /// available). Index is ROSTER space: 0 = `main` (synthetic, no worker
    /// transcript → `None`), 1..=entries maps to `entries[idx-1]`.
    pub fn entry_summary_at(&self, idx: usize) -> Option<String> {
        let idx = idx.checked_sub(1)?;
        self.entries.get(idx).map(|e| {
            let who = if e.subject.is_empty() {
                &e.name
            } else {
                &e.subject
            };
            let action = match e.status {
                AgentStatus::Completed => "done".to_string(),
                AgentStatus::Failed if e.current_action.is_empty() => "failed".to_string(),
                _ if e.current_action.is_empty() => "starting…".to_string(),
                _ => e.current_action.clone(),
            };
            let mut summary = format!(
                "{} — {} · {} tool{} · {} tok · {}",
                who,
                action,
                e.tool_uses,
                if e.tool_uses == 1 { "" } else { "s" },
                e.tokens_used,
                crate::util::fmt_elapsed(e.elapsed_secs()),
            );
            if !e.active_skills.is_empty() {
                summary.push_str(&format!("\nUsing: {}", e.active_skills.join(", ")));
            }
            if !e.model_reason.is_empty() {
                summary.push_str(&format!("\nWhy model: {}", e.model_reason));
            }
            if !e.skill_reason.is_empty() {
                summary.push_str(&format!("\nWhy skill: {}", e.skill_reason));
            }
            if e.retry_count > 0 || e.failure_count > 0 {
                summary.push_str(&format!(
                    "\nRecovery: {} retries · {} failures",
                    e.retry_count, e.failure_count
                ));
            }
            if !e.delivery_status.is_empty() {
                summary.push_str(&format!("\nParent delivery: {}", e.delivery_status));
            }
            summary
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

    /// Agents that have NOT reached a terminal state — i.e. the ones the footer
    /// cue means when it says "N subagents". `entry_count` includes rows that
    /// already finished (they linger for `RETAIN_SECS`), so using it there
    /// reported e.g. "4 subagents" for one running worker and three that were
    /// already done.
    ///
    /// `Unknown` and `Stalled` count as in-flight on purpose: neither is a
    /// report that the agent ended, and dropping them would understate the fleet
    /// exactly as badly as `entry_count` overstates it.
    pub fn running_count(&self) -> usize {
        self.entries
            .iter()
            .filter(|e| !e.status.is_terminal())
            .count()
    }

    /// True if any agent has ever been tracked this session — gates opening the
    /// dashboard.
    pub fn has_entries(&self) -> bool {
        !self.entries.is_empty()
    }

    /// Stable id (entry name / agent_id) of the roster row at `idx`, used to
    /// target the backend cancel endpoint. Index is ROSTER space: 0 = `main`
    /// (synthetic, not a backend agent → `None`), 1..=entries maps to
    /// `entries[idx-1]`.
    pub fn agent_id_at(&self, idx: usize) -> Option<String> {
        let idx = idx.checked_sub(1)?;
        self.entries.get(idx).map(|e| e.name.clone())
    }

    /// True when the roster row at `idx` is still cancellable (running or
    /// spawning). Index is ROSTER space: row 0 is the synthetic `main` node,
    /// which is NEVER cancellable (`is_cancellable(0) == false`); 1..=entries
    /// maps to `entries[idx-1]`.
    pub fn is_cancellable(&self, idx: usize) -> bool {
        let Some(idx) = idx.checked_sub(1) else {
            return false;
        };
        self.entries
            .get(idx)
            .map(|e| matches!(e.status, AgentStatus::Running | AgentStatus::Spawning))
            .unwrap_or(false)
    }

    /// Whether the synthetic `main` root row has enough of its own to justify a
    /// full row, or should fold into the roster header directly above it.
    ///
    /// `main` had already been stripped down to defend the one-timer rule: no
    /// elapsed (that is the turn clock the activity line owns) and no fallback
    /// verb (that merely restated "Running N agents…"). What the capture showed
    /// was the end state of that stripping — a whole row reading `● main` and a
    /// token count, wedged between a header and a tree rule that both said more
    /// than it did.
    ///
    /// So it earns its row on exactly two conditions:
    ///   * it carries the GOAL (`activity`) — a fact no other live surface
    ///     states; or
    ///   * it is the current roster selection, and therefore the visible target
    ///     of the Enter-to-detach affordance. A selection you cannot see is a
    ///     worse bug than a crowded panel.
    ///
    /// Otherwise the only thing it held — session tokens — moves into the header,
    /// which is the "N=1 inlines, N>1 promotes to rows" rule Codex applies to
    /// delegation targets.
    ///
    /// MUST be consulted by both `height()` and `draw_tree`.
    pub(super) fn main_row_earns_a_row(&self) -> bool {
        match self.main_row {
            None => false,
            Some(ref m) => self.roster_selected == Some(0) || !m.activity.trim().is_empty(),
        }
    }

    /// The session-token meta the `main` row would have carried, for the header
    /// to absorb when [`Self::main_row_earns_a_row`] is false. `None` when the
    /// row is being drawn (the fact belongs to exactly one surface at a time).
    pub(super) fn folded_main_tokens(&self) -> Option<u32> {
        match self.main_row {
            Some(ref m) if !self.main_row_earns_a_row() => Some(m.tokens),
            _ => None,
        }
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
        // Inline roster is capped at INLINE_ROSTER_MAX_AGENTS rows; the overflow
        // collapses into a single "+K more agents" summary line (see draw_tree).
        let agent_lines: u16 = self
            .entries
            .iter()
            .take(INLINE_ROSTER_MAX_AGENTS)
            .map(Self::entry_rows)
            .sum();
        let more_line = u16::from(self.entries.len() > INLINE_ROSTER_MAX_AGENTS);
        let batch_header_lines = {
            let groups = self.grouped_entries();
            // MUST mirror `draw_tree`'s `has_batches` exactly: a rule only exists
            // once there are two groups to separate (see the note there).
            let has_batches = groups.len() > 1 && groups.iter().any(|g| g.batch_id.is_some());
            if has_batches {
                groups.len() as u16
            } else {
                0
            }
        };
        let synth_lines = if matches!(self.synthesis, SynthesisState::Synthesizing { .. }) {
            1u16
        } else {
            0
        };
        let swarm_lines = if self.swarm.is_some() { 1u16 } else { 0 };
        // Shared-scratchpad section: 1 header + one line per retained note.
        let scratchpad_lines = if self.scratchpad.is_empty() {
            0u16
        } else {
            1 + self.scratchpad.len() as u16
        };
        // Synthetic `main` root row (CC FleetView). Only drawn when it has
        // something to say — see `main_row_earns_a_row`.
        let main_line = u16::from(self.main_row_earns_a_row());
        // summary + 1 header + main + batch headers + agents + synth + swarm + scratchpad
        let total = summary_line
            + 1
            + main_line
            + batch_header_lines
            + agent_lines
            + more_line
            + synth_lines
            + swarm_lines
            + scratchpad_lines;
        total.min(30)
    }

    /// Rows the tree needs for one agent: 1 subject row + the action trail.
    ///
    /// Running agents show the de-duplicated recent actions ([`trail_actions`],
    /// at most [`TRAIL_MAX_ACTIONS`]), the whole child list capped at
    /// [`TRAIL_MAX_ROWS`]; terminal agents keep the compact 2-row layout.
    ///
    /// The "+N earlier" counter costs NO row: it is a prefix on the oldest
    /// visible trail row (see `draw_tree`). It only claims a row of its own in
    /// the degenerate case where there is no visible row to prefix — which is the
    /// same row the `Starting…` fallback would have taken, so the `.max(1)`
    /// covers both and the count is unchanged either way.
    ///
    /// MUST stay in lockstep with the trail built in `draw_tree` or the layout
    /// desyncs — both go through [`trail_actions`].
    pub(super) fn entry_rows(entry: &AgentEntry) -> u16 {
        match entry.status {
            AgentStatus::Running | AgentStatus::Spawning => {
                let shown = trail_actions(entry).len();
                1 + shown.max(1).min(TRAIL_MAX_ROWS) as u16
            }
            // Unknown / Stalled: 1 subject + exactly 1 state line. No trail (the
            // trail would imply live activity we do not have) and no summary
            // (nothing was produced — the agent has not ended).
            AgentStatus::Unknown | AgentStatus::Stalled => 2,
            // Terminal rows: 1 subject + 1 Done/Failed trail + an optional dim
            // `⎿ <summary>` line when the backend delivered a result preview.
            _ => 2 + u16::from(entry.result_summary.is_some()),
        }
    }

    /// Advance spinner animation frame + clear dead/stale ghosts so the panel
    /// never shows a "Running … 14m" row for an agent that actually died.
    pub fn tick(&mut self) {
        self.tick = self.tick.wrapping_add(1);
        self.prune_stale();
    }

    /// How long a still-"Running" agent may go silent before the panel admits it
    /// no longer knows the agent's state.
    const STALE_SECS: u64 = 90;
    /// How long a finished (Completed/Failed) row lingers before it's removed so
    /// the panel doesn't accumulate old rows.
    const RETAIN_SECS: u64 = 20;
    /// How long an `Unknown` row is kept before it is DROPPED (not failed). At
    /// some point a row whose state we cannot determine stops being information
    /// and becomes clutter — but removing it still says nothing false, whereas
    /// flipping it to Failed would.
    const UNKNOWN_REAP_SECS: u64 = 600;

    /// Reconcile the panel with reality: demote silent running agents to
    /// `Unknown`, and drop finished rows that have lingered past the retain
    /// window. Idempotent, cheap, safe to call every tick.
    ///
    /// This deliberately does NOT synthesize a failure. A background subagent
    /// emits `started` before it waits for a concurrency slot and emits nothing
    /// while queued, so silence is the NORMAL shape of a healthy queued agent —
    /// the old Running→Failed transition invented a failure for it. `Failed` may
    /// only come from a terminal backend event.
    pub fn prune_stale(&mut self) {
        // 1. Silent runners → Unknown (stops the forever-"Running" ghost without
        //    claiming a death nobody reported).
        for e in self.entries.iter_mut() {
            if e.is_stale(Self::STALE_SECS) {
                e.status = AgentStatus::Unknown;
            }
        }
        // 2. Old finished rows → removed; long-Unknown rows → removed as well
        //    (silent removal, never a fabricated terminal state).
        self.entries.retain(|e| match e.status {
            AgentStatus::Completed | AgentStatus::Failed => e
                .finished_at
                .map(|t| t.elapsed().as_secs() < Self::RETAIN_SECS)
                .unwrap_or(true),
            AgentStatus::Unknown => e.last_activity.elapsed().as_secs() < Self::UNKNOWN_REAP_SECS,
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
        self.scratchpad.clear();
    }

    /// Drop the transient shared-scratchpad notes (new top-level turn). Kept
    /// separate from a full `clear` so the caller can reset just this surface
    /// without tearing down live agent rows.
    pub fn clear_scratchpad(&mut self) {
        self.scratchpad.clear();
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
                    result_summary: None,
                    cost_usd: None,
                    phase: None,
                    active_skills: Vec::new(),
                    model_reason: String::new(),
                    skill_reason: String::new(),
                    retry_count: 0,
                    failure_count: 0,
                    delivery_status: String::new(),
                    available_controls: Vec::new(),
                });
            }
        }
        self.active = true;
    }

    /// A subagent started, or was re-announced.
    ///
    /// `elapsed_ms` is the run's age by the BACKEND's clock. It is the only
    /// thing allowed to set `started_at` on a row that already exists: an
    /// `agent_started` frame is not proof that work is beginning now — a
    /// reconnect, a replay or a late panel open delivers one for an agent that
    /// has been running for minutes — and restamping the local clock on it was
    /// what produced "17 seconds of work and 99 tool uses". With no age
    /// reported, an existing row KEEPS the anchor it already had.
    pub fn agent_started(
        &mut self,
        name: impl Into<String>,
        role: impl Into<String>,
        model: impl Into<String>,
        subject: impl Into<String>,
        batch_id: Option<String>,
        elapsed_ms: Option<u64>,
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
            entry.finished_at = None;
            // Backend age first, so a re-announcement lands on the real start.
            // Only a row with NO backend age and no work behind it falls back to
            // "now" — a genuine fresh start, where now IS the start.
            let had_work = entry.tool_uses > 0 || entry.phase.is_some();
            entry.anchor_elapsed(elapsed_ms);
            if elapsed_ms.is_none() && !had_work {
                entry.started_at = std::time::Instant::now();
            }
            entry.last_activity = std::time::Instant::now();
            entry.result_summary = None;
            if batch_id.is_some() {
                entry.batch_id = batch_id;
            }
        } else {
            let mut entry = AgentEntry {
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
                result_summary: None,
                cost_usd: None,
                phase: None,
                active_skills: Vec::new(),
                model_reason: String::new(),
                skill_reason: String::new(),
                retry_count: 0,
                failure_count: 0,
                delivery_status: String::new(),
                available_controls: Vec::new(),
            };
            // A row created from a frame about an agent that has been running
            // for a while starts with the age the backend reports, not zero.
            entry.anchor_elapsed(elapsed_ms);
            self.entries.push(entry);
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
        elapsed_ms: Option<u64>,
    ) {
        let subject = subject.into();
        if let Some(entry) = self.entries.iter_mut().find(|e| e.name == name) {
            // Every progress frame re-states the run's true age, so a row the
            // panel adopted mid-flight converges on the backend's clock rather
            // than counting from whenever this process first saw it.
            entry.anchor_elapsed(elapsed_ms);
            entry.last_activity = std::time::Instant::now();
            // A signal from a row we had given up on (Unknown) or that the
            // backend flagged as stalled means it is demonstrably alive again.
            if matches!(entry.status, AgentStatus::Unknown | AgentStatus::Stalled) {
                entry.status = AgentStatus::Running;
            }
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

    /// Update durable control-plane facts without disturbing lifecycle state.
    pub fn agent_runtime(
        &mut self,
        name: &str,
        active_skills: Vec<String>,
        model_reason: String,
        skill_reason: String,
        retry_count: u32,
        failure_count: u32,
        delivery_status: String,
        available_controls: Vec<String>,
    ) {
        if let Some(entry) = self.entries.iter_mut().find(|entry| entry.name == name) {
            entry.active_skills = active_skills;
            if !model_reason.is_empty() {
                entry.model_reason = model_reason;
            }
            if !skill_reason.is_empty() {
                entry.skill_reason = skill_reason;
            }
            entry.retry_count = retry_count;
            entry.failure_count = failure_count;
            if !delivery_status.is_empty() {
                entry.delivery_status = delivery_status;
            }
            entry.available_controls = available_controls;
        }
    }

    pub fn control_allowed(&self, name: &str, action: &str) -> bool {
        self.entries
            .iter()
            .find(|entry| entry.name == name)
            .is_some_and(|entry| {
                entry.available_controls.is_empty()
                    || entry
                        .available_controls
                        .iter()
                        .any(|control| control == action)
            })
    }

    pub fn set_available_controls(&mut self, name: &str, controls: Vec<String>) {
        if let Some(entry) = self.entries.iter_mut().find(|entry| entry.name == name) {
            entry.available_controls = controls;
        }
    }

    /// Terminal "completed" transition.
    ///
    /// `tool_uses` / `tokens` are OPTIONAL and non-destructive: `None` means the
    /// wire carried no usage for this agent, in which case the counters that
    /// were accumulated from its progress events are LEFT ALONE. Passing a
    /// hardcoded `0` here used to wipe every real number the panel had
    /// collected, so a worker that ran 12 tools and 40k tokens finished reading
    /// `0 tools · 0 tokens`. Same rule the fleet path already follows
    /// (`fleet_node_completed`).
    pub fn agent_completed(
        &mut self,
        name: &str,
        tool_uses: Option<u32>,
        tokens: Option<u32>,
        summary: Option<String>,
    ) {
        if let Some(entry) = self.entries.iter_mut().find(|e| e.name == name) {
            entry.status = AgentStatus::Completed;
            entry.current_action = "complete".into();
            if let Some(t) = tool_uses {
                entry.tool_uses = t;
            }
            if let Some(t) = tokens {
                entry.tokens_used = t;
            }
            entry.finished_at = Some(std::time::Instant::now());
            entry.result_summary = summary.filter(|s| !s.trim().is_empty());
        }
    }

    /// Terminal "failed" transition. `tool_uses` / `tokens` are non-destructive
    /// for the same reason as [`Agents::agent_completed`] — a crash is exactly
    /// when the accumulated counters matter most.
    pub fn agent_failed(
        &mut self,
        name: &str,
        error: impl Into<String>,
        tool_uses: Option<u32>,
        tokens: Option<u32>,
        summary: Option<String>,
    ) {
        if let Some(entry) = self.entries.iter_mut().find(|e| e.name == name) {
            entry.status = AgentStatus::Failed;
            entry.current_action = error.into();
            if let Some(t) = tool_uses {
                entry.tool_uses = t;
            }
            if let Some(t) = tokens {
                entry.tokens_used = t;
            }
            entry.finished_at = Some(std::time::Instant::now());
            entry.result_summary = summary.filter(|s| !s.trim().is_empty());
        }
    }

    /// The BACKEND reported what this agent is doing (`background_agent_phase`).
    ///
    /// A phase is a signal like any other, so it revives an `Unknown` row and
    /// refreshes `last_activity` — an agent that just told us it is waiting on
    /// the model is demonstrably being tracked, and the panel has no business
    /// calling that unknown. It does NOT clear `Stalled`: a stall is a positive
    /// backend measurement of no-progress and only progress or a terminal event
    /// may overturn it.
    ///
    /// Creates the row if it does not exist yet: for a background agent the
    /// first phase can arrive before `orchestrator_agent_started`, because the
    /// queue wait happens before the run is even set up.
    pub fn agent_phase(
        &mut self,
        name: &str,
        display_name: &str,
        phase: &str,
        detail: &str,
        elapsed_ms: Option<u64>,
    ) {
        let now = std::time::Instant::now();
        let parsed = AgentPhase {
            name: phase.to_string(),
            detail: detail.to_string(),
            since: now,
        };

        if let Some(entry) = self.entries.iter_mut().find(|e| e.name == name) {
            if entry.status.is_terminal() {
                return;
            }
            // Only restamp `since` when the phase actually CHANGED, so "queued
            // for 4m" keeps counting from when queueing began rather than
            // resetting on every repeat of the same phase.
            let changed = entry
                .phase
                .as_ref()
                .map(|p| p.name != parsed.name || p.detail != parsed.detail)
                .unwrap_or(true);
            if changed {
                entry.phase = Some(parsed);
            }
            entry.anchor_elapsed(elapsed_ms);
            entry.last_activity = now;
            if entry.status == AgentStatus::Unknown {
                entry.status = AgentStatus::Running;
            }
        } else {
            let mut entry = AgentEntry {
                name: name.to_string(),
                role: String::new(),
                model: String::new(),
                subject: display_name.to_string(),
                status: AgentStatus::Spawning,
                current_action: String::new(),
                recent_actions: Vec::new(),
                tool_uses: 0,
                tokens_used: 0,
                batch_id: Some("background".to_string()),
                started_at: now,
                finished_at: None,
                last_activity: now,
                result_summary: None,
                cost_usd: None,
                phase: Some(parsed),
                active_skills: Vec::new(),
                model_reason: String::new(),
                skill_reason: String::new(),
                retry_count: 0,
                failure_count: 0,
                delivery_status: String::new(),
                available_controls: Vec::new(),
            };
            entry.anchor_elapsed(elapsed_ms);
            self.entries.push(entry);
            self.active = true;
        }
    }

    /// The BACKEND reported no progress for this agent (`background_agent_stalled`).
    /// Non-terminal: the row keeps its counters and its live clock, and any
    /// later progress event revives it. `stalled_ms` comes from the backend's
    /// own measurement — the panel never guesses it.
    pub fn agent_stalled(&mut self, name: &str, stalled_ms: u64) {
        if let Some(entry) = self.entries.iter_mut().find(|e| e.name == name) {
            if entry.status.is_terminal() {
                return;
            }
            entry.status = AgentStatus::Stalled;
            entry.current_action = format!("no progress for {}m", (stalled_ms / 60_000).max(1));
        }
    }

    /// Terminal transition for a fleet node from a `fleet_node_completed` frame.
    /// Record what an agent cost, from the backend's durable spend record.
    ///
    /// `None` is a NO-OP, not a write: the same non-destructive rule as
    /// [`Agents::agent_completed`]'s counters. A frame that carries no cost
    /// (legacy backend, or a run with no recorded spend) must leave whatever we
    /// already knew alone rather than overwrite it with a fabricated zero.
    /// `None` renders as `—` — see [`AgentEntry::cost_usd`].
    pub fn set_agent_cost(&mut self, name: &str, cost_usd: Option<f64>) {
        let Some(cost) = cost_usd else { return };
        if let Some(entry) = self.entries.iter_mut().find(|e| e.name == name) {
            entry.cost_usd = Some(cost);
        }
    }

    /// The frame carries NO tool/token counts (they were set by the preceding
    /// progress events), so this flips status + records the summary WITHOUT
    /// overwriting the accumulated counters. `status` is
    /// "completed" | "failed" | "cancelled".
    pub fn fleet_node_completed(&mut self, name: &str, status: &str, summary: Option<String>) {
        if let Some(entry) = self.entries.iter_mut().find(|e| e.name == name) {
            let failed = matches!(status, "failed" | "cancelled");
            entry.status = if failed {
                AgentStatus::Failed
            } else {
                AgentStatus::Completed
            };
            entry.current_action = status.to_string();
            entry.finished_at = Some(std::time::Instant::now());
            entry.result_summary = summary.filter(|s| !s.trim().is_empty());
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

    pub fn swarm_started(&mut self, id: impl Into<String>, pattern: impl Into<String>, count: u32) {
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
        self.scratchpad.clear();
        self.main_row = None;
        self.roster_selected = None;
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

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::{backend::TestBackend, Terminal};

    /// Flatten the panel render to a single string so we can assert on visible
    /// text (mirrors the status-bar / event-loop buffer harness).
    fn render_text(agents: &Agents, w: u16, h: u16) -> String {
        let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
        term.draw(|f| agents.draw(f, f.area())).unwrap();
        term.backend()
            .buffer()
            .content()
            .iter()
            .map(|c| c.symbol())
            .collect()
    }

    #[test]
    fn scratchpad_activity_is_capped_newest_first() {
        let mut a = Agents::new();
        for i in 0..(SCRATCHPAD_CAP + 3) {
            a.scratchpad_activity("agent:s1:1", format!("f{}.md", i), "write", 100 + i as u64);
        }
        // Never grows past the cap.
        assert_eq!(a.scratchpad_len(), SCRATCHPAD_CAP);
        // Newest write is at the front.
        assert_eq!(a.scratchpad[0].entry, format!("f{}.md", SCRATCHPAD_CAP + 2));
    }

    #[test]
    fn clear_scratchpad_drops_notes_but_keeps_agents() {
        let mut a = Agents::new();
        a.agent_started("worker-1", "researcher", "", "scan modules", None, None);
        a.scratchpad_activity("agent:s1:1", "findings.md", "write", 2100);
        assert_eq!(a.scratchpad_len(), 1);

        a.clear_scratchpad();
        assert_eq!(a.scratchpad_len(), 0);
        // The live worker row survives a scratchpad-only reset.
        assert!(a.is_active());
        assert_eq!(a.entry_count(), 1);
    }

    #[test]
    fn task_started_clears_prior_scratchpad() {
        let mut a = Agents::new();
        a.scratchpad_activity("agent:s1:1", "old.md", "write", 10);
        a.task_started("task-2");
        assert_eq!(a.scratchpad_len(), 0);
    }

    #[test]
    fn panel_renders_worker_status_and_scratchpad_line() {
        let mut a = Agents::new();
        a.agent_started("worker-1", "researcher", "", "scan modules", None, None);
        a.scratchpad_activity("agent:s1:2", "findings.md", "write", 2100);

        let text = render_text(&a, 80, 12);
        // Worker subject is visible (the running row).
        assert!(
            text.contains("scan modules"),
            "missing worker row: {:?}",
            text
        );
        // The shared-scratchpad section header + the compact write line.
        assert!(
            text.contains("scratchpad"),
            "missing scratchpad section: {:?}",
            text
        );
        assert!(
            text.contains("findings.md"),
            "missing entry name: {:?}",
            text
        );
        // Compact byte size (2100 → 2.1k), not raw bytes.
        assert!(text.contains("2.1k"), "missing compact size: {:?}", text);
        // Past-tense verb, not the raw action token.
        assert!(text.contains("wrote"), "missing verb: {:?}", text);
    }

    #[test]
    fn append_renders_appended_verb() {
        let mut a = Agents::new();
        a.agent_started("worker-1", "", "", "work", None, None);
        a.scratchpad_activity("lead", "notes.md", "append", 300);
        let text = render_text(&a, 80, 10);
        assert!(text.contains("appended"), "expected 'appended': {:?}", text);
    }

    #[test]
    fn scratchpad_section_absent_when_empty() {
        let mut a = Agents::new();
        a.agent_started("worker-1", "", "", "work", None, None);
        let text = render_text(&a, 80, 8);
        assert!(
            !text.contains("scratchpad"),
            "unexpected scratchpad section: {:?}",
            text
        );
    }

    #[test]
    fn completed_summary_populates_entry_and_renders_dim_line() {
        let mut a = Agents::new();
        a.agent_started("worker-1", "researcher", "", "scan modules", None, None);
        a.agent_completed(
            "worker-1",
            Some(3),
            Some(1200),
            Some("Found 4 dead code paths".to_string()),
        );

        // Entry carries the summary + the terminal row reserves one extra line.
        let entry = a.entries.iter().find(|e| e.name == "worker-1").unwrap();
        assert_eq!(
            entry.result_summary.as_deref(),
            Some("Found 4 dead code paths")
        );
        assert_eq!(Agents::entry_rows(entry), 3);

        let text = render_text(&a, 80, 12);
        // The dim `⎿ <summary>` line is visible under the finished row.
        assert!(
            text.contains("Found 4 dead code paths"),
            "missing summary line: {:?}",
            text
        );
        assert!(text.contains('\u{23bf}'), "missing ⎿ glyph: {:?}", text);
    }

    #[test]
    fn completed_without_summary_renders_no_extra_line() {
        let mut a = Agents::new();
        a.agent_started("worker-1", "researcher", "", "scan modules", None, None);
        a.agent_completed("worker-1", Some(1), Some(100), None);

        let entry = a.entries.iter().find(|e| e.name == "worker-1").unwrap();
        assert_eq!(entry.result_summary, None);
        // No summary → compact 2-row terminal layout, no ⎿ line.
        assert_eq!(Agents::entry_rows(entry), 2);
        let text = render_text(&a, 80, 12);
        assert!(!text.contains('\u{23bf}'), "unexpected ⎿ line: {:?}", text);
    }

    #[test]
    fn blank_summary_is_treated_as_none() {
        let mut a = Agents::new();
        a.agent_started("worker-1", "", "", "work", None, None);
        a.agent_completed("worker-1", Some(0), Some(0), Some("   \n  ".to_string()));
        let entry = a.entries.iter().find(|e| e.name == "worker-1").unwrap();
        assert_eq!(
            entry.result_summary, None,
            "whitespace-only summary must be dropped"
        );
    }

    #[test]
    fn failed_summary_renders_in_error_style() {
        let mut a = Agents::new();
        a.agent_started("worker-1", "", "", "work", None, None);
        a.agent_failed(
            "worker-1",
            "timeout",
            Some(2),
            Some(500),
            Some("join timeout after 300ms".to_string()),
        );

        let entry = a.entries.iter().find(|e| e.name == "worker-1").unwrap();
        assert_eq!(entry.status, AgentStatus::Failed);
        assert_eq!(
            entry.result_summary.as_deref(),
            Some("join timeout after 300ms")
        );
        let text = render_text(&a, 80, 12);
        assert!(
            text.contains("join timeout after 300ms"),
            "missing failed summary: {:?}",
            text
        );
    }

    #[test]
    fn summary_line_is_width_truncated() {
        let mut a = Agents::new();
        a.agent_started("w", "", "", "s", None, None);
        let long = "abcdefghijklmnopqrstuvwxyz0123456789 ".repeat(6);
        a.agent_completed("w", Some(1), Some(1), Some(long));
        // Narrow panel: the summary line must fit (ellipsis), no panic, no wrap.
        let text = render_text(&a, 40, 10);
        assert!(
            text.contains('\u{2026}'),
            "expected ellipsis truncation: {:?}",
            text
        );
    }

    // ── FleetView roster: inline `← for agents` navigation invariants ─────────
    // These lock the ROSTER index space (0 = synthetic `main`, 1..=entries) that
    // `handle_fleet_select_key` / `view_selected_dashboard_item` /
    // `stop_selected_dashboard_item` rely on. See app/update.rs + handle_dialogs.rs.

    #[test]
    fn roster_count_is_one_plus_entries() {
        // Bounds the FleetSelect cursor (B): `main` alone is 1 row; each worker
        // adds one. Empty roster is never zero — `main` always exists.
        let mut a = Agents::new();
        assert_eq!(a.roster_count(), 1, "main-only roster is 1 row");
        a.agent_started("w1", "researcher", "", "scan", None, None);
        a.agent_started("w2", "coder", "", "build", None, None);
        assert_eq!(a.roster_count(), 3, "main + 2 workers");
    }

    #[test]
    fn is_active_true_once_a_worker_exists() {
        // Gate for entering FleetSelect via `←` (A): the Left arm + enter_fleet_select
        // both guard on is_active(), which flips true the moment an agent is tracked.
        let mut a = Agents::new();
        assert!(!a.is_active(), "fresh panel is inactive");
        a.agent_started("w1", "researcher", "", "scan", None, None);
        assert!(a.is_active(), "tracking a worker activates the panel");
    }

    #[test]
    fn main_row_index_zero_is_never_cancellable() {
        // `x`/`c` on `main` must be a NO-OP (E): is_cancellable(0) is always false,
        // even with live workers present.
        let mut a = Agents::new();
        assert!(!a.is_cancellable(0), "empty: main not cancellable");
        a.agent_started("w1", "researcher", "", "scan", None, None);
        assert!(
            !a.is_cancellable(0),
            "with workers: main STILL not cancellable"
        );
    }

    #[test]
    fn worker_cancellable_while_running_not_after_terminal() {
        // `x` on a running worker stops it; a completed/failed worker is inert (E).
        let mut a = Agents::new();
        a.agent_started("w1", "researcher", "", "scan", None, None);
        assert!(
            a.is_cancellable(1),
            "running worker at roster idx 1 is cancellable"
        );
        a.agent_completed("w1", Some(1), Some(10), None);
        assert!(!a.is_cancellable(1), "completed worker is not cancellable");

        a.agent_started("w2", "coder", "", "build", None, None);
        a.agent_failed("w2", "boom", Some(0), Some(0), None);
        assert!(!a.is_cancellable(2), "failed worker is not cancellable");
    }

    #[test]
    fn agent_id_and_summary_are_roster_indexed_main_is_none() {
        // Enter/x routing depends on this offset (C/D/I): roster idx 0 = `main`
        // (no backend id, no worker transcript → None); idx 1 maps to entries[0].
        let mut a = Agents::new();
        a.agent_started("worker-alpha", "researcher", "", "scan modules", None, None);
        a.agent_started("worker-beta", "coder", "", "write code", None, None);

        assert_eq!(a.agent_id_at(0), None, "main has no backend agent id");
        assert_eq!(
            a.agent_id_at(1).as_deref(),
            Some("worker-alpha"),
            "idx 1 → entries[0]"
        );
        assert_eq!(
            a.agent_id_at(2).as_deref(),
            Some("worker-beta"),
            "idx 2 → entries[1]"
        );
        assert_eq!(a.agent_id_at(3), None, "past the end → None");

        assert_eq!(a.entry_summary_at(0), None, "main has no worker summary");
        let s1 = a.entry_summary_at(1).expect("worker-alpha summary");
        assert!(
            s1.contains("scan modules"),
            "summary names the worker subject: {s1:?}"
        );
        assert!(a.entry_summary_at(3).is_none(), "past the end → None");
    }

    #[test]
    fn is_cancellable_saturates_below_zero_and_above_end() {
        // Defensive: no panic / no wraparound at the roster edges.
        let mut a = Agents::new();
        a.agent_started("w1", "", "", "s", None, None);
        assert!(!a.is_cancellable(0));
        assert!(a.is_cancellable(1));
        assert!(!a.is_cancellable(99), "way out of range → false, no panic");
    }

    #[test]
    fn summary_clears_when_agent_restarts_and_on_new_turn() {
        let mut a = Agents::new();
        a.agent_started("worker-1", "", "", "work", None, None);
        a.agent_completed("worker-1", Some(1), Some(1), Some("done stuff".to_string()));
        assert!(a.entries[0].result_summary.is_some());

        // Re-running the same agent (resume/new wave) clears the stale summary.
        a.agent_started("worker-1", "", "", "work", None, None);
        assert_eq!(a.entries[0].result_summary, None);

        a.agent_completed("worker-1", Some(1), Some(1), Some("done again".to_string()));
        // A new top-level turn wipes the whole panel (rows + their summaries).
        a.task_started("task-2");
        assert_eq!(a.entry_count(), 0);
    }

    // ── Wave 2: display edge-case hardening ───────────────────────────────────

    #[test]
    fn inline_roster_caps_agents_and_shows_more_summary() {
        // (1) A 20-node fleet must NOT blow past the inline panel: only the first
        // INLINE_ROSTER_MAX_AGENTS rows render, the rest collapse into a dim
        // "+K more agents" line. The full-screen dashboard still lists them all.
        let mut a = Agents::new();
        for i in 0..20 {
            a.agent_started(format!("w{i}"), "", "", format!("subj{i}"), None, None);
        }
        let text = render_text(&a, 80, 40);
        // First cap agents (0..=7) are visible.
        assert!(text.contains("subj0"), "first agent visible: {text:?}");
        assert!(text.contains("subj7"), "8th (cap) agent visible: {text:?}");
        // Agents beyond the cap are collapsed away, not drawn inline.
        assert!(
            !text.contains("subj9"),
            "past-cap agent hidden inline: {text:?}"
        );
        assert!(
            !text.contains("subj19"),
            "last agent hidden inline: {text:?}"
        );
        // The dim overflow summary counts the remainder (20 - 8 = 12).
        assert!(text.contains("12 more agent"), "overflow summary: {text:?}");
        // height() reserves for the capped rows + the summary line, not all 20.
        assert!(
            a.height() <= 30,
            "inline panel height stays bounded: {}",
            a.height()
        );
    }

    #[test]
    fn inline_roster_no_more_line_when_under_cap() {
        // Below the cap there is no overflow line at all.
        let mut a = Agents::new();
        for i in 0..3 {
            a.agent_started(format!("w{i}"), "", "", format!("subj{i}"), None, None);
        }
        let text = render_text(&a, 80, 20);
        assert!(
            !text.contains("more agent"),
            "no overflow line under cap: {text:?}"
        );
    }

    #[test]
    fn long_activity_truncates_with_ellipsis() {
        // (1) Long node activity/name still truncates with `…`, never wraps/overflows.
        let mut a = Agents::new();
        a.agent_started("w", "", "", "x".repeat(300), None, None);
        let text = render_text(&a, 40, 8);
        assert!(text.contains('\u{2026}'), "activity truncated: {text:?}");
    }

    #[test]
    fn header_fleet_gauge_clamps_and_keeps_large_fleet_hint() {
        // (2) running > cap (a backend race) must render `cap/cap`, never `30/16`;
        // the ">=25 large fleet" dim warning is preserved.
        let mut a = Agents::new();
        a.agent_started("w1", "", "", "s", None, None);
        a.set_fleet_summary(30, 0, 16, 30, true);
        let text = render_text(&a, 100, 12);
        assert!(text.contains("16/16 agents"), "clamped gauge: {text:?}");
        assert!(
            !text.contains("30/16"),
            "impossible ratio never shown: {text:?}"
        );
        assert!(text.contains("large fleet"), "warn hint retained: {text:?}");
    }

    #[test]
    fn header_fleet_gauge_zero_cap_no_slash_zero() {
        // (2) cap == 0 must not render an odd `N/0`; show a plain count instead.
        let mut a = Agents::new();
        a.agent_started("w1", "", "", "s", None, None);
        a.set_fleet_summary(4, 0, 0, 4, false);
        let text = render_text(&a, 100, 12);
        assert!(
            text.contains("4 agents"),
            "plain count when cap=0: {text:?}"
        );
        assert!(!text.contains("4/0"), "never renders N/0: {text:?}");
    }

    #[test]
    fn fleet_select_enter_gate_matches_subagent_hint() {
        // (3) The App gates `←`-enter into FleetSelect on is_active() &&
        // has_entries() — exactly the condition that makes the status-bar
        // `← for agents` hint appear (subagent_count = entry_count while active).
        // So you can never enter the roster into a state that showed no hint.
        let mut a = Agents::new();
        // A scratchpad write activates the panel WITHOUT adding any worker rows:
        // active but no entries → hint absent → enter must be blocked.
        a.scratchpad_activity("lead", "notes.md", "write", 10);
        assert!(a.is_active(), "scratchpad activity activates the panel");
        assert!(!a.has_entries(), "…but there are no worker rows to browse");
        // Once a real worker exists, both the hint and the enter-gate fire.
        a.agent_started("w1", "researcher", "", "scan", None, None);
        assert!(
            a.is_active() && a.has_entries(),
            "worker present → gate + hint agree"
        );
    }

    #[test]
    fn main_only_roster_clamps_nav_to_index_zero() {
        // (3) With no real nodes the inline roster is `main` alone: roster_count
        // is 1, so the FleetSelect cursor can only ever sit at index 0 (all nav is
        // clamped by `roster_count`), and main is never cancellable.
        let a = Agents::new();
        assert_eq!(a.roster_count(), 1, "main-only roster is a single row");
        assert!(!a.is_cancellable(0), "main is never cancellable");
    }

    #[test]
    fn prune_stale_reaps_finished_rows_and_flips_silent_runners() {
        // (4) Finished rows older than the retain window are dropped; a running
        // row silent past the stale window stops claiming to be running.
        use std::time::{Duration, Instant};
        let mut a = Agents::new();
        a.agent_started("done-1", "", "", "s", None, None);
        a.agent_completed("done-1", Some(1), Some(10), None);
        a.agent_started("live-1", "", "", "s", None, None); // fresh running row stays

        let old = Instant::now() - Duration::from_secs(Agents::RETAIN_SECS + 40);
        for e in a.entries.iter_mut() {
            if e.name == "done-1" {
                e.finished_at = Some(old);
            }
        }
        a.prune_stale();
        assert!(
            a.entries.iter().all(|e| e.name != "done-1"),
            "stale finished row reaped"
        );
        assert!(
            a.entries.iter().any(|e| e.name == "live-1"),
            "fresh running row kept"
        );

        // Silence the live runner past the stale threshold → Unknown, NOT Failed.
        // The panel may only report a failure the backend actually reported.
        if let Some(e) = a.entries.iter_mut().find(|e| e.name == "live-1") {
            e.last_activity = Instant::now() - Duration::from_secs(Agents::STALE_SECS + 40);
        }
        a.prune_stale();
        let live = a.entries.iter().find(|e| e.name == "live-1").unwrap();
        assert_eq!(
            live.status,
            AgentStatus::Unknown,
            "silent runner is unknown, not failed"
        );
        assert!(
            live.finished_at.is_none(),
            "a silent agent has not finished"
        );
    }

    #[test]
    fn prune_stale_does_not_accumulate_dead_rows_under_churn() {
        // (4) Rapid churn: many completed rows all past the retain window are all
        // reaped in one pass — the roster never accumulates dead rows — and the
        // panel goes idle once nothing remains.
        use std::time::{Duration, Instant};
        let mut a = Agents::new();
        for i in 0..50 {
            let name = format!("w{i}");
            a.agent_started(name.clone(), "", "", "s", None, None);
            a.agent_completed(&name, Some(1), Some(1), None);
        }
        let old = Instant::now() - Duration::from_secs(Agents::RETAIN_SECS + 40);
        for e in a.entries.iter_mut() {
            e.finished_at = Some(old);
        }
        a.prune_stale();
        assert_eq!(a.entry_count(), 0, "all lingering finished rows reaped");
        assert!(!a.is_active(), "panel goes idle when nothing remains");
    }

    // ── FleetView roster: visual layout / column-alignment snapshots ───────────
    // These render the panel to a TestBackend and assert on the actual per-row
    // pixels, locking the CC-parity roster columns (glyph · type · activity ·
    // elapsed · ↓tokens) and the box-drawing width accounting.

    /// Render the panel and return one String per terminal row (each exactly `w`
    /// columns, so column positions are directly assertable). Every glyph the
    /// roster uses is width-1, so cell index == column.
    fn render_lines(agents: &Agents, w: u16, h: u16) -> Vec<String> {
        let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
        term.draw(|f| agents.draw(f, f.area())).unwrap();
        let content: Vec<String> = term
            .backend()
            .buffer()
            .content()
            .iter()
            .map(|c| c.symbol().to_string())
            .collect();
        (0..h as usize)
            .map(|y| content[y * w as usize..(y + 1) * w as usize].concat())
            .collect()
    }

    #[test]
    fn roster_renders_main_root_and_worker_meta_columns() {
        // The synthetic `main` root row + a live worker, with the CC meta column
        // (`<elapsed> · ↓<tokens>`) on each. Locks: the green `● main` root, the
        // `◯` worker glyph, and the right-hand token/elapsed column.
        let mut a = Agents::new();
        a.set_main_row("orchestrating the fleet", 625, 107_300);
        a.agent_started("worker-1", "researcher", "", "scanning modules", None, None);
        a.agent_progress(
            "worker-1",
            "reading entry.rs",
            4,
            4213,
            "scanning modules",
            vec![],
            None,
        );

        let lines = render_lines(&a, 70, 12);
        let joined = lines.join("\n");

        // The `main` root row: `● main` + its activity + compact meta.
        let main_line = lines.iter().find(|l| l.contains("main")).expect("main row");
        assert!(
            main_line.contains('\u{25cf}'),
            "main uses ● glyph: {main_line:?}"
        );
        assert!(
            main_line.contains("orchestrating the fleet"),
            "main activity: {main_line:?}"
        );
        // 107_300 → "107.3k", arrow ↓.
        assert!(
            main_line.contains("\u{2193}107.3k"),
            "main ↓tokens column: {main_line:?}"
        );
        // ONE turn clock: `main.elapsed_secs` IS the turn elapsed the activity
        // status line already renders next to the interrupt hint, so the inline
        // roster root must NOT render it a second time (625s → "10m 25s").
        assert!(
            !main_line.contains("10m 25s"),
            "main row must not restate the turn clock: {main_line:?}"
        );

        // The worker row: `◯` unselected glyph, role as the type, activity, meta.
        let worker_line = lines
            .iter()
            .find(|l| l.contains("researcher"))
            .expect("worker row");
        assert!(
            worker_line.contains('\u{25cb}'),
            "unselected worker uses ◯: {worker_line:?}"
        );
        assert!(
            worker_line.contains("reading entry.rs"),
            "worker activity: {worker_line:?}"
        );
        assert!(
            worker_line.contains("\u{2193}4.2k"),
            "worker ↓tokens: {worker_line:?}"
        );
        // Tree connector present.
        assert!(
            worker_line.contains('\u{2514}') || worker_line.contains('\u{251c}'),
            "worker row has a tree connector: {worker_line:?}"
        );

        // No row overflows the width (TestBackend is exactly 70 wide).
        assert!(
            lines.iter().all(|l| l.chars().count() == 70),
            "all rows padded to width"
        );
        // Nothing wrapped the activity onto a stray line (sanity on total content).
        assert!(joined.contains("researcher"), "role rendered: {joined:?}");
    }

    #[test]
    fn selected_worker_uses_filled_glyph() {
        // In FleetSelect focus the selected roster row swaps `◯` → `●`.
        let mut a = Agents::new();
        a.set_main_row("working", 5, 100);
        a.agent_started("w1", "coder", "", "building", None, None);
        // Roster index 1 == entries[0] selected.
        a.set_roster_selected(Some(1));
        let lines = render_lines(&a, 60, 10);
        let worker = lines
            .iter()
            .find(|l| l.contains("coder"))
            .expect("worker row");
        assert!(
            worker.contains('\u{25cf}'),
            "selected worker uses ● glyph: {worker:?}"
        );
    }

    #[test]
    fn batch_separator_fills_to_right_edge() {
        // Regression: the batch header `─── Batch N: id ` pads with `─` to the
        // pane's right edge. The label's leading box glyphs are 3-byte chars, so
        // the pad must be computed by CHAR width — a byte-len pad shorted the rule
        // and left a ragged gap before the edge.
        let mut a = Agents::new();
        a.agent_started(
            "w1",
            "researcher",
            "",
            "s1",
            Some("alpha".to_string()),
            None,
        );
        a.agent_started("w2", "coder", "", "s2", Some("beta".to_string()), None);

        let w = 72u16;
        let lines = render_lines(&a, w, 14);
        let sep = lines
            .iter()
            .find(|l| l.contains("Batch 1"))
            .expect("batch 1 header");
        // The separator reaches the last column (`─` fill, not blank).
        let last = sep.chars().nth((w - 1) as usize).unwrap();
        assert_eq!(
            last, '\u{2500}',
            "separator fills to the right edge: {sep:?}"
        );
    }

    #[test]
    fn done_row_shows_frozen_elapsed() {
        // A completed worker renders `Done · <elapsed>` (frozen), not a live timer.
        let mut a = Agents::new();
        a.agent_started("w1", "researcher", "", "scan", None, None);
        a.agent_completed("w1", Some(3), Some(1200), Some("found 4 paths".to_string()));
        let lines = render_lines(&a, 70, 10);
        let joined = lines.join("\n");
        assert!(
            joined.contains("Done \u{00b7}"),
            "Done · elapsed line: {joined:?}"
        );
        assert!(
            joined.contains("found 4 paths"),
            "result summary line: {joined:?}"
        );
    }

    #[test]
    fn narrow_pane_truncates_without_overflow() {
        // Very narrow pane with long activity: every row is exactly the pane width
        // (ratatui clips), and the ellipsis marks the truncation.
        let mut a = Agents::new();
        a.set_main_row("x".repeat(200), 30, 500);
        a.agent_started("w1", "researcher", "", "y".repeat(200), None, None);
        a.agent_progress("w1", "z".repeat(200), 2, 100, "", vec![], None);
        let w = 32u16;
        let lines = render_lines(&a, w, 10);
        assert!(
            lines.iter().all(|l| l.chars().count() == w as usize),
            "no row exceeds width"
        );
        assert!(
            lines.join("\n").contains('\u{2026}'),
            "long content truncated with …"
        );
    }

    // ── FleetView roster: right-aligned meta column ────────────────────────────
    // The `<elapsed> · ↓<tokens>` meta is flush-right to the pane edge so it forms
    // a clean vertical column (CC parity), instead of left-flowing after each
    // agent's activity. These render to a TestBackend and assert on the *cell
    // grid* (not the char-collapsed string) so wide (CJK) glyphs are handled: a
    // wide cell keeps its column and the trailing cell is empty, so a cell's index
    // is its true display column.

    /// Render the panel to a `w × h` grid of per-cell symbols (row-major). Cell
    /// index within a row == its display column, even across wide glyphs.
    fn render_cells(agents: &Agents, w: u16, h: u16) -> Vec<Vec<String>> {
        let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
        term.draw(|f| agents.draw(f, f.area())).unwrap();
        let flat: Vec<String> = term
            .backend()
            .buffer()
            .content()
            .iter()
            .map(|c| c.symbol().to_string())
            .collect();
        (0..h as usize)
            .map(|y| flat[y * w as usize..(y + 1) * w as usize].to_vec())
            .collect()
    }

    /// The display column of the first `↓` cell in a row, if any.
    fn arrow_col(row: &[String]) -> Option<usize> {
        row.iter().position(|s| s == "\u{2193}")
    }

    #[test]
    fn roster_meta_column_is_right_aligned_across_rows() {
        // main + two workers, all with equal-width metas (`0s · ↓X.Xk`). Because
        // the meta is flush-right, the `↓` — and the meta's start column — land in
        // the SAME column on every row: a clean vertical table column.
        for w in [60u16, 80u16] {
            let mut a = Agents::new();
            a.set_main_row("orchestrating the fleet", 0, 5_000); // ↓5.0k
            a.agent_started("w1", "researcher", "", "scanning modules", None, None);
            a.agent_progress(
                "w1",
                "reading entry.rs",
                4,
                4_200,
                "scanning modules",
                vec![],
                None,
            ); // ↓4.2k
            a.agent_started("w2", "coder", "", "building the crate", None, None);
            a.agent_progress(
                "w2",
                "compiling render.rs",
                7,
                5_100,
                "building",
                vec![],
                None,
            ); // ↓5.1k

            let cells = render_cells(&a, w, 12);

            // Collect the roster rows (main + the two workers).
            let rows: Vec<&Vec<String>> = cells
                .iter()
                .filter(|r| {
                    let s: String = r.concat();
                    s.contains("main") || s.contains("researcher") || s.contains("coder")
                })
                .collect();
            assert_eq!(rows.len(), 3, "expected main + 2 worker rows at w={w}");

            // Every row's `↓` sits in the identical column.
            let cols: Vec<usize> = rows
                .iter()
                .map(|r| arrow_col(r).expect("↓ present"))
                .collect();
            assert!(
                cols.iter().all(|c| *c == cols[0]),
                "meta ↓ column must line up across rows at w={w}: {cols:?}"
            );
            // Equal-width metas → the ↓ sits 5 columns in from the right edge
            // (`↓X.Xk`), and the token digit 'k' is the last cell.
            assert_eq!(
                cols[0],
                w as usize - 5,
                "↓ is 5 cols from the edge at w={w}"
            );
            for r in &rows {
                assert_eq!(
                    r[w as usize - 1],
                    "k",
                    "meta ends flush at the right edge at w={w}"
                );
            }
        }
    }

    #[test]
    fn roster_meta_aligns_with_wide_glyph_row() {
        // A worker whose agent-type carries wide (CJK) glyphs must NOT drift the
        // meta column: display-width accounting keeps its `↓` in the same column
        // as an ASCII row, and the row still fills the pane exactly (no overflow).
        let w = 70u16;
        let mut a = Agents::new();
        a.set_main_row("orchestrating", 0, 5_000); // ↓5.0k
        a.agent_started("w1", "researcher", "", "scanning modules", None, None);
        a.agent_progress(
            "w1",
            "reading entry.rs",
            4,
            4_200,
            "scanning modules",
            vec![],
            None,
        ); // ↓4.2k
           // Wide agent-type (研究者 = 3 CJK chars = 6 display columns) + long activity.
        a.agent_started("w2", "研究者", "", "x".repeat(120), None, None);
        a.agent_progress("w2", "y".repeat(120), 9, 3_300, "", vec![], None); // ↓3.3k

        let cells = render_cells(&a, w, 12);
        let rows: Vec<&Vec<String>> = cells
            .iter()
            .filter(|r| {
                let s: String = r.concat();
                s.contains("researcher") || s.contains("\u{7814}") // 研
            })
            .collect();
        assert_eq!(rows.len(), 2, "ascii worker + wide-glyph worker rows");

        let cols: Vec<usize> = rows
            .iter()
            .map(|r| arrow_col(r).expect("↓ present"))
            .collect();
        assert_eq!(
            cols[0], cols[1],
            "wide-glyph row keeps the meta column aligned: {cols:?}"
        );
        // The wide-glyph row still occupies exactly the pane width (no overflow),
        // and its meta is flush-right.
        for r in &rows {
            assert_eq!(r.len(), w as usize, "row spans exactly the pane width");
            assert_eq!(r[w as usize - 1], "k", "meta ends flush at the right edge");
        }
    }

    // ── Wave 1: the panel must not state things that are false ────────────────

    #[test]
    fn completion_without_usage_keeps_the_counters_it_accumulated() {
        // FIX 1. The background completion frame used to be handled with a
        // hardcoded `agent_completed(&id, 0, 0, …)`, so a worker that really ran
        // 12 tools and 40k tokens finished the turn displaying `0 tools · 0 tok`
        // — the panel destroyed the only real numbers it had.
        let mut a = Agents::new();
        a.agent_started("worker-1", "researcher", "", "scan", None, None);
        a.agent_progress("worker-1", "grep", 12, 40_000, "", vec![], None);

        // No usage on the wire → the accumulated counters survive untouched.
        a.agent_completed("worker-1", None, None, Some("done".into()));
        let e = a.entries.iter().find(|e| e.name == "worker-1").unwrap();
        assert_eq!(e.status, AgentStatus::Completed);
        assert_eq!(e.tool_uses, 12, "absent usage must not zero the tool count");
        assert_eq!(
            e.tokens_used, 40_000,
            "absent usage must not zero the token count"
        );

        // And a REAL zero from the wire is still honoured — `None` means absent,
        // not "ignore the backend".
        a.agent_started("worker-2", "researcher", "", "scan", None, None);
        a.agent_progress("worker-2", "grep", 5, 900, "", vec![], None);
        a.agent_completed("worker-2", Some(0), Some(0), None);
        let e2 = a.entries.iter().find(|e| e.name == "worker-2").unwrap();
        assert_eq!(
            (e2.tool_uses, e2.tokens_used),
            (0, 0),
            "an explicit 0 is applied"
        );
    }

    #[test]
    fn failure_without_usage_keeps_the_counters_it_accumulated() {
        // FIX 1, failure path — a crash is exactly when the accumulated work
        // matters most, and it was being wiped the same way.
        let mut a = Agents::new();
        a.agent_started("worker-1", "coder", "", "build", None, None);
        a.agent_progress("worker-1", "bash", 7, 12_345, "", vec![], None);
        a.agent_failed("worker-1", "boom", None, None, None);
        let e = a.entries.iter().find(|e| e.name == "worker-1").unwrap();
        assert_eq!((e.tool_uses, e.tokens_used), (7, 12_345));
    }

    // ── elapsed is the BACKEND's clock, not the panel's ─────────────────────
    //
    // The report: a subagent showing "17 seconds of work and 99 tool uses".
    // Both numbers were true. `tool_uses` is the backend's accumulated counter;
    // elapsed came from `Instant::now()` stamped locally and RESTAMPED on every
    // `agent_started`, so any re-announcement — a reconnect, a replay, a panel
    // opened after work began — zeroed one clock and left the other running.

    #[test]
    fn a_re_announced_agent_does_not_restart_its_clock() {
        use std::time::{Duration, Instant};
        let mut a = Agents::new();
        a.agent_started("w1", "researcher", "", "scan", None, None);
        // This agent has been working for five minutes and has the tool count
        // to prove it.
        if let Some(e) = a.entries.iter_mut().find(|e| e.name == "w1") {
            e.started_at = Instant::now() - Duration::from_secs(300);
        }
        a.agent_progress("w1", "grep", 99, 0, "", vec![], None);

        // A reconnect replays `agent_started` for an agent already running. The
        // backend reports its real age; the row must adopt it, not reset.
        a.agent_started("w1", "researcher", "", "scan", None, Some(300_000));

        let e = a.entries.iter().find(|e| e.name == "w1").unwrap();
        assert!(
            e.elapsed_secs() >= 299,
            "a replayed start rebased elapsed to {}s beside a real tool count of {} \
             — the two-clocks defect",
            e.elapsed_secs(),
            e.tool_uses
        );
    }

    #[test]
    fn a_row_adopted_mid_flight_starts_at_the_age_the_backend_reports() {
        // The panel opened (or the client connected) after work began. Without
        // a backend age this row could only ever start counting from zero.
        let mut a = Agents::new();
        a.agent_started("late", "coder", "", "build", None, Some(420_000));
        let e = a.entries.iter().find(|e| e.name == "late").unwrap();
        assert!(
            (419..=421).contains(&e.elapsed_secs()),
            "expected ~420s from the backend's reported age, got {}s",
            e.elapsed_secs()
        );
    }

    #[test]
    fn an_absent_age_leaves_the_anchor_alone_rather_than_resetting_it() {
        use std::time::{Duration, Instant};
        // Absent is NOT zero. An older backend, or a path with no run row, says
        // nothing about the age — and a frame that says nothing must not be
        // allowed to discard a measurement we already have.
        let mut a = Agents::new();
        a.agent_started("w1", "", "", "s", None, None);
        if let Some(e) = a.entries.iter_mut().find(|e| e.name == "w1") {
            e.started_at = Instant::now() - Duration::from_secs(200);
        }
        a.agent_progress("w1", "grep", 7, 0, "", vec![], None);
        a.agent_phase("w1", "w1", "awaiting_model", "thinking", None);

        let e = a.entries.iter().find(|e| e.name == "w1").unwrap();
        assert!(
            e.elapsed_secs() >= 199,
            "an age-less frame reset elapsed to {}s",
            e.elapsed_secs()
        );
    }

    #[test]
    fn a_finished_agents_elapsed_stays_frozen() {
        // A late frame must not un-freeze a terminal row's elapsed.
        let mut a = Agents::new();
        a.agent_started("w1", "", "", "s", None, Some(60_000));
        a.agent_completed("w1", Some(3), Some(0), None);
        let before = a
            .entries
            .iter()
            .find(|e| e.name == "w1")
            .unwrap()
            .elapsed_secs();
        a.agent_progress("w1", "grep", 4, 0, "", vec![], Some(999_000));
        let after = a
            .entries
            .iter()
            .find(|e| e.name == "w1")
            .unwrap()
            .elapsed_secs();
        assert_eq!(before, after, "a terminal row's elapsed must not move");
    }

    #[test]
    fn a_silent_running_agent_becomes_unknown_never_failed() {
        // FIX 4. A background agent emits `started` BEFORE it waits for a
        // concurrency slot and emits nothing at all while queued, so silence is
        // the normal shape of a healthy queued agent. The panel used to invent a
        // `Failed · stalled` row for it.
        use std::time::{Duration, Instant};
        let mut a = Agents::new();
        a.agent_started("queued-1", "researcher", "", "scan modules", None, None);
        if let Some(e) = a.entries.iter_mut().find(|e| e.name == "queued-1") {
            e.last_activity = Instant::now() - Duration::from_secs(Agents::STALE_SECS + 150);
        }
        a.tick();

        let e = a.entries.iter().find(|e| e.name == "queued-1").unwrap();
        assert_eq!(e.status, AgentStatus::Unknown, "silence is not death");
        assert_ne!(e.status, AgentStatus::Failed);
        assert!(e.finished_at.is_none(), "nothing terminal happened");

        // On screen: the row says what it knows and no more.
        let text = render_text(&a, 80, 12);
        // With no phase ever reported the row still admits the gap — but it
        // says the agent is STILL BEING WATCHED rather than leaving the state
        // open-ended. "state unknown · last signal 4m ago" named our ignorance
        // and implied nothing would ever change; this names the gap and the
        // fact that something is still looking.
        assert!(
            text.contains("no update for"),
            "unknown row text missing: {text:?}"
        );
        assert!(
            text.contains("still being watched"),
            "an indeterminate row must say what happens next: {text:?}"
        );
        assert!(
            !text.contains("stalled"),
            "must not claim a stall it never saw: {text:?}"
        );
        assert!(
            !text.contains("Failed"),
            "must not claim a failure: {text:?}"
        );

        // And it recovers: any later signal proves it is alive.
        a.agent_progress("queued-1", "grep pattern", 1, 10, "", vec![], None);
        let e = a.entries.iter().find(|e| e.name == "queued-1").unwrap();
        assert_eq!(
            e.status,
            AgentStatus::Running,
            "a signal revives an Unknown row"
        );
    }

    #[test]
    fn an_unknown_row_is_dropped_not_failed_once_it_is_hopeless() {
        // Unknown rows cannot linger forever, but they leave by being REMOVED —
        // never by being relabelled with an outcome nobody reported.
        use std::time::{Duration, Instant};
        let mut a = Agents::new();
        a.agent_started("ghost", "", "", "s", None, None);
        if let Some(e) = a.entries.iter_mut().find(|e| e.name == "ghost") {
            e.last_activity = Instant::now() - Duration::from_secs(Agents::UNKNOWN_REAP_SECS + 5);
        }
        a.prune_stale();
        assert!(a.entries.is_empty(), "hopeless unknown row removed");
    }

    #[test]
    fn backend_reported_stall_is_its_own_state_and_is_not_terminal() {
        // FIX 5. `background_agent_stalled` had no consumer at all. A stall is a
        // positive backend observation — distinct from `Unknown` (we lost the
        // signal) and from `Failed` (it ended badly).
        let mut a = Agents::new();
        a.agent_started("w1", "researcher", "", "scan", None, None);
        a.agent_progress("w1", "grep", 3, 500, "", vec![], None);
        a.agent_stalled("w1", 14 * 60 * 1000);

        let e = a.entries.iter().find(|e| e.name == "w1").unwrap();
        assert_eq!(e.status, AgentStatus::Stalled);
        assert!(e.finished_at.is_none(), "a stall is not a finish");
        assert_eq!(e.tool_uses, 3, "the stall keeps the work it had done");

        let text = render_text(&a, 80, 12);
        assert!(
            text.contains("no progress for 14m"),
            "stall row text: {text:?}"
        );

        // A terminal event still wins — a stalled agent that later completes is
        // completed.
        a.agent_completed("w1", None, None, None);
        assert_eq!(a.entries[0].status, AgentStatus::Completed);
        // And a stall report can never resurrect a finished row.
        a.agent_stalled("w1", 99 * 60 * 1000);
        assert_eq!(
            a.entries[0].status,
            AgentStatus::Completed,
            "terminal is terminal"
        );
    }

    #[test]
    fn running_count_excludes_finished_rows() {
        // FIX 3. The footer cue counted EVERY entry, and finished rows linger for
        // the retain window — so one live worker plus three just-finished ones
        // read as "4 subagents".
        let mut a = Agents::new();
        for n in ["a", "b", "c", "live"] {
            a.agent_started(n, "", "", "s", None, None);
        }
        a.agent_completed("a", None, None, None);
        a.agent_completed("b", None, None, None);
        a.agent_failed("c", "boom", None, None, None);

        assert_eq!(a.entry_count(), 4, "all four rows are still tracked");
        assert_eq!(a.running_count(), 1, "only the live worker is in flight");

        // Unknown/Stalled still count: neither says the agent ended.
        a.agent_stalled("live", 60_000);
        assert_eq!(a.running_count(), 1, "a stalled agent has not finished");
    }

    #[test]
    fn selected_agent_summary_explains_runtime_choices_and_recovery() {
        let mut agents = Agents::new();
        agents.agent_started("worker", "researcher", "gpt-5", "debug resize", None, None);
        agents.agent_runtime(
            "worker",
            vec!["diagnose".into()],
            "selected for tools and large context".into(),
            "matched debugging task".into(),
            2,
            1,
            "acknowledged".into(),
            vec!["retry".into(), "reassign".into()],
        );

        let summary = agents.entry_summary_at(1).unwrap();
        assert!(summary.contains("Using: diagnose"), "summary: {summary}");
        assert!(summary.contains("Why model"), "summary: {summary}");
        assert!(summary.contains("Why skill"), "summary: {summary}");
        assert!(summary.contains("2 retries"), "summary: {summary}");
        assert!(summary.contains("1 failure"), "summary: {summary}");
        assert!(summary.contains("acknowledged"), "summary: {summary}");
        assert!(agents.control_allowed("worker", "retry"));
        assert!(!agents.control_allowed("worker", "pause"));
    }

    #[test]
    fn header_never_calls_unfinished_agents_completed() {
        // A roster with nothing confirmed-running but rows that never ended used
        // to fall through to the `N agents completed` tally.
        use std::time::{Duration, Instant};
        let mut a = Agents::new();
        a.agent_started("w1", "", "", "s", None, None);
        if let Some(e) = a.entries.iter_mut().find(|e| e.name == "w1") {
            e.last_activity = Instant::now() - Duration::from_secs(Agents::STALE_SECS + 30);
        }
        a.prune_stale();
        let text = render_text(&a, 80, 12);
        assert!(
            !text.contains("completed"),
            "never claims completion: {text:?}"
        );
        // With no phase ever reported the header still admits it does not know
        // — but it says the row is still being tracked rather than leaving the
        // state open-ended, which was the whole complaint.
        assert!(
            text.contains("awaiting an update"),
            "header states the truth: {text:?}"
        );
    }

    #[test]
    fn a_quiet_agent_reports_its_phase_instead_of_our_ignorance() {
        // The bug, stated as a test: an agent waiting on a model goes quiet for
        // longer than the panel's local silence threshold. It is healthy. The
        // panel used to answer "state unknown · last signal 2m ago", which
        // described the panel and not the agent.
        use std::time::{Duration, Instant};
        let mut a = Agents::new();
        a.agent_started("w1", "", "", "s", None, None);
        a.agent_phase(
            "w1",
            "explorer",
            "awaiting_model",
            "waiting for the first response from glm-4.7",
            None,
        );
        if let Some(e) = a.entries.iter_mut().find(|e| e.name == "w1") {
            e.last_activity = Instant::now() - Duration::from_secs(Agents::STALE_SECS + 30);
        }
        a.prune_stale();
        assert_eq!(
            a.entries[0].status,
            AgentStatus::Unknown,
            "silence still demotes the row — we are not pretending it reported"
        );

        let text = render_text(&a, 100, 12);
        assert!(
            text.contains("waiting on the model"),
            "the row says what the AGENT is doing: {text:?}"
        );
        assert!(
            !text.contains("state unknown"),
            "never describes our ignorance when the backend told us: {text:?}"
        );
    }

    #[test]
    fn a_phase_revives_a_row_the_panel_had_given_up_on() {
        // Resolution: an `Unknown` row is not a dead end. Any later word from
        // the backend — including a phase, not just tool progress — returns it
        // to `Running`.
        use std::time::{Duration, Instant};
        let mut a = Agents::new();
        a.agent_started("w1", "", "", "s", None, None);
        if let Some(e) = a.entries.iter_mut().find(|e| e.name == "w1") {
            e.last_activity = Instant::now() - Duration::from_secs(Agents::STALE_SECS + 30);
        }
        a.prune_stale();
        assert_eq!(a.entries[0].status, AgentStatus::Unknown);

        a.agent_phase(
            "w1",
            "explorer",
            "starting",
            "creating an isolated worktree",
            None,
        );
        assert_eq!(
            a.entries[0].status,
            AgentStatus::Running,
            "a phase is a signal: the row is demonstrably being tracked again"
        );
    }

    #[test]
    fn a_phase_can_create_the_row_before_the_run_is_set_up() {
        // A background agent is queued BEFORE its run is started, so its first
        // phase can arrive before any `agent_started`. The roster must show it
        // rather than drop the frame on the floor.
        let mut a = Agents::new();
        a.agent_phase("bg1", "explorer", "queued", "16 of 16 slots busy", None);
        assert_eq!(a.entry_count(), 1, "the queued agent is visible");
        let text = render_text(&a, 100, 12);
        assert!(
            text.contains("queued"),
            "a queued agent says it is queued: {text:?}"
        );
    }

    /// Flatten the `/agents` DASHBOARD render (not the inline tree) — the
    /// per-agent cost column lives there.
    fn render_dashboard_text(agents: &Agents, w: u16, h: u16) -> String {
        let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
        term.draw(|f| agents.draw_dashboard(f, f.area(), 0, &[], 0))
            .unwrap();
        term.backend()
            .buffer()
            .content()
            .iter()
            .map(|c| c.symbol())
            .collect()
    }

    /// A4 — cost follows the same non-destructive rule, and an UNKNOWN cost is
    /// rendered as `—`. `$0.00` would be the panel asserting a measurement
    /// nobody made, and "this teammate was free" is exactly the wrong thing to
    /// tell someone deciding whether to delegate again.
    #[test]
    fn an_unknown_cost_renders_as_a_dash_never_as_zero() {
        let mut a = Agents::new();
        a.agent_started("w1", "researcher", "", "unpriced", None, None);
        a.agent_completed("w1", Some(3), Some(1000), None);
        a.set_agent_cost("w1", None);

        assert_eq!(
            a.entries.iter().find(|e| e.name == "w1").unwrap().cost_usd,
            None,
            "an absent cost must stay absent"
        );

        let text = render_dashboard_text(&a, 100, 16);
        // Assert on the COST COLUMN specifically (the metric tail is
        // `… · <n> tok · <cost>`), not on a bare em-dash — the dashboard title
        // contains one too, and a test that passes on the title would still
        // pass with no cost column at all.
        assert!(
            text.contains("tok \u{00b7} \u{2014}"),
            "unknown cost must render as a dash in the cost column: {text:?}"
        );
        assert!(
            !text.contains("$0.00"),
            "never claim a run was free when nobody measured it: {text:?}"
        );
    }

    /// A known cost is shown, and a later frame that carries none must not wipe
    /// it — the same rule as the tool/token counters.
    #[test]
    fn a_known_cost_is_shown_and_is_not_wiped_by_a_later_silent_frame() {
        let mut a = Agents::new();
        a.agent_started("w1", "researcher", "", "priced", None, None);
        // A sub-cent price is the realistic shape for a short subagent run, and
        // it is exactly the case that must not collapse to "$0.00".
        a.set_agent_cost("w1", Some(0.0043));
        a.agent_completed("w1", Some(3), Some(1000), None);
        a.set_agent_cost("w1", None);

        assert_eq!(
            a.entries.iter().find(|e| e.name == "w1").unwrap().cost_usd,
            Some(0.0043),
            "None is a no-op, not a write"
        );

        let text = render_dashboard_text(&a, 100, 16);
        assert!(
            text.contains("$0.0043"),
            "sub-cent costs keep their precision: {text:?}"
        );
        assert!(
            !text.contains("$0.00 "),
            "a sub-cent cost must not collapse to zero: {text:?}"
        );
    }
}
