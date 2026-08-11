defmodule OptimalSystemAgent.Agent.BackgroundNotifier do
  @moduledoc """
  Delegate-and-continue feedback bridge for background subagents.

  When a delegation runs in the background, `Orchestrator.run_background/2`
  returns immediately and later emits `:background_agent_completed` /
  `:background_agent_failed` on the parent session's PubSub topic. Without a
  listener those results just scroll past in the CLI and never re-enter the
  orchestrator's reasoning.

  This GenServer subscribes to a parent session's PubSub topic and, on each
  completion/failure, queues a `<task-notification>` via
  `Agent.TaskNotifications.queue/2` and pokes the parent Loop
  (`Loop.poke/1`): a BUSY loop folds the notification in at its next ReAct
  step boundary (beside the steer drain), an IDLE loop reacts with a
  synthetic turn — mirroring Claude Code's background completion resume.

  One notifier runs per parent session. It is started lazily by
  `ensure_started/1` (called from `run_background/2`), registered in the
  `SessionRegistry` under a `"bg-notifier:"`-prefixed key so it is a singleton
  and does not collide with Loop session ids.
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Agent.TaskNotifications

  # --- Client API ---

  @doc """
  Ensure a notifier is running for `parent_id`. Idempotent and race-safe —
  returns `{:ok, pid}` whether it started a new one or found an existing one.
  """
  @spec ensure_started(String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(parent_id) when is_binary(parent_id) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, registry_key(parent_id)) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(
               OptimalSystemAgent.SessionSupervisor,
               {__MODULE__, parent_id}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end
    end
  rescue
    e ->
      Logger.debug("[BackgroundNotifier] ensure_started failed: #{Exception.message(e)}")
      {:error, e}
  end

  def start_link(parent_id) do
    GenServer.start_link(__MODULE__, parent_id,
      name: {:via, Registry, {OptimalSystemAgent.SessionRegistry, registry_key(parent_id)}}
    )
  end

  # --- Server callbacks ---

  @impl true
  def init(parent_id) do
    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{parent_id}")
    Logger.debug("[BackgroundNotifier] listening for background results on #{parent_id}")
    {:ok, %{parent_id: parent_id}}
  end

  @impl true
  def handle_info({:osa_event, %{type: :background_agent_completed} = ev}, state) do
    inject(state.parent_id, ev, :completed)
    {:noreply, state}
  end

  def handle_info({:osa_event, %{type: :background_agent_failed} = ev}, state) do
    inject(state.parent_id, ev, :failed)
    {:noreply, state}
  end

  # The orchestrator's phase-aware stall watcher already measured that a
  # background teammate stopped making progress, and broadcast it here — with
  # nothing listening. The parent model, which is the party that can actually
  # DO something about it (task_output, task_stop, re-dispatch), never heard.
  #
  # Deliberately NOT arbitrated through `TaskNotifications.mark_notified/1`: that
  # flag is the exactly-once token for the run's TERMINAL result. A stall is not
  # terminal — the agent may still complete — so consuming the token here would
  # swallow the real completion later. The watcher emits at most one stall per
  # run and then stops, so this cannot repeat on its own.
  def handle_info({:osa_event, %{type: :background_agent_stalled} = ev}, state) do
    inject_stall(state.parent_id, ev)
    {:noreply, state}
  end

  # Background SHELL command completion — same re-entry mechanism as subagents.
  # Reproduces Claude Code's "Background command '<cmd>' completed (exit code N)"
  # so the model picks the result up on its next turn without manual polling.
  def handle_info({:osa_event, %{type: :background_command_completed} = ev}, state) do
    verb =
      case ev[:status] do
        :killed -> "was stopped"
        :failed -> "failed"
        _ -> "completed"
      end

    code = if is_integer(ev[:exit_code]), do: " (exit code #{ev[:exit_code]})", else: ""
    tail = ev[:output_tail] |> to_string() |> String.slice(0, 400)
    task_id = to_string(ev[:background_id] || "")

    summary =
      "Background command '#{ev[:command]}' #{verb}#{code}" <>
        if tail == "", do: "", else: " - tail: #{tail}"

    # WS6 exactly-once: if a bash_output poll already showed the model the
    # terminal status, mark_notified/1 returns false and we skip the queue.
    if task_id == "" or TaskNotifications.mark_notified(task_id) do
      TaskNotifications.queue(state.parent_id, %{
        task_id: task_id,
        status: ev[:status] || :done,
        output_file: ev[:output_file],
        summary: summary
      })

      # Busy loop → ReactLoop drains this beside Steer at its next step
      # boundary; idle loop → the poke runs a synthetic turn so the agent
      # reacts unprompted (the old inject-only path was never acted on).
      Loop.poke(state.parent_id)
    end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # --- Private ---

  defp inject(parent_id, ev, outcome) do
    role = Map.get(ev, :role, "background")
    agent_id = Map.get(ev, :agent_id, "unknown")
    dur = Map.get(ev, :duration_ms)
    dur_str = if is_integer(dur), do: " after #{dur}ms", else: ""

    summary =
      case outcome do
        :completed ->
          result = ev |> Map.get(:result, "") |> to_string() |> String.slice(0, 1000)

          "Background agent '#{role}' (#{agent_id}) completed#{dur_str}: #{result}"

        :failed ->
          error = ev |> Map.get(:error, "unknown error") |> to_string() |> String.slice(0, 1000)

          "Background agent '#{role}' (#{agent_id}) failed#{dur_str}: #{error}"
      end

    # WS7 — structured usage rendered as a compact string so the model reads
    # real numbers in the <usage> field instead of an inspected map.
    #
    # Built key-by-key rather than by matching a fixed shape. `total_tokens` and
    # `tool_uses` are omitted by `Orchestrator.reported_usage/2` when the run row
    # is gone, and a whole-map pattern match on the three-key shape would miss —
    # dropping the duration we DO know and handing the model an inspected map.
    usage = format_usage(Map.get(ev, :usage))

    # WS6: queue + poke instead of a bare transcript append — an idle parent
    # now reacts to the completion instead of the result rotting in history.
    #
    # Exactly-once across surfaces: the per-tool-call `Agent.Reminders`
    # pipeline can surface the SAME completed subagent as a `<system-reminder>`
    # when the loop is busy. Both paths arbitrate on `mark_notified/1` (the
    # shell path already does), so whichever reaches the id first delivers it
    # and the other skips — mirroring the `background_command_completed` guard.
    task_id = to_string(agent_id)

    if task_id in ["", "unknown"] or TaskNotifications.mark_notified(task_id) do
      TaskNotifications.queue(parent_id, %{
        task_id: task_id,
        status: outcome,
        summary: summary,
        output_file: Map.get(ev, :output_file),
        usage: usage
      })

      Loop.poke(parent_id)
    end
  rescue
    e -> Logger.debug("[BackgroundNotifier] inject failed: #{Exception.message(e)}")
  end

  # Render whichever usage counters are actually present as `k=v` pairs, in a
  # fixed order. Returns nil for an empty/absent map so `to_xml/1` drops the
  # <usage> element entirely rather than emitting an empty one.
  @doc false
  @spec format_usage(map() | nil | term()) :: String.t() | nil | term()
  def format_usage(usage) when is_map(usage) do
    case Enum.flat_map([:total_tokens, :tool_uses, :duration_ms], fn key ->
           case Map.get(usage, key) do
             v when is_number(v) -> ["#{key}=#{v}"]
             _ -> []
           end
         end) do
      [] -> nil
      parts -> Enum.join(parts, " ")
    end
  end

  def format_usage(other), do: other

  # Hand a stall report to the parent Loop the same way a completion is handed
  # over: queue a `<task-notification>` and poke. The summary carries the
  # watcher's own wording (which already names the phase and the recommended
  # next step) so the model gets an actionable message, not a bare flag.
  defp inject_stall(parent_id, ev) do
    agent_id = ev |> Map.get(:agent_id, "unknown") |> to_string()
    display = Map.get(ev, :display_name) || Map.get(ev, :role) || agent_id
    stalled_ms = Map.get(ev, :stalled_ms, 0)
    minutes = if is_integer(stalled_ms), do: div(stalled_ms, 60_000), else: 0

    summary =
      case ev |> Map.get(:message, "") |> to_string() do
        "" ->
          "Background agent '#{display}' (#{agent_id}) has made no progress for " <>
            "#{minutes} minutes (phase: #{Map.get(ev, :phase, "unknown")})."

        msg ->
          msg
      end

    TaskNotifications.queue(parent_id, %{
      task_id: agent_id,
      status: :stalled,
      summary: summary
    })

    Loop.poke(parent_id)
  rescue
    e -> Logger.debug("[BackgroundNotifier] inject_stall failed: #{Exception.message(e)}")
  end

  defp registry_key(parent_id), do: "bg-notifier:" <> parent_id
end
