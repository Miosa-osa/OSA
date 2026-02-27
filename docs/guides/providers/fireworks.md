# Fireworks AI

> Optimized open model serving with fast inference

## Setup

```bash
FIREWORKS_API_KEY="fw_..."
```

Get a key at [fireworks.ai](https://fireworks.ai).

## Models

| Model | Speed | Best For |
|-------|-------|----------|
| `accounts/fireworks/models/llama-v3p3-70b-instruct` | Fast | General purpose |
| `accounts/fireworks/models/mixtral-8x22b-instruct` | Fast | Complex tasks |
| `accounts/fireworks/models/firefunction-v2` | Fast | Function calling |

## Why Use Fireworks

- **Optimized inference** — custom serving stack for open models
- Good balance of speed and quality
- Competitive pricing
- Strong function calling support with FireFunction

## Switching

```
/model fireworks
```

## Configuration

```elixir
config :optimal_system_agent, :fireworks,
  api_key: System.get_env("FIREWORKS_API_KEY"),
  model: "accounts/fireworks/models/llama-v3p3-70b-instruct",
  url: "https://api.fireworks.ai/inference/v1"
```
