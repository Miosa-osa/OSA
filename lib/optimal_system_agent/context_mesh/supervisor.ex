defmodule OptimalSystemAgent.ContextMesh.Supervisor do
  @moduledoc """
  DynamicSupervisor that manages per-team ContextMesh Keeper processes.

  Keepers are started on demand when a team first needs context storage and
  terminated either manually via `stop_keeper/2` or automatically by
  `OptimalSystemAgent.ContextMesh.Archiver` after they reach the `:expired`
  staleness state and exceed the minimum retention age.

  ## Registration

  When a Keeper is started it is automatically registered in
  `OptimalSystemAgent.ContextMesh.Registry`. When it stops (for any reason)
  it is unregistered in the same call so the Registry remains consistent.

  ## Process naming

  Keepers are registered in `OptimalSystemAgent.ContextMesh.KeeperRegistry`
  (a `Registry` process started alongside this supervisor) under the key
  `{team_id, keeper_id}`.
  """

  use DynamicSupervisor
  require Logger

  alias OptimalSystemAgent.ContextMesh.{Keeper, Registry}

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc "Start the DynamicSupervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Start a Keeper for `team_id` / `keeper_id`.

  Options are forwarded directly to `Keeper.start_link/1`. Returns
  `{:ok, pid}` or `{:error, {:already_started, pid}}` if one is already
  running.
  """
  @spec start_keeper(String.t(), String.t(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def start_keeper(team_id, keeper_id \\ nil, opts \\ []) do
    keeper_id = keeper_id || team_id

    child_opts =
      opts
      |> Keyword.put(:team_id, team_id)
      |> Keyword.put(:keeper_id, keeper_id)
      |> Keyword.put_new(:flush_fn, default_flush_fn(team_id, keeper_id))

    spec = {Keeper, child_opts}

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} ->
        Registry.register(team_id, keeper_id)
        Logger.info("[ContextMesh.Supervisor] started keeper team=#{team_id} id=#{keeper_id}")
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Logger.debug(
          "[ContextMesh.Supervisor] keeper already running team=#{team_id} id=#{keeper_id}"
        )

        {:ok, pid}

      {:error, reason} = err ->
        Logger.warning(
          "[ContextMesh.Supervisor] failed to start keeper team=#{team_id} id=#{keeper_id}: " <>
            inspect(reason)
        )

        err
    end
  end

  @doc """
  Stop the Keeper for `team_id` / `keeper_id`.

  The keeper's `terminate/2` callback will flush any dirty state before the
  process exits. Removes the entry from the Registry on success.
  """
  @spec stop_keeper(String.t(), String.t()) :: :ok | {:error, term()}
  def stop_keeper(team_id, keeper_id \\ nil) do
    keeper_id = keeper_id || team_id

    pid = keeper_pid(team_id, keeper_id)

    if pid do
      result = DynamicSupervisor.terminate_child(__MODULE__, pid)
      Registry.unregister(team_id, keeper_id)

      Logger.info("[ContextMesh.Supervisor] stopped keeper team=#{team_id} id=#{keeper_id}")
      result
    else
      Logger.debug(
        "[ContextMesh.Supervisor] stop_keeper: no process found team=#{team_id} id=#{keeper_id}"
      )

      :ok
    end
  end

  @doc """
  Return the pid of a running Keeper, or `nil` if not found.
  """
  @spec keeper_pid(String.t(), String.t()) :: pid() | nil
  def keeper_pid(team_id, keeper_id \\ nil) do
    keeper_id = keeper_id || team_id

    case Elixir.Registry.lookup(
           OptimalSystemAgent.ContextMesh.KeeperRegistry,
           {team_id, keeper_id}
         ) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Return a list of all active keeper pids under this supervisor."
  @spec list_keepers() :: [pid()]
  def list_keepers do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.flat_map(fn
      {_, pid, :worker, _} when is_pid(pid) -> [pid]
      _ -> []
    end)
  end

  # ---------------------------------------------------------------------------
  # DynamicSupervisor callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Default flush_fn: refresh Registry metadata from the keeper's stats.
  defp default_flush_fn(team_id, keeper_id) do
    fn state ->
      Registry.refresh_from_stats(team_id, keeper_id, Map.from_struct(state))
    end
  end
end
