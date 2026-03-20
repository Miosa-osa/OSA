# OSA Developer Guide

Quick-reference for adding new agents, tools, providers, channels, screens, and skills to the OptimalSystemAgent codebase.

## Directory Structure

```
lib/optimal_system_agent/
├── agents/              # 25 agent modules (AgentBehaviour implementations)
├── agent/               # Core agent infrastructure (roster, loop, cortex, context)
├── channels/            # Channel adapters (telegram, discord, slack, cli, http)
├── tools/               # Tool registry and middleware
│   └── builtins/        # Built-in tool implementations (file ops, git, web, etc.)
├── providers/           # LLM provider integrations (anthropic, openai, ollama, etc.)
├── events/              # Event bus, signal classification, failure modes
├── signal/              # Signal Theory classifier (LLM + deterministic)
├── commands/            # CLI command handlers
├── sandbox/             # Docker/container isolation
├── platform/            # Platform abstractions (computer use adapters)
├── intelligence/        # Decision trees, complexity analysis
├── mcp/                 # Model Context Protocol client
├── security/            # Auth/authorization
└── onboarding/          # User onboarding flows

lib/miosa/
└── shims.ex             # 28 backward-compat shims for extracted packages

desktop/src/routes/app/  # SvelteKit frontend (file-based routing)
priv/skills/             # SKILL.md files (YAML frontmatter + markdown)
priv/prompts/            # System prompts by role
config/                  # Elixir config files (config.exs, runtime.exs, etc.)
test/                    # ExUnit tests (mirrors lib/ structure)
```

## Adding a New Agent

### 1. Create the module

```elixir
# lib/optimal_system_agent/agents/my_agent.ex
defmodule OptimalSystemAgent.Agents.MyAgent do
  @behaviour OptimalSystemAgent.Agent.AgentBehaviour

  @impl true
  def name, do: "my-agent"

  @impl true
  def description, do: "Does something specific"

  @impl true
  def tier, do: :specialist  # :elite | :specialist | :utility

  @impl true
  def role, do: :specialist  # :lead | :specialist | :utility

  @impl true
  def system_prompt do
    """
    You are a specialist agent for...
    """
  end

  @impl true
  def skills, do: ["brainstorming", "code-review"]

  @impl true
  def triggers, do: ["my keyword", "another trigger"]

  @impl true
  def territory, do: ["*.specific", "path/to/domain/"]

  @impl true
  def escalate_to, do: "architect"

  # Optional: custom message handling
  @impl true
  def handle(message, context) do
    {:ok, "Response to: #{message}"}
  end
end
```

### 2. Register in Roster

Add your module to `@agent_modules` in `lib/optimal_system_agent/agent/roster.ex` (line ~37):

```elixir
@agent_modules [
  # ... existing agents
  OptimalSystemAgent.Agents.MyAgent
]
```

### 3. Add tests

```elixir
# test/agents/my_agent_test.exs
defmodule OptimalSystemAgent.Agents.MyAgentTest do
  use ExUnit.Case, async: true
  alias OptimalSystemAgent.Agents.MyAgent

  test "implements all required callbacks" do
    assert is_binary(MyAgent.name())
    assert MyAgent.tier() in [:elite, :specialist, :utility]
    assert is_list(MyAgent.triggers())
  end
end
```

### Required Callbacks (9)

| Callback | Returns | Purpose |
|---|---|---|
| `name/0` | `String.t()` | Unique agent identifier |
| `description/0` | `String.t()` | Human-readable description |
| `tier/0` | `:elite \| :specialist \| :utility` | Determines LLM model tier |
| `role/0` | `atom()` | Agent role category |
| `system_prompt/0` | `String.t()` | LLM system prompt |
| `skills/0` | `[String.t()]` | Skills this agent can use |
| `triggers/0` | `[String.t()]` | Keywords that route to this agent |
| `territory/0` | `[String.t()]` | File patterns this agent handles |
| `escalate_to/0` | `String.t() \| nil` | Agent to escalate to |

### Optional Callbacks (3)

| Callback | Purpose |
|---|---|
| `handle/2` | Custom message processing |
| `before_handle/2` | Pre-processing hook |
| `after_handle/2` | Post-processing hook |

---

## Adding a New Tool

### 1. Create the module

```elixir
# lib/optimal_system_agent/tools/builtins/my_tool.ex
defmodule OptimalSystemAgent.Tools.Builtins.MyTool do
  @behaviour MiosaTools.Behaviour

  @impl true
  def name, do: "my_tool"

  @impl true
  def description, do: "Does something useful"

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "input" => %{"type" => "string", "description" => "The input to process"},
        "verbose" => %{"type" => "boolean", "description" => "Show details"}
      },
      "required" => ["input"]
    }
  end

  @impl true
  def safety, do: :read_only  # :read_only | :write_safe | :write_destructive | :terminal

  @impl true
  def available?, do: true

  @impl true
  def execute(%{"input" => input} = params) do
    verbose = Map.get(params, "verbose", false)
    result = process(input, verbose)
    {:ok, result}
  rescue
    e -> {:error, Exception.message(e)}
  end
end
```

### 2. Register

Tools auto-register via `Tools.Registry`. Add to the builtin list in the registry module, or register dynamically:

```elixir
Tools.Registry.register(OptimalSystemAgent.Tools.Builtins.MyTool)
```

### Required Callbacks (6)

| Callback | Returns | Purpose |
|---|---|---|
| `name/0` | `String.t()` | Tool name (used in LLM tool calls) |
| `description/0` | `String.t()` | Shown to LLM for tool selection |
| `parameters/0` | `map()` | JSON Schema for input validation |
| `execute/1` | `{:ok, any()} \| {:error, String.t()}` | Runs the tool |
| `safety/0` | safety level atom | Controls LLM access permissions |
| `available?/0` | `boolean()` | Runtime feature flag |

---

## Adding a New Provider

### 1. Create the module

```elixir
# lib/optimal_system_agent/providers/my_provider.ex
defmodule OptimalSystemAgent.Providers.MyProvider do
  @behaviour OptimalSystemAgent.Providers.Behaviour

  @impl true
  def name, do: :my_provider

  @impl true
  def default_model, do: "my-model-v1"

  @impl true
  def chat(messages, opts \\ []) do
    # messages: [%{role: "user", content: "..."}]
    # opts: [model: "...", temperature: 0.7, max_tokens: 4096]
    {:ok, %{content: "response", tool_calls: []}}
  end

  # Optional
  @impl true
  def chat_stream(messages, callback, opts \\ []) do
    # callback receives {:text_delta, text}, {:done, result}
    :ok
  end

  @impl true
  def available_models, do: ["my-model-v1", "my-model-v2"]
end
```

### Required Callbacks (3)

| Callback | Returns | Purpose |
|---|---|---|
| `name/0` | `atom()` | Provider identifier |
| `default_model/0` | `String.t()` | Default model to use |
| `chat/2` | `{:ok, %{content, tool_calls}} \| {:error, String.t()}` | Send messages to LLM |

### Optional Callbacks (2)

| Callback | Purpose |
|---|---|
| `chat_stream/3` | Streaming responses |
| `available_models/0` | List supported models |

---

## Adding a New Channel

### 1. Create the module

```elixir
# lib/optimal_system_agent/channels/my_channel.ex
defmodule OptimalSystemAgent.Channels.MyChannel do
  use GenServer
  @behaviour OptimalSystemAgent.Channels.Behaviour

  @impl true
  def channel_name, do: :my_channel

  @impl true
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def send_message(chat_id, message, opts \\ []) do
    GenServer.call(__MODULE__, {:send, chat_id, message, opts})
  end

  @impl true
  def connected? do
    GenServer.whereis(__MODULE__) != nil
  end

  # GenServer callbacks
  def init(opts), do: {:ok, %{opts: opts}}

  def handle_call({:send, chat_id, message, _opts}, _from, state) do
    # Send message to platform
    {:reply, :ok, state}
  end
end
```

### Required Callbacks (4)

| Callback | Returns | Purpose |
|---|---|---|
| `channel_name/0` | `atom()` | Channel identifier |
| `start_link/1` | `GenServer.on_start()` | Start the channel process |
| `send_message/3` | `:ok \| {:error, term()}` | Send outbound message |
| `connected?/0` | `boolean()` | Check if channel is active |

---

## Adding a New Screen (Desktop)

### 1. Create the route

```
desktop/src/routes/app/my-screen/+page.svelte    # Page component
desktop/src/routes/app/my-screen/+page.ts         # Data loader (optional)
```

### 2. Page component

```svelte
<!-- desktop/src/routes/app/my-screen/+page.svelte -->
<script lang="ts">
  import { onMount } from 'svelte';

  let data = $state<any[]>([]);

  onMount(async () => {
    const res = await fetch('/api/my-data');
    data = await res.json();
  });
</script>

<div class="p-6">
  <h1 class="text-2xl font-bold mb-4">My Screen</h1>
  <!-- Content here -->
</div>
```

### 3. Add to navigation

Update the `NAV_ROUTES` array in `desktop/src/routes/app/+layout.svelte` to add your route.

### 4. Data loader (optional)

```typescript
// desktop/src/routes/app/my-screen/+page.ts
export async function load({ fetch }) {
  const res = await fetch('/api/my-data');
  return { items: await res.json() };
}
```

---

## Adding a New Skill

### 1. Create the skill file

```markdown
<!-- priv/skills/category/my-skill.md -->
---
name: my-skill
description: Brief description of what this skill does
triggers:
  - keyword1
  - keyword2
  - phrase trigger
---

# My Skill

## When This Activates
Describe the conditions that trigger this skill.

## Process
1. Step one
2. Step two
3. Step three

## Output Format
Describe expected output structure.
```

### 2. Skill discovery

Skills in `priv/skills/` are auto-discovered at boot. User skills go in `~/.osa/skills/`.

### Frontmatter Fields

| Field | Type | Purpose |
|---|---|---|
| `name` | `string` | Unique skill identifier |
| `description` | `string` | Human-readable description |
| `triggers` | `[string]` | Keywords that activate the skill |

---

## Configuration

### Environment Variables
```
OSA_DEFAULT_PROVIDER=ollama          # Default LLM provider
ANTHROPIC_API_KEY=                   # Anthropic API key
OPENAI_API_KEY=                      # OpenAI API key
OLLAMA_URL=http://localhost:11434    # Ollama server URL
OLLAMA_MODEL=llama3.2:latest        # Default Ollama model
OSA_SANDBOX_ENABLED=true            # Enable Docker sandboxing
```

### Elixir Config
- `config/config.exs` — Base config (all envs)
- `config/runtime.exs` — Runtime overrides
- `config/test.exs` — Test environment
- `config/dev.exs` — Development
- `config/prod.exs` — Production

### User Config
- `~/.osa/` — Main user config directory
- `~/.osa/skills/` — User skill files
- `~/.osa/mcp.json` — MCP server configuration
- `~/.osa/sessions/` — Session history (JSONL)

---

## Testing

### Structure
Tests mirror `lib/` structure under `test/`:
- `test/agents/` — Agent tests
- `test/tools/builtins/` — Tool tests
- `test/providers/` — Provider tests
- `test/channels/` — Channel tests

### Conventions
- File: `{module}_test.exs`
- Module: `{Module}Test`
- Async by default: `use ExUnit.Case, async: true`
- Pattern: Arrange -> Act -> Assert

### Running
```bash
mix test                    # All tests
mix test test/agents/       # Directory
mix test test/my_test.exs   # Single file
mix test --only tag:value   # By tag
```

---

## Key Architecture Notes

1. **Roster** builds agent map at compile time from `@agent_modules` list
2. **Tools.Registry** uses `:persistent_term` for lock-free parallel reads
3. **Events.Bus** uses goldrush-compiled dispatch for BEAM-speed event routing
4. **Hooks** use ETS atomic counters (`:osa_hook_metrics`) — no GenServer bottleneck
5. **Shims** (`lib/miosa/shims.ex`) provide backward-compat for extracted MIOSA packages
6. **Signal classifier** (`Signal.Classifier`) uses LLM with deterministic fallback
