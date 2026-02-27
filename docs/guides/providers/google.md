# Google (Gemini)

> Tier: Elite (Gemini 2.5 Pro) / Specialist (Gemini 2.0 Flash)

## Setup

```bash
GOOGLE_API_KEY="AIza..."
```

Get a key at [aistudio.google.com](https://aistudio.google.com).

## Models

| Model | Tier | Context | Best For |
|-------|------|---------|----------|
| `gemini-2.5-pro` | Elite | 1M | Long context analysis, massive codebases |
| `gemini-2.0-flash` | Specialist | 1M | Fast inference with large context |

## Why Use Gemini

- **1M token context window** — largest in the industry
- Ideal for analyzing entire codebases in a single pass
- Competitive pricing
- Strong multimodal (code + images)

## Switching

```
/model google
/model google gemini-2.5-pro
```
