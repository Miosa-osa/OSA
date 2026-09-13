defmodule OptimalSystemAgent.Healing.Orchestrator do
  @moduledoc """
  Autonomous Self-Healing Orchestrator.

  Manages the lifecycle of healing sessions for suspended agent loops.
  When a Loop encounters an unrecoverable error and suspends itself, it
  calls `request_healing/3`. The orchestrator then:

    1. Creates a Session struct and stores it in ETS
    2. **Phase 1 – Diagnosis**: Spawns an ephemeral diagnostician EphemeralAgent,
       allocating 40% of the session budget
    3. **Phase 2 – Fixing**: On receipt of diagnosis, spawns an ephemeral fixer
       EphemeralAgent with the remaining 60%
    4. **Phase 3 – Completion**: Wakes the suspended agent with a result summary,
       broadcasts healing signals via the event bus, cleans up ephemeral processes

  Retry logic: if a phase fails, the session is retried up to `max_attempts`
  times. Exhausted retries trigger escalation — the agent is woken with a
  failure notification and an algedonic alert is emitted.

  ## Event signals emitted (via Events.Bus)

      :system_event  %{event: :healing_session_started, ...}
      :system_event  %{event: :healing_diagnosis_complete, ...}
      :system_event  %{event: :healing_fix_applied, ...}
      :system_event  %{event: :healing_session_complete, ...}
      :system_event  %{event: :healing_session_failed, ...}
      :algedonic_alert               (escalation)

  ## Suspension protocol

  The suspended agent process must send its PID as part of `healing_context` under
  the key `:agent_pid`. The orchestrator will send it:

      {:healing_complete, summary_map}
      {:healing_failed, reason}

  after the session concludes.
  """

  alias OptimalSystemAgent.Infra.BoundedTable

  use GenServer
  require Logger

  alias OptimalSystemAgent.Healing.Session
  alias OptimalSystemAgent.Healing.EphemeralAgent
  alias OptimalSystemAgent.Healing.ErrorClassifier
  alias OptimalSystemAgent.Events.Bus

  @table :osa_healing_sessions

  # Row cap. A healing session is history the moment it terminates, and nothing
  # ever deleted one — this table grew for the life of the daemon. Oldest-first
  # eviction; see Infra.BoundedTable.
  @max_rows 500

  # -- Child spec --

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  # -- Client API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Request autonomous healing for a suspended agent.

  - `agent_id` — session ID of the failed agent
  - `error` — the raw error term
  - `healing_context` — map that MUST include `:agent_pid` (the suspended process PID)
    and MAY include `:messages`, `:working_dir`, `:tool_history`, `:provider`, `:model`

  Returns `{:ok, session_id}` immediately. The session runs asynchronously.
  The agent at `:agent_pid` receives `{:healing_complete, summary}` or
  `{:healing_failed, reason}` when the session concludes.
  """
  @spec request_healing(String.t(), term(), map()) :: {:ok, String.t()} | {:error, term()}
  def request_healing(agent_id, error, healing_context) do
    GenServer.call(__MODULE__, {:request_healing, agent_id, error, healing_context})
  end

  @doc "Get a healing session by ID. Returns `{:ok, session}` or `{:error, :not_found}`."
  @spec get_session(String.t()) :: {:ok, Session.t()} | {:error, :not_found}
  def get_session(session_id) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, session}] -> {:ok, session}
      [] -> {:error, :not_found}
    end
  end

  @doc "List all active (non-terminal) healing sessions."
  @spec active_sessions() :: [Session.t()]
  def active_sessions do
    :ets.tab2list(@table)
    |> Enum.map(fn {_id, session} -> session end)
    |> Enum.reject(&Session.terminal?/1)
  rescue
    e in ArgumentError ->
      Logger.warning("[Healing.Orchestrator] active_sessions failed: #{Exception.message(e)}")
      []
  end

  # -- Server Callbacks --

  @impl true
  def init(_opts) do
    # The ephemeral diagnostician/fixer are started with `start_link/1`, so they
    # are LINKED to this process, and this process owns `@table` — the only copy
    # of every healing session record. Without trapping exits an abnormal
    # ephemeral exit propagated straight through the link, killed the
    # orchestrator, deleted the table, and skipped `terminate/2` (which is what
    # wakes suspended agents). Trapping turns those exits into `{:EXIT, …}`
    # messages that the catch-all `handle_info/2` drops; the crash is already
    # handled properly through the `Process.monitor/1` DOWN path.
    Process.flag(:trap_exit, true)
    :ets.new(@table, [:named_table, :public, :set])
    Logger.info("[Healing.Orchestrator] Started")
    # monitors: %{monitor_ref => {session_id, role}}
    # pid_to_session: %{ephemeral_pid => session_id}
    {:ok, %{monitors: %{}, pid_to_session: %{}}}
  end

  @impl true
  def handle_call({:request_healing, agent_id, error, healing_context}, _from, state) do
    {category, severity, retryable} = ErrorClassifier.classify(error)

    classification = %{
      category: category,
      severity: severity,
      retryable: retryable,
      error: error
    }

    session =
      Session.new(agent_id, classification,
        agent_pid: Map.get(healing_context, :agent_pid),
        healing_context: healing_context,
        budget_usd: Map.get(healing_context, :budget_usd, 0.50),
        timeout_ms: Map.get(healing_context, :timeout_ms, 300_000),
        max_attempts: Map.get(healing_context, :max_attempts, 1)
      )

    full_context =
      healing_context
      |> Map.put(:agent_id, agent_id)
      |> Map.put(:category, category)
      |> Map.put(:severity, severity)
      |> Map.put(:retryable, retryable)
      |> Map.put(:error, error)
      |> Map.put(:attempt_count, 0)

    session = %{session | attempt_count: 1}
    store(session)

    Logger.info(
      "[Healing.Orchestrator] Session #{session.id} created for agent #{agent_id} " <>
        "(#{category}/#{severity}, retryable=#{retryable})"
    )

    broadcast(:system_event, session, %{event: :healing_session_started})

    state = start_diagnosis(session, full_context, state)

    {:reply, {:ok, session.id}, state}
  end

  # Diagnosis result from EphemeralAgent
  @impl true
  def handle_info({:diagnosis, from_pid, result}, state) do
    {session_id, state} = pop_pid_mapping(from_pid, state)

    case session_id && :ets.lookup(@table, session_id) do
      [{^session_id, session}] ->
        handle_diagnosis_result(session, result, state)

      _ ->
        Logger.warning(
          "[Healing.Orchestrator] Received :diagnosis with no matching session (pid=#{inspect(from_pid)})"
        )

        {:noreply, state}
    end
  end

  # Fix result from EphemeralAgent
  @impl true
  def handle_info({:fix_applied, from_pid, result}, state) do
    {session_id, state} = pop_pid_mapping(from_pid, state)

    case session_id && :ets.lookup(@table, session_id) do
      [{^session_id, session}] ->
        handle_fix_result(session, result, state)

      _ ->
        Logger.warning(
          "[Healing.Orchestrator] Received :fix_applied with no matching session (pid=#{inspect(from_pid)})"
        )

        {:noreply, state}
    end
  end

  # Error from EphemeralAgent
  @impl true
  def handle_info({:ephemeral_error, from_pid, role, reason}, state) do
    {session_id, state} = pop_pid_mapping(from_pid, state)

    case session_id && :ets.lookup(@table, session_id) do
      [{^session_id, session}] ->
        Logger.warning(
          "[Healing.Orchestrator] Ephemeral #{role} for session #{session_id} errored: #{inspect(reason)}"
        )

        handle_phase_failure(session, role, reason, state)

      _ ->
        Logger.warning(
          "[Healing.Orchestrator] Received :ephemeral_error with no matching session (pid=#{inspect(from_pid)})"
        )

        {:noreply, state}
    end
  end

  # Session timeout
  @impl true
  def handle_info({:session_timeout, session_id}, state) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, session}] ->
        unless Session.terminal?(session) do
          Logger.warning("[Healing.Orchestrator] Session #{session_id} timed out")
          escalate(session, :timeout, state)
        else
          {:noreply, state}
        end

      [] ->
        {:noreply, state}
    end
  end

  # Ephemeral agent process DOWN — abnormal exit (crash, not normal stop)
  @impl true
  def handle_info({:DOWN, mon_ref, :process, pid, reason}, state) when reason != :normal do
    case Map.pop(state.monitors, mon_ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {{session_id, role}, monitors} ->
        # Also clean up pid_to_session entry
        pid_to_session = Map.delete(state.pid_to_session, pid)
        state = %{state | monitors: monitors, pid_to_session: pid_to_session}

        case :ets.lookup(@table, session_id) do
          [{^session_id, session}] ->
            Logger.warning(
              "[Healing.Orchestrator] Ephemeral #{role} for #{session_id} crashed: #{inspect(reason)}"
            )

            handle_phase_failure(session, role, {:crashed, reason}, state)

          [] ->
            {:noreply, state}
        end
    end
  end

  # Normal DOWN — ephemeral agent exited cleanly (result already sent)
  @impl true
  def handle_info({:DOWN, mon_ref, :process, pid, :normal}, state) do
    monitors = Map.delete(state.monitors, mon_ref)
    pid_to_session = Map.delete(state.pid_to_session, pid)
    {:noreply, %{state | monitors: monitors, pid_to_session: pid_to_session}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state) do
    # Wake all suspended agents gracefully on shutdown
    try do
      :ets.tab2list(@table)
      |> Enum.each(fn {_id, session} ->
        unless Session.terminal?(session) do
          notify_agent(session, {:healing_failed, :orchestrator_shutdown})
        end
      end)
    rescue
      _ -> :ok
    end

    :ok
  end

  # -- Phase execution --

  defp start_diagnosis(session, context, state) do
    session = force_transition(session, :diagnosing)
    session = arm_session_timer(session)
    store(session)

    budget = Session.diagnosis_budget(session)

    opts = [
      role: :diagnostician,
      context: context,
      parent_pid: self(),
      budget_usd: budget,
      provider: Map.get(context, :provider),
      model: Map.get(context, :model)
    ]

    case ephemeral_module().start_link(opts) do
      {:ok, pid} ->
        mon_ref = Process.monitor(pid)
        session_updated = %{session | diagnostician_pid: pid}
        store(session_updated)

        monitors = Map.put(state.monitors, mon_ref, {session.id, :diagnostician})
        pid_to_session = Map.put(state.pid_to_session, pid, session.id)
        %{state | monitors: monitors, pid_to_session: pid_to_session}

      {:error, reason} ->
        Logger.error(
          "[Healing.Orchestrator] Failed to start diagnostician for #{session.id}: #{inspect(reason)}"
        )

        notify_agent(session, {:healing_failed, {:diagnostician_start_error, reason}})
        escalate_session(session, {:diagnostician_start_error, reason})
        state
    end
  end

  defp start_fixing(session, diagnosis, context, state) do
    session = force_transition(session, :fixing)
    session = %{session | diagnosis: diagnosis}
    store(session)

    broadcast(:system_event, session, %{
      event: :healing_diagnosis_complete,
      root_cause: Map.get(diagnosis, "root_cause"),
      confidence: Map.get(diagnosis, "confidence"),
      strategy: Map.get(diagnosis, "remediation_strategy")
    })

    budget = Session.fix_budget(session)

    opts = [
      role: :fixer,
      context: context,
      diagnosis: diagnosis,
      parent_pid: self(),
      budget_usd: budget,
      provider: Map.get(context, :provider),
      model: Map.get(context, :model)
    ]

    case ephemeral_module().start_link(opts) do
      {:ok, pid} ->
        mon_ref = Process.monitor(pid)
        session_updated = %{session | fixer_pid: pid}
        store(session_updated)

        monitors = Map.put(state.monitors, mon_ref, {session.id, :fixer})
        pid_to_session = Map.put(state.pid_to_session, pid, session.id)
        %{state | monitors: monitors, pid_to_session: pid_to_session}

      {:error, reason} ->
        Logger.error(
          "[Healing.Orchestrator] Failed to start fixer for #{session.id}: #{inspect(reason)}"
        )

        notify_agent(session, {:healing_failed, {:fixer_start_error, reason}})
        escalate_session(session, {:fixer_start_error, reason})
        state
    end
  end

  # -- Result handlers --

  defp handle_diagnosis_result(session, diagnosis, state) do
    context = rebuild_context(session)
    state = start_fixing(session, diagnosis, context, state)
    {:noreply, state}
  end

  defp handle_fix_result(session, fix_result, state) do
    session = force_transition(session, :completed)
    session = %{session | fix_result: fix_result}
    cancel_session_timer(session)
    store(session)

    summary = %{
      session_id: session.id,
      agent_id: session.agent_id,
      duration_ms: Session.duration_ms(session),
      root_cause: get_in(session.diagnosis, ["root_cause"]),
      fix_applied: Map.get(fix_result, "fix_applied", false),
      description: Map.get(fix_result, "description"),
      file_changes: Map.get(fix_result, "file_changes", [])
    }

    notify_agent(session, {:healing_complete, summary})

    broadcast(:system_event, session, %{
      event: :healing_fix_applied,
      fix_applied: Map.get(fix_result, "fix_applied"),
      description: Map.get(fix_result, "description")
    })

    broadcast(:system_event, session, %{
      event: :healing_session_complete,
      summary: summary
    })

    Logger.info(
      "[Healing.Orchestrator] Session #{session.id} completed for #{session.agent_id} in #{Session.duration_ms(session)}ms"
    )

    {:noreply, state}
  end

  defp handle_phase_failure(session, _role, reason, state) do
    can_retry = session.attempt_count < session.max_attempts

    if can_retry do
      Logger.info(
        "[Healing.Orchestrator] Retrying session #{session.id} " <>
          "(attempt #{session.attempt_count}/#{session.max_attempts})"
      )

      # Kill the failed phase's ephemerals BEFORE starting the retry. A fixer
      # writes into the user's working tree; two of them running concurrently
      # on the same session was a real corruption path.
      state = stop_ephemerals(session, state)

      retry_context =
        rebuild_context(session) |> Map.put(:attempt_count, session.attempt_count)

      # Reset to :pending, not :diagnosing. `start_diagnosis/3` transitions to
      # :diagnosing, and :diagnosing -> :diagnosing is not a legal move, so the
      # old code fed `Session.transition/2` an illegal transition on every
      # retry. Combined with the `{:ok, _} =` match at the call site that raised
      # a MatchError and killed the orchestrator (and its ETS table) outright.
      retry_session = %{
        session
        | status: :pending,
          error: reason,
          attempt_count: session.attempt_count + 1,
          diagnosis: nil,
          diagnostician_pid: nil,
          fixer_pid: nil
      }

      store(retry_session)

      state = start_diagnosis(retry_session, retry_context, state)
      {:noreply, state}
    else
      escalate(session, reason, state)
    end
  end

  defp escalate(session, reason, state) do
    state = stop_ephemerals(session, state)
    escalate_session(session, reason)

    Bus.emit_algedonic(
      :high,
      "Self-healing exhausted for agent #{session.agent_id}: #{inspect(reason)}",
      metadata: %{
        session_id: session.id,
        agent_id: session.agent_id,
        category: session.classification.category,
        attempts: session.attempt_count
      }
    )

    notify_agent(session, {:healing_failed, reason})
    {:noreply, state}
  end

  defp escalate_session(session, reason) do
    session = force_transition(session, :escalated)
    session = %{session | error: reason}
    cancel_session_timer(session)
    store(session)

    broadcast(:system_event, session, %{
      event: :healing_session_failed,
      reason: inspect(reason),
      attempts: session.attempt_count
    })
  end

  # -- Helpers --

  # The ephemeral agent implementation. Overridable so the orchestrator's own
  # lifecycle (crash isolation, retry, escalation, wake-up) can be exercised
  # without a live LLM call — `EphemeralAgent` issues a real provider request,
  # which makes the orchestrator untestable and any test of it billable.
  defp ephemeral_module do
    Application.get_env(:optimal_system_agent, :healing_ephemeral_module, EphemeralAgent)
  end

  # Write a session row, then enforce the row cap OURSELVES.
  #
  # This used to be a straight `BoundedTable.insert/4` with `max: @max_rows`,
  # whose eviction policy is oldest-by-insertion-recency with no notion of
  # whether a row is still live. Under load that deleted sessions that were
  # mid-`:diagnosing`: the row vanished, and the ephemeral's later `:diagnosis`
  # / `:fix_applied` message found no matching session and was dropped on the
  # floor while the suspended Loop kept waiting. A row cap is history
  # management; it must never reap work in progress. Terminal rows only.
  defp store(session) do
    # max: 0 disables BoundedTable's own eviction but keeps its ordering
    # bookkeeping accurate, so a row evicted later is still cleaned up properly.
    BoundedTable.insert(@table, session.id, session, max: 0)
    enforce_cap()
    :ok
  end

  defp enforce_cap do
    overflow = BoundedTable.size(@table) - @max_rows

    if overflow > 0 do
      :ets.tab2list(@table)
      |> Enum.filter(fn {_id, s} -> Session.terminal?(s) end)
      |> Enum.sort_by(fn {_id, s} -> s.completed_at || s.started_at end, DateTime)
      |> Enum.take(overflow)
      |> Enum.each(fn {id, _s} -> BoundedTable.delete(@table, id) end)
    end

    :ok
  rescue
    e ->
      Logger.warning("[Healing.Orchestrator] enforce_cap failed: #{Exception.message(e)}")
      :ok
  end

  # Stop any ephemeral still attached to this session and drop its bookkeeping.
  #
  # Retry used to nil `diagnostician_pid`/`fixer_pid` without stopping the
  # processes behind them, and escalation never touched them at all. A fixer is
  # a process that edits the user's working tree; leaving one running while a
  # second one starts means two agents writing the same files, and its eventual
  # result message routing to a session that has already moved on.
  defp stop_ephemerals(session, state) do
    pids = Enum.filter([session.diagnostician_pid, session.fixer_pid], &is_pid/1)

    monitors =
      Enum.reduce(state.monitors, state.monitors, fn {ref, {sid, _role}}, acc ->
        if sid == session.id do
          Process.demonitor(ref, [:flush])
          Map.delete(acc, ref)
        else
          acc
        end
      end)

    pid_to_session = Map.drop(state.pid_to_session, pids)

    Enum.each(pids, fn pid ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    %{state | monitors: monitors, pid_to_session: pid_to_session}
  end

  # `Session.transition/2` refuses illegal moves, and several call sites used to
  # bind its result with `{:ok, s} = …`, so an illegal move raised a MatchError
  # inside the orchestrator — taking the ETS table and every session with it.
  # Nothing here is worth killing the orchestrator over: log and carry on.
  defp force_transition(session, status) do
    case Session.transition(session, status) do
      {:ok, updated} ->
        updated

      {:error, :invalid_transition} ->
        Logger.warning(
          "[Healing.Orchestrator] session #{session.id}: illegal transition " <>
            "#{session.status} -> #{status}; forcing"
        )

        %{session | status: status}
    end
  end

  defp notify_agent(session, message) do
    agent_pid = session.agent_pid

    if is_pid(agent_pid) and Process.alive?(agent_pid) do
      send(agent_pid, message)
    else
      Logger.warning(
        "[Healing.Orchestrator] Cannot notify agent for session #{session.id} — pid not available or dead"
      )
    end
  end

  defp broadcast(type, session, payload) do
    Bus.emit(type, payload,
      session_id: session.id,
      source: "healing.orchestrator",
      correlation_id: session.agent_id
    )
  end

  defp arm_session_timer(session) do
    ref = Process.send_after(self(), {:session_timeout, session.id}, session.timeout_ms)
    %{session | timer_ref: ref}
  end

  defp cancel_session_timer(%{timer_ref: ref}) when not is_nil(ref) do
    Process.cancel_timer(ref)
  end

  defp cancel_session_timer(_session), do: :ok

  # Rebuild the error context from stored session fields for retry passes
  defp rebuild_context(session) do
    %{
      agent_id: session.agent_id,
      category: session.classification.category,
      severity: session.classification.severity,
      retryable: session.classification.retryable,
      error: session.classification.error,
      attempt_count: session.attempt_count
    }
    |> then(&Map.merge(session.healing_context || %{}, &1))
  end

  # Pop the session_id associated with a given ephemeral agent PID.
  # EphemeralAgent includes `self()` in every result/error message so we can
  # route deterministically even when multiple sessions run concurrently.
  defp pop_pid_mapping(pid, state) do
    case Map.pop(state.pid_to_session, pid) do
      {nil, _} -> {nil, state}
      {session_id, pid_to_session} -> {session_id, %{state | pid_to_session: pid_to_session}}
    end
  end
end
