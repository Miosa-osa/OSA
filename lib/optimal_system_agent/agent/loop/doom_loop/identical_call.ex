defmodule OptimalSystemAgent.Agent.Loop.DoomLoop.IdenticalCall do
  @moduledoc """
  Identical-call detector.

  Catches the model spamming the same tool+args back-to-back even when the
  calls succeed (the model ignores the result and re-issues). The
  signature-based failure check only catches repeated FAILURES; this catches
  repeated USELESS SUCCESSES (e.g. `dir_list` of cwd 6× in a row).

  Tracks the last N tool invocations as `{name, args_hash}` tuples on the
  threaded `state` (`:recent_call_keys`) and halts when 4+ consecutive entries
  are identical. One below the hard cap it delegates to `Escalation` to nudge a
  change of approach.
  """
  require Logger

  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Agent.Loop.DoomLoop.Escalation
  alias OptimalSystemAgent.Agent.Loop.DoomLoop.Resample

  # Tracks the last N tool invocations as `{name, args_hash}` tuples and halts
  # when `repeat_threshold/0`+ consecutive entries are identical. Independent of
  # success vs. error — protects against the model looping on a working tool
  # when it isn't using the result. The threshold is read from the shared
  # `:doom_loop_resample` settings (default 4) so detection sensitivity and the
  # resample remedy are configured together, matching grok's combined
  # `DoomLoopRecoverySettings`.
  @default_repeat_threshold 4

  # Threshold before an identical-call loop is declared. Configurable via
  # `config :optimal_system_agent, :doom_loop_resample, threshold: N`.
  defp repeat_threshold, do: Resample.threshold()

  # Sliding window sized to always accommodate the threshold (min 8) so a raised
  # threshold can never exceed the window and silently disable detection.
  defp repeat_window, do: max(@default_repeat_threshold * 2, repeat_threshold() * 2)

  @doc """
  Check the incoming tool calls for an identical-call loop.

  Returns `{:ok, state}` to continue or `{:halt, message, state}` to stop.
  """
  def check(tool_calls, state) do
    threshold = repeat_threshold()
    window = repeat_window()

    new_keys =
      Enum.map(tool_calls, fn tc ->
        args =
          case Map.get(tc, :arguments) do
            m when is_map(m) -> m
            _ -> %{}
          end

        {tc.name, :erlang.phash2(args)}
      end)

    history =
      (Map.get(state, :recent_call_keys, []) ++ new_keys)
      |> Enum.take(-window)

    state = Map.put(state, :recent_call_keys, history)

    streak =
      history
      |> Enum.reverse()
      |> Enum.chunk_while(
        nil,
        fn key, acc ->
          cond do
            is_nil(acc) -> {:cont, {key, 1}}
            elem(acc, 0) == key -> {:cont, {key, elem(acc, 1) + 1}}
            true -> {:halt, acc}
          end
        end,
        fn acc -> {:cont, acc, nil} end
      )
      |> List.first()

    case streak do
      {{tool, _hash}, n} when n >= threshold ->
        msg =
          "Stopped: tool `#{tool}` was called with identical arguments #{n} times in a row " <>
            "without making progress. The result of an earlier call is already in context — " <>
            "use it, or try a different tool / different arguments."

        Logger.warning("[doom] Identical-call loop on #{tool} (#{n}x) — halting")

        Bus.emit(:doom_loop_halt, %{
          session_id: state.session_id,
          reason: :identical_repeat,
          tool: tool,
          repeats: n
        })

        {:halt, msg, state}

      {{tool, _hash}, n} when n == threshold - 1 ->
        # One below the hard identical-call cap: nudge a change of approach
        # before the next repeat triggers the halt above.
        Escalation.graded(
          :approaching_identical_repeat,
          "You have called `#{tool}` with identical arguments #{n} times in a row.",
          state
        )

      _ ->
        {:ok, state}
    end
  end
end
