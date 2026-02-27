# Replicate

> Run any model on-demand, pay per second

## Setup

```bash
REPLICATE_API_KEY="r8_..."
```

Get a key at [replicate.com](https://replicate.com).

## Models

Any model on Replicate's platform. Common choices:

| Model | Best For |
|-------|----------|
| `meta/llama-3.3-70b-instruct` | General purpose |
| `meta/llama-3.1-8b-instruct` | Quick tasks |

## Why Use Replicate

- **Run any model** — largest model marketplace
- Pay-per-second billing (no idle costs)
- GPU auto-scaling
- Custom model deployment support

## Switching

```
/model replicate
```

## Configuration

```elixir
config :optimal_system_agent, :replicate,
  api_key: System.get_env("REPLICATE_API_KEY"),
  model: "meta/llama-3.3-70b-instruct"
```
