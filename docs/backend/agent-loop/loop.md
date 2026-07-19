# Agent Loop

The core reasoning engine for OSA. Implements a bounded ReAct loop as an Elixir `GenServer`, one per session. Receives messages from channels or the event bus, drives tool execution, and returns final responses.

**Module:** `OptimalSystemAgent.Agent.Loop`
**Submodules:** `Loop.Checkpoint`, `Loop.Guardrails`, `Loop.LLMClient`, `Loop.ToolExecutor`, `Loop.GenreRouter`

---

## State

```elixir
%Loop{
  session_id:                 String.t(),
  user_id:                    String.t() | nil,
  channel:                    atom(),
  provider:                   atom(),
  model:                      String.t(),
  messages:                   [map()],
  iteration:                  non_neg_integer(),
  overflow_retries:           0..3,
  recent_failure_signatures:  [[String.t()]],
  auto_continues:             0..2,
  status:                     :idle | :thinking,
  tools:                      [map()],
  plan_mode:                  boolean(),
  plan_mode_enabled:          boolean(),
  turn_count:                 non_neg_integer(),
  last_meta:                  %{iteration_count: integer, tools_used: [String.t()]},
  explored_files:             MapSet.t(),
  exploration_done:           boolean(),
  permission_tier:            :full | :workspace | :read_only,
  strategy:                   module() | nil,
  strategy_state:             map()
}
```

**Configuration keys:**

| Key | Default | Meaning |
|-----|---------|---------|
| `:max_iterations` | `30` | Hard cap on tool-call loop iterations |
| `:auto_insights_interval` | `10` | Every N turns, extract insights from history |
| `:max_response_tokens` | `8192` | Max tokens in each LLM response |
| `:plan_mode_enabled` | `false` | Whether plan mode is active for the session |
| `:checkpoint_dir` | `~/.osa/checkpoints` | Crash recovery checkpoint location |

---

## Registration and Lifecycle

Each loop process registers via `Registry` under `OptimalSystemAgent.SessionRegistry` with the session ID as key and `user_id` as the value stored alongside the PID. The `child_spec` uses `:transient` restart so the process only restarts on abnormal termination — crash recovery uses the checkpoint.

On `init`, the loop attempts to restore a checkpoint for the session. If one exists (from a previous crash), messages, iteration count, plan mode, and turn count are restored. The reasoning strategy is also resolved at init time.

On normal or `:shutdown` termination, the checkpoint is deleted. On abnormal termination, the checkpoint is preserved for recovery.

---

## Message Processing Flow

`process_message/3` is a synchronous call with a 300-second timeout. The full sequence on each call:

```
1. Clear stale cancel flag in ETS
2. Apply per-call overrides (provider, model, working_dir)
3. Increment turn_count
4. Clear per-message process caches (git info, workspace overview, system message)
5. Prompt injection guard (Guardrails.prompt_injection?/1) — refuse and bail if detected
6. Noise filter (NoiseFilter.check/2) — filter low-signal messages before touching memory
7. Persist user message to JSONL session storage
8. Run Compactor.maybe_compact/1 on message history
9. Auto-extract insights from last 20 messages every 10 turns (async Task)
10. Inject memory nudge into user message if due
11. Inject explore-first directive if Guardrails.complex_coding_task?/1 is true
12. Run Explorer.maybe_explore/2 for pre-loop codebase exploration
13. Genre routing via GenreRouter.route_by_genre/3 — some genres respond directly
14. Plan mode check (should_plan?/1) — single LLM call with plan overlay if true
15. run_loop/1 — main reasoning loop
16. Persist assistant response to memory
17. Emit :context_pressure and :agent_response events
```

---

## run_loop / do_run_loop

`run_loop/1` checks two conditions before each iteration:

- **Cancel flag:** Reads the `:osa_cancel_flags` ETS table. If `{session_id, true}` is present, stops immediately. This is safe during a blocking `handle_call` because ETS reads are concurrent.
- **Max iterations:** If `state.iteration >= max_iterations()`, returns a limit-reached message.

`do_run_loop/1` executes one iteration:

1. Build (or retrieve from cache) context via `cached_context/1`.
2. Consult the active strategy for guidance via `strategy.next_step/2`. The strategy may inject a system message (`:think`, `:observe`, `:respond`) or signal completion (`:done`).
3. Call LLM via `LLMClient.llm_chat_stream/3`. Thinking options are applied for providers that support extended thinking.
4. Emit `:llm_request` and `:llm_response` events with timing and usage data.

**Response with no tool calls — final response path:**

The loop guards against several degenerate cases before returning:

| Condition | Guardrail | Max Fires |
|-----------|-----------|-----------|
| Model described intent ("let me check…") without calling tools | Auto-continue nudge | 2 |
| Model wrote code in markdown instead of calling `file_write`/`file_edit` | Coding nudge | 2 |
| Completed >2 iterations with task context but zero successful tools | Verification gate | 1 |

For non-Anthropic providers, `<think>` blocks are stripped from the final content via `Scratchpad.process_response/2` before returning.

**Response with tool calls:**

1. Increment `iteration`.
2. Strip `<think>` blocks from the assistant content.
3. Append the assistant message (including thinking blocks for Anthropic).
4. Execute all tool calls in parallel via `Task.async_stream/3` with `max_concurrency: 10` and a 60-second per-task timeout.
5. Append tool result messages in original call order.
6. Write a crash-recovery checkpoint via `Checkpoint.checkpoint_state/1`.
7. Feed results back to the active strategy via `strategy.handle_result/3`. If the strategy returns `{:switch_strategy, name}`, the loop switches strategies immediately.
8. Apply read-before-write nudge if writes occurred without prior reads (iteration 1 only).
9. Invalidate system message cache if `memory_save` ran successfully.
10. Apply skill creation nudge if 5+ tools were called in a single turn.
11. Doom loop detection: if the same tool signature fails 3+ consecutive times (or 6 total failures regardless of pattern), halt with an error message.
12. Recurse via `run_loop/1`.

**LLM error path:**

If the LLM call returns an error containing `"context_length"`, `"max_tokens"`, `"maximum context length"`, or `"token limit"`, the compactor runs and the loop retries. This overflow retry is capped at 3 attempts. After 3 failures, the loop returns a user-facing message to break the request into smaller parts.

---

## System Message Cache

Within a single `process_message` call, the system message (Tier 1 static base) is cached in the process dictionary under `:osa_system_msg_cache`. The cache key is `{plan_mode, session_id, memory_version, channel}`. The cache is invalidated when:

- A new `process_message` call starts (cache cleared explicitly).
- `memory_save` runs successfully (memory version bumped in the process dictionary).

On a cache hit, the full context is rebuilt with the fresh conversation history but the cached system message — avoiding repeated `persistent_term` reads and string assembly.

---

## Plan Mode

Plan mode is enabled when `state.plan_mode_enabled == true` and `skip_plan: false` (the default). When active:

- A single LLM call is made with an empty tools list and `temperature: 0.3`.
- The context includes the plan mode overlay block (see `context.md`).
- The response is returned as `{:plan, plan_text}` rather than `{:ok, response}`.
- The CLI uses this return tag to display the plan and prompt the user for approval before re-calling with `skip_plan: true`.

If the plan mode LLM call fails, the loop falls through to normal execution.

Plan mode is toggled via the `:toggle_plan_mode` call or the `/plan` CLI command.

---

## Checkpoint / Resume

`Checkpoint.checkpoint_state/1` writes a JSON file to `~/.osa/checkpoints/<session_id>.json` after every successful tool-result cycle. The checkpoint contains:

- `messages` — full conversation history at that point
- `iteration` — current iteration count
- `plan_mode` — plan mode state
- `turn_count` — lifetime turn counter
- `checkpointed_at` — ISO8601 timestamp

On `init`, `Checkpoint.restore_checkpoint/1` reads this file if it exists. A successfully restored loop logs the restored iteration count and message count. On clean shutdown, `Checkpoint.clear_checkpoint/1` deletes the file.

---

## Cancellation

`Loop.cancel/1` writes `{session_id, true}` to the `:osa_cancel_flags` ETS table. The `run_loop` function reads this table at the top of every iteration. Because ETS reads are concurrent (the table uses `:public` access), this works correctly even though the `GenServer` mailbox is blocked during `handle_call`.

---

## Permission Tiers

Each loop has a `permission_tier` that controls which tools are executable:

| Tier | Allowed |
|------|---------|
| `:full` | All tools |
| `:workspace` | File and workspace tools; no shell or network |
| `:read_only` | Read-only file tools only |

`ToolExecutor.permission_tier_allows?/2` is called per tool before execution.

---

## Events Emitted

| Event | When |
|-------|------|
| `:llm_request` | Before each LLM call |
| `:llm_response` | After each LLM call (includes `duration_ms`, `usage`) |
| `:agent_response` | When a final response is produced |
| `:system_event / :context_pressure` | End of each `process_message` call |
| `:system_event / :agent_cancelled` | When the cancel flag is detected |
| `:system_event / :doom_loop_detected` | When the doom loop guard fires |
| `:strategy_changed` | When the active strategy switches |

---

## Output-Shorten-to-File (Tool Result Persistence)

**Module:** `OptimalSystemAgent.Agent.Loop.ToolResultStorage`

Applied at the tool boundary before a result is appended to the message
history. A result is offloaded to disk when it exceeds EITHER limit:

| Config Key | Default | Trigger |
|---|---|---|
| `max_tool_output_bytes` | `51_200` (50KB) | Byte-size cap |
| `max_tool_output_lines` | `2_000` | Line-count cap — catches a huge number of short lines (e.g. `grep -r` across a big tree) even under the byte cap |

An offloaded result is persisted to `~/.osa/tool-results/<id>.txt` and the
inline content is replaced with a head+tail preview
(`tool_output_preview_head_lines`, default `40`; `tool_output_preview_tail_lines`,
default `20`) plus a reference to the full file — so the model sees both
"what this command started doing" and "how it ended" without paying context
budget for the middle. Result files older than 7 days are swept as orphans.
The verbose setting (`Settings.get("verbose", false)`) bypasses the budget
entirely and returns the full result unshortened.

See [Configuration → Agent Behavior → Tool output](../../getting-started/configuration.md#agent-behavior-wave-2b2c)
for the full key list, and [goal-orchestration.md](goal-orchestration.md) for
the other Wave 2b/2c loop-discipline additions this cycle.

---

## Public API

```elixir
Loop.process_message(session_id, message, opts \\ [])
# Returns {:ok, response} | {:plan, plan_text}
# Opts: skip_plan, signal_weight, signal_genre, provider, model, working_dir

Loop.cancel(session_id)
# Returns :ok | {:error, :not_running}

Loop.get_metadata(session_id)
# Returns %{iteration_count: integer, tools_used: [String.t()]}

Loop.get_owner(session_id)
# Returns user_id | nil

Loop.ask_user_question(session_id, survey_id, questions, opts \\ [])
# Returns {:ok, answers} | {:skipped} | {:error, :timeout | :cancelled}
```

See also: [context.md](context.md), [strategies.md](strategies.md), [compactor.md](compactor.md), [scratchpad.md](scratchpad.md)
