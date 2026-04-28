defmodule OptimalSystemAgent.Agent.Tasks.Queue do
  @moduledoc """
  Persistent queue logic — atomic leasing and SQLite write-through.

  Tasks are enqueued by agent_id and leased atomically. Expired leases are
  reaped back to :pending. Failed tasks retry up to max_attempts before :failed.

  All mutations hit the DB (Store.Repo) first, then update in-memory state.
  Completed/failed tasks are NOT held in memory — use history/1 for those.
  If DB is unavailable, degrades to in-memory only.
  """

  require Logger

  import Ecto.Query

  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Store.Repo
  alias OptimalSystemAgent.Store.Task, as: TaskSchema

  @default_lease_ms 300_000
  @default_max_attempts 3

  # ── State type ─────────────────────────────────────────────────────────────
  # %{tasks: %{task_id => task_map}, leased: %{task_id => lease_info}, db_available: bool}

  @doc "Initial queue state."
  @spec init_state(boolean()) :: map()
  def init_state(is_singleton) do
    db_ok = is_singleton and db_available?()
    state = %{tasks: %{}, leased: %{}, db_available: db_ok}

    if db_ok do
      load_from_db(state)
    else
      if is_singleton do
        Logger.warning("[Tasks.Queue] DB unavailable — running in-memory only")
      end

      state
    end
  end

  # ── Mutations ──────────────────────────────────────────────────────────────

  @doc "Enqueue a new task. Returns updated state."
  @spec enqueue(map(), String.t(), String.t(), map(), keyword()) :: map()
  def enqueue(state, task_id, agent_id, payload, opts \\ []) do
    task = build_task(task_id, agent_id, payload, opts)
    state = persist_and_cache(state, task)
    Bus.emit(:system_event, %{event: :task_enqueued, task_id: task_id, agent_id: agent_id})
    Logger.debug("[Tasks.Queue] Enqueued task #{task_id} for agent #{agent_id}")
    state
  end

  @doc "Enqueue and return `{state, task}`."
  @spec enqueue_sync(map(), String.t(), String.t(), map(), keyword()) :: {map(), map()}
  def enqueue_sync(state, task_id, agent_id, payload, opts \\ []) do
    task = build_task(task_id, agent_id, payload, opts)
    state = persist_and_cache(state, task)
    Bus.emit(:system_event, %{event: :task_enqueued, task_id: task_id, agent_id: agent_id})
    Logger.debug("[Tasks.Queue] Enqueued (sync) task #{task_id} for agent #{agent_id}")
    {state, task}
  end

  @doc "Atomically lease oldest pending task for an agent. Returns `{state, {:ok, task} | :empty}`."
  @spec lease(map(), String.t(), non_neg_integer()) :: {map(), {:ok, map()} | :empty}
  def lease(state, agent_id, lease_duration_ms \\ @default_lease_ms) do
    now = DateTime.utc_now()

    candidate =
      state.tasks
      |> Map.values()
      |> Enum.filter(fn t -> t.agent_id == agent_id and t.status == :pending end)
      |> Enum.sort_by(& &1.created_at, DateTime)
      |> List.first()

    case candidate do
      nil ->
        {state, :empty}

      task ->
        leased_until = DateTime.add(now, lease_duration_ms, :millisecond)
        updated = %{task | status: :leased, leased_until: leased_until, leased_by: agent_id}
        state = persist_update(state, updated)

        lease_info = %{
          task_id: task.task_id,
          agent_id: agent_id,
          leased_at: now,
          leased_until: leased_until
        }

        state = %{
          state
          | tasks: Map.put(state.tasks, task.task_id, updated),
            leased: Map.put(state.leased, task.task_id, lease_info)
        }

        Bus.emit(:system_event, %{event: :task_leased, task_id: task.task_id, agent_id: agent_id})
        Logger.debug("[Tasks.Queue] Leased task #{task.task_id} to agent #{agent_id}")
        {state, {:ok, updated}}
    end
  end

  @doc "Complete a task. Returns updated state."
  @spec complete(map(), String.t(), term()) :: map()
  def complete(state, task_id, result) do
    case Map.get(state.tasks, task_id) do
      nil ->
        Logger.warning("[Tasks.Queue] Complete called for unknown task #{task_id}")
        state

      task ->
        now = DateTime.utc_now()

        updated = %{
          task
          | status: :completed,
            result: result,
            completed_at: now,
            leased_until: nil,
            leased_by: nil
        }

        state = persist_update(state, updated)

        state = %{
          state
          | tasks: Map.put(state.tasks, task_id, updated),
            leased: Map.delete(state.leased, task_id)
        }

        Bus.emit(:system_event, %{event: :task_completed, task_id: task_id})
        Logger.debug("[Tasks.Queue] Task #{task_id} completed")
        state
    end
  end

  @doc "Fail a task (retries if under max_attempts). Returns updated state."
  @spec fail(map(), String.t(), term()) :: map()
  def fail(state, task_id, error) do
    case Map.get(state.tasks, task_id) do
      nil ->
        Logger.warning("[Tasks.Queue] Fail called for unknown task #{task_id}")
        state

      task ->
        new_attempts = task.attempts + 1

        updated =
          if new_attempts >= task.max_attempts do
            %{
              task
              | status: :failed,
                error: error,
                attempts: new_attempts,
                leased_until: nil,
                leased_by: nil
            }
          else
            %{
              task
              | status: :pending,
                error: error,
                attempts: new_attempts,
                leased_until: nil,
                leased_by: nil
            }
          end

        state = persist_update(state, updated)

        state = %{
          state
          | tasks: Map.put(state.tasks, task_id, updated),
            leased: Map.delete(state.leased, task_id)
        }

        Bus.emit(:system_event, %{
          event: :task_failed,
          task_id: task_id,
          attempts: new_attempts,
          max_attempts: task.max_attempts,
          final: new_attempts >= task.max_attempts
        })

        Logger.debug(
          "[Tasks.Queue] Task #{task_id} failed (attempt #{new_attempts}/#{task.max_attempts})"
        )

        state
    end
  end

  @doc "Reap expired leases back to :pending. Returns updated state."
  @spec reap_expired(map()) :: map()
  def reap_expired(state) do
    now = DateTime.utc_now()

    expired_ids =
      state.leased
      |> Enum.filter(fn {_id, info} -> DateTime.compare(now, info.leased_until) == :gt end)
      |> Enum.map(fn {id, _} -> id end)

    if expired_ids != [] do
      Logger.info("[Tasks.Queue] Reaping #{length(expired_ids)} expired lease(s)")

      if state.db_available do
        try do
          TaskSchema
          |> where([t], t.task_id in ^expired_ids)
          |> Repo.update_all(
            set: [status: "pending", leased_until: nil, leased_by: nil, updated_at: now]
          )
        rescue
          e -> Logger.warning("[Tasks.Queue] DB reap failed: #{inspect(e)}")
        end
      end
    end

    updated_tasks =
      Enum.reduce(expired_ids, state.tasks, fn task_id, tasks ->
        case Map.get(tasks, task_id) do
          nil ->
            tasks

          task ->
            Map.put(tasks, task_id, %{task | status: :pending, leased_until: nil, leased_by: nil})
        end
      end)

    updated_leased =
      Enum.reduce(expired_ids, state.leased, fn id, leased -> Map.delete(leased, id) end)

    %{state | tasks: updated_tasks, leased: updated_leased}
  end

  # ── Queries ────────────────────────────────────────────────────────────────

  @doc "Get a task by ID."
  @spec get_task(map(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_task(state, task_id) do
    case Map.get(state.tasks, task_id) do
      nil -> {:error, :not_found}
      task -> {:ok, task}
    end
  end

  @doc "List in-memory tasks with optional filters: status, agent_id."
  @spec list_tasks(map(), keyword()) :: [map()]
  def list_tasks(state, opts \\ []) do
    state.tasks
    |> Map.values()
    |> maybe_filter_status(Keyword.get(opts, :status))
    |> maybe_filter_agent(Keyword.get(opts, :agent_id))
    |> Enum.sort_by(& &1.created_at, DateTime)
  end

  @doc "Query completed/failed tasks from DB. Options: agent_id, status, since, limit."
  @spec history(keyword()) :: [map()]
  def history(opts \\ []) do
    if db_available?() do
      do_list_history(opts)
    else
      []
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  defp build_task(task_id, agent_id, payload, opts) do
    %{
      task_id: task_id,
      agent_id: agent_id,
      payload: payload,
      status: :pending,
      leased_until: nil,
      leased_by: nil,
      result: nil,
      error: nil,
      attempts: 0,
      max_attempts: Keyword.get(opts, :max_attempts, @default_max_attempts),
      created_at: DateTime.utc_now(),
      completed_at: nil
    }
  end

  defp db_available? do
    try do
      Repo.__adapter__()
      Process.whereis(Repo) != nil
    rescue
      _ -> false
    end
  end

  defp load_from_db(state) do
    try do
      records =
        TaskSchema
        |> where([t], t.status in ["pending", "leased"])
        |> order_by([t], asc: t.inserted_at)
        |> Repo.all()

      {tasks, leased} =
        Enum.reduce(records, {%{}, %{}}, fn record, {tasks_acc, leased_acc} ->
          task = TaskSchema.to_map(record)
          tasks_acc = Map.put(tasks_acc, task.task_id, task)

          leased_acc =
            if task.status == :leased do
              Map.put(leased_acc, task.task_id, %{
                task_id: task.task_id,
                agent_id: task.agent_id,
                leased_at: task.created_at,
                leased_until: task.leased_until
              })
            else
              leased_acc
            end

          {tasks_acc, leased_acc}
        end)

      %{state | tasks: tasks, leased: leased}
    rescue
      e ->
        Logger.warning("[Tasks.Queue] Failed to load from DB: #{inspect(e)}")
        %{state | db_available: false}
    end
  end

  defp persist_and_cache(state, task) do
    if state.db_available do
      try do
        attrs = TaskSchema.from_map(task)

        case Repo.insert(TaskSchema.changeset(attrs), on_conflict: :nothing) do
          {:ok, _record} ->
            %{state | tasks: Map.put(state.tasks, task.task_id, task)}

          {:error, changeset} ->
            Logger.warning(
              "[Tasks.Queue] DB insert failed for #{task.task_id}: #{inspect(changeset.errors)}"
            )

            %{state | tasks: Map.put(state.tasks, task.task_id, task)}
        end
      rescue
        e ->
          Logger.warning("[Tasks.Queue] DB insert error for #{task.task_id}: #{inspect(e)}")
          %{state | tasks: Map.put(state.tasks, task.task_id, task)}
      end
    else
      %{state | tasks: Map.put(state.tasks, task.task_id, task)}
    end
  end

  defp persist_update(state, task) do
    if state.db_available do
      try do
        attrs = TaskSchema.from_map(task)

        TaskSchema
        |> where([t], t.task_id == ^task.task_id)
        |> Repo.update_all(
          set: [
            status: attrs.status,
            leased_until: attrs.leased_until,
            leased_by: attrs.leased_by,
            result: attrs.result,
            error: attrs.error,
            attempts: attrs.attempts,
            completed_at: attrs.completed_at,
            updated_at: DateTime.utc_now()
          ]
        )

        state
      rescue
        e ->
          Logger.warning("[Tasks.Queue] DB update failed for #{task.task_id}: #{inspect(e)}")
          state
      catch
        :exit, reason ->
          Logger.warning("[Tasks.Queue] DB update exit for #{task.task_id}: #{inspect(reason)}")
          state
      end
    else
      state
    end
  end

  defp do_list_history(opts) do
    limit = Keyword.get(opts, :limit, 50)
    agent_id = Keyword.get(opts, :agent_id)
    status = Keyword.get(opts, :status)
    since = Keyword.get(opts, :since)

    query =
      TaskSchema
      |> where([t], t.status in ["completed", "failed"])
      |> order_by([t], desc: t.updated_at)
      |> limit(^limit)

    query = if agent_id, do: where(query, [t], t.agent_id == ^agent_id), else: query

    query =
      if status do
        status_str = TaskSchema.status_to_string(status)
        where(query, [t], t.status == ^status_str)
      else
        query
      end

    query = if since, do: where(query, [t], t.updated_at >= ^since), else: query

    try do
      query |> Repo.all() |> Enum.map(&TaskSchema.to_map/1)
    rescue
      e ->
        Logger.warning("[Tasks.Queue] History query failed: #{inspect(e)}")
        []
    end
  end

  defp maybe_filter_status(tasks, nil), do: tasks
  defp maybe_filter_status(tasks, status), do: Enum.filter(tasks, &(&1.status == status))

  defp maybe_filter_agent(tasks, nil), do: tasks
  defp maybe_filter_agent(tasks, agent_id), do: Enum.filter(tasks, &(&1.agent_id == agent_id))
end
