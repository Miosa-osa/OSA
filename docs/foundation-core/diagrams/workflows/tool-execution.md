# Tool Execution Workflow

Detailed flow for a single tool call from `Agent.Loop` through the permission
check, hook pipeline, tool dispatch, and result formatting.

Source: `lib/optimal_system_agent/agent/loop/tool_executor.ex` and
`lib/optimal_system_agent/tools/registry.ex`.

---

## Mermaid Sequence Diagram

```mermaid
sequenceDiagram
    participant Loop as Agent.Loop
    participant Bus as Events.Bus
    participant ToolEx as Loop.ToolExecutor
    participant Hooks as Agent.Hooks
    participant Perm as Permission<br/>Tier Check
    participant ToolsReg as Tools.Registry
    participant Tool as Tool Module<br/>(builtin / MCP / custom)
    participant DLQ as Events.DLQ

    Loop->>Bus: emit(:tool_call, {name, args_hint, phase: :start})
    Loop->>ToolEx: execute_tool_call(tool_call, state)

    ToolEx->>Perm: permission_tier_allows?(state.permission_tier, tool_name)
    Note over Perm: :full → all tools allowed<br/>:workspace → read_only + write tools<br/>:read_only → file_read, grep, memory_recall, etc. only

    alt permission denied
        Perm-->>ToolEx: false
        ToolEx-->>Loop: "Blocked: :workspace mode — shell_execute not permitted"
    else permission granted
        Perm-->>ToolEx: true

        ToolEx->>Hooks: run(:pre_tool_use, {tool_name, args, session_id})
        Note over Hooks: runs in priority order (10 → 95)<br/>security_check, spend_guard, read_before_write_nudge, etc.

        alt hook returns {:blocked, reason}
            Hooks-->>ToolEx: {:blocked, reason}
            ToolEx-->>Loop: "Blocked: #{reason}"
        else hook returns {:error, :hooks_unavailable}
            Note over ToolEx: Hooks GenServer is down<br/>FAIL CLOSED — never execute without security check
            ToolEx-->>Loop: "Blocked: security pipeline unavailable"
        else hook returns :ok or {:ok, _}
            Hooks-->>ToolEx: :ok

            Note over ToolEx: inject __session_id__ into args<br/>for tools that need session context (ask_user, etc.)

            ToolEx->>ToolsReg: execute(tool_name, enriched_args)

            ToolsReg->>ToolsReg: lookup tool module (ETS / goldrush dispatch)

            alt tool not found
                ToolsReg-->>ToolEx: {:error, :not_found}
                ToolEx->>ToolsReg: suggest_fallback_tool(tool_name)
                alt fallback found
                    ToolsReg-->>ToolEx: {:ok, alt_tool_name}
                    ToolEx->>ToolsReg: execute(alt_tool_name, enriched_args)
                    ToolsReg->>Tool: execute(args)
                    Tool-->>ToolsReg: {:ok, result} | {:error, reason}
                    ToolsReg-->>ToolEx: result
                else no fallback
                    ToolEx-->>Loop: "Tool 'name' not found"
                end
            else tool found
                Note over ToolsReg: schema validation, then central action authority<br/>ActionAuthority.authorize_tool — governed platform actions only<br/>fail closed; local/ungoverned tools pass through with no network call

                alt central authority blocks (governed action, not allowed)
                    ToolsReg-->>ToolEx: {:error, "Blocked: #{message}"}
                    ToolEx-->>Loop: "Error executing tool: Blocked: #{message}"
                else allowed or not governed
                    ToolsReg->>Tool: execute(enriched_args)
                end

                alt tool returns {:ok, {:image, %{media_type, data, path}}}
                    Tool-->>ToolsReg: {:ok, {:image, ...}}
                    ToolsReg-->>ToolEx: {:image, media_type, base64_data, path}
                    ToolEx-->>Loop: image result (formatted for LLM vision)
                else tool returns {:ok, content}
                    Tool-->>ToolsReg: {:ok, content}
                    ToolsReg-->>ToolEx: content_string

                    Note over ToolEx: truncate if > max_tool_output_bytes (default 10 KB)

                    ToolEx-->>Loop: content_string (possibly truncated)
                else tool returns {:error, reason}
                    Tool-->>ToolsReg: {:error, reason}
                    ToolsReg-->>ToolEx: {:error, reason}
                    ToolEx-->>Loop: "Error executing tool: #{reason}"
                end
            end

            ToolEx->>Hooks: run(:post_tool_use, {tool_name, result, session_id})
            Note over Hooks: auto_format, learning_capture, telemetry, episodic_memory, metrics_dashboard

            ToolEx->>Bus: emit(:tool_result, {name, result_summary, duration_ms})
        end
    end
```

---

## Permission Tiers

Tools are filtered by the session's `permission_tier` before the hook pipeline runs.

| Tier | Allowed Tools |
|---|---|
| `:full` | All tools — no restriction |
| `:workspace` | Read-only tools + local write tools (file_write, file_edit, git, task_write, memory_write) |
| `:read_only` | file_read, file_glob, dir_list, file_grep, memory_recall, session_search, semantic_search, code_symbols, web_fetch, web_search |

The permission tier is set per session in `Agent.Loop` state. It defaults to `:full`
for CLI sessions. SDK callers can set a more restrictive tier when spawning sessions
for untrusted tasks.

Attempting to call a tool outside the permission tier returns a blocked message to
the LLM without calling any hook or the tool itself.

---

## Hook Pipeline

The pre_tool_use hook pipeline runs synchronously and can block tool execution.

| Hook | Priority | Effect |
|---|---|---|
| `security_check` | 10 (first) | Blocks dangerous shell patterns, validates tool args |
| `spend_guard` | 20 | Blocks execution if budget is exhausted |
| `read_before_write_nudge` | 30 | Warns if file_write called on unread file |
| `context_optimizer` | 50 | Trims oversized tool arguments |
| ... | ... | ... |

Hooks return `{:ok, payload}`, `{:blocked, reason}`, or `:skip`. The first `{:blocked, reason}`
short-circuits the rest of the pipeline and prevents execution. If `Hooks` GenServer is
unreachable, the executor fails closed (blocks all tool execution).

The post_tool_use pipeline runs after the tool completes and receives the result.
Post-use hooks cannot block — they run asynchronously in supervised Tasks.

---

## Output Truncation

Tool output is capped at `max_tool_output_bytes` (default: 10,240 bytes = 10 KB).
If the raw tool result exceeds this limit, it is truncated with a suffix:
`\n[Output truncated — #{byte_size} bytes total]`.

This prevents a single verbose tool call (e.g., `cat` of a large file) from filling
the LLM context window and degrading subsequent reasoning quality.

---

## Tool Result Types

| Return type | Handling |
|---|---|
| `{:ok, string}` | Passed directly to the LLM as a tool result message |
| `{:ok, {:image, %{media_type, data, path}}}` | Formatted as a vision-capable message (Claude multi-modal) |
| `{:error, reason}` | Formatted as `"Error executing tool: #{reason}"` — passed to LLM |
| Raised exception | Caught in `Tools.Registry.execute/2`, returned as `{:error, message}` |

---

## Parallel Tool Execution

When the LLM returns multiple tool calls in a single response, `Agent.Loop`
executes them in parallel using `Task.async_stream` with `max_concurrency: 5`.
Each parallel call goes through the full permission check → hook → execute
pipeline independently. Results are collected in order and appended to the
message list as individual tool result messages before the next LLM call.
