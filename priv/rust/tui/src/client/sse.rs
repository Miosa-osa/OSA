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
                    // Clean disconnect (server closed or cancelled)
                    let _ = self.send(BackendEvent::SseDisconnected { error: None });
                    return;
                }
                Err(SseError::AuthFailed) => {
                    let _ = self.send(BackendEvent::SseAuthFailed);
                    return;
                }
                Err(SseError::Cancelled) => {
                    let _ = self.send(BackendEvent::SseDisconnected { error: None });
                    return;
                }
                Err(SseError::Disconnected(e)) => {
                    attempt += 1;
                    if attempt > MAX_RECONNECTS {
                        error!(
                            "SSE reconnect failed after {} attempts: {:?}",
                            MAX_RECONNECTS, e
                        );
                        let _ = self.send(BackendEvent::SseDisconnected { error: None });
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
                            let _ = self.send(BackendEvent::SseDisconnected { error: None });
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
            .map_err(|e| SseError::Disconnected(e.into()))?;

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
            .map_err(|e| SseError::Disconnected(e.into()))?;

        let status = resp.status();
        if status == reqwest::StatusCode::UNAUTHORIZED
            || status == reqwest::StatusCode::FORBIDDEN
        {
            return Err(SseError::AuthFailed);
        }
        if !status.is_success() {
            return Err(SseError::Disconnected(anyhow::anyhow!(
                "SSE stream returned {}",
                status
            )));
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
                            return Err(SseError::Disconnected(e.into()));
                        }
                    }
                }
            }
        }
    }
}

#[derive(Debug)]
enum SseError {
    AuthFailed,
    Cancelled,
    Disconnected(anyhow::Error),
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
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("llm_request", e)),
            };
            Some(BackendEvent::LlmRequest {
                iteration: ev.iteration,
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
        | "context_pressure"
        | "task_created"
        | "task_updated"
        | "swarm_started"
        | "swarm_completed"
        | "swarm_failed"
        | "swarm_cancelled"
        | "swarm_timeout"
        | "swarm_intelligence_started"
        | "swarm_intelligence_round"
        | "swarm_intelligence_converged"
        | "swarm_intelligence_completed"
        | "hook_blocked"
        | "budget_warning"
        | "budget_exceeded"
        | "permission_required"
        | "plan_proposed" => parse_system_event(data),

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
            }
            let ev: Ev = serde_json::from_slice(data).ok()?;
            Some(BackendEvent::OrchestratorAgentStarted {
                agent_name: ev.agent_name,
                role: ev.role,
                model: ev.model,
                subject: ev.description,
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
            }
            let ev: Ev = serde_json::from_slice(data).ok()?;
            Some(BackendEvent::OrchestratorAgentProgress {
                agent_name: ev.agent_name,
                current_action: ev.current_action,
                tool_uses: ev.tool_uses,
                tokens_used: ev.tokens_used,
                subject: ev.description,
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
            }
            let ev: Ev = serde_json::from_slice(data).ok()?;
            // Backend uses this event for both success and failure
            if ev.status == "failed" {
                Some(BackendEvent::OrchestratorAgentFailed {
                    agent_name: ev.agent_name,
                    error: ev.error,
                    tool_uses: ev.tool_uses,
                    tokens_used: ev.tokens_used,
                })
            } else {
                Some(BackendEvent::OrchestratorAgentCompleted {
                    agent_name: ev.agent_name,
                    status: ev.status,
                    tool_uses: ev.tool_uses,
                    tokens_used: ev.tokens_used,
                })
            }
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
            }
            let ev: Ev = serde_json::from_slice(data).ok()?;
            Some(BackendEvent::OrchestratorAgentFailed {
                agent_name: ev.agent_name,
                error: ev.error,
                tool_uses: ev.tool_uses,
                tokens_used: ev.tokens_used,
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
            }
            let ev: Ev = serde_json::from_slice(data).ok()?;
            Some(BackendEvent::ContextPressure {
                utilization: ev.utilization,
                estimated_tokens: ev.estimated_tokens,
                max_tokens: ev.max_tokens,
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
                #[serde(default)]
                args: String,
                #[serde(default)]
                request_id: String,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("permission_required", e)),
            };
            Some(BackendEvent::PermissionRequired {
                tool: ev.tool,
                args: ev.args,
                request_id: ev.request_id,
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

        other if !other.is_empty() => Some(BackendEvent::ParseWarning {
            message: format!("[sse] unknown system_event: {}", other),
        }),

        _ => None,
    }
}

fn parse_warning(event_type: &str, err: serde_json::Error) -> BackendEvent {
    BackendEvent::ParseWarning {
        message: format!("[sse] parse {}: {}", event_type, err),
    }
}
