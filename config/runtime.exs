import Config

config :optimal_system_agent,
  # LLM Providers
  anthropic_api_key: System.get_env("ANTHROPIC_API_KEY"),
  openai_api_key: System.get_env("OPENAI_API_KEY"),
  groq_api_key: System.get_env("GROQ_API_KEY"),

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

  # Override default provider at runtime
  default_provider: (System.get_env("OSA_DEFAULT_PROVIDER") || "ollama") |> String.to_atom(),

  # HTTP channel
  shared_secret: System.get_env("OSA_SHARED_SECRET") || "osa-dev-secret-change-me",
  require_auth: System.get_env("OSA_REQUIRE_AUTH") == "true"
