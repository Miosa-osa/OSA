defmodule OptimalSystemAgent.Agent.TurnTermination do
  @moduledoc """
  A once-per-turn latch over the terminal SSE frame (`agent_response` + `done`).

  `done` is the authoritative turn-end edge: the TUI gates its message-queue
  drain on it, precisely because `agent_response` can arrive several times
  within one turn. That makes a duplicate `done` more than noise.

  `POST /api/v1/orchestrate` emitted two. `TurnPipeline` already broadcasts a
  terminal frame before returning `{:error, reason}` for the turn/budget limit
  gate and for a `UserPromptSubmit` hook block, and the route's async task then
  called its own `emit_terminal_error/2` for that same `{:error, reason}`. The
  route's fallback was written for the crash and `:exit` cases, where nothing
  had broadcast anything and the client would otherwise spin on keepalives
  forever; it did not exclude the business-error case that had already
  terminated itself.

  Under the TUI's gate the second frame is actively harmful, and it reproduces
  the very bug the gate was added to fix:

      done #1  → turn_done = true, queue drains
      queued message opens turn B → turn_done = false
      done #2  → turn_done = true, mid-turn-B

  …which is the early drain again, through a narrower door.

  So terminal frames are claimed rather than sent. The first claimant for a turn
  sends; later ones are refused.

  ## Why the latch is epoch-stamped

  The first cut made the latch per-turn by having `open/1` DELETE the previous
  turn's row, and `open/1` is called from exactly one place: the top of
  `TurnPipeline.run/3`. That works for every turn that reaches the pipeline —
  and silently wedges the session for every turn that does not.

  A turn can die on the way IN: the Loop GenServer is gone, `GenServer.call`
  exits, `handle_call` raises before the pipeline runs. That turn never reaches
  `open/1`, so the PREVIOUS turn's claim is still standing. The route's crash
  fallback — the one code path whose entire job is to rescue exactly this case —
  asks to claim, is refused by a latch belonging to a turn that ended minutes
  ago, and broadcasts nothing. The SSE loop spins on keepalives forever and the
  session is inert.

  That is the same "nothing happens" symptom as the client-side overlay wedge,
  reached by a completely independent path, and it is strictly worse than the
  duplicate `done` this module exists to prevent: a duplicate frame costs one
  mis-drained queue, a swallowed frame costs the whole session.

  So the latch carries the epoch of the turn it belongs to, and a caller that
  cannot prove it is talking about the CURRENT turn cannot be silenced by an
  older one:

    * `open/1` bumps the session's epoch and marks the new turn unclaimed.
    * `claim/1` is the in-turn claim — used by code running inside the turn,
      which is by definition current.
    * `claim/2` is the cross-process claim. The caller passes the epoch it
      `observe/1`-ed BEFORE dispatching. If the epoch has advanced the turn
      really opened and ordinary dedup applies; if it has not, the turn never
      opened, any latch present belongs to an earlier turn, and the frame goes
      out. Failing toward a duplicate rather than toward silence is the whole
      point.

  Both claims are atomic (`:ets.insert_new/2` and `:ets.select_replace/2`), so
  processes racing to terminate one turn resolve to exactly one winner rather
  than both reading an empty latch and both sending.

  ## Observability

  Every suppression and every forced claim is logged above `debug` and emitted
  as `[:osa, :turn_termination, :suppressed | :forced]` telemetry. A latch that
  swallows a frame must never again be something you can only find by reading
  the source.
  """

  require Logger

  @table :osa_turn_termination

  # {session_id, epoch, claimed?}
  @typep row :: {String.t(), non_neg_integer(), boolean()}

  @doc """
  Open a new turn — bumps the session's epoch and clears the claim.

  Called at the top of a turn, before anything can terminate it. Returns the
  new epoch.
  """
  @spec open(String.t()) :: non_neg_integer()
  def open(session_id) when is_binary(session_id) do
    ensure_table()
    epoch = observe(session_id) + 1
    :ets.insert(@table, {session_id, epoch, false})
    epoch
  end

  def open(_), do: 0

  @doc """
  The session's current turn epoch, or `0` if no turn has ever opened.

  Callers that will terminate a turn from OUTSIDE it (the orchestrate route's
  crash fallback) must read this BEFORE dispatching the turn and pass it to
  `claim/2`. That reading is what lets a late claim tell "the turn opened and
  already terminated itself" apart from "the turn never opened at all", which
  are otherwise indistinguishable and have opposite correct answers.
  """
  @spec observe(String.t()) :: non_neg_integer()
  def observe(session_id) when is_binary(session_id) do
    ensure_table()

    case :ets.lookup(@table, session_id) do
      [{^session_id, epoch, _claimed}] -> epoch
      _ -> 0
    end
  end

  def observe(_), do: 0

  @doc """
  Claim the right to send this turn's terminal frame, from inside the turn.

  Returns `true` for the first caller in a turn and `false` for every later
  one. A caller that gets `false` must send nothing.
  """
  @spec claim(String.t()) :: boolean()
  def claim(session_id) when is_binary(session_id) do
    ensure_table()

    # A session with no row at all has never opened a turn. The frame must go
    # out — this is the crash-before-anything case the route fallback exists
    # for — but it must go out exactly once, so the row is created claimed.
    claimed? =
      :ets.insert_new(@table, {session_id, 0, true}) or
        :ets.select_replace(@table, unclaimed_to_claimed(session_id)) == 1

    unless claimed?, do: report_suppressed(session_id)
    claimed?
  end

  def claim(_), do: true

  @doc """
  Claim the terminal frame for a turn that was dispatched from another process.

  `observed_epoch` is the value `observe/1` returned before the turn was
  dispatched. See the module doc: when the epoch has not advanced the turn never
  opened, so no in-turn code can have broadcast anything, and refusing here
  would strand the client on keepalives forever.
  """
  @spec claim(String.t(), non_neg_integer()) :: boolean()
  def claim(session_id, observed_epoch)
      when is_binary(session_id) and is_integer(observed_epoch) do
    ensure_table()

    if observe(session_id) > observed_epoch do
      # The turn genuinely opened; ordinary once-per-turn dedup applies.
      claim(session_id)
    else
      force_claim(session_id, observed_epoch)
    end
  end

  def claim(_, _), do: true

  @doc """
  Whether this turn's terminal frame has already been sent. Diagnostics only —
  callers must use `claim/1`, which is atomic; a check followed by a send is
  the race this exists to avoid.
  """
  @spec terminated?(String.t()) :: boolean()
  def terminated?(session_id) when is_binary(session_id) do
    ensure_table()

    case :ets.lookup(@table, session_id) do
      [{^session_id, _epoch, claimed?}] -> claimed?
      _ -> false
    end
  end

  def terminated?(_), do: false

  @doc """
  Drop a session's latch entirely. Called when the session's loop goes away, so
  a stopped session leaves nothing behind that a reused id could inherit.
  """
  @spec forget(String.t()) :: :ok
  def forget(session_id) when is_binary(session_id) do
    ensure_table()
    :ets.delete(@table, session_id)
    :ok
  end

  def forget(_), do: :ok

  # --- Internals ---

  # The turn never opened, so whatever is in the table describes an EARLIER
  # turn and has no authority over this frame. Take the latch by advancing the
  # epoch past it, which also makes the take itself once-only: a second forcer
  # racing on the same stale epoch loses the `select_replace` and falls through
  # to a refusal.
  @spec force_claim(String.t(), non_neg_integer()) :: boolean()
  defp force_claim(session_id, observed_epoch) do
    next = observed_epoch + 1

    took? =
      :ets.insert_new(@table, {session_id, next, true}) or
        :ets.select_replace(@table, stale_to_forced(session_id, observed_epoch, next)) == 1

    if took? do
      Logger.info(
        "[turn-termination] session #{session_id}: turn never opened (epoch " <>
          "#{observed_epoch}) — emitting the terminal frame over a latch left by an " <>
          "earlier turn"
      )

      emit(:forced, session_id, observed_epoch)
    else
      report_suppressed(session_id)
    end

    took?
  end

  # `{sid, _epoch, false} -> {sid, epoch, true}` — flip an OPEN turn to claimed.
  @spec unclaimed_to_claimed(String.t()) :: [tuple()]
  defp unclaimed_to_claimed(session_id) do
    [{{session_id, :"$1", false}, [], [{{session_id, :"$1", true}}]}]
  end

  # `{sid, observed, _} -> {sid, observed + 1, true}` — take a STALE turn's row.
  @spec stale_to_forced(String.t(), non_neg_integer(), non_neg_integer()) :: [tuple()]
  defp stale_to_forced(session_id, observed_epoch, next) do
    [{{session_id, observed_epoch, :_}, [], [{{session_id, next, true}}]}]
  end

  defp report_suppressed(session_id) do
    Logger.warning(
      "[turn-termination] session #{session_id}: terminal frame suppressed — this " <>
        "turn was already terminated (epoch #{observe(session_id)})"
    )

    emit(:suppressed, session_id, observe(session_id))
  end

  defp emit(event, session_id, epoch) do
    :telemetry.execute(
      [:osa, :turn_termination, event],
      %{count: 1},
      %{session_id: session_id, epoch: epoch}
    )
  rescue
    _ -> :ok
  end

  # Created on demand rather than in a supervisor: the latch has to work for
  # any session on any node-local path, including request processes that start
  # before (or without) the agent supervision tree.
  @spec ensure_table() :: :ok
  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  rescue
    # Lost a creation race with another process — the table exists either way.
    ArgumentError -> :ok
  end

  @doc false
  @spec __row__(String.t()) :: row() | nil
  def __row__(session_id) do
    ensure_table()

    case :ets.lookup(@table, session_id) do
      [row] -> row
      _ -> nil
    end
  end
end
