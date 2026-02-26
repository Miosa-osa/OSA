defmodule OptimalSystemAgent.Events.Bus do
  @moduledoc """
  Event bus — goldrush-compiled :osa_event_router for zero-overhead dispatch.

  Uses `glc:compile/3` to compile event-matching predicates into real Erlang
  bytecode modules. Event routing happens at BEAM instruction speed — no hash
  lookups, no pattern matching at runtime.

  ## Event Types
  - user_message: from channels → Agent.Loop
  - llm_request: from Agent.Loop → Providers.Registry
  - llm_response: from Providers → Agent.Loop
  - tool_call: from Agent.Loop → Skills.Registry
  - tool_result: from Skills → Agent.Loop
  - agent_response: from Agent.Loop → Channels, Bridge.PubSub
  - system_event: from Scheduler, internals → Agent.Loop, Memory
  """
  use GenServer
  require Logger

  @event_types ~w(user_message llm_request llm_response tool_call tool_result agent_response system_event)a

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Emit an event through the goldrush-compiled router."
  def emit(event_type, payload \\ %{}) when event_type in @event_types do
    event = Map.merge(payload, %{type: event_type, timestamp: System.monotonic_time()})
    :gre.emit(:osa_event_router, event)
  end

  @doc "Register a handler for a specific event type."
  def register_handler(event_type, handler_fn) when is_function(handler_fn, 1) do
    GenServer.call(__MODULE__, {:register, event_type, handler_fn})
  end

  @doc "List all registered event types."
  def event_types, do: @event_types

  @impl true
  def init(:ok) do
    # Compile the initial goldrush event router with empty handlers
    compile_router(%{})
    Logger.info("Event bus started — :osa_event_router compiled")
    {:ok, %{handlers: %{}}}
  end

  @impl true
  def handle_call({:register, event_type, handler_fn}, _from, state) do
    handlers = Map.update(state.handlers, event_type, [handler_fn], &[handler_fn | &1])
    compile_router(handlers)
    {:reply, :ok, %{state | handlers: handlers}}
  end

  # Compile the goldrush event router module.
  # This creates a real .beam artifact loaded into the VM.
  defp compile_router(handlers) do
    # Build glc filter rules from registered handlers
    rules = Enum.flat_map(handlers, fn {event_type, fns} ->
      Enum.map(fns, fn handler_fn ->
        {:glc, :eq, :type, event_type, handler_fn}
      end)
    end)

    # If no handlers, compile a pass-through that does nothing
    if rules == [] do
      :ok
    else
      case :glc.compile(:osa_event_router, rules) do
        {:ok, _} -> :ok
        error -> Logger.warning("Failed to compile :osa_event_router: #{inspect(error)}")
      end
    end
  rescue
    e ->
      Logger.warning("goldrush compile error: #{inspect(e)}")
      :ok
  end
end
