import Config

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

# Smart provider auto-detection: explicit override > API key presence > ollama fallback
provider_map = %{
  "ollama" => :ollama, "anthropic" => :anthropic, "openai" => :openai,
  "groq" => :groq, "openrouter" => :openrouter, "together" => :together,
  "fireworks" => :fireworks, "deepseek" => :deepseek, "mistral" => :mistral,
  "cerebras" => :cerebras, "google" => :google, "cohere" => :cohere,
  "perplexity" => :perplexity, "xai" => :xai, "sambanova" => :sambanova,
  "hyperbolic" => :hyperbolic, "lmstudio" => :lmstudio, "llamacpp" => :llamacpp
}

default_provider =
  cond do
    env = System.get_env("OSA_DEFAULT_PROVIDER") -> Map.get(provider_map, env, :ollama)
    System.get_env("ANTHROPIC_API_KEY") -> :anthropic
    System.get_env("OPENAI_API_KEY") -> :openai
    System.get_env("GROQ_API_KEY") -> :groq
    System.get_env("OPENROUTER_API_KEY") -> :openrouter
    true -> :ollama
  end

config :optimal_system_agent,
  # LLM Providers
  anthropic_api_key: System.get_env("ANTHROPIC_API_KEY"),
  openai_api_key: System.get_env("OPENAI_API_KEY"),
  groq_api_key: System.get_env("GROQ_API_KEY"),
  openrouter_api_key: System.get_env("OPENROUTER_API_KEY"),

  # Ollama overrides
  ollama_url: System.get_env("OLLAMA_URL") || "http://localhost:11434",
  ollama_model: System.get_env("OLLAMA_MODEL") || "llama3.2:latest",

  # Channel tokens
  telegram_bot_token: System.get_env("TELEGRAM_BOT_TOKEN"),
  discord_bot_token: System.get_env("DISCORD_BOT_TOKEN"),
  slack_bot_token: System.get_env("SLACK_BOT_TOKEN"),
  # Web search
  brave_api_key: System.get_env("BRAVE_API_KEY"),

  # Provider selection
  default_provider: default_provider,
  # Default model — resolved from OSA_MODEL env, or provider-specific env var.
  # Falls back to OLLAMA_MODEL only when the active provider is actually ollama.
  default_model: (
    System.get_env("OSA_MODEL") ||
      case default_provider do
        :ollama -> System.get_env("OLLAMA_MODEL") || "llama3.2:latest"
        :groq -> System.get_env("GROQ_MODEL")
        :anthropic -> System.get_env("ANTHROPIC_MODEL")
        :openai -> System.get_env("OPENAI_MODEL")
        :openrouter -> System.get_env("OPENROUTER_MODEL")
        :deepseek -> System.get_env("DEEPSEEK_MODEL")
        :together -> System.get_env("TOGETHER_MODEL")
        :fireworks -> System.get_env("FIREWORKS_MODEL")
        :mistral -> System.get_env("MISTRAL_MODEL")
        :google -> System.get_env("GOOGLE_MODEL")
        :cohere -> System.get_env("COHERE_MODEL")
        :xai -> System.get_env("XAI_MODEL")
        :cerebras -> System.get_env("CEREBRAS_MODEL")
        :lmstudio -> System.get_env("LMSTUDIO_MODEL")
        :llamacpp -> System.get_env("LLAMACPP_MODEL")
        _ -> nil
      end
  ),

  # HTTP channel
  shared_secret:
    System.get_env("OSA_SHARED_SECRET") ||
      (if System.get_env("OSA_REQUIRE_AUTH") == "true" do
         raise "OSA_SHARED_SECRET must be set when OSA_REQUIRE_AUTH=true"
       else
         "osa-dev-secret-#{:crypto.strong_rand_bytes(16) |> Base.url_encode64()}"
       end),
  require_auth: System.get_env("OSA_REQUIRE_AUTH", "true") == "true",

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

  # OTA updates
  update_enabled: System.get_env("OSA_UPDATE_ENABLED") == "true",
  update_url: System.get_env("OSA_UPDATE_URL"),
  update_interval: parse_int.(System.get_env("OSA_UPDATE_INTERVAL"), 86_400_000),

  # Provider failover chain — auto-detected from configured API keys.
  # Override with comma-separated list: OSA_FALLBACK_CHAIN=anthropic,openai,ollama
  fallback_chain: (
    case System.get_env("OSA_FALLBACK_CHAIN") do
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

        ollama_reachable =
          case :gen_tcp.connect(ollama_host, ollama_port, [], 1_000) do
            {:ok, sock} -> :gen_tcp.close(sock); true
            {:error, _} -> false
          end

        chain = if ollama_reachable do
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
    end
  ),

  # Plan mode (opt-in via OSA_PLAN_MODE=true)
  plan_mode_enabled: System.get_env("OSA_PLAN_MODE") == "true",

  # Extended thinking
  thinking_enabled: System.get_env("OSA_THINKING_ENABLED") == "true",
  thinking_budget_tokens: parse_int.(System.get_env("OSA_THINKING_BUDGET"), 5_000),

  # Quiet hours for heartbeat
  quiet_hours: System.get_env("OSA_QUIET_HOURS")
