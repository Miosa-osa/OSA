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
  sends; later ones are refused. `open/1` starts a fresh turn and is what makes
  the latch per-turn rather than per-session — without it the first turn would
  silence every turn after it.

  The claim is `:ets.insert_new/2`, so two processes racing to terminate the
  same turn resolve to exactly one winner rather than both checking an empty
  table and both sending.
  """

  @table :osa_turn_termination

  @doc """
  Open a new turn — drops any claim from the previous one.

  Called at the top of a turn, before anything can terminate it.
  """
  @spec open(String.t()) :: :ok
  def open(session_id) when is_binary(session_id) do
    ensure_table()
    :ets.delete(@table, session_id)
    :ok
  end

  def open(_), do: :ok

  @doc """
  Claim the right to send this turn's terminal frame.

  Returns `true` for the first caller in a turn and `false` for every later
  one. A caller that gets `false` must send nothing.
  """
  @spec claim(String.t()) :: boolean()
  def claim(session_id) when is_binary(session_id) do
    ensure_table()
    :ets.insert_new(@table, {session_id, true})
  end

  def claim(_), do: true

  @doc """
  Whether this turn's terminal frame has already been sent. Diagnostics only —
  callers must use `claim/1`, which is atomic; a check followed by a send is
  the race this exists to avoid.
  """
  @spec terminated?(String.t()) :: boolean()
  def terminated?(session_id) when is_binary(session_id) do
    ensure_table()
    :ets.member(@table, session_id)
  end

  def terminated?(_), do: false

  # Created on demand rather than in a supervisor: the latch has to work for
  # any session on any node-local path, including request processes that start
  # before (or without) the agent supervision tree.
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
end
