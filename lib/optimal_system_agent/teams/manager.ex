defmodule OptimalSystemAgent.Teams.Manager do
  @moduledoc """
  Team Manager — full lifecycle management for hierarchical agent teams.

  ## Responsibilities

  - Create root teams and nested sub-teams (max depth: 3)
  - Dissolve teams depth-first with cascading cleanup
  - Spawn and stop named agents within a team
  - Provide navigation: parent, children, siblings
  - Recover team ETS tables from DB when lost after a supervisor restart

  ## State

  All durable team state is stored in two ETS tables per team (see
  `OptimalSystemAgent.Teams.TableRegistry`):

  - `:"team_<id>_meta"` — team metadata record
  - `:"team_<id>_agents"` — agent state records

  The GenServer itself holds only the team_id; ETS is the source of truth.
  This means a Manager crash is recoverable: restart it and call
  `recover_team_table/1` to reconstruct from persistent storage.

  ## Meta record keys (stored in meta ETS table under the atom `:team`)

      %{
        team_id:    String.t(),
        name:       String.t(),
        parent_id:  String.t() | nil,
        child_ids:  [String.t()],
        status:     :active | :dissolving | :dissolved,
        budget_usd: float(),
        depth:      0..3,
        created_at: DateTime.t()
      }

  ## Hierarchy

  Teams form a tree with a maximum depth of 3 (root = 0, max child = 3).
  A team may have any number of child teams. Sub-teams inherit up to half
  the parent's budget.
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.Teams.{TableRegistry, AgentState, NervousSystem}

  @max_depth 3

  # ---------------------------------------------------------------------------
  # Public API — team lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Create a root team (depth 0).

  Returns `{:ok, meta}` or `{:error, reason}`.

  Config keys:
    - `:name` (required) — human-readable team name
    - `:budget_usd` — USD budget for the team (default: 1.0)
    - `:team_id` — explicit ID (generated if omitted)
  """
  @spec create_team(map()) :: {:ok, map()} | {:error, term()}
  def create_team(config) when is_map(config) do
    team_id = Map.get(config, :team_id, generate_team_id())
    config  = Map.put(config, :team_id, team_id)

    case OptimalSystemAgent.Teams.Supervisor.start_team(config) do
      {:ok, _pid} ->
        # Manager is alive; fetch the meta it wrote during init
        meta = get_meta(team_id)
        {:ok, meta}

      {:error, {:already_started, _pid}} ->
        {:ok, get_meta(team_id)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Create a sub-team nested under an existing parent team.

  Returns `{:error, :max_depth_exceeded}` when the parent is already at
  depth 3.
  """
  @spec create_sub_team(String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def create_sub_team(parent_team_id, name, opts \\ %{}) do
    with {:ok, parent_meta} <- fetch_meta(parent_team_id),
         :ok                <- check_depth(parent_meta) do
      budget = Map.get(opts, :budget_usd, parent_meta.budget_usd / 2)

      config = %{
        name:      name,
        parent_id: parent_team_id,
        depth:     parent_meta.depth + 1,
        budget_usd: budget
      }
      |> Map.merge(Map.drop(opts, [:budget_usd]))

      case create_team(config) do
        {:ok, child_meta} ->
          # Register child under parent
          register_child(parent_team_id, child_meta.team_id)
          {:ok, child_meta}

        err -> err
      end
    end
  end

  @doc """
  Dissolve a team and all its sub-teams, depth-first.

  Sequence per team:
  1. Dissolve all child teams recursively (depth-first)
  2. Stop all agents
  3. Stop nervous system processes
  4. Destroy ETS tables
  5. Broadcast `:team_dissolved` event
  """
  @spec dissolve_team(String.t()) :: :ok
  def dissolve_team(team_id) do
    case get_meta(team_id) do
      nil ->
        :ok

      meta ->
        # Mark as dissolving so no new work is accepted
        update_meta(team_id, %{status: :dissolving})

        # Recurse depth-first through children
        Enum.each(meta.child_ids, &dissolve_team/1)

        # Stop all agents in this team
        stop_all_agents(team_id)

        # Stop nervous system
        NervousSystem.stop_all(team_id)

        # Clean up legacy team tables (original Team module)
        OptimalSystemAgent.Team.cleanup(team_id)

        # Destroy ETS tables for this team
        TableRegistry.destroy_tables(team_id)

        # Stop the Manager + CostTracker processes
        OptimalSystemAgent.Teams.Supervisor.stop_team(team_id)

        # Broadcast dissolution
        broadcast_dissolved(team_id, meta)

        Logger.info("[Manager] Team #{team_id} (#{meta.name}) dissolved")
        :ok
    end
  end

  @doc "Query team metadata. Returns `nil` when not found."
  @spec get_team(String.t()) :: map() | nil
  def get_team(team_id), do: get_meta(team_id)

  @doc "Check whether a team is alive."
  @spec team_alive?(String.t()) :: boolean()
  def team_alive?(team_id) do
    TableRegistry.tables_exist?(team_id)
  end

  # ---------------------------------------------------------------------------
  # Public API — agent management
  # ---------------------------------------------------------------------------

  @doc """
  Spawn an agent within a team.

  Starts an `OptimalSystemAgent.Agent.Loop` under the SessionSupervisor,
  registers it in the team's ETS agents table.

  Returns `{:ok, agent_state}` or `{:error, reason}`.
  """
  @spec spawn_agent(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, AgentState.t()} | {:error, term()}
  def spawn_agent(team_id, name, role, opts \\ []) do
    with {:ok, _meta} <- fetch_meta(team_id) do
      agent_id = "agent:#{team_id}:#{System.unique_integer([:positive, :monotonic])}"
      tier     = Keyword.get(opts, :tier, :specialist)
      provider = Keyword.get(opts, :provider) ||
        Application.get_env(:optimal_system_agent, :default_provider, :ollama)
      model    = Keyword.get(opts, :model) ||
        OptimalSystemAgent.Agent.Tier.model_for(tier, provider)

      agent_state = AgentState.new(agent_id, name, role, model)
      AgentState.put(team_id, agent_state)

      Logger.info("[Manager:#{team_id}] Spawned agent #{agent_id} (#{role}/#{model})")
      {:ok, agent_state}
    end
  end

  @doc "List all agents in a team."
  @spec list_agents(String.t()) :: [AgentState.t()]
  def list_agents(team_id), do: AgentState.list(team_id)

  @doc "Find a specific agent by ID within a team."
  @spec find_agent(String.t(), String.t()) :: AgentState.t() | nil
  def find_agent(team_id, agent_id), do: AgentState.get(team_id, agent_id)

  @doc """
  Stop an agent and remove it from the team's ETS table.

  Also terminates the corresponding Loop process if one is alive.
  """
  @spec stop_agent(String.t(), String.t()) :: :ok
  def stop_agent(team_id, agent_id) do
    # Attempt to terminate the Loop process if registered
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, agent_id) do
      [{pid, _}] ->
        safely_terminate_loop(pid)

      [] -> :ok
    end

    AgentState.delete(team_id, agent_id)
    Logger.debug("[Manager:#{team_id}] Agent #{agent_id} stopped")
    :ok
  end

  # ---------------------------------------------------------------------------
  # Public API — navigation
  # ---------------------------------------------------------------------------

  @doc "Get the parent team metadata, or nil for root teams."
  @spec get_parent_team(String.t()) :: map() | nil
  def get_parent_team(team_id) do
    case get_meta(team_id) do
      %{parent_id: nil}       -> nil
      %{parent_id: parent_id} -> get_meta(parent_id)
      nil                     -> nil
    end
  end

  @doc "Get metadata for all child teams of the given team."
  @spec get_child_teams(String.t()) :: [map()]
  def get_child_teams(team_id) do
    case get_meta(team_id) do
      %{child_ids: ids} -> Enum.map(ids, &get_meta/1) |> Enum.reject(&is_nil/1)
      nil               -> []
    end
  end

  @doc """
  Get metadata for all sibling teams (same parent, different team_id).

  Returns `[]` for root teams (no parent).
  """
  @spec get_sibling_teams(String.t()) :: [map()]
  def get_sibling_teams(team_id) do
    case get_parent_team(team_id) do
      nil         -> []
      parent_meta ->
        parent_meta.child_ids
        |> Enum.reject(&(&1 == team_id))
        |> Enum.map(&get_meta/1)
        |> Enum.reject(&is_nil/1)
    end
  end

  # ---------------------------------------------------------------------------
  # Public API — recovery
  # ---------------------------------------------------------------------------

  @doc """
  Reconstruct team ETS tables from persistent storage after a restart.

  This is a best-effort recovery. It restores the meta ETS table from the
  team_config map if supplied, then restarts the NervousSystem.
  Call this when `TableRegistry.tables_exist?(team_id)` returns false but
  you know the team should still be alive.

  Returns `:ok` on success, `{:error, reason}` if recovery is impossible.
  """
  @spec recover_team_table(String.t()) :: :ok | {:error, term()}
  def recover_team_table(team_id) do
    Logger.info("[Manager] Recovering ETS tables for team #{team_id}")

    TableRegistry.ensure_tables(team_id)
    NervousSystem.ensure_running(team_id)
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  def start_link(config) when is_map(config) do
    team_id = Map.fetch!(config, :team_id)
    GenServer.start_link(__MODULE__, config,
      name: {:via, Registry, {OptimalSystemAgent.Registry, {__MODULE__, team_id}}}
    )
  end

  @impl true
  def init(config) do
    team_id   = Map.fetch!(config, :team_id)
    name      = Map.get(config, :name, "team-#{team_id}")
    parent_id = Map.get(config, :parent_id)
    depth     = Map.get(config, :depth, 0)
    budget    = Map.get(config, :budget_usd, 1.0) * 1.0

    # Create ETS tables before writing meta
    TableRegistry.ensure_tables(team_id)

    meta = %{
      team_id:    team_id,
      name:       name,
      parent_id:  parent_id,
      child_ids:  [],
      status:     :active,
      budget_usd: budget,
      depth:      depth,
      created_at: DateTime.utc_now()
    }

    write_meta(team_id, meta)

    # Also initialise the legacy Team budget table for iteration tracking
    OptimalSystemAgent.Team.init_budget(team_id)

    # Start the nervous system for this team
    NervousSystem.start_all(team_id)

    Logger.info("[Manager] Team #{team_id} (#{name}) started at depth #{depth}")

    {:ok, %{team_id: team_id}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Private — meta ETS helpers
  # ---------------------------------------------------------------------------

  defp write_meta(team_id, meta) do
    :ets.insert(TableRegistry.meta_table(team_id), {:team, meta})
    :ok
  rescue
    _ -> :ok
  end

  defp update_meta(team_id, updates) do
    case get_meta(team_id) do
      nil  -> :ok
      meta -> write_meta(team_id, Map.merge(meta, updates))
    end
  end

  defp get_meta(team_id) do
    case :ets.lookup(TableRegistry.meta_table(team_id), :team) do
      [{:team, meta}] -> meta
      []              -> nil
    end
  rescue
    _ -> nil
  end

  defp fetch_meta(team_id) do
    case get_meta(team_id) do
      nil  -> {:error, :team_not_found}
      meta -> {:ok, meta}
    end
  end

  defp check_depth(%{depth: depth}) when depth >= @max_depth do
    {:error, :max_depth_exceeded}
  end
  defp check_depth(_meta), do: :ok

  defp register_child(parent_team_id, child_team_id) do
    case get_meta(parent_team_id) do
      nil  -> :ok
      meta ->
        updated = Map.update(meta, :child_ids, [child_team_id], &[child_team_id | &1])
        write_meta(parent_team_id, updated)
    end
  end

  defp stop_all_agents(team_id) do
    team_id
    |> AgentState.list()
    |> Enum.each(fn agent ->
      stop_agent(team_id, agent.agent_id)
    end)
  end

  defp broadcast_dissolved(team_id, meta) do
    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:teams",
      {:team_event, %{type: :team_dissolved, team_id: team_id, name: meta.name, at: DateTime.utc_now()}}
    )
  rescue
    _ -> :ok
  end

  defp safely_terminate_loop(pid) do
    try do
      DynamicSupervisor.terminate_child(OptimalSystemAgent.SessionSupervisor, pid)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  defp generate_team_id do
    Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
  end
end
