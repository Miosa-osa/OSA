# Perplexity

> Search-augmented generation with real-time web access

## Setup

```bash
PERPLEXITY_API_KEY="pplx-..."
```

Get a key at [perplexity.ai](https://perplexity.ai).

## Models

| Model | Context | Best For |
|-------|---------|----------|
| `sonar-pro` | 200K | Deep research with citations |
| `sonar` | 128K | Quick web-augmented answers |

## Why Use Perplexity

- **Real-time web search** built into model responses
- Responses include citations and sources
- Ideal for research tasks requiring current information
- No separate search API needed

## Switching

```
/model perplexity
/model perplexity sonar-pro
```

## Configuration

```elixir
config :optimal_system_agent, :perplexity,
  api_key: System.get_env("PERPLEXITY_API_KEY"),
  model: "sonar",
  url: "https://api.perplexity.ai"
```
