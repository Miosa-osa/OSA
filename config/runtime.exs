import Config

# ── Logger level override via env var ────────────────────────────────────
case System.get_env("LOGGER_LEVEL") do
  "warning" -> config :logger, level: :warning
  "error" -> config :logger, level: :error
  "info" -> config :logger, level: :info
  "debug" -> config :logger, level: :debug
  _ -> :ok
end

# ── Helper functions for env var parsing ─────────────────────────────────
parse_float = fn
  nil, default ->
    default

  str, default ->
    case Float.parse(str) do
      {val, _} -> val
      :error -> default
    end
end

parse_int = fn
  nil, default ->
    default

  str, default ->
    case Integer.parse(str) do
      {val, _} -> val
      :error -> default
    end
end

# ── .env file loading ──────────────────────────────────────────────────
# Load .env from project root OR ~/.osa/.env (project root takes priority).
# Only sets vars that aren't already in the environment (explicit env wins).
# Skipped in test env so OSA_HTTP_PORT / DATABASE_URL from .env don't
# override test.exs config (port 0, platform_enabled: false).
if config_env() != :test do
  for env_path <- [Path.expand(".env"), Path.expand("~/.osa/.env")] do
    if File.exists?(env_path) do
      env_path
      |> File.read!()
      |> String.split("\n")
      |> Enum.each(fn line ->
        line = String.trim(line)

        case line do
          "#" <> _ ->
            :skip

          "" ->
            :skip

          _ ->
            case String.split(line, "=", parts: 2) do
              [key, value] ->
                key = String.trim(key)
                value = value |> String.trim() |> String.trim("\"") |> String.trim("'")

                if key != "" and value != "" and is_nil(System.get_env(key)) do
                  System.put_env(key, value)
                end

              _ ->
                :skip
            end
        end
      end)
    end
  end
end

# Smart provider auto-detection: explicit override > API key presence > ollama fallback
provider_map = %{
  "ollama" => :ollama,
  "anthropic" => :anthropic,
  "openai" => :openai,
  "groq" => :groq,
  "openrouter" => :openrouter,
  "together" => :together,
  "fireworks" => :fireworks,
  "deepseek" => :deepseek,
  "mistral" => :mistral,
  "cerebras" => :cerebras,
  "google" => :google,
  "cohere" => :cohere,
  "perplexity" => :perplexity,
  "xai" => :xai,
  "sambanova" => :sambanova,
  "hyperbolic" => :hyperbolic,
  "lmstudio" => :lmstudio,
  "llamacpp" => :llamacpp,
  "miosa" => :miosa,
  "replicate" => :replicate,
  "qwen" => :qwen,
  "moonshot" => :moonshot,
  "zhipu" => :zhipu,
  "glm" => :zhipu,
  "volcengine" => :volcengine,
  "baichuan" => :baichuan,
  "ollama_cloud" => :ollama_cloud
}

default_provider =
  cond do
    env = System.get_env("OSA_DEFAULT_PROVIDER") -> Map.get(provider_map, env, :ollama)
    System.get_env("MIOSA_API_KEY") -> :miosa
    # Ollama Cloud is the MAIN recommended path (no local GPU needed). An
    # OLLAMA_API_KEY (or an ollama.com OLLAMA_URL) routes through the native
    # Ollama provider pinned to the cloud endpoint.
    System.get_env("OLLAMA_API_KEY") -> :ollama
    (u = System.get_env("OLLAMA_URL")) && String.contains?(u, "ollama.com") -> :ollama
    System.get_env("ANTHROPIC_API_KEY") -> :anthropic
    System.get_env("OPENAI_API_KEY") -> :openai
    System.get_env("GROQ_API_KEY") -> :groq
    System.get_env("OPENROUTER_API_KEY") -> :openrouter
    true -> :ollama
  end

config :optimal_system_agent,
  # LLM Providers — API keys
  anthropic_api_key: System.get_env("ANTHROPIC_API_KEY"),
  openai_api_key: System.get_env("OPENAI_API_KEY"),
  groq_api_key: System.get_env("GROQ_API_KEY"),
  openrouter_api_key: System.get_env("OPENROUTER_API_KEY"),
  google_api_key: System.get_env("GOOGLE_API_KEY"),
  deepseek_api_key: System.get_env("DEEPSEEK_API_KEY"),
  mistral_api_key: System.get_env("MISTRAL_API_KEY"),
  together_api_key: System.get_env("TOGETHER_API_KEY"),
  fireworks_api_key: System.get_env("FIREWORKS_API_KEY"),
  replicate_api_key: System.get_env("REPLICATE_API_KEY"),
  perplexity_api_key: System.get_env("PERPLEXITY_API_KEY"),
  cohere_api_key: System.get_env("COHERE_API_KEY"),
  qwen_api_key: System.get_env("QWEN_API_KEY"),
  zhipu_api_key: System.get_env("ZHIPU_API_KEY"),
  moonshot_api_key: System.get_env("MOONSHOT_API_KEY"),
  volcengine_api_key: System.get_env("VOLCENGINE_API_KEY"),
  baichuan_api_key: System.get_env("BAICHUAN_API_KEY"),
  xai_api_key: System.get_env("XAI_API_KEY"),
  cerebras_api_key: System.get_env("CEREBRAS_API_KEY"),
  sambanova_api_key: System.get_env("SAMBANOVA_API_KEY"),
  hyperbolic_api_key: System.get_env("HYPERBOLIC_API_KEY"),
  lmstudio_api_key: System.get_env("LMSTUDIO_API_KEY"),
  llamacpp_api_key: System.get_env("LLAMACPP_API_KEY"),

  # LLM Providers — model overrides (per-provider, takes precedence over OSA_MODEL)
  google_model: System.get_env("GOOGLE_MODEL"),
  deepseek_model: System.get_env("DEEPSEEK_MODEL"),
  mistral_model: System.get_env("MISTRAL_MODEL"),
  together_model: System.get_env("TOGETHER_MODEL"),
  fireworks_model: System.get_env("FIREWORKS_MODEL"),
  replicate_model: System.get_env("REPLICATE_MODEL"),
  perplexity_model: System.get_env("PERPLEXITY_MODEL"),
  cohere_model: System.get_env("COHERE_MODEL"),
  qwen_model: System.get_env("QWEN_MODEL"),
  zhipu_model: System.get_env("ZHIPU_MODEL"),
  moonshot_model: System.get_env("MOONSHOT_MODEL"),
  volcengine_model: System.get_env("VOLCENGINE_MODEL"),
  baichuan_model: System.get_env("BAICHUAN_MODEL"),
  xai_model: System.get_env("XAI_MODEL"),
  cerebras_model: System.get_env("CEREBRAS_MODEL"),
  sambanova_model: System.get_env("SAMBANOVA_MODEL"),
  hyperbolic_model: System.get_env("HYPERBOLIC_MODEL"),
  lmstudio_model: System.get_env("LMSTUDIO_MODEL"),
  llamacpp_model: System.get_env("LLAMACPP_MODEL"),

  # ── Channel Adapters ────────────────────────────────────────────────
  # WhatsApp (Baileys bridge sidecar)
  whatsapp_enabled: System.get_env("WHATSAPP_ENABLED") == "true",
  whatsapp_bridge_url: System.get_env("WHATSAPP_BRIDGE_URL") || "http://127.0.0.1:3001",

  # Matrix
  matrix_homeserver: System.get_env("MATRIX_HOMESERVER"),
  matrix_access_token: System.get_env("MATRIX_ACCESS_TOKEN"),
  matrix_allowed_users: System.get_env("MATRIX_ALLOWED_USERS"),

  # Email (IMAP + SMTP)
  email_imap_host: System.get_env("EMAIL_IMAP_HOST"),
  email_imap_port: parse_int.(System.get_env("EMAIL_IMAP_PORT"), 993),
  email_smtp_host: System.get_env("EMAIL_SMTP_HOST"),
  email_smtp_port: parse_int.(System.get_env("EMAIL_SMTP_PORT"), 587),
  email_address: System.get_env("EMAIL_ADDRESS"),
  email_password: System.get_env("EMAIL_PASSWORD"),
  email_poll_interval: parse_int.(System.get_env("EMAIL_POLL_INTERVAL"), 15),
  email_allowed_senders: System.get_env("EMAIL_ALLOWED_SENDERS"),

  # LINE Messaging API
  line_channel_token: System.get_env("LINE_CHANNEL_TOKEN"),
  line_channel_secret: System.get_env("LINE_CHANNEL_SECRET"),

  # Signal (signal-cli REST API)
  signal_api_url: System.get_env("SIGNAL_API_URL"),
  signal_phone_number: System.get_env("SIGNAL_PHONE_NUMBER"),

  # DingTalk
  dingtalk_client_id: System.get_env("DINGTALK_CLIENT_ID"),
  dingtalk_client_secret: System.get_env("DINGTALK_CLIENT_SECRET"),

  # Feishu/Lark
  feishu_app_id: System.get_env("FEISHU_APP_ID"),
  feishu_app_secret: System.get_env("FEISHU_APP_SECRET"),
  feishu_verification_token: System.get_env("FEISHU_VERIFICATION_TOKEN"),

  # WeCom (Enterprise WeChat)
  wecom_bot_key: System.get_env("WECOM_BOT_KEY"),
  wecom_webhook_token: System.get_env("WECOM_WEBHOOK_TOKEN"),

  # Computer Use — set OSA_COMPUTER_USE=true to enable desktop control tool
  computer_use_enabled: System.get_env("OSA_COMPUTER_USE") == "true",
  computer_use_platform:
    (case System.get_env("OSA_COMPUTER_USE_PLATFORM") do
       nil -> nil
       "" -> nil
       "miosa" -> :miosa
       "macos" -> :macos
       "linux_x11" -> :linux_x11
       "linux_wayland" -> :linux_wayland
       _ -> nil
     end),
  computer_use_miosa: [
    computer_id: System.get_env("MIOSA_COMPUTER_ID") || System.get_env("OSA_COMPUTER_ID"),
    api_key: System.get_env("MIOSA_API_KEY"),
    base_url: System.get_env("MIOSA_API_BASE_URL") || "https://api.miosa.ai/api/v1"
  ],

  # Ollama overrides (OLLAMA_API_KEY required for cloud instances)
  # Falls back to config.exs values (Ollama Cloud + nemotron-3-super:cloud) when no env var set.
  # When an Ollama Cloud key is present but no explicit URL, pin to the
  # cloud endpoint (no GPU needed). Otherwise use the local default.
  ollama_url:
    System.get_env("OLLAMA_URL") ||
      if(System.get_env("OLLAMA_API_KEY"),
        do: "https://ollama.com",
        else:
          Application.compile_env(:optimal_system_agent, :ollama_url, "http://localhost:11434")
      ),
  ollama_model:
    System.get_env("OLLAMA_MODEL") ||
      Application.compile_env(:optimal_system_agent, :ollama_model, "nemotron-3-super:cloud"),
  ollama_api_key: System.get_env("OLLAMA_API_KEY"),
  # OLLAMA_THINK: set to "true" to enable extended reasoning (kimi-k2, qwen3-thinking, etc.)
  # Default nil → ollama.ex disables thinking for known reasoning models to prevent timeouts.
  ollama_think:
    (case System.get_env("OLLAMA_THINK") do
       "true" -> true
       "false" -> false
       _ -> nil
     end),

  # MIOSA / Optimal — routes through openai_compat with optimal.miosa.ai base URL
  miosa_api_key: System.get_env("MIOSA_API_KEY"),
  miosa_url: System.get_env("MIOSA_URL") || "https://optimal.miosa.ai/v1",
  miosa_model: System.get_env("MIOSA_MODEL") || System.get_env("OSA_MODEL") || "nemotron-3-miosa",

  # Channel tokens
  telegram_bot_token: System.get_env("TELEGRAM_BOT_TOKEN"),
  discord_bot_token: System.get_env("DISCORD_BOT_TOKEN"),
  slack_bot_token: System.get_env("SLACK_BOT_TOKEN"),
  # Channel webhook signing secrets — used to HMAC-verify inbound webhooks.
  # When a bot token is set but the signing secret is missing, verification
  # FAILS CLOSED (see slack.ex / channel_routes.ex) so an unauthenticated
  # party cannot drive agent turns.
  slack_signing_secret: System.get_env("SLACK_SIGNING_SECRET"),
  signal_webhook_secret: System.get_env("SIGNAL_WEBHOOK_SECRET"),
  # Per-channel allowlists (comma-separated ids). Empty = current open behavior
  # unless the deployment sets these to restrict who can drive agent turns.
  telegram_allowed_chats: System.get_env("TELEGRAM_ALLOWED_CHATS"),
  discord_allowed_users: System.get_env("DISCORD_ALLOWED_USERS"),
  slack_allowed_users: System.get_env("SLACK_ALLOWED_USERS"),
  # Web search
  brave_api_key: System.get_env("BRAVE_API_KEY"),

  # Provider selection
  default_provider: default_provider,
  # Default model — resolved from OSA_MODEL env, or provider-specific env var.
  # Falls back to OLLAMA_MODEL only when the active provider is actually ollama.
  default_model:
    System.get_env("OSA_MODEL") ||
      (case default_provider do
         :miosa ->
           System.get_env("MIOSA_MODEL") || "nemotron-3-miosa"

         :ollama ->
           System.get_env("OLLAMA_MODEL") ||
             Application.compile_env(
               :optimal_system_agent,
               :ollama_model,
               "nemotron-3-super:cloud"
             )

         :groq ->
           System.get_env("GROQ_MODEL")

         :anthropic ->
           System.get_env("ANTHROPIC_MODEL")

         :openai ->
           System.get_env("OPENAI_MODEL")

         :openrouter ->
           System.get_env("OPENROUTER_MODEL")

         :deepseek ->
           System.get_env("DEEPSEEK_MODEL")

         :together ->
           System.get_env("TOGETHER_MODEL")

         :fireworks ->
           System.get_env("FIREWORKS_MODEL")

         :mistral ->
           System.get_env("MISTRAL_MODEL")

         :google ->
           System.get_env("GOOGLE_MODEL")

         :cohere ->
           System.get_env("COHERE_MODEL")

         :xai ->
           System.get_env("XAI_MODEL")

         :cerebras ->
           System.get_env("CEREBRAS_MODEL")

         :lmstudio ->
           System.get_env("LMSTUDIO_MODEL")

         :llamacpp ->
           System.get_env("LLAMACPP_MODEL")

         _ ->
           nil
       end),

  # HTTP channel
  shared_secret:
    System.get_env("OSA_SHARED_SECRET") ||
      (if System.get_env("OSA_REQUIRE_AUTH") == "true" do
         raise "OSA_SHARED_SECRET must be set when OSA_REQUIRE_AUTH=true"
       else
         # Don't override test.exs or config.exs secrets; nil means dev mode (open access)
         Application.get_env(:optimal_system_agent, :shared_secret)
       end),
  require_auth: System.get_env("OSA_REQUIRE_AUTH", "false") == "true",

  # Bind address for the HTTP channel.
  # Defaults to 127.0.0.1 (loopback) — safe with open-access dev mode.
  # Set OSA_HTTP_IP=0.0.0.0 to expose on all interfaces (requires auth).
  http_ip:
    (case System.get_env("OSA_HTTP_IP", "127.0.0.1") do
       "0.0.0.0" ->
         {0, 0, 0, 0}

       "::1" ->
         {0, 0, 0, 0, 0, 0, 0, 1}

       "::" ->
         {0, 0, 0, 0, 0, 0, 0, 0}

       ip_str ->
         parts = String.split(ip_str, ".")

         if length(parts) == 4 do
           octets =
             Enum.map(parts, fn part ->
               case Integer.parse(part) do
                 {n, ""} when n in 0..255 -> n
                 _ -> :invalid
               end
             end)

           if Enum.any?(octets, &(&1 == :invalid)) do
             require Logger

             Logger.warning(
               "[runtime] Invalid OSA_HTTP_IP #{inspect(ip_str)}; falling back to 127.0.0.1"
             )

             {127, 0, 0, 1}
           else
             List.to_tuple(octets)
           end
         else
           {127, 0, 0, 1}
         end
     end),

  # Budget limits (USD)
  daily_budget_usd: parse_float.(System.get_env("OSA_DAILY_BUDGET_USD"), 50.0),
  monthly_budget_usd: parse_float.(System.get_env("OSA_MONTHLY_BUDGET_USD"), 500.0),
  per_call_limit_usd: parse_float.(System.get_env("OSA_PER_CALL_LIMIT_USD"), 5.0),

  # Treasury — keys match Treasury GenServer expectations
  treasury_enabled: System.get_env("OSA_TREASURY_ENABLED") == "true",
  treasury_auto_debit: System.get_env("OSA_TREASURY_AUTO_DEBIT") != "false",
  treasury_daily_limit: parse_float.(System.get_env("OSA_TREASURY_DAILY_LIMIT"), 250.0),
  treasury_max_single: parse_float.(System.get_env("OSA_TREASURY_MAX_SINGLE"), 50.0),

  # Fleet management
  fleet_enabled: System.get_env("OSA_FLEET_ENABLED") == "true",

  # Wallet integration
  wallet_enabled: System.get_env("OSA_WALLET_ENABLED") == "true",
  wallet_provider: System.get_env("OSA_WALLET_PROVIDER") || "mock",
  wallet_address: System.get_env("OSA_WALLET_ADDRESS"),
  wallet_rpc_url: System.get_env("OSA_WALLET_RPC_URL"),

  # Sprites.dev sandbox
  sprites_token: System.get_env("SPRITES_TOKEN"),
  sprites_api_url: System.get_env("SPRITES_API_URL") || "https://api.sprites.dev",

  # OTA updates
  update_enabled: System.get_env("OSA_UPDATE_ENABLED") == "true",
  update_url: System.get_env("OSA_UPDATE_URL"),
  update_interval: parse_int.(System.get_env("OSA_UPDATE_INTERVAL"), 86_400_000),

  # OpenComputers host daemon mode. The installer sets the env var in the
  # launchd/systemd service; the marker is kept for interactive CLI enablement.
  open_computers_enabled:
    System.get_env("OSA_OPEN_COMPUTERS_ENABLED") == "true" or
      File.exists?(Path.expand("~/.osa/.open_computers_enabled")),

  # Provider failover chain — auto-detected from configured API keys.
  # Override with comma-separated list: OSA_FALLBACK_CHAIN=anthropic,openai,ollama
  fallback_chain:
    (case System.get_env("OSA_FALLBACK_CHAIN") do
       nil ->
         candidates = [
           {:anthropic, System.get_env("ANTHROPIC_API_KEY")},
           {:openai, System.get_env("OPENAI_API_KEY")},
           {:groq, System.get_env("GROQ_API_KEY")},
           {:openrouter, System.get_env("OPENROUTER_API_KEY")},
           {:deepseek, System.get_env("DEEPSEEK_API_KEY")},
           {:together, System.get_env("TOGETHER_API_KEY")},
           {:fireworks, System.get_env("FIREWORKS_API_KEY")},
           {:mistral, System.get_env("MISTRAL_API_KEY")},
           {:google, System.get_env("GOOGLE_API_KEY")},
           {:cohere, System.get_env("COHERE_API_KEY")}
         ]

         configured = for {name, key} <- candidates, key != nil and key != "", do: name

         # Only add Ollama if it's actually reachable (TCP check, 1s timeout).
         # Prevents Req.TransportError{reason: :econnrefused} on every provider failure.
         ollama_url = System.get_env("OLLAMA_URL") || "http://localhost:11434"
         ollama_uri = URI.parse(ollama_url)
         ollama_host = String.to_charlist(ollama_uri.host || "localhost")
         ollama_port = ollama_uri.port || 11434

         # If OLLAMA_API_KEY is set, assume Ollama Cloud is reachable (skip TCP check).
         # Otherwise, TCP-check local Ollama.
         ollama_reachable =
           if System.get_env("OLLAMA_API_KEY") do
             true
           else
             case :gen_tcp.connect(ollama_host, ollama_port, [], 1_000) do
               {:ok, sock} ->
                 :gen_tcp.close(sock)
                 true

               {:error, _} ->
                 false
             end
           end

         chain =
           if ollama_reachable do
             (configured ++ [:ollama]) |> Enum.uniq()
           else
             configured
           end

         Enum.reject(chain, &(&1 == default_provider))

       csv ->
         csv
         |> String.split(",", trim: true)
         |> Enum.map(&String.trim/1)
         |> Enum.map(fn name ->
           try do
             String.to_existing_atom(name)
           rescue
             ArgumentError -> nil
           end
         end)
         |> Enum.reject(&is_nil/1)
     end),

  # Plan mode (opt-in via OSA_PLAN_MODE=true)
  plan_mode_enabled: System.get_env("OSA_PLAN_MODE") == "true",

  # Extended thinking
  thinking_enabled: System.get_env("OSA_THINKING_ENABLED") == "true",
  thinking_budget_tokens: parse_int.(System.get_env("OSA_THINKING_BUDGET"), 5_000),

  # Quiet hours for heartbeat
  quiet_hours: System.get_env("OSA_QUIET_HOURS"),

  # Default working directory for the agent (e.g. a project you want OSA to work on).
  # Set OSA_WORKING_DIR=~/Desktop/BOS to point OSA at the BOS codebase by default.
  working_dir:
    (case System.get_env("OSA_WORKING_DIR") do
       nil -> nil
       path -> Path.expand(path)
     end)

# ── Platform (multi-tenant PostgreSQL + AMQP) ────────────────────────
# These are optional — OSA works standalone without them.
# Set DATABASE_URL to enable Platform.Repo (PostgreSQL for users, tenants, OS instances).
# Set AMQP_URL to enable event publishing to Go workers.
# Set JWT_SECRET to share JWT signing key with the Go backend.

database_url = System.get_env("DATABASE_URL")

if database_url do
  config :optimal_system_agent, OptimalSystemAgent.Platform.Repo,
    url: database_url,
    pool_size: max(parse_int.(System.get_env("POOL_SIZE"), 10), 1)

  config :optimal_system_agent,
    ecto_repos: [OptimalSystemAgent.Store.Repo, OptimalSystemAgent.Platform.Repo]
end

config :optimal_system_agent,
  jwt_secret: System.get_env("JWT_SECRET"),
  amqp_url: System.get_env("AMQP_URL"),
  platform_enabled: database_url != nil
