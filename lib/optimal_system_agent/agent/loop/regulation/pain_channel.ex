defmodule OptimalSystemAgent.Agent.Loop.Regulation.PainChannel do
  @moduledoc """
  The long-lived process behind the turn's algedonic (pain) channel.

  Two jobs, both needing a process that outlives a single ReAct iteration:

  1. **Cross-process wait capture.** `Agent.Loop.PermissionBroker.await/3` runs
     inside a `Task` spawned by `Agent.Loop.ToolOrchestrator` — a different
     process than the one running the ReAct loop — so the elapsed wait time it
     measures cannot flow back through the loop's own `state` the way every
     other regulation signal does (that Task's return value is just the
     tool's final string result). The broker emits a `:permission_wait`
     `system_event` on the Bus instead; this GenServer registers a handler for
     it (mirrors `Events.TuiForwarder`'s own registration, and for the same
     reason: `Events.Bus.register_handler/2` monitors the registering process
     and drops the handler when it dies, so it must be a supervised process,
     not a one-off Task) and accumulates the elapsed time per session in ETS.
     `take_wait_ms/1` reads and resets it, so each turn/iteration only sees the
     wait time that happened since it last asked.

  2. **Emission rate-limiting.** `Agent.Loop.Regulation.Pain` computes a score
     every iteration, but a sustained stuck stretch must not flood the bus/TUI
     with an alert per tool call. `should_emit?/3` + `record_emit/2` implement
     "at most one emission per `min_interval_ms`, except a severity increase
     always gets through" — the exception matters because a turn going from
     `:medium` to `:critical` is new information the rate limit must never
     hide.

  Both tables are plain ETS (no `:heir`): a lost cache on a crash/restart is a
  cold start, not data loss — the worst case is one extra emission or wait
  ms counted from zero, not a wrong answer.
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Events.Bus

  @table :osa_regulation_pain

  # Emission severities, ordered low -> high so "did severity increase" is a
  # plain integer comparison rather than a table of allowed transitions.
  @severity_rank %{none: 0, low: 1, medium: 2, high: 3, critical: 4}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Read and reset the approval-wait time accumulated for `session_id` since the
  last call. Returns `0` for a session with no recorded wait — the common
  case, so this is cheap on the hot path.
  """
  @spec take_wait_ms(String.t() | nil) :: non_neg_integer()
  def take_wait_ms(session_id) when is_binary(session_id) do
    case :ets.lookup(ensure_table(), {:wait, session_id}) do
      [{_, ms}] ->
        :ets.delete(ensure_table(), {:wait, session_id})
        ms

      [] ->
        0
    end
  end

  def take_wait_ms(_), do: 0

  @doc """
  Whether an algedonic emission for `session_id` at `severity` is allowed
  right now: either no prior emission is on record, `min_interval_ms` has
  elapsed since the last one, OR `severity` outranks the last one recorded
  (a severity increase always bypasses the rate limit — see moduledoc).
  """
  @spec should_emit?(String.t() | nil, atom(), non_neg_integer()) :: boolean()
  def should_emit?(session_id, severity, min_interval_ms) when is_binary(session_id) do
    case :ets.lookup(ensure_table(), {:emit, session_id}) do
      [{_, %{at: last_at, severity: last_severity}}] ->
        elapsed = System.monotonic_time(:millisecond) - last_at
        elapsed >= min_interval_ms or rank(severity) > rank(last_severity)

      [] ->
        true
    end
  end

  def should_emit?(_, _, _), do: false

  @doc "Record that an emission at `severity` just happened for `session_id`."
  @spec record_emit(String.t(), atom()) :: :ok
  def record_emit(session_id, severity) when is_binary(session_id) do
    :ets.insert(
      ensure_table(),
      {{:emit, session_id}, %{at: System.monotonic_time(:millisecond), severity: severity}}
    )

    :ok
  end

  @doc """
  Clear the rate-limit memory for `session_id` — called at the start of a new
  user turn (`TurnPipeline.reset_per_turn_fields/1`) so a fresh turn is judged
  on its own evidence rather than inheriting the previous turn's severity, and
  a genuinely brand-new stuck pattern in turn N+1 is never rate-limited away
  by turn N's alert.
  """
  @spec clear(String.t() | nil) :: :ok
  def clear(session_id) when is_binary(session_id) do
    :ets.delete(ensure_table(), {:emit, session_id})
    :ets.delete(ensure_table(), {:wait, session_id})
    :ok
  end

  def clear(_), do: :ok

  defp rank(severity), do: Map.get(@severity_rank, severity, 0)

  # --- GenServer ---

  @impl true
  def init(_opts) do
    ensure_table()

    ref =
      Bus.register_handler(:system_event, fn payload ->
        handle_bus_event(payload)
      end)

    {:ok, %{ref: ref}}
  end

  # Handler runs inside a Bus-spawned Task; keep it defensive — a crash here
  # must never take the channel down, and must never affect the turn that
  # emitted the event (this always runs after the fact).
  defp handle_bus_event(payload) do
    data = payload_data(payload)

    if normalize(data[:event] || data["event"]) == :permission_wait do
      session_id = data[:session_id] || data["session_id"]
      elapsed_ms = data[:elapsed_ms] || data["elapsed_ms"] || 0
      accumulate_wait(session_id, elapsed_ms)
    end

    :ok
  rescue
    e ->
      Logger.debug("[pain_channel] handle_bus_event failed: #{Exception.message(e)}")
      :ok
  catch
    kind, reason ->
      Logger.debug("[pain_channel] handle_bus_event #{kind}: #{inspect(reason)}")
      :ok
  end

  defp accumulate_wait(session_id, elapsed_ms)
       when is_binary(session_id) and is_integer(elapsed_ms) and elapsed_ms >= 0 do
    :ets.update_counter(ensure_table(), {:wait, session_id}, elapsed_ms, {
      {:wait, session_id},
      0
    })

    :ok
  end

  defp accumulate_wait(_, _), do: :ok

  defp payload_data(%{data: data}) when is_map(data), do: data
  defp payload_data(payload) when is_map(payload), do: payload
  defp payload_data(_), do: %{}

  # `permission_wait` is always minted as an atom by `PermissionBroker`, and
  # the Bus payload is built in-process (never decoded from external JSON), so
  # `String.to_existing_atom/1` is safe here — no attacker-controlled binary
  # ever reaches this path, and a genuinely unknown string correctly raises
  # into the `rescue` above rather than growing the atom table.
  defp normalize(e) when is_atom(e), do: e
  defp normalize(e) when is_binary(e), do: String.to_existing_atom(e)
  defp normalize(_), do: nil

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> @table
        end

      _ ->
        @table
    end
  end
end
