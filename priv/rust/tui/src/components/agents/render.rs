use ratatui::prelude::*;
use ratatui::widgets::{Block, BorderType, Borders, Paragraph};

use super::entry::{AgentEntry, AgentStatus, SynthesisState, SwarmStatus};
use super::Agents;

/// Braille spinner frames for running agents.
const SPINNER: &[char] = &['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];

/// Format elapsed seconds compactly (45s → 2m15s → 1h3m).
fn fmt_elapsed(secs: u64) -> String {
    if secs < 60 {
        format!("{}s", secs)
    } else if secs < 3600 {
        format!("{}m{:02}s", secs / 60, secs % 60)
    } else {
        format!("{}h{:02}m", secs / 3600, (secs % 3600) / 60)
    }
}

impl Agents {
    /// Draw the tree-view agent display.
    pub(super) fn draw_tree(&self, frame: &mut Frame, area: Rect) {
        if area.height == 0 || area.width == 0 {
            return;
        }

        let theme = crate::style::theme();
        let mut y = area.y;

        // ── Header line ─────────────────────────────────────────────────────
        {
            let running = self
                .entries
                .iter()
                .filter(|e| matches!(e.status, AgentStatus::Running | AgentStatus::Spawning))
                .count();
            let total = self.entries.len();

            let header_text = if running > 0 {
                format!("Running {} agent{}…", running, if running == 1 { "" } else { "s" })
            } else if total > 0 {
                format!(
                    "{} agent{} completed",
                    total,
                    if total == 1 { "" } else { "s" }
                )
            } else {
                "Orchestrator".to_string()
            };

            let header_style = if running > 0 {
                theme.spinner()
            } else {
                theme.task_done()
            };

            let collapse_hint = if self.collapsed {
                " (ctrl+o to expand)"
            } else {
                " (ctrl+o to collapse)"
            };

            let mut spans = vec![
                Span::styled(header_text, header_style),
                Span::styled(collapse_hint, theme.faint()),
            ];

            if let Some(ref w) = self.wave {
                spans.push(Span::styled("  ", Style::default()));
                spans.push(Span::styled(
                    format!("Wave {}/{}", w.current, w.total),
                    theme.wave_label(),
                ));
            }

            frame.render_widget(
                Paragraph::new(Line::from(spans)),
                Rect::new(area.x, y, area.width, 1),
            );
            y += 1;
        }

        // If collapsed, only show header
        if self.collapsed {
            return;
        }

        // ── Agent rows (tree-view, with optional batch grouping) ──────────
        let groups = self.grouped_entries();
        let has_batches = groups.iter().any(|g| g.batch_id.is_some());

        for (group_idx, group) in groups.iter().enumerate() {
            if y + 1 >= area.y + area.height {
                break;
            }

            // Render batch header if any entries use batch_id
            if has_batches {
                let label = match &group.batch_id {
                    Some(id) => format!("─── Batch {}: {} ", group_idx + 1, id),
                    None => "─── Ungrouped ".to_string(),
                };
                let pad_len = (area.width as usize).saturating_sub(label.len());
                let padded = format!("{}{}", label, "─".repeat(pad_len));
                frame.render_widget(
                    Paragraph::new(Line::from(Span::styled(padded, theme.faint()))),
                    Rect::new(area.x, y, area.width, 1),
                );
                y += 1;
            }

            let group_len = group.entries.len();
            for (pos, &idx) in group.entries.iter().enumerate() {
                if y + 1 >= area.y + area.height {
                    break;
                }
                let entry = &self.entries[idx];

                let is_last = pos == group_len - 1;
                let connector = if is_last { "└─ " } else { "├─ " };
                let continuation = if is_last { "   " } else { "│  " };

                // Row 1: connector + spinner + subject + stats
                let (icon, icon_style) = self.agent_icon(entry);
                let subject = if entry.subject.is_empty() {
                    entry.name.clone()
                } else {
                    entry.subject.clone()
                };

                // Build optional role/model tag strings
                let role_str = if entry.role.is_empty() {
                    String::new()
                } else {
                    format!(" [{}]", entry.role)
                };
                let model_str = if entry.model.is_empty() {
                    String::new()
                } else {
                    format!(" ({})", shorten_model_name(&entry.model))
                };

                // Truncate subject to fit
                let stats_str = format!(
                    " · {} tool use{} · {} tokens",
                    entry.tool_uses,
                    if entry.tool_uses == 1 { "" } else { "s" },
                    fmt_tokens(entry.tokens_used)
                );
                let prefix_len = connector.len() + 2 + 1; // connector + icon + space
                let tags_len = role_str.len() + model_str.len();
                let max_subject = (area.width as usize)
                    .saturating_sub(prefix_len + tags_len + stats_str.len())
                    .max(8);
                let subject_display = truncate_str(&subject, max_subject);

                let mut row1_spans = vec![
                    Span::styled(connector, theme.faint()),
                    Span::styled(format!("{} ", icon), icon_style),
                    Span::styled(subject_display, theme.agent_name()),
                ];
                if !role_str.is_empty() {
                    row1_spans.push(Span::styled(role_str, theme.role_tag()));
                }
                if !model_str.is_empty() {
                    row1_spans.push(Span::styled(model_str, theme.model_tag()));
                }
                row1_spans.push(Span::styled(stats_str, theme.faint()));

                let row1 = Line::from(row1_spans);
                frame.render_widget(
                    Paragraph::new(row1),
                    Rect::new(area.x, y, area.width, 1),
                );
                y += 1;

                // Row 2: continuation + action line
                if y < area.y + area.height {
                    let action_display = match entry.status {
                        AgentStatus::Completed => "Done".to_string(),
                        AgentStatus::Failed => {
                            if entry.current_action.is_empty() {
                                "Failed".to_string()
                            } else {
                                entry.current_action.clone()
                            }
                        }
                        _ => {
                            if entry.current_action.is_empty() {
                                "Starting…".to_string()
                            } else {
                                entry.current_action.clone()
                            }
                        }
                    };

                    let action_style = match entry.status {
                        AgentStatus::Completed => theme.task_done(),
                        AgentStatus::Failed => theme.error_text(),
                        _ => theme.faint(),
                    };

                    // Truncate action
                    let max_action = (area.width as usize).saturating_sub(continuation.len() + 4).max(8);
                    let action_truncated = truncate_str(&action_display, max_action);

                    let row2 = Line::from(vec![
                        Span::styled(continuation, theme.faint()),
                        Span::styled("└─ ", theme.faint()),
                        Span::styled(action_truncated, action_style),
                    ]);
                    frame.render_widget(
                        Paragraph::new(row2),
                        Rect::new(area.x, y, area.width, 1),
                    );
                    y += 1;
                }
            }
        }

        // ── Synthesizing line ───────────────────────────────────────────────
        if let SynthesisState::Synthesizing { count } = self.synthesis {
            if y < area.y + area.height {
                let spin = SPINNER[self.tick as usize % SPINNER.len()];
                let line = Line::from(vec![
                    Span::styled(format!("{} ", spin), theme.spinner()),
                    Span::styled(
                        format!("Synthesizing {} agent output{}…", count, if count == 1 { "" } else { "s" }),
                        theme.spinner(),
                    ),
                ]);
                frame.render_widget(
                    Paragraph::new(line),
                    Rect::new(area.x, y, area.width, 1),
                );
            }
        }

        // ── Swarm line ──────────────────────────────────────────────────────
        if let Some(ref swarm) = self.swarm {
            if y < area.y + area.height {
                let (status_str, status_style) = match swarm.status {
                    SwarmStatus::Running => ("Running", theme.spinner()),
                    SwarmStatus::Completed => ("Done", theme.task_done()),
                    SwarmStatus::Failed => ("Failed", theme.error_text()),
                };

                let swarm_line = Line::from(vec![
                    Span::styled("Swarm: ", theme.faint()),
                    Span::styled(&*swarm.pattern, theme.tool_name()),
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

    /// Full-screen background-agent dashboard: every tracked agent grouped by
    /// state (Working / Ready / Completed / Failed) with role, elapsed, tool
    /// count and tokens. `selected` is an index into the entries list; the
    /// matching row is highlighted so it can be cancelled.
    pub fn draw_dashboard(&self, frame: &mut Frame, area: Rect, selected: usize) {
        let theme = crate::style::theme();

        let running = self
            .entries
            .iter()
            .filter(|e| matches!(e.status, AgentStatus::Running | AgentStatus::Spawning))
            .count();
        let title = format!(
            " Agent Dashboard — {} total, {} active ",
            self.entries.len(),
            running
        );
        let block = Block::default()
            .title(Span::styled(title, theme.section_title()))
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(Style::default().fg(theme.colors.border));
        let inner = block.inner(area);
        frame.render_widget(block, area);

        if inner.height < 2 || inner.width < 4 {
            return;
        }

        let mut lines: Vec<Line> = Vec::new();

        // Fixed group order with the labels the task calls for. "Ready" maps to
        // agents that are spawned but not yet running.
        let groups: [(&str, &dyn Fn(&AgentEntry) -> bool); 4] = [
            ("Working", &|e: &AgentEntry| e.status == AgentStatus::Running),
            ("Ready", &|e: &AgentEntry| e.status == AgentStatus::Spawning),
            ("Completed", &|e: &AgentEntry| e.status == AgentStatus::Completed),
            ("Failed", &|e: &AgentEntry| e.status == AgentStatus::Failed),
        ];

        for (label, pred) in groups.iter() {
            let idxs: Vec<usize> = self
                .entries
                .iter()
                .enumerate()
                .filter(|(_, e)| pred(e))
                .map(|(i, _)| i)
                .collect();
            if idxs.is_empty() {
                continue;
            }

            if !lines.is_empty() {
                lines.push(Line::from(""));
            }
            lines.push(Line::from(Span::styled(
                format!("{} ({})", label, idxs.len()),
                theme.section_title(),
            )));

            for idx in idxs {
                let entry = &self.entries[idx];
                let is_sel = idx == selected;

                let (icon, icon_style) = self.agent_icon(entry);
                let marker = if is_sel { "▸ " } else { "  " };
                let name = if entry.subject.is_empty() {
                    entry.name.clone()
                } else {
                    entry.subject.clone()
                };
                let name_style = if is_sel {
                    theme.plan_selected()
                } else {
                    theme.agent_name()
                };
                let role = if entry.role.is_empty() {
                    String::new()
                } else {
                    format!(" [{}]", entry.role)
                };
                let meta = format!(
                    "  {} · {} tool{} · {} tok",
                    fmt_elapsed(entry.elapsed_secs()),
                    entry.tool_uses,
                    if entry.tool_uses == 1 { "" } else { "s" },
                    fmt_tokens(entry.tokens_used),
                );

                let mut spans = vec![
                    Span::styled(marker, theme.plan_selected()),
                    Span::styled(format!("{} ", icon), icon_style),
                    Span::styled(name, name_style),
                ];
                if !role.is_empty() {
                    spans.push(Span::styled(role, theme.role_tag()));
                }
                spans.push(Span::styled(meta, theme.faint()));
                lines.push(Line::from(spans));
            }
        }

        if lines.is_empty() {
            lines.push(Line::from(Span::styled(
                "No agents have run yet.",
                theme.faint(),
            )));
        }

        // Footer hint.
        lines.push(Line::from(""));
        lines.push(Line::from(Span::styled(
            "↑/↓ select   c/x cancel selected   Esc/q close",
            theme.faint(),
        )));

        frame.render_widget(Paragraph::new(lines), inner);
    }

    /// Return (icon_char, style) for an agent entry based on status.
    fn agent_icon(&self, entry: &AgentEntry) -> (char, Style) {
        let theme = crate::style::theme();
        match entry.status {
            AgentStatus::Spawning => ('○', Style::default().fg(Color::DarkGray)),
            AgentStatus::Running => {
                let frame = SPINNER[self.tick as usize % SPINNER.len()];
                (frame, theme.spinner())
            }
            AgentStatus::Completed => ('✓', theme.task_done()),
            AgentStatus::Failed => ('✗', theme.error_text()),
        }
    }
}

/// Format token count as compact string: 4213 → "4.2k", 90512 → "90.5k"
fn fmt_tokens(n: u32) -> String {
    if n >= 1000 {
        format!("{:.1}k", n as f64 / 1000.0)
    } else {
        n.to_string()
    }
}

/// Shorten model names by stripping the "claude-" prefix.
fn shorten_model_name(model: &str) -> &str {
    if let Some(rest) = model.strip_prefix("claude-") {
        rest
    } else {
        model
    }
}

/// UTF-8 safe truncation with ellipsis.
fn truncate_str(s: &str, max_chars: usize) -> String {
    let char_count = s.chars().count();
    if char_count <= max_chars {
        s.to_string()
    } else {
        let truncated: String = s.chars().take(max_chars.saturating_sub(1)).collect();
        format!("{}…", truncated)
    }
}
