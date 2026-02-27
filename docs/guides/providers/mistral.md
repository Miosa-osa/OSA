# Mistral

> European AI lab with strong open and proprietary models

## Setup

```bash
MISTRAL_API_KEY="..."
```

Get a key at [console.mistral.ai](https://console.mistral.ai).

## Models

| Model | Tier | Context | Best For |
|-------|------|---------|----------|
| `mistral-large-latest` | Elite | 128K | Complex reasoning |
| `mistral-medium-latest` | Specialist | 32K | General coding |
| `mistral-small-latest` | Utility | 32K | Quick tasks |
| `codestral-latest` | Specialist | 32K | Code generation |

## Why Use Mistral

- **European data sovereignty** — EU-hosted infrastructure
- Strong code model (Codestral)
- Competitive with frontier models at lower cost
- Good function calling support
- Open-weight models available (Mistral 7B, Mixtral via Ollama)

## Switching

```
/model mistral
/model mistral mistral-large-latest
/model mistral codestral-latest
```

## Configuration

```elixir
config :optimal_system_agent, :mistral,
  api_key: System.get_env("MISTRAL_API_KEY"),
  model: "mistral-large-latest",
  url: "https://api.mistral.ai/v1"
```
