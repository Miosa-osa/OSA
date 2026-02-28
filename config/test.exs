import Config

config :logger, level: :warning

config :optimal_system_agent, OptimalSystemAgent.Store.Repo, pool: Ecto.Adapters.SQL.Sandbox

# Disable all LLM calls in tests so deterministic paths are always
# exercised and tests remain fast, repeatable, and provider-independent.
config :optimal_system_agent, classifier_llm_enabled: false
config :optimal_system_agent, compactor_llm_enabled: false
config :optimal_system_agent, noise_filter_llm_enabled: false

# Use a different HTTP port in tests to avoid conflicts
config :optimal_system_agent, http_port: 0

# Per-run test secret — no hardcoded secrets
config :optimal_system_agent,
  shared_secret: "osa-test-#{:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)}"
