# Contributing to OptimalSystemAgent

We welcome contributions. The highest-impact way to contribute is by writing skills — not by submitting code PRs. Skills are where the value lives for users. Code PRs are welcome too, but if you are not sure where to start, write a skill.

---

## The Contribution Model

OSA follows a skills-first contribution model (similar to NanoClaw's agent-template approach):

| Contribution Type | Impact | Effort | Review Speed |
|-------------------|--------|--------|--------------|
| **SKILL.md skill** | High | Low | Fast |
| **Elixir module skill** | High | Medium | Moderate |
| **Bug fix** | High | Varies | Fast |
| **Documentation** | Medium | Low | Fast |
| **New channel adapter** | High | High | Slower |
| **Core engine change** | Very High | High | Careful review |

**Skills are the preferred contribution.** A well-written SKILL.md file that solves a real business problem is more valuable to the community than most code changes. And it requires no Elixir knowledge.

---

## Contributing a Skill

### SKILL.md (No Code Required)

1. Fork the repo
2. Create `examples/skills/your-skill/SKILL.md`
3. Follow the format:

```markdown
---
name: your-skill-name
description: One line description
tools:
  - file_read
  - file_write
  - web_search
  - memory_save
---

## Instructions

[Detailed instructions for the agent]

## Examples

[3-5 example prompts and expected behaviors]
```

4. Test it by copying to `~/.osa/skills/your-skill/` and using it in a conversation
5. Submit a PR

### Skill Quality Checklist

Before submitting a skill:

- [ ] **Name is descriptive.** `sales-pipeline` not `sp` or `pipeline`
- [ ] **Description is one clear sentence.** The LLM reads this to decide when to use the skill.
- [ ] **Instructions are specific.** Step-by-step workflow, not vague guidance.
- [ ] **Instructions are under 500 words.** Context window efficiency matters.
- [ ] **Examples cover 3-5 scenarios.** Common case, edge case, boundary.
- [ ] **Tools are minimal.** Only list tools the skill actually needs.
- [ ] **No fabrication instructions.** The skill should never tell the agent to make things up.
- [ ] **Tested locally.** You ran it and it works.

### Skill Ideas We Want

If you are looking for ideas, here are skills the community would benefit from:

- **Invoice generator** — Create invoices from conversation context
- **Competitor monitor** — Track competitor websites and social media for changes
- **Social media scheduler** — Plan and organize social posts across platforms
- **Hiring pipeline** — Track candidates, schedule interviews, follow up
- **Project planner** — Break down a project into tasks with estimates
- **Expense tracker** — Categorize expenses from receipts or bank statements
- **Networking assistant** — Track professional contacts and follow-up cadence
- **Learning planner** — Create study plans, track progress, quiz on material
- **Legal document reviewer** — Flag common issues in contracts (non-legal-advice)
- **Inventory tracker** — Track inventory levels and alert on low stock

---

## Development Setup

### Prerequisites

- Elixir 1.17+ and OTP 27+
- Ollama (for local testing without API keys)
- Git

### Setup

```bash
# Clone your fork
git clone https://github.com/YOUR_USERNAME/OSA.git
cd OSA

# Install dependencies and compile
mix setup

# Run the setup wizard (creates ~/.osa/ config directory)
mix osa.setup

# Verify everything works
mix test
mix chat
```

### Running Locally

```bash
# Interactive CLI
mix chat

# The HTTP API starts automatically on port 8089
curl http://localhost:8089/health
```

### Project Structure

```
lib/
├── optimal_system_agent/
│   ├── agent/           # Core agent loop, context, scheduler, compactor, cortex, memory
│   ├── bridge/          # PubSub bridge (goldrush -> PubSub, 3-tier fan-out)
│   ├── channels/        # Platform adapters (CLI, HTTP/API, future: Telegram, Discord)
│   │   └── http/        # HTTP channel (Bandit + Plug)
│   │       ├── api.ex   # REST API endpoints
│   │       └── auth.ex  # JWT HS256 authentication
│   ├── events/          # Event bus (goldrush-compiled :osa_event_router)
│   ├── intelligence/    # Communication intelligence (5 modules)
│   ├── mcp/             # Model Context Protocol client
│   ├── providers/       # LLM provider abstraction (Ollama, Anthropic, OpenAI)
│   ├── signal/          # Signal Theory 5-tuple classifier + noise filter
│   ├── skills/          # Skills.Behaviour + builtins + markdown skill loader
│   │   └── builtins/    # Built-in tools (file_read, file_write, shell_execute, etc.)
│   ├── store/           # Ecto + SQLite3
│   └── machines.ex      # Composable skill set activation
│
├── mix/tasks/           # Mix tasks (osa.setup, osa.chat)

config/                  # Application configuration
examples/                # Example skills, HEARTBEAT.md, config.json
docs/                    # Documentation
support/                 # macOS LaunchAgent, system support files
install.sh               # One-click installer
```

---

## Running Tests

```bash
# Run all tests
mix test

# Run tests with coverage
mix test --cover

# Run a specific test file
mix test test/signal/classifier_test.exs

# Run tests matching a pattern
mix test --only tag:signal
```

### Writing Tests

Tests go in the `test/` directory, mirroring the `lib/` structure:

```elixir
defmodule OptimalSystemAgent.Signal.ClassifierTest do
  use ExUnit.Case

  alias OptimalSystemAgent.Signal.Classifier

  describe "classify/2" do
    test "classifies urgent messages as high weight" do
      signal = Classifier.classify("Urgent: production is down")
      assert signal.weight >= 0.8
      assert signal.mode == :execute
    end

    test "classifies greetings as low weight" do
      signal = Classifier.classify("hey")
      assert signal.weight < 0.4
    end

    test "classifies questions with question mark" do
      signal = Classifier.classify("What is our revenue?")
      assert signal.type == "question"
    end
  end
end
```

### Test Coverage Targets

- Statements: 80%+
- The signal classifier and noise filter should have near-complete coverage
- Skills should be tested with both happy path and error cases

---

## Submitting Code Changes

### Adding a Skill (Elixir Module)

1. Create `lib/optimal_system_agent/skills/builtins/your_skill.ex`
2. Implement `OptimalSystemAgent.Skills.Behaviour` (4 callbacks: `name`, `description`, `parameters`, `execute`)
3. Register it in `lib/optimal_system_agent/skills/registry.ex` in `load_builtin_skills/0`
4. Add a fallback dispatch clause in `dispatch_builtin/2`
5. Write tests
6. Submit PR

```elixir
defmodule OptimalSystemAgent.Skills.Builtins.YourSkill do
  @behaviour OptimalSystemAgent.Skills.Behaviour

  @impl true
  def name, do: "your_skill"

  @impl true
  def description, do: "What it does — be specific, the LLM reads this"

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "input" => %{"type" => "string", "description" => "The input to process"}
      },
      "required" => ["input"]
    }
  end

  @impl true
  def execute(%{"input" => input}) do
    # Your implementation
    {:ok, "Result: #{input}"}
  end
end
```

### Adding a Channel Adapter

1. Create `lib/optimal_system_agent/channels/your_channel.ex`
2. Implement as a GenServer (see `channels/cli.ex` for reference pattern)
3. Register with `Channels.Supervisor` (DynamicSupervisor)
4. Process incoming messages through `Signal.Classifier` then `Agent.Loop`
5. Handle outbound messages from the event bus
6. Add config keys to `config/config.exs` and `config/runtime.exs`
7. Write tests
8. Submit PR

### Adding an LLM Provider

1. Add a `do_chat/3` clause to `lib/optimal_system_agent/providers/registry.ex`
2. Handle message formatting, tool formatting, and response parsing
3. Add config keys (api_key, model, url) to `config/config.exs` and `config/runtime.exs`
4. Write tests with mocked HTTP responses
5. Submit PR

### Adding a Machine

1. Add a `machine_addendum/1` clause to `lib/optimal_system_agent/machines.ex`
2. Register associated skills in `Skills.Registry`
3. Add the machine toggle to `~/.osa/config.json` handling in `determine_active_machines/1`
4. Update `examples/config.json`
5. Submit PR

---

## Code Style

### Formatting

```bash
# Always run before committing
mix format
```

OSA uses the default Elixir formatter configuration.

### Naming

- Modules: `PascalCase` — `OptimalSystemAgent.Skills.Builtins.WebSearch`
- Functions: `snake_case` — `classify_mode/1`, `load_builtin_skills/0`
- Variables: `snake_case` — `session_id`, `tool_calls`
- Constants: Module attributes — `@max_iterations 20`

### Module Structure

Every module should have:

```elixir
defmodule OptimalSystemAgent.YourModule do
  @moduledoc """
  One paragraph explaining what this module does and why it exists.

  Reference architecture decisions or Signal Theory concepts if relevant.
  """

  # ... implementation
end
```

### Function Guidelines

- Functions should be short and focused (under 20 lines ideal)
- Use pattern matching in function heads over conditional logic in function bodies
- Use pipe operators for data transformation chains
- Private helper functions at the bottom of the module
- Group public API at the top, callbacks next, private functions last

### Error Handling

- Skills return `{:ok, result}` or `{:error, reason}` — always strings
- Use `Logger.warning/1` for recoverable issues
- Use `Logger.error/1` for unexpected failures
- Let OTP supervision handle crashes — do not rescue everything

---

## Pull Request Guidelines

1. **Fork the repo and create a feature branch** from `main`
2. **Keep PRs focused.** One feature or fix per PR. If you need to refactor something as part of a feature, submit the refactor as a separate PR first.
3. **Run `mix test` and `mix format`** before submitting
4. **Write a clear PR description:**
   - What does this change do?
   - Why is it needed?
   - How was it tested?
5. **Link to an issue** if one exists
6. **Be responsive to review feedback** — we aim to review PRs within a few days

### PR Title Format

```
[type] Short description

Examples:
[skill] Add invoice-generator skill
[fix] Handle nil session_id in Loop.process_message
[feat] Add Groq provider support
[docs] Add HEARTBEAT.md examples
[refactor] Extract tool formatting from Providers.Registry
```

---

## Community

- **Issues:** Report bugs and request features on GitHub Issues
- **Discussions:** Use GitHub Discussions for questions and ideas
- **Skills showcase:** Share your skills in the `examples/skills/` directory via PR

---

## License

By contributing, you agree that your contributions will be licensed under the Apache 2.0 License.
