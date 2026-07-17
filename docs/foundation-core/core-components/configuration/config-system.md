# Configuration System

## Three-Layer Configuration

OSA resolves configuration from three layers applied in order. Later layers
override earlier ones.

```
Layer 1: config/config.exs       compile-time defaults
    ↓ overridden by
Layer 2: config/runtime.exs      runtime environment variable overrides
    ↓ overridden by
Layer 3: ~/.osa/.env             user config file (loaded by runtime.exs)
```

### Layer 1 — Compile-Time Defaults (config.exs)

`config/config.exs` sets structural defaults that are baked in at compile time.
These values apply when no environment variable or user config overrides them.

```elixir
config :optimal_system_agent,
  default_provider: :ollama,
  ollama_url: "http://localhost:11434",
  ollama_model: "qwen2.5:7b",
  anthropic_model: "claude-sonnet-4-6",
  openai_url: "https://api.openai.com/v1",
  openai_model: "gpt-4o",
  max_iterations: 20,
  temperature: 0.7,
  max_tokens: 4096,
  max_tool_output_bytes: 51_200,
  http_port: 9089,
  require_auth: false,
  sandbox_enabled: false,
  treasury_enabled: false,
  fleet_enabled: false,
  wallet_enabled: false,
  update_enabled: false
```

Environment-specific overrides are imported at the bottom:

```elixir
import_config "#{config_env()}.exs"
```

`config/dev.exs` sets `logger level: :debug`. `config/test.exs` disables the
platform database and sets `http_port: 0`.

### Layer 2 — Runtime Environment Overrides (runtime.exs)

`config/runtime.exs` runs at node startup (not compile time). It reads
environment variables and merges them into the application environment. This is
the layer that makes OSA configurable without recompilation.

The file handles:

1. `.env` file loading (project root or `~/.osa/.env`)
2. Provider auto-detection
3. API key injection
4. Budget limit overrides
5. Feature flag activation
6. Fallback chain construction

### Layer 3 — User Config File (~/.osa/.env)

`runtime.exs` loads `~/.osa/.env` before processing any other environment
variables. Lines are parsed as `KEY=VALUE` pairs. Values are trimmed of
surrounding quotes. Keys already set in the process environment are not
overwritten:

```elixir
if key != "" and value != "" and is_nil(System.get_env(key)) do
  System.put_env(key, value)
end
```

This means shell environment variables always take priority over `~/.osa/.env`,
which takes priority over compile-time defaults.

## Key Configuration Areas

### Provider Configuration

`OSA_DEFAULT_PROVIDER` sets the primary provider. If not set, the first API key
found in the environment determines the default:

```
OSA_DEFAULT_PROVIDER set? → use it
ANTHROPIC_API_KEY set?    → :anthropic
OPENAI_API_KEY set?       → :openai
GROQ_API_KEY set?         → :groq
OPENROUTER_API_KEY set?   → :openrouter
(else)                    → :ollama
```

Supported provider identifiers: `ollama`, `anthropic`, `openai`, `groq`,
`openrouter`, `together`, `fireworks`, `deepseek`, `mistral`, `cerebras`,
`google`, `cohere`, `perplexity`, `xai`, `sambanova`, `hyperbolic`,
`lmstudio`, `llamacpp`.

### Budget Limits

Budget enforcement uses three limits, all in USD:

| Config key | Env var | Default |
|------------|---------|---------|
| `daily_budget_usd` | `OSA_DAILY_BUDGET_USD` | `50.0` |
| `monthly_budget_usd` | `OSA_MONTHLY_BUDGET_USD` | `500.0` |
| `per_call_limit_usd` | `OSA_PER_CALL_LIMIT_USD` | `5.0` |

The `spend_guard` hook (priority 8, `pre_tool_use`) reads the current spend from
`MiosaBudget` and blocks tool execution when any limit is exceeded.

### Context Compaction Thresholds

Three-tier compaction thresholds control when the agent compacts its
conversation history:

| Config key | Default | Action |
|------------|---------|--------|
| `compaction_warn` | `0.80` | Log warning |
| `compaction_aggressive` | `0.85` | Summarize older turns |
| `compaction_emergency` | `0.95` | Hard truncation |

### Sandbox Configuration

The sandbox is Docker-based by default. All settings are prefixed `sandbox_`:

```elixir
sandbox_enabled: false,           # master switch
sandbox_mode: :docker,            # :docker | :beam
sandbox_image: "osa-sandbox:latest",
sandbox_network: false,           # --network none
sandbox_max_memory: "256m",
sandbox_max_cpu: "0.5",
sandbox_timeout: 30_000,          # ms per command
sandbox_workspace_mount: true,
sandbox_read_only_root: true,
sandbox_no_new_privileges: true,
sandbox_capabilities_drop: ["ALL"],
sandbox_capabilities_add: []
```

### Vault Configuration

```elixir
vault_enabled: true,
vault_checkpoint_interval: 10,        # checkpoint every N tool calls
vault_observation_min_score: 0.4,     # minimum score to persist an observation
vault_observation_flush_interval: 60_000,  # ms between observer flushes
vault_context_max_chars: 3000         # max chars injected into LLM context
```

### Fallback Chain Auto-Detection

At boot, `runtime.exs` builds the provider fallback chain by probing which API
keys are configured and whether Ollama is reachable:

```elixir
# Check Ollama reachability via TCP probe (1s timeout)
ollama_reachable = case :gen_tcp.connect(host, port, [], 1_000) do
  {:ok, sock} -> :gen_tcp.close(sock); true
  {:error, _} -> false
end

# Build chain from configured keys + reachable Ollama
chain = configured_providers ++ (if ollama_reachable, do: [:ollama], else: [])
```

Override with `OSA_FALLBACK_CHAIN=anthropic,openai,ollama` (comma-separated).

## Database Configuration

### SQLite (default)

```elixir
config :optimal_system_agent, OptimalSystemAgent.Store.Repo,
  database: Path.expand("~/.osa/osa.db"),
  pool_size: 5,
  journal_mode: :wal,
  custom_pragmas: [encoding: "'UTF-8'", busy_timeout: 5000]
```

### PostgreSQL (optional, multi-tenant platform mode)

Activated when `DATABASE_URL` is set:

```elixir
if database_url do
  config :optimal_system_agent, OptimalSystemAgent.Platform.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")
end
```

`platform_enabled` is set to `true` automatically when `DATABASE_URL` is
present. This starts `Platform.Repo` before the rest of the supervision tree.
