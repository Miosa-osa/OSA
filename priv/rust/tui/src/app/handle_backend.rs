use crate::app::state::AppState;
use crate::components::activity::ProcessingPhase;
use crate::event::backend::BackendEvent;
use std::time::Duration;
use tracing::{debug, error, info, warn};

use super::App;

/// How long the terminal must be free of keystrokes before a turn-completion
/// notification is emitted. Approximates "user stepped away / terminal unfocused"
/// (crossterm focus reporting is not enabled), so quick turns the user is
/// actively watching stay silent while long unattended ones ping.
const NOTIFY_IDLE_THRESHOLD: Duration = Duration::from_secs(10);

impl App {
    /// Flush the collapsed-tool accumulator: emit the pending run (e.g. three
    /// reads → "Read 3 files") as one scrollback line, if any. Called at every
    /// break site (non-collapsible tool, different kind, interstitial text,
    /// turn end).
    pub(super) fn flush_collapse(&mut self) {
        if let Some(line) = self.collapse.take_summary_line() {
            self.chat.add_collapsed_tool_summary(line);
        }
    }

    /// Emit a completion notification (terminal bell + OSC 9 desktop notice) when
    /// a turn finishes and the user is likely away. Gated by `notify_on_complete`
    /// (disable with the OSA_NO_NOTIFY env var) and an idle heuristic so turns the
    /// user is actively watching don't ping.
    pub(super) fn notify_turn_complete(&mut self) {
        if !self.notify_on_complete {
            return;
        }
        let idle_enough = self
            .last_user_input
            .map(|t| t.elapsed() >= NOTIFY_IDLE_THRESHOLD)
            .unwrap_or(true);
        if idle_enough {
            emit_completion_notification();
        }
    }

    pub(super) fn handle_backend_event(&mut self, event: BackendEvent) -> bool {
        match event {
            BackendEvent::HealthResult(result) => {
                self.handle_health_result(result);
            }
            BackendEvent::LoginResult(result) => {
                self.handle_login_result(result);
            }
            BackendEvent::SseConnected { session_id } => {
                info!("SSE connected: {}", session_id);
                self.sse_reconnecting = false;
                self.sidebar.set_session(&self.session_id);
                // Load commands and tools after SSE connection
                self.load_commands();
                self.load_tools();
            }
            BackendEvent::SseDisconnected { error } => {
                match error.as_deref() {
                    Some("token_refreshed") => {
                        info!("SSE reconnecting with refreshed token");
                        self.toasts.push(
                            "SSE reconnecting with refreshed token".into(),
                            crate::components::toast::ToastLevel::Info,
                        );
                        self.start_sse();
                    }
                    Some("auth_failed") => {
                        warn!("SSE auth failed after refresh attempt");
                        self.toasts.push(
                            "SSE auth failed. Try /login to re-authenticate.".into(),
                            crate::components::toast::ToastLevel::Error,
                        );
                        self.sse_reconnecting = true;
                    }
                    Some(err) => {
                        warn!("SSE disconnected: {}", err);
                        self.sse_reconnecting = true;
                    }
                    None => {
                        self.sse_reconnecting = true;
                    }
                }
            }
            BackendEvent::SseReconnecting { attempt } => {
                debug!("SSE reconnecting (attempt {})", attempt);
                self.sse_reconnecting = true;
            }
            BackendEvent::StreamingToken { text, .. } => {
                if self.state.is_processing() {
                    // Reasoning is over once real tokens stream: collapse the
                    // thinking box so the elapsed-timer spinner row returns for
                    // the rest of the turn. Without this the box (which REPLACES
                    // the activity row in draw_inline) froze at "▶ Thinking…"
                    // until agent_response, hiding the timer the recap must
                    // agree with. A later ThinkingDelta (multi-iteration turn)
                    // repopulates it; thinking_buf is kept — it is the
                    // transcript accumulator, not the live box.
                    if !self.thinking_box.is_empty() {
                        self.thinking_box.clear();
                    }
                    self.stream_buf.push_str(&text);
                    self.chat.update_streaming(&self.stream_buf);
                    self.activity.add_stream_chars(text.len());
                    self.activity.set_phase(ProcessingPhase::Streaming);
                }
            }
            BackendEvent::ThinkingDelta { text } => {
                self.thinking_buf.push_str(&text);
                self.thinking_box.update(&text);
                self.activity.add_thinking_chars(text.len());
                self.activity.set_phase(ProcessingPhase::Thinking);
            }
            BackendEvent::AgentResponse {
                response,
                response_type: _,
                signal,
            } => {
                let was_processing = self.state.is_processing();
                self.handle_agent_response(response, signal);
                // True turn-end edge: `handle_agent_response` flips Processing →
                // Idle only when the turn actually completes. Fire the completion
                // notification exactly on that transition (mid-turn agent_response
                // events stay in Processing, so this never double-pings).
                if was_processing && !self.state.is_processing() {
                    self.notify_turn_complete();
                }
            }
            BackendEvent::ToolCallStart { name, args } => {
                // Flush any accumulated streaming text as a chat message BEFORE
                // the tool call. This interleaves text and tool calls
                // chronologically instead of dumping all text at the end.
                //
                // Only the very first flush of a turn shows the "◈ OSA" header.
                // Subsequent flushes (text chunks between tool calls) use the
                // header-less AgentContinuation type so the conversation looks
                // like a single flowing response rather than multiple separate
                // "◈ OSA" blocks.
                //
                // agent_header_sent is set unconditionally here — even when
                // stream_buf is empty (LLM went straight to a tool call with no
                // preamble). Without this, the flag would stay false and the
                // next non-empty ToolCallStart flush would call add_agent_message
                // again, emitting a duplicate "◈ OSA" header mid-turn.
                //
                // Finalize any still-pending tool call into native scrollback
                // first, so ordering stays: [prior text][prior tool][this text].
                self.chat.flush_pending_tools();
                if !self.stream_buf.is_empty() {
                    // Assistant text separates the previous tool run from this
                    // one — commit the collapsed summary before the text so the
                    // scrollback order stays [prior tools][text][this tool].
                    self.flush_collapse();
                    let text = self.stream_buf.clone();
                    self.chat.clear_streaming();
                    if self.agent_header_sent {
                        self.chat.add_agent_continuation(&text);
                    } else {
                        self.chat.add_agent_message(&text, None);
                    }
                    self.stream_buf.clear();
                }
                self.agent_header_sent = true;

                if !self.activity.is_active() {
                    self.activity.start();
                }
                self.activity.tool_start(&name, &args);
                self.activity.set_phase(ProcessingPhase::ToolCall);
                // A shell call with run_in_background counts as a live background
                // terminal until its `background_command_completed` event lands.
                // A shell call WITHOUT it is a foreground command that Ctrl+B can
                // detach to the background mid-run.
                if is_shell_tool(&name) {
                    if is_run_in_background(&args) {
                        self.bg_shell_count += 1;
                        self.refresh_bg_indicators();
                    } else {
                        self.active_fg_shell_count += 1;
                    }
                }
                // Stash args (FIFO queue per name) so ToolCallEnd can build a rich
                // summary even when several same-name calls overlap.
                self.pending_tool_args.entry(name.clone()).or_default().push(args);
                self.recompute_layout();
                debug!("Tool call start: {}", name);
            }
            BackendEvent::ToolCallEnd {
                name,
                duration_ms,
                success,
            } => {
                self.activity.tool_end(&name, duration_ms, success);
                self.activity.set_phase(ProcessingPhase::Waiting);

                // Build rich styled tool summary for the chat — pop the OLDEST
                // pending args for this tool name (FIFO), matching call order.
                let args = self
                    .pending_tool_args
                    .get_mut(&name)
                    .filter(|q| !q.is_empty())
                    .map(|q| q.remove(0))
                    .unwrap_or_default();
                // A foreground shell command just ended — it's no longer
                // detachable. (A run_in_background shell was never counted here.)
                if is_shell_tool(&name)
                    && !is_run_in_background(&args)
                    && self.active_fg_shell_count > 0
                {
                    self.active_fg_shell_count -= 1;
                }
                // Collapse consecutive same-kind tool calls into one summary
                // line ("Read N files", "Ran N shell commands", …). Only
                // NonCollapsible tools (edit/write/web/…) keep full rendering.
                let kind = crate::tools::collapse::classify(&name, &args);
                if kind.is_collapsible() {
                    // A different collapsible kind breaks the run.
                    if !self.collapse.is_empty() && !self.collapse.family_matches(&kind) {
                        self.flush_collapse();
                    }
                    self.collapse.add(&kind, &args, success);
                    debug!(
                        "Tool call end (collapsed): {} ({}ms, success={})",
                        name, duration_ms, success
                    );
                } else {
                    // Non-collapsible tool: commit any pending collapsed run
                    // first so ordering stays chronological, then render fully.
                    self.flush_collapse();
                    let status = if success {
                        crate::tools::ToolStatus::Success
                    } else {
                        crate::tools::ToolStatus::Error
                    };
                    let opts = crate::tools::RenderOpts {
                        status,
                        width: self.width,
                        expanded: false,
                        compact: true,
                        spinner_frame: None,
                        duration_ms,
                        truncated: false,
                    };
                    let lines = crate::tools::render_tool(&name, &args, "", &opts);
                    if !lines.is_empty() {
                        use crate::components::chat::message::ToolCallData;
                        self.chat.add_tool_message_rich(ToolCallData {
                            name: name.clone(),
                            args,
                            result: String::new(),
                            duration_ms,
                            success,
                            expanded: false,
                            lines,
                        });
                    }
                    debug!(
                        "Tool call end: {} ({}ms, success={})",
                        name, duration_ms, success
                    );
                }
            }
            BackendEvent::ToolResult {
                name, result, success,
            } => {
                // Attach result to last matching tool message for expand support,
                // then finalize the tool into native scrollback. Scrolled-back
                // tool calls become static (lose Ctrl+O), matching Claude Code.
                if !result.is_empty() {
                    self.chat.update_last_tool_result(&name, &result);
                }
                self.chat.finalize_tool(&name);
                debug!("Tool result: {} (success={})", name, success);
            }
            BackendEvent::LlmRequest { iteration } => {
                self.activity.set_iteration(iteration as u32);
                self.status.set_iteration(iteration as u32);
                debug!("LLM request iteration {}", iteration);
            }
            BackendEvent::LlmResponse {
                duration_ms,
                input_tokens,
                output_tokens,
            } => {
                self.status
                    .set_stats(input_tokens, output_tokens, duration_ms);
                self.activity.set_tokens(input_tokens, output_tokens);
                self.sidebar.set_tokens(input_tokens, output_tokens);
            }
            BackendEvent::SignalClassified { signal } => {
                self.status.set_signal(signal);
            }
            BackendEvent::ContextPressure {
                utilization,
                estimated_tokens,
                max_tokens,
                percent_left,
                context_low,
            } => {
                // Normalize at the handler level: the backend sends utilization as
                // a 0-100 percentage. If it's absent/zero but the token counts are
                // present, derive the ratio from estimated/max so the meter still
                // reflects real usage instead of sticking at 0%.
                let mut ratio = if utilization > 1.0 { utilization / 100.0 } else { utilization };
                if ratio <= 0.0 && max_tokens > 0 && estimated_tokens > 0 {
                    ratio = estimated_tokens as f64 / max_tokens as f64;
                }
                self.status.set_context(ratio, estimated_tokens, max_tokens);
                // WS12 — feed the CC token-warning state to the status bar; the
                // context-low hint above the composer keys off these.
                self.status
                    .set_context_warning(percent_left, context_low.unwrap_or(false));
                self.sidebar.set_context(ratio);
            }
            BackendEvent::TaskCreated {
                task_id,
                subject,
                active_form,
            } => {
                self.tasks.add(task_id.clone(), subject.clone(), String::new());
                self.task_checklist.add(task_id, subject, Some(active_form));
                self.recompute_layout();
            }
            BackendEvent::TaskUpdated { task_id, status } => {
                self.tasks.update(&task_id, &status);
                let checklist_status = match status.as_str() {
                    "completed" => crate::components::task_checklist::ChecklistStatus::Completed,
                    "in_progress" => crate::components::task_checklist::ChecklistStatus::InProgress,
                    "failed" => crate::components::task_checklist::ChecklistStatus::Failed,
                    _ => crate::components::task_checklist::ChecklistStatus::Pending,
                };
                self.task_checklist.update(&task_id, checklist_status);
                // Drive the activity spinner from the active step, like Claude
                // Code's activeForm. Clears automatically when nothing is in
                // progress (current_active_form -> None).
                let verb = self.task_checklist.current_active_form();
                self.activity.set_active_verb(verb);
            }
            BackendEvent::TaskChecklistShow { tasks } => {
                self.task_checklist.clear();
                for task in tasks {
                    let status = match task.status.as_str() {
                        "completed" => crate::components::task_checklist::ChecklistStatus::Completed,
                        "in_progress" => crate::components::task_checklist::ChecklistStatus::InProgress,
                        "failed" => crate::components::task_checklist::ChecklistStatus::Failed,
                        _ => crate::components::task_checklist::ChecklistStatus::Pending,
                    };
                    let id = task.id.clone();
                    self.task_checklist.add(task.id, task.subject, task.active_form);
                    self.task_checklist.update(&id, status);
                }
                self.task_checklist.show();
                self.activity.set_active_verb(self.task_checklist.current_active_form());
                self.recompute_layout();
            }
            BackendEvent::TaskChecklistHide => {
                self.task_checklist.hide();
                self.activity.set_active_verb(None);
                self.recompute_layout();
            }
            BackendEvent::CommandsLoaded(result) => {
                // Merge the backend registry with the TUI-native commands (/steer,
                // /bg, /fg, /agents, /version) so they always surface in the Ctrl+K
                // palette and the inline `/` completions — even if the backend
                // registry doesn't list them, or the fetch failed (offline).
                let mut commands = match result {
                    Ok(commands) => commands,
                    Err(e) => {
                        warn!("Failed to load commands, using TUI-native set: {}", e);
                        Vec::new()
                    }
                };
                merge_tui_native_commands(&mut commands);
                self.command_entries = commands;
                // Rebuild the `/` completion popup, filtered to capability-available
                // commands and carrying the category so user-defined "custom"
                // commands (~/.osa/commands/*.md) stay tagged distinctly.
                self.refresh_command_completions();
            }
            BackendEvent::ToolsLoaded(result) => match result {
                Ok(tools) => {
                    self.header.set_tool_count(tools.len());
                    // Refresh the capability-gate: commands whose required tools are
                    // now present become visible; those still missing stay hidden.
                    self.available_tools =
                        tools.iter().map(|t| t.name.clone()).collect();
                    self.refresh_command_completions();
                    self.sidebar.set_tool_count(tools.len());
                    self.chat.set_welcome_info(
                        self.header.provider(),
                        self.header.model_name(),
                        tools.len(),
                    );

                    // Emit the OSA welcome BANNER (bordered box + ASCII logo) into
                    // the terminal scrollback once, after tools load so the count
                    // is accurate. The event loop renders it via insert_before.
                    if !self.welcome_injected && !self.chat.has_messages {
                        self.welcome_injected = true;
                        self.pending_welcome_banner = Some((
                            tools.len(),
                            Some(self.header.provider().to_string()),
                            Some(self.header.model_name().to_string()),
                        ));
                    }
                }
                Err(e) => warn!("Failed to load tools: {}", e),
            },
            BackendEvent::OrchestrateResult(result) => match result {
                Ok(resp) => {
                    debug!(
                        "Orchestrate response: session={}, status={}",
                        resp.session_id, resp.status
                    );
                    // Don't transition to Idle here. The HTTP response is just an
                    // acknowledgment — SSE events (StreamingToken, AgentResponse)
                    // drive the actual processing lifecycle. AgentResponse already
                    // handles Processing→Idle when the backend is truly done.
                }
                Err(e) => {
                    error!("Orchestrate failed: {}", e);
                    self.toasts.push(
                        format!("Error: {}", e),
                        crate::components::toast::ToastLevel::Error,
                    );
                    if self.state.is_processing() {
                        self.transition(AppState::Idle);
                        self.activity.stop();
                    }
                    // The current turn errored out — don't let queued messages
                    // get stuck; drain the next one if we're back at Idle.
                    self.maybe_dequeue_message();
                }
            },
            BackendEvent::CommandResult(result) => {
                self.handle_command_result(result);
            }
            BackendEvent::ModelSwitched(result) => match result {
                Ok(resp) => {
                    self.header.set_provider_info(&resp.provider, &resp.model);
                    self.status.set_provider_info(&resp.provider, &resp.model);
                    self.sidebar.set_provider_info(&resp.provider, &resp.model);
                    self.chat.set_welcome_info(
                        &resp.provider,
                        &resp.model,
                        self.header.tool_count(),
                    );
                    // Reset context bar with new model's window size
                    if let Some(ctx) = resp.context_window {
                        self.status.set_context(0.0, 0, ctx);
                    }
                    self.toasts.push(
                        format!("Model: {}/{}", resp.provider, resp.model),
                        crate::components::toast::ToastLevel::Info,
                    );
                }
                Err(e) => {
                    self.toasts.push(
                        format!("Model switch failed: {}", e),
                        crate::components::toast::ToastLevel::Error,
                    );
                }
            },
            BackendEvent::SessionCreated(result) => match result {
                Ok(resp) => {
                    let resumed = resp.status.as_deref() == Some("resumed");
                    self.session_id = resp.id.clone();
                    self.chat.clear();
                    self.tasks.clear();
                    self.stream_buf.clear();
                    self.thinking_buf.clear();
                    self.agent_header_sent = false;

                    // The session id just changed — reconnect the SSE stream to it,
                    // otherwise responses stream to the new session while the TUI is
                    // still listening on the old one ("waiting for response" forever).
                    self.start_sse();

                    if resumed {
                        // Folder already had a conversation — pull its history back in
                        // so the user sees where they left off (Claude Code style).
                        let client = self.client.clone();
                        let tx = self.event_tx.clone();
                        let sid = resp.id.clone();
                        tokio::spawn(async move {
                            let ev = match client.get_session_messages(&sid).await {
                                Ok(messages) => BackendEvent::SessionMessages(Ok(messages)),
                                Err(e) => BackendEvent::SessionMessages(Err(e.to_string())),
                            };
                            let _ = tx.send(crate::event::Event::Backend(ev));
                        });
                        self.toasts.push(
                            "Resumed this folder's conversation".into(),
                            crate::components::toast::ToastLevel::Info,
                        );
                    } else {
                        self.toasts.push(
                            "New session".into(),
                            crate::components::toast::ToastLevel::Info,
                        );
                    }
                }
                Err(e) => {
                    self.toasts.push(
                        format!("Session create failed: {}", e),
                        crate::components::toast::ToastLevel::Error,
                    );
                }
            },
            // === Models/Sessions loaded (dialog triggers) ===
            // ModelsLoaded is legacy (the flat model list). The picker is now
            // provider-first and opens via ProviderPickerData; this arm is kept
            // only to remain exhaustive over the event enum.
            BackendEvent::ModelsLoaded(_result) => {}

            // === Provider-first picker: catalog + detection loaded ===
            BackendEvent::ProviderPickerData(result) => match result {
                Ok(resp) => {
                    let current_provider = self.header.provider().to_string();
                    let current_model = self.header.model_name().to_string();
                    let picker =
                        crate::dialogs::model_picker::ModelPicker::new_provider_first(
                            resp.providers,
                            resp.detected,
                            current_provider,
                            current_model,
                        );
                    self.model_picker = Some(picker);
                    self.enter_overlay(AppState::ModelPicker);
                }
                Err(e) => {
                    self.toasts.push(
                        format!("Failed to load providers: {}", e),
                        crate::components::toast::ToastLevel::Error,
                    );
                }
            },

            // === Provider-first picker: candidate key verified ===
            BackendEvent::ModelPickerKeyVerified(result) => {
                if let Some(picker) = self.model_picker.as_mut() {
                    match result {
                        Ok(r) if r.status == "ok" => {
                            picker.set_verify_success(r.latency_ms.unwrap_or(0));
                        }
                        Ok(r) => {
                            // Distinguish a bad key from a network/API error by
                            // branching on the JSON error code (HTTP is always 200).
                            let reason = r
                                .message
                                .clone()
                                .or_else(|| r.error.clone())
                                .unwrap_or_else(|| "Unknown error".into());
                            match r.error.as_deref() {
                                Some("unauthorized")
                                | Some("forbidden")
                                | Some("insufficient_credits") => {
                                    picker.set_verify_failed(reason);
                                }
                                _ => picker.set_verify_error(reason),
                            }
                        }
                        Err(e) => picker.set_verify_error(e),
                    }
                }
            }

            // === Provider-first picker: dynamic model list loaded ===
            BackendEvent::ProviderModelsLoaded(result) => {
                if let Some(picker) = self.model_picker.as_mut() {
                    match result {
                        Ok(resp) => picker.set_provider_models(resp.models),
                        Err(e) => {
                            self.toasts.push(
                                format!("Failed to load models: {}", e),
                                crate::components::toast::ToastLevel::Error,
                            );
                        }
                    }
                }
            }
            BackendEvent::SessionsLoaded(result) => match result {
                Ok(sessions) => {
                    let browser = crate::dialogs::sessions::SessionBrowser::new(
                        sessions,
                        self.session_id.clone(),
                    );
                    self.session_browser = Some(browser);
                    self.enter_overlay(AppState::Sessions);
                }
                Err(e) => {
                    self.toasts.push(
                        format!("Failed to load sessions: {}", e),
                        crate::components::toast::ToastLevel::Error,
                    );
                }
            },

            BackendEvent::RewindCheckpointsLoaded(result) => match result {
                Ok(checkpoints) => {
                    if checkpoints.is_empty() {
                        self.toasts.push(
                            "No rewind checkpoints yet".into(),
                            crate::components::toast::ToastLevel::Info,
                        );
                    } else {
                        self.rewind_dialog =
                            Some(crate::dialogs::rewind::RewindDialog::new(checkpoints));
                        self.enter_overlay(AppState::Rewind);
                    }
                }
                Err(e) => {
                    self.toasts.push(
                        format!("Failed to load checkpoints: {}", e),
                        crate::components::toast::ToastLevel::Error,
                    );
                }
            },

            BackendEvent::RewindRestored(result) => match result {
                Ok(resp) => {
                    let detail = match resp.message_count {
                        Some(n) => format!("Rewound ({}, {} messages)", resp.scope, n),
                        None => format!("Rewound ({})", resp.scope),
                    };
                    self.toasts
                        .push(detail, crate::components::toast::ToastLevel::Info);
                }
                Err(e) => {
                    self.toasts.push(
                        format!("Rewind failed: {}", e),
                        crate::components::toast::ToastLevel::Error,
                    );
                }
            },

            // === Orchestrator events → Agents component ===
            BackendEvent::OrchestratorTaskStarted { task_id } => {
                self.agents.task_started(&task_id);
                self.recompute_layout();
            }
            BackendEvent::OrchestratorAgentsSpawning { agents, .. } => {
                self.agents.on_agents_spawning(&agents);
                self.recompute_layout();
            }
            BackendEvent::OrchestratorTaskAppraised { estimated_cost_usd, .. } => {
                // Record the task-level cost estimate so the agents dashboard can
                // surface it. There is no per-agent cost signal from the backend,
                // so this whole-task figure is the only cost we can honestly show.
                if estimated_cost_usd > 0.0 {
                    self.agents.set_estimated_cost(estimated_cost_usd);
                }
            }
            BackendEvent::OrchestratorAgentStarted { agent_name, role, model, subject, batch_id } => {
                self.agents.agent_started(&agent_name, &role, &model, &subject, batch_id);
                let display = if role.is_empty() { agent_name.clone() } else { format!("{}/{}", agent_name, role) };
                self.sidebar.set_current_agent(display);
                self.recompute_layout();
            }
            BackendEvent::OrchestratorAgentProgress { agent_name, current_action, tool_uses, tokens_used, subject, recent_actions } => {
                self.agents.agent_progress(&agent_name, &current_action, tool_uses, tokens_used, &subject, recent_actions);
                // Trail length can change the panel height — keep layout in sync.
                self.recompute_layout();
            }
            BackendEvent::OrchestratorAgentCompleted { agent_name, tool_uses, tokens_used, .. } => {
                self.agents.agent_completed(&agent_name, tool_uses, tokens_used);
                self.sidebar.set_current_agent("");
            }
            BackendEvent::OrchestratorAgentFailed { agent_name, error, tool_uses, tokens_used } => {
                self.agents.agent_failed(&agent_name, &error, tool_uses, tokens_used);
                self.sidebar.set_current_agent("");
            }
            BackendEvent::OrchestratorWaveStarted { wave_number, total_waves } => {
                self.agents.wave_started(wave_number, total_waves);
                self.recompute_layout();
            }
            BackendEvent::OrchestratorSynthesizing { agent_count } => {
                self.agents.on_synthesizing(agent_count);
                self.recompute_layout();
            }
            BackendEvent::OrchestratorTaskCompleted { .. } => {
                self.agents.task_completed();
                self.recompute_layout();
            }

            // === Swarm events → Agents component ===
            BackendEvent::SwarmStarted { swarm_id, pattern, agent_count, .. } => {
                self.agents.swarm_started(&swarm_id, &pattern, agent_count);
                self.recompute_layout();
            }
            BackendEvent::SwarmCompleted { swarm_id, .. } => {
                self.agents.swarm_completed(&swarm_id);
                self.recompute_layout();
            }
            BackendEvent::SwarmFailed { swarm_id, reason } => {
                self.agents.swarm_failed(&swarm_id, &reason);
                self.recompute_layout();
            }
            BackendEvent::SwarmCancelled { swarm_id } => {
                self.agents.swarm_failed(&swarm_id, "cancelled");
                self.recompute_layout();
            }
            BackendEvent::SwarmTimeout { swarm_id } => {
                self.agents.swarm_failed(&swarm_id, "timeout");
                self.recompute_layout();
            }

            // === Nested subagent transcript (dashboard "view" / Ctrl+O) ===
            BackendEvent::AgentTranscript(result) => match result {
                Ok((agent_id, transcript)) => {
                    let entries = vec![
                        crate::dialogs::transcript_viewer::TranscriptEntry {
                            role: crate::dialogs::transcript_viewer::TranscriptRole::System,
                            text: format!("Agent transcript — {}", agent_id),
                        },
                        crate::dialogs::transcript_viewer::TranscriptEntry {
                            role: crate::dialogs::transcript_viewer::TranscriptRole::Agent,
                            text: transcript,
                        },
                    ];
                    self.transcript =
                        Some(crate::dialogs::transcript_viewer::TranscriptViewer::open(&entries));
                    self.transcript_override = Some(entries);
                }
                Err(e) => {
                    self.toasts.push(
                        format!("Transcript unavailable: {}", e),
                        crate::components::toast::ToastLevel::Warning,
                    );
                }
            },

            // === Background agents (fire-and-forget subagents) ===
            // Reuse the Agents panel: the background agent's id is its stable
            // entry key, so completion/failure updates the same row. A toast
            // announces the lifecycle transition, and completion/failure also
            // drop a short system note into chat with the result/error preview.
            BackendEvent::BackgroundAgentStarted { agent_id, role } => {
                let label = if role.is_empty() { "background".to_string() } else { role.clone() };
                self.agents.agent_started(
                    agent_id.clone(),
                    role,
                    "",
                    format!("background: {}", label),
                    Some("background".to_string()),
                );
                self.toasts.push(
                    format!("Background agent \"{}\" started", label),
                    crate::components::toast::ToastLevel::Info,
                );
                self.recompute_layout();
            }
            BackendEvent::BackgroundAgentCompleted { agent_id, role, result, duration_ms } => {
                let label = if role.is_empty() { "background".to_string() } else { role };
                self.agents.agent_completed(&agent_id, 0, 0);
                let preview: String = result.trim().chars().take(200).collect();
                // Format duration as h/m/s (shared formatter) so a 2h33m run reads
                // "2h33m", not "9180.0s". Styled as a teammate-finished line.
                let elapsed = crate::util::fmt_elapsed(duration_ms / 1000);
                let note = if preview.is_empty() {
                    format!("\u{23fa} Teammate @{} finished \u{00b7} {}", label, elapsed)
                } else {
                    format!("\u{23fa} Teammate @{} finished \u{00b7} {} \u{2014} {}", label, elapsed, preview)
                };
                self.chat.add_system_message(&note, "info");
                self.toasts.push(
                    format!("Background agent \"{}\" completed", label),
                    crate::components::toast::ToastLevel::Success,
                );
                self.refresh_bg_indicators();
                self.recompute_layout();
            }
            BackendEvent::BackgroundAgentFailed { agent_id, role, error, duration_ms } => {
                let label = if role.is_empty() { "background".to_string() } else { role };
                self.agents.agent_failed(&agent_id, error.clone(), 0, 0);
                let preview: String = error.trim().chars().take(200).collect();
                let elapsed = crate::util::fmt_elapsed(duration_ms / 1000);
                self.chat.add_system_message(
                    &format!("\u{23fa} Teammate @{} failed \u{00b7} {} \u{2014} {}", label, elapsed, preview),
                    "error",
                );
                self.toasts.push(
                    format!("Background agent \"{}\" failed", label),
                    crate::components::toast::ToastLevel::Error,
                );
                self.refresh_bg_indicators();
                self.recompute_layout();
            }

            // === Multi-agent workflow (Claude Code parity) ===
            // Teammate/sub-agent lifecycle + inbound messages + background-command
            // completion + turn recap, decoded from the session SSE stream.
            BackendEvent::AgentFinished { display_name, duration_ms, .. } => {
                let name = if display_name.is_empty() {
                    "agent".to_string()
                } else {
                    display_name
                };
                self.chat.add_system_message(
                    &format!(
                        "\u{23fa} Teammate @{} finished \u{00b7} {}",
                        name,
                        crate::util::fmt_elapsed(duration_ms / 1000)
                    ),
                    "info",
                );
                self.recompute_layout();
            }
            BackendEvent::AgentMessage { from, text } => {
                let who = if from.is_empty() { "agent".to_string() } else { from };
                self.chat
                    .add_system_message(&format!("\u{203a} Message from @{}: {}", who, text), "info");
                self.recompute_layout();
            }
            BackendEvent::BackgroundCommandCompleted { exit_code, command, task_id } => {
                if self.bg_shell_count > 0 {
                    self.bg_shell_count -= 1;
                }
                self.refresh_bg_indicators();
                // The backend labels the job by id (`background_id`); fall back to
                // it when the command text is empty so the toast is never a blank
                // `''` — it always identifies which background command finished.
                let label = if command.trim().is_empty() {
                    task_id.clone()
                } else {
                    command.clone()
                };
                let note =
                    format!("Background command '{}' completed (exit code {})", label, exit_code);
                let (severity, level) = if exit_code == 0 {
                    ("info", crate::components::toast::ToastLevel::Success)
                } else {
                    ("error", crate::components::toast::ToastLevel::Error)
                };
                self.chat.add_system_message(&note, severity);
                self.toasts.push(note, level);
                self.recompute_layout();
            }
            BackendEvent::TaskNotification { count, summary } => {
                // WS6: the backend just folded completed background task(s) into
                // the agent's context — show why the agent is about to pivot.
                let note = if summary.trim().is_empty() {
                    format!("\u{2699} Reacting to {} completed background task(s)", count)
                } else {
                    format!(
                        "\u{2699} Reacting to {} completed background task(s) \u{2014} {}",
                        count, summary
                    )
                };
                self.chat.add_system_message(&note, "info");
                self.recompute_layout();
            }
            BackendEvent::ShellDetached(result) => {
                match result {
                    Ok(background_id) => {
                        // The command is now a live background terminal. Count it
                        // here (its foreground tool-call was never counted as bg);
                        // the later `background_command_completed` event will
                        // decrement the count and raise the completion toast.
                        self.bg_shell_count += 1;
                        self.refresh_bg_indicators();
                        let label = if background_id.trim().is_empty() {
                            "command".to_string()
                        } else {
                            background_id
                        };
                        self.toasts.push(
                            format!("Moved to background ({}) \u{00b7} /bg to list", label),
                            crate::components::toast::ToastLevel::Success,
                        );
                        self.announce_a11y("command moved to background");
                    }
                    Err(_) => {
                        // Nothing to detach — the command almost certainly finished
                        // between the keypress and the request; its result lands in
                        // scrollback through the normal path.
                        self.toasts.push(
                            "Nothing to move to background — the command already finished".into(),
                            crate::components::toast::ToastLevel::Info,
                        );
                    }
                }
                self.recompute_layout();
            }
            BackendEvent::TurnRecap { elapsed_ms, tool_calls, tools_used } => {
                // Only surface the recap when the turn did substantive, user-visible
                // work — a real tool ran (shell/file/web/dir/git/…) OR the turn took
                // a noticeable amount of wall-clock time. `tool_calls` is the
                // server's PER-TURN substantive tool-USE count (internal
                // bookkeeping like memory_save / memory_recall / session_search
                // is filtered server-side, and calls are counted per use, not
                // per distinct tool name). The name-list fallback covers legacy
                // servers that don't send tool_calls; substantive_tool_count
                // re-filters it as defense-in-depth.
                let tool_count = if tool_calls > 0 {
                    tool_calls as usize
                } else {
                    crate::util::substantive_tool_count(&tools_used)
                };
                // Elapsed: prefer the CLIENT clock the live spinner rendered
                // from (snapshotted at the agent_response turn-end edge), so
                // the recap equals the last spinner value and can never jump
                // backwards — the server clock starts later, after the request
                // round-trip. Server elapsed_ms is only the fallback (e.g. a
                // recap arriving after an SSE reconnect with no live timer).
                let elapsed_secs = self
                    .last_turn_client_elapsed_secs
                    .take()
                    .unwrap_or(elapsed_ms / 1000);
                if tool_count > 0 || elapsed_secs >= crate::util::RECAP_ELAPSED_THRESHOLD_SECS {
                    let mut text =
                        format!("\u{273b} Worked for {}", crate::util::fmt_elapsed(elapsed_secs));
                    if tool_count > 0 {
                        text.push_str(&format!(
                            " \u{00b7} {} tool use{}",
                            tool_count,
                            if tool_count == 1 { "" } else { "s" }
                        ));
                    }
                    // Render as a single, height-1 line snug under the message. The
                    // system-message carrier floors height at 2 rows (message.rs),
                    // which left an orphan blank line under the recap; the collapsed
                    // tool-summary carrier is exactly one row, so no empty gap.
                    let line = ratatui::text::Line::from(ratatui::text::Span::styled(
                        text,
                        crate::style::theme().faint(),
                    ));
                    self.chat.add_collapsed_tool_summary(line);
                    self.recompute_layout();
                }
            }

            BackendEvent::SseAuthFailed => {
                error!("SSE auth failed — attempting token refresh");
                let client = self.client.clone();
                let tx = self.event_tx.clone();
                tokio::spawn(async move {
                    if client.try_refresh_token().await {
                        // Signal the app to restart SSE with refreshed token
                        let _ = tx.send(crate::event::Event::Backend(BackendEvent::SseDisconnected {
                            error: Some("token_refreshed".into()),
                        }));
                    } else {
                        // Refresh failed — tell user to login manually
                        let _ = tx.send(crate::event::Event::Backend(BackendEvent::SseDisconnected {
                            error: Some("auth_failed".into()),
                        }));
                    }
                });
            }
            BackendEvent::ParseWarning { message } => {
                warn!("SSE parse warning: {}", message);
            }
            BackendEvent::AutoModePaused { blocked_count, message } => {
                // The auto-mode guardian paused for human review. Surface a clear
                // status note telling the user how many dangerous actions were
                // blocked and how to proceed (/resume or approve).
                let note = if message.is_empty() {
                    let n = blocked_count.max(1);
                    let plural = if n == 1 { "action" } else { "actions" };
                    format!(
                        "auto-mode paused: {} dangerous {} blocked — /resume or approve",
                        n, plural
                    )
                } else {
                    format!("auto-mode paused: {} — /resume or approve", message)
                };
                self.chat.add_system_message(&note, "warning");
                self.toasts.push(
                    note,
                    crate::components::toast::ToastLevel::Warning,
                );
            }
            BackendEvent::HookBlocked { hook_name, reason } => {
                self.toasts.push(
                    format!("Blocked by {}: {}", hook_name, reason),
                    crate::components::toast::ToastLevel::Warning,
                );
            }
            BackendEvent::BudgetWarning { utilization, message } => {
                self.toasts.push(
                    format!("Budget {}%: {}", (utilization * 100.0) as u32, message),
                    crate::components::toast::ToastLevel::Warning,
                );
            }
            BackendEvent::BudgetExceeded { message } => {
                self.toasts.push(
                    format!("Budget exceeded: {}", message),
                    crate::components::toast::ToastLevel::Error,
                );
            }
            BackendEvent::ProviderRetry { attempt, max_attempts, delay_ms, reason } => {
                // Surface "Retrying in Ns…" so a mid-turn network drop is
                // visible instead of a silent stall (WS1 item 8).
                let secs = ((delay_ms + 999) / 1000).max(1);
                let note = if reason.is_empty() {
                    format!("Retrying in {}s\u{2026} (attempt {}/{})", secs, attempt, max_attempts)
                } else {
                    format!(
                        "Retrying in {}s\u{2026} (attempt {}/{}) \u{2014} {}",
                        secs, attempt, max_attempts, reason
                    )
                };
                self.chat.add_system_message(&note, "warning");
            }
            BackendEvent::TurnError { kind, reason } => {
                // Red error line for turn-fatal failures (llm_error /
                // context_overflow) — SystemError renders in the error style.
                let note = if reason.is_empty() {
                    format!("Error: {}", kind)
                } else {
                    format!("Error ({}): {}", kind, reason)
                };
                self.chat.add_system_message(&note, "error");
            }
            BackendEvent::OnboardingStatus(result) => match result {
                Ok(resp) => {
                    if resp.needs_onboarding {
                        info!("Onboarding needed — showing setup wizard");
                        let data = crate::dialogs::onboarding::OnboardingData {
                            providers: resp.providers,
                            system_info: resp.system_info,
                        };
                        self.onboarding = Some(
                            crate::dialogs::onboarding::OnboardingWizard::new(data),
                        );
                        if self.state.can_transition_to(AppState::Onboarding) {
                            self.enter_overlay(AppState::Onboarding);
                        }
                    } else {
                        // Onboarded. Two things, both Claude-Code-style:
                        // 1. needs_bootstrap: the agent hasn't learned the user yet — do
                        //    NOT auto-send a greeting or delete anything. Just show the
                        //    banner and wait. The backend injects "get to know the user"
                        //    context only while USER.md has no name, so it learns naturally
                        //    in the first real conversation, then stops on its own.
                        if resp.needs_bootstrap {
                            info!("Bootstrap pending — banner, waiting for first prompt");
                        }
                        // 2. Resolve THIS folder's session once: resume the folder's prior
                        //    conversation if it has one, else stay on a fresh blank session.
                        if !self.dir_session_resolved {
                            self.dir_session_resolved = true;
                            // Honour launch flags: --continue resumes this folder's
                            // newest session; --resume <id> loads that session;
                            // --resume (no id) opens the session browser; otherwise
                            // start fresh.
                            if self.startup_continue {
                                self.continue_session();
                            } else if let Some(resume) = self.startup_resume.take() {
                                match resume {
                                    Some(id) => self.switch_session(&id),
                                    None => {
                                        self.create_session();
                                        self.load_recent_sessions();
                                    }
                                }
                            } else {
                                self.create_session();
                            }
                        }
                    }
                }
                Err(e) => {
                    debug!("Onboarding check failed: {}", e);
                }
            },

            // === Session messages (history load) ===
            BackendEvent::SessionMessages(result) => match result {
                Ok(messages) => {
                    for msg in &messages {
                        match msg.role.as_str() {
                            "user" => self.chat.add_user_message(&msg.content),
                            "assistant" | "agent" => {
                                self.chat.add_agent_message(&msg.content, None);
                            }
                            "system" => {
                                self.chat.add_system_message(&msg.content, "info");
                            }
                            _ => {
                                self.chat.add_system_message(&msg.content, "info");
                            }
                        }
                    }
                    if !messages.is_empty() {
                        self.toasts.push(
                            format!("Loaded {} messages", messages.len()),
                            crate::components::toast::ToastLevel::Info,
                        );
                    }
                }
                Err(e) => {
                    debug!("Failed to load session messages: {}", e);
                }
            },

            // === Swarm Intelligence events ===
            BackendEvent::SwarmIntelligenceStarted { swarm_id, intelligence_type, .. } => {
                self.agents.swarm_started(&swarm_id, &intelligence_type, 0);
                self.toasts.push(
                    format!("SI started: {}", intelligence_type),
                    crate::components::toast::ToastLevel::Info,
                );
            }
            BackendEvent::SwarmIntelligenceRound { swarm_id, round } => {
                debug!("SI round {}: {}", round, swarm_id);
            }
            BackendEvent::SwarmIntelligenceConverged { round, .. } => {
                self.toasts.push(
                    format!("SI converged (round {})", round),
                    crate::components::toast::ToastLevel::Success,
                );
            }
            BackendEvent::SwarmIntelligenceCompleted { swarm_id, .. } => {
                self.agents.swarm_completed(&swarm_id);
                self.recompute_layout();
            }

            // === Phase 2+ HTTP Response Results ===
            BackendEvent::SkillsLoaded(result) => match result {
                Ok(skills) => {
                    debug!("Skills loaded: {} skills", skills.len());
                }
                Err(e) => {
                    self.toasts.push(
                        format!("Failed to load skills: {}", e),
                        crate::components::toast::ToastLevel::Error,
                    );
                }
            },
            BackendEvent::SkillCreated(result) => match result {
                Ok(_resp) => {
                    self.toasts.push(
                        "Skill created".into(),
                        crate::components::toast::ToastLevel::Success,
                    );
                }
                Err(e) => {
                    self.toasts.push(
                        format!("Skill creation failed: {}", e),
                        crate::components::toast::ToastLevel::Error,
                    );
                }
            },
            BackendEvent::ClassifyResult(result) => match result {
                Ok(resp) => {
                    self.status.set_signal(resp.signal.clone());
                    self.sidebar.set_signal_info(&resp.signal.mode, &resp.signal.genre);
                }
                Err(e) => {
                    self.toasts.push(
                        format!("Classification failed: {}", e),
                        crate::components::toast::ToastLevel::Error,
                    );
                }
            },
            BackendEvent::ComplexTaskResult(result) => match result {
                Ok(resp) => {
                    if let Some(synthesis) = &resp.synthesis {
                        self.chat.add_agent_message(synthesis, None);
                    }
                    if self.state.is_processing() {
                        self.activity.stop();
                        self.status.set_active(false);
                        self.transition(AppState::Idle);
                    }
                }
                Err(e) => {
                    self.toasts.push(
                        format!("Complex task failed: {}", e),
                        crate::components::toast::ToastLevel::Error,
                    );
                    if self.state.is_processing() {
                        self.activity.stop();
                        self.status.set_active(false);
                        self.transition(AppState::Idle);
                    }
                }
            },
            BackendEvent::TaskProgressResult(result) => match result {
                Ok(progress) => {
                    debug!("Task progress: {} status={}", progress.task_id, progress.status);
                    self.tasks.update(&progress.task_id, &progress.status);
                }
                Err(e) => {
                    self.toasts.push(
                        format!("Task progress failed: {}", e),
                        crate::components::toast::ToastLevel::Error,
                    );
                }
            },
            BackendEvent::TasksLoaded(result) => match result {
                Ok(tasks) => {
                    self.tasks.clear();
                    for t in &tasks {
                        self.tasks.add(
                            t.task_id.clone(),
                            t.task.clone(),
                            String::new(),
                        );
                        if t.status != "pending" {
                            self.tasks.update(&t.task_id, &t.status);
                        }
                    }
                    self.recompute_layout();
                }
                Err(e) => {
                    self.toasts.push(
                        format!("Failed to load tasks: {}", e),
                        crate::components::toast::ToastLevel::Error,
                    );
                }
            },
            BackendEvent::SwarmLaunched(result) => match result {
                Ok(resp) => {
                    self.toasts.push(
                        format!("Swarm launched: {}", resp.pattern),
                        crate::components::toast::ToastLevel::Success,
                    );
                }
                Err(e) => {
                    self.toasts.push(
                        format!("Swarm launch failed: {}", e),
                        crate::components::toast::ToastLevel::Error,
                    );
                }
            },
            BackendEvent::SwarmsLoaded(result) => match result {
                Ok(resp) => {
                    let msg = format!("{} swarms ({} active)", resp.count, resp.active_count);
                    self.chat.add_system_message(&msg, "info");
                }
                Err(e) => {
                    self.toasts.push(
                        format!("Failed to load swarms: {}", e),
                        crate::components::toast::ToastLevel::Error,
                    );
                }
            },
            BackendEvent::SwarmStatusResult(result) => match result {
                Ok(status) => {
                    let msg = format!("Swarm {} [{}]: {}", status.id, status.pattern, status.status);
                    self.chat.add_system_message(&msg, "info");
                }
                Err(e) => {
                    self.toasts.push(
                        format!("Swarm status failed: {}", e),
                        crate::components::toast::ToastLevel::Error,
                    );
                }
            },
            BackendEvent::SwarmCancelResult(result) => match result {
                Ok(()) => {
                    self.toasts.push(
                        "Swarm cancelled".into(),
                        crate::components::toast::ToastLevel::Info,
                    );
                }
                Err(e) => {
                    self.toasts.push(
                        format!("Swarm cancel failed: {}", e),
                        crate::components::toast::ToastLevel::Error,
                    );
                }
            },
            BackendEvent::MemorySaved(result) => match result {
                Ok(_resp) => {
                    self.toasts.push(
                        "Memory saved".into(),
                        crate::components::toast::ToastLevel::Success,
                    );
                }
                Err(e) => {
                    self.toasts.push(
                        format!("Memory save failed: {}", e),
                        crate::components::toast::ToastLevel::Error,
                    );
                }
            },
            BackendEvent::MemoryRecalled(result) => match result {
                Ok(resp) => {
                    self.chat.add_system_message(&resp.content, "info");
                }
                Err(e) => {
                    self.toasts.push(
                        format!("Memory recall failed: {}", e),
                        crate::components::toast::ToastLevel::Error,
                    );
                }
            },
            BackendEvent::AnalyticsResult(result) => match result {
                Ok(resp) => {
                    let parts: Vec<String> = [
                        ("sessions", resp.sessions.len()),
                        ("budget", resp.budget.len()),
                        ("learning", resp.learning.len()),
                        ("hooks", resp.hooks.len()),
                        ("compactor", resp.compactor.len()),
                    ]
                    .iter()
                    .filter(|(_, n)| *n > 0)
                    .map(|(k, n)| format!("{}: {} entries", k, n))
                    .collect();
                    let msg = if parts.is_empty() {
                        "No analytics data".into()
                    } else {
                        parts.join(" | ")
                    };
                    self.chat.add_system_message(&msg, "info");
                }
                Err(e) => {
                    self.toasts.push(
                        format!("Analytics failed: {}", e),
                        crate::components::toast::ToastLevel::Error,
                    );
                }
            },
            BackendEvent::SchedulerJobs(result) => match result {
                Ok(jobs) => {
                    let msg = format!("{} scheduled jobs", jobs.len());
                    self.chat.add_system_message(&msg, "info");
                }
                Err(e) => {
                    self.toasts.push(
                        format!("Failed to load scheduler jobs: {}", e),
                        crate::components::toast::ToastLevel::Error,
                    );
                }
            },
            BackendEvent::SchedulerReloaded(result) => match result {
                Ok(()) => {
                    self.toasts.push(
                        "Scheduler reloaded".into(),
                        crate::components::toast::ToastLevel::Info,
                    );
                }
                Err(e) => {
                    self.toasts.push(
                        format!("Scheduler reload failed: {}", e),
                        crate::components::toast::ToastLevel::Error,
                    );
                }
            },
            BackendEvent::MachinesLoaded(result) => match result {
                Ok(machines) => {
                    let msg = format!("{} machines connected", machines.len());
                    self.chat.add_system_message(&msg, "info");
                }
                Err(e) => {
                    self.toasts.push(
                        format!("Failed to load machines: {}", e),
                        crate::components::toast::ToastLevel::Error,
                    );
                }
            },
            BackendEvent::OnboardingComplete(result) => match result {
                Ok(resp) => {
                    self.toasts.push(
                        "Setup complete!".into(),
                        crate::components::toast::ToastLevel::Success,
                    );
                    let prov = resp.provider.as_deref().unwrap_or("configured");
                    let mdl = resp.model.as_deref().unwrap_or("default");
                    self.header.set_provider_info(prov, mdl);
                    self.status.set_provider_info(prov, mdl);
                    self.sidebar.set_provider_info(prov, mdl);
                    self.onboarding = None;
                    if self.state == AppState::Onboarding {
                        self.discard_overlay_return();
                        self.transition(AppState::Idle);
                    }

                    // Auto-send bootstrap message — agent speaks first
                    // This kicks off the BOOTSTRAP.md identity ritual
                    self.submit_prompt("Hey, I just set you up. What's good?");
                }
                Err(e) => {
                    self.toasts.push(
                        format!("Onboarding failed: {}", e),
                        crate::components::toast::ToastLevel::Error,
                    );
                }
            },
            BackendEvent::OnboardingHealthCheck(result) => {
                if let Some(ref mut wizard) = self.onboarding {
                    match result {
                        Ok(resp) => {
                            if resp.status == "ok" {
                                wizard.set_verify_success(resp.latency_ms.unwrap_or(0));
                            } else {
                                let msg = resp.message.unwrap_or_else(|| resp.error.unwrap_or_else(|| "Unknown error".into()));
                                wizard.set_verify_failed(msg);
                            }
                        }
                        Err(e) => {
                            wizard.set_verify_failed(format!("Request failed: {}", e));
                        }
                    }
                }
            }
            BackendEvent::PermissionRequired {
                tool,
                args,
                request_id,
                kind: _,
                old_content,
                new_content,
                warning,
                reason,
            } => {
                // Show the permission dialog — transition from Processing (or Idle) to Permissions.
                // Carry the backend-assigned request_id so the user's decision can
                // resume the exact parked tool call via POST /permissions/respond.
                let mut dialog = crate::dialogs::permissions::Permissions::new();
                dialog.set_tool(tool, args, request_id);
                if let (Some(old), Some(new)) = (old_content, new_content) {
                    dialog.set_diff(old, new);
                }
                dialog.set_meta(warning, reason);
                self.permissions = Some(dialog);
                if self.state.can_transition_to(AppState::Permissions) {
                    self.enter_overlay(AppState::Permissions);
                }
            }
            BackendEvent::PlanProposed { plan, request_id: _ } => {
                // Show the plan review dialog — backend paused for user approval.
                let mut review = crate::dialogs::plan_review::PlanReview::new();
                review.set_plan(plan);
                self.plan_review = Some(review);
                if self.state.can_transition_to(AppState::PlanReview) {
                    self.enter_overlay(AppState::PlanReview);
                }
            }
            BackendEvent::CancelTimeout => {
                // Safety net: if the backend cancel response never came via SSE,
                // force the UI back to idle so the user isn't stuck.
                if self.cancelled && self.state.is_processing() {
                    info!("Cancel timeout — forcing UI back to Idle");
                    self.chat.clear_streaming();
                    // Commit any completed-but-unflushed tool calls; drop the
                    // partial streaming text deliberately.
                    self.chat.flush_pending_tools();
                    self.flush_collapse();
                    self.stream_buf.clear();
                    self.thinking_buf.clear();
                    self.agent_header_sent = false;
                    self.activity.stop();
                    self.status.set_active(false);
                    self.agents.task_completed(); // Clear agents panel
                    self.cancelled = false;
                    self.transition(AppState::Idle);
                    self.recompute_layout();
                    self.toasts.push(
                        "Interrupted".into(),
                        crate::components::toast::ToastLevel::Warning,
                    );
                }
            },

            // Survey events
            BackendEvent::AskUserQuestion { survey_id, questions, skippable } => {
                use crate::dialogs::survey::{SurveyDialog, SurveyQuestion, SurveyOption};
                let qs: Vec<SurveyQuestion> = questions.into_iter().map(|q| {
                    SurveyQuestion {
                        text: q.text,
                        multi_select: q.multi_select,
                        options: q.options.into_iter().map(|o| SurveyOption {
                            label: o.label,
                            description: o.description,
                        }).collect(),
                        skippable: q.skippable,
                    }
                }).collect();
                self.survey = Some(SurveyDialog::new(survey_id, qs, skippable));
                if self.state.can_transition_to(AppState::Survey) {
                    self.enter_overlay(AppState::Survey);
                }
            }
            BackendEvent::SurveyAnswered { survey_id, summary } => {
                self.chat.add_survey_summary(survey_id, summary);
            }

            // === Proactive Mode ===
            BackendEvent::ProactiveMessage { message, message_type } => {
                let level = match message_type.as_str() {
                    "alert" | "work_failed" => crate::components::toast::ToastLevel::Warning,
                    "work_complete" => crate::components::toast::ToastLevel::Success,
                    _ => crate::components::toast::ToastLevel::Info,
                };
                // Show as a system message in chat with proactive badge
                let tagged = format!("[proactive] {}", message);
                self.chat.add_system_message(&tagged, &message_type);
                // Also toast for visibility
                let preview = if message.len() > 60 {
                    format!("{}...", crate::util::truncate_str(&message, 57))
                } else {
                    message
                };
                self.toasts.push(preview, level);
            }
            BackendEvent::ProactiveModeChanged { enabled } => {
                let msg = if enabled { "Proactive mode: ON" } else { "Proactive mode: OFF" };
                self.toasts.push(
                    msg.into(),
                    crate::components::toast::ToastLevel::Info,
                );
                self.sidebar.set_proactive(enabled);
            }
        }
        false
    }
}

/// Names OSA uses for a shell-command tool. The model may invoke any alias
/// (`bash`, `shell`, `shell_execute`, …); all map to the same background/detach
/// machinery, so foreground/background tracking must recognise every form.
fn is_shell_tool(name: &str) -> bool {
    matches!(
        name.to_ascii_lowercase().as_str(),
        "bash" | "shell" | "shell_execute" | "run_command" | "run_bash_command"
    )
}

/// True when a shell tool call's JSON args request background execution
/// (`run_in_background: true`). Mirrors the detection in `tools/bash.rs`.
fn is_run_in_background(args: &str) -> bool {
    serde_json::from_str::<serde_json::Value>(args)
        .ok()
        .and_then(|v| v.get("run_in_background").and_then(|b| b.as_bool()))
        .unwrap_or(false)
}

/// Write a completion ping to the terminal via the channel-selected notifier
/// (ghostty OSC 777 / kitty OSC 99 / OSC 9 fallback, tmux-wrapped, plus a BEL
/// for terminals with no notification support). Control sequences the terminal
/// consumes — never disturbs the ratatui render.
fn emit_completion_notification() {
    crate::components::notify::notify("OSA", "Response ready");
}

/// Commands the TUI handles locally (or wants surfaced) that must appear in the
/// Ctrl+K palette and inline `/` completions. Appended to whatever the backend
/// `GET /commands` returns, de-duplicated by name (the backend wins on a name
/// clash), so discoverability never depends on the backend knowing about a
/// TUI-only affordance. Names are slash-less — the completions layer prepends
/// the `/` — so they must NOT carry a leading `/` here (a leading slash produced
/// bogus `//steer` popup entries before).
impl App {
    /// Whether a command with these `required_tools` should be shown, given the
    /// tools available in the current session. Fail-open: an ungated command
    /// (empty list) always shows, and before the first ToolsLoaded arrives
    /// (`available_tools` empty) nothing is gated so `/` works immediately.
    pub(crate) fn command_capability_met(&self, required: &[String]) -> bool {
        required.is_empty()
            || self.available_tools.is_empty()
            || required.iter().all(|t| self.available_tools.contains(t))
    }

    /// Rebuild the inline `/` completion items from `command_entries`, filtered to
    /// only capability-available commands. Called whenever the command list OR the
    /// available-tool set changes, so the palette never lists a dead command.
    pub(crate) fn refresh_command_completions(&mut self) {
        let items: Vec<(String, String, Option<String>)> = self
            .command_entries
            .iter()
            .filter(|c| self.command_capability_met(&c.required_tools))
            .map(|c| (c.name.clone(), c.description.clone(), c.category.clone()))
            .collect();
        self.input.set_command_items(items);
    }
}

fn merge_tui_native_commands(commands: &mut Vec<crate::client::types::CommandEntry>) {
    use crate::client::types::CommandEntry;
    for &(name, desc) in crate::app::commands::BUILTIN_SLASH_COMMANDS {
        let already = commands
            .iter()
            .any(|c| c.name.eq_ignore_ascii_case(name));
        if !already {
            commands.push(CommandEntry {
                name: name.to_string(),
                description: desc.to_string(),
                category: Some("agent".to_string()),
                // TUI-native commands are handled locally and are always
                // available — no backend capability to gate on.
                required_tools: Vec::new(),
            });
        }
    }
}

/// Build the full built-in command set (every `BUILTIN_SLASH_COMMANDS` entry as
/// a `CommandEntry`), used to seed `command_entries` at App construction so the
/// Ctrl+K palette and `/help` are populated INSTANTLY — before, or entirely
/// without, the backend `GET /commands` response. Mirrors the inline `/`
/// completions seed (mod.rs, `set_commands_with_descriptions`). The
/// `CommandsLoaded` handler later REPLACES this seed with the richer backend
/// list (built-ins + api-only + ~/.osa/commands custom entries); if that fetch
/// fails or the backend never connects, `merge_tui_native_commands` still
/// guarantees the built-ins survive, so the palette is never empty.
pub(crate) fn builtin_command_entries() -> Vec<crate::client::types::CommandEntry> {
    let mut v = Vec::new();
    merge_tui_native_commands(&mut v);
    v
}
