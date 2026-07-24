# Tools Overview

Tools are the action primitives that agents use to interact with the world. Every tool is a module implementing `MiosaTools.Behaviour`, registered in the Tools Registry, and callable by any LLM that receives the tool list.

---

## Architecture

```
LLM call → tool_calls: [{name: "file_read", arguments: {path: "..."}}]
               │
               ▼
Tools.Registry.execute/2  or  Tools.execute_direct/2
               │
               ▼
Tool module.execute/1  →  {:ok, result} | {:error, reason}
               │
               ▼
Tool result appended to message history → next LLM iteration
```

### Two execution paths

| Path | Function | Use case |
|------|---------|---------|
| Registry (GenServer) | `Tools.execute/2` | Main agent loop |
| Direct (lock-free) | `Tools.execute_direct/2` | Inside tools, sub-agents, delegates |

The direct path reads the tool registry from `:persistent_term` without routing through the GenServer process. This prevents deadlocks when a tool needs to call another tool (e.g., `codebase_explore` calling `file_read`).

---

## MiosaTools.Behaviour Contract

Every tool module implements this behaviour:

```elixir
@callback name() :: String.t()
@callback description() :: String.t()
@callback parameters() :: map()
@callback execute(map()) :: {:ok, String.t()} | {:error, String.t()}

# Optional callbacks
@callback safety() :: :read_only | :write_safe | :write_destructive | :terminal
@callback available?() :: boolean()
```

### Safety levels

| Level | Meaning | Example tools |
|-------|---------|--------------|
| `:read_only` | No writes | `file_read`, `file_grep`, `semantic_search` |
| `:write_safe` | Writes to controlled paths | `file_write`, `file_edit`, `code_sandbox` |
| `:write_destructive` | Potentially irreversible | `git` (reset --hard), `shell_execute` |
| `:terminal` | Full shell access | `shell_execute` |

The `available?/0` callback allows tools to declare themselves unavailable at runtime (e.g., `code_sandbox` when Docker is not installed).

---

## Tool Registry

`OptimalSystemAgent.Tools.Registry` maintains the live tool map. It uses Goldrush-compiled dispatch for fast tool lookup and execution.

### Registration

```elixir
# Register a tool module
Tools.Registry.register(MyTool)

# List all tools (via GenServer — use for display)
tools = Tools.Registry.list_tools()

# List tools (via persistent_term — use inside agents/tools)
tools = Tools.Registry.list_tools_direct()
```

When a new tool is registered, the Registry recompiles its dispatch table. Tool definitions are written to `:persistent_term` under `{Tools.Registry, :tools}` for lock-free reads.

### Tool definition format (sent to LLM)

```elixir
%{
  name: "file_read",
  description: "Read a file from the filesystem...",
  parameters: %{
    "type" => "object",
    "properties" => %{
      "path" => %{"type" => "string", "description" => "Path to the file to read"},
      "offset" => %{"type" => "integer"},
      "limit" => %{"type" => "integer"}
    },
    "required" => ["path"]
  }
}
```

---

## Tool Middleware and Pipeline

Tools run through a middleware pipeline that can wrap execution with cross-cutting concerns.

### Built-in middleware stages

| Stage | Purpose |
|-------|---------|
| **Schema validation** | Validate input against JSON schema before calling `execute/1` |
| **Central action authority** | For governed platform actions only, ask MIOSA's durable action authority whether the authenticated principal may act in the selected tenant/workspace; fail closed. Purely local tools are ungoverned and skip it (no network call). See `OptimalSystemAgent.ActionAuthority`. |
| **Safety gate** | Block tools inappropriate for the current permission tier |
| **Budget check** | Verify the operation fits within the session token/cost budget |
| **Telemetry** | Emit execution time, success/failure metrics |
| **Error recovery** | Normalize error formats, add contextual hints |

### Pipeline execution

```
Tool.execute/1
  → Middleware.schema_validate
  → Middleware.safety_check(permission_tier)
  → Middleware.budget_check(session)
  → ActionAuthority.authorize_tool  (governed platform actions only; fail closed)
  → Tool.execute/1  (actual work)
  → Middleware.telemetry_emit
  → {:ok | :error, result}
```

Middleware is configured per-tool and per-tier. Read-only tools skip the budget check for writes; terminal tools require explicit safety level confirmation.

---

## Skill Context Injection

`Tools.active_skills_context/1` scans the task description for skill trigger keywords and returns a formatted context block. This is injected into sub-agent system prompts so agents automatically access relevant skills.

```elixir
# Returns nil or a formatted ## Active Skills block
context = Tools.active_skills_context("debug the authentication flow")
```

Skills are `.md` files in `~/.claude/skills/` and `priv/skills/`. Each skill has trigger keywords. When the task description matches, the skill's instructions are injected into the agent prompt.

---

## Tool Discovery

Tools are discovered at compile time from the `OptimalSystemAgent.Tools.Builtins.*` namespace and at runtime via `Tools.Registry.register/1` for SDK-defined tools.

### Builtin tool list

| Category | Tools |
|----------|-------|
| File | `file_read`, `file_write`, `file_edit`, `file_glob`, `file_grep`, `multi_file_edit`, `dir_list` |
| Code | `code_symbols`, `codebase_explore`, `diff` |
| Execution | `shell_execute`, `code_sandbox`, `computer_use`, `notebook_edit` |
| Browser | `browser` |
| Intelligence | `semantic_search`, `session_search`, `mcts_index`, `memory_recall`, `memory_save`, `knowledge` |
| Integration | `web_fetch`, `web_search`, `github`, `git`, `ask_user` |
| Orchestration | `delegate`, `orchestrate`, `create_skill`, `skill_manager` |
| System | `budget_status`, `wallet_ops`, `task_write` |

---

## See Also

- [File Tools](./file-tools.md)
- [Execution Tools](./execution-tools.md)
- [Intelligence Tools](./intelligence-tools.md)
- [Integration Tools](./integration-tools.md)
- [Custom Tools](./custom-tools.md)
