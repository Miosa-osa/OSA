import Config

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
        "#" <> _ -> :skip
        "" -> :skip
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
default_provider =
  cond do
    env = System.get_env("OSA_DEFAULT_PROVIDER") -> String.to_atom(env)
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
  slack_app_token: System.get_env("SLACK_APP_TOKEN"),

  # Web search
  brave_api_key: System.get_env("BRAVE_API_KEY"),

  # Provider selection
  default_provider: default_provider,

  # HTTP channel
  shared_secret: System.get_env("OSA_SHARED_SECRET") || "osa-dev-secret-change-me",
  require_auth: System.get_env("OSA_REQUIRE_AUTH") == "true"
