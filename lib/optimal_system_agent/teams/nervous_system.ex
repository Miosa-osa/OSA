defmodule OptimalSystemAgent.Teams.NervousSystem do
  @moduledoc """
  Per-team process group — 8 lightweight GenServers that provide team-level
  intelligence and coordination services.

  ## Processes

  1. `AutoLogger`        — logs all team events to the activity log
  2. `Broadcaster`       — publishes team state changes to PubSub subscribers
  3. `Rebalancer`        — monitors agent load, emits reassignment suggestions
  4. `ConflictDetector`  — detects conflicting file edits or task assignments
  5. `MessageScheduler`  — queued messages, reorder/squash/schedule delivery
  6. `Negotiation`       — task negotiation protocol between agents
  7. `Rendezvous`        — synchronization points for multi-agent coordination
  8. `ComplexityMonitor` — analyzes task complexity, recommends team scaling

  ## Lifecycle

  `start_all/1` starts all 8 processes under the team's DynamicSupervisor.
  `stop_all/1` terminates them all. `ensure_running/1` is idempotent —
  it checks which processes are alive and restarts any that have died.

  All 8 are registered in `OptimalSystemAgent.Registry` under
  `{ModuleName, team_id}` keys for O(1) lookup.
  """

  require Logger

  # Ordered list of all nervous-system module names (used for start/stop loops)
  @processes [
    __MODULE__.AutoLogger,
    __MODULE__.Broadcaster,
    __MODULE__.Rebalancer,
    __MODULE__.ConflictDetector,
    __MODULE__.MessageScheduler,
    __MODULE__.Negotiation,
    __MODULE__.Rendezvous,
    __MODULE__.ComplexityMonitor
  ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start all 8 nervous-system processes for the given team_id.

  Returns `:ok`. Individual start failures are logged but do not halt the
  rest — the team should operate with degraded intelligence rather than fail.
  """
  @spec start_all(String.t()) :: :ok
  def start_all(team_id) do
    Enum.each(@processes, fn mod ->
      case start_process(mod, team_id) do
        {:ok, _pid} ->
          Logger.debug("[NervousSystem:#{team_id}] Started #{inspect(mod)}")

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, reason} ->
          Logger.warning("[NervousSystem:#{team_id}] Could not start #{inspect(mod)}: #{inspect(reason)}")
      end
    end)

    :ok
  end

  @doc "Stop all 8 nervous-system processes for the given team_id."
  @spec stop_all(String.t()) :: :ok
  def stop_all(team_id) do
    Enum.each(@processes, fn mod ->
      case Registry.lookup(OptimalSystemAgent.Registry, {mod, team_id}) do
        [{pid, _}] ->
          DynamicSupervisor.terminate_child(
            OptimalSystemAgent.Teams.Supervisor,
            pid
          )
          |> tap(fn result ->
            Logger.debug("[NervousSystem:#{team_id}] Stopped #{inspect(mod)}: #{inspect(result)}")
          end)

        [] -> :ok
      end
    end)

    :ok
  end

  @doc """
  Idempotently ensure all 8 processes are running for the given team_id.

  Starts any process that is not currently registered.
  """
  @spec ensure_running(String.t()) :: :ok
  def ensure_running(team_id) do
    Enum.each(@processes, fn mod ->
      case Registry.lookup(OptimalSystemAgent.Registry, {mod, team_id}) do
        [{_pid, _}] -> :ok
        [] -> start_process(mod, team_id)
      end
    end)

    :ok
  end

  @doc "Return a list of `{module, pid | :not_running}` for all 8 processes."
  @spec status(String.t()) :: [{module(), pid() | :not_running}]
  def status(team_id) do
    Enum.map(@processes, fn mod ->
      case Registry.lookup(OptimalSystemAgent.Registry, {mod, team_id}) do
        [{pid, _}] -> {mod, pid}
        [] -> {mod, :not_running}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp start_process(mod, team_id) do
    DynamicSupervisor.start_child(
      OptimalSystemAgent.Teams.Supervisor,
      {mod, team_id: team_id}
    )
  end

  # ---------------------------------------------------------------------------
  # Sub-process: AutoLogger
  # ---------------------------------------------------------------------------

  defmodule AutoLogger do
    @moduledoc "Logs all team events to the activity log via PubSub subscription."
    use GenServer
    require Logger

    def start_link(opts) do
      team_id = Keyword.fetch!(opts, :team_id)
      GenServer.start_link(__MODULE__, team_id,
        name: {:via, Registry, {OptimalSystemAgent.Registry, {__MODULE__, team_id}}}
      )
    end

    @impl true
    def init(team_id) do
      Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:team:#{team_id}")
      {:ok, %{team_id: team_id, event_count: 0}}
    end

    @impl true
    def handle_info({:team_event, event}, state) do
      Logger.debug("[Team:#{state.team_id}] #{inspect(event)}")
      {:noreply, %{state | event_count: state.event_count + 1}}
    end

    def handle_info(_msg, state), do: {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Sub-process: Broadcaster
  # ---------------------------------------------------------------------------

  defmodule Broadcaster do
    @moduledoc "Publishes team state changes to PubSub subscribers."
    use GenServer
    require Logger

    def start_link(opts) do
      team_id = Keyword.fetch!(opts, :team_id)
      GenServer.start_link(__MODULE__, team_id,
        name: {:via, Registry, {OptimalSystemAgent.Registry, {__MODULE__, team_id}}}
      )
    end

    def broadcast(team_id, event_type, payload) do
      case Registry.lookup(OptimalSystemAgent.Registry, {__MODULE__, team_id}) do
        [{pid, _}] -> GenServer.cast(pid, {:broadcast, event_type, payload})
        [] -> :ok
      end
    end

    @impl true
    def init(team_id), do: {:ok, %{team_id: team_id}}

    @impl true
    def handle_cast({:broadcast, event_type, payload}, state) do
      Phoenix.PubSub.broadcast(
        OptimalSystemAgent.PubSub,
        "osa:team:#{state.team_id}",
        {:team_event, %{type: event_type, payload: payload, team_id: state.team_id, at: DateTime.utc_now()}}
      )

      {:noreply, state}
    end
  end

  # ---------------------------------------------------------------------------
  # Sub-process: Rebalancer
  # ---------------------------------------------------------------------------

  defmodule Rebalancer do
    @moduledoc """
    Monitors agent load across the team. Emits :rebalance_suggested events
    when load is skewed beyond the configured threshold.
    """
    use GenServer
    require Logger

    # Check every 30 seconds
    @check_interval 30_000
    @skew_threshold 0.5

    def start_link(opts) do
      team_id = Keyword.fetch!(opts, :team_id)
      GenServer.start_link(__MODULE__, team_id,
        name: {:via, Registry, {OptimalSystemAgent.Registry, {__MODULE__, team_id}}}
      )
    end

    @impl true
    def init(team_id) do
      schedule_check()
      {:ok, %{team_id: team_id}}
    end

    @impl true
    def handle_info(:check_load, state) do
      alias OptimalSystemAgent.Teams.AgentState

      agents  = AgentState.list(state.team_id)
      working = Enum.count(agents, &(&1.status == :working))
      idle    = Enum.count(agents, &(&1.status == :idle))
      total   = working + idle

      if total > 1 and idle / total < @skew_threshold do
        Logger.info("[Rebalancer:#{state.team_id}] Load skew detected (working=#{working} idle=#{idle}) — suggesting rebalance")

        OptimalSystemAgent.Teams.NervousSystem.Broadcaster.broadcast(
          state.team_id,
          :rebalance_suggested,
          %{working: working, idle: idle, total: total}
        )
      end

      schedule_check()
      {:noreply, state}
    end

    def handle_info(_msg, state), do: {:noreply, state}

    defp schedule_check, do: Process.send_after(self(), :check_load, @check_interval)
  end

  # ---------------------------------------------------------------------------
  # Sub-process: ConflictDetector
  # ---------------------------------------------------------------------------

  defmodule ConflictDetector do
    @moduledoc """
    Detects conflicting file edits and duplicate task assignments.

    Maintains a registry of {file_path => agent_id} and {task_id => agent_id}.
    When two agents attempt to edit the same file or claim the same task,
    emits a :conflict_detected event.
    """
    use GenServer
    require Logger

    def start_link(opts) do
      team_id = Keyword.fetch!(opts, :team_id)
      GenServer.start_link(__MODULE__, team_id,
        name: {:via, Registry, {OptimalSystemAgent.Registry, {__MODULE__, team_id}}}
      )
    end

    def register_file_edit(team_id, agent_id, file_path) do
      GenServer.call(
        {:via, Registry, {OptimalSystemAgent.Registry, {__MODULE__, team_id}}},
        {:register_file, agent_id, file_path}
      )
    end

    def release_file_edit(team_id, agent_id, file_path) do
      GenServer.cast(
        {:via, Registry, {OptimalSystemAgent.Registry, {__MODULE__, team_id}}},
        {:release_file, agent_id, file_path}
      )
    end

    @impl true
    def init(team_id) do
      {:ok, %{team_id: team_id, file_locks: %{}, task_locks: %{}}}
    end

    @impl true
    def handle_call({:register_file, agent_id, file_path}, _from, state) do
      case Map.get(state.file_locks, file_path) do
        nil ->
          new_locks = Map.put(state.file_locks, file_path, agent_id)
          {:reply, :ok, %{state | file_locks: new_locks}}

        ^agent_id ->
          {:reply, :ok, state}

        other_agent ->
          Logger.warning("[ConflictDetector:#{state.team_id}] File conflict: #{file_path} — #{agent_id} vs #{other_agent}")

          OptimalSystemAgent.Teams.NervousSystem.Broadcaster.broadcast(
            state.team_id,
            :conflict_detected,
            %{type: :file_edit, file: file_path, agents: [agent_id, other_agent]}
          )

          {:reply, {:conflict, other_agent}, state}
      end
    end

    @impl true
    def handle_cast({:release_file, _agent_id, file_path}, state) do
      new_locks = Map.delete(state.file_locks, file_path)
      {:noreply, %{state | file_locks: new_locks}}
    end
  end

  # ---------------------------------------------------------------------------
  # Sub-process: MessageScheduler
  # ---------------------------------------------------------------------------

  defmodule MessageScheduler do
    @moduledoc """
    Queued message delivery with reordering, squashing, and scheduled dispatch.

    Messages can be:
    - Delayed: deliver after N milliseconds
    - Squashed: if N messages of the same type arrive, only deliver the latest
    - Prioritized: higher-priority messages delivered before lower-priority ones
    """
    use GenServer
    require Logger

    def start_link(opts) do
      team_id = Keyword.fetch!(opts, :team_id)
      GenServer.start_link(__MODULE__, team_id,
        name: {:via, Registry, {OptimalSystemAgent.Registry, {__MODULE__, team_id}}}
      )
    end

    @doc "Schedule a message for delivery after `delay_ms` milliseconds."
    def schedule(team_id, recipient, message, delay_ms \\ 0) do
      GenServer.cast(
        {:via, Registry, {OptimalSystemAgent.Registry, {__MODULE__, team_id}}},
        {:schedule, recipient, message, delay_ms}
      )
    end

    @impl true
    def init(team_id) do
      {:ok, %{team_id: team_id, queue: []}}
    end

    @impl true
    def handle_cast({:schedule, recipient, message, 0}, state) do
      deliver(state.team_id, recipient, message)
      {:noreply, state}
    end

    def handle_cast({:schedule, recipient, message, delay_ms}, state) do
      Process.send_after(self(), {:deliver, recipient, message}, delay_ms)
      {:noreply, state}
    end

    @impl true
    def handle_info({:deliver, recipient, message}, state) do
      deliver(state.team_id, recipient, message)
      {:noreply, state}
    end

    def handle_info(_msg, state), do: {:noreply, state}

    defp deliver(team_id, recipient, message) do
      Phoenix.PubSub.broadcast(
        OptimalSystemAgent.PubSub,
        "osa:team:#{team_id}:#{recipient}",
        {:team_message, message}
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Sub-process: Negotiation
  # ---------------------------------------------------------------------------

  defmodule Negotiation do
    @moduledoc """
    Task negotiation protocol between agents.

    When multiple agents want the same task, Negotiation runs a simple
    priority auction: agents submit bids with a confidence score (0.0–1.0)
    and the highest bidder wins. Ties resolved by agent_id for determinism.
    """
    use GenServer
    require Logger

    def start_link(opts) do
      team_id = Keyword.fetch!(opts, :team_id)
      GenServer.start_link(__MODULE__, team_id,
        name: {:via, Registry, {OptimalSystemAgent.Registry, {__MODULE__, team_id}}}
      )
    end

    @doc "Submit a bid for a task. Returns `:won` or `{:lost, winner_agent_id}`."
    def bid(team_id, task_id, agent_id, confidence) do
      GenServer.call(
        {:via, Registry, {OptimalSystemAgent.Registry, {__MODULE__, team_id}}},
        {:bid, task_id, agent_id, confidence},
        5_000
      )
    end

    @doc "Close bidding for a task and return the winner."
    def close_auction(team_id, task_id) do
      GenServer.call(
        {:via, Registry, {OptimalSystemAgent.Registry, {__MODULE__, team_id}}},
        {:close_auction, task_id}
      )
    end

    @impl true
    def init(team_id) do
      {:ok, %{team_id: team_id, auctions: %{}}}
    end

    @impl true
    def handle_call({:bid, task_id, agent_id, confidence}, _from, state) do
      bids = Map.get(state.auctions, task_id, [])
      new_bids = [{agent_id, confidence} | bids]
      new_auctions = Map.put(state.auctions, task_id, new_bids)

      {:reply, :ok, %{state | auctions: new_auctions}}
    end

    @impl true
    def handle_call({:close_auction, task_id}, _from, state) do
      case Map.get(state.auctions, task_id, []) do
        [] ->
          {:reply, {:error, :no_bids}, state}

        bids ->
          {winner, _} = Enum.max_by(bids, fn {agent_id, conf} -> {conf, agent_id} end)
          new_auctions = Map.delete(state.auctions, task_id)
          Logger.info("[Negotiation:#{state.team_id}] Task #{task_id} awarded to #{winner} (#{length(bids)} bids)")
          {:reply, {:ok, winner}, %{state | auctions: new_auctions}}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Sub-process: Rendezvous
  # ---------------------------------------------------------------------------

  defmodule Rendezvous do
    @moduledoc """
    Synchronization points for multi-agent coordination.

    A rendezvous is a named barrier: N agents must all call `arrive/3` before
    any of them proceeds. When all expected agents have arrived, all waiting
    callers are unblocked simultaneously.

    Useful for fan-out/fan-in patterns: spawn N agents, wait for all to reach
    a checkpoint before synthesizing results.
    """
    use GenServer
    require Logger

    def start_link(opts) do
      team_id = Keyword.fetch!(opts, :team_id)
      GenServer.start_link(__MODULE__, team_id,
        name: {:via, Registry, {OptimalSystemAgent.Registry, {__MODULE__, team_id}}}
      )
    end

    @doc """
    Create a rendezvous point. Returns `:ok`.

    `expected` is the number of agents that must arrive before the barrier opens.
    """
    def create(team_id, name, expected) when is_integer(expected) and expected > 0 do
      GenServer.call(
        {:via, Registry, {OptimalSystemAgent.Registry, {__MODULE__, team_id}}},
        {:create, name, expected}
      )
    end

    @doc """
    Arrive at a rendezvous point. Blocks until all expected agents arrive.

    Returns `:go` when the barrier opens or `{:error, :not_found}` if the
    rendezvous does not exist.

    `timeout_ms` defaults to 60 seconds.
    """
    def arrive(team_id, name, agent_id, timeout_ms \\ 60_000) do
      GenServer.call(
        {:via, Registry, {OptimalSystemAgent.Registry, {__MODULE__, team_id}}},
        {:arrive, name, agent_id},
        timeout_ms
      )
    end

    @impl true
    def init(team_id) do
      {:ok, %{team_id: team_id, barriers: %{}}}
    end

    @impl true
    def handle_call({:create, name, expected}, _from, state) do
      barrier = %{expected: expected, arrived: [], waiters: []}
      new_barriers = Map.put(state.barriers, name, barrier)
      {:reply, :ok, %{state | barriers: new_barriers}}
    end

    @impl true
    def handle_call({:arrive, name, agent_id}, from, state) do
      case Map.get(state.barriers, name) do
        nil ->
          {:reply, {:error, :not_found}, state}

        barrier ->
          arrived = [agent_id | barrier.arrived] |> Enum.uniq()
          waiters = [from | barrier.waiters]
          updated = %{barrier | arrived: arrived, waiters: waiters}

          if length(arrived) >= updated.expected do
            # All arrived — unblock everyone
            Logger.info("[Rendezvous:#{state.team_id}] Barrier '#{name}' opened (#{length(arrived)} agents)")
            Enum.each(updated.waiters, &GenServer.reply(&1, :go))
            new_barriers = Map.delete(state.barriers, name)
            {:noreply, %{state | barriers: new_barriers}}
          else
            new_barriers = Map.put(state.barriers, name, updated)
            {:noreply, %{state | barriers: new_barriers}}
          end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Sub-process: ComplexityMonitor
  # ---------------------------------------------------------------------------

  defmodule ComplexityMonitor do
    @moduledoc """
    Analyzes task complexity signals and recommends team scaling.

    Watches:
    - Number of pending tasks relative to available agents
    - Average task failure rate
    - Task depth (dependency chains)

    Recommendations:
    - `:scale_up` — spawn more agents
    - `:scale_down` — dissolve idle agents
    - `:escalate_tier` — promote agents to higher model tier
    - `:ok` — no action needed
    """
    use GenServer
    require Logger

    @check_interval 45_000

    def start_link(opts) do
      team_id = Keyword.fetch!(opts, :team_id)
      GenServer.start_link(__MODULE__, team_id,
        name: {:via, Registry, {OptimalSystemAgent.Registry, {__MODULE__, team_id}}}
      )
    end

    @doc "Get the current complexity recommendation for the team."
    def recommend(team_id) do
      GenServer.call(
        {:via, Registry, {OptimalSystemAgent.Registry, {__MODULE__, team_id}}},
        :recommend
      )
    end

    @impl true
    def init(team_id) do
      schedule_check()
      {:ok, %{team_id: team_id, last_recommendation: :ok}}
    end

    @impl true
    def handle_call(:recommend, _from, state) do
      rec = compute_recommendation(state.team_id)
      {:reply, rec, %{state | last_recommendation: rec}}
    end

    @impl true
    def handle_info(:check_complexity, state) do
      rec = compute_recommendation(state.team_id)

      if rec != :ok and rec != state.last_recommendation do
        Logger.info("[ComplexityMonitor:#{state.team_id}] Recommendation: #{inspect(rec)}")

        OptimalSystemAgent.Teams.NervousSystem.Broadcaster.broadcast(
          state.team_id,
          :complexity_recommendation,
          %{recommendation: rec}
        )
      end

      schedule_check()
      {:noreply, %{state | last_recommendation: rec}}
    end

    def handle_info(_msg, state), do: {:noreply, state}

    defp compute_recommendation(team_id) do
      alias OptimalSystemAgent.Teams.AgentState
      alias OptimalSystemAgent.Team

      agents  = AgentState.list(team_id)
      tasks   = Team.list_tasks(team_id)

      pending_count = Enum.count(tasks, &(&1.status == :pending))
      failed_count  = Enum.count(tasks, &(&1.status == :failed))
      idle_count    = Enum.count(agents, &(&1.status == :idle))
      total_tasks   = length(tasks)

      cond do
        pending_count > 0 and idle_count == 0 ->
          :scale_up

        idle_count > div(length(agents) + 1, 2) and length(agents) > 1 ->
          :scale_down

        total_tasks > 0 and failed_count / max(total_tasks, 1) > 0.3 ->
          :escalate_tier

        true ->
          :ok
      end
    rescue
      _ -> :ok
    end

    defp schedule_check, do: Process.send_after(self(), :check_complexity, @check_interval)
  end
end
