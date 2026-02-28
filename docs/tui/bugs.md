# TUI Known Issues & Bug Tracker

> Tracked issues for the Go TUI (`bin/osa`).
> Last updated: 2026-02-28

---

## Open

### BUG-001: swarm_cancelled and swarm_timeout SSE events not parsed
**Severity:** Medium
**File:** `priv/go/tui/client/sse.go` → `parseSystemEvent()`
**Description:** Backend emits `swarm_cancelled` and `swarm_timeout` system events with `session_id`, but the TUI's `parseSystemEvent()` only handles `swarm_started`, `swarm_completed`, and `swarm_failed`. The cancelled/timeout events are silently logged as "unknown system_event" to stderr.
**Fix:** Add event types + cases to sse.go, add handlers in app.go (terminate processing state, show message).

### BUG-002: RefreshToken endpoint defined but never called
**Severity:** Low
**File:** `priv/go/tui/client/http.go`
**Description:** `RefreshToken()` method exists on the Client but is never invoked. If a JWT expires mid-session, the SSE stream will 401 and prompt re-login rather than transparently refreshing. Should add periodic refresh or refresh-on-401-before-reprompt logic.

### BUG-003: Plan detection is fragile (string prefix match)
**Severity:** Medium
**File:** `priv/go/tui/app/app.go`
**Description:** Plan review mode is triggered by checking if the agent response contains `"## Plan"` or `"# Plan"` as a string prefix. This can false-positive on any response that starts with a "Plan" heading, or false-negative if the plan heading has different formatting (e.g., `**Plan:**`). Should use a structured signal from the backend (e.g., a `plan_review` SSE event type) instead of content sniffing.

### BUG-004: OrchestrateComplex client method unused
**Severity:** Low
**File:** `priv/go/tui/client/http.go`
**Description:** `OrchestrateComplex()` is defined but never called from app.go. The complex orchestration flow (multi-stage swarm) has no UI trigger. Either wire it up to a `/complex` command or remove the dead code.

### BUG-005: Progress polling endpoint unused
**Severity:** Low
**File:** `priv/go/tui/client/http.go`
**Description:** `GET /orchestrate/:task_id/progress` is defined in the client but never polled. SSE handles progress events. However, if SSE drops and reconnect fails, there's no fallback to poll for progress. Consider polling as SSE backup after reconnect exhaustion.

### BUG-006: Classify endpoint unused
**Severity:** Low
**File:** `priv/go/tui/client/http.go`
**Description:** `POST /classify` is defined but never called. Signal classification arrives via the agent_response SSE event. The standalone classify endpoint could be useful for a `/classify` command or pre-classification before submit.

### BUG-007: No rate limit handling (HTTP 429)
**Severity:** Medium
**File:** `priv/go/tui/client/http.go`
**Description:** None of the HTTP client methods check for 429 Too Many Requests. If the backend rate-limits the TUI, it gets a generic error. Should detect 429, parse `Retry-After` header, and display a user-friendly backoff message.

### BUG-008: Task list doesn't reset between orchestrations
**Severity:** Low
**File:** `priv/go/tui/model/tasks.go`
**Description:** Tasks from previous orchestrations persist in the task list. When a new request spawns new tasks, old completed/failed tasks remain visible. Should clear or archive old tasks when a new orchestration starts.

### BUG-009: Plan rejection doesn't capture structured feedback
**Severity:** Low
**File:** `priv/go/tui/model/plan.go`, `app/app.go`
**Description:** When a user selects "Edit" on a plan, the input is pre-filled with "Revise the plan: " but there's no structured feedback mechanism. The rejection reason is sent as a plain orchestrate message. Consider a dedicated feedback field or structured rejection payload.

### BUG-010: Scanner buffer starts at 0 bytes
**Severity:** Cosmetic
**File:** `priv/go/tui/client/sse.go:229`
**Description:** `scanner.Buffer(make([]byte, 0), 1024*1024)` passes a zero-length initial buffer. Go's bufio.Scanner allocates its own buffer anyway, so this works, but the conventional form is `make([]byte, 4096)` for the initial allocation.

---

## Pipeline Audit Findings (2026-02-28)

> Full audit of Backend → SSE → TUI data pipeline. The backend emits 63+ system_event types.
> The TUI parses 18 (28% coverage). 45+ events are silently dropped.

### BUG-011: 45+ backend events missing session_id — never reach TUI [CRITICAL]
**Severity:** Critical
**Scope:** Backend (`lib/optimal_system_agent/agent/orchestrator.ex`, `swarm/intelligence.ex`, `swarm/pact.ex`, `agent/hooks.ex`, `agent/learning.ex`, `budget.ex`, `treasury.ex`)
**Description:** The SSE bridge routes events to `osa:session:{session_id}`. Events without `session_id` go to a global firehose the TUI never subscribes to. The following event categories are completely invisible to the TUI:

| Category | Events | session_id? | Impact |
|----------|--------|-------------|--------|
| Agent Orchestrator | orchestrator_task_started, _appraised, _agents_spawning, _wave_started, _agent_started, _agent_progress, _agent_completed, _agent_failed, _task_completed, _task_failed, _synthesis_started, _synthesis_completed | **NO** | Orchestrator progress panel shows nothing |
| Swarm Intelligence | swarm_intelligence_round, _vote, _consensus_progress, _converged, _diverged, _deadlocked | NO | Swarm appears frozen between launch and completion |
| Pact Workflows | pact_proposed, _voted, _ratified, _rejected, _expired, _revoked, _enacted, _rollback, _checkpoint | NO | Pact system invisible |
| Budget | budget_warning, budget_exceeded, cost_tier_update, budget_reset | NO (except cost_recorded) | Spending limits invisible |
| Treasury | treasury_*, balance_*, payout_* | NO | Token economics invisible |
| Learning | learning_consolidation, pattern_detected, skill_generated, error_recovered | NO | Self-improvement invisible |
| Hooks | hook_blocked | NO | Security violations invisible |
| Scheduler | heartbeat, proactive_alert | NO | Scheduler invisible |

**Fix:** Add `session_id` to all Bus.emit calls in the affected modules, same pattern used in `swarm/orchestrator.ex`.

### BUG-012: task_created/task_updated are ghost events — backend never emits them [CRITICAL]
**Severity:** Critical
**Files:** `priv/go/tui/client/sse.go:463-472` (parser), `priv/go/tui/model/tasks.go` (display)
**Description:** The TUI parses `task_created` and `task_updated` system events and has a full TasksModel panel to display them. However, the backend **never emits** events with those names. The backend's task queue (`lib/optimal_system_agent/task_queue.ex`) emits `task_enqueued`, `task_completed`, `task_failed`, `task_leased` — completely different names. The TUI's task checklist panel is dead UI that never gets populated.
**Fix:** Either:
- (a) Rename TUI parsers to match backend event names (`task_enqueued` → `TaskCreatedEvent`, etc.)
- (b) Add `task_created`/`task_updated` emissions in the backend at appropriate lifecycle points
- (c) Both — wire up task_queue events AND add Claude Code-style task tracking events

### BUG-013: Agent Orchestrator events never reach TUI despite having handlers [CRITICAL]
**Severity:** Critical
**Files:** `lib/optimal_system_agent/agent/orchestrator.ex`, `priv/go/tui/client/sse.go`, `priv/go/tui/app/app.go`
**Description:** The TUI has full handlers for `orchestrator_task_started`, `orchestrator_wave_started`, `orchestrator_agent_started`, `orchestrator_agent_progress`, `orchestrator_agent_completed`, `orchestrator_agent_failed`, `orchestrator_task_completed` — with a dedicated AgentsModel panel showing roles, waves, tool counts, token usage. But Agent.Orchestrator's Bus.emit calls don't include `session_id`, so these events never reach the TUI's session-scoped SSE stream. The multi-agent progress panel is fully built but always empty.
**Fix:** Add `session_id` to all 12 Bus.emit calls in `agent/orchestrator.ex`. The orchestrator's TaskState already stores `session_id` (from the orchestrate API call) — it just needs to be included in the event payloads.

### BUG-014: Swarm intelligence rounds invisible — no SSE events parsed
**Severity:** Medium
**Files:** `lib/optimal_system_agent/swarm/intelligence.ex`, `priv/go/tui/client/sse.go`
**Description:** Swarm Intelligence emits 6 event types (round progress, votes, consensus, convergence, divergence, deadlock) during debate/review patterns. None are parsed by the TUI. During a debate swarm, the user sees "Swarm launched" then nothing until "Swarm completed" — potentially minutes of silence.
**Fix:** Add event types + parsers in sse.go, add progress display in app.go (could reuse the activity panel or agents panel).

### BUG-015: Budget warnings and spending limits invisible
**Severity:** Medium
**Files:** `lib/optimal_system_agent/budget.ex`, `priv/go/tui/client/sse.go`
**Description:** Backend emits `budget_warning` (75% threshold), `budget_exceeded` (100%), and `cost_recorded` events. None reach the TUI because they lack `session_id` (except `cost_recorded`). User has no visibility into token spending or budget limits.
**Fix:** Add `session_id` to budget events. Add TUI parsers. Display as system warnings in chat.

### BUG-016: Security hook blocks invisible to user
**Severity:** High
**Files:** `lib/optimal_system_agent/agent/hooks.ex`, `priv/go/tui/client/sse.go`
**Description:** When the security hook blocks a dangerous command (e.g., `rm -rf`), it emits `hook_blocked` without `session_id`. The user never sees that their action was blocked or why. The processing state may hang with no feedback.
**Fix:** Add `session_id` to hook_blocked emissions. Parse in TUI. Display as system error with the blocked reason.

---

## Pipeline Coverage Map

```
Backend Event                    → SSE Bridge → TUI Parser → TUI Handler → Display
─────────────────────────────────────────────────────────────────────────────────────
agent_response                   ✓ session_id  ✓ parsed     ✓ handled     ✓ chat message
llm_request                      ✓ session_id  ✓ parsed     ✓ handled     ✓ iteration counter
llm_response                     ✓ session_id  ✓ parsed     ✓ handled     ✓ token counter
tool_call (start/end)            ✓ session_id  ✓ parsed     ✓ handled     ✓ activity feed
context_pressure                 ✓ session_id  ✓ parsed     ✓ handled     ✓ context bar
swarm_started                    ✓ session_id  ✓ parsed     ✓ handled     ✓ system message
swarm_completed                  ✓ session_id  ✓ parsed     ✓ handled     ✓ agent message
swarm_failed                     ✓ session_id  ✓ parsed     ✓ handled     ✓ error message
swarm_cancelled                  ✓ session_id  ✗ NOT PARSED ✗             ✗ (BUG-001)
swarm_timeout                    ✓ session_id  ✗ NOT PARSED ✗             ✗ (BUG-001)
orchestrator_task_started        ✗ NO SID      ✓ parsed     ✓ handled     ✗ DEAD (BUG-013)
orchestrator_wave_started        ✗ NO SID      ✓ parsed     ✓ handled     ✗ DEAD (BUG-013)
orchestrator_agent_started       ✗ NO SID      ✓ parsed     ✓ handled     ✗ DEAD (BUG-013)
orchestrator_agent_progress      ✗ NO SID      ✓ parsed     ✓ handled     ✗ DEAD (BUG-013)
orchestrator_agent_completed     ✗ NO SID      ✓ parsed     ✓ handled     ✗ DEAD (BUG-013)
orchestrator_agent_failed        ✗ NO SID      ✓ parsed     ✓ handled     ✗ DEAD (BUG-013)
orchestrator_task_completed      ✗ NO SID      ✓ parsed     ✓ handled     ✗ DEAD (BUG-013)
task_created                     ✗ NEVER EMITTED ✓ parsed   ✓ handled     ✗ DEAD (BUG-012)
task_updated                     ✗ NEVER EMITTED ✓ parsed   ✓ handled     ✗ DEAD (BUG-012)
budget_warning                   ✗ NO SID      ✗ not parsed ✗             ✗ (BUG-015)
budget_exceeded                  ✗ NO SID      ✗ not parsed ✗             ✗ (BUG-015)
hook_blocked                     ✗ NO SID      ✗ not parsed ✗             ✗ (BUG-016)
swarm_intelligence_round         ✗ NO SID      ✗ not parsed ✗             ✗ (BUG-014)
swarm_intelligence_converged     ✗ NO SID      ✗ not parsed ✗             ✗ (BUG-014)
learning_consolidation           ✗ NO SID      ✗ not parsed ✗             ✗ (LOW)
pact_*                           ✗ NO SID      ✗ not parsed ✗             ✗ (LOW)
treasury_*                       ✗ NO SID      ✗ not parsed ✗             ✗ (LOW)
```

---

## Recently Fixed (2026-02-28)

### FIXED: session_map memory leak in orchestrator
**Files:** `lib/optimal_system_agent/swarm/orchestrator.ex`
**Issue:** `session_map` entries were never cleaned up when swarms reached terminal state (cancelled/completed/failed/timeout).
**Fix:** Eliminated `session_map` entirely. All event emissions now read `session_id` from `swarm.session_id` directly — single source of truth.

### FIXED: SwarmCompleted/Failed didn't terminate StateProcessing
**Files:** `priv/go/tui/app/app.go`
**Issue:** If a swarm completed without a subsequent `agent_response`, the TUI stayed in `StateProcessing` forever — user could never type again.
**Fix:** Swarm terminal events now stop activity, clear processing view, set `StateIdle`, and re-focus input.

### FIXED: Empty ResultPreview produced blank agent message
**Files:** `priv/go/tui/app/app.go`
**Issue:** `SwarmCompletedEvent` with empty `ResultPreview` called `AddAgentMessage("")`, rendering a blank chat bubble.
**Fix:** Guard empty preview — show a system message "Swarm completed" instead.

### FIXED: Silent unmarshal failures for swarm SSE events
**Files:** `priv/go/tui/client/sse.go`
**Issue:** Malformed swarm JSON was silently dropped with no diagnostic (unlike all other event parsers which log to stderr).
**Fix:** Added `fmt.Fprintf(os.Stderr, "[sse] parse %s: %v\n", ...)` for all 3 swarm event cases.

### FIXED: extractResumeSessionID fragile guard
**Files:** `priv/go/tui/app/app.go`
**Issue:** `s == action` comparison was unclear and theoretically fragile. Intent was "prefix not found."
**Fix:** Replaced with explicit `strings.HasPrefix` check — clear intent, no edge cases.

### FIXED: Cancel race in synthesizing state
**Files:** `lib/optimal_system_agent/swarm/orchestrator.ex`
**Issue:** If cancel fires during `:running`, the async Task could still send `:swarm_complete` → `:synthesizing` → `:synthesis_complete`, double-decrementing `active_count`.
**Fix:** Added guard in `handle_cast(:swarm_complete, ...)` — ignores late arrivals if swarm is already in terminal state.

### FIXED: Phantom "prime-businessos" in category_for
**Files:** `lib/optimal_system_agent/commands.ex`
**Issue:** `"prime-businessos"` was listed in `category_for/1` but doesn't exist as a builtin command.
**Fix:** Removed from the priming category list.

### FIXED: Invalid swarm pattern silently ignored (E2E Bug 15)
**Files:** `lib/optimal_system_agent/channels/http/api.ex`
**Issue:** `parse_swarm_pattern/1` returned `nil` for invalid patterns. `maybe_put/3` skipped nil keys, so invalid patterns were silently dropped and the swarm launched with the default pattern instead of returning an error.
**Fix:** Replaced with `parse_swarm_pattern_opts/1` returning `{:ok, opts}` or `{:error, :invalid_pattern, msg}`. Invalid patterns now return `400 invalid_pattern` with a message listing valid patterns: `parallel, pipeline, debate, review`.

### FIXED: Health endpoint shows wrong model name (E2E Bug 19)
**Files:** `config/runtime.exs`, `lib/optimal_system_agent/channels/http.ex`
**Issue:** `runtime.exs` set `default_model` from `System.get_env("OLLAMA_MODEL")` regardless of active provider. When using Groq, the health endpoint showed `llama3.2:latest` (Ollama's default) instead of the actual Groq model.
**Fix:** `default_model` now resolves from provider-specific env vars (`GROQ_MODEL`, `ANTHROPIC_MODEL`, etc.) and only falls back to `OLLAMA_MODEL` when the active provider is actually Ollama. Health endpoint fallback uses `provider_info/1` to get the provider's built-in default model.

### FIXED: Dead 2-tuple backward compat in API
**Files:** `lib/optimal_system_agent/channels/http/api.ex`
**Issue:** `GET /commands` had a `{name, description}` pattern match clause that could never match — `list_commands/0` always returns 3-tuples now.
**Fix:** Removed dead clause.

### FIXED: Command kind routing broken
**Files:** `priv/go/tui/app/app.go`
**Issue:** `handleCommand()` only handled text output. Commands returning `kind: "prompt"` (custom commands), `kind: "action"` (:new_session, :exit, etc.), or `kind: "error"` were all treated as plain text.
**Fix:** Full kind-based dispatch with action handler.

### FIXED: Help text hardcoded to ~12 commands
**Files:** `priv/go/tui/app/app.go`
**Issue:** `/help` showed a static list of ~12 commands while the backend has 80+.
**Fix:** Dynamic help text built from backend command list, grouped by 16 categories with fallback to static help.

### FIXED: Swarm events never reached TUI
**Files:** `lib/optimal_system_agent/swarm/orchestrator.ex`, `priv/go/tui/client/sse.go`
**Issue:** Swarm events were emitted without `session_id`, so PubSub never routed them to the SSE stream. TUI also lacked parsers for swarm events.
**Fix:** Added `session_id` to all swarm event emissions. Added event types + parsers in sse.go. Added handlers in app.go.

---

## Testing Notes

- Go: `cd priv/go/tui && go build ./... && go vet ./...`
- Elixir: `mix test test/commands_test.exs test/channels/` (65 tests, 0 failures)
- Full suite: `mix test` (797 tests; 19 failures in MemoryTest/CompactorTest — pre-existing, unrelated)
- Manual: `bin/osa` → boot → /help → /agents → /status → submit question → verify SSE flow
- Swarm validation: `curl -X POST .../swarm/launch -d '{"task":"test","pattern":"invalid"}'` → expect 400
