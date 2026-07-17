# Configuration Reference

Audience: operators configuring OSA for deployment.

Configuration has two layers:

1. **Compile-time defaults** in `config/config.exs` — set for all environments.
2. **Runtime overrides** in `config/runtime.exs` — read from environment variables and `.env` files at startup.

OSA loads `.env` files in order: project root `.env` first, then `~/.osa/.env`. Environment variables already set in the shell take priority over both files. The `.env` format is `KEY=value`, one per line; `#` starts a comment.

---

## Provider Selection

| Env Var | Type | Default | Description |
|---------|------|---------|-------------|
| `OSA_DEFAULT_PROVIDER` | string | auto-detected | Active LLM provider. One of: `ollama`, `anthropic`, `openai`, `groq`, `openrouter`, `together`, `fireworks`, `deepseek`, `mistral`, `cerebras`, `google`, `cohere`, `perplexity`, `xai`, `sambanova`, `hyperbolic`, `lmstudio`, `llamacpp`. If unset, the first provider with a configured API key wins; Ollama is used if reachable. |
| `OSA_MODEL` | string | provider default | Model name for the active provider. Overrides all per-provider model env vars. |
| `OSA_FALLBACK_CHAIN` | CSV string | auto-detected | Comma-separated provider list for failover, e.g. `anthropic,openai,ollama`. Auto-detection builds the chain from configured API keys plus Ollama if reachable. |

## API Keys

| Env Var | Provider |
|---------|----------|
| `ANTHROPIC_API_KEY` | Anthropic (Claude) |
| `OPENAI_API_KEY` | OpenAI |
| `GROQ_API_KEY` | Groq |
| `OPENROUTER_API_KEY` | OpenRouter |
| `GOOGLE_API_KEY` | Google Gemini |
| `DEEPSEEK_API_KEY` | DeepSeek |
| `MISTRAL_API_KEY` | Mistral |
| `TOGETHER_API_KEY` | Together AI |
| `FIREWORKS_API_KEY` | Fireworks AI |
| `REPLICATE_API_KEY` | Replicate |
| `PERPLEXITY_API_KEY` | Perplexity |
| `COHERE_API_KEY` | Cohere |
| `XAI_API_KEY` | xAI (Grok) |
| `CEREBRAS_API_KEY` | Cerebras |
| `SAMBANOVA_API_KEY` | SambaNova |
| `HYPERBOLIC_API_KEY` | Hyperbolic |
| `QWEN_API_KEY` | Qwen (Alibaba) |
| `ZHIPU_API_KEY` | Zhipu |
| `MOONSHOT_API_KEY` | Moonshot |
| `VOLCENGINE_API_KEY` | VolcEngine |
| `BAICHUAN_API_KEY` | Baichuan |
| `LMSTUDIO_API_KEY` | LM Studio |
| `LLAMACPP_API_KEY` | llama.cpp |

## Per-Provider Model Overrides

Each provider has a corresponding `{PROVIDER}_MODEL` env var. These are lower priority than `OSA_MODEL`.

Examples: `ANTHROPIC_MODEL`, `OPENAI_MODEL`, `GROQ_MODEL`, `OLLAMA_MODEL`, `GOOGLE_MODEL`.

## Ollama

| Env Var | Default | Description |
|---------|---------|-------------|
| `OLLAMA_URL` | `http://localhost:11434` | Ollama server URL |
| `OLLAMA_MODEL` | `qwen2.5:7b` | Model to use with Ollama |
| `OLLAMA_API_KEY` | — | Required for Ollama cloud instances |
| `OLLAMA_THINK` | `nil` | Set `true` to enable extended reasoning for models like `qwen3-thinking`. Default `nil` disables thinking for known reasoning models to prevent timeouts. |

## Agent Behaviour

These keys live under `:optimal_system_agent` application config. Set them in `config/config.exs` or via env in `runtime.exs`.

| Key | Config Key | Default | Description |
|-----|-----------|---------|-------------|
| Max iterations | `max_iterations` | `20` | Maximum tool-call iterations per agent turn before forced completion. |
| Temperature | `temperature` | `0.7` | LLM sampling temperature for all providers. |
| Max tokens | `max_tokens` | `4096` | Maximum tokens to request per LLM call. |
| Tool output limit | `max_tool_output_bytes` | `51200` | Maximum bytes captured from a single tool execution before truncation. Default is 50 KB. |
| Compaction warn | `compaction_warn` | `0.80` | Context usage fraction that triggers a warning-level compaction. |
| Compaction aggressive | `compaction_aggressive` | `0.85` | Context usage fraction that triggers aggressive sliding-window compression. |
| Compaction emergency | `compaction_emergency` | `0.95` | Context usage fraction that triggers emergency compaction (most of history dropped). |
| Proactive interval | `proactive_interval` | `1800000` (30 min) | Milliseconds between proactive monitor checks. |
| Proactive mode | `proactive_mode` | `false` | Enable autonomous greetings and background work. |
| Plan mode | `OSA_PLAN_MODE` env | `false` | When `true`, agent presents a plan for approval before executing. |

## Extended Thinking

| Env Var | Default | Description |
|---------|---------|-------------|
| `OSA_THINKING_ENABLED` | `false` | Enable extended reasoning tokens (Anthropic Claude 3.7+ only). |
| `OSA_THINKING_BUDGET` | `5000` | Maximum thinking tokens per LLM call when thinking is enabled. |

## HTTP Channel

| Env Var / Config Key | Default | Description |
|----------------------|---------|-------------|
| `OSA_HTTP_PORT` / `http_port` | `9089` | Port the Bandit HTTP server listens on. |
| `OSA_REQUIRE_AUTH` / `require_auth` | `false` | When `true`, all `/api/v1/*` requests must include a Bearer token matching `OSA_SHARED_SECRET`. |
| `OSA_SHARED_SECRET` / `shared_secret` | `nil` | Shared secret for Bearer token auth. Required when `OSA_REQUIRE_AUTH=true`. Raises at startup if missing. |

## Budget

| Env Var | Default | Description |
|---------|---------|-------------|
| `OSA_DAILY_BUDGET_USD` | `50.0` | Maximum USD spend per calendar day. Agent refuses new LLM calls when exceeded. |
| `OSA_MONTHLY_BUDGET_USD` | `500.0` | Maximum USD spend per calendar month. |
| `OSA_PER_CALL_LIMIT_USD` | `5.0` | Maximum USD cost allowed for a single LLM API call. |

## Filesystem Paths

| Config Key | Default | Description |
|-----------|---------|-------------|
| `config_dir` | `~/.osa` | Root directory for all OSA user data. |
| `skills_dir` | `~/.osa/skills` | Directory scanned for user-defined SKILL.md files. |
| `mcp_config_path` | `~/.osa/mcp.json` | Path to MCP server definitions file. |
| `bootstrap_dir` | `~/.osa` | Directory containing `IDENTITY.md`, `SOUL.md`, `USER.md`. |
| `data_dir` | `~/.osa/data` | Vault structured memory store. |
| `sessions_dir` | `~/.osa/sessions` | JSONL session conversation files. |
| `OSA_WORKING_DIR` | `nil` | Default working directory for the agent. Set to a project path to scope file operations. |

## Database

| Config Key | Default | Description |
|-----------|---------|-------------|
| `database` (Repo) | `~/.osa/osa.db` | SQLite database file path. |
| `pool_size` | `5` | Ecto connection pool size. |
| `journal_mode` | `:wal` | SQLite journal mode. WAL provides concurrent reads. |
| `DATABASE_URL` (env) | — | PostgreSQL URL for platform mode. When set, enables `Platform.Repo` and multi-tenant features. |
| `POOL_SIZE` (env) | `10` | PostgreSQL connection pool size (platform mode only). |

## Vault

| Config Key | Default | Description |
|-----------|---------|-------------|
| `vault_enabled` | `true` | Enable the structured memory vault subsystem. |
| `vault_checkpoint_interval` | `10` | Number of turns between automatic vault checkpoints. |
| `vault_observation_min_score` | `0.4` | Minimum relevance score for an observation to be persisted. |
| `vault_observation_flush_interval` | `60000` | Milliseconds between observation flush cycles. |
| `vault_context_max_chars` | `3000` | Maximum characters of vault context injected into each prompt. |

## Sandbox

| Env Var / Config Key | Default | Description |
|----------------------|---------|-------------|
| `OSA_SANDBOX_ENABLED` | `false` | Enable Docker container isolation for skill execution. |
| `sandbox_mode` | `:docker` | Isolation backend: `:docker` or `:beam`. |
| `sandbox_image` | `osa-sandbox:latest` | Default Docker image for sandboxed execution. |
| `sandbox_network` | `false` | Allow network access inside the container. |
| `sandbox_max_memory` | `256m` | Docker memory limit. |
| `sandbox_max_cpu` | `0.5` | Docker CPU limit (fraction of one core). |
| `sandbox_timeout` | `30000` | Per-command timeout in milliseconds. |
| `sandbox_workspace_mount` | `true` | Mount `~/.osa/workspace` into the container at `/workspace`. |

## Optional Sidecars

| Env Var | Default | Description |
|---------|---------|-------------|
| `OSA_GO_TOKENIZER` | `false` | Enable the Go BPE tokenizer binary. Requires `priv/go/tokenizer/osa-tokenizer` to exist. |
| `go_tokenizer_encoding` | `cl100k_base` | BPE encoding used by the Go tokenizer. |
| `OSA_PYTHON_SIDECAR` | `false` | Enable Python semantic memory search via `sentence-transformers`. |
| `python_sidecar_model` | `all-MiniLM-L6-v2` | Sentence transformer model for embedding-based memory search. |
| `OSA_PYTHON_PATH` | `python3` | Path to the Python interpreter. |

## Channel Tokens

| Env Var | Description |
|---------|-------------|
| `TELEGRAM_BOT_TOKEN` | Telegram bot token for the Telegram channel adapter. |
| `DISCORD_BOT_TOKEN` | Discord bot token. |
| `SLACK_BOT_TOKEN` | Slack bot token. |
| `BRAVE_API_KEY` | Brave Search API key for web search tool. |

## Quiet Hours

| Env Var | Default | Description |
|---------|---------|-------------|
| `OSA_QUIET_HOURS` | `nil` | Heartbeat suppression window in `HH:MM-HH:MM` format (e.g. `23:00-07:00`). Proactive notifications are suppressed during this window. |
