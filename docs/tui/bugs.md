# TUI Known Issues & Bug Tracker

> Tracked issues for the Go TUI (`bin/osa`).
> Last updated: 2026-02-28

---

## Open

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

> Full audit of Backend → SSE → TUI data pipeline. Backend emits 63+ system_event types.
> After fixes: ~33 events fully wired end-to-end. Remaining gaps are low-priority subsystems.

### Remaining unparsed events (low priority)
- Pact workflows (9 events) — no TUI parser, no `session_id`
- Treasury (8 events) — no TUI parser, no `session_id`
- Learning (4 events) — no TUI parser, no `session_id`
- Scheduler heartbeats (2 events) — no TUI parser

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
swarm_cancelled                  ✓ session_id  ✓ parsed     ✓ handled     ✓ system warning
swarm_timeout                    ✓ session_id  ✓ parsed     ✓ handled     ✓ error message
orchestrator_task_started        ✓ session_id  ✓ parsed     ✓ handled     ✓ agents panel
orchestrator_wave_started        ✓ session_id  ✓ parsed     ✓ handled     ✓ wave counter
orchestrator_agent_started       ✓ session_id  ✓ parsed     ✓ handled     ✓ agent added
orchestrator_agent_progress      ✓ session_id  ✓ parsed     ✓ handled     ✓ progress update
orchestrator_agent_completed     ✓ session_id  ✓ parsed     ✓ handled     ✓ agent done
orchestrator_agent_failed        ✓ session_id  ✓ parsed     ✓ handled     ✓ agent failed
orchestrator_task_completed      ✓ session_id  ✓ parsed     ✓ handled     ✓ panel stop
task_created                     ✓ session_id  ✓ parsed     ✓ handled     ✓ task checklist
task_updated                     ✓ session_id  ✓ parsed     ✓ handled     ✓ status update
budget_warning                   ✓ session_id  ✓ parsed     ✓ handled     ✓ system warning
budget_exceeded                  ✓ session_id  ✓ parsed     ✓ handled     ✓ error message
hook_blocked                     ✓ session_id  ✓ parsed     ✓ handled     ✓ error message
thinking_delta                   ✓ session_id  ✓ parsed     ✓ handled     ✓ activity panel
streaming_token                  ✓ session_id  ✓ parsed     ✓ handled     ✓ live response
swarm_intelligence_started       ✓ session_id  ✓ parsed     ✓ handled     ✓ system message
swarm_intelligence_round         ✓ session_id  ✓ parsed     ✓ handled     ✓ system message
swarm_intelligence_converged     ✓ session_id  ✓ parsed     ✓ handled     ✓ system message
swarm_intelligence_completed     ✓ session_id  ✓ parsed     ✓ handled     ✓ system message
learning_consolidation           ✗ NO SID      ✗ not parsed ✗             ✗ (LOW)
pact_*                           ✗ NO SID      ✗ not parsed ✗             ✗ (LOW)
treasury_*                       ✗ NO SID      ✗ not parsed ✗             ✗ (LOW)
```

---

## Recently Fixed (2026-02-28)

### FIXED: iteration_count and tools_used always 0/empty in HTTP response
**Files:** `lib/optimal_system_agent/agent/loop.ex`, `lib/optimal_system_agent/channels/http/api.ex`
**Issue:** POST /orchestrate hardcoded `tools_used: []` and `iteration_count: 0`. Loop returned `{:ok, response}` with no metadata.
**Fix:** Added `last_meta` to Loop state, populated with `iteration_count` and `tools_used` after each run. Added `Loop.get_metadata/1` public API. API endpoint now calls `get_metadata` after `process_message` to populate the response.

### FIXED: Thinking/reasoning blocks silently dropped (BUG-014 partial)
**Files:** `lib/optimal_system_agent/agent/loop.ex`, `priv/go/tui/client/sse.go`, `priv/go/tui/app/app.go`, `priv/go/tui/model/activity.go`, `priv/go/tui/msg/msg.go`
**Issue:** Anthropic provider emits `{:thinking_delta, text}` callbacks during extended thinking. Loop's streaming callback ignored all events except `{:text_delta, _}` and `{:done, _}`. Thinking was completely invisible.
**Fix:** Added `{:thinking_delta, text}` handler in loop.ex that emits `thinking_delta` SSE event. Added `ThinkingDeltaEvent` type + parser in sse.go. Added handler in app.go that forwards to activity model. Activity model now tracks `isThinking` state and shows live "thinking Xs" in the header during active thinking.

### FIXED: Swarm intelligence events invisible (BUG-014)
**Files:** `lib/optimal_system_agent/swarm/intelligence.ex`, `priv/go/tui/client/sse.go`, `priv/go/tui/app/app.go`
**Issue:** All 6 swarm intelligence Bus.emit calls lacked `session_id`. No TUI parsers or handlers existed. During a debate/exploration swarm, the user saw nothing between "Swarm launched" and "Swarm completed".
**Fix:** Added `session_id` to all 6 Bus.emit calls (threaded through opts → `explore/2`, `specialize/2`, `run_rounds/7`). Added 4 event types (Started, Round, Converged, Completed) + parsers in sse.go. Added handlers in app.go that display progress as system messages.

### FIXED: Orchestrator events never reached TUI (BUG-013)
**Files:** `lib/optimal_system_agent/agent/orchestrator.ex`
**Issue:** All 12 orchestrator Bus.emit calls lacked `session_id`. Events vanished into the global firehose — multi-agent progress panel was always empty.
**Fix:** Added `session_id` to all 10 orchestrator event emissions (1 left intentionally system-level). Sources: `session_id` param in handle_call, `task_state.session_id` in handle_cast/handle_continue.

### FIXED: task_created/task_updated never emitted (BUG-012)
**Files:** `lib/optimal_system_agent/agent/orchestrator.ex`, `lib/optimal_system_agent/agent/task_tracker.ex`
**Issue:** TUI parsed `task_created`/`task_updated` events but backend emitted `task_enqueued`/`task_completed` — different names. Task checklist panel was dead UI.
**Fix:** Added `task_created` emissions after task enqueue (orchestrator subtasks + task_tracker add_task/add_tasks). Added `task_updated` emissions on status transitions (start/complete/fail) in both orchestrator and task_tracker. All include `session_id`.

### FIXED: Budget warnings invisible (BUG-015)
**Files:** `lib/optimal_system_agent/agent/budget.ex`, `priv/go/tui/client/sse.go`, `priv/go/tui/app/app.go`
**Issue:** `budget_warning` and `budget_exceeded` events lacked `session_id` and had no TUI parser.
**Fix:** Added `session_id`, `utilization`, `message` fields to 4 budget Bus.emit calls. Added `BudgetWarningEvent`/`BudgetExceededEvent` types + parsers in sse.go. Added handlers in app.go (system warning/error).

### FIXED: Security hook blocks invisible (BUG-016)
**Files:** `lib/optimal_system_agent/agent/hooks.ex`, `priv/go/tui/client/sse.go`, `priv/go/tui/app/app.go`
**Issue:** `hook_blocked` events lacked `session_id` and had no TUI parser. Blocked actions were invisible.
**Fix:** Added `session_id: Map.get(payload, :session_id, "unknown")` to hook_blocked emission. Added `HookBlockedEvent` type + parser + handler in TUI.

### FIXED: swarm_cancelled/swarm_timeout not parsed (BUG-001)
**Files:** `priv/go/tui/client/sse.go`, `priv/go/tui/app/app.go`
**Issue:** Backend emitted these events but TUI had no parsers or handlers.
**Fix:** Added `SwarmCancelledEvent`/`SwarmTimeoutEvent` types + parsers. Handlers terminate StateProcessing and show warning/error.

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

### FIXED: Session race condition — second source (E2E Bug 20, round 2)
**Files:** `lib/optimal_system_agent/tools/registry.ex`, `lib/optimal_system_agent/agent/context.ex`, `lib/optimal_system_agent/channels/session.ex`, `lib/optimal_system_agent/channels/http/api.ex`
**Issue:** After fixing `list_tools()` in Loop.init (round 1), session creation still failed ~25% under concurrent load. Root cause: `Context.build()` called `Tools.list_docs()` and `Tools.list_tools()` via GenServer.call on EVERY LLM iteration. Under concurrent load, 10 Loop processes all serialized on Tools.Registry, causing 5s timeouts that crashed the Loop GenServer.
**Fix:** Added `list_docs_direct()` using `:persistent_term` (lock-free). Switched `context.ex:tools_block()` to use `list_docs_direct()` and `list_tools_direct()`. Hardened `ensure_loop` with retry logic and `{:already_started, _}` handling. Orchestrate handler now returns 503 on session start failure instead of crashing.

### FIXED: /analytics crashes with Jason.Encoder error (E2E Bug 25)
**Files:** `lib/optimal_system_agent/channels/http/api.ex`
**Issue:** `GET /analytics` crashed with `Protocol.UndefinedError: protocol Jason.Encoder not implemented for Tuple`. `Budget.get_status()` returns `{:ok, map}` tuple but the handler passed it directly to `Jason.encode!`.
**Fix:** Added `unwrap_ok/1` helper that extracts data from `{:ok, data}` tuples, raw maps, or returns `%{}` as fallback. Applied to all 4 analytics GenServer calls.

### FIXED: GET /sessions crashes with NaiveDateTime.compare on nil (E2E Bug 24/22)
**Files:** `lib/optimal_system_agent/channels/http/api.ex`
**Issue:** `GET /sessions` sorted results with `Enum.sort_by(& &1.last_active, {:desc, NaiveDateTime})`. The `last_active` values from Memory are ISO8601 strings or nil — not NaiveDateTime structs. Crashed when any session had nil timestamps.
**Fix:** Changed to nil-safe string sort: `Enum.sort_by(fn s -> s.last_active || "" end, :desc)`. ISO8601 strings sort lexicographically in correct chronological order.

### FIXED: 40% session creation failure rate (E2E Bug 20)
**Files:** `lib/optimal_system_agent/agent/loop.ex`
**Issue:** `Loop.init/1` called `Tools.list_tools()` which is a `GenServer.call` to Tools.Registry. Under concurrent session creation, this serialized call becomes a bottleneck — if Tools.Registry is busy processing other requests, new sessions timeout waiting for the tool list.
**Fix:** Switched to `Tools.list_tools_direct()` which reads from `:persistent_term` — lock-free, zero contention, safe from inside GenServer callbacks.

### FIXED: Missing /analytics endpoint (E2E Bug 8)
**Files:** `lib/optimal_system_agent/channels/http/api.ex`
**Issue:** `GET /api/v1/analytics` returned 404. No route existed for analytics data.
**Fix:** Added `GET /analytics` endpoint that aggregates data from Budget, Learning, Hooks, Compactor, and active session count from SessionRegistry.

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

### FIXED: SSE stream crashes on every message — "Connection lost" (BUG-026)
**Severity:** Critical
**Files:** `lib/optimal_system_agent/agent/loop.ex`, `lib/optimal_system_agent/channels/http/api.ex`
**Root cause:** `agent_response` bus events included `signal: %Classifier{}` struct. The SSE loop's `Jason.encode!(event)` cannot encode Elixir structs without a `Jason.Encoder` implementation — it raises `Jason.EncodeError`, crashing the SSE Plug process and dropping the TCP connection. The Go TUI then detects the disconnect and enters reconnection mode, showing "Connection lost. Reconnecting (attempt N/10)..." on every single message.
**Fix:** (1) Converted `signal` from struct to plain map via `Map.from_struct(signal)` in all three `Bus.emit(:agent_response, ...)` and `Bus.emit(:system_event, %{signal: ...})` calls in loop.ex. (2) Switched `sse_loop` from `Jason.encode!` (crash on failure) to `Jason.encode` (returns `{:ok, data}` / `{:error, reason}`) so non-serializable events are logged and skipped instead of killing the SSE stream.

---

## Testing Notes

- Go: `cd priv/go/tui && go build ./... && go vet ./...`
- Elixir: `mix test test/commands_test.exs test/channels/` (65 tests, 0 failures)
- Full suite: `mix test` (797 tests; 19 failures in MemoryTest/CompactorTest — pre-existing, unrelated)
- Manual: `bin/osa` → boot → /help → /agents → /status → submit question → verify SSE flow
- Swarm validation: `curl -X POST .../swarm/launch -d '{"task":"test","pattern":"invalid"}'` → expect 400
