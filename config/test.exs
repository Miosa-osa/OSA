import Config

config :logger, level: :warning

config :optimal_system_agent, OptimalSystemAgent.Store.Repo,
  pool: Ecto.Adapters.SQL.Sandbox

# Disable LLM-tier classification in tests so deterministic paths are always
# exercised and tests remain fast, repeatable, and provider-independent.
config :optimal_system_agent, classifier_llm_enabled: false
