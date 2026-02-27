defmodule OptimalSystemAgent.Sidecar.Registry do
  @moduledoc """
  ETS-backed registry for active sidecar processes.

  Tracks which sidecars are running, their health status, and their capabilities.
  Used by `Sidecar.Manager` to route requests by capability (e.g., "who can do
  tokenization?") and by health monitoring to track degradation.

  Table: `:osa_sidecar_registry` — `{name, pid, health, capabilities, updated_at}`
  """

  @table :osa_sidecar_registry

  @doc "Initialize the registry ETS table. Idempotent."
  def init do
    case :ets.info(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  end

  @doc "Register a sidecar with its capabilities."
  @spec register(module(), [atom()]) :: :ok
  def register(name, capabilities) when is_atom(name) and is_list(capabilities) do
    ensure_table()
    pid = Process.whereis(name)

    :ets.insert(@table, {
      name,
      pid,
      :starting,
      capabilities,
      System.monotonic_time(:millisecond)
    })

    :ok
  end

  @doc "Update the health status of a registered sidecar."
  @spec update_health(module(), :ready | :starting | :degraded | :unavailable) :: :ok
  def update_health(name, health) when is_atom(name) do
    ensure_table()

    case :ets.lookup(@table, name) do
      [{^name, pid, _old_health, caps, _ts}] ->
        :ets.insert(@table, {name, pid, health, caps, System.monotonic_time(:millisecond)})
        :ok

      [] ->
        :ok
    end
  end

  @doc "Find all sidecars that provide a given capability."
  @spec find_by_capability(atom()) :: [{module(), pid() | nil, atom()}]
  def find_by_capability(capability) when is_atom(capability) do
    ensure_table()

    :ets.tab2list(@table)
    |> Enum.filter(fn {_name, _pid, _health, caps, _ts} -> capability in caps end)
    |> Enum.map(fn {name, pid, health, _caps, _ts} -> {name, pid, health} end)
  end

  @doc "Return all registered sidecars with their status."
  @spec all() :: [map()]
  def all do
    ensure_table()

    :ets.tab2list(@table)
    |> Enum.map(fn {name, pid, health, caps, updated_at} ->
      %{
        name: name,
        pid: pid,
        health: health,
        capabilities: caps,
        updated_at: updated_at
      }
    end)
  end

  @doc "Remove a sidecar from the registry."
  @spec unregister(module()) :: :ok
  def unregister(name) when is_atom(name) do
    ensure_table()
    :ets.delete(@table, name)
    :ok
  end

  defp ensure_table do
    case :ets.info(@table) do
      :undefined -> init()
      _ -> :ok
    end
  end
end
