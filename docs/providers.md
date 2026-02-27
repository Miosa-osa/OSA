# Provider Integration Guide

> How to set up and use each of OSA's 18 LLM providers

## Overview

OSA supports 18 LLM providers out of the box. Each provider implements the `OptimalSystemAgent.Providers.Behaviour` callback with `chat/2`, `chat_stream/3`, `name/0`, and `default_model/0`.

All providers accept a `:model` option to override the default model per request. The tier system (elite/specialist/utility) maps to models automatically.

## Quick Setup

```bash
# Set your API key in ~/.osa/.env
echo 'ANTHROPIC_API_KEY=sk-ant-...' >> ~/.osa/.env

# OSA auto-detects the provider on next start
osagent
# → "Using provider: anthropic (claude-sonnet-4-6)"
```

## Provider Auto-Detection Priority

```
1. OSA_DEFAULT_PROVIDER=<name>   # Explicit override
2. ANTHROPIC_API_KEY present     # → :anthropic
3. OPENAI_API_KEY present        # → :openai
4. GROQ_API_KEY present          # → :groq
5. OPENROUTER_API_KEY present    # → :openrouter
6. Fallback                      # → :ollama (local)
```

Override: `OSA_DEFAULT_PROVIDER=groq` forces Groq even if Anthropic key exists.

## Tier Mapping

| Tier | Purpose | Anthropic | OpenAI | Google | Ollama |
|------|---------|-----------|--------|--------|--------|
| **Elite** | Orchestration, architecture | Claude Opus | GPT-4o | Gemini 2.5 Pro | Largest model |
| **Specialist** | Implementation, analysis | Claude Sonnet | GPT-4o-mini | Gemini 2.0 Flash | Mid-range model |
| **Utility** | Quick tasks, classification | Claude Haiku | GPT-3.5-turbo | — | Smallest model |

---

## Frontier Providers

### Anthropic (Claude)

```bash
ANTHROPIC_API_KEY="sk-ant-api03-..."
```

| Model | Tier | Context | Best For |
|-------|------|---------|----------|
| claude-opus-4-6 | Elite | 200K | Complex architecture, orchestration |
| claude-sonnet-4-6 | Specialist | 200K | Implementation, analysis (default) |
| claude-haiku-4-5 | Utility | 200K | Classification, quick tasks |

Switch: `/model anthropic claude-opus-4-6`

### OpenAI

```bash
OPENAI_API_KEY="sk-proj-..."
```

| Model | Tier | Context | Best For |
|-------|------|---------|----------|
| gpt-4o | Elite | 128K | Complex reasoning (default) |
| gpt-4o-mini | Specialist | 128K | General coding |
| gpt-3.5-turbo | Utility | 16K | Quick tasks |

### Google (Gemini)

```bash
GOOGLE_API_KEY="AIza..."
```

| Model | Tier | Context | Best For |
|-------|------|---------|----------|
| gemini-2.5-pro | Elite | 1M | Long context analysis |
| gemini-2.0-flash | Specialist | 1M | Fast inference |

---

## Fast Inference Providers

### Groq (LPU)

```bash
GROQ_API_KEY="gsk_..."
```

Extremely fast inference via custom LPU hardware. Best for high-throughput, latency-sensitive tasks.

| Model | Speed | Best For |
|-------|-------|----------|
| llama-3.3-70b-versatile | ~500 tok/s | General purpose |
| llama-3.1-8b-instant | ~1000 tok/s | Quick tasks |
| mixtral-8x7b-32768 | ~500 tok/s | Long context |

### Fireworks

```bash
FIREWORKS_API_KEY="fw_..."
```

Optimized open model serving. Good balance of speed and quality.

### Together AI

```bash
TOGETHER_API_KEY="..."
```

Open model hosting with competitive pricing. Supports Llama, CodeLlama, Mistral.

### DeepSeek

```bash
DEEPSEEK_API_KEY="..."
```

Strong reasoning models at low cost. DeepSeek R1 excels at math and coding.

---

## Aggregator Providers

### OpenRouter

```bash
OPENROUTER_API_KEY="sk-or-v1-..."
```

Meta-provider routing to 100+ models via single API key. Useful for model experimentation.

Default model: `meta-llama/llama-3.3-70b-instruct`

### Perplexity

```bash
PERPLEXITY_API_KEY="pplx-..."
```

Search-augmented generation. Sonar models include real-time web search in responses.

---

## Local Providers

### Ollama

```bash
# No API key needed — runs locally
OLLAMA_URL="http://localhost:11434"  # Default
OLLAMA_MODEL="llama3.2:latest"      # Default
```

**Setup:**
```bash
# Install Ollama
curl -fsSL https://ollama.ai/install.sh | sh

# Pull a model
ollama pull llama3.2:latest

# OSA auto-detects Ollama if no cloud keys are set
osagent
```

**Tool Gating**: Only models >= 7GB with known tool-capable prefixes receive tool definitions. Small models get NO tools to prevent hallucinated tool calls.

**Auto-Detection**: At boot, OSA queries `ollama list` and selects the largest tool-capable model.

---

## Chinese Regional Providers

### Qwen (Alibaba Cloud)

```bash
QWEN_API_KEY="sk-..."
```

Alibaba's Qwen 2.5 series. Strong multilingual (Chinese/English) performance.

### Zhipu (GLM)

```bash
ZHIPU_API_KEY="..."
```

Zhipu's GLM-4 series. Competitive Chinese-language reasoning.

### Moonshot

```bash
MOONSHOT_API_KEY="..."
```

Moonshot AI's Kimi models. 200K context window.

### VolcEngine (Doubao)

```bash
VOLCENGINE_API_KEY="..."
```

ByteDance's Doubao models via Volcano Engine.

### Baichuan

```bash
BAICHUAN_API_KEY="..."
```

Baichuan Intelligence models. Strong Chinese NLP.

---

## Other Providers

### Mistral

```bash
MISTRAL_API_KEY="..."
```

European AI lab. Mistral Large for complex tasks, Mistral Medium for general use.

### Cohere

```bash
COHERE_API_KEY="..."
```

Command R+ model. Strong RAG and retrieval capabilities.

### Replicate

```bash
REPLICATE_API_KEY="r8_..."
```

Run any model on Replicate's infrastructure. Pay per second.

---

## Switching Providers at Runtime

```
/model                          # Show current provider and model
/model anthropic                # Switch to Anthropic (default model)
/model anthropic claude-opus-4-6  # Switch to specific model
/model ollama llama3.2:latest   # Switch to local Ollama
/models                         # List all available models
/provider                       # Show provider details
```

## Fallback Chains

Configure in `~/.osa/config.json`:
```json
{
  "providers": {
    "fallback_chain": ["anthropic", "openai", "ollama"]
  }
}
```

If the primary provider fails, OSA automatically tries the next in the chain.

## Adding Custom Providers

Any OpenAI-compatible API works via `OptimalSystemAgent.Providers.OpenAICompat`:

```elixir
config :optimal_system_agent, :custom_provider,
  url: "https://my-api.com/v1",
  api_key: "my-key",
  model: "my-model"
```
