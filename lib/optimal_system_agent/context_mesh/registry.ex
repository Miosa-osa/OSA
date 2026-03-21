defmodule OptimalSystemAgent.ContextMesh.Registry do
  @moduledoc """
  ETS-backed registry of active ContextMesh Keepers.

  Maintains a single `:osa_context_mesh_keepers` ETS table where each row
  stores keeper metadata for fast lookup without hitting individual GenServer
  processes.

  ## Row structure

  Each row is keyed by `{team_id, keeper_id}` and stores:

    - `team_id`       — owning team
    - `keeper_id`     — keeper identifier within the team
    - `token_count`   — last known token count (updated on flush or stats poll)
    - `staleness`     — last computed staleness score (integer 0–100)
    - `created_at`    — when the keeper was first registered
    - `last_accessed` — when the keeper was last retrieved from

  The table is created by `init_table/0` which is called from
  `OptimalSystemAgent.Application` at boot alongside the other shared ETS
  tables.
  """

  require Logger

  @table :osa_context_mesh_keepers

  # ---------------------------------------------------------------------------
  # Boot
  # ---------------------------------------------------------------------------

  @doc "Create the ETS table. Safe to call more than once (idempotent)."
  @spec init_table() :: :ok
  def init_table do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    :ok
  rescue
    ArgumentError -> :ok
  end

  # ---------------------------------------------------------------------------
  # Registration
  # ---------------------------------------------------------------------------

  @doc """
  Register a keeper entry.

  `meta` is a map with optional keys: `token_count`, `staleness`,
  `last_accessed`.
  """
  @spec register(String.t(), String.t(), map()) :: :ok
  def register(team_id, keeper_id, meta \\ %{}) do
    now = DateTime.utc_now()

    row = {
      {team_id, keeper_id},
      %{
        team_id: team_id,
        keeper_id: keeper_id,
        token_count: Map.get(meta, :token_count, 0),
        staleness: Map.get(meta, :staleness, 0),
        created_at: Map.get(meta, :created_at, now),
        last_accessed: Map.get(meta, :last_accessed, now)
      }
    }

    :ets.insert(@table, row)
    Logger.debug("[ContextMesh.Registry] registered team=#{team_id} id=#{keeper_id}")
    :ok
  rescue
    e ->
      Logger.warning("[ContextMesh.Registry] register error: #{Exception.message(e)}")
      :ok
  end

  @doc "Remove a keeper from the registry."
  @spec unregister(String.t(), String.t()) :: :ok
  def unregister(team_id, keeper_id) do
    :ets.delete(@table, {team_id, keeper_id})
    Logger.debug("[ContextMesh.Registry] unregistered team=#{team_id} id=#{keeper_id}")
    :ok
  rescue
    e ->
      Logger.warning("[ContextMesh.Registry] unregister error: #{Exception.message(e)}")
      :ok
  end

  # ---------------------------------------------------------------------------
  # Lookup
  # ---------------------------------------------------------------------------

  @doc "Look up metadata for a specific keeper. Returns `nil` if not found."
  @spec lookup(String.t(), String.t()) :: map() | nil
  def lookup(team_id, keeper_id) do
    case :ets.lookup(@table, {team_id, keeper_id}) do
      [{_, meta}] -> meta
      [] -> nil
    end
  rescue
    _ -> nil
  end

  @doc "Return all registered keepers for a given team."
  @spec list_by_team(String.t()) :: [map()]
  def list_by_team(team_id) do
    :ets.match_object(@table, {{team_id, :_}, :_})
    |> Enum.map(fn {_, meta} -> meta end)
    |> Enum.sort_by(& &1.created_at)
  rescue
    _ -> []
  end

  @doc "Return all registered keepers across all teams."
  @spec list_all() :: [map()]
  def list_all do
    :ets.tab2list(@table)
    |> Enum.map(fn {_, meta} -> meta end)
    |> Enum.sort_by(& &1.created_at)
  rescue
    _ -> []
  end

  # ---------------------------------------------------------------------------
  # Metadata updates
  # ---------------------------------------------------------------------------

  @doc "Update a subset of metadata fields for an existing registry entry."
  @spec update(String.t(), String.t(), map()) :: :ok
  def update(team_id, keeper_id, updates) when is_map(updates) do
    case lookup(team_id, keeper_id) do
      nil ->
        :ok

      existing ->
        :ets.insert(@table, {{team_id, keeper_id}, Map.merge(existing, updates)})
        :ok
    end
  rescue
    _ -> :ok
  end

  @doc "Refresh the `token_count` and `staleness` fields from a live keeper stats map."
  @spec refresh_from_stats(String.t(), String.t(), map()) :: :ok
  def refresh_from_stats(team_id, keeper_id, stats) when is_map(stats) do
    {staleness_score, _} =
      OptimalSystemAgent.ContextMesh.Staleness.compute_staleness(stats)

    update(team_id, keeper_id, %{
      token_count: Map.get(stats, :token_count, 0),
      staleness: staleness_score,
      last_accessed: Map.get(stats, :last_accessed_at, DateTime.utc_now())
    })
  end
end
