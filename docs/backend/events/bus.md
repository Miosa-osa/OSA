# Events: Bus

The event bus is the central nervous system of OSA. It routes typed events between the agent loop, tools, channels, orchestration, memory, and external integrations using Goldrush-compiled BEAM bytecode for zero-overhead dispatch.

---

## Architecture

```
Bus.emit(:event_type, payload)
  -> Event.new/4          builds typed Event struct (UUID, timestamp, Signal Theory dims)
  -> Classifier.auto_classify   fills signal_mode/genre/type if not explicit
  -> :gre.make/2          wraps as goldrush event proplist
  -> TaskSupervisor child  dispatches to :osa_event_router (never blocks caller)
     -> :glc.handle/2     compiled filter matches by type
        -> dispatch_event/1   ETS lookup -> handler calls
           -> TaskSupervisor child per handler  (isolated: crash = DLQ)
  -> Stream.append/2      appends to per-session stream if session_id present
```

The caller of `Bus.emit/3` is never blocked. Dispatch runs in a supervised Task.

---

## Goldrush Compilation

The router module `:osa_event_router` is compiled once at `Bus.init/1` using `glc:compile/2`. This compiles event type predicates into real BEAM bytecode — routing at BEAM instruction speed with no hash lookups or runtime pattern matching.

The compiled module handles type-filtering only. Handler dispatch remains dynamic via ETS lookup in `dispatch_event/1`. The router is **never recompiled after init** to prevent a TOCTOU race with `gr_param`'s ETS table while in-flight tasks hold references to old bytecode.

---

## Event Types

All valid event types are declared in `@event_types`:

| Atom | Direction / Purpose |
|------|---------------------|
| `:user_message` | Channel -> Agent.Loop — inbound user input |
| `:llm_request` | Agent.Loop -> Providers — LLM call being made |
| `:llm_response` | Providers -> Agent.Loop — LLM response received |
| `:tool_call` | Agent.Loop -> Tools — tool execution start/end |
| `:tool_result` | Tools -> Agent.Loop — tool output |
| `:tool_render` | Agent.Loop -> UI — structured tool render payload |
| `:agent_response` | Agent.Loop -> Channels/Bridge — final response |
| `:system_event` | Scheduler/internals -> Loop/Memory — control events |
| `:channel_connected` | Manager — channel came online |
| `:channel_disconnected` | Manager — channel went offline |
| `:channel_error` | Manager — channel start failed |
| `:ask_user_question` | Agent tool — prompts user for input |
| `:survey_answered` | Agent tool — user answered a survey |
| `:algedonic_alert` | System health — urgent bypass signal (Beer VSM) |
| `:signal_classified` | Signal classifier — event enriched with Signal Theory dimensions |
| `:doom_loop_halt` | Agent.Loop — repetition/stall detected, loop halted |
| `:auto_mode_blocked` | Safety Guardian — an auto-mode action was blocked |
| `:auto_mode_paused` | Safety Guardian — auto mode paused after repeated blocks |

Attempting to emit an unknown type raises an `ArgumentError` at the `when event_type in @event_types` guard.

---

## Public API

### `Bus.emit/3`

```elixir
Bus.emit(event_type, payload \\ %{}, opts \\ []) :: {:ok, Event.t()}
```

Emits an event. Wraps `payload` in a full `Event` struct (UUID, ISO timestamp, Signal Theory dimensions). Returns `{:ok, event}` with the created Event.

**Options:**

| Key | Default | Description |
|-----|---------|-------------|
| `:source` | `"bus"` | Origin string |
| `:parent_id` | nil | Parent event ID for causality chains |
| `:session_id` | nil | Session identifier (enables stream append) |
| `:correlation_id` | nil | Groups related events |
| `:signal_mode` | auto | Signal Theory mode (skips auto-classify if set) |
| `:signal_genre` | auto | Signal Theory genre |
| `:signal_sn` | auto | Signal-to-noise ratio 0.0–1.0 |

### `Bus.emit_algedonic/3`

```elixir
Bus.emit_algedonic(severity, message, opts \\ []) :: {:ok, Event.t()}
```

Emits an `:algedonic_alert` event — an urgent bypass signal in Beer's VSM model. Severity must be `:critical`, `:high`, `:medium`, or `:low`.

### `Bus.register_handler/2`

```elixir
Bus.register_handler(event_type, handler_fn) :: reference()
```

Registers a `(payload -> any())` handler for `event_type`. Returns a `ref` for later unregistration. Handlers are stored in ETS table `:osa_event_handlers` as `{event_type, ref, fn}`.

### `Bus.unregister_handler/2`

```elixir
Bus.unregister_handler(event_type, ref) :: :ok
```

Removes a previously registered handler.

---

## Dead Letter Queue (`Events.DLQ`)

When a handler crashes or throws, the event is enqueued in the DLQ for automatic retry.

**Retry policy:**
- Max retries: 3.
- Base backoff: 1 000 ms, doubling each retry (capped at 30 000 ms).
- Retry tick: every 60 seconds.

On exhaustion (3 failures), the event is dropped and a `:high` severity algedonic alert is emitted.

**Nonce-stable storage:** Anonymous handler functions are converted to MFA tuples where possible. If conversion fails (complex closures), the function reference is stored as-is.

**API:**

| Function | Description |
|----------|-------------|
| `DLQ.depth/0` | Current queue depth |
| `DLQ.entries/0` | List all queued entries |
| `DLQ.drain/0` | Force-retry all entries now; returns `{successes, failures}` |

---

## Failure Modes (`Events.FailureModes`)

`FailureModes` is a delegation shim that forwards to `MiosaSignal.FailureModes`. It provides Signal Theory failure mode detection for events.

| Function | Description |
|----------|-------------|
| `detect/1` | Detect which failure mode an event exhibits |
| `check/2` | Check a specific failure mode against an event |

Failure modes correspond to the 11 failure types in Signal Theory (routing failure, bandwidth overload, genre mismatch, etc.).

---

## Event Stream (`Events.Stream`)

Per-session circular buffer with pub/sub for live subscribers.

Each session gets its own `Stream` GenServer registered in `OptimalSystemAgent.EventStreamRegistry`. The Bus calls `Stream.append/2` automatically for any event that has a `session_id`.

**Buffer:** Fixed capacity of 1 000 events (FIFO drop of oldest on overflow).

**API:**

| Function | Description |
|----------|-------------|
| `Stream.append/2` | Append event; notifies all subscribers |
| `Stream.subscribe/2` | Subscribe pid to `{:event, event}` messages |
| `Stream.unsubscribe/2` | Remove subscription (also auto-removed on process exit via monitor) |
| `Stream.events/2` | Query with optional `type:`, `since:`, `limit:` filters |
| `Stream.replay/3` | Get all events in a `[from, to]` DateTime range |
| `Stream.count/1` | Return event count |
| `Stream.stop/1` | Terminate the stream GenServer |

---

## Event Struct

`OptimalSystemAgent.Events.Event` is a backward-compatibility shim over `MiosaSignal.Event`. The struct fields are:

| Field | CloudEvents | Description |
|-------|-------------|-------------|
| `id` | Required | UUID v4 |
| `type` | Required | Event type atom |
| `source` | Required | Origin string |
| `time` | Optional | DateTime UTC |
| `subject` | Optional | Subject of the event |
| `data` | Optional | Payload map |
| `dataschema` | Optional | Schema URI |
| `specversion` | — | Always `"1.0.2"` |
| `datacontenttype` | — | Always `"application/json"` |
| `parent_id` | Extension | Causality chain |
| `session_id` | Extension | Session context |
| `correlation_id` | Extension | Event grouping |
| `signal_mode` | Extension | Signal Theory M dimension |
| `signal_genre` | Extension | Signal Theory G dimension |
| `signal_type` | Extension | Signal Theory T dimension |
| `signal_format` | Extension | Signal Theory F dimension |
| `signal_structure` | Extension | Signal Theory W dimension |
| `signal_sn` | Extension | Signal-to-noise ratio 0.0–1.0 |

`Event.to_cloud_event/1` converts to a CloudEvents 1.0 envelope.

---

## Signal Classifier (`Events.Classifier`)

`Events.Classifier` is a delegation shim over `MiosaSignal.Classifier`. It auto-populates the Signal Theory dimensions on every event emitted through the Bus (when not explicitly set).

| Function | Description |
|----------|-------------|
| `auto_classify/1` | Fill all signal dimensions from event content |
| `classify/1` | Full classification |
| `sn_ratio/1` | Compute signal-to-noise ratio |
| `infer_mode/1` | Infer linguistic/visual/code mode |
| `infer_genre/1` | Infer genre (directive, report, query, …) |
| `infer_type/1` | Infer speech act type |
| `infer_format/1` | Infer format (text, json, markdown, …) |
| `dimension_score/1` | Score all dimensions |

---

## See Also

- [protocol.md](protocol.md) — OSCP and CloudEvents encoding
- [telemetry.md](telemetry.md) — Metrics and instrumentation
