import Config

config :logger, level: :warning

config :optimal_system_agent, OptimalSystemAgent.Store.Repo,
  pool: Ecto.Adapters.SQL.Sandbox
