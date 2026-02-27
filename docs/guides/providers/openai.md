# OpenAI

> Tier: Elite (GPT-4o) / Specialist (GPT-4o-mini) / Utility (GPT-3.5-turbo)

## Setup

```bash
OPENAI_API_KEY="sk-proj-..."
```

Auto-detected as priority 2 (after Anthropic).

## Models

| Model | Tier | Context | Best For |
|-------|------|---------|----------|
| `gpt-4o` | Elite | 128K | Complex reasoning (default) |
| `gpt-4o-mini` | Specialist | 128K | General coding, analysis |
| `gpt-3.5-turbo` | Utility | 16K | Quick classification |

## Switching

```
/model openai                # Use default (GPT-4o)
/model openai gpt-4o-mini    # Use mini
```

## Configuration

```elixir
config :optimal_system_agent, :openai,
  api_key: System.get_env("OPENAI_API_KEY"),
  model: "gpt-4o",
  url: "https://api.openai.com/v1"
```
