# Configuration Architecture

## Audience

Operators deploying OSA and developers adding new configuration knobs.

## Overview

OSA configuration flows through four sources in precedence order (highest first):

1. Environment variables (set in the shell or `.env` files)
2. `config/runtime.exs` — runtime resolution of env vars into application config
3. `config/<env>.exs` — compile-time environment overrides (`dev.exs`, `test.exs`, `prod.exs`)
4. `config/config.exs` — base defaults, imported first

The final value for any key is determined by the last `config :optimal_system_agent, key: value` call that ran, which means runtime.exs always wins over the compile-time files.

## Config File Roles

### `config/config.exs`

Base defaults for all environments. Contains every config key with a safe fallback value. Notable settings:

```elixir
config :optimal_system_agent,
  default_provider: :ollama,
  ollama_url: "http://localhost:11434",
  ollama_model: "qwen2.5:7b",
  anthropic_model: "claude-sonnet-4-6",
  max_iterations: 20,
  temperature: 0.7,
  max_tokens: 4096,
  max_tool_output_bytes: 51_200,
  http_port: 9089,
  require_auth: false,
  vault_enabled: true,
  sandbox_enabled: false,
  fleet_enabled: false,
  treasury_enabled: false
```

Ends with `import_config "#{config_env()}.exs"` which overlays the environment-specific file.

### `config/dev.exs`

Sets `Logger` level to `:debug`. No other changes — OSA's defaults are already development-friendly.

### `config/prod.exs`

Sets `Logger` level to `:info`. No other changes — all production tuning goes through environment variables resolved in `runtime.exs`.

### `config/test.exs`

Reduces pool size, disables LLM calls in the classifier and compactor, uses port 0 (OS-assigned), and generates a random shared secret per test run:

```elixir
config :optimal_system_agent, OptimalSystemAgent.Store.Repo, pool_size: 2
config :optimal_system_agent, classifier_llm_enabled: false
config :optimal_system_agent, compactor_llm_enabled: false
config :optimal_system_agent, http_port: 0
config :optimal_system_agent,
  shared_secret: "osa-test-#{:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)}"
```

### `config/runtime.exs`

Runs at application start, after compilation. Responsible for:

1. Loading `.env` files from the project root or `~/.osa/.env`
2. Auto-detecting the default provider from available API keys
3. Building the fallback chain (TCP-probing Ollama before including it)
4. Resolving all env var overrides into application config

## .env File Loading

`runtime.exs` loads `.env` files in this order, with environment variables already in the shell taking priority:

```
~/.osa/.env   (user global)
.env          (project root, takes priority over ~/.osa/.env)
```

Only variables not already set in the environment are written. Lines starting with `#` and empty lines are skipped. Values are stripped of surrounding single or double quotes.

This loading is skipped entirely in test environment to prevent `.env` variables from overriding test-specific config (port 0, `platform_enabled: false`).

## Provider Auto-Detection

`runtime.exs` selects `default_provider` using this precedence:

```
OSA_DEFAULT_PROVIDER env var
→ ANTHROPIC_API_KEY present  → :anthropic
→ OPENAI_API_KEY present     → :openai
→ GROQ_API_KEY present       → :groq
→ OPENROUTER_API_KEY present → :openrouter
→ fallback                   → :ollama
```

The fallback chain is auto-built from all configured API keys, then Ollama is TCP-probed and included only if reachable:

```elixir
ollama_reachable =
  case :gen_tcp.connect(ollama_host, ollama_port, [], 1_000) do
    {:ok, sock} -> :gen_tcp.close(sock); true
    {:error, _} -> false
  end
```

Override the chain manually with `OSA_FALLBACK_CHAIN=anthropic,openai,ollama`.

## Reading Config at Runtime

Standard pattern using `Application.get_env/3`:

```elixir
max_iter = Application.get_env(:optimal_system_agent, :max_iterations, 30)
provider  = Application.get_env(:optimal_system_agent, :default_provider, :ollama)
```

The third argument is the default if the key is absent from the application environment.

For hot-reload scenarios, `Application.put_env/3` updates the running process without restart. The onboarding flow uses this to apply a provider switch immediately:

```elixir
Application.put_env(:optimal_system_agent, :ollama_url, url)
Application.put_env(:optimal_system_agent, :ollama_api_key, api_key)
```

## persistent_term for Boot-Time Config

Config data that is read on every LLM call but never changes after boot is stored in `:persistent_term` for lock-free reads from any process:

- `Soul.load/0` stores `IDENTITY.md`, `SOUL.md`, `USER.md`, and the interpolated static system prompt under `{Soul, :key}` keys
- `PromptLoader.load/0` stores prompt templates similarly
- `Tools.Registry` stores the built-in tool map and MCP tool map under `{Tools.Registry, :builtin_tools}` and `{Tools.Registry, :mcp_tools}`

Writing to `:persistent_term` triggers a global GC pass across all processes. Only use it for data that is written once at startup or on an explicit `reload` call.

## SQLite Database Config

```elixir
config :optimal_system_agent, OptimalSystemAgent.Store.Repo,
  database: Path.expand("~/.osa/osa.db"),
  pool_size: 5,
  journal_mode: :wal,
  custom_pragmas: [encoding: "'UTF-8'", busy_timeout: 5000]
```

WAL journal mode allows concurrent reads. `busy_timeout: 5000` prevents writer starvation by waiting up to 5 seconds before returning `SQLITE_BUSY`.

## Platform PostgreSQL (Optional)

Activated by setting `DATABASE_URL`. When present, `runtime.exs` configures `OptimalSystemAgent.Platform.Repo` and adds it to `ecto_repos`:

```elixir
if database_url do
  config :optimal_system_agent, OptimalSystemAgent.Platform.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")
end
```

`platform_enabled: true` is set automatically when `DATABASE_URL` is present. Application code checks `Application.get_env(:optimal_system_agent, :platform_enabled, false)` before using platform features.
