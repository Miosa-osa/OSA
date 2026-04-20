defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Cluster.Controller do
  @moduledoc """
  GenServer managing inference clusters on this host.

  One GenServer for the entire OSA session. Routes `cluster_provision_request`
  frames to the appropriate backend adapter (exo or mlx-distributed) and
  handles `cluster_stop_request`.

  Holds a map of active cluster processes:
    `%{cluster_id => %{task: Task.t(), backend: String.t(), role: atom()}}`

  Outbound frames (progress, ready, health, error) are sent via
  `FrameRouter.send_frame/1`.
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.OpenComputers.FrameRouter
  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Cluster.Exo
  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Cluster.MlxDistributed

  @health_interval_ms 15_000

  # ── Public API ───────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.merge([name: __MODULE__], opts))
  end

  @doc "Handle an inbound cluster frame dispatched by FrameRouter."
  @spec handle_frame(term()) :: :ok
  def handle_frame(frame) do
    GenServer.cast(__MODULE__, {:inbound, frame})
  end

  # ── GenServer ────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    schedule_health_tick()
    {:ok, %{clusters: %{}}}
  end

  @impl true
  def handle_cast({:inbound, {:cluster_provision_request, payload}}, state) do
    cluster_id = payload.cluster_id
    backend = payload.backend
    role = payload.role

    Logger.info("[Cluster.Controller] provision cluster=#{cluster_id} backend=#{backend} role=#{role}")

    # Spawn provisioning in a supervised Task — do NOT block the GenServer
    controller_pid = self()
    task =
      Task.async(fn ->
        result =
          case backend do
            "exo" ->
              Exo.provision(%{
                cluster_id: cluster_id,
                model: payload.model,
                role: role,
                peers: payload.peers,
                leader: payload.leader
              })

            "mlx-distributed" ->
              MlxDistributed.provision(%{
                cluster_id: cluster_id,
                model: payload.model,
                role: role,
                peers: payload.peers,
                leader: payload.leader
              })

            other ->
              {:error, {:unknown_backend, other}}
          end

        send(controller_pid, {:provision_result, cluster_id, result})
        result
      end)

    cluster_entry = %{task: task, backend: backend, role: role, port: nil}
    {:noreply, put_in(state.clusters[cluster_id], cluster_entry)}
  end

  def handle_cast({:inbound, {:cluster_stop_request, %{cluster_id: cluster_id}}}, state) do
    Logger.info("[Cluster.Controller] stop cluster=#{cluster_id}")

    case Map.get(state.clusters, cluster_id) do
      nil ->
        Logger.warning("[Cluster.Controller] stop for unknown cluster #{cluster_id}")

      entry ->
        Task.shutdown(entry.task, :brutal_kill)

        case entry.backend do
          "exo" -> Exo.stop(cluster_id)
          "mlx-distributed" -> MlxDistributed.stop(cluster_id)
          _ -> :ok
        end
    end

    {:noreply, update_in(state.clusters, &Map.delete(&1, cluster_id))}
  end

  def handle_cast({:inbound, frame}, state) do
    Logger.debug("[Cluster.Controller] unhandled inbound frame: #{inspect(elem(frame, 0))}")
    {:noreply, state}
  end

  @impl true
  def handle_info({:provision_result, cluster_id, :ok}, state) do
    Logger.info("[Cluster.Controller] provision completed cluster=#{cluster_id}")
    {:noreply, state}
  end

  def handle_info({:provision_result, cluster_id, {:error, reason}}, state) do
    Logger.error("[Cluster.Controller] provision failed cluster=#{cluster_id} reason=#{inspect(reason)}")

    FrameRouter.send_frame(
      {:cluster_error,
       %{cluster_id: cluster_id, reason: reason, phase: :provisioning}}
    )

    {:noreply, update_in(state.clusters, &Map.delete(&1, cluster_id))}
  end

  def handle_info({:health_tick}, state) do
    Enum.each(state.clusters, fn {cluster_id, entry} ->
      health_frame =
        {:cluster_health,
         %{
           cluster_id: cluster_id,
           role: entry.role,
           mesh_peers: [],
           latency_ms: 0
         }}

      FrameRouter.send_frame(health_frame)
    end)

    schedule_health_tick()
    {:noreply, state}
  end

  # Task completion messages (Task.async)
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private ──────────────────────────────────────────────────────────────────

  defp schedule_health_tick do
    Process.send_after(self(), {:health_tick}, @health_interval_ms)
  end
end
