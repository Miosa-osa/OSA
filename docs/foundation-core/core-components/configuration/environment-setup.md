# Environment Setup

## Audience

Developers and operators setting up OSA for the first time or moving between dev, test, and production deployments.

## Environment Detection

OSA uses the standard Mix environment variable `MIX_ENV` (default: `dev`). There is no `OSA_ENV` variable. The value of `MIX_ENV` is not checked at runtime beyond determining which `config/<env>.exs` file is overlaid during build.

```bash
# Development (default)
mix run --no-halt

# Test
MIX_ENV=test mix test

# Production
MIX_ENV=prod mix run --no-halt
# or via release:
MIX_ENV=prod mix release
```

## Environment Variables Reference

### Required for Cloud Providers

Set at least one of these or ensure Ollama is running locally:

| Variable | Provider | Notes |
|----------|----------|-------|
| `ANTHROPIC_API_KEY` | Anthropic | Auto-selects Anthropic as default provider when set |
| `OPENAI_API_KEY` | OpenAI | Auto-selects OpenAI if no Anthropic key |
| `GROQ_API_KEY` | Groq | |
| `OPENROUTER_API_KEY` | OpenRouter | |
| `GOOGLE_API_KEY` | Google Gemini | |
| `DEEPSEEK_API_KEY` | DeepSeek | |
| `MISTRAL_API_KEY` | Mistral | |
| `TOGETHER_API_KEY` | Together AI | |
| `FIREWORKS_API_KEY` | Fireworks | |
| `PERPLEXITY_API_KEY` | Perplexity | |
| `COHERE_API_KEY` | Cohere | |
| `XAI_API_KEY` | xAI Grok | |
| `CEREBRAS_API_KEY` | Cerebras | |
| `SAMBANOVA_API_KEY` | SambaNova | |
| `HYPERBOLIC_API_KEY` | Hyperbolic | |

### Provider Selection

| Variable | Default | Description |
|----------|---------|-------------|
| `OSA_DEFAULT_PROVIDER` | auto-detected | One of: `ollama`, `anthropic`, `openai`, `groq`, `openrouter`, `together`, `fireworks`, `deepseek`, `mistral`, `cerebras`, `google`, `cohere`, `perplexity`, `xai`, `sambanova`, `hyperbolic`, `lmstudio`, `llamacpp` |
| `OSA_MODEL` | provider default | Override model for the active provider (e.g. `claude-opus-4-5`) |
| `OLLAMA_URL` | `http://localhost:11434` | Ollama endpoint URL |
| `OLLAMA_MODEL` | `qwen2.5:7b` | Ollama model name |
| `OLLAMA_API_KEY` | none | Required for cloud-hosted Ollama instances |
| `OLLAMA_THINK` | auto | `true` / `false` to force extended reasoning mode |
| `OSA_FALLBACK_CHAIN` | auto-built | Comma-separated provider list: `anthropic,openai,ollama` |

Per-provider model overrides: `ANTHROPIC_MODEL`, `OPENAI_MODEL`, `GROQ_MODEL`, `OPENROUTER_MODEL`, `GOOGLE_MODEL`, `DEEPSEEK_MODEL`, `MISTRAL_MODEL`, `TOGETHER_MODEL`, `FIREWORKS_MODEL`, `COHERE_MODEL`, `XAI_MODEL`, `CEREBRAS_MODEL`, `LMSTUDIO_MODEL`, `LLAMACPP_MODEL`.

### HTTP and Auth

| Variable | Default | Description |
|----------|---------|-------------|
| `OSA_HTTP_PORT` | `9089` | HTTP server port |
| `OSA_REQUIRE_AUTH` | `false` | Require JWT on all API routes when `true` |
| `OSA_SHARED_SECRET` | none | JWT signing secret; required when `OSA_REQUIRE_AUTH=true` |

### Budget

| Variable | Default | Description |
|----------|---------|-------------|
| `OSA_DAILY_BUDGET_USD` | `50.0` | Maximum daily API spend |
| `OSA_MONTHLY_BUDGET_USD` | `500.0` | Maximum monthly API spend |
| `OSA_PER_CALL_LIMIT_USD` | `5.0` | Maximum cost per LLM call |

### Agent Behavior

| Variable | Default | Description |
|----------|---------|-------------|
| `OSA_PLAN_MODE` | `false` | When `true`, agent makes a single LLM call with no tool calls |
| `OSA_THINKING_ENABLED` | `false` | Enable extended thinking for supported models |
| `OSA_THINKING_BUDGET` | `5000` | Token budget for thinking blocks |
| `OSA_WORKING_DIR` | none | Default working directory for file operations (e.g. `~/Desktop/MyProject`) |
| `OSA_QUIET_HOURS` | none | Suppress heartbeat during hours (format: `"22:00-08:00"`) |

### Channels

| Variable | Description |
|----------|-------------|
| `TELEGRAM_BOT_TOKEN` | Telegram bot token (enables Telegram channel) |
| `DISCORD_BOT_TOKEN` | Discord bot token |
| `SLACK_BOT_TOKEN` | Slack bot token |
| `BRAVE_API_KEY` | Brave Search API key (enables web search tool) |

### Platform (Multi-Tenant, Optional)

| Variable | Description |
|----------|-------------|
| `DATABASE_URL` | PostgreSQL URL; when set, enables Platform.Repo and multi-tenant features |
| `POOL_SIZE` | PostgreSQL connection pool size (default `10`) |
| `JWT_SECRET` | Shared JWT signing key with Go backend |
| `AMQP_URL` | RabbitMQ URL; when set, enables AMQP event publisher |

### Optional Sidecars

| Variable | Default | Description |
|----------|---------|-------------|
| `OSA_PYTHON_SIDECAR` | `false` | Enable Python sidecar for semantic memory search |
| `OSA_PYTHON_PATH` | `python3` | Path to Python binary |
| `OSA_GO_TOKENIZER` | `false` | Enable Go sidecar for accurate BPE token counting |
| `OSA_SANDBOX_ENABLED` | `false` | Enable Docker sandbox for skill execution |

### Optional Extensions

| Variable | Default | Description |
|----------|---------|-------------|
| `OSA_TREASURY_ENABLED` | `false` | Enable financial governance with transaction ledger |
| `OSA_FLEET_ENABLED` | `false` | Enable remote agent fleet registry |
| `OSA_WALLET_ENABLED` | `false` | Enable crypto wallet integration |
| `OSA_UPDATE_ENABLED` | `false` | Enable OTA updater |

## .env File Location

Place `.env` at the project root or at `~/.osa/.env`. Project root takes priority. Format:

```bash
ANTHROPIC_API_KEY=sk-ant-...
OSA_DEFAULT_PROVIDER=anthropic
OSA_HTTP_PORT=9089
OSA_WORKING_DIR=~/Desktop/MyProject
```

Comments (`# ...`) and blank lines are ignored. Values are stripped of surrounding quotes.

## Local Development Setup

```bash
# 1. Clone and install dependencies
git clone <repo> && cd OSA
mix deps.get

# 2. Set API key (or start Ollama locally)
echo "ANTHROPIC_API_KEY=sk-ant-..." > .env

# 3. Create the SQLite database
mix ecto.create && mix ecto.migrate

# 4. Start OSA
mix run --no-halt
# or for interactive shell:
iex -S mix
```

## Docker vs Local Config

When running via Docker (`docker-compose.yml`), environment variables are passed via the `environment:` section or an `env_file:`. The `.env` file loading in `runtime.exs` still applies inside the container if the file is volume-mounted.

Key differences:

- `OLLAMA_URL` should point to the host or a sibling container (e.g. `http://ollama:11434`) rather than `localhost`
- `OSA_WORKING_DIR` must use a path that exists inside the container (typically a mounted volume)
- `DATABASE_URL` uses the Docker network hostname of the PostgreSQL container

The `Dockerfile` sets `MIX_ENV=prod` and runs `mix release`. The release binary reads runtime config from `rel/env.sh.eex` if present, and from the environment at startup.
