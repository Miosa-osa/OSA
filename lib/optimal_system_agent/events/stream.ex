defmodule OptimalSystemAgent.Events.Stream do
  @moduledoc """
  Per-session event stream — a lightweight circular buffer of events with
  pub/sub for live subscribers.

  Each session gets its own Stream GenServer, registered via
  `OptimalSystemAgent.EventStreamRegistry`. Subscribers receive
  `{:event, event}` messages as events are appended. The stream
  auto-cleans subscriber entries when monitored processes exit.

  ## Usage

      # Start a stream for a session (typically via SessionSupervisor)
      {:ok, _pid} = Stream.start_link("session-abc")

      # Append events
      :ok = Stream.append("session-abc", event)

      # Subscribe to live events
      :ok = Stream.subscribe("session-abc", self())

      # Query historical events
      events = Stream.events("session-abc", type: :tool_call, limit: 10)

      # Replay a time range
      events = Stream.replay("session-abc", ~U[2026-03-06 00:00:00Z], ~U[2026-03-06 01:00:00Z])
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Events.Event

  @default_max_events 1000

  # ── Public API ──────────────────────────────────────────────────────

  @doc "Start an event stream for the given session."
  def start_link(session_id) do
    GenServer.start_link(__MODULE__, session_id, name: via(session_id))
  end

  @doc "Append an event to the session's stream. Notifies all subscribers."
  @spec append(String.t(), struct()) :: :ok | {:error, :not_found}
  def append(session_id, event) do
    GenServer.call(via(session_id), {:append, event})
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
  end

  @doc """
  Subscribe `pid` to live events on this session stream.

  The subscriber will receive `{:event, event}` messages for each new event.
  If the subscriber process exits, it is automatically removed.
  """
  @spec subscribe(String.t(), pid()) :: :ok | {:error, :not_found}
  def subscribe(session_id, pid \\ self()) do
    GenServer.call(via(session_id), {:subscribe, pid})
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
  end

  @doc "Unsubscribe `pid` from live events."
  @spec unsubscribe(String.t(), pid()) :: :ok | {:error, :not_found}
  def unsubscribe(session_id, pid \\ self()) do
    GenServer.call(via(session_id), {:unsubscribe, pid})
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
  end

  @doc """
  Retrieve events from the stream.

  ## Options

    * `:type` — filter by event type atom
    * `:since` — only events with `time >= since` (DateTime)
    * `:limit` — max number of events to return (most recent first)
  """
  @spec events(String.t(), keyword()) :: {:ok, list()} | {:error, :not_found}
  def events(session_id, opts \\ []) do
    GenServer.call(via(session_id), {:events, opts})
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
  end

  @doc "Replay events within a time range [from, to] inclusive."
  @spec replay(String.t(), DateTime.t(), DateTime.t()) :: {:ok, list()} | {:error, :not_found}
  def replay(session_id, from, to) do
    GenServer.call(via(session_id), {:replay, from, to})
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
  end

  @doc "Stop the event stream for the given session."
  @spec stop(String.t()) :: :ok
  def stop(session_id) do
    GenServer.stop(via(session_id), :normal)
  catch
    :exit, {:noproc, _} -> :ok
  end

  @doc "Return the count of events currently in the stream."
  @spec count(String.t()) :: {:ok, non_neg_integer()} | {:error, :not_found}
  def count(session_id) do
    GenServer.call(via(session_id), :count)
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
  end

  # ── GenServer callbacks ─────────────────────────────────────────────

  @impl true
  def init(session_id) do
    state = %{
      session_id: session_id,
      events: :queue.new(),
      event_count: 0,
      subscribers: %{},
      max_events: @default_max_events
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:append, event}, _from, state) do
    {queue, count} = enqueue(state.events, state.event_count, event, state.max_events)
    notify_subscribers(state.subscribers, event)
    {:reply, :ok, %{state | events: queue, event_count: count}}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    if Map.has_key?(state.subscribers, pid) do
      {:reply, :ok, state}
    else
      ref = Process.monitor(pid)
      {:reply, :ok, %{state | subscribers: Map.put(state.subscribers, pid, ref)}}
    end
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    case Map.pop(state.subscribers, pid) do
      {nil, _subs} ->
        {:reply, :ok, state}

      {ref, subs} ->
        Process.demonitor(ref, [:flush])
        {:reply, :ok, %{state | subscribers: subs}}
    end
  end

  def handle_call({:events, opts}, _from, state) do
    result =
      state.events
      |> :queue.to_list()
      |> filter_events(opts)
      |> Event.sort()

    {:reply, {:ok, result}, state}
  end

  def handle_call({:replay, from, to}, _from, state) do
    # Append order into the buffer is task-scheduling order (Bus.emit hands the
    # already-built event to a Task so emit never blocks), and the wall clock
    # alone cannot repair an inversion. Events carry a monotonic `seq` stamped
    # on the CALLER's process at emit time, so replay orders on that.
    result =
      state.events
      |> :queue.to_list()
      |> Enum.filter(fn event ->
        time = event_time(event)

        time != nil and DateTime.compare(time, from) in [:gt, :eq] and
          DateTime.compare(time, to) in [:lt, :eq]
      end)
      |> Event.sort()

    {:reply, {:ok, result}, state}
  end

  def handle_call(:count, _from, state) do
    {:reply, {:ok, state.event_count}, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.pop(state.subscribers, pid) do
      {^ref, subs} ->
        {:noreply, %{state | subscribers: subs}}

      {nil, subs} ->
        # Subscriber not found — clean up any stale refs matching this monitor
        cleaned =
          subs
          |> Enum.reject(fn {_p, r} -> r == ref end)
          |> Map.new()

        {:noreply, %{state | subscribers: cleaned}}

      {_other_ref, subs} ->
        # Subscriber found but ref didn't match — still remove it
        {:noreply, %{state | subscribers: subs}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Internals ───────────────────────────────────────────────────────

  defp via(session_id) do
    {:via, Registry, {OptimalSystemAgent.EventStreamRegistry, session_id}}
  end

  defp enqueue(queue, count, event, max) when count >= max do
    # Drop oldest event, add new one — circular buffer
    {_dropped, queue} = :queue.out(queue)
    {:queue.in(event, queue), max}
  end

  defp enqueue(queue, count, event, _max) do
    {:queue.in(event, queue), count + 1}
  end

  defp notify_subscribers(subscribers, event) do
    Enum.each(subscribers, fn {pid, _ref} ->
      send(pid, {:event, event})
    end)
  end

  defp filter_events(events, opts) do
    type = Keyword.get(opts, :type)
    since = Keyword.get(opts, :since)
    limit = Keyword.get(opts, :limit)

    events
    |> maybe_filter_type(type)
    |> maybe_filter_since(since)
    |> maybe_limit(limit)
  end

  defp maybe_filter_type(events, nil), do: events

  defp maybe_filter_type(events, type) do
    Enum.filter(events, fn event -> event_type(event) == type end)
  end

  defp maybe_filter_since(events, nil), do: events

  defp maybe_filter_since(events, since) do
    Enum.filter(events, fn event ->
      time = event_time(event)
      time != nil and DateTime.compare(time, since) in [:gt, :eq]
    end)
  end

  defp maybe_limit(events, nil), do: events
  defp maybe_limit(events, limit), do: Enum.take(events, -limit)

  # Extract type from Event struct or plain map
  defp event_type(%{type: type}), do: type
  defp event_type(_), do: nil

  # Extract time from Event struct or plain map
  defp event_time(%{time: time}), do: time
  defp event_time(_), do: nil
end
