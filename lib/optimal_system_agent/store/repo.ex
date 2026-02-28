defmodule OptimalSystemAgent.Store.Repo do
  use Ecto.Repo,
    otp_app: :optimal_system_agent,
    adapter: Ecto.Adapters.SQLite3

  @doc """
  Runtime init callback — ensures UTF-8 encoding pragma is always present.

  The `custom_pragmas` option is set in config.exs, but this callback
  guarantees the setting survives any config override (e.g. test env)
  and is always injected at startup.
  """
  @impl true
  def init(_type, config) do
    # Merge UTF-8 pragma into any existing custom_pragmas
    existing = Keyword.get(config, :custom_pragmas, [])

    pragmas =
      existing
      |> Keyword.put_new(:encoding, "'UTF-8'")

    {:ok, Keyword.put(config, :custom_pragmas, pragmas)}
  end
end
