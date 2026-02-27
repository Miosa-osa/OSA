# Cohere

> Enterprise-grade RAG and retrieval capabilities

## Setup

```bash
COHERE_API_KEY="..."
```

Get a key at [dashboard.cohere.com](https://dashboard.cohere.com).

## Models

| Model | Context | Best For |
|-------|---------|----------|
| `command-r-plus` | 128K | Complex tasks, RAG |
| `command-r` | 128K | General purpose |
| `command-light` | 4K | Quick classification |

## Why Use Cohere

- **Best-in-class RAG** — Command R+ designed for retrieval-augmented generation
- Strong document understanding
- Enterprise features (data privacy, compliance)
- Good multilingual support

## Switching

```
/model cohere
/model cohere command-r-plus
```

## Configuration

```elixir
config :optimal_system_agent, :cohere,
  api_key: System.get_env("COHERE_API_KEY"),
  model: "command-r-plus",
  url: "https://api.cohere.ai/v1"
```
