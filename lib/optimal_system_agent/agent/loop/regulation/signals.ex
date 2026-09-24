defmodule OptimalSystemAgent.Agent.Loop.Regulation.Signals do
  @moduledoc """
  Pure signal extraction for the algedonic pain score.

  Unifies what the existing turn-level detectors already know onto one small
  map, WITHOUT duplicating their detection logic. Every field here is either:

    * read straight off a counter one of `DoomLoop`'s sub-detectors already
      threads on `state` (`IdenticalCall`, `Stall`, `ReasoningOnly`,
      `Escalation`) — this module never re-derives their windows, it only
      reads what they already wrote, so there is exactly one place that
      decides "is this a repeat" and this module cannot drift from it;
    * a small amount of genuinely NEW bookkeeping this pain channel owns
      outright (the surprise count, the approval-wait time, the turn clock,
      the cost baseline) — each is reset per-turn in
      `Agent.Loop.TurnPipeline.reset_per_turn_fields/1`.

  Nothing here halts, escalates, or emits. `check/3` is a plain function of
  its inputs — the only side effect anywhere in this module is the read of
  `PainChannel`'s wait-time accumulator (`take_wait_ms/1` also resets it,
  which is why `collect/3` must be called at most once per iteration).
  """

  alias OptimalSystemAgent.Agent.Loop.Regulation.PainChannel

  @type t :: %{
          probe_streak: non_neg_integer(),
          probe_tool: String.t() | nil,
          stall_checkpoints: non_neg_integer(),
          reasoning_only_streak: non_neg_integer(),
          recovery_attempts: non_neg_integer(),
          recovery_ratio: float(),
          graded_escalation: non_neg_integer(),
          escalation_ratio: float(),
          reasoning_overflow_ms: non_neg_integer() | nil,
          wait_ms: non_neg_integer(),
          surprises: non_neg_integer(),
          no_disk_change?: boolean(),
          elapsed_ms: non_neg_integer(),
          cost_this_turn_usd: float()
        }

  # Shared with `DoomLoop.Escalation` (graded nudge budget) and
  # `ReactLoop.spend_recovery/2` (recovery budget) — read here as constants
  # instead of aliasing those modules, so this module has zero risk of ever
  # calling into their halt/escalate side effects by accident.
  @max_graded_escalations 3
  @max_recovery_attempts 6

  # A reasoning-only generation this slow, with nothing to show for it, is the
  # "118s reasoning call produced nothing" shape from the motivating incident.
  # Deliberately well above the ~30s a normal thinking pass takes, so an
  # ordinary slow generation is not mistaken for the pathology.
  @reasoning_overflow_ms 60_000

  # Tools that represent a real write/edit landing on disk — mirrors
  # `DoomLoop.Stall`'s own list (kept independent on purpose: this module must
  # never import Stall's private helpers, only read the counters it publishes).
  @write_edit_tools ~w(file_write file_edit file_create write_file edit_file
                       apply_patch str_replace str_replace_editor create_file
                       file_append multi_edit notebook_edit)

  @doc """
  Collect the current pain signals for this iteration.

  `results` / `tool_calls` describe THIS iteration's tool batch (may be `[]`
  for a reasoning-only generation). `state` is the loop state, post
  `DoomLoop.check/3` (so its counters reflect this iteration already).
  """
  @spec collect(list(), list(), map()) :: t()
  def collect(results, tool_calls, state) do
    session_id = Map.get(state, :session_id)
    recovery_attempts = Map.get(state, :recovery_attempts, 0)
    graded_escalation = Map.get(state, :graded_escalation_count, 0)

    %{
      probe_streak: probe_streak(state),
      probe_tool: probe_tool(state),
      stall_checkpoints: Map.get(state, :stall_checkpoint_count, 0),
      reasoning_only_streak: Map.get(state, :reasoning_only_streak, 0),
      recovery_attempts: recovery_attempts,
      recovery_ratio: ratio(recovery_attempts, @max_recovery_attempts),
      graded_escalation: graded_escalation,
      escalation_ratio: ratio(graded_escalation, @max_graded_escalations),
      reasoning_overflow_ms: reasoning_overflow_ms(tool_calls, state),
      wait_ms: PainChannel.take_wait_ms(session_id),
      surprises: Map.get(state, :regulation_surprise_count, 0),
      no_disk_change?: not any_disk_write?(tool_calls, results),
      elapsed_ms: turn_elapsed_ms(state),
      cost_this_turn_usd: cost_this_turn(state)
    }
  end

  # ── Windowed read-only-probe streak ─────────────────────────────────────
  #
  # Reads `DoomLoop.IdenticalCall`'s own `:windowed_call_keys` bookkeeping
  # (the same field it writes every iteration) rather than re-deriving a
  # second notion of "is this a repeat" — see moduledoc. Counts trailing
  # occurrences of the most recent `{key, result-signature}` pair, exactly
  # what `IdenticalCall` itself scores, so a nudge/halt fired by that detector
  # and a pain-score rise reported here always describe the SAME repeat.
  defp probe_streak(state) do
    case Map.get(state, :windowed_call_keys, []) do
      [] ->
        0

      history ->
        case List.last(history) do
          {key, sig, true} -> windowed_count(history, key, sig)
          _ -> 0
        end
    end
  end

  defp probe_tool(state) do
    case Map.get(state, :windowed_call_keys, []) do
      [] -> nil
      history -> history |> List.last() |> elem(0) |> elem(0) |> to_string()
    end
  end

  defp windowed_count(history, key, sig) do
    history
    |> Enum.reverse()
    |> Enum.reduce_while(0, fn
      {^key, ^sig, true}, acc -> {:cont, acc + 1}
      {^key, _other, true}, acc -> {:halt, acc}
      _, acc -> {:cont, acc}
    end)
  end

  defp ratio(_used, max) when max <= 0, do: 0.0
  defp ratio(used, max), do: min(1.0, used / max)

  # A generation that produced no tool calls AND took unusually long is the
  # "118s reasoning call produced nothing" shape — distinct from an ordinary
  # slow-but-successful generation, which either produced tool calls or ended
  # the turn with a real answer (in which case there is no "next iteration" to
  # score it against).
  defp reasoning_overflow_ms([], state) do
    case Map.get(state, :last_generation_ms) do
      ms when is_integer(ms) and ms >= @reasoning_overflow_ms -> ms
      _ -> nil
    end
  end

  defp reasoning_overflow_ms(_tool_calls, _state), do: nil

  defp any_disk_write?(tool_calls, results) do
    Enum.any?(tool_calls, fn tc ->
      write_or_edit_tool?(tc.name) and write_succeeded?(tc, results)
    end)
  end

  defp write_or_edit_tool?(name) do
    downcased = name |> to_string() |> String.downcase()

    name in @write_edit_tools or
      String.contains?(downcased, "write") or
      String.contains?(downcased, "edit") or
      String.contains?(downcased, "patch")
  end

  defp write_succeeded?(tc, results) do
    case find_result(tc, results) do
      {:ok, result_str} when is_binary(result_str) -> not error_result?(result_str)
      _ -> true
    end
  end

  defp find_result(tc, results) when is_list(results) do
    Enum.find_value(results, :error, fn
      {rtc, {_msg, result_str}} when is_map(rtc) ->
        if same_call?(rtc, tc), do: {:ok, result_str}, else: nil

      {rtc, result_str} when is_map(rtc) and is_binary(result_str) ->
        if same_call?(rtc, tc), do: {:ok, result_str}, else: nil

      _ ->
        nil
    end)
  end

  defp find_result(_tc, _results), do: :error

  defp same_call?(a, b) when is_map(a) and is_map(b) do
    aid = Map.get(a, :id)
    bid = Map.get(b, :id)

    if not is_nil(aid) and not is_nil(bid) do
      aid == bid
    else
      Map.get(a, :name) == Map.get(b, :name) and Map.get(a, :arguments) == Map.get(b, :arguments)
    end
  end

  defp same_call?(_a, _b), do: false

  defp error_result?(result_str) do
    trimmed = String.trim_leading(result_str)

    String.starts_with?(trimmed, "Error:") or String.starts_with?(trimmed, "Blocked:") or
      String.contains?(result_str, "No change needed") or
      String.contains?(result_str, "No changes needed")
  end

  # `:regulation_turn_started_ms` is set once per turn in
  # `TurnPipeline.reset_per_turn_fields/1`. Its absence (a hand-built test
  # state, or a caller that never went through the turn pipeline) reads as "no
  # time has passed" rather than crashing.
  defp turn_elapsed_ms(state) do
    case Map.get(state, :regulation_turn_started_ms) do
      started when is_integer(started) -> max(System.monotonic_time(:millisecond) - started, 0)
      _ -> 0
    end
  end

  # `:regulation_turn_baseline_cost_usd` is snapshotted at the same turn
  # boundary, from the running `session_cost_usd` total. The DELTA since then
  # is what is actually scoped to this turn — `session_cost_usd` itself is a
  # session-lifetime total and would only ever grow.
  defp cost_this_turn(state) do
    total = Map.get(state, :session_cost_usd, 0.0) || 0.0
    baseline = Map.get(state, :regulation_turn_baseline_cost_usd, total) || total
    max(total - baseline, 0.0)
  end
end
