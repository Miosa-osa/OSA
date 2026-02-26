# Contributing to OptimalSystemAgent

We welcome contributions! Here's how to get started.

## Development Setup

```bash
# Clone
git clone https://github.com/Miosa-osa/OSA.git
cd OSA

# Install dependencies
mix setup

# Run setup wizard
mix osa.setup

# Run tests
mix test

# Start interactive CLI
mix chat
```

## Project Structure

```
lib/
├── optimal_system_agent/
│   ├── agent/           # Core agent loop, context, scheduler, compactor, cortex, memory
│   ├── bridge/          # PubSub bridge (goldrush → PubSub, 3 tiers)
│   ├── channels/        # Platform adapters (CLI, Telegram, Discord, SDK)
│   ├── events/          # Event bus (goldrush-compiled :osa_event_router)
│   ├── intelligence/    # Communication intelligence (profiler, coach, tracker)
│   ├── mcp/             # MCP client/server integration
│   ├── providers/       # LLM provider abstraction (Ollama, Anthropic, OpenAI)
│   ├── signal/          # Signal Theory 5-tuple classifier + noise filter
│   ├── skills/          # Skills.Behaviour + builtins + markdown loader
│   ├── store/           # Ecto + SQLite3
│   └── machines.ex      # Composable skill set activation
│
├── mix/tasks/           # Mix tasks (osa.setup, osa.chat)
│
support/
├── com.osa.agent.plist  # macOS LaunchAgent
install.sh               # One-click installer
```

## Adding a Skill (Behaviour-based)

Implement `OptimalSystemAgent.Skills.Behaviour` with 4 callbacks:

```elixir
defmodule OptimalSystemAgent.Skills.MySkill do
  @behaviour OptimalSystemAgent.Skills.Behaviour

  @impl true
  def name, do: "my_skill"

  @impl true
  def description, do: "What it does"

  @impl true
  def parameters do
    %{"type" => "object", "properties" => %{}, "required" => []}
  end

  @impl true
  def execute(args) do
    {:ok, "result"}
  end
end
```

Register at runtime (hot reload — no restart needed):

```elixir
OptimalSystemAgent.Skills.Registry.register(OptimalSystemAgent.Skills.MySkill)
```

## Adding a Skill (Markdown-based)

Create a SKILL.md file in `~/.osa/skills/your_skill/`:

```markdown
---
name: your_skill
description: What it does
---

Instructions for the agent on how to use this skill.
```

## Adding a Channel Adapter

1. Create `lib/optimal_system_agent/channels/your_channel.ex`
2. Implement the channel GenServer pattern (see `cli.ex` for reference)
3. Register with the Channels.Supervisor

## Adding an LLM Provider

1. Add to `lib/optimal_system_agent/providers/registry.ex`
2. Implement the `do_chat/3` clause for your provider
3. Add config keys to `config/config.exs` and `config/runtime.exs`

## Adding a Machine

1. Add to `lib/optimal_system_agent/machines.ex`
2. Define machine_addendum/1 for the system prompt fragment
3. Register associated skills
4. Add config toggle to `~/.osa/config.json`

## Code Style

- Run `mix format` before committing
- Follow Elixir naming conventions
- Add `@moduledoc` to all modules
- Keep functions short and focused
- Skills must implement `Skills.Behaviour`

## Pull Requests

1. Fork the repo
2. Create a feature branch
3. Make your changes
4. Run `mix test` and `mix format`
5. Submit a PR with a clear description

## License

By contributing, you agree that your contributions will be licensed under Apache 2.0.
