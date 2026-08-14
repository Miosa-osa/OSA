# Environment Configuration

All environment variables are read in `config/runtime.exs` at node startup.
Values set in the shell environment take precedence over `~/.osa/.env`.

## Provider Selection

| Variable | Default | Description |
|----------|---------|-------------|
| `OSA_DEFAULT_PROVIDER` | auto-detected | Primary LLM provider. Valid values: `ollama`, `anthropic`, `openai`, `groq`, `openrouter`, `together`, `fireworks`, `deepseek`, `mistral`, `cerebras`, `google`, `cohere`, `perplexity`, `xai`, `sambanova`, `hyperbolic`, `lmstudio`, `llamacpp` |
| `OSA_MODEL` | provider default | Override the model for the active provider |
| `OSA_FALLBACK_CHAIN` | auto-detected | Comma-separated provider fallback order, e.g. `anthropic,openai,ollama` |

## LLM Provider API Keys

| Variable | Provider |
|----------|----------|
| `ANTHROPIC_API_KEY` | Anthropic (Claude) |
| `OPENAI_API_KEY` | OpenAI (GPT) |
| `GROQ_API_KEY` | Groq |
| `OPENROUTER_API_KEY` | OpenRouter |
| `GOOGLE_API_KEY` | Google (Gemini) |
| `DEEPSEEK_API_KEY` | DeepSeek |
| `MISTRAL_API_KEY` | Mistral |
| `TOGETHER_API_KEY` | Together AI |
| `FIREWORKS_API_KEY` | Fireworks AI |
| `REPLICATE_API_KEY` | Replicate |
| `PERPLEXITY_API_KEY` | Perplexity |
| `COHERE_API_KEY` | Cohere |
| `QWEN_API_KEY` | Qwen |
| `ZHIPU_API_KEY` | Zhipu AI |
| `MOONSHOT_API_KEY` | Moonshot |
| `VOLCENGINE_API_KEY` | VolcEngine |
| `BAICHUAN_API_KEY` | Baichuan |
| `XAI_API_KEY` | xAI (Grok) |
| `CEREBRAS_API_KEY` | Cerebras |
| `SAMBANOVA_API_KEY` | SambaNova |
| `HYPERBOLIC_API_KEY` | Hyperbolic |
| `LMSTUDIO_API_KEY` | LM Studio |
| `LLAMACPP_API_KEY` | llama.cpp |

## Per-Provider Model Overrides

Each provider supports a model override via an environment variable. These take
precedence over `OSA_MODEL` for their specific provider.

| Variable | Provider |
|----------|----------|
| `ANTHROPIC_MODEL` | Anthropic |
| `OPENAI_MODEL` | OpenAI |
| `OLLAMA_MODEL` | Ollama (default: `qwen2.5:7b`) |
| `GROQ_MODEL` | Groq |
| `OPENROUTER_MODEL` | OpenRouter |
| `GOOGLE_MODEL` | Google |
| `DEEPSEEK_MODEL` | DeepSeek |
| `MISTRAL_MODEL` | Mistral |
| `TOGETHER_MODEL` | Together AI |
| `FIREWORKS_MODEL` | Fireworks AI |
| `REPLICATE_MODEL` | Replicate |
| `PERPLEXITY_MODEL` | Perplexity |
| `COHERE_MODEL` | Cohere |
| `XAI_MODEL` | xAI |
| `CEREBRAS_MODEL` | Cerebras |
| `SAMBANOVA_MODEL` | SambaNova |
| `HYPERBOLIC_MODEL` | Hyperbolic |
| `LMSTUDIO_MODEL` | LM Studio |
| `LLAMACPP_MODEL` | llama.cpp |

## Ollama-Specific Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `OLLAMA_URL` | `http://localhost:11434` | Ollama API base URL; override for cloud Ollama instances |
| `OLLAMA_API_KEY` | — | Required for authenticated cloud Ollama instances |
| `OLLAMA_TOOLS` | — | `true` / `false` to force tool schemas to be sent or withheld for all Ollama models. Omit for the default: sent unless the daemon or catalog says the model cannot call tools, or it is an embedding model or too small to hold the schemas |
| `OLLAMA_THINK` | — | `true` / `false` to force extended reasoning on or off for all Ollama models. Omit for the serving-mode default: on for cloud tags (`:cloud` / `-cloud`), off for locally served reasoning models (stall guard) |

## HTTP Server

| Variable | Default | Description |
|----------|---------|-------------|
| `OSA_HTTP_PORT` | `9089` | Port for the Bandit HTTP server |
| `OSA_REQUIRE_AUTH` | `false` | Require `Authorization: Bearer <secret>` on all HTTP endpoints |
| `OSA_SHARED_SECRET` | — | Bearer token value. Required when `OSA_REQUIRE_AUTH=true` |

## Budget Limits

| Variable | Default | Description |
|----------|---------|-------------|
| `OSA_DAILY_BUDGET_USD` | `50.0` | Maximum USD spend per calendar day |
| `OSA_MONTHLY_BUDGET_USD` | `500.0` | Maximum USD spend per calendar month |
| `OSA_PER_CALL_LIMIT_USD` | `5.0` | Maximum USD spend per LLM call |

## Feature Flags

| Variable | Default | Description |
|----------|---------|-------------|
| `OSA_SANDBOX_ENABLED` | `false` | Enable Docker/WASM sandbox for tool execution isolation |
| `OSA_PYTHON_SIDECAR` | `false` | Enable Python sidecar for semantic embedding-based memory search |
| `OSA_GO_TOKENIZER` | `false` | Enable Go BPE tokenizer binary for accurate token counting |
| `OSA_TREASURY_ENABLED` | `false` | Enable Treasury financial governance with transaction ledger |
| `OSA_FLEET_ENABLED` | `false` | Enable Fleet remote agent registry with sentinel monitoring |
| `OSA_WALLET_ENABLED` | `false` | Enable crypto wallet connectivity |
| `OSA_UPDATE_ENABLED` | `false` | Enable OTA updater with TUF verification |
| `OSA_PLAN_MODE` | `false` | Start sessions in plan mode (single LLM call, no tool iterations) |
| `OSA_THINKING_ENABLED` | `true` | Extended thinking on Anthropic. Set to `false` to disable; any other value (including unset) leaves it on |

## Treasury Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `OSA_TREASURY_ENABLED` | `false` | Enable Treasury subsystem |
| `OSA_TREASURY_AUTO_DEBIT` | `true` | Auto-debit approved transactions |
| `OSA_TREASURY_DAILY_LIMIT` | `250.0` | Treasury daily spend cap (USD) |
| `OSA_TREASURY_MAX_SINGLE` | `50.0` | Maximum single transaction amount (USD) |

## Agent Behavior

| Variable | Default | Description |
|----------|---------|-------------|
| `OSA_WORKING_DIR` | — | Default working directory for the agent (e.g. `~/Desktop/myproject`) |
| `OSA_QUIET_HOURS` | — | Heartbeat suppression window, e.g. `22:00-08:00` |
| `OSA_THINKING_BUDGET` | `5000` | Token budget for extended thinking (when enabled) |

## Platform Mode (Multi-Tenant)

| Variable | Description |
|----------|-------------|
| `DATABASE_URL` | PostgreSQL connection URL. Setting this enables `Platform.Repo` and platform multi-tenant features |
| `POOL_SIZE` | PostgreSQL connection pool size (default: `10`) |
| `AMQP_URL` | RabbitMQ connection URL for event publishing to Go workers |
| `JWT_SECRET` | JWT signing key shared with the Go backend |

## Sidecar Paths

| Variable | Default | Description |
|----------|---------|-------------|
| `OSA_PYTHON_PATH` | `python3` | Path to the Python executable used by the sidecar |

## Channel Tokens

| Variable | Description |
|----------|-------------|
| `TELEGRAM_BOT_TOKEN` | Telegram bot token |
| `DISCORD_BOT_TOKEN` | Discord bot token |
| `SLACK_BOT_TOKEN` | Slack bot token |

## Wallet Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `OSA_WALLET_PROVIDER` | `mock` | Wallet backend: `mock` or implementation name |
| `OSA_WALLET_ADDRESS` | — | Wallet public address |
| `OSA_WALLET_RPC_URL` | — | Blockchain RPC endpoint |

## Sprites.dev Sandbox

| Variable | Default | Description |
|----------|---------|-------------|
| `SPRITES_TOKEN` | — | API token for Sprites.dev remote sandbox |
| `SPRITES_API_URL` | `https://api.sprites.dev` | Sprites.dev API base URL |

## OTA Updater

| Variable | Default | Description |
|----------|---------|-------------|
| `OSA_UPDATE_URL` | — | TUF update server URL |
| `OSA_UPDATE_INTERVAL` | `86400000` | Check interval in milliseconds (default: 24 hours) |

## Web Search

| Variable | Description |
|----------|-------------|
| `BRAVE_API_KEY` | Brave Search API key for web search tool |

## Webhook Signature Secrets

These are set in `config.exs` and can be overridden:

| Config key | Description |
|------------|-------------|
| `telegram_webhook_secret` | Telegram webhook signature verification |
| `whatsapp_app_secret` | WhatsApp webhook HMAC secret |
| `dingtalk_secret` | DingTalk webhook signature secret |
| `email_webhook_secret` | Email webhook verification secret |

## Auto-Detection Logic

Provider auto-detection runs at startup in `runtime.exs`:

```elixir
default_provider =
  cond do
    env = System.get_env("OSA_DEFAULT_PROVIDER") ->
      Map.get(provider_map, env, :ollama)
    System.get_env("ANTHROPIC_API_KEY")  -> :anthropic
    System.get_env("OPENAI_API_KEY")     -> :openai
    System.get_env("GROQ_API_KEY")       -> :groq
    System.get_env("OPENROUTER_API_KEY") -> :openrouter
    true -> :ollama
  end
```

The first matching condition wins. Ollama is the final fallback because it
requires no API key and runs locally.
