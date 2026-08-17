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

/// How long an attached stream may go completely silent before we treat it as
/// dead and reconnect.
///
/// The reconnect loop below only ever runs on an `Err` from the read. A
/// half-open TCP connection produces neither bytes nor an error — the laptop
/// slept, the VPN dropped, a NAT box forgot the flow — so without a timeout the
/// `select!` parks forever, the backoff never fires, and the UI silently stops
/// updating for the rest of the session.
///
/// The server emits `: keepalive` every 30s (`session_routes.ex`'s SSE loop),
/// which lands here as a comment line and counts as traffic. Three intervals of
/// slack means a live stream has to miss three consecutive keepalives before we
/// call it: enough that a scheduling hiccup or a brief stall never trips it,
/// short enough that a genuinely wedged connection recovers in ~90s instead of
/// never. Do not tighten this below `3 * keepalive`.
const IDLE_TIMEOUT: Duration = Duration::from_secs(90);

/// SSE client that connects to the backend event stream and dispatches
/// parsed events through a channel.
pub struct SseClient {
    session_id: String,
    base_url: String,
    token: String,
    event_tx: mpsc::UnboundedSender<Event>,
    cancel: CancellationToken,
    /// Silence budget for an attached stream. Always [`IDLE_TIMEOUT`] in
    /// production; tests shorten it so they can prove the timeout actually
    /// fires without waiting out three keepalive intervals.
    idle_timeout: Duration,
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
            idle_timeout: IDLE_TIMEOUT,
        }
    }

    /// Shorten the idle budget. Test-only: production always uses
    /// [`IDLE_TIMEOUT`], which is pinned to the server's keepalive cadence.
    #[cfg(test)]
    fn with_idle_timeout(mut self, idle_timeout: Duration) -> Self {
        self.idle_timeout = idle_timeout;
        self
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
                Err(SseError::SessionNotFound) => {
                    // A 404 is permanent for this session id. Retrying it with
                    // network backoff only leaves the TUI stuck on
                    // "Reconnecting…" for minutes. Hand recovery to the app,
                    // which can create a replacement session and preserve any
                    // queued prompt until that new stream is attached.
                    let _ = self.send(BackendEvent::SseDisconnected {
                        error: Some("session_not_found".to_string()),
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
                        attempt, MAX_RECONNECTS, backoff_secs, e
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
        let url = format!("{}/api/v1/stream/{}", self.base_url, self.session_id);

        // No total-request timeout for SSE long-polling — the stream is
        // intentionally long-lived. Duration::from_secs(0) is NOT "no
        // timeout": reqwest wraps it in a tokio::time::sleep(Duration::ZERO)
        // which fires on the first poll, immediately killing the body stream.
        // Omitting .timeout() leaves reqwest at its default (no timeout).
        let http = HttpClient::builder()
            .build()
            .map_err(|e| SseError::Disconnected {
                err: e.into(),
                connected: false,
            })?;

        let mut req = http
            .get(&url)
            .header("Accept", "text/event-stream")
            .header("Cache-Control", "no-cache");

        if !self.token.is_empty() {
            req = req.header("Authorization", format!("Bearer {}", self.token));
        }

        let resp = req.send().await.map_err(|e| SseError::Disconnected {
            err: e.into(),
            connected: false,
        })?;

        let status = resp.status();
        if status == reqwest::StatusCode::UNAUTHORIZED || status == reqwest::StatusCode::FORBIDDEN {
            return Err(SseError::AuthFailed);
        }
        if status == reqwest::StatusCode::NOT_FOUND {
            return Err(SseError::SessionNotFound);
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
        let stream_reader =
            tokio_util::io::StreamReader::new(byte_stream.map(|result| {
                result.map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))
            }));
        let mut lines = tokio::io::BufReader::with_capacity(MAX_LINE_BYTES, stream_reader).lines();

        let mut event_type = String::new();

        loop {
            tokio::select! {
                _ = self.cancel.cancelled() => {
                    return Err(SseError::Cancelled);
                }
                line = tokio::time::timeout(self.idle_timeout, lines.next_line()) => {
                    // Timeout elapsed: the stream is attached but silent past
                    // three keepalive intervals. Fall into the SAME mid-stream
                    // drop path a read error takes, so the existing
                    // reconnect/backoff machinery recovers it.
                    let Ok(line) = line else {
                        warn!(
                            "SSE idle for {:?} (no data, no keepalive) — treating as half-open and reconnecting",
                            self.idle_timeout
                        );
                        return Err(SseError::Disconnected {
                            err: anyhow::anyhow!(
                                "SSE stream idle for {:?}",
                                self.idle_timeout
                            ),
                            connected: true,
                        });
                    };

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
    SessionNotFound,
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
                /// Absent on an older backend — see `BackendEvent::StreamingToken`.
                #[serde(default)]
                message_id: Option<String>,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("streaming_token", e)),
            };
            Some(BackendEvent::StreamingToken {
                text: ev.text,
                session_id: ev.session_id,
                message_id: ev.message_id,
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
                /// Absent on an older backend — see `BackendEvent::AgentResponse`.
                #[serde(default)]
                message_id: Option<String>,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("agent_response", e)),
            };
            Some(BackendEvent::AgentResponse {
                response: ev.response,
                response_type: ev.response_type,
                signal: ev.signal,
                message_id: ev.message_id,
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
                /// Stable per-call identity. Absent on an older backend, hence
                /// `Option` + `#[serde(default)]`; consumers fall back to
                /// name-based pairing when it is `None`.
                #[serde(default)]
                tool_call_id: Option<String>,
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
                    tool_call_id: ev.tool_call_id,
                }),
                _ => Some(BackendEvent::ToolCallStart {
                    name: ev.name,
                    args: ev.args,
                    tool_call_id: ev.tool_call_id,
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
                #[serde(default)]
                tool_call_id: Option<String>,
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
                tool_call_id: ev.tool_call_id,
            })
        }

        "tool_result" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                name: String,
                result: String,
                success: bool,
                #[serde(default)]
                tool_call_id: Option<String>,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("tool_result", e)),
            };
            Some(BackendEvent::ToolResult {
                name: ev.name,
                result: ev.result,
                success: ev.success,
                tool_call_id: ev.tool_call_id,
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

        // Accounting and recovery telemetry is useful to backend observers but
        // does not have a dedicated TUI surface. Recognise it explicitly so a
        // healthy stream does not generate misleading "unknown event" warnings.
        "cost_update" | "doom_loop_detected" => None,

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
        | "goal_tracker_transition"
        | "scratchpad_activity"
        | "hook_run"
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
        | "ask_user_mode"
        | "session_title"
        | "compaction_started"
        | "compaction_progress"
        | "compaction_completed"
        | "compaction_failed"
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
                #[serde(default)]
                usage: Option<Usage>,
                /// What this teammate actually cost, from the backend's durable
                /// spend record. `None` when nothing was recorded — which is a
                /// DIFFERENT fact from "$0.00" and must render differently.
                #[serde(default)]
                cost_usd: Option<f64>,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("background_agent_completed", e)),
            };
            let usage = ev.usage.unwrap_or_default();
            Some(BackendEvent::BackgroundAgentCompleted {
                agent_id: ev.agent_id,
                role: ev.role,
                result: ev.result,
                duration_ms: ev.duration_ms,
                total_tokens: usage.total_tokens,
                tool_uses: usage.tool_uses,
                cost_usd: ev.cost_usd,
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
                #[serde(default)]
                usage: Option<Usage>,
                /// See `background_agent_completed` — a failed run still cost
                /// money, and that is exactly when the user wants the number.
                #[serde(default)]
                cost_usd: Option<f64>,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("background_agent_failed", e)),
            };
            let usage = ev.usage.unwrap_or_default();
            Some(BackendEvent::BackgroundAgentFailed {
                agent_id: ev.agent_id,
                role: ev.role,
                error: ev.error,
                duration_ms: ev.duration_ms,
                total_tokens: usage.total_tokens,
                tool_uses: usage.tool_uses,
                cost_usd: ev.cost_usd,
            })
        }

        // Phase-aware stall report from the backend's watcher. It was emitted on
        // both the session topic and the Bus and had NO consumer here, so it fell
        // through to `ParseWarning` — the one surface that knew a teammate had
        // gone quiet threw the message away.
        "background_agent_stalled" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                #[serde(default)]
                agent_id: String,
                #[serde(default)]
                display_name: String,
                #[serde(default)]
                role: String,
                #[serde(default)]
                phase: String,
                #[serde(default)]
                stalled_ms: u64,
                #[serde(default)]
                message: String,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("background_agent_stalled", e)),
            };
            Some(BackendEvent::BackgroundAgentStalled {
                agent_id: ev.agent_id,
                display_name: ev.display_name,
                role: ev.role,
                phase: ev.phase,
                stalled_ms: ev.stalled_ms,
                message: ev.message,
            })
        }

        // Dispatch-phase narration. The backend now names what a subagent is
        // doing for the whole stretch before it has tool activity to report,
        // instead of leaving the panel to infer from silence.
        "background_agent_phase" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                #[serde(default)]
                agent_id: String,
                #[serde(default)]
                agent_name: String,
                #[serde(default)]
                display_name: String,
                #[serde(default)]
                phase: String,
                #[serde(default)]
                detail: String,
                #[serde(default)]
                elapsed_ms: Option<u64>,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("background_agent_phase", e)),
            };
            // The backend sends both keys with the same value; prefer whichever
            // is populated so the roster lookup by name always resolves.
            let agent_id = if ev.agent_id.is_empty() {
                ev.agent_name
            } else {
                ev.agent_id
            };
            Some(BackendEvent::BackgroundAgentPhase {
                agent_id,
                display_name: ev.display_name,
                phase: ev.phase,
                detail: ev.detail,
                elapsed_ms: ev.elapsed_ms,
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
                /// `"completed"` | `"failed"`, sent by `emit_agent_finished/6`.
                /// It was never deserialized, so a crashed teammate printed the
                /// same "finished" line as a successful one.
                #[serde(default)]
                status: String,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("agent_finished", e)),
            };
            Some(BackendEvent::AgentFinished {
                display_name: ev.display_name,
                duration_ms: ev.duration_ms,
                batch_id: ev.batch_id,
                status: ev.status,
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
            Some(BackendEvent::TaskNotification {
                count: ev.count,
                summary: ev.summary,
            })
        }

        // The authoritative turn-end edge. Carries no payload — its arrival IS
        // the information.
        "done" => Some(BackendEvent::TurnDone),

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

/// The backend's `usage` map on background-agent terminal frames
/// (`orchestrator.ex` builds it from the child's RunStore row).
///
/// Every field is `Option` on purpose: an ABSENT counter and a counter that is
/// genuinely zero are different facts, and the panel must be able to tell them
/// apart so it can leave its accumulated numbers alone instead of overwriting
/// them with a fabricated 0.
#[derive(serde::Deserialize, Default)]
struct Usage {
    #[serde(default)]
    total_tokens: Option<u32>,
    #[serde(default)]
    tool_uses: Option<u32>,
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
                #[serde(default)]
                elapsed_ms: Option<u64>,
            }
            let ev: Ev = serde_json::from_slice(data).ok()?;
            Some(BackendEvent::OrchestratorAgentStarted {
                agent_name: ev.agent_name,
                role: ev.role,
                model: ev.model,
                subject: ev.description,
                batch_id: ev.batch_id,
                elapsed_ms: ev.elapsed_ms,
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
                #[serde(default)]
                elapsed_ms: Option<u64>,
            }
            let ev: Ev = serde_json::from_slice(data).ok()?;
            Some(BackendEvent::OrchestratorAgentProgress {
                agent_name: ev.agent_name,
                current_action: ev.current_action,
                tool_uses: ev.tool_uses,
                tokens_used: ev.tokens_used,
                subject: ev.description,
                recent_actions: ev.recent_actions,
                elapsed_ms: ev.elapsed_ms,
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
                /// Absent on an older backend — see `BackendEvent::StreamingToken`.
                #[serde(default)]
                message_id: Option<String>,
            }
            let ev: Ev = serde_json::from_slice(data).ok()?;
            Some(BackendEvent::StreamingToken {
                text: ev.text,
                session_id: ev.session_id,
                message_id: ev.message_id,
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
                // The absolute thresholds the two fields above were derived
                // from. Defaulted to 0 ("unknown") so older backends still
                // parse; the status bar falls back to the reported values.
                #[serde(default)]
                compact_at: u64,
                #[serde(default)]
                warn_at: u64,
            }
            let ev: Ev = serde_json::from_slice(data).ok()?;
            Some(BackendEvent::ContextPressure {
                utilization: ev.utilization,
                estimated_tokens: ev.estimated_tokens,
                max_tokens: ev.max_tokens,
                percent_left: ev.percent_left,
                context_low: ev.context_low,
                compact_at: ev.compact_at,
                warn_at: ev.warn_at,
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

        "task_checklist_hide" => Some(BackendEvent::TaskChecklistHide),

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

        "goal_tracker_transition" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                #[serde(default)]
                action: String,
                #[serde(default)]
                status: String,
                #[serde(default)]
                phase: String,
                #[serde(default)]
                goal: Option<String>,
                #[serde(default)]
                goal_id: Option<String>,
                #[serde(default)]
                pause_reason: Option<String>,
                #[serde(default)]
                turn_count: u32,
                #[serde(default)]
                verify_run_count: u32,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("goal_tracker_transition", e)),
            };
            Some(BackendEvent::GoalTransition {
                action: ev.action,
                status: ev.status,
                phase: ev.phase,
                goal: ev.goal,
                goal_id: ev.goal_id,
                pause_reason: ev.pause_reason,
                turn_count: ev.turn_count,
                verify_run_count: ev.verify_run_count,
            })
        }

        "compaction_started" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                #[serde(default)]
                trigger: String,
                #[serde(default)]
                tokens_before: u64,
            }
            let ev: Ev = serde_json::from_slice(data).ok()?;
            Some(BackendEvent::CompactionStarted {
                trigger: ev.trigger,
                tokens_before: ev.tokens_before,
            })
        }

        "compaction_progress" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                #[serde(default)]
                chunk_index: u32,
                #[serde(default)]
                chunk_total: u32,
            }
            let ev: Ev = serde_json::from_slice(data).ok()?;
            // A zero total carries no ratio. Drop it rather than letting a
            // divide-by-zero become a 0%-forever or 100%-instantly bar.
            if ev.chunk_total == 0 {
                return None;
            }
            Some(BackendEvent::CompactionProgress {
                chunk_index: ev.chunk_index.min(ev.chunk_total),
                chunk_total: ev.chunk_total,
            })
        }

        "compaction_completed" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                #[serde(default)]
                tokens_before: u64,
                #[serde(default)]
                tokens_after: u64,
                #[serde(default)]
                messages_before: u32,
                #[serde(default)]
                messages_after: u32,
                #[serde(default)]
                duration_ms: u64,
            }
            let ev: Ev = serde_json::from_slice(data).ok()?;
            Some(BackendEvent::CompactionCompleted {
                tokens_before: ev.tokens_before,
                tokens_after: ev.tokens_after,
                messages_before: ev.messages_before,
                messages_after: ev.messages_after,
                duration_ms: ev.duration_ms,
            })
        }

        "compaction_failed" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                #[serde(default)]
                reason: String,
                #[serde(default)]
                duration_ms: u64,
            }
            let ev: Ev = serde_json::from_slice(data).ok()?;
            Some(BackendEvent::CompactionFailed {
                reason: ev.reason,
                duration_ms: ev.duration_ms,
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

        "hook_run" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                hook_name: String,
                #[serde(default)]
                hook_event: String,
                #[serde(default)]
                outcome: String,
                #[serde(default)]
                duration_ms: u64,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("hook_run", e)),
            };
            Some(BackendEvent::HookRun {
                hook_name: ev.hook_name,
                hook_event: ev.hook_event,
                outcome: ev.outcome,
                duration_ms: ev.duration_ms,
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

        // Whether the agent may block the turn on a question. Defaults to false
        // on a missing field, which matches the backend default — a parse that
        // silently read "on" would be the worst possible direction to fail.
        "ask_user_mode" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                #[serde(default)]
                enabled: bool,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("ask_user_mode", e)),
            };
            Some(BackendEvent::AskUserMode {
                enabled: ev.enabled,
            })
        }

        // The session's human-readable title. Emitted twice in the normal case:
        // once with the instant heuristic title when the first prompt lands, then
        // again if the backend's small-model refinement improves it. An empty
        // title is dropped rather than blanking a good one.
        "session_title" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                #[serde(default)]
                title: String,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("session_title", e)),
            };
            if ev.title.trim().is_empty() {
                return None;
            }
            Some(BackendEvent::SessionTitle {
                title: ev.title.trim().to_string(),
            })
        }

        "overdrive_resumed" => {
            #[derive(serde::Deserialize)]
            struct Ev {
                #[serde(default)]
                message: String,
            }
            let ev: Ev = match serde_json::from_slice(data) {
                Ok(e) => e,
                Err(e) => return Some(parse_warning("overdrive_resumed", e)),
            };
            if ev.message.trim().is_empty() {
                None
            } else {
                Some(BackendEvent::SystemNotice {
                    message: ev.message,
                    level: "warning".to_string(),
                })
            }
        }

        // Internal bookkeeping events have no user-facing state to update.
        // They are still known protocol members and must not be reported as
        // parser failures.
        "progress_ledger" | "cost_update" | "doom_loop_detected" => None,

        // Multi-agent workflow events may also arrive wrapped as a system_event
        // (with an `event` field). Delegate to the top-level parser, which builds
        // them from the same frame data.
        "agent_finished"
        | "agent_message"
        | "background_command_completed"
        | "turn_recap"
        | "provider_retry"
        | "error" => parse_sse_event(base.event.as_str(), data),

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

    /// The idle budget must stay at or above three server keepalive intervals
    /// (`session_routes.ex` chunks `: keepalive` every 30s). Tighter than that
    /// and a single missed keepalive tears down a perfectly healthy stream.
    #[test]
    fn the_idle_timeout_leaves_room_for_three_keepalives() {
        const SERVER_KEEPALIVE: Duration = Duration::from_secs(30);
        assert!(
            IDLE_TIMEOUT >= SERVER_KEEPALIVE * 3,
            "idle timeout {:?} must not be tighter than 3 keepalive intervals",
            IDLE_TIMEOUT
        );
    }

    #[test]
    fn known_internal_events_do_not_become_parse_warnings() {
        let direct = br#"{"type":"cost_update","session_cost_usd":0.42}"#;
        assert!(parse_sse_event("cost_update", direct).is_none());

        let progress = br#"{"type":"system_event","event":"progress_ledger","action":"append"}"#;
        assert!(parse_sse_event("system_event", progress).is_none());

        let doom = br#"{"type":"doom_loop_detected","tool_name":"file_read"}"#;
        assert!(parse_sse_event("doom_loop_detected", doom).is_none());
    }

    #[test]
    fn resumed_overdrive_is_a_visible_warning() {
        let frame = br#"{"type":"system_event","event":"overdrive_resumed","message":"full auto restored"}"#;
        match parse_sse_event("system_event", frame) {
            Some(BackendEvent::SystemNotice { message, level }) => {
                assert_eq!(message, "full auto restored");
                assert_eq!(level, "warning");
            }
            other => panic!("unexpected: {:?}", other),
        }
    }

    /// THE defect: a half-open connection yields neither bytes nor an error, so
    /// the read parked forever and the reconnect path below it never ran — the
    /// UI stopped updating for the rest of the session with no error anywhere.
    ///
    /// This drives the real client against a real socket that completes the
    /// HTTP response head, delivers one event, and then goes silent forever
    /// without closing (exactly what a dropped NAT flow looks like). The client
    /// must give up on its own and report a *mid-stream* drop, which is the
    /// variant the reconnect loop retries.
    #[tokio::test]
    async fn a_silent_half_open_stream_gives_up_instead_of_parking_forever() {
        use tokio::io::AsyncWriteExt;

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();

        // Server: answer the request, send one frame, then never speak again
        // and never close. Holding the socket alive is the whole point.
        let server = tokio::spawn(async move {
            let (mut sock, _) = listener.accept().await.unwrap();
            // Drain the request head so the client's write completes.
            let mut buf = [0u8; 1024];
            let _ = tokio::io::AsyncReadExt::read(&mut sock, &mut buf).await;
            sock.write_all(
                b"HTTP/1.1 200 OK\r\n\
                  Content-Type: text/event-stream\r\n\
                  Transfer-Encoding: chunked\r\n\r\n",
            )
            .await
            .unwrap();
            // One well-formed keepalive comment (0xd = 13 bytes), then silence.
            sock.write_all(b"d\r\n: keepalive\n\n\r\n").await.unwrap();
            sock.flush().await.unwrap();
            // Park, holding the connection open.
            std::future::pending::<()>().await;
        });

        let (tx, _rx) = mpsc::unbounded_channel();
        let client = SseClient::with_cancel(
            "s1".to_string(),
            format!("http://{addr}"),
            String::new(),
            tx,
            CancellationToken::new(),
        )
        // The production budget is 90s; the *mechanism* is what is under test,
        // so shorten it rather than make the suite wait. A paused clock is not
        // usable here — the runtime is parked on real socket I/O, so it never
        // auto-advances.
        .with_idle_timeout(Duration::from_millis(300));

        // An order-of-magnitude outer bound: if the read parks forever again
        // this fails the suite instead of hanging it.
        let outcome = tokio::time::timeout(Duration::from_secs(10), client.connect_once()).await;

        server.abort();

        let Ok(result) = outcome else {
            panic!(
                "connect_once never returned — the read is parked forever on a half-open stream"
            );
        };
        match result {
            Err(SseError::Disconnected { connected, err }) => {
                assert!(
                    connected,
                    "an idle timeout happens AFTER the body attached, so it must \
                     report connected=true and reset the reconnect budget"
                );
                assert!(
                    err.to_string().contains("idle"),
                    "the surfaced error should name the idle timeout: {err}"
                );
            }
            other => panic!("expected a mid-stream Disconnected, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn a_missing_session_is_not_retried_as_a_network_failure() {
        use tokio::io::AsyncWriteExt;

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (mut sock, _) = listener.accept().await.unwrap();
            let mut buf = [0u8; 1024];
            let _ = tokio::io::AsyncReadExt::read(&mut sock, &mut buf).await;
            sock.write_all(
                b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            )
            .await
            .unwrap();
        });

        let (tx, _rx) = mpsc::unbounded_channel();
        let client = SseClient::with_cancel(
            "missing-session".to_string(),
            format!("http://{addr}"),
            String::new(),
            tx,
            CancellationToken::new(),
        );

        let result = client.connect_once().await;
        server.await.unwrap();
        assert!(
            matches!(result, Err(SseError::SessionNotFound)),
            "a permanent 404 must trigger session recovery, not ten reconnects: {result:?}"
        );
    }

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
        let legacy =
            br#"{"event":"goal_verifier_round","verdict":"complete","refuted_count":0,"total":3}"#;
        match parse_sse_event("goal_verifier_round", legacy) {
            Some(BackendEvent::GoalVerification { phase, verdict, .. }) => {
                assert_eq!(phase, "done");
                assert_eq!(verdict, "complete");
            }
            other => panic!("unexpected: {:?}", other),
        }
    }

    #[test]
    fn parses_authoritative_goal_tracker_transition() {
        let data = br#"{"event":"goal_tracker_transition","action":"paused","status":"paused","phase":"idle","goal":"Ship the release","goal_id":"goal-1","pause_reason":"user","turn_count":3,"verify_run_count":1}"#;
        match parse_sse_event("goal_tracker_transition", data) {
            Some(BackendEvent::GoalTransition {
                status,
                goal,
                pause_reason,
                turn_count,
                ..
            }) => {
                assert_eq!(status, "paused");
                assert_eq!(goal.as_deref(), Some("Ship the release"));
                assert_eq!(pause_reason.as_deref(), Some("user"));
                assert_eq!(turn_count, 3);
            }
            other => panic!("expected goal transition, got {other:?}"),
        }
    }

    #[test]
    fn parses_the_compaction_lifecycle() {
        // Before this existed, compaction frames fell through the `parse_sse_event`
        // allowlist and were dropped, so a multi-minute blocking step rendered as
        // a frozen UI. These four frames are the exact shapes
        // `Agent.CompactionEvents` broadcasts on `osa:session:<id>`.
        let started = br#"{"type":"system_event","event":"compaction_started","session_id":"s1","trigger":"manual","tokens_before":84000}"#;
        match parse_sse_event("compaction_started", started) {
            Some(BackendEvent::CompactionStarted {
                trigger,
                tokens_before,
            }) => {
                assert_eq!(trigger, "manual");
                assert_eq!(tokens_before, 84_000);
            }
            other => panic!("unexpected: {:?}", other),
        }

        let progress = br#"{"type":"system_event","event":"compaction_progress","session_id":"s1","chunk_index":6,"chunk_total":10}"#;
        match parse_sse_event("compaction_progress", progress) {
            Some(BackendEvent::CompactionProgress {
                chunk_index,
                chunk_total,
            }) => {
                assert_eq!(chunk_index, 6);
                assert_eq!(chunk_total, 10);
            }
            other => panic!("unexpected: {:?}", other),
        }

        let completed = br#"{"type":"system_event","event":"compaction_completed","session_id":"s1","tokens_before":84000,"tokens_after":21000,"messages_before":52,"messages_after":14,"duration_ms":134000}"#;
        match parse_sse_event("compaction_completed", completed) {
            Some(BackendEvent::CompactionCompleted {
                tokens_before,
                tokens_after,
                messages_before,
                messages_after,
                duration_ms,
            }) => {
                assert_eq!(tokens_before, 84_000);
                assert_eq!(tokens_after, 21_000);
                // The rendered line says "38 messages folded" — derived here, not
                // sent as a separate number that could disagree.
                assert_eq!(messages_before - messages_after, 38);
                assert_eq!(duration_ms, 134_000);
            }
            other => panic!("unexpected: {:?}", other),
        }

        let failed = br#"{"type":"system_event","event":"compaction_failed","session_id":"s1","reason":"summarizer timeout","duration_ms":90000}"#;
        match parse_sse_event("compaction_failed", failed) {
            Some(BackendEvent::CompactionFailed {
                reason,
                duration_ms,
            }) => {
                assert_eq!(reason, "summarizer timeout");
                assert_eq!(duration_ms, 90_000);
            }
            other => panic!("unexpected: {:?}", other),
        }
    }

    #[test]
    fn compaction_progress_without_a_real_total_is_dropped() {
        // A zero total carries no ratio. It must be dropped at the parser rather
        // than reaching the renderer, where it could only become a bar that is
        // stuck at 0% or claims 100% instantly. Neither describes reality.
        let zero = br#"{"type":"system_event","event":"compaction_progress","session_id":"s1","chunk_index":1,"chunk_total":0}"#;
        assert!(parse_sse_event("compaction_progress", zero).is_none());

        // An index past the total is clamped, never rendered as >100%.
        let over = br#"{"type":"system_event","event":"compaction_progress","session_id":"s1","chunk_index":99,"chunk_total":8}"#;
        match parse_sse_event("compaction_progress", over) {
            Some(BackendEvent::CompactionProgress {
                chunk_index,
                chunk_total,
            }) => {
                assert_eq!(chunk_index, 8);
                assert_eq!(chunk_total, 8);
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
            Some(BackendEvent::ScratchpadActivity {
                agent,
                entry,
                action,
                bytes,
            }) => {
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
            Some(BackendEvent::OrchestratorAgentCompleted {
                agent_name,
                summary,
                ..
            }) => {
                assert_eq!(agent_name, "w1");
                assert_eq!(summary.as_deref(), Some("Found 4 dead paths"));
            }
            other => panic!("unexpected: {:?}", other),
        }

        // Failure frame carries the error summary on the same field.
        let fail = br#"{"type":"system_event","event":"orchestrator_agent_completed","session_id":"s1","agent_name":"w2","status":"failed","error":"boom","summary":"boom: join timeout"}"#;
        match parse_sse_event("orchestrator_agent_completed", fail) {
            Some(BackendEvent::OrchestratorAgentFailed {
                agent_name,
                summary,
                ..
            }) => {
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

    /// FIX 1 — `orchestrator.ex` has always put a `usage` map on the background
    /// completion/failure broadcast (`total_tokens`, `tool_uses`, `duration_ms`).
    /// The parser simply never looked at it, which is why the handler fell back
    /// to a hardcoded `0, 0`.
    #[test]
    fn parses_background_agent_usage_and_distinguishes_absent_from_zero() {
        let with_usage = br#"{"type":"background_agent_completed","agent_id":"agent:s1:1","role":"researcher","result":"ok","duration_ms":91000,"usage":{"total_tokens":40123,"tool_uses":12,"duration_ms":91000},"output_file":"/tmp/x.md"}"#;
        match parse_sse_event("background_agent_completed", with_usage) {
            Some(BackendEvent::BackgroundAgentCompleted {
                total_tokens,
                tool_uses,
                ..
            }) => {
                assert_eq!(total_tokens, Some(40123));
                assert_eq!(tool_uses, Some(12));
            }
            other => panic!("unexpected: {:?}", other),
        }

        // Legacy frame with no `usage` at all → None, NOT Some(0). The handler
        // relies on this distinction to leave the panel's counters alone.
        let legacy = br#"{"type":"background_agent_completed","agent_id":"agent:s1:1","role":"researcher","result":"ok","duration_ms":91000}"#;
        match parse_sse_event("background_agent_completed", legacy) {
            Some(BackendEvent::BackgroundAgentCompleted {
                total_tokens,
                tool_uses,
                ..
            }) => {
                assert_eq!(total_tokens, None, "absent usage must not decode as 0");
                assert_eq!(tool_uses, None, "absent usage must not decode as 0");
            }
            other => panic!("unexpected: {:?}", other),
        }

        // The failure broadcast carries the same map.
        let failed = br#"{"type":"background_agent_failed","agent_id":"agent:s1:2","role":"coder","error":"boom","duration_ms":50,"usage":{"total_tokens":7,"tool_uses":2,"duration_ms":50}}"#;
        match parse_sse_event("background_agent_failed", failed) {
            Some(BackendEvent::BackgroundAgentFailed {
                total_tokens,
                tool_uses,
                ..
            }) => {
                assert_eq!((total_tokens, tool_uses), (Some(7), Some(2)));
            }
            other => panic!("unexpected: {:?}", other),
        }
    }

    /// `Orchestrator.run_cost_usd/1` has always been real and durable, but it
    /// rode NO event — the panel could only ever show a whole-task estimate and
    /// said so in its footer. The backend now attaches `cost_usd` to both
    /// terminal broadcasts, and `nil` (a run with no recorded spend) must decode
    /// as `None`, never as `Some(0.0)`: "free" is a claim, "unmeasured" is not.
    #[test]
    fn parses_background_agent_cost_and_distinguishes_absent_from_zero() {
        let priced = br#"{"type":"background_agent_completed","agent_id":"agent:s1:1","role":"researcher","result":"ok","duration_ms":91000,"usage":{"total_tokens":40123,"tool_uses":12,"duration_ms":91000},"cost_usd":0.0431}"#;
        match parse_sse_event("background_agent_completed", priced) {
            Some(BackendEvent::BackgroundAgentCompleted { cost_usd, .. }) => {
                assert_eq!(cost_usd, Some(0.0431));
            }
            other => panic!("unexpected: {:?}", other),
        }

        // Backend sent `cost_usd: nil` (no spend record) — absent, not zero.
        let unpriced = br#"{"type":"background_agent_completed","agent_id":"agent:s1:1","role":"researcher","result":"ok","duration_ms":91000,"cost_usd":null}"#;
        match parse_sse_event("background_agent_completed", unpriced) {
            Some(BackendEvent::BackgroundAgentCompleted { cost_usd, .. }) => {
                assert_eq!(cost_usd, None, "an unrecorded cost must not decode as 0");
            }
            other => panic!("unexpected: {:?}", other),
        }

        // A run that FAILED still cost money — that is when the number matters.
        let failed = br#"{"type":"background_agent_failed","agent_id":"agent:s1:2","role":"coder","error":"boom","duration_ms":50,"cost_usd":1.25}"#;
        match parse_sse_event("background_agent_failed", failed) {
            Some(BackendEvent::BackgroundAgentFailed { cost_usd, .. }) => {
                assert_eq!(cost_usd, Some(1.25));
            }
            other => panic!("unexpected: {:?}", other),
        }
    }

    /// FIX 2 — `emit_agent_finished/6` sends `status: "completed" | "failed"`.
    /// The `Ev` struct had no such field, so a crashed teammate rendered the
    /// identical "finished" line as a successful one.
    #[test]
    fn agent_finished_carries_its_status() {
        let failed = br#"{"type":"agent_finished","display_name":"explorer","duration_ms":1200,"status":"failed"}"#;
        match parse_sse_event("agent_finished", failed) {
            Some(BackendEvent::AgentFinished {
                status,
                display_name,
                ..
            }) => {
                assert_eq!(status, "failed");
                assert_eq!(display_name, "explorer");
            }
            other => panic!("unexpected: {:?}", other),
        }

        let ok = br#"{"type":"agent_finished","display_name":"explorer","duration_ms":1200,"status":"completed"}"#;
        match parse_sse_event("agent_finished", ok) {
            Some(BackendEvent::AgentFinished { status, .. }) => assert_eq!(status, "completed"),
            other => panic!("unexpected: {:?}", other),
        }

        // Legacy frame with no status → empty, and the handler stays neutral.
        let legacy = br#"{"type":"agent_finished","display_name":"explorer","duration_ms":1200}"#;
        match parse_sse_event("agent_finished", legacy) {
            Some(BackendEvent::AgentFinished { status, .. }) => assert_eq!(status, ""),
            other => panic!("unexpected: {:?}", other),
        }
    }

    /// FIX 5 — the stall event was emitted on the session topic and on the Bus
    /// and had NO consumer here, so it hit the catch-all and became a
    /// `ParseWarning`. The one signal that a teammate had gone quiet was thrown
    /// away by the only surface watching.
    #[test]
    fn parses_background_agent_stalled_instead_of_warning_about_it() {
        let frame = br#"{"type":"background_agent_stalled","session_id":"s1","agent_id":"agent:s1:1","display_name":"explorer","role":"researcher","phase":"working","stalled_ms":840000,"tool_count":3,"message":"Background agent @explorer has made no progress for 14 minutes: it ran 3 tool(s) and then went quiet"}"#;
        match parse_sse_event("background_agent_stalled", frame) {
            Some(BackendEvent::BackgroundAgentStalled {
                agent_id,
                display_name,
                phase,
                stalled_ms,
                message,
                ..
            }) => {
                assert_eq!(agent_id, "agent:s1:1");
                assert_eq!(display_name, "explorer");
                assert_eq!(phase, "working");
                assert_eq!(stalled_ms, 840_000);
                assert!(message.contains("no progress"));
            }
            other => panic!("stall must not fall through to ParseWarning: {:?}", other),
        }
    }

    #[test]
    fn parses_session_title() {
        // Arrives either under its own frame name or wrapped as a system_event,
        // depending on whether the SSE loop unwrapped it.
        let data = br#"{"type":"system_event","event":"session_title","session_id":"s1","title":"Debugging production 500 errors"}"#;
        for frame in ["session_title", "system_event"] {
            match parse_sse_event(frame, data) {
                Some(BackendEvent::SessionTitle { title }) => {
                    assert_eq!(title, "Debugging production 500 errors")
                }
                other => panic!("unexpected for {}: {:?}", frame, other),
            }
        }
    }

    #[test]
    fn session_title_trims_and_drops_blanks() {
        let padded = br#"{"type":"system_event","event":"session_title","session_id":"s1","title":"  Rate limiting implementation  "}"#;
        match parse_sse_event("session_title", padded) {
            Some(BackendEvent::SessionTitle { title }) => {
                assert_eq!(title, "Rate limiting implementation")
            }
            other => panic!("unexpected: {:?}", other),
        }

        // A blank title must never blank out a good one.
        let blank =
            br#"{"type":"system_event","event":"session_title","session_id":"s1","title":"   "}"#;
        assert!(parse_sse_event("session_title", blank).is_none());

        let missing = br#"{"type":"system_event","event":"session_title","session_id":"s1"}"#;
        assert!(parse_sse_event("session_title", missing).is_none());
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

    /// The exact frame `Events.TuiForwarder` now puts on the wire for a
    /// blocking `ask_user` call. Before the fix the backend never emitted this
    /// at all (the sub-event was missing from the forwarder allowlist), so the
    /// picker never opened and the tool hung on its own timeout.
    #[test]
    fn parses_ask_user_question_frame_from_the_forwarder() {
        let data = br##"{"type":"system_event","event":"ask_user_question","session_id":"s1","survey_id":"#Reference<0.1.2.3>","skippable":true,"questions":[{"text":"Which parser should we keep?","multi_select":false,"skippable":true,"options":[{"label":"Rewrite the parser (Recommended)","description":"removes the whole class of escaping bugs"},{"label":"Patch in place","description":"faster but the bug class stays"}]}]}"##;

        // Arrives either under its own frame name or wrapped as a system_event.
        for frame in ["ask_user_question", "system_event"] {
            match parse_sse_event(frame, data) {
                Some(BackendEvent::AskUserQuestion {
                    survey_id,
                    questions,
                    skippable,
                }) => {
                    assert_eq!(survey_id, "#Reference<0.1.2.3>");
                    assert!(skippable, "must be dismissable with Esc");
                    assert_eq!(questions.len(), 1);
                    assert_eq!(questions[0].text, "Which parser should we keep?");
                    assert_eq!(questions[0].options.len(), 2);
                    assert_eq!(
                        questions[0].options[0].label,
                        "Rewrite the parser (Recommended)"
                    );
                    assert_eq!(
                        questions[0].options[0].description.as_deref(),
                        Some("removes the whole class of escaping bugs")
                    );
                }
                other => panic!("unexpected for {}: {:?}", frame, other),
            }
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
