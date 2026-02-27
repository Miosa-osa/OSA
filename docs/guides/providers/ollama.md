# Ollama (Local Models)

> Tier: Auto-detected by model size | No API key required

## Setup

```bash
# Install Ollama
curl -fsSL https://ollama.ai/install.sh | sh

# Pull a model
ollama pull llama3.2:latest

# Optional: configure endpoint
OLLAMA_URL="http://localhost:11434"    # Default
OLLAMA_MODEL="llama3.2:latest"        # Default
```

OSA falls back to Ollama when no cloud API keys are configured.

## Tool Gating

OSA only sends tool definitions to Ollama models that meet BOTH criteria:
1. Model size >= 7GB
2. Model matches known tool-capable prefix (llama3, qwen2, mistral, etc.)

Small models get NO tools — this prevents hallucinated tool calls.

## Auto-Detection

At boot, OSA queries `ollama list` and selects the **largest tool-capable model** automatically.

## Recommended Models

| Model | Size | Tool-Capable | Best For |
|-------|------|-------------|----------|
| `llama3.3:70b` | 40GB | Yes | Full agent capabilities |
| `llama3.2:latest` | 2GB | No (too small) | Chat only, no tools |
| `qwen2.5:32b` | 18GB | Yes | Good balance, multilingual |
| `codellama:34b` | 19GB | Yes | Code-focused tasks |
| `mistral:7b` | 4GB | Yes (borderline) | Light tasks |
| `deepseek-r1:14b` | 9GB | Yes | Reasoning tasks |

## Switching

```
/model ollama                      # Use auto-detected model
/model ollama llama3.3:70b         # Use specific model
/models                            # See all available
```

## Performance Tips

- Use quantized models (Q4_K_M) for speed vs full precision for quality
- Keep GPU memory in mind — larger models need more VRAM
- Ollama serves one request at a time by default; set `OLLAMA_NUM_PARALLEL` for concurrent
- For multi-agent swarms, consider a cloud provider for parallelism

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Connection refused | `ollama serve` — ensure Ollama is running |
| Model not found | `ollama pull <model>` to download it |
| Slow responses | Use a smaller/quantized model or add GPU |
| No tools working | Model too small (< 7GB) — use a larger model |
