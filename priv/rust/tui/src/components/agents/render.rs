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

            // Live fleet gauge `<running>/<cap> agents` (Part 4.2), from the
            // backend `fleet_summary` frame. A dim "large fleet" hint appears
            // once the backend flags the >=25 warning threshold.
            if let Some(ref f) = self.fleet {
                spans.push(Span::styled(
                    format!(" \u{00b7} {}/{} agents", f.running, f.cap),
                    header_style,
                ));
                if f.warn {
                    spans.push(Span::styled(" \u{00b7} large fleet", theme.faint()));
                }
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

        // ── `main` root row (CC FleetView) ──────────────────────────────────
        // Always roster index 0, rendered GREEN (● + `main`). Synthesized by the
        // App from live session state (top-level action, turn elapsed, session
        // tokens). Selecting it + Enter detaches back to the main transcript.
        if let Some(ref main) = self.main_row {
            if y + 1 <= area.y + area.height {
                let selected = self.roster_selected == Some(0);
                let type_style = if selected {
                    theme.plan_selected()
                } else {
                    theme.agent_main()
                };
                let meta = fmt_cc_meta(main.elapsed_secs, main.tokens);
                // Reserve columns for the glyph ("● "), the label, the gap and
                // the right-hand meta, then truncate the activity to what's left.
                let prefix_cols = 2 + "main".chars().count() + 2;
                let max_activity = (area.width as usize)
                    .saturating_sub(prefix_cols + meta.chars().count() + 2)
                    .max(4);
                let mut spans = vec![
                    Span::styled("\u{25cf} ", theme.agent_main()),
                    Span::styled("main", type_style),
                ];
                if !main.activity.trim().is_empty() {
                    spans.push(Span::styled("  ", theme.faint()));
                    spans.push(Span::styled(
                        truncate_str(&main.activity, max_activity),
                        theme.faint(),
                    ));
                }
                spans.push(Span::styled(format!("  {}", meta), theme.faint()));
                frame.render_widget(
                    Paragraph::new(Line::from(spans)),
                    Rect::new(area.x, y, area.width, 1),
                );
                y += 1;
            }
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

                // Row 1: connector + CC roster layout —
                //   <glyph> <agent-type>  <live-activity…>  <elapsed> · ↓<tokens>
                // Glyph ● when this row is the selected/attached node (roster
                // index == entry index + 1), ◯ otherwise. agent-type is the
                // node's role identity (the custom-agent it was spawned as),
                // falling back to its name. Activity is the live current action.
                let selected = self.roster_selected == Some(idx + 1);
                let glyph = if selected { '\u{25cf}' } else { '\u{25cb}' };
                let glyph_style = if selected {
                    theme.agent_main()
                } else {
                    theme.faint()
                };
                let agent_type = if !entry.role.is_empty() {
                    entry.role.clone()
                } else {
                    entry.name.clone()
                };
                let type_style = if selected {
                    theme.plan_selected()
                } else {
                    theme.agent_name()
                };
                // Live activity: current action, or the subject as a fallback.
                let activity = if !entry.current_action.is_empty() {
                    entry.current_action.clone()
                } else if !entry.subject.is_empty() {
                    entry.subject.clone()
                } else {
                    String::new()
                };
                let meta = fmt_cc_meta(entry.elapsed_secs(), entry.tokens_used);

                // Char-count widths: the connector is multi-byte box drawing, so
                // byte .len() would treble-count its 3 columns.
                let prefix_len = connector.chars().count()
                    + 2 // glyph + space
                    + agent_type.chars().count()
                    + 2; // gap before activity
                let max_activity = (area.width as usize)
                    .saturating_sub(prefix_len + meta.chars().count() + 2)
                    .max(4);

                let mut row1_spans = vec![
                    Span::styled(connector, theme.faint()),
                    Span::styled(format!("{} ", glyph), glyph_style),
                    Span::styled(agent_type, type_style),
                ];
                if !activity.trim().is_empty() {
                    row1_spans.push(Span::styled("  ", theme.faint()));
                    row1_spans.push(Span::styled(
                        truncate_str(&activity, max_activity),
                        theme.faint(),
                    ));
                }
                row1_spans.push(Span::styled(format!("  {}", meta), theme.faint()));

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
                    // CC's finished line: `Done · 15m 5s`. Elapsed is frozen at
                    // `finished_at` (via `elapsed_secs()`) and formatted with the
                    // shared compact formatter, so a completed node shows how long
                    // it ran, not just that it finished.
                    AgentStatus::Completed => vec![(
                        format!(
                            "Done \u{00b7} {}",
                            crate::components::status_bar::fmt_elapsed_compact(entry.elapsed_secs()),
                        ),
                        theme.task_done(),
                    )],
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

                // Result-summary line: a dim, single truncated `⎿ <summary>` under
                // a FINISHED worker so the panel shows WHAT it produced, not just
                // that it finished. Only for terminal rows carrying a summary;
                // running rows are untouched. Failed rows use the error color.
                // MUST stay in lockstep with `Agents::entry_rows`.
                if matches!(entry.status, AgentStatus::Completed | AgentStatus::Failed) {
                    if let Some(summary) = entry.result_summary.as_deref() {
                        if y < area.y + area.height {
                            let style = if entry.status == AgentStatus::Failed {
                                theme.error_text()
                            } else {
                                theme.faint()
                            };
                            let max_summary = (area.width as usize)
                                .saturating_sub(continuation.len() + 4)
                                .max(8);
                            let summary_truncated = truncate_str(summary, max_summary);
                            let row = Line::from(vec![
                                Span::styled(continuation, theme.faint()),
                                Span::styled("\u{23bf} ", theme.faint()),
                                Span::styled(summary_truncated, style),
                            ]);
                            frame.render_widget(
                                Paragraph::new(row),
                                Rect::new(area.x, y, area.width, 1),
                            );
                            y += 1;
                        }
                    }
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
                y += 1;
            }
        }

        // ── Shared scratchpad activity ──────────────────────────────────────
        // A compact, dim section listing the last few writes to the shared
        // file-based scratchpad so the user watches coordination artifacts
        // accumulate during a fan-out. Capped by `SCRATCHPAD_CAP`; cleared when
        // the team finishes or a new turn starts. Never a log, never loud.
        if !self.scratchpad.is_empty() && y < area.y + area.height {
            let n = self.scratchpad.len();
            let header = Line::from(vec![
                Span::styled("scratchpad", theme.faint()),
                Span::styled(
                    format!(" \u{00b7} {} entr{}", n, if n == 1 { "y" } else { "ies" }),
                    theme.faint(),
                ),
            ]);
            frame.render_widget(Paragraph::new(header), Rect::new(area.x, y, area.width, 1));
            y += 1;

            for note in self.scratchpad.iter() {
                if y >= area.y + area.height {
                    break;
                }
                // "  ↳ @agent wrote findings.md (2.1k)" — all dim, tucked under
                // the agent rows.
                let who = short_agent(&note.agent);
                let line_text = format!(
                    "  \u{21b3} @{} {} {} ({})",
                    who,
                    note.action,
                    note.entry,
                    fmt_bytes(note.bytes),
                );
                let truncated = truncate_str(&line_text, (area.width as usize).max(8));
                frame.render_widget(
                    Paragraph::new(Line::from(Span::styled(truncated, theme.faint()))),
                    Rect::new(area.x, y, area.width, 1),
                );
                y += 1;
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
        // Live fleet gauge `<running>/<cap> agents` (Part 4.2) from `fleet_summary`.
        if let Some(ref f) = self.fleet {
            title = format!("{}· {}/{} agents ", title.trim_end(), f.running, f.cap);
            if f.warn {
                title = format!("{}· large fleet ", title.trim_end());
            }
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

        // ── `main` root row (CC FleetView) — always selection index 0, GREEN.
        // Selecting it + Enter detaches back to the main transcript; it is never
        // cancellable. Synthesized from live session state by the App.
        {
            let is_sel = selected == 0;
            let marker = if is_sel { "▸ " } else { "  " };
            let (activity, meta) = match self.main_row {
                Some(ref m) => (
                    if m.activity.trim().is_empty() {
                        String::new()
                    } else {
                        m.activity.clone()
                    },
                    format!("  {}", fmt_cc_meta(m.elapsed_secs, m.tokens)),
                ),
                None => (String::new(), String::new()),
            };
            let type_style = if is_sel {
                theme.plan_selected()
            } else {
                theme.agent_main()
            };
            let mut spans = vec![
                Span::styled(marker, theme.plan_selected()),
                Span::styled("\u{25cf} ", theme.agent_main()),
                Span::styled("main", type_style),
            ];
            if !activity.is_empty() {
                spans.push(Span::styled("  ", theme.faint()));
                spans.push(Span::styled(activity, theme.faint()));
            }
            if !meta.is_empty() {
                spans.push(Span::styled(meta, theme.faint()));
            }
            lines.push(Line::from(spans));
        }

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
                // Selection is in ROSTER index space (0 = main), so an entry at
                // `entries[idx]` is selected when the cursor is at `idx + 1`.
                let is_sel = idx + 1 == selected;

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
                // Roster index space: 0 = main, 1..=entries, then bg terminals.
                let global_idx = 1 + self.entries.len() + pos;
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
            AgentStatus::Spawning => ('⚡', theme.task_pending()),
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

/// Format token count as a compact k/M-scaled string: 4213 → "4.2k",
/// 117_500 → "117.5k", 1_200_000 → "1.2M" (CC FleetView roster style).
fn fmt_tokens(n: u32) -> String {
    if n >= 1_000_000 {
        format!("{:.1}M", n as f64 / 1_000_000.0)
    } else if n >= 1000 {
        format!("{:.1}k", n as f64 / 1000.0)
    } else {
        n.to_string()
    }
}

/// The CC roster row's right-hand meta column: `<elapsed> · ↓<tokens>`, e.g.
/// `10m 25s · ↓107.3k`. Reuses the shared compact elapsed formatter and the
/// k/M token scaler so every roster surface renders identically.
fn fmt_cc_meta(elapsed_secs: u64, tokens: u32) -> String {
    format!(
        "{} \u{00b7} \u{2193}{}",
        crate::components::status_bar::fmt_elapsed_compact(elapsed_secs),
        fmt_tokens(tokens),
    )
}

/// Format a byte size compactly: 312 → "312", 2100 → "2.1k", 1_500_000 → "1.5M".
fn fmt_bytes(n: u64) -> String {
    if n >= 1_000_000 {
        format!("{:.1}M", n as f64 / 1_000_000.0)
    } else if n >= 1000 {
        format!("{:.1}k", n as f64 / 1000.0)
    } else {
        n.to_string()
    }
}

/// Compact a writer's session id for the scratchpad line. Worker session ids
/// look like `agent:<parent>:1`; showing the trailing `<parent>:1` keeps the
/// line short while still distinguishing teammates. Non-worker ids pass through.
fn short_agent(agent: &str) -> String {
    let trimmed = agent.strip_prefix("agent:").unwrap_or(agent);
    truncate_str(trimmed, 18)
}

/// Shorten model names by stripping the "claude-" prefix.
#[allow(dead_code)]
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
