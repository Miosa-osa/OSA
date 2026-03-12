defmodule OptimalSystemAgent.Bridge.PubSub do
  @moduledoc """
  Bridges goldrush events to Phoenix.PubSub topics.

  Four subscription tiers:
  - Firehose: `osa:events` — all events (debugging, monitoring)
  - Session: `osa:session:{key}` — events scoped to a chat session
  - Type: `osa:type:{type}` — events filtered by type (selective subscription)
  - TUI: `osa:tui:output` — agent-visible events forwarded to the Rust TUI SSE stream

  This bridge allows any process (SDK connections, monitoring, etc.)
  to subscribe to agent events without coupling to goldrush directly.
  """
  use GenServer
  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Subscribe to the firehose (all events)."
  def subscribe_firehose do
    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:events")
  end

  @doc "Subscribe to a specific session's events."
  def subscribe_session(session_id) do
    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{session_id}")
  end

  @doc "Subscribe to a specific event type."
  def subscribe_type(event_type) do
    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:type:#{event_type}")
  end

  @doc "Subscribe to the TUI output stream (agent-visible events only)."
  def subscribe_tui_output do
    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:tui:output")
  end

  @impl true
  def init(:ok) do
    # Register as a handler for all event types on the goldrush bus
    # This will be called after Events.Bus initializes
    Process.send_after(self(), :register_bridge, 100)
    Logger.info("Bridge.PubSub started — 4-tier event fan-out")
    {:ok, %{}}
  end

  @impl true
  def handle_info(:register_bridge, state) do
    event_types = OptimalSystemAgent.Events.Bus.event_types()

    Enum.each(event_types, fn event_type ->
      OptimalSystemAgent.Events.Bus.register_handler(event_type, fn event ->
        broadcast_event(event)
      end)
    end)

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp broadcast_event(event) do
    pubsub = OptimalSystemAgent.PubSub

    # Tier 0: Command Center SSE — feed EventStream so /events SSE clients receive live events
    event_type = Map.get(event, :type, :unknown) |> to_string()
    OptimalSystemAgent.EventStream.broadcast(event_type, event)

    # Tier 1: Firehose — all events
    Phoenix.PubSub.broadcast(pubsub, "osa:events", {:osa_event, event})

    # Tier 2: Session — scoped to session_id if present
    if session_id = Map.get(event, :session_id) do
      Phoenix.PubSub.broadcast(pubsub, "osa:session:#{session_id}", {:osa_event, event})
    end

    # Tier 3: Type — filtered by event type
    if type = Map.get(event, :type) do
      Phoenix.PubSub.broadcast(pubsub, "osa:type:#{type}", {:osa_event, event})
    end

    # Tier 4: TUI output — forward agent-visible events to the Rust TUI SSE stream.
    # The TUI subscribes to "osa:tui:output" but nothing was broadcasting there,
    # causing the SSE connection to open but never receive any events.
    if tui_event?(event) do
      Phoenix.PubSub.broadcast(pubsub, "osa:tui:output", {:osa_event, event})
    end
  end

  # Events the TUI should display: LLM responses, tool results, agent responses,
  # and thinking/scratchpad output. Excludes internal bookkeeping events.
  @tui_event_types ~w(llm_chunk llm_response agent_response tool_result tool_error
                      thinking_chunk agent_message signal_classified)a

  defp tui_event?(event) do
    Map.get(event, :type) in @tui_event_types
  end
end
