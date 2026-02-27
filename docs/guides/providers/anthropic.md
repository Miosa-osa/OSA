# Anthropic (Claude)

> Tier: Elite (Opus) / Specialist (Sonnet) / Utility (Haiku)

## Setup

```bash
# Add to ~/.osa/.env
ANTHROPIC_API_KEY="sk-ant-api03-..."
```

OSA auto-detects Anthropic as priority 1 when key is present.

## Models

| Model | Tier | Context | Best For |
|-------|------|---------|----------|
| `claude-opus-4-6` | Elite | 200K | Complex orchestration, architecture decisions |
| `claude-sonnet-4-6` | Specialist | 200K | Implementation, analysis, coding (default) |
| `claude-haiku-4-5` | Utility | 200K | Classification, quick tasks, noise filtering |

## Switching

```
/model anthropic                    # Use default (Sonnet)
/model anthropic claude-opus-4-6    # Use Opus
/model anthropic claude-haiku-4-5   # Use Haiku
```

## Pricing (approx)

| Model | Input (per 1M tokens) | Output (per 1M tokens) |
|-------|----------------------|------------------------|
| Opus | $15.00 | $75.00 |
| Sonnet | $3.00 | $15.00 |
| Haiku | $0.25 | $1.25 |

## Features

- Full tool use support (all models)
- Streaming responses
- Extended thinking (Opus, Sonnet)
- 200K context window across all tiers
- Vision/image input support

## Configuration

```elixir
# config.exs defaults
config :optimal_system_agent, :anthropic,
  api_key: System.get_env("ANTHROPIC_API_KEY"),
  model: "claude-sonnet-4-6",
  url: "https://api.anthropic.com"
```

## Troubleshooting

| Issue | Fix |
|-------|-----|
| 401 Unauthorized | Check API key is valid and has credits |
| 429 Rate Limited | Reduce concurrent agents or add delay |
| 529 Overloaded | Wait and retry, or switch to different provider |
