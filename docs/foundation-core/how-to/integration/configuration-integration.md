# Configuration Integration

Audience: developers who need to read, write, or extend OSA's runtime
configuration from their own code.

---

## How Configuration is Loaded

OSA uses standard Elixir/Mix configuration with a layered precedence:

```
Shell environment variables         (highest priority)
  └── .env in project root
        └── ~/.osa/.env
              └── config/runtime.exs  (evaluates the above)
                    └── config/config.exs  (compile-time defaults)
                          └── config/dev.exs | prod.exs | test.exs
```

`config/runtime.exs` is evaluated at application startup, after the OTP
release is assembled. It reads environment variables and writes the resolved
values into the application environment under the `:optimal_system_agent` key.

`.env` files are loaded by `runtime.exs` before provider detection runs. Only
keys that are not already in the shell environment are written — an explicit
shell export always wins.

---

## Reading Configuration

### From application code

```elixir
# Read a value (with default)
Application.get_env(:optimal_system_agent, :default_provider, :ollama)

# Read a nested value
Application.get_env(:optimal_system_agent, :noise_filter_thresholds, %{})
|> Map.get(:definitely_noise, 0.15)
```

### Common configuration keys

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `:default_provider` | `atom()` | auto-detected | Active LLM provider |
| `:default_model` | `String.t()` or `nil` | provider default | Active LLM model |
| `:http_port` | `integer()` | `9089` | HTTP server port |
| `:max_iterations` | `integer()` | `30` | Max ReAct loop iterations |
| `:max_context_tokens` | `integer()` | `128_000` | Context window size |
| `:max_response_tokens` | `integer()` | `8_192` | Max tokens per LLM response |
| `:daily_budget_usd` | `float()` | `50.0` | Daily spend limit in USD |
| `:monthly_budget_usd` | `float()` | `500.0` | Monthly spend limit in USD |
| `:per_call_limit_usd` | `float()` | `5.0` | Per-call spend limit in USD |
| `:require_auth` | `boolean()` | `false` | Enable JWT auth on HTTP endpoints |
| `:shared_secret` | `String.t()` or `nil` | `nil` | JWT signing secret |
| `:plan_mode_enabled` | `boolean()` | `false` | Single LLM call, no tool loop |
| `:thinking_enabled` | `boolean()` | `false` | Extended reasoning mode |
| `:working_dir` | `String.t()` or `nil` | `nil` | Default working directory |
| `:platform_enabled` | `boolean()` | `false` | PostgreSQL platform layer |

---

## Environment Variables

All user-facing configuration is driven by environment variables. Setting a
variable and restarting OSA is the standard way to change configuration.

### Provider and model

```sh
# Override provider
OSA_DEFAULT_PROVIDER=anthropic

# Override model (applies to the active provider)
OSA_MODEL=claude-opus-4-5

# Provider-specific model overrides
ANTHROPIC_MODEL=claude-opus-4-5
OPENAI_MODEL=gpt-4o
GOOGLE_MODEL=gemini-2.0-flash
```

### Budget

```sh
OSA_DAILY_BUDGET_USD=25.0
OSA_MONTHLY_BUDGET_USD=250.0
OSA_PER_CALL_LIMIT_USD=2.0
```

### HTTP and auth

```sh
OSA_HTTP_PORT=9089
OSA_REQUIRE_AUTH=true
OSA_SHARED_SECRET=a-very-long-random-secret
```

### Behaviour flags

```sh
OSA_PLAN_MODE=true           # Single LLM call per message — no tool loop
OSA_THINKING_ENABLED=false   # Extended reasoning (Anthropic only); ON by default
OSA_THINKING_BUDGET=10000    # Max tokens for extended reasoning
OSA_WORKING_DIR=~/projects/myapp  # Default working directory
OSA_QUIET_HOURS=22-08        # Suppress heartbeat during these hours
```

### Fallback chain

```sh
# Override auto-detected fallback order
OSA_FALLBACK_CHAIN=anthropic,openai,ollama
```

### Channel tokens

```sh
TELEGRAM_BOT_TOKEN=...
DISCORD_BOT_TOKEN=...
SLACK_BOT_TOKEN=...
```

### Platform (optional)

```sh
DATABASE_URL=postgresql://user:pass@host/db  # Enables PostgreSQL platform layer
AMQP_URL=amqp://guest:guest@localhost/       # Enables RabbitMQ event publishing
JWT_SECRET=shared-secret-with-go-backend
```

---

## Runtime Configuration Changes

### Application.put_env

```elixir
# Change a value at runtime (takes effect immediately for new reads)
Application.put_env(:optimal_system_agent, :plan_mode_enabled, true)

# Verify
Application.get_env(:optimal_system_agent, :plan_mode_enabled)
# => true
```

`put_env` is not persistent across restarts. For persistent changes, update
the `.env` file and restart.

### Feature flag pattern

```elixir
defmodule MyModule do
  defp feature_enabled? do
    Application.get_env(:optimal_system_agent, :my_feature_enabled, false)
  end

  def do_something do
    if feature_enabled?() do
      # new code path
    else
      # old code path
    end
  end
end
```

Enable the feature without a code change:

```sh
# In .env or shell
MY_FEATURE_ENABLED=true  # read in runtime.exs as:
# Application.put_env(:optimal_system_agent, :my_feature_enabled, true)
```

Or toggle at runtime in IEx:

```elixir
Application.put_env(:optimal_system_agent, :my_feature_enabled, true)
```

---

## Adding New Configuration Keys

1. Add the env var read to `config/runtime.exs`:

```elixir
config :optimal_system_agent,
  my_new_setting: System.get_env("MY_NEW_SETTING") || "default"
```

2. Add a compile-time default to `config/config.exs` if needed:

```elixir
config :optimal_system_agent,
  my_new_setting: "default"
```

3. Read it in your module:

```elixir
defp my_new_setting do
  Application.get_env(:optimal_system_agent, :my_new_setting, "default")
end
```

Use a private function rather than a module attribute (`@`) for configuration
that may change at runtime. Module attributes are evaluated at compile time.

---

## Related

- [Integrating a Subsystem](./integrating-a-subsystem.md) — connect to Events.Bus and Memory
- [Local Development](../../development/local-development.md) — dev-mode configuration
- [Runtime Behavior](../../operations/runtime-behavior.md) — supervision and process restart semantics
