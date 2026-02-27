import Config

config :logger, level: :warning

config :optimal_system_agent, OptimalSystemAgent.Store.Repo, pool: Ecto.Adapters.SQL.Sandbox

# Disable LLM-tier classification in tests so deterministic paths are always
# exercised and tests remain fast, repeatable, and provider-independent.
config :optimal_system_agent, classifier_llm_enabled: false

# Use a different HTTP port in tests to avoid conflicts
config :optimal_system_agent, http_port: 0

# Stable shared secret for test token generation/verification
config :optimal_system_agent, shared_secret: "osa-dev-secret-change-me"
