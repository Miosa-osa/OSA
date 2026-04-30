defmodule OptimalSystemAgent.Agent.Memory.Episodic do
  @moduledoc """
  Episodic memory — records session events in ETS for fast recall.

  Stores events per session in `:osa_episodic_memory`. Caps at 1000 events
  per session (drops oldest when exceeded). Provides keyword matching with
  relevance scoring for recall queries.
  """

  use GenServer

  require Logger

  @table :osa_episodic_memory
  @max_events_per_session 1_000
  @decay_half_life_hours 2.0

  # -- Public API ------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  @doc "Record an event for a session."
  def record(event_type, content, session_id) do
    GenServer.cast(__MODULE__, {:record, event_type, content, session_id})
  end

  @doc "Return the most recent events for a session (newest first), with relevance."
  def recent(session_id, limit \\ 20) do
    events = lookup_session(session_id)

    events
    |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})
    |> Enum.take(limit)
    |> Enum.map(&add_relevance/1)
  end

  @doc "Recall events matching a keyword query, with relevance scoring."
  def recall(query, opts \\ []) do
    session_id = Keyword.get(opts, :session_id)
    event_type = Keyword.get(opts, :event_type)
    limit = Keyword.get(opts, :limit, 20)

    events =
      if session_id do
        lookup_session(session_id)
      else
        all_events()
      end

    # Filter by event_type if specified
    events =
      if event_type do
        Enum.filter(events, &(&1.event_type == event_type))
      else
        events
      end

    keywords =
      query
      |> to_string()
      |> String.downcase()
      |> String.split(~r/\s+/, trim: true)
      |> Enum.reject(&(String.length(&1) < 3))

    if keywords == [] do
      events
      |> Enum.take(limit)
      |> Enum.map(&add_relevance/1)
    else
      events
      |> Enum.map(fn event ->
        haystack = String.downcase(content_to_string(event.content))
        match_count = Enum.count(keywords, &String.contains?(haystack, &1))

        if match_count > 0 do
          keyword_relevance = match_count / max(length(keywords), 1)
          decay = temporal_decay(event.timestamp, @decay_half_life_hours)
          relevance = keyword_relevance * 0.7 + decay * 0.3
          Map.put(event, :relevance, Float.round(relevance, 4))
        else
          nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.relevance, :desc)
      |> Enum.take(limit)
    end
  end

  @doc "Return summary stats."
  def stats do
    case :ets.whereis(@table) do
      :undefined ->
        %{sessions: %{}, total_events: 0, event_types: %{}}

      _ ->
        all = all_events()

        sessions =
          all
          |> Enum.group_by(& &1.session_id)
          |> Map.new(fn {sid, evts} -> {sid, length(evts)} end)

        event_types =
          all
          |> Enum.group_by(& &1.event_type)
          |> Map.new(fn {t, evts} -> {t, length(evts)} end)

        %{sessions: sessions, total_events: length(all), event_types: event_types}
    end
  end

  @doc "Clear all events for a session."
  def clear_session(session_id) do
    GenServer.cast(__MODULE__, {:clear_session, session_id})
  end

  @doc "Compute temporal decay weight (exponential half-life)."
  def temporal_decay(timestamp, half_life_hours) do
    now = DateTime.utc_now()
    diff_seconds = DateTime.diff(now, timestamp, :second)
    diff_hours = diff_seconds / 3600.0
    :math.pow(0.5, diff_hours / half_life_hours)
  end

  # -- GenServer callbacks ---------------------------------------------------

  @impl true
  def init(:ok) do
    ensure_table()
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:record, event_type, content, session_id}, state) do
    ensure_table()

    event = %{
      type: event_type,
      event_type: event_type,
      content: content,
      data: if(is_map(content), do: content, else: %{message: content}),
      timestamp: DateTime.utc_now(),
      session_id: session_id
    }

    :ets.insert(@table, {{session_id, System.unique_integer([:monotonic, :positive])}, event})

    enforce_cap(session_id)

    {:noreply, state}
  end

  def handle_cast({:clear_session, session_id}, state) do
    ensure_table()
    :ets.match_delete(@table, {{session_id, :_}, :_})
    {:noreply, state}
  end

  # -- Internal helpers ------------------------------------------------------

  defp add_relevance(event) do
    decay = temporal_decay(event.timestamp, @decay_half_life_hours)
    Map.put(event, :relevance, Float.round(decay, 4))
  end

  defp content_to_string(content) when is_binary(content), do: content

  defp content_to_string(content) when is_map(content) do
    content
    |> Enum.map(fn {k, v} -> "#{k} #{v}" end)
    |> Enum.join(" ")
  end

  defp content_to_string(content), do: inspect(content)

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :ordered_set, :public])
      _ -> @table
    end
  rescue
    ArgumentError -> @table
  end

  defp lookup_session(session_id) do
    case :ets.whereis(@table) do
      :undefined ->
        []

      _ ->
        :ets.match_object(@table, {{session_id, :_}, :_})
        |> Enum.map(fn {_key, event} -> event end)
    end
  rescue
    _ -> []
  end

  defp all_events do
    case :ets.whereis(@table) do
      :undefined ->
        []

      _ ->
        :ets.tab2list(@table)
        |> Enum.map(fn {_key, event} -> event end)
    end
  rescue
    _ -> []
  end

  defp enforce_cap(session_id) do
    events = :ets.match_object(@table, {{session_id, :_}, :_})

    if length(events) > @max_events_per_session do
      to_drop = length(events) - @max_events_per_session

      events
      |> Enum.sort_by(fn {key, _} -> key end)
      |> Enum.take(to_drop)
      |> Enum.each(fn {key, _} -> :ets.delete(@table, key) end)
    end
  rescue
    _ -> :ok
  end
end
