use futures::StreamExt;
use reqwest::Client as HttpClient;
use std::time::Duration;
use tokio::io::AsyncBufReadExt;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;
use tracing::{error, warn};

use super::types::Signal;
use crate::event::backend::BackendEvent;
use crate::event::Event;

const MAX_RECONNECTS: u32 = 10;
const MAX_LINE_BYTES: usize = 1024 * 1024; // 1 MB

/// SSE client that connects to the backend event stream and dispatches
/// parsed events through a channel.
pub struct SseClient {
    session_id: String,
    base_url: String,
    token: String,
    event_tx: mpsc::UnboundedSender<Event>,
    cancel: CancellationToken,
}

impl SseClient {
    /// Construct with a pre-existing cancellation token. Use this when the
    /// caller needs to hold a cancel handle before the client is started
    /// (e.g. when the auth token is fetched asynchronously after the cancel
    /// token is stored in app state).
    pub fn with_cancel(
        session_id: String,
        base_url: String,
        token: String,
        event_tx: mpsc::UnboundedSender<Event>,
        cancel: CancellationToken,
    ) -> Self {
        Self {
            session_id,
            base_url,
            token,
            event_tx,
            cancel,
        }
    }

    /// Returns a cancellation token that can be used to stop the SSE stream.
    // Phase 2: expose for external cancel control (e.g., reconnect-on-session-switch)
    #[allow(dead_code)]
    pub fn cancel_token(&self) -> CancellationToken {
        self.cancel.clone()
    }

    /// Wrap a BackendEvent in Event::Backend and send through channel.
    fn send(&self, be: BackendEvent) -> Result<(), mpsc::error::SendError<Event>> {
        self.event_tx.send(Event::Backend(be))
    }

    /// Spawn a tokio task that connects to the SSE stream and sends parsed
    /// events through the channel. Reconnects with exponential backoff on
    /// disconnect.
    pub fn connect(self) -> tokio::task::JoinHandle<()> {
        tokio::spawn(async move {
            self.run_with_reconnect().await;
        })
    }

    async fn run_with_reconnect(&self) {
        let mut attempt: u32 = 0;

        loop {
            if self.cancel.is_cancelled() {
                return;
            }

            match self.connect_once().await {
                Ok(()) => {
                    // Clean/graceful close: the server closed the stream body
                    // (EOF) or restarted. This is DISTINCT from a user cancel —
                    // the client should re-attach a fresh stream. Tag it "closed"
                    // so the handler reconnects instead of wedging on a permanent
                    // "Reconnecting…" banner.
                    let _ = self.send(BackendEvent::SseDisconnected {
                        error: Some("closed".to_string()),
                    });
                    return;
                }
                Err(SseError::AuthFailed) => {
                    let _ = self.send(BackendEvent::SseAuthFailed);
                    return;
                }
                Err(SseError::Cancelled) => {
                    // Client-initiated cancel (shutdown / session switch). Do NOT
                    // reconnect — tag it "cancelled" so the handler stays quiet.
                    let _ = self.send(BackendEvent::SseDisconnected {
                        error: Some("cancelled".to_string()),
                    });
                    return;
                }
                Err(SseError::Disconnected { err: e, connected }) => {
                    // D5: a drop that occurred AFTER the stream attached resets
                    // the budget (a recovered blip must not accumulate toward
                    // exhaustion); only genuine back-to-back connect FAILURES
                    // that never reached the body burn it.
                    attempt = next_reconnect_attempt(attempt, connected);
                    if attempt > MAX_RECONNECTS {
                        error!(
                            "SSE reconnect failed after {} attempts: {:?}",
                            MAX_RECONNECTS, e
                        );
                        // Reconnect budget exhausted — surface an honest terminal
                        // error ("exhausted") so the UI can stop the spinner and
                        // tell the user, rather than a silent forever-"Reconnecting".
                        let _ = self.send(BackendEvent::SseDisconnected {
                            error: Some("exhausted".to_string()),
                        });
                        return;
                    }

                    let _ = self.send(BackendEvent::SseReconnecting { attempt });

                    // Exponential backoff: 2, 4, 8, 16, 30, 30, ...
                    let shift = attempt.min(5);
                    let backoff_secs = (1u64 << shift).min(30);
                    let backoff = Duration::from_secs(backoff_secs);

                    warn!(
                        "SSE disconnected (attempt {}/{}), retrying in {}s: {:?}",
                        attempt,
                        MAX_RECONNECTS,
                        backoff_secs,
                        e
                    );

                    tokio::select! {
                        _ = tokio::time::sleep(backoff) => {}
                        _ = self.cancel.cancelled() => {
                            let _ = self.send(BackendEvent::SseDisconnected {
                                error: Some("cancelled".to_string()),
                            });
                            return;
                        }
                    }
                }
            }
        }
    }

    /// Single connection attempt. Returns Ok(()) on clean close, Err on failure.
    async fn connect_once(&self) -> std::result::Result<(), SseError> {
        let url = format!(
            "{}/api/v1/stream/{}",
            self.base_url, self.session_id
        );

        // No total-request timeout for SSE long-polling — the stream is
        // intentionally long-lived. Duration::from_secs(0) is NOT "no
        // timeout": reqwest wraps it in a tokio::time::sleep(Duration::ZERO)
        // which fires on the first poll, immediately killing the body stream.
        // Omitting .timeout() leaves reqwest at its default (no timeout).
        let http = HttpClient::builder()
            .build()
            .map_err(|e| SseError::Disconnected { err: e.into(), connected: false })?;

        let mut req = http
            .get(&url)
            .header("Accept", "text/event-stream")
            .header("Cache-Control", "no-cache");

        if !self.token.is_empty() {
            req = req.header("Authorization", format!("Bearer {}", self.token));
        }

        let resp = req
            .send()
            .await
            .map_err(|e| SseError::Disconnected { err: e.into(), connected: false })?;

        let status = resp.status();
        if status == reqwest::StatusCode::UNAUTHORIZED
            || status == reqwest::StatusCode::FORBIDDEN
        {
            return Err(SseError::AuthFailed);
        }
        if !status.is_success() {
            return Err(SseError::Disconnected {
                err: anyhow::anyhow!("SSE stream returned {}", status),
                connected: false,
            });
        }

        // Signal connected
        let _ = self.send(BackendEvent::SseConnected {
            session_id: self.session_id.clone(),
        });

        // Read the stream line by line
        let byte_stream = resp.bytes_stream();
        let stream_reader = tokio_util::io::StreamReader::new(
            byte_stream.map(|result| {
                result.map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))
            }),
        );
        let mut lines = tokio::io::BufReader::with_capacity(MAX_LINE_BYTES, stream_reader).lines();

        let mut event_type = String::new();

        loop {
            tokio::select! {
                _ = self.cancel.cancelled() => {
                    return Err(SseError::Cancelled);
                }
                line = lines.next_line() => {
                    match line {
                        Ok(Some(line)) => {
                            if line.is_empty() {
                                // Empty line resets event type (end of event block)
                                event_type.clear();
                            } else if line.starts_with(':') {
                                // Keepalive comment, ignore
                            } else if let Some(et) = line.strip_prefix("event: ") {
                                event_type = et.to_string();
                            } else if let Some(data) = line.strip_prefix("data: ") {
                                if let Some(be) = parse_sse_event(&event_type, data.as_bytes()) {
                                    if self.send(be).is_err() {
                                        // Receiver dropped
                                        return Ok(());
                                    }
                                }
                            }
                        }
                        Ok(None) => {
                            // Stream ended
                            return Ok(());
                        }
                        Err(e) => {
                            // Read failure AFTER the body attached — a mid-stream
                            // drop that the reconnect loop can recover cheaply.
                            return Err(SseError::Disconnected { err: e.into(), connected: true });
                        }
                    }
                }
            }
        }
    }
}

/// Next reconnect-attempt counter after a stream failure. A failure that
/// happened after the body attached (`connected`) restarts the budget at 1 so a
/// recovered mid-stream blip never accumulates toward "exhausted"; a pre-attach
/// connect failure increments the running count. Pure + unit-testable.
fn next_reconnect_attempt(attempt: u32, connected: bool) -> u32 {
    if connected {
        1
    } else {
        attempt + 1
    }
}

#[derive(Debug)]
enum SseError {
    AuthFailed,
    Cancelled,
    /// A network/stream failure. `connected` is true when the failure happened
    /// AFTER the stream body was successfully attached (a mid-stream drop), so
    /// the reconnect loop can reset its backoff budget for a recovered blip
    /// rather than counting it toward permanent exhaustion.
    Disconnected {
        err: anyhow::Error,
        connected: bool,
    },
}

// =============================================================================
// SSE event parsing
// =============================================================================

fn parse_sse_event(event_type: &str, data: &[u8]) -> Option<BackendEvent> {
    match event_type {
        "connected" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                session_id: String,
            }
            let ev: Ev = serde_json::from_slice(data).ok()?;
            Some(BackendEvent::SseConnected {
                session_id: ev.session_id,
            })
        }

        "streaming_token" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                text: String,
                #[serde(default)]
                session_id: String,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("streaming_token", e)),
            };
            Some(BackendEvent::StreamingToken {
                text: ev.text,
                session_id: ev.session_id,
            })
        }

        "thinking_delta" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                text: String,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("thinking_delta", e)),
            };
            Some(BackendEvent::ThinkingDelta { text: ev.text })
        }

        "agent_response" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                response: String,
                #[serde(default)]
                response_type: String,
                signal: Option<Signal>,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("agent_response", e)),
            };
            Some(BackendEvent::AgentResponse {
                response: ev.response,
                response_type: ev.response_type,
                signal: ev.signal,
            })
        }

        "tool_call" => {
            // Backend sends "phase" to distinguish start vs end.
            #[derive(serde::Deserialize)]
            struct Ev {
                name: String,
                #[serde(default)]
                phase: String,
                #[serde(default)]
                args: String,
                #[serde(default)]
                duration_ms: u64,
                success: Option<bool>,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("tool_call", e)),
            };
            match ev.phase.as_str() {
                "end" => Some(BackendEvent::ToolCallEnd {
                    name: ev.name,
                    duration_ms: ev.duration_ms,
                    success: ev.success.unwrap_or(true),
                }),
                _ => Some(BackendEvent::ToolCallStart {
                    name: ev.name,
                    args: ev.args,
                }),
            }
        }

        "command_output_delta" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                #[serde(default)]
                command: String,
                #[serde(default)]
                chunk: String,
                #[serde(default)]
                tail: String,
                #[serde(default)]
                seq: u64,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("command_output_delta", e)),
            };
            Some(BackendEvent::CommandOutputDelta {
                command: ev.command,
                chunk: ev.chunk,
                tail: ev.tail,
                seq: ev.seq,
            })
        }

        "tool_result" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                name: String,
                result: String,
                success: bool,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("tool_result", e)),
            };
            Some(BackendEvent::ToolResult {
                name: ev.name,
                result: ev.result,
                success: ev.success,
            })
        }

        "llm_request" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                iteration: u32,
                #[serde(default)]
                max_iterations: Option<u32>,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("llm_request", e)),
            };
            Some(BackendEvent::LlmRequest {
                iteration: ev.iteration,
                max_iterations: ev.max_iterations,
            })
        }

        "llm_response" => {
            #[derive(serde::Deserialize)]
            struct Usage {
                input_tokens: u64,
                output_tokens: u64,
            }
            #[derive(serde::Deserialize)]
            struct Ev {
                duration_ms: u64,
                usage: Usage,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("llm_response", e)),
            };
            Some(BackendEvent::LlmResponse {
                duration_ms: ev.duration_ms,
                input_tokens: ev.usage.input_tokens,
                output_tokens: ev.usage.output_tokens,
            })
        }

        "signal_classified" => {
            // Try nested {signal: {...}} first, fall back to flat.
            #[derive(serde::Deserialize)]
            struct Wrapper {
                signal: Signal,
            }
            if let Ok(wrapper) = serde_json::from_slice::<Wrapper>(data) {
                if !wrapper.signal.mode.is_empty() {
                    return Some(BackendEvent::SignalClassified {
                        signal: wrapper.signal,
                    });
                }
            }
            let signal: Signal = match serde_json::from_slice(data) {
                Ok(s) => s,
                Err(e) => return Some(parse_warning("signal_classified", e)),
            };
            Some(BackendEvent::SignalClassified { signal })
        }

        "system_event" => parse_system_event(data),

        // The backend unwraps system_event sub-events: the SSE frame header
        // arrives as e.g. "orchestrator_agent_started" rather than "system_event".
        // Route these directly to the same parser.
        "orchestrator_task_started"
        | "orchestrator_agents_spawning"
        | "orchestrator_task_appraised"
        | "orchestrator_agent_started"
        | "orchestrator_agent_progress"
        | "orchestrator_agent_completed"
        | "orchestrator_agent_failed"
        | "orchestrator_wave_started"
        | "orchestrator_synthesizing"
        | "orchestrator_task_completed"
        | "fleet_node_started"
        | "fleet_node_progress"
        | "fleet_node_completed"
        | "fleet_summary"
        | "context_pressure"
        | "task_created"
        | "task_updated"
        | "task_checklist_show"
        | "task_checklist_hide"
        | "swarm_started"
        | "swarm_completed"
        | "swarm_failed"
        | "swarm_cancelled"
        | "swarm_timeout"
        | "swarm_intelligence_started"
        | "swarm_intelligence_round"
        | "swarm_intelligence_converged"
        | "swarm_intelligence_completed"
        | "goal_verifier_round"
        | "scratchpad_activity"
        | "hook_blocked"
        | "budget_warning"
        | "budget_exceeded"
        | "permission_required"
        | "plan_proposed"
        | "ask_user_question"
        | "survey_answered"
        | "proactive_message"
        | "proactive_mode_changed"
        | "coordinator_mode"
        | "auto_mode_paused" => parse_system_event(data),

        // Background (fire-and-forget) subagents. `started` arrives wrapped as a
        // system_event (has an `event` field); `completed`/`failed` are broadcast
        // directly with a `type` field and no `event` key, so parse all three here
        // rather than routing through parse_system_event.
        "background_agent_started" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                #[serde(default)]
                agent_id: String,
                #[serde(default)]
                role: String,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("background_agent_started", e)),
            };
            Some(BackendEvent::BackgroundAgentStarted {
                agent_id: ev.agent_id,
                role: ev.role,
            })
        }

        "background_agent_completed" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                #[serde(default)]
                agent_id: String,
                #[serde(default)]
                role: String,
                #[serde(default)]
                result: String,
                #[serde(default)]
                duration_ms: u64,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("background_agent_completed", e)),
            };
            Some(BackendEvent::BackgroundAgentCompleted {
                agent_id: ev.agent_id,
                role: ev.role,
                result: ev.result,
                duration_ms: ev.duration_ms,
            })
        }

        "background_agent_failed" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                #[serde(default)]
                agent_id: String,
                #[serde(default)]
                role: String,
                #[serde(default)]
                error: String,
                #[serde(default)]
                duration_ms: u64,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("background_agent_failed", e)),
            };
            Some(BackendEvent::BackgroundAgentFailed {
                agent_id: ev.agent_id,
                role: ev.role,
                error: ev.error,
                duration_ms: ev.duration_ms,
            })
        }

        // Multi-agent workflow events (Claude Code parity). Emitted directly on
        // the session topic with a `type` field (no `event` wrapper), so parse the
        // frame data directly like the background_agent_* arms above. All new
        // fields use #[serde(default)] for forward/backward compatibility.
        "agent_finished" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                #[serde(default)]
                display_name: String,
                #[serde(default)]
                duration_ms: u64,
                #[serde(default)]
                batch_id: Option<String>,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("agent_finished", e)),
            };
            Some(BackendEvent::AgentFinished {
                display_name: ev.display_name,
                duration_ms: ev.duration_ms,
                batch_id: ev.batch_id,
            })
        }

        "agent_message" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                #[serde(default)]
                from: String,
                #[serde(default)]
                text: String,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("agent_message", e)),
            };
            Some(BackendEvent::AgentMessage {
                from: ev.from,
                text: ev.text,
            })
        }

        "background_command_completed" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                #[serde(default)]
                exit_code: i32,
                #[serde(default)]
                command: String,
                // Backend emits the id as `background_id`; accept both so the
                // decoded task_id (shown in the completion toast) is populated.
                #[serde(default, alias = "background_id")]
                task_id: String,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("background_command_completed", e)),
            };
            Some(BackendEvent::BackgroundCommandCompleted {
                exit_code: ev.exit_code,
                command: ev.command,
                task_id: ev.task_id,
            })
        }

        "task_notification" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                #[serde(default)]
                count: u32,
                #[serde(default)]
                summary: String,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("task_notification", e)),
            };
            Some(BackendEvent::TaskNotification { count: ev.count, summary: ev.summary })
        }

        "turn_recap" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                #[serde(default)]
                elapsed_ms: u64,
                /// Substantive tool USES this turn (server-filtered). Defaults
                /// to 0 for legacy servers, in which case the handler falls
                /// back to counting the `tools_used` name list.
                #[serde(default)]
                tool_calls: u32,
                #[serde(default)]
                tools_used: Vec<String>,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("turn_recap", e)),
            };
            Some(BackendEvent::TurnRecap {
                elapsed_ms: ev.elapsed_ms,
                tool_calls: ev.tool_calls,
                tools_used: ev.tools_used,
            })
        }

        // Provider retry: broadcast directly on the session topic by
        // llm_client.ex as {type: :provider_retry, attempt, max_attempts,
        // delay_ms, reason} — fields are flat in both wire shapes.
        "provider_retry" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                #[serde(default)]
                attempt: u32,
                #[serde(default)]
                max_attempts: u32,
                #[serde(default)]
                delay_ms: u64,
                #[serde(default)]
                reason: String,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("provider_retry", e)),
            };
            Some(BackendEvent::ProviderRetry {
                attempt: ev.attempt,
                max_attempts: ev.max_attempts,
                delay_ms: ev.delay_ms,
                reason: ev.reason,
            })
        }

        // Turn-fatal backend error (react_loop llm_error / context_overflow),
        // unwrapped from a system_event frame by the SSE loop / TuiForwarder.
        "error" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                #[serde(default)]
                kind: String,
                #[serde(default)]
                reason: String,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("error", e)),
            };
            Some(BackendEvent::TurnError {
                kind: ev.kind,
                reason: ev.reason,
            })
        }

        "" => None,

        other => Some(BackendEvent::ParseWarning {
            message: format!("[sse] unknown event type: {}", other),
        }),
    }
}

fn parse_system_event(data: &[u8]) -> Option<BackendEvent> {
    #[derive(serde::Deserialize)]
    struct Base {
        event: String,
    }
    let base: Base = serde_json::from_slice(data).ok()?;

    match base.event.as_str() {
        "orchestrator_task_started" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                task_id: String,
            }
            let ev: Ev = serde_json::from_slice(data).ok()?;
            Some(BackendEvent::OrchestratorTaskStarted {
                task_id: ev.task_id,
            })
        }

        "orchestrator_agents_spawning" => {
            #[derive(serde::Deserialize)]
            struct Agent {
                #[serde(default)]
                name: String,
                #[serde(default)]
                role: String,
            }
            #[derive(serde::Deserialize)]
            struct Ev {
                #[serde(default)]
                agent_count: usize,
                #[serde(default)]
                agents: Vec<Agent>,
            }
            let ev: Ev = serde_json::from_slice(data).ok()?;
            Some(BackendEvent::OrchestratorAgentsSpawning {
                agent_count: ev.agent_count,
                agents: ev
                    .agents
                    .into_iter()
                    .map(|a| crate::event::backend::SpawningAgent {
                        name: a.name,
                        role: a.role,
                    })
                    .collect(),
            })
        }

        "orchestrator_task_appraised" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                #[serde(default)]
                estimated_cost_usd: f64,
                #[serde(default)]
                estimated_hours: f64,
            }
            let ev: Ev = serde_json::from_slice(data).ok()?;
            Some(BackendEvent::OrchestratorTaskAppraised {
                estimated_cost_usd: ev.estimated_cost_usd,
                estimated_hours: ev.estimated_hours,
            })
        }

        "orchestrator_agent_started" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                agent_name: String,
                role: String,
                #[serde(default)]
                model: String,
                #[serde(default)]
                description: String,
                #[serde(default)]
                batch_id: Option<String>,
            }
            let ev: Ev = serde_json::from_slice(data).ok()?;
            Some(BackendEvent::OrchestratorAgentStarted {
                agent_name: ev.agent_name,
                role: ev.role,
                model: ev.model,
                subject: ev.description,
                batch_id: ev.batch_id,
            })
        }

        "orchestrator_agent_progress" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                agent_name: String,
                #[serde(default)]
                current_action: String,
                #[serde(default)]
                tool_uses: u32,
                #[serde(default)]
                tokens_used: u32,
                #[serde(default)]
                description: String,
                #[serde(default)]
                recent_actions: Vec<String>,
            }
            let ev: Ev = serde_json::from_slice(data).ok()?;
            Some(BackendEvent::OrchestratorAgentProgress {
                agent_name: ev.agent_name,
                current_action: ev.current_action,
                tool_uses: ev.tool_uses,
                tokens_used: ev.tokens_used,
                subject: ev.description,
                recent_actions: ev.recent_actions,
            })
        }

        "orchestrator_synthesizing" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                #[serde(default)]
                agent_count: usize,
            }
            let ev: Ev = serde_json::from_slice(data).ok()?;
            Some(BackendEvent::OrchestratorSynthesizing {
                agent_count: ev.agent_count,
            })
        }

        "orchestrator_agent_completed" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                agent_name: String,
                #[serde(default)]
                status: String,
                #[serde(default)]
                tool_uses: u32,
                #[serde(default)]
                tokens_used: u32,
                #[serde(default)]
                error: String,
                // Compact one-line result/error preview (absent from older backends).
                #[serde(default)]
                summary: Option<String>,
            }
            let ev: Ev = serde_json::from_slice(data).ok()?;
            // Backend uses this event for both success and failure
            if ev.status == "failed" {
                Some(BackendEvent::OrchestratorAgentFailed {
                    agent_name: ev.agent_name,
                    error: ev.error,
                    tool_uses: ev.tool_uses,
                    tokens_used: ev.tokens_used,
                    summary: ev.summary,
                })
            } else {
                Some(BackendEvent::OrchestratorAgentCompleted {
                    agent_name: ev.agent_name,
                    status: ev.status,
                    tool_uses: ev.tool_uses,
                    tokens_used: ev.tokens_used,
                    summary: ev.summary,
                })
            }
        }

        // === Fleet events (Part 3.2) — full-power background nodes. All fields
        // `#[serde(default)]` so a partial frame decodes cleanly rather than
        // dropping to a ParseWarning.
        "fleet_node_started" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                #[serde(default)]
                node_id: String,
                #[serde(default)]
                agent_type: String,
                #[serde(default)]
                task: String,
                #[serde(default)]
                flavor: String,
                #[serde(default)]
                depth: u32,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(v) => v,
                Err(e) => return Some(parse_warning("fleet_node_started", e)),
            };
            Some(BackendEvent::FleetNodeStarted {
                node_id: ev.node_id,
                agent_type: ev.agent_type,
                task: ev.task,
                flavor: ev.flavor,
                depth: ev.depth,
            })
        }

        "fleet_node_progress" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                #[serde(default)]
                node_id: String,
                #[serde(default)]
                current_action: String,
                #[serde(default)]
                tool_uses: u32,
                #[serde(default)]
                tokens_used: u32,
                #[serde(default)]
                recent_actions: Vec<String>,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(v) => v,
                Err(e) => return Some(parse_warning("fleet_node_progress", e)),
            };
            Some(BackendEvent::FleetNodeProgress {
                node_id: ev.node_id,
                current_action: ev.current_action,
                tool_uses: ev.tool_uses,
                tokens_used: ev.tokens_used,
                recent_actions: ev.recent_actions,
            })
        }

        "fleet_node_completed" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                #[serde(default)]
                node_id: String,
                #[serde(default)]
                summary: Option<String>,
                #[serde(default)]
                status: String,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(v) => v,
                Err(e) => return Some(parse_warning("fleet_node_completed", e)),
            };
            Some(BackendEvent::FleetNodeCompleted {
                node_id: ev.node_id,
                summary: ev.summary,
                status: ev.status,
            })
        }

        "fleet_summary" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                #[serde(default)]
                running: u32,
                #[serde(default)]
                queued: u32,
                #[serde(default)]
                cap: u32,
                #[serde(default)]
                total_spawned: u32,
                #[serde(default)]
                warn: bool,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(v) => v,
                Err(e) => return Some(parse_warning("fleet_summary", e)),
            };
            Some(BackendEvent::FleetSummary {
                running: ev.running,
                queued: ev.queued,
                cap: ev.cap,
                total_spawned: ev.total_spawned,
                warn: ev.warn,
            })
        }

        "orchestrator_agent_failed" => {
            // Forward compat if backend ever emits this directly
            #[derive(serde::Deserialize)]
            struct Ev {
                agent_name: String,
                #[serde(default)]
                error: String,
                #[serde(default)]
                tool_uses: u32,
                #[serde(default)]
                tokens_used: u32,
                #[serde(default)]
                summary: Option<String>,
            }
            let ev: Ev = serde_json::from_slice(data).ok()?;
            Some(BackendEvent::OrchestratorAgentFailed {
                agent_name: ev.agent_name,
                error: ev.error,
                tool_uses: ev.tool_uses,
                tokens_used: ev.tokens_used,
                summary: ev.summary,
            })
        }

        "orchestrator_wave_started" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                wave_number: u32,
                total_waves: u32,
            }
            let ev: Ev = serde_json::from_slice(data).ok()?;
            Some(BackendEvent::OrchestratorWaveStarted {
                wave_number: ev.wave_number,
                total_waves: ev.total_waves,
            })
        }

        "orchestrator_task_completed" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                task_id: String,
            }
            let ev: Ev = serde_json::from_slice(data).ok()?;
            Some(BackendEvent::OrchestratorTaskCompleted {
                task_id: ev.task_id,
            })
        }

        "streaming_token" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                text: String,
                #[serde(default)]
                session_id: String,
            }
            let ev: Ev = serde_json::from_slice(data).ok()?;
            Some(BackendEvent::StreamingToken {
                text: ev.text,
                session_id: ev.session_id,
            })
        }

        "thinking_delta" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                text: String,
            }
            let ev: Ev = serde_json::from_slice(data).ok()?;
            Some(BackendEvent::ThinkingDelta { text: ev.text })
        }

        "context_pressure" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                utilization: f64,
                estimated_tokens: u64,
                max_tokens: u64,
                // WS8/WS12 — CC token-warning fields (percent of usable context
                // left before auto-compact; low-context threshold crossed).
                // Defaulted so frames from older backends still parse.
                #[serde(default)]
                percent_left: Option<u32>,
                #[serde(default)]
                context_low: Option<bool>,
            }
            let ev: Ev = serde_json::from_slice(data).ok()?;
            Some(BackendEvent::ContextPressure {
                utilization: ev.utilization,
                estimated_tokens: ev.estimated_tokens,
                max_tokens: ev.max_tokens,
                percent_left: ev.percent_left,
                context_low: ev.context_low,
            })
        }

        "task_created" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                task_id: String,
                #[serde(default)]
                subject: String,
                #[serde(default)]
                active_form: String,
            }
            let ev: Ev = serde_json::from_slice(data).ok()?;
            Some(BackendEvent::TaskCreated {
                task_id: ev.task_id,
                subject: ev.subject,
                active_form: ev.active_form,
            })
        }

        "task_updated" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                task_id: String,
                status: String,
            }
            let ev: Ev = serde_json::from_slice(data).ok()?;
            Some(BackendEvent::TaskUpdated {
                task_id: ev.task_id,
                status: ev.status,
            })
        }

        "task_checklist_show" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                #[serde(default)]
                data: ChecklistData,
            }
            #[derive(serde::Deserialize, Default)]
            struct ChecklistData {
                #[serde(default)]
                tasks: Vec<crate::client::types::ChecklistTaskWire>,
            }
            let ev: Ev = serde_json::from_slice(data).ok()?;
            Some(BackendEvent::TaskChecklistShow {
                tasks: ev.data.tasks,
            })
        }

        "task_checklist_hide" => {
            Some(BackendEvent::TaskChecklistHide)
        }

        "swarm_started" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                swarm_id: String,
                #[serde(default)]
                pattern: String,
                #[serde(default)]
                agent_count: u32,
                #[serde(default)]
                task_preview: String,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("swarm_started", e)),
            };
            Some(BackendEvent::SwarmStarted {
                swarm_id: ev.swarm_id,
                pattern: ev.pattern,
                agent_count: ev.agent_count,
                task_preview: ev.task_preview,
            })
        }

        "swarm_completed" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                swarm_id: String,
                #[serde(default)]
                pattern: String,
                #[serde(default)]
                agent_count: u32,
                #[serde(default)]
                result_preview: String,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("swarm_completed", e)),
            };
            Some(BackendEvent::SwarmCompleted {
                swarm_id: ev.swarm_id,
                pattern: ev.pattern,
                agent_count: ev.agent_count,
                result_preview: ev.result_preview,
            })
        }

        "swarm_failed" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                swarm_id: String,
                #[serde(default)]
                reason: String,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("swarm_failed", e)),
            };
            Some(BackendEvent::SwarmFailed {
                swarm_id: ev.swarm_id,
                reason: ev.reason,
            })
        }

        "swarm_cancelled" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                swarm_id: String,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("swarm_cancelled", e)),
            };
            Some(BackendEvent::SwarmCancelled {
                swarm_id: ev.swarm_id,
            })
        }

        "swarm_timeout" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                swarm_id: String,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("swarm_timeout", e)),
            };
            Some(BackendEvent::SwarmTimeout {
                swarm_id: ev.swarm_id,
            })
        }

        "swarm_intelligence_started" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                swarm_id: String,
                #[serde(rename = "type", default)]
                intelligence_type: String,
                #[serde(default)]
                task: String,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("swarm_intelligence_started", e)),
            };
            Some(BackendEvent::SwarmIntelligenceStarted {
                swarm_id: ev.swarm_id,
                intelligence_type: ev.intelligence_type,
                task: ev.task,
            })
        }

        "swarm_intelligence_round" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                swarm_id: String,
                round: u32,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("swarm_intelligence_round", e)),
            };
            Some(BackendEvent::SwarmIntelligenceRound {
                swarm_id: ev.swarm_id,
                round: ev.round,
            })
        }

        "goal_verifier_round" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                #[serde(default = "default_phase")]
                phase: String,
                #[serde(default)]
                verdict: String,
                #[serde(default)]
                round: u32,
                #[serde(default)]
                max_runs: u32,
                #[serde(default)]
                refuted_count: u32,
                #[serde(default)]
                total: u32,
                #[serde(default)]
                gaps: Vec<String>,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("goal_verifier_round", e)),
            };
            Some(BackendEvent::GoalVerification {
                phase: ev.phase,
                verdict: ev.verdict,
                round: ev.round,
                max_runs: ev.max_runs,
                refuted: ev.refuted_count,
                total: ev.total,
                gaps: ev.gaps,
            })
        }

        "scratchpad_activity" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                #[serde(default)]
                agent: String,
                #[serde(default)]
                entry: String,
                #[serde(default)]
                action: String,
                #[serde(default)]
                bytes: u64,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("scratchpad_activity", e)),
            };
            Some(BackendEvent::ScratchpadActivity {
                agent: ev.agent,
                entry: ev.entry,
                action: ev.action,
                bytes: ev.bytes,
            })
        }

        "swarm_intelligence_converged" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                swarm_id: String,
                round: u32,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("swarm_intelligence_converged", e)),
            };
            Some(BackendEvent::SwarmIntelligenceConverged {
                swarm_id: ev.swarm_id,
                round: ev.round,
            })
        }

        "swarm_intelligence_completed" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                swarm_id: String,
                #[serde(default)]
                converged: bool,
                #[serde(default)]
                rounds: u32,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("swarm_intelligence_completed", e)),
            };
            Some(BackendEvent::SwarmIntelligenceCompleted {
                swarm_id: ev.swarm_id,
                converged: ev.converged,
                rounds: ev.rounds,
            })
        }

        "hook_blocked" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                hook_name: String,
                #[serde(default)]
                reason: String,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("hook_blocked", e)),
            };
            Some(BackendEvent::HookBlocked {
                hook_name: ev.hook_name,
                reason: ev.reason,
            })
        }

        "budget_warning" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                utilization: f64,
                #[serde(default)]
                message: String,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("budget_warning", e)),
            };
            Some(BackendEvent::BudgetWarning {
                utilization: ev.utilization,
                message: ev.message,
            })
        }

        "budget_exceeded" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                #[serde(default)]
                message: String,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("budget_exceeded", e)),
            };
            Some(BackendEvent::BudgetExceeded {
                message: ev.message,
            })
        }

        "permission_required" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                #[serde(default)]
                tool: String,
                /// Flat hint string on current backends; older backends sent a
                /// {tool, args} object — accept both.
                #[serde(default)]
                args: serde_json::Value,
                #[serde(default)]
                request_id: String,
                #[serde(default)]
                target: Option<String>,
                #[serde(default)]
                kind: Option<String>,
                #[serde(default)]
                old_content: Option<String>,
                #[serde(default)]
                new_content: Option<String>,
                #[serde(default)]
                warning: Option<String>,
                #[serde(default)]
                reason: Option<String>,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("permission_required", e)),
            };
            let args = match ev.args {
                serde_json::Value::String(s) => s,
                serde_json::Value::Object(map) => map
                    .get("args")
                    .and_then(|v| v.as_str())
                    .unwrap_or_default()
                    .to_string(),
                _ => String::new(),
            };
            Some(BackendEvent::PermissionRequired {
                tool: ev.tool,
                args,
                request_id: ev.request_id,
                target: ev.target.filter(|s| !s.trim().is_empty()),
                kind: ev.kind.unwrap_or_default(),
                old_content: ev.old_content,
                new_content: ev.new_content,
                warning: ev.warning,
                reason: ev.reason,
            })
        }

        "plan_proposed" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                #[serde(default)]
                plan: String,
                #[serde(default)]
                request_id: String,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("plan_proposed", e)),
            };
            Some(BackendEvent::PlanProposed {
                plan: ev.plan,
                request_id: ev.request_id,
            })
        }

        "ask_user_question" => {
            use crate::client::types::SurveyQuestionWire;
            #[derive(serde::Deserialize)]
            struct Ev {
                survey_id: String,
                questions: Vec<SurveyQuestionWire>,
                #[serde(default)]
                skippable: bool,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("ask_user_question", e)),
            };
            Some(BackendEvent::AskUserQuestion {
                survey_id: ev.survey_id,
                questions: ev.questions,
                skippable: ev.skippable,
            })
        }

        "survey_answered" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                survey_id: String,
                #[serde(default)]
                summary: Vec<(String, String)>,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("survey_answered", e)),
            };
            Some(BackendEvent::SurveyAnswered {
                survey_id: ev.survey_id,
                summary: ev.summary,
            })
        }

        "proactive_message" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                #[serde(default)]
                message: String,
                #[serde(default)]
                message_type: String,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("proactive_message", e)),
            };
            Some(BackendEvent::ProactiveMessage {
                message: ev.message,
                message_type: ev.message_type,
            })
        }

        "proactive_mode_changed" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                #[serde(default)]
                enabled: bool,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("proactive_mode_changed", e)),
            };
            Some(BackendEvent::ProactiveModeChanged {
                enabled: ev.enabled,
            })
        }

        "auto_mode_paused" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                #[serde(default)]
                blocked_count: u32,
                #[serde(default)]
                message: String,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("auto_mode_paused", e)),
            };
            Some(BackendEvent::AutoModePaused {
                blocked_count: ev.blocked_count,
                message: ev.message,
            })
        }

        "coordinator_mode" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                #[serde(default)]
                active: bool,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("coordinator_mode", e)),
            };
            Some(BackendEvent::CoordinatorMode { active: ev.active })
        }

        // Multi-agent workflow events may also arrive wrapped as a system_event
        // (with an `event` field). Delegate to the top-level parser, which builds
        // them from the same frame data.
        "agent_finished" | "agent_message" | "background_command_completed"
        | "turn_recap" | "provider_retry" | "error" => {
            parse_sse_event(base.event.as_str(), data)
        }

        other if !other.is_empty() => Some(BackendEvent::ParseWarning {
            message: format!("[sse] unknown system_event: {}", other),
        }),

        _ => None,
    }
}

/// A goal-verifier frame with no explicit `phase` is a completed round (older
/// backends emit only the done event), so default the discriminator to "done".
fn default_phase() -> String {
    "done".to_string()
}

fn parse_warning(event_type: &str, err: serde_json::Error) -> BackendEvent {
    BackendEvent::ParseWarning {
        message: format!("[sse] parse {}: {}", event_type, err),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reconnect_budget_resets_after_a_recovered_blip() {
        // A mid-stream drop (connected=true) restarts the budget at 1 so many
        // recovered blips never trip "exhausted".
        assert_eq!(next_reconnect_attempt(7, true), 1);
        assert_eq!(next_reconnect_attempt(0, true), 1);
        // A pre-attach connect failure (never reached the body) counts up.
        assert_eq!(next_reconnect_attempt(0, false), 1);
        assert_eq!(next_reconnect_attempt(3, false), 4);
        // Repeated connect failures eventually exceed the budget.
        let mut attempt = 0;
        for _ in 0..(MAX_RECONNECTS + 1) {
            attempt = next_reconnect_attempt(attempt, false);
        }
        assert!(attempt > MAX_RECONNECTS);
    }

    #[test]
    fn parses_provider_retry() {
        let data = br#"{"type":"provider_retry","session_id":"s1","attempt":2,"max_attempts":3,"delay_ms":4000,"reason":"timeout"}"#;
        match parse_sse_event("provider_retry", data) {
            Some(BackendEvent::ProviderRetry {
                attempt: 2,
                max_attempts: 3,
                delay_ms: 4000,
                reason,
            }) => assert_eq!(reason, "timeout"),
            other => panic!("unexpected: {:?}", other),
        }
    }

    #[test]
    fn parses_goal_verifier_round_start_and_done() {
        // Start phase: a lightweight "verifying…" signal (no verdict yet).
        let start = br#"{"type":"system_event","event":"goal_verifier_round","session_id":"s1","phase":"start","round":1,"max_runs":3}"#;
        match parse_sse_event("goal_verifier_round", start) {
            Some(BackendEvent::GoalVerification { phase, round, .. }) => {
                assert_eq!(phase, "start");
                assert_eq!(round, 1);
            }
            other => panic!("unexpected: {:?}", other),
        }

        // Done phase, incomplete verdict with a compact gap summary.
        let done = br#"{"type":"system_event","event":"goal_verifier_round","session_id":"s1","phase":"done","round":1,"max_runs":3,"verdict":"incomplete","refuted_count":2,"total":3,"gaps":["[completeness] error handling"]}"#;
        match parse_sse_event("goal_verifier_round", done) {
            Some(BackendEvent::GoalVerification {
                phase,
                verdict,
                refuted,
                total,
                gaps,
                ..
            }) => {
                assert_eq!(phase, "done");
                assert_eq!(verdict, "incomplete");
                assert_eq!((refuted, total), (2, 3));
                assert_eq!(gaps, vec!["[completeness] error handling".to_string()]);
            }
            other => panic!("unexpected: {:?}", other),
        }

        // A frame missing `phase` (older backend) defaults to a done round.
        let legacy = br#"{"event":"goal_verifier_round","verdict":"complete","refuted_count":0,"total":3}"#;
        match parse_sse_event("goal_verifier_round", legacy) {
            Some(BackendEvent::GoalVerification { phase, verdict, .. }) => {
                assert_eq!(phase, "done");
                assert_eq!(verdict, "complete");
            }
            other => panic!("unexpected: {:?}", other),
        }
    }

    #[test]
    fn parses_scratchpad_activity() {
        // The compact fan-out coordination signal: who wrote what, how big — and
        // crucially NO file contents.
        let data = br#"{"type":"system_event","event":"scratchpad_activity","session_id":"s1","agent":"agent:s1:2","entry":"findings.md","action":"write","bytes":2100}"#;
        match parse_sse_event("scratchpad_activity", data) {
            Some(BackendEvent::ScratchpadActivity { agent, entry, action, bytes }) => {
                assert_eq!(agent, "agent:s1:2");
                assert_eq!(entry, "findings.md");
                assert_eq!(action, "write");
                assert_eq!(bytes, 2100);
            }
            other => panic!("unexpected: {:?}", other),
        }

        // An append frame with a small size still parses.
        let appended = br#"{"type":"system_event","event":"scratchpad_activity","session_id":"s1","agent":"lead","entry":"notes.md","action":"append","bytes":42}"#;
        match parse_sse_event("scratchpad_activity", appended) {
            Some(BackendEvent::ScratchpadActivity { action, bytes, .. }) => {
                assert_eq!(action, "append");
                assert_eq!(bytes, 42);
            }
            other => panic!("unexpected: {:?}", other),
        }
    }

    #[test]
    fn parses_agent_completed_summary_backward_compatible() {
        // Success frame WITH a summary → OrchestratorAgentCompleted carrying it.
        let ok = br#"{"type":"system_event","event":"orchestrator_agent_completed","session_id":"s1","agent_name":"w1","status":"completed","tool_uses":3,"tokens_used":1200,"summary":"Found 4 dead paths"}"#;
        match parse_sse_event("orchestrator_agent_completed", ok) {
            Some(BackendEvent::OrchestratorAgentCompleted { agent_name, summary, .. }) => {
                assert_eq!(agent_name, "w1");
                assert_eq!(summary.as_deref(), Some("Found 4 dead paths"));
            }
            other => panic!("unexpected: {:?}", other),
        }

        // Failure frame carries the error summary on the same field.
        let fail = br#"{"type":"system_event","event":"orchestrator_agent_completed","session_id":"s1","agent_name":"w2","status":"failed","error":"boom","summary":"boom: join timeout"}"#;
        match parse_sse_event("orchestrator_agent_completed", fail) {
            Some(BackendEvent::OrchestratorAgentFailed { agent_name, summary, .. }) => {
                assert_eq!(agent_name, "w2");
                assert_eq!(summary.as_deref(), Some("boom: join timeout"));
            }
            other => panic!("unexpected: {:?}", other),
        }

        // Older backend without the field → summary is None (no panic, no drop).
        let legacy = br#"{"type":"system_event","event":"orchestrator_agent_completed","session_id":"s1","agent_name":"w3","status":"completed","tool_uses":1,"tokens_used":10}"#;
        match parse_sse_event("orchestrator_agent_completed", legacy) {
            Some(BackendEvent::OrchestratorAgentCompleted { summary, .. }) => {
                assert_eq!(summary, None);
            }
            other => panic!("unexpected: {:?}", other),
        }
    }

    #[test]
    fn parses_coordinator_mode() {
        // Delivered wrapped as a system_event by the backend TuiForwarder.
        let on = br#"{"type":"system_event","event":"coordinator_mode","session_id":"s1","active":true}"#;
        for frame in ["coordinator_mode", "system_event"] {
            match parse_sse_event(frame, on) {
                Some(BackendEvent::CoordinatorMode { active }) => assert!(active),
                other => panic!("unexpected for {}: {:?}", frame, other),
            }
        }

        let off = br#"{"type":"system_event","event":"coordinator_mode","session_id":"s1","active":false}"#;
        match parse_sse_event("coordinator_mode", off) {
            Some(BackendEvent::CoordinatorMode { active }) => assert!(!active),
            other => panic!("unexpected: {:?}", other),
        }
    }

    #[test]
    fn parses_error_direct_and_wrapped() {
        let data = br#"{"type":"system_event","event":"error","kind":"llm_error","reason":"boom"}"#;
        for frame in ["error", "system_event"] {
            match parse_sse_event(frame, data) {
                Some(BackendEvent::TurnError { kind, reason }) => {
                    assert_eq!(kind, "llm_error");
                    assert_eq!(reason, "boom");
                }
                other => panic!("unexpected for {}: {:?}", frame, other),
            }
        }
    }
}
