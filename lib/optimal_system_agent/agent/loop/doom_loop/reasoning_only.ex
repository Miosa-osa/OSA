defmodule OptimalSystemAgent.Agent.Loop.DoomLoop.ReasoningOnly do
  @moduledoc """
  Reasoning-only / turn-errored doom-loop detector.

  OSA's other three detectors (`IdenticalCall`, `Stall`, `FailureSignature`)
  all key off *repeated tool calls* — they inspect `tool_calls`/`results`.
  A model that spins purely in thought (zero tool calls every generation)
  and/or whose turn keeps erroring produces NO tool-call signature at all, so
  none of them ever trip. The absolute call cap in `DoomLoop.check/3` is no
  backstop either — it only increments `total_tool_calls`, which never moves
  when there are no tool calls to count.

  This detector closes that gap (grok `session/streaming_capture.rs:7-38`
  `DoomLoopSegmentStamp` reasoning-only recovery parity): it tracks a
  consecutive counter of "empty" turns — a generation with zero tool calls, OR
  one the caller flags as errored via `state[:turn_errored]` — on the threaded
  `state` (`:reasoning_only_streak`), and halts once the streak reaches
  `threshold/0`. Any turn that DOES carry a tool call resets the streak (that
  is forward-progress-shaped, even if the call itself later fails — the
  `FailureSignature`/`Stall` detectors already own that case).

  On halt, it returns the same `{:halt, message, state}` contract the other
  detectors use, so it plugs into the EXISTING `Resample` remedy exactly like
  they do — the caller (`ReactLoop`) already forwards any `DoomLoop.check/3`
  halt to `Resample.handle/4`. No new remedy plumbing needed.
  """
  require Logger

  alias OptimalSystemAgent.Agent.Attendance
  alias OptimalSystemAgent.Agent.Loop.Guardrails
  alias OptimalSystemAgent.Events.Bus

  # Consecutive reasoning-only / turn-errored generations before a loop is
  # declared. Kept small — a single stuck reasoning spin can burn a LOT of
  # tokens per iteration (no tool call means no early-out), so this should
  # trip well before the identical-call/stall windows (12) would even fill.
  @default_threshold 3

  @doc """
  Consecutive reasoning-only/errored-turn threshold before a loop is declared
  (default #{@default_threshold}). Configurable via
  `config :optimal_system_agent, :doom_loop_resample, reasoning_only_threshold: N`
  — shares the resample settings block so detection sensitivity and the
  resample remedy budget are configured together.
  """
  @spec threshold() :: pos_integer()
  def threshold do
    Application.get_env(:optimal_system_agent, :doom_loop_resample, [])
    |> Keyword.get(:reasoning_only_threshold, @default_threshold)
  end

  @doc """
  Check whether this turn continues a reasoning-only / turn-errored streak.

  `tool_calls` is the list of tool calls this turn produced (empty for a
  pure-reasoning generation). `state[:turn_errored]` (optional, defaults to
  `false`) lets a caller flag a turn that errored out even though it may have
  attempted a tool call. Returns `{:ok, state}` to continue or
  `{:halt, message, state}` to stop.

  ## A truncated generation is not a spin

  `state[:turn_truncated]` (set by `ReactLoop` from the provider's stop reason)
  suppresses the count entirely. This detector asks "did the model stop calling
  tools?"; a generation cut off at the output-token ceiling never got to the
  end of its own sentence, let alone to a tool call, so counting it answers a
  question nobody asked.

  MEASURED, on `bench/terminalbench/runs/osa-tb20-full89-f6981b61`: the three
  generations that tripped this guard on `schemelike-metacircular-eval` were
  the three generations that stopped at exactly 32,768 output tokens. The model
  was writing an interpreter and being cut off; the guard reported it as a
  reasoning-only spin, halted, and its own advice text was delivered to the
  grader as the final answer. Two failures compounding — and the first of them
  was this predicate.

  The streak is left UNCHANGED rather than reset: a truncation is neither
  progress nor a spin, so it should neither advance the counter nor erase a
  real spin that was already accumulating around it. Only a genuine tool call
  resets it — and a generation that called a tool AND was then cut off is
  forward progress, so that case resets the streak as it always did.

  Like `:turn_errored`, the flag is one-shot: it is cleared on every call, so a
  caller that forgets to unset it cannot excuse an unbounded run of spins.
  """
  @spec check(list(), map()) :: {:ok, map()} | {:halt, String.t(), map()}
  def check(tool_calls, state) do
    errored? = Map.get(state, :turn_errored, false)
    reasoning_only? = tool_calls == []
    truncated? = Map.get(state, :turn_truncated, false) == true
    # Did THIS generation produce no visible content? The caller sets this from
    # the same `visible_empty?` it already computes. It is what tells a genuine
    # empty spin from a conversation — see `suppressed/2`.
    generation_empty? = Map.get(state, :generation_empty, false) == true

    # Always clear the one-shot flags — each describes THIS generation only.
    state =
      state
      |> Map.put(:turn_errored, false)
      |> Map.put(:turn_truncated, false)
      |> Map.put(:generation_empty, false)

    cond do
      # Forward progress outranks everything: a generation that called a tool
      # resets the streak whether or not it was ALSO cut off afterwards.
      not (reasoning_only? or errored?) ->
        {:ok, Map.put(state, :reasoning_only_streak, 0)}

      truncated? ->
        Logger.warning(
          "[doom] Generation was TRUNCATED at the output ceiling — not counted toward the " <>
            "reasoning-only streak (streak stays #{Map.get(state, :reasoning_only_streak, 0)}, " <>
            "session: #{Map.get(state, :session_id)})"
        )

        {:ok, state}

      true ->
        count_streak(errored?, generation_empty?, state)
    end
  end

  defp count_streak(errored?, generation_empty?, state) do
    streak = Map.get(state, :reasoning_only_streak, 0) + 1
    state = Map.put(state, :reasoning_only_streak, streak)

    cond do
      streak < threshold() -> {:ok, state}
      reason = suppressed(generation_empty?, state) -> suppress(reason, streak, state)
      true -> handle_trip(streak, errored?, state)
    end
  end

  # ── A conversation is not a spin ──────────────────────────────────────
  #
  # LIVE USER REPORT. A user typed `ok how about now` into the TUI and OSA's
  # entire reply was this guard's advice text, verbatim:
  #
  #     Stopped: 3 consecutive generations produced no tool calls without making
  #     progress (reasoning-only spin). Reconsider the goal, call a concrete
  #     tool to move forward, or decompose the task into smaller steps.
  #
  # Two things are wrong there and they are independent. The delivery is fixed
  # elsewhere (`Loop.TerminalSource` marks guard text so it can never render as
  # the model's answer). What is fixed HERE is that the guard should not have
  # fired at all.
  #
  # The predicate was `tool_calls == []`. It asked "did the model call a tool?"
  # and treated "no" as evidence of stalling — without ever asking whether a
  # tool was WARRANTED. For a conversational turn, zero tool calls is not a
  # symptom; it is the correct behaviour. The message even asserts a conclusion
  # its predicate never tested: it says "without making progress" when all it
  # measured was tool-call absence.
  #
  # This is the THIRD distinct way this one predicate has been wrong, and the
  # pattern across all three is the same — absence of a signal read as presence
  # of a fault:
  #
  #   1. A generation that was TRUNCATED at the output ceiling was counted as a
  #      spin (fixed above, `truncated?`): the model was cut off, not stalling.
  #   2. A turn that ERRORED was counted as a spin: the provider failed, the
  #      model never got to act.
  #   3. A CONVERSATIONAL turn is counted as a spin: no tool was needed.
  #
  # The conjunct used here is not new machinery. `ReactLoop`'s announcement
  # backstop already gates on exactly this question, with exactly this helper,
  # for exactly this reason — quoting its comment: *"a session that has only
  # talked is a conversation, not an interrupted task"*. Reusing it keeps one
  # definition of "this session is a conversation" rather than two that drift.
  #
  # `is_list/1` is load-bearing: `Guardrails.talked_only?/1` returns `true` for
  # a non-list, so without the guard a state map that simply has no `:messages`
  # key would suppress every halt. Absent evidence must not be read as evidence
  # of a conversation — that would be the same absence-means-presence mistake
  # this fix exists to correct.
  # An EMPTY generation (no visible content, no tool call) is never a
  # conversation — a conversation is the model TALKING, and this one said
  # nothing. It is exactly the spin this guard exists for, so neither
  # `talked_only?` nor `attended?` may excuse it. This is the fourth face of the
  # same predicate error: here, "attended session" (a real signal that a human
  # can press Esc) was read as "therefore this silence is fine", which let a
  # reasoning model that returns empty content every generation nudge-loop
  # forever in an attended TUI (reported: grok "thinks for a bit then stops").
  defp suppressed(true, _state), do: nil

  defp suppressed(false, state) do
    messages = Map.get(state, :messages)

    cond do
      is_list(messages) and Guardrails.talked_only?(messages) -> :conversation
      Attendance.attended?(state) -> :attended
      true -> nil
    end
  end

  # Suppression is LOUD, not silent — the whole point of this defect class.
  #
  # The streak keeps counting, so an operator reading the event stream sees the
  # detector still firing; what changes is that it no longer terminates the
  # turn. The turn stays bounded regardless: `ReactLoop`'s `max_iterations` cap
  # is the real backstop, and in an attended session a human can press Esc,
  # which is the case this guard was never needed for.
  defp suppress(reason, streak, state) do
    Logger.info(
      "[doom] Reasoning-only streak reached #{streak} but NOT halting — #{reason} " <>
        "(session: #{Map.get(state, :session_id)}). Zero tool calls is correct behaviour " <>
        "here; max_iterations remains the bound."
    )

    Bus.emit(:system_event, %{
      event: :reasoning_only_suppressed,
      session_id: Map.get(state, :session_id),
      reason: reason,
      streak: streak
    })

    {:ok, state}
  end

  defp handle_trip(streak, errored?, state) do
    what = if errored?, do: "the turn kept erroring", else: "produced no tool calls"

    msg =
      "Stopped: #{streak} consecutive generations #{what} without making progress " <>
        "(reasoning-only spin). Reconsider the goal, call a concrete tool to move forward, " <>
        "or decompose the task into smaller steps."

    Logger.warning(
      "[doom] Reasoning-only loop (#{streak}x, errored?=#{errored?}) — halting " <>
        "(session: #{Map.get(state, :session_id)})"
    )

    Bus.emit(:doom_loop_halt, %{
      session_id: Map.get(state, :session_id),
      reason: :reasoning_only,
      streak: streak,
      errored: errored?
    })

    # Reset the streak on halt so a resample (which re-invokes the loop) gets
    # a clean slate instead of instantly re-tripping on its very next check.
    state = Map.put(state, :reasoning_only_streak, 0)

    {:halt, msg, state}
  end
end
