use crate::app::state::AppState;
use crate::components::activity::ProcessingPhase;
use crate::event::backend::BackendEvent;
use tracing::{debug, error, info, warn};

use super::App;

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

    /// Emit a turn-complete notification when the terminal is UNFOCUSED (U-T11).
    /// Replaces the old last-keypress idle heuristic with the real DECSET-1004
    /// focus signal folded in by `focus::note_event`: a turn the user is actively
    /// watching (focused) never dings, while one finishing while they're away
    /// fires through the configured channel (bell / kitty / hooks). The channel
    /// itself honours the OSA_NO_NOTIFY opt-out (`NotificationConfig::from_env`
    /// sets the channel to `None`, so this becomes a no-op + user hooks only).
    pub(super) fn notify_turn_complete(&mut self) {
        if crate::notification::focus::is_unfocused() {
            crate::notification::on_turn_complete(&mut self.notify_cfg);
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
                // Reconcile the workspace name/title with the backend's real cwd.
                self.load_workspace_identity();
                // Re-assert the current permission mode to the (possibly
                // restarted) backend session. The mode is otherwise pushed ONLY
                // when the user changes it (cycle_permission_mode / enter_overdrive
                // / the config editor), so after a daemon restart the fresh session
                // reverts to its default gate while the status bar still shows
                // overdrive/accept-edits/plan — a security-adjacent lie about the
                // effective gate. Re-push mode + dangerous_mode so they survive the
                // restart, mirroring the same commands enter_overdrive sends.
                let mode = self.status.permission_mode();
                self.spawn_backend_command("permission_mode", mode.backend_token());
                let dangerous =
                    matches!(mode, crate::components::status_bar::PermissionMode::BypassPermissions);
                self.spawn_backend_command("dangerous_mode", if dangerous { "on" } else { "off" });
                // Coordinator state is backend-authoritative (sticky per-session
                // store), the opposite direction from permission mode. Query it on
                // (re)connect so the chip reflects a session that resumed with
                // coordinator on. The backend echoes a coordinator_mode event,
                // which drives the chip; "status" reads without mutating.
                self.spawn_backend_command("coordinator", "status");
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
                        // Auth failure is terminal (the client does NOT reconnect
                        // on AuthFailed), so a live turn would spin forever. End it
                        // cleanly before surfacing the error.
                        if self.turn_is_active() {
                            self.end_active_turn_on_disconnect();
                        }
                        self.toasts.push(
                            "SSE auth failed. Try /login to re-authenticate.".into(),
                            crate::components::toast::ToastLevel::Error,
                        );
                        self.sse_reconnecting = true;
                    }
                    Some("closed") => {
                        // Graceful/backend-initiated close (e.g. daemon restart).
                        // The in-flight turn's stream is gone — there is no
                        // Last-Event-ID replay — so end it cleanly instead of
                        // freezing the spinner forever, then re-attach a fresh
                        // stream for subsequent turns (the internal backoff loop
                        // handles a backend that is still coming back up).
                        info!("SSE stream closed by backend; re-attaching");
                        if self.turn_is_active() {
                            self.end_active_turn_on_disconnect();
                            self.toasts.push(
                                "Backend connection reset — turn ended. Reconnecting…".into(),
                                crate::components::toast::ToastLevel::Warning,
                            );
                        }
                        self.sse_reconnecting = true;
                        self.start_sse();
                    }
                    Some("cancelled") => {
                        // Client-initiated cancel (shutdown / session switch): no
                        // reconnect, no error, just clear any stale banner.
                        debug!("SSE cancelled by client");
                        self.sse_reconnecting = false;
                    }
                    Some("exhausted") => {
                        // Reconnect budget exhausted — honest terminal error.
                        // Stop the spinner, drop out of Processing, and tell the
                        // user how to recover rather than looping "Reconnecting…".
                        error!("SSE reconnect budget exhausted");
                        if self.turn_is_active() {
                            self.end_active_turn_on_disconnect();
                        }
                        self.sse_reconnecting = false;
                        self.toasts.push(
                            "Disconnected from backend. Restart OSA or run /login to reconnect."
                                .into(),
                            crate::components::toast::ToastLevel::Error,
                        );
                    }
                    Some(err) => {
                        // Unclassified disconnect. Never leave a live turn's
                        // spinner stuck: finalize it and tell the user, then let
                        // the internal backoff loop keep trying to re-attach.
                        warn!("SSE disconnected: {}", err);
                        if self.turn_is_active() {
                            self.end_active_turn_on_disconnect();
                            self.toasts.push(
                                "Backend disconnected — turn ended. Reconnecting…".into(),
                                crate::components::toast::ToastLevel::Warning,
                            );
                        }
                        self.sse_reconnecting = true;
                    }
                    None => {
                        // Silent disconnect (no reason). Same rule: finalize a
                        // live turn rather than freezing the spinner with no toast.
                        warn!("SSE disconnected (no reason given)");
                        if self.turn_is_active() {
                            self.end_active_turn_on_disconnect();
                            self.toasts.push(
                                "Backend disconnected — turn ended. Reconnecting…".into(),
                                crate::components::toast::ToastLevel::Warning,
                            );
                        }
                        self.sse_reconnecting = true;
                    }
                }
            }
            BackendEvent::SseReconnecting { attempt } => {
                debug!("SSE reconnecting (attempt {})", attempt);
                self.sse_reconnecting = true;
                // D1: a mid-stream blip reconnects with a FRESH GET /stream/{id}
                // carrying no Last-Event-ID, so the turn's finalizing
                // AgentResponse emitted during the gap is lost and the spinner
                // would spin forever. Finalize the in-flight turn on the FIRST
                // reconnect attempt (like opencode finalizing the in-flight part
                // on a stream error) instead of waiting for a completion frame
                // that will never arrive. Gated on attempt == 1 so multiple
                // backoff attempts don't re-toast or re-finalize.
                if attempt == 1 && self.turn_is_active() {
                    self.end_active_turn_on_disconnect();
                    self.toasts.push(
                        "Connection interrupted — turn ended. Reconnecting…".into(),
                        crate::components::toast::ToastLevel::Warning,
                    );
                }
            }
            BackendEvent::StreamingToken { text, .. } => {
                // Gate on the whole turn, not just `Processing`: ~20 overlays can
                // open FROM Processing (/context, /cost, /tools, …), which parks
                // the live turn on the return stack and flips `is_processing()`
                // false. The old `is_processing()` gate silently DROPPED every
                // token streamed while such an overlay was up, so closing it lost
                // a chunk of the answer. `turn_is_active()` keeps `stream_buf`
                // accumulating so the text is intact when the overlay closes.
                if self.turn_is_active() {
                    // Reasoning is over once real tokens stream. Freeze the
                    // thinking box to its done state ("∴ Thought for Ns") instead
                    // of clearing it, so the reasoning summary persists rather
                    // than vanishing. `finish()` is idempotent, and a later
                    // ThinkingDelta (multi-iteration turn) starts a fresh run.
                    // thinking_buf is kept — it is the transcript accumulator.
                    if !self.thinking_box.is_empty() {
                        self.thinking_box.finish();
                    }
                    self.stream_buf.push_str(&text);
                    self.chat.update_streaming(&self.stream_buf);
                    // Count CHARACTERS, not UTF-8 bytes — the ~4-chars/token
                    // estimate inflates badly on non-ASCII output if we use len().
                    self.activity.add_stream_chars(text.chars().count());
                    self.activity.set_phase(ProcessingPhase::Streaming);
                }
            }
            BackendEvent::ThinkingDelta { text } => {
                // U-B4 — gate on the active turn, mirroring `StreamingToken`.
                // A stray reasoning frame arriving while Idle (e.g. a late
                // event after the turn ended, or replayed post-disconnect)
                // used to pop a ghost "Thinking…" box and re-activate the
                // spinner with no turn behind it. Dropping it when no turn is
                // live keeps the reasoning box tied to a real turn.
                if self.turn_is_active() {
                    self.thinking_buf.push_str(&text);
                    self.thinking_box.update(&text);
                    self.activity.add_thinking_chars(text.chars().count());
                    self.activity.set_phase(ProcessingPhase::Thinking);
                }
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

                // The reasoning box REPLACES the activity row in draw_inline
                // (event_loop draws thinking_box INSTEAD of the activity feed
                // whenever it is non-empty — see event_loop.rs:642 and
                // think_row_height). If the model went thinking → straight to a
                // tool call with no interleaved streaming text, the box would
                // stay up and hide the live tool feed for the rest of the turn.
                // Clear it here (StreamingToken already does the same) so each
                // running tool is visible with its name + status + spinner.
                // Freeze to the done state ("∴ Thought for Ns") rather than
                // clearing so the reasoning summary persists across the
                // reasoning→tool edge instead of silently vanishing.
                if !self.thinking_box.is_empty() {
                    self.thinking_box.finish();
                }

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
                        // U-B6 — count a live background job at most once. On an
                        // SSE reconnect/replay the same ToolCallStart can arrive
                        // twice; without this guard `bg_shell_count` drifted up
                        // (one completion event can only decrement it once).
                        if self.counted_bg_shells.insert(bg_shell_signature(&name, &args)) {
                            self.bg_shell_count += 1;
                            self.refresh_bg_indicators();
                        }
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
            BackendEvent::CommandOutputDelta {
                command,
                chunk,
                tail,
                seq,
            } => {
                // A still-running foreground shell command is talking. Append to
                // the bounded live preview so the activity feed shows a tail
                // instead of a silent spinner.
                //
                // `chunk` is the incremental delta and is what the ring buffer
                // wants. On the FIRST delta we have no prior state, so an event
                // with seq > 0 arriving first (late SSE attach, dropped frames)
                // seeds from `tail` — the rolling snapshot — instead of showing
                // a preview that starts mid-stream with no context.
                let seeding = seq > 0 && self.activity.live_output_lines().is_empty();
                let text = if seeding { &tail } else { &chunk };
                if !text.is_empty() {
                    self.activity.push_command_output(&command, text);
                }
                // No redraw request needed: the event loop repaints the live
                // region every tick (the spinner cadence), so the appended tail
                // shows up on the next frame. The activity slot height is
                // unchanged by design, so no `recompute_layout` either.
            }
            BackendEvent::ToolCallEnd {
                name,
                duration_ms,
                success,
            } => {
                // The command is done — its full output goes to scrollback via
                // the tool summary below, so drop the live preview.
                if is_shell_tool(&name) {
                    self.activity.clear_command_output();
                }
                self.activity.tool_end(&name, duration_ms, success);
                self.activity.set_phase(ProcessingPhase::Waiting);
                // Item 3 — after a tool completes we're blocked on the model to
                // resume streaming; name that wait instead of a flavor verb.
                self.activity
                    .set_waiting_reason(Some(crate::components::activity::WaitingReason::Model));

                // Build rich styled tool summary for the chat — pop the OLDEST
                // pending args for this tool name (FIFO), matching call order.
                // `pending` is `None` when NO matching ToolCallStart was seen
                // (out-of-order / duplicated / reconnect-replayed end frame): we
                // have no args, so rendering would leave a permanent Read/Edit
                // line with an EMPTY filename. Treat that as an orphan and skip
                // building any scrollback line.
                let pending = self
                    .pending_tool_args
                    .get_mut(&name)
                    .filter(|q| !q.is_empty())
                    .map(|q| q.remove(0));
                let orphan = is_orphan_tool_end(pending.is_some());
                let args = pending.unwrap_or_default();
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
                // U-B6 — did this ToolCallEnd build a rich scrollback message a
                // stashed (early) ToolResult can attach to? Only the
                // non-collapsible path does; collapsible runs fold into a summary
                // with no per-call result slot.
                let mut built_tool_message = false;
                if orphan {
                    // No matching ToolCallStart: render nothing (an empty-args
                    // tool line is worse than no line). Fall through to drain any
                    // stashed ToolResult below so the map never leaks.
                    debug!(
                        "Orphan tool_call end with no matching start: {} ({}ms)",
                        name, duration_ms
                    );
                } else if kind.is_collapsible() {
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
                        built_tool_message = true;
                    }
                    debug!(
                        "Tool call end: {} ({}ms, success={})",
                        name, duration_ms, success
                    );
                }
                // U-B6 — a ToolResult that arrived BEFORE this ToolCallEnd was
                // stashed (there was no message to attach it to yet). Now that the
                // message exists, drain the stash: attach the result to the fresh
                // message and finalize it into scrollback. For a collapsible run
                // (no per-call message) the stashed result is simply discarded so
                // the map never leaks.
                if let Some(mut results) = self.pending_tool_results.remove(&name) {
                    if !results.is_empty() {
                        let (res, _succ) = results.remove(0);
                        if built_tool_message && !res.is_empty() {
                            self.chat.update_last_tool_result(&name, &res);
                        }
                        self.chat.finalize_tool(&name);
                    }
                    // Requeue any further out-of-order results for later calls.
                    if !results.is_empty() {
                        self.pending_tool_results.insert(name.clone(), results);
                    }
                }
            }
            BackendEvent::ToolResult {
                name, result, success,
            } => {
                // U-B6 — ToolResult can arrive BEFORE its ToolCallEnd on an
                // out-of-order stream. ToolCallEnd is what builds the scrollback
                // message, so attaching now would find nothing and DROP the
                // output. The call is "still pending" while its args remain queued
                // in `pending_tool_args` (pushed on start, popped on end); in that
                // window stash the result for ToolCallEnd to attach. Otherwise the
                // message already exists → attach + finalize now (unchanged path).
                let call_args_still_queued = self
                    .pending_tool_args
                    .get(&name)
                    .map_or(false, |q| !q.is_empty());
                if tool_result_should_stash(call_args_still_queued) {
                    self.pending_tool_results
                        .entry(name.clone())
                        .or_default()
                        .push((result, success));
                } else {
                    // Attach result to last matching tool message for expand
                    // support, then finalize into native scrollback. Scrolled-back
                    // tool calls become static (lose Ctrl+O), matching Claude Code.
                    if !result.is_empty() {
                        self.chat.update_last_tool_result(&name, &result);
                    }
                    self.chat.finalize_tool(&name);
                }
                debug!("Tool result: {} (success={})", name, success);
            }
            BackendEvent::LlmRequest { iteration, max_iterations } => {
                self.activity.set_iteration(iteration as u32);
                self.activity.set_max_iterations(max_iterations);
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
                // Context meter self-heal: input_tokens is the full prompt that
                // was actually sent = the context in use. ContextPressure is the
                // authoritative feed but doesn't fire on every provider/turn, so
                // without this the meter sticks at 0% mid-turn (glm/openai-compat
                // streaming path). Derive it from the real request size here.
                self.status.note_input_tokens(input_tokens);
                self.sidebar.set_context(self.status.context_ratio());
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
                // Arm the debounced "Updated plan" snapshot. A plan of N steps
                // arrives as N task_created events in one burst; re-arming here and
                // flushing on tick coalesces them into a single history cell.
                self.plan_snapshot_debounce = 2;
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
                // Debounced snapshot (dedup in snapshot_if_changed still guards a
                // no-op update, so an unchanged TaskUpdated flushes to nothing).
                self.plan_snapshot_debounce = 2;
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
                // One event carries the whole plan; still route through the
                // debounce so it produces a single "Updated plan" history cell.
                self.plan_snapshot_debounce = 2;
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
                        // Keep the status-bar folder label in lockstep with the
                        // banner: both show the real working dir the agent operates
                        // in, so the two surfaces can never disagree.
                        self.status.set_cwd_path(&self.working_dir);
                    }

                    // If this fetch was triggered by `/tools`, open the browser now
                    // that the full list is in hand.
                    if self.tools_browser_pending {
                        self.tools_browser_pending = false;
                        let entries: Vec<crate::dialogs::tools_browser::ToolEntry> = tools
                            .iter()
                            .map(|t| crate::dialogs::tools_browser::ToolEntry {
                                name: t.name.clone(),
                                description: t.description.clone(),
                                module: t.module.clone(),
                            })
                            .collect();
                        if self.state.can_transition_to(AppState::Tools) {
                            self.tools_browser =
                                Some(crate::dialogs::tools_browser::ToolsBrowser::new(entries));
                            self.enter_overlay(AppState::Tools);
                        }
                    }
                }
                Err(e) => {
                    if self.tools_browser_pending {
                        self.tools_browser_pending = false;
                        self.toasts.push(
                            format!("Could not load tools: {e}"),
                            crate::components::toast::ToastLevel::Error,
                        );
                    }
                    warn!("Failed to load tools: {}", e);
                }
            },
            BackendEvent::WorkspaceIdentityLoaded(result) => match result {
                Ok(identity) => {
                    // Store the git-root-aware name for the window title (see
                    // sync_chrome). The STATUS-BAR folder label deliberately tracks
                    // the real working dir (set at banner time) so it always agrees
                    // with the welcome banner, rather than showing a git-root name
                    // that can differ from the folder the user is actually in.
                    self.workspace_name = Some(identity.name.clone());
                }
                Err(e) => {
                    debug!("Failed to load workspace identity: {}", e);
                }
            },
            BackendEvent::ContextLoaded(result) => match result {
                Ok(stats) => {
                    self.context_stats =
                        Some(crate::dialogs::context_breakdown::ContextStats {
                            system_tokens: stats.system_tokens,
                            conversation_tokens: stats.conversation_tokens,
                            tool_result_tokens: stats.tool_result_tokens,
                            max_tokens: stats.max_tokens,
                            used_tokens: stats.used_tokens,
                        });
                    if self.state.can_transition_to(AppState::ContextBreakdown) {
                        self.enter_overlay(AppState::ContextBreakdown);
                    }
                }
                Err(e) => {
                    self.toasts.push(
                        format!("Could not load context: {e}"),
                        crate::components::toast::ToastLevel::Error,
                    );
                }
            },
            BackendEvent::TrustLoaded(result) => match result {
                Ok(status) => {
                    let risks: Vec<String> =
                        status.risks.iter().map(|r| r.label.clone()).collect();
                    self.trust_dialog = Some(crate::dialogs::trust::TrustDialog::new(
                        status.path.clone(),
                        risks,
                    ));
                    if self.state.can_transition_to(AppState::Trust) {
                        self.enter_overlay(AppState::Trust);
                    }
                }
                Err(e) => {
                    self.toasts.push(
                        format!("Could not load trust status: {e}"),
                        crate::components::toast::ToastLevel::Error,
                    );
                }
            },
            BackendEvent::PermissionRulesLoaded(result) => match result {
                Ok(resp) => {
                    let rules = resp
                        .rules
                        .into_iter()
                        .map(|r| crate::dialogs::permissions_manager::Rule {
                            behavior: r.behavior,
                            rule: r.rule,
                            source: r.source,
                        })
                        .collect();
                    self.permissions_manager =
                        Some(crate::dialogs::permissions_manager::PermissionsManager::new(rules));
                    if self.state.can_transition_to(AppState::PermissionsManager) {
                        self.enter_overlay(AppState::PermissionsManager);
                    }
                }
                Err(e) => self.toasts.push(
                    format!("Could not load permission rules: {e}"),
                    crate::components::toast::ToastLevel::Error,
                ),
            },
            BackendEvent::HooksLoaded(result) => match result {
                Ok(resp) => {
                    let mut events: Vec<crate::dialogs::hooks_viewer::EventHooks> = resp
                        .hooks
                        .into_iter()
                        .map(|(event, hooks)| {
                            let m = resp.metrics.get(&event);
                            crate::dialogs::hooks_viewer::EventHooks {
                                hooks: hooks
                                    .into_iter()
                                    .map(|h| crate::dialogs::hooks_viewer::HookEntry {
                                        name: h.name,
                                        priority: h.priority,
                                    })
                                    .collect(),
                                calls: m.map(|x| x.calls).unwrap_or(0),
                                avg_us: m.map(|x| x.avg_us).unwrap_or(0),
                                event,
                            }
                        })
                        .collect();
                    events.sort_by(|a, b| a.event.cmp(&b.event));
                    self.hooks_viewer =
                        Some(crate::dialogs::hooks_viewer::HooksViewer::new(events));
                    if self.state.can_transition_to(AppState::Hooks) {
                        self.enter_overlay(AppState::Hooks);
                    }
                }
                Err(e) => self.toasts.push(
                    format!("Could not load hooks: {e}"),
                    crate::components::toast::ToastLevel::Error,
                ),
            },
            BackendEvent::McpServersLoaded(result, open) => match result {
                Ok(resp) => {
                    // U-T26 — surface a persistent "N MCP" status-bar chip from
                    // the count of connected (enabled) servers. (OSA has no LSP
                    // concept, so no "N LSP" half is shown.) Runs on session start
                    // (quiet refresh) as well as `/mcp`, so the chip appears
                    // automatically instead of only after the dialog is opened.
                    let enabled = resp.servers.iter().filter(|s| s.enabled).count();
                    self.status.set_mcp(enabled);
                    let servers = resp
                        .servers
                        .into_iter()
                        .map(|s| crate::dialogs::mcp_servers::McpServer {
                            name: s.name,
                            transport: s.transport,
                            enabled: s.enabled,
                            status: s.status,
                            tool_count: s.tool_count,
                        })
                        .collect();
                    self.mcp_servers =
                        Some(crate::dialogs::mcp_servers::McpServers::new(servers));
                    // Only an explicit `/mcp` opens the dialog; the background
                    // chip refresh just updates the count above.
                    if open && self.state.can_transition_to(AppState::Mcp) {
                        self.enter_overlay(AppState::Mcp);
                    }
                }
                // A quiet background refresh failing must not spam a toast.
                Err(e) => {
                    if open {
                        self.toasts.push(
                            format!("Could not load MCP servers: {e}"),
                            crate::components::toast::ToastLevel::Error,
                        );
                    }
                }
            },
            BackendEvent::CostLoaded(result) => match result {
                Ok(r) => {
                    let view = crate::dialogs::cost_dashboard::CostView {
                        total_cost_usd: r.total_cost_usd,
                        total_tokens: r.total_tokens,
                        input_tokens: r.input_tokens,
                        output_tokens: r.output_tokens,
                        sessions: r.sessions,
                        since: r.since,
                        monthly_limit_usd: None,
                        monthly_spent_usd: None,
                        daily_limit_usd: None,
                        daily_spent_usd: None,
                    };
                    self.cost_dashboard =
                        Some(crate::dialogs::cost_dashboard::CostDashboard::new(view));
                    if self.state.can_transition_to(AppState::Cost) {
                        self.enter_overlay(AppState::Cost);
                    }
                }
                Err(e) => self.toasts.push(
                    format!("Could not load cost: {e}"),
                    crate::components::toast::ToastLevel::Error,
                ),
            },
            BackendEvent::SkillsBrowserLoaded(result) => match result {
                Ok(skills) => {
                    let items = skills
                        .into_iter()
                        .map(|s| crate::dialogs::skills_browser::SkillItem {
                            name: s.name,
                            description: s.description,
                            category: s.category,
                            triggers: s.triggers.unwrap_or_default(),
                            priority: s.priority,
                        })
                        .collect();
                    self.skills_browser =
                        Some(crate::dialogs::skills_browser::SkillsBrowser::new(items));
                    if self.state.can_transition_to(AppState::Skills) {
                        self.enter_overlay(AppState::Skills);
                    }
                }
                Err(e) => self.toasts.push(
                    format!("Could not load skills: {e}"),
                    crate::components::toast::ToastLevel::Error,
                ),
            },
            BackendEvent::MemoriesLoaded(result) => match result {
                Ok(resp) => {
                    let entries = resp
                        .entries
                        .into_iter()
                        .map(|e| crate::dialogs::memory_browser::MemoryEntry {
                            content: e.content,
                            category: e.category,
                            scope: e.scope,
                            created_at: e.created_at,
                        })
                        .collect();
                    self.memory_browser =
                        Some(crate::dialogs::memory_browser::MemoryBrowser::new(entries));
                    if self.state.can_transition_to(AppState::Memory) {
                        self.enter_overlay(AppState::Memory);
                    }
                }
                Err(e) => self.toasts.push(
                    format!("Could not load memory: {e}"),
                    crate::components::toast::ToastLevel::Error,
                ),
            },
            BackendEvent::TasksListLoaded(result) => match result {
                Ok(resp) => {
                    let tasks = resp
                        .tasks
                        .into_iter()
                        .map(|t| crate::dialogs::tasks_panel::TaskEntry {
                            id: t.id,
                            description: t.description,
                            status: t.status,
                            priority: t.priority,
                        })
                        .collect();
                    self.tasks_panel =
                        Some(crate::dialogs::tasks_panel::TasksPanel::new(tasks));
                    if self.state.can_transition_to(AppState::Tasks) {
                        self.enter_overlay(AppState::Tasks);
                    }
                }
                Err(e) => self.toasts.push(
                    format!("Could not load tasks: {e}"),
                    crate::components::toast::ToastLevel::Error,
                ),
            },
            BackendEvent::MetricsLoaded(result) => match result {
                Ok(resp) => {
                    let data = crate::dialogs::metrics_dashboard::MetricsData {
                        cards: resp
                            .cards
                            .into_iter()
                            .map(|c| crate::dialogs::metrics_dashboard::MetricCard {
                                label: c.label,
                                value: c.value,
                                note: c.note,
                                tone: c.tone,
                            })
                            .collect(),
                        rows: resp
                            .rows
                            .into_iter()
                            .map(|r| crate::dialogs::metrics_dashboard::LatencyRow {
                                name: r.name,
                                kind: r.kind,
                                count: r.count,
                                avg_ms: r.avg_ms,
                                p99_ms: r.p99_ms,
                            })
                            .collect(),
                    };
                    self.metrics_dashboard =
                        Some(crate::dialogs::metrics_dashboard::MetricsDashboard::new(data));
                    if self.state.can_transition_to(AppState::Metrics) {
                        self.enter_overlay(AppState::Metrics);
                    }
                }
                Err(e) => self.toasts.push(
                    format!("Could not load metrics: {e}"),
                    crate::components::toast::ToastLevel::Error,
                ),
            },
            BackendEvent::PersonasLoaded(result) => match result {
                Ok(resp) => {
                    let current = resp.current.clone();
                    let personas = resp
                        .personas
                        .into_iter()
                        .map(|p| crate::dialogs::persona_picker::PersonaEntry {
                            current: p.name == current,
                            name: p.name,
                            display: p.display,
                            description: p.description,
                        })
                        .collect();
                    self.persona_picker =
                        Some(crate::dialogs::persona_picker::PersonaPicker::new(personas));
                    if self.state.can_transition_to(AppState::Persona) {
                        self.enter_overlay(AppState::Persona);
                    }
                }
                Err(e) => self.toasts.push(
                    format!("Could not load personas: {e}"),
                    crate::components::toast::ToastLevel::Error,
                ),
            },
            BackendEvent::SandboxesLoaded(result) => match result {
                Ok(resp) => {
                    let mode = resp.mode.clone();
                    let backends = resp
                        .backends
                        .into_iter()
                        .map(|b| crate::dialogs::sandbox_picker::SandboxBackend {
                            name: b.name,
                            display_name: b.display_name,
                            available: b.available,
                            current: b.current,
                        })
                        .collect();
                    self.sandbox_picker =
                        Some(crate::dialogs::sandbox_picker::SandboxPicker::new(backends, mode));
                    if self.state.can_transition_to(AppState::Sandbox) {
                        self.enter_overlay(AppState::Sandbox);
                    }
                }
                Err(e) => self.toasts.push(
                    format!("Could not load sandboxes: {e}"),
                    crate::components::toast::ToastLevel::Error,
                ),
            },
            BackendEvent::ChannelsListLoaded(result) => match result {
                Ok(resp) => {
                    let channels = resp
                        .channels
                        .into_iter()
                        .map(|ch| {
                            let connected = ch.connected;
                            crate::dialogs::channels_panel::ChannelEntry {
                                name: ch.name,
                                connected,
                                status: if connected { "connected".into() } else { "not connected".into() },
                                kind: ch
                                    .module
                                    .and_then(|m| m.rsplit('.').next().map(|s| s.to_lowercase()))
                                    .unwrap_or_else(|| "messaging".into()),
                            }
                        })
                        .collect();
                    self.channels_panel =
                        Some(crate::dialogs::channels_panel::ChannelsPanel::new(channels));
                    if self.state.can_transition_to(AppState::Channels) {
                        self.enter_overlay(AppState::Channels);
                    }
                }
                Err(e) => self.toasts.push(
                    format!("Could not load channels: {e}"),
                    crate::components::toast::ToastLevel::Error,
                ),
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
            BackendEvent::SelfUpdate(ev) => {
                self.handle_self_update(ev);
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
                    // A2 — refresh the effort chip so it reflects the new model's
                    // reasoning effort instead of staying stuck on the previous
                    // model's value. Only when the backend reports it (absent ⇒
                    // leave the chip untouched rather than clearing a good value).
                    if let Some(effort) = resp.effort.clone() {
                        self.status.set_effort(Some(effort));
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
                    // Hotfix: a failed fetch must never leave the newcomer
                    // with no picker at all. Open a small offline fallback
                    // catalog (paste-key providers + local Ollama) so setup
                    // can still be completed; Ctrl+R inside the picker
                    // retries the real fetch and swaps in the full catalog
                    // once it succeeds.
                    self.toasts.push(
                        format!("Couldn't load full provider list ({}) — showing basics", e),
                        crate::components::toast::ToastLevel::Warning,
                    );
                    let current_provider = self.header.provider().to_string();
                    let current_model = self.header.model_name().to_string();
                    self.model_picker = Some(crate::dialogs::model_picker::ModelPicker::new_fallback(
                        current_provider,
                        current_model,
                    ));
                    self.enter_overlay(AppState::ModelPicker);
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
                            // Distinguish a bad key from a network/API error.
                            // Prefer the backend's explicit `verified` tag
                            // ("key_rejected" vs "unverified") from the
                            // hotfix; fall back to the old error-code
                            // heuristic for providers/backends that don't
                            // send it yet (HTTP is always 200 either way).
                            let reason = r
                                .message
                                .clone()
                                .or_else(|| r.error.clone())
                                .unwrap_or_else(|| "Unknown error".into());
                            let key_rejected = match r.verified.as_deref() {
                                Some("key_rejected") => true,
                                Some("unverified") | Some("ok") => false,
                                _ => matches!(
                                    r.error.as_deref(),
                                    Some("unauthorized")
                                        | Some("forbidden")
                                        | Some("insufficient_credits")
                                ),
                            };
                            if key_rejected {
                                picker.set_verify_failed(reason);
                            } else {
                                picker.set_verify_error(reason);
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
                // Codex-style live naming: during orchestration the leader spinner
                // otherwise shows a generic flavor verb while sub-agents do the
                // real work. Surface the running sub-agent by name + subject on the
                // spinner row ("@deep-scan: scanning modules") so the user always
                // sees WHAT is happening, not just that something is.
                let label = if subject.trim().is_empty() {
                    format!("@{}: {}", agent_name, current_action)
                } else {
                    format!("@{}: {}", agent_name, subject)
                };
                self.activity.set_active_verb(Some(label));
                // Trail length can change the panel height — keep layout in sync.
                self.recompute_layout();
            }
            BackendEvent::OrchestratorAgentCompleted { agent_name, tool_uses, tokens_used, summary, .. } => {
                self.agents.agent_completed(&agent_name, tool_uses, tokens_used, summary);
                self.sidebar.set_current_agent("");
                // Clear the stale "@agent: subject" spinner label set on every
                // progress tick — otherwise the leader spinner keeps naming a
                // finished sub-agent until some unrelated event overwrites it.
                self.activity.set_active_verb(None);
            }
            BackendEvent::OrchestratorAgentFailed { agent_name, error, tool_uses, tokens_used, summary } => {
                // Fall back to the (truncated) error text when the backend sent no
                // dedicated summary, so a failed row still previews what went wrong.
                let fail_summary = summary.or_else(|| {
                    let e = error.trim();
                    if e.is_empty() { None } else { Some(e.chars().take(140).collect()) }
                });
                self.agents.agent_failed(&agent_name, &error, tool_uses, tokens_used, fail_summary);
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
                // Orchestration is over — drop any lingering "@agent: subject"
                // label so the leader spinner doesn't keep a dead sub-agent name.
                self.activity.set_active_verb(None);
                self.recompute_layout();
            }

            // === Fleet events → Agents component (CC FleetView roster) ===
            // Full-power background nodes drive the same roster mutation API as
            // orchestrator workers, so they appear inline identically.
            BackendEvent::FleetNodeStarted { node_id, agent_type, task, .. } => {
                self.agents.agent_started(&node_id, &agent_type, "", &task, None);
                self.recompute_layout();
            }
            BackendEvent::FleetNodeProgress {
                node_id,
                current_action,
                tool_uses,
                tokens_used,
                recent_actions,
            } => {
                self.agents.agent_progress(
                    &node_id,
                    &current_action,
                    tool_uses,
                    tokens_used,
                    "",
                    recent_actions,
                );
                self.recompute_layout();
            }
            BackendEvent::FleetNodeCompleted { node_id, summary, status } => {
                self.agents.fleet_node_completed(&node_id, &status, summary);
                self.recompute_layout();
            }
            BackendEvent::FleetSummary { running, queued, cap, total_spawned, warn } => {
                self.agents
                    .set_fleet_summary(running, queued, cap, total_spawned, warn);
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
                let panel_summary: Option<String> = {
                    let first = result.trim().lines().find(|l| !l.trim().is_empty()).unwrap_or("");
                    if first.is_empty() { None } else { Some(first.chars().take(140).collect()) }
                };
                self.agents.agent_completed(&agent_id, 0, 0, panel_summary);
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
                let panel_summary: Option<String> = {
                    let first = error.trim().lines().find(|l| !l.trim().is_empty()).unwrap_or("");
                    if first.is_empty() { None } else { Some(first.chars().take(140).collect()) }
                };
                self.agents.agent_failed(&agent_id, error.clone(), 0, 0, panel_summary);
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
                // U-B6 — with no live background jobs left, forget the counted
                // signatures so a later identical command counts fresh (and the
                // set can't grow without bound).
                if self.bg_shell_count == 0 {
                    self.counted_bg_shells.clear();
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
                // Item 1 — also hold the retry state LIVE on the spinner row so
                // the stall is visible on the status line (with a countdown),
                // not just as a one-shot scrollback note. Cleared automatically
                // when the turn resumes (tokens/stream/non-Waiting phase).
                self.activity.set_retry(Some(
                    crate::components::activity::RetryState {
                        attempt,
                        max_attempts,
                        reason: reason.clone(),
                        resume_at: std::time::Instant::now()
                            + std::time::Duration::from_millis(delay_ms),
                    },
                ));
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
                // U-B5 — drive the live status-bar swarm chip.
                self.status.set_swarm(Some(intelligence_type.clone()));
                self.toasts.push(
                    format!("SI started: {}", intelligence_type),
                    crate::components::toast::ToastLevel::Info,
                );
            }
            BackendEvent::SwarmIntelligenceRound { swarm_id, round } => {
                // U-B5 — previously a dead debug-only handler. Surface each
                // round on the status-bar swarm chip so the swarm's progress is
                // actually visible ("✻ swarm · round N").
                debug!("SI round {}: {}", round, swarm_id);
                self.status.set_swarm(Some(format!("swarm \u{00b7} round {}", round)));
            }
            BackendEvent::SwarmIntelligenceConverged { round, .. } => {
                self.status.set_swarm(None);
                self.toasts.push(
                    format!("SI converged (round {})", round),
                    crate::components::toast::ToastLevel::Success,
                );
            }
            BackendEvent::SwarmIntelligenceCompleted { swarm_id, .. } => {
                self.agents.swarm_completed(&swarm_id);
                self.status.set_swarm(None);
                self.recompute_layout();
            }

            // === Goal Verification (independent skeptic panel) ===
            BackendEvent::GoalVerification {
                phase,
                verdict,
                round,
                refuted,
                total,
                gaps,
                ..
            } => {
                use crate::components::status_bar::GoalVerifyState;
                debug!(
                    "goal verifier round {} phase={} verdict={} {}/{}",
                    round, phase, verdict, refuted, total
                );
                let state = if phase == "start" {
                    Some(GoalVerifyState::Verifying)
                } else {
                    match verdict.as_str() {
                        "complete" => Some(GoalVerifyState::OnTrack),
                        "off_track" => Some(GoalVerifyState::OffTrack),
                        // "incomplete" and anything unexpected fail toward the
                        // gap indicator (mirrors the backend's fail-closed vote).
                        _ => Some(GoalVerifyState::Incomplete {
                            refuted,
                            total,
                            gaps,
                        }),
                    }
                };
                self.status.set_goal_verification(state);
            }

            // === Shared scratchpad activity → Agents panel ===
            BackendEvent::ScratchpadActivity { agent, entry, action, bytes } => {
                // Feed the visual panel (dim, capped recent-writes section).
                self.agents.scratchpad_activity(&agent, &entry, &action, bytes);
                // Screen-reader path: announce a plain-text note instead of the
                // glyph-decorated panel line (no-op for sighted users).
                let verb = if action == "append" { "appended" } else { "wrote" };
                self.announce_a11y(&format!(
                    "@{} {} {} to the shared scratchpad ({} bytes)",
                    agent, verb, entry, bytes
                ));
                // The new line changes the panel height — keep layout in sync.
                self.recompute_layout();
            }

            // === Phase 2+ HTTP Response Results ===
            // (U-B5: the dead `SkillsLoaded` handler was removed — it only
            // logged. The skills browser is driven by `SkillsBrowserLoaded`.)
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
                    // Prefer the backend's echoed provider/model; fall back to the
                    // wizard's actual selection so the header/status/sidebar never
                    // render a placeholder ("configured" / "default"). Only if both
                    // are somehow absent do we show a neutral label.
                    let wiz_prov = self
                        .onboarding
                        .as_ref()
                        .and_then(|w| w.selected_provider_id());
                    let wiz_model = self
                        .onboarding
                        .as_ref()
                        .and_then(|w| w.selected_model_id());
                    let prov = resp
                        .provider
                        .clone()
                        .filter(|s| !s.is_empty())
                        .or(wiz_prov)
                        .unwrap_or_else(|| "unknown".to_string());
                    let mdl = resp
                        .model
                        .clone()
                        .filter(|s| !s.is_empty())
                        .or(wiz_model)
                        .unwrap_or_else(|| "unknown".to_string());
                    self.header.set_provider_info(&prov, &mdl);
                    self.status.set_provider_info(&prov, &mdl);
                    self.sidebar.set_provider_info(&prov, &mdl);
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
                target,
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
                dialog.set_target(target);
                if let (Some(old), Some(new)) = (old_content, new_content) {
                    dialog.set_diff(old, new);
                }
                dialog.set_meta(warning, reason);
                self.permissions = Some(dialog);
                // Item 5 — the turn is now blocked on YOU: pulse the ◆ cue so
                // the spinner telegraphs "you're the blocker". Cleared on resume.
                self.activity.set_pending_user(true);
                if self.state.can_transition_to(AppState::Permissions) {
                    self.enter_overlay(AppState::Permissions);
                }
            }
            BackendEvent::PlanProposed { plan, request_id: _ } => {
                // Show the plan review dialog — backend paused for user approval.
                let mut review = crate::dialogs::plan_review::PlanReview::new();
                review.set_plan(plan);
                self.plan_review = Some(review);
                // Item 5 — parked on user approval → pulse the pending cue.
                self.activity.set_pending_user(true);
                if self.state.can_transition_to(AppState::PlanReview) {
                    self.enter_overlay(AppState::PlanReview);
                }
            }
            BackendEvent::CancelTimeout => {
                // Safety net: if the backend cancel response never came via SSE,
                // force the UI back to idle so the user isn't stuck.
                if self.cancelled && self.state.is_processing() {
                    info!("Cancel timeout — forcing UI back to Idle");
                    // Shared teardown: flush finished tools, drop partial text,
                    // reset per-turn buffers/spinner/status/agents.
                    self.finalize_turn_state();
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
                // Item 5 — waiting on the user's answer → pulse the pending cue.
                self.activity.set_pending_user(true);
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
            BackendEvent::CoordinatorMode { active } => {
                // The backend is authoritative for coordinator state (sticky
                // per-session store): reflect it on the status-bar chip, toast the
                // transition, and announce it for screen readers.
                self.status.set_coordinator(active);
                let msg = if active {
                    "Coordinator mode on: delegation and messaging only"
                } else {
                    "Coordinator mode off: full tool access"
                };
                self.toasts.push(
                    msg.into(),
                    crate::components::toast::ToastLevel::Info,
                );
                self.announce_a11y(msg);
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

/// U-B6 — de-dup key for a background shell job. The stream carries no per-call
/// id on `ToolCallStart`, so a replayed start is only recognisable by its
/// (name, args) pair. Same command text ⇒ same signature ⇒ counted once. Two
/// genuinely-distinct jobs with identical args collapse to one count (a rare,
/// bounded under-count) — strictly better than the previous unbounded drift.
fn bg_shell_signature(name: &str, args: &str) -> String {
    format!("{name}\u{0000}{args}")
}

/// U-B6 — decide, at `ToolResult` time, whether the result must be stashed for a
/// not-yet-built scrollback message. The call's `ToolCallEnd` (which builds the
/// message) has not run while its args are still queued in `pending_tool_args`;
/// in that window the result has nothing to attach to and must be held.
fn tool_result_should_stash(call_args_still_queued: bool) -> bool {
    call_args_still_queued
}

/// D4 — a ToolCallEnd whose matching ToolCallStart never queued its args (an
/// out-of-order / duplicated / reconnect-replayed end frame) is an ORPHAN.
/// Rendering it would build a permanent Read/Edit scrollback line with an empty
/// filename, so the handler suppresses the line for an orphan. Pure predicate.
fn is_orphan_tool_end(had_pending_args: bool) -> bool {
    !had_pending_args
}

/// Write a completion ping to the terminal via the channel-selected notifier
/// (ghostty OSC 777 / kitty OSC 99 / OSC 9 fallback, tmux-wrapped, plus a BEL
/// for terminals with no notification support). Control sequences the terminal
/// consumes — never disturbs the ratatui render.
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

#[cfg(test)]
mod handle_backend_tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn bg_shell_signature_is_stable_and_dedups_replay() {
        // U-B6 — replayed identical ToolCallStart must count the job once.
        let mut counted: HashSet<String> = HashSet::new();
        let mut count = 0usize;
        let (n, a) = ("bash", r#"{"command":"sleep 9","run_in_background":true}"#);

        // First start counts.
        if counted.insert(bg_shell_signature(n, a)) {
            count += 1;
        }
        // Replay of the SAME start does NOT count again.
        if counted.insert(bg_shell_signature(n, a)) {
            count += 1;
        }
        assert_eq!(count, 1, "replayed background start must not double-count");

        // A different command IS a distinct job.
        let a2 = r#"{"command":"sleep 5","run_in_background":true}"#;
        if counted.insert(bg_shell_signature(n, a2)) {
            count += 1;
        }
        assert_eq!(count, 2);

        // On completion → zero, the set clears so an identical command later
        // counts fresh (mirrors the handler's clear-at-zero).
        count = 0;
        counted.clear();
        assert!(counted.insert(bg_shell_signature(n, a)));
    }

    #[test]
    fn tool_result_stashes_only_while_call_pending() {
        // U-B6 — ordering oracle: stash iff the ToolCallEnd hasn't built the
        // message yet (its args are still queued).
        assert!(
            tool_result_should_stash(true),
            "result arriving before ToolCallEnd must be stashed"
        );
        assert!(
            !tool_result_should_stash(false),
            "result arriving after ToolCallEnd attaches directly"
        );
    }

    #[test]
    fn orphan_tool_end_when_no_args_were_queued() {
        // No matching start queued args → orphan → suppress the empty-args line.
        assert!(is_orphan_tool_end(false));
        // A real start queued args → render the tool line as usual.
        assert!(!is_orphan_tool_end(true));
    }
}
