# Contributing to OptimalSystemAgent

We welcome contributions. There are many ways to contribute — skills, hooks, agent definitions, command templates, swarm patterns, bug fixes, and core engine changes. Pick the one that matches your skills and interest.

---

## The Contribution Model

| Contribution Type | Impact | Effort | Review Speed | Elixir Required? |
|-------------------|--------|--------|--------------|------------------|
| **SKILL.md skill** | High | Low | Fast | No |
| **Command template** | Medium | Low | Fast | No |
| **Agent definition** | Medium | Low | Fast | No |
| **Swarm pattern** | Medium | Low | Fast | No |
| **Hook** | High | Medium | Moderate | Yes |
| **Elixir module skill** | High | Medium | Moderate | Yes |
| **Bug fix** | High | Varies | Fast | Yes |
| **Documentation** | Medium | Low | Fast | No |
| **New channel adapter** | High | High | Slower | Yes |
| **New LLM provider** | High | Medium | Moderate | Yes |
| **Core engine change** | Very High | High | Careful review | Yes |

**No-code contributions are preferred.** A well-written SKILL.md, command template, or agent definition is more valuable to the community than most code changes.

---

## No-Code Contributions

### Skills (SKILL.md)

Drop a markdown file in `priv/skills/` or `~/.osa/skills/your-skill/SKILL.md`:

```markdown
---
name: your-skill-name
description: One line description
tools:
  - file_read
  - file_write
  - web_search
triggers:
  - "analyze data"
  - "csv"
priority: 50
---

## Instructions

[Detailed instructions for the agent]

## Examples

[3-5 example prompts and expected behaviors]
```

**Quality checklist:**

- [ ] Name is descriptive (`sales-pipeline` not `sp`)
- [ ] Description is one clear sentence (the LLM reads this to decide when to use the skill)
- [ ] Instructions are specific and under 500 words
- [ ] Examples cover 3-5 scenarios (happy path + edge cases)
- [ ] Tools list only what the skill actually needs
- [ ] No fabrication instructions
- [ ] Tested locally

### Command Templates

Command templates live in `priv/commands/{category}/` and are invoked as slash commands:

```
priv/commands/
├── workflow/     # /commit, /build, /test, /lint, /verify, /create-pr, /fix, /explain
├── context/      # /prime-backend, /prime-webdev, /prime-svelte, /prime-security
├── security/     # /security-scan, /secret-scan, /harden
├── memory/       # /mem-search, /mem-save, /mem-recall, /mem-stats
└── utility/      # /debug, /review, /refactor, /agents, /status, /doctor, /analytics
```

Each command is a markdown file. The filename becomes the command name. Content is expanded as a prompt when the user invokes the slash command:

```markdown
You are performing a security scan on the current codebase.

## Steps

1. Check for hardcoded secrets (API keys, passwords, tokens)
2. Review input validation on all endpoints
3. Check for SQL injection vulnerabilities
4. Review authentication and authorization logic
5. Report findings with severity levels

## Output Format

| Severity | File | Line | Issue | Recommendation |
```

To contribute: add your `.md` file to the appropriate category directory, wire the command name in `lib/optimal_system_agent/commands.ex`, and submit a PR.

### Agent Definitions

Agent definitions live in `priv/agents/{category}/`:

```
priv/agents/
├── elite/        # dragon, oracle, nova, blitz, architect
├── combat/       # parallel, cache, quantum, angel
├── security/     # security-auditor, red-team, blue-team, purple-team, threat-intel
└── specialists/  # backend-go, frontend-react, frontend-svelte, database-specialist,
                  # debugger, test-automator, code-reviewer, explorer, etc.
```

Each definition is a markdown file with the agent's role prompt, capabilities, constraints, and behavior guidelines. Loaded at runtime via `Roster.load_definition/1`.

### Swarm Patterns

Swarm patterns are defined in `priv/swarms/patterns.json`:

```json
{
  "patterns": {
    "your-pattern": {
      "name": "Your Pattern",
      "description": "What this pattern does",
      "agents": ["researcher", "builder", "reviewer"],
      "collaboration": "pipeline",
      "max_rounds": 3
    }
  }
}
```

Currently shipped patterns: `code-analysis`, `full-stack`, `debug-swarm`, `performance-audit`, `security-audit`, `documentation`, `adaptive-debug`, `adaptive-feature`, `concurrent-migration`, `ai-pipeline`.

---

## Code Contributions

### Development Setup

**Prerequisites:**

- Elixir 1.19+ and OTP 28+
- Ollama (for local testing without API keys)
- Git

```bash
# Clone your fork
git clone https://github.com/YOUR_USERNAME/OSA.git
cd OSA

# Install dependencies and compile
mix setup

# Run the setup wizard (creates ~/.osa/ config directory)
mix osa.setup

# Verify everything works
mix test     # 440 tests, 0 failures
mix chat     # Interactive CLI
```

### Project Structure

```
lib/
├── optimal_system_agent/
│   ├── agent/              # Core agent subsystems
│   │   ├── loop.ex         # Main agent loop (message → classify → route → respond)
│   │   ├── context.ex      # Token-budgeted context assembly (4-tier priority)
│   │   ├── compactor.ex    # 3-zone sliding window compression
│   │   ├── cortex.ex       # Knowledge synthesis
│   │   ├── hooks.ex        # 16-hook middleware pipeline
│   │   ├── memory.ex       # 3-store memory (session + long-term + episodic)
│   │   ├── orchestrator.ex # Multi-agent task decomposition
│   │   ├── progress.ex     # Real-time progress tracking
│   │   ├── roster.ex       # 25 agent definitions loader
│   │   ├── scheduler.ex    # Cron + heartbeat
│   │   ├── tier.ex         # 18-provider × 3-tier model routing
│   │   └── workflow.ex     # Multi-step workflow tracking
│   ├── bridge/             # PubSub bridge (goldrush → Phoenix.PubSub, 3-tier fan-out)
│   ├── channels/           # Platform adapters
│   │   ├── cli.ex          # Terminal interface
│   │   ├── cli/
│   │   │   ├── line_editor.ex  # Readline (arrow keys, history, Ctrl bindings)
│   │   │   └── spinner.ex      # Animated spinner (elapsed time, tool tracking)
│   │   └── http/           # HTTP channel (Bandit + Plug, port 8089)
│   ├── events/             # Event bus (goldrush-compiled :osa_event_router)
│   ├── intelligence/       # Communication intelligence (5 modules)
│   ├── mcp/                # Model Context Protocol client
│   ├── providers/          # 18 LLM provider adapters
│   ├── signal/             # Signal Theory 5-tuple classifier + noise filter
│   ├── skills/             # Skills.Behaviour + builtins + markdown loader
│   ├── store/              # Ecto + SQLite3
│   ├── swarm/              # Multi-agent coordination
│   │   ├── pact.ex         # PACT framework (Plan→Action→Coordination→Testing)
│   │   ├── intelligence.ex # Swarm intelligence (5 roles, voting, convergence)
│   │   └── patterns.ex     # 10 named swarm patterns
│   ├── commands.ex         # 63 slash commands
│   ├── prompt_loader.ex    # Template loader (priv/ + ~/.osa/ overrides)
│   └── machines.ex         # Composable skill set activation

priv/
├── agents/         # 25 agent definitions (elite/, combat/, security/, specialists/)
├── commands/       # 63 command templates (workflow/, context/, security/, memory/, utility/)
├── prompts/        # Externalized prompt templates
├── scripts/        # 13 utility scripts
├── skills/         # 29 skill definitions with YAML frontmatter
└── swarms/         # patterns.json (10 swarm patterns)

config/             # Application configuration (config.exs, runtime.exs)
test/               # 440 tests mirroring lib/ structure
docs/               # Documentation
examples/           # Example skills, configs
```

### Running Tests

```bash
mix test                                    # Run all 440 tests
mix test --cover                            # With coverage report
mix test test/signal/classifier_test.exs    # Single file
mix test --only tag:signal                  # By tag
```

**Coverage targets:** 80%+ statements. Signal classifier and noise filter should have near-complete coverage.

### Writing Tests

Tests mirror the `lib/` structure in `test/`:

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
  end
end
```

---

## Adding Things

### Adding a Skill (Elixir Module)

1. Create `lib/optimal_system_agent/skills/builtins/your_skill.ex`
2. Implement `OptimalSystemAgent.Skills.Behaviour` (4 callbacks: `name`, `description`, `parameters`, `execute`)
3. Register in `skills/registry.ex` → `load_builtin_skills/0`
4. Add dispatch clause in `dispatch_builtin/2`
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
    {:ok, "Result: #{input}"}
  end
end
```

### Adding a Hook

Hooks are registered in `lib/optimal_system_agent/agent/hooks.ex` → `register_builtins/1`:

```elixir
# In register_builtins/1:
register_hook(state, %{
  name: :your_hook,
  event: :post_tool_use,     # or :pre_tool_use, :pre_response, :session_end
  priority: 50,              # Lower = runs first (10-95 range)
  handler: fn payload ->
    # Return {:ok, payload}, {:block, reason}, or :skip
    {:ok, payload}
  end
})
```

Current hooks run at priorities 10-95. Pick a priority that makes sense relative to existing hooks. See `hooks.ex` for the full list.

### Adding an LLM Provider

1. Add a `do_chat/3` clause to `providers/registry.ex`
2. Handle message formatting, tool formatting, response parsing
3. Add tier mappings to `agent/tier.ex` → `@tier_models`
4. Add config keys to `config/config.exs` and `config/runtime.exs`
5. Write tests with mocked HTTP responses
6. Submit PR

### Adding a Channel Adapter

1. Create `lib/optimal_system_agent/channels/your_channel.ex`
2. Implement as a GenServer (see `channels/cli.ex` for reference)
3. Register with `Channels.Supervisor` (DynamicSupervisor)
4. Process messages through `Signal.Classifier` → `Agent.Loop`
5. Handle outbound messages from the event bus
6. Add config keys to `config/config.exs` and `config/runtime.exs`
7. Write tests
8. Submit PR

---

## Code Style

```bash
# Always run before committing
mix format
```

**Naming:**

- Modules: `PascalCase` — `OptimalSystemAgent.Skills.Builtins.WebSearch`
- Functions: `snake_case` — `classify_mode/1`, `load_builtin_skills/0`
- Variables: `snake_case` — `session_id`, `tool_calls`
- Constants: Module attributes — `@max_iterations 20`

**Module structure:** `@moduledoc` → public API → callbacks → private functions.

**Function guidelines:**

- Short and focused (under 20 lines ideal)
- Pattern matching in function heads over conditionals in bodies
- Pipe operators for data transformation chains
- Let OTP supervision handle crashes — don't rescue everything

**Error handling:**

- Skills return `{:ok, result}` or `{:error, reason}` — always strings
- `Logger.warning/1` for recoverable issues
- `Logger.error/1` for unexpected failures

---

## Pull Request Guidelines

1. **Fork and create a feature branch** from `main`
2. **Keep PRs focused** — one feature or fix per PR
3. **Run `mix test` and `mix format`** before submitting
4. **Write a clear PR description** — what, why, how tested
5. **Link to an issue** if one exists

### PR Title Format

```
[type] Short description

[skill]    Add invoice-generator skill
[hook]     Add rate-limiting hook for tool calls
[agent]    Add kubernetes-specialist agent definition
[cmd]      Add /deploy command template
[fix]      Handle nil session_id in Loop.process_message
[feat]     Add Groq provider support
[docs]     Update architecture documentation
[refactor] Extract tool formatting from Providers.Registry
```

---

## Skill Ideas We Want

If you're looking for ideas:

- **Invoice generator** — Create invoices from conversation context
- **Competitor monitor** — Track competitor websites for changes
- **Social media scheduler** — Plan and organize social posts
- **Hiring pipeline** — Track candidates, schedule interviews
- **Project planner** — Break down projects into tasks with estimates
- **Expense tracker** — Categorize expenses from receipts
- **Learning planner** — Create study plans, track progress
- **Legal document reviewer** — Flag common issues in contracts
- **Inventory tracker** — Track levels, alert on low stock
- **CI/CD analyzer** — Parse pipeline logs, suggest fixes
- **API documentation generator** — Generate OpenAPI specs from code
- **Database migration planner** — Plan safe schema migrations

---

## Community

- **Issues:** Report bugs and request features on [GitHub Issues](https://github.com/Miosa-osa/OSA/issues)
- **Discussions:** Use [GitHub Discussions](https://github.com/Miosa-osa/OSA/discussions) for questions and ideas
- **Skills showcase:** Share skills in `priv/skills/` or `examples/skills/` via PR

---

## License

By contributing, you agree that your contributions will be licensed under the Apache 2.0 License.
