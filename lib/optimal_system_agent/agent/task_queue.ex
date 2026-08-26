defmodule OptimalSystemAgent.Agent.TaskQueue do
  @moduledoc """
  Persistent task queue with atomic leasing and SQLite write-through.

  Tasks are enqueued by agent_id and leased atomically — only one consumer
  gets a given task. Expired leases are automatically reaped back to :pending.
  Failed tasks retry up to max_attempts (default 3) before being marked :failed.

  ## Durability

  All mutations hit the DB (`Store.Repo`) first, then update the in-memory
  cache. On init, pending + leased tasks are loaded from DB for crash recovery.
  Completed/failed tasks are NOT held in memory — use `list_history/1` to query.

  If the DB is unavailable, the queue degrades to in-memory only (with a warning).

  Events emitted on :system_event:
  - :task_enqueued — when a new task is added
  - :task_leased — when a task is leased to an agent
  - :task_completed — when a task finishes successfully
  - :task_failed — when a task fails (with attempt count)
  """
  use GenServer
  require Logger

  import Ecto.Query

  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Store.Repo
  alias OptimalSystemAgent.Store.Task, as: TaskSchema

  @reap_interval 60_000
  @default_lease_ms 300_000
  @default_max_attempts 3

  # ── State ────────────────────────────────────────────────────────────

  defstruct tasks: %{},
            leased: %{},
            db_available: false

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Enqueue a new task for a specific agent.
  Options: :priority (integer, lower = higher priority), :max_attempts (default 3).
  """
  def enqueue(task_id, agent_id, payload, opts \\ []) do
    GenServer.cast(__MODULE__, {:enqueue, task_id, agent_id, payload, opts})
  end

  @doc """
  Synchronous enqueue — returns `{:ok, task}` with the created task.
  Use when the caller needs the task struct immediately (e.g. orchestrator wave dispatch).
  """
  def enqueue_sync(task_id, agent_id, payload, opts \\ []) do
    GenServer.call(__MODULE__, {:enqueue_sync, task_id, agent_id, payload, opts})
  end

  @doc """
  Atomically lease the oldest pending task for an agent.
  Returns `{:ok, task}` or `:empty`.
  """
  def lease(agent_id, lease_duration_ms \\ @default_lease_ms) do
    GenServer.call(__MODULE__, {:lease, agent_id, lease_duration_ms})
  end

  @doc """
  Mark a task as completed with a result.

  `opts` carries the caller's lease proof and is how a task avoids being
  executed twice:

    - `:lease_epoch` — the `lease_epoch` from the task `lease/2` handed back.
      A lease that has since expired and been re-granted to another agent has a
      NEWER epoch, so the slow original holder's completion is discarded instead
      of overwriting the second holder's in-flight work.
    - `:agent_id` — the leasing agent; must match `leased_by`.

  Omitting both keeps the old (unchecked-by-token) behavior for callers that
  cannot thread the lease through, but the `:leased` status check always
  applies, so a duplicate completion of an already-terminal task is dropped.
  """
  def complete(task_id, result, opts \\ []) do
    GenServer.cast(__MODULE__, {:complete, task_id, result, opts})
  end

  @doc """
  Mark a task as failed. Retries if under max_attempts, otherwise marks :failed.

  Takes the same lease-proof `opts` as `complete/3` — without them a stale
  worker's failure could revert a task another agent is actively running.
  """
  def fail(task_id, error, opts \\ []) do
    GenServer.cast(__MODULE__, {:fail, task_id, error, opts})
  end

  @doc "Reap expired leases back to :pending status."
  def reap_expired_leases do
    GenServer.cast(__MODULE__, :reap_expired)
  end

  @doc "List tasks, optionally filtered by status or agent_id."
  def list_tasks(opts \\ []) do
    GenServer.call(__MODULE__, {:list_tasks, opts})
  end

  @doc "Get a single task by ID."
  def get_task(task_id) do
    GenServer.call(__MODULE__, {:get_task, task_id})
  end

  @doc """
  Query completed/failed tasks from the database (not in memory).
  Options: :agent_id, :status, :since (DateTime), :limit (default 50).
  """
  @spec list_history(keyword()) :: [map()]
  def list_history(opts \\ []) do
    if db_available?() do
      do_list_history(opts)
    else
      []
    end
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────

  @impl true
  def init(_opts) do
    schedule_reap()

    # Only the singleton instance (__MODULE__) loads from DB.
    # Test instances (registered under other names) run pure in-memory.
    singleton? =
      case Process.info(self(), :registered_name) do
        {:registered_name, __MODULE__} -> true
        _ -> false
      end

    db_ok = singleton? and db_available?()
    state = %__MODULE__{db_available: db_ok}

    state =
      if db_ok do
        load_from_db(state)
      else
        if singleton? do
          Logger.warning("[Agent.TaskQueue] DB unavailable — running in-memory only")
        end

        state
      end

    count = map_size(state.tasks)

    Logger.info(
      "[Agent.TaskQueue] Started — #{count} task(s) recovered, reap interval #{div(@reap_interval, 1000)}s"
    )

    {:ok, state}
  end

  @impl true
  def handle_cast({:enqueue, task_id, agent_id, payload, opts}, state) do
    now = DateTime.utc_now()
    max_attempts = Keyword.get(opts, :max_attempts, @default_max_attempts)

    task = %{
      task_id: task_id,
      agent_id: agent_id,
      payload: payload,
      status: :pending,
      leased_until: nil,
      leased_by: nil,
      result: nil,
      error: nil,
      attempts: 0,
      max_attempts: max_attempts,
      created_at: now,
      completed_at: nil,
      # Bumped on every lease grant AND every reap; the holder echoes it back
      # on complete/fail so a stale holder cannot clobber the current one.
      lease_epoch: 0
    }

    case persist_and_cache(state, task) do
      {:ok, state} ->
        Bus.emit(:system_event, %{event: :task_enqueued, task_id: task_id, agent_id: agent_id})
        Logger.debug("[Agent.TaskQueue] Enqueued task #{task_id} for agent #{agent_id}")

        {:noreply, state}

      {:error, reason} ->
        # Not cached: a task nobody durably recorded must not be leased out.
        persist_failed(:enqueue, task_id, reason)
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:complete, task_id, result, opts}, state) do
    case lease_holder(state, task_id, opts, :complete) do
      :reject ->
        {:noreply, state}

      {:ok, task} ->
        now = DateTime.utc_now()

        updated = %{
          task
          | status: :completed,
            result: result,
            completed_at: now,
            leased_until: nil,
            leased_by: nil
        }

        # Write FIRST, advance in-memory only on a durable write.
        case persist_update(state, updated) do
          {:ok, state} ->
            state = %{
              state
              | tasks: Map.put(state.tasks, task_id, updated),
                leased: Map.delete(state.leased, task_id)
            }

            Bus.emit(:system_event, %{event: :task_completed, task_id: task_id})
            Logger.debug("[Agent.TaskQueue] Task #{task_id} completed")

            {:noreply, state}

          {:error, reason} ->
            persist_failed(:complete, task_id, reason)
            {:noreply, state}
        end
    end
  end

  @impl true
  def handle_cast({:fail, task_id, error, opts}, state) do
    case lease_holder(state, task_id, opts, :fail) do
      :reject ->
        {:noreply, state}

      {:ok, task} ->
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
            # Retry: revert to pending
            %{
              task
              | status: :pending,
                error: error,
                attempts: new_attempts,
                leased_until: nil,
                leased_by: nil
            }
          end

        case persist_update(state, updated) do
          {:ok, state} ->
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
              "[Agent.TaskQueue] Task #{task_id} failed (attempt #{new_attempts}/#{task.max_attempts})"
            )

            {:noreply, state}

          {:error, reason} ->
            # Without the durable write, releasing the lease in memory would let
            # a second worker lease a task the DB still shows as held — and the
            # attempts increment would be lost, so `max_attempts` would never
            # be reached.
            persist_failed(:fail, task_id, reason)
            {:noreply, state}
        end
    end
  end

  # Resolve the task a `complete`/`fail` refers to, but ONLY if the caller still
  # holds its lease.
  #
  # Without this, both handlers looked a task up by id alone — no status check,
  # no `leased_by` check, no epoch. `do_reap_expired/1` reverts an expired lease
  # and the next `lease/2` hands the task to a second agent, so the original
  # slow worker's later `complete/2` overwrote the SECOND worker's in-flight
  # task, and its `fail/2` reverted a task another agent was actively running —
  # a third execution.
  defp lease_holder(state, task_id, opts, op) do
    case Map.get(state.tasks, task_id) do
      nil ->
        Logger.warning("[Agent.TaskQueue] #{op} called for unknown task #{task_id}")
        :reject

      %{status: status} when status != :leased ->
        Logger.warning(
          "[Agent.TaskQueue] ignoring #{op} for task #{task_id} — status is #{status}, not :leased"
        )

        :reject

      task ->
        epoch = Keyword.get(opts, :lease_epoch)
        agent_id = Keyword.get(opts, :agent_id)

        cond do
          not is_nil(epoch) and epoch != Map.get(task, :lease_epoch, 0) ->
            Logger.warning(
              "[Agent.TaskQueue] ignoring #{op} for task #{task_id} — stale lease epoch " <>
                "#{inspect(epoch)} (current #{inspect(Map.get(task, :lease_epoch, 0))})"
            )

            :reject

          not is_nil(agent_id) and agent_id != task.leased_by ->
            Logger.warning(
              "[Agent.TaskQueue] ignoring #{op} for task #{task_id} — #{inspect(agent_id)} " <>
                "does not hold the lease (#{inspect(task.leased_by)})"
            )

            :reject

          true ->
            {:ok, task}
        end
    end
  end

  @impl true
  def handle_cast(:reap_expired, state) do
    state = do_reap_expired(state)
    {:noreply, state}
  end

  @impl true
  def handle_call({:enqueue_sync, task_id, agent_id, payload, opts}, _from, state) do
    now = DateTime.utc_now()
    max_attempts = Keyword.get(opts, :max_attempts, @default_max_attempts)

    task = %{
      task_id: task_id,
      agent_id: agent_id,
      payload: payload,
      status: :pending,
      leased_until: nil,
      leased_by: nil,
      result: nil,
      error: nil,
      attempts: 0,
      max_attempts: max_attempts,
      created_at: now,
      completed_at: nil,
      # Bumped on every lease grant AND every reap; the holder echoes it back
      # on complete/fail so a stale holder cannot clobber the current one.
      lease_epoch: 0
    }

    case persist_and_cache(state, task) do
      {:ok, state} ->
        Bus.emit(:system_event, %{event: :task_enqueued, task_id: task_id, agent_id: agent_id})
        Logger.debug("[Agent.TaskQueue] Enqueued (sync) task #{task_id} for agent #{agent_id}")

        {:reply, {:ok, task}, state}

      {:error, reason} ->
        persist_failed(:enqueue, task_id, reason)
        {:reply, {:error, :persist_failed}, state}
    end
  end

  @impl true
  def handle_call({:lease, agent_id, lease_duration_ms}, _from, state) do
    now = DateTime.utc_now()

    # Find oldest pending task for this agent
    candidate =
      state.tasks
      |> Map.values()
      |> Enum.filter(fn t -> t.agent_id == agent_id and t.status == :pending end)
      |> Enum.sort_by(& &1.created_at, DateTime)
      |> List.first()

    case candidate do
      nil ->
        {:reply, :empty, state}

      task ->
        leased_until = DateTime.add(now, lease_duration_ms, :millisecond)

        # Every grant mints a NEW epoch. The holder echoes it back on
        # complete/fail, which is what lets a stale holder be told apart from
        # the current one after a reap re-granted the task.
        epoch = Map.get(task, :lease_epoch, 0) + 1

        updated = %{
          task
          | status: :leased,
            leased_until: leased_until,
            leased_by: agent_id,
            lease_epoch: epoch
        }

        # Grant the lease in memory only once it is durable. Handing work out on
        # the strength of a write that failed means the DB still shows the task
        # pending: after a restart it is leased to nobody and runs a second time
        # alongside the worker still holding the in-memory lease.
        case persist_update(state, updated) do
          {:ok, state} ->
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

            Bus.emit(:system_event, %{
              event: :task_leased,
              task_id: task.task_id,
              agent_id: agent_id
            })

            Logger.debug("[Agent.TaskQueue] Leased task #{task.task_id} to agent #{agent_id}")

            {:reply, {:ok, updated}, state}

          {:error, reason} ->
            persist_failed(:lease, task.task_id, reason)
            {:reply, {:error, :persist_failed}, state}
        end
    end
  end

  @impl true
  def handle_call({:list_tasks, opts}, _from, state) do
    tasks = Map.values(state.tasks)

    filtered =
      tasks
      |> maybe_filter_status(Keyword.get(opts, :status))
      |> maybe_filter_agent(Keyword.get(opts, :agent_id))
      |> Enum.sort_by(& &1.created_at, DateTime)

    {:reply, filtered, state}
  end

  @impl true
  def handle_call({:get_task, task_id}, _from, state) do
    case Map.get(state.tasks, task_id) do
      nil -> {:reply, {:error, :not_found}, state}
      task -> {:reply, {:ok, task}, state}
    end
  end

  @impl true
  def handle_info(:reap, state) do
    state = do_reap_expired(state)
    schedule_reap()
    {:noreply, state}
  end

  # ── Private: DB Persistence ──────────────────────────────────────────

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
          # Epochs are per-BEAM (there is no lease_epoch column); a recovered
          # task starts at 0 and the next grant mints 1.
          task = record |> TaskSchema.to_map() |> Map.put_new(:lease_epoch, 0)
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
        Logger.warning("[Agent.TaskQueue] Failed to load from DB: #{inspect(e)}")
        %{state | db_available: false}
    end
  end

  # Enqueue. `{:ok, state}` on a durable insert, `{:error, reason}` otherwise —
  # every branch used to cache the task in memory regardless, so a task whose
  # row was never written was handed out to a worker and then vanished at the
  # next restart, mid-flight.
  defp persist_and_cache(state, task) do
    cached = %{state | tasks: Map.put(state.tasks, task.task_id, task)}

    if state.db_available do
      try do
        attrs = TaskSchema.from_map(task)

        case Repo.insert(TaskSchema.changeset(attrs), on_conflict: :nothing) do
          {:ok, _record} ->
            {:ok, cached}

          {:error, changeset} ->
            Logger.error(
              "[Agent.TaskQueue] DB insert failed for #{task.task_id}: #{inspect(changeset.errors)}"
            )

            {:error, changeset.errors}
        end
      rescue
        e ->
          Logger.error("[Agent.TaskQueue] DB insert error for #{task.task_id}: #{inspect(e)}")
          {:error, e}
      catch
        :exit, reason ->
          Logger.error("[Agent.TaskQueue] DB insert exit for #{task.task_id}: #{inspect(reason)}")
          {:error, reason}
      end
    else
      # Memory-only by design: nothing survives a restart, so nothing diverges.
      {:ok, cached}
    end
  end

  # Durable write for a status transition. Returns `{:ok, state}` or
  # `{:error, reason}` — it USED to swallow every failure and return the state
  # unchanged, which is indistinguishable from success, and every caller then
  # mutated the in-memory map regardless.
  #
  # The cost of that was a second execution of real work: a `complete` whose
  # write failed left `tasks` saying `:completed` and the DB row saying
  # `"leased"` with no result. On restart `load_from_db/1` recovers the row as
  # leased, the reaper expires it, and the task RUNS AGAIN — with the first
  # run's result gone.
  #
  # `db_available: false` is not a failure: the queue is memory-only by design
  # there, nothing survives a restart, and so there is no divergence to create.
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
            error: db_error(attrs.error),
            attempts: attrs.attempts,
            completed_at: attrs.completed_at,
            updated_at: DateTime.utc_now()
          ]
        )

        {:ok, state}
      rescue
        e ->
          Logger.error("[Agent.TaskQueue] DB update failed for #{task.task_id}: #{inspect(e)}")
          {:error, e}
      catch
        :exit, reason ->
          Logger.error("[Agent.TaskQueue] DB update exit for #{task.task_id}: #{inspect(reason)}")
          {:error, reason}
      end
    else
      {:ok, state}
    end
  end

  # The `error` column is a string. `do_reap_expired/1` sets the in-memory error
  # to the ATOM `:lease_expired`, and Ecto refuses to cast an atom to :string —
  # so every reap-to-failed write raised. The old rescue swallowed that and
  # advanced memory anyway, which is why nobody noticed the row was never
  # written. Normalize at the DB boundary; the in-memory value stays an atom.
  defp db_error(nil), do: nil
  defp db_error(v) when is_binary(v), do: v
  defp db_error(v) when is_atom(v), do: Atom.to_string(v)
  defp db_error(v), do: inspect(v)

  # Shared handling for a transition whose durable write failed: in-memory state
  # is left EXACTLY as it was (the task stays `:leased`, by the same holder, at
  # the same epoch), so memory and the DB still agree and the holder can simply
  # retry the same call. Announced rather than swallowed.
  defp persist_failed(op, task_id, reason) do
    Logger.error(
      "[Agent.TaskQueue] refusing to apply #{op} for task #{task_id} in memory — its durable " <>
        "write failed (#{inspect(reason)}). The task stays leased; retry the #{op}. Advancing " <>
        "anyway would leave the row leased with no result and re-run the work after a restart."
    )

    Bus.emit(:system_event, %{
      event: :task_persist_failed,
      task_id: task_id,
      op: op,
      reason: inspect(reason)
    })
  end

  defp do_reap_expired(state) do
    now = DateTime.utc_now()

    expired_ids =
      state.leased
      |> Enum.filter(fn {_id, info} ->
        DateTime.compare(now, info.leased_until) == :gt
      end)
      |> Enum.map(fn {id, _} -> id end)

    if expired_ids != [] do
      Logger.info("[Agent.TaskQueue] Reaping #{length(expired_ids)} expired lease(s)")
    end

    # An expired lease is a FAILED attempt, not a free retry. The reap used to
    # reset straight to :pending without touching `attempts`, so max_attempts
    # was enforced only on the explicit-fail path and a task that hangs its
    # worker every time re-executed forever. Each reaped task also gets a new
    # epoch so the (still-running) previous holder's late complete/fail is
    # rejected instead of clobbering whoever leases it next.
    #
    # Rows are written one at a time rather than via a bulk `update_all`: the
    # bulk form had no `where status == "leased"` guard (so it could stomp a
    # task that raced to :completed) and could not carry per-task attempts.
    {state, reaped_ids} =
      Enum.reduce(expired_ids, {state, []}, fn task_id, {acc, reaped} ->
        case Map.get(acc.tasks, task_id) do
          %{status: :leased} = task ->
            attempts = task.attempts + 1

            reverted =
              if attempts >= task.max_attempts do
                %{
                  task
                  | status: :failed,
                    error: :lease_expired,
                    attempts: attempts,
                    completed_at: now,
                    leased_until: nil,
                    leased_by: nil,
                    lease_epoch: task.lease_epoch + 1
                }
              else
                %{
                  task
                  | status: :pending,
                    attempts: attempts,
                    leased_until: nil,
                    leased_by: nil,
                    lease_epoch: task.lease_epoch + 1
                }
              end

            # Only revert in memory if the row was actually reverted on disk.
            # A reap that mutates memory on a failed write puts the task back in
            # the pending pool while the DB still shows it leased — so it is
            # leased twice, and the attempts increment that enforces
            # `max_attempts` is lost, making the hang-and-retry loop endless.
            case persist_reaped(acc, reverted) do
              {:ok, acc} ->
                {%{acc | tasks: Map.put(acc.tasks, task_id, reverted)}, [task_id | reaped]}

              {:error, reason} ->
                # Lease entry deliberately RETAINED: dropping it here would free
                # the task for a second worker while the DB still shows it held.
                # The next reap tick retries the write.
                persist_failed(:reap, task_id, reason)
                {acc, reaped}
            end

          _ ->
            # Already terminal or gone — nothing to revert, but the stale lease
            # entry should go.
            {acc, [task_id | reaped]}
        end
      end)

    updated_leased =
      Enum.reduce(reaped_ids, state.leased, fn id, leased ->
        Map.delete(leased, id)
      end)

    %{state | leased: updated_leased}
  end

  # Guarded persist for a reaped task: the DB row must STILL be leased, so a
  # task that legitimately completed between the expiry scan and this write is
  # left alone.
  defp persist_reaped(state, task) do
    if state.db_available do
      try do
        attrs = TaskSchema.from_map(task)

        TaskSchema
        |> where([t], t.task_id == ^task.task_id and t.status == "leased")
        |> Repo.update_all(
          set: [
            status: attrs.status,
            leased_until: nil,
            leased_by: nil,
            error: db_error(attrs.error),
            attempts: attrs.attempts,
            completed_at: attrs.completed_at,
            updated_at: DateTime.utc_now()
          ]
        )

        {:ok, state}
      rescue
        e ->
          Logger.error("[Agent.TaskQueue] DB reap failed: #{inspect(e)}")
          {:error, e}
      catch
        :exit, reason ->
          Logger.error("[Agent.TaskQueue] DB reap exit: #{inspect(reason)}")
          {:error, reason}
      end
    else
      {:ok, state}
    end
  end

  # ── Private: History Query ──────────────────────────────────────────

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

    query =
      if since do
        where(query, [t], t.updated_at >= ^since)
      else
        query
      end

    try do
      query
      |> Repo.all()
      |> Enum.map(&TaskSchema.to_map/1)
    rescue
      e ->
        Logger.warning("[Agent.TaskQueue] History query failed: #{inspect(e)}")
        []
    end
  end

  # ── Private: Filters ────────────────────────────────────────────────

  defp maybe_filter_status(tasks, nil), do: tasks
  defp maybe_filter_status(tasks, status), do: Enum.filter(tasks, &(&1.status == status))

  defp maybe_filter_agent(tasks, nil), do: tasks
  defp maybe_filter_agent(tasks, agent_id), do: Enum.filter(tasks, &(&1.agent_id == agent_id))

  defp schedule_reap do
    Process.send_after(self(), :reap, @reap_interval)
  end
end
