# Skills Guide

Skills are the actions your OSA agent can perform. This guide covers everything about writing, registering, and managing skills.

---

## Two Types of Skills

OSA supports two skill formats:

| Format | Best For | Requires Code | Hot Reload |
|--------|----------|---------------|------------|
| **SKILL.md** (Markdown) | Instructions, prompts, workflows | No | Yes |
| **Elixir Module** (Behaviour) | Programmatic tools, API integrations, data processing | Yes | Yes |

Both types are hot-reloaded — no restart needed when you add or modify skills.

## SKILL.md Format Reference

Drop a `SKILL.md` file into `~/.osa/skills/<skill-name>/` and it is available immediately.

### Directory Structure

```
~/.osa/skills/
  email-assistant/
    SKILL.md
  sales-pipeline/
    SKILL.md
  my-custom-skill/
    SKILL.md
```

### File Format

```markdown
---
name: skill-name
description: One line description of what this skill does
tools:
  - file_read
  - file_write
  - web_search
  - memory_save
  - shell_execute
---

## Instructions

Detailed instructions for the agent on how to use this skill.
Write these as if you are briefing a capable assistant.
Be specific about:
- What the skill does
- When to use it
- What steps to follow
- What to avoid

## Examples

Show example prompts and expected behavior.
This helps the agent understand the skill's scope.
```

### Frontmatter Fields

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Unique skill identifier. Lowercase, hyphens allowed. Must match the folder name. |
| `description` | Yes | One-line description. Shown in skill listings and used by the LLM to decide when to invoke the skill. |
| `tools` | No | List of built-in tools this skill can use. Available tools: `file_read`, `file_write`, `web_search`, `memory_save`, `shell_execute`. If omitted, no tool restrictions are applied. |

### Built-in Tools Reference

These are the tools available to SKILL.md skills:

| Tool | Description | Parameters |
|------|-------------|------------|
| `file_read` | Read a file from the filesystem | `path` (string) |
| `file_write` | Write content to a file | `path` (string), `content` (string) |
| `web_search` | Search the web via Brave Search API | `query` (string) |
| `memory_save` | Save information to long-term memory (MEMORY.md) | `content` (string), `category` (string, optional) |
| `shell_execute` | Run a shell command | `command` (string) |

### Writing Good Instructions

The `## Instructions` section is injected into the agent's context when the skill is relevant. Write it like a briefing document.

**Do:**
- Be specific about the workflow: step 1, step 2, step 3
- Define expected output formats
- List edge cases and how to handle them
- Explain when NOT to use the skill

**Do not:**
- Write vague instructions like "help the user with email"
- Include implementation details the agent does not need
- Make the instructions longer than ~500 words (context window efficiency)

### Writing Good Examples

Examples teach the agent by demonstration. Include 3-5 examples covering:

1. The most common use case
2. A variation or edge case
3. A boundary — what the skill does NOT do

Format:

```markdown
**User:** "The exact prompt the user would type"

**Expected behavior:** What the agent should do, step by step,
and what the output should look like.
```

## Elixir Module Skills (Skills.Behaviour)

For programmatic tools that need to execute code, make API calls, or process data.

### The Behaviour

Implement `OptimalSystemAgent.Skills.Behaviour` with four callbacks:

```elixir
defmodule MyApp.Skills.StockPrice do
  @behaviour OptimalSystemAgent.Skills.Behaviour

  @impl true
  def name, do: "stock_price"

  @impl true
  def description, do: "Get the current stock price for a ticker symbol"

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "ticker" => %{
          "type" => "string",
          "description" => "Stock ticker symbol (e.g., AAPL, GOOGL)"
        }
      },
      "required" => ["ticker"]
    }
  end

  @impl true
  def execute(%{"ticker" => ticker}) do
    case fetch_price(ticker) do
      {:ok, price} -> {:ok, "#{ticker}: $#{price}"}
      {:error, reason} -> {:error, "Failed to fetch #{ticker}: #{reason}"}
    end
  end

  defp fetch_price(ticker) do
    # Your implementation here
    {:ok, "182.52"}
  end
end
```

### Callback Reference

| Callback | Returns | Description |
|----------|---------|-------------|
| `name/0` | `String.t()` | Unique tool name. Lowercase, underscores. This is what the LLM calls. |
| `description/0` | `String.t()` | Human-readable description. The LLM uses this to decide when to call the tool. |
| `parameters/0` | `map()` | JSON Schema for tool arguments. Follows the standard JSON Schema format. |
| `execute/1` | `{:ok, String.t()} \| {:error, String.t()}` | Execute the tool with validated arguments. Always return a string result. |

### Parameter Schema

The `parameters/0` callback returns a JSON Schema object. The LLM uses this to generate valid arguments.

```elixir
def parameters do
  %{
    "type" => "object",
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "The search query"
      },
      "max_results" => %{
        "type" => "integer",
        "description" => "Maximum number of results to return",
        "default" => 5
      },
      "format" => %{
        "type" => "string",
        "enum" => ["json", "text", "markdown"],
        "description" => "Output format"
      }
    },
    "required" => ["query"]
  }
end
```

### Registration

Register at runtime — the skill is available immediately with no restart:

```elixir
OptimalSystemAgent.Skills.Registry.register(MyApp.Skills.StockPrice)
```

Under the hood, this recompiles the goldrush tool dispatcher module (`:osa_tool_dispatcher`) with the new skill. The compiled Erlang bytecode module is replaced in the running VM.

### Error Handling

Always return `{:error, reason}` for expected failures. The error message is shown to the LLM so it can inform the user or try a different approach.

```elixir
def execute(%{"ticker" => ticker}) do
  case fetch_price(ticker) do
    {:ok, price} -> {:ok, "$#{price}"}
    {:error, :not_found} -> {:error, "Ticker '#{ticker}' not found"}
    {:error, :rate_limited} -> {:error, "API rate limited — try again in 60 seconds"}
    {:error, reason} -> {:error, "Unexpected error: #{inspect(reason)}"}
  end
end
```

For unexpected crashes, OTP supervision handles recovery. The skill process crashes, the supervisor restarts it, and the agent loop retries or reports the failure.

## Hot Reload

Both skill types support hot reload — changes take effect without restarting OSA.

### SKILL.md Hot Reload

OSA watches `~/.osa/skills/` using `file_system` (fsnotify). When you:

- **Add** a new SKILL.md file: The skill is parsed and registered automatically
- **Modify** an existing SKILL.md: The skill definition is updated in the registry
- **Delete** a skill folder: The skill is removed from the registry

No restart, no recompile, no downtime.

### Elixir Module Hot Reload

When you call `Skills.Registry.register/1`, the goldrush tool dispatcher is recompiled. This happens in the running VM:

1. New skill module is loaded into the BEAM
2. Registry state is updated with the new skill
3. goldrush recompiles `:osa_tool_dispatcher` with the updated tool list
4. The next agent loop iteration sees the new tool

This is the same mechanism that powers Erlang's hot code upgrades in telecom systems.

## Machine Assignment

Skills can be grouped into machines. Machines are toggled in `~/.osa/config.json`:

```json
{
  "machines": {
    "communication": true,
    "productivity": true,
    "research": true
  }
}
```

| Machine | Skills Included | Default |
|---------|----------------|---------|
| **Core** | file_read, file_write, shell_execute, web_search, memory_save | Always on |
| **Communication** | telegram_send, discord_send, slack_send | Off |
| **Productivity** | calendar_read, calendar_create, task_manager | Off |
| **Research** | web_search_deep, summarize, translate | Off |

When a machine is activated:
1. Its skills are registered with the Skills.Registry
2. A machine-specific prompt addendum is injected into the system prompt
3. The LLM can now call those skills

Custom SKILL.md skills are always available regardless of machine configuration.

## Best Practices

### 1. Keep Skills Focused

One skill, one job. A skill that does email triage, calendar management, AND sales tracking is too broad. Split it into three skills.

### 2. Write Descriptions for the LLM

The `description` field is what the LLM reads to decide whether to use your skill. Make it clear and specific:

```
# Good
"Search the web using Brave Search API and return the top results with snippets"

# Bad
"Search stuff"
```

### 3. Use Memory for Persistence

Skills that learn user preferences should save them with `memory_save`:

```markdown
## Instructions
On first use, ask the user for their preferred timezone and save it to memory.
On subsequent uses, recall it from memory — do not ask again.
```

### 4. Handle Missing Data Gracefully

```markdown
## Instructions
If the user's calendar data is not available, skip the calendar section
and note: "Calendar data not found — connect your calendar to enable this."
Do not fail silently or fabricate data.
```

### 5. Limit Tool Access

Only list the tools your skill actually needs:

```yaml
tools:
  - web_search    # Only what this skill uses
```

### 6. Test with Edge Cases

Include examples that cover:
- Empty input
- Missing data
- Malformed requests
- What the skill should NOT do

### 7. Version Your Skills

If you make breaking changes to a skill, consider creating a new skill and deprecating the old one rather than modifying in place.

## Example Skills

See `examples/skills/` for complete, production-ready example skills:

- `email-assistant/` — Email triage and management
- `daily-briefing/` — Morning business briefing
- `sales-pipeline/` — Sales pipeline monitoring
- `content-writer/` — Content drafting assistant
- `meeting-prep/` — Meeting preparation

Copy any of these to `~/.osa/skills/` and they work immediately.
