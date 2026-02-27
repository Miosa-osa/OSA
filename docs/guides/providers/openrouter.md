# OpenRouter

> Meta-provider: 100+ models via single API key

## Setup

```bash
OPENROUTER_API_KEY="sk-or-v1-..."
```

Get a key at [openrouter.ai](https://openrouter.ai).

Auto-detected as priority 4 (after Anthropic, OpenAI, Groq).

## Why Use OpenRouter

- **Single API key** for 100+ models from every provider
- Great for experimentation and model comparison
- Pay-per-use, no provider-specific subscriptions
- Automatic fallback between providers

## Default Model

`meta-llama/llama-3.3-70b-instruct`

## Switching

```
/model openrouter
/model openrouter anthropic/claude-sonnet-4-6
/model openrouter meta-llama/llama-3.3-70b-instruct
```

## Configuration

```elixir
config :optimal_system_agent, :openrouter,
  api_key: System.get_env("OPENROUTER_API_KEY"),
  model: "meta-llama/llama-3.3-70b-instruct",
  url: "https://openrouter.ai/api/v1"
```
