defmodule OptimalSystemAgent.Agent.BatchCadence do
  @moduledoc """
  How many tool calls the model has issued per turn lately, and whether that
  pattern has flattened enough to be worth interrupting.

  ## The measurement this exists to act on

  Over 164 sessions and 6,748 tool-bearing turns:

    * batch rate decays with position — **0.34 at turn 0, 0.04 at turn 15+**;
    * batching is strongly self-conditioned —
      `P(batch | previous turn batched) = 0.53` against a base rate of
      **0.063**, an 8x lift;
    * sessions that never batched at all: **74 observed vs 22 expected** if
      turns were independent.

  A decay with position, a self-conditioning of 8x, and a bimodal
  never-vs-sometimes split are three signatures of the same mechanism:
  **in-context imitation**. The model reproduces the shape of its own recent
  transcript. Once thirty turns of single-call evidence are in the window, the
  next turn is a single call because that is what the transcript looks like.

  ## Why this is not a prompt change

  It was tried. A 4-trial-per-arm A/B moved nothing — including the arm that
  *removed* the existing guidance. That is the result the mechanism predicts: a
  static prefix is a handful of tokens sitting in front of tens of thousands of
  tokens of contrary evidence, and it does not get a vote proportional to its
  position.

  What can compete with recent evidence is *more recent evidence*. So the
  intervention is a short reminder in the **volatile tail** — appended after a
  tool result, where the transcript is being written — and never in the cached
  prefix. The prefix runs at ~92.8% cache hit on a byte-identical prefix, and
  anything that varies per turn there costs roughly 30x what it saves.

  ## Why it stops

  A reminder that fires every turn is noise, and the model learns to skip it.
  OSA has already run that experiment by accident: the stall detector fired 247
  times to no observable effect. So this one is bounded three ways —

    * it needs `@window` consecutive single-call turns before it says anything,
    * it will not speak again for `cooldown_for/1` turns afterwards, and that
      gap DOUBLES each time,
    * and it gives up entirely after `@max_fires` per session.

  The doubling is what lets one rule cover both a 15-turn session and a 232-turn
  one. Firings land at roughly turns 8, 18, 38, 78, 158 — five in total across a
  long session, one in a short one, and always further apart than the last.

  ## What it does NOT do

  It does not try to reduce turn count. OSA is at parity with codex on turns
  (78 vs 82) and mini-swe-agent takes 213 and beats both, so turn count is not
  the quantity that predicts anything. The goal is more work per turn.

  It also does not reason about which calls are safe to batch. `ConflictScope`
  decides that centrally, at the one layer that sees the whole batch, and a
  second opinion here would be a second thing to keep in sync. The nudge says
  what the model should consider; the orchestrator remains free to serialise
  whatever it must.

  ## Storage

  One public ETS table, `#{inspect(:osa_batch_cadence)}`, keyed by session id,
  holding a bounded recent-batch-size list plus the fire bookkeeping. Owned by a
  lazily started, unsupervised `GenServer` — the same self-owning-ETS pattern
  `Tools.FileState` and the hook engine use. Losing the table costs at most a
  missed nudge, so nothing here is allowed to raise.
  """

  use GenServer

  @table :osa_batch_cadence

  # How many consecutive single-call turns before the nudge is warranted. Chosen
  # against the decay curve: batch rate is already down to 0.04 by turn 15, so a
  # run of six single-call turns is an ordinary state rather than a rare one, and
  # a shorter window would fire constantly.
  @window 6

  # Turns of silence after the FIRST firing. Doubles after each one — see
  # `cooldown_for/1`.
  @cooldown 10

  # Total firings per session.
  @max_fires 5

  # Turn index below which nothing fires. Early turns already batch at 0.34 and
  # the opening moves of a session are legitimately sequential (orient, then
  # read). The problem being addressed lives at turn 15+.
  @min_turn 8

  # Cap on the retained history — only the tail matters and an unbounded list on
  # a 230-turn session is pure growth.
  @history 16

  @doc false
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    ensure_ets()
    {:ok, %{}}
  end

  @doc """
  Record that `session_id` issued `count` tool calls in one turn.

  Called once per dispatched batch from `Loop.ToolOrchestrator`, which is the
  only layer that sees a whole turn's calls together. Best-effort.
  """
  @spec record(term(), non_neg_integer()) :: :ok
  def record(session_id, count) when is_integer(count) and count >= 0 do
    key = skey(session_id)
    state = get(key)

    put(key, %{state | history: Enum.take([count | state.history], @history)})
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def record(_session_id, _count), do: :ok

  @doc """
  Should a batching nudge be emitted for `session_id` at `turn`?

  Returns `true` at most `@max_fires` times per session, and only when the last
  `@window` recorded turns were all single-call, the session is past
  `@min_turn`, and `@cooldown` turns have passed since the previous nudge.

  **This call is a check-and-set**: a `true` answer records the firing. Two
  callers cannot both be told to nudge for the same run of turns.
  """
  @spec nudge?(term(), integer()) :: boolean()
  def nudge?(session_id, turn) when is_integer(turn) do
    key = skey(session_id)
    state = get(key)

    if fire?(state, turn) do
      put(key, %{state | fires: state.fires + 1, last_fire_turn: turn})
      true
    else
      false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  def nudge?(_session_id, _turn), do: false

  defp fire?(state, turn) do
    turn >= @min_turn and
      state.fires < @max_fires and
      turn - state.last_fire_turn >= cooldown_for(state.fires) and
      flat?(state.history)
  end

  @doc """
  Turns of silence owed after `fires` firings: `@cooldown * 2^fires`.

  A flat cooldown was the first design and the offline replay killed it. With a
  10-turn gap and a 3-firing cap, every nudge in the corpus was spent by turn
  ~30 — including in the 232-turn session — so the region where batching has
  actually collapsed (turn 60+) received nothing at all. The cap was protecting
  the model from a reminder in exactly the place the measurement says the
  reminder is warranted.

  Doubling fixes both ends at once. Firings land at roughly turns 8, 18, 38, 78
  and 158: a short session hears it once, a long session hears it five times
  across its whole length, and the gap always grows, so it can never become the
  background noise the stall detector became at 247 repeats.
  """
  @spec cooldown_for(non_neg_integer()) :: pos_integer()
  def cooldown_for(fires) when is_integer(fires) and fires >= 0,
    do: @cooldown * Integer.pow(2, min(fires, @max_fires))

  # Every one of the last @window turns issued exactly one tool call. A turn
  # with ZERO tool calls is not evidence either way — it is a text-only answer,
  # which the orchestrator never reports — so history only ever contains turns
  # that called something.
  defp flat?(history) do
    recent = Enum.take(history, @window)
    length(recent) >= @window and Enum.all?(recent, &(&1 == 1))
  end

  @doc """
  The reminder text. Kept to two sentences: it rides in the volatile tail on a
  turn that already carries a tool result, and a long reminder is a cost paid
  every time it fires against a benefit that is at best one extra call.

  It names the mechanism (independent work) rather than a target number,
  because the only published comparison — opencode at 1.91 calls/turn — is
  partly an artefact of a prompt that forbids compound shell commands, which
  inflates its call count without doing more work. Steering toward that figure
  would be steering toward the artefact.
  """
  @spec message() :: String.t()
  def message do
    "You have issued one tool call per turn for the last #{@window} turns. If the next " <>
      "few things you need are independent — reading several files, checking several " <>
      "places, gathering evidence before deciding — issue those calls together in one " <>
      "turn instead of one at a time. Anything that would actually conflict is serialised " <>
      "for you, so batching independent work is always safe."
  end

  @doc "Drop all state. Test/maintenance helper."
  @spec reset() :: :ok
  def reset do
    ensure_table()

    try do
      :ets.delete_all_objects(@table)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  @doc false
  @spec window() :: pos_integer()
  def window, do: @window

  @doc false
  @spec min_turn() :: pos_integer()
  def min_turn, do: @min_turn

  @doc false
  @spec cooldown() :: pos_integer()
  def cooldown, do: @cooldown

  @doc false
  @spec max_fires() :: pos_integer()
  def max_fires, do: @max_fires

  # ── Internals ─────────────────────────────────────────────────────────

  @empty %{history: [], fires: 0, last_fire_turn: -1_000}

  defp get(key) do
    ensure_table()

    case safe_lookup(key) do
      [{^key, %{history: _, fires: _, last_fire_turn: _} = state}] -> state
      _ -> @empty
    end
  end

  defp put(key, state) do
    :ets.insert(@table, {key, state})
    :ok
  rescue
    ArgumentError ->
      ensure_table()

      try do
        :ets.insert(@table, {key, state})
      rescue
        ArgumentError -> :ok
      end

      :ok
  end

  defp safe_lookup(key) do
    :ets.lookup(@table, key)
  rescue
    ArgumentError -> []
  end

  defp skey(nil), do: "default"
  defp skey(s) when is_binary(s), do: s
  defp skey(other), do: to_string(other)

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        case GenServer.start(__MODULE__, :ok, name: __MODULE__) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          _ -> ensure_ets()
        end

      _tid ->
        :ok
    end
  end

  defp ensure_ets do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [
            :named_table,
            :public,
            :set,
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end

    :ok
  end
end
