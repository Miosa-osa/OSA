defmodule OptimalSystemAgent.Agent.TaskTracker do
  @moduledoc """
  Live task tracking for CLI display — persistent, event-driven checklist.

  Singleton GenServer holding per-session task lists. Tasks progress through
  `:pending` → `:in_progress` → `:completed` | `:failed` and emit events on
  each transition for the CLI renderer to pick up.

  Persistence: `~/.osa/sessions/{session_id}/tasks.json` (atomic .tmp→rename).
  Auto-extraction: registers a `:post_response` hook that parses numbered lists
  and markdown checkboxes from agent responses.
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Events.Bus

  # ── Task struct ────────────────────────────────────────────────────

  defmodule Task do
    @moduledoc false
    @derive Jason.Encoder
    defstruct [
      :id,
      :title,
      :reason,
      status: :pending,
      tokens_used: 0,
      created_at: nil,
      started_at: nil,
      completed_at: nil
    ]
  end

  # ── State ──────────────────────────────────────────────────────────

  defstruct sessions: %{}

  # ── Public API ─────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Add a single task. Returns `{:ok, task_id}`."
  def add_task(session_id, title, server \\ __MODULE__) do
    GenServer.call(server, {:add_task, session_id, title})
  end

  @doc "Add multiple tasks at once. Returns `{:ok, [task_id]}`."
  def add_tasks(session_id, titles, server \\ __MODULE__) do
    GenServer.call(server, {:add_tasks, session_id, titles})
  end

  @doc "Transition task to `:in_progress`."
  def start_task(session_id, task_id, server \\ __MODULE__) do
    GenServer.call(server, {:start_task, session_id, task_id})
  end

  @doc "Transition task to `:completed`."
  def complete_task(session_id, task_id, server \\ __MODULE__) do
    GenServer.call(server, {:complete_task, session_id, task_id})
  end

  @doc "Transition task to `:failed` with a reason."
  def fail_task(session_id, task_id, reason, server \\ __MODULE__) do
    GenServer.call(server, {:fail_task, session_id, task_id, reason})
  end

  @doc "Get all tasks for a session."
  def get_tasks(session_id, server \\ __MODULE__) do
    GenServer.call(server, {:get_tasks, session_id})
  end

  @doc "Clear all tasks for a session."
  def clear_tasks(session_id, server \\ __MODULE__) do
    GenServer.call(server, {:clear_tasks, session_id})
  end

  @doc "Record token usage against a specific task."
  def record_tokens(session_id, task_id, count, server \\ __MODULE__) do
    GenServer.cast(server, {:record_tokens, session_id, task_id, count})
  end

  @doc """
  Extract task titles from a text response.

  Parses numbered lists (`1. Do something`) and markdown checkboxes
  (`- [ ] Do something`). Only returns titles between 5–120 chars, capped at 20.
  """
  @spec extract_tasks_from_response(String.t()) :: [String.t()]
  def extract_tasks_from_response(text) when is_binary(text) do
    numbered = Regex.scan(~r/^\s*\d+\.\s+(.+)$/m, text, capture: :all_but_first)
    checkboxes = Regex.scan(~r/^\s*-\s*\[[ x]?\]\s+(.+)$/mi, text, capture: :all_but_first)

    (numbered ++ checkboxes)
    |> List.flatten()
    |> Enum.map(&String.trim/1)
    |> Enum.filter(fn t -> String.length(t) >= 5 and String.length(t) <= 120 end)
    |> Enum.uniq()
    |> Enum.take(20)
  end

  def extract_tasks_from_response(_), do: []

  # ── GenServer Callbacks ────────────────────────────────────────────

  @impl true
  def init(_opts) do
    # Register auto-extraction hook after Hooks GenServer is up
    schedule_hook_registration()
    Logger.info("[TaskTracker] Started")
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:add_task, session_id, title}, _from, state) do
    state = ensure_session(state, session_id)
    task = new_task(title)
    tasks = get_in(state.sessions, [session_id]) ++ [task]
    state = put_in(state.sessions[session_id], tasks)
    persist(session_id, tasks)

    safe_emit(:system_event, %{
      event: :task_tracker_task_added,
      session_id: session_id,
      task_id: task.id,
      title: title
    })

    {:reply, {:ok, task.id}, state}
  end

  @impl true
  def handle_call({:add_tasks, session_id, titles}, _from, state) do
    state = ensure_session(state, session_id)
    new_tasks = Enum.map(titles, &new_task/1)
    tasks = get_in(state.sessions, [session_id]) ++ new_tasks
    state = put_in(state.sessions[session_id], tasks)
    persist(session_id, tasks)

    ids = Enum.map(new_tasks, & &1.id)

    Enum.each(new_tasks, fn t ->
      safe_emit(:system_event, %{
        event: :task_tracker_task_added,
        session_id: session_id,
        task_id: t.id,
        title: t.title
      })
    end)

    {:reply, {:ok, ids}, state}
  end

  @impl true
  def handle_call({:start_task, session_id, task_id}, _from, state) do
    state = ensure_session(state, session_id)

    case update_task(state, session_id, task_id, fn task ->
           %{task | status: :in_progress, started_at: DateTime.utc_now()}
         end) do
      {:ok, updated_state, task} ->
        persist(session_id, updated_state.sessions[session_id])

        safe_emit(:system_event, %{
          event: :task_tracker_task_started,
          session_id: session_id,
          task_id: task_id,
          title: task.title
        })

        {:reply, :ok, updated_state}

      :not_found ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:complete_task, session_id, task_id}, _from, state) do
    state = ensure_session(state, session_id)

    case update_task(state, session_id, task_id, fn task ->
           %{task | status: :completed, completed_at: DateTime.utc_now()}
         end) do
      {:ok, updated_state, task} ->
        persist(session_id, updated_state.sessions[session_id])

        safe_emit(:system_event, %{
          event: :task_tracker_task_completed,
          session_id: session_id,
          task_id: task_id,
          title: task.title
        })

        {:reply, :ok, updated_state}

      :not_found ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:fail_task, session_id, task_id, reason}, _from, state) do
    state = ensure_session(state, session_id)

    case update_task(state, session_id, task_id, fn task ->
           %{task | status: :failed, reason: reason, completed_at: DateTime.utc_now()}
         end) do
      {:ok, updated_state, task} ->
        persist(session_id, updated_state.sessions[session_id])

        safe_emit(:system_event, %{
          event: :task_tracker_task_failed,
          session_id: session_id,
          task_id: task_id,
          title: task.title,
          reason: reason
        })

        {:reply, :ok, updated_state}

      :not_found ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:get_tasks, session_id}, _from, state) do
    state = ensure_session(state, session_id)
    {:reply, state.sessions[session_id] || [], state}
  end

  @impl true
  def handle_call({:clear_tasks, session_id}, _from, state) do
    state = put_in(state.sessions[session_id], [])
    persist(session_id, [])

    safe_emit(:system_event, %{
      event: :task_tracker_tasks_cleared,
      session_id: session_id
    })

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:record_tokens, session_id, task_id, count}, state) do
    state = ensure_session(state, session_id)

    case update_task(state, session_id, task_id, fn task ->
           %{task | tokens_used: task.tokens_used + count}
         end) do
      {:ok, updated_state, _task} ->
        {:noreply, updated_state}

      :not_found ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:register_hook, state) do
    try do
      OptimalSystemAgent.Agent.Hooks.register(
        :post_response,
        "task_auto_extract",
        &auto_extract_hook/1,
        priority: 80
      )

      Logger.debug("[TaskTracker] Registered auto-extraction hook")
    rescue
      _ -> Logger.debug("[TaskTracker] Hooks not available, skipping auto-extraction hook")
    end

    {:noreply, state}
  end

  # ── Private ────────────────────────────────────────────────────────

  defp safe_emit(event_type, payload) do
    # Spawn to isolate from goldrush/Bus crashes in test environment
    spawn(fn ->
      try do
        Bus.emit(event_type, payload)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  defp schedule_hook_registration do
    Process.send_after(self(), :register_hook, 500)
  end

  defp new_task(title) do
    %Task{
      id: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower),
      title: title,
      status: :pending,
      tokens_used: 0,
      created_at: DateTime.utc_now()
    }
  end

  defp update_task(state, session_id, task_id, update_fn) do
    tasks = state.sessions[session_id] || []
    idx = Enum.find_index(tasks, &(&1.id == task_id))

    case idx do
      nil ->
        :not_found

      i ->
        task = Enum.at(tasks, i)
        updated = update_fn.(task)
        tasks = List.replace_at(tasks, i, updated)
        state = put_in(state.sessions[session_id], tasks)
        {:ok, state, updated}
    end
  end

  defp ensure_session(state, session_id) do
    if Map.has_key?(state.sessions, session_id) do
      state
    else
      # Try loading from disk
      tasks = load_persisted(session_id)
      put_in(state.sessions[session_id], tasks)
    end
  end

  # ── Persistence ────────────────────────────────────────────────────

  defp persist(session_id, tasks) do
    path = tasks_path(session_id)
    dir = Path.dirname(path)

    try do
      File.mkdir_p!(dir)
      serialized = Enum.map(tasks, &serialize_task/1)
      json = Jason.encode!(serialized, pretty: true)
      tmp = path <> ".tmp"
      File.write!(tmp, json)
      File.rename!(tmp, path)
    rescue
      e -> Logger.error("[TaskTracker] Persist failed: #{inspect(e)}")
    end
  end

  defp load_persisted(session_id) do
    path = tasks_path(session_id)

    case File.read(path) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, list} when is_list(list) ->
            Enum.map(list, &deserialize_task/1)

          _ ->
            []
        end

      {:error, _} ->
        []
    end
  rescue
    _ -> []
  end

  defp tasks_path(session_id) do
    base = System.get_env("OSA_HOME") || Path.expand("~/.osa")
    Path.join([base, "sessions", session_id, "tasks.json"])
  end

  defp serialize_task(%Task{} = t) do
    %{
      "id" => t.id,
      "title" => t.title,
      "reason" => t.reason,
      "status" => to_string(t.status),
      "tokens_used" => t.tokens_used,
      "created_at" => if(t.created_at, do: DateTime.to_iso8601(t.created_at)),
      "started_at" => if(t.started_at, do: DateTime.to_iso8601(t.started_at)),
      "completed_at" => if(t.completed_at, do: DateTime.to_iso8601(t.completed_at))
    }
  end

  defp deserialize_task(map) when is_map(map) do
    %Task{
      id: map["id"],
      title: map["title"],
      reason: map["reason"],
      status: String.to_existing_atom(map["status"] || "pending"),
      tokens_used: map["tokens_used"] || 0,
      created_at: parse_datetime(map["created_at"]),
      started_at: parse_datetime(map["started_at"]),
      completed_at: parse_datetime(map["completed_at"])
    }
  rescue
    _ ->
      %Task{
        id: map["id"] || "unknown",
        title: map["title"] || "unknown",
        status: :pending
      }
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  # ── Auto-extraction hook ───────────────────────────────────────────

  defp auto_extract_hook(payload) do
    session_id = payload[:session_id]
    response = payload[:response] || payload[:text] || ""

    if is_binary(session_id) and is_binary(response) do
      # Only extract if no tasks exist yet for this session
      existing =
        try do
          get_tasks(session_id)
        rescue
          _ -> []
        end

      if existing == [] do
        titles = extract_tasks_from_response(response)

        if length(titles) >= 3 do
          try do
            add_tasks(session_id, titles)
          rescue
            _ -> :ok
          end
        end
      end
    end

    {:ok, payload}
  end
end
