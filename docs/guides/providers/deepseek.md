# DeepSeek

> Strong reasoning models at low cost

## Setup

```bash
DEEPSEEK_API_KEY="..."
```

Get a key at [platform.deepseek.com](https://platform.deepseek.com).

## Models

| Model | Tier | Context | Best For |
|-------|------|---------|----------|
| `deepseek-chat` | Specialist | 128K | General coding, analysis |
| `deepseek-reasoner` | Elite | 128K | Math, logic, complex reasoning |

## Why Use DeepSeek

- **DeepSeek R1** excels at math, logic, and chain-of-thought reasoning
- Very competitive pricing (often cheapest per token)
- Strong code generation
- Open-weight models available via Ollama

## Switching

```
/model deepseek
/model deepseek deepseek-reasoner
```

## Configuration

```elixir
config :optimal_system_agent, :deepseek,
  api_key: System.get_env("DEEPSEEK_API_KEY"),
  model: "deepseek-chat",
  url: "https://api.deepseek.com/v1"
```
