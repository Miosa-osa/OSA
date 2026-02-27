# Together AI

> Open model hosting with competitive pricing

## Setup

```bash
TOGETHER_API_KEY="..."
```

Get a key at [together.ai](https://together.ai).

## Models

| Model | Context | Best For |
|-------|---------|----------|
| `meta-llama/Llama-3.3-70B-Instruct-Turbo` | 128K | General purpose |
| `meta-llama/Llama-3.1-8B-Instruct-Turbo` | 128K | Quick tasks |
| `codellama/CodeLlama-34b-Instruct-hf` | 16K | Code generation |
| `mistralai/Mixtral-8x7B-Instruct-v0.1` | 32K | Balanced performance |

## Why Use Together

- Wide selection of open models (Llama, CodeLlama, Mistral, etc.)
- Competitive pay-per-token pricing
- Good for experimenting with different open models
- Serverless and dedicated endpoints available

## Switching

```
/model together
/model together meta-llama/Llama-3.3-70B-Instruct-Turbo
```

## Configuration

```elixir
config :optimal_system_agent, :together,
  api_key: System.get_env("TOGETHER_API_KEY"),
  model: "meta-llama/Llama-3.3-70B-Instruct-Turbo",
  url: "https://api.together.xyz/v1"
```
