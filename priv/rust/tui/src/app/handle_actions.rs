use crate::app::assistant_stream::Finalize;
use crate::app::state::AppState;
use crate::event::backend::BackendEvent;
use crate::event::Event;
use tracing::{debug, error, info, warn};

use super::App;
use crate::util::truncate_str;

impl App {
    pub(super) fn handle_health_result(
        &mut self,
        result: Result<crate::client::types::HealthResponse, String>,
    ) {
        match result {
            Ok(health) => {
                info!(
                    "Backend healthy: {} v{} ({}/{})",
                    health.status, health.version, health.provider, health.model
                );
                // The backend's version is the single source of truth for the
                // displayed version (its root VERSION file) — record it so the
                // status bar, welcome banner, and /version never show a stale
                // compile-time value.
                crate::config::set_runtime_version(&health.version);
                // One writer for every surface (header / status bar / sidebar /
                // welcome), so the banner and the status bar cannot show
                // different models on the same screen.
                self.set_identity(&health.provider, &health.model);

                // Welcome injection moved to ToolsLoaded handler (accurate tool count)

                // Seed context bar with model's max context window
                if let Some(ctx) = health.context_window {
                    self.status.set_context(0.0, 0, ctx);
                }

                // Claude-Code-style status-line extras: reasoning effort +
                // spend/limits. Both are Option — a field the backend didn't
                // send simply leaves its chip off (no "effort:" / "$" shown).
                self.status.set_effort(health.effort.clone());
                self.status.set_billing(health.billing.clone());

                // Update-available signal (Codex parity: understated, no
                // auto-install). Refresh the persistent status-bar chip on every
                // health poll — it appears while an update is available and
                // vanishes once the backend reports none. Then, at most ONCE per
                // session, drop a dim non-blocking notice into the transcript
                // pointing at `/update`. Never interrupts an in-progress turn:
                // this only runs on a completed health response.
                self.status.set_update_available(health.update.clone());
                if should_show_update_notice(health.update.as_ref(), self.update_notice_shown) {
                    self.update_notice_shown = true;
                    // Safe: should_show_* only returns true for Some(available).
                    if let Some(update) = health.update.as_ref() {
                        self.chat
                            .add_system_message(&update_notice_line(update), "info");
                    }
                }

                // Skip banner — go straight to Idle (no jarring screen switch)
                if self.state == AppState::Connecting {
                    self.transition(AppState::Idle);
                }
                self.health_retry_count = 0;

                // Start auth + SSE
                self.do_login();
            }
            Err(e) => {
                self.health_retry_count += 1;
                warn!("Health check failed (attempt {}): {}", self.health_retry_count, e);

                // Auto-start backend on first failure
                if !self.backend_spawn_attempted {
                    self.backend_spawn_attempted = true;
                    self.try_spawn_backend();
                }

                // Give up after 12 retries (60s total)
                if self.health_retry_count >= 12 {
                    error!("Backend unreachable after {} attempts", self.health_retry_count);
                    self.transition(AppState::Idle);
                    // Name the most common real cause (HTTP port already in use, so
                    // the backend crashed on start) and point at a single next step.
                    // Pull the actual configured port from the client's base_url so
                    // the diagnostic command is copy-pasteable.
                    let port = port_from_base_url(self.client.base_url());
                    self.toasts.push(
                        format!(
                            "Backend unreachable on port {port}. It may have failed to start \
                             because the port ({port}) is already in use. Run `osa doctor` to \
                             diagnose, or check: ss -ltnp | grep {port}"
                        ),
                        crate::components::toast::ToastLevel::Error,
                    );
                    return;
                }

                // Retry after delay
                let tx = self.event_tx.clone();
                tokio::spawn(async move {
                    tokio::time::sleep(super::HEALTH_RETRY_DELAY).await;
                    let _ = tx.send(Event::HealthRetry);
                });
            }
        }
    }

    pub(super) fn handle_login_result(
        &mut self,
        result: Result<crate::client::types::LoginResponse, String>,
    ) {
        match result {
            Ok(_) => {
                info!("Login successful");
                // Load commands and tools in parallel
                self.load_commands();
                self.load_tools();
                // Populate the "N MCP" status-bar chip up front so connected
                // servers are visible without the user opening `/mcp` first.
                self.refresh_mcp_status();
                // Start SSE
                self.start_sse();
                // Check if onboarding is needed
                self.check_onboarding();
            }
            Err(e) => {
                warn!("Login failed: {}", e);
                // Clear stale tokens so subsequent requests don't send them
                crate::client::auth::clear_tokens(&self.client.profile_dir);
                self.toasts.push(
                    format!("Login failed: {}", e),
                    crate::components::toast::ToastLevel::Error,
                );
            }
        }
    }

    pub(crate) fn check_onboarding(&self) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        tokio::spawn(async move {
            match client.onboarding_status().await {
                Ok(resp) => {
                    let _ = tx.send(Event::Backend(BackendEvent::OnboardingStatus(Ok(resp))));
                }
                Err(e) => {
                    let _ = tx.send(Event::Backend(BackendEvent::OnboardingStatus(Err(e.to_string()))));
                }
            }
        });
    }

    /// Force-show the onboarding wizard regardless of needs_onboarding status.
    /// Used by /setup command to let users reconfigure anytime.
    pub(crate) fn force_onboarding(&self) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        tokio::spawn(async move {
            match client.onboarding_status().await {
                Ok(mut resp) => {
                    // Force needs_onboarding to true so the wizard always shows
                    resp.needs_onboarding = true;
                    let _ = tx.send(Event::Backend(BackendEvent::OnboardingStatus(Ok(resp))));
                }
                Err(e) => {
                    let _ = tx.send(Event::Backend(BackendEvent::OnboardingStatus(Err(e.to_string()))));
                }
            }
        });
    }

    /// Apply the turn's terminal `agent_response`.
    ///
    /// `message_id` identifies which assistant message this finalizes (see
    /// `app::assistant_stream`). Two rules the old code got wrong:
    ///
    /// * the backend's text REPLACES that message's streamed accumulation —
    ///   it is the authoritative, post-processed version and was previously
    ///   discarded in favour of the raw deltas;
    /// * finalizing the same message twice renders nothing the second time,
    ///   so an SSE replay or a second code path ending the same turn cannot
    ///   append the answer a second time.
    pub(super) fn handle_agent_response(
        &mut self,
        response: String,
        signal: Option<crate::client::types::Signal>,
        message_id: Option<String>,
    ) {
        // Truncate if too long
        let display_response = if response.len() > super::MAX_MESSAGE_SIZE {
            let truncated = truncate_str(&response, super::MAX_MESSAGE_SIZE);
            format!(
                "{}\n\n... (response truncated at {}KB)",
                truncated,
                super::MAX_MESSAGE_SIZE / 1000
            )
        } else {
            response
        };

        // An interrupt marker is a synthetic control string, not assistant
        // prose — it never finalizes a message, so it bypasses the buffer
        // handover below and only drains whatever had streamed.
        let interrupted = is_interrupt_marker(&display_response);
        // A user interrupt IS a genuine turn end — the backend will not send a
        // `done` for a turn it just stopped, and waiting on the 3s
        // CancelTimeout before draining would make a queued command look
        // ignored. The queue deliberately survives an interrupt (CC parity), so
        // it has to fire promptly once the interrupt lands.
        if interrupted {
            self.turn_done = true;
        }

        // Hand the buffer over to the backend's text. This is the ONE place a
        // streamed assistant message becomes final, and it happens BEFORE any
        // other state is touched so a repeat delivery is a true no-op — it must
        // not re-run turn teardown, re-fire /goal continuation or re-drain the
        // message queue either.
        let finalized = if interrupted {
            None
        } else {
            match self
                .assistant_stream
                .finalize(message_id.as_deref(), display_response.clone())
            {
                Finalize::Duplicate => {
                    debug!(
                        "Ignoring repeat agent_response for message {:?}",
                        message_id
                    );
                    return;
                }
                Finalize::Emit(text) => Some(text),
            }
        };

        // If nothing is in the foreground (state is Idle) yet a background turn
        // is still running, this response belongs to that backgrounded turn —
        // its output is about to land in scrollback, so retire the handle and
        // update the running count. (Foregrounded turns were already removed
        // from `bg_tasks` by `foreground_task`, so this can't double-count.)
        if !self.state.is_processing() && self.bg_running_count() > 0 {
            self.complete_background_task();
        }

        self.chat.clear_streaming();
        // Ensure any completed tool call is committed to scrollback before the
        // final answer text, preserving chronological order.
        self.chat.flush_pending_tools();
        // Emit any pending collapsed tool run ("Read N files", …) before the
        // final answer text.
        self.flush_collapse();

        // WS5 — interrupt marker (CC parity): an interrupted turn ends with a
        // synthetic user-marker string (ReactLoop.finalize_interrupt). Render
        // it as a styled dim line instead of raw agent text — and when the
        // turn produced NO output at all, restore the interrupted prompt into
        // the composer for editing (CC auto-restore on user-cancel).
        if interrupted {
            let remaining = self.assistant_stream.take();
            let had_output = self.agent_header_sent || !remaining.trim().is_empty();
            // Close any open chunk flow first: the interrupt notice is its own
            // block, so the last settled chunk must give up its separator row.
            self.chat.end_agent_chunk_flow();
            if !remaining.trim().is_empty() {
                if self.agent_header_sent {
                    self.chat.add_agent_continuation(&remaining);
                } else {
                    self.chat.add_agent_message(&remaining, signal.as_ref());
                    self.agent_header_sent = true;
                }
            }
            self.chat.add_system_message(
                "Interrupted \u{00b7} What should OSA do instead?",
                "warning",
            );
            if !had_output && self.input.is_empty() && self.message_queue.is_empty() {
                if let Some(prev) = self.last_submitted_prompt.take() {
                    self.input.insert_str(&prev);
                }
            }
        } else if let Some(final_text) = finalized {
            // `final_text` is the backend's message, which has already REPLACED
            // the streamed accumulation (falling back to it only when the final
            // carried no text). It is never the two concatenated: appending the
            // final onto the deltas is exactly what welded a superseded answer
            // to its replacement.
            //
            // `agent_header_sent` is deliberately NOT reset afterwards: it is
            // reset only when the user submits a new prompt (submit_prompt).
            // Resetting it per response meant a turn that produced more than one
            // agent_response event (e.g. text → subagent/tool → more text)
            // emitted a second "◈ OSA" header, visually splitting one answer
            // into chunks.
            // `final_text` is what is LEFT of that message: `finalize` has
            // already subtracted the blocks that settled into native scrollback
            // while the reply streamed, so completion reveals only the last,
            // still-unfinished block — never a wholesale re-appearance of text
            // the user has been reading all along. It is empty when the reply
            // ended exactly on a block boundary, and then completion reveals
            // nothing at all, which is the point.
            crate::app::assistant_stream::commit_assistant_chunk(
                &mut self.chat,
                &mut self.agent_header_sent,
                &final_text,
                signal.as_ref(),
            );
            // The message is over: drop the block separator the last chunk was
            // still carrying so the answer does not end on a spare row.
            self.chat.end_agent_chunk_flow();
        }

        // Snapshot the spinner's clock at the turn-end edge, BEFORE stopping it
        // (and before /goal auto-continue or a queued auto-submit can restart
        // it for the NEXT turn). The turn_recap SSE event arrives after this
        // agent_response and consumes the snapshot, so "✻ Worked for Ns"
        // equals the last value the spinner showed instead of a server-side
        // clock that starts later (after the request round-trip) and can
        // visibly jump backwards.
        self.last_turn_client_elapsed_secs = self.activity.elapsed_secs();

        // Clear streaming state. `clear_buf`, NOT `reset`: this turn's
        // finalization must stay on record so a duplicate agent_response
        // arriving after it (SSE replay, a second terminal code path) is still
        // recognised as a repeat. The record is dropped when the next turn
        // opens (`submit_prompt` / `finalize_turn_state`).
        self.assistant_stream.clear_buf();
        self.thinking_buf.clear();
        self.thinking_box.clear();
        self.activity.stop();
        self.status.set_active(false);
        self.cancelled = false;

        // Freeze the plan into scrollback, then retire the live checklist for this
        // turn. This is the ONE AND ONLY place a plan cell is pushed to history:
        // one frozen copy per turn, showing the plan's FINAL state.
        //
        // It used to also flush from a settled ~400ms tick debounce after every
        // task mutation. `snapshot_if_changed` deduped identical states, but a
        // 3-step plan legitimately passes through 7 distinct states (create, then
        // start+complete per step) — so the transcript got 7-8 near-identical
        // cells for three tasks, alternating "Plan n/3" / "Updated plan n/3" as
        // the header tracked whether a step happened to be running. The live
        // checklist band shows progress in real time; history only needs the
        // outcome.
        //
        // Clearing here also closes an older bug: the checklist was never retired
        // at turn end, so it silently reappeared over the NEXT turn's reply.
        let snap_w = self.width.saturating_sub(2).max(20);
        if let Some((body, plain)) = self.task_checklist.snapshot_if_changed(snap_w) {
            self.chat.add_plan_snapshot(body, plain);
        }
        self.task_checklist.clear();

        // Transition back to idle
        if self.state.is_processing() {
            self.transition(AppState::Idle);
        }

        // Update signal in status bar
        if let Some(signal) = signal {
            self.status.set_signal(signal);
        }

        // Cross-turn keep-going: if a /goal is active, decide whether to stop
        // (DONE / cap / cancelled) or auto-submit the next continue prompt.
        self.maybe_continue_goal();

        // Message queue: if the turn fully ended (and /goal didn't take over,
        // which would flip us back to Processing), auto-submit the next queued
        // prompt FIFO. Guarded to Idle inside, so this is a no-op mid-turn.
        self.maybe_dequeue_message();

        self.recompute_layout();
    }

    pub(super) fn handle_command_result(
        &mut self,
        result: Result<crate::client::types::CommandExecuteResponse, String>,
    ) {
        match result {
            Ok(resp) => {
                match resp.kind.as_str() {
                    "error" => {
                        self.chat
                            .add_system_message(&resp.output, "error");
                    }
                    "prompt" => {
                        // Feed output back as a prompt (used by custom
                        // ~/.osa/commands/*.md commands: the expanded body is
                        // submitted as the turn's prompt). submit_prompt sets
                        // Processing and starts a real turn — return early so the
                        // post-match cleanup below does NOT immediately flip us
                        // back to Idle / stop the spinner.
                        self.submit_prompt(&resp.output);
                        return;
                    }
                    "action" => {
                        if let Some(action) = resp.action {
                            self.handle_command_action(&action);
                        }
                    }
                    _ => {
                        if !resp.output.is_empty() {
                            self.chat
                                .add_system_message(&resp.output, "info");
                        }
                    }
                }
            }
            Err(e) => {
                self.toasts.push(
                    format!("Command error: {}", e),
                    crate::components::toast::ToastLevel::Error,
                );
            }
        }

        if self.state.is_processing() {
            self.transition(AppState::Idle);
            self.activity.stop();
            self.status.set_active(false);
        }

        // A queued command/shell just finished — pull the next queued item. A
        // local command is its own whole turn, so it ends here; there is no
        // backend `done` coming for it.
        self.turn_done = true;
        self.maybe_dequeue_message();
    }

    fn handle_command_action(&mut self, action: &str) {
        match action {
            ":new_session" => self.create_session(),
            ":clear" => {
                self.chat.clear();
                self.tasks.clear();
            }
            _ => {
                debug!("Unhandled command action: {}", action);
            }
        }
    }

    pub fn submit_input(&mut self, text: &str) {
        let text = text.trim();
        if text.is_empty() {
            return;
        }

        // /steer <text>: inject a high-priority message. Handled before the
        // Processing-enqueue path so it can jump to the FRONT of the queue.
        if let Some(rest) = text.strip_prefix("/steer") {
            // Only treat as the steer command when it's exactly "/steer" or
            // "/steer <args>" — so a future "/steerX" command still routes on.
            if rest.is_empty() || rest.starts_with(char::is_whitespace) {
                self.steer_message(rest.trim());
                return;
            }
        }

        // Keep typing while it works: everything typed mid-turn is QUEUED and
        // runs FIFO when the turn ends. Enter never interrupts and never
        // diverts the running turn.
        //
        // Plain text used to become an automatic mid-turn steer — folded into
        // the RUNNING turn at its next step boundary. It read as the agent
        // lurching off course mid-thought, because that is what it was: the
        // turn had already spent tool calls establishing a line of work, and a
        // new instruction landed on top of it with no way to tell whether the
        // turn was one step or thirty from done.
        //
        // Queueing costs nothing by comparison. The message lands at the next
        // turn boundary with every tool result the turn produced still in
        // context, so the work is kept rather than re-derived. Steering remains
        // available — it is just explicit now (`/steer`, handled above), which
        // is the right shape for a gesture that overrides work in flight.
        if self.turn_is_active() {
            self.enqueue_message(text);
            return;
        }

        if text.starts_with('/') {
            self.handle_command(text);
        } else if let Some(shell_cmd) = text.strip_prefix('!') {
            self.execute_shell(shell_cmd.trim());
        } else {
            self.submit_prompt(text);
        }
    }

    /// Enqueue a message typed while the agent is Processing. It runs (FIFO)
    /// when the current turn completes. Shows a toast + updates the "N queued"
    /// indicator on the input.
    fn enqueue_message(&mut self, text: &str) {
        self.message_queue.push(text.to_string());
        // WS5 — the queued text renders as dim lines directly above the
        // composer (CC PromptInputQueuedCommands), so no toast: the user can
        // see and verify exactly what they queued, and recall it with ↑/Esc.
        self.input.set_queued_items(self.message_queue.clone());
        self.recompute_layout();
    }

    /// /steer — inject a directive. Idle: submit immediately as a new turn.
    /// Processing: TRUE mid-turn steer — POST the text to the live session so the
    /// backend folds it into the running ReAct loop at its next step boundary
    /// (primitive #32). The agent adapts WITHOUT the turn being cancelled and
    /// in-flight work lost — a strict upgrade over the old front-of-queue
    /// behaviour (which only ran the steer at the NEXT turn).
    pub(crate) fn steer_message(&mut self, text: &str) {
        let text = text.trim();
        if text.is_empty() {
            self.toasts.push(
                "Usage: /steer <text>".into(),
                crate::components::toast::ToastLevel::Warning,
            );
            return;
        }
        if self.state == AppState::Processing {
            // Mid-turn injection: hand the directive to the backend steer queue.
            // The running loop drains it at its next step boundary; no cancel,
            // no waiting for the turn to finish.
            let client = self.client.clone();
            let session_id = self.session_id.clone();
            let steer_text = text.to_string();
            tokio::spawn(async move {
                if let Err(e) = client.steer_session(&session_id, &steer_text).await {
                    tracing::warn!("Backend steer failed: {}", e);
                }
            });
            self.toasts.push(
                "steering — folding into the current turn".into(),
                crate::components::toast::ToastLevel::Info,
            );
        } else {
            self.submit_prompt(text);
        }
    }

    /// Auto-submit the next queued message once the agent is cleanly back to
    /// Idle (turn fully ended — not mid-turn, not auto-continued by /goal, no
    /// open dialog). FIFO: oldest first. Called at every turn-completion site.
    pub(super) fn maybe_dequeue_message(&mut self) {
        if !queue_may_drain(self.state, self.turn_done) {
            return;
        }
        if self.message_queue.is_empty() {
            return;
        }
        let next = self.message_queue.remove(0);
        self.input.set_queued_items(self.message_queue.clone());
        self.recompute_layout();
        // Re-enter the normal submit path so queued commands / shell / prompts
        // all behave exactly as if freshly typed at an Idle prompt.
        self.submit_input(&next);
    }

    /// WS5 — CC messageQueueManager.popAllEditable: move every queued message
    /// back into the composer (oldest first, joined by newlines, any current
    /// draft appended last) so a mistyped queued message can be edited before
    /// it fires. Cursor lands at the end.
    pub(crate) fn pop_queue_to_composer(&mut self) {
        if self.message_queue.is_empty() {
            return;
        }
        let items = std::mem::take(&mut self.message_queue);
        let joined = join_queued_for_composer(&items, self.input.value());
        self.input.reset();
        self.input.insert_str(&joined);
        self.input.set_queued_items(Vec::new());
        self.toasts.push(
            "Queued messages moved to composer".into(),
            crate::components::toast::ToastLevel::Info,
        );
        self.recompute_layout();
    }

    fn execute_shell(&mut self, cmd: &str) {
        if cmd.is_empty() {
            self.toasts.push(
                "Usage: !<command>".into(),
                crate::components::toast::ToastLevel::Warning,
            );
            return;
        }

        self.chat.add_system_message(&format!("$ {}", cmd), "shell");
        self.transition(AppState::Processing);
        self.activity.start();
        self.status.set_active(true);
        self.processing_start = Some(std::time::Instant::now());

        let client = self.client.clone();
        let tx = self.event_tx.clone();
        let session_id = self.session_id.clone();
        let shell_cmd = cmd.to_string();

        tokio::spawn(async move {
            let req = crate::client::types::CommandExecuteRequest {
                command: "shell".to_string(),
                arg: shell_cmd,
                session_id,
            };
            let result = client.execute_command(&req).await;
            let event = match result {
                Ok(resp) => BackendEvent::CommandResult(Ok(resp)),
                Err(e) => BackendEvent::CommandResult(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    pub(crate) fn submit_prompt(&mut self, text: &str) {
        // Safety net: commit any leftover collapsed tool run before the new turn.
        self.flush_collapse();
        self.chat.add_user_message(text);
        // WS5 — remember the outgoing prompt so an interrupt that lands before
        // any output can restore it into the composer (CC auto-restore).
        self.last_submitted_prompt = Some(text.to_string());
        if self.state != AppState::Processing {
            self.transition(AppState::Processing);
        }
        // A turn opens here and is not done until the backend says so.
        self.turn_done = false;
        self.activity.start();
        self.activity.set_model_name(self.header.model_name());
        self.status.set_active(true);
        // The turn is committed — drop the live pending-composer overlay so the
        // meter snaps back to the committed context (the backend now owns the
        // real size via context_pressure / note_input_tokens). Backstop for
        // submit paths that don't drain the composer first (commands, queue).
        self.status.set_pending_input_tokens(0);
        self.sidebar.set_context(self.status.display_context_ratio());
        // Fresh turn — clear any prior goal-verification indicator so it never
        // lingers into unrelated work.
        self.status.set_goal_verification(None);
        // Fresh turn — drop any prior fan-out's shared-scratchpad notes so they
        // never bleed into unrelated work (transient, scoped to the fan-out).
        self.agents.clear_scratchpad();
        self.processing_start = Some(std::time::Instant::now());
        // Fresh turn — drop the partial text AND the previous turn's
        // finalization record, so an identical answer this turn still renders.
        self.assistant_stream.reset();
        self.thinking_buf.clear();
        self.agent_header_sent = false;
        // Fresh turn — no foreground shell in flight yet. Guards against a stale
        // count if a prior turn ended without a matching tool-call-end.
        self.active_fg_shell_count = 0;

        // Send to backend
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        let session_id = self.session_id.clone();
        let input = text.to_string();
        let working_dir = if self.working_dir.is_empty() {
            None
        } else {
            Some(self.working_dir.clone())
        };
        // Orphan prune (CC PromptInput.tsx:1189-1200): a chip the user deleted
        // from the composer must not send its attachment — keep only
        // attachments whose [Image #N]/[File #N] token appears in the outgoing
        // text. Final gate covering every submit path (keys, voice, queue).
        self.prune_orphaned_attachments_in(text);
        // Collect pasted/dropped attachments for this turn, then clear them so the
        // next prompt starts fresh (the chips already left the input on submit).
        let mut wire_images: Vec<String> =
            self.attachments.iter().map(|a| a.wire_value()).collect();
        self.attachments.clear();
        // U-T1/U-T4 — consume the structured composer submit metadata. Drain the
        // `@`-mention attachments the composer resolved for this line
        // (`take_attachments` clears them so they never leak to a later turn) and
        // carry any real on-disk IMAGE mentions onto the same vision `images`
        // wire, so `@photo.png` now actually attaches instead of being only
        // inline text. `last_submit_kind` is consulted for logging only: SHELL
        // lines (`!cmd`) are already routed to the shell tool by `submit_input`
        // before this path, and MEMORY lines (`#note`) are intercepted at the
        // key layer — so here the kind is always Prompt. Non-image `@file`
        // (with optional `#L` range) and `@agent` mentions carry as structured
        // `context_refs` — the backend resolves each into a real context block
        // instead of relying on the mention's inline text alone.
        let mention_atts = self.input.take_attachments();
        let submit_kind = self.input.last_submit_kind();
        for p in crate::app::attachment::mention_image_paths(&mention_atts) {
            if std::path::Path::new(&p).is_file() && !wire_images.contains(&p) {
                wire_images.push(p);
            }
        }
        let context_refs = crate::app::attachment::mention_context_refs(&mention_atts);
        if !mention_atts.is_empty() {
            tracing::debug!(
                kind = ?submit_kind,
                mentions = mention_atts.len(),
                context_refs = context_refs.len(),
                "consumed composer submit metadata"
            );
        }
        // Every path in `wire_images` reached us through an explicit user
        // action: a drag-and-drop or a pasted path (`ingest_paste_as_attachments`),
        // a clipboard image (bytes, not a path), or an `@file` mention the user
        // typed. None of them is model-authored, so the turn is marked
        // `image_source = "user"` and the backend reads them from wherever they
        // live — a screenshot lands in $TMPDIR or on the Desktop, never inside
        // the workspace, and confining it there refused the owner's own
        // screenshots (v1.0.79). Sensitive files are still refused server-side.
        let (images, image_source) = if wire_images.is_empty() {
            (None, None)
        } else {
            (Some(wire_images), Some("user".to_string()))
        };
        let context_refs = if context_refs.is_empty() {
            None
        } else {
            Some(context_refs)
        };

        tokio::spawn(async move {
            let req = crate::client::types::OrchestrateRequest {
                input,
                session_id: Some(session_id),
                user_id: None,
                workspace_id: None,
                skip_plan: None,
                working_dir,
                images,
                image_source,
                context_refs,
            };
            let result = client.orchestrate(&req).await;
            let event = match result {
                Ok(resp) => BackendEvent::OrchestrateResult(Ok(resp)),
                Err(e) => BackendEvent::OrchestrateResult(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    pub(super) fn cancel_processing(&mut self) {
        self.cancelled = true;
        self.toasts.push(
            "Interrupting...".into(),
            crate::components::toast::ToastLevel::Info,
        );

        // A user interrupt also stops any active /goal auto-continue loop.
        if self.goal.is_some() {
            self.clear_goal(true);
        }

        // WS5 — the queue SURVIVES an interrupt (CC parity: clearCommandQueue
        // only runs in the kill-agents chord). Queued items either fire when
        // the cancel completes or can be popped into the composer with Esc/↑.

        // Immediately clear the agents panel so the UI reflects the interrupt
        self.agents.task_completed();
        self.recompute_layout();

        // Tell the backend to stop the agent loop (+ all sub-agents)
        let client = self.client.clone();
        let session_id = self.session_id.clone();
        let tx = self.event_tx.clone();
        tokio::spawn(async move {
            if let Err(e) = client.cancel_session(&session_id).await {
                tracing::warn!("Backend cancel failed: {}", e);
            }
            // Also cancel any active swarm
            // (swarm IDs not tracked here, backend cancel propagates to sub-agents)

            // The SSE stream will deliver the final "Cancelled by user." response,
            // which triggers handle_agent_response → resets UI to Idle.
            // If SSE doesn't fire within 3s, force-reset the UI.
            tokio::time::sleep(std::time::Duration::from_secs(3)).await;
            let _ = tx.send(Event::Backend(BackendEvent::CancelTimeout));
        });
    }

    /// Number of background turns still running (not yet completed).
    pub(crate) fn bg_running_count(&self) -> usize {
        self.bg_tasks.iter().filter(|t| !t.done).count()
    }

    /// Refresh every "background work" surface at once: the status-bar shell chip
    /// (running background bash jobs), the status-bar "N bg" chip (Ctrl+B'd turns),
    /// and the agents-panel "N background terminals · ↓ to manage" summary line.
    /// The summary is the combined count so ↓ always has something to manage.
    pub(crate) fn refresh_bg_indicators(&mut self) {
        self.status.set_shell_count(self.bg_shell_count);
        self.status.set_background_count(self.bg_running_count());
        self.agents
            .set_bg_summary(self.bg_running_count() + self.bg_shell_count);
    }

    /// Ctrl+B dispatcher. When a FOREGROUND shell command is running in this turn
    /// (Claude-Code parity), detach just that command to the background — it keeps
    /// running, joins the background panel, and notifies on completion. Otherwise
    /// fall back to backgrounding the whole turn.
    pub(super) fn background_or_detach(&mut self) {
        if self.state != AppState::Processing {
            return;
        }
        if self.active_fg_shell_count > 0 {
            self.detach_foreground_shell();
        } else {
            self.background_task();
        }
    }

    /// Ask the backend to promote the running foreground shell command to a
    /// supervised background task. Fire-and-forget: the result comes back as a
    /// `ShellDetached` backend event (toast + background-count update).
    fn detach_foreground_shell(&mut self) {
        self.toasts.push(
            "Moving command to background…".into(),
            crate::components::toast::ToastLevel::Info,
        );
        let client = self.client.clone();
        let session_id = self.session_id.clone();
        let tx = self.event_tx.clone();
        tokio::spawn(async move {
            let result = client
                .detach_shell(&session_id)
                .await
                .map_err(|e| e.to_string());
            let _ = tx.send(Event::Backend(BackendEvent::ShellDetached(result)));
        });
    }

    /// Ctrl+B — push the running turn to the background. The turn is NOT
    /// cancelled: it keeps running on the backend (the session SSE stream stays
    /// connected and its final answer still lands in scrollback). We record a
    /// real handle so `/bg` can list it and `/fg` can bring it back — no
    /// one-way dead-end.
    pub(super) fn background_task(&mut self) {
        if self.state != AppState::Processing {
            return;
        }
        // Summarize with the prompt that started this turn so `/bg` is legible.
        let summary = self
            .chat
            .last_user_message()
            .map(|m| {
                let one_line = m.replace('\n', " ");
                let trimmed = one_line.trim();
                // COLUMNS, not chars — see `crate::util::fit_cols`. A char-count
                // cut renders a CJK/emoji prompt at up to double the reserved
                // width and can sever a grapheme cluster mid-glyph.
                crate::util::fit_cols(trimmed, 60)
            })
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "background turn".to_string());

        self.bg_task_seq += 1;
        let id = self.bg_task_seq;
        self.bg_tasks.push(crate::app::BackgroundTask {
            id,
            summary,
            // Preserve the real turn start so the timer is accurate on bring-back.
            started_at: self.processing_start.unwrap_or_else(std::time::Instant::now),
            done: false,
        });
        self.refresh_bg_indicators();
        self.toasts.push(
            format!("Backgrounded [{}] — /fg to bring it back · /bg to list", id),
            crate::components::toast::ToastLevel::Info,
        );
        self.announce_a11y(&format!(
            "turn [{}] moved to background; type /fg to bring it back",
            id
        ));
        // Don't cancel processing — just detach the live activity view.
        self.activity.stop();
        self.status.set_active(false);
        self.transition(AppState::Idle);
    }

    /// `/fg` (and the agents dashboard bring-back) — re-attach the most recent
    /// still-running background turn to the foreground activity view. The turn
    /// never stopped, so this just re-shows the live indicator and restores the
    /// elapsed timer. If the turn already finished, its answer is in scrollback
    /// and we say so instead of pretending there's something to resume.
    pub(crate) fn foreground_task(&mut self) {
        // Newest running task first.
        let idx = self
            .bg_tasks
            .iter()
            .rposition(|t| !t.done);
        let Some(idx) = idx else {
            // Nothing running. If completed ones exist, their output already
            // landed in chat; otherwise there was never anything backgrounded.
            let msg = if self.bg_tasks.is_empty() {
                "No background tasks"
            } else {
                "No running background task — completed output is in the chat above"
            };
            self.toasts
                .push(msg.into(), crate::components::toast::ToastLevel::Info);
            return;
        };

        // Can't foreground while another turn is already visibly processing.
        if self.state == AppState::Processing {
            self.toasts.push(
                "A turn is already in the foreground".into(),
                crate::components::toast::ToastLevel::Warning,
            );
            return;
        }

        // It's the foreground turn again — drop the background handle so its
        // eventual completion flows through the normal foreground path (and the
        // running count reflects reality immediately).
        let task = self.bg_tasks.remove(idx);
        // Restore the live view for the still-running backend turn.
        self.processing_start = Some(task.started_at);
        self.activity.start();
        self.activity.set_model_name(self.header.model_name());
        self.status.set_active(true);
        self.transition(AppState::Processing);
        self.refresh_bg_indicators();
        self.toasts.push(
            format!("Foregrounded [{}] {}", task.id, task.summary),
            crate::components::toast::ToastLevel::Info,
        );
        self.announce_a11y(&format!("brought background turn [{}] to the foreground", task.id));
    }

    /// Mark the most recent still-running background turn as complete. Called
    /// when an agent response arrives while nothing is in the foreground — that
    /// response belongs to the backgrounded turn, whose output has now landed in
    /// scrollback. Keeps `/bg` and the status count honest.
    pub(super) fn complete_background_task(&mut self) {
        if let Some(task) = self.bg_tasks.iter_mut().rev().find(|t| !t.done) {
            task.done = true;
            let id = task.id;
            self.refresh_bg_indicators();
            self.toasts.push(
                format!("Background task [{}] finished — output is above", id),
                crate::components::toast::ToastLevel::Success,
            );
            self.announce_a11y(&format!("background task [{}] finished", id));
        }
    }

    pub fn check_health(&self) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        tokio::spawn(async move {
            let result = client.health().await;
            let event = match result {
                Ok(resp) => BackendEvent::HealthResult(Ok(resp)),
                Err(e) => BackendEvent::HealthResult(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    pub(super) fn do_login(&self) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        tokio::spawn(async move {
            let result = client.login(Some("local")).await;
            let event = match result {
                Ok(resp) => BackendEvent::LoginResult(Ok(resp)),
                Err(e) => BackendEvent::LoginResult(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    pub(super) fn load_commands(&self) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        tokio::spawn(async move {
            let result = client.list_commands().await;
            let event = match result {
                Ok(commands) => BackendEvent::CommandsLoaded(Ok(commands)),
                Err(e) => BackendEvent::CommandsLoaded(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    pub(crate) fn load_models(&self) {
        // Provider-first picker: load the provider catalog + detection status
        // (not the flat model list), so we can render ✓ ready / ⚠ needs-key.
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        tokio::spawn(async move {
            let result = client.onboarding_status().await;
            let event = match result {
                Ok(resp) => BackendEvent::ProviderPickerData(Ok(resp)),
                Err(e) => BackendEvent::ProviderPickerData(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    /// Account + quota for the picker's usage panel.
    ///
    /// Fired alongside the catalog rather than lazily on selection: both reads
    /// are pure (`/auth/status` never dials out, `/usage/quota` is a cache of
    /// response headers), so there is nothing to save by deferring, and a
    /// panel that populates as the cursor moves reads as flicker.
    ///
    /// Both halves are fetched before either is published, so the panel cannot
    /// show an account from one instant beside a quota window from another.
    pub(crate) fn load_provider_usage(&self) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        tokio::spawn(async move {
            let event = match (client.auth_status().await, client.usage_quota().await) {
                (Ok(a), Ok(q)) => BackendEvent::ProviderUsage(Ok((a, q))),
                (Err(e), _) | (_, Err(e)) => BackendEvent::ProviderUsage(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    /// Open the vendor-CLI sign-in screen and read the CLI's state into it.
    ///
    /// Also starts a fast repaint beat, scoped to the dialog's lifetime by the
    /// `alive` flag the dialog clears on drop. The app's own 200ms tick is
    /// fine for a spinner and much too slow for a terminal: a fifth of a
    /// second between a keystroke and its echo is the difference between
    /// typing into a program and fighting one.
    pub(crate) fn start_cli_login(&mut self, provider: String, model: String) {
        if let Some(picker) = self.model_picker.as_mut() {
            picker.begin_cli_login(provider, model);
        }
        let alive = match self.model_picker.as_ref().and_then(|p| p.cli_login_alive()) {
            Some(a) => a,
            None => return,
        };

        let tx = self.event_tx.clone();
        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(std::time::Duration::from_millis(50));
            loop {
                ticker.tick().await;
                if !alive.load(std::sync::atomic::Ordering::Relaxed) {
                    return;
                }
                if tx.send(Event::Backend(BackendEvent::CliLoginTick)).is_err() {
                    return;
                }
            }
        });

        self.refresh_cli_login();
    }

    /// Re-read `/auth/cli/claude`. The only way to learn whether a child that
    /// just exited actually changed anything.
    pub(crate) fn refresh_cli_login(&self) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        tokio::spawn(async move {
            let event = match client.claude_cli_state().await {
                Ok(s) => BackendEvent::ClaudeCliState(Ok(s)),
                Err(e) => BackendEvent::ClaudeCliState(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    /// Verify a candidate provider key live (picker key screen).
    pub(crate) fn verify_provider_key(
        &self,
        provider: String,
        api_key: Option<String>,
        model: String,
        base_url: Option<String>,
    ) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        tokio::spawn(async move {
            let body = serde_json::json!({
                "provider": provider,
                "api_key": api_key,
                "model": model,
                "base_url": base_url,
            });
            // The authenticated variant attaches a Bearer only when a token
            // exists and works in both contexts: post-onboarding (auth required
            // to pass through a candidate key) and first-run (backend permits
            // params for known providers without a token).
            let result = client.onboarding_health_check_auth(&body).await;
            let event = match result {
                Ok(resp) => BackendEvent::ModelPickerKeyVerified(Ok(resp)),
                Err(e) => BackendEvent::ModelPickerKeyVerified(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    /// Start an account sign-in and poll it to completion.
    ///
    /// The poll lives here rather than in the dialog because the dialog is
    /// redrawn synchronously and must never block. One task owns the whole
    /// grant: it starts the sign-in, then re-reads its state on a fixed
    /// interval and pushes each reading in as an event. The dialog is a pure
    /// renderer of those readings.
    ///
    /// Bounded at 15 minutes to match the backend's own deadline, so the task
    /// cannot outlive the thing it is watching — an orphaned poller against a
    /// swept session would spin on 404s for ever.
    pub(crate) fn start_account_login(&mut self, provider: String, model: String) {
        if let Some(picker) = self.model_picker.as_mut() {
            picker.begin_account_login(provider.clone(), model);
        }

        let client = self.client.clone();
        let tx = self.event_tx.clone();

        tokio::spawn(async move {
            let session = match client.auth_login_start(&provider).await {
                Ok(s) => s,
                Err(e) => {
                    let _ = tx.send(Event::Backend(BackendEvent::AccountLoginUpdate(Err(
                        e.to_string()
                    ))));
                    return;
                }
            };

            let id = session.id.clone();
            let terminal = |state: &str| {
                matches!(state, "connected" | "failed" | "cancelled")
            };
            let done = terminal(&session.state);
            let _ = tx.send(Event::Backend(BackendEvent::AccountLoginUpdate(Ok(session))));
            if done || id.is_empty() {
                return;
            }

            // One second: fast enough that the spinner reads as live and the
            // success is felt as immediate, slow enough that a fifteen-minute
            // grant is 900 cheap local requests rather than a busy loop.
            let mut ticker = tokio::time::interval(std::time::Duration::from_secs(1));
            let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(900);

            loop {
                ticker.tick().await;
                if tokio::time::Instant::now() >= deadline {
                    return;
                }
                match client.auth_login_status(&id).await {
                    Ok(s) => {
                        let done = terminal(&s.state);
                        let _ = tx.send(Event::Backend(BackendEvent::AccountLoginUpdate(Ok(s))));
                        if done {
                            return;
                        }
                    }
                    // A single failed poll is not a failed sign-in — the grant
                    // is running on the backend and one dropped request must
                    // not throw it away. Keep polling; the deadline bounds it.
                    Err(_) => continue,
                }
            }
        });
    }

    /// Best-effort cancel of an in-flight sign-in. Never reported to the user:
    /// the dialog has already closed, and the backend gives up on its own
    /// deadline regardless.
    pub(crate) fn cancel_account_login(&self, session_id: String) {
        let client = self.client.clone();
        tokio::spawn(async move {
            let _ = client.auth_login_cancel(&session_id).await;
        });
    }

    /// Persist a verified key (merging into .env) then switch to it.
    pub(crate) fn save_provider_key_and_switch(
        &self,
        provider: String,
        runtime_provider: String,
        api_key: Option<String>,
        model: String,
        base_url: Option<String>,
    ) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        let sid = self.session_id.clone();
        tokio::spawn(async move {
            let saved = client
                .providers_save_key(
                    &provider,
                    api_key.as_deref(),
                    base_url.as_deref(),
                    Some(&model),
                    true,
                )
                .await;
            match saved {
                Ok(_) => {
                    // Reflect the switch live in the UI header + context window
                    // AND on the live session's Loop GenServer — session-scoped
                    // so the current conversation actually uses the newly-saved
                    // key/model on its next turn (the global-only endpoint left
                    // an already-running session silently stuck on the old one).
                    let req = crate::client::types::ModelSwitchRequest {
                        provider: runtime_provider,
                        model: model.clone(),
                    };
                    let event = match client.switch_session_model(&sid, &req).await {
                        Ok(resp) => BackendEvent::ModelSwitched(Ok(resp)),
                        Err(e) => BackendEvent::ModelSwitched(Err(e.to_string())),
                    };
                    let _ = tx.send(Event::Backend(event));
                }
                Err(e) => {
                    let _ = tx.send(Event::Backend(BackendEvent::ModelSwitched(Err(
                        e.to_string()
                    ))));
                }
            }
        });
    }

    /// Fetch a provider's dynamic model list (miosa / ollama_local / custom).
    pub(crate) fn load_provider_models(
        &self,
        provider: String,
        base_url: Option<String>,
        api_key: Option<String>,
    ) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        tokio::spawn(async move {
            let result = client
                .onboarding_models(&provider, base_url.as_deref(), api_key.as_deref())
                .await;
            let event = match result {
                Ok(resp) => BackendEvent::ProviderModelsLoaded(Ok(resp)),
                Err(e) => BackendEvent::ProviderModelsLoaded(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    pub(crate) fn load_sessions(&self) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        tokio::spawn(async move {
            let result = client.list_sessions().await;
            let event = match result {
                Ok(sessions) => BackendEvent::SessionsLoaded(Ok(sessions)),
                Err(e) => BackendEvent::SessionsLoaded(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    /// Open the session browser populated from GET /api/v1/sessions/recent so
    /// past on-disk sessions show with real titles/counts (used by /resume).
    pub(crate) fn load_recent_sessions(&self) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        tokio::spawn(async move {
            let result = client.recent_sessions().await;
            let event = match result {
                Ok(sessions) => BackendEvent::SessionsLoaded(Ok(sessions)),
                Err(e) => BackendEvent::SessionsLoaded(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    /// Resolve a launch-time `osa resume <ref>` before switching to it.
    ///
    /// `switch_session` takes whatever id it is handed on faith, and
    /// `GET /:id/messages` answers 200 + `[]` for an id that was never a
    /// session — so resuming a typo used to be indistinguishable from resuming
    /// an empty conversation. Going through `/sessions/resolve` first turns
    /// "unknown id" and "ambiguous prefix" into explicit errors, and buys
    /// git-style short-prefix resume for free.
    pub(crate) fn resolve_and_switch_session(&mut self, session_ref: &str) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        let session_ref = session_ref.to_string();
        tokio::spawn(async move {
            let event = match client.resolve_session(&session_ref).await {
                Ok(id) => BackendEvent::SessionResolved(Ok(id)),
                Err(e) => BackendEvent::SessionResolved(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    /// Directory-scoped resume for the current working folder (used by /continue):
    /// POST /api/v1/sessions with { working_dir }, then switch to the returned
    /// session and pull its transcript back in via the SessionCreated handler.
    pub(crate) fn continue_session(&mut self) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        let working_dir = if self.working_dir.is_empty() {
            std::env::current_dir()
                .ok()
                .map(|p| p.display().to_string())
        } else {
            Some(self.working_dir.clone())
        };
        let working_dir = match working_dir {
            Some(dir) => dir,
            None => {
                self.toasts.push(
                    "Cannot determine working directory to continue".into(),
                    crate::components::toast::ToastLevel::Error,
                );
                return;
            }
        };
        tokio::spawn(async move {
            let result = client.resume_for_dir(working_dir).await;
            let event = match result {
                Ok(resp) => BackendEvent::SessionCreated(Ok(resp)),
                Err(e) => BackendEvent::SessionCreated(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    pub(super) fn load_tools(&self) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        tokio::spawn(async move {
            let result = client.list_tools().await;
            let event = match result {
                Ok(tools) => BackendEvent::ToolsLoaded(Ok(tools)),
                Err(e) => BackendEvent::ToolsLoaded(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    /// Fetch the backend's git-root-aware workspace identity so the status bar,
    /// terminal title, and welcome banner reflect the dir the agent actually
    /// operates in (not an independent launch-dir basename).
    pub(super) fn load_workspace_identity(&self) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        tokio::spawn(async move {
            let event = match client.get_workspace_identity().await {
                Ok(identity) => BackendEvent::WorkspaceIdentityLoaded(Ok(identity)),
                Err(e) => BackendEvent::WorkspaceIdentityLoaded(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    fn try_spawn_backend(&self) {
        let candidates: Vec<Option<std::path::PathBuf>> = vec![
            // From binary location: target/release/osagent → ../../.. = priv/rust/tui → ../../../ = root
            std::env::current_exe()
                .ok()
                .and_then(|p| {
                    p.parent()?.parent()?.parent()?.parent()?.parent()?.parent()
                        .map(|p| p.to_path_buf())
                }),
            // Stored project root
            std::fs::read_to_string(osa_home_dir().join(".osa/project_root"))
                .ok()
                .map(|s| std::path::PathBuf::from(s.trim())),
            // CWD
            std::env::current_dir().ok(),
        ];

        for candidate in candidates.into_iter().flatten() {
            if candidate.join("mix.exs").exists() {
                info!("Auto-starting backend from: {}", candidate.display());
                let project_dir = candidate;
                let log_dir = osa_home_dir().join(".osa/logs/backend.log");
                // The backend spawns from the mix.exs dir (the OSA source tree),
                // but its cwd source of truth must be the user's launch dir.
                // Export it so Cwd.set_original_cwd() captures the project.
                let original_cwd = self.working_dir.clone();
                std::thread::spawn(move || {
                    let log_file = std::fs::OpenOptions::new()
                        .create(true)
                        .append(true)
                        .open(&log_dir)
                        .ok();
                    let stdout = log_file
                        .as_ref()
                        .and_then(|f| f.try_clone().ok())
                        .map(std::process::Stdio::from)
                        .unwrap_or_else(std::process::Stdio::null);
                    let stderr = log_file
                        .map(|f| std::process::Stdio::from(f))
                        .unwrap_or_else(std::process::Stdio::null);
                    // On Windows the Elixir launcher is `mix.bat`; CreateProcess
                    // can't exec a batch file directly, so route through cmd.
                    // Unix keeps the bare `mix` path (behavior-preserving).
                    let mut command = if cfg!(windows) {
                        let mut c = std::process::Command::new("cmd");
                        c.args(["/C", "mix", "osa.serve"]);
                        c
                    } else {
                        let mut c = std::process::Command::new("mix");
                        c.arg("osa.serve");
                        c
                    };
                    let _ = command
                        .current_dir(&project_dir)
                        .env("OSA_ORIGINAL_CWD", &original_cwd)
                        .stdout(stdout)
                        .stderr(stderr)
                        .spawn();
                });
                return;
            }
        }
        warn!("Could not find project root to auto-start backend. \
               Run from the project directory or create ~/.osa/project_root");
    }

    pub(super) fn start_sse(&mut self) {
        // Cancel any previous SSE connection before starting a new one.
        if let Some(old_cancel) = self.sse_cancel.take() {
            old_cancel.cancel();
        }

        let tx = self.event_tx.clone();
        let session_id = self.session_id.clone();
        let base_url = self.config.base_url.clone();
        let client = self.client.clone();
        let cancel = tokio_util::sync::CancellationToken::new();
        self.sse_cancel = Some(cancel.clone());

        tokio::spawn(async move {
            if cancel.is_cancelled() {
                return;
            }

            let token = match client.token().await {
                Some(t) => t,
                None => {
                    warn!("No auth token for SSE");
                    return;
                }
            };

            if cancel.is_cancelled() {
                return;
            }

            let sse = crate::client::SseClient::with_cancel(
                session_id,
                base_url,
                token,
                tx,
                cancel,
            );
            sse.connect();
        });
    }

    pub(crate) fn show_help(&mut self) {
        self.chat.add_help_message();
    }

    pub(crate) fn switch_session(&mut self, session_id: &str) {
        // Cancel any active SSE connection
        if let Some(cancel) = self.sse_cancel.take() {
            cancel.cancel();
        }

        // Update session and clear state
        self.session_id = session_id.to_string();
        self.chat.clear();
        self.tasks.clear();
        self.assistant_stream.reset();
        self.thinking_buf.clear();
        self.pending_tool_args.clear();
        // Hook attribution is per-call and per-session; a switch abandons any
        // call still in flight, so its unclaimed runs must not follow us.
        self.hook_runs_for_call.clear();
        self.hook_runs_current_call = None;
        self.agent_header_sent = false;
        self.activity.stop();
        self.status.set_active(false);

        if self.state.is_processing() {
            self.transition(AppState::Idle);
        }

        // Load session history
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        let sid = session_id.to_string();
        tokio::spawn(async move {
            match client.get_session_messages(&sid).await {
                Ok(messages) => {
                    let _ = tx.send(Event::Backend(BackendEvent::SessionMessages(Ok(messages))));
                }
                Err(e) => {
                    let _ = tx.send(Event::Backend(BackendEvent::SessionMessages(Err(e.to_string()))));
                }
            }
        });

        // Reconnect SSE with new session
        self.start_sse();

        // `osa --continue --model X` / `osa --resume <id> --model X` resolve the
        // session through here rather than SessionCreated, so the session-scoped
        // override has to be applied on this path too (no-op when unset).
        self.apply_startup_model_override();

        self.toasts.push(
            format!("Switched to session {}", truncate_str(session_id, 16)),
            crate::components::toast::ToastLevel::Info,
        );
    }

    pub(crate) fn create_session(&mut self) {
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        // Always start FRESH (Claude-Code semantics): create with no working_dir so
        // the backend cannot directory-resume the folder's prior conversation. Past
        // chats for this folder are reachable on demand via /resume (picker) and
        // /continue (resume latest). The session still gets tagged to the folder at
        // first-message time (the post_response persistence hook records the
        // orchestrate working_dir), so it remains resumable later.
        tokio::spawn(async move {
            let result = client.create_session(None).await;
            let event = match result {
                Ok(resp) => BackendEvent::SessionCreated(Ok(resp)),
                Err(e) => BackendEvent::SessionCreated(Err(e.to_string())),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    /// Apply a `--model` / `--provider` launch flag to the session that just
    /// became current.
    ///
    /// SESSION-SCOPED on purpose. The boot-time resolution order is stacked
    /// against an environment variable — `Application` prefers
    /// `config.toml`/`config.json` over `OLLAMA_MODEL`, `Settings` writes env
    /// unconditionally, and the shell launcher re-sources `~/.osa/.env` — so on
    /// any machine where a model has ever been picked in the TUI an env-based
    /// override is simply ignored. `POST /sessions/:id/provider` swaps the LIVE
    /// loop instead, which is the thing that decides what the next turn calls,
    /// so the flag wins for this run without rewriting anything on disk.
    ///
    /// Fires at most once (`.take()`), so a later `/new` or `/resume` keeps the
    /// model the *user* chose rather than resurrecting a stale launch flag.
    pub(crate) fn apply_startup_model_override(&mut self) {
        let Some((provider, model)) = self.startup_model.take() else {
            return;
        };
        // An empty model means `--provider` was given alone; the backend fills in
        // that provider's default. An empty provider means `--model` was given
        // alone; the backend attributes the model to its owning provider.
        let req = crate::client::types::ModelSwitchRequest {
            provider: provider.unwrap_or_default(),
            model: model.clone(),
        };
        let client = self.client.clone();
        let tx = self.event_tx.clone();
        let sid = self.session_id.clone();
        tokio::spawn(async move {
            let event = match client.switch_session_model(&sid, &req).await {
                Ok(resp) => BackendEvent::ModelSwitched(Ok(resp)),
                Err(e) => BackendEvent::ModelSwitched(Err(format!(
                    "--model/--provider could not be applied: {}",
                    e
                ))),
            };
            let _ = tx.send(Event::Backend(event));
        });
    }

    pub(super) fn copy_last_message(&mut self) {
        if let Some(msg) = self.chat.last_agent_message() {
            // U-T7/U-T19 — layered clipboard cascade (native CLI → tmux buffer →
            // OSC 52). Works locally, over SSH, on headless boxes and through
            // tmux, unlike the old arboard-only path (local windowing only).
            // The outcome carries how much is actually KNOWN: OSC 52 cannot be
            // acknowledged, so an unverified send must not be reported as a
            // copy. `message()`/`level()` say exactly that, and an unconfirmed
            // payload is parked on disk so it is never unrecoverable.
            let outcome = crate::clipboard::copy(&msg);
            if outcome.confidence != crate::clipboard::Confidence::Confirmed {
                warn!(?outcome, "clipboard copy not confirmed");
            }
            self.toasts.push(outcome.message(), outcome.level());
        }
    }

    // ── Voice input ──────────────────────────────────────────────

    pub(crate) fn start_recording(&mut self) {
        if self.voice.recording {
            return;
        }
        // Don't allow recording while the LLM is processing
        if self.state == AppState::Processing {
            self.toasts.push(
                "Cannot record while processing".into(),
                crate::components::toast::ToastLevel::Warning,
            );
            return;
        }

        match crate::voice::VoiceCapture::start() {
            Ok(capture) => {
                self.voice.recording = true;
                self.voice.started_at = Some(std::time::Instant::now());
                self.voice.silence_start = None;
                self.voice.capture = Some(capture);
                self.transition(AppState::Recording);
                self.status.set_recording(true);
                self.input.set_recording(true);
                info!("Voice recording started");
            }
            Err(e) => {
                error!("Failed to start recording: {}", e);
                self.toasts.push(
                    format!("Mic error: {}", e),
                    crate::components::toast::ToastLevel::Error,
                );
            }
        }
    }

    pub(crate) fn stop_recording(&mut self) {
        if !self.voice.recording {
            return;
        }

        self.voice.recording = false;
        self.voice.silence_start = None;
        self.status.set_recording(false);
        self.input.set_recording(false);

        let capture = match self.voice.capture.take() {
            Some(c) => c,
            None => {
                if self.state == AppState::Recording {
                    self.transition(AppState::Idle);
                }
                return;
            }
        };

        let buffer = capture.stop();
        self.voice.started_at = None;

        if buffer.duration_secs() < 0.3 {
            self.toasts.push(
                "Recording too short".into(),
                crate::components::toast::ToastLevel::Warning,
            );
            if self.state == AppState::Recording {
                self.transition(AppState::Idle);
            }
            return;
        }

        // Transcribe in background
        let tx = self.event_tx.clone();
        let provider_debug = format!("{:?}", self.voice.provider);
        info!("Transcribing with {}", provider_debug);

        self.status.set_transcribing(true);
        self.toasts.push(
            "Transcribing...".into(),
            crate::components::toast::ToastLevel::Info,
        );

        // Spawn transcription based on provider type
        match &self.voice.provider {
            crate::voice::VoiceProvider::Cloud(c) => {
                let api_key = c.api_key().to_string();
                tokio::spawn(async move {
                    let transcriber = crate::voice::CloudTranscriber::new(api_key);
                    let result = transcriber.transcribe(buffer).await;
                    let event = match result {
                        Ok(text) => crate::event::VoiceEvent::TranscriptionReady(text),
                        Err(e) => crate::event::VoiceEvent::TranscriptionError(e.to_string()),
                    };
                    let _ = tx.send(crate::event::Event::Voice(event));
                });
            }
            crate::voice::VoiceProvider::Groq(g) => {
                let api_key = g.api_key().to_string();
                tokio::spawn(async move {
                    let transcriber = crate::voice::GroqTranscriber::new(api_key);
                    let result = transcriber.transcribe(buffer).await;
                    let event = match result {
                        Ok(text) => crate::event::VoiceEvent::TranscriptionReady(text),
                        Err(e) => crate::event::VoiceEvent::TranscriptionError(e.to_string()),
                    };
                    let _ = tx.send(crate::event::Event::Voice(event));
                });
            }
            crate::voice::VoiceProvider::Local(_) => {
                tokio::spawn(async move {
                    let provider = crate::voice::VoiceProvider::local_or_unavailable();
                    let result = provider
                        .transcribe_with_progress(buffer, Some(&tx))
                        .await;
                    let event = match result {
                        Ok(text) => crate::event::VoiceEvent::TranscriptionReady(text),
                        Err(e) => crate::event::VoiceEvent::TranscriptionError(e.to_string()),
                    };
                    let _ = tx.send(crate::event::Event::Voice(event));
                });
            }
        }
    }

    pub(crate) fn cancel_recording(&mut self) {
        if !self.voice.recording {
            return;
        }

        self.voice.recording = false;
        self.voice.started_at = None;
        self.voice.silence_start = None;
        self.status.set_recording(false);
        self.input.set_recording(false);

        // Drop capture, discarding audio
        if let Some(capture) = self.voice.capture.take() {
            drop(capture);
        }

        if self.state == AppState::Recording {
            self.transition(AppState::Idle);
        }
        self.toasts.push(
            "Recording cancelled".into(),
            crate::components::toast::ToastLevel::Info,
        );
        info!("Voice recording cancelled");
    }

    pub(crate) fn toggle_hands_free(&mut self) {
        self.voice.hands_free = !self.voice.hands_free;
        self.status.set_hands_free(self.voice.hands_free);

        if self.voice.hands_free {
            self.toasts.push(
                "Hands-free: ON (F9 to toggle)".into(),
                crate::components::toast::ToastLevel::Info,
            );
            // Start recording immediately when enabling hands-free
            if !self.voice.recording {
                self.start_recording();
            }
        } else {
            self.toasts.push(
                "Hands-free: OFF".into(),
                crate::components::toast::ToastLevel::Info,
            );
            // Cancel any active recording when disabling
            if self.voice.recording {
                self.cancel_recording();
            }
        }
        info!("Hands-free voice mode: {}", self.voice.hands_free);
    }

    // ── /goal auto-continue (cross-turn keep-going) ──────────────────────────

    /// Start (or replace) an active goal and kick off the first work turn.
    pub(crate) fn set_goal(&mut self, goal: &str) {
        let goal = goal.trim().to_string();
        if goal.is_empty() {
            return;
        }
        self.goal = Some(goal.clone());
        self.goal_cycle = 0;
        self.refresh_goal_status();
        self.chat.add_system_message(
            &format!(
                "Goal set — auto-continuing until achieved (max {} cycles). Reply DONE to stop. Use /goal off to cancel.\n→ {}",
                self.goal_max_cycles, goal
            ),
            "info",
        );
        // Kick off the first turn toward the goal.
        let prompt = self.goal_continue_prompt(&goal);
        self.goal_cycle = 1;
        self.refresh_goal_status();
        self.submit_prompt(&prompt);
    }

    /// Clear the active goal (from /goal off, cancel, DONE, or the cycle cap).
    pub(crate) fn clear_goal(&mut self, notify: bool) {
        let had_goal = self.goal.is_some();
        self.goal = None;
        self.goal_cycle = 0;
        self.status.set_goal_label(None);
        if notify && had_goal {
            self.chat.add_system_message("Goal cleared.", "info");
        }
    }

    /// Show the current goal status without changing it.
    pub(crate) fn show_goal_status(&mut self) {
        match self.goal.clone() {
            Some(goal) => {
                self.chat.add_system_message(
                    &format!(
                        "Active goal (cycle {}/{}):\n→ {}",
                        self.goal_cycle, self.goal_max_cycles, goal
                    ),
                    "info",
                );
            }
            None => {
                self.chat.add_system_message(
                    "No active goal. Set one with /goal <text>.",
                    "info",
                );
            }
        }
    }

    /// The continue prompt sent on each cycle toward the goal.
    fn goal_continue_prompt(&self, goal: &str) -> String {
        format!(
            "Continue toward the goal: {}. When the goal is fully achieved, reply with exactly DONE on its own line and stop.",
            goal
        )
    }

    /// Sync the status-bar "goal N/max" indicator with the current state.
    fn refresh_goal_status(&mut self) {
        if self.goal.is_some() {
            self.status.set_goal_label(Some(format!(
                "goal {}/{}",
                self.goal_cycle, self.goal_max_cycles
            )));
        } else {
            self.status.set_goal_label(None);
        }
    }

    /// True when the assistant reply signals the goal is achieved. The sentinel
    /// must be the *last* non-empty line of the reply (or the whole reply),
    /// matching the `goal_continue_prompt` instruction to "reply with exactly
    /// DONE on its own line and stop". Requiring the final line avoids false
    /// positives from an intermediate turn that merely mentions a standalone
    /// `DONE` line mid-reply — e.g. narrating `echo DONE`, a build-log line, a
    /// checklist item, quoted code, or restating the instruction itself.
    fn reply_signals_done(reply: &str) -> bool {
        reply
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty())
            .next_back()
            .map(|line| line == "DONE")
            .unwrap_or(false)
    }

    /// Called at the end of each assistant turn. If a goal is active, either
    /// stop (DONE / cap reached) or auto-submit the next continue prompt.
    pub(super) fn maybe_continue_goal(&mut self) {
        let goal = match self.goal.clone() {
            Some(g) => g,
            None => return,
        };
        // Don't auto-continue if the user cancelled this turn.
        if self.cancelled {
            self.clear_goal(true);
            return;
        }

        let last_reply = self.chat.last_agent_message().unwrap_or_default();
        if Self::reply_signals_done(&last_reply) {
            self.chat.add_system_message(
                &format!("Goal achieved in {} cycle(s). Auto-continue stopped.", self.goal_cycle),
                "info",
            );
            self.clear_goal(false);
            return;
        }

        if self.goal_cycle >= self.goal_max_cycles {
            self.chat.add_system_message(
                &format!(
                    "Goal auto-continue reached the {}-cycle cap without a DONE. Stopping. Use /goal <text> to resume.",
                    self.goal_max_cycles
                ),
                "warning",
            );
            self.clear_goal(false);
            return;
        }

        self.goal_cycle += 1;
        self.refresh_goal_status();
        let prompt = self.goal_continue_prompt(&goal);
        self.submit_prompt(&prompt);
    }
}

/// Resolve the user's home dir cross-platform. BaseDirs honors USERPROFILE /
/// HOMEDRIVE+HOMEPATH on Windows (where $HOME is normally unset) and $HOME on
/// unix, falling back to $HOME then "." — so backend auto-start paths land under
/// the real profile instead of the drive root on Windows.
fn osa_home_dir() -> std::path::PathBuf {
    directories::BaseDirs::new()
        .map(|d| d.home_dir().to_path_buf())
        .or_else(|| std::env::var("HOME").ok().map(std::path::PathBuf::from))
        .unwrap_or_else(|| std::path::PathBuf::from("."))
}

/// Best-effort extraction of the HTTP port the TUI is trying to reach, so the
/// "backend unreachable" toast can name a copy-pasteable diagnostic command.
/// Parses the port out of the client's base_url (e.g. "http://localhost:9089");
/// falls back to $OSA_HTTP_PORT and finally the compiled default (9089).
fn port_from_base_url(base_url: &str) -> String {
    // Trim scheme, then take host:port before any path, and grab the ":port".
    let after_scheme = base_url.split("://").nth(1).unwrap_or(base_url);
    let authority = after_scheme.split('/').next().unwrap_or(after_scheme);
    if let Some(port) = authority.rsplit(':').next() {
        if !port.is_empty() && port.chars().all(|c| c.is_ascii_digit()) {
            return port.to_string();
        }
    }
    std::env::var("OSA_HTTP_PORT").unwrap_or_else(|_| "9089".to_string())
}

/// Read user name from ~/.osa/USER.md (sync, for welcome message)
pub fn read_user_name_sync() -> Option<String> {
    let home = std::env::var("HOME").ok()?;
    let path = format!("{}/.osa/USER.md", home);
    let content = std::fs::read_to_string(&path).ok()?;

    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("- **Name:**") {
            let name = trimmed.trim_start_matches("- **Name:**").trim();
            if !name.is_empty() {
                return Some(name.to_string());
            }
        }
    }
    None
}

/// WS5 — the backend ends an interrupted turn with one of these synthetic
/// user-marker strings. Kept in sync with
/// `OptimalSystemAgent.Agent.Loop.ReactLoop.interrupt_markers/0`.
pub(crate) fn is_interrupt_marker(s: &str) -> bool {
    matches!(
        s,
        "[Request interrupted by user]" | "[Request interrupted by user for tool use]"
    )
}

/// WS5 — composer content after pop-all-editable: queued items oldest-first,
/// then the current draft (if any), joined by newlines (CC popAllEditable).
pub(crate) fn join_queued_for_composer(items: &[String], current: &str) -> String {
    let mut parts: Vec<String> = items.to_vec();
    if !current.trim().is_empty() {
        parts.push(current.to_string());
    }
    parts.join("\n")
}

/// Whether to drop the one-time "update available" transcript notice on this
/// health response. True only when the backend flags an available update AND we
/// haven't already shown it this session — keeping it quiet (once, never a nag).
pub(crate) fn should_show_update_notice(
    update: Option<&crate::client::types::HealthUpdate>,
    already_shown: bool,
) -> bool {
    !already_shown && matches!(update, Some(u) if u.available)
}

/// The understated update-notice line (Codex `UpdateAvailableHistoryCell`
/// style): `✨ Update available: vX → vY  ·  type /update to install`. When the
/// latest version is unknown the arrow is dropped. Names `/update` so the user
/// runs it themselves — OSA never auto-installs.
pub(crate) fn update_notice_line(update: &crate::client::types::HealthUpdate) -> String {
    let latest = update.latest_version.as_deref().unwrap_or("").trim();
    if latest.is_empty() {
        "\u{2728} Update available  \u{00b7}  type /update to install".to_string()
    } else {
        format!(
            "\u{2728} Update available: v{} \u{2192} v{}  \u{00b7}  type /update to install",
            update.current_version.trim(),
            latest
        )
    }
}


/// Whether a queued message may be auto-submitted now.
///
/// Extracted as a free function for one reason: it is the decision that a
/// queued `/overdrive` had to be typed twice for, and inside a method on `App`
/// it could not be tested at all — nothing in this crate can construct an
/// `App`, so the only "tests" available were ones that restated the code.
///
/// Both conditions are load-bearing and neither implies the other.
///
/// `Idle` says the composer is free. It is NOT sufficient on its own:
/// `handle_agent_response` runs full turn teardown — including the
/// Processing → Idle transition — on EVERY agent_response, and one turn can
/// emit several (text → subagent/tool → more text). So the state read Idle
/// while the turn was genuinely still running, and the drain fired a queued
/// message straight into it, where it applied to session state the real turn
/// end then overwrote. Reproducing it needed a multi-generation turn, which is
/// why it was intermittent.
///
/// `turn_done` says the turn is over. It is NOT sufficient on its own either:
/// it stays true through the dialog states (Permissions / PlanReview / Survey)
/// that route through the same completion handlers, and draining under an open
/// dialog would fire a message the user is still being asked about.
pub(crate) fn queue_may_drain(state: AppState, turn_done: bool) -> bool {
    state == AppState::Idle && turn_done
}

#[cfg(test)]
mod update_notice_tests {
    use super::{should_show_update_notice, update_notice_line};
    use crate::client::types::HealthUpdate;

    fn upd(available: bool, latest: Option<&str>) -> HealthUpdate {
        HealthUpdate {
            available,
            current_version: "0.4.6".to_string(),
            latest_version: latest.map(|s| s.to_string()),
        }
    }

    #[test]
    fn notice_shows_once_per_session() {
        let update = upd(true, Some("0.5.0"));
        // First health response with an available update → show it.
        assert!(should_show_update_notice(Some(&update), false));
        // Every subsequent poll (flag now set) → suppressed.
        assert!(!should_show_update_notice(Some(&update), true));
    }

    #[test]
    fn notice_suppressed_when_no_update_or_up_to_date() {
        // No update object at all.
        assert!(!should_show_update_notice(None, false));
        // Object present but not available (up to date / source build).
        assert!(!should_show_update_notice(Some(&upd(false, None)), false));
    }

    #[test]
    fn notice_line_names_update_command_and_versions() {
        let line = update_notice_line(&upd(true, Some("0.5.0")));
        assert!(line.contains("Update available"));
        assert!(line.contains("v0.4.6"));
        assert!(line.contains("v0.5.0"));
        assert!(line.contains("/update"), "must point the user at /update");
    }

    #[test]
    fn notice_line_drops_arrow_when_latest_unknown() {
        let line = update_notice_line(&upd(true, None));
        assert!(line.contains("Update available"));
        assert!(!line.contains("\u{2192}"), "no arrow without a known latest");
        assert!(line.contains("/update"));
    }
}

#[cfg(test)]
mod interrupt_steer_tests {
    use super::{is_interrupt_marker, join_queued_for_composer};

    #[test]
    fn recognizes_both_interrupt_markers() {
        assert!(is_interrupt_marker("[Request interrupted by user]"));
        assert!(is_interrupt_marker("[Request interrupted by user for tool use]"));
    }

    #[test]
    fn ordinary_text_is_not_a_marker() {
        assert!(!is_interrupt_marker("Cancelled by user."));
        assert!(!is_interrupt_marker("[Request interrupted by user] extra"));
    }

    #[test]
    fn pop_joins_queued_items_with_newlines() {
        let items = vec!["first".to_string(), "second".to_string()];
        assert_eq!(join_queued_for_composer(&items, ""), "first\nsecond");
    }

    #[test]
    fn pop_appends_current_draft_last() {
        let items = vec!["queued".to_string()];
        assert_eq!(join_queued_for_composer(&items, "draft"), "queued\ndraft");
    }

    #[test]
    fn pop_drops_blank_draft() {
        let items = vec!["queued".to_string()];
        assert_eq!(join_queued_for_composer(&items, "   "), "queued");
    }
}

#[cfg(test)]
mod goal_done_tests {
    use super::App;

    #[test]
    fn done_only_when_final_nonempty_line() {
        // Whole reply is exactly the sentinel.
        assert!(App::reply_signals_done("DONE"));
        assert!(App::reply_signals_done("DONE\n"));
        // Sentinel as the last non-empty line (trailing whitespace/blanks ok).
        assert!(App::reply_signals_done("All checks pass.\nDONE"));
        assert!(App::reply_signals_done("finished\n  DONE  \n\n"));
    }

    #[test]
    fn not_done_when_sentinel_is_mid_reply() {
        // Intermediate turns that merely mention a standalone DONE line must
        // NOT stop the goal loop prematurely.
        assert!(!App::reply_signals_done("Running: echo DONE\nNow building..."));
        assert!(!App::reply_signals_done(
            "Step 1: DONE\nStep 2: still working on the migration"
        ));
        assert!(!App::reply_signals_done(
            "The instruction says to reply with exactly DONE on its own line.\nContinuing."
        ));
        assert!(!App::reply_signals_done(""));
        assert!(!App::reply_signals_done("done"));
        assert!(!App::reply_signals_done("DONE deal, moving on"));
    }
}

// ── the gate behind the queued-/overdrive bug ───────────────────────────────
#[cfg(test)]
mod queue_gate_tests {
    use super::queue_may_drain;
    use crate::app::AppState;

    #[test]
    fn a_finished_turn_at_an_idle_prompt_drains() {
        assert!(queue_may_drain(AppState::Idle, true));
    }

    #[test]
    fn an_idle_state_mid_turn_does_not_drain() {
        // The actual bug: teardown sets Idle on every agent_response, and a
        // turn emits several. Idle alone let a queued message into a live turn.
        assert!(!queue_may_drain(AppState::Idle, false));
    }

    #[test]
    fn a_finished_turn_under_an_open_dialog_does_not_drain() {
        // turn_done survives into the dialog states that route through the same
        // completion handlers; draining here fires a message the user is still
        // being asked about.
        for state in [AppState::Processing, AppState::Quit] {
            assert!(
                !queue_may_drain(state, true),
                "{state:?} must hold the queue"
            );
        }
    }

    #[test]
    fn neither_condition_implies_the_other() {
        // Guards against a future simplification collapsing the two checks into
        // one — each has a state the other does not cover.
        assert!(!queue_may_drain(AppState::Idle, false));
        assert!(!queue_may_drain(AppState::Processing, true));
        assert!(!queue_may_drain(AppState::Processing, false));
        assert!(queue_may_drain(AppState::Idle, true));
    }
}
