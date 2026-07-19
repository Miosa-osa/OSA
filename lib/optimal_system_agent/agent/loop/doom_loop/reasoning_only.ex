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
  """
  @spec check(list(), map()) :: {:ok, map()} | {:halt, String.t(), map()}
  def check(tool_calls, state) do
    errored? = Map.get(state, :turn_errored, false)
    reasoning_only? = tool_calls == []

    # Always clear the one-shot errored flag — it describes THIS turn only.
    state = Map.put(state, :turn_errored, false)

    if reasoning_only? or errored? do
      streak = Map.get(state, :reasoning_only_streak, 0) + 1
      state = Map.put(state, :reasoning_only_streak, streak)

      if streak >= threshold() do
        handle_trip(streak, errored?, state)
      else
        {:ok, state}
      end
    else
      {:ok, Map.put(state, :reasoning_only_streak, 0)}
    end
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
