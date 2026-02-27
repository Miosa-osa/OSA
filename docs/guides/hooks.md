# Hook Pipeline Guide

> Middleware system for intercepting agent lifecycle events

## Overview

Hooks intercept key moments in the agent lifecycle. They can log, modify, or block actions. Hooks run in priority order — lower numbers run first.

## Events

| Event | When | Can Block? | Use Case |
|-------|------|-----------|----------|
| `pre_tool_use` | Before a tool executes | Yes | Security checks, budget validation |
| `post_tool_use` | After a tool executes | No | Learning capture, error recovery, telemetry |
| `pre_compact` | Before context compaction | No | Snapshot state, flush memory |
| `session_start` | New session begins | No | Inject context, load memory, greet |
| `session_end` | Session ends | No | Log, consolidate patterns, save state |
| `pre_response` | Before sending to user | No | Quality check, formatting |
| `post_response` | After response sent | No | Telemetry, learning, engagement tracking |

## Built-in Hooks (16+)

| Hook | Event | Priority | Description |
|------|-------|----------|-------------|
| `security_check` | pre_tool_use | 10 | Blocks dangerous shell commands (`rm -rf /`, `sudo`, etc.) |
| `budget_tracker` | pre_tool_use | 20 | Checks budget before LLM calls |
| `tool_gating` | pre_tool_use | 30 | Prevents tools for small/incapable models |
| `context_injection` | session_start | 10 | Loads memory, identity, soul into context |
| `learning_capture` | post_tool_use | 50 | Records outcomes for SICA learning engine |
| `error_recovery` | post_tool_use | 40 | Detects errors, suggests recovery via VIGIL |
| `telemetry` | post_tool_use | 60 | Tracks timing, token usage, success rates |
| `quality_check` | pre_response | 50 | Validates response quality before delivery |
| `memory_flush` | pre_compact | 10 | Saves important context before compaction |
| `pattern_consolidation` | session_end | 50 | Consolidates learned patterns |

## Hook Return Values

```elixir
{:ok, payload}     # Continue with (possibly modified) payload
{:block, reason}   # Block the action (pre_tool_use only)
:skip              # Skip this hook silently
```

## Writing a Custom Hook

### Register at Runtime

```elixir
alias OptimalSystemAgent.Agent.Hooks

# Simple logging hook
Hooks.register(:pre_tool_use, "my_logger", fn payload ->
  IO.puts("Tool called: #{payload.tool_name}")
  {:ok, payload}
end, priority: 45)

# Blocking hook (security)
Hooks.register(:pre_tool_use, "block_curl", fn payload ->
  if payload.tool_name == "shell_execute" and
     String.contains?(payload.arguments["command"] || "", "curl") do
    {:block, "curl commands are not allowed"}
  else
    {:ok, payload}
  end
end, priority: 15)

# Post-response analytics
Hooks.register(:post_response, "analytics", fn payload ->
  MyAnalytics.track(:response_sent, %{
    tokens: payload.token_count,
    duration: payload.duration_ms
  })
  {:ok, payload}
end)
```

### Hook Payload Structure

Each event passes a specific payload map:

**pre_tool_use / post_tool_use:**
```elixir
%{
  tool_name: "shell_execute",
  arguments: %{"command" => "ls -la"},
  session_id: "abc123",
  agent_role: :backend,
  tier: :specialist,
  # post_tool_use also includes:
  result: {:ok, "file1.ex\nfile2.ex"},
  duration_ms: 45
}
```

**session_start / session_end:**
```elixir
%{
  session_id: "abc123",
  channel: :cli,
  timestamp: ~U[2026-02-27 10:00:00Z],
  # session_end also includes:
  message_count: 42,
  tool_calls: 15,
  duration_minutes: 30
}
```

**pre_response / post_response:**
```elixir
%{
  content: "Here's the fix for the auth bug...",
  session_id: "abc123",
  token_count: 450,
  model: "claude-sonnet-4-6",
  provider: :anthropic
}
```

## Priority Guide

| Range | Purpose |
|-------|---------|
| 1-10 | Critical security (run first) |
| 11-30 | Budget and resource checks |
| 31-50 | Business logic hooks |
| 51-70 | Analytics and telemetry |
| 71-100 | Low-priority logging |

## Commands

```
/hooks             # List all registered hooks with priorities
```

## Async Hooks

For post-event hooks where results aren't needed:

```elixir
# Fire-and-forget (doesn't block the agent loop)
Hooks.run_async(:post_tool_use, payload)

# Synchronous (blocks until all hooks complete)
{:ok, modified_payload} = Hooks.run(:pre_tool_use, payload)
```

## Hook Metrics

The Hooks module tracks execution metrics per hook:
- Call count
- Average duration
- Block count (for pre_tool_use)
- Error count
