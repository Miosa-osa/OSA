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

## Ollama Cloud models

Tags ending in `:cloud` (`glm-5.2:cloud`) or `-cloud` (`gpt-oss:120b-cloud`,
`gemma4:31b-cloud`) run on Ollama's hosted hardware — no local GPU, no
download. They work with an `OLLAMA_API_KEY` **or** through a signed-in local
daemon, which proxies them by device identity. Some tags additionally require a
paid Ollama plan; OSA notes that in the picker.

### Adding a new Ollama Cloud model

There is **one** place to edit:
`lib/optimal_system_agent/providers/ollama_cloud.ex`.

Everything else derives from its `@models` list — the onboarding/model picker
(TUI `/model` dialog, `osa setup`, `mix osa.setup.wizard`), the Registry's
static context-window table, the pricing table, and the Ollama tool/thinking
gating. Cloud-tag detection is suffix-based and needs no per-model entry.

1. **Probe the real numbers.** Never copy them from a model card:

   ```bash
   curl -s http://localhost:11434/api/show -d '{"name":"kimi-k3:cloud"}'
   ```

   - `model_info["<arch>.context_length"]` → `:ctx`
   - `capabilities` → `:tools` / `:thinking` / `:vision` / `:audio`
     (`completion` is noise and is ignored)

   If the daemon is down or not signed in, fall back to the vendor's published
   numbers and set `ctx_source: :docs` instead of `:probe`.

2. **Add one entry to `@models`**, in display order (flagship first).

3. **Pricing** — only when the vendor publishes `{input, output}` USD per 1M
   tokens. Leave it `nil` rather than guessing: an unpriced model accounts at
   $0.00 *and logs*, which is honest; a guessed price is silently wrong.

4. **`:requires_subscription`** — set it when the tag needs a paid Ollama plan
   (e.g. `"Ollama Pro or Max"`). It is prefixed onto the picker note, so a
   free-plan user sees the requirement before selecting the model instead of
   hitting an opaque API failure.

5. **`:recommended`** is the flag paired with the provider's `default_model` in
   `Onboarding.providers_list/0`. Only one model carries it, and it must never
   be a model that requires a paid plan.

6. Run `mix compile` and `mix test test/providers`.

> **The `:ctx` value is a fallback, not the truth.** At runtime,
> `Registry.context_window/1` probes `/api/show` **first** for cloud tags and
> only falls back to this table when the probe fails (daemon down, offline, not
> signed in). A slightly stale `:ctx` therefore degrades gracefully instead of
> overriding reality — but it *is* what a fresh install budgets against before
> the first successful probe, so keep it honest.

Making a model a **tier default** (`elite` / `specialist` / `utility` for
sub-agents) is a separate editorial decision and still lives in
`lib/optimal_system_agent/agent/tier.ex`.

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
