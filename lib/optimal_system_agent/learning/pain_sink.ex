defmodule OptimalSystemAgent.Learning.PainSink do
  @moduledoc """
  Narrow consumer-side interface for turn-level "pain" — the friction signals
  `OptimalSystemAgent.Learning.DoubleLoop` turns into durable lessons at
  session end and at compaction.

  ## Why this exists

  A dedicated, richer per-turn pain channel (folding in measurement,
  budget/effort and routing signals) is being built elsewhere in this
  codebase. Until it lands, `record/4` is the stable, narrow boundary both
  sides can already agree on: call it with one of the fixed
  `OptimalSystemAgent.Learning.PainEvent.kind/0` values and a short,
  already-sanitised detail string. Every current caller —
  `OptimalSystemAgent.Agent.Loop.ToolRetry` on a recovered transient failure,
  the `pain_observer_*` hooks in `OptimalSystemAgent.Agent.Hooks.Handlers` —
  goes through this same function, so swapping in the eventual richer
  emitter is a call-site change, not a redesign. `test_event/2` exists to
  exercise the pipeline (and to seed tests) without waiting for either.

  ## Storage

  Events are buffered per session in a named ETS table (`:osa_pain_events`),
  capped at 300 events per session (oldest dropped first) — the same shape
  `OptimalSystemAgent.Agent.Memory.Episodic` already uses. `DoubleLoop.flush/2`
  drains (reads then clears) a session's buffer; `clear/1` is also called
  directly so a session's buffer can never accumulate forever.

  Every recorded event is ALSO mirrored onto `Events.Bus` as an algedonic
  alert (best-effort — a missing/degraded Bus never blocks the caller), so
  anything already watching algedonic alerts observes pain events too.
  """

  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Learning.PainEvent

  @table :osa_pain_events
  @max_events_per_session 300

  @doc """
  Record a pain event for a session. Never raises — a broken pain observer
  must never take down the real turn it is watching.
  """
  @spec record(String.t() | nil, PainEvent.kind(), term(), map()) :: :ok
  def record(session_id, kind, detail, metadata \\ %{})

  def record(session_id, kind, detail, metadata) when is_binary(session_id) do
    event = PainEvent.new(kind, session_id, detail, metadata)
    ensure_table()
    :ets.insert(@table, {{session_id, System.unique_integer([:monotonic, :positive])}, event})
    enforce_cap(session_id)
    emit_alert(event)
    :ok
  rescue
    _ -> :ok
  end

  def record(_session_id, _kind, _detail, _metadata), do: :ok

  @doc """
  Synthesise one event of `kind` for a session — the bridge for exercising
  the pain -> lesson pipeline before a richer upstream emitter exists, and
  for tests.
  """
  @spec test_event(String.t(), PainEvent.kind()) :: :ok
  def test_event(session_id, kind) do
    record(session_id, kind, "synthetic #{kind} test event", %{synthetic: true})
  end

  @doc "Buffered events for a session, oldest first."
  @spec events(String.t() | nil) :: [PainEvent.t()]
  def events(session_id) when is_binary(session_id) do
    ensure_table()

    @table
    |> :ets.match_object({{session_id, :_}, :_})
    |> Enum.sort_by(fn {key, _event} -> key end)
    |> Enum.map(fn {_key, event} -> event end)
  rescue
    _ -> []
  end

  def events(_session_id), do: []

  @doc "Drop every buffered event for a session."
  @spec clear(String.t() | nil) :: :ok
  def clear(session_id) when is_binary(session_id) do
    ensure_table()
    :ets.match_delete(@table, {{session_id, :_}, :_})
    :ok
  rescue
    _ -> :ok
  end

  def clear(_session_id), do: :ok

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :ordered_set, :public])
      _ -> @table
    end
  rescue
    ArgumentError -> @table
  end

  defp enforce_cap(session_id) do
    session_events = :ets.match_object(@table, {{session_id, :_}, :_})

    if length(session_events) > @max_events_per_session do
      to_drop = length(session_events) - @max_events_per_session

      session_events
      |> Enum.sort_by(fn {key, _event} -> key end)
      |> Enum.take(to_drop)
      |> Enum.each(fn {key, _event} -> :ets.delete(@table, key) end)
    end
  rescue
    _ -> :ok
  end

  defp emit_alert(%PainEvent{} = event) do
    Bus.emit_algedonic(severity_for(event.kind), event.detail,
      source: "pain_sink",
      metadata: Map.merge(event.metadata, %{pain_kind: event.kind, session_id: event.session_id})
    )
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp severity_for(:command_fix), do: :low
  defp severity_for(:slow_search), do: :low
  defp severity_for(_), do: :medium
end
