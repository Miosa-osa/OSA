defmodule OptimalSystemAgent.Agent.Tasks do
  @moduledoc """
  Unified task management system — public API facade.

  Consolidates three subsystems under one GenServer:
  - Workflow: LLM-decomposed multi-step workflow tracking
  - Tracker: Per-session checklist with dependencies and event emission
  - Queue: Persistent job queue with atomic leasing and SQLite write-through

  ## Usage

      # Tracker
      {:ok, id} = Tasks.add_task(session_id, "Implement auth")
      :ok = Tasks.complete_task(session_id, id)

      # Workflow
      {:ok, workflow} = Tasks.create_workflow(description, session_id)
      {:ok, workflow} = Tasks.advance_workflow(workflow_id, result)

      # Queue
      Tasks.enqueue(task_id, agent_id, payload)
      {:ok, task} = Tasks.lease(agent_id)
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Agent.Tasks.{Workflow, Tracker, Queue}

  @reap_interval 60_000

  # ── State ──────────────────────────────────────────────────────────────────

  defstruct sessions: %{},
            workflows: %{},
            dir: nil,
            queue: %{tasks: %{}, leased: %{}, db_available: false}

  # ── Startup ────────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    schedule_reap()
    schedule_hook_registration()

    workflow_state = Workflow.init_state()

    is_singleton =
      case Process.info(self(), :registered_name) do
        {:registered_name, __MODULE__} -> true
        _ -> false
      end

    queue_state = Queue.init_state(is_singleton)

    state = %__MODULE__{
      sessions: %{},
      workflows: workflow_state.workflows,
      dir: workflow_state.dir,
      queue: queue_state
    }

    Logger.info("[Agent.Tasks] Started — #{map_size(state.workflows)} workflow(s), queue ready")

    if Keyword.get(opts, :name) == __MODULE__ or is_singleton do
      Logger.info("[Agent.Tasks] Singleton instance active")
    end

    {:ok, state}
  end

  # ── Tracker API ────────────────────────────────────────────────────────────

  @doc "Add a single task. Returns `{:ok, task_id}`."
  def add_task(session_id, title, opts_or_server \\ __MODULE__, server \\ nil)

  def add_task(session_id, title, opts, server) when is_map(opts) do
    GenServer.call(server || __MODULE__, {:add_task, session_id, title, opts})
  end

  def add_task(session_id, title, server, _) when is_atom(server) or is_pid(server) do
    GenServer.call(server, {:add_task, session_id, title, %{}})
  end

  @doc "Add multiple tasks at once. Returns `{:ok, [task_id]}`."
  def add_tasks(session_id, titles, server \\ __MODULE__) do
    GenServer.call(server, {:add_tasks, session_id, titles})
  end

  @doc "Transition task to :in_progress."
  def start_task(session_id, task_id, server \\ __MODULE__) do
    GenServer.call(server, {:start_task, session_id, task_id})
  end

  @doc "Transition task to :completed."
  def complete_task(session_id, task_id, server \\ __MODULE__) do
    GenServer.call(server, {:complete_task, session_id, task_id})
  end

  @doc "Transition task to :failed."
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

  @doc "Record token usage against a specific task (async)."
  def record_tokens(session_id, task_id, count, server \\ __MODULE__) do
    GenServer.cast(server, {:record_tokens, session_id, task_id, count})
  end

  @doc "Update task fields (description, owner, metadata)."
  def update_task_fields(session_id, task_id, updates, server \\ __MODULE__) do
    GenServer.call(server, {:update_task_fields, session_id, task_id, updates})
  end

  @doc "Add a dependency (blocked_by) to a task."
  def add_dependency(session_id, task_id, blocker_id, server \\ __MODULE__) do
    GenServer.call(server, {:add_dependency, session_id, task_id, blocker_id})
  end

  @doc "Remove a dependency from a task."
  def remove_dependency(session_id, task_id, blocker_id, server \\ __MODULE__) do
    GenServer.call(server, {:remove_dependency, session_id, task_id, blocker_id})
  end

  @doc "Get the next unblocked pending task."
  def get_next_task(session_id, server \\ __MODULE__) do
    GenServer.call(server, {:get_next_task, session_id})
  end

  @doc "Emit a task_checklist_show event."
  def show_checklist(session_id, server \\ __MODULE__) do
    tasks = get_tasks(session_id, server)

    OptimalSystemAgent.Events.Bus.emit(:system_event, %{
      event: :task_checklist_show,
      session_id: session_id,
      data: %{tasks: Enum.map(tasks, &Tracker.task_to_map/1)}
    })

    :ok
  end

  @doc "Emit a task_checklist_hide event."
  def hide_checklist(session_id) do
    OptimalSystemAgent.Events.Bus.emit(:system_event, %{
      event: :task_checklist_hide,
      session_id: session_id,
      data: %{}
    })

    :ok
  end

  @doc "Extract task titles from a text response."
  defdelegate extract_tasks_from_response(text), to: Tracker, as: :extract_from_response

  # ── Workflow API ───────────────────────────────────────────────────────────

  @doc "Create a new workflow from a task description (LLM decomposition or template)."
  def create_workflow(task_description, session_id, opts \\ []) do
    GenServer.call(__MODULE__, {:create_workflow, task_description, session_id, opts}, 60_000)
  end

  @doc "Get the active workflow for a session."
  def active_workflow(session_id) do
    GenServer.call(__MODULE__, {:active_workflow, session_id})
  end

  @doc "Advance to the next step."
  def advance_workflow(workflow_id, result \\ nil) do
    GenServer.call(__MODULE__, {:advance_workflow, workflow_id, result})
  end

  @doc "Mark current step as completed with a result."
  def complete_workflow_step(workflow_id, result) do
    GenServer.call(__MODULE__, {:complete_workflow_step, workflow_id, result})
  end

  @doc "Skip a step."
  def skip_workflow_step(workflow_id, reason \\ nil) do
    GenServer.call(__MODULE__, {:skip_workflow_step, workflow_id, reason})
  end

  @doc "Pause a workflow."
  def pause_workflow(workflow_id) do
    GenServer.call(__MODULE__, {:pause_workflow, workflow_id})
  end

  @doc "Resume a paused workflow."
  def resume_workflow(workflow_id) do
    GenServer.call(__MODULE__, {:resume_workflow, workflow_id})
  end

  @doc "Get workflow status."
  def workflow_status(workflow_id) do
    GenServer.call(__MODULE__, {:workflow_status, workflow_id})
  end

  @doc "List all workflows for a session."
  def list_workflows(session_id) do
    GenServer.call(__MODULE__, {:list_workflows, session_id})
  end

  @doc "Get context block for prompt injection."
  def workflow_context_block(session_id) do
    GenServer.call(__MODULE__, {:workflow_context_block, session_id})
  end

  @doc "Auto-detect if a message implies a workflow should be created."
  defdelegate should_create_workflow?(message), to: Workflow, as: :should_create?

  # ── Queue API ──────────────────────────────────────────────────────────────

  @doc "Enqueue a task (async)."
  def enqueue(task_id, agent_id, payload, opts \\ []) do
    GenServer.cast(__MODULE__, {:enqueue, task_id, agent_id, payload, opts})
  end

  @doc "Enqueue a task (sync). Returns `{:ok, task}`."
  def enqueue_sync(task_id, agent_id, payload, opts \\ []) do
    GenServer.call(__MODULE__, {:enqueue_sync, task_id, agent_id, payload, opts})
  end

  @doc "Lease the oldest pending task for an agent. Returns `{:ok, task} | :empty`."
  def lease(agent_id, lease_duration_ms \\ 300_000) do
    GenServer.call(__MODULE__, {:lease, agent_id, lease_duration_ms})
  end

  @doc "Mark a task as completed."
  def complete_queued(task_id, result) do
    GenServer.cast(__MODULE__, {:queue_complete, task_id, result})
  end

  @doc "Mark a task as failed."
  def fail_queued(task_id, error) do
    GenServer.cast(__MODULE__, {:queue_fail, task_id, error})
  end

  @doc "Reap expired leases (async)."
  def reap_expired_leases do
    GenServer.cast(__MODULE__, :reap_expired)
  end

  @doc "List queue tasks."
  def list_tasks(opts \\ []) do
    GenServer.call(__MODULE__, {:list_tasks, opts})
  end

  @doc "Get a queue task by ID."
  def get_task(task_id) do
    GenServer.call(__MODULE__, {:get_task, task_id})
  end

  @doc "Query completed/failed tasks from DB."
  def list_history(opts \\ []) do
    Queue.history(opts)
  end

  # ── GenServer Callbacks: Tracker ───────────────────────────────────────────

  @impl true
  def handle_call({:add_task, session_id, title, opts}, _from, state) do
    {sessions, result} = Tracker.add_task(state.sessions, session_id, title, opts)
    {:reply, result, %{state | sessions: sessions}}
  end

  @impl true
  def handle_call({:add_tasks, session_id, titles}, _from, state) do
    {sessions, result} = Tracker.add_tasks(state.sessions, session_id, titles)
    {:reply, result, %{state | sessions: sessions}}
  end

  @impl true
  def handle_call({:start_task, session_id, task_id}, _from, state) do
    {sessions, result} = Tracker.start_task(state.sessions, session_id, task_id)
    {:reply, result, %{state | sessions: sessions}}
  end

  @impl true
  def handle_call({:complete_task, session_id, task_id}, _from, state) do
    {sessions, result} = Tracker.complete_task(state.sessions, session_id, task_id)
    {:reply, result, %{state | sessions: sessions}}
  end

  @impl true
  def handle_call({:fail_task, session_id, task_id, reason}, _from, state) do
    {sessions, result} = Tracker.fail_task(state.sessions, session_id, task_id, reason)
    {:reply, result, %{state | sessions: sessions}}
  end

  @impl true
  def handle_call({:update_task_fields, session_id, task_id, updates}, _from, state) do
    {sessions, result} = Tracker.update_fields(state.sessions, session_id, task_id, updates)
    {:reply, result, %{state | sessions: sessions}}
  end

  @impl true
  def handle_call({:add_dependency, session_id, task_id, blocker_id}, _from, state) do
    {sessions, result} = Tracker.add_dependency(state.sessions, session_id, task_id, blocker_id)
    {:reply, result, %{state | sessions: sessions}}
  end

  @impl true
  def handle_call({:remove_dependency, session_id, task_id, blocker_id}, _from, state) do
    {sessions, result} =
      Tracker.remove_dependency(state.sessions, session_id, task_id, blocker_id)

    {:reply, result, %{state | sessions: sessions}}
  end

  @impl true
  def handle_call({:get_tasks, session_id}, _from, state) do
    tasks = Tracker.get_tasks(state.sessions, session_id)
    {:reply, tasks, state}
  end

  @impl true
  def handle_call({:clear_tasks, session_id}, _from, state) do
    sessions = Tracker.clear_tasks(state.sessions, session_id)
    {:reply, :ok, %{state | sessions: sessions}}
  end

  @impl true
  def handle_call({:get_next_task, session_id}, _from, state) do
    result = Tracker.get_next_task(state.sessions, session_id)
    {:reply, result, state}
  end

  # ── GenServer Callbacks: Workflow ──────────────────────────────────────────

  @impl true
  def handle_call({:create_workflow, task_description, session_id, opts}, _from, state) do
    workflow_state = workflow_state_from(state)

    case Workflow.create(workflow_state, task_description, session_id, opts) do
      {:ok, {new_wf_state, serialized}} ->
        {:reply, {:ok, serialized}, merge_workflow_state(state, new_wf_state)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:active_workflow, session_id}, _from, state) do
    result = Workflow.active_workflow(workflow_state_from(state), session_id)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:advance_workflow, workflow_id, result}, _from, state) do
    wf_state = workflow_state_from(state)

    case Workflow.advance(wf_state, workflow_id, result) do
      {:ok, {new_wf_state, serialized}} ->
        {:reply, {:ok, serialized}, merge_workflow_state(state, new_wf_state)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:complete_workflow_step, workflow_id, result}, _from, state) do
    wf_state = workflow_state_from(state)

    case Workflow.complete_step(wf_state, workflow_id, result) do
      {:ok, {new_wf_state, serialized}} ->
        {:reply, {:ok, serialized}, merge_workflow_state(state, new_wf_state)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:skip_workflow_step, workflow_id, reason}, _from, state) do
    wf_state = workflow_state_from(state)

    case Workflow.skip_step(wf_state, workflow_id, reason) do
      {:ok, {new_wf_state, serialized}} ->
        {:reply, {:ok, serialized}, merge_workflow_state(state, new_wf_state)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:pause_workflow, workflow_id}, _from, state) do
    wf_state = workflow_state_from(state)

    case Workflow.pause(wf_state, workflow_id) do
      {:ok, {new_wf_state, serialized}} ->
        {:reply, {:ok, serialized}, merge_workflow_state(state, new_wf_state)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:resume_workflow, workflow_id}, _from, state) do
    wf_state = workflow_state_from(state)

    case Workflow.resume(wf_state, workflow_id) do
      {:ok, {new_wf_state, serialized}} ->
        {:reply, {:ok, serialized}, merge_workflow_state(state, new_wf_state)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:workflow_status, workflow_id}, _from, state) do
    result = Workflow.status(workflow_state_from(state), workflow_id)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:list_workflows, session_id}, _from, state) do
    result = Workflow.list(workflow_state_from(state), session_id)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:workflow_context_block, session_id}, _from, state) do
    result = Workflow.context_block(workflow_state_from(state), session_id)
    {:reply, result, state}
  end

  # ── GenServer Callbacks: Queue (handle_call) ──────────────────────────────

  @impl true
  def handle_call({:enqueue_sync, task_id, agent_id, payload, opts}, _from, state) do
    {queue, task} = Queue.enqueue_sync(state.queue, task_id, agent_id, payload, opts)
    {:reply, {:ok, task}, %{state | queue: queue}}
  end

  @impl true
  def handle_call({:lease, agent_id, lease_duration_ms}, _from, state) do
    {queue, result} = Queue.lease(state.queue, agent_id, lease_duration_ms)
    {:reply, result, %{state | queue: queue}}
  end

  @impl true
  def handle_call({:list_tasks, opts}, _from, state) do
    tasks = Queue.list_tasks(state.queue, opts)
    {:reply, tasks, state}
  end

  @impl true
  def handle_call({:get_task, task_id}, _from, state) do
    result = Queue.get_task(state.queue, task_id)
    {:reply, result, state}
  end

  # ── GenServer Callbacks: handle_cast (Tracker + Queue) ────────────────────

  @impl true
  def handle_cast({:record_tokens, session_id, task_id, count}, state) do
    sessions = Tracker.record_tokens(state.sessions, session_id, task_id, count)
    {:noreply, %{state | sessions: sessions}}
  end

  @impl true
  def handle_cast({:enqueue, task_id, agent_id, payload, opts}, state) do
    queue = Queue.enqueue(state.queue, task_id, agent_id, payload, opts)
    {:noreply, %{state | queue: queue}}
  end

  @impl true
  def handle_cast({:queue_complete, task_id, result}, state) do
    queue = Queue.complete(state.queue, task_id, result)
    {:noreply, %{state | queue: queue}}
  end

  @impl true
  def handle_cast({:queue_fail, task_id, error}, state) do
    queue = Queue.fail(state.queue, task_id, error)
    {:noreply, %{state | queue: queue}}
  end

  @impl true
  def handle_cast(:reap_expired, state) do
    queue = Queue.reap_expired(state.queue)
    {:noreply, %{state | queue: queue}}
  end

  # ── Timer Callbacks ────────────────────────────────────────────────────────

  @impl true
  def handle_info(:reap, state) do
    queue = Queue.reap_expired(state.queue)
    schedule_reap()
    {:noreply, %{state | queue: queue}}
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

      Logger.debug("[Agent.Tasks] Registered auto-extraction hook")
    rescue
      _ -> Logger.debug("[Agent.Tasks] Hooks not available, skipping auto-extraction hook")
    end

    {:noreply, state}
  end

  # ── Private Helpers ────────────────────────────────────────────────────────

  defp workflow_state_from(state) do
    %{workflows: state.workflows, dir: state.dir}
  end

  defp merge_workflow_state(state, wf_state) do
    %{state | workflows: wf_state.workflows, dir: wf_state.dir}
  end

  defp schedule_reap do
    Process.send_after(self(), :reap, @reap_interval)
  end

  defp schedule_hook_registration do
    Process.send_after(self(), :register_hook, 500)
  end

  defp auto_extract_hook(payload) do
    session_id = payload[:session_id]
    response = payload[:response] || payload[:text] || ""

    if is_binary(session_id) and is_binary(response) do
      existing =
        try do
          get_tasks(session_id)
        rescue
          _ -> []
        end

      if existing == [] do
        titles = Tracker.extract_from_response(response)

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
