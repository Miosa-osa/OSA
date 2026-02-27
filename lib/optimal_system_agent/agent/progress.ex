defmodule OptimalSystemAgent.Agent.Progress do
  @moduledoc """
  Real-time progress tracking for orchestrated tasks.

  Subscribes to orchestrator events and maintains a live view of:
  - Running agents and their current activity
  - Tool use counts and token consumption
  - Completion status

  Emits formatted progress updates for CLI and UI rendering:

  Running 3 agents...
     Research - 12 tool uses - 45.2k tokens - Reading codebase
     Build - 28 tool uses - 89.1k tokens - Writing lib/router.ex
     Test - 8 tool uses - 23.4k tokens - Running tests
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Events.Bus

  defstruct tasks: %{},
            subscribers: %{}

  defmodule AgentProgress do
    @moduledoc "Progress state for a single agent within a task."
    defstruct [
      :id,
      :name,
      :role,
      status: :pending,
      tool_uses: 0,
      tokens_used: 0,
      current_action: nil,
      started_at: nil,
      completed_at: nil
    ]
  end

  defmodule TaskProgress do
    @moduledoc "Aggregate progress state for an orchestrated task."
    defstruct [
      :id,
      status: :running,
      agents: %{},
      started_at: nil,
      completed_at: nil,
      last_update: nil
    ]
  end

  # ── Client API ──────────────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)
  end

  @doc """
  Get a formatted progress string for a task.
  Returns the tree-style display suitable for CLI/UI rendering.
  """
  @spec format(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def format(task_id) do
    GenServer.call(__MODULE__, {:format, task_id})
  end

  @doc """
  Get raw progress data for a task.
  Returns a map with all agent states and metrics.
  """
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(task_id) do
    GenServer.call(__MODULE__, {:get, task_id})
  end

  @doc """
  List all tracked tasks with their current status.
  """
  @spec list() :: list(map())
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @doc """
  Subscribe to progress updates for a task.
  The subscriber PID will receive {:progress_update, task_id, formatted_string} messages.
  """
  @spec subscribe(String.t(), pid()) :: :ok
  def subscribe(task_id, pid \\ self()) do
    GenServer.call(__MODULE__, {:subscribe, task_id, pid})
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────

  @impl true
  def init(state) do
    # Register handlers for orchestrator events on the event bus
    register_event_handlers()

    Logger.info("[Progress] Progress tracker started")
    {:ok, state}
  end

  @impl true
  def handle_call({:format, task_id}, _from, state) do
    case Map.get(state.tasks, task_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      task_progress ->
        formatted = format_progress(task_progress)
        {:reply, {:ok, formatted}, state}
    end
  end

  @impl true
  def handle_call({:get, task_id}, _from, state) do
    case Map.get(state.tasks, task_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      task_progress ->
        data = %{
          task_id: task_id,
          status: task_progress.status,
          started_at: task_progress.started_at,
          completed_at: task_progress.completed_at,
          agents:
            task_progress.agents
            |> Map.values()
            |> Enum.sort_by(& &1.started_at)
            |> Enum.map(fn a ->
              %{
                id: a.id,
                name: a.name,
                role: a.role,
                status: a.status,
                tool_uses: a.tool_uses,
                tokens_used: a.tokens_used,
                current_action: a.current_action
              }
            end)
        }

        {:reply, {:ok, data}, state}
    end
  end

  @impl true
  def handle_call(:list, _from, state) do
    tasks =
      state.tasks
      |> Map.values()
      |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
      |> Enum.map(fn tp ->
        agent_count = map_size(tp.agents)
        completed = tp.agents |> Map.values() |> Enum.count(&(&1.status == :completed))

        %{
          id: tp.id,
          status: tp.status,
          agent_count: agent_count,
          completed_agents: completed,
          started_at: tp.started_at,
          completed_at: tp.completed_at
        }
      end)

    {:reply, tasks, state}
  end

  @impl true
  def handle_call({:subscribe, task_id, pid}, _from, state) do
    subs = Map.get(state.subscribers, task_id, MapSet.new())
    state = %{state | subscribers: Map.put(state.subscribers, task_id, MapSet.put(subs, pid))}
    {:reply, :ok, state}
  end

  # Handle orchestrator events relayed from the event bus
  @impl true
  def handle_info({:orchestrator_event, event}, state) do
    state = handle_orchestrator_event(event, state)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ── Event Handlers ──────────────────────────────────────────────────

  defp register_event_handlers do
    progress_pid = self()

    Bus.register_handler(:system_event, fn payload ->
      event = payload[:event]

      if event in [
           :orchestrator_task_started,
           :orchestrator_agents_spawning,
           :orchestrator_agent_started,
           :orchestrator_agent_progress,
           :orchestrator_agent_completed,
           :orchestrator_task_completed,
           :orchestrator_task_failed,
           :orchestrator_synthesizing
         ] do
        send(progress_pid, {:orchestrator_event, payload})
      end
    end)
  end

  defp handle_orchestrator_event(%{event: :orchestrator_task_started, task_id: task_id}, state) do
    task_progress = %TaskProgress{
      id: task_id,
      status: :running,
      started_at: DateTime.utc_now()
    }

    %{state | tasks: Map.put(state.tasks, task_id, task_progress)}
  end

  defp handle_orchestrator_event(
         %{event: :orchestrator_agent_started, task_id: task_id, agent_id: agent_id} = event,
         state
       ) do
    case Map.get(state.tasks, task_id) do
      nil ->
        state

      task_progress ->
        agent = %AgentProgress{
          id: agent_id,
          name: event[:agent_name] || "unnamed",
          role: event[:role] || :builder,
          status: :running,
          started_at: DateTime.utc_now()
        }

        updated = %{
          task_progress
          | agents: Map.put(task_progress.agents, agent_id, agent),
            last_update: DateTime.utc_now()
        }

        state = %{state | tasks: Map.put(state.tasks, task_id, updated)}
        notify_subscribers(state, task_id, updated)
        state
    end
  end

  defp handle_orchestrator_event(
         %{event: :orchestrator_agent_progress, task_id: task_id, agent_id: agent_id} = event,
         state
       ) do
    case Map.get(state.tasks, task_id) do
      nil ->
        state

      task_progress ->
        case Map.get(task_progress.agents, agent_id) do
          nil ->
            state

          agent ->
            updated_agent = %{
              agent
              | tool_uses: event[:tool_uses] || agent.tool_uses,
                tokens_used: event[:tokens_used] || agent.tokens_used,
                current_action: event[:current_action] || agent.current_action
            }

            updated = %{
              task_progress
              | agents: Map.put(task_progress.agents, agent_id, updated_agent),
                last_update: DateTime.utc_now()
            }

            state = %{state | tasks: Map.put(state.tasks, task_id, updated)}
            notify_subscribers(state, task_id, updated)
            state
        end
    end
  end

  defp handle_orchestrator_event(
         %{event: :orchestrator_agent_completed, task_id: task_id, agent_id: agent_id} = event,
         state
       ) do
    case Map.get(state.tasks, task_id) do
      nil ->
        state

      task_progress ->
        case Map.get(task_progress.agents, agent_id) do
          nil ->
            state

          agent ->
            updated_agent = %{
              agent
              | status: event[:status] || :completed,
                completed_at: DateTime.utc_now()
            }

            updated = %{
              task_progress
              | agents: Map.put(task_progress.agents, agent_id, updated_agent),
                last_update: DateTime.utc_now()
            }

            state = %{state | tasks: Map.put(state.tasks, task_id, updated)}
            notify_subscribers(state, task_id, updated)
            state
        end
    end
  end

  defp handle_orchestrator_event(%{event: :orchestrator_task_completed, task_id: task_id}, state) do
    case Map.get(state.tasks, task_id) do
      nil ->
        state

      task_progress ->
        updated = %{task_progress | status: :completed, completed_at: DateTime.utc_now()}
        state = %{state | tasks: Map.put(state.tasks, task_id, updated)}
        notify_subscribers(state, task_id, updated)
        state
    end
  end

  defp handle_orchestrator_event(%{event: :orchestrator_task_failed, task_id: task_id}, state) do
    case Map.get(state.tasks, task_id) do
      nil ->
        state

      task_progress ->
        updated = %{task_progress | status: :failed, completed_at: DateTime.utc_now()}
        state = %{state | tasks: Map.put(state.tasks, task_id, updated)}
        notify_subscribers(state, task_id, updated)
        state
    end
  end

  defp handle_orchestrator_event(_event, state), do: state

  # ── Progress Formatting ─────────────────────────────────────────────

  @doc """
  Format a task's progress as a tree-style display string.

  Example output:
    Running 3 agents...
       Research - 12 tool uses - 45.2k tokens - Reading codebase
       Build - 28 tool uses - 89.1k tokens - Writing lib/router.ex
       Test - 8 tool uses - 23.4k tokens - Running tests
  """
  def format_progress(%TaskProgress{} = task_progress) do
    agents =
      task_progress.agents
      |> Map.values()
      |> Enum.sort_by(& &1.started_at)

    total = length(agents)

    if total == 0 do
      "Preparing agents..."
    else
      completed = Enum.count(agents, &(&1.status == :completed))
      failed = Enum.count(agents, &(&1.status == :failed))

      header =
        cond do
          task_progress.status == :completed ->
            "Completed #{total} agent#{plural(total)} (#{completed} succeeded#{if failed > 0, do: ", #{failed} failed"})"

          task_progress.status == :failed ->
            "Failed (#{failed}/#{total} agents failed)"

          true ->
            running = Enum.count(agents, &(&1.status == :running))
            "Running #{running} agent#{plural(running)}..."
        end

      lines =
        agents
        |> Enum.with_index()
        |> Enum.map(fn {agent, idx} ->
          prefix = if idx == total - 1, do: "   \u2514\u2500", else: "   \u251c\u2500"
          tokens = format_tokens(agent.tokens_used)
          status = agent_status_text(agent)
          icon = status_icon(agent.status)

          "#{prefix} #{icon} #{agent.name} \u00b7 #{agent.tool_uses} tool uses \u00b7 #{tokens} tokens \u00b7 #{status}"
        end)

      Enum.join([header | lines], "\n")
    end
  end

  defp format_tokens(tokens) when is_number(tokens) and tokens >= 1000 do
    "#{Float.round(tokens / 1000, 1)}k"
  end

  defp format_tokens(tokens) when is_number(tokens), do: "#{tokens}"
  defp format_tokens(_), do: "0"

  defp agent_status_text(%AgentProgress{status: :completed}), do: "Done"
  defp agent_status_text(%AgentProgress{status: :failed}), do: "Failed"

  defp agent_status_text(%AgentProgress{current_action: action})
       when is_binary(action) and action != "", do: action

  defp agent_status_text(%AgentProgress{status: :running}), do: "Working..."
  defp agent_status_text(_), do: "Pending"

  defp status_icon(:completed), do: "[done]"
  defp status_icon(:failed), do: "[fail]"
  defp status_icon(:running), do: "[..]"
  defp status_icon(_), do: "[ ]"

  defp plural(1), do: ""
  defp plural(_), do: "s"

  # ── Subscriber Notification ─────────────────────────────────────────

  defp notify_subscribers(state, task_id, task_progress) do
    formatted = format_progress(task_progress)

    case Map.get(state.subscribers, task_id) do
      nil ->
        :ok

      subscribers ->
        Enum.each(subscribers, fn pid ->
          if Process.alive?(pid) do
            send(pid, {:progress_update, task_id, formatted})
          end
        end)
    end

    # Also emit on PubSub for SSE consumers
    try do
      Phoenix.PubSub.broadcast(
        OptimalSystemAgent.PubSub,
        "osa:orchestrator:#{task_id}",
        {:progress_update, task_id, formatted}
      )
    rescue
      _ -> :ok
    end
  end
end
