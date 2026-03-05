use crate::app::state::AppState;
use crate::components::activity::ProcessingPhase;
use crate::event::backend::BackendEvent;
use tracing::{debug, error, info, warn};

use super::App;

impl App {
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
                if let Some(err) = error {
                    warn!("SSE disconnected: {}", err);
                }
                self.sse_reconnecting = true;
            }
            BackendEvent::SseReconnecting { attempt } => {
                debug!("SSE reconnecting (attempt {})", attempt);
                self.sse_reconnecting = true;
            }
            BackendEvent::StreamingToken { text, .. } => {
                if self.state.is_processing() {
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
                self.handle_agent_response(response, signal);
            }
            BackendEvent::ToolCallStart { name, args } => {
                if !self.activity.is_active() {
                    self.activity.start();
                }
                self.activity.tool_start(&name, &args);
                self.activity.set_phase(ProcessingPhase::ToolCall);
                // Stash args so ToolCallEnd can build a rich summary
                self.pending_tool_args.insert(name.clone(), args);
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

                // Build rich styled tool summary for the chat
                let args = self
                    .pending_tool_args
                    .remove(&name)
                    .unwrap_or_default();
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
                        lines,
                    });
                }

                debug!(
                    "Tool call end: {} ({}ms, success={})",
                    name, duration_ms, success
                );
            }
            BackendEvent::ToolResult {
                name, result, success,
            } => {
                // Attach result to last matching tool message for expand support
                if !result.is_empty() {
                    self.chat.update_last_tool_result(&name, &result);
                }
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
            } => {
                self.status
                    .set_context(utilization, estimated_tokens, max_tokens);
                self.sidebar.set_context(utilization);
            }
            BackendEvent::TaskCreated {
                task_id,
                subject,
                active_form: _,
            } => {
                self.tasks.add(task_id.clone(), subject, String::new());
                self.recompute_layout();
            }
            BackendEvent::TaskUpdated { task_id, status } => {
                self.tasks.update(&task_id, &status);
            }
            BackendEvent::CommandsLoaded(result) => match result {
                Ok(commands) => {
                    let names: Vec<String> =
                        commands.iter().map(|c| c.name.clone()).collect();
                    self.input.set_commands(names);
                    self.command_entries = commands;
                }
                Err(e) => warn!("Failed to load commands: {}", e),
            },
            BackendEvent::ToolsLoaded(result) => match result {
                Ok(tools) => {
                    self.header.set_tool_count(tools.len());
                    self.sidebar.set_tool_count(tools.len());
                    // Update welcome screen tool inventory
                    self.chat.set_welcome_info(
                        self.header.provider(),
                        self.header.model_name(),
                        tools.len(),
                    );
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
                }
            },
            BackendEvent::CommandResult(result) => {
                self.handle_command_result(result);
            }
            BackendEvent::ModelSwitched(result) => match result {
                Ok(resp) => {
                    self.header.set_provider_info(&resp.provider, &resp.model);
                    self.status.set_provider_info(&resp.provider, &resp.model);
                    self.chat.set_welcome_info(
                        &resp.provider,
                        &resp.model,
                        self.header.tool_count(),
                    );
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
                    self.session_id = resp.id;
                    self.chat.clear();
                    self.tasks.clear();
                    self.stream_buf.clear();
                    self.thinking_buf.clear();
                    self.toasts.push(
                        "New session".into(),
                        crate::components::toast::ToastLevel::Info,
                    );
                }
                Err(e) => {
                    self.toasts.push(
                        format!("Session create failed: {}", e),
                        crate::components::toast::ToastLevel::Error,
                    );
                }
            },
            // === Models/Sessions loaded (dialog triggers) ===
            BackendEvent::ModelsLoaded(result) => match result {
                Ok(resp) => {
                    let picker = crate::dialogs::model_picker::ModelPicker::new(
                        resp.models,
                        Vec::new(),
                    );
                    self.model_picker = Some(picker);
                    self.transition(AppState::ModelPicker);
                }
                Err(e) => {
                    self.toasts.push(
                        format!("Failed to load models: {}", e),
                        crate::components::toast::ToastLevel::Error,
                    );
                }
            },
            BackendEvent::SessionsLoaded(result) => match result {
                Ok(sessions) => {
                    let browser = crate::dialogs::sessions::SessionBrowser::new(
                        sessions,
                        self.session_id.clone(),
                    );
                    self.session_browser = Some(browser);
                    self.transition(AppState::Sessions);
                }
                Err(e) => {
                    self.toasts.push(
                        format!("Failed to load sessions: {}", e),
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
            BackendEvent::OrchestratorTaskAppraised { .. } => {
                // Appraisal info is informational only; no UI state change needed.
            }
            BackendEvent::OrchestratorAgentStarted { agent_name, role, model, subject } => {
                self.agents.agent_started(&agent_name, &role, &model, &subject);
                let display = if role.is_empty() { agent_name.clone() } else { format!("{}/{}", agent_name, role) };
                self.sidebar.set_current_agent(display);
                self.recompute_layout();
            }
            BackendEvent::OrchestratorAgentProgress { agent_name, current_action, tool_uses, tokens_used, subject } => {
                self.agents.agent_progress(&agent_name, &current_action, tool_uses, tokens_used, &subject);
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

            BackendEvent::SseAuthFailed => {
                error!("SSE auth failed — token may be expired");
                self.toasts.push(
                    "SSE auth failed. Try /login to re-authenticate.".into(),
                    crate::components::toast::ToastLevel::Error,
                );
            }
            BackendEvent::ParseWarning { message } => {
                warn!("SSE parse warning: {}", message);
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
            BackendEvent::OnboardingStatus(result) => match result {
                Ok(resp) => {
                    if resp.needs_onboarding {
                        info!("Onboarding needed — showing setup wizard");
                        let data = crate::dialogs::onboarding::OnboardingData {
                            providers: resp.providers,
                            templates: resp.templates,
                            machines: resp.machines,
                            channels: resp.channels,
                            system_info: resp.system_info,
                        };
                        self.onboarding = Some(
                            crate::dialogs::onboarding::OnboardingWizard::new(data),
                        );
                        if self.state.can_transition_to(AppState::Onboarding) {
                            self.transition(AppState::Onboarding);
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
                        self.chat.scroll_to_bottom();
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
                    self.header.set_provider_info(&resp.provider, &resp.model);
                    self.status.set_provider_info(&resp.provider, &resp.model);
                    self.onboarding = None;
                    if self.state == AppState::Onboarding {
                        self.transition(AppState::Idle);
                    }
                }
                Err(e) => {
                    self.toasts.push(
                        format!("Onboarding failed: {}", e),
                        crate::components::toast::ToastLevel::Error,
                    );
                }
            },
            BackendEvent::PermissionRequired { tool, args, request_id: _ } => {
                // Show the permission dialog — transition from Processing (or Idle) to Permissions.
                let mut dialog = crate::dialogs::permissions::Permissions::new();
                dialog.set_tool(tool, args, String::new());
                self.permissions = Some(dialog);
                if self.state.can_transition_to(AppState::Permissions) {
                    self.transition(AppState::Permissions);
                }
            }
            BackendEvent::PlanProposed { plan, request_id: _ } => {
                // Show the plan review dialog — backend paused for user approval.
                let mut review = crate::dialogs::plan_review::PlanReview::new();
                review.set_plan(plan);
                self.plan_review = Some(review);
                if self.state.can_transition_to(AppState::PlanReview) {
                    self.transition(AppState::PlanReview);
                }
            }
            BackendEvent::CancelTimeout => {
                // Safety net: if the backend cancel response never came via SSE,
                // force the UI back to idle so the user isn't stuck.
                if self.cancelled && self.state.is_processing() {
                    info!("Cancel timeout — forcing UI back to Idle");
                    self.chat.clear_streaming();
                    self.stream_buf.clear();
                    self.thinking_buf.clear();
                    self.activity.stop();
                    self.status.set_active(false);
                    self.cancelled = false;
                    self.transition(AppState::Idle);
                    self.toasts.push(
                        "Cancelled (backend did not respond)".into(),
                        crate::components::toast::ToastLevel::Warning,
                    );
                }
            },
        }
        false
    }
}
