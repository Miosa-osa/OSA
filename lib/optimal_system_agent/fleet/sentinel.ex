defmodule OptimalSystemAgent.Fleet.Sentinel do
  @moduledoc """
  Per-agent digital twin — a GenServer started by DynamicSupervisor.

  Tracks real-time metrics for a single remote agent: CPU, memory, disk,
  current task, capabilities, and last heartbeat timestamp.

  Stale detection: if no heartbeat arrives within 5 minutes, the sentinel
  marks the agent as :unreachable and emits a fleet event on the bus.
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Events.Bus

  @stale_interval_ms 300_000

  defstruct agent_id: nil,
            status: :unknown,
            last_heartbeat: nil,
            cpu_load: 0.0,
            memory_mb: 0,
            disk_gb: 0.0,
            current_task: nil,
            capabilities: [],
            last_error: nil,
            stale_timer: nil

  # ── Client API ────────────────────────────────────────────────────

  def start_link(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    name = {:via, Registry, {OptimalSystemAgent.Fleet.AgentRegistry, agent_id}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Update heartbeat metrics for this sentinel."
  @spec update_heartbeat(pid(), map()) :: :ok
  def update_heartbeat(pid, metrics) when is_map(metrics) do
    GenServer.cast(pid, {:heartbeat, metrics})
  end

  @doc "Get the current status and metrics."
  @spec get_status(pid()) :: map()
  def get_status(pid) do
    GenServer.call(pid, :get_status)
  end

  @doc "Assign a task to this agent."
  @spec assign_task(pid(), any()) :: :ok
  def assign_task(pid, task) do
    GenServer.cast(pid, {:assign_task, task})
  end

  @doc "Report an error from this agent."
  @spec report_error(pid(), any()) :: :ok
  def report_error(pid, error) do
    GenServer.cast(pid, {:report_error, error})
  end

  # ── Server callbacks ──────────────────────────────────────────────

  @impl true
  def init(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    capabilities = Keyword.get(opts, :capabilities, [])

    Logger.info("[Fleet.Sentinel] Started sentinel for agent #{agent_id}")

    timer = Process.send_after(self(), :stale_check, @stale_interval_ms)

    state = %__MODULE__{
      agent_id: agent_id,
      status: :online,
      capabilities: capabilities,
      last_heartbeat: DateTime.utc_now(),
      stale_timer: timer
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:heartbeat, metrics}, state) do
    # Cancel existing stale timer and start a new one
    if state.stale_timer, do: Process.cancel_timer(state.stale_timer)
    timer = Process.send_after(self(), :stale_check, @stale_interval_ms)

    new_state = %{
      state
      | status: :online,
        last_heartbeat: DateTime.utc_now(),
        cpu_load: Map.get(metrics, :cpu_load, state.cpu_load),
        memory_mb: Map.get(metrics, :memory_mb, state.memory_mb),
        disk_gb: Map.get(metrics, :disk_gb, state.disk_gb),
        stale_timer: timer
    }

    {:noreply, new_state}
  end

  def handle_cast({:assign_task, task}, state) do
    Logger.info("[Fleet.Sentinel] Agent #{state.agent_id} assigned task: #{inspect(task)}")
    {:noreply, %{state | current_task: task}}
  end

  def handle_cast({:report_error, error}, state) do
    Logger.error("[Fleet.Sentinel] Agent #{state.agent_id} error: #{inspect(error)}")
    {:noreply, %{state | last_error: error}}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status_map = %{
      agent_id: state.agent_id,
      status: state.status,
      last_heartbeat: state.last_heartbeat,
      cpu_load: state.cpu_load,
      memory_mb: state.memory_mb,
      disk_gb: state.disk_gb,
      current_task: state.current_task,
      capabilities: state.capabilities,
      last_error: state.last_error
    }

    {:reply, status_map, state}
  end

  @impl true
  def handle_info(:stale_check, state) do
    now = DateTime.utc_now()
    stale_threshold = DateTime.add(state.last_heartbeat, @stale_interval_ms, :millisecond)

    new_state =
      if DateTime.compare(now, stale_threshold) in [:gt, :eq] do
        Logger.warning(
          "[Fleet.Sentinel] Agent #{state.agent_id} is unreachable (no heartbeat in 5min)"
        )

        try do
          Bus.emit(:system_event, %{
            event: :fleet_agent_unreachable,
            agent_id: state.agent_id,
            last_heartbeat: state.last_heartbeat
          })
        rescue
          _ -> :ok
        end

        %{state | status: :unreachable, stale_timer: nil}
      else
        # Not yet stale — reschedule
        remaining = DateTime.diff(stale_threshold, now, :millisecond)
        timer = Process.send_after(self(), :stale_check, max(remaining, 1000))
        %{state | stale_timer: timer}
      end

    {:noreply, new_state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
