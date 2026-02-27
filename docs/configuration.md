# Configuration Reference

> Complete reference for all OSA configuration options

## Configuration Sources (Priority Order)

1. **Environment variables** — highest priority, runtime override
2. **runtime.exs** — loaded at boot, supports `.env` file loading
3. **config.exs** — compile-time defaults

The system loads `.env` files from two locations:
```
.env                  # Project root (highest priority)
~/.osa/.env           # User config directory
```

Comments (`#`) and blank lines are skipped. Format: `KEY=value` or `KEY="quoted value"`.

---

## Provider API Keys

| Env Var | Provider | Models |
|---------|----------|--------|
| `ANTHROPIC_API_KEY` | Anthropic | Claude Opus, Sonnet, Haiku |
| `OPENAI_API_KEY` | OpenAI | GPT-4o, GPT-4o-mini, GPT-3.5-turbo |
| `GROQ_API_KEY` | Groq | Llama, Mixtral (LPU inference) |
| `OPENROUTER_API_KEY` | OpenRouter | 100+ models via single key |
| `GOOGLE_API_KEY` | Google | Gemini 2.5 Pro, 2.0 Flash |
| `DEEPSEEK_API_KEY` | DeepSeek | DeepSeek R1, Chat V3 |
| `MISTRAL_API_KEY` | Mistral | Mistral Large, Medium |
| `TOGETHER_API_KEY` | Together AI | Open models (Llama, CodeLlama) |
| `FIREWORKS_API_KEY` | Fireworks | Fast open model inference |
| `REPLICATE_API_KEY` | Replicate | Any model on Replicate |
| `PERPLEXITY_API_KEY` | Perplexity | Sonar models (search-augmented) |
| `COHERE_API_KEY` | Cohere | Command R+ |
| `QWEN_API_KEY` | Qwen (Alibaba) | Qwen 2.5 |
| `ZHIPU_API_KEY` | Zhipu | GLM-4 |
| `MOONSHOT_API_KEY` | Moonshot | Moonshot v1 |
| `VOLCENGINE_API_KEY` | VolcEngine | Doubao |
| `BAICHUAN_API_KEY` | Baichuan | Baichuan 4 |

### Provider Auto-Detection

When `OSA_DEFAULT_PROVIDER` is not set, the system auto-detects based on available keys:

```
1. OSA_DEFAULT_PROVIDER env var → explicit override
2. ANTHROPIC_API_KEY present   → :anthropic
3. OPENAI_API_KEY present      → :openai
4. GROQ_API_KEY present        → :groq
5. OPENROUTER_API_KEY present  → :openrouter
6. Fallback                    → :ollama (local)
```

### Per-Provider Config

Each provider supports `_model` and `_url` config keys:

```bash
# Override default model for a provider
export OLLAMA_MODEL="llama3.2:latest"
export OLLAMA_URL="http://localhost:11434"
```

Default models:
| Provider | Default Model |
|----------|--------------|
| Anthropic | `claude-sonnet-4-6` |
| OpenAI | `gpt-4o` |
| Ollama | `llama3.2:latest` |
| OpenRouter | `meta-llama/llama-3.3-70b-instruct` |
| Groq | Provider default |

---

## Core Agent Settings

| Env Var | Config Key | Default | Description |
|---------|-----------|---------|-------------|
| — | `max_iterations` | `20` | Max ReAct loops per agent execution |
| — | `temperature` | `0.7` | LLM sampling temperature (0.0-1.0) |
| — | `max_tokens` | `4096` | Max tokens per LLM response |
| — | `noise_filter_threshold` | `0.6` | Signal noise confidence cutoff |

---

## Budget Management

| Env Var | Default | Description |
|---------|---------|-------------|
| `OSA_DAILY_BUDGET_USD` | `50.0` | Daily API spend limit (USD) |
| `OSA_MONTHLY_BUDGET_USD` | `500.0` | Monthly API spend limit (USD) |
| `OSA_PER_CALL_LIMIT_USD` | `5.0` | Per-LLM-call spend limit (USD) |

---

## Treasury (Financial Governance)

| Env Var | Default | Description |
|---------|---------|-------------|
| `OSA_TREASURY_ENABLED` | `false` | Enable treasury balance management |
| `OSA_TREASURY_AUTO_DEBIT` | `true` | Auto-debit treasury on LLM calls |
| `OSA_TREASURY_DAILY_LIMIT` | `250.0` | Daily withdrawal limit (USD) |
| `OSA_TREASURY_MONTHLY_LIMIT` | `2500.0` | Monthly withdrawal limit (USD) |
| `OSA_TREASURY_MAX_SINGLE` | `50.0` | Max single transaction (USD) |

---

## HTTP Server

| Env Var | Default | Description |
|---------|---------|-------------|
| `OSA_HTTP_PORT` | `8089` | HTTP API server port |
| `OSA_REQUIRE_AUTH` | `false` | Require authentication |
| `OSA_SHARED_SECRET` | Auto-generated | HMAC secret for request signing |

---

## Feature Flags

| Env Var | Default | Description |
|---------|---------|-------------|
| `OSA_FLEET_ENABLED` | `false` | Multi-agent fleet registry + health monitoring |
| `OSA_WALLET_ENABLED` | `false` | Crypto wallet integration |
| `OSA_UPDATE_ENABLED` | `false` | OTA updates with TUF verification |
| `OSA_SANDBOX_ENABLED` | `false` | Docker container isolation for skills |
| `OSA_GO_TOKENIZER_ENABLED` | `false` | Go BPE tokenizer sidecar |
| `OSA_PYTHON_SIDECAR_ENABLED` | `false` | Python embeddings sidecar |
| `OSA_GO_GIT_ENABLED` | `false` | Go git introspection sidecar |
| `OSA_GO_SYSMON_ENABLED` | `false` | Go system monitor sidecar |
| `OSA_TREASURY_ENABLED` | `false` | Financial governance |
| `OSA_QUIET_HOURS` | `nil` | Suppress heartbeat. Format: `"23:00-08:00"` |

---

## Channel Credentials

### Telegram
```bash
TELEGRAM_BOT_TOKEN="123456:ABC-DEF..."
```

### Discord
```bash
DISCORD_BOT_TOKEN="MTIz..."
DISCORD_APPLICATION_ID="1234567890"
DISCORD_PUBLIC_KEY="abc123..."
```

### Slack
```bash
SLACK_BOT_TOKEN="xoxb-..."
SLACK_APP_TOKEN="xapp-..."
SLACK_SIGNING_SECRET="abc123..."
```

### WhatsApp (Business API)
```bash
WHATSAPP_TOKEN="EAABx..."
WHATSAPP_PHONE_NUMBER_ID="15551234567"
WHATSAPP_VERIFY_TOKEN="my-verify-token"
```

### Signal
```bash
SIGNAL_API_URL="http://localhost:8080"
SIGNAL_PHONE_NUMBER="+15551234567"
```

### Matrix
```bash
MATRIX_HOMESERVER="https://matrix.org"
MATRIX_ACCESS_TOKEN="syt_..."
MATRIX_USER_ID="@bot:matrix.org"
```

### Email (SendGrid)
```bash
EMAIL_FROM="bot@yourdomain.com"
EMAIL_FROM_NAME="OSA Agent"
SENDGRID_API_KEY="SG.xxx..."
```

### Email (SMTP)
```bash
EMAIL_FROM="bot@yourdomain.com"
EMAIL_SMTP_HOST="smtp.gmail.com"
EMAIL_SMTP_USER="bot@gmail.com"
EMAIL_SMTP_PASSWORD="app-password"
```

### DingTalk
```bash
DINGTALK_ACCESS_TOKEN="xxx..."
DINGTALK_SECRET="SECxxx..."
```

### Feishu
```bash
FEISHU_APP_ID="cli_xxx"
FEISHU_APP_SECRET="xxx..."
FEISHU_ENCRYPT_KEY="xxx..."
```

### QQ
```bash
QQ_APP_ID="123456"
QQ_APP_SECRET="xxx..."
QQ_TOKEN="xxx..."
```

### Web Search
```bash
BRAVE_API_KEY="BSAx..."
```

---

## Sandbox Configuration

```elixir
# config.exs defaults
config :optimal_system_agent, :sandbox,
  mode: :docker,
  image: "osa-sandbox:latest",
  network: false,
  max_memory: "256m",
  max_cpu: "0.5",
  timeout: 30_000,
  workspace_mount: true,
  allowed_images: ["osa-sandbox:latest", "python:3.12-slim", "node:22-slim"],
  capabilities_drop: ["ALL"],
  capabilities_add: [],
  read_only_root: true,
  no_new_privileges: true
```

---

## Context Compaction Thresholds

```elixir
config :optimal_system_agent, :compaction,
  warn: 0.80,        # 80% of token budget → warning
  aggressive: 0.85,  # 85% → aggressive compaction
  emergency: 0.95    # 95% → emergency compaction
```

---

## Database

```elixir
config :optimal_system_agent, OptimalSystemAgent.Store.Repo,
  database: "~/.osa/osa.db",
  pool_size: 5,
  journal_mode: :wal
```

---

## Directory Structure

```
~/.osa/
├── config.json              # Machine configuration
├── osa.db                   # SQLite database
├── IDENTITY.md              # Agent identity
├── SOUL.md                  # Personality
├── USER.md                  # User profile
├── HEARTBEAT.md             # Periodic tasks
├── CRONS.json               # Scheduled jobs
├── TRIGGERS.json            # Event triggers
├── MEMORY.md                # Long-term memory
├── mcp.json                 # MCP server configuration
├── heartbeat_state.json     # Heartbeat persistence
├── sessions/                # Session JSONL files
├── skills/                  # Custom SKILL.md files
├── learning/                # Pattern & solution data
│   ├── patterns.json
│   └── solutions.json
├── data/                    # General data storage
├── workspace/               # Sandbox mount point
└── tmp/                     # Temporary files
```
