# Groq (LPU Inference)

> Extremely fast inference via custom hardware

## Setup

```bash
GROQ_API_KEY="gsk_..."
```

Get a key at [console.groq.com](https://console.groq.com).

Auto-detected as priority 3 (after Anthropic, OpenAI).

## Models

| Model | Speed | Context | Best For |
|-------|-------|---------|----------|
| `llama-3.3-70b-versatile` | ~500 tok/s | 128K | General purpose |
| `llama-3.1-8b-instant` | ~1000 tok/s | 128K | Quick tasks |
| `mixtral-8x7b-32768` | ~500 tok/s | 32K | Long context |

## Why Use Groq

- **10-50x faster** than cloud inference for open models
- Best for high-throughput, latency-sensitive swarm workers
- Free tier available with rate limits
- Ideal utility tier provider

## Switching

```
/model groq
/model groq llama-3.3-70b-versatile
```
