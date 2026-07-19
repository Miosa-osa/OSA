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
    {:ok, state, {:continue, :register_bus_handler}}
  end

  # Registering with Events.Bus is deferred to handle_continue (rather than
  # done inline in init/1) so a boot-time hiccup there — e.g. Bus transiently
  # unreachable while Infrastructure is still settling under load — degrades
  # Progress instead of crashing it, which would otherwise take down the
  # whole AgentServices supervisor (and hence the entire app) on startup.
  @impl true
  def handle_continue(:register_bus_handler, state) do
    case try_register_event_handlers() do
      :ok ->
        Logger.info("[Progress] Progress tracker started")
        {:noreply, state}

      :error ->
        Process.send_after(self(), :retry_register_bus_handler, 500)
        {:noreply, state}
    end
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
  def handle_info(:retry_register_bus_handler, state) do
    {:noreply, state, {:continue, :register_bus_handler}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ── Event Handlers ──────────────────────────────────────────────────

  defp try_register_event_handlers do
    register_event_handlers()
    :ok
  catch
    :exit, reason ->
      Logger.warning("[Progress] Events.Bus unavailable, will retry: #{inspect(reason)}")
      :error
  end

  defp register_event_handlers do
    progress_pid = self()

    Bus.register_handler(:system_event, fn payload ->
      # Bus wraps payload in Event struct — original data is in :data field
      data = payload[:data] || payload
      event = data[:event]

      if event in [
           :orchestrator_task_started,
           :orchestrator_task_appraised,
           :orchestrator_wave_started,
           :orchestrator_agents_spawning,
           :orchestrator_agent_started,
           :orchestrator_agent_progress,
           :orchestrator_agent_completed,
           :orchestrator_task_completed,
           :orchestrator_task_failed,
           :orchestrator_synthesizing
         ] do
        send(progress_pid, {:orchestrator_event, data})
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
      lines =
        Enum.map(agents, fn agent ->
          format_agent_line(agent)
        end)

      Enum.join(lines, "\n")
    end
  end

  @doc """
  Format a single agent's status in the upstream contract style:

      ⏺ devops-engineer(Build server bootstrap script)
        ⎿  Done (15 tool uses · 50.6k tokens · 6m 32s)

  Or while running:

      ⏺ backend(Design user auth API)
        ⎿  Reading lib/router.ex (8 tool uses · 12.3k tokens · 2m 15s)
  """
  def format_agent_line(%AgentProgress{} = agent) do
    name = agent.name || agent.role || "agent"
    role = agent.role || name
    task_desc = truncate(agent.current_action || "", 50)
    duration = format_duration(agent.started_at, agent.completed_at)
    tokens = format_tokens(agent.tokens_used)
    tools = agent.tool_uses

    # Build metrics string: "15 tool uses · 50.6k tokens · 6m 32s"
    metrics =
      [
        if(tools > 0, do: "#{tools} tool use#{plural(tools)}"),
        if(agent.tokens_used > 0, do: "#{tokens} tokens"),
        if(duration != "", do: duration)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    status_text = agent_status_text(agent)
    icon = status_icon(agent.status)

    detail =
      if metrics != "" do
        "#{status_text} (#{metrics})"
      else
        status_text
      end

    "#{icon} #{role}(#{task_desc})\n  \u23bf  #{detail}"
  end

  @doc "Format duration between two DateTimes as human-readable string."
  def format_duration(nil, _), do: ""
  def format_duration(_, nil), do: ""

  def format_duration(started_at, completed_at) do
    diff_s = DateTime.diff(completed_at, started_at, :second)
    format_elapsed(diff_s)
  end

  @doc "Format elapsed seconds as human-readable duration."
  def format_elapsed(seconds) when seconds < 60, do: "#{seconds}s"

  def format_elapsed(seconds) do
    mins = div(seconds, 60)
    secs = rem(seconds, 60)

    if mins >= 60 do
      hours = div(mins, 60)
      remaining_mins = rem(mins, 60)
      "#{hours}h #{remaining_mins}m"
    else
      if secs > 0, do: "#{mins}m #{secs}s", else: "#{mins}m"
    end
  end

  defp truncate(str, max) when byte_size(str) > max, do: String.slice(str, 0, max) <> "..."
  defp truncate(str, _), do: str

  defp format_tokens(tokens) when is_number(tokens) and tokens >= 1000 do
    "#{Float.round(tokens / 1000, 1)}k"
  end

  defp format_tokens(tokens) when is_number(tokens), do: "#{tokens}"
  defp format_tokens(_), do: "0"

  defp agent_status_text(%AgentProgress{status: :completed}), do: "Done"

  defp agent_status_text(%AgentProgress{status: :failed, current_action: action})
       when is_binary(action) and action != "", do: "Failed: #{action}"

  defp agent_status_text(%AgentProgress{status: :failed}), do: "Failed"

  defp agent_status_text(%AgentProgress{current_action: action})
       when is_binary(action) and action != "", do: action

  defp agent_status_text(%AgentProgress{status: :running}), do: "Working..."
  defp agent_status_text(_), do: "Pending"

  defp status_icon(:completed), do: "⏺"
  defp status_icon(:failed), do: "✗"
  defp status_icon(:running), do: "⏺"
  defp status_icon(_), do: "○"

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
