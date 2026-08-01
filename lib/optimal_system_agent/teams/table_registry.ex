defmodule OptimalSystemAgent.Teams.TableRegistry do
  @moduledoc """
  ETS storage for per-team state.

  Two FIXED, globally-named tables hold every team's state, partitioned by a
  composite key:

    - `:osa_team_meta`   — `{{team_id, :team}, meta}` (plus a presence marker)
    - `:osa_team_agents` — `{{team_id, agent_id}, agent_state}`

  ## Why fixed tables and not one table per team

  This module used to mint the table names dynamically —
  `:"team_<id>_meta"` and `:"team_<id>_agents"` — one brand-new atom per team,
  per table. Atoms are **never garbage collected**, and the BEAM atom table is a
  hard, fixed-size limit (`+t`, default ~1,048,576): once it fills, the VM
  aborts with `system_limit`. Every other unbounded-growth issue in this
  codebase degrades performance; this one is the only class that ends in an
  unrecoverable crash, and it needed no attacker — a long-running daemon that
  creates and dissolves teams gets there on its own, because dissolving a team
  frees its ETS table but can never free its name.

  The same class was fixed once already in `Agent.Scheduler` (see
  `String.to_existing_atom` there, with the comment "prevent atom table
  exhaustion"). This follows that precedent, taking the stronger of the two
  options: a fixed table plus a key creates NO atoms at all, so team ids stay
  free-form and unbounded without ever touching the atom table.

  Tables are `:public` so nervous-system processes can read/write without going
  through the owning GenServer. They are created on demand and, unlike the old
  per-team tables, are never destroyed — `destroy_tables/1` deletes a team's
  ROWS, which is what dissolution actually needs.
  """

  require Logger

  @meta_table :osa_team_meta
  @agents_table :osa_team_agents

  # Marker row proving a team was set up, so `tables_exist?/1` keeps meaning
  # "this team has storage" now that the tables themselves are global and always
  # present. Written by `ensure_tables/1`, removed by `destroy_tables/1`.
  @presence :__present__

  @doc "The fixed ETS table holding every team's metadata."
  @spec meta_table() :: atom()
  def meta_table, do: @meta_table

  @doc "The fixed ETS table holding every team's agent-state records."
  @spec agents_table() :: atom()
  def agents_table, do: @agents_table

  @doc "Key for a team's metadata row in `meta_table/0`."
  @spec meta_key(String.t()) :: {String.t(), :team}
  def meta_key(team_id), do: {team_id, :team}

  @doc "Key for one agent's state row in `agents_table/0`."
  @spec agent_key(String.t(), String.t()) :: {String.t(), String.t()}
  def agent_key(team_id, agent_id), do: {team_id, agent_id}

  @doc """
  Idempotently create the shared tables and mark `team_id` as present.

  Safe to call any number of times, from any process.
  """
  @spec ensure_tables(String.t()) :: :ok
  def ensure_tables(team_id) do
    ensure_table(@meta_table)
    ensure_table(@agents_table)
    :ets.insert(@meta_table, {{team_id, @presence}, true})
    :ok
  rescue
    _ -> :ok
  end

  @doc "Idempotently create one of the shared named ETS tables."
  @spec ensure_table(atom()) :: :ok
  def ensure_table(name) do
    :ets.new(name, [
      :named_table,
      :public,
      :set,
      {:read_concurrency, true},
      {:write_concurrency, true}
    ])

    :ok
  rescue
    # ArgumentError is raised when the table already exists — that is fine.
    ArgumentError -> :ok
  end

  @doc """
  Remove ALL rows belonging to `team_id` (metadata, presence marker, and every
  agent-state record).

  Replaces the old `:ets.delete/1` of two per-team tables. The shared tables
  themselves survive — they are storage for every other live team.

  Safe to call for a team that was never created.
  """
  @spec destroy_tables(String.t()) :: :ok
  def destroy_tables(team_id) do
    ensure_table(@meta_table)
    ensure_table(@agents_table)

    # `:"$1"` matches any second key element, so this deletes {team_id, :team},
    # {team_id, :__present__} and every {team_id, agent_id} row in one pass.
    _ = :ets.match_delete(@meta_table, {{team_id, :"$1"}, :_})
    _ = :ets.match_delete(@agents_table, {{team_id, :"$1"}, :_})
    :ok
  rescue
    _ -> :ok
  end

  @doc "Whether `team_id` currently has storage set up."
  @spec tables_exist?(String.t()) :: boolean()
  def tables_exist?(team_id) do
    :ets.lookup(@meta_table, {team_id, @presence}) != []
  rescue
    _ -> false
  end

  @doc "Whether one of the shared named ETS tables exists yet."
  @spec table_exists?(atom()) :: boolean()
  def table_exists?(name), do: :ets.info(name) != :undefined

  @doc """
  Every team_id that currently has storage.

  Reads presence markers out of the shared meta table instead of scanning
  `:ets.all/0` for a name pattern. Useful for recovery after a supervisor
  restart, to discover surviving teams.
  """
  @spec list_live_teams() :: [String.t()]
  def list_live_teams do
    @meta_table
    |> :ets.match({{:"$1", @presence}, :_})
    |> Enum.map(fn [team_id] -> team_id end)
  rescue
    _ -> []
  end

  @doc """
  Number of rows stored for `team_id` — diagnostics, and the handle tests use
  to assert dissolution actually frees storage.
  """
  @spec row_count(String.t()) :: non_neg_integer()
  def row_count(team_id) do
    meta = @meta_table |> :ets.match({{team_id, :"$1"}, :_}) |> length()
    agents = @agents_table |> :ets.match({{team_id, :"$1"}, :_}) |> length()
    meta + agents
  rescue
    _ -> 0
  end
end
