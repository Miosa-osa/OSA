defmodule OptimalSystemAgent.ContextMesh.Archiver do
  @moduledoc """
  Periodic archival sweep for expired ContextMesh Keepers.

  ## Schedule

  The Archiver wakes up every 30 minutes via a `Process.send_after` self-timer.
  On each sweep it:

    1. Lists all registered keepers from `OptimalSystemAgent.ContextMesh.Registry`.
    2. Fetches live stats from each Keeper process.
    3. Scores staleness via `OptimalSystemAgent.ContextMesh.Staleness`.
    4. For keepers that are `:expired` (score ≥ 75) AND were created at least
       7 days ago, it:
         a. Persists the keeper state (calls `persist_keeper/1`).
         b. Stops the keeper process via the `Supervisor`.
         c. Broadcasts an `:archived` signal via PubSub.
         d. Removes the entry from the Registry.

  ## Persistence

  `persist_keeper/1` is intentionally thin — it records the archival event in
  the OSA event bus. Concrete DB persistence is left to a plug-in flush
  callback on the Keeper itself (see `Keeper.start_link/1` `:flush_fn`).

  ## Crash Safety

  Errors during individual keeper archival are caught and logged so a single
  bad keeper does not abort the entire sweep.
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.ContextMesh.{Registry, Staleness, Supervisor, Keeper}

  @check_interval_ms 30 * 60 * 1_000
  @archive_min_age_days 7
  @archive_staleness_threshold 75

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc "Start the Archiver GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Trigger an archival sweep immediately (useful for tests or manual admin
  operations). Returns the number of keepers archived.
  """
  @spec sweep() :: {:ok, non_neg_integer()}
  def sweep do
    GenServer.call(__MODULE__, :sweep, 120_000)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    schedule_check()
    Logger.info("[ContextMesh.Archiver] started (interval=#{@check_interval_ms}ms)")
    {:ok, %{archived_total: 0}}
  end

  @impl true
  def handle_info(:check, state) do
    archived = do_sweep()
    schedule_check()
    {:noreply, %{state | archived_total: state.archived_total + archived}}
  end

  @impl true
  def handle_call(:sweep, _from, state) do
    archived = do_sweep()
    {:reply, {:ok, archived}, %{state | archived_total: state.archived_total + archived}}
  end

  # ---------------------------------------------------------------------------
  # Sweep logic
  # ---------------------------------------------------------------------------

  defp do_sweep do
    all_keepers = Registry.list_all()

    Logger.debug("[ContextMesh.Archiver] sweep — checking #{length(all_keepers)} keepers")

    archive_candidates =
      Enum.filter(all_keepers, fn meta ->
        old_enough?(meta) and staleness_expired?(meta)
      end)

    Enum.reduce(archive_candidates, 0, fn meta, count ->
      case archive_keeper(meta) do
        :ok -> count + 1
        {:error, _} -> count
      end
    end)
  end

  defp old_enough?(%{created_at: created_at}) do
    case created_at do
      %DateTime{} ->
        age_days = DateTime.diff(DateTime.utc_now(), created_at, :second) / 86_400
        age_days >= @archive_min_age_days

      _ ->
        false
    end
  end

  defp old_enough?(_), do: false

  defp staleness_expired?(%{staleness: score}) when is_integer(score) do
    score >= @archive_staleness_threshold
  end

  defp staleness_expired?(meta) do
    # staleness field missing — fetch live stats to compute it
    team_id = Map.get(meta, :team_id)
    keeper_id = Map.get(meta, :keeper_id)

    try do
      stats = Keeper.stats(team_id, keeper_id)
      {score, _} = Staleness.compute_staleness(stats)
      score >= @archive_staleness_threshold
    rescue
      _ -> false
    catch
      :exit, _ -> false
    end
  end

  defp archive_keeper(%{team_id: team_id, keeper_id: keeper_id} = meta) do
    Logger.info(
      "[ContextMesh.Archiver] archiving keeper team=#{team_id} id=#{keeper_id} " <>
        "staleness=#{Map.get(meta, :staleness, "?")}"
    )

    # 1. Persist state before stopping the process
    with :ok <- persist_keeper(team_id, keeper_id) do
      # 2. Stop the keeper via DynamicSupervisor
      Supervisor.stop_keeper(team_id, keeper_id)

      # 3. Broadcast archival event
      broadcast_archived(team_id, keeper_id)

      # 4. Remove from registry
      Registry.unregister(team_id, keeper_id)

      Logger.info("[ContextMesh.Archiver] archived team=#{team_id} id=#{keeper_id}")
      :ok
    end
  rescue
    e ->
      Logger.warning(
        "[ContextMesh.Archiver] failed to archive team=#{team_id} id=#{keeper_id}: " <>
          Exception.message(e)
      )

      {:error, Exception.message(e)}
  end

  # ---------------------------------------------------------------------------
  # Persistence
  # ---------------------------------------------------------------------------

  # Emit an archival event on the OSA event bus. Concrete storage is handled
  # by the Keeper's flush_fn at process termination.
  defp persist_keeper(team_id, keeper_id) do
    event = %{
      type: :context_keeper_archived,
      team_id: team_id,
      keeper_id: keeper_id,
      archived_at: DateTime.utc_now()
    }

    try do
      OptimalSystemAgent.Events.Bus.emit(:system_event, Map.put(event, :channel, :context_mesh))
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # PubSub broadcast
  # ---------------------------------------------------------------------------

  defp broadcast_archived(team_id, keeper_id) do
    try do
      Phoenix.PubSub.broadcast(
        OptimalSystemAgent.PubSub,
        "osa:context_mesh:#{team_id}",
        {:keeper_archived, %{team_id: team_id, keeper_id: keeper_id, at: DateTime.utc_now()}}
      )
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Timer
  # ---------------------------------------------------------------------------

  defp schedule_check do
    Process.send_after(self(), :check, @check_interval_ms)
  end
end
