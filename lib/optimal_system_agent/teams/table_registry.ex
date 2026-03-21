defmodule OptimalSystemAgent.Teams.TableRegistry do
  @moduledoc """
  ETS table management for per-team state storage.

  Each team gets two named ETS tables:

    - `:"team_<id>_meta"`   — team metadata, parent/child relationships, status
    - `:"team_<id>_agents"` — agent state records keyed by agent_id

  Tables are owned by the calling process (typically the TeamManager GenServer).
  Idempotent creation: `ensure_table/1` is safe to call multiple times.
  Cleanup removes both tables atomically on team dissolution.
  """

  require Logger

  @doc "Return the atom name for the team metadata table."
  @spec meta_table(String.t()) :: atom()
  def meta_table(team_id), do: :"team_#{team_id}_meta"

  @doc "Return the atom name for the team agents table."
  @spec agents_table(String.t()) :: atom()
  def agents_table(team_id), do: :"team_#{team_id}_agents"

  @doc """
  Idempotently create both ETS tables for the given team_id.

  Safe to call multiple times — returns `:ok` whether tables already exist
  or were just created. Tables are `:public` so nervous-system processes can
  read/write without going through the owning GenServer.
  """
  @spec ensure_tables(String.t()) :: :ok
  def ensure_tables(team_id) do
    ensure_table(meta_table(team_id), :set)
    ensure_table(agents_table(team_id), :set)
    :ok
  end

  @doc "Idempotently create a single named ETS table with the given type."
  @spec ensure_table(atom(), :set | :bag | :duplicate_bag | :ordered_set) :: :ok
  def ensure_table(name, type \\ :set) do
    :ets.new(name, [:named_table, :public, type, {:read_concurrency, true}, {:write_concurrency, true}])
    :ok
  rescue
    # ArgumentError is raised when the table already exists — that is fine.
    ArgumentError -> :ok
  end

  @doc """
  Destroy both ETS tables for the given team_id.

  Safe to call even when the tables do not exist (silent no-op on missing tables).
  """
  @spec destroy_tables(String.t()) :: :ok
  def destroy_tables(team_id) do
    destroy_table(meta_table(team_id))
    destroy_table(agents_table(team_id))
    :ok
  end

  @doc "Destroy a single named ETS table. No-op when the table is already gone."
  @spec destroy_table(atom()) :: :ok
  def destroy_table(name) do
    :ets.delete(name)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Check whether both tables for the given team_id currently exist.

  Returns `true` only when both the meta and agents tables are present.
  """
  @spec tables_exist?(String.t()) :: boolean()
  def tables_exist?(team_id) do
    table_exists?(meta_table(team_id)) and table_exists?(agents_table(team_id))
  end

  @doc "Check whether a single named ETS table exists."
  @spec table_exists?(atom()) :: boolean()
  def table_exists?(name) do
    :ets.info(name) != :undefined
  end

  @doc """
  List all team_ids for which both ETS tables currently exist.

  Scans all ETS tables looking for the `_meta` suffix pattern. Useful for
  recovery after a supervisor restart to discover surviving teams.
  """
  @spec list_live_teams() :: [String.t()]
  def list_live_teams do
    :ets.all()
    |> Enum.filter(fn name ->
      name_str = to_string(name)
      String.ends_with?(name_str, "_meta") and String.starts_with?(name_str, "team_")
    end)
    |> Enum.map(fn name ->
      name
      |> to_string()
      |> String.replace_prefix("team_", "")
      |> String.replace_suffix("_meta", "")
    end)
    |> Enum.filter(&tables_exist?/1)
  rescue
    _ -> []
  end
end
