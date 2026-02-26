# Getting Started with OSA

This guide gets you from zero to a working AI agent in about 5 minutes.

---

## Prerequisites

- **macOS, Linux, or WSL2** — OSA runs on any UNIX-like system
- **Elixir 1.17+** and **OTP 27+** — The install script handles this if you do not have them
- **Ollama** (recommended) — For local AI with no API keys. Install: `curl -fsSL https://ollama.com/install.sh | sh`
- Or an **Anthropic** or **OpenAI** API key if you want cloud models

## Installation

### One-Line Install (Recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/Miosa-osa/OSA/main/install.sh | bash
```

This script:
1. Checks for Elixir/OTP (installs via Homebrew or asdf if missing)
2. Clones the repository
3. Runs `mix deps.get` and `mix compile`
4. Launches the interactive setup wizard (`mix osa.setup`)
5. Creates the `~/.osa/` configuration directory
6. Sets up the SQLite database
7. Optionally installs the macOS LaunchAgent for auto-start

### Manual Install

```bash
git clone https://github.com/Miosa-osa/OSA.git
cd OSA
mix deps.get
mix osa.setup       # Interactive setup wizard
mix ecto.create && mix ecto.migrate
mix compile
```

### Verify Installation

```bash
mix chat
```

You should see the agent prompt. Type a message and confirm you get a response.

## Your First Conversation

```bash
$ mix chat

OSA> What can you help me with?

I'm an AI agent with access to your file system, shell, and web search.
I can help you with:
- Reading and writing files
- Running shell commands
- Searching the web
- Managing your schedule and tasks
- Anything you add as a custom skill

What would you like to do?
```

Try these to verify everything works:

```
What's the weather in San Francisco?
Read the file ~/Desktop/notes.txt
Search the web for "Elixir OTP tutorials 2026"
```

## Configuring Providers

OSA supports three LLM providers. You configure them via environment variables or `~/.osa/config.json`.

### Ollama (Local — Default)

No API key needed. Free. Your data never leaves your machine.

```bash
# Install Ollama (if not already)
curl -fsSL https://ollama.com/install.sh | sh

# Pull a model
ollama pull llama3.2:latest

# OSA uses Ollama by default — just start chatting
mix chat
```

To use a different Ollama model:

```bash
export OLLAMA_MODEL="mistral:latest"
# or
export OLLAMA_MODEL="deepseek-coder-v2:latest"
```

### Anthropic

```bash
export OSA_DEFAULT_PROVIDER=anthropic
export ANTHROPIC_API_KEY=sk-ant-...
mix chat
```

Default model: `anthropic-latest`. Override with:

```bash
# In config/config.exs or ~/.osa/config.json
anthropic_model: "your-preferred-model"
```

### OpenAI (or OpenAI-Compatible)

```bash
export OSA_DEFAULT_PROVIDER=openai
export OPENAI_API_KEY=sk-...
mix chat
```

Default model: `gpt-4o`. For OpenAI-compatible providers (Groq, Together, etc.):

```bash
export OPENAI_API_KEY=your-api-key
export OSA_DEFAULT_PROVIDER=openai
# Point to the compatible endpoint
# Set in ~/.osa/config.json: "openai_url": "https://api.groq.com/openai/v1"
```

## Understanding Signal Classification

Every message you send is classified before the AI sees it. This is what makes OSA different from every other agent framework.

When you send a message, OSA produces a 5-tuple:

```
S = (Mode, Genre, Type, Format, Weight)
```

| Dimension | What It Means | Values |
|-----------|---------------|--------|
| **Mode** | What operation to perform | BUILD, ASSIST, ANALYZE, EXECUTE, MAINTAIN |
| **Genre** | The communicative purpose | DIRECT, INFORM, COMMIT, DECIDE, EXPRESS |
| **Type** | Domain category | question, request, issue, scheduling, summary, general |
| **Format** | Container type | message, document, notification, command, transcript |
| **Weight** | Information value (0.0-1.0) | 0.0 = noise, 1.0 = critical signal |

**What this means in practice:**

- "hey" gets classified as Weight ~0.2 (noise) and is filtered — no AI call, no cost
- "What's our Q3 revenue trend compared to Q2?" gets Weight ~0.85 and is routed immediately
- "Urgent: production is down" gets Weight ~0.9 and is prioritized

You can see the classification for any message via the HTTP API:

```bash
curl -X POST http://localhost:8089/api/v1/classify \
  -H "Content-Type: application/json" \
  -d '{"message": "What is our Q3 revenue trend?"}'
```

Response:
```json
{
  "signal": {
    "mode": "analyze",
    "genre": "inform",
    "type": "question",
    "format": "command",
    "weight": 0.85,
    "channel": "http",
    "timestamp": "2026-02-24T10:30:00Z"
  }
}
```

## Adding Your First Custom Skill

Skills are the actions OSA can take. You can add new ones in two ways.

### Option 1: Markdown Skill (No Code)

Create a folder and SKILL.md file:

```bash
mkdir -p ~/.osa/skills/my-first-skill
```

Create `~/.osa/skills/my-first-skill/SKILL.md`:

```markdown
---
name: my-first-skill
description: Greet people by name with a fun fact
tools:
  - web_search
---

## Instructions

When asked to greet someone, search the web for a fun fact about their first name
and include it in a personalized greeting.

## Examples

User: "Greet Sarah"
Expected: "Hi Sarah! Fun fact: the name Sarah means 'princess' in Hebrew and has
been one of the top 10 names in the US for over 40 years."
```

No restart needed. OSA picks up new skills automatically.

### Option 2: Elixir Module Skill

Create a file `lib/my_skills/calculator.ex`:

```elixir
defmodule MySkills.Calculator do
  @behaviour OptimalSystemAgent.Skills.Behaviour

  @impl true
  def name, do: "calculator"

  @impl true
  def description, do: "Evaluate a math expression and return the result"

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "expression" => %{"type" => "string", "description" => "Math expression to evaluate"}
      },
      "required" => ["expression"]
    }
  end

  @impl true
  def execute(%{"expression" => expr}) do
    {result, _} = Code.eval_string(expr)
    {:ok, "#{result}"}
  end
end
```

Register it at runtime (hot reload — no restart):

```elixir
OptimalSystemAgent.Skills.Registry.register(MySkills.Calculator)
```

## Setting Up HEARTBEAT.md

The HEARTBEAT.md file lets OSA run tasks on a schedule — without you asking. The scheduler checks it every 30 minutes by default.

Edit `~/.osa/HEARTBEAT.md`:

```markdown
# Heartbeat Tasks

## Periodic Tasks
- [ ] Check the weather in San Francisco and save a summary to ~/.osa/briefings/weather.md
- [ ] Search for the latest news about AI agents and save the top 3 headlines to memory
```

OSA will:
1. Check the file every 30 minutes
2. Execute any unchecked items through the agent loop
3. Mark them as completed with a timestamp

```markdown
- [x] Check the weather in San Francisco and save a summary (completed 2026-02-24T14:30:00Z)
```

If a task fails 3 times in a row, the circuit breaker disables it. Fix the task description and uncheck it to re-enable.

See `examples/HEARTBEAT.md` for more practical periodic task examples.

## HTTP API Quickstart

OSA exposes a REST API on port 8089 for SDK clients and integrations.

### Health Check

```bash
curl http://localhost:8089/health
```

### Send a Message (Full Agent Loop)

```bash
curl -X POST http://localhost:8089/api/v1/orchestrate \
  -H "Content-Type: application/json" \
  -d '{"input": "What files are in my home directory?", "session_id": "my-session"}'
```

### List Available Skills

```bash
curl http://localhost:8089/api/v1/skills
```

### Stream Events (Server-Sent Events)

```bash
curl http://localhost:8089/api/v1/stream/my-session
```

In a separate terminal, send a message to that session — you will see events streaming in real-time.

### Enable Authentication (Production)

```bash
export OSA_SHARED_SECRET="your-secret-key-here"
export OSA_REQUIRE_AUTH=true
```

Generate a token:

```bash
# From an IEx session
token = OptimalSystemAgent.Channels.HTTP.Auth.generate_token(%{"user_id" => "me"})
```

Use it:

```bash
curl -X POST http://localhost:8089/api/v1/orchestrate \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"input": "Hello"}'
```

See `docs/http-api.md` for the complete API reference.

## Configuration Reference

All configuration lives in `~/.osa/config.json`. Here is a minimal config:

```json
{
  "provider": "ollama",
  "machines": {
    "communication": false,
    "productivity": false,
    "research": true
  }
}
```

And a fully-loaded config: see `examples/config.json`.

## What's Next

- **Add more skills** — See `docs/skills-guide.md` for the full SKILL.md reference
- **Set up periodic tasks** — See `examples/HEARTBEAT.md` for practical examples
- **Connect an SDK** — See `docs/http-api.md` for the full API reference
- **Understand the architecture** — See `docs/architecture.md` for how it all fits together
- **See real-world use cases** — See `docs/use-cases.md` for practical business applications

## Troubleshooting

### Ollama Connection Refused

```
** (Req.TransportError) connection refused
```

Ollama is not running. Start it:

```bash
ollama serve
```

### No Model Found

```
Error: model "llama3.2:latest" not found
```

Pull the model first:

```bash
ollama pull llama3.2:latest
```

### Signal Filtered (HTTP 422)

```json
{"error": "signal_filtered", "code": "SIGNAL_BELOW_THRESHOLD"}
```

Your message was classified as noise (weight below threshold). This is working as intended. Send a more substantive message, or lower the threshold in config:

```elixir
# config/config.exs
config :optimal_system_agent, noise_filter_threshold: 0.3
```

### Database Error

```bash
mix ecto.reset    # Drops and recreates the database
```

### Port 8089 Already in Use

```bash
# Find what's using it
lsof -i :8089

# Or change the port
# In config/config.exs:
config :optimal_system_agent, http_port: 9090
```
