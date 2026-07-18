use ratatui::prelude::*;
use ratatui::widgets::{Block, BorderType, Borders, Paragraph};

use super::entry::{AgentEntry, AgentStatus, BgTerminalRow, SynthesisState, SwarmStatus};
use super::Agents;

/// Braille spinner frames for running agents.
const SPINNER: &[char] = &['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];

/// Shared h/m/s formatter so the panel, dashboard, teammate lines, background
/// completions and the turn recap all render durations identically.
use crate::util::fmt_elapsed;

impl Agents {
    /// Draw the tree-view agent display.
    pub(super) fn draw_tree(&self, frame: &mut Frame, area: Rect) {
        if area.height == 0 || area.width == 0 {
            return;
        }

        let theme = crate::style::theme();
        let mut y = area.y;

        // ── Background-terminals summary ─────────────────────────────────────
        // Ctrl+B'd turns + running background shell commands aren't tree entries,
        // so surface them as a one-line "N background terminals · ↓ to manage"
        // header (matching Claude Code). Rendered even when no agents are active.
        if self.bg_summary > 0 && y < area.y + area.height {
            let line = format!(
                "\u{21e3} {} background terminal{} \u{00b7} \u{2193} to manage",
                self.bg_summary,
                if self.bg_summary == 1 { "" } else { "s" }
            );
            frame.render_widget(
                Paragraph::new(Line::from(Span::styled(line, theme.faint()))),
                Rect::new(area.x, y, area.width, 1),
            );
            y += 1;
        }

        // With no live agent tree (panel inactive) the summary line is all there
        // is to draw.
        if !self.active {
            return;
        }

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

            // Advertise the full-screen dashboard when there are tracked agents.
            if !self.entries.is_empty() {
                spans.push(Span::styled(" \u{00b7} \u{2193} to manage", theme.faint()));
            }

            // Surface the task-level appraised cost when available (the only cost
            // signal the backend reports — there is no per-agent breakdown).
            if let Some(cost) = self.est_cost_usd {
                spans.push(Span::styled(
                    format!(" \u{00b7} est. {}", fmt_cost(cost)),
                    theme.faint(),
                ));
            }

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
                let label = match group.batch_id.as_deref() {
                    // Foreground-vs-background display: background agents get a
                    // named section instead of an opaque "Batch N: background".
                    Some("background") => "─── Background agents ".to_string(),
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

                // Rows 2+: action trail. Running agents show the last up-to-3
                // recent actions (oldest first) preceded by a "+N more tool
                // uses" counter (CC AgentTool UI parity); terminal agents keep
                // a single Done/Failed row. Row count MUST match
                // `Agents::entry_rows` or the layout desyncs.
                let trail: Vec<(String, Style)> = match entry.status {
                    AgentStatus::Completed => vec![("Done".to_string(), theme.task_done())],
                    AgentStatus::Failed => {
                        let msg = if entry.current_action.is_empty() {
                            "Failed".to_string()
                        } else {
                            entry.current_action.clone()
                        };
                        vec![(msg, theme.error_text())]
                    }
                    _ => {
                        let mut rows: Vec<(String, Style)> = Vec::new();
                        let shown = entry.recent_actions.len().min(3);
                        if entry.tool_uses as usize > shown {
                            rows.push((
                                format!("+{} more tool uses", entry.tool_uses as usize - shown),
                                theme.faint(),
                            ));
                        }
                        // recent_actions is newest-first; display oldest → newest.
                        for a in entry.recent_actions.iter().take(3).rev() {
                            rows.push((a.clone(), theme.faint()));
                        }
                        if rows.is_empty() {
                            let msg = if entry.current_action.is_empty() {
                                "Starting…".to_string()
                            } else {
                                entry.current_action.clone()
                            };
                            rows.push((msg, theme.faint()));
                        }
                        rows
                    }
                };

                for (line_text, line_style) in trail {
                    if y >= area.y + area.height {
                        break;
                    }
                    let max_action =
                        (area.width as usize).saturating_sub(continuation.len() + 4).max(8);
                    let action_truncated = truncate_str(&line_text, max_action);
                    let row = Line::from(vec![
                        Span::styled(continuation, theme.faint()),
                        Span::styled("└─ ", theme.faint()),
                        Span::styled(action_truncated, line_style),
                    ]);
                    frame.render_widget(Paragraph::new(row), Rect::new(area.x, y, area.width, 1));
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

    /// Full-screen management dashboard: every tracked sub-agent grouped by state
    /// (Working / Ready / Completed / Failed) with role, a compact progress
    /// indicator, elapsed, tool count and tokens — followed by a Background
    /// Terminals section listing the Ctrl+B'd turns in `bg_rows` and a count of
    /// running background shell jobs (`shell_jobs`).
    ///
    /// `selected` is a unified index across the two lists: `0..entries.len()`
    /// selects a sub-agent (highlighted for view/stop), and
    /// `entries.len()..entries.len()+bg_rows.len()` selects a background terminal.
    ///
    /// Cost: the backend reports no per-agent cost, so the header shows the
    /// task-level appraised estimate (when known) and the footer notes that the
    /// per-agent breakdown is unavailable — no fabricated per-row figure.
    pub fn draw_dashboard(
        &self,
        frame: &mut Frame,
        area: Rect,
        selected: usize,
        bg_rows: &[BgTerminalRow],
        shell_jobs: usize,
    ) {
        let theme = crate::style::theme();

        let running = self
            .entries
            .iter()
            .filter(|e| matches!(e.status, AgentStatus::Running | AgentStatus::Spawning))
            .count();
        let bg_running = bg_rows.iter().filter(|r| !r.done).count() + shell_jobs;
        let mut title = format!(
            " Agent Dashboard — {} agent{}, {} active · {} background ",
            self.entries.len(),
            if self.entries.len() == 1 { "" } else { "s" },
            running,
            bg_running,
        );
        if let Some(cost) = self.est_cost_usd {
            title = format!("{}· est. {} ", title.trim_end(), fmt_cost(cost));
        }
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

        // Busiest agent's token count anchors the relative progress micro-bar so a
        // row's fill reflects its real share of activity (not a fabricated %).
        let max_tokens = self.entries.iter().map(|e| e.tokens_used).max().unwrap_or(0);

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
                // Compact progress indicator from the data we actually have: a
                // token-usage micro-bar (relative to the busiest agent) plus
                // elapsed/tool/token counts. No per-agent percent or cost exists.
                let meta = format!(
                    "  {} {} · {} tool{} · {} tok",
                    token_bar(entry.tokens_used, max_tokens),
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

        // ── Background Terminals section ─────────────────────────────────────
        if !bg_rows.is_empty() || shell_jobs > 0 {
            if !lines.is_empty() {
                lines.push(Line::from(""));
            }
            lines.push(Line::from(Span::styled(
                format!("Background Terminals ({})", bg_rows.len()),
                theme.section_title(),
            )));

            for (pos, row) in bg_rows.iter().enumerate() {
                let global_idx = self.entries.len() + pos;
                let is_sel = global_idx == selected;
                let (icon, icon_style) = if row.done {
                    ('✓', theme.task_done())
                } else {
                    let spin = SPINNER[self.tick as usize % SPINNER.len()];
                    (spin, theme.spinner())
                };
                let marker = if is_sel { "▸ " } else { "  " };
                let name_style = if is_sel {
                    theme.plan_selected()
                } else {
                    theme.agent_name()
                };
                let status = if row.done { "done" } else { "running" };
                let meta = format!(
                    "  {} · {}",
                    fmt_elapsed(row.elapsed_secs),
                    status,
                );
                let spans = vec![
                    Span::styled(marker, theme.plan_selected()),
                    Span::styled(format!("{} ", icon), icon_style),
                    Span::styled(format!("[{}] ", row.id), theme.faint()),
                    Span::styled(truncate_str(&row.summary, 48), name_style),
                    Span::styled(meta, theme.faint()),
                ];
                lines.push(Line::from(spans));
            }

            if shell_jobs > 0 {
                lines.push(Line::from(Span::styled(
                    format!(
                        "  \u{2699} {} background shell job{} running",
                        shell_jobs,
                        if shell_jobs == 1 { "" } else { "s" }
                    ),
                    theme.faint(),
                )));
            }
        }

        if lines.is_empty() {
            lines.push(Line::from(Span::styled(
                "No agents or background terminals yet.",
                theme.faint(),
            )));
        }

        // Cost note: honest about the missing per-agent breakdown.
        lines.push(Line::from(""));
        let cost_note = match self.est_cost_usd {
            Some(cost) => format!(
                "Cost: task est. {} — per-agent cost not reported by backend",
                fmt_cost(cost)
            ),
            None => "Cost: not reported by backend (no per-task or per-agent estimate)".to_string(),
        };
        lines.push(Line::from(Span::styled(cost_note, theme.faint())));

        // Footer hint.
        lines.push(Line::from(Span::styled(
            "↑/↓ select   enter view   c/x stop   Esc/q close",
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

/// Format an appraised cost in USD compactly: 0.0042 → "$0.0042", 1.2 → "$1.20".
/// Sub-cent estimates keep four decimals so small runs aren't rendered as "$0.00".
fn fmt_cost(usd: f64) -> String {
    if usd > 0.0 && usd < 0.01 {
        format!("${:.4}", usd)
    } else {
        format!("${:.2}", usd)
    }
}

/// Five-cell token-usage micro-bar visualizing this agent's token count relative
/// to the busiest agent. This is a real proportion of observed tokens (the only
/// per-agent progress signal available) — not a fabricated completion percent.
fn token_bar(tokens: u32, max_tokens: u32) -> String {
    const CELLS: usize = 5;
    if max_tokens == 0 {
        return "[·····]".to_string();
    }
    let filled = ((tokens as f64 / max_tokens as f64) * CELLS as f64).round() as usize;
    let filled = filled.min(CELLS);
    let mut bar = String::from("[");
    for i in 0..CELLS {
        bar.push(if i < filled { '\u{2588}' } else { '\u{00b7}' });
    }
    bar.push(']');
    bar
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
