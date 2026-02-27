# Provider Guides

> Setup and configuration for each of OSA's 18 LLM providers

## Auto-Detection Priority

```
1. OSA_DEFAULT_PROVIDER=<name>   → Explicit override
2. ANTHROPIC_API_KEY present     → Anthropic
3. OPENAI_API_KEY present        → OpenAI
4. GROQ_API_KEY present          → Groq
5. OPENROUTER_API_KEY present    → OpenRouter
6. Fallback                      → Ollama (local)
```

## Frontier Providers

| Provider | Guide | Key Env Var | Default Model |
|----------|-------|-------------|---------------|
| Anthropic (Claude) | [anthropic.md](anthropic.md) | `ANTHROPIC_API_KEY` | claude-sonnet-4-6 |
| OpenAI | [openai.md](openai.md) | `OPENAI_API_KEY` | gpt-4o |
| Google (Gemini) | [google.md](google.md) | `GOOGLE_API_KEY` | gemini-2.5-pro |

## Fast Inference

| Provider | Guide | Key Env Var | Default Model |
|----------|-------|-------------|---------------|
| Groq (LPU) | [groq.md](groq.md) | `GROQ_API_KEY` | llama-3.3-70b-versatile |
| Fireworks | [fireworks.md](fireworks.md) | `FIREWORKS_API_KEY` | llama-v3p3-70b |
| Together AI | [together.md](together.md) | `TOGETHER_API_KEY` | Llama-3.3-70B |
| DeepSeek | [deepseek.md](deepseek.md) | `DEEPSEEK_API_KEY` | deepseek-chat |

## Aggregators

| Provider | Guide | Key Env Var | Default Model |
|----------|-------|-------------|---------------|
| OpenRouter | [openrouter.md](openrouter.md) | `OPENROUTER_API_KEY` | llama-3.3-70b |
| Perplexity | [perplexity.md](perplexity.md) | `PERPLEXITY_API_KEY` | sonar |

## Local

| Provider | Guide | Key Env Var | Default Model |
|----------|-------|-------------|---------------|
| Ollama | [ollama.md](ollama.md) | None (local) | Auto-detected |

## Specialty

| Provider | Guide | Key Env Var |
|----------|-------|-------------|
| Mistral | [mistral.md](mistral.md) | `MISTRAL_API_KEY` |
| Cohere | [cohere.md](cohere.md) | `COHERE_API_KEY` |
| Replicate | [replicate.md](replicate.md) | `REPLICATE_API_KEY` |

## Chinese Regional

| Provider | Guide | Key Env Var |
|----------|-------|-------------|
| Qwen, Zhipu, Moonshot, VolcEngine, Baichuan | [chinese.md](chinese.md) | Various |

## Runtime Switching

```
/model                          # Show current provider and model
/model anthropic                # Switch to Anthropic
/model anthropic claude-opus-4-6  # Switch to specific model
/models                         # List all available
```
