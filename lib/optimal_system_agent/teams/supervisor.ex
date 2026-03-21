defmodule OptimalSystemAgent.Teams.Supervisor do
  @moduledoc """
  DynamicSupervisor for team processes.

  Supervises:
  - One `OptimalSystemAgent.Teams.Manager` per live team
  - All 8 `NervousSystem` sub-processes per team
  - `CostTracker` GenServer per team

  All children are started with `strategy: :one_for_one` so a crash in one
  team's processes does not affect any other team's processes.

  Use `start_team/1` and `stop_team/1` from callers rather than interacting
  with the DynamicSupervisor directly.
  """

  use DynamicSupervisor
  require Logger

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc """
  Start the Manager + CostTracker for a team.

  The Manager in turn calls `NervousSystem.start_all/1` during its `init/1`,
  so all 8 nervous-system processes are also started here.
  """
  @spec start_team(map()) :: {:ok, pid()} | {:error, term()}
  def start_team(team_config) when is_map(team_config) do
    team_id = Map.fetch!(team_config, :team_id)

    # Start CostTracker first — Manager may reference it during init
    cost_opts = [
      team_id:    team_id,
      budget_usd: Map.get(team_config, :budget_usd, 1.0)
    ]

    case DynamicSupervisor.start_child(__MODULE__, {OptimalSystemAgent.Teams.CostTracker, cost_opts}) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} ->
        Logger.warning("[Teams.Supervisor] CostTracker start failed for #{team_id}: #{inspect(reason)}")
    end

    # Start the Manager (which also starts NervousSystem processes)
    DynamicSupervisor.start_child(__MODULE__, {OptimalSystemAgent.Teams.Manager, team_config})
  end

  @doc "Stop all processes belonging to a team."
  @spec stop_team(String.t()) :: :ok
  def stop_team(team_id) do
    # Stop nervous system processes
    OptimalSystemAgent.Teams.NervousSystem.stop_all(team_id)

    # Stop CostTracker
    terminate_via(OptimalSystemAgent.Teams.CostTracker, team_id)

    # Stop Manager last
    terminate_via(OptimalSystemAgent.Teams.Manager, team_id)

    :ok
  end

  # ---------------------------------------------------------------------------
  # DynamicSupervisor callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp terminate_via(module, team_id) do
    case Registry.lookup(OptimalSystemAgent.Registry, {module, team_id}) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)
        |> tap(fn result ->
          Logger.debug("[Teams.Supervisor] Terminated #{inspect(module)} for #{team_id}: #{inspect(result)}")
        end)

      [] -> :ok
    end
  end
end
