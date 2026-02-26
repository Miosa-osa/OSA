defmodule OptimalSystemAgent.Store.Repo do
  use Ecto.Repo,
    otp_app: :optimal_system_agent,
    adapter: Ecto.Adapters.SQLite3
end
