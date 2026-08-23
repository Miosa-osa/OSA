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

  alias OptimalSystemAgent.Events.Event
  alias OptimalSystemAgent.Events.Classifier
  alias OptimalSystemAgent.Events.FailureModes

  # Sample 1-in-N events for failure-mode detection to keep overhead negligible.
  @failure_mode_sample_rate 10

  @event_types ~w(user_message llm_request llm_response tool_call tool_result tool_render agent_response system_event channel_connected channel_disconnected channel_error ask_user_question survey_answered algedonic_alert signal_classified doom_loop_halt auto_mode_blocked auto_mode_paused)a

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Emit an event through the goldrush-compiled router.

  Wraps the payload in an `Event` struct with UUID, sequence number, timestamp,
  and tracing fields before dispatching to goldrush. Returns `{:ok, event}` with
  the created Event.

  The struct is built on the caller's process, so `event.seq` (strictly
  increasing, see `Event.next_seq/0`) and `event.time` reflect the order emit was
  called in. Delivery remains asynchronous, so consumers that care about order
  must sort on `seq` (`Event.sort/1`) rather than trusting arrival order or the
  wall clock.

  ## Options

    * `:source` - origin string (default: `"bus"`)
    * `:parent_id` - parent event ID for causality chains
    * `:session_id` - session identifier
    * `:correlation_id` - groups related events
    * `:signal_mode` - Signal Theory mode
    * `:signal_genre` - Signal Theory genre
    * `:signal_sn` - signal-to-noise ratio (0.0-1.0)
  """
  def emit(event_type, payload \\ %{}, opts \\ []) when event_type in @event_types do
    # Build the Event struct SYNCHRONOUSLY, on the caller's process, before any
    # task is spawned. `seq` (strictly increasing) and `time` therefore record
    # the order the caller emitted in. Building it inside the task instead let
    # two events emitted in a known order be stamped — and appended — reversed,
    # because task scheduling order is arbitrary.
    source = Keyword.get(opts, :source, "bus")
    typed_event = Event.new(event_type, source, payload, opts)

    # Run the rest of emit in a supervised task to never block the caller.
    # Using start_child (fire-and-forget) so crashes are observed by the supervisor
    # and the caller is never blocked or killed by a Bus.emit failure.
    case Task.Supervisor.start_child(
           OptimalSystemAgent.Events.TaskSupervisor,
           fn -> do_emit(typed_event) end
         ) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("[Bus] Could not dispatch emit task: #{inspect(reason)}")
    end

    {:ok, typed_event}
  end

  defp do_emit(%Event{} = typed_event) do
    event_type = typed_event.type

    # Auto-classify signal dimensions if not explicitly set
    typed_event =
      if is_nil(typed_event.signal_mode) do
        Classifier.auto_classify(typed_event)
      else
        typed_event
      end

    # Signal Theory failure-mode detection — sampled to keep the hot path cheap.
    # Runs 1-in-@failure_mode_sample_rate events; logs detected violations.
    if :rand.uniform(@failure_mode_sample_rate) == 1 do
      case FailureModes.detect(typed_event) do
        [] ->
          :ok

        violations ->
          Enum.each(violations, fn {mode, description} ->
            Logger.warning("[Bus] Signal failure mode #{mode} on #{event_type}: #{description}")
          end)
      end
    end

    # Build goldrush proplist from the Event struct.
    # :type must be at the top level for goldrush's compiled filter.
    gre_fields =
      typed_event
      |> Event.to_map()
      |> Map.put(:timestamp, System.monotonic_time())
      |> Map.to_list()

    gre_event = :gre.make(gre_fields, [:list])

    # Route through the compiled :osa_event_router module.
    # Dispatch via a supervised Task — goldrush's compiled module can call
    # into gr_param GenServer (5s default timeout), which hangs when its
    # ETS tables are in a bad state. An event bus must never block the caller.
    Task.Supervisor.start_child(
      OptimalSystemAgent.Events.TaskSupervisor,
      fn ->
        try do
          :glc.handle(:osa_event_router, gre_event)
        catch
          :error, reason ->
            Logger.warning("[Bus] Router dispatch error: #{inspect(reason)}")

          :exit, reason ->
            Logger.warning("[Bus] Router dispatch exit: #{inspect(reason)}")
        end
      end,
      max_children: 1000
    )

    # Best-effort append to per-session event stream (if session_id present).
    # Stream unavailable = silent no-op.
    if typed_event.session_id do
      try do
        OptimalSystemAgent.Events.Stream.append(typed_event.session_id, typed_event)
      rescue
        e ->
          Logger.warning(
            "[Bus] Stream append failed for session #{typed_event.session_id}: #{Exception.message(e)}"
          )
      catch
        kind, reason ->
          Logger.warning(
            "[Bus] Stream append #{kind} for session #{typed_event.session_id}: #{inspect(reason)}"
          )
      end
    end

    {:ok, typed_event}
  end

  @doc """
  Emit an algedonic alert — an urgent bypass signal in Beer's VSM.

  Algedonic signals propagate immediately, bypassing normal event channels.
  Use for critical system health issues that need immediate attention.

  ## Parameters

    * `severity` - `:critical`, `:high`, `:medium`, or `:low`
    * `message` - human-readable description of the alert

  ## Options

    * `:source` - origin string (default: `"algedonic"`)
    * `:metadata` - additional context map
    * All options from `emit/3`
  """
  @spec emit_algedonic(atom(), String.t(), keyword()) :: {:ok, Event.t()}
  def emit_algedonic(severity, message, opts \\ [])
      when severity in [:critical, :high, :medium, :low] and is_binary(message) do
    metadata = Keyword.get(opts, :metadata, %{})
    source = Keyword.get(opts, :source, "algedonic")

    payload = %{
      signal: :pain,
      severity: severity,
      message: message,
      metadata: metadata
    }

    emit(:algedonic_alert, payload, Keyword.put(opts, :source, source))
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
    # monitors: %{monitor_ref => [{event_type, handler_ref}]}
    {:ok, %{monitors: %{}}}
  end

  @impl true
  def handle_call({:register, event_type, ref, handler_fn}, {caller_pid, _}, state) do
    :ets.insert(:osa_event_handlers, {event_type, ref, handler_fn})
    # Monitor the registering process so we can auto-remove its handlers when it dies.
    mon_ref = Process.monitor(caller_pid)
    entries = Map.get(state.monitors, mon_ref, [])
    monitors = Map.put(state.monitors, mon_ref, [{event_type, ref} | entries])
    # No recompile needed — dispatch_event/1 reads handlers from ETS at call time.
    # The compiled goldrush module only does type-filtering (static @event_types).
    # Recompiling here caused a TOCTOU race: gr_param:transform/1 wipes the ETS
    # table mid-recompile while in-flight Task workers still hold references to
    # the old compiled bytecode → ets:lookup_element crash.
    {:reply, :ok, %{state | monitors: monitors}}
  end

  def handle_call({:unregister, event_type, ref}, _from, state) do
    :ets.match_delete(:osa_event_handlers, {event_type, ref, :_})
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, mon_ref, :process, _pid, _reason}, state) do
    {entries, monitors} = Map.pop(state.monitors, mon_ref, [])

    Enum.each(entries, fn {event_type, ref} ->
      :ets.match_delete(:osa_event_handlers, {event_type, ref, :_})
    end)

    {:noreply, %{state | monitors: monitors}}
  end

  # Compile the goldrush event router module ONCE at init.
  # Creates a real .beam module loaded into the VM at BEAM instruction speed.
  #
  # The compiled module handles type-filtering only (static @event_types).
  # Handler dispatch is dynamic via ETS lookup in dispatch_event/1.
  # Never recompile after init — doing so causes a TOCTOU race with
  # gr_param's ETS table while in-flight tasks hold old bytecode refs.
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
  # Handlers receive a map containing all Event struct fields plus goldrush metadata.
  defp dispatch_event(event) do
    type = :gre.fetch(:type, event)
    # Convert gre event to an Elixir map for handler consumption.
    # This map contains all Event struct fields (id, type, source, time, etc.)
    # plus the goldrush monotonic timestamp.
    payload = event |> :gre.pairs() |> Map.new()

    try do
      :ets.lookup(:osa_event_handlers, type)
      |> Enum.each(fn
        {_, _ref, handler} ->
          dispatch_with_dlq(type, payload, handler)
      end)
    rescue
      ArgumentError -> :ok
    end
  end

  defp dispatch_with_dlq(type, payload, handler) do
    case Task.Supervisor.start_child(OptimalSystemAgent.Events.TaskSupervisor, fn ->
           try do
             handler.(payload)
           rescue
             e ->
               Logger.warning("[Bus] Handler crash for #{type}: #{Exception.message(e)}")
               OptimalSystemAgent.Events.DLQ.enqueue(type, payload, handler, Exception.message(e))
           catch
             kind, reason ->
               Logger.warning("[Bus] Handler #{kind} for #{type}: #{inspect(reason)}")

               OptimalSystemAgent.Events.DLQ.enqueue(
                 type,
                 payload,
                 handler,
                 "#{kind}: #{inspect(reason)}"
               )
           end
         end) do
      {:ok, _} ->
        :ok

      {:error, :max_children} ->
        Logger.warning("[Bus] TaskSupervisor at max_children — enqueuing #{type} to DLQ")
        OptimalSystemAgent.Events.DLQ.enqueue(type, payload, handler, "max_children")

      {:error, reason} ->
        Logger.warning(
          "[Bus] dispatch_with_dlq start_child failed for #{type}: #{inspect(reason)}"
        )
    end
  end
end
