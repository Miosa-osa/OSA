use ratatui::prelude::*;
use ratatui::widgets::Paragraph;

use crate::event::Event;

use super::{Component, ComponentAction};

// ─── Types ────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum AgentStatus {
    Running,
    Completed,
    Failed,
}

struct AgentEntry {
    name: String,
    role: String,
    #[allow(dead_code)]
    model: String,
    status: AgentStatus,
    current_action: String,
    tool_uses: u32,
    tokens_used: u32,
}

struct WaveInfo {
    current: u32,
    total: u32,
}

struct SwarmInfo {
    id: String,
    pattern: String,
    agent_count: u32,
    status: SwarmStatus,
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum SwarmStatus {
    Running,
    Completed,
    Failed,
}

// ─── Component ────────────────────────────────────────────────────────────────

pub struct Agents {
    active: bool,
    task_id: Option<String>,
    agents: Vec<AgentEntry>,
    wave: Option<WaveInfo>,
    swarm: Option<SwarmInfo>,
}

impl Agents {
    pub fn new() -> Self {
        Self {
            active: false,
            task_id: None,
            agents: Vec::new(),
            wave: None,
            swarm: None,
        }
    }

    #[allow(dead_code)]
    pub fn is_active(&self) -> bool {
        self.active
    }

    /// Total render height: 0 when inactive, else header + agents + optional swarm line.
    pub fn height(&self) -> u16 {
        if !self.active {
            return 0;
        }
        let agent_lines = self.agents.len() as u16;
        let swarm_lines = if self.swarm.is_some() { 1u16 } else { 0 };
        // 1 title/header line + agents + blank gap + swarm
        2 + agent_lines + swarm_lines
    }

    // ─── Public mutation API ───────────────────────────────────────────────────

    pub fn task_started(&mut self, task_id: impl Into<String>) {
        self.active = true;
        self.task_id = Some(task_id.into());
        self.agents.clear();
        self.wave = None;
        self.swarm = None;
    }

    pub fn agent_started(&mut self, name: impl Into<String>, role: impl Into<String>, model: impl Into<String>) {
        let name = name.into();
        // Avoid duplicates — treat a restart as a reset
        if let Some(entry) = self.agents.iter_mut().find(|e| e.name == name) {
            entry.status = AgentStatus::Running;
            entry.current_action = String::new();
            entry.tool_uses = 0;
            entry.tokens_used = 0;
        } else {
            self.agents.push(AgentEntry {
                name,
                role: role.into(),
                model: model.into(),
                status: AgentStatus::Running,
                current_action: String::new(),
                tool_uses: 0,
                tokens_used: 0,
            });
        }
        self.active = true;
    }

    pub fn agent_progress(&mut self, name: &str, action: impl Into<String>, tool_uses: u32, tokens: u32) {
        if let Some(entry) = self.agents.iter_mut().find(|e| e.name == name) {
            entry.current_action = action.into();
            entry.tool_uses = tool_uses;
            entry.tokens_used = tokens;
        }
    }

    pub fn agent_completed(&mut self, name: &str, tool_uses: u32, tokens: u32) {
        if let Some(entry) = self.agents.iter_mut().find(|e| e.name == name) {
            entry.status = AgentStatus::Completed;
            entry.current_action = "complete".into();
            entry.tool_uses = tool_uses;
            entry.tokens_used = tokens;
        }
    }

    pub fn agent_failed(&mut self, name: &str, error: impl Into<String>, tool_uses: u32, tokens: u32) {
        if let Some(entry) = self.agents.iter_mut().find(|e| e.name == name) {
            entry.status = AgentStatus::Failed;
            entry.current_action = error.into();
            entry.tool_uses = tool_uses;
            entry.tokens_used = tokens;
        }
    }

    pub fn wave_started(&mut self, current: u32, total: u32) {
        self.wave = Some(WaveInfo { current, total });
    }

    pub fn task_completed(&mut self) {
        // Caller may want to hide after a tick delay; here we just mark inactive immediately.
        self.active = false;
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

    #[allow(dead_code)]
    pub fn clear(&mut self) {
        self.active = false;
        self.task_id = None;
        self.agents.clear();
        self.wave = None;
        self.swarm = None;
    }

    // ─── Drawing helpers ───────────────────────────────────────────────────────

    /// Format token count as compact string: 4213 → "4.2k"
    fn fmt_tokens(n: u32) -> String {
        if n >= 1000 {
            format!("{:.1}k", n as f64 / 1000.0)
        } else {
            n.to_string()
        }
    }
}

impl Component for Agents {
    fn handle_event(&mut self, _event: &Event) -> ComponentAction {
        ComponentAction::Ignored
    }

    fn draw(&self, frame: &mut Frame, area: Rect) {
        if !self.active || area.height == 0 || area.width == 0 {
            return;
        }

        let theme = crate::style::theme();
        let mut y = area.y;

        // ── Title / header line ───────────────────────────────────────────────
        // "─── Orchestrator ─── Wave 2/3 ───"
        {
            let separator = Span::styled("\u{2500}\u{2500}\u{2500} ", theme.faint());
            let title = Span::styled("Orchestrator", theme.agent_label());
            let sep2 = Span::styled(" \u{2500}\u{2500}\u{2500}", theme.faint());

            let mut header_spans = vec![separator, title, sep2];

            if let Some(ref w) = self.wave {
                header_spans.push(Span::styled(" ", Style::default()));
                header_spans.push(Span::styled(
                    format!("Wave {}/{}", w.current, w.total),
                    theme.wave_label(),
                ));
                header_spans.push(Span::styled(" \u{2500}\u{2500}\u{2500}", theme.faint()));
            }

            let header_line = Line::from(header_spans);
            frame.render_widget(
                Paragraph::new(header_line),
                Rect::new(area.x, y, area.width, 1),
            );
            y += 1;
        }

        // ── Agent rows ────────────────────────────────────────────────────────
        for entry in &self.agents {
            if y >= area.y + area.height {
                break;
            }

            let (icon, icon_style) = match entry.status {
                AgentStatus::Running => ("\u{25b8}", theme.spinner()),       // ▸ primary
                AgentStatus::Completed => ("\u{2713}", theme.task_done()),   // ✓ green
                AgentStatus::Failed => ("\u{2718}", theme.error_text()),     // ✘ red
            };

            // Truncate action to keep row tidy
            let max_action = (area.width as usize).saturating_sub(48).max(8);
            let action_display = if entry.current_action.len() > max_action {
                format!("{}...", &entry.current_action[..max_action.saturating_sub(3)])
            } else {
                entry.current_action.clone()
            };

            let tokens_str = Self::fmt_tokens(entry.tokens_used);
            let meta = format!(
                "  \u{2699} {}  {} tools  {} tokens",
                action_display, entry.tool_uses, tokens_str
            );

            let row = Line::from(vec![
                Span::styled(format!("{} ", icon), icon_style),
                Span::styled(format!("{:<16}", &entry.name), theme.agent_name()),
                Span::styled(format!("{:<12}", &entry.role), theme.agent_role()),
                Span::styled(meta, theme.faint()),
            ]);

            frame.render_widget(
                Paragraph::new(row),
                Rect::new(area.x, y, area.width, 1),
            );
            y += 1;
        }

        // ── Swarm line ────────────────────────────────────────────────────────
        if let Some(ref swarm) = self.swarm {
            if y < area.y + area.height {
                // blank gap before swarm
                y = y.max(area.y + 1);

                let (status_str, status_style) = match swarm.status {
                    SwarmStatus::Running => ("Running", theme.spinner()),
                    SwarmStatus::Completed => ("Done", theme.task_done()),
                    SwarmStatus::Failed => ("Failed", theme.error_text()),
                };

                let swarm_line = Line::from(vec![
                    Span::styled("Swarm: ", theme.faint()),
                    Span::styled(&swarm.pattern, theme.tool_name()),
                    Span::styled(
                        format!("  {} agents  ", swarm.agent_count),
                        theme.faint(),
                    ),
                    Span::styled(status_str, status_style),
                ]);

                frame.render_widget(
                    Paragraph::new(swarm_line),
                    Rect::new(area.x, y, area.width, 1),
                );
            }
        }
    }
}
