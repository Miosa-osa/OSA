defmodule OptimalSystemAgent.Agent.ExecutionControl do
  @moduledoc """
  Durable control-plane record for one delegated agent execution.

  The run transcript remains the source for conversation history and the
  `RunStore` lease remains the source for process ownership. This record is the
  compact source of truth for operator-facing state: routing rationale, active
  workflow and tool, counters, recovery state, and parent-delivery status.

  Every mutation is a locked read-modify-write to a JSON sidecar beside the run
  transcript. Callers use the same small interface before and after a backend
  restart, so the HTTP/SSE and TUI projections never need to reconstruct state
  from prose logs.
  """

  require Logger

  alias OptimalSystemAgent.Agent.RunStore
  alias OptimalSystemAgent.Agent.SessionPersistence.RecordLock

  @monotonic ~w(tokens_used tool_count retry_count failure_count)a

  @doc "Create or reset the control record for a newly dispatched run."
  @spec start(String.t(), map()) :: :ok | {:error, term()}
  def start(agent_id, attrs) when is_binary(agent_id) and is_map(attrs) do
    now = now()

    attrs
    |> Map.merge(%{
      agent_id: agent_id,
      status: :running,
      active_skills: [],
      current_tool: nil,
      tokens_used: 0,
      tool_count: 0,
      retry_count: 0,
      failure_count: 0,
      delivery_status: :pending,
      delivery_receipt: nil,
      started_at: now,
      updated_at: now
    })
    |> persist(agent_id)
  end

  @doc "Record current work and cumulative counters for a running agent."
  @spec progress(String.t(), map()) :: :ok | {:error, term()}
  def progress(agent_id, attrs) when is_binary(agent_id) and is_map(attrs) do
    mutate(agent_id, fn current ->
      current
      |> merge_monotonic(attrs)
      |> Map.put(:updated_at, now())
    end)
  end

  @doc "Set a terminal status and its final metrics."
  @spec finish(String.t(), atom() | String.t(), map()) :: :ok | {:error, term()}
  def finish(agent_id, status, attrs \\ %{}) when is_binary(agent_id) and is_map(attrs) do
    mutate(agent_id, fn current ->
      current
      |> merge_monotonic(attrs)
      |> Map.put(:status, status)
      |> Map.put(:current_tool, nil)
      |> Map.put(:completed_at, now())
      |> Map.put(:updated_at, now())
    end)
  end

  @doc "Record the durable parent-delivery receipt lifecycle."
  @spec delivery(String.t(), String.t() | nil, atom() | String.t()) ::
          :ok | {:error, term()}
  def delivery(agent_id, receipt, status) when is_binary(agent_id) do
    progress(agent_id, %{delivery_receipt: receipt, delivery_status: status})
  end

  @doc "Atomically increment one cumulative execution counter."
  @spec increment(String.t(), :retry_count | :failure_count) :: :ok | {:error, term()}
  def increment(agent_id, counter)
      when is_binary(agent_id) and counter in [:retry_count, :failure_count] do
    mutate(agent_id, fn current ->
      Map.update(current, counter, 1, &(&1 + 1))
      |> Map.put(:updated_at, now())
    end)
  end

  @doc "Load one durable execution record."
  @spec get(String.t()) :: map() | nil
  def get(agent_id) when is_binary(agent_id) do
    case File.read(path(agent_id)) do
      {:ok, body} ->
        decode(body)

      {:error, :enoent} ->
        nil

      {:error, reason} ->
        Logger.warning("[ExecutionControl] read failed for #{agent_id}: #{inspect(reason)}")
        nil
    end
  end

  @doc "Merge control-plane facts into a RunStore projection."
  @spec project(map()) :: map()
  def project(%{agent_id: agent_id} = run) do
    case get(agent_id) do
      nil -> run
      control -> Map.merge(run, control)
    end
  end

  def project(run), do: run

  @doc "Broadcast the latest durable projection to the parent session TUI."
  @spec broadcast(String.t(), String.t()) :: :ok
  def broadcast(agent_id, parent_session_id)
      when is_binary(agent_id) and is_binary(parent_session_id) do
    case get(agent_id) do
      nil ->
        :ok

      control ->
        payload = %{
          type: :system_event,
          event: "orchestrator_agent_progress",
          session_id: parent_session_id,
          agent_name: agent_id,
          current_action: Map.get(control, :current_tool) || Map.get(control, :status, ""),
          tool_uses: Map.get(control, :tool_count, 0),
          tokens_used: Map.get(control, :tokens_used, 0),
          active_skills: Map.get(control, :active_skills, []),
          model_reason: Map.get(control, :model_reason, ""),
          skill_reason: Map.get(control, :skill_reason, ""),
          retry_count: Map.get(control, :retry_count, 0),
          failure_count: Map.get(control, :failure_count, 0),
          delivery_status: Map.get(control, :delivery_status, ""),
          available_controls:
            OptimalSystemAgent.Agent.SubagentControl.available_controls(
              Map.get(control, :status, "unknown")
            )
        }

        Phoenix.PubSub.broadcast(
          OptimalSystemAgent.PubSub,
          "osa:session:#{parent_session_id}",
          {:osa_event, payload}
        )

        :ok
    end
  rescue
    error ->
      Logger.warning("[ExecutionControl] runtime broadcast failed: #{Exception.message(error)}")
      :ok
  end

  defp mutate(agent_id, fun) do
    record_path = path(agent_id)

    case RecordLock.with_lock_strict(record_path, fn ->
           current = get(agent_id) || %{agent_id: agent_id, started_at: now()}
           persist_unlocked(fun.(current), record_path)
         end) do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, :contended} = error -> error
    end
  end

  defp persist(attrs, agent_id) do
    record_path = path(agent_id)

    case RecordLock.with_lock_strict(record_path, fn -> persist_unlocked(attrs, record_path) end) do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, :contended} = error -> error
    end
  end

  defp persist_unlocked(attrs, record_path) do
    attrs
    |> stringify_values()
    |> Jason.encode!()
    |> then(&RunStore.atomic_write(record_path, &1))
  end

  defp merge_monotonic(current, attrs) do
    merged = Map.merge(current, attrs)

    Enum.reduce(@monotonic, merged, fn key, acc ->
      old = number(Map.get(current, key))
      incoming = number(Map.get(attrs, key))
      Map.put(acc, key, max(old, incoming))
    end)
  end

  defp number(value) when is_integer(value) and value >= 0, do: value
  defp number(_), do: 0

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) ->
        Map.new(map, fn {key, value} -> {String.to_existing_atom(key), value} end)

      _ ->
        Logger.error("[ExecutionControl] malformed durable control record")
        nil
    end
  rescue
    ArgumentError ->
      Logger.error("[ExecutionControl] durable control record contains unsupported fields")
      nil
  end

  defp stringify_values(map) do
    Map.new(map, fn
      {key, value} when is_atom(value) -> {key, Atom.to_string(value)}
      pair -> pair
    end)
  end

  defp path(agent_id), do: RunStore.transcript_path_for(agent_id) <> ".control.json"
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
