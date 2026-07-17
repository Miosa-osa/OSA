# Error Model

## OTP "Let It Crash" Philosophy

OSA follows the OTP principle that processes should crash on unexpected errors
rather than defensively handling every possible failure. Supervisors detect
crashes and restart failed processes, restoring system invariants automatically.

This philosophy has three practical effects:

1. Error handling code is written for *expected* failures (network timeouts, bad
   input, budget exceeded). Unexpected failures are left to supervisors.
2. Supervision trees are designed so that a crashed child does not cascade into
   healthy siblings (`:one_for_one`) unless the crashed child provides
   infrastructure that others depend on (`:rest_for_one`).
3. State that must survive crashes is persisted explicitly (checkpoints,
   vault handoffs, SQLite) rather than recovered from in-memory backups.

## Error Categories

### Expected Failures — Handled in-process

| Failure | Handling |
|---------|----------|
| LLM API timeout or 5xx | Provider fallback chain; retry with next provider |
| Malformed LLM response | Logged; empty tool list returned; loop continues |
| Tool execution error | Error result returned to LLM for self-correction |
| Budget exceeded | `spend_guard` hook blocks tool execution before it starts |
| Dangerous shell command | `security_check` hook blocks and returns refusal |
| Invalid tool arguments | JSON Schema validation returns error to LLM |
| File not found | Tool returns `{:error, :enoent}` result |
| MCP server unavailable | Tool registration skipped; tools absent from session |
| Prompt injection attempt | `Guardrails.prompt_injection?/1` blocks before memory write |

### Unexpected Failures — Supervisor restart

| Failure | Supervisor | Restart strategy |
|---------|------------|------------------|
| `Agent.Loop` crash | `SessionSupervisor` (DynamicSupervisor) | `:transient` — restarts on crash, not normal exit |
| `Events.Bus` crash | `Supervisors.Infrastructure` | `:rest_for_one` — restarts Bus and all downstream |
| `Events.DLQ` crash | `Supervisors.Infrastructure` | `:rest_for_one` |
| Channel adapter crash | `Channels.Supervisor` | `:one_for_one` — isolated |
| Optional sidecar crash | `Supervisors.Extensions` | `:one_for_one` — isolated |
| `Telemetry.Metrics` crash | `Supervisors.Infrastructure` | `:rest_for_one` |

### Graceful Degradation — Fail silently

Some optional modules are designed to degrade without affecting core operation:

| Module | Degraded behavior |
|--------|-------------------|
| Python sidecar (embeddings) | Memory search falls back to keyword retrieval |
| Go tokenizer | Token counting falls back to word-count heuristic |
| Platform DB (`Platform.Repo`) | Disabled entirely when `DATABASE_URL` is not set |
| Intelligence subsystem _(planned — not implemented)_ | `ConversationTracker`, `ContactDetector` are not in `lib/`; when built they are intended to remain dormant until wired |
| MCP servers | Failed servers are skipped; their tools are absent |
| `Events.Stream` | Stream append failures are caught and logged; Bus dispatch continues |

## Hook-Based Error Gates

Two hooks block operations before they start rather than recovering after failure:

### spend_guard (priority 8, pre_tool_use)

Reads the current spend totals from `MiosaBudget` and blocks if any limit is
exceeded:

```elixir
case MiosaBudget.check_limits() do
  :ok -> {:ok, payload}
  {:exceeded, :daily, spent, limit} ->
    {:block, "Daily budget exceeded ($#{spent}/$#{limit})"}
  {:exceeded, :monthly, spent, limit} ->
    {:block, "Monthly budget exceeded ($#{spent}/$#{limit})"}
  {:exceeded, :per_call, spent, limit} ->
    {:block, "Per-call limit exceeded ($#{spent}/$#{limit})"}
end
```

### security_check (priority 10, pre_tool_use)

Blocks shell commands that match dangerous patterns:

```elixir
if is_dangerous_command?(args) do
  {:block, "Security check blocked: #{describe_risk(args)}"}
else
  {:ok, payload}
end
```

Dangerous patterns include: `rm -rf /`, fork bombs, reverse shells,
`/etc/passwd` writes, and other destructive commands.

## LLM Failure Recovery

The LLM client implements a provider fallback chain. On failure:

1. Log the failure at `:warning`
2. Mark the provider in `MiosaLLM.HealthChecker` (circuit breaker counter)
3. Consult `fallback_chain` from application config
4. Retry the same request with the next configured provider
5. If all providers fail, return an error result to the caller

```elixir
defp try_with_fallback(request, [provider | rest]) do
  case call_provider(provider, request) do
    {:ok, response} -> {:ok, response}
    {:error, reason} ->
      Logger.warning("[LLMClient] #{provider} failed: #{reason}, trying fallback")
      try_with_fallback(request, rest)
  end
end

defp try_with_fallback(_request, []) do
  {:error, "All providers in fallback chain failed"}
end
```

## Tool Failure as LLM Input

Tool failures do not abort the agent loop. Instead, the error is formatted as
a tool result message and appended to the conversation, allowing the LLM to
self-correct on the next iteration:

```elixir
case Tools.Registry.execute(name, args, state) do
  {:ok, result} ->
    %{role: "tool", tool_use_id: id, content: format_result(result)}
  {:error, reason} ->
    %{role: "tool", tool_use_id: id,
      content: "Error: #{reason}\n\nPlease review the arguments and try a different approach."}
end
```

This makes tool failures a signal to the LLM rather than a terminal condition.
The LLM receives the error text and can adjust its strategy, use a different
tool, or ask the user for clarification.

## Context Overflow Handling

When the conversation history approaches the model's context window limit,
`Agent.Compactor` applies tiered compaction:

| Threshold | Action |
|-----------|--------|
| 80% (`compaction_warn`) | Log warning |
| 85% (`compaction_aggressive`) | Summarize older turns via LLM |
| 95% (`compaction_emergency`) | Hard truncation of oldest messages |

Compaction preserves the system prompt, the most recent N turns, and any
pinned context blocks. The compacted summary is injected as a synthetic
system message.
