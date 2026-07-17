defmodule OptimalSystemAgent.Agent.BackgroundNotifier do
  @moduledoc """
  Delegate-and-continue feedback bridge for background subagents.

  When a delegation runs in the background, `Orchestrator.run_background/2`
  returns immediately and later emits `:background_agent_completed` /
  `:background_agent_failed` on the parent session's PubSub topic. Without a
  listener those results just scroll past in the CLI and never re-enter the
  orchestrator's reasoning.

  This GenServer subscribes to a parent session's PubSub topic and, on each
  completion/failure, injects a synthetic user message carrying the child's
  result into the parent Loop's message history via
  `Loop.inject_agent_result/2`. The orchestrator LLM then picks it up on its
  next turn — mirroring Claude Code's completion notification.

  One notifier runs per parent session. It is started lazily by
  `ensure_started/1` (called from `run_background/2`), registered in the
  `SessionRegistry` under a `"bg-notifier:"`-prefixed key so it is a singleton
  and does not collide with Loop session ids.
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Agent.Loop

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
    tail = to_string(ev[:output_tail] || "")

    body =
      "[Background command '#{ev[:command]}' (#{ev[:background_id]}) #{verb}#{code}]" <>
        if tail == "", do: "", else: "\n\n#{tail}"

    Loop.inject_agent_result(state.parent_id, body)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # --- Private ---

  defp inject(parent_id, ev, outcome) do
    role = Map.get(ev, :role, "background")
    agent_id = Map.get(ev, :agent_id, "unknown")
    dur = Map.get(ev, :duration_ms)
    dur_str = if is_integer(dur), do: " after #{dur}ms", else: ""

    body =
      case outcome do
        :completed ->
          result = to_string(Map.get(ev, :result, ""))

          "[Background agent '#{role}' (#{agent_id}) completed#{dur_str}]\n\n#{result}"

        :failed ->
          error = to_string(Map.get(ev, :error, "unknown error"))

          "[Background agent '#{role}' (#{agent_id}) failed#{dur_str}]\n\n#{error}"
      end

    Loop.inject_agent_result(parent_id, body)
  rescue
    e -> Logger.debug("[BackgroundNotifier] inject failed: #{Exception.message(e)}")
  end

  defp registry_key(parent_id), do: "bg-notifier:" <> parent_id
end
