defmodule OptimalSystemAgent.Events.TuiForwarder do
  @moduledoc """
  Bridges the internal `Events.Bus` to the per-session `osa:session:<id>` PubSub
  topic that the TUI actually streams.

  OSA has two disjoint event transports: the goldrush-compiled `Events.Bus`
  (fire-and-forget, wraps CloudEvents) and Phoenix.PubSub `osa:session:<id>`
  (what the SSE loop / TUI consumes). Only `tool_executor` bridged both, so
  anything emitted ONLY on the Bus — progress notes, steer injections, monitor
  fires, push notifications — was invisible in the TUI.

  This GenServer registers a single `Bus` handler on `:system_event` and
  re-broadcasts the events on an **allowlist** of Bus-only sub-events to the
  session topic as `{:osa_event, %{type: :system_event, event: <sub>, ...}}`.
  The allowlist prevents double-emitting events that a producer already
  broadcasts directly on the session topic (which would duplicate them and
  could feed back).

  Add new Bus-only sub-events to `@forward_events` to make them visible in the
  TUI without touching each emitter.
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Events.Bus

  # Sub-event names (the `:event` field inside a `:system_event` payload) that
  # are emitted ONLY on the Bus and should be surfaced to the TUI. Anything a
  # producer already broadcasts on the session topic (tool_call, orchestrator_*,
  # background_*) is intentionally NOT here to avoid duplicates.
  @forward_events ~w(
    progress_ledger
    steer_injected
    monitor_started
    monitor_fired
    push_notification
    subscribe_pr_registered
    goal_verifier_round
    scratchpad_activity
    coordinator_mode
    error
    fleet_node_started
    fleet_node_progress
    fleet_node_completed
    fleet_summary
  )a

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    ref =
      Bus.register_handler(:system_event, fn payload ->
        forward(payload)
      end)

    Logger.debug("[TuiForwarder] bridging Bus :system_event → osa:session PubSub")
    {:ok, %{ref: ref}}
  end

  # Handler runs in a Bus-spawned Task; keep it pure + defensive.
  defp forward(payload) do
    data = payload_data(payload)
    sub = normalize_event(data[:event] || data["event"])
    session_id = data[:session_id] || data["session_id"] || payload[:session_id]

    if sub in @forward_events and is_binary(session_id) do
      event =
        data
        |> Map.put(:type, :system_event)
        |> Map.put(:event, sub)
        |> Map.put(:session_id, session_id)

      Phoenix.PubSub.broadcast(
        OptimalSystemAgent.PubSub,
        "osa:session:#{session_id}",
        {:osa_event, event}
      )
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # The inner emit payload is carried in the CloudEvents `:data` field.
  defp payload_data(%{data: data}) when is_map(data), do: data
  defp payload_data(payload) when is_map(payload), do: payload
  defp payload_data(_), do: %{}

  defp normalize_event(e) when is_atom(e), do: e
  defp normalize_event(e) when is_binary(e), do: String.to_atom(e)
  defp normalize_event(_), do: nil
end
