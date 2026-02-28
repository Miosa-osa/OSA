defmodule OptimalSystemAgent.Events.Bus do
  @moduledoc """
  Event bus — goldrush-compiled :osa_event_router for zero-overhead dispatch.

  Uses `glc:compile/2` to compile event-matching predicates into real Erlang
  bytecode modules. Event routing happens at BEAM instruction speed — no hash
  lookups, no pattern matching at runtime.

  goldrush API (extend/goldrush 0.1.9):
  - `glc:eq(key, value)` — equality predicate
  - `glc:any([...])` — OR combinator
  - `glc:with(query, fun/1)` — wrap query with output handler
  - `glc:compile(module, query)` — compile to BEAM bytecode module
  - `glc:handle(module, event)` — process event through compiled module
  - `gre:make(proplist, [:list])` — create event
  - `gre:fetch(key, event)` — extract field from event

  ## Event Types
  - user_message: from channels -> Agent.Loop
  - llm_request: from Agent.Loop -> Providers.Registry
  - llm_response: from Providers -> Agent.Loop
  - tool_call: from Agent.Loop -> Tools.Registry
  - tool_result: from Tools -> Agent.Loop
  - agent_response: from Agent.Loop -> Channels, Bridge.PubSub
  - system_event: from Scheduler, internals -> Agent.Loop, Memory
  """
  use GenServer
  require Logger

  @event_types ~w(user_message llm_request llm_response tool_call tool_result agent_response system_event signal_classified channel_connected channel_disconnected channel_error)a

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Emit an event through the goldrush-compiled router."
  def emit(event_type, payload \\ %{}) when event_type in @event_types do
    # Create goldrush event from proplist
    fields = [{:type, event_type}, {:timestamp, System.monotonic_time()} | Map.to_list(payload)]
    event = :gre.make(fields, [:list])

    # Route through the compiled :osa_event_router module.
    # Dispatch via a supervised Task — goldrush's compiled module can call
    # into gr_param GenServer (5s default timeout), which hangs when its
    # ETS tables are in a bad state. An event bus must never block the caller.
    Task.Supervisor.start_child(OptimalSystemAgent.Events.TaskSupervisor, fn ->
      try do
        :glc.handle(:osa_event_router, event)
      catch
        _, _ -> :ok
      end
    end)
  end

  @doc """
  Register a handler for a specific event type.
  Returns a reference that can be passed to `unregister_handler/2`.
  """
  def register_handler(event_type, handler_fn) when is_function(handler_fn, 1) do
    ref = make_ref()
    GenServer.call(__MODULE__, {:register, event_type, ref, handler_fn})
    ref
  end

  @doc "Remove a previously registered handler by its ref."
  def unregister_handler(event_type, ref) do
    GenServer.call(__MODULE__, {:unregister, event_type, ref})
  end

  @doc "List all registered event types."
  def event_types, do: @event_types

  @impl true
  def init(:ok) do
    :ets.new(:osa_event_handlers, [:named_table, :public, :bag])
    compile_router()
    Logger.info("Event bus started — :osa_event_router compiled")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, event_type, ref, handler_fn}, _from, state) do
    :ets.insert(:osa_event_handlers, {event_type, ref, handler_fn})
    # Recompile the goldrush router — hot code reload
    compile_router()
    {:reply, :ok, state}
  end

  def handle_call({:unregister, event_type, ref}, _from, state) do
    # Match and delete the specific handler by ref
    :ets.match_delete(:osa_event_handlers, {event_type, ref, :_})
    {:reply, :ok, state}
  end

  # Compile the goldrush event router module.
  # Creates a real .beam module loaded into the VM at BEAM instruction speed.
  #
  # Architecture:
  #   1. Type-specific filters (glc:eq per event type)
  #   2. Combined via glc:any (OR)
  #   3. Wrapped with glc:with for dispatch handler
  #   4. Compiled to :osa_event_router via glc:compile
  defp compile_router do
    # Build type filter — only known event types pass through
    type_filters = Enum.map(@event_types, &:glc.eq(:type, &1))

    # Wrap with dispatch handler — glc:with(query, fun/1)
    # The handler is called when the compiled filter matches
    query =
      :glc.with(:glc.any(type_filters), fn event ->
        dispatch_event(event)
      end)

    case :glc.compile(:osa_event_router, query) do
      {:ok, _} -> :ok
      error -> Logger.warning("Failed to compile :osa_event_router: #{inspect(error)}")
    end
  rescue
    e ->
      Logger.warning("goldrush compile error: #{inspect(e)}")
      :ok
  end

  # Called by the goldrush compiled module when an event passes all filters.
  # Looks up registered handlers in ETS and dispatches asynchronously.
  defp dispatch_event(event) do
    type = :gre.fetch(:type, event)
    # Convert gre event to an Elixir map for handler consumption
    payload = event |> :gre.pairs() |> Map.new()

    try do
      :ets.lookup(:osa_event_handlers, type)
      |> Enum.each(fn
        {_, _ref, handler} ->
          Task.Supervisor.start_child(OptimalSystemAgent.Events.TaskSupervisor, fn ->
            handler.(payload)
          end)

        {_, handler} ->
          Task.Supervisor.start_child(OptimalSystemAgent.Events.TaskSupervisor, fn ->
            handler.(payload)
          end)
      end)
    rescue
      _ -> :ok
    end
  end
end
