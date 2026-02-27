defmodule OptimalSystemAgent.Agent.TaskQueue do
  @moduledoc """
  Persistent task queue with atomic leasing.

  Tasks are enqueued by agent_id and leased atomically — only one consumer
  gets a given task. Expired leases are automatically reaped back to :pending.
  Failed tasks retry up to max_attempts (default 3) before being marked :failed.

  Events emitted on :system_event:
  - :task_enqueued — when a new task is added
  - :task_leased — when a task is leased to an agent
  - :task_completed — when a task finishes successfully
  - :task_failed — when a task fails (with attempt count)
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Events.Bus

  @reap_interval 60_000
  @default_lease_ms 300_000
  @default_max_attempts 3

  # ── State ────────────────────────────────────────────────────────────

  defstruct tasks: %{},
            leased: %{}

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
  Atomically lease the oldest pending task for an agent.
  Returns `{:ok, task}` or `:empty`.
  """
  def lease(agent_id, lease_duration_ms \\ @default_lease_ms) do
    GenServer.call(__MODULE__, {:lease, agent_id, lease_duration_ms})
  end

  @doc "Mark a task as completed with a result."
  def complete(task_id, result) do
    GenServer.cast(__MODULE__, {:complete, task_id, result})
  end

  @doc "Mark a task as failed. Retries if under max_attempts, otherwise marks :failed."
  def fail(task_id, error) do
    GenServer.cast(__MODULE__, {:fail, task_id, error})
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

  # ── GenServer Callbacks ─────────────────────────────────────────────

  @impl true
  def init(_opts) do
    schedule_reap()
    Logger.info("[Agent.TaskQueue] Started — reap interval #{div(@reap_interval, 1000)}s")
    {:ok, %__MODULE__{}}
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
      completed_at: nil
    }

    state = %{state | tasks: Map.put(state.tasks, task_id, task)}

    Bus.emit(:system_event, %{event: :task_enqueued, task_id: task_id, agent_id: agent_id})
    Logger.debug("[Agent.TaskQueue] Enqueued task #{task_id} for agent #{agent_id}")

    {:noreply, state}
  end

  @impl true
  def handle_cast({:complete, task_id, result}, state) do
    case Map.get(state.tasks, task_id) do
      nil ->
        Logger.warning("[Agent.TaskQueue] Complete called for unknown task #{task_id}")
        {:noreply, state}

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

        state = %{
          state
          | tasks: Map.put(state.tasks, task_id, updated),
            leased: Map.delete(state.leased, task_id)
        }

        Bus.emit(:system_event, %{event: :task_completed, task_id: task_id})
        Logger.debug("[Agent.TaskQueue] Task #{task_id} completed")

        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:fail, task_id, error}, state) do
    case Map.get(state.tasks, task_id) do
      nil ->
        Logger.warning("[Agent.TaskQueue] Fail called for unknown task #{task_id}")
        {:noreply, state}

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
    end
  end

  @impl true
  def handle_cast(:reap_expired, state) do
    state = do_reap_expired(state)
    {:noreply, state}
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

        updated = %{task | status: :leased, leased_until: leased_until, leased_by: agent_id}

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
        Logger.debug("[Agent.TaskQueue] Leased task #{task.task_id} to agent #{agent_id}")

        {:reply, {:ok, updated}, state}
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

  # ── Private ─────────────────────────────────────────────────────────

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

    updated_tasks =
      Enum.reduce(expired_ids, state.tasks, fn task_id, tasks ->
        case Map.get(tasks, task_id) do
          nil ->
            tasks

          task ->
            reverted = %{task | status: :pending, leased_until: nil, leased_by: nil}
            Map.put(tasks, task_id, reverted)
        end
      end)

    updated_leased =
      Enum.reduce(expired_ids, state.leased, fn id, leased ->
        Map.delete(leased, id)
      end)

    %{state | tasks: updated_tasks, leased: updated_leased}
  end

  defp maybe_filter_status(tasks, nil), do: tasks
  defp maybe_filter_status(tasks, status), do: Enum.filter(tasks, &(&1.status == status))

  defp maybe_filter_agent(tasks, nil), do: tasks
  defp maybe_filter_agent(tasks, agent_id), do: Enum.filter(tasks, &(&1.agent_id == agent_id))

  defp schedule_reap do
    Process.send_after(self(), :reap, @reap_interval)
  end
end
